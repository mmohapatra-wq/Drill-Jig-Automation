<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
echo.
pause
exit /b %errorlevel%
#>

# ============================================================================
# csysinator.cmd - datum COORDINATE SYSTEM at the INTERSECTION of 3 planes
# ============================================================================
# REWRITTEN 2026-07-13. The old edge-center / offset-plane / orientation-pick
# approach was scrapped -- it deadlocked (a COM read while the csys dialog was open)
# and demanded mouse picks. The new recipe is the operator's own working mapkey:
#
#   select 3 mutually-perpendicular planes IN ORDER (X-normal, Y-normal, Z-normal),
#   then  ~ Command `ProCmdDatumCsys` ;  ~ Activate `Odui_Dlg_00` `stdbtn_1` ;
#
# 3 perpendicular planes meet at ONE point; ProCmdDatumCsys makes a coordinate
# system there. This is BYTE-FOR-BYTE the proven 3-plane intersection recipe
# (Build-IntersectPointMacro / point-at-3-plane-intersection-by-id) with
# ProCmdDatumPointGeneral swapped for ProCmdDatumCsys, so the engine lives in
# lib\drilljig_core.ps1 (Build-CsysFromPlanesMacro / Invoke-IndexCsys) and is SHARED
# with drilljig.cmd STAGE 5 (index-hole csys) + drilljig-gui.cmd's Index stage.
#
# This standalone tool is for the ad-hoc case: you have (or make) 3 perpendicular
# planes and want a csys at their intersection. drilljig's STAGE 5 is the integrated
# path -- it already KNOWS the 3 planes behind each drilled hole, so there you just
# pick the hole. Open the jig PART (not .asm).
#
# Created iff a NEW feature appears (canary) -- never "done" on a no-op
# ([[feedback_canary_must_not_assume_on_failure]]). NOT yet confirmed live in this
# by-ID form (the operator's mapkey selected the planes in the model tree; here they
# are fed by tree-search select-by-ID, the accumulation channel proven for
# ProCmdDatumPointGeneral). Verify the axes visually after a run.
#
# FLAGS:  -v  verbose diagnostics
# ============================================================================

$Host.UI.RawUI.WindowTitle = "CSYSINATOR"
$ErrorActionPreference = "Stop"

trap {
    Write-Host ""
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    exit 1
}

$Verbose = ($ScriptArgs -match '(?i)-v\b|--verbose')

# Shared engine: creo_geometry (base reads), drilljig_core (Build-CsysFromPlanesMacro,
# Invoke-IndexCsys, Get-SelectByIdMacro, Read-SelectedId, Invoke-Macro,
# Wait-ModelModified, Get-FeatureIdSet - all read the $script:DJ* scope set by
# Initialize-DrilljigCore). orthogrid(_points) are pulled in for parity with the
# drilljig dot-source set (Get-SelectByIdMacro resolves at fire time in one scope).
. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')
. (Join-Path $ScriptDir 'lib\orthogrid.ps1')
. (Join-Path $ScriptDir 'lib\orthogrid_points.ps1')
. (Join-Path $ScriptDir 'lib\drilljig_core.ps1')

# ============================================================================
# HEADER
# ============================================================================
Write-Host ""
Write-Host "  CSYSINATOR - datum coordinate system at the intersection of 3 planes" -ForegroundColor White
Write-Host "  --------------------------------------------------------------------" -ForegroundColor DarkGray

# ----------------------------------------------------------------------------
# Connect
# ----------------------------------------------------------------------------
try {
    $proc = Get-Process | Where-Object { $_.ProcessName -eq "xtop" }
    if ($null -eq $proc) { throw "Running Creo process (xtop) not found" }
    $Env:PRO_DIRECTORY = $proc.Path.TrimEnd("xtop.exe")
    $Env:PRO_COMM_MSG_EXE = ($proc.Path -replace "xtop.exe", "pro_comm_msg.exe")
}
catch { $_; exit }

try { New-Object -ComObject pfcls.pfcAsyncConnection | Out-Null }
catch {
    Write-Output "VB API not yet registered, performing first time setup..."
    $vb_path = $proc.Path -replace "Common Files(.*)$", "Parametric\bin\vb_api_register.bat"
    Start-Process -Wait -FilePath $vb_path
}

try {
    $async = New-Object -ComObject pfcls.pfcAsyncConnection
    $connection = $async.Connect($null, $null, $null, $null)
    $session = $connection.Session
}
catch { $_; Write-Output "Could not connect to Creo session."; exit }

function Close-Connection {
    try { if ($null -ne $connection) { $connection.Disconnect($null) } } catch {}
    foreach ($o in @($session,$connection,$async)) { try { if ($null -ne $o) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($o) | Out-Null } } catch {} }
}

$model = $session.GetActiveModel()
if ($null -eq $model) { Close-Connection; throw "No active model. Open the jig part first." }
Write-Host "  Connected: $($model.FileName)" -ForegroundColor Green

$modelFile = ""; try { $modelFile = [string]$model.FileName } catch {}
if ($modelFile -match '\.asm(\.\d+)?$') {
    Write-Host ""
    Write-Host "  STOP: active model is an ASSEMBLY. Open the jig PART itself and re-run." -ForegroundColor Yellow
    Close-Connection
    exit 1
}

# config suppress + finally
$origVisibleMapkeys = $null; $origDynamicPreview = $null
try { $v = $session.GetConfigOptionValues("visible_mapkeys"); if ($null -ne $v -and $v.Count -gt 0) { $origVisibleMapkeys = $v.Item(0) } } catch {}
try { $v = $session.GetConfigOptionValues("dynamic_preview"); if ($null -ne $v -and $v.Count -gt 0) { $origDynamicPreview = $v.Item(0) } } catch {}
try { $session.SetConfigOption("visible_mapkeys", "no") | Out-Null; $session.SetConfigOption("dynamic_preview", "no") | Out-Null } catch {}

try {
    $pfcType = New-Object -ComObject pfcls.pfcModelItemType
    Initialize-DrilljigCore -Session $session -Model $model -TypeObj $pfcType -DataDir $ScriptDir -Log $null

    Write-Host ""
    Write-Host "  Method: select 3 perpendicular planes (X/Y/Z-normal) -> ProCmdDatumCsys -> OK." -ForegroundColor Cyan
    Write-Host "  Their intersection is the csys origin; the plane order sets the axis assignment." -ForegroundColor DarkGray

    # ========================================================================
    # STEP 1 - capture the 3 planes IN ORDER, each by a single click + ENTER.
    # ReuseBase note: any datum plane works (a default datum or an offset plane);
    # they only need to be mutually perpendicular so they meet at one point.
    # ========================================================================
    Write-Host ""
    Write-Host "  Click each plane in Creo, in this order: X-normal, then Y-normal, then Z-normal." -ForegroundColor Cyan
    $planeIds = @(); $seen = @{}
    foreach ($axis in @('X','Y','Z')) {
        Read-Host "    Click the $axis-normal plane, then press ENTER"
        $id = Read-SelectedId
        if ($null -eq $id) { Write-Host "  Nothing selected for $axis - aborting (no csys)." -ForegroundColor Yellow; exit 1 }
        if ($seen.ContainsKey([int]$id)) { Write-Host "  $axis reused a plane already picked - pick 3 DISTINCT planes. Aborting." -ForegroundColor Yellow; exit 1 }
        $seen[[int]$id] = $true; $planeIds += [int]$id
        Write-Host "      $axis-normal plane feature id = $id" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host ("  Planes (X/Y/Z-normal order): {0}" -f ($planeIds -join ", ")) -ForegroundColor Green
    if ($Verbose) { Write-Host ("  Macro: {0}" -f (Build-CsysFromPlanesMacro -PlaneIds $planeIds)) -ForegroundColor DarkGray }

    $go = Read-Host "  Create the coordinate system at their intersection? (y/N)"
    if ($go -notmatch '^[Yy]') { Write-Host "  Skipped - nothing created." -ForegroundColor Yellow; exit 0 }

    # ========================================================================
    # STEP 2 - fire the csys (canary-gated: a NEW feature must appear).
    # ========================================================================
    $cs = Invoke-IndexCsys -PlaneIds @($planeIds) -Show
    Write-Host ""
    if ($cs.Ok) {
        Write-Host ("  CREATED: coordinate system feature id {0} at the 3-plane intersection." -f $cs.NewFeatId) -ForegroundColor Green
        Write-Host "  VERIFY VISUALLY: the origin sits at the intersection; if an axis is mirrored," -ForegroundColor Yellow
        Write-Host "  swap the plane pick order (the order sets the axis assignment)." -ForegroundColor DarkGray
    } else {
        Write-Host ("  NOT created: {0}" -f $cs.Reason) -ForegroundColor Yellow
        Write-Host "  (Check Creo: did the csys dialog open? The recorded widget names may need a" -ForegroundColor DarkGray
        Write-Host "   refresh for this build, or the 3 planes may not be mutually perpendicular.)" -ForegroundColor DarkGray
    }

} finally {
    if ($null -ne $origVisibleMapkeys) { try { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null } catch {} }
    if ($null -ne $origDynamicPreview) { try { $session.SetConfigOption("dynamic_preview",  $origDynamicPreview)  | Out-Null } catch {} }
    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($pfcType) | Out-Null } catch {}
    try { $connection.Disconnect($null) } catch {}
    foreach ($o in @($model,$session,$connection,$async)) { try { if ($null -ne $o) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($o) | Out-Null } } catch {} }
    [System.GC]::Collect()
}

Write-Host ""
