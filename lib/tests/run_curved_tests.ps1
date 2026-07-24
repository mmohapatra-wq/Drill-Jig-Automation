# ============================================================================
# lib\tests\run_curved_tests.ps1 - offline unit tests for lib\curved_jig.ps1
# ============================================================================
# Runs WITHOUT Creo and WITHOUT network. Exercises the pure per-hole angularity
# + curved-layout math for the conformal drill jig:
#   * Get-BoreAngularity  - direction cosines vs the OG csys axes, angle off the
#     nominal drilling axis (OG Z), spherical azimuth/polar. Degenerate guard.
#   * Get-CurvedHolePlan   - per-hole angularity records + a max-tilt summary +
#     a warn flag when a hole tilts beyond -MaxTiltDeg. Bad hole flagged, not fatal.
#   * Get-CurvedIndexExport - the curved analog of the flat Get-HolesRelativeToIndex:
#     express every hole in the 2-index-hole frame (index_frame.ps1) while keeping
#     the full 3D orientation. Matches the proven index_frame result on a flat case.
#
# Written to the PUBLISHED CONTRACT (wf_curved_phase1.js angularity-lib task):
#   Get-BoreAngularity     -> Valid; Errors; DirCosX; DirCosY; DirCosZ;
#                             AngleFromZDeg; AzimuthDeg; PolarDeg
#   Get-CurvedIndexExport   -> per-hole rows { X_index; Y_index; Z_index; DirCos*;
#                             AngleFromZDeg; IsIndex }
# Ambiguous field names (the plan's per-hole record + its summary) are probed
# tolerantly so a faithful impl passes regardless of exact naming choice.
#
# Run:  powershell -ExecutionPolicy Bypass -File lib\tests\run_curved_tests.ps1
# Exit code 0 = all passed, 1 = at least one failure.
# ============================================================================

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here
# curved_jig.ps1 reuses index_frame.ps1's frame math for Get-CurvedIndexExport;
# dot-source the dependency FIRST so it is in scope regardless of load order.
. (Join-Path $libDir 'index_frame.ps1')
. (Join-Path $libDir 'curved_jig.ps1')

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
# $obj from the candidate name list, or $null if none. Lets the tests survive a
# reasonable naming choice for the not-strictly-contracted fields (the plan's
# per-hole record + its summary), while contract-named fields are asserted directly.
function Get-Field {
    param($Obj, [string[]]$Names)
    if ($null -eq $Obj) { return $null }
    foreach ($n in $Names) {
        $p = $Obj.PSObject.Properties[$n]
        if ($null -ne $p) { return $p.Value }
    }
    return $null
}

function Has-Field {
    param($Obj, [string[]]$Names)
    return ($null -ne (Get-Field $Obj $Names)) -or ($null -ne $Obj -and ($Names | Where-Object { $Obj.PSObject.Properties[$_] } | Select-Object -First 1))
}

Write-Host ""
Write-Host "  Running curved-jig unit tests (offline)..." -ForegroundColor Cyan
Write-Host ""

$rad = [Math]::PI / 180.0
$cos45 = [Math]::Cos(45.0 * $rad)   # ~0.70710678

# ============================================================================
# Get-BoreAngularity
# ============================================================================
Write-Host "  -- Get-BoreAngularity --" -ForegroundColor White

# (1) exactly along +Z: angle off Z ~ 0, DirCosZ ~ 1, DirCosX/Y ~ 0.
$aZ = Get-BoreAngularity -Axis @(0,0,1)
Assert-True "along +Z: Valid" ($aZ.Valid)
Assert-True "along +Z: AngleFromZDeg ~ 0" (Approx $aZ.AngleFromZDeg 0.0 1e-6)
Assert-True "along +Z: DirCosZ ~ 1" (Approx $aZ.DirCosZ 1.0 1e-9)
Assert-True "along +Z: DirCosX ~ 0" (Approx $aZ.DirCosX 0.0 1e-9)
Assert-True "along +Z: DirCosY ~ 0" (Approx $aZ.DirCosY 0.0 1e-9)
# contract fields present
Assert-True "along +Z: AzimuthDeg present" ($null -ne $aZ.PSObject.Properties['AzimuthDeg'])
Assert-True "along +Z: PolarDeg present" ($null -ne $aZ.PSObject.Properties['PolarDeg'])
# polar angle (from +Z) equals the angle-off-Z here => ~0
Assert-True "along +Z: PolarDeg ~ 0" (Approx $aZ.PolarDeg 0.0 1e-6)

# (2) 45-degree tilt: axis in the X-Z plane at 45 deg from Z.
#   axis = (sin45, 0, cos45) => AngleFromZDeg ~ 45, DirCosZ ~ cos45, DirCosX ~ cos45.
$s45 = [Math]::Sin(45.0 * $rad)
$a45 = Get-BoreAngularity -Axis @($s45, 0, $cos45)
Assert-True "45-tilt: Valid" ($a45.Valid)
Assert-True "45-tilt: AngleFromZDeg ~ 45" (Approx $a45.AngleFromZDeg 45.0 1e-6)
Assert-True "45-tilt: DirCosZ ~ cos45" (Approx $a45.DirCosZ $cos45 1e-9)
Assert-True "45-tilt: DirCosX ~ cos45 (== sin from Z)" (Approx $a45.DirCosX $s45 1e-9)
Assert-True "45-tilt: DirCosY ~ 0" (Approx $a45.DirCosY 0.0 1e-9)
Assert-True "45-tilt: PolarDeg ~ 45" (Approx $a45.PolarDeg 45.0 1e-6)

# (3) horizontal axis (purely in XY): angle off Z ~ 90, DirCosZ ~ 0.
$aH = Get-BoreAngularity -Axis @(1,0,0)
Assert-True "horizontal +X: Valid" ($aH.Valid)
Assert-True "horizontal +X: AngleFromZDeg ~ 90" (Approx $aH.AngleFromZDeg 90.0 1e-6)
Assert-True "horizontal +X: DirCosZ ~ 0" (Approx $aH.DirCosZ 0.0 1e-9)
Assert-True "horizontal +X: DirCosX ~ 1" (Approx $aH.DirCosX 1.0 1e-9)
Assert-True "horizontal +X: PolarDeg ~ 90" (Approx $aH.PolarDeg 90.0 1e-6)
# azimuth of +X (in XY, measured from +X) ~ 0
Assert-True "horizontal +X: AzimuthDeg ~ 0" (Approx $aH.AzimuthDeg 0.0 1e-6)

# horizontal along +Y => azimuth ~ 90 (measured from +X toward +Y).
$aHy = Get-BoreAngularity -Axis @(0,1,0)
Assert-True "horizontal +Y: AngleFromZDeg ~ 90" (Approx $aHy.AngleFromZDeg 90.0 1e-6)
Assert-True "horizontal +Y: DirCosY ~ 1" (Approx $aHy.DirCosY 1.0 1e-9)
Assert-True "horizontal +Y: AzimuthDeg ~ 90" (Approx $aHy.AzimuthDeg 90.0 1e-6)

# (4) non-unit input normalized correctly: (0,0,5) behaves like +Z.
$aScaled = Get-BoreAngularity -Axis @(0,0,5)
Assert-True "non-unit (0,0,5): Valid" ($aScaled.Valid)
Assert-True "non-unit (0,0,5): DirCosZ ~ 1 (normalized)" (Approx $aScaled.DirCosZ 1.0 1e-9)
Assert-True "non-unit (0,0,5): AngleFromZDeg ~ 0" (Approx $aScaled.AngleFromZDeg 0.0 1e-6)

# scaled 45-tilt: (3,0,3) => still 45 deg off Z, direction cosines ~ cos45.
$aScaled45 = Get-BoreAngularity -Axis @(3,0,3)
Assert-True "non-unit (3,0,3): AngleFromZDeg ~ 45" (Approx $aScaled45.AngleFromZDeg 45.0 1e-6)
Assert-True "non-unit (3,0,3): DirCosZ ~ cos45" (Approx $aScaled45.DirCosZ $cos45 1e-9)
Assert-True "non-unit (3,0,3): DirCosX ~ cos45" (Approx $aScaled45.DirCosX $cos45 1e-9)

# (5) anti-parallel axis: -Z should read as angle-off-Z 0 IF the impl uses |dot|
#     for the drilling-axis angle (a bore read backwards is the same drill line).
#     The contract says "use |dot| where appropriate" - AngleFromZDeg is the
#     nominal-drilling-axis angle, so |dot| => ~0 for -Z.
$aNeg = Get-BoreAngularity -Axis @(0,0,-1)
Assert-True "anti-parallel -Z: Valid" ($aNeg.Valid)
Assert-True "anti-parallel -Z: AngleFromZDeg ~ 0 (|dot|)" (Approx $aNeg.AngleFromZDeg 0.0 1e-6)

# (6) degenerate / zero axis => Valid=$false, no throw.
$aZero = Get-BoreAngularity -Axis @(0,0,0)
Assert-True "zero axis: Valid=false (no throw)" (-not $aZero.Valid)
Assert-True "zero axis: Errors populated" ($aZero.Errors.Count -ge 1)

# malformed / null axis => Valid=$false, no throw.
$aNull = Get-BoreAngularity -Axis $null
Assert-True "null axis: Valid=false (no throw)" (-not $aNull.Valid)
$aShort = Get-BoreAngularity -Axis @(1,0)
Assert-True "short axis: Valid=false (no throw)" (-not $aShort.Valid)

# (7) custom OG csys axes: rotate the reference so that the world +X becomes the
#     nominal drilling axis (RefZ = +X). A bore along +X is then "on axis".
$aCustom = Get-BoreAngularity -Axis @(1,0,0) -RefX @(0,1,0) -RefY @(0,0,1) -RefZ @(1,0,0)
Assert-True "custom RefZ=+X: Valid" ($aCustom.Valid)
Assert-True "custom RefZ=+X: AngleFromZDeg ~ 0 (bore on RefZ)" (Approx $aCustom.AngleFromZDeg 0.0 1e-6)
Assert-True "custom RefZ=+X: DirCosZ ~ 1 (vs RefZ)" (Approx $aCustom.DirCosZ 1.0 1e-9)

# ============================================================================
# Get-CurvedHolePlan
# ============================================================================
Write-Host "  -- Get-CurvedHolePlan --" -ForegroundColor White

# N holes with varying tilts:
#   h0 straight +Z (0 deg), h1 tilted 45 deg, h2 tilted 10 deg.
$holes = @(
    @{ Pos = @(0,0,0);   Axis = @(0,0,1) },
    @{ Pos = @(2,0,0);   Axis = @($s45,0,$cos45) },
    @{ Pos = @(4,0,0);   Axis = @([Math]::Sin(10*$rad),0,[Math]::Cos(10*$rad)) }
)
$plan = Get-CurvedHolePlan -Holes $holes -MaxTiltDeg 20.0
Assert-True "plan: Valid" ($plan.Valid)

# Per-hole records - probe tolerantly for the collection field.
$rows = Get-Field $plan @('Holes','Rows','Records','Items','Plan')
Assert-True "plan: has a per-hole collection" ($null -ne $rows)
Assert-True "plan: 3 per-hole records" (($rows | Measure-Object).Count -eq 3)

if ($null -ne $rows -and ($rows | Measure-Object).Count -eq 3) {
    $r0 = $rows[0]; $r1 = $rows[1]; $r2 = $rows[2]

    # each record carries Pos + Axis (contract: "carrying Pos, Axis, and its Get-BoreAngularity result")
    $p0 = Get-Field $r0 @('Pos','Position')
    $x0 = Get-Field $r0 @('Axis','Dir','Direction')
    Assert-True "plan row0: Pos carried" ($null -ne $p0)
    Assert-True "plan row0: Axis carried" ($null -ne $x0)
    Assert-True "plan row0: Pos == (0,0,0)" (($null -ne $p0) -and (Approx ([double]$p0[0]) 0) -and (Approx ([double]$p0[1]) 0) -and (Approx ([double]$p0[2]) 0))

    # the Get-BoreAngularity result on each record (tolerant field name, or the
    # angularity fields flattened directly onto the row).
    $ang0 = Get-Field $r0 @('Angularity','Bore','Ang','BoreAngularity')
    $a1 = Get-Field $r1 @('Angularity','Bore','Ang','BoreAngularity')
    $a2 = Get-Field $r2 @('Angularity','Bore','Ang','BoreAngularity')

    # angle off nominal per hole - either on a nested angularity object OR flattened.
    $ang1Deg = if ($null -ne $a1) { Get-Field $a1 @('AngleFromZDeg') } else { Get-Field $r1 @('AngleFromZDeg') }
    $ang0Deg = if ($null -ne $ang0) { Get-Field $ang0 @('AngleFromZDeg') } else { Get-Field $r0 @('AngleFromZDeg') }
    $ang2Deg = if ($null -ne $a2) { Get-Field $a2 @('AngleFromZDeg') } else { Get-Field $r2 @('AngleFromZDeg') }

    Assert-True "plan row0: angle off Z ~ 0" (($null -ne $ang0Deg) -and (Approx ([double]$ang0Deg) 0.0 1e-6))
    Assert-True "plan row1: angle off Z ~ 45" (($null -ne $ang1Deg) -and (Approx ([double]$ang1Deg) 45.0 1e-6))
    Assert-True "plan row2: angle off Z ~ 10" (($null -ne $ang2Deg) -and (Approx ([double]$ang2Deg) 10.0 1e-6))
}

# summary: max angle off nominal (the 45-deg hole) + a tilted flag.
$maxTilt = Get-Field $plan @('MaxAngleFromZDeg','MaxTiltDeg','MaxAngleDeg','MaxTilt','MaxAngle')
Assert-True "plan: max-tilt summary ~ 45" (($null -ne $maxTilt) -and (Approx ([double]$maxTilt) 45.0 1e-6))

# some hole exceeds the 20-deg warn threshold => an "any tilted" style flag is true.
$anyTilted = Get-Field $plan @('AnyTilted','HasTilted','Warned','AnyBeyondThreshold','TiltWarn','Warn')
Assert-True "plan: a tilted-beyond-threshold flag is present" ($null -ne $anyTilted)
Assert-True "plan: tilted flag TRUE (45 > 20)" (($null -ne $anyTilted) -and ([bool]$anyTilted))

# with a generous threshold nothing is flagged.
$planLoose = Get-CurvedHolePlan -Holes $holes -MaxTiltDeg 60.0
$anyLoose = Get-Field $planLoose @('AnyTilted','HasTilted','Warned','AnyBeyondThreshold','TiltWarn','Warn')
Assert-True "plan (loose 60deg): tilted flag FALSE (45 < 60)" (($null -ne $anyLoose) -and (-not [bool]$anyLoose))

# a malformed / null hole is flagged, NOT fatal (never throws).
$holesBad = @(
    @{ Pos = @(0,0,0); Axis = @(0,0,1) },
    @{ Pos = @(1,0,0); Axis = @(0,0,0) },   # degenerate axis
    $null,                                   # missing hole entirely
    @{ Pos = @(3,0,0); Axis = @(0,0,1) }
)
$planBad = $null
$threw = $false
try { $planBad = Get-CurvedHolePlan -Holes $holesBad -MaxTiltDeg 20.0 } catch { $threw = $true }
Assert-True "plan with bad holes: did NOT throw" (-not $threw)
Assert-True "plan with bad holes: returned an object" ($null -ne $planBad)
if ($null -ne $planBad) {
    $badRows = Get-Field $planBad @('Holes','Rows','Records','Items','Plan')
    Assert-True "plan with bad holes: still enumerated the good holes" (($badRows | Measure-Object).Count -ge 2)
    # at least one row/record is flagged invalid; look for an invalid marker anywhere.
    $flaggedBad = $false
    foreach ($br in $badRows) {
        if ($null -eq $br) { continue }
        $bv = Get-Field $br @('Valid')
        if ($null -ne $bv -and -not [bool]$bv) { $flaggedBad = $true; break }
        $ba = Get-Field $br @('Angularity','Bore','Ang','BoreAngularity')
        if ($null -ne $ba) {
            $bav = Get-Field $ba @('Valid')
            if ($null -ne $bav -and -not [bool]$bav) { $flaggedBad = $true; break }
        }
    }
    $planErrs = Get-Field $planBad @('Errors')
    Assert-True "plan with bad holes: a bad hole is flagged (row Valid=false or plan Errors)" ($flaggedBad -or (($null -ne $planErrs) -and ($planErrs.Count -ge 1)))
}

# empty holes list: no throw, empty/valid result.
$threwEmpty = $false
$planEmpty = $null
try { $planEmpty = Get-CurvedHolePlan -Holes @() -MaxTiltDeg 20.0 } catch { $threwEmpty = $true }
Assert-True "plan with empty list: did NOT throw" (-not $threwEmpty)
Assert-True "plan with empty list: returned an object" ($null -ne $planEmpty)

# null holes: no throw.
$threwNull = $false
try { [void](Get-CurvedHolePlan -Holes $null -MaxTiltDeg 20.0) } catch { $threwNull = $true }
Assert-True "plan with null Holes: did NOT throw" (-not $threwNull)

# ============================================================================
# Get-CurvedIndexExport
# ============================================================================
Write-Host "  -- Get-CurvedIndexExport --" -ForegroundColor White

# 3 coplanar holes with parallel +Z axes, laid out flat in the z=0 plane:
#   h0 = index A at (0,0,0), h2 = index B at (4,0,0) => the 1->2 line is +X.
#   h1 = (2,1.5,0) a middle hole.
# The index frame should put A at the origin and B on the +X axis - matching the
# proven index_frame.ps1 result exactly.
$expHoles = @(
    @{ Pos = @(0,0,0);   Axis = @(0,0,1) },   # index A
    @{ Pos = @(2,1.5,0); Axis = @(0,0,1) },   # middle
    @{ Pos = @(4,0,0);   Axis = @(0,0,1) }    # index B
)
$exp = Get-CurvedIndexExport -Holes $expHoles -IndexA @(0,0,0) -IndexB @(4,0,0)
Assert-True "export: Valid" ($exp.Valid)

$erows = Get-Field $exp @('Holes','Rows','Records','Items','Export')
Assert-True "export: has a per-hole collection" ($null -ne $erows)
Assert-True "export: 3 rows" (($erows | Measure-Object).Count -eq 3)

# Independent index_frame ground truth to compare against.
$gtFrame = Get-IndexFrame -A1 @(0,0,0) -A2 @(4,0,0) -D1 @(0,0,1) -D2 @(0,0,1)
Assert-True "export: ground-truth frame Valid" ($gtFrame.Valid)

if ($null -ne $erows -and ($erows | Measure-Object).Count -eq 3) {
    $e0 = $erows[0]; $e1 = $erows[1]; $e2 = $erows[2]

    # contract field names: X_index; Y_index; Z_index; DirCos*; AngleFromZDeg; IsIndex
    $e0x = Get-Field $e0 @('X_index','Xindex','XIndex')
    $e0y = Get-Field $e0 @('Y_index','Yindex','YIndex')
    $e0z = Get-Field $e0 @('Z_index','Zindex','ZIndex')
    Assert-True "export row0: X_index present" ($null -ne $e0x)
    Assert-True "export row0: Y_index present" ($null -ne $e0y)
    Assert-True "export row0: Z_index present" ($null -ne $e0z)

    # index hole A -> origin (0,0,0)
    Assert-True "export: index A at origin (X_index~0)" (($null -ne $e0x) -and (Approx ([double]$e0x) 0.0 1e-9))
    Assert-True "export: index A at origin (Y_index~0)" (($null -ne $e0y) -and (Approx ([double]$e0y) 0.0 1e-9))
    Assert-True "export: index A at origin (Z_index~0)" (($null -ne $e0z) -and (Approx ([double]$e0z) 0.0 1e-9))

    # index hole B -> on +X axis: X_index = 4 (the separation), Y_index ~ 0.
    $e2x = Get-Field $e2 @('X_index','Xindex','XIndex')
    $e2y = Get-Field $e2 @('Y_index','Yindex','YIndex')
    Assert-True "export: index B X_index ~ 4 (separation)" (($null -ne $e2x) -and (Approx ([double]$e2x) 4.0 1e-9))
    Assert-True "export: index B on +X (Y_index ~ 0)" (($null -ne $e2y) -and (Approx ([double]$e2y) 0.0 1e-9))

    # middle hole -> matches the independent index_frame transform exactly.
    $gtMid = ConvertTo-IndexCoords -Frame $gtFrame -P @(2,1.5,0)
    $e1x = Get-Field $e1 @('X_index','Xindex','XIndex')
    $e1y = Get-Field $e1 @('Y_index','Yindex','YIndex')
    Assert-True "export: middle X_index matches index_frame" (($null -ne $e1x) -and (Approx ([double]$e1x) $gtMid.X 1e-9))
    Assert-True "export: middle Y_index matches index_frame" (($null -ne $e1y) -and (Approx ([double]$e1y) $gtMid.Y 1e-9))

    # IsIndex flags: the two index holes flagged, the middle not.
    $e0IsIdx = Get-Field $e0 @('IsIndex','IsIndexHole')
    $e1IsIdx = Get-Field $e1 @('IsIndex','IsIndexHole')
    $e2IsIdx = Get-Field $e2 @('IsIndex','IsIndexHole')
    Assert-True "export: IsIndex present on row0" ($null -ne $e0IsIdx)
    Assert-True "export: index A IsIndex TRUE" (($null -ne $e0IsIdx) -and ([bool]$e0IsIdx))
    Assert-True "export: index B IsIndex TRUE" (($null -ne $e2IsIdx) -and ([bool]$e2IsIdx))
    Assert-True "export: middle IsIndex FALSE" (($null -ne $e1IsIdx) -and (-not [bool]$e1IsIdx))

    # orientation carried through: parallel +Z bores => DirCosZ ~ 1 on every row.
    $e0dcz = Get-Field $e0 @('DirCosZ')
    $e1dcz = Get-Field $e1 @('DirCosZ')
    Assert-True "export: DirCosZ present" ($null -ne $e0dcz)
    Assert-True "export: flat bore DirCosZ ~ 1 (row0)" (($null -ne $e0dcz) -and (Approx ([double]$e0dcz) 1.0 1e-9))
    Assert-True "export: flat bore DirCosZ ~ 1 (row1)" (($null -ne $e1dcz) -and (Approx ([double]$e1dcz) 1.0 1e-9))
    $e0afz = Get-Field $e0 @('AngleFromZDeg')
    Assert-True "export: AngleFromZDeg present" ($null -ne $e0afz)
    Assert-True "export: flat bore AngleFromZDeg ~ 0" (($null -ne $e0afz) -and (Approx ([double]$e0afz) 0.0 1e-6))
}

# A TILTED hole's orientation is carried through the export.
#   Same layout, but the middle hole tilts 45 deg (in X-Z).
$expTiltHoles = @(
    @{ Pos = @(0,0,0);   Axis = @(0,0,1) },
    @{ Pos = @(2,1.5,0); Axis = @($s45,0,$cos45) },
    @{ Pos = @(4,0,0);   Axis = @(0,0,1) }
)
$expTilt = Get-CurvedIndexExport -Holes $expTiltHoles -IndexA @(0,0,0) -IndexB @(4,0,0)
Assert-True "export (tilt): Valid" ($expTilt.Valid)
$etrows = Get-Field $expTilt @('Holes','Rows','Records','Items','Export')
if ($null -ne $etrows -and ($etrows | Measure-Object).Count -eq 3) {
    $et1 = $etrows[1]
    $et1afz = Get-Field $et1 @('AngleFromZDeg')
    Assert-True "export (tilt): middle AngleFromZDeg ~ 45 carried through" (($null -ne $et1afz) -and (Approx ([double]$et1afz) 45.0 1e-6))
    $et1dcz = Get-Field $et1 @('DirCosZ')
    Assert-True "export (tilt): middle DirCosZ ~ cos45" (($null -ne $et1dcz) -and (Approx ([double]$et1dcz) $cos45 1e-9))
}

# NEVER throws on bad input.
#   (a) collinear index holes (A2 - A1 purely along the bore axis) => invalid frame.
$threwCol = $false
$expCol = $null
try {
    $expCol = Get-CurvedIndexExport -Holes $expHoles -IndexA @(0,0,0) -IndexB @(0,0,5)
} catch { $threwCol = $true }
Assert-True "export collinear index: did NOT throw" (-not $threwCol)
Assert-True "export collinear index: Valid=false" (($null -ne $expCol) -and (-not $expCol.Valid))

#   (b) null / malformed holes.
$threwBad2 = $false
$expBad = $null
try {
    $expBad = Get-CurvedIndexExport -Holes @( @{ Pos=@(0,0,0); Axis=@(0,0,1) }, $null, @{ Pos=@(4,0,0); Axis=@(0,0,1) } ) -IndexA @(0,0,0) -IndexB @(4,0,0)
} catch { $threwBad2 = $true }
Assert-True "export with null hole: did NOT throw" (-not $threwBad2)
Assert-True "export with null hole: returned an object" ($null -ne $expBad)

#   (c) null Holes / null index positions.
$threwNulls = $false
try { [void](Get-CurvedIndexExport -Holes $null -IndexA @(0,0,0) -IndexB @(4,0,0)) } catch { $threwNulls = $true }
Assert-True "export with null Holes: did NOT throw" (-not $threwNulls)

$threwNullIdx = $false
$expNullIdx = $null
try { $expNullIdx = Get-CurvedIndexExport -Holes $expHoles -IndexA $null -IndexB @(4,0,0) } catch { $threwNullIdx = $true }
Assert-True "export with null IndexA: did NOT throw" (-not $threwNullIdx)
Assert-True "export with null IndexA: Valid=false" (($null -ne $expNullIdx) -and (-not $expNullIdx.Valid))

# ============================================================================
# SUMMARY
# ============================================================================
Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ("  curved-jig tests: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { "Green" } else { "Red" })
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ""
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
