#!/usr/bin/env bash
# org-issue: open a GitHub issue whose body is built here, so the dependency line is always one
# line at the end. Needs bash and gh. See ../SKILL.md. Run it from the secretary.
set -u

usage() {
  cat <<'USAGE'
Usage: org-issue.sh --repo OWNER/NAME --kind decide|build|followup --title TITLE --goal CLAUSE
                    [--depends N]... <section options of the kind>

Kinds and their sections (all required; each text is the option's value):
  decide    --question, --known (What we know, with sources), --options, --done
  build     --why, --done
  followup  --seen (What was seen), --ask
Every kind ends with the Goal clause (--goal, for example "G2 Permissions and hooks ...").

--depends N may be given 0 or more times; N must be an issue that exists in --repo, once each.
When there is any, the last line of the body is "Depends on #N #M" (one line).
Nothing is created unless every check passes. Prints the issue URL.

Exit codes: 0 opened, 2 bad argument or missing section, 3 gh not found,
4 a dependency does not exist in the repository, 6 the issue could not be created.
USAGE
}

die() { code=$1; shift; echo "org-issue: $*" >&2; exit "$code"; }

repo=; kind=; title=; goal=; deps=
question=; known=; options=; why=; seen=; ask=; done_=
set_question=; set_known=; set_options=; set_why=; set_seen=; set_ask=; set_done=
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --repo|--kind|--title|--goal|--depends|--question|--known|--options|--why|--seen|--ask|--done)
      [ $# -ge 2 ] || die 2 "$1 needs a value"
      case $1 in
        --repo) repo=$2 ;; --kind) kind=$2 ;; --title) title=$2 ;; --goal) goal=$2 ;;
        --depends) deps="$deps $2" ;;
        --question) question=$2; set_question=1 ;; --known) known=$2; set_known=1 ;;
        --options) options=$2; set_options=1 ;; --why) why=$2; set_why=1 ;;
        --seen) seen=$2; set_seen=1 ;; --ask) ask=$2; set_ask=1 ;; --done) done_=$2; set_done=1 ;;
      esac
      shift 2 ;;
    *) echo "org-issue: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case $repo in */*) ;; *) die 2 "--repo OWNER/NAME is required" ;; esac
[ -n "$title" ] || die 2 "--title is required"
[ -n "$goal" ] || die 2 "--goal is required (the Goal clause section)"

# Sections of the kind, in order: "<flag>|<heading>|<value>". Headings equal the ones in
# .github/ISSUE_TEMPLATE/issue.md.
case $kind in
  decide)   allowed="question known options done"
            sections=("question|Question|$question" "known|What we know (with sources)|$known" "options|Options|$options" "done|Definition of done|$done_") ;;
  build)    allowed="why done"
            sections=("why|Why|$why" "done|Definition of done|$done_") ;;
  followup) allowed="seen ask"
            sections=("seen|What was seen|$seen" "ask|Ask|$ask") ;;
  *) die 2 "--kind must be decide, build or followup" ;;
esac

# A section option that does not belong to the kind is an error, not silently dropped.
for f in question known options why seen ask done; do
  v=set_$f
  [ -z "${!v}" ] && continue
  case " $allowed " in *" $f "*) ;; *) die 2 "--$f is not a section of kind $kind" ;; esac
done

body=
for s in "${sections[@]}"; do
  flag=${s%%|*}; rest=${s#*|}; heading=${rest%%|*}; text=${rest#*|}
  [ -n "$text" ] || die 2 "section '$heading' (--$flag) is required for kind $kind"
  body+="## $heading"$'\n\n'"$text"$'\n\n'
done
case $goal in "- "*) goalline=$goal ;; *) goalline="- $goal" ;; esac
body+="## Goal clause"$'\n\n'"$goalline"$'\n'

command -v gh >/dev/null 2>&1 || die 3 "gh not found"

# Dependencies: numbers, once each, and existing. A self-dependency cannot be written: the
# issue has no number yet.
line=
for d in $deps; do
  case $d in ""|*[!0-9]*) die 2 "--depends must be an issue number: $d" ;; esac
  case " ${seen_deps:-} " in *" $d "*) die 2 "--depends $d given twice" ;; esac
  seen_deps="${seen_deps:-} $d"
  gh issue view "$d" --repo "$repo" >/dev/null 2>&1 || die 4 "issue #$d does not exist in $repo"
  line="$line #$d"
done
[ -z "$line" ] || body+=$'\n'"Depends on${line}"$'\n'

tmp=$(mktemp) || die 6 "cannot make a temporary file"
trap 'rm -f "$tmp"' EXIT
printf '%s' "$body" > "$tmp"
gh issue create --repo "$repo" --title "$title" --body-file "$tmp" || die 6 "gh issue create failed"
