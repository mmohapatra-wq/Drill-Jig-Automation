<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

# ============================================================================
# drilljig3d.cmd - conformal 3D drill-jig blank from a clicked surface
# ============================================================================
# "I want a drill-jig that follows a curved face." You enter a THICKNESS, click
# the SURFACE you want jigged, and this tool:
#   1. Creates an OFFSET-surface feature from that face at offset = 0 (a coincident
#      quilt copy of the face), then
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

# ============================================================================
# USER INPUT - THICKNESS (the whole point of the jig; require a positive number)
# ============================================================================
$Thickness = $null
while ($null -eq $Thickness) {
    $raw = Read-Host "  Drill-jig thickness"
    $tv = 0.0
    if ([double]::TryParse(($raw.Trim()), [ref]$tv) -and $tv -gt 0) {
        $Thickness = $tv
    } else {
        Write-Host "  Enter a positive number (e.g. 0.5)." -ForegroundColor Yellow
    }
}
Write-Host "  Thickness: $Thickness" -ForegroundColor Green
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

            # --- OFFSET -> 0 -------------------------------------------------
            if ($null -ne $offsetSym) {
                $now = Set-DimAndConfirm -Model $model -TypeObj $modelItemType -Sym $offsetSym -Target 0.0
                if ($null -ne $now -and [math]::Abs($now) -lt 1e-4) {
                    Write-Host "    Offset  feat $($offsetFeat.Id)  $offsetSym = $now  (held at 0)" -ForegroundColor Green
                } else {
                    Write-Host "    Offset  feat $($offsetFeat.Id)  $offsetSym = $now  (wanted 0 - did NOT hold)" -ForegroundColor Yellow
                }
            } else {
                Write-Host "    Offset  feat $($offsetFeat.Id) exposed no linear dim - assuming its default (likely 0)." -ForegroundColor DarkGray
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

        # --- STEP 1: select target datum points (ID-only) ---
        Write-Host ""
        Write-Host "  In Creo, select the target datum points on the blank, then press ENTER here." -ForegroundColor Cyan
        Read-Host
        $pres = Resolve-SelectedPoints -Session $session -TypeObj $modelItemType
        $pointIds = @($pres.Points)
        if ($pres.Rejected.Count -gt 0) {
            Write-Host ("  Ignored $($pres.Rejected.Count) non-point selection(s):") -ForegroundColor Yellow
            foreach ($r in ($pres.Rejected | Select-Object -First 10)) { Write-Host "      $r" -ForegroundColor DarkGray }
        }
        if ($pointIds.Count -eq 0) {
            Write-Host "  No datum points resolved from the selection - skipping drilling." -ForegroundColor Yellow
        } else {
            Write-Host "  Captured $($pointIds.Count) point id(s): $($pointIds -join ', ')" -ForegroundColor Green

            # --- STEP 2: diameter ---
            Write-Host ""
            $holeDia = 0.0
            while ($holeDia -le 0) {
                $raw = Read-Host "  Hole diameter"
                $d = 0.0
                if ([double]::TryParse(($raw.Trim()), [ref]$d) -and $d -gt 0) { $holeDia = $d }
                else { Write-Host "  Enter a positive number." -ForegroundColor Yellow }
            }

            # Orientation reference = the FIRST surface picked in STAGE 1 (normal varies
            # across a multi-surface pick; v1 uses the first). -defaultorient skips it.
            $orientSurf = [int]$surfIds[0]
            $orientNote = if ($DefaultOrient) { "Creo default On-Point direction (-defaultorient)" } else { "normal to surface $orientSurf (surface pre-select - verify visually)" }

            Write-Host ""
            Write-Host "  Ready: $($pointIds.Count) On-Point hole(s), dia $holeDia, thru all, body index $bodyIndex." -ForegroundColor Cyan
            Write-Host "  Orientation: $orientNote." -ForegroundColor Cyan
            Write-Host "  Do not touch Creo while this runs." -ForegroundColor DarkGray
            $go2 = Read-Host "  Proceed? (y/N)"
            if ($go2 -notmatch '^[Yy]$') {
                Write-Host "  Cancelled - no holes drilled." -ForegroundColor Yellow
            } else {
                Write-Host ""
                $total = $pointIds.Count; $idx = 0; $holesMade = 0; $holesNoop = 0; $holesFail = 0; $holeAbort = $false
                $script:lastPct = -1
                foreach ($ptId in $pointIds) {
                    $idx++
                    Show-Progress ([Math]::Floor(($idx / $total) * 100)) "Hole $idx/$total"
                    $hm = Build-NormalHoleMacro -PointId $ptId -SurfaceId $orientSurf -Diameter $holeDia -BodyIndex $bodyIndex -DefaultOrient:$DefaultOrient
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
                } elseif ($holesMade -eq $total -and $holesFail -eq 0) {
                    $script:holesConfirmed = $true
                    Write-Host "  Done - $holesMade On-Point hole(s) created (model changed for each)." -ForegroundColor Green
                    if (-not $DefaultOrient) {
                        Write-Host "  VERIFY the holes are NORMAL to the surface visually - orientation is" -ForegroundColor DarkGray
                        Write-Host "  the live-unverified piece (see Build-NormalHoleMacro)." -ForegroundColor DarkGray
                    }
                } else {
                    Write-Host "  Finished with issues - $holesMade of $total changed the model. Inspect Creo." -ForegroundColor Yellow
                }
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
