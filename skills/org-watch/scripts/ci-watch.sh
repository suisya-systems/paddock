#!/usr/bin/env bash
# ci-watch: one CI watch for org-watch (decision 0013). Finds the run of a PR head, watches it, reads
# its conclusion, and always writes exactly one record as watcher (ci_completed, or ci_watch_failed
# with a reason) and one line to the secretary's mailbox. org-watch starts it in the background with
# its output in watcher/ci/<pr>-<sha7>.log. Needs bash, coreutils and gh. See ../SKILL.md.
set -u

usage() {
  cat <<'USAGE'
Usage: ci-watch.sh --pr N --sha SHA --repo OWNER/NAME [--task ID] [--fail REASON]

Finds the CI run of SHA (gh run list --commit, PADDOCK_RUN_TRIES tries, default 10, every
PADDOCK_RUN_SLEEP s, default 6), runs gh run watch <run> --exit-status --interval 30, then reads
the run's conclusion (gh run view --json conclusion), so a gh error is not taken for a CI failure.
Whatever ends it, it writes one record with scripts/org --as watcher and one mailbox line to
the secretary:
  ci_completed (conclusion success or failure), or
  ci_watch_failed with reason no_run, gh_error, signal (HUP, INT, TERM) or superseded (USR1).
--fail REASON writes only ci_watch_failed with REASON (org-watch: vanished, superseded).
Its log is watcher/ci/<owner>_<name>-<pr>-<sha7>.log; it removes watcher/ci/<owner>_<name>-<pr>.pid
when that file names it.

Exit codes: 0 a result was recorded, 2 bad argument, 1 no result (ci_watch_failed was written),
129, 130, 143, 138 ended by HUP, INT, TERM, USR1 (ci_watch_failed was written).
USAGE
}

die() { echo "ci-watch: $*" >&2; exit 2; }
pr=; sha=; repo=; task=; fail=
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --pr|--sha|--repo|--task|--fail)
      [ $# -ge 2 ] || die "$1 needs a value"
      case "$1" in --pr) pr=$2 ;; --sha) sha=$2 ;; --repo) repo=$2 ;; --task) task=$2 ;; --fail) fail=$2 ;; esac
      shift 2 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
case "$pr" in ''|*[!0-9]*) die "--pr needs a number" ;; esac
case "$sha" in ''|*[!0-9a-f]*) die "--sha needs a hex commit id" ;; esac
[ -n "$repo" ] || die "--repo needs OWNER/NAME"

here=$(dirname "${BASH_SOURCE[0]}")
org=${PADDOCK_ORG:-$here/../../../scripts/org}
cidir=${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}/watcher/ci
sha7=${sha:0:7}; key=${repo//\//_}-$pr; log=$cidir/$key-$sha7.log   # <owner>_<name>-<pr>: one PR of one repository
ta=(); [ -z "$task" ] || ta=(--task "$task")
run=; code=; child=; written=

# finish <reason|ok> [conclusion]: the one record and the one mailbox line, once
finish() {
  [ -z "$written" ] || return 0; written=1
  local msg ra=() ca=()
  [ -z "$child" ] || kill "$child" 2>/dev/null
  if [ "$1" = ok ]; then
    bash "$org" --as watcher ci_completed --pr "$pr" --sha "$sha" --repo "$repo" --run-id "$run" --exit-code "$code" "${ta[@]}" \
      || echo "ci-watch: the ci_completed line could not be written"
    msg="CI $2 on PR $pr, head $sha7, run $run."
  else
    [ -z "$run" ] || ra=(--run-id "$run"); [ -z "$code" ] || ca=(--exit-code "$code")
    bash "$org" --as watcher ci_watch_failed --pr "$pr" --sha "$sha" --repo "$repo" --reason "$1" --log "$log" "${ra[@]}" "${ca[@]}" "${ta[@]}" \
      || echo "ci-watch: the ci_watch_failed line could not be written"
    msg="CI watch failed on PR $pr, head $sha7: $1 (log $log)."
  fi
  bash "$org" --as watcher send_message secretary "$msg" || echo "ci-watch: the mailbox line could not be written"
  echo "ci-watch: $(date -u +%Y-%m-%dT%H:%M:%SZ) $msg exit_code=${code:-none}"
  local p; read -r p _ < "$cidir/$key.pid" 2>/dev/null && [ "$p" = "$$" ] && rm -f "${cidir:?}/${key:?}.pid"
}
if [ -n "$fail" ]; then finish "$fail"; exit 1; fi

reason=gh_error   # what an unexpected end (an error, set -u) records
on_sig() { reason=$1; code=$2; exit "$2"; }
trap 'on_sig signal 129' HUP; trap 'on_sig signal 130' INT; trap 'on_sig signal 143' TERM
trap 'on_sig superseded 138' USR1
trap 'finish "$reason"' EXIT
# A child in the foreground would hold a trapped signal until it ends, so the long steps (the
# watch, the sleep between tries) run in the background and are waited for; wait returns on a signal.
bg() { "$@" & child=$!; wait "$child"; local r=$?; child=; return "$r"; }

echo "ci-watch: $(date -u +%Y-%m-%dT%H:%M:%SZ) PR $pr head $sha repo $repo"
tries=${PADDOCK_RUN_TRIES:-10}; rc=0
while [ "$tries" -gt 0 ]; do
  out=$(gh run list --repo "$repo" --commit "$sha" --limit 1 --json databaseId --jq '.[0].databaseId'); rc=$?
  echo "ci-watch: gh run list exit $rc: $out"
  case "$rc:$out" in 0:[0-9]*) case "$out" in *[!0-9]*) ;; *) run=$out; break ;; esac ;; esac
  tries=$((tries - 1)); [ "$tries" -le 0 ] || bg sleep "${PADDOCK_RUN_SLEEP:-6}"
done
if [ -z "$run" ]; then code=$rc; [ "$rc" -ne 0 ] || reason=no_run; exit 1; fi

bg gh run watch "$run" --repo "$repo" --exit-status --interval 30; w=$?
echo "ci-watch: gh run watch exit $w"
concl=$(gh run view "$run" --repo "$repo" --json conclusion --jq .conclusion); rc=$?
echo "ci-watch: gh run view exit $rc: $concl"
case "$rc:$concl" in
  0:success) code=0; reason=ok; trap - EXIT; finish ok success; exit 0 ;;
  0:null|0:) code=$w; exit 1 ;;   # no conclusion yet: the watch ended on a gh error
  0:*)   # failure, cancelled, timed_out, ...: not green
    code=$w; [ "$w" -ne 0 ] || code=1; trap - EXIT; finish ok failure; exit 0 ;;
  *) code=$rc; exit 1 ;;   # gh run view failed
esac
