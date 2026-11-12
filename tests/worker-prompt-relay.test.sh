#!/usr/bin/env bash
# Acceptance test for Issue #260 (L-N3 revised): a worker's prompt is answered only after a fresh
# screen read matched it. Workers run in auto mode; the secretary answers a prompt in the policy
# list (folder-trust) with org-escalation `prompt`; anything else is recorded with `ask --prompt`
# and `answer` relays the person's Yes / No as keys, only while the same prompt is on the screen.
# The secretary's own Bash cannot run `hc keys` or a forced `hc send` (a PreToolUse hook).
# Needs bash, coreutils and node (JSON.parse); hc is a stub on PATH, scripts/org is the real one.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-escalation/scripts/org-escalation.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

# ---- 1. workers run in auto mode ---------------------------------------------
cmd=$(sed -n '2,${/^---[[:space:]]*$/q;p;}' "$here/templates/worker.md" | grep -m1 '^command:')
grep -q -- '"$c" --permission-mode auto ' <<<"$cmd"; check "the worker template starts claude with --permission-mode auto" $?
sec=$(sed -n '2,${/^---[[:space:]]*$/q;p;}' "$here/templates/secretary.md" | grep -m1 '^command:')
! grep -q -- '--permission-mode' <<<"$sec"; check "the secretary keeps Claude Code's default prompts" $?

# ---- 2. the secretary's hook refuses hand-typed keys -------------------------
hook=$(node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const m = (s.hooks.PreToolUse || []).find((x) => new RegExp(x.matcher).test("Bash"));
  process.stdout.write(m ? m.hooks[0].command : "");' "$here/templates/secretary-settings.json" 2>/dev/null)
[ -n "$hook" ]; check "secretary-settings.json has a PreToolUse hook for Bash" $?
fire() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" | sh -c "$hook" >/dev/null 2>&1; }
for c in 'hc keys w-t1 enter' 'hc keys w-t1 down' '/usr/local/bin/hc keys t3 esc' 'hc send --force w-t1 yes' \
         'hc send w-t1 -f yes' 'cd /x && hc keys w-t1 enter'; do
  fire "$c"; [ $? -eq 2 ]; check "the hook refuses: $c" $?
done
for c in 'hc send w-t1 hello' 'hc read w-t1' 'hc get --json w-t1' \
         'bash skills/org-escalation/scripts/org-escalation.sh answer --id t1-20261112T000000Z --text yes' \
         'bash skills/org-escalation/scripts/org-escalation.sh prompt --task t1'; do
  fire "$c"; [ $? -eq 0 ]; check "the hook lets through: $c" $?
done

# ---- 3. stub hc ----------------------------------------------------------------
# $STUB/screen-<t>: what hc read prints; screen-<t>.down: the screen after `keys down`.
# $STUB/term-<t>: the status state (none = status null); after `keys <t> enter` the state in
# $STUB/after-enter-<t> (if any) replaces it. Every call goes to $STUB/calls.
stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB/calls"
case $1 in
  read) [ -f "$STUB/screen-$2" ] || exit 1; cat "$STUB/screen-$2"; exit 0 ;;
  keys)
    t=$2; shift 2
    for k in "$@"; do
      [ "$k" = down ] && [ -f "$STUB/screen-$t.down" ] && cp "$STUB/screen-$t.down" "$STUB/screen-$t"
      [ "$k" = enter ] && [ -f "$STUB/after-enter-$t" ] && cp "$STUB/after-enter-$t" "$STUB/term-$t"
    done
    exit 0 ;;
  send) exit 0 ;;
  get)
    for a in "$@"; do name=$a; done
    [ -f "$STUB/term-$name" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
    st=$(cat "$STUB/term-$name"); s="{\"app\":\"claude-code\",\"state\":\"$st\"}"; [ "$st" != none ] || s=null
    printf '{\n  "name": "%s",\n  "state": "live",\n  "labels": {},\n  "status": %s\n}\n' "$name" "$s"; exit 0 ;;
  connect) ;;
  *) exit 0 ;;
esac
read -r req
method=$(printf '%s' "$req" | sed 's/.*"method":"\([^"]*\)".*/\1/')
name=$(printf '%s' "$req" | sed 's/.*"name":"\([^"]*\)".*/\1/')
ver() { cat "$STUB/docver-$name" 2>/dev/null || echo 0; }
val() { cat "$STUB/docval-$name" 2>/dev/null || echo null; }
case "$method" in
  doc.get) printf '{"jsonrpc":"2.0","id":1,"result":{"value":%s,"version":%s}}\n' "$(val)" "$(ver)" ;;
  doc.set)
    v=$(printf '%s' "$req" | sed 's/.*"version":\([0-9]*\)}}$/\1/')
    printf '%s' "$req" | sed 's/.*"value":\(.*\),"version":[0-9]*}}$/\1/' > "$STUB/docval-$name"
    echo $(( v + 1 )) > "$STUB/docver-$name"
    printf '{"jsonrpc":"2.0","id":1,"result":{"version":%s}}\n' "$(ver)" ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc"
export STUB=$tmp/stub
reset() { rm -rf "$STUB"; mkdir -p "$STUB"; : > "$STUB/calls"; printf '{"work":[],"approvals":[]}\n' > "$STUB/docval-org-state"; }
esc() {
  env -u PADDOCK_ORG_ID -u PADDOCK_SECRETARY_NAME PADDOCK_HC_HOLD=0 PADDOCK_NOW=2026-11-12T01:02:03Z \
      PADDOCK_PROMPT_TRIES=3 PADDOCK_STATE_DIR="$tmp/state" PATH="$stubdir:$PATH" bash "$script" "$@" 2>&1
}
keys() { grep '^keys ' "$STUB/calls" | tr '\n' ';'; }
doc() { cat "$STUB/docval-org-state"; }

trust='
 Accessing workspace:

 /home/p/paddock-workers/proj/t1

 Quick safety check: Is this a project you created or one you trust?

 ❯ 1. No, exit
   2. Yes, I trust this folder

 Enter to confirm · Esc to cancel'
trustdown=${trust/❯ 1. No, exit/  1. No, exit}; trustdown=${trustdown/   2. Yes, I trust/ ❯ 2. Yes, I trust}
bashprompt='
 Bash command

   npm publish --registry https://example.invalid

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don'"'"'t ask again for npm publish commands in /home/p/w
   3. No, and tell Claude what to do differently (esc)'

# ---- 4. prompt: the policy list ------------------------------------------------
reset; printf '%s\n' "$trust" > "$STUB/screen-w-t1"; printf '%s\n' "$trustdown" > "$STUB/screen-w-t1.down"
echo none > "$STUB/term-w-t1"; echo idle > "$STUB/after-enter-w-t1"
out=$(esc prompt --task t1 --then-send "Your org id is w-t1."); rc=$?
[ $rc -eq 0 ]; check "folder-trust: prompt exits 0 ($out)" $?
grep -q 'folder-trust' <<<"$out"; check "folder-trust: the output names the policy entry" $?
[ "$(keys)" = "keys w-t1 down;keys w-t1 enter;" ]; check "folder-trust: down, then enter, nothing else ($(keys))" $?
awk '/^keys w-t1 down/{d=NR} /^read w-t1/{if(d&&!r)r=NR} /^keys w-t1 enter/{e=NR} END{exit !(d&&r&&e&&d<r&&r<e)}' "$STUB/calls"
check "folder-trust: the screen is read again between down and enter" $?
grep -q '^send w-t1 Your org id is w-t1\.' "$STUB/calls"; check "folder-trust: --then-send sends the first message once the terminal reports a status" $?

reset; printf '%s\n' "$trust" > "$STUB/screen-w-t1"; echo none > "$STUB/term-w-t1"   # down does not move the cursor
out=$(esc prompt --task t1); rc=$?
[ $rc -eq 10 ]; check "folder-trust, cursor not on Yes after down: exit 10 ($rc)" $?
! grep -q '^keys w-t1 enter' "$STUB/calls"; check "folder-trust, cursor not on Yes: enter is never pressed" $?

# ---- 5. prompt: outside the policy ----------------------------------------------
reset; printf '%s\n' "$bashprompt" > "$STUB/screen-w-t2"; echo blocked > "$STUB/term-w-t2"
out=$(esc prompt --task t2); rc=$?
[ $rc -eq 3 ]; check "a tool prompt is outside the policy: exit 3 ($rc)" $?
grep -q '^PROMPT=.*npm publish.*Do you want to proceed' <<<"$out"; check "it prints the prompt it read" $?
[ -z "$(keys)" ]; check "outside the policy: no key is pressed" $?
reset; out=$(esc prompt --task t9); rc=$?
[ $rc -eq 11 ] && [ -z "$(keys)" ]; check "an unreadable screen: exit 11, no key ($rc)" $?

# ---- 6. ask --prompt, then answer relays Yes / No ---------------------------------
reset; printf '%s\n' "$bashprompt" > "$STUB/screen-w-t2"
ptext=$(esc prompt --task t2 | sed -n 's/^PROMPT=//p')
[ -n "$ptext" ]; check "the PROMPT line has text" $?
ask() { esc ask --task t2 --question "Let t2 run npm publish?" --prompt "$ptext" --background "b" \
          --if-yes "y" --if-no "n" --recommend no --why "w" | sed -n 's/^APPROVAL_ID=//p'; }
setup() { reset; printf '%s\n' "$bashprompt" > "$STUB/screen-w-t2"; echo blocked > "$STUB/term-w-t2"; id=$(ask); }

setup
[ -n "$id" ]; check "ask --prompt records an entry ($id)" $?
case $(doc) in *'"prompt":"'*'npm publish'*) r=0 ;; *) r=1 ;; esac; check "the entry holds the prompt text" $r
case $(doc) in *'"answer_in":"worker"'*) r=1 ;; *) r=0 ;; esac; check "the entry is not answer_in worker" $r
out=$(esc answer --id "$id" --text yes); rc=$?
[ $rc -eq 0 ]; check "answer yes on a prompt entry exits 0 ($out)" $?
[ "$(keys)" = "keys w-t2 enter;" ]; check "yes: one enter on '1. Yes' ($(keys))" $?
case $(doc) in *"$id"*) r=1 ;; *) r=0 ;; esac; check "yes: the entry is removed" $r

setup; out=$(esc answer --id "$id" --text no); rc=$?
[ $rc -eq 0 ] && [ "$(keys)" = "keys w-t2 esc;" ]; check "no: one esc ($(keys))" $?

setup; printf '%s\n' "${bashprompt/npm publish --registry/rm -rf}" > "$STUB/screen-w-t2"
out=$(esc answer --id "$id" --text yes); rc=$?
[ $rc -eq 10 ] && [ -z "$(keys)" ]; check "a different prompt on the screen: exit 10, nothing pressed ($rc)" $?
case $(doc) in *"$id"*) r=0 ;; *) r=1 ;; esac; check "a different prompt: the entry is kept" $r

setup; echo working > "$STUB/term-w-t2"
out=$(esc answer --id "$id" --text yes); rc=$?
[ $rc -eq 10 ] && [ -z "$(keys)" ]; check "the terminal is no longer blocked: exit 10, nothing pressed ($rc)" $?

setup; out=$(esc answer --id "$id" --text "only on Tuesdays"); rc=$?
[ $rc -eq 2 ] && [ -z "$(keys)" ]; check "free text on a prompt entry: exit 2, nothing pressed ($rc)" $?

setup; rm -f "$STUB/screen-w-t2"
out=$(esc answer --id "$id" --text yes); rc=$?
[ $rc -eq 10 ] && [ -z "$(keys)" ]; check "an unreadable screen: exit 10, nothing pressed ($rc)" $?

# ---- 7. answer_in worker is gone -----------------------------------------------
reset; out=$(esc ask --task t3 --question "Allow it?" --answer-in worker); rc=$?
[ $rc -eq 2 ]; check "ask --answer-in is refused (exit 2)" $?
! grep -q 'answer_in === "worker"' "$here/mods/org-cockpit/main.js"; check "the card has no answer_in worker branch" $?
! grep -q 'answer-in worker' "$here/templates/secretary.md"; check "the secretary template no longer records --answer-in worker" $?

[ "$fail" -eq 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
