# ============================================================================
# lib\tests\run_wizard_tests.ps1 - offline tests for the GUI wizard layer
# ============================================================================
# Runs WITHOUT Creo and WITHOUT network. Exercises:
#   * lib\wizard.ps1 PURE logic - breadcrumb state machine, back-navigation
#     guard (committed-step boundary), chip color palette, step descriptor.
#   * lib\drilljig_core.ps1 PURE helpers - the decision-tree/catalog parsing
#     (ConvertTo-Decimal, Get-FracLabel, Get-FixedOdSpec, Group-CatalogByOD,
#     New-IdUnspecifiedPick) and the macro-string builders (Get-SelectByIdMacro,
#     Get-SelectDatumByIdMacro, Build-HoleMacro, Build-ReliefHoleMacro,
#     Resolve-PlaneRole), which must be byte-for-byte the proven recipes.
#   * PARSE + FUNCTION-RESOLVE smoke check of drilljig-gui.cmd (the WinForms
#     surface can't run headless, but it must parse and every function it calls
#     must exist - the same bar orthogrid_gui gets).
#
# Run:  powershell -ExecutionPolicy Bypass -File lib\tests\run_wizard_tests.ps1
# Exit code 0 = all passed, 1 = at least one failure.
# ============================================================================

$ErrorActionPreference = "Stop"
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here
$root   = Split-Path -Parent $libDir

# drilljig_core needs creo_geometry + orthogrid in scope for a couple of helpers
# at dot-source time; load the same set the GUI loads (none of these touch Creo).
. (Join-Path $libDir 'creo_geometry.ps1')
. (Join-Path $libDir 'blind_evaluator.ps1')
. (Join-Path $libDir 'orthogrid.ps1')
. (Join-Path $libDir 'orthogrid_points.ps1')
. (Join-Path $libDir 'drilljig_core.ps1')
. (Join-Path $libDir 'wizard.ps1')

$script:pass = 0
$script:fail = 0
function Assert-True {
    param([string]$Name, [bool]$Cond, [string]$Detail = "")
    if ($Cond) { Write-Host "  [PASS] $Name" -ForegroundColor Green; $script:pass++ }
    else       { Write-Host "  [FAIL] $Name $Detail" -ForegroundColor Red;   $script:fail++ }
}
function Approx { param([double]$A, [double]$B, [double]$Tol = 1e-9) return [Math]::Abs($A - $B) -le $Tol }

Write-Host ""
Write-Host "  Running wizard / drilljig-core unit tests (offline)..." -ForegroundColor Cyan
Write-Host ""

# ----------------------------------------------------------------------------
# Breadcrumb state machine
# ----------------------------------------------------------------------------
Write-Host "  -- breadcrumb state machine --" -ForegroundColor White
$stages = @('Bushing','Layout','Datums','Box','Drill','Done')
# steps: one per stage in order (indices 0..5)
$steps = @(
    (New-WizardStep -Key a -Title A -Stage Bushing -Build {}),
    (New-WizardStep -Key b -Title B -Stage Layout  -Build {}),
    (New-WizardStep -Key c -Title C -Stage Datums  -Build {}),
    (New-WizardStep -Key d -Title D -Stage Box     -Build {}),
    (New-WizardStep -Key e -Title E -Stage Drill   -Build {}),
    (New-WizardStep -Key f -Title F -Stage Done    -Build {})
)
$bc0 = Get-BreadcrumbStates -Stages $stages -Steps $steps -CurrentIndex 0
Assert-True "stage 0 (Bushing) is active at index 0" (($bc0 | Where-Object { $_.Name -eq 'Bushing' }).State -eq 'active')
Assert-True "stage 1 (Layout) is future at index 0"   (($bc0 | Where-Object { $_.Name -eq 'Layout' }).State -eq 'future')
$bc3 = Get-BreadcrumbStates -Stages $stages -Steps $steps -CurrentIndex 3
Assert-True "stage Box active at index 3"   (($bc3 | Where-Object { $_.Name -eq 'Box' }).State -eq 'active')
Assert-True "stage Bushing done at index 3" (($bc3 | Where-Object { $_.Name -eq 'Bushing' }).State -eq 'done')
Assert-True "stage Drill future at index 3" (($bc3 | Where-Object { $_.Name -eq 'Drill' }).State -eq 'future')
$bc5 = Get-BreadcrumbStates -Stages $stages -Steps $steps -CurrentIndex 5
Assert-True "all but Done are done at last index" ((@($bc5 | Where-Object { $_.State -eq 'done' }).Count) -eq 5)

# multi-step-per-stage: two steps share a stage
$steps2 = @(
    (New-WizardStep -Key a -Title A -Stage Drill -Build {}),
    (New-WizardStep -Key b -Title B -Stage Drill -Build {}),
    (New-WizardStep -Key c -Title C -Stage Done  -Build {})
)
$bcA = Get-BreadcrumbStates -Stages @('Drill','Done') -Steps $steps2 -CurrentIndex 0
$bcB = Get-BreadcrumbStates -Stages @('Drill','Done') -Steps $steps2 -CurrentIndex 1
Assert-True "stage spanning 2 steps stays active across both" `
    ((($bcA | Where-Object {$_.Name -eq 'Drill'}).State -eq 'active') -and (($bcB | Where-Object {$_.Name -eq 'Drill'}).State -eq 'active'))

# a stage with no steps is future
$bcNo = Get-BreadcrumbStates -Stages @('Ghost','Drill') -Steps $steps2 -CurrentIndex 0
Assert-True "stage with no steps is future" (($bcNo | Where-Object {$_.Name -eq 'Ghost'}).State -eq 'future')

# ----------------------------------------------------------------------------
# Back-navigation guard (committed boundary)
# ----------------------------------------------------------------------------
Write-Host "  -- back-navigation guard --" -ForegroundColor White
$gs = @(
    (New-WizardStep -Key a -Title A -Stage S -Build {}),
    (New-WizardStep -Key b -Title B -Stage S -Build {}),
    (New-WizardStep -Key c -Title C -Stage S -Build {})
)
Assert-True "no commits: max committed index = -1" ((Get-MaxCommittedIndex -Steps $gs) -eq -1)
Assert-True "can't go back from index 0" (-not (Test-CanGoBack -CurrentIndex 0 -MaxCommittedIndex -1))
Assert-True "can go back from index 1 with no commits" (Test-CanGoBack -CurrentIndex 1 -MaxCommittedIndex -1)
$gs[1].Committed = $true
Assert-True "max committed index follows .Committed" ((Get-MaxCommittedIndex -Steps $gs) -eq 1)
Assert-True "cannot go back INTO a committed step (idx 2 -> 1 blocked)" (-not (Test-CanGoBack -CurrentIndex 2 -MaxCommittedIndex 1))
Assert-True "cannot go back when target == committed" (-not (Test-CanGoBack -CurrentIndex 2 -MaxCommittedIndex 1))
$gs[1].Committed = $false; $gs[0].Committed = $true
Assert-True "back to a step after the committed one is allowed (idx 2 -> 1, committed 0)" (Test-CanGoBack -CurrentIndex 2 -MaxCommittedIndex 0)

# ----------------------------------------------------------------------------
# Chip color palette
# ----------------------------------------------------------------------------
Write-Host "  -- chip color palette --" -ForegroundColor White
Assert-True "needs-input -> Gray"      ((Resolve-ChipColorName -State 'needs-input') -eq 'Gray')
Assert-True "set -> SteelBlue"         ((Resolve-ChipColorName -State 'set') -eq 'SteelBlue')
Assert-True "built -> SeaGreen"        ((Resolve-ChipColorName -State 'built') -eq 'SeaGreen')
Assert-True "verified -> SeaGreen"     ((Resolve-ChipColorName -State 'verified') -eq 'SeaGreen')
Assert-True "unverified -> Goldenrod"  ((Resolve-ChipColorName -State 'unverified') -eq 'Goldenrod')
Assert-True "warning -> Goldenrod"     ((Resolve-ChipColorName -State 'warning') -eq 'Goldenrod')
Assert-True "aborted -> Firebrick"     ((Resolve-ChipColorName -State 'aborted') -eq 'Firebrick')
Assert-True "unknown -> Gray (fallback)" ((Resolve-ChipColorName -State 'frobnitz') -eq 'Gray')
Assert-True "case-insensitive"         ((Resolve-ChipColorName -State 'BUILT') -eq 'SeaGreen')

# ----------------------------------------------------------------------------
# New-WizardStep descriptor
# ----------------------------------------------------------------------------
Write-Host "  -- step descriptor --" -ForegroundColor White
$st = New-WizardStep -Key 'k' -Title 'T' -Stage 'S' -Kind 'pick' -PrimaryText 'Go' -Build {} -Validate { $true } -OnNext { $true }
Assert-True "step Key"     ($st.Key -eq 'k')
Assert-True "step Kind"    ($st.Kind -eq 'pick')
Assert-True "step Primary" ($st.PrimaryText -eq 'Go')
Assert-True "step starts uncommitted" (-not $st.Committed)
Assert-True "step default Kind is info" ((New-WizardStep -Key x -Title x -Stage s -Build {}).Kind -eq 'info')

# ----------------------------------------------------------------------------
# drilljig_core PURE: decision-tree + catalog parsing
# ----------------------------------------------------------------------------
Write-Host "  -- core: fraction / OD parsing --" -ForegroundColor White
Assert-True "ConvertTo-Decimal 3/4"    (Approx (ConvertTo-Decimal '3/4') 0.75)
Assert-True "ConvertTo-Decimal 1.25"   (Approx (ConvertTo-Decimal '1.25') 1.25)
Assert-True "ConvertTo-Decimal junk -> null" ($null -eq (ConvertTo-Decimal 'abc'))
Assert-True "Get-FracLabel OD"  ((Get-FracLabel 'HSB | OD 3/4 x ID 1/2 x 1 Lg' 'OD' 'x') -eq '3/4')
Assert-True "Get-FracLabel Lg"  ((Get-FracLabel 'HSB | OD 3/4 x ID 1/2 x 1 3/8 Lg' 'Lg' 'x') -eq '1 3/8')
Assert-True "Get-FracLabel fallback" ((Get-FracLabel 'no easyname here' 'OD' 'FB') -eq 'FB')
Assert-True "Get-FixedOdSpec 3/4"    (Approx (Get-FixedOdSpec 'the OD of the hole will be 3/4 in') 0.75)
Assert-True "Get-FixedOdSpec none"   ($null -eq (Get-FixedOdSpec 'no diameter mentioned here'))

Write-Host "  -- core: catalog grouping --" -ForegroundColor White
# build a tiny synthetic catalog (in-memory rows shaped like Import-Csv output)
$rows = @(
    [pscustomobject]@{ OD='0.75'; ID='0.5';  Length='1.0'; EasyName='HSB | OD 3/4 x ID 1/2 x 1 Lg';     PartNumber='P1' },
    [pscustomobject]@{ OD='0.75'; ID='0.6';  Length='1.0'; EasyName='HSB | OD 3/4 x ID 5/8 x 1 Lg';     PartNumber='P2' },
    [pscustomobject]@{ OD='0.75'; ID='0.5';  Length='1.5'; EasyName='HSB | OD 3/4 x ID 1/2 x 1 1/2 Lg'; PartNumber='P3' },
    [pscustomobject]@{ OD='0.5';  ID='0.25'; Length='1.0'; EasyName='HSB | OD 1/2 x ID 1/4 x 1 Lg';     PartNumber='P4' }
)
$grp = Group-CatalogByOD -Rows $rows
Assert-True "grouping: 2 distinct ODs"            (@($grp).Count -eq 2)
Assert-True "grouping: ODs ascending (0.5 first)" (Approx $grp[0].OD 0.5)
$od075 = $grp | Where-Object { (Approx $_.OD 0.75) } | Select-Object -First 1
Assert-True "grouping: OD 0.75 has 2 lengths"     (@($od075.Lengths).Count -eq 2)
$len1 = $od075.Lengths | Where-Object { (Approx $_.Length 1.0) } | Select-Object -First 1
Assert-True "grouping: OD0.75 x Lg1.0 has 2 ID rows" (@($len1.Rows).Count -eq 2)
Assert-True "grouping: OD label is a fraction"    ($od075.ODLabel -eq '3/4')

$uns = New-IdUnspecifiedPick -ODLabel '3/4' -LenLabel '1' -Rows $len1.Rows
Assert-True "id-unspec: OD carried"        (Approx ([double]$uns.OD) 0.75)
Assert-True "id-unspec: ID is (any)"       ($uns.ID -eq '(any)')
Assert-True "id-unspec: Length carried"    (Approx ([double]$uns.Length) 1.0)

# ----------------------------------------------------------------------------
# drilljig_core PURE: plane-role classifier
# ----------------------------------------------------------------------------
Write-Host "  -- core: Resolve-PlaneRole --" -ForegroundColor White
Assert-True "SIDE -> Side"   ((Resolve-PlaneRole 'SIDE') -eq 'Side')
Assert-True "TOP -> Top"     ((Resolve-PlaneRole 'TOP') -eq 'Top')
Assert-True "FRONT -> Front" ((Resolve-PlaneRole 'FRONT') -eq 'Front')
Assert-True "case-insensitive 'side datum'" ((Resolve-PlaneRole 'side datum') -eq 'Side')
Assert-True "no keyword -> null" ($null -eq (Resolve-PlaneRole 'DTM1'))
Assert-True "empty -> null"      ($null -eq (Resolve-PlaneRole ''))

# ----------------------------------------------------------------------------
# drilljig_core PURE: macro string builders (must match the proven recipes)
# ----------------------------------------------------------------------------
Write-Host "  -- core: by-id select macros --" -ForegroundColor White
# NOTE: the macro strings contain SINGLE backticks (PowerShell collapses the
# doubled backticks in the source to one). Match the widget name + value with
# [^|]*-style gaps rather than literal backticks to stay readable + robust.
$selF = Get-SelectByIdMacro -FeatId 42
Assert-True "select-by-id: clears buffer by default" ($selF -match 'buffer_clean')
Assert-True "select-by-id: type Feature"             ($selF -match 'SelOptionRadio.*Feature')
Assert-True "select-by-id: carries the id"           ($selF -match 'InputIDPanel.*42')
Assert-True "select-by-id: Evaluate+Apply+Cancel"    (($selF -match 'EvaluateBtn') -and ($selF -match 'ApplyBtn') -and ($selF -match 'CancelButton'))
$selNC = Get-SelectByIdMacro -FeatId 7 -NoClear
Assert-True "select-by-id -NoClear: NO buffer_clean"  (-not ($selNC -match 'buffer_clean'))
$selD = Get-SelectDatumByIdMacro -FeatId 9
Assert-True "select-datum: type Datum"        ($selD -match 'SelOptionRadio.*Datum')
Assert-True "select-datum: LookBy Feature"    ($selD -match 'LookByOptionMenu.*Feature')
Assert-True "select-datum: NO buffer_clean"   (-not ($selD -match 'buffer_clean'))

Write-Host "  -- core: hole macros --" -ForegroundColor White
$h0 = Build-HoleMacro -PointId 100 -Diameter 0.5 -BodyIndex 0
Assert-True "hole: ProCmdHole present"        ($h0 -match 'ProCmdHole')
Assert-True "hole: thru-all depth type"       ($h0 -match 'StrHoleDepThruAllF')
Assert-True "hole: diameter input present"    ($h0 -match 'diameter_mip_OptionMenu.*0\.5')
Assert-True "hole: confirm Done"              ($h0 -match 'dashInst0\.Done')
Assert-True "hole: point selected by id"      ($h0 -match 'InputIDPanel.*100')
Assert-True "hole: point-only has NO surface datum search" (-not ($h0 -match 'SelOptionRadio.*Datum'))
Assert-True "hole: point-only has NO flip"    (-not ($h0 -match 'maindashInst0\.Flip'))
$hS = Build-HoleMacro -PointId 100 -Diameter 0.5 -BodyIndex 0 -SurfacePlaneId 55
Assert-True "hole+surface: selects the surface as Datum" ($hS -match 'SelOptionRadio.*Datum')
Assert-True "hole+surface: surface id present" ($hS -match 'InputIDPanel.*55')
Assert-True "hole+surface: one flip by default" (([regex]::Matches($hS, 'maindashInst0\.Flip')).Count -eq 1)
$hS2 = Build-HoleMacro -PointId 100 -Diameter 0.5 -BodyIndex 0 -SurfacePlaneId 55 -FlipCount 2
Assert-True "hole+surface FlipCount=2: two flips" (([regex]::Matches($hS2, 'maindashInst0\.Flip')).Count -eq 2)
$r0 = Build-ReliefHoleMacro -PointId 100 -Diameter 0.75 -BodyIndex 0
Assert-True "relief: BLIND depth type (not thru-all)" (($r0 -match 'StrHoleDepBlindF') -and (-not ($r0 -match 'StrHoleDepThruAllF')))
Assert-True "relief: diameter present"         ($r0 -match 'diameter_mip_OptionMenu.*0\.75')

# ----------------------------------------------------------------------------
# core: chip-relief SLOT macros (Build-CutFinishMacro + Build-SlotPatternMacro),
# shared by slotinator.cmd + drilljig.cmd + drilljig-gui.cmd.
# ----------------------------------------------------------------------------
Write-Host "  -- core: slot macros --" -ForegroundColor White
$cut = Build-CutFinishMacro -Depth 0.15 -BodyIndex 0 -Flip $true
Assert-True "cut: finishes the sketch"          ($cut -match 'ProCmdSketDone')
Assert-True "cut: flip when -Flip true"         ($cut -match 'maindashInst0\.flip_pb')
Assert-True "cut: types blind depth"            ($cut -match 'def_depth1_ip.*0\.15')
Assert-True "cut: remove-material toggle"       ($cut -match 'remove_material_cb')
Assert-True "cut: confirm Done"                 ($cut -match 'dashInst0\.Done')
$cutNF = Build-CutFinishMacro -Depth 0.0 -BodyIndex 0 -Flip $false
Assert-True "cut: -Flip false -> no flip"       (-not ($cutNF -match 'maindashInst0\.flip_pb'))
Assert-True "cut: depth 0 -> no depth typed"    (-not ($cutNF -match 'def_depth1_ip'))
$sp = Build-SlotPatternMacro -DirDatumId 55 -Count 5 -Spacing 4
Assert-True "slotpat: opens the geom pattern"   ($sp -match 'ProCmdGeomPattern')
Assert-True "slotpat: activates dir-1 collector"($sp -match 'ui_pat_dir_dir1')
Assert-True "slotpat: feeds the datum by id"    ($sp -match 'SelOptionRadio.*Datum' -and $sp -match 'InputIDPanel.*55')
Assert-True "slotpat: sets count"               ($sp -match 'ui_pat_dir_1_num_inst.*5')
Assert-True "slotpat: sets spacing"             ($sp -match 'ui_pat_dir_1_incr.*4')
Assert-True "slotpat: confirms stdbtn_1"        ($sp -match 'dashInst0\.stdbtn_1')
$spF = Build-SlotPatternMacro -DirDatumId 55 -Count 5 -Spacing 4 -Flip
Assert-True "slotpat: -Flip adds ui_pat_dir_1_flip" ($spF -match 'ui_pat_dir_1_flip')

# ----------------------------------------------------------------------------
# PARSE + FUNCTION-RESOLVE smoke check of drilljig-gui.cmd
# ----------------------------------------------------------------------------
Write-Host "  -- smoke: drilljig-gui.cmd parse + resolve --" -ForegroundColor White
$guiRaw = Get-Content -Raw (Join-Path $root 'drilljig-gui.cmd')
$perr = $null
[void][System.Management.Automation.PSParser]::Tokenize($guiRaw, [ref]$perr)
Assert-True "drilljig-gui.cmd parses clean" ($perr.Count -eq 0) ("({0} errors)" -f $perr.Count)

# also parse-check the two new libs
foreach ($lf in @('wizard.ps1','drilljig_core.ps1')) {
    $t = Get-Content -Raw (Join-Path $libDir $lf)
    $e = $null
    [void][System.Management.Automation.PSParser]::Tokenize($t, [ref]$e)
    Assert-True ("lib\$lf parses clean") ($e.Count -eq 0) ("({0} errors)" -f $e.Count)
}

# every drilljig-core public function the GUI relies on resolves
$coreFns = @('Initialize-DrilljigCore','New-OffsetPlane','Set-PlaneOffset','Set-ReliefHoleDepth',
             'Build-HoleMacro','Build-ReliefHoleMacro','Get-SelectByIdMacro','Get-SelectDatumByIdMacro',
             'Read-SelectedId','Read-SelectionPlanePicks','Find-DefaultDatumPicks','Resolve-SelectedPointIds',
             'Get-BodyList','Get-CatalogRows','Group-CatalogByOD','Invoke-Macro','Invoke-ForceRegen','Wait-ModelModified',
             'Build-CsysFromPlanesMacro','Get-CsysShowMacro','Resolve-IndexHolePlanes','Read-IndexSelectionIds','Invoke-IndexCsys',
             'Get-HolesRelativeToIndex','Export-IndexHoleCsv','Build-CsysOffsetPointsMacro','Invoke-CsysOffsetPoints',
             'Resolve-HoleFeatGroups','Format-IndexHoleReport','Write-IndexHoleReport')
$missingCore = @($coreFns | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
Assert-True "all drilljig-core functions resolve" ($missingCore.Count -eq 0) ("missing: {0}" -f ($missingCore -join ', '))

$wizFns = @('New-WizardStep','Show-Wizard','Add-WizardChoiceCards','Get-BreadcrumbStates','Get-MaxCommittedIndex','Test-CanGoBack','Resolve-ChipColorName')
$missingWiz = @($wizFns | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
Assert-True "all wizard functions resolve" ($missingWiz.Count -eq 0) ("missing: {0}" -f ($missingWiz -join ', '))

# Add-WizardChoiceCards advertises the -AfterPick contract (rerender|advance|none).
# Its param() references [System.Windows.Forms.Panel], so Get-Command can only bind
# the parameter metadata once WinForms is loaded - load it (present on this box;
# the same assembly Show-Wizard loads). Skip gracefully if unavailable (headless CI).
$wfLoaded = $false
try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop; Add-Type -AssemblyName System.Drawing -ErrorAction Stop; $wfLoaded = $true } catch { $wfLoaded = $false }
if ($wfLoaded) {
    $apParam = (Get-Command Add-WizardChoiceCards).Parameters['AfterPick']
    Assert-True "Add-WizardChoiceCards has -AfterPick" ($null -ne $apParam)
    if ($null -ne $apParam) {
        $apValid = @($apParam.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | Select-Object -First 1)
        Assert-True "-AfterPick validates rerender|advance|none" ($null -ne $apValid -and (@($apValid.ValidValues) -contains 'rerender') -and (@($apValid.ValidValues) -contains 'advance') -and (@($apValid.ValidValues) -contains 'none'))
    }
} else {
    Write-Host "  [SKIP] -AfterPick metadata check (WinForms not available headless)" -ForegroundColor DarkGray
}

# ----------------------------------------------------------------------------
# INTEGRATION: fire the drilljig-gui decision-tree OnPick callbacks (the prior
# render-only smoke missed the captured-variable bug where an OnPick indexed a
# Build-local $grouped that is $null at click time). This rebuilds the tree step
# from drilljig-gui.cmd, captures the OnPick each Build hands to a stubbed
# Add-WizardChoiceCards, and FIRES it - walking Q1->Q2->OD->length->ID and
# asserting no throw + a resolved diameter. Requires WinForms (the step Build
# constructs Labels); skips gracefully headless.
# ----------------------------------------------------------------------------
Write-Host "  -- integration: fire tree OnPick callbacks --" -ForegroundColor White
if (-not $wfLoaded) {
    Write-Host "  [SKIP] tree OnPick walk (WinForms not available headless)" -ForegroundColor DarkGray
} else {
    try {
        . (Join-Path $libDir 'orthogrid_gui.ps1')
        Initialize-DrilljigCore -Session $null -Model $null -TypeObj $null -DataDir (Join-Path $root 'data') -Log $null

        $fakeWiz = [pscustomobject]@{ }
        foreach ($mm in 'SetChip','Refresh','Log','Pump','SetProgress','BeginRun','EndRun','MarkCommitted','SetStatus','LogError','Next','Rerender') {
            $fakeWiz | Add-Member ScriptMethod $mm { param($a,$b,$c) } -Force
        }
        # stub Add-WizardChoiceCards to capture the OnPick + Options
        $script:capOnPick = $null; $script:capOpts = $null
        function Add-WizardChoiceCards { param($Panel,$Options,$OnPick,$Context,$Wizard,$CardWidth,$CardHeight,$AfterPick) $script:capOnPick=$OnPick; $script:capOpts=$Options }

        $src = Get-Content -Raw (Join-Path $root 'drilljig-gui.cmd')
        $h0 = $src.IndexOf('# STEP BUILDERS'); $h1 = $src.IndexOf('# Build the connection up front')
        Invoke-Expression $src.Substring($h0, $h1 - $h0) | Out-Null
        $siR = $src.IndexOf('# WIZARD STEPS'); $eiR = $src.IndexOf('# RUN THE WIZARD')
        $RELIEF_DIA_MULT = 1.5; $noCornerRound = $false; $cornerRadius = 0.25
        function Invoke-BoxEval { param($Operation,$Expected) return $true }
        $model=$null;$pfcType=$null;$session=$null
        $ctx = @{
            TreePath = Join-Path $root 'docs\drill_jig_decision_tree.json'
            Path=[System.Collections.ArrayList]::new(); Picks=[System.Collections.ArrayList]::new()
            HoleDia=$null; BushingLen=$null; Is3dPrint=$false
            TreeNode=$null; TreeDone=$false; PendingSpec=$null; BushStage=$null; Grouped=$null; BushOD=$null; BushLen=$null
            PointMode='predefined'; OrthoGeo=$null; LayoutPicked=$false
            Planes=$null; AutoMapped=$false; SidePlane=$null; Made=@(); BoxArmed=$false; SketchPlaneId=$null; ExtrudeToId=$null; BoxBuilt=$false; BuildConfirmed=$null
            GridPointIDs=@(); GridPlaneIds=@(); PointIDs=@(); BodyIndex=0; HoleDiaFinal=0.0; Drilled=$false
        }
        $steps = New-Object System.Collections.ArrayList
        $treeRoot = Get-Content $ctx.TreePath -Raw | ConvertFrom-Json
        $ctx.TreeNode = @($treeRoot)[0]
        Invoke-Expression $src.Substring($siR, $eiR - $siR) | Out-Null
        $tStep = $steps | Where-Object { $_.Key -eq 'tree' } | Select-Object -First 1

        $fire = {
            param($i)
            $pnl = New-Object System.Windows.Forms.Panel; $pnl.Size = New-Object System.Drawing.Size(820,380)
            & $tStep.Build $pnl $ctx $fakeWiz | Out-Null
            if ($null -eq $script:capOnPick) { throw "no OnPick captured" }
            & $script:capOnPick $i $script:capOpts[$i] $ctx $fakeWiz | Out-Null
            $pnl.Dispose()
        }
        $threw = $false
        try {
            & $fire 0   # Q1 material
            & $fire 0   # Q2 PFD/Hand -> outcome -> catalog
            if ($null -ne $ctx.PendingSpec) {
                & $fire 0   # OD pick (the bug site)
                & $fire 0   # length
                & $fire 0   # ID -> Any
            }
        } catch { $threw = $true; Write-Host ("       threw: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow }
        Assert-True "tree OnPick walk does not throw (no null-index)" (-not $threw)
        Assert-True "tree walk set BushOD via persistent context" ($null -ne $ctx.BushOD)
        Assert-True "tree walk resolved a bushing pick" ($ctx.Picks.Count -gt 0)
        Assert-True "tree walk set TreeDone" ([bool]$ctx.TreeDone)
        Assert-True "resolved HoleDiameter > 0" ($ctx.Picks.Count -gt 0 -and [double]$ctx.Picks[$ctx.Picks.Count-1].HoleDiameter -gt 0)

        # --- the tree is now DONE with a pick: the confirmation branch must render
        #     a Change button instead of re-showing the OD cards (no endless cycle).
        $cp = New-Object System.Windows.Forms.Panel; $cp.Size = New-Object System.Drawing.Size(820,380)
        & $tStep.Build $cp $ctx $fakeWiz | Out-Null
        $hasChange = $false
        foreach ($cc in $cp.Controls) { if ($cc -is [System.Windows.Forms.Button] -and $cc.Text -match 'Change') { $hasChange = $true } }
        Assert-True "bushing-done shows a Change button (no re-cycle)" $hasChange
        $cp.Dispose()

        # --- the EMBEDDED inline orthogrid editor: render it in-canvas and assert it
        #     computes a valid grid + gates the layout step (the no-popup embed).
        . (Join-Path $libDir 'orthogrid_gui.ps1')
        $lStep = $steps | Where-Object { $_.Key -eq 'layout' } | Select-Object -First 1
        $ctx.PointMode='orthogrid'; $ctx.LayoutMode='orthogrid'; $ctx.OrthoValid=$false; $ctx.OrthoFields=$null; $ctx.OrthoGeo=$null
        $lp = New-Object System.Windows.Forms.Panel; $lp.Size = New-Object System.Drawing.Size(820,360)
        & $lStep.Build $lp $ctx $fakeWiz | Out-Null
        Assert-True "inline orthogrid editor computes a valid grid" ([bool]$ctx.OrthoValid)
        Assert-True "inline editor stored an orthogrid OrthoGeo" ($null -ne $ctx.OrthoGeo -and $ctx.OrthoGeo.Mode -eq 'orthogrid')
        Assert-True "layout Validate passes on a valid embedded grid" ([bool](& $lStep.Validate $ctx))
        $lp.Dispose()
        # invalid field flips it off (Next gates)
        $ctx.OrthoFields['Nx'] = 'abc'; $ctx.OrthoValid = $true
        $lp2 = New-Object System.Windows.Forms.Panel; $lp2.Size = New-Object System.Drawing.Size(820,360)
        & $lStep.Build $lp2 $ctx $fakeWiz | Out-Null
        Assert-True "invalid Nx flips OrthoValid false (Next gates off)" (-not $ctx.OrthoValid)
        Assert-True "layout Validate fails on an invalid embedded grid" (-not (& $lStep.Validate $ctx))
        $lp2.Dispose()
    } catch {
        Assert-True "tree OnPick integration harness ran" $false ("harness error: {0}" -f $_.Exception.Message)
    }
}

# ----------------------------------------------------------------------------
# DRIVE: run a real wizard and click Next via PerformClick. This is the test
# whose absence let the "$script:wz/$wzLogError null inside a .GetNewClosure block"
# bug through -- a $script:-scoped var set in Show-Wizard is INVISIBLE inside the
# closures, so $wz.Steps[..] / $wiz.Refresh() threw "Cannot index into a null
# array" on every click and the buttons never gated (so nothing responded). They
# are now LOCALS captured by .GetNewClosure (which DOES see live mutations). This
# drives 3 valid steps to completion and asserts Next stayed enabled + advanced +
# nothing got logged to the error file. Requires WinForms; skips headless.
# ----------------------------------------------------------------------------
Write-Host "  -- drive: click Next through a live wizard --" -ForegroundColor White
if (-not $wfLoaded) {
    Write-Host "  [SKIP] wizard drive (WinForms not available headless)" -ForegroundColor DarkGray
} else {
    try {
        $logPath = Join-Path ([System.IO.Path]::GetTempPath()) 'drilljig-gui-error.log'
        $beforeLen = if (Test-Path $logPath) { (Get-Item $logPath).Length } else { 0 }
        $mk = {
            param($key)
            New-WizardStep -Key $key -Title $key -Stage $key -Build {
                param($panel,$c,$wiz) $lbl = New-Object System.Windows.Forms.Label; $lbl.Text='x'; $panel.Controls.Add($lbl)
            } -Validate { param($c) $true } -OnNext { param($c,$wiz) $c.Advances++; return $true }
        }
        $dsteps = @((& $mk 'A'), (& $mk 'B'), (& $mk 'C'))
        $dctx = @{ Advances = 0 }
        $script:driveErr = $null
        $clicks = 0
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 300
        $timer.Add_Tick({
            try {
                $f = [System.Windows.Forms.Form]::ActiveForm
                if ($null -eq $f) { $timer.Stop(); return }
                $btns = @(); foreach ($ctl in $f.Controls) { if ($ctl -is [System.Windows.Forms.Button]) { $btns += $ctl } }
                $nx = $btns | Where-Object { $_.Text -notmatch 'Back' } | Select-Object -First 1
                if ($null -eq $nx) { $timer.Stop(); return }
                if (-not $nx.Enabled) { $script:driveErr = 'Next disabled on a valid step (Refresh failed to gate)'; $timer.Stop(); $f.Close(); return }
                $nx.PerformClick(); $clicks++
                if ($clicks -ge 5) { $timer.Stop(); try { $f.Close() } catch {} }
            } catch { $script:driveErr = $_.Exception.Message; $timer.Stop() }
        })
        $timer.Start()
        $completed = Show-Wizard -Steps $dsteps -Stages @('A','B','C') -Title 'DRIVE-TEST' -Context $dctx
        $timer.Dispose()
        $afterLen = if (Test-Path $logPath) { (Get-Item $logPath).Length } else { 0 }

        Assert-True "drive: no handler error during clicks" ($null -eq $script:driveErr) ("err: {0}" -f $script:driveErr)
        Assert-True "drive: Next advanced through all 3 steps (completed)" ([bool]$completed)
        Assert-True "drive: 3 OnNext advances fired" ($dctx.Advances -ge 3) ("got {0}" -f $dctx.Advances)
        Assert-True "drive: no NEW entries in the error log (no closure-scope throw)" ($afterLen -le $beforeLen)
    } catch {
        Assert-True "wizard drive harness ran" $false ("harness error: {0}" -f $_.Exception.Message)
    }
}

# ----------------------------------------------------------------------------
# HYBRID SCOPE: the killer test. drilljig-gui.cmd runs its whole body via
# & ([scriptblock]::Create(<text>)) (the hybrid .cmd header). Functions dot-sourced
# into THAT scriptblock land in its LOCAL scope, and .GetNewClosure() blocks (the
# inline-editor recompute, the breadcrumb Paint, $wiz.Refresh) resolve bare function
# names against GLOBAL scope -- so a plain `function Foo` is INVISIBLE to them and
# the inline orthogrid/custom editors silently failed (no diagram, Next disabled).
# The fix was `function global:` on the pure helpers (wizard's Get-MaxCommittedIndex
# /Test-CanGoBack/Get-BreadcrumbStates/Resolve-ChipColorName + orthogrid's
# Get-OrthogridGeometry/Get-CustomPointsGeometry/Get-SharedPlanePlan/Draw-AxisGlyph).
# This test runs the layout step's inline editors UNDER scriptblock::Create and
# asserts they compute -- the execution model the other tests (normal script scope)
# could NOT exercise. Requires WinForms; skips headless.
# ----------------------------------------------------------------------------
Write-Host "  -- hybrid scope: inline editors under scriptblock::Create (child process) --" -ForegroundColor White
if (-not $wfLoaded) {
    Write-Host "  [SKIP] hybrid-scope test (WinForms not available headless)" -ForegroundColor DarkGray
} else {
    # CRITICAL: this must run in a CHILD powershell process whose TOP-LEVEL invocation
    # is & ([scriptblock]::Create(...)) -- exactly like the .cmd header. Running the
    # scriptblock NESTED inside this already-running test does NOT reproduce the bug
    # (a nested scriptblock inherits the parent's function table), which is why an
    # earlier in-process version of this test was a false-positive. The child writes
    # one line: GRID=<bool> CUSTOM=<bool>. We then assert both are True. (A mutation
    # test confirmed this child harness FAILS when the orthogrid globals are removed.)
    $childScript = @'
param($ROOT)
$ErrorActionPreference = 'Stop'
$body = {
    Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing
    . (Join-Path $ROOT 'lib\creo_geometry.ps1'); . (Join-Path $ROOT 'lib\blind_evaluator.ps1')
    . (Join-Path $ROOT 'lib\orthogrid.ps1'); . (Join-Path $ROOT 'lib\orthogrid_gui.ps1')
    . (Join-Path $ROOT 'lib\orthogrid_points.ps1'); . (Join-Path $ROOT 'lib\drilljig_core.ps1')
    . (Join-Path $ROOT 'lib\wizard.ps1')
    Initialize-DrilljigCore -Session $null -Model $null -TypeObj $null -DataDir (Join-Path $ROOT 'data') -Log $null
    $RELIEF_DIA_MULT = 1.5; $noCornerRound = $false; $cornerRadius = 0.25
    function Invoke-BoxEval { param($Operation,$Expected) return $true }
    $model=$null;$pfcType=$null;$session=$null
    $src = Get-Content -Raw (Join-Path $ROOT 'drilljig-gui.cmd')
    $h0 = $src.IndexOf('# STEP BUILDERS'); $h1 = $src.IndexOf('# Build the connection up front')
    Invoke-Expression $src.Substring($h0, $h1 - $h0) | Out-Null
    $fakeWiz = [pscustomobject]@{}
    foreach ($m in 'SetChip','Refresh','Log','Pump','SetProgress','BeginRun','EndRun','MarkCommitted','SetStatus','LogError','Next','Rerender') { $fakeWiz | Add-Member ScriptMethod $m { param($a,$b,$c) } -Force }
    $ctx = @{
        TreePath=Join-Path $ROOT 'docs\drill_jig_decision_tree.json'
        Path=[System.Collections.ArrayList]::new(); Picks=[System.Collections.ArrayList]::new()
        HoleDia=0.75; BushingLen=1.0; Is3dPrint=$false
        TreeNode=$null; TreeDone=$false; PendingSpec=$null; BushStage=$null; Grouped=$null; BushOD=$null; BushLen=$null
        PointMode='predefined'; OrthoGeo=$null; LayoutPicked=$true; LayoutMode=$null; OrthoValid=$false; OrthoFields=$null; CustomRows=$null
        Planes=$null; AutoMapped=$false; SidePlane=$null; Made=@(); BoxArmed=$false; SketchPlaneId=$null; ExtrudeToId=$null; BoxBuilt=$false; BuildConfirmed=$null
        GridPointIDs=@(); GridPlaneIds=@(); PointIDs=@(); BodyIndex=0; HoleDiaFinal=0.0; Drilled=$false
    }
    $steps = New-Object System.Collections.ArrayList
    $treeRoot = Get-Content $ctx.TreePath -Raw | ConvertFrom-Json
    $ctx.TreeNode = @($treeRoot)[0]
    $si = $src.IndexOf('# WIZARD STEPS'); $ei = $src.IndexOf('# RUN THE WIZARD')
    Invoke-Expression $src.Substring($si, $ei - $si) | Out-Null
    $lStep = $steps | Where-Object { $_.Key -eq 'layout' } | Select-Object -First 1
    $ctx.PointMode='orthogrid'; $ctx.LayoutMode='orthogrid'; $ctx.OrthoValid=$false; $ctx.OrthoFields=$null; $ctx.OrthoGeo=$null
    $p1 = New-Object System.Windows.Forms.Panel; $p1.Size = New-Object System.Drawing.Size(840,360)
    & $lStep.Build $p1 $ctx $fakeWiz | Out-Null
    $grid = ([bool]$ctx.OrthoValid -and $null -ne $ctx.OrthoGeo -and $ctx.OrthoGeo.Mode -eq 'orthogrid'); $p1.Dispose()
    $ctx.PointMode='custom'; $ctx.LayoutMode='custom'; $ctx.OrthoValid=$false; $ctx.CustomRows=$null; $ctx.OrthoGeo=$null
    $p2 = New-Object System.Windows.Forms.Panel; $p2.Size = New-Object System.Drawing.Size(840,360)
    & $lStep.Build $p2 $ctx $fakeWiz | Out-Null
    $cust = ([bool]$ctx.OrthoValid -and $null -ne $ctx.OrthoGeo -and $ctx.OrthoGeo.Mode -eq 'custom'); $p2.Dispose()
    Write-Output ("GRID={0} CUSTOM={1}" -f $grid, $cust)
}
& ([scriptblock]::Create($body.ToString()))
'@
    try {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('wiz_hybrid_' + [System.IO.Path]::GetRandomFileName() + '.ps1')
        Set-Content -Path $tmp -Value $childScript -Encoding UTF8
        $childOut = & powershell -NoProfile -ExecutionPolicy Bypass -STA -File $tmp $root 2>&1 | Out-String
        Remove-Item $tmp -ErrorAction SilentlyContinue
        $gridOk = ($childOut -match 'GRID=True')
        $custOk = ($childOut -match 'CUSTOM=True')
        Assert-True "hybrid (child proc): inline ORTHOGRID computes under scriptblock::Create" $gridOk ("child said: " + ($childOut.Trim() -replace '\s+',' '))
        Assert-True "hybrid (child proc): inline CUSTOM computes under scriptblock::Create"    $custOk ("child said: " + ($childOut.Trim() -replace '\s+',' '))
    } catch {
        Assert-True "hybrid-scope child harness ran" $false ("harness error: {0}" -f $_.Exception.Message)
    }
}

# ----------------------------------------------------------------------------
# PARITY: drilljig.cmd must NOT define any function that lives in drilljig_core.ps1.
# If it does, the shared-engine architecture is broken (a copy drifted back in), and
# the GUI will silently diverge. This is the guardrail the user requested (2026-06-26).
# ----------------------------------------------------------------------------
Write-Host "  -- parity: drilljig.cmd does not re-define shared-engine functions --" -ForegroundColor White
try {
    $djText = Get-Content -Raw (Join-Path $root 'drilljig.cmd')
    $djT=$null; $djE=$null
    $djAst = [System.Management.Automation.Language.Parser]::ParseInput($djText, [ref]$djT, [ref]$djE)
    $djFns = @($djAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })

    $coreText = Get-Content -Raw (Join-Path $libDir 'drilljig_core.ps1')
    $coreT=$null; $coreE=$null
    $coreAst = [System.Management.Automation.Language.Parser]::ParseInput($coreText, [ref]$coreT, [ref]$coreE)
    $coreFns = @($coreAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })

    $drifted = @($djFns | Where-Object { $coreFns -contains $_ })
    Assert-True "parity: drilljig.cmd does NOT re-define any drilljig_core function (0 drift)" ($drifted.Count -eq 0) ("drifted: {0}" -f ($drifted -join ', '))

    # slotinator.cmd must no longer DEFINE the slot primitives moved to the lib
    # (Build-CutFinishMacro / Invoke-VerifiedSeedCut) - it uses the lib copies.
    $slText = Get-Content -Raw (Join-Path $root 'slotinator.cmd')
    $slT=$null; $slE=$null
    $slAst = [System.Management.Automation.Language.Parser]::ParseInput($slText, [ref]$slT, [ref]$slE)
    $slFns = @($slAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
    Assert-True "parity: slotinator.cmd does NOT re-define Build-CutFinishMacro" (-not ($slFns -contains 'Build-CutFinishMacro'))
    Assert-True "parity: slotinator.cmd does NOT re-define Invoke-VerifiedSeedCut" (-not ($slFns -contains 'Invoke-VerifiedSeedCut'))
    Assert-True "parity: slotinator.cmd uses the lib Build-SlotPatternMacro" ($slText -match 'Build-SlotPatternMacro -DirDatumId')
} catch {
    Assert-True "parity harness ran" $false ("harness error: {0}" -f $_.Exception.Message)
}

# ----------------------------------------------------------------------------
# core: New-SlotGuidePlanes -- creates + shows the slot-edge guide planes (the 2+
# planes slotinator makes). COM-heavy, so stub New-OffsetPlane + the core session
# scope; assert pattern-mode (first row only) creates FEWER than all-rows. Placed
# last so the New-OffsetPlane stub doesn't shadow earlier tests.
# ----------------------------------------------------------------------------
Write-Host "  -- core: New-SlotGuidePlanes --" -ForegroundColor White
function New-OffsetPlane { param($Label,$Offset,$BaseId) $script:gpN++; return @{ FeatId = (3000 + $script:gpN); Symbol = "g$($script:gpN)" } }
$gpStubS = [pscustomobject]@{}; Add-Member -InputObject $gpStubS -MemberType ScriptMethod -Name RunMacro -Value { param($x) }
$gpStubM = [pscustomobject]@{}; Add-Member -InputObject $gpStubM -MemberType ScriptMethod -Name Regenerate -Value { param($x) }
Set-Variable -Name DJSession -Scope Script -Value $gpStubS
Set-Variable -Name DJModel   -Scope Script -Value $gpStubM
$gpGeo = Get-OrthogridGeometry -CcX 2.0 -CcZ 2.0 -Nx 3 -Nz 3 -Edge 2.0 -ClearDia 0.75
$gpSl  = Get-RowSlots -Points $gpGeo.Points -SlotWidth 0.75 -Width $gpGeo.Width -Height $gpGeo.Height -RowAxis 'X'
$script:gpN = 0; $gpPat = New-SlotGuidePlanes -Rows $gpSl.Rows -TopBaseId 10 -FrontBaseId 11 -UsePattern
$script:gpN = 0; $gpAll = New-SlotGuidePlanes -Rows $gpSl.Rows -TopBaseId 10 -FrontBaseId 11
Assert-True "guides: pattern mode creates >=1 plane"        (@($gpPat.Ids).Count -ge 1)
Assert-True "guides: all-rows creates more than first-row"  (@($gpAll.Ids).Count -gt @($gpPat.Ids).Count)
Assert-True "guides: no TOP/FRONT base -> no planes, no throw" (@((New-SlotGuidePlanes -Rows $gpSl.Rows -TopBaseId 0 -FrontBaseId 0).Ids).Count -eq 0)
Assert-True "guides: empty rows -> no planes, no throw"     (@((New-SlotGuidePlanes -Rows @() -TopBaseId 10 -FrontBaseId 11).Ids).Count -eq 0)

# ----------------------------------------------------------------------------
Write-Host ""
Write-Host ("  RESULT: {0} passed, {1} failed." -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
Write-Host ""
exit ([int]($script:fail -gt 0))
