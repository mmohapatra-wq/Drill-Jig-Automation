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
#   (GUI)     (optional) right after the tree, lay out an orthogrid hole pattern
#             in a WinForms editor, pre-filled with the tree's hole Ø + depth as
#             read-only context. Captures the spec only; no Creo yet.
#   STAGE 2   build a parametric box from offset planes (plane-probe v2). When a
#             pattern was captured, TOP offset = plate width and FRONT offset =
#             plate height come straight from the GUI (SIDE = bushing length).
#             Auto-mapped planes build the box with no prompts.
#   STAGE 2.5 (orthogrid mode) you create ONE seed datum point at the grid corner;
#             the grid is made later by PATTERNING THE HOLE (STAGE 5), not by
#             patterning points. If no clean seed, STAGE 3 picks points instead.
#   STAGE 3   drill an On-Point hole on the seed point (or every selected point),
#             diameter from STAGE 1; capture the new hole feature id.
#   STAGE 4   (metal: ask / 3DP: auto) add a coaxial chip-relief hole on the same
#             point(s); capture the new relief feature id.
#   STAGE 5   (orthogrid mode) Direction-pattern the hole (+ relief) feature(s)
#             into the Nx x Nz grid (TOP x Nx @ CcX, FRONT x Nz @ CcZ); canary-
#             gated, with a printed manual Edit > Pattern fallback.
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
# DATUM POINTS: STAGE 2.5 can GENERATE the target datum points as an orthogrid
# (a regular Nx x Nz grid laid out from the box's TOP/FRONT datums on the SIDE
# face). If you skip STAGE 2.5, the prototype falls back to its original
# assumption -- the target datum points ALREADY EXIST in the CAD file and STAGE 3
# just selects them. Open the jig PART (not the .asm) with its default datum
# planes (FRONT/RIGHT/TOP); pre-placed datum points are only needed when you skip
# the STAGE 2.5 grid generation.
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

# Turn a machinist fraction or plain number ("3/4", "0.5") into a decimal.
function ConvertTo-Decimal {
    param([string]$Text)
    if ($Text -match '^\s*(\d+)\s*/\s*(\d+)\s*$') {
        return [double]$matches[1] / [double]$matches[2]
    }
    $d = 0.0
    if ([double]::TryParse($Text, [ref]$d)) { return $d }
    return $null
}

# Pull the machinist-fraction label for a dimension out of an EasyName so the
# menu can show "3/4" / "1 3/8" instead of decimals. EasyName format is
#   "<tag> | OD <od> x ID <id> x <len> Lg"
# $Which is 'OD' or 'Lg' (length). Falls back to the decimal value if the name
# doesn't parse (e.g. drill IDs are stored decimal).
function Get-FracLabel {
    param([string]$EasyName, [string]$Which, [string]$Fallback)
    if ($EasyName) {
        if ($Which -eq 'OD' -and $EasyName -match 'OD\s+(.+?)\s+x') {
            return $matches[1].Trim()
        }
        if ($Which -eq 'Lg' -and $EasyName -match 'x\s+([^x]+?)\s+Lg') {
            return $matches[1].Trim()
        }
    }
    return $Fallback
}

# Parse a free-text outcome label into a catalog query:
#   { File = '<csv path>'; Filters = @( @{ Column='ID'|'OD'; Values=@(<decimals>) }, ... ) }
# Returns $null if the label isn't a catalog-show instruction.
function Get-CatalogSpec {
    param([string]$Label)
    if (-not $Label) { return $null }
    $low = $Label.ToLower()

    # category -> file
    $file = $null
    if ($low -match 'removable|drill') {
        $file = Join-Path $dataDir 'bushings_drill.csv'
    } elseif ($low -match 'sleeve') {
        $file = Join-Path $dataDir 'bushings.csv'
    }
    if (-not $file) { return $null }

    # constraints: every "<fraction-or-number> ID|OD" token, grouped by column
    $byCol = @{}
    $rx = [regex]'(\d+(?:/\d+)?(?:\.\d+)?)\s*(ID|OD)'
    foreach ($m in $rx.Matches($Label)) {
        $val = ConvertTo-Decimal $m.Groups[1].Value
        $col = $m.Groups[2].Value.ToUpper()
        if ($null -eq $val) { continue }
        if (-not $byCol.ContainsKey($col)) { $byCol[$col] = @() }
        $byCol[$col] += $val
    }

    $filters = @()
    foreach ($col in $byCol.Keys) {
        $filters += @{ Column = $col; Values = @($byCol[$col] | Select-Object -Unique) }
    }

    return @{ File = $file; Filters = $filters }
}

# Parse a FIXED-OD outcome label -> the hole diameter (decimal), or $null.
# Some tree leaves declare the hole OD outright instead of showing a catalog,
# e.g. metal -> PFD: "the OD of the hole will be 3/4 in". There is no bushing to
# pick (so no length), just a hard diameter. Only catalog labels carry the
# removable/drill/sleeve keyword, so any label reaching here is NOT a catalog
# show; we match "OD ... <fraction|number>" and convert it.
function Get-FixedOdSpec {
    param([string]$Label)
    if (-not $Label) { return $null }
    if ($Label -notmatch '(?i)\bOD\b') { return $null }
    # the first fraction/number that appears AFTER the word OD is the hole OD
    if ($Label -match '(?i)\bOD\b[^0-9]*(\d+(?:/\d+)?(?:\.\d+)?)') {
        return (ConvertTo-Decimal $matches[1])
    }
    return $null
}

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

# Forced regen with fallbacks (lifted verbatim-in-spirit from boxinator). On this
# No-Resolve build the API forced regen throws IpfcXToolkitBadContext, so the
# reliable path is the UI ProCmdRegenerate; automatic regen is the last resort.
function Invoke-ForceRegen {
    param($Model)
    try {
        $regenCls = New-Object -ComObject pfcls.pfcRegenInstructions
        $instr    = $regenCls.Create($false, $true, $null)   # Create(AllowFixUI, ForceRegen, FromFeat)
        $Model.Regenerate($instr)
        return
    } catch {}
    $before = $null
    try { $before = $Model.VersionStamp } catch {}
    Invoke-Macro "force regenerate (UI)" "~ Command ``ProCmdRegenerate``;"
    if ($null -ne $before) {
        for ($i = 0; $i -lt 30; $i++) {
            try { if ($Model.VersionStamp -ne $before) { return } } catch {}
            Start-Sleep -Milliseconds 50
        }
    }
    try { $Model.Regenerate($null) } catch {}
}

# NOTE: Get-LinearDimMap and Read-DimValue live in lib\creo_geometry.ps1
# (dot-sourced below) and are shared with the blind evaluator.

# Snapshot every feature ID on the model. The new datum-plane feature is found by
# diffing this before vs after creation (same approach boxinator uses to find a
# fresh extrude), so we capture the plane's feature ID without guessing.
function Get-FeatureIdSet {
    param($Model, $TypeObj)
    $set = @{}
    try {
        foreach ($f in $Model.ListItems($TypeObj.ITEM_FEATURE)) {
            try { $set[[int]$f.Id] = $true } catch {}
        }
    } catch {}
    return $set
}

# Diff the current ITEM_FEATURE set against a prior Get-FeatureIdSet snapshot and
# return the @(new int feature ids), sorted ascending. Used to capture the hole /
# relief feature ids just created (STAGE 3/4) so STAGE 5 can pattern them.
function Resolve-NewFeatureIds {
    param($Model, $TypeObj, $Before)
    $after = Get-FeatureIdSet -Model $Model -TypeObj $TypeObj
    $new = @()
    foreach ($id in $after.Keys) {
        if (-not $Before.ContainsKey($id)) { $new += [int]$id }
    }
    return @($new | Sort-Object)
}

# Read the (last) selected feature ID from Creo's selection buffer, or $null.
function Read-SelectedId {
    $contents = ($session.CurrentSelectionBuffer()).Contents
    if ($null -eq $contents -or $contents.Count -eq 0) { return $null }
    try { return [int]$contents[$contents.Count - 1].SelItem.Id } catch { return $null }
}

# Map a datum-plane NAME to its box role by substring (case-insensitive). This is
# what lets a ONE-SHOT multi-select of all three default datums be sorted into
# TOP/SIDE/FRONT regardless of the click order - the name carries the role, not
# the order. SIDE is the important one: it drives the box length AND is the plane
# the box is sketched on, so the box build can run hands-free once SIDE is known.
# Returns 'Top'/'Side'/'Front' (matching $planes[].Label) or $null if no keyword
# is present. SIDE is tested first so a stray match can't shadow it.
function Resolve-PlaneRole {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $u = $Name.ToUpper()
    if ($u -match 'SIDE')  { return 'Side' }
    if ($u -match 'TOP')   { return 'Top' }
    if ($u -match 'FRONT') { return 'Front' }
    return $null
}

# Read the CURRENT selection buffer as datum-plane picks: one entry per UNIQUE
# selected item, each { Id; Name; Role }. Name is the datum's GetName(); Role is
# Resolve-PlaneRole on that name. ID-and-name only - never reads geometry/coords
# (the toolkit's hard-won ID-only lesson; plane normals also read $null on this
# build per project_plane_normal_null, so a name match is the only viable
# auto-classifier here). De-dups by id. Returns @() if the buffer is empty.
function Read-SelectionPlanePicks {
    param($Session)
    $picks = @()
    $contents = $null
    try { $contents = ($Session.CurrentSelectionBuffer()).Contents } catch {}
    if ($null -eq $contents -or $contents.Count -eq 0) { return @($picks) }
    $seen = @{}
    foreach ($item in $contents) {
        $si = $null
        try { $si = $item.SelItem } catch { continue }
        if ($null -eq $si) { continue }
        $id = $null
        try { $id = [int]$si.Id } catch { continue }
        if ($seen.ContainsKey($id)) { continue }
        $seen[$id] = $true
        $name = $null
        try { $name = [string]$si.GetName() } catch {}
        $picks += [pscustomobject]@{ Id = $id; Name = $name; Role = (Resolve-PlaneRole -Name $name) }
    }
    return @($picks)
}

# Build the tree-search select-by-ID macro fragment for a Feature (the proven
# nodelator/flipenator pattern). Clears the buffer, then selects the feature with
# the given ID INTO the buffer. The caller appends whatever command should
# consume that buffered selection.
#
# -NoClear omits the leading buffer_clean. Use it when feeding a dashboard
# reference collector that is already open and waiting for a pick (clearing the
# buffer mid-dashboard can deactivate that collector).
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

# Select a DATUM PLANE by ID into an ALREADY-OPEN dashboard reference collector
# (the extrude depth "to selected" collector). This mirrors surfenator's PROVEN
# up-to-plane feed (surfenator.cmd): the tree search picks type DATUM with
# LookBy = Feature, which hands the collector a real GEOMETRIC reference.
#
# Why a separate helper from Get-SelectByIdMacro: that one selects type FEATURE,
# which is correct for CONSUMING a buffered ref (ProCmdDatumPlane) or showing a
# feature, and so the base-plane creation + sketch-plane pick work with it. But a
# Feature-typed selection does NOT satisfy the depth collector's reference filter
# -- the symptom being the extrude dashboard sitting OPEN, waiting for a manual
# plane click (exactly the behavior this replaces). No leading buffer_clean:
# clearing the buffer mid-dashboard can deactivate the open collector.
function Get-SelectDatumByIdMacro {
    param([int]$FeatId)
    return "~ Command ``ProCmdMdlTreeSearch``;" +
        "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Datum``;" +
        "~ Select ``selspecdlg0`` ``LookByOptionMenu`` 1 ``Feature``;" +
        "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
        "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$FeatId``;" +
        "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
        "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
        "~ Activate ``selspecdlg0`` ``CancelButton``;"
}

# Create ONE offset plane from a base reference selected BY ID and return a
# [pscustomobject] with its new offset dim Symbol and new feature Id (either may
# be $null if none/ambiguous appeared). The base plane's feature ID was captured
# up front, so this fires with no human interaction.
function New-OffsetPlane {
    param($Model, $TypeObj, [string]$Label, [double]$Offset, [int]$BaseId)

    $before     = Get-LinearDimMap   -Model $Model -TypeObj $TypeObj
    $beforeFeat = Get-FeatureIdSet   -Model $Model -TypeObj $TypeObj

    # ONE atomic macro: clear buffer -> tree-search-select base plane BY ID ->
    # open ProCmdDatumPlane (ref pre-loaded from buffer) -> offset -> blur -> OK.
    $macro =
        (Get-SelectByIdMacro -FeatId $BaseId) +
        "~ Command ``ProCmdDatumPlane``;" +
        "~ Input  ``Odui_Dlg_00`` ``t1.constr_dim1`` ``$Offset``;" +
        "~ Update ``Odui_Dlg_00`` ``t1.constr_dim1`` ``$Offset``;" +
        "~ FocusOut ``Odui_Dlg_00`` ``t1.constr_dim1``;" +
        "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;"

    Invoke-Macro "$Label plane: open + offset $Offset + OK" $macro

    # POLL for the new offset dim to appear, rather than waiting a fixed interval.
    # A heavier model commits the datum plane more slowly; this breaks the instant
    # a new symbol shows up, so a fast model stays fast.
    $MaxWaitSec = 20
    $newSyms    = @()
    $after      = $before
    for ($i = 0; $i -lt ($MaxWaitSec * 10); $i++) {
        $after   = Get-LinearDimMap -Model $Model -TypeObj $TypeObj
        $newSyms = @($after.Keys | Where-Object { -not $before.ContainsKey($_) })
        if ($newSyms.Count -ge 1) { break }
        if ($i -eq 20) { Write-Host "    (waiting for Creo to commit the $Label plane...)" -ForegroundColor DarkGray }
        Start-Sleep -Milliseconds 100
    }

    # The new datum-plane feature ID, by feature-set diff (used later to show it).
    $afterFeat = Get-FeatureIdSet -Model $Model -TypeObj $TypeObj
    $newFeats  = @($afterFeat.Keys | Where-Object { -not $beforeFeat.ContainsKey($_) })
    $newFeatId = if ($newFeats.Count -ge 1) { [int]$newFeats[0] } else { $null }

    if ($newSyms.Count -eq 0) {
        Write-Host "    No new linear dim appeared for the $Label plane after ${MaxWaitSec}s." -ForegroundColor Yellow
        Write-Host "    The plane may still have been created (feature id $newFeatId) - if so this" -ForegroundColor Yellow
        Write-Host "    is a dim-enumeration issue, not a creation failure. Otherwise the base" -ForegroundColor Yellow
        Write-Host "    plane ID ($BaseId) didn't select, or t1.constr_dim1/stdbtn_1 differ." -ForegroundColor Yellow
        return [pscustomobject]@{ Symbol = $null; FeatId = $newFeatId }
    }
    if ($newSyms.Count -gt 1) {
        Write-Host "    More than one new dim appeared ($($newSyms -join ', ')); taking the first." -ForegroundColor Yellow
    }
    $sym = [string]$newSyms[0]
    Write-Host "    $Label offset dim: $sym = $($after[$sym])" -ForegroundColor Green
    return [pscustomobject]@{ Symbol = $sym; FeatId = $newFeatId }
}

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

# Write one plane's offset, force a regen, return the value that actually stuck.
function Set-PlaneOffset {
    param($Plane, [double]$Value)
    try {
        $d = $model.GetItemByName($pfcType.ITEM_DIMENSION, $Plane.Sym)
        $d.DimValue = $Value
    } catch {
        Write-Host "    $($Plane.Label): could not write DimValue: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
    Invoke-ForceRegen -Model $model
    return (Read-DimValue -Model $model -TypeObj $pfcType -Sym $Plane.Sym)
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

function Wait-ModelModified {
    # $true if VersionStamp changed within the timeout (macro modified the model).
    param($Model, [string]$PreviousStamp, [int]$TimeoutMs = 30000)
    $deadline = [DateTime]::Now.AddMilliseconds($TimeoutMs)
    while ([DateTime]::Now -lt $deadline) {
        try { if ($Model.VersionStamp -ne $PreviousStamp) { return $true } } catch {}
    }
    return $false
}

# Recorded hole macro (transcribed live 2026-06-11). ID-driven; ONE atomic
# RunMacro -- a dashboard's command context does not survive across RunMacro
# calls (CLAUDE.md boxinator lesson). `~ Trail`/`~ Timer` recording noise dropped.
function Build-HoleMacro {
    param([int]$PointId, [double]$Diameter, [int]$BodyIndex = 0, [int]$SurfacePlaneId = 0)
    # For intersection-of-3-planes points (orthogrid mode), Creo can't auto-infer
    # the placement surface. Fix: pre-select the SIDE base datum (type DATUM) as
    # the placement surface, THEN the point (type Point, -NoClear to accumulate).
    # ProCmdHole receives both → On Point with surface pre-filled. For holeinator-
    # style points (already on a surface), pass SurfacePlaneId=0 → point-only.
    $sel = ""
    if ($SurfacePlaneId -gt 0) {
        # Clean buffer FIRST (stale refs from prior ops cause Linear mode), then
        # surface (Datum-typed tree search), then Point (accumulated, no buffer_clean).
        $sel = "~ Activate ``main_dlg_cur`` ``buffer_clean``;" +
            (Get-SelectDatumByIdMacro -FeatId $SurfacePlaneId) +
            "~ Command ``ProCmdMdlTreeSearch``;" +
            "~ Open ``selspecdlg0`` ``SelOptionRadio``;" +
            "~ Close ``selspecdlg0`` ``SelOptionRadio``;" +
            "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Point``;" +
            "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
            "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$PointId``;" +
            "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
            "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
            "~ Activate ``selspecdlg0`` ``CancelButton``;"
    } else {
        # Original holeinator: point-only (surface auto-inferred from point's association).
        $sel = "~ Activate ``main_dlg_cur`` ``buffer_clean``;" +
            "~ Command ``ProCmdMdlTreeSearch``;" +
            "~ Open ``selspecdlg0`` ``SelOptionRadio``;" +
            "~ Close ``selspecdlg0`` ``SelOptionRadio``;" +
            "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Point``;" +
            "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
            "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$PointId``;" +
            "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
            "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
            "~ Activate ``selspecdlg0`` ``CancelButton``;"
    }
    # Flip the drill direction when a surface plane was pre-selected (orthogrid mode).
    $flip = ""
    if ($SurfacePlaneId -gt 0) {
        $flip = "~ Activate ``main_dlg_cur`` ``maindashInst0.Flip``;"
    }
    return $sel +
        # hole dashboard (recorded)
        "~ Command ``ProCmdHole``;" +
        $flip +
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

# ----------------------------------------------------------------------------
# Build-ReliefHoleMacro - a CHIP-RELIEF hole: coaxial with the through-hole (same
# on-point datum-point location, so it reuses the proven point-select / body /
# diameter path verbatim) but BLIND instead of Thru All. ONE atomic RunMacro
# (dashboard context does not survive across RunMacro calls).
#
# *** DEPTH IS SET AFTER CREATION, NOT IN THIS MACRO (boxinator pattern). ***
# The macro creates the hole as BLIND (StrHoleDepBlindF -- confirmed firing live
# in trail.txt.3 2026-06-22) but does NOT type the depth value. WHY: the blind
# depth-VALUE widget name was never recordable -- a guessed '~ Input maindashInst0.
# depth_*_mip_OptionMenu' was SILENTLY DROPPED by Creo (it never appeared in the
# trail), so the hole kept Creo's default blind depth and drilled through the
# plate. A Blind hole's depth is a FEATURE-LEVEL Linear dimension, so the reliable
# fix (same as boxinator's extrude depth / plane-probe's offset) is: create the
# blind hole here, then in the caller find its new Linear depth dim by a
# before/after Get-LinearDimMap diff and write DimValue + Invoke-ForceRegen --
# a feature-level DimValue write STICKS on a closed feature regardless of regen
# mode. This sidesteps the unknown depth-VALUE widget entirely.
#
# So this macro takes NO depth param: it just makes a blind hole of $Diameter at
# $PointId on body $BodyIndex with Creo's default depth; the caller fixes depth.
# (The diameter widget maindashInst0.diameter_mip_OptionMenu IS confirmed -- the
# through-holes set their diameter through it correctly.)
# ----------------------------------------------------------------------------
function Build-ReliefHoleMacro {
    param([int]$PointId, [double]$Diameter, [int]$BodyIndex = 0, [int]$SurfacePlaneId = 0)
    $blindDepthType = "StrHoleDepBlindF"   # CONFIRMED live (trail.txt.3 2026-06-22)
    # Same surface+point selection logic as Build-HoleMacro (see its comment).
    $sel = ""
    if ($SurfacePlaneId -gt 0) {
        # Clean buffer FIRST (stale refs cause Linear mode), then surface + point.
        $sel = "~ Activate ``main_dlg_cur`` ``buffer_clean``;" +
            (Get-SelectDatumByIdMacro -FeatId $SurfacePlaneId) +
            "~ Command ``ProCmdMdlTreeSearch``;" +
            "~ Open ``selspecdlg0`` ``SelOptionRadio``;" +
            "~ Close ``selspecdlg0`` ``SelOptionRadio``;" +
            "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Point``;" +
            "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
            "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$PointId``;" +
            "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
            "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
            "~ Activate ``selspecdlg0`` ``CancelButton``;"
    } else {
        $sel = "~ Activate ``main_dlg_cur`` ``buffer_clean``;" +
            "~ Command ``ProCmdMdlTreeSearch``;" +
            "~ Open ``selspecdlg0`` ``SelOptionRadio``;" +
            "~ Close ``selspecdlg0`` ``SelOptionRadio``;" +
            "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Point``;" +
            "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
            "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$PointId``;" +
            "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
            "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
            "~ Activate ``selspecdlg0`` ``CancelButton``;"
    }
    $flip = ""
    if ($SurfacePlaneId -gt 0) {
        $flip = "~ Activate ``main_dlg_cur`` ``maindashInst0.Flip``;"
    }
    return $sel +
        # hole dashboard
        "~ Command ``ProCmdHole``;" +
        $flip +
        # depth-type -> BLIND (creates a drivable depth dim; value set after regen)
        "~ Select ``main_dlg_cur`` ``maindashInst0.hole_depth_to_type_flybtn``;" +
        "~ Close  ``main_dlg_cur`` ``maindashInst0.hole_depth_to_type_flybtn``;" +
        "~ Activate ``main_dlg_cur`` ``maindashInst0.$blindDepthType`` 1;" +
        # standard-hole layout + hole-note toggles (as recorded)
        "~ Activate ``main_dlg_cur`` ``chkbn.std_hle_layout.0`` 1;" +
        "~ Activate ``main_dlg_cur`` ``chkbn.std_hole_note_layout.0`` 1;" +
        # body selection
        "~ Activate ``main_dlg_cur`` ``chkbn.body_page.0`` 1;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ``$BodyIndex``;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ````;" +
        "~ Focus  ``body_page.1.0`` ``PH.bodyselectrepwdg_list``;" +
        "~ Select ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` 1 ``$BodyIndex``;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ````;" +
        # diameter (relief = original + delta) -- this widget IS confirmed working
        "~ Input  ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu`` ``$Diameter``;" +
        "~ Update ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu`` ``$Diameter``;" +
        "~ Activate ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu``;" +
        "~ FocusOut ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu``;" +
        # confirm
        "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"
}

# Drive a freshly-created BLIND hole to its target depth, the boxinator way:
# diff the model's Linear-dim set before vs after the hole to find its new depth
# dim (the hole's diameter is a Diameter-type dim, so Get-LinearDimMap -- Linear
# only -- isolates the depth), write DimValue + force a regen, then re-read to
# confirm it held. Returns a status string: 'held' / 'wrote-unconfirmed' /
# 'no-depth-dim' / 'error'. $BeforeMap is the Get-LinearDimMap snapshot taken
# immediately BEFORE the create macro ran.
function Set-ReliefHoleDepth {
    param($BeforeMap, [double]$Depth)
    $after = Get-LinearDimMap -Model $model -TypeObj $pfcType
    $newSyms = @($after.Keys | Where-Object { -not $BeforeMap.ContainsKey($_) })
    if ($newSyms.Count -eq 0) { return @{ Status = 'no-depth-dim'; Sym = $null; Value = $null } }
    if ($newSyms.Count -gt 1) {
        # On-point blind hole should add exactly ONE new linear dim (the depth).
        # If more appear, the largest is the safest depth guess, but warn loudly.
        Write-Host "      (>1 new linear dim after hole: $($newSyms -join ', '); taking the largest as depth)" -ForegroundColor Yellow
    }
    # pick the new linear dim with the LARGEST current value: a default blind depth
    # is the through-ish value we are shrinking, and any stray placement dim would
    # be smaller. Deterministic tiebreak when the on-point case isn't clean.
    $depthSym = $newSyms | Sort-Object { [double]$after[$_] } -Descending | Select-Object -First 1
    try {
        $d = $model.GetItemByName($pfcType.ITEM_DIMENSION, [string]$depthSym)
        $d.DimValue = $Depth
    } catch {
        return @{ Status = 'error'; Sym = $depthSym; Value = $null }
    }
    Invoke-ForceRegen -Model $model
    $now = Read-DimValue -Model $model -TypeObj $pfcType -Sym ([string]$depthSym)
    if ($null -ne $now -and [math]::Abs($now - $Depth) -lt 1e-4) {
        return @{ Status = 'held'; Sym = $depthSym; Value = $now }
    }
    return @{ Status = 'wrote-unconfirmed'; Sym = $depthSym; Value = $now }
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

# Material drives STAGE 4's chip-relief gate. A 3D-printed part ALWAYS gets the
# chip-relief holes made automatically (no y/N) so the run doesn't pause for a
# confirmation we already know the answer to; metal (or any non-3D-print / un-
# resolved path) keeps the human y/N gate. The material is the user's answer to
# the root question, which the walk recorded into $path -- the "3d print" signal
# only ever enters $path via that material option (the metal sub-answers are
# "PFD"/"Hand Drill"), so matching $path for it is unambiguous. Safe default:
# auto-act ONLY on the explicit 3D-print choice; everything else still asks.
$is3dPrint = @($path | Where-Object { $_ -match '(?i)3d\s*print' }).Count -gt 0
if ($is3dPrint) {
    Write-Host "  Material: 3D print -> chip-relief holes will be added automatically (STAGE 4, no prompt)." -ForegroundColor Cyan
    Write-Host ""
}

# ============================================================================
# ORTHOGRID PATTERN (GUI) -- right after the decision tree, BEFORE Creo.
# ============================================================================
# The orthogrid editor is pure WinForms (no Creo), so it runs here while the
# tree's numbers are fresh and BEFORE we connect/build the box. It only CAPTURES
# the pattern spec ($orthoGeo); the datum points are CREATED later in STAGE 2.5,
# once the box + its TOP/SIDE/FRONT datums exist. The decision-tree hole diameter
# ($holeDia), the chip-relief diameter (= hole x RELIEF_DIA_MULT, the WIDEST
# feature), and bushing length / drill depth ($bushingLen) are passed in as
# read-only context. The relief dia ALSO sizes the plate (Show-OrthogridDialog
# feeds it to Get-OrthogridGeometry as -ClearDia), so the box Width/Height clears
# the relief circle at the border -- the operator no longer hand-adds the hole dia.
# RELIEF_DIA_MULT is defined ONCE here and reused by STAGE 4. Answer 'n' (or cancel
# the dialog) to skip -- STAGE 3 then uses hand-selected points.
$RELIEF_DIA_MULT = 1.5
$reliefDiaForGui = 0.0
if ($null -ne $holeDia -and [double]$holeDia -gt 0) { $reliefDiaForGui = [Math]::Round([double]$holeDia * $RELIEF_DIA_MULT, 4) }
$orthoGeo = $null
$useOrtho = Read-Host "  Lay out an orthogrid hole pattern now? (Y/n)"
if ($useOrtho -match '^[Nn]') {
    Write-Host "  Skipping the orthogrid - STAGE 3 will use hand-selected pre-existing points." -ForegroundColor DarkGray
} else {
    try { $orthoGeo = Show-OrthogridDialog -HoleDiameter $holeDia -ReliefDiameter $reliefDiaForGui -Thickness $bushingLen } catch { $orthoGeo = $null }
    if ($null -eq $orthoGeo) {
        Write-Host "  Orthogrid editor cancelled (or unavailable) - STAGE 3 will use hand-selected points." -ForegroundColor Yellow
    } else {
        Write-Host ("  Grid captured: {0} holes, part {1:0.00} x {2:0.00} (Nx={3}, Nz={4}, cc {5}x{6}, edge {7}, relief-clear {8}). Points created in STAGE 2.5/5." -f `
            $orthoGeo.Count, $orthoGeo.Width, $orthoGeo.Height, $orthoGeo.Nx, $orthoGeo.Nz, $orthoGeo.CcX, $orthoGeo.CcZ, $orthoGeo.Edge, $orthoGeo.ClearDia) -ForegroundColor Green
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
# PREFERRED: ONE multi-select of all three default datums (Ctrl-click TOP, SIDE,
# FRONT together), then read each pick's NAME and auto-sort them into roles by
# substring (TOP/SIDE/FRONT). The name carries the role, so click order does not
# matter. We then show the mapping and confirm ONCE; on accept the box build runs
# hands-free (SIDE drives the sketch plane + the extrude-to plane). If the buffer
# does not yield a clean, unambiguous all-three mapping, we fall back to the
# original per-plane sequential capture (one click each) so the tool never wedges.
Write-Host "  Identify the three base planes." -ForegroundColor Cyan
Write-Host "  In Creo, Ctrl-click ALL THREE default datums (TOP, SIDE, FRONT) - any order -" -ForegroundColor White
Write-Host "  then press ENTER here. (They are matched to roles by NAME, not click order.)" -ForegroundColor White
Read-Host

$autoMapped = $false
$picks = @(Read-SelectionPlanePicks -Session $session)

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
    $res = New-OffsetPlane -Model $model -TypeObj $pfcType -Label $p.Label -Offset $p.Offset -BaseId $p.BaseId
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
# STAGE 2.5 -- ORTHOGRID DATUM-POINT GRID (plane intersections, all by ID)
# ============================================================================
# Programmatic creation of every grid point via the PROVEN 3-plane-intersection
# recipe (point-probe.cmd, confirmed live 2026-06-24): for each grid position, the
# point = intersection of (SIDE offset face) + (an X-offset plane from TOP) + (a
# Z-offset plane from FRONT). Planes are SHARED (1 face + Nx X-planes + Nz Z-planes
# → Nx·Nz intersection points). ALL widgets confirmed live; NO screen picks; each
# RunMacro is atomic + independent (no dashboard-survival issue). Each coordinate is
# a drivable feature-level offset dim → fully parametric. Completely replaces the
# broken pattern approach and the manual seed-pick step.
# If the plane/point creation fails, falls back to Invoke-ManualPointGrid (user
# creates + selects all points by hand). Never drills a zero-point "Done".
$gridPointIDs = @()
if ($null -ne $orthoGeo) {
    Write-Host "  ====================================================================" -ForegroundColor Cyan
    Write-Host "   STAGE 2.5 - create all $($orthoGeo.Count) datum points (plane intersections)" -ForegroundColor Cyan
    Write-Host "  ====================================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host ("  Grid: {0} points, plate {1:0.00} x {2:0.00} (Nx={3}, Nz={4}, cc {5}x{6})." -f `
        $orthoGeo.Count, $orthoGeo.Width, $orthoGeo.Height, $orthoGeo.Nx, $orthoGeo.Nz, $orthoGeo.CcX, $orthoGeo.CcZ) -ForegroundColor Green

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
        Write-Host "  Missing base datum or SIDE offset plane - cannot auto-create the grid." -ForegroundColor Yellow
        Write-Host "  Falling back to the manual path (you create + select all points by hand)." -ForegroundColor Yellow
    } else {
        Write-Host "  Creating Nx=$($orthoGeo.Nx) X-planes + Nz=$($orthoGeo.Nz) Z-planes + $($orthoGeo.Count) intersection points..." -ForegroundColor Cyan
        Write-Host "  (All by ID, no picks, no pattern - fully automatic.)" -ForegroundColor DarkGray
        $ok = $true

        # 1. Create Nx X-offset planes (offset from TOP base by each X coord).
        $xPlaneIds = @()
        $xCoords = @(0..($orthoGeo.Nx - 1) | ForEach-Object { [double]$orthoGeo.Points[$_ * $orthoGeo.Nz].X })
        foreach ($xOff in $xCoords) {
            $res = New-OffsetPlane -Model $model -TypeObj $pfcType -Label "X$($xPlaneIds.Count)" -Offset $xOff -BaseId ([int]$topBaseId)
            if ($null -eq $res.FeatId) { Write-Host "  X-plane at offset $xOff FAILED." -ForegroundColor Red; $ok = $false; break }
            $xPlaneIds += [int]$res.FeatId
        }
        if ($ok) { Write-Host ("  {0} X-planes created." -f $xPlaneIds.Count) -ForegroundColor DarkGray }

        # 2. Create Nz Z-offset planes (offset from FRONT base by each Z coord).
        $zPlaneIds = @()
        if ($ok) {
            $zCoords = @(0..($orthoGeo.Nz - 1) | ForEach-Object { [double]$orthoGeo.Points[$_].Z })
            foreach ($zOff in $zCoords) {
                $res = New-OffsetPlane -Model $model -TypeObj $pfcType -Label "Z$($zPlaneIds.Count)" -Offset $zOff -BaseId ([int]$frontBaseId)
                if ($null -eq $res.FeatId) { Write-Host "  Z-plane at offset $zOff FAILED." -ForegroundColor Red; $ok = $false; break }
                $zPlaneIds += [int]$res.FeatId
            }
            if ($ok) { Write-Host ("  {0} Z-planes created." -f $zPlaneIds.Count) -ForegroundColor DarkGray }
        }

        # 3. Create Nx·Nz intersection points: each = face ∩ X-plane[I] ∩ Z-plane[J].
        if ($ok) {
            $beforePts = Get-PointIdSet -Model $model -TypeObj $pfcType
            $ptOk = $true
            $ptIdx = 0
            foreach ($pt in $orthoGeo.Points) {
                $ptIdx++
                Show-Progress ([Math]::Floor(($ptIdx / $orthoGeo.Count) * 100)) "Point $ptIdx/$($orthoGeo.Count)"
                $macro = Build-IntersectPointMacro -PlaneIds @([int]$facePlaneId, [int]$xPlaneIds[$pt.I], [int]$zPlaneIds[$pt.J])
                try { $session.RunMacro($macro) } catch {
                    Write-Host "  Point $ptIdx macro errored: $($_.Exception.Message)" -ForegroundColor Red
                    $ptOk = $false; break
                }
            }
            Show-Progress 100 "Done"
            $newIds = Resolve-NewPointIds -Model $model -TypeObj $pfcType -Before $beforePts
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
            Write-Host "  Auto grid creation had issues. Falling back to manual point selection." -ForegroundColor Yellow
            if ($gridPointIDs.Count -eq 0) {
                $gridPointIDs = @(Invoke-ManualPointGrid -Geo $orthoGeo -Session $session -TypeObj $pfcType)
            }
        }
    }

    if ($gridPointIDs.Count -gt 0) {
        Write-Host ("  Orthogrid ready: {0} point(s) for STAGE 3 drilling." -f $gridPointIDs.Count) -ForegroundColor Green
    } else {
        if (-not $canAutoGrid) {
            $gridPointIDs = @(Invoke-ManualPointGrid -Geo $orthoGeo -Session $session -TypeObj $pfcType)
        }
        if ($gridPointIDs.Count -eq 0) {
            Write-Host "  No orthogrid points captured - STAGE 3 will fall back to a manual selection." -ForegroundColor Yellow
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
# Prefer the orthogrid grid created in STAGE 2.5 (all Nx·Nz points, no pattern);
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
# In orthogrid mode (grid created programmatically) auto-pick body 0 with no prompt.
# In manual mode, ask only if >1 body.
if ($gridPointIDs.Count -gt 0) {
    Write-Host "  Body index: 0 (auto, orthogrid mode)." -ForegroundColor DarkGray
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
# Orthogrid mode: auto-proceed (the user committed at the GUI; everything after is automatic).
if ($gridPointIDs.Count -gt 0) {
    $go = 'y'
    Write-Host "  Proceeding automatically (orthogrid mode)." -ForegroundColor Cyan
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
# STAGE 4 -- CHIP-RELIEF HOLES (separate gated step)
# ============================================================================
# A chip-relief hole is a wider, shallow, BLIND hole COAXIAL with each through-
# hole, giving drill chips somewhere to clear. Same on-point datum points, so it
# reuses the through-hole point/body path verbatim and only changes:
#   diameter = 1.5 x through-hole diameter  (hardcoded multiplier)
#   depth    = 20% of the plate thickness in the drill direction (hardcoded pct)
#
# DEPTH IS APPLIED AFTER CREATION (boxinator pattern): Build-ReliefHoleMacro makes
# a BLIND hole at Creo's default depth, then Set-ReliefHoleDepth finds the new
# Linear depth dim (before/after Get-LinearDimMap diff) and writes DimValue +
# force-regen. This replaced typing the depth into the dashboard, which silently
# failed -- the blind depth-VALUE widget name was never recordable and Creo
# dropped the '~ Input', so every relief hole drilled THROUGH (live 2026-06-22).
#
# THICKNESS SOURCE (decided with the user 2026-06-22): the box was BUILT this run
# by extruding from an og datum UP TO the SIDE offset plane, and the holes drill
# ALONG the SIDE direction -- so the SIDE plane's offset dim IS the plate
# thickness the hole passes through. We read that dim LIVE (Read-DimValue by the
# Side plane's captured .Sym) rather than measuring the solid with EvalOutline +
# a guessed surface normal. Why live, not the cached $made[Side].Offset / the
# STAGE-1 $bushingLen: the resize loop writes new offsets via Set-PlaneOffset
# (DimValue + regen) but does NOT update those scalars, so they go STALE after a
# resize -- only a fresh Read-DimValue reflects the current box. If no Side plane
# with a drivable dim exists this run (creation failed, or the box was never
# built), fall back to a manual thickness prompt.
#
# This replaces an earlier surface-pick + Read-SurfaceNormal + EvalOutline path:
# the picked surface was used ONLY to measure thickness (it was never the drill-
# from face -- the relief is placed On-Point by ID), and that normal read was a
# guess proven for cylinders, not planes, so it could silently mis-measure.
# $RELIEF_DIA_MULT was defined once up at the orthogrid-GUI block (reused here).
$RELIEF_DEPTH_PCT = 0.20

Write-Host ""
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "   STAGE 4 - chip-relief holes (wider + shallow, on the same points)" -ForegroundColor Cyan
Write-Host "  ====================================================================" -ForegroundColor Cyan
# GATE: 3D-printed parts make the relief holes automatically (no prompt) so the
# run doesn't stall on a question we already know the answer to; metal (and any
# non-3D-print / unresolved path) still asks the human y/N. $is3dPrint was
# derived from the STAGE-1 decision path right after the walk.
if ($is3dPrint -or $gridPointIDs.Count -gt 0) {
    # Orthogrid mode OR 3D print: auto-add relief (no prompt); the user committed
    # at the GUI / the material gate. Metal non-orthogrid still asks.
    $doRelief = 'y'
    if ($is3dPrint) {
        Write-Host "  Material is 3D print -- adding chip-relief holes automatically." -ForegroundColor Cyan
    } else {
        Write-Host "  Orthogrid mode -- adding chip-relief holes automatically." -ForegroundColor Cyan
    }
} else {
    $doRelief = Read-Host "  Add chip-relief holes on these points? (y/N)"
}
if ($doRelief -notmatch '^[Yy]$') {
    Write-Host "  Skipped chip-relief holes." -ForegroundColor DarkGray
} else {
    # --- STEP 1: relief depth = 20% of the live SIDE-plane offset (drill-axis
    # plate thickness), with a manual fallback. Re-derive the Side plane from
    # $made (NOT the STAGE-2-scoped $sidePlane) and re-read its dim LIVE so a
    # post-build resize is reflected; never trust the cached .Offset/$bushingLen.
    Write-Host ""
    $reliefDepth = 0.0
    $reliefSide  = @($made | Where-Object { $_.Label -eq "Side" })
    $reliefSide  = if ($reliefSide.Count -gt 0) { $reliefSide[0] } else { $null }
    $thickness   = $null
    if ($null -ne $reliefSide -and $null -ne $reliefSide.Sym) {
        $live = Read-DimValue -Model $model -TypeObj $pfcType -Sym $reliefSide.Sym
        if ($null -ne $live -and $live -gt 0) { $thickness = [double]$live }
    }
    if ($null -ne $thickness -and $thickness -gt 0) {
        $reliefDepth = [Math]::Round($thickness * $RELIEF_DEPTH_PCT, 4)
        Write-Host ("  Plate thickness from the live SIDE offset ({0} = {1}`"):  relief depth {2}`" ({3:P0})" -f `
            $reliefSide.Sym, [Math]::Round($thickness,4), $reliefDepth, $RELIEF_DEPTH_PCT) -ForegroundColor Green
    } else {
        Write-Host "  No live SIDE offset dim this run -- enter the plate thickness by hand." -ForegroundColor Yellow
        $thicknessRaw = $null
        while ($reliefDepth -le 0) {
            $thicknessRaw = Read-Host "  Plate thickness in the drill direction (relief depth = 20% of it)"
            $tv = 0.0
            if ([double]::TryParse($thicknessRaw.Trim(), [ref]$tv) -and $tv -gt 0) {
                $reliefDepth = [Math]::Round($tv * $RELIEF_DEPTH_PCT, 4)
            } else { Write-Host "  Enter a positive number." -ForegroundColor Yellow }
        }
        Write-Host ("  Relief depth: {0}`" (20% of {1}`")" -f $reliefDepth, $thicknessRaw.Trim()) -ForegroundColor Green
    }

    $reliefDia = [Math]::Round($holeDiaFinal * $RELIEF_DIA_MULT, 4)

    # --- No second confirm: saying yes to "Add chip-relief holes?" above already
    # authorized this; proceed straight to drilling (user, 2026-06-24). ---
    Write-Host ""
    Write-Host ("  Ready: {0} relief hole(s), diameter {1}`" (= {2} x {3}), blind depth {4}`", body index {5}." -f `
        $pointIDs.Count, $reliefDia, $holeDiaFinal, $RELIEF_DIA_MULT, $reliefDepth, $bodyIndex) -ForegroundColor Cyan
    Write-Host ""
        # --- FIRE -- canary first, then the rest (same guard as through-holes) ---
        # Each hole: snapshot Linear dims -> create BLIND hole (default depth) ->
        # find the new depth dim by diff -> write DimValue=reliefDepth + force regen.
        $rTotal = $pointIDs.Count
        $rIdx = 0; $rMade = 0; $rNoop = 0; $rFail = 0; $rAbort = $false
        $rDepthHeld = 0; $rDepthMiss = 0
        foreach ($ptId in $pointIDs) {
            $rIdx++
            Show-Progress ([Math]::Floor(($rIdx / $rTotal) * 100)) "Relief $rIdx/$rTotal"
            # snapshot the Linear-dim set BEFORE creating the hole (depth-dim diff)
            $beforeMap = Get-LinearDimMap -Model $model -TypeObj $pfcType
            $rSurfId = 0
            if ($gridPointIDs.Count -gt 0 -and $null -ne $sidePlane -and $null -ne $sidePlane.FeatId) {
                $rSurfId = [int]$sidePlane.FeatId
            }
            $macro = Build-ReliefHoleMacro -PointId $ptId -Diameter $reliefDia -BodyIndex $bodyIndex -SurfacePlaneId $rSurfId
            $changed = $false
            try {
                $stamp = $model.VersionStamp
                $session.RunMacro($macro)
                $changed = Wait-ModelModified -Model $model -PreviousStamp $stamp
            } catch { $rFail++ }
            if ($changed) {
                $rMade++
                # NOW drive the blind depth via the feature-level dim (boxinator way)
                $dr = Set-ReliefHoleDepth -BeforeMap $beforeMap -Depth $reliefDepth
                if ($dr.Status -eq 'held') {
                    $rDepthHeld++
                } else {
                    $rDepthMiss++
                    Write-Host ""
                    Write-Host ("      depth not confirmed on hole {0}: {1} (sym {2}, read {3}, wanted {4})" -f `
                        $rIdx, $dr.Status, $dr.Sym, $dr.Value, $reliefDepth) -ForegroundColor Yellow
                }
            } else { $rNoop++ }
            if ($rIdx -eq 1 -and -not $changed) {
                Show-Progress 100 "Canary failed"
                Write-Host ""
                Write-Host "  ABORT: the first RELIEF hole did not modify the model." -ForegroundColor Red
                Write-Host "  StrHoleDepBlindF was confirmed firing live, so this is more likely a" -ForegroundColor Red
                Write-Host "  point-select / body-select issue than the depth-type -- inspect Creo." -ForegroundColor Red
                $rAbort = $true
                break
            }
            # depth-canary: if hole #1 changed the model but NO depth dim was found
            # to drive, the rest will all drill through too -- stop and report.
            if ($rIdx -eq 1 -and $changed -and $rDepthMiss -eq 1) {
                Show-Progress 100 "Depth canary"
                Write-Host ""
                Write-Host "  ABORT: the first relief hole was created but its blind DEPTH dim" -ForegroundColor Red
                Write-Host "  could not be found/driven, so it would drill through like before." -ForegroundColor Red
                Write-Host "  Set-ReliefHoleDepth status was '$($dr.Status)'. Inspect the new hole's" -ForegroundColor Red
                Write-Host "  dims in Creo; the Linear-dim diff may need adjusting for this build." -ForegroundColor Red
                $rAbort = $true
                break
            }
        }
        if (-not $rAbort) { Show-Progress 100 "Done" }
        Write-Host ""
        Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
        Write-Host ("  Relief points     : {0}" -f $rTotal) -ForegroundColor White
        Write-Host ("  Model changed     : {0}" -f $rMade) -ForegroundColor White
        Write-Host ("  Depth confirmed   : {0}" -f $rDepthHeld) -ForegroundColor White
        if ($rDepthMiss -gt 0) { Write-Host ("  Depth NOT confirmed: {0}" -f $rDepthMiss) -ForegroundColor Yellow }
        if ($rNoop -gt 0) { Write-Host ("  No-op (no change) : {0}" -f $rNoop) -ForegroundColor Yellow }
        if ($rFail -gt 0) { Write-Host ("  Macro errors      : {0}" -f $rFail) -ForegroundColor Yellow }
        Write-Host ""
        if ($rAbort) {
            Write-Host "  STOPPED after the canary -- inspect the model in Creo." -ForegroundColor Red
        } elseif ($rMade -eq $rTotal -and $rFail -eq 0 -and $rDepthMiss -eq 0) {
            Write-Host "  Done -- $rMade chip-relief hole(s) created and driven to depth $reliefDepth`". Verify visually in Creo." -ForegroundColor Green
        } else {
            Write-Host "  Finished with issues -- $rMade of $rTotal changed the model, $rDepthHeld at correct depth. Inspect Creo." -ForegroundColor Yellow
        }
}

# (STAGE 5 REMOVED: the Direction-pattern approach was abandoned after multiple
# iterations -- screen picks needed, dashboard didn't survive, chaining made an "L".
# All grid points are now created programmatically in STAGE 2.5 via plane intersections,
# and STAGE 3/4 drill + relief every point. No pattern needed.)

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
