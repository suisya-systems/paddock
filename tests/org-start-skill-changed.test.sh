#!/usr/bin/env bash
# Decision 0014 part 4: after a landing, org-start --place-only --from-origin prints what a changed
# skill needs. A running secretary serves the SKILL.md text it loaded (probe H4), so each changed or
# new skill gets one "skill changed: paddock:<name>" line, and one line tells the secretary to run
# /reload-plugins. A landing that touches no SKILL.md prints neither. Needs only bash, coreutils, git, tar.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
gitc() { local d=$1; shift; git -C "$d" -c user.name=t -c user.email=t@t "$@"; }

mkdir -p "$tmp/bin"
for c in hc herdr-app; do printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/$c"; done
chmod +x "$tmp/bin/"*
origin=$tmp/origin.git; root=$tmp/paddock
git init -q --bare "$origin"; git init -q -b main "$root"
cp -R "$here/templates" "$here/scripts" "$here/skills" "$here/mods" "$here/layouts" "$root/"
gitc "$root" add -A; gitc "$root" commit -qm base
git -C "$root" remote add origin "$origin"; git -C "$root" push -q origin main
land="$tmp/land"; git clone -q -b main "$origin" "$land"
benv=(PATH="$tmp/bin:$PATH" PADDOCK_STATE_DIR="$tmp/state" PADDOCK_CORE_TEMPLATES_DIR="$tmp/core/templates"
  PADDOCK_APP_MODS_DIR="$tmp/app/mods" PADDOCK_APP_LAYOUTS_DIR="$tmp/app/layouts" PADDOCK_BIN_DIR="$tmp/bin-org" CLAUDECODE=1)
place() { env "${benv[@]}" bash "$root/skills/org-start/scripts/org-start.sh" --place-only --from-origin main 2>&1; }
land_it() { gitc "$land" add -A; gitc "$land" commit -qm "$1"; git -C "$land" push -q origin HEAD:main; }
place >/dev/null

# a landing that changes no SKILL.md: no skill line, no reload line.
echo x >> "$land/skills/org-delegate/references/rationale.md"; land_it "reference only"
out=$(place)
! grep -q 'skill changed' <<<"$out" && ! grep -q '/reload-plugins' <<<"$out"; check "a landing without a SKILL.md change prints no skill line" $?

# a changed skill and a new skill.
echo "more" >> "$land/skills/org-delegate/SKILL.md"
mkdir -p "$land/skills/org-fresh"; printf -- '---\nname: org-fresh\ndescription: d\n---\n# org-fresh\n' > "$land/skills/org-fresh/SKILL.md"
land_it "skill change"
out=$(place); rc=$?
[ "$rc" -eq 0 ]; check "place-only exits 0 (rc $rc)" $?
grep -qx 'org-start: skill changed: paddock:org-delegate (invoke it again before you use it)' <<<"$out"; check "a changed skill gets its line" $?
grep -qx 'org-start: skill changed: paddock:org-fresh (invoke it again before you use it)' <<<"$out"; check "a new skill gets its line" $?
[ "$(grep -c '^org-start: skill changed:' <<<"$out")" -eq 2 ]; check "only the two changed skills are named" $?
[ "$(grep -c '/reload-plugins' <<<"$out")" -eq 1 ] && grep '/reload-plugins' <<<"$out" | grep -q 'secretary'
check "one line tells the secretary to run /reload-plugins" $?
out=$(place)
! grep -q 'skill changed' <<<"$out"; check "a second run repeats nothing" $?

# a checkout that is left alone does not change what the running plugin serves: no skill line.
echo dirty >> "$root/templates/worker.md"
echo "again" >> "$land/skills/org-delegate/SKILL.md"; land_it "skill change 2"
out=$(place)
grep -q 'left alone' <<<"$out" && ! grep -q 'skill changed' <<<"$out"; check "a checkout left alone prints no skill line" $?
exit $fail
