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

# --- catalog -----------------------------------------------------------------

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

            # synthetic "ID unspecified" result - OD still drives the hole
            $idUnspec = [pscustomobject]@{
                EasyName   = "$tag | OD $odLabel x ID (any) x $lenLbl Lg"
                OD         = $idRows[0].OD
                ID         = '(any)'
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

    $again = Read-Host "Run again? (y/N)"
} while ($again -match '^[Yy]')

Write-Host "Done." -ForegroundColor Green
