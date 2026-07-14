# ============================================================================
# lib\tests\run_csys_tests.ps1 - offline unit tests for the csys engine
# ============================================================================
# Runs WITHOUT Creo and WITHOUT network. Exercises:
#  (1) the generic descriptor-read helpers in lib\creo_geometry.ps1 (still shipped;
#      general-purpose reads, kept though the new csys flow no longer needs them):
#      - Get-EdgeArcCenter    (round edge -> center + radius; straight/unreadable
#                              degrade to IsRound=$false, never throw)
#      - Read-CoordSysTransform (IpfcCoordSystem.CoordSys -> origin + axes; null
#                              when the read is unavailable, never throw)
#  (2) the PURE csys engine in lib\drilljig_core.ps1 (REWRITTEN 2026-07-13): the
#      3-plane-intersection coordinate system shared by csysinator.cmd + drilljig.cmd
#      STAGE 5 + drilljig-gui.cmd's Index stage:
#      - Build-CsysFromPlanesMacro (select 3 planes accumulated by ID -> ProCmdDatumCsys
#                                   -> stdbtn_1; the token structure is LOCKED so it
#                                   stays the proven 3-plane recipe with the point
#                                   command swapped for the csys command)
#      - Get-CsysShowMacro         (select by id -> ProCmdViewShow)
#      - Resolve-IndexHolePlanes   (registry lookup: selected hole/point -> its ordered
#                                   plane triple; match precedence + never-throw)
# COM objects are stubbed with pscustomobjects exposing the same member NAMES the
# real IpfcArc/CircleDescriptor / IpfcCoordSystem / IpfcTransform3D expose.
# Mirrors run_index_frame_tests.ps1 / run_tests.ps1 harness style.
#
# Run:  powershell -ExecutionPolicy Bypass -File lib\tests\run_csys_tests.ps1
# Exit code 0 = all passed, 1 = at least one failure.
# ============================================================================

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here
$repoDir = Split-Path -Parent $libDir
. (Join-Path $libDir 'creo_geometry.ps1')
# the csys engine lives in drilljig_core.ps1 (PURE builders + lookup are safe to
# dot-source offline; the COM helpers just sit unused without a live session).
. (Join-Path $libDir 'orthogrid.ps1')
. (Join-Path $libDir 'orthogrid_points.ps1')
. (Join-Path $libDir 'drilljig_core.ps1')

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

# ----------------------------------------------------------------------------
# Stub builders - stand in for the COM objects Get-EdgeArcCenter /
# Read-CoordSysTransform read. A pscustomobject with the same member NAMES is
# enough because the helpers only touch .GetCurveDescriptor()/.Center/.Radius/.End1
# and .CoordSys/.GetOrigin()/.GetXAxis()/... - never a COM-only feature.
# ----------------------------------------------------------------------------

# An edge whose GetCurveDescriptor() returns an ARC descriptor (.Center + .Radius).
function New-StubArcEdge {
    param($Center, [double]$Radius)
    $desc = [pscustomobject]@{ Center = $Center; Radius = $Radius }
    return [pscustomobject]@{} |
        Add-Member -PassThru -MemberType ScriptMethod -Name GetCurveDescriptor -Value { $desc }.GetNewClosure()
}

# An edge whose descriptor is a straight LINE: has .End1, NO .Center.
function New-StubLineEdge {
    # .Center intentionally absent; .End1 present (a non-null marker object).
    $desc = [pscustomobject]@{ End1 = [pscustomobject]@{ x = 0.0 } }
    return [pscustomobject]@{} |
        Add-Member -PassThru -MemberType ScriptMethod -Name GetCurveDescriptor -Value { $desc }.GetNewClosure()
}

# An edge whose GetCurveDescriptor() THROWS (unreadable / foreign descriptor).
function New-StubThrowingEdge {
    return [pscustomobject]@{} |
        Add-Member -PassThru -MemberType ScriptMethod -Name GetCurveDescriptor -Value { throw "no descriptor" }
}

# A coordinate system whose .CoordSys transform exposes GetOrigin/GetXAxis/etc.
function New-StubCsys {
    param($Origin, $X, $Y, $Z)
    $xf = [pscustomobject]@{} |
        Add-Member -PassThru -MemberType ScriptMethod -Name GetOrigin -Value { $Origin }.GetNewClosure() |
        Add-Member -PassThru -MemberType ScriptMethod -Name GetXAxis  -Value { $X }.GetNewClosure() |
        Add-Member -PassThru -MemberType ScriptMethod -Name GetYAxis  -Value { $Y }.GetNewClosure() |
        Add-Member -PassThru -MemberType ScriptMethod -Name GetZAxis  -Value { $Z }.GetNewClosure()
    return [pscustomobject]@{ CoordSys = $xf }
}

Write-Host ""
Write-Host "  Running csys engine unit tests (offline)..." -ForegroundColor Cyan
Write-Host ""

# ----------------------------------------------------------------------------
# Get-EdgeArcCenter
# ----------------------------------------------------------------------------
Write-Host "  -- Get-EdgeArcCenter --" -ForegroundColor White

# round arc edge -> center + radius extracted, IsRound
$arc = New-StubArcEdge -Center @(2.0, 3.0, -1.5) -Radius 0.25
$r = Get-EdgeArcCenter -Edge $arc
Assert-True "arc: IsRound"        ($r.IsRound)
Assert-True "arc: Kind=arc"       ($r.Kind -eq 'arc')
Assert-True "arc: center read"    ($null -ne $r.Center -and (Approx $r.Center[0] 2.0) -and (Approx $r.Center[1] 3.0) -and (Approx $r.Center[2] -1.5))
Assert-True "arc: radius read"    (Approx $r.Radius 0.25)

# straight line edge -> rejected as straight, no center, no throw
$line = New-StubLineEdge
$rl = Get-EdgeArcCenter -Edge $line
Assert-True "line: not round"     (-not $rl.IsRound)
Assert-True "line: Kind=straight" ($rl.Kind -eq 'straight')
Assert-True "line: no center"     ($null -eq $rl.Center)

# throwing descriptor -> IsRound=$false, Kind=no-descriptor, no throw
$thrown = $false
try { $rt = Get-EdgeArcCenter -Edge (New-StubThrowingEdge) } catch { $thrown = $true }
Assert-True "throwing edge: no throw"          (-not $thrown)
Assert-True "throwing edge: not round"         (-not $rt.IsRound)
Assert-True "throwing edge: Kind=no-descriptor" ($rt.Kind -eq 'no-descriptor')

# $null edge -> benign 'none'
$rn = Get-EdgeArcCenter -Edge $null
Assert-True "null edge: not round"  (-not $rn.IsRound)
Assert-True "null edge: Kind=none"  ($rn.Kind -eq 'none')

# arc with unreadable radius still yields the center (radius best-effort)
$arcNoR = [pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptMethod -Name GetCurveDescriptor -Value {
    [pscustomobject]@{ Center = @(1.0, 1.0, 1.0) }   # no Radius member
}
$rnr = Get-EdgeArcCenter -Edge $arcNoR
Assert-True "arc-no-radius: IsRound"     ($rnr.IsRound)
Assert-True "arc-no-radius: center read" ($null -ne $rnr.Center -and (Approx $rnr.Center[0] 1.0))

# CIRCULAR edge whose .Center is UNREADABLE on this build (has Radius, no Center,
# no straight-edge .End1) -> must still be ROUND so creation proceeds; center null
# so the caller degrades to visual verification. This locks in the honesty-bar fix:
# "is it round" must NOT be conflated with "could I read the center".
$arcNoCenter = [pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptMethod -Name GetCurveDescriptor -Value {
    [pscustomobject]@{ Radius = 0.5 }   # radius only: no Center, no End1
}
$rnc = Get-EdgeArcCenter -Edge $arcNoCenter
Assert-True "arc-no-center: IsRound (creation not blocked)" ($rnc.IsRound)
Assert-True "arc-no-center: Kind=arc-no-center"             ($rnc.Kind -eq 'arc-no-center')
Assert-True "arc-no-center: center is null (verify visually)" ($null -eq $rnc.Center)
Assert-True "arc-no-center: radius still read"              (Approx $rnc.Radius 0.5)

# fully unreadable descriptor (no Center, no Radius, no End1) -> NOT round, benign
$blank = [pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptMethod -Name GetCurveDescriptor -Value {
    [pscustomobject]@{}   # nothing readable
}
$rbl = Get-EdgeArcCenter -Edge $blank
Assert-True "blank descriptor: not round"           (-not $rbl.IsRound)
Assert-True "blank descriptor: Kind=no-descriptor"  ($rbl.Kind -eq 'no-descriptor')

# ----------------------------------------------------------------------------
# Read-CoordSysTransform
# ----------------------------------------------------------------------------
Write-Host "  -- Read-CoordSysTransform --" -ForegroundColor White

$cs = New-StubCsys -Origin @(5.0, 6.0, 7.0) -X @(1.0,0.0,0.0) -Y @(0.0,1.0,0.0) -Z @(0.0,0.0,1.0)
$t = Read-CoordSysTransform -Csys $cs
Assert-True "csys: transform read"  ($null -ne $t)
Assert-True "csys: origin"          ($null -ne $t -and (Approx $t.Origin[0] 5.0) -and (Approx $t.Origin[1] 6.0) -and (Approx $t.Origin[2] 7.0))
Assert-True "csys: +X"              ($null -ne $t -and (Approx $t.X[0] 1.0))
Assert-True "csys: +Z"              ($null -ne $t -and (Approx $t.Z[2] 1.0))

# $null csys -> $null, no throw
$thrown2 = $false
try { $tn = Read-CoordSysTransform -Csys $null } catch { $thrown2 = $true }
Assert-True "null csys: no throw"   (-not $thrown2)
Assert-True "null csys: null result" ($null -eq $tn)

# csys whose .CoordSys throws -> $null, no throw
$badCs = [pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptProperty -Name CoordSys -Value { throw "unavailable" }
$thrown3 = $false
try { $tb = Read-CoordSysTransform -Csys $badCs } catch { $thrown3 = $true }
Assert-True "throwing csys: no throw"    (-not $thrown3)
Assert-True "throwing csys: null result" ($null -eq $tb)

# csys with an unreadable origin (GetOrigin returns null) -> $null (origin required)
$csNoOrigin = New-StubCsys -Origin $null -X @(1.0,0.0,0.0) -Y @(0.0,1.0,0.0) -Z @(0.0,0.0,1.0)
$tno = Read-CoordSysTransform -Csys $csNoOrigin
Assert-True "csys-no-origin: null result" ($null -eq $tno)

# origin reads fine but an AXIS read THROWS -> origin still returned, that axis null
# (axes are best-effort, each in its own try/catch; a bad axis must not lose origin)
$xfBadZ = [pscustomobject]@{} |
    Add-Member -PassThru -MemberType ScriptMethod -Name GetOrigin -Value { @(9.0, 8.0, 7.0) } |
    Add-Member -PassThru -MemberType ScriptMethod -Name GetXAxis  -Value { @(1.0, 0.0, 0.0) } |
    Add-Member -PassThru -MemberType ScriptMethod -Name GetYAxis  -Value { @(0.0, 1.0, 0.0) } |
    Add-Member -PassThru -MemberType ScriptMethod -Name GetZAxis  -Value { throw "axis unavailable" }
$csBadZ = [pscustomobject]@{ CoordSys = $xfBadZ }
$thrown4 = $false
try { $tbz = Read-CoordSysTransform -Csys $csBadZ } catch { $thrown4 = $true }
Assert-True "throwing-axis: no throw"        (-not $thrown4)
Assert-True "throwing-axis: origin survived" ($null -ne $tbz -and (Approx $tbz.Origin[0] 9.0) -and (Approx $tbz.Origin[2] 7.0))
Assert-True "throwing-axis: bad Z is null"   ($null -ne $tbz -and $null -eq $tbz.Z)
Assert-True "throwing-axis: good X kept"     ($null -ne $tbz -and (Approx $tbz.X[0] 1.0))

# ----------------------------------------------------------------------------
# Build-CsysFromPlanesMacro - the 3-plane-intersection csys recipe. Selects the
# 3 planes accumulated BY ID (1st clears the buffer, 2nd/3rd -NoClear accumulate),
# then ProCmdDatumCsys -> stdbtn_1. This MUST stay the proven Build-IntersectPointMacro
# recipe with ProCmdDatumPointGeneral swapped for ProCmdDatumCsys - the token asserts
# below lock that (and lock OUT the scrapped edge-origin orientation widgets).
# ----------------------------------------------------------------------------
Write-Host "  -- Build-CsysFromPlanesMacro (3 planes by ID -> ProCmdDatumCsys -> OK) --" -ForegroundColor White

if (Get-Command Build-CsysFromPlanesMacro -ErrorAction SilentlyContinue) {
    $mc = Build-CsysFromPlanesMacro -PlaneIds @(101, 202, 303)
    Assert-True "csysmacro: fires ProCmdDatumCsys"        ($mc.Contains('~ Command `ProCmdDatumCsys`'))
    Assert-True "csysmacro: OK via stdbtn_1"              ($mc.Contains('~ Activate `Odui_Dlg_00` `stdbtn_1`'))
    Assert-True "csysmacro: NOT the point command"        (-not $mc.Contains('ProCmdDatumPointGeneral'))
    # all three plane ids are fed to the tree-search
    Assert-True "csysmacro: plane 101 fed by id"          ($mc.Contains('`101`'))
    Assert-True "csysmacro: plane 202 fed by id"          ($mc.Contains('`202`'))
    Assert-True "csysmacro: plane 303 fed by id"          ($mc.Contains('`303`'))
    # exactly ONE buffer_clean (the 1st select clears; the 2nd/3rd accumulate -NoClear)
    $clears = ([regex]::Matches($mc, 'buffer_clean')).Count
    Assert-True "csysmacro: exactly one buffer_clear (accumulate 2nd/3rd)" ($clears -eq 1)
    # regression lock: NONE of the scrapped edge-origin orientation widgets
    foreach ($bad in @('t1.OriginPlacement','pg_vis_tab','tab_2','AxisMenu','FlipBtn','DirectionTable')) {
        Assert-True ("csysmacro: no scrapped widget {0}" -f $bad) (-not $mc.Contains($bad))
    }
} else {
    Assert-True "Build-CsysFromPlanesMacro resolves from drilljig_core.ps1" $false "function not found"
}

# ----------------------------------------------------------------------------
# Get-CsysShowMacro - unhide the created csys.
# ----------------------------------------------------------------------------
Write-Host "  -- Get-CsysShowMacro --" -ForegroundColor White
if (Get-Command Get-CsysShowMacro -ErrorAction SilentlyContinue) {
    $ms = Get-CsysShowMacro -FeatId 777
    Assert-True "showmacro: selects the feature by id" ($ms.Contains('`777`'))
    Assert-True "showmacro: fires ProCmdViewShow"      ($ms.Contains('ProCmdViewShow@PopupMenuTree'))
} else {
    Assert-True "Get-CsysShowMacro resolves from drilljig_core.ps1" $false "function not found"
}

# ----------------------------------------------------------------------------
# Resolve-IndexHolePlanes - registry lookup (selected hole/point -> plane triple).
# ----------------------------------------------------------------------------
Write-Host "  -- Resolve-IndexHolePlanes (registry lookup) --" -ForegroundColor White
if (Get-Command Resolve-IndexHolePlanes -ErrorAction SilentlyContinue) {
    $recs = @(
        [pscustomobject]@{ PointId=51; HoleFeatId=91; PlaneIds=@(3,10,20) },
        [pscustomobject]@{ PointId=52; HoleFeatId=92; PlaneIds=@(3,11,20) },
        [pscustomobject]@{ PointId=53; HoleFeatId=$null; PlaneIds=@(3,10,21) }   # never drilled -> no hole id
    )
    # match by HOLE feature id (the user selected the hole feature)
    $r1 = Resolve-IndexHolePlanes -Records $recs -FeatureIds @(92) -PointIds @()
    Assert-True "resolve: matches by hole feat id"    ($r1.Ok -and $r1.PointId -eq 52)
    Assert-True "resolve: returns that triple"        (($r1.PlaneIds -join ',') -eq '3,11,20')
    # match by a hole SUB-feature id (a hole can add axis/note features; a tree click
    # may surface one of those, not the primary hole feature) via HoleFeatIds.
    $recsSub = @([pscustomobject]@{ PointId=61; HoleFeatId=95; HoleFeatIds=@(95,96,97); PlaneIds=@(3,12,20) })
    $rs1 = Resolve-IndexHolePlanes -Records $recsSub -FeatureIds @(97) -PointIds @()
    Assert-True "resolve: matches a hole sub-feature id" ($rs1.Ok -and $rs1.PointId -eq 61 -and (($rs1.PlaneIds -join ',') -eq '3,12,20'))
    # HoleFeatId still wins as the returned canonical hole id
    Assert-True "resolve: sub-feature match reports primary hole id" ($rs1.HoleFeatId -eq 95)
    # match by datum POINT id (the user selected the point)
    $r2 = Resolve-IndexHolePlanes -Records $recs -FeatureIds @() -PointIds @(51)
    Assert-True "resolve: matches by point id"        ($r2.Ok -and (($r2.PlaneIds -join ',') -eq '3,10,20'))
    # a point-bearing feature can surface its point as a FEATURE id -> still resolves
    $r3 = Resolve-IndexHolePlanes -Records $recs -FeatureIds @(53) -PointIds @()
    Assert-True "resolve: point id via feature list"  ($r3.Ok -and $r3.PointId -eq 53)
    # HOLE-id precedence over point-id when both present in the same call
    $r4 = Resolve-IndexHolePlanes -Records $recs -FeatureIds @(91) -PointIds @(52)
    Assert-True "resolve: hole-id wins over point-id"  ($r4.Ok -and $r4.PointId -eq 51)
    # unknown selection -> not ok, no throw
    $r5 = Resolve-IndexHolePlanes -Records $recs -FeatureIds @(999) -PointIds @(888)
    Assert-True "resolve: unknown selection not ok"    (-not $r5.Ok)
    # empty registry (predefined mode) -> not ok, no throw
    $r6 = Resolve-IndexHolePlanes -Records @() -FeatureIds @(91) -PointIds @()
    Assert-True "resolve: empty registry not ok"       (-not $r6.Ok)
    # never throws on malformed records
    $thrownR = $false
    try { $rM = Resolve-IndexHolePlanes -Records @([pscustomobject]@{ Foo=1 }) -FeatureIds @(1) -PointIds @() } catch { $thrownR = $true }
    Assert-True "resolve: malformed record no throw"   (-not $thrownR -and -not $rM.Ok)
} else {
    Assert-True "Resolve-IndexHolePlanes resolves from drilljig_core.ps1" $false "function not found"
}

# ----------------------------------------------------------------------------
# Get-HolesRelativeToIndex - each hole's coordinate in the index csys frame
# (X = gridX - indexX, Y = 0, Z = gridZ - indexZ). Pure; never throws.
# ----------------------------------------------------------------------------
Write-Host "  -- Get-HolesRelativeToIndex (coords relative to the index hole) --" -ForegroundColor White
if (Get-Command Get-HolesRelativeToIndex -ErrorAction SilentlyContinue) {
    $hrecs = @(
        [pscustomobject]@{ PointId=51; HoleFeatId=91; GridX=0.5; GridZ=0.5 },
        [pscustomobject]@{ PointId=52; HoleFeatId=92; GridX=1.5; GridZ=0.5 },
        [pscustomobject]@{ PointId=53; HoleFeatId=93; GridX=0.5; GridZ=2.0 }
    )
    # index = point 52 at grid (1.5, 0.5)
    $hr = Get-HolesRelativeToIndex -Records $hrecs -IndexPointId 52 -Diameter 0.25
    Assert-True "rel: ok"                    ($hr.Ok)
    Assert-True "rel: 3 rows"                (@($hr.Rows).Count -eq 3)
    $r52 = @($hr.Rows | Where-Object { $_.PointId -eq 52 })[0]
    Assert-True "rel: index hole is at origin" ((Approx $r52.X_index 0.0) -and (Approx $r52.Z_index 0.0) -and $r52.IsIndexHole)
    Assert-True "rel: Y is always 0"         (@($hr.Rows | Where-Object { -not (Approx $_.Y_index 0.0) }).Count -eq 0)
    $r51 = @($hr.Rows | Where-Object { $_.PointId -eq 51 })[0]
    Assert-True "rel: hole 51 dX = 0.5-1.5 = -1.0" (Approx $r51.X_index -1.0)
    Assert-True "rel: hole 51 dZ = 0.5-0.5 = 0.0"  (Approx $r51.Z_index 0.0)
    $r53 = @($hr.Rows | Where-Object { $_.PointId -eq 53 })[0]
    Assert-True "rel: hole 53 dZ = 2.0-0.5 = 1.5"  (Approx $r53.Z_index 1.5)
    Assert-True "rel: carries diameter"      (Approx $r51.Diameter 0.25)
    Assert-True "rel: keeps raw grid coords" ((Approx $r51.GridX 0.5) -and (Approx $r53.GridZ 2.0))
    # index id not in the set -> not ok, no throw
    $hrBad = Get-HolesRelativeToIndex -Records $hrecs -IndexPointId 999 -Diameter 0.25
    Assert-True "rel: unknown index not ok"  (-not $hrBad.Ok)
    # empty records -> not ok, no throw
    $thrownH = $false
    try { $hrE = Get-HolesRelativeToIndex -Records @() -IndexPointId 1 } catch { $thrownH = $true }
    Assert-True "rel: empty records no throw" (-not $thrownH -and -not $hrE.Ok)
} else {
    Assert-True "Get-HolesRelativeToIndex resolves from drilljig_core.ps1" $false "function not found"
}

# ----------------------------------------------------------------------------
# Export-IndexHoleCsv - writes the rows to a real CSV in a temp dir, reads back.
# ----------------------------------------------------------------------------
Write-Host "  -- Export-IndexHoleCsv (writes a CSV) --" -ForegroundColor White
if (Get-Command Export-IndexHoleCsv -ErrorAction SilentlyContinue) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("djcsys_test_{0}.csv" -f ([System.IO.Path]::GetRandomFileName()))
    $recsE = @(
        [pscustomobject]@{ PointId=1; HoleFeatId=11; GridX=0.0; GridZ=0.0 },
        [pscustomobject]@{ PointId=2; HoleFeatId=12; GridX=1.0; GridZ=0.0 }
    )
    $er = Export-IndexHoleCsv -Records $recsE -IndexPointId 1 -Diameter 0.5 -Path $tmp
    Assert-True "export: ok"         ($er.Ok -and $er.Count -eq 2)
    Assert-True "export: file exists" (Test-Path $tmp)
    if (Test-Path $tmp) {
        $back = @(Import-Csv $tmp)
        Assert-True "export: 2 rows round-trip" ($back.Count -eq 2)
        $b2 = @($back | Where-Object { [int]$_.PointId -eq 2 })[0]
        Assert-True "export: hole 2 X_index = 1.0" (Approx ([double]$b2.X_index) 1.0)
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    # bad index -> not ok, no file needed
    $erBad = Export-IndexHoleCsv -Records $recsE -IndexPointId 999 -Diameter 0.5 -Path $tmp
    Assert-True "export: bad index not ok" (-not $erBad.Ok)
} else {
    Assert-True "Export-IndexHoleCsv resolves from drilljig_core.ps1" $false "function not found"
}

# ----------------------------------------------------------------------------
# Build-CsysOffsetPointsMacro - offset-csys datum points from the csys (UNVERIFIED
# widgets; the token structure is locked so a live recording can replace only the
# widget names, and the coords + csys id are threaded correctly).
# ----------------------------------------------------------------------------
Write-Host "  -- Build-CsysOffsetPointsMacro (csys-referenced points) --" -ForegroundColor White
if (Get-Command Build-CsysOffsetPointsMacro -ErrorAction SilentlyContinue) {
    $rowsM = @(
        [pscustomobject]@{ X_index=0.0;  Y_index=0.0; Z_index=0.0 },
        [pscustomobject]@{ X_index=1.25; Y_index=0.0; Z_index=-2.5 }
    )
    $mc = Build-CsysOffsetPointsMacro -CsysFeatId 404 -Rows $rowsM
    Assert-True "csyspts: selects the csys by id"        ($mc.Contains('`404`'))
    Assert-True "csyspts: fires ProCmdDatumPoint"        ($mc.Contains('~ Command `ProCmdDatumPoint`'))
    Assert-True "csyspts: offset-coordinate-system mode" ($mc.Contains('Offset Coordinate System'))
    Assert-True "csyspts: OK via stdbtn_1"               ($mc.Contains('~ Activate `Odui_Dlg_00` `stdbtn_1`'))
    Assert-True "csyspts: threads the X offset 1.25"     ($mc.Contains('`1.25`'))
    Assert-True "csyspts: threads the Z offset -2.5"     ($mc.Contains('`-2.5`'))
    # one add-row per coordinate
    $adds = ([regex]::Matches($mc, 'add_pnt_btn')).Count
    Assert-True "csyspts: one add-row per coordinate (2)" ($adds -eq 2)
    # NOT the 3-plane intersection command (that is a different feature)
    Assert-True "csyspts: not ProCmdDatumPointGeneral"   (-not $mc.Contains('ProCmdDatumPointGeneral'))
} else {
    Assert-True "Build-CsysOffsetPointsMacro resolves from drilljig_core.ps1" $false "function not found"
}

# ----------------------------------------------------------------------------
# Resolve-HoleFeatGroups - split new features into one contiguous group per hole
# (a hole can add >1 feature). Ok only on a clean multiple; never mis-attributes.
# ----------------------------------------------------------------------------
Write-Host "  -- Resolve-HoleFeatGroups (hole->feature grouping) --" -ForegroundColor White
if (Get-Command Resolve-HoleFeatGroups -ErrorAction SilentlyContinue) {
    # 1 feature per hole (k=1): 3 features, 3 holes
    $g1 = Resolve-HoleFeatGroups -NewFeatIds @(30,10,20) -HoleCount 3
    Assert-True "groups: k=1 ok"           ($g1.Ok -and $g1.PerHole -eq 1)
    Assert-True "groups: sorted ascending" ((($g1.Groups | ForEach-Object { $_[0] }) -join ',') -eq '10,20,30')
    # 2 features per hole (k=2): the OLD strict count==N would have SKIPPED this
    $g2 = Resolve-HoleFeatGroups -NewFeatIds @(11,12,21,22,31,32) -HoleCount 3
    Assert-True "groups: k=2 ok (the blank-HoleFeatId fix)" ($g2.Ok -and $g2.PerHole -eq 2)
    Assert-True "groups: hole 1 group = 11,12" (($g2.Groups[0] -join ',') -eq '11,12')
    Assert-True "groups: hole 3 group = 31,32" (($g2.Groups[2] -join ',') -eq '31,32')
    Assert-True "groups: 3 groups"             (@($g2.Groups).Count -eq 3)
    # not a clean multiple -> not ok (no mis-attribution)
    $g3 = Resolve-HoleFeatGroups -NewFeatIds @(1,2,3,4,5) -HoleCount 3
    Assert-True "groups: non-multiple not ok"  (-not $g3.Ok)
    # degenerate: no features / no holes -> not ok, no throw
    $thrownG = $false
    try { $g4 = Resolve-HoleFeatGroups -NewFeatIds @() -HoleCount 3 } catch { $thrownG = $true }
    Assert-True "groups: empty no throw"       (-not $thrownG -and -not $g4.Ok)
} else {
    Assert-True "Resolve-HoleFeatGroups resolves from drilljig_core.ps1" $false "function not found"
}

# ----------------------------------------------------------------------------
# Format-IndexHoleReport - the human-readable provenance report string (pure).
# ----------------------------------------------------------------------------
Write-Host "  -- Format-IndexHoleReport (provenance report) --" -ForegroundColor White
if (Get-Command Format-IndexHoleReport -ErrorAction SilentlyContinue) {
    $rrows = @(
        [pscustomobject]@{ Hole=1; PointId=1600; HoleFeatId=52; X_index=0.0; Y_index=0.0; Z_index=0.0; GridX=3.375; GridZ=3.375; Diameter=0.75; IsIndexHole=$true },
        [pscustomobject]@{ Hole=2; PointId=1602; HoleFeatId=53; X_index=0.0; Y_index=0.0; Z_index=3.0; GridX=3.375; GridZ=6.375; Diameter=0.75; IsIndexHole=$false }
    )
    $rep = Format-IndexHoleReport -Rows $rrows -Meta @{ PartNumber='004-921-0351-001'; CsysFeatId=52; Units='in'; WhenIso='2026-07-14T00:00:00' }
    Assert-True "report: has the part number"     ($rep.Contains('004-921-0351-001'))
    Assert-True "report: has the csys feature id" ($rep.Contains('52'))
    Assert-True "report: names the index hole"    ($rep.Contains('point 1600'))
    Assert-True "report: shows units"             ($rep.Contains('in'))
    Assert-True "report: counts 1 index + 1 other" ($rep.Contains('2  (1 index + 1 other)'))
    Assert-True "report: flags the index row YES" ($rep.Contains('YES'))
    Assert-True "report: has an axis-frame note"  ($rep.Contains('Verify axis SIGNS'))
    # never throws on empty meta / no index row
    $thrownF = $false
    try { $rep2 = Format-IndexHoleReport -Rows @($rrows[1]) -Meta @{} } catch { $thrownF = $true }
    Assert-True "report: empty meta no throw"     (-not $thrownF -and $rep2.Contains('(unknown)'))
} else {
    Assert-True "Format-IndexHoleReport resolves from drilljig_core.ps1" $false "function not found"
}

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host ("  csys tests: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
Write-Host ""
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
