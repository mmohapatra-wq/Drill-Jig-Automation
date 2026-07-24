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
        if ([double]$matches[2] -eq 0) { return $null }   # "3/0" -> $null, not Infinity
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

# Pull the machinist-fraction label for OD, ID or Lg out of an EasyName
#   "<tag> | OD <od> x ID <id> x <len> Lg"; falls back to $Fallback (e.g. drill IDs
# are stored decimal, so the ID branch returns the decimal; sleeve IDs are fractions).
function Get-FracLabel {
    param([string]$EasyName, [string]$Which, [string]$Fallback)
    if ($EasyName) {
        if ($Which -eq 'OD' -and $EasyName -match 'OD\s+(.+?)\s+x') { return $matches[1].Trim() }
        if ($Which -eq 'ID' -and $EasyName -match 'x\s+ID\s+(.+?)\s+x') { return $matches[1].Trim() }
        if ($Which -eq 'Lg' -and $EasyName -match 'x\s+([^x]+?)\s+Lg') { return $matches[1].Trim() }
    }
    return $Fallback
}

# Group catalog rows into the ID-FIRST hierarchy ID -> length -> ODs (all ascending).
# Local copy of lib\drilljig_core.ps1's Group-CatalogByID (jiginator.ps1 dot-sources
# no lib). The ODs tier is ALWAYS populated so callers gate the OD tie-breaker on the
# ODCount integer; OD is the drilled jig hole and is never silently chosen when >1.
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
                # sort by PartNumber (ID is constant at this leaf) so Rows[0] is deterministic
                $odOut += [pscustomobject]@{ OD = [double]$og.Name; ODLabel = $odLabel; Rows = @($og.Group | Sort-Object PartNumber) }
            }
            $lenOut += [pscustomobject]@{ Length = [double]$lg.Name; LenLabel = $lenLabel; ODCount = $odOut.Count; ODs = $odOut }
        }
        $out += [pscustomobject]@{ ID = [double]$ig.Name; IDLabel = $idLabel; Lengths = $lenOut }
    }
    return ,@($out)
}

# OD-FIRST (METAL removable-bushing) PICK (user 2026-07-22). LOCAL copies of the shared
# lib\drilljig_core.ps1 helpers (jiginator.ps1 dot-sources no lib). METAL -> Hand Drill
# gives an OD-filtered spec (only 1/2" & 3/4" ODs); the drilled hole IS the removable
# bushing's OD, so the flow displays the OD, skips ID, then asks the length. (METAL -> PFD
# is no longer OD-first: user 2026-07-23 changed its leaf to "3/4 ID sleeves" -> ID-first.)
function Test-OdFirstSpec {
    param($Spec)
    if ($null -eq $Spec -or $null -eq $Spec.Filters) { return $false }
    foreach ($f in @($Spec.Filters)) {
        if ($null -ne $f -and ([string]$f.Column).ToUpper() -eq 'OD') { return $true }
    }
    return $false
}
function Get-OdGroups {
    param([array]$Rows)
    $byOd = @{}
    if ($null -ne $Rows) {
        foreach ($r in @($Rows)) {
            $key = ('{0:0.######}' -f [double]$r.OD)
            if (-not $byOd.ContainsKey($key)) {
                $odLabel = Get-FracLabel $r.EasyName 'OD' ([string]$r.OD)
                $byOd[$key] = [pscustomobject]@{ OD = [double]$r.OD; ODLabel = [string]$odLabel; Rows = @() }
            }
            $byOd[$key].Rows += @($r)
        }
    }
    $out = @($byOd.Values | Sort-Object { [double]$_.OD })
    foreach ($o in $out) { $o.Rows = @($o.Rows | Sort-Object { [double]$_.Length }, { [double]$_.ID }, PartNumber) }
    return ,@($out)
}
function Resolve-OdBushingPick {
    param($OdGroup, [double]$Length, [string]$LenLabel)
    $tag = 'Bushing'
    if (@($OdGroup.Rows).Count -gt 0 -and $OdGroup.Rows[0].EasyName) { $tag = ($OdGroup.Rows[0].EasyName -split '\|')[0].Trim() }
    $exact = @($OdGroup.Rows | Where-Object { [math]::Abs([double]$_.Length - $Length) -lt 1e-6 } | Select-Object -First 1)
    $pn = if ($exact.Count -gt 0) { [string]$exact[0].PartNumber } else { '(ID unspecified)' }
    return [pscustomobject]@{
        EasyName   = ("{0} | OD {1} x ID (any) x {2} Lg" -f $tag, $OdGroup.ODLabel, $LenLabel)
        OD         = [double]$OdGroup.OD
        ID         = '(any)'
        Length     = [double]$Length
        PartNumber = $pn
    }
}

# CUSTOM HOLE OD (user 2026-07-23). LOCAL copies of the shared lib\drilljig_core.ps1
# helpers (jiginator.ps1 dot-sources no lib). Let the operator type an ARBITRARY hole
# diameter instead of only catalog ODs; blank is an error (no default OD), and the caller
# shows a bold warning that a real drill bushing / sleeve must be verified. Keep in sync.
function Resolve-CustomOdInput {
    param([string]$Text)
    $r = @{ Ok = $false; Value = 0.0; Error = $null }
    if ($null -eq $Text -or [string]::IsNullOrWhiteSpace($Text)) { $r.Error = 'Enter a hole diameter.'; return $r }
    $t = $Text.Trim()
    $v = $null
    if ($t -match '^\s*(\d+)\s+(\d+)\s*/\s*(\d+)\s*$') {
        $den = [double]$matches[3]
        if ($den -ne 0) { $v = [double]$matches[1] + ([double]$matches[2] / $den) }
    } else { $v = ConvertTo-Decimal $t }
    if ($null -eq $v) { $r.Error = ("Not a number: '{0}'" -f $t); return $r }
    if ([double]::IsNaN([double]$v) -or [double]::IsInfinity([double]$v)) { $r.Error = ("Not a number: '{0}'" -f $t); return $r }
    if ($v -le 0) { $r.Error = 'Hole diameter must be greater than 0.'; return $r }
    $r.Ok = $true; $r.Value = [math]::Round([double]$v, 4)
    return $r
}
function Resolve-CustomOdPick {
    param([double]$OD, [double]$Length, [string]$LenLabel, [string]$OdLabel = $null)
    $odLbl = if ([string]::IsNullOrWhiteSpace($OdLabel)) { ('{0:0.###}' -f [double]$OD) } else { [string]$OdLabel }
    return [pscustomobject]@{
        EasyName   = ("Bushing | OD {0} x ID (custom) x {1} Lg" -f $odLbl, $LenLabel)
        OD         = [double]$OD
        ID         = '(custom)'
        Length     = [double]$Length
        PartNumber = '(verify bushing exists)'
    }
}

# STANDARDIZED-LENGTH PICK (user 2026-07-21). LOCAL copies of the lib\drilljig_core.ps1
# helpers (jiginator.ps1 dot-sources no lib). Fixed {1/2, 3/4, 1} + Custom length menu
# with a length RECOMMENDED from the ID; OD re-keyed on ID ALONE. Keep in sync with lib.
$script:StdLengths = @(
    [pscustomobject]@{ Value = 0.5;  Label = '1/2' },
    [pscustomobject]@{ Value = 0.75; Label = '3/4' },
    [pscustomobject]@{ Value = 1.0;  Label = '1'   }
)
function Get-BushingLengthOptions {
    param([double]$Id)
    $opts = @()
    foreach ($s in $script:StdLengths) { $opts += [pscustomobject]@{ Value = [double]$s.Value; Label = [string]$s.Label; IsCustom = $false } }
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
                if (-not $byOd.ContainsKey($key)) { $byOd[$key] = [pscustomobject]@{ OD = [double]$od.OD; ODLabel = [string]$od.ODLabel; Rows = @() } }
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
    if (@($OdOption.Rows).Count -gt 0 -and $OdOption.Rows[0].EasyName) { $tag = ($OdOption.Rows[0].EasyName -split '\|')[0].Trim() }
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
    } else { $v = ConvertTo-Decimal $t }
    if ($null -eq $v) { $r.Error = ("Not a number: '{0}'" -f $t); return $r }
    if ([double]::IsNaN([double]$v) -or [double]::IsInfinity([double]$v)) { $r.Error = ("Not a number: '{0}'" -f $t); return $r }
    if ($v -le 0) { $r.Error = 'Length must be greater than 0.'; return $r }
    $r.Ok = $true; $r.Value = [math]::Round([double]$v, 4)
    return $r
}

# CUSTOM HOLE OD (user 2026-07-23): prompt for an ARBITRARY hole diameter (not limited to
# the catalog), print a BOLD warning that a real drill bushing / bushing sleeve must be
# verified, then run the standard length menu (recommended from the typed OD). Returns the
# synthesized pick (Resolve-CustomOdPick) or $null on cancel. Reachable from BOTH the
# OD-first (metal) and ID-first (sleeve) menus.
function Invoke-CustomOdPick {
    while ($true) {
        Write-Host ""
        Write-Host "  Custom hole OD (type any diameter -- NOT limited to the catalog):" -ForegroundColor Cyan
        $odVal = $null; $odLabel = $null
        while ($true) {
            $raw = Read-Host "  Enter hole diameter in inches (e.g. 0.6, 3/8, 1 3/8; Q to cancel)"
            if ($raw -match '^[Qq]$') { return $null }
            $res = Resolve-CustomOdInput -Text $raw
            if ($res.Ok) { $odVal = [double]$res.Value; $odLabel = ('{0:0.###}' -f $odVal); break }
            Write-Host "  $($res.Error)" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host ("  ** WARNING: custom hole OD {0}`" has NO catalog bushing behind it.  **" -f $odLabel) -ForegroundColor Yellow
        Write-Host   "  ** Verify a drill bushing / bushing sleeve at this OD actually       **" -ForegroundColor Yellow
        Write-Host   "  ** EXISTS before machining -- double-check against your supplier.     **" -ForegroundColor Yellow
        $backToOd = $false
        while (-not $backToOd) {
            $lenOpt = Get-BushingLengthOptions -Id $odVal
            $opts   = @($lenOpt.Options)
            $preIdx = [int]$lenOpt.PreselectIndex
            Write-Host ""
            Write-Host ("  Select length (custom OD {0}`"):" -f $odLabel) -ForegroundColor Cyan
            for ($i = 0; $i -lt $opts.Count; $i++) {
                $o = $opts[$i]
                $tag = if ($i -eq $preIdx) { "   <- recommended" } elseif ($o.IsCustom) { "   (type any length)" } else { '' }
                $lbl = if ($o.IsCustom) { 'Custom' } else { ("{0}`" Lg" -f $o.Label) }
                Write-Host ("    {0,3}) {1,-10}{2}" -f ($i + 1), $lbl, $tag) -ForegroundColor White
            }
            $recNote = if ($preIdx -ge 0) { "ENTER = recommended ($($opts[$preIdx].Label)`"), " } else { '' }
            Write-Host ""
            $chosenLen = $null; $chosenLabel = $null
            while ($true) {
                $raw = Read-Host "  Pick length (1-$($opts.Count), ${recNote}B to change OD, or Q to skip)"
                if ($raw -match '^[Qq]$') { return $null }
                if ($raw -match '^[Bb]$') { $backToOd = $true; break }
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
                            $lres = Resolve-BushingLengthInput -Text $ctxt -Default $def
                            if ($lres.Ok) { $chosenLen = [double]$lres.Value; $chosenLabel = ('{0:0.###}' -f $chosenLen); break }
                            Write-Host "    $($lres.Error)" -ForegroundColor Yellow
                        }
                        if ($null -ne $chosenLen) { break }
                        continue
                    }
                    $chosenLen = [double]$o.Value; $chosenLabel = $o.Label; break
                }
                Write-Host "  Enter a number between 1 and $($opts.Count) (or ENTER / B / Q)." -ForegroundColor Yellow
            }
            if ($backToOd) { break }
            if ($null -eq $chosenLen) { continue }
            Write-Host ("  Custom hole diameter = {0}`"; length = {1}`" (verify bushing exists)." -f $odLabel, $chosenLabel) -ForegroundColor Green
            return (Resolve-CustomOdPick -OD $odVal -Length $chosenLen -LenLabel $chosenLabel -OdLabel $odLabel)
        }
    }
}

# Load + filter the catalog and let the user pick one row via the ID-FIRST staged
# flow (user 2026-07-21): ID first, then a STANDARDIZED length menu {1/2, 3/4, 1} +
# Custom with a length RECOMMENDED from the ID; OD is re-keyed on ID ALONE and is
# auto-resolved unless the ID reaches more than one OD (then the OD tie-breaker is
# asked; OD is the drilled hole and is never silently guessed). Returns row or $null.
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

    # OD-FIRST metal path (user 2026-07-22): METAL -> Hand Drill is OD-filtered
    # (only 1/2" & 3/4" ODs). The drilled hole IS the removable bushing's OD, so DISPLAY
    # THE OD, skip the ID question, then ask the standardized length (recommended from the
    # OD value). The 3D-print SLEEVE path AND METAL -> PFD (user 2026-07-23: "3/4 ID sleeves")
    # are ID-filtered and fall through to the ID-first flow below.
    if (Test-OdFirstSpec -Spec $Spec) {
        $odGroups = Get-OdGroups -Rows $rows
        while ($true) {
            Write-Host ""
            Write-Host "  Select OD (removable bushing = the drilled hole diameter):" -ForegroundColor Cyan
            for ($i = 0; $i -lt $odGroups.Count; $i++) {
                $og = $odGroups[$i]
                Write-Host ("    {0,3}) OD {1,-7}   (-> hole {2:0.###}`")" -f ($i + 1), $og.ODLabel, $og.OD) -ForegroundColor White
            }
            $customIdx = $odGroups.Count + 1
            Write-Host ("    {0,3}) Custom hole OD... (type any diameter)" -f $customIdx) -ForegroundColor Yellow
            Write-Host ""
            $odPick = $null
            while ($true) {
                $raw = Read-Host "  Pick OD (1-$customIdx, or Q to skip)"
                if ($raw -match '^[Qq]$') { return $null }
                $n = 0
                if ([int]::TryParse($raw, [ref]$n) -and $n -eq $customIdx) {
                    $cpick = Invoke-CustomOdPick
                    if ($null -ne $cpick) { return $cpick }
                    break   # custom cancelled -> re-show the OD menu
                }
                if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $odGroups.Count) { $odPick = $odGroups[$n - 1]; break }
                Write-Host "  Enter a number between 1 and $customIdx." -ForegroundColor Yellow
            }
            if ($null -eq $odPick) { continue }   # custom was cancelled; re-show the OD menu
            $backToOd = $false
            while (-not $backToOd) {
                $lenOpt = Get-BushingLengthOptions -Id $odPick.OD   # recommend length from the OD value
                $opts   = @($lenOpt.Options)
                $preIdx = [int]$lenOpt.PreselectIndex
                Write-Host ""
                Write-Host ("  Select length (OD {0}):" -f $odPick.ODLabel) -ForegroundColor Cyan
                for ($i = 0; $i -lt $opts.Count; $i++) {
                    $o = $opts[$i]
                    $tag = if ($i -eq $preIdx) { "   <- recommended for OD $($odPick.ODLabel)" } elseif ($o.IsCustom) { "   (type any length)" } else { '' }
                    $lbl = if ($o.IsCustom) { 'Custom' } else { ("{0}`" Lg" -f $o.Label) }
                    Write-Host ("    {0,3}) {1,-10}{2}" -f ($i + 1), $lbl, $tag) -ForegroundColor White
                }
                $recNote = if ($preIdx -ge 0) { "ENTER = recommended ($($opts[$preIdx].Label)`"), " } else { '' }
                Write-Host ""
                $chosenLen = $null; $chosenLabel = $null
                while ($true) {
                    $raw = Read-Host "  Pick length (1-$($opts.Count), ${recNote}B to change OD, or Q to skip)"
                    if ($raw -match '^[Qq]$') { return $null }
                    if ($raw -match '^[Bb]$') { $backToOd = $true; break }
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
                if ($backToOd) { break }
                if ($null -eq $chosenLen) { continue }
                Write-Host ("  Hole diameter = {0:0.###}`" (OD {1}); length = {2}`" (ID unspecified)." -f $odPick.OD, $odPick.ODLabel, $chosenLabel) -ForegroundColor Green
                return (Resolve-OdBushingPick -OdGroup $odPick -Length $chosenLen -LenLabel $chosenLabel)
            }
        }
    }

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
        $customIdx = $byId.Count + 1
        Write-Host ("    {0,3}) Custom hole OD... (type any diameter)" -f $customIdx) -ForegroundColor Yellow
        Write-Host ""

        $idPick = $null
        while ($true) {
            $raw = Read-Host "  Pick ID (1-$customIdx, or Q to skip)"
            if ($raw -match '^[Qq]$') { return $null }
            $n = 0
            if ([int]::TryParse($raw, [ref]$n) -and $n -eq $customIdx) {
                $cpick = Invoke-CustomOdPick
                if ($null -ne $cpick) { return $cpick }
                break   # custom cancelled -> re-show the ID menu
            }
            if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $byId.Count) {
                $idPick = $byId[$n - 1]; break
            }
            Write-Host "  Enter a number between 1 and $customIdx." -ForegroundColor Yellow
        }
        if ($null -eq $idPick) { continue }   # custom was cancelled; re-show the ID menu
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
            if ($backToId) { break }
            if ($null -eq $chosenLen) { continue }

            # --- stage 3: OD - AUTO-RESOLVED when unique, tie-breaker only when not ---
            if (@($odOptions).Count -eq 1) {
                $odPick = $odOptions[0]
                Write-Host ("  Hole diameter = {0:0.###}`" (the only OD for ID {1}); length = {2}`"." -f $odPick.OD, $idPick.IDLabel, $chosenLabel) -ForegroundColor Green
                return (Resolve-BushingPickRow -IdGroup $idPick -OdOption $odPick -Length $chosenLen -LenLabel $chosenLabel)
            }
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
                if ($raw -match '^[Bb]$') { break }
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
