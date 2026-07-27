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
. (Join-Path $libDir 'tangent_plane.ps1')
. (Join-Path $libDir 'curved_slots.ps1')
. (Join-Path $libDir 'curved_slot_macros.ps1')
. (Join-Path $libDir 'wizard.ps1')
. (Join-Path $libDir 'curved_gui_helpers.ps1')
. (Join-Path $libDir 'curved_gui_steps_bushing.ps1')
. (Join-Path $libDir 'curved_gui_steps_surface.ps1')
. (Join-Path $libDir 'curved_gui_steps_drill.ps1')
. (Join-Path $libDir 'curved_gui_steps_relief.ps1')

# --- STUB only the COM-touching functions (canned valid-shaped returns) -------
# Pure pieces (bushing catalog resolvers, Get-CurvedSlotPlan/Test-CurvedSlotPlan,
# Build-NormalHoleMacro) run FOR REAL.
function Initialize-DrilljigCore { param($Session,$Model,$TypeObj,$DataDir,$Log) }
function Invoke-ConformalBlank {
    param($Session,$Model,$TypeObj,$SurfIds,$Thickness,$StandOff,$OnPoll,$TimeoutMs)
    if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }
    @{ Made=$true; Phase1=$true; Phase2=$true; OffsetSym='d7'; ThickSym='d9'; OffsetHeld=$true; ThicknessHeld=$true;
       QuiltSurfIds=@(55); OffsetFeatId=7; BodyIndex=1; BodyId=20; BodyName='CONFORMAL_BLANK'; Reason='' }
}
function Invoke-TangentPlane {
    param($PointId,$SurfaceId,$OnPoll)
    if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }
    @{ Created=$true; PlaneId=(900 + [int]$PointId); Reason='' }
}
function Resolve-SelectedSurfaces { param($Session,$TypeObj) @{ Surfaces=@(41); Rejected=@() } }
function Resolve-SelectedPoints   { param($Session,$TypeObj) @{ Points=@(201,202,203); Rejected=@() } }
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
$fakeModel = [pscustomobject]@{ VersionStamp = 1 }
$fakeModel | Add-Member ScriptMethod Regenerate { param($x) } -Force
$fakeModel | Add-Member ScriptMethod GetActiveModel { $this } -Force -ErrorAction SilentlyContinue
$fakeSession = [pscustomobject]@{}
$fakeSession | Add-Member ScriptMethod RunMacro { param($m) $script:cfModel.VersionStamp = ([int]$script:cfModel.VersionStamp + 1) } -Force
$fakeSession | Add-Member ScriptMethod GetActiveModel { $script:cfModel } -Force
$fakeSession | Add-Member ScriptMethod CurrentSelectionBuffer { [pscustomobject]@{ } } -Force
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
        DrillPerHole = $false; HolePairs = @(); HoleDiaDrill = $null; HoleDiaDrillValid = $false; DrillArmed = $false
        HolesMade = 0; CurvedHolePairs = @(); CurvedHoleDiaFinal = $null
        TangentOrient = $true; DefaultOrient = $false
        NoSlots = $false; SlotDepthAbs = 0.25
        SlotSkip = $false; SlotPlan = $null; SlotsCut = $false
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
    Add-CurvedBushingSteps -Steps $steps
    Add-CurvedSurfaceSteps -Steps $steps
    Add-CurvedDrillSteps   -Steps $steps
    Add-CurvedReliefSteps  -Steps $steps
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
function Set-Blank   { param($C) Set-Surface $C; $C.BlankMade = $true; $C.BodyIndex = 1; $C.BodyId = 20; $C.BodyName = 'CONFORMAL_BLANK' }
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
    $C.CurvedHolePairs = @(
        [pscustomobject]@{ PointId=201; SurfaceId=41; TangentPlaneId=1101 }
        [pscustomobject]@{ PointId=202; SurfaceId=41; TangentPlaneId=1102 }
    )
    $C.CurvedHoleDiaFinal = 0.5
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
    @{ Name='surface-arm-fresh';  Steps=@('surface-arm');      Btns=$true;  Next=$true;  Setup={ param($c) Set-Bushing $c } }
    @{ Name='surface-arm-set';    Steps=@('surface-arm');      Btns=$true;  Next=$true;  Setup={ param($c) Set-Bushing $c; $c.SurfIds=@(41) } }
    @{ Name='surface-run-ready';  Steps=@('surface-run');      Btns=$false; Next=$true;  Setup={ param($c) Set-Bushing $c; Set-Surface $c } }
    @{ Name='surface-run-built';  Steps=@('surface-run');      Btns=$true;  Next=$true;  Setup={ param($c) Set-Bushing $c; Set-Blank $c } }
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
    @{ Name='relief-intro-3dp';   Steps=@('relief-intro');     Btns=$false; Next=$true;  Setup={ param($c) Set-Drilled $c; $c.Is3dPrint=$true } }
    @{ Name='relief-intro-metal'; Steps=@('relief-intro');     Btns=$false; Next=$true;  Setup={ param($c) Set-Drilled $c; $c.Is3dPrint=$false } }
    @{ Name='relief-intro-noslot';Steps=@('relief-intro');     Btns=$false; Next=$true;  Setup={ param($c) Set-Drilled $c; $c.NoSlots=$true } }
    @{ Name='relief-intro-noplane';Steps=@('relief-intro');    Btns=$false; Next=$true;  Setup={ param($c) Set-Holes $c; $c.CurvedHolePairs=@([pscustomobject]@{PointId=201;SurfaceId=41;TangentPlaneId=0}) } }
    @{ Name='relief-plan-ready';  Steps=@('relief-plan');      Btns=$false; Next=$true;  Setup={ param($c) Set-Drilled $c; $c.SlotSkip=$false } }
    @{ Name='relief-plan-skip';   Steps=@('relief-plan');      Btns=$false; Next=$true;  Setup={ param($c) Set-Drilled $c; $c.SlotSkip=$true } }
    @{ Name='relief-run-planned'; Steps=@('relief-run');       Btns=$false; Next=$true;  Setup={ param($c) Set-Drilled $c; $c.SlotSkip=$false; $c.SlotPlan=(Get-CurvedSlotPlan -Holes @([pscustomobject]@{Id=201;PlaneId=1101;RowKey=$null},[pscustomobject]@{Id=202;PlaneId=1102;RowKey=$null}) -SlotWidth 0.5 -Mode 'per-hole') } }
    @{ Name='relief-run-skip';    Steps=@('relief-run');       Btns=$false; Next=$true;  Setup={ param($c) Set-Drilled $c; $c.SlotSkip=$true } }
    @{ Name='relief-run-cut';     Steps=@('relief-run');       Btns=$true;  Next=$true;  Setup={ param($c) Set-Drilled $c; $c.SlotsCut=$true; $c.SlotPlan=(Get-CurvedSlotPlan -Holes @([pscustomobject]@{Id=201;PlaneId=1101;RowKey=$null}) -SlotWidth 0.5 -Mode 'per-hole') } }
    @{ Name='done-clean';         Steps=@('done');             Btns=$false; Next=$true;  Setup={ param($c) Set-Drilled $c; $c.SlotsCut=$true } }
    @{ Name='done-skipslot';      Steps=@('done');             Btns=$false; Next=$true;  Setup={ param($c) Set-Drilled $c; $c.SlotSkip=$true } }
    @{ Name='done-nothing';       Steps=@('done');             Btns=$false; Next=$true;  Setup={ param($c) } }
)

Write-Host "  -- render + fuzz + DRIVE each step across the state matrix --" -ForegroundColor White
foreach ($sc in $scenarios) {
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
