<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

# ============================================================================
# cornerinator.cmd - round the VERTICAL edges of a drill-jig plate
# ============================================================================
# Auto-detects the vertical corner edges of a rectangular plate (a box solid)
# and applies a round/fillet to them. For a plain plate that is the 4 corners;
# any plate with more vertical edges (pockets, bosses) gets them all - the
# confirm step shows the count first so nothing unexpected is rounded blind.
#
# This is a STANDALONE tool (like radinator.cmd) - it does not touch drilljig.cmd
# and reuses its proven machinery:
#   - round mapkey + edge-by-ID selection + batching ....... radinator.cmd
#   - mode guard / VersionStamp canary / ID-only buffer read  drilljig.cmd
#   - Measure-Extents / Get-AllSurfaces / Read-PlaneNormal /
#     Dot / Cross ........................................... lib\creo_geometry.ps1
#
# DETECTION (the only new logic) - a vertical edge is found by its TWO ADJACENT
# FACE NORMALS, never by reading the edge's endpoints (the coordinate-read path
# that crashed holeinator live - see CLAUDE.md "History / why ID-only"):
#   straight edge AND both adjacent surfaces are planes AND both plane normals
#   are perpendicular to the plate's "up"/thickness axis.
# "up" defaults to the thinnest of the three measured extents; override X/Y/Z.
#
# THE ONE LIVE-UNVERIFIED ASSUMPTION: that a PLANE descriptor's .Origin.GetZAxis()
# is the face normal (Read-PlaneNormal). It is proven for the cylinder sibling
# (Get-CylinderAxes) but not doc-confirmed for planes. If it misfires, detection
# finds 0 edges and the tool offers a MANUAL PICK fallback (you select the edges,
# it reads their IDs) - so the tool still works either way.
#
# Verification is a VersionStamp change (the model changed when the round fired),
# NOT a geometric measurement - same honest bar as radinator/holeinator. The
# success count is BATCHES FIRED, not rounds Creo geometrically accepted; verify
# the rounds visually after a run.
# ============================================================================

$Host.UI.RawUI.WindowTitle = "CORNERINATOR"
$Verbose = $ScriptArgs -match '(?i)-v|--verbose'
# --probe-edges: read-only diagnostic. Dumps what every COM enumeration call
# returns live, then has the user select ONE edge by hand and walks UP from it
# (GetFeature) to pinpoint exactly where enumeration breaks. No mutation, no round.
$ProbeEdges = ($ScriptArgs -match '(?i)(^|\s)-{1,2}probe-edges(\s|$)')
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

# $true if VersionStamp changed within the timeout (the macro modified the
# model). The canary net against round-mapkey widget-name drift. (drilljig.cmd)
function Wait-ModelModified {
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

# Build the find-tool "select edges by ID into the buffer" macro (radinator's
# proven round-phase fragment). Opens the tool once, loops every id into the
# buffer (ApplyBtn ACCUMULATES without clearing), closes the tool once. Used both
# to HIGHLIGHT the detected edges for the confirm and inside the round batch.
function Build-EdgeSelectMacro {
    param([int[]]$EdgeIds)
    $m = "~ Command ``ProCmdMdlTreeSearch``;" +
        "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Edge``;" +
        "~ Select ``selspecdlg0`` ``LookByOptionMenu`` 1 ``Edge``;" +
        "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Attributes``;" +
        "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
        "~ Select ``selspecdlg0`` ``RuleTypes`` 1 ``All``;" +
        "~ Select ``selspecdlg0`` ``RuleTypes`` 1 ``ID``;"
    foreach ($id in $EdgeIds) {
        $m += "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$id``;" +
              "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
              "~ Activate ``selspecdlg0`` ``ApplyBtn``;"
    }
    $m += "~ Activate ``selspecdlg0`` ``CancelButton``;"
    return $m
}

# Build the ROUND mapkey for the edges already accumulated in the selection
# buffer (radinator.cmd:512-519, verbatim). ONE atomic RunMacro - a dashboard's
# command context does not survive across RunMacro calls. The radius is committed
# by the Activate on cir_rad_list (NO FocusOut blur - that is this widget's own
# commit path; do not graft the extrude/hole blur onto it).
function Build-RoundMacro {
    param([double]$Radius)
    return "~ Activate ``main_dlg_cur`` ``page_Model_control_btn`` 1;" +
        "~ Command ``ProCmdRound``;" +
        "~ Input ``main_dlg_cur`` ``maindashInst0.cir_rad_list`` ``$Radius``;" +
        "~ Update ``main_dlg_cur`` ``maindashInst0.cir_rad_list`` ``$Radius``;" +
        "~ Activate ``main_dlg_cur`` ``maindashInst0.cir_rad_list``;" +
        "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"
}

# Resolve the user's CURRENT selection buffer into EDGE ids only (manual-pick
# fallback). ID-ONLY - never reads an edge coordinate (holeinator's lesson).
# Reports any non-edge selections by their .Type. Returns @(ids) (may be empty).
function Resolve-SelectedEdgeIds {
    param($Session, $TypeObj)
    $ids = @()
    $seen = @{}
    $rejected = @()
    $contents = $null
    try { $contents = ($Session.CurrentSelectionBuffer()).Contents } catch {}
    if ($null -eq $contents) { return @{ Ids = @(); Rejected = @() } }
    foreach ($item in $contents) {
        $si = $null
        try { $si = $item.SelItem } catch { continue }
        if ($null -eq $si) { continue }
        $isEdge = $false
        try { $isEdge = ([int]$si.Type -eq [int]$TypeObj.ITEM_EDGE) } catch {}
        if ($isEdge) {
            $id = $null
            try { $id = [int]$si.Id } catch {}
            if ($null -ne $id -and -not $seen.ContainsKey($id)) { $seen[$id] = $true; $ids += $id }
        } else {
            $rid = "?"; $tname = "?"
            try { $rid = [int]$si.Id } catch {}
            try { $tname = [string]$si.Type } catch {}
            $rejected += "id $rid (type $tname)"
        }
    }
    return @{ Ids = @($ids); Rejected = @($rejected) }
}

# Select EVERY edge in the model via the FIND TOOL, then read them back from the
# selection buffer. THE BREAKTHROUGH (2026-06-22): on this jig part all FOUR COM
# enumeration routes (surface walk, model/per-body ListItems(ITEM_EDGE), feature
# ListSubItems) return 0 edges, yet MANUAL PICK works - i.e. the geometry is
# selectable but NOT API-traversable (classic imported/"foreign" body). The find
# tool is the SAME UI selection layer as manual pick, NOT the dead COM-traversal
# layer - so a "select all edges" rule reaches what enumeration cannot, and the
# resulting buffer is read with the proven CurrentSelectionBuffer().Contents path.
#
# The rule: open the search, object type = Edge, Rule = ID, but enter NO id and
# Evaluate -> with an empty/All rule the find tool matches every edge of the type.
# Each buffered SelItem yields .Id + EvalLength() (the same reads manual pick uses).
# Returns @{ Edges=@(@{Id;Length}); Source; Detail }.
function Get-EdgesViaFindTool {
    param($Session)
    $edges = @()
    $seen = @{}
    # 1) clear, then open the find tool and select ALL edges into the buffer.
    #    'All' rule + Evaluate + Apply with no ID filter selects every edge.
    $macro = "~ Command ``ProCmdSelClear``;" +
        "~ Command ``ProCmdMdlTreeSearch``;" +
        "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Edge``;" +
        "~ Select ``selspecdlg0`` ``LookByOptionMenu`` 1 ``Edge``;" +
        "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
        "~ Select ``selspecdlg0`` ``RuleTypes`` 1 ``All``;" +
        "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
        "~ Activate ``selspecdlg0`` ``FindNowBtn``;" +
        "~ Activate ``selspecdlg0`` ``SelAllBtn``;" +
        "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
        "~ Activate ``selspecdlg0`` ``CancelButton``;"
    try { $Session.RunMacro($macro) } catch { Write-Log "find-tool select-all edges macro failed: $($_.Exception.Message)" "Yellow" }

    # 2) read the buffer back - the proven path (same call manual pick uses).
    $contents = $null
    try { $contents = ($Session.CurrentSelectionBuffer()).Contents } catch {}
    if ($null -ne $contents) {
        foreach ($item in $contents) {
            $si = $null
            try { $si = $item.SelItem } catch { continue }
            if ($null -eq $si) { continue }
            $id = $null
            try { $id = [int]$si.Id } catch {}
            if ($null -eq $id -or $seen.ContainsKey($id)) { continue }
            $seen[$id] = $true
            $len = $null
            try { $len = [double]$si.EvalLength() } catch {}
            $edges += @{ Id = $id; Length = $len; Sel = $si }
        }
    }
    return @{ Edges = @($edges); Source = "find-tool select-all -> buffer"; Detail = "$($edges.Count) edges" }
}

# Gather ALL edges of the part as a flat COM list. The user's directed approach
# (2026-06-22): "find all edges that are equal to the extrude" - i.e. go through
# the FEATURE, not the geometry container. The VB docs confirm the route:
# IpfcGeomCurve.GetFeature() links an edge to its owning feature, and
# feature.ListSubItems(ITEM_EDGE) lists a feature's own edges (ITEM_EDGE is a
# supported ListSubItems subitem; holeinator uses the same call for ITEM_POINT).
#
# LIVE 2026-06-22: the surface walk (Get-AllSurfaces -> ListContours ->
# ListElements) returned 0 surfaces, AND model/per-body ListItems(ITEM_EDGE) came
# back empty - so the FEATURE route is tried FIRST now, geometry-container routes
# demoted to fallbacks. Cascade (stop at the first that yields edges):
#   1. feature tree: each feature.ListSubItems(ITEM_EDGE), dedup by Id  <- PRIMARY
#   2. $model.ListItems(ITEM_EDGE)                - whole-model
#   3. per body: $body.ListItems(ITEM_EDGE), else walk $body.ListSurfaces()
#   4. the old surface walk via Get-AllSurfaces   - last resort
# Each path logs its yield (Write-Log) so a live run shows which one fed edges.
# Returns @{ Edges=@(<IpfcEdge>); Source="..."; Detail }.
function Get-AllEdges {
    param($Model, $TypeObj)

    # --- 1. PRIMARY: feature tree - each feature's ListSubItems(ITEM_EDGE) ---
    # The user's "edges of the extrude" route. Features share edges, so dedup by Id.
    try {
        $feats = @($Model.ListItems($TypeObj.ITEM_FEATURE))
        Write-Log "feature route: $($feats.Count) features"
        if ($feats.Count -gt 0) {
            $arr = @()
            $seenF = @{}
            foreach ($ft in $feats) {
                $subs = $null
                try { $subs = $ft.ListSubItems($TypeObj.ITEM_EDGE) } catch {}
                if ($null -eq $subs) { continue }
                for ($i = 0; $i -lt $subs.Count; $i++) {
                    $ed = $subs.Item($i)
                    $eid = $null
                    try { $eid = [int]$ed.Id } catch {}
                    if ($null -ne $eid -and $seenF.ContainsKey($eid)) { continue }
                    if ($null -ne $eid) { $seenF[$eid] = $true }
                    $arr += $ed
                }
            }
            Write-Log "feature route yielded $($arr.Count) unique edges"
            if ($arr.Count -gt 0) {
                return @{ Edges = $arr; Source = "feature.ListSubItems(ITEM_EDGE) ($($feats.Count) features)"; Detail = "$($arr.Count) edges" }
            }
        }
    } catch { Write-Log "feature-tree edge enumeration failed: $($_.Exception.Message)" "Yellow" }

    # --- 2. whole-model ListItems(ITEM_EDGE) ---
    try {
        $items = $Model.ListItems($TypeObj.ITEM_EDGE)
        $cnt = if ($null -ne $items) { $items.Count } else { 0 }
        Write-Log "model.ListItems(ITEM_EDGE) yielded $cnt"
        if ($null -ne $items -and $items.Count -gt 0) {
            $arr = @()
            for ($i = 0; $i -lt $items.Count; $i++) { $arr += $items.Item($i) }
            return @{ Edges = $arr; Source = "model.ListItems(ITEM_EDGE)"; Detail = "$($arr.Count) edges" }
        }
    } catch { Write-Log "model.ListItems(ITEM_EDGE) failed: $($_.Exception.Message)" "Yellow" }

    # --- 3. per body: ListItems(ITEM_EDGE), then ListSurfaces contour walk ---
    try {
        $bodies = @($Model.ListItems($TypeObj.ITEM_BODY))
        if ($bodies.Count -gt 0) {
            $arr = @()
            foreach ($body in $bodies) {
                $got = $false
                try {
                    $be = $body.ListItems($TypeObj.ITEM_EDGE)
                    if ($null -ne $be -and $be.Count -gt 0) {
                        for ($i = 0; $i -lt $be.Count; $i++) { $arr += $be.Item($i) }
                        $got = $true
                    }
                } catch {}
                if (-not $got) {
                    try {
                        $bs = $body.ListSurfaces()
                        if ($null -ne $bs) {
                            for ($i = 0; $i -lt $bs.Count; $i++) {
                                $ct = $null
                                try { $ct = $bs.Item($i).ListContours() } catch {}
                                if ($null -ne $ct) {
                                    for ($c = 0; $c -lt $ct.Count; $c++) {
                                        $el = $null
                                        try { $el = $ct.Item($c).ListElements() } catch {}
                                        if ($null -ne $el) { for ($e = 0; $e -lt $el.Count; $e++) { $arr += $el.Item($e) } }
                                    }
                                }
                            }
                        }
                    } catch {}
                }
            }
            Write-Log "per-body route yielded $($arr.Count) edges across $($bodies.Count) bodies"
            if ($arr.Count -gt 0) {
                return @{ Edges = $arr; Source = "body.ListItems/ListSurfaces ($($bodies.Count) bodies)"; Detail = "$($arr.Count) edges" }
            }
        }
    } catch { Write-Log "per-body edge enumeration failed: $($_.Exception.Message)" "Yellow" }

    # --- 4. last resort: the original surface walk ---
    try {
        $surfaces = Get-AllSurfaces -Model $Model -TypeObj $TypeObj
        $arr = @()
        foreach ($sf in $surfaces) {
            $ct = $null
            try { $ct = $sf.ListContours() } catch {}
            if ($null -eq $ct) { continue }
            for ($c = 0; $c -lt $ct.Count; $c++) {
                $el = $null
                try { $el = $ct.Item($c).ListElements() } catch {}
                if ($null -ne $el) { for ($e = 0; $e -lt $el.Count; $e++) { $arr += $el.Item($e) } }
            }
        }
        Write-Log "surface-walk route yielded $($arr.Count) edges across $($surfaces.Count) surfaces"
        return @{ Edges = $arr; Source = "Get-AllSurfaces walk ($($surfaces.Count) surfaces)"; Detail = "$($arr.Count) edges" }
    } catch { Write-Log "surface walk failed: $($_.Exception.Message)" "Yellow" }

    return @{ Edges = @(); Source = "none"; Detail = "no enumeration path returned edges" }
}

# Detect the VERTICAL edges of the plate. EDGE SOURCE (2026-06-22): the FIND TOOL
# select-all -> selection buffer (pass -Session), because on this jig ALL COM
# traversal returns 0 edges while UI selection works (imported/foreign body). Falls
# back to the Get-AllEdges COM cascade if the find tool yields nothing.
#
# PRIMARY gate: length ~= plate THICKNESS (EvalLength within $LenTol of $Thickness).
# On a flat rectangular plate the only edges whose length equals the thinnest extent
# ARE the four verticals (perimeter edges are width/depth long).
#
# OPTIONAL sub-gates - SKIP-not-fail, so none can ever zero the result on foreign
# geometry where the probe is unavailable:
#   - straight: GetCurveDescriptor().End1 non-null. Only a CONFIRMED curve rejects;
#     "could not test" does NOT reject.
#   - both adjacent faces planar (Surface1/Surface2 -> GetSurfaceType 0/9) - skipped
#     if Surface1/2 are unreachable.
#   - normals perpendicular to $UpUnit, only if Read-PlaneNormal returns non-null.
#
# $Thickness is the up-axis extent (plate thickness); pass 0 to skip the length
# test. Returns @{ Matches=@(@{Id;Length;Dot1;Dot2;NormalUsed}); Scanned;
# EdgeSource; Stats }. Stats shows where edges drop, so a live run pinpoints the gate.
function Get-VerticalEdges {
    param($Model, $TypeObj, $UpUnit, [double]$Thickness = 0.0, [double]$LenTol = 0.05, [double]$PerpTol = 0.02, $Session = $null)

    # PRIMARY edge source: the FIND TOOL -> selection buffer (the UI selection
    # layer that works on this part where ALL COM traversal returns 0). Falls back
    # to COM enumeration (Get-AllEdges cascade) only if the find tool yields nothing.
    $eres = $null
    if ($null -ne $Session) {
        $eres = Get-EdgesViaFindTool -Session $Session
        Write-Log "find-tool route: $($eres.Detail)"
    }
    if ($null -eq $eres -or @($eres.Edges).Count -eq 0) {
        $eres = Get-AllEdges -Model $Model -TypeObj $TypeObj
    }
    $edges = @($eres.Edges)
    Write-Log "Edge source: $($eres.Source) -> $($eres.Detail) (thickness=$Thickness, lenTol=$LenTol)"

    $matches = @()
    $processedEdgeIds = @{}
    $scanned = 0
    # diagnostics: how many edges survived each successive gate
    $stats = @{ Straight = 0; LenMatch = 0; PlanarChecked = 0; BothPlanar = 0; NormalRead = 0; NormalPerp = 0 }

    for ($e = 0; $e -lt $edges.Count; $e++) {
        if ($edges.Count -gt 0) { Show-Progress ([Math]::Floor(($e / $edges.Count) * 100)) "Scanning edges" }
        $edge = $edges[$e]
        if ($null -eq $edge) { continue }

        # Edges from the find-tool route are @{Id;Length;Sel}; from COM routes they
        # are raw IpfcEdge. Resolve a COM edge handle ($eob) for the optional probes,
        # and read Id/Length from whichever shape we have.
        $eob = $edge
        $preLen = $null
        if ($edge -is [hashtable]) { $eob = $edge.Sel; $preLen = $edge.Length }

        $edgeId = $null
        try { $edgeId = [int]$eob.Id } catch { try { $edgeId = [int]$edge.Id } catch { continue } }
        if ($processedEdgeIds.ContainsKey($edgeId)) { continue }
        $processedEdgeIds[$edgeId] = $true
        $scanned++

        # length (used by the length gate AND shown in the report)
        $length = $preLen
        if ($null -eq $length) { try { $length = [double]$eob.EvalLength() } catch {} }

        # straight test: GetCurveDescriptor().End1 non-null - SKIP-not-fail. On
        # foreign/imported geometry GetCurveDescriptor may be unavailable just like
        # the surfaces are; treat "could not test" as "do not reject" so the length
        # gate stands alone. Only a POSITIVE not-straight reading rejects.
        $straightTested = $false
        $isStraight = $false
        $curveDesc = $null
        try {
            $curveDesc = $eob.GetCurveDescriptor()
            $straightTested = $true
            if ($null -ne $curveDesc.End1) { $isStraight = $true }
        } catch { $straightTested = $false }
        finally {
            if ($null -ne $curveDesc) {
                try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($curveDesc) | Out-Null } catch {}
            }
        }
        if ($straightTested -and -not $isStraight) { continue }   # only reject a CONFIRMED curve
        $stats.Straight++

        # PRIMARY: length ~= thickness (skipped if no thickness given)
        $lenOk = $true
        if ($Thickness -gt 0 -and $null -ne $length) {
            $lenOk = ([Math]::Abs($length - $Thickness) -le $LenTol)
        }
        if (-not $lenOk) { continue }
        $stats.LenMatch++

        # OPTIONAL sub-gate: both faces planar - ONLY when Surface1/2 are reachable.
        # If they are not (ListItems-sourced edges may not expose them), SKIP (do not
        # fail) so this can never zero the result by itself.
        $qualifies = $true
        $d1 = $null; $d2 = $null
        $normalUsed = $false
        $surf1 = $null; $surf2 = $null
        $desc1 = $null; $desc2 = $null
        try {
            try { $surf1 = $eob.Surface1 } catch {}
            try { $surf2 = $eob.Surface2 } catch {}
            if ($null -ne $surf1 -and $null -ne $surf2) {
                $stats.PlanarChecked++
                $desc1 = $surf1.GetSurfaceDescriptor()
                $desc2 = $surf2.GetSurfaceDescriptor()
                $t1 = [int]$desc1.GetSurfaceType()
                $t2 = [int]$desc2.GetSurfaceType()
                $bothPlanes = (($t1 -eq 0 -or $t1 -eq 9) -and ($t2 -eq 0 -or $t2 -eq 9))
                if (-not $bothPlanes) {
                    $qualifies = $false          # faces read AND say not plane-plane -> reject
                } else {
                    $stats.BothPlanar++
                    # refinement: tighten with normals IF they read
                    $n1 = Read-PlaneNormal -Surf $surf1
                    $n2 = Read-PlaneNormal -Surf $surf2
                    if ($null -ne $n1 -and $null -ne $n2) {
                        $stats.NormalRead++
                        $normalUsed = $true
                        $d1 = [Math]::Abs((Dot $n1 $UpUnit))
                        $d2 = [Math]::Abs((Dot $n2 $UpUnit))
                        if ($d1 -le $PerpTol -and $d2 -le $PerpTol) { $stats.NormalPerp++ }
                        else { $qualifies = $false }   # normals say not vertical -> trust them
                    }
                }
            }
            # surfaces unreachable -> leave $qualifies = $true (primary gate stands)
        } catch { }   # a planar-probe failure must NOT drop an edge that passed the primary gate
        finally {
            if ($null -ne $desc1) { try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($desc1) | Out-Null } catch {} }
            if ($null -ne $desc2) { try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($desc2) | Out-Null } catch {} }
            if ($null -ne $surf1) { try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($surf1) | Out-Null } catch {} }
            if ($null -ne $surf2) { try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($surf2) | Out-Null } catch {} }
        }

        if ($qualifies) {
            $matches += @{ Id = $edgeId; Length = $length; Dot1 = $d1; Dot2 = $d2; NormalUsed = $normalUsed }
        }
    }
    Show-Progress 100 "Scan complete"
    return @{ Matches = @($matches); Scanned = $scanned; EdgeSource = $eres.Source; Stats = $stats }
}

# ============================================================================
# HEADER
# ============================================================================
Write-Host ""
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "   CORNERINATOR  -  round the vertical edges of a drill-jig plate" -ForegroundColor Cyan
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Prerequisites:" -ForegroundColor Green
Write-Host "    1. The jig PART (not .asm) open in Creo, on its default datums" -ForegroundColor White
Write-Host "    2. The plate roughly axis-aligned (thinnest extent = thickness)" -ForegroundColor White
Write-Host "    3. Do not interact with Creo during processing" -ForegroundColor White
Write-Host ""

# ============================================================================
# SHARED LIBRARY (geometry reads)
# ============================================================================
. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')

# ============================================================================
# USER INPUT (before connecting)
# ============================================================================
$RadiusValue = 0.25
$raw = Read-Host "  Round radius in inches (blank -> 0.25)"
if (-not [string]::IsNullOrWhiteSpace($raw)) {
    $rv = 0.0
    if ([double]::TryParse($raw.Trim(), [ref]$rv) -and $rv -gt 0) { $RadiusValue = $rv }
    else { Write-Host "  Not a positive number - using 0.25" -ForegroundColor Yellow }
}
Write-Host "  Radius: $RadiusValue" -ForegroundColor Green
Write-Host ""

# up / thickness axis: auto (thinnest extent) by default; X/Y/Z to override.
$upChoice = Read-Host "  Up/thickness axis - A=auto (thinnest), or X / Y / Z (blank -> auto)"
$upMode = "AUTO"
switch ($upChoice.Trim().ToUpper()) {
    "X" { $upMode = "X" }
    "Y" { $upMode = "Y" }
    "Z" { $upMode = "Z" }
    default { $upMode = "AUTO" }
}
Write-Host "  Up axis: $upMode" -ForegroundColor Green
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
# Use GetActiveModel() FIRST - it is what the proven-live holeinator/drilljig use.
# cornerinator originally used CurrentModel; that may hand back a different/empty
# model handle than the one the selection buffer resolves against, which would
# explain enumeration returning 0 while manual pick works. Fall back to CurrentModel.
$model = $null
try { $model = $session.GetActiveModel() } catch {}
if ($null -eq $model) { try { $model = $session.CurrentModel } catch {} }

if ($null -eq $model) {
    Write-Host ""
    Write-Host "  FAILED: No model open in Creo." -ForegroundColor Red
    exit 1
}

Write-Host " Connected to $($model.FileName)" -ForegroundColor Green

# Mode guard: this tool rounds a PART. In assembly mode by-ID selection resolves
# against the .asm, not the part. Key off the filename extension (EpfcModelType
# enum ints are unconfirmed on this build - drilljig.cmd lesson).
$modelFile = ""
try { $modelFile = [string]$model.FileName } catch {}
if ($modelFile -match '\.asm(\.\d+)?$') {
    Write-Host ""
    Write-Host "  STOP: the active model is an ASSEMBLY ($modelFile)." -ForegroundColor Yellow
    Write-Host "  This tool rounds a single PART. Open the jig PART itself" -ForegroundColor Yellow
    Write-Host "  (activate it in its own window), then re-run." -ForegroundColor Yellow
    Write-Host ""
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
# --probe-edges : READ-ONLY DIAGNOSTIC (no mutation, no round)
# ============================================================================
# Four COM enumeration routes have returned 0 edges live while manual pick works.
# This probe dumps what every call actually returns, then walks UP from a single
# hand-picked edge (GetFeature) so we see precisely where enumeration breaks.
if ($ProbeEdges) {
    Write-Host ""
    Write-Host "  ====================================================================" -ForegroundColor Cyan
    Write-Host "   --probe-edges : read-only enumeration diagnostic" -ForegroundColor Cyan
    Write-Host "  ====================================================================" -ForegroundColor Cyan
    Write-Host "  Active model: $($model.FileName)" -ForegroundColor White
    Write-Host ""

    # Helper: report a ListItems(<type>) call by name -> count (or the error).
    function Probe-Count {
        param($Owner, [string]$OwnerLabel, [string]$TypeName)
        $tv = $null
        try { $tv = $modelItemType.$TypeName } catch {}
        if ($null -eq $tv) { Write-Host ("    {0}.ListItems({1}) -> (type const unavailable)" -f $OwnerLabel, $TypeName) -ForegroundColor DarkGray; return }
        try {
            $items = $Owner.ListItems($tv)
            $cnt = if ($null -eq $items) { "<null>" } else { $items.Count }
            Write-Host ("    {0}.ListItems({1}) -> {2}" -f $OwnerLabel, $TypeName, $cnt) -ForegroundColor White
        } catch {
            Write-Host ("    {0}.ListItems({1}) -> ERROR: {2}" -f $OwnerLabel, $TypeName, $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    Write-Host "  [1] Model-level ListItems counts:" -ForegroundColor Cyan
    foreach ($tn in @("ITEM_EDGE","ITEM_SURFACE","ITEM_BODY","ITEM_FEATURE","ITEM_CURVE","ITEM_AXIS","ITEM_POINT","ITEM_SOLID_GEOMETRY")) {
        Probe-Count -Owner $model -OwnerLabel "model" -TypeName $tn
    }
    Write-Host ""

    Write-Host "  [2] Per-body enumeration:" -ForegroundColor Cyan
    $bodies = @()
    try { $bodies = @($model.ListItems($modelItemType.ITEM_BODY)) } catch { Write-Host "    ListItems(ITEM_BODY) threw: $($_.Exception.Message)" -ForegroundColor Yellow }
    Write-Host ("    body count = $($bodies.Count)") -ForegroundColor White
    for ($b = 0; $b -lt $bodies.Count; $b++) {
        $body = $bodies[$b]
        $nm = try { $body.GetName() } catch { "(unnamed)" }
        Probe-Count -Owner $body -OwnerLabel "  body[$b] '$nm'" -TypeName "ITEM_EDGE"
        $sc = "?"; try { $bs = $body.ListSurfaces(); $sc = if ($null -eq $bs) { "<null>" } else { $bs.Count } } catch { $sc = "ERR:$($_.Exception.Message)" }
        Write-Host ("    body[$b].ListSurfaces() -> $sc") -ForegroundColor White
    }
    Write-Host ""

    Write-Host "  [3] GetDefaultBody:" -ForegroundColor Cyan
    try {
        $db = $model.GetDefaultBody()
        if ($null -eq $db) { Write-Host "    GetDefaultBody() -> <null>" -ForegroundColor White }
        else {
            Probe-Count -Owner $db -OwnerLabel "  defaultBody" -TypeName "ITEM_EDGE"
            $sc = "?"; try { $bs = $db.ListSurfaces(); $sc = if ($null -eq $bs) { "<null>" } else { $bs.Count } } catch { $sc = "ERR" }
            Write-Host ("    defaultBody.ListSurfaces() -> $sc") -ForegroundColor White
        }
    } catch { Write-Host "    GetDefaultBody() threw: $($_.Exception.Message)" -ForegroundColor Yellow }
    Write-Host ""

    Write-Host "  [4] Feature route (first 5 features' ListSubItems(ITEM_EDGE)):" -ForegroundColor Cyan
    $feats = @()
    try { $feats = @($model.ListItems($modelItemType.ITEM_FEATURE)) } catch {}
    Write-Host ("    feature count = $($feats.Count)") -ForegroundColor White
    $shown = 0
    foreach ($ft in $feats) {
        if ($shown -ge 5) { break }
        $fid = try { [int]$ft.Id } catch { "?" }
        $ec = "?"; try { $se = $ft.ListSubItems($modelItemType.ITEM_EDGE); $ec = if ($null -eq $se) { "<null>" } else { $se.Count } } catch { $ec = "ERR:$($_.Exception.Message)" }
        Write-Host ("    feature[id $fid].ListSubItems(ITEM_EDGE) -> $ec") -ForegroundColor White
        $shown++
    }
    Write-Host ""

    Write-Host "  [5] WALK-UP FROM A HAND-PICKED EDGE (the decisive test):" -ForegroundColor Cyan
    Write-Host "      In Creo, select ONE edge (the same way manual pick works), then press ENTER." -ForegroundColor White
    Read-Host
    $buf = $null
    try { $buf = ($session.CurrentSelectionBuffer()).Contents } catch {}
    if ($null -eq $buf -or $buf.Count -eq 0) {
        Write-Host "    Selection buffer empty - nothing to walk up from." -ForegroundColor Yellow
    } else {
        Write-Host ("    buffer has $($buf.Count) item(s)") -ForegroundColor White
        $si = $null
        try { $si = $buf[$buf.Count - 1].SelItem } catch {}
        if ($null -ne $si) {
            $eid = try { [int]$si.Id } catch { "?" }
            $ety = try { [string]$si.Type } catch { "?" }
            $elen = try { [double]$si.EvalLength() } catch { "n/a" }
            Write-Host ("    picked item: Id=$eid  Type=$ety  EvalLength=$elen") -ForegroundColor Green
            # walk UP to the owning feature (the user's GetFeature route)
            try {
                $ownFeat = $si.GetFeature()
                if ($null -ne $ownFeat) {
                    $ofid = try { [int]$ownFeat.Id } catch { "?" }
                    $ofnm = try { [string]$ownFeat.GetName() } catch { "(unnamed)" }
                    Write-Host ("    GetFeature() -> feature id $ofid '$ofnm'") -ForegroundColor Green
                    $back = "?"; try { $bse = $ownFeat.ListSubItems($modelItemType.ITEM_EDGE); $back = if ($null -eq $bse) { "<null>" } else { $bse.Count } } catch { $back = "ERR:$($_.Exception.Message)" }
                    Write-Host ("    that feature.ListSubItems(ITEM_EDGE) -> $back  (if >0, the feature route CAN reach edges)") -ForegroundColor Green
                } else {
                    Write-Host "    GetFeature() -> <null>" -ForegroundColor Yellow
                }
            } catch { Write-Host "    GetFeature() threw: $($_.Exception.Message)" -ForegroundColor Yellow }
            # also: does the edge expose adjacent surfaces / its own owner model?
            try { $own = $si.Owner; $on = try { [string]$own.FileName } catch { "?" }; Write-Host ("    edge.Owner.FileName = $on  (vs active model $($model.FileName))") -ForegroundColor White } catch {}
        } else {
            Write-Host "    Could not read SelItem from the buffer." -ForegroundColor Yellow
        }
    }
    Write-Host ""
    Write-Host "  Probe complete. Copy ALL of the above and paste it back." -ForegroundColor Cyan

    try { if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null } } catch {}
    try { if ($null -ne $origDynamicPreview)  { $session.SetConfigOption("dynamic_preview",  $origDynamicPreview)  | Out-Null } } catch {}
    try { $connection.Disconnect($null) } catch {}
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 0
}

try {

# ============================================================================
# MEASURE EXTENTS + PICK UP AXIS
# ============================================================================
Write-Host ""
Write-Host "  Measuring the plate..." -ForegroundColor Cyan
$excl = New-ExcludeTypes -TypeObj $modelItemType
$ext  = Measure-Extents -Solid $model -ExcludeTypes $excl

$upIndex = $null
if ($null -ne $ext) {
    Write-Host ("    extents: X=$([math]::Round($ext[0],4))  Y=$([math]::Round($ext[1],4))  Z=$([math]::Round($ext[2],4))") -ForegroundColor White
    switch ($upMode) {
        "X" { $upIndex = 0 }
        "Y" { $upIndex = 1 }
        "Z" { $upIndex = 2 }
        default {
            # AUTO: smallest extent = plate thickness
            $upIndex = 0
            if ($ext[1] -lt $ext[$upIndex]) { $upIndex = 1 }
            if ($ext[2] -lt $ext[$upIndex]) { $upIndex = 2 }
        }
    }
} else {
    Write-Host "    Could not measure the solid extents (EvalOutline gave nothing)." -ForegroundColor Yellow
    if ($upMode -eq "AUTO") {
        Write-Host "    Auto up-axis needs the extents; defaulting up = Z. Re-run with X/Y/Z to override." -ForegroundColor Yellow
        $upIndex = 2
    } else {
        $upIndex = switch ($upMode) { "X" {0} "Y" {1} "Z" {2} default {2} }
    }
}
$axisName = @("X","Y","Z")[$upIndex]
$upUnit = @(0.0, 0.0, 0.0)
$upUnit[$upIndex] = 1.0
# Plate thickness = the extent along the up axis. A vertical edge's length equals
# this (the proven primary signal). $null when extents could not be measured -
# then the length gate is skipped (detection falls back to straight + both-planar).
$thickness = if ($null -ne $ext) { [double]$ext[$upIndex] } else { 0.0 }
Write-Host "    Up/thickness axis: $axisName  (vertical edges run along $axisName, length ~ $([math]::Round($thickness,4)))" -ForegroundColor Green
Write-Host ""

# Length tolerance for "edge length ~= thickness": 5% of thickness, floor 0.01.
$lenTol = if ($thickness -gt 0) { [Math]::Max(0.01, $thickness * 0.05) } else { 0.05 }

# ============================================================================
# DETECT VERTICAL EDGES
# ============================================================================
Write-Host "  Detecting vertical edges (find-tool select-all -> buffer; length ~ thickness gate)..." -ForegroundColor Cyan
$scan = Get-VerticalEdges -Model $model -TypeObj $modelItemType -UpUnit $upUnit -Thickness $thickness -LenTol $lenTol -Session $session
$detected = @($scan.Matches)
Write-Host "  Edge source: $($scan.EdgeSource)" -ForegroundColor DarkGray
Write-Host "  Scanned $($scan.Scanned) unique edge(s)." -ForegroundColor DarkGray
if ($null -ne $scan.Stats) {
    $st = $scan.Stats
    Write-Host ("  Gate survivors: straight=$($st.Straight) -> length~thickness=$($st.LenMatch) -> planar-checked=$($st.PlanarChecked) -> both-planar=$($st.BothPlanar) -> normals-read=$($st.NormalRead) -> normals-perp=$($st.NormalPerp)") -ForegroundColor DarkGray
    if ($st.PlanarChecked -eq 0 -and $st.LenMatch -gt 0) {
        Write-Host "  (adjacent faces not reachable from these edges - qualified by the straight+length gate alone)" -ForegroundColor DarkGray
    } elseif ($st.NormalRead -eq 0 -and $st.BothPlanar -gt 0) {
        Write-Host "  (plane normals did not read on this build - qualified by the length/planar gate instead)" -ForegroundColor DarkGray
    }
}
Write-Host ""

$edgeIds = @()

if ($detected.Count -gt 0) {
    Write-Host "  Found $($detected.Count) vertical edge(s):" -ForegroundColor Green
    foreach ($m in $detected) {
        $lenStr = if ($null -ne $m.Length) { [math]::Round($m.Length,4) } else { "?" }
        $normStr = if ($m.NormalUsed) { "|n.up| = $([math]::Round($m.Dot1,4)) / $([math]::Round($m.Dot2,4))" } else { "(normals not read - length/planar gate)" }
        Write-Host ("    edge $($m.Id)   length $lenStr   $normStr") -ForegroundColor White
    }
    Write-Host ""
    $edgeIds = @($detected | ForEach-Object { [int]$_.Id })

    # Highlight the detected edges in Creo so the user can eyeball them before
    # committing. This selects them into the buffer; the round is NOT fired yet.
    try {
        $session.RunMacro("~ Command ``ProCmdSelClear``;")
        $session.RunMacro((Build-EdgeSelectMacro -EdgeIds $edgeIds))
        Write-Host "  The $($edgeIds.Count) edge(s) are now highlighted in Creo - verify them." -ForegroundColor Cyan
    } catch {
        Write-Host "  (could not highlight the edges: $($_.Exception.Message))" -ForegroundColor Yellow
    }
}
else {
    # Zero detected. Use the per-gate stats to say WHICH gate emptied the set, so
    # the user/next run knows what to adjust - then offer manual pick regardless.
    Write-Host "  No vertical edges were auto-detected." -ForegroundColor Yellow
    if ($null -ne $scan.Stats) {
        $st = $scan.Stats
        if ($scan.Scanned -eq 0) {
            Write-Host "  No edges were enumerated at all (edge source: $($scan.EdgeSource))." -ForegroundColor Yellow
            Write-Host "  ListItems(ITEM_EDGE), per-body, and the surface walk all returned nothing." -ForegroundColor Yellow
            Write-Host "  Check that the PART (not .asm) is active and has solid geometry." -ForegroundColor Yellow
        } elseif ($st.Straight -eq 0) {
            Write-Host "  $($scan.Scanned) edges were found but none are straight - is this a flat-faced plate?" -ForegroundColor Yellow
        } elseif ($st.LenMatch -eq 0) {
            Write-Host "  Straight edges exist but none match the thickness ~ $([math]::Round($thickness,4)) (len tol $([math]::Round($lenTol,4))):" -ForegroundColor Yellow
            Write-Host "  the up-axis may be wrong (try X/Y/Z explicitly) or the plate is not axis-aligned." -ForegroundColor Yellow
        } else {
            Write-Host "  Candidates matched straight+length but the planar/normal sub-gate rejected them." -ForegroundColor Yellow
        }
    }
    Write-Host ""
    $useManual = Read-Host "  Select the vertical edges by hand instead? (y/N)"
    if ($useManual -match '^[Yy]$') {
        Write-Host ""
        Write-Host "  In Creo, select the vertical edges to round, then press ENTER here." -ForegroundColor Cyan
        Read-Host
        $res = Resolve-SelectedEdgeIds -Session $session -TypeObj $modelItemType
        if ($res.Rejected.Count -gt 0) {
            Write-Host ("  Ignored $($res.Rejected.Count) non-edge selection(s):") -ForegroundColor Yellow
            foreach ($r in ($res.Rejected | Select-Object -First 10)) { Write-Host "      $r" -ForegroundColor DarkGray }
        }
        $edgeIds = @($res.Ids)
        if ($edgeIds.Count -eq 0) {
            Write-Host "  No edges resolved from the selection - nothing to round." -ForegroundColor Yellow
        } else {
            Write-Host "  Captured $($edgeIds.Count) edge id(s): $($edgeIds -join ', ')" -ForegroundColor Green
        }
    } else {
        Write-Host "  Nothing to do." -ForegroundColor DarkGray
    }
}

# ============================================================================
# CONFIRM + ROUND (canary-guarded)
# ============================================================================
if ($edgeIds.Count -gt 0) {
    Write-Host ""
    Write-Host ("  Ready: round $($edgeIds.Count) edge(s) at radius $RadiusValue.") -ForegroundColor Cyan
    Write-Host "  Do not touch Creo while this runs." -ForegroundColor DarkGray
    $go = Read-Host "  Proceed? (y/N)"
    if ($go -notmatch '^[Yy]$') {
        Write-Host "  Cancelled - no rounds applied." -ForegroundColor Yellow
    } else {
        Write-Host ""
        Write-Host "  Monitor Creo and click Ok if any rounds fail. You can fix them after." -ForegroundColor Gray
        Write-Host ""

        # Batch <=40 edges per round feature (radinator's proven batch size).
        $batchSize = 40
        $totalBatches = [Math]::Ceiling($edgeIds.Count / $batchSize)
        $batchNum = 0
        $batchesFired = 0
        $modelChanged = 0
        $aborted = $false
        $script:lastPct = -1

        for ($batchStart = 0; $batchStart -lt $edgeIds.Count; $batchStart += $batchSize) {
            $batchNum++
            $batchEnd = [Math]::Min($batchStart + $batchSize, $edgeIds.Count)
            $batchEdges = @($edgeIds[$batchStart..($batchEnd - 1)])

            Show-Progress ([Math]::Floor(($batchEnd / $edgeIds.Count) * 100)) "Batch $batchNum/$totalBatches"

            $stamp = $null
            try { $stamp = $model.VersionStamp } catch {}

            # clear -> accumulate this batch into the buffer -> fire one round
            try { $session.RunMacro("~ Command ``ProCmdSelClear``;") } catch {}
            try { $session.RunMacro((Build-EdgeSelectMacro -EdgeIds $batchEdges)) } catch {}

            $changed = $false
            try {
                $session.RunMacro((Build-RoundMacro -Radius $RadiusValue))
                $batchesFired++
                if ($null -ne $stamp) {
                    $changed = Wait-ModelModified -Model $model -PreviousStamp $stamp
                }
            } catch {
                Write-Log "Batch $batchNum macro error: $($_.Exception.Message)" "Yellow"
            }
            if ($changed) { $modelChanged++ }

            # canary: the FIRST batch must change the model, else abort (the round
            # mapkey widget names may need a refresh for this Creo build).
            if ($batchNum -eq 1 -and -not $changed) {
                Show-Progress 100 "Canary failed"
                Write-Host ""
                Write-Host "  ABORT: the first round batch did not modify the model" -ForegroundColor Red
                Write-Host "  (VersionStamp unchanged). Stopped after 1 batch. Check Creo:" -ForegroundColor Red
                Write-Host "  did the round dashboard open / error? The recorded round" -ForegroundColor Red
                Write-Host "  widget names (Build-RoundMacro) may need a refresh." -ForegroundColor Red
                $aborted = $true
                break
            }
        }
        if (-not $aborted) { Show-Progress 100 "Rounds complete" }
        Write-Host ""

        # ---- honest report ----
        Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
        Write-Host ("  Edges selected    : {0}" -f $edgeIds.Count) -ForegroundColor White
        Write-Host ("  Batches fired     : {0}" -f $batchesFired) -ForegroundColor White
        Write-Host ("  Model changed     : {0} batch(es)" -f $modelChanged) -ForegroundColor White
        Write-Host ""
        if ($aborted) {
            Write-Host "  STOPPED after the canary - inspect the model in Creo." -ForegroundColor Red
        } elseif ($modelChanged -eq $totalBatches) {
            Write-Host "  Done - round feature(s) created (model changed for each batch)." -ForegroundColor Green
            Write-Host "  NOTE: a count of batches FIRED, not rounds Creo geometrically" -ForegroundColor DarkGray
            Write-Host "  accepted. Verify the rounded corners visually in Creo." -ForegroundColor DarkGray
        } else {
            Write-Host "  Finished with issues - $modelChanged of $totalBatches batch(es) changed the model. Inspect Creo." -ForegroundColor Yellow
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
