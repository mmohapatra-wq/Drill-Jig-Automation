# ============================================================================
# lib\tests\run_orthogrid_tests.ps1 - offline unit tests for lib\orthogrid.ps1
# ============================================================================
# Runs WITHOUT Creo and WITHOUT network. Exercises the pure orthogrid layout
# math (plate Width/Height, point Count, the point grid, and the input-
# validation / never-throw contract). Mirrors run_tests.ps1: $ErrorActionPreference
# 'Stop', dot-source the lib via Split-Path of $MyInvocation, Assert-True/Approx
# helpers, exit 0 all-pass / 1 any-fail.
#
# Run:  powershell -ExecutionPolicy Bypass -File lib\tests\run_orthogrid_tests.ps1
# Exit code 0 = all passed, 1 = at least one failure.
# ============================================================================

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here
. (Join-Path $libDir 'orthogrid.ps1')
. (Join-Path $libDir 'orthogrid_points.ps1')

# Build-PointGridMacro calls Get-SelectByIdMacro, which lives in the consuming
# .cmd (drilljig.cmd). Stub it here so the pure-string macro builder is testable
# offline: the stub emits an unmistakable marker carrying the FeatId so the test
# can assert the SIDE base datum was selected first.
function Get-SelectByIdMacro {
    param([int]$FeatId, [switch]$NoClear)
    # Distinguish -NoClear (accumulate) from default (clear) so
    # Build-IntersectPointMacro tests can verify the accumulation pattern.
    if ($NoClear) { return "SELBYID_NC($FeatId);" }
    return "SELBYID($FeatId);"
}
# Build-PointPatternMacro also calls Get-SelectDatumByIdMacro (drilljig-defined) to
# feed the direction reference by id. Stub it with a distinct marker.
function Get-SelectDatumByIdMacro {
    param([int]$FeatId)
    return "SELDATUM($FeatId);"
}
# (Get-SelectEdgeByIdMacro stub removed 2026-06-25 with Build-EdgePlanePointMacro --
# selecting an edge by ID doesn't load on the foreign body; STAGE 6 now uses the
# 3-plane intersection + Resolve-EdgeAxis, tested below.)

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
Write-Host "  Running orthogrid unit tests (offline)..." -ForegroundColor Cyan
Write-Host ""

# ----------------------------------------------------------------------------
# Width / Height formula on a normal grid
# ----------------------------------------------------------------------------
Write-Host "  -- orthogrid: Width / Height --" -ForegroundColor White

# 4 x 3 grid, cc 2.0 / 1.5, edge 0.5
#   Width  = (4-1)*2.0 + 2*0.5 = 6.0 + 1.0 = 7.0
#   Height = (3-1)*1.5 + 2*0.5 = 3.0 + 1.0 = 4.0
$g = Get-OrthogridGeometry -CcX 2.0 -CcZ 1.5 -Nx 4 -Nz 3 -Edge 0.5
Assert-True "Width  = (Nx-1)*CcX + 2*Edge" (Approx $g.Width 7.0)
Assert-True "Height = (Nz-1)*CcZ + 2*Edge" (Approx $g.Height 4.0)

# echo of inputs
Assert-True "echoes inputs" `
    ((Approx $g.CcX 2.0) -and (Approx $g.CcZ 1.5) -and ($g.Nx -eq 4) -and ($g.Nz -eq 3) -and (Approx $g.Edge 0.5))
Assert-True "ClearDia defaults to 0 (original behaviour)" (Approx $g.ClearDia 0.0)

# ----------------------------------------------------------------------------
# ClearDia: plate Width/Height gain the (relief) diameter; points inset by dia/2.
# ----------------------------------------------------------------------------
Write-Host "  -- orthogrid: ClearDia (relief clearance) --" -ForegroundColor White

# same 4x3 grid + ClearDia 0.75 (= relief dia):
#   Width  = (4-1)*2.0 + 2*0.5 + 0.75 = 7.0 + 0.75 = 7.75
#   Height = (3-1)*1.5 + 2*0.5 + 0.75 = 4.0 + 0.75 = 4.75
$gc = Get-OrthogridGeometry -CcX 2.0 -CcZ 1.5 -Nx 4 -Nz 3 -Edge 0.5 -ClearDia 0.75
Assert-True "ClearDia adds to Width  (+ClearDia)" (Approx $gc.Width 7.75)
Assert-True "ClearDia adds to Height (+ClearDia)" (Approx $gc.Height 4.75)
Assert-True "ClearDia echoed on result" (Approx $gc.ClearDia 0.75)
# first point CENTERED: inset = Edge + ClearDia/2 = 0.5 + 0.375 = 0.875
# (the centering fix: equal margin on both sides of the grid, not shifted left)
Assert-True "first point centered (Edge + ClearDia/2)" `
    ((Approx $gc.Points[0].X 0.875) -and (Approx $gc.Points[0].Z 0.875))
# the grid still spans (Nx-1)*CcX between first and last point centres
$lastc = $gc.Points[$gc.Points.Count - 1]
Assert-True "ClearDia does not change the point SPAN (centres)" `
    ((Approx ($lastc.X - $gc.Points[0].X) 6.0) -and (Approx ($lastc.Z - $gc.Points[0].Z) 3.0))
# negative ClearDia is invalid (but never throws)
$gcBad = Get-OrthogridGeometry -CcX 2.0 -CcZ 1.5 -Nx 4 -Nz 3 -Edge 0.5 -ClearDia -1.0
Assert-True "ClearDia<0 -> Valid false" (-not $gcBad.Valid)

# ----------------------------------------------------------------------------
# Single-column / single-row edge cases (Nx=1, Nz=1)
# ----------------------------------------------------------------------------
Write-Host "  -- orthogrid: Nx=1 / Nz=1 edge cases --" -ForegroundColor White

# Nx=1: Width = (1-1)*CcX + 2*Edge = 2*Edge, single X coord = Edge
$gNx1 = Get-OrthogridGeometry -CcX 2.0 -CcZ 1.5 -Nx 1 -Nz 3 -Edge 0.5
Assert-True "Nx=1 -> Width = 2*Edge" (Approx $gNx1.Width 1.0)
Assert-True "Nx=1 -> Height unaffected" (Approx $gNx1.Height 4.0)
Assert-True "Nx=1 -> Count = 1*Nz" ($gNx1.Count -eq 3)
Assert-True "Nx=1 -> all points share X = Edge" `
    (@($gNx1.Points | Where-Object { Approx $_.X 0.5 }).Count -eq 3)

# Nz=1: Height = 2*Edge, single Z coord = Edge
$gNz1 = Get-OrthogridGeometry -CcX 2.0 -CcZ 1.5 -Nx 4 -Nz 1 -Edge 0.5
Assert-True "Nz=1 -> Height = 2*Edge" (Approx $gNz1.Height 1.0)
Assert-True "Nz=1 -> Width unaffected" (Approx $gNz1.Width 7.0)
Assert-True "Nz=1 -> Count = Nx*1" ($gNz1.Count -eq 4)
Assert-True "Nz=1 -> all points share Z = Edge" `
    (@($gNz1.Points | Where-Object { Approx $_.Z 0.5 }).Count -eq 4)

# 1x1: a single point, plate is 2*Edge square
$g1x1 = Get-OrthogridGeometry -CcX 2.0 -CcZ 1.5 -Nx 1 -Nz 1 -Edge 0.5
Assert-True "1x1 -> Width = Height = 2*Edge" ((Approx $g1x1.Width 1.0) -and (Approx $g1x1.Height 1.0))
Assert-True "1x1 -> Count = 1" ($g1x1.Count -eq 1)
Assert-True "1x1 -> the single point is at (Edge,Edge)" `
    ($g1x1.Points.Count -eq 1 -and (Approx $g1x1.Points[0].X 0.5) -and (Approx $g1x1.Points[0].Z 0.5))

# Edge = 0 is legal (>= 0): width collapses to the point span exactly
$gE0 = Get-OrthogridGeometry -CcX 2.0 -CcZ 1.5 -Nx 4 -Nz 3 -Edge 0.0
Assert-True "Edge=0 -> Width = (Nx-1)*CcX" (Approx $gE0.Width 6.0)
Assert-True "Edge=0 -> first point at origin (0,0)" `
    ((Approx $gE0.Points[0].X 0.0) -and (Approx $gE0.Points[0].Z 0.0))

# ----------------------------------------------------------------------------
# Count
# ----------------------------------------------------------------------------
Write-Host "  -- orthogrid: Count --" -ForegroundColor White

Assert-True "Count = Nx*Nz" ($g.Count -eq 12)

# ----------------------------------------------------------------------------
# Points: count, first point, last point, ordering
# ----------------------------------------------------------------------------
Write-Host "  -- orthogrid: Points --" -ForegroundColor White

Assert-True "Points count == Nx*Nz" ($g.Points.Count -eq 12)

# first point == (Edge, Edge)
Assert-True "first point == (Edge, Edge)" `
    ((Approx $g.Points[0].X 0.5) -and (Approx $g.Points[0].Z 0.5))
Assert-True "first point indices are (0,0)" `
    ($g.Points[0].I -eq 0 -and $g.Points[0].J -eq 0)

# last point == (Edge+(Nx-1)*CcX, Edge+(Nz-1)*CcZ) = (0.5+6.0, 0.5+3.0) = (6.5, 3.5)
$last = $g.Points[$g.Points.Count - 1]
Assert-True "last point == (Edge+(Nx-1)*CcX, Edge+(Nz-1)*CcZ)" `
    ((Approx $last.X 6.5) -and (Approx $last.Z 3.5))
Assert-True "last point indices are (Nx-1, Nz-1)" `
    ($last.I -eq 3 -and $last.J -eq 2)

# ordering: I outer, J inner -> the first Nz points share I=0 and J cycles 0..Nz-1
Assert-True "ordering is I outer, J inner (first Nz points share I=0)" `
    (@($g.Points[0..2] | Where-Object { $_.I -eq 0 }).Count -eq 3 -and `
     $g.Points[0].J -eq 0 -and $g.Points[1].J -eq 1 -and $g.Points[2].J -eq 2)
# the (Nz+1)th point steps I to 1, J back to 0
Assert-True "ordering steps I after J wraps" `
    ($g.Points[3].I -eq 1 -and $g.Points[3].J -eq 0)

# point coordinates follow X = Edge + I*CcX, Z = Edge + J*CcZ for an interior point
$pInterior = $g.Points | Where-Object { $_.I -eq 2 -and $_.J -eq 1 } | Select-Object -First 1
Assert-True "interior point coords = (Edge+I*CcX, Edge+J*CcZ)" `
    ($null -ne $pInterior -and (Approx $pInterior.X 4.5) -and (Approx $pInterior.Z 2.0))

# ----------------------------------------------------------------------------
# Valid = true on good input; Errors empty
# ----------------------------------------------------------------------------
Write-Host "  -- orthogrid: Valid (good input) --" -ForegroundColor White

Assert-True "Valid is true on good input" ($g.Valid)
Assert-True "Errors empty when Valid" ($g.Errors.Count -eq 0)

# ----------------------------------------------------------------------------
# Valid = false + Errors non-empty on bad input (and NO throw)
# ----------------------------------------------------------------------------
Write-Host "  -- orthogrid: Valid (bad input, never throws) --" -ForegroundColor White

# CcX <= 0
$bCcX = Get-OrthogridGeometry -CcX 0.0 -CcZ 1.5 -Nx 4 -Nz 3 -Edge 0.5
Assert-True "CcX<=0 -> Valid false" (-not $bCcX.Valid)
Assert-True "CcX<=0 -> Errors non-empty" ($bCcX.Errors.Count -ge 1)

$bCcXneg = Get-OrthogridGeometry -CcX -1.0 -CcZ 1.5 -Nx 4 -Nz 3 -Edge 0.5
Assert-True "CcX<0 -> Valid false" (-not $bCcXneg.Valid)

# CcZ <= 0
$bCcZ = Get-OrthogridGeometry -CcX 2.0 -CcZ 0.0 -Nx 4 -Nz 3 -Edge 0.5
Assert-True "CcZ<=0 -> Valid false" (-not $bCcZ.Valid)

# Nx < 1
$bNx = Get-OrthogridGeometry -CcX 2.0 -CcZ 1.5 -Nx 0 -Nz 3 -Edge 0.5
Assert-True "Nx<1 -> Valid false" (-not $bNx.Valid)
Assert-True "Nx<1 -> Errors non-empty" ($bNx.Errors.Count -ge 1)
Assert-True "Nx<1 -> Points empty (best-effort, no throw)" ($bNx.Points.Count -eq 0)
Assert-True "Nx<1 -> Count 0" ($bNx.Count -eq 0)

# Nz < 1
$bNz = Get-OrthogridGeometry -CcX 2.0 -CcZ 1.5 -Nx 4 -Nz -2 -Edge 0.5
Assert-True "Nz<1 -> Valid false" (-not $bNz.Valid)

# Edge < 0
$bEdge = Get-OrthogridGeometry -CcX 2.0 -CcZ 1.5 -Nx 4 -Nz 3 -Edge -0.5
Assert-True "Edge<0 -> Valid false" (-not $bEdge.Valid)
Assert-True "Edge<0 -> Errors non-empty" ($bEdge.Errors.Count -ge 1)

# multiple bad inputs -> multiple errors collected (does not short-circuit)
$bMulti = Get-OrthogridGeometry -CcX 0.0 -CcZ -1.0 -Nx 0 -Nz 0 -Edge -1.0
Assert-True "multiple bad inputs collect multiple errors" ($bMulti.Errors.Count -ge 2)

# explicit never-throws guard: wrap a deliberately broken call in try/catch
$threw = $false
try { $null = Get-OrthogridGeometry -CcX 0.0 -CcZ 0.0 -Nx 0 -Nz 0 -Edge -9.0 } catch { $threw = $true }
Assert-True "Get-OrthogridGeometry does NOT throw on bad input" (-not $threw)

# ----------------------------------------------------------------------------
# Build-PointGridMacro -- pure-string macro builder (UNVERIFIED widgets, but the
# STRUCTURE is testable: one row triple per point, SIDE selected first, atomic
# single string, correct backtick escaping, X/Z values embedded).
# ----------------------------------------------------------------------------
Write-Host "  -- orthogrid: Build-PointGridMacro --" -ForegroundColor White

$gm  = Get-OrthogridGeometry -CcX 1.0 -CcZ 2.0 -Nx 3 -Nz 2 -Edge 0.5   # 6 points
$mac = Build-PointGridMacro -Points $gm.Points -SideBaseId 11 -TopBaseId 22 -FrontBaseId 33

Assert-True "macro is a single String (atomic RunMacro)" ($mac -is [string])

# SIDE base datum selected first (our stub marker carries the FeatId).
Assert-True "selects SIDE base datum (id 11) first via Get-SelectByIdMacro" `
    ($mac.StartsWith("SELBYID(11);"))

# one add-row per point; one X cell + one Z cell per point.
Assert-True "one add_pnt_btn per point (Count)" `
    ([regex]::Matches($mac, 'add_pnt_btn').Count -eq $gm.Count)
Assert-True "one xax_axis cell per point" `
    ([regex]::Matches($mac, 'xax_axis').Count -eq $gm.Count)
Assert-True "one zax_axis cell per point" `
    ([regex]::Matches($mac, 'zax_axis').Count -eq $gm.Count)

# the datum-point command + dialog OK are present, wrapped in SINGLE backticks
# (the escaped double-backticks in the builder must collapse to one in the
# returned string). Single-quoted literals below contain real backtick chars.
Assert-True "fires ProCmdDatumPoint (single-backtick token)" `
    ($mac.Contains('`ProCmdDatumPoint`'))
Assert-True "commits with the dialog OK (stdbtn_1, single-backtick)" `
    ($mac.Contains('`stdbtn_1`'))
Assert-True "hands TOP base id (22) as a direction ref" ($mac.Contains('`22`'))
Assert-True "hands FRONT base id (33) as a direction ref" ($mac.Contains('`33`'))

# every grid point's X and Z literal appears in the macro (value transcription).
$allCoordsPresent = $true
foreach ($pt in $gm.Points) {
    $xs = ([double]$pt.X).ToString()
    $zs = ([double]$pt.Z).ToString()
    if (-not $mac.Contains($xs)) { $allCoordsPresent = $false }
    if (-not $mac.Contains($zs)) { $allCoordsPresent = $false }
}
Assert-True "every point's X and Z value is written into the macro" $allCoordsPresent

# empty point list -> still a string, no rows, never throws.
$threwMac = $false
$macEmpty = $null
try { $macEmpty = Build-PointGridMacro -Points @() -SideBaseId 1 -TopBaseId 2 -FrontBaseId 3 } catch { $threwMac = $true }
Assert-True "empty Points -> does not throw" (-not $threwMac)
Assert-True "empty Points -> no add_pnt_btn rows" `
    ($null -ne $macEmpty -and [regex]::Matches($macEmpty, 'add_pnt_btn').Count -eq 0)

# ----------------------------------------------------------------------------
# Build-IntersectPointMacro -- the PROVEN datum-point creation recipe: select 3
# planes by ID (accumulate with -NoClear), ProCmdDatumPointGeneral, stdbtn_1. ALL
# widgets confirmed live (point-probe.cmd, 2026-06-24). This is what drilljig
# STAGE 2.5 fires per grid point (face + X-plane + Z-plane → intersection point).
# Uses the Get-SelectByIdMacro stub (SELBYID) + Get-SelectDatumByIdMacro stub
# (SELDATUM, though not used here -- Build-IntersectPointMacro only uses
# Get-SelectByIdMacro with/without -NoClear).
# ----------------------------------------------------------------------------
Write-Host "  -- orthogrid: Build-IntersectPointMacro --" -ForegroundColor White

$ip = Build-IntersectPointMacro -PlaneIds @(10, 20, 30)
Assert-True "intersect macro is a single String (atomic RunMacro)" ($ip -is [string])
# 1st plane: buffer_clean (SELBYID), 2nd/3rd: -NoClear (SELBYID_NC per our stub).
# Note: the test stub distinguishes with/without NoClear by name.
Assert-True "1st plane (id 10) selected WITH buffer_clean" ($ip.Contains("SELBYID(10);"))
Assert-True "2nd plane (id 20) selected WITHOUT buffer_clean (NoClear, accumulates)" ($ip.Contains("SELBYID_NC(20);"))
Assert-True "3rd plane (id 30) selected WITHOUT buffer_clean (NoClear, accumulates)" ($ip.Contains("SELBYID_NC(30);"))
Assert-True "fires ProCmdDatumPointGeneral (confirmed live)" ($ip.Contains('`ProCmdDatumPointGeneral`'))
Assert-True "confirms with stdbtn_1 (dialog OK)" ($ip.Contains('`stdbtn_1`'))
Assert-True "does NOT use any pattern/direction widgets" `
    (-not $ip.Contains('ProCmdGeomPattern') -and -not $ip.Contains('ui_pat_dir'))
# single-point (1 plane): degenerate but doesn't throw.
$ip1 = Build-IntersectPointMacro -PlaneIds @(99)
Assert-True "1-plane degenerate -> still a string (no throw)" ($ip1 -is [string])
Assert-True "1-plane -> has ProCmdDatumPointGeneral" ($ip1.Contains('`ProCmdDatumPointGeneral`'))

# Get-PatternExpectedNewPoints retained (documented/tested, kept for reference).
Assert-True "expected-new 5x4 = 19" ((Get-PatternExpectedNewPoints -Nx 5 -Nz 4) -eq 19)
Assert-True "expected-new 1x1 = 0 (seed only)" ((Get-PatternExpectedNewPoints -Nx 1 -Nz 1) -eq 0)
Assert-True "expected-new 0x0 floors at 0 (no negative)" ((Get-PatternExpectedNewPoints -Nx 0 -Nz 0) -eq 0)

# ----------------------------------------------------------------------------
# Resolve-EdgeAxis (STAGE 6 chip-relief paths) -- classify the picked plate edge by
# LENGTH alone (no coordinate read): an edge ~= plate Width runs along X (cross the
# X-pitch planes, boundary = Front); ~= Height runs along Z (boundary = Top). A
# length matching neither (a thickness edge) is reported NOT Confident.
# ----------------------------------------------------------------------------
Write-Host "  -- orthogrid: Resolve-EdgeAxis (STAGE 6) --" -ForegroundColor White

# plate 10 (Width/X) x 6 (Height/Z)
$axW = Resolve-EdgeAxis -Length 10.0 -Width 10.0 -Height 6.0
Assert-True "edge == Width -> Axis X" ($axW.Axis -eq 'X')
Assert-True "edge == Width -> Boundary Front" ($axW.Boundary -eq 'Front')
Assert-True "edge == Width -> Confident" ($axW.Confident)

$axH = Resolve-EdgeAxis -Length 6.0 -Width 10.0 -Height 6.0
Assert-True "edge == Height -> Axis Z" ($axH.Axis -eq 'Z')
Assert-True "edge == Height -> Boundary Top" ($axH.Boundary -eq 'Top')
Assert-True "edge == Height -> Confident" ($axH.Confident)

# within 20% tol still confident (Width 10, edge 9.0 -> 10% off)
$axNear = Resolve-EdgeAxis -Length 9.0 -Width 10.0 -Height 6.0
Assert-True "edge near Width (10% off) -> Axis X, Confident" ($axNear.Axis -eq 'X' -and $axNear.Confident)

# a thickness edge (length 0.5) matches neither 10 nor 6 -> NOT confident
$axThk = Resolve-EdgeAxis -Length 0.5 -Width 10.0 -Height 6.0
Assert-True "thickness edge (0.5) -> NOT Confident" (-not $axThk.Confident)
Assert-True "Resolve-EdgeAxis never throws on zero dims" `
    ($null -ne (Resolve-EdgeAxis -Length 0 -Width 0 -Height 0))
# square plate (Width == Height): ties resolve to X (dw <= dh), deterministic.
$axSq = Resolve-EdgeAxis -Length 5.0 -Width 5.0 -Height 5.0
Assert-True "square plate tie -> Axis X (deterministic), Confident" ($axSq.Axis -eq 'X' -and $axSq.Confident)

# ----------------------------------------------------------------------------
# Resolve-SeedPoint -- single seed read (id + owning feature id), ID-only.
# Fake selection buffer: each item exposes .SelItem with .Type/.Id/.GetFeature().
# ----------------------------------------------------------------------------
Write-Host "  -- orthogrid: Resolve-SeedPoint --" -ForegroundColor White

$seedType = [pscustomobject]@{ ITEM_POINT = 999 }

# build a fake datum-POINT SelItem (Type=ITEM_POINT, .Id, .GetFeature().Id, and a
# ListSubItems that returns nothing - it is a point, not a feature).
function New-FakePointSel {
    param([int]$PointId, [int]$FeatId)
    $feat = [pscustomobject]@{ Id = $FeatId }
    $si = [pscustomobject]@{ Type = 999; Id = $PointId }
    $si | Add-Member -MemberType ScriptMethod -Name GetFeature  -Value { $feat }.GetNewClosure()
    $si | Add-Member -MemberType ScriptMethod -Name ListSubItems -Value { param($t) @() }
    return [pscustomobject]@{ SelItem = $si }
}
function New-FakeBuffer {
    param([array]$Items)
    $buf = [pscustomobject]@{}
    $buf | Add-Member -MemberType ScriptProperty -Name Contents -Value { $Items }.GetNewClosure()
    $sess = [pscustomobject]@{}
    $sess | Add-Member -MemberType ScriptMethod -Name CurrentSelectionBuffer -Value { $buf }.GetNewClosure()
    return $sess
}

# exactly one seed -> returns {PointId; FeatId}.
$sess1 = New-FakeBuffer -Items @( (New-FakePointSel -PointId 41 -FeatId 5) )
$seed1 = Resolve-SeedPoint -Session $sess1 -TypeObj $seedType
Assert-True "one seed -> resolves point id" ($null -ne $seed1 -and $seed1.PointId -eq 41)
Assert-True "one seed -> resolves owning feature id (GetFeature)" ($null -ne $seed1 -and $seed1.FeatId -eq 5)

# zero points selected -> $null (the pattern needs exactly one).
$sess0 = New-FakeBuffer -Items @()
Assert-True "empty selection -> null seed" ($null -eq (Resolve-SeedPoint -Session $sess0 -TypeObj $seedType))

# two distinct points -> $null (ambiguous; wants exactly ONE seed).
$sess2 = New-FakeBuffer -Items @( (New-FakePointSel -PointId 41 -FeatId 5), (New-FakePointSel -PointId 42 -FeatId 6) )
Assert-True "two seeds -> null (ambiguous)" ($null -eq (Resolve-SeedPoint -Session $sess2 -TypeObj $seedType))

# never throws even when the buffer read blows up.
$boomSess = [pscustomobject]@{}
$boomSess | Add-Member -MemberType ScriptMethod -Name CurrentSelectionBuffer -Value { throw "com blew up" }
$threwSeed = $false
$seedNull = $null
try { $seedNull = Resolve-SeedPoint -Session $boomSess -TypeObj $seedType } catch { $threwSeed = $true }
Assert-True "Resolve-SeedPoint does NOT throw on buffer failure" (-not $threwSeed)
Assert-True "Resolve-SeedPoint returns null on buffer failure" ($null -eq $seedNull)

# ----------------------------------------------------------------------------
# Resolve-NewPointIds / Get-PointIdSet -- before/after set diff, ID-only.
# Uses a tiny fake model whose ListItems(ITEM_POINT) returns objects with .Id.
# ----------------------------------------------------------------------------
Write-Host "  -- orthogrid: Resolve-NewPointIds --" -ForegroundColor White

function New-FakePoint { param([int]$Id) [pscustomobject]@{ Id = $Id } }
# a fake model: $script:fakePts drives what ListItems returns; ITEM_POINT echoes.
$script:fakePts = @()
$fakeType  = [pscustomobject]@{ ITEM_POINT = 999 }
$fakeModel = [pscustomobject]@{}
$fakeModel | Add-Member -MemberType ScriptMethod -Name ListItems -Value { param($t) return $script:fakePts }

$script:fakePts = @( (New-FakePoint 5), (New-FakePoint 6) )
$before = Get-PointIdSet -Model $fakeModel -TypeObj $fakeType
Assert-True "Get-PointIdSet snapshots existing ids" `
    ($before.ContainsKey(5) -and $before.ContainsKey(6) -and $before.Count -eq 2)

# add two new points (7, 8); 5/6 still present -> diff is exactly {7,8}.
$script:fakePts = @( (New-FakePoint 5), (New-FakePoint 6), (New-FakePoint 7), (New-FakePoint 8) )
$newIds = Resolve-NewPointIds -Model $fakeModel -TypeObj $fakeType -Before $before
Assert-True "Resolve-NewPointIds returns only the NEW ids" `
    (@($newIds).Count -eq 2 -and $newIds[0] -eq 7 -and $newIds[1] -eq 8)

# no change -> empty diff.
$script:fakePts = @( (New-FakePoint 5), (New-FakePoint 6) )
$noNew = Resolve-NewPointIds -Model $fakeModel -TypeObj $fakeType -Before $before
Assert-True "no new points -> empty diff" (@($noNew).Count -eq 0)

# ListItems throwing -> Get-PointIdSet degrades to empty set, never throws.
$boom = [pscustomobject]@{}
$boom | Add-Member -MemberType ScriptMethod -Name ListItems -Value { throw "com blew up" }
$threwSet = $false
$emptySet = $null
try { $emptySet = Get-PointIdSet -Model $boom -TypeObj $fakeType } catch { $threwSet = $true }
Assert-True "Get-PointIdSet does NOT throw when ListItems fails" (-not $threwSet)
Assert-True "Get-PointIdSet returns empty set on failure" ($null -ne $emptySet -and $emptySet.Count -eq 0)

# ----------------------------------------------------------------------------
# Show-OrthogridTable -- smoke: prints a grid without throwing.
# ----------------------------------------------------------------------------
Write-Host "  -- orthogrid: Show-OrthogridTable (smoke) --" -ForegroundColor White
$threwTbl = $false
try { Show-OrthogridTable -Geo (Get-OrthogridGeometry -CcX 1 -CcZ 1 -Nx 2 -Nz 2 -Edge 0.25) | Out-Null } catch { $threwTbl = $true }
Assert-True "Show-OrthogridTable does not throw" (-not $threwTbl)

# ----------------------------------------------------------------------------
# Get-CustomPointsGeometry -- irregular-layout sibling, shape-compatible with the
# orthogrid result. NO Edge margin: plate is DERIVED (maxX/maxZ + ClearDia) or
# EXPLICIT (Width/Height override). Origin (0,0) points dropped by default.
# ----------------------------------------------------------------------------
Write-Host "  -- custom points: Get-CustomPointsGeometry --" -ForegroundColor White

$cpPts = @(
    [pscustomobject]@{ X = 1.0; Z = 2.0 }
    [pscustomobject]@{ X = 3.5; Z = 0.5 }
    [pscustomobject]@{ X = 2.0; Z = 4.0 }
)
$cp = Get-CustomPointsGeometry -Points $cpPts
Assert-True "custom: Valid on good input" ($cp.Valid)
Assert-True "custom: Mode = 'custom'" ($cp.Mode -eq 'custom')
Assert-True "custom: WidthMode = 'derived' by default" ($cp.WidthMode -eq 'derived')
Assert-True "custom: Count = #points" ($cp.Count -eq 3)
# DERIVED (ClearDia 0): Width = max(X)=3.5 ; Height = max(Z)=4.0  (NO edge margin)
Assert-True "custom: derived Width = maxX (no edge)"  (Approx $cp.Width 3.5)
Assert-True "custom: derived Height = maxZ (no edge)" (Approx $cp.Height 4.0)
Assert-True "custom: Edge member is 0 (shape-compat, unused)" (Approx $cp.Edge 0.0)
Assert-True "custom: SkippedOrigin = 0 (no origin point here)" ($cp.SkippedOrigin -eq 0)
Assert-True "custom: Errors empty when Valid" ($cp.Errors.Count -eq 0)
# shape-compat: it has the SAME members the orthogrid result + $orthoGeo consumers read.
$orthoMembers = @('Valid','Errors','Mode','CcX','CcZ','Nx','Nz','Edge','ClearDia','Width','Height','Count','Points')
$cpNames = @($cp.PSObject.Properties.Name)
$missing = @($orthoMembers | Where-Object { $cpNames -notcontains $_ })
Assert-True "custom: shape-compatible with orthogrid result" ($missing.Count -eq 0) ("missing: " + ($missing -join ','))
# each point carries I/J/X/Z; I is the running index, J fixed 0.
Assert-True "custom: points carry I/J/X/Z" `
    (($cp.Points[0].PSObject.Properties.Name -contains 'I') -and `
     ($cp.Points[0].PSObject.Properties.Name -contains 'J') -and `
     ($cp.Points[0].PSObject.Properties.Name -contains 'X') -and `
     ($cp.Points[0].PSObject.Properties.Name -contains 'Z'))
Assert-True "custom: I is running index, J fixed 0" `
    ($cp.Points[0].I -eq 0 -and $cp.Points[1].I -eq 1 -and $cp.Points[2].I -eq 2 -and `
     $cp.Points[0].J -eq 0 -and $cp.Points[2].J -eq 0)
Assert-True "custom: X/Z echoed straight from input" `
    ((Approx $cp.Points[1].X 3.5) -and (Approx $cp.Points[1].Z 0.5))

# ClearDia widens the (derived) plate but does NOT move points.
$cpC = Get-CustomPointsGeometry -Points $cpPts -ClearDia 0.75
Assert-True "custom: ClearDia adds to derived Width"  (Approx $cpC.Width 4.25)
Assert-True "custom: ClearDia adds to derived Height" (Approx $cpC.Height 4.75)
Assert-True "custom: ClearDia does not move points" `
    ((Approx $cpC.Points[1].X 3.5) -and (Approx $cpC.Points[1].Z 0.5))

# EXPLICIT part size overrides the derived dims (when large enough to contain holes).
$cpE = Get-CustomPointsGeometry -Points $cpPts -WidthOverride 10.0 -HeightOverride 8.0
Assert-True "custom: explicit -> WidthMode 'explicit'" ($cpE.WidthMode -eq 'explicit')
Assert-True "custom: explicit Width honored" (Approx $cpE.Width 10.0)
Assert-True "custom: explicit Height honored" (Approx $cpE.Height 8.0)
Assert-True "custom: explicit + valid (contains all holes)" ($cpE.Valid)
# only one dim explicit -> the other derives; WidthMode reflects the WIDTH only.
$cpE1 = Get-CustomPointsGeometry -Points $cpPts -WidthOverride 9.0
Assert-True "custom: width-only explicit -> Width 9, Height derived (maxZ)" `
    ((Approx $cpE1.Width 9.0) -and (Approx $cpE1.Height 4.0) -and ($cpE1.WidthMode -eq 'explicit'))
Assert-True "custom: width-only -> HeightMode stays 'derived'" ($cpE1.HeightMode -eq 'derived')
# height-only explicit must NOT mislabel WidthMode as explicit (per-axis modes).
$cpH1 = Get-CustomPointsGeometry -Points $cpPts -HeightOverride 9.0
Assert-True "custom: height-only -> WidthMode 'derived', HeightMode 'explicit'" `
    (($cpH1.WidthMode -eq 'derived') -and ($cpH1.HeightMode -eq 'explicit') -and (Approx $cpH1.Width 3.5) -and (Approx $cpH1.Height 9.0))
# explicit too small to contain the farthest hole -> Valid false.
$cpESmall = Get-CustomPointsGeometry -Points $cpPts -WidthOverride 2.0 -HeightOverride 8.0
Assert-True "custom: explicit width < farthest hole -> Valid false" (-not $cpESmall.Valid)
Assert-True "custom: explicit-too-small -> Errors non-empty" ($cpESmall.Errors.Count -ge 1)
# bore-edge clearance: with ClearDia, an explicit width must contain the FULL bore
# (maxX + ClearDia/2), not just the hole CENTER at maxX. maxX=3.5, ClearDia=1.0 ->
# need width >= 4.0; a width of exactly 3.5 (center on edge) must be REJECTED.
$cpBore = Get-CustomPointsGeometry -Points $cpPts -ClearDia 1.0 -WidthOverride 3.5 -HeightOverride 8.0
Assert-True "custom: explicit width = maxX but bore overhangs -> Valid false" (-not $cpBore.Valid)
$cpBoreOk = Get-CustomPointsGeometry -Points $cpPts -ClearDia 1.0 -WidthOverride 4.0 -HeightOverride 8.0
Assert-True "custom: explicit width = maxX + ClearDia/2 -> Valid (bore fits)" ($cpBoreOk.Valid)
# with ClearDia 0 the bound degrades to maxX (a width of exactly maxX is fine).
$cpBore0 = Get-CustomPointsGeometry -Points $cpPts -ClearDia 0 -WidthOverride 3.5 -HeightOverride 8.0
Assert-True "custom: ClearDia 0 -> width = maxX is valid (no bore overhang)" ($cpBore0.Valid)
# explicit dim of 0 / negative is treated as 'not given' -> derive (not an error).
$cpEzero = Get-CustomPointsGeometry -Points $cpPts -WidthOverride 0 -HeightOverride 0
Assert-True "custom: explicit 0/0 falls back to derived" ($cpEzero.WidthMode -eq 'derived' -and (Approx $cpEzero.Width 3.5))

# ORIGIN handling: a (0,0) point is DROPPED by default (no hole at the part corner).
$cpOrig = Get-CustomPointsGeometry -Points @(
    [pscustomobject]@{ X = 0.0; Z = 0.0 }
    [pscustomobject]@{ X = 2.0; Z = 3.0 }
)
Assert-True "custom: origin dropped -> Count excludes it" ($cpOrig.Count -eq 1)
Assert-True "custom: origin dropped -> SkippedOrigin = 1" ($cpOrig.SkippedOrigin -eq 1)
Assert-True "custom: kept point is the non-origin one" ((Approx $cpOrig.Points[0].X 2.0) -and (Approx $cpOrig.Points[0].Z 3.0))
Assert-True "custom: kept point re-indexed to I=0 (no gap from dropped origin)" ($cpOrig.Points[0].I -eq 0)
# -KeepOrigin keeps it.
$cpKeep = Get-CustomPointsGeometry -Points @(
    [pscustomobject]@{ X = 0.0; Z = 0.0 }
    [pscustomobject]@{ X = 2.0; Z = 3.0 }
) -KeepOrigin
Assert-True "custom: -KeepOrigin keeps the origin point" ($cpKeep.Count -eq 2 -and $cpKeep.SkippedOrigin -eq 0)
# a point ON one axis (X=0, Z!=0) is NOT the origin -> kept.
$cpAxis = Get-CustomPointsGeometry -Points @([pscustomobject]@{ X = 0.0; Z = 5.0 })
Assert-True "custom: on-axis (0,5) is NOT origin -> kept" ($cpAxis.Count -eq 1 -and $cpAxis.SkippedOrigin -eq 0)
# origin-ONLY layout -> nothing to drill -> Valid false.
$cpOnly = Get-CustomPointsGeometry -Points @([pscustomobject]@{ X = 0.0; Z = 0.0 })
Assert-True "custom: origin-only -> Valid false (nothing to drill)" (-not $cpOnly.Valid -and $cpOnly.Count -eq 0)

# a single (non-origin) point is legal.
$cp1 = Get-CustomPointsGeometry -Points @([pscustomobject]@{ X = 2.0; Z = 3.0 })
Assert-True "custom: single point is valid" ($cp1.Valid -and $cp1.Count -eq 1)
Assert-True "custom: single-point derived Width = X" (Approx $cp1.Width 2.0)

# bad input: empty list, negative coord, negative ClearDia -> Valid false, no throw.
$cpEmpty = Get-CustomPointsGeometry -Points @()
Assert-True "custom: empty list -> Valid false" (-not $cpEmpty.Valid)
Assert-True "custom: empty list -> Errors non-empty" ($cpEmpty.Errors.Count -ge 1)
Assert-True "custom: empty list -> Count 0, Points empty" ($cpEmpty.Count -eq 0 -and $cpEmpty.Points.Count -eq 0)

$cpNeg = Get-CustomPointsGeometry -Points @([pscustomobject]@{ X = -1.0; Z = 2.0 })
Assert-True "custom: negative X -> Valid false" (-not $cpNeg.Valid)

$cpBadClear = Get-CustomPointsGeometry -Points $cpPts -ClearDia -1.0
Assert-True "custom: negative ClearDia -> Valid false" (-not $cpBadClear.Valid)

# malformed point (no numeric X/Z) is reported, not thrown.
$threwCp = $false
$cpMal = $null
try { $cpMal = Get-CustomPointsGeometry -Points @([pscustomobject]@{ Foo = 1 }) } catch { $threwCp = $true }
Assert-True "custom: malformed point does NOT throw" (-not $threwCp)
Assert-True "custom: malformed point -> Valid false (reported)" ($null -ne $cpMal -and -not $cpMal.Valid)

# explicit never-throws guard.
$threwCp2 = $false
try { $null = Get-CustomPointsGeometry -Points $null -ClearDia -9.0 -WidthOverride "bad" } catch { $threwCp2 = $true }
Assert-True "custom: Get-CustomPointsGeometry does NOT throw on bad input" (-not $threwCp2)

# ----------------------------------------------------------------------------
# Get-SharedPlanePlan -- distinct X/Z dedup + per-point indices. Must (a) dedup
# shared coordinates, (b) index each point correctly, (c) reproduce the regular
# grid's plane layout (orthogrid equivalence), (d) never throw.
# ----------------------------------------------------------------------------
Write-Host "  -- shared planes: Get-SharedPlanePlan --" -ForegroundColor White

# three points sharing X=1.0 and Z=2.0 across them.
$spPts = @(
    [pscustomobject]@{ X = 1.0; Z = 2.0 }
    [pscustomobject]@{ X = 3.0; Z = 2.0 }   # shares Z=2.0 with #1
    [pscustomobject]@{ X = 1.0; Z = 5.0 }   # shares X=1.0 with #1
)
$sp = Get-SharedPlanePlan -Points $spPts
Assert-True "shared: distinct X = {1.0, 3.0}" (@($sp.XCoords).Count -eq 2 -and (Approx $sp.XCoords[0] 1.0) -and (Approx $sp.XCoords[1] 3.0))
Assert-True "shared: distinct Z = {2.0, 5.0}" (@($sp.ZCoords).Count -eq 2 -and (Approx $sp.ZCoords[0] 2.0) -and (Approx $sp.ZCoords[1] 5.0))
Assert-True "shared: one triple per point" (@($sp.Triples).Count -eq 3)
# point #1 (1.0, 2.0) -> Xi 0, Zi 0 ; #2 (3.0,2.0) -> Xi 1, Zi 0 ; #3 (1.0,5.0) -> Xi 0, Zi 1
Assert-True "shared: point1 indices (Xi=0,Zi=0)" ($sp.Triples[0].Xi -eq 0 -and $sp.Triples[0].Zi -eq 0)
Assert-True "shared: point2 indices (Xi=1,Zi=0) shares Z plane" ($sp.Triples[1].Xi -eq 1 -and $sp.Triples[1].Zi -eq 0)
Assert-True "shared: point3 indices (Xi=0,Zi=1) shares X plane" ($sp.Triples[2].Xi -eq 0 -and $sp.Triples[2].Zi -eq 1)
# coordinates echoed on the triple
Assert-True "shared: triple echoes X/Z" ((Approx $sp.Triples[1].X 3.0) -and (Approx $sp.Triples[1].Z 2.0))

# tolerance dedup: two X within Tol collapse to one plane.
$spTol = Get-SharedPlanePlan -Points @(
    [pscustomobject]@{ X = 1.0;          Z = 0.0 }
    [pscustomobject]@{ X = 1.0000000001; Z = 0.0 }
) -Tol 1e-6
Assert-True "shared: near-equal X collapse to ONE distinct plane" (@($spTol.XCoords).Count -eq 1)
Assert-True "shared: both points index the same X plane" ($spTol.Triples[0].Xi -eq 0 -and $spTol.Triples[1].Xi -eq 0)

# ORTHOGRID EQUIVALENCE: feed an orthogrid's Points and confirm the distinct X
# offsets are exactly the per-column offsets (Edge + I*CcX), one plane per column,
# and a column-I point indexes XCoords[I]. This is what guarantees the live-
# confirmed grid path is byte-identical under the generalised STAGE 2.5.
$gridGeo = Get-OrthogridGeometry -CcX 2.0 -CcZ 1.5 -Nx 4 -Nz 3 -Edge 0.5   # 12 points
$spGrid  = Get-SharedPlanePlan -Points $gridGeo.Points
Assert-True "shared/grid: distinct X count == Nx" (@($spGrid.XCoords).Count -eq 4)
Assert-True "shared/grid: distinct Z count == Nz" (@($spGrid.ZCoords).Count -eq 3)
# X offsets are {0.5, 2.5, 4.5, 6.5} = Edge + I*CcX, ascending
Assert-True "shared/grid: X offsets = Edge + I*CcX" `
    ((Approx $spGrid.XCoords[0] 0.5) -and (Approx $spGrid.XCoords[1] 2.5) -and (Approx $spGrid.XCoords[2] 4.5) -and (Approx $spGrid.XCoords[3] 6.5))
Assert-True "shared/grid: Z offsets = Edge + J*CcZ" `
    ((Approx $spGrid.ZCoords[0] 0.5) -and (Approx $spGrid.ZCoords[1] 2.0) -and (Approx $spGrid.ZCoords[2] 3.5))
# a column-I/row-J grid point must index (Xi=I, Zi=J) -- the equivalence that keeps
# the generalised plane creation identical to the old Nx/Nz derivation.
$gridEquiv = $true
foreach ($k in 0..($gridGeo.Points.Count - 1)) {
    $gp = $gridGeo.Points[$k]
    $tr = $spGrid.Triples[$k]
    if ($tr.Xi -ne $gp.I -or $tr.Zi -ne $gp.J) { $gridEquiv = $false }
}
Assert-True "shared/grid: each point indexes (Xi=I, Zi=J) -- orthogrid equivalence" $gridEquiv

# empty / degenerate input -> empty plan, never throws.
$threwSp = $false
$spEmpty = $null
try { $spEmpty = Get-SharedPlanePlan -Points @() } catch { $threwSp = $true }
Assert-True "shared: empty input does NOT throw" (-not $threwSp)
Assert-True "shared: empty input -> no coords, no triples" `
    ($null -ne $spEmpty -and @($spEmpty.XCoords).Count -eq 0 -and @($spEmpty.ZCoords).Count -eq 0 -and @($spEmpty.Triples).Count -eq 0)

# malformed points are skipped (not thrown); a clean point still indexes.
$threwSp2 = $false
$spMal = $null
try { $spMal = Get-SharedPlanePlan -Points @([pscustomobject]@{ Foo = 1 }, [pscustomobject]@{ X = 1.0; Z = 2.0 }) } catch { $threwSp2 = $true }
Assert-True "shared: malformed point does NOT throw" (-not $threwSp2)
Assert-True "shared: malformed point skipped, clean point kept" `
    ($null -ne $spMal -and @($spMal.Triples).Count -eq 1 -and (Approx $spMal.Triples[0].X 1.0))

# ----------------------------------------------------------------------------
# Show-OrthogridTable -- custom-mode header smoke (Nx/Nz are 0 -> count-only line).
# ----------------------------------------------------------------------------
Write-Host "  -- custom points: Show-OrthogridTable (custom-mode smoke) --" -ForegroundColor White
$threwCustTbl = $false
try { Show-OrthogridTable -Geo (Get-CustomPointsGeometry -Points @([pscustomobject]@{X=1;Z=1}) -Edge 0.25) | Out-Null } catch { $threwCustTbl = $true }
Assert-True "Show-OrthogridTable handles custom Geo without throwing" (-not $threwCustTbl)

# ----------------------------------------------------------------------------
# Get-HoleBoundingRect (rectpocketinator) -- the subset-rectangle chip-relief
# pocket. PURE bounding box of the hole CENTERS + margin, in the plate-corner
# frame. Must (a) bound the centers, (b) expand by Margin on all sides, (c) clamp
# near edges to >= 0, (d) fit-check against the plate, (e) advise when the margin
# is under a bore radius, (f) reproduce for orthogrid AND custom points, (g) never
# throw.
# ----------------------------------------------------------------------------
Write-Host "  -- pocket: Get-HoleBoundingRect --" -ForegroundColor White

# a simple 3-point cluster: X in {1,3,2}, Z in {2,0.5,4} -> center box [1,3]x[0.5,4]
$brPts = @(
    [pscustomobject]@{ X = 1.0; Z = 2.0 }
    [pscustomobject]@{ X = 3.0; Z = 0.5 }
    [pscustomobject]@{ X = 2.0; Z = 4.0 }
)
$br = Get-HoleBoundingRect -Points $brPts -Margin 0.5 -Width 10.0 -Height 10.0
Assert-True "pocket: Valid on good input" ($br.Valid)
Assert-True "pocket: Count = #points" ($br.Count -eq 3)
Assert-True "pocket: center-box extremes (minX/maxX/minZ/maxZ)" `
    ((Approx $br.MinX 1.0) -and (Approx $br.MaxX 3.0) -and (Approx $br.MinZ 0.5) -and (Approx $br.MaxZ 4.0))
# rect = center box +/- margin: X0=1-0.5=0.5, X1=3+0.5=3.5, Z0=0.5-0.5=0.0, Z1=4+0.5=4.5
Assert-True "pocket: X0 = minX - margin" (Approx $br.X0 0.5)
Assert-True "pocket: X1 = maxX + margin" (Approx $br.X1 3.5)
Assert-True "pocket: Z0 = minZ - margin" (Approx $br.Z0 0.0)
Assert-True "pocket: Z1 = maxZ + margin" (Approx $br.Z1 4.5)
Assert-True "pocket: RectW = X1 - X0" (Approx $br.RectW 3.0)
Assert-True "pocket: RectH = Z1 - Z0" (Approx $br.RectH 4.5)
# center of the pocket rect: ((0.5+3.5)/2, (0.0+4.5)/2) = (2.0, 2.25)
Assert-True "pocket: CenterX = (X0+X1)/2" (Approx $br.CenterX 2.0)
Assert-True "pocket: CenterZ = (Z0+Z1)/2" (Approx $br.CenterZ 2.25)
Assert-True "pocket: Margin echoed" (Approx $br.Margin 0.5)
Assert-True "pocket: Errors empty when Valid" ($br.Errors.Count -eq 0)

# NEAR-EDGE CLAMP: a margin larger than the nearest center coordinate must clamp
# X0/Z0 to 0 (never push the pocket wall off the near datum). minZ here is 0.5,
# margin 1.0 -> Z0 would be -0.5, clamp to 0.0. minX is 1.0, margin 1.0 -> X0 = 0.0.
$brClamp = Get-HoleBoundingRect -Points $brPts -Margin 1.0 -Width 10.0 -Height 10.0
Assert-True "pocket: near X edge clamps to >= 0" (Approx $brClamp.X0 0.0)
Assert-True "pocket: near Z edge clamps to >= 0 (was -0.5)" (Approx $brClamp.Z0 0.0)
Assert-True "pocket: far edges still extend past by margin" `
    ((Approx $brClamp.X1 4.0) -and (Approx $brClamp.Z1 5.0))

# FIT CHECK: a pocket that spills past the plate width/height -> Valid false.
# maxX=3, margin 0.5 -> X1=3.5; a plate Width of 3.0 is too small.
$brFit = Get-HoleBoundingRect -Points $brPts -Margin 0.5 -Width 3.0 -Height 10.0
Assert-True "pocket: rect exceeding plate width -> Valid false" (-not $brFit.Valid)
Assert-True "pocket: over-width -> Errors non-empty" ($brFit.Errors.Count -ge 1)
$brFitH = Get-HoleBoundingRect -Points $brPts -Margin 0.5 -Width 10.0 -Height 4.0
Assert-True "pocket: rect exceeding plate height -> Valid false" (-not $brFitH.Valid)
# Width/Height <= 0 disables the fit check (still valid even for a big margin).
$brNoFit = Get-HoleBoundingRect -Points $brPts -Margin 5.0 -Width 0.0 -Height 0.0
Assert-True "pocket: no plate dims -> fit check skipped (Valid)" ($brNoFit.Valid)

# BORE ADVISORY: margin < hole radius -> Warnings non-empty, but STILL Valid.
$brWarn = Get-HoleBoundingRect -Points $brPts -Margin 0.1 -Width 10.0 -Height 10.0 -HoleDia 0.5
Assert-True "pocket: margin < bore radius -> Warnings non-empty" ($brWarn.Warnings.Count -ge 1)
Assert-True "pocket: bore advisory does NOT gate Valid" ($brWarn.Valid)
# margin >= hole radius -> no warning.
$brNoWarn = Get-HoleBoundingRect -Points $brPts -Margin 0.5 -Width 10.0 -Height 10.0 -HoleDia 0.5
Assert-True "pocket: margin >= bore radius -> no bore warning" ($brNoWarn.Warnings.Count -eq 0)

# SINGLE POINT: minX==maxX -> rect is 2*margin square centered on it.
$br1 = Get-HoleBoundingRect -Points @([pscustomobject]@{ X = 2.0; Z = 3.0 }) -Margin 0.5 -Width 10.0 -Height 10.0
Assert-True "pocket: single point valid" ($br1.Valid -and $br1.Count -eq 1)
Assert-True "pocket: single point rect = 2*margin square" ((Approx $br1.RectW 1.0) -and (Approx $br1.RectH 1.0))
Assert-True "pocket: single point centered on it" ((Approx $br1.CenterX 2.0) -and (Approx $br1.CenterZ 3.0))

# ORTHOGRID SOURCE: the bounding box of a real grid's Points spans the outer
# centers. 4x3 grid, cc 2.0/1.5, edge 0.5 -> centers X {0.5..6.5}, Z {0.5..3.5}.
$brGridGeo = Get-OrthogridGeometry -CcX 2.0 -CcZ 1.5 -Nx 4 -Nz 3 -Edge 0.5
$brGrid = Get-HoleBoundingRect -Points $brGridGeo.Points -Margin 0.25 -Width $brGridGeo.Width -Height $brGridGeo.Height
Assert-True "pocket/grid: bounds the outer grid centers" `
    ((Approx $brGrid.MinX 0.5) -and (Approx $brGrid.MaxX 6.5) -and (Approx $brGrid.MinZ 0.5) -and (Approx $brGrid.MaxZ 3.5))
Assert-True "pocket/grid: fits inside the plate it was sized for" ($brGrid.Valid)

# CUSTOM SOURCE: works on Get-CustomPointsGeometry output identically.
$brCustGeo = Get-CustomPointsGeometry -Points @(
    [pscustomobject]@{ X = 1.0; Z = 2.0 }
    [pscustomobject]@{ X = 3.5; Z = 0.5 }
) -ClearDia 0.5
$brCust = Get-HoleBoundingRect -Points $brCustGeo.Points -Margin 0.2 -Width $brCustGeo.Width -Height $brCustGeo.Height
Assert-True "pocket/custom: bounds custom centers" `
    ((Approx $brCust.MinX 1.0) -and (Approx $brCust.MaxX 3.5))
Assert-True "pocket/custom: Valid on custom source" ($brCust.Valid)

# BAD INPUT / never-throws: empty, negative margin, malformed points.
$brEmpty = Get-HoleBoundingRect -Points @() -Margin 0.5
Assert-True "pocket: empty points -> Valid false" (-not $brEmpty.Valid)
Assert-True "pocket: empty points -> Errors non-empty" ($brEmpty.Errors.Count -ge 1)
$brNeg = Get-HoleBoundingRect -Points $brPts -Margin -1.0
Assert-True "pocket: negative margin -> Valid false" (-not $brNeg.Valid)
$threwBr = $false
$brMal = $null
try { $brMal = Get-HoleBoundingRect -Points @([pscustomobject]@{ Foo = 1 }, [pscustomobject]@{ X = 1.0; Z = 1.0 }) -Margin 0.5 } catch { $threwBr = $true }
Assert-True "pocket: malformed point does NOT throw" (-not $threwBr)
Assert-True "pocket: malformed skipped, clean point still bounds" `
    ($null -ne $brMal -and $brMal.Count -eq 1 -and (Approx $brMal.MinX 1.0))
$threwBr2 = $false
try { $null = Get-HoleBoundingRect -Points $null -Margin -9.0 -Width -1.0 -Height -1.0 } catch { $threwBr2 = $true }
Assert-True "pocket: Get-HoleBoundingRect does NOT throw on all-bad input" (-not $threwBr2)

# ----------------------------------------------------------------------------
# Get-RowSlots (slotinator) -- one rectangular chip-relief SLOT per hole ROW.
# Rows are grouped by CROSS-coordinate (Z when RowAxis='X') via single-linkage
# on a PHYSICAL RowTol (never 1e-6); each slot spans the full plate length along
# the row axis (LengthMode='full') and is SlotWidth (= original hole dia) wide,
# centered on the MEAN cross-coord. Must (a) count rows correctly, (b) mean-
# center, (c) emit 2 diagonal corners/row that feed Get-SharedPlanePlan, (d)
# group near-but-not-equal cross-coords into ONE row under RowTol (the flagship
# regression), (e) warn (not fail) on overlap, (f) clamp near / fail far edges,
# (g) never throw.
# ----------------------------------------------------------------------------
Write-Host "  -- slots: Get-RowSlots --" -ForegroundColor White

# 3x2 grid, cc 2.0/1.5, edge 0.5 -> centers X {0.5,2.5,4.5}, Z {0.5,2.0}.
# RowAxis='X' groups by Z -> 2 rows (Z=0.5 and Z=2.0), each with 3 holes.
$rsGeo = Get-OrthogridGeometry -CcX 2.0 -CcZ 1.5 -Nx 3 -Nz 2 -Edge 0.5
$rs = Get-RowSlots -Points $rsGeo.Points -SlotWidth 0.25 -Width $rsGeo.Width -Height $rsGeo.Height
Assert-True "slots: Valid on a clean grid" ($rs.Valid)
Assert-True "slots: 3x2 grid -> 2 rows (group by Z)" ($rs.Count -eq 2)
Assert-True "slots: CrossAxis derived = Z when RowAxis=X" ($rs.CrossAxis -eq 'Z')
Assert-True "slots: PointCount = 6" ($rs.PointCount -eq 6)
Assert-True "slots: each row has 3 holes" (($rs.Rows[0].HoleCount -eq 3) -and ($rs.Rows[1].HoleCount -eq 3))
# rows ascending in Z: row0 mean Z=0.5, row1 mean Z=2.0
Assert-True "slots: row0 centered on mean Z=0.5" (Approx $rs.Rows[0].CrossCoord 0.5)
Assert-True "slots: row1 centered on mean Z=2.0" (Approx $rs.Rows[1].CrossCoord 2.0)
# band = mean +/- SlotWidth/2 (0.125). row1: 2.0 -> [1.875, 2.125]
Assert-True "slots: row1 CrossLo = mean - w/2" (Approx $rs.Rows[1].CrossLo 1.875)
Assert-True "slots: row1 CrossHi = mean + w/2" (Approx $rs.Rows[1].CrossHi 2.125)
# 'full' length: slot spans 0..Width along X
Assert-True "slots: full length spans 0..Width" ((Approx $rs.Rows[0].AlongMin 0.0) -and (Approx $rs.Rows[0].AlongMax $rsGeo.Width))
Assert-True "slots: SlotLen = Width" (Approx $rs.Rows[0].SlotLen $rsGeo.Width)
# diagonal corners in plate frame: Corner0=(AlongMin,CrossLo), Corner1=(AlongMax,CrossHi)
Assert-True "slots: row1 Corner0 = (0, 1.875)" ((Approx $rs.Rows[1].Corner0.X 0.0) -and (Approx $rs.Rows[1].Corner0.Z 1.875))
Assert-True "slots: row1 Corner1 = (Width, 2.125)" ((Approx $rs.Rows[1].Corner1.X $rsGeo.Width) -and (Approx $rs.Rows[1].Corner1.Z 2.125))
Assert-True "slots: Corners flat list = 2 per row = 4" ($rs.Corners.Count -eq 4)
Assert-True "slots: SlotWidth echoed" (Approx $rs.SlotWidth 0.25)
Assert-True "slots: Errors empty when Valid" ($rs.Errors.Count -eq 0)

# INTEGRATION: the flat Corners list feeds Get-SharedPlanePlan (the downstream
# consumer that creates the shared offset planes for the snap-guide points).
$rsPlan = Get-SharedPlanePlan -Points $rs.Corners
Assert-True "slots: Corners feed Get-SharedPlanePlan" ($null -ne $rsPlan -and $rsPlan.Triples.Count -eq 4)
# all 'full' slots share X0=0 and X1=Width -> only 2 distinct X planes.
Assert-True "slots: full-slot corners share 2 distinct X" ($rsPlan.XCoords.Count -eq 2)
# 2 rows x 2 corner-Z (Lo/Hi) = up to 4 distinct Z.
Assert-True "slots: corner Z distinct count sane" ($rsPlan.ZCoords.Count -ge 2 -and $rsPlan.ZCoords.Count -le 4)

# RowTolEffective auto = max(SlotWidth/4, 0.01). SlotWidth 0.25 -> 0.0625.
Assert-True "slots: RowTolEffective auto = SlotWidth/4" (Approx $rs.RowTolEffective 0.0625)
$rsFloor = Get-RowSlots -Points $rsGeo.Points -SlotWidth 0.02 -Width $rsGeo.Width -Height $rsGeo.Height
Assert-True "slots: RowTolEffective floored at 0.01" (Approx $rsFloor.RowTolEffective 0.01)
$rsTolOverride = Get-RowSlots -Points $rsGeo.Points -SlotWidth 0.25 -Width $rsGeo.Width -Height $rsGeo.Height -RowTol 0.3
Assert-True "slots: explicit RowTol wins" (Approx $rsTolOverride.RowTolEffective 0.3)

# FLAGSHIP REGRESSION: near-but-not-equal Z (2.000, 2.004, 1.997) must group into
# ONE row under a physical RowTol. With 1e-6 they would fragment into 3 rows (a
# silent over-cut). SlotWidth 0.25 -> RowTol 0.0625, and the max gap is 0.007.
$rsJit = Get-RowSlots -Points @(
    [pscustomobject]@{ X = 1.0; Z = 2.000 }
    [pscustomobject]@{ X = 3.0; Z = 2.004 }
    [pscustomobject]@{ X = 5.0; Z = 1.997 }
) -SlotWidth 0.25 -Width 6.0 -Height 4.0
Assert-True "slots: near-equal Z groups into ONE row (physical RowTol)" ($rsJit.Count -eq 1)
Assert-True "slots: that row has all 3 holes" ($rsJit.Rows[0].HoleCount -eq 3)
# mean Z = (2.000+2.004+1.997)/3 = 2.00033..
Assert-True "slots: crooked row centered on mean Z" (Approx $rsJit.Rows[0].CrossCoord 2.0003333333 1e-6)

# SINGLE ROW: all points share one Z -> exactly 1 slot spanning the row's holes.
$rs1row = Get-RowSlots -Points @(
    [pscustomobject]@{ X = 1.0; Z = 3.0 }
    [pscustomobject]@{ X = 2.0; Z = 3.0 }
    [pscustomobject]@{ X = 3.0; Z = 3.0 }
) -SlotWidth 0.25 -Width 10.0 -Height 6.0
Assert-True "slots: single row -> 1 slot" ($rs1row.Count -eq 1 -and $rs1row.Valid)
Assert-True "slots: single row full length spans plate Width" (Approx $rs1row.Rows[0].AlongMax 10.0)

# SINGLE POINT: 1 row/slot centered on it, full length.
$rs1pt = Get-RowSlots -Points @([pscustomobject]@{ X = 2.0; Z = 3.0 }) -SlotWidth 0.25 -Width 10.0 -Height 6.0
Assert-True "slots: single point -> 1 slot, valid" ($rs1pt.Count -eq 1 -and $rs1pt.Valid)
Assert-True "slots: single point HoleCount = 1" ($rs1pt.Rows[0].HoleCount -eq 1)

# SINGLE COLUMN: all share X, different Z (wide spacing) -> N stacked slots.
$rsCol = Get-RowSlots -Points @(
    [pscustomobject]@{ X = 2.0; Z = 1.0 }
    [pscustomobject]@{ X = 2.0; Z = 3.0 }
    [pscustomobject]@{ X = 2.0; Z = 5.0 }
) -SlotWidth 0.25 -Width 10.0 -Height 6.0
Assert-True "slots: single column (wide) -> N stacked slots" ($rsCol.Count -eq 3 -and $rsCol.Valid)

# RowAxis='Z': group by X instead. Same 3x2 grid -> Count = Nx = 3, slots run along Z.
$rsZ = Get-RowSlots -Points $rsGeo.Points -SlotWidth 0.25 -Width $rsGeo.Width -Height $rsGeo.Height -RowAxis 'Z'
Assert-True "slots: RowAxis=Z groups by X -> Count = Nx = 3" ($rsZ.Count -eq 3)
Assert-True "slots: RowAxis=Z CrossAxis = X" ($rsZ.CrossAxis -eq 'X')
Assert-True "slots: RowAxis=Z slots span Height along Z" (Approx $rsZ.Rows[0].AlongMax $rsGeo.Height)

# OVERLAP: two rows closer than SlotWidth -> Warning, still Valid (union of relief).
$rsOv = Get-RowSlots -Points @(
    [pscustomobject]@{ X = 1.0; Z = 2.0 }
    [pscustomobject]@{ X = 1.0; Z = 2.2 }
) -SlotWidth 0.5 -Width 10.0 -Height 6.0
Assert-True "slots: overlapping rows -> Warnings non-empty" ($rsOv.Warnings.Count -ge 1)
Assert-True "slots: overlap does NOT gate Valid (default)" ($rsOv.Valid)
Assert-True "slots: overlap DID split into 2 rows" ($rsOv.Count -eq 2)
# StrictNoOverlap promotes overlap to fatal.
$rsOvStrict = Get-RowSlots -Points @(
    [pscustomobject]@{ X = 1.0; Z = 2.0 }
    [pscustomobject]@{ X = 1.0; Z = 2.2 }
) -SlotWidth 0.5 -Width 10.0 -Height 6.0 -StrictNoOverlap
Assert-True "slots: StrictNoOverlap -> Valid false" (-not $rsOvStrict.Valid)

# NEAR-EDGE CLAMP: a row near Z=0 with a wide slot -> CrossLo clamps to 0 + Warning.
$rsClamp = Get-RowSlots -Points @([pscustomobject]@{ X = 2.0; Z = 0.1 }) -SlotWidth 0.5 -Width 10.0 -Height 6.0
Assert-True "slots: near Z edge clamps CrossLo to 0" (Approx $rsClamp.Rows[0].CrossLo 0.0)
Assert-True "slots: near-edge clamp is still Valid" ($rsClamp.Valid)
Assert-True "slots: near-edge clamp warns" ($rsClamp.Warnings.Count -ge 1)

# FAR-EDGE SPILL: a slot whose band exceeds Height -> Valid false (off-part cut).
$rsSpill = Get-RowSlots -Points @([pscustomobject]@{ X = 2.0; Z = 5.95 }) -SlotWidth 0.5 -Width 10.0 -Height 6.0
Assert-True "slots: far-edge cross spill -> Valid false" (-not $rsSpill.Valid)
Assert-True "slots: far-edge spill -> Errors non-empty" ($rsSpill.Errors.Count -ge 1)
# Height <= 0 disables the far-edge check (like Get-HoleBoundingRect).
$rsNoH = Get-RowSlots -Points @([pscustomobject]@{ X = 2.0; Z = 5.95 }) -SlotWidth 0.5 -Width 10.0 -Height 0.0
Assert-True "slots: Height<=0 disables far-edge check (Valid)" ($rsNoH.Valid)

# HOLES length mode: slot spans hole extent +/- Margin, clamped.
$rsHoles = Get-RowSlots -Points @(
    [pscustomobject]@{ X = 2.0; Z = 3.0 }
    [pscustomobject]@{ X = 5.0; Z = 3.0 }
) -SlotWidth 0.25 -Width 10.0 -Height 6.0 -LengthMode 'holes' -Margin 0.5
Assert-True "slots: holes mode AlongMin = minX - margin" (Approx $rsHoles.Rows[0].AlongMin 1.5)
Assert-True "slots: holes mode AlongMax = maxX + margin" (Approx $rsHoles.Rows[0].AlongMax 5.5)
Assert-True "slots: holes mode reports LengthMode=holes" ($rsHoles.LengthMode -eq 'holes')

# BAD INPUT / never-throws.
$rsBadW = Get-RowSlots -Points $rsGeo.Points -SlotWidth 0 -Width 10.0 -Height 6.0
Assert-True "slots: SlotWidth<=0 -> Valid false" (-not $rsBadW.Valid)
$rsEmpty = Get-RowSlots -Points @() -SlotWidth 0.25 -Width 10.0 -Height 6.0
Assert-True "slots: empty points -> Valid false, Count 0" ((-not $rsEmpty.Valid) -and $rsEmpty.Count -eq 0)
$rsBadMargin = Get-RowSlots -Points $rsGeo.Points -SlotWidth 0.25 -Width 10.0 -Height 6.0 -LengthMode 'holes' -Margin -1.0
Assert-True "slots: negative margin -> Valid false" (-not $rsBadMargin.Valid)
# bad RowAxis string does NOT throw and still returns best-effort geometry (defaults to X).
$threwRa = $false; $rsBadRa = $null
try { $rsBadRa = Get-RowSlots -Points $rsGeo.Points -SlotWidth 0.25 -Width $rsGeo.Width -Height $rsGeo.Height -RowAxis 'Q' } catch { $threwRa = $true }
Assert-True "slots: bad RowAxis does NOT throw" (-not $threwRa)
Assert-True "slots: bad RowAxis -> Errors + defaults to X (still groups)" ($null -ne $rsBadRa -and $rsBadRa.Errors.Count -ge 1 -and $rsBadRa.RowAxis -eq 'X' -and $rsBadRa.Count -eq 2)
# malformed point among good ones is skipped, not thrown.
$threwMal = $false; $rsMal = $null
try { $rsMal = Get-RowSlots -Points @([pscustomobject]@{ Foo = 1 }, [pscustomobject]@{ X = 1.0; Z = 3.0 }) -SlotWidth 0.25 -Width 10.0 -Height 6.0 } catch { $threwMal = $true }
Assert-True "slots: malformed point does NOT throw" (-not $threwMal)
Assert-True "slots: malformed skipped, clean point still grouped" ($null -ne $rsMal -and $rsMal.PointCount -eq 1)
# all-bad input never throws.
$threwAll = $false
try { $null = Get-RowSlots -Points $null -SlotWidth -1.0 -Width -1.0 -Height -1.0 -RowAxis 'zzz' -LengthMode 'nope' } catch { $threwAll = $true }
Assert-True "slots: Get-RowSlots does NOT throw on all-bad input" (-not $threwAll)

# CUSTOM SOURCE: works on Get-CustomPointsGeometry output identically.
$rsCustGeo = Get-CustomPointsGeometry -Points @(
    [pscustomobject]@{ X = 1.0; Z = 2.0 }
    [pscustomobject]@{ X = 3.0; Z = 2.0 }
    [pscustomobject]@{ X = 2.0; Z = 4.0 }
) -WidthOverride 6.0 -HeightOverride 6.0
$rsCust = Get-RowSlots -Points $rsCustGeo.Points -SlotWidth 0.25 -Width $rsCustGeo.Width -Height $rsCustGeo.Height
Assert-True "slots/custom: 2 rows (Z=2 has 2 holes, Z=4 has 1)" ($rsCust.Count -eq 2 -and $rsCust.Valid)

# ----------------------------------------------------------------------------
# Get-SlotPatternPlan (slotinator) -- can the row slots be one dimension pattern?
# A dimension pattern advances a single dim by a CONSTANT increment, so only
# EVENLY-SPACED rows qualify. Must: (a) count = #rows, (b) increment = the common
# pitch, (c) CanPattern only when >=2 evenly-spaced rows, (d) flag irregular
# layouts, (e) never throw. Feeds off Get-RowSlots .Rows (has .CrossCoord).
# ----------------------------------------------------------------------------
Write-Host "  -- slots: Get-SlotPatternPlan --" -ForegroundColor White

# a regular 5-row orthogrid (RowAxis=X groups by Z) -> evenly spaced at CcZ.
$ppGeo   = Get-OrthogridGeometry -CcX 2.0 -CcZ 1.5 -Nx 3 -Nz 5 -Edge 0.5
$ppSlots = Get-RowSlots -Points $ppGeo.Points -SlotWidth 0.25 -Width $ppGeo.Width -Height $ppGeo.Height
$pp = Get-SlotPatternPlan -Rows $ppSlots.Rows
Assert-True "pat: valid on a regular grid" ($pp.Valid)
Assert-True "pat: CanPattern on evenly-spaced rows" ($pp.CanPattern)
Assert-True "pat: Count = #rows = Nz = 5" ($pp.Count -eq 5)
Assert-True "pat: Increment = row pitch = CcZ = 1.5" (Approx $pp.Increment 1.5)
Assert-True "pat: EvenlySpaced true" ($pp.EvenlySpaced)
Assert-True "pat: 4 gaps for 5 rows" ($pp.Spacings.Count -eq 4)

# single row -> nothing to pattern.
$pp1 = Get-SlotPatternPlan -Rows @([pscustomobject]@{ CrossCoord = 2.0 })
Assert-True "pat: single row -> valid but CanPattern false" ($pp1.Valid -and -not $pp1.CanPattern -and $pp1.Count -eq 1)

# two evenly-spaced rows -> patternable, increment = the gap.
$pp2 = Get-SlotPatternPlan -Rows @(
    [pscustomobject]@{ CrossCoord = 1.0 }
    [pscustomobject]@{ CrossCoord = 3.5 }
)
Assert-True "pat: two rows patternable" ($pp2.CanPattern -and $pp2.Count -eq 2)
Assert-True "pat: two-row increment = gap 2.5" (Approx $pp2.Increment 2.5)

# unsorted input still yields the right sorted gaps.
$ppU = Get-SlotPatternPlan -Rows @(
    [pscustomobject]@{ CrossCoord = 4.0 }
    [pscustomobject]@{ CrossCoord = 0.0 }
    [pscustomobject]@{ CrossCoord = 2.0 }
)
Assert-True "pat: unsorted rows -> even, pitch 2.0" ($ppU.CanPattern -and (Approx $ppU.Increment 2.0))

# IRREGULAR spacing (custom layout) -> NOT patternable.
$ppIrr = Get-SlotPatternPlan -Rows @(
    [pscustomobject]@{ CrossCoord = 0.0 }
    [pscustomobject]@{ CrossCoord = 1.0 }
    [pscustomobject]@{ CrossCoord = 3.7 }
)
Assert-True "pat: irregular gaps -> CanPattern false" (-not $ppIrr.CanPattern)
Assert-True "pat: irregular still reports Count (for per-row fallback)" ($ppIrr.Count -eq 3)
Assert-True "pat: irregular Increment 0" (Approx $ppIrr.Increment 0.0)

# near-but-within-tol gaps still count as even (float tolerance).
$ppTol = Get-SlotPatternPlan -Rows @(
    [pscustomobject]@{ CrossCoord = 0.0 }
    [pscustomobject]@{ CrossCoord = 1.50002 }
    [pscustomobject]@{ CrossCoord = 2.99999 }
) -Tol 0.001
Assert-True "pat: gaps within Tol -> even" ($ppTol.CanPattern)

# empty / malformed / never-throws.
$ppEmpty = Get-SlotPatternPlan -Rows @()
Assert-True "pat: empty -> valid false, CanPattern false" ((-not $ppEmpty.Valid) -and (-not $ppEmpty.CanPattern))
$threwPP = $false
try { $null = Get-SlotPatternPlan -Rows $null } catch { $threwPP = $true }
Assert-True "pat: null Rows does NOT throw" (-not $threwPP)
$threwPP2 = $false; $ppMal = $null
try { $ppMal = Get-SlotPatternPlan -Rows @([pscustomobject]@{ Foo = 1 }, [pscustomobject]@{ CrossCoord = 2.0 }) } catch { $threwPP2 = $true }
Assert-True "pat: malformed row skipped, does NOT throw" ((-not $threwPP2) -and $ppMal.Count -eq 1)

# ----------------------------------------------------------------------------
# slotinator PATTERN-MODE plane reduction -- in pattern mode slotinator feeds only
# the FIRST row's 2 corners to Get-SharedPlanePlan (the seed's guide planes; the
# pattern replicates the seed, so rows 2..N need no planes), vs ALL corners in
# per-row mode. This encodes the exact speedup: fewer distinct offset planes, and
# the saving grows with row count. (Mirrors slotinator.cmd's $planeCorners choice.)
# ----------------------------------------------------------------------------
Write-Host "  -- slotinator: pattern-mode guide-plane reduction --" -ForegroundColor White
# 3x3 grid (3 rows). Non-zero offsets = the offset planes actually created (a ~0
# offset reuses a base datum, point-probe trick), matching slotinator's $tolP skip.
$prGeo   = Get-OrthogridGeometry -CcX 2.0 -CcZ 2.0 -Nx 3 -Nz 3 -Edge 2.0 -ClearDia 0.75
$prSlots = Get-RowSlots -Points $prGeo.Points -SlotWidth 0.75 -Width $prGeo.Width -Height $prGeo.Height -RowAxis 'X'
Assert-True "planes: 3x3 grid -> 3 rows" ($prSlots.Count -eq 3)
function Script:Count-OffsetPlanes($corners) {
    $pl = Get-SharedPlanePlan -Points $corners
    $n = @($pl.XCoords | Where-Object { [math]::Abs($_) -gt 1e-6 }).Count +
         @($pl.ZCoords | Where-Object { [math]::Abs($_) -gt 1e-6 }).Count
    return $n
}
$prAll   = Script:Count-OffsetPlanes $prSlots.Corners
$prFirst = Script:Count-OffsetPlanes @($prSlots.Rows[0].Corner0, $prSlots.Rows[0].Corner1)
Assert-True "planes: all-rows (3 rows) builds 7 offset planes"      ($prAll   -eq 7)
Assert-True "planes: first-row-only builds 3 offset planes"          ($prFirst -eq 3)
Assert-True "planes: pattern mode creates 4 fewer (7 -> 3)"          (($prAll - $prFirst) -eq 4)
# saving grows with row count: a 5-row grid saves even more than a 3-row grid.
$pr5Geo   = Get-OrthogridGeometry -CcX 2.0 -CcZ 2.0 -Nx 3 -Nz 5 -Edge 2.0 -ClearDia 0.75
$pr5Slots = Get-RowSlots -Points $pr5Geo.Points -SlotWidth 0.75 -Width $pr5Geo.Width -Height $pr5Geo.Height -RowAxis 'X'
$pr5All   = Script:Count-OffsetPlanes $pr5Slots.Corners
$pr5First = Script:Count-OffsetPlanes @($pr5Slots.Rows[0].Corner0, $pr5Slots.Rows[0].Corner1)
Assert-True "planes: first-row-only is constant (3) regardless of row count" ($pr5First -eq 3)
Assert-True "planes: saving grows with rows (5-row saves > 3-row saves)" `
    (($pr5All - $pr5First) -gt ($prAll - $prFirst))

# ----------------------------------------------------------------------------
# SUMMARY
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host ("  ============================================") -ForegroundColor Cyan
Write-Host ("  RESULTS: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { "Green" } else { "Red" })
Write-Host ("  ============================================") -ForegroundColor Cyan
Write-Host ""

if ($script:fail -gt 0) { exit 1 } else { exit 0 }
