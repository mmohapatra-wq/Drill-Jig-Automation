# ============================================================================
# lib\curved_fastener_hole.ps1 - the FASTENER-PLANE hole engine for the curved
# drill jig: a fastener's TOP/SIDE/FRONT planes -> a datum POINT at their
# intersection -> an ON-POINT hole placed on that point + ORIENTED to the fastener's
# own TOP plane (id 1), drilled into the jig blank.
# ============================================================================
# Dot-source AFTER lib\creo_geometry.ps1 + lib\drilljig_core.ps1 + lib\
# conformal_blank.ps1. It reuses drilljig_core's shared primitives (Get-FeatureIdSet
# / Wait-ModelModified read the $script:DJSession/DJModel/DJType scope set by
# Initialize-DrilljigCore) and conformal_blank's ID-only buffer readers -- nothing
# is redefined here. Every function is `function global:` so the wizard's
# .GetNewClosure() step handlers resolve it (the closure-scope rule,
# [[project_gui_scope_bugs]]). PURE builders NEVER throw. ID-ONLY throughout --
# never reads IpfcPoint.Point (holeinator's lesson).
#
# PROVENANCE: the POINT macro (ProCmdDatumPointGeneral + stdbtn_1) is the proven
# 3-plane-intersection recipe (confirmed live: fastenerplane-probe point id 951/957/959;
# the 3 planes belong to a fastener COMPONENT selected with the jig part ACTIVATED). The
# HOLE macro (Build-PreselectedHoleMacro = ProCmdHole + dashInst0.Quit blur + dashInst0.Done)
# is transcribed VERBATIM from the operator's authoritative 'holeexctrude' recording
# (2026-07-28): the datum POINT and the fastener's TOP plane are SELECTED TOGETHER (a 2-item
# tree selection) BEFORE ProCmdHole, which AUTO-ASSIGNS them by type -- point -> on-point
# placement, TOP plane -> normal orientation. NO prim_ref/ft_dir collector arming, NO
# placement-page triggers. The hole DIAMETER is set from the selected value (user 2026-07-29)
# via the confirmed-live maindashInst0.diameter_mip_OptionMenu widget (Build-PreselectedHoleMacro
# -Diameter) so the hole is drilled at the right size; thru-all/target-body still inherit Creo's
# current dashboard settings. A wrong diameter is NOT caught by the feature-diff canary, so still
# verify the size + thru-all visually.
#
# ORIENTATION: the hole is oriented to the fastener's OWN TOP plane (feature id 1) -- the hole
# axis is normal to that plane, which (per the operator) is exactly normal to the jig part.
# The operator's 'holeexctrude' recording (2026-07-28) shows the CORRECT sequence: SELECT the
# datum POINT and the fastener's TOP plane TOGETHER (a 2-item tree selection), THEN fire
# ProCmdHole + Done -- ProCmdHole AUTO-ASSIGNS them by type (point -> on-point PLACEMENT, plane
# -> normal ORIENTATION). NO prim_ref/ft_dir collector arming, NO placement-page triggers (the
# prior arm-then-feed approach was overcomplicated -- ft_dir never reliably consumed a raw-COM
# selection in the GUI). Invoke-FastenerHole reproduces the two tree picks by ID: the local
# datum point (path=$null) + the TOP plane (id 1, path-qualified, Select-ComponentPlaneById
# -NoClear so BOTH sit in the buffer), then Build-PreselectedHoleMacro fires ProCmdHole which
# consumes the pre-selection. NO tangent plane (retired). If the plane can't be staged by ID,
# an operator Ctrl-click-the-TOP-plane pause is the fallback. Canary (new hole feature) + the
# fallback = no regression. LIVE-UNVERIFIED that ProCmdHole auto-assigns the pre-selected
# point+plane in the GUI (the recording proves it manually; re-run pipeline/drilljig3d-gui.cmd).
# ============================================================================

# ----------------------------------------------------------------------------
# Build-FastenerPointMacro - create a datum POINT at the intersection of the 3
# fastener planes ALREADY IN THE SELECTION BUFFER (the operator Ctrl-clicked them).
# ProCmdDatumPointGeneral consumes the buffered planes; stdbtn_1 = OK. ONE atomic
# macro (no by-ID re-select -- the operator's live selection IS the input, exactly
# like the recording's tree-node select). PURE.
# ----------------------------------------------------------------------------
function global:Build-FastenerPointMacro {
    return "~ Command ``ProCmdDatumPointGeneral``;" +
        "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;"
}

# ----------------------------------------------------------------------------
# Build-PreselectedHoleMacro - the WHOLE on-point hole, VERBATIM from the operator's
# authoritative 'holeexctrude' recording (2026-07-28). The caller PRE-SELECTS BOTH the datum
# POINT and the fastener's TOP plane (a 2-item selection) BEFORE this fires; ProCmdHole then
# consumes that pre-selection and AUTO-ASSIGNS by type -- the datum point becomes the ON-POINT
# placement, the TOP plane becomes the direction/ORIENTATION reference -- so NO prim_ref / ft_dir
# collector manipulation, NO placement-page triggers, NO diameter/thru-all/body are needed (the
# hole inherits Creo's current dashboard settings; user decision "match recording exactly").
# This is the same "pre-select then fire" pattern proven for ProCmdFtOffset consuming a
# pre-selected surface. The recording's tail is `Enter/Exit dashInst0.Quit; Activate
# dashInst0.Done` -- harmless here (no armed collector to discard; the refs are already bound).
# ONE atomic macro. PURE. The two tree-selects in the recording (point + TOP plane) are the
# operator's picks; the caller reproduces them by ID + path (raw-COM CreateModelItemSelection).
#
# -Diameter (user 2026-07-29: "make sure the hole is the correct diameter"): when > 0, the
# CONFIRMED-LIVE diameter widget maindashInst0.diameter_mip_OptionMenu (holeinator's proven
# hole-dashboard tail, lib\conformal_blank.ps1 Build-NormalHoleMacro) is set BEFORE Done, so
# the hole is drilled at the SELECTED diameter instead of inheriting Creo's last dashboard
# value (the wrong-diameter bug). Diameter <= 0 emits NO diameter tokens (keeps the default).
# The tokens go AFTER the dashInst0.Quit blur (which discards the auto-armed collector) and
# BEFORE Done, so the value is typed into a clean dashboard then committed.
# ----------------------------------------------------------------------------
function global:Build-PreselectedHoleMacro {
    param([double]$Diameter = 0.0)
    $diaMacro = if ($Diameter -gt 0) {
        "~ Input  ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu`` ``$Diameter``;" +
        "~ Update ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu`` ``$Diameter``;" +
        "~ Activate ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu``;" +
        "~ FocusOut ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu``;"
    } else { "" }
    return "~ Command ``ProCmdHole``;" +
        "~ Enter ``main_dlg_cur`` ``dashInst0.Quit``;" +
        "~ Exit  ``main_dlg_cur`` ``dashInst0.Quit``;" +
        $diaMacro +
        "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"
}

# ----------------------------------------------------------------------------
# Add-ComponentDefaultPlanesToBuffer - the HANDS-FREE fastener-loop enabler (user:
# "you know TOP/SIDE/FRONT by ID in each part; loop the fasteners and do it all
# yourself"). Given ONE fastener's IpfcComponentPath (from the proven component
# selection -- $sel.Path, creo_geometry.ps1), resolve that component's OWN default
# datum planes (TOP/SIDE/FRONT by Resolve-PlaneRole name) and ACCUMULATE them into
# the selection buffer as PATH-QUALIFIED selections, so ProCmdDatumPointGeneral can
# then intersect them into the fastener's datum point -- no operator Ctrl-click.
#
# TRAVERSAL (all wrapped; NEVER throws -- degrades to Added=0 + Reason):
#   1. $ComponentPath.Leaf IS the fastener's solid model (hole_layout.ps1 proven-live pattern:
#      it calls GetItemById on Path.Leaf directly). Leaf.GetModel() is kept only as a wrapper
#      fallback -- calling it on a solid returns null, which was the fastenerplane-probe miss.
#   2. the component's TOP/SIDE/FRONT default datum planes are ALWAYS feature ids
#      1 / 3 / 5 (fastenerplane-probe.cmd, live 2026-07-27) -> fetch each DIRECTLY via
#      GetItemById(ITEM_FEATURE, 1/3/5). They register as Feature (type 0), NOT
#      ITEM_SURFACE -- a name/surface walk was the old failure mode. A name-match walk
#      remains as a secondary only if the constant ids do not resolve.
#   3. per role plane: cascade a CMpfcSelect factory (same ProgID list as edginator's
#      Select-FeatureById) and CreateModelItemSelection($planeItem, $ComponentPath) --
#      the 2nd arg is the fastener's COMPONENT PATH (NOT $null, unlike the part-scoped
#      Select-FeatureById), which path-qualifies the sub-item into the assembly.
#   4. AddSelection into CurrentSelectionBuffer (Clear first unless -NoClear; the 2nd
#      + 3rd planes accumulate).
#
# CONFIRMED LIVE (fastenerplane-probe.cmd SECTION 3, 2026-07-28): selecting ONE fastener
# component then this by-ID path resolved its 1/3/5 planes (path-qualified) and built the
# datum point (id 959) at the correct location -- the path-qualified component-subitem
# selection WORKS on this build once the leaf model is resolved as Path.Leaf (see the leaf
# resolver above; the earlier .Leaf.GetModel() miss was the only bug). The caller STILL
# canary-gates (a datum POINT / a VersionStamp move) and FALLS BACK to the operator tree-pick
# on a miss (e.g. a non-default fastener), so the by-ID path NEVER regresses the manual flow.
#
# Returns @{ Added=<int>; Roles=@(str Top/Side/Front, add order); Ids=@(int planeIds);
#            Reason=<string> }. Reads only params (does NOT touch the $script:DJ scope,
# so probes + the GUI both call it with explicit handles). ID-only; never .Point.
# ----------------------------------------------------------------------------

# Get-ComSelectFactory - resolve the first working CMpfcSelect factory (the same ProgID
# cascade as edginator's Select-FeatureById; CM*/CC* names are never standalone ProgIDs).
# A NAMED helper so an offline test can shadow it (New-Object -ComObject can't be faked
# reliably). Returns the factory COM object or $null. NEVER throws.
function global:Get-ComSelectFactory {
    foreach ($progId in @('pfcls.pfcSelect','pfcls.MpfcSelect','pfcls.CMpfcSelect','pfcls.pfcSelectClass')) {
        try { $f = New-Object -ComObject $progId; if ($null -ne $f) { return $f } } catch {}
    }
    return $null
}

# ----------------------------------------------------------------------------
# Resolve-ComponentLeafModel - given a fastener's IpfcComponentPath, return its own
# solid model (the model to GetItemById the 1/3/5 planes on). RESOLVED ROBUSTLY
# (fastenerplane-probe.cmd SECTION 3, live 2026-07-28): the old $ComponentPath.Leaf.
# GetModel() returned null on this build -- .Leaf ALREADY IS the solid (hole_layout.ps1
# uses Path.Leaf directly as a model, GetItemById on it, confirmed live), so .GetModel()
# on a solid returns null. Gather BOTH candidates (Leaf-as-model + Leaf.GetModel()) and
# pick the one that resolves the constant plane id 1 (a real fastener model); else the
# first that answers ListItems (so a name-walk can still run). NEVER throws; $null on miss.
# ----------------------------------------------------------------------------
function global:Resolve-ComponentLeafModel {
    param($ComponentPath, $TypeObj)
    if ($null -eq $ComponentPath -or $null -eq $TypeObj) { return $null }
    $cand = @()
    $lf = $null
    try { $lf = $ComponentPath.Leaf } catch { $lf = $null }
    if ($null -ne $lf) {
        $cand += ,$lf
        try { $gm = $lf.GetModel(); if ($null -ne $gm) { $cand += ,$gm } } catch {}
    }
    foreach ($m in $cand) {
        $p1 = $null
        try { $p1 = $m.GetItemById($TypeObj.ITEM_FEATURE, 1) } catch { $p1 = $null }
        if ($null -ne $p1) { return $m }
    }
    foreach ($m in $cand) {
        $ok = $false
        try { $null = $m.ListItems($TypeObj.ITEM_FEATURE); $ok = $true } catch { $ok = $false }
        if ($ok) { return $m }
    }
    return $null
}

# ----------------------------------------------------------------------------
# Select-ComponentPlaneById - path-qualify ONE of a fastener component's datum planes
# (by its constant feature id) into the selection buffer, so an OPEN dashboard collector
# (e.g. the hole's ft_dir direction collector) picks it up. This is the hole-direction
# analog of Add-ComponentDefaultPlanesToBuffer: the fastener's TOP plane (id 1) is the
# hole ORIENTATION reference (operator's recording: direction = the fastener's TOP plane).
# The tree-search select-by-id macros (drilljig_core Get-SelectDatumByIdMacro) CANNOT reach
# an external component's plane (they search the ACTIVE model's tree), so this uses the
# raw-COM path-qualified channel (CreateModelItemSelection(plane, ComponentPath)) -- the
# SAME channel proven live for the point (fastenerplane-probe id 959). NAME-VERIFIED
# (Resolve-PlaneRole(GetName) -eq Role) so a wrong-model plane is rejected. -NoClear adds
# onto an existing selection (default = Clear first, mirroring a tree-click's replace).
# Returns @{ Ok=<bool>; Id=<int>; Reason=<string> }. NEVER throws.
# ----------------------------------------------------------------------------
function global:Select-ComponentPlaneById {
    param($Session, $TypeObj, $ComponentPath, [int]$PlaneId, [string]$Role = '', [switch]$NoClear)
    $res = @{ Ok = $false; Id = 0; Reason = '' }
    if ($null -eq $Session)       { $res.Reason = 'no session'; return $res }
    if ($null -eq $ComponentPath) { $res.Reason = 'no component path'; return $res }
    if ($PlaneId -le 0)           { $res.Reason = 'no plane id'; return $res }
    $compModel = Resolve-ComponentLeafModel -ComponentPath $ComponentPath -TypeObj $TypeObj
    if ($null -eq $compModel) { $res.Reason = 'could not resolve the component leaf model from the path'; return $res }
    $planeItem = $null
    try { $planeItem = $compModel.GetItemById($TypeObj.ITEM_FEATURE, [int]$PlaneId) } catch { $planeItem = $null }
    if ($null -eq $planeItem) { $res.Reason = ("plane feature id {0} not found in the component" -f $PlaneId); return $res }
    # name-verify (guards against a wrong model -- e.g. the assembly, whose id 1 is a different datum).
    if ($Role) {
        $nm = ''; try { $nm = [string]$planeItem.GetName() } catch { $nm = '' }
        $r2 = $null; try { $r2 = Resolve-PlaneRole -Name $nm } catch { $r2 = $null }
        if ($r2 -ne $Role) { $res.Reason = ("plane id {0} name '{1}' does not confirm role {2} (wrong model?)" -f $PlaneId, $nm, $Role); return $res }
    }
    $factory = Get-ComSelectFactory
    if ($null -eq $factory) { $res.Reason = 'CreateModelItemSelection factory unavailable on this build'; return $res }
    $buf = $null
    try { $buf = $Session.CurrentSelectionBuffer() } catch { $buf = $null }
    if ($null -eq $buf) { $res.Reason = 'could not get the current selection buffer'; return $res }
    if (-not $NoClear) { try { $buf.Clear() } catch {} }
    $sel = $null
    try { $sel = $factory.CreateModelItemSelection($planeItem, $ComponentPath) } catch { $sel = $null }
    if ($null -eq $sel) { $res.Reason = 'CreateModelItemSelection returned null'; return $res }
    try { $buf.AddSelection($sel) } catch { $res.Reason = 'AddSelection failed'; return $res }
    $res.Ok = $true; $res.Id = [int]$PlaneId; $res.Reason = ("added plane id {0} ({1})" -f $PlaneId, $Role)
    return $res
}

# ----------------------------------------------------------------------------
# Get-BufferComponentPath - read a FRESH, currently-live IpfcComponentPath out of the
# selection buffer (the first selected item that carries a component path, i.e. a
# path-qualified sub-item like a fastener's datum plane). Returns the path or $null;
# NEVER throws. `function global:` so a WinForms .GetNewClosure() handler can call it.
#
# WHY (workflow root-cause 2026-07-28): the GUI fastener loop stashed $comp.Path -- a raw
# COM IpfcComponentPath handle -- at fastener-select time and carried it across the Add_Click
# closure + many loop iterations + RunMacro/DoEvents pumps. By the hole step that handle no
# longer re-resolves (Resolve-ComponentLeafModel returns null), so Select-ComponentPlaneById
# missed and the operator direction-pick fired. onpointhole-probe.cmd works because it reads
# the path FRESH from the live buffer at the point of use. This helper lets the loop do the
# same: right after this fastener's planes are in the buffer (by-ID auto OR the operator's
# tree-pick), grab a live path from them to feed the hole -- matching the probe's proven
# handle lifetime. A path with >=1 ComponentIds is required (a LOCAL datum point has none).
# ----------------------------------------------------------------------------
function global:Get-BufferComponentPath {
    param($Session)
    if ($null -eq $Session) { return $null }
    try {
        foreach ($sel in @(($Session.CurrentSelectionBuffer()).Contents)) {
            $pp = $null
            try { $pp = $sel.Path } catch { $pp = $null }
            if ($null -eq $pp) { continue }
            $pc = @()
            try { $pc = @($pp.ComponentIds) } catch { $pc = @() }
            if (@($pc).Count -ge 1) { return $pp }
        }
    } catch {}
    return $null
}

function global:Add-ComponentDefaultPlanesToBuffer {
    param($Session, $Model, $TypeObj, $ComponentPath, [switch]$NoClear)
    $res = @{ Added = 0; Roles = @(); Ids = @(); Reason = '' }
    if ($null -eq $Session)       { $res.Reason = 'no session'; return $res }
    if ($null -eq $ComponentPath) { $res.Reason = 'no component path'; return $res }

    # 1) leaf component -> its own solid model (shared robust resolver -- Leaf-as-model,
    # then Leaf.GetModel(); see Resolve-ComponentLeafModel).
    $compModel = Resolve-ComponentLeafModel -ComponentPath $ComponentPath -TypeObj $TypeObj
    if ($null -eq $compModel) { $res.Reason = 'could not resolve the component leaf model from the path (Leaf and Leaf.GetModel both unusable)'; return $res }

    # 2) the component part's default datum planes.
    # PRIMARY (fastenerplane-probe.cmd, live 2026-07-27): a fastener component's default
    # TOP/SIDE/FRONT datum planes are ALWAYS feature ids 1 / 3 / 5 (constant on every
    # fastener the operator selects -- probe dump: type 0=Feature, ss .../Feature(#1|#3|#5)).
    # So fetch them DIRECTLY by id via GetItemById(ITEM_FEATURE, 1/3/5) -- no name-resolution
    # (the name walk was the failure mode; the planes read as Feature, not ITEM_SURFACE).
    $roleWanted = @('Top','Side','Front')
    $roleId     = @{ Top = 1; Side = 3; Front = 5 }
    $picks = @{}       # role -> the plane ModelItem
    foreach ($role in $roleWanted) {
        $it = $null
        try { $it = $compModel.GetItemById($TypeObj.ITEM_FEATURE, [int]$roleId[$role]) } catch { $it = $null }
        if ($null -eq $it) { continue }
        # VERIFY the constant id maps to the EXPECTED role BY NAME. This guards against
        # $compModel having resolved to the WRONG model (e.g. the root ASSEMBLY, whose feature
        # ids 1/3/5 are DIFFERENT datums) -- a wrong-model point would still be created and would
        # FALSELY pass the downstream point canary (it fires a real point, just at the wrong
        # place). If the name does not confirm the role, reject this by-id pick; the name-walk
        # secondary below (and ultimately the manual fallback) still covers a legitimately
        # differently-named fastener. Fastener planes are named TOP/SIDE/FRONT (fastenerplane-probe).
        $nm = ''
        try { $nm = [string]$it.GetName() } catch { $nm = '' }
        $r2 = $null
        try { $r2 = Resolve-PlaneRole -Name $nm } catch { $r2 = $null }
        if ($r2 -eq $role) { $picks[$role] = $it }
    }
    # SECONDARY (only if the constant ids did not resolve, e.g. a non-default fastener):
    # walk the component's features + match TOP/SIDE/FRONT by name.
    if ($picks.Count -lt 3) {
        try {
            foreach ($f in @($compModel.ListItems($TypeObj.ITEM_FEATURE))) {
                $nm = ''
                try { $nm = [string]$f.GetName() } catch { $nm = '' }
                $role = $null
                try { $role = Resolve-PlaneRole -Name $nm } catch { $role = $null }
                if ($null -ne $role -and -not $picks.ContainsKey($role)) { $picks[$role] = $f }
                if ($picks.Count -ge 3) { break }
            }
        } catch {}
    }
    if ($picks.Count -lt 1) { $res.Reason = 'could not resolve the fastener TOP/SIDE/FRONT planes (feature ids 1/3/5 nor a name match)'; return $res }

    # 3) a CMpfcSelect factory (same cascade as edginator's Select-FeatureById), via a
    # named helper so an offline test can shadow it (the repo's proven stub pattern --
    # shadowing New-Object globally would be fragile).
    $factory = Get-ComSelectFactory
    if ($null -eq $factory) { $res.Reason = 'CreateModelItemSelection factory unavailable on this build'; return $res }

    $buf = $null
    try { $buf = $Session.CurrentSelectionBuffer() } catch { $buf = $null }
    if ($null -eq $buf) { $res.Reason = 'could not get the current selection buffer'; return $res }
    if (-not $NoClear) { try { $buf.Clear() } catch {} }

    # 4) path-qualify + accumulate each role plane.
    foreach ($role in $roleWanted) {
        if (-not $picks.ContainsKey($role)) { continue }
        $planeItem = $picks[$role]
        $sel = $null
        try { $sel = $factory.CreateModelItemSelection($planeItem, $ComponentPath) } catch { $sel = $null }
        if ($null -eq $sel) { continue }
        try { $buf.AddSelection($sel) } catch { continue }
        # $plId, NOT $pid -- $PID is a read-only automatic variable (assigning throws).
        $plId = 0
        try { $plId = [int]$planeItem.Id } catch { $plId = 0 }
        $res.Roles += $role
        $res.Ids   += $plId
        $res.Added++
    }
    if ($res.Added -lt 1) { $res.Reason = 'no component plane could be path-qualified into the buffer (CreateModelItemSelection/AddSelection returned nothing)'; return $res }
    # PARTIAL-SELECTION GUARD: a 1- or 2-plane buffer would let ProCmdDatumPointGeneral
    # build a DEGENERATE point (a point on/along 1-2 planes, not the 3-plane intersection)
    # that a VersionStamp/feature canary would FALSELY pass. Only a full 3-plane set is a
    # valid fastener intersection -- so if fewer than 3 path-qualified, CLEAR the buffer and
    # report Added=0 to force the caller's operator-pick fallback. Never a half-selection.
    if ($res.Added -lt 3) {
        try { $buf.Clear() } catch {}
        $partial = ($res.Roles -join '/')
        $res.Added = 0; $res.Roles = @(); $res.Ids = @()
        $res.Reason = ("partial plane set ({0}) - cleared to force the manual fallback (need all 3)" -f $(if ($partial) { $partial } else { '<3' }))
        return $res
    }
    $res.Reason = ("added {0} plane(s): {1}" -f $res.Added, ($res.Roles -join '/'))
    return $res
}

# ----------------------------------------------------------------------------
# Resolve-SelectedPlaneIds - read the selection buffer into datum-plane ids for
# the fastener-plane point. ID-ONLY (never IpfcPoint.Point). Dedups by id; resolves
# a Top/Side/Front role by name best-effort. Returns @{ Ids=@(int); Names=@(str);
# Roles=@(str) }. NEVER throws.
#
# TYPE GATE RELAXED 2026-07-27 (root cause of "fastener planes could not register /
# manual didn't work either"): the old reader ONLY counted an item whose Type ==
# ITEM_SURFACE. But trail.txt.15 (the live run) PROVES a fastener-component datum
# plane selected via the ASSEMBLY TREE builds a point through ProCmdDatumPointGeneral
# just fine -- so a tree-selected component plane does NOT report as ITEM_SURFACE here,
# and the SURFACE-only gate was silently rejecting a valid selection (count read 0 ->
# the loop skipped the fastener -> the point never fired, for BOTH the auto AND the
# manual pick). So this now counts ANY distinct-Id selected item (a COUNT read, not a
# re-selection). The TRUE validator is downstream: ProCmdDatumPointGeneral + the
# ITEM_POINT canary (Resolve-NewDatumPointIds) -- if the buffered refs are not
# 3 intersecting planes, no point appears and the caller reports a miss. So relaxing
# this pre-count can NEVER create a false success; it only stops rejecting valid planes.
# ProCmdDatumPointGeneral consumes whatever refs are buffered; the caller confirms
# >=3 plane-like items, then trusts the point canary.
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# Get-DatumPointIdSet / Resolve-NewDatumPointIds - ID-only ITEM_POINT set diff, the
# canary for "did the fastener point actually get created". Never reads .Point.
# (conformal_blank has the surface/body equivalents; this is the point one.)
# ----------------------------------------------------------------------------
function global:Get-DatumPointIdSet {
    param($Model, $TypeObj)
    $set = @{}
    try { foreach ($p in $Model.ListItems($TypeObj.ITEM_POINT)) { try { $set[[int]$p.Id] = $true } catch {} } } catch {}
    return $set
}
function global:Resolve-NewDatumPointIds {
    param($Model, $TypeObj, $Before)
    $after = Get-DatumPointIdSet -Model $Model -TypeObj $TypeObj
    $new = @()
    foreach ($id in $after.Keys) { if (-not $Before.ContainsKey($id)) { $new += [int]$id } }
    return @($new | Sort-Object)
}

# ----------------------------------------------------------------------------
# Invoke-FastenerPoint - fire Build-FastenerPointMacro on the ALREADY-BUFFERED 3
# planes and report ROBUST evidence that a datum point was created. NEVER throws.
#
# WHY NOT JUST the ITEM_POINT diff: fastenerplane-probe.cmd (live 2026-07-27) proved
# the point IS created BUT it lands in the drilljig PART while the ACTIVE model is the
# ASSEMBLY -- and $model.ListItems(ITEM_POINT) on an assembly returns 0 (the known
# assembly-enumeration limit). So a point-id diff alone reports a FALSE MISS. The
# VersionStamp DOES move when the point commits, so this treats EITHER signal as
# success: a new ITEM_POINT id (when the active model is the part) OR a VersionStamp
# change (when it is the assembly). Returns:
#   @{ Created=<bool>; PointId=<int 0 if unreadable>; ViaStamp=<bool>; Reason=<string> }
# PointId is the new point id when the diff could read it (part-active), else 0 -- the
# caller uses PointId>0 for the hole placement ref if it has one, else relies on the
# point staying selected after stdbtn_1 (the recording's behavior). -OnPoll pumps DoEvents.
# ----------------------------------------------------------------------------
function global:Invoke-FastenerPoint {
    param($Session, $Model, $TypeObj, [scriptblock]$OnPoll = $null, [int]$TimeoutMs = 30000)
    $res = @{ Created = $false; PointId = 0; ViaStamp = $false; Reason = '' }
    $ptBefore = Get-DatumPointIdSet -Model $Model -TypeObj $TypeObj
    $stamp = $null; try { $stamp = $Model.VersionStamp } catch {}
    try { $Session.RunMacro((Build-FastenerPointMacro)) }
    catch { $res.Reason = "point macro error: $($_.Exception.Message)"; return $res }

    # signal 1: a new ITEM_POINT id (works when the active model is the PART).
    $newPts = @(Resolve-NewDatumPointIds -Model $Model -TypeObj $TypeObj -Before $ptBefore)
    if (@($newPts).Count -ge 1) {
        $res.Created = $true; $res.PointId = [int]$newPts[-1]; $res.Reason = 'point created (new ITEM_POINT id)'
        return $res
    }
    # signal 2: a VersionStamp move (works when the active model is the ASSEMBLY, where
    # ListItems(ITEM_POINT) is blind -- the point still lands in the drilljig part).
    if ($null -ne $stamp) {
        $moved = $false
        try { $moved = Wait-ModelModified -Model $Model -PreviousStamp $stamp -TimeoutMs $TimeoutMs -OnPoll $OnPoll } catch { $moved = $false }
        if ($moved) { $res.Created = $true; $res.ViaStamp = $true; $res.Reason = 'point created (VersionStamp moved; point id not enumerable on the assembly)'; return $res }
    }
    $res.Reason = 'no datum point evidence (no new point id AND no VersionStamp change)'
    return $res
}

# ----------------------------------------------------------------------------
# Invoke-FastenerHole - fire the ON-POINT hole by PRE-SELECTING BOTH references (the datum
# POINT + the fastener's TOP plane) BEFORE ProCmdHole, exactly like the operator's
# 'holeexctrude' recording (2026-07-28), then CANARY on a new hole FEATURE. NEVER throws.
# `function global:` so the GUI's Add_Click CLOSURE only ever calls a GLOBAL function (the
# closure-scope rule -- Get-FeatureIdSet / Wait-ModelModified are non-global in drilljig_core).
#
# The recording selects the datum point AND the fastener's TOP plane TOGETHER in the tree,
# THEN fires ProCmdHole + Done -- ProCmdHole auto-assigns them by type (point -> on-point
# PLACEMENT, plane -> normal ORIENTATION). NO collector arming, NO placement-page triggers.
# This is the "pre-select then fire" pattern proven for ProCmdFtOffset. We reproduce the two
# tree picks by ID: the local point (path=$null) + the TOP plane (id 1, path-qualified).
#
# FLOW (canary-gated; the operator-add-plane pause is a strict last resort -> no regression):
#   1. Clear the buffer + raw-COM select the local datum POINT (placement).
#   2. ACCUMULATE (-NoClear) the fastener TOP plane (Select-ComponentPlaneById, id 1,
#      path-qualified) so the buffer holds BOTH refs. Retry once on a miss.
#   3. If the plane could not be staged by ID, run the injected -DirectionPrompt so the operator
#      Ctrl-clicks the TOP plane onto the point (fallback only).
#   4. RunMacro(Build-PreselectedHoleMacro) -> ProCmdHole consumes both refs + Done.
#   5. CANARY: a new hole FEATURE (VersionStamp corroborating); never tally on a miss.
#
#   -PointId        the fastener datum point id (Invoke-FastenerPoint). >0 for the pre-select.
#   -ComponentPath  the fastener's IpfcComponentPath (FRESH from the buffer -- Get-BufferComponentPath).
#   -TopPlaneId     the fastener's TOP datum-plane feature id (constant 1). The orientation ref.
#   -Diameter       the SELECTED hole diameter (in). >0 sets it via the confirmed-live widget so
#                   the hole is drilled at the right size; <=0 keeps Creo's default (see the macro).
#   -DirectionPrompt operator fallback (AskInline NoActivate) fired only if the by-id plane misses.
# Returns @{ Drilled=<bool>; ViaPlane=<bool>; Reason=<string> }. -OnPoll pumps DoEvents.
# ----------------------------------------------------------------------------
function global:Invoke-FastenerHole {
    param(
        $Session, $Model, $TypeObj,
        [int]$PointId = 0, $ComponentPath = $null, [int]$TopPlaneId = 1,
        [double]$Diameter = 0.0,
        [scriptblock]$DirectionPrompt = $null,
        [scriptblock]$OnPoll = $null, [int]$TimeoutMs = 30000
    )
    $res = @{ Drilled = $false; ViaPlane = $false; Reason = '' }
    $featBefore = Get-FeatureIdSet
    $stamp = $null; try { $stamp = $Model.VersionStamp } catch {}

    # 1) PLACEMENT: clear the buffer + select the local datum POINT (path=$null).
    $ptOk = $false
    if ($PointId -gt 0 -and $null -ne $Model -and $null -ne $TypeObj) {
        try {
            $ptItem = $Model.GetItemById($TypeObj.ITEM_POINT, [int]$PointId)
            $factory = Get-ComSelectFactory
            if ($null -ne $ptItem -and $null -ne $factory) {
                $buf = $Session.CurrentSelectionBuffer()
                if ($null -ne $buf) {
                    try { $buf.Clear() } catch {}
                    $psel = $factory.CreateModelItemSelection($ptItem, $null)   # local point, no path
                    if ($null -ne $psel) { $buf.AddSelection($psel); $ptOk = $true }
                }
            }
        } catch { $ptOk = $false }
    }

    # 2) ORIENTATION: ACCUMULATE the fastener TOP plane (id 1, path-qualified) onto the point
    # (-NoClear) so the buffer holds BOTH refs. Retry once on a transient miss.
    $planeOk = $false
    if ($ptOk -and $null -ne $ComponentPath -and $TopPlaneId -gt 0) {
        for ($attempt = 1; ($attempt -le 2) -and (-not $planeOk); $attempt++) {
            try {
                $pf = Select-ComponentPlaneById -Session $Session -TypeObj $TypeObj -ComponentPath $ComponentPath -PlaneId $TopPlaneId -Role 'Top' -NoClear
                if ($null -ne $pf -and $pf.Ok) { $planeOk = $true; $res.ViaPlane = $true }
            } catch { $planeOk = $false }
        }
    }

    # 3) FALLBACK: if the plane could not be staged by ID, let the operator Ctrl-click this
    # fastener's TOP plane (ADDING it to the already-selected point). Strict last resort.
    if ($ptOk -and (-not $planeOk) -and $null -ne $DirectionPrompt) { try { & $DirectionPrompt } catch {} }

    # PUMP so Creo/WinForms processes the pre-selection before ProCmdHole reads it.
    if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }

    # 4) fire ProCmdHole on the PRE-SELECTED [point, TOP plane] + commit (Done). Set the
    # SELECTED diameter so the hole is drilled at the right size (not Creo's last value).
    try { $Session.RunMacro((Build-PreselectedHoleMacro -Diameter ([double]$Diameter))) }
    catch { $res.Reason = "hole macro error: $($_.Exception.Message)"; return $res }

    # 5) canary: a NEW hole FEATURE must appear (VersionStamp move is corroborating).
    if ($null -ne $stamp) { try { [void](Wait-ModelModified -Model $Model -PreviousStamp $stamp -TimeoutMs $TimeoutMs -OnPoll $OnPoll) } catch {} }
    $afterFeat = Get-FeatureIdSet
    $newFeats = @($afterFeat.Keys | Where-Object { -not $featBefore.ContainsKey($_) })
    if (@($newFeats).Count -ge 1) { $res.Drilled = $true; $res.Reason = 'hole feature created' }
    else { $res.Reason = 'no new hole feature appeared (model unchanged)' }
    return $res
}

function global:Resolve-SelectedPlaneIds {
    param($Session, $TypeObj)
    $ids = @(); $names = @(); $roles = @(); $seen = @{}
    $contents = $null
    try { $contents = ($Session.CurrentSelectionBuffer()).Contents } catch {}
    if ($null -eq $contents) { return @{ Ids=@(); Names=@(); Roles=@() } }
    foreach ($item in $contents) {
        $si = $null
        try { $si = $item.SelItem } catch { continue }
        if ($null -eq $si) { continue }
        $id = $null
        try { $id = [int]$si.Id } catch {}
        if ($null -eq $id -or $seen.ContainsKey($id)) { continue }
        # Count ANY distinct-Id selected item (a tree-selected component datum plane may
        # NOT report as ITEM_SURFACE on this build -- trail.txt.15 proves it still builds
        # a point). The point canary downstream is the real validator, so this is a plain
        # COUNT + provenance read. Skip only obvious non-geometry (no readable Id above).
        $seen[$id] = $true
        $nm = ''
        try { $nm = [string]$si.GetName() } catch {}
        $role = $null
        try { $role = Resolve-PlaneRole -Name $nm } catch {}
        $ids += $id; $names += $nm; $roles += $(if ($null -ne $role) { $role } else { '' })
    }
    return @{ Ids=@($ids); Names=@($names); Roles=@($roles) }
}
