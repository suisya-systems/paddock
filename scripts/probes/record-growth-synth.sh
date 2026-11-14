#!/bin/sh
# Issue #332: build a synthetic state folder (events/<YYYY-MM>/<writer>.jsonl) to time the readers on.
# usage: record-growth-synth.sh <out-dir> <1x|10x|p95|LINES>   (LINES = lines per month)
# 1x = 10000 lines a month (about 1.7 MB, the size Q8 measured). 10x = 100000. p95 = 30000: the busy
# month, 3x the mean, until record-growth-measure.sh has numbers from the real folder.
# Same lines for the current month and the one before it (the two the readers scan). 9 writers:
# the secretary (40% of the lines) and w-t01..w-t08. Lines are a pure function of their position, so
# the same arguments give the same folder. Needs only sh and awk.
# SYNTH_CUR=<YYYY-MM> sets the current month (default: this month, UTC).
set -u
[ $# -eq 2 ] || { echo "usage: $0 <out-dir> <1x|10x|p95|LINES>" >&2; exit 2; }
out=$1
case "$2" in
  1x) n=10000 ;; 10x) n=100000 ;; p95) n=30000 ;;
  ''|*[!0-9]*) echo "record-growth-synth: unknown size: $2 (1x, 10x, p95 or a line count)" >&2; exit 2 ;;
  *) n=$2 ;;
esac
[ "$n" -ge 20 ] || { echo "record-growth-synth: at least 20 lines a month" >&2; exit 2; }
cur=${SYNTH_CUR:-$(date -u +%Y-%m)}
case "$cur" in [0-9][0-9][0-9][0-9]-[0-9][0-9]) ;; *) echo "record-growth-synth: SYNTH_CUR is YYYY-MM" >&2; exit 2 ;; esac
y=${cur%-*}; m=$((${cur#*-} + 0 - 1)); [ "$m" -gt 0 ] || { m=12; y=$((y - 1)); }
prev=$(printf '%04d-%02d' "$y" "$m")
[ ! -e "$out/events" ] || { echo "record-growth-synth: $out/events exists; give a new folder" >&2; exit 1; }

sec=$((n * 40 / 100)); wk=$(((n - sec) / 8))
for mon in "$prev" "$cur"; do
  mkdir -p "$out/events/$mon" || exit 1
  w=0
  for who in secretary w-t01 w-t02 w-t03 w-t04 w-t05 w-t06 w-t07 w-t08; do
    cnt=$wk; [ "$who" != secretary ] || cnt=$sec
    awk -v who="$who" -v n="$cnt" -v mon="$mon" -v wk="$wk" -v widx="$w" 'BEGIN {
      fill = "filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler "
      span = 28 * 86400
      for (i = 1; i <= n; i++) {
        t = int((i - 1) * span / n); d = 1 + int(t / 86400); r = t % 86400
        ts = sprintf("%s-%02dT%02d:%02d:%02dZ", mon, d, int(r / 3600), int(r % 3600 / 60), r % 60)
        text = substr(fill, 1, 20 + (i * 7) % 90) " " i
        task = ""; to = "secretary"; kind = "message"
        if (who == "secretary") {
          k = (i - 1) % 8 + 1; w8 = sprintf("w-t%02d", k)
          if (i <= 8) { kind = "run_started"; to = w8; task = sprintf("t%02d", k); text = "started " task }
          else if (i % 10 == 0) { kind = "ack"; to = ""; text = w8 " " int(i / n * wk * 9 / 10) }
          else to = w8
        } else {
          task = sprintf("t%02d", widx)
          if (i == 1) { kind = "run_started"; to = "secretary"; text = "started" }
          else if (i == n) { kind = "run_completed"; text = "done" }
          else if (i % 5 == 0) { kind = "summary"; to = "" }
        }
        printf "{\"seq\":%d,\"ts\":\"%s\",\"from\":\"%s\",\"kind\":\"%s\",\"to\":\"%s\",\"task_id\":\"%s\",\"text\":\"%s\"}\n", i, ts, who, kind, to, task, text
      }
    }' > "$out/events/$mon/$who.jsonl" || exit 1
    w=$((w + 1))
  done
done
echo "record-growth-synth: $out ($prev and $cur, about $((n)) lines each)"
