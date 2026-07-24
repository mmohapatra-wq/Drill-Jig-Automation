# ============================================================================
# lib\curved_jig.ps1 - pure per-hole ANGULARITY + curved-layout math
# ============================================================================
# Pure MATH only - no COM, no network, no module-level state. The angular /
# spatial math the CURVED (conformal) drill jig needs to bring it to parity with
# the proven FLAT jig. Where the flat jig assumes every bore is perpendicular to
# a plate face (one nominal drilling axis), the curved jig must carry, PER HOLE,
# both the position AND the bore's ANGLE relative to the OG (original-part)
# coordinate system - because fasteners on a curved panel are NOT axis-parallel
# (user architecture #2).
#
# Dot-source from a hybrid .cmd after $ScriptDir is set (no connection needed):
#     . (Join-Path $ScriptDir 'lib\curved_jig.ps1')
# Also loadable in a plain PowerShell host - the offline unit tests dot-source it
# directly with no Creo. If index_frame.ps1 is ALSO dot-sourced in scope,
# Get-CurvedIndexExport reuses its Get-IndexFrame/ConvertTo-IndexCoords; if not,
# it falls back to a minimal in-file re-derivation (so this lib is independently
# testable / usable). No Creo calls anywhere in this file.
#
# ----------------------------------------------------------------------------
# HOW an angle is represented (Get-BoreAngularity):
#   Given a bore axis DIRECTION and the OG csys axes (default = world X/Y/Z):
#     DirCosX/Y/Z   = cos of the angle between the (unit) axis and each OG axis
#                     = the axis's components in the OG frame (direction cosines).
#     AngleFromZDeg = angle off the OG Z (the NOMINAL drilling axis) = the tilt
#                     that matters for "is this hole slanted?" (0 = straight down).
#     AzimuthDeg    = spherical azimuth in the OG X/Y plane, atan2(cy, cx), 0..360.
#     PolarDeg      = spherical polar off +Z, == AngleFromZDeg (kept as a named
#                     spherical pair with AzimuthDeg).
#   The axis is sign-normalized to the +Z hemisphere first (a bore direction and
#   its negation are the same drilling line), so AngleFromZDeg is always in
#   [0,90] and the reported tilt is orientation-consistent hole to hole.
#
# CONVENTION (matches creo_geometry.ps1 / index_frame.ps1 / orthogrid.ps1): a
# function that COMPUTES never throws - invalid input returns a result object
# with Valid=$false and Errors populated. A trap from a math helper would kill
# the whole run. COM-array trap: build each vector component on its OWN line,
# never inside a comma-separated @(math,math,math) literal.
# ============================================================================

# ----------------------------------------------------------------------------
# Vec3 helpers - tiny, self-contained (do NOT rely on creo_geometry.ps1's Dot/
# Cross or index_frame.ps1's IFrame-* being dot-sourced, so this lib is
# independently testable). Each takes @(x,y,z) double arrays. Component-per-line
# to dodge the op_* on-array trap.
# ----------------------------------------------------------------------------
function global:CJ-Dot {
    param($A, $B)
    return ([double]$A[0]*[double]$B[0] + [double]$A[1]*[double]$B[1] + [double]$A[2]*[double]$B[2])
}

function global:CJ-Cross {
    param($A, $B)
    $cx = [double]$A[1]*[double]$B[2] - [double]$A[2]*[double]$B[1]
    $cy = [double]$A[2]*[double]$B[0] - [double]$A[0]*[double]$B[2]
    $cz = [double]$A[0]*[double]$B[1] - [double]$A[1]*[double]$B[0]
    return @($cx, $cy, $cz)
}

function global:CJ-Norm {
    param($A)
    return [Math]::Sqrt((CJ-Dot $A $A))
}

# Return a unit copy of $A, or $null if $A is degenerate (|A| < $Eps).
function global:CJ-Unit {
    param($A, [double]$Eps = 1e-12)
    $n = CJ-Norm $A
    if ($n -lt $Eps) { return $null }
    $ux = [double]$A[0]/$n
    $uy = [double]$A[1]/$n
    $uz = [double]$A[2]/$n
    return @($ux, $uy, $uz)
}

function global:CJ-Sub {
    param($A, $B)
    $x = [double]$A[0]-[double]$B[0]
    $y = [double]$A[1]-[double]$B[1]
    $z = [double]$A[2]-[double]$B[2]
    return @($x, $y, $z)
}

# Is $V a usable 3-component vector? (guarded - never throws on odd shapes)
function global:CJ-IsVec3 {
    param($V)
    $ok = $false
    try { $ok = ($null -ne $V -and $V.Count -ge 3) } catch { $ok = $false }
    return $ok
}

# Clamp a dot-product cosine into [-1,1] before Acos (float noise guard).
function global:CJ-ClampCos {
    param([double]$C)
    if ($C -gt 1.0) { return 1.0 }
    if ($C -lt -1.0) { return -1.0 }
    return $C
}

# ----------------------------------------------------------------------------
# Get-BoreAngularity - the angle of a bore axis relative to the OG csys.
#
# Inputs:
#   Axis  [double[3]]   bore axis DIRECTION (need not be unit).
#   RefX/RefY/RefZ [double[3]] the OG csys axes (default = world X/Y/Z). They
#                     SHOULD be orthonormal; direction cosines are computed
#                     against each as given (each internally unit-normalized so a
#                     non-unit OG axis still yields a true cosine).
#
# Returns [pscustomobject]:
#   Valid [bool] ; Errors [string[]]
#   DirCosX/Y/Z    [double]  cos(angle) vs OG X/Y/Z (== components in OG frame)
#   AngleFromZDeg  [double]  angle off OG Z (nominal drill axis), 0..90
#   AzimuthDeg     [double]  spherical azimuth in OG XY plane, 0..360
#   PolarDeg       [double]  spherical polar off +Z (== AngleFromZDeg)
# Degenerate/zero axis (or a degenerate OG axis) => Valid=$false. NEVER throws.
# ----------------------------------------------------------------------------
function global:Get-BoreAngularity {
    param(
        $Axis,
        $RefX = @(1.0, 0.0, 0.0),
        $RefY = @(0.0, 1.0, 0.0),
        $RefZ = @(0.0, 0.0, 1.0)
    )
    $errors = @()

    if (-not (CJ-IsVec3 $Axis)) { $errors += "Axis must be a 3-component vector" }
    if (-not (CJ-IsVec3 $RefX)) { $errors += "RefX must be a 3-component vector" }
    if (-not (CJ-IsVec3 $RefY)) { $errors += "RefY must be a 3-component vector" }
    if (-not (CJ-IsVec3 $RefZ)) { $errors += "RefZ must be a 3-component vector" }
    if ($errors.Count -gt 0) {
        return [pscustomobject]@{
            Valid=$false; Errors=$errors;
            DirCosX=$null; DirCosY=$null; DirCosZ=$null;
            AngleFromZDeg=$null; AzimuthDeg=$null; PolarDeg=$null
        }
    }

    $uAxis = CJ-Unit $Axis
    $uX = CJ-Unit $RefX
    $uY = CJ-Unit $RefY
    $uZ = CJ-Unit $RefZ
    if ($null -eq $uAxis) { $errors += "Axis is degenerate (zero-length bore direction)" }
    if ($null -eq $uX)    { $errors += "RefX is degenerate (zero-length axis)" }
    if ($null -eq $uY)    { $errors += "RefY is degenerate (zero-length axis)" }
    if ($null -eq $uZ)    { $errors += "RefZ is degenerate (zero-length axis)" }
    if ($errors.Count -gt 0) {
        return [pscustomobject]@{
            Valid=$false; Errors=$errors;
            DirCosX=$null; DirCosY=$null; DirCosZ=$null;
            AngleFromZDeg=$null; AzimuthDeg=$null; PolarDeg=$null
        }
    }

    # Sign-normalize to the +Z hemisphere: a bore direction and its negation are
    # the same drilling line, so flip the axis so its OG-Z component is >= 0.
    # This keeps AngleFromZDeg in [0,90] and azimuth consistent hole to hole.
    $cz0 = CJ-Dot $uAxis $uZ
    if ($cz0 -lt 0.0) {
        $fx = -1.0 * $uAxis[0]
        $fy = -1.0 * $uAxis[1]
        $fz = -1.0 * $uAxis[2]
        $uAxis = @($fx, $fy, $fz)
    }

    $dcX = CJ-Dot $uAxis $uX
    $dcY = CJ-Dot $uAxis $uY
    $dcZ = CJ-Dot $uAxis $uZ

    $angZ = [Math]::Acos((CJ-ClampCos $dcZ)) * 180.0 / [Math]::PI

    # Spherical azimuth in the OG XY plane: atan2(component-on-Y, component-on-X).
    $az = [Math]::Atan2($dcY, $dcX) * 180.0 / [Math]::PI
    if ($az -lt 0.0) { $az += 360.0 }

    return [pscustomobject]@{
        Valid         = $true
        Errors        = @()
        DirCosX       = [double]$dcX
        DirCosY       = [double]$dcY
        DirCosZ       = [double]$dcZ
        AngleFromZDeg = [double]$angZ
        AzimuthDeg    = [double]$az
        PolarDeg      = [double]$angZ
    }
}

# ----------------------------------------------------------------------------
# Get-CurvedHolePlan - map a list of read holes (position + axis) into per-hole
# records carrying Pos, Axis, and each hole's Get-BoreAngularity, plus a summary.
#
# Inputs:
#   Holes  array of @{ Pos=@(x,y,z); Axis=@(x,y,z) } (Pos optional per hole -
#          angularity only needs Axis; Pos is passed through for later stages).
#   RefX/RefY/RefZ  OG csys axes (default world), forwarded to Get-BoreAngularity.
#   MaxTiltDeg      warn threshold for AngleFromZDeg (default 5 deg).
#
# Returns [pscustomobject]:
#   Valid [bool]   ($true when Holes was a usable list, even if some holes are
#                   flagged - a bad hole is NON-fatal); Errors [string[]]
#   Holes  array of @{ Index; Pos; Axis; Angularity; Valid; Errors } (Angularity
#          is the Get-BoreAngularity result; a bad-axis hole has Valid=$false but
#          is still returned so the caller sees which one).
#   Count            [int]    number of input holes
#   ValidCount       [int]    holes with a usable angularity
#   MaxAngleFromZDeg [double] largest AngleFromZDeg over valid holes (0 if none)
#   AnyTilted        [bool]   any valid hole with AngleFromZDeg > MaxTiltDeg
#   TiltedIndices    [int[]]  indices of holes exceeding MaxTiltDeg
#   MaxTiltDeg       [double] the threshold echoed back
#   Warnings         [string[]] human-readable tilt warnings
# NEVER throws.
# ----------------------------------------------------------------------------
function global:Get-CurvedHolePlan {
    param(
        $Holes,
        $RefX = @(1.0, 0.0, 0.0),
        $RefY = @(0.0, 1.0, 0.0),
        $RefZ = @(0.0, 0.0, 1.0),
        [double]$MaxTiltDeg = 5.0
    )
    $errors = @()
    $warnings = @()

    $isList = $false
    try { $isList = ($null -ne $Holes -and $Holes.Count -ge 1) } catch { $isList = $false }
    if (-not $isList) {
        return [pscustomobject]@{
            Valid=$false; Errors=@("Holes must be a non-empty list of @{ Pos; Axis }");
            Holes=@(); Count=0; ValidCount=0; MaxAngleFromZDeg=0.0;
            AnyTilted=$false; TiltedIndices=@(); MaxTiltDeg=[double]$MaxTiltDeg; Warnings=@()
        }
    }

    $records = @()
    $maxAng = 0.0
    $validCount = 0
    $tilted = @()
    $i = 0
    foreach ($h in $Holes) {
        $pos = $null
        $axis = $null
        try { $pos = $h.Pos } catch {}
        try { $axis = $h.Axis } catch {}

        $ang = Get-BoreAngularity -Axis $axis -RefX $RefX -RefY $RefY -RefZ $RefZ
        $hErrs = @()
        $hValid = $false
        if ($null -ne $ang -and $ang.Valid) {
            $hValid = $true
            $validCount++
            if ($ang.AngleFromZDeg -gt $maxAng) { $maxAng = $ang.AngleFromZDeg }
            if ($ang.AngleFromZDeg -gt $MaxTiltDeg) {
                $tilted += $i
                $warnings += "hole #$i is tilted $([math]::Round($ang.AngleFromZDeg,3)) deg off nominal Z (> $MaxTiltDeg)"
            }
        } else {
            if ($null -ne $ang) { $hErrs = $ang.Errors } else { $hErrs = @("angularity could not be computed") }
        }

        $records += [pscustomobject]@{
            Index      = $i
            Pos        = $pos
            Axis       = $axis
            Angularity = $ang
            Valid      = $hValid
            Errors     = $hErrs
        }
        $i++
    }

    return [pscustomobject]@{
        Valid            = $true
        Errors           = $errors
        Holes            = $records
        Count            = [int]$records.Count
        ValidCount       = [int]$validCount
        MaxAngleFromZDeg = [double]$maxAng
        AnyTilted        = [bool]($tilted.Count -gt 0)
        TiltedIndices    = $tilted
        MaxTiltDeg       = [double]$MaxTiltDeg
        Warnings         = $warnings
    }
}

# ----------------------------------------------------------------------------
# Get-CurvedIndexExport - the curved analog of the flat Get-HolesRelativeToIndex,
# keeping FULL 3D position + per-hole orientation. Build the index frame from two
# index-hole positions and express every hole in it, alongside its bore
# angularity (direction cosines + angle off nominal Z).
#
# Reuse: if Get-IndexFrame / ConvertTo-IndexCoords (index_frame.ps1) are in scope
# they are used verbatim (the load-bearing (x,y)-invariance math); otherwise a
# minimal in-file re-derivation runs (same convention: Zhat = sign-aligned
# average of the bore axes; Xhat = in-plane part of A1->A2; Yhat = Zhat x Xhat).
#
# Inputs:
#   Holes    array of @{ Pos=@(x,y,z); Axis=@(x,y,z) } - Pos AND Axis required per
#            hole here (Pos to place it, Axis for Zhat + angularity).
#   IndexA   [double[3]] position of index hole #1 (frame origin).
#   IndexB   [double[3]] position of index hole #2 (defines +X).
#   RefX/RefY/RefZ  OG csys axes for the ANGULARITY report (default world). The
#            index-frame (X_index/Y_index/Z_index) is independent of these.
#   IndexTol [double] proximity tol (world units) for tagging a hole as an index
#            hole (IsIndex) by position match to IndexA/IndexB (default 1e-6).
#
# Returns [pscustomobject]:
#   Valid [bool] ; Errors [string[]]
#   Frame  the index-frame object (Get-IndexFrame result, or the in-file equiv)
#   Rows   array of @{ Index; X_index; Y_index; Z_index; DirCosX; DirCosY;
#          DirCosZ; AngleFromZDeg; AzimuthDeg; IsIndex; Valid; Errors }
#          (index-frame coords + angularity per hole; a bad hole is flagged).
#   Count            [int]
#   MaxAngleFromZDeg [double]
# NEVER throws. Frame-invalid (collinear index bores / cancelled axes / too-close
# index holes) => Valid=$false with Frame carrying the reason.
# ----------------------------------------------------------------------------
function global:Get-CurvedIndexExport {
    param(
        $Holes,
        $IndexA,
        $IndexB,
        $RefX = @(1.0, 0.0, 0.0),
        $RefY = @(0.0, 1.0, 0.0),
        $RefZ = @(0.0, 0.0, 1.0),
        [double]$IndexTol = 1e-6
    )
    $errors = @()

    $isList = $false
    try { $isList = ($null -ne $Holes -and $Holes.Count -ge 1) } catch { $isList = $false }
    if (-not $isList)               { $errors += "Holes must be a non-empty list of @{ Pos; Axis }" }
    if (-not (CJ-IsVec3 $IndexA))   { $errors += "IndexA must be a 3-component position" }
    if (-not (CJ-IsVec3 $IndexB))   { $errors += "IndexB must be a 3-component position" }
    if ($errors.Count -gt 0) {
        return [pscustomobject]@{
            Valid=$false; Errors=$errors; Frame=$null; Rows=@(); Count=0; MaxAngleFromZDeg=0.0
        }
    }

    # Gather all bore directions for a robust Zhat (and the index axes D1/D2).
    $allDirs = @()
    $d1 = $null
    $d2 = $null
    foreach ($h in $Holes) {
        $ax = $null
        $ps = $null
        try { $ax = $h.Axis } catch {}
        try { $ps = $h.Pos } catch {}
        if (CJ-IsVec3 $ax) {
            $allDirs += ,$ax
            if ($null -eq $d1 -and (CJ-IsVec3 $ps) -and ((CJ-Norm (CJ-Sub $ps $IndexA)) -le $IndexTol)) { $d1 = $ax }
            if ($null -eq $d2 -and (CJ-IsVec3 $ps) -and ((CJ-Norm (CJ-Sub $ps $IndexB)) -le $IndexTol)) { $d2 = $ax }
        }
    }
    # Fallbacks: if an index hole's own axis wasn't matched by position, use the
    # aggregate so the frame's Zhat still comes from real bore directions.
    if ($null -eq $d1) { $d1 = if ($allDirs.Count -ge 1) { $allDirs[0] } else { $RefZ } }
    if ($null -eq $d2) { $d2 = if ($allDirs.Count -ge 2) { $allDirs[1] } else { $d1 } }

    # -- build the frame: reuse index_frame.ps1 if present, else re-derive -----
    $frame = $null
    $haveIFrame = $null -ne (Get-Command -Name 'Get-IndexFrame' -ErrorAction SilentlyContinue)
    if ($haveIFrame) {
        $frame = Get-IndexFrame -A1 $IndexA -A2 $IndexB -D1 $d1 -D2 $d2 -AllDirs $allDirs
    } else {
        $frame = CJ-BuildFrame -A1 $IndexA -A2 $IndexB -AllDirs $allDirs
    }

    if ($null -eq $frame -or -not $frame.Valid) {
        $fe = @()
        if ($null -ne $frame) { $fe = $frame.Errors }
        return [pscustomobject]@{
            Valid=$false; Errors=@("index frame invalid: " + (($fe) -join '; ')); Frame=$frame;
            Rows=@(); Count=0; MaxAngleFromZDeg=0.0
        }
    }

    $haveConvert = $null -ne (Get-Command -Name 'ConvertTo-IndexCoords' -ErrorAction SilentlyContinue)

    $rows = @()
    $maxAng = 0.0
    $i = 0
    foreach ($h in $Holes) {
        $pos = $null
        $axis = $null
        try { $pos = $h.Pos } catch {}
        try { $axis = $h.Axis } catch {}

        $rErrs = @()
        $rValid = $true

        # index-frame coordinates
        $coord = $null
        if (CJ-IsVec3 $pos) {
            if ($haveConvert) { $coord = ConvertTo-IndexCoords -Frame $frame -P $pos }
            else              { $coord = CJ-ToFrameCoords -Frame $frame -P $pos }
        }
        if ($null -eq $coord) { $rValid = $false; $rErrs += "position missing or not transformable" }

        # bore angularity vs OG csys
        $ang = Get-BoreAngularity -Axis $axis -RefX $RefX -RefY $RefY -RefZ $RefZ
        if ($null -eq $ang -or -not $ang.Valid) {
            $rValid = $false
            if ($null -ne $ang) { $rErrs += $ang.Errors } else { $rErrs += "angularity could not be computed" }
        } else {
            if ($ang.AngleFromZDeg -gt $maxAng) { $maxAng = $ang.AngleFromZDeg }
        }

        # index tagging by position proximity to A1 / A2
        $isIndex = $false
        if (CJ-IsVec3 $pos) {
            if ((CJ-Norm (CJ-Sub $pos $IndexA)) -le $IndexTol) { $isIndex = $true }
            elseif ((CJ-Norm (CJ-Sub $pos $IndexB)) -le $IndexTol) { $isIndex = $true }
        }

        $xi = $null; $yi = $null; $zi = $null
        if ($null -ne $coord) { $xi = $coord.X; $yi = $coord.Y; $zi = $coord.Z }
        $dcx = $null; $dcy = $null; $dcz = $null; $afz = $null; $azd = $null
        if ($null -ne $ang -and $ang.Valid) {
            $dcx = $ang.DirCosX; $dcy = $ang.DirCosY; $dcz = $ang.DirCosZ
            $afz = $ang.AngleFromZDeg; $azd = $ang.AzimuthDeg
        }

        $rows += [pscustomobject]@{
            Index         = $i
            X_index       = $xi
            Y_index       = $yi
            Z_index       = $zi
            DirCosX       = $dcx
            DirCosY       = $dcy
            DirCosZ       = $dcz
            AngleFromZDeg = $afz
            AzimuthDeg    = $azd
            IsIndex       = [bool]$isIndex
            Valid         = [bool]$rValid
            Errors        = $rErrs
        }
        $i++
    }

    return [pscustomobject]@{
        Valid            = $true
        Errors           = $errors
        Frame            = $frame
        Rows             = $rows
        Count            = [int]$rows.Count
        MaxAngleFromZDeg = [double]$maxAng
    }
}

# ----------------------------------------------------------------------------
# CJ-BuildFrame / CJ-ToFrameCoords - MINIMAL in-file re-derivation of the index
# frame, used ONLY when index_frame.ps1 is not dot-sourced in scope. Same
# convention as Get-IndexFrame (see index_frame.ps1 header for the full math and
# the (x,y)-invariance argument):
#   Zhat = normalize( sign-aligned sum of all bore directions )
#   Xhat = normalize( in-plane part of (A2 - A1) )
#   Yhat = Zhat x Xhat
# These are intentionally kept tiny; prefer index_frame.ps1 when available.
# ----------------------------------------------------------------------------
function global:CJ-BuildFrame {
    param($A1, $A2, $AllDirs, [double]$VTol = 1e-3, [double]$ZTol = 1e-9)
    $errors = @()

    $dirs = @()
    if ($null -ne $AllDirs) { foreach ($d in $AllDirs) { if (CJ-IsVec3 $d) { $dirs += ,$d } } }
    if ($dirs.Count -eq 0) { $errors += "no usable bore directions to define Zhat" }

    $ref = $null
    if ($dirs.Count -ge 1) { $ref = CJ-Unit $dirs[0] }

    $sx = 0.0; $sy = 0.0; $sz = 0.0
    if ($null -ne $ref) {
        foreach ($d in $dirs) {
            $ud = CJ-Unit $d
            if ($null -eq $ud) { continue }
            $sgn = if ((CJ-Dot $ud $ref) -lt 0) { -1.0 } else { 1.0 }
            $sx += $sgn * $ud[0]
            $sy += $sgn * $ud[1]
            $sz += $sgn * $ud[2]
        }
    }
    $zSum = @($sx, $sy, $sz)
    $Zhat = $null
    if ((CJ-Norm $zSum) -lt $ZTol) { $errors += "bore directions cancel - cannot define Zhat" }
    else { $Zhat = CJ-Unit $zSum }

    $Xhat = $null
    $indexSep = $null
    if ($null -ne $Zhat) {
        $w = CJ-Sub $A2 $A1
        $along = CJ-Dot $w $Zhat
        $vx = $w[0] - $along * $Zhat[0]
        $vy = $w[1] - $along * $Zhat[1]
        $vz = $w[2] - $along * $Zhat[2]
        $v = @($vx, $vy, $vz)
        $vn = CJ-Norm $v
        if ($vn -lt $VTol) { $errors += "index holes axially collinear - X axis indeterminate" }
        else { $Xhat = CJ-Unit $v; $indexSep = $vn }
    }

    $Yhat = $null
    if ($null -ne $Zhat -and $null -ne $Xhat) {
        $Yhat = CJ-Unit (CJ-Cross $Zhat $Xhat)
        if ($null -eq $Yhat) { $errors += "Yhat degenerate" }
    }

    $valid = ($errors.Count -eq 0 -and $null -ne $Xhat -and $null -ne $Yhat -and $null -ne $Zhat)
    return [pscustomobject]@{
        Valid=$valid; Errors=$errors;
        O=@([double]$A1[0], [double]$A1[1], [double]$A1[2]);
        Xhat=$Xhat; Yhat=$Yhat; Zhat=$Zhat; IndexSep=$indexSep; AxisAngleDeg=$null
    }
}

function global:CJ-ToFrameCoords {
    param($Frame, $P, [double]$Eps = 1e-9)
    if ($null -eq $Frame -or -not $Frame.Valid) { return $null }
    if (-not (CJ-IsVec3 $P)) { return $null }
    $R = CJ-Sub $P $Frame.O
    $x = CJ-Dot $R $Frame.Xhat
    $y = CJ-Dot $R $Frame.Yhat
    $z = CJ-Dot $R $Frame.Zhat
    $atOrigin = ((CJ-Norm $R) -lt $Eps)
    return [pscustomobject]@{ X=[double]$x; Y=[double]$y; Z=[double]$z; AtOrigin=[bool]$atOrigin }
}
