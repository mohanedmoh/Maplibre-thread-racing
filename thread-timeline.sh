#!/usr/bin/env bash
# Per-round thread timeline for a run of an instrumented build
# (patches/instrumentation.patch).
#
#   ./thread-timeline.sh <run-dir>
#
# Times are ms relative to the JS "[repro] ... calling OfflineManager" line, and
# [name] is the thread. Only the app process that made that call is used, in
# case logcat was not cleared between rounds.
#
#   mapInit      MLRNMapViewModule.initialize() posts MapLibre.getInstance
#   getInstance  MapLibre.getInstance start..done on main ("never" = did not finish)
#   lib          nativeloader line for libmaplibre.so (dlopen has returned)
#   offInit      MLRNOfflineModule.initialize() posts runMigrations
#   runMig       runMigrations starts on main
#   setTile      setTileCountLimit runs
#   WATCHDOG     the offline promise had not settled after 6 s; every thread's
#                stack is in round-N-repro.log (REPRO_DUMP lines)
set -u
d=${1:?usage: thread-timeline.sh <run-dir>}
rounds=$(grep -c '^round ' "$d/summary.txt")
for n in $(seq 1 "$rounds"); do
  f="$d/round-$n-repro.log"
  [ -f "$f" ] || continue
  verdict=$(grep -m1 "^round $n:" "$d/summary.txt" | sed -E 's/^round [0-9]+: ([A-Z-]+).*/\1/')
  pid=$(grep 'calling OfflineManager' "$d/round-$n-timing.log" 2>/dev/null | tail -1 | awk '{print $3}')
  cat "$f" "$d/round-$n-timing.log" 2>/dev/null | grep -v REPRO_DUMP | awk -v n="$n" -v verdict="$verdict" -v pid="$pid" '
    function ms(t,  p) { split(t, p, /[:.]/); return ((p[1] * 60 + p[2]) * 60 + p[3]) * 1000 + p[4] }
    function th(s) { if (match(s, / on [^: ]+/)) return substr(s, RSTART + 4, RLENGTH - 4); return "?" }
    function rel(t) { return (t == "" ? "   -  " : sprintf("%+5d", t - js)) }
    !/^[0-9][0-9]-[0-9][0-9] / { next }
    pid != "" && $3 != pid { next }
    { t = ms($2) }
    /calling OfflineManager/            && js  == "" { js  = t }
    /libmaplibre\.so/                   && lib == "" { lib = t }
    /MapViewModule\.initialize\(\) on/  && mvi == "" { mvi = t; mvith = th($0) }
    /OfflineModule\.initialize\(\) on/  && ofi == "" { ofi = t; ofith = th($0) }
    /MapLibre\.getInstance START/       && gis == "" { gis = t }
    /MapLibre\.getInstance DONE/        && gid == "" { gid = t }
    /runMigrations START/               && mig == "" { mig = t }
    /setTileCountLimit on/              && stl == "" { stl = t; stlth = th($0) }
    /watchdog: NO ambient/                           { wd = 1 }
    END {
      if (js == "") { printf "round %-2s %-9s (no JS offline-call line)\n", n, verdict; exit }
      dur = (gis != "" && gid != "") ? sprintf("%dms", gid - gis) : "never"
      printf "round %-2s %-9s mapInit %s[%s]  getInstance %s..%s (%s)  lib %s  offInit %s[%s]  runMig %s  setTile %s[%s]%s\n",
        n, verdict, rel(mvi), mvith, rel(gis), rel(gid), dur, rel(lib), rel(ofi), ofith, rel(mig), rel(stl), stlth,
        (wd ? "  WATCHDOG" : "")
    }'
done
