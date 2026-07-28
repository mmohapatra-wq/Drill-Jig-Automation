# ============================================================================
# lib\conformal_blank.ps1 - the CONFORMAL JIG BLANK engine (STAGE 1 of the curved
# drill jig) + the On-Point normal-hole macro, lifted out of drilljig3d.cmd so BOTH
# the console tool AND drilljig3d-gui.cmd call ONE source.
# ============================================================================
# Dot-source AFTER lib\creo_geometry.ps1 (Read-DimValue) and lib\drilljig_core.ps1.
# drilljig_core.ps1 already provides the SHARED COM primitives this module reuses
# (so they are NOT redefined here, which would shadow the scope the curved-slot
# loop relies on):
#     Invoke-Macro / Invoke-ForceRegen / Wait-ModelModified / Get-FeatureIdSet
#     (all read the $script:DJSession/DJModel/DJType scope set by Initialize-DrilljigCore),
#     Get-SelectByIdMacro / Get-SelectDatumByIdMacro.
# This module adds ONLY the STAGE-1 offset+thicken pieces + the On-Point normal-hole
# macro + the ID-only selection-buffer readers. Every function is `function global:`
# so the wizard's .GetNewClosure() step handlers resolve them (the closure-scope rule
# in [[project_gui_scope_bugs]]). PURE builders NEVER throw; COM readers degrade to
# empty/$null. ID-ONLY throughout - never reads IpfcPoint.Point (holeinator's lesson).
#
# PROVENANCE: the macro token sequences here are lifted VERBATIM from drilljig3d.cmd
# (STAGE 1 offset+thicken confirmed live 2026-06-24; the On-Point hole tail from
# holeinator, recorded 2026-06-11). drilljig3d.cmd keeps its own inline copies for
# now; a later dedup can point it at this module.
# ============================================================================

# ----------------------------------------------------------------------------
# Get-SelectSurfacesByIdMacro - tree-search "select surface(s) BY ID into the
# buffer" (plane-probe's select-by-id skeleton, type=Surface, edginator's
# accumulate loop so >1 surface can feed one offset quilt). Clears the buffer
# first, opens the search once, loops every id (ApplyBtn ACCUMULATES), closes once.
# The caller appends ProCmdFtOffset, which consumes the buffered surface set. PURE.
# ----------------------------------------------------------------------------
function global:Get-SelectSurfacesByIdMacro {
    param([int[]]$SurfIds)
    $m = "~ Activate ``main_dlg_cur`` ``buffer_clean``;" +
        "~ Command ``ProCmdMdlTreeSearch``;" +
        "~ Open ``selspecdlg0`` ``SelOptionRadio``;" +
        "~ Close ``selspecdlg0`` ``SelOptionRadio``;" +
        "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Surface``;" +
        "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;"
    foreach ($id in $SurfIds) {
        $m += "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$id``;" +
              "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
              "~ Activate ``selspecdlg0`` ``ApplyBtn``;"
    }
    $m += "~ Activate ``selspecdlg0`` ``CancelButton``;"
    return $m
}

# ----------------------------------------------------------------------------
# Get-OffsetThickenMacro - the offset+thicken dashboard sequence, fired as ONE
# atomic RunMacro AFTER the surface(s) are already buffered by ID. This is the
# AUTHORITATIVE sequence, transcribed VERBATIM from the operator's freshest
# recording (working_folder\trail\trail.txt.15, the 'dumbclaude'/'claudedumb'
# mapkeys, 2026-07-27 15:43). It supersedes the 2026-07-27-AM 'curvedworkflow'
# reconciliation (commit 6784c5a), which used the WRONG widgets (GrmTextTagEmbedMRU
# for both values + a show-the-quilt right-click dance + operator screen-picks) and
# DROPPED the new-body checkbox -- so the GUI Surface stage silently no-op'd. The
# correct sequence matches drilljig3d.cmd STAGE 1 (Get-OffsetThickenMacro, CONFIRMED
# LIVE 2026-06-24): pre-select the surface by ID -> ProCmdFtOffset (consumes it) ->
# mru_option_menu/ExclSrfColl -> Done -> ProCmdFtThicken -> type maindashInst0.Thickness
# -> [optional single Flip] -> thicken_control.0 + body_page.0 + body_page.0.0
# PH.bodyusechkbtnrepwdg (THE "CREATE A NEW BODY" CHECKBOX) -> Done. NO
# GrmTextTagEmbedMRU, NO show-quilt, NO operator picks.
#
#   -Thickness : typed straight into maindashInst0.Thickness (the recording types
#                `.5` in-dashboard); the regen-dim backstop re-confirms it.
#   -StandOff  : NOT written here -- the recording's offset leg (mru_option_menu `0`)
#                types no offset distance, so StandOff is applied ONLY by the caller's
#                regenerative-dimension backstop. Kept as a param for signature parity.
#   -Flip      : emit ONE maindashInst0.Flip before the body-page block (drilljig3d.cmd
#                fires this unconditionally: "the default thickened toward the part").
#                DEFAULT OFF = match the trail.15 recording (which has no Flip); the
#                GUI exposes --flip if a part grows the wrong way live.
# PURE (string only). LIVE-UNVERIFIED in the GUI (headless): the thicken_control.0 +
# typed maindashInst0.Thickness combo -- canary-gated by Invoke-ConformalBlank.
# ----------------------------------------------------------------------------
function global:Get-OffsetThickenMacro {
    param([double]$Thickness, [double]$StandOff = 0.0, [switch]$Flip)
    $t = ('{0}' -f $Thickness)
    $flipTok = if ($Flip) { "~ Activate ``main_dlg_cur`` ``maindashInst0.Flip``;" } else { "" }
    return "~ Command ``ProCmdFtOffset``;" +
        "~ Input  ``main_dlg_cur`` ``maindashInst0.mru_option_menu`` ``0``;" +
        "~ Update ``main_dlg_cur`` ``maindashInst0.mru_option_menu`` ``0``;" +
        "~ Trigger ``main_dlg_cur`` ``maindashInst0.ExclSrfColl`` ``0``;" +
        "~ Trigger ``main_dlg_cur`` ``maindashInst0.ExclSrfColl`` ````;" +
        "~ FocusOut ``main_dlg_cur`` ``maindashInst0.mru_option_menu``;" +
        "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;" +
        "~ Command ``ProCmdFtThicken``;" +
        "~ Enter ``main_dlg_cur`` ``dashInst0.Quit``;" +
        "~ Exit  ``main_dlg_cur`` ``dashInst0.Quit``;" +
        "~ Input  ``main_dlg_cur`` ``maindashInst0.Thickness`` ``$t``;" +
        "~ Update ``main_dlg_cur`` ``maindashInst0.Thickness`` ``$t``;" +
        "~ FocusOut ``main_dlg_cur`` ``maindashInst0.Thickness``;" +
        $flipTok +
        "~ Activate ``main_dlg_cur`` ``chkbn.thicken_control.0`` 1;" +
        "~ Activate ``main_dlg_cur`` ``chkbn.body_page.0`` 1;" +
        "~ Activate ``body_page.0.0`` ``PH.bodyusechkbtnrepwdg`` 1;" +
        "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"
}

# ----------------------------------------------------------------------------
# Get-SelectItemByIdMacro - generic tree-search "select ONE item of $TypeName by
# $Id into the buffer". Clears the buffer first UNLESS -NoClear (which ACCUMULATES
# a second ref - used to add the orientation surface after the placement point). PURE.
# ----------------------------------------------------------------------------
function global:Get-SelectItemByIdMacro {
    param([string]$TypeName, [int]$Id, [switch]$NoClear)
    $clear = if ($NoClear) { "" } else { "~ Activate ``main_dlg_cur`` ``buffer_clean``;" }
    return $clear +
        "~ Command ``ProCmdMdlTreeSearch``;" +
        "~ Open ``selspecdlg0`` ``SelOptionRadio``;" +
        "~ Close ``selspecdlg0`` ``SelOptionRadio``;" +
        "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``$TypeName``;" +
        "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
        "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$Id``;" +
        "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
        "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
        "~ Activate ``selspecdlg0`` ``CancelButton``;"
}

# ----------------------------------------------------------------------------
# Build-NormalHoleMacro - the On-Point HOLE macro, NORMAL TO THE SURFACE. Reuses
# holeinator's CONFIRMED-LIVE hole dashboard tail (thru-all + body page + diameter,
# recorded 2026-06-11) VERBATIM; the 3D-specific addition is the orientation ref.
# 1) placement: the datum point (clears the buffer). 2) orientation: add the surface
# (or tangent plane) as a 2nd buffered ref, UNLESS -DefaultOrient. 3) the recorded
# On-Point tail. -SurfaceId here is the ORIENTATION reference (a surface OR a tangent
# datum plane feat id; the by-ID select is type 'Surface' either way on this build).
# PURE (string only).
# ----------------------------------------------------------------------------
function global:Build-NormalHoleMacro {
    param([int]$PointId, [int]$SurfaceId, [double]$Diameter, [int]$BodyIndex = 0, [switch]$DefaultOrient)
    $m = (Get-SelectItemByIdMacro -TypeName 'Point' -Id $PointId)
    if (-not $DefaultOrient -and $SurfaceId -gt 0) {
        $m += (Get-SelectItemByIdMacro -TypeName 'Surface' -Id $SurfaceId -NoClear)
    }
    $m += "~ Command ``ProCmdHole``;" +
        "~ Select ``main_dlg_cur`` ``maindashInst0.hole_depth_to_type_flybtn``;" +
        "~ Close  ``main_dlg_cur`` ``maindashInst0.hole_depth_to_type_flybtn``;" +
        "~ Activate ``main_dlg_cur`` ``maindashInst0.StrHoleDepThruAllF`` 1;" +
        "~ Activate ``main_dlg_cur`` ``chkbn.std_hle_layout.0`` 1;" +
        "~ Activate ``main_dlg_cur`` ``chkbn.std_hole_note_layout.0`` 1;" +
        "~ Activate ``main_dlg_cur`` ``chkbn.body_page.0`` 1;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ``$BodyIndex``;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ````;" +
        "~ Focus  ``body_page.1.0`` ``PH.bodyselectrepwdg_list``;" +
        "~ Select ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` 1 ``$BodyIndex``;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ````;" +
        "~ Input  ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu`` ``$Diameter``;" +
        "~ Update ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu`` ``$Diameter``;" +
        "~ Activate ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu``;" +
        "~ FocusOut ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu``;" +
        "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"
    return $m
}

# ----------------------------------------------------------------------------
# Get-NewFeatureLinearDims - for every feature NOT in $BeforeIds, return its id +
# its LINEAR (DimType 0) dim symbols, sorted ascending by id (= creation order).
# This isolates the new offset feature's dim and the new thicken feature's dim
# (the lower new id is the offset, the higher the thicken). NEVER throws.
# ----------------------------------------------------------------------------
function global:Get-NewFeatureLinearDims {
    param($Model, $TypeObj, $BeforeIds)
    $out = @()
    try {
        foreach ($f in $Model.ListItems($TypeObj.ITEM_FEATURE)) {
            $fid = $null
            try { $fid = [int]$f.Id } catch {}
            if ($null -eq $fid -or $BeforeIds.ContainsKey($fid)) { continue }
            $syms = @()
            try {
                foreach ($d in $f.ListSubItems($TypeObj.ITEM_DIMENSION)) {
                    try { if ([int]$d.DimType -eq 0) { $syms += [string]$d.Symbol } } catch {}
                }
            } catch {}
            $out += [pscustomobject]@{ Id = $fid; Dims = @($syms) }
        }
    } catch {}
    return @($out | Sort-Object Id)
}

# ----------------------------------------------------------------------------
# Get-BodyIdSet - snapshot solid-body ids into a hashtable set. The thicken creates
# a NEW body; the caller diffs before/after to find it (index in ListItems(ITEM_BODY)
# == the hole dashboard's body-selector index). NEVER throws.
# ----------------------------------------------------------------------------
function global:Get-BodyIdSet {
    param($Model, $TypeObj)
    $set = @{}
    try {
        foreach ($b in $Model.ListItems($TypeObj.ITEM_BODY)) {
            try { $set[[int]$b.Id] = $true } catch {}
        }
    } catch {}
    return $set
}

# Snapshot surface ids into a hashtable set. The offset creates a NEW quilt (a set of
# new surfaces); Invoke-ConformalBlank diffs this before/after the offset to find the
# quilt surfaces to SHOW + pre-select for the thicken. ID-only. NEVER throws.
function global:Get-SurfaceIdSet {
    param($Model, $TypeObj)
    $set = @{}
    try {
        foreach ($s in $Model.ListItems($TypeObj.ITEM_SURFACE)) {
            try { $set[[int]$s.Id] = $true } catch {}
        }
    } catch {}
    return $set
}

# Diff the current ITEM_SURFACE set against a prior snapshot -> the @(new int ids).
function global:Resolve-NewSurfaceIds {
    param($Model, $TypeObj, $Before)
    $after = Get-SurfaceIdSet -Model $Model -TypeObj $TypeObj
    $new = @()
    foreach ($id in $after.Keys) { if (-not $Before.ContainsKey($id)) { $new += [int]$id } }
    return @($new | Sort-Object)
}

# ----------------------------------------------------------------------------
# Set-DimAndConfirm - write one dim by symbol, force a regen, return the value that
# actually stuck (or $null on a write failure). Uses Read-DimValue (creo_geometry)
# + Invoke-ForceRegen (drilljig_core). NEVER throws.
# ----------------------------------------------------------------------------
function global:Set-DimAndConfirm {
    param($Model, $TypeObj, [string]$Sym, [double]$Target)
    try {
        $d = $Model.GetItemByName($TypeObj.ITEM_DIMENSION, $Sym)
        $d.DimValue = $Target
    } catch {
        return $null
    }
    try { Invoke-ForceRegen -Model $Model } catch {}
    return (Read-DimValue -Model $Model -TypeObj $TypeObj -Sym $Sym)
}

# ----------------------------------------------------------------------------
# Resolve-SelectedSurfaces - read the selection buffer into surface IDs. ID-ONLY -
# never reads a surface coordinate. An item counts as a surface if its Type is
# ITEM_SURFACE. Dedups; reports non-surface selections. Returns
# @{ Surfaces=@(ids); Rejected=@() }. NEVER throws.
# ----------------------------------------------------------------------------
function global:Resolve-SelectedSurfaces {
    param($Session, $TypeObj)
    $ids = @(); $seen = @{}; $rejected = @()
    $contents = $null
    try { $contents = ($Session.CurrentSelectionBuffer()).Contents } catch {}
    if ($null -eq $contents) { return @{ Surfaces = @(); Rejected = @() } }
    foreach ($item in $contents) {
        $si = $null
        try { $si = $item.SelItem } catch { continue }
        if ($null -eq $si) { continue }
        $id = $null
        try { $id = [int]$si.Id } catch {}
        $isSurf = $false
        try { $isSurf = ([int]$si.Type -eq [int]$TypeObj.ITEM_SURFACE) } catch {}
        if (-not $isSurf) {
            $tname = "?"
            try { $tname = [string]$si.Type } catch {}
            $rejected += "id $(if ($null -ne $id) { $id } else { '?' }) (type $tname, not a surface)"
            continue
        }
        if ($null -eq $id -or $seen.ContainsKey($id)) { continue }
        $seen[$id] = $true
        $ids += $id
    }
    return @{ Surfaces = @($ids); Rejected = @($rejected) }
}

# ----------------------------------------------------------------------------
# Resolve-SelectedPoints - resolve the selection buffer into datum-point IDs.
# ID-ONLY (never $p.Point). A selection is the point geometry directly (Type=
# ITEM_POINT) or a datum-point FEATURE whose point ids come from ListSubItems(
# ITEM_POINT). Returns @{ Points=@(ids); Rejected=@() }. NEVER throws.
# ----------------------------------------------------------------------------
function global:Resolve-SelectedPoints {
    param($Session, $TypeObj)
    $ids = @(); $seen = @{}; $rejected = @()
    $contents = $null
    try { $contents = ($Session.CurrentSelectionBuffer()).Contents } catch {}
    if ($null -eq $contents) { return @{ Points = @(); Rejected = @() } }
    foreach ($item in $contents) {
        $si = $null
        try { $si = $item.SelItem } catch { continue }
        if ($null -eq $si) { continue }
        $isPoint = $false
        try { $isPoint = ([int]$si.Type -eq [int]$TypeObj.ITEM_POINT) } catch {}
        $subIds = @()
        try { foreach ($p in @($si.ListSubItems($TypeObj.ITEM_POINT))) { try { $subIds += [int]$p.Id } catch {} } } catch {}
        if ($subIds.Count -gt 0) {
            foreach ($sid in $subIds) { if (-not $seen.ContainsKey($sid)) { $seen[$sid] = $true; $ids += $sid } }
        } elseif ($isPoint) {
            $id = [int]$si.Id
            if (-not $seen.ContainsKey($id)) { $seen[$id] = $true; $ids += $id }
        } else {
            $tname = "?"; $rid = "?"
            try { $rid = [int]$si.Id } catch {}
            try { $tname = [string]$si.Type } catch {}
            $rejected += "id $rid (type $tname)"
        }
    }
    return @{ Points = @($ids); Rejected = @($rejected) }
}

# ----------------------------------------------------------------------------
# Invoke-ConformalBlank - the STAGE-1 ORCHESTRATOR. ONE ATOMIC macro (faithful to
# the trail.txt.15 recording + drilljig3d.cmd STAGE 1, CONFIRMED LIVE 2026-06-24):
#   1. pre-select the surface(s) BY ID (Get-SelectSurfacesByIdMacro) so ProCmdFtOffset
#      consumes them, then the whole offset+thicken+new-body sequence
#      (Get-OffsetThickenMacro -Thickness -Flip) fires in one RunMacro. The thicken's
#      command context relies on the freshly-created offset quilt being live, which a
#      dashboard does NOT keep across separate RunMacro calls -- so it MUST be one macro.
#   2. CANARY on VersionStamp: a no-change is a MISS (Made=$false + Reason), NEVER an
#      assumed success ([[feedback_canary_must_not_assume_on_failure]]).
#   3. BACKSTOP: regenerative-dimension the offset -> $StandOff (the recording types no
#      offset distance) and the thicken -> $Thickness (in case the typed value slipped),
#      disambiguated by creation order (lower new feat id = offset, higher = thicken).
#   4. diff ITEM_BODY for the NEW blank body so the drill stage targets it.
# COM; reads the passed -Session/-Model/-TypeObj. NEVER throws. -OnPoll threaded to
# Wait-ModelModified (a GUI passes a DoEvents pump). -Flip forwards to the macro.
#   LIVE-UNVERIFIED (headless): the thicken_control.0 + typed maindashInst0.Thickness +
#   body_page.0.0 PH.bodyusechkbtnrepwdg combo (trail.15). A canary miss keeps Made=$false
#   and the caller reports honestly; --flip is the escape hatch if material grows the
#   wrong way.
# Returns:
#   @{ Made; Changed; OffsetSym; ThickSym; OffsetHeld; ThicknessHeld;
#      BodyIndex; BodyId; BodyName; Reason }
# ----------------------------------------------------------------------------
function global:Invoke-ConformalBlank {
    param(
        $Session, $Model, $TypeObj,
        [int[]]$SurfIds,
        [double]$Thickness,
        [double]$StandOff = 0.0,
        [switch]$Flip,
        [scriptblock]$OnPoll = $null,
        [int]$TimeoutMs = 30000
    )
    $res = @{ Made=$false; Changed=$false; OffsetSym=$null; ThickSym=$null;
              OffsetHeld=$false; ThicknessHeld=$false;
              BodyIndex=$null; BodyId=$null; BodyName=$null; Reason='' }
    if ($null -eq $SurfIds -or @($SurfIds).Count -lt 1) { $res.Reason = 'no surface ids to offset'; return $res }
    if ($Thickness -le 0) { $res.Reason = 'thickness must be > 0'; return $res }

    $beforeFeat   = Get-FeatureIdSet
    $beforeBodies = Get-BodyIdSet -Model $Model -TypeObj $TypeObj

    # -- ONE atomic macro: select surface(s) by ID -> offset+thicken+new-body --
    $stamp = $null; try { $stamp = $Model.VersionStamp } catch {}
    $macro = (Get-SelectSurfacesByIdMacro -SurfIds $SurfIds) +
             (Get-OffsetThickenMacro -Thickness $Thickness -StandOff $StandOff -Flip:$Flip)
    try { $Session.RunMacro($macro) } catch { $res.Reason = "offset/thicken macro error: $($_.Exception.Message)"; return $res }

    # -- CANARY: the macro must have modified the model (else a MISS, not success) --
    if ($null -ne $stamp) { $res.Changed = Wait-ModelModified -Model $Model -PreviousStamp $stamp -TimeoutMs $TimeoutMs -OnPoll $OnPoll }
    if (-not $res.Changed) {
        $res.Reason = 'the offset/thicken did not fire (model unchanged) - check the pre-selected surface / recorded widget names (visible_mapkeys yes), or try --flip.'
        return $res
    }
    $res.Made = $true

    # -- BACKSTOP: regenerative-dimension offset->StandOff, thicken->Thickness.
    # By creation order the LOWER new feat id is the offset, the HIGHER is the thicken.
    $newFeats = @(Get-NewFeatureLinearDims -Model $Model -TypeObj $TypeObj -BeforeIds $beforeFeat)
    if (@($newFeats).Count -ge 1) {
        $offsetFeat = $newFeats[0]
        $thickFeat  = if (@($newFeats).Count -ge 2) { $newFeats[$newFeats.Count - 1] } else { $null }
        if ($offsetFeat.Dims.Count -ge 1) {
            $res.OffsetSym = [string]$offsetFeat.Dims[0]
            $now = Set-DimAndConfirm -Model $Model -TypeObj $TypeObj -Sym $res.OffsetSym -Target $StandOff
            if ($null -ne $now -and [math]::Abs($now - $StandOff) -lt 1e-4) { $res.OffsetHeld = $true }
        }
        if ($null -ne $thickFeat -and $thickFeat.Dims.Count -ge 1) {
            $res.ThickSym = [string]$thickFeat.Dims[0]
            $now = Set-DimAndConfirm -Model $Model -TypeObj $TypeObj -Sym $res.ThickSym -Target $Thickness
            if ($null -ne $now -and [math]::Abs($now - $Thickness) -lt 1e-4) { $res.ThicknessHeld = $true }
        }
    }

    # -- Identify the NEW body (diff vs before) so the drill stage targets the blank --
    try {
        $afterBodies = @($Model.ListItems($TypeObj.ITEM_BODY))
        for ($bi = 0; $bi -lt $afterBodies.Count; $bi++) {
            $bid = $null
            try { $bid = [int]$afterBodies[$bi].Id } catch {}
            if ($null -ne $bid -and -not $beforeBodies.ContainsKey($bid)) {
                $res.BodyIndex = $bi; $res.BodyId = $bid
                try { $res.BodyName = [string]$afterBodies[$bi].GetName() } catch {}
                break
            }
        }
    } catch {}

    return $res
}
