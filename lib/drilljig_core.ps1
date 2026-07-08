# ============================================================================
# lib\drilljig_core.ps1 - the shared DRILL-JIG engine (Creo-facing + pure)
# ============================================================================
# The proven helper bodies behind drilljig.cmd, lifted into one dot-sourceable
# module so BOTH the console drilljig.cmd and the new GUI front-end
# (drilljig-gui.cmd) call the SAME live-verified code. Nothing here changes the
# Creo behavior of the originals - the macro strings, the offset-plane creation,
# the hole dashboard tail, the canaries are byte-for-byte the recipes proven live
# (see CLAUDE.md drilljig.cmd / holeinator / plane-probe sections).
#
# TWO kinds of helper:
#   * PURE (no COM): tree/catalog parsing, the by-ID select-macro fragments, the
#     hole/relief macro builders, Resolve-PlaneRole. These take only strings/ints
#     and return strings, so lib\tests\run_wizard_tests.ps1 exercises them offline.
#   * COM ORCHESTRATION: New-OffsetPlane, Set-PlaneOffset, the buffer readers, the
#     canary waiter, etc. To keep the bodies near-verbatim (they referenced the
#     enclosing $session/$model/$pfcType), they read a one-time-initialised script
#     scope instead of threading three params through every call. Call
#     Initialize-DrilljigCore ONCE after connecting:
#         Initialize-DrilljigCore -Session $s -Model $m -TypeObj $t -DataDir $d -Log {param($m,$c) ...}
#     The -Log callback (optional) routes status text; it defaults to Write-Host
#     so the console tool is unaffected. The GUI passes a callback that appends to
#     the wizard's run log.
#
# This module depends on lib\creo_geometry.ps1 (Get-LinearDimMap / Read-DimValue /
# Measure-Extents / New-ExcludeTypes) being dot-sourced first, exactly as
# drilljig.cmd requires.
# ============================================================================

# ---- one-time COM context + logger (set by Initialize-DrilljigCore) ---------
$script:DJSession = $null
$script:DJModel   = $null
$script:DJType    = $null
$script:DJDataDir = $null
$script:DJLog     = $null
$script:macroFailures = 0    # mirrors drilljig.cmd's run-wide mapkey failure tally

function Initialize-DrilljigCore {
    param($Session, $Model, $TypeObj, [string]$DataDir, [scriptblock]$Log = $null)
    $script:DJSession = $Session
    $script:DJModel   = $Model
    $script:DJType    = $TypeObj
    $script:DJDataDir = $DataDir
    $script:DJLog     = $Log
    $script:macroFailures = 0
}

# Internal: emit a status line. Routes to the -Log callback when set (GUI), else
# Write-Host (console). $Color is a best-effort hint the console honors.
function Write-DJ {
    param([string]$Text, [string]$Color = 'Gray')
    if ($null -ne $script:DJLog) {
        try { & $script:DJLog $Text $Color; return } catch {}
    }
    try { Write-Host $Text -ForegroundColor $Color } catch { Write-Host $Text }
}

# ============================================================================
# STAGE 1 - decision tree + catalog (PURE; lifted from drilljig.cmd verbatim)
# ============================================================================

# Turn a machinist fraction or plain number ("3/4", "0.5") into a decimal.
function ConvertTo-Decimal {
    param([string]$Text)
    if ($Text -match '^\s*(\d+)\s*/\s*(\d+)\s*$') {
        return [double]$matches[1] / [double]$matches[2]
    }
    $d = 0.0
    if ([double]::TryParse($Text, [ref]$d)) { return $d }
    return $null
}

# Pull the machinist-fraction label ("3/4", "1 3/8") for OD or Lg out of an
# EasyName "<tag> | OD <od> x ID <id> x <len> Lg"; falls back to $Fallback.
function Get-FracLabel {
    param([string]$EasyName, [string]$Which, [string]$Fallback)
    if ($EasyName) {
        if ($Which -eq 'OD' -and $EasyName -match 'OD\s+(.+?)\s+x') { return $matches[1].Trim() }
        if ($Which -eq 'Lg' -and $EasyName -match 'x\s+([^x]+?)\s+Lg') { return $matches[1].Trim() }
    }
    return $Fallback
}

# Parse a free-text outcome label into a catalog query
#   { File = '<csv path>'; Filters = @( @{ Column='ID'|'OD'; Values=@(<decimals>) } ) }
# or $null if it isn't a catalog-show instruction. Uses $script:DJDataDir.
function Get-CatalogSpec {
    param([string]$Label)
    if (-not $Label) { return $null }
    $low = $Label.ToLower()
    $file = $null
    if ($low -match 'removable|drill') { $file = Join-Path $script:DJDataDir 'bushings_drill.csv' }
    elseif ($low -match 'sleeve')      { $file = Join-Path $script:DJDataDir 'bushings.csv' }
    if (-not $file) { return $null }

    $byCol = @{}
    $rx = [regex]'(\d+(?:/\d+)?(?:\.\d+)?)\s*(ID|OD)'
    foreach ($m in $rx.Matches($Label)) {
        $val = ConvertTo-Decimal $m.Groups[1].Value
        $col = $m.Groups[2].Value.ToUpper()
        if ($null -eq $val) { continue }
        if (-not $byCol.ContainsKey($col)) { $byCol[$col] = @() }
        $byCol[$col] += $val
    }
    $filters = @()
    foreach ($col in $byCol.Keys) { $filters += @{ Column = $col; Values = @($byCol[$col] | Select-Object -Unique) } }
    return @{ File = $file; Filters = $filters }
}

# A FIXED-OD leaf ("the OD of the hole will be 3/4 in") -> the hole diameter, or $null.
function Get-FixedOdSpec {
    param([string]$Label)
    if (-not $Label) { return $null }
    if ($Label -notmatch '(?i)\bOD\b') { return $null }
    if ($Label -match '(?i)\bOD\b[^0-9]*(\d+(?:/\d+)?(?:\.\d+)?)') { return (ConvertTo-Decimal $matches[1]) }
    return $null
}

# Load a catalog file and apply a spec's filters, returning the matching rows
# (@() if none / file missing). PURE apart from Import-Csv (filesystem only, no
# Creo). Replaces the Read-Host-driven Invoke-BushingPick: the GUI renders these
# rows as cards (OD -> length -> ID), this just supplies the filtered data.
function Get-CatalogRows {
    param($Spec)
    if ($null -eq $Spec) { return ,@() }
    if (-not (Test-Path $Spec.File)) { return ,@() }
    $rows = @(Import-Csv $Spec.File)
    foreach ($f in $Spec.Filters) {
        $col = $f.Column; $vals = $f.Values
        $rows = @($rows | Where-Object {
            $cell = [double]$_.$col
            ($vals | Where-Object { [math]::Abs($cell - $_) -lt 1e-6 }).Count -gt 0
        })
    }
    return ,@($rows)
}

# Group catalog rows into the GUI's OD -> length -> ID hierarchy (ascending),
# carrying the machinist-fraction labels. Pure. Returns an array of
#   @{ OD; ODLabel; Lengths = @( @{ Length; LenLabel; Rows = @(<row>...) } ) }
function Group-CatalogByOD {
    param([array]$Rows)
    $out = @()
    if ($null -eq $Rows -or $Rows.Count -eq 0) { return ,@($out) }
    $odGroups = @($Rows | Group-Object OD | Sort-Object { [double]$_.Name })
    foreach ($og in $odGroups) {
        $odLabel = Get-FracLabel $og.Group[0].EasyName 'OD' $og.Name
        $lenOut = @()
        $lenGroups = @($og.Group | Group-Object Length | Sort-Object { [double]$_.Name })
        foreach ($lg in $lenGroups) {
            $lenLabel = Get-FracLabel $lg.Group[0].EasyName 'Lg' $lg.Name
            $lenOut += [pscustomobject]@{
                Length   = [double]$lg.Name
                LenLabel = $lenLabel
                Rows     = @($lg.Group | Sort-Object { [double]$_.ID })
            }
        }
        $out += [pscustomobject]@{
            OD      = [double]$og.Name
            ODLabel = $odLabel
            Lengths = $lenOut
        }
    }
    return ,@($out)
}

# Synthesize an "ID unspecified" bushing pick from an OD+length group's rows
# (OD still drives the hole; the user may leave the exact ID open). Pure.
function New-IdUnspecifiedPick {
    param([string]$ODLabel, [string]$LenLabel, [array]$Rows)
    $tag = ($Rows[0].EasyName -split '\|')[0].Trim()
    return [pscustomobject]@{
        EasyName   = "$tag | OD $ODLabel x ID (any) x $LenLabel Lg"
        OD         = $Rows[0].OD
        ID         = '(any)'
        Length     = $Rows[0].Length
        PartNumber = '(ID unspecified)'
    }
}

# ============================================================================
# STAGE 2/3 - by-ID select macros + hole macros (PURE strings; verbatim)
# ============================================================================

# Tree-search select-by-ID fragment for a FEATURE (nodelator/flipenator pattern).
# -NoClear omits the leading buffer_clean (feed an already-open dashboard collector).
function Get-SelectByIdMacro {
    param([int]$FeatId, [switch]$NoClear)
    $clear = if ($NoClear) { "" } else { "~ Activate ``main_dlg_cur`` ``buffer_clean``;" }
    return $clear +
        "~ Command ``ProCmdMdlTreeSearch``;" +
        "~ Open ``selspecdlg0`` ``SelOptionRadio``;" +
        "~ Close ``selspecdlg0`` ``SelOptionRadio``;" +
        "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Feature``;" +
        "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
        "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$FeatId``;" +
        "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
        "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
        "~ Activate ``selspecdlg0`` ``CancelButton``;"
}

# Select a DATUM PLANE by ID into an already-open dashboard reference collector
# (surfenator's proven up-to-plane feed: type DATUM, LookBy Feature). No buffer_clean.
function Get-SelectDatumByIdMacro {
    param([int]$FeatId)
    return "~ Command ``ProCmdMdlTreeSearch``;" +
        "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Datum``;" +
        "~ Select ``selspecdlg0`` ``LookByOptionMenu`` 1 ``Feature``;" +
        "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
        "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$FeatId``;" +
        "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
        "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
        "~ Activate ``selspecdlg0`` ``CancelButton``;"
}

# Internal: the point-by-ID (+ optional surface-by-ID) selection prefix shared by
# Build-HoleMacro and Build-ReliefHoleMacro. SurfacePlaneId>0 pre-selects the SIDE
# offset plane (Datum) as the On-Point placement surface, then the point (Point,
# accumulated, no buffer_clean); =0 is the original point-only path.
function Get-HolePointSelectMacro {
    param([int]$PointId, [int]$SurfacePlaneId = 0)
    $pointSearch =
        "~ Command ``ProCmdMdlTreeSearch``;" +
        "~ Open ``selspecdlg0`` ``SelOptionRadio``;" +
        "~ Close ``selspecdlg0`` ``SelOptionRadio``;" +
        "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Point``;" +
        "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
        "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$PointId``;" +
        "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
        "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
        "~ Activate ``selspecdlg0`` ``CancelButton``;"
    if ($SurfacePlaneId -gt 0) {
        return "~ Activate ``main_dlg_cur`` ``buffer_clean``;" +
            (Get-SelectDatumByIdMacro -FeatId $SurfacePlaneId) +
            $pointSearch
    }
    return "~ Activate ``main_dlg_cur`` ``buffer_clean``;" + $pointSearch
}

# Recorded hole macro (transcribed live 2026-06-11). ID-driven, ONE atomic RunMacro.
function Build-HoleMacro {
    param([int]$PointId, [double]$Diameter, [int]$BodyIndex = 0, [int]$SurfacePlaneId = 0, [int]$FlipCount = 1)
    $sel = Get-HolePointSelectMacro -PointId $PointId -SurfacePlaneId $SurfacePlaneId
    $flip = ""
    if ($SurfacePlaneId -gt 0 -and $FlipCount -gt 0) {
        for ($f = 0; $f -lt $FlipCount; $f++) { $flip += "~ Activate ``main_dlg_cur`` ``maindashInst0.Flip``;" }
    }
    return $sel +
        "~ Command ``ProCmdHole``;" +
        $flip +
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
}

# A BLIND chip-relief hole (depth set AFTER creation via Set-ReliefHoleDepth).
function Build-ReliefHoleMacro {
    param([int]$PointId, [double]$Diameter, [int]$BodyIndex = 0, [int]$SurfacePlaneId = 0)
    $blindDepthType = "StrHoleDepBlindF"   # CONFIRMED live (trail.txt.3 2026-06-22)
    $sel = Get-HolePointSelectMacro -PointId $PointId -SurfacePlaneId $SurfacePlaneId
    $flip = ""
    if ($SurfacePlaneId -gt 0) { $flip = "~ Activate ``main_dlg_cur`` ``maindashInst0.Flip``;" }
    return $sel +
        "~ Command ``ProCmdHole``;" +
        $flip +
        "~ Select ``main_dlg_cur`` ``maindashInst0.hole_depth_to_type_flybtn``;" +
        "~ Close  ``main_dlg_cur`` ``maindashInst0.hole_depth_to_type_flybtn``;" +
        "~ Activate ``main_dlg_cur`` ``maindashInst0.$blindDepthType`` 1;" +
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
}

# Map a datum-plane NAME to its box role by substring (SIDE first so it can't be shadowed).
function Resolve-PlaneRole {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $u = $Name.ToUpper()
    if ($u -match 'SIDE')  { return 'Side' }
    if ($u -match 'TOP')   { return 'Top' }
    if ($u -match 'FRONT') { return 'Front' }
    return $null
}

# ============================================================================
# COM ORCHESTRATION - read $script:DJSession/DJModel/DJType (Initialize first)
# ============================================================================

# Fire a mapkey, count + surface failures (boxinator's pattern, GUI-log aware).
function Invoke-Macro {
    param([string]$Label, [string]$Macro)
    Write-DJ "  > $Label ..." 'DarkGray'
    try {
        $script:DJSession.RunMacro($Macro)
    } catch {
        Write-DJ "    FAILED: $($_.Exception.Message)" 'Red'
        $script:macroFailures++
    }
}

# Forced regen with fallbacks (boxinator). Forced API regen -> UI ProCmdRegenerate
# -> automatic. Safe on No-Resolve builds (the forced path throws, we fall through).
function Invoke-ForceRegen {
    param($Model = $null)
    if ($null -eq $Model) { $Model = $script:DJModel }
    try {
        $regenCls = New-Object -ComObject pfcls.pfcRegenInstructions
        $instr    = $regenCls.Create($false, $true, $null)
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

# $true if VersionStamp changed within the timeout (the canary signal).
# A short Start-Sleep between polls so this does NOT spin a CPU core flat-out for
# the whole operation (the original tight loop pegged a core, which under the GUI
# also starved the UI thread -> sluggishness). 40ms is far finer than any Creo
# regen, so it does not slow detection; it just stops the busy-wait. When a GUI
# is driving, the -OnPoll callback pumps the message loop so the window repaints.
function Wait-ModelModified {
    param($Model = $null, [string]$PreviousStamp, [int]$TimeoutMs = 30000, [scriptblock]$OnPoll = $null)
    if ($null -eq $Model) { $Model = $script:DJModel }
    $deadline = [DateTime]::Now.AddMilliseconds($TimeoutMs)
    while ([DateTime]::Now -lt $deadline) {
        try { if ($Model.VersionStamp -ne $PreviousStamp) { return $true } } catch {}
        if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }
        Start-Sleep -Milliseconds 40
    }
    return $false
}

# Snapshot every ITEM_FEATURE id (for before/after diffs).
function Get-FeatureIdSet {
    $set = @{}
    try { foreach ($f in $script:DJModel.ListItems($script:DJType.ITEM_FEATURE)) { try { $set[[int]$f.Id] = $true } catch {} } } catch {}
    return $set
}

# Read the (last) selected feature ID from the selection buffer, or $null.
function Read-SelectedId {
    $contents = ($script:DJSession.CurrentSelectionBuffer()).Contents
    if ($null -eq $contents -or $contents.Count -eq 0) { return $null }
    try { return [int]$contents[$contents.Count - 1].SelItem.Id } catch { return $null }
}

# Read the buffer as datum-plane picks: one { Id; Name; Role } per UNIQUE item.
# ID-and-name only (never coords). De-dups by id. @() if empty.
function Read-SelectionPlanePicks {
    $picks = @()
    $contents = $null
    try { $contents = ($script:DJSession.CurrentSelectionBuffer()).Contents } catch {}
    if ($null -eq $contents -or $contents.Count -eq 0) { return @($picks) }
    $seen = @{}
    foreach ($item in $contents) {
        $si = $null
        try { $si = $item.SelItem } catch { continue }
        if ($null -eq $si) { continue }
        $id = $null
        try { $id = [int]$si.Id } catch { continue }
        if ($seen.ContainsKey($id)) { continue }
        $seen[$id] = $true
        $name = $null
        try { $name = [string]$si.GetName() } catch {}
        $picks += [pscustomobject]@{ Id = $id; Name = $name; Role = (Resolve-PlaneRole -Name $name) }
    }
    return @($picks)
}

# Auto-discover the three default datums by NAME (no selection). First feature per
# role wins. @() if enumeration fails. Same shape as Read-SelectionPlanePicks.
function Find-DefaultDatumPicks {
    $picks = @()
    $contents = $null
    try { $contents = @($script:DJModel.ListItems($script:DJType.ITEM_FEATURE)) } catch {}
    if ($null -eq $contents -or $contents.Count -eq 0) { return @($picks) }
    $rolesSeen = @{}
    foreach ($f in $contents) {
        $name = $null
        try { $name = [string]$f.GetName() } catch {}
        $role = Resolve-PlaneRole -Name $name
        if ($null -eq $role) { continue }
        if ($rolesSeen.ContainsKey($role)) { continue }
        $id = $null
        try { $id = [int]$f.Id } catch { continue }
        $rolesSeen[$role] = $true
        $picks += [pscustomobject]@{ Id = $id; Name = $name; Role = $role }
    }
    return @($picks)
}

# Resolve the CURRENT selection buffer into datum POINT ids (never reads .Point).
# Returns @{ Ids = @(int...); Rejected = @(string...) } - the STAGE-3 hand-select logic.
function Resolve-SelectedPointIds {
    $points = ($script:DJSession.CurrentSelectionBuffer()).Contents
    $ids = @(); $seen = @{}; $rejected = @()
    if ($null -eq $points) { return @{ Ids = @($ids); Rejected = @($rejected) } }
    foreach ($item in $points) {
        $si = $null
        try { $si = $item.SelItem } catch { continue }
        if ($null -eq $si) { continue }
        $isPointType = $false
        try { $isPointType = ([int]$si.Type -eq [int]$script:DJType.ITEM_POINT) } catch {}
        $subIds = @()
        try { foreach ($pt in @($si.ListSubItems($script:DJType.ITEM_POINT))) { try { $subIds += [int]$pt.Id } catch {} } } catch {}
        if ($subIds.Count -gt 0) {
            foreach ($sid in $subIds) { if (-not $seen.ContainsKey($sid)) { $seen[$sid] = $true; $ids += $sid } }
        } elseif ($isPointType) {
            $id = [int]$si.Id
            if (-not $seen.ContainsKey($id)) { $seen[$id] = $true; $ids += $id }
        } else {
            $tname = "?"; $rid = "?"
            try { $rid = [int]$si.Id } catch {}
            try { $tname = [string]$si.Type } catch {}
            $rejected += "id $rid (type $tname)"
        }
    }
    return @{ Ids = @($ids); Rejected = @($rejected) }
}

# Create ONE offset plane from a base ref selected BY ID. Returns
# [pscustomobject]@{ Symbol; FeatId } (either may be $null). Verbatim recipe +
# poll (heavier models commit the plane more slowly). GUI-log aware.
function New-OffsetPlane {
    param([string]$Label, [double]$Offset, [int]$BaseId)
    $before     = Get-LinearDimMap -Model $script:DJModel -TypeObj $script:DJType
    $beforeFeat = Get-FeatureIdSet
    $macro =
        (Get-SelectByIdMacro -FeatId $BaseId) +
        "~ Command ``ProCmdDatumPlane``;" +
        "~ Input  ``Odui_Dlg_00`` ``t1.constr_dim1`` ``$Offset``;" +
        "~ Update ``Odui_Dlg_00`` ``t1.constr_dim1`` ``$Offset``;" +
        "~ FocusOut ``Odui_Dlg_00`` ``t1.constr_dim1``;" +
        "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;"
    Invoke-Macro "$Label plane: open + offset $Offset + OK" $macro

    $MaxWaitSec = 20
    $newSyms = @(); $after = $before
    for ($i = 0; $i -lt ($MaxWaitSec * 10); $i++) {
        $after   = Get-LinearDimMap -Model $script:DJModel -TypeObj $script:DJType
        $newSyms = @($after.Keys | Where-Object { -not $before.ContainsKey($_) })
        if ($newSyms.Count -ge 1) { break }
        if ($i -eq 20) { Write-DJ "    (waiting for Creo to commit the $Label plane...)" 'DarkGray' }
        Start-Sleep -Milliseconds 100
    }
    $afterFeat = Get-FeatureIdSet
    $newFeats  = @($afterFeat.Keys | Where-Object { -not $beforeFeat.ContainsKey($_) })
    $newFeatId = if ($newFeats.Count -ge 1) { [int]$newFeats[0] } else { $null }

    if ($newSyms.Count -eq 0) {
        Write-DJ "    No new linear dim appeared for the $Label plane after ${MaxWaitSec}s (feat id $newFeatId)." 'Yellow'
        return [pscustomobject]@{ Symbol = $null; FeatId = $newFeatId }
    }
    if ($newSyms.Count -gt 1) { Write-DJ "    More than one new dim appeared ($($newSyms -join ', ')); taking the first." 'Yellow' }
    $sym = [string]$newSyms[0]
    Write-DJ "    $Label offset dim: $sym = $($after[$sym])" 'Green'
    return [pscustomobject]@{ Symbol = $sym; FeatId = $newFeatId }
}

# Write one plane's offset, force a regen, return the value that stuck (or $null).
function Set-PlaneOffset {
    param($Plane, [double]$Value)
    try {
        $d = $script:DJModel.GetItemByName($script:DJType.ITEM_DIMENSION, $Plane.Sym)
        $d.DimValue = $Value
    } catch {
        Write-DJ "    $($Plane.Label): could not write DimValue: $($_.Exception.Message)" 'Yellow'
        return $null
    }
    Invoke-ForceRegen -Model $script:DJModel
    return (Read-DimValue -Model $script:DJModel -TypeObj $script:DJType -Sym $Plane.Sym)
}

# Drive a freshly-created BLIND hole to depth (boxinator way). Returns
# @{ Status='held'|'wrote-unconfirmed'|'no-depth-dim'|'error'; Sym; Value }.
function Set-ReliefHoleDepth {
    param($BeforeMap, [double]$Depth)
    $after = Get-LinearDimMap -Model $script:DJModel -TypeObj $script:DJType
    $newSyms = @($after.Keys | Where-Object { -not $BeforeMap.ContainsKey($_) })
    if ($newSyms.Count -eq 0) { return @{ Status = 'no-depth-dim'; Sym = $null; Value = $null } }
    if ($newSyms.Count -gt 1) { Write-DJ "      (>1 new linear dim after hole: $($newSyms -join ', '); taking the largest as depth)" 'Yellow' }
    $depthSym = $newSyms | Sort-Object { [double]$after[$_] } -Descending | Select-Object -First 1
    try {
        $d = $script:DJModel.GetItemByName($script:DJType.ITEM_DIMENSION, [string]$depthSym)
        $d.DimValue = $Depth
    } catch {
        return @{ Status = 'error'; Sym = [string]$depthSym; Value = $null }
    }
    Invoke-ForceRegen -Model $script:DJModel
    $got = Read-DimValue -Model $script:DJModel -TypeObj $script:DJType -Sym ([string]$depthSym)
    if ($null -ne $got -and [math]::Abs([double]$got - $Depth) -lt 1e-4) {
        return @{ Status = 'held'; Sym = [string]$depthSym; Value = $got }
    }
    return @{ Status = 'wrote-unconfirmed'; Sym = [string]$depthSym; Value = $got }
}

# Enumerate solid bodies as @( @{ Index; Name } ) for the body picker. @() on failure.
function Get-BodyList {
    $out = @()
    $bodies = @()
    try { $bodies = @($script:DJModel.ListItems($script:DJType.ITEM_BODY)) } catch {}
    for ($i = 0; $i -lt $bodies.Count; $i++) {
        $bn = "(unnamed)"
        try { $bn = [string]$bodies[$i].GetName() } catch {}
        $out += [pscustomobject]@{ Index = $i; Name = $bn }
    }
    return ,@($out)
}

# ============================================================================
# CHIP-RELIEF SLOTS (slotinator engine, shared by slotinator.cmd + drilljig.cmd
# + drilljig-gui.cmd). Moved here 2026-07-07 so all three fire the SAME
# confirmed-live macros instead of copy-pasted bodies. A slot is a blind
# rectangular REMOVE-MATERIAL extrude per hole row (length = part length,
# width = hole dia, depth = % of thickness); rows are seed-drawn once then
# patterned along a base datum plane's normal.
# ============================================================================

# Build-CutFinishMacro - MACRO B: finish the internal sketch (which holds the
# rectangle the operator drew), optionally flip the cut direction, type the blind
# depth, toggle REMOVE MATERIAL, pick the body, confirm. ONE atomic RunMacro (a
# dashboard's command context does not survive across RunMacro calls). PURE builder
# (no COM). Widget provenance (all confirmed live, slotinator.cmd / trail.txt.32,
# .27:3973, .8:1758/1799):
#   ProCmdSketDone -> [maindashInst0.flip_pb] -> [def_depth1_ip blind depth] ->
#   Enter/Exit dashInst0.Quit (blur) -> remove_material_cb 1 -> body_page.1.0 body
#   -> dashInst0.Done.
function Build-CutFinishMacro {
    param([double]$Depth = 0.0, [int]$BodyIndex = 0, [bool]$Flip = $true)
    $flipMacro = if ($Flip) { "~ Activate ``main_dlg_cur`` ``maindashInst0.flip_pb``;" } else { "" }
    $depthMacro = if ($Depth -gt 0) {
        "~ Input  ``main_dlg_cur`` ``maindashInst0.def_depth1_ip`` ``$Depth``;" +
        "~ Update ``main_dlg_cur`` ``maindashInst0.def_depth1_ip`` ``$Depth``;" +
        "~ Activate ``main_dlg_cur`` ``maindashInst0.def_depth1_ip``;" +
        "~ FocusOut ``main_dlg_cur`` ``maindashInst0.def_depth1_ip``;"
    } else { "" }
    return "~ Command ``ProCmdSketDone``;" +
        $flipMacro +
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

# Build-SlotPatternMacro - the hands-free single-direction pattern, fired as ONE
# atomic macro AFTER the operator has SELECTED the seed slot in the model tree
# (a search-buffer select does NOT register as the pattern target - the operator
# must click it; see slotinator FIX 1). Direction is a base DATUM PLANE fed BY ID
# (FIX 2): open pattern -> activate ui_pat_dir_dir1 -> feed the datum by ID ->
# count + spacing (+ optional flip) -> confirm. CONFIRMED LIVE 2026-07-07.
# Uses Build-PatternArm/Values/ConfirmMacro (orthogrid_points.ps1) +
# Get-SelectDatumByIdMacro (above).
function Build-SlotPatternMacro {
    param([int]$DirDatumId, [int]$Count, [double]$Spacing, [switch]$Flip)
    return (Build-PatternArmMacro) +
           (Get-SelectDatumByIdMacro -FeatId $DirDatumId) +
           (Build-PatternValuesMacro -Count1 $Count -Spacing1 $Spacing -Flip1:$Flip) +
           (Build-PatternConfirmMacro)
}

# New-SlotGuidePlanes - create + SHOW the slot-edge offset planes that guide the
# manual rectangle draw (the 2-plus datum planes slotinator makes; essential for
# drawing the slot to the right size). One plane per distinct X edge (offset from
# the TOP base) + per distinct Z edge (from FRONT); a ~0 offset reuses the base
# datum (point-probe trick). -UsePattern => only the FIRST row's edges (the seed;
# the pattern replicates it), else every row's edges. Shows each via
# ProCmdViewShow@PopupMenuTree (proven: plane-probe / trail.txt.32). Reads the core
# scope ($script:DJSession/$script:DJModel); needs Get-SharedPlanePlan (orthogrid_
# points) + New-OffsetPlane + Get-SelectByIdMacro in scope. Returns
# @{ Ids=@(); XCount; ZCount }. Never throws on a plane failure (logs to $Log).
function New-SlotGuidePlanes {
    param(
        [array]$Rows,
        [int]$TopBaseId,
        [int]$FrontBaseId,
        [switch]$UsePattern,
        [scriptblock]$Log = $null
    )
    $ids = @()
    if ($null -eq $Rows -or @($Rows).Count -lt 1 -or $TopBaseId -le 0 -or $FrontBaseId -le 0) {
        return @{ Ids = @(); XCount = 0; ZCount = 0 }
    }
    $corners = if ($UsePattern) { @($Rows[0].Corner0, $Rows[0].Corner1) } else { @($Rows | ForEach-Object { $_.Corner0; $_.Corner1 }) }
    $plan = Get-SharedPlanePlan -Points $corners
    $tolP = 1e-6
    foreach ($xOff in $plan.XCoords) {
        if ([math]::Abs([double]$xOff) -le $tolP) { continue }   # X~0 -> the TOP base datum (already visible)
        $res = New-OffsetPlane -Label "SlotX$($ids.Count)" -Offset ([double]$xOff) -BaseId ([int]$TopBaseId)
        if ($null -ne $res.FeatId) { $ids += [int]$res.FeatId }
        elseif ($null -ne $Log) { & $Log ("  slot X-edge plane at offset $xOff FAILED (continuing).") }
    }
    foreach ($zOff in $plan.ZCoords) {
        if ([math]::Abs([double]$zOff) -le $tolP) { continue }   # Z~0 -> the FRONT base datum
        $res = New-OffsetPlane -Label "SlotZ$($ids.Count)" -Offset ([double]$zOff) -BaseId ([int]$FrontBaseId)
        if ($null -ne $res.FeatId) { $ids += [int]$res.FeatId }
        elseif ($null -ne $Log) { & $Log ("  slot Z-edge plane at offset $zOff FAILED (continuing).") }
    }
    # SHOW each created plane (select by id -> ProCmdViewShow@PopupMenuTree)
    foreach ($planeId in $ids) {
        $showMacro = (Get-SelectByIdMacro -FeatId ([int]$planeId)) + "~ Command ``ProCmdViewShow@PopupMenuTree``;"
        try { $script:DJSession.RunMacro($showMacro) } catch { if ($null -ne $Log) { & $Log ("  could not show plane id $planeId : $($_.Exception.Message)") } }
    }
    try { $script:DJModel.Regenerate($null) } catch {}
    return @{ Ids = @($ids); XCount = $plan.XCoords.Count; ZCount = $plan.ZCoords.Count }
}

# Invoke-VerifiedSeedCut - fire the FIRST slot cut and VERIFY it with the operator
# (console: uses Read-Host for the draw/verify pause). The correct cut DIRECTION
# depends on the sketch plane and cannot be known offline, so: open the sketch, the
# operator draws the rectangle, fire the cut, then ASK whether it cut INTO the plate
# at the right depth. If NOT, undo + TOGGLE the flip + redraw once (only two
# directions). Returns @{ Ok; Flip; FeatId } - the confirmed Flip is reused for the
# pattern / remaining rows, so direction is verified ONCE. Reads the core session
# scope ($script:DJSession/$script:DJModel), so slotinator.cmd AND drilljig.cmd share
# this one copy (both call Initialize-DrilljigCore). The GUI does NOT call this - it
# uses wizard arm/verify steps around the same Build-CutFinishMacro.
function Invoke-VerifiedSeedCut {
    param(
        [int]$FaceId,
        [double]$Depth,
        [int]$BodyIndex,
        [bool]$Flip,
        [string]$RowLabel = "row 1",
        [hashtable]$DrawInfo   # SlotLen, RowAxis, SlotWidth, CrossAxis, CrossCoord, HasPlanes
    )
    $curFlip = $Flip
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $dirWord = if ($curFlip) { "flipped" } else { "default" }
        $mkOpen =
            (Get-SelectByIdMacro -FeatId $FaceId) +
            "~ Command ``ProCmdFtExtrude``;" +
            "~ Command ``ProCmdViewSketchView``;" +
            "~ Command ``ProCmdSketRectangle`` 1;"
        Write-Host ""
        Write-Host ("  SEED SLOT ($RowLabel) - attempt $attempt, direction: $dirWord - opening the sketch...") -ForegroundColor Cyan
        try { $script:DJSession.RunMacro($mkOpen) }
        catch {
            Write-Host "    Could not open the sketch: $($_.Exception.Message)" -ForegroundColor Red
            return @{ Ok = $false; Flip = $curFlip; FeatId = $null }
        }

        Write-Host ""
        Write-Host "  MANUAL STEP - draw the rectangle over $RowLabel's holes:" -ForegroundColor Magenta
        Write-Host ("    target: {0:0.###} long (along {1}) x {2:0.###} wide (along {3}), centered on {3}~{4:0.###}" -f `
            $DrawInfo.SlotLen, $DrawInfo.RowAxis, $DrawInfo.SlotWidth, $DrawInfo.CrossAxis, $DrawInfo.CrossCoord) -ForegroundColor White
        if ($DrawInfo.HasPlanes) { Write-Host "    Snap the rectangle edges to the visible slot-edge planes." -ForegroundColor White }
        Write-Host "    Click one corner then the opposite corner (ONE closed rectangle). Esc drops the tool." -ForegroundColor White
        Write-Host "    Leave the rectangle drawn + sketch OPEN, then press ENTER here." -ForegroundColor Yellow
        Read-Host

        $beforeFeat = Get-FeatureIdSet
        $stamp = $null; try { $stamp = $script:DJModel.VersionStamp } catch {}
        $changed = $false
        try {
            $script:DJSession.RunMacro((Build-CutFinishMacro -Depth $Depth -BodyIndex $BodyIndex -Flip $curFlip))
            if ($null -ne $stamp) { $changed = Wait-ModelModified -PreviousStamp $stamp -TimeoutMs 30000 }
        } catch { Write-Host "    Macro error on the cut: $($_.Exception.Message)" -ForegroundColor Red }

        if (-not $changed) {
            Write-Host "  The cut did NOT modify the model (rectangle not a closed loop, or widget drift)." -ForegroundColor Red
            return @{ Ok = $false; Flip = $curFlip; FeatId = $null }
        }
        $afterFeat = Get-FeatureIdSet
        $newFeats  = @($afterFeat.Keys | Where-Object { -not $beforeFeat.ContainsKey($_) } | Sort-Object)
        $featId    = if ($newFeats.Count -ge 1) { [int]$newFeats[-1] } else { $null }

        Write-Host ""
        Write-Host "  VERIFY IN CREO: did this slot cut INTO the plate, at the right depth?" -ForegroundColor Magenta
        $ok = Read-Host "    y = correct (keep it, reuse this direction for all rows) / n = wrong (undo + flip + redraw)"
        if ($ok -match '^[Yy]') {
            Write-Host ("  Direction CONFIRMED ($dirWord). Reusing it for the remaining rows.") -ForegroundColor Green
            return @{ Ok = $true; Flip = $curFlip; FeatId = $featId }
        }

        if ($attempt -lt 2) {
            Write-Host "  Flipping the direction. First remove this wrong cut:" -ForegroundColor Yellow
            try { $script:DJSession.RunMacro("~ Command ``ProCmdEditUndo``;") } catch {}
            Write-Host "    (I fired Undo. If the wrong slot is STILL in the model, press Ctrl+Z in Creo now.)" -ForegroundColor Yellow
            Write-Host "    Press ENTER when the wrong slot is gone - you'll redraw with the flipped direction." -ForegroundColor Yellow
            Read-Host
            $curFlip = -not $curFlip
        } else {
            Write-Host "  Both directions tried and neither was confirmed. Leaving the last cut - inspect Creo." -ForegroundColor Yellow
            return @{ Ok = $false; Flip = $curFlip; FeatId = $featId }
        }
    }
}
