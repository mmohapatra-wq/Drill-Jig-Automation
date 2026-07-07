# ============================================================================
# lib\orthogrid_points.ps1 - create / resolve the orthogrid datum-point grid
# ============================================================================
# Dot-source from a hybrid .cmd AFTER lib\orthogrid.ps1 (Get-OrthogridGeometry).
# The macro builder calls Get-SelectByIdMacro, which the CONSUMING .cmd defines
# (drilljig.cmd) - dot-sourcing puts every function in one scope, and PowerShell
# resolves a call at invocation time, so Build-PointGridMacro resolves it as long
# as the .cmd defined it before the macro is fired. The offline tests stub it.
#
# ID-ONLY throughout: these reads touch $p.Id and NOTHING else - never
# $p.Point coordinates (reading IpfcPoint.Point crashed holeinator live; see
# CLAUDE.md holeinator "History / why ID-only").
#
# ORCHESTRATION CONTRACT (the drilljig STAGE 2.5 driver follows this):
#   1. Compute the grid with Get-OrthogridGeometry (the EXACT shared shape).
#   2. TRY the auto-macro: snapshot ITEM_POINT ids -> fire Build-PointGridMacro
#      inside a VersionStamp canary -> Resolve-NewPointIds to diff.
#   3. VERIFY: model changed (VersionStamp) AND new-point-count == grid.Count.
#   4. On ANY miss (no change / wrong count / macro error) FALL THROUGH to the
#      GUARANTEED manual path (Invoke-ManualPointGrid). NEVER silently proceed
#      with zero points -- a zero-point hand-off would drill nothing and say "Done".
# ============================================================================


# ----------------------------------------------------------------------------
# Get-PointIdSet -- snapshot every datum-point id currently in the model as a
# hashtable set. Returns @{} (empty set) on any enumeration failure -- never
# throws. ID only -- never $p.Point.
# ----------------------------------------------------------------------------
function Get-PointIdSet {
    param($Model, $TypeObj)
    $set = @{}
    try {
        $items = $Model.ListItems($TypeObj.ITEM_POINT)
        if ($null -ne $items) {
            foreach ($p in $items) {
                $id = $null
                try { $id = [int]$p.Id } catch { continue }   # ID only -- never .Point
                $set[$id] = $true
            }
        }
    } catch {}
    return $set
}

# ----------------------------------------------------------------------------
# Resolve-NewPointIds -- diff the current ITEM_POINT set against a prior snapshot
# ($Before) and return the @(new int ids), de-duped, sorted ascending for stable
# output.
#   $before = Get-PointIdSet -Model $model -TypeObj $pfcType
#   <run a creation action: a macro, or a manual hand-create + ENTER>
#   $newIds = Resolve-NewPointIds -Model $model -TypeObj $pfcType -Before $before
# ----------------------------------------------------------------------------
function Resolve-NewPointIds {
    param($Model, $TypeObj, $Before)
    $after = Get-PointIdSet -Model $Model -TypeObj $TypeObj
    $new = @()
    $seen = @{}
    foreach ($id in $after.Keys) {
        if ($Before.ContainsKey($id)) { continue }
        $iid = [int]$id
        if ($seen.ContainsKey($iid)) { continue }
        $seen[$iid] = $true
        $new += $iid
    }
    return @($new | Sort-Object)
}


# ----------------------------------------------------------------------------
# Build-PointGridMacro
#
# *** UNVERIFIED -- BEST-GUESS WIDGET NAMES. THIS MACRO HAS NOT BEEN RECORDED   ***
# *** LIVE. Treat exactly like Build-ReliefHoleMacro: try it, gate it on a      ***
# *** VersionStamp canary + exact new-point COUNT, and fall through to the      ***
# *** manual path on ANY miss. DO NOT trust it until the recipe below is run.   ***
#
# WHAT IT TRIES TO DO: create the whole grid as ONE "Offset Coordinate System"
# datum-point feature -- the dialog that lets you type a table of points, each
# an (X, Z) offset from a reference, so N points become ONE feature with no
# screen picks. The reference is the SIDE base/default datum (the plate FACE the
# holes drill into); the two in-plane offset directions are the TOP and FRONT
# datums. (A *sketched* datum point would need a screen pick per point, which a
# RunMacro cannot drive -- that is why the offset-table feature is the target.)
#
# WHY THE PROGRAMMATIC ROUTE IS NOT USED: IpfcSolid.CreateFeature is "not
# implemented" on this build (CLAUDE.md holeinator), so IpfcDatumPointFeat /
# IpfcDatumPointPlacementConstraint cannot be instantiated -- the mapkey is the
# only lever, hence this guessed macro.
#
# GUESSED WIDGET NAMES (every one of these must be confirmed live -- the proven
# fragments are ONLY the leading Get-SelectByIdMacro tree-search select-by-ID
# and the atomic-RunMacro/double-backtick escaping; everything inside the datum-
# point dialog is a guess):
#   Command                       `ProCmdDatumPoint`  (datum point tool; may be `ProCmdDatumPointOffCsys`)
#   Dialog                        `Odui_Dlg_00`       (same family as nodelator's paste dialog)
#   Point-type / offset-csys tab  `t1.PntTypeOptMenu` value `Offset Coordinate System`
#   Direction references          `t1.DirRefList`     (TOP=X, FRONT=Z -- may be two collectors)
#   Points table                  `t1.pnt_table`      (the editable X/Z grid)
#   Add-row button                `t1.add_pnt_btn`    (append a new table row)
#   Per-row X cell column key     `xax_axis`          (the TOP-direction offset)
#   Per-row Z cell column key     `zax_axis`          (the FRONT-direction offset)
#   OK button                     `stdbtn_1`          (confirmed elsewhere as the datum-dialog OK)
#
# *** RECORD-LIVE RECIPE to replace these guesses (do this ONCE, then transcribe
#     the real widget names below and delete this UNVERIFIED banner):
#   1. In Creo: set  visible_mapkeys = yes  (Configuration Editor / config.pro),
#      Apply -- every widget interaction is then echoed into the trail file.
#   2. Tools > Trail/Training Files -- note the active trail.txt.N path.
#   3. Pre-select the SIDE base datum plane in the model tree (the FACE).
#   4. Model > Datum > Point > Offset Coordinate System (the TABLE variant).
#      Pick the SIDE datum as the placement reference and TOP/FRONT as the two
#      offset directions; switch the dropdown to "Cartesian".
#   5. Add a row, type a known X and Z (e.g. 1.0 / 2.0). Add a SECOND row with a
#      different X/Z so the row index + column tokens are unambiguous. Click OK.
#   6. Open the newest trail.txt.* and copy every `~ Command` / `~ Select` /
#      `~ Open` / `~ Close` / `~ Update` / `~ Input` / `~ Activate` / `~ Trigger`
#      line from steps 4-5 (drop `~ Trail` / `~ Timer` / `~ Move` noise).
#   7. Replace the guessed tokens below with the recorded ones, keeping the whole
#      open->table->OK as ONE concatenated RunMacro string, and the leading
#      Get-SelectByIdMacro select-by-ID of the SIDE base datum.
#   8. Re-run drilljig; the canary + exact-count gate confirms it took.
#
# PARAMETERS:
#   -Points        : the Get-OrthogridGeometry.Points array (each {I;J;X;Z}); X
#                    is the TOP-direction offset, Z is the FRONT-direction offset
#                    (both measured from the plate corner -- (Edge,Edge) is pt 1).
#   -SideBaseId    : SIDE base/default datum feature id -- the plate FACE the
#                    points lie on / the holes drill into.
#   -TopBaseId     : TOP  base datum id  (in-plane X / "horizontal" direction ref)
#   -FrontBaseId   : FRONT base datum id (in-plane Z / "vertical"   direction ref)
#
# Returns ONE atomic RunMacro string (the whole feature in a single call -- a
# dashboard/dialog's command context does NOT survive across RunMacro calls;
# CLAUDE.md boxinator lesson). Double-backticks escape the literal backticks
# Creo wants around widget tokens, exactly as Build-HoleMacro does.
# ----------------------------------------------------------------------------
function Build-PointGridMacro {
    param(
        [array]$Points,
        [int]$SideBaseId,
        [int]$TopBaseId,
        [int]$FrontBaseId
    )

    # Open: select the SIDE base datum BY ID (proven tree-search fragment; its
    # buffer_clean wipes any stale selection), then open the datum-point tool so
    # the dialog comes up with that reference pre-loaded.
    $macro =
        (Get-SelectByIdMacro -FeatId $SideBaseId) +
        "~ Command ``ProCmdDatumPoint``;" +
        # GUESS: switch the point type to the offset-coordinate-system table mode
        "~ Open  ``Odui_Dlg_00`` ``t1.PntTypeOptMenu``;" +
        "~ Close ``Odui_Dlg_00`` ``t1.PntTypeOptMenu``;" +
        "~ Select ``Odui_Dlg_00`` ``t1.PntTypeOptMenu`` 1 ``Offset Coordinate System``;" +
        # GUESS: hand the two in-plane direction references (TOP=X, FRONT=Z).
        "~ Update ``Odui_Dlg_00`` ``t1.DirRefList`` ``$TopBaseId``;" +
        "~ Update ``Odui_Dlg_00`` ``t1.DirRefList`` ``$FrontBaseId``;"

    # One table row per grid point. X = TOP-direction offset, Z = FRONT-direction
    # offset (both from the plate corner; Get-OrthogridGeometry already computed
    # them as Edge + I*CcX / Edge + J*CcZ). GUESS: add a row, then write its X
    # and Z cells by (row,column) trigger.
    $row = 0
    foreach ($pt in $Points) {
        $x = ([double]$pt.X)
        $z = ([double]$pt.Z)
        $macro +=
            "~ Activate ``Odui_Dlg_00`` ``t1.add_pnt_btn``;" +
            "~ Update  ``Odui_Dlg_00`` ``t1.pnt_table`` $row ``xax_axis`` ``$x``;" +
            "~ Update  ``Odui_Dlg_00`` ``t1.pnt_table`` $row ``zax_axis`` ``$z``;"
        $row++
    }

    # OK -- commit the whole feature. stdbtn_1 is the datum-dialog OK confirmed
    # by New-OffsetPlane (same Odui_Dlg_00 family).
    $macro += "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;"
    return $macro
}


# ============================================================================
# CREO DIRECTION PATTERN -- transcribed from the user's WORKING mapkey (2026-06-24)
# ============================================================================
# The decisive fact from that recording: the per-direction REFERENCE is a
# @PAUSE_FOR_SCREEN_PICK -- the operator clicks each direction's reference
# (edge/plane/axis) in the graphics window. A RunMacro CANNOT screen-pick, so the
# pattern CANNOT be one atomic macro; it MUST be SPLIT into RunMacro phases around
# the user's picks, exactly like the box build splits around the rough-rectangle
# draw (a dashboard survives a pause while the user interacts with the graphics
# window). The earlier by-id reference feed (Get-SelectDatumByIdMacro) was WRONG --
# it cannot substitute for the pick and its mid-dashboard tree-search clobbered the
# value fields (the "spacings defaulted" bug). Values are set DIRECTLY (no clear):
# Input -> Update -> Activate -> FocusOut. Field order per the recording: count
# (num_inst) then spacing (incr).
#
# RECORDED WIDGETS (CONFIRMED by the user's full pattern mapkey, 2026-07-07):
#   ~ Select `main_dlg_cur` `PHTLeft.AssyTree` 1 `<node>`;   <- seed SELECTED FIRST
#   ~ Command `ProCmdGeomPattern`;
#   ~ Trigger `maindashInst0.ui_pat_dir_dir1` `0`; ~ Trigger `...ui_pat_dir_dir1` ``;
#   [PAUSE: pick the dir-1 direction reference]
#   ~ Activate `maindashInst0.ui_pat_dir_1_flip`;            <- OPTIONAL direction flip
#   ~ Input/Update/Activate/FocusOut `maindashInst0.ui_pat_dir_1_num_inst` <count>;
#   ~ Input/Update/Activate/FocusOut `maindashInst0.ui_pat_dir_1_incr`     <spacing>;
#   ~ Activate `main_dlg_cur` `dashInst0.stdbtn_1`;          <- confirm
# (The recording's dir-2 block is a 2-D pattern; slotinator uses ONE direction.)
#
# THE FIX for "the pattern tool opens but nothing is selected" (user 2026-07-07):
# the seed feature must be SELECTED BEFORE ProCmdGeomPattern - the recording clicks
# it in the model tree. A search-dialog buffer selection does NOT register as the
# pattern's target here. So Build-PatternArmMacro no longer search-selects; the
# caller has the OPERATOR select the seed (one tree/graphics click) first, exactly
# like the recording. (-FeatId is kept optional for a future auto-select attempt.)
#
# PHASE ORDER (caller fires these as separate RunMacros with a user pick between,
# mirroring the recording):
#   [operator selects the seed feature in the model tree]
#   A. Build-PatternArmMacro     -> open pattern on the selected seed, activate the
#                                   dir-1 collector.  [PAUSE: user picks dir-1 ref]
#   B. Build-PatternValuesMacro  -> (optional dir-1 flip) + dir-1 count+spacing; if a
#                                   2nd direction, set dir-2 count+spacing AND activate
#                                   the dir-2 collector.  [PAUSE: user picks dir-2 ref]
#   C. Build-PatternConfirmMacro -> dashInst0.stdbtn_1.
# For a 1-direction grid the caller omits dir-2 and the 2nd pause.
# ----------------------------------------------------------------------------

# Set one dashboard value field directly (NO clear -- the recording does not clear):
# Input -> Update -> Activate -> FocusOut. The trailing Activate+FocusOut commit it.
function Get-SetFieldMacro {
    param([string]$Widget, $Value)
    return "~ Input  ``main_dlg_cur`` ``$Widget`` ``$Value``;" +
           "~ Update ``main_dlg_cur`` ``$Widget`` ``$Value``;" +
           "~ Activate ``main_dlg_cur`` ``$Widget``;" +
           "~ FocusOut ``main_dlg_cur`` ``$Widget``;"
}

# PHASE A: open the Direction pattern on the ALREADY-SELECTED seed feature, and
# activate the dir-1 reference collector so the dialog waits for the user's dir-1
# pick. The seed MUST be selected first (the caller has the operator click it in the
# model tree - matching the recording's `~ Select PHTLeft.AssyTree`). Passing
# -FeatId prepends a search-by-ID select, but that channel did NOT register as the
# pattern target live (2026-07-07), so the caller normally omits it.
function Build-PatternArmMacro {
    param([int]$FeatId = 0)
    $sel = if ($FeatId -gt 0) { (Get-SelectByIdMacro -FeatId $FeatId) } else { "" }
    return $sel +
        "~ Command ``ProCmdGeomPattern``;" +
        "~ Trigger ``main_dlg_cur`` ``maindashInst0.ui_pat_dir_dir1`` ``0``;" +
        "~ Trigger ``main_dlg_cur`` ``maindashInst0.ui_pat_dir_dir1`` ````;"
}

# PHASE B: with the dir-1 reference now picked, set dir-1 count + spacing. -Flip1
# prepends the recorded direction flip (maindashInst0.ui_pat_dir_1_flip) for a part
# whose copies would otherwise march off the plate. If a 2nd direction is requested
# (-Count2 > 1), also set dir-2 count + spacing and ACTIVATE the dir-2 collector (so
# the dialog then waits for the user's dir-2 pick). Values only -- references are
# picked by the user around this macro.
function Build-PatternValuesMacro {
    param(
        [int]$Count1,
        [double]$Spacing1,
        [switch]$Flip1,
        [int]$Count2 = 0,
        [double]$Spacing2 = 0.0
    )
    # optional direction-1 flip (recorded: ~ Activate maindashInst0.ui_pat_dir_1_flip)
    $macro = if ($Flip1) { "~ Activate ``main_dlg_cur`` ``maindashInst0.ui_pat_dir_1_flip``;" } else { "" }
    # dir-1: count (num_inst) then spacing (incr), per the recording.
    $macro +=
        (Get-SetFieldMacro -Widget "maindashInst0.ui_pat_dir_1_num_inst" -Value $Count1) +
        (Get-SetFieldMacro -Widget "maindashInst0.ui_pat_dir_1_incr"     -Value $Spacing1)

    if ($Count2 -gt 1) {
        # dir-2 values FIRST, then activate the dir-2 collector for the next pick.
        $macro +=
            (Get-SetFieldMacro -Widget "maindashInst0.ui_pat_dir_2_num_inst" -Value $Count2) +
            (Get-SetFieldMacro -Widget "maindashInst0.ui_pat_dir_2_incr"     -Value $Spacing2) +
            "~ Trigger ``main_dlg_cur`` ``maindashInst0.ui_pat_dir_dir2`` ``0``;" +
            "~ Trigger ``main_dlg_cur`` ``maindashInst0.ui_pat_dir_dir2`` ````;"
    }
    return $macro
}

# PHASE C: confirm the pattern.
function Build-PatternConfirmMacro {
    return "~ Activate ``main_dlg_cur`` ``dashInst0.stdbtn_1``;"
}

# ============================================================================
# Build-IntersectPointMacro -- create a datum point at the INTERSECTION of 3
# mutually-perpendicular planes, ALL fed BY ID. The PRIMARY point-creation method
# for drilljig's orthogrid (STAGE 2.5): Nx+Nz offset planes are created, then
# each grid point = intersect(face, X-plane, Z-plane).
#
# ALL WIDGETS CONFIRMED LIVE (point-probe.cmd, 2026-06-24):
#   - 1st plane selected via Get-SelectByIdMacro (buffer_clean clears stale selection).
#   - 2nd/3rd planes: Get-SelectByIdMacro -NoClear (ACCUMULATE into the buffer).
#   - ProCmdDatumPointGeneral (consumes all 3 from the buffer).
#   - stdbtn_1 (OK → creates the intersection point, no picks, no offset widgets).
# The 3 planes must be mutually perpendicular (the default datums + their offset
# planes satisfy this). ONE atomic RunMacro string. No dashboard-survival issue.
#
# PARAMETERS:
#   -PlaneIds [int[]] : exactly 3 plane feature IDs to intersect (order: face, X, Z).
#
# Returns ONE atomic RunMacro string. Calls Get-SelectByIdMacro (consuming .cmd's
# definition at fire time, same dot-source scope pattern).
# ============================================================================
function Build-IntersectPointMacro {
    param([int[]]$PlaneIds)
    # 1st plane: buffer_clean (clear stale); 2nd/3rd: -NoClear (accumulate).
    $m = (Get-SelectByIdMacro -FeatId $PlaneIds[0])
    for ($i = 1; $i -lt $PlaneIds.Count; $i++) {
        $m += (Get-SelectByIdMacro -FeatId $PlaneIds[$i] -NoClear)
    }
    $m += "~ Command ``ProCmdDatumPointGeneral``;" +
          "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;"
    return $m
}

# (Build-EdgePlanePointMacro REMOVED 2026-06-25: feeding ProCmdDatumPointGeneral an
# EDGE selected by ID does NOT load on this imported/foreign body -- the trail
# showed the point dialog opening EMPTY ("Select up to 3 references...") then
# cancelled, every time, exactly as the edginator find-tool-dead-for-edges wall
# predicts. The chip-relief PATH points are now built with the PROVEN 3-plane
# intersection (Build-IntersectPointMacro): SIDE face + a pitch plane + the
# user-clicked BOUNDARY plane the edge lies on -- all Feature-type planes, which DO
# load. The picked edge is used only to AUTO-DETECT the axis (Resolve-EdgeAxis, by
# length) and is never fed to the datum-point dialog. See drilljig STAGE 6.)

# ============================================================================
# Get-SharedPlanePlan -- the PURE plane-sharing plan for ANY point set.
#
# Generalises drilljig STAGE 2.5's regular-grid plane sharing (1 face + Nx
# X-planes + Nz Z-planes -> Nx*Nz intersection points) to an ARBITRARY list of
# {X;Z} points, so the SAME create-planes-then-intersect engine serves BOTH the
# orthogrid and the custom (irregular) point modes. Pure math: no COM, no state,
# NEVER throws.
#
# What it computes:
#   * the DISTINCT X offsets across all points (tolerance-deduped, sorted asc)
#   * the DISTINCT Z offsets likewise
#   * per input point, the INDEX of its X into XCoords and Z into ZCoords
# The caller then creates ONE plane per distinct coordinate (reusing a base datum
# when the offset is ~0, point-probe's proven trick) and intersects, per point,
# face + XPlane[Xi] + ZPlane[Zi]. Sharing planes is what keeps an N-point job to
# (distinctX + distinctZ) planes instead of 3*N.
#
# Inputs:
#   Points - array of objects each exposing .X and .Z (doubles). Malformed
#            entries (no numeric X/Z) are SKIPPED, never throw; Triples then has
#            one fewer entry, which the caller can detect against Points.Count.
#   Tol    - two coordinates within Tol collapse to ONE shared plane (default 1e-6).
#
# Returns [pscustomobject]:
#   XCoords [double[]] distinct X offsets, ascending
#   ZCoords [double[]] distinct Z offsets, ascending
#   Triples [array] of [pscustomobject]@{ X; Z; Xi; Zi } - Xi indexes XCoords,
#           Zi indexes ZCoords; in input order (skipping malformed points).
#
# ORTHOGRID EQUIVALENCE (must hold so the live-confirmed path is unchanged): for a
# regular grid the distinct X offsets ARE {Edge, Edge+CcX, ...} ascending and a
# point with grid column I lands at XCoords index I (same for J/Z). With Edge>0 no
# coordinate is ~0, so every distinct coord becomes a created plane exactly as the
# original Nx/Nz derivation did -- identical planes, identical intersections.
# global: scope (see Get-OrthogridGeometry note) so closures resolve it under the
# hybrid .cmd scriptblock::Create model. Pure + idempotent.
# ============================================================================
function global:Get-SharedPlanePlan {
    param(
        [array]$Points,
        [double]$Tol = 1e-6
    )

    # gather clean (x,z) pairs; skip anything without numeric X/Z (no throw).
    $pairs = @()
    if ($null -ne $Points) {
        foreach ($pt in $Points) {
            # Explicit null-check BEFORE coercion: [double]$null silently yields 0.0,
            # so a point missing .X/.Z would otherwise sneak in as (0,0) instead of
            # being skipped. A legit 0 coordinate has $pt.X -ne $null, so it survives.
            $x = $null; $z = $null
            try { if ($null -ne $pt.X) { $x = [double]$pt.X } } catch {}
            try { if ($null -ne $pt.Z) { $z = [double]$pt.Z } } catch {}
            if ($null -eq $x -or $null -eq $z) { continue }
            $pairs += [pscustomobject]@{ X = [double]$x; Z = [double]$z }
        }
    }

    # build a tolerance-deduped, ascending distinct-coordinate list from a set of
    # scalars. Each value is added only if it differs from the last kept value by
    # more than Tol (works because the input is sorted first).
    $buildDistinct = {
        param([double[]]$Vals)
        $out = @()
        foreach ($v in (@($Vals) | Sort-Object)) {
            if ($out.Count -eq 0 -or [math]::Abs([double]$v - [double]$out[$out.Count - 1]) -gt $Tol) {
                $out += [double]$v
            }
        }
        return ,@($out)
    }

    $xCoords = & $buildDistinct (@($pairs | ForEach-Object { [double]$_.X }))
    $zCoords = & $buildDistinct (@($pairs | ForEach-Object { [double]$_.Z }))

    # index a scalar into a distinct list by nearest-within-Tol (returns -1 if none,
    # which cannot happen for a value that came from the same set, but is handled).
    $indexOf = {
        param([double[]]$Coords, [double]$V)
        for ($k = 0; $k -lt $Coords.Count; $k++) {
            if ([math]::Abs([double]$Coords[$k] - $V) -le $Tol) { return $k }
        }
        return -1
    }

    $triples = @()
    foreach ($p in $pairs) {
        $xi = & $indexOf $xCoords ([double]$p.X)
        $zi = & $indexOf $zCoords ([double]$p.Z)
        $triples += [pscustomobject]@{ X = [double]$p.X; Z = [double]$p.Z; Xi = [int]$xi; Zi = [int]$zi }
    }

    # $xCoords/$zCoords are already proper arrays (the leading comma INSIDE
    # $buildDistinct protected the single-element case through the call). Assign
    # them with @(...) only -- a second ,@(...) here would NEST the array (a
    # property assignment never enumerates, so the inner-comma protection isn't
    # needed and the extra comma is a bug).
    return [pscustomobject]@{
        XCoords = @($xCoords)
        ZCoords = @($zCoords)
        Triples = @($triples)
    }
}

# ----------------------------------------------------------------------------
# Get-PatternExpectedNewPoints -- how many NEW datum points a Direction pattern
# of one seed should ADD. A 2-direction Nx*Nz pattern has Nx*Nz total members but
# the seed is member (1,1) and already existed, so the diff against a pre-seed-
# pattern snapshot is Nx*Nz - 1. This is the exact-count the pattern gate uses
# (vs. Build-PointGridMacro's offset-table path, which creates ALL Nx*Nz fresh).
# Returns 0 for an empty/degenerate grid (caller treats <=0 as "nothing to gate").
# ----------------------------------------------------------------------------
function Get-PatternExpectedNewPoints {
    param([int]$Nx, [int]$Nz)
    $total = $Nx * $Nz
    $new = $total - 1
    if ($new -lt 0) { return 0 }
    return $new
}


# ----------------------------------------------------------------------------
# Show-OrthogridTable -- print the grid as a readable table: point #, (I,J),
# corner-offset X/Z. The offsets ARE measured from the plate corner origin
# (Edge,Edge)=first point per the grid contract. $Geo is a Get-OrthogridGeometry
# result. Returns nothing.
# ----------------------------------------------------------------------------

# ----------------------------------------------------------------------------
# Resolve-SeedPoint -- read the ONE seed datum point the user just created and
# return @{ PointId; FeatId } (or $null if none/ambiguous). The rectangular
# pattern needs the seed's owning FEATURE id (to select + pattern it) and its
# datum-POINT id (so the seed itself counts as one of the final grid points).
# ID-ONLY: never reads .Point coordinates. Resolution mirrors STAGE 3 / the manual
# path -- a selected datum point gives its own id, and we get the feature id via
# the point's GetFeature() (with a buffer-feature fallback). Returns $null and
# warns if 0 or >1 distinct seed points were selected (the pattern wants exactly 1).
# ----------------------------------------------------------------------------
function Resolve-SeedPoint {
    param($Session, $TypeObj)

    $contents = $null
    try { $contents = ($Session.CurrentSelectionBuffer()).Contents } catch {}
    if ($null -eq $contents -or $contents.Count -eq 0) {
        Write-Host "  Selection buffer is empty -- no seed datum point selected." -ForegroundColor Yellow
        return $null
    }

    # collect (pointId, featId) pairs, ID-only, deduped by point id.
    $pairs = @()
    $seen  = @{}
    foreach ($item in $contents) {
        $si = $null
        try { $si = $item.SelItem } catch { continue }
        if ($null -eq $si) { continue }

        # the selection IS a datum point?
        $isPoint = $false
        try { $isPoint = ([int]$si.Type -eq [int]$TypeObj.ITEM_POINT) } catch {}

        # also handle a selected point-bearing FEATURE -> its contained point(s)
        $subPts = @()
        try { foreach ($p in @($si.ListSubItems($TypeObj.ITEM_POINT))) { $subPts += $p } } catch {}

        $candidates = @()
        if ($isPoint) { $candidates += $si }
        $candidates += $subPts

        foreach ($pt in $candidates) {
            # NOTE: $ptId, NOT $pid -- $pid is a read-only PowerShell automatic var
            # (the same trap holeinator hit; see CLAUDE.md / project memory).
            $ptId = $null
            try { $ptId = [int]$pt.Id } catch { continue }
            if ($seen.ContainsKey($ptId)) { continue }
            $seen[$ptId] = $true

            # owning feature id: prefer the point's GetFeature(); fall back to the
            # selected feature's own id when the selection WAS the feature.
            $fid = $null
            try { $fid = [int]$pt.GetFeature().Id } catch {}
            if ($null -eq $fid) { try { $fid = [int]$si.Id } catch {} }

            $pairs += [pscustomobject]@{ PointId = $ptId; FeatId = $fid }
        }
    }

    if ($pairs.Count -eq 0) {
        Write-Host "  No datum point found in the selection (select the ONE seed point)." -ForegroundColor Yellow
        return $null
    }
    if ($pairs.Count -gt 1) {
        Write-Host ("  {0} distinct datum points selected -- the rectangular pattern wants exactly ONE seed." -f $pairs.Count) -ForegroundColor Yellow
        Write-Host "  Select only the single corner point and try again." -ForegroundColor Yellow
        return $null
    }
    if ($null -eq $pairs[0].FeatId) {
        Write-Host "  Could not resolve the seed point's owning feature id (needed to pattern it)." -ForegroundColor Yellow
        return $null
    }
    return $pairs[0]
}

# ----------------------------------------------------------------------------
function Show-OrthogridTable {
    param($Geo)
    Write-Host ""
    # Mode-aware header: a custom layout has no Nx/Nz (both 0), so show just the count.
    if ($Geo.PSObject.Properties.Name -contains 'Mode' -and $Geo.Mode -eq 'custom') {
        Write-Host ("  Custom points: {0} point(s)   plate {1} x {2}" -f `
            $Geo.Count, $Geo.Width, $Geo.Height) -ForegroundColor Green
    } else {
        Write-Host ("  Orthogrid: {0} points  ({1} x {2})   plate {3} x {4}" -f `
            $Geo.Count, $Geo.Nx, $Geo.Nz, $Geo.Width, $Geo.Height) -ForegroundColor Green
    }
    Write-Host "  X = TOP-direction offset, Z = FRONT-direction offset, both from the plate corner." -ForegroundColor DarkGray
    Write-Host ("  {0,4}  {1,7}  {2,12}  {3,12}" -f "#", "(I,J)", "X (offset)", "Z (offset)") -ForegroundColor White
    Write-Host "  ----  -------  ------------  ------------" -ForegroundColor DarkGray
    $n = 0
    foreach ($pt in $Geo.Points) {
        $n++
        Write-Host ("  {0,4}  ({1},{2})  {3,12:N4}  {4,12:N4}" -f $n, $pt.I, $pt.J, ([double]$pt.X), ([double]$pt.Z)) -ForegroundColor White
    }
    Write-Host ""
}

# ----------------------------------------------------------------------------
# Invoke-ManualPointGrid -- GUARANTEED path: show the grid, ask the user to
# create those datum points by hand in Creo (or confirm a skeleton already has
# them) and SELECT them, press ENTER, then resolve the selection buffer to point
# ids -- the exact STAGE-3 resolution (datum point -> its id; point-bearing
# feature -> ListSubItems(ITEM_POINT)). ID-ONLY: never reads .Point coordinates.
# Returns @(point ids) -- possibly fewer/more than Count if the user creates a
# different set; the caller reports the mismatch and lets the user re-pick.
# ----------------------------------------------------------------------------
function Invoke-ManualPointGrid {
    param($Geo, $Session, $TypeObj)

    Show-OrthogridTable -Geo $Geo

    Write-Host "  MANUAL POINT CREATION (guaranteed path):" -ForegroundColor Cyan
    Write-Host "    In Creo, create datum points at the X/Z offsets above on the SIDE" -ForegroundColor White
    Write-Host "    base datum (the plate face), OR if the skeleton already has them," -ForegroundColor White
    Write-Host "    just verify they match. Then SELECT all the grid points (Ctrl-click," -ForegroundColor White
    Write-Host "    or box-select), and press ENTER here." -ForegroundColor White
    Read-Host

    $contents = $null
    try { $contents = ($Session.CurrentSelectionBuffer()).Contents } catch {}
    if ($null -eq $contents -or $contents.Count -eq 0) {
        Write-Host "  Selection buffer is empty -- no points captured." -ForegroundColor Yellow
        return @()
    }

    # ---- STAGE-3 resolution, verbatim: ID-only, datum point OR point feature ----
    $ids = @()
    $seen = @{}
    $rejected = @()
    foreach ($item in $contents) {
        $si = $null
        try { $si = $item.SelItem } catch { continue }
        if ($null -eq $si) { continue }

        $isPointType = $false
        try { $isPointType = ([int]$si.Type -eq [int]$TypeObj.ITEM_POINT) } catch {}

        $subIds = @()
        try {
            foreach ($pt in @($si.ListSubItems($TypeObj.ITEM_POINT))) {
                try { $subIds += [int]$pt.Id } catch {}
            }
        } catch {}

        if ($subIds.Count -gt 0) {
            foreach ($sid in $subIds) {
                if (-not $seen.ContainsKey($sid)) { $seen[$sid] = $true; $ids += $sid }
            }
        } elseif ($isPointType) {
            $id = [int]$si.Id
            if (-not $seen.ContainsKey($id)) { $seen[$id] = $true; $ids += $id }
        } else {
            $rid = "?"; $tname = "?"
            try { $rid = [int]$si.Id } catch {}
            try { $tname = [string]$si.Type } catch {}
            $rejected += "id $rid (type $tname)"
        }
    }

    if ($rejected.Count -gt 0) {
        Write-Host ("  Ignored {0} selected item(s) that are neither datum points nor point-bearing features:" -f $rejected.Count) -ForegroundColor Yellow
        foreach ($r in ($rejected | Select-Object -First 10)) { Write-Host "      $r" -ForegroundColor DarkGray }
    }
    if ($ids.Count -ne $Geo.Count) {
        Write-Host ("  NOTE: captured {0} point id(s) but the grid expects {1}. Verify the" -f $ids.Count, $Geo.Count) -ForegroundColor Yellow
        Write-Host "        selection before drilling, or re-run this step." -ForegroundColor Yellow
    }
    return @($ids)
}


# NOTE: the old Invoke-PatternPointGrid driver (pattern the DATUM POINTS into the
# grid) was REMOVED 2026-06-24. The grid is now built by patterning the HOLE feature
# in drilljig STAGE 5, via the Build-Pattern{Arm,Values,Confirm}Macro PHASE builders
# above (split around the user's direction-reference screen picks, per the recorded
# mapkey). Resolve-SeedPoint (above) is still used by STAGE 2.5 to capture the one seed.
