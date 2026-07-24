# ============================================================================
# lib\tests\run_fastener_tests.ps1 - offline unit tests for lib\fastener_layout.ps1
# ============================================================================
# Runs WITHOUT Creo and WITHOUT network. Exercises the PURE half of the
# import-fastener-layout feature: axis projection + sign, the corner-shift that
# keeps every point >= Margin (so Get-CustomPointsGeometry never drops the origin
# point), stack dedup by projected proximity, the Margin<=0 / same-axis guards,
# the sanity canary, and the fastener_layout.json round-trip (exact PascalCase).
#
# Run:  powershell -ExecutionPolicy Bypass -File lib\tests\run_fastener_tests.ps1
# Exit code 0 = all passed, 1 = at least one failure. Mirrors run_index_frame_tests.ps1.
# ============================================================================

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here
. (Join-Path $libDir 'fastener_layout.ps1')
# Get-CustomPointsGeometry is the downstream consumer - load it so we can assert
# the integration contract (fastener Points feed it and produce a valid layout).
. (Join-Path $libDir 'orthogrid.ps1')

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

Write-Host ""
Write-Host "  Running fastener-layout unit tests (offline)..." -ForegroundColor Cyan
Write-Host ""

# ----------------------------------------------------------------------------
# Get-AxisComponent
# ----------------------------------------------------------------------------
Write-Host "  -- Get-AxisComponent --" -ForegroundColor White

Assert-True "axis X -> comp[0]" (Approx (Get-AxisComponent -Center @(1.5, 2.5, 3.5) -Axis 'X') 1.5)
Assert-True "axis Y -> comp[1]" (Approx (Get-AxisComponent -Center @(1.5, 2.5, 3.5) -Axis 'Y') 2.5)
Assert-True "axis Z -> comp[2]" (Approx (Get-AxisComponent -Center @(1.5, 2.5, 3.5) -Axis 'Z') 3.5)
Assert-True "axis lowercase ok"  (Approx (Get-AxisComponent -Center @(1.5, 2.5, 3.5) -Axis 'z') 3.5)
Assert-True "sign flips"         (Approx (Get-AxisComponent -Center @(1.5, 2.5, 3.5) -Axis 'X' -Sign -1) -1.5)
Assert-True "bad axis -> null"   ($null -eq (Get-AxisComponent -Center @(1,2,3) -Axis 'Q'))
Assert-True "null center -> null" ($null -eq (Get-AxisComponent -Center $null -Axis 'X'))
Assert-True "NaN component -> null" ($null -eq (Get-AxisComponent -Center @([double]::NaN, 0, 0) -Axis 'X'))
Assert-True "Inf component -> null" ($null -eq (Get-AxisComponent -Center @([double]::PositiveInfinity, 0, 0) -Axis 'X'))

# ----------------------------------------------------------------------------
# ConvertTo-LayoutXZ - core projection + corner-shift
# ----------------------------------------------------------------------------
Write-Host "  -- ConvertTo-LayoutXZ projection --" -ForegroundColor White

# a simple 2x2 pattern in model X/Z at model coords (10..12, 5, 20..22).
# Y (=5) is the through-thickness axis and must be IGNORED when AxisX=X, AxisZ=Z.
$centers = @(
    @(10.0, 5.0, 20.0),
    @(12.0, 5.0, 20.0),
    @(10.0, 5.0, 22.0),
    @(12.0, 5.0, 22.0)
)
$r = ConvertTo-LayoutXZ -Centers $centers -AxisX 'X' -AxisZ 'Z' -Margin 0.5 -DedupTol 1e-4
Assert-True "basic: Valid" ($r.Valid) (($r.Errors) -join '; ')
Assert-True "basic: 4 kept" ($r.Count -eq 4)
Assert-True "basic: none dropped" ($r.Dropped -eq 0)
Assert-True "basic: none skipped" ($r.Skipped -eq 0)
# corner-shift: min X was 10 -> shifts to Margin 0.5; min Z was 20 -> 0.5.
Assert-True "basic: nearest point at (Margin,Margin)" (
    ($r.Points | Where-Object { (Approx $_.X 0.5) -and (Approx $_.Z 0.5) } | Measure-Object).Count -eq 1)
Assert-True "basic: far point at (2.5,2.5)" (
    ($r.Points | Where-Object { (Approx $_.X 2.5) -and (Approx $_.Z 2.5) } | Measure-Object).Count -eq 1)
Assert-True "basic: every X >= Margin" (@($r.Points | Where-Object { $_.X -lt 0.5 - 1e-12 }).Count -eq 0)
Assert-True "basic: every Z >= Margin" (@($r.Points | Where-Object { $_.Z -lt 0.5 - 1e-12 }).Count -eq 0)
Assert-True "basic: spanX = 2" (Approx $r.SpanX 2.0)
Assert-True "basic: spanZ = 2" (Approx $r.SpanZ 2.0)

# axis remap: use Y as layout Z (a part laid out in the X/Y plane).
$centersXY = @(
    @(0.0, 0.0, 99.0),
    @(3.0, 0.0, 99.0),
    @(0.0, 4.0, 99.0)
)
$rXY = ConvertTo-LayoutXZ -Centers $centersXY -AxisX 'X' -AxisZ 'Y' -Margin 1.0
Assert-True "remap X/Y: Valid" ($rXY.Valid)
Assert-True "remap X/Y: spanZ from Y = 4" (Approx $rXY.SpanZ 4.0)
Assert-True "remap X/Y: spanX = 3" (Approx $rXY.SpanX 3.0)
# the Z=99 model component is ignored entirely.

# sign flip: negate X so the layout mirrors. Model X in {0,2}; -X in {0,-2};
# after corner-shift the point that WAS at min-x ends up at the far edge.
$rSign = ConvertTo-LayoutXZ -Centers @(@(0,0,0), @(2,0,0)) -AxisX 'X' -AxisZ 'Z' -AxisXSign -1 -Margin 0.5
Assert-True "sign flip: Valid + 2 pts" ($rSign.Valid -and $rSign.Count -eq 2)
Assert-True "sign flip: spanX preserved" (Approx $rSign.SpanX 2.0)

# ----------------------------------------------------------------------------
# ConvertTo-LayoutXZ - guards
# ----------------------------------------------------------------------------
Write-Host "  -- ConvertTo-LayoutXZ guards --" -ForegroundColor White

$rBadAxis = ConvertTo-LayoutXZ -Centers $centers -AxisX 'X' -AxisZ 'Q'
Assert-True "bad AxisZ -> invalid" (-not $rBadAxis.Valid)

$rSameAxis = ConvertTo-LayoutXZ -Centers $centers -AxisX 'X' -AxisZ 'X'
Assert-True "same axis both -> invalid (collapses to a line)" (-not $rSameAxis.Valid)

$rZeroMargin = ConvertTo-LayoutXZ -Centers $centers -AxisX 'X' -AxisZ 'Z' -Margin 0
Assert-True "Margin=0 -> invalid (would drop the corner point)" (-not $rZeroMargin.Valid)

$rNegMargin = ConvertTo-LayoutXZ -Centers $centers -AxisX 'X' -AxisZ 'Z' -Margin -1
Assert-True "Margin<0 -> invalid" (-not $rNegMargin.Valid)

$rNegDedup = ConvertTo-LayoutXZ -Centers $centers -AxisX 'X' -AxisZ 'Z' -Margin 0.5 -DedupTol -1
Assert-True "DedupTol<0 -> invalid" (-not $rNegDedup.Valid)

$rEmpty = ConvertTo-LayoutXZ -Centers @() -AxisX 'X' -AxisZ 'Z' -Margin 0.5
Assert-True "no centers -> invalid, no throw" (-not $rEmpty.Valid -and $rEmpty.Count -eq 0)

$rNull = ConvertTo-LayoutXZ -Centers $null -AxisX 'X' -AxisZ 'Z' -Margin 0.5
Assert-True "null centers -> invalid, no throw" (-not $rNull.Valid)

# a center with a non-numeric component is skipped (not fatal by itself, but
# recorded); a mix keeps the good ones and reports the skip.
$rSkip = ConvertTo-LayoutXZ -Centers @(@(1,1,1), @('x',2,3), @(4,1,5)) -AxisX 'X' -AxisZ 'Z' -Margin 0.5
Assert-True "bad component skipped + flagged" ($rSkip.Skipped -eq 1)
Assert-True "bad component: invalid (skip is an error)" (-not $rSkip.Valid)
Assert-True "bad component: good points still projected best-effort" ($rSkip.Points.Count -eq 2)

# ----------------------------------------------------------------------------
# ConvertTo-LayoutXZ - dedup (bolt+washer+nut stacks)
# ----------------------------------------------------------------------------
Write-Host "  -- ConvertTo-LayoutXZ dedup --" -ForegroundColor White

# a through-fastener at (5,_,7) reads as 3 collinear cylinders at slightly
# different (x,z) due to descriptor origins; DedupTol >= stack scatter merges them.
$stack = @(
    @(5.000, 0.0, 7.000),
    @(5.001, 0.0, 7.001),
    @(4.999, 0.0, 6.999),
    @(9.000, 0.0, 7.000)     # a distinct second fastener
)
$rDup = ConvertTo-LayoutXZ -Centers $stack -AxisX 'X' -AxisZ 'Z' -Margin 0.5 -DedupTol 0.01
Assert-True "dedup: 2 kept from a 3-cylinder stack + 1 loner" ($rDup.Count -eq 2)
Assert-True "dedup: 2 merged away" ($rDup.Dropped -eq 2)

# with a tiny tol nothing merges (all 4 survive)
$rNoDup = ConvertTo-LayoutXZ -Centers $stack -AxisX 'X' -AxisZ 'Z' -Margin 0.5 -DedupTol 1e-6
Assert-True "no-dedup with tiny tol: 4 kept" ($rNoDup.Count -eq 4)

# over-large tol merges everything -> invalid (guards against silent 1-hole)
$rAllDup = ConvertTo-LayoutXZ -Centers $stack -AxisX 'X' -AxisZ 'Z' -Margin 0.5 -DedupTol 100
Assert-True "over-large dedup: collapses toward few + still valid if >=1" ($rAllDup.Count -ge 1)

# ----------------------------------------------------------------------------
# FL-BestFitNormal + Get-FastenerPlaneFrame - panel frame from the HOLE POSITIONS
# (best-fit plane), with the fastener axes as a fallback for < 3 / collinear holes.
# ----------------------------------------------------------------------------
Write-Host "  -- FL-BestFitNormal / Get-FastenerPlaneFrame --" -ForegroundColor White

# best-fit normal of points in the Y=5 plane -> normal ~ +/-Y, flatness ~ 0
$bf = FL-BestFitNormal -Points @(@(0,5,0), @(2,5,0), @(0,5,3), @(2,5,3))
Assert-True "bestfit: coplanar -> normal ~ +/-Y" ($null -ne $bf -and [math]::Abs([double]$bf.Normal[1]) -gt 0.999)
Assert-True "bestfit: flatness ~ 0 for coplanar points" ($null -ne $bf -and [double]$bf.Flatness -lt 1e-9)
Assert-True "bestfit: < 3 points -> null" ($null -eq (FL-BestFitNormal -Points @(@(0,0,0), @(1,1,1))))
Assert-True "bestfit: collinear points -> null (normal indeterminate)" ($null -eq (FL-BestFitNormal -Points @(@(0,0,0), @(1,0,0), @(2,0,0), @(3,0,0))))

# parallel axes (all +Y) + coplanar points -> normal ~ +Y from the POINTS
$fpAxes = @(@(0,1,0), @(0,1,0), @(0,1,0), @(0,1,0))
$fpCtr  = @(@(0,5,0), @(2,5,0), @(0,5,3), @(2,5,3))
$fr = Get-FastenerPlaneFrame -Centers $fpCtr -Axes $fpAxes -AxisX 'X' -AxisZ 'Z'
Assert-True "frame: valid for coplanar points" ($fr.Valid) (($fr.Errors) -join '; ')
Assert-True "frame: normal ~ +/-Y" ([math]::Abs([double]$fr.N[1]) -gt 0.999)
Assert-True "frame: normal came from the POINTS" ($fr.NormalSource -eq 'points')
Assert-True "frame: Xhat unit" (Approx ([math]::Sqrt($fr.Xhat[0]*$fr.Xhat[0]+$fr.Xhat[1]*$fr.Xhat[1]+$fr.Xhat[2]*$fr.Xhat[2])) 1.0 1e-9)
Assert-True "frame: Xhat . Zhat ~ 0 (orthonormal)" ([math]::Abs($fr.Xhat[0]*$fr.Zhat[0]+$fr.Xhat[1]*$fr.Zhat[1]+$fr.Xhat[2]*$fr.Zhat[2]) -lt 1e-9)
Assert-True "frame: axis spread ~ 0 (axes match the point normal here)" ([double]$fr.AxisSpreadDeg -lt 1e-6)

# NO axes but >=3 coplanar points -> STILL valid, from the points (the key upgrade:
# the plane no longer needs the fastener axes at all)
$frNoAx = Get-FastenerPlaneFrame -Centers $fpCtr -Axes @($null,$null,$null,$null) -AxisX 'X' -AxisZ 'Z'
Assert-True "frame: no axes but coplanar points -> valid from points" ($frNoAx.Valid -and $frNoAx.NormalSource -eq 'points')

# COLLINEAR points + axes -> best-fit indeterminate -> FALL BACK to the axis normal
$frCol = Get-FastenerPlaneFrame -Centers @(@(0,5,0), @(1,5,0), @(2,5,0)) -Axes @(@(0,1,0), @(0,1,0), @(0,1,0)) -AxisX 'X' -AxisZ 'Z'
Assert-True "frame: collinear holes -> axis-fallback normal" ($frCol.Valid -and $frCol.NormalSource -eq 'axis')

# layout X axis parallel to the panel normal -> AUTO-SUBSTITUTED with an in-plane axis
# (the operator need not know the panel orientation). Panel normal here is Y; asking for
# AxisX='Y' is degenerate, so Xhat becomes an in-plane axis (X or Z) -> still valid.
$frBadX = Get-FastenerPlaneFrame -Centers $fpCtr -Axes $fpAxes -AxisX 'Y' -AxisZ 'Z'
Assert-True "frame: AxisX along normal -> auto-substituted, still valid" ($frBadX.Valid)
Assert-True "frame: auto-substituted Xhat is in-plane (perp to normal Y)" ([math]::Abs($frBadX.Xhat[1]) -lt 1e-9)

# never throws on junk
$frJunk = Get-FastenerPlaneFrame -Centers $null -Axes $null
Assert-True "frame: null in -> invalid, no throw" (-not $frJunk.Valid)

# ----------------------------------------------------------------------------
# ConvertTo-LayoutXZ - PANEL-PLANE projection (the tilted-panel fix)
# ----------------------------------------------------------------------------
Write-Host "  -- ConvertTo-LayoutXZ panel-plane projection --" -ForegroundColor White

# AXIS-ALIGNED panel (normal +Y): plane mode must MATCH the legacy global drop.
$aaCtr  = @(@(0,5,0), @(2,5,0), @(0,5,3), @(2,5,3))
$aaAxes = @(@(0,1,0), @(0,1,0), @(0,1,0), @(0,1,0))
$rGlobal = ConvertTo-LayoutXZ -Centers $aaCtr -AxisX 'X' -AxisZ 'Z' -Margin 0.5
$rPlane  = ConvertTo-LayoutXZ -Centers $aaCtr -Axes $aaAxes -AxisX 'X' -AxisZ 'Z' -Margin 0.5
Assert-True "plane: axis-aligned uses plane frame" ($rPlane.Frame -eq 'plane')
Assert-True "plane: legacy fallback when no axes" ($rGlobal.Frame -eq 'global')
Assert-True "plane: axis-aligned spanX matches legacy (2)" ((Approx $rPlane.SpanX 2.0) -and (Approx $rGlobal.SpanX 2.0))
Assert-True "plane: axis-aligned spanZ matches legacy (3)" ((Approx $rPlane.SpanZ 3.0) -and (Approx $rGlobal.SpanZ 3.0))

# TILTED panel: the SAME 2x3 grid rotated 45 deg about global X. True in-plane
# spacing is still 2 x 3, but the GLOBAL drop distorts Z to 3*cos45 = 2.121.
# Plane projection must RECOVER the true 3.0. c = s = cos(45).
# NOTE: precompute every product into a scalar -- PS 5.1 mis-parses a comma
# @(literal, number*var, ...) literal (the file's documented COM-array trap).
$c45 = 0.70710678118
$p3  = 3.0 * $c45                       # 2.1213...  the tilted Y/Z component
$negC = -1.0 * $c45
$tiltCtr = @(
    (@(0.0, 0.0, 0.0)),
    (@(2.0, 0.0, 0.0)),
    (@(0.0, $p3, $p3)),
    (@(2.0, $p3, $p3))
)
$tiltNrm = @(0.0, $negC, $c45)          # (0,0,1) rotated 45 deg about X
$tiltAxes = @($tiltNrm, $tiltNrm, $tiltNrm, $tiltNrm)
$rTiltGlobal = ConvertTo-LayoutXZ -Centers $tiltCtr -AxisX 'X' -AxisZ 'Z' -Margin 0.5
$rTiltPlane  = ConvertTo-LayoutXZ -Centers $tiltCtr -Axes $tiltAxes -AxisX 'X' -AxisZ 'Z' -Margin 0.5
Assert-True "tilt: global drop DISTORTS spanZ (2.121, not 3)" (Approx $rTiltGlobal.SpanZ $p3 1e-3)
Assert-True "tilt: plane projection RECOVERS true spanZ = 3.0" (Approx $rTiltPlane.SpanZ 3.0 1e-6)
Assert-True "tilt: plane preserves spanX = 2.0" (Approx $rTiltPlane.SpanX 2.0 1e-6)
Assert-True "tilt: plane keeps all 4 distinct holes (no false collapse)" ($rTiltPlane.Count -eq 4)

# Points COINCIDENT in 3D (a re-selected same instance) merge in plane mode too --
# stack-merging via best-fit is NOT guaranteed (a stack's axis can be in-plane), so
# genuine coincidence, not "coaxial", is what DedupTol collapses.
$dupCtr = @(
    (@(0.0, 5.0, 0.0)),
    (@(0.0, 5.0, 0.0)),                                    # exact duplicate
    (@(2.0, 5.0, 0.0)),
    (@(0.0, 5.0, 3.0))
)
$dupAx = @(@(0,1,0), @(0,1,0), @(0,1,0), @(0,1,0))
$rDupPlane = ConvertTo-LayoutXZ -Centers $dupCtr -Axes $dupAx -AxisX 'X' -AxisZ 'Z' -Margin 0.5 -DedupTol 1e-3
Assert-True "plane: exact-coincident points merge -> 3 holes" ($rDupPlane.Count -eq 3)

# a null axis entry is tolerated; the plane still comes from the POINTS
$rMixedAxes = ConvertTo-LayoutXZ -Centers $aaCtr -Axes @(@(0,1,0), $null, @(0,1,0), @(0,1,0)) -AxisX 'X' -AxisZ 'Z' -Margin 0.5
Assert-True "plane: null axis entry tolerated, still plane mode" ($rMixedAxes.Frame -eq 'plane' -and $rMixedAxes.Count -eq 4)

# ----------------------------------------------------------------------------
# REAL DATA regression: the operator's 22-fastener higher-level assembly. The
# holes are coplanar on Z - Y = 0.6194 (normal ~ (0,-1,1)); the fastener axis
# read (1,0,0) LIES IN that plane. The old global (X,Z) drop compresses the row
# spacing by sqrt(2) and coincides rows; best-fit-plane projection must keep all
# 22 distinct with true spacing (columns span 3.75, rows span 7.5).
# ----------------------------------------------------------------------------
Write-Host "  -- real 22-fastener assembly regression --" -ForegroundColor White
$realCtr = @(
 (@(107.381,22.9859,23.6053)),(@(104.881,23.693,24.3125)),(@(107.381,23.693,24.3125)),
 (@(104.881,25.6376,26.257)),(@(107.381,25.6376,26.257)),(@(104.881,26.5215,27.1409)),
 (@(108.631,26.5215,27.1409)),(@(106.131,23.693,24.3125)),(@(106.131,24.4001,25.0196)),
 (@(107.381,24.4001,25.0196)),(@(104.881,24.4001,25.0196)),(@(106.131,26.5215,27.1409)),
 (@(106.131,27.4053,28.0248)),(@(107.381,26.5215,27.1409)),(@(107.381,27.4053,28.0248)),
 (@(106.131,25.6376,26.257)),(@(108.631,27.4053,28.0248)),(@(106.131,22.9859,23.6053)),
 (@(104.881,22.9859,23.6053)),(@(108.631,28.2892,28.9086)),(@(107.381,28.2892,28.9086)),
 (@(106.131,28.2892,28.9086)))
$realAxV = @(1.0, 0.0, 0.0)                                # the (misleading) fastener axis (1,0,0)
$realAxes = @(); foreach ($i in 0..21) { $realAxes += ,$realAxV }
$rReal = ConvertTo-LayoutXZ -Centers $realCtr -Axes $realAxes -AxisX 'X' -AxisZ 'Z' -Margin 0.375 -DedupTol 1e-3
Assert-True "real: plane frame from the POINTS (axis was in-plane)" ($rReal.Frame -eq 'plane' -and $rReal.NormalSource -eq 'points')
Assert-True "real: holes are coplanar (flatness ~ 0)" ($null -ne $rReal.Flatness -and [double]$rReal.Flatness -lt 1e-6)
Assert-True "real: ALL 22 holes kept (no false collapse)" ($rReal.Count -eq 22)
Assert-True "real: column span ~ 3.75" (Approx $rReal.SpanX 3.75 1e-2)
Assert-True "real: row span ~ 7.5 (true, not sqrt2-compressed)" (Approx $rReal.SpanZ 7.5 1e-2)
# the OLD global (X,Z) drop compresses the rows -> smaller Z span (the bug)
$rRealGlobal = ConvertTo-LayoutXZ -Centers $realCtr -AxisX 'X' -AxisZ 'Z' -Margin 0.375
Assert-True "real: OLD global drop compressed the row span (< true 7.5)" ([double]$rRealGlobal.SpanZ -lt 7.0)
# COUNT-PRESERVATION (user 2026-07-23: picked count = hole count): with DedupTol=0 the
# 22 distinct fasteners must stay 22 -- NO proximity merge ever reduces distinct holes.
$rReal0 = ConvertTo-LayoutXZ -Centers $realCtr -Axes $realAxes -AxisX 'X' -AxisZ 'Z' -Margin 0.375 -DedupTol 0
Assert-True "real: DedupTol=0 keeps all 22 (no merge)" ($rReal0.Count -eq 22 -and $rReal0.Dropped -eq 0)
Assert-True "real: SpanRatio exposed + well-conditioned" ($null -ne $rReal0.SpanRatio -and [double]$rReal0.SpanRatio -gt 0.06)

# REAL DATA #2 (150-110-0030-101.asm, 8 fasteners nas6405a9): the panel normal is
# GLOBAL X (all 8 share X=109.444; a 2x4 grid in Y-Z). The default AxisX='X' is now the
# NORMAL -> the layout must AUTO-SUBSTITUTE in-plane axes (Y,Z) instead of failing, and
# keep all 8 holes at true spacing (Y span 1.5, Z span 6.0). Fastener Zaxis=(0,0,1) is
# again IN-plane, not the normal.
Write-Host "  -- real 8-fastener assembly (panel normal = global X) --" -ForegroundColor White
$real2Ctr = @(
 (@(109.444,25.9269,16.75)),(@(109.444,24.4269,16.75)),(@(109.444,24.4269,15.25)),(@(109.444,25.9269,15.25)),
 (@(109.444,25.9269,12.25)),(@(109.444,24.4269,12.25)),(@(109.444,24.4269,10.75)),(@(109.444,25.9269,10.75)))
$real2AxV = @(0.0, 0.0, 1.0)                               # the fastener Zaxis (0,0,1), in-plane
$real2Axes = @(); foreach ($i in 0..7) { $real2Axes += ,$real2AxV }
$rReal2 = ConvertTo-LayoutXZ -Centers $real2Ctr -Axes $real2Axes -AxisX 'X' -AxisZ 'Z' -Margin 0.375 -DedupTol 0
Assert-True "real2: normal = X panel -> plane frame from points" ($rReal2.Frame -eq 'plane' -and $rReal2.NormalSource -eq 'points')
Assert-True "real2: default AxisX=X (the normal) auto-substituted -> Valid, all 8 kept" ($rReal2.Valid -and $rReal2.Count -eq 8)
Assert-True "real2: coplanar (flatness ~ 0)" ($null -ne $rReal2.Flatness -and [double]$rReal2.Flatness -lt 1e-6)
# true in-plane spans (Y=1.5, Z=6.0) preserved, in some axis order
$sp = @([double]$rReal2.SpanX, [double]$rReal2.SpanZ) | Sort-Object
Assert-True "real2: true spans 1.5 & 6.0 preserved (no distortion)" ((Approx $sp[0] 1.5 1e-2) -and (Approx $sp[1] 6.0 1e-2))

# ----------------------------------------------------------------------------
# GRID ALIGNMENT (-AlignGrid, user 2026-07-23): a pattern rotated in-plane relative to
# the layout axes must be DE-ROTATED so rows/columns run perpendicular to the axes.
# ----------------------------------------------------------------------------
Write-Host "  -- grid alignment (-AlignGrid) --" -ForegroundColor White

# FL-BestGridAngle: an axis-aligned 2x3 grid -> ~0 deg; the same grid rotated 30 deg -> ~30.
$gAligned = @( (@{RX=0.0;RZ=0.0}), (@{RX=2.0;RZ=0.0}), (@{RX=0.0;RZ=3.0}), (@{RX=2.0;RZ=3.0}) ) | ForEach-Object { [pscustomobject]$_ }
Assert-True "align-angle: axis-aligned grid -> ~0 deg" ([Math]::Abs((FL-BestGridAngle -Raw $gAligned) * 180.0 / [Math]::PI) -lt 0.5)

# a 3x3 axis-aligned grid, then rotate every point 30 deg in-plane; ConvertTo-LayoutXZ
# with axis-aligned axes (normal +Y, layout X/Z) + -AlignGrid must recover a square-ish
# axis-aligned bounding box (span ratio near the true 2:2), NOT the sqrt2-inflated diag.
$deg30 = 30.0 * [Math]::PI / 180.0
$c30 = [Math]::Cos($deg30); $s30 = [Math]::Sin($deg30)
$gridCtr = @(); $gridAx = @()
foreach ($gx in 0,1,2) { foreach ($gz in 0,1,2) {
    # base grid point (gx, gz) in the X-Z plane (Y=5), rotated 30deg about Y (in the X-Z plane)
    $bx = [double]$gx; $bz = [double]$gz
    $rxp = $bx*$c30 - $bz*$s30
    $rzp = $bx*$s30 + $bz*$c30
    $gridCtr += (,@($rxp, 5.0, $rzp))
    $gridAx  += (,@(0.0, 1.0, 0.0))
} }
$rNoAlign = ConvertTo-LayoutXZ -Centers $gridCtr -Axes $gridAx -AxisX 'X' -AxisZ 'Z' -Margin 0.25 -DedupTol 0
$rAlign   = ConvertTo-LayoutXZ -Centers $gridCtr -Axes $gridAx -AxisX 'X' -AxisZ 'Z' -Margin 0.25 -DedupTol 0 -AlignGrid
Assert-True "align: rotated grid keeps all 9 holes (isometry, no merge)" ($rAlign.Valid -and $rAlign.Count -eq 9)
Assert-True "align: applied ~30 deg de-rotation" ((([Math]::Abs([double]$rAlign.AlignAngleDeg - 30.0) -lt 0.5) -or ([Math]::Abs([double]$rAlign.AlignAngleDeg - 60.0) -lt 0.5)))
# un-aligned: the 30deg-rotated grid's AABB is inflated (span > true 2.0); aligned: ~2.0
Assert-True "align: de-rotated spans collapse to the true grid extent (~2.0)" ((Approx $rAlign.SpanX 2.0 1e-2) -and (Approx $rAlign.SpanZ 2.0 1e-2))
Assert-True "align: un-aligned spans are inflated by the diagonal" ([double]$rNoAlign.SpanX -gt 2.3)
# already-aligned grid + -AlignGrid -> unchanged (angle ~0, spans still 2 x 3)
$rAA = ConvertTo-LayoutXZ -Centers $aaCtr -Axes $aaAxes -AxisX 'X' -AxisZ 'Z' -Margin 0.5 -AlignGrid
Assert-True "align: already-aligned grid unchanged (~0 deg, spans 2 & 3)" ([Math]::Abs([double]$rAA.AlignAngleDeg) -lt 0.5 -and (Approx $rAA.SpanX 2.0 1e-6) -and (Approx $rAA.SpanZ 3.0 1e-6))

# ----------------------------------------------------------------------------
# CONDITIONING GATE: a selection that cannot define the panel plane FAILS LOUD
# (Valid=$false) instead of silently distorting via the legacy global drop.
# ----------------------------------------------------------------------------
Write-Host "  -- conditioning gate (fail loud, no silent distortion) --" -ForegroundColor White

# a single COLUMN of the real panel (3 holes sharing (Y,Z), differ only in X) is
# collinear -> best-fit null -> with -Axes (plane requested) it must NOT silently
# fall back; it must return Valid=$false with a collinear/line message.
$colCtr = @( (@(107.381,22.9859,23.6053)), (@(106.131,22.9859,23.6053)), (@(104.881,22.9859,23.6053)) )
$colAx  = @( (@(1.0,0.0,0.0)), (@(1.0,0.0,0.0)), (@(1.0,0.0,0.0)) )
$rCol = ConvertTo-LayoutXZ -Centers $colCtr -Axes $colAx -AxisX 'X' -AxisZ 'Z' -Margin 0.375 -DedupTol 0
Assert-True "gate: collinear column -> Valid=false (no silent global fallback)" (-not $rCol.Valid)
Assert-True "gate: collinear column -> message names line/collinear" ((($rCol.Errors) -join ' ') -match '(?i)collinear|line')
Assert-True "gate: collinear column -> Frame plane, NormalSource none" ($rCol.Frame -eq 'plane' -and $rCol.NormalSource -eq 'none')

# '3->2' REPRODUCED-then-BLOCKED: 3 real holes collinear along the YZ diagonal.
# Old behaviour merged the middle one (global 1/sqrt2 shrink). These 3 share X=104.881
# (a row in the X=const plane) and the fastener axis (1,0,0) is PERPENDICULAR to that
# row, so the axis-fallback legitimately lays them out as a valid row of 3 at TRUE
# spacing -- no 3->2 merge (the old compression bug is gone; distances 2.0 & 1.75 > tol).
$diagCtr = @( (@(104.881,22.9859,23.6053)), (@(104.881,24.4001,25.0196)), (@(104.881,25.6376,26.257)) )
$diagAx  = @( (@(1.0,0.0,0.0)), (@(1.0,0.0,0.0)), (@(1.0,0.0,0.0)) )
$rDiag = ConvertTo-LayoutXZ -Centers $diagCtr -Axes $diagAx -AxisX 'X' -AxisZ 'Z' -Margin 0.375 -DedupTol 1.0
Assert-True "gate: 3 collinear row (axis perp) -> valid row of 3, NO 3->2 merge" ($rDiag.Valid -and $rDiag.Count -eq 3)
# add ONE off-line helper -> now spans 2D -> Valid, all 4 kept, no merge.
# (unary-comma append: PS 5.1 $a + @(@(x,y,z)) FLATTENS the inner 3-array to scalars)
$diag4Ctr = $diagCtr + (,@(107.381,24.4001,25.0196))
$diag4Ax  = $diagAx  + (,@(1.0,0.0,0.0))
$rDiag4 = ConvertTo-LayoutXZ -Centers $diag4Ctr -Axes $diag4Ax -AxisX 'X' -AxisZ 'Z' -Margin 0.375 -DedupTol 0
Assert-True "gate: +1 off-line helper -> Valid, all 4 kept (2D restored)" ($rDiag4.Valid -and $rDiag4.Count -eq 4 -and $rDiag4.Frame -eq 'plane')

# ----------------------------------------------------------------------------
# AXIS-FALLBACK GUARD: the axis is a valid normal only if the points have ~zero
# spread along it. In-plane axis -> rejected; perpendicular-to-row axis -> allowed.
# ----------------------------------------------------------------------------
Write-Host "  -- axis-fallback guard --" -ForegroundColor White

# 3 collinear points along X, axis ALSO (1,0,0) -> axis lies along the spread ->
# variance-along-axis = 1.0 -> REJECT (would collapse the row).
$rowX = @( (@(0.0,0.0,0.0)), (@(1.0,0.0,0.0)), (@(2.0,0.0,0.0)) )
$axInPlane = @( (@(1.0,0.0,0.0)), (@(1.0,0.0,0.0)), (@(1.0,0.0,0.0)) )
$frInPlane = Get-FastenerPlaneFrame -Centers $rowX -Axes $axInPlane -AxisX 'Y' -AxisZ 'Z'
Assert-True "guard: axis along the row spread -> axis-rejected, invalid" (-not $frInPlane.Valid -and $frInPlane.NormalSource -eq 'axis-rejected')

# same collinear row, axis (0,1,0) PERPENDICULAR to it -> variance-along-axis 0 ->
# legitimate single-row fallback stays VALID (NormalSource='axis').
$axPerp = @( (@(0.0,1.0,0.0)), (@(0.0,1.0,0.0)), (@(0.0,1.0,0.0)) )
$frPerp = Get-FastenerPlaneFrame -Centers $rowX -Axes $axPerp -AxisX 'X' -AxisZ 'Z'
Assert-True "guard: axis perpendicular to the row -> axis-fallback stays valid" ($frPerp.Valid -and $frPerp.NormalSource -eq 'axis')

# ----------------------------------------------------------------------------
# NON-COPLANAR GATE: holes spanning two faces -> Flatness high -> Valid=false.
# ----------------------------------------------------------------------------
$twoFace = @( (@(0.0,0.0,0.0)), (@(2.0,0.0,0.0)), (@(0.0,2.0,0.0)), (@(1.0,1.0,3.0)) )  # last point far off the Z=0 plane
$twoFaceAx = @( (@(0.0,0.0,1.0)), (@(0.0,0.0,1.0)), (@(0.0,0.0,1.0)), (@(0.0,0.0,1.0)) )
$rTwoFace = ConvertTo-LayoutXZ -Centers $twoFace -Axes $twoFaceAx -AxisX 'X' -AxisZ 'Y' -Margin 0.375 -DedupTol 0
Assert-True "gate: non-coplanar selection -> Valid=false (two surfaces)" (-not $rTwoFace.Valid)
Assert-True "gate: non-coplanar -> message names coplanar/surface" ((($rTwoFace.Errors) -join ' ') -match '(?i)coplanar|surface')

# ----------------------------------------------------------------------------
# Integration: fastener Points feed Get-CustomPointsGeometry unchanged
# ----------------------------------------------------------------------------
Write-Host "  -- integration with Get-CustomPointsGeometry --" -ForegroundColor White

$rInteg = ConvertTo-LayoutXZ -Centers $centers -AxisX 'X' -AxisZ 'Z' -Margin 0.5
$geo = Get-CustomPointsGeometry -Points $rInteg.Points -ClearDia 0.25 -HoleDia 0.25
Assert-True "integration: orthoGeo Valid" ($geo.Valid) (($geo.Errors) -join '; ')
Assert-True "integration: Mode custom" ($geo.Mode -eq 'custom')
Assert-True "integration: 4 holes (no origin drop)" ($geo.Count -eq 4)
Assert-True "integration: SkippedOrigin 0" ($geo.SkippedOrigin -eq 0)

# ----------------------------------------------------------------------------
# Test-FastenerLayoutSane
# ----------------------------------------------------------------------------
Write-Host "  -- Test-FastenerLayoutSane --" -ForegroundColor White

$sane = Test-FastenerLayoutSane -Layout $rInteg
Assert-True "sane: a good layout passes" ($sane.Ok) (($sane.Errors) -join '; ')

$saneNull = Test-FastenerLayoutSane -Layout $null
Assert-True "sane: null -> not ok, no throw" (-not $saneNull.Ok)

# degenerate: all points coincident (span 0 both axes) -> flagged unless single
$rCoin = ConvertTo-LayoutXZ -Centers @(@(3,0,3), @(3,0,3)) -AxisX 'X' -AxisZ 'Z' -Margin 0.5 -DedupTol 1e-9
# (two identical points, dedup 1e-9 keeps... they ARE identical so one merges)
$saneCoin = Test-FastenerLayoutSane -Layout $rCoin
Assert-True "sane: single merged point flagged unless -AllowSinglePoint" (
    (-not $saneCoin.Ok) -or ((Test-FastenerLayoutSane -Layout $rCoin -AllowSinglePoint).Ok))

# runaway extent (assembly-frame coords) -> flagged
$rHuge = ConvertTo-LayoutXZ -Centers @(@(0,0,0), @(500000,0,0)) -AxisX 'X' -AxisZ 'Z' -Margin 0.5
$saneHuge = Test-FastenerLayoutSane -Layout $rHuge -MaxExtent 1e5
Assert-True "sane: runaway span flagged" (-not $saneHuge.Ok)

# ----------------------------------------------------------------------------
# Set-LayoutMargin - re-anchor the near corner (build the plate around the holes)
# ----------------------------------------------------------------------------
Write-Host "  -- Set-LayoutMargin (re-anchor to jig hole margin) --" -ForegroundColor White

# start from a 2x2 with margin 0.25, then re-anchor to a LARGER jig-hole margin 0.5
$srcPts = (ConvertTo-LayoutXZ -Centers $centers -AxisX 'X' -AxisZ 'Z' -Margin 0.25).Points
$reanc = Set-LayoutMargin -Points $srcPts -Margin 0.5
Assert-True "reanchor: Valid" ($reanc.Valid) (($reanc.Errors) -join '; ')
Assert-True "reanchor: same count" ($reanc.Count -eq $srcPts.Count)
$rMinX = ($reanc.Points | ForEach-Object { $_.X } | Measure-Object -Minimum).Minimum
$rMinZ = ($reanc.Points | ForEach-Object { $_.Z } | Measure-Object -Minimum).Minimum
Assert-True "reanchor: min X == new margin" (Approx $rMinX 0.5)
Assert-True "reanchor: min Z == new margin" (Approx $rMinZ 0.5)
Assert-True "reanchor: every X >= margin" (@($reanc.Points | Where-Object { $_.X -lt 0.5 - 1e-12 }).Count -eq 0)
# the KEY invariant: relative spacing is preserved EXACTLY (pure translation).
$srcSpanX = (($srcPts | ForEach-Object { $_.X } | Measure-Object -Maximum).Maximum) - (($srcPts | ForEach-Object { $_.X } | Measure-Object -Minimum).Minimum)
$reSpanX  = (($reanc.Points | ForEach-Object { $_.X } | Measure-Object -Maximum).Maximum) - $rMinX
Assert-True "reanchor: X span preserved (pattern unchanged)" (Approx $srcSpanX $reSpanX)
# uniform shift: every point moved by the same delta
$dx0 = [double]$reanc.Points[0].X - [double]$srcPts[0].X
$uniform = $true
for ($k=0; $k -lt $srcPts.Count; $k++) { if (-not (Approx ([double]$reanc.Points[$k].X - [double]$srcPts[$k].X) $dx0)) { $uniform = $false } }
Assert-True "reanchor: uniform translation in X (all points shift equally)" $uniform
Assert-True "reanchor: Margin<=0 -> invalid, no throw" (-not (Set-LayoutMargin -Points $srcPts -Margin 0).Valid)
Assert-True "reanchor: empty -> invalid, no throw" (-not (Set-LayoutMargin -Points @() -Margin 0.5).Valid)

# THE BUG THIS FIXES: a layout captured with a SMALL fastener margin fails
# Get-CustomPointsGeometry's edge-margin check when built at a LARGER jig hole dia;
# re-anchoring to the jig hole dia makes it pass without moving the pattern.
$jigDia = 0.5
$smallMargin = (ConvertTo-LayoutXZ -Centers $centers -AxisX 'X' -AxisZ 'Z' -Margin 0.1).Points
$geoFail = Get-CustomPointsGeometry -Points $smallMargin -ClearDia $jigDia -HoleDia $jigDia
Assert-True "edge-margin bug reproduced: small border FAILS at jig dia" (-not $geoFail.Valid)
$fixedPts = (Set-LayoutMargin -Points $smallMargin -Margin $jigDia).Points
$geoFixed = Get-CustomPointsGeometry -Points $fixedPts -ClearDia $jigDia -HoleDia $jigDia
Assert-True "edge-margin FIX: re-anchored to jig dia PASSES" ($geoFixed.Valid) (($geoFixed.Errors) -join '; ')
Assert-True "edge-margin FIX: same hole count (no hole lost)" ($geoFixed.Count -eq @($smallMargin).Count)

# --- NEW RULE (user 2026-07-21): the border WALL must equal the hole DIAMETER --------
# The drilljig fastener path now re-anchors the near corner to 1.5x the jig hole dia
# (bore radius + one-diameter wall) and passes -EdgeMargin = the hole dia. So the
# nearest hole's edge is one FULL diameter from the part edge, and the derived plate
# grows to give the same wall on the far side. This is what "the edge margin should
# always be the same as the diameter of the hole" means for the imported layout.
Write-Host "  -- Set-LayoutMargin + EdgeMargin: wall = one full diameter --" -ForegroundColor White
$centerInset = $jigDia * 1.5
$diaPts   = (Set-LayoutMargin -Points $smallMargin -Margin $centerInset).Points
$geoDia   = Get-CustomPointsGeometry -Points $diaPts -ClearDia $jigDia -HoleDia $jigDia -EdgeMargin $jigDia
Assert-True "new rule: 1.5x re-anchor + EdgeMargin=dia PASSES" ($geoDia.Valid) (($geoDia.Errors) -join '; ')
Assert-True "new rule: no hole lost" ($geoDia.Count -eq @($smallMargin).Count)
# the nearest hole now sits one full diameter of WALL from the near edge (center at
# 1.5*dia -> wall = 1.5*dia - dia/2 = dia).
$nearX = ($geoDia.Points | ForEach-Object { $_.X } | Measure-Object -Minimum).Minimum
Assert-True "new rule: near-edge wall equals one full diameter" (Approx ($nearX - $jigDia/2.0) $jigDia)
# WHY we bumped to 1.5x: the OLD one-radius re-anchor (Margin = jigDia) now FAILS the
# stricter EdgeMargin=dia check (near wall = radius < diameter). This is the regression
# guard that keeps the re-anchor and the check in lockstep.
$oldAnchor = (Set-LayoutMargin -Points $smallMargin -Margin $jigDia).Points
$geoOldFail = Get-CustomPointsGeometry -Points $oldAnchor -ClearDia $jigDia -HoleDia $jigDia -EdgeMargin $jigDia
Assert-True "new rule: one-radius re-anchor FAILS the diameter check (why 1.5x)" (-not $geoOldFail.Valid)

# ----------------------------------------------------------------------------
# Write / Read round-trip (fastener_layout.json) - exact PascalCase
# ----------------------------------------------------------------------------
Write-Host "  -- Write/Read round-trip --" -ForegroundColor White

$tmp = Join-Path $env:TEMP ("fastener_layout_test_{0}.json" -f ([guid]::NewGuid().ToString('N')))
try {
    $wrote = Write-FastenerLayout -Path $tmp -Layout $rInteg -SourceModel 'bolts.prt' -Units 'inch' -ReadMethod 'cylinder-axis' -WhenIso '2026-07-20T00:00:00Z'
    Assert-True "write: returns true" ($wrote)
    Assert-True "write: file exists" (Test-Path $tmp)

    $back = Read-FastenerLayout -Path $tmp
    Assert-True "read: Valid" ($back.Valid) (($back.Errors) -join '; ')
    Assert-True "read: same count" ($back.Count -eq $rInteg.Count)
    Assert-True "read: source model preserved" ($back.SourceModel -eq 'bolts.prt')
    Assert-True "read: units preserved" ($back.Units -eq 'inch')
    Assert-True "read: AxisX preserved" ($back.AxisX -eq 'X')
    Assert-True "read: AxisZ preserved" ($back.AxisZ -eq 'Z')
    Assert-True "read: ReadMethod preserved" ($back.ReadMethod -eq 'cylinder-axis')
    # coordinates survive the round-trip
    $matchAll = $true
    for ($k = 0; $k -lt $rInteg.Count; $k++) {
        $a = $rInteg.Points[$k]; $b = $back.Points[$k]
        if (-not ((Approx $a.X $b.X 1e-9) -and (Approx $a.Z $b.Z 1e-9))) { $matchAll = $false }
    }
    Assert-True "read: every (X,Z) matches what was written" $matchAll
    # read result is shape-usable by Get-CustomPointsGeometry
    $geo2 = Get-CustomPointsGeometry -Points $back.Points -ClearDia 0.25 -HoleDia 0.25
    Assert-True "read: feeds Get-CustomPointsGeometry" ($geo2.Valid -and $geo2.Count -eq $rInteg.Count)
} finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

$rMissing = Read-FastenerLayout -Path (Join-Path $env:TEMP 'definitely_not_here_12345.json')
Assert-True "read: missing file -> invalid, no throw" (-not $rMissing.Valid)

# ----------------------------------------------------------------------------
# SUMMARY
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ("  fastener-layout tests: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { "Green" } else { "Red" })
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ""
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
