<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

# ============================================================================
# pocketinator.cmd - ONE connected chip-clearance pocket (inner-offset cut)
# ============================================================================
# Instead of N individual coaxial relief holes (drilljig STAGE 4), this cuts ONE
# connected chip-clearance pocket: an inset loop OFFSET inward from the plate's
# own boundary, extruded as a shallow blind REMOVE-MATERIAL cut. "All the area
# enclosed by the holes is chip clearance" - the whole inset region is relieved.
#
# WHY OFFSET-THE-BOUNDARY (the user's idea) BEATS draw-a-rectangle:
#   - PARAMETRIC: the inset margin is a real sketch offset tied to the plate's
#     existing boundary, so the pocket follows the actual plate outline (handles
#     non-rectangular plates) and tracks the plate if it is resized.
#   - NO COORDINATE READ: it references the boundary loop that already exists -
#     sidestepping the IpfcPoint.Point live crash ("op_Subtraction on
#     System.Object[]") that blocks every "hug the individual points" shape
#     (convex hull / bounding rect / union-of-disks). See CLAUDE.md holeinator
#     "History / why ID-only".
#   - NO per-point / per-vertex picks: the only human action in the sketch is the
#     Offset itself (a few clicks).
#
# STANDALONE (like cornerinator/radinator) - does NOT touch drilljig.cmd; the
# drill-jig pipeline and its per-point relief are left intact.
#
# ----------------------------------------------------------------------------
# HUMAN-IN-THE-LOOP v1 - the OFFSET step is a guided manual pick (by design)
# ----------------------------------------------------------------------------
# The CUT half is fully proven/mined in this repo:
#   - remove-material toggle  maindashInst0.remove_material_cb 1   (mined live
#     from working_folder\trail.txt.8:1799 - the Remove Material checkbox)
#   - body select for the cut  body_page.1.0 / PH.bodyselectrepwdg_list   (the
#     holeinator-proven collector; the trail showed body_page.0.0 but holeinator
#     runs .1.0 live - the canary catches a wrong suffix on cut #1)
#   - blind typed depth  GrmTextTagEmbedMRU + Enter/Exit dashInst0.Quit blur
#     (boxinator.cmd:594-600, proven live)
#   - extrude-first / internal-sketch open + select-by-ID  (plane-probe v2)
#
# The OFFSET half is NOT recorded anywhere: all four candidate trail files were
# mined and came back NEGATIVE - none contains ProCmdSketOffset / ProCmd2dEdge /
# ProCmdSketUse, and the VB API exposes no programmatic sketch-offset (only
# datum-plane offset constraints). So the sketcher Offset command, its distance
# field, and the loop/flip widgets are GENUINELY UNKNOWN and are NOT guessed
# here. Instead the tool opens the internal sketcher for you and PAUSES while you
# run Sketch > Offset > Loop and type the margin by hand, exactly like boxinator
# pauses for the rough-rectangle draw. To upgrade to full-auto later: record one
# trail of Sketch>Offset (visible_mapkeys yes), re-mine it, and replace the
# manual pause in MACRO A with the captured offset fragment.
#
# VERIFICATION = VersionStamp changed (the cut mutated the model), NOT a
# geometric measure of the inset - the same honest bar as holeinator/cornerinator.
# A canary validates the cut fired before the success message. Wiring a
# blind-evaluator volume/extent check is the later hardening step, not v1.
#
# PREREQUISITES:
#   1. The jig PART (not .asm) open in Creo, on its default datums.
#   2. The drilled through-holes already present (this relieves over them).
#   3. A flat, roughly axis-aligned plate (thinnest extent = thickness).
# ============================================================================

$Host.UI.RawUI.WindowTitle = "POCKETINATOR"
$Verbose = $ScriptArgs -match '(?i)-v|--verbose'
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

# ============================================================================
# HELPERS
# ============================================================================

# $true if VersionStamp changed within the timeout (the macro modified the
# model). The canary net against mapkey widget-name drift. (drilljig/cornerinator)
function Wait-ModelModified {
    param($Model, [string]$PreviousStamp, [int]$TimeoutMs = 30000)
    $deadline = [DateTime]::Now.AddMilliseconds($TimeoutMs)
    while ([DateTime]::Now -lt $deadline) {
        try { if ($Model.VersionStamp -ne $PreviousStamp) { return $true } } catch {}
        # Poll gap (proven pattern from boxinator/drilljig_core): without it this loop
        # busy-waits, pegging a CPU core AND flooding Creo with COM VersionStamp reads
        # *during* the regen it is polling for -- which slows the very operation. 40ms
        # is far finer than any Creo regen, so detection latency is imperceptible.
        Start-Sleep -Milliseconds 40
    }
    return $false
}

# Read the last selected feature ID from the selection buffer (plane-probe's
# Read-SelectedId). ID-ONLY - never reads a coordinate.
function Read-SelectedFeatureId {
    param($Session)
    $contents = $null
    try { $contents = ($Session.CurrentSelectionBuffer()).Contents } catch {}
    if ($null -eq $contents -or $contents.Count -eq 0) { return $null }
    try { return [int]$contents[$contents.Count - 1].SelItem.Id } catch { return $null }
}

# The proven tree-search select-by-ID FEATURE fragment (nodelator/flipenator/
# plane-probe). Clears the buffer, selects the feature with the given ID into it;
# the caller appends whatever command consumes that buffered selection
# (ProCmdFtExtrude here). -NoClear omits the leading buffer_clean for feeding an
# already-open dashboard collector (surfenator pattern).
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

# ----------------------------------------------------------------------------
# Build-CutFinishMacro - MACRO B: finish the internal sketch (which now holds the
# inset offset loop the user just drew), set the shallow blind depth, toggle
# REMOVE MATERIAL, pick the target body, confirm. ONE atomic RunMacro - a
# dashboard's command context does not survive across RunMacro calls (CLAUDE.md
# boxinator lesson), so the whole finish-to-Done sequence is a single string.
#
# WIDGET PROVENANCE:
#   ProCmdSketDone .................... CLAUDE.md confirmed (exit sketcher)
#   GrmTextTagEmbedMRU + Enter/Exit Quit  boxinator.cmd:594-600 (blind typed depth)
#   maindashInst0.remove_material_cb 1    trail.txt.8:1799 (mined - the cut toggle)
#   chkbn.body_page.0 / body_page.1.0 / PH.bodyselectrepwdg_list
#                                         holeinator.cmd:99-108 (proven body select)
#   dashInst0.Done .................... confirm (proven everywhere)
#
# DEPTH ORDER: type the depth FIRST (blur via Enter/Exit Quit), THEN flip
# remove_material on, THEN body, THEN Done - mirrors the recorded order
# (depth set, then remove_material_cb at trail.txt.8:1799, then body, then Done).
# ----------------------------------------------------------------------------
function Build-CutFinishMacro {
    param([double]$Depth, [int]$BodyIndex = 0)
    return "~ Command ``ProCmdSketDone``;" +
        # shallow blind depth (typed), then blur the field so Done can land
        "~ Update ``main_dlg_cur`` ``GrmTextTagEmbedMRU`` ``$Depth``;" +
        "~ Activate ``main_dlg_cur`` ``GrmTextTagEmbedMRU``;" +
        "~ Enter ``main_dlg_cur`` ``dashInst0.Quit``;" +
        "~ Exit  ``main_dlg_cur`` ``dashInst0.Quit``;" +
        # REMOVE MATERIAL -> this extrude becomes a cut
        "~ Activate ``main_dlg_cur`` ``maindashInst0.remove_material_cb`` 1;" +
        # body the cut removes from (holeinator's proven body_page.1.0 collector)
        "~ Activate ``main_dlg_cur`` ``chkbn.body_page.0`` 1;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ``$BodyIndex``;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ````;" +
        "~ Focus  ``body_page.1.0`` ``PH.bodyselectrepwdg_list``;" +
        "~ Select ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` 1 ``$BodyIndex``;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ````;" +
        # confirm
        "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"
}

# ============================================================================
# HEADER
# ============================================================================
Write-Host ""
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "   POCKETINATOR  -  one connected chip-clearance pocket (inner offset)" -ForegroundColor Cyan
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Cuts ONE shallow blind pocket from an inset loop offset inward from" -ForegroundColor White
Write-Host "  the plate boundary - replacing N individual chip-relief holes." -ForegroundColor White
Write-Host ""
Write-Host "  Prerequisites:" -ForegroundColor Green
Write-Host "    1. The jig PART (not .asm) open in Creo, on its default datums" -ForegroundColor White
Write-Host "    2. The through-holes already drilled (this relieves over them)" -ForegroundColor White
Write-Host "    3. A flat, roughly axis-aligned plate (thinnest extent = thickness)" -ForegroundColor White
Write-Host ""

# ============================================================================
# SHARED LIBRARY (geometry reads)
# ============================================================================
. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')

# ============================================================================
# USER INPUT (before connecting)
# ============================================================================
# Inset margin: how far the pocket boundary sits inside the plate edge. This is
# the value you TYPE into the sketcher Offset tool by hand; it is captured here
# only to show you in the prompt, the script does not drive the offset.
$MarginValue = 0.5
$raw = Read-Host "  Inset margin in inches - pocket boundary inside the plate edge (blank -> 0.5)"
if (-not [string]::IsNullOrWhiteSpace($raw)) {
    $mv = 0.0
    if ([double]::TryParse($raw.Trim(), [ref]$mv) -and $mv -gt 0) { $MarginValue = $mv }
    else { Write-Host "  Not a positive number - using 0.5" -ForegroundColor Yellow }
}
Write-Host "  Inset margin: $MarginValue (you will type this into the sketcher Offset)" -ForegroundColor Green
Write-Host ""

# Pocket depth = a percentage of plate thickness (the chosen convention). The
# plate thickness is measured live after connecting; the percent is asked now.
$DepthPct = 0.20
$rawPct = Read-Host "  Pocket depth as % of plate thickness (blank -> 20)"
if (-not [string]::IsNullOrWhiteSpace($rawPct)) {
    $pv = 0.0
    $clean = $rawPct.Trim().TrimEnd('%')
    if ([double]::TryParse($clean, [ref]$pv) -and $pv -gt 0 -and $pv -lt 100) { $DepthPct = $pv / 100.0 }
    else { Write-Host "  Not a percentage in (0,100) - using 20%" -ForegroundColor Yellow }
}
Write-Host ("  Pocket depth: {0:P0} of plate thickness" -f $DepthPct) -ForegroundColor Green
Write-Host ""

# Up / thickness axis: auto (thinnest extent) by default; X/Y/Z to override.
$upChoice = Read-Host "  Up/thickness axis - A=auto (thinnest), or X / Y / Z (blank -> auto)"
$upMode = "AUTO"
switch ($upChoice.Trim().ToUpper()) {
    "X" { $upMode = "X" }
    "Y" { $upMode = "Y" }
    "Z" { $upMode = "Z" }
    default { $upMode = "AUTO" }
}
Write-Host "  Up axis: $upMode" -ForegroundColor Green
Write-Host ""

# ============================================================================
# CONNECT
# ============================================================================
Write-Host "  Connecting to Creo..." -NoNewline

$proc = Get-Process -Name "xtop" -ErrorAction SilentlyContinue
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
$model = $session.CurrentModel

if ($null -eq $model) {
    Write-Host ""
    Write-Host "  FAILED: No model open in Creo." -ForegroundColor Red
    exit 1
}

Write-Host " Connected to $($model.FileName)" -ForegroundColor Green

# Mode guard: this tool cuts a PART. In assembly mode by-ID selection resolves
# against the .asm, not the part. Key off the filename extension (EpfcModelType
# enum ints are unconfirmed on this build - drilljig.cmd lesson).
$modelFile = ""
try { $modelFile = [string]$model.FileName } catch {}
if ($modelFile -match '\.asm(\.\d+)?$') {
    Write-Host ""
    Write-Host "  STOP: the active model is an ASSEMBLY ($modelFile)." -ForegroundColor Yellow
    Write-Host "  This tool cuts a single PART. Open the jig PART itself" -ForegroundColor Yellow
    Write-Host "  (activate it in its own window), then re-run." -ForegroundColor Yellow
    Write-Host ""
    try { $connection.Disconnect($null) } catch {}
    exit 1
}

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

# ============================================================================
# MEASURE EXTENTS + PICK UP AXIS + DERIVE DEPTH
# ============================================================================
Write-Host ""
Write-Host "  Measuring the plate..." -ForegroundColor Cyan
$excl = New-ExcludeTypes -TypeObj $modelItemType
$ext  = Measure-Extents -Solid $model -ExcludeTypes $excl

$upIndex = $null
if ($null -ne $ext) {
    Write-Host ("    extents: X=$([math]::Round($ext[0],4))  Y=$([math]::Round($ext[1],4))  Z=$([math]::Round($ext[2],4))") -ForegroundColor White
    switch ($upMode) {
        "X" { $upIndex = 0 }
        "Y" { $upIndex = 1 }
        "Z" { $upIndex = 2 }
        default {
            # AUTO: smallest extent = plate thickness
            $upIndex = 0
            if ($ext[1] -lt $ext[$upIndex]) { $upIndex = 1 }
            if ($ext[2] -lt $ext[$upIndex]) { $upIndex = 2 }
        }
    }
} else {
    Write-Host "    Could not measure the solid extents (EvalOutline gave nothing)." -ForegroundColor Yellow
    if ($upMode -eq "AUTO") {
        Write-Host "    Auto up-axis needs the extents; defaulting up = Z. Re-run with X/Y/Z to override." -ForegroundColor Yellow
        $upIndex = 2
    } else {
        $upIndex = switch ($upMode) { "X" {0} "Y" {1} "Z" {2} default {2} }
    }
}
$axisName = @("X","Y","Z")[$upIndex]

# Plate thickness = the extent along the up axis. The pocket depth is a percent
# of this. If extents could not be measured, fall back to a manual thickness
# prompt (so the tool still works), mirroring drilljig STAGE 4's fallback.
$thickness = if ($null -ne $ext) { [double]$ext[$upIndex] } else { 0.0 }
if ($thickness -le 0) {
    Write-Host "  Could not read plate thickness from the up axis - enter it by hand." -ForegroundColor Yellow
    while ($thickness -le 0) {
        $traw = Read-Host "  Plate thickness in inches (drill-direction)"
        $tv = 0.0
        if ([double]::TryParse($traw.Trim(), [ref]$tv) -and $tv -gt 0) { $thickness = $tv }
        else { Write-Host "  Enter a positive number." -ForegroundColor Yellow }
    }
}
$pocketDepth = [Math]::Round($thickness * $DepthPct, 4)
Write-Host ("  Up/thickness axis: $axisName  (plate thickness ~ {0})" -f [math]::Round($thickness,4)) -ForegroundColor Green
Write-Host ("  Pocket depth = {0:P0} of {1} = {2}`"" -f $DepthPct, [math]::Round($thickness,4), $pocketDepth) -ForegroundColor Green
if ($pocketDepth -ge $thickness) {
    Write-Host "  WARNING: pocket depth >= plate thickness - this would cut through. Reduce the %." -ForegroundColor Red
}
Write-Host ""

# ============================================================================
# STEP 1 - SKETCH PLANE (the plate face to pocket from)
# ============================================================================
# The pocket is sketched on the plate's top face and cut DOWN into the plate.
# Select that face by ID (the human picks it once; we read its feature ID), so
# the extrude opens on the right plane with no mid-flow coordinate read.
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "   STEP 1 - pick the face to pocket FROM" -ForegroundColor Cyan
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "  In Creo: CLICK the flat plate face the pocket is cut from (the same" -ForegroundColor White
Write-Host "  side the chip clearance should open onto), then press ENTER." -ForegroundColor White
Read-Host
$sketchPlaneId = Read-SelectedFeatureId -Session $session
if ($null -eq $sketchPlaneId) {
    Write-Host "  Nothing selected - cannot open the sketch. Re-run and click the face." -ForegroundColor Yellow
    throw "No sketch plane selected."
}
Write-Host "      sketch plane feature ID = $sketchPlaneId" -ForegroundColor DarkGray
Write-Host ""

# ============================================================================
# STEP 2 - TARGET BODY (which solid the cut removes from)
# ============================================================================
# Enumerate solid bodies; single body -> index 0 silently; multiple -> prompt.
# The cut's body_page collector selects by list index (holeinator's pattern).
$bodyIndex = 0
$bodies = @()
try { $bodies = @($model.ListItems($modelItemType.ITEM_BODY)) } catch {}
if ($bodies.Count -gt 1) {
    Write-Host "  ====================================================================" -ForegroundColor Cyan
    Write-Host "   STEP 2 - which body does the pocket cut from?" -ForegroundColor Cyan
    Write-Host "  ====================================================================" -ForegroundColor Cyan
    Write-Host "  $($bodies.Count) solid bodies found. The cut removes from ONE body." -ForegroundColor White
    for ($i = 0; $i -lt $bodies.Count; $i++) {
        $bid = "?"
        try { $bid = [int]$bodies[$i].Id } catch {}
        Write-Host ("    [$i]  body id $bid") -ForegroundColor White
    }
    $braw = Read-Host "  Body index (blank -> 0)"
    if (-not [string]::IsNullOrWhiteSpace($braw)) {
        $bi = 0
        if ([int]::TryParse($braw.Trim(), [ref]$bi) -and $bi -ge 0 -and $bi -lt $bodies.Count) { $bodyIndex = $bi }
        else { Write-Host "  Out of range - using 0." -ForegroundColor Yellow }
    }
    Write-Host "  Cutting from body index $bodyIndex." -ForegroundColor Green
    Write-Host ""
} else {
    Write-Log "Single body (or none enumerable) - using body index 0."
}

# ============================================================================
# CONFIRM
# ============================================================================
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "   READY" -ForegroundColor Cyan
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host ("  Pocket: inset {0}`" from the plate edge, blind depth {1}`", body index {2}." -f `
    $MarginValue, $pocketDepth, $bodyIndex) -ForegroundColor White
Write-Host "  This removes a connected region of plate material - structurally more" -ForegroundColor Yellow
Write-Host "  aggressive than individual relief holes. No Blue Origin standard found" -ForegroundColor Yellow
Write-Host "  authorizing a connected chip cavity - verify the design is intended." -ForegroundColor Yellow
Write-Host ""
$go = Read-Host "  Proceed to open the sketch? (y/N)"
if ($go -notmatch '^[Yy]$') {
    Write-Host "  Cancelled - no pocket created." -ForegroundColor Yellow
} else {

    $stamp = $null
    try { $stamp = $model.VersionStamp } catch {}

    # ========================================================================
    # MACRO A - open the extrude on the plate face (by ID) + enter the internal
    # sketcher, oriented to the sketch view. Stops here so the human does the
    # Offset by hand (the one unrecorded step). ONE atomic macro.
    #
    # ORDER: select-by-ID runs FIRST so its buffer_clean leaves ONLY the plate
    # face selected; THEN ProCmdFtExtrude consumes that buffered face as its
    # sketch plane (surfenator's select-then-extrude order; plane-probe lesson -
    # firing the extrude first grabs a stale buffered ref).
    # ========================================================================
    $mkOpen =
        (Get-SelectByIdMacro -FeatId $sketchPlaneId) +
        "~ Command ``ProCmdFtExtrude``;" +
        "~ Command ``ProCmdViewSketchView``;"
    Write-Host ""
    Write-Host "  Opening the sketch on face id $sketchPlaneId ..." -ForegroundColor Cyan
    try { $session.RunMacro($mkOpen) } catch {
        Write-Host "  Could not open the extrude/sketch: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }

    # ----- THE ONE MANUAL STEP: Sketch > Offset the boundary loop inward -----
    Write-Host ""
    Write-Host "  ====================================================================" -ForegroundColor Magenta
    Write-Host "   MANUAL STEP - offset the plate boundary inward (sketcher Offset)" -ForegroundColor Magenta
    Write-Host "  ====================================================================" -ForegroundColor Magenta
    Write-Host "  You are now in the internal sketcher. Do this in Creo:" -ForegroundColor White
    Write-Host "    1. Sketch ribbon  ->  Offset  (Offset Edge)" -ForegroundColor White
    Write-Host "    2. In the Type box choose  LOOP, then click the plate's outer" -ForegroundColor White
    Write-Host "       boundary edge - the whole loop highlights." -ForegroundColor White
    Write-Host ("    3. Type the offset distance  {0}  and aim it INWARD (toward the" -f $MarginValue) -ForegroundColor White
    Write-Host "       plate center; flip the arrow if it goes outward)." -ForegroundColor White
    Write-Host "    4. Accept the offset. You should have ONE closed inset loop." -ForegroundColor White
    Write-Host ""
    Write-Host "  Leave the sketch OPEN (do not finish it - the script does that)." -ForegroundColor Yellow
    Write-Host "  When the inset loop is drawn, press ENTER here." -ForegroundColor Yellow
    Read-Host

    # ========================================================================
    # MACRO B - finish the sketch + shallow blind depth + REMOVE MATERIAL +
    # body + confirm, as ONE atomic RunMacro (dashboard context does not survive
    # across RunMacro calls). See Build-CutFinishMacro for widget provenance.
    # ========================================================================
    Write-Host ""
    Write-Host "  Finishing the sketch and cutting the pocket..." -ForegroundColor Cyan
    $changed = $false
    try {
        $macro = Build-CutFinishMacro -Depth $pocketDepth -BodyIndex $bodyIndex
        $session.RunMacro($macro)
        if ($null -ne $stamp) {
            $changed = Wait-ModelModified -Model $model -PreviousStamp $stamp -TimeoutMs 30000
        }
    } catch {
        Write-Host "  Macro error firing the cut: $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host ""
    Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
    if ($changed) {
        Write-Host "  Done - the model changed (the pocket cut fired)." -ForegroundColor Green
        Write-Host "  NOTE: verification is a VersionStamp change, NOT a geometric" -ForegroundColor DarkGray
        Write-Host "  measure of the inset. Verify the pocket visually in Creo:" -ForegroundColor DarkGray
        Write-Host "   - it encloses every through-hole," -ForegroundColor DarkGray
        Write-Host "   - it opens onto the correct (chip-clearance) face," -ForegroundColor DarkGray
        Write-Host "   - a supporting land remains around each bushing seat." -ForegroundColor DarkGray
    } else {
        Write-Host "  The model did NOT change - the cut did not commit." -ForegroundColor Red
        Write-Host "  Likely causes, in order:" -ForegroundColor Yellow
        Write-Host "   - the inset loop was not a single CLOSED loop (Offset>Loop)," -ForegroundColor Yellow
        Write-Host "   - the depth/remove-material/body widget names drifted on this" -ForegroundColor Yellow
        Write-Host "     Creo build (Build-CutFinishMacro) - check the extrude" -ForegroundColor Yellow
        Write-Host "     dashboard is still open in Creo and finish it by hand," -ForegroundColor Yellow
        Write-Host "   - body index $bodyIndex was wrong for this part." -ForegroundColor Yellow
        Write-Host "  Inspect Creo; nothing was force-committed." -ForegroundColor Yellow
    }
}

$elapsed = (Get-Date) - $startTime
Write-Host ""
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
