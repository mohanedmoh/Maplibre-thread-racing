#!/usr/bin/env bash
# Summarise one fresh-install-loop.sh output directory.
#
#   ./summarize-run.sh <run-dir>
#
# Prints the verdict counts, what each crash was (thread | exception | first
# wrapper frame; native aborts are read from round-N-app.log), what the app log
# shows for each NO-ANSWER round, and the library-load -> offline-call margins.
set -u
d=${1:?usage: summarize-run.sh <run-dir>}
s="$d/summary.txt"
[ -f "$s" ] || { echo "no summary.txt in $d" >&2; exit 1; }

rounds_with() { awk -v v="$1" '$1 == "round" && index($3, v) == 1 { sub(":", "", $2); print $2 }' "$s"; }
count() { rounds_with "$1" | wc -l | tr -d ' '; }
strip() { sed -E 's/^[0-9-]+ [0-9:.]+ +[0-9]+ +[0-9]+ [A-Z] //'; }

echo "rounds=$(grep -c '^round ' "$s")  clean=$(count OK)  crash=$(count CRASH)  hang(ANR)=$(count HANG)  no-answer=$(count NO-ANSWER)"

crashes=$(rounds_with CRASH)
if [ -n "$crashes" ]; then
  echo "crashes (thread | exception | first wrapper frame):"
  for n in $crashes; do
    f="$d/round-$n-crash.txt"; app="$d/round-$n-app.log"
    if grep -q 'FATAL EXCEPTION' "$f" 2>/dev/null; then
      th=$(grep -m1 'FATAL EXCEPTION' "$f" | sed 's/.*FATAL EXCEPTION: //')
      ex=$(grep -m1 -o -E '[A-Za-z.]+(Exception|Error)' "$f" | head -1)
      fr=$(grep -m1 -o -E 'MLRN[A-Za-z]+\.[A-Za-z$]+' "$f" | head -1)
    elif grep -q 'Fatal signal' "$app" 2>/dev/null; then
      th=$(grep -m1 -o -E 'in tid [0-9]+ \([^)]+\)' "$app" | sed -E 's/.*\((.*)\)/\1/')
      ex="native abort ($(grep -m1 -o -E 'JNI DETECTED ERROR IN APPLICATION: .*' "$app" | sed 's/JNI DETECTED ERROR IN APPLICATION: /JNI: /'))"
      fr=$(grep -m1 -o -E 'from [a-z]+ [A-Za-z0-9_.$]+' "$app" | awk '{print $3}')
    else
      th="?"; ex="no trace (see round-$n-app.log)"; fr="?"
    fi
    echo "  $th | $ex | $fr"
  done | sort | uniq -c | sort -rn
fi

noanswer=$(rounds_with NO-ANSWER)
if [ -n "$noanswer" ]; then
  echo "no-answer rounds, checked against the app log:"
  for n in $noanswer; do
    app="$d/round-$n-app.log"
    if grep -q 'FATAL EXCEPTION' "$app" 2>/dev/null; then
      what="crash the loop missed: $(grep -m1 -o -E '[A-Za-z.]+(Exception|Error)' "$app")"
    elif grep -q 'REPRO_DUMP' "$d/round-$n-repro.log" 2>/dev/null; then
      what="hang, watchdog thread dump in round-$n-repro.log"
    else
      what="silent after: $(tail -1 "$app" 2>/dev/null | strip | cut -c1-90)"
    fi
    echo "  round $n: $what"
  done
fi

echo "margin (libmaplibre.so nativeloader line -> first offline call):"
nums=$(grep -o 'margin: [+-][0-9]*ms' "$s" | grep -o '[+-][0-9]*' | sed 's/^+//' | sort -n)
if [ -n "$nums" ]; then
  n=$(echo "$nums" | wc -l | tr -d ' ')
  echo "  n=$n  min=$(echo "$nums" | head -1)ms  median=$(echo "$nums" | sed -n "$(( (n + 1) / 2 ))p")ms  max=$(echo "$nums" | tail -1)ms  negative=$(echo "$nums" | grep -c '^-')"
fi
echo "  rounds where the library had not loaded at all before the call: $(grep -c 'lib-not-loaded-before-call' "$s")"
