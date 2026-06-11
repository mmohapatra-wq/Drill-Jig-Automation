<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "PLANE-PROBE"
$ErrorActionPreference = "Stop"

# --probe-judge : validate the BlueGPT REST judge round-trip (endpoint + auth)
# with a synthetic packet, then exit. No Creo connection, no model touched.
# Use this once to confirm the gateway is reachable before relying on the blind
# evaluator in a live run.
$ProbeJudge = ($ScriptArgs -match '(?i)(^|\s)-{1,2}probe-judge(\s|$)')

# ============================================================================
# PLANE-PROBE  (boxinator-parametric branch — EXPERIMENT, not production)
# ============================================================================
# Creates THREE offset datum planes — Front, Side, Top — so the three new planes
# plus the part's three default datums (FRONT/RIGHT/TOP) bound a parametric BOX
# envelope. Each plane's offset is a FEATURE-LEVEL dim, so a plain DimValue write
# + regen HOLDS (no relations, no sketch-dim snap-back) — meaning all three box
# dimensions are parametrically drivable from PowerShell.
#
# Why this works (proven over earlier probes): driving a SKETCH dim via DimValue
# snaps back on regen, and the relations route (dim = PARAM) was fiddly. A datum
# plane's OFFSET distance, by contrast, is a feature-level dim — the same
# reliable path boxinator uses for extrude depth — so a DimValue write sticks.
#
# Flow — collect everything up front, then fire all three with NO further clicks:
#   0. Ask for all three offset distances (TOP/SIDE/FRONT).
#   1. User picks the three BASE reference planes once each (quick clicks); the
#      script records each base plane's FEATURE ID from the selection buffer.
#      Nothing is created during this step.
#   2. For each plane (loop runs with zero human interaction):
#      a. Snapshot the linear dim-symbol set.
#      b. ONE atomic RunMacro: tree-search-select the base plane BY ID (so the
#         buffer holds the right ref) -> ProCmdDatumPlane (opens with the
#         buffered ref pre-loaded as an Offset constraint) -> type offset into
#         t1.constr_dim1 -> Update -> FocusOut (blur so it lands) -> OK stdbtn_1.
#         Must be a single RunMacro — a dialog's command context does NOT survive
#         across separate RunMacro calls (same rule as the extrude dashboard).
#      c. Diff the dim-symbol set; the ONE new symbol is that plane's offset dim.
#
# Selecting the base plane by ID (the nodelator/flipenator tree-search pattern)
# is what lets all three fire back-to-back: the old version made you click a base
# plane and press ENTER between every plane because ProCmdDatumPlane consumes the
# buffer. Capturing the IDs up front removes that interleaving.
#
# After all three are created, a parametric loop lets you resize the whole box
# (all three at once) or any single plane — write its offset DimValue +
# Invoke-ForceRegen, re-read to confirm it held. Resizing the planes IS resizing
# the box.
#
# Widget names confirmed from a live `visible_mapkeys yes` recording:
#   ~ Command `ProCmdDatumPlane`;
#   ~ FocusOut `Odui_Dlg_00` `t1.constr_dim1`;   <- offset value field
#   ~ Activate `Odui_Dlg_00` `stdbtn_1`;         <- OK
#
# PREREQ: a part open in Creo with the three default datum planes (FRONT/RIGHT/
# TOP) to offset FROM. Run with ONE Creo session (no picker here — this is a
# probe).
# ============================================================================

trap {
    Write-Host ""
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $inv = $_.InvocationInfo
    if ($null -ne $inv) {
        Write-Host ("  at line {0}: {1}" -f $inv.ScriptLineNumber, $inv.Line.Trim()) -ForegroundColor DarkYellow
    }
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

# ---------------------------------------------------------------------------
# Fire a mapkey and report success/failure instead of swallowing it (boxinator's
# pattern). A silent no-op from a wrong widget name is the hardest mapkey bug to
# find, so count failures and surface them.
# ---------------------------------------------------------------------------
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

# Forced regen with fallbacks (lifted verbatim-in-spirit from boxinator). On this
# No-Resolve build the API forced regen throws IpfcXToolkitBadContext, so the
# reliable path is the UI ProCmdRegenerate; automatic regen is the last resort.
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

# NOTE: Get-LinearDimMap and Read-DimValue now live in lib\creo_geometry.ps1
# (dot-sourced above) — they were identical to the inline copies here and are
# shared with the blind evaluator so every tool reads dims the same way.

# Snapshot every feature ID on the model. The new datum-plane feature is found by
# diffing this before vs after creation (same approach boxinator uses to find a
# fresh extrude), so we capture the plane's feature ID without guessing.
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

# Read the (last) selected feature ID from Creo's selection buffer, or $null.
# Same buffer read used to capture the base planes up front.
function Read-SelectedId {
    $contents = ($session.CurrentSelectionBuffer()).Contents
    if ($null -eq $contents -or $contents.Count -eq 0) { return $null }
    try { return [int]$contents[$contents.Count - 1].SelItem.Id } catch { return $null }
}

# Build the tree-search select-by-ID macro fragment for a Feature (the proven
# nodelator/flipenator pattern). Clears the buffer, then selects the feature with
# the given ID INTO the buffer. The caller appends whatever command should
# consume that buffered selection (ProCmdDatumPlane, ProCmdDatumSketCurve,
# ProCmdViewShow@PopupMenuTree, the extrude's toselected, ...). Centralising the
# string keeps the call sites from drifting apart.
#
# -NoClear omits the leading buffer_clean. Use it when feeding a dashboard
# reference collector that is already open and waiting for a pick (surfenator
# proves a tree search feeds the open up-to-plane collector this way; clearing
# the buffer mid-dashboard can deactivate that collector).
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

# Create ONE offset plane from a base reference selected BY ID and return a
# [pscustomobject] with its new offset dim Symbol and new feature Id (either may
# be $null if none/ambiguous appeared). The base plane's feature ID was captured
# up front, so this fires with no human interaction: tree-search-select the base
# BY ID (populates the buffer) -> ProCmdDatumPlane (consumes it) -> offset -> OK,
# all in one atomic macro. New symbol/feature resolved by before/after diff.
function New-OffsetPlane {
    param($Model, $TypeObj, [string]$Label, [double]$Offset, [int]$BaseId)

    $before     = Get-LinearDimMap   -Model $Model -TypeObj $TypeObj
    $beforeFeat = Get-FeatureIdSet   -Model $Model -TypeObj $TypeObj

    # ONE atomic macro: clear buffer -> tree-search-select base plane BY ID ->
    # open ProCmdDatumPlane (ref pre-loaded from buffer) -> offset -> blur -> OK.
    $macro =
        (Get-SelectByIdMacro -FeatId $BaseId) +
        "~ Command ``ProCmdDatumPlane``;" +
        "~ Input  ``Odui_Dlg_00`` ``t1.constr_dim1`` ``$Offset``;" +
        "~ Update ``Odui_Dlg_00`` ``t1.constr_dim1`` ``$Offset``;" +
        "~ FocusOut ``Odui_Dlg_00`` ``t1.constr_dim1``;" +
        "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;"

    Invoke-Macro "$Label plane: open + offset $Offset + OK" $macro

    # POLL for the new offset dim to appear, rather than waiting a fixed interval
    # and checking once. A heavier model commits the datum plane more slowly, and
    # the old fixed ~2s wait diffed the dim set BEFORE the offset dim was
    # enumerable (symptom: "No new linear dim" even though the plane was made and
    # the macro returned ok). This breaks the instant a new symbol shows up, so a
    # fast model stays fast; a slow one just waits longer (up to ~MaxWaitSec).
    $MaxWaitSec = 20
    $newSyms    = @()
    $after      = $before
    for ($i = 0; $i -lt ($MaxWaitSec * 10); $i++) {
        $after   = Get-LinearDimMap -Model $Model -TypeObj $TypeObj
        $newSyms = @($after.Keys | Where-Object { -not $before.ContainsKey($_) })
        if ($newSyms.Count -ge 1) { break }
        if ($i -eq 20) { Write-Host "    (waiting for Creo to commit the $Label plane...)" -ForegroundColor DarkGray }
        Start-Sleep -Milliseconds 100
    }

    # The new datum-plane feature ID, by feature-set diff (used later to show it).
    $afterFeat = Get-FeatureIdSet -Model $Model -TypeObj $TypeObj
    $newFeats  = @($afterFeat.Keys | Where-Object { -not $beforeFeat.ContainsKey($_) })
    $newFeatId = if ($newFeats.Count -ge 1) { [int]$newFeats[0] } else { $null }

    if ($newSyms.Count -eq 0) {
        Write-Host "    No new linear dim appeared for the $Label plane after ${MaxWaitSec}s." -ForegroundColor Yellow
        Write-Host "    The plane may still have been created (feature id $newFeatId) — if so this" -ForegroundColor Yellow
        Write-Host "    is a dim-enumeration issue, not a creation failure. Otherwise the base" -ForegroundColor Yellow
        Write-Host "    plane ID ($BaseId) didn't select, or t1.constr_dim1/stdbtn_1 differ." -ForegroundColor Yellow
        return [pscustomobject]@{ Symbol = $null; FeatId = $newFeatId }
    }
    if ($newSyms.Count -gt 1) {
        Write-Host "    More than one new dim appeared ($($newSyms -join ', ')); taking the first." -ForegroundColor Yellow
    }
    $sym = [string]$newSyms[0]
    Write-Host "    $Label offset dim: $sym = $($after[$sym])" -ForegroundColor Green
    return [pscustomobject]@{ Symbol = $sym; FeatId = $newFeatId }
}

# ============================================
# HEADER
# ============================================
Write-Host ""
Write-Host "  PLANE-PROBE — three offset planes (Front/Side/Top) = parametric box" -ForegroundColor Cyan
Write-Host "  (boxinator-parametric branch — does NOT modify boxinator.cmd)" -ForegroundColor DarkGray
Write-Host ""

# ============================================
# SHARED LIBRARY (geometry reads + blind evaluator)
# ============================================
# Dot-source the shared helpers. creo_geometry.ps1 supplies the pure measurement
# functions (Measure-Extents, Get-LinearDimMap, Read-DimValue, ...) that used to
# be copy-pasted into each tool; blind_evaluator.ps1 supplies the convergence
# layer (claim -> sliced truth -> blind LLM judge -> gated report).
. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')
. (Join-Path $ScriptDir 'lib\blind_evaluator.ps1')

# --probe-judge: validate the REST judge in isolation, then exit (no Creo).
if ($ProbeJudge) {
    $ok = Invoke-JudgeProbe -RepoRoot $ScriptDir -Model "sonnet"
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit ([int](-not $ok))
}

# Resolve the judge config once up front so the build/resize sections can use it.
# $null is fine — the evaluator then just writes the packet and skips the REST call.
$judgeCfg = Get-JudgeConfig -RepoRoot $ScriptDir -DefaultModel "sonnet"
if ($null -eq $judgeCfg) {
    Write-Host "  (blind judge not configured — eval packets will be written for offline judging)" -ForegroundColor DarkGray
} else {
    Write-Host "  Blind judge: $($judgeCfg.base) [$($judgeCfg.model)]" -ForegroundColor DarkGray
}
Write-Host ""

# ============================================
# CONNECT (single session)
# ============================================
$procs = @(Get-Process | Where-Object { $_.ProcessName -eq "xtop" })
if ($procs.Count -eq 0) { throw "Creo (xtop.exe) is not running" }
if ($procs.Count -gt 1) {
    throw "More than one Creo session is open. This probe expects exactly ONE (no session picker here)."
}
$proc = $procs[0]
$Env:PRO_DIRECTORY    = $proc.Path.TrimEnd("xtop.exe")
$Env:PRO_COMM_MSG_EXE = $proc.Path -replace "xtop.exe", "pro_comm_msg.exe"

try { New-Object -ComObject pfcls.pfcAsyncConnection | Out-Null }
catch {
    $reg = $proc.Path -replace "Common Files(.*)$", "Parametric\bin\vb_api_register.bat"
    Start-Process -Wait -FilePath $reg
}

$async      = New-Object -ComObject pfcls.pfcAsyncConnection
$connection = $async.Connect($null, $null, $null, $null)
$session    = $connection.Session
$model      = $session.GetActiveModel()
if ($null -eq $model) { throw "No active model. Open a part with the default datum planes first." }

Write-Host "  Connected. Active model: $($model.FileName)" -ForegroundColor Green
Write-Host ""

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

try {

$pfcType = New-Object -ComObject pfcls.pfcModelItemType

# ============================================
# 0. ASK FOR THE THREE BOX OFFSETS
# ============================================
# Each label is just descriptive — the actual base plane is whatever you pick.
# The part's default datums on this build are TOP / SIDE / FRONT. Mapping:
# Top offsets TOP (height), Side offsets SIDE (width), Front offsets FRONT (depth).
$planes = @(
    [pscustomobject]@{ Label = "Top";   Hint = "TOP";   Offset = 0.0; Sym = $null; BaseId = $null; FeatId = $null }
    [pscustomobject]@{ Label = "Side";  Hint = "SIDE";  Offset = 0.0; Sym = $null; BaseId = $null; FeatId = $null }
    [pscustomobject]@{ Label = "Front"; Hint = "FRONT"; Offset = 0.0; Sym = $null; BaseId = $null; FeatId = $null }
)

Write-Host "  Enter the three box offsets (blank/0 -> 1.0 so each has a drivable dim):" -ForegroundColor Cyan
foreach ($p in $planes) {
    $raw = Read-Host "    $($p.Label) plane offset (from $($p.Hint))"
    $v = 0.0
    if (-not [double]::TryParse($raw, [ref]$v) -or $v -eq 0) {
        Write-Host "      using 1.0" -ForegroundColor Yellow
        $v = 1.0
    }
    $p.Offset = $v
}
Write-Host ""

# ============================================
# 1a. CAPTURE THE THREE BASE-PLANE IDs (quick picks, up front — nothing created)
# ============================================
# Click each base plane once; the script reads its feature ID from the selection
# buffer. No macro fires here, so there's no waiting between picks. The IDs let
# section 1b re-select each base by ID and fire all three creations back-to-back.
Write-Host "  First, identify the three base planes (one quick click each):" -ForegroundColor Cyan
foreach ($p in $planes) {
    Read-Host "    Click the $($p.Hint) plane in Creo, then press ENTER"
    $contents = ($session.CurrentSelectionBuffer()).Contents
    if ($null -eq $contents -or $contents.Count -eq 0) {
        throw "Nothing was selected for the $($p.Hint) plane. Click the plane, then press ENTER."
    }
    # Take the last-selected item (in case earlier picks are still buffered).
    $p.BaseId = [int]$contents[$contents.Count - 1].SelItem.Id
    Write-Host "      $($p.Hint) base feature ID = $($p.BaseId)" -ForegroundColor DarkGray
}
Write-Host ""

# ============================================
# 1b. CREATE THE THREE OFFSET PLANES (select base BY ID -> atomic macro, x3, no clicks)
# ============================================
Write-Host "  Creating all three offset planes (no further clicks needed)..." -ForegroundColor Cyan
Write-Host ""

foreach ($p in $planes) {
    Write-Host "  --- $($p.Label) plane (offset $($p.Offset) from $($p.Hint), id $($p.BaseId)) ---" -ForegroundColor Cyan
    $res = New-OffsetPlane -Model $model -TypeObj $pfcType -Label $p.Label -Offset $p.Offset -BaseId $p.BaseId
    $p.Sym    = $res.Symbol
    $p.FeatId = $res.FeatId
    Write-Host ""
}

# ============================================
# 1c. SHOW (UNHIDE) ALL THREE OFFSET PLANES
# ============================================
# The recorded mapkey targeted a hard-coded tree node (`T3 6`), so it isn't
# reusable as-is. Instead, for each plane we just created, select it BY ID
# (tree-search) then fire ProCmdViewShow@PopupMenuTree — the show command from
# the recording — so all three offset planes are made visible.
#
# This runs on FeatId (was the plane physically created?), BEFORE the $made /
# drivable-dim gate below — so a plane still gets shown even if its offset dim
# wasn't captured. (Previously the "nothing to drive" throw pre-empted the show
# step, which is why a run that failed dim detection also showed no planes.)
$toShow = @($planes | Where-Object { $null -ne $_.FeatId })
if ($toShow.Count -gt 0) {
    Write-Host "  Showing the $($toShow.Count) new offset plane(s)..." -ForegroundColor Cyan
    foreach ($p in $toShow) {
        $showMacro =
            (Get-SelectByIdMacro -FeatId $p.FeatId) +
            "~ Command ``ProCmdViewShow@PopupMenuTree``;"
        Invoke-Macro "show $($p.Label) plane (id $($p.FeatId))" $showMacro
    }
    Write-Host ""
}

# Gate the parametric/resize half on planes that produced a DRIVABLE dim.
$made = @($planes | Where-Object { $null -ne $_.Sym })
if ($made.Count -eq 0) {
    throw "No offset planes produced a drivable dim — nothing to resize. (Any planes that WERE created have been shown above.)"
}
if ($made.Count -lt 3) {
    Write-Host "  WARNING: only $($made.Count) of 3 planes produced a drivable dim." -ForegroundColor Yellow
    Write-Host ""
}

# ============================================
# 2. SUMMARY — the parametric box skeleton
# ============================================
# The three offsets ARE the box dimensions: Side->Width, Top->Height,
# Front->Depth. With the part's three default datums forming the box's anchored
# corner, these three offset planes are the three opposite faces, so each offset
# distance equals one box extent.
function Show-BoxState {
    param($Made)
    Write-Host "  Parametric box planes (offset = box extent):" -ForegroundColor Green
    for ($i = 0; $i -lt $Made.Count; $i++) {
        $p   = $Made[$i]
        $now = Read-DimValue -Model $model -TypeObj $pfcType -Sym $p.Sym
        $dim = switch ($p.Label) { "Side" { "Width" } "Top" { "Height" } "Front" { "Depth" } default { "" } }
        Write-Host ("    [{0}] {1,-5} ({2,-6}) {3,-6} = {4}" -f ($i + 1), $p.Label, $dim, $p.Sym, $now) -ForegroundColor White
    }
}
Show-BoxState -Made $made
Write-Host ""

# ============================================
# BLIND-EVALUATOR HOOK — converge on "the SOLID matches the claim"
# ============================================
# The whole premise of this probe — "resizing the planes IS resizing the box" —
# was, until now, ASSERTED, never measured: Set-PlaneOffset re-reads the dim
# symbol and calls it "held", but a dim can hold symbolically while the solid did
# not actually resize (broken coupling). This hook closes that gap the way the
# wiki's blind evaluator does: measure the finished SOLID (EvalOutline, via the
# shared Measure-Extents), state the claim ("box width = Side offset"), and let an
# independent judge — which never saw the mapkeys or the offset->extent mapping —
# decide from the geometry alone whether the claim holds. It matches by VALUE, so
# it also catches a width/height/depth swap that a symbol re-read cannot.
#
# Returns $true only if the judge's overall verdict is "confirm". On no-config or
# a judge error it writes the packet (for offline judging) and returns $false.
function Invoke-BoxEval {
    param([string]$Operation, [string[]]$Claims)

    # Measure the solid itself (datum-excluded), sorted desc so the judge never
    # needs an axis order. $model / $pfcType / $judgeCfg / $ScriptDir / $made are
    # read from the enclosing scope (same dynamic-scope pattern Set-PlaneOffset uses).
    $excl = New-ExcludeTypes -TypeObj $pfcType
    $ext  = Measure-Extents -Solid $model -ExcludeTypes $excl

    $truth = @{}
    if ($null -ne $ext) {
        $sorted = @($ext | Sort-Object -Descending)
        $truth["measured_extents_sorted_desc"] = @([math]::Round([double]$sorted[0],4), [math]::Round([double]$sorted[1],4), [math]::Round([double]$sorted[2],4))
    } else {
        $truth["measured_extents_sorted_desc"] = $null
        $truth["note"] = "EvalOutline returned no outline (the solid may not exist yet)"
    }

    # Re-read the current offset of every created plane, labeled by box dimension.
    $offsets = @{}
    foreach ($mp in $made) {
        $dim = switch ($mp.Label) { "Side" {"Width"} "Top" {"Height"} "Front" {"Depth"} default {$mp.Label} }
        $offsets[$dim] = Read-DimValue -Model $model -TypeObj $pfcType -Sym $mp.Sym
    }
    $truth["offset_dims"] = $offsets

    $modelName = try { [string]$model.FileName } catch { "(unknown)" }
    $claim = New-EvalClaim -Tool "plane-probe" -Operation $Operation -Claims $Claims
    $slice = Get-GeometrySlice -Model $modelName -Truth $truth

    $base = ($modelName -replace '\.(prt|asm)(\.\d+)?$','') -replace '[^\w\-]','_'
    $packetPath = Join-Path $ScriptDir ($base + "_eval.json")
    $when = (Get-Date).ToString("o")
    Write-EvalPacket -Path $packetPath -Claim $claim -Slice $slice -WhenIso $when | Out-Null
    Write-Host "  Eval packet -> $packetPath" -ForegroundColor DarkGray

    # Judge the PERSISTED packet (reload), so what is judged == what is on disk.
    $packetObj = Get-Content $packetPath -Raw | ConvertFrom-Json
    $verdict = Invoke-BlindJudge -Packet $packetObj -Config $judgeCfg
    return (Show-ConvergenceReport -Verdict $verdict -Title "Blind evaluator: $Operation")
}

# ============================================
# 2b. CREATE THE BOX — EXTRUDE-FIRST with an INTERNAL sketch (v2 algorithm)
# ============================================
# Goal: build the solid whose depth is parametrically driven by the SIDE offset
# plane. This v2 path clicks Extrude FIRST and creates the sketch INSIDE the
# extrude (an internal sketch the feature owns), rather than extruding a separate
# standalone sketch. The section is bound to the feature from the start, which
# removes the standalone-sketch section-binding fragility of the v1 flow.
#
# DIRECTION: sketch ON the offset plane and extrude UP TO the og / default datum,
# so the box grows og -> offset (the natural-reading direction). It stays
# parametric because the offset plane sits exactly the offset dim away from the og
# datum, so the up-to-datum depth equals the offset value — driving the offset dim
# still resizes the box. (Earlier the roles were reversed and the feature read
# offset -> og, which confused users even though the geometry was correct.)
#
# Both plane references are captured BY ID up front and re-selected by ID, so the
# ONLY manual step is drawing the rough rectangle. The rectangle draw is 4 screen
# picks that a RunMacro cannot perform, so it forces ONE split: macro A arms the
# rectangle tool, the user draws, macro B finishes the sketch + extrude.
#
# Transcribed from the user's live recording (current-build widget names):
#   ~ Command `ProCmdFtExtrude`;
#   ~ Select `main_dlg_cur` `PHTLeft.AssyTree` 1 `T3 1`;   <- sketch plane pick (-> select-by-ID)
#   ~ Command `ProCmdViewSketchView`;
#   ~ Command `ProCmdSketRectangle` 1;
#   @PAUSE x4                                              <- the manual rectangle draw (split here)
#   ~ Command `ProCmdSketDone`;
#   ~ Select/Close `maindashInst0.depth_flyout`; ~ Activate `maindashInst0.toselected` 1;
#   ~ Trigger `extrev_1_placement.0.0` `PH.section_select_list` `0`/``;
#   @PAUSE                                                 <- up-to plane pick (-> select-by-ID, NoClear)
#   ~ Enter/Exit `dashInst0.Quit`; ~ Activate `dashInst0.Done`;
#
# Two recorded screen picks are replaced by tree-search select-BY-ID: the sketch
# plane (after ProCmdFtExtrude opens, while it waits for a plane) and the up-to
# plane (feeding the open depth collector — surfenator proves a tree search feeds
# that collector; -NoClear avoids deactivating it).
#
# THREE THINGS TO WATCH LIVE (all new to v2):
#   (1) Does select-by-ID feed the extrude's sketch-plane request the same way the
#       recorded PHTLeft.AssyTree click did? If the extrude doesn't drop into the
#       sketcher, try surfenator's order instead (select plane BY ID *before*
#       ProCmdFtExtrude).
#   (2) Does the parked extrude dashboard survive the RunMacro boundary at the
#       draw split? The internal sketcher is a modal sub-context of the extrude;
#       ProCmdSketDone should return to it, but a dashboard's command context not
#       surviving across RunMacro calls is a known gotcha (see CLAUDE.md).
#   (3) Does select-by-ID (NoClear) feed the toselected/section_select_list
#       collector while the dashboard is open (as in v1's flagged assumption)?

$sidePlane = @($made | Where-Object { $_.Label -eq "Side" })
$sidePlane = if ($sidePlane.Count -gt 0) { $sidePlane[0] } else { $null }

$sketchPlaneId = $null
Write-Host "  Build the box now? (v2: Extrude-first, internal sketch; og -> offset direction)" -ForegroundColor Cyan
$doBox = Read-Host "    (y to create the box, anything else to skip and go straight to resize)"
if ($doBox.Trim().ToUpper() -eq "Y") {
    if ($null -eq $sidePlane) {
        Write-Host "  No SIDE plane was created, so there is nothing to build against. Skipping box." -ForegroundColor Yellow
    } else {

        # --- capture BOTH reference IDs UP FRONT (no commands fire here) ---
        # DIRECTION: sketch ON the og / default datum, extrude UP TO the OFFSET
        # plane. The arrow then reads og -> offset (what we want). This stays
        # parametric because the og datum and the offset plane are separated by
        # EXACTLY the offset dim, so "up to the offset plane" depth == the offset
        # value; driving the offset dim still resizes the box.
        #   1) sketch plane = the og / default datum the user clicks (required;
        #      there's no auto-default — the og datums aren't the planes we made),
        #   2) extrude-to   = OFFSET plane (defaults to the SIDE plane we just made).
        # Both recorded by feature ID and re-selected by ID (no mid-flow clicks).
        Write-Host ""
        Write-Host "  In Creo: CLICK the og/default datum to sketch the box footprint on," -ForegroundColor White
        Write-Host "  then press ENTER." -ForegroundColor White
        Read-Host
        $sketchPlaneId = Read-SelectedId
        if ($null -eq $sketchPlaneId) {
            Write-Host "  Nothing selected for the sketch plane — skipping box." -ForegroundColor Yellow
        } else {
            Write-Host "      sketch plane feature ID = $sketchPlaneId" -ForegroundColor DarkGray
        }

        if ($null -ne $sketchPlaneId) {
            Write-Host ""
            Write-Host "  In Creo: CLICK the OFFSET plane to extrude UP TO (the box grows" -ForegroundColor White
            Write-Host "  from the og plane toward this datum), then press ENTER. Or just" -ForegroundColor White
            Write-Host "  press ENTER to use the SIDE offset plane." -ForegroundColor White
            Read-Host
            $extrudeToId = Read-SelectedId
            if ($null -eq $extrudeToId) {
                $extrudeToId = $sidePlane.FeatId
                Write-Host "      extruding up to SIDE offset plane (id $extrudeToId)" -ForegroundColor DarkGray
            } else {
                Write-Host "      extrude-to feature ID = $extrudeToId" -ForegroundColor DarkGray
            }
        }
    }

    if ($null -ne $sketchPlaneId) {

        $stamp = $null
        try { $stamp = $model.VersionStamp } catch {}

        # --- MACRO A: select sketch plane BY ID -> ProCmdFtExtrude -> orient -> arm
        #     the corner-rectangle tool. Stops before the manual draw. ---
        # ORDER MATTERS: the select-by-ID runs FIRST so its leading buffer_clean
        # wipes the offset plane left in the buffer by the extrude-to capture pick,
        # and leaves ONLY the og datum selected. THEN ProCmdFtExtrude opens and
        # consumes that buffered og datum as its sketch plane (surfenator's proven
        # select-then-extrude order). The earlier version fired ProCmdFtExtrude
        # first, so the extrude grabbed the stale OFFSET plane from the buffer before
        # the by-ID select ran — which is why the sketch kept landing on the offset
        # plane. Then orient + corner-rectangle, leaving the sketcher armed for the
        # user's 2-corner draw.
        $mkArm =
            (Get-SelectByIdMacro -FeatId $sketchPlaneId) +
            "~ Command ``ProCmdFtExtrude``;" +
            "~ Command ``ProCmdViewSketchView``;" +
            "~ Command ``ProCmdSketRectangle`` 1;"
        Invoke-Macro "select sketch plane (id $sketchPlaneId) + extrude + arm rectangle" $mkArm

        Write-Host ""
        Write-Host "  In Creo (internal sketcher): click one corner of the rectangle, then" -ForegroundColor White
        Write-Host "  the opposite corner. Size doesn't matter. Press Esc to finish the" -ForegroundColor White
        Write-Host "  rectangle, then press ENTER here." -ForegroundColor White
        Read-Host

        # --- MACRO B: finish the internal sketch, set depth UP TO the extrude-to
        #     plane (re-selected BY ID), blur the field, confirm. ---
        # Mirrors the recording after the draw. The recorded up-to-plane @PAUSE is
        # replaced by select-by-ID (-NoClear, so the open depth collector stays
        # active). The section_select_list Triggers + the Enter/Exit Quit blur are
        # kept verbatim from the recording.
        $mkFinish =
            "~ Command ``ProCmdSketDone``;" +
            "~ Select ``main_dlg_cur`` ``maindashInst0.depth_flyout``;" +
            "~ Close ``main_dlg_cur`` ``maindashInst0.depth_flyout``;" +
            "~ Activate ``main_dlg_cur`` ``maindashInst0.toselected`` 1;" +
            "~ Trigger ``extrev_1_placement.0.0`` ``PH.section_select_list`` ``0``;" +
            "~ Trigger ``extrev_1_placement.0.0`` ``PH.section_select_list`` ````;" +
            (Get-SelectByIdMacro -FeatId $extrudeToId -NoClear) +
            "~ Enter ``main_dlg_cur`` ``dashInst0.Quit``;" +
            "~ Exit  ``main_dlg_cur`` ``dashInst0.Quit``;" +
            "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"
        Invoke-Macro "finish sketch + extrude up to plane id $extrudeToId + confirm" $mkFinish

        if ($null -ne $stamp) {
            for ($i = 0; $i -lt 100; $i++) {
                try { if ($model.VersionStamp -ne $stamp) { break } } catch {}
                Start-Sleep -Milliseconds 50
            }
        }
        Write-Host ""

        # --- BLIND EVALUATE the freshly built box -------------------------------
        # Claim: each box extent equals its driving offset. The judge measures the
        # solid and confirms/refutes from geometry alone (no axis map handed to it).
        $buildClaims = @()
        foreach ($mp in $made) {
            $dim = switch ($mp.Label) { "Side" {"Width"} "Top" {"Height"} "Front" {"Depth"} default {$mp.Label} }
            $val = Read-DimValue -Model $model -TypeObj $pfcType -Sym $mp.Sym
            if ($null -ne $val) { $buildClaims += ("the box {0} is {1}" -f $dim.ToLower(), $val) }
        }
        $buildClaims += "the solid's three measured extents each equal one of the three offset dims"
        $script:buildConfirmed = Invoke-BoxEval -Operation "build-box" -Claims $buildClaims
        Write-Host ""
    }
}

# Write one plane's offset, force a regen, return the value that actually stuck.
function Set-PlaneOffset {
    param($Plane, [double]$Value)
    try {
        $d = $model.GetItemByName($pfcType.ITEM_DIMENSION, $Plane.Sym)
        $d.DimValue = $Value
    } catch {
        Write-Host "    $($Plane.Label): could not write DimValue: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
    Invoke-ForceRegen -Model $model
    return (Read-DimValue -Model $model -TypeObj $pfcType -Sym $Plane.Sym)
}

# ============================================
# 3. PARAMETRIC LOOP — resize the box (all three) or one plane, watch each stick
# ============================================
# The box-resize demonstration. Commands:
#   A           -> set all three offsets in one pass (resize the whole box)
#   1..N        -> resize a single plane
#   D / blank   -> done (exit the loop)
# Either way each write goes through Set-PlaneOffset (DimValue + force regen) and
# is re-read to confirm it held.
Write-Host "  Resize loop:" -ForegroundColor Cyan
Write-Host "    A = set ALL three (resize the box),  1-$($made.Count) = one plane,  D/blank = done" -ForegroundColor White
while ($true) {
    $cmd = Read-Host "  Command (A / 1-$($made.Count) / D)"
    if ([string]::IsNullOrWhiteSpace($cmd) -or $cmd.Trim().ToUpper() -eq "D") {
        Write-Host "  Done resizing." -ForegroundColor Cyan
        break
    }

    if ($cmd.Trim().ToUpper() -eq "A") {
        # Resize the whole box: prompt each, write each, then report once.
        $targets = @()
        foreach ($p in $made) {
            $dim = switch ($p.Label) { "Side" { "Width" } "Top" { "Height" } "Front" { "Depth" } default { "" } }
            $raw = Read-Host "    $($p.Label) ($dim) new offset"
            $v = 0.0
            if (-not [double]::TryParse($raw, [ref]$v)) { Write-Host "      not a number — skipping $($p.Label)." -ForegroundColor Yellow; continue }
            $targets += [pscustomobject]@{ Plane = $p; Want = $v }
        }
        foreach ($t in $targets) {
            $now = Set-PlaneOffset -Plane $t.Plane -Value $t.Want
            if ($null -ne $now -and [math]::Abs($now - $t.Want) -lt 1e-4) {
                Write-Host "    $($t.Plane.Label) $($t.Plane.Sym) = $now  (held)" -ForegroundColor Green
            } else {
                Write-Host "    $($t.Plane.Label) $($t.Plane.Sym) = $now  (wanted $($t.Want) — did NOT hold)" -ForegroundColor Yellow
            }
        }
        Write-Host ""
        Show-BoxState -Made $made
        Write-Host ""
        # Blind-evaluate the WHOLE resized box: the dim "held" symbolically above,
        # but did the SOLID actually take those sizes? The judge measures and decides.
        $resizeClaims = foreach ($t in $targets) {
            $dim = switch ($t.Plane.Label) { "Side" {"Width"} "Top" {"Height"} "Front" {"Depth"} default {$t.Plane.Label} }
            "the box $($dim.ToLower()) is $($t.Want)"
        }
        if (@($resizeClaims).Count -gt 0) { $null = Invoke-BoxEval -Operation "resize-all" -Claims @($resizeClaims) }
        Write-Host ""
        continue
    }

    $sel = 0
    if (-not [int]::TryParse($cmd, [ref]$sel) -or $sel -lt 1 -or $sel -gt $made.Count) {
        Write-Host "    enter A or 1-$($made.Count)." -ForegroundColor Yellow; continue
    }
    $p = $made[$sel - 1]

    $valRaw = Read-Host "    New offset for $($p.Label) ($($p.Sym))"
    $v = 0.0
    if (-not [double]::TryParse($valRaw, [ref]$v)) { Write-Host "    not a number." -ForegroundColor Yellow; continue }

    $now = Set-PlaneOffset -Plane $p -Value $v
    if ($null -ne $now -and [math]::Abs($now - $v) -lt 1e-4) {
        Write-Host "    $($p.Label) $($p.Sym) = $now  (held)" -ForegroundColor Green
    } else {
        Write-Host "    $($p.Label) $($p.Sym) = $now  (wanted $v — did NOT hold)" -ForegroundColor Yellow
    }
    # Blind-evaluate this single resize against the measured solid (dim "held" is
    # necessary but not sufficient — confirm one measured extent actually became $v).
    $dimName = switch ($p.Label) { "Side" {"Width"} "Top" {"Height"} "Front" {"Depth"} default {$p.Label} }
    $null = Invoke-BoxEval -Operation "resize-$($dimName.ToLower())" -Claims @("the box $($dimName.ToLower()) is $v")
}

Write-Host ""
if ($script:macroFailures -eq 0) {
    Write-Host "  Probe complete (no mapkey failures)." -ForegroundColor Cyan
} else {
    Write-Host "  Probe complete with $($script:macroFailures) mapkey failure(s) — see red lines above." -ForegroundColor Yellow
}
# Honest final word on the box build: green only if the BLIND judge measured the
# solid and confirmed the claim (not merely that the mapkeys fired or a dim symbol
# read back). $script:buildConfirmed is unset if no box was built this run.
if ($null -ne $script:buildConfirmed) {
    if ($script:buildConfirmed) {
        Write-Host "  Box build: independently confirmed by the blind evaluator (solid measured)." -ForegroundColor Green
    } else {
        Write-Host "  Box build: NOT independently confirmed — see the blind-evaluator verdict above." -ForegroundColor Yellow
        Write-Host "  (An eval packet was written; it can also be judged offline.)" -ForegroundColor DarkGray
    }
}

} finally {
    try {
        if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null }
        if ($null -ne $origDynamicPreview)  { $session.SetConfigOption("dynamic_preview",  $origDynamicPreview)  | Out-Null }
    } catch {}
    $connection.Disconnect($null)
}

Write-Host ""
Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
