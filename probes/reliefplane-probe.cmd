<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir=((Split-Path -Parent ('%~dp0'.TrimEnd('\')))+'\'); $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "RELIEFPLANE-PROBE"
$ErrorActionPreference = "Stop"

# ============================================================================
# RELIEFPLANE-PROBE -- settle, LIVE and in 60 seconds, the ONE question the curved
# chip-relief has been stuck on: can the relief extrude open its sketch ON the
# fastener's OWN TOP plane HANDS-FREE, by PRE-SELECTING that TOP plane (the SAME
# raw-COM path-qualified reference the hole uses) BEFORE ProCmdFtExtrude?
# ============================================================================
# WHY THIS EXISTS: the hole works (ProCmdHole consumes a pre-selected component TOP
# plane as its orientation ref). The relief extrude needs that plane as a SKETCH plane,
# and it has failed repeatedly. TWO unknowns are tangled together and this probe SPLITS
# them so we stop guessing:
#   (Q1) does ProCmdFtExtrude ACCEPT the raw-COM pre-selected component TOP plane as a
#        sketch plane?  (trail.txt.20 showed a rejection during an old one-shot-macro run;
#        the hole proves the identical pre-select works for ProCmdHole -- so re-test clean.)
#   (Q2) is the stored component path even ALIVE by relief time, or stale?  This probe reads
#        a FRESH path from the live buffer, so a SUCCESS here isolates Q1 from Q2 -- if the
#        probe works but the GUI does not, the GUI bug is a STALE path (fix = re-resolve).
#
# It runs the EXACT choreography Invoke-FastenerReliefArm now uses:
#   Select-ComponentPlaneById(TOP, id 1)  ->  ProCmdFtExtrude
# then PAUSES for you to LOOK at Creo and report whether the sketch opened on the TOP plane.
# As a cross-check it also tries the v5 order (open FIRST, feed after) so we can see the
# difference directly. Both are behind a y/N + the extrude is CANCELLED after each.
#
# ID-ONLY (Id / GetName / Path); NEVER IpfcPoint.Point. Opens + CANCELS a throwaway extrude
# (no cut). Writes artifacts\reliefplane_probe_report.txt (gitignored). ONE Creo session.
#
# FLAGS:
#   -v   verbose (print each macro before firing).
# ============================================================================

trap {
    Write-Host ""
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $inv = $_.InvocationInfo
    if ($null -ne $inv) { Write-Host ("  at line {0}: {1}" -f $inv.ScriptLineNumber, $inv.Line.Trim()) -ForegroundColor DarkYellow }
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

$argStr  = [string]$ScriptArgs
$verbose = $argStr -match '(?i)(^|\s)(-v|--verbose)(\s|$)'

Write-Host ""
Write-Host "  RELIEFPLANE-PROBE -- can the relief extrude open its sketch on the fastener TOP plane hands-free?" -ForegroundColor Cyan
Write-Host "  Runs Invoke-FastenerReliefArm's exact pre-select-then-extrude path with a FRESH reference." -ForegroundColor DarkGray
Write-Host ""

# ============================================================================
# SHARED LIBRARY
# ============================================================================
. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')
. (Join-Path $ScriptDir 'lib\drilljig_core.ps1')         # Initialize-DrilljigCore, Get-FeatureIdSet, Wait-ModelModified, Resolve-PlaneRole
. (Join-Path $ScriptDir 'lib\conformal_blank.ps1')
. (Join-Path $ScriptDir 'lib\curved_fastener_hole.ps1')  # Select-ComponentPlaneById, Get-BufferComponentPath, Get-ComSelectFactory
. (Join-Path $ScriptDir 'lib\curved_relief.ps1')          # Build-CurvedReliefOpenMacro, Build-CurvedReliefRectMacro

# ============================================================================
# CONNECT (single session)
# ============================================================================
$procs = @(Get-Process -Name xtop -ErrorAction SilentlyContinue)
if ($procs.Count -eq 0) { throw "Creo (xtop.exe) is not running" }
if ($procs.Count -gt 1) { throw "More than one Creo session is open. This probe expects exactly ONE." }
$proc = $procs[0]
$Env:PRO_DIRECTORY    = $proc.Path.TrimEnd("xtop.exe")
$Env:PRO_COMM_MSG_EXE = $proc.Path -replace "xtop.exe", "pro_comm_msg.exe"

try { New-Object -ComObject pfcls.pfcAsyncConnection | Out-Null }
catch {
    $reg = $proc.Path -replace "Common Files(.*)$", "Parametric\bin\vb_api_register.bat"
    Start-Process -Wait -FilePath $reg
}
$async      = New-Object -ComObject pfcls.pfcAsyncConnection
$connection = $async.Connect($null, $null, $null, $null)
$session    = $connection.Session
$model      = $null
try { $model = $session.GetActiveModel() } catch {}
if ($null -eq $model) { try { $model = $session.CurrentModel } catch {} }
if ($null -eq $model) { throw "No active model. Open the top-down ASSEMBLY (curved surface + fasteners + drilljig)." }

$fname = try { [string]$model.FileName } catch { "" }

$pfcType = New-Object -ComObject pfcls.pfcModelItemType
Initialize-DrilljigCore -Session $session -Model $model -TypeObj $pfcType -DataDir $ScriptDir -Log $null
Write-Host "  Connected. Active model: $fname" -ForegroundColor Green
Write-Host ""

# config-suppress (restored in the finally)
$origVisibleMapkeys = $null; $origDynamicPreview = $null
try { $vals = $session.GetConfigOptionValues("visible_mapkeys"); if ($null -ne $vals -and $vals.Count -gt 0) { $origVisibleMapkeys = $vals.Item(0) } } catch {}
try { $vals = $session.GetConfigOptionValues("dynamic_preview"); if ($null -ne $vals -and $vals.Count -gt 0) { $origDynamicPreview = $vals.Item(0) } } catch {}

$script:report = @()
function Rep { param([string]$Line, [string]$Color = 'Gray') Write-Host ("  " + $Line) -ForegroundColor $Color; $script:report += $Line }

# a hard CANCEL of any open dashboard (so a throwaway extrude leaves NO feature).
function Cancel-Dashboard {
    try { $session.RunMacro("~ Activate ``main_dlg_cur`` ``dashInst0.Cancel``;") } catch {}
    try { $session.RunMacro("~ Command ``ProCmdMdlTreeSuppress`` ;") } catch {}   # no-op guard; ignored if invalid
}

$reportFile = Join-Path $ScriptDir 'artifacts\reliefplane_probe_report.txt'
$reportDir = Split-Path -Parent $reportFile; if ($reportDir -and -not (Test-Path $reportDir)) { New-Item -ItemType Directory -Force -Path $reportDir | Out-Null }
Rep ("RELIEFPLANE-PROBE report  model=$fname  when=" + (Get-Date).ToString('o')) 'Cyan'
Rep ""

try {

try { $session.SetConfigOption("visible_mapkeys", "no") | Out-Null; $session.SetConfigOption("dynamic_preview", "no") | Out-Null } catch {}

# ============================================================================
# SECTION 0 -- MAKE THE DRILLJIG PART ACTIVE (the sketch/cut must land in the jig).
# ============================================================================
$activeNow = ''
try { $am0 = $session.GetActiveModel(); if ($null -ne $am0) { $activeNow = [string]$am0.FileName } } catch {}
Rep ("== [0] ACTIVE MODEL == {0}" -f $activeNow) $(if ($activeNow -match '(?i)\.asm(\.\d+)?$') {'Yellow'} else {'Green'})
if ($activeNow -match '(?i)\.asm(\.\d+)?$') {
    Rep "  The ACTIVE model is the ASSEMBLY. In Creo select the DRILLJIG PART node, then press ENTER;" 'Yellow'
    Rep "  the probe fires ProCmdMakeActive so the extrude opens in the jig part." 'Yellow'
    Read-Host
    try { $session.RunMacro("~ Command ``ProCmdMakeActive@PopupMenuTree``;"); Rep "  fired ProCmdMakeActive." 'DarkGray' } catch { Rep ("  ProCmdMakeActive error: $($_.Exception.Message)") 'Red' }
    $activeNow = ''
    try { $am0 = $session.GetActiveModel(); if ($null -ne $am0) { $activeNow = [string]$am0.FileName } } catch {}
    Rep ("  Active model after ProCmdMakeActive: {0}" -f $activeNow) $(if ($activeNow -match '(?i)\.asm(\.\d+)?$') {'Yellow'} else {'Green'})
}
Rep ""

# ============================================================================
# SECTION 1 -- FRESH component path: operator selects ONE fastener COMPONENT.
# ============================================================================
Write-Host "  In Creo, select ONE fastener COMPONENT (the fastener in the tree, NOT a plane), then press ENTER." -ForegroundColor Cyan
Read-Host
Rep "== [1] FRESH COMPONENT PATH ==" 'Cyan'
$compPath = Get-BufferComponentPath -Session $session
if ($null -eq $compPath) {
    # fall back to any Path on the selection (Get-BufferComponentPath needs >=1 ComponentId).
    try { foreach ($sel in @(($session.CurrentSelectionBuffer()).Contents)) { $pp=$null; try { $pp=$sel.Path } catch {}; if ($null -ne $pp) { $compPath=$pp; break } } } catch {}
}
if ($null -eq $compPath) { throw "No component Path on the selection -- select the fastener COMPONENT (not a plane) and re-run." }
$cids = ''; try { $cids = (@($compPath.ComponentIds) -join '|') } catch {}
Rep ("  fastener component path.ComponentIds = {0}" -f $(if ($cids) { $cids } else { '(none)' })) 'Gray'
# verify the TOP plane (id 1) resolves + name-checks off THIS fresh path.
$chk = Select-ComponentPlaneById -Session $session -TypeObj $pfcType -ComponentPath $compPath -PlaneId 1 -Role 'Top'
$chkOk = $false; try { $chkOk = [bool]$chk.Ok } catch {}
Rep ("  TOP plane id 1 resolves off this path: Ok={0}  Reason={1}" -f $chkOk, [string]$chk.Reason) $(if ($chkOk) {'Green'} else {'Yellow'})
if (-not $chkOk) { throw "Could not resolve/name-verify the TOP plane (id 1) off this fastener path -- the point channel must work first (fastenerplane-probe)." }
Rep ""

# ============================================================================
# TEST A -- THE FIX: PRE-SELECT the TOP plane, THEN ProCmdFtExtrude.
# ============================================================================
$ansA = Read-Host "  TEST A (the fix): pre-select TOP plane id 1, THEN open the extrude? (y/N)"
if ($ansA -notmatch '^(?i)y') { Rep "== [A] pre-select-then-extrude -- declined ==" 'Yellow' } else {
    Rep "== [A] PRE-SELECT TOP plane id 1 -> ProCmdFtExtrude ==" 'Cyan'
    $pf = Select-ComponentPlaneById -Session $session -TypeObj $pfcType -ComponentPath $compPath -PlaneId 1 -Role 'Top'
    Rep ("  (1) pre-select TOP plane: Ok={0}" -f ([bool]$pf.Ok)) $(if ([bool]$pf.Ok) {'Green'} else {'Yellow'})
    if ($verbose) { Rep ("  macro: " + (Build-CurvedReliefOpenMacro)) 'DarkGray' }
    try { $session.RunMacro((Build-CurvedReliefOpenMacro)) } catch { Rep ("  extrude open error: $($_.Exception.Message)") 'Red' }
    Rep "" 'Gray'
    Rep "  >>> LOOK AT CREO NOW. <<<" 'Cyan'
    Rep "  SUCCESS  = the internal sketch opened oriented ON the fastener's TOP plane (you could draw)." 'Green'
    Rep "  FAILURE  = Creo shows 'select a sketch plane' / 'selected geometry can not be used' / nothing usable." 'Yellow'
    $seeA = Read-Host "  Did the sketch open ON the fastener TOP plane? (y = SUCCESS / n = it did not)"
    if ($seeA -match '^(?i)y') { Rep "  RESULT [A]: SUCCESS -- pre-select-then-extrude opens the sketch on the TOP plane HANDS-FREE." 'Green' }
    else { Rep "  RESULT [A]: FAIL -- ProCmdFtExtrude did NOT take the raw-COM pre-selected component plane as a sketch plane." 'Yellow' }
    Cancel-Dashboard
    Rep "  (extrude cancelled -- no feature left behind)." 'DarkGray'
}
Rep ""

# ============================================================================
# TEST B -- CROSS-CHECK (v5): open the extrude FIRST, feed the TOP plane after.
# ============================================================================
$ansB = Read-Host "  TEST B (cross-check, v5 order): open the extrude FIRST, then feed the TOP plane? (y/N)"
if ($ansB -notmatch '^(?i)y') { Rep "== [B] open-then-feed -- declined ==" 'Yellow' } else {
    Rep "== [B] ProCmdFtExtrude -> (post-open) Select-ComponentPlaneById TOP id 1 ==" 'Cyan'
    if ($verbose) { Rep ("  macro: " + (Build-CurvedReliefOpenMacro)) 'DarkGray' }
    try { $session.RunMacro((Build-CurvedReliefOpenMacro)) } catch { Rep ("  extrude open error: $($_.Exception.Message)") 'Red' }
    $pfB = Select-ComponentPlaneById -Session $session -TypeObj $pfcType -ComponentPath $compPath -PlaneId 1 -Role 'Top'
    Rep ("  (post-open) feed TOP plane: Ok={0}" -f ([bool]$pfB.Ok)) $(if ([bool]$pfB.Ok) {'Green'} else {'Yellow'})
    Rep "  >>> LOOK AT CREO NOW. <<<" 'Cyan'
    $seeB = Read-Host "  Did the sketch open ON the fastener TOP plane? (y = SUCCESS / n = it did not)"
    if ($seeB -match '^(?i)y') { Rep "  RESULT [B]: SUCCESS -- open-then-feed works (v5 order)." 'Green' }
    else { Rep "  RESULT [B]: FAIL -- the post-open feed did not register (matches the GUI symptom)." 'Yellow' }
    Cancel-Dashboard
    Rep "  (extrude cancelled -- no feature left behind)." 'DarkGray'
}
Rep ""

# ============================================================================
# VERDICT
# ============================================================================
Rep "== VERDICT ==" 'Cyan'
Rep "TEST A SUCCESS  => the fix is correct; if the GUI still fails, the bug is a STALE component path" 'Gray'
Rep "                   in the Slots stage (fix = store component ids at drill time, re-resolve fresh)." 'Gray'
Rep "TEST A FAIL     => ProCmdFtExtrude genuinely rejects the raw-COM component plane as a sketch plane;" 'Gray'
Rep "                   hands-free is not possible via this channel -- the operator must click the TOP" 'Gray'
Rep "                   plane in the open extrude (the proven curvedslot-recording path), one click/hole." 'Gray'
Rep "TEST B tells us whether the v5 post-open order ever had a chance (expected: FAIL)." 'Gray'
Rep "This probe opened + CANCELLED throwaway extrudes -- if any dashboard is still open in Creo, Cancel it." 'Yellow'

}
finally {
    try { if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null } } catch {}
    try { if ($null -ne $origDynamicPreview) { $session.SetConfigOption("dynamic_preview", $origDynamicPreview) | Out-Null } } catch {}
    try {
        Set-Content -Path $reportFile -Value ($script:report -join [Environment]::NewLine) -Encoding UTF8
        Write-Host ""
        Write-Host ("  Report written: $reportFile") -ForegroundColor Cyan
        Write-Host "  (reliefplane_probe_report.txt is gitignored -- probe reports are not committed.)" -ForegroundColor DarkGray
    } catch { Write-Host ("  Could not write report: $($_.Exception.Message)") -ForegroundColor Yellow }
    try { $connection.Disconnect($null) } catch {}
    [System.GC]::Collect(); [System.GC]::WaitForPendingFinalizers()
}

Write-Host ""
Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
