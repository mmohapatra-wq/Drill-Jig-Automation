# ============================================================================
# lib\wpf3d_preview.ps1 - WPF Media3D mesh + scene builders for the drill-jig
# 3D preview. PURE construction (no Creo/COM); needs the WPF assemblies loaded
# by the caller (PresentationCore/PresentationFramework/WindowsBase) before any
# builder is CALLED. Shared by the standalone window (drilljig-3d-preview.cmd)
# and the headless render test; the eventual drilljig-gui integration reuses it.
#
# Media3D has NO boolean CSG, so:
#   * a hole is a DARK BORE cylinder that pokes through the plate (its end caps
#     read as drilled openings on the faces); the plate silhouette stays solid.
#   * a chip-relief slot is a translucent amber recessed box (one per hole row).
# Every model gets BackMaterial = Material so triangle winding never hides a face.
#
# All helpers are `function global:` so they resolve from the hybrid .cmd
# scriptblock::Create model (same convention as lib\orthogrid_gui.ps1).
#
# FRAME: X = plate width (right), Y = thickness (up), Z = plate depth. The plate
# is centered in X and Z; Y spans [0, thickness]. A hole at app (X,Z) maps to
# world (X - Width/2, y, Z - Height/2). This matches docs\drilljig_3d_preview.html.
# ============================================================================

function global:New-WpfP3D {
    param($x, $y, $z)
    New-Object System.Windows.Media.Media3D.Point3D -ArgumentList ([double]$x), ([double]$y), ([double]$z)
}

# Solid-color Diffuse material (optionally with a subtle white Specular for a
# metallic plate). $A < 255 gives translucency (used for slot markers).
function global:New-WpfMaterial {
    param([int]$R, [int]$G, [int]$B, [int]$A = 255, [switch]$Spec)
    $col   = [System.Windows.Media.Color]::FromArgb([byte]$A, [byte]$R, [byte]$G, [byte]$B)
    $brush = New-Object System.Windows.Media.SolidColorBrush($col)
    $diff  = New-Object System.Windows.Media.Media3D.DiffuseMaterial($brush)
    if (-not $Spec) { return $diff }
    $grp = New-Object System.Windows.Media.Media3D.MaterialGroup
    $grp.Children.Add($diff)
    $sb = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(255, 255, 255))
    $grp.Children.Add((New-Object System.Windows.Media.Media3D.SpecularMaterial($sb, 22)))
    return $grp
}

# Axis-aligned box mesh from (x0,y0,z0) to (x1,y1,z1). 8 verts / 12 triangles.
function global:New-WpfBoxMesh {
    param($x0, $y0, $z0, $x1, $y1, $z1)
    $m = New-Object System.Windows.Media.Media3D.MeshGeometry3D
    $v = @(@($x0,$y0,$z0), @($x1,$y0,$z0), @($x1,$y1,$z0), @($x0,$y1,$z0),
           @($x0,$y0,$z1), @($x1,$y0,$z1), @($x1,$y1,$z1), @($x0,$y1,$z1))
    foreach ($p in $v) { $m.Positions.Add((New-WpfP3D $p[0] $p[1] $p[2])) }
    $t = @(0,2,1, 0,3,2, 4,5,6, 4,6,7, 0,4,7, 0,7,3, 1,2,6, 1,6,5, 0,1,5, 0,5,4, 3,7,6, 3,6,2)
    foreach ($i in $t) { $m.TriangleIndices.Add([int]$i) }
    return $m
}

# Vertical cylinder (axis along Y) centered at (cx,cz), radius r, from y0 to y1.
function global:New-WpfCylinderMesh {
    param($cx, $cz, $r, $y0, $y1, [int]$seg = 16)
    $m = New-Object System.Windows.Media.Media3D.MeshGeometry3D
    for ($i = 0; $i -lt $seg; $i++) {
        $a = 2 * [math]::PI * $i / $seg
        $x = $cx + $r * [math]::Cos($a); $z = $cz + $r * [math]::Sin($a)
        $m.Positions.Add((New-WpfP3D $x $y0 $z))   # even index = bottom ring
        $m.Positions.Add((New-WpfP3D $x $y1 $z))   # odd  index = top ring
    }
    for ($i = 0; $i -lt $seg; $i++) {
        $a = 2*$i; $b = 2*$i+1; $c = 2*(($i+1)%$seg); $d = 2*(($i+1)%$seg)+1
        foreach ($ti in @($a,$c,$b, $b,$c,$d)) { $m.TriangleIndices.Add([int]$ti) }
    }
    $bc = $m.Positions.Count; $m.Positions.Add((New-WpfP3D $cx $y0 $cz))   # bottom cap center
    $tc = $m.Positions.Count; $m.Positions.Add((New-WpfP3D $cx $y1 $cz))   # top cap center
    for ($i = 0; $i -lt $seg; $i++) {
        $b0 = 2*$i; $b1 = 2*(($i+1)%$seg)
        foreach ($ti in @($bc,$b1,$b0)) { $m.TriangleIndices.Add([int]$ti) }
        $t0 = 2*$i+1; $t1 = 2*(($i+1)%$seg)+1
        foreach ($ti in @($tc,$t0,$t1)) { $m.TriangleIndices.Add([int]$ti) }
    }
    return $m
}

function global:Add-WpfModel {
    param($group, $mesh, $mat)
    $gm = New-Object System.Windows.Media.Media3D.GeometryModel3D
    $gm.Geometry = $mesh; $gm.Material = $mat; $gm.BackMaterial = $mat
    $group.Children.Add($gm)
}

# Open cylinder SIDE WALL (no end caps), axis along Y, centered at (cx,cz), radius r,
# from y0 to y1. The building block for a HOLLOW tube (bore wall, body wall, head wall).
# Both faces render (caller sets BackMaterial), so winding direction is not critical.
function global:New-WpfCylWall {
    param($cx, $cz, $r, $y0, $y1, [int]$seg = 32)
    $m = New-Object System.Windows.Media.Media3D.MeshGeometry3D
    for ($i = 0; $i -lt $seg; $i++) {
        $a = 2 * [math]::PI * $i / $seg
        $x = $cx + $r * [math]::Cos($a); $z = $cz + $r * [math]::Sin($a)
        $m.Positions.Add((New-WpfP3D $x $y0 $z))   # even index = bottom ring
        $m.Positions.Add((New-WpfP3D $x $y1 $z))   # odd  index = top ring
    }
    for ($i = 0; $i -lt $seg; $i++) {
        $a = 2*$i; $b = 2*$i+1; $c = 2*(($i+1)%$seg); $d = 2*(($i+1)%$seg)+1
        foreach ($ti in @($a,$c,$b, $b,$c,$d)) { $m.TriangleIndices.Add([int]$ti) }
    }
    return $m
}

# Flat ANNULUS (washer) in the XZ plane at height y, from rInner to rOuter, centered
# at (cx,cz). The end ring of a tube and the head shoulder. rInner may be 0 (a disc).
function global:New-WpfAnnulus {
    param($cx, $cz, $rInner, $rOuter, $y, [int]$seg = 32)
    $m = New-Object System.Windows.Media.Media3D.MeshGeometry3D
    for ($i = 0; $i -lt $seg; $i++) {
        $a = 2 * [math]::PI * $i / $seg; $ca = [math]::Cos($a); $sa = [math]::Sin($a)
        $m.Positions.Add((New-WpfP3D ($cx + $rInner*$ca) $y ($cz + $rInner*$sa)))  # even = inner
        $m.Positions.Add((New-WpfP3D ($cx + $rOuter*$ca) $y ($cz + $rOuter*$sa)))  # odd  = outer
    }
    for ($i = 0; $i -lt $seg; $i++) {
        $ii = 2*$i; $io = 2*$i+1; $ni = 2*(($i+1)%$seg); $no = 2*(($i+1)%$seg)+1
        foreach ($ti in @($ii,$no,$io, $ii,$ni,$no)) { $m.TriangleIndices.Add([int]$ti) }
    }
    return $m
}

# ----------------------------------------------------------------------------
# Build-BushingModelGroup - a 3D bushing: a HOLLOW TUBE (outer OD wall + inner ID
# bore + end rings) with an optional HEAD flange (drill bushings are headed;
# sleeves headless - the head/no-head distinction the 2D schematic makes, in 3D).
# Axis along Y, centered at the origin. The BODY length is the catalog Length; the
# head is ADDED to the body (matching the 2D: Length excludes the head). No CSG is
# needed - the bore is a real inner wall, so the openings read as a true through-hole.
#   -OD -ID -Length   bushing dimensions (inch); ID must be < OD
#   -HeadDia          head OD (> OD => headed; <= OD or 0 => headless sleeve)
#   -Segments         cylinder facet count (default 40 - one part, so smooth)
# Returns an empty group on degenerate/invalid input (never throws).
# Model count: headless = 4 (bore, body wall, bottom ring, top ring);
#              headed   = 6 (+ head wall, shoulder ring; top ring spans ID->HeadDia).
# ----------------------------------------------------------------------------
function global:Build-BushingModelGroup {
    param([double]$OD, [double]$ID, [double]$Length, [double]$HeadDia = 0.0, [int]$Segments = 40)
    $grp = New-Object System.Windows.Media.Media3D.Model3DGroup
    if ($OD -le 0 -or $ID -le 0 -or $Length -le 0 -or $ID -ge $OD) { return $grp }
    $rB = $OD / 2.0; $rI = $ID / 2.0
    $headed  = ($HeadDia -gt $OD)
    $rH      = if ($headed) { $HeadDia / 2.0 } else { $rB }
    $headLen = if ($headed) { $OD * 0.3 } else { 0.0 }   # head axial length (matches the 2D)
    $H = $Length + $headLen
    $yBot = -$H / 2.0; $yBodyTop = $yBot + $Length; $yTop = $H / 2.0

    $steel   = New-WpfMaterial 154 167 189 255 -Spec
    $headMat = if ($headed) { New-WpfMaterial 178 189 209 255 -Spec } else { $steel }  # head a touch brighter
    $boreMat = New-WpfMaterial 14 21 36 255                                            # dark bore

    Add-WpfModel $grp (New-WpfCylWall 0 0 $rI $yBot $yTop $Segments)      $boreMat   # bore (full length)
    Add-WpfModel $grp (New-WpfCylWall 0 0 $rB $yBot $yBodyTop $Segments)  $steel     # body outer wall
    Add-WpfModel $grp (New-WpfAnnulus 0 0 $rI $rB $yBot $Segments)        $steel     # body bottom ring
    if ($headed) {
        Add-WpfModel $grp (New-WpfCylWall 0 0 $rH $yBodyTop $yTop $Segments) $headMat  # head outer wall
        Add-WpfModel $grp (New-WpfAnnulus 0 0 $rB $rH $yBodyTop $Segments)   $headMat  # shoulder (head underside)
        Add-WpfModel $grp (New-WpfAnnulus 0 0 $rI $rH $yTop $Segments)       $headMat  # head top ring
    } else {
        Add-WpfModel $grp (New-WpfAnnulus 0 0 $rI $rB $yTop $Segments)       $steel    # top ring
    }
    return $grp
}

# ----------------------------------------------------------------------------
# Build-JigModelGroup - assemble the full jig GEOMETRY group (plate box + one
# dark bore per hole + optional amber slot markers) from a Get-OrthogridGeometry
# / Get-CustomPointsGeometry result. Lights are NOT included (the caller adds
# them once). Returns an empty group on degenerate input (never throws).
#
#   -Geo        geometry result (.Width/.Height/.Points/.Valid, model units)
#   -Thickness  plate thickness (= bushing length + slot depth)
#   -HoleDia    drilled bore diameter (0 -> no bores)
#   -ShowSlots  include chip-relief slot markers (needs Get-RowSlots in scope)
#   -Segments   cylinder facet count (default 16)
# ----------------------------------------------------------------------------
function global:Build-JigModelGroup {
    param($Geo, [double]$Thickness, [double]$HoleDia, [double]$SlotDepth = 0.25, [switch]$ShowSlots, [int]$Segments = 16, [string]$RowAxis = 'X')
    $grp = New-Object System.Windows.Media.Media3D.Model3DGroup
    if ($null -eq $Geo) { return $grp }
    $w = [double]$Geo.Width; $h = [double]$Geo.Height; $t = [double]$Thickness
    if ($w -le 0 -or $h -le 0 -or $t -le 0) { return $grp }

    # plate (steel; red when the layout is invalid)
    $plateMat = if ($Geo.Valid) { New-WpfMaterial 154 167 189 255 -Spec } else { New-WpfMaterial 208 106 98 255 -Spec }
    Add-WpfModel $grp (New-WpfBoxMesh (-$w/2) 0 (-$h/2) ($w/2) $t ($h/2)) $plateMat

    # holes = dark bores poking ~3% beyond each face (caps read as openings)
    $r = $HoleDia / 2.0
    if ($r -gt 0 -and $Geo.Points) {
        $boreMat = New-WpfMaterial 14 21 36 255
        $poke = [math]::Max($t * 0.03, 0.01)
        foreach ($p in $Geo.Points) {
            $bore = New-WpfCylinderMesh ([double]$p.X - $w/2) ([double]$p.Z - $h/2) $r (-$poke) ($t + $poke) $Segments
            Add-WpfModel $grp $bore $boreMat
        }
    }

    # chip-relief slots = translucent amber recessed boxes (one per hole row),
    # recessed from the top by the actual slot depth (clamped to the thickness).
    if ($ShowSlots -and $Geo.Valid -and $HoleDia -gt 0) {
        try {
            # -RowAxis (default 'X') honors the fastener slot-direction choice; Get-RowSlots
            # returns Corner0/Corner1 in X/Z for either axis, and the box below reads X/Z
            # generically, so a 'Z' pick just reorients the recessed slabs with no other change.
            $ra = if (("$RowAxis").Trim().ToUpper() -eq 'Z') { 'Z' } else { 'X' }
            $slots = Get-RowSlots -Points $Geo.Points -SlotWidth $HoleDia -Width $w -Height $h -RowAxis $ra
            if ($slots.Valid -and $slots.Rows) {
                $slotMat = New-WpfMaterial 224 160 32 185
                $recess = [math]::Min($t, [math]::Max($SlotDepth, 0.01))
                foreach ($row in $slots.Rows) {
                    $sx0 = [double]$row.Corner0.X - $w/2; $sx1 = [double]$row.Corner1.X - $w/2
                    $sz0 = [double]$row.Corner0.Z - $h/2; $sz1 = [double]$row.Corner1.Z - $h/2
                    $sm = New-WpfBoxMesh $sx0 ($t - $recess) $sz0 $sx1 ($t + 0.004) $sz1
                    Add-WpfModel $grp $sm $slotMat
                }
            }
        } catch {}
    }
    return $grp
}
