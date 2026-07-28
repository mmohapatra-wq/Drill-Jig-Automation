# ============================================================================
# lib\tests\run_curved_relief_tests.ps1 - offline unit tests for lib\curved_relief.ps1
# ============================================================================
# curved_relief.ps1 is the TOP-plane SYMMETRIC chip-relief engine for the curved
# drill jig: two PURE macro builders (Build-CurvedReliefArmMacro /
# Build-CurvedReliefCutMacro) + one COM driver (Invoke-FastenerRelief). The pure
# builders are asserted directly (token presence + order + the 2x-relief depth
# doubling). The driver is exercised against a FAKE session/model + stubbed
# Select-ComponentPlaneById / Get-FeatureIdSet / Wait-ModelModified (the same
# fake-COM approach as fuzz_curved_gui.ps1) so its canary/fallback control flow is
# covered without Creo.
#
# Run:  powershell -ExecutionPolicy Bypass -File lib\tests\run_curved_relief_tests.ps1
# Exit 0 = all pass.
# ============================================================================

$ErrorActionPreference = "Stop"
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here

$script:pass = 0; $script:fail = 0
function Assert-True { param([string]$Name, [bool]$Cond, [string]$Detail = "")
    if ($Cond) { Write-Host "  [PASS] $Name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  [FAIL] $Name  $Detail" -ForegroundColor Red; $script:fail++ }
}

# ----------------------------------------------------------------------------
# Dependencies. curved_relief.ps1 calls Get-FeatureIdSet / Wait-ModelModified
# (drilljig_core, non-global) + Select-ComponentPlaneById / Get-ComSelectFactory
# (curved_fastener_hole). For the pure-builder tests we only need the builders; for
# the driver tests we STUB the COM-touching helpers as globals (so the driver's
# calls resolve to canned returns). Dot-source drilljig_core + curved_fastener_hole
# first so their real (non-stubbed) helpers exist, then override the COM ones.
# ----------------------------------------------------------------------------
foreach ($dep in @('creo_geometry.ps1','orthogrid.ps1','orthogrid_points.ps1','drilljig_core.ps1','conformal_blank.ps1','curved_fastener_hole.ps1')) {
    $p = Join-Path $libDir $dep
    if (Test-Path $p) { try { . $p } catch {} }
}
. (Join-Path $libDir 'curved_relief.ps1')

# ============================================================================
# 1. Build-CurvedReliefArmMacro (PURE) - the sketch-on-plane open.
# ============================================================================
Write-Host ""
Write-Host "  -- Build-CurvedReliefArmMacro (pure) --" -ForegroundColor White
$arm = Build-CurvedReliefArmMacro
Assert-True "arm: opens ProCmdFtExtrude"        ($arm -match 'ProCmdFtExtrude')
Assert-True "arm: orients ProCmdViewSketchView" ($arm -match 'ProCmdViewSketchView')
Assert-True "arm: arms ProCmdSketRectangle"     ($arm -match 'ProCmdSketRectangle')
# ORDER: extrude open BEFORE the view-orient BEFORE the rectangle tool (the recording order).
$iExt = $arm.IndexOf('ProCmdFtExtrude'); $iView = $arm.IndexOf('ProCmdViewSketchView'); $iRect = $arm.IndexOf('ProCmdSketRectangle')
Assert-True "arm: order = Extrude -> ViewSketchView -> Rectangle" (($iExt -lt $iView) -and ($iView -lt $iRect)) ("(ext=$iExt view=$iView rect=$iRect)")
# it must NOT select the plane itself (the DRIVER pre-selects it by raw-COM; the arm
# macro must not tree-search a plane -- a component TOP plane is not tree-reachable).
Assert-True "arm: does NOT tree-search for the plane" (-not ($arm -match 'ProCmdMdlTreeSearch')) "(arm must rely on the driver's pre-select)"

# ============================================================================
# 2. Build-CurvedReliefCutMacro (PURE) - the symmetric remove-material finish.
# ============================================================================
Write-Host ""
Write-Host "  -- Build-CurvedReliefCutMacro (pure) --" -ForegroundColor White
# The macro delimits widget names with single backticks; strip them so the
# assertions match plain "widget arg" substrings (a doubled-backtick pattern would
# never match the single-backtick rendered output).
$cut   = Build-CurvedReliefCutMacro -SymDepth 0.5 -BodyIndex 1
$cutNB = ($cut -replace '`','')
Assert-True "cut: finishes the sketch (ProCmdSketDone)"  ($cutNB -match 'ProCmdSketDone')
Assert-True "cut: opens the depth flyout"                ($cutNB -match 'maindashInst0\.depth_flyout')
Assert-True "cut: toggles Symmetric to 1"                ($cutNB -match 'maindashInst0\.Symmetric 1')
Assert-True "cut: types def_depth1_ip"                   ($cutNB -match 'maindashInst0\.def_depth1_ip')
Assert-True "cut: def_depth1_ip carries the SymDepth value 0.5" ($cutNB -match 'maindashInst0\.def_depth1_ip 0\.5')
Assert-True "cut: toggles remove_material_cb (a CUT)"    ($cutNB -match 'maindashInst0\.remove_material_cb 1')
Assert-True "cut: opens the body page"                   ($cutNB -match 'chkbn\.body_page\.0')
Assert-True "cut: selects the body index 1"              ($cutNB -match 'PH\.bodyselectrepwdg_list 1')
Assert-True "cut: commits with dashInst0.Done"           ($cutNB -match 'dashInst0\.Done')
# ORDER: SketDone -> Symmetric -> depth -> remove-material -> Done.
$iDone1 = $cutNB.IndexOf('ProCmdSketDone'); $iSym = $cutNB.IndexOf('Symmetric'); $iDepth = $cutNB.IndexOf('def_depth1_ip')
$iRem = $cutNB.IndexOf('remove_material_cb'); $iDone2 = $cutNB.LastIndexOf('dashInst0.Done')
Assert-True "cut: order SketDone<Symmetric<depth<removeMaterial<Done" `
    (($iDone1 -lt $iSym) -and ($iSym -lt $iDepth) -and ($iDepth -lt $iRem) -and ($iRem -lt $iDone2))
# NO flip_pb (symmetric removes the direction ambiguity -> no operator direction-verify).
Assert-True "cut: NO flip_pb (symmetric needs no direction flip)" (-not ($cutNB -match 'flip_pb'))
# SymDepth <= 0 emits NO depth tokens (Creo keeps its default).
$cut0 = ((Build-CurvedReliefCutMacro -SymDepth 0 -BodyIndex 0) -replace '`','')
Assert-True "cut: SymDepth<=0 emits no def_depth1_ip token" (-not ($cut0 -match 'def_depth1_ip')) "(no depth typed when <=0)"
Assert-True "cut: SymDepth<=0 still toggles Symmetric + cut" (($cut0 -match 'Symmetric') -and ($cut0 -match 'remove_material_cb'))
# body index threads through.
$cut3 = ((Build-CurvedReliefCutMacro -SymDepth 0.4 -BodyIndex 3) -replace '`','')
Assert-True "cut: body index 3 threads into the selector" ($cut3 -match 'PH\.bodyselectrepwdg_list 3')

# ============================================================================
# 3. Invoke-FastenerRelief (COM driver) - canary + doubling + fallback flow.
#    STUB the COM helpers as globals so the driver's calls resolve to canned data.
# ============================================================================
Write-Host ""
Write-Host "  -- Invoke-FastenerRelief (driver, stubbed COM) --" -ForegroundColor White

# a fake model whose VersionStamp bumps on each RunMacro, and a session that records
# the macros it fired (so we can assert the 2x-relief depth reached the cut macro).
$script:firedMacros = New-Object System.Collections.ArrayList
$fakeModel = [pscustomobject]@{ VersionStamp = 1 }
$fakeSession = [pscustomobject]@{}
$fakeSession | Add-Member ScriptMethod RunMacro { param($m) [void]$script:firedMacros.Add([string]$m); $script:cModel.VersionStamp = ([int]$script:cModel.VersionStamp + 1) } -Force
$script:cModel = $fakeModel

# stub the COM-touching helpers the driver calls (globals so they win over the reals).
$script:planeSelectOk = $true   # toggled per test to exercise the fallback
function global:Select-ComponentPlaneById { param($Session,$TypeObj,$ComponentPath,$PlaneId,$Role,[switch]$NoClear) if ($script:planeSelectOk) { @{ Ok=$true; Id=[int]$PlaneId; Reason='' } } else { @{ Ok=$false; Id=0; Reason='stub miss' } } }
# Get-FeatureIdSet grows with the VersionStamp so the before/after diff yields a new id.
function global:Get-FeatureIdSet { $set=@{}; $v=0; try { $v=[int]$script:cModel.VersionStamp } catch { $v=0 }; for ($i=1; $i -le $v; $i++) { $set[(1000+$i)]=$true }; return $set }
function global:Wait-ModelModified { param($Model,$PreviousStamp,$TimeoutMs=30000,$OnPoll=$null) if ($null -ne $OnPoll) { try { & $OnPoll } catch {} } return $true }

# 3a. happy path: plane pre-select OK -> Cut=$true, ViaPlane=$true, 2x depth in the cut macro.
# NOTE the prompt scriptblocks are PLAIN blocks (NOT .GetNewClosure()) so the driver's
# `& $DrawPrompt` runs them in the driver's scope and their $script: writes reach here.
$script:planeSelectOk = $true
$script:firedMacros.Clear()
$script:drawFired2 = $false
$r = Invoke-FastenerRelief -Session $fakeSession -Model $fakeModel -TypeObj $null -ComponentPath ([pscustomobject]@{}) -TopPlaneId 1 -ReliefDepth 0.25 -BodyIndex 1 -DrawPrompt { $script:drawFired2 = $true } -PlanePrompt { } -OnPoll { }
Assert-True "driver: happy path Cut=true"        ([bool]$r.Cut)
Assert-True "driver: happy path ViaPlane=true"   ([bool]$r.ViaPlane)
Assert-True "driver: fired the DrawPrompt"       ($script:drawFired2)
$cutFired = @($script:firedMacros | Where-Object { $_ -match 'remove_material_cb' })
Assert-True "driver: fired a remove-material cut macro" (@($cutFired).Count -ge 1)
$cutFiredNB = (@($cutFired) -join "`n") -replace '`',''
Assert-True "driver: doubled the relief (0.25 -> def_depth1_ip 0.5)" ($cutFiredNB -match 'def_depth1_ip 0\.5') "(2 x relief must reach the cut)"

# 3b. relief depth 0 -> immediate no-op (no cut, clear reason), no macros fired.
$script:firedMacros.Clear()
$r0 = Invoke-FastenerRelief -Session $fakeSession -Model $fakeModel -TypeObj $null -ComponentPath ([pscustomobject]@{}) -TopPlaneId 1 -ReliefDepth 0 -BodyIndex 1
Assert-True "driver: ReliefDepth<=0 -> Cut=false"     (-not [bool]$r0.Cut)
Assert-True "driver: ReliefDepth<=0 fires no macro"   (@($script:firedMacros).Count -eq 0)

# 3c. plane pre-select MISS -> the PlanePrompt fallback fires; the cut still runs.
$script:planeSelectOk = $false
$script:firedMacros.Clear()
$script:planeFired3 = $false
$r3 = Invoke-FastenerRelief -Session $fakeSession -Model $fakeModel -TypeObj $null -ComponentPath ([pscustomobject]@{}) -TopPlaneId 1 -ReliefDepth 0.3 -BodyIndex 0 -DrawPrompt { } -PlanePrompt { $script:planeFired3 = $true } -OnPoll { }
Assert-True "driver: plane miss fires the PlanePrompt fallback" ($script:planeFired3)
Assert-True "driver: plane miss -> ViaPlane=false"              (-not [bool]$r3.ViaPlane)
Assert-True "driver: plane miss still cuts (fallback pick)"     ([bool]$r3.Cut)

# 3d. canary: no model change -> Cut=false (never assume success). Stub Wait-ModelModified false.
function global:Wait-ModelModified { param($Model,$PreviousStamp,$TimeoutMs=30000,$OnPoll=$null) return $false }
$script:planeSelectOk = $true
$r4 = Invoke-FastenerRelief -Session $fakeSession -Model $fakeModel -TypeObj $null -ComponentPath ([pscustomobject]@{}) -TopPlaneId 1 -ReliefDepth 0.25 -BodyIndex 1 -DrawPrompt { } -PlanePrompt { } -OnPoll { }
Assert-True "driver: no VersionStamp move -> Cut=false (canary miss)" (-not [bool]$r4.Cut)
Assert-True "driver: canary-miss reason is set" ([string]$r4.Reason -ne '')

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ("  curved_relief tests: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
Write-Host "  ============================================" -ForegroundColor Cyan
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
