<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "SLOTPAT-PROBE (RECORDER)"
$ErrorActionPreference = "Stop"

# ============================================================================
# SLOTPAT-PROBE  -- a RECORDER for the dimension-pattern mapkey (creates a
# throwaway pattern you then delete; its PURPOSE is to capture the widget names)
# ============================================================================
# GOAL: capture the EXACT widget sequence for a completed Creo DIMENSION PATTERN
# so slotinator can pattern one seed slot into N rows (user 2026-07-06: "make a
# pattern instead of drawing rectangles over and over"). An exhaustive VB-docs
# sweep confirmed there is NO programmatic pattern/copy API on this build
# (IpfcFeaturePattern is read/delete-only; IpfcCopyInstructions = "reserved for
# the future"; CreateFeature not-implemented) -- so a MAPKEY is the only lever,
# and the mapkey needs the operator to CLICK the dimension to vary (one pick).
#
# WHY A RECORDER (not the old observational probe): ProCmdPattern was recorded
# only ONCE across every trail (trail.txt.27:3759) and CANCELLED before the
# count/increment widgets were ever set -- so those widget names are UNKNOWN and
# CANNOT be guessed (the repo's mine-don't-guess rule). This tool has you COMPLETE
# one dimension pattern by hand with visible_mapkeys ON, then it DIFFS the trail
# and prints the exact ~ Command / ~ Input / ~ Update / ~ Activate / ~ Trigger
# lines of the pattern session -- the real recipe to wire into slotinator next.
#
# WHAT IT DOES:
#   1. Finds the active trail file + records its current line count (the "before"
#      mark).
#   2. Ensures visible_mapkeys = yes (so every widget interaction is logged), and
#      restores the original setting in finally.
#   3. Selects your pre-made seed slot-cut feature BY ID and opens ProCmdPattern.
#   4. PAUSES while YOU complete a Dimension pattern by hand: click the position
#      dimension to vary, type a COUNT (e.g. 3) and an INCREMENT (e.g. the row
#      pitch), and click OK/Done. (Then you can delete the pattern -- we only want
#      the recording.)
#   5. Reads the trail from the "before" mark to end and PRINTS every pattern
#      widget line, and writes them to slotpat_recipe.txt for transcription.
#
# PREREQ: a PART (.prt) with ONE seed slot cut already made (a Remove-Material
# extrude whose cross-position is a drivable dimension). ONE Creo session.
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

# Feature-typed tree-search select-by-ID (proven; nodelator/flipenator/plane-probe).
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

# Find the NEWEST trail file (working_folder\trail\trail.txt.N). Trails live under
# PRO_DIRECTORY\..\working_folder\trail on this machine; search a few likely roots
# and take the most-recently-modified trail.txt.*. Returns $null if none found.
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
Write-Host "  SLOTPAT-PROBE (RECORDER) -- capture the dimension-pattern widget sequence" -ForegroundColor Cyan
Write-Host "  You complete ONE pattern by hand; this reads the trail + prints the recipe." -ForegroundColor DarkGray
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
if ($null -eq $model) { throw "No active model. Open a PART with ONE seed slot cut." }

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
# 1. MARK THE TRAIL (before) + CAPTURE THE SEED SLOT-CUT FEATURE ID
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
Write-Host "  PREP (do this in Creo first): make ONE seed slot cut -- a Remove-Material" -ForegroundColor Cyan
Write-Host "  extrude rectangle over the first hole row, whose cross-position (distance" -ForegroundColor Cyan
Write-Host "  from the near datum) is a real, editable dimension." -ForegroundColor Cyan
Write-Host ""
Write-Host "  Now SELECT that cut feature in the model tree, then press ENTER." -ForegroundColor Cyan
Read-Host
$seedId = Read-SelectedId
if ($null -eq $seedId) { throw "Nothing selected. Select the seed slot-cut feature in the tree, then press ENTER." }
Write-Host "  Seed slot-cut feature ID = $seedId" -ForegroundColor White
Write-Host ""

# ============================================
# 2. PRE-SELECT THE SEED BY ID + OPEN ProCmdPattern
# ============================================
$macro =
    (Get-SelectByIdMacro -FeatId $seedId) +
    "~ Command ``ProCmdPattern``;"
Invoke-Macro "select seed cut by ID + open ProCmdPattern" $macro
Write-Host ""

# ============================================
# 3. YOU COMPLETE THE PATTERN BY HAND (this is the recording)
# ============================================
Write-Host "  ============================================================" -ForegroundColor Magenta
Write-Host "  COMPLETE A DIMENSION PATTERN BY HAND IN CREO NOW:" -ForegroundColor Magenta
Write-Host "  ============================================================" -ForegroundColor Magenta
Write-Host "    1. The pattern dashboard is open on your seed cut." -ForegroundColor White
Write-Host "    2. Make sure the type is DIMENSION (not Direction)." -ForegroundColor White
Write-Host "    3. Click the seed's CROSS-POSITION dimension (the distance from the" -ForegroundColor White
Write-Host "       near datum) as the dimension to vary in the first direction." -ForegroundColor White
Write-Host "    4. Type a COUNT (e.g. 3) and an INCREMENT (e.g. your row pitch)." -ForegroundColor White
Write-Host "    5. Click OK / the green check to CREATE the pattern." -ForegroundColor White
Write-Host ""
Write-Host "  Do the WHOLE thing with the mouse/keyboard - every click is being recorded." -ForegroundColor Yellow
Write-Host "  When the pattern is CREATED (or you have finished the sequence), press ENTER." -ForegroundColor Yellow
Read-Host

# ============================================
# 4. DIFF THE TRAIL -> extract the pattern widget sequence
# ============================================
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "  RECORDED PATTERN RECIPE (widget lines since the 'before' mark)" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
$recipeFile = Join-Path $ScriptDir 'slotpat_recipe.txt'
$captured = @()
if ($null -ne $trail) {
    # re-find the newest trail (Creo may have rolled to a new trail.txt.N+1)
    $trailNow = Find-NewestTrail
    $allNew = @()
    if ($trailNow.FullName -eq $trail.FullName) {
        # same file: take everything after the before-mark
        try { $allNew = @(Get-Content -LiteralPath $trailNow.FullName | Select-Object -Skip $beforeLines) } catch {}
    } else {
        # Creo rolled the trail: the whole new file is the recording
        Write-Host ("  (Creo rolled to a new trail: {0})" -f $trailNow.FullName) -ForegroundColor DarkGray
        try { $allNew = @(Get-Content -LiteralPath $trailNow.FullName) } catch {}
    }
    # keep only the widget-interaction lines (drop mouse/timer/move/window noise);
    # this is exactly the set worth transcribing into a macro.
    $captured = @($allNew | Where-Object {
        $_ -match '^\s*~\s*(Command|Open|Close|Select|Update|Input|Activate|Trigger|FocusOut|FocusIn|Enter|Exit)\b' -or
        $_ -match '^\s*!%CP'    # Creo prompt lines (context, e.g. "Select the dimension to vary")
    })
    if ($captured.Count -gt 0) {
        foreach ($ln in $captured) { Write-Host "    $ln" -ForegroundColor Gray }
        try {
            $captured | Set-Content -LiteralPath $recipeFile -Encoding UTF8
            Write-Host ""
            Write-Host ("  {0} widget/prompt line(s) written to: {1}" -f $captured.Count, $recipeFile) -ForegroundColor Green
        } catch {
            Write-Host "  (could not write $recipeFile : $($_.Exception.Message))" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  No new widget lines found after the mark. Was visible_mapkeys on, and did" -ForegroundColor Yellow
        Write-Host "  you complete the pattern? You can read the trail directly: $($trail.FullName)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  No trail file was located - read working_folder\trail\trail.txt.<newest> by hand" -ForegroundColor Yellow
    Write-Host "  and copy the ~ Command / ~ Input / ~ Update / ~ Activate / ~ Trigger lines of" -ForegroundColor Yellow
    Write-Host "  the Pattern session (from '~ Command ``ProCmdPattern``' to the confirm)." -ForegroundColor Yellow
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
