# ============================================================================
# lib\tests\run_curved_radial_tests.ps1 - offline unit tests for lib\curved_radial.ps1
# ============================================================================
# curved_radial.ps1 is the PURE radial/axis-pattern PLANNING math for the curved
# drill jig's chip relief: Get-CurvedRadialAzimuths (project positions -> azimuths
# about a rotation axis) + Get-CurvedRadialPatternPlan (count / angular increment /
# seed / uniform-spacing gate) + Test-CurvedRadialPatternPlan (a cheap safety gate).
# No COM anywhere - dot-source it directly and assert the arithmetic on known rings/
# arcs. The whole point of this suite: prove the "can we pattern? at what increment?"
# decision is correct + never-throws BEFORE any Creo axis-pattern is fired.
#
# Run:  powershell -ExecutionPolicy Bypass -File lib\tests\run_curved_radial_tests.ps1
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
function Approx { param([double]$A, [double]$B, [double]$Tol = 1e-6) return ([Math]::Abs($A - $B) -le $Tol) }

. (Join-Path $libDir 'curved_radial.ps1')

# ----------------------------------------------------------------------------
# helper: N fasteners evenly spaced on a circle of radius R in the Z=z0 plane
# (rotation axis = +Z), starting at angle startDeg, stepping stepDeg. Returns the
# @(x,y,z) list. A partial arc uses stepDeg*(N-1) < 360.
# ----------------------------------------------------------------------------
function Make-Ring {
    param([int]$N, [double]$R = 5.0, [double]$StartDeg = 0.0, [double]$StepDeg = 0.0, [double]$Z = 2.0, [double]$Cx = 10.0, [double]$Cy = -3.0)
    if ($StepDeg -le 0) { $StepDeg = 360.0 / $N }
    $out = @()
    for ($i = 0; $i -lt $N; $i++) {
        $a = ($StartDeg + $i * $StepDeg) * [Math]::PI / 180.0
        $x = $Cx + $R * [Math]::Cos($a)
        $y = $Cy + $R * [Math]::Sin($a)
        $out += ,@([double]$x, [double]$y, [double]$Z)
    }
    return $out
}

Write-Host ""
Write-Host "  -- curved_radial: full even circle --" -ForegroundColor White
# 4 fasteners at 90 deg spacing, full circle about +Z.
$ring4 = Make-Ring -N 4 -R 5.0 -StartDeg 0.0
$p4 = Get-CurvedRadialPatternPlan -Positions $ring4
Assert-True "4-ring: Valid"                 ([bool]$p4.Valid)
Assert-True "4-ring: CanPattern"            ([bool]$p4.CanPattern) ("reason=" + $p4.Reason)
Assert-True "4-ring: Count == 4"            ([int]$p4.Count -eq 4)
Assert-True "4-ring: increment ~ 90 deg"    (Approx ([double]$p4.IncrementDeg) 90.0 1e-3) ("got " + $p4.IncrementDeg)
Assert-True "4-ring: FullCircle"            ([bool]$p4.FullCircle)
Assert-True "4-ring: RadiusMean ~ 5"        (Approx ([double]$p4.RadiusMean) 5.0 1e-6)
Assert-True "4-ring: SeedIndex in range"    ([int]$p4.SeedIndex -ge 0 -and [int]$p4.SeedIndex -lt 4)
Assert-True "4-ring: gate Ok"               ([bool](Test-CurvedRadialPatternPlan $p4).Ok)

Write-Host ""
Write-Host "  -- curved_radial: 6-ring 60 deg --" -ForegroundColor White
$ring6 = Make-Ring -N 6 -R 3.25
$p6 = Get-CurvedRadialPatternPlan -Positions $ring6
Assert-True "6-ring: CanPattern + count 6 + inc 60" ([bool]$p6.CanPattern -and [int]$p6.Count -eq 6 -and (Approx ([double]$p6.IncrementDeg) 60.0 1e-3))
Assert-True "6-ring: FullCircle"            ([bool]$p6.FullCircle)

Write-Host ""
Write-Host "  -- curved_radial: partial ARC (uniform) --" -ForegroundColor White
# 5 fasteners, 20 deg apart, arc spans 80 deg (NOT a full circle).
$arc = Make-Ring -N 5 -R 4.0 -StartDeg 10.0 -StepDeg 20.0
$pa = Get-CurvedRadialPatternPlan -Positions $arc
Assert-True "arc: CanPattern"               ([bool]$pa.CanPattern) ("reason=" + $pa.Reason)
Assert-True "arc: count 5 + inc ~ 20"       ([int]$pa.Count -eq 5 -and (Approx ([double]$pa.IncrementDeg) 20.0 1e-3)) ("inc=" + $pa.IncrementDeg)
Assert-True "arc: NOT FullCircle"           (-not [bool]$pa.FullCircle)
# the seed must be an ARC ENDPOINT (min OR max azimuth), so +increment steps across the arc.
# Azimuths is in ORIGINAL input order, so index it by SeedIndex directly.
$azMin = ($pa.Azimuths | Measure-Object -Minimum).Minimum
$azMax = ($pa.Azimuths | Measure-Object -Maximum).Maximum
$seedAz = [double]$pa.Azimuths[$pa.SeedIndex]
Assert-True "arc: seed is an endpoint (min or max azimuth)" ((Approx $seedAz $azMin 1e-6) -or (Approx $seedAz $azMax 1e-6)) ("seedAz=$seedAz min=$azMin max=$azMax")

Write-Host ""
Write-Host "  -- curved_radial: TWO fasteners (the user's mapkey case, count=2) --" -ForegroundColor White
# 2 fasteners 30 deg apart on a circle centered (10,-3) r=6 in Z=2. Two points alone
# can't fit a circle center, so N==2 auto-planning needs an EXPLICIT axis + point (the
# operator picks the axis anyway); WITH them -> count 2, increment = the 30 deg between.
$two = Make-Ring -N 2 -R 6.0 -StartDeg 5.0 -StepDeg 30.0 -Cx 10.0 -Cy -3.0 -Z 2.0
$p2 = Get-CurvedRadialPatternPlan -Positions $two -Axis @(0.0,0.0,1.0) -AxisPoint @(10.0,-3.0,2.0)
Assert-True "2-fastener (axis+pt): CanPattern" ([bool]$p2.CanPattern) ("reason=" + $p2.Reason)
Assert-True "2-fastener (axis+pt): count 2"    ([int]$p2.Count -eq 2)
Assert-True "2-fastener (axis+pt): inc ~ 30"   (Approx ([double]$p2.IncrementDeg) 30.0 1e-3) ("got " + $p2.IncrementDeg)
# WITHOUT an explicit center, 2 fasteners cannot be auto-planned (draw both by hand).
$p2n = Get-CurvedRadialPatternPlan -Positions $two
Assert-True "2-fastener (no axis): NOT CanPattern (falls back to per-fastener)" (-not [bool]$p2n.CanPattern)

Write-Host ""
Write-Host "  -- curved_radial: NON-uniform -> CanPattern false (per-fastener fallback) --" -ForegroundColor White
# 4 points at 0, 90, 100, 200 deg -> gaps 90,10,100,60 (excluding opening still non-uniform).
$nonU = @()
foreach ($deg in @(0.0, 90.0, 100.0, 200.0)) { $a=$deg*[Math]::PI/180.0; $nonU += ,@([double](10+5*[Math]::Cos($a)), [double](-3+5*[Math]::Sin($a)), 2.0) }
$pn = Get-CurvedRadialPatternPlan -Positions $nonU
Assert-True "non-uniform: Valid but NOT CanPattern" ([bool]$pn.Valid -and -not [bool]$pn.CanPattern)
Assert-True "non-uniform: Reason names the spacing" ([string]$pn.Reason -match '(?i)uniform')
Assert-True "non-uniform: gate Ok is false"         (-not [bool](Test-CurvedRadialPatternPlan $pn).Ok)

Write-Host ""
Write-Host "  -- curved_radial: tolerance band (near-uniform passes, wide fails) --" -ForegroundColor White
# perturb one point of a 6-ring by ~1 deg -> passes at TolDeg 2, fails at TolDeg 0.5
$ring6b = Make-Ring -N 6 -R 4.0
# nudge index 3 by +1.0 deg along the circle
$a3 = (180.0 + 1.0) * [Math]::PI / 180.0
$ring6b[3] = @([double](10 + 4.0*[Math]::Cos($a3)), [double](-3 + 4.0*[Math]::Sin($a3)), 2.0)
$pTolOk  = Get-CurvedRadialPatternPlan -Positions $ring6b -TolDeg 3.0
$pTolNo  = Get-CurvedRadialPatternPlan -Positions $ring6b -TolDeg 0.25
Assert-True "near-uniform passes at TolDeg 3"   ([bool]$pTolOk.CanPattern)
Assert-True "near-uniform fails at TolDeg 0.25" (-not [bool]$pTolNo.CanPattern)

Write-Host ""
Write-Host "  -- curved_radial: overrides (Read-radial-distance seam) --" -ForegroundColor White
$pOv = Get-CurvedRadialPatternPlan -Positions $ring4 -IncrementDegOverride 45.0 -CountOverride 8
Assert-True "override: increment replaced"  (Approx ([double]$pOv.IncrementDeg) 45.0 1e-6)
Assert-True "override: count replaced"      ([int]$pOv.Count -eq 8)
Assert-True "override: still CanPattern"    ([bool]$pOv.CanPattern)
Assert-True "override: Warnings note it"    ((@($pOv.Warnings) -join ' ') -match '(?i)overrid')

Write-Host ""
Write-Host "  -- curved_radial: degenerate / malformed inputs never throw --" -ForegroundColor White
$threw = $false
try {
    $r1 = Get-CurvedRadialPatternPlan -Positions $null
    $r2 = Get-CurvedRadialPatternPlan -Positions @()
    $r3 = Get-CurvedRadialPatternPlan -Positions @( ,@(1.0,2.0,3.0) )                       # 1 point
    $r4 = Get-CurvedRadialPatternPlan -Positions @( @(0,0,0), @(1,0,0), @(2,0,0), @(3,0,0) ) # collinear
    $r5 = Get-CurvedRadialPatternPlan -Positions @( @('a','b','c'), $null, @(1,1) )          # malformed
    $r6 = Get-CurvedRadialPatternPlan -Positions @( @(0,0,0), @(0,0,0), @(0,0,0) )           # coincident
    Assert-True "null -> Valid false"          (-not [bool]$r1.Valid)
    Assert-True "empty -> Valid false"         (-not [bool]$r2.Valid)
    Assert-True "1 point -> not CanPattern"    (-not [bool]$r3.CanPattern)
    Assert-True "collinear -> not CanPattern"  (-not [bool]$r4.CanPattern)
    Assert-True "malformed -> not CanPattern"  (-not [bool]$r5.CanPattern)
    Assert-True "coincident -> not CanPattern" (-not [bool]$r6.CanPattern)
    Assert-True "gate on null plan Ok=false"   (-not [bool](Test-CurvedRadialPatternPlan $null).Ok)
} catch { $threw = $true; Write-Host "    THREW: $($_.Exception.Message)" -ForegroundColor Red }
Assert-True "no throw across degenerate inputs" (-not $threw)

Write-Host ""
Write-Host "  -- curved_radial: azimuths are axis-supplied-consistent --" -ForegroundColor White
# supply the axis explicitly (+Z) and a point on it; count/increment must match derived.
$pAxis = Get-CurvedRadialPatternPlan -Positions $ring4 -Axis @(0.0,0.0,1.0) -AxisPoint @(10.0,-3.0,2.0)
Assert-True "supplied-axis: CanPattern + inc 90" ([bool]$pAxis.CanPattern -and (Approx ([double]$pAxis.IncrementDeg) 90.0 1e-3))

Write-Host ""
Write-Host "  -- Get-CylinderFromFasteners (radius + axis + center) --" -ForegroundColor White
# 4-ring R=5 about +Z centered (10,-3,2): derive -> R~5, spread~0, axis ~ +/-Z.
$cyl = Get-CylinderFromFasteners -Positions $ring4
Assert-True "cyl(derived): Valid"            ([bool]$cyl.Valid) ("reason=" + $cyl.Reason)
Assert-True "cyl(derived): Radius ~ 5"       (Approx ([double]$cyl.Radius) 5.0 1e-4) ("got " + $cyl.Radius)
Assert-True "cyl(derived): spread ~ 0"       (Approx ([double]$cyl.RadiusSpread) 0.0 1e-4)
Assert-True "cyl(derived): axis is unit +/-Z" ((Approx ([Math]::Abs([double]$cyl.AxisDir[2])) 1.0 1e-6) -and (Approx ([double]$cyl.AxisDir[0]) 0.0 1e-6) -and (Approx ([double]$cyl.AxisDir[1]) 0.0 1e-6))
Assert-True "cyl(derived): Count 4"          ([int]$cyl.Count -eq 4)
# supplied axis+point -> same radius; works for N=2 too.
$cyl2 = Get-CylinderFromFasteners -Positions $two -Axis @(0.0,0.0,1.0) -AxisPoint @(10.0,-3.0,2.0)
Assert-True "cyl(N=2, axis+pt): Valid + R ~ 6" ([bool]$cyl2.Valid -and (Approx ([double]$cyl2.Radius) 6.0 1e-4)) ("got " + $cyl2.Radius)
# non-cylinder (collinear) -> not Valid, never throws.
$cylBad = Get-CylinderFromFasteners -Positions @( @(0,0,0), @(1,0,0), @(2,0,0), @(3,0,0) )
Assert-True "cyl(collinear): not Valid"      (-not [bool]$cylBad.Valid)
# a two-radius set (inner + outer ring) flags a nonzero spread advisory.
$mixed = @()
foreach ($deg in @(0.0,90.0,180.0,270.0)) { $a=$deg*[Math]::PI/180.0; $mixed += ,@([double](10+5*[Math]::Cos($a)),[double](-3+5*[Math]::Sin($a)),2.0) }
foreach ($deg in @(45.0,135.0,225.0,315.0)) { $a=$deg*[Math]::PI/180.0; $mixed += ,@([double](10+8*[Math]::Cos($a)),[double](-3+8*[Math]::Sin($a)),2.0) }
$cylMix = Get-CylinderFromFasteners -Positions $mixed -Axis @(0.0,0.0,1.0) -AxisPoint @(10.0,-3.0,2.0)
Assert-True "cyl(two-radius): spread > 0 (advisory)" ([double]$cylMix.RadiusSpread -gt 1.0)

Write-Host ""
Write-Host "  -- Get-CurvedRadialPatternGroups (multi-pattern) --" -ForegroundColor White
# uniform 4-ring -> ONE regular group, count 4, inc 90, no accommodations.
$g4 = Get-CurvedRadialPatternGroups -Positions $ring4
Assert-True "groups(uniform): Valid + 1 group"      ([bool]$g4.Valid -and [int]$g4.PatternCount -eq 1)
Assert-True "groups(uniform): regular count 4 @ 90" (([string]$g4.Groups[0].Kind -eq 'regular') -and [int]$g4.Groups[0].Count -eq 4 -and (Approx ([double]$g4.Groups[0].Increment) 90.0 1e-3))
Assert-True "groups(uniform): Count == N == 4"      ([int]$g4.Count -eq 4)
Assert-True "groups(uniform): SeedIndex in range"   ([int]$g4.SeedIndex -ge 0 -and [int]$g4.SeedIndex -lt 4)
# NON-uniform: seed + {30,60,90 (regular pitch 30, 3 copies)} + a stray at 200 -> 1 regular(count4) + 1 accommodation(count2).
$mp = @()
foreach ($deg in @(0.0,30.0,60.0,90.0,200.0)) { $a=$deg*[Math]::PI/180.0; $mp += ,@([double](10+5*[Math]::Cos($a)),[double](-3+5*[Math]::Sin($a)),2.0) }
$gm = Get-CurvedRadialPatternGroups -Positions $mp -Axis @(0.0,0.0,1.0) -AxisPoint @(10.0,-3.0,2.0)
Assert-True "groups(mixed): Valid"                  ([bool]$gm.Valid) ("reason=" + $gm.Reason)
$reg = @($gm.Groups | Where-Object { $_.Kind -eq 'regular' })
$acc = @($gm.Groups | Where-Object { $_.Kind -eq 'accommodation' })
Assert-True "groups(mixed): 1 regular @ pitch 30"   (@($reg).Count -eq 1 -and (Approx ([double]$reg[0].Increment) 30.0 1e-2))
Assert-True "groups(mixed): regular covers 4 (0/30/60/90)" ([int]$reg[0].Count -eq 4)
Assert-True "groups(mixed): >=1 accommodation (the 200-deg stray)" (@($acc).Count -ge 1)
# EVERY fastener is covered exactly once (seed + sum of copies == N).
$coverage = 1; foreach ($g in $gm.Groups) { $coverage += ([int]$g.Count - 1) }
Assert-True "groups(mixed): total coverage == N (5)" ($coverage -eq [int]$gm.Count -and [int]$gm.Count -eq 5) ("coverage=$coverage N=" + $gm.Count)
# malformed / degenerate never throw.
$threwG = $false
try {
    $gn = Get-CurvedRadialPatternGroups -Positions $null
    $g1 = Get-CurvedRadialPatternGroups -Positions @( ,@(1.0,2.0,3.0) )
    Assert-True "groups(null): not Valid"       (-not [bool]$gn.Valid)
    Assert-True "groups(1 pt): Valid, 0 patterns (draw one)" ([bool]$g1.Valid -and [int]$g1.PatternCount -eq 0)
} catch { $threwG = $true; Write-Host "    THREW: $($_.Exception.Message)" -ForegroundColor Red }
Assert-True "groups: no throw on degenerate input" (-not $threwG)

# NEAR-DUPLICATE trap (review F1 2026-07-31): a fastener at 101 deg sits WITHIN TolDeg(2) of the
# regular pitch's covered multiple 100, but the regular pattern plants its copy at EXACTLY 100 --
# so 101 is NOT served and MUST get its own accommodation. The old proximity-to-multiple skip
# dropped it (coverage 3, not 4). Assert it is now covered exactly once.
$nd = @()
foreach ($deg in @(0.0,100.0,101.0,200.0)) { $a=$deg*[Math]::PI/180.0; $nd += ,@([double](10+5*[Math]::Cos($a)),[double](-3+5*[Math]::Sin($a)),2.0) }
$gnd = Get-CurvedRadialPatternGroups -Positions $nd -Axis @(0.0,0.0,1.0) -AxisPoint @(10.0,-3.0,2.0) -TolDeg 2.0
Assert-True "groups(near-dup): Valid" ([bool]$gnd.Valid) ("reason=" + $gnd.Reason)
$covnd = 1; foreach ($g in $gnd.Groups) { $covnd += ([int]$g.Count - 1) }
Assert-True "groups(near-dup): coverage == N == 4 (101-deg fastener NOT dropped)" ($covnd -eq 4 -and [int]$gnd.Count -eq 4) ("coverage=$covnd N=" + $gnd.Count + " groups=" + (@($gnd.Groups | ForEach-Object { '{0}:{1}@{2}' -f $_.Kind,$_.Count,$_.Increment }) -join ' '))
$accnd = @($gnd.Groups | Where-Object { $_.Kind -eq 'accommodation' })
Assert-True "groups(near-dup): the 101-deg stray got an accommodation" (@($accnd).Count -ge 1)

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ("  curved_radial tests: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
Write-Host "  ============================================" -ForegroundColor Cyan
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
