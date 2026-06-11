# ============================================================================
# lib\creo_geometry.ps1 - shared geometric-read helpers for the Creo toolkit
# ============================================================================
# Pure READS only - no script in this file mutates the model. Lifted (verbatim
# in spirit, keeping the hard-won comments) from the inline copies that had
# drifted across datinator / boxinator / holeinator / plane-probe so every tool
# - and the blind evaluator - measures the model the SAME way.
#
# Dot-source from a hybrid .cmd after $ScriptDir is set and a connection exists:
#     . (Join-Path $ScriptDir 'lib\creo_geometry.ps1')
#
# Every function takes its COM objects as parameters (no module-level $session /
# $model), so the file is also loadable in a plain PowerShell host with stubbed
# objects for the offline unit tests.
# ============================================================================

# ----------------------------------------------------------------------------
# Get-Comp - read the 3 components of an IpfcPoint3D / IpfcVector3D.
# The VB API exposes sequence members both via .Item(i) and as a direct array;
# gauginator/datinator read coords as $V[0..2] so bracket indexing is the
# confirmed path, with .Item as a fallback. Returns @(x,y,z) doubles or $null
# (a measurement failure must degrade to UNVERIFIED, never throw to a trap).
# ----------------------------------------------------------------------------
function Get-Comp {
    param($V)
    if ($null -eq $V) { return $null }
    try   { return @([double]$V[0], [double]$V[1], [double]$V[2]) }
    catch {
        try { return @([double]$V.Item(0), [double]$V.Item(1), [double]$V.Item(2)) }
        catch { return $null }
    }
}

# ----------------------------------------------------------------------------
# Dot - 3D dot product of two @(x,y,z) arrays.
# ----------------------------------------------------------------------------
function Dot {
    param($A, $B)
    ($A[0]*$B[0] + $A[1]*$B[1] + $A[2]*$B[2])
}

# ----------------------------------------------------------------------------
# Dist-PointToAxis - perpendicular distance from point P to the infinite line
# through A with direction D (D need not be unit - normalized here). Returns
# +inf if D is degenerate. This is the "does this point lie on that hole axis"
# metric used by holeinator's idempotency check.
# ----------------------------------------------------------------------------
function Dist-PointToAxis {
    param($P, $A, $D)
    $len = [Math]::Sqrt((Dot $D $D))
    if ($len -le 1e-12) { return [double]::PositiveInfinity }
    # NOTE: build each component on its own line, NOT inside a comma-separated
    # @(...) literal. Inside @($D[0]/$len, $D[1]/$len) PowerShell parses the comma
    # as building an array FIRST, so $D[0] / @($len, $D[1]) tries to divide a
    # scalar by an array and throws op_Division. Parenthesizing each term avoids it.
    $ux = $D[0]/$len; $uy = $D[1]/$len; $uz = $D[2]/$len
    $u  = @($ux, $uy, $uz)
    $vx = $P[0]-$A[0]; $vy = $P[1]-$A[1]; $vz = $P[2]-$A[2]
    $v  = @($vx, $vy, $vz)
    $t  = Dot $v $u                                  # projection onto axis
    $px = $vx - $t*$ux; $py = $vy - $t*$uy; $pz = $vz - $t*$uz
    $perp = @($px, $py, $pz)
    return [Math]::Sqrt((Dot $perp $perp))
}

# ----------------------------------------------------------------------------
# New-ExcludeTypes - build an IpfcModelItemTypes sequence of the datum item
# types EvalOutline should ignore. Default datum planes/axes/csys are auto-sized
# slightly larger than the solid and, if included, inflate every measured extent
# by a uniform amount (~0.0856 seen live). Passing these as ExcludeTypes makes
# the outline the SOLID GEOMETRY only.
#
# NOTE on risk (from boxinator): a datum plane's geometry may register as
# ITEM_SURFACE, which is ALSO the type of the solid's own faces. Excluding it
# could strip the box faces and collapse the outline - Measure-Extents runs a
# degenerate-outline guard and falls back to a no-exclude EvalOutline if so.
# ----------------------------------------------------------------------------
function New-ExcludeTypes {
    param($TypeObj)
    $names = @("ITEM_AXIS", "ITEM_COORD_SYS", "ITEM_POINT", "ITEM_CURVE", "ITEM_SURFACE")
    foreach ($ctor in @("pfcls.pfcModelItemTypes", "pfcls.pfcmodelitemtypes")) {
        try {
            $seq = New-Object -ComObject $ctor
            foreach ($n in $names) {
                $val = $null
                try { $val = $TypeObj.$n } catch {}
                if ($null -eq $val) { continue }
                $added = $false
                foreach ($m in @("Append", "Add", "Insert", "Set")) {
                    try { $seq.$m($val) | Out-Null; $added = $true; break } catch {}
                }
                if (-not $added) { try { $seq.Item($seq.Count) = $val } catch {} }
            }
            if ($seq.Count -gt 0) { return $seq }
        } catch {}
    }
    return $null
}

# ----------------------------------------------------------------------------
# Get-OutlineExtents - read the raw min/max corners from an IpfcOutline3D and
# return per-axis extents @(dx,dy,dz), or $null if the outline could not be read.
# ----------------------------------------------------------------------------
function Get-OutlineExtents {
    param($Outline)
    if ($null -eq $Outline) { return $null }
    $p0 = $null; $p1 = $null
    try { $p0 = $Outline[0]; $p1 = $Outline[1] } catch {}
    if ($null -eq $p0 -or $null -eq $p1) {
        try { $p0 = $Outline.Item(0); $p1 = $Outline.Item(1) } catch {}
    }
    if ($null -eq $p0 -or $null -eq $p1) { return $null }
    $a = Get-Comp $p0
    $b = Get-Comp $p1
    if ($null -eq $a -or $null -eq $b) { return $null }
    return @([math]::Abs($b[0]-$a[0]), [math]::Abs($b[1]-$a[1]), [math]::Abs($b[2]-$a[2]))
}

# ----------------------------------------------------------------------------
# Measure-Extents - measure a solid's true size via its regeneration outline.
# EvalOutline returns an IpfcOutline3D (2-element min/max corner sequence); the
# three axis extents ARE the solid's real X/Y/Z size, independent of any
# dimension symbol. Returns per-axis @(dx,dy,dz) - NOT sorted - so the caller
# can map axes itself; or $null if it could not be read.
#
# Datums are excluded so they don't inflate the result; if the exclude collapses
# the outline (a face type got stripped) we discard it and fall back to the
# plain no-exclude EvalOutline, then GetOutline as a last resort.
#
# (Was boxinator's Measure-BoxExtents - renamed generic; identical behavior.)
# ----------------------------------------------------------------------------
function Measure-Extents {
    param($Solid, $ExcludeTypes)

    $ext = $null
    if ($null -ne $ExcludeTypes) {
        $o = $null
        try { $o = $Solid.EvalOutline($null, $ExcludeTypes) } catch {}
        $ext = Get-OutlineExtents -Outline $o
        # Guard: a collapsed/degenerate box (any extent ~0) means the exclude
        # stripped real geometry - discard and fall through to no-exclude.
        if ($null -ne $ext -and ($ext[0] -lt 1e-6 -or $ext[1] -lt 1e-6 -or $ext[2] -lt 1e-6)) {
            $ext = $null
        }
    }
    if ($null -eq $ext) {
        $o = $null
        try { $o = $Solid.EvalOutline($null, $null) } catch {}
        if ($null -eq $o) { try { $o = $Solid.GetOutline() } catch {} }
        $ext = Get-OutlineExtents -Outline $o
    }
    return $ext
}

# ----------------------------------------------------------------------------
# Get-AllSurfaces - gather every surface across all solid bodies (fall back to
# the default body). Centralized so a counter and an axis-reader can never
# diverge on which surfaces they see. (From holeinator.)
# ----------------------------------------------------------------------------
function Get-AllSurfaces {
    param($Model, $TypeObj)
    if ($null -eq $TypeObj) { $TypeObj = New-Object -ComObject pfcls.pfcModelItemType }
    $allSurfaces = @()
    try {
        $allBodies = @($Model.ListItems($TypeObj.ITEM_BODY))
        foreach ($body in $allBodies) {
            try {
                $bs = $body.ListSurfaces()
                if ($null -ne $bs -and $bs.Count -gt 0) {
                    for ($i = 0; $i -lt $bs.Count; $i++) { $allSurfaces += $bs.Item($i) }
                }
            } catch {}
        }
    } catch {}
    if ($allSurfaces.Count -eq 0) {
        try {
            $surfaces = $Model.GetDefaultBody().ListSurfaces()
            if ($null -ne $surfaces -and $surfaces.Count -gt 0) {
                for ($i = 0; $i -lt $surfaces.Count; $i++) { $allSurfaces += $surfaces.Item($i) }
            }
        } catch {}
    }
    return $allSurfaces
}

# ----------------------------------------------------------------------------
# Count-Cylinders - count cylindrical surfaces. If $TargetRadius > 0, only count
# cylinders whose radius matches within $RadTol; otherwise count every cylinder.
# Reads via $desc.Radius and [int]$type -eq 1 exactly as radinator does.
# (From holeinator.)
# ----------------------------------------------------------------------------
function Count-Cylinders {
    param($Model, $TypeObj, [double]$TargetRadius = 0.0, [double]$RadTol = 1e-3)
    $count = 0
    foreach ($surf in (Get-AllSurfaces -Model $Model -TypeObj $TypeObj)) {
        try {
            $desc = $surf.GetSurfaceDescriptor()
            $type = [int]$desc.GetSurfaceType()
            if ($type -eq 1) {   # EpfcSURFACE_CYLINDER
                if ($TargetRadius -le 0.0) {
                    $count++
                } else {
                    $r = $null
                    try { $r = [double]$desc.Radius } catch {}
                    if ($null -ne $r -and [Math]::Abs($r - $TargetRadius) -le $RadTol) { $count++ }
                }
            }
        } catch {}
    }
    return $count
}

# ----------------------------------------------------------------------------
# Get-CylinderAxes - read existing cylinder axes at a target radius. A drilled
# hole leaves a same-radius cylinder whose axis passes through the original
# datum point; reading those axes lets a create loop skip already-drilled
# points. The cylinder descriptor's .Origin is an IpfcTransform3D; axis point =
# Origin.GetOrigin(), axis dir = Origin.GetZAxis(). Returns an array of
# @{ A = <pt[3]>; D = <dir[3]> }. (From holeinator.)
# ----------------------------------------------------------------------------
function Get-CylinderAxes {
    param($Model, $TypeObj, [double]$TargetRadius, [double]$RadTol = 1e-3)
    $axes = @()
    foreach ($surf in (Get-AllSurfaces -Model $Model -TypeObj $TypeObj)) {
        try {
            $desc = $surf.GetSurfaceDescriptor()
            if ([int]$desc.GetSurfaceType() -ne 1) { continue }      # cylinders only
            $r = $null
            try { $r = [double]$desc.Radius } catch {}
            if ($null -eq $r -or [Math]::Abs($r - $TargetRadius) -gt $RadTol) { continue }
            $xf = $desc.Origin                                       # IpfcTransform3D
            $a = Get-Comp $xf.GetOrigin()
            $d = Get-Comp $xf.GetZAxis()
            if ($null -ne $a -and $null -ne $d) { $axes += @{ A = $a; D = $d } }
        } catch {}
    }
    return $axes
}

# ----------------------------------------------------------------------------
# Get-LinearDimMap - snapshot every LINEAR dimension symbol on the model -> its
# value. New feature dims (e.g. a datum-plane offset, an extrude depth) are
# found by diffing this before vs after an operation, so a script never has to
# guess a dim symbol. ListItems(ITEM_DIMENSION) is the proven Solid path.
# (From plane-probe; boxinator's Get-DimSymbols also keeps DimType - this one is
# linear-only by design for the offset-diff use.)
# ----------------------------------------------------------------------------
function Get-LinearDimMap {
    param($Model, $TypeObj)
    $map = @{}
    try {
        foreach ($d in $Model.ListItems($TypeObj.ITEM_DIMENSION)) {
            try { if ($d.DimType -eq 0) { $map[[string]$d.Symbol] = [double]$d.DimValue } } catch {}
        }
    } catch {}
    return $map
}

# ----------------------------------------------------------------------------
# Read-DimValue - re-read one dim's value by symbol with a FRESH handle (old COM
# handles can go stale across a regen). Returns the double or $null. The fresh
# GetItemByName lookup is the truth check: after a write+regen, this is the only
# read that tells you whether the value actually stuck. (From plane-probe.)
# ----------------------------------------------------------------------------
function Read-DimValue {
    param($Model, $TypeObj, [string]$Sym)
    try {
        $item = $Model.GetItemByName($TypeObj.ITEM_DIMENSION, $Sym)
        # The real COM GetItemByName THROWS on a missing item (caught below), but
        # guard the null path too: [double]$null silently coerces to 0.0, which
        # would be a wrong dim reading masquerading as a real one.
        if ($null -eq $item) { return $null }
        return [double]$item.DimValue
    }
    catch { return $null }
}

# ----------------------------------------------------------------------------
# Test-ExtentsMatch - DETERMINISTIC by-value check that a set of expected
# dimension values all appear among a set of measured extents, each within
# tolerance, with no measured extent used twice (a multiset match).
#
# WHY this exists separately from the LLM judge: numeric matching is arithmetic,
# not judgment. "Is 4.0 among [4.0009, 3.0, 2.0] within tol?" has one correct
# answer that must be the SAME every run - an LLM can flicker confirm/uncertain
# on identical input, which is corrosive for a verification gate. So the toolkit
# owns the arithmetic here; the LLM is reserved for the semantic call ("is this
# really a node fillet?") and the human-readable summary. Matching is by VALUE
# (greedy nearest, each measured value consumed once), so it is independent of
# axis order - a width/height/depth swap still matches the right values, and a
# genuinely wrong value (or a snap-back to the wrong size) fails to match.
#
# Returns a [pscustomobject]:
#   AllMatched : $true only if EVERY expected value found an unused measured one
#   Pairs      : per-expected @{ Expected; Matched(or $null); Error; Ok }
#   Tol        : the tolerance used
# $Expected / $Measured are plain double arrays. $null/empty $Measured -> no
# match (AllMatched $false, every pair Ok=$false) rather than a throw.
# ----------------------------------------------------------------------------
function Test-ExtentsMatch {
    param(
        [double[]]$Expected,
        [double[]]$Measured,
        [double]$Tol = 0.1
    )
    $pairs = @()
    # Work on a mutable copy of measured values; null out each as it is consumed
    # so two expected values can't both claim the same measured extent.
    $pool = @()
    if ($null -ne $Measured) { foreach ($m in $Measured) { $pool += [double]$m } }

    $all = $true
    foreach ($e in $Expected) {
        $bestIdx = -1; $bestErr = [double]::MaxValue
        for ($i = 0; $i -lt $pool.Count; $i++) {
            if ($null -eq $pool[$i]) { continue }                 # already consumed
            $err = [Math]::Abs([double]$pool[$i] - [double]$e)
            if ($err -lt $bestErr) { $bestErr = $err; $bestIdx = $i }
        }
        if ($bestIdx -ge 0 -and $bestErr -le $Tol) {
            $matched = [double]$pool[$bestIdx]
            $pool[$bestIdx] = $null                               # consume it
            $pairs += [pscustomobject]@{ Expected = [double]$e; Matched = $matched; Error = $bestErr; Ok = $true }
        } else {
            $all = $false
            $m = if ($bestIdx -ge 0) { [double]$pool[$bestIdx] } else { $null }
            $err = if ($bestIdx -ge 0) { $bestErr } else { [double]::PositiveInfinity }
            $pairs += [pscustomobject]@{ Expected = [double]$e; Matched = $m; Error = $err; Ok = $false }
        }
    }
    return [pscustomobject]@{ AllMatched = $all; Pairs = $pairs; Tol = $Tol }
}
