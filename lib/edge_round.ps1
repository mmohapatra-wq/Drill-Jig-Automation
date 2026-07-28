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
# -OnPoll (optional) is invoked each poll gap so a WinForms caller can pump its message
# loop (DoEvents) and stay responsive while Creo regenerates the round -- ADDITIVE:
# it defaults to $null and the flat/console callers that omit it are unchanged.
function Wait-EdgeModelChange {
    param($Model, [string]$PreviousStamp, [int]$TimeoutMs = 30000, [scriptblock]$OnPoll = $null)
    $deadline = [DateTime]::Now.AddMilliseconds($TimeoutMs)
    while ([DateTime]::Now -lt $deadline) {
        try { if ($Model.VersionStamp -ne $PreviousStamp) { return $true } } catch {}
        # Poll gap (proven pattern from boxinator/drilljig_core): without it this loop
        # busy-waits, pegging a CPU core AND flooding Creo with COM VersionStamp reads
        # *during* the round-feature regen it is polling for -- which slows the very
        # operation. 40ms is far finer than any Creo regen; detection stays instant.
        if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }
        Start-Sleep -Milliseconds 40
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
        [int]$BatchSize = 40,
        [scriptblock]$OnPoll = $null
    )
    $res = @{ Found = 0; Target = $null; Matched = 0; SelfTestOk = $false;
        BatchesFired = 0; ModelChanged = 0; TotalBatches = 0; Aborted = $false; Reason = "";
        Lengths = @(); LengthSummary = "" }

    # 1. DISCOVER
    $cand = @(Get-EdgesBySweep -Model $Model -TypeObj $TypeObj -MaxId $SweepMax)
    $res.Found = $cand.Count
    if ($cand.Count -eq 0) { $res.Reason = "sweep found no edges (GetItemById dead, or ids exceed $SweepMax)"; return $res }

    # DIAGNOSTIC: distinct edge lengths present (rounded to 3dp) + counts. Set BEFORE any
    # early return so a caller that matched nothing can still SEE what lengths the body
    # actually has -- the single most useful clue when a corner round "does nothing" (was
    # the target simply not a real edge length?). Cheap; pure.
    $hist = @{}
    foreach ($e in $cand) {
        $L = [math]::Round([double]$e.Length, 3)
        if ($hist.ContainsKey($L)) { $hist[$L] = [int]$hist[$L] + 1 } else { $hist[$L] = 1 }
    }
    $res.Lengths = @($hist.GetEnumerator() | Sort-Object { [double]$_.Name } | ForEach-Object { @{ Len = [double]$_.Name; Count = [int]$_.Value } })
    $res.LengthSummary = (@($res.Lengths | ForEach-Object { ("{0}x{1}" -f $_.Len, $_.Count) }) -join ', ')

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
            if ($null -ne $stamp) { $changed = Wait-EdgeModelChange -Model $Model -PreviousStamp $stamp -OnPoll $OnPoll }
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

# ----------------------------------------------------------------------------
# Invoke-CurvedCornerRound - the CURVED-jig entry point (drilljig3d-gui.cmd).
#
# WHY A `function global:` WRAPPER (not a direct Invoke-AutoCornerRound call):
# the curved GUI's wizard steps live in SEPARATE step-group libs
# (curved_gui_steps_*.ps1) and run their Build/OnNext inside .GetNewClosure()
# handlers, which resolve a bare command name against GLOBAL scope ONLY
# ([[project_gui_scope_bugs]]; the run_drilljig3d_gui_tests Section-6 lint has
# teeth for this). The eight functions above are PLAIN `function` (dot-sourced into
# the .cmd's own scriptblock scope) so a curved-GUI step closure CANNOT see them --
# calling Invoke-AutoCornerRound from a step handler would throw "the term is not
# recognized" at runtime (the exact wall the flat GUI avoids only because ITS steps
# are inline in the .cmd body). So the curved GUI calls THIS global wrapper, which
# runs in a scope that CAN see the plain primitives -- identical to how
# Invoke-ConformalBlank (global) wraps the plain Get-FeatureIdSet/Wait-ModelModified
# core primitives (CONFIRMED LIVE 2026-06-24).
#
# CURVED-SPECIFIC TARGETING: the flat jig rounds the AUTO-lowest edge length (on a
# flat plate the through-thickness verticals ARE the shortest edges). A conformal
# offset+thicken blank is not guaranteed that property, so we TARGET the thicken
# length directly -- a thicken's side/through-thickness edges are the constant
# offset distance = $Thickness. When $Thickness <= 0 (not known) we fall back to
# AUTO (-Target -1), exactly the flat behavior. -Tol defaults looser than the flat
# 0.01 because a curved blank's through-thickness edge length can drift slightly off
# the nominal thickness with surface curvature; still tight enough not to grab the
# (much longer) perimeter edges.
#
# Returns the SAME shape as Invoke-AutoCornerRound (Found/Target/Matched/SelfTestOk/
# BatchesFired/ModelChanged/TotalBatches/Aborted/Reason) plus a 'Mode' field
# ('thickness' | 'auto') so the caller can report which targeting ran. Honest: it
# NEVER fabricates success -- the underlying self-test + VersionStamp canary gate it.
# ----------------------------------------------------------------------------
function global:Invoke-CurvedCornerRound {
    param(
        $Session, $Model, $TypeObj,
        [double]$Radius = 0.25,
        [double]$Thickness = 0,
        [double]$Tol = 0.05,
        [int]$SweepMax = 5000,
        [int]$BatchSize = 40,
        [scriptblock]$OnPoll = $null
    )
    $mode = if ($Thickness -gt 0) { 'thickness' } else { 'auto' }
    $target = if ($Thickness -gt 0) { [double]$Thickness } else { -1 }
    $res = Invoke-AutoCornerRound -Session $Session -Model $Model -TypeObj $TypeObj `
            -Radius $Radius -Target $target -Tol $Tol -SweepMax $SweepMax -BatchSize $BatchSize -OnPoll $OnPoll

    # AUTO FALLBACK: if targeting the thicken length matched NO edges but the sweep DID
    # find edges, the passed thickness simply is not a real edge length on this body (the
    # #1 cause of "corner round does nothing" -- e.g. the blank was thickened to wall+relief
    # but we were handed wall). Retry with the flat jig's AUTO target (the LOWEST length
    # present) -- on a plate the shortest edges ARE the through-thickness walls. Only adopt
    # the fallback if it actually matched something; otherwise keep the first (honest) miss
    # so the caller still sees the LengthSummary + can report it.
    if ($Thickness -gt 0 -and [int]$res.Matched -eq 0 -and [int]$res.Found -gt 0) {
        $auto = Invoke-AutoCornerRound -Session $Session -Model $Model -TypeObj $TypeObj `
                -Radius $Radius -Target -1 -Tol $Tol -SweepMax $SweepMax -BatchSize $BatchSize -OnPoll $OnPoll
        if ([int]$auto.Matched -gt 0) { $res = $auto; $mode = 'auto-fallback' }
    }
    try { $res.Mode = $mode } catch {}
    return $res
}
