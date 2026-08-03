# ============================================================================
# lib\tests\run_curved_surface_radius_tests.ps1 - offline unit tests for
# lib\curved_surface_radius.ps1 (the curved-DJ RADIAL-DISTANCE override producer).
# ============================================================================
# curved_surface_radius.ps1 is SELF-CONTAINED (the descriptor read is inlined), so
# these tests dot-source ONLY that file and drive it with FAKE COM stubs - no Creo,
# no other module. Covers: the New-CurvedRadialGeom shape, the single-surface
# cylinder read (cylinder / plane / throwing / null), the selection-buffer walk
# (first cylinder wins, -PreferSurfId, empty, null session), Format, and the JSON
# handoff round-trip.
#
# Run:  powershell -ExecutionPolicy Bypass -File lib\tests\run_curved_surface_radius_tests.ps1
# Exit 0 = all pass.
# ============================================================================

$ErrorActionPreference = "Stop"
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here
. (Join-Path $libDir 'curved_surface_radius.ps1')

$script:pass = 0; $script:fail = 0
function Assert-True { param([string]$Name, [bool]$Cond, [string]$Detail = "")
    if ($Cond) { Write-Host "  [PASS] $Name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  [FAIL] $Name  $Detail" -ForegroundColor Red; $script:fail++ }
}

# ----------------------------------------------------------------------------
# Fake COM builders. A cylinder surface exposes GetSurfaceDescriptor() -> a
# descriptor with GetSurfaceType()==1, a Radius property, and Origin (a transform
# with GetOrigin()/GetZAxis()). A plane returns type 2; a "bad" surface throws.
# ----------------------------------------------------------------------------
$ITEM_SURFACE = 5
$TypeObj = [pscustomobject]@{ ITEM_SURFACE = $ITEM_SURFACE }

function New-FakeCylSurf {
    param([int]$Id, [double]$Radius, $OriginPt = @(0, 0, 0), $ZAxis = @(0, 0, 1), [int]$Type = 1)
    $xf = [pscustomobject]@{ _o = @($OriginPt); _z = @($ZAxis) }
    $xf | Add-Member ScriptMethod GetOrigin { $this._o } -Force
    $xf | Add-Member ScriptMethod GetZAxis  { $this._z } -Force
    $desc = [pscustomobject]@{ Radius = $Radius; Origin = $xf; _t = $Type }
    $desc | Add-Member ScriptMethod GetSurfaceType { $this._t } -Force
    $surf = [pscustomobject]@{ Id = $Id; Type = $ITEM_SURFACE; _d = $desc }
    $surf | Add-Member ScriptMethod GetSurfaceDescriptor { $this._d } -Force
    return $surf
}
function New-FakePlaneSurf {
    param([int]$Id)
    return (New-FakeCylSurf -Id $Id -Radius 0 -Type 2)   # type 2 = not a cylinder
}
function New-FakeBadSurf {
    param([int]$Id)
    $surf = [pscustomobject]@{ Id = $Id; Type = $ITEM_SURFACE }
    $surf | Add-Member ScriptMethod GetSurfaceDescriptor { throw 'descriptor boom' } -Force
    return $surf
}
function New-FakeSession {
    param($SurfItems)   # array of surface objects; each wrapped as a buffer item
    $items = @($SurfItems | ForEach-Object { [pscustomobject]@{ SelItem = $_ } })
    $sess = [pscustomobject]@{ _c = $items }
    $sess | Add-Member ScriptMethod CurrentSelectionBuffer { [pscustomobject]@{ Contents = $this._c } } -Force
    return $sess
}

Write-Host ""
Write-Host "  -- New-CurvedRadialGeom (pure shape) --" -ForegroundColor White
$g = New-CurvedRadialGeom -Valid:$true -Radius 2.5 -AxisPt @(1, 2, 3) -AxisDir @(0, 0, 1) -SurfId 42 -Reason 'ok'
Assert-True "valid geom: Valid true"            ([bool]$g.Valid)
Assert-True "valid geom: Radius coerced double"  ([double]$g.Radius -eq 2.5)
Assert-True "valid geom: AxisPt triple"          (@($g.AxisPt).Count -eq 3 -and [double]$g.AxisPt[0] -eq 1.0)
Assert-True "valid geom: AxisDir triple"         (@($g.AxisDir).Count -eq 3 -and [double]$g.AxisDir[2] -eq 1.0)
Assert-True "valid geom: SurfId int"             ([int]$g.SurfId -eq 42)
Assert-True "valid geom: Source tag"             ([string]$g.Source -eq 'cylinder-descriptor')
$gi = New-CurvedRadialGeom -Valid:$false -Reason 'nope'
Assert-True "invalid geom: Valid false"          (-not $gi.Valid)
Assert-True "invalid geom: Radius null"          ($null -eq $gi.Radius)
Assert-True "invalid geom: AxisPt null"          ($null -eq $gi.AxisPt)

Write-Host ""
Write-Host "  -- Read-CurvedSurfaceCylinderGeom (single surface) --" -ForegroundColor White
$cyl = New-FakeCylSurf -Id 7 -Radius 3.125 -OriginPt @(1, 2, 3) -ZAxis @(0, 0, 1)
$rc = Read-CurvedSurfaceCylinderGeom -Surf $cyl -SurfId 7
Assert-True "cylinder: Valid true"               ([bool]$rc.Valid)
Assert-True "cylinder: Radius read"              ([double]$rc.Radius -eq 3.125)
Assert-True "cylinder: AxisPt read"              (@($rc.AxisPt).Count -eq 3 -and [double]$rc.AxisPt[0] -eq 1.0)
Assert-True "cylinder: AxisDir read"             (@($rc.AxisDir).Count -eq 3 -and [double]$rc.AxisDir[2] -eq 1.0)
Assert-True "cylinder: SurfId threads"           ([int]$rc.SurfId -eq 7)

$pl = New-FakePlaneSurf -Id 8
$rp = Read-CurvedSurfaceCylinderGeom -Surf $pl -SurfId 8
Assert-True "plane: Valid false"                 (-not $rp.Valid)
Assert-True "plane: reason says not a cylinder"  ([string]$rp.Reason -match 'not a cylinder')

$bad = New-FakeBadSurf -Id 9
$rb = Read-CurvedSurfaceCylinderGeom -Surf $bad -SurfId 9
Assert-True "throwing surface: Valid false (no throw)" (-not $rb.Valid)
Assert-True "throwing surface: reason = no descriptor"  ([string]$rb.Reason -match 'no surface descriptor')

$rn = Read-CurvedSurfaceCylinderGeom -Surf $null -SurfId 0
Assert-True "null surface: Valid false"          (-not $rn.Valid)

Write-Host ""
Write-Host "  -- Read-CurvedRadialGeomFromBuffer (selection walk) --" -ForegroundColor White
# a plane THEN a cylinder: the cylinder wins even though it is not first.
$sess1 = New-FakeSession @((New-FakePlaneSurf -Id 10), (New-FakeCylSurf -Id 11 -Radius 4.0))
$rb1 = Read-CurvedRadialGeomFromBuffer -Session $sess1 -TypeObj $TypeObj
Assert-True "buffer: first readable cylinder wins" ([bool]$rb1.Valid -and [int]$rb1.SurfId -eq 11 -and [double]$rb1.Radius -eq 4.0)

# two cylinders: -PreferSurfId picks the preferred one.
$sess2 = New-FakeSession @((New-FakeCylSurf -Id 20 -Radius 5.0), (New-FakeCylSurf -Id 21 -Radius 6.0))
$rb2 = Read-CurvedRadialGeomFromBuffer -Session $sess2 -TypeObj $TypeObj -PreferSurfId 21
Assert-True "buffer: PreferSurfId picks preferred cylinder" ([int]$rb2.SurfId -eq 21 -and [double]$rb2.Radius -eq 6.0)

# only planes: Valid false.
$sess3 = New-FakeSession @((New-FakePlaneSurf -Id 30), (New-FakePlaneSurf -Id 31))
$rb3 = Read-CurvedRadialGeomFromBuffer -Session $sess3 -TypeObj $TypeObj
Assert-True "buffer: no cylinder -> Valid false"  (-not $rb3.Valid)

# no surfaces at all.
$sess4 = New-FakeSession @()
$rb4 = Read-CurvedRadialGeomFromBuffer -Session $sess4 -TypeObj $TypeObj
Assert-True "buffer: empty selection -> Valid false" (-not $rb4.Valid -and ([string]$rb4.Reason -match 'no surface'))

# null session -> no buffer, no throw.
$rb5 = Read-CurvedRadialGeomFromBuffer -Session $null -TypeObj $TypeObj
Assert-True "buffer: null session -> Valid false (no throw)" (-not $rb5.Valid -and ([string]$rb5.Reason -match 'no selection buffer'))

Write-Host ""
Write-Host "  -- Format-CurvedRadialGeom --" -ForegroundColor White
Assert-True "format valid: mentions R= and cylinder"  ((Format-CurvedRadialGeom $rc) -match 'R=' -and (Format-CurvedRadialGeom $rc) -match 'cylinder')
Assert-True "format invalid: says none"               ((Format-CurvedRadialGeom $rp) -match 'none')
Assert-True "format null: says none (no throw)"        ((Format-CurvedRadialGeom $null) -match 'none')

Write-Host ""
Write-Host "  -- Save/Read-CurvedRadialGeom (JSON handoff round-trip) --" -ForegroundColor White
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("curved_radial_geom_test_{0}.json" -f ([System.IO.Path]::GetRandomFileName()))
try {
    $saved = Save-CurvedRadialGeom -Geom $rc -Path $tmp
    Assert-True "handoff: file written"              (Test-Path $saved)
    $back = Read-CurvedRadialGeom -Path $saved
    Assert-True "handoff: Valid preserved"           ([bool]$back.Valid)
    Assert-True "handoff: Radius preserved"          ([double]$back.Radius -eq 3.125)
    Assert-True "handoff: AxisDir preserved"         (@($back.AxisDir).Count -eq 3 -and [double]$back.AxisDir[2] -eq 1.0)
    Assert-True "handoff: SurfId preserved"          ([int]$back.SurfId -eq 7)
    $miss = Read-CurvedRadialGeom -Path (Join-Path ([System.IO.Path]::GetTempPath()) 'no_such_curved_radial.json')
    Assert-True "handoff: missing file -> Valid false" (-not $miss.Valid)
} finally {
    if (Test-Path $tmp) { Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue }
}

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ("  curved_surface_radius tests: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
Write-Host "  ============================================" -ForegroundColor Cyan
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
