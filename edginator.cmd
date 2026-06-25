<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

# ============================================================================
# edginator.cmd - round the edges of a given DIMENSION (length), HANDS-FREE
# ============================================================================
# "Find an edge with a certain dimension, then round those corners" with NO
# geometry selection by the user. You give a target edge length; the tool finds
# every matching edge itself, selects them through the VB API, and rounds them.
#
# THE PIPELINE - all four steps proven live on the imported/"foreign" jig body
# (vbselect-probe.cmd, 2026-06-24, part 004-826-0638-001):
#   1. DISCOVER (no selection): sweep $model.GetItemById(ITEM_EDGE, 1..N). On a
#      foreign body ListItems(ITEM_EDGE) returns 0 and the find tool is dead for
#      ALL selection (incl. by-ID) - but GetItemById resolves edges directly.
#      Live: 28 edges resolved in 1.9s with no pick; the manually-picked ids were
#      among them. See [[project_find_edge_by_length]].
#   2. MEASURE: $edge.EvalLength() off each resolved edge (proven).
#   3. FILTER (PowerShell): keep edges within tol of the target length. The Search
#      tool CANNOT filter edges by length - this MUST happen in code.
#   4. SELECT + ROUND (NO find tool): CMpfcSelect.CreateModelItemSelection(edge,
#      $null) -> ($session.CurrentSelectionBuffer()).AddSelection(sel), then the
#      proven round mapkey. Clear()+AddSelection reselection is proven; building
#      the Selection from a swept edge via CreateModelItemSelection is the one
#      newer link, so the tool SELF-TESTS it on one edge before rounding anything.
#
# Manual pick remains a FALLBACK (if the sweep finds nothing, or the API select
# factory is unavailable): then it re-adds the original buffered IpfcSelection
# objects (Path 1a, proven) instead of building them from scratch.
#
# Verification is a VersionStamp change per batch - NOT a geometric measurement.
# The success count is BATCHES FIRED, not rounds Creo accepted; verify visually.
#
# NO MAPKEY drives selection anymore - only the round itself is a mapkey. Args:
#   -v / --verbose     extra logging
#   --sweep N          max edge id to sweep (default 5000)
# ============================================================================

$Host.UI.RawUI.WindowTitle = "EDGINATOR (hands-free)"
$Verbose = $ScriptArgs -match '(?i)-v|--verbose'
$ErrorActionPreference = "Stop"
$startTime = Get-Date

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

$script:lastPct = -1
function Show-Progress {
    param([int]$Pct, [string]$Label)
    if ($Pct -eq $script:lastPct) { return }
    $script:lastPct = $Pct
    $filled = [Math]::Floor($Pct / 5)
    $empty = 20 - $filled
    $bar = ([char]9608).ToString() * $filled + ([char]9617).ToString() * $empty
    $color = if ($Pct -ge 100) { "Green" } else { "White" }
    $shortLabel = if ($Label.Length -gt 60) { $Label.Substring(0, 60) } else { $Label }
    Write-Host "`r  [$bar] $($Pct.ToString().PadLeft(3))%  $shortLabel   " -NoNewline -ForegroundColor $color
    if ($Pct -ge 100) { Write-Host "" }
}

# ============================================================================
# HELPERS
# ============================================================================

# $true if VersionStamp changed within the timeout (the round modified the model).
function Wait-ModelModified {
    param($Model, [string]$PreviousStamp, [int]$TimeoutMs = 30000)
    $deadline = [DateTime]::Now.AddMilliseconds($TimeoutMs)
    while ([DateTime]::Now -lt $deadline) {
        try { if ($Model.VersionStamp -ne $PreviousStamp) { return $true } } catch {}
    }
    return $false
}

# The proven round mapkey for the edges already in the selection buffer
# (radinator.cmd:512-519, verbatim). ONE atomic RunMacro. This is the ONLY mapkey
# in the tool - selection is now pure COM, so nothing else can drift on widgets.
function Build-RoundMacro {
    param([double]$Radius)
    return "~ Activate ``main_dlg_cur`` ``page_Model_control_btn`` 1;" +
        "~ Command ``ProCmdRound``;" +
        "~ Input ``main_dlg_cur`` ``maindashInst0.cir_rad_list`` ``$Radius``;" +
        "~ Update ``main_dlg_cur`` ``maindashInst0.cir_rad_list`` ``$Radius``;" +
        "~ Activate ``main_dlg_cur`` ``maindashInst0.cir_rad_list``;" +
        "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"
}

# DISCOVER edges hands-free: sweep GetItemById(ITEM_EDGE, 1..MaxId), keeping every
# id that resolves to an edge with a readable EvalLength. No selection, no find
# tool. Returns @(@{Id;Length;Sel=$null}).
function Get-EdgesBySweep {
    param($Model, $TypeObj, [int]$MaxId)
    $edges = @()
    $et = $TypeObj.ITEM_EDGE
    for ($id = 1; $id -le $MaxId; $id++) {
        if (($id % 250) -eq 0) { Show-Progress ([Math]::Floor(($id / $MaxId) * 100)) "Sweeping edge ids" }
        $ed = $null
        try { $ed = $Model.GetItemById($et, $id) } catch { continue }
        if ($null -eq $ed) { continue }
        $len = $null
        try { $len = [double]$ed.EvalLength() } catch {}
        if ($null -ne $len) { $edges += @{ Id = $id; Length = $len; Sel = $null } }
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ed) | Out-Null } catch {}
    }
    Show-Progress 100 "Sweep complete"
    return @($edges)
}

# Resolve the CMpfcSelect factory by trying candidate ProgIDs and a real
# CreateModelItemSelection call on a known edge id - the CM*/CC* factory names are
# never standalone ProgIDs (pfcRegenInstructions lesson), so we discover which
# prefix-dropped ProgID actually works. Returns @{Cls;ProgId} or $null.
function Resolve-SelectFactory {
    param($Model, $TypeObj, [int]$TestId)
    $candidates = @('pfcls.pfcSelect', 'pfcls.MpfcSelect', 'pfcls.CMpfcSelect', 'pfcls.pfcSelectClass')
    foreach ($progId in $candidates) {
        try {
            $cls = New-Object -ComObject $progId
            $ed = $Model.GetItemById($TypeObj.ITEM_EDGE, $TestId)
            $sel = $cls.CreateModelItemSelection($ed, $null)
            if ($null -ne $sel) { Write-Log "select factory: $progId works"; return @{ Cls = $cls; ProgId = $progId } }
        } catch { Write-Log "select factory $progId failed: $($_.Exception.Message)" }
    }
    return $null
}

# Read the edge ids currently in the selection buffer (self-test verification).
function Get-BufferEdgeIds {
    param($Session)
    $ids = @(); $c = $null
    try { $c = ($Session.CurrentSelectionBuffer()).Contents } catch {}
    if ($null -eq $c) { return @() }
    foreach ($it in $c) { try { $ids += [int]$it.SelItem.Id } catch {} }
    return @($ids)
}

# SELECT a set of edges via the API (NO find tool): Clear the buffer, then for each
# edge add it. Manual-sourced edges carry their original IpfcSelection ($e.Sel) and
# are re-added directly (Path 1a, proven). Sweep-sourced edges ($e.Sel = $null) are
# refetched by id and wrapped via the factory (Path 2). Returns count added.
function Select-EdgesViaApi {
    param($Session, $Model, $TypeObj, $Edges, $Factory)
    try { ($Session.CurrentSelectionBuffer()).Clear() } catch {}
    $added = 0
    foreach ($e in $Edges) {
        $sel = $null
        if ($null -ne $e.Sel) {
            $sel = $e.Sel
        } elseif ($null -ne $Factory) {
            $ed = $null
            try { $ed = $Model.GetItemById($TypeObj.ITEM_EDGE, [int]$e.Id) } catch {}
            if ($null -ne $ed) {
                try { $sel = $Factory.Cls.CreateModelItemSelection($ed, $null) } catch {}
            }
        }
        if ($null -eq $sel) { continue }
        try { ($Session.CurrentSelectionBuffer()).AddSelection($sel); $added++ } catch {}
    }
    return $added
}

# Manual-pick fallback: read the user's current selection into @(@{Id;Length;Sel})
# keeping the original IpfcSelection so it can be re-added without the factory.
function Resolve-SelectedEdges {
    param($Session, $TypeObj)
    $edges = @(); $seen = @{}
    $c = $null
    try { $c = ($Session.CurrentSelectionBuffer()).Contents } catch {}
    if ($null -eq $c) { return @() }
    foreach ($it in $c) {
        $si = $null
        try { $si = $it.SelItem } catch {}
        if ($null -eq $si) { continue }
        $isEdge = $false
        try { $isEdge = ([int]$si.Type -eq [int]$TypeObj.ITEM_EDGE) } catch {}
        if (-not $isEdge) { continue }
        $id = $null
        try { $id = [int]$si.Id } catch {}
        if ($null -eq $id -or $seen.ContainsKey($id)) { continue }
        $len = $null
        try { $len = [double]$si.EvalLength() } catch {}
        if ($null -eq $len) { continue }
        $seen[$id] = $true
        $edges += @{ Id = $id; Length = $len; Sel = $it }
    }
    return @($edges)
}

# Length distribution grouped by rounded length (so the user picks a target).
function Show-LengthDistribution {
    param($Edges, [int]$Decimals = 4)
    $groups = @{}
    foreach ($e in $Edges) {
        $key = [math]::Round([double]$e.Length, $Decimals)
        if (-not $groups.ContainsKey($key)) { $groups[$key] = 0 }
        $groups[$key]++
    }
    Write-Host "  Length distribution of the $($Edges.Count) edge(s):" -ForegroundColor Cyan
    foreach ($k in ($groups.Keys | Sort-Object { [double]$_ })) {
        $count = $groups[$k]
        $bar = ([char]9608).ToString() * [Math]::Min(40, $count)
        Write-Host ("    {0,12}  x{1,-4} {2}" -f $k, $count, $bar) -ForegroundColor White
    }
}

# ============================================================================
# HEADER + INPUT
# ============================================================================
Write-Host ""
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "   EDGINATOR  -  round edges of a given dimension (HANDS-FREE)" -ForegroundColor Cyan
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Finds matching edges itself (no geometry selection) and rounds them." -ForegroundColor Green
Write-Host "  Open the jig PART (not .asm). Do not interact with Creo while it runs." -ForegroundColor White
Write-Host ""

$RadiusValue = 0.25
$raw = Read-Host "  Round radius (blank -> 0.25)"
if (-not [string]::IsNullOrWhiteSpace($raw)) {
    $rv = 0.0
    if ([double]::TryParse($raw.Trim(), [ref]$rv) -and $rv -gt 0) { $RadiusValue = $rv }
    else { Write-Host "  Not a positive number - using 0.25" -ForegroundColor Yellow }
}
Write-Host "  Radius: $RadiusValue" -ForegroundColor Green

$sweepMax = 5000
$argRange = [regex]::Match($ScriptArgs, '(?i)(?:-sweep|--sweep)\s+(\d+)')
if ($argRange.Success) { $sweepMax = [int]$argRange.Groups[1].Value }
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
$model = $null
try { $model = $session.GetActiveModel() } catch {}
if ($null -eq $model) { try { $model = $session.CurrentModel } catch {} }

if ($null -eq $model) {
    Write-Host ""
    Write-Host "  FAILED: No model open in Creo." -ForegroundColor Red
    exit 1
}

Write-Host " Connected to $($model.FileName)" -ForegroundColor Green

$modelFile = ""
try { $modelFile = [string]$model.FileName } catch {}
if ($modelFile -match '\.asm(\.\d+)?$') {
    Write-Host ""
    Write-Host "  STOP: active model is an ASSEMBLY ($modelFile). Open the PART, re-run." -ForegroundColor Yellow
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
# STEP 1 - DISCOVER edges (hands-free sweep; manual pick only as a fallback)
# ============================================================================
Write-Host ""
Write-Host "  STEP 1 - discovering edges by id sweep (1..$sweepMax), no selection..." -ForegroundColor Cyan
$cand = @(Get-EdgesBySweep -Model $model -TypeObj $modelItemType -MaxId $sweepMax)
$source = "sweep"
Write-Host "  Found $($cand.Count) edge(s) by sweep." -ForegroundColor $(if ($cand.Count -gt 0) { "Green" } else { "Yellow" })

if ($cand.Count -eq 0) {
    Write-Host ""
    Write-Host "  Sweep found no edges (GetItemById may be dead on this body, or ids exceed" -ForegroundColor Yellow
    Write-Host "  $sweepMax - retry with --sweep <larger>). Falling back to MANUAL pick." -ForegroundColor Yellow
    Write-Host "  In Creo, select the candidate edges by hand, then press ENTER." -ForegroundColor Cyan
    Read-Host
    $cand = @(Resolve-SelectedEdges -Session $session -TypeObj $modelItemType)
    $source = "manual"
    Write-Host "  Captured $($cand.Count) edge(s) from your selection." -ForegroundColor $(if ($cand.Count -gt 0) { "Green" } else { "Yellow" })
}

if ($cand.Count -eq 0) {
    Write-Host "  No edges to work with - nothing to do." -ForegroundColor Yellow
}
else {
    # ========================================================================
    # STEP 2 - length spread; AUTO-select the LOWEST dimensional value
    # ========================================================================
    # Default (NO prompt): round every edge whose length equals the smallest
    # length present. On a plate the shortest edges are the through-thickness
    # corner edges - i.e. "round the corners". Override without prompting via
    # --target <len> (optional --tol <t>); there is no interactive target prompt.
    Write-Host ""
    Show-LengthDistribution -Edges $cand
    Write-Host ""

    $targetLen = $null
    $tol = 0.01
    $mTol = [regex]::Match($ScriptArgs, '(?i)(?:-tol|--tol)\s+([0-9]*\.?[0-9]+)')
    if ($mTol.Success) { $tol = [double]$mTol.Groups[1].Value }
    $mTgt = [regex]::Match($ScriptArgs, '(?i)(?:-target|--target)\s+([0-9]*\.?[0-9]+)')
    if ($mTgt.Success) { $targetLen = [double]$mTgt.Groups[1].Value }

    if ($null -eq $targetLen) {
        # AUTO: the lowest dimensional value present (smallest edge length).
        $minLen = ($cand | ForEach-Object { [double]$_.Length } | Measure-Object -Minimum).Minimum
        $targetLen = [math]::Round([double]$minLen, 4)
        Write-Host "  Auto-target = LOWEST edge length present: $targetLen (+/- $tol)" -ForegroundColor Cyan
    } else {
        Write-Host "  Target (--target): $targetLen (+/- $tol)" -ForegroundColor Cyan
    }

    # ========================================================================
    # FILTER by the target dimension (in PowerShell - the Search tool can't)
    # ========================================================================
    $matchEdges = @($cand | Where-Object { [Math]::Abs([double]$_.Length - $targetLen) -le $tol })
    Write-Host ""
    Write-Host "  $($matchEdges.Count) of $($cand.Count) edge(s) match length $targetLen +/- $tol :" -ForegroundColor Green
    foreach ($m in ($matchEdges | Sort-Object { [double]$_.Length })) {
        Write-Host ("    edge $($m.Id)   length $([math]::Round([double]$m.Length,4))") -ForegroundColor White
    }

    if ($matchEdges.Count -eq 0) {
        Write-Host ""
        Write-Host "  No edges matched - re-run and adjust the target/tolerance." -ForegroundColor Yellow
    }
    else {
        # ====================================================================
        # SELECT FACTORY + LIVE SELF-TEST (gate before any mutation)
        # ====================================================================
        # Sweep-sourced edges need CreateModelItemSelection (Path 2); resolve the
        # factory. Manual-sourced edges carry their own Selection (Path 1a) so no
        # factory is needed. Then self-test: select exactly ONE matched edge via the
        # API and confirm the buffer holds exactly it. If that fails we abort (or
        # fall back to manual) WITHOUT rounding - no geometry on a broken primitive.
        $factory = $null
        if ($source -eq "sweep") {
            $factory = Resolve-SelectFactory -Model $model -TypeObj $modelItemType -TestId ([int]$matchEdges[0].Id)
            if ($null -eq $factory) {
                Write-Host ""
                Write-Host "  API select factory (CreateModelItemSelection) not available on this build." -ForegroundColor Yellow
                Write-Host "  Falling back to MANUAL pick of the edges to round." -ForegroundColor Yellow
                Write-Host "  In Creo, select the edges to round, then press ENTER." -ForegroundColor Cyan
                Read-Host
                $manual = @(Resolve-SelectedEdges -Session $session -TypeObj $modelItemType)
                if ($manual.Count -gt 0) { $matchEdges = $manual; $source = "manual" }
            }
        }

        Write-Host ""
        Write-Host "  Self-testing API selection on edge $($matchEdges[0].Id)..." -ForegroundColor Cyan
        $stLanded = Select-EdgesViaApi -Session $session -Model $model -TypeObj $modelItemType -Edges @($matchEdges[0]) -Factory $factory
        $stBuf = @(Get-BufferEdgeIds -Session $session)
        $selfOk = ($stLanded -ge 1 -and $stBuf.Count -eq 1 -and [int]$stBuf[0] -eq [int]$matchEdges[0].Id)
        if ($selfOk) {
            Write-Host "  Self-test PASS - the API selected exactly edge $($matchEdges[0].Id)." -ForegroundColor Green
        } else {
            Write-Host "  Self-test FAILED - API selection did not land exactly the test edge" -ForegroundColor Red
            Write-Host "  (landed=$stLanded, buffer=[$($stBuf -join ', ')]). NOT rounding." -ForegroundColor Red
            Write-Host "  Selection cannot be driven on this body via the API path; aborting safely." -ForegroundColor Red
        }

        if ($selfOk) {
            Write-Host ""
            Write-Host ("  Rounding $($matchEdges.Count) edge(s) at radius $RadiusValue (source: $source) - proceeding automatically.") -ForegroundColor Cyan
            Write-Host "  Monitor Creo and click Ok if any rounds fail. You can fix them after." -ForegroundColor Gray
            Write-Host ""

                $matchIds = @($matchEdges | ForEach-Object { [int]$_.Id })
                $batchSize = 40
                $totalBatches = [Math]::Ceiling($matchEdges.Count / $batchSize)
                $batchNum = 0
                $batchesFired = 0
                $modelChanged = 0
                $aborted = $false
                $script:lastPct = -1

                for ($batchStart = 0; $batchStart -lt $matchEdges.Count; $batchStart += $batchSize) {
                    $batchNum++
                    $batchEnd = [Math]::Min($batchStart + $batchSize, $matchEdges.Count)
                    $batchEdges = @($matchEdges[$batchStart..($batchEnd - 1)])

                    Show-Progress ([Math]::Floor(($batchEnd / $matchEdges.Count) * 100)) "Batch $batchNum/$totalBatches"

                    $stamp = $null
                    try { $stamp = $model.VersionStamp } catch {}

                    # SELECT this batch via the API (no find tool), then round.
                    $landed = Select-EdgesViaApi -Session $session -Model $model -TypeObj $modelItemType -Edges $batchEdges -Factory $factory

                    $changed = $false
                    try {
                        $session.RunMacro((Build-RoundMacro -Radius $RadiusValue))
                        $batchesFired++
                        if ($null -ne $stamp) { $changed = Wait-ModelModified -Model $model -PreviousStamp $stamp }
                    } catch {
                        Write-Log "Batch $batchNum round error: $($_.Exception.Message)" "Yellow"
                    }
                    if ($changed) { $modelChanged++ }

                    if ($batchNum -eq 1 -and -not $changed) {
                        Show-Progress 100 "Canary failed"
                        Write-Host ""
                        Write-Host "  ABORT: the first round batch did not modify the model" -ForegroundColor Red
                        Write-Host "  (VersionStamp unchanged; $landed edge(s) were selected). Stopped after" -ForegroundColor Red
                        Write-Host "  1 batch. The round mapkey (Build-RoundMacro) may need a refresh, or the" -ForegroundColor Red
                        Write-Host "  selected edges cannot take this radius." -ForegroundColor Red
                        $aborted = $true
                        break
                    }
                }
                if (-not $aborted) { Show-Progress 100 "Rounds complete" }
                Write-Host ""

                Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
                Write-Host ("  Edge source       : {0}" -f $source) -ForegroundColor White
                Write-Host ("  Edges matched     : {0}" -f $matchEdges.Count) -ForegroundColor White
                Write-Host ("  Batches fired     : {0}" -f $batchesFired) -ForegroundColor White
                Write-Host ("  Model changed     : {0} batch(es)" -f $modelChanged) -ForegroundColor White
                Write-Host ""
                if ($aborted) {
                    Write-Host "  STOPPED after the canary - inspect the model in Creo." -ForegroundColor Red
                } elseif ($modelChanged -eq $totalBatches) {
                    Write-Host "  Done - round feature(s) created (model changed for each batch)." -ForegroundColor Green
                    Write-Host "  NOTE: a count of batches FIRED, not rounds Creo geometrically" -ForegroundColor DarkGray
                    Write-Host "  accepted. Verify the rounded edges visually in Creo." -ForegroundColor DarkGray
                } else {
                    Write-Host "  Finished with issues - $modelChanged of $totalBatches batch(es) changed the model. Inspect Creo." -ForegroundColor Yellow
                }
        }
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
