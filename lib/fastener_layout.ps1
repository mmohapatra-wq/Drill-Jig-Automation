# ============================================================================
# lib\fastener_layout.ps1 - PURE fastener-center -> 2D hole-layout projection
#                            + the file-based handoff (fastener_layout.json)
# ============================================================================
# Pure MATH + file I/O only - no COM, no network, no module-level state. Turns a
# list of 3D fastener CENTERS (read elsewhere off the live model) into the flat
# {X;Z} hole layout the drill-jig flow consumes, and persists it so the read
# (fastener part) and the build (blank jig part) can happen in separate Creo
# active models / separate runs.
#
# WHY THIS EXISTS: the user has a part/assembly full of fasteners and wants the
# jig's holes to land at those same positions. Reading the CENTERS off the model
# is the risky, COM-side half (see fastener-probe.cmd / fastenator.cmd - the ONLY
# proven non-crashing center read on this build is a cylinder bore's axis origin,
# NOT IpfcPoint.Point). This file is the SAFE half: given centers, it does the
# axis projection + handoff with pure arithmetic, fully unit-tested offline.
#
# Dot-source from a hybrid .cmd after $ScriptDir is set (no connection needed):
#     . (Join-Path $ScriptDir 'lib\fastener_layout.ps1')
# Also loadable in a plain PowerShell host - the offline unit tests
# (lib\tests\run_fastener_tests.ps1) dot-source it directly with no Creo.
#
# CONVENTION (matches orthogrid.ps1 / index_frame.ps1): a function that COMPUTES
# never throws - invalid input returns a result object with Valid=$false and
# Errors populated, best-effort geometry still filled in. A trap from a math
# helper would kill the whole automation run, so degrade loudly-but-gracefully.
#
# COM-array trap (documented in creo_geometry.ps1 / index_frame.ps1): the 3D
# centers arrive as COM Get-Comp results; build every derived scalar on its OWN
# line, never inside a comma-separated @(...) literal mixed with math, or PS 5.1
# tries op_* on the array object and throws.
#
# FRAME CONVENTION (matches Get-CustomPointsGeometry / Draw-AxisGlyph): the layout
# is a plate-corner frame - X runs right (TOP direction), Z runs up (FRONT
# direction), origin at the SIDE-face corner. Every projected point is a
# corner-relative offset >= Margin (so no point lands on the origin, which
# Get-CustomPointsGeometry would silently DROP - orthogrid.ps1:295).
# ============================================================================

# ----------------------------------------------------------------------------
# Get-AxisComponent - pull the model-axis component (0=X,1=Y,2=Z) out of one
# 3D center, honouring an optional sign. PURE, never throws: a bad axis token or
# non-numeric component yields $null so the caller can flag the point.
#
#   Center - a 3-element indexable (@(x,y,z), a COM Get-Comp result, ...).
#   Axis   - 'X' | 'Y' | 'Z' (case-insensitive). Anything else -> $null.
#   Sign   - +1 or -1 (default +1). Multiplies the read component.
# ----------------------------------------------------------------------------
function global:Get-AxisComponent {
    param($Center, [string]$Axis, [double]$Sign = 1.0)
    if ($null -eq $Center) { return $null }
    $idx = switch (("" + $Axis).Trim().ToUpper()) {
        'X'     { 0 }
        'Y'     { 1 }
        'Z'     { 2 }
        default { -1 }
    }
    if ($idx -lt 0) { return $null }
    $ok = $false
    try { $ok = ($Center.Count -ge ($idx + 1)) } catch { $ok = $false }
    if (-not $ok) {
        # some COM sequences don't expose .Count but DO index; try the read and
        # let a failure fall through to $null rather than assume a length.
        try { $null = $Center[$idx] } catch { return $null }
    }
    $c = $null
    try { $c = [double]$Center[$idx] } catch { return $null }
    if ($null -eq $c) { return $null }
    # NaN / Infinity guard - an unproven read can return junk; never propagate it.
    if ([double]::IsNaN($c) -or [double]::IsInfinity($c)) { return $null }
    $s = if ($Sign -lt 0) { -1.0 } else { 1.0 }
    return ($s * $c)
}

# ----------------------------------------------------------------------------
# Tiny vec3 helpers (file-local, FL- prefixed) - this lib's convention is to NOT
# depend on creo_geometry.ps1 being dot-sourced (the offline tests load it alone),
# so it carries its own Dot/Cross/Unit/Sub. Component-per-line to dodge the COM
# op_* on-array trap. @(x,y,z) double arrays in, same out.
# ----------------------------------------------------------------------------
function FL-Dot  { param($A,$B) return ([double]$A[0]*[double]$B[0] + [double]$A[1]*[double]$B[1] + [double]$A[2]*[double]$B[2]) }
function FL-Sub  { param($A,$B) $x=[double]$A[0]-[double]$B[0]; $y=[double]$A[1]-[double]$B[1]; $z=[double]$A[2]-[double]$B[2]; return @($x,$y,$z) }
function FL-Cross{ param($A,$B) $cx=[double]$A[1]*[double]$B[2]-[double]$A[2]*[double]$B[1]; $cy=[double]$A[2]*[double]$B[0]-[double]$A[0]*[double]$B[2]; $cz=[double]$A[0]*[double]$B[1]-[double]$A[1]*[double]$B[0]; return @($cx,$cy,$cz) }
function FL-Norm { param($A) return [Math]::Sqrt((FL-Dot $A $A)) }
function FL-Unit { param($A,[double]$Eps=1e-12) $n=FL-Norm $A; if ($n -lt $Eps) { return $null }; $ux=[double]$A[0]/$n; $uy=[double]$A[1]/$n; $uz=[double]$A[2]/$n; return @($ux,$uy,$uz) }

# ----------------------------------------------------------------------------
# FL-Eigen3Sym - eigen-decomposition of a SYMMETRIC 3x3 matrix by cyclic Jacobi
# rotations. Pure PS 5.1 (nested-array matrices - $A[i][j] - because the parser
# rejects $A[i,j] 2D indexing inside method-call args). Returns
#   @{ Vals = @(v0,v1,v2); Vecs = @(vec0,vec1,vec2) }  (columns of V; NOT sorted).
# Converges in a handful of sweeps for a 3x3; capped at 100 as a backstop.
# ----------------------------------------------------------------------------
function FL-Eigen3Sym {
    param([double]$a11,[double]$a12,[double]$a13,[double]$a22,[double]$a23,[double]$a33)
    $A = @(@([double]$a11,[double]$a12,[double]$a13), @([double]$a12,[double]$a22,[double]$a23), @([double]$a13,[double]$a23,[double]$a33))
    $V = @(@(1.0,0.0,0.0), @(0.0,1.0,0.0), @(0.0,0.0,1.0))
    for ($sweep = 0; $sweep -lt 100; $sweep++) {
        $off = [Math]::Abs($A[0][1]) + [Math]::Abs($A[0][2]) + [Math]::Abs($A[1][2])
        if ($off -lt 1e-18) { break }
        foreach ($pq in @(@(0,1), @(0,2), @(1,2))) {
            $p = $pq[0]; $q = $pq[1]
            $apq = $A[$p][$q]
            if ([Math]::Abs($apq) -lt 1e-300) { continue }
            $theta = ($A[$q][$q] - $A[$p][$p]) / (2.0 * $apq)
            if ($theta -eq 0) { $t = 1.0 } else { $t = [Math]::Sign($theta) / ([Math]::Abs($theta) + [Math]::Sqrt($theta*$theta + 1.0)) }
            $c = 1.0 / [Math]::Sqrt($t*$t + 1.0)
            $s = $t * $c
            $r = 3 - $p - $q
            $app = $A[$p][$p]; $aqq = $A[$q][$q]; $arp = $A[$r][$p]; $arq = $A[$r][$q]
            $A[$p][$p] = $c*$c*$app - 2.0*$s*$c*$apq + $s*$s*$aqq
            $A[$q][$q] = $s*$s*$app + 2.0*$s*$c*$apq + $c*$c*$aqq
            $A[$p][$q] = 0.0; $A[$q][$p] = 0.0
            $A[$r][$p] = $c*$arp - $s*$arq; $A[$p][$r] = $A[$r][$p]
            $A[$r][$q] = $s*$arp + $c*$arq; $A[$q][$r] = $A[$r][$q]
            for ($i = 0; $i -lt 3; $i++) {
                $vip = $V[$i][$p]; $viq = $V[$i][$q]
                $V[$i][$p] = $c*$vip - $s*$viq
                $V[$i][$q] = $s*$vip + $c*$viq
            }
        }
    }
    $vals = @([double]$A[0][0], [double]$A[1][1], [double]$A[2][2])
    $vec0 = @([double]$V[0][0], [double]$V[1][0], [double]$V[2][0])
    $vec1 = @([double]$V[0][1], [double]$V[1][1], [double]$V[2][1])
    $vec2 = @([double]$V[0][2], [double]$V[1][2], [double]$V[2][2])
    return @{ Vals = $vals; Vecs = @($vec0, $vec1, $vec2) }
}

# ----------------------------------------------------------------------------
# FL-BestFitNormal - the least-squares plane normal of a POINT CLOUD (the drilled
# holes are coplanar on the plate, so their point cloud defines the true plate
# normal - regardless of how each fastener's OWN axis is modelled; live data
# 2026-07-23 showed the fastener csys Z axis can lie IN the plate plane, so the
# axis is NOT a reliable normal, but the hole positions always are).
#
# The normal is the eigenvector of the SMALLEST eigenvalue of the centered
# covariance. Returns @{ Normal=@(x,y,z) unit; Flatness=<smallest/largest ratio>;
# Vals=@(sorted asc) } or $null when it cannot be trusted:
#   - fewer than 3 points, OR
#   - the TWO smallest eigenvalues are both ~0 relative to the largest (the points
#     are COLLINEAR - a single row of holes - so the normal is indeterminate).
# Flatness ~0 == perfectly coplanar; a large Flatness == the points are NOT
# coplanar (a mixed-panel selection) and the caller should warn.
# ----------------------------------------------------------------------------
function FL-BestFitNormal {
    param([array]$Points, [double]$CollinearTol = 1e-6)
    $pts = @()
    if ($null -ne $Points) { foreach ($p in $Points) { if ($null -ne $p) { $pts += ,$p } } }
    if ($pts.Count -lt 3) { return $null }
    $cx = 0.0; $cy = 0.0; $cz = 0.0
    foreach ($p in $pts) { $cx += [double]$p[0]; $cy += [double]$p[1]; $cz += [double]$p[2] }
    $np = [double]$pts.Count
    $cx = $cx / $np; $cy = $cy / $np; $cz = $cz / $np
    $xx = 0.0; $xy = 0.0; $xz = 0.0; $yy = 0.0; $yz = 0.0; $zz = 0.0
    foreach ($p in $pts) {
        $dx = [double]$p[0] - $cx; $dy = [double]$p[1] - $cy; $dz = [double]$p[2] - $cz
        $xx += $dx*$dx; $xy += $dx*$dy; $xz += $dx*$dz; $yy += $dy*$dy; $yz += $dy*$dz; $zz += $dz*$dz
    }
    $e = FL-Eigen3Sym $xx $xy $xz $yy $yz $zz
    # index eigenvalues ascending
    $idx = @(0,1,2)
    for ($i = 0; $i -lt 3; $i++) { for ($j = $i+1; $j -lt 3; $j++) { if ($e.Vals[$idx[$j]] -lt $e.Vals[$idx[$i]]) { $tmp = $idx[$i]; $idx[$i] = $idx[$j]; $idx[$j] = $tmp } } }
    $lo = [double]$e.Vals[$idx[0]]; $mid = [double]$e.Vals[$idx[1]]; $hi = [double]$e.Vals[$idx[2]]
    if ($hi -le 0) { return $null }                              # degenerate (all points coincident)
    if (($mid / $hi) -lt $CollinearTol) { return $null }         # collinear: normal indeterminate
    $nrm = FL-Unit $e.Vecs[$idx[0]]
    if ($null -eq $nrm) { return $null }
    $flat = $lo / $hi
    $spanRatio = $mid / $hi     # 2nd-largest span ratio: ~0 == collinear, larger == genuinely 2D
    return @{ Normal = $nrm; Flatness = [double]$flat; Vals = @($lo, $mid, $hi); SpanRatio = [double]$spanRatio }
}

# Project a vector onto the plane with unit normal $N; return @{ U = unit(in-plane part);
# Mag = |in-plane part| } or $null if the projection is degenerate (V ~ parallel to N).
# Component-per-line (COM-array trap). Used to pick valid in-plane layout axes.
function FL-ProjPlane {
    param($V, $N)
    if ($null -eq $V -or $null -eq $N) { return $null }
    $d = FL-Dot $V $N
    $px = [double]$V[0] - $d*[double]$N[0]
    $py = [double]$V[1] - $d*[double]$N[1]
    $pz = [double]$V[2] - $d*[double]$N[2]
    $mag = [Math]::Sqrt($px*$px + $py*$py + $pz*$pz)
    $u = FL-Unit @($px, $py, $pz)
    if ($null -eq $u) { return $null }
    return @{ U = $u; Mag = [double]$mag }
}

# Map an axis token to its global unit vector, honouring a sign. 'X'/'Y'/'Z' ->
# +/- the basis vector; anything else -> $null.
function FL-AxisVec {
    param([string]$Axis, [double]$Sign = 1.0)
    $s = if ($Sign -lt 0) { -1.0 } else { 1.0 }
    switch (("" + $Axis).Trim().ToUpper()) {
        'X' { return @($s, 0.0, 0.0) }
        'Y' { return @(0.0, $s, 0.0) }
        'Z' { return @(0.0, 0.0, $s) }
        default { return $null }
    }
}

# ----------------------------------------------------------------------------
# FL-BestGridAngle - the in-plane rotation (radians, in [0, pi/2)) that best ALIGNS
# a 2D point set to the axes: the angle that, applied to every point, MINIMISES the
# axis-aligned bounding-box area. For a filled rectangular grid that is the grid's own
# orientation; for a SQUARE grid it is 0 (a 45deg box is larger), so an already-aligned
# pattern is returned as ~0 (no rotation). Rotating-calipers idea, done as a coarse 1deg
# sweep + a 0.1deg refine (cheap for a few dozen holes; deterministic). PURE.
#   $Raw : array of objects with numeric .RX / .RZ (the projected in-plane coords).
# ----------------------------------------------------------------------------
function FL-BestGridAngle {
    param([array]$Raw, [double]$CoarseDeg = 1.0)
    if ($null -eq $Raw -or @($Raw).Count -lt 2) { return 0.0 }
    $areaAt = {
        param($th)
        $cs = [Math]::Cos($th); $sn = [Math]::Sin($th)
        $minx = [double]::MaxValue; $maxx = -[double]::MaxValue
        $miny = [double]::MaxValue; $maxy = -[double]::MaxValue
        foreach ($p in $Raw) {
            $u = [double]$p.RX; $v = [double]$p.RZ
            $nu = $u*$cs - $v*$sn
            $nv = $u*$sn + $v*$cs
            if ($nu -lt $minx) { $minx = $nu }; if ($nu -gt $maxx) { $maxx = $nu }
            if ($nv -lt $miny) { $miny = $nv }; if ($nv -gt $maxy) { $maxy = $nv }
        }
        return ($maxx - $minx) * ($maxy - $miny)
    }
    $bestDeg = 0.0; $bestArea = [double]::MaxValue
    for ($d = 0.0; $d -lt 90.0; $d += $CoarseDeg) {
        $a = & $areaAt ($d * [Math]::PI / 180.0)
        if ($a -lt $bestArea) { $bestArea = $a; $bestDeg = $d }
    }
    $lo = $bestDeg - $CoarseDeg; $hi = $bestDeg + $CoarseDeg
    for ($d = $lo; $d -le $hi; $d += 0.1) {
        $a = & $areaAt ($d * [Math]::PI / 180.0)
        if ($a -lt $bestArea) { $bestArea = $a; $bestDeg = $d }
    }
    # normalise into [0, 90)
    $nd = $bestDeg % 90.0
    if ($nd -lt 0) { $nd += 90.0 }
    return ($nd * [Math]::PI / 180.0)
}

# ----------------------------------------------------------------------------
# Get-FastenerPlaneFrame - build an in-plane orthonormal frame for the fastener
# PANEL from each fastener's OWN AXIS (user 2026-07-23: "every single bolt has
# its own axis that defines itself ... read to the assembly default coordinate
# system, and then the software does the math between all of the fasteners").
#
# WHY THIS EXISTS (the bug it fixes): the old ConvertTo-LayoutXZ kept two GLOBAL
# axis COMPONENTS of each origin and discarded the third. When the fastener panel
# is NOT square to the global X/Z plane (normal in a higher-level assembly), that
# naive drop COLLAPSES the real separation into the discarded axis - so points
# that are far apart on the panel land coincident (merged -> UNDER-COUNT) or
# near-coincident (the collision check errors "holes too close"). BOTH reported
# symptoms are the SAME projection bug.
#
# THE FIX: the fasteners are (near-)coaxial and their centers lie ON the panel.
# The panel NORMAL is the common fastener axis; projecting the origins onto the
# plane with that normal is an ISOMETRY, so every true hole-to-hole distance is
# preserved. As a bonus a bolt+washer+nut STACK is coaxial -> its members project
# to the SAME point and merge to one hole (correct), while distinct holes stay
# apart.
#
# Inputs:
#   Centers  - array of 3-element origins (@(x,y,z)/COM Get-Comp results).
#   Axes     - array PARALLEL to Centers of each fastener's axis direction
#              (@(x,y,z); need not be unit; a $null entry is skipped). For an
#              assembly this is GetTransform($true).GetZAxis(); for a part it is
#              the bore cylinder's .D.
#   AxisX/AxisZ (+Signs) - the GLOBAL axes the user chose as the layout's in-plane
#              X and Z REFERENCE directions. They are PROJECTED onto the plane
#              (Gram-Schmidt) so an axis-aligned panel reduces EXACTLY to keeping
#              those two global components (byte-identical to the old behaviour),
#              while a tilted panel gets the correct in-plane axes.
#
# Returns [pscustomobject] (NEVER throws):
#   Valid  [bool]      $true iff a normal AND both in-plane axes were derivable
#   Errors [string[]]
#   O      [double[3]] centroid of the centers (frame origin; the corner-shift
#                      downstream makes the absolute origin irrelevant)
#   N,Xhat,Zhat [double[3]] plane normal + in-plane unit axes ($null when invalid)
#   AxisSpreadDeg [double] max angle between any fastener axis and the mean normal
#                      (advisory - large => the "axes" are not really parallel)
# ----------------------------------------------------------------------------
function global:Get-FastenerPlaneFrame {
    param(
        [array]$Centers, [array]$Axes,
        [string]$AxisX = 'X', [string]$AxisZ = 'Z',
        [double]$AxisXSign = 1.0, [double]$AxisZSign = 1.0,
        [double]$Eps = 1e-9
    )
    $errors = @()
    $pts = @()
    if ($null -ne $Centers) { foreach ($c in $Centers) { if ($null -ne $c) { $pts += ,$c } } }
    if ($pts.Count -lt 1) {
        return [pscustomobject]@{ Valid=$false; Errors=@("no centers to build a plane from"); O=$null; N=$null; Xhat=$null; Zhat=$null; AxisSpreadDeg=$null; NormalSource='none'; Flatness=$null; SpanRatio=$null }
    }

    # centroid = frame origin (component-per-line: the file's COM-array trap rule -
    # a comma-separated @(math,math,math) literal misfires under PS 5.1)
    $ox=0.0; $oy=0.0; $oz=0.0
    foreach ($p in $pts) { $ox+=[double]$p[0]; $oy+=[double]$p[1]; $oz+=[double]$p[2] }
    $nPts = [double]$pts.Count
    $ocx = $ox / $nPts
    $ocy = $oy / $nPts
    $ocz = $oz / $nPts
    $O = @($ocx, $ocy, $ocz)

    # gather the fastener axes (for the advisory + the collinear fallback)
    $units = @()
    if ($null -ne $Axes) { foreach ($a in $Axes) { if ($null -ne $a) { $u = FL-Unit $a; if ($null -ne $u) { $units += ,$u } } } }

    # -- normal: PRIMARY = best-fit plane of the POINTS. The drilled holes are coplanar
    #    on the plate, so their point cloud defines the TRUE plate normal -- regardless
    #    of how each fastener's OWN axis is modelled (live 2026-07-23: the fastener csys
    #    Z axis read (1,0,0) LAY IN the plate plane, i.e. the axis was NOT the normal, so
    #    an axis-average normal projected the layout wrong; the point cloud is reliable).
    #    FALLBACK = sign-aligned average of the fastener axes, only when best-fit is
    #    indeterminate (fewer than 3 holes, or a single collinear row).
    $normalSource = 'points'
    $flatness = $null
    $spanRatio = $null
    $bf = FL-BestFitNormal -Points $pts
    if ($null -ne $bf) {
        $N = $bf.Normal
        $flatness = [double]$bf.Flatness
        $spanRatio = [double]$bf.SpanRatio
    } else {
        $normalSource = 'axis'
        if ($units.Count -lt 1) {
            return [pscustomobject]@{ Valid=$false; Errors=@("cannot derive a panel normal: fewer than 3 non-collinear holes AND no readable fastener axes"); O=$O; N=$null; Xhat=$null; Zhat=$null; AxisSpreadDeg=$null; NormalSource='none'; Flatness=$null; SpanRatio=$null }
        }
        $ref = $units[0]
        $sx=0.0; $sy=0.0; $sz=0.0
        foreach ($u in $units) {
            $sgn = if ((FL-Dot $u $ref) -lt 0) { -1.0 } else { 1.0 }   # anti-parallel returns must not cancel
            $sx += $sgn*$u[0]; $sy += $sgn*$u[1]; $sz += $sgn*$u[2]
        }
        $N = FL-Unit @($sx,$sy,$sz)
        if ($null -eq $N) {
            return [pscustomobject]@{ Valid=$false; Errors=@("fastener axes cancel out - cannot derive a panel normal"); O=$O; N=$null; Xhat=$null; Zhat=$null; AxisSpreadDeg=$null; NormalSource='axis'; Flatness=$null; SpanRatio=$null }
        }
        # GUARD (live 2026-07-23): the axis is a valid NORMAL only if the points have
        # ~ZERO spread ALONG it. If they spread along $N, the axis lies IN the hole
        # plane (the real 22-fastener panel: axis (1,0,0) in-plane, variance ratio 0.19)
        # and projecting perpendicular to it would COLLAPSE that spread -> reject rather
        # than silently distort. A legitimate single row perpendicular to its bolt axis
        # measures ratio ~0; the empty gap [0.001..0.1] makes 0.02 a robust cutoff.
        $sAlong = 0.0; $sTot = 0.0
        foreach ($p in $pts) {
            $dx = [double]$p[0]-[double]$O[0]; $dy = [double]$p[1]-[double]$O[1]; $dz = [double]$p[2]-[double]$O[2]
            $along = $dx*[double]$N[0] + $dy*[double]$N[1] + $dz*[double]$N[2]
            $sAlong += $along*$along
            $sTot   += $dx*$dx + $dy*$dy + $dz*$dz
        }
        $rAlong = if ($sTot -gt 0) { $sAlong / $sTot } else { 0.0 }
        if ($rAlong -ge 0.02) {
            return [pscustomobject]@{ Valid=$false; Errors=@("fastener axis lies in the hole plane (points spread along it) - cannot use it as the panel normal; select 3+ non-collinear fasteners (not one row/column) or pick layout axes explicitly"); O=$O; N=$null; Xhat=$null; Zhat=$null; AxisSpreadDeg=$null; NormalSource='axis-rejected'; Flatness=$null; SpanRatio=$null }
        }
    }

    # advisory: how non-parallel are the fastener axes vs the CHOSEN normal? For a
    # points-derived normal a LARGE value just means the fastener axis is not the plate
    # normal (fine -- the points win); it is NOT an error.
    $maxDeg = 0.0
    foreach ($u in $units) {
        $c = FL-Dot $u $N; if ($c -gt 1.0) { $c = 1.0 } elseif ($c -lt -1.0) { $c = -1.0 }
        $deg = [Math]::Acos([Math]::Abs($c)) * 180.0 / [Math]::PI
        if ($deg -gt $maxDeg) { $maxDeg = $deg }
    }

    # -- in-plane X/Z axes. PREFER the operator's chosen global axes projected onto the
    #    plane; but if a chosen axis is (near-)parallel to the normal it CANNOT lie in the
    #    plane (live 2026-07-23: a panel with normal (1,0,0) makes the default AxisX='X'
    #    degenerate), so AUTO-SUBSTITUTE the most-in-plane global axis. This makes the
    #    layout work for ANY panel orientation with no operator axis knowledge. Xhat/Zhat
    #    are an orthonormal in-plane basis regardless; spacing/count are preserved (an
    #    isometry) -- only the plate's in-plane ORIENTATION follows the chosen/auto axes.
    $MIN_INPLANE = 0.35   # a layout axis must keep >= this in-plane magnitude after projection
    $axVec = FL-AxisVec $AxisX $AxisXSign
    $azVec = FL-AxisVec $AxisZ $AxisZSign
    if ($null -eq $axVec) { $errors += "AxisX must be one of X/Y/Z (got '$AxisX')" }
    if ($null -eq $azVec) { $errors += "AxisZ must be one of X/Y/Z (got '$AxisZ')" }
    $Xhat = $null; $Zhat = $null
    if ($null -ne $axVec -and $null -ne $azVec) {
        # Xhat = operator's AxisX projected onto the plane, if it stays in-plane enough;
        # else auto-pick the global axis with the largest in-plane projection.
        $pxX = FL-ProjPlane $axVec $N
        if ($null -ne $pxX -and $pxX.Mag -ge $MIN_INPLANE) {
            $Xhat = $pxX.U
        } else {
            $bestU = $null; $bestMag = 0.0
            foreach ($g in @( (@(1.0,0.0,0.0)), (@(0.0,1.0,0.0)), (@(0.0,0.0,1.0)) )) {
                $pg = FL-ProjPlane $g $N
                if ($null -ne $pg -and $pg.Mag -gt $bestMag) { $bestMag = $pg.Mag; $bestU = $pg.U }
            }
            $Xhat = $bestU
        }
        if ($null -eq $Xhat) { $errors += "cannot form an in-plane X axis (degenerate plane)" }
        else {
            # Zhat = the UNIQUE in-plane axis perpendicular to Xhat (= N x Xhat), signed
            # toward the operator's AxisZ so the layout keeps the requested handedness.
            $zc = FL-Unit (FL-Cross $N $Xhat)
            if ($null -eq $zc) { $errors += "cannot form an in-plane Z axis (Xhat parallel to normal)" }
            else {
                $pzZ = FL-ProjPlane $azVec $N
                if ($null -ne $pzZ -and (FL-Dot $pzZ.U $zc) -lt 0) {
                    # flip sign toward AxisZ (component-per-line: @(math,math,math) is the COM-array trap)
                    $nzx = -1.0 * [double]$zc[0]
                    $nzy = -1.0 * [double]$zc[1]
                    $nzz = -1.0 * [double]$zc[2]
                    $Zhat = @($nzx, $nzy, $nzz)
                } else {
                    $Zhat = $zc
                }
            }
        }
    }

    $valid = ($errors.Count -eq 0 -and $null -ne $Xhat -and $null -ne $Zhat)
    return [pscustomobject]@{
        Valid = $valid; Errors = [string[]]$errors
        O = $O; N = $N; Xhat = $Xhat; Zhat = $Zhat
        AxisSpreadDeg = [double]$maxDeg
        NormalSource  = $normalSource          # 'points' (best-fit plane) | 'axis' (fallback) | 'axis-rejected' | 'none'
        Flatness      = $flatness              # smallest/largest eigenvalue ratio; ~0 = perfectly coplanar
        SpanRatio     = $spanRatio             # mid/largest eigenvalue ratio; ~0 = collinear selection
    }
}

# ----------------------------------------------------------------------------
# ConvertTo-LayoutXZ - project 3D fastener CENTERS onto the 2D jig layout plane
# the user chose, corner-shift so every point is a positive offset, and merge
# near-coincident stacks (a through-bolt reads as bolt + washer + nut cylinders
# at nearly the same (X,Z)). This is the PUBLIC CONTRACT fastenator.cmd + the
# drilljig import mode bind to.
#
# PROJECTION MODE (user 2026-07-23): when -Axes is supplied (each fastener's own
# axis, parallel to -Centers) a PANEL-PLANE frame is built (Get-FastenerPlaneFrame)
# and the centers are projected onto that plane - an ISOMETRY that preserves true
# hole-to-hole distances even when the panel is not square to the global axes.
# Without -Axes (or if a plane cannot be derived) it FALLS BACK to the legacy
# per-axis global-component projection (Frame='global'), byte-identical to before,
# so every existing caller/test is unchanged. For an axis-aligned panel the two
# modes agree exactly (the projected in-plane axes ARE the chosen global axes).
#
# WHY straight axis projection (not index_frame's Get-IndexFrame): the user picks
# which model axes map to layout X and Z explicitly, so the frame is GIVEN - the
# orthonormal-frame derivation (two index bores, averaged bore directions) buys
# nothing here and adds concepts that don't apply to raw fastener centers.
#
# Inputs:
#   Centers   - array of 3-element centers (@(x,y,z) / COM Get-Comp results).
#   AxisX     - which model axis becomes layout X: 'X' | 'Y' | 'Z'.
#   AxisZ     - which model axis becomes layout Z: 'X' | 'Y' | 'Z'.
#   AxisXSign - +1 / -1 (default +1): flip if the layout comes out mirrored on X
#               (same knob idea as drilljig's --index-flip-x).
#   AxisZSign - +1 / -1 (default +1).
#   Margin    - the border added to EVERY point after the corner-shift, so the
#               nearest fastener sits Margin in from the plate corner (>0). This
#               ALSO guarantees no point is (0,0), which Get-CustomPointsGeometry
#               would drop. Default 0.25. MUST be > 0 (rejected otherwise).
#   DedupTol  - two projected centers closer than this (straight-line, in the
#               layout plane) are merged to one hole. Default 1e-4 (numeric-dup
#               only). Set >= the hole diameter to merge real bolt+nut stacks so
#               they don't later trip Get-CustomPointsGeometry's collision floor.
#
# Returns a [pscustomobject] (NEVER throws):
#   Valid    [bool]      $true iff AxisX/AxisZ are valid axes AND Margin>0 AND
#                        DedupTol>=0 AND >=1 kept point AND every center projected
#                        to a numeric (x,z).
#   Errors   [string[]]  reasons when -not Valid (empty when Valid)
#   Points   [array] of [pscustomobject]@{ I; J; X; Z } - corner-relative, +Margin,
#                        every X/Z >= Margin. I = running kept index, J = 0. Same
#                        members Get-CustomPointsGeometry / the GUI preview read.
#   Count    [int]       kept points (after dedup)
#   Dropped  [int]       how many centers were merged away by dedup
#   Skipped  [int]       centers that could not be projected (bad component)
#   MinX/MinZ/MaxX/MaxZ  [double] the PRE-shift projected extents (provenance)
#   SpanX/SpanZ [double] MaxX-MinX / MaxZ-MinZ before shift (for the sanity canary)
#   AxisX/AxisZ [string]; AxisXSign/AxisZSign [double]; Margin/DedupTol [double] (echo)
#
# The kept Points feed Get-CustomPointsGeometry -Points $r.Points unchanged.
# global: scope so closures resolve it under the hybrid .cmd scriptblock model.
# ----------------------------------------------------------------------------
function global:ConvertTo-LayoutXZ {
    param(
        [array]$Centers,
        [string]$AxisX = 'X',
        [string]$AxisZ = 'Z',
        [double]$AxisXSign = 1.0,
        [double]$AxisZSign = 1.0,
        [double]$Margin = 0.25,
        [double]$DedupTol = 1e-4,
        [array]$Axes = $null,     # OPTIONAL each-fastener axis (parallel to Centers) -> panel-plane projection
        [switch]$AlignGrid        # de-rotate the pattern so rows/columns run parallel to the layout axes
    )

    $errors = @()

    # -- validate the axis picks up front ------------------------------------
    $axValid = @('X','Y','Z')
    $ax = ("" + $AxisX).Trim().ToUpper()
    $az = ("" + $AxisZ).Trim().ToUpper()
    if ($axValid -notcontains $ax) { $errors += "AxisX must be one of X/Y/Z (got '$AxisX')" }
    if ($axValid -notcontains $az) { $errors += "AxisZ must be one of X/Y/Z (got '$AxisZ')" }
    if ($ax -eq $az -and $axValid -contains $ax) {
        $errors += "AxisX and AxisZ must be DIFFERENT model axes (both '$ax') - the layout would collapse to a line"
    }
    if ($Margin -le 0)   { $errors += "Margin must be > 0 (got $Margin) - a 0 margin lets a corner fastener land on the origin, which the layout drops" }
    if ($DedupTol -lt 0) { $errors += "DedupTol must be >= 0 (got $DedupTol)" }

    # -- decide projection mode: panel-plane (if axes given) or legacy global ---
    # PANEL-PLANE (user 2026-07-23): project onto the plane whose normal is the
    # common fastener axis, so real inter-hole distances survive a tilted panel.
    # This is the FIX for both the under-count (collapsed points merge away) and
    # the "holes too close" errors (distorted distances) on higher-level assemblies.
    $frame = $null
    $frameMode = 'global'
    $axisSpreadDeg = $null
    $normalSource = 'global'
    $flatness = $null
    $spanRatio = $null
    # conditioning thresholds (measured 2026-07-23 on the real 22-fastener panel):
    # good 2D panels have SpanRatio (mid/hi eigenvalue) >= 0.06; collinear ones <= 3e-10.
    # coplanar panels have Flatness (lo/hi) ~0; a non-coplanar mix pushes it up.
    $TOL_SPAN = 1e-6
    $TOL_FLAT = 1e-3
    if ($null -ne $Axes -and @($Axes).Count -ge 1 -and $errors.Count -eq 0) {
        # PLANE MODE was REQUESTED (-Axes supplied). A plane that cannot be trusted must
        # FAIL LOUD -- NOT silently fall back to the legacy global drop, which on a tilted
        # panel compresses spacing by 1/sqrt2 and merges/mis-spaces distinct holes (the
        # "3->2" / "holes too close" bug, confirmed 2026-07-23). The front-ends already
        # show .Errors and gate on .Valid, so this surfaces with no UI change.
        $frame = Get-FastenerPlaneFrame -Centers $Centers -Axes $Axes -AxisX $ax -AxisZ $az -AxisXSign $AxisXSign -AxisZSign $AxisZSign
        $illReason = $null
        if ($null -eq $frame -or -not $frame.Valid) {
            $illReason = if ($null -ne $frame -and @($frame.Errors).Count -gt 0) { ($frame.Errors -join '; ') } `
                         else { "the selected fasteners are collinear (or fewer than 3) - they define a LINE, not a panel plane. Select at least 3 fasteners that are NOT all in one row/column." }
        } elseif ($null -ne $frame.SpanRatio -and [double]$frame.SpanRatio -le $TOL_SPAN) {
            $illReason = "the selected fasteners are collinear - they define a LINE, not a panel plane. Select fasteners that span the panel in two directions."
        } elseif ($null -ne $frame.Flatness -and [double]$frame.Flatness -ge $TOL_FLAT) {
            $illReason = "the selected fasteners are not coplanar (they span two surfaces) - select fasteners from a single flat panel."
        }
        if ($null -ne $illReason) {
            return [pscustomobject]@{
                Valid=$false; Errors=[string[]]@($illReason); Points=@(); Count=0; Dropped=0; Skipped=0;
                MinX=0.0; MinZ=0.0; MaxX=0.0; MaxZ=0.0; SpanX=0.0; SpanZ=0.0;
                AxisX=$ax; AxisZ=$az; AxisXSign=[double]$AxisXSign; AxisZSign=[double]$AxisZSign;
                Margin=[double]$Margin; DedupTol=[double]$DedupTol; Frame='plane'; AxisSpreadDeg=$null; NormalSource='none'; Flatness=$null; SpanRatio=$null; AlignAngleDeg=0.0
            }
        }
        $frameMode = 'plane'
        $axisSpreadDeg = [double]$frame.AxisSpreadDeg
        $normalSource = [string]$frame.NormalSource
        $flatness = $frame.Flatness
        $spanRatio = $frame.SpanRatio
    }

    # -- project every center to a raw (x,z); collect problems, never throw ---
    # PLANE mode: raw = the center's coordinates in the panel's in-plane (Xhat,Zhat)
    #   frame (an isometry). GLOBAL mode (legacy/fallback): raw = the two chosen
    #   global-axis components. For an axis-aligned panel the two AGREE exactly.
    $raw     = @()
    $skipped = 0
    $i = 0
    if ($null -ne $Centers) {
        foreach ($ctr in $Centers) {
            $rx = $null; $rz = $null
            if ($frameMode -eq 'plane') {
                # in-plane coords: R = ctr - O ; rx = R.Xhat ; rz = R.Zhat
                $okc = $false
                try { $okc = ($null -ne $ctr -and $ctr.Count -ge 3) } catch { $okc = $false }
                if ($okc) {
                    try {
                        $R = FL-Sub $ctr $frame.O
                        $rx = FL-Dot $R $frame.Xhat
                        $rz = FL-Dot $R $frame.Zhat
                        if ([double]::IsNaN($rx) -or [double]::IsInfinity($rx) -or [double]::IsNaN($rz) -or [double]::IsInfinity($rz)) { $rx = $null; $rz = $null }
                    } catch { $rx = $null; $rz = $null }
                }
            } else {
                $rx = Get-AxisComponent -Center $ctr -Axis $ax -Sign $AxisXSign
                $rz = Get-AxisComponent -Center $ctr -Axis $az -Sign $AxisZSign
            }
            if ($null -eq $rx -or $null -eq $rz) {
                $skipped++
                $i++
                continue
            }
            # component-per-line (COM-array trap): $rx / $rz are already scalars.
            $raw += [pscustomobject]@{ RX = [double]$rx; RZ = [double]$rz }
            $i++
        }
    }

    if ($skipped -gt 0) { $errors += "$skipped fastener center(s) could not be projected onto axes $ax/$az (non-numeric component)" }
    if ($raw.Count -lt 1) {
        if ($errors.Count -eq 0 -or $skipped -gt 0) { $errors += "no fastener centers projected to a usable (X,Z) - nothing to lay out" }
        return [pscustomobject]@{
            Valid=$false; Errors=[string[]]$errors; Points=@(); Count=0; Dropped=0; Skipped=[int]$skipped;
            MinX=0.0; MinZ=0.0; MaxX=0.0; MaxZ=0.0; SpanX=0.0; SpanZ=0.0;
            AxisX=$ax; AxisZ=$az; AxisXSign=[double]$AxisXSign; AxisZSign=[double]$AxisZSign;
            Margin=[double]$Margin; DedupTol=[double]$DedupTol; Frame=$frameMode; AxisSpreadDeg=$axisSpreadDeg; NormalSource=$normalSource; Flatness=$flatness; SpanRatio=$spanRatio; AlignAngleDeg=0.0
        }
    }

    # -- GRID ALIGNMENT (user 2026-07-23): de-rotate the in-plane pattern so its rows/
    #    columns run PERPENDICULAR to the layout axes (not diagonal) when the selected
    #    fasteners' grid is rotated relative to the chosen axes. Pure 2D rotation about the
    #    centroid = an ISOMETRY, so every hole-to-hole distance is preserved; only the
    #    orientation changes (and the plate shrinks from the diagonal extent to the true
    #    W x H). The angle is the one that MINIMISES the axis-aligned bounding-box area
    #    (rotating-calipers idea) -- for a filled rectangular grid that is the grid
    #    orientation, and for a SQUARE grid it correctly picks 0deg (a 45deg box is larger),
    #    so an already-aligned pattern is left unchanged (angle ~0). Off by default; the
    #    fastener consumers pass -AlignGrid.
    $alignDeg = 0.0
    if ($AlignGrid -and $raw.Count -ge 2) {
        $th = FL-BestGridAngle -Raw $raw           # radians in [0, pi/2)
        $alignDeg = $th * 180.0 / [Math]::PI
        if ([Math]::Abs($th) -gt 1e-9) {
            $cs = [Math]::Cos($th); $sn = [Math]::Sin($th)
            $rot = @()
            foreach ($p in $raw) {
                $u = [double]$p.RX; $v = [double]$p.RZ
                $nu = $u*$cs - $v*$sn
                $nv = $u*$sn + $v*$cs
                $rot += [pscustomobject]@{ RX = [double]$nu; RZ = [double]$nv }
            }
            $raw = $rot
        }
    }

    # -- pre-shift extents (provenance + the sanity canary's span) -----------
    $minX = ($raw | ForEach-Object { $_.RX } | Measure-Object -Minimum).Minimum
    $maxX = ($raw | ForEach-Object { $_.RX } | Measure-Object -Maximum).Maximum
    $minZ = ($raw | ForEach-Object { $_.RZ } | Measure-Object -Minimum).Minimum
    $maxZ = ($raw | ForEach-Object { $_.RZ } | Measure-Object -Maximum).Maximum

    # -- corner-shift so the nearest fastener sits at (Margin,Margin) --------
    # X = (rawX - minRawX) + Margin  ->  every X >= Margin > 0 (no origin drop).
    $shifted = @()
    foreach ($p in $raw) {
        $sx = ([double]$p.RX - [double]$minX) + [double]$Margin
        $sz = ([double]$p.RZ - [double]$minZ) + [double]$Margin
        $shifted += [pscustomobject]@{ X = [double]$sx; Z = [double]$sz }
    }

    # -- dedup near-coincident stacks (bolt + washer + nut) by (X,Z) proximity -
    # Merge any point within DedupTol (straight-line) of an already-kept point.
    # Merging by projected proximity is what keeps a through-fastener's several
    # collinear cylinders from becoming several overlapping holes downstream.
    $kept    = @()
    $dropped = 0
    foreach ($p in $shifted) {
        $isDup = $false
        foreach ($k in $kept) {
            $dx = [double]$p.X - [double]$k.X
            $dz = [double]$p.Z - [double]$k.Z
            $d  = [math]::Sqrt($dx * $dx + $dz * $dz)
            if ($d -le $DedupTol) { $isDup = $true; break }
        }
        if ($isDup) { $dropped++; continue }
        $kept += [pscustomobject]@{ I = $kept.Count; J = 0; X = [double]$p.X; Z = [double]$p.Z }
    }

    if ($kept.Count -lt 1) { $errors += "all projected centers merged away (DedupTol $DedupTol too large?)" }

    $valid = ($errors.Count -eq 0)
    return [pscustomobject]@{
        Valid     = $valid
        Errors    = [string[]]$errors
        Points    = $kept
        Count     = [int]$kept.Count
        Dropped   = [int]$dropped
        Skipped   = [int]$skipped
        MinX      = [double]$minX
        MinZ      = [double]$minZ
        MaxX      = [double]$maxX
        MaxZ      = [double]$maxZ
        SpanX     = [double]($maxX - $minX)
        SpanZ     = [double]($maxZ - $minZ)
        AxisX     = $ax
        AxisZ     = $az
        AxisXSign = [double]$AxisXSign
        AxisZSign = [double]$AxisZSign
        Margin    = [double]$Margin
        DedupTol  = [double]$DedupTol
        Frame     = $frameMode                # 'plane' (axes given, tilt-corrected) | 'global' (legacy)
        AxisSpreadDeg = $axisSpreadDeg         # advisory: max fastener-axis vs chosen-normal angle
        NormalSource  = $normalSource          # 'points' (best-fit plane) | 'axis' (fallback) | 'global'
        Flatness      = $flatness              # smallest/largest eigenvalue ratio; ~0 = perfectly coplanar
        SpanRatio     = $spanRatio             # mid/largest eigenvalue ratio; ~0 = collinear selection
        AlignAngleDeg = [double]$alignDeg      # in-plane de-rotation applied to align the grid to the axes (0 = none / not requested)
    }
}

# ----------------------------------------------------------------------------
# Test-FastenerLayoutSane - the honesty canary. The center read is unproven on
# this build, so before fastenator.cmd writes a layout (or drilljig trusts one)
# we assert the projected result is PLAUSIBLE - not silently garbage from a bad
# COM read. Cheap, deterministic, never throws.
#
#   Layout   - a ConvertTo-LayoutXZ result (or a Read-FastenerLayout result -
#              anything exposing .Points, .SpanX, .SpanZ).
#   MinSpan  - the layout must span at least this much on at least ONE axis
#              (a single-point layout has span 0 on both -> flagged unless
#              -AllowSinglePoint). Default 1e-6.
#   MaxExtent- reject a layout whose span exceeds this on either axis (a runaway
#              read - e.g. assembly-frame coords in the millions). Default 1e5.
#   AllowSinglePoint - a genuine 1-hole layout is legal; pass this to skip the
#              degenerate-span check.
#
# Returns [pscustomobject]@{ Ok; Warnings[]; Errors[] }. Ok=$false blocks a write.
# ----------------------------------------------------------------------------
function global:Test-FastenerLayoutSane {
    param(
        $Layout,
        [double]$MinSpan = 1e-6,
        [double]$MaxExtent = 1e5,
        [switch]$AllowSinglePoint
    )
    $errs  = @()
    $warns = @()
    if ($null -eq $Layout) {
        return [pscustomobject]@{ Ok=$false; Warnings=$warns; Errors=@("layout is null") }
    }
    $pts = @()
    try { $pts = @($Layout.Points) } catch { $pts = @() }
    if ($pts.Count -lt 1) { $errs += "layout has no points" }

    # every coordinate finite and non-negative (corner-relative frame)
    foreach ($p in $pts) {
        $bad = $false
        try {
            $x = [double]$p.X; $z = [double]$p.Z
            if ([double]::IsNaN($x) -or [double]::IsInfinity($x) -or [double]::IsNaN($z) -or [double]::IsInfinity($z)) { $bad = $true }
            if ($x -lt 0 -or $z -lt 0) { $bad = $true }
        } catch { $bad = $true }
        if ($bad) { $errs += "layout contains a non-finite or negative point"; break }
    }

    $spanX = 0.0; $spanZ = 0.0
    try { $spanX = [double]$Layout.SpanX } catch {}
    try { $spanZ = [double]$Layout.SpanZ } catch {}
    if (-not $AllowSinglePoint -and $pts.Count -gt 1) {
        if ($spanX -lt $MinSpan -and $spanZ -lt $MinSpan) {
            $errs += "layout spans < $MinSpan on both axes - the read likely returned coincident points"
        }
    }
    if ($spanX -gt $MaxExtent -or $spanZ -gt $MaxExtent) {
        $errs += "layout span exceeds $MaxExtent (SpanX=$spanX, SpanZ=$spanZ) - the read likely returned wrong-frame coordinates"
    }

    $ok = ($errs.Count -eq 0)
    return [pscustomobject]@{ Ok=$ok; Warnings=$warns; Errors=$errs }
}

# ----------------------------------------------------------------------------
# Set-LayoutMargin - RE-ANCHOR a {X;Z} point list so the nearest hole sits exactly
# Margin in from the plate corner, WITHOUT changing any hole's position relative to
# the others. "Build the plate around the holes" (user 2026-07-20): the drilled
# PATTERN is sacred; only the plate border floats.
#
# WHY THIS EXISTS: the fastener layout is captured with a border sized to the
# FASTENER (median bore ~0.25), but the drill jig builds holes at the JIG hole
# diameter (the bushing OD from the decision tree, usually LARGER). drilljig's
# Get-CustomPointsGeometry edge-margin check (orthogrid.ps1) requires each border
# hole to keep >= one JIG-hole RADIUS of wall to the plate edge; with the smaller
# stored border the nearest hole sits too close to the datum corner -> "edge margin"
# error. Re-anchoring the near corner to the jig hole diameter grows the border to
# clear the jig hole on ALL four sides (the far edge is already sized by ClearDia in
# Get-CustomPointsGeometry), so the check passes. It is a pure TRANSLATION: every
# point shifts by the SAME delta, so all center-to-center spacings are preserved
# EXACTLY -- the holes drill in the identical relative pattern.
#
# Inputs:
#   Points - array of objects each exposing numeric .X and .Z (the imported holes).
#   Margin - the desired border: the smallest X (and smallest Z) becomes exactly
#            Margin. Pass the JIG hole diameter so the border clears a full hole
#            radius on the near edges (matching Get-CustomPointsGeometry's far edge).
#            MUST be > 0 (a 0 margin lets the corner hole hit the origin, which
#            Get-CustomPointsGeometry drops). <=0 -> Valid=$false, points unchanged.
#
# Returns [pscustomobject] (NEVER throws):
#   Valid  [bool]      ; Errors [string[]]
#   Points [array] of @{ I; J; X; Z } - re-anchored, min X == min Z == Margin,
#          every X/Z >= Margin. Relative layout identical to the input.
#   Count  [int]       ; Margin [double] (echo) ; ShiftX/ShiftZ [double] (the
#          translation applied, = Margin - min(X)/min(Z); provenance)
# ----------------------------------------------------------------------------
function global:Set-LayoutMargin {
    param([array]$Points, [double]$Margin)

    $errors = @()
    if ($Margin -le 0) { $errors += "Margin must be > 0 (got $Margin)" }

    # normalise + collect numeric points (defensive; never throw on a bad entry)
    $clean = @()
    if ($null -ne $Points) {
        foreach ($pt in $Points) {
            $x = $null; $z = $null
            try { if ($null -ne $pt.X) { $x = [double]$pt.X } } catch {}
            try { if ($null -ne $pt.Z) { $z = [double]$pt.Z } } catch {}
            if ($null -eq $x -or $null -eq $z) { continue }
            $clean += [pscustomobject]@{ X = [double]$x; Z = [double]$z }
        }
    }
    if ($clean.Count -lt 1) {
        $errors += "no numeric points to re-anchor"
        return [pscustomobject]@{ Valid=$false; Errors=[string[]]$errors; Points=@(); Count=0; Margin=[double]$Margin; ShiftX=0.0; ShiftZ=0.0 }
    }

    $minX = ($clean | ForEach-Object { $_.X } | Measure-Object -Minimum).Minimum
    $minZ = ($clean | ForEach-Object { $_.Z } | Measure-Object -Minimum).Minimum
    # translate so the smallest X and smallest Z each land exactly on Margin.
    $shiftX = [double]$Margin - [double]$minX
    $shiftZ = [double]$Margin - [double]$minZ

    $out = @()
    foreach ($p in $clean) {
        $nx = [double]$p.X + $shiftX
        $nz = [double]$p.Z + $shiftZ
        $out += [pscustomobject]@{ I = $out.Count; J = 0; X = [double]$nx; Z = [double]$nz }
    }

    return [pscustomobject]@{
        Valid  = ($errors.Count -eq 0)
        Errors = [string[]]$errors
        Points = $out
        Count  = [int]$out.Count
        Margin = [double]$Margin
        ShiftX = [double]$shiftX
        ShiftZ = [double]$shiftZ
    }
}

# ----------------------------------------------------------------------------
# Write-FastenerLayout - persist a ConvertTo-LayoutXZ result to the handoff file
# (fastener_layout.json). This is the bridge between the fastener-part READ and
# the blank-jig-part BUILD (separate Creo active models / separate runs), exactly
# the file-handoff style of last_jig_spec.json.
#
#   Path        - full path to write (typically <repo>\fastener_layout.json).
#   Layout      - a ConvertTo-LayoutXZ result (.Points, .AxisX/Z, .Margin, ...).
#   SourceModel - the fastener model's file name (provenance).
#   Units       - source model length units ('inch'|'mm'|'unknown'); recorded so
#                 a mm->inch mismatch against the jig part can be WARNED about.
#   ReadMethod  - which read produced the centers (e.g. 'cylinder-axis') -
#                 provenance for the unproven-read gate.
#   WhenIso     - ISO timestamp string (passed in - Date.now-free-friendly).
#
# Returns $true on success, $false on any I/O error (never throws).
# ----------------------------------------------------------------------------
function global:Write-FastenerLayout {
    param(
        [string]$Path,
        $Layout,
        [string]$SourceModel = '',
        [string]$Units = 'unknown',
        [string]$ReadMethod = 'unknown',
        [string]$WhenIso = ''
    )
    if ($null -eq $Layout) { return $false }
    try {
        $ptsOut = @()
        foreach ($p in @($Layout.Points)) {
            $ptsOut += [pscustomobject]@{ X = [double]$p.X; Z = [double]$p.Z }
        }
        $obj = [pscustomobject]@{
            SourceModel = [string]$SourceModel
            Units       = [string]$Units
            AxisX       = [string]$Layout.AxisX
            AxisZ       = [string]$Layout.AxisZ
            AxisXSign   = [double]$Layout.AxisXSign
            AxisZSign   = [double]$Layout.AxisZSign
            Margin      = [double]$Layout.Margin
            Count       = [int]$Layout.Count
            Points      = $ptsOut
            ReadMethod  = [string]$ReadMethod
            WhenIso     = [string]$WhenIso
        }
        $json = $obj | ConvertTo-Json -Depth 6
        Set-Content -Path $Path -Value $json -Encoding UTF8
        return $true
    } catch {
        return $false
    }
}

# ----------------------------------------------------------------------------
# Read-FastenerLayout - load fastener_layout.json back into a normalized result.
# The drilljig import mode calls this then feeds .Points to Get-CustomPointsGeometry.
#
# CASE SENSITIVITY (the diminator lesson): ConvertFrom-Json property access is
# case-sensitive, so we read the EXACT PascalCase keys Write-FastenerLayout wrote.
#
#   Path - the file to read.
# Returns [pscustomobject]@{ Valid; Errors[]; Points=@({I;J;X;Z}); Count;
#         SourceModel; Units; AxisX; AxisZ; Margin; ReadMethod; WhenIso;
#         SpanX; SpanZ }  (Points shaped like Get-CustomPointsGeometry input;
#         SpanX/SpanZ derived so Test-FastenerLayoutSane works on a read result).
# NEVER throws - a missing/garbled file yields Valid=$false + Errors.
# ----------------------------------------------------------------------------
function global:Read-FastenerLayout {
    param([string]$Path)
    $errors = @()
    $empty = {
        param($errs)
        [pscustomobject]@{
            Valid=$false; Errors=[string[]]$errs; Points=@(); Count=0;
            SourceModel=''; Units='unknown'; AxisX=''; AxisZ=''; Margin=0.0;
            ReadMethod='unknown'; WhenIso=''; SpanX=0.0; SpanZ=0.0
        }
    }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return (& $empty @("fastener layout file not found: $Path"))
    }
    $raw = $null
    try { $raw = Get-Content $Path -Raw | ConvertFrom-Json } catch { return (& $empty @("could not parse ${Path}: $($_.Exception.Message)")) }
    if ($null -eq $raw) { return (& $empty @("empty layout file: $Path")) }

    $pts = @()
    $minX = $null; $maxX = $null; $minZ = $null; $maxZ = $null
    try {
        $srcPts = @($raw.Points)
        $j = 0
        foreach ($p in $srcPts) {
            $x = $null; $z = $null
            try { if ($null -ne $p.X) { $x = [double]$p.X } } catch {}
            try { if ($null -ne $p.Z) { $z = [double]$p.Z } } catch {}
            if ($null -eq $x -or $null -eq $z) { $errors += "point $($j + 1) is missing a numeric X/Z"; $j++; continue }
            $pts += [pscustomobject]@{ I = $pts.Count; J = 0; X = [double]$x; Z = [double]$z }
            if ($null -eq $minX -or $x -lt $minX) { $minX = $x }
            if ($null -eq $maxX -or $x -gt $maxX) { $maxX = $x }
            if ($null -eq $minZ -or $z -lt $minZ) { $minZ = $z }
            if ($null -eq $maxZ -or $z -gt $maxZ) { $maxZ = $z }
            $j++
        }
    } catch { $errors += "could not read Points array: $($_.Exception.Message)" }

    if ($pts.Count -lt 1) { $errors += "layout file has no usable points" }

    $units = 'unknown'; $ax=''; $az=''; $margin=0.0; $src=''; $rm='unknown'; $when=''
    try { if ($null -ne $raw.Units)       { $units  = [string]$raw.Units } } catch {}
    try { if ($null -ne $raw.AxisX)       { $ax     = [string]$raw.AxisX } } catch {}
    try { if ($null -ne $raw.AxisZ)       { $az     = [string]$raw.AxisZ } } catch {}
    try { if ($null -ne $raw.Margin)      { $margin = [double]$raw.Margin } } catch {}
    try { if ($null -ne $raw.SourceModel) { $src    = [string]$raw.SourceModel } } catch {}
    try { if ($null -ne $raw.ReadMethod)  { $rm     = [string]$raw.ReadMethod } } catch {}
    try { if ($null -ne $raw.WhenIso)     { $when   = [string]$raw.WhenIso } } catch {}

    $spanX = if ($null -ne $minX) { [double]($maxX - $minX) } else { 0.0 }
    $spanZ = if ($null -ne $minZ) { [double]($maxZ - $minZ) } else { 0.0 }

    return [pscustomobject]@{
        Valid       = ($errors.Count -eq 0)
        Errors      = [string[]]$errors
        Points      = $pts
        Count       = [int]$pts.Count
        SourceModel = $src
        Units       = $units
        AxisX       = $ax
        AxisZ       = $az
        Margin      = [double]$margin
        ReadMethod  = $rm
        WhenIso     = $when
        SpanX       = $spanX
        SpanZ       = $spanZ
    }
}
