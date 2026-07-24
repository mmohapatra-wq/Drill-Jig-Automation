<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "SLOTPLANE-PROBE (READ-ONLY)"
$ErrorActionPreference = "Stop"

# ============================================================================
# SLOTPLANE-PROBE  -- an OBSERVATIONAL probe (creates NOTHING it does not undo)
# ============================================================================
# QUESTION IT ANSWERS: can a sketch be opened on a datum PLANE fed BY ID (no
# screen pick), so the per-hole CURVED slot loop can arm the seed-rectangle
# sketch HANDS-FREE?
#
# WHY IT MATTERS: the curved (conformal) drill jig's slot-relief step wants to
# draw ONE rectangle on an offset plane at one hole and replicate it at every
# hole (user's architecture step 4). The planes that locate the holes already
# exist -- so IF the sketcher can be opened on a plane by feeding its feature
# ID (the way surfenator/plane-probe feed a datum plane into an open dashboard
# collector), the seed sketch can be armed with no operator pick. If it CANNOT,
# the per-hole slot loop must fall back to a screen-pick of the sketch plane.
#
# THE OPEN QUESTION (from CLAUDE.md "Open sketcher on a plane (confirmed)"):
#   ~ Command `ProCmdDatumSketCurve`;
#   @PAUSE_FOR_SCREEN_PICK                    <- user picks sketch plane HERE
#   ~ Trigger `Odui_Dlg_00` `t1.PlnMru` `0`;  <- select plane from MRU
#   ~ Trigger `Odui_Dlg_00` `t1.PlnMru` ``;
#   ~ Trigger `Odui_Dlg_00` `t1.RefMru` `0`;  <- select orientation ref from MRU
#   ~ Trigger `Odui_Dlg_00` `t1.RefMru` ``;
#   ~ Activate `Odui_Dlg_00` `stdbtn_1`;      <- enter sketcher
# The confirmed recipe RELIES on a manual plane click to populate the dialog's
# plane MRU. This probe tests whether a Datum-type tree-search select-by-ID
# BEFORE ProCmdDatumSketCurve replaces that pick -- i.e. whether the buffered
# plane loads into t1.PlnMru so t1.PlnMru `0` selects it.
#
# HOW IT STAYS SAFE (mirrors pointref-probe / fastener-probe):
#   * It fires ONE atomic arm macro (select plane by ID + open sketcher).
#   * It creates NOTHING. If the sketcher opens, it immediately fires
#     ProCmdSketDone (and a dashboard Quit as a belt-and-suspenders) so no
#     sketch is committed.
#   * It ASKS the operator (Read-Host) what actually happened -- opened /
#     did-not / partially, and whether a plane was pre-loaded -- because plane
#     normals / dialog state are not reliably readable here.
#   * visible_mapkeys is turned ON so the run is captured in the trail for
#     later transcription (restored in finally).
#   * Findings are written to slotplane_probe_report.txt (gitignored).
#
# PREREQ: open a PART (.prt) that has at least one datum PLANE. ONE Creo
# session. This probe does not need holes or slots -- any datum plane will do.
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

# Read the (last) selected feature ID from Creo's selection buffer, or $null.
function Read-SelectedId {
    $contents = ($session.CurrentSelectionBuffer()).Contents
    if ($null -eq $contents -or $contents.Count -eq 0) { return $null }
    try { return [int]$contents[$contents.Count - 1].SelItem.Id } catch { return $null }
}

# Find the NEWEST trail file (working_folder\trail\trail.txt.N). Same search as
# slotpat-probe: a few likely roots, take the most-recently-modified. $null if none.
function Find-NewestTrail {
    $roots = @(
        (Join-Path $env:USERPROFILE 'working_folder\trail'),
        (Join-Path $env:USERPROFILE 'working_folder'),
        $env:USERPROFILE
    )
    $newest = $null
    foreach ($r in $roots) {
        if (-not (Test-Path $r)) { continue }
        $f = Get-ChildItem -Path $r -Filter 'trail.txt.*' -File -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -ne $f) {
            if ($null -eq $newest -or $f.LastWriteTime -gt $newest.LastWriteTime) { $newest = $f }
        }
    }
    return $newest
}

# ============================================
# HEADER
# ============================================
Write-Host ""
Write-Host "  SLOTPLANE-PROBE (READ-ONLY) -- does a sketch open on a plane fed BY ID?" -ForegroundColor Cyan
Write-Host "  Fires ONE arm macro, asks you what happened, commits nothing." -ForegroundColor DarkGray
Write-Host ""

# ============================================
# SHARED LIBRARY (geometry reads + drilljig engine for the by-ID datum macro)
# ============================================
. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')
. (Join-Path $ScriptDir 'lib\drilljig_core.ps1')

# ============================================
# CONNECT (single session, .prt guard)
# ============================================
$procs = @(Get-Process -Name xtop -ErrorAction SilentlyContinue)
if ($procs.Count -eq 0) { throw "Creo (xtop.exe) is not running" }
if ($procs.Count -gt 1) {
    throw "More than one Creo session is open. This probe expects exactly ONE."
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
$model      = $null
try { $model = $session.GetActiveModel() } catch {}
if ($null -eq $model) { try { $model = $session.CurrentModel } catch {} }
if ($null -eq $model) { throw "No active model. Open a PART with at least one datum plane." }

$fname = try { [string]$model.FileName } catch { "" }
if ($fname -match '(?i)\.asm(\.\d+)?$') {
    throw "Active model is an assembly ($fname). Open the PART (.prt)."
}
Write-Host "  Connected. Active model: $fname" -ForegroundColor Green
Write-Host ""

# Type object + init the shared engine so Get-SelectDatumByIdMacro resolves the
# same way it does in slotinator/drilljig. -Log $null -> Write-Host (console).
$modelItemType = New-Object -ComObject pfcls.pfcModelItemType
Initialize-DrilljigCore -Session $session -Model $model -TypeObj $modelItemType -DataDir $ScriptDir -Log $null

# ENABLE visible_mapkeys so the whole run is echoed into the trail (capture +
# restore the original in finally). We WANT the recording here.
$origVisibleMapkeys = $null
try {
    $vals = $session.GetConfigOptionValues("visible_mapkeys")
    if ($null -ne $vals -and $vals.Count -gt 0) { $origVisibleMapkeys = $vals.Item(0) }
} catch {}
try { $session.SetConfigOption("visible_mapkeys", "yes") | Out-Null } catch {}

# Collected for the report.
$planeId      = 0
$planeSource  = ""
$openedAnswer = ""
$preloadAnswer = ""
$reportFile   = Join-Path $ScriptDir 'slotplane_probe_report.txt'

try {

# ============================================
# 1. MARK THE TRAIL (before) + CAPTURE THE TARGET PLANE ID
# ============================================
$trail = Find-NewestTrail
$beforeLines = 0
if ($null -ne $trail) {
    try { $beforeLines = (Get-Content -LiteralPath $trail.FullName | Measure-Object -Line).Lines } catch {}
    Write-Host ("  Trail file: {0}" -f $trail.FullName) -ForegroundColor DarkGray
    Write-Host ("  Trail is at {0} lines now (the 'before' mark)." -f $beforeLines) -ForegroundColor DarkGray
} else {
    Write-Host "  Could not locate a trail file automatically -- the run is still recorded in" -ForegroundColor Yellow
    Write-Host "  working_folder\trail\trail.txt.<newest> if you need the raw widget lines." -ForegroundColor Yellow
}
Write-Host ""

Write-Host "  Pick the datum plane to test the sketch-open on. Either:" -ForegroundColor Cyan
Write-Host "    * SELECT one datum plane in Creo (model tree or graphics), then press ENTER; or" -ForegroundColor Cyan
Write-Host "    * press ENTER with NOTHING selected and type the plane's feature ID." -ForegroundColor Cyan
Read-Host
$planeId = Read-SelectedId
if ($null -ne $planeId -and $planeId -gt 0) {
    $planeSource = "selection buffer"
    Write-Host "  Using SELECTED plane feature ID = $planeId" -ForegroundColor White
} else {
    $typed = Read-Host "  Nothing selected. Type the datum plane feature ID"
    $parsed = 0
    if (-not [int]::TryParse(($typed).Trim(), [ref]$parsed) -or $parsed -le 0) {
        throw "No plane selected and no valid feature ID typed."
    }
    $planeId = $parsed
    $planeSource = "typed ID"
    Write-Host "  Using TYPED plane feature ID = $planeId" -ForegroundColor White
}
Write-Host ""

# ============================================
# 2. FIRE ONE ATOMIC ARM MACRO:
#    (a) select the plane BY ID (Datum-type tree search, from drilljig_core), then
#    (b) open the sketcher on it (the confirmed recipe, minus @PAUSE_FOR_SCREEN_PICK
#        -- the whole point is to see whether the by-ID feed replaces that pick).
# ============================================
# Get-SelectDatumByIdMacro selects a DATUM PLANE by ID (surfenator's proven feed).
# It carries NO leading buffer_clean, so we prepend one to start from a clean
# buffer (this is a fresh selection, not feeding an already-open collector).
$armMacro =
    "~ Activate ``main_dlg_cur`` ``buffer_clean``;" +
    (Get-SelectDatumByIdMacro -FeatId $planeId) +
    "~ Command ``ProCmdDatumSketCurve``;" +
    "~ Trigger ``Odui_Dlg_00`` ``t1.PlnMru`` ``0``;" +
    "~ Trigger ``Odui_Dlg_00`` ``t1.PlnMru`` ````;" +
    "~ Trigger ``Odui_Dlg_00`` ``t1.RefMru`` ``0``;" +
    "~ Trigger ``Odui_Dlg_00`` ``t1.RefMru`` ````;" +
    "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;"

Write-Host "  Firing the arm macro (select plane by ID + open sketcher)..." -ForegroundColor Cyan
Invoke-Macro "select datum plane $planeId by ID + ProCmdDatumSketCurve + enter sketcher" $armMacro
Write-Host ""

# ============================================
# 3. ASK THE OPERATOR WHAT ACTUALLY HAPPENED (dialog state is not reliably read here)
# ============================================
Write-Host "  ============================================================" -ForegroundColor Magenta
Write-Host "  LOOK AT CREO NOW -- WHAT HAPPENED?" -ForegroundColor Magenta
Write-Host "  ============================================================" -ForegroundColor Magenta
Write-Host "    * Did the SKETCHER open (you are now in 2D sketch mode on a plane)?" -ForegroundColor White
Write-Host "    * OR is the sketch-plane dialog (Odui_Dlg_00) still open waiting for a pick?" -ForegroundColor White
Write-Host "    * OR did nothing happen / an error dialog appear?" -ForegroundColor White
Write-Host ""

$openedAnswer = Read-Host "  Did the sketcher OPEN on the intended plane? (Y = yes / N = no / P = partially)"
$openedAnswer = ($openedAnswer).Trim().ToUpper()

$preloadAnswer = Read-Host "  Was a plane PRE-LOADED into the dialog / did it use the plane you fed by ID? (Y/N/UNSURE)"
$preloadAnswer = ($preloadAnswer).Trim().ToUpper()

$notes = Read-Host "  Any extra notes (dialog name, prompt text, error)? (optional, ENTER to skip)"

# ============================================
# 4. IF THE SKETCHER OPENED, GET OUT WITHOUT COMMITTING ANYTHING
# ============================================
if ($openedAnswer -eq 'Y' -or $openedAnswer -eq 'P') {
    Write-Host ""
    Write-Host "  Exiting the sketcher WITHOUT committing (ProCmdSketDone + dashboard Quit)..." -ForegroundColor Cyan
    # ProCmdSketDone finishes the (empty) sketch; the datum-curve dashboard is then
    # cancelled so no curve feature is created. Both fired best-effort -- if one is
    # a no-op for the current state Creo simply ignores it. Belt-and-suspenders:
    # if a dialog is still open the operator can cancel it by hand (we created no
    # geometry regardless -- an empty sketch commits nothing).
    Invoke-Macro "exit sketcher (ProCmdSketDone)" "~ Command ``ProCmdSketDone``;"
    Invoke-Macro "cancel datum-curve dashboard (Quit)" "~ Activate ``main_dlg_cur`` ``dashInst0.Quit``;"
    Write-Host ""
    Write-Host "  If any dialog is STILL open in Creo, cancel it by hand -- this probe drew" -ForegroundColor DarkGray
    Write-Host "  no geometry, so nothing was committed." -ForegroundColor DarkGray
} else {
    Write-Host ""
    Write-Host "  Sketcher did not open. If the plane dialog (Odui_Dlg_00) is still up, cancel" -ForegroundColor DarkGray
    Write-Host "  it by hand. Nothing was committed." -ForegroundColor DarkGray
}
Write-Host ""

# ============================================
# 5. CAPTURE THE TRAIL WIDGET LINES (for transcription) + BUILD THE VERDICT
# ============================================
$captured = @()
if ($null -ne $trail) {
    $trailNow = Find-NewestTrail
    $allNew = @()
    if ($null -ne $trailNow -and $trailNow.FullName -eq $trail.FullName) {
        try { $allNew = @(Get-Content -LiteralPath $trailNow.FullName | Select-Object -Skip $beforeLines) } catch {}
    } elseif ($null -ne $trailNow) {
        Write-Host ("  (Creo rolled to a new trail: {0})" -f $trailNow.FullName) -ForegroundColor DarkGray
        try { $allNew = @(Get-Content -LiteralPath $trailNow.FullName) } catch {}
    }
    $captured = @($allNew | Where-Object {
        $_ -match '^\s*~\s*(Command|Open|Close|Select|Update|Input|Activate|Trigger|FocusOut|FocusIn|Enter|Exit)\b' -or
        $_ -match '^\s*!%CP'
    })
}

# Verdict from the operator's answers.
$verdict = ""
$falls_back = $false
if ($openedAnswer -eq 'Y' -and ($preloadAnswer -eq 'Y')) {
    $verdict = "BY-ID FEED WORKS: the sketcher opened on the plane fed by ID (no screen pick). " +
               "The per-hole curved slot loop CAN arm the seed sketch hands-free."
} elseif ($openedAnswer -eq 'Y') {
    $verdict = "SKETCHER OPENED, but the operator was unsure whether the by-ID plane was used " +
               "(pre-load answer '$preloadAnswer'). Confirm which plane it opened on before " +
               "relying on the hands-free arm; re-run and verify the plane is the intended one."
} elseif ($openedAnswer -eq 'P') {
    $verdict = "PARTIAL: something opened but not cleanly on the intended plane. Treat the " +
               "by-ID feed as UNPROVEN -- the per-hole slot loop should fall back to a screen-pick."
    $falls_back = $true
} else {
    $verdict = "BY-ID FEED DID NOT OPEN THE SKETCH. The confirmed sketcher-open recipe needs the " +
               "manual plane click (@PAUSE_FOR_SCREEN_PICK) to populate t1.PlnMru; feeding the " +
               "plane by ID did not replace it. The per-hole curved slot loop MUST fall back to a " +
               "SCREEN-PICK of the sketch plane."
    $falls_back = $true
}

# ============================================
# 6. WRITE THE REPORT
# ============================================
$lines = @()
$lines += "SLOTPLANE-PROBE REPORT"
$lines += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$lines += "Model:     $fname"
$lines += ""
$lines += "QUESTION: can a sketch be opened on a datum PLANE fed BY ID (no screen"
$lines += "pick), so the per-hole curved slot loop can arm the seed-rectangle sketch"
$lines += "hands-free?"
$lines += ""
$lines += "INPUT"
$lines += "  Plane feature ID : $planeId  (source: $planeSource)"
$lines += ""
$lines += "ARM MACRO FIRED (one atomic RunMacro):"
$lines += "  buffer_clean + Get-SelectDatumByIdMacro($planeId) + ProCmdDatumSketCurve"
$lines += "  + t1.PlnMru/t1.RefMru triggers + stdbtn_1 (enter sketcher)."
$lines += "  NOTE: the @PAUSE_FOR_SCREEN_PICK from the confirmed recipe was DELIBERATELY"
$lines += "  OMITTED -- this probe tests whether the by-ID feed replaces it."
$lines += "  Macro failures during run: $script:macroFailures"
$lines += ""
$lines += "OPERATOR ANSWERS"
$lines += "  Sketcher opened on intended plane? : $openedAnswer   (Y/N/P)"
$lines += "  Plane pre-loaded / by-ID plane used?: $preloadAnswer   (Y/N/UNSURE)"
if ($notes) { $lines += "  Notes                              : $notes" }
$lines += ""
$lines += "VERDICT"
$lines += "  $verdict"
$lines += ""
if ($falls_back) {
    $lines += "IMPLICATION FOR THE CURVED SLOT LOOP:"
    $lines += "  The per-hole slot loop must FALL BACK to a SCREEN-PICK of the sketch plane"
    $lines += "  (arm ProCmdDatumSketCurve, PAUSE for the operator to click the plane, then"
    $lines += "  finish) -- exactly as boxinator splits its sketch open around the manual pick."
} else {
    $lines += "IMPLICATION FOR THE CURVED SLOT LOOP:"
    $lines += "  The seed sketch can be armed hands-free by selecting the host plane by ID"
    $lines += "  before ProCmdDatumSketCurve. Transcribe the exact widget lines below into"
    $lines += "  the slot loop and re-verify on a second plane before wiring it in."
}
$lines += ""
$lines += "RECORDED TRAIL WIDGET LINES (for transcription; visible_mapkeys was ON):"
if ($captured.Count -gt 0) {
    foreach ($ln in $captured) { $lines += "  $ln" }
} else {
    $lines += "  (none captured automatically -- read working_folder\trail\trail.txt.<newest>"
    $lines += "   from the 'before' mark and copy the ~ Command / ~ Trigger / ~ Activate lines"
    $lines += "   of the ProCmdDatumSketCurve session.)"
}

# Echo the verdict + trail lines to the console.
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "  VERDICT" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host ("  {0}" -f $verdict) -ForegroundColor White
Write-Host ""
if ($captured.Count -gt 0) {
    Write-Host "  Recorded trail widget lines:" -ForegroundColor DarkGray
    foreach ($ln in $captured) { Write-Host "    $ln" -ForegroundColor Gray }
    Write-Host ""
}

try {
    $lines | Set-Content -LiteralPath $reportFile -Encoding UTF8
    Write-Host ("  Report written to: {0}" -f $reportFile) -ForegroundColor Green
    Write-Host "  (add slotplane_probe_report.txt to .gitignore -- probe reports are not committed)" -ForegroundColor DarkGray
} catch {
    Write-Host "  (could not write $reportFile : $($_.Exception.Message))" -ForegroundColor Yellow
}

if ($script:macroFailures -gt 0) {
    Write-Host ""
    Write-Host "  ($script:macroFailures macro failure(s) fired -- see red lines above.)" -ForegroundColor Yellow
}

} finally {
    try { if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null } } catch {}
    try { $connection.Disconnect($null) } catch {}
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}

Write-Host ""
Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
