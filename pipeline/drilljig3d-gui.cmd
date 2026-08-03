<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -STA -Command "$ScriptDir=((Split-Path -Parent ('%~dp0'.TrimEnd('\')))+'\'); $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

# ============================================================================
# drilljig3d-gui.cmd - GUI front-end for the CURVED (conformal) drill jig
# ============================================================================
# The curved analog of drilljig-gui.cmd: a single never-closing WinForms WIZARD
# window that drives the end-to-end curved-jig flow, re-sequenced INPUT-FIRST: the
# operator front-loads every pick + number, then the build fires hands-free, then the
# only remaining interaction (drawing the relief rectangles) happens at the end.
#   Fasteners (select) -> Surface (pick) -> Conditions (bushing + chip clearance + dia)
#   -> Build (one hands-free click: conformal blank -> corner round -> drill all holes
#   normal to the surface) -> Slots (per already-selected fastener, draw one chip-relief
#   rectangle). Every UNAVOIDABLE Creo mouse pick a RunMacro cannot replay (select the
#   FASTENERS, pick the SURFACE, pick each relief PLANE + DRAW each relief rectangle) is
#   its own arm/verify/draw step.
#
# AUTO SIZING (user 2026-07-29): the operator never types the wall thickness or the
# offset. The Conditions 'chip-clearance' card (Standard 0.25" / Tight-custom) is the
# ONLY sizing input: part thickness = bushing length + chip clearance (the blank
# thickens to wall + relief), and the offset is always 0 (flush).
#
# CHIP-RELIEF (TOP-plane symmetric method): a terminal STAGE 5. STAGE 4 drills all
# holes hands-free; STAGE 5 REUSES the fasteners selected up front (no re-pick) and, per
# fastener, opens an extrude -> operator picks that fastener's TOP plane (ProCmdFtExtrude
# REJECTS a raw-COM component-plane pre-select, so the pick is explicit -- see
# [[project_curved_relief_extrude_plane]]) -> operator draws ONE rectangle -> SYMMETRIC
# remove-material extrude (typed depth = 2 x clearance) cuts a pocket straddling the plane.
# The retired tangent-plane per-hole slot stage stays on disk (lib\curved_slots.ps1 /
# curved_slot_macros.ps1) for the console tool drilljig3d.cmd.
#
# ADDITIVE + ISOLATED: this file EDITS NOTHING existing. It reuses lib\wizard.ps1
# (the framework) + the CURVED libs (jig_tree is console-only, so the tree WALK is
# reimplemented as wizard cards here; the catalog resolvers come from drilljig_core;
# the STAGE-1 offset+thicken engine + On-Point normal-hole macro come from the NEW
# lib\conformal_blank.ps1; tangent planes from lib\tangent_plane.ps1; curved slots
# from lib\curved_slots.ps1 + lib\curved_slot_macros.ps1). drilljig-gui.cmd and every
# shared lib it uses are LEFT UNTOUCHED. Open the jig PART (not the .asm).
#
# Stages: Welcome / Fasteners / Surface / Conditions / Build / Slots / Done.
#
# Flags:
#   --default-orient : drill with Creo's default On-Point direction (skip the
#                      per-hole TOP-plane orientation).
#   --no-relief      : disable chip relief (alias --no-slots): seeds the Bushing
#                      relief-depth field to 0 (no thicken bump, no pockets).
#   --relief-depth N : chip-relief depth in inches (alias --slot-depth N; default
#                      0.25). The Bushing relief-depth step prefills from this; the
#                      symmetric pocket is cut 2N deep (N each side of the TOP plane).
#   --no-corner-round: skip the Surface-stage auto corner-rounding of the blank.
#   --corner-radius N: corner-round fillet radius in inches (default 0.25). Same
#                      contract as drilljig.cmd / drilljig-gui.cmd.
#   --no-flip        : do NOT flip the thicken side. The thicken FLIPS by DEFAULT so
#                      the blank grows AWAY from the part (one maindashInst0.Flip,
#                      matching the confirmed-live console drilljig3d.cmd). Use
#                      --no-flip only if a part defaults the correct way.
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
# --no-relief (alias --no-slots) DISABLES chip relief for the whole run (no thicken
# bump, no pockets). It seeds the Bushing relief-depth field to 0; the operator can
# still type a positive value there to re-enable.
$NoSlots       = ($ScriptArgs -match '(?i)-{1,2}no-(slots|relief)')
# Thicken direction: FLIP the material side so the blank grows AWAY from the part
# (the operator confirmed the default thickens the wrong way). ON by default, matching
# the confirmed-live console drilljig3d.cmd (which fires one unconditional maindashInst0.Flip
# 2026-06-24). --no-flip reverts to the un-flipped side for a part that defaults correctly.
$Flip          = (-not ($ScriptArgs -match '(?i)-{1,2}no-flip'))
# Chip-relief depth default (prefills the Bushing relief-depth field). --relief-depth N
# (alias --slot-depth N) overrides. --no-relief/--no-slots forces the default to 0.
$SlotDepthAbs  = 0.25
$mSd = [regex]::Match($ScriptArgs, '(?i)--(slot|relief)-depth\s+([0-9]*\.?[0-9]+)')
if ($mSd.Success) { $sdv = [double]$mSd.Groups[2].Value; if ($sdv -gt 0) { $SlotDepthAbs = $sdv } }
if ($NoSlots) { $SlotDepthAbs = 0.0 }
# --no-radial-pattern DISABLES the auto radial/axis chip-relief pattern (draw ONE pocket +
# pattern the rest around the cylinder axis when the fasteners are uniformly spaced). When
# disabled (or when the fasteners are NOT uniformly spaced), the Slots stage draws every
# pocket by hand (the proven per-fastener loop). See [[project_curved_radial_slot_pattern]].
$NoRadialPattern = ($ScriptArgs -match '(?i)-{1,2}no-radial-pattern')
# Corner-round flags (same contract as drilljig.cmd / drilljig-gui.cmd): the Surface
# stage auto-rounds the conformal blank's sharp corner edges after it builds. Default
# radius 0.25; --no-corner-round skips it.
$NoCornerRound = ($ScriptArgs -match '(?i)-{1,2}no-corner-round')
$CornerRadius  = 0.25
$mCr = [regex]::Match($ScriptArgs, '(?i)--corner-radius\s+([0-9]*\.?[0-9]+)')
if ($mCr.Success) { $crv = [double]$mCr.Groups[1].Value; if ($crv -gt 0) { $CornerRadius = $crv } }
# Chip-relief creates NO reference/guide planes (user 2026-07-29 "no need to create those
# reference planes for chip relief -- just open the sketch on the top plane immediately"). The
# Slots stage pre-selects the fastener's TOP plane and opens the extrude straight away.

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
. (Join-Path $ScriptDir 'lib\curved_surface_radius.ps1') # RADIAL-DISTANCE override producer (Read-CurvedRadialGeomFromBuffer -> $ctx.RadialAxisGeom)
. (Join-Path $ScriptDir 'lib\edge_round.ps1')          # hands-free corner round (sweep-by-id -> filter length -> round); global:Invoke-CurvedCornerRound wraps it for the step closures
. (Join-Path $ScriptDir 'lib\curved_fastener_hole.ps1') # fastener-plane point + reference/direction hole macros (the curvedholes workflow)
. (Join-Path $ScriptDir 'lib\tangent_plane.ps1')       # Build-TangentPlaneMacro / Invoke-TangentPlane
. (Join-Path $ScriptDir 'lib\curved_slots.ps1')        # Get-CurvedSlotPlan / Test-CurvedSlotPlan (kept: the console tool drilljig3d.cmd still uses these)
. (Join-Path $ScriptDir 'lib\curved_slot_macros.ps1')  # Invoke-CurvedSlotArm/Cut/PlanRun (kept: the console tool still uses these)
. (Join-Path $ScriptDir 'lib\curved_relief.ps1')       # Build-CurvedReliefArm/CutMacro + Invoke-FastenerRelief (TOP-plane SYMMETRIC chip-relief, cut inline per fastener) + the RADIAL/axis-pattern macros + driver (Build-RadialPattern*/Invoke-CurvedReliefRadialPattern)
. (Join-Path $ScriptDir 'lib\curved_radial.ps1')       # PURE radial/axis-pattern PLANNING math (Get-CurvedRadialPatternPlan / Test-CurvedRadialPatternPlan): count + angular increment + seed + uniform-spacing gate from the fastener positions
. (Join-Path $ScriptDir 'lib\wizard.ps1')              # New-WizardStep / Show-Wizard / the wizard framework
. (Join-Path $ScriptDir 'lib\bushing_svg.ps1')         # Draw-BushingSchematic / Get-BushingHeadDia (2D bushing render on the tree-done confirmation)
. (Join-Path $ScriptDir 'lib\wpf3d_preview.ps1')       # Build-BushingModelGroup (WPF Media3D bushing 3D, shown beside the 2D; guarded below)
# WPF gate: the bushing 3D view needs the WPF assemblies + an STA thread (the launcher
# passes -STA). GUARDED: if WPF is unavailable the confirmation degrades to the 2D
# schematic only (never crashes). $script:Wpf3dOk gates New-BushingViewportHost.
$script:Wpf3dOk = $false
try {
    Add-Type -AssemblyName PresentationCore -ErrorAction Stop
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    Add-Type -AssemblyName WindowsBase -ErrorAction Stop
    Add-Type -AssemblyName WindowsFormsIntegration -ErrorAction Stop
    $script:Wpf3dOk = $true
} catch { $script:Wpf3dOk = $false }
. (Join-Path $ScriptDir 'lib\curved_gui_helpers.ps1')  # ported canvas helpers + bushing render (Add-BushingConfirmSchematic/New-BushingViewportHost) + bushing-tree walk + Set-CurvedChipClearance
# The step-group libs (each defines ONE global Add-Curved*Steps -Steps fn), plus the
# INPUT-FIRST composition layer. Flow: front-load ALL input (Fasteners select ->
# Surface pick -> Conditions numbers), then STAGE 4 'build-run' fires the whole build
# hands-free (blank -> corners -> drill all holes), then STAGE 5 'slot-*' re-selects
# the fasteners + draws each chip-relief rectangle. curved_gui_steps_compose.ps1 owns
# the canonical step ORDER (Add-CurvedInputFirstSteps) so the shell + the offline
# harnesses build the identical ordered inventory. The manual-datum-point Drill lib is
# left on disk but not wired in.
. (Join-Path $ScriptDir 'lib\curved_gui_steps_bushing.ps1')
. (Join-Path $ScriptDir 'lib\curved_gui_steps_surface.ps1')
. (Join-Path $ScriptDir 'lib\curved_gui_steps_fastener.ps1')
. (Join-Path $ScriptDir 'lib\curved_gui_steps_build.ps1')
. (Join-Path $ScriptDir 'lib\curved_gui_steps_slots.ps1')
. (Join-Path $ScriptDir 'lib\curved_gui_steps_done.ps1')
. (Join-Path $ScriptDir 'lib\curved_gui_steps_compose.ps1')

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
    throw ("The ACTIVE model is the top assembly ($modelFile). In the top-down assembly, ACTIVATE the drilljig PART first (right-click it in the tree -> Activate) so feature creation routes into the jig part, then re-run. (Once activated, the active model is the .prt and the tool proceeds; you can still Ctrl-click the curved surface + the fasteners' planes as external references.)")
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
#   ChipClearance/ChipClearanceValid/ClearanceMode  - the Conditions 'chip-clearance' card
#                                        input; Set-CurvedChipClearance DERIVES the two below.
#   Thickness/StandOff       - conformal-blank inputs, DERIVED (never typed): Thickness = wall
#                              (= bushing length, or a fallback); StandOff = 0 (always flush).
#   SurfIds                  - the picked surface id(s) (Surface stage)
#   BlankMade/BodyIndex/BodyId/BodyName  - conformal blank result (Surface stage output)
#   FastenerComponents/FastenerSurfId  - STAGE-1 fastener select (components picked once;
#                                        FastenerComponents = @({Path;CompIds;Origin}),
#                                        FastenerSurfId defaulted in the Surface stage)
#   FastenerHoleDia/FastenerHoleDiaValid/FastenerHolesMade  - fastener drill state
#   CurvedHolePairs/CurvedHoleDiaFinal  - STAGE-4 drill output;
#                                         CurvedHolePairs = @({PointId;TopPlaneId;ViaPlane;ReliefCut})
#   TangentOrient/DefaultOrient/FlipThicken/NoSlots/SlotDepthAbs  - flags
#   NoCornerRound/CornerRadius/CornersRounded/BlankThickness  - corner-round state (STAGE-4 build)
#   ReliefDepth/ReliefDepthValid  - chip-relief depth `r` = the chip clearance (set by
#                                   Set-CurvedChipClearance): the STAGE-4 thicken grows to
#                                   wall + r; STAGE 5 cuts a symmetric 2r pocket on each
#                                   fastener's TOP plane; 0 = no relief.
#   ReliefComponents  - LEGACY (seeded, unused): STAGE 5 now reuses FastenerComponents /
#                       CurvedHolePairs directly rather than re-selecting the fasteners.
#   ReliefsCut  - count of relief pockets cut (tallied in STAGE 5)
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
    # *Valid flags seeded to match each step's real semantics + Build defaults: a blank
    # thickness is INVALID (bushing step sets ThicknessValid=$false on blank), a blank
    # standoff == 0 == flush is VALID. Seeding here hardens the ctx contract so a Validate
    # that reads a *Valid flag can never see $null->$false before its Build runs.
    Thickness = $null; ThicknessValid = $false; StandOff = 0.0; StandOffValid = $true
    SurfIds = @(); BlankMade = $false; SurfaceArmed = $false
    # RadialAxisGeom - RADIAL-DISTANCE override the surface-arm verify reads off the
    # picked follow-surface when it is a cylinder (Read-CurvedRadialGeomFromBuffer,
    # lib\curved_surface_radius.ps1): @{Valid;Radius;AxisPt[3];AxisDir[3];SurfId;Reason}
    # or $null. Consumed by the radial-pattern (Slots) step as the "accept override"
    # input; $null / Valid=$false => that step self-computes its increment + axis pick.
    RadialAxisGeom = $null
    BodyIndex = $null; BodyId = $null; BodyName = $null
    # guided offset->pick->finish state (Surface stage; before-sets + stamps for the canary/diff)
    BlankBeforeFeat = @{}; BlankBeforeSurf = @{}; BlankBeforeBodies = @{}
    BlankStamp = $null; BlankStamp2 = $null; OffsetFeatId = $null; QuiltSurfIds = @()
    # fastener-plane hole stage (the dumbclaude workflow: select components once,
    # loop each, resolve TOP/SIDE/FRONT by ID, drill normal-to-surface via tangent planes)
    FastenerComponents = @(); FastenerSurfId = $null
    FastenerHoleDia = $null; FastenerHoleDiaValid = $false; FastenerHolesMade = 0
    DrillPerHole = $false; HolePairs = @(); HoleDiaDrill = $null; HoleDiaDrillValid = $false; DrillArmed = $false
    HolesMade = 0; CurvedHolePairs = @(); CurvedHoleDiaFinal = $null
    TangentOrient = (-not $DefaultOrient); DefaultOrient = [bool]$DefaultOrient
    FlipThicken = [bool]$Flip
    NoSlots = [bool]$NoSlots; SlotDepthAbs = [double]$SlotDepthAbs
    SlotSkip = $false; SlotPlan = $null; SlotsCut = $false
    # Slots-stage two-step (slot-arm/slot-finish) state: SlotArmed gates slot-finish's
    # Validate; SlotRunIndex is the per-fastener cursor; SlotsDone is terminal; SlotAnyCut
    # tracks whether any pocket cut; SlotBaseFeat/SlotBaseStamp are the per-armed-fastener
    # cut-canary baseline (captured by the arm, read by the finish). No *Valid gate flags.
    SlotArmed = $false; SlotRunIndex = 0; SlotsDone = $false; SlotAnyCut = $false
    SlotBaseFeat = @{}; SlotBaseStamp = $null
    # per-fastener re-arm failure counter (escape-hatch guard so a wedged Creo can't trap the
    # operator in an endless Finish->fail loop; reset on each successful arm). See slot-finish.
    SlotRearmFails = 0
    # RADIAL / AXIS chip-relief pattern (user 2026-07-30/31): draw ONE seed pocket then axis-pattern
    # the rest around the cylinder. SlotPatternMode 'perfastener' (default) | 'radial' (set by slot-arm
    # when Get-CurvedRadialPatternGroups yields >=1 pattern group); SlotRadialGroups = the grouped plan
    # (1 regular pattern + count-2 accommodations for non-equi-angular columns, user 2026-07-31 "multiple
    # patterns if not constant angles"); SlotSeedFeatId = the first cut's feature id (the shared pattern
    # seed). NoRadialPattern (flag) forces per-fastener.
    # RadialAxisFeatId 0 = operator picks the axis (proven); >0 = feed a datum axis by id
    # (EXPERIMENTAL, off by default - the user's "axis from a plane intersection" idea, gated
    # by radialpat-probe). THE AXIS OVERRIDE (self-compute + accept override) comes from
    # $ctx.RadialAxisGeom (AxisDir/AxisPt, seeded above) - the "Read radial distance" half's
    # live cylinder read (lib\curved_surface_radius.ps1); the Slots step feeds it to
    # Get-CurvedRadialPatternPlan -Axis/-AxisPoint when Valid, else self-derives from the
    # fastener positions. See [[project_curved_radial_slot_pattern]].
    SlotPatternMode = 'perfastener'; SlotRadialGroups = $null; SlotSeedFeatId = 0
    NoRadialPattern = [bool]$NoRadialPattern; RadialAxisFeatId = 0
    # chip-relief (Bushing stage input -> Surface thicken bump + Fasteners inline cut).
    # ReliefDepth seeds from the --relief-depth/--slot-depth flag (0 when --no-relief);
    # the Bushing relief-depth step lets the operator change it. A seeded numeric default
    # is VALID (0 = disabled is a valid choice). ReliefsCut tallies the pockets actually cut.
    ReliefDepth = [double]$SlotDepthAbs; ReliefDepthValid = $true; ReliefsCut = 0
    # CHIP CLEARANCE (Conditions 'chip-clearance' card, user 2026-07-29): the SINGLE value
    # that sizes the blank. Set-CurvedChipClearance derives Thickness (wall = bushing len),
    # ReliefDepth (= clearance), and StandOff (= 0) from it. ClearanceMode is 'standard' |
    # 'custom' | $null (undecided). Seeded to the --slot-depth/--relief-depth default so the
    # standard card + Next path are meaningful; ChipClearanceValid seeded true (0.25 is valid).
    ChipClearance = [double]$SlotDepthAbs; ChipClearanceValid = $true; ClearanceMode = $null
    # STAGE-5 chip-relief now REUSES the fasteners selected up front (FastenerComponents /
    # CurvedHolePairs) -- it does NOT re-select. ReliefComponents kept (seeded) for back-compat
    # with any older reader; unused by the current slot-loop.
    ReliefComponents = @()
    # corner-round state (Surface stage, after blank-build): CornerRadius/NoCornerRound
    # are the flag values; CornersRounded is the done-flag the step sets on a verified
    # round (gates the idempotent revisit + the RebuiltNotice).
    NoCornerRound = [bool]$NoCornerRound; CornerRadius = [double]$CornerRadius; CornersRounded = $false
    # the ACTUAL thicken applied to the blank (wall + relief), recorded by blank-build so
    # corner-round targets the blank's true through-thickness edge length (not wall alone).
    BlankThickness = $null
    Is3dPrint = $false
}

# ============================================================================
# BUILD THE STEP LIST (each group lib appends its steps in stage order)
# ============================================================================
$steps = New-Object System.Collections.ArrayList
# INPUT-FIRST composition: ONE adder builds every step in the canonical order
# (Welcome / Fasteners select / Surface pick / Conditions inputs / Build batch /
# Slots relief / Done). curved_gui_steps_compose.ps1 owns the order so the shell +
# the offline harnesses see the identical inventory.
Add-CurvedInputFirstSteps   -Steps $steps

# ============================================================================
# RUN THE WIZARD
# ============================================================================
$stages = @('Welcome','Fasteners','Surface','Conditions','Build','Slots','Done')
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
