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
. (Join-Path $libDir 'wizard.ps1')
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
# TOP-plane symmetric chip-relief (curved_relief.ps1). Fires OnPoll + the DrawPrompt
# closure (its body reads captured $wiz/$ci); fires PlanePrompt only when no path (the
# by-id pre-select "misses"). Returns Cut=$true so the loop's relief-tally branch runs.
function Invoke-FastenerRelief     { param($Session,$Model,$TypeObj,$ComponentPath,$TopPlaneId,$ReliefDepth,$BodyIndex,$DrawPrompt,$PlanePrompt,$OnPoll,$TimeoutMs) if ($null -ne $OnPoll) { try { & $OnPoll } catch {} } $viaPlane = ($null -ne $ComponentPath -and [int]$TopPlaneId -gt 0); if (-not $viaPlane -and $null -ne $PlanePrompt) { try { & $PlanePrompt } catch { Fault 'stub/PlanePrompt' $_.Exception.Message } } if ($null -ne $DrawPrompt) { try { & $DrawPrompt } catch { Fault 'stub/DrawPrompt' $_.Exception.Message } } @{ Cut=$true; ViaPlane=$viaPlane; Reason='' } }
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
    # 6. OnNext - the crux: fire the handler that executes the step's logic.
    if ($FireOnNext -and $null -ne $Step.OnNext) {
        try { [void](& $Step.OnNext $Ctx $Wiz) }
        catch { Fault "$Tag/OnNext($($Step.Key))" $_.Exception.Message; $ok = $false }
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
    # the TOP-plane fastener loop stores {PointId; TopPlaneId=1; ViaPlane; ReliefCut}.
    $C.CurvedHolePairs = @(
        [pscustomobject]@{ PointId=201; TopPlaneId=1; ViaPlane=$true; ReliefCut=$false }
        [pscustomobject]@{ PointId=202; TopPlaneId=1; ViaPlane=$true; ReliefCut=$false }
    )
    $C.CurvedHoleDiaFinal = 0.5
    $C.FastenerHolesMade = 2
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
# STAGE-5 fresh fastener re-selection for chip relief.
function Set-ReliefComps { param($C)
    $C.ReliefComponents = @(
        [pscustomobject]@{ Path = $null; CompIds = @(7); Origin = @(0.0,0.0,0.0) }
        [pscustomobject]@{ Path = $null; CompIds = @(8); Origin = @(1.0,0.0,0.0) }
    )
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
    @{ Name='thickness-fresh';    Steps=@('thickness');        Btns=$false; Next=$false; Setup={ param($c) Set-Bushing $c } }
    @{ Name='thickness-set';      Steps=@('thickness');        Btns=$false; Next=$true;  Setup={ param($c) Set-Bushing $c; $c.Thickness=0.25; $c.ThicknessValid=$true } }
    @{ Name='standoff-fresh';     Steps=@('standoff');         Btns=$false; Next=$true;  Setup={ param($c) Set-Bushing $c } }
    # chip-relief depth (Bushing stage): default-seeded (valid), a typed positive, and 0 (disabled).
    @{ Name='relief-depth-fresh'; Steps=@('relief-depth');     Btns=$false; Next=$true;  Setup={ param($c) Set-Bushing $c } }
    @{ Name='relief-depth-set';   Steps=@('relief-depth');     Btns=$false; Next=$true;  Setup={ param($c) Set-Bushing $c; $c.ReliefDepth=0.3; $c.ReliefDepthValid=$true } }
    @{ Name='relief-depth-zero';  Steps=@('relief-depth');     Btns=$false; Next=$true;  Setup={ param($c) Set-Bushing $c; $c.ReliefDepth=0.0; $c.ReliefDepthValid=$true } }
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
    # STAGE-5 SLOTS: select (relief on / disabled skip) + loop (relief on / disabled / no-body).
    # slot-loop's Add_Click drives Invoke-FastenerRelief per ReliefComponents.
    @{ Name='slot-select-on';     Steps=@('slot-select');      Btns=$true;  Next=$true;  Setup={ param($c) Set-Drilled $c; Set-ReliefComps $c } }
    @{ Name='slot-select-skip';   Steps=@('slot-select');      Btns=$false; Next=$true;  Setup={ param($c) Set-Drilled $c; $c.ReliefDepth=0.0 } }
    @{ Name='slot-loop-relief';   Steps=@('slot-loop');        Btns=$true;  Next=$true;  Setup={ param($c) Set-Drilled $c; Set-ReliefComps $c } }
    @{ Name='slot-loop-norelief'; Steps=@('slot-loop');        Btns=$true;  Next=$true;  Setup={ param($c) Set-Drilled $c; $c.ReliefDepth=0.0 } }
    @{ Name='slot-loop-nobody';   Steps=@('slot-loop');        Btns=$true;  Next=$true;  Setup={ param($c) Set-Drilled $c; Set-ReliefComps $c; $c.BodyIndex=$null } }
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
    # (build-run-asm sets a .asm active name; build-run-blankmiss forces a blank miss).
    $script:cfActiveName = '004-984-3965-001.prt'
    $script:cfBlankMiss  = $false
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
