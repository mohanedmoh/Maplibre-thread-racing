#!/usr/bin/env bash
# Fresh-install loop for the MapLibre startup race.
#
#   ./fresh-install-loop.sh <apk> [rounds] [output-dir]
#
# Each round uninstalls the app, installs the APK and cold-launches it, so the
# native library is loaded cold every time. `pm clear` is not enough: the race
# is widest on a fresh install. Use a physical device; an emulator did not
# reproduce the original bug.
#
# Verdicts:
#   OK     the app logged "[repro] offline configured" (or "rejected")
#   CRASH  the system logged am_crash for the app
#   HANG   neither happened; a tap then raised the input ANR. The thread dump
#          is read from dropbox and saved, with other apps' entries removed.
#   NO-ANSWER  neither happened and the tap raised no ANR either. Read
#          round-N-app.log: in our runs this was a silent deadlock, or a crash
#          that React Native killed (SIGKILL) before the system logged am_crash.
#
# A native abort (SIGABRT) also counts as CRASH, but round-N-crash.txt stays
# empty because it only holds Java exceptions; the abort is in round-N-app.log.
#
# Set SERIAL to pick a device when more than one is attached.
set -u
APK=${1:?usage: fresh-install-loop.sh <apk> [rounds] [output-dir]}
ROUNDS=${2:-10}
OUT=${3:-/tmp/maplibre-startup-repro}
PKG=${PKG:-com.maplibrestartuprepro}
ACTIVITY=${ACTIVITY:-$PKG/.MainActivity}
WAIT=${WAIT:-15}

a() { if [ -n "${SERIAL:-}" ]; then adb -s "$SERIAL" "$@"; else adb "$@"; fi; }

mkdir -p "$OUT"
read -r W H < <(a shell wm size | awk -F'[ x]' '/Physical size/ {print $3, $4}' | tr -d '\r')
ok=0; crash=0; hang=0

for r in $(seq 1 "$ROUNDS"); do
  a uninstall "$PKG" >/dev/null 2>&1
  a install "$APK" >/dev/null || { echo "round $r: install failed"; exit 1; }
  a shell input keyevent KEYCODE_WAKEUP
  a shell input keyevent KEYCODE_HOME
  sleep 2
  a logcat -b main,system,events,crash -c
  a shell am start -n "$ACTIVITY" >/dev/null

  verdict=""
  for i in $(seq 1 "$WAIT"); do
    sleep 1
    if a logcat -b events -d | grep 'am_crash' | grep -q "$PKG"; then verdict=CRASH; break; fi
    if a logcat -d -s ReactNativeJS:I | grep -q -E '\[repro\] offline (configured|rejected)'; then verdict="OK(${i}s)"; break; fi
  done

  detail=""
  if [ -z "$verdict" ]; then
    # No answer from the offline module. Deliver input so the system raises the
    # ANR and records the thread dump.
    pid=$(a shell pidof "$PKG" | tr -d '\r')
    a shell input tap $((W / 2)) $((H / 2))
    sleep 9
    if a logcat -b events -d | grep 'am_anr' | grep -q "$PKG"; then
      verdict=HANG
      a shell dumpsys dropbox --print data_app_anr > "$OUT/.dropbox.tmp" 2>&1
      awk -v want="PID: $pid" -v p="Process: $PKG" '
        /^[0-9]+-[0-9]+-[0-9]+ [0-9:]+ data_app_anr/ { if (keep && mine) last = buf; buf = ""; keep = 0; mine = 0 }
        { buf = buf $0 "\n" }
        $0 == p { keep = 1 }
        $0 == want { mine = 1 }
        END { if (keep && mine) last = buf; printf "%s", last }' "$OUT/.dropbox.tmp" > "$OUT/round-$r-anr.txt"
      rm -f "$OUT/.dropbox.tmp"
      if grep -q 'LibraryLoader' "$OUT/round-$r-anr.txt"; then detail=" [LibraryLoader in thread dump: round-$r-anr.txt]"; else detail=" [see round-$r-anr.txt]"; fi
    else
      verdict="NO-ANSWER"; detail=" [no crash, no ANR, no offline reply in ${WAIT}s]"
    fi
  fi
  if [ "$verdict" = CRASH ]; then
    a logcat -d -s AndroidRuntime:E > "$OUT/round-$r-crash.txt"
    detail=" [$(grep -m1 -o -E '[A-Za-z.]+(Exception|Error)' "$OUT/round-$r-crash.txt" | head -1): round-$r-crash.txt]"
  fi

  case $verdict in OK*) ok=$((ok + 1));; CRASH) crash=$((crash + 1));; *) hang=$((hang + 1));; esac
  a logcat -d -s ReactNativeJS:I > "$OUT/round-$r-js.log"
  # Instrumented builds (patches/instrumentation.patch) log REPRO lines, and a
  # REPRO_DUMP of every thread if the offline promise has not settled after 6 s.
  a logcat -d -v threadtime -s REPRO:I REPRO_DUMP:I | grep ' REPRO' > "$OUT/round-$r-repro.log" || rm -f "$OUT/round-$r-repro.log"
  case $verdict in OK*) ;; *)
    # Keep the app's own log lines for anything that is not a clean start.
    apppid=$(a logcat -b events -d | grep 'am_proc_start' | grep "$PKG" | tail -1 | sed -E 's/.*am_proc_start: \[[0-9]+,([0-9]+),.*/\1/')
    [ -n "$apppid" ] && a logcat -d -v threadtime | grep -E "^[0-9-]+ [0-9:.]+ +$apppid " > "$OUT/round-$r-app.log"
  ;; esac

  # How close was it? Time from the nativeloader line for libmaplibre.so to the
  # first offline call. Negative, or no library line at all, means the offline
  # call got there first. Positive does not mean safe: the line is logged when
  # dlopen returns, before JNI_OnLoad and the rest of MapLibre.getInstance run.
  a logcat -d -v threadtime | grep -E 'libmaplibre\.so|\[repro\] .*calling OfflineManager' > "$OUT/round-$r-timing.log"
  margin=$(awk '
    function ms(t,  p) { split(t, p, /[:.]/); return ((p[1] * 60 + p[2]) * 60 + p[3]) * 1000 + p[4] }
    /libmaplibre\.so/ && !lib { lib = ms($2) }
    /calling OfflineManager/ && !call { call = ms($2) }
    END { if (!call) print "no-call"; else if (!lib) print "lib-not-loaded-before-call"; else printf "%+dms", call - lib }' "$OUT/round-$r-timing.log")
  echo "round $r: $verdict$detail | library-loaded -> offline-call margin: $margin"
  a shell am force-stop "$PKG"
done

echo "SUMMARY: ok=$ok crash=$crash hang/no-answer=$hang of $ROUNDS"
