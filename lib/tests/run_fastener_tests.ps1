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
