<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

# ============================================================================
# drilljig.cmd - DRILL-JIG PROTOTYPE (jiginator + plane-probe + holeinator)
# ============================================================================
# One end-to-end run of the whole drill-jig flow, in a single console session
# and a SINGLE Creo connection:
#
#   STAGE 1   walk the decision tree (no Creo)        -> resolves the hole OD
#   (GUI)     POINT SOURCE -- right after the tree, the user picks how the target
#             hole points are sourced: (1) PREDEFINED (already in the CAD file),
#             (2) ORTHOGRID (regular Nx x Nz grid editor), or (3) CUSTOM (add each
#             point + type its X/Z offset). Modes 2/3 are pure WinForms, pre-filled
#             with the tree's hole Ã˜ + depth as read-only context, and capture the
#             spec into a shared $orthoGeo object (a .Mode tag distinguishes them);
#             no Creo yet.
#   STAGE 2   build a parametric box from offset planes (plane-probe v2). When a
#             layout was captured (mode 2/3), TOP offset = plate width and FRONT
#             offset = plate height come straight from the GUI (SIDE = bushing
#             length). Auto-mapped planes build the box with no prompts.
#   STAGE 2.5 (modes 2/3) create EVERY target datum point by the proven 3-plane
#             intersection recipe, with planes SHARED across points
#             (Get-SharedPlanePlan: 1 face + one plane per distinct X + one per
#             distinct Z). Works for both the regular grid and arbitrary custom
#             points. Falls back to manual point selection on any failure.
#   STAGE 3   drill an On-Point hole at every target point (created in 2.5, or
#             hand-selected in PREDEFINED mode), diameter from STAGE 1.
#   STAGE 4   (3DP: auto / metal: ask) cut chip-relief SLOTS -- one blind
#             rectangular remove-material slot per hole ROW (slotinator method:
#             seed-drawn once then patterned). Needs a GUI layout; skipped for
#             PREDEFINED points. REPLACES the old coaxial relief holes + relief
#             paths (both removed).
#
# This is a MERGE of three working tools (jiginator.cmd / plane-probe.cmd /
# holeinator.cmd). Those three are LEFT UNTOUCHED and still run standalone. The
# differences here vs. running them separately:
#   - the hole diameter is handed STAGE 1 -> STAGE 3 as an in-process variable,
#     NOT via last_jig_spec.json (the standalone tools still use that file);
#   - ONE Creo connection / config-suppress / finally wraps STAGES 2 + 3;
#   - the tree is walked ONCE (jiginator's "run again?" loop is dropped);
#   - only one press-any-key at the very end.
#
# DATUM POINTS: STAGE 2.5 GENERATES the target datum points from the GUI layout
# (orthogrid OR custom), laid out from the box's TOP/FRONT datums on the SIDE
# face. In PREDEFINED mode STAGE 2.5 is skipped and the prototype uses the
# original assumption -- the points ALREADY EXIST in the CAD file and STAGE 3
# hand-selects them. Open the jig PART (not the .asm) with its default datum
# planes (FRONT/RIGHT/TOP); pre-placed datum points are only needed in PREDEFINED
# mode.
#
# Provenance of the lifted logic (do not "improve" during the merge):
#   - jiginator helpers + tree walk (jiginator.cmd)
#   - plane-probe's v2 extrude-first / internal-sketch box build, the offset-
#     plane creation, the blind evaluator hook, and the resize loop
#   - holeinator's Build-HoleMacro (transcribed from a live recording) + canary
# ============================================================================

$Host.UI.RawUI.WindowTitle = "DRILLJIG"
$ErrorActionPreference = "Stop"

# --probe-judge : validate the BlueGPT REST judge round-trip (endpoint + auth)
# with a synthetic packet, then exit. No Creo connection, no model touched.
$ProbeJudge = ($ScriptArgs -match '(?i)(^|\s)-{1,2}probe-judge(\s|$)')


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

# ============================================================================
# STAGE 1 HELPERS - decision-tree walk (lifted from jiginator.cmd)
# ============================================================================

$dataDir = Join-Path $ScriptDir 'data'

# Load + filter the catalog and let the user pick one row.
# Returns the chosen row (PSCustomObject) or $null on quit / no matches.
function Invoke-BushingPick {
    param($Spec)

    if (-not (Test-Path $Spec.File)) {
        Write-Host "  Catalog file not found: $($Spec.File)" -ForegroundColor Red
        return $null
    }

    $rows = @(Import-Csv $Spec.File)

    foreach ($f in $Spec.Filters) {
        $col = $f.Column
        $vals = $f.Values
        $rows = @($rows | Where-Object {
            $cell = [double]$_.$col
            ($vals | Where-Object { [math]::Abs($cell - $_) -lt 1e-6 }).Count -gt 0
        })
    }

    if ($rows.Count -eq 0) {
        Write-Host "  No catalog rows match this selection." -ForegroundColor Yellow
        $crit = ($Spec.Filters | ForEach-Object { "$($_.Column) in {$($_.Values -join ', ')}" }) -join '; '
        Write-Host "  (file: $(Split-Path $Spec.File -Leaf); filter: $crit)" -ForegroundColor DarkGray
        return $null
    }

    # Two-stage pick: OD first (drives the hole), then length within that OD.
    # The user only needs to see OD + length; everything else is on the row.
    while ($true) {

        # --- stage 1: distinct ODs, ascending ---
        $odGroups = @($rows | Group-Object OD | Sort-Object { [double]$_.Name })
        Write-Host ""
        Write-Host "  Select OD (hole diameter):" -ForegroundColor Cyan
        for ($i = 0; $i -lt $odGroups.Count; $i++) {
            $g = $odGroups[$i]
            $lenWord = if ($g.Count -eq 1) { 'length' } else { 'lengths' }
            Write-Host ("    {0,3}) OD {1,-7} [hole = {2:0.###}]   ({3} {4})" -f `
                ($i + 1), (Get-FracLabel $g.Group[0].EasyName 'OD' $g.Name), $g.Name, $g.Count, $lenWord) `
                -ForegroundColor White
        }
        Write-Host ""

        $odPick = $null
        while ($true) {
            $raw = Read-Host "  Pick OD (1-$($odGroups.Count), or Q to skip)"
            if ($raw -match '^[Qq]$') { return $null }
            $n = 0
            if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $odGroups.Count) {
                $odPick = $odGroups[$n - 1]; break
            }
            Write-Host "  Enter a number between 1 and $($odGroups.Count)." -ForegroundColor Yellow
        }

        $odLabel = Get-FracLabel $odPick.Group[0].EasyName 'OD' $odPick.Name

        # --- stage 2: distinct lengths within the chosen OD, ascending ---
        # ID is intentionally hidden here - it doesn't change the jig hole (= OD).
        # If an OD+length has more than one ID, stage 3 offers the ID choice.
        $backToOd = $false
        while (-not $backToOd) {
            $lenGroups = @($odPick.Group | Group-Object Length | Sort-Object { [double]$_.Name })
            Write-Host ""
            Write-Host ("  Select length (OD {0}):" -f $odLabel) -ForegroundColor Cyan
            for ($i = 0; $i -lt $lenGroups.Count; $i++) {
                $lg = $lenGroups[$i]
                $lenLbl = Get-FracLabel $lg.Group[0].EasyName 'Lg' $lg.Name
                $extra = if ($lg.Count -gt 1) { "   ($($lg.Count) ID options)" } else { '' }
                Write-Host ("    {0,3}) {1,-7} Lg{2}" -f ($i + 1), $lenLbl, $extra) -ForegroundColor White
            }
            Write-Host ""

            $lenPick = $null
            while ($true) {
                $raw = Read-Host "  Pick length (1-$($lenGroups.Count), B to change OD, or Q to skip)"
                if ($raw -match '^[Qq]$') { return $null }
                if ($raw -match '^[Bb]$') { $backToOd = $true; break }
                $n = 0
                if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $lenGroups.Count) {
                    $lenPick = $lenGroups[$n - 1]; break
                }
                Write-Host "  Enter a number between 1 and $($lenGroups.Count) (or B / Q)." -ForegroundColor Yellow
            }
            if ($backToOd) { break }          # back to stage 1
            if ($null -eq $lenPick) { continue }

            # --- stage 3: ID step (ALWAYS explicit - never assume the ID) ---
            # ID does not change the jig hole (= OD). The user may leave it
            # unspecified, view the IDs, and from there skip or pick one.
            $idRows = @($lenPick.Group | Sort-Object { [double]$_.ID })
            $lenLbl = Get-FracLabel $idRows[0].EasyName 'Lg' $lenPick.Name
            $tag    = ($idRows[0].EasyName -split '\|')[0].Trim()

            # synthetic "ID unspecified" result - OD still drives the hole.
            # Carry Length too: the SIDE plane offset (box length) = bushing length,
            # and that must work even when the user leaves the ID unspecified.
            $idUnspec = [pscustomobject]@{
                EasyName   = "$tag | OD $odLabel x ID (any) x $lenLbl Lg"
                OD         = $idRows[0].OD
                ID         = '(any)'
                Length     = $idRows[0].Length
                PartNumber = '(ID unspecified)'
            }

            $idWord = if ($idRows.Count -eq 1) { 'is 1 ID' } else { "are $($idRows.Count) IDs" }

            $backToLen = $false
            while (-not $backToLen) {
                Write-Host ""
                Write-Host ("  ID for OD {0} x {1} Lg: there {2} on file." -f $odLabel, $lenLbl, $idWord) -ForegroundColor Cyan
                Write-Host "  ID does not change the jig hole (= OD); view it only if you need the exact bushing." -ForegroundColor DarkGray
                Write-Host ""
                $raw = Read-Host "  View IDs? (Y to list, N to leave ID unspecified, B to change length, Q to skip)"
                if ($raw -match '^[Qq]$') { return $null }
                if ($raw -match '^[Bb]$') { $backToLen = $true; break }
                if ($raw -match '^[Nn]?$') { return $idUnspec }   # N or blank -> unspecified
                if ($raw -notmatch '^[Yy]$') {
                    Write-Host "  Enter Y, N, B, or Q." -ForegroundColor Yellow
                    continue
                }

                # Y -> list the IDs; user may pick one, skip (unspecified), back, or quit
                while ($true) {
                    Write-Host ""
                    Write-Host ("  Select ID (OD {0} x {1} Lg):" -f $odLabel, $lenLbl) -ForegroundColor Cyan
                    for ($i = 0; $i -lt $idRows.Count; $i++) {
                        $r = $idRows[$i]
                        $bit = if ($r.PSObject.Properties.Name -contains 'DrillBitSize' -and $r.DrillBitSize) { "  ($($r.DrillBitSize))" } else { '' }
                        Write-Host ("    {0,3}) ID {1,-7}{2}   [{3}]" -f ($i + 1), $r.ID, $bit, $r.PartNumber) -ForegroundColor White
                    }
                    Write-Host ""
                    $raw = Read-Host "  Pick ID (1-$($idRows.Count), S to skip / leave unspecified, B to change length, Q to skip)"
                    if ($raw -match '^[Qq]$') { return $null }
                    if ($raw -match '^[Ss]$') { return $idUnspec }
                    if ($raw -match '^[Bb]$') { $backToLen = $true; break }
                    $n = 0
                    if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $idRows.Count) {
                        return $idRows[$n - 1]
                    }
                    Write-Host "  Enter a number between 1 and $($idRows.Count) (or S / B / Q)." -ForegroundColor Yellow
                }
            }
            # backToLen -> re-show length list
        }
    }
}

function Read-Choice {
    param([array]$Options, [string]$Prompt = 'Select')
    while ($true) {
        for ($i = 0; $i -lt $Options.Count; $i++) {
            $label = if ($Options[$i].label) { $Options[$i].label } else { '(untitled)' }
            Write-Host ("  {0}) {1}" -f ($i + 1), $label) -ForegroundColor White
        }
        Write-Host ""
        $raw = Read-Host "$Prompt (1-$($Options.Count), or Q to quit)"
        if ($raw -match '^[Qq]$') { return $null }
        $n = 0
        if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) {
            return $Options[$n - 1]
        }
        Write-Host "  Please enter a number between 1 and $($Options.Count)." -ForegroundColor Yellow
        Write-Host ""
    }
}

# Walk a node. $Path accumulates the chosen labels; $Outcomes collects leaves.
# Returns $true to continue, $false if the user quit.
function Invoke-Walk {
    param($Node, [System.Collections.ArrayList]$Path, [System.Collections.ArrayList]$Outcomes)

    switch ($Node.kind) {

        'question' {
            $opts = @($Node.children)
            if ($opts.Count -eq 0) {
                Write-Host "  (question '$($Node.label)' has no options - nothing to ask)" -ForegroundColor Yellow
                return $true
            }
            Write-Host ""
            Write-Host ">> $($Node.label)" -ForegroundColor Cyan
            if ($Node.notes) { Write-Host "   ($($Node.notes))" -ForegroundColor DarkGray }
            $chosen = Read-Choice -Options $opts -Prompt 'Answer'
            if ($null -eq $chosen) { return $false }
            [void]$Path.Add($chosen.label)
            return (Invoke-Walk -Node $chosen -Path $Path -Outcomes $Outcomes)
        }

        'option' {
            # an answer label; descend through its children in order
            foreach ($child in @($Node.children)) {
                $cont = Invoke-Walk -Node $child -Path $Path -Outcomes $Outcomes
                if (-not $cont) { return $false }
            }
            return $true
        }

        'outcome' {
            $spec = Get-CatalogSpec -Label $Node.label
            if ($spec) {
                $pick = Invoke-BushingPick -Spec $spec
                if ($pick) {
                    $od = [double]$pick.OD
                    # Bushing length drives the SIDE plane offset (box length) in
                    # STAGE 2. Parse defensively - $null if the row has no usable
                    # Length so the caller can fall back to a manual entry.
                    $blen = $null
                    try { if ($null -ne $pick.Length) { $blen = [double]$pick.Length } } catch {}
                    [void]$Outcomes.Add(("Bushing: {0}  ->  hole diameter = {1}`" (OD), length = {2}`"" -f $pick.EasyName, $od, $blen))
                    # record the resolved hole spec for the in-process handoff to STAGE 3
                    [void]$script:Picks.Add([pscustomobject]@{
                        HoleDiameter  = $od
                        BushingLength = $blen
                        Bushing       = $pick.EasyName
                        PartNumber    = $pick.PartNumber
                        Outcome       = $Node.label
                    })
                } else {
                    [void]$Outcomes.Add("(no bushing selected) $($Node.label)")
                }
            } else {
                # Not a catalog leaf. Some leaves declare the hole OD outright
                # (metal -> PFD: "the OD of the hole will be 3/4 in"). Resolve the
                # diameter straight from the label, with NO bushing pick. There is
                # no bushing => no length, so BushingLength stays $null and STAGE 2's
                # SIDE offset falls back to a manual entry (only the OD is fixed).
                $fixedOd = Get-FixedOdSpec -Label $Node.label
                if ($null -ne $fixedOd) {
                    [void]$Outcomes.Add(("Fixed hole diameter = {0}`" (OD) -- {1}" -f $fixedOd, $Node.label))
                    [void]$script:Picks.Add([pscustomobject]@{
                        HoleDiameter  = [double]$fixedOd
                        BushingLength = $null
                        Bushing       = "(fixed OD, no bushing)"
                        PartNumber    = "(n/a)"
                        Outcome       = $Node.label
                    })
                } else {
                    [void]$Outcomes.Add($Node.label)
                }
            }
            return $true
        }

        'bushing' {
            # placeholder until the catalog filter + pick is wired in
            [void]$Outcomes.Add("[BUSHING PICK] $($Node.label)")
            foreach ($child in @($Node.children)) {
                $cont = Invoke-Walk -Node $child -Path $Path -Outcomes $Outcomes
                if (-not $cont) { return $false }
            }
            return $true
        }

        'pattern' {
            [void]$Outcomes.Add("[PATTERN GROUPING] $($Node.label)")
            foreach ($child in @($Node.children)) {
                $cont = Invoke-Walk -Node $child -Path $Path -Outcomes $Outcomes
                if (-not $cont) { return $false }
            }
            return $true
        }

        default {
            Write-Host "  (unknown node kind '$($Node.kind)' - skipping)" -ForegroundColor Yellow
            return $true
        }
    }
}

# ============================================================================
# STAGE 2 HELPERS - parametric box (lifted from plane-probe.cmd)
# ============================================================================

# Fire a mapkey and report success/failure instead of swallowing it (boxinator's
# pattern). A silent no-op from a wrong widget name is the hardest mapkey bug to
# find, so count failures and surface them.
$script:macroFailures = 0

# The three offsets ARE the box dimensions: Side->Width, Top->Height,
# Front->Depth. With the part's three default datums forming the box's anchored
# corner, these three offset planes are the three opposite faces.
function Show-BoxState {
    param($Made)
    Write-Host "  Parametric box planes (offset = box extent):" -ForegroundColor Green
    for ($i = 0; $i -lt $Made.Count; $i++) {
        $p   = $Made[$i]
        $now = Read-DimValue -Model $model -TypeObj $pfcType -Sym $p.Sym
        $dim = switch ($p.Label) { "Side" { "Width" } "Top" { "Height" } "Front" { "Depth" } default { "" } }
        Write-Host ("    [{0}] {1,-5} ({2,-6}) {3,-6} = {4}" -f ($i + 1), $p.Label, $dim, $p.Sym, $now) -ForegroundColor White
    }
}

# Blind-evaluator hook: converge on "the SOLID matches what you ASKED FOR".
# $Expected is an array of @{ Dim = "Width"; Value = 4.0 } - the values the CALLER
# intended. Deterministic numeric match gates; the LLM verdict is advisory.
# $model/$pfcType/$judgeCfg/$ScriptDir come from the enclosing scope.
function Invoke-BoxEval {
    param([string]$Operation, $Expected)

    # Measure the solid itself.
    $excl = New-ExcludeTypes -TypeObj $pfcType
    $ext  = Measure-Extents -Solid $model -ExcludeTypes $excl

    $truth = @{}
    $measuredSorted = $null
    if ($null -ne $ext) {
        $measuredSorted = @($ext | Sort-Object -Descending | ForEach-Object { [math]::Round([double]$_, 4) })
        $truth["measured_extents_sorted_desc"] = $measuredSorted
    } else {
        $truth["measured_extents_sorted_desc"] = $null
        $truth["note"] = "EvalOutline returned no outline (the solid may not exist yet)"
    }
    # Record what was REQUESTED (intent) in the slice too.
    $reqMap = @{}
    foreach ($e in $Expected) { $reqMap[[string]$e.Dim] = [double]$e.Value }
    $truth["requested_dims"] = $reqMap

    # (1) deterministic by-value match - the gate.
    $expectedVals = @($Expected | ForEach-Object { [double]$_.Value })
    $measuredVals = if ($null -ne $measuredSorted) { @($measuredSorted | ForEach-Object { [double]$_ }) } else { @() }
    $numeric = Test-ExtentsMatch -Expected $expectedVals -Measured $measuredVals -Tol 0.1

    # Human-readable claims (used by the LLM layer + persisted in the packet).
    $claims = @($Expected | ForEach-Object { "the box {0} is {1}" -f $_.Dim.ToLower(), $_.Value })

    $modelName = try { [string]$model.FileName } catch { "(unknown)" }
    $claim = New-EvalClaim -Tool "drilljig" -Operation $Operation -Claims $claims
    $slice = Get-GeometrySlice -Model $modelName -Truth $truth

    $base = ($modelName -replace '\.(prt|asm)(\.\d+)?$','') -replace '[^\w\-]','_'
    $packetPath = Join-Path $ScriptDir ($base + "_eval.json")
    $when = (Get-Date).ToString("o")
    Write-EvalPacket -Path $packetPath -Claim $claim -Slice $slice -WhenIso $when | Out-Null
    Write-Host "  Eval packet -> $packetPath" -ForegroundColor DarkGray

    # (2) LLM layer - judge the PERSISTED packet (so what is judged == what's on disk).
    $packetObj = Get-Content $packetPath -Raw | ConvertFrom-Json
    $verdict = Invoke-BlindJudge -Packet $packetObj -Config $judgeCfg

    # Gate on the deterministic numeric result; LLM verdict is advisory.
    return (Show-ConvergenceReport -Verdict $verdict -Title "Blind evaluator: $Operation" -Numeric $numeric)
}

# ============================================================================
# STAGE 3 HELPERS - hole creation (lifted from holeinator.cmd)
# ============================================================================

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

# ============================================================================
# HEADER
# ============================================================================
Write-Host ""
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "   DRILLJIG  -  tree -> parametric box -> drill holes (one session)" -ForegroundColor Cyan
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "  (prototype: merges jiginator + plane-probe + holeinator; originals" -ForegroundColor DarkGray
Write-Host "   are untouched and still run standalone)" -ForegroundColor DarkGray
Write-Host ""

# ============================================================================
# SHARED LIBRARY (geometry reads + blind evaluator)
# ============================================================================
. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')
. (Join-Path $ScriptDir 'lib\blind_evaluator.ps1')
# hands-free edge rounding (sweep GetItemById -> filter by EvalLength -> AddSelection
# -> round; NO find tool). Used right after the STAGE 2 box build to round corners.
. (Join-Path $ScriptDir 'lib\edge_round.ps1')
# STAGE 2.5 orthogrid: grid MATH (pure), the WinForms editor, and the datum-point
# grid creation/resolution. _gui needs _math (Get-OrthogridGeometry) in scope;
# _points' Build-PointGridMacro calls Get-SelectByIdMacro (defined below in this
# file) at fire time -- dot-sourcing shares one scope, so the order here is fine.
. (Join-Path $ScriptDir 'lib\orthogrid.ps1')
. (Join-Path $ScriptDir 'lib\orthogrid_gui.ps1')
. (Join-Path $ScriptDir 'lib\orthogrid_points.ps1')
# The shared Creo engine: drilljig-gui.cmd + this console tool share ONE copy of
# the proven helpers (Build-HoleMacro, New-OffsetPlane, etc.) via this lib. A
# parity test in the suite fails if any helper drifts back into this file.
. (Join-Path $ScriptDir 'lib\drilljig_core.ps1')
# Initialize with DataDir now (for the tree/catalog walk in STAGE 1); session/model/
# type are not available until connect (~line 1204). Re-initialized after connect.
Initialize-DrilljigCore -Session $null -Model $null -TypeObj $null -DataDir $dataDir -Log $null

# --probe-judge: validate the REST judge in isolation, then exit (no Creo).
if ($ProbeJudge) {
    $ok = Invoke-JudgeProbe -RepoRoot $ScriptDir -Model "sonnet"
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit ([int](-not $ok))
}

# ============================================================================
# STAGE 1 -- DECISION TREE (no Creo). Walk ONCE -> the hole diameter.
# ============================================================================
$treePath = Join-Path $ScriptDir 'docs\drill_jig_decision_tree.json'
if (-not (Test-Path $treePath)) {
    throw "Decision tree not found at: $treePath  (build it in docs\drill_jig_tree_builder.html first)"
}
try {
    $tree = Get-Content $treePath -Raw | ConvertFrom-Json
} catch {
    throw "Could not parse the tree JSON: $($_.Exception.Message)"
}
# ConvertFrom-Json gives a single object if the root array has one element;
# normalize to an array either way.
$roots = @($tree)

Write-Host "  STAGE 1 - Drill-jig decision tree" -ForegroundColor Green
Write-Host "  Reading tree: $treePath" -ForegroundColor DarkGray

$path     = [System.Collections.ArrayList]::new()
$outcomes = [System.Collections.ArrayList]::new()
$script:Picks = [System.Collections.ArrayList]::new()

$quit = $false
foreach ($root in $roots) {
    $cont = Invoke-Walk -Node $root -Path $path -Outcomes $outcomes
    if (-not $cont) { $quit = $true; break }
}

if ($quit) {
    Write-Host ""
    Write-Host "  Cancelled in the decision tree - nothing built, no Creo connection made." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 0
}

Write-Host ""
Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
Write-Host "  Your selections:" -ForegroundColor Green
Write-Host ("    " + ($path -join "  >  ")) -ForegroundColor White
Write-Host ""
Write-Host "  Result:" -ForegroundColor Green
foreach ($o in $outcomes) { Write-Host "    $o" -ForegroundColor White }
Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
Write-Host ""

# In-process handoff: if several outcomes resolved a bushing, the LAST pick wins
# (matches jiginator's model). NO file is written here - these are carried into
# STAGES 2/3 as variables:
#   $holeDia    -> the STAGE 3 hole diameter (= bushing OD), used WITHOUT prompting
#   $bushingLen -> the STAGE 2 SIDE-plane offset (box length = bushing/sleeve length)
$holeDia    = $null
$bushingLen = $null
if ($script:Picks.Count -gt 0) {
    $active  = $script:Picks[$script:Picks.Count - 1]
    $holeDia = [double]$active.HoleDiameter
    if ($null -ne $active.BushingLength) { $bushingLen = [double]$active.BushingLength }
    Write-Host ("  Hole diameter from the tree: {0}`"  ({1})" -f $holeDia, $active.Bushing) -ForegroundColor Cyan
    if ($null -ne $bushingLen) {
        Write-Host ("  Bushing length from the tree: {0}`"  -> SIDE plane offset (box length)" -f $bushingLen) -ForegroundColor Cyan
    } else {
        Write-Host "  (the chosen bushing row had no usable Length - SIDE offset will be entered by hand)" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  The decision tree did not resolve a bushing / hole diameter." -ForegroundColor Yellow
    Write-Host "  You can still build the box now and enter the dimensions by hand." -ForegroundColor DarkGray
}
Write-Host ""

# Material drives STAGE 4's chip-relief-SLOT gate. A 3D-printed part ALWAYS gets the
# slots made automatically (no y/N) so the run doesn't pause for a confirmation we
# already know the answer to; metal (or any non-3D-print / unresolved path) keeps the
# human y/N gate. The material is the user's answer to the root question, which the
# walk recorded into $path -- the "3d print" signal only ever enters $path via that
# material option (the metal sub-answers are "PFD"/"Hand Drill"), so matching $path
# for it is unambiguous. Safe default: auto-act ONLY on the explicit 3D-print choice.
$is3dPrint = @($path | Where-Object { $_ -match '(?i)3d\s*print' }).Count -gt 0
if ($is3dPrint) {
    Write-Host "  Material: 3D print -> chip-relief slots will be added automatically (STAGE 4, no prompt)." -ForegroundColor Cyan
    Write-Host ""
}

# ============================================================================
# POINT SOURCE (GUI) -- right after the decision tree, BEFORE Creo.
# ============================================================================
# The user picks HOW the target hole points are sourced -- three modes:
#   1. PREDEFINED  -- the datum points already exist in the CAD file; STAGE 2.5 is
#                     skipped and STAGE 3 hand-selects them (the original flow).
#   2. ORTHOGRID   -- regular Nx x Nz grid laid out in Show-OrthogridDialog.
#   3. CUSTOM      -- arbitrary, per-point layout in Show-CustomPointsDialog: the
#                     operator adds each point and types its X/Z offset.
# Both create-modes are pure WinForms (no Creo), so they run here while the tree's
# numbers are fresh and BEFORE we connect. They only CAPTURE the spec into the
# shared $orthoGeo object (Get-Custom/OrthogridGeometry are shape-compatible, with
# a .Mode tag); the datum points are CREATED later in STAGE 2.5 once the box + its
# TOP/SIDE/FRONT datums exist. The decision-tree hole diameter ($holeDia) and bushing
# length / drill depth ($bushingLen) are passed in as read-only context. The hole dia
# ALSO sizes the plate (the dialog feeds it to the math layer as -ClearDia), so the
# box Width/Height clears the hole at the border. Cancelling a create dialog falls
# back to PREDEFINED (hand-selected).
$orthoGeo  = $null
$pointMode = 'predefined'

Write-Host "  How should the target hole points be sourced?" -ForegroundColor Cyan
Write-Host "    1) I already have datum points in the part   (select them later)" -ForegroundColor White
Write-Host "    2) Create a regular orthogrid pattern         (Nx x Nz grid editor)" -ForegroundColor White
Write-Host "    3) Create custom points one at a time         (type each X/Z offset)" -ForegroundColor White
$modeRaw = Read-Host "  Choose 1 / 2 / 3 (default 1)"
switch ($modeRaw.Trim()) {
    '2'     { $pointMode = 'orthogrid' }
    '3'     { $pointMode = 'custom' }
    default { $pointMode = 'predefined' }
}

if ($pointMode -eq 'predefined') {
    Write-Host "  Using PRE-EXISTING datum points - STAGE 3 will hand-select them." -ForegroundColor DarkGray
} elseif ($pointMode -eq 'orthogrid') {
    try { $orthoGeo = Show-OrthogridDialog -HoleDiameter $holeDia -Thickness $bushingLen } catch { $orthoGeo = $null }
    if ($null -eq $orthoGeo) {
        Write-Host "  Orthogrid editor cancelled (or unavailable) - STAGE 3 will use hand-selected points." -ForegroundColor Yellow
        $pointMode = 'predefined'
    } else {
        Write-Host ("  Grid captured: {0} holes, part {1:0.00} x {2:0.00} (Nx={3}, Nz={4}, cc {5}x{6}, edge {7}, relief-clear {8}). Points created in STAGE 2.5." -f `
            $orthoGeo.Count, $orthoGeo.Width, $orthoGeo.Height, $orthoGeo.Nx, $orthoGeo.Nz, $orthoGeo.CcX, $orthoGeo.CcZ, $orthoGeo.Edge, $orthoGeo.ClearDia) -ForegroundColor Green
    }
} else {
    # custom -- arbitrary per-point layout
    try { $orthoGeo = Show-CustomPointsDialog -HoleDiameter $holeDia -Thickness $bushingLen } catch { $orthoGeo = $null }
    if ($null -eq $orthoGeo) {
        Write-Host "  Custom-points editor cancelled (or unavailable) - STAGE 3 will use hand-selected points." -ForegroundColor Yellow
        $pointMode = 'predefined'
    } else {
        Write-Host ("  Custom layout captured: {0} hole(s), part {1:0.00} x {2:0.00} ({3}, relief-clear {4}). Points created in STAGE 2.5." -f `
            $orthoGeo.Count, $orthoGeo.Width, $orthoGeo.Height, $orthoGeo.WidthMode, $orthoGeo.ClearDia) -ForegroundColor Green
        if ($orthoGeo.SkippedOrigin -gt 0) {
            Write-Host ("  ({0} point(s) at the origin were dropped - no hole will be drilled at the part corner.)" -f $orthoGeo.SkippedOrigin) -ForegroundColor DarkGray
        }
    }
}
Write-Host ""

# ============================================================================
# CONNECT ONCE (single session) -- wraps STAGES 2 + 3
# ============================================================================
# Resolve the judge config once up front. $null is fine - the evaluator then just
# writes the packet and skips the REST call.
$judgeCfg = Get-JudgeConfig -RepoRoot $ScriptDir -DefaultModel "sonnet"
if ($null -eq $judgeCfg) {
    Write-Host "  (blind judge not configured - eval packets will be written for offline judging)" -ForegroundColor DarkGray
} else {
    Write-Host "  Blind judge: $($judgeCfg.base) [$($judgeCfg.model)]" -ForegroundColor DarkGray
}
Write-Host ""

$procs = @(Get-Process | Where-Object { $_.ProcessName -eq "xtop" })
if ($procs.Count -eq 0) { throw "Creo (xtop.exe) is not running" }
if ($procs.Count -gt 1) {
    throw "More than one Creo session is open. This prototype expects exactly ONE (no session picker here)."
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
if ($null -eq $model) { throw "No active model. Open the jig PART (default datum planes + the target datum points) first." }

Write-Host "  Connected. Active model: $($model.FileName)" -ForegroundColor Green

# Mode guard: this tool drills a PART. In assembly mode the datum points and
# by-ID selection resolve against the .asm, not the part to drill. Key off the
# filename extension (EpfcModelType enum ints are unconfirmed on this build).
$modelFile = ""
try { $modelFile = [string]$model.FileName } catch {}
if ($modelFile -match '\.asm(\.\d+)?$') {
    Write-Host ""
    Write-Host "  STOP: the active model is an ASSEMBLY ($modelFile)." -ForegroundColor Yellow
    Write-Host "  This prototype builds + drills a single PART. Open the jig PART" -ForegroundColor Yellow
    Write-Host "  itself (activate it in its own window), then re-run." -ForegroundColor Yellow
    Write-Host ""
    $connection.Disconnect($null)
    exit 1
}
Write-Host ""

# Suppress UI noise during the run, restore in finally (toolkit convention).
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

# $pfcType defined ONCE here, shared by STAGES 2 + 3.
$pfcType = New-Object -ComObject pfcls.pfcModelItemType
# Re-initialize the shared engine now that session/model/type are available (the
# first Initialize before STAGE 1 only set DataDir for the catalog walk).
Initialize-DrilljigCore -Session $session -Model $model -TypeObj $pfcType -DataDir $dataDir -Log $null

try {

# ============================================================================
# STAGE 2 -- PARAMETRIC BOX (plane-probe v2)
# ============================================================================
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "   STAGE 2 - parametric box from three offset datum planes" -ForegroundColor Cyan
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host ""

# Each label is descriptive - the actual base plane is whatever you pick.
# Top offsets TOP (height), Side offsets SIDE (width), Front offsets FRONT (depth).
$planes = @(
    [pscustomobject]@{ Label = "Top";   Hint = "TOP";   Offset = 0.0; Sym = $null; BaseId = $null; FeatId = $null }
    [pscustomobject]@{ Label = "Side";  Hint = "SIDE";  Offset = 0.0; Sym = $null; BaseId = $null; FeatId = $null }
    [pscustomobject]@{ Label = "Front"; Hint = "FRONT"; Offset = 0.0; Sym = $null; BaseId = $null; FeatId = $null }
)

# Plane-offset sources, in priority order:
#   * SIDE  = box LENGTH, fixed by the decision tree = the bushing/sleeve length
#             ($bushingLen). Not prompted when the tree resolved a length.
#   * TOP   = plate WIDTH  and  FRONT = plate HEIGHT, taken from the orthogrid GUI
#             ($orthoGeo) when a pattern was laid out -- the plate is sized to hold
#             the grid, so the box face dims ARE the grid's plate extents. Per the
#             grid contract X/Width runs along TOP and Z/Height along FRONT, so
#             TOP<-Width, FRONT<-Height. Not prompted when $orthoGeo is present.
#   * anything still unset -> manual prompt (blank/0 -> 1.0 so it has a drivable dim).
Write-Host "  Box offsets:" -ForegroundColor Cyan
foreach ($p in $planes) {
    if ($p.Label -eq "Side" -and $null -ne $bushingLen) {
        $p.Offset = [double]$bushingLen
        Write-Host ("    SIDE offset (box length) = {0} (from the bushing length; not asked)" -f $bushingLen) -ForegroundColor Green
        continue
    }
    if ($p.Label -eq "Top" -and $null -ne $orthoGeo) {
        $p.Offset = [double]$orthoGeo.Width
        Write-Host ("    TOP offset (plate width)  = {0} (from the orthogrid plate; not asked)" -f $p.Offset) -ForegroundColor Green
        continue
    }
    if ($p.Label -eq "Front" -and $null -ne $orthoGeo) {
        $p.Offset = [double]$orthoGeo.Height
        Write-Host ("    FRONT offset (plate height) = {0} (from the orthogrid plate; not asked)" -f $p.Offset) -ForegroundColor Green
        continue
    }
    $raw = Read-Host "    $($p.Label) plane offset (from $($p.Hint))"
    $v = 0.0
    if (-not [double]::TryParse($raw, [ref]$v) -or $v -eq 0) {
        Write-Host "      using 1.0" -ForegroundColor Yellow
        $v = 1.0
    }
    $p.Offset = $v
}
Write-Host ""

# --- capture the three base-plane IDs ---------------------------------------
# PREFERRED (no clicks): AUTO-DISCOVER the three default datums by NAME via the API
# (Find-DefaultDatumPicks enumerates ITEM_FEATURE + GetName()). The default datums
# are named literally TOP/SIDE/FRONT and are the same every part, so no user
# selection is needed -- the program finds them itself.
#   2nd CHOICE: if auto-discovery doesn't yield a clean all-three mapping (oddly
#     named part, GetName() miss), ONE multi-select of all three datums (Ctrl-click,
#     any order) read by NAME (Read-SelectionPlanePicks).
#   LAST RESORT: per-plane sequential capture (one click each).
# All three feed the SAME auto-map block, so the box build runs hands-free once the
# roles are known (SIDE drives the sketch plane + the extrude-to plane).
$autoMapped = $false

# 1) try the API first -- no selection, no prompt.
$picks = @(Find-DefaultDatumPicks)
$autoFound = ($picks | Where-Object { $null -ne $_.Role } | Select-Object -ExpandProperty Role -Unique)
if (@($autoFound).Count -ge 3) {
    Write-Host "  Found the three default datums by name (no selection needed):" -ForegroundColor Cyan
} else {
    # 2) API didn't find all three -- ask for the one multi-select.
    Write-Host "  Could not auto-find all three default datums by name -- identify them." -ForegroundColor Yellow
    Write-Host "  In Creo, Ctrl-click ALL THREE default datums (TOP, SIDE, FRONT) - any order -" -ForegroundColor White
    Write-Host "  then press ENTER here. (They are matched to roles by NAME, not click order.)" -ForegroundColor White
    Read-Host
    $picks = @(Read-SelectionPlanePicks)
}

if ($picks.Count -gt 0) {
    Write-Host ("  Read {0} selected datum(s):" -f $picks.Count) -ForegroundColor DarkGray
    foreach ($pk in $picks) {
        $nm = if ($pk.Name) { $pk.Name } else { "(no name)" }
        $rl = if ($pk.Role) { $pk.Role.ToUpper() } else { "unmatched" }
        Write-Host ("      id $($pk.Id)  name '$nm'  -> $rl") -ForegroundColor DarkGray
    }

    # assign each plane its base id by matched role; flag any conflict/gap
    $byRole = @{}
    $conflict = $false
    foreach ($pk in $picks) {
        if ($null -eq $pk.Role) { continue }
        if ($byRole.ContainsKey($pk.Role)) { $conflict = $true; continue }   # two datums claim the same role
        $byRole[$pk.Role] = $pk.Id
    }
    $allRolesPresent = ($byRole.ContainsKey('Top') -and $byRole.ContainsKey('Side') -and $byRole.ContainsKey('Front'))

    if ($allRolesPresent -and -not $conflict) {
        foreach ($p in $planes) { $p.BaseId = [int]$byRole[$p.Label] }
        Write-Host ""
        Write-Host "  Auto-mapped by name:" -ForegroundColor Green
        foreach ($p in $planes) {
            $dim = switch ($p.Label) { "Side" {"Width/length"} "Top" {"Height"} "Front" {"Depth"} default {""} }
            Write-Host ("      {0,-5} ({1,-12}) = datum id {2}" -f $p.Hint, $dim, $p.BaseId) -ForegroundColor White
        }
        Write-Host "  SIDE also becomes the sketch plane + extrude-to reference (hands-free box build)." -ForegroundColor DarkGray
        # Clean, unambiguous all-three mapping by name -> proceed automatically (no
        # accept prompt). The ambiguous cases below (conflict / missing role / empty
        # buffer) still fall back to one-click-per-plane.
        $autoMapped = $true
        Write-Host "  Proceeding with this mapping automatically." -ForegroundColor DarkGray
    } else {
        Write-Host ""
        if ($conflict) {
            Write-Host "  Two datums matched the same role - cannot auto-map by name." -ForegroundColor Yellow
        } else {
            $missing = @('Top','Side','Front' | Where-Object { -not $byRole.ContainsKey($_) })
            Write-Host ("  Could not match all three roles by name (missing: {0})." -f ($missing -join ', ')) -ForegroundColor Yellow
        }
        Write-Host "  Falling back to one-click-per-plane capture." -ForegroundColor Yellow
    }
} else {
    Write-Host "  Nothing was selected - falling back to one-click-per-plane capture." -ForegroundColor Yellow
}

# FALLBACK: original sequential capture - one quick click per plane, in order.
if (-not $autoMapped) {
    Write-Host ""
    foreach ($p in $planes) {
        Read-Host "    Click the $($p.Hint) plane in Creo, then press ENTER"
        $contents = ($session.CurrentSelectionBuffer()).Contents
        if ($null -eq $contents -or $contents.Count -eq 0) {
            throw "Nothing was selected for the $($p.Hint) plane. Click the plane, then press ENTER."
        }
        $p.BaseId = [int]$contents[$contents.Count - 1].SelItem.Id
        Write-Host "      $($p.Hint) base feature ID = $($p.BaseId)" -ForegroundColor DarkGray
    }
}
Write-Host ""

# --- create the three offset planes (select base BY ID -> atomic macro, x3) ---
Write-Host "  Creating all three offset planes (no further clicks needed)..." -ForegroundColor Cyan
Write-Host ""
foreach ($p in $planes) {
    Write-Host "  --- $($p.Label) plane (offset $($p.Offset) from $($p.Hint), id $($p.BaseId)) ---" -ForegroundColor Cyan
    $res = New-OffsetPlane -Label $p.Label -Offset $p.Offset -BaseId $p.BaseId
    $p.Sym    = $res.Symbol
    $p.FeatId = $res.FeatId
    Write-Host ""
}

# --- show (unhide) the new offset planes; runs on FeatId, before the dim gate ---
$toShow = @($planes | Where-Object { $null -ne $_.FeatId })
if ($toShow.Count -gt 0) {
    Write-Host "  Showing the $($toShow.Count) new offset plane(s)..." -ForegroundColor Cyan
    foreach ($p in $toShow) {
        $showMacro =
            (Get-SelectByIdMacro -FeatId $p.FeatId) +
            "~ Command ``ProCmdViewShow@PopupMenuTree``;"
        Invoke-Macro "show $($p.Label) plane (id $($p.FeatId))" $showMacro
    }
    Write-Host ""
}

# Gate the parametric/resize half on planes that produced a DRIVABLE dim.
$made = @($planes | Where-Object { $null -ne $_.Sym })
if ($made.Count -eq 0) {
    throw "No offset planes produced a drivable dim - nothing to resize. (Any planes that WERE created have been shown above.)"
}
if ($made.Count -lt 3) {
    Write-Host "  WARNING: only $($made.Count) of 3 planes produced a drivable dim." -ForegroundColor Yellow
    Write-Host ""
}

Show-BoxState -Made $made
Write-Host ""

# --- CREATE THE BOX: extrude-first with an internal sketch (plane-probe v2) ---
# DIRECTION: sketch ON the og/default datum, extrude UP TO the offset plane, so
# the feature reads og -> offset. Stays parametric because the og datum and the
# offset plane are separated by exactly the offset dim. Both refs captured BY ID
# up front; the ONLY manual step is drawing the rough rectangle (forces ONE split
# into two macros around the user's draw).
$sidePlane = @($made | Where-Object { $_.Label -eq "Side" })
$sidePlane = if ($sidePlane.Count -gt 0) { $sidePlane[0] } else { $null }

$sketchPlaneId = $null
$script:buildConfirmed = $null
# Auto-build when the planes were cleanly auto-mapped by name (no prompt - the box
# build is hands-free in that case). Only ask when we fell back to manual plane
# picking, where the user may want to skip straight to resize.
if ($autoMapped) {
    $doBox = "y"
    Write-Host "  Building the box automatically (planes mapped by name; extrude-first, internal sketch)..." -ForegroundColor Cyan
} else {
    Write-Host "  Build the box now? (Extrude-first, internal sketch; og -> offset direction)" -ForegroundColor Cyan
    $doBox = Read-Host "    (y to create the box, anything else to skip and go straight to resize)"
}
if ($doBox.Trim().ToUpper() -eq "Y") {
    if ($null -eq $sidePlane) {
        Write-Host "  No SIDE plane was created, so there is nothing to build against. Skipping box." -ForegroundColor Yellow
    }
    # HANDS-FREE PATH: the all-three multi-select already identified SIDE by name
    # AND confirmed once, so the box's two references are known with no further
    # clicks - sketch ON the SIDE og/default datum ($sidePlane.BaseId), extrude UP
    # TO the SIDE offset plane ($sidePlane.FeatId). This is exactly the user ask:
    # "draw on the SIDE plane and the offset to that plane." Requires both ids.
    elseif ($autoMapped -and $null -ne $sidePlane.BaseId -and $null -ne $sidePlane.FeatId) {
        $sketchPlaneId = [int]$sidePlane.BaseId
        $extrudeToId   = [int]$sidePlane.FeatId
        Write-Host ""
        Write-Host "  Box references taken from the SIDE mapping (no clicks needed):" -ForegroundColor Green
        Write-Host "      sketch on   SIDE og/default datum (id $sketchPlaneId)" -ForegroundColor White
        Write-Host "      extrude to  SIDE offset plane      (id $extrudeToId)" -ForegroundColor White
    }
    # FALLBACK PATH: no clean auto-map (or SIDE ids missing) - click each plane.
    else {

        Write-Host ""
        Write-Host "  In Creo: CLICK the og/default datum to sketch the box footprint on," -ForegroundColor White
        Write-Host "  then press ENTER. (Tip: this is normally the SIDE datum.)" -ForegroundColor White
        Read-Host
        $sketchPlaneId = Read-SelectedId
        if ($null -eq $sketchPlaneId) {
            Write-Host "  Nothing selected for the sketch plane - skipping box." -ForegroundColor Yellow
        } else {
            Write-Host "      sketch plane feature ID = $sketchPlaneId" -ForegroundColor DarkGray
        }

        if ($null -ne $sketchPlaneId) {
            Write-Host ""
            Write-Host "  In Creo: CLICK the OFFSET plane to extrude UP TO (the box grows" -ForegroundColor White
            Write-Host "  from the og plane toward this datum), then press ENTER. Or just" -ForegroundColor White
            Write-Host "  press ENTER to use the SIDE offset plane." -ForegroundColor White
            Read-Host
            $extrudeToId = Read-SelectedId
            if ($null -eq $extrudeToId) {
                $extrudeToId = $sidePlane.FeatId
                Write-Host "      extruding up to SIDE offset plane (id $extrudeToId)" -ForegroundColor DarkGray
            } else {
                Write-Host "      extrude-to feature ID = $extrudeToId" -ForegroundColor DarkGray
            }
        }
    }

    if ($null -ne $sketchPlaneId) {

        $stamp = $null
        try { $stamp = $model.VersionStamp } catch {}

        # MACRO A: select sketch plane BY ID FIRST (its buffer_clean wipes the
        # stale offset plane), -> ProCmdFtExtrude consumes the og datum -> orient
        # -> arm the corner-rectangle tool. Stops before the manual draw.
        $mkArm =
            (Get-SelectByIdMacro -FeatId $sketchPlaneId) +
            "~ Command ``ProCmdFtExtrude``;" +
            "~ Command ``ProCmdViewSketchView``;" +
            "~ Command ``ProCmdSketRectangle`` 1;"
        Invoke-Macro "select sketch plane (id $sketchPlaneId) + extrude + arm rectangle" $mkArm

        Write-Host ""
        Write-Host "  In Creo (internal sketcher): click one corner of the rectangle, then" -ForegroundColor White
        Write-Host "  the opposite corner. Size doesn't matter. Press Esc to finish the" -ForegroundColor White
        Write-Host "  rectangle, then press ENTER here." -ForegroundColor White
        Read-Host

        # MACRO B: finish the internal sketch, set depth UP TO the extrude-to
        # plane, blur the field, confirm. The extrude-to plane is fed to the open
        # depth collector via Get-SelectDatumByIdMacro (type DATUM, surfenator's
        # proven up-to-plane feed) -- NOT the Feature-typed Get-SelectByIdMacro,
        # which left the dashboard waiting for a manual plane click. No buffer_clean
        # (clearing mid-dashboard can deactivate the open collector).
        $mkFinish =
            "~ Command ``ProCmdSketDone``;" +
            "~ Select ``main_dlg_cur`` ``maindashInst0.depth_flyout``;" +
            "~ Close ``main_dlg_cur`` ``maindashInst0.depth_flyout``;" +
            "~ Activate ``main_dlg_cur`` ``maindashInst0.toselected`` 1;" +
            "~ Trigger ``extrev_1_placement.0.0`` ``PH.section_select_list`` ``0``;" +
            "~ Trigger ``extrev_1_placement.0.0`` ``PH.section_select_list`` ````;" +
            (Get-SelectDatumByIdMacro -FeatId $extrudeToId) +
            "~ Enter ``main_dlg_cur`` ``dashInst0.Quit``;" +
            "~ Exit  ``main_dlg_cur`` ``dashInst0.Quit``;" +
            "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"
        Invoke-Macro "finish sketch + extrude up to plane id $extrudeToId + confirm" $mkFinish

        if ($null -ne $stamp) {
            for ($i = 0; $i -lt 100; $i++) {
                try { if ($model.VersionStamp -ne $stamp) { break } } catch {}
                Start-Sleep -Milliseconds 50
            }
        }
        Write-Host ""

        # BLIND EVALUATE the freshly built box. Intent = the offset values the
        # USER ENTERED ($mp.Offset), NOT a value re-read from the model.
        $expected = foreach ($mp in $made) {
            $dim = switch ($mp.Label) { "Side" {"Width"} "Top" {"Height"} "Front" {"Depth"} default {$mp.Label} }
            [pscustomobject]@{ Dim = $dim; Value = [double]$mp.Offset }
        }
        $script:buildConfirmed = Invoke-BoxEval -Operation "build-box" -Expected @($expected)
        Write-Host ""
    }
}

# --- RESIZE LOOP -- A = all three, 1..N = one plane, D/blank = done (-> STAGE 3) ---
# In orthogrid mode, the box was sized from the GUI's plate dimensions -- skip the
# resize loop entirely (no manual adjustments needed).
if ($null -ne $orthoGeo) {
    Write-Host "  Resize loop skipped (box sized by orthogrid plate dimensions)." -ForegroundColor DarkGray
} else {
Write-Host "  Resize loop (optional - adjust the box before drilling):" -ForegroundColor Cyan
Write-Host "    A = set ALL three (resize the box),  1-$($made.Count) = one plane,  D/blank = done -> drill" -ForegroundColor White
}
while ($null -eq $orthoGeo) {
    $cmd = Read-Host "  Command (A / 1-$($made.Count) / D)"
    if ([string]::IsNullOrWhiteSpace($cmd) -or $cmd.Trim().ToUpper() -eq "D") {
        Write-Host "  Done resizing - moving to drilling." -ForegroundColor Cyan
        break
    }

    if ($cmd.Trim().ToUpper() -eq "A") {
        $targets = @()
        foreach ($p in $made) {
            $dim = switch ($p.Label) { "Side" { "Width" } "Top" { "Height" } "Front" { "Depth" } default { "" } }
            $raw = Read-Host "    $($p.Label) ($dim) new offset"
            $v = 0.0
            if (-not [double]::TryParse($raw, [ref]$v)) { Write-Host "      not a number - skipping $($p.Label)." -ForegroundColor Yellow; continue }
            $targets += [pscustomobject]@{ Plane = $p; Want = $v }
        }
        foreach ($t in $targets) {
            $now = Set-PlaneOffset -Plane $t.Plane -Value $t.Want
            if ($null -ne $now -and [math]::Abs($now - $t.Want) -lt 1e-4) {
                Write-Host "    $($t.Plane.Label) $($t.Plane.Sym) = $now  (held)" -ForegroundColor Green
            } else {
                Write-Host "    $($t.Plane.Label) $($t.Plane.Sym) = $now  (wanted $($t.Want) - did NOT hold)" -ForegroundColor Yellow
            }
        }
        Write-Host ""
        Show-BoxState -Made $made
        Write-Host ""
        # NOTE: no blind-evaluator call on resize. A single offset value is not a
        # sorted box extent (and a negative offset never matches a positive
        # extent), so the build-box numeric check spammed a false "expected vs
        # measured" mismatch here. The per-plane "held / did NOT hold" line above
        # (a DimValue re-read) is the right confirmation for a resize.
        continue
    }

    $sel = 0
    if (-not [int]::TryParse($cmd, [ref]$sel) -or $sel -lt 1 -or $sel -gt $made.Count) {
        Write-Host "    enter A or 1-$($made.Count)." -ForegroundColor Yellow; continue
    }
    $p = $made[$sel - 1]

    $valRaw = Read-Host "    New offset for $($p.Label) ($($p.Sym))"
    $v = 0.0
    if (-not [double]::TryParse($valRaw, [ref]$v)) { Write-Host "    not a number." -ForegroundColor Yellow; continue }

    $now = Set-PlaneOffset -Plane $p -Value $v
    if ($null -ne $now -and [math]::Abs($now - $v) -lt 1e-4) {
        Write-Host "    $($p.Label) $($p.Sym) = $now  (held)" -ForegroundColor Green
    } else {
        Write-Host "    $($p.Label) $($p.Sym) = $now  (wanted $v - did NOT hold)" -ForegroundColor Yellow
    }
    # No blind-evaluator call on a single-plane resize (see the resize-all note).
}
Write-Host ""

# ============================================================================
# STAGE 2.5 -- DATUM-POINT CREATION (plane intersections, all by ID)
# ============================================================================
# Programmatic creation of EVERY target point via the PROVEN 3-plane-intersection
# recipe (point-probe.cmd, confirmed live 2026-06-24): for each point, the point =
# intersection of (SIDE face) + (an X-offset plane from TOP) + (a Z-offset plane
# from FRONT). Planes are SHARED via Get-SharedPlanePlan -- ONE plane per DISTINCT
# X offset + one per distinct Z offset -- so this serves BOTH the orthogrid
# (1 face + Nx + Nz planes -> Nx*Nz points) AND the custom layout (1 face +
# distinctX + distinctZ planes -> Count points). ALL widgets confirmed live; NO
# screen picks; each RunMacro is atomic + independent. Each coordinate is a
# drivable feature-level offset dim -> fully parametric.
#
# A coordinate of ~0 reuses the BASE datum directly (point-probe's trick) instead
# of a degenerate offset plane -- so a custom point typed at X=0 / Z=0 lands on the
# TOP / FRONT base datum. For the orthogrid (Edge>0) no coordinate is ~0, so this
# produces the IDENTICAL planes + intersections the live-confirmed path always did.
#
# If the plane/point creation fails, falls back to Invoke-ManualPointGrid (user
# creates + selects all points by hand). Never drills a zero-point "Done".
$gridPointIDs = @()
# $gridPlaneIds records the offset planes STAGE 2.5 creates (the X/Z loops below do
# `$gridPlaneIds += ...`). It no longer feeds a later stage (the chip-relief PATHS
# stage that consumed it was removed when slots replaced relief) but is kept as a
# harmless record. MUST be initialised to @() here at top level: an un-initialised
# `$null += obj` makes it a SCALAR PSObject (not a 1-element array), and the SECOND
# += then throws "does not contain a method named 'op_Addition'".
$gridPlaneIds = @()
# $csysRecords is the INDEX-HOLE csys registry (STAGE 5): one record per created
# grid point, @{ PointId; HoleFeatId; PlaneIds=@(Xplane,face,Zplane)=X/Y/Z-normal }. STAGE 2.5
# fills PointId + PlaneIds (the SAME ordered triple that built the point =
# X/Y/Z-normal); STAGE 3 fills HoleFeatId as each hole is drilled. STAGE 5 looks up
# the hole the user picks and re-uses its plane triple to make the csys. MUST be @()
# at top level (same scalar-PSObject += trap as $gridPlaneIds above); empty in
# PREDEFINED mode (no tracked planes) -> STAGE 5 degrades to a manual 3-plane pick.
$csysRecords = @()
if ($null -ne $orthoGeo) {
    $modeLabel = if ($orthoGeo.Mode -eq 'custom') { "custom layout" } else { "orthogrid" }
    Write-Host "  ====================================================================" -ForegroundColor Cyan
    Write-Host "   STAGE 2.5 - create all $($orthoGeo.Count) datum points ($modeLabel, plane intersections)" -ForegroundColor Cyan
    Write-Host "  ====================================================================" -ForegroundColor Cyan
    Write-Host ""
    if ($orthoGeo.Mode -eq 'custom') {
        Write-Host ("  {0} custom point(s), plate {1:0.00} x {2:0.00}." -f $orthoGeo.Count, $orthoGeo.Width, $orthoGeo.Height) -ForegroundColor Green
    } else {
        Write-Host ("  Grid: {0} points, plate {1:0.00} x {2:0.00} (Nx={3}, Nz={4}, cc {5}x{6})." -f `
            $orthoGeo.Count, $orthoGeo.Width, $orthoGeo.Height, $orthoGeo.Nx, $orthoGeo.Nz, $orthoGeo.CcX, $orthoGeo.CcZ) -ForegroundColor Green
    }

    # Base datum ids for the offset planes (already captured in STAGE 2).
    $topBaseId   = ($planes | Where-Object { $_.Label -eq "Top"   } | Select-Object -First 1).BaseId
    $frontBaseId = ($planes | Where-Object { $_.Label -eq "Front" } | Select-Object -First 1).BaseId
    # The SIDE offset plane = the face all points sit on (from STAGE 2 box build).
    # Use the SIDE BASE datum (og/default) for point intersection. Points sit on the
    # body's starting face so "On Point" holes work. ClearDia only widens the plate,
    # does NOT shift the point positions (the inset fix), so dimensions are correct.
    $facePlaneId = if ($null -ne $sidePlane -and $null -ne $sidePlane.BaseId) { [int]$sidePlane.BaseId } else { $null }

    $canAutoGrid = ($null -ne $topBaseId -and $null -ne $frontBaseId -and $null -ne $facePlaneId)
    if (-not $canAutoGrid) {
        Write-Host "  Missing base datum or SIDE offset plane - cannot auto-create the points." -ForegroundColor Yellow
        Write-Host "  Falling back to the manual path (you create + select all points by hand)." -ForegroundColor Yellow
    } else {
        # Shared-plane plan: distinct X/Z offsets + each point's index into them.
        # Works identically for orthogrid + custom (the orthogrid's distinct X
        # offsets are {Edge, Edge+CcX, ...}, so a column-I point indexes XCoords[I]).
        $plan = Get-SharedPlanePlan -Points $orthoGeo.Points
        $tol  = 1e-6
        Write-Host ("  Creating {0} X-plane(s) + {1} Z-plane(s) + {2} intersection point(s)..." -f `
            $plan.XCoords.Count, $plan.ZCoords.Count, $orthoGeo.Count) -ForegroundColor Cyan
        Write-Host "  (All by ID, no picks, no pattern - fully automatic.)" -ForegroundColor DarkGray
        $ok = $true

        # 1. One X-offset plane per DISTINCT X coord (offset from TOP base). A ~0
        #    coord reuses the TOP base datum directly. $xPlaneIds is parallel to
        #    $plan.XCoords so a point's .Xi indexes straight into it.
        $xPlaneIds = @()
        foreach ($xOff in $plan.XCoords) {
            if ([math]::Abs([double]$xOff) -le $tol) {
                $xPlaneIds += [int]$topBaseId
                Write-Host "    X=0 -> using TOP base datum $topBaseId directly" -ForegroundColor DarkGray
                continue
            }
            $res = New-OffsetPlane -Label "X$($xPlaneIds.Count)" -Offset ([double]$xOff) -BaseId ([int]$topBaseId) -SkipSymbolWait
            if ($null -eq $res.FeatId) { Write-Host "  X-plane at offset $xOff FAILED." -ForegroundColor Red; $ok = $false; break }
            $xPlaneIds += [int]$res.FeatId
        }
        if ($ok) { Write-Host ("  {0} X-plane reference(s) ready." -f $xPlaneIds.Count) -ForegroundColor DarkGray }

        # 2. One Z-offset plane per DISTINCT Z coord (offset from FRONT base). ~0 -> base.
        $zPlaneIds = @()
        if ($ok) {
            foreach ($zOff in $plan.ZCoords) {
                if ([math]::Abs([double]$zOff) -le $tol) {
                    $zPlaneIds += [int]$frontBaseId
                    Write-Host "    Z=0 -> using FRONT base datum $frontBaseId directly" -ForegroundColor DarkGray
                    continue
                }
                $res = New-OffsetPlane -Label "Z$($zPlaneIds.Count)" -Offset ([double]$zOff) -BaseId ([int]$frontBaseId) -SkipSymbolWait
                if ($null -eq $res.FeatId) { Write-Host "  Z-plane at offset $zOff FAILED." -ForegroundColor Red; $ok = $false; break }
                $zPlaneIds += [int]$res.FeatId
            }
            if ($ok) { Write-Host ("  {0} Z-plane reference(s) ready." -f $zPlaneIds.Count) -ForegroundColor DarkGray }
        }

        # Record the grid offset planes (tagged with axis + offset). This was
        # consumed by the old chip-relief PATHS stage (removed); kept as a harmless
        # record. Skip the X=0/Z=0 base-datum reuse (default datums, not offsets).
        if ($ok) {
            for ($qi = 0; $qi -lt $xPlaneIds.Count; $qi++) {
                if ([int]$xPlaneIds[$qi] -ne [int]$topBaseId) {
                    $gridPlaneIds += [pscustomobject]@{ FeatId = [int]$xPlaneIds[$qi]; Axis = 'X'; Offset = [double]$plan.XCoords[$qi] }
                }
            }
            for ($qi = 0; $qi -lt $zPlaneIds.Count; $qi++) {
                if ([int]$zPlaneIds[$qi] -ne [int]$frontBaseId) {
                    $gridPlaneIds += [pscustomobject]@{ FeatId = [int]$zPlaneIds[$qi]; Axis = 'Z'; Offset = [double]$plan.ZCoords[$qi] }
                }
            }
        }

        # 3. One intersection point per input point: face n X-plane[Xi] n Z-plane[Zi].
        # This loop is the ORIGINAL point-creation code -- it fires ONLY the creation
        # macros, with NO COM reads between them (reading ListItems mid-loop disrupts
        # the very commits it would poll for). The index-csys registry is built AFTER
        # the loop as pure post-processing (below), so it cannot affect point creation.
        if ($ok) {
            $beforePts = Get-PointIdSet -Model $model -TypeObj $pfcType
            $ptIdx = 0
            foreach ($tri in $plan.Triples) {
                $ptIdx++
                Show-Progress ([Math]::Floor(($ptIdx / $orthoGeo.Count) * 100)) "Point $ptIdx/$($orthoGeo.Count)"
                $macro = Build-IntersectPointMacro -PlaneIds @([int]$facePlaneId, [int]$xPlaneIds[$tri.Xi], [int]$zPlaneIds[$tri.Zi])
                try { $session.RunMacro($macro) } catch {
                    Write-Host "  Point $ptIdx macro errored: $($_.Exception.Message)" -ForegroundColor Red
                    $ok = $false; break
                }
            }
            Show-Progress 100 "Done"
            $newIds = Resolve-NewPointIds -Model $model -TypeObj $pfcType -Before $beforePts
            # INDEX-CSYS REGISTRY (post-processing; does NOT touch point creation):
            # Creo assigns datum-point ids in ascending CREATION order and $plan.Triples
            # is in creation order, so index k of the sorted new ids IS the k-th triple.
            # Zip them into PointId -> PlaneIds records. PLANE ORDER = X-normal, then
            # Y-normal, then Z-normal (the order ProCmdDatumCsys assigns axes from):
            #   X-normal = the X-offset plane (offset from TOP; per the grid contract,
            #              "X = TOP-direction offset", so TOP's normal IS the X axis),
            #   Y-normal = the SIDE face (the box length/thickness axis),
            #   Z-normal = the Z-offset plane (offset from FRONT; FRONT's normal = Z).
            # So the order is [xPlane, face, zPlane] -- NOT [face, xPlane, zPlane]
            # (that put SIDE=Y first and flipped the csys direction). Only when the
            # counts match exactly, else leave the registry empty (STAGE 5 then falls
            # back to a manual pick rather than mis-map a csys to the wrong hole).
            if (@($newIds).Count -eq @($plan.Triples).Count) {
                $csysRecords = @()
                for ($k = 0; $k -lt $newIds.Count; $k++) {
                    $tri = $plan.Triples[$k]
                    # GridX/GridZ = the hole's design coordinate (offset from the base
                    # datums), carried so STAGE 6 can export coords relative to the index csys.
                    $csysRecords += [pscustomobject]@{ PointId = [int]$newIds[$k]; HoleFeatId = $null; PlaneIds = @([int]$xPlaneIds[$tri.Xi], [int]$facePlaneId, [int]$zPlaneIds[$tri.Zi]); GridX = [double]$tri.X; GridZ = [double]$tri.Z }
                }
                Write-Host ("  (index-csys registry: {0} point(s) mapped to their planes, X/Y/Z-normal)" -f @($csysRecords).Count) -ForegroundColor DarkGray
            }
            if ($newIds.Count -eq $orthoGeo.Count) {
                $gridPointIDs = @($newIds)
                Write-Host ("  All {0} datum points created. IDs: {1}" -f $newIds.Count, (($newIds | Select-Object -First 10) -join ", ")) -ForegroundColor Green
            } else {
                Write-Host ("  Point-count MISMATCH: expected {0}, got {1}. Some intersections may have failed." -f $orthoGeo.Count, $newIds.Count) -ForegroundColor Yellow
                if ($newIds.Count -gt 0) { $gridPointIDs = @($newIds) }  # use what we have
                $ok = $false
            }
        }

        if (-not $ok) {
            Write-Host "  Auto point creation had issues. Falling back to manual point selection." -ForegroundColor Yellow
            if ($gridPointIDs.Count -eq 0) {
                $gridPointIDs = @(Invoke-ManualPointGrid -Geo $orthoGeo -Session $session -TypeObj $pfcType)
            }
        }
    }

    if ($gridPointIDs.Count -gt 0) {
        Write-Host ("  Points ready: {0} point(s) for STAGE 3 drilling." -f $gridPointIDs.Count) -ForegroundColor Green
    } else {
        if (-not $canAutoGrid) {
            $gridPointIDs = @(Invoke-ManualPointGrid -Geo $orthoGeo -Session $session -TypeObj $pfcType)
        }
        if ($gridPointIDs.Count -eq 0) {
            Write-Host "  No points captured - STAGE 3 will fall back to a manual selection." -ForegroundColor Yellow
        }
    }
    Write-Host ""

    # Regenerate the model after creating the planes + points so Creo recognizes
    # them as valid hole-placement references. Without this, ProCmdHole may not
    # "see" the just-created datum points (they exist in the feature tree but the
    # model geometry isn't committed). This matches holeinator's assumption that
    # points PRE-EXIST before drilling starts.
    if ($gridPointIDs.Count -gt 0) {
        Write-Host "  Regenerating model (commit all new planes + points before drilling)..." -ForegroundColor DarkGray
        try { $model.Regenerate($null) } catch {}
    }
}

# ============================================================================
# STAGE 3 -- DRILL HOLES (holeinator) at the diameter from STAGE 1
# ============================================================================
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "   STAGE 3 - drill an On-Point hole at every target datum point" -ForegroundColor Cyan
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host ""

# --- STEP 1: target datum points ---
# Prefer the orthogrid grid created in STAGE 2.5 (all NxÂ·Nz points, no pattern);
# otherwise fall back to selecting pre-existing datum points.
$pointIDs = @()
if ($gridPointIDs.Count -gt 0) {
    $pointIDs = @($gridPointIDs)
    Write-Host ("  STEP 1 -- using the {0} orthogrid point id(s) from STAGE 2.5: {1}" -f $pointIDs.Count, (($pointIDs | Select-Object -First 10) -join ", ")) -ForegroundColor Green
} else {
    Write-Host "  STEP 1 -- In Creo, select the target datum points (they already exist" -ForegroundColor Cyan
    Write-Host "           in the part, on another plane), then press ENTER here." -ForegroundColor Cyan
    Read-Host
    $points = ($session.CurrentSelectionBuffer()).Contents
    if ($null -eq $points) { throw "Selection buffer is empty -- no datum points selected in Creo." }

    # Resolve selections into POINT IDs only (never reads .Point coordinates).
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
            foreach ($pt in @($si.ListSubItems($pfcType.ITEM_POINT))) {
                try { $subIds += [int]$pt.Id } catch {}
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
}

# --- STEP 2: user picks the target body ---
Write-Host ""
Write-Host "  STEP 2 -- Target body." -ForegroundColor Cyan
$bodyList = @()
try { $bodyList = @($model.ListItems($pfcType.ITEM_BODY)) } catch {}

$bodyIndex = 0
# When points were created programmatically (orthogrid or custom) auto-pick body 0
# with no prompt. In manual mode, ask only if >1 body.
if ($gridPointIDs.Count -gt 0) {
    Write-Host "  Body index: 0 (auto, programmatic points)." -ForegroundColor DarkGray
} elseif ($bodyList.Count -gt 1) {
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
} else {
    Write-Host "  (could not enumerate bodies; defaulting to body index 0)" -ForegroundColor Yellow
}
Write-Host ("  Target body index: {0}" -f $bodyIndex) -ForegroundColor Green

# --- STEP 3: hole diameter, taken from STAGE 1 (in-process, no prompt) ---
# The decision tree's resolved OD IS the hole diameter; use it directly and do
# NOT ask. Only fall back to a manual prompt if the tree produced no diameter
# (e.g. the walk ended without resolving a bushing).
Write-Host ""
Write-Host "  STEP 3 -- Hole diameter." -ForegroundColor Cyan
$holeDiaFinal = 0.0
if ($null -ne $holeDia -and [double]$holeDia -gt 0) {
    $holeDiaFinal = [double]$holeDia
    Write-Host ("  Using the decision-tree diameter: {0}`" (not asked)" -f $holeDiaFinal) -ForegroundColor Green
} else {
    Write-Host "  The decision tree did not resolve a diameter - enter it by hand." -ForegroundColor Yellow
    while ($holeDiaFinal -le 0) {
        $raw = Read-Host "  Enter hole diameter (required)"
        $d = 0.0
        if ([double]::TryParse($raw.Trim(), [ref]$d) -and $d -gt 0) { $holeDiaFinal = $d }
        else { Write-Host "  Enter a positive number." -ForegroundColor Yellow }
    }
    Write-Host ("  Hole diameter: {0}" -f $holeDiaFinal) -ForegroundColor Green
}

# ============================================================================
# STAGE 2b -- AUTO-ROUND THE BOX CORNER EDGES (hands-free, just before drilling)
# ============================================================================
# Right BEFORE the drill confirmation below, round the box corner edges: the
# edges of the LOWEST dimension present (the through-thickness verticals of the
# plate). FULLY AUTOMATIC - no target prompt, no proceed prompt (user, 2026-06-24).
# Mechanism = lib\edge_round.ps1 (Invoke-AutoCornerRound): sweep GetItemById ->
# filter by EvalLength to the smallest length -> CreateModelItemSelection +
# AddSelection -> proven round mapkey. NO find tool (dead on foreign bodies).
# It self-tests selection on one edge and aborts WITHOUT mutating if that fails;
# a VersionStamp canary aborts if the first round changes nothing.
# Override radius with --corner-radius N (default 0.25); --no-corner-round skips.
$cornerRadius = 0.25
$mCr = [regex]::Match($ScriptArgs, '(?i)--corner-radius\s+([0-9]*\.?[0-9]+)')
if ($mCr.Success) { $cornerRadius = [double]$mCr.Groups[1].Value }
if ($ScriptArgs -match '(?i)--no-corner-round') {
    Write-Host "  (--no-corner-round) skipping automatic corner rounding." -ForegroundColor DarkGray
} else {
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "   STAGE 2b - auto-rounding box corner edges (lowest dimension)" -ForegroundColor Cyan
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "  Hands-free: finding the smallest-length edges and rounding them" -ForegroundColor White
    Write-Host "  at radius $cornerRadius." -ForegroundColor White
    $cr = Invoke-AutoCornerRound -Session $session -Model $model -TypeObj $pfcType -Radius $cornerRadius
    Write-Host ("  Found $($cr.Found) edge(s); target length $($cr.Target); matched $($cr.Matched).") -ForegroundColor White
    if ($cr.Matched -gt 0 -and -not $cr.SelfTestOk) {
        Write-Host "  Corner round SKIPPED (safe) - $($cr.Reason)" -ForegroundColor Yellow
    } elseif ($cr.Aborted) {
        Write-Host "  Corner round ABORTED after canary - $($cr.Reason). Inspect Creo." -ForegroundColor Red
    } elseif ($cr.Matched -eq 0) {
        Write-Host "  No corner edges matched - $($cr.Reason). Skipped." -ForegroundColor Yellow
    } elseif ($cr.TotalBatches -gt 0 -and $cr.ModelChanged -eq $cr.TotalBatches) {
        Write-Host "  Rounded $($cr.Matched) corner edge(s) in $($cr.BatchesFired) batch(es) (model changed each)." -ForegroundColor Green
        Write-Host "  NOTE: batches FIRED, not rounds Creo geometrically accepted - verify visually." -ForegroundColor DarkGray
    } else {
        Write-Host "  Corner round finished with issues - $($cr.ModelChanged)/$($cr.TotalBatches) batch(es) changed the model. Inspect Creo." -ForegroundColor Yellow
    }
    Write-Host ""
}

# --- CONFIRM (last stop before mutating the model) ---
Write-Host ""
Write-Host ("  Ready: {0} hole(s), diameter {1}, through all, body index {2}." -f $pointIDs.Count, $holeDiaFinal, $bodyIndex) -ForegroundColor Cyan
Write-Host "  Do not touch Creo while this runs." -ForegroundColor DarkGray
# Programmatic points (orthogrid/custom): auto-proceed (the user committed at the
# GUI; everything after is automatic).
if ($gridPointIDs.Count -gt 0) {
    $go = 'y'
    Write-Host "  Proceeding automatically (points created from the GUI layout)." -ForegroundColor Cyan
} else {
    $go = Read-Host "  Proceed? (y/N)"
}
if ($go -notmatch '^[Yy]$') {
    Write-Host "  Cancelled -- the box was built but no holes were drilled." -ForegroundColor Yellow
} else {
    Write-Host ""

    # --- FIRE -- canary first, then the rest ---
    $total = $pointIDs.Count
    $idx = 0
    $madeHoles = 0
    $noop = 0
    $failed = 0
    $aborted = $false

    # index-csys: ONE feature snapshot BEFORE the drill loop (outside it, so hole
    # creation is untouched). After the loop we diff ONCE and, if the new-feature
    # count matches the hole count exactly, zip sorted-ascending (= creation order)
    # onto $pointIDs to record each point's HoleFeatId. If it doesn't match cleanly
    # (a hole added an axis/note), we skip the tie -- clicking the datum POINT still
    # resolves via the point registry. Only when a registry exists to enrich.
    $beforeDrillFeat = if (@($csysRecords).Count -gt 0) { Get-FeatureIdSet } else { $null }

    foreach ($ptId in $pointIDs) {
        $idx++
        Show-Progress ([Math]::Floor(($idx / $total) * 100)) "Hole $idx/$total"

        # Orthogrid mode: pass the SIDE base datum as the placement surface (the
        # intersection points aren't on a solid face, so Creo needs it explicitly).
        # Pre-select the SIDE OFFSET plane (the box face the points sit on) as the
        # hole placement surface. Point + matching surface -> "On Point" mode.
        $surfId = 0
        if ($gridPointIDs.Count -gt 0 -and $null -ne $sidePlane -and $null -ne $sidePlane.FeatId) {
            $surfId = [int]$sidePlane.FeatId
        }
        $macro = Build-HoleMacro -PointId $ptId -Diameter $holeDiaFinal -BodyIndex $bodyIndex -SurfacePlaneId $surfId
        $changed = $false
        try {
            $stamp = $model.VersionStamp
            $session.RunMacro($macro)
            $changed = Wait-ModelModified -Model $model -PreviousStamp $stamp
        } catch {
            $failed++
        }
        if ($changed) { $madeHoles++ } else { $noop++ }

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

    # index-csys: tie holes to points OUTSIDE the loop (one diff), creation-order
    # groups. Resolve-HoleFeatGroups splits the new features into one group per hole
    # (a hole may add an axis/note as well as the hole feature), so clicking ANY of a
    # hole's features in STAGE 5 resolves (Resolve-IndexHolePlanes matches HoleFeatIds).
    if ($null -ne $beforeDrillFeat -and -not $aborted -and $madeHoles -gt 0) {
        $afterDrillFeat = Get-FeatureIdSet
        $newDrillFeats  = @($afterDrillFeat.Keys | Where-Object { -not $beforeDrillFeat.ContainsKey($_) } | Sort-Object)
        $grp = Resolve-HoleFeatGroups -NewFeatIds $newDrillFeats -HoleCount @($pointIDs).Count
        if ($grp.Ok) {
            for ($k = 0; $k -lt $pointIDs.Count; $k++) {
                $rec = $csysRecords | Where-Object { $null -ne $_.PointId -and [int]$_.PointId -eq [int]$pointIDs[$k] } | Select-Object -First 1
                if ($null -ne $rec) {
                    $rec.HoleFeatId = [int]$grp.Groups[$k][0]
                    try { $rec | Add-Member -NotePropertyName HoleFeatIds -NotePropertyValue @($grp.Groups[$k]) -Force } catch {}
                }
            }
            $extra = if ($grp.PerHole -gt 1) { (" ({0} features each)" -f $grp.PerHole) } else { "" }
            Write-Host ("  (index-csys: {0} hole(s) tied to their points{1})" -f @($pointIDs).Count, $extra) -ForegroundColor DarkGray
        } else {
            Write-Host ("  (index-csys: hole->point tie skipped -- {0}; click the datum POINT for the index csys)" -f $grp.Reason) -ForegroundColor DarkGray
        }
    }

    Write-Host ""

    # --- REPORT ---
    Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
    Write-Host ("  Points targeted   : {0}" -f $total) -ForegroundColor White
    Write-Host ("  Holes attempted   : {0}" -f $idx) -ForegroundColor White
    Write-Host ("  Model changed     : {0}" -f $madeHoles) -ForegroundColor White
    if ($noop   -gt 0) { Write-Host ("  No-op (no change) : {0}" -f $noop) -ForegroundColor Yellow }
    if ($failed -gt 0) { Write-Host ("  Macro errors      : {0}" -f $failed) -ForegroundColor Yellow }
    Write-Host ""
    if ($aborted) {
        Write-Host "  STOPPED after the canary -- inspect the model in Creo." -ForegroundColor Red
    } elseif ($madeHoles -eq $total -and $failed -eq 0) {
        Write-Host "  Done -- $madeHoles hole(s) created (model changed for each)." -ForegroundColor Green
        Write-Host "  Verify the holes visually in Creo." -ForegroundColor DarkGray
    } else {
        Write-Host "  Finished with issues -- $madeHoles of $total changed the model. Inspect Creo." -ForegroundColor Yellow
    }
}

# ============================================================================
# STAGE 4 -- CHIP-RELIEF SLOTS (rectangular remove-material, one per hole row)
# ============================================================================
# Replaces the old coaxial relief holes + relief paths with the slotinator method:
# ONE blind rectangular slot per hole ROW (length = the part length along the row,
# width = the drilled hole diameter, depth = % of plate thickness), seed-drawn once
# then patterned along a base datum plane's normal. Reuses the shared engine in
# lib\drilljig_core.ps1 (Get-RowSlots / Get-SlotPatternPlan / Invoke-VerifiedSeedCut /
# Build-SlotPatternMacro / Build-CutFinishMacro) and ALL the context already gathered
# this run -- the hole diameter ($holeDiaFinal), plate thickness (the live SIDE
# offset), and hole layout ($orthoGeo) are NOT re-asked. Requires a GUI layout
# (orthogrid/custom); PREDEFINED points carry no row info (we never read point
# coordinates -- the IpfcPoint.Point crash), so slots are skipped there.
$SLOT_DEPTH_PCT = 0.20
$mSdp = [regex]::Match($ScriptArgs, '(?i)--slot-depth-pct\s+([0-9]*\.?[0-9]+)')
if ($mSdp.Success) { $pSdp = [double]$mSdp.Groups[1].Value; if ($pSdp -gt 0 -and $pSdp -lt 100) { $SLOT_DEPTH_PCT = $pSdp / 100.0 } }
$slotFlip        = ($ScriptArgs -match '(?i)--slot-flip')
$slotPatternFlip = ($ScriptArgs -match '(?i)--pattern-flip')
$slotNoPattern   = ($ScriptArgs -match '(?i)--no-pattern')

Write-Host ""
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "   STAGE 4 - chip-relief SLOTS (one rectangular slot per hole row)" -ForegroundColor Cyan
Write-Host "  ====================================================================" -ForegroundColor Cyan

# GATE (material, user 2026-07-07): 3D print -> add slots automatically; metal (and
# any non-3D-print / unresolved path) -> ask the human y/N. $is3dPrint was derived
# from the STAGE-1 decision path.
$doSlots = $false
if ($ScriptArgs -match '(?i)--no-slot-relief') {
    Write-Host "  (--no-slot-relief) skipping chip-relief slots." -ForegroundColor DarkGray
} elseif ($is3dPrint) {
    Write-Host "  Material is 3D print -- adding chip-relief slots automatically." -ForegroundColor Cyan
    $doSlots = $true
} else {
    $ansSlot = Read-Host "  Add chip-relief slots? (y/N)"
    $doSlots = ($ansSlot -match '^[Yy]$')
    if (-not $doSlots) { Write-Host "  Skipped chip-relief slots." -ForegroundColor DarkGray }
}

if ($doSlots -and $null -eq $orthoGeo) {
    Write-Host "  No grid/custom layout was entered (predefined points) -- holes cannot be grouped" -ForegroundColor Yellow
    Write-Host "  into rows without a layout, so chip-relief slots are skipped. Use orthogrid/custom" -ForegroundColor Yellow
    Write-Host "  mode to get slots." -ForegroundColor Yellow
    $doSlots = $false
}

if ($doSlots) {
    # --- rows from the SAME layout the holes came from (NO re-entry) ---
    $slots = Get-RowSlots -Points $orthoGeo.Points -SlotWidth $holeDiaFinal -Width $orthoGeo.Width -Height $orthoGeo.Height -RowAxis 'X'
    if (-not $slots.Valid -or @($slots.Rows).Count -lt 1) {
        Write-Host "  The layout produced no valid slot rows -- skipping chip-relief slots." -ForegroundColor Yellow
        foreach ($er in @($slots.Errors)) { Write-Host "    - $er" -ForegroundColor Yellow }
    } else {
        # --- plate thickness from the LIVE SIDE offset (same source the old relief used;
        # never the cached .Offset/$bushingLen, which go stale after a resize) ---
        $slotDepth = 0.0
        $sSide = @($made | Where-Object { $_.Label -eq "Side" }); $sSide = if ($sSide.Count -gt 0) { $sSide[0] } else { $null }
        $thkS  = $null
        if ($null -ne $sSide -and $null -ne $sSide.Sym) { $liveS = Read-DimValue -Model $model -TypeObj $pfcType -Sym $sSide.Sym; if ($null -ne $liveS -and $liveS -gt 0) { $thkS = [double]$liveS } }
        if ($null -ne $thkS -and $thkS -gt 0) {
            $slotDepth = [Math]::Round($thkS * $SLOT_DEPTH_PCT, 4)
            Write-Host ("  Plate thickness from the live SIDE offset ({0} = {1}"" ): slot depth {2}"" ({3:P0})" -f $sSide.Sym, [Math]::Round($thkS,4), $slotDepth, $SLOT_DEPTH_PCT) -ForegroundColor Green
        } else {
            Write-Host "  No live SIDE offset this run -- slots will use Creo's DEFAULT depth (no value typed)." -ForegroundColor Yellow
        }
        # --- sketch face = the SIDE og datum (where the box was sketched); pattern
        # direction datum from the march axis: CrossAxis Z -> FRONT, X -> TOP ---
        $slotFaceId = if ($null -ne $sidePlane -and $null -ne $sidePlane.BaseId) { [int]$sidePlane.BaseId } else { $null }
        $frontBase = @($made | Where-Object { $_.Label -eq "Front" }); $frontBase = if ($frontBase.Count -gt 0) { $frontBase[0] } else { $null }
        $topBase   = @($made | Where-Object { $_.Label -eq "Top" });   $topBase   = if ($topBase.Count -gt 0) { $topBase[0] } else { $null }
        $dirDatumId = $null; $dirName = $null
        if ($slots.CrossAxis -eq 'Z') { if ($null -ne $frontBase -and $null -ne $frontBase.BaseId) { $dirDatumId = [int]$frontBase.BaseId; $dirName = 'FRONT' } }
        else                          { if ($null -ne $topBase   -and $null -ne $topBase.BaseId)   { $dirDatumId = [int]$topBase.BaseId;   $dirName = 'TOP' } }

        if ($null -eq $slotFaceId) {
            Write-Host "  The SIDE datum was not captured this run -- cannot sketch the slots. Skipping." -ForegroundColor Yellow
        } else {
            $depthNote = if ($slotDepth -gt 0) { "$slotDepth""" } else { "Creo default depth" }
            Write-Host ("  {0} slot row(s), width {1}"" (= hole dia), {2}, sketched on the SIDE face (id {3})." -f @($slots.Rows).Count, $slots.SlotWidth, $depthNote, $slotFaceId) -ForegroundColor Cyan

            $patPlan = Get-SlotPatternPlan -Rows $slots.Rows
            $usePattern = ($patPlan.CanPattern -and -not $slotNoPattern -and @($slots.Rows).Count -ge 2 -and $null -ne $dirDatumId)

            # --- GUIDE PLANES: create + show the slot-edge offset planes (the 2+ datum
            # planes slotinator makes) so the operator draws the seed rectangle to the
            # right size. Pattern mode -> FIRST row's edges only (the seed). Needs the
            # TOP + FRONT bases. Best-effort; freehand if the bases weren't captured. ---
            $slotHasPlanes = $false
            $topBaseIdN   = if ($null -ne $topBase   -and $null -ne $topBase.BaseId)   { [int]$topBase.BaseId }   else { 0 }
            $frontBaseIdN = if ($null -ne $frontBase -and $null -ne $frontBase.BaseId) { [int]$frontBase.BaseId } else { 0 }
            if ($topBaseIdN -gt 0 -and $frontBaseIdN -gt 0) {
                Write-Host "  Creating the slot-edge guide planes (draw references)..." -ForegroundColor Cyan
                $gp = New-SlotGuidePlanes -Rows $slots.Rows -TopBaseId $topBaseIdN -FrontBaseId $frontBaseIdN -UsePattern:$usePattern -Log { param($m) Write-Host $m -ForegroundColor Yellow }
                if (@($gp.Ids).Count -gt 0) { $slotHasPlanes = $true; Write-Host ("  {0} slot-edge guide plane(s) created + shown." -f @($gp.Ids).Count) -ForegroundColor Green }
                else { Write-Host "  No new guide planes needed (edges lie on base datums) - draw freehand." -ForegroundColor DarkGray }
            } else {
                Write-Host "  TOP/FRONT base datums not both captured - skipping guide planes (draw freehand)." -ForegroundColor Yellow
            }

            # --- SEED slot (row 1): draw + verify direction/depth; learn the flip ---
            $seedRow = $slots.Rows[0]
            $seed = Invoke-VerifiedSeedCut -FaceId $slotFaceId -Depth $slotDepth -BodyIndex $bodyIndex `
                -Flip $slotFlip -RowLabel "row 1 (seed)" -DrawInfo @{
                    SlotLen = $seedRow.SlotLen; RowAxis = $slots.RowAxis; SlotWidth = $slots.SlotWidth
                    CrossAxis = $slots.CrossAxis; CrossCoord = $seedRow.CrossCoord; HasPlanes = $slotHasPlanes }

            if (-not $seed.Ok) {
                Write-Host "  The seed slot was not confirmed -- no further slots made. Inspect Creo." -ForegroundColor Yellow
            } elseif ($usePattern) {
                # --- PATTERN the seed to the remaining rows (hands-free, datum-by-ID) ---
                Write-Host ""
                Write-Host "  SELECT THE SEED SLOT CUT in Creo's model tree (the remove-material extrude you" -ForegroundColor Magenta
                Write-Host "  just verified), then press ENTER." -ForegroundColor Magenta
                Read-Host
                $selSeed = Read-SelectedId
                if ($null -eq $selSeed) {
                    Write-Host "  Nothing selected -- the seed slot IS cut; pattern by hand, or re-run with --no-pattern." -ForegroundColor Yellow
                } else {
                    Write-Host ("  Patterning {0} copies at pitch {1:0.####} along {2}, direction = the {3} datum (by ID)..." -f $patPlan.Count, $patPlan.Increment, $slots.CrossAxis, $dirName) -ForegroundColor Cyan
                    $stampP = $null; try { $stampP = $model.VersionStamp } catch {}
                    $patChanged = $false
                    try {
                        $session.RunMacro((Build-SlotPatternMacro -DirDatumId $dirDatumId -Count ([int]$patPlan.Count) -Spacing ([double]$patPlan.Increment) -Flip:$slotPatternFlip))
                        if ($null -ne $stampP) { $patChanged = Wait-ModelModified -Model $model -PreviousStamp $stampP -TimeoutMs 30000 }
                    } catch { Write-Host "    pattern macro error: $($_.Exception.Message)" -ForegroundColor Red }
                    if ($patChanged) {
                        Write-Host ("  Done -- seed slot patterned to the remaining rows (model changed). {0} slots total, one per" -f $patPlan.Count) -ForegroundColor Green
                        Write-Host ("  row, spaced {0:0.####}. If the copies marched the WRONG way (off the plate), re-run with --pattern-flip." -f $patPlan.Increment) -ForegroundColor DarkGray
                    } else {
                        Write-Host "  The pattern did NOT change the model. The seed slot IS cut; finish by hand or re-run with --no-pattern." -ForegroundColor Yellow
                    }
                }
            } else {
                # --- PER-ROW: seed is row 1; draw the rest with the confirmed flip ---
                $confirmedFlip = $seed.Flip
                $rowNum = 1; $slMade = 1; $slNoop = 0
                foreach ($row in @($slots.Rows | Select-Object -Skip 1)) {
                    $rowNum++
                    Write-Host ""
                    Write-Host ("  ROW $rowNum of $(@($slots.Rows).Count) ($($slots.CrossAxis)~{0:0.###})" -f $row.CrossCoord) -ForegroundColor Cyan
                    $mkOpenR = (Get-SelectByIdMacro -FeatId $slotFaceId) + "~ Command ``ProCmdFtExtrude``;" + "~ Command ``ProCmdViewSketchView``;" + "~ Command ``ProCmdSketRectangle`` 1;"
                    try { $session.RunMacro($mkOpenR) } catch { Write-Host "    open error: $($_.Exception.Message)" -ForegroundColor Red; continue }
                    Write-Host ("    Draw this row's slot rectangle ({0:0.###} long x {1:0.###} wide), then press ENTER." -f $row.SlotLen, $slots.SlotWidth) -ForegroundColor Magenta
                    Read-Host
                    $stampR = $null; try { $stampR = $model.VersionStamp } catch {}
                    $chgR = $false
                    try { $session.RunMacro((Build-CutFinishMacro -Depth $slotDepth -BodyIndex $bodyIndex -Flip $confirmedFlip)); if ($null -ne $stampR) { $chgR = Wait-ModelModified -Model $model -PreviousStamp $stampR -TimeoutMs 30000 } } catch { Write-Host "    cut error: $($_.Exception.Message)" -ForegroundColor Red }
                    if ($chgR) { $slMade++; Write-Host "    Slot cut (model changed)." -ForegroundColor Green } else { $slNoop++; Write-Host "    No change." -ForegroundColor Yellow }
                }
                Write-Host ""
                Write-Host ("  Done -- {0} of {1} slot(s) cut (per-row). Verify in Creo." -f $slMade, @($slots.Rows).Count) -ForegroundColor $(if ($slNoop -eq 0) { 'Green' } else { 'Yellow' })
            }
        }
    }
}

# ============================================================================
# STAGE 5 -- INDEX-HOLE COORDINATE SYSTEM (datum csys at a chosen hole)
# ============================================================================
# The user picks ONE drilled hole to be the INDEX hole (the origin of a datum
# coordinate system). Each grid point was built as the intersection of 3
# mutually-perpendicular planes (STAGE 2.5) recorded, per point, in $csysRecords
# in X/Y/Z-normal order = [X-plane from TOP, SIDE face, Z-plane from FRONT]; STAGE 3
# tied each hole's feature id to its point. So: read what the user selected, look
# up its plane triple, and re-select those SAME 3 planes -> ProCmdDatumCsys -> OK
# (Build-CsysFromPlanesMacro, the proven 3-plane intersection recipe with
# ProCmdDatumPointGeneral swapped for ProCmdDatumCsys). Created iff a NEW feature
# appears (canary) -- never "done" on a no-op. --no-index-csys skips it. In
# PREDEFINED mode (no registry) it degrades to a manual 3-plane pick.
Write-Host ""
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "   STAGE 5 - index-hole coordinate system (optional)" -ForegroundColor Cyan
Write-Host "  ====================================================================" -ForegroundColor Cyan

# outcomes for the FINAL WORD summary (parity with the GUI Done step)
$indexCsysFeatId    = $null
$indexCsvPath       = $null
$indexPointsCreated = 0

if ($ScriptArgs -match '(?i)--no-index-csys') {
    Write-Host "  (--no-index-csys) skipping the index-hole coordinate system." -ForegroundColor DarkGray
} else {
    $ansCsys = Read-Host "  Create a coordinate system at an index hole? (y/N)"
    if ($ansCsys -notmatch '^[Yy]$') {
        Write-Host "  Skipped the index-hole coordinate system." -ForegroundColor DarkGray
    } elseif ($csysRecords.Count -gt 0) {
        # REGISTRY path: user selects the index HOLE; we resolve its plane triple.
        Write-Host ""
        Write-Host "  In Creo, SELECT THE HOLE you want as the index hole (click the hole" -ForegroundColor Cyan
        Write-Host "  feature in the model tree, or the datum point it was drilled on)," -ForegroundColor Cyan
        Write-Host "  then press ENTER here." -ForegroundColor Cyan
        Read-Host
        $sel = Read-IndexSelectionIds
        $res = Resolve-IndexHolePlanes -Records $csysRecords -FeatureIds $sel.FeatureIds -PointIds $sel.PointIds
        if (-not $res.Ok) {
            Write-Host "  Could not tie the selection to a drilled hole: $($res.Reason)." -ForegroundColor Yellow
            # diagnostics so a miss is debuggable (what got read vs. what's on file)
            Write-Host ("  (read feature ids: {0}; point ids: {1})" -f (($sel.FeatureIds | Select-Object -First 12) -join ', '), (($sel.PointIds | Select-Object -First 12) -join ', ')) -ForegroundColor DarkGray
            $withHole = @($csysRecords | Where-Object { $null -ne $_.HoleFeatId })
            Write-Host ("  (index registry: {0} record(s), {1} with a hole id; sample hole ids: {2})" -f @($csysRecords).Count, @($withHole).Count, ((@($withHole | ForEach-Object { $_.HoleFeatId }) | Select-Object -First 12) -join ', ')) -ForegroundColor DarkGray
            Write-Host "  Nothing created. Select the HOLE feature (or its datum point) and re-run." -ForegroundColor Yellow
        } else {
            Write-Host ("  Index hole resolved ({0}); point id {1}, planes {2}." -f $res.Reason, $res.PointId, ($res.PlaneIds -join ", ")) -ForegroundColor Green
            Write-Host "  Creating the coordinate system automatically from the hole's 3 planes (X/Y/Z-normal, no clicks)..." -ForegroundColor Cyan
            $cs = Invoke-IndexCsys -PlaneIds @($res.PlaneIds) -Show
            if ($cs.Ok) {
                $indexCsysFeatId = $cs.NewFeatId
                Write-Host ("  Done -- coordinate system created (new feature id {0}). Verify axes visually in Creo." -f $cs.NewFeatId) -ForegroundColor Green

                # --- STAGE 6: export every hole's coordinate relative to this index csys ---
                # Pure math from the grid layout (no COM coordinate read): csys X = grid X,
                # csys Z = grid Z, csys Y = 0 (all holes on the SIDE face). The index hole
                # is the origin (0,0,0). CSV lands next to the drilljig eval packets.
                $base = ($modelFile -replace '\.(prt|asm)(\.\d+)?$','') -replace '[^\w\-]','_'
                if ([string]::IsNullOrWhiteSpace($base)) { $base = 'drilljig' }   # never an identity-less, underscore-leading filename
                $csvPath = Join-Path $ScriptDir ($base + "_holes_from_index_csys.csv")
                $exp = Export-IndexHoleCsv -Records $csysRecords -IndexPointId $res.PointId -Diameter $holeDiaFinal -Path $csvPath
                if ($exp.Ok) {
                    $indexCsvPath = $exp.Path
                    Write-Host ("  Exported {0} hole coordinate(s) relative to the index csys ->" -f $exp.Count) -ForegroundColor Green
                    Write-Host ("    $($exp.Path)") -ForegroundColor White
                    Write-Host "    Columns: X_index / Y_index / Z_index (in the index frame; Y=0, all holes on the face)," -ForegroundColor DarkGray
                    Write-Host "    plus GridX/GridZ (design offsets), Diameter, IsIndexHole. Verify axis SIGNS vs the csys." -ForegroundColor DarkGray
                    # human-readable provenance report sidecar (part / date / csys / index / units + table)
                    $reportPath = Join-Path $ScriptDir ($base + "_index_report.txt")
                    $csysMeta = @{ PartNumber = $modelFile; CsysFeatId = $cs.NewFeatId; Units = 'model units'; WhenIso = (Get-Date).ToString('o') }
                    $rep = Write-IndexHoleReport -Records $csysRecords -IndexPointId $res.PointId -Diameter $holeDiaFinal -Meta $csysMeta -Path $reportPath
                    if ($rep.Ok) { Write-Host ("    (readable report -> $($rep.Path))") -ForegroundColor DarkGray }
                } else {
                    Write-Host ("  Could not export hole coordinates: {0}" -f $exp.Reason) -ForegroundColor Yellow
                }

                # --- STAGE 7: create datum points REFERENCED FROM the index csys ---
                # One datum-point feature offset from the csys, at every exported
                # coordinate (Offset Coordinate System, Cartesian). WIDGETS UNVERIFIED
                # (see Build-CsysOffsetPointsMacro) -> canary-gated; a no-op prints the
                # record recipe and creates nothing. --no-csys-points skips it.
                if ($ScriptArgs -match '(?i)--no-csys-points') {
                    Write-Host "  (--no-csys-points) skipping csys-referenced datum points." -ForegroundColor DarkGray
                } else {
                    Write-Host "  (Experimental: the offset-coordinate-system dialog widgets are a best GUESS -" -ForegroundColor DarkGray
                    Write-Host "   not yet recorded live. If created, VERIFY the points' placement in Creo.)" -ForegroundColor DarkGray
                    $ansPts = Read-Host "  Also create datum points referenced from this coordinate system? (y/N)"
                    if ($ansPts -match '^[Yy]$') {
                        $hr = Get-HolesRelativeToIndex -Records $csysRecords -IndexPointId $res.PointId -Diameter $holeDiaFinal
                        if ($hr.Ok -and @($hr.Rows).Count -gt 0) {
                            Write-Host ("  Creating {0} datum point(s) offset from the csys (X/Y/Z from the export)..." -f @($hr.Rows).Count) -ForegroundColor Cyan
                            $cp = Invoke-CsysOffsetPoints -CsysFeatId ([int]$cs.NewFeatId) -Rows @($hr.Rows)
                            if ($cp.Ok) {
                                $indexPointsCreated = $cp.Created
                                # count matched, but the offset-csys widgets are a guess -> the
                                # count alone does NOT prove the points are offset FROM the csys at
                                # the intended X/Y/Z. Report UNVERIFIED (amber), never a green "done".
                                Write-Host ("  {0} datum point(s) created -- UNVERIFIED: widgets are a best guess," -f $cp.Created) -ForegroundColor Yellow
                                Write-Host "  so the count matched but the PLACEMENT is not checked. Verify in Creo that" -ForegroundColor Yellow
                                Write-Host "  each point is offset from the coordinate system at the intended X/Z." -ForegroundColor Yellow
                            } elseif ($cp.Created -gt 0) {
                                Write-Host ("  Created {0} of {1} point(s) -- inspect Creo (count mismatch)." -f $cp.Created, $cp.Expected) -ForegroundColor Yellow
                            } else {
                                Write-Host ("  No csys-referenced points created: {0}" -f $cp.Reason) -ForegroundColor Yellow
                                Write-Host "  The offset-csys dialog widgets are a GUESS. Record the mapkey (see" -ForegroundColor DarkGray
                                Write-Host "  Build-CsysOffsetPointsMacro's header recipe) and I'll lock them." -ForegroundColor DarkGray
                            }
                        } else {
                            Write-Host ("  No coordinates to place: {0}" -f $hr.Reason) -ForegroundColor Yellow
                        }
                    } else {
                        Write-Host "  Skipped csys-referenced datum points." -ForegroundColor DarkGray
                    }
                }
            } else {
                Write-Host ("  Coordinate system NOT created: {0}" -f $cs.Reason) -ForegroundColor Yellow
            }
        }
    } else {
        # MANUAL path: no registry (predefined points). User selects 3 perpendicular
        # planes in X/Y/Z-normal order.
        Write-Host ""
        Write-Host "  No tracked hole planes this run (predefined points). Select 3 mutually-" -ForegroundColor Yellow
        Write-Host "  perpendicular planes IN ORDER (X-normal, then Y-normal, then Z-normal) -" -ForegroundColor Yellow
        Write-Host "  their intersection is the csys origin." -ForegroundColor Yellow
        $manualIds = @()
        foreach ($axis in @('X','Y','Z')) {
            Read-Host "    Click the $axis-normal plane in Creo, then press ENTER"
            $id = Read-SelectedId
            if ($null -eq $id) { Write-Host "    Nothing selected for $axis - aborting the csys." -ForegroundColor Yellow; $manualIds = @(); break }
            $manualIds += [int]$id
            Write-Host "      $axis-normal plane feature id = $id" -ForegroundColor DarkGray
        }
        if (@($manualIds).Count -eq 3) {
            $cs = Invoke-IndexCsys -PlaneIds @($manualIds) -Show
            if ($cs.Ok) {
                $indexCsysFeatId = $cs.NewFeatId
                Write-Host ("  Done -- coordinate system created (new feature id {0}). Verify axes visually in Creo." -f $cs.NewFeatId) -ForegroundColor Green
            } else {
                Write-Host ("  Coordinate system NOT created: {0}" -f $cs.Reason) -ForegroundColor Yellow
            }
        }
    }
}

# ============================================================================
# FINAL WORD
# ============================================================================
Write-Host ""
if ($script:macroFailures -eq 0) {
    Write-Host "  Run complete (no mapkey failures)." -ForegroundColor Cyan
} else {
    Write-Host "  Run complete with $($script:macroFailures) mapkey failure(s) - see red lines above." -ForegroundColor Yellow
}
if ($null -ne $script:buildConfirmed) {
    if ($script:buildConfirmed) {
        Write-Host "  Box build: independently confirmed by the blind evaluator (solid measured)." -ForegroundColor Green
    } else {
        Write-Host "  Box build: NOT independently confirmed - see the blind-evaluator verdict above." -ForegroundColor Yellow
        Write-Host "  (An eval packet was written; it can also be judged offline.)" -ForegroundColor DarkGray
    }
}
# Index-csys / export / points summary (parity with the GUI Done step).
if ($null -ne $indexCsysFeatId) {
    Write-Host ("  Index coordinate system: created (feature id {0}); verify axes visually." -f $indexCsysFeatId) -ForegroundColor Green
    if ($null -ne $indexCsvPath) { Write-Host ("  Hole coordinates (relative to the index csys): $indexCsvPath") -ForegroundColor White }
    if ($indexPointsCreated -gt 0) { Write-Host ("  Datum points referenced from the index csys: {0} created -- UNVERIFIED (verify placement in Creo)." -f $indexPointsCreated) -ForegroundColor Yellow }
}

} finally {
    try {
        if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null }
        if ($null -ne $origDynamicPreview)  { $session.SetConfigOption("dynamic_preview",  $origDynamicPreview)  | Out-Null }
    } catch {}
    try { $connection.Disconnect($null) } catch {}
}

Write-Host ""
Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
