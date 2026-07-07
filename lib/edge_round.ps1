# ============================================================================
# lib\edge_round.ps1 - HANDS-FREE edge rounding by dimension (no find tool)
# ============================================================================
# Extracted from edginator.cmd (proven-live 2026-06-24 on the imported/"foreign"
# jig body 004-826-0638-001). The pipeline, all four steps live-proven:
#   1. DISCOVER (no selection): sweep $model.GetItemById(ITEM_EDGE, 1..N). On a
#      foreign body ListItems(ITEM_EDGE)=0 and the find tool is dead for ALL
#      selection - but GetItemById resolves edges directly (28 edges in 1.9s).
#   2. MEASURE: $edge.EvalLength() off each.
#   3. SELECT (no find tool): CMpfcSelect.CreateModelItemSelection(edge,$null) ->
#      ($session.CurrentSelectionBuffer()).AddSelection(sel). Proven via probe.
#   4. ROUND: the proven ProCmdRound mapkey (radinator), VersionStamp canary.
# See [[project_find_edge_by_length]].
#
# Repo lib convention: every function takes its COM objects as params (no
# module-level $session/$model) so the file dot-sources in a plain host and the
# pure pieces (Select-LowestDimensionEdges) unit-test offline. Functions are
# uniquely named (EdgeRound / AutoCornerRound) so dot-sourcing into a tool that
# already defines Wait-ModelModified / Build-RoundMacro does NOT clash.
#
# Used by: drilljig.cmd STAGE 2 (auto-round the box corners right after extrude).
# ============================================================================

# The proven round mapkey for whatever edges are already in the selection buffer
# (radinator.cmd:512-519, verbatim). ONE atomic RunMacro. The ONLY mapkey here -
# selection is pure COM, so nothing else can drift on widget names.
function Build-EdgeRoundMacro {
    param([double]$Radius)
    return "~ Activate ``main_dlg_cur`` ``page_Model_control_btn`` 1;" +
        "~ Command ``ProCmdRound``;" +
        "~ Input ``main_dlg_cur`` ``maindashInst0.cir_rad_list`` ``$Radius``;" +
        "~ Update ``main_dlg_cur`` ``maindashInst0.cir_rad_list`` ``$Radius``;" +
        "~ Activate ``main_dlg_cur`` ``maindashInst0.cir_rad_list``;" +
        "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"
}

# $true if VersionStamp changed within the timeout (the round modified the model).
function Wait-EdgeModelChange {
    param($Model, [string]$PreviousStamp, [int]$TimeoutMs = 30000)
    $deadline = [DateTime]::Now.AddMilliseconds($TimeoutMs)
    while ([DateTime]::Now -lt $deadline) {
        try { if ($Model.VersionStamp -ne $PreviousStamp) { return $true } } catch {}
    }
    return $false
}

# DISCOVER edges hands-free: sweep GetItemById(ITEM_EDGE, 1..MaxId), keeping every
# id that resolves to an edge with a readable EvalLength. No selection, no find
# tool. Returns @(@{Id;Length;Sel=$null}).
function Get-EdgesBySweep {
    param($Model, $TypeObj, [int]$MaxId = 5000)
    $edges = @()
    $et = $TypeObj.ITEM_EDGE
    for ($id = 1; $id -le $MaxId; $id++) {
        $ed = $null
        try { $ed = $Model.GetItemById($et, $id) } catch { continue }
        if ($null -eq $ed) { continue }
        $len = $null
        try { $len = [double]$ed.EvalLength() } catch {}
        if ($null -ne $len) { $edges += @{ Id = $id; Length = $len; Sel = $null } }
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ed) | Out-Null } catch {}
    }
    return @($edges)
}

# PURE (no COM): given @(@{Id;Length;...}) choose the target dimension and the
# matching edges. $Target < 0 => AUTO = the lowest length present. Match is
# |length - target| <= Tol. Returns @{ Target; Matches=@(...) }. Unit-tested.
function Select-LowestDimensionEdges {
    param($Edges, [double]$Target = -1, [double]$Tol = 0.01)
    $all = @($Edges)
    if ($all.Count -eq 0) { return @{ Target = $null; Matches = @() } }
    $tgt = $Target
    if ($tgt -lt 0) {
        $min = ($all | ForEach-Object { [double]$_.Length } | Measure-Object -Minimum).Minimum
        $tgt = [math]::Round([double]$min, 4)
    }
    $matches = @($all | Where-Object { [Math]::Abs([double]$_.Length - $tgt) -le $Tol })
    return @{ Target = $tgt; Matches = @($matches) }
}

# Resolve the CMpfcSelect factory by trying candidate ProgIDs and a real
# CreateModelItemSelection call on a known edge id (the CM*/CC* factory-is-never-
# a-ProgID gotcha). Returns @{Cls;ProgId} or $null.
function Resolve-EdgeSelectFactory {
    param($Model, $TypeObj, [int]$TestId)
    $candidates = @('pfcls.pfcSelect', 'pfcls.MpfcSelect', 'pfcls.CMpfcSelect', 'pfcls.pfcSelectClass')
    foreach ($progId in $candidates) {
        try {
            $cls = New-Object -ComObject $progId
            $ed = $Model.GetItemById($TypeObj.ITEM_EDGE, $TestId)
            $sel = $cls.CreateModelItemSelection($ed, $null)
            if ($null -ne $sel) { return @{ Cls = $cls; ProgId = $progId } }
        } catch {}
    }
    return $null
}

# Edge ids currently in the selection buffer (self-test verification).
function Get-SelectionEdgeIds {
    param($Session)
    $ids = @(); $c = $null
    try { $c = ($Session.CurrentSelectionBuffer()).Contents } catch {}
    if ($null -eq $c) { return @() }
    foreach ($it in $c) { try { $ids += [int]$it.SelItem.Id } catch {} }
    return @($ids)
}

# SELECT a set of edges via the API (NO find tool): Clear the buffer, then add each.
# Edges carrying their own IpfcSelection ($e.Sel) are re-added directly (Path 1a);
# sweep-sourced edges ($e.Sel=$null) are refetched by id and wrapped via the
# factory (Path 2). Returns count added.
function Add-EdgesToSelection {
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

# ----------------------------------------------------------------------------
# Invoke-AutoCornerRound - the hands-free orchestrator. NO prompts, NO find tool,
# NO user selection. Sweep -> pick the lowest dimension (or $Target) -> resolve
# the select factory -> SELF-TEST selection on one edge (abort, no mutation, if it
# fails) -> round in <=40-edge batches with a VersionStamp canary.
#
# Returns @{ Found; Target; Matched; SelfTestOk; BatchesFired; ModelChanged;
#            TotalBatches; Aborted; Reason }. Honest: ModelChanged counts batches
# whose VersionStamp moved (NOT rounds Creo geometrically accepted).
# ----------------------------------------------------------------------------
function Invoke-AutoCornerRound {
    param(
        $Session, $Model, $TypeObj,
        [double]$Radius = 0.25,
        [double]$Target = -1,
        [double]$Tol = 0.01,
        [int]$SweepMax = 5000,
        [int]$BatchSize = 40
    )
    $res = @{ Found = 0; Target = $null; Matched = 0; SelfTestOk = $false;
        BatchesFired = 0; ModelChanged = 0; TotalBatches = 0; Aborted = $false; Reason = "" }

    # 1. DISCOVER
    $cand = @(Get-EdgesBySweep -Model $Model -TypeObj $TypeObj -MaxId $SweepMax)
    $res.Found = $cand.Count
    if ($cand.Count -eq 0) { $res.Reason = "sweep found no edges (GetItemById dead, or ids exceed $SweepMax)"; return $res }

    # 2. SELECT lowest dimension (or explicit target)
    $pick = Select-LowestDimensionEdges -Edges $cand -Target $Target -Tol $Tol
    $matchEdges = @($pick.Matches)
    $res.Target = $pick.Target
    $res.Matched = $matchEdges.Count
    if ($matchEdges.Count -eq 0) { $res.Reason = "no edges matched target $($pick.Target) +/- $Tol"; return $res }

    # 3. FACTORY + SELF-TEST (gate before any mutation)
    $factory = Resolve-EdgeSelectFactory -Model $Model -TypeObj $TypeObj -TestId ([int]$matchEdges[0].Id)
    if ($null -eq $factory) { $res.Reason = "CreateModelItemSelection factory unavailable on this build"; return $res }

    $stLanded = Add-EdgesToSelection -Session $Session -Model $Model -TypeObj $TypeObj -Edges @($matchEdges[0]) -Factory $factory
    $stBuf = @(Get-SelectionEdgeIds -Session $Session)
    $res.SelfTestOk = ($stLanded -ge 1 -and $stBuf.Count -eq 1 -and [int]$stBuf[0] -eq [int]$matchEdges[0].Id)
    if (-not $res.SelfTestOk) {
        $res.Reason = "self-test failed (landed=$stLanded, buffer=[$($stBuf -join ', ')]); did NOT round"
        return $res
    }

    # 4. ROUND in batches with a first-batch canary
    $res.TotalBatches = [Math]::Ceiling($matchEdges.Count / $BatchSize)
    $batchNum = 0
    for ($batchStart = 0; $batchStart -lt $matchEdges.Count; $batchStart += $BatchSize) {
        $batchNum++
        $batchEnd = [Math]::Min($batchStart + $BatchSize, $matchEdges.Count)
        $batchEdges = @($matchEdges[$batchStart..($batchEnd - 1)])

        $stamp = $null
        try { $stamp = $Model.VersionStamp } catch {}

        $null = Add-EdgesToSelection -Session $Session -Model $Model -TypeObj $TypeObj -Edges $batchEdges -Factory $factory

        $changed = $false
        try {
            $Session.RunMacro((Build-EdgeRoundMacro -Radius $Radius))
            $res.BatchesFired++
            if ($null -ne $stamp) { $changed = Wait-EdgeModelChange -Model $Model -PreviousStamp $stamp }
        } catch {}
        if ($changed) { $res.ModelChanged++ }

        # canary: first batch MUST change the model or we abort (a can't-read stamp
        # counts as NO change - never assume success on failure).
        if ($batchNum -eq 1 -and -not $changed) {
            $res.Aborted = $true
            $res.Reason = "canary: first round batch did not change the model (VersionStamp unchanged)"
            break
        }
    }
    if (-not $res.Aborted -and $res.Reason -eq "") {
        $res.Reason = "rounded $($matchEdges.Count) edge(s) of length $($pick.Target) in $($res.BatchesFired) batch(es)"
    }
    return $res
}
