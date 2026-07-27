# ============================================================================
# lib\tangent_plane.ps1 - tangent-plane macro + orchestration (CURVED jig)
# ============================================================================
# THE CURVED-JIG LINCHPIN (user 2026-07-24; recording in
# docs\tangent_plane_at_point_on_surface.mapkey.txt, fact
# tangent-plane-at-point-on-surface):
#
#   A datum plane constrained TANGENT to a curved SURFACE AT a datum POINT
#   touches the surface at that point -- so its NORMAL IS the surface normal
#   there. That single feature gives, per hole:
#     (a) a genuine normal-to-surface reference for DRILLING (the hole goes
#         THROUGH the curved blank normal to the face, not sunk ON the surface);
#     (b) the ideal seed-sketch HOST for the chip-relief slot (arm the seed
#         rectangle sketch on this tangent plane BY ID -- sketch-open-on-plane-
#         by-id, proven live 2026-07-24).
#
#   This REPLACES the old surface-pre-select orientation HYPOTHESIS (drilljig3d
#   STAGE 2's buffered-surface normal reference) as the PRIMARY per-hole
#   normal-plane strategy; the offset-plane reuse remains the fallback.
#
# CHANNEL: the references (curved SURFACE + datum POINT) are fed BY ID and
# ACCUMULATED into the selection buffer BEFORE ProCmdDatumPlane -- the SAME
# channel proven for the 3-plane intersection point
# (point-at-3-plane-intersection-by-id) and the intersection csys
# (csys-at-3-plane-intersection). The Tangent constraint applies to the SURFACE
# ref; the POINT ref is the through-point. The load-bearing tokens (from the
# recording) are: ProCmdDatumPlane + constr_type1_OPTMENU1 = Tangent + stdbtn_1.
#
# LIVE-UNVERIFIED for THIS command: the by-ID reference feed into
# ProCmdDatumPlane and the exact surface/point ref order are NOT yet confirmed
# live for the Tangent constraint -- a tangent-plane-probe must settle them
# (select surface + point by ID, fire the sequence, feature-diff canary that a
# NEW datum plane appears + a visual tangency check). Hence -SurfaceFirst is a
# switch (flip the ref order if the probe shows the point must go first), and
# Invoke-TangentPlane is CANARY-GATED: a no-change VersionStamp is a MISS, never
# an assumed success ([[feedback_canary_must_not_assume_on_failure]]).
#
# CONVENTIONS honored here (repo house style):
#   * PURE math/string builders NEVER touch COM and NEVER throw.
#   * COM orchestration reads the ONE-TIME scope set by Initialize-DrilljigCore
#     ($script:DJSession / $script:DJModel / $script:DJType) instead of threading
#     the session/model/type through every call -- mirrors Invoke-VerifiedSeedCut
#     / Select-FeatureById in lib\drilljig_core.ps1.
#   * ONE atomic RunMacro per dashboard (a dialog's command context does not
#     survive across separate RunMacro calls).
#   * ID-only: NEVER reads IpfcPoint.Point (it crashes on this build).
#   * Get-SelectSurfaceByIdMacro / Get-SelectPointByIdMacro come from
#     lib\drilljig_core.ps1 (dot-source scope) -- they are NOT redefined here.
#   * Library functions are declared `function global:` so they resolve from
#     WinForms .GetNewClosure() handlers (a closure module can only see globals).
#
# DEPENDS ON (dot-source FIRST, exactly as the console/GUI tools do):
#   lib\creo_geometry.ps1  (base geometry reads)
#   lib\drilljig_core.ps1  (Get-SelectByIdMacro, Initialize-DrilljigCore,
#                           Wait-ModelModified, Get-FeatureIdSet)
# ============================================================================

# ----------------------------------------------------------------------------
# 1. Build-TangentPlaneMacro  (PURE string builder -- no COM, never throws)
# ----------------------------------------------------------------------------
# Return the ONE atomic macro that:
#   (1) selects the curved SURFACE (as Surface GEOMETRY) + the datum POINT (as
#       Point) by ID, ACCUMULATED (first ref clears the buffer; the second uses
#       -NoClear). The surface MUST go in as Surface, NOT Feature: trail proof
#       2026-07-27 (trail.txt.11) showed a Feature-typed face gives
#       ProCmdDatumPlane no tangent-able reference, so the `Tangent` option never
#       appears (menu logged index 0) and the dialog cancels (0 new features);
#   (2) fires ProCmdDatumPlane (consumes the two buffered refs);
#   (3) sets the constraint TYPE menu to Tangent (constr_type1_OPTMENU1);
#   (4) confirms with stdbtn_1 (OK).
#
# The backtick-quoted tokens are copied VERBATIM from
# docs\tangent_plane_at_point_on_surface.mapkey.txt (script-usable sequence):
#   ~ Command `ProCmdDatumPlane`;
#   ~ Open  `Odui_Dlg_00` `constr_type1_OPTMENU1`;
#   ~ Close `Odui_Dlg_00` `constr_type1_OPTMENU1`;
#   ~ Select `Odui_Dlg_00` `constr_type1_OPTMENU1` 1 `Tangent`;
#   ~ Activate `Odui_Dlg_00` `stdbtn_1`;
#
# -SurfaceFirst (default $true): SURFACE selected first, then the POINT. Flip to
# $false to select the POINT first (the probe settles which order Creo accepts;
# a wrong order simply means the tangent constraint has nothing to bind, caught
# by the Invoke-TangentPlane canary -- it can never build the wrong plane
# silently, only fail to build one).
function global:Build-TangentPlaneMacro {
    param(
        [int]$PointId,
        [int]$SurfaceId,
        [bool]$SurfaceFirst = $true
    )
    # Accumulate the two references by ID. The surface goes in as SURFACE
    # geometry (Get-SelectSurfaceByIdMacro) and the point as POINT
    # (Get-SelectPointByIdMacro) -- NOT as Feature: a Feature-typed face is not a
    # tangent-able reference (see the docstring / trail.txt.11). The FIRST call
    # clears the buffer; the SECOND uses -NoClear so it accumulates (does not
    # replace) -- the proven multi-ref accumulate channel.
    if ($SurfaceFirst) {
        $sel = (Get-SelectSurfaceByIdMacro -FeatId $SurfaceId) +
               (Get-SelectPointByIdMacro   -FeatId $PointId -NoClear)
    } else {
        $sel = (Get-SelectPointByIdMacro   -FeatId $PointId) +
               (Get-SelectSurfaceByIdMacro -FeatId $SurfaceId -NoClear)
    }
    return $sel +
        "~ Command ``ProCmdDatumPlane``;" +
        "~ Open  ``Odui_Dlg_00`` ``constr_type1_OPTMENU1``;" +
        "~ Close ``Odui_Dlg_00`` ``constr_type1_OPTMENU1``;" +
        "~ Select ``Odui_Dlg_00`` ``constr_type1_OPTMENU1`` 1 ``Tangent``;" +
        "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;"
}

# ----------------------------------------------------------------------------
# 2. Invoke-TangentPlane  (COM orchestration -- the primary per-hole plane build)
# ----------------------------------------------------------------------------
# Fire Build-TangentPlaneMacro and CANARY-GATE the result:
#   * snapshot the feature-id set (Get-FeatureIdSet) BEFORE,
#   * fire the macro,
#   * Wait-ModelModified on the VersionStamp,
#   * resolve the NEW plane feature id (the highest id that appears in the
#     after-set but not the before-set).
# Returns @{ Created = <bool>; PlaneId = <int|null>; Reason = <string> }.
#
# Created=$false whenever the model did not change (a MISS -- NEVER assume a
# plane was made just because the macro fired; [[feedback_canary_must_not_
# assume_on_failure]]). Also Created=$false + Reason WITHOUT firing when
# PointId<=0 or SurfaceId<=0 (bad input never touches Creo).
#
# Reads the core scope ($script:DJSession/DJModel/DJType) set by
# Initialize-DrilljigCore -- call that ONCE after connecting, exactly like
# Invoke-VerifiedSeedCut. -OnPoll is threaded to Wait-ModelModified (a GUI
# passes a DoEvents pump so the window repaints during the plane regen).
# Never throws (a macro/COM error is caught and returned as Created=$false).
function global:Invoke-TangentPlane {
    param(
        [int]$PointId,
        [int]$SurfaceId,
        [switch]$SurfaceFirst,
        [scriptblock]$OnPoll = $null,
        [int]$TimeoutMs = 30000
    )
    # -SurfaceFirst is a switch here (so callers can pass -SurfaceFirst:$false);
    # default to surface-first when unspecified, matching Build-TangentPlaneMacro.
    $surfFirst = $true
    if ($PSBoundParameters.ContainsKey('SurfaceFirst')) { $surfFirst = [bool]$SurfaceFirst }

    $res = @{ Created = $false; PlaneId = $null; Reason = '' }

    # Guard: never fire on bad input.
    if ($PointId -le 0)   { $res.Reason = 'point feature id was not captured (PointId <= 0)';   return $res }
    if ($SurfaceId -le 0) { $res.Reason = 'surface feature id was not captured (SurfaceId <= 0)'; return $res }

    # Snapshot BEFORE (so we can resolve the new plane by set diff) + the stamp.
    $before = Get-FeatureIdSet
    $stamp  = $null
    try { $stamp = $script:DJModel.VersionStamp } catch {}

    # Fire the ONE atomic macro.
    $macro = Build-TangentPlaneMacro -PointId ([int]$PointId) -SurfaceId ([int]$SurfaceId) -SurfaceFirst $surfFirst
    try {
        $script:DJSession.RunMacro($macro)
    } catch {
        $res.Reason = "tangent-plane macro error: $($_.Exception.Message)"
        return $res
    }

    # CANARY: a new datum plane must actually change the model. If the stamp is
    # unreadable, treat it as a MISS (never assume success on a can't-read signal).
    if ($null -eq $stamp) {
        $res.Reason = 'could not read the model VersionStamp before firing (canary unavailable) -- treating as a miss'
        return $res
    }
    if (-not (Wait-ModelModified -Model $script:DJModel -PreviousStamp $stamp -TimeoutMs $TimeoutMs -OnPoll $OnPoll)) {
        $res.Reason = 'model did not change -- no tangent plane created (the by-ID ref feed or the surface/point ref order may be wrong for ProCmdDatumPlane Tangent; try -SurfaceFirst:$false, or confirm with the tangent-plane-probe)'
        return $res
    }

    # Resolve the NEW plane feature id = highest id present after but not before.
    $after = Get-FeatureIdSet
    $newIds = @()
    foreach ($k in $after.Keys) { if (-not $before.ContainsKey($k)) { $newIds += [int]$k } }
    if ($newIds.Count -ge 1) {
        $res.Created = $true
        $res.PlaneId = [int](@($newIds | Sort-Object)[ -1 ])   # highest new id
        $res.Reason  = 'tangent plane created'
    } else {
        # The model changed but no NEW feature id surfaced (unexpected on this
        # build). Report it honestly rather than claiming a plane id we cannot
        # point to -- a caller that needs the id must treat this as a miss.
        $res.Reason = 'model changed but no new feature id was found -- cannot confirm the tangent plane id'
    }
    return $res
}
