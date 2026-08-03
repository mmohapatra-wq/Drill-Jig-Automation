# ============================================================================
# lib\tests\run_curved_slot_macros_tests.ps1 - offline unit tests for
# lib\curved_slot_macros.ps1
# ============================================================================
# Runs WITHOUT Creo and WITHOUT network. Exercises the CURVED (conformal) drill
# jig's chip-relief SLOT macro layer - the thin Creo-facing shell that turns a
# Get-CurvedSlotPlan (lib\curved_slots.ps1) into ARMED seed sketches + cut
# features, one per hole (or per shared-plane row). It is the curved analog of
# the flat jig's Invoke-VerifiedSeedCut / Build-CutFinishMacro (drilljig_core.ps1)
# but WITHOUT a linear pattern: on a curved panel every bore normal differs, so a
# single pattern will NOT replicate one seed to arbitrary curved positions - each
# seed is cut individually, canary-gated (mirrors the drilljig-gui slot-b PER-ROW
# fallback). The seed sketch is armed on that hole's TANGENT plane (or the datum
# plane it was intersected through) fed BY ID (sketch-open-on-plane-by-id, proven
# live 2026-07-24, slotplane-probe.cmd) - no screen pick.
#
# PIECES UNDER TEST (the published curved slot-macros contract):
#   * Build-CurvedSlotArmMacro -SketchPlaneId  -> the PURE atomic macro STRING that
#     selects the sketch plane BY ID (datum-by-id) then opens the sketcher on it
#     (ProCmdDatumSketCurve + t1.PlnMru/t1.RefMru + stdbtn_1) and arms the corner
#     rectangle (ProCmdSketSlantRectangle). No screen pick.
#   * Invoke-CurvedSlotArm -SketchPlaneId  -> COM: fire the arm macro. A plane id
#     <= 0 means "no usable plane" (fall back to a screen pick) -> Armed=$false and
#     NOTHING is fired; a positive id -> Armed=$true (the macro fired).
#   * Invoke-CurvedSlotCut -Depth -BodyIndex -Flip  -> COM: fire Build-CutFinishMacro
#     (the proven, surface-agnostic remove-material cut), canary-gate on a
#     VersionStamp change, and (on a change) resolve the NEW feature id by a
#     before/after ITEM_FEATURE diff. No change -> Changed=$false, no FeatId claimed
#     ([[feedback_canary_must_not_assume_on_failure]]).
#   * Invoke-CurvedSlotPlanRun -Plan  -> the loop: for each seed, arm + (draw pause)
#     + cut + (verify). A seed with no usable SketchPlaneId is SKIPPED (SeedsSkipped++,
#     a Warning) not cut; a canary miss increments SeedsFailed and never claims
#     success; the FIRST seed's 'wrong' verify flips the direction and retries, and
#     the confirmed flip is reused for the rest (direction verified ONCE).
#
# STUBBING (mirrors lib\tests\run_wizard_tests.ps1's `isp` block + the
# New-SlotGuidePlanes block): the COM helpers read $script:DJSession/DJModel/DJType
# set by Initialize-DrilljigCore. We Set-Variable those to lightweight PSCustomObject
# stubs (RunMacro captures the fired macro; a mutable VersionStamp ScriptProperty +
# a ListItems that returns fake feature objects drive the canary + feature-diff).
# DrawPrompt / VerifyPrompt are injected scriptblocks so the loop runs headless with
# no Read-Host.
#
# HARD REPO RULES honored: pure math NEVER throws (bad input -> a result object, not
# an exception); no Creo, no network, no IpfcPoint.Point. Modeled EXACTLY on
# lib\tests\run_curved_slots_tests.ps1 (Assert-True/Approx/Get-Field helpers,
# dot-source pattern, pass/fail counter, exit 0 on all-pass / 1 on any failure).
#
# Run:  powershell -ExecutionPolicy Bypass -File lib\tests\run_curved_slot_macros_tests.ps1
# Exit code 0 = all passed, 1 = at least one failure.
# ============================================================================

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here
# curved_slot_macros.ps1 is the Creo-facing shell over the PURE curved_slots.ps1
# planner + the shared drilljig_core.ps1 engine (Build-CutFinishMacro,
# Get-SelectDatumByIdMacro, Wait-ModelModified, Get-FeatureIdSet, Initialize-
# DrilljigCore). Dot-source the dependencies FIRST so they are in scope regardless
# of the lib's internal load order. drilljig_core needs creo_geometry + the
# orthogrid_points macro fragments in scope too; guard each optional dependency so
# a load hiccup on one never wedges the suite.
foreach ($dep in @('creo_geometry.ps1', 'orthogrid.ps1', 'orthogrid_points.ps1', 'drilljig_core.ps1', 'curved_slots.ps1')) {
    $p = Join-Path $libDir $dep
    if (Test-Path $p) { try { . $p } catch {} }
}
. (Join-Path $libDir 'curved_slot_macros.ps1')

$script:pass = 0
$script:fail = 0

function Assert-True {
    param([string]$Name, [bool]$Cond, [string]$Detail = "")
    if ($Cond) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  [FAIL] $Name $Detail" -ForegroundColor Red
        $script:fail++
    }
}

function Approx {
    param([double]$A, [double]$B, [double]$Tol = 1e-9)
    return [Math]::Abs($A - $B) -le $Tol
}

# Tolerant field getter: returns the value of the FIRST field that exists on
# $obj from the candidate name list, or $null if none. Contract-named fields are
# asserted directly; this survives a reasonable naming choice for anything the
# contract leaves slightly ambiguous.
#
# The curved slot-macros lib returns its results as HASHTABLES (@{ Armed=..;
# Changed=..; SeedsCut=.. }), whose keys are NOT surfaced through
# $Obj.PSObject.Properties (that only exposes Count/Keys/Values for a hashtable).
# So read fields the way the sibling suite (run_drilljig3d_stage3_tests.ps1) does:
# dynamic member access ($Obj.$n), which resolves BOTH hashtable keys AND
# PSCustomObject/NoteProperty members. Fall back to PSObject.Properties only for a
# member whose name is not directly addressable.
function Get-Field {
    param($Obj, [string[]]$Names)
    if ($null -eq $Obj) { return $null }
    foreach ($n in $Names) {
        # hashtable key -> containsKey; PSCustomObject/NoteProperty -> dynamic access
        if (($Obj -is [System.Collections.IDictionary]) -and $Obj.Contains($n)) { return $Obj[$n] }
        $prop = $Obj.PSObject.Properties[$n]
        if ($null -ne $prop) { return $prop.Value }
        try { $v = $Obj.$n; if ($null -ne $v) { return $v } } catch {}
    }
    return $null
}

# Count members robustly (a single object is count 1, $null is 0).
function Count-Of {
    param($X)
    if ($null -eq $X) { return 0 }
    return (@($X) | Measure-Object).Count
}

# ----------------------------------------------------------------------------
# STUB COM SCOPE. Build lightweight PSCustomObject stubs and Set-Variable them into
# the drilljig_core $script scope (exactly what Initialize-DrilljigCore does, minus
# the real COM). A mutable VersionStamp lets a test flip "did the model change?"; a
# ListItems that returns fake feature objects (each with an .Id) drives Get-
# FeatureIdSet's before/after diff for the new-feature id resolution.
#
# $script:cslmFired  - captures every RunMacro string fired.
# $script:cslmStamp  - the current VersionStamp value (a test bumps it to signal a
#                      change; leaving it puts the canary in "no change" state).
# $script:cslmFeats  - the current ITEM_FEATURE id list (a test appends a new id to
#                      simulate a cut creating a feature).
# ----------------------------------------------------------------------------
$script:cslmFired = @()
$script:cslmStamp = 'v0'
$script:cslmFeats = @(1, 2, 3)

$cslmSession = [pscustomobject]@{}
Add-Member -InputObject $cslmSession -MemberType ScriptMethod -Name RunMacro -Value {
    param($x) $script:cslmFired += ,([string]$x)
}

$cslmModel = [pscustomobject]@{}
Add-Member -InputObject $cslmModel -MemberType ScriptProperty -Name VersionStamp -Value { $script:cslmStamp }
Add-Member -InputObject $cslmModel -MemberType ScriptMethod -Name ListItems -Value {
    param($t)
    # return one fake feature object per current id (Get-FeatureIdSet reads .Id)
    return @($script:cslmFeats | ForEach-Object { [pscustomobject]@{ Id = [int]$_ } })
}
Add-Member -InputObject $cslmModel -MemberType ScriptMethod -Name Regenerate -Value { param($x) }

# a Type stub carrying only ITEM_FEATURE (all Get-FeatureIdSet needs here)
$cslmType = [pscustomobject]@{ ITEM_FEATURE = 999 }

Set-Variable -Name DJSession -Scope Script -Value $cslmSession
Set-Variable -Name DJModel   -Scope Script -Value $cslmModel
Set-Variable -Name DJType    -Scope Script -Value $cslmType

# The cut path also calls Wait-ModelModified (VersionStamp poll) - the real one
# spins for TimeoutMs. Keep it but pass a tiny timeout; because the stub model's
# VersionStamp reflects $script:cslmStamp, a test can make the poll return quickly
# by bumping the stamp before the call, or return $false by leaving it. To keep the
# no-change case FAST we also override Wait-ModelModified with a stub that reports
# whether the stamp differs from the PreviousStamp it was handed - deterministic and
# instant. Placed after any drilljig_core-dependent tests would need the real one
# (there are none in this file).
$script:cslmWaitForced = $null   # $null = derive from stamp; $true/$false = force
function Wait-ModelModified {
    param($Model = $null, [string]$PreviousStamp, [int]$TimeoutMs = 30000, [scriptblock]$OnPoll = $null)
    if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }
    if ($null -ne $script:cslmWaitForced) { return [bool]$script:cslmWaitForced }
    return ([string]$script:cslmStamp -ne [string]$PreviousStamp)
}

Write-Host ""
Write-Host "  Running curved-slot-macros unit tests (offline, stubbed COM)..." -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# Build-CurvedSlotArmMacro  --  PURE macro string
# ============================================================================
Write-Host "  -- Build-CurvedSlotArmMacro (pure macro string) --" -ForegroundColor White

$armMacro = Build-CurvedSlotArmMacro -SketchPlaneId 5002
Assert-True "arm-macro: returns a non-empty string" (($armMacro -is [string]) -and ($armMacro.Length -gt 0))
# the proven sketch-open tokens (CLAUDE.md "Open sketcher on a plane (confirmed)")
Assert-True "arm-macro: opens the sketcher (ProCmdDatumSketCurve)" ($armMacro -match 'ProCmdDatumSketCurve')
Assert-True "arm-macro: selects the plane from the MRU (t1.PlnMru)"  ($armMacro -match 't1\.PlnMru')
Assert-True "arm-macro: enters the sketcher (stdbtn_1)"              ($armMacro -match 'stdbtn_1')
# arms the SLANTED rectangle for the operator to draw the seed slot
Assert-True "arm-macro: arms the slanted rectangle (ProCmdSketSlantRectangle)" ($armMacro -match 'ProCmdSketSlantRectangle')
# routes the plane id through the datum-by-ID tree search (surfenator feed)
Assert-True "arm-macro: routes plane via the tree-search select" ($armMacro -match 'ProCmdMdlTreeSearch')
Assert-True "arm-macro: feeds the plane id 5002 into the InputIDPanel" ($armMacro -match 'InputIDPanel.*5002')
Assert-True "arm-macro: selects a Datum-type reference" ($armMacro -match 'Datum')

# a different id lands in the macro (the id is really threaded, not hard-coded)
$armMacro2 = Build-CurvedSlotArmMacro -SketchPlaneId 7777
Assert-True "arm-macro: a different plane id (7777) appears" ($armMacro2 -match 'InputIDPanel.*7777')
Assert-True "arm-macro: 5002 is NOT in the 7777 macro" (-not ($armMacro2 -match 'InputIDPanel.*5002'))

# ============================================================================
# Invoke-CurvedSlotArm  --  COM: fire the arm macro, gate on a usable plane id
# ============================================================================
Write-Host "  -- Invoke-CurvedSlotArm (gate on plane id) --" -ForegroundColor White

# Invoke-CurvedSlotArm takes a SEED object (a Get-CurvedSlotPlan seed carrying a
# .SketchPlaneId) - the SAME shape Invoke-CurvedSlotPlanRun feeds it. Build a minimal
# seed per case; the arm gates on the seed's .SketchPlaneId (<=0 => never fires).

# plane id 0 -> no usable plane -> Armed=$false, NOTHING fired
$script:cslmFired = @()
$armZero = Invoke-CurvedSlotArm -Seed ([pscustomobject]@{ SketchPlaneId = 0 })
Assert-True "arm: plane id 0 -> Armed false"        (-not [bool](Get-Field $armZero @('Armed')))
Assert-True "arm: plane id 0 -> nothing fired"      (@($script:cslmFired).Count -eq 0)

# negative plane id -> same (no usable plane)
$script:cslmFired = @()
$armNeg = Invoke-CurvedSlotArm -Seed ([pscustomobject]@{ SketchPlaneId = -5 })
Assert-True "arm: negative plane id -> Armed false" (-not [bool](Get-Field $armNeg @('Armed')))
Assert-True "arm: negative plane id -> nothing fired" (@($script:cslmFired).Count -eq 0)

# positive plane id -> Armed=$true, fires ONE arm macro carrying that id
$script:cslmFired = @()
$armOk = Invoke-CurvedSlotArm -Seed ([pscustomobject]@{ SketchPlaneId = 5003 })
Assert-True "arm: positive plane id -> Armed true"  ([bool](Get-Field $armOk @('Armed')))
Assert-True "arm: positive plane id -> fired exactly one macro" (@($script:cslmFired).Count -eq 1)
Assert-True "arm: fired macro opens the sketcher"   ($script:cslmFired[0] -match 'ProCmdDatumSketCurve')
Assert-True "arm: fired macro carries plane id 5003" ($script:cslmFired[0] -match 'InputIDPanel.*5003')
Assert-True "arm: fired macro arms the rectangle"   ($script:cslmFired[0] -match 'ProCmdSketSlantRectangle')

# never throws on a bad id
$threwArm = $false
try { $null = Invoke-CurvedSlotArm -Seed ([pscustomobject]@{ SketchPlaneId = 0 }) } catch { $threwArm = $true }
Assert-True "arm: bad id did NOT throw" (-not $threwArm)

# ============================================================================
# Invoke-CurvedSlotCut  --  COM: fire the cut, canary + feature-diff
# ============================================================================
Write-Host "  -- Invoke-CurvedSlotCut (cut + canary + feature-diff) --" -ForegroundColor White

# (a) NO CHANGE: the stamp does not move and no feature appears -> Changed=$false,
#     no FeatId claimed (a canary that cannot confirm a change is a MISS).
$script:cslmFired = @()
$script:cslmStamp = 'vNC'
$script:cslmFeats = @(1, 2, 3)
$script:cslmWaitForced = $false     # force the poll to report "no change"
$cutNC = Invoke-CurvedSlotCut -Depth 0.25 -BodyIndex 0 -Flip $true
Assert-True "cut: no-change -> Changed false"           (-not [bool](Get-Field $cutNC @('Changed')))
Assert-True "cut: no-change -> FeatId null/0 (no claim)" (($null -eq (Get-Field $cutNC @('FeatId'))) -or ([int](Get-Field $cutNC @('FeatId')) -le 0))
Assert-True "cut: no-change -> a cut macro still fired once" (@($script:cslmFired).Count -eq 1)
Assert-True "cut: fired macro is the remove-material cut"    ($script:cslmFired[0] -match 'remove_material_cb')
Assert-True "cut: fired macro finishes the sketch (ProCmdSketDone)" ($script:cslmFired[0] -match 'ProCmdSketDone')

# (b) CHANGE + a new feature appears -> Changed=$true + FeatId = the new id.
#     Simulate: before-diff sees @(1,2,3); the cut "creates" feature 42; the stamp
#     moves so the canary confirms. The lib's before-snapshot runs INSIDE the call,
#     so we arrange for ListItems to return the new set AFTER the macro fires by
#     appending inside the RunMacro stub.
$script:cslmFired = @()
$script:cslmStamp = 'vA'
$script:cslmFeats = @(1, 2, 3)
$script:cslmWaitForced = $null      # derive from the stamp (we bump it in RunMacro)
# a one-shot RunMacro that mutates the model state the way a real cut would: adds a
# new feature id AND advances the version stamp, so the before/after diff + the
# canary both see the change.
Add-Member -InputObject $cslmSession -MemberType ScriptMethod -Name RunMacro -Force -Value {
    param($x)
    $script:cslmFired += ,([string]$x)
    if ("$x" -match 'remove_material_cb') {
        $script:cslmFeats = @(1, 2, 3, 42)
        $script:cslmStamp = 'vA-changed'
    }
}
$cutOk = Invoke-CurvedSlotCut -Depth 0.25 -BodyIndex 0 -Flip $true
Assert-True "cut: change -> Changed true"          ([bool](Get-Field $cutOk @('Changed')))
Assert-True "cut: change -> FeatId == the new id 42" (([int](Get-Field $cutOk @('FeatId'))) -eq 42)
Assert-True "cut: change -> exactly one cut macro fired" (@($script:cslmFired).Count -eq 1)

# restore the plain capture-only RunMacro for later tests
Add-Member -InputObject $cslmSession -MemberType ScriptMethod -Name RunMacro -Force -Value {
    param($x) $script:cslmFired += ,([string]$x)
}
$script:cslmWaitForced = $null

# (c) the Flip flag threads into the cut macro (Build-CutFinishMacro -Flip).
$script:cslmFired = @(); $script:cslmStamp = 'vF'; $script:cslmFeats = @(1); $script:cslmWaitForced = $false
$null = Invoke-CurvedSlotCut -Depth 0.30 -BodyIndex 1 -Flip $true
Assert-True "cut: Flip=true -> macro contains the flip widget (flip_pb)" ($script:cslmFired[0] -match 'flip_pb')
$script:cslmFired = @(); $script:cslmStamp = 'vF2'; $script:cslmFeats = @(1); $script:cslmWaitForced = $false
$null = Invoke-CurvedSlotCut -Depth 0.30 -BodyIndex 1 -Flip $false
Assert-True "cut: Flip=false -> macro omits the flip widget" (-not ($script:cslmFired[0] -match 'flip_pb'))

# (d) never throws.
$threwCut = $false
try { $script:cslmWaitForced = $false; $null = Invoke-CurvedSlotCut -Depth 0.25 -BodyIndex 0 -Flip $true } catch { $threwCut = $true }
Assert-True "cut: did NOT throw" (-not $threwCut)

# ============================================================================
# Invoke-CurvedSlotPlanRun  --  the per-seed loop (arm + draw + cut + verify)
# ============================================================================
Write-Host "  -- Invoke-CurvedSlotPlanRun (per-seed loop) --" -ForegroundColor White

# Build a real 3-seed per-hole plan (each hole has its own usable plane).
$run3holes = @(
    @{ Id = 801; Pos = @(0,0,0);   Axis = @(0,0,1);      RowKey = 'R0'; SketchPlaneId = 8001 },
    @{ Id = 802; Pos = @(2,0,0.1); Axis = @(0.1,0,0.99); RowKey = 'R0'; SketchPlaneId = 8002 },
    @{ Id = 803; Pos = @(4,0,0.3); Axis = @(0.2,0,0.98); RowKey = 'R1'; SketchPlaneId = 8003 }
)
$run3plan = Get-CurvedSlotPlan -Holes $run3holes -SlotWidth 0.375
Assert-True "planrun fixture: 3-seed plan is valid" ([bool](Get-Field $run3plan @('Valid')) -and ((Count-Of (Get-Field $run3plan @('Seeds'))) -eq 3))

# stubbed prompts: DrawPrompt is the "operator drew the rectangle, press ENTER"
# pause (no-op headless); VerifyPrompt returns whether the FIRST cut looked correct.
$drawPrompt = { param($SeedInfo) }                 # headless: just proceed
$verifyGood = { param($SeedInfo) return $true }    # every cut confirmed correct

# a RunMacro that makes EVERY cut "succeed" (advance the stamp + add a feature) so
# the canary passes for each seed. Each cut adds a distinct feature id.
$script:cslmSeedCounter = 0
Add-Member -InputObject $cslmSession -MemberType ScriptMethod -Name RunMacro -Force -Value {
    param($x)
    $script:cslmFired += ,([string]$x)
    if ("$x" -match 'remove_material_cb') {
        $script:cslmSeedCounter++
        $script:cslmFeats += (9000 + $script:cslmSeedCounter)
        $script:cslmStamp  = ("vrun{0}" -f $script:cslmSeedCounter)
    }
}

# (a) ALL 3 seeds cut cleanly.
$script:cslmFired = @(); $script:cslmFeats = @(1); $script:cslmStamp = 'vrun0'; $script:cslmSeedCounter = 0; $script:cslmWaitForced = $null
$runAll = Invoke-CurvedSlotPlanRun -Plan $run3plan -Depth 0.25 -BodyIndex 0 -Flip $true -DrawPrompt $drawPrompt -VerifyPrompt $verifyGood
Assert-True "planrun all-ok: returned an object" ($null -ne $runAll)
Assert-True "planrun all-ok: SeedsCut == 3"      (([int](Get-Field $runAll @('SeedsCut'))) -eq 3)
Assert-True "planrun all-ok: SeedsSkipped == 0"  (([int](Get-Field $runAll @('SeedsSkipped'))) -eq 0)
Assert-True "planrun all-ok: SeedsFailed == 0"   (([int](Get-Field $runAll @('SeedsFailed'))) -eq 0)
# 3 seeds -> 3 arm macros + 3 cut macros = 6 fired (no verify-flip retries here)
Assert-True "planrun all-ok: fired 3 arm + 3 cut macros" ((@($script:cslmFired | Where-Object { $_ -match 'ProCmdSketSlantRectangle' }).Count -eq 3) -and (@($script:cslmFired | Where-Object { $_ -match 'remove_material_cb' }).Count -eq 3))

# (b) a seed with NO usable plane (SketchPlaneId <= 0) is SKIPPED, not cut, and
#     recorded as a Warning; the other two still cut.
$runGapHoles = @(
    @{ Id = 811; Pos = @(0,0,0); Axis = @(0,0,1); RowKey = 'R0'; SketchPlaneId = 8101 },
    @{ Id = 812; Pos = @(2,0,0); Axis = @(0,0,1); RowKey = 'R0'; SketchPlaneId = 0 },     # no plane
    @{ Id = 813; Pos = @(4,0,0); Axis = @(0,0,1); RowKey = 'R1'; SketchPlaneId = 8103 }
)
$runGapPlan = Get-CurvedSlotPlan -Holes $runGapHoles -SlotWidth 0.375
$script:cslmFired = @(); $script:cslmFeats = @(1); $script:cslmStamp = 'vgap0'; $script:cslmSeedCounter = 0; $script:cslmWaitForced = $null
$runGap = Invoke-CurvedSlotPlanRun -Plan $runGapPlan -Depth 0.25 -BodyIndex 0 -Flip $true -DrawPrompt $drawPrompt -VerifyPrompt $verifyGood
Assert-True "planrun gap: SeedsCut == 2 (the two good holes)" (([int](Get-Field $runGap @('SeedsCut'))) -eq 2)
Assert-True "planrun gap: SeedsSkipped == 1 (the no-plane hole)" (([int](Get-Field $runGap @('SeedsSkipped'))) -eq 1)
$runGapWarn = Get-Field $runGap @('Warnings')
Assert-True "planrun gap: a Warning was recorded for the skip" ((Count-Of $runGapWarn) -ge 1)
# the skipped seed did NOT arm/cut: only 2 arm macros + 2 cuts fired
Assert-True "planrun gap: only 2 seeds armed (skip did not arm)" (@($script:cslmFired | Where-Object { $_ -match 'ProCmdSketSlantRectangle' }).Count -eq 2)
Assert-True "planrun gap: only 2 cuts fired (skip did not cut)"  (@($script:cslmFired | Where-Object { $_ -match 'remove_material_cb' }).Count -eq 2)

# (c) a CANARY MISS (a cut that does not change the model) increments SeedsFailed
#     and does NOT count as SeedsCut. Force Wait-ModelModified to $false so EVERY
#     canary reports no-change.
$script:cslmFired = @(); $script:cslmFeats = @(1); $script:cslmStamp = 'vmiss0'; $script:cslmSeedCounter = 0
$script:cslmWaitForced = $false
# also stop the RunMacro from advancing the stamp so the before/after are identical
Add-Member -InputObject $cslmSession -MemberType ScriptMethod -Name RunMacro -Force -Value {
    param($x) $script:cslmFired += ,([string]$x)   # capture only; no model mutation
}
$runMiss = Invoke-CurvedSlotPlanRun -Plan $run3plan -Depth 0.25 -BodyIndex 0 -Flip $true -DrawPrompt $drawPrompt -VerifyPrompt $verifyGood
Assert-True "planrun canary-miss: SeedsCut == 0 (no cut confirmed)" (([int](Get-Field $runMiss @('SeedsCut'))) -eq 0)
Assert-True "planrun canary-miss: SeedsFailed >= 1"                 (([int](Get-Field $runMiss @('SeedsFailed'))) -ge 1)
Assert-True "planrun canary-miss: never claims success"            (-not [bool](Get-Field $runMiss @('AllCut')))

# restore the succeed-on-cut RunMacro for the verify-flip test
$script:cslmWaitForced = $null
Add-Member -InputObject $cslmSession -MemberType ScriptMethod -Name RunMacro -Force -Value {
    param($x)
    $script:cslmFired += ,([string]$x)
    if ("$x" -match 'remove_material_cb') {
        $script:cslmSeedCounter++
        $script:cslmFeats += (9500 + $script:cslmSeedCounter)
        $script:cslmStamp  = ("vflip{0}" -f $script:cslmSeedCounter)
    }
}

# (d) the FIRST seed's VerifyPrompt 'wrong' path flips the direction and retries.
#     A verify prompt that returns $false the FIRST time then $true afterwards. The
#     first seed is cut (canary ok) but rejected -> undo + flip + re-cut; the flip
#     is then reused. We assert: the first seed produced TWO cut attempts (original
#     + retry), an undo fired, and the flip DIRECTION toggled between them.
$script:cslmFired = @(); $script:cslmFeats = @(1); $script:cslmStamp = 'vflip0'; $script:cslmSeedCounter = 0; $script:cslmWaitForced = $null
$script:cslmVerifyCalls = 0
$verifyFirstWrong = {
    param($SeedInfo)
    $script:cslmVerifyCalls++
    # reject only the very first verify; accept every one after
    return ($script:cslmVerifyCalls -ne 1)
}
$runFlip = Invoke-CurvedSlotPlanRun -Plan $run3plan -Depth 0.25 -BodyIndex 0 -Flip $false -DrawPrompt $drawPrompt -VerifyPrompt $verifyFirstWrong
Assert-True "planrun verify-flip: returned an object" ($null -ne $runFlip)
# an Undo was fired to remove the rejected first cut
Assert-True "planrun verify-flip: an Undo fired for the rejected cut" (@($script:cslmFired | Where-Object { $_ -match 'ProCmdEditUndo' }).Count -ge 1)
# the first seed was cut TWICE (original + flipped retry); total cuts = 4 (seed1 x2 + seed2 + seed3)
$cutCount = @($script:cslmFired | Where-Object { $_ -match 'remove_material_cb' }).Count
Assert-True "planrun verify-flip: first seed retried (>=1 extra cut fired, total $cutCount)" ($cutCount -ge 4)
# the retry TOGGLED the flip: one cut macro has the flip widget and one does not
#   (Flip started $false; the reject flips it to $true for the retry)
$withFlip = @($script:cslmFired | Where-Object { ($_ -match 'remove_material_cb') -and ($_ -match 'flip_pb') }).Count
$noFlip   = @($script:cslmFired | Where-Object { ($_ -match 'remove_material_cb') -and (-not ($_ -match 'flip_pb')) }).Count
Assert-True "planrun verify-flip: direction toggled (both a flipped and a non-flipped cut fired)" (($withFlip -ge 1) -and ($noFlip -ge 1))
# all 3 seeds ultimately confirmed
Assert-True "planrun verify-flip: SeedsCut == 3 after the retry" (([int](Get-Field $runFlip @('SeedsCut'))) -eq 3)

# (e) bad-input contract: a null / invalid plan never throws.
$threwRun = $false; $runNull = $null
try { $runNull = Invoke-CurvedSlotPlanRun -Plan $null -Depth 0.25 -BodyIndex 0 -Flip $true -DrawPrompt $drawPrompt -VerifyPrompt $verifyGood } catch { $threwRun = $true }
Assert-True "planrun null plan: did NOT throw"        (-not $threwRun)
Assert-True "planrun null plan: returned an object"   ($null -ne $runNull)
Assert-True "planrun null plan: SeedsCut == 0"        (($null -eq $runNull) -or (([int](Get-Field $runNull @('SeedsCut'))) -eq 0))

# an invalid plan (Valid=false, no seeds) runs nothing and cuts nothing.
$script:cslmFired = @()
$badPlan = Get-CurvedSlotPlan -Holes @() -SlotWidth 0.25   # Valid=false
$runBad = Invoke-CurvedSlotPlanRun -Plan $badPlan -Depth 0.25 -BodyIndex 0 -Flip $true -DrawPrompt $drawPrompt -VerifyPrompt $verifyGood
Assert-True "planrun invalid plan: SeedsCut == 0" (([int](Get-Field $runBad @('SeedsCut'))) -eq 0)
Assert-True "planrun invalid plan: nothing fired" (@($script:cslmFired).Count -eq 0)

# ============================================================================
# SUMMARY
# ============================================================================
Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ("  curved-slot-macros tests: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { "Green" } else { "Red" })
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ""
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
