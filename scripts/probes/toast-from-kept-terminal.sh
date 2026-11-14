#!/bin/sh
# Probe for decision 0008 (its "first probe"): is a Windows toast raised by powershell.exe when it
# is started from a WSL process that lives in a kept hc terminal (no desktop session of its own)?
#
# Run on the WSL host, from a plain login shell (the person's own, with the Windows desktop on
# screen and a core reachable by hc):
#   sh scripts/probes/toast-from-kept-terminal.sh
# Takes about 15 s. Needs hc, sh, grep, sed, tr, date, mktemp. Starts one terminal,
# p335-toast, with `hc run --bg --keep`; the cleanup trap kills and removes it. Prints no secrets.
#
# It raises three toasts (A: this shell; B, B2: a kept terminal, by name and by absolute path),
# each with the Windows default sound. Watch the screen and listen for 15 s, then paste the WHOLE
# output back, plus the one thing the script cannot see: which toasts you SAW and HEARD.
#
# The PowerShell script goes in on stdin (`powershell.exe -Command -`), so no quoting crosses the
# WSL to Windows boundary; the title and body go in as environment variables named in WSLENV.
#
# Reading the output (one RESULT line per case, from the process that ran powershell.exe):
#   RESULT A, B (powershell.exe by name), B2 (by its default absolute path): ps_rc, setting, shown
#   ps_rc=0 and shown=yes   powershell.exe ran Show() without an error.
#   setting=Enabled         Windows says notifications are on for the AppId used. Anything else
#                           (DisabledForUser, DisabledByGroupPolicy, DisabledForApplication,
#                           DisabledByManifest) means the toast is swallowed on purpose.
# PASS  : B or B2 has ps_rc=0, shown=yes, setting=Enabled, AND the person saw and heard it.
# FAIL  : B and B2 both have ps_rc!=0, or setting is not Enabled, or the person saw nothing -> the WSL channel
#         is the bell and a sound (decision 0008, "What is not measured").
# B failing and B2 passing: the kept terminal only lacks /mnt/c on its PATH; the watcher calls the absolute path.
# The line "interop" says whether WSL interop is on (powershell.exe found, cmd.exe answers).

PS_SCRIPT='
$ErrorActionPreference = "Stop"
try {
  [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
  [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
  $t = [Security.SecurityElement]::Escape($env:PADDOCK_TOAST_TITLE)
  $b = [Security.SecurityElement]::Escape($env:PADDOCK_TOAST_BODY)
  $x = New-Object Windows.Data.Xml.Dom.XmlDocument
  $x.LoadXml("<toast><visual><binding template=`"ToastText02`"><text id=`"1`">$t</text><text id=`"2`">$b</text></binding></visual><audio src=`"ms-winsoundevent:Notification.Default`"/></toast>")
  $app = "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe"
  $n = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app)
  Write-Output ("setting=" + $n.Setting)
  $n.Show([Windows.UI.Notifications.ToastNotification]::new($x))
  Write-Output "shown=yes"
} catch { Write-Output ("shown=no error=" + $_.Exception.Message); exit 3 }
'

toast() { # toast <title> <body> <powershell command>: prints "ps_rc=.. setting=.. shown=.." for it
  out=$(printf '%s\n' "$PS_SCRIPT" | PADDOCK_TOAST_TITLE=$1 PADDOCK_TOAST_BODY=$2 \
        WSLENV="${WSLENV:+$WSLENV:}PADDOCK_TOAST_TITLE:PADDOCK_TOAST_BODY" \
        "$3" -NoProfile -NonInteractive -Command - 2>&1 | tr -d "\r")
  setting=$(printf '%s\n' "$out" | sed -n 's/^setting=//p' | tail -1)
  shown=$(printf '%s\n' "$out" | sed -n 's/^shown=\([a-z]*\).*/\1/p' | tail -1)
  err=$(printf '%s\n' "$out" | sed -n 's/^shown=no error=//p' | tail -1)
  raw=; [ "$shown" = yes ] || raw=" raw=$(printf '%s' "$out" | tr '\n' ' ' | head -c 160)"
  printf 'ps_rc=%s setting=%s shown=%s%s%s\n' "$([ "$shown" = yes ] && echo 0 || echo 3)" "${setting:-n/a}" "${shown:-no}" "${err:+ error=$err}" "$raw"
}

WIN_PS=/mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe

if [ "${1:-}" = --inner ]; then # runs inside the kept terminal; writes its lines to $2
  {
    echo "inner PATH has powershell.exe: $(command -v powershell.exe || echo no)"
    echo "inner PATH has /mnt/c: $(printf '%s' "$PATH" | grep -c /mnt/c)"
    echo "B  (by name): $(toast "paddock probe B (kept terminal, by name)" "powershell.exe found through PATH" powershell.exe)"
    sleep 6
    echo "B2 (absolute path): $(toast "paddock probe B2 (kept terminal, absolute path)" "called as $WIN_PS" "$WIN_PS")"
  } > "$2.tmp" 2>&1
  mv "$2.tmp" "$2"
  exit 0
fi

echo "probe: toast-from-kept-terminal, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "env: WSL_DISTRO_NAME=${WSL_DISTRO_NAME:+set} powershell.exe=$(command -v powershell.exe || echo missing) hc=$(command -v hc || echo missing) default-path-exists=$([ -x "$WIN_PS" ] && echo yes || echo no)"
if [ -x "$WIN_PS" ] || command -v powershell.exe >/dev/null 2>&1; then
  echo "interop: powershell.exe version $("$WIN_PS" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>&1 | tr -d '\r' | head -1)"
else
  echo "interop: powershell.exe not found; WSL interop is off or this is not WSL. Stopping."; exit 1
fi
command -v hc >/dev/null 2>&1 || { echo "hc not found; only case A can run"; }

echo "--- A: from this login shell"
a=$(toast "paddock probe A (login shell)" "raised from the shell that ran the probe" "$WIN_PS")
echo "RESULT A: $a"

if command -v hc >/dev/null 2>&1; then
  echo "--- B and B2: from a kept terminal"
  dir=$(mktemp -d); res=$dir/b.result
  here=$(cd "$(dirname "$0")" && pwd)
  cleanup() { hc kill p335-toast >/dev/null 2>&1; hc rm p335-toast >/dev/null 2>&1; rm -rf "$dir"; }
  trap cleanup EXIT INT TERM
  hc rm p335-toast >/dev/null 2>&1
  sleep 6 # let the first toast finish so the second is not folded into it
  if hc run --bg --keep --name p335-toast -- sh "$here/toast-from-kept-terminal.sh" --inner "$res" >/dev/null 2>"$dir/run.err"; then
    i=0; while [ ! -s "$res" ] && [ "$i" -lt 40 ]; do sleep 1; i=$((i + 1)); done
    if [ -s "$res" ]; then sed 's/^/RESULT /' "$res"; else echo "RESULT B: no answer after 40 s (terminal: $(hc get p335-toast 2>&1 | tr -d '\n' | head -c 200))"; fi
  else
    echo "RESULT B: hc run failed: $(cat "$dir/run.err")"
  fi
fi
echo "--- now report: did you SEE toast A, B, B2? did you HEAR a sound for each?"
