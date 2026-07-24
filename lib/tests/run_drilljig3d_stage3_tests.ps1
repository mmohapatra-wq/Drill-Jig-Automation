# ============================================================================
# lib\tests\run_drilljig3d_stage3_tests.ps1 - offline smoke of drilljig3d STAGE 3
# ============================================================================
# drilljig3d.cmd STAGE 3 (curved chip-relief slots) is console glue that CANNOT
# run headless (it drives Creo). This suite verifies the OFFLINE-checkable parts of
# that wiring so a regression is caught without Creo:
#   1. Every lib drilljig3d STAGE 2/3 dot-sources loads + its key functions resolve
#      (jig_tree, curved_jig, curved_slots, tangent_plane, curved_slot_macros).
#   2. The STAGE-3 per-hole slot-planner input contract: the {Id;PlaneId;RowKey}
#      records drilljig3d builds from drilled holes feed Get-CurvedSlotPlan into a
#      valid per-hole plan, holes WITHOUT a tangent plane (PlaneId 0) are warned +
#      would be SKIPPED (never silently cut on the wrong plane), and Test-CurvedSlotPlan
#      gates it.
#   3. The Invoke-CurvedSlotPlanRun driver, with stubbed COM + injected Draw/Verify
#      prompts (exactly as drilljig3d wires them), cuts the planned seeds, skips the
#      no-plane hole, and never claims success on a canary miss -- so the drilljig3d
#      callback contract (& DrawPrompt $seed / & VerifyPrompt $seed $flip) is correct.
#
# Run:  powershell -ExecutionPolicy Bypass -File lib\tests\run_drilljig3d_stage3_tests.ps1
# Exit 0 = all pass.
# ============================================================================

$ErrorActionPreference = "Stop"
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir  = Split-Path -Parent $here

# dot-source the same chain drilljig3d.cmd loads for STAGE 2/3 (guard optional deps).
foreach ($dep in @('creo_geometry.ps1','orthogrid.ps1','orthogrid_points.ps1','drilljig_core.ps1','jig_tree.ps1','curved_jig.ps1','curved_slots.ps1','tangent_plane.ps1','curved_slot_macros.ps1')) {
    $p = Join-Path $libDir $dep
    if (Test-Path $p) { try { . $p } catch {} }
}

$script:pass = 0; $script:fail = 0
function Assert-True { param([string]$Name, [bool]$Cond, [string]$Detail = "")
    if ($Cond) { Write-Host "  [PASS] $Name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  [FAIL] $Name  $Detail" -ForegroundColor Red; $script:fail++ }
}
function Get-Field { param($Obj, [string]$Name) if ($null -eq $Obj) { return $null } try { return $Obj.$Name } catch { return $null } }

Write-Host ""
Write-Host "  -- drilljig3d STAGE 2/3: all dot-sourced functions resolve --" -ForegroundColor White
foreach ($fn in @('Invoke-Walk','Get-BoreAngularity','Get-CurvedSlotPlan','Test-CurvedSlotPlan',
                  'Build-TangentPlaneMacro','Invoke-TangentPlane','Build-CurvedSlotArmMacro',
                  'Invoke-CurvedSlotArm','Invoke-CurvedSlotCut','Invoke-CurvedSlotPlanRun',
                  'Build-CutFinishMacro','Initialize-DrilljigCore')) {
    Assert-True "resolves: $fn" ($null -ne (Get-Command $fn -ErrorAction SilentlyContinue))
}

# ----------------------------------------------------------------------------
# STAGE-3 planner input contract: drilljig3d builds one {Id;PlaneId;RowKey} record
# per drilled hole (PlaneId = the hole's captured TangentPlaneId, 0 if none).
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "  -- STAGE-3 planner input contract --" -ForegroundColor White
# 3 holes with tangent planes, 1 without (drilled without --tangent-orient / a miss)
$slotHoles = @(
    [pscustomobject]@{ Id = 101; PlaneId = 5001; RowKey = $null },
    [pscustomobject]@{ Id = 102; PlaneId = 5002; RowKey = $null },
    [pscustomobject]@{ Id = 103; PlaneId = 5003; RowKey = $null },
    [pscustomobject]@{ Id = 104; PlaneId = 0;    RowKey = $null }
)
$plan = Get-CurvedSlotPlan -Holes $slotHoles -SlotWidth 0.25 -Mode 'per-hole'
Assert-True "plan: Valid"                         ([bool](Get-Field $plan 'Valid'))
Assert-True "plan: 4 seeds (one per hole)"        ((Get-Field $plan 'Count') -eq 4)
Assert-True "plan: per-hole mode"                 ((Get-Field $plan 'Mode') -eq 'per-hole')
# the no-plane hole (104) produced a warning (it will be SKIPPED, not silently cut)
$warns = @(Get-Field $plan 'Warnings')
Assert-True "plan: a warning for the no-plane hole" (@($warns | Where-Object { $_ -match '104' }).Count -ge 1)
$gate = Test-CurvedSlotPlan -Plan $plan
Assert-True "plan: Test-CurvedSlotPlan Ok (armable)" ([bool](Get-Field $gate 'Ok'))
# the 3 planed seeds carry their SketchPlaneId
$seeds = @(Get-Field $plan 'Seeds')
$s0 = $seeds | Where-Object { $_.HoleIds -contains 101 } | Select-Object -First 1
Assert-True "plan: seed for hole 101 hosts plane 5001" ((Get-Field $s0 'SketchPlaneId') -eq 5001)

# ----------------------------------------------------------------------------
# Invoke-CurvedSlotPlanRun with stubbed COM + injected prompts (drilljig3d's wiring).
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "  -- STAGE-3 driver: Invoke-CurvedSlotPlanRun (stubbed COM + injected prompts) --" -ForegroundColor White

# stubbed session/model in the core scope (mirrors run_curved_slot_macros_tests.ps1).
$script:s3Stamp = 'v0'; $script:s3Feats = @(1); $script:s3Fired = @(); $script:s3Seed = 0
$s3Sess = New-Object psobject
Add-Member -InputObject $s3Sess -MemberType ScriptMethod -Name RunMacro -Value {
    param($x); $script:s3Fired += ,([string]$x)
    if ("$x" -match 'remove_material_cb') { $script:s3Seed++; $script:s3Feats = @(1) + (2..(1+$script:s3Seed)); $script:s3Stamp = "v$($script:s3Seed)" }
}
$s3Model = New-Object psobject
Add-Member -InputObject $s3Model -MemberType ScriptProperty -Name VersionStamp -Value { $script:s3Stamp }
Add-Member -InputObject $s3Model -MemberType ScriptMethod -Name ListItems -Value { param($t) $script:s3Feats | ForEach-Object { $o = New-Object psobject; Add-Member -InputObject $o -MemberType NoteProperty -Name Id -Value $_; $o } }
$s3Type = New-Object psobject; Add-Member -InputObject $s3Type -MemberType NoteProperty -Name ITEM_FEATURE -Value 999
Set-Variable -Name DJSession -Scope Script -Value $s3Sess
Set-Variable -Name DJModel   -Scope Script -Value $s3Model
Set-Variable -Name DJType    -Scope Script -Value $s3Type
# deterministic canary: a cut always advances the stamp (see RunMacro), so the real
# Wait-ModelModified returns quickly. But keep a fast shadow to avoid the 30s spin.
function Wait-ModelModified { param($Model=$null,[string]$PreviousStamp,[int]$TimeoutMs=30000,[scriptblock]$OnPoll=$null)
    if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }
    return ([string]$script:s3Stamp -ne [string]$PreviousStamp)
}

# injected prompts EXACTLY as drilljig3d wires them: DrawPrompt($seed), VerifyPrompt($seed,$flip)
$drawCalls = 0
$drawCb   = { param($seed) $script:drawCalls++ }
$verifyCb = { param($seed, $flip) return $true }   # direction correct on the first cut

$res = Invoke-CurvedSlotPlanRun -Plan $plan -Depth 0.25 -BodyIndex 0 -DrawPrompt $drawCb -VerifyPrompt $verifyCb -OnPoll { }
Assert-True "run: cut the 3 planed seeds"          ((Get-Field $res 'SeedsCut') -eq 3)
Assert-True "run: skipped the 1 no-plane seed"     ((Get-Field $res 'SeedsSkipped') -eq 1)
Assert-True "run: 0 failed (clean canaries)"       ((Get-Field $res 'SeedsFailed') -eq 0)
Assert-True "run: DrawPrompt called once per cut seed" ($drawCalls -eq 3)
Assert-True "run: a skip warning was recorded"     (@(Get-Field $res 'Warnings').Count -ge 1)

# canary MISS: a cut that never advances the stamp must NOT be counted as cut.
$script:s3Stamp = 'stuck'; $script:s3Fired = @()
Add-Member -InputObject $s3Sess -MemberType ScriptMethod -Name RunMacro -Force -Value { param($x) $script:s3Fired += ,([string]$x) }  # never changes the stamp
$planMiss = Get-CurvedSlotPlan -Holes @([pscustomobject]@{ Id = 201; PlaneId = 6001; RowKey = $null }) -SlotWidth 0.25 -Mode 'per-hole'
$resMiss = Invoke-CurvedSlotPlanRun -Plan $planMiss -Depth 0.25 -BodyIndex 0 -DrawPrompt $drawCb -VerifyPrompt $verifyCb -OnPoll { }
Assert-True "run(miss): 0 cut on a canary miss"    ((Get-Field $resMiss 'SeedsCut') -eq 0)
Assert-True "run(miss): >=1 failed (honest)"       ((Get-Field $resMiss 'SeedsFailed') -ge 1)

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ("  drilljig3d STAGE-3 wiring tests: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
Write-Host "  ============================================" -ForegroundColor Cyan
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
