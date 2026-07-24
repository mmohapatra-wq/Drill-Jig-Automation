# ============================================================================
# lib\tests\run_curved_slots_tests.ps1 - offline unit tests for lib\curved_slots.ps1
# ============================================================================
# Runs WITHOUT Creo and WITHOUT network. Exercises the PURE per-hole slot-plane
# planner for the CURVED (conformal) drill jig - the curved analog of the flat
# jig's Get-RowSlots/Get-SlotSeedPatterns. On a curved face per-hole bore normals
# differ, so a single linear pattern cannot replicate one seed slot; instead each
# hole (or each shared-plane row) gets its OWN seed sketch armed BY ID on the
# datum plane already created for that hole's 3-plane intersection point.
#
#   * Get-CurvedSlotPlan     - hole list -> one seed per hole ('per-hole', the MVP
#     default) or one seed per RowKey group ('per-row'). Each seed carries the
#     SketchPlaneId the caller arms the slot sketch on. A hole with no usable
#     SketchPlaneId (0/null) is a Warning (caller screen-picks) NOT a plan failure.
#   * Group-CurvedHolesByRow - pure row grouping by RowKey string-equality, or (no
#     RowKey) by a projected coordinate within a PHYSICAL -Tol (never 1e-6, like
#     Get-RowSlots). Feeds per-row mode.
#   * Test-CurvedSlotPlan     - cheap deterministic sanity gate over a plan result:
#     >=1 seed, every seed has >=1 hole, and each seed has a SketchPlaneId OR a
#     recorded Warning.
#
# Written to the PUBLISHED CONTRACT (curved slot-planner task); field names below
# are the exact contract names both the lib and these tests must use:
#   Get-CurvedSlotPlan  -> Valid; Errors; Mode; Seeds=@({Key;HoleIds;SketchPlaneId;
#                          SlotWidth;Members}); Count; Warnings
#   Group-CurvedHolesByRow -> Valid; Errors; Rows=@({Key;HoleIds;Members})
#   Test-CurvedSlotPlan -> Ok; Issues
#
# HARD REPO RULES honored here: pure math NEVER throws (Valid=$false + Errors on
# bad input); no Creo, no network, no IpfcPoint.Point. Modeled EXACTLY on
# lib\tests\run_curved_tests.ps1 (Assert-True/Approx/Get-Field helpers, dot-source
# pattern, pass/fail counter, exit 0 on all-pass / 1 on any failure).
#
# Run:  powershell -ExecutionPolicy Bypass -File lib\tests\run_curved_slots_tests.ps1
# Exit code 0 = all passed, 1 = at least one failure.
# ============================================================================

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here
# curved_slots.ps1 is PURE (no COM). It may reuse the vec/tol helpers already in
# curved_jig.ps1 / orthogrid.ps1 for its physical row grouping; dot-source those
# dependencies FIRST so they are in scope regardless of the lib's internal load
# order. Load errors on an optional dependency are non-fatal (the lib is meant to
# be independently testable), so guard each.
foreach ($dep in @('orthogrid.ps1', 'curved_jig.ps1')) {
    $p = Join-Path $libDir $dep
    if (Test-Path $p) { try { . $p } catch {} }
}
. (Join-Path $libDir 'curved_slots.ps1')

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

# Tolerant field getter: returns the value of the FIRST property that exists on
# $obj from the candidate name list, or $null if none. Contract-named fields are
# asserted directly; this survives a reasonable naming choice for anything the
# contract leaves slightly ambiguous.
function Get-Field {
    param($Obj, [string[]]$Names)
    if ($null -eq $Obj) { return $null }
    foreach ($n in $Names) {
        $prop = $Obj.PSObject.Properties[$n]
        if ($null -ne $prop) { return $prop.Value }
    }
    return $null
}

# Count members robustly (a single object is count 1, $null is 0).
function Count-Of {
    param($X)
    if ($null -eq $X) { return 0 }
    return (@($X) | Measure-Object).Count
}

# Find the seed in a plan whose HoleIds contains $id (or $null).
function Find-SeedByHoleId {
    param($Plan, $Id)
    $seeds = Get-Field $Plan @('Seeds')
    if ($null -eq $seeds) { return $null }
    foreach ($s in @($seeds)) {
        $hids = Get-Field $s @('HoleIds')
        if ($null -eq $hids) { continue }
        foreach ($h in @($hids)) { if ("$h" -eq "$Id") { return $s } }
    }
    return $null
}

Write-Host ""
Write-Host "  Running curved-slots unit tests (offline)..." -ForegroundColor Cyan
Write-Host ""

# ----------------------------------------------------------------------------
# Shared fixtures.
#   A 2x2-ish curved layout: two rows (RowKey R0 / R1), two holes each. Every
#   hole carries a distinct SketchPlaneId (the datum plane its slot sketch is
#   armed on by ID). Positions/axes are carried through (not required for the
#   pure plan math, but the lib should pass them through as Members).
# ----------------------------------------------------------------------------
$holes4 = @(
    @{ Id = 101; Pos = @(0,0,0);   Axis = @(0,0,1);        RowKey = 'R0'; SketchPlaneId = 5001 },
    @{ Id = 102; Pos = @(2,0,0.1); Axis = @(0.1,0,0.99);   RowKey = 'R0'; SketchPlaneId = 5002 },
    @{ Id = 103; Pos = @(0,3,0.4); Axis = @(0,0.2,0.98);   RowKey = 'R1'; SketchPlaneId = 5003 },
    @{ Id = 104; Pos = @(2,3,0.5); Axis = @(0.2,0.2,0.96); RowKey = 'R1'; SketchPlaneId = 5004 }
)

# ============================================================================
# Get-CurvedSlotPlan  --  'per-hole' (default MVP) mode
# ============================================================================
Write-Host "  -- Get-CurvedSlotPlan (per-hole) --" -ForegroundColor White

$planPH = Get-CurvedSlotPlan -Holes $holes4 -SlotWidth 0.375
Assert-True "per-hole: Valid" ([bool](Get-Field $planPH @('Valid')))
Assert-True "per-hole: Mode == 'per-hole' (default)" ((Get-Field $planPH @('Mode')) -eq 'per-hole')

$seedsPH = Get-Field $planPH @('Seeds')
Assert-True "per-hole: Seeds present" ($null -ne $seedsPH)
Assert-True "per-hole: one seed PER HOLE (4)" ((Count-Of $seedsPH) -eq 4)
Assert-True "per-hole: Count == hole count (4)" (([int](Get-Field $planPH @('Count'))) -eq 4)
Assert-True "per-hole: Warnings present + empty (all planes usable)" ((Count-Of (Get-Field $planPH @('Warnings'))) -eq 0)
Assert-True "per-hole: Errors present + empty" ((Count-Of (Get-Field $planPH @('Errors'))) -eq 0)

# each seed carries exactly its own hole's SketchPlaneId + SlotWidth + one HoleId.
$sHole = Find-SeedByHoleId $planPH 102
Assert-True "per-hole: seed for hole 102 found" ($null -ne $sHole)
if ($null -ne $sHole) {
    Assert-True "per-hole: seed 102 SketchPlaneId == 5002" (([int](Get-Field $sHole @('SketchPlaneId'))) -eq 5002)
    Assert-True "per-hole: seed 102 SlotWidth == 0.375" (Approx ([double](Get-Field $sHole @('SlotWidth'))) 0.375 1e-9)
    Assert-True "per-hole: seed 102 HoleIds == just [102]" ((Count-Of (Get-Field $sHole @('HoleIds'))) -eq 1)
    Assert-True "per-hole: seed 102 has a Key" ($null -ne (Get-Field $sHole @('Key')))
    Assert-True "per-hole: seed 102 has Members" ($null -ne (Get-Field $sHole @('Members')))
}

# every input hole id appears in exactly one seed.
$allIds = @(101,102,103,104)
$covered = $true
foreach ($id in $allIds) { if ($null -eq (Find-SeedByHoleId $planPH $id)) { $covered = $false } }
Assert-True "per-hole: every hole id is covered by a seed" $covered

# distinct planes across the per-hole seeds (no accidental collapse).
$distinctPlanes = @($seedsPH | ForEach-Object { Get-Field $_ @('SketchPlaneId') } | Sort-Object -Unique)
Assert-True "per-hole: 4 distinct SketchPlaneIds" ((Count-Of $distinctPlanes) -eq 4)

# explicit -Mode 'per-hole' behaves identically to the default.
$planPHx = Get-CurvedSlotPlan -Holes $holes4 -SlotWidth 0.375 -Mode 'per-hole'
Assert-True "per-hole (explicit): Mode == 'per-hole'" ((Get-Field $planPHx @('Mode')) -eq 'per-hole')
Assert-True "per-hole (explicit): 4 seeds" ((Count-Of (Get-Field $planPHx @('Seeds'))) -eq 4)

# ============================================================================
# Get-CurvedSlotPlan  --  'per-row' mode
# ============================================================================
Write-Host "  -- Get-CurvedSlotPlan (per-row) --" -ForegroundColor White

$planPR = Get-CurvedSlotPlan -Holes $holes4 -SlotWidth 0.375 -Mode 'per-row'
Assert-True "per-row: Valid" ([bool](Get-Field $planPR @('Valid')))
Assert-True "per-row: Mode == 'per-row'" ((Get-Field $planPR @('Mode')) -eq 'per-row')

$seedsPR = Get-Field $planPR @('Seeds')
Assert-True "per-row: one seed PER ROW (2)" ((Count-Of $seedsPR) -eq 2)
Assert-True "per-row: Count == seed count (2)" (([int](Get-Field $planPR @('Count'))) -eq 2)

# each row-seed's HoleIds = the whole row (2 holes); SketchPlaneId = the row's
# shared plane (the first row member's plane per contract).
$sR0 = Find-SeedByHoleId $planPR 101
Assert-True "per-row: seed containing hole 101 found" ($null -ne $sR0)
if ($null -ne $sR0) {
    $r0ids = @(Get-Field $sR0 @('HoleIds'))
    Assert-True "per-row: R0 seed has BOTH row-0 holes (101 & 102)" (($r0ids -contains 101) -and ($r0ids -contains 102))
    Assert-True "per-row: R0 seed HoleIds count == 2" ((Count-Of $r0ids) -eq 2)
    # shared plane = one of the row members' plane ids (5001 or 5002).
    $r0plane = [int](Get-Field $sR0 @('SketchPlaneId'))
    Assert-True "per-row: R0 seed SketchPlaneId is a row member's plane" (($r0plane -eq 5001) -or ($r0plane -eq 5002))
}
$sR1 = Find-SeedByHoleId $planPR 103
Assert-True "per-row: seed containing hole 103 found" ($null -ne $sR1)
if ($null -ne $sR1) {
    $r1ids = @(Get-Field $sR1 @('HoleIds'))
    Assert-True "per-row: R1 seed has BOTH row-1 holes (103 & 104)" (($r1ids -contains 103) -and ($r1ids -contains 104))
}

# per-row still covers every hole id.
$coveredPR = $true
foreach ($id in $allIds) { if ($null -eq (Find-SeedByHoleId $planPR $id)) { $coveredPR = $false } }
Assert-True "per-row: every hole id is covered" $coveredPR

# ============================================================================
# Get-CurvedSlotPlan  --  SketchPlaneId 0/null => Warning, NOT invalid
# ============================================================================
Write-Host "  -- Get-CurvedSlotPlan (missing plane => warning) --" -ForegroundColor White

$holesGap = @(
    @{ Id = 201; Pos = @(0,0,0); Axis = @(0,0,1); RowKey = 'R0'; SketchPlaneId = 6001 },
    @{ Id = 202; Pos = @(2,0,0); Axis = @(0,0,1); RowKey = 'R0'; SketchPlaneId = 0 },      # no usable plane
    @{ Id = 203; Pos = @(4,0,0); Axis = @(0,0,1); RowKey = 'R0' }                          # SketchPlaneId absent -> null
)
$planGap = Get-CurvedSlotPlan -Holes $holesGap -SlotWidth 0.25
Assert-True "missing-plane: still Valid (a missing plane is non-fatal)" ([bool](Get-Field $planGap @('Valid')))
Assert-True "missing-plane: still one seed per hole (3)" ((Count-Of (Get-Field $planGap @('Seeds'))) -eq 3)
$warnGap = Get-Field $planGap @('Warnings')
Assert-True "missing-plane: Warnings present" ($null -ne $warnGap)
Assert-True "missing-plane: >=2 warnings (the 0 and the null plane)" ((Count-Of $warnGap) -ge 2)

# the seed for the good hole still has its plane; the seeds for the bad holes are
# present but flag the missing plane (SketchPlaneId 0/null) so the caller falls
# back to a screen pick for those two.
$sGood = Find-SeedByHoleId $planGap 201
Assert-True "missing-plane: good hole 201 keeps plane 6001" (($null -ne $sGood) -and ([int](Get-Field $sGood @('SketchPlaneId')) -eq 6001))
$sBad0 = Find-SeedByHoleId $planGap 202
Assert-True "missing-plane: hole 202 still has a seed" ($null -ne $sBad0)
if ($null -ne $sBad0) {
    $bp = Get-Field $sBad0 @('SketchPlaneId')
    Assert-True "missing-plane: hole 202 seed plane is 0/null (needs screen pick)" (($null -eq $bp) -or ([int]$bp -eq 0))
}

# ============================================================================
# Get-CurvedSlotPlan  --  bad-input contract (NEVER throws)
# ============================================================================
Write-Host "  -- Get-CurvedSlotPlan (bad input never throws) --" -ForegroundColor White

# null Holes
$threwNull = $false; $planNull = $null
try { $planNull = Get-CurvedSlotPlan -Holes $null -SlotWidth 0.25 } catch { $threwNull = $true }
Assert-True "null Holes: did NOT throw" (-not $threwNull)
Assert-True "null Holes: returned an object" ($null -ne $planNull)
Assert-True "null Holes: Valid=false" (($null -ne $planNull) -and (-not [bool](Get-Field $planNull @('Valid'))))
Assert-True "null Holes: Errors populated" ((Count-Of (Get-Field $planNull @('Errors'))) -ge 1)

# empty Holes
$threwEmpty = $false; $planE = $null
try { $planE = Get-CurvedSlotPlan -Holes @() -SlotWidth 0.25 } catch { $threwEmpty = $true }
Assert-True "empty Holes: did NOT throw" (-not $threwEmpty)
Assert-True "empty Holes: returned an object" ($null -ne $planE)
Assert-True "empty Holes: Valid=false" (($null -ne $planE) -and (-not [bool](Get-Field $planE @('Valid'))))

# malformed holes ($null entry mixed in) - still plans the good ones, no throw.
$holesMal = @(
    @{ Id = 301; Pos = @(0,0,0); Axis = @(0,0,1); RowKey = 'R0'; SketchPlaneId = 7001 },
    $null,
    @{ Id = 302; Pos = @(2,0,0); Axis = @(0,0,1); RowKey = 'R0'; SketchPlaneId = 7002 }
)
$threwMal = $false; $planMal = $null
try { $planMal = Get-CurvedSlotPlan -Holes $holesMal -SlotWidth 0.25 } catch { $threwMal = $true }
Assert-True "malformed Holes: did NOT throw" (-not $threwMal)
Assert-True "malformed Holes: returned an object" ($null -ne $planMal)
if ($null -ne $planMal) {
    # the good holes are still covered (a null entry does not wedge the plan).
    Assert-True "malformed Holes: good hole 301 covered" ($null -ne (Find-SeedByHoleId $planMal 301))
    Assert-True "malformed Holes: good hole 302 covered" ($null -ne (Find-SeedByHoleId $planMal 302))
}

# unknown -Mode: no throw (degrades sensibly, e.g. to the default per-hole).
$threwMode = $false; $planMode = $null
try { $planMode = Get-CurvedSlotPlan -Holes $holes4 -SlotWidth 0.25 -Mode 'bogus' } catch { $threwMode = $true }
Assert-True "bogus Mode: did NOT throw" (-not $threwMode)
Assert-True "bogus Mode: returned an object" ($null -ne $planMode)

# ============================================================================
# Group-CurvedHolesByRow
# ============================================================================
Write-Host "  -- Group-CurvedHolesByRow --" -ForegroundColor White

# (a) group by RowKey string-equality.
$gk = Group-CurvedHolesByRow -Holes $holes4
Assert-True "group-by-key: Valid" ([bool](Get-Field $gk @('Valid')))
$gkRows = Get-Field $gk @('Rows')
Assert-True "group-by-key: Rows present" ($null -ne $gkRows)
Assert-True "group-by-key: 2 rows (R0/R1)" ((Count-Of $gkRows) -eq 2)
Assert-True "group-by-key: Errors present + empty" ((Count-Of (Get-Field $gk @('Errors'))) -eq 0)

# each row has a Key, its HoleIds, and Members.
$foundR0 = $false; $foundR1 = $false
foreach ($row in @($gkRows)) {
    $k = Get-Field $row @('Key')
    $hids = @(Get-Field $row @('HoleIds'))
    Assert-True ("group-by-key: row '$k' has 2 holes") ((Count-Of $hids) -eq 2)
    Assert-True ("group-by-key: row '$k' has Members") ($null -ne (Get-Field $row @('Members')))
    if ("$k" -eq 'R0') { $foundR0 = $true; Assert-True "group-by-key: R0 = {101,102}" (($hids -contains 101) -and ($hids -contains 102)) }
    if ("$k" -eq 'R1') { $foundR1 = $true; Assert-True "group-by-key: R1 = {103,104}" (($hids -contains 103) -and ($hids -contains 104)) }
}
Assert-True "group-by-key: both RowKeys present" ($foundR0 -and $foundR1)

# (b) NO RowKey -> group by projected coordinate within a PHYSICAL -Tol.
#   two holes near Z=0, two near Z=3; a physical tol (default ~SlotWidth/4 floored
#   at 0.01, NEVER 1e-6) chains the near-equal ones into one row. The 0.02 z-jitter
#   inside each cluster is WELL under the physical tol -> two rows, not four.
$holesNoKey = @(
    @{ Id = 401; Pos = @(0,0,0);    Axis = @(0,0,1) },
    @{ Id = 402; Pos = @(2,0,0.02); Axis = @(0,0,1) },
    @{ Id = 403; Pos = @(0,0,3.00); Axis = @(0,0,1) },
    @{ Id = 404; Pos = @(2,0,3.02); Axis = @(0,0,1) }
)
$gc = Group-CurvedHolesByRow -Holes $holesNoKey -Tol 0.25
Assert-True "group-by-coord: Valid" ([bool](Get-Field $gc @('Valid')))
$gcRows = Get-Field $gc @('Rows')
Assert-True "group-by-coord: 2 rows from a physical tol" ((Count-Of $gcRows) -eq 2)

# a tiny (but > physical-floor) tol still keeps each cluster together, and the two
# clusters (Z ~ 0 vs Z ~ 3) stay separate.
$rowSizes = @($gcRows | ForEach-Object { Count-Of (Get-Field $_ @('HoleIds')) } | Sort-Object)
Assert-True "group-by-coord: each row has 2 holes" (($rowSizes.Count -eq 2) -and ($rowSizes[0] -eq 2) -and ($rowSizes[1] -eq 2))

# default tol (no -Tol) must NOT be 1e-6 - the 0.02 intra-cluster jitter must not
# fragment a cluster into singletons (the silent-over-cut trap Get-RowSlots warns
# against). Provide a SlotWidth so the auto physical tol (~SlotWidth/4) is ample.
$gcDefault = Group-CurvedHolesByRow -Holes $holesNoKey -SlotWidth 0.5
Assert-True "group-by-coord (default tol): Valid" ([bool](Get-Field $gcDefault @('Valid')))
Assert-True "group-by-coord (default tol): still 2 rows (physical tol, not 1e-6)" ((Count-Of (Get-Field $gcDefault @('Rows'))) -eq 2)

# (c) bad input never throws.
$threwGN = $false; $gN = $null
try { $gN = Group-CurvedHolesByRow -Holes $null } catch { $threwGN = $true }
Assert-True "group null Holes: did NOT throw" (-not $threwGN)
Assert-True "group null Holes: returned an object" ($null -ne $gN)
Assert-True "group null Holes: Valid=false" (($null -ne $gN) -and (-not [bool](Get-Field $gN @('Valid'))))
Assert-True "group null Holes: Errors populated" ((Count-Of (Get-Field $gN @('Errors'))) -ge 1)

$threwGE = $false; $gE = $null
try { $gE = Group-CurvedHolesByRow -Holes @() } catch { $threwGE = $true }
Assert-True "group empty Holes: did NOT throw" (-not $threwGE)
Assert-True "group empty Holes: Valid=false" (($null -ne $gE) -and (-not [bool](Get-Field $gE @('Valid'))))

# malformed entry mixed in - no throw, groups the good ones.
$threwGM = $false; $gM = $null
try { $gM = Group-CurvedHolesByRow -Holes @( @{ Id=501; Pos=@(0,0,0); RowKey='R0' }, $null, @{ Id=502; Pos=@(1,0,0); RowKey='R0' } ) } catch { $threwGM = $true }
Assert-True "group malformed Holes: did NOT throw" (-not $threwGM)
Assert-True "group malformed Holes: returned an object" ($null -ne $gM)

# ============================================================================
# Test-CurvedSlotPlan
# ============================================================================
Write-Host "  -- Test-CurvedSlotPlan --" -ForegroundColor White

# (a) a good per-hole plan passes the gate cleanly.
$tGood = Test-CurvedSlotPlan -Plan $planPH
Assert-True "gate good plan: Ok=true" ([bool](Get-Field $tGood @('Ok')))
Assert-True "gate good plan: Issues present + empty" ((Count-Of (Get-Field $tGood @('Issues'))) -eq 0)

# (b) a plan with a missing-plane hole still PASSES the gate because the missing
#   plane was RECORDED as a Warning (the caller knows to screen-pick that seed).
$tGap = Test-CurvedSlotPlan -Plan $planGap
Assert-True "gate warned plan: Ok=true (warning recorded => still gate-ok)" ([bool](Get-Field $tGap @('Ok')))

# (c) an invalid plan (no seeds) fails the gate.
$tNull = Test-CurvedSlotPlan -Plan $planNull
Assert-True "gate invalid plan: Ok=false" (-not [bool](Get-Field $tNull @('Ok')))
Assert-True "gate invalid plan: Issues populated" ((Count-Of (Get-Field $tNull @('Issues'))) -ge 1)

# (d) a hand-built plan with an EMPTY-holeId seed AND no warning fails the gate
#   (a seed must have >=1 hole).
$emptySeedPlan = [pscustomobject]@{
    Valid    = $true
    Errors   = @()
    Mode     = 'per-hole'
    Seeds    = @( [pscustomobject]@{ Key='k0'; HoleIds=@(); SketchPlaneId=9001; SlotWidth=0.25; Members=@() } )
    Count    = 1
    Warnings = @()
}
$tEmptySeed = Test-CurvedSlotPlan -Plan $emptySeedPlan
Assert-True "gate empty-holeid seed: Ok=false" (-not [bool](Get-Field $tEmptySeed @('Ok')))

# (e) a plan whose only seed has NO plane AND NO warning fails the gate (the
#   caller would have no way to know it must screen-pick).
$noPlaneNoWarnPlan = [pscustomobject]@{
    Valid    = $true
    Errors   = @()
    Mode     = 'per-hole'
    Seeds    = @( [pscustomobject]@{ Key='k0'; HoleIds=@(101); SketchPlaneId=0; SlotWidth=0.25; Members=@() } )
    Count    = 1
    Warnings = @()
}
$tNoPlane = Test-CurvedSlotPlan -Plan $noPlaneNoWarnPlan
Assert-True "gate no-plane/no-warning seed: Ok=false" (-not [bool](Get-Field $tNoPlane @('Ok')))

# (f) gate NEVER throws on null / garbage.
$threwGate = $false; $tBad = $null
try { $tBad = Test-CurvedSlotPlan -Plan $null } catch { $threwGate = $true }
Assert-True "gate null plan: did NOT throw" (-not $threwGate)
Assert-True "gate null plan: returned an object" ($null -ne $tBad)
Assert-True "gate null plan: Ok=false" (($null -ne $tBad) -and (-not [bool](Get-Field $tBad @('Ok'))))

# ============================================================================
# SUMMARY
# ============================================================================
Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ("  curved-slots tests: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { "Green" } else { "Red" })
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ""
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
