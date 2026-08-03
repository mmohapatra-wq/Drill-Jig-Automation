# ============================================================================
# lib\curved_surface_radius.ps1 - RADIAL-DISTANCE read for the CURVED drill jig.
# ============================================================================
# The "read radial distance" HALF of the two-session curved radial-pattern effort
# (see the memory note project_curved_radial_slot_pattern). The radial-pattern
# session self-computes the axis pattern's count + angular increment from the
# fastener positions already in memory, and reads the value THIS half produces as
# an OVERRIDE ("self-compute + accept override"). This file is that producer: when
# the operator picks the surface the conformal jig follows, if that surface is a
# genuine CYLINDER we read its RADIUS + AXIS off the surface descriptor and hand it
# to the radial-pattern step via $ctx.RadialAxisGeom (and, optionally, a JSON
# handoff file for the cross-process console path).
#
# WHY the read is bounded to a cylinder: the ONLY confirmed-live radial read on
# this build is the cylinder surface descriptor path .GetSurfaceDescriptor() ->
# GetSurfaceType()==1 -> .Radius + .Origin(GetOrigin()/GetZAxis()) (the exact
# proven path Get-CylinderAxisFromSurface uses in lib\creo_geometry.ps1, facts
# cylinder-radius + cylinder-origin-transform-axes). A NON-cylindrical follow
# surface (general/spline/plane) has no readable radius here, so the geom comes
# back Valid=$false and the radial-pattern session simply falls back to its
# self-computed increment + operator-picked axis. Nothing regresses on a miss.
#
# EVERYTHING here is `function global:` so a wizard .GetNewClosure() step handler
# resolves it (the closure-scope rule, project_gui_scope_bugs) AND so the live COM
# read has ZERO dependency on any script-scoped helper in another module: the
# descriptor read is INLINED (mirrors Get-CylinderAxisFromSurface + Get-Comp
# verbatim) rather than calling across module scopes from inside a closure.
#
# Dot-source from a hybrid .cmd after $ScriptDir is set (no connection needed):
#     . (Join-Path $ScriptDir 'lib\curved_surface_radius.ps1')
# Also loadable in a plain PowerShell host - the offline unit tests dot-source it
# directly with fake COM stubs and no Creo. NEVER throws: every read miss degrades
# to a Valid=$false geom so a step handler can report "no radial override" instead
# of crashing the run.
# ============================================================================

# ----------------------------------------------------------------------------
# Get-CurvedRadialCompTriple - read a COM 3-vector (point/dir) into @(x,y,z).
# Mirrors Get-Comp (lib\creo_geometry.ps1): bracket index first, then .Item.
# Returns $null on an unreadable value (NEVER throws).
# ----------------------------------------------------------------------------
function global:Get-CurvedRadialCompTriple {
    param($V)
    if ($null -eq $V) { return $null }
    try   { return @([double]$V[0], [double]$V[1], [double]$V[2]) }
    catch {
        try { return @([double]$V.Item(0), [double]$V.Item(1), [double]$V.Item(2)) }
        catch { return $null }
    }
}

# ----------------------------------------------------------------------------
# New-CurvedRadialGeom - build the normalized RADIAL-DISTANCE override shape.
# This is the interface the radial-pattern session consumes ($ctx.RadialAxisGeom):
#   @{ Valid=<bool>; Radius=<double|null>; AxisPt=@(x,y,z)|null;
#      AxisDir=@(x,y,z)|null; SurfId=<int>; Source='cylinder-descriptor';
#      Reason=<string> }
# Pure (no COM). Coerces AxisPt/AxisDir to double triples. NEVER throws.
# ----------------------------------------------------------------------------
function global:New-CurvedRadialGeom {
    param(
        [bool]$Valid = $false,
        $Radius = $null,
        $AxisPt = $null,
        $AxisDir = $null,
        [int]$SurfId = 0,
        [string]$Reason = ''
    )
    $rr = $null
    if ($null -ne $Radius) { try { $rr = [double]$Radius } catch { $rr = $null } }
    return @{
        Valid   = [bool]$Valid
        Radius  = $rr
        AxisPt  = (Get-CurvedRadialCompTriple $AxisPt)
        AxisDir = (Get-CurvedRadialCompTriple $AxisDir)
        SurfId  = [int]$SurfId
        Source  = 'cylinder-descriptor'
        Reason  = [string]$Reason
    }
}

# ----------------------------------------------------------------------------
# Read-CurvedSurfaceCylinderGeom - read ONE surface COM item as a cylinder
# radius+axis. Mirrors Get-CylinderAxisFromSurface (lib\creo_geometry.ps1) but
# returns the New-CurvedRadialGeom override shape (Valid + Reason) so the caller
# always gets a structured answer. INLINED descriptor read = no cross-module call.
# NEVER throws.
# ----------------------------------------------------------------------------
function global:Read-CurvedSurfaceCylinderGeom {
    param($Surf, [int]$SurfId = 0)
    if ($null -eq $Surf) { return (New-CurvedRadialGeom -Valid:$false -SurfId $SurfId -Reason 'null surface') }
    $desc = $null
    try { $desc = $Surf.GetSurfaceDescriptor() } catch { return (New-CurvedRadialGeom -Valid:$false -SurfId $SurfId -Reason 'no surface descriptor') }
    if ($null -eq $desc) { return (New-CurvedRadialGeom -Valid:$false -SurfId $SurfId -Reason 'null descriptor') }
    $stype = $null
    try { $stype = [int]$desc.GetSurfaceType() } catch { return (New-CurvedRadialGeom -Valid:$false -SurfId $SurfId -Reason 'surface type unreadable') }
    if ($stype -ne 1) { return (New-CurvedRadialGeom -Valid:$false -SurfId $SurfId -Reason ("not a cylinder (surface type {0})" -f $stype)) }   # EpfcSURFACE_CYLINDER
    $r = $null
    try { $r = [double]$desc.Radius } catch {}
    $a = $null; $d = $null
    try {
        $xf = $desc.Origin                       # IpfcTransform3D
        $a = Get-CurvedRadialCompTriple $xf.GetOrigin()
        $d = Get-CurvedRadialCompTriple $xf.GetZAxis()
    } catch { return (New-CurvedRadialGeom -Valid:$false -SurfId $SurfId -Reason 'axis transform unreadable') }
    if ($null -eq $a -or $null -eq $d) { return (New-CurvedRadialGeom -Valid:$false -SurfId $SurfId -Reason 'axis origin/dir null') }
    if ($null -eq $r) { return (New-CurvedRadialGeom -Valid:$false -AxisPt $a -AxisDir $d -SurfId $SurfId -Reason 'radius unreadable') }
    return (New-CurvedRadialGeom -Valid:$true -Radius $r -AxisPt $a -AxisDir $d -SurfId $SurfId -Reason 'cylinder radius+axis read')
}

# ----------------------------------------------------------------------------
# Read-CurvedRadialGeomFromBuffer - read the LIVE selection buffer into a radial
# override. Walks Session.CurrentSelectionBuffer().Contents (the same buffer
# Resolve-SelectedSurfaces reads), and for each ITEM_SURFACE selection reads its
# cylinder geom, returning the FIRST readable cylinder. -PreferSurfId tries that
# id first (the surface-arm step passes the surface it defaulted the fastener
# orientation from). If no surface is a readable cylinder, returns Valid=$false
# with the last read miss reason. NEVER throws.
# ----------------------------------------------------------------------------
function global:Read-CurvedRadialGeomFromBuffer {
    param($Session, $TypeObj, [int]$PreferSurfId = 0)
    $contents = $null
    try { $contents = ($Session.CurrentSelectionBuffer()).Contents } catch {}
    if ($null -eq $contents) { return (New-CurvedRadialGeom -Valid:$false -Reason 'no selection buffer') }
    $pairs = @()
    foreach ($item in $contents) {
        $si = $null
        try { $si = $item.SelItem } catch { continue }
        if ($null -eq $si) { continue }
        $isSurf = $false
        try { $isSurf = ([int]$si.Type -eq [int]$TypeObj.ITEM_SURFACE) } catch {}
        if (-not $isSurf) { continue }
        $id = 0; try { $id = [int]$si.Id } catch { $id = 0 }
        $pairs += @{ Id = $id; Surf = $si }
    }
    if (@($pairs).Count -lt 1) { return (New-CurvedRadialGeom -Valid:$false -Reason 'no surface in selection') }
    # preferred id first, then the rest (a cylinder anywhere in the pick wins).
    $ordered = @()
    if ($PreferSurfId -gt 0) { $ordered += @($pairs | Where-Object { $_.Id -eq $PreferSurfId }) }
    $ordered += @($pairs | Where-Object { ($PreferSurfId -le 0) -or ($_.Id -ne $PreferSurfId) })
    $lastReason = 'no cylindrical surface in selection'
    foreach ($p in $ordered) {
        $g = Read-CurvedSurfaceCylinderGeom -Surf $p.Surf -SurfId ([int]$p.Id)
        if ($g.Valid) { return $g }
        if ($g.Reason) { $lastReason = $g.Reason }
    }
    return (New-CurvedRadialGeom -Valid:$false -SurfId ([int]@($pairs)[0].Id) -Reason $lastReason)
}

# ----------------------------------------------------------------------------
# Format-CurvedRadialGeom - one-line human summary for a verify message / chip.
# Pure. NEVER throws.
# ----------------------------------------------------------------------------
function global:Format-CurvedRadialGeom {
    param($Geom)
    if ($null -eq $Geom -or -not $Geom.Valid) {
        $why = if ($null -ne $Geom -and $Geom.Reason) { [string]$Geom.Reason } else { 'not a cylinder' }
        return ("Radial override: none ({0})." -f $why)
    }
    $r = if ($null -ne $Geom.Radius) { [Math]::Round([double]$Geom.Radius, 4) } else { '?' }
    return ("Radial override: cylinder R={0} (surf id {1}) - available to the radial-pattern step." -f $r, [int]$Geom.SurfId)
}

# ----------------------------------------------------------------------------
# Save-CurvedRadialGeom / Read-CurvedRadialGeom - the optional FILE handoff (the
# "handoff file" alternative to the ctx field), mirroring Save/Read-FastenerLayout.
# The GUI runs the producer + consumer in ONE process so the ctx field is the live
# channel; the file is for the console/cross-process path + debugging. Pure IO.
# NEVER throws on a read miss (returns a Valid=$false geom).
# ----------------------------------------------------------------------------
function global:Save-CurvedRadialGeom {
    param([Parameter(Mandatory = $true)]$Geom, [Parameter(Mandatory = $true)][string]$Path)
    $obj = [pscustomobject]@{
        schema  = 'curved_radial_geom/v1'
        valid   = [bool]$Geom.Valid
        radius  = $Geom.Radius
        axisPt  = $Geom.AxisPt
        axisDir = $Geom.AxisDir
        surfId  = [int]$Geom.SurfId
        source  = [string]$Geom.Source
        reason  = [string]$Geom.Reason
    }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ($obj | ConvertTo-Json -Depth 6) | Set-Content -Path $Path -Encoding UTF8
    return $Path
}

function global:Read-CurvedRadialGeom {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path $Path)) { return (New-CurvedRadialGeom -Valid:$false -Reason 'handoff file not found') }
    $o = $null
    try { $o = (Get-Content -Raw -Path $Path | ConvertFrom-Json) } catch { return (New-CurvedRadialGeom -Valid:$false -Reason 'handoff file unparseable') }
    if ($null -eq $o) { return (New-CurvedRadialGeom -Valid:$false -Reason 'handoff file empty') }
    return (New-CurvedRadialGeom -Valid:([bool]$o.valid) -Radius $o.radius -AxisPt $o.axisPt -AxisDir $o.axisDir -SurfId ([int]$o.surfId) -Reason ([string]$o.reason))
}
