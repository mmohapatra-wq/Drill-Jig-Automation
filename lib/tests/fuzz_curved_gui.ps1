# ============================================================================
# lib\tests\fuzz_curved_gui.ps1 - DYNAMIC UI fuzz/drive harness for the CURVED
# drill-jig wizard GUI (pipeline\drilljig3d-gui.cmd).
# ============================================================================
# The curved GUI kept shipping RUNTIME-ONLY handler bugs that the parse-check +
# the build-only smoke test (run_drilljig3d_gui_tests.ps1) could not see:
#   * a wrong-widget offset+thicken macro that SILENTLY no-op'd the Surface stage,
#   * `$pid = 0` in the drill-run OnNext ($PID is a read-only automatic -> THROWS),
#   * unseeded $c.*Valid gate flags.
# The first two only surface when the wizard HANDLER EXECUTES. This harness runs
# the handlers headless -- it is the curved analog of fuzz_gui.ps1 (the flat GUI's
# harness), and it EXECUTES each step's Build + Validate + OnNext (with Creo COM
# stubbed) so a throwing handler is caught here, not by the operator mid-run.
#
# HOW IT WORKS (no Creo, no ShowDialog modal):
#   1. Dot-source the SAME libs drilljig3d-gui.cmd loads, then STUB only the
#      COM-touching functions (Invoke-ConformalBlank / Invoke-TangentPlane /
#      Resolve-Selected* / Wait-ModelModified / Invoke-CurvedSlotPlanRun /
#      Initialize-DrilljigCore) with canned, valid-shaped returns. The PURE pieces
#      (the bushing catalog walk, Get-CurvedSlotPlan/Test-CurvedSlotPlan, the macro
#      string builders) run FOR REAL -- more coverage.
#   2. Build the real $steps by CALLING Add-Curved{Bushing,Surface,Drill,Relief}Steps
#      (the curved GUI exposes its steps as global functions -- no source-region
#      extraction needed, unlike the flat GUI).
#   3. For a matrix of $ctx states (each mid-run configuration), RENDER every step's
#      -Build into a fresh Panel, FUZZ its controls (buttons PerformClick, textboxes
#      TextChanged with junk/valid/empty, Paint via DrawToBitmap), run -Validate, and
#      -- crucially -- FIRE -OnNext on the run/gate steps so the handler code that
#      crashed actually executes.
#   4. ORACLE: the error log (%TEMP%\drilljig-gui-error.log) + a WinForms thread-
#      exception trap + any exception escaping a fired handler. Any of these = a bug.
#
# Additive + offline: does NOT modify the GUI; SKIPS cleanly if WinForms is absent.
# Run:  powershell -ExecutionPolicy Bypass -File lib\tests\fuzz_curved_gui.ps1
# Exit 0 = no UI faults; 1 = at least one fault (printed).
# ============================================================================

$ErrorActionPreference = 'Stop'
$here = $null
try { if ($MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path } } catch {}
if (-not $here -and $PSScriptRoot) { $here = $PSScriptRoot }
if (-not $here) { $here = Split-Path -Parent ([System.IO.Path]::GetFullPath('lib\tests\fuzz_curved_gui.ps1')) }
$libDir = Split-Path -Parent $here
$root   = Split-Path -Parent $libDir

$script:faults = New-Object System.Collections.ArrayList
$script:checks = 0
function Fault { param([string]$Where, [string]$Msg) [void]$script:faults.Add("[$Where] $Msg"); Write-Host "  [FAULT] $Where : $Msg" -ForegroundColor Red }
function Note  { param([string]$Msg) Write-Host "  - $Msg" -ForegroundColor DarkGray }
function Ok    { param([string]$Msg) $script:checks++; Write-Host "  [ok] $Msg" -ForegroundColor DarkGreen }

Write-Host ""
Write-Host "  drilljig3d-gui.cmd (CURVED) DYNAMIC UI FUZZ/DRIVE" -ForegroundColor Cyan
Write-Host ""

# --- WinForms required --------------------------------------------------------
$wf = $false
try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop; Add-Type -AssemblyName System.Drawing -ErrorAction Stop; $wf = $true } catch { $wf = $false }
if (-not $wf) { Write-Host "  [SKIP] WinForms not available headless." -ForegroundColor Yellow; exit 0 }

try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
    [System.Windows.Forms.Application]::add_ThreadException({ param($s,$e) Fault 'WinForms-thread' $e.Exception.Message })
} catch {}

# --- dot-source the real libs (the exact set drilljig3d-gui.cmd loads) --------
. (Join-Path $libDir 'creo_geometry.ps1')
. (Join-Path $libDir 'blind_evaluator.ps1')
. (Join-Path $libDir 'drilljig_core.ps1')
. (Join-Path $libDir 'conformal_blank.ps1')
. (Join-Path $libDir 'edge_round.ps1')
. (Join-Path $libDir 'curved_fastener_hole.ps1')
. (Join-Path $libDir 'tangent_plane.ps1')
. (Join-Path $libDir 'curved_slots.ps1')
. (Join-Path $libDir 'curved_slot_macros.ps1')
. (Join-Path $libDir 'curved_relief.ps1')
. (Join-Path $libDir 'curved_radial.ps1')          # PURE radial/axis-pattern plan (runs FOR REAL; the driver is stubbed below)
. (Join-Path $libDir 'curved_surface_radius.ps1')  # RADIAL-DISTANCE override producer (real; surface-arm's read resolves to it, returns Valid=$false on the empty fake buffer)
. (Join-Path $libDir 'wizard.ps1')
# bushing render libs (the tree-done Build now draws the 2D schematic via the ported
# global Add-BushingConfirmSchematic -> Draw-BushingSchematic/Get-BushingHeadDia). WPF 3D
# is OFF headless ($script:Wpf3dOk = $false), so New-BushingViewportHost is skipped and only
# the GDI+ 2D renders (which DrawToBitmap exercises).
. (Join-Path $libDir 'bushing_svg.ps1')
. (Join-Path $libDir 'wpf3d_preview.ps1')
$script:Wpf3dOk = $false
. (Join-Path $libDir 'curved_gui_helpers.ps1')
. (Join-Path $libDir 'curved_gui_steps_bushing.ps1')
. (Join-Path $libDir 'curved_gui_steps_surface.ps1')
. (Join-Path $libDir 'curved_gui_steps_fastener.ps1')
. (Join-Path $libDir 'curved_gui_steps_build.ps1')
. (Join-Path $libDir 'curved_gui_steps_slots.ps1')
. (Join-Path $libDir 'curved_gui_steps_drill.ps1')
. (Join-Path $libDir 'curved_gui_steps_done.ps1')
. (Join-Path $libDir 'curved_gui_steps_compose.ps1')

# --- STUB only the COM-touching functions (canned valid-shaped returns) -------
# Pure pieces (bushing catalog resolvers, Get-CurvedSlotPlan/Test-CurvedSlotPlan,
# Build-NormalHoleMacro) run FOR REAL.
function Initialize-DrilljigCore { param($Session,$Model,$TypeObj,$DataDir,$Log) }
function Invoke-ConformalBlank {
    param($Session,$Model,$TypeObj,$SurfIds,$Thickness,$StandOff,[switch]$Flip,$OnPoll,$TimeoutMs)
    if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }
    # $script:cfBlankMiss lets a scenario exercise the STAGE-4 blank-miss branch (skip dependents).
    if ($script:cfBlankMiss) { return @{ Made=$false; Changed=$false; Reason='stub: forced miss' } }
    @{ Made=$true; Changed=$true; OffsetSym='d7'; ThickSym='d9'; OffsetHeld=$true; ThicknessHeld=$true;
       BodyIndex=1; BodyId=20; BodyName='CONFORMAL_BLANK'; Reason='' }
}
function Invoke-TangentPlane {
    param($PointId,$SurfaceId,$OnPoll)
    if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }
    @{ Created=$true; PlaneId=(900 + [int]$PointId); Reason='' }
}
# corner round: the Surface-stage 'corner-round' step calls the global wrapper. Stub it
# with a canned all-matched-all-changed result (mirrors a live successful round) so the
# step's chip logic runs its 'built' branch. Fires OnPoll (DoEvents pump). The REAL
# Invoke-AutoCornerRound + Select-LowestDimensionEdges (dot-sourced above) still run in
# run_edge_round_tests.ps1; here we only need the step handler to execute without Creo.
function Invoke-CurvedCornerRound {
    param($Session,$Model,$TypeObj,$Radius=0.25,$Thickness=0,$Tol=0.05,$SweepMax=5000,$BatchSize=40,$OnPoll=$null)
    if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }
    $mode = if ($Thickness -gt 0) { 'thickness' } else { 'auto' }
    $tgt  = if ($Thickness -gt 0) { [double]$Thickness } else { 0.25 }
    @{ Found=8; Target=$tgt; Matched=4; SelfTestOk=$true; BatchesFired=1; ModelChanged=1;
       TotalBatches=1; Aborted=$false; Reason=("rounded 4 edge(s)"); Mode=$mode;
       Lengths=@(@{Len=$tgt;Count=4},@{Len=6.0;Count=4}); LengthSummary=("{0}x4, 6x4" -f $tgt) }
}
# the HANDS-FREE by-ID fastener-loop helpers (curved_fastener_hole.ps1).
function Add-ComponentDefaultPlanesToBuffer {
    param($Session,$Model,$TypeObj,$ComponentPath,[switch]$NoClear)
    @{ Added=3; Roles=@('Top','Side','Front'); Ids=@(11,12,13); Reason='added 3 plane(s): Top/Side/Front' }
}
function Resolve-SelectedPlaneIds { param($Session,$TypeObj) @{ Ids=@(11,12,13); Names=@('TOP','SIDE','FRONT'); Roles=@('Top','Side','Front') } }
function Get-DatumPointIdSet       { param($Model,$TypeObj) @{} }
function Resolve-NewDatumPointIds  { param($Model,$TypeObj,$Before) @(201) }
function Invoke-FastenerPoint      { param($Session,$Model,$TypeObj,$OnPoll,$TimeoutMs) if ($null -ne $OnPoll) { try { & $OnPoll } catch {} } @{ Created=$true; PointId=201; ViaStamp=$false; Reason='' } }
function Invoke-FastenerHole       { param($Session,$Model,$TypeObj,$PointId,$ComponentPath,$TopPlaneId,$DirectionPrompt,$OnPoll,$TimeoutMs) if ($null -ne $OnPoll) { try { & $OnPoll } catch {} } $viaPlane = ($null -ne $ComponentPath -and [int]$TopPlaneId -gt 0); if (-not $viaPlane -and $null -ne $DirectionPrompt) { try { & $DirectionPrompt } catch {} } @{ Drilled=$true; ViaPlane=$viaPlane; Reason='' } }
# TOP-plane symmetric chip-relief (curved_relief.ps1). The GUI now uses the TWO-STEP split:
# Invoke-CurvedReliefArmAt (REAL, curved_gui_steps_slots.ps1) calls Invoke-FastenerReliefArm
# (arm the sketch), and slot-finish calls Invoke-FastenerReliefCut (finish + cut). Stub BOTH
# halves + keep the single-shot wrapper. ARM: fires OnPoll + PlanePrompt only when no PointId
# (the fallback), returns Armed=$true + ViaPlane + a BaseStamp so the cut canary passes. CUT:
# returns Cut=$true (BaseStamp null -> miss). Accepts the NEW named params or PS errors when
# the real slot steps pass them.
function Invoke-FastenerReliefArm { param($Session,$Model,$TypeObj,$ComponentPath,$PointId=0,$SurfaceId=0,$HoleDia=0.0,$TopPlaneId=1,[switch]$GuidePlanes,$PlanePrompt,$OnPoll,$TimeoutMs=30000) if ($null -ne $OnPoll) { try { & $OnPoll } catch {} } if ($script:cfArmMiss) { return @{ Armed=$false; ViaPlane=$false; PlaneId=0; BaseFeat=@{}; BaseStamp=$null; Reason='stub: forced arm miss' } } $fed = ($null -ne $ComponentPath); if (-not $fed -and $null -ne $PlanePrompt) { try { & $PlanePrompt } catch { Fault 'stub/PlanePrompt' $_.Exception.Message } } @{ Armed=$true; ViaPlane=$fed; PlaneId=0; BaseFeat=@{}; BaseStamp=1; Reason='' } }
function Invoke-FastenerReliefCut { param($Session,$Model,$SymDepth=0.0,$BodyIndex=0,$BaseFeat,$BaseStamp,$OnPoll,$TimeoutMs=30000) if ($null -ne $OnPoll) { try { & $OnPoll } catch {} } if ($null -eq $BaseStamp) { return @{ Cut=$false; Reason='no baseline' } } @{ Cut=$true; Reason='' } }
function Invoke-FastenerRelief     { param($Session,$Model,$TypeObj,$ComponentPath,$TopPlaneId,$ReliefDepth,$BodyIndex,$PointId=0,$SurfaceId=0,$HoleDia=0.0,[switch]$GuidePlanes,$DrawPrompt,$PlanePrompt,$OnPoll,$TimeoutMs) if ([double]$ReliefDepth -le 0) { return @{ Cut=$false; ViaPlane=$false; Reason='relief depth <= 0' } } if ($null -ne $OnPoll) { try { & $OnPoll } catch {} } $viaPlane = ([int]$PointId -gt 0 -and [int]$SurfaceId -gt 0); if (-not $viaPlane -and $null -ne $PlanePrompt) { try { & $PlanePrompt } catch { Fault 'stub/PlanePrompt' $_.Exception.Message } } if ($null -ne $DrawPrompt) { try { & $DrawPrompt } catch { Fault 'stub/DrawPrompt' $_.Exception.Message } } @{ Cut=$true; ViaPlane=$viaPlane; Reason='' } }
# RADIAL / AXIS chip-relief pattern driver (curved_relief.ps1). Fires the injected AxisPrompt
# (the operator axis-pick closure -- exercising its $wiz.AskInline body), then returns
# Patterned=$true UNLESS $script:cfRadialMiss forces the miss path (-> the slot-finish fallback
# to the per-fastener loop). NewFeatures mirrors a real count>=1 on success.
function Invoke-CurvedReliefRadialPattern { param($Session,$Model,$TypeObj,$SeedFeatId,$Count,$IncrementDeg,$AxisFeatId=0,[switch]$UseLiveSelection,$AxisPrompt=$null,$OnPoll=$null,$TimeoutMs=30000)
    if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }
    if ([int]$AxisFeatId -le 0 -and $null -ne $AxisPrompt) { try { & $AxisPrompt } catch { Fault 'stub/AxisPrompt' $_.Exception.Message } }
    # $script:cfRadialHardMiss = BOTH attempts miss (-> per-fastener fallback);
    # $script:cfRadialMiss = the raw-COM (attempt 1) misses but the -UseLiveSelection retry succeeds.
    $miss = $false
    if ($script:cfRadialHardMiss) { $miss = $true }
    elseif ($script:cfRadialMiss -and -not $UseLiveSelection) { $miss = $true }
    if ($miss) { return @{ Patterned=$false; NewFeatures=0; ViaAxisId=([int]$AxisFeatId -gt 0); SeedSelected=[bool]$UseLiveSelection; Reason='stub: forced miss' } }
    @{ Patterned=$true; NewFeatures=([Math]::Max(1,[int]$Count-1)); ViaAxisId=([int]$AxisFeatId -gt 0); SeedSelected=$true; Reason='' }
}
# The REAL slot-arm gate (curved_gui_steps_slots.ps1) now enters radial mode ONLY when
# Test-RadialPatternReady (the atomic axis-by-id recipe tokens are recorded, curved_relief.ps1)
# AND RadialAxisFeatId>0. In live use both are absent until probes\radialpat-probe.cmd records
# them, so radial stays dark and the GUI draws per-fastener. For the fuzz we SET the (test)
# tokens process-wide so the radial group-loop wiring is still exercised headless; the radial
# SETUPS below also set RadialAxisFeatId>0. Non-radial scenarios keep RadialAxisFeatId=0 (default)
# so radialReady stays false for them even with the tokens present.
$global:RadialAxisCollectorWidget = 'maindashInst0.ui_pat_axis_ref_TESTONLY'
$global:RadialAxisSelType         = 'Axis'
# guide-plane helper (curved_relief.ps1) -- best-effort; stub returns canned ids so the
# arm path resolves headless (it is called INSIDE the real Invoke-FastenerReliefArm live,
# but here the arm is stubbed above, so this is only needed if a step calls it directly).
function New-CurvedGuidePlanes { param($Session,$Model,$TypeObj,$ComponentPath,$HoleDia=0.5,$Margin=0.125,$Log=$null,$OnPoll=$null,$TimeoutMs=15000) @{ Ids=@(801,802) } }
# fresh buffer-read component path: the loop calls this before the hole to avoid a stale
# $comp.Path handle. Stub returns $script:FuzzBufComp (default $null -> loop uses $comp.Path).
function Get-BufferComponentPath   { param($Session) return $script:FuzzBufComp }
# Get-FeatureIdSet grows with the fake model's VersionStamp (RunMacro bumps it), so a
# before/after diff around a fired macro yields a NEW feature id -> the loop's "drilled"
# canary branch runs (not a permanent miss).
function Get-FeatureIdSet {
    $set = @{}
    $v = 0; try { $v = [int]$script:cfModel.VersionStamp } catch { $v = 0 }
    for ($i = 1; $i -le $v; $i++) { $set[(1000 + $i)] = $true }
    return $set
}
function Resolve-SelectedSurfaces { param($Session,$TypeObj) @{ Surfaces=@(41); Rejected=@() } }
function Resolve-SelectedPoints   { param($Session,$TypeObj) @{ Points=@(201,202,203); Rejected=@() } }
function Get-Comp { param($P) @(0.0, 0.0, 0.0) }
function Wait-ModelModified {
    param($Model,$PreviousStamp,$TimeoutMs=30000,$OnPoll=$null)
    if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }
    return $true
}
function Invoke-CurvedSlotPlanRun {
    param($Plan,$Depth,$BodyIndex,$OnPoll,$DrawPrompt,$VerifyPrompt)
    if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }
    $n = 0; try { $n = [int]$Plan.Count } catch { $n = 1 }
    if ($n -lt 1) { $n = 1 }
    # fire the operator-prompt closures so THEIR bodies (which read $script:GuiWiz) run
    $seed = [pscustomobject]@{ Key = 'hole-1' }
    if ($null -ne $DrawPrompt)   { try { & $DrawPrompt $seed } catch { Fault 'stub/DrawPrompt' $_.Exception.Message } }
    if ($null -ne $VerifyPrompt) { try { [void](& $VerifyPrompt $seed $false) } catch { Fault 'stub/VerifyPrompt' $_.Exception.Message } }
    @{ SeedsCut=$n; SeedsFailed=0; SeedsSkipped=0; Warnings=@() }
}

# a fake $model with a settable VersionStamp + a fake $session that bumps it.
# $script:cfActiveName drives GetActiveModel().FileName so an .asm-active scenario can
# exercise the STAGE-4/STAGE-5 active-model gate (default a .prt -> the gate passes).
$script:cfActiveName = '004-984-3965-001.prt'
$fakeModel = [pscustomobject]@{ VersionStamp = 1; FileName = '004-984-3965-001.prt' }
$fakeModel | Add-Member ScriptMethod Regenerate { param($x) } -Force
$fakeModel | Add-Member ScriptMethod GetActiveModel { $this } -Force -ErrorAction SilentlyContinue
$fakeSession = [pscustomobject]@{}
$fakeSession | Add-Member ScriptMethod RunMacro { param($m) $script:cfModel.VersionStamp = ([int]$script:cfModel.VersionStamp + 1) } -Force
$fakeSession | Add-Member ScriptMethod GetActiveModel { [pscustomobject]@{ FileName = $script:cfActiveName } } -Force
$fakeSession | Add-Member ScriptMethod CurrentSelectionBuffer { $b = [pscustomobject]@{ }; $b | Add-Member ScriptMethod Clear {} -Force; $b | Add-Member ScriptMethod Contents { @() } -Force; $b } -Force
$script:cfModel = $fakeModel; $script:cfSession = $fakeSession

# top-level vars the steps / helpers read
$ScriptDir = $root
$script:macroFailures = 0
$treePath = Join-Path $root 'docs\drill_jig_decision_tree.json'

# error-log oracle: snapshot length before any rendering
$logPath = Join-Path ([System.IO.Path]::GetTempPath()) 'drilljig-gui-error.log'
$logBefore = if (Test-Path $logPath) { (Get-Item $logPath).Length } else { 0 }

# ----------------------------------------------------------------------------
# fresh $ctx builder - MIRRORS the drilljig3d-gui.cmd initializer (incl. the
# seeded *Valid gate flags).
# ----------------------------------------------------------------------------
function New-CurvedCtx {
    $c = @{
        Session = $fakeSession; Model = $fakeModel; Type = $null
        TreeRoot = $null; TreeNode = $null; TreeDone = $false
        TreeHistory = [System.Collections.ArrayList]::new()
        Path  = [System.Collections.ArrayList]::new()
        Picks = [System.Collections.ArrayList]::new()
        PendingSpec = $null; BushStage = $null
        BushID = $null; BushOdFirst = $false; BushOdGroups = $null; BushOD = $null; BushOdOptions = $null
        BushLenValue = $null; BushLenLabel = $null; BushLenIsCustom = $false; BushLenCustomText = ''; BushLenValid = $true
        BushCustom = $false; BushCustomOd = $null; BushCustomOdLabel = $null; BushCustomOdText = ''; BushCustomOdValid = $false
        Grouped = $null
        HoleDia = $null; HoleDiaFinal = $null; BushingLen = $null
        Thickness = $null; ThicknessValid = $false; StandOff = 0.0; StandOffValid = $true
        SurfIds = @(); BlankMade = $false; SurfaceArmed = $false
        BodyIndex = $null; BodyId = $null; BodyName = $null
        FastenerComponents = @(); FastenerSurfId = $null
        FastenerHoleDia = $null; FastenerHoleDiaValid = $false; FastenerHolesMade = 0
        DrillPerHole = $false; HolePairs = @(); HoleDiaDrill = $null; HoleDiaDrillValid = $false; DrillArmed = $false
        HolesMade = 0; CurvedHolePairs = @(); CurvedHoleDiaFinal = $null
        TangentOrient = $true; DefaultOrient = $false; FlipThicken = $false
        NoSlots = $false; SlotDepthAbs = 0.25
        SlotSkip = $false; SlotPlan = $null; SlotsCut = $false
        SlotArmed = $false; SlotRunIndex = 0; SlotsDone = $false; SlotAnyCut = $false
        SlotBaseFeat = @{}; SlotBaseStamp = $null
        # RADIAL / AXIS chip-relief pattern (mirrors the shell $ctx seeds)
        SlotPatternMode = 'perfastener'; SlotRadialGroups = $null; SlotSeedFeatId = 0
        NoRadialPattern = $false; RadialAxisFeatId = 0; RadialAxisGeom = $null
        ReliefDepth = 0.25; ReliefDepthValid = $true; ReliefsCut = 0; ReliefComponents = @()
        NoCornerRound = $false; CornerRadius = 0.25; CornersRounded = $false; BlankThickness = $null
        Is3dPrint = $false
    }
    try {
        $tr = Get-Content $treePath -Raw | ConvertFrom-Json
        $c.TreeRoot = @($tr)[0]; $c.TreeNode = @($tr)[0]
    } catch {}
    return $c
}

# ----------------------------------------------------------------------------
# a fake $wiz controller with every method the curved steps call.
# ----------------------------------------------------------------------------
function New-CurvedWiz {
    param([string]$AskAnswer = 'Yes')
    $w = [pscustomobject]@{ AskLog = (New-Object System.Collections.ArrayList); Answer = $AskAnswer }
    foreach ($m in 'SetChip','Refresh','Log','Pump','SetProgress','BeginRun','EndRun','MarkCommitted','SetStatus','Next','Rerender','GoToStepKey') {
        $w | Add-Member ScriptMethod $m { param($a,$b,$c) } -Force
    }
    $w | Add-Member ScriptMethod AskInline { param($h,$t,$btns='OK',$noact=$false) [void]$this.AskLog.Add($h); return $this.Answer } -Force
    $w | Add-Member ScriptMethod LogError { param($e,$where) } -Force
    return $w
}

# ----------------------------------------------------------------------------
# render a step's Build into a fresh panel, then FUZZ + drive it.
# ----------------------------------------------------------------------------
function Invoke-CurvedFuzzStep {
    param($Step, $Ctx, $Wiz, [string]$Tag, [switch]$FireButtons, [switch]$FireOnNext)
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Size = New-Object System.Drawing.Size(880, 520)
    $ok = $true
    # 1. Build
    try { & $Step.Build $panel $Ctx $Wiz | Out-Null }
    catch { Fault "$Tag/Build($($Step.Key))" $_.Exception.Message; $ok = $false }
    # 2. Validate
    try { if ($null -ne $Step.Validate) { [void](& $Step.Validate $Ctx) } }
    catch { Fault "$Tag/Validate($($Step.Key))" $_.Exception.Message; $ok = $false }
    # 3. Paint (fires Add_Paint .GetNewClosure() bodies) on the panel + child panels
    $allPanels = New-Object System.Collections.ArrayList
    $collect = { param($p) foreach ($cc in $p.Controls) { if ($cc -is [System.Windows.Forms.Panel]) { [void]$allPanels.Add($cc); & $collect $cc } } }
    & $collect $panel
    foreach ($pp in @($panel) + @($allPanels.ToArray())) {
        try {
            if ($pp.Width -gt 0 -and $pp.Height -gt 0) {
                $bmp = New-Object System.Drawing.Bitmap([Math]::Min(700,$pp.Width), [Math]::Min(460,$pp.Height))
                $pp.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0,0,$bmp.Width,$bmp.Height)))
                $bmp.Dispose()
            }
        } catch { Fault "$Tag/Paint($($Step.Key))" $_.Exception.Message; $ok = $false }
    }
    # 4. fuzz TEXTBOXES (fire TextChanged closures with junk/valid/empty/fractions)
    $textboxes = New-Object System.Collections.ArrayList
    $ctb = { param($p) foreach ($cc in $p.Controls) { if ($cc -is [System.Windows.Forms.TextBox]) { [void]$textboxes.Add($cc) }; if ($cc.Controls.Count -gt 0) { & $ctb $cc } } }
    & $ctb $panel
    foreach ($tb in $textboxes.ToArray()) {
        foreach ($v in @('abc','-5','0','1.5','','3/4','1e9','  ','.25')) {
            try { $tb.Text = $v } catch { Fault "$Tag/TextChanged($($Step.Key))" ("val='$v' -> " + $_.Exception.Message); $ok = $false; break }
        }
    }
    # 5. fuzz BUTTONS (PerformClick -> Add_Click .GetNewClosure() bodies)
    if ($FireButtons) {
        $buttons = New-Object System.Collections.ArrayList
        $cbn = { param($p) foreach ($cc in $p.Controls) { if ($cc -is [System.Windows.Forms.Button]) { [void]$buttons.Add($cc) }; if ($cc.Controls.Count -gt 0) { & $cbn $cc } } }
        & $cbn $panel
        foreach ($bn in $buttons.ToArray()) {
            try { $bn.PerformClick() }
            catch { Fault "$Tag/Click($($Step.Key):'$($bn.Text)')" $_.Exception.Message; $ok = $false }
        }
    }
    # 6. OnNext - the crux: fire the handler that executes the step's logic. A 'run' step
    # may SELF-LOOP by returning $false (slot-finish re-arms the next fastener + stays), so
    # pump OnNext up to a bound until it advances ($true) -- exercising the whole loop, not
    # just one iteration. Bounded so an always-$false handler cannot spin forever.
    if ($FireOnNext -and $null -ne $Step.OnNext) {
        $guard = 0
        do {
            $adv = $true
            try { $adv = [bool](& $Step.OnNext $Ctx $Wiz) }
            catch { Fault "$Tag/OnNext($($Step.Key))" $_.Exception.Message; $ok = $false; break }
            $guard++
        } while ((-not $adv) -and ($guard -lt 12))
    }
    $panel.Dispose()
    return $ok
}

# ----------------------------------------------------------------------------
# BUILD the real $steps from the curved step-group functions.
# ----------------------------------------------------------------------------
$steps = New-Object System.Collections.ArrayList
try {
    # the INPUT-FIRST composition (exactly what the shell builds) ...
    Add-CurvedInputFirstSteps   -Steps $steps
    # ... plus the UNWIRED manual-datum-point Drill stage (not in the shell) so its
    # drill-* scenarios below still have steps to look up by key (coverage only).
    Add-CurvedDrillSteps        -Steps $steps
    Ok ("built {0} real curved wizard steps" -f $steps.Count)
} catch { Fault 'build-steps' $_.Exception.Message }
$stepArr = @($steps.ToArray())
function Get-CStep { param([string]$Key) $stepArr | Where-Object { $_.Key -eq $Key } | Select-Object -First 1 }

# ---- helpers to put ctx into plausible mid-run states -----------------------
function Set-Bushing { param($C, [double]$Dia = 0.5)
    $C.HoleDia = $Dia; $C.HoleDiaFinal = $Dia; $C.BushingLen = 0.75
    $C.TreeDone = $true
    [void]$C.Picks.Add([pscustomobject]@{ HoleDiameter=$Dia; BushingID=0.25; BushingLength=0.75; Bushing='Drill Bushing | OD 1/2 x ID 1/4'; PartNumber='8493A072'; Outcome='x' })
}
function Set-Surface { param($C) $C.SurfIds = @(41); $C.Thickness = 0.25; $C.ThicknessValid = $true; $C.StandOff = 0.0; $C.StandOffValid = $true }
function Set-Blank   { param($C) Set-Surface $C; $C.BlankMade = $true; $C.BodyIndex = 1; $C.BodyId = 20; $C.BodyName = 'CONFORMAL_BLANK'; $C.BlankThickness = 0.5 }
function Set-Fasteners { param($C)
    Set-Blank $C
    $C.FastenerComponents = @(
        [pscustomobject]@{ Path = $null; CompIds = @(7);  Origin = @(0.0,0.0,0.0) }
        [pscustomobject]@{ Path = $null; CompIds = @(8);  Origin = @(1.0,0.0,0.0) }
    )
    $C.FastenerSurfId = 41
    $C.FastenerHoleDia = 0.5; $C.FastenerHoleDiaValid = $true
}
function Set-Holes   { param($C)
    Set-Blank $C
    $C.HolePairs = @(
        [pscustomobject]@{ PointId=201; SurfaceId=41; TangentPlaneId=0 }
        [pscustomobject]@{ PointId=202; SurfaceId=41; TangentPlaneId=0 }
    )
    $C.HoleDiaDrill = 0.5; $C.HoleDiaDrillValid = $true
}
function Set-Drilled { param($C)
    Set-Holes $C
    $C.HolesMade = 2
    # the fastener loop stores {PointId; TopPlaneId=1; ViaPlane; ReliefCut; CompPath}. The
    # PointId + CompPath let the Slots stage build a tangent sketch plane + guide planes with
    # NO re-selection. FastenerSurfId (the tangent-plane surface) makes the by-id relief path fire.
    $C.CurvedHolePairs = @(
        [pscustomobject]@{ PointId=201; TopPlaneId=1; ViaPlane=$true; ReliefCut=$false; CompPath=([pscustomobject]@{}) }
        [pscustomobject]@{ PointId=202; TopPlaneId=1; ViaPlane=$true; ReliefCut=$false; CompPath=([pscustomobject]@{}) }
    )
    $C.CurvedHoleDiaFinal = 0.5
    $C.FastenerSurfId = 41
    $C.FastenerHolesMade = 2
}
# RADIAL: 4 fasteners on a circle (centered (10,-3,2), R=5, at 0/90/180/270) so
# Get-CurvedRadialPatternPlan.CanPattern is TRUE -> slot-arm picks radial mode + swaps the
# seed to items[0], and slot-finish fires Invoke-CurvedReliefRadialPattern. Origins are on
# every CurvedHolePair (aligned 1:1 with the slot items).
function Set-RadialFasteners { param($C)
    Set-Blank $C
    $C.HolesMade = 4
    $C.CurvedHolePairs = @(
        [pscustomobject]@{ PointId=201; TopPlaneId=1; ViaPlane=$true; ReliefCut=$false; CompPath=([pscustomobject]@{}); Origin=@(15.0,-3.0,2.0) }
        [pscustomobject]@{ PointId=202; TopPlaneId=1; ViaPlane=$true; ReliefCut=$false; CompPath=([pscustomobject]@{}); Origin=@(10.0, 2.0,2.0) }
        [pscustomobject]@{ PointId=203; TopPlaneId=1; ViaPlane=$true; ReliefCut=$false; CompPath=([pscustomobject]@{}); Origin=@( 5.0,-3.0,2.0) }
        [pscustomobject]@{ PointId=204; TopPlaneId=1; ViaPlane=$true; ReliefCut=$false; CompPath=([pscustomobject]@{}); Origin=@(10.0,-8.0,2.0) }
    )
    $C.CurvedHoleDiaFinal = 0.5
    $C.FastenerSurfId = 41
    $C.RadialAxisFeatId = 55   # stub datum-axis id so radialReady passes (real path is probe-gated)
    $C.FastenerHolesMade = 4
    $C.FastenerComponents = @(
        [pscustomobject]@{ Path=$null; CompIds=@(7);  Origin=@(15.0,-3.0,2.0) }
        [pscustomobject]@{ Path=$null; CompIds=@(8);  Origin=@(10.0, 2.0,2.0) }
        [pscustomobject]@{ Path=$null; CompIds=@(9);  Origin=@( 5.0,-3.0,2.0) }
        [pscustomobject]@{ Path=$null; CompIds=@(10); Origin=@(10.0,-8.0,2.0) }
    )
    $C.FastenerHoleDia = 0.5; $C.FastenerHoleDiaValid = $true
}
# NON-UNIFORM angular layout (user 2026-07-31 "multiple patterns if not constant angles"): 5
# fasteners at 0/30/60/90 (a 30-deg run) + a stray at 200 -> Get-CurvedRadialPatternGroups yields
# 1 regular pattern (count 4 @ 30) + 1 count-2 accommodation -> the slot-finish group loop fires 2.
function Set-RadialFastenersMulti { param($C)
    Set-Blank $C
    $mk = { param($deg) $a=$deg*[Math]::PI/180.0; ,@([double](10+5*[Math]::Cos($a)), [double](-3+5*[Math]::Sin($a)), 2.0) }
    $degs = @(0.0,30.0,60.0,90.0,200.0)
    $C.CurvedHolePairs = @()
    $pid0 = 201
    foreach ($d in $degs) {
        $o = (& $mk $d)
        $C.CurvedHolePairs = @($C.CurvedHolePairs) + @([pscustomobject]@{ PointId=$pid0; TopPlaneId=1; ViaPlane=$true; ReliefCut=$false; CompPath=([pscustomobject]@{}); Origin=$o })
        $pid0++
    }
    $C.HolesMade = 5; $C.FastenerHolesMade = 5; $C.CurvedHoleDiaFinal = 0.5; $C.FastenerSurfId = 41
    $C.RadialAxisFeatId = 55   # stub datum-axis id so radialReady passes (real path is probe-gated)
    # a live cylinder axis (so the plan derives cleanly even for the mixed set): +Z through (10,-3,2)
    $C.RadialAxisGeom = @{ Valid=$true; Radius=5.0; AxisPt=@(10.0,-3.0,2.0); AxisDir=@(0.0,0.0,1.0); SurfId=41; Reason='stub cylinder' }
    $C.FastenerComponents = @(); foreach ($d in $degs) { $C.FastenerComponents = @($C.FastenerComponents) + @([pscustomobject]@{ Path=$null; CompIds=@(7); Origin=(& $mk $d) }) }
    $C.FastenerHoleDia = 0.5; $C.FastenerHoleDiaValid = $true
}
# INPUT-FIRST: all input entered but the blank NOT yet built (STAGE-4 build-run fresh).
function Set-Inputs { param($C)
    Set-Bushing $C
    $C.SurfIds = @(41); $C.Thickness = 0.25; $C.ThicknessValid = $true; $C.StandOff = 0.0; $C.StandOffValid = $true
    $C.FastenerComponents = @(
        [pscustomobject]@{ Path = $null; CompIds = @(7); Origin = @(0.0,0.0,0.0) }
        [pscustomobject]@{ Path = $null; CompIds = @(8); Origin = @(1.0,0.0,0.0) }
    )
    $C.FastenerSurfId = 41; $C.FastenerHoleDia = 0.5; $C.FastenerHoleDiaValid = $true
}
# ============================================================================
# STATE MATRIX - render + fuzz + DRIVE each step across configurations.
# FireOnNext is set wherever executing the handler is the coverage target
# (that is where $pid / the ctx-gate / the wrong-widget bugs would throw).
# ============================================================================
$scenarios = @(
    @{ Name='welcome';            Steps=@('welcome');          Btns=$true;  Next=$true;  Setup={ param($c) } }
    @{ Name='tree-root';          Steps=@('tree');             Btns=$true;  Next=$false; Setup={ param($c) } }
    @{ Name='tree-done';          Steps=@('tree');             Btns=$true;  Next=$true;  Setup={ param($c) Set-Bushing $c } }
    # chip-clearance (Conditions): the ONE card that derives thickness + relief + offset.
    # undecided (cards render, Next gated off), standard (green preselect + Set-CurvedChipClearance),
    # custom (editable field), and the no-bushing-length fallback wall path.
    @{ Name='chip-clearance-fresh';    Steps=@('chip-clearance'); Btns=$false; Next=$false; Setup={ param($c) Set-Bushing $c } }
    @{ Name='chip-clearance-standard'; Steps=@('chip-clearance'); Btns=$true;  Next=$true;  Setup={ param($c) Set-Bushing $c; $c.ClearanceMode='standard' } }
    @{ Name='chip-clearance-custom';   Steps=@('chip-clearance'); Btns=$false; Next=$true;  Setup={ param($c) Set-Bushing $c; $c.ClearanceMode='custom'; $c.ChipClearance=0.125; $c.ChipClearanceValid=$true } }
    @{ Name='chip-clearance-nolen';    Steps=@('chip-clearance'); Btns=$true;  Next=$true;  Setup={ param($c) Set-Bushing $c; $c.BushingLen=$null; $c.ClearanceMode='standard' } }
    @{ Name='surface-arm-fresh';  Steps=@('surface-arm');      Btns=$true;  Next=$true;  Setup={ param($c) Set-Bushing $c } }
    @{ Name='surface-arm-set';    Steps=@('surface-arm');      Btns=$true;  Next=$true;  Setup={ param($c) Set-Bushing $c; $c.SurfIds=@(41) } }
    # FASTENER SELECT + DIA (STAGE-1 Fasteners select + a STAGE-3 Conditions number; the
    # drill LOOP moved into the STAGE-4 build-run batch).
    @{ Name='fastener-dia-fresh'; Steps=@('fastener-dia');      Btns=$false; Next=$false; Setup={ param($c) Set-Bushing $c; $c.FastenerHoleDia=$null; $c.FastenerHoleDiaValid=$false } }
    @{ Name='fastener-dia-set';   Steps=@('fastener-dia');      Btns=$false; Next=$true;  Setup={ param($c) Set-Bushing $c; $c.FastenerHoleDia=0.5; $c.FastenerHoleDiaValid=$true } }
    @{ Name='fastener-select-fresh';Steps=@('fastener-select'); Btns=$true;  Next=$false; Setup={ param($c) } }
    @{ Name='fastener-select-set';Steps=@('fastener-select');   Btns=$true;  Next=$true;  Setup={ param($c) Set-Fasteners $c } }
    # STAGE-4 BUILD (build-run): the batch OnNext drives blank -> corners -> drill hands-free.
    # fresh (all input, blank NOT yet built), idempotent revisit (RebuiltNotice), blank-miss
    # (skips dependents), and .asm-active (the gate returns $false, nothing mutated).
    @{ Name='build-run-fresh';    Steps=@('build-run');        Btns=$false; Next=$true;  Setup={ param($c) Set-Inputs $c } }
    @{ Name='build-run-idempotent';Steps=@('build-run');       Btns=$true;  Next=$true;  Setup={ param($c) Set-Fasteners $c; $c.FastenerHolesMade=2 } }
    @{ Name='build-run-blankmiss';Steps=@('build-run');        Btns=$false; Next=$true;  Setup={ param($c) Set-Inputs $c; $script:cfBlankMiss=$true } }
    @{ Name='build-run-asm';      Steps=@('build-run');        Btns=$false; Next=$true;  Setup={ param($c) Set-Inputs $c; $script:cfActiveName='top-assy.asm' } }
    # STAGE-5 SLOTS: the flat-DJ TWO-STEP flow (slot-arm opens the first pocket sketch +
    # advances; slot-finish cuts + re-arms the next, self-looping via return-false until done).
    # Fire BOTH steps in sequence; the OnNext pump loops slot-finish across all fasteners.
    # relief on (cuts all), disabled (skip), no-body (skip), and fasteners-only (PointId 0 fallback).
    @{ Name='slot-relief';    Steps=@('slot-arm','slot-finish'); Btns=$true;  Next=$true;  Setup={ param($c) Set-Drilled $c } }
    @{ Name='slot-norelief';  Steps=@('slot-arm','slot-finish'); Btns=$true;  Next=$true;  Setup={ param($c) Set-Drilled $c; $c.ReliefDepth=0.0 } }
    @{ Name='slot-nobody';    Steps=@('slot-arm','slot-finish'); Btns=$true;  Next=$true;  Setup={ param($c) Set-Drilled $c; $c.BodyIndex=$null } }
    @{ Name='slot-fastonly';  Steps=@('slot-arm','slot-finish'); Btns=$true;  Next=$true;  Setup={ param($c) Set-Fasteners $c; $c.CurvedHolePairs=@() } }
    # RADIAL / AXIS pattern: 4 fasteners on a circle -> slot-arm picks radial mode (seed swapped
    # to items[0]), slot-finish cuts the seed then fires the radial driver (axis-prompt closure
    # runs). slot-radial = pattern success (SlotsDone); slot-radial-miss = the driver returns
    # Patterned=$false -> the per-fastener fallback loop draws the rest. Both drive OnNext to
    # completion; the error-log + thread-exception oracles catch any handler throw.
    @{ Name='slot-radial';         Steps=@('slot-arm','slot-finish'); Btns=$true;  Next=$true;  Setup={ param($c) Set-RadialFasteners $c } }
    @{ Name='slot-radial-miss';    Steps=@('slot-arm','slot-finish'); Btns=$true;  Next=$true;  Setup={ param($c) Set-RadialFasteners $c; $script:cfRadialMiss=$true } }
    @{ Name='slot-radial-hardmiss';Steps=@('slot-arm','slot-finish'); Btns=$true;  Next=$true;  Setup={ param($c) Set-RadialFasteners $c; $script:cfRadialHardMiss=$true } }
    @{ Name='slot-radial-multi';   Steps=@('slot-arm','slot-finish'); Btns=$true;  Next=$true;  Setup={ param($c) Set-RadialFastenersMulti $c } }
    @{ Name='slot-radial-off';     Steps=@('slot-arm','slot-finish'); Btns=$true;  Next=$true;  Setup={ param($c) Set-RadialFasteners $c; $c.NoRadialPattern=$true } }
    @{ Name='drill-mode';         Steps=@('drill-mode');       Btns=$true;  Next=$true;  Setup={ param($c) Set-Blank $c } }
    @{ Name='drill-mode-noblank'; Steps=@('drill-mode');       Btns=$true;  Next=$true;  Setup={ param($c) Set-Bushing $c } }
    @{ Name='drill-arm-mode1';    Steps=@('drill-arm-points'); Btns=$true;  Next=$true;  Setup={ param($c) Set-Blank $c; $c.DrillPerHole=$false } }
    @{ Name='drill-arm-mode2';    Steps=@('drill-arm-points'); Btns=$true;  Next=$false; Setup={ param($c) Set-Blank $c; $c.DrillPerHole=$true } }
    @{ Name='drill-arm-mode2-cap';Steps=@('drill-arm-points'); Btns=$true;  Next=$true;  Setup={ param($c) Set-Blank $c; $c.DrillPerHole=$true; $c.HolePairs=@([pscustomobject]@{PointId=201;SurfaceId=41;TangentPlaneId=0}) } }
    @{ Name='drill-dia-fresh';    Steps=@('drill-diameter');   Btns=$false; Next=$false; Setup={ param($c) Set-Holes $c; $c.HoleDiaDrill=$null; $c.HoleDiaDrillValid=$false } }
    @{ Name='drill-dia-set';      Steps=@('drill-diameter');   Btns=$false; Next=$true;  Setup={ param($c) Set-Holes $c } }
    # drill-run OnNext is THE bug site ($pid). Fire it: tangent orient, default orient.
    @{ Name='drill-run-tangent';  Steps=@('drill-run');        Btns=$false; Next=$true;  Setup={ param($c) Set-Holes $c; $c.TangentOrient=$true; $c.DefaultOrient=$false } }
    @{ Name='drill-run-default';  Steps=@('drill-run');        Btns=$false; Next=$true;  Setup={ param($c) Set-Holes $c; $c.TangentOrient=$false; $c.DefaultOrient=$true } }
    @{ Name='drill-run-done';     Steps=@('drill-run');        Btns=$true;  Next=$true;  Setup={ param($c) Set-Drilled $c } }
    # DONE recap (relocated to curved_gui_steps_done.ps1): relief pockets cut, relief
    # requested but none cut, relief disabled (0), and a bare/nothing-done ctx.
    @{ Name='done-relief';        Steps=@('done');             Btns=$false; Next=$true;  Setup={ param($c) Set-Drilled $c } }
    @{ Name='done-relief-missed'; Steps=@('done');             Btns=$false; Next=$true;  Setup={ param($c) Set-Drilled $c; $c.ReliefsCut=0 } }
    @{ Name='done-relief-partial';Steps=@('done');             Btns=$false; Next=$true;  Setup={ param($c) Set-Drilled $c; $c.ReliefsCut=1 } }
    @{ Name='done-norelief';      Steps=@('done');             Btns=$false; Next=$true;  Setup={ param($c) Set-Drilled $c; $c.ReliefDepth=0.0; $c.ReliefsCut=0 } }
    @{ Name='done-nothing';       Steps=@('done');             Btns=$false; Next=$true;  Setup={ param($c) } }
)

Write-Host "  -- render + fuzz + DRIVE each step across the state matrix --" -ForegroundColor White
foreach ($sc in $scenarios) {
    # reset the leaky $script: toggles so a prior scenario cannot bleed into this one
    # (build-run-asm sets a .asm active name; build-run-blankmiss forces a blank miss;
    # slot-radial-miss forces the radial-pattern driver miss).
    $script:cfActiveName = '004-984-3965-001.prt'
    $script:cfBlankMiss  = $false
    $script:cfRadialMiss = $false
    $script:cfRadialHardMiss = $false
    $script:cfArmMiss = $false
    $c = New-CurvedCtx
    try { & $sc.Setup $c } catch { Fault "setup:$($sc.Name)" $_.Exception.Message; continue }
    $wiz = New-CurvedWiz -AskAnswer 'Yes'
    foreach ($sk in $sc.Steps) {
        $st = Get-CStep $sk
        if ($null -eq $st) { Fault "$($sc.Name)" "step '$sk' not found"; continue }
        [void](Invoke-CurvedFuzzStep -Step $st -Ctx $c -Wiz $wiz -Tag $sc.Name -FireButtons:([bool]$sc.Btns) -FireOnNext:([bool]$sc.Next))
    }
}
Ok ("fuzzed + drove {0} scenarios" -f $scenarios.Count)

# ============================================================================
# TARGETED REGRESSION: the drill-run OnNext must NOT assign to a read-only
# automatic (the $pid bug). Drive it with 2 pairs + tangent orient and assert it
# completes, sets HolesMade, and logs NOTHING to the error log. WITHOUT the fix
# ($ptId), the handler throws "Cannot overwrite variable PID" the moment it runs.
# ============================================================================
Write-Host "  -- regression: drill-run OnNext executes (the read-only `$pid crash site) --" -ForegroundColor White
try {
    $c = New-CurvedCtx; Set-Holes $c
    $wiz = New-CurvedWiz
    $drill = Get-CStep 'drill-run'
    $threw = $false
    try { [void](& $drill.OnNext $c $wiz) } catch { $threw = $true; Fault 'reg/drill-run-throw' $_.Exception.Message }
    if (-not $threw) {
        if ([int]$c.HolesMade -eq 2) { Ok "drill-run OnNext drilled 2/2 holes without throwing (no read-only-`$pid regression)" }
        else { Fault 'reg/drill-run' ("drill-run completed but HolesMade={0} (expected 2)" -f $c.HolesMade) }
    }
} catch { Fault 'reg/drill-run-harness' $_.Exception.Message }

# ============================================================================
# TARGETED REGRESSION: the STAGE-4 build-run OnNext must (a) execute WITHOUT throwing
# (it calls only GLOBAL action helpers Invoke-CurvedBlankAction/CornerAction/DrillAll +
# the global engines -- a plain non-global call would throw "term not recognized"), and
# (b) build the blank + round the corners + drill all holes hands-free (BlankMade +
# CornersRounded + FastenerHolesMade), and (c) honor --no-corner-round (drills but does
# not round), and (d) STAY on the step (return $false, NOTHING mutated) when the active
# model is an .asm.
# ============================================================================
Write-Host "  -- regression: build-run OnNext runs the hands-free batch + gates --" -ForegroundColor White
try {
    $build = Get-CStep 'build-run'
    if ($null -eq $build) { Fault 'reg/build-run' "step 'build-run' not found" }
    else {
        # (a)+(b) full batch: blank -> corners -> drill.
        $script:cfActiveName = '004-984-3965-001.prt'; $script:cfBlankMiss = $false
        $c = New-CurvedCtx; Set-Inputs $c
        $wiz = New-CurvedWiz
        $threw = $false; $adv = $null
        try { $adv = (& $build.OnNext $c $wiz) } catch { $threw = $true; Fault 'reg/build-run-throw' $_.Exception.Message }
        if (-not $threw) {
            if ($c.BlankMade -and $c.CornersRounded -and ([int]$c.FastenerHolesMade -eq 2) -and ($adv -eq $true)) {
                Ok "build-run OnNext built blank + rounded corners + drilled 2/2 hands-free (global helpers resolved)"
            } else {
                Fault 'reg/build-run' ("batch ran but Blank={0} Corners={1} Holes={2} adv={3} (expected True/True/2/True)" -f $c.BlankMade, $c.CornersRounded, $c.FastenerHolesMade, $adv)
            }
        }
        # (c) --no-corner-round -> drills but does not round.
        $c2 = New-CurvedCtx; Set-Inputs $c2; $c2.NoCornerRound = $true
        $wiz2 = New-CurvedWiz
        try { [void](& $build.OnNext $c2 $wiz2) } catch { Fault 'reg/build-run-nocorner-throw' $_.Exception.Message }
        if ($c2.BlankMade -and (-not $c2.CornersRounded) -and ([int]$c2.FastenerHolesMade -eq 2)) { Ok "build-run honored --no-corner-round (built + drilled, did not round)" }
        else { Fault 'reg/build-run-nocorner' ("Blank={0} Corners={1} Holes={2} (expected True/False/2)" -f $c2.BlankMade, $c2.CornersRounded, $c2.FastenerHolesMade) }
        # (d) .asm active -> return $false, NOTHING mutated.
        $script:cfActiveName = 'top-assy.asm'
        $c3 = New-CurvedCtx; Set-Inputs $c3
        $wiz3 = New-CurvedWiz
        $adv3 = $null
        try { $adv3 = (& $build.OnNext $c3 $wiz3) } catch { Fault 'reg/build-run-asm-throw' $_.Exception.Message }
        if (($adv3 -eq $false) -and (-not $c3.BlankMade) -and ([int]$c3.FastenerHolesMade -eq 0)) { Ok "build-run .asm gate: stayed on the step, nothing mutated" }
        else { Fault 'reg/build-run-asm' ("adv={0} Blank={1} Holes={2} (expected False/False/0)" -f $adv3, $c3.BlankMade, $c3.FastenerHolesMade) }
        $script:cfActiveName = '004-984-3965-001.prt'
    }
} catch { Fault 'reg/build-run-harness' $_.Exception.Message }

# ============================================================================
# TARGETED REGRESSION: the RADIAL / AXIS chip-relief pattern (user 2026-07-30). With 4
# fasteners on a circle, slot-arm must pick radial mode (SlotPatternMode='radial') + swap
# the seed to items[0]; slot-finish must cut the seed then fire Invoke-CurvedReliefRadialPattern
# and finish (SlotsDone + ReliefsCut == Count). On a driver MISS ($script:cfRadialMiss) it must
# fall back to per-fastener (SlotPatternMode flips back to 'perfastener' and every hole is drawn
# -> ReliefsCut == 4). And --no-radial-pattern must NEVER pick radial mode.
# ============================================================================
Write-Host "  -- regression: radial-pattern auto-selects + patterns / falls back / respects the flag --" -ForegroundColor White
try {
    $arm = Get-CStep 'slot-arm'; $fin = Get-CStep 'slot-finish'
    if ($null -eq $arm -or $null -eq $fin) { Fault 'reg/radial' "slot-arm/slot-finish not found" }
    else {
        # (a) uniform ring -> radial mode + full pattern.
        $script:cfRadialMiss = $false
        $c = New-CurvedCtx; Set-RadialFasteners $c
        $w = New-CurvedWiz
        try { [void](& $arm.OnNext $c $w) } catch { Fault 'reg/radial-arm-throw' $_.Exception.Message }
        if ($c.SlotPatternMode -eq 'radial') { Ok "slot-arm picked radial mode for a uniform ring (SlotRadialGroups set)" }
        else { Fault 'reg/radial-arm' ("SlotPatternMode={0} (expected 'radial')" -f $c.SlotPatternMode) }
        # drive slot-finish to completion (it should finish in ONE call on pattern success).
        $guard = 0; $adv = $false
        do { try { $adv = [bool](& $fin.OnNext $c $w) } catch { Fault 'reg/radial-finish-throw' $_.Exception.Message; break }; $guard++ } while ((-not $adv) -and ($guard -lt 12))
        if ($c.SlotsDone -and ([int]$c.ReliefsCut -eq 4)) { Ok "radial pattern finished: SlotsDone + ReliefsCut=4 (seed + 3 copies)" }
        else { Fault 'reg/radial-finish' ("SlotsDone={0} ReliefsCut={1} (expected True/4)" -f $c.SlotsDone, $c.ReliefsCut) }

        # (b) hands-free (raw-COM) MISS -> the operator-seed-click retry (-UseLiveSelection) SUCCEEDS
        # (the proven channel), so it still PATTERNS (stays radial, ReliefsCut=4).
        $script:cfRadialMiss = $true; $script:cfRadialHardMiss = $false
        $c2 = New-CurvedCtx; Set-RadialFasteners $c2
        $w2 = New-CurvedWiz
        try { [void](& $arm.OnNext $c2 $w2) } catch { Fault 'reg/radial-miss-arm-throw' $_.Exception.Message }
        $g2 = 0; $adv2 = $false
        do { try { $adv2 = [bool](& $fin.OnNext $c2 $w2) } catch { Fault 'reg/radial-miss-finish-throw' $_.Exception.Message; break }; $g2++ } while ((-not $adv2) -and ($g2 -lt 20))
        if (($c2.SlotPatternMode -eq 'radial') -and $c2.SlotsDone -and ([int]$c2.ReliefsCut -eq 4)) { Ok "hands-free miss -> manual-seed-click retry patterned all 4 (ReliefsCut=4, stayed radial)" }
        else { Fault 'reg/radial-miss' ("Mode={0} SlotsDone={1} ReliefsCut={2} (expected radial/True/4)" -f $c2.SlotPatternMode, $c2.SlotsDone, $c2.ReliefsCut) }
        $script:cfRadialMiss = $false

        # (c) HARD miss (both attempts fail) -> fall back to the per-fastener loop; all 4 still cut.
        $script:cfRadialHardMiss = $true
        $c2h = New-CurvedCtx; Set-RadialFasteners $c2h
        $w2h = New-CurvedWiz
        try { [void](& $arm.OnNext $c2h $w2h) } catch { Fault 'reg/radial-hardmiss-arm-throw' $_.Exception.Message }
        $gh = 0; $advh = $false
        do { try { $advh = [bool](& $fin.OnNext $c2h $w2h) } catch { Fault 'reg/radial-hardmiss-finish-throw' $_.Exception.Message; break }; $gh++ } while ((-not $advh) -and ($gh -lt 20))
        if (($c2h.SlotPatternMode -eq 'perfastener') -and $c2h.SlotsDone -and ([int]$c2h.ReliefsCut -eq 4)) { Ok "hard miss fell back to per-fastener + drew all 4 (ReliefsCut=4)" }
        else { Fault 'reg/radial-hardmiss' ("Mode={0} SlotsDone={1} ReliefsCut={2} (expected perfastener/True/4)" -f $c2h.SlotPatternMode, $c2h.SlotsDone, $c2h.ReliefsCut) }
        $script:cfRadialHardMiss = $false

        # (d) --no-radial-pattern -> never radial, even for a uniform ring.
        $c3 = New-CurvedCtx; Set-RadialFasteners $c3; $c3.NoRadialPattern = $true
        $w3 = New-CurvedWiz
        try { [void](& $arm.OnNext $c3 $w3) } catch { Fault 'reg/radial-off-throw' $_.Exception.Message }
        if ($c3.SlotPatternMode -eq 'perfastener') { Ok "--no-radial-pattern kept per-fastener mode on a uniform ring" }
        else { Fault 'reg/radial-off' ("SlotPatternMode={0} (expected 'perfastener')" -f $c3.SlotPatternMode) }

        # (e) NON-UNIFORM (multi-pattern): 5 fasteners (0/30/60/90 + a 200 stray) -> 2 pattern groups
        # (1 regular count-4 @ 30 + 1 count-2 accommodation) -> the group loop fires BOTH -> all 5 cut.
        $script:cfRadialMiss = $false; $script:cfRadialHardMiss = $false
        $c4 = New-CurvedCtx; Set-RadialFastenersMulti $c4
        $w4 = New-CurvedWiz
        try { [void](& $arm.OnNext $c4 $w4) } catch { Fault 'reg/radial-multi-arm-throw' $_.Exception.Message }
        $gpc = 0; try { $gpc = [int]$c4.SlotRadialGroups.PatternCount } catch { $gpc = 0 }
        if (($c4.SlotPatternMode -eq 'radial') -and ($gpc -ge 2)) { Ok ("slot-arm split the non-uniform layout into {0} pattern groups" -f $gpc) }
        else { Fault 'reg/radial-multi-arm' ("Mode={0} PatternCount={1} (expected radial/>=2)" -f $c4.SlotPatternMode, $gpc) }
        $g4c = 0; $adv4 = $false
        do { try { $adv4 = [bool](& $fin.OnNext $c4 $w4) } catch { Fault 'reg/radial-multi-finish-throw' $_.Exception.Message; break }; $g4c++ } while ((-not $adv4) -and ($g4c -lt 20))
        if ($c4.SlotsDone -and ([int]$c4.ReliefsCut -eq 5)) { Ok "multi-pattern: 2 groups fired -> all 5 pockets (seed + 3 regular copies + 1 accommodation)" }
        else { Fault 'reg/radial-multi' ("SlotsDone={0} ReliefsCut={1} (expected True/5)" -f $c4.SlotsDone, $c4.ReliefsCut) }

        # (f) ESCAPE-HATCH guard (review F2 2026-07-31): a persistently failing re-arm (Creo wedged)
        # must NOT trap the operator with no counter. Arm the seed OK, then force EVERY re-arm to fail
        # ($script:cfArmMiss). The no-progress counter must climb past its threshold while the step
        # keeps returning false WITHOUT crashing, advancing the index, or falsely marking SlotsDone --
        # and only the seed pocket is ever cut.
        $script:cfRadialMiss = $false; $script:cfRadialHardMiss = $false; $script:cfArmMiss = $false
        $c5 = New-CurvedCtx; Set-RadialFasteners $c5; $c5.NoRadialPattern = $true   # force per-fastener
        $w5 = New-CurvedWiz
        try { [void](& $arm.OnNext $c5 $w5) } catch { Fault 'reg/f2-arm-throw' $_.Exception.Message }
        $script:cfArmMiss = $true   # from here every re-arm fails (wedged Creo)
        $g5 = 0; $adv5 = $false
        do { try { $adv5 = [bool](& $fin.OnNext $c5 $w5) } catch { Fault 'reg/f2-finish-throw' $_.Exception.Message; break }; $g5++ } while ((-not $adv5) -and ($g5 -lt 6))
        $rfv = 0; try { $rfv = [int]$c5.SlotRearmFails } catch { $rfv = 0 }
        if ((-not $adv5) -and (-not $c5.SlotsDone) -and ($rfv -ge 3) -and ([int]$c5.ReliefsCut -eq 1)) { Ok ("escape-hatch: a wedged re-arm never traps -- no-progress counter climbed to {0}, no false completion (only the seed cut)" -f $rfv) }
        else { Fault 'reg/f2-escape' ("adv={0} SlotsDone={1} SlotRearmFails={2} ReliefsCut={3} (expected false/false/>=3/1)" -f $adv5, $c5.SlotsDone, $rfv, $c5.ReliefsCut) }
        $script:cfArmMiss = $false
    }
} catch { Fault 'reg/radial-harness' $_.Exception.Message }

# ============================================================================
# ORACLE: any NEW error-log entries written during the fuzz?
# ============================================================================
$logAfter = if (Test-Path $logPath) { (Get-Item $logPath).Length } else { 0 }
if ($logAfter -gt $logBefore) {
    $newTxt = ''
    try { $fs = [System.IO.File]::Open($logPath,'Open','Read','ReadWrite'); $fs.Seek($logBefore,'Begin')|Out-Null; $sr = New-Object System.IO.StreamReader($fs); $newTxt = $sr.ReadToEnd(); $sr.Close(); $fs.Close() } catch {}
    Fault 'error-log' ("NEW entries written during fuzz:`n" + $newTxt)
} else {
    Ok "no NEW error-log entries during fuzz"
}

Write-Host ""
if ($script:faults.Count -eq 0) {
    Write-Host ("  CURVED FUZZ RESULT: clean ({0} checks, {1} scenarios, no faults)" -f $script:checks, $scenarios.Count) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("  CURVED FUZZ RESULT: {0} FAULT(S):" -f $script:faults.Count) -ForegroundColor Red
    foreach ($ff in $script:faults) { Write-Host "    - $ff" -ForegroundColor Red }
    exit 1
}
