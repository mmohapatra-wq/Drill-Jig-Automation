<#
  probes\motw-webview2-test.ps1 - confirm/deny the hypothesis that Mark-of-the-Web
  (the Zone.Identifier a browser download + Explorer-extract stamps on every file)
  breaks the drilljig-gui 3D overview by making Add-Type fail on the WebView2 DLLs.

  Copies the vendored WebView2 managed DLLs to a temp dir, stamps them with
  ZoneId=3 (Internet - what a downloaded+extracted file carries), then tries
  Add-Type exactly like Add-WebView2Assemblies does. Reports whether the load
  throws. Then repeats AFTER Unblock-File to prove the fix.

  Pure diagnostic - touches nothing in the repo.
#>
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Repo = Split-Path -Parent $ScriptDir
function Say($m,$c='Gray'){ Write-Host $m -ForegroundColor $c }

$src = Join-Path $Repo 'handbook\vendor\webview2'
$core = Join-Path $src 'Microsoft.Web.WebView2.Core.dll'
if (-not (Test-Path $core)) { Say "vendored WebView2 Core.dll not found at $core" 'Red'; exit 3 }

$tmp = Join-Path $env:TEMP ('motw_wv2_' + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
foreach ($n in 'Microsoft.Web.WebView2.Core.dll','Microsoft.Web.WebView2.WinForms.dll','WebView2Loader.dll') {
  Copy-Item (Join-Path $src $n) (Join-Path $tmp $n) -Force
}

# stamp Mark-of-the-Web (ZoneId=3 = Internet) on the managed DLLs, exactly as a
# browser-downloaded + Explorer-extracted file carries.
function Set-MOTW($path){
  $z = "[ZoneTransfer]`r`nZoneId=3`r`n"
  Set-Content -Path ($path + ':Zone.Identifier') -Value $z -Encoding Ascii
}
$coreT = Join-Path $tmp 'Microsoft.Web.WebView2.Core.dll'
$wfT   = Join-Path $tmp 'Microsoft.Web.WebView2.WinForms.dll'
Set-MOTW $coreT; Set-MOTW $wfT
Say ("PS host: {0}  (.NET {1})" -f $PSVersionTable.PSVersion, [System.Environment]::Version) 'Cyan'
Say "stamped ZoneId=3 (Internet / MOTW) on the copied DLLs." 'Yellow'
$zi = $null; try { $zi = Get-Content -LiteralPath $coreT -Stream Zone.Identifier -ErrorAction Stop } catch {}
Say ("  Zone.Identifier present on Core.dll? {0}" -f ([bool]$zi)) 'DarkGray'

# --- attempt 1: load WHILE marked (in a CHILD powershell so a hard load-failure
#     doesn't poison this process; Add-Type can only load an assembly identity once) ---
function Try-Load([string]$dir,[string]$label){
  $code = @"
`$ErrorActionPreference='Stop'
try {
  Add-Type -Path (Join-Path '$dir' 'Microsoft.Web.WebView2.Core.dll')
  Add-Type -Path (Join-Path '$dir' 'Microsoft.Web.WebView2.WinForms.dll')
  Write-Output 'LOAD_OK'
} catch {
  Write-Output ('LOAD_FAIL: ' + `$_.Exception.GetType().Name + ': ' + `$_.Exception.Message)
}
"@
  $out = & (Get-Process -Id $PID).Path -NoProfile -STA -ExecutionPolicy Bypass -Command $code 2>&1 | Out-String
  Say ("[$label] " + $out.Trim()) $(if ($out -match 'LOAD_OK') { 'Green' } else { 'Red' })
  return ($out -match 'LOAD_OK')
}

Say ""
Say "== attempt 1: DLLs MARKED with MOTW ==" 'Cyan'
$marked = Try-Load $tmp 'marked'

# --- attempt 2: Unblock-File, then load again (the proposed fix) ---
Say ""
Say "== attempt 2: after Unblock-File (the fix) ==" 'Cyan'
Get-ChildItem $tmp -Filter *.dll | Unblock-File
$zi2 = $null; try { $zi2 = Get-Content -LiteralPath $coreT -Stream Zone.Identifier -ErrorAction Stop } catch {}
Say ("  Zone.Identifier still on Core.dll? {0}" -f ([bool]$zi2)) 'DarkGray'
$unblocked = Try-Load $tmp 'unblocked'

Say ""
Say "== VERDICT ==" 'Cyan'
if (-not $marked -and $unblocked) {
  Say "CONFIRMED: MOTW breaks the WebView2 load; Unblock-File fixes it." 'Green'
  Say "  => a downloaded+Explorer-extracted bundle would show '3D overview unavailable' until unblocked." 'Yellow'
} elseif ($marked) {
  Say "NOT REPRODUCED: the marked DLLs loaded anyway on this host (loadFromRemoteSources may be enabled, or .NET tolerated it)." 'Yellow'
  Say "  MOTW is still a real risk on stricter hosts; Unblock-File remains a safe hardening." 'Gray'
} else {
  Say "INCONCLUSIVE: neither load succeeded (a different problem - inspect the messages above)." 'Red'
}
try { Remove-Item $tmp -Recurse -Force } catch {}
