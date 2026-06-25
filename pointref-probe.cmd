<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "POINTREF-PROBE"
$ErrorActionPreference = "Stop"

# ============================================================================
# POINTREF-PROBE  (plane-probe-v2 branch -- EXPERIMENT, observational, creates
# NOTHING)
# ============================================================================
# ONE question, answered live: does ProCmdDatumPointGeneral CONSUME datum-plane
# references fed BY ID (pre-selected into the selection buffer), the way
# ProCmdDatumPlane consumes one buffered ref? If YES, an offset-from-3-planes
# datum point is fully scriptable (feed 3 planes by ID, type 3 offsets, OK) with
# no screen picks. If NO, point creation stays pick-bound (the holeinator wall)
# and we pivot. We do NOT guess offset-value widgets until this is settled.
#
# WHY this matters: the Creo trail shows every datum point you make is placed by
# CLICKING reference geometry (surface + edges) -- mouse picks a RunMacro cannot
# replay. The only escape is if the point tool accepts references fed by ID from
# the buffer (proven for ProCmdDatumPlane via the tree-search select-by-ID). This
# probe tests exactly that, and nothing else.
#
# WHAT IT DOES (and does NOT): captures 3 datum-plane feature IDs (3 quick
# clicks), fires ONE atomic macro that pre-selects all three BY ID into the buffer
# (accumulating) and then opens ProCmdDatumPointGeneral. It then PAUSES and asks
# YOU to read the dialog: how many of your 3 planes loaded as references? You then
# CANCEL the dialog -- this probe never commits a feature.
#
# Proven fragments: Get-SelectByIdMacro (tree-search select-by-ID; accumulates
# into the buffer via repeated EvaluateBtn/ApplyBtn -- radinator's batching).
# Unproven (the whole point of the test): that ProCmdDatumPointGeneral loads those
# buffered planes as references.
#
# PREREQ: a PART (.prt) open with >= 3 datum planes. ONE Creo session.
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

# Feature-typed tree-search select-by-ID (proven). With -NoClear it omits the
# leading buffer_clean so repeated calls ACCUMULATE selections into the buffer
# (EvaluateBtn/ApplyBtn add, not replace -- radinator batches edges this way).
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

# ============================================
# HEADER
# ============================================
Write-Host ""
Write-Host "  POINTREF-PROBE -- does ProCmdDatumPointGeneral accept datum planes fed BY ID?" -ForegroundColor Cyan
Write-Host "  (Observational test. Creates NOTHING -- you cancel the dialog at the end.)" -ForegroundColor DarkGray
Write-Host ""

# ============================================
# CONNECT (single session)
# ============================================
$procs = @(Get-Process | Where-Object { $_.ProcessName -eq "xtop" })
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
$model      = $session.GetActiveModel()
if ($null -eq $model) { throw "No active model. Open a part with at least 3 datum planes." }

$fname = try { [string]$model.FileName } catch { "" }
if ($fname -match '(?i)\.asm(\.\d+)?$') {
    throw "Active model is an assembly ($fname). Open the PART (.prt)."
}
Write-Host "  Connected. Active model: $fname" -ForegroundColor Green
Write-Host ""

$origVisibleMapkeys = $null
try {
    $vals = $session.GetConfigOptionValues("visible_mapkeys")
    if ($null -ne $vals -and $vals.Count -gt 0) { $origVisibleMapkeys = $vals.Item(0) }
} catch {}
# NOTE: visible_mapkeys is left AS-IS (not suppressed) so this test is also
# recorded in the trail file for follow-up transcription.

try {

# ============================================
# 1. CAPTURE 3 DATUM-PLANE IDs (3 quick clicks)
# ============================================
Write-Host "  Click THREE datum planes (e.g. 3 mutually-perpendicular planes whose" -ForegroundColor Cyan
Write-Host "  intersection defines a point), one at a time:" -ForegroundColor Cyan
$planeIds = @()
for ($k = 1; $k -le 3; $k++) {
    Read-Host "    Click datum plane #$k in Creo, then press ENTER"
    $id = Read-SelectedId
    if ($null -eq $id) { throw "Nothing selected for plane #$k. Click a datum plane, then press ENTER." }
    if ($planeIds -contains $id) {
        Write-Host "      (id $id already captured -- pick a DIFFERENT plane)" -ForegroundColor Yellow
        $k--
        continue
    }
    $planeIds += $id
    Write-Host "      plane #$k feature ID = $id" -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "  Captured plane IDs: $($planeIds -join ', ')" -ForegroundColor White
Write-Host ""

# ============================================
# 2. PRE-SELECT ALL 3 BY ID (accumulate) + OPEN ProCmdDatumPointGeneral
# ============================================
# ONE atomic macro: clear+select plane1, then select plane2/plane3 with -NoClear
# (accumulate into the buffer), then open the datum-point tool so it sees the
# buffered references -- IF it consumes them.
$macro =
    (Get-SelectByIdMacro -FeatId $planeIds[0]) +
    (Get-SelectByIdMacro -FeatId $planeIds[1] -NoClear) +
    (Get-SelectByIdMacro -FeatId $planeIds[2] -NoClear) +
    "~ Command ``ProCmdDatumPointGeneral``;"
Invoke-Macro "select 3 planes by ID + open ProCmdDatumPointGeneral" $macro
Write-Host ""

# ============================================
# 3. OBSERVE -- how many references loaded?
# ============================================
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "  LOOK AT THE DATUM POINT DIALOG IN CREO NOW." -ForegroundColor Cyan
Write-Host "  In its References / placement collector, how many of your 3 planes" -ForegroundColor Cyan
Write-Host "  appear as already-loaded references?" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "    3 = full success (by-ID feed AND accumulation work -> automation is possible)" -ForegroundColor White
Write-Host "    1 or 2 = partial (consumption works, accumulation needs work)" -ForegroundColor White
Write-Host "    0 = the dialog is empty/waiting for a screen pick (by-ID feed does NOT work)" -ForegroundColor White
Write-Host ""
$loaded = Read-Host "  How many references are loaded? (0/1/2/3, or '?' if unsure)"
Write-Host ""

# ============================================
# 4. CANCEL -- commit nothing
# ============================================
Write-Host "  Now CANCEL the datum point dialog in Creo (Esc or the red X / Cancel)," -ForegroundColor Yellow
Write-Host "  so no feature is created. Then press ENTER here." -ForegroundColor Yellow
Read-Host

# ============================================
# 5. VERDICT
# ============================================
Write-Host ""
switch -regex ($loaded.Trim()) {
    '^3$' {
        Write-Host "  RESULT: by-ID reference feed WORKS (3/3 loaded)." -ForegroundColor Green
        Write-Host "  -> Offset-from-3-planes points ARE scriptable. Next: I record/transcribe the" -ForegroundColor Green
        Write-Host "     offset-value widgets and build the full create+verify macro." -ForegroundColor Green
    }
    '^(1|2)$' {
        Write-Host "  RESULT: consumption works but only $loaded/3 loaded -- accumulation needs work." -ForegroundColor Yellow
        Write-Host "  -> Promising. I'll adjust how the 3 refs are pushed into the buffer (or feed" -ForegroundColor Yellow
        Write-Host "     them one collector-row at a time) and we retest." -ForegroundColor Yellow
    }
    '^0$' {
        Write-Host "  RESULT: by-ID feed does NOT work (0 loaded) -- the point tool wants screen picks." -ForegroundColor Yellow
        Write-Host "  -> Point creation stays pick-bound (the holeinator wall). Best path: you place" -ForegroundColor Yellow
        Write-Host "     points (or one seed) by hand and we automate drilling/patterning." -ForegroundColor Yellow
    }
    default {
        Write-Host "  RESULT: unclear ($loaded). Tell me what the dialog showed and I'll interpret." -ForegroundColor Yellow
    }
}
Write-Host ""
Write-Host "  (This run is also in the trail file, so I can read the exact dialog widget" -ForegroundColor DarkGray
Write-Host "   names regardless of the count you reported.)" -ForegroundColor DarkGray

} finally {
    try {
        if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null }
    } catch {}
    $connection.Disconnect($null)
}

Write-Host ""
Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
