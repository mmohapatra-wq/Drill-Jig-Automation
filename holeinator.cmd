<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

# ============================================================================
# holeinator.cmd - create an On-Point HOLE at every target datum point
# ============================================================================
# Human-in-the-loop flow (the human makes the judgments that coordinate math
# kept getting wrong over COM):
#   STEP 1  user SELECTS the target datum points in Creo  -> ENTER
#   STEP 2  user PICKS the target body                    -> ENTER
#   STEP 3  user ENTERS the hole diameter
#   CONFIRM y/N -> fire (canary first, then the rest)
#
# ID-ONLY capture. The script never reads IpfcPoint.Point coordinates -- an
# earlier coordinate-based design (off-plane filter + idempotency) kept crashing
# on the COM marshaling of point xyz ("op_Subtraction on System.Object[]"). The
# human now does the on-plane / which-body judgment visually, so only point IDs
# are needed. Resolving a selected datum-point FEATURE into its point ids uses
# ListSubItems(ITEM_POINT) -> $p.Id, which is id-only too.
#
# Each hole is CREATED from scratch with Creo's native On-Point hole: select the
# datum point by ID (tree search, no screen picks), then fire the recorded hole
# dashboard as ONE atomic RunMacro. The diameter is set directly in the
# dashboard (never written-then-regenerated), so the sketch-dim snap-back trap
# (see project_sketch_dim_snapback) never applies.
#
# MACRO PROVENANCE: Build-HoleMacro was transcribed from a live mapkey recording
# on the jig part (2026-06-11). The whole select+dashboard runs as one atomic
# RunMacro -- a dashboard's command context does not survive across RunMacro
# calls (CLAUDE.md boxinator lesson). Not yet confirmed by a full scripted run;
# the canary (verify hole #1 changed the model before committing) is the live
# net against widget-name drift across Creo datecodes.
# ============================================================================

$Host.UI.RawUI.WindowTitle = "HOLEINATOR"
$ErrorActionPreference = "Stop"

trap {
    Write-Host ""
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

$script:lastPct = -1
function Show-Progress {
    param([int]$Pct, [string]$Label)
    if ($Pct -eq $script:lastPct) { return }
    $script:lastPct = $Pct
    $filled = [Math]::Floor($Pct / 5)
    $empty = 20 - $filled
    $bar = ([char]9608).ToString() * $filled + ([char]9617).ToString() * $empty
    $color = if ($Pct -ge 100) { "Green" } else { "White" }
    $shortLabel = if ($Label.Length -gt 20) { $Label.Substring(0, 20) } else { $Label }
    Write-Host "`r  [$bar] $($Pct.ToString().PadLeft(3))%  $shortLabel   " -NoNewline -ForegroundColor $color
    if ($Pct -ge 100) { Write-Host "" }
}

function Wait-ModelModified {
    # $true if VersionStamp changed within the timeout (macro modified the model).
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

# ----------------------------------------------------------------------------
# Recorded hole macro (transcribed live 2026-06-11). ID-driven; ONE atomic
# RunMacro -- a dashboard's command context does not survive across RunMacro
# calls (CLAUDE.md boxinator lesson). `~ Trail`/`~ Timer` recording noise dropped.
# ----------------------------------------------------------------------------
function Build-HoleMacro {
    param([int]$PointId, [double]$Diameter, [int]$BodyIndex = 0)
    return "~ Activate ``main_dlg_cur`` ``buffer_clean``;" +
        # select the target datum point by ID
        "~ Command ``ProCmdMdlTreeSearch``;" +
        "~ Open ``selspecdlg0`` ``SelOptionRadio``;" +
        "~ Close ``selspecdlg0`` ``SelOptionRadio``;" +
        "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Point``;" +
        "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
        "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$PointId``;" +
        "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
        "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
        "~ Activate ``selspecdlg0`` ``CancelButton``;" +
        # hole dashboard (recorded)
        "~ Command ``ProCmdHole``;" +
        # depth -> through all (open the depth-type flyout, pick Thru All)
        "~ Select ``main_dlg_cur`` ``maindashInst0.hole_depth_to_type_flybtn``;" +
        "~ Close  ``main_dlg_cur`` ``maindashInst0.hole_depth_to_type_flybtn``;" +
        "~ Activate ``main_dlg_cur`` ``maindashInst0.StrHoleDepThruAllF`` 1;" +
        # standard-hole layout + hole-note toggles (as recorded)
        "~ Activate ``main_dlg_cur`` ``chkbn.std_hle_layout.0`` 1;" +
        "~ Activate ``main_dlg_cur`` ``chkbn.std_hole_note_layout.0`` 1;" +
        # body selection: enable the body page, then pick body $BodyIndex
        "~ Activate ``main_dlg_cur`` ``chkbn.body_page.0`` 1;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ``$BodyIndex``;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ````;" +
        "~ Focus  ``body_page.1.0`` ``PH.bodyselectrepwdg_list``;" +
        "~ Select ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` 1 ``$BodyIndex``;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ````;" +
        # diameter
        "~ Input  ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu`` ``$Diameter``;" +
        "~ Update ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu`` ``$Diameter``;" +
        "~ Activate ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu``;" +
        "~ FocusOut ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu``;" +
        # confirm
        "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"
}

# ============================================
# HEADER
# ============================================
Write-Host ""
Write-Host "  ██   ██  ██████  ██      ███████ ██ ███    ██  █████  ████████  ██████  ██████ " -ForegroundColor White
Write-Host "  ██   ██ ██    ██ ██      ██      ██ ████   ██ ██   ██    ██    ██    ██ ██   ██" -ForegroundColor White
Write-Host "  ███████ ██    ██ ██      █████   ██ ██ ██  ██ ███████    ██    ██    ██ ██████ " -ForegroundColor White
Write-Host "  ██   ██ ██    ██ ██      ██      ██ ██  ██ ██ ██   ██    ██    ██    ██ ██   ██" -ForegroundColor White
Write-Host "  ██   ██  ██████  ███████ ███████ ██ ██   ████ ██   ██    ██     ██████  ██   ██" -ForegroundColor White
Write-Host "  On-Point Hole Creation" -ForegroundColor White
Write-Host ""

# ============================================
# PREREQUISITES
# ============================================
Write-Host "  Prerequisites:" -ForegroundColor Green
Write-Host "    1. Part open in Creo" -ForegroundColor White
Write-Host "    2. Datum points placed at every target hole location" -ForegroundColor White
Write-Host "    3. Hole diameter known" -ForegroundColor White
Write-Host "    4. Do not interact with Creo once drilling starts" -ForegroundColor White
Write-Host ""

# ----------------------------------------------------------------------------
# Connect (identical pattern to nodelator / every toolkit script)
# ----------------------------------------------------------------------------
try {
    $proc = Get-Process -Name xtop -ErrorAction SilentlyContinue
    if ($null -eq $proc) { throw "Running Creo process (xtop) not found" }
    $pc_path = $proc.Path -replace "xtop.exe", "pro_comm_msg.exe"
    $Env:PRO_DIRECTORY = $proc.Path.TrimEnd("xtop.exe")
    $Env:PRO_COMM_MSG_EXE = $pc_path
}
catch { $_; exit }

try { New-Object -ComObject pfcls.pfcAsyncConnection | Out-Null }
catch {
    Write-Output "VB API not yet registered on this machine, performing first time setup..."
    $vb_path = $proc.Path -replace "Common Files(.*)$", "Parametric\bin\vb_api_register.bat"
    Start-Process -Wait -FilePath $vb_path
}

try {
    $async = New-Object -ComObject pfcls.pfcAsyncConnection
    $connection = $async.Connect($null, $null, $null, $null)
    $session = $connection.Session
}
catch { $_; Write-Output "Could not connect to Creo session."; exit }

$model = $session.GetActiveModel()
if ($null -eq $model) { throw "No active model in the Creo session. Open the drill-jig part first." }
Write-Host "  Connected: $($model.FileName)" -ForegroundColor Green

# Mode guard: this tool drills a PART. In assembly mode the datum points and
# by-ID selection resolve against the .asm, not the part to drill. Key off the
# filename extension (EpfcModelType enum ints are unconfirmed on this build).
$modelFile = ""
try { $modelFile = [string]$model.FileName } catch {}
if ($modelFile -match '\.asm(\.\d+)?$') {
    Write-Host ""
    Write-Host "  STOP: the active model is an ASSEMBLY ($modelFile)." -ForegroundColor Yellow
    Write-Host "  holeinator drills holes into a single PART. Open the jig PART" -ForegroundColor Yellow
    Write-Host "  itself (activate it in its own window), then re-run." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# Suppress UI noise; restore in finally.
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
#------------- HOLEINATOR LOGIC ---------------------

$pfcType = New-Object -ComObject pfcls.pfcModelItemType

# ============================================
# STEP 1: user selects the target datum points in Creo
# ============================================
Write-Host ""
Write-Host "  STEP 1 -- In Creo, select the target datum points," -ForegroundColor Cyan
Write-Host "           then come back here and press ENTER." -ForegroundColor Cyan
Read-Host
$points = ($session.CurrentSelectionBuffer()).Contents
if ($null -eq $points) { throw "Selection buffer is empty -- no datum points selected in Creo." }

# Resolve selections into POINT IDs only (never reads .Point coordinates).
# A selection can be the point geometry directly, or a datum-point FEATURE whose
# point ids come from ListSubItems(ITEM_POINT). Both expose .Id with no coords.
$pointIDs = @()
$seen = @{}
$rejected = @()
foreach ($item in $points) {
    $si = $null
    try { $si = $item.SelItem } catch { continue }
    if ($null -eq $si) { continue }

    $isPointType = $false
    try { $isPointType = ([int]$si.Type -eq [int]$pfcType.ITEM_POINT) } catch {}

    $subIds = @()
    try {
        foreach ($p in @($si.ListSubItems($pfcType.ITEM_POINT))) {
            try { $subIds += [int]$p.Id } catch {}
        }
    } catch {}

    if ($subIds.Count -gt 0) {
        # a feature that contains points -> use the contained point ids
        foreach ($sid in $subIds) {
            if (-not $seen.ContainsKey($sid)) { $seen[$sid] = $true; $pointIDs += $sid }
        }
    } elseif ($isPointType) {
        # the selection IS a datum point -> use its id
        $id = [int]$si.Id
        if (-not $seen.ContainsKey($id)) { $seen[$id] = $true; $pointIDs += $id }
    } else {
        $tname = "?"; $rid = "?"
        try { $rid = [int]$si.Id } catch {}
        try { $tname = [string]$si.Type } catch {}
        $rejected += "id $rid (type $tname)"
    }
}

if ($rejected.Count -gt 0) {
    Write-Host ("  Ignored {0} selected item(s) that are neither datum points nor point-bearing features:" -f $rejected.Count) -ForegroundColor Yellow
    foreach ($r in ($rejected | Select-Object -First 10)) { Write-Host "      $r" -ForegroundColor DarkGray }
}
if ($pointIDs.Count -eq 0) {
    throw "No datum point ids resolved from the selection. Select datum points (or a datum-point feature) and try again."
}
Write-Host ("  Captured {0} target point id(s): {1}" -f $pointIDs.Count, ($pointIDs -join ", ")) -ForegroundColor Green

# ============================================
# STEP 2: user picks the target body
# ============================================
# Listing ITEM_BODY is the supported way to enumerate bodies (the multibody-
# unsupported exception is about geometry-item lists, not body lists). Wrapped
# defensively regardless.
Write-Host ""
Write-Host "  STEP 2 -- Target body." -ForegroundColor Cyan
$bodyList = @()
try { $bodyList = @($model.ListItems($pfcType.ITEM_BODY)) } catch {}

$bodyIndex = 0
if ($bodyList.Count -gt 1) {
    Write-Host ("  This part has {0} solid bodies:" -f $bodyList.Count) -ForegroundColor White
    for ($i = 0; $i -lt $bodyList.Count; $i++) {
        $bn = try { $bodyList[$i].GetName() } catch { "(unnamed)" }
        Write-Host ("      {0}) {1}" -f $i, $bn) -ForegroundColor White
    }
    Write-Host "  Highlight/verify the body in Creo if unsure, then choose here." -ForegroundColor DarkGray
    while ($true) {
        $raw = Read-Host ("  Enter body index (0-{0}), then ENTER" -f ($bodyList.Count - 1))
        $n = -1
        if ([int]::TryParse($raw, [ref]$n) -and $n -ge 0 -and $n -lt $bodyList.Count) { $bodyIndex = $n; break }
        Write-Host ("  Enter a number between 0 and {0}." -f ($bodyList.Count - 1)) -ForegroundColor Yellow
    }
} elseif ($bodyList.Count -eq 1) {
    Write-Host "  Single-body part -- using body index 0." -ForegroundColor DarkGray
    Read-Host "  Press ENTER to continue"
} else {
    Write-Host "  (could not enumerate bodies; defaulting to body index 0)" -ForegroundColor Yellow
    Read-Host "  Press ENTER to continue"
}
Write-Host ("  Target body index: {0}" -f $bodyIndex) -ForegroundColor Green

# ============================================
# STEP 3: user enters the hole diameter
# ============================================
# Pre-fill from jiginator's handoff if present, but the user always confirms/types.
$jigDia = $null
$handoffPath = Join-Path $ScriptDir 'last_jig_spec.json'
if (Test-Path $handoffPath) {
    try {
        $spec = Get-Content $handoffPath -Raw | ConvertFrom-Json
        if ($null -ne $spec.HoleDiameter -and [double]$spec.HoleDiameter -gt 0) {
            $jigDia = [double]$spec.HoleDiameter
            Write-Host ""
            Write-Host ("  (jiginator handoff suggests diameter {0})" -f $jigDia) -ForegroundColor DarkGray
        }
    } catch {}
}

Write-Host ""
Write-Host "  STEP 3 -- Hole diameter." -ForegroundColor Cyan
$holeDia = 0.0
while ($holeDia -le 0) {
    $prompt = if ($null -ne $jigDia) { "  Enter hole diameter [ENTER = $jigDia]" } else { "  Enter hole diameter (required)" }
    $raw = Read-Host $prompt
    if ([string]::IsNullOrWhiteSpace($raw) -and $null -ne $jigDia) { $holeDia = $jigDia; break }
    $d = 0.0
    if ([double]::TryParse($raw.Trim(), [ref]$d) -and $d -gt 0) { $holeDia = $d }
    else { Write-Host "  Enter a positive number." -ForegroundColor Yellow }
}
Write-Host ("  Hole diameter: {0}" -f $holeDia) -ForegroundColor Green

# ============================================
# CONFIRM (last stop before mutating the model)
# ============================================
Write-Host ""
Write-Host ("  Ready: {0} hole(s), diameter {1}, through all, body index {2}." -f $pointIDs.Count, $holeDia, $bodyIndex) -ForegroundColor Cyan
Write-Host "  Do not touch Creo while this runs." -ForegroundColor DarkGray
$go = Read-Host "  Proceed? (y/N)"
if ($go -notmatch '^[Yy]$') {
    Write-Host "  Cancelled -- nothing was changed in the model." -ForegroundColor Yellow
    return
}
Write-Host ""

# ============================================
# FIRE -- canary first, then the rest
# ============================================
# The recorded macro has not been confirmed by a full scripted run, so validate
# hole #1 by VersionStamp before committing. If the first does nothing, stop
# after one attempt rather than firing a broken macro N times.
$total = $pointIDs.Count
$idx = 0
$made = 0
$noop = 0
$failed = 0
$aborted = $false

foreach ($ptId in $pointIDs) {
    $idx++
    Show-Progress ([Math]::Floor(($idx / $total) * 100)) "Hole $idx/$total"

    $macro = Build-HoleMacro -PointId $ptId -Diameter $holeDia -BodyIndex $bodyIndex
    $changed = $false
    try {
        $stamp = $model.VersionStamp
        $session.RunMacro($macro)
        $changed = Wait-ModelModified -Model $model -PreviousStamp $stamp
    } catch {
        $failed++
    }
    if ($changed) { $made++ } else { $noop++ }

    # canary: after the FIRST hole, require the model to have changed.
    if ($idx -eq 1 -and -not $changed) {
        Show-Progress 100 "Canary failed"
        Write-Host ""
        Write-Host "  ABORT: the first hole did not modify the model (VersionStamp" -ForegroundColor Red
        Write-Host "  unchanged). Stopped after 1 attempt. Check Creo: did the hole" -ForegroundColor Red
        Write-Host "  dashboard open / error? The recorded widget names may need a" -ForegroundColor Red
        Write-Host "  refresh for this Creo build." -ForegroundColor Red
        $aborted = $true
        break
    }
}
if (-not $aborted) { Show-Progress 100 "Done" }
Write-Host ""

# ============================================
# REPORT
# ============================================
Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
Write-Host ("  Points targeted   : {0}" -f $total) -ForegroundColor White
Write-Host ("  Holes attempted   : {0}" -f $idx) -ForegroundColor White
Write-Host ("  Model changed     : {0}" -f $made) -ForegroundColor White
if ($noop   -gt 0) { Write-Host ("  No-op (no change) : {0}" -f $noop) -ForegroundColor Yellow }
if ($failed -gt 0) { Write-Host ("  Macro errors      : {0}" -f $failed) -ForegroundColor Yellow }
Write-Host ""
if ($aborted) {
    Write-Host "  STOPPED after the canary -- inspect the model in Creo." -ForegroundColor Red
} elseif ($made -eq $total -and $failed -eq 0) {
    Write-Host "  Done -- $made hole(s) created (model changed for each)." -ForegroundColor Green
    Write-Host "  Verify the holes visually in Creo." -ForegroundColor DarkGray
} else {
    Write-Host "  Finished with issues -- $made of $total changed the model. Inspect Creo." -ForegroundColor Yellow
}

} finally {
    try {
        if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null }
        if ($null -ne $origDynamicPreview)  { $session.SetConfigOption("dynamic_preview",  $origDynamicPreview)  | Out-Null }
    } catch {}
    try { $connection.Disconnect($null) } catch {}
}
