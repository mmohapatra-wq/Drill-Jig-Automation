# ============================================================================
# lib\curved_relief.ps1 - the CHIP-RELIEF engine for the CURVED drill jig: a
# SYMMETRIC remove-material EXTRUDE cut on each fastener's own TOP plane.
# ============================================================================
# The curved jig's chip-relief is cut RIGHT AFTER each fastener hole is drilled,
# reusing that fastener's OWN TOP plane (component feature id 1 -- the same plane
# the hole was oriented to). Creo opens a sketch ON that TOP plane, the operator
# draws ONE rectangle over the hole, and the tool fires a SYMMETRIC remove-material
# extrude whose typed depth is 2 x the relief (so the pocket straddles the TOP
# plane, relief-deep each way). To leave material for it, the conformal blank's
# thicken grows to wall + relief (handled in the Surface stage). This SUPERSEDES the
# retired tangent-plane per-hole slot loop (which gated on a TangentPlaneId the
# fastener loop never set -> always skipped).
#
# Dot-source AFTER lib\creo_geometry.ps1 + lib\drilljig_core.ps1 +
# lib\conformal_blank.ps1 + lib\curved_fastener_hole.ps1. It reuses:
#   - Select-ComponentPlaneById / Get-ComSelectFactory (curved_fastener_hole.ps1) --
#     the RAW-COM path-qualified channel that pre-selects an EXTERNAL component plane
#     (the tree-search select-by-id in curved_slot_macros' Build-CurvedSlotArmMacro
#     CANNOT reach a fastener-component plane, so it is NOT reused here).
#   - Get-FeatureIdSet / Wait-ModelModified (drilljig_core.ps1, read the core scope
#     set by Initialize-DrilljigCore) -- the cut canary.
# Every function is `function global:` so the wizard's fastener-loop Add_Click
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
#     pre-select the plane -> ProCmdFtExtrude -> ProCmdViewSketchView ->
#     ProCmdSketRectangle 1 -> [operator draws] -> ProCmdSketDone.
#   The remove-material + body-select tail matches drilljig_core's proven
#   Build-CutFinishMacro (slotinator/pocketinator, confirmed live) VERBATIM -- but
#   this is a SEPARATE builder (a curved-specific one) so the shared, flat-tool
#   Build-CutFinishMacro's blind-depth+flip contract is NOT mutated.
#
# LIVE-UNVERIFIED (headless): that ProCmdFtExtrude auto-consumes a RAW-COM
# pre-selected plane as its sketch plane the way ProCmdHole/ProCmdFtOffset do
# (proven for those two, not yet for the extrude). Invoke-FastenerRelief injects a
# -PlanePrompt operator fallback ("Ctrl-click this fastener's TOP plane") + a cut
# canary, so worst case is one operator plane-click per fastener -- no regression.
# ============================================================================

# ----------------------------------------------------------------------------
# Build-CurvedReliefArmMacro - PURE. The sketch-on-plane open, VERBATIM from
# trail.txt.18: ProCmdFtExtrude (opens the extrude on the PRE-SELECTED plane) ->
# ProCmdViewSketchView (orient to the sketch plane) -> ProCmdSketRectangle 1 (arm
# the corner-rectangle tool for the operator draw). The TOP plane is pre-selected
# by Invoke-FastenerRelief BEFORE this fires (raw-COM path-qualified), so the macro
# never selects it -- mirroring how ProCmdFtOffset consumes a pre-selected surface.
# ----------------------------------------------------------------------------
function global:Build-CurvedReliefArmMacro {
    return "~ Command ``ProCmdFtExtrude``;" +
        "~ Command ``ProCmdViewSketchView``;" +
        "~ Command ``ProCmdSketRectangle`` 1;"
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
# Invoke-FastenerRelief - drive ONE fastener's chip-relief cut, interleaved into
# the fastener drill loop right after that fastener's hole is drilled (so the TOP
# plane reference is FRESH -- component paths go stale across many RunMacro/DoEvents
# iterations, so reusing it immediately is what keeps this hands-free). CANARY-gated
# on a new feature + a VersionStamp move; NEVER tallies on a miss
# ([[feedback_canary_must_not_assume_on_failure]]). NEVER throws.
#
# FLOW (each leg canary/fallback-safe -- worst case is an operator plane-pick):
#   1. baseline canary: Get-FeatureIdSet (core scope) + $Model.VersionStamp.
#   2. pre-select the TOP plane: Select-ComponentPlaneById -PlaneId $TopPlaneId
#      -Role 'Top' (raw-COM path-qualified -- the SAME channel proven for the hole's
#      ft_dir feed; default Clear = this is a fresh sketch plane). Retry ONCE. On a
#      miss, fire the injected -PlanePrompt (operator Ctrl-clicks the TOP plane).
#   3. & $OnPoll (pump the message loop so Creo consumes the pre-selection).
#   4. RunMacro(Build-CurvedReliefArmMacro) -> opens the extrude sketch on the plane.
#   5. & $DrawPrompt -- operator draws the rectangle (AskInline NoActivate; a pause).
#   6. RunMacro(Build-CurvedReliefCutMacro -SymDepth (2*$ReliefDepth) -BodyIndex).
#      DOUBLING CONTRACT: the driver receives the operator's relief `r` and passes
#      2*r as the symmetric depth (the field is the FULL pocket depth; symmetric
#      splits it, so each side of the TOP plane gets `r`). Doubled HERE, once.
#   7. canary: Wait-ModelModified + Get-FeatureIdSet diff.
#
#   -ComponentPath  the fastener's FRESH IpfcComponentPath (Get-BufferComponentPath
#                   at the hole step) -- NOT a stashed handle (staleness).
#   -TopPlaneId     the fastener's TOP datum-plane feature id (constant 1).
#   -ReliefDepth    the operator's relief depth `r` (> 0; the driver doubles it).
#   -BodyIndex      the conformal blank body index (the cut target).
#   -DrawPrompt     scriptblock: pause for the operator to draw the rectangle.
#   -PlanePrompt    scriptblock: operator fallback if the by-id TOP-plane pre-select
#                   misses (Ctrl-click the TOP plane on screen).
# Returns @{ Cut=<bool>; ViaPlane=<bool>; Reason=<string> }. -OnPoll pumps DoEvents.
# ----------------------------------------------------------------------------
function global:Invoke-FastenerRelief {
    param(
        $Session, $Model, $TypeObj,
        $ComponentPath = $null, [int]$TopPlaneId = 1,
        [double]$ReliefDepth = 0.0, [int]$BodyIndex = 0,
        [scriptblock]$DrawPrompt = $null,
        [scriptblock]$PlanePrompt = $null,
        [scriptblock]$OnPoll = $null, [int]$TimeoutMs = 30000
    )
    $res = @{ Cut = $false; ViaPlane = $false; Reason = '' }
    if ($null -eq $Session -or $null -eq $Model) { $res.Reason = 'no live session/model'; return $res }
    if ($ReliefDepth -le 0) { $res.Reason = 'relief depth <= 0 - nothing to cut'; return $res }

    $featBefore = Get-FeatureIdSet
    $stamp = $null; try { $stamp = $Model.VersionStamp } catch {}

    # 1) pre-select the TOP plane (raw-COM path-qualified). Retry ONCE before the
    # operator fallback: a transient RCW/re-resolve hiccup then converts to a
    # hands-free success instead of a prompt.
    $fedPlane = $false
    if ($null -ne $ComponentPath -and $TopPlaneId -gt 0) {
        for ($attempt = 1; ($attempt -le 2) -and (-not $fedPlane); $attempt++) {
            try {
                $pf = Select-ComponentPlaneById -Session $Session -TypeObj $TypeObj -ComponentPath $ComponentPath -PlaneId $TopPlaneId -Role 'Top'
                if ($null -ne $pf -and $pf.Ok) { $fedPlane = $true; $res.ViaPlane = $true }
            } catch { $fedPlane = $false }
        }
    }
    if (-not $fedPlane) {
        # FALLBACK: operator picks the TOP plane on screen (the sketch-plane reference).
        if ($null -ne $PlanePrompt) { try { & $PlanePrompt } catch {} }
    }

    # 2) pump so Creo processes the pre-selection BEFORE the arm macro opens the extrude.
    if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }

    # 3) open the extrude sketch on the (pre-selected) plane.
    try { $Session.RunMacro((Build-CurvedReliefArmMacro)) }
    catch { $res.Reason = "arm macro error: $($_.Exception.Message)"; return $res }

    # 4) operator draws the rectangle (a pause; its return is ignored).
    if ($null -ne $DrawPrompt) { try { & $DrawPrompt } catch {} }

    # 5) fire the symmetric remove-material cut (2 x relief).
    $symDepth = 2.0 * [double]$ReliefDepth
    try { $Session.RunMacro((Build-CurvedReliefCutMacro -SymDepth $symDepth -BodyIndex $BodyIndex)) }
    catch { $res.Reason = "cut macro error: $($_.Exception.Message)"; return $res }

    # 6) canary: a new feature must appear AND the VersionStamp must move. A stamp
    # that could not be read is a MISS, never assumed success.
    if ($null -eq $stamp) { $res.Reason = 'could not read a baseline VersionStamp - cut cannot be verified (treated as a miss)'; return $res }
    $changed = $false
    try { $changed = Wait-ModelModified -Model $Model -PreviousStamp $stamp -TimeoutMs $TimeoutMs -OnPoll $OnPoll } catch { $changed = $false }
    if (-not $changed) {
        $res.Reason = 'the relief cut did not change the model (rectangle not a closed loop, plane not consumed, or widget drift)'
        return $res
    }
    $afterFeat = Get-FeatureIdSet
    $newFeats = @($afterFeat.Keys | Where-Object { -not $featBefore.ContainsKey($_) })
    if (@($newFeats).Count -ge 1) { $res.Cut = $true; $res.Reason = 'relief pocket cut (new feature + VersionStamp moved)' }
    else { $res.Reason = 'VersionStamp moved but no new feature id resolved (treated as a miss)' }
    return $res
}
