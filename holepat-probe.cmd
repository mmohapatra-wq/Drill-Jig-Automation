<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "HOLEPAT-PROBE (RECORDER)"
$ErrorActionPreference = "Stop"

# ============================================================================
# HOLEPAT-PROBE -- a RECORDER for the seed-hole GEOMETRY-PATTERN mapkey (creates
# a throwaway pattern you then delete; its PURPOSE is to capture the widget names)
# ============================================================================
# WHY THIS EXISTS: an in-depth hole-creation-speedup study (2026-07-21, fan-out
# workflow) established that the drill loop's dominant wall-clock cost is
# STRICTLY LINEAR -- ONE ProCmdHole dashboard + ONE regen PER point (drilljig.cmd
# STAGE 3 foreach 2052-2086; holeinator.cmd 357-383). Every headless-safe micro-
# optimization (trim redundant diameter/body tokens, mega-macro, defer regen,
# drop buffer_clean) was REJECTED as either no-gain or canary-blind-unsafe (see
# the study). The ONLY large win is to CUT THE REGEN COUNT by replicating ONE
# seed hole with a Creo PATTERN (N holes -> 1 seed dashboard + 1 pattern feature),
# exactly as radinator batches 40 rounds into one feature and slotinator patterns
# one seed slot into a row.
#
# The mechanism is PROVEN for slots: slotinator fires a single-direction
# ProCmdGeomPattern live (2026-07-07) -- ui_pat_dir_dir1 fed a base datum BY ID,
# ui_pat_dir_1_num_inst (count), ui_pat_dir_1_incr (spacing), dashInst0.stdbtn_1.
# But a HOLE grid is usually 2-D (Nx x Nz), and the SECOND direction's widgets
# (ui_pat_dir_dir2 / ui_pat_dir_2_num_inst / ui_pat_dir_2_incr, best-guess) were
# NEVER RECORDED -- slotinator's own notes say "the recording's dir-2 block
# omitted." The repo rule is MINE, DON'T GUESS (reference_mine_trail_files_for_
# widgets): a mapkey widget name is transcribed from a real recording, never
# invented. So this probe has you complete ONE 2-direction geometry pattern of a
# seed hole BY HAND with visible_mapkeys ON, then DIFFS the trail and prints the
# exact recipe to wire into a future drilljig "pattern the holes" fast path.
#
# WHAT IT DOES (creates/commits NOTHING itself):
#   1. Finds the active trail file + records its line count (the "before" mark).
#   2. Ensures visible_mapkeys = yes (restores the original in finally).
#   3. Selects your pre-made SEED HOLE feature BY ID and opens ProCmdPattern.
#   4. PAUSES while YOU complete a 2-direction (or 1-direction) pattern by hand:
#      pick direction-1 reference + count + spacing, THEN direction-2 reference +
#      count + spacing, then OK. (Delete the pattern after -- we want the recording.)
#   5. Reads the trail from the mark to end and PRINTS every ~ Command / ~ Select /
#      ~ Input / ~ Update / ~ Activate / ~ Trigger / ~ FocusOut line + Creo !%CP
#      prompts, and writes them to holepat_recipe.txt for transcription.
#
# PREREQ: a PART (.prt) with ONE seed hole already drilled (an On-Point hole at
# a datum point), whose placement can be patterned. ONE Creo session.
#
# This is a READ/RECORD tool: the ONLY macro it fires is the proven select-by-ID +
# ProCmdPattern open (same tokens nodelator/flipenator/slotinator use live). It
# does not type any count/spacing/direction itself -- YOU do, so the trail captures
# the REAL widget names rather than a guess.
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

# Feature-typed tree-search select-by-ID (proven; nodelator/flipenator/plane-probe/slotpat-probe).
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

# Find the NEWEST trail file (working_folder\trail\trail.txt.N). Same search as
# slotpat-probe / csystrf-probe. Returns $null if none found.
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
Write-Host "  HOLEPAT-PROBE (RECORDER) -- capture the seed-hole geometry-pattern widget sequence" -ForegroundColor Cyan
Write-Host "  You complete ONE hole pattern by hand; this reads the trail + prints the recipe." -ForegroundColor DarkGray
Write-Host "  The captured recipe is the path to N holes -> 1 pattern feature (fewer regens)." -ForegroundColor DarkGray
Write-Host ""

# ============================================
# CONNECT (single session)
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
$model      = $session.GetActiveModel()
if ($null -eq $model) { throw "No active model. Open a PART with ONE seed hole." }

$fname = try { [string]$model.FileName } catch { "" }
if ($fname -match '(?i)\.asm(\.\d+)?$') {
    throw "Active model is an assembly ($fname). Open the PART (.prt)."
}
Write-Host "  Connected. Active model: $fname" -ForegroundColor Green
Write-Host ""

# ENABLE visible_mapkeys so EVERY widget interaction is echoed into the trail
# (that is the whole point - we are recording). Capture + restore the original.
$origVisibleMapkeys = $null
try {
    $vals = $session.GetConfigOptionValues("visible_mapkeys")
    if ($null -ne $vals -and $vals.Count -gt 0) { $origVisibleMapkeys = $vals.Item(0) }
} catch {}
try { $session.SetConfigOption("visible_mapkeys", "yes") | Out-Null } catch {}

try {

# ============================================
# 1. MARK THE TRAIL (before) + CAPTURE THE SEED HOLE FEATURE ID
# ============================================
$trail = Find-NewestTrail
$beforeLines = 0
if ($null -ne $trail) {
    try { $beforeLines = (Get-Content -LiteralPath $trail.FullName | Measure-Object -Line).Lines } catch {}
    Write-Host ("  Trail file: {0}" -f $trail.FullName) -ForegroundColor DarkGray
    Write-Host ("  Trail is at {0} lines now (the 'before' mark)." -f $beforeLines) -ForegroundColor DarkGray
} else {
    Write-Host "  Could not locate a trail file automatically - I'll still print instructions;" -ForegroundColor Yellow
    Write-Host "  you can transcribe from working_folder\trail\trail.txt.<newest> by hand." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  PREP (do this in Creo first): drill ONE seed hole -- an On-Point hole at a" -ForegroundColor Cyan
Write-Host "  datum point (or just any hole), so it can be patterned across the grid." -ForegroundColor Cyan
Write-Host ""
Write-Host "  Now SELECT that HOLE feature in the model tree, then press ENTER." -ForegroundColor Cyan
Read-Host
$seedId = Read-SelectedId
if ($null -eq $seedId) { throw "Nothing selected. Select the seed HOLE feature in the tree, then press ENTER." }
Write-Host "  Seed hole feature ID = $seedId" -ForegroundColor White
Write-Host ""

# ============================================
# 2. PRE-SELECT THE SEED BY ID + OPEN ProCmdPattern
# ============================================
$macro =
    (Get-SelectByIdMacro -FeatId $seedId) +
    "~ Command ``ProCmdPattern``;"
Invoke-Macro "select seed hole by ID + open ProCmdPattern" $macro
Write-Host ""

# ============================================
# 3. YOU COMPLETE THE PATTERN BY HAND (this is the recording)
# ============================================
Write-Host "  ============================================================" -ForegroundColor Magenta
Write-Host "  COMPLETE A HOLE PATTERN BY HAND IN CREO NOW:" -ForegroundColor Magenta
Write-Host "  ============================================================" -ForegroundColor Magenta
Write-Host "    1. The pattern dashboard is open on your seed hole." -ForegroundColor White
Write-Host "    2. Choose the pattern TYPE you want the fast path to use:" -ForegroundColor White
Write-Host "         - DIRECTION pattern is the proven-live one (slotinator uses dir-1)." -ForegroundColor White
Write-Host "    3. DIRECTION 1: pick a reference (a base DATUM PLANE / flat face / axis --" -ForegroundColor White
Write-Host "       a plane is always valid), type a COUNT and a SPACING (increment)." -ForegroundColor White
Write-Host "    4. DIRECTION 2 (the part we are MISSING): pick the perpendicular datum" -ForegroundColor White
Write-Host "       plane, type its COUNT and SPACING, so the seed replicates in a GRID." -ForegroundColor White
Write-Host "    5. Click OK / the green check to CREATE the pattern." -ForegroundColor White
Write-Host ""
Write-Host "  Do the WHOLE thing with the mouse/keyboard - every click is being recorded." -ForegroundColor Yellow
Write-Host "  Especially the DIRECTION-2 widgets (count/spacing) -- those are the ones the" -ForegroundColor Yellow
Write-Host "  repo has never captured. When the pattern is CREATED, press ENTER." -ForegroundColor Yellow
Read-Host

# ============================================
# 4. DIFF THE TRAIL -> extract the pattern widget sequence
# ============================================
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "  RECORDED HOLE-PATTERN RECIPE (widget lines since the 'before' mark)" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
$recipeFile = Join-Path $ScriptDir 'holepat_recipe.txt'
$captured = @()
if ($null -ne $trail) {
    # re-find the newest trail (Creo may have rolled to a new trail.txt.N+1)
    $trailNow = Find-NewestTrail
    $allNew = @()
    if ($trailNow.FullName -eq $trail.FullName) {
        try { $allNew = @(Get-Content -LiteralPath $trailNow.FullName | Select-Object -Skip $beforeLines) } catch {}
    } else {
        Write-Host ("  (Creo rolled to a new trail: {0})" -f $trailNow.FullName) -ForegroundColor DarkGray
        try { $allNew = @(Get-Content -LiteralPath $trailNow.FullName) } catch {}
    }
    # keep only the widget-interaction + prompt lines (drop mouse/timer/move noise).
    $captured = @($allNew | Where-Object {
        $_ -match '^\s*~\s*(Command|Open|Close|Select|Update|Input|Activate|Trigger|FocusOut|FocusIn|Enter|Exit)\b' -or
        $_ -match '^\s*!%CP'
    })
    if ($captured.Count -gt 0) {
        foreach ($ln in $captured) { Write-Host "    $ln" -ForegroundColor Gray }
        try {
            $captured | Set-Content -LiteralPath $recipeFile -Encoding UTF8
            Write-Host ""
            Write-Host ("  {0} widget/prompt line(s) written to: {1}" -f $captured.Count, $recipeFile) -ForegroundColor Green
            Write-Host "  Transcribe the ui_pat_dir_dir2 / ui_pat_dir_2_num_inst / ui_pat_dir_2_incr" -ForegroundColor Green
            Write-Host "  tokens (the second direction) into the drilljig hole-pattern fast path." -ForegroundColor Green
        } catch {
            Write-Host "  (could not write $recipeFile : $($_.Exception.Message))" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  No new widget lines found after the mark. Was visible_mapkeys on, and did" -ForegroundColor Yellow
        Write-Host "  you complete the pattern? You can read the trail directly: $($trail.FullName)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  No trail file was located - read working_folder\trail\trail.txt.<newest> by hand" -ForegroundColor Yellow
    Write-Host "  and copy the ~ Command / ~ Select / ~ Input / ~ Update / ~ Activate / ~ Trigger" -ForegroundColor Yellow
    Write-Host "  lines of the Pattern session (from '~ Command ``ProCmdPattern``' to the confirm)." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  You can now delete the throwaway pattern in Creo (Edit > Delete) - we only" -ForegroundColor DarkGray
Write-Host "  needed the recording. This tool committed nothing itself." -ForegroundColor DarkGray
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
