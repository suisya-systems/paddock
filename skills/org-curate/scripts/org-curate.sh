#!/usr/bin/env bash
# org-curate: the shell parts of growth through skills (decision 0009). Needs only bash, coreutils,
# awk and grep. See ../SKILL.md. Notes live under $PADDOCK_STATE_DIR/knowledge/.
set -u
export LC_ALL=C

usage() {
  cat <<'USAGE'
Usage: org-curate.sh <command> [options]

  save --task <task_id> --topic <kebab-topic>   read a raw note on stdin (the four headings),
                                                write knowledge/raw/<date>-<topic>.md
  count                                         print the unreviewed raw note and pending candidate
                                                counts; at 5 of either, a line says to start the curator
  candidates                                    print the patterns of knowledge/curated/ that pass
                                                both gates and are not in the queue yet
  finish                                        touch knowledge/last-curated (end of a curator cycle)
  settings                                      write the curator's per-run settings file,
                                                <state>/settings/curator.json, and print its path
  start                                         write it, then start the curator (hc run)
  chain --pattern <p> --skill <s> [--repo <dir>] check links 1 to 4 of the acceptance chain

Environment: PADDOCK_STATE_DIR (default $XDG_STATE_HOME/paddock); settings and start need the core's
socket folder (PADDOCK_CORE_SOCKET_DIR, else the folder of HC_TERMINAL_SOCKET).
Exit codes: 0 ok, 1 a check failed, 2 bad argument or note, 4 the note file already exists.
USAGE
}
die() { code=$1; shift; echo "org-curate: $*" >&2; exit "$code"; }

state=${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}
k=$state/knowledge
queue=$k/skill-candidates.md

# gate <curated file>: print "<ntasks> <files>" over the listed notes that exist (raw/ or raw/archive/);
# the notes are the "- raw/<file>" lines. Nothing is printed for a curated note without a one-sentence
# "When:" line. Tasks are the "Task:" lines of the notes.
gate() {
  local c=$1 w f b tasks n files=
  w=$(sed -n 's/^When:[[:space:]]*//p' "$c" | head -1)
  [ -n "$w" ] && ! grep -qE '[.!?][[:space:]]+[^[:space:]]' <<<"$w" && [ "${#w}" -le 300 ] || return 1
  tasks=
  while IFS= read -r f; do
    # a note that moved to raw/archive/ is still found by its file name
    b=${f##*/}; f=raw/$b; [ -f "$k/$f" ] || f=raw/archive/$b
    [ -f "$k/$f" ] || continue
    files="$files $f"
    tasks="$tasks
$(sed -n 's/^Task:[[:space:]]*//p' "$k/$f" | head -1)"
  done < <(sed -n 's/^- \(raw\/[^[:space:]]*\.md\)[[:space:]]*$/\1/p' "$c")
  n=$(printf '%s\n' "$tasks" | grep -v '^$' | sort -u | wc -l)
  printf '%s%s\n' "$n" "$files"
}
# field <pattern> <field>: the value of "- **field**: v" in the queue entry of the pattern.
field() {
  awk -v p="$1" -v f="$2" '
    /^- \*\*pattern\*\*:/ { v = $0; sub(/^- \*\*pattern\*\*:[ ]*/, "", v); on = (v == p) }
    on && index($0, "- **" f "**:") == 1 { v = $0; sub(/^- \*\*[a-z]+\*\*:[ ]*/, "", v); print v; exit }' "$queue" 2>/dev/null
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
  -h|--help|help) usage; exit 0 ;;

  save)
    task= topic=
    while [ $# -gt 0 ]; do
      case "$1" in
        --task) [ $# -ge 2 ] || die 2 "--task needs a value"; task=$2; shift 2 ;;
        --topic) [ $# -ge 2 ] || die 2 "--topic needs a value"; topic=$2; shift 2 ;;
        *) die 2 "unknown argument: $1" ;;
      esac
    done
    case "$task" in ''|-*|*[!a-z0-9_-]*) die 2 "--task <task_id> is required: lowercase letters, digits, _ and -" ;; esac
    case "$topic" in ''|-*|*-|*--*|*[!a-z0-9-]*) die 2 "--topic must be English kebab-case (a-z, 0-9, -)" ;; esac
    body=$(cat)
    for h in Facts Judgment Grounds 'Where it applies'; do
      grep -qx "## $h" <<<"$body" || die 2 "the note lacks the heading '## $h'"
    done
    mkdir -p "$k/raw" || die 2 "cannot create $k/raw"
    f=$k/raw/$(date +%F)-$topic.md
    # names are looked up in both folders by file name, so one that is archived counts as taken
    { [ -e "$f" ] || [ -e "$k/raw/archive/${f##*/}" ]; } && die 4 "${f##*/} already exists (raw/ or raw/archive/); it is never overwritten"
    ( set -C; printf 'Task: %s\n\n%s\n' "$task" "$body" > "$f" ) 2>/dev/null || die 4 "$f already exists"
    echo "org-curate: saved $f"
    ;;

  count)
    n=0
    if [ -d "$k/raw" ]; then
      if [ -f "$k/last-curated" ]; then
        n=$(find "$k/raw" -maxdepth 1 -name '*.md' -newer "$k/last-curated" | wc -l)
      else
        n=$(find "$k/raw" -maxdepth 1 -name '*.md' | wc -l)
      fi
    fi
    m=$(grep -c '^- \*\*status\*\*: pending' "$queue" 2>/dev/null); m=${m:-0}
    n=$((n + 0)); m=$((m + 0))
    echo "org-curate: $n unreviewed raw notes, $m pending candidates"
    if [ "$n" -ge 5 ] || [ "$m" -ge 5 ]; then
      echo "org-curate: start the curator: bash skills/org-curate/scripts/org-curate.sh start (it reads every kept note)"
    fi
    ;;

  candidates)
    for c in "$k"/curated/*.md; do
      [ -f "$c" ] || continue
      p=$(basename "$c" .md)
      grep -qxF -- "- **pattern**: $p" "$queue" 2>/dev/null && continue
      g=$(gate "$c") || continue
      n=${g%% *}; [ "$n" -ge 3 ] || continue
      printf '%s\t%s\t%s\n' "$p" "$n" "${g#* }"
    done
    ;;

  finish)
    mkdir -p "$k" && touch "$k/last-curated" || die 2 "cannot touch $k/last-curated"
    echo "org-curate: touched $k/last-curated"
    ;;

  chain)
    p= s= repo=
    while [ $# -gt 0 ]; do
      case "$1" in
        --pattern) [ $# -ge 2 ] || die 2 "--pattern needs a value"; p=$2; shift 2 ;;
        --skill) [ $# -ge 2 ] || die 2 "--skill needs a value"; s=$2; shift 2 ;;
        --repo) [ $# -ge 2 ] || die 2 "--repo needs a value"; repo=$2; shift 2 ;;
        *) die 2 "unknown argument: $1" ;;
      esac
    done
    [ -n "$p" ] && [ -n "$s" ] || die 2 "--pattern and --skill are required"
    repo=${repo:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
    bad() { echo "org-curate: link $1 FAILED: $2" >&2; exit 1; }
    # 1. Records: 3+ notes from 3+ different tasks name the pattern, with a one-sentence trigger.
    g=$(gate "$k/curated/$p.md" 2>/dev/null) || bad 1 "no curated note $p with a one-sentence 'When:' line"
    [ "${g%% *}" -ge 3 ] || bad 1 "only ${g%% *} different tasks among the notes of $p (need 3)"
    files=${g#* }
    echo "org-curate: link 1 ok: notes from ${g%% *} tasks"
    # 2. Candidate: one entry lists those files and has the trigger.
    [ -n "$(field "$p" pattern)" ] || bad 2 "no queue entry for $p in $queue"
    notes=$(field "$p" notes)
    # The evidence is what the entry recorded (later cycles may add notes to the pattern without
    # changing a queued entry): its listed notes must exist and come from 3 or more different tasks.
    files=; ntasks=$(
      for x in $notes; do b=${x##*/}; f=raw/$b; [ -f "$k/$f" ] || f=raw/archive/$b
        [ -f "$k/$f" ] || { echo "MISSING $b"; continue; }
        sed -n "s/^Task:[[:space:]]*//p" "$k/$f" | head -1; done | sort -u)
    case "$ntasks" in *MISSING*) bad 2 "the entry lists a note that does not exist: $(grep MISSING <<<"$ntasks" | head -1)" ;; esac
    [ "$(grep -c . <<<"$ntasks")" -ge 3 ] || bad 2 "the entry lists notes from fewer than 3 different tasks"
    files=; for x in $notes; do files="$files ${x##*/}"; done
    w=$(field "$p" when); [ -n "$w" ] && ! grep -qE "[.!?][[:space:]]+[^[:space:]]" <<<"$w" || bad 2 "the entry has no trigger, or it is more than one sentence"
    echo "org-curate: link 2 ok: queue entry lists the notes and the trigger"
    # 3. Decision: approved, with a decision date.
    [ "$(field "$p" status)" = approved ] || bad 3 "the entry's status is '$(field "$p" status)', not approved"
    grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' <<<"$(field "$p" decided)" || bad 3 "the entry has no decision date"
    [ "$(field "$p" skill)" = "$s" ] || bad 3 "the approved entry is for skill '$(field "$p" skill)', not '$s'"
    echo "org-curate: link 3 ok: approved on $(field "$p" decided)"
    # 4. Skill: folder from the template, self-contained, rationale names the raw notes.
    d=$repo/skills/$s
    [ -f "$d/SKILL.md" ] || bad 4 "$d/SKILL.md is missing"
    [ "$(sed -n 's/^name:[[:space:]]*//p' "$d/SKILL.md" | head -1)" = "$s" ] || bad 4 "front matter name is not '$s'"
    [ -n "$(sed -n 's/^description:[[:space:]]*//p' "$d/SKILL.md" | head -1)" ] || bad 4 "front matter has no description"
    [ -f "$d/references/rationale.md" ] || bad 4 "$d/references/rationale.md is missing"
    for f in $files; do grep -qF "$(basename "$f")" "$d/references/rationale.md" || bad 4 "rationale.md does not name $(basename "$f")"; done
    # The same two rules as tests/skill-selfcontained.test.sh (the full test covers the real skills/).
    if grep -rnE --include='*.md' '(^|[^A-Za-z0-9_&/-])#[0-9]+([^0-9A-Za-z-]|$)|https?://|/(issues|pull)/[0-9]+|\b(Issue|PR) ?[0-9]+' "$d" >/dev/null; then
      bad 4 "an Issue number or URL in $d"
    fi
    echo "org-curate: link 4 ok: skills/$s"
    echo "org-curate: chain links 1 to 4 hold for $p"
    ;;

  settings|start)
    # The curator's write limit is held by its own --settings file, as a worker's is by
    # org-delegate's per-task file: ../curator-settings.json with allowWrite naming knowledge/
    # and the curator's own mail files (scripts/org own_files), the core's socket folder denied, and
    # PADDOCK_STATE_DIR pinned. Written to <state>/settings/curator.json, outside what it allows.
    root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
    if [ -n "${PADDOCK_CORE_SOCKET_DIR:-}" ]; then sock=$PADDOCK_CORE_SOCKET_DIR
    elif [ -n "${HC_TERMINAL_SOCKET:-}" ]; then sock=$(dirname "$HC_TERMINAL_SOCKET")
    else die 2 "cannot tell the core's socket folder: run from a core terminal (HC_TERMINAL_SOCKET) or set PADDOCK_CORE_SOCKET_DIR"; fi
    for p in "$state" "$sock"; do
      case "$p" in /*) ;; *) die 2 "not an absolute path: $p" ;; esac
      case "$p" in *[\"\\]*|*[[:cntrl:]]*) die 2 "a path with a quote, backslash or control character cannot go into the settings: $p" ;; esac
    done
    tpl=$(cat "$(dirname "${BASH_SOURCE[0]}")/../curator-settings.json") || die 2 "cannot read curator-settings.json beside scripts/"
    for x in '"allowWrite": []' '"denyRead": [' '"denyWrite": ['; do
      [ "$(grep -cF "$x" <<<"$tpl")" = 1 ] || die 2 "curator-settings.json must hold exactly one $x"
    done
    mkdir -p "$k" || die 2 "cannot create $k"
    own=$(PADDOCK_STATE_DIR=$state bash "$root/scripts/org" --as secretary own_files curator 2>&1) \
      || die 2 "cannot create the curator's own files: $own"
    list="\"$k\""
    while IFS= read -r p; do list="$list,\"$p\""; done <<<"$own"
    tpl=${tpl/'"allowWrite": []'/"\"allowWrite\": [$list]"}
    tpl=${tpl/'"denyRead": ['/"\"denyRead\": [\"$sock\","}
    tpl=${tpl/'"denyWrite": ['/"\"denyWrite\": [\"$sock\","}
    tpl="{\"env\": {\"PADDOCK_STATE_DIR\": \"$state\"},${tpl#\{}"
    cs=$state/settings/curator.json
    { mkdir -p "$state/settings" && printf '%s\n' "$tpl" > "$cs.tmp" && mv -f "$cs.tmp" "$cs"; } 2>/dev/null \
      || die 2 "cannot write $cs"
    if [ "$cmd" = settings ]; then echo "$cs"; exit 0; fi
    self=$root/skills/org-curate/scripts/org-curate.sh
    hc run --bg --name curator curator "Your org-curate script is $self: run it as bash $self candidates and bash $self finish." \
      || die 2 "hc run of the curator failed"
    ;;

  *) usage >&2; exit 2 ;;
esac
