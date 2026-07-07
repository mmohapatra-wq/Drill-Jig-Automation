# ============================================================================
# lib\index_frame.ps1 - pure "change-of-matrix-model" (change-of-basis) math
# ============================================================================
# Pure MATH only - no COM, no network, no module-level state. The single source
# of truth for the drill-jig INDEX-FRAME transform: given two "index" holes and
# any number of other holes (all read as cylinder axes elsewhere), build a local
# coordinate frame anchored at index hole #1 with its primary axis pointing
# toward index hole #2, then express every hole's center in that frame.
#
# Dot-source from a hybrid .cmd after $ScriptDir is set (no connection needed):
#     . (Join-Path $ScriptDir 'lib\index_frame.ps1')
# Also loadable in a plain PowerShell host - the offline unit tests
# (lib\tests\run_index_frame_tests.ps1) dot-source it directly with no Creo.
#
# ----------------------------------------------------------------------------
# THE MATH (verified by a 3-way independent derivation + adversarial judge,
# 2026-06-26 - see project_index_frame memory):
#
#   Zhat = normalize( sum of all bore directions D_i, sign-aligned to D_1 )
#   v    = (A2 - A1) - ((A2-A1).Zhat) Zhat      # in-plane part of 1->2 vector
#   Xhat = v / |v|
#   Yhat = Zhat x Xhat                          # right-handed: +X right, +Y left-
#                                               #   of-1->2-from-above, +Z up
#   For a hole at axis-origin P:  R = P - A1
#     x = R.Xhat   y = R.Yhat   z = R.Zhat
#
# INVARIANCE (the load-bearing property): a cylinder descriptor may place its
# axis ORIGIN anywhere ALONG the bore (top of hole, bottom, arbitrary height) -
# it is NOT guaranteed to lie on the plate face or at the same height per hole.
# Because Xhat and Yhat are both perpendicular to Zhat by construction, sliding
# any origin A1/A2/P by s*Zhat changes ONLY z; the reported (x,y) is invariant.
# This is EXACT when all bores share one Zhat (parallel bores). For non-parallel
# bores separated by angle theta the leak into (x,y) is bounded by ~s*sin(theta)
# (few um on a flat plate at theta<=0.01deg) - Test-IndexFrameValid WARNS when
# theta exceeds MaxAxisAngleDeg so a wobbly part is caught, not silently wrong.
#
# WHY average bore directions for Zhat (not a plane normal): on this Creo build a
# PLANE descriptor's normal reads null (project_plane_normal_null), while reading
# a CYLINDER's axis direction is proven-live (cylinder-origin-transform-axes).
# So the most reliable "up" we can get is the average of the trustworthy bore
# axes, sign-aligned so an anti-parallel descriptor return can't cancel the sum.
#
# CONVENTION (matches creo_geometry.ps1 / orthogrid.ps1): a function that
# COMPUTES never throws - invalid input returns a result object with Valid=$false
# and Errors populated. A trap from a math helper would kill the whole run.
# COM-array trap (documented in creo_geometry.ps1): build each vector component
# on its OWN line, never inside a comma-separated @(...) literal mixed with math.
# ============================================================================

# ----------------------------------------------------------------------------
# Vec3 helpers - tiny, self-contained (NOT relying on creo_geometry.ps1's Dot/
# Cross being dot-sourced, so this lib is independently testable). Each takes
# @(x,y,z) double arrays. Component-per-line to dodge the op_* on-array trap.
# ----------------------------------------------------------------------------
function IFrame-Dot {
    param($A, $B)
    return ([double]$A[0]*[double]$B[0] + [double]$A[1]*[double]$B[1] + [double]$A[2]*[double]$B[2])
}

function IFrame-Cross {
    param($A, $B)
    $cx = [double]$A[1]*[double]$B[2] - [double]$A[2]*[double]$B[1]
    $cy = [double]$A[2]*[double]$B[0] - [double]$A[0]*[double]$B[2]
    $cz = [double]$A[0]*[double]$B[1] - [double]$A[1]*[double]$B[0]
    return @($cx, $cy, $cz)
}

function IFrame-Norm {
    param($A)
    return [Math]::Sqrt((IFrame-Dot $A $A))
}

# Return a unit copy of $A, or $null if $A is degenerate (|A| < $Eps).
function IFrame-Unit {
    param($A, [double]$Eps = 1e-12)
    $n = IFrame-Norm $A
    if ($n -lt $Eps) { return $null }
    $ux = [double]$A[0]/$n
    $uy = [double]$A[1]/$n
    $uz = [double]$A[2]/$n
    return @($ux, $uy, $uz)
}

function IFrame-Sub {
    param($A, $B)
    $x = [double]$A[0]-[double]$B[0]
    $y = [double]$A[1]-[double]$B[1]
    $z = [double]$A[2]-[double]$B[2]
    return @($x, $y, $z)
}

# ----------------------------------------------------------------------------
# Get-IndexFrame - build the orthonormal index frame from the two index holes
# (and, for a robust Zhat, the bore directions of ALL holes).
#
# Inputs:
#   A1, A2     [double[3]]   axis ORIGIN points of index hole 1 and 2
#   D1, D2     [double[3]]   axis DIRECTIONS of index hole 1 and 2 (need not be
#                            unit; sign-aligned and averaged internally)
#   AllDirs    [double[3][]] OPTIONAL - every hole's bore direction. When given,
#                            Zhat = sign-aligned average over ALL of them (less
#                            noise than just D1,D2). Defaults to @(D1,D2).
#   VTol       [double]      min in-plane separation |v| to accept (deg. guard 1)
#   ZTol       [double]      min |sum of dirs| to accept (deg. guard 2)
#
# Returns [pscustomobject]:
#   Valid  [bool]      ; Errors [string[]]
#   O      [double[3]] = A1 (frame origin)
#   Xhat,Yhat,Zhat [double[3]] (unit, right-handed) - $null members when invalid
#   IndexSep [double]  = |v| = the +X coordinate index hole 2 maps to (d > 0)
#   AxisAngleDeg [double] = angle between D1,D2 (advisory; large => see WARN)
# NEVER throws.
# ----------------------------------------------------------------------------
function Get-IndexFrame {
    param(
        $A1, $A2, $D1, $D2,
        $AllDirs = $null,
        [double]$VTol = 1e-3,
        [double]$ZTol = 1e-9
    )
    $errors = @()

    # -- validate presence ----------------------------------------------------
    foreach ($pair in @(@('A1',$A1), @('A2',$A2), @('D1',$D1), @('D2',$D2))) {
        $v = $pair[1]
        $ok = $false
        try { $ok = ($null -ne $v -and $v.Count -ge 3) } catch {}
        if (-not $ok) { $errors += "$($pair[0]) must be a 3-component vector" }
    }
    if ($errors.Count -gt 0) {
        return [pscustomobject]@{
            Valid=$false; Errors=$errors; O=$null; Xhat=$null; Yhat=$null; Zhat=$null;
            IndexSep=$null; AxisAngleDeg=$null
        }
    }

    # -- unit index directions, sign-aligned so D2 points the same way as D1 --
    $u1 = IFrame-Unit $D1
    $u2 = IFrame-Unit $D2
    if ($null -eq $u1) { $errors += "D1 is degenerate (zero-length bore direction)" }
    if ($null -eq $u2) { $errors += "D2 is degenerate (zero-length bore direction)" }

    $axisAngleDeg = $null
    if ($null -ne $u1 -and $null -ne $u2) {
        $c = IFrame-Dot $u1 $u2
        if ($c -gt 1.0) { $c = 1.0 } elseif ($c -lt -1.0) { $c = -1.0 }
        $axisAngleDeg = [Math]::Acos([Math]::Abs($c)) * 180.0 / [Math]::PI
    }

    # -- Zhat = sign-aligned average of all available bore directions ---------
    # Sign-align EVERY direction to u1 before summing: an anti-parallel
    # descriptor return must not cancel the sum (judge guard #2).
    $dirs = @()
    if ($null -ne $AllDirs) {
        foreach ($d in $AllDirs) { if ($null -ne $d) { $dirs += ,$d } }
    }
    if ($dirs.Count -eq 0) { $dirs = @($D1, $D2) }

    $ref = if ($null -ne $u1) { $u1 } else { $u2 }
    $sx = 0.0; $sy = 0.0; $sz = 0.0
    if ($null -ne $ref) {
        foreach ($d in $dirs) {
            $ud = IFrame-Unit $d
            if ($null -eq $ud) { continue }
            $sgn = if ((IFrame-Dot $ud $ref) -lt 0) { -1.0 } else { 1.0 }
            $sx += $sgn * $ud[0]
            $sy += $sgn * $ud[1]
            $sz += $sgn * $ud[2]
        }
    }
    $zSum = @($sx, $sy, $sz)
    $Zhat = $null
    if ((IFrame-Norm $zSum) -lt $ZTol) {
        $errors += "bore directions cancel (|sum| < $ZTol) - cannot define Zhat (anti-parallel axes?)"
    } else {
        $Zhat = IFrame-Unit $zSum
    }

    # -- v = in-plane component of (A2 - A1); Xhat = v / |v| ------------------
    $Xhat = $null
    $indexSep = $null
    if ($null -ne $Zhat) {
        $w = IFrame-Sub $A2 $A1
        $along = IFrame-Dot $w $Zhat
        $vx = $w[0] - $along * $Zhat[0]
        $vy = $w[1] - $along * $Zhat[1]
        $vz = $w[2] - $along * $Zhat[2]
        $v = @($vx, $vy, $vz)
        $vn = IFrame-Norm $v
        if ($vn -lt $VTol) {
            $errors += "index holes are axially collinear (in-plane separation |v|=$([math]::Round($vn,6)) < $VTol) - X axis indeterminate"
        } else {
            $Xhat = IFrame-Unit $v
            $indexSep = $vn
        }
    }

    # -- Yhat = Zhat x Xhat (right-handed) -----------------------------------
    $Yhat = $null
    if ($null -ne $Zhat -and $null -ne $Xhat) {
        $Yhat = IFrame-Unit (IFrame-Cross $Zhat $Xhat)
        if ($null -eq $Yhat) { $errors += "Yhat degenerate (Zhat,Xhat not independent)" }
    }

    $valid = ($errors.Count -eq 0 -and $null -ne $Xhat -and $null -ne $Yhat -and $null -ne $Zhat)
    return [pscustomobject]@{
        Valid        = $valid
        Errors       = $errors
        O            = @([double]$A1[0], [double]$A1[1], [double]$A1[2])
        Xhat         = $Xhat
        Yhat         = $Yhat
        Zhat         = $Zhat
        IndexSep     = $indexSep
        AxisAngleDeg = $axisAngleDeg
    }
}

# ----------------------------------------------------------------------------
# ConvertTo-IndexCoords - express a hole's axis-origin P in the index frame.
# Returns [pscustomobject]@{ X; Y; Z; AtOrigin } (doubles), or $null if the frame
# is invalid or P is not a 3-vector. AtOrigin=$true flags |R|<Eps (P IS index
# hole 1). The (X,Y) are invariant to where along its bore P was read (see header).
# ----------------------------------------------------------------------------
function ConvertTo-IndexCoords {
    param($Frame, $P, [double]$Eps = 1e-9)
    if ($null -eq $Frame -or -not $Frame.Valid) { return $null }
    $ok = $false
    try { $ok = ($null -ne $P -and $P.Count -ge 3) } catch {}
    if (-not $ok) { return $null }
    $R = IFrame-Sub $P $Frame.O
    $x = IFrame-Dot $R $Frame.Xhat
    $y = IFrame-Dot $R $Frame.Yhat
    $z = IFrame-Dot $R $Frame.Zhat
    $atOrigin = ((IFrame-Norm $R) -lt $Eps)
    return [pscustomobject]@{
        X        = [double]$x
        Y        = [double]$y
        Z        = [double]$z
        AtOrigin = [bool]$atOrigin
    }
}

# ----------------------------------------------------------------------------
# Test-IndexFrameValid - runtime self-check that the frame is geometrically
# sound BEFORE any coordinates are trusted/reported (judge spec section 4).
# Two layers:
#   (a) ORTHONORMALITY residuals: |Xhat.Zhat|,|Yhat.Zhat|,|Xhat.Yhat|<Tol;
#       each axis unit to within Tol; right-handed (|cross(Zhat,Xhat)-Yhat|<Tol).
#   (b) FIXED POINTS (the load-bearing behavioral check): A1 -> (0,0,~0) and
#       A2 -> (+d, 0, ~0) with d>0. These confirm the frame is anchored AND
#       oriented (1->2 along +X) without trusting any intermediate value.
# Optionally WARNS (does not fail) when AxisAngleDeg > MaxAxisAngleDeg - the
# non-parallel-bore caveat where (x,y) invariance starts to degrade.
#
# Returns [pscustomobject]@{ Ok; Residuals(hashtable); Warnings[]; Errors[] }.
# Pass A1,A2 (the index origins used to build the frame) for the fixed-point leg;
# omit them to run orthonormality-only.
# ----------------------------------------------------------------------------
function Test-IndexFrameValid {
    param(
        $Frame, $A1 = $null, $A2 = $null,
        [double]$Tol = 1e-9,
        [double]$FixedTol = 1e-6,
        [double]$MaxAxisAngleDeg = 0.05
    )
    $errs = @()
    $warns = @()
    $res = @{}
    if ($null -eq $Frame -or -not $Frame.Valid) {
        return [pscustomobject]@{ Ok=$false; Residuals=$res; Warnings=$warns; Errors=@("frame is invalid: " + (($Frame.Errors) -join '; ')) }
    }

    # (a) orthonormality
    $res['Xz'] = [Math]::Abs((IFrame-Dot $Frame.Xhat $Frame.Zhat))
    $res['Yz'] = [Math]::Abs((IFrame-Dot $Frame.Yhat $Frame.Zhat))
    $res['Xy'] = [Math]::Abs((IFrame-Dot $Frame.Xhat $Frame.Yhat))
    $res['Xlen'] = [Math]::Abs((IFrame-Norm $Frame.Xhat) - 1.0)
    $res['Ylen'] = [Math]::Abs((IFrame-Norm $Frame.Yhat) - 1.0)
    $res['Zlen'] = [Math]::Abs((IFrame-Norm $Frame.Zhat) - 1.0)
    $rh = IFrame-Sub (IFrame-Cross $Frame.Zhat $Frame.Xhat) $Frame.Yhat
    $res['RH'] = IFrame-Norm $rh
    foreach ($k in @('Xz','Yz','Xy','Xlen','Ylen','Zlen','RH')) {
        if ($res[$k] -gt $Tol) { $errs += "orthonormality residual $k = $($res[$k]) exceeds $Tol" }
    }

    # (b) fixed points
    if ($null -ne $A1 -and $null -ne $A2) {
        $c1 = ConvertTo-IndexCoords -Frame $Frame -P $A1
        $c2 = ConvertTo-IndexCoords -Frame $Frame -P $A2
        if ($null -eq $c1 -or $null -eq $c2) {
            $errs += "could not transform A1/A2 for the fixed-point check"
        } else {
            $res['A1x'] = [Math]::Abs($c1.X); $res['A1y'] = [Math]::Abs($c1.Y)
            $res['A2y'] = [Math]::Abs($c2.Y)
            $res['A2x'] = $c2.X
            if ($res['A1x'] -gt $FixedTol) { $errs += "index hole 1 did not map to x=0 (got $($c1.X))" }
            if ($res['A1y'] -gt $FixedTol) { $errs += "index hole 1 did not map to y=0 (got $($c1.Y))" }
            if ($res['A2y'] -gt $FixedTol) { $errs += "index hole 2 not on +X axis (y=$($c2.Y))" }
            if ($c2.X -le $FixedTol)       { $errs += "index hole 2 not at +X (d=$($c2.X) must be > 0)" }
        }
    }

    # advisory: non-parallel bores
    if ($null -ne $Frame.AxisAngleDeg -and $Frame.AxisAngleDeg -gt $MaxAxisAngleDeg) {
        $warns += "index bore axes differ by $([math]::Round($Frame.AxisAngleDeg,4)) deg (> $MaxAxisAngleDeg) - (x,y) invariance degrades ~s*sin(theta); verify the plate is flat / bores parallel"
    }

    return [pscustomobject]@{
        Ok        = ($errs.Count -eq 0)
        Residuals = $res
        Warnings  = $warns
        Errors    = $errs
    }
}
