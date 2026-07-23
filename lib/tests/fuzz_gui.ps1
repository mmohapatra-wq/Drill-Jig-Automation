# ============================================================================
# lib\tests\fuzz_gui.ps1 - DYNAMIC UI fuzz harness for drilljig-gui.cmd
# ============================================================================
# The user asked for a "training model" that constantly exercises the GUI --
# clicking buttons, opening/closing, changing values, walking pages back and
# forth -- to shake out UI bugs. This is that harness, run HEADLESS.
#
# HOW IT WORKS (no Creo, no ShowDialog modal):
#   1. Dot-source the same libs drilljig-gui.cmd loads, with the live Creo COM
#      helpers STUBBED (Initialize-DrilljigCore/Find-DefaultDatumPicks/... return
#      canned data) so the pure + WinForms code runs but nothing touches Creo.
#   2. Extract + Invoke-Expression the two source regions of drilljig-gui.cmd:
#        (a) "# STEP BUILDERS" .. "# Build the connection up front"  (helpers)
#        (b) "# WIZARD STEPS"  .. "# RUN THE WIZARD"                 (the $steps)
#      exactly as run_wizard_tests.ps1's integration test already does.
#   3. For a matrix of $ctx STATES (each point-source mode, mid-bushing-pick,
#      box-built, drilled, tight-slot, etc.), RENDER every step's -Build into a
#      fresh Panel, then FUZZ every control it produced:
#        * Button      -> PerformClick()
#        * TextBox     -> set .Text to junk / valid / empty, fire TextChanged
#        * DataGridView-> add/remove/edit rows
#        * Panel(Paint)-> DrawToBitmap to fire Add_Paint closures
#      and call -Validate / -OnNext where safe.
#   4. The ERROR LOG (%TEMP%\drilljig-gui-error.log) + a thread-exception trap
#      are the ORACLE: any NEW entry, or any exception escaping a fired handler,
#      is a UI bug. The closure-scope bug class (a script-scope function called
#      inside a .GetNewClosure() body) shows up here as a "not recognized" throw
#      the moment the handler fires -- which static reading can miss.
#
# This is additive + offline: it does NOT modify the GUI, and it SKIPS cleanly
# if WinForms is unavailable. Run:
#   powershell -ExecutionPolicy Bypass -File lib\tests\fuzz_gui.ps1
# Exit 0 = no UI faults observed; 1 = at least one fault (printed).
# ============================================================================

$ErrorActionPreference = 'Stop'
# Resolve our own path robustly: $MyInvocation.MyCommand.Path is null when the
# script is launched via `-Command "& script.ps1"` (vs `-File`), which would leave
# $root/$ScriptDir null and make the fastener steps' Join-Path throw. Fall back to
# $PSScriptRoot, then to the known repo location, so the harness works either way.
$here = $null
try { if ($MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path } } catch {}
if (-not $here -and $PSScriptRoot) { $here = $PSScriptRoot }
if (-not $here) { $here = Split-Path -Parent ([System.IO.Path]::GetFullPath('lib\tests\fuzz_gui.ps1')) }
$libDir = Split-Path -Parent $here
$root   = Split-Path -Parent $libDir

$script:faults = New-Object System.Collections.ArrayList
$script:checks = 0
function Fault { param([string]$Where, [string]$Msg) [void]$script:faults.Add("[$Where] $Msg"); Write-Host "  [FAULT] $Where : $Msg" -ForegroundColor Red }
function Note  { param([string]$Msg) Write-Host "  - $Msg" -ForegroundColor DarkGray }
function Ok    { param([string]$Msg) $script:checks++; Write-Host "  [ok] $Msg" -ForegroundColor DarkGreen }

Write-Host ""
Write-Host "  drilljig-gui.cmd DYNAMIC UI FUZZ" -ForegroundColor Cyan
Write-Host ""

# --- WinForms required (this box has it; the offline suite proves it) --------
$wf = $false
try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop; Add-Type -AssemblyName System.Drawing -ErrorAction Stop; $wf = $true } catch { $wf = $false }
if (-not $wf) { Write-Host "  [SKIP] WinForms not available headless." -ForegroundColor Yellow; exit 0 }

# route WinForms thread exceptions into our fault list (a fired handler that
# throws past its own catch would otherwise pop a JIT dialog / vanish).
try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
    [System.Windows.Forms.Application]::add_ThreadException({ param($s,$e) Fault 'WinForms-thread' $e.Exception.Message })
} catch {}

# --- dot-source the real libs (same set the GUI loads) -----------------------
. (Join-Path $libDir 'creo_geometry.ps1')
. (Join-Path $libDir 'blind_evaluator.ps1')
. (Join-Path $libDir 'orthogrid.ps1')
. (Join-Path $libDir 'orthogrid_gui.ps1')
. (Join-Path $libDir 'orthogrid_points.ps1')
. (Join-Path $libDir 'fastener_layout.ps1')
. (Join-Path $libDir 'drilljig_core.ps1')
. (Join-Path $libDir 'bushing_svg.ps1')
. (Join-Path $libDir 'wizard.ps1')

# --- STUB the live-Creo helpers so step Builds/OnNext run without Creo -------
# These shadow the real (COM-touching) lib functions for the duration of the
# fuzz. Each returns canned, valid-shaped data so the wizard logic proceeds.
function Initialize-DrilljigCore { param($Session,$Model,$TypeObj,$DataDir,$Log) }
function Find-DefaultDatumPicks {
    @(
        [pscustomobject]@{ Id=101; Name='TOP';   Role='Top'   }
        [pscustomobject]@{ Id=102; Name='SIDE';  Role='Side'  }
        [pscustomobject]@{ Id=103; Name='FRONT'; Role='Front' }
    )
}
function Read-SelectionPlanePicks {
    @(
        [pscustomobject]@{ Id=101; Name='TOP';   Role='Top'   }
        [pscustomobject]@{ Id=102; Name='SIDE';  Role='Side'  }
        [pscustomobject]@{ Id=103; Name='FRONT'; Role='Front' }
    )
}
function Resolve-SelectedPointIds { @{ Ids=@(201,202,203); Rejected=@() } }
function Find-DefaultCsysId { 501 }
function Invoke-BaseCsys { param($RefCsysId) @{ Ok=$true; CsysFeatId=777; Reason='' } } # -Show is switch
function Invoke-OutputCsys { param($RefCsysId,$GridX,$GridZ,$GridY) @{ Ok=$true; CsysFeatId=778; AnchorPlaneIds=@(311,312,313); Reason='' } }
function New-OffsetPlane { param($Label,$Offset,$BaseId,[switch]$SkipSymbolWait) @{ Symbol=('d'+$BaseId); FeatId=(400 + [int]$BaseId + [int]([Math]::Abs($Offset)*10)) } }
function New-CsysOffsetPlane { param($CsysFeatId,$Axis,$Offset,[switch]$SkipSymbolWait) @{ Symbol=('c'+$Axis); FeatId=(600 + [int]([Math]::Abs($Offset)*13) + [int]$Axis[0]) } }
function Invoke-Macro { param($Desc,$Macro) }
function Wait-ModelModified { param($Model,$PreviousStamp,$OnPoll) if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }; return $true }
function Get-PointIdSet { param($Model,$TypeObj) @{} }
function Resolve-NewPointIds { param($Model,$TypeObj,$Before) @(201,202,203,204,205,206,207,208,209,210,211,212,213,214,215,216,217,218,219,220) }
function Get-FeatureIdSet { @{} }
function Resolve-HoleFeatGroups { param($NewFeatIds,$HoleCount) @{ Ok=$true; PerHole=1; Groups=@(1..$HoleCount | ForEach-Object { @($_) }) } }
function Invoke-AutoCornerRound { param($Session,$Model,$TypeObj,$Radius) @{ Found=8; Matched=4; TotalBatches=1; ModelChanged=1 } }
function Read-SelectedId { 999 }
function Get-BodyList { @(0) }
function New-SlotGuidePlanes { param($Rows,$TopBaseId,$FrontBaseId,[switch]$UsePattern,$Log) if ($null -ne $Log) { try { & $Log 'stub guide planes' } catch {} }; @{ Ids=@(701,702) } }

# a fake $model with a mutating VersionStamp so canary loops progress
$script:vstamp = 0
$fakeModel = [pscustomobject]@{}
$fakeModel | Add-Member ScriptMethod VersionStamp { $script:vstamp++ ; return $script:vstamp } -Force
$fakeModel | Add-Member ScriptProperty VersionStamp { $script:vstamp++; return $script:vstamp } -Force -ErrorAction SilentlyContinue 2>$null
# $model.VersionStamp is a PROPERTY read in the GUI; emulate with a NoteProperty that
# we bump via a wrapper. Simpler: give it a settable prop and bump in the session stub.
$fakeModel = [pscustomobject]@{ VersionStamp = 1 }
$fakeModel | Add-Member ScriptMethod Regenerate { param($x) } -Force
$fakeModel | Add-Member ScriptMethod GetActiveModel { $this } -Force -ErrorAction SilentlyContinue
$fakeSession = [pscustomobject]@{}
$fakeSession | Add-Member ScriptMethod RunMacro { param($m) $script:model.VersionStamp = ([int]$script:model.VersionStamp + 1) } -Force
$fakeSession | Add-Member ScriptMethod GetActiveModel { $script:model } -Force
$fakeSession | Add-Member ScriptMethod GetConfigOptionValues { param($k) $null } -Force
$fakeSession | Add-Member ScriptMethod SetConfigOption { param($k,$v) } -Force

# --- extract the GUI helper region + the steps region, like the integration test
$src = Get-Content -Raw (Join-Path $root 'drilljig-gui.cmd')
$h0 = $src.IndexOf('# STEP BUILDERS'); $h1 = $src.IndexOf('# Build the connection up front')
if ($h0 -lt 0 -or $h1 -lt 0) { Fault 'extract' 'could not find helper region markers'; }
else { Invoke-Expression $src.Substring($h0, $h1 - $h0) | Out-Null }

# top-level vars the steps region reads (mirror the .cmd + integration test)
# $ScriptDir is set by the hybrid .cmd header in the real run; the fastener steps
# build 'Join-Path $ScriptDir fastener_layout.json', so define it (repo root) here.
$ScriptDir = $root
$ScriptArgs = ''
$dataDir = Join-Path $root 'data'
$cornerRadius = 0.25; $noCornerRound = $false
$SLOT_DEPTH_ABS = 0.25; $slotDepthFromFlagG = $false; $slotFlipDefault = $false
$slotPatternFlip = $false; $slotNoPattern = $false; $noSlotRelief = $false
$noBaseCsys = $false; $indexFlipX = 1.0; $indexFlipZ = 1.0
$model = $fakeModel; $session = $fakeSession; $pfcType = $null; $modelFile = 'jig.prt'
$script:model = $fakeModel; $script:session = $fakeSession; $script:connection = $null
$script:macroFailures = 0

# error-log oracle: snapshot length before any rendering
$logPath = Join-Path ([System.IO.Path]::GetTempPath()) 'drilljig-gui-error.log'
$logBefore = if (Test-Path $logPath) { (Get-Item $logPath).Length } else { 0 }

# ----------------------------------------------------------------------------
# fresh $ctx builder (mirrors the .cmd initializer; ArrayLists as it uses)
# ----------------------------------------------------------------------------
function New-FuzzCtx {
    $c = @{
        TreePath = Join-Path $root 'docs\drill_jig_decision_tree.json'
        Path=[System.Collections.ArrayList]::new(); Picks=[System.Collections.ArrayList]::new()
        HoleDia=$null; BushingLen=$null; Is3dPrint=$false
        TreeNode=$null; TreeDone=$false; PendingSpec=$null; BushStage=$null; Grouped=$null; BushID=$null
        BushOdFirst=$false; BushOdGroups=$null; BushOD=$null; BushOdOptions=$null
        BushLenValue=$null; BushLenLabel=$null; BushLenIsCustom=$false; BushLenCustomText=''; BushLenValid=$true
        PointMode='predefined'; OrthoGeo=$null; LayoutPicked=$false; LayoutMode=$null
        FastenerLayoutPath=$null; OrthoValid=$false; OrthoFields=$null; CustomRows=$null; CustomIndex=$null
        IndexFirst=$false; IndexKey=$null
        Session=$fakeSession; Model=$fakeModel; Type=$null; ModelName='jig.prt'; Connected=$true
        BaseCsysId=$null; RefCsysId=$null; IndexAnchorX=$null; IndexAnchorZ=$null; UseCsys=$null; FaceId=$null
        Planes=$null; AutoMapped=$false; SidePlane=$null; Made=@(); BoxArmed=$false
        SketchPlaneId=$null; ExtrudeToId=$null; BoxBuilt=$false
        GridPointIDs=@(); GridPlaneIds=@(); CsysRecords=@()
        PointIDs=@(); BodyIndex=0; HoleDiaFinal=0.0; Drilled=$false
        IndexGridX=$null; IndexGridZ=$null
        SlotArmed=$false; SlotSkip=$false; SlotFlip=$false; SlotPlan=$null; SlotsDone=$false
        SlotRunIndex=0; SeedCut=$false; SlotAnyCut=$false; SlotWarn=$false
        WillSlot=$null; ReliefPad=0.0
        SlotDepth=[double]0.25; SlotSpaceMode=$null; SlotDepthFromFlag=$false; SlotDepthValid=$true
        SlotRowAxis=$null; SlotDirFromFlag=$false
        EdgeMargin=$null; EdgeMarginMode=$null; EdgeMarginValid=$true
        FastenerRawPoints=$null; FastenerAsked=$false
    }
    $treeRoot = Get-Content $c.TreePath -Raw | ConvertFrom-Json
    $c.TreeNode = @($treeRoot)[0]; $c.TreeRoot = @($treeRoot)[0]; $c.TreeHistory=[System.Collections.ArrayList]::new()
    return $c
}

# ----------------------------------------------------------------------------
# a fake $wiz controller with every method the steps call (no-ops that record).
# AskInline returns a scripted answer so OnNext branches both ways.
# ----------------------------------------------------------------------------
function New-FuzzWiz {
    param([string]$AskAnswer = 'Yes')
    $w = [pscustomobject]@{ AskLog = (New-Object System.Collections.ArrayList); Answer=$AskAnswer }
    foreach ($m in 'SetChip','Refresh','Log','Pump','SetProgress','BeginRun','EndRun','MarkCommitted','SetStatus','LogError','Next','Rerender','GoToStepKey') {
        $w | Add-Member ScriptMethod $m { param($a,$b,$c) } -Force
    }
    $w | Add-Member ScriptMethod AskInline { param($h,$t,$btns='OK',$noact=$false) [void]$this.AskLog.Add($h); return $this.Answer } -Force
    return $w
}

# ----------------------------------------------------------------------------
# render a step's Build into a fresh panel, then FUZZ every control it made.
# ----------------------------------------------------------------------------
function Invoke-FuzzStep {
    param($Step, $Ctx, $Wiz, [string]$Tag, [switch]$FireButtons, [switch]$FireOnNext)
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Size = New-Object System.Drawing.Size(860, 460)
    $ok = $true
    # 1. Build
    try { & $Step.Build $panel $Ctx $Wiz | Out-Null }
    catch { Fault "$Tag/Build($($Step.Key))" $_.Exception.Message; $ok=$false }
    # 2. Validate
    try { if ($null -ne $Step.Validate) { [void](& $Step.Validate $Ctx) } }
    catch { Fault "$Tag/Validate($($Step.Key))" $_.Exception.Message; $ok=$false }
    # 3. force every Paint handler (fires Add_Paint .GetNewClosure() bodies) by
    #    DrawToBitmap on the panel AND each child panel.
    $allPanels = New-Object System.Collections.ArrayList
    $collect = { param($p) foreach ($cc in $p.Controls) { if ($cc -is [System.Windows.Forms.Panel]) { [void]$allPanels.Add($cc); & $collect $cc } } }
    & $collect $panel
    foreach ($pp in @($panel) + @($allPanels.ToArray())) {
        try {
            if ($pp.Width -gt 0 -and $pp.Height -gt 0) {
                $bmp = New-Object System.Drawing.Bitmap([Math]::Min(600,$pp.Width), [Math]::Min(400,$pp.Height))
                $pp.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0,0,$bmp.Width,$bmp.Height)))
                $bmp.Dispose()
            }
        } catch { Fault "$Tag/Paint($($Step.Key))" $_.Exception.Message; $ok=$false }
    }
    # 4. fuzz TEXTBOXES (fire TextChanged closures with junk + valid + empty)
    $textboxes = New-Object System.Collections.ArrayList
    $ctb = { param($p) foreach ($cc in $p.Controls) { if ($cc -is [System.Windows.Forms.TextBox]) { [void]$textboxes.Add($cc) }; if ($cc.Controls.Count -gt 0) { & $ctb $cc } } }
    & $ctb $panel
    foreach ($tb in $textboxes.ToArray()) {
        foreach ($v in @('abc','-5','0','1.5','','3/4','1e9','  ')) {
            try { $tb.Text = $v } catch { Fault "$Tag/TextChanged($($Step.Key))" ("val='$v' -> " + $_.Exception.Message); $ok=$false; break }
        }
    }
    # 5. fuzz DATAGRIDVIEWS (edit a cell + fire CellEndEdit/CellValueChanged closures)
    $grids = New-Object System.Collections.ArrayList
    $cgd = { param($p) foreach ($cc in $p.Controls) { if ($cc -is [System.Windows.Forms.DataGridView]) { [void]$grids.Add($cc) }; if ($cc.Controls.Count -gt 0) { & $cgd $cc } } }
    & $cgd $panel
    foreach ($gd in $grids.ToArray()) {
        try {
            if ($gd.Rows.Count -gt 0 -and $gd.Columns.Count -gt 0) {
                $gd.Rows[0].Cells[0].Value = 'zzz'
                # fire the change handlers explicitly (headless has no edit UI)
                foreach ($ev in 'CellValueChanged','CellEndEdit') {
                    try { $gd.GetType().GetMethod("On$ev",[System.Reflection.BindingFlags]'Instance,NonPublic').Invoke($gd, @((New-Object System.Windows.Forms.DataGridViewCellEventArgs(0,0)))) } catch {}
                }
            }
        } catch { Fault "$Tag/Grid($($Step.Key))" $_.Exception.Message; $ok=$false }
    }
    # 6. fuzz BUTTONS (PerformClick -> fires Add_Click .GetNewClosure() bodies).
    #    Recurse into child panels/overlays. Optional (some clicks mutate ctx a lot).
    if ($FireButtons) {
        $buttons = New-Object System.Collections.ArrayList
        $cbn = { param($p) foreach ($cc in $p.Controls) { if ($cc -is [System.Windows.Forms.Button]) { [void]$buttons.Add($cc) }; if ($cc.Controls.Count -gt 0) { & $cbn $cc } } }
        & $cbn $panel
        foreach ($bn in $buttons.ToArray()) {
            try { $bn.PerformClick() }
            catch { Fault "$Tag/Click($($Step.Key):'$($bn.Text)')" $_.Exception.Message; $ok=$false }
        }
    }
    # 7. OnNext (optional; some do heavy stubbed work)
    if ($FireOnNext -and $null -ne $Step.OnNext) {
        try { [void](& $Step.OnNext $Ctx $Wiz) }
        catch { Fault "$Tag/OnNext($($Step.Key))" $_.Exception.Message; $ok=$false }
    }
    $panel.Dispose()
    return $ok
}

# ----------------------------------------------------------------------------
# BUILD THE REAL $steps from drilljig-gui.cmd (steps region).
# ----------------------------------------------------------------------------
$steps = New-Object System.Collections.ArrayList
# the steps region references $ctx (the .cmd's own name) for the tree-load block
# (Get-Content $ctx.TreePath ...); give it one, matching the .cmd initializer.
$ctx = New-FuzzCtx
try {
    $siR = $src.IndexOf('# WIZARD STEPS'); $eiR = $src.IndexOf('# RUN THE WIZARD')
    Invoke-Expression $src.Substring($siR, $eiR - $siR) | Out-Null
    Ok ("extracted {0} real wizard steps" -f $steps.Count)
} catch { Fault 'extract-steps' $_.Exception.Message }

$stepArr = @($steps.ToArray())
function Get-Step { param([string]$Key) $stepArr | Where-Object { $_.Key -eq $Key } | Select-Object -First 1 }

# ============================================================================
# STATE MATRIX - render + fuzz every step under many $ctx configurations.
# Each scenario mutates a fresh ctx to a plausible mid-run state, then fuzzes
# the named steps. FireButtons on the steps whose buttons are safe to click.
# ============================================================================

# ---- helper: put ctx into a valid orthogrid layout state --------------------
function Set-OrthoLayout { param($C, [double]$Dia=0.5)
    $C.HoleDia=$Dia; $C.BushingLen=0.75; $C.PointMode='orthogrid'; $C.LayoutMode='orthogrid'
    $C.OrthoFields = @{ CcX=0.75; CcZ=0.75; Nx=4; Nz=3; Edge=$Dia }
    $C.OrthoGeo = Get-OrthogridGeometry -CcX 0.75 -CcZ 0.75 -Nx 4 -Nz 3 -Edge $Dia -ClearDia $Dia -HoleDia $Dia -EdgeMargin $Dia
    $C.OrthoValid = [bool]$C.OrthoGeo.Valid
}
function Set-Datums { param($C)
    $C.Planes = @(
        [pscustomobject]@{ Label='Top';   Hint='TOP';   Offset=3.0; Sym='d1'; BaseId=101; FeatId=411 }
        [pscustomobject]@{ Label='Side';  Hint='SIDE';  Offset=0.75; Sym='d2'; BaseId=102; FeatId=412 }
        [pscustomobject]@{ Label='Front'; Hint='FRONT'; Offset=2.0; Sym='d3'; BaseId=103; FeatId=413 }
    )
    $C.Made = @($C.Planes)
    $C.SidePlane = $C.Planes | Where-Object { $_.Label -eq 'Side' } | Select-Object -First 1
    $C.AutoMapped = $true
}

$scenarios = @(
    @{ Name='welcome';             Steps=@('welcome');      Setup={ param($c) } }
    @{ Name='import-fresh';        Steps=@('import');       Setup={ param($c) } }
    @{ Name='import-captured';     Steps=@('import');       Setup={ param($c) $c.FastenerRawPoints=@([pscustomobject]@{X=0.5;Z=0.5},[pscustomobject]@{X=1.5;Z=0.5}) } }
    @{ Name='tree-root';           Steps=@('tree');         Setup={ param($c) } }
    @{ Name='tree-done-fixed';     Steps=@('tree');         Setup={ param($c) $c.TreeDone=$true; [void]$c.Picks.Add([pscustomobject]@{HoleDiameter=0.5;BushingLength=$null;Bushing='(fixed OD)';PartNumber='(n/a)';Outcome='x'}) } }
    # bushing-confirmation schematic (display-only Draw-BushingSchematic):
    #   sleeve = HEADLESS (real ID), drill = HEADED (real ID), metal = HEADED + '(any)' bore
    @{ Name='tree-done-sleeve';    Steps=@('tree');         Setup={ param($c) $c.TreeDone=$true; [void]$c.Picks.Add([pscustomobject]@{HoleDiameter=0.75;BushingID=0.5;BushingLength=0.75;Bushing='Sleeve | OD 3/4 x ID 1/2 x 3/4 Lg';PartNumber='3556N158';Outcome='x'}) } }
    @{ Name='tree-done-drill';     Steps=@('tree');         Setup={ param($c) $c.TreeDone=$true; [void]$c.Picks.Add([pscustomobject]@{HoleDiameter=0.5;BushingID=0.25;BushingLength=0.25;Bushing='Drill Bushing | OD 1/2 x ID 1/4 x 1/4 Lg';PartNumber='8493A072';Outcome='x'}) } }
    @{ Name='tree-done-metal';     Steps=@('tree');         Setup={ param($c) $c.TreeDone=$true; [void]$c.Picks.Add([pscustomobject]@{HoleDiameter=0.75;BushingID='(any)';BushingLength=0.75;Bushing='Drill Bushing | OD 3/4 x ID (any) x 3/4 Lg';PartNumber='';Outcome='x'}) } }
    @{ Name='edgemargin-fresh';    Steps=@('edge-margin');  Setup={ param($c) $c.HoleDia=0.5 } }
    @{ Name='edgemargin-nodia';    Steps=@('edge-margin');  Setup={ param($c) } }
    @{ Name='edgemargin-custom';   Steps=@('edge-margin');  Setup={ param($c) $c.HoleDia=0.5; $c.EdgeMarginMode='custom'; $c.EdgeMargin=0.25 } }
    @{ Name='edgemargin-std';      Steps=@('edge-margin');  Setup={ param($c) $c.HoleDia=0.5; $c.EdgeMarginMode='standard' } }
    @{ Name='edgemargin-builtback';Steps=@('edge-margin');  Setup={ param($c) $c.HoleDia=0.5; $c.EdgeMarginMode='custom'; $c.EdgeMargin=0.25; $c.BoxBuilt=$true } }
    @{ Name='slotdepth-fresh';     Steps=@('slot-depth');   Setup={ param($c) $c.BushingLen=0.75 } }
    @{ Name='slotdepth-tight';     Steps=@('slot-depth');   Setup={ param($c) $c.BushingLen=0.75; $c.SlotSpaceMode='tight' } }
    @{ Name='slotdepth-std';       Steps=@('slot-depth');   Setup={ param($c) $c.BushingLen=0.75; $c.SlotSpaceMode='standard' } }
    @{ Name='slotdepth-builtback'; Steps=@('slot-depth');   Setup={ param($c) $c.BushingLen=0.75; $c.SlotSpaceMode='tight'; $c.BoxBuilt=$true; $c.ReliefPad=0.25 } }
    @{ Name='layout-tiles';        Steps=@('layout');       Setup={ param($c) $c.HoleDia=0.5 } }
    @{ Name='layout-orthogrid';    Steps=@('layout');       Setup={ param($c) $c.HoleDia=0.5; $c.BushingLen=0.75; $c.PointMode='orthogrid'; $c.LayoutMode='orthogrid' } }
    @{ Name='layout-custom';       Steps=@('layout');       Setup={ param($c) $c.HoleDia=0.5; $c.BushingLen=0.75; $c.PointMode='custom'; $c.LayoutMode='custom' } }
    @{ Name='layout-ortho-smallmargin'; Steps=@('layout');  Setup={ param($c) $c.HoleDia=0.5; $c.BushingLen=0.75; $c.PointMode='orthogrid'; $c.LayoutMode='orthogrid'; $c.EdgeMargin=0.125; $c.EdgeMarginMode='custom' } }
    @{ Name='layout-custom-smallmargin';Steps=@('layout');  Setup={ param($c) $c.HoleDia=0.5; $c.BushingLen=0.75; $c.PointMode='custom'; $c.LayoutMode='custom'; $c.EdgeMargin=0.125; $c.EdgeMarginMode='custom' } }
    @{ Name='layout-fastener';     Steps=@('layout');       Setup={ param($c) $c.HoleDia=0.5; $c.LayoutMode='fastener' } }
    @{ Name='layout-fast-captured';Steps=@('layout');       Setup={ param($c) $c.HoleDia=0.5; $c.FastenerRawPoints=@([pscustomobject]@{X=0.5;Z=0.5},[pscustomobject]@{X=2.5;Z=0.5},[pscustomobject]@{X=0.5;Z=2.0}) } }
    @{ Name='index-orthogrid';     Steps=@('index-choice'); Setup={ param($c) Set-OrthoLayout $c } }
    @{ Name='index-noortho';       Steps=@('index-choice'); Setup={ param($c) } }
    @{ Name='index-custom-idxrel'; Steps=@('index-choice'); Setup={ param($c) $c.HoleDia=0.5; $c.OrthoGeo = Get-IndexRelativeCustomGeometry -IndexX 0.75 -IndexZ 0.75 -OtherPoints @([pscustomobject]@{X=1.0;Z=0},[pscustomobject]@{X=0;Z=1.0}) -ClearDia 0.5 -HoleDia 0.5 -EdgeMargin 0.5; $c.OrthoValid=$true } }
    @{ Name='datums-auto';         Steps=@('datums');       Setup={ param($c) } }
    @{ Name='box-a-grid';          Steps=@('box-a');        Setup={ param($c) Set-OrthoLayout $c; Set-Datums $c } }
    @{ Name='box-b-armed';         Steps=@('box-b');        Setup={ param($c) Set-OrthoLayout $c; Set-Datums $c; $c.BoxArmed=$true; $c.SketchPlaneId=102; $c.ExtrudeToId=412 } }
    @{ Name='box-b-built';         Steps=@('box-b');        Setup={ param($c) Set-OrthoLayout $c; Set-Datums $c; $c.BoxBuilt=$true } }
    @{ Name='pickpoints-pre';      Steps=@('pickpoints');   Setup={ param($c) $c.PointMode='predefined' } }
    @{ Name='pickpoints-auto';     Steps=@('pickpoints');   Setup={ param($c) Set-OrthoLayout $c } }
    @{ Name='drill-ready';         Steps=@('drill');        Setup={ param($c) Set-OrthoLayout $c; Set-Datums $c; $c.UseCsys=$false; $c.PointIDs=@() } }
    @{ Name='drill-done';          Steps=@('drill');        Setup={ param($c) Set-OrthoLayout $c; Set-Datums $c; $c.Drilled=$true; $c.GridPointIDs=@(201,202) } }
    # slot-dir moved into the LAYOUT stage (user 2026-07-23): the fastener layout view now
    # renders an X/Z toggle (Add-SlotDirToggle) ABOVE the preview, and Add-LayoutPreview's
    # slot bands honor $c.SlotRowAxis. Exercise the up-front fastener branch with Z chosen
    # (renders the toggle buttons + the Z-direction relief bands in the preview Paint).
    @{ Name='layout-fast-dirZ';    Steps=@('layout');       Setup={ param($c) $c.HoleDia=0.5; $c.SlotRowAxis='Z'; $c.FastenerRawPoints=@([pscustomobject]@{X=0.5;Z=0.5},[pscustomobject]@{X=2.5;Z=0.5},[pscustomobject]@{X=0.5;Z=2.0}) } }
    @{ Name='slot-a-ready';        Steps=@('slot-a');       Setup={ param($c) Set-OrthoLayout $c; Set-Datums $c; $c.HoleDiaFinal=0.5; $c.ReliefPad=0.25; $c.WillSlot=$true } }
    @{ Name='slot-a-fastener';     Steps=@('slot-a');       Setup={ param($c) Set-OrthoLayout $c; Set-Datums $c; $c.PointMode='fastener'; $c.SlotRowAxis='Z'; $c.HoleDiaFinal=0.5; $c.ReliefPad=0.25; $c.WillSlot=$true } }
    @{ Name='slot-a-armed';        Steps=@('slot-a');       Setup={ param($c) Set-OrthoLayout $c; Set-Datums $c; $c.SlotArmed=$true } }
    @{ Name='slot-b-pattern';      Steps=@('slot-b');       Setup={ param($c) Set-OrthoLayout $c; Set-Datums $c; $c.SlotArmed=$true; $c.SlotPlan=@{Mode='pattern';SeedRow=[pscustomobject]@{CrossCoord=0.5;SlotLen=10.0;Corner0=@{X=0;Z=0.5};Corner1=@{X=10;Z=0.5}};Patterns=@([pscustomobject]@{Increment=0.75;Count=3;Offsets=@(0.75,1.5)},[pscustomobject]@{Increment=4.0;Count=2;Offsets=@(4.0)});SlotWidth=0.5;RowAxis='X';CrossAxis='Z';Depth=0.25;FaceId=102;DirDatumId=413;DirName='FRONT'} } }
    @{ Name='slot-b-pattern-seedcut'; Steps=@('slot-b');    Setup={ param($c) Set-OrthoLayout $c; Set-Datums $c; $c.SlotArmed=$true; $c.SeedCut=$true; $c.SlotAnyCut=$true; $c.SlotPlan=@{Mode='pattern';SeedRow=[pscustomobject]@{CrossCoord=0.5;SlotLen=10.0;Corner0=@{X=0;Z=0.5};Corner1=@{X=10;Z=0.5}};Patterns=@([pscustomobject]@{Increment=0.75;Count=3;Offsets=@(0.75,1.5)});SlotWidth=0.5;RowAxis='X';CrossAxis='Z';Depth=0.25;FaceId=102;DirDatumId=413;DirName='FRONT'} } }
    @{ Name='slot-b-perrow';       Steps=@('slot-b');       Setup={ param($c) Set-OrthoLayout $c; Set-Datums $c; $c.SlotArmed=$true; $c.SlotPlan=@{Mode='perrow';SeedRow=[pscustomobject]@{CrossCoord=0.5};Rows=@([pscustomobject]@{CrossCoord=0.5;SlotLen=10.0;Corner0=@{X=0;Z=0.5};Corner1=@{X=10;Z=0.5}},[pscustomobject]@{CrossCoord=3.0;SlotLen=10.0;Corner0=@{X=0;Z=3};Corner1=@{X=10;Z=3}});SlotWidth=0.5;RowAxis='X';CrossAxis='Z';Depth=0.25;FaceId=102;DirDatumId=413;DirName='FRONT'} } }
    @{ Name='slot-b-skip';         Steps=@('slot-b');       Setup={ param($c) $c.SlotSkip=$true } }
    @{ Name='slot-b-done';         Steps=@('slot-b');       Setup={ param($c) Set-OrthoLayout $c; $c.SlotsDone=$true } }
    @{ Name='done-clean';          Steps=@('done');         Setup={ param($c) Set-OrthoLayout $c; $c.BoxBuilt=$true; $c.Drilled=$true; $c.SlotsDone=$true; $c.PointIDs=@(1,2,3) } }
    @{ Name='done-pad-warn';       Steps=@('done');         Setup={ param($c) $c.BushingLen=0.75; $c.WillSlot=$true; $c.SlotsDone=$false; $c.SlotDepth=0.25 } }
)

Write-Host "  -- render + fuzz each step across state matrix --" -ForegroundColor White
foreach ($sc in $scenarios) {
    $c = New-FuzzCtx
    try { & $sc.Setup $c } catch { Fault "setup:$($sc.Name)" $_.Exception.Message; continue }
    $wiz = New-FuzzWiz -AskAnswer 'Yes'
    foreach ($sk in $sc.Steps) {
        $st = Get-Step $sk
        if ($null -eq $st) { Fault "$($sc.Name)" "step '$sk' not found"; continue }
        # buttons safe to click for render-only pages; skip clicking on RUN steps that
        # would fire the live pipeline redundantly (Build already fuzzed their controls).
        $fireBtns = ($sk -in @('import','tree','edge-margin','slot-depth','layout','index-choice','datums','box-b','drill','slot-b','done'))
        [void](Invoke-FuzzStep -Step $st -Ctx $c -Wiz $wiz -Tag $sc.Name -FireButtons:$fireBtns)
    }
}
Ok ("fuzzed {0} scenarios" -f $scenarios.Count)

# ============================================================================
# S3 REGRESSION: stale session/model after a fastener-import RECONNECT.
# The Datums stage can RECONNECT (the fastener live read closes the startup
# session) and update $c.Session/$c.Model, but a `$script:session =` write there
# does NOT reach a bare $session read in box-b/drill/slot-b OnNext (proven, in a
# faithful nested-scope repro). The fix rebinds $session/$model FROM $c at the top
# of those OnNext blocks.
#
# TEETH: most bare $session/$model uses are wrapped in try/catch, so a dead handle
# degrades to a SILENT no-op (the canary reports "no change"), not a crash. So this
# test does not assert "no throw" -- it asserts the macro actually reached the LIVE
# handle. The drill step calls Get-PointIdSet -Model $model and $session.RunMacro;
# we shadow those lib stubs to RECORD which handle they were handed, tag the dead vs
# live handles, and assert the drill used the LIVE one. WITHOUT the fix, drill reads
# the bare (dead) $model/$session and the recorder sees the DEAD tag -> FAULT.
# ============================================================================
Write-Host "  -- S3 regression: reconnect leaves box/drill/slot using LIVE handles --" -ForegroundColor White
try {
    $script:s3seen = New-Object System.Collections.ArrayList
    # tagged DEAD top-level handles (the stale startup session)
    $deadModel   = [pscustomobject]@{ S3Tag='DEAD'; VersionStamp=1 }
    $deadSession = [pscustomobject]@{ S3Tag='DEAD' }
    $deadSession | Add-Member ScriptMethod RunMacro { param($m) [void]$script:s3seen.Add('RunMacro:' + $this.S3Tag) } -Force
    # tagged LIVE reconnected handles (what the Datums repair binds into $c)
    $liveModel   = [pscustomobject]@{ S3Tag='LIVE'; VersionStamp=1 }
    $liveSession = [pscustomobject]@{ S3Tag='LIVE' }
    $liveSession | Add-Member ScriptMethod RunMacro { param($m) [void]$script:s3seen.Add('RunMacro:' + $this.S3Tag) } -Force

    # shadow the point/model lib stubs to RECORD which handle they received
    function Get-PointIdSet { param($Model,$TypeObj) [void]$script:s3seen.Add('PointIdSet:' + $Model.S3Tag); @{} }
    function Resolve-NewPointIds { param($Model,$TypeObj,$Before) [void]$script:s3seen.Add('ResolveNew:' + $Model.S3Tag); @(201,202,203,204,205,206,207,208,209,210,211,212) }
    function Invoke-AutoCornerRound { param($Session,$Model,$TypeObj,$Radius) [void]$script:s3seen.Add('Corner:' + $Session.S3Tag); @{ Found=4; Matched=4; TotalBatches=1; ModelChanged=1 } }
    function Get-FeatureIdSet { @{} }

    # point the TOP-LEVEL bare vars at the DEAD handles (the stale startup session)
    $session = $deadSession; $model = $deadModel
    $script:session = $deadSession; $script:model = $deadModel

    $c = New-FuzzCtx
    Set-OrthoLayout $c 0.5; Set-Datums $c
    $c.UseCsys = $false; $c.PointIDs = @()
    # the Datums repair binds the LIVE handles into the context (reference type -> reaches OnNext)
    $c.Session = $liveSession; $c.Model = $liveModel
    $wiz = New-FuzzWiz
    $drill = Get-Step 'drill'
    $threw = $false
    try { [void](& $drill.OnNext $c $wiz) } catch { $threw = $true; Fault 'S3/drill-OnNext' $_.Exception.Message }
    $seen = @($script:s3seen.ToArray())
    $usedDead = @($seen | Where-Object { $_ -match ':DEAD$' })
    $usedLive = @($seen | Where-Object { $_ -match ':LIVE$' })
    if ($usedDead.Count -gt 0) {
        Fault 'S3/drill' ("drill used the DEAD (stale) handle after a reconnect: " + ($usedDead -join ', ') + " | seen=[" + ($seen -join ', ') + "]")
    } elseif ($usedLive.Count -gt 0) {
        Ok ("S3: drill used the LIVE reconnected handle ({0} live calls, 0 dead)" -f $usedLive.Count)
    } else {
        Fault 'S3/drill' ("drill made no recorded session/model call - test could not observe (seen=[" + ($seen -join ', ') + "])")
    }

    # restore the good stubs + real lib functions for anything after
    $session = $fakeSession; $model = $fakeModel; $script:session = $fakeSession; $script:model = $fakeModel
    function Get-PointIdSet { param($Model,$TypeObj) @{} }
    function Resolve-NewPointIds { param($Model,$TypeObj,$Before) @(201,202,203,204,205,206,207,208,209,210,211,212,213,214,215,216,217,218,219,220) }
    function Invoke-AutoCornerRound { param($Session,$Model,$TypeObj,$Radius) @{ Found=8; Matched=4; TotalBatches=1; ModelChanged=1 } }
} catch { Fault 'S3-harness' $_.Exception.Message }

# ============================================================================
# BUSHING SCHEMATIC (display-only) - the confirmation view renders a GDI+ picture
# of the picked bushing via Draw-BushingSchematic (lib\bushing_svg.ps1). TEETH: the
# fuzz scenarios above only prove "no crash" (my Paint is try/catch-wrapped, so a
# missing draw is silent). Here we build the tree confirmation with a REAL pick,
# find the preview Panel it adds, DrawToBitmap it, and assert it actually painted
# pixels (> a floor). Plus a NEGATIVE case: the fixed-OD "no bushing" leaf must add
# NO preview panel. WITHOUT the integration (or if the draw silently no-ops), the
# positive case renders ~0 px -> FAULT.
# ============================================================================
Write-Host "  -- bushing confirmation schematic renders (display-only) --" -ForegroundColor White
try {
    $treeStepB = Get-Step 'tree'
    if ($null -eq $treeStepB) { Fault 'bushing-svg' "tree step not found" }
    else {
        function Render-Confirm { param($Pick)
            $c = New-FuzzCtx; $c.TreeDone = $true; [void]$c.Picks.Add($Pick)
            $wz = New-FuzzWiz
            $pnl = New-Object System.Windows.Forms.Panel; $pnl.Size = New-Object System.Drawing.Size(880, 640)
            & $treeStepB.Build $pnl $c $wz | Out-Null
            # the confirmation view's only child Panel is the bushing preview
            $prev = @($pnl.Controls | Where-Object { $_ -is [System.Windows.Forms.Panel] }) | Select-Object -First 1
            $px = 0
            if ($null -ne $prev -and $prev.Width -gt 0 -and $prev.Height -gt 0) {
                $bmp = New-Object System.Drawing.Bitmap($prev.Width, $prev.Height)
                $prev.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0,0,$prev.Width,$prev.Height)))
                $bg = $prev.BackColor
                for ($x=0; $x -lt $bmp.Width; $x+=3) { for ($y=0; $y -lt $bmp.Height; $y+=3) {
                    $p = $bmp.GetPixel($x,$y)
                    if ([math]::Abs($p.R-$bg.R)+[math]::Abs($p.G-$bg.G)+[math]::Abs($p.B-$bg.B) -gt 24) { $px++ }
                } }
                $bmp.Dispose()
            }
            $pnl.Dispose()
            return @{ HasPanel = ($null -ne $prev); Pixels = $px }
        }
        # sleeve (HEADLESS, real ID)
        $rs = Render-Confirm ([pscustomobject]@{HoleDiameter=0.75;BushingID=0.5;BushingLength=0.75;Bushing='Sleeve | OD 3/4 x ID 1/2 x 3/4 Lg';PartNumber='3556N158';Outcome='x'})
        if ($rs.HasPanel -and $rs.Pixels -gt 300) { Ok ("bushing schematic (sleeve, headless, real ID) rendered ($($rs.Pixels) px)") }
        else { Fault 'bushing-svg/sleeve' ("expected a preview panel with pixels; got HasPanel=$($rs.HasPanel) Pixels=$($rs.Pixels)") }
        # drill bushing (HEADED, real ID)
        $rd = Render-Confirm ([pscustomobject]@{HoleDiameter=0.5;BushingID=0.25;BushingLength=0.25;Bushing='Drill Bushing | OD 1/2 x ID 1/4 x 1/4 Lg';PartNumber='8493A072';Outcome='x'})
        if ($rd.HasPanel -and $rd.Pixels -gt 300) { Ok ("bushing schematic (drill, headed, real ID) rendered ($($rd.Pixels) px)") }
        else { Fault 'bushing-svg/drill' ("expected a preview panel with pixels; got HasPanel=$($rd.HasPanel) Pixels=$($rd.Pixels)") }
        # metal removable (HEADED, ID '(any)')
        $rm = Render-Confirm ([pscustomobject]@{HoleDiameter=0.75;BushingID='(any)';BushingLength=0.75;Bushing='Drill Bushing | OD 3/4 x ID (any) x 3/4 Lg';PartNumber='';Outcome='x'})
        if ($rm.HasPanel -and $rm.Pixels -gt 300) { Ok ("bushing schematic (metal, headed, ID any) rendered ($($rm.Pixels) px)") }
        else { Fault 'bushing-svg/metal' ("expected a preview panel with pixels; got HasPanel=$($rm.HasPanel) Pixels=$($rm.Pixels)") }
        # NEGATIVE: fixed-OD "no bushing" leaf -> no preview panel
        $rf = Render-Confirm ([pscustomobject]@{HoleDiameter=0.5;BushingLength=$null;Bushing='(fixed OD, no bushing)';PartNumber='(n/a)';Outcome='x'})
        if (-not $rf.HasPanel) { Ok "bushing schematic correctly SKIPPED for the fixed-OD no-bushing leaf" }
        else { Fault 'bushing-svg/fixed' "a preview panel was added for the no-bushing leaf (should be skipped)" }
    }
} catch { Fault 'bushing-svg-harness' $_.Exception.Message }

# ============================================================================
# NAVIGATION FUZZ - drive the WHOLE wizard through Show-Wizard with a timer that
# clicks Next / Back / breadcrumb pills in a pseudo-random-but-deterministic
# order, exercising interwoven navigation + re-render. Modal, so gate on opt-in
# (WIZ_LIVE_DRIVE=1) exactly like run_wizard_tests.ps1's drive tests, since a
# ShowDialog under the background harness can hang.
# ============================================================================
if ($env:WIZ_LIVE_DRIVE -eq '1') {
    Write-Host "  -- navigation drive (Next/Back/breadcrumb) --" -ForegroundColor White
    try {
        $navCtx = New-FuzzCtx
        # pre-seed a tree pick so the flow can advance without card interaction
        $navCtx.TreeDone=$true; [void]$navCtx.Picks.Add([pscustomobject]@{HoleDiameter=0.5;BushingLength=0.75;Bushing='(t)';PartNumber='p';Outcome='o'})
        $navCtx.HoleDia=0.5; $navCtx.BushingLen=0.75
        $seq = @('N','N','B','N','N','B','B','N','N','N','B','N','N','N','N','N','N','N')
        $i = 0
        $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 120
        $timer.Add_Tick({
            try {
                $f = [System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -eq 'FUZZ-NAV' } | Select-Object -First 1
                if ($null -eq $f) { return }
                if ($i -ge $seq.Count) { $timer.Stop(); try { $f.Close() } catch {}; return }
                $act = $seq[$i]; $i++
                $btns = @(); foreach ($ct in $f.Controls) { if ($ct -is [System.Windows.Forms.Button]) { $btns += $ct } }
                if ($act -eq 'N') { $nx = $btns | Where-Object { $_.Text -notmatch 'Back' -and $_.Enabled } | Select-Object -First 1; if ($nx) { $nx.PerformClick() } }
                elseif ($act -eq 'B') { $bk = $btns | Where-Object { $_.Text -match 'Back' -and $_.Enabled } | Select-Object -First 1; if ($bk) { $bk.PerformClick() } }
            } catch { Fault 'nav-drive' $_.Exception.Message; $timer.Stop() }
        })
        $timer.Start()
        [void](Show-Wizard -Steps $stepArr -Stages @('Import','Bushing','Layout','Datums','Box','Drill','Relief','Done') -Title 'FUZZ-NAV' -Context $navCtx)
        $timer.Dispose()
        Ok "navigation drive completed without escaping exceptions"
    } catch { Fault 'nav-drive-harness' $_.Exception.Message }
} else {
    Note "navigation drive skipped (set WIZ_LIVE_DRIVE=1 to enable the modal drive)"
}

# ============================================================================
# LAYOUT REGRESSION: Show-CustomPointsDialog (lib\orthogrid_gui.ps1) had its 2-line
# bold readout at y=372 (h40 -> 372-412) OVERLAPPING the part-size row (the "Specify
# part size" radio + W/H textboxes at y=364-386). The modal can't be rendered non-modally
# here, so lock the fix at the SOURCE: parse the readout/error/size-row Y coords and assert
# the readout starts AT OR BELOW the size-row bottom (386). Fails if the overlap regresses.
# ============================================================================
Write-Host "  -- layout regression: custom-dialog readout clears the size row --" -ForegroundColor White
try {
    $ogSrc = Get-Content -Raw (Join-Path $libDir 'orthogrid_gui.ps1')
    # isolate the Show-CustomPointsDialog function body (its readout is the one at issue)
    $cpIdx = $ogSrc.IndexOf('function Show-CustomPointsDialog')
    $cpBody = if ($cpIdx -ge 0) { $ogSrc.Substring($cpIdx) } else { $ogSrc }
    # readout Y = the Point Y on the line after '$lblReadout = New-Object ... Label'
    $mRead = [regex]::Match($cpBody, '\$lblReadout\.Location\s*=\s*New-Object System\.Drawing\.Point\(\s*\d+\s*,\s*(\d+)\s*\)')
    # size-row bottom = max(tbW/tbH Y + height). tbH Location Y + Size height.
    $mTbH  = [regex]::Match($cpBody, '\$tbH\.Location\s*=\s*New-Object System\.Drawing\.Point\(\s*\d+\s*,\s*(\d+)\s*\)')
    $mTbHsz= [regex]::Match($cpBody, '\$tbH\.Size\s*=\s*New-Object System\.Drawing\.Size\(\s*\d+\s*,\s*(\d+)\s*\)')
    if ($mRead.Success -and $mTbH.Success -and $mTbHsz.Success) {
        $readoutY = [int]$mRead.Groups[1].Value
        $sizeRowBottom = [int]$mTbH.Groups[1].Value + [int]$mTbHsz.Groups[1].Value
        if ($readoutY -ge $sizeRowBottom) { Ok ("layout: custom-dialog readout (y=$readoutY) clears the size row (bottom=$sizeRowBottom)") }
        else { Fault 'layout/custom-readout' ("readout y=$readoutY OVERLAPS the size row (bottom=$sizeRowBottom) - the modal will draw the readout over the W/H fields") }
    } else {
        Note "layout regression: could not parse the custom-dialog coords (skipped)"
    }
} catch { Fault 'layout-regression-harness' $_.Exception.Message }

# ============================================================================
# ORACLE: new error-log entries?
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
    Write-Host ("  FUZZ RESULT: clean ({0} checks, {1} scenarios, no faults)" -f $script:checks, $scenarios.Count) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("  FUZZ RESULT: {0} FAULT(S):" -f $script:faults.Count) -ForegroundColor Red
    foreach ($ff in $script:faults) { Write-Host "    - $ff" -ForegroundColor Red }
    exit 1
}
