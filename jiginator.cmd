<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

# jiginator.cmd - drill jig decision-tree prompt (walker)
#
# Reads the decision tree authored in docs\drill_jig_tree_builder.html
# (saved to docs\drill_jig_decision_tree.json) and walks the user through it
# in the console. The tree is the single source of truth - edit it in the HTML
# builder and this prompt updates automatically, no code changes needed.
#
# This is the QUESTION FLOW only. It ends by printing the chosen path and the
# resolved outcome(s) - i.e. which subset of the bushing catalog to show, and
# the hole diameter (selected bushing OD). Creo connection, datum-point read,
# and geometry creation come later.

$Host.UI.RawUI.WindowTitle = "JIGINATOR"
$ErrorActionPreference = "Stop"

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

# --- locate the tree JSON relative to this script ---
$treePath = Join-Path $ScriptDir 'docs\drill_jig_decision_tree.json'
if (-not (Test-Path $treePath)) {
    Write-Host "ERROR: decision tree not found at:" -ForegroundColor Red
    Write-Host "  $treePath" -ForegroundColor Red
    Write-Host "Build it in docs\drill_jig_tree_builder.html and link/save it there first." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

try {
    $tree = Get-Content $treePath -Raw | ConvertFrom-Json
} catch {
    Write-Host "ERROR: could not parse the tree JSON: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

# ConvertFrom-Json gives a single object if the root array has one element;
# normalize to an array either way.
$roots = @($tree)

# Handoff file: when an outcome resolves a bushing, the resolved OD (= jig hole
# diameter) is written here so holeinator can pick it up and pre-fill its verify
# diameter -- the same file-based handoff style as datinator -> diminator.
$handoffPath = Join-Path $ScriptDir 'last_jig_spec.json'

# --- catalog -----------------------------------------------------------------

$dataDir = Join-Path $ScriptDir 'data'

# Turn a machinist fraction or plain number ("3/4", "0.5") into a decimal.
function ConvertTo-Decimal {
    param([string]$Text)
    if ($Text -match '^\s*(\d+)\s*/\s*(\d+)\s*$') {
        if ([double]$matches[2] -eq 0) { return $null }   # "3/0" -> $null, not Infinity
        return [double]$matches[1] / [double]$matches[2]
    }
    $d = 0.0
    if ([double]::TryParse($Text, [ref]$d)) { return $d }
    return $null
}

# Pull the machinist-fraction label for a dimension out of an EasyName so the
# menu can show "3/4" / "1 3/8" instead of decimals. EasyName format is
#   "<tag> | OD <od> x ID <id> x <len> Lg"
# $Which is 'OD', 'ID', or 'Lg' (length). Falls back to the decimal value if the
# name doesn't parse (e.g. drill IDs are stored decimal -> ID branch returns the
# decimal; sleeve IDs are fractions -> returns the fraction).
function Get-FracLabel {
    param([string]$EasyName, [string]$Which, [string]$Fallback)
    if ($EasyName) {
        if ($Which -eq 'OD' -and $EasyName -match 'OD\s+(.+?)\s+x') {
            return $matches[1].Trim()
        }
        if ($Which -eq 'ID' -and $EasyName -match 'x\s+ID\s+(.+?)\s+x') {
            return $matches[1].Trim()
        }
        if ($Which -eq 'Lg' -and $EasyName -match 'x\s+([^x]+?)\s+Lg') {
            return $matches[1].Trim()
        }
    }
    return $Fallback
}

# Group catalog rows into the ID-FIRST hierarchy ID -> length -> ODs (all ascending).
# Local copy of lib\drilljig_core.ps1's Group-CatalogByID (jiginator.cmd is
# self-contained by design - it dot-sources no lib). The ODs tier is ALWAYS
# populated so callers gate the OD tie-breaker on the ODCount integer; OD is the
# drilled jig hole and is never silently chosen when ODCount > 1.
function Group-CatalogByID {
    param([array]$Rows)
    $out = @()
    if ($null -eq $Rows -or $Rows.Count -eq 0) { return ,@($out) }
    $idGroups = @($Rows | Group-Object ID | Sort-Object { [double]$_.Name })
    foreach ($ig in $idGroups) {
        $idLabel = Get-FracLabel $ig.Group[0].EasyName 'ID' $ig.Name
        $lenOut = @()
        $lenGroups = @($ig.Group | Group-Object Length | Sort-Object { [double]$_.Name })
        foreach ($lg in $lenGroups) {
            $lenLabel = Get-FracLabel $lg.Group[0].EasyName 'Lg' $lg.Name
            $odOut = @()
            $odGroups = @($lg.Group | Group-Object OD | Sort-Object { [double]$_.Name })
            foreach ($og in $odGroups) {
                $odLabel = Get-FracLabel $og.Group[0].EasyName 'OD' $og.Name
                $odOut += [pscustomobject]@{
                    OD      = [double]$og.Name
                    ODLabel = $odLabel
                    # sort by PartNumber (ID is constant at this leaf) so Rows[0] is deterministic
                    Rows    = @($og.Group | Sort-Object PartNumber)
                }
            }
            $lenOut += [pscustomobject]@{
                Length   = [double]$lg.Name
                LenLabel = $lenLabel
                ODCount  = $odOut.Count
                ODs      = $odOut
            }
        }
        $out += [pscustomobject]@{
            ID      = [double]$ig.Name
            IDLabel = $idLabel
            Lengths = $lenOut
        }
    }
    return ,@($out)
}

# ---------------------------------------------------------------------------
# STANDARDIZED-LENGTH PICK (user 2026-07-21). LOCAL copies of the shared helpers
# in lib\drilljig_core.ps1 (jiginator.cmd dot-sources no lib by design). The length
# menu is now a FIXED {1/2, 3/4, 1} + Custom, with a length RECOMMENDED from the ID;
# OD is re-keyed on ID ALONE (union of the ID's distinct ODs). Keep byte-in-sync with
# the lib copies.
# ---------------------------------------------------------------------------
$script:StdLengths = @(
    [pscustomobject]@{ Value = 0.5;  Label = '1/2' },
    [pscustomobject]@{ Value = 0.75; Label = '3/4' },
    [pscustomobject]@{ Value = 1.0;  Label = '1'   }
)
function Get-BushingLengthOptions {
    param([double]$Id)
    $opts = @()
    foreach ($s in $script:StdLengths) {
        $opts += [pscustomobject]@{ Value = [double]$s.Value; Label = [string]$s.Label; IsCustom = $false }
    }
    $opts += [pscustomobject]@{ Value = $null; Label = 'Custom'; IsCustom = $true }
    $pre = -1
    for ($i = 0; $i -lt $script:StdLengths.Count; $i++) {
        if ([math]::Abs([double]$script:StdLengths[$i].Value - $Id) -lt 1e-6) { $pre = $i; break }
    }
    return @{ Options = $opts; PreselectIndex = $pre }
}
function Get-IdOdOptions {
    param($IdGroup)
    $byOd = @{}
    if ($null -ne $IdGroup) {
        foreach ($ln in @($IdGroup.Lengths)) {
            foreach ($od in @($ln.ODs)) {
                $key = ('{0:0.######}' -f [double]$od.OD)
                if (-not $byOd.ContainsKey($key)) {
                    $byOd[$key] = [pscustomobject]@{ OD = [double]$od.OD; ODLabel = [string]$od.ODLabel; Rows = @() }
                }
                $byOd[$key].Rows += @($od.Rows)
            }
        }
    }
    $out = @($byOd.Values | Sort-Object { [double]$_.OD })
    foreach ($o in $out) { $o.Rows = @($o.Rows | Sort-Object { [double]$_.Length }, PartNumber) }
    return ,@($out)
}
function Resolve-BushingPickRow {
    param($IdGroup, $OdOption, [double]$Length, [string]$LenLabel)
    $exact = @($OdOption.Rows | Where-Object { [math]::Abs([double]$_.Length - $Length) -lt 1e-6 } | Select-Object -First 1)
    if ($exact.Count -gt 0) { return $exact[0] }
    $tag = 'Bushing'
    if (@($OdOption.Rows).Count -gt 0 -and $OdOption.Rows[0].EasyName) {
        $tag = ($OdOption.Rows[0].EasyName -split '\|')[0].Trim()
    }
    return [pscustomobject]@{
        EasyName   = ("{0} | OD {1} x ID {2} x {3} Lg" -f $tag, $OdOption.ODLabel, $IdGroup.IDLabel, $LenLabel)
        OD         = [double]$OdOption.OD
        ID         = [double]$IdGroup.ID
        Length     = [double]$Length
        PartNumber = '(custom length)'
    }
}
function Resolve-BushingLengthInput {
    param([string]$Text, [double]$Default = 0.5)
    $r = @{ Ok = $false; Value = [double]$Default; Error = $null }
    if ($null -eq $Text -or [string]::IsNullOrWhiteSpace($Text)) { $r.Ok = $true; $r.Value = [double]$Default; return $r }
    $t = $Text.Trim()
    $v = $null
    if ($t -match '^\s*(\d+)\s+(\d+)\s*/\s*(\d+)\s*$') {
        $den = [double]$matches[3]
        if ($den -ne 0) { $v = [double]$matches[1] + ([double]$matches[2] / $den) }
    } else {
        $v = ConvertTo-Decimal $t
    }
    if ($null -eq $v) { $r.Error = ("Not a number: '{0}'" -f $t); return $r }
    if ([double]::IsNaN([double]$v) -or [double]::IsInfinity([double]$v)) { $r.Error = ("Not a number: '{0}'" -f $t); return $r }
    if ($v -le 0) { $r.Error = 'Length must be greater than 0.'; return $r }
    $r.Ok = $true; $r.Value = [math]::Round([double]$v, 4)
    return $r
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

    # ID-FIRST staged pick (user 2026-07-21): ID first, then a STANDARDIZED length menu
    # {1/2, 3/4, 1} + Custom with a length RECOMMENDED from the ID (a 1/2" ID sleeve is
    # normally 1/2" long, a 3/4" ID 3/4" long). The fixed menu is decoupled from the
    # catalog length-rows, so OD is re-keyed on ID ALONE (Get-IdOdOptions) -- auto-resolved
    # when unique, offered as a tie-breaker when the ID reaches more than one OD. OD is
    # the drilled jig hole and is NEVER silently guessed. Group-CatalogByID supplies the IDs.
    $byId = Group-CatalogByID -Rows $rows

    while ($true) {

        # --- stage 1: distinct IDs (bore size), ascending ---
        Write-Host ""
        Write-Host "  Select ID (bore size):" -ForegroundColor Cyan
        for ($i = 0; $i -lt $byId.Count; $i++) {
            $g = $byId[$i]
            $ods = Get-IdOdOptions -IdGroup $g
            $hole = if (@($ods).Count -eq 1) { ("-> hole {0:0.###}`"" -f $ods[0].OD) } else { ("{0} OD options" -f @($ods).Count) }
            $bit = if ($g.Lengths[0].ODs[0].Rows[0].PSObject.Properties.Name -contains 'DrillBitSize' -and $g.Lengths[0].ODs[0].Rows[0].DrillBitSize) { "  ($($g.Lengths[0].ODs[0].Rows[0].DrillBitSize))" } else { '' }
            Write-Host ("    {0,3}) ID {1,-7}{2}   ({3})" -f ($i + 1), $g.IDLabel, $bit, $hole) -ForegroundColor White
        }
        Write-Host ""

        $idPick = $null
        while ($true) {
            $raw = Read-Host "  Pick ID (1-$($byId.Count), or Q to skip)"
            if ($raw -match '^[Qq]$') { return $null }
            $n = 0
            if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $byId.Count) {
                $idPick = $byId[$n - 1]; break
            }
            Write-Host "  Enter a number between 1 and $($byId.Count)." -ForegroundColor Yellow
        }
        $odOptions = Get-IdOdOptions -IdGroup $idPick

        # --- stage 2: STANDARDIZED length menu {1/2, 3/4, 1} + Custom, ID-recommended ---
        $backToId = $false
        while (-not $backToId) {
            $lenOpt = Get-BushingLengthOptions -Id $idPick.ID
            $opts   = @($lenOpt.Options)
            $preIdx = [int]$lenOpt.PreselectIndex
            Write-Host ""
            Write-Host ("  Select length (ID {0}):" -f $idPick.IDLabel) -ForegroundColor Cyan
            for ($i = 0; $i -lt $opts.Count; $i++) {
                $o = $opts[$i]
                $tag = if ($i -eq $preIdx) { "   <- recommended for ID $($idPick.IDLabel)" } elseif ($o.IsCustom) { "   (type any length)" } else { '' }
                $lbl = if ($o.IsCustom) { 'Custom' } else { ("{0}`" Lg" -f $o.Label) }
                Write-Host ("    {0,3}) {1,-10}{2}" -f ($i + 1), $lbl, $tag) -ForegroundColor White
            }
            $recNote = if ($preIdx -ge 0) { "ENTER = recommended ($($opts[$preIdx].Label)`"), " } else { '' }
            Write-Host ""

            $chosenLen = $null; $chosenLabel = $null
            while ($true) {
                $raw = Read-Host "  Pick length (1-$($opts.Count), ${recNote}B to change ID, or Q to skip)"
                if ($raw -match '^[Qq]$') { return $null }
                if ($raw -match '^[Bb]$') { $backToId = $true; break }
                if ([string]::IsNullOrWhiteSpace($raw) -and $preIdx -ge 0) {
                    $chosenLen = [double]$opts[$preIdx].Value; $chosenLabel = $opts[$preIdx].Label; break
                }
                $n = 0
                if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $opts.Count) {
                    $o = $opts[$n - 1]
                    if ($o.IsCustom) {
                        $def = if ($preIdx -ge 0) { [double]$opts[$preIdx].Value } else { 0.5 }
                        while ($true) {
                            $ctxt = Read-Host "    Enter custom length in inches (e.g. 0.9, 3/8, 1 3/8; Q to cancel)"
                            if ($ctxt -match '^[Qq]$') { break }
                            $res = Resolve-BushingLengthInput -Text $ctxt -Default $def
                            if ($res.Ok) { $chosenLen = [double]$res.Value; $chosenLabel = ('{0:0.###}' -f $chosenLen); break }
                            Write-Host "    $($res.Error)" -ForegroundColor Yellow
                        }
                        if ($null -ne $chosenLen) { break }
                        continue
                    }
                    $chosenLen = [double]$o.Value; $chosenLabel = $o.Label; break
                }
                Write-Host "  Enter a number between 1 and $($opts.Count) (or ENTER / B / Q)." -ForegroundColor Yellow
            }
            if ($backToId) { break }          # back to stage 1
            if ($null -eq $chosenLen) { continue }

            # --- stage 3: OD - AUTO-RESOLVED when unique, tie-breaker only when not ---
            if (@($odOptions).Count -eq 1) {
                $odPick = $odOptions[0]
                Write-Host ("  Hole diameter = {0:0.###}`" (the only OD for ID {1}); length = {2}`"." -f $odPick.OD, $idPick.IDLabel, $chosenLabel) -ForegroundColor Green
                return (Resolve-BushingPickRow -IdGroup $idPick -OdOption $odPick -Length $chosenLen -LenLabel $chosenLabel)
            }

            # ambiguous: this bore is available at more than one OD. OD IS the drilled
            # hole, so the operator MUST choose it - never silently picked.
            while ($true) {
                Write-Host ""
                Write-Host ("  ID {0} is available at more than one OD - OD IS the drilled hole, so pick it:" -f $idPick.IDLabel) -ForegroundColor Cyan
                for ($i = 0; $i -lt $odOptions.Count; $i++) {
                    $od = $odOptions[$i]
                    Write-Host ("    {0,3}) OD {1,-7} [hole = {2:0.###}]" -f ($i + 1), $od.ODLabel, $od.OD) -ForegroundColor White
                }
                Write-Host ""
                $raw = Read-Host "  Pick OD (1-$($odOptions.Count), B to change length, or Q to skip)"
                if ($raw -match '^[Qq]$') { return $null }
                if ($raw -match '^[Bb]$') { break }   # back to stage 2 (re-show length menu)
                $n = 0
                if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $odOptions.Count) {
                    return (Resolve-BushingPickRow -IdGroup $idPick -OdOption $odOptions[$n - 1] -Length $chosenLen -LenLabel $chosenLabel)
                }
                Write-Host "  Enter a number between 1 and $($odOptions.Count) (or B / Q)." -ForegroundColor Yellow
            }
        }
    }
}

# --- helpers ---------------------------------------------------------------

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
                    [void]$Outcomes.Add(("Bushing: {0}  ->  hole diameter = {1}`" (OD)" -f $pick.EasyName, $od))
                    # record the resolved hole spec for the holeinator handoff
                    [void]$script:Picks.Add([pscustomobject]@{
                        HoleDiameter = $od
                        Bushing      = $pick.EasyName
                        PartNumber   = $pick.PartNumber
                        Outcome      = $Node.label
                    })
                } else {
                    [void]$Outcomes.Add("(no bushing selected) $($Node.label)")
                }
            } else {
                [void]$Outcomes.Add($Node.label)
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

# --- main loop -------------------------------------------------------------

Write-Host ""
Write-Host "=== Drill Jig Configurator ===" -ForegroundColor Green
Write-Host "Reading tree: $treePath" -ForegroundColor DarkGray

do {
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
        Write-Host "Cancelled." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "----------------------------------------" -ForegroundColor DarkGray
    Write-Host "Your selections:" -ForegroundColor Green
    Write-Host ("  " + ($path -join "  >  ")) -ForegroundColor White
    Write-Host ""
    Write-Host "Result:" -ForegroundColor Green
    foreach ($o in $outcomes) { Write-Host "  $o" -ForegroundColor White }
    Write-Host "----------------------------------------" -ForegroundColor DarkGray
    Write-Host ""

    # --- handoff to holeinator -------------------------------------------------
    # Persist the resolved hole spec(s) so holeinator can pre-fill its diameter.
    # If several outcomes resolved a bushing, the LAST pick wins as the active
    # hole diameter (matches the on-screen "most recent decision" model); all
    # picks are kept under .AllPicks for reference.
    if ($script:Picks.Count -gt 0) {
        $active = $script:Picks[$script:Picks.Count - 1]
        $handoff = [pscustomobject]@{
            HoleDiameter = $active.HoleDiameter
            Bushing      = $active.Bushing
            PartNumber   = $active.PartNumber
            Outcome      = $active.Outcome
            Path         = ($path -join ' > ')
            AllPicks     = @($script:Picks)
        }
        try {
            $handoff | ConvertTo-Json -Depth 5 | Set-Content -Path $handoffPath -Encoding UTF8
            Write-Host ("Saved hole spec for holeinator: diameter {0}`" -> {1}" -f $active.HoleDiameter, (Split-Path $handoffPath -Leaf)) -ForegroundColor DarkGray
            Write-Host ""
        } catch {
            Write-Host "  (could not write handoff file: $($_.Exception.Message))" -ForegroundColor Yellow
        }
    }

    $again = Read-Host "Run again? (y/N)"
} while ($again -match '^[Yy]')

Write-Host "Done." -ForegroundColor Green
