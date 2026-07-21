<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "CSYSTRF-PROBE (RECORDER)"
$ErrorActionPreference = "Stop"

# ============================================================================
# CSYSTRF-PROBE  -- a RECORDER for the "change coordinate system type" mapkey
# (creates NOTHING itself; its PURPOSE is to capture the real widget names)
# ============================================================================
# GOAL: capture the EXACT widget sequence for drilljig's DEFAULT reref-method
# 'transform' -- relocate the base csys onto the index hole by (1) Analysis >
# Transform between the base csys and the index csys -> save the matrix to an
# info.trf file, then (2) redefine the base csys with OffsetType = file importing
# that transform. The whole jig (offset from the base) then follows.
#
# WHY A RECORDER (mine-don't-guess, per reference_mine_trail_files_for_widgets):
# lib/drilljig_core.ps1 Build-CsysTransformExportMacro + Build-CsysReimportMacro
# were transcribed from the operator's 2026-07-14 "mapkey three", but the FILE
# DIALOG legs are UNVERIFIED -- specifically:
#   * the Save-As filename ENTRY (the macro clicks 'file_saveas desktop_pb' + 'OK'
#     but never types a filename -> which file did it write?),
#   * the file-OPEN SELECTION on reimport (the macro clicks 'file_open desktop_pb'
#     + a generic open push but never selects a specific info.trf), and
#   * an omitted @PAUSE_FOR_SCREEN_PICK a RunMacro cannot replay.
# These widget/token names cannot be guessed. This tool has you perform the WHOLE
# transform + reimport BY HAND with visible_mapkeys ON, then DIFFS the trail and
# prints/writes the exact ~ Command / ~ Select / ~ Update / ~ Activate / ~ Trigger
# lines -- the real recipe to reconcile against the two Build-* macros.
#
# WHAT IT DOES (observational only -- it commits nothing, selects nothing):
#   1. Finds the active trail file + records its line count (the "before" mark).
#   2. Ensures visible_mapkeys = yes (restores the original in finally).
#   3. PAUSES while YOU do the full workflow in Creo by hand.
#   4. Reads the trail from the mark to end, prints every widget/prompt line, and
#      writes them to csystrf_recipe.txt for transcription.
#
# PREREQ: a PART (.prt) that already has TWO datum coordinate systems -- a BASE
# csys and a TARGET/index csys (e.g. from a drilljig run, or make two by hand).
# ONE Creo session. This probe drives NOTHING in Creo; you do every click.
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

# Find the NEWEST trail file (working_folder\trail\trail.txt.N). Same roots as
# slotpat-probe.cmd. Returns $null if none found.
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
Write-Host "  CSYSTRF-PROBE (RECORDER) -- capture the change-coordinate-system-type recipe" -ForegroundColor Cyan
Write-Host "  You do the whole transform + reimport by hand; this reads the trail + prints it." -ForegroundColor DarkGray
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
if ($null -eq $model) { throw "No active model. Open a PART with two datum coordinate systems." }

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
# 1. MARK THE TRAIL (before)
# ============================================
$trail = Find-NewestTrail
$beforeLines = 0
if ($null -ne $trail) {
    try { $beforeLines = (Get-Content -LiteralPath $trail.FullName | Measure-Object -Line).Lines } catch {}
    Write-Host ("  Trail file: {0}" -f $trail.FullName) -ForegroundColor DarkGray
    Write-Host ("  Trail is at {0} lines now (the 'before' mark)." -f $beforeLines) -ForegroundColor DarkGray
} else {
    Write-Host "  Could not locate a trail file automatically - I'll still print instructions;" -ForegroundColor Yellow
    Write-Host "  transcribe from working_folder\trail\trail.txt.<newest> by hand afterward." -ForegroundColor Yellow
}
Write-Host ""

# ============================================
# 2. YOU DO THE WHOLE WORKFLOW BY HAND (this is the recording)
# ============================================
Write-Host "  ============================================================" -ForegroundColor Magenta
Write-Host "  PERFORM THE FULL CHANGE-COORDINATE-SYSTEM-TYPE WORKFLOW BY HAND:" -ForegroundColor Magenta
Write-Host "  ============================================================" -ForegroundColor Magenta
Write-Host "  PART 1 -- export the transform to a file:" -ForegroundColor White
Write-Host "    1. Select the TARGET (index) csys, then Ctrl-select the BASE csys." -ForegroundColor White
Write-Host "    2. Analysis tab > Measure/Transform (the Transform analysis tool)." -ForegroundColor White
Write-Host "    3. Set the type to TRANSFORM; the From/To references are the two csys." -ForegroundColor White
Write-Host "    4. Produce the info, then SAVE-AS to a file -- TYPE A FILENAME you'll" -ForegroundColor White
Write-Host "       recognize (e.g. drilljig_info.trf) and note WHERE it saves." -ForegroundColor White
Write-Host "    5. Close the info window / exit the Transform tool." -ForegroundColor White
Write-Host ""
Write-Host "  PART 2 -- change the BASE csys to import that transform:" -ForegroundColor White
Write-Host "    6. Right-click the BASE csys in the tree > Edit Definition (redefine)." -ForegroundColor White
Write-Host "    7. Change its Offset TYPE to 'From File' / file transform." -ForegroundColor White
Write-Host "    8. Browse to + OPEN the info.trf you saved in step 4." -ForegroundColor White
Write-Host "    9. Click OK to complete the redefine; confirm the part regenerates." -ForegroundColor White
Write-Host ""
Write-Host "  Do EVERY step with the mouse/keyboard - each click is being recorded." -ForegroundColor Yellow
Write-Host "  When you have FINISHED (or completed as much as you can), press ENTER." -ForegroundColor Yellow
Read-Host

# ============================================
# 3. DIFF THE TRAIL -> extract the widget sequence
# ============================================
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "  RECORDED CHANGE-CSYS-TYPE RECIPE (widget lines since the 'before' mark)" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
$recipeFile = Join-Path $ScriptDir 'csystrf_recipe.txt'
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
    # keep only the widget-interaction + prompt lines (drop mouse/timer/move/window
    # noise); this is exactly the set worth transcribing into the two Build-* macros.
    $captured = @($allNew | Where-Object {
        $_ -match '^\s*~\s*(Command|Open|Close|Select|Update|Input|Activate|Trigger|FocusOut|FocusIn|Enter|Exit)\b' -or
        $_ -match '^\s*!%CP'    # Creo prompt lines (e.g. "Select a file to open")
    })
    if ($captured.Count -gt 0) {
        foreach ($ln in $captured) { Write-Host "    $ln" -ForegroundColor Gray }
        try {
            $captured | Set-Content -LiteralPath $recipeFile -Encoding UTF8
            Write-Host ""
            Write-Host ("  {0} widget/prompt line(s) written to: {1}" -f $captured.Count, $recipeFile) -ForegroundColor Green
            Write-Host "  Reconcile these against lib/drilljig_core.ps1 Build-CsysTransformExportMacro" -ForegroundColor DarkGray
            Write-Host "  + Build-CsysReimportMacro -- especially the Save-As filename + file-open tokens." -ForegroundColor DarkGray
        } catch {
            Write-Host "  (could not write $recipeFile : $($_.Exception.Message))" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  No new widget lines found after the mark. Was visible_mapkeys on, and did" -ForegroundColor Yellow
        Write-Host "  you complete the workflow? You can read the trail directly: $($trail.FullName)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  No trail file was located - read working_folder\trail\trail.txt.<newest> by hand" -ForegroundColor Yellow
    Write-Host "  and copy the Transform-tool + Redefine (OffsetType=file) widget lines." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  This tool drove nothing in Creo - it only recorded. Nothing to undo." -ForegroundColor DarkGray

} finally {
    try { if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null } } catch {}
    try { $connection.Disconnect($null) } catch {}
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}

Write-Host ""
Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
