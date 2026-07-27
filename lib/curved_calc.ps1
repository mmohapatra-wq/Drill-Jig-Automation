# ============================================================================
# lib\curved_calc.ps1 - curved-jig NORMALITY verification + QA calculations
# ============================================================================
# Pure MATH (no COM, no state, NEVER throws) that turns the PROVEN drilled-cylinder
# -axis read into a MEASURED answer to the load-bearing curved-jig question: "did the
# hole come out NORMAL to the surface?" -- the QA the tangent-plane / normal-to-surface
# approach exists to achieve. Analogous to the flat tool's blind-eval count gate: it
# converts the "orientation is a visual check" caveat into a deterministic gate using
# ONLY the proven read (a bore's cylinder axis IS the surface normal at that hole;
# fact cylinder-origin-transform-axes / Get-CylinderAxes). No live-unverified read
# (no Eval3DData) is needed -- you MEASURE each drilled bore's axis and compare it to
# the INTENDED normal (the tangent-plane normal, or the fastener axis for a
# fastener-driven jig).
#
# Dot-source AFTER lib\curved_jig.ps1 (this module reuses its global CJ-* vector
# helpers: CJ-Dot / CJ-Unit / CJ-ClampCos / CJ-IsVec3 -- NOT redefined here). Loadable
# in a plain host for the offline tests (lib\tests\run_curved_calc_tests.ps1).
#
# CONVENTION (matches curved_jig.ps1 / creo_geometry.ps1): a COMPUTE never throws --
# invalid input returns a result object with Valid=$false + Errors populated. Every
# function is `function global:` so a wizard/console closure resolves it. Vectors are
# @(x,y,z) double arrays.
#
# ANTI-PARALLEL: a bore drilled "the other way" (axis negated) is the SAME drilling
# line, so normality uses |cos| (the ABSOLUTE dot of the unit vectors). An off-normal
# angle is therefore always reported in [0,90] deg.
# ============================================================================

# ----------------------------------------------------------------------------
# Get-NormalityCheck - is a MEASURED bore axis aligned with an INTENDED normal?
#
# Inputs:
#   MeasuredAxis   [double[3]]  the drilled bore's axis DIRECTION (from Get-CylinderAxes
#                               .D -- proven-live; need not be unit).
#   IntendedNormal [double[3]]  the surface normal the hole SHOULD follow (the
#                               tangent-plane normal, or the fastener axis; need not be unit).
#   TolDeg         [double]     max allowed off-normal angle (default 5 deg).
#
# Returns [pscustomobject] (NEVER throws):
#   Valid        [bool]    inputs were usable 3-vectors of non-zero length
#   Errors       [string[]]
#   DotAbs       [double]  |cos(angle)| of the two unit vectors (1 = perfectly aligned)
#   OffNormalDeg [double]  the off-normal angle in [0,90] (0 = perfectly normal)
#   WithinTol    [bool]    OffNormalDeg <= TolDeg (the GATE)
#   TolDeg       [double]  echoed
# ----------------------------------------------------------------------------
function global:Get-NormalityCheck {
    param(
        $MeasuredAxis,
        $IntendedNormal,
        [double]$TolDeg = 5.0
    )
    $errors = @()
    if (-not (CJ-IsVec3 $MeasuredAxis))   { $errors += "MeasuredAxis must be a 3-component vector" }
    if (-not (CJ-IsVec3 $IntendedNormal)) { $errors += "IntendedNormal must be a 3-component vector" }
    if ($TolDeg -lt 0) { $errors += "TolDeg must be >= 0" }
    if ($errors.Count -gt 0) {
        return [pscustomobject]@{ Valid=$false; Errors=$errors; DotAbs=$null; OffNormalDeg=$null; WithinTol=$false; TolDeg=$TolDeg }
    }
    $uA = CJ-Unit $MeasuredAxis
    $uN = CJ-Unit $IntendedNormal
    if ($null -eq $uA) { $errors += "MeasuredAxis is degenerate (zero-length)" }
    if ($null -eq $uN) { $errors += "IntendedNormal is degenerate (zero-length)" }
    if ($errors.Count -gt 0) {
        return [pscustomobject]@{ Valid=$false; Errors=$errors; DotAbs=$null; OffNormalDeg=$null; WithinTol=$false; TolDeg=$TolDeg }
    }
    # |cos| -> anti-parallel (bore drilled the other way) counts as aligned.
    $dotAbs = [math]::Abs([double](CJ-Dot $uA $uN))
    $dotAbs = CJ-ClampCos $dotAbs
    $offDeg = [math]::Acos($dotAbs) * 180.0 / [math]::PI
    return [pscustomobject]@{
        Valid        = $true
        Errors       = @()
        DotAbs       = [double]$dotAbs
        OffNormalDeg = [double]$offDeg
        WithinTol    = [bool]($offDeg -le $TolDeg)
        TolDeg       = [double]$TolDeg
    }
}

# ----------------------------------------------------------------------------
# Get-CurvedHoleQaReport - per-hole normality QA over a drilled curved jig.
#
# Each hole record carries the MEASURED bore axis (Get-CylinderAxes .D, post-drill)
# and the INTENDED normal (the tangent-plane normal or fastener axis captured at
# placement). A hole with a missing/degenerate vector is flagged (Ok=$false + a
# Reason) but does NOT abort the report (never throws). Optional Pos + Id/Key are
# carried through for the CSV / manufacturing handoff.
#
# Inputs:
#   Holes  array of @{ Id?; Key?; MeasuredAxis=@(x,y,z); IntendedNormal=@(x,y,z); Pos? }
#   TolDeg [double] off-normal tolerance (default 5 deg), passed to Get-NormalityCheck.
#
# Returns [pscustomobject] (NEVER throws):
#   Valid          [bool]     at least one hole was checkable
#   Errors         [string[]]
#   Rows           [array]    per-hole @{ Id; Key; OffNormalDeg; WithinTol; DotAbs; Ok; Reason; Pos }
#   Count          [int]      total holes
#   Checked        [int]      holes with a usable pair of vectors
#   WithinTol      [int]      holes whose bore is within TolDeg of normal
#   MaxOffNormalDeg[double]   worst off-normal angle among checked holes (0 if none)
#   AllWithinTol   [bool]     every CHECKED hole is within tol AND >=1 was checked
#   TolDeg         [double]   echoed
# ----------------------------------------------------------------------------
function global:Get-CurvedHoleQaReport {
    param(
        $Holes,
        [double]$TolDeg = 5.0
    )
    $rows = @()
    $errors = @()
    $count = 0; $checked = 0; $within = 0; $maxOff = 0.0

    if ($null -eq $Holes) {
        return [pscustomobject]@{ Valid=$false; Errors=@("no holes to check"); Rows=@(); Count=0; Checked=0; WithinTol=0; MaxOffNormalDeg=0.0; AllWithinTol=$false; TolDeg=$TolDeg }
    }

    $idx = 0
    foreach ($h in $Holes) {
        $idx++
        $count++
        if ($null -eq $h) {
            $rows += [pscustomobject]@{ Id=$null; Key="hole$idx"; OffNormalDeg=$null; WithinTol=$false; DotAbs=$null; Ok=$false; Reason='null hole record'; Pos=$null }
            continue
        }
        $id  = $null; try { $id  = $h.Id }  catch {}
        $key = $null; try { $key = $h.Key } catch {}
        if ($null -eq $key) { $key = if ($null -ne $id) { "$id" } else { "hole$idx" } }
        $pos = $null; try { $pos = $h.Pos } catch {}

        $ma = $null; $inrm = $null
        try { $ma   = $h.MeasuredAxis }   catch {}
        try { $inrm = $h.IntendedNormal } catch {}

        $nc = Get-NormalityCheck -MeasuredAxis $ma -IntendedNormal $inrm -TolDeg $TolDeg
        if (-not $nc.Valid) {
            $reason = ($nc.Errors -join '; ')
            $rows += [pscustomobject]@{ Id=$id; Key=[string]$key; OffNormalDeg=$null; WithinTol=$false; DotAbs=$null; Ok=$false; Reason=$reason; Pos=$pos }
            continue
        }
        $checked++
        if ($nc.WithinTol) { $within++ }
        if ($nc.OffNormalDeg -gt $maxOff) { $maxOff = [double]$nc.OffNormalDeg }
        $rows += [pscustomobject]@{
            Id=$id; Key=[string]$key; OffNormalDeg=[double]$nc.OffNormalDeg; WithinTol=[bool]$nc.WithinTol;
            DotAbs=[double]$nc.DotAbs; Ok=$true; Reason=''; Pos=$pos
        }
    }

    return [pscustomobject]@{
        Valid           = [bool]($checked -ge 1)
        Errors          = [string[]]$errors
        Rows            = @($rows)
        Count           = [int]$count
        Checked         = [int]$checked
        WithinTol       = [int]$within
        MaxOffNormalDeg = [double]$maxOff
        AllWithinTol    = [bool](($checked -ge 1) -and ($within -eq $checked))
        TolDeg          = [double]$TolDeg
    }
}
