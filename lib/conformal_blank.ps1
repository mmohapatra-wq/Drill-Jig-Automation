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
# Get-OffsetThickenMacro - the offset+thicken dashboard sequence (the user's
# recording, verbatim widgets), fired as ONE atomic RunMacro AFTER the surface(s)
# are already buffered by ID. Offset distance / thickness are NOT set here - they
# are driven afterward by regenerative dimensioning. THICKEN OUTPUTS A NEW BODY
# (the chkbn.body_page.0 + PH.bodyusechkbtnrepwdg widgets, thickenator's confirmed
# "thicken -> new solid body"). A single maindashInst0.Flip grows material AWAY
# from the part (confirmed needed live 2026-06-24). PURE.
# ----------------------------------------------------------------------------
# RECONCILED 2026-07-27 to the operator's 'curvedworkflow' recording (MAPKEYS.md):
# the offset+thicken is NO LONGER one atomic macro. The recording shows the offset
# DISTANCE and the thickness are both set via GrmTextTagEmbedMRU (NOT mru_option_menu/
# ExclSrfColl / maindashInst0.Thickness), and the offset quilt must be SHOWN before the
# thicken can consume it. So it splits into three PURE builders that Invoke-ConformalBlank
# fires as offset -> (find + show quilt) -> thicken, with a canary per phase. The old
# single Get-OffsetThickenMacro (wrong widgets: mru_option_menu/ExclSrfColl + Flip/body-
# page) is replaced. LIVE-UNVERIFIED: whether ProCmdFtOffset/ProCmdFtThicken consume a
# pre-selected-by-ID surface here (the recording used two operator screen picks); if the
# canary shows a phase did not fire, the fix is to make that pick an operator arm step.

# Get-OffsetMacro - the OFFSET-surface leg. The caller PRE-SELECTS the surface(s) by ID
# (Get-SelectSurfacesByIdMacro) so ProCmdFtOffset consumes them; the offset DISTANCE goes
# in GrmTextTagEmbedMRU (Open/Close/Update), then Done. Verbatim widget order from the
# recording (no Activate on the MRU for the offset leg). PURE.
function global:Get-OffsetMacro {
    param([double]$StandOff = 0.0)
    $v = ('{0}' -f $StandOff)
    return "~ Command ``ProCmdFtOffset``;" +
        "~ Open   ``main_dlg_cur`` ``GrmTextTagEmbedMRU``;" +
        "~ Close  ``main_dlg_cur`` ``GrmTextTagEmbedMRU``;" +
        "~ Update ``main_dlg_cur`` ``GrmTextTagEmbedMRU`` ``$v``;" +
        "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"
}

# Get-ShowByIdMacro - select a feature/surface BY ID, then ProCmdViewShow@PopupMenuTree,
# to make the (hidden) offset quilt visible so the thicken can consume it (the recording
# right-clicks the offset feature in the tree + Show; the by-ID select is the automatable
# equivalent). PURE.
function global:Get-ShowByIdMacro {
    param([string]$TypeName, [int]$Id)
    return (Get-SelectItemByIdMacro -TypeName $TypeName -Id $Id) +
        "~ Command ``ProCmdViewShow@PopupMenuTree``;"
}

# Get-ThickenMacro - the THICKEN leg. The caller PRE-SELECTS the (shown) offset quilt by
# ID so ProCmdFtThicken consumes it; the THICKNESS goes in GrmTextTagEmbedMRU (Update +
# Activate), then blur via Enter/Exit dashInst0.Quit, then Done. Verbatim from the
# recording (NOT maindashInst0.Thickness / Flip / body-page). PURE.
function global:Get-ThickenMacro {
    param([double]$Thickness)
    $v = ('{0}' -f $Thickness)
    return "~ Command ``ProCmdFtThicken``;" +
        "~ Update ``main_dlg_cur`` ``GrmTextTagEmbedMRU`` ``$v``;" +
        "~ Activate ``main_dlg_cur`` ``GrmTextTagEmbedMRU``;" +
        "~ Enter ``main_dlg_cur`` ``dashInst0.Quit``;" +
        "~ Exit  ``main_dlg_cur`` ``dashInst0.Quit``;" +
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
# Invoke-ConformalBlank - the STAGE-1 ORCHESTRATOR, reconciled 2026-07-27 to the
# operator's 'curvedworkflow' recording (MAPKEYS.md). TWO PHASES with a canary each
# (the offset quilt must be SHOWN between them so the thicken can consume it):
#   PHASE 1 (offset): pre-select the surface(s) by ID -> Get-OffsetMacro (offset
#     distance = $StandOff via GrmTextTagEmbedMRU) -> Done. Canary on VersionStamp.
#   BETWEEN: diff ITEM_SURFACE to find the NEW quilt surfaces; SHOW the new offset
#     feature (Get-ShowByIdMacro) so the quilt is visible/pickable.
#   PHASE 2 (thicken): pre-select the new quilt surfaces by ID -> Get-ThickenMacro
#     (thickness = $Thickness via GrmTextTagEmbedMRU + blur + Done). Canary.
#   BACKSTOP: regenerative-dimension the offset -> $StandOff and thicken -> $Thickness
#     (Set-DimAndConfirm) in case the in-dashboard value did not stick. Then diff for
#     the NEW blank BODY.
# COM; reads the passed -Session/-Model/-TypeObj. NEVER throws (never assumes success
# on a canary miss). -OnPoll threaded to Wait-ModelModified.
#   LIVE-UNVERIFIED: whether ProCmdFtOffset/ProCmdFtThicken consume a pre-selected-by-ID
#   surface here (the recording used two operator screen picks). If PHASE 2 does not
#   fire (canary miss), the next fix is to make the quilt selection an operator arm/pick
#   step (box-a/box-b split) -- Made stays $false and the caller reports honestly.
# Returns:
#   @{ Made; Phase1; Phase2; OffsetSym; ThickSym; OffsetHeld; ThicknessHeld;
#      QuiltSurfIds; OffsetFeatId; BodyIndex; BodyId; BodyName; Reason }
# ----------------------------------------------------------------------------
function global:Invoke-ConformalBlank {
    param(
        $Session, $Model, $TypeObj,
        [int[]]$SurfIds,
        [double]$Thickness,
        [double]$StandOff = 0.0,
        [scriptblock]$OnPoll = $null,
        [int]$TimeoutMs = 30000
    )
    $res = @{ Made=$false; Phase1=$false; Phase2=$false; OffsetSym=$null; ThickSym=$null;
              ThicknessHeld=$false; OffsetHeld=$false; QuiltSurfIds=@(); OffsetFeatId=$null;
              BodyIndex=$null; BodyId=$null; BodyName=$null; Reason='' }
    if ($null -eq $SurfIds -or @($SurfIds).Count -lt 1) { $res.Reason = 'no surface ids to offset'; return $res }
    if ($Thickness -le 0) { $res.Reason = 'thickness must be > 0'; return $res }

    $beforeFeat   = Get-FeatureIdSet
    $beforeSurf   = Get-SurfaceIdSet -Model $Model -TypeObj $TypeObj
    $beforeBodies = Get-BodyIdSet -Model $Model -TypeObj $TypeObj

    # -- PHASE 1: offset (pre-selected surface consumes into ProCmdFtOffset) --
    $stamp1 = $null; try { $stamp1 = $Model.VersionStamp } catch {}
    $m1 = (Get-SelectSurfacesByIdMacro -SurfIds $SurfIds) + (Get-OffsetMacro -StandOff $StandOff)
    try { $Session.RunMacro($m1) } catch { $res.Reason = "offset macro error: $($_.Exception.Message)"; return $res }
    if ($null -ne $stamp1) { $res.Phase1 = Wait-ModelModified -Model $Model -PreviousStamp $stamp1 -TimeoutMs $TimeoutMs -OnPoll $OnPoll }
    if (-not $res.Phase1) { $res.Reason = 'the offset did not fire (model unchanged) - check the pre-selected surface / widget names'; return $res }

    # -- BETWEEN: find the new offset feature + the new quilt surfaces; SHOW the quilt --
    $newFeatsP1 = @(Get-NewFeatureLinearDims -Model $Model -TypeObj $TypeObj -BeforeIds $beforeFeat)
    if (@($newFeatsP1).Count -ge 1) { $res.OffsetFeatId = [int]$newFeatsP1[0].Id }
    $res.QuiltSurfIds = @(Resolve-NewSurfaceIds -Model $Model -TypeObj $TypeObj -Before $beforeSurf)
    if ($null -ne $res.OffsetFeatId -and [int]$res.OffsetFeatId -gt 0) {
        try { $Session.RunMacro((Get-ShowByIdMacro -TypeName 'Feature' -Id ([int]$res.OffsetFeatId))) } catch {}
    }

    # -- PHASE 2: thicken (pre-select the new quilt surfaces, then ProCmdFtThicken) --
    $stamp2 = $null; try { $stamp2 = $Model.VersionStamp } catch {}
    $selQuilt = if (@($res.QuiltSurfIds).Count -ge 1) { (Get-SelectSurfacesByIdMacro -SurfIds $res.QuiltSurfIds) } else { "" }
    $m2 = $selQuilt + (Get-ThickenMacro -Thickness $Thickness)
    try { $Session.RunMacro($m2) } catch { $res.Reason = "thicken macro error: $($_.Exception.Message)"; return $res }
    if ($null -ne $stamp2) { $res.Phase2 = Wait-ModelModified -Model $Model -PreviousStamp $stamp2 -TimeoutMs $TimeoutMs -OnPoll $OnPoll }
    if (-not $res.Phase2) {
        $res.Reason = 'the offset was created but the THICKEN did not fire (model unchanged after phase 2). The quilt may need an operator pick - re-run and pick the shown quilt, or use --default (operator pick) once wired.'
        return $res
    }
    $res.Made = $true

    # -- BACKSTOP: regenerative-dimension offset->StandOff, thicken->Thickness --
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
