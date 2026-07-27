<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir=((Split-Path -Parent ('%~dp0'.TrimEnd('\')))+'\'); $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

# ============================================================================
# drilljig3d.cmd - conformal 3D drill-jig blank from a clicked surface
# ============================================================================
# "I want a drill-jig that follows a curved face." You enter a THICKNESS, click
# the SURFACE you want jigged, and this tool:
#   1. Creates an OFFSET-surface feature from that face at a STANDOFF offset
#      (default 0 = a coincident quilt copy; >0 floats the jig off the part for
#      chip clearance), then
#   2. THICKENS that quilt into a NEW solid body of the given thickness (STAGE 1).
#   3. STAGE 2 (optional): drills On-Point holes NORMAL to the surface at datum
#      points you select - holeinator's proven machinery, retargeted at the new
#      blank body, all in the SAME session.
# The result is a conformal drill jig - the 3D analog of drilljig.cmd's flat plate.
#
# Built from the user's recorded offset+thicken mapkey:
#   ~ Command `ProCmdFtOffset`;
#   ~ FocusOut `references.1.0` `PH.SrfCollTbl`;  @PAUSE (surface pick)
#   ~ Input/Update `maindashInst0.mru_option_menu` `0`;
#   ~ Trigger `maindashInst0.ExclSrfColl` `0`/``;  ~ FocusOut `mru_option_menu`;
#   ~ Activate `dashInst0.Done`;
#   ~ Command `ProCmdFtThicken`;  ~ Activate `dashInst0.Done`;
#
# TWO DELIBERATE DEPARTURES from a raw mapkey replay, both proven elsewhere:
#  (1) NO SCREEN PICK. The recording pauses for the human to click the surface
#      into the offset collector. A RunMacro cannot pause, so instead the user
#      pre-selects the surface; the script reads its ID and re-selects it BY ID
#      (ID-ONLY - never reads a surface coordinate, holeinator's lesson) so the
#      whole offset+thicken fires as ONE atomic RunMacro. Pre-selecting a geometry
#      ref and letting the feature command consume it is the SAME proven path
#      surfenator (ProCmdFtExtrude consumes a pre-selected sketch plane) and
#      plane-probe (ProCmdDatumPlane consumes a pre-selected base) already use.
#  (2) REGENERATIVE DIMENSIONING for the values. The recorded mapkey sets neither
#      the offset distance nor the thickness - it takes the dashboard defaults. We
#      instead create the two features, then find each new feature by before/after
#      ID diff (plane-probe's New-OffsetPlane pattern), write its feature-level dim
#      via DimValue (offset -> 0, thickness -> entered value), Invoke-ForceRegen,
#      and RE-READ to confirm it stuck. Offset distance and thicken thickness are
#      both FEATURE-level dims, so a DimValue write holds on a closed feature
#      (same reliable path boxinator uses for extrude depth; sketch dims would
#      snap back - see [[project_sketch_dim_snapback]]).
#
# OFFSET+THICKEN STAY IN ONE ATOMIC MACRO (faithful to the recording): the thicken
# relies on the freshly-created offset quilt being the active geometry, and a
# dashboard's command context does NOT survive across RunMacro calls (boxinator
# lesson). The two new features are then disambiguated by CREATION ORDER - the
# lower new feature ID is the offset (created first), the higher is the thicken -
# so each dim is driven to the right target without guessing a feature type
# (EpfcFeatureType enum ints are unconfirmed on this build - drilljig lesson).
#
# Verification is a VersionStamp change (the model changed when the macro fired),
# NOT a geometric measurement - the offset surface is curved, so a bounding-box
# extent does not equal the thickness. "Done" means the features were created and
# each driven dim re-read at its target; verify the conformal slab visually.
# ============================================================================

$Host.UI.RawUI.WindowTitle = "DRILLJIG3D"
$Verbose = $ScriptArgs -match '(?i)-v|--verbose'
# -defaultorient : in STAGE 2, drill holes with holeinator's EXACT proven macro
# (Creo's default On-Point direction) instead of the normal-to-surface orientation
# hypothesis (surface pre-select). Use to confirm the rest of the pipeline if the
# orientation step misbehaves live.
$DefaultOrient = ($ScriptArgs -match '(?i)-{1,2}defaultorient')
# --tangent-orient : in STAGE 2, build a TANGENT datum plane at each hole (point +
# STAGE-1 surface) and drill On-Point normal to THAT plane -- its normal IS the
# surface normal there, so orientation is normal-to-surface by construction (retires
# the surface-pre-select HYPOTHESIS). OFF by default until tangent-plane-probe.cmd
# confirms the by-ID Tangent ref feed live; the proven Build-NormalHoleMacro path
# stays the default. Also reused as the slot sketch host in STAGE 3.
$TangentOrient = ($ScriptArgs -match '(?i)-{1,2}tangent-orient')
# --no-slots : skip the STAGE 3 curved chip-relief slot loop.
$NoSlots = ($ScriptArgs -match '(?i)-{1,2}no-slots')
$ErrorActionPreference = "Stop"
$startTime = Get-Date

trap {
    Write-Host ""
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $inv = $_.InvocationInfo
    if ($null -ne $inv) {
        Write-Host ("  at line {0}: {1}" -f $inv.ScriptLineNumber, $inv.Line.Trim()) -ForegroundColor DarkYellow
    }
    if ($Verbose -and $_.ScriptStackTrace) {
        Write-Host "  $($_.ScriptStackTrace)" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

function Write-Log {
    param([string]$Msg, [string]$Color = 'Gray')
    if ($Verbose) { Write-Host "  $Msg" -ForegroundColor $Color }
}

# Progress bar for the STAGE 2 drilling loop (standard toolkit helper, from
# holeinator/edginator). Tracks the last percent in $script:lastPct so a redraw
# only happens when the number changes.
$script:lastPct = -1
function Show-Progress {
    param([int]$Pct, [string]$Label)
    if ($Pct -eq $script:lastPct) { return }
    $script:lastPct = $Pct
    $filled = [Math]::Floor($Pct / 5)
    $empty = 20 - $filled
    $bar = ([char]9608).ToString() * $filled + ([char]9617).ToString() * $empty
    $color = if ($Pct -ge 100) { "Green" } else { "White" }
    $shortLabel = if ($Label.Length -gt 60) { $Label.Substring(0, 60) } else { $Label }
    Write-Host "`r  [$bar] $($Pct.ToString().PadLeft(3))%  $shortLabel   " -NoNewline -ForegroundColor $color
    if ($Pct -ge 100) { Write-Host "" }
}

# ============================================================================
# HELPERS
# ============================================================================

# Fire a mapkey and report success/failure instead of swallowing it (plane-probe's
# pattern). A silent no-op from a wrong widget name is the hardest mapkey bug to
# find, so we count failures and surface them.
$script:macroFailures = 0
function Invoke-Macro {
    param([string]$Label, [string]$Macro)
    Write-Host "    > $Label ..." -NoNewline -ForegroundColor DarkGray
    try {
        $session.RunMacro($Macro)
        Write-Host " ok" -ForegroundColor DarkGray
    } catch {
        Write-Host ""
        Write-Host "      FAILED: $($_.Exception.Message)" -ForegroundColor Red
        $script:macroFailures++
    }
}

# $true if VersionStamp changed within the timeout (the macro modified the model).
# The canary net against offset/thicken mapkey widget-name drift.
function Wait-ModelModified {
    param($Model, [string]$PreviousStamp, [int]$TimeoutMs = 30000)
    $deadline = [DateTime]::Now.AddMilliseconds($TimeoutMs)
    while ([DateTime]::Now -lt $deadline) {
        try { if ($Model.VersionStamp -ne $PreviousStamp) { return $true } } catch {}
        Start-Sleep -Milliseconds 50
    }
    return $false
}

# Forced regen with fallbacks (lifted from plane-probe / boxinator). On this
# No-Resolve build the API forced regen throws IpfcXToolkitBadContext, so the
# reliable path is the UI ProCmdRegenerate; automatic regen is the last resort.
# This is what makes a feature-level DimValue write take effect immediately.
function Invoke-ForceRegen {
    param($Model)
    try {
        $regenCls = New-Object -ComObject pfcls.pfcRegenInstructions
        $instr    = $regenCls.Create($false, $true, $null)   # Create(AllowFixUI, ForceRegen, FromFeat)
        $Model.Regenerate($instr)
        return
    } catch {}
    $before = $null
    try { $before = $Model.VersionStamp } catch {}
    Invoke-Macro "force regenerate (UI)" "~ Command ``ProCmdRegenerate``;"
    if ($null -ne $before) {
        for ($i = 0; $i -lt 30; $i++) {
            try { if ($Model.VersionStamp -ne $before) { return } } catch {}
            Start-Sleep -Milliseconds 50
        }
    }
    try { $Model.Regenerate($null) } catch {}
}

# Snapshot every feature ID on the model into a hashtable. The new offset/thicken
# features are found by diffing this before vs after the macro (plane-probe's
# Get-FeatureIdSet), so we never guess a feature ID.
function Get-FeatureIdSet {
    param($Model, $TypeObj)
    $set = @{}
    try {
        foreach ($f in $Model.ListItems($TypeObj.ITEM_FEATURE)) {
            try { $set[[int]$f.Id] = $true } catch {}
        }
    } catch {}
    return $set
}

# For every feature NOT in $BeforeIds, return its id + its LINEAR dim symbols,
# sorted ascending by id (= creation order). Per-feature dims via
# feature.ListSubItems(ITEM_DIMENSION) is gauginator's proven walk; DimType 0 =
# Linear (the offset distance and thicken thickness are both linear). This is how
# the new offset feature's dim and the new thicken feature's dim are isolated
# without disturbing any pre-existing dim on the part.
function Get-NewFeatureLinearDims {
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

# Build the tree-search "select surface(s) BY ID into the buffer" macro fragment
# (plane-probe's Get-SelectByIdMacro skeleton, with type = Surface, and edginator's
# accumulate loop so >1 surface can feed one offset quilt). Clears the buffer
# first, opens the search once, loops every id in (ApplyBtn ACCUMULATES), closes
# once. The caller appends ProCmdFtOffset, which consumes the buffered surface set.
function Get-SelectSurfacesByIdMacro {
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

# The offset+thicken dashboard sequence (the user's recording, verbatim widgets),
# fired as ONE atomic RunMacro after the surface(s) are already buffered by ID.
# The offset distance / thickness are NOT set here - they are driven afterward by
# regenerative dimensioning. The recording's pre-pick `FocusOut references.1.0
# PH.SrfCollTbl` line is intentionally omitted: it readied the EMPTY collector for
# a manual pick, but here the surface is pre-loaded from the buffer.
#   LIVE FALLBACK if the offset does not pick up the pre-selected surface: open
#   ProCmdFtOffset FIRST, then feed PH.SrfCollTbl by ID with -NoClear (surfenator's
#   open-collector feed) instead of pre-selecting. See header.
#
# THICKEN OUTPUTS A NEW BODY. The two body-page widgets below route the thicken's
# output to a freshly CREATED body (rather than merging into the body the offset
# surface came from), so the conformal jig blank is its own solid. They are
# thickenator's CONFIRMED-WORKING "thicken quilt -> new solid body" widgets
# (thickenator.cmd: chkbn.body_page.0 then body_page.0.0 PH.bodyusechkbtnrepwdg),
# fired right before dashInst0.Done. Thickness is still driven by regenerative
# dimensioning afterward, so maindashInst0.Thickness is deliberately NOT set here.
# DIRECTION: a single maindashInst0.Flip makes the material grow AWAY from the
# part (opposite the offset surface) - confirmed needed live 2026-06-24.
function Get-OffsetThickenMacro {
    return "~ Command ``ProCmdFtOffset``;" +
        "~ Input  ``main_dlg_cur`` ``maindashInst0.mru_option_menu`` ``0``;" +
        "~ Update ``main_dlg_cur`` ``maindashInst0.mru_option_menu`` ``0``;" +
        "~ Trigger ``main_dlg_cur`` ``maindashInst0.ExclSrfColl`` ``0``;" +
        "~ Trigger ``main_dlg_cur`` ``maindashInst0.ExclSrfColl`` ````;" +
        "~ FocusOut ``main_dlg_cur`` ``maindashInst0.mru_option_menu``;" +
        "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;" +
        "~ Command ``ProCmdFtThicken``;" +
        # FLIP the thicken side ONCE so material grows AWAY from the part (the
        # opposite side of the coincident offset surface) - confirmed needed live
        # 2026-06-24 (the default thickened toward the part). maindashInst0.Flip is
        # thickenator's confirmed flip widget; ONE Activate = one flip off the
        # default. If a future part defaults the other way, this is the knob.
        "~ Activate ``main_dlg_cur`` ``maindashInst0.Flip``;" +
        "~ Activate ``main_dlg_cur`` ``chkbn.body_page.0`` 1;" +
        "~ Activate ``body_page.0.0`` ``PH.bodyusechkbtnrepwdg`` 1;" +
        "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"
}

# Write one dim by symbol, force a regen, return the value that actually stuck (or
# $null on a write failure). plane-probe's Set-PlaneOffset, generalized.
function Set-DimAndConfirm {
    param($Model, $TypeObj, [string]$Sym, [double]$Target)
    try {
        $d = $Model.GetItemByName($TypeObj.ITEM_DIMENSION, $Sym)
        $d.DimValue = $Target
    } catch {
        Write-Host "      could not write DimValue on $Sym : $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
    Invoke-ForceRegen -Model $Model
    return (Read-DimValue -Model $Model -TypeObj $TypeObj -Sym $Sym)
}

# Read the user's current selection buffer into surface IDs. ID-ONLY - never reads
# a surface coordinate (holeinator's lesson). An item counts as a surface if its
# Type is ITEM_SURFACE. Dedups; reports non-surface selections with their type.
# Returns @{ Surfaces=@(ids); Rejected=@() }.
function Resolve-SelectedSurfaces {
    param($Session, $TypeObj)
    $ids = @()
    $seen = @{}
    $rejected = @()
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
# STAGE 2 (drilling) helpers — reuse holeinator's proven On-Point hole machinery
# ----------------------------------------------------------------------------

# Snapshot solid-body IDs into a hashtable. The thicken creates a NEW body; STAGE 2
# finds it by diffing this before vs after the offset+thicken macro so it drills
# into the blank we just made, not some other body. Index in ListItems(ITEM_BODY)
# == the hole dashboard's body-selector index (holeinator's assumption).
function Get-BodyIdSet {
    param($Model, $TypeObj)
    $set = @{}
    try {
        foreach ($b in $Model.ListItems($TypeObj.ITEM_BODY)) {
            try { $set[[int]$b.Id] = $true } catch {}
        }
    } catch {}
    return $set
}

# Generic tree-search "select ONE item of $TypeName by $Id into the buffer"
# fragment (holeinator's point-select / plane-probe's feature-select, made type-
# generic). Clears the buffer first UNLESS -NoClear, which ACCUMULATES a second
# ref onto what is already buffered (used to add the orientation surface after the
# placement point).
function Get-SelectItemByIdMacro {
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

# Resolve the current selection buffer into datum-point IDs (holeinator's ID-ONLY
# resolve). A selection is either the point geometry directly (Type=ITEM_POINT) or
# a datum-point FEATURE whose point ids come from ListSubItems(ITEM_POINT). Never
# reads .Point coordinates. Returns @{ Points=@(ids); Rejected=@() }.
function Resolve-SelectedPoints {
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

# Build the On-Point HOLE macro, NORMAL TO THE SURFACE. Reuses holeinator's
# CONFIRMED-LIVE hole dashboard tail (thru-all + body page + diameter, recorded
# 2026-06-11) VERBATIM; the only 3D-specific addition is the orientation reference.
#
# ORIENTATION HYPOTHESIS (the live-unverified piece — the user accepted this needs
# a live recording): to make the hole NORMAL to the curved face, the surface is
# pre-selected into the buffer ALONGSIDE the placement point, then ProCmdHole. This
# uses ONLY the proven select-by-ID machinery — NO guessed dashboard widget that
# could hard-error — so the worst case is the hole takes Creo's DEFAULT On-Point
# direction (verify normal-to-surface visually), not a broken macro. If
# pre-selecting the surface does NOT orient the hole, record the proper
# Placement -> direction-reference pick live (visible_mapkeys yes: place an On-Point
# hole, then in the Placement panel add the surface as the direction ref set to
# Normal) and splice it where marked. -DefaultOrient drops the surface pre-select
# entirely = holeinator's exact proven macro (point only).
function Build-NormalHoleMacro {
    param([int]$PointId, [int]$SurfaceId, [double]$Diameter, [int]$BodyIndex = 0, [switch]$DefaultOrient)
    # 1) placement: the datum point (clears the buffer first)
    $m = (Get-SelectItemByIdMacro -TypeName 'Point' -Id $PointId)
    # 2) orientation: add the surface as a second buffered ref (normal direction).
    #    <-- if a live recording shows On-Point needs an explicit Placement
    #        direction-reference pick instead, splice that fragment here.
    if (-not $DefaultOrient) {
        $m += (Get-SelectItemByIdMacro -TypeName 'Surface' -Id $SurfaceId -NoClear)
    }
    # 3) holeinator's recorded On-Point hole dashboard tail (verbatim, proven live)
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

# Blind-evaluator gate for STAGE 2 drilling (top rec #3 of docs\drilljig3d_improvements.md):
# did we create exactly the INTENDED number of bores at the INTENDED diameter? The CLAIM
# is from INTENT (the point count + diameter the user asked for), NOT re-read from the
# build path (re-reading would be outcome-vs-outcome and a self-consistent wrong result
# would pass). MEASUREMENT is the DELTA of cylindrical surfaces AT the target radius
# (holeDia/2) before vs after drilling - counting AT the radius checks COUNT and DIAMETER
# TOGETHER (a wrong-diameter bore is not counted at the target radius; a missing bore drops
# the delta), and the delta is robust to any pre-existing same-radius cylinders (they
# cancel). Test-ExtentsMatch (deterministic) owns the arithmetic; the LLM is advisory.
# Degrades to UNVERIFIED (returns $null) - never a false pass - when the cylinder walk
# returns 0 surfaces (the foreign-body / dead-ListSurfaces case; canary-must-not-assume).
# Reuses the same blind_evaluator API + <model>_eval.json artifact plane-probe uses.
function Invoke-JigEval {
    param($Model, $TypeObj, [string]$RepoRoot, $JudgeCfg, [int]$IntendedCount, [double]$Diameter, [int]$CylBefore, [int]$CylAfter, [string]$ModelName)

    $delta  = $CylAfter - $CylBefore
    $radius = [math]::Round($Diameter / 2.0, 5)

    # 0-surface walk => cannot measure. UNVERIFIED, not a failure of the holes.
    if ($CylAfter -le 0 -and $CylBefore -le 0) {
        Write-Host "  Blind eval: the cylinder walk returned 0 surfaces - cannot measure bore" -ForegroundColor Yellow
        Write-Host "  count/diameter on this body (UNVERIFIED, not a failure). Verify visually." -ForegroundColor Yellow
        return $null
    }

    # Slice carries MEASURED geometry only (no mapkey / body-index / orientation
    # provenance - the slice-purity rule the run_tests.ps1 assertions enforce).
    $truth = @{
        intended_hole_count        = $IntendedCount
        target_radius              = $radius
        cylinders_at_radius_before = $CylBefore
        cylinders_at_radius_after  = $CylAfter
        new_cylinders_at_radius    = $delta
    }

    # Deterministic gate: measured delta must equal the intended count (within 0.5).
    $numeric = Test-ExtentsMatch -Expected @([double]$IntendedCount) -Measured @([double]$delta) -Tol 0.5

    $claims = @(
        "the jig has $IntendedCount through-hole(s) of diameter $Diameter",
        "every through-hole bore is at diameter $Diameter (counted at radius $radius)"
    )

    $claim = New-EvalClaim -Tool "drilljig3d" -Operation "drill-holes" -Claims $claims
    $slice = Get-GeometrySlice -Model $ModelName -Truth $truth

    $base = ($ModelName -replace '\.(prt|asm)(\.\d+)?$','') -replace '[^\w\-]','_'
    $packetPath = Join-Path $RepoRoot ($base + "_eval.json")
    $when = (Get-Date).ToString("o")
    Write-EvalPacket -Path $packetPath -Claim $claim -Slice $slice -WhenIso $when | Out-Null
    Write-Host "  Eval packet -> $packetPath" -ForegroundColor DarkGray

    $packetObj = Get-Content $packetPath -Raw | ConvertFrom-Json
    $verdict = Invoke-BlindJudge -Packet $packetObj -Config $JudgeCfg

    # Gate on the deterministic delta; the LLM verdict is advisory.
    return (Show-ConvergenceReport -Verdict $verdict -Title "Blind evaluator: drill-holes" -Numeric $numeric)
}

# ============================================================================
# HEADER
# ============================================================================
Write-Host ""
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "   DRILLJIG3D  -  conformal jig: offset surface (0) + thicken + drill" -ForegroundColor Cyan
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Prerequisites:" -ForegroundColor Green
Write-Host "    1. The jig PART (not .asm) open in Creo, with the surface to follow" -ForegroundColor White
Write-Host "    2. STAGE 1: enter a thickness, then click that surface" -ForegroundColor White
Write-Host "    3. STAGE 2 (optional): datum points at the hole locations on the blank" -ForegroundColor White
Write-Host "    4. Do not interact with Creo during processing" -ForegroundColor White
Write-Host ""

# ============================================================================
# SHARED LIBRARY (dim reads come from here so every tool reads dims the same way)
# ============================================================================
. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')
. (Join-Path $ScriptDir 'lib\blind_evaluator.ps1')
# STAGE 0 decision-tree walk + bushing/hole pick. drilljig_core.ps1 supplies the
# PURE catalog helpers (Get-CatalogSpec, Get-OdGroups, Resolve-*BushingPick*, ...);
# jig_tree.ps1 is the console walk (Invoke-Walk / Invoke-BushingPick / Read-Choice)
# lifted from drilljig.cmd STAGE 1 so the flat + curved tools resolve a hole OD +
# bushing length through the SAME logic. Both are pure (no Creo) - safe pre-connect.
. (Join-Path $ScriptDir 'lib\drilljig_core.ps1')
. (Join-Path $ScriptDir 'lib\jig_tree.ps1')
# Curved-jig pieces (all offline-tested; the Creo-firing bodies are canary-gated):
#   tangent_plane.ps1  - Build-TangentPlaneMacro / Invoke-TangentPlane: a datum plane
#     TANGENT to the curved surface AT a hole's datum point; its normal IS the surface
#     normal there, so it is BOTH a real normal-to-surface drilling reference AND the
#     ideal chip-relief slot sketch host (fact tangent-plane-at-point-on-surface).
#   curved_slots.ps1 / curved_slot_macros.ps1 - plan + drive the per-hole chip-relief
#     slot loop (arm the seed sketch on each hole's tangent plane BY ID -- proven-live
#     sketch-open-on-plane-by-id -- then Build-CutFinishMacro, canary-gated each).
. (Join-Path $ScriptDir 'lib\tangent_plane.ps1')
. (Join-Path $ScriptDir 'lib\curved_slots.ps1')
. (Join-Path $ScriptDir 'lib\curved_slot_macros.ps1')

# Resolve the blind-judge config once (BlueGPT REST). $null is fine - the STAGE-2
# hole-count gate still runs DETERMINISTICALLY; the packet is written for offline
# judging and the REST call is simply skipped.
$judgeCfg = Get-JudgeConfig -RepoRoot $ScriptDir -DefaultModel "sonnet"
if ($null -eq $judgeCfg) {
    Write-Host "  (blind judge not configured - hole-count gate runs deterministically; packet written for offline judging)" -ForegroundColor DarkGray
}

# drilljig_core needs its data dir for the catalog (Get-CatalogSpec resolves CSV
# paths under it). No session/model yet - STAGE 0 is pure, pre-connect.
try { Initialize-DrilljigCore -Session $null -Model $null -TypeObj $null -DataDir (Join-Path $ScriptDir 'data') } catch {}

# ============================================================================
# STAGE 0 - DECISION TREE (no Creo). Walk ONCE -> the hole diameter + bushing
# length, EXACTLY like drilljig.cmd STAGE 1. This is the curved tool's parity
# answer to "all of the hole and bushing selection". The resolved values take
# PRECEDENCE over last_jig_spec.json (below); skipping the tree falls back to the
# file, then to manual entry - so nothing regresses for a bare run.
#   --no-tree  : skip the walk entirely (old behavior: file/manual only).
# ============================================================================
$treeDia = $null; $treeBushLen = $null; $treeBushName = $null
$SkipTree = ($ScriptArgs -match '(?i)-{1,2}no-tree')
$treePath = Join-Path $ScriptDir 'docs\drill_jig_decision_tree.json'
if (-not $SkipTree -and (Test-Path $treePath)) {
    $tree = $null
    try { $tree = Get-Content $treePath -Raw | ConvertFrom-Json } catch {
        Write-Host "  (could not parse the decision tree - skipping STAGE 0: $($_.Exception.Message))" -ForegroundColor Yellow
    }
    if ($null -ne $tree) {
        Write-Host ""
        Write-Host "  ====================================================================" -ForegroundColor Cyan
        Write-Host "   STAGE 0 - Drill-jig decision tree (hole + bushing selection)" -ForegroundColor Cyan
        Write-Host "  ====================================================================" -ForegroundColor Cyan
        Write-Host "  (or press Q at any prompt to skip the tree and enter values by hand)" -ForegroundColor DarkGray

        $roots        = @($tree)
        $t0path       = [System.Collections.ArrayList]::new()
        $t0outcomes   = [System.Collections.ArrayList]::new()
        $script:Picks = [System.Collections.ArrayList]::new()

        $t0quit = $false
        foreach ($root in $roots) {
            if (-not (Invoke-Walk -Node $root -Path $t0path -Outcomes $t0outcomes)) { $t0quit = $true; break }
        }

        if ($t0quit) {
            Write-Host ""
            Write-Host "  Decision tree skipped - will use the handoff file / manual entry." -ForegroundColor Yellow
        } else {
            Write-Host ""
            Write-Host "  Your selections:" -ForegroundColor Green
            Write-Host ("    " + ($t0path -join "  >  ")) -ForegroundColor White
            foreach ($o in $t0outcomes) { Write-Host "    $o" -ForegroundColor White }
        }

        # LAST pick wins as the active hole spec (jiginator's model).
        if ($script:Picks.Count -gt 0) {
            $active  = $script:Picks[$script:Picks.Count - 1]
            $treeDia = [double]$active.HoleDiameter
            if ($null -ne $active.BushingLength) { try { $treeBushLen = [double]$active.BushingLength } catch {} }
            $treeBushName = [string]$active.Bushing
            Write-Host ("  Tree resolved: hole dia {0}`"  ({1})" -f $treeDia, $treeBushName) -ForegroundColor Cyan
            if ($null -ne $treeBushLen) {
                Write-Host ("  Bushing length {0}`" -> STAGE-1 thickness default (the jig wall = the bushing guide length)." -f $treeBushLen) -ForegroundColor Cyan
            }
        }
        Write-Host ""
    }
}

# ============================================================================
# JIGINATOR HANDOFF (optional) - the same last_jig_spec.json holeinator consumes
# ============================================================================
# If a jiginator walk wrote it, pre-fill the STAGE-2 hole diameter (HoleDiameter =
# bushing OD = the jig seat bore) and seed the STAGE-1 thickness guidance from it.
# Stale/absent file -> everything stays manual (the user always confirms). Pure
# file read, no Creo. BushingLength is read if jiginator ever emits it (not in the
# current handoff contract yet) so this is forward-compatible.
$jigSpec = $null; $jigDia = $null; $jigBushLen = $null; $jigBushName = $null
# STAGE 0 (the live tree walk above) takes PRECEDENCE over the file. If the tree
# resolved a hole spec, use it; otherwise fall back to last_jig_spec.json (an
# earlier jiginator/drilljig walk), then to manual entry.
if ($null -ne $treeDia) {
    $jigDia = $treeDia; $jigBushLen = $treeBushLen; $jigBushName = $treeBushName
    Write-Host "  Using STAGE-0 tree result: hole/seat dia $jigDia$(if ($jigBushName) { " ($jigBushName)" })" -ForegroundColor DarkGray
} else {
    $handoffPath = Join-Path $ScriptDir 'last_jig_spec.json'
    if (Test-Path $handoffPath) {
        try {
            $jigSpec = Get-Content $handoffPath -Raw | ConvertFrom-Json
            if ($null -ne $jigSpec.HoleDiameter  -and [double]$jigSpec.HoleDiameter  -gt 0) { $jigDia     = [double]$jigSpec.HoleDiameter }
            if ($null -ne $jigSpec.BushingLength -and [double]$jigSpec.BushingLength -gt 0) { $jigBushLen = [double]$jigSpec.BushingLength }
        } catch { $jigSpec = $null }
        if ($null -ne $jigDia) {
            $bn = ""
            try { if ($jigSpec.Bushing) { $bn = " ($($jigSpec.Bushing))"; $jigBushName = [string]$jigSpec.Bushing } } catch {}
            Write-Host "  jiginator handoff: hole/seat dia $jigDia$bn" -ForegroundColor DarkGray
        }
    }
}

# ============================================================================
# USER INPUT - THICKNESS (the jig wall = the bushing's guide length)
# ============================================================================
# Guidance (general jig practice, EDITABLE - re-verify against data\bushings*.csv):
# a drill bushing guides the bit over ~1.5x its diameter and a jig plate is
# typically 1-2x the tool diameter thick. If the hole diameter is known (handoff),
# show that band; soft-warn a too-thin wall AFTER entry. Advisory only, never blocks.
if ($null -ne $jigDia) {
    $loBand = [math]::Round(1.0 * $jigDia, 4); $hiBand = [math]::Round(2.0 * $jigDia, 4); $seat = [math]::Round(1.5 * $jigDia, 4)
    Write-Host "  Guidance: jig wall ~1-2x hole dia ($loBand - $hiBand); bushing seats over ~1.5x ($seat)." -ForegroundColor DarkGray
    Write-Host "  (general jig practice - verify; the chosen bushing's length is the real target)" -ForegroundColor DarkGray
}
$Thickness = $null
while ($null -eq $Thickness) {
    $tprompt = if ($null -ne $jigBushLen) { "  Drill-jig thickness [ENTER = bushing length $jigBushLen]" } else { "  Drill-jig thickness" }
    $raw = Read-Host $tprompt
    if ([string]::IsNullOrWhiteSpace($raw) -and $null -ne $jigBushLen) { $Thickness = $jigBushLen; break }
    $tv = 0.0
    if ([double]::TryParse(($raw.Trim()), [ref]$tv) -and $tv -gt 0) {
        $Thickness = $tv
    } else {
        Write-Host "  Enter a positive number (e.g. 0.5)." -ForegroundColor Yellow
    }
}
if ($null -ne $jigDia -and $Thickness -lt (1.5 * $jigDia)) {
    Write-Host "  NOTE: $Thickness is below ~1.5x the hole dia ($([math]::Round(1.5*$jigDia,4))) - a thin wall guides the" -ForegroundColor Yellow
    Write-Host "  drill over a short length and may let it wander. (advisory, not blocking)" -ForegroundColor Yellow
}
Write-Host "  Thickness: $Thickness" -ForegroundColor Green
Write-Host ""

# ============================================================================
# USER INPUT - STANDOFF / CHIP-CLEARANCE OFFSET (default 0 = flush, current behavior)
# ============================================================================
# The offset-surface distance was previously hard-driven to 0 (jig face coincident
# with the part). Exposing it lets the jig float a deliberate gap off the part for
# chip clearance / coating. DEFAULT 0 keeps the proven coincident behavior exactly.
# (Carr Lane: drilling chip clearance ~0.5-1.5x tool dia - editable guidance.)
$StandOff = 0.0
$soRaw = Read-Host "  Standoff / chip-clearance offset from the part (blank/0 = flush)"
if (-not [string]::IsNullOrWhiteSpace($soRaw)) {
    $sov = 0.0
    if ([double]::TryParse(($soRaw.Trim()), [ref]$sov) -and $sov -ge 0) { $StandOff = $sov }
    else { Write-Host "  Not a non-negative number - using 0 (flush)." -ForegroundColor Yellow }
}
if ($StandOff -gt 0) { Write-Host "  Standoff: $StandOff (jig floats off the part face)" -ForegroundColor Green }
Write-Host ""

# ============================================================================
# CONNECT  (edginator's block - GetActiveModel() first, then CurrentModel)
# ============================================================================
Write-Host "  Connecting to Creo..." -NoNewline

$proc = @(Get-Process -Name "xtop" -ErrorAction SilentlyContinue)[0]
if ($null -eq $proc) {
    Write-Host ""
    Write-Host "  FAILED: Creo process not found. Please start Creo Parametric." -ForegroundColor Red
    exit 1
}

$creoPath = $proc.Path
$Env:PRO_DIRECTORY = $creoPath.TrimEnd("xtop.exe")
$Env:PRO_COMM_MSG_EXE = $creoPath -replace "xtop.exe", "pro_comm_msg.exe"

try {
    $async = New-Object -ComObject pfcls.pfcAsyncConnection
}
catch {
    Write-Log "Attempting VB API registration..."
    $vb_path = $creoPath -replace "Common Files(.*)$", "Parametric\bin\vb_api_register.bat"
    if (Test-Path $vb_path) {
        Start-Process -Wait -FilePath $vb_path
        $async = New-Object -ComObject pfcls.pfcAsyncConnection
    }
    else {
        Write-Host ""
        Write-Host "  FAILED: VB API registration script not found." -ForegroundColor Red
        exit 1
    }
}

$connection = $async.Connect($null, $null, $null, $null)
$session = $connection.Session
$model = $null
try { $model = $session.GetActiveModel() } catch {}
if ($null -eq $model) { try { $model = $session.CurrentModel } catch {} }

if ($null -eq $model) {
    Write-Host ""
    Write-Host "  FAILED: No model open in Creo." -ForegroundColor Red
    exit 1
}

Write-Host " Connected to $($model.FileName)" -ForegroundColor Green

# Mode guard: by-ID selection + feature creation resolve against the active model.
# In assembly mode that is the .asm, not the part. Key off the filename extension
# (EpfcModelType enum ints unconfirmed on this build - drilljig/edginator lesson).
$modelFile = ""
try { $modelFile = [string]$model.FileName } catch {}
if ($modelFile -match '\.asm(\.\d+)?$') {
    Write-Host ""
    Write-Host "  STOP: the active model is an ASSEMBLY ($modelFile)." -ForegroundColor Yellow
    Write-Host "  This tool builds a jig blank in a single PART. Open the PART, then re-run." -ForegroundColor Yellow
    try { $connection.Disconnect($null) } catch {}
    exit 1
}

# Suppress UI noise during the run, restore in finally (toolkit convention).
$origVisibleMapkeys = $null
$origDynamicPreview = $null
try {
    $vals = $session.GetConfigOptionValues("visible_mapkeys")
    if ($null -ne $vals -and $vals.Count -gt 0) { $origVisibleMapkeys = $vals.Item(0) }
} catch {}
try {
    $vals = $session.GetConfigOptionValues("dynamic_preview")
    if ($null -ne $vals -and $vals.Count -gt 0) { $origDynamicPreview = $vals.Item(0) }
} catch {}
try {
    $session.SetConfigOption("visible_mapkeys", "no") | Out-Null
    $session.SetConfigOption("dynamic_preview", "no") | Out-Null
} catch {}

$modelItemType = New-Object -ComObject pfcls.pfcModelItemType

# Re-initialize the shared drilljig-core scope with the LIVE session/model now that we
# are connected (STAGE 0 initialized it pre-connect with only the data dir). The
# tangent-plane + curved-slot COM helpers (Invoke-TangentPlane / Invoke-CurvedSlot*)
# read $script:DJSession/DJModel/DJType from here, exactly like Invoke-VerifiedSeedCut.
try { Initialize-DrilljigCore -Session $session -Model $model -TypeObj $modelItemType -DataDir (Join-Path $ScriptDir 'data') } catch {}

try {

$script:blankMade = $false   # set true once the offset+thicken blank is created (gates STAGE 2)

# ============================================================================
# STAGE 1, STEP 1 - SELECT THE SURFACE TO JIG (by hand, read ID-only)
# ============================================================================
Write-Host ""
Write-Host "  STEP 1 - In Creo, CLICK the surface you want the drill-jig to follow" -ForegroundColor Cyan
Write-Host "  (Ctrl-click for several surfaces of one quilt). Then press ENTER here." -ForegroundColor Cyan
Read-Host

$res = Resolve-SelectedSurfaces -Session $session -TypeObj $modelItemType
$surfIds = @($res.Surfaces)
if ($res.Rejected.Count -gt 0) {
    Write-Host ("  Ignored $($res.Rejected.Count) non-surface selection(s):") -ForegroundColor Yellow
    foreach ($r in ($res.Rejected | Select-Object -First 10)) { Write-Host "      $r" -ForegroundColor DarkGray }
}
if ($surfIds.Count -eq 0) {
    throw "No surface resolved from the selection. Click a model SURFACE (not a feature/edge/datum), then press ENTER."
}
Write-Host "  Captured $($surfIds.Count) surface(s): $($surfIds -join ', ')" -ForegroundColor Green
Write-Host ""

# ============================================================================
# STAGE 1, STEP 2 - CONFIRM, then CREATE the offset+thicken features (one atomic macro)
# ============================================================================
Write-Host "  Ready: offset surface(s) $($surfIds -join ', ') at 0, then thicken to $Thickness." -ForegroundColor Cyan
Write-Host "  Do not touch Creo while this runs." -ForegroundColor DarkGray
$go = Read-Host "  Proceed? (y/N)"
if ($go -notmatch '^[Yy]$') {
    Write-Host "  Cancelled - nothing created." -ForegroundColor Yellow
} else {
    # Snapshot features AND bodies BEFORE so the new offset + thicken features and
    # the new thicken BODY are all found by diff.
    $beforeFeat   = Get-FeatureIdSet -Model $model -TypeObj $modelItemType
    $beforeBodies = Get-BodyIdSet    -Model $model -TypeObj $modelItemType

    $stamp = $null
    try { $stamp = $model.VersionStamp } catch {}

    # ONE atomic macro: select surface(s) by ID -> ProCmdFtOffset (consumes them)
    # -> offset dashboard options -> Done -> ProCmdFtThicken -> Done.
    $macro = (Get-SelectSurfacesByIdMacro -SurfIds $surfIds) + (Get-OffsetThickenMacro)
    Write-Host ""
    Invoke-Macro "offset surface (0) + thicken" $macro

    $changed = $false
    if ($null -ne $stamp) { $changed = Wait-ModelModified -Model $model -PreviousStamp $stamp }

    if (-not $changed) {
        # Canary failed: the macro did not modify the model. Do NOT dimension blind.
        Write-Host ""
        Write-Host "  ABORT: the model did not change (VersionStamp unchanged)." -ForegroundColor Red
        Write-Host "  The offset/thicken did not fire. Check Creo:" -ForegroundColor Red
        Write-Host "    - did the offset dashboard pick up the pre-selected surface? If it" -ForegroundColor Red
        Write-Host "      sat waiting for a pick, the offset needs the open-collector feed" -ForegroundColor Red
        Write-Host "      (see Get-OffsetThickenMacro 'LIVE FALLBACK' note)." -ForegroundColor Red
        Write-Host "    - do the recorded widget names still match (visible_mapkeys yes)?" -ForegroundColor Red
    } else {
        Write-Host ""
        Write-Host "  Features created. Driving the dimensions (regenerative)..." -ForegroundColor Cyan

        # Find the new features (offset + thicken) and their linear dims. By
        # creation order the LOWER new id is the offset, the HIGHER is the thicken.
        $newFeats = @(Get-NewFeatureLinearDims -Model $model -TypeObj $modelItemType -BeforeIds $beforeFeat)
        Write-Log ("New features: " + (($newFeats | ForEach-Object { "$($_.Id)[$($_.Dims -join ',')]" }) -join '  ')) "DarkGray"

        if ($newFeats.Count -eq 0) {
            Write-Host "  No new features were enumerated, yet the model changed. Set the offset" -ForegroundColor Yellow
            Write-Host "  (0) and thickness ($Thickness) manually in Creo, or re-run." -ForegroundColor Yellow
        } else {
            $offsetFeat  = $newFeats[0]
            $thickenFeat = if ($newFeats.Count -ge 2) { $newFeats[$newFeats.Count - 1] } else { $null }

            $offsetSym = if ($offsetFeat.Dims.Count -ge 1) { [string]$offsetFeat.Dims[0] } else { $null }
            $thickSym  = if ($null -ne $thickenFeat -and $thickenFeat.Dims.Count -ge 1) { [string]$thickenFeat.Dims[0] } else { $null }

            if ($null -eq $thickenFeat) {
                Write-Host "  WARNING: only ONE new feature was found (id $($offsetFeat.Id)). Expected the" -ForegroundColor Yellow
                Write-Host "  offset AND the thicken. The offset+thicken may not have both committed;" -ForegroundColor Yellow
                Write-Host "  inspect Creo. Not auto-driving a thickness onto an ambiguous feature." -ForegroundColor Yellow
            }

            # --- OFFSET -> standoff (default 0 = coincident; chip-clearance if >0) ---
            if ($null -ne $offsetSym) {
                $now = Set-DimAndConfirm -Model $model -TypeObj $modelItemType -Sym $offsetSym -Target $StandOff
                if ($null -ne $now -and [math]::Abs($now - $StandOff) -lt 1e-4) {
                    Write-Host "    Offset  feat $($offsetFeat.Id)  $offsetSym = $now  (held at $StandOff)" -ForegroundColor Green
                } else {
                    Write-Host "    Offset  feat $($offsetFeat.Id)  $offsetSym = $now  (wanted $StandOff - did NOT hold; surface may have self-intersected if offset is large)" -ForegroundColor Yellow
                }
            } else {
                Write-Host "    Offset  feat $($offsetFeat.Id) exposed no linear dim - assuming its default ($StandOff)." -ForegroundColor DarkGray
            }

            # --- THICKNESS -> entered value ----------------------------------
            if ($null -ne $thickSym) {
                $now = Set-DimAndConfirm -Model $model -TypeObj $modelItemType -Sym $thickSym -Target $Thickness
                if ($null -ne $now -and [math]::Abs($now - $Thickness) -lt 1e-4) {
                    Write-Host "    Thicken feat $($thickenFeat.Id)  $thickSym = $now  (held at $Thickness)" -ForegroundColor Green
                    $script:thicknessConfirmed = $true
                } else {
                    Write-Host "    Thicken feat $($thickenFeat.Id)  $thickSym = $now  (wanted $Thickness - did NOT hold)" -ForegroundColor Yellow
                }
            } elseif ($null -ne $thickenFeat) {
                Write-Host "    Thicken feat $($thickenFeat.Id) exposed no linear dim - set thickness $Thickness manually in Creo." -ForegroundColor Yellow
            }
        }

        # Identify the NEW body the thicken created (diff vs the before-snapshot) so
        # STAGE 2 drills into the blank we just built. Index in ListItems(ITEM_BODY)
        # == the hole dashboard's body-selector index (holeinator's assumption).
        $script:blankMade = $true
        $script:jigBodyIndex = $null; $script:jigBodyId = $null; $script:jigBodyName = $null
        try {
            $afterBodies = @($model.ListItems($modelItemType.ITEM_BODY))
            for ($bi = 0; $bi -lt $afterBodies.Count; $bi++) {
                $bid = $null
                try { $bid = [int]$afterBodies[$bi].Id } catch {}
                if ($null -ne $bid -and -not $beforeBodies.ContainsKey($bid)) {
                    $script:jigBodyIndex = $bi; $script:jigBodyId = $bid
                    try { $script:jigBodyName = [string]$afterBodies[$bi].GetName() } catch {}
                    break
                }
            }
        } catch {}
        if ($null -ne $script:jigBodyIndex) {
            Write-Host "    New blank body: '$script:jigBodyName' (index $script:jigBodyIndex, id $script:jigBodyId)" -ForegroundColor Green
        } else {
            Write-Host "    (could not auto-identify the new body; STAGE 2 will ask which body to drill)" -ForegroundColor DarkGray
        }
    }
}

# ============================================================================
# STAGE 2 - DRILL ON-POINT HOLES (normal to the surface) into the new body
# ============================================================================
# Reuses holeinator's proven On-Point hole machinery, retargeted at the blank we
# just built: holes at datum points YOU select, drilled NORMAL to the surface
# (orientation hypothesis + live-recording fallback in Build-NormalHoleMacro).
# Only runs if STAGE 1 actually built the blank. Each step is ID-only, the body is
# the new blank body, and a VersionStamp canary aborts after hole #1 if nothing
# changed (never drills a broken macro N times).
if ($script:blankMade) {
    Write-Host ""
    $drill = Read-Host "  STAGE 2 - drill On-Point holes into the blank now? (y/N)"
    if ($drill -match '^[Yy]$') {

        # --- target body: the new blank (fall back to a prompt if not identified) ---
        $bodyIndex = $script:jigBodyIndex
        if ($null -eq $bodyIndex) {
            $bodyList = @()
            try { $bodyList = @($model.ListItems($modelItemType.ITEM_BODY)) } catch {}
            if ($bodyList.Count -gt 1) {
                Write-Host "  Could not auto-identify the new body. Bodies in the part:" -ForegroundColor Yellow
                for ($i = 0; $i -lt $bodyList.Count; $i++) {
                    $bn = try { $bodyList[$i].GetName() } catch { "(unnamed)" }
                    Write-Host ("      {0}) {1}" -f $i, $bn) -ForegroundColor White
                }
                while ($true) {
                    $raw = Read-Host ("  Body index (0-{0})" -f ($bodyList.Count - 1))
                    $n = -1
                    if ([int]::TryParse($raw, [ref]$n) -and $n -ge 0 -and $n -lt $bodyList.Count) { $bodyIndex = $n; break }
                    Write-Host "  Enter a valid index." -ForegroundColor Yellow
                }
            } else { $bodyIndex = 0 }
        } else {
            Write-Host "  Drilling into the new blank body '$script:jigBodyName' (index $bodyIndex)." -ForegroundColor Cyan
        }

        # --- STEP 1: orientation mode + build the (point, surface) pair list ---
        # CONFORMAL FIX: each hole can carry its OWN normal-reference surface, so a
        # curved/multi-face jig orients every bore to its LOCAL face (not one global
        # surface). Mode 1 (default) keeps the fast "all holes share the STAGE-1
        # surface" path - byte-for-byte the previous behavior; mode 2 pairs each point
        # with the surface it sits on. Both are ID-ONLY (Resolve-SelectedPoints /
        # Resolve-SelectedSurfaces walk the same buffer; never a coordinate read).
        # -defaultorient ignores the surface, so the pairing surface is moot there.
        $perHole = $false
        if (-not $DefaultOrient -and $surfIds.Count -ge 1) {
            Write-Host ""
            Write-Host "  Orientation surface:" -ForegroundColor Cyan
            Write-Host "    [1] one surface for ALL holes (fast; holes share STAGE-1 surface $($surfIds[0]))" -ForegroundColor White
            Write-Host "    [2] per-hole surface (curved/multi-face; pick each point WITH its surface)" -ForegroundColor White
            $omode = Read-Host "  Choose 1 or 2 [1]"
            if ($omode.Trim() -eq '2') { $perHole = $true }
        }

        $holePairs = @()
        if ($perHole) {
            Write-Host ""
            Write-Host "  Per-hole mode: in Creo Ctrl-click ONE datum point AND the surface it sits on," -ForegroundColor Cyan
            Write-Host "  then press ENTER. An empty ENTER (nothing selected) finishes." -ForegroundColor Cyan
            while ($true) {
                Read-Host "  Point + surface for hole $($holePairs.Count + 1) (empty ENTER to finish)"
                $pp = @((Resolve-SelectedPoints   -Session $session -TypeObj $modelItemType).Points)
                $ss = @((Resolve-SelectedSurfaces -Session $session -TypeObj $modelItemType).Surfaces)
                if ($pp.Count -eq 0 -and $ss.Count -eq 0) { break }
                if ($pp.Count -ne 1 -or $ss.Count -lt 1) {
                    Write-Host "    Need exactly ONE datum point AND its surface selected (got $($pp.Count) point / $($ss.Count) surface). Try again." -ForegroundColor Yellow
                    continue
                }
                $holePairs += [pscustomobject]@{ PointId = [int]$pp[0]; SurfaceId = [int]$ss[0] }
                Write-Host "    + hole $($holePairs.Count): point $($pp[0]) normal to surface $($ss[0])" -ForegroundColor Green
            }
        } else {
            Write-Host ""
            Write-Host "  In Creo, select the target datum points on the blank, then press ENTER here." -ForegroundColor Cyan
            Read-Host
            $pres = Resolve-SelectedPoints -Session $session -TypeObj $modelItemType
            if ($pres.Rejected.Count -gt 0) {
                Write-Host ("  Ignored $($pres.Rejected.Count) non-point selection(s):") -ForegroundColor Yellow
                foreach ($r in ($pres.Rejected | Select-Object -First 10)) { Write-Host "      $r" -ForegroundColor DarkGray }
            }
            $os = if ($surfIds.Count -ge 1) { [int]$surfIds[0] } else { 0 }
            foreach ($p in @($pres.Points)) { $holePairs += [pscustomobject]@{ PointId = [int]$p; SurfaceId = $os } }
        }

        if ($holePairs.Count -eq 0) {
            Write-Host "  No holes resolved from the selection - skipping drilling." -ForegroundColor Yellow
        } else {
            Write-Host "  Captured $($holePairs.Count) hole(s)." -ForegroundColor Green

            # --- STEP 2: diameter (pre-filled from the jiginator handoff bushing OD) ---
            Write-Host ""
            $holeDia = 0.0
            while ($holeDia -le 0) {
                $dprompt = if ($null -ne $jigDia) { "  Hole / bushing-seat diameter [ENTER = $jigDia]" } else { "  Hole diameter" }
                $raw = Read-Host $dprompt
                if ([string]::IsNullOrWhiteSpace($raw) -and $null -ne $jigDia) { $holeDia = $jigDia; break }
                $d = 0.0
                if ([double]::TryParse(($raw.Trim()), [ref]$d) -and $d -gt 0) { $holeDia = $d }
                else { Write-Host "  Enter a positive number." -ForegroundColor Yellow }
            }

            # Orientation note (each hole's normal-reference surface now lives in its
            # $holePairs entry - per-hole in mode 2, the shared STAGE-1 surface in mode 1).
            $orientNote = if ($DefaultOrient)  { "Creo default On-Point direction (-defaultorient)" }
                          elseif ($TangentOrient) { "normal to a TANGENT PLANE built at each hole (tangent-orient) - normal-to-surface by construction" }
                          elseif ($perHole)    { "normal to each hole's OWN surface (per-hole) - verify visually" }
                          else                 { "normal to surface $($surfIds[0]) (one surface for all - verify visually)" }

            Write-Host ""
            Write-Host "  Ready: $($holePairs.Count) On-Point hole(s), dia $holeDia, thru all, body index $bodyIndex." -ForegroundColor Cyan
            Write-Host "  Orientation: $orientNote." -ForegroundColor Cyan
            Write-Host "  Do not touch Creo while this runs." -ForegroundColor DarkGray
            $go2 = Read-Host "  Proceed? (y/N)"
            if ($go2 -notmatch '^[Yy]$') {
                Write-Host "  Cancelled - no holes drilled." -ForegroundColor Yellow
            } else {
                Write-Host ""
                $total = $holePairs.Count; $idx = 0; $holesMade = 0; $holesNoop = 0; $holesFail = 0; $holeAbort = $false
                $script:lastPct = -1

                # Blind-eval baseline: count cylinders at the target radius BEFORE drilling,
                # so the AFTER-minus-BEFORE delta isolates the new bores (robust to any
                # pre-existing same-radius geometry on the part).
                $cylBefore = $null
                try { $cylBefore = Count-Cylinders -Model $model -TypeObj $modelItemType -TargetRadius ($holeDia / 2.0) -RadTol 1e-3 } catch {}

                foreach ($pair in $holePairs) {
                    $idx++
                    Show-Progress ([Math]::Floor(($idx / $total) * 100)) "Hole $idx/$total"

                    # --tangent-orient: build a TANGENT datum plane at (point, surface)
                    # first; its normal IS the surface normal there, so drilling On-Point
                    # normal to it is normal-to-surface BY CONSTRUCTION. Canary-gated: if
                    # the plane is not created we FALL BACK to the proven surface-pre-select
                    # macro for this hole (never assume; never block the drill). The plane
                    # id is stashed on the pair so STAGE 3 reuses it as the slot sketch host.
                    $orientSurfId = [int]$pair.SurfaceId
                    if ($TangentOrient -and -not $DefaultOrient -and [int]$pair.SurfaceId -gt 0 -and [int]$pair.PointId -gt 0) {
                        $tp = Invoke-TangentPlane -PointId ([int]$pair.PointId) -SurfaceId ([int]$pair.SurfaceId)
                        if ($tp.Created -and [int]$tp.PlaneId -gt 0) {
                            Add-Member -InputObject $pair -MemberType NoteProperty -Name TangentPlaneId -Value ([int]$tp.PlaneId) -Force
                        } else {
                            Write-Log ("tangent plane for hole $idx not created ($($tp.Reason)) - using the surface pre-select for this hole.") 'Yellow'
                        }
                    }

                    $hm = Build-NormalHoleMacro -PointId $pair.PointId -SurfaceId $orientSurfId -Diameter $holeDia -BodyIndex $bodyIndex -DefaultOrient:$DefaultOrient
                    $hchanged = $false
                    try {
                        $hstamp = $model.VersionStamp
                        $session.RunMacro($hm)
                        $hchanged = Wait-ModelModified -Model $model -PreviousStamp $hstamp
                    } catch { $holesFail++ }
                    if ($hchanged) { $holesMade++ } else { $holesNoop++ }

                    # canary: hole #1 must change the model, else stop (widget drift /
                    # the orientation pre-select may be the problem - try -defaultorient).
                    if ($idx -eq 1 -and -not $hchanged) {
                        Show-Progress 100 "Canary failed"
                        Write-Host ""
                        Write-Host "  ABORT: the first hole did not modify the model (VersionStamp" -ForegroundColor Red
                        Write-Host "  unchanged). Stopped after 1 attempt. Check Creo: did the hole" -ForegroundColor Red
                        Write-Host "  dashboard open / error? If the surface pre-select for orientation" -ForegroundColor Red
                        Write-Host "  is the culprit, re-run with -defaultorient to use holeinator's" -ForegroundColor Red
                        Write-Host "  exact proven macro and confirm the rest of the pipeline." -ForegroundColor Red
                        $holeAbort = $true
                        break
                    }
                }
                if (-not $holeAbort) { Show-Progress 100 "Holes done" }
                Write-Host ""
                Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
                Write-Host ("  Points targeted : {0}" -f $total) -ForegroundColor White
                Write-Host ("  Model changed   : {0}" -f $holesMade) -ForegroundColor White
                if ($holesNoop -gt 0) { Write-Host ("  No-op           : {0}" -f $holesNoop) -ForegroundColor Yellow }
                if ($holesFail -gt 0) { Write-Host ("  Macro errors    : {0}" -f $holesFail) -ForegroundColor Yellow }
                Write-Host ""
                if ($holeAbort) {
                    Write-Host "  STOPPED after the canary - inspect Creo." -ForegroundColor Red
                } else {
                    if ($holesMade -eq $total -and $holesFail -eq 0) {
                        Write-Host "  All $total fire(s) changed the model. Measuring the result..." -ForegroundColor Cyan
                    } else {
                        Write-Host "  Finished with issues - $holesMade of $total changed the model. Measuring anyway..." -ForegroundColor Yellow
                    }

                    # BLIND-EVAL GATE: count bores at the target radius (delta vs before) and
                    # compare to the intended hole count. This replaces "macros fired" as the
                    # confirmation - it measures the model independently of the per-fire stamp.
                    $cylAfter = $null
                    try { $cylAfter = Count-Cylinders -Model $model -TypeObj $modelItemType -TargetRadius ($holeDia / 2.0) -RadTol 1e-3 } catch {}
                    $modelName = try { [string]$model.FileName } catch { "(unknown)" }
                    $gate = $null
                    if ($null -ne $cylBefore -and $null -ne $cylAfter) {
                        $gate = Invoke-JigEval -Model $model -TypeObj $modelItemType -RepoRoot $ScriptDir -JudgeCfg $judgeCfg `
                            -IntendedCount $total -Diameter $holeDia -CylBefore $cylBefore -CylAfter $cylAfter -ModelName $modelName
                    }

                    if ($gate -eq $true) {
                        $script:holesConfirmed = $true
                        Write-Host "  CONFIRMED: $total bore(s) at diameter $holeDia measured on the model." -ForegroundColor Green
                    } elseif ($null -eq $gate) {
                        # couldn't measure (0-surface walk) - fall back to the per-fire signal, honestly labelled
                        if ($holesMade -eq $total -and $holesFail -eq 0) {
                            Write-Host "  Holes fired (model changed for each); bore count UNVERIFIED by measurement - verify visually." -ForegroundColor Yellow
                        } else {
                            Write-Host "  Finished with issues and could not measure - inspect Creo." -ForegroundColor Yellow
                        }
                    } else {
                        Write-Host "  NOT confirmed: the measured bore count/diameter did not match $total hole(s) - inspect Creo." -ForegroundColor Yellow
                    }
                    if ($TangentOrient -and -not $DefaultOrient) {
                        Write-Host "  Orientation: drilled normal to per-hole TANGENT PLANES (normal-to-surface by construction; verify visually)." -ForegroundColor DarkGray
                    } elseif (-not $DefaultOrient) {
                        Write-Host "  Orientation (normal-to-surface) is still a VISUAL check (see Build-NormalHoleMacro / --probe-orient roadmap)." -ForegroundColor DarkGray
                    }

                    # Hand the drilled holes (+ any tangent planes) to STAGE 3 so the
                    # curved chip-relief slot loop can arm each seed sketch on the hole's
                    # tangent plane BY ID. Only when we actually made holes.
                    if (-not $holeAbort -and $holesMade -gt 0) {
                        $script:curvedHolePairs = @($holePairs)
                        $script:curvedHoleDia   = $holeDia
                        $script:curvedBodyIndex = $bodyIndex
                    }
                }
            }
        }
    }
}

# ============================================================================
# STAGE 3 - CURVED CHIP-RELIEF SLOTS (one blind rectangular slot per hole)
# ============================================================================
# The curved analog of the flat jig's slot relief. For each drilled hole, arm a seed
# rectangle sketch on that hole's TANGENT PLANE (proven-live sketch-open-on-plane-by-ID
# -- the plane is tangent at the hole so the slot cuts NORMAL to the surface, the user's
# acceptance bar), the operator draws the rectangle, then Build-CutFinishMacro cuts it,
# canary-gated. NO pattern (per-hole individual cuts -- there is no programmatic copy API
# for arbitrary curved positions). Needs per-hole TANGENT PLANES, so it requires
# --tangent-orient (which captured $pair.TangentPlaneId during drilling); otherwise it
# reports what is missing and skips. Everything is opt-out via --no-slots.
if (-not $NoSlots -and $null -ne $script:curvedHolePairs -and @($script:curvedHolePairs).Count -gt 0) {
    Write-Host ""
    Write-Host "  ====================================================================" -ForegroundColor Cyan
    Write-Host "   STAGE 3 - curved chip-relief slots (one per hole, normal-to-surface)" -ForegroundColor Cyan
    Write-Host "  ====================================================================" -ForegroundColor Cyan

    # Build the per-hole slot-planner input: each hole needs a SketchPlaneId (its tangent
    # plane). A hole with no captured tangent plane (drilled without --tangent-orient, or
    # its tangent plane missed) has PlaneId 0 -> Get-CurvedSlotPlan warns + the loop
    # SKIPS it (fall back to a hand-drawn slot), never silently cut on the wrong plane.
    $slotHoles = @()
    $withPlane = 0
    foreach ($pair in @($script:curvedHolePairs)) {
        # $plId, NOT $pid -- $PID is a PowerShell read-only automatic variable; assigning
        # to it throws "Cannot overwrite variable PID because it is read-only or constant".
        $plId = 0
        try { if ($null -ne $pair.TangentPlaneId) { $plId = [int]$pair.TangentPlaneId } } catch {}
        if ($plId -gt 0) { $withPlane++ }
        $slotHoles += [pscustomobject]@{ Id = [int]$pair.PointId; PlaneId = $plId; RowKey = $null }
    }

    if ($withPlane -eq 0) {
        Write-Host "  No per-hole tangent planes were captured, so there is no by-ID sketch host" -ForegroundColor Yellow
        Write-Host "  for the seed slots. Re-run with --tangent-orient (builds a tangent plane at" -ForegroundColor Yellow
        Write-Host "  each hole) to enable hands-free curved slots. Skipping STAGE 3." -ForegroundColor Yellow
    } else {
        $doSlots = Read-Host "  Cut a chip-relief slot at each hole now? (y/N)"
        if ($doSlots -notmatch '^[Yy]$') {
            Write-Host "  Skipped chip-relief slots." -ForegroundColor DarkGray
        } else {
            # slot width = the hole diameter (matches the flat tool). depth default 0.25"
            # (absolute), overridable via --slot-depth N (shared parse with drilljig.cmd).
            $slotDepth = 0.25
            $mSd = [regex]::Match($ScriptArgs, '(?i)--slot-depth\s+([0-9]*\.?[0-9]+)')
            if ($mSd.Success) { $sdv = [double]$mSd.Groups[1].Value; if ($sdv -gt 0) { $slotDepth = $sdv } }
            $slotW = [double]$script:curvedHoleDia

            $plan = Get-CurvedSlotPlan -Holes $slotHoles -SlotWidth $slotW -Mode 'per-hole'
            $gate = Test-CurvedSlotPlan -Plan $plan
            if (-not $plan.Valid -or -not $gate.Ok) {
                Write-Host "  Could not build a usable slot plan - skipping." -ForegroundColor Yellow
                foreach ($e in @($plan.Errors)) { Write-Host "    $e" -ForegroundColor DarkGray }
                foreach ($e in @($gate.Issues)) { Write-Host "    $e" -ForegroundColor DarkGray }
            } else {
                foreach ($w in @($plan.Warnings)) { Write-Host "    note: $w" -ForegroundColor DarkGray }
                Write-Host ("  {0} seed(s), width {1}, depth {2}. For each: the sketcher opens on the hole's" -f $plan.Count, $slotW, $slotDepth) -ForegroundColor Cyan
                Write-Host "  tangent plane; DRAW the rectangle, leave the sketch OPEN, then press ENTER." -ForegroundColor Cyan

                # DrawPrompt: the manual pause (a RunMacro can't draw). The lib calls it as
                # (& $DrawPrompt $seed); VerifyPrompt as (& $VerifyPrompt $seed $flip) on the
                # FIRST cut only (undo+flip+redraw on wrong, reuse the flip for the rest).
                $drawCb = {
                    param($seed)
                    Write-Host ("  Draw the rectangle over hole '$($seed.Key)', leave the sketch OPEN.") -ForegroundColor Magenta
                    Read-Host "    Press ENTER when the rectangle is drawn"
                }
                $verifyCb = {
                    param($seed, $flip)
                    $a = Read-Host "    Did the slot cut INTO the plate at the right depth? (y = keep+reuse direction / n = undo+flip+redraw)"
                    return ($a -match '^[Yy]')
                }

                $res = Invoke-CurvedSlotPlanRun -Plan $plan -Depth $slotDepth -BodyIndex $script:curvedBodyIndex `
                    -DrawPrompt $drawCb -VerifyPrompt $verifyCb -OnPoll { }
                Write-Host ""
                Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
                Write-Host ("  Slots cut     : {0}" -f $res.SeedsCut) -ForegroundColor White
                if ($res.SeedsSkipped -gt 0) { Write-Host ("  Skipped       : {0} (no tangent plane; draw by hand)" -f $res.SeedsSkipped) -ForegroundColor Yellow }
                if ($res.SeedsFailed  -gt 0) { Write-Host ("  Failed        : {0} (canary miss - inspect Creo)" -f $res.SeedsFailed) -ForegroundColor Yellow }
                foreach ($w in @($res.Warnings)) { Write-Host "    $w" -ForegroundColor DarkGray }
                if ($res.SeedsCut -gt 0) { $script:slotsCut = $true }
            }
        }
    }
}

# ============================================================================
# REPORT
# ============================================================================
$elapsed = (Get-Date) - $startTime
Write-Host ""
Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
if ($script:macroFailures -gt 0) {
    Write-Host "  Completed with $($script:macroFailures) mapkey failure(s) - see red lines above." -ForegroundColor Yellow
} elseif ($script:thicknessConfirmed) {
    Write-Host "  Done - offset+thicken blank created and thickness re-read at $Thickness." -ForegroundColor Green
    if ($script:holesConfirmed) {
        Write-Host "  STAGE 2 holes created (see the per-hole report above)." -ForegroundColor Green
    }
    if ($script:slotsCut) {
        Write-Host "  STAGE 3 chip-relief slots cut (see the per-slot report above)." -ForegroundColor Green
    }
    Write-Host "  NOTE: dim re-read, NOT a geometric measurement of the curved slab." -ForegroundColor DarkGray
    Write-Host "  Verify the conformal jig blank (and any holes) visually in Creo." -ForegroundColor DarkGray
} else {
    Write-Host "  Finished - inspect the result in Creo (see notes above)." -ForegroundColor Yellow
}
Write-Host ("  Elapsed: {0:n1}s" -f $elapsed.TotalSeconds) -ForegroundColor DarkGray

} finally {
    try {
        if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null }
        if ($null -ne $origDynamicPreview)  { $session.SetConfigOption("dynamic_preview",  $origDynamicPreview)  | Out-Null }
    } catch {}

    if ($null -ne $modelItemType) {
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($modelItemType) | Out-Null } catch {}
    }
    try { $connection.Disconnect($null) } catch {}
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}

Write-Host ""
Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
