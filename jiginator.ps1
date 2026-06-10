<#
  jiginator.ps1 - drill jig decision-tree prompt (walker)

  Reads the decision tree authored in docs/drill_jig_tree_builder.html
  (saved to docs/drill_jig_decision_tree.json) and walks the user through it
  in the console. The tree is the single source of truth - edit it in the HTML
  builder and this prompt updates automatically, no code changes needed.

  This is the QUESTION FLOW only. It ends by printing the chosen path and the
  resolved outcome(s) - i.e. which subset of the bushing catalog to show.
  Creo connection, datum-point read, and geometry creation come later.
#>

$ErrorActionPreference = 'Stop'

# --- locate the tree JSON relative to this script ---
$treePath = Join-Path $PSScriptRoot 'docs\drill_jig_decision_tree.json'
if (-not (Test-Path $treePath)) {
    Write-Host "ERROR: decision tree not found at:" -ForegroundColor Red
    Write-Host "  $treePath" -ForegroundColor Red
    Write-Host "Build it in docs\drill_jig_tree_builder.html and link/save it there first." -ForegroundColor Yellow
    return
}

try {
    $tree = Get-Content $treePath -Raw | ConvertFrom-Json
} catch {
    Write-Host "ERROR: could not parse the tree JSON: $($_.Exception.Message)" -ForegroundColor Red
    return
}

# ConvertFrom-Json gives a single object if the root array has one element;
# normalize to an array either way.
$roots = @($tree)

# --- catalog -----------------------------------------------------------------

$dataDir = Join-Path $PSScriptRoot 'data'

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

    Write-Host ""
    Write-Host "  $($rows.Count) matching bushing(s):" -ForegroundColor Cyan
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $r = $rows[$i]
        Write-Host ("    {0,3}) {1}   [OD {2}  ID {3}]" -f ($i + 1), $r.EasyName, $r.OD, $r.ID) -ForegroundColor White
    }
    Write-Host ""

    while ($true) {
        $raw = Read-Host "  Pick a bushing (1-$($rows.Count), or Q to skip)"
        if ($raw -match '^[Qq]$') { return $null }
        $n = 0
        if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $rows.Count) {
            return $rows[$n - 1]
        }
        Write-Host "  Enter a number between 1 and $($rows.Count)." -ForegroundColor Yellow
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
