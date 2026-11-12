#!/bin/sh
# Issue #258: put a sample approval on the card, to look at it in herdr-app (light and dark).
# Run it as the secretary's writer, on the machine whose core holds org-state:
#
#   sh scripts/approval-card-samples.sh show full      # every context field, long text
#   sh scripts/approval-card-samples.sh show minimal   # question only, as before #258
#   sh scripts/approval-card-samples.sh show worker    # a worker's own prompt, partial context
#   sh scripts/approval-card-samples.sh restore        # put the saved org-state back
#
# `show` replaces org-state with one sample task and approval. The first `show` saves the
# current value to $PADDOCK_STATE_DIR/approval-card-samples.saved; later ones keep that copy,
# so `restore` always brings back the value from before the first `show`. Do not run it while
# the secretary is working: org-state is its document.
# Between shots, switch the theme in herdr-app: app.theme {"name":"paper"} (light) and
# app.theme {"name":"graphite"} (dark), e.g. herdr-app do app.theme '{"name":"paper"}'.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
org() { bash "$here/scripts/org" --as "${PADDOCK_SECRETARY_NAME:-secretary}" "$@"; }
state=${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}
saved=$state/approval-card-samples.saved
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
since=$(date -u -d '-25 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$now")

work='"work":[{"task_id":"paddock-258","title":"Approval card says what is being decided","since":"'$since'"}]'
case ${1:-} in
  show)
    case ${2:-} in
      full) entry='{"id":"paddock-258-sample-full","task_id":"paddock-258","question":"May I add paddock-proto3.txt at the repository root, next to README.md, so the Prototype 3 runbook has a file whose change it can follow from the worker to the pull request?","asked_at":"'$since'","answer_in":"secretary","background":"The runbook needs one small, visible change per run to check that a worker'"'"'s commit reaches the PR and CI. The worker proposed a new file at the root; nothing else in the repository depends on it, and it would be removed again at the end of Prototype 3.","if_yes":"The worker adds paddock-proto3.txt in its branch, commits it and reports done; the PR then shows one new file at the root.","if_no":"The worker writes the marker under docs/design/ instead, where run records already live, and the root stays as it is.","recommend":"no","why":"docs/design/ already holds the run records, so the marker belongs there and the root stays clean."}' ;;
      minimal) entry='{"id":"paddock-258-sample-minimal","task_id":"paddock-258","question":"May I add paddock-proto3.txt at the repository root?","asked_at":"'$since'","answer_in":"secretary"}' ;;
      worker) entry='{"id":"paddock-258-sample-worker","task_id":"paddock-258","question":"Allow the worker to run npm install with network access?","asked_at":"'$since'","answer_in":"worker","background":"The worker'"'"'s sandbox blocks the registry; its permission prompt waits in its terminal.","recommend":"yes","why":"The lockfile is pinned and the registry is the public one."}' ;;
      *) echo "usage: $0 show full|minimal|worker | restore" >&2; exit 2 ;;
    esac
    mkdir -p "$state"
    [ -f "$saved" ] || { org doc get org-state > "$saved.tmp" && mv "$saved.tmp" "$saved"; }
    printf '{%s,"approvals":[%s]}\n' "$work" "$entry" | org doc set org-state
    echo "SHOWN $2 (saved org-state: $saved)" ;;
  restore)
    [ -f "$saved" ] || { echo "nothing saved at $saved" >&2; exit 6; }
    org doc set org-state < "$saved"
    mv "$saved" "$saved.restored-$(date -u +%Y%m%dT%H%M%SZ)"
    echo "RESTORED org-state" ;;
  *) echo "usage: $0 show full|minimal|worker | restore" >&2; exit 2 ;;
esac
