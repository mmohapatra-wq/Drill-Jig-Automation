# ============================================================================
# lib\curved_radial.ps1 - pure CURVED chip-relief RADIAL/AXIS-PATTERN planning math
# ============================================================================
# Pure MATH only - no COM, no network, no module-level state. Plans a Creo AXIS
# (radial) feature-pattern that replicates ONE chip-relief pocket around the
# cylinder the fasteners are arrayed on, instead of the operator drawing a
# rectangle at EVERY fastener (the per-fastener slot-arm/slot-finish loop in
# lib\curved_gui_steps_slots.ps1 / [[project_curved_relief_extrude_plane]]).
#
# WHY RADIAL WORKS WHERE LINEAR DOES NOT (the whole reason this exists): a Creo
# LINEAR pattern carries a fixed increment + orientation, so it cannot re-orient a
# copy to a curved face's changing normal (correctly ruled out for curved slots).
# An AXIS pattern ROTATES each copy about a chosen axis; on a cylinder that rotation
# lands every copy normal to the surface at its new angular position. So one seed
# pocket + an axis pattern about the cylinder axis == all the pockets, correctly
# oriented. The operator's `axispattern` mapkey (2026-07-30) records the Creo tokens:
# ProCmdPattern -> ui_pat_type item 2 (Axis) -> pick axis -> ui_pat_axis_1_num_inst
# (count) + ui_pat_axis_1_incr (angular DEGREES) -> confirm. This file is the PURE
# half: given the fastener POSITIONS (already in memory as FastenerComponents[].Origin),
# compute the COUNT + the angular INCREMENT + WHICH fastener to seed on, and gate on
# UNIFORM angular spacing (a single-increment axis pattern only fits an evenly-spaced
# ring/arc; anything else falls back to the proven per-fastener loop).
#
# Dot-source from a hybrid .cmd after $ScriptDir is set (no connection needed):
#     . (Join-Path $ScriptDir 'lib\curved_radial.ps1')
# Also loadable in a plain PowerShell host - the offline unit tests
# (lib\tests\run_curved_radial_tests.ps1) dot-source it directly with no Creo.
#
# CONVENTION (matches orthogrid.ps1 / curved_jig.ps1 / curved_slots.ps1): a function
# that COMPUTES never throws - invalid input returns a result object with
# Valid=$false + Errors/Reason populated. A trap from a math helper would kill the
# whole automation run. COM-array trap (documented across the repo): build each
# vector component on its OWN line, never inside a comma-separated @(math,math,math)
# literal - PS 5.1 tries op_* on the COM array object and throws. This file is
# SELF-CONTAINED (its own CR- vec helpers, like curved_slots.ps1's CS-*), so it adds
# NO new dot-source dependency to drilljig3d-gui.cmd or the offline harnesses.
# `function global:` on every function so the wizard's .GetNewClosure() step handlers
# resolve them (the closure-scope rule, [[project_gui_scope_bugs]]).
#
# THE ROTATION AXIS in Creo is OPERATOR-PICKED (the mapkey's @PAUSE_FOR_SCREEN_PICK);
# this math derives an axis from the positions ONLY to compute the increment + seed +
# uniformity gate. If the operator's picked axis differs in DIRECTION from the derived
# one, the increment MAGNITUDE is still correct (azimuth spacing is direction-agnostic)
# but the pattern's rotation SENSE may flip - that is a live visual-verify item (the
# driver types the magnitude; a wrong sense is corrected by re-picking the axis's other
# end). The count + uniformity are unaffected by the axis sign.
# ============================================================================

# ----------------------------------------------------------------------------
# CR- vec3 helpers (file-local; component-per-line to dodge the COM op_*-on-array
# trap). @(x,y,z) double arrays in, same out. Mirror fastener_layout.ps1's FL-*
# deliberately (self-containment > reuse here - see the header).
# ----------------------------------------------------------------------------
function CR-Dot   { param($A,$B) return ([double]$A[0]*[double]$B[0] + [double]$A[1]*[double]$B[1] + [double]$A[2]*[double]$B[2]) }
function CR-Sub   { param($A,$B) $x=[double]$A[0]-[double]$B[0]; $y=[double]$A[1]-[double]$B[1]; $z=[double]$A[2]-[double]$B[2]; return @($x,$y,$z) }
function CR-Cross { param($A,$B) $cx=[double]$A[1]*[double]$B[2]-[double]$A[2]*[double]$B[1]; $cy=[double]$A[2]*[double]$B[0]-[double]$A[0]*[double]$B[2]; $cz=[double]$A[0]*[double]$B[1]-[double]$A[1]*[double]$B[0]; return @($cx,$cy,$cz) }
function CR-Norm  { param($A) return [Math]::Sqrt((CR-Dot $A $A)) }
function CR-Unit  { param($A,[double]$Eps=1e-12) $n=CR-Norm $A; if ($n -lt $Eps) { return $null }; $ux=[double]$A[0]/$n; $uy=[double]$A[1]/$n; $uz=[double]$A[2]/$n; return @($ux,$uy,$uz) }
# subtract the component of $V along unit $U (projection out): V - (V.U) U
function CR-ProjectOut { param($V,$U) $d = CR-Dot $V $U; $x=[double]$V[0]-$d*[double]$U[0]; $y=[double]$V[1]-$d*[double]$U[1]; $z=[double]$V[2]-$d*[double]$U[2]; return @($x,$y,$z) }

# ----------------------------------------------------------------------------
# CR-CleanPositions - normalise the -Positions input into a list of clean
# @(x,y,z) double triples, each tagged with its ORIGINAL input index (so a plan's
# SeedIndex maps back to the fastener the caller must seed on). A malformed /
# non-finite / non-3-element entry is SKIPPED (never throws). Returns an array of
# @{ Index=<orig int>; Pos=@(x,y,z) }.
# ----------------------------------------------------------------------------
function global:CR-CleanPositions {
    param($Positions)
    $out = @()
    if ($null -eq $Positions) { return $out }
    $i = 0
    foreach ($p in $Positions) {
        if ($null -eq $p) { $i++; continue }
        $x = $null; $y = $null; $z = $null
        try { $x = [double]$p[0] } catch { $x = $null }
        try { $y = [double]$p[1] } catch { $y = $null }
        try { $z = [double]$p[2] } catch { $z = $null }
        $bad = ($null -eq $x -or $null -eq $y -or $null -eq $z)
        if (-not $bad) {
            if ([double]::IsNaN($x) -or [double]::IsInfinity($x)) { $bad = $true }
            if ([double]::IsNaN($y) -or [double]::IsInfinity($y)) { $bad = $true }
            if ([double]::IsNaN($z) -or [double]::IsInfinity($z)) { $bad = $true }
        }
        if (-not $bad) { $out += [pscustomobject]@{ Index = [int]$i; Pos = @([double]$x, [double]$y, [double]$z) } }
        $i++
    }
    return $out
}

# ----------------------------------------------------------------------------
# CR-DeriveAxis - EIGEN-FREE rotation-axis direction from a ring/arc of positions.
# The two-farthest-points cross-product: v1 = the point farthest from the centroid;
# v2 = the point farthest from the v1 LINE (through the centroid); the plane normal
# is unit(v1 x v2). For points on a circle/arc this yields a robust normal from two
# well-separated in-plane spans (no covariance eigen-decomposition needed, unlike
# fastener_layout.ps1 FL-BestFitNormal - kept self-contained here on purpose).
# Returns @{ Axis=@(ux,uy,uz); Centroid=@(x,y,z); Ok=<bool>; Reason } - Ok=$false on
# a collinear/degenerate set (v1 x v2 ~ 0). NEVER throws.
#   -Clean : the CR-CleanPositions output (>= 2 entries expected by the caller).
# ----------------------------------------------------------------------------
function global:CR-DeriveAxis {
    param($Clean)
    $res = @{ Axis = $null; Centroid = $null; Ok = $false; Reason = '' }
    $pts = @($Clean)
    if ($pts.Count -lt 3) { $res.Reason = 'need at least 3 positions to derive an axis'; return $res }
    # centroid
    $sx = 0.0; $sy = 0.0; $sz = 0.0
    foreach ($e in $pts) { $sx += [double]$e.Pos[0]; $sy += [double]$e.Pos[1]; $sz += [double]$e.Pos[2] }
    $n = [double]$pts.Count
    $cx = $sx / $n; $cy = $sy / $n; $cz = $sz / $n
    $centroid = @($cx, $cy, $cz)
    # v1 = farthest from centroid
    $v1 = $null; $best1 = -1.0
    foreach ($e in $pts) {
        $w = CR-Sub $e.Pos $centroid
        $d = CR-Norm $w
        if ($d -gt $best1) { $best1 = $d; $v1 = $w }
    }
    if ($null -eq $v1 -or $best1 -le 1e-9) { $res.Reason = 'positions coincide at the centroid (no radius)'; return $res }
    $u1 = CR-Unit $v1
    if ($null -eq $u1) { $res.Reason = 'degenerate primary span'; return $res }
    # v2 = farthest from the v1 line (largest perpendicular component)
    $v2 = $null; $best2 = -1.0
    foreach ($e in $pts) {
        $w = CR-Sub $e.Pos $centroid
        $perp = CR-ProjectOut $w $u1
        $d = CR-Norm $perp
        if ($d -gt $best2) { $best2 = $d; $v2 = $w }
    }
    if ($null -eq $v2 -or $best2 -le 1e-9) { $res.Reason = 'positions are collinear (no plane -> no rotation axis)'; return $res }
    $axis = CR-Unit (CR-Cross $v1 $v2)
    if ($null -eq $axis) { $res.Reason = 'axis is degenerate (spans are parallel)'; return $res }
    $res.Axis = $axis; $res.Centroid = $centroid; $res.Ok = $true
    $res.Reason = 'axis from two-farthest-points cross'
    return $res
}

# ----------------------------------------------------------------------------
# CR-FitCircle2D - algebraic (Kasa) least-squares circle fit to 2D points. Returns
# @{ Uc; Vc; R } (center + radius) or $null on a collinear/degenerate set (< 3
# points, or a singular normal-equation matrix). CRITICAL for a partial ARC: the
# CENTROID of an arc is NOT the circle center, so azimuths measured about the
# centroid are non-uniform; the true center (this fit) is required for a correct
# angular increment. For a full circle the fit center == the centroid, so it is
# also correct there. Solves the 2x2 centered normal equations directly. NEVER throws.
# ----------------------------------------------------------------------------
function global:CR-FitCircle2D {
    param($Us, $Vs)
    $u = @($Us); $v = @($Vs)
    $n = $u.Count
    if ($n -lt 3 -or $v.Count -ne $n) { return $null }
    $mu = 0.0; $mv = 0.0
    for ($i = 0; $i -lt $n; $i++) { $mu += [double]$u[$i]; $mv += [double]$v[$i] }
    $mu /= [double]$n; $mv /= [double]$n
    $Suu=0.0; $Svv=0.0; $Suv=0.0; $Suuu=0.0; $Svvv=0.0; $Suvv=0.0; $Svuu=0.0
    for ($i = 0; $i -lt $n; $i++) {
        $du = [double]$u[$i] - $mu; $dv = [double]$v[$i] - $mv
        $Suu += $du*$du; $Svv += $dv*$dv; $Suv += $du*$dv
        $Suuu += $du*$du*$du; $Svvv += $dv*$dv*$dv; $Suvv += $du*$dv*$dv; $Svuu += $dv*$du*$du
    }
    $det = $Suu*$Svv - $Suv*$Suv
    if ([Math]::Abs($det) -lt 1e-12) { return $null }   # collinear
    $b1 = 0.5*($Suuu + $Suvv); $b2 = 0.5*($Svvv + $Svuu)
    $uc = ($b1*$Svv - $b2*$Suv) / $det
    $vc = ($Suu*$b2 - $Suv*$b1) / $det
    $r = [Math]::Sqrt([Math]::Max(0.0, $uc*$uc + $vc*$vc + ($Suu + $Svv)/[double]$n))
    return @{ Uc = ($mu + $uc); Vc = ($mv + $vc); R = $r }
}

# ----------------------------------------------------------------------------
# Get-CurvedRadialAzimuths - project each position into the plane perpendicular to
# the rotation axis and return its azimuth [0,360) about the FITTED CIRCLE CENTER +
# its radius. PURE; never throws. Returns @{ Valid; Reason; Axis; AxisPoint; E1; E2;
# Items=@(@{ Index; Az; Radius }) } (Items in the ORIGINAL input order). The azimuth
# origin (E1) is arbitrary; Get-CurvedRadialPatternPlan only uses azimuth DIFFERENCES,
# which are origin-independent.
#   -Positions : raw fastener positions (cleaned internally).
#   -Axis      : optional rotation-axis DIRECTION; default derived (needs >= 3 pts).
#   -AxisPoint : optional point on the axis (the ring/arc center). When supplied WITH
#                -Axis it is used directly (works for N==2); otherwise the center is
#                Kasa-fit from the in-plane projection (needs >= 3 pts) so a PARTIAL
#                ARC gets its true center, not the (wrong) centroid.
# ----------------------------------------------------------------------------
function global:Get-CurvedRadialAzimuths {
    param($Positions, $Axis = $null, $AxisPoint = $null)
    $clean = @(CR-CleanPositions $Positions)
    if ($clean.Count -lt 2) {
        return [pscustomobject]@{ Valid=$false; Reason='need at least 2 usable positions'; Axis=$null; AxisPoint=$null; E1=$null; E2=$null; Items=@() }
    }
    # rotation-axis DIRECTION: supplied (unit) or derived from >= 3 positions.
    $ax = $null
    $uAxis = $null
    if ($null -ne $Axis) { $uAxis = CR-Unit $Axis }
    if ($null -ne $uAxis) { $ax = $uAxis }
    else {
        $der = CR-DeriveAxis -Clean $clean
        if (-not $der.Ok) {
            return [pscustomobject]@{ Valid=$false; Reason=("could not derive a rotation axis: " + $der.Reason); Axis=$null; AxisPoint=$null; E1=$null; E2=$null; Items=@() }
        }
        $ax = $der.Axis
    }
    # basis origin for the in-plane projection = the centroid (any point on/near the
    # plane works; the circle center is fit relative to it below).
    $sx=0.0;$sy=0.0;$sz=0.0
    foreach ($e in $clean) { $sx+=[double]$e.Pos[0]; $sy+=[double]$e.Pos[1]; $sz+=[double]$e.Pos[2] }
    $nn=[double]$clean.Count
    # component-per-line (never @(math,math,math) - the COM op_* trap, header rule)
    $ox = $sx / $nn; $oy = $sy / $nn; $oz = $sz / $nn
    $origin = @($ox, $oy, $oz)
    # in-plane orthonormal basis (E1, E2) perpendicular to the axis.
    $e1 = $null
    foreach ($e in $clean) {
        $w = CR-Sub $e.Pos $origin
        $perp = CR-ProjectOut $w $ax
        if ((CR-Norm $perp) -gt 1e-9) { $e1 = CR-Unit $perp; break }
    }
    if ($null -eq $e1) {
        return [pscustomobject]@{ Valid=$false; Reason='all positions lie on the axis (no radial spread)'; Axis=$ax; AxisPoint=$null; E1=$null; E2=$null; Items=@() }
    }
    $e2 = CR-Unit (CR-Cross $ax $e1)
    if ($null -eq $e2) {
        return [pscustomobject]@{ Valid=$false; Reason='could not build the in-plane basis'; Axis=$ax; AxisPoint=$null; E1=$e1; E2=$null; Items=@() }
    }
    # project all points to 2D (u,v) about the basis origin
    $us=@(); $vs=@()
    foreach ($e in $clean) {
        $w = CR-Sub $e.Pos $origin
        $us += (CR-Dot $w $e1)
        $vs += (CR-Dot $w $e2)
    }
    # circle CENTER (Uc,Vc) in the (E1,E2) plane. If an AxisPoint was supplied WITH an
    # axis, project it to 2D and use it (allows N==2). Else Kasa-fit (needs >= 3).
    $uc = $null; $vc = $null
    if ($null -ne $Axis -and $null -ne $AxisPoint) {
        $wap = CR-Sub @([double]$AxisPoint[0],[double]$AxisPoint[1],[double]$AxisPoint[2]) $origin
        $uc = CR-Dot $wap $e1; $vc = CR-Dot $wap $e2
    } else {
        $fit = CR-FitCircle2D -Us $us -Vs $vs
        if ($null -eq $fit) {
            return [pscustomobject]@{ Valid=$false; Reason='could not fit a circle center (positions collinear or fewer than 3) - supply -Axis and -AxisPoint, or draw the pockets by hand'; Axis=$ax; AxisPoint=$null; E1=$e1; E2=$e2; Items=@() }
        }
        $uc = $fit.Uc; $vc = $fit.Vc
    }
    # 3D axis point (the ring center) = origin + Uc*E1 + Vc*E2
    $apx = [double]$origin[0] + $uc*[double]$e1[0] + $vc*[double]$e2[0]
    $apy = [double]$origin[1] + $uc*[double]$e1[1] + $vc*[double]$e2[1]
    $apz = [double]$origin[2] + $uc*[double]$e1[2] + $vc*[double]$e2[2]
    $ap = @($apx, $apy, $apz)
    # azimuth of each point ABOUT the fitted center, in the (E1,E2) plane.
    $items = @()
    for ($i = 0; $i -lt $clean.Count; $i++) {
        $du = [double]$us[$i] - $uc
        $dv = [double]$vs[$i] - $vc
        $rad = [Math]::Sqrt($du*$du + $dv*$dv)
        $azDeg = [Math]::Atan2($dv, $du) * 180.0 / [Math]::PI
        if ($azDeg -lt 0.0) { $azDeg += 360.0 }
        $items += [pscustomobject]@{ Index = [int]$clean[$i].Index; Az = [double]$azDeg; Radius = [double]$rad }
    }
    return [pscustomobject]@{ Valid=$true; Reason=''; Axis=$ax; AxisPoint=$ap; E1=$e1; E2=$e2; Items=@($items) }
}

# ============================================================================
# Get-CurvedRadialPatternPlan - THE plan. Decide whether ONE seed pocket can be
# AXIS-patterned to cover every fastener, and with what count/increment/seed.
#
# PARAMETERS:
#   -Positions       array of @(x,y,z) fastener positions (FastenerComponents[].Origin).
#   -Axis/-AxisPoint optional rotation axis + a point on it (else derived).
#   -TolDeg          uniform-spacing tolerance in degrees (default 2.0). The N-1
#                    pattern gaps (all cyclic gaps EXCEPT the single largest "opening")
#                    must agree within this band.
#   -IncrementDegOverride / -CountOverride  optional values from the parallel "Read
#                    radial distance" session (user 2026-07-30 "self-compute + accept
#                    override"). A positive override REPLACES the computed value; the
#                    uniformity gate + seed are still computed from the positions.
#
# RETURNS [pscustomobject]:
#   Valid        [bool]   the math ran (>= 2 clean positions + an axis)
#   CanPattern   [bool]   a single-increment axis pattern fits (uniform spacing)
#   Count        [int]    total instances (= fastener count, INCLUDING the seed)
#   IncrementDeg [double] angular step in degrees (magnitude; sign is a live-verify)
#   SeedIndex    [int]    ORIGINAL index of the fastener to draw the seed on (the arc
#                         start = the point just after the largest cyclic gap). -1 if none.
#   FullCircle   [bool]   every cyclic gap (incl. the opening) is uniform (360/N ring)
#   RadiusMean   [double] mean in-plane radius (advisory; big spread => Warnings)
#   Axis/AxisPoint        the axis used (derived or supplied)
#   Azimuths     [double[]] the per-fastener azimuths in ORIGINAL order (diagnostic)
#   Reason       [string] why CanPattern is false (non-uniform / too few / etc.)
#   Warnings     [string[]]
# NEVER throws.
# ============================================================================
function global:Get-CurvedRadialPatternPlan {
    param(
        $Positions,
        $Axis = $null,
        $AxisPoint = $null,
        [double]$TolDeg = 2.0,
        [double]$IncrementDegOverride = 0.0,
        [int]$CountOverride = 0
    )
    $warnings = @()
    $az = Get-CurvedRadialAzimuths -Positions $Positions -Axis $Axis -AxisPoint $AxisPoint
    if (-not $az.Valid) {
        return [pscustomobject]@{
            Valid=$false; CanPattern=$false; Count=0; IncrementDeg=0.0; SeedIndex=-1; FullCircle=$false;
            RadiusMean=0.0; Axis=$az.Axis; AxisPoint=$az.AxisPoint; Azimuths=@();
            Reason=$az.Reason; Warnings=$warnings
        }
    }
    $items = @($az.Items)
    $N = $items.Count
    $azimuthsOrig = @($items | ForEach-Object { [double]$_.Az })
    $radMean = 0.0
    if ($N -ge 1) { $r = 0.0; foreach ($it in $items) { $r += [double]$it.Radius }; $radMean = $r / [double]$N }

    if ($N -lt 2) {
        return [pscustomobject]@{
            Valid=$true; CanPattern=$false; Count=$N; IncrementDeg=0.0; SeedIndex=$(if ($N -ge 1) { [int]$items[0].Index } else { -1 }); FullCircle=$false;
            RadiusMean=$radMean; Axis=$az.Axis; AxisPoint=$az.AxisPoint; Azimuths=$azimuthsOrig;
            Reason='fewer than 2 fasteners - nothing to pattern (draw the single pocket by hand)'; Warnings=$warnings
        }
    }

    # radius-spread advisory: a big radial spread means the fasteners are NOT on one
    # circle (a helix / mixed rings) - the pattern may misplace copies. Advisory only.
    $rMin = [double]::MaxValue; $rMax = 0.0
    foreach ($it in $items) { $rr=[double]$it.Radius; if ($rr -lt $rMin) { $rMin=$rr }; if ($rr -gt $rMax) { $rMax=$rr } }
    if ($radMean -gt 1e-9 -and (($rMax - $rMin) / $radMean) -gt 0.05) {
        $warnings += ("fastener radii vary by {0:0.#}% (min {1:0.###}, max {2:0.###}) - they may not lie on one circle; verify the patterned pockets visually" -f (100.0*($rMax-$rMin)/$radMean), $rMin, $rMax)
    }

    # sort by azimuth ascending (carry the original index)
    $sorted = @($items | Sort-Object Az)
    # cyclic gaps: gap[i] = az[(i+1)%N] - az[i]  (mod 360). N gaps total.
    $gaps = @()
    for ($i = 0; $i -lt $N; $i++) {
        $a = [double]$sorted[$i].Az
        $b = [double]$sorted[($i + 1) % $N].Az
        $d = $b - $a
        if ($d -lt 0.0) { $d += 360.0 }
        $gaps += $d
    }
    # the SINGLE largest gap is the arc "opening"; the arc starts at the point just
    # after it. The pattern increments are the OTHER N-1 gaps (must be uniform).
    $maxGapIdx = 0; $maxGap = -1.0
    for ($i = 0; $i -lt $N; $i++) { if ($gaps[$i] -gt $maxGap) { $maxGap = $gaps[$i]; $maxGapIdx = $i } }
    $seedSortPos = ($maxGapIdx + 1) % $N
    $seedIndex = [int]$sorted[$seedSortPos].Index

    # the N-1 pattern gaps (exclude the opening at $maxGapIdx)
    $patGaps = @()
    for ($i = 0; $i -lt $N; $i++) { if ($i -ne $maxGapIdx) { $patGaps += [double]$gaps[$i] } }
    # (N==2 -> exactly 1 pattern gap; trivially uniform.)
    $pMin = [double]::MaxValue; $pMax = -1.0; $pSum = 0.0
    foreach ($g in $patGaps) { if ($g -lt $pMin) { $pMin = $g }; if ($g -gt $pMax) { $pMax = $g }; $pSum += $g }
    $pMean = if (@($patGaps).Count -ge 1) { $pSum / [double]@($patGaps).Count } else { 0.0 }
    $uniform = ((@($patGaps).Count -ge 1) -and (($pMax - $pMin) -le $TolDeg) -and ($pMean -gt 1e-6))
    # full circle: EVERY cyclic gap (including the opening) is uniform.
    $allSpread = $maxGap - $pMin
    $fullCircle = ($uniform -and (($maxGap - $pMean) -le $TolDeg) -and ($maxGap - $pMin -le $TolDeg))

    $increment = $pMean
    $count = $N
    # accept overrides from the "Read radial distance" session (positive wins).
    if ($IncrementDegOverride -gt 0.0) { $increment = [double]$IncrementDegOverride; $warnings += ("angular increment overridden to {0} deg (Read-radial-distance)" -f $increment) }
    if ($CountOverride -gt 0)          { $count = [int]$CountOverride;               $warnings += ("count overridden to {0} (Read-radial-distance)" -f $count) }

    $reason = ''
    if (-not $uniform) {
        $reason = ("fasteners are NOT uniformly spaced about the axis (pattern gaps {0:0.##}..{1:0.##} deg span {2:0.##} > tol {3}); drawing each pocket by hand" -f $pMin, $pMax, ($pMax - $pMin), $TolDeg)
    } elseif ($increment -le 1e-6) {
        $uniform = $false
        $reason = 'computed angular increment is ~0 - cannot pattern'
    }

    return [pscustomobject]@{
        Valid       = $true
        CanPattern  = [bool]$uniform
        Count       = [int]$count
        IncrementDeg = [double][Math]::Round($increment, 6)
        SeedIndex   = [int]$seedIndex
        FullCircle  = [bool]$fullCircle
        RadiusMean  = [double]$radMean
        Axis        = $az.Axis
        AxisPoint   = $az.AxisPoint
        Azimuths    = $azimuthsOrig
        Reason      = [string]$reason
        Warnings    = [string[]]$warnings
    }
}

# ============================================================================
# Test-CurvedRadialPatternPlan - cheap deterministic gate over a
# Get-CurvedRadialPatternPlan result: is it safe to fire the axis pattern? Confirms
# Valid + CanPattern + Count>=2 + IncrementDeg>0 + a real SeedIndex. NEVER throws;
# a $null/non-plan input => Ok=$false + an Issue. The caller treats Ok=$false as
# "run the per-fastener loop instead" (never a hard error).
# ============================================================================
function global:Test-CurvedRadialPatternPlan {
    param($Plan)
    $issues = @()
    if ($null -eq $Plan) { return [pscustomobject]@{ Ok=$false; Issues=@('plan is null') } }
    $valid = $false;  try { $valid = [bool]$Plan.Valid } catch { $valid = $false }
    $can   = $false;  try { $can   = [bool]$Plan.CanPattern } catch { $can = $false }
    $cnt   = 0;       try { $cnt   = [int]$Plan.Count } catch { $cnt = 0 }
    $inc   = 0.0;     try { $inc   = [double]$Plan.IncrementDeg } catch { $inc = 0.0 }
    $seed  = -1;      try { $seed  = [int]$Plan.SeedIndex } catch { $seed = -1 }
    if (-not $valid) { $issues += 'plan did not compute (Valid=$false)' }
    if (-not $can)   { $r=''; try { $r=[string]$Plan.Reason } catch {}; $issues += ('not patternable' + $(if ($r) { ": $r" } else { '' })) }
    if ($cnt -lt 2)  { $issues += "count < 2 ($cnt)" }
    if ($inc -le 0)  { $issues += "increment <= 0 ($inc)" }
    if ($seed -lt 0) { $issues += 'no seed fastener index' }
    return [pscustomobject]@{ Ok = [bool]($issues.Count -eq 0); Issues = [string[]]$issues }
}

# ============================================================================
# Get-CylinderFromFasteners - the "radius of the surface + center point" the user asked
# for (2026-07-31): compute the cylinder AXIS DIRECTION, a point on the AXIS (the center
# line), and the RADIUS from the fastener positions. PRIMARY source is the live cylinder
# read the "Read radial distance" half already provides ($ctx.RadialAxisGeom -> supply
# -Axis/-AxisPoint); this then just measures the radius from the positions. With NO axis
# supplied it DERIVES one from the positions (CR-DeriveAxis + the CR-FitCircle2D center via
# Get-CurvedRadialAzimuths, a single-ring fit). This is the geometry to CONSTRUCT a datum
# axis at (radialpat-probe records the ProCmdDatumAxis widgets; the -AxisFeatId feed reuses it).
#
#   -Positions  fastener @(x,y,z) list. -Axis/-AxisPoint optional (the live cylinder axis).
# Returns @{ Valid; AxisDir=@(ux,uy,uz); AxisPoint=@(x,y,z); Radius; RadiusSpread; Count; Reason }.
# NEVER throws. RadiusSpread (max-min) flags a non-cylindrical / multi-radius set (advisory).
# ============================================================================
function global:Get-CylinderFromFasteners {
    param($Positions, $Axis = $null, $AxisPoint = $null)
    $az = Get-CurvedRadialAzimuths -Positions $Positions -Axis $Axis -AxisPoint $AxisPoint
    if (-not $az.Valid) {
        return [pscustomobject]@{ Valid=$false; AxisDir=$az.Axis; AxisPoint=$az.AxisPoint; Radius=0.0; RadiusSpread=0.0; Count=0; Reason=$az.Reason }
    }
    $items = @($az.Items)
    $n = $items.Count
    $rmin = [double]::MaxValue; $rmax = 0.0; $sum = 0.0
    foreach ($it in $items) { $rr = [double]$it.Radius; if ($rr -lt $rmin) { $rmin = $rr }; if ($rr -gt $rmax) { $rmax = $rr }; $sum += $rr }
    $mean = if ($n -ge 1) { $sum / [double]$n } else { 0.0 }
    $spread = if ($n -ge 1) { $rmax - $rmin } else { 0.0 }
    return [pscustomobject]@{
        Valid = $true; AxisDir = $az.Axis; AxisPoint = $az.AxisPoint
        Radius = [double][Math]::Round($mean, 6); RadiusSpread = [double]$spread; Count = [int]$n
        Reason = ('cylinder: R={0:0.####} (spread {1:0.####}) over {2} fasteners' -f $mean, $spread, $n)
    }
}

# ============================================================================
# Get-CurvedRadialPatternGroups - the MULTI-PATTERN plan (user 2026-07-31: "you can also
# create multiple patterns, if the patterns arent at constant angles"). Generalises the
# single Get-CurvedRadialPatternPlan: split the fasteners' ANGULAR positions (about the axis)
# into ONE regular axis-pattern at the best-fit angular pitch + a count-2 "accommodation"
# pattern per off-pitch stray -- the EXACT model of the flat-DJ Get-SlotSeedPatterns
# (lib\orthogrid.ps1), applied to azimuth offsets instead of a linear cross-coord. ALL groups
# rotate the SAME seed pocket about the SAME axis, so the operator/constructed axis is picked
# ONCE and reused for every group.
#
# ALGORITHM (mirrors Get-SlotSeedPatterns):
#   1. azimuths about the axis (Get-CurvedRadialAzimuths; supply the live cylinder axis).
#   2. sort; find the largest CYCLIC gap = the arc "opening"; the SEED = the point just after
#      it (the arc start), so from-seed offsets increase monotonically across the arc.
#   3. offsets[] = each other fastener's angle from the seed (deg, 0..360, ascending).
#   4. bestG = the from-seed pitch whose consecutive multiples g,2g,... land on the MOST
#      offsets -> the REGULAR pattern (Count = coveredMultiples+1, Increment = g).
#   5. every offset NOT on the regular multiples -> its OWN count-2 accommodation pattern
#      (Increment = that offset). So the groups together cover ALL N fasteners exactly once
#      (seed shared): sum of (group.Count-1) copies + 1 seed = N.
#
#   -Positions  fastener @(x,y,z) list.  -Axis/-AxisPoint  optional live cylinder axis.
#   -TolDeg     angular equality tolerance (default 2.0).
# Returns @{ Valid; SeedIndex; Count(=N); Groups=@(@{Increment;Count;Kind('regular'|'accommodation')});
#            PatternCount; Axis; AxisPoint; Azimuths; Reason }. A single uniform ring => ONE
# 'regular' group == Get-CurvedRadialPatternPlan. N<2 => no groups (draw the one pocket). NEVER throws.
# ============================================================================
function global:Get-CurvedRadialPatternGroups {
    param($Positions, $Axis = $null, $AxisPoint = $null, [double]$TolDeg = 2.0)
    # too-few / no-axis-derivable => Valid=$true with 0 patterns (draw the pocket(s) by hand),
    # not a hard error -- the caller routes 0 patterns to the per-fastener loop. Only 0 clean
    # positions is invalid.
    $clean0 = @(CR-CleanPositions $Positions)
    if ($clean0.Count -lt 1) {
        return [pscustomobject]@{ Valid=$false; SeedIndex=-1; Count=0; Groups=@(); PatternCount=0; Axis=$null; AxisPoint=$null; Azimuths=@(); Reason='no usable fastener positions' }
    }
    $az = Get-CurvedRadialAzimuths -Positions $Positions -Axis $Axis -AxisPoint $AxisPoint
    if (-not $az.Valid) {
        # e.g. 1 fastener, or 2 with no supplied axis (an axis needs >=3 to derive) -> draw by hand.
        return [pscustomobject]@{ Valid=$true; SeedIndex=[int]$clean0[0].Index; Count=[int]$clean0.Count; Groups=@(); PatternCount=0; Axis=$az.Axis; AxisPoint=$az.AxisPoint; Azimuths=@(); Reason=("cannot derive a radial pattern (" + $az.Reason + ") - draw the pocket(s) by hand") }
    }
    $items = @($az.Items)
    $N = $items.Count
    $azimuthsOrig = @($items | ForEach-Object { [double]$_.Az })
    if ($N -lt 1) {
        return [pscustomobject]@{ Valid=$false; SeedIndex=-1; Count=0; Groups=@(); PatternCount=0; Axis=$az.Axis; AxisPoint=$az.AxisPoint; Azimuths=@(); Reason='no fasteners' }
    }
    if ($N -eq 1) {
        return [pscustomobject]@{ Valid=$true; SeedIndex=[int]$items[0].Index; Count=1; Groups=@(); PatternCount=0; Axis=$az.Axis; AxisPoint=$az.AxisPoint; Azimuths=$azimuthsOrig; Reason='1 fastener - draw the single pocket (no pattern)' }
    }

    # sort by azimuth; largest cyclic gap = the arc opening -> the seed is the point after it.
    $sorted = @($items | Sort-Object Az)
    $gaps = @()
    for ($i = 0; $i -lt $N; $i++) {
        $b = [double]$sorted[($i + 1) % $N].Az - [double]$sorted[$i].Az
        if ($b -lt 0.0) { $b += 360.0 }
        $gaps += $b
    }
    $maxGapIdx = 0; $maxGap = -1.0
    for ($i = 0; $i -lt $N; $i++) { if ($gaps[$i] -gt $maxGap) { $maxGap = $gaps[$i]; $maxGapIdx = $i } }
    # reorder starting at the arc-start; re-measure each other point's angle FROM the seed.
    $arc = @(); for ($k = 0; $k -lt $N; $k++) { $arc += $sorted[($maxGapIdx + 1 + $k) % $N] }
    $seedIndex = [int]$arc[0].Index
    $seedAz = [double]$arc[0].Az
    $offsets = @()
    for ($k = 1; $k -lt $N; $k++) {
        $d = [double]$arc[$k].Az - $seedAz
        if ($d -lt 0.0) { $d += 360.0 }
        $offsets += $d
    }

    # best-fit regular pitch = the from-seed pitch g whose consecutive multiples cover the
    # most offsets (mirror Get-SlotSeedPatterns). Tie -> the finer (smaller) pitch.
    $tol = if ($TolDeg -gt 0) { $TolDeg } else { 2.0 }
    $bestG = [double]$offsets[0]; $bestLen = 0; $bestCov = @()
    foreach ($cand in $offsets) {
        $g = [double]$cand
        if ($g -le 1e-6) { continue }
        $cov = @(); $m = 1
        while ($true) {
            $target = $g * $m
            if ($target -gt 360.5) { break }
            $hit = $false
            foreach ($o in $offsets) { if ([Math]::Abs([double]$o - $target) -le $tol) { $hit = $true; break } }
            if (-not $hit) { break }
            $cov += ($g * $m); $m++
        }
        if (@($cov).Count -gt $bestLen -or (@($cov).Count -eq $bestLen -and $g -lt $bestG)) {
            $bestLen = @($cov).Count; $bestG = $g; $bestCov = @($cov)
        }
    }

    # AUTHORITATIVE consumption pass (the $bestCov proximity count above only PICKS the pitch; it
    # must NOT decide coverage). A Creo axis pattern plants copies at CONSECUTIVE multiples
    # g,2g,3g,... and each planted copy serves exactly ONE fastener. So walk the multiples; each
    # multiple CONSUMES the closest not-yet-consumed offset within tol; STOP at the first multiple
    # with no match (consecutive - the pattern can't skip a gap). Every offset the regular run does
    # NOT consume gets its OWN count-2 accommodation. This is the fix for the near-duplicate trap:
    # two distinct fasteners both within tol of the SAME multiple (e.g. 100 deg and 101 deg) -- the
    # regular pattern plants ONE copy at 100, so the 101 fastener is NOT covered and MUST get an
    # accommodation. The old proximity-to-multiple skip dropped it silently. ([[project_curved_radial_slot_pattern]])
    $consumed = @{}
    $regCopies = 0; $mm = 1
    while ($true) {
        $target = $bestG * $mm
        if ($target -gt 360.5) { break }
        $bestOi = -1; $bestD = $tol + 1.0
        for ($oi = 0; $oi -lt @($offsets).Count; $oi++) {
            if ($consumed.ContainsKey($oi)) { continue }
            $d = [Math]::Abs([double]$offsets[$oi] - $target)
            if ($d -le $tol -and $d -lt $bestD) { $bestD = $d; $bestOi = $oi }
        }
        if ($bestOi -lt 0) { break }
        $consumed[$bestOi] = $true; $regCopies++; $mm++
    }

    $groups = @()
    $groups += [pscustomobject]@{ Increment = [double][Math]::Round($bestG, 6); Count = [int]($regCopies + 1); Kind = 'regular' }
    for ($oi = 0; $oi -lt @($offsets).Count; $oi++) {
        if ($consumed.ContainsKey($oi)) { continue }
        $groups += [pscustomobject]@{ Increment = [double][Math]::Round([double]$offsets[$oi], 6); Count = 2; Kind = 'accommodation' }
    }

    $pc = @($groups).Count
    $accN = $pc - 1
    $reason = if ($accN -le 0) {
        ("{0} fasteners uniformly spaced -> 1 radial pattern ({1} pockets, {2:0.##} deg apart)" -f $N, $groups[0].Count, $groups[0].Increment)
    } else {
        ("{0} fasteners NOT all uniform -> 1 regular radial pattern ({1} pockets @ {2:0.##} deg) + {3} count-2 accommodation pattern(s); draw ONE seed" -f $N, $groups[0].Count, $groups[0].Increment, $accN)
    }
    return [pscustomobject]@{
        Valid = $true; SeedIndex = [int]$seedIndex; Count = [int]$N; Groups = @($groups); PatternCount = [int]$pc
        Axis = $az.Axis; AxisPoint = $az.AxisPoint; Azimuths = $azimuthsOrig; Reason = [string]$reason
    }
}
