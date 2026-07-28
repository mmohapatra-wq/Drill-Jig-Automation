<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir=((Split-Path -Parent ('%~dp0'.TrimEnd('\')))+'\'); $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "ONPOINTHOLE-PROBE"
$ErrorActionPreference = "Stop"

# ============================================================================
# ONPOINTHOLE-PROBE -- settle, LIVE, whether the curved-jig ON-POINT fastener hole
# fires HANDS-FREE: placement = a fastener's datum point, ORIENTATION = that
# fastener's own TOP plane (id 1), fed via the raw-COM path-qualified channel into
# the ProCmdHole ft_dir collector. This is the operator's authoritative recording
# (2026-07-28) with the two positional tree-selects replaced by raw-COM selects.
# ============================================================================
# WHY: the point channel is proven (fastenerplane-probe id 959) and the manual hole
# works, but the HANDS-FREE on-point hole hinges on ONE unverified mechanic -- whether
# a raw-COM AddSelection populates an ARMED dashboard collector (prim_ref for the
# pre-selected point, ft_dir for the external TOP plane). This probe runs the EXACT
# choreography Invoke-FastenerHole uses, with a buffer dump after every step, so we see
# precisely where (if anywhere) it breaks -- and the --noclear flag settles whether the
# ft_dir feed should Clear the buffer first (mirroring a tree-click's replace) or add onto it.
#
# SEQUENCE (per fastener):
#   [0] make the drilljig PART active (external planes need the jig active).
#   [1] operator selects ONE fastener COMPONENT -> Add-ComponentDefaultPlanesToBuffer
#       (constant ids 1/3/5, path-qualified) -> ProCmdDatumPointGeneral -> the point (id P).
#   [2] raw-COM pre-select point P -> Build-OnPointHoleOpenMacro (prim_ref binds P, ft_dir
#       armed) -> Select-ComponentPlaneById(TOP, id 1) into ft_dir -> Build-OnPointHoleFinishMacro
#       -> canary a NEW hole FEATURE. Dumps the buffer after each step.
#
# ID-ONLY: reads Id / GetName / Path only; NEVER IpfcPoint.Point.
# MUTATES (one throwaway point + one throwaway hole) behind a y/N + canary.
# Writes artifacts\onpointhole_probe_report.txt (gitignored). ONE Creo session.
#
# FLAGS:
#   --noclear    feed the TOP plane into ft_dir WITHOUT clearing the buffer first
#                (default clears, mirroring a tree-click replace). Re-run with this to
#                settle the Clear-vs-NoClear question if the default misses.
#   -v           verbose (print each macro before firing).
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
$noClear = $argStr -match '(?i)--no-?clear'
$verbose = $argStr -match '(?i)(^|\s)(-v|--verbose)(\s|$)'

Write-Host ""
Write-Host "  ONPOINTHOLE-PROBE -- does the hands-free ON-POINT hole (TOP-plane orientation) fire?" -ForegroundColor Cyan
Write-Host "  Runs Invoke-FastenerHole's exact choreography with per-step buffer dumps. ft_dir feed = $(if ($noClear) { 'NoClear (add)' } else { 'Clear (replace)' })." -ForegroundColor DarkGray
Write-Host ""

# ============================================================================
# SHARED LIBRARY
# ============================================================================
. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')        # Get-Comp
. (Join-Path $ScriptDir 'lib\drilljig_core.ps1')         # Initialize-DrilljigCore, Get-FeatureIdSet, Wait-ModelModified, Resolve-PlaneRole
. (Join-Path $ScriptDir 'lib\conformal_blank.ps1')       # (dep of curved_fastener_hole)
. (Join-Path $ScriptDir 'lib\curved_fastener_hole.ps1')  # Add-ComponentDefaultPlanesToBuffer, Select-ComponentPlaneById, Build-OnPointHole*, Get-ComSelectFactory

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

function Get-PointIdSetLocal {
    $set = @{}
    try { foreach ($p in @($model.ListItems($pfcType.ITEM_POINT))) { try { $set[[int]$p.Id] = $true } catch {} } } catch {}
    return $set
}
# dump the current selection buffer (Id / GetName / path) -- the diagnostic lens.
function Dump-Buffer { param([string]$Tag)
    $bb = @(); try { $bb = @(($session.CurrentSelectionBuffer()).Contents) } catch {}
    Rep ("  buffer @ {0}: {1} item(s)" -f $Tag, $bb.Count) $(if ($bb.Count -ge 1) {'Gray'} else {'DarkGray'})
    foreach ($b in $bb) {
        $bsi = $null; try { $bsi = $b.SelItem } catch {}
        if ($null -eq $bsi) { continue }
        $bid = 0; try { $bid = [int]$bsi.Id } catch {}
        $btn = ''; try { $btn = [string]$bsi.GetName() } catch {}
        $bp2 = ''; try { $bp = $b.Path; if ($null -ne $bp) { $bp2 = (@($bp.ComponentIds) -join '|') } } catch {}
        Rep ("      id={0}  name='{1}'  path={2}" -f $bid, $btn, $(if ($bp2) { $bp2 } else { '(none)' })) 'DarkGray'
    }
}

$reportFile = Join-Path $ScriptDir 'artifacts\onpointhole_probe_report.txt'
$reportDir = Split-Path -Parent $reportFile; if ($reportDir -and -not (Test-Path $reportDir)) { New-Item -ItemType Directory -Force -Path $reportDir | Out-Null }
Rep ("ONPOINTHOLE-PROBE report  model=$fname  noclear=$noClear  when=" + (Get-Date).ToString('o')) 'Cyan'
Rep ""

try {

try { $session.SetConfigOption("visible_mapkeys", "no") | Out-Null; $session.SetConfigOption("dynamic_preview", "no") | Out-Null } catch {}

# ============================================================================
# SECTION 0 -- MAKE THE DRILLJIG PART ACTIVE (external fastener planes need it).
# ============================================================================
$activeNow = ''
try { $am0 = $session.GetActiveModel(); if ($null -ne $am0) { $activeNow = [string]$am0.FileName } } catch {}
Rep ("== [0] ACTIVE MODEL == {0}" -f $activeNow) $(if ($activeNow -match '(?i)\.asm(\.\d+)?$') {'Yellow'} else {'Green'})
if ($activeNow -match '(?i)\.asm(\.\d+)?$') {
    Rep "  The ACTIVE model is the ASSEMBLY. In Creo select the DRILLJIG PART node, then press ENTER;" 'Yellow'
    Rep "  the probe fires ProCmdMakeActive so the point + hole land in the jig." 'Yellow'
    Read-Host
    try { $session.RunMacro("~ Command ``ProCmdMakeActive@PopupMenuTree``;"); Rep "  fired ProCmdMakeActive." 'DarkGray' } catch { Rep ("  ProCmdMakeActive error: $($_.Exception.Message)") 'Red' }
    $activeNow = ''
    try { $am0 = $session.GetActiveModel(); if ($null -ne $am0) { $activeNow = [string]$am0.FileName } } catch {}
    Rep ("  Active model after ProCmdMakeActive: {0}" -f $activeNow) $(if ($activeNow -match '(?i)\.asm(\.\d+)?$') {'Yellow'} else {'Green'})
}
Rep ""

# ============================================================================
# SECTION 1 -- POINT: select ONE fastener COMPONENT, build its intersection point.
# ============================================================================
Write-Host "  In Creo, select ONE fastener COMPONENT (the fastener in the tree, NOT its planes)," -ForegroundColor Cyan
Write-Host "  then press ENTER. The probe resolves its 1/3/5 planes by ID + path and builds the point." -ForegroundColor Cyan
Read-Host
Rep "== [1] POINT (Add-ComponentDefaultPlanesToBuffer -> ProCmdDatumPointGeneral) ==" 'Cyan'
$compPath = $null
try {
    foreach ($sel in @(($session.CurrentSelectionBuffer()).Contents)) {
        $pp = $null; try { $pp = $sel.Path } catch {}
        if ($null -ne $pp) { $compPath = $pp; break }
    }
} catch {}
if ($null -eq $compPath) { throw "No component Path on the selection -- select the fastener COMPONENT (not a plane) and re-run." }
$cids = ''; try { $cids = (@($compPath.ComponentIds) -join '|') } catch {}
Rep ("  fastener component path.ComponentIds = {0}" -f $(if ($cids) { $cids } else { '(none)' })) 'Gray'
$byid = Add-ComponentDefaultPlanesToBuffer -Session $session -Model $model -TypeObj $pfcType -ComponentPath $compPath
$added = 0; try { $added = [int]$byid.Added } catch {}
Rep ("  Add-ComponentDefaultPlanesToBuffer -> Added={0}  Roles={1}  Ids={2}" -f $added, (@($byid.Roles) -join '/'), (@($byid.Ids) -join ',')) $(if ($added -ge 3) {'Green'} else {'Yellow'})
if ($added -lt 3) { throw "by-ID plane select did not add 3 planes (Reason: $([string]$byid.Reason)) -- fix the point channel first (fastenerplane-probe)." }
$ptBefore = Get-PointIdSetLocal
$stamp = $null; try { $stamp = [string]$model.VersionStamp } catch {}
try { $session.RunMacro((Build-FastenerPointMacro)) } catch { Rep ("  point macro error: $($_.Exception.Message)") 'Red' }
if ($null -ne $stamp) { [void](Wait-ModelModified -Model $model -PreviousStamp $stamp -TimeoutMs 30000) }
$ptAfter = Get-PointIdSetLocal
$newPts  = @($ptAfter.Keys | Where-Object { -not $ptBefore.ContainsKey($_) } | Sort-Object)
$pointId = 0; if (@($newPts).Count -ge 1) { $pointId = [int]$newPts[-1] }
Rep ("  POINT: {0} (id {1})" -f $(if ($pointId -gt 0) { 'created' } else { 'NO new id enumerated' }), $pointId) $(if ($pointId -gt 0) {'Green'} else {'Yellow'})
if ($pointId -le 0) { throw "No datum point id -- cannot pre-select it for the on-point hole. (Is the jig PART active?)" }
Rep ""

# ============================================================================
# SECTION 2 -- PRE-SELECTED HOLE: select the point + the TOP plane TOGETHER, then ProCmdHole.
# Mirrors the operator's 'holeexctrude' recording + Invoke-FastenerHole: ProCmdHole consumes
# the 2-item pre-selection (point -> on-point placement, TOP plane -> orientation). Buffer dumps
# between each step. (--noclear is now vestigial: the plane is ALWAYS accumulated onto the point.)
# ============================================================================
Write-Host "  (Answer in THIS console.)" -ForegroundColor DarkGray
$ans = Read-Host "  Fire the hole on the PRE-SELECTED point $pointId + TOP plane id 1 now? (y/N)"
if ($ans -notmatch '^(?i)y') { Rep "== [2] HOLE -- declined ==" 'Yellow' } else {
    Rep "== [2] PRE-SELECTED HOLE (placement=point $pointId, orientation=TOP plane id 1) ==" 'Cyan'
    $featBefore = Get-FeatureIdSet
    $stampH = $null; try { $stampH = [string]$model.VersionStamp } catch {}

    # (1) PLACEMENT: clear + select the local datum point.
    $preOk = $false
    try {
        $ptItem = $model.GetItemById($pfcType.ITEM_POINT, [int]$pointId)
        $factory = Get-ComSelectFactory
        if ($null -ne $ptItem -and $null -ne $factory) {
            $buf = $session.CurrentSelectionBuffer()
            try { $buf.Clear() } catch {}
            $psel = $factory.CreateModelItemSelection($ptItem, $null)
            if ($null -ne $psel) { $buf.AddSelection($psel); $preOk = $true }
        }
    } catch { Rep ("  point pre-select threw: $($_.Exception.Message)") 'Red' }
    Rep ("  (1) point pre-select: {0}" -f $(if ($preOk) { 'ok' } else { 'FAILED' })) $(if ($preOk) {'Green'} else {'Yellow'})
    Dump-Buffer 'after point pre-select'

    # (2) ORIENTATION: ACCUMULATE the TOP plane (id 1, path-qualified) onto the point (-NoClear)
    # so the buffer holds BOTH refs -- exactly the recording's 2-item tree selection.
    $pf = Select-ComponentPlaneById -Session $session -TypeObj $pfcType -ComponentPath $compPath -PlaneId 1 -Role 'Top' -NoClear
    $pfOk = $false; try { $pfOk = [bool]$pf.Ok } catch {}
    Rep ("  (2) TOP-plane accumulate (Select-ComponentPlaneById -NoClear): Ok={0}  Reason={1}" -f $pfOk, [string]$pf.Reason) $(if ($pfOk) {'Green'} else {'Yellow'})
    Dump-Buffer 'after TOP-plane accumulate (should hold POINT + TOP plane)'

    # (3) fire ProCmdHole on the pre-selection + Done.
    if ($verbose) { Rep ("  macro: " + (Build-PreselectedHoleMacro)) 'DarkGray' }
    try { $session.RunMacro((Build-PreselectedHoleMacro)) } catch { Rep ("  hole macro error: $($_.Exception.Message)") 'Red' }

    # (4) canary: a NEW hole FEATURE.
    if ($null -ne $stampH) { [void](Wait-ModelModified -Model $model -PreviousStamp $stampH -TimeoutMs 30000) }
    $afterFeat = Get-FeatureIdSet
    $newFeats = @($afterFeat.Keys | Where-Object { -not $featBefore.ContainsKey($_) })
    if (@($newFeats).Count -ge 1) {
        Rep ("  (4) HOLE CREATED: {0} new feature id(s) -> {1}." -f @($newFeats).Count, ((@($newFeats) | Sort-Object) -join ',')) 'Green'
        Rep "  -> the hands-free PRE-SELECTED on-point hole WORKS. Verify VISUALLY it is ON the point + oriented to the TOP plane (normal to the jig)." 'Green'
    } else {
        Rep "  (4) NO new hole feature (model unchanged) -- a MISS." 'Yellow'
        Rep "  Read the (2) buffer dump: it must hold BOTH the point AND the TOP plane before ProCmdHole." 'Yellow'
        Rep "  If a hole dashboard is still open in Creo, Cancel it before re-running." 'Yellow'
    }
}
Rep ""

# ============================================================================
# VERDICT
# ============================================================================
Rep "== VERDICT ==" 'Cyan'
Rep "Section [2] step (4) is the real gate: a new hole FEATURE => the hands-free pre-selected hole fires." 'Gray'
Rep "The (2) buffer dump must show BOTH the datum point AND the fastener TOP plane (path-qualified) --" 'Gray'
Rep "ProCmdHole then auto-assigns point=placement, plane=orientation (the operator's holeexctrude flow)." 'Gray'
Rep "This probe created a throwaway point + hole -- delete/Undo them in Creo." 'Yellow'

}
finally {
    try { if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null } } catch {}
    try { if ($null -ne $origDynamicPreview) { $session.SetConfigOption("dynamic_preview", $origDynamicPreview) | Out-Null } } catch {}
    try {
        Set-Content -Path $reportFile -Value ($script:report -join [Environment]::NewLine) -Encoding UTF8
        Write-Host ""
        Write-Host ("  Report written: $reportFile") -ForegroundColor Cyan
        Write-Host "  (onpointhole_probe_report.txt is gitignored -- probe reports are not committed.)" -ForegroundColor DarkGray
    } catch { Write-Host ("  Could not write report: $($_.Exception.Message)") -ForegroundColor Yellow }
    try { $connection.Disconnect($null) } catch {}
    [System.GC]::Collect(); [System.GC]::WaitForPendingFinalizers()
}

Write-Host ""
Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
