<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
echo.
pause
exit /b %errorlevel%
#>

# ============================================================================
# csys-negoffset-probe.cmd - does a NEGATIVE csys-axis datum-plane offset flip
#                            the plane to the -axis side?  (the one live unknown
#                            behind drilljig index-first only working for hole 1)
# ============================================================================
# WHY THIS EXISTS
# --------------------------------------------------------------------------
# In drilljig INDEX-FIRST mode the base coordinate system is built AT the chosen
# index hole and every OTHER hole's grid plane is offset RELATIVE to it:
#     offset = (gridCoord - indexCoord) * flip          (STAGE 2.5)
# That subtraction is CORRECT and offline-proven: for a row {0,2,4,6} indexed at
# X=4 the effective offsets are  -4, -2, 0, +2  (run_orthogrid_tests.ps1). So the
# code already "knows when to put a negative vs a positive offset."
#
# BUT: when the index hole is hole #1 (the min corner) EVERY offset is >= 0, so
# the toolkit has NEVER actually created a NEGATIVE-offset datum plane -- not
# here, not in the box/slot/anchor planes (all positive). Whether Creo's
# datum-plane dialog honors a negative value in `t1.constr_dim1` (moving the plane
# to the -axis side) vs treating it as a magnitude is therefore UNVERIFIED. If a
# negative is NOT honored, a middle/other index hole drills the -side holes on the
# wrong side -- exactly the "only works for hole 1" symptom.
#
# This probe isolates that single question: it creates TWO datum planes offset
# from a coordinate system's axis by ID (the SAME lib recipe drilljig uses --
# Build-CsysOffsetPlaneMacro / New-CsysOffsetPlane), one at +MAG and one at -MAG,
# then asks YOU which side the -MAG plane landed on.
#   * -MAG on the OPPOSITE side of +MAG  -> negatives WORK -> drilljig index-first
#     is correct for ANY index hole (no code change needed).
#   * -MAG on the SAME side (or no plane) -> negatives are NOT honored by this
#     dialog -> the fix needs a DIRECTION-FLIP widget. Record it: rerun with
#     `visible_mapkeys yes`, create a datum plane offset from a csys axis and FLIP
#     its direction by hand, and transcribe the flip token (e.g. a `t1.constr_flip1`
#     Activate) into Build-CsysOffsetPlaneMacro so a negative offset is sent as
#     abs(offset)+flip. (mine-don't-guess: [[reference_mine_trail_files_for_widgets]])
#
# Canary-gated: a plane counts only if a NEW feature appears
# ([[feedback_canary_must_not_assume_on_failure]]). The two planes are THROWAWAY
# -- delete them (and any base csys this made) after reading the result.
#
# FLAGS:  --axis X|Y|Z   (default X)     --mag <number>   (default 2)
# Open the jig PART (not .asm). ONE Creo session.
# ============================================================================

$Host.UI.RawUI.WindowTitle = "CSYS-NEGOFFSET-PROBE"
$ErrorActionPreference = "Stop"

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

# args
$axis = 'X'
$mAx = [regex]::Match($ScriptArgs, '(?i)--axis\s+([XYZxyz])')
if ($mAx.Success) { $axis = $mAx.Groups[1].Value.ToUpper() }
$mag = 2.0
$mMag = [regex]::Match($ScriptArgs, '(?i)--mag\s+([0-9]*\.?[0-9]+)')
if ($mMag.Success) { $m = [double]$mMag.Groups[1].Value; if ($m -gt 0) { $mag = $m } }

# shared engine (same dot-source set as csysinator.cmd so Get-SelectByIdMacro etc.
# resolve at fire time in one scope)
. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')
. (Join-Path $ScriptDir 'lib\orthogrid.ps1')
. (Join-Path $ScriptDir 'lib\orthogrid_points.ps1')
. (Join-Path $ScriptDir 'lib\drilljig_core.ps1')

Write-Host ""
Write-Host "  CSYS-NEGOFFSET-PROBE - does a negative csys-axis offset flip the plane side?" -ForegroundColor White
Write-Host "  ---------------------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ("  Axis = Axis_$axis   magnitude = $mag  (planes at +$mag and -$mag)") -ForegroundColor DarkGray

# ----------------------------------------------------------------------------
# Connect
# ----------------------------------------------------------------------------
try {
    $proc = Get-Process -Name xtop -ErrorAction SilentlyContinue
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

    # ------------------------------------------------------------------------
    # Resolve a coordinate system to offset from. Prefer the part's DEFAULT csys
    # (CSYS_PAT_DEF / PRT_CSYS_DEF / first) -- same call drilljig STAGE 1.9 uses.
    # ------------------------------------------------------------------------
    $refCsysId = Find-DefaultCsysId
    if ($null -eq $refCsysId) {
        Write-Host ""
        Write-Host "  No coordinate system found in the part. Create/keep a datum csys and re-run." -ForegroundColor Yellow
        Close-Connection; exit 1
    }
    Write-Host ("  Offsetting both planes from coordinate system feature id $refCsysId, Axis_$axis." -f $refCsysId) -ForegroundColor Cyan
    Write-Host ""

    # ------------------------------------------------------------------------
    # (1) POSITIVE control: Axis_$axis @ +mag. Canary on a new feature.
    # ------------------------------------------------------------------------
    Write-Host ("  [1/2] creating the +$mag plane (Axis_$axis @ +$mag)..." ) -ForegroundColor Cyan
    $resPos = New-CsysOffsetPlane -CsysFeatId ([int]$refCsysId) -Axis $axis -Offset ([double]$mag) -SkipSymbolWait
    if ($null -eq $resPos.FeatId) {
        Write-Host "  The +$mag plane was NOT created (no new feature). The csys-axis offset recipe" -ForegroundColor Red
        Write-Host "  itself is not landing -- fix that before the negative question is meaningful." -ForegroundColor Red
        Close-Connection; exit 1
    }
    Write-Host ("        +$mag plane created (feature id $($resPos.FeatId))." ) -ForegroundColor Green

    # ------------------------------------------------------------------------
    # (2) THE TEST: Axis_$axis @ -mag. Same recipe, negative value in t1.constr_dim1.
    # ------------------------------------------------------------------------
    Write-Host ("  [2/2] creating the -$mag plane (Axis_$axis @ -$mag)..." ) -ForegroundColor Cyan
    $resNeg = New-CsysOffsetPlane -CsysFeatId ([int]$refCsysId) -Axis $axis -Offset (-1.0 * [double]$mag) -SkipSymbolWait
    if ($null -eq $resNeg.FeatId) {
        Write-Host ""
        Write-Host "  RESULT: the -$mag plane was NOT created (no new feature)." -ForegroundColor Red
        Write-Host "  -> A negative value in t1.constr_dim1 was REJECTED by this build's dialog." -ForegroundColor Red
        Write-Host "     drilljig's negative-side offset planes will fail the same way. FIX: send the" -ForegroundColor Yellow
        Write-Host "     offset as abs(offset) + a DIRECTION-FLIP widget. Record it (see this file's" -ForegroundColor Yellow
        Write-Host "     header) and transcribe the flip token into Build-CsysOffsetPlaneMacro." -ForegroundColor Yellow
        Close-Connection; exit 0
    }
    Write-Host ("        -$mag plane created (feature id $($resNeg.FeatId))." ) -ForegroundColor Green

    # ------------------------------------------------------------------------
    # Both planes exist -> the operator eyeballs WHICH SIDE the -mag plane is on.
    # ------------------------------------------------------------------------
    Write-Host ""
    Write-Host "  Both planes were created. LOOK at them in Creo:" -ForegroundColor White
    Write-Host ("    * the +$mag plane (id $($resPos.FeatId)) is on the +Axis_$axis side of the csys." ) -ForegroundColor White
    Write-Host ("    * WHERE is the -$mag plane (id $($resNeg.FeatId))?" ) -ForegroundColor White
    Write-Host ""
    Write-Host "    S = on the SAME side as the +plane (both stacked one way)" -ForegroundColor DarkGray
    Write-Host "    O = on the OPPOSITE side (mirrored across the csys) -- the expected/correct result" -ForegroundColor DarkGray
    $ans = Read-Host "  Which side is the -$mag plane on? (O = opposite / S = same)"

    Write-Host ""
    if ($ans -match '^[Oo]') {
        Write-Host "  RESULT: negatives WORK. A negative t1.constr_dim1 flips the plane to the -axis side." -ForegroundColor Green
        Write-Host "  -> drilljig index-first is already CORRECT for ANY index hole (the (grid-index)" -ForegroundColor Green
        Write-Host "     subtraction produces the right signs and Creo honors them). No code change needed." -ForegroundColor Green
        Write-Host "     If a middle-index run still looks mirrored, that is the csys AXIS orientation, not" -ForegroundColor DarkGray
        Write-Host "     the sign -- use --index-flip-x / --index-flip-z." -ForegroundColor DarkGray
    } elseif ($ans -match '^[Ss]') {
        Write-Host "  RESULT: negatives are NOT honored -- the dialog treated -$mag as a magnitude (+$mag)." -ForegroundColor Red
        Write-Host "  -> This is the 'only works for hole 1' root cause. FIX: change Build-CsysOffsetPlaneMacro" -ForegroundColor Yellow
        Write-Host "     to type abs(offset) into t1.constr_dim1 AND fire a direction-flip widget when the" -ForegroundColor Yellow
        Write-Host "     offset is negative. Record the flip token (see the header) and transcribe it." -ForegroundColor Yellow
    } else {
        Write-Host "  (no clear answer) -- inspect the two planes' sides in Creo and re-run if unsure." -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "  NOTE: both planes (ids $($resPos.FeatId), $($resNeg.FeatId)) are THROWAWAY -- delete them." -ForegroundColor DarkGray
}
finally {
    try {
        if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null }
        if ($null -ne $origDynamicPreview)  { $session.SetConfigOption("dynamic_preview",  $origDynamicPreview)  | Out-Null }
    } catch {}
    Close-Connection
}

Write-Host ""
Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
