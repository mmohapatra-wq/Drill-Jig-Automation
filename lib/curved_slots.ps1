# ============================================================================
# lib\curved_slots.ps1 - pure CURVED chip-relief SLOT PLANNING math
# ============================================================================
# Pure MATH only - no COM, no network, no module-level state. Plans the CURVED
# (conformal) drill jig's chip-relief slot loop from a per-hole layout, so the
# (later) drilljig3d slot stage can arm each seed sketch BY ID and cut. This is
# the curved analog of the FLAT jig's Get-RowSlots + Get-SlotSeedPatterns
# (lib\orthogrid.ps1): the flat jig draws ONE seed slot on the SIDE face and
# replicates it with a single-direction linear pattern; on a CURVED face every
# bore normal differs, so a single linear pattern will NOT replicate the seed to
# arbitrary curved positions. Instead each curved hole already carries the datum
# PLANE it was intersected through (SketchPlaneId), and a sketch CAN be opened on
# that plane fed BY ID with NO screen pick (fact `sketch-open-on-plane-by-id`,
# PROVEN-LIVE 2026-07-24, slotplane-probe.cmd). So the curved plan is a list of
# per-hole (or per-row) SEEDS, each naming the plane its slot sketch is armed on.
#
# Dot-source from a hybrid .cmd after $ScriptDir is set (no connection needed):
#     . (Join-Path $ScriptDir 'lib\curved_slots.ps1')
# Also loadable in a plain PowerShell host - the offline unit tests dot-source it
# directly with no Creo. No Creo calls anywhere in this file.
#
# ----------------------------------------------------------------------------
# WHAT the plan carries (Get-CurvedSlotPlan):
#   A SEED is one slot the operator draws by hand once, then (in per-hole mode)
#   every hole is its own seed, or (in per-row mode) one seed per shared-plane
#   row. Each seed names the SketchPlaneId its sketch is armed on by ID, the
#   HoleIds it covers, and the SlotWidth. A hole whose SketchPlaneId is missing
#   (0/null) is still planned but recorded in Warnings so the caller knows to
#   fall back to a manual screen-pick for that ONE seed - it never invalidates
#   the whole plan.
#
# MODES:
#   'per-hole' (DEFAULT, the MVP) - ONE seed per hole. Robust on a curved panel:
#     each seed's sketch is armed on THAT hole's own plane, so differing bore
#     normals never matter. Count = hole count.
#   'per-row'  - group holes by RowKey (string equality) or, absent RowKey, by a
#     projected coordinate within a PHYSICAL tolerance (Group-CurvedHolesByRow).
#     ONE seed per row, on the row's SHARED plane -> fewer cuts when a whole row
#     is coplanar. A row whose holes disagree on SketchPlaneId gets a Warning and
#     the FIRST usable plane in the row is used.
#
# CONVENTION (matches orthogrid.ps1 / curved_jig.ps1 / creo_geometry.ps1): a
# function that COMPUTES never throws - invalid input returns a result object
# with Valid=$false and Errors populated. A trap from a math helper would kill
# the whole run. COM-array trap: build each vector component on its OWN line,
# never inside a comma-separated @(math,math,math) literal (there is no vector
# math here, but the rule is honored for any coordinate touched). global: scope
# on every function so closures resolve them under the hybrid .cmd
# scriptblock::Create model. Physical row-grouping tolerance is NEVER 1e-6 (a
# float-equality guard would silently fragment a near-but-not-equal row); it is
# max(SlotWidth/4, 0.01)-style, exactly like Get-RowSlots.
# ============================================================================

# ----------------------------------------------------------------------------
# CS-ReadDouble - null-safe [double] read of a member. [double]$null silently
# yields 0.0, so a MISSING member would sneak in as 0; an explicit null check
# before coercion keeps a legit 0 (member present) but skips a missing/garbage
# member (returns $null). Never throws.
# ----------------------------------------------------------------------------
function global:CS-ReadDouble {
    param($Value)
    $out = $null
    try { if ($null -ne $Value) { $out = [double]$Value } } catch { $out = $null }
    return $out
}

# ----------------------------------------------------------------------------
# CS-ReadPlaneId - read a hole's SketchPlaneId as a POSITIVE int, else 0.
# A usable Creo feature id is a positive int; 0/null/negative/garbage -> 0
# (meaning "no usable plane", the fall-back-to-pick signal). Never throws.
# ----------------------------------------------------------------------------
function global:CS-ReadPlaneId {
    param($Value)
    $id = 0
    try { if ($null -ne $Value) { $id = [int]$Value } } catch { $id = 0 }
    if ($id -lt 0) { $id = 0 }
    return $id
}

# ----------------------------------------------------------------------------
# CS-ReadHoleId - read a hole's Id as-is (string or int both fine); never throws.
# Returns $null when absent. Used only for the HoleIds membership list.
# ----------------------------------------------------------------------------
function global:CS-ReadHoleId {
    param($Value)
    $id = $null
    try { if ($null -ne $Value) { $id = $Value } } catch { $id = $null }
    return $id
}

# ----------------------------------------------------------------------------
# CS-CleanHoles - normalise the -Holes input into a list of clean records:
#   { Id; PlaneId (>0 or 0); RowKey (string or $null); ProjCoord (double or $null);
#     Index (input ordinal) }
# Malformed/non-record entries are SKIPPED (never throw). ProjCoord is a scalar
# used for coordinate row-grouping when RowKey is absent - it is taken from the
# hole's Pos (the along-cross coordinate the caller wants rows to split on). We
# use Pos[0] (the OG X) as the projection scalar by default, because on the
# curved panel the flat-analog "cross coordinate" is the position along one OG
# axis; a caller wanting a different axis supplies RowKey directly.
# ----------------------------------------------------------------------------
function global:CS-CleanHoles {
    param($Holes)
    # Return the array PLAINLY (no `,@()` comma-wrap) and let callers force array
    # context with @(). The comma-wrap idiom, combined with a param-bound @(...)
    # call site, double-nests a multi-element result into a 1-element array-of-
    # array (caught live: `$c.PlaneId` then member-enumerates to Object[] and the
    # [int] cast throws). Plain return + caller @() is correct for 0/1/N elements.
    $out = @()
    if ($null -eq $Holes) { return $out }
    $i = 0
    foreach ($h in $Holes) {
        if ($null -eq $h) { $i++; continue }

        $id = $null
        try { $id = CS-ReadHoleId $h.Id } catch { $id = $null }

        $planeId = 0
        try { $planeId = CS-ReadPlaneId $h.SketchPlaneId } catch { $planeId = 0 }

        # RowKey as a trimmed string when present (string equality grouping).
        $rowKey = $null
        try {
            if ($null -ne $h.RowKey -and ("$($h.RowKey)").Trim().Length -gt 0) {
                $rowKey = ("$($h.RowKey)").Trim()
            }
        } catch { $rowKey = $null }

        # Projection scalar from Pos[0] (OG X), null-safe. Absent Pos -> $null.
        $proj = $null
        try {
            $pos = $h.Pos
            if ($null -ne $pos) {
                $c0 = $null
                try { if ($null -ne $pos[0]) { $c0 = [double]$pos[0] } } catch { $c0 = $null }
                $proj = $c0
            }
        } catch { $proj = $null }

        $out += [pscustomobject]@{
            Id        = $id
            PlaneId   = [int]$planeId
            RowKey    = $rowKey
            ProjCoord = $proj
            Index     = [int]$i
        }
        $i++
    }
    return $out
}

# ============================================================================
# Group-CurvedHolesByRow - group per-hole records into ROWS. Rows are formed by
# RowKey STRING EQUALITY when every hole carries a RowKey; otherwise holes are
# grouped by their projected coordinate within a PHYSICAL -Tol (single-linkage
# on the sorted coordinate, exactly like Get-RowSlots - NEVER 1e-6).
#
# PARAMETERS:
#   -Holes  array of @{ Id; Pos=@(x,y,z); Axis=@(x,y,z); RowKey; SketchPlaneId }.
#           RowKey and Pos are BOTH optional per hole; a hole with neither cannot
#           be coordinate-grouped and lands in its OWN singleton row (never lost).
#   -Tol    physical grouping distance for the coordinate fallback. Default 0
#           => auto = max(SlotWidth/4, 0.01)-style; here SlotWidth is unknown so
#           the auto floor is 0.01 (a physical distance, NEVER 1e-6).
#
# Returns [pscustomobject]:
#   Valid  [bool]     $true when at least one hole was usable
#   Errors [string[]]
#   Rows   array of @{ Key; HoleIds=@(); Members=@() } - Members are the clean
#          per-hole records; HoleIds is the list of .Id (may contain $null for a
#          hole with no Id). Key is the RowKey (string mode) or a synthesized
#          "row<n>" label (coordinate mode / singleton).
# NEVER throws; empty/malformed Holes => Valid=$false + Errors + Rows=@().
# ============================================================================
function global:Group-CurvedHolesByRow {
    param(
        $Holes,
        [double]$Tol = 0.0
    )
    $errors = @()

    $clean = @(CS-CleanHoles $Holes)
    if ($clean.Count -lt 1) {
        return [pscustomobject]@{
            Valid  = $false
            Errors = @("need at least one usable hole record (got none)")
            Rows   = @()
        }
    }

    # physical grouping tolerance (NEVER 1e-6): a caller-supplied positive Tol
    # wins, else the 0.01 floor (SlotWidth is unknown at grouping time).
    $tolEff = if ($Tol -gt 0) { $Tol } else { 0.01 }

    # RowKey string-equality mode applies ONLY when EVERY hole carries a RowKey;
    # a partial mix falls back to coordinate grouping so nothing is silently split
    # on an inconsistent signal.
    $allKeyed = $true
    foreach ($c in $clean) { if ($null -eq $c.RowKey) { $allKeyed = $false; break } }

    $rows = @()

    if ($allKeyed) {
        # group by exact RowKey string; preserve first-seen key order.
        $order = @()
        $byKey = @{}
        foreach ($c in $clean) {
            $k = [string]$c.RowKey
            if (-not $byKey.ContainsKey($k)) { $byKey[$k] = @(); $order += $k }
            $byKey[$k] += $c
        }
        foreach ($k in $order) {
            $members = @($byKey[$k])
            $rows += [pscustomobject]@{
                Key     = [string]$k
                HoleIds = @($members | ForEach-Object { $_.Id })
                Members = $members
            }
        }
    } else {
        # coordinate single-linkage on ProjCoord. Holes with NO ProjCoord cannot
        # be placed on the axis -> each becomes its own singleton row (never lost).
        $withCoord = @($clean | Where-Object { $null -ne $_.ProjCoord })
        $noCoord   = @($clean | Where-Object { $null -eq $_.ProjCoord })

        $groups = @()
        if ($withCoord.Count -ge 1) {
            $sorted = @($withCoord | Sort-Object ProjCoord)
            $cur = @()
            $prev = $null
            foreach ($c in $sorted) {
                if ($cur.Count -eq 0) { $cur = @($c); $prev = [double]$c.ProjCoord; continue }
                if ([math]::Abs([double]$c.ProjCoord - $prev) -gt $tolEff) {
                    $groups += ,@($cur)
                    $cur = @($c)
                } else {
                    $cur += $c
                }
                $prev = [double]$c.ProjCoord
            }
            if ($cur.Count -gt 0) { $groups += ,@($cur) }
        }

        $rn = 0
        foreach ($g in $groups) {
            $members = @($g)
            $rows += [pscustomobject]@{
                Key     = ("row{0}" -f $rn)
                HoleIds = @($members | ForEach-Object { $_.Id })
                Members = $members
            }
            $rn++
        }
        # each coordinate-less hole -> its own singleton row.
        foreach ($c in $noCoord) {
            $rows += [pscustomobject]@{
                Key     = ("row{0}" -f $rn)
                HoleIds = @($c.Id)
                Members = @($c)
            }
            $rn++
        }
    }

    return [pscustomobject]@{
        Valid  = $true
        Errors = $errors
        Rows   = @($rows)
    }
}

# ============================================================================
# Get-CurvedSlotPlan - plan the curved chip-relief slot loop from a per-hole
# layout. Produces a list of SEEDS the (later) drilljig3d slot stage arms by ID.
#
# PARAMETERS:
#   -Holes      array of @{ Id; Pos=@(x,y,z); Axis=@(x,y,z); RowKey; SketchPlaneId }.
#   -SlotWidth  [double] the drilled hole diameter (slot width). Echoed on each
#               seed for the (later) sketch/cut; a value <= 0 is a soft Warning
#               (the caller may not know it at plan time), not fatal.
#   -Mode       'per-hole' (default) | 'per-row'. See header MODES.
#
# Returns [pscustomobject]:
#   Valid    [bool]
#   Errors   [string[]]
#   Mode     [string]   the effective mode ('per-hole' | 'per-row')
#   Seeds    array of @{ Key; HoleIds=@(); SketchPlaneId; SlotWidth; Members }
#            - Key: seed label (hole Id / index in per-hole, row Key in per-row)
#            - HoleIds: the hole(s) this seed's slot covers
#            - SketchPlaneId: the datum plane the seed sketch is armed on BY ID
#              (0 => none usable; recorded in Warnings, caller falls back to pick)
#            - SlotWidth: echoed slot width
#            - Members: the clean per-hole record(s) behind this seed
#   Count    [int]      number of seeds
#   Warnings [string[]] holes/rows with no usable plane (fall back to a pick) +
#            a mixed-plane row note + a non-positive SlotWidth note.
# NEVER throws; empty/malformed Holes => Valid=$false + Errors.
# ============================================================================
function global:Get-CurvedSlotPlan {
    param(
        $Holes,
        [double]$SlotWidth = 0.0,
        [string]$Mode = 'per-hole'
    )
    $errors   = @()
    $warnings = @()

    # normalise Mode WITHOUT [ValidateSet] (which throws on a bad value).
    $modeEff = 'per-hole'
    try { $modeEff = ("$Mode").Trim().ToLower() } catch { $modeEff = 'per-hole' }
    if ($modeEff -ne 'per-hole' -and $modeEff -ne 'per-row') {
        $errors += "Mode must be 'per-hole' or 'per-row' (got '$Mode'); defaulting to 'per-hole'"
        $modeEff = 'per-hole'
    }

    if ($SlotWidth -le 0) {
        $warnings += "SlotWidth <= 0 ($SlotWidth) - the seed slot width is unknown at plan time; the caller must supply it before cutting"
    }

    $clean = @(CS-CleanHoles $Holes)
    if ($clean.Count -lt 1) {
        return [pscustomobject]@{
            Valid    = $false
            Errors   = @("need at least one usable hole record (got none)")
            Mode     = [string]$modeEff
            Seeds    = @()
            Count    = 0
            Warnings = $warnings
        }
    }

    $seeds = @()

    if ($modeEff -eq 'per-hole') {
        # ONE seed per hole. Each seed is armed on THAT hole's own plane by ID.
        foreach ($c in $clean) {
            # a readable, stable key: the hole Id when present, else its ordinal.
            $key = if ($null -ne $c.Id) { "$($c.Id)" } else { "hole$($c.Index)" }
            if ($c.PlaneId -le 0) {
                $warnings += "hole $key has no usable SketchPlaneId - fall back to a screen-pick for this seed"
            }
            $seeds += [pscustomobject]@{
                Key           = [string]$key
                HoleIds       = @($c.Id)
                SketchPlaneId = [int]$c.PlaneId
                SlotWidth     = [double]$SlotWidth
                Members       = @($c)
            }
        }
    } else {
        # per-row: group, then ONE seed per row on the row's shared plane.
        $grp = Group-CurvedHolesByRow -Holes $Holes -Tol ([math]::Max($SlotWidth / 4.0, 0.01))
        if ($null -eq $grp -or -not $grp.Valid) {
            $ge = @()
            if ($null -ne $grp) { $ge = $grp.Errors }
            return [pscustomobject]@{
                Valid    = $false
                Errors   = @("could not group holes into rows: " + (($ge) -join '; '))
                Mode     = [string]$modeEff
                Seeds    = @()
                Count    = 0
                Warnings = $warnings
            }
        }
        foreach ($row in $grp.Rows) {
            $members = @($row.Members)
            # the row's shared plane = the FIRST member with a usable PlaneId.
            $planeId = 0
            $planeIds = @()
            foreach ($m in $members) {
                if ($m.PlaneId -gt 0) {
                    if ($planeId -le 0) { $planeId = [int]$m.PlaneId }
                    $planeIds += [int]$m.PlaneId
                }
            }
            # distinct usable plane ids in the row (mixed-plane detection)
            $distinct = @($planeIds | Sort-Object -Unique)
            if ($distinct.Count -gt 1) {
                $warnings += "row '$($row.Key)' holes reference different sketch planes ($($distinct -join ',')) - using the first ($planeId); a curved row that is not coplanar may need per-hole mode"
            }
            if ($planeId -le 0) {
                $warnings += "row '$($row.Key)' has no usable SketchPlaneId - fall back to a screen-pick for this seed"
            }
            $seeds += [pscustomobject]@{
                Key           = [string]$row.Key
                HoleIds       = @($row.HoleIds)
                SketchPlaneId = [int]$planeId
                SlotWidth     = [double]$SlotWidth
                Members       = $members
            }
        }
    }

    $valid = ($errors.Count -eq 0)
    return [pscustomobject]@{
        Valid    = $valid
        Errors   = [string[]]$errors
        Mode     = [string]$modeEff
        Seeds    = @($seeds)
        Count    = [int]@($seeds).Count
        Warnings = [string[]]$warnings
    }
}

# ============================================================================
# Test-CurvedSlotPlan - a cheap deterministic SANITY GATE over a Get-CurvedSlotPlan
# result. Confirms the plan is armable: >= 1 seed, every seed has >= 1 hole, and
# every seed either names a usable SketchPlaneId OR was recorded in the plan's
# Warnings (so the caller knows to screen-pick that ONE seed). A plan whose seed
# has neither a plane nor a matching warning is a HOLE in the plan the caller
# could not act on - that is the only thing this gate refuses.
#
# PARAMETERS:
#   -Plan  a Get-CurvedSlotPlan result object.
#
# Returns [pscustomobject]:
#   Ok     [bool]      the plan is armable
#   Issues [string[]]  each thing that fails the gate
# NEVER throws; a $null / non-plan input => Ok=$false + an Issue.
# ============================================================================
function global:Test-CurvedSlotPlan {
    param($Plan)
    $issues = @()

    if ($null -eq $Plan) {
        return [pscustomobject]@{ Ok = $false; Issues = @("plan is null") }
    }

    # the plan itself must have computed cleanly.
    $planValid = $false
    try { $planValid = [bool]$Plan.Valid } catch { $planValid = $false }
    if (-not $planValid) {
        $pe = @()
        try { if ($null -ne $Plan.Errors) { $pe = @($Plan.Errors) } } catch { $pe = @() }
        $issues += ("plan is not Valid" + $(if ($pe.Count -gt 0) { ": " + ($pe -join '; ') } else { "" }))
    }

    $seeds = @()
    try { if ($null -ne $Plan.Seeds) { $seeds = @($Plan.Seeds) } } catch { $seeds = @() }
    if ($seeds.Count -lt 1) { $issues += "plan has no seeds" }

    # the plan's warnings text is the record that a seed's missing plane is a
    # known fall-back-to-pick, not an unactionable gap.
    $warnText = ""
    try { if ($null -ne $Plan.Warnings) { $warnText = (@($Plan.Warnings) -join "`n") } } catch { $warnText = "" }

    $si = 0
    foreach ($s in $seeds) {
        $key = "seed$si"
        try { if ($null -ne $s.Key) { $key = "$($s.Key)" } } catch {}

        # >= 1 hole
        $holeIds = @()
        try { if ($null -ne $s.HoleIds) { $holeIds = @($s.HoleIds) } } catch { $holeIds = @() }
        if ($holeIds.Count -lt 1) { $issues += "seed '$key' covers no holes" }

        # usable plane OR a recorded warning naming this seed's key
        $planeId = 0
        try { $planeId = [int]$s.SketchPlaneId } catch { $planeId = 0 }
        if ($planeId -le 0) {
            $mentioned = $false
            try { $mentioned = ($warnText -match [regex]::Escape($key)) } catch { $mentioned = $false }
            if (-not $mentioned) {
                $issues += "seed '$key' has no usable SketchPlaneId and no recorded fall-back warning (unactionable)"
            }
        }
        $si++
    }

    return [pscustomobject]@{
        Ok     = [bool]($issues.Count -eq 0)
        Issues = [string[]]$issues
    }
}
