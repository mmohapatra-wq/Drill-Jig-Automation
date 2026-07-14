# ============================================================================
# STAGE 2.5 -- ORTHOGRID DATUM POINTS (splice INLINE into drilljig.cmd, AFTER
# the STAGE 2 box build, BEFORE STAGE 3). Depends on, already in scope:
#   $session, $model, $pfcType, $planes/$made (each {Label;BaseId;FeatId;Sym}),
#   Invoke-Macro, Get-SelectByIdMacro, Wait-ModelModified, lib\orthogrid.ps1
#     (Get-OrthogridGeometry), and the STAGE-3 ITEM_POINT resolution pattern.
# Dot-source the grid math once near the other lib loads:
#     . (Join-Path $ScriptDir 'lib\orthogrid.ps1')
#
# ORCHESTRATION CONTRACT (the caller MUST follow this; see the driver block at
# the bottom of this code):
#   1. Compute the grid with Get-OrthogridGeometry (the EXACT shared shape).
#   2. TRY the auto-macro: snapshot ITEM_POINT ids -> fire Build-PointGridMacro
#      inside a VersionStamp canary -> Resolve-NewPointIds to diff.
#   3. VERIFY: model changed (VersionStamp) AND new-point-count == grid.Count.
#   4. On ANY miss (no change / wrong count / macro error) FALL THROUGH to the
#      GUARANTEED manual path. NEVER silently proceed with zero points -- a
#      zero-point hand-off would make STAGE 3 drill nothing and still say "Done".
#   5. Return @(new int point ids) to STAGE 3, which feeds them to Build-HoleMacro.
# ============================================================================


# ----------------------------------------------------------------------------
# 1. Resolve-NewPointIds -- before/after ITEM_POINT diff. ID-ONLY: it reads
#    $p.Id and NOTHING else (never $p.Point coordinates -- the toolkit's hard
#    ID-only lesson; reading IpfcPoint.Point crashed holeinator live, see
#    CLAUDE.md holeinator "History / why ID-only"). Every COM touch is wrapped
#    so a single bad item can't throw and kill the run (READS degrade to skip).
#
#    Usage:
#      $before = Get-PointIdSet -Model $model -TypeObj $pfcType
#      <run a creation action: a macro, or a manual hand-create + ENTER>
#      $newIds = Resolve-NewPointIds -Model $model -TypeObj $pfcType -Before $before
# ----------------------------------------------------------------------------
function Get-PointIdSet {
    # Snapshot every datum-point id currently in the model as a hashtable set.
    # Returns @{} (empty set) on any enumeration failure -- never throws.
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

function Resolve-NewPointIds {
    # Diff the current ITEM_POINT set against a prior snapshot ($Before) and
    # return the @(new int ids), de-duped, sorted ascending for stable output.
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
# 2. Build-PointGridMacro
#
# *** UNVERIFIED -- BEST-GUESS WIDGET NAMES. THIS MACRO HAS NOT BEEN RECORDED ***
# *** LIVE. Treat exactly like Build-ReliefHoleMacro: try it, gate it on a    ***
# *** VersionStamp canary + exact new-point COUNT, and fall through to the    ***
# *** manual path on ANY miss. DO NOT trust it until the recipe below is run. ***
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
#   Command                       `ProCmdDatumPoint`            (datum point tool; may be `ProCmdDatumPointOffCsys`)
#   Dialog                        `Odui_Dlg_00`                 (the datum-point dialog -- same family as nodelator's paste dialog)
#   Point-type / offset-csys tab  `t1.PntTypeOptMenu`           value `Offset Coordinate System`  (selects the table mode)
#   Reference collector           `t1.RefCollector`             (fed the SIDE base datum by the leading select-by-ID)
#   Csys/dir references           `t1.DirRefList`               (TOP/FRONT for the two in-plane axes -- may be two separate collectors)
#   Points table                  `t1.pnt_table`                (the editable X/Z grid; rows added per point)
#   Add-row button                `t1.add_pnt_btn`              (append a new table row)
#   Per-row X cell column key     `xax_axis`  (column 1)        (the TOP-direction offset)
#   Per-row Z cell column key     `zax_axis`  (column 2)        (the FRONT-direction offset)
#   OK button                     `stdbtn_1`                    (confirmed elsewhere as the datum-dialog OK; reused here)
#
# *** RECORD-LIVE RECIPE to replace these guesses (do this ONCE, then transcribe
#     the real widget names below and delete this UNVERIFIED banner):
#   1. In Creo: File > Options > Configuration Editor, set  visible_mapkeys = yes
#      (or add `visible_mapkeys yes` to config.pro) and Apply, so every widget
#      interaction is echoed into the trail file.
#   2. Tools > Trail/Training Files -- note the active trail.txt.N path (or just
#      let it write; you will read the newest trail.txt.* after).
#   3. Pre-select the SIDE base datum plane in the model tree (this is the FACE).
#   4. Model > Datum > Point > Offset Coordinate System  (the table variant).
#      Pick the SIDE datum as the placement reference and TOP/FRONT as the two
#      offset directions; switch the dropdown to "Cartesian".
#   5. Click "Add Point" / add a row, type a known X and a known Z (e.g. 1.0 /
#      2.0). Add a SECOND row with a different X/Z so the row index + column
#      tokens are unambiguous in the trail. Click OK.
#   6. Open the newest trail.txt.* and copy every `~ Command` / `~ Select` /
#      `~ Update` / `~ Input` / `~ Activate` / `~ Trigger` line from step 4-5
#      (drop `~ Trail` / `~ Timer` / `~ Move` noise). Those are the REAL tokens.
#   7. Replace the guessed tokens below with the recorded ones, keeping the
#      whole open->table->OK as ONE concatenated RunMacro string, and keeping
#      the leading Get-SelectByIdMacro select-by-ID of the SIDE base datum.
#   8. Re-run drilljig; the canary + exact-count gate confirms it took.
#
# PARAMETERS:
#   -Points        : the Get-OrthogridGeometry.Points array (each {I;J;X;Z}); X
#                    is the TOP-direction offset, Z is the FRONT-direction offset
#                    (both measured from the plate corner -- (Edge,Edge) is pt 1).
#   -SideBaseId    : SIDE base/default datum feature id ($sidePlane.BaseId) -- the
#                    plate FACE the points lie on / the holes drill into.
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
        # These are fed by ID via the same Datum tree-search the box build uses
        # for the up-to plane; if the dialog instead consumes them from the
        # buffer, swap each line for a (Get-SelectByIdMacro -FeatId <id> -NoClear).
        "~ Update ``Odui_Dlg_00`` ``t1.DirRefList`` ``$TopBaseId``;" +
        "~ Update ``Odui_Dlg_00`` ``t1.DirRefList`` ``$FrontBaseId``;"

    # One table row per grid point. X = TOP-direction offset, Z = FRONT-direction
    # offset (both from the plate corner; Get-OrthogridGeometry already computed
    # them as Edge + I*CcX / Edge + J*CcZ). GUESS: add a row, then write its X
    # and Z cells by (row,column) trigger -- the column keys xax_axis/zax_axis
    # and the add-row button are the parts MOST likely to differ from the trail.
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


# ----------------------------------------------------------------------------
# 3. MANUAL FALLBACK -- GUARANTEED to work today. No guessed widgets: it only
#    PRINTS the computed grid and READS BACK ids the user/skeleton already has,
#    via the SAME selection-buffer + ListSubItems(ITEM_POINT) resolution STAGE 3
#    uses verbatim. Use whenever the auto-macro misses (or to skip it entirely).
#
#    $Geo is the Get-OrthogridGeometry result (Points + Width/Height/Count).
#    Returns @(point ids) -- possibly fewer/more than Count if the user creates a
#    different set; the caller reports the mismatch and lets the user re-pick.
# ----------------------------------------------------------------------------
function Show-OrthogridTable {
    # Print the grid as a readable table: point #, (I,J), corner-offset X/Z, and
    # the plate-relative coordinate (identical here -- offsets ARE measured from
    # the plate corner origin (Edge,Edge)=first point per the grid contract).
    param($Geo)
    Write-Host ""
    Write-Host ("  Orthogrid: {0} points  ({1} x {2})   plate {3} x {4}" -f `
        $Geo.Count, $Geo.Nx, $Geo.Nz, $Geo.Width, $Geo.Height) -ForegroundColor Green
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

function Invoke-ManualPointGrid {
    # GUARANTEED path: show the grid, ask the user to create those datum points
    # by hand in Creo (or confirm a skeleton already has them) and SELECT them,
    # press ENTER, then resolve the selection buffer to point ids -- the exact
    # STAGE-3 resolution (datum point -> its id; point-bearing feature ->
    # ListSubItems(ITEM_POINT)). ID-ONLY: never reads .Point coordinates.
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


# ============================================================================
# DRIVER -- splice this after the STAGE 2 box build. Computes the grid, TRIES the
# auto-macro (canary + exact-count gate), falls through to the manual path on any
# miss, and leaves the resolved ids in $gridPointIDs for STAGE 3. NEVER proceeds
# with zero points.
# ============================================================================

# --- gather the grid inputs (cc-X / cc-Z spacing, Nx / Nz counts, edge margin) ---
# These would normally come from the orthogrid GUI / prompts; shown here as the
# read that feeds Get-OrthogridGeometry. Adjust the prompt source to taste.
$geo = Get-OrthogridGeometry -CcX $orthoCcX -CcZ $orthoCcZ -Nx $orthoNx -Nz $orthoNz -Edge $orthoEdge
if (-not $geo.Valid) {
    Write-Host "  Orthogrid inputs invalid -- not creating any points:" -ForegroundColor Red
    foreach ($e in $geo.Errors) { Write-Host "      - $e" -ForegroundColor Red }
    $gridPointIDs = @()
} else {

    $sidePlane  = @($made | Where-Object { $_.Label -eq "Side"  })
    $topPlane   = @($planes | Where-Object { $_.Label -eq "Top"   })
    $frontPlane = @($planes | Where-Object { $_.Label -eq "Front" })
    $sideBaseId  = if ($sidePlane.Count  -gt 0) { [int]$sidePlane[0].BaseId  } else { $null }
    $topBaseId   = if ($topPlane.Count   -gt 0) { [int]$topPlane[0].BaseId   } else { $null }
    $frontBaseId = if ($frontPlane.Count -gt 0) { [int]$frontPlane[0].BaseId } else { $null }

    $gridPointIDs = @()
    $autoOk = $false

    # ---- (2)+(3) TRY the auto-macro, gated on canary + EXACT new-point count ----
    $canTryAuto = ($null -ne $sideBaseId -and $null -ne $topBaseId -and $null -ne $frontBaseId)
    if ($canTryAuto) {
        Write-Host "  Attempting one-feature auto grid (UNVERIFIED widgets -- will verify by count)..." -ForegroundColor Cyan
        $before = Get-PointIdSet -Model $model -TypeObj $pfcType
        $stamp  = $null
        try { $stamp = $model.VersionStamp } catch {}

        $macro = Build-PointGridMacro -Points $geo.Points -SideBaseId $sideBaseId -TopBaseId $topBaseId -FrontBaseId $frontBaseId
        $changed = $false
        try {
            $session.RunMacro($macro)
            if ($null -ne $stamp) { $changed = Wait-ModelModified -Model $model -PreviousStamp $stamp } else { $changed = $true }
        } catch {
            Write-Host "  Auto grid macro errored: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        $newIds = Resolve-NewPointIds -Model $model -TypeObj $pfcType -Before $before

        # CANARY + EXACT-COUNT GATE: model must have changed AND the diff must
        # yield exactly Count new points. A partial/zero result is a MISS.
        if ($changed -and $newIds.Count -eq $geo.Count) {
            $gridPointIDs = @($newIds)
            $autoOk = $true
            Write-Host ("  Auto grid OK: created {0} datum point(s) in one feature." -f $newIds.Count) -ForegroundColor Green
        } else {
            Write-Host ("  Auto grid MISS (model changed={0}, new points={1}, expected={2})." -f `
                $changed, $newIds.Count, $geo.Count) -ForegroundColor Yellow
            Write-Host "  The guessed datum-point widget names likely need a live recording" -ForegroundColor Yellow
            Write-Host "  (see Build-PointGridMacro's RECORD-LIVE RECIPE). Falling back." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Missing a base datum id (Side/Top/Front) -- skipping the auto grid, going manual." -ForegroundColor Yellow
    }

    # ---- (4) FALL THROUGH to the guaranteed manual path on any miss ----
    if (-not $autoOk) {
        $gridPointIDs = @(Invoke-ManualPointGrid -Geo $geo -Session $session -TypeObj $pfcType)
    }
}

# ---- HARD STOP: never hand STAGE 3 zero points (it would "drill nothing" green) ----
if ($null -eq $gridPointIDs -or $gridPointIDs.Count -eq 0) {
    throw "No orthogrid datum points were created or captured -- refusing to proceed to drilling. (Auto grid missed and the manual selection was empty.)"
}
Write-Host ("  Orthogrid points ready: {0} id(s) -> {1}" -f $gridPointIDs.Count, ($gridPointIDs -join ", ")) -ForegroundColor Green
# STAGE 3 consumes $gridPointIDs in place of its own STEP-1 $pointIDs capture:
#   foreach ($ptId in $gridPointIDs) { Build-HoleMacro -PointId $ptId ... }