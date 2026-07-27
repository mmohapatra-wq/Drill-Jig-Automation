<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -STA -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

# ============================================================================
# drilljig3d-gui.cmd - GUI front-end for the CURVED (conformal) drill jig
# ============================================================================
# The curved analog of drilljig-gui.cmd: a single never-closing WinForms WIZARD
# window that drives the SAME end-to-end curved-jig flow as drilljig3d.cmd
# (decision tree -> conformal blank -> normal-to-surface holes -> curved chip-relief
# slots), with no console typing. Every UNAVOIDABLE Creo mouse pick a RunMacro
# cannot replay (pick the SURFACE, pick the target POINTS, DRAW each slot rectangle)
# is its own "arm + verify / arm + draw" step whose Next stays disabled until the
# selection buffer / draw validates.
#
# ADDITIVE + ISOLATED: this file EDITS NOTHING existing. It reuses lib\wizard.ps1
# (the framework) + the CURVED libs (jig_tree is console-only, so the tree WALK is
# reimplemented as wizard cards here; the catalog resolvers come from drilljig_core;
# the STAGE-1 offset+thicken engine + On-Point normal-hole macro come from the NEW
# lib\conformal_blank.ps1; tangent planes from lib\tangent_plane.ps1; curved slots
# from lib\curved_slots.ps1 + lib\curved_slot_macros.ps1). drilljig-gui.cmd and every
# shared lib it uses are LEFT UNTOUCHED. Open the jig PART (not the .asm).
#
# Stages: Welcome / Bushing / Surface / Drill / Relief / Done.
#
# Flags:
#   --default-orient : drill with Creo's default On-Point direction (skip the
#                      per-hole tangent-plane orientation). Default is tangent-orient
#                      ON (curved slots need per-hole tangent planes anyway).
#   --no-slots       : skip the STAGE-3 curved chip-relief slot loop.
#   --slot-depth N   : chip-relief slot depth in inches (default 0.25).
# ============================================================================

$Host.UI.RawUI.WindowTitle = "CURVED DRILL JIG BUILDER"
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

# ============================================================================
# FLAGS
# ============================================================================
$DefaultOrient = ($ScriptArgs -match '(?i)-{1,2}default-orient')
$NoSlots       = ($ScriptArgs -match '(?i)-{1,2}no-slots')
$SlotDepthAbs  = 0.25
$mSd = [regex]::Match($ScriptArgs, '(?i)--slot-depth\s+([0-9]*\.?[0-9]+)')
if ($mSd.Success) { $sdv = [double]$mSd.Groups[1].Value; if ($sdv -gt 0) { $SlotDepthAbs = $sdv } }

# ============================================================================
# SHARED LIBRARIES (dot-source ORDER matters: framework + pure math first, then the
# curved engine, then the GUI helpers + step groups that call all of the above).
# EVERY curved-GUI helper/step function is `function global:` so the wizard's
# .GetNewClosure() handlers resolve it (the closure-scope rule).
# ============================================================================
. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')       # Read-DimValue, Count-Cylinders, ...
. (Join-Path $ScriptDir 'lib\blind_evaluator.ps1')     # (optional hole-count gate; harmless if unused)
. (Join-Path $ScriptDir 'lib\drilljig_core.ps1')       # catalog resolvers + shared COM primitives + Initialize-DrilljigCore
. (Join-Path $ScriptDir 'lib\conformal_blank.ps1')     # STAGE-1 offset+thicken engine + On-Point normal-hole macro + buffer readers
. (Join-Path $ScriptDir 'lib\tangent_plane.ps1')       # Build-TangentPlaneMacro / Invoke-TangentPlane
. (Join-Path $ScriptDir 'lib\curved_slots.ps1')        # Get-CurvedSlotPlan / Test-CurvedSlotPlan
. (Join-Path $ScriptDir 'lib\curved_slot_macros.ps1')  # Invoke-CurvedSlotArm/Cut/PlanRun
. (Join-Path $ScriptDir 'lib\wizard.ps1')              # New-WizardStep / Show-Wizard / the wizard framework
. (Join-Path $ScriptDir 'lib\curved_gui_helpers.ps1')  # ported canvas helpers + bushing-tree walk state machine
# The four step-group libs (each defines ONE global Add-Curved*Steps -Steps fn).
. (Join-Path $ScriptDir 'lib\curved_gui_steps_bushing.ps1')
. (Join-Path $ScriptDir 'lib\curved_gui_steps_surface.ps1')
. (Join-Path $ScriptDir 'lib\curved_gui_steps_drill.ps1')
. (Join-Path $ScriptDir 'lib\curved_gui_steps_relief.ps1')

# ============================================================================
# DECISION TREE (loaded pre-connect; the Bushing stage walks it as cards)
# ============================================================================
$treeRoot = $null
$treePath = Join-Path $ScriptDir 'docs\drill_jig_decision_tree.json'
if (Test-Path $treePath) {
    try {
        $treeJson = Get-Content $treePath -Raw | ConvertFrom-Json
        $treeRoot = @($treeJson)[0]
    } catch { $treeRoot = $null }
}

# ============================================================================
# CONNECT (mirror drilljig-gui.cmd's lifecycle: xtop discovery, single-session
# guard, .prt guard, config-suppress; restored in the finally). ONE session.
# ============================================================================
$procs = @(Get-Process -Name xtop -ErrorAction SilentlyContinue)
if ($procs.Count -eq 0) { throw "Creo (xtop.exe) is not running. Open Creo and the jig PART, then re-run." }
if ($procs.Count -gt 1) { throw "More than one Creo session is open. This tool expects exactly ONE." }
$proc = $procs[0]
$Env:PRO_DIRECTORY    = $proc.Path.TrimEnd("xtop.exe")
$Env:PRO_COMM_MSG_EXE = $proc.Path -replace "xtop.exe", "pro_comm_msg.exe"

Write-Host "  Connecting to Creo..." -NoNewline
try {
    $async = New-Object -ComObject pfcls.pfcAsyncConnection
} catch {
    $vb_path = $proc.Path -replace "Common Files(.*)$", "Parametric\bin\vb_api_register.bat"
    if (Test-Path $vb_path) { Start-Process -Wait -FilePath $vb_path; $async = New-Object -ComObject pfcls.pfcAsyncConnection }
    else { throw "VB API registration script not found." }
}
$connection = $async.Connect($null, $null, $null, $null)
$session = $connection.Session
$model = $null
try { $model = $session.GetActiveModel() } catch {}
if ($null -eq $model) { try { $model = $session.CurrentModel } catch {} }
if ($null -eq $model) { throw "No model open in Creo. Open the jig PART, then re-run." }
$modelFile = ""
try { $modelFile = [string]$model.FileName } catch {}
if ($modelFile -match '\.asm(\.\d+)?$') {
    try { $connection.Disconnect($null) } catch {}
    throw "The active model is an ASSEMBLY ($modelFile). This tool builds a jig blank in a single PART. Open the PART, then re-run."
}
Write-Host " Connected to $modelFile" -ForegroundColor Green

# config-suppress UI noise; restore in finally
$origVisibleMapkeys = $null; $origDynamicPreview = $null
try { $v = $session.GetConfigOptionValues("visible_mapkeys"); if ($null -ne $v -and $v.Count -gt 0) { $origVisibleMapkeys = $v.Item(0) } } catch {}
try { $v = $session.GetConfigOptionValues("dynamic_preview"); if ($null -ne $v -and $v.Count -gt 0) { $origDynamicPreview = $v.Item(0) } } catch {}
try { $session.SetConfigOption("visible_mapkeys", "no") | Out-Null; $session.SetConfigOption("dynamic_preview", "no") | Out-Null } catch {}

$pfcType = New-Object -ComObject pfcls.pfcModelItemType

# Initialize the shared drilljig-core scope with the LIVE session/model so the
# conformal-blank + tangent-plane + curved-slot COM helpers resolve
# $script:DJSession/DJModel/DJType (exactly like drilljig.cmd / the console tool).
try { Initialize-DrilljigCore -Session $session -Model $model -TypeObj $pfcType -DataDir (Join-Path $ScriptDir 'data') } catch {}

# ============================================================================
# WIZARD CONTEXT - the single shared $ctx every step reads/writes. Field-name
# contract for the step-group libs (they must use EXACTLY these names):
#   Session/Model/Type       - live COM handles (run steps rebind $session=$c.Session)
#   TreeRoot/TreeNode/TreeDone/TreeHistory/Path/Picks/PendingSpec/BushStage/Bush*  - tree walk
#   HoleDia/HoleDiaFinal/BushingLen  - resolved hole OD + bushing length (Bushing stage output)
#   Thickness/StandOff       - conformal-blank inputs (Surface stage)
#   SurfIds                  - the picked surface id(s) (Surface stage)
#   BlankMade/BodyIndex/BodyId/BodyName  - conformal blank result (Surface stage output)
#   DrillPerHole/HolePairs/HoleDiaDrill  - drill inputs; HolePairs = @({PointId;SurfaceId;TangentPlaneId})
#   HolesMade/CurvedHolePairs/CurvedHoleDiaFinal  - drill output -> Relief input
#   TangentOrient/DefaultOrient/NoSlots/SlotDepthAbs  - flags
#   SlotSkip/SlotPlan/SlotsCut  - relief state
# ============================================================================
$ctx = @{
    Session = $session; Model = $model; Type = $pfcType
    TreeRoot = $treeRoot; TreeNode = $treeRoot; TreeDone = $false
    TreeHistory = [System.Collections.ArrayList]::new()
    Path  = [System.Collections.ArrayList]::new()
    Picks = [System.Collections.ArrayList]::new()
    PendingSpec = $null; BushStage = $null
    BushID = $null; BushOdFirst = $false; BushOdGroups = $null; BushOD = $null; BushOdOptions = $null
    BushLenValue = $null; BushLenLabel = $null; BushLenIsCustom = $false; BushLenCustomText = ''; BushLenValid = $true
    BushCustom = $false; BushCustomOd = $null; BushCustomOdLabel = $null; BushCustomOdText = ''; BushCustomOdValid = $false
    Grouped = $null
    HoleDia = $null; HoleDiaFinal = $null; BushingLen = $null
    Thickness = $null; StandOff = 0.0
    SurfIds = @(); BlankMade = $false; SurfaceArmed = $false
    BodyIndex = $null; BodyId = $null; BodyName = $null
    DrillPerHole = $false; HolePairs = @(); HoleDiaDrill = $null; DrillArmed = $false
    HolesMade = 0; CurvedHolePairs = @(); CurvedHoleDiaFinal = $null
    TangentOrient = (-not $DefaultOrient); DefaultOrient = [bool]$DefaultOrient
    NoSlots = [bool]$NoSlots; SlotDepthAbs = [double]$SlotDepthAbs
    SlotSkip = $false; SlotPlan = $null; SlotsCut = $false
    Is3dPrint = $false
}

# ============================================================================
# BUILD THE STEP LIST (each group lib appends its steps in stage order)
# ============================================================================
$steps = New-Object System.Collections.ArrayList
Add-CurvedBushingSteps -Steps $steps   # Welcome + Bushing (tree, thickness, standoff)
Add-CurvedSurfaceSteps -Steps $steps   # Surface (arm pick, offset+thicken run)
Add-CurvedDrillSteps   -Steps $steps   # Drill (mode, arm points, diameter, drill run)
Add-CurvedReliefSteps  -Steps $steps   # Relief (intro, plan, run) + Done

# ============================================================================
# RUN THE WIZARD
# ============================================================================
$stages = @('Welcome','Bushing','Surface','Drill','Relief','Done')
$subtitle = "Curved jig - Connected: $([System.IO.Path]::GetFileName($modelFile))"

try {
    $completed = Show-Wizard -Steps @($steps.ToArray()) -Stages $stages -Title 'Curved Drill Jig Builder' -SubTitle $subtitle -Context $ctx
    if ($completed) { Write-Host "  Wizard completed." -ForegroundColor Green }
    else { Write-Host "  Wizard closed before completing." -ForegroundColor Yellow }
} finally {
    try {
        if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null }
        if ($null -ne $origDynamicPreview)  { $session.SetConfigOption("dynamic_preview",  $origDynamicPreview)  | Out-Null }
    } catch {}
    try { $connection.Disconnect($null) } catch {}
    foreach ($h in @('model','session','connection','async','pfcType')) {
        try {
            $obj = Get-Variable -Name $h -ValueOnly -ErrorAction SilentlyContinue
            if ($null -ne $obj -and [System.Runtime.InteropServices.Marshal]::IsComObject($obj)) {
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($obj) | Out-Null
            }
        } catch {}
    }
    try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
}

Write-Host ""
Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
