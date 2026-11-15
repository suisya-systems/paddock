#!/usr/bin/env bash
# After a landing that changes a placed file, the bin copy equals main with nobody typing:
# org-pull-request (acceptance) merges and runs org-start --place-only --from-origin main, which
# fetches and places origin/main and starts nothing (the stub hc records no call at all).
# A copy of this checkout is the paddock folder; a local bare repository stands in for origin.
# Needs only bash, coreutils, git and tar.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
gitc() { local d=$1; shift; git -C "$d" -c user.name=t -c user.email=t@t "$@"; }

# stubs: hc and herdr-app record every call; gh merges by pushing the landed commit to origin main.
mkdir -p "$tmp/bin" "$tmp/stub"; : > "$tmp/stub/calls"
for c in hc herdr-app; do printf '#!/bin/sh\necho "%s $*" >> "$STUB/calls"\nexit 0\n' "$c" > "$tmp/bin/$c"; done
cat > "$tmp/bin/gh" <<'EOF2'
#!/bin/sh
echo "gh $*" >> "$STUB/calls"
case "$1 $2" in
  "pr view") case "$*" in *baseRefName*) echo main ;; *) cat "$STUB/head" ;; esac ;;
  "pr merge") git -C "$STUB/land" push -q origin HEAD:main || exit 1 ;;
esac
exit 0
EOF2
chmod +x "$tmp/bin/"*

# the paddock folder: this checkout's files, committed on main and pushed to a bare origin.
origin=$tmp/origin.git; root=$tmp/paddock
git init -q --bare "$origin"; git init -q -b main "$root"
cp -R "$here/templates" "$here/scripts" "$here/skills" "$here/mods" "$here/layouts" "$root/"
gitc "$root" add -A; gitc "$root" commit -qm base
git -C "$root" remote add origin "$origin"; git -C "$root" push -q origin main
# the worker's worktree shares the paddock folder's git store (as org-delegate cuts it).
wt=$tmp/wt; git -C "$root" worktree add -q -b feat/x "$wt"
printf '{"hooks":{}}\n' > "$wt/templates/secretary-settings.json"
gitc "$wt" commit -qam "change secretary-settings"
git -C "$wt" rev-parse HEAD > "$tmp/stub/head"; head=$(cat "$tmp/stub/head")
# the squash merge GitHub would make: main plus the same change.
git clone -q -b main "$origin" "$tmp/stub/land"
cp "$wt/templates/secretary-settings.json" "$tmp/stub/land/templates/"
gitc "$tmp/stub/land" commit -qam "squash"

st=$tmp/state; binorg=$tmp/bin-org
benv=(STUB="$tmp/stub" PATH="$tmp/bin:$PATH" PADDOCK_STATE_DIR="$st" PADDOCK_ORG_CONFIG_FILE="$tmp/none.md"
  PADDOCK_CORE_TEMPLATES_DIR="$tmp/core/templates" PADDOCK_APP_MODS_DIR="$tmp/app/mods"
  PADDOCK_APP_LAYOUTS_DIR="$tmp/app/layouts" PADDOCK_BIN_DIR="$binorg" CLAUDECODE=1)
# an earlier org-start placed the old files.
env "${benv[@]}" bash "$root/skills/org-start/scripts/org-start.sh" --place-only >/dev/null 2>&1
check "place-only runs with CLAUDECODE set (inside an agent)" $?
cmp -s "$root/templates/secretary-settings.json" "$binorg/secretary-settings.json"; check "the old settings are placed" $?

# CI green on the head, as the secretary and the watcher record it.
env -u PADDOCK_NOW PADDOCK_STATE_DIR="$st" bash "$root/scripts/org" --as secretary ci_requested --pr 42 --sha "$head" --repo o/r >/dev/null
sleep 1
env -u PADDOCK_NOW PADDOCK_STATE_DIR="$st" bash "$root/scripts/org" --as watcher ci_completed --pr 42 --sha "$head" --repo o/r --run-id 7 --exit-code 0 >/dev/null
out=$(env "${benv[@]}" bash "$root/skills/org-pull-request/scripts/org-pull-request.sh" --worktree "$wt" --repo o/r --pr 42 --mode acceptance 2>&1); rc=$?
[ "$rc" -eq 0 ]; check "acceptance merge exits 0 (rc $rc)" $?
git -C "$root" show refs/remotes/origin/main:templates/secretary-settings.json > "$tmp/main.json"
! cmp -s "$root/templates/secretary-settings.json" "$tmp/main.json" && cmp -s "$tmp/main.json" "$binorg/secretary-settings.json"; check "after the landing the bin copy equals main" $?
grep -q 'changed:.*secretary-settings.json' <<<"$out"; check "the output names the changed file" $?
! grep -q 'RENEWAL NEEDED' <<<"$out"; check "no renewal asked for a settings change" $?
! grep -Eq '^(hc|herdr-app) ' "$tmp/stub/calls"; check "place-only made no hc or herdr-app call (no run, no server)" $?

# the command the secretary runs after its own merge (human mode): a template body change asks for renewal.
echo "landed" >> "$tmp/stub/land/templates/secretary.md"; gitc "$tmp/stub/land" commit -qam body
git -C "$tmp/stub/land" push -q origin HEAD:main
out=$(env "${benv[@]}" bash "$root/skills/org-start/scripts/org-start.sh" --place-only --from-origin main 2>&1); rc=$?
[ "$rc" -eq 0 ] && cmp -s "$tmp/stub/land/templates/secretary.md" "$tmp/core/templates/secretary.md"
check "place-only --from-origin main places the landed template" $?
grep -q 'RENEWAL NEEDED' <<<"$out"; check "a secretary.md change asks for a renewal" $?
out=$(env "${benv[@]}" bash "$root/skills/org-start/scripts/org-start.sh" --place-only --from-origin main 2>&1)
grep -q 'nothing changed' <<<"$out"; check "a second run changes nothing" $?
! grep -Eq '^(hc|herdr-app) ' "$tmp/stub/calls"; check "still no hc or herdr-app call" $?
env "${benv[@]}" bash "$root/skills/org-start/scripts/org-start.sh" --from-origin main >/dev/null 2>&1
[ $? -eq 2 ]; check "--from-origin without --place-only exits 2" $?
exit $fail
