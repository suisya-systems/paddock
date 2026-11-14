#!/bin/sh
# Issue #332: lines and bytes per round per writer, from a state folder. READ-ONLY: it opens
# <state-dir>/events/*/*.jsonl for reading and writes nothing; it does not call hc.
# usage: record-growth-measure.sh [state-dir]   (default: $PADDOCK_STATE_DIR, else $XDG_STATE_HOME or ~/.local/state, then paddock)
# A round is one task: the lines that carry its task_id, from every writer (run_started ..
# run_completed, with the messages and summaries between). Lines with no task_id are "no-task".
# Output is tab-separated: scope, key, lines, bytes, rounds. Scopes:
#   total all                           everything under events/
#   month (month)                     rounds = run_started lines in that month
#   writer (writer)                     over all months; the writer is the file's name
#   writer-month (month)/(writer)
#   kind (kind)
#   no-task all                         lines with an empty task_id
#   round (task_id)                     lines and bytes of the round, over every writer
#   round-stat mean|p95|max             over rounds: lines, bytes
#   round-writer (writer)               per round the writer took part in: mean lines, mean bytes; rounds = how many
# Bytes are line length plus the newline, counted in the C locale. Needs only sh, awk and sort.
set -u
LC_ALL=C; export LC_ALL
d=${1:-${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}}
[ -d "$d/events" ] || { echo "record-growth-measure: no $d/events" >&2; exit 1; }
# the awk program has no output redirect so that a reader of this file can see at a glance that nothing is written
set -- "$d"/events/*/*.jsonl
[ -f "$1" ] || { echo "record-growth-measure: no events/*/*.jsonl under $d" >&2; exit 1; }
awk '
  function field(name,   pat) {
    pat = "\"" name "\":\"[^\"]*\""
    if (!match($0, pat)) return ""
    return substr($0, RSTART + length(name) + 4, RLENGTH - length(name) - 5)
  }
  BEGIN { OFS = "\t" }
  {
    n = split(FILENAME, p, "/"); w = p[n]; sub(/\.jsonl$/, "", w); mon = p[n - 1]
    b = length($0) + 1; k = field("kind"); t = field("task_id")
    tl += 1; tb += b
    ml[mon] += 1; mb[mon] += b
    wl[w] += 1; wb[w] += b
    wml[mon "/" w] += 1; wmb[mon "/" w] += b
    kl[k] += 1; kb[k] += b
    if (k == "run_started") { mr[mon] += 1; tr += 1 }
    if (t == "") { nl += 1; nb += b }
    else { rl[t] += 1; rb[t] += b; tw = t SUBSEP w; rwl[tw] += 1; rwb[tw] += b }
  }
  END {
    print "total", "all", tl + 0, tb + 0, tr + 0
    for (x in ml) print "month", x, ml[x], mb[x], mr[x] + 0
    for (x in wl) print "writer", x, wl[x], wb[x], ""
    for (x in wml) print "writer-month", x, wml[x], wmb[x], ""
    for (x in kl) print "kind", x, kl[x], kb[x], ""
    print "no-task", "all", nl + 0, nb + 0, ""
    for (x in rl) {
      print "round", x, rl[x], rb[x], ""
      nr += 1; sl += rl[x]; sb += rb[x]
      if (lmax < rl[x]) lmax = rl[x]
      if (bmax < rb[x]) bmax = rb[x]
      i = nr; while (1 < i && rl[x] < ls[i - 1]) { ls[i] = ls[i - 1]; i-- } ls[i] = rl[x]
      j = nr; while (1 < j && rb[x] < bs[j - 1]) { bs[j] = bs[j - 1]; j-- } bs[j] = rb[x]
    }
    if (nr) {
      q = int(nr * 95 / 100); if (q * 100 < nr * 95) q += 1; if (q < 1) q = 1
      print "round-stat", "mean", int(sl / nr), int(sb / nr), nr
      print "round-stat", "p95", ls[q], bs[q], nr
      print "round-stat", "max", lmax, bmax, nr
    }
    for (x in rwl) { split(x, a, SUBSEP); ww = a[2]; wr[ww] += 1; wsl[ww] += rwl[x]; wsb[ww] += rwb[x] }
    for (x in wr) print "round-writer", x, int(wsl[x] / wr[x]), int(wsb[x] / wr[x]), wr[x]
  }' "$@" | sort -t "	" -k1,1 -k2,2
