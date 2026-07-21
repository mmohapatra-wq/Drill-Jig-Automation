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
# ConvertTo-LayoutXZ - project 3D fastener CENTERS onto the 2D jig layout plane
# the user chose, corner-shift so every point is a positive offset, and merge
# near-coincident stacks (a through-bolt reads as bolt + washer + nut cylinders
# at nearly the same (X,Z)). This is the PUBLIC CONTRACT fastenator.cmd + the
# drilljig import mode bind to.
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
        [double]$DedupTol = 1e-4
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

    # -- project every center to a raw (x,z); collect problems, never throw ---
    # raw = the chosen model-axis components BEFORE the corner-shift.
    $raw     = @()
    $skipped = 0
    $i = 0
    if ($null -ne $Centers) {
        foreach ($ctr in $Centers) {
            $rx = Get-AxisComponent -Center $ctr -Axis $ax -Sign $AxisXSign
            $rz = Get-AxisComponent -Center $ctr -Axis $az -Sign $AxisZSign
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
            Margin=[double]$Margin; DedupTol=[double]$DedupTol
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
