# ============================================================================
# lib\curved_relief.ps1 - the CHIP-RELIEF engine for the CURVED drill jig: a
# SYMMETRIC remove-material EXTRUDE cut on each fastener's own TOP plane.
# ============================================================================
# The curved jig's chip-relief is cut in the terminal Slots stage, one pocket per
# fastener that was already drilled (the Slots stage reuses the fasteners selected in
# the Fasteners stage -- it does NOT re-ask). For each, Creo opens an extrude, the
# operator picks that fastener's TOP plane, draws ONE rectangle over the hole, and the
# tool fires a SYMMETRIC remove-material extrude whose typed depth is 2 x the relief
# (so the pocket straddles the TOP plane, relief-deep each way). To leave material for
# it, the conformal blank's thicken grows to wall + relief (handled in the Conditions
# chip-clearance step). This SUPERSEDES the retired tangent-plane per-hole slot loop
# (which gated on a TangentPlaneId the fastener loop never set -> always skipped).
#
# Dot-source AFTER lib\creo_geometry.ps1 + lib\drilljig_core.ps1 +
# lib\conformal_blank.ps1 + lib\curved_fastener_hole.ps1. It reuses:
#   - Get-FeatureIdSet / Wait-ModelModified (drilljig_core.ps1, read the core scope
#     set by Initialize-DrilljigCore) -- the cut canary.
# The TOP plane is picked by the OPERATOR on screen (an explicit step), NOT via a
# raw-COM pre-select: [[project_curved_relief_extrude_plane]] proved ProCmdFtExtrude
# REJECTS a path-qualified component-plane pre-select, so Select-ComponentPlaneById is
# NO LONGER used here (the earlier hands-free assumption was false).
# Every function is `function global:` so the wizard's slot-loop Add_Click
# .GetNewClosure() handler resolves it (the closure-scope rule -- a plain `function`
# is INVISIBLE to a closure body; [[project_gui_scope_bugs]]). PURE builders NEVER
# throw. ID-ONLY throughout -- never reads IpfcPoint.Point.
#
# PROVENANCE (operator trail recordings, C:\Users\<user>\working_folder\trail\):
#   * SYMMETRIC cut: trail.txt.15 (2026-07-27) L7457-7478 + L5267: open+close
#     `maindashInst0.depth_flyout` -> `maindashInst0.Symmetric 1` -> type
#     `def_depth1_ip` (the FULL pocket depth = 2 x relief) -> Enter/Exit
#     dashInst0.Quit blur -> remove_material_cb 1 -> body page -> dashInst0.Done.
#     Symmetric removes the direction ambiguity the flat/tangent slot loop needed
#     (no flip_pb, no operator direction-verify).
#   * SKETCH-ON-PLANE extrude open: trail.txt.18 (2026-07-28) L388-407 + L573:
#     ProCmdFtExtrude (open) -> [operator picks the sketch plane] -> ProCmdViewSketchView
#     -> ProCmdSketSlantRectangle 1 -> [operator draws] -> ProCmdSketDone.
#   The remove-material + body-select tail matches drilljig_core's proven
#   Build-CutFinishMacro (slotinator/pocketinator, confirmed live) VERBATIM -- but
#   this is a SEPARATE builder (a curved-specific one) so the shared, flat-tool
#   Build-CutFinishMacro's blind-depth+flip contract is NOT mutated.
#
# THE PLANE PICK IS MANDATORY (not hands-free): trail.txt.20 L935-963 proved
# ProCmdFtExtrude REJECTS a raw-COM path-qualified component-plane pre-select, and a
# component TOP plane is not tree-reachable from the active jig part -- so there is no
# reliable hands-free plane feed. Invoke-FastenerRelief opens the extrude, fires the
# operator -PlanePrompt (they Ctrl-click the TOP plane), THEN arms the rectangle on the
# now-open sketch. Splitting the arm this way is what fixed the "sketch opens then
# immediately extrudes without letting me draw" bug. [[project_curved_relief_extrude_plane]]
# ============================================================================

# ----------------------------------------------------------------------------
# Build-CurvedReliefOpenMacro - PURE. Just OPEN the extrude: ProCmdFtExtrude. The CALLER
# (Invoke-FastenerReliefArm) PRE-SELECTS this fastener's TOP plane into the buffer BEFORE
# firing this, so ProCmdFtExtrude opens with the TOP plane already chosen as its sketch plane
# and drops straight into the sketch -- the pre-select-then-fire pattern the HOLE proves (the
# hole pre-selects the point + this same TOP plane before ProCmdHole). If the pre-select could
# not stage (stale component path), the extrude instead enters its "select a sketch plane" wait
# and the operator clicks the TOP plane (Invoke-FastenerReliefArm's -PlanePrompt fallback). This
# macro stays a bare `ProCmdFtExtrude` either way (the plane is staged by a raw-COM COM call, not
# a macro token). Kept SEPARATE from the rectangle-arm macro so the rectangle tool arms on the
# NOW-OPEN sketch, never into a plane-wait/error state (the old one-shot open+view+rectangle macro
# fired the rectangle into the plane-reject error -> "Section is incomplete", trail.txt.20 L935-963;
# splitting the arm is the fix). See [[project_curved_relief_extrude_plane]].
# ----------------------------------------------------------------------------
function global:Build-CurvedReliefOpenMacro {
    return "~ Command ``ProCmdFtExtrude``;"
}

# ----------------------------------------------------------------------------
# Build-CurvedReliefRectMacro - PURE. Fires ONLY AFTER the operator has picked the
# sketch plane and Creo has opened the internal sketch: ProCmdViewSketchView (orient
# to the sketch plane) -> ProCmdSketSlantRectangle 1 (arm the SLANTED-rectangle tool so
# the operator can draw). Kept separate from the open macro so the rectangle tool arms on
# the NOW-OPEN sketch, not into the plane-wait error state.
# ----------------------------------------------------------------------------
function global:Build-CurvedReliefRectMacro {
    return "~ Command ``ProCmdViewSketchView``;" +
        "~ Command ``ProCmdSketSlantRectangle`` 1;"
}

# ----------------------------------------------------------------------------
# Build-CurvedReliefOpenByIdMacro - PURE. Open the relief extrude sketch HANDS-FREE
# on a JIG-PART datum plane fed BY FEATURE ID (no operator plane pick). Mirrors the
# PROVEN flat-jig Invoke-VerifiedSeedCut channel VERBATIM (drilljig_core.ps1: a FACE
# selected via Get-SelectByIdMacro THEN ProCmdFtExtrude -> the sketch opens on it and
# ProCmdSketSlantRectangle arms in ONE shot BECAUSE the plane is already in the buffer -- no
# plane-wait state to drop the rectangle tokens into). Get-SelectByIdMacro selects
# SelOptionRadio `Feature` (a jig-part TANGENT datum plane IS a tree-reachable feature),
# NOT Get-SelectDatumByIdMacro (that is the surfenator up-to-plane / ProCmdDatumSketCurve
# MRU-collector feed -- a different channel). $PlaneId<=0 returns "" (the caller gates on it
# and falls back to the split open->operator-pick->rect form).
#
# LIVE-UNVERIFIED for a DATUM PLANE: proven only for a FACE via this exact channel; no
# contrary evidence (the retired failure -- [[project_curved_relief_extrude_plane]] -- was
# a raw-COM PATH-QUALIFIED COMPONENT plane, a different case). The caller keeps the operator
# PlanePrompt fallback, so worst case == the split-macro behavior, no regression.
# ----------------------------------------------------------------------------
function global:Build-CurvedReliefOpenByIdMacro {
    param([int]$PlaneId)
    if ($PlaneId -le 0) { return "" }
    return (Get-SelectByIdMacro -FeatId ([int]$PlaneId)) +
        "~ Command ``ProCmdFtExtrude``;" +
        "~ Command ``ProCmdViewSketchView``;" +
        "~ Command ``ProCmdSketSlantRectangle`` 1;"
}

# ----------------------------------------------------------------------------
# Build-OffsetPlaneOnPreselectedMacro - PURE. Create a datum plane OFFSET from a plane
# ALREADY IN THE SELECTION BUFFER (the caller pre-selected it -- e.g. a fastener's SIDE
# or FRONT component plane via Select-ComponentPlaneById). This is New-OffsetPlane's
# ProCmdDatumPlane + t1.constr_dim1 tail (drilljig_core.ps1:993-997) WITHOUT the
# Get-SelectByIdMacro tree-search pre-select -- because a COMPONENT plane is not
# tree-reachable, it must be buffered by the raw-COM path-qualified channel first (the
# SAME channel that feeds ProCmdDatumPointGeneral to make the fastener datum point).
# PURE (string only); NEVER throws.
#
# LIVE-UNVERIFIED: whether ProCmdDatumPlane accepts a raw-COM buffered COMPONENT plane as
# its offset base (proven for ProCmdDatumPointGeneral; not yet for ProCmdDatumPlane). The
# guide-plane helper that fires this is BEST-EFFORT + canary-gated, so a rejection just
# means no guide plane (the relief still proceeds).
# ----------------------------------------------------------------------------
function global:Build-OffsetPlaneOnPreselectedMacro {
    param([double]$Offset = 0.0)
    return "~ Command ``ProCmdDatumPlane``;" +
        "~ Input  ``Odui_Dlg_00`` ``t1.constr_dim1`` ``$Offset``;" +
        "~ Update ``Odui_Dlg_00`` ``t1.constr_dim1`` ``$Offset``;" +
        "~ FocusOut ``Odui_Dlg_00`` ``t1.constr_dim1``;" +
        "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;"
}

# ----------------------------------------------------------------------------
# Build-CurvedReliefArmMacro - PURE. The open + orient + rectangle-arm tokens
# concatenated (open THEN view THEN rectangle), preserved as the composed form so the
# pure ORDER test (Extrude -> ViewSketchView -> Rectangle) still passes. The DRIVER no
# longer fires this as one macro (it fires Open, waits for the plane pick, then fires
# Rect); it stays for token/documentation parity.
# ----------------------------------------------------------------------------
function global:Build-CurvedReliefArmMacro {
    return (Build-CurvedReliefOpenMacro) + (Build-CurvedReliefRectMacro)
}

# ----------------------------------------------------------------------------
# Build-CurvedReliefCutMacro - PURE. The SYMMETRIC remove-material finish, fired
# AFTER the operator draws the rectangle. Token order VERBATIM from trail.txt.15:
#   ProCmdSketDone (finish the internal sketch holding the drawn rectangle)
#   -> open+close maindashInst0.depth_flyout (the recording opens the depth flyout
#      before toggling Symmetric)
#   -> maindashInst0.Symmetric 1 (SYMMETRIC = split the depth about the sketch plane)
#   -> type def_depth1_ip = $SymDepth (the FULL pocket depth; the caller passes
#      2 x relief so each side of the TOP plane gets `relief`)
#   -> Enter/Exit dashInst0.Quit (blur the depth field, matching Build-CutFinishMacro)
#   -> remove_material_cb 1 (turn the extrude into a CUT)
#   -> body page + body-select $BodyIndex (route the cut to the conformal blank body;
#      the exact block from drilljig_core Build-CutFinishMacro, proven live)
#   -> dashInst0.Done (commit).
#
#   -SymDepth   the FULL symmetric depth typed into def_depth1_ip == 2 x relief.
#               A value <= 0 emits NO depth tokens (Creo keeps its default) -- but
#               the driver never calls this with <=0 (it gates on ReliefDepth>0).
#   -BodyIndex  the conformal blank body index (from the Surface stage).
# PURE (string only); NEVER throws.
# ----------------------------------------------------------------------------
function global:Build-CurvedReliefCutMacro {
    param([double]$SymDepth = 0.0, [int]$BodyIndex = 0)
    $depthMacro = if ($SymDepth -gt 0) {
        "~ Input  ``main_dlg_cur`` ``maindashInst0.def_depth1_ip`` ``$SymDepth``;" +
        "~ Update ``main_dlg_cur`` ``maindashInst0.def_depth1_ip`` ``$SymDepth``;" +
        "~ Activate ``main_dlg_cur`` ``maindashInst0.def_depth1_ip``;" +
        "~ FocusOut ``main_dlg_cur`` ``maindashInst0.def_depth1_ip``;"
    } else { "" }
    return "~ Command ``ProCmdSketDone``;" +
        "~ Select ``main_dlg_cur`` ``maindashInst0.depth_flyout``;" +
        "~ Close  ``main_dlg_cur`` ``maindashInst0.depth_flyout``;" +
        "~ Activate ``main_dlg_cur`` ``maindashInst0.Symmetric`` 1;" +
        $depthMacro +
        "~ Enter ``main_dlg_cur`` ``dashInst0.Quit``;" +
        "~ Exit  ``main_dlg_cur`` ``dashInst0.Quit``;" +
        "~ Activate ``main_dlg_cur`` ``maindashInst0.remove_material_cb`` 1;" +
        "~ Activate ``main_dlg_cur`` ``chkbn.body_page.0`` 1;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ``$BodyIndex``;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ````;" +
        "~ Focus  ``body_page.1.0`` ``PH.bodyselectrepwdg_list``;" +
        "~ Select ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` 1 ``$BodyIndex``;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ````;" +
        "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"
}

# ----------------------------------------------------------------------------
# New-CurvedGuidePlanes - BEST-EFFORT hole-bounding guide planes. RETIRED FROM THE RELIEF
# FLOW (user 2026-07-29: "no need to create those reference planes for chip relief -- just
# open the sketch on the top plane immediately") -- Invoke-FastenerReliefArm NO LONGER calls
# this; the relief sketch opens on the TOP plane immediately. Kept as a pure, unit-tested
# helper (offline test 3g) in case hole-bounding snap planes are wanted again, but nothing
# in the live relief path invokes it.
# (Original intent, user 2026-07-29: "create planes that bound the hole so the user has easy
# snap in places".) Offsets a plane +/- (HoleDia/2 + Margin) from the fastener's own SIDE
# (feature id 3) and FRONT (id 5) datum planes -- those pass through the hole and are
# PERPENDICULAR to the TOP/sketch plane, so their offsets intersect the sketch plane
# along 4 lines forming a BOX around the hole (the corners are the operator's snap
# points). The SIDE/FRONT planes are COMPONENT planes (external refs), so each is
# buffered by the raw-COM path-qualified channel (Select-ComponentPlaneById -- the SAME
# channel that feeds ProCmdDatumPointGeneral) THEN offset via Build-OffsetPlaneOnPreselectedMacro.
#
# BEST-EFFORT + NEVER THROWS + NEVER BLOCKS the relief: every plane is canary-gated
# (a new feature + a VersionStamp move); a miss is skipped + logged, and the relief
# proceeds regardless. Returns @{ Ids = @(<created plane ids>) }.
#
# LIVE-UNVERIFIED: whether ProCmdDatumPlane accepts a raw-COM-buffered component plane
# as its offset base (proven for ProCmdDatumPointGeneral, not yet for ProCmdDatumPlane).
# If it is rejected the guide planes simply do not appear (logged) -- the relief still
# opens on the tangent plane / operator pick and the operator draws freehand.
# `function global:` so the slot-loop .GetNewClosure() Add_Click resolves it.
# ----------------------------------------------------------------------------
function global:New-CurvedGuidePlanes {
    param(
        $Session, $Model, $TypeObj, $ComponentPath,
        [double]$HoleDia = 0.5, [double]$Margin = 0.125,
        [scriptblock]$Log = $null, [scriptblock]$OnPoll = $null, [int]$TimeoutMs = 15000
    )
    $res = @{ Ids = @() }
    if ($null -eq $Session -or $null -eq $Model -or $null -eq $ComponentPath) { return $res }
    $hd = if ($HoleDia -gt 0) { [double]$HoleDia } else { 0.5 }
    $half = ($hd / 2.0) + [double]$Margin
    if ($half -le 0) { return $res }
    $ids = @()
    # SIDE=3, FRONT=5 are the fastener component's default datum planes perpendicular to TOP=1.
    foreach ($role in @(@{ Id = 3; Name = 'Side' }, @{ Id = 5; Name = 'Front' })) {
        foreach ($off in @($half, (-1.0 * $half))) {
            # 1) buffer the component plane (raw-COM path-qualified; default Clear = fresh base).
            $sel = $null
            try { $sel = Select-ComponentPlaneById -Session $Session -TypeObj $TypeObj -ComponentPath $ComponentPath -PlaneId ([int]$role.Id) -Role ([string]$role.Name) } catch { $sel = $null }
            if ($null -eq $sel -or -not $sel.Ok) {
                if ($null -ne $Log) { try { & $Log ("  guide plane ({0} {1:0.###}) skipped - could not buffer the component plane." -f $role.Name, $off) } catch {} }
                continue
            }
            # 2) fire the offset datum plane on the buffered base, canary-gated.
            $before = Get-FeatureIdSet
            $stamp = $null; try { $stamp = $Model.VersionStamp } catch {}
            try { $Session.RunMacro((Build-OffsetPlaneOnPreselectedMacro -Offset ([double]$off))) }
            catch { if ($null -ne $Log) { try { & $Log ("  guide plane ({0} {1:0.###}) macro error - skipped." -f $role.Name, $off) } catch {} }; continue }
            if ($null -eq $stamp) { continue }
            $changed = $false
            try { $changed = Wait-ModelModified -Model $Model -PreviousStamp $stamp -TimeoutMs $TimeoutMs -OnPoll $OnPoll } catch { $changed = $false }
            if (-not $changed) {
                if ($null -ne $Log) { try { & $Log ("  guide plane ({0} {1:0.###}) did not create (offset base likely rejected) - skipped." -f $role.Name, $off) } catch {} }
                continue
            }
            $after = Get-FeatureIdSet
            $new = @($after.Keys | Where-Object { -not $before.ContainsKey($_) } | Sort-Object)
            if ($new.Count -ge 1) { $ids += [int]$new[-1] }
        }
    }
    $res.Ids = @($ids)
    return $res
}

# ----------------------------------------------------------------------------
# Invoke-FastenerRelief - drive ONE fastener's chip-relief cut. The operator picks
# the fastener's TOP plane ON SCREEN (there is no hands-free plane feed -- see below),
# draws ONE rectangle, and the tool fires a SYMMETRIC remove-material extrude. CANARY-
# gated on a new feature + a VersionStamp move; NEVER tallies on a miss
# ([[feedback_canary_must_not_assume_on_failure]]). NEVER throws.
#
# PLANE FEED -- HANDS-FREE by-ID with an operator-pick FALLBACK (user 2026-07-29:
# "open the sketch in the top plane of one of the fasteners"). Per hole the drill loop
# already created a jig-part datum POINT (CurvedHolePairs[i].PointId). This driver
# builds a jig-part TANGENT plane AT that point (Invoke-TangentPlane; its normal IS the
# surface normal there = the jig's local top plane at the fastener) and opens the relief
# extrude ON it BY FEATURE ID -- the PROVEN Invoke-VerifiedSeedCut channel
# (Get-SelectByIdMacro -> ProCmdFtExtrude arms the sketch+rectangle in one shot because
# the plane is pre-selected). That is hands-free: no operator plane pick.
#
# FALLBACK (no regression): if PointId/SurfaceId are missing, or the tangent plane
# cannot be built (canary miss), or the by-id open is not desired, it reverts to the
# split open -> operator PlanePrompt pick -> rectangle-arm form. So worst case == the
# prior behavior. Both LIVE-UNVERIFIED bits (Invoke-TangentPlane building a plane;
# ProCmdFtExtrude accepting a jig-part datum plane by id) degrade cleanly to the pick.
# [[project_curved_relief_extrude_plane]] proved ProCmdFtExtrude REJECTS a raw-COM
# path-qualified COMPONENT plane pre-select -- but a jig-part TANGENT plane fed by
# tree-search Feature id is a DIFFERENT, proven-for-a-FACE channel.
#
# NO reference/guide planes (user 2026-07-29 "no need to create those reference planes for chip
# relief -- just open the sketch on the top plane immediately"): the arm pre-selects the TOP plane
# and opens the sketch straight away; nothing is offset around the hole.
#
# FLOW:
#   1. baseline canary snapshot (before the extrude) so the cut canary sees ONLY the extrude/cut.
#   2. PRE-SELECT the fastener TOP plane (Select-ComponentPlaneById id 1) -> ProCmdFtExtrude opens
#      with it as the sketch plane; ViaPlane=$true. If it cannot stage: open bare -> & $PlanePrompt
#      (operator picks) -> ViaPlane=$false. Then arm the rectangle.
#   3. & $DrawPrompt -- operator draws the rectangle (a pause).
#   4. RunMacro(Build-CurvedReliefCutMacro -SymDepth (2*$ReliefDepth) -BodyIndex).
#   5. canary: Wait-ModelModified + Get-FeatureIdSet diff (vs the step-1 baseline).
#
#   -ComponentPath the fastener's IpfcComponentPath (to pre-select its TOP plane id 1; may be $null).
#   -TopPlaneId    the fastener TOP plane feature id (constant 1 in every fastener).
#   -ReliefDepth   the operator's relief depth `r` (> 0; the driver doubles it: 2*r).
#   -BodyIndex     the conformal blank body index (the cut target).
#   -PlanePrompt   scriptblock: operator picks the sketch plane (fallback path only).
#   -DrawPrompt    scriptblock: pause for the operator to draw the rectangle.
#   -PointId/-SurfaceId/-HoleDia/-GuidePlanes accepted but UNUSED (tangent-plane + guide planes retired).
# Returns @{ Cut=<bool>; ViaPlane=<bool>; Reason=<string> }. -OnPoll pumps DoEvents.
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# Invoke-FastenerReliefArm - the ARM HALF: SNAPSHOT the cut canary baseline + OPEN the
# extrude sketch ON THE FASTENER'S OWN TOP PLANE (no guide planes -- opens immediately). The sketch
# MUST sit on the fastener's TOP datum plane (user 2026-07-29: "the sketch needs to be on
# each of the TOP plane of the fastener") -- so the OPERATOR picks that TOP plane on screen
# after the extrude opens. There is NO hands-free feed: ProCmdFtExtrude REJECTS a raw-COM
# path-qualified COMPONENT plane pre-select (trail.txt.20 L938), and a component plane is not
# tree-reachable by feature id, so a fabricated jig-part plane (a tangent plane) would sit on
# the WRONG plane. The PROVEN path (trail.txt.20 L950-954: operator tree-picks the TOP plane
# -> the sketch opens cleanly) is exactly this: open the extrude (plane-wait) -> operator picks
# the TOP plane -> arm the rectangle. See [[project_curved_relief_extrude_plane]].
#
# It does NOT draw and does NOT cut -- it leaves Creo's sketcher OPEN so the operator draws,
# then a SEPARATE step calls Invoke-FastenerReliefCut (the flat-DJ slot-a/slot-b split).
#
# HANDS-FREE TOP-PLANE PRE-SELECT (user 2026-07-29: "make it extrude first, within that extrude
# select the top plane"; and earlier "we use it as a reference already when creating the hole"):
# this fastener's OWN TOP plane (component feature id $TopPlaneId, default 1) is PRE-SELECTED into
# the buffer via the SAME raw-COM path-qualified channel the HOLE uses (Select-ComponentPlaneById
# + $ComponentPath) BEFORE ProCmdFtExtrude fires -- so the extrude opens with the TOP plane already
# chosen as its sketch plane and drops straight into the sketch. This is the pre-select-THEN-fire
# pattern the hole proves live (placed on the point + oriented to THIS plane, both pre-selected
# before ProCmdHole) and that ProCmdFtOffset uses. (v5 fed the plane AFTER the open, into the
# plane-wait collector -- that did NOT register; pre-selecting like the hole is the corrected order.)
# If the pre-select cannot stage (STALE $ComponentPath / name-verify miss), it FALLS BACK to the
# operator PlanePrompt (click the TOP plane in the open extrude) -- worst case == the proven manual
# pick, still landing on the TOP plane. LIVE-UNVERIFIED whether ProCmdFtExtrude accepts a raw-COM
# pre-selected COMPONENT plane as a SKETCH plane (proven for ProCmdHole orientation + ProCmdFtOffset
# surface; trail.txt.20 showed a rejection during the old one-shot-macro era -- re-test live).
#
# Returns @{ Armed=<bool>; ViaPlane=<bool> ($true = pre-select took, $false = operator pick);
# PlaneId=<int>; BaseFeat; BaseStamp; Reason }. BaseFeat/BaseStamp are captured right before the
# extrude opens (so the finish canary sees ONLY the extrude/cut). NEVER throws. -OnPoll pumps DoEvents.
# NO reference/guide planes are created (user 2026-07-29 "no need to create those reference planes
# for chip relief -- just open the sketch on the top plane immediately"). -PointId/-SurfaceId/
# -HoleDia/-GuidePlanes are accepted but UNUSED (tangent-plane auto + guide planes both retired).
# ----------------------------------------------------------------------------
function global:Invoke-FastenerReliefArm {
    param(
        $Session, $Model, $TypeObj,
        $ComponentPath = $null,
        [int]$PointId = 0, [int]$SurfaceId = 0, [double]$HoleDia = 0.0, [int]$TopPlaneId = 1,
        [switch]$GuidePlanes,
        [scriptblock]$PlanePrompt = $null,
        [scriptblock]$OnPoll = $null, [int]$TimeoutMs = 30000
    )
    $res = @{ Armed = $false; ViaPlane = $false; PlaneId = 0; BaseFeat = @{}; BaseStamp = $null; Reason = '' }
    if ($null -eq $Session -or $null -eq $Model) { $res.Reason = 'no live session/model'; return $res }

    # NO reference/guide planes are created (user 2026-07-29: "no need to create those reference
    # planes for chip relief -- just open the sketch on the top plane immediately"). The arm goes
    # straight to pre-selecting the TOP plane + opening the extrude.

    # 1) baseline canary snapshot (before the extrude opens) so the finish cut canary sees ONLY
    # the extrude/cut feature, nothing else.
    $res.BaseFeat = Get-FeatureIdSet
    try { $res.BaseStamp = $Model.VersionStamp } catch { $res.BaseStamp = $null }

    # 2) PRE-SELECT this fastener's TOP plane (feature id $TopPlaneId, default 1) via the SAME
    # raw-COM path-qualified channel the HOLE uses (Select-ComponentPlaneById + $ComponentPath),
    # staged into the buffer BEFORE ProCmdFtExtrude fires -- so the extrude opens with the TOP
    # plane already chosen as its sketch plane. This is the pre-select-THEN-fire pattern the hole
    # proves live (the hole is placed on the datum point AND oriented to THIS exact plane, both
    # pre-selected before ProCmdHole) and that ProCmdFtOffset uses (a pre-selected surface). "make
    # it extrude first, within that extrude select the top plane" (user 2026-07-29). Retry once
    # for a transient RCW hiccup. A STALE $ComponentPath (the handle can go stale across the run)
    # yields Ok=false -> $fed stays false -> the operator picks the plane in the extrude (step 5).
    $fed = $false
    if ($null -ne $ComponentPath -and $TopPlaneId -gt 0) {
        for ($attempt = 1; ($attempt -le 2) -and (-not $fed); $attempt++) {
            $pf = $null
            try { $pf = Select-ComponentPlaneById -Session $Session -TypeObj $TypeObj -ComponentPath $ComponentPath -PlaneId $TopPlaneId -Role 'Top' } catch { $pf = $null }
            if ($null -ne $pf -and $pf.Ok) { $fed = $true; $res.PlaneId = [int]$TopPlaneId }
            if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }
        }
    }
    $res.ViaPlane = [bool]$fed

    # 3) OPEN the extrude. With the TOP plane pre-selected (step 2) Creo takes it as the sketch
    # plane and drops straight into the internal sketch (no plane-wait) -- hands-free. If the
    # plane could NOT be staged (stale path / name miss) the extrude instead enters its
    # "select a sketch plane" wait, handled by the operator pick in step 4.
    try { $Session.RunMacro((Build-CurvedReliefOpenMacro)) }
    catch { $res.Reason = "open macro error: $($_.Exception.Message)"; return $res }
    if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }

    # 4) FALLBACK (only when the plane was NOT staged): the operator clicks the TOP plane in the
    # open extrude's plane-wait. When the pre-select DID stage, the sketch is already open ON the
    # TOP plane, so no pick is fired (avoids a stray second selection).
    if (-not $fed) {
        if ($null -ne $PlanePrompt) { try { & $PlanePrompt } catch {} }
        if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }
    }

    # 5) arm the rectangle tool ON the now-open sketch (orient to the sketch plane + rectangle).
    try { $Session.RunMacro((Build-CurvedReliefRectMacro)) }
    catch { $res.Reason = "rectangle-arm macro error: $($_.Exception.Message)"; return $res }

    $res.Armed = $true
    $res.Reason = if ($fed) { 'TOP plane pre-selected before the extrude (hands-free)' } else { 'TOP plane pre-select unavailable (stale path?) - operator picks it in the open extrude' }
    return $res
}

# ----------------------------------------------------------------------------
# Invoke-FastenerReliefCut - the FINISH HALF (steps 6-7): AFTER the operator has drawn
# the rectangle in the armed sketch, fire the SYMMETRIC remove-material cut
# (Build-CurvedReliefCutMacro, 2 x relief) and canary-gate it against the baseline the
# ARM captured ($BaseFeat/$BaseStamp). A null $BaseStamp is a MISS (never assumed). NEVER
# throws. Returns @{ Cut=<bool>; Reason=<string> }. -OnPoll pumps DoEvents.
# ----------------------------------------------------------------------------
function global:Invoke-FastenerReliefCut {
    param(
        $Session, $Model,
        [double]$SymDepth = 0.0, [int]$BodyIndex = 0,
        $BaseFeat = $null, $BaseStamp = $null,
        [scriptblock]$OnPoll = $null, [int]$TimeoutMs = 30000
    )
    # NewFeatId (added 2026-07-30, additive): the id of the cut's new extrude feature, so the
    # Slots stage can capture the SEED pocket for a radial/axis pattern (Invoke-CurvedReliefRadialPattern).
    # Existing callers read only .Cut/.Reason; this extra key never affects them.
    $res = @{ Cut = $false; Reason = ''; NewFeatId = 0 }
    if ($null -eq $Session -or $null -eq $Model) { $res.Reason = 'no live session/model'; return $res }
    if ($null -eq $BaseFeat) { $BaseFeat = @{} }

    # fire the symmetric remove-material cut (the caller passes SymDepth = 2 x relief).
    try { $Session.RunMacro((Build-CurvedReliefCutMacro -SymDepth ([double]$SymDepth) -BodyIndex ([int]$BodyIndex))) }
    catch { $res.Reason = "cut macro error: $($_.Exception.Message)"; return $res }

    # canary: a new feature must appear AND the VersionStamp must move (vs the ARM baseline).
    if ($null -eq $BaseStamp) { $res.Reason = 'no baseline VersionStamp from the arm - cut cannot be verified (treated as a miss)'; return $res }
    $changed = $false
    try { $changed = Wait-ModelModified -Model $Model -PreviousStamp $BaseStamp -TimeoutMs $TimeoutMs -OnPoll $OnPoll } catch { $changed = $false }
    if (-not $changed) {
        $res.Reason = 'the relief cut did not change the model (rectangle not a closed loop, plane not consumed, or widget drift)'
        return $res
    }
    $afterFeat = Get-FeatureIdSet
    $newFeats = @($afterFeat.Keys | Where-Object { -not $BaseFeat.ContainsKey($_) })
    if (@($newFeats).Count -ge 1) {
        $res.Cut = $true; $res.Reason = 'relief pocket cut (new feature + VersionStamp moved)'
        # highest new id = the just-committed extrude/cut feature (the seed for a pattern).
        try { $res.NewFeatId = [int](@($newFeats | Sort-Object)[-1]) } catch { $res.NewFeatId = 0 }
    }
    else { $res.Reason = 'VersionStamp moved but no new feature id resolved (treated as a miss)' }
    return $res
}

# ----------------------------------------------------------------------------
# Invoke-FastenerRelief - the SINGLE-SHOT wrapper (Arm -> operator draws -> Cut), kept
# for the console/one-shot path + the offline tests. The GUI Slots stage uses the two
# halves DIRECTLY across two wizard steps (slot-arm / slot-finish) so the operator draws
# between steps (flat-DJ parity); this wrapper interleaves them with the -DrawPrompt pause.
# Returns @{ Cut=<bool>; ViaPlane=<bool>; Reason=<string> }.
# ----------------------------------------------------------------------------
function global:Invoke-FastenerRelief {
    param(
        $Session, $Model, $TypeObj,
        $ComponentPath = $null, [int]$TopPlaneId = 1,
        [double]$ReliefDepth = 0.0, [int]$BodyIndex = 0,
        [int]$PointId = 0, [int]$SurfaceId = 0, [double]$HoleDia = 0.0,
        [switch]$GuidePlanes,
        [scriptblock]$DrawPrompt = $null,
        [scriptblock]$PlanePrompt = $null,
        [scriptblock]$OnPoll = $null, [int]$TimeoutMs = 30000
    )
    $res = @{ Cut = $false; ViaPlane = $false; Reason = '' }
    if ($null -eq $Session -or $null -eq $Model) { $res.Reason = 'no live session/model'; return $res }
    if ($ReliefDepth -le 0) { $res.Reason = 'relief depth <= 0 - nothing to cut'; return $res }

    $arm = Invoke-FastenerReliefArm -Session $Session -Model $Model -TypeObj $TypeObj -ComponentPath $ComponentPath `
            -PointId $PointId -SurfaceId $SurfaceId -HoleDia $HoleDia -GuidePlanes:$GuidePlanes -PlanePrompt $PlanePrompt -OnPoll $OnPoll -TimeoutMs $TimeoutMs
    $res.ViaPlane = [bool]$arm.ViaPlane
    if (-not $arm.Armed) { $res.Reason = "arm failed: $($arm.Reason)"; return $res }

    # operator draws the rectangle (a pause; its return is ignored).
    if ($null -ne $DrawPrompt) { try { & $DrawPrompt } catch {} }

    $symDepth = 2.0 * [double]$ReliefDepth
    $cut = Invoke-FastenerReliefCut -Session $Session -Model $Model -SymDepth $symDepth -BodyIndex $BodyIndex -BaseFeat $arm.BaseFeat -BaseStamp $arm.BaseStamp -OnPoll $OnPoll -TimeoutMs $TimeoutMs
    $res.Cut = [bool]$cut.Cut
    $res.Reason = $cut.Reason
    return $res
}

# ============================================================================
# RADIAL / AXIS PATTERN of a chip-relief pocket (2026-07-30) - replicate ONE seed
# pocket around the cylinder axis instead of drawing a rectangle at every fastener.
# The pure decision (can we pattern? count + angular increment + which fastener to
# seed on?) is Get-CurvedRadialPatternPlan (lib\curved_radial.ps1); THIS is the Creo
# side: the macro builders (transcribed VERBATIM from the operator's `axispattern`
# mapkey, 2026-07-30) + the driver.
#
# WHY RADIAL (not the linear pattern ruled out for curved): an AXIS pattern ROTATES
# each copy about the picked axis, so on a cylinder every copy lands normal to the
# surface at its new angular position - the re-orientation a linear pattern cannot do.
#
# THE AXIS IS OPERATOR-PICKED: the mapkey has a @PAUSE_FOR_SCREEN_PICK after arming
# the axis collector (a RunMacro cannot screen-pick), so the sequence SPLITS into an
# OPEN macro (open pattern -> type Axis -> arm the axis collector), then the operator
# picks the rotation axis (the cylinder axis / a datum axis), then a VALUES macro
# (count + angular increment + confirm). This is the SAME split-around-a-pick pattern
# as the box rough-rectangle draw and the proven LINEAR direction pattern.
#
# LIVE-UNVERIFIED (canary-gated + per-fastener fallback, so no regression): (1) the
# ui_pat_type ordinal (2 = Axis) + the ui_pat_axis_* widget names come from the ONE
# operator mapkey, not cross-checked in a trail; (2) whether a raw-COM-selected seed
# feature registers as the AXIS-pattern target (proven for ProCmdRound, LIVE-UNVERIFIED
# for a pattern - same standing as the flat jig's Invoke-SlotPatternFromSeed). The
# driver canary-gates on a VersionStamp move + a new feature; a miss falls back to the
# per-fastener slot loop. probes\radialpat-probe.cmd confirms the tokens live.
# See [[project_curved_radial_slot_pattern]].
# ============================================================================

# ----------------------------------------------------------------------------
# Build-RadialPatternOpenMacro - PURE. OPEN the axis pattern on the ALREADY-SELECTED
# seed (the driver raw-COM-selects it first): ProCmdPattern -> zero the default
# Dimension-pattern count fields -> switch ui_pat_type to item 2 (Axis) -> arm the
# axis reference collector (ui_pat_dim_1_array). Ends at the operator's axis PICK
# (the mapkey's @PAUSE_FOR_SCREEN_PICK) - the driver fires the operator pause / by-id
# feed AFTER this, then Build-RadialPatternValuesMacro. Tokens VERBATIM from the
# `axispattern` mapkey (2026-07-30). PURE (string only); NEVER throws.
# ----------------------------------------------------------------------------
function global:Build-RadialPatternOpenMacro {
    return "~ Command ``ProCmdPattern``;" +
        "~ Trigger ``main_dlg_cur`` ``maindashInst0.ui_pat_dim_1_num`` ``0``;" +
        "~ Trigger ``main_dlg_cur`` ``maindashInst0.ui_pat_dim_1_num`` ````;" +
        "~ Trigger ``main_dlg_cur`` ``maindashInst0.ui_pat_dim_2_num`` ``0``;" +
        "~ Trigger ``main_dlg_cur`` ``maindashInst0.ui_pat_dim_2_num`` ````;" +
        "~ FocusOut ``ui_pat_dim_panel.0.0`` ``PH.ui_pat_dim_1_array``;" +
        "~ Select ``main_dlg_cur`` ``maindashInst0.ui_pat_type``;" +
        "~ Close  ``main_dlg_cur`` ``maindashInst0.ui_pat_type``;" +
        "~ Activate ``main_dlg_cur`` ``2 ui_pat_type`` 1;" +
        "~ Trigger ``ui_pat_dim_panel.0.0`` ``PH.ui_pat_dim_1_array`` 2 ``DuMmY`` ``dimension``;" +
        "~ Trigger ``ui_pat_dim_panel.0.0`` ``PH.ui_pat_dim_1_array`` 2 ```` ````;"
}

# ----------------------------------------------------------------------------
# Build-RadialPatternValuesMacro - PURE. AFTER the operator has picked the rotation
# axis: set the axis-1 instance COUNT (ui_pat_axis_1_num_inst) + the angular INCREMENT
# in DEGREES (ui_pat_axis_1_incr) + zero the 2nd axis dim (ui_pat_axis_2_incr) + confirm
# (dashInst0.stdbtn_1). Idiom Input/Update/FocusOut per the `axispattern` mapkey. Count
# is the TOTAL instances (Creo counts the seed as instance 1), so the caller passes the
# fastener count N. IncrementDeg is the per-step angle. PURE; NEVER throws.
# ----------------------------------------------------------------------------
function global:Build-RadialPatternValuesMacro {
    param([int]$Count = 2, [double]$IncrementDeg = 0.0)
    return "~ Input  ``main_dlg_cur`` ``maindashInst0.ui_pat_axis_1_num_inst`` ``$Count``;" +
        "~ Update ``main_dlg_cur`` ``maindashInst0.ui_pat_axis_1_num_inst`` ``$Count``;" +
        "~ FocusOut ``main_dlg_cur`` ``maindashInst0.ui_pat_axis_1_num_inst``;" +
        "~ Input  ``main_dlg_cur`` ``maindashInst0.ui_pat_axis_1_incr`` ``$IncrementDeg``;" +
        "~ Update ``main_dlg_cur`` ``maindashInst0.ui_pat_axis_1_incr`` ``$IncrementDeg``;" +
        "~ FocusOut ``main_dlg_cur`` ``maindashInst0.ui_pat_axis_1_incr``;" +
        "~ Input  ``main_dlg_cur`` ``maindashInst0.ui_pat_axis_2_incr`` ``0``;" +
        "~ Update ``main_dlg_cur`` ``maindashInst0.ui_pat_axis_2_incr`` ``0``;" +
        "~ FocusOut ``main_dlg_cur`` ``maindashInst0.ui_pat_axis_2_incr``;" +
        "~ Activate ``main_dlg_cur`` ``dashInst0.stdbtn_1``;"
}

# ============================================================================
# ATOMIC axis-by-id pattern (the FIX for the live "opens but does nothing" no-op).
# ROOT CAUSE (workflow-confirmed 2026-07-31): the operator's `axispattern` mapkey works
# because Creo's native interpreter runs it as ONE continuous playback with an INTERNAL
# @PAUSE_FOR_SCREEN_PICK for the axis; the dashboard context survives the pause. The old
# driver fired it as THREE separate RunMacro calls (open -> operator axis dialog ->
# values+stdbtn_1), and a dashboard's command context does NOT survive across separate
# RunMacro calls -- the confirm landed in a dashboard Creo had dropped, so nothing was
# created. RunMacro CANNOT honor @PAUSE (creo_api_facts.json), so the only viable radial
# via RunMacro is a SINGLE atomic macro that feeds the rotation AXIS BY ID (no pick) --
# exactly how the flat slot pattern (Build-SlotPatternMacro) stays atomic by feeding its
# DIRECTION reference by id.
#
# TWO tokens are needed and were NEVER recorded (mine-don't-guess -- do NOT hand-write them):
#   * RadialAxisCollectorWidget - the widget to Activate to ARM the axis reference collector
#     (the axis analog of the flat pattern's ui_pat_dir_dir1). The operator's mapkey never
#     armed it -- it hit the screen-pick @PAUSE instead -- so no token exists.
#   * RadialAxisSelType - the ProCmdMdlTreeSearch SelOptionRadio value that selects a datum
#     AXIS by id (expected 'Axis', vs the proven 'Datum'/'Surface'/'Point').
# Both are recorded by probes\radialpat-probe.cmd Section B -> artifacts\radialpat_recipe.txt.
# GLOBAL (not script:) so a closure / global function reads the live value across dot-source
# scopes ([[project_gui_scope_bugs]]). Default $null => the builders return $null => the driver
# CANNOT fire a guessed token; it returns a probe-gated miss and the caller draws per-fastener.
# ============================================================================
if (-not (Test-Path variable:global:RadialAxisCollectorWidget)) { $global:RadialAxisCollectorWidget = $null }
if (-not (Test-Path variable:global:RadialAxisSelType))         { $global:RadialAxisSelType = $null }

# PURE. $true only when BOTH probe-recorded tokens are present. Until then the radial path
# is dark and the GUI stays per-fastener (honest -- the feature genuinely cannot work yet).
function global:Test-RadialPatternReady {
    return ((-not [string]::IsNullOrWhiteSpace([string]$global:RadialAxisCollectorWidget)) -and
            (-not [string]::IsNullOrWhiteSpace([string]$global:RadialAxisSelType)))
}

# PURE. Tree-search select-by-ID for a datum AXIS, mirroring Get-SelectDatumByIdMacro but with
# the AXIS SelOptionRadio value. NO leading buffer_clean (clearing mid-dashboard deactivates the
# open axis collector -- the surfenator open-collector rule). Returns $null until the SelOptionRadio
# value is recorded. NEVER throws.
function global:Get-SelectAxisByIdMacro {
    param([int]$FeatId)
    if ([string]::IsNullOrWhiteSpace([string]$global:RadialAxisSelType)) { return $null }
    return "~ Command ``ProCmdMdlTreeSearch``;" +
        "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``$($global:RadialAxisSelType)``;" +
        "~ Select ``selspecdlg0`` ``LookByOptionMenu`` 1 ``Feature``;" +
        "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
        "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$FeatId``;" +
        "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
        "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
        "~ Activate ``selspecdlg0`` ``CancelButton``;"
}

# PURE. The WHOLE axis pattern as ONE concatenated macro string (the shape of the proven flat
# Build-SlotPatternMacro): open+type=Axis (verbatim proven prefix) -> ARM the axis collector ->
# feed the axis BY ID -> count+increment+confirm (verbatim proven suffix). Returns $null unless
# BOTH tokens are recorded AND a positive axis feature id is supplied -- so it can never emit a
# guessed widget. NEVER throws.
function global:Build-RadialPatternAtomicMacro {
    param([int]$AxisFeatId, [int]$Count = 2, [double]$IncrementDeg = 0.0)
    if (-not (Test-RadialPatternReady)) { return $null }
    if ($AxisFeatId -le 0) { return $null }
    $feed = Get-SelectAxisByIdMacro -FeatId $AxisFeatId
    if ([string]::IsNullOrWhiteSpace([string]$feed)) { return $null }
    $armAxis = "~ Activate ``main_dlg_cur`` ``$($global:RadialAxisCollectorWidget)``;"
    return (Build-RadialPatternOpenMacro) + $armAxis + $feed + (Build-RadialPatternValuesMacro -Count $Count -IncrementDeg $IncrementDeg)
}

# ----------------------------------------------------------------------------
# Invoke-CurvedReliefRadialPattern - drive the axis pattern of the seed relief pocket.
# `function global:` (a Slots-stage OnNext calls it). NEVER throws. Flow:
#   1. baseline canary (Get-FeatureIdSet + VersionStamp).
#   2. RAW-COM select the seed feature by id (Get-ComSelectFactory + CreateModelItemSelection
#      + buffer.AddSelection - the edginator/Invoke-SlotPatternFromSeed channel; a tree-SEARCH
#      select does NOT register as a pattern target, FIX 1). Done INLINE via the global
#      Get-ComSelectFactory so there is no non-global dependency.
#   3. RunMacro(Build-RadialPatternOpenMacro) - open + type Axis + arm the axis collector.
#   4. AXIS: if -AxisFeatId > 0, feed it by id via Get-SelectDatumByIdMacro (HANDS-FREE,
#      EXPERIMENTAL - the datum-typed open-collector channel; off by default until a probe
#      confirms an axis pattern accepts it). Else fire -AxisPrompt (operator picks it).
#   5. RunMacro(Build-RadialPatternValuesMacro -Count -IncrementDeg) - values + confirm.
#   6. canary: VersionStamp moved AND >= 1 new feature -> Patterned; else a miss (caller
#      falls back to the per-fastener loop). NEVER assumes success on a no-change signal.
#
#   -SeedFeatId    the drawn seed pocket's feature id (from Invoke-FastenerReliefCut.NewFeatId).
#   -Count         TOTAL instances = fastener count N (Creo counts the seed as instance 1).
#   -IncrementDeg  per-step angle in degrees (Get-CurvedRadialPatternPlan.IncrementDeg).
#   -AxisFeatId    optional datum-axis feature id for the hands-free feed (default 0 = pick).
#   -AxisPrompt    scriptblock: operator picks the rotation axis in Creo (the fallback / default).
#   -UseLiveSelection  the operator has ALREADY selected the seed in the model tree (the PROVEN
#                  channel from the operator's mapkey: ProCmdPattern honors a TREE-clicked seed).
#                  When set, SKIP the raw-COM select entirely + do NOT clear the buffer -- fire
#                  ProCmdPattern directly on the live selection. This is the guaranteed fallback
#                  the caller uses after a hands-free (raw-COM) attempt misses, because whether a
#                  raw-COM-selected seed registers as the pattern TARGET is LIVE-UNVERIFIED (proven
#                  for ProCmdRound, not the pattern); the tree click is the recording's proven path.
# Returns @{ Patterned=<bool>; NewFeatures=<int>; ViaAxisId=<bool>; SeedSelected=<bool>; Reason }.
# ----------------------------------------------------------------------------
function global:Invoke-CurvedReliefRadialPattern {
    param(
        $Session, $Model, $TypeObj,
        [int]$SeedFeatId, [int]$Count, [double]$IncrementDeg,
        [int]$AxisFeatId = 0,
        [switch]$UseLiveSelection,
        [scriptblock]$AxisPrompt = $null,
        [scriptblock]$OnPoll = $null, [int]$TimeoutMs = 30000
    )
    $res = @{ Patterned = $false; NewFeatures = 0; ViaAxisId = $false; SeedSelected = $false; Reason = '' }
    if ($null -eq $Session -or $null -eq $Model) { $res.Reason = 'no live session/model'; return $res }
    if ((-not $UseLiveSelection) -and $SeedFeatId -le 0) { $res.Reason = 'no seed feature id (the first pocket cut was not captured)'; return $res }
    if ($Count -lt 2)        { $res.Reason = 'count < 2 - nothing to pattern'; return $res }
    if ($IncrementDeg -le 0) { $res.Reason = 'angular increment <= 0'; return $res }

    # GATE: the ONLY viable radial via RunMacro is the ATOMIC axis-by-id macro. RunMacro cannot
    # pause for an operator axis pick, and a dashboard's command context does not survive across
    # SEPARATE RunMacro calls -- so the old open->(operator picks axis)->values+stdbtn_1 split
    # silently dropped the confirm (the live "opens but does nothing" no-op, workflow-confirmed
    # 2026-07-31). We therefore require BOTH probe-recorded tokens AND a datum-axis feature id;
    # otherwise this is probe-gated and the caller falls back to the per-fastener draw. The old
    # split is NOT fired here (known-broken) -- it lives only in probes\radialpat-probe.cmd as the
    # T0 root-cause demonstration. -AxisPrompt is now legacy/unused (no operator pick in the atomic path).
    if (-not (Test-RadialPatternReady)) {
        $res.Reason = 'radial pattern probe-gated: the atomic axis-by-id recipe (axis-collector widget + datum-axis tree-search type) is not recorded yet -- run probes\radialpat-probe.cmd Section B; using per-fastener'
        return $res
    }
    if ($AxisFeatId -le 0) {
        $res.Reason = 'radial pattern needs a datum-axis feature id (RadialAxisFeatId); none available on this build yet -- using per-fastener'
        return $res
    }
    $atomicMacro = Build-RadialPatternAtomicMacro -AxisFeatId ([int]$AxisFeatId) -Count ([int]$Count) -IncrementDeg ([double]$IncrementDeg)
    if ([string]::IsNullOrWhiteSpace([string]$atomicMacro)) {
        $res.Reason = 'atomic radial macro unavailable (a probe-recorded token is missing) -- using per-fastener'
        return $res
    }

    # 1) baseline canary (before the pattern) so the diff sees ONLY the pattern feature.
    $before = Get-FeatureIdSet
    $stamp = $null; try { $stamp = $Model.VersionStamp } catch { $stamp = $null }

    # 2) SELECT the seed. -UseLiveSelection trusts the operator's tree click (the recording's
    # PROVEN channel -- do NOT clear the buffer). Else raw-COM select by id (hands-free; whether
    # this registers as the pattern TARGET is LIVE-UNVERIFIED, FIX 1 -- the caller retries with
    # -UseLiveSelection on a miss).
    if ($UseLiveSelection) {
        $res.SeedSelected = $true
    } else {
        $seedItem = $null
        try { if ($null -ne $TypeObj) { $seedItem = $Model.GetItemById($TypeObj.ITEM_FEATURE, [int]$SeedFeatId) } } catch { $seedItem = $null }
        if ($null -eq $seedItem) { $res.Reason = "seed feature id $SeedFeatId did not resolve"; return $res }
        $factory = Get-ComSelectFactory
        if ($null -eq $factory) { $res.Reason = 'CreateModelItemSelection factory unavailable on this build'; return $res }
        $buf = $null; try { $buf = $Session.CurrentSelectionBuffer() } catch { $buf = $null }
        if ($null -eq $buf) { $res.Reason = 'could not get the current selection buffer'; return $res }
        try { $buf.Clear() } catch {}
        $sel = $null; try { $sel = $factory.CreateModelItemSelection($seedItem, $null) } catch { $sel = $null }
        if ($null -eq $sel) { $res.Reason = 'CreateModelItemSelection returned null for the seed'; return $res }
        try { $buf.AddSelection($sel) } catch { $res.Reason = 'AddSelection failed for the seed'; return $res }
        $res.SeedSelected = $true
    }
    if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }

    # 3) fire the WHOLE pattern as ONE atomic RunMacro (open -> type=Axis -> arm the axis collector
    #    -> feed the rotation axis BY ID -> count + increment -> confirm). THE FIX: the confirm rides
    #    in the SAME RunMacro as the open, so the dashboard context can never be lost between calls.
    try { $Session.RunMacro($atomicMacro); $res.ViaAxisId = $true }
    catch { $res.Reason = "atomic pattern macro error: $($_.Exception.Message)"; return $res }
    if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }

    # 6) canary: VersionStamp move + a new feature (never assume success on a can't-read).
    if ($null -eq $stamp) { $res.Reason = 'no baseline VersionStamp - the pattern cannot be verified (treated as a miss)'; return $res }
    $changed = $false
    try { $changed = Wait-ModelModified -Model $Model -PreviousStamp $stamp -TimeoutMs $TimeoutMs -OnPoll $OnPoll } catch { $changed = $false }
    if (-not $changed) {
        $res.Reason = 'the pattern did not change the model (the seed may not register as a pattern target on this build, or the axis pick was invalid)'
        return $res
    }
    $after = Get-FeatureIdSet
    $newF = @($after.Keys | Where-Object { -not $before.ContainsKey($_) })
    $res.NewFeatures = @($newF).Count
    if (@($newF).Count -ge 1) { $res.Patterned = $true; $res.Reason = 'radial pattern created (VersionStamp moved + new feature)' }
    else { $res.Reason = 'VersionStamp moved but no new feature id resolved (treated as a miss)' }
    return $res
}
