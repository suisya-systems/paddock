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
# It raises two toasts, "paddock probe A (login shell)" and "paddock probe B (kept terminal)",
# each with the Windows default sound. Watch the screen and listen for 15 s, then paste the WHOLE
# output back, plus the one thing the script cannot see: which toasts you SAW and HEARD.
#
# The PowerShell script goes in on stdin (`powershell.exe -Command -`), so no quoting crosses the
# WSL to Windows boundary; the title and body go in as environment variables named in WSLENV.
#
# Reading the output (one RESULT line per case, from the process that ran powershell.exe):
#   RESULT A|B: ps_rc=<exit status> setting=<Enabled | Disabled... | n/a> shown=<yes|no>
#   ps_rc=0 and shown=yes   powershell.exe ran Show() without an error.
#   setting=Enabled         Windows says notifications are on for the AppId used. Anything else
#                           (DisabledForUser, DisabledByGroupPolicy, DisabledForApplication,
#                           DisabledByManifest) means the toast is swallowed on purpose.
# PASS  : B has ps_rc=0, shown=yes, setting=Enabled, AND the person saw and heard it.
# FAIL  : B has ps_rc!=0, or setting is not Enabled, or the person saw nothing -> the WSL channel
#         is the bell and a sound (decision 0008, "What is not measured").
# A alone passing and B failing means a kept terminal has no desktop reach.
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

toast() { # toast <title> <body>: prints "ps_rc=.. setting=.. shown=.." for powershell.exe
  out=$(printf '%s\n' "$PS_SCRIPT" | PADDOCK_TOAST_TITLE=$1 PADDOCK_TOAST_BODY=$2 \
        WSLENV="${WSLENV:+$WSLENV:}PADDOCK_TOAST_TITLE:PADDOCK_TOAST_BODY" \
        powershell.exe -NoProfile -NonInteractive -Command - 2>&1 | tr -d "\r")
  setting=$(printf '%s\n' "$out" | sed -n 's/^setting=//p' | tail -1)
  shown=$(printf '%s\n' "$out" | sed -n 's/^shown=\([a-z]*\).*/\1/p' | tail -1)
  err=$(printf '%s\n' "$out" | sed -n 's/^shown=no error=//p' | tail -1)
  printf 'ps_rc=%s setting=%s shown=%s%s\n' "$([ "$shown" = yes ] && echo 0 || echo 3)" "${setting:-n/a}" "${shown:-no}" "${err:+ error=$err}"
}

if [ "${1:-}" = --inner ]; then # runs inside the kept terminal; writes its line to $2
  toast "paddock probe B (kept terminal)" "raised from a process in an hc terminal" > "$2.tmp" 2>&1
  mv "$2.tmp" "$2"
  exit 0
fi

echo "probe: toast-from-kept-terminal, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "env: WSL_DISTRO_NAME=${WSL_DISTRO_NAME:+set} powershell.exe=$(command -v powershell.exe || echo missing) hc=$(command -v hc || echo missing)"
if command -v powershell.exe >/dev/null 2>&1; then
  echo "interop: powershell.exe version $(powershell.exe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>&1 | tr -d '\r' | head -1)"
else
  echo "interop: powershell.exe not found; WSL interop is off or this is not WSL. Stopping."; exit 1
fi
command -v hc >/dev/null 2>&1 || { echo "hc not found; only case A can run"; }

echo "--- A: from this login shell"
a=$(toast "paddock probe A (login shell)" "raised from the shell that ran the probe")
echo "RESULT A: $a"

if command -v hc >/dev/null 2>&1; then
  echo "--- B: from a kept terminal"
  dir=$(mktemp -d); res=$dir/b.result
  here=$(cd "$(dirname "$0")" && pwd)
  cleanup() { hc kill p335-toast >/dev/null 2>&1; hc rm p335-toast >/dev/null 2>&1; rm -rf "$dir"; }
  trap cleanup EXIT INT TERM
  hc rm p335-toast >/dev/null 2>&1
  sleep 6 # let the first toast finish so the second is not folded into it
  if hc run --bg --keep --name p335-toast -- sh "$here/toast-from-kept-terminal.sh" --inner "$res" >/dev/null 2>"$dir/run.err"; then
    i=0; while [ ! -s "$res" ] && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
    if [ -s "$res" ]; then echo "RESULT B: $(cat "$res")"; else echo "RESULT B: no answer after 30 s (terminal state: $(hc get p335-toast 2>&1 | tr -d '\n' | head -c 200))"; fi
  else
    echo "RESULT B: hc run failed: $(cat "$dir/run.err")"
  fi
fi
echo "--- now report: did you SEE toast A? toast B? did you HEAR a sound for each?"
