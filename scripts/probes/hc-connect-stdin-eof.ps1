# Probe for Issue #74, Windows form of hc-connect-stdin-eof.sh (see it for how
# to read the cases). Run in pwsh: pwsh -NoProfile -File scripts/probes/hc-connect-stdin-eof.ps1 [doc]
# Read-only doc.get. Paste the whole output back.
param([string]$Doc = "org-state")
$hc = (Get-Command hc -ErrorAction SilentlyContinue).Source
if (-not $hc) { $hc = "$env:LOCALAPPDATA\Programs\herdr-core\hc.exe" }
"date: $((Get-Date).ToUniversalTime().ToString('s'))Z"; & $hc --version
$req = '{"jsonrpc":"2.0","id":1,"method":"doc.get","params":{"name":"' + $Doc + '"}}'
$a = 0; $b = 0
foreach ($i in 1..20) {
  $r = & { $req } | & $hc connect 2>&1
  if ($i -eq 1) { "-- A (EOF at once) exit=$LASTEXITCODE output=[$r]" }
  if ("$r" -match '^\{') { $a++ }
  $r = & { $req; Start-Sleep -Seconds 1 } | & $hc connect 2>&1
  if ($i -eq 1) { "-- B (held 1 s) exit=$LASTEXITCODE output=[$r]" }
  if ("$r" -match '^\{') { $b++ }
}
"-- E: EOF at once answered $a/20; held 1 s answered $b/20"
