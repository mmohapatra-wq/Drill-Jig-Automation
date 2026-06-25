<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

# ============================================================================
# cornerinator-probe.cmd - READ-ONLY find-tool "select-all edges" vocabulary probe
# ============================================================================
# PURPOSE: pin down the ONE unverified piece of cornerinator's auto-detect path -
# the "select ALL edges into the selection buffer" widget names. Research
# (2026-06-23) established:
#   * Creo's Search Tool CANNOT filter edges by length - so finding "an edge with
#     a certain dimension" MUST be: select edges -> read the buffer -> filter by
#     EvalLength() in PowerShell. cornerinator's architecture is already correct.
#   * The pure-API bypass (ListItems/GetItemById -> CreateModelItemSelection ->
#     AddSelection) is DEAD on the imported/foreign jig body - it needs the same
#     COM enumeration that returns 0 edges there.
#   * The ENTIRE find-tool->buffer->filter->reselect-by-ID->round pipeline is
#     live-proven EXCEPT the select-all step's widget names (FindNowBtn/SelAllBtn).
#
# This probe fires FOUR candidate "select all edges" macros - each a minimal delta
# from radinator's VERBATIM proven open-find-tool skeleton (radinator.cmd:470-507)
# - and reports, for each, how many items landed in the selection buffer and how
# many are edges. The macro that fills the buffer names the real vocabulary; we
# then wire it into a length-targeted rounding tool.
#
# READ-ONLY: it opens/closes the Search dialog and pushes selections into the
# buffer. It fires NO ProCmdRound, NO feature creation, NO DimValue write - the
# model is NEVER mutated (VersionStamp does not change from selection alone).
#
# It also independently confirms the load-bearing assumption (openQuestion #2):
# that a find-tool-buffered edge on a FOREIGN body exposes .EvalLength() - by
# reading Id/Type/EvalLength off whatever lands in the buffer, and via a final
# optional manual single-edge pick.
# ============================================================================

$Host.UI.RawUI.WindowTitle = "CORNERINATOR-PROBE (read-only)"
$Verbose = $ScriptArgs -match '(?i)-v|--verbose'
$ErrorActionPreference = "Stop"

trap {
    Write-Host ""
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
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
# The PROVEN open-find-tool skeleton, VERBATIM from radinator.cmd:470-476. Every
# probe shares this prefix; they differ only in how they try to "select all" once
# the rule is set to All. Keeping the shared prefix identical to the proven path
# means a probe that fails localizes the failure to the select-all delta, not the
# skeleton.
# ----------------------------------------------------------------------------
$openEdgeSearch =
    "~ Command ``ProCmdMdlTreeSearch``;" +
    "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Edge``;" +
    "~ Select ``selspecdlg0`` ``LookByOptionMenu`` 1 ``Edge``;" +
    "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Attributes``;" +
    "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
    "~ Select ``selspecdlg0`` ``RuleTypes`` 1 ``All``;"

$closeSearch = "~ Activate ``selspecdlg0`` ``CancelButton``;"

# The four candidate select-all sequences (each is the shared prefix + a delta).
# Ordered cheapest-hypothesis-first: P1 assumes the two guessed widgets are
# unnecessary; P4 is the pure proven skeleton as a baseline.
$probes = @(
    @{
        Label = "P1"
        Desc  = "RuleTypes=All, then EvaluateBtn + ApplyBtn ONLY (drop guessed FindNowBtn/SelAllBtn)"
        Macro = $openEdgeSearch +
                "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
                "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
                $closeSearch
        Hyp   = "EvaluateBtn already runs the search AND ApplyBtn transfers all matches -> the guessed widgets are redundant."
    },
    @{
        Label = "P2"
        Desc  = "+ FindNowBtn between EvaluateBtn and ApplyBtn"
        Macro = $openEdgeSearch +
                "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
                "~ Activate ``selspecdlg0`` ``FindNowBtn``;" +
                "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
                $closeSearch
        Hyp   = "A distinct FindNowBtn is needed to populate Items-Found before ApplyBtn transfers them."
    },
    @{
        Label = "P3"
        Desc  = "+ FindNowBtn + SelAllBtn (the EXACT current cornerinator guess, as control)"
        Macro = $openEdgeSearch +
                "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
                "~ Activate ``selspecdlg0`` ``FindNowBtn``;" +
                "~ Activate ``selspecdlg0`` ``SelAllBtn``;" +
                "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
                $closeSearch
        Hyp   = "Both guessed widgets are real and required (cornerinator's current Get-EdgesViaFindTool)."
    },
    @{
        Label = "P4"
        Desc  = "Proven skeleton toggled RuleTypes All->ID with NO id entered (baseline)"
        Macro = $openEdgeSearch +
                "~ Select ``selspecdlg0`` ``RuleTypes`` 1 ``ID``;" +
                "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
                "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
                $closeSearch
        Hyp   = "Diagnostic baseline: does an empty-ID rule select nothing (expected -> a real select-all widget IS needed) or everything?"
    }
)

# ----------------------------------------------------------------------------
# Read the selection buffer and summarise: total items, how many are edges, and
# a sample of Id/Type/EvalLength off the first few (the load-bearing confirmation
# that a buffered FOREIGN-body edge exposes EvalLength). ID-ONLY otherwise - no
# coordinate reads (holeinator's lesson).
# ----------------------------------------------------------------------------
function Read-BufferEdges {
    param($Session, $TypeObj, [int]$SampleMax = 6)
    $contents = $null
    try { $contents = ($Session.CurrentSelectionBuffer()).Contents } catch {}
    if ($null -eq $contents) { return @{ Count = 0; EdgeCount = 0; Samples = @(); LenReadOk = $false } }

    $count = 0; $edgeCount = 0; $lenReadOk = $false
    $samples = @()
    foreach ($item in $contents) {
        $count++
        $si = $null
        try { $si = $item.SelItem } catch { continue }
        if ($null -eq $si) { continue }
        $isEdge = $false
        try { $isEdge = ([int]$si.Type -eq [int]$TypeObj.ITEM_EDGE) } catch {}
        if ($isEdge) { $edgeCount++ }
        if ($samples.Count -lt $SampleMax) {
            $sid = "?"; $stype = "?"; $slen = $null
            try { $sid = [int]$si.Id } catch {}
            try { $stype = [string]$si.Type } catch {}
            try { $slen = [double]$si.EvalLength(); $lenReadOk = $true } catch {}
            $samples += @{ Id = $sid; Type = $stype; Len = $slen; IsEdge = $isEdge }
        }
    }
    return @{ Count = $count; EdgeCount = $edgeCount; Samples = @($samples); LenReadOk = $lenReadOk }
}

# Best-effort reset to a clean state between probes: close any open Search dialog,
# then clear the buffer. Both wrapped - a left-open dialog from a failed macro is
# the main hazard, so we try to close it even if it errors.
function Reset-FindToolAndBuffer {
    param($Session)
    try { $Session.RunMacro("~ Activate ``selspecdlg0`` ``CancelButton``;") } catch {}
    try { $Session.RunMacro("~ Command ``ProCmdSelClear``;") } catch {}
}

# ============================================================================
# HEADER
# ============================================================================
Write-Host ""
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "   CORNERINATOR-PROBE  -  read-only find-tool select-all vocabulary" -ForegroundColor Cyan
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  READ-ONLY: opens/closes the Search dialog and selects edges into the" -ForegroundColor Green
Write-Host "  buffer. Fires NO round, NO feature creation - the model is NOT mutated." -ForegroundColor Green
Write-Host ""
Write-Host "  Prerequisites:" -ForegroundColor Green
Write-Host "    1. The jig PART (not .asm) open in Creo - the SAME foreign body" -ForegroundColor White
Write-Host "       cornerinator targets, so the probe reflects the real layer." -ForegroundColor White
Write-Host "    2. Do not interact with Creo during the probe." -ForegroundColor White
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
# GetActiveModel() first (the proven-live holeinator/drilljig accessor); fall back
# to CurrentModel.
$model = $null
try { $model = $session.GetActiveModel() } catch {}
if ($null -eq $model) { try { $model = $session.CurrentModel } catch {} }

if ($null -eq $model) {
    Write-Host ""
    Write-Host "  FAILED: No model open in Creo." -ForegroundColor Red
    exit 1
}

Write-Host " Connected to $($model.FileName)" -ForegroundColor Green

# Mode guard: by-ID / buffer selection resolves against the active model. In
# assembly mode that is the .asm, not the part. Key off the filename extension
# (EpfcModelType enum ints unconfirmed on this build - drilljig lesson).
$modelFile = ""
try { $modelFile = [string]$model.FileName } catch {}
if ($modelFile -match '\.asm(\.\d+)?$') {
    Write-Host ""
    Write-Host "  STOP: the active model is an ASSEMBLY ($modelFile)." -ForegroundColor Yellow
    Write-Host "  Open the jig PART itself, then re-run." -ForegroundColor Yellow
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

# ============================================================================
# FIRE THE PROBES
# ============================================================================
$results = @()
try {
    Write-Host ""
    Write-Host "  Firing $($probes.Count) candidate select-all macros (read-only)..." -ForegroundColor Cyan
    Write-Host "  Each is radinator's PROVEN open-find-tool skeleton + a select-all delta." -ForegroundColor DarkGray
    Write-Host ""

    foreach ($p in $probes) {
        Reset-FindToolAndBuffer -Session $session

        Write-Host "  ----------------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host "  [$($p.Label)] $($p.Desc)" -ForegroundColor White
        Write-Host "       hypothesis: $($p.Hyp)" -ForegroundColor DarkGray

        $err = $null
        try {
            $session.RunMacro($p.Macro)
        } catch {
            $err = $_.Exception.Message
        }

        # Read the buffer AFTER the macro (Apply commits to the buffer; CancelButton
        # closes without discarding - radinator's proven sequencing).
        $r = Read-BufferEdges -Session $session -TypeObj $modelItemType

        $verdict = if ($r.Count -gt 0) { "BUFFER FILLED" } else { "buffer empty" }
        $vcolor  = if ($r.Count -gt 0) { "Green" } else { "Yellow" }
        Write-Host "       result: $verdict  -  $($r.Count) item(s), $($r.EdgeCount) edge(s)" -ForegroundColor $vcolor
        if ($null -ne $err) {
            Write-Host "       RunMacro error: $err" -ForegroundColor Yellow
            Write-Host "       (an 'unknown widget' name here is the invalid guess for THIS probe)" -ForegroundColor DarkGray
        }
        if ($r.Samples.Count -gt 0) {
            foreach ($s in $r.Samples) {
                $lenStr = if ($null -ne $s.Len) { [math]::Round($s.Len, 4) } else { "<EvalLength unreadable>" }
                Write-Host "         sample: id $($s.Id)  type $($s.Type)  EvalLength $lenStr" -ForegroundColor DarkGray
            }
            $lenNote = if ($r.LenReadOk) { "EvalLength READS off buffered edges (foreign-body assumption CONFIRMED)" } else { "EvalLength did NOT read - the length-filter assumption FAILS for this source" }
            Write-Host "       $lenNote" -ForegroundColor $(if ($r.LenReadOk) { "Green" } else { "Red" })
        }

        $results += @{ Label = $p.Label; Desc = $p.Desc; Count = $r.Count; EdgeCount = $r.EdgeCount; Err = $err; LenReadOk = $r.LenReadOk }
        Write-Host ""
    }

    Reset-FindToolAndBuffer -Session $session

    # ========================================================================
    # SUMMARY
    # ========================================================================
    Write-Host "  ================================================================" -ForegroundColor Cyan
    Write-Host "   SUMMARY" -ForegroundColor Cyan
    Write-Host "  ================================================================" -ForegroundColor Cyan
    foreach ($r in $results) {
        $tag = if ($r.Count -gt 0) { "FILLED ($($r.EdgeCount) edges)" } else { "empty" }
        $col = if ($r.Count -gt 0) { "Green" } else { "DarkGray" }
        $errTag = if ($null -ne $r.Err) { "  [err: $($r.Err)]" } else { "" }
        Write-Host ("    {0} : {1}{2}" -f $r.Label.PadRight(4), $tag, $errTag) -ForegroundColor $col
    }
    Write-Host ""
    $winners = @($results | Where-Object { $_.Count -gt 0 })
    if ($winners.Count -gt 0) {
        $w = $winners[0]
        Write-Host "  WINNER: $($w.Label) filled the buffer with $($w.EdgeCount) edge(s)." -ForegroundColor Green
        Write-Host "  -> its widget sequence is the real 'select all edges' vocabulary." -ForegroundColor Green
        Write-Host "  -> paste this whole output back; I will wire $($w.Label) into the" -ForegroundColor Green
        Write-Host "     length-targeted rounding tool (filter by EvalLength in PowerShell)." -ForegroundColor Green
    } else {
        Write-Host "  No probe filled the buffer. The select-all vocabulary is none of these." -ForegroundColor Yellow
        Write-Host "  Next step: record it live with visible_mapkeys=yes (search Edges ->" -ForegroundColor Yellow
        Write-Host "  Find Now -> select all rows -> Add/Apply -> Close) and paste the" -ForegroundColor Yellow
        Write-Host "  exact ~ Activate lines. Manual-pick rounding always remains available." -ForegroundColor Yellow
    }
    Write-Host ""

    # ========================================================================
    # OPTIONAL: manual single-edge pick - independent EvalLength confirmation
    # ========================================================================
    Write-Host "  ----------------------------------------------------------------" -ForegroundColor DarkGray
    $doManual = Read-Host "  Independently confirm EvalLength via a manual pick? Select 1 edge in Creo then y (y/N)"
    if ($doManual -match '^[Yy]$') {
        Reset-FindToolAndBuffer -Session $session
        Write-Host "  In Creo, select ONE edge by hand, then press ENTER here." -ForegroundColor Cyan
        Read-Host
        $rm = Read-BufferEdges -Session $session -TypeObj $modelItemType -SampleMax 3
        if ($rm.Count -eq 0) {
            Write-Host "  Buffer empty - nothing picked." -ForegroundColor Yellow
        } else {
            foreach ($s in $rm.Samples) {
                $lenStr = if ($null -ne $s.Len) { [math]::Round($s.Len, 4) } else { "<unreadable>" }
                Write-Host "    picked: id $($s.Id)  type $($s.Type)  EvalLength $lenStr" -ForegroundColor Green
            }
            if ($rm.LenReadOk) {
                Write-Host "  Manual-pick EvalLength READS - the length filter is sound on this body." -ForegroundColor Green
            } else {
                Write-Host "  Manual-pick EvalLength did NOT read - investigate before length-filtering." -ForegroundColor Red
            }
        }
    }

} finally {
    Reset-FindToolAndBuffer -Session $session
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
Write-Host "  Probe complete (read-only - nothing was modified)." -ForegroundColor Cyan
Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
