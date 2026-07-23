<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

# ============================================================================
# slotinator.cmd - rectangular chip-relief SLOTS, one per hole ROW
# ============================================================================
# Replaces the ROUND chip relief (drilljig STAGE 4 coaxial relief holes / STAGE 6
# relief paths) with a RECTANGULAR extrude cutout per hole row. For every row of
# holes the tool cuts ONE shallow blind slot:
#     LENGTH = ALWAYS the full part length along the removal-path direction
#     WIDTH  = the ORIGINAL drilled hole diameter  (NOT the 1.5x relief dia)
#     DEPTH  = a % of plate thickness (default 20%), a BLIND cut driven into the
#              def_depth1_ip field (Build-CutFinishMacro); falls back to Creo's
#              default depth only if the thickness can't be measured/entered
# and it does this for EVERY row, auto-looped. The slot-edge offset PLANES are
# created and MADE VISIBLE as guides for the manual rectangle draw (no datum
# points - they were useless).
#
# STANDALONE (like pocketinator/cornerinator/radinator) - does NOT touch
# drilljig.cmd or pocketinator.cmd; the drill-jig pipeline is left intact. Prove
# the capability here, fold into drilljig later (the repo pattern).
#
# ----------------------------------------------------------------------------
# HOW IT LEARNS THE ROWS - NO coordinate read (dodges the IpfcPoint.Point crash)
# ----------------------------------------------------------------------------
# Reading the drilled holes off the model crashes on this build ("op_Subtraction
# on System.Object[]" - the holeinator lesson). So instead the operator RE-ENTERS
# the SAME hole layout in the grid GUI (Show-OrthogridDialog /
# Show-CustomPointsDialog - the exact editor used to place the holes), and every
# slot rectangle is PURE MATH on those {X;Z} offsets via Get-RowSlots
# (lib\orthogrid.ps1). Rows are grouped by the CROSS-coordinate (Z when the rows
# run along X) with a PHYSICAL row tolerance (max(SlotWidth/4, 0.01), never a
# 1e-6 float-equality guard - that would silently fragment a near-but-not-equal
# custom row into N full-width slots).
#
# ----------------------------------------------------------------------------
# HUMAN-IN-THE-LOOP - the rectangle DRAW is a guided manual pick (by design)
# ----------------------------------------------------------------------------
# The CUT half is fully proven/mined in this repo (Build-CutFinishMacro,
# transcribed verbatim from the operator's recording trail.txt.32:4398-4412):
#   - remove-material toggle  maindashInst0.remove_material_cb 1   (the Remove
#     Material checkbox; also trail.txt.8:1799)
#   - Enter/Exit dashInst0.Quit blur, then Done  (NO depth typed - the recorded
#     cut takes Creo's default cut depth)
#   - body select for the cut  body_page.1.0 / PH.bodyselectrepwdg_list
#   - extrude-first / internal-sketch open + select-by-ID  (plane-probe v2)
# A RunMacro CANNOT draw sketch geometry, so - exactly like boxinator pauses for
# the rough-rectangle draw and pocketinator pauses for the Offset - this tool
# computes each row's EXACT target rectangle (prints W x H, corners), creates the
# slot-edge offset PLANES and MAKES THEM VISIBLE as draw guides, opens the internal
# sketcher, and PAUSES while you draw the corner rectangle around that row's holes.
# Then it auto-finishes the sketch and extrudes the cut. Auto-loops to the next row.
#
# GUIDE PLANES ONLY, never a gate (user 2026-07-06: the old corner datum POINTS
# were useless - they only landed on the sketch plane when the picked face was
# coincident with the SIDE datum - so we create ONLY the offset planes at the slot
# edges and show them). If the default datums can't be auto-discovered (oddly-named
# / imported part), the tool WARNS and still arms the rectangle for a freehand draw
# from the printed sizes. The cut is the deliverable; the planes are an aid.
#
# VERIFICATION = VersionStamp changed (the cut fired), NOT a geometric measure of
# the slot - the same honest bar as pocketinator/holeinator. A canary on ROW 1's
# cut aborts the loop if the recipe didn't fire; later rows count no-ops without
# aborting.
#
# *** NOT YET RUN LIVE END TO END. *** The cut half is proven (pocketinator); the
# per-row loop + corner-point guides are new. The offline math is unit-tested
# (lib\tests\run_orthogrid_tests.ps1, Get-RowSlots block).
#
# PREREQUISITES:
#   1. The jig PART (not .asm) open in Creo, on its default datums.
#   2. The drilled through-holes already present (this relieves over them).
#   3. A flat, roughly axis-aligned plate (thinnest extent = thickness).
#
# FLAGS:  -v / --verbose ,  --strict-overlap  (fatal if two rows' slots overlap) ,
#         --flip     (start the seed cut flipped; default = Creo's direction) ,
#         --no-pattern  (cut every row by hand instead of seed+pattern)
# ============================================================================

$Host.UI.RawUI.WindowTitle = "SLOTINATOR"
$Verbose        = $ScriptArgs -match '(?i)-v|--verbose'
$StrictOverlap  = $ScriptArgs -match '(?i)--strict-overlap'
# DEFAULT = NO flip: on the SIDE-datum sketch, Creo's default remove-material
# direction cuts INTO the plate (matches the operator's proven trail.32 hand cut,
# which had no flip). trail.33 showed a forced flip cut the WRONG way. --flip opts
# in to one flip for a part that defaults the other way. Either way the SEED cut is
# verified with the operator, who flips it live if the starting guess is wrong.
$FlipDir        = ($ScriptArgs -match '(?i)--flip')
# By default, evenly-spaced rows are made by drawing ONE seed slot and PATTERNING
# it (the user's ask - no drawing rectangles over and over). --no-pattern forces
# the per-row draw loop (also the automatic fallback for irregular row spacing).
$NoPattern      = $ScriptArgs -match '(?i)--no-pattern'
# The pattern DIRECTION is fed as a base datum plane's normal (hands-free, by ID).
# --pattern-flip reverses it if the copies march off the plate instead of across it.
$PatternFlip    = $ScriptArgs -match '(?i)--pattern-flip'
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

# ----------------------------------------------------------------------------
# Build-CutFinishMacro, Invoke-VerifiedSeedCut, and Build-SlotPatternMacro now live
# in lib\drilljig_core.ps1 (dot-sourced below) so slotinator.cmd, drilljig.cmd, and
# drilljig-gui.cmd all fire the SAME confirmed-live macros. Invoke-VerifiedSeedCut
# reads the core session scope ($script:DJSession/$script:DJModel) set by
# Initialize-DrilljigCore, which slotinator calls after connecting.
# ----------------------------------------------------------------------------

# ============================================================================
# HEADER
# ============================================================================
Write-Host ""
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "   SLOTINATOR  -  rectangular chip-relief slots, one per hole row" -ForegroundColor Cyan
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  For every ROW of holes, cuts ONE blind rectangular slot:" -ForegroundColor White
Write-Host "    length = the full part length along the row" -ForegroundColor White
Write-Host "    width  = the ORIGINAL drilled hole diameter" -ForegroundColor White
Write-Host "    depth  = % of plate thickness (default 20%), blind remove-material cut" -ForegroundColor White
Write-Host "  replacing the round coaxial relief holes / relief paths." -ForegroundColor White
Write-Host ""
Write-Host "  *** NOT yet run live end-to-end - verify each slot visually. ***" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Prerequisites:" -ForegroundColor Green
Write-Host "    1. The jig PART (not .asm) open in Creo, on its default datums" -ForegroundColor White
Write-Host "    2. The through-holes already drilled (this relieves over them)" -ForegroundColor White
Write-Host "    3. A flat, roughly axis-aligned plate (thinnest extent = thickness)" -ForegroundColor White
Write-Host ""

# ============================================================================
# SHARED LIBRARY (geometry reads + orthogrid math + GUI editors + drilljig engine)
# ============================================================================
. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')
. (Join-Path $ScriptDir 'lib\orthogrid.ps1')
. (Join-Path $ScriptDir 'lib\orthogrid_points.ps1')
. (Join-Path $ScriptDir 'lib\orthogrid_gui.ps1')
. (Join-Path $ScriptDir 'lib\drilljig_core.ps1')

# ============================================================================
# STEP 0 - ORIGINAL HOLE DIAMETER (asked BEFORE the layout GUI - critical)
# ============================================================================
# The hole diameter is needed BEFORE the re-entry dialog, because the grid GUI
# insets the holes by ClearDia/2 = holeDia/2 (orthogrid_gui.ps1: "Edge is measured
# from the HOLE edge", clearDia = holeDia). The part you drilled was laid out WITH
# that inset, so slotinator MUST re-enter with the same hole diameter or every
# slot lands holeDia/2 off the real holes (trail-confirmed: slots at Z=2.0/4.0 vs
# holes at 2.375/4.375 = off by 0.375 = 0.75/2). It is ALSO the slot WIDTH.
$HoleDia = 0.0
while ($HoleDia -le 0) {
    $rawHD = Read-Host "  Original drilled hole diameter in inches (= slot width; sizes the grid inset)"
    $hv = 0.0
    if ([double]::TryParse($rawHD.Trim(), [ref]$hv) -and $hv -gt 0) { $HoleDia = $hv }
    else { Write-Host "  Enter a positive number." -ForegroundColor Yellow }
}
Write-Host "  Hole diameter: $HoleDia (drives both the grid inset and the slot width)" -ForegroundColor Green
Write-Host ""

# ============================================================================
# STEP A - RE-ENTER THE HOLE LAYOUT (grid GUI, before connecting)
# ============================================================================
# The rows/slots are computed from the holes you drilled. Reading the holes off
# the model crashes (IpfcPoint.Point), so instead you RE-ENTER the same layout in
# the grid GUI - the exact editor you used to place them - and the row slots are
# computed from those coordinates (Get-RowSlots). Pure WinForms, no Creo yet.
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "   STEP A - re-enter the hole layout (to compute the row slots)" -ForegroundColor Cyan
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "  Re-specify the SAME hole layout you drilled - each row becomes one" -ForegroundColor White
Write-Host "  slot. (The holes cannot be read off the model directly.)" -ForegroundColor White
Write-Host ""
Write-Host "  Layout type:" -ForegroundColor White
Write-Host "    [1] Orthogrid   - regular Nx x Nz grid" -ForegroundColor White
Write-Host "    [2] Custom      - arbitrary per-point X/Z layout" -ForegroundColor White
$layoutChoice = Read-Host "  Choose 1 or 2 (blank -> 1)"

$orthoGeo = $null
switch ($layoutChoice.Trim()) {
    "2" {
        Write-Host "  Opening the custom-points editor..." -ForegroundColor Cyan
        # -HoleDiameter carries the hole dia through as context; custom points are
        # entered explicitly (no inset), so it only sizes the derived plate.
        try { $orthoGeo = Show-CustomPointsDialog -HoleDiameter $HoleDia } catch { $orthoGeo = $null }
    }
    default {
        Write-Host "  Opening the orthogrid editor..." -ForegroundColor Cyan
        # -HoleDiameter is CRITICAL here: it sets ClearDia = holeDia so the grid
        # insets the holes by holeDia/2 exactly as the part was built (else the
        # slots land holeDia/2 off - the trail-confirmed offset bug).
        try { $orthoGeo = Show-OrthogridDialog -HoleDiameter $HoleDia } catch { $orthoGeo = $null }
    }
}

if ($null -eq $orthoGeo) {
    Write-Host ""
    Write-Host "  No layout entered (dialog cancelled) - cannot compute the slots. Exiting." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}
if (-not $orthoGeo.Valid -or @($orthoGeo.Points).Count -lt 1) {
    Write-Host ""
    Write-Host "  The entered layout has no valid points - cannot compute the slots. Exiting." -ForegroundColor Yellow
    exit 1
}
Write-Host ("  Layout captured: {0} hole(s), plate {1:0.###} x {2:0.###}" -f `
    @($orthoGeo.Points).Count, $orthoGeo.Width, $orthoGeo.Height) -ForegroundColor Green
Write-Host ""

# ============================================================================
# STEP B - SLOT INPUTS (before connecting)
# ============================================================================
# Slot WIDTH = the ORIGINAL hole diameter asked in STEP 0 (same value that drove
# the grid inset). Not the 1.5x relief-dia multiplier; no separate prompt.
$SlotWidth = [double]$HoleDia
Write-Host "  Slot width: $SlotWidth (= the hole diameter)" -ForegroundColor Green
Write-Host ""

# Direction of the removal path: X = the slots run along X (rows grouped by Z);
# Z = the slots run along Z (rows grouped by X). This is the ONLY row-related
# choice; the slot always spans the FULL part length along this direction.
$rowAxisChoice = Read-Host "  Direction of removal path - X (default) or Z (blank -> X)"
$RowAxis = if ($rowAxisChoice.Trim().ToUpper() -eq 'Z') { 'Z' } else { 'X' }
Write-Host "  Removal-path direction: $RowAxis" -ForegroundColor Green
Write-Host ""

# Slot LENGTH is ALWAYS the full part length along the removal-path direction
# (user 2026-07-06: not an option). SlotMargin is unused in 'full' mode but kept
# for the Get-RowSlots signature.
$LengthMode = 'full'
$SlotMargin = 0.25

# DEPTH: the cut is a BLIND extrude driven to a real depth. Depth = a % of the
# plate thickness (thickness measured live after connecting). The value is typed
# into maindashInst0.def_depth1_ip (Build-CutFinishMacro). Ask the % now.
$DepthPct = 0.20
$rawPct = Read-Host "  Slot depth as % of plate thickness (blank -> 20)"
if (-not [string]::IsNullOrWhiteSpace($rawPct)) {
    $pv = 0.0
    $clean = $rawPct.Trim().TrimEnd('%')
    if ([double]::TryParse($clean, [ref]$pv) -and $pv -gt 0 -and $pv -lt 100) { $DepthPct = $pv / 100.0 }
    else { Write-Host "  Not a percentage in (0,100) - using 20%" -ForegroundColor Yellow }
}
Write-Host ("  Slot depth: {0:P0} of plate thickness" -f $DepthPct) -ForegroundColor Green
Write-Host ""

# Up / thickness axis is ALWAYS auto (the thinnest extent = plate thickness); no
# prompt (user 2026-07-06). Measure-Extents picks it after connecting.

if ($StrictOverlap) { Write-Host "  --strict-overlap: overlapping slots will ABORT (not warn)." -ForegroundColor Yellow }
if ($FlipDir) { Write-Host "  Cut direction: --flip -> starting FLIPPED (you verify the seed and can flip back)." -ForegroundColor Yellow }
else          { Write-Host "  Cut direction: Creo's default (NOT flipped) - matches the proven hand cut. You verify the seed." -ForegroundColor DarkGray }
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
$model = $session.GetActiveModel()

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

# Initialize the shared drilljig engine so New-OffsetPlane / Build-IntersectPointMacro
# deps / Find-DefaultDatumPicks / Wait-ModelModified / Read-SelectedId / Get-BodyList
# all resolve against this session/model/type. -Log $null -> Write-Host (console).
Initialize-DrilljigCore -Session $session -Model $model -TypeObj $modelItemType -DataDir $ScriptDir -Log $null

try {

# ============================================================================
# MEASURE PLATE THICKNESS -> BLIND CUT DEPTH (= DepthPct of thickness)
# ============================================================================
# The cut is a BLIND extrude driven to this depth via def_depth1_ip. Thickness =
# the extent along the up axis (auto = thinnest). Fall back to a manual prompt if
# EvalOutline gives nothing (mirrors pocketinator / drilljig STAGE 4). If depth
# still can't be derived, $slotDepth stays 0 and Build-CutFinishMacro falls back
# to Creo's default depth (never fires a bogus 0-depth widget).
Write-Host ""
Write-Host "  Measuring the plate for the cut depth..." -ForegroundColor Cyan
$excl = New-ExcludeTypes -TypeObj $modelItemType
$ext  = Measure-Extents -Solid $model -ExcludeTypes $excl
# Up/thickness axis is ALWAYS auto = the thinnest of the three extents.
$upIndex = 2
if ($null -ne $ext) {
    Write-Host ("    extents: X=$([math]::Round($ext[0],4))  Y=$([math]::Round($ext[1],4))  Z=$([math]::Round($ext[2],4))") -ForegroundColor White
    $upIndex = 0
    if ($ext[1] -lt $ext[$upIndex]) { $upIndex = 1 }
    if ($ext[2] -lt $ext[$upIndex]) { $upIndex = 2 }
} else {
    Write-Host "    Could not measure the solid extents (EvalOutline gave nothing); defaulting thickness axis = Z." -ForegroundColor Yellow
}
$axisName  = @("X","Y","Z")[$upIndex]
$measured  = if ($null -ne $ext) { [double]$ext[$upIndex] } else { 0.0 }
# ALWAYS confirm the thickness (user 2026-07-06: "ask thickness, measured default").
# Measure-Extents' thinnest extent is only a GUESS at the plate thickness - on a
# multi-body / feature-heavy model it can return the wrong axis (live: it gave
# 0.4705 -> 20% = 0.0941, the wrong depth). So show the measured value and let the
# operator accept it with ENTER or type the real plate thickness they built.
$thickness = $measured
if ($measured -gt 0) {
    Write-Host ("  Measured plate thickness ($axisName axis) = {0}`"." -f [math]::Round($measured,4)) -ForegroundColor White
    $traw = Read-Host ("  Plate thickness in inches (ENTER to accept {0}, or type the real thickness)" -f [math]::Round($measured,4))
} else {
    Write-Host "  Could not measure plate thickness (EvalOutline gave nothing)." -ForegroundColor Yellow
    $traw = Read-Host "  Plate thickness in inches (drill-direction; blank -> Creo's default depth)"
}
if (-not [string]::IsNullOrWhiteSpace($traw)) {
    $tv = 0.0
    if ([double]::TryParse($traw.Trim(), [ref]$tv) -and $tv -gt 0) { $thickness = $tv }
    else { Write-Host ("  Not a positive number - keeping {0}." -f [math]::Round($thickness,4)) -ForegroundColor Yellow }
}
$slotDepth = if ($thickness -gt 0) { [Math]::Round($thickness * $DepthPct, 4) } else { 0.0 }
if ($slotDepth -gt 0) {
    Write-Host ("  Up/thickness axis: $axisName (~{0}`"), blind cut depth = {1:P0} = {2}`"" -f [math]::Round($thickness,4), $DepthPct, $slotDepth) -ForegroundColor Green
    if ($slotDepth -ge $thickness) { Write-Host "  WARNING: depth >= thickness - this cuts through. Reduce the %." -ForegroundColor Red }
} else {
    Write-Host "  No thickness -> the cut will use Creo's DEFAULT depth (no value typed)." -ForegroundColor Yellow
}
Write-Host ""

# ============================================================================
# COMPUTE THE ROW SLOTS (pure math on the re-entered layout)
# ============================================================================
$slotArgs = @{
    Points    = $orthoGeo.Points
    SlotWidth = $SlotWidth
    Width     = $orthoGeo.Width
    Height    = $orthoGeo.Height
    RowAxis   = $RowAxis
    LengthMode= $LengthMode
    Margin    = $SlotMargin
}
if ($StrictOverlap) { $slotArgs['StrictNoOverlap'] = $true }
$slots = Get-RowSlots @slotArgs

Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "   ROW SLOTS (one rectangular cut per row)" -ForegroundColor Cyan
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host ("    removal-path direction {0} (rows grouped by {1}), full part length, row-group tol {2:0.####}" -f `
    $slots.RowAxis, $slots.CrossAxis, $slots.RowTolEffective) -ForegroundColor DarkGray
Write-Host ("    {0} row(s) -> {0} slot(s), each {1:0.###} wide" -f $slots.Count, $slots.SlotWidth) -ForegroundColor Green
Write-Host ""
Write-Host ("    {0,4}  {1,10}  {2,14}  {3,14}  {4,5}" -f "#", "$($slots.CrossAxis)~center", "along [min,max]", "cross [lo,hi]", "holes") -ForegroundColor White
Write-Host "    ----  ----------  --------------  --------------  -----" -ForegroundColor DarkGray
$rn = 0
foreach ($row in $slots.Rows) {
    $rn++
    Write-Host ("    {0,4}  {1,10:N3}  [{2,5:N2},{3,5:N2}]  [{4,5:N2},{5,5:N2}]  {6,5}" -f `
        $rn, $row.CrossCoord, $row.AlongMin, $row.AlongMax, $row.CrossLo, $row.CrossHi, $row.HoleCount) -ForegroundColor White
}
Write-Host ""
if ($slots.Warnings -and $slots.Warnings.Count -gt 0) {
    foreach ($w in $slots.Warnings) { Write-Host "    NOTE: $w" -ForegroundColor DarkYellow }
    Write-Host ""
}
if (-not $slots.Valid) {
    Write-Host "  Cannot cut these slots:" -ForegroundColor Red
    foreach ($e in $slots.Errors) { Write-Host "    - $e" -ForegroundColor Yellow }
    throw "Invalid slot layout for the entered holes / width."
}

# --- PATTERN FEASIBILITY (informational; the hook for the future dimension pattern) ---
# A native Creo dimension pattern (draw ONE seed slot, pattern it for the rest -
# the user's ask) advances a single dimension by a CONSTANT increment, so it can
# only reproduce EVENLY-SPACED rows. Get-SlotPatternPlan decides this from the row
# cross-coordinates. The pattern MACRO itself is not wired yet (its count/increment
# widgets must be recorded live via slotpat-probe.cmd - no programmatic pattern API
# exists on this build), so today every row is still cut individually; this just
# reports whether a pattern WILL be applicable once the recipe is captured.
$patPlan = Get-SlotPatternPlan -Rows $slots.Rows
# Use the seed+pattern flow only when the rows are evenly spaced (a single-
# direction pattern can't reproduce irregular gaps) AND the operator didn't force
# per-row with --no-pattern AND there are >=2 rows (1 row = just draw it).
$usePattern = ($patPlan.CanPattern -and -not $NoPattern -and $slots.Count -ge 2)
if ($slots.Count -ge 2) {
    if ($NoPattern) {
        Write-Host ("  --no-pattern: cutting all {0} rows by hand (per-row draw)." -f $slots.Count) -ForegroundColor DarkGray
    } elseif ($patPlan.CanPattern) {
        Write-Host ("  PATTERN MODE: {0} rows evenly spaced at pitch {1:0.####} -> draw ONE seed slot, then pattern it." -f $patPlan.Count, $patPlan.Increment) -ForegroundColor Cyan
    } else {
        Write-Host ("  Rows NOT evenly spaced -> can't pattern; cutting per-row. ({0})" -f $patPlan.Reason) -ForegroundColor DarkYellow
    }
    Write-Host ""
}

# ============================================================================
# DATUM DISCOVERY + VISIBLE SLOT-EDGE PLANES (guide the manual rectangle draw)
# ============================================================================
# For each slot we create the offset PLANES at its two along-axis edges (X0/X1)
# and its two cross-axis edges (Z0/Z1), then MAKE THEM VISIBLE, so the operator
# has real datum planes to snap the drawn rectangle to. (We used to also create
# 2 corner datum POINTS per slot, but they were useless - they only lie on the
# sketch plane when the picked face is coincident with the SIDE datum, which it
# often is not - so per the user 2026-07-06 we create ONLY the planes and show
# them.) Planes are OPTIONAL: if the default datums can't be found we skip them
# and the operator draws freehand from the printed sizes. NEVER a gate.
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "   DATUM DISCOVERY + VISIBLE SLOT-EDGE PLANES" -ForegroundColor Cyan
Write-Host "  ====================================================================" -ForegroundColor Cyan
$topBaseId = $null; $sideBaseId = $null; $frontBaseId = $null
$picks = @(Find-DefaultDatumPicks)
$autoRoles = @($picks | Where-Object { $null -ne $_.Role } | Select-Object -ExpandProperty Role -Unique)
if (@($autoRoles).Count -lt 3) {
    Write-Host "  Could not auto-find all three default datums by name." -ForegroundColor Yellow
    Write-Host "  In Creo, Ctrl-click ALL THREE default datums (TOP, SIDE, FRONT) - any order -" -ForegroundColor White
    Write-Host "  then press ENTER here (or just press ENTER to skip the guide planes)." -ForegroundColor White
    Read-Host
    $picks = @(Read-SelectionPlanePicks)
}
foreach ($pk in $picks) {
    if ($null -eq $pk.Role) { continue }
    switch ($pk.Role) {
        'Top'   { if ($null -eq $topBaseId)   { $topBaseId   = [int]$pk.Id } }
        'Side'  { if ($null -eq $sideBaseId)  { $sideBaseId  = [int]$pk.Id } }
        'Front' { if ($null -eq $frontBaseId) { $frontBaseId = [int]$pk.Id } }
    }
}
# The slot rectangle spans the row (X, offset from TOP) and its width band (Z,
# offset from FRONT), so we only need the TOP + FRONT bases to build the edge
# planes. (SIDE is discovered too but not required for the planes.)
# Planes are created + shown in BOTH modes (user 2026-07-07 wants the planes):
# in per-row mode they guide every draw; in PATTERN mode the ROW-0 (seed) edge
# planes guide the seed draw and the rest show where each patterned slot lands.
$canPlanes = ($null -ne $topBaseId -and $null -ne $frontBaseId)
if ($canPlanes) {
    Write-Host "  Datums found: TOP id $topBaseId, FRONT id $frontBaseId$(if ($null -ne $sideBaseId) { ", SIDE id $sideBaseId" } else { '' })." -ForegroundColor Green
} else {
    Write-Host "  TOP/FRONT datums not both resolved - SKIPPING the guide planes." -ForegroundColor Yellow
    Write-Host "  You will draw the slot rectangle freehand (guided by the printed sizes)." -ForegroundColor Yellow
}
Write-Host ""

# --- Create the SHARED slot-edge offset planes (one per distinct X and Z edge) ---
# PATTERN MODE: only the FIRST row's edges are needed as draw guides (user 2026-07-07:
# "don't create unnecessary planes - just the first set") - the operator draws ONLY
# the seed slot (row 1) and the pattern replicates it, so planes for rows 2..N would
# never be drawn against. PER-ROW MODE: feed ALL slot corners (every row is drawn by
# hand and wants its own guides). Get-SharedPlanePlan dedups shared edges (all
# full-length slots share X0=0 / X1=Width). Each distinct X offset -> a plane from
# the TOP base; each distinct Z -> from FRONT; a ~0 offset reuses the base datum
# (point-probe trick). Then SHOW each created plane (ProCmdViewShow@PopupMenuTree,
# select-by-ID) so it is a visible reference for the draw. $createdPlaneIds tracks
# only the NEW planes to show (base-datum reuses are already visible).
$createdPlaneIds = @()
if ($canPlanes) {
    $planeCorners = if ($usePattern) { @($slots.Rows[0].Corner0, $slots.Rows[0].Corner1) } else { $slots.Corners }
    if ($usePattern) { Write-Host "  Pattern mode: creating guide planes for the FIRST row only (the seed)." -ForegroundColor DarkGray }
    $plan = Get-SharedPlanePlan -Points $planeCorners
    $tolP = 1e-6
    Write-Host ("  Creating {0} X-edge plane(s) + {1} Z-edge plane(s) (offset datums)..." -f `
        $plan.XCoords.Count, $plan.ZCoords.Count) -ForegroundColor Cyan
    foreach ($xOff in $plan.XCoords) {
        if ([math]::Abs([double]$xOff) -le $tolP) { continue }   # X=0 -> the TOP base datum (already there)
        $res = New-OffsetPlane -Label "SlotX$($createdPlaneIds.Count)" -Offset ([double]$xOff) -BaseId ([int]$topBaseId) -SkipSymbolWait
        if ($null -ne $res.FeatId) { $createdPlaneIds += [int]$res.FeatId }
        else { Write-Host "  X-edge plane at offset $xOff FAILED (continuing)." -ForegroundColor Yellow }
    }
    foreach ($zOff in $plan.ZCoords) {
        if ([math]::Abs([double]$zOff) -le $tolP) { continue }   # Z=0 -> the FRONT base datum
        $res = New-OffsetPlane -Label "SlotZ$($createdPlaneIds.Count)" -Offset ([double]$zOff) -BaseId ([int]$frontBaseId) -SkipSymbolWait
        if ($null -ne $res.FeatId) { $createdPlaneIds += [int]$res.FeatId }
        else { Write-Host "  Z-edge plane at offset $zOff FAILED (continuing)." -ForegroundColor Yellow }
    }

    # SHOW every created plane so it is a visible reference for the manual draw.
    # Recipe: select the plane BY ID (tree search) then ProCmdViewShow@PopupMenuTree
    # (proven: plane-probe.cmd + trail.txt.32:227-255).
    if ($createdPlaneIds.Count -gt 0) {
        Write-Host ("  Showing {0} new slot-edge plane(s)..." -f $createdPlaneIds.Count) -ForegroundColor Cyan
        # NOTE: $planeId, NOT $pid -- $pid is a read-only PowerShell automatic var
        # (the process ID); assigning it throws "Cannot overwrite variable PID".
        # Same trap the orthogrid_points.ps1 header documents.
        foreach ($planeId in $createdPlaneIds) {
            $showMacro = (Get-SelectByIdMacro -FeatId ([int]$planeId)) + "~ Command ``ProCmdViewShow@PopupMenuTree``;"
            try { $session.RunMacro($showMacro) } catch {
                Write-Host "    could not show plane id $planeId : $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        try { $model.Regenerate($null) } catch {}
        Write-Host ("  {0} slot-edge plane(s) created and made visible." -f $createdPlaneIds.Count) -ForegroundColor Green
    } else {
        Write-Host "  No new offset planes needed (all slot edges lie on base datums)." -ForegroundColor DarkGray
    }
    Write-Host ""
}

# ============================================================================
# STEP 1 - SKETCH PLANE = the stored SIDE plane (automatic, no pick)
# ============================================================================
# The SIDE datum was already discovered above ($sideBaseId), and the slots are
# always cut on the SIDE plane (the face the holes open onto). So we sketch on it
# automatically - no "pick the face" prompt (user 2026-07-06). Only if SIDE did
# not resolve (odd part / discovery miss) do we fall back to a manual face pick.
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "   STEP 1 - sketch plane (SIDE)" -ForegroundColor Cyan
Write-Host "  ====================================================================" -ForegroundColor Cyan
if ($null -ne $sideBaseId) {
    $sketchFaceId = [int]$sideBaseId
    Write-Host "  Sketching every slot on the stored SIDE plane (id $sketchFaceId) - no pick needed." -ForegroundColor Green
    if ($createdPlaneIds.Count -gt 0) {
        Write-Host "  (The slot-edge planes are visible in Creo as draw guides.)" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  SIDE plane was NOT discovered - pick the sketch face manually." -ForegroundColor Yellow
    Write-Host "  In Creo: CLICK the flat plate face the slots are cut from (the SIDE" -ForegroundColor White
    Write-Host "  face the holes open onto / the chip clearance should open onto), then" -ForegroundColor White
    Write-Host "  press ENTER." -ForegroundColor White
    Read-Host
    $sketchFaceId = Read-SelectedId
    if ($null -eq $sketchFaceId) {
        Write-Host "  Nothing selected - cannot open the sketch. Re-run and click the face." -ForegroundColor Yellow
        throw "No sketch face selected."
    }
    Write-Host "      sketch face feature ID = $sketchFaceId" -ForegroundColor DarkGray
}
Write-Host ""

# ============================================================================
# STEP 2 - TARGET BODY (which solid the cuts remove from)
# ============================================================================
$bodyIndex = 0
$bodyList = @(Get-BodyList)
if ($bodyList.Count -gt 1) {
    Write-Host "  ====================================================================" -ForegroundColor Cyan
    Write-Host "   STEP 2 - which body do the slots cut from?" -ForegroundColor Cyan
    Write-Host "  ====================================================================" -ForegroundColor Cyan
    Write-Host "  $($bodyList.Count) solid bodies found. The cuts remove from ONE body." -ForegroundColor White
    foreach ($b in $bodyList) {
        Write-Host ("    [{0}]  {1}" -f $b.Index, $b.Name) -ForegroundColor White
    }
    $braw = Read-Host "  Body index (blank -> 0)"
    if (-not [string]::IsNullOrWhiteSpace($braw)) {
        $bi = 0
        if ([int]::TryParse($braw.Trim(), [ref]$bi) -and $bi -ge 0 -and $bi -lt $bodyList.Count) { $bodyIndex = $bi }
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
$depthNote = if ($slotDepth -gt 0) { "blind depth $slotDepth`"" } else { "Creo default depth" }
if ($usePattern) {
    Write-Host ("  Draw ONE seed slot ({0:0.###} wide, {1}), then PATTERN it to {2} rows at pitch {3:0.####} along {4}, body index {5}." -f `
        $slots.SlotWidth, $depthNote, $patPlan.Count, $patPlan.Increment, $slots.CrossAxis, $bodyIndex) -ForegroundColor White
} else {
    Write-Host ("  {0} slot(s), each {1:0.###} wide, {2}, body index {3}." -f `
        $slots.Count, $slots.SlotWidth, $depthNote, $bodyIndex) -ForegroundColor White
}
Write-Host "  This removes $($slots.Count) full-length rectangle(s) of plate material -" -ForegroundColor Yellow
Write-Host "  structurally more aggressive than discrete relief holes. No Blue Origin" -ForegroundColor Yellow
Write-Host "  standard found authorizing connected chip cavities - verify intended." -ForegroundColor Yellow
Write-Host ""
$go = Read-Host "  Proceed? (y/N)"
if ($go -notmatch '^[Yy]$') {
    Write-Host "  Cancelled - no slots created." -ForegroundColor Yellow
} elseif ($usePattern) {

    # ========================================================================
    # PATTERN FLOW - draw ONE seed slot, then pattern it to the other rows
    # ========================================================================
    # The user's ask: draw one slot, pattern the rest (no drawing over and over).
    # Uses the recorded single-direction pattern builders (Build-PatternArm/Values/
    # Confirm -> ProCmdGeomPattern + ui_pat_dir_* widgets, transcribed from the
    # 2026-06-24 recording). The two-direction "L-bug" that abandoned the point-grid
    # pattern does NOT apply (one direction; the operator picks the reference). NOT
    # yet confirmed live in this integration -> canary-gated; the seed slot survives
    # if the pattern doesn't take, and --no-pattern falls back to per-row.
    $seedRow = $slots.Rows[0]

    # --- SEED: open + draw + fire, then VERIFY direction/depth with the operator ---
    # (user 2026-07-06: "keep auto-SIDE, verify seed"). The helper learns the
    # confirmed flip and returns the seed feature id to pattern from.
    $seed = Invoke-VerifiedSeedCut -FaceId $sketchFaceId -Depth $slotDepth -BodyIndex $bodyIndex `
        -Flip $FlipDir -RowLabel "row 1 (seed)" -DrawInfo @{
            SlotLen    = $seedRow.SlotLen
            RowAxis    = $slots.RowAxis
            SlotWidth  = $slots.SlotWidth
            CrossAxis  = $slots.CrossAxis
            CrossCoord = $seedRow.CrossCoord
            HasPlanes  = ($createdPlaneIds.Count -gt 0)
        }

    if (-not $seed.Ok) {
        Write-Host ""
        Write-Host "  ABORT: the SEED slot was not confirmed - not patterning." -ForegroundColor Red
        Write-Host "  Inspect Creo. Nothing force-committed beyond the seed attempt(s)." -ForegroundColor Yellow
    } else {
        $confirmedFlip = $seed.Flip           # reuse for the pattern / any fallback
        $seedFeatId    = $seed.FeatId
        $afterFeat     = Get-FeatureIdSet      # baseline for the pattern new-count diff

        # Auto-identifying the seed feature id is now only for the post-pattern
        # count report - the operator selects the seed MANUALLY below, so a null id
        # does NOT block patterning (that was the old, too-strict guard).
        if ($null -ne $seedFeatId) { Write-Host ("  Seed cut feature id = {0} (for the count report)." -f $seedFeatId) -ForegroundColor DarkGray }
        else { Write-Host "  (Seed feature id not auto-identified; the post-pattern count is best-effort.)" -ForegroundColor DarkGray }

        # --- The pattern DIRECTION reference = a base DATUM PLANE, fed BY ID ---
        # THE LIVE FAILURE (trail.txt.33): the operator picked a CURVED EDGE for the
        # pattern direction; Creo rejected it (the prompt "Define the first direction.
        # Select a Plane, Flat Face, Linear Curve..." kept repeating) and the pattern
        # was cancelled. A datum PLANE is ALWAYS a valid direction reference (its
        # normal IS the direction), and slotinator already knows the base datum ids -
        # so feed the right one BY ID into the ui_pat_dir_dir1 collector (surfenator's
        # proven open-collector feed via Get-SelectDatumByIdMacro), NO pick. Copies
        # march along the datum normal:
        #   CrossAxis Z (rows run along X) -> FRONT datum (normal Z)
        #   CrossAxis X (rows run along Z) -> TOP  datum (normal X)
        $dirDatumId   = if ($slots.CrossAxis -eq 'Z') { $frontBaseId } else { $topBaseId }
        $dirDatumName = if ($slots.CrossAxis -eq 'Z') { 'FRONT' } else { 'TOP' }

        # --- SELECT the seed slot in the model tree (recording-faithful) ---
        # The pattern replicates the SELECTED feature; a search-dialog buffer select
        # does NOT register as the pattern target on this build (user 2026-07-07), so
        # the operator clicks the seed once - exactly what the mapkey's
        # `~ Select PHTLeft.AssyTree` does.
        Write-Host ""
        Write-Host "  SELECT THE SEED SLOT CUT in Creo's model tree (the remove-material extrude you" -ForegroundColor Magenta
        Write-Host "  just verified - NOT a base or copy-geometry feature), then press ENTER." -ForegroundColor Magenta
        Read-Host
        $selSeed = Read-SelectedId
        $patChanged = $false
        if ($null -eq $selSeed) {
            Write-Host "  Nothing selected - cannot pattern. The seed slot IS cut; re-run with --no-pattern" -ForegroundColor Yellow
            Write-Host "  to cut the rest per-row, or finish the pattern by hand in Creo." -ForegroundColor Yellow
        } elseif ($null -eq $dirDatumId) {
            Write-Host "  Cannot pattern: the $dirDatumName datum (the pattern direction) was not discovered." -ForegroundColor Yellow
            Write-Host "  Re-run with --no-pattern to cut per-row, or pattern by hand in Creo." -ForegroundColor Yellow
        } else {
            Write-Host ("  Seed selected (id {0}). Patterning {1} copies at pitch {2:0.####} along {3}," -f `
                $selSeed, $patPlan.Count, $patPlan.Increment, $slots.CrossAxis) -ForegroundColor Cyan
            Write-Host "  direction = the $dirDatumName datum plane (fed by ID - no pick)..." -ForegroundColor Cyan
            # ONE atomic RunMacro (NO pick, so nothing is split - boxinator rule):
            # open pattern on the selected seed -> activate the dir-1 collector -> feed
            # the datum plane BY ID -> set count + spacing (+ optional flip) -> confirm.
            $stamp2 = $null; try { $stamp2 = $model.VersionStamp } catch {}
            try {
                $patMacro = Build-SlotPatternMacro -DirDatumId ([int]$dirDatumId) -Count ([int]$patPlan.Count) -Spacing ([double]$patPlan.Increment) -Flip:$PatternFlip
                $session.RunMacro($patMacro)
                if ($null -ne $stamp2) { $patChanged = Wait-ModelModified -Model $model -PreviousStamp $stamp2 -TimeoutMs 30000 }
            } catch { Write-Host "    pattern macro error: $($_.Exception.Message)" -ForegroundColor Red }
        }

        $afterPat = Get-FeatureIdSet
        $patNew = @($afterPat.Keys | Where-Object { -not $afterFeat.ContainsKey($_) }).Count

        Write-Host ""
        Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
        if ($patChanged) {
            Write-Host ("  Done - seed slot patterned. Model changed; {0} new feature id(s) (expected ~{1})." -f $patNew, ($patPlan.Count - 1)) -ForegroundColor Green
            Write-Host "  NOTE: verification is a VersionStamp change, NOT a geometric count. Verify in Creo:" -ForegroundColor DarkGray
            Write-Host ("   - {0} slots total, one per row, evenly spaced at {1:0.####}," -f $patPlan.Count, $patPlan.Increment) -ForegroundColor DarkGray
            Write-Host "   - each lands on its hole row, correct width + depth + face." -ForegroundColor DarkGray
            Write-Host "  If the copies marched the WRONG way (off the plate), re-run with --pattern-flip." -ForegroundColor DarkGray
        } else {
            Write-Host "  The pattern did NOT change the model." -ForegroundColor Red
            Write-Host "  The seed slot IS cut. The direction-datum feed may not have registered on this" -ForegroundColor Yellow
            Write-Host "  build. Inspect Creo; finish the pattern by hand (pick the $dirDatumName datum" -ForegroundColor Yellow
            Write-Host "  PLANE as the direction - NOT an edge), or re-run with --no-pattern to cut per-row." -ForegroundColor Yellow
        }
    }

} else {

    # ========================================================================
    # PER-ROW LOOP - one slot per row, auto-looped
    # ========================================================================
    $madeRows = 0; $noopRows = 0; $failRows = 0; $aborted = $false
    # Row 1 is a VERIFIED seed (user 2026-07-06: "verify seed") - the operator
    # confirms the cut direction/depth once, and the confirmed flip is reused for
    # rows 2..N (no re-verify per row). $confirmedFlip starts at the CLI default.
    $confirmedFlip = $FlipDir
    $rowNum = 0
    foreach ($row in $slots.Rows) {
        $rowNum++
        Write-Host ""
        Write-Host "  --------------------------------------------------------------------" -ForegroundColor Cyan
        Write-Host ("   ROW $rowNum of $($slots.Count)  ($($slots.CrossAxis)~{0:0.###}, {1} hole(s))" -f $row.CrossCoord, $row.HoleCount) -ForegroundColor Cyan
        Write-Host "  --------------------------------------------------------------------" -ForegroundColor Cyan

        # (No datum points are created - the visible slot-edge offset planes made
        # up front are the draw guides. User 2026-07-06: the corner points were
        # useless, planes only.)

        if ($rowNum -eq 1) {
            # --- ROW 1 = VERIFIED SEED: open + draw + fire, then confirm direction/
            #     depth; learn the flip to reuse for every remaining row. ---
            $seed = Invoke-VerifiedSeedCut -FaceId $sketchFaceId -Depth $slotDepth -BodyIndex $bodyIndex `
                -Flip $confirmedFlip -RowLabel "row 1 (seed)" -DrawInfo @{
                    SlotLen    = $row.SlotLen
                    RowAxis    = $slots.RowAxis
                    SlotWidth  = $slots.SlotWidth
                    CrossAxis  = $slots.CrossAxis
                    CrossCoord = $row.CrossCoord
                    HasPlanes  = ($createdPlaneIds.Count -gt 0)
                }
            if ($seed.Ok) {
                $madeRows++
                $confirmedFlip = $seed.Flip
            } else {
                # ROW-1 canary: seed not confirmed -> the recipe is broken (widget
                # drift / wrong face / wrong body) or the operator gave up. Abort
                # before drawing N-1 more; nothing force-committed beyond the seed.
                Write-Host ""
                Write-Host "  ABORT: the FIRST (seed) slot was not confirmed. Inspect Creo; stopping." -ForegroundColor Red
                $aborted = $true
                break
            }
            continue
        }

        # --- ROWS 2..N: reuse the confirmed flip; no per-row direction check ---
        # MACRO A: select-by-ID first (its buffer_clean leaves ONLY the face), then
        # the extrude consumes it as the sketch plane, orient, arm the rectangle.
        $mkOpen =
            (Get-SelectByIdMacro -FeatId $sketchFaceId) +
            "~ Command ``ProCmdFtExtrude``;" +
            "~ Command ``ProCmdViewSketchView``;" +
            "~ Command ``ProCmdSketRectangle`` 1;"
        Write-Host ("    Opening the sketch on face id {0} (rectangle tool armed)..." -f $sketchFaceId) -ForegroundColor Cyan
        try { $session.RunMacro($mkOpen) } catch {
            Write-Host "    Could not open the extrude/sketch: $($_.Exception.Message)" -ForegroundColor Red
            $failRows++
            continue
        }

        # --- THE ONE MANUAL STEP: draw the rectangle around this row's holes ---
        Write-Host ""
        Write-Host "    MANUAL STEP - draw this row's slot rectangle around its holes:" -ForegroundColor Magenta
        Write-Host ("      target: {0:0.###} long (along {1}) x {2:0.###} wide (along {3})" -f `
            $row.SlotLen, $slots.RowAxis, $slots.SlotWidth, $slots.CrossAxis) -ForegroundColor White
        Write-Host ("      corners: ({0:0.##},{1:0.##}) and ({2:0.##},{3:0.##}) in the X/Z plate frame." -f `
            $row.Corner0.X, $row.Corner0.Z, $row.Corner1.X, $row.Corner1.Z) -ForegroundColor White
        if ($createdPlaneIds.Count -gt 0) {
            Write-Host "      To snap the slot in place: hold CTRL + ALT, then click the two planes spanning" -ForegroundColor White
            Write-Host "      across the LENGTH of the part (X direction) and the RIGHT-SIDE EDGE of the jig." -ForegroundColor White
            Write-Host "      Dotted blue lines should form the rectangle; then snap each rectangle corner to it." -ForegroundColor White
        }
        Write-Host "      Click one corner, then the opposite corner (ONE closed rectangle)." -ForegroundColor White
        Write-Host "      Then press Esc to drop the rectangle tool (leave the rectangle drawn)." -ForegroundColor White
        Write-Host "    Leave the sketch OPEN (the script finishes it). Press ENTER when drawn." -ForegroundColor Yellow
        Read-Host

        # --- MACRO B: finish sketch + depth + remove-material + body + confirm ---
        # uses $confirmedFlip (the direction the operator OK'd on the seed).
        $stamp = $null
        try { $stamp = $model.VersionStamp } catch {}
        $changed = $false
        try {
            $macro = Build-CutFinishMacro -Depth $slotDepth -BodyIndex $bodyIndex -Flip $confirmedFlip
            $session.RunMacro($macro)
            if ($null -ne $stamp) { $changed = Wait-ModelModified -Model $model -PreviousStamp $stamp -TimeoutMs 30000 }
        } catch {
            Write-Host "    Macro error firing the cut: $($_.Exception.Message)" -ForegroundColor Red
        }

        if ($changed) {
            $madeRows++
            Write-Host "    Slot cut (model changed)." -ForegroundColor Green
        } else {
            $noopRows++
            Write-Host "    The model did NOT change - this slot did not commit." -ForegroundColor Yellow
        }
    }

    # ========================================================================
    # HONEST REPORT
    # ========================================================================
    Write-Host ""
    Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
    Write-Host ("  Rows (slots)      : {0}" -f $slots.Count) -ForegroundColor White
    Write-Host ("  Model changed     : {0}" -f $madeRows) -ForegroundColor White
    if ($noopRows -gt 0) { Write-Host ("  No-op (no change) : {0}" -f $noopRows) -ForegroundColor Yellow }
    if ($failRows -gt 0) { Write-Host ("  Macro errors      : {0}" -f $failRows) -ForegroundColor Yellow }
    if ($createdPlaneIds.Count -gt 0) { Write-Host ("  Slot-edge planes  : {0} created + shown" -f $createdPlaneIds.Count) -ForegroundColor DarkGray }
    Write-Host ""
    if ($aborted) {
        Write-Host "  STOPPED after the row-1 canary - inspect the model in Creo." -ForegroundColor Red
    } elseif ($madeRows -eq $slots.Count -and $failRows -eq 0 -and $noopRows -eq 0) {
        Write-Host "  Done - all $madeRows slot(s) cut (model changed for each)." -ForegroundColor Green
        Write-Host "  NOTE: verification is a VersionStamp change, NOT a geometric measure." -ForegroundColor DarkGray
        Write-Host "  Verify each slot visually: spans its row, width ~ the hole dia, on the" -ForegroundColor DarkGray
        Write-Host "  correct (chip-clearance) face, a supporting land remains between rows." -ForegroundColor DarkGray
    } elseif ($madeRows -gt 0) {
        Write-Host "  Finished with issues - $madeRows of $($slots.Count) slot(s) changed the model. Inspect Creo." -ForegroundColor Yellow
    } else {
        Write-Host "  No slots were cut - inspect Creo (the recipe may need a widget refresh)." -ForegroundColor Red
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
