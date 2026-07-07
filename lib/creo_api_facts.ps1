# ============================================================================
# lib\creo_api_facts.ps1 - query + validate the verified VB API fact registry
# ============================================================================
# A repo-local, machine-checkable reference of Creo Parametric VB API (pfcls COM)
# facts hard-won live on this build, so tools and the convergence layer stop
# RE-DERIVING the same gotchas (the pfcRegenInstructions ProgID, the
# EvalOutline outline shape, the plane-descriptor null normal, the
# IpfcPoint.Point coordinate-read crash, ...). The data lives in
# lib\creo_api_facts.json; this file is the read/validate API over it.
#
# WHY a registry, not just CLAUDE.md prose: the facts here are STRUCTURED
# (id, category, status, antipattern, symbols, evidence) so they can be
# queried by symbol/category/status at runtime AND validated for integrity by a
# deterministic schema check that the offline test suite gates. CLAUDE.md stays
# the narrative; this is the lookup table. Each fact carries a STATUS so a tool
# never confuses "confirmed-live on the real build" with "docs-only / not
# exercised" or "refuted (an antipattern)".
#
# Dot-source like the other lib modules:
#     . (Join-Path $ScriptDir 'lib\creo_api_facts.ps1')
#     $f = Get-ApiFact -Id 'regen-instructions-progid'
#     $f.fact                      # the confirmed statement
#     Find-ApiFact -Symbol 'EvalOutline'
#     Find-ApiFact -Status refuted # everything proven to FAIL on this build
#
# No COM, no network - pure JSON read + filtering, so it loads in a plain host
# and the offline unit tests exercise every path.
# ============================================================================

# Resolve the registry path. Defaults to creo_api_facts.json sitting next to
# this file (the lib\ dir), so callers usually pass nothing.
function Get-ApiFactsPath {
    param([string]$Path = "")
    if (-not [string]::IsNullOrWhiteSpace($Path)) { return $Path }
    return (Join-Path $PSScriptRoot 'creo_api_facts.json')
}

# ----------------------------------------------------------------------------
# Get-ApiFacts - load and parse the whole registry object
# { schemaVersion, description, statusEnum[], categoryEnum[], facts[] }.
# Throws (via ConvertFrom-Json) only on unreadable/!JSON input - callers that
# want graceful degradation use Test-ApiFactsSchema first (it never throws).
# ----------------------------------------------------------------------------
function Get-ApiFacts {
    param([string]$Path = "")
    $p = Get-ApiFactsPath -Path $Path
    $raw = Get-Content -Path $p -Raw -Encoding UTF8
    return ($raw | ConvertFrom-Json)
}

# ----------------------------------------------------------------------------
# Get-ApiFact - one fact by its exact id (case-insensitive), or $null if no
# such id. The everyday lookup: "what's the confirmed ProgID / signature?".
# ----------------------------------------------------------------------------
function Get-ApiFact {
    param([Parameter(Mandatory = $true)][string]$Id, [string]$Path = "")
    $reg = Get-ApiFacts -Path $Path
    foreach ($f in @($reg.facts)) {
        if ($f.id -and ([string]$f.id) -ieq $Id) { return $f }
    }
    return $null
}

# ----------------------------------------------------------------------------
# Find-ApiFact - filter facts. All supplied filters AND together; an omitted
# filter does not constrain. Returns an array (possibly empty).
#   -Category  exact match against fact.category
#   -Status    exact match against fact.status (confirmed-live|docs-only|refuted)
#   -Symbol    fact.symbols contains this token (case-insensitive, exact token);
#              with -SymbolLike it's a substring match instead (e.g. 'Regen').
#   -Text      case-insensitive substring of fact OR antipattern OR id
# ----------------------------------------------------------------------------
function Find-ApiFact {
    param(
        [string]$Category = "",
        [string]$Status = "",
        [string]$Symbol = "",
        [switch]$SymbolLike,
        [string]$Text = "",
        [string]$Path = ""
    )
    $reg = Get-ApiFacts -Path $Path
    $out = @()
    foreach ($f in @($reg.facts)) {
        if ($Category -and -not (($f.category) -ieq $Category)) { continue }
        if ($Status   -and -not (($f.status)   -ieq $Status))   { continue }
        if ($Symbol) {
            $hit = $false
            foreach ($s in @($f.symbols)) {
                if ($null -eq $s) { continue }
                if ($SymbolLike) {
                    if (([string]$s).ToLower().Contains($Symbol.ToLower())) { $hit = $true; break }
                } else {
                    if (([string]$s) -ieq $Symbol) { $hit = $true; break }
                }
            }
            if (-not $hit) { continue }
        }
        if ($Text) {
            $blob = (@($f.id, $f.fact, $f.antipattern) -join " `n ").ToLower()
            if (-not $blob.Contains($Text.ToLower())) { continue }
        }
        $out += $f
    }
    return $out
}

# ----------------------------------------------------------------------------
# Test-ApiFactsSchema - DETERMINISTIC integrity check of the registry. This is
# the "machine-checkable" core: it never trusts the JSON, it validates it, and
# the offline suite gates on it so a malformed fact can't land. Returns
#   @{ Ok; Errors[]; Count }
# and NEVER throws (a load/parse failure becomes Ok=$false + an error string),
# so a hook or tool can call it to decide whether to trust the registry.
#
# Rules enforced:
#   * top-level has a non-empty facts[] array
#   * statusEnum / categoryEnum are present (the allowed value sets)
#   * every fact has: id, category, status, fact (all non-empty strings)
#   * id is UNIQUE across the registry (case-insensitive)
#   * category is in categoryEnum; status is in statusEnum
#   * symbols is an array (may be empty); antipattern is string-or-null
#   * a refuted fact MUST name its antipattern (a refutation with no "don't do
#     this" is uselessly vague - the whole value of a refuted entry is the trap)
# ----------------------------------------------------------------------------
function Test-ApiFactsSchema {
    param([string]$Path = "")
    $errors = @()
    $reg = $null
    try { $reg = Get-ApiFacts -Path $Path }
    catch { return [pscustomobject]@{ Ok = $false; Errors = @("could not load/parse registry: $($_.Exception.Message)"); Count = 0 } }

    if ($null -eq $reg) { return [pscustomobject]@{ Ok = $false; Errors = @("registry parsed to null"); Count = 0 } }

    $facts = @($reg.facts)
    if ($facts.Count -eq 0) { $errors += "registry has no facts[]" }

    # Allowed value sets. Fall back to the known enums if the file omits them,
    # so a registry missing the *Enum keys still gets value-checked.
    $statusEnum = if ($reg.statusEnum)   { @($reg.statusEnum) }   else { @("confirmed-live","docs-only","refuted") }
    $catEnum    = if ($reg.categoryEnum) { @($reg.categoryEnum) } else { @("progid","regen","dimension","model","geometry-read","surface","feature","selection","mapkey") }

    $seen = @{}
    foreach ($f in $facts) {
        $idLabel = if ($f.id) { [string]$f.id } else { "(missing id)" }

        foreach ($req in @("id","category","status","fact")) {
            $val = $null
            try { $val = $f.$req } catch {}
            if ([string]::IsNullOrWhiteSpace([string]$val)) { $errors += "[$idLabel] missing/empty required field '$req'" }
        }

        if ($f.id) {
            $key = ([string]$f.id).ToLower()
            if ($seen.ContainsKey($key)) { $errors += "[$idLabel] duplicate id" } else { $seen[$key] = $true }
        }

        if ($f.category -and ($catEnum -notcontains [string]$f.category)) {
            $errors += "[$idLabel] category '$($f.category)' not in categoryEnum"
        }
        if ($f.status -and ($statusEnum -notcontains [string]$f.status)) {
            $errors += "[$idLabel] status '$($f.status)' not in statusEnum"
        }

        # symbols must be an array if present (ConvertFrom-Json gives Object[]).
        if ($f.PSObject.Properties.Name -contains "symbols") {
            $isArray = ($f.symbols -is [System.Array])
            if (-not $isArray -and $null -ne $f.symbols) { $errors += "[$idLabel] 'symbols' is not an array" }
        }

        # a refuted fact must carry an antipattern (the trap is the point).
        if (($f.status -ieq "refuted") -and [string]::IsNullOrWhiteSpace([string]$f.antipattern)) {
            $errors += "[$idLabel] status 'refuted' but no antipattern named"
        }
    }

    return [pscustomobject]@{ Ok = ($errors.Count -eq 0); Errors = $errors; Count = $facts.Count }
}

# ----------------------------------------------------------------------------
# Show-ApiFact - pretty-print one fact (or an array) for a human at the console.
# Color by status: confirmed-live green, docs-only yellow, refuted red. Used by
# the --api-fact CLI affordance a tool can expose; returns nothing.
# ----------------------------------------------------------------------------
function Show-ApiFact {
    param($Fact)
    foreach ($f in @($Fact)) {
        if ($null -eq $f) { continue }
        $col = switch ([string]$f.status) { "confirmed-live" {"Green"} "refuted" {"Red"} default {"Yellow"} }
        Write-Host ("  [{0}] {1}" -f $f.status, $f.id) -ForegroundColor $col
        Write-Host ("      cat : {0}" -f $f.category) -ForegroundColor DarkGray
        Write-Host ("      fact: {0}" -f $f.fact) -ForegroundColor White
        if (-not [string]::IsNullOrWhiteSpace([string]$f.antipattern)) {
            Write-Host ("      AVOID: {0}" -f $f.antipattern) -ForegroundColor DarkYellow
        }
        if (@($f.symbols).Count -gt 0) {
            Write-Host ("      syms: {0}" -f (@($f.symbols) -join ", ")) -ForegroundColor DarkGray
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$f.evidence)) {
            Write-Host ("      src : {0}" -f $f.evidence) -ForegroundColor DarkGray
        }
        Write-Host ""
    }
}
