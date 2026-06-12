# ============================================================================
# lib\response_eval.ps1 - blind-evaluator convergence aimed at the AGENT
# ============================================================================
# The same convergence loop the Creo tools run, turned on Claude Code's own
# responses. A Creo tool fires mapkeys and CLAIMS it built something; the blind
# evaluator measures the solid and checks. An LLM coding agent fires EDITS and
# claims it did something ("tests pass", "all 3 call sites updated", "this is
# consistent") - and, until now, nothing checks. Confident producers emit
# plausible-but-wrong claims; that is exactly what a blind evaluator is for.
#
# Reuses the domain-agnostic half of blind_evaluator.ps1 (Get-JudgeConfig + the
# REST transport). The SLICE here is the raw `git diff` + command outputs - the
# evidence - and DELIBERATELY EXCLUDES the agent's prose/reasoning. The judge
# never sees the narrative, only what actually changed and what commands actually
# returned. That is what keeps it blind: it cannot be talked into a verdict.
#
# TWO GATES, same split as the geometry evaluator:
#   * DETERMINISTIC FLOOR (the gate): claimed-symbol greps + command exit codes.
#     Same evidence -> same verdict. The LLM cannot override a failed test.
#   * LLM (semantic claims + unclaimed-change detection): judges claims that
#     have no mechanical check, and flags substantive diff hunks no claim covers.
#
# HARD BOUNDARY: headless, this harness can run tests / parse / grep / git. It
# CANNOT run Creo. Any behavioral "it works in Creo" claim is emitted as
# UNVERIFIED IN CREO - never a green check. Live Creo runs remain the only judge
# of mapkey behavior (why holeinator needed a hands-on confirmation run).
#
# Dot-source after blind_evaluator.ps1:
#     . (Join-Path $ScriptDir 'lib\blind_evaluator.ps1')
#     . (Join-Path $ScriptDir 'lib\response_eval.ps1')
# Or run as a script:  powershell -File lib\response_eval.ps1 -PacketPath x.json -RepoRoot .
# ============================================================================

# ----------------------------------------------------------------------------
# Claim-packet schema (JSON the agent writes; one object):
# {
#   "turn": "<optional id>",
#   "baseRef": "<optional git ref to diff against; default: working tree vs HEAD>",
#   "claims": [
#     { "id":"c1", "text":"added Test-ExtentsMatch",
#       "check": { "kind":"symbol", "pattern":"function Test-ExtentsMatch",
#                  "min":1, "in":"lib/creo_geometry.ps1" } },
#     { "id":"c2", "text":"unit tests pass",
#       "check": { "kind":"cmd", "run":"powershell -File lib/tests/run_tests.ps1",
#                  "expectExit":0 } },
#     { "id":"c3", "text":"the gate cannot be flipped by the LLM",
#       "check": { "kind":"semantic" } },
#     { "id":"c4", "text":"holeinator drills clean holes",
#       "check": { "kind":"creo" } }
#   ]
# }
# check.kind: symbol | cmd  -> deterministic floor (must pass to gate green)
#             semantic      -> LLM-judged
#             creo          -> behavioral; always UNVERIFIED IN CREO, never green
# ----------------------------------------------------------------------------

# Gather the blind SLICE the judge will see: the raw diff + each cmd's result.
# No agent prose. $RepoRoot is where git + the commands run.
function Get-ResponseSlice {
    param([string]$RepoRoot, [string]$BaseRef, $Claims)

    # 1. the diff (what actually changed this turn)
    # IMPORTANT: do NOT do `git ... 2>$null` here. git writes informational lines
    # to stderr (e.g. the Windows LF->CRLF warning), and under the callers'
    # $ErrorActionPreference='Stop' a redirected native-stderr line is wrapped as a
    # terminating error - it would abort the whole diff read. Instead drop EAP to
    # 'Continue' for the git calls and merge stderr into the captured output (2>&1)
    # so a warning becomes harmless text, never a thrown error.
    $diff = ""
    $savedEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $RepoRoot
    try {
        if ([string]::IsNullOrWhiteSpace($BaseRef)) {
            # Working tree vs HEAD (staged + unstaged), plus untracked file names.
            $diff = (& git diff HEAD 2>&1 | Out-String)
            $untracked = (& git ls-files --others --exclude-standard 2>&1 | Out-String)
            if (-not [string]::IsNullOrWhiteSpace($untracked)) {
                $diff += "`n--- untracked (new) files ---`n" + $untracked
            }
        } else {
            $diff = (& git diff $BaseRef 2>&1 | Out-String)
        }
    } catch {} finally { Pop-Location; $ErrorActionPreference = $savedEAP }

    # 2. run each cmd check, capture exit + tail of output (this is evidence, not
    #    the gate decision yet - Test-DeterministicFloor decides pass/fail).
    $cmdResults = @()
    foreach ($c in @($Claims)) {
        if ($null -eq $c.check -or $c.check.kind -ne "cmd") { continue }
        $out = ""; $exit = $null
        Push-Location $RepoRoot
        try {
            $out  = (& cmd /c $c.check.run 2>&1 | Out-String)
            $exit = $LASTEXITCODE
        } catch { $out = "  (command threw: $($_.Exception.Message))"; $exit = -999 }
        finally { Pop-Location }
        # keep only the tail so a chatty command can't blow the judge context
        $tail = ($out -split "`n" | Select-Object -Last 40) -join "`n"
        $cmdResults += [pscustomobject]@{ id = $c.id; run = $c.check.run; exit = $exit; outputTail = $tail }
    }

    return [pscustomobject]@{ diff = $diff; cmdResults = $cmdResults }
}

# ----------------------------------------------------------------------------
# Test-SymbolClaim - DETERMINISTIC: does $Pattern appear at least $Min times in
# the repo (optionally scoped to $In)? This is the "I said I added X / updated
# all N sites - did the edit actually land?" check. Returns @{ Ok; Count; Min }.
# Uses Select-String (literal by default) so a regex-y pattern can't misfire.
# ----------------------------------------------------------------------------
function Test-SymbolClaim {
    param([string]$RepoRoot, [string]$Pattern, [int]$Min = 1, [string]$In = "")
    $count = 0
    try {
        $target = if ([string]::IsNullOrWhiteSpace($In)) { $RepoRoot } else { Join-Path $RepoRoot $In }
        if (Test-Path $target -PathType Leaf) {
            $count = @(Select-String -Path $target -Pattern $Pattern -SimpleMatch -AllMatches -ErrorAction SilentlyContinue).Count
        } elseif (Test-Path $target) {
            # directory: search common source files, skip .git and binaries
            $files = Get-ChildItem -Path $target -Recurse -File -Include *.ps1,*.cmd,*.json,*.md,*.bat -ErrorAction SilentlyContinue |
                     Where-Object { $_.FullName -notmatch '\\\.git\\' }
            if ($files) {
                $count = @(Select-String -Path $files.FullName -Pattern $Pattern -SimpleMatch -AllMatches -ErrorAction SilentlyContinue).Count
            }
        }
    } catch {}
    return [pscustomobject]@{ Ok = ($count -ge $Min); Count = $count; Min = $Min }
}

# ----------------------------------------------------------------------------
# Test-DeterministicFloor - run every symbol + cmd check and return the floor
# result. This is the GATE for mechanically-checkable claims; the LLM cannot
# override it. Returns @{ AllPassed; Results[] } where each result is
# @{ id; text; kind; ok; detail }.
# ----------------------------------------------------------------------------
function Test-DeterministicFloor {
    param([string]$RepoRoot, $Claims, $Slice)
    $results = @()
    $all = $true
    foreach ($c in @($Claims)) {
        $kind = if ($null -ne $c.check) { $c.check.kind } else { "semantic" }
        if ($kind -eq "symbol") {
            $min = if ($null -ne $c.check.min) { [int]$c.check.min } else { 1 }
            $in  = if ($null -ne $c.check.in)  { [string]$c.check.in } else { "" }
            $r = Test-SymbolClaim -RepoRoot $RepoRoot -Pattern $c.check.pattern -Min $min -In $in
            if (-not $r.Ok) { $all = $false }
            $where = if ($in) { $in } else { "repo" }
            $results += [pscustomobject]@{ id=$c.id; text=$c.text; kind="symbol"; ok=$r.Ok;
                detail=("'{0}' found {1}x in {2} (need {3})" -f $c.check.pattern, $r.Count, $where, $min) }
        }
        elseif ($kind -eq "cmd") {
            $cr = @($Slice.cmdResults | Where-Object { $_.id -eq $c.id }) | Select-Object -First 1
            $want = if ($null -ne $c.check.expectExit) { [int]$c.check.expectExit } else { 0 }
            $ok = ($null -ne $cr -and $cr.exit -eq $want)
            if (-not $ok) { $all = $false }
            $got = if ($null -ne $cr) { $cr.exit } else { "(not run)" }
            $results += [pscustomobject]@{ id=$c.id; text=$c.text; kind="cmd"; ok=$ok;
                detail=("`{0}` exit {1} (want {2})" -f $c.check.run, $got, $want) }
        }
    }
    return [pscustomobject]@{ AllPassed = $all; Results = $results }
}

# ----------------------------------------------------------------------------
# Get-ResponseJudgeMessages - blind, diff-focused prompt. Factored out so tests
# can assert it is blind and carries no agent prose.
# ----------------------------------------------------------------------------
function Get-ResponseJudgeMessages {
    param($SemanticClaims, $Slice)
    $system = @"
You are a BLIND code-change evaluator. You did NOT write this change and you have
NOT seen the author's explanation. You are given ONLY:
  (1) the raw git diff of what changed, and
  (2) the exit codes / output tails of any commands that were run.

For EACH claim below, decide from that evidence alone whether the diff and command
results CONFIRM it, REFUTE it, or leave it UNCERTAIN. Judge only what the evidence
shows - do not assume good intent, do not fill gaps with charity.

ALSO do one more thing: list any SUBSTANTIVE change visible in the diff that is not
covered by any claim (an unclaimed change - new behavior, a deletion, a changed
default that no claim mentions). Trivial reformatting does not count.

Be skeptical. Default to refute/uncertain when the evidence does not clearly back
the claim.
"@
    $payload = [pscustomobject]@{
        claims     = @($SemanticClaims | ForEach-Object { [pscustomobject]@{ id = $_.id; text = $_.text } })
        diff       = $Slice.diff
        cmdResults = $Slice.cmdResults
    }
    $user = "Evaluate these claims against the diff + command evidence. Respond in the required JSON schema.`n`n" +
            ($payload | ConvertTo-Json -Depth 12)
    return @(
        @{ role = "system"; content = $system },
        @{ role = "user";   content = $user }
    )
}

function Get-ResponseJudgeSchema {
    return @{
        type = "json_schema"
        json_schema = @{
            name = "response_verdict"; strict = $true
            schema = @{
                type = "object"; additionalProperties = $false
                properties = @{
                    perClaim = @{ type="array"; items = @{
                        type="object"; additionalProperties=$false
                        properties = @{ id=@{type="string"}; verdict=@{type="string"; enum=@("confirm","refute","uncertain")}; reason=@{type="string"} }
                        required = @("id","verdict","reason") } }
                    unclaimedChanges = @{ type="array"; items = @{ type="string" } }
                    overall = @{ type="string"; enum=@("confirm","refute","uncertain") }
                    summary = @{ type="string" }
                }
                required = @("perClaim","unclaimedChanges","overall","summary")
            }
        }
    }
}

# Call the judge for the semantic claims. Reuses blind_evaluator.ps1's REST plumbing
# pattern but with the response schema/prompt. Returns the parsed verdict or { error }.
function Invoke-ResponseJudge {
    param($SemanticClaims, $Slice, $Config, [int]$MaxTokens = 1500, [int]$TimeoutSec = 90)
    if ($null -eq $Config) { return [pscustomobject]@{ error = "no judge config; semantic claims unjudged" } }
    if (@($SemanticClaims).Count -eq 0 -and [string]::IsNullOrWhiteSpace($Slice.diff)) {
        return [pscustomobject]@{ perClaim=@(); unclaimedChanges=@(); overall="confirm"; summary="no semantic claims and no diff" }
    }
    # ConvertTo-AsciiSafeJson (from blind_evaluator.ps1), NOT ConvertTo-Json: a diff
    # carrying ± / curly quotes / box-draw chars 400s the gateway otherwise. See the
    # helper's comment for why this is required, not cosmetic.
    $body = @{
        model = $Config.model; max_tokens = $MaxTokens
        messages = Get-ResponseJudgeMessages -SemanticClaims $SemanticClaims -Slice $Slice
        response_format = Get-ResponseJudgeSchema
    } | ConvertTo-AsciiSafeJson -Depth 25
    $headers = @{ "Authorization" = "Bearer $($Config.token)"; "Content-Type" = "application/json" }
    try {
        $resp = Invoke-RestMethod -Uri "$($Config.base)/v1/chat/completions" -Method Post -Headers $headers -Body $body -TimeoutSec $TimeoutSec
    } catch { return [pscustomobject]@{ error = "judge request failed: $($_.Exception.Message)" } }
    $content = $null
    try { $content = $resp.choices[0].message.content } catch {}
    if ([string]::IsNullOrWhiteSpace($content)) { return [pscustomobject]@{ error = "judge returned no content" } }
    try { return ($content | ConvertFrom-Json) } catch { return [pscustomobject]@{ error = "judge returned non-JSON"; raw = $content } }
}

# ----------------------------------------------------------------------------
# Invoke-ResponseConverge - the whole loop for ONE turn. Returns:
#   @{ Passed; Refutations[]; Unverified[]; Warnings[]; Floor; Verdict }
# Passed is the GATE: deterministic floor all-pass AND no semantic refute. Creo
# claims never fail the gate but populate Unverified. Unclaimed changes populate
# Warnings (surfaced, not gating) unless -StrictUnclaimed.
# ----------------------------------------------------------------------------
function Invoke-ResponseConverge {
    param([string]$RepoRoot, [string]$PacketPath, $Config = $null, [switch]$StrictUnclaimed)

    $packet = Get-Content $PacketPath -Raw | ConvertFrom-Json
    $claims = @($packet.claims)
    $baseRef = if ($packet.PSObject.Properties.Name -contains "baseRef") { [string]$packet.baseRef } else { "" }

    $slice = Get-ResponseSlice -RepoRoot $RepoRoot -BaseRef $baseRef -Claims $claims
    $floor = Test-DeterministicFloor -RepoRoot $RepoRoot -Claims $claims -Slice $slice

    $refutations = @()
    $unverified  = @()
    $warnings    = @()

    foreach ($r in @($floor.Results | Where-Object { -not $_.ok })) {
        $refutations += ("[{0}] {1} -- {2}" -f $r.kind, $r.text, $r.detail)
    }
    foreach ($c in @($claims | Where-Object { $null -ne $_.check -and $_.check.kind -eq "creo" })) {
        $unverified += ("{0}  (cannot be verified headless - run it in Creo)" -f $c.text)
    }

    # Semantic layer (advisory for floor, but a refute DOES fail the gate).
    $semantic = @($claims | Where-Object { $null -eq $_.check -or $_.check.kind -eq "semantic" })
    $verdict = $null; $semanticOk = $true
    if (@($semantic).Count -gt 0 -or -not [string]::IsNullOrWhiteSpace($slice.diff)) {
        $verdict = Invoke-ResponseJudge -SemanticClaims $semantic -Slice $slice -Config $Config
        if ($verdict.PSObject.Properties.Name -contains "error") {
            $warnings += ("semantic judge unavailable: {0}" -f $verdict.error)
            # judge down: do NOT fail the gate on semantics we couldn't check
        } else {
            foreach ($pc in @($verdict.perClaim | Where-Object { $_.verdict -eq "refute" })) {
                $semanticOk = $false
                $txt = (@($semantic | Where-Object { $_.id -eq $pc.id }) | Select-Object -First 1).text
                $refutations += ("[semantic] {0} -- {1}" -f $txt, $pc.reason)
            }
            foreach ($uc in @($verdict.unclaimedChanges)) {
                if ($StrictUnclaimed) { $refutations += ("[unclaimed change] {0}" -f $uc); $semanticOk = $false }
                else { $warnings += ("unclaimed change: {0}" -f $uc) }
            }
        }
    }

    $passed = ($floor.AllPassed -and $semanticOk)
    return [pscustomobject]@{
        Passed = $passed; Refutations = $refutations; Unverified = $unverified
        Warnings = $warnings; Floor = $floor; Verdict = $verdict
    }
}

# ----------------------------------------------------------------------------
# Show-ResponseVerdict - render the convergence result; returns the Passed bool.
# ----------------------------------------------------------------------------
function Show-ResponseVerdict {
    param($Result, [string]$Title = "Response convergence")
    Write-Host ""
    Write-Host "  === $Title ===" -ForegroundColor Cyan

    Write-Host "  Deterministic floor:" -ForegroundColor White
    foreach ($r in @($Result.Floor.Results)) {
        $col = if ($r.ok) { "Green" } else { "Red" }
        $mk  = if ($r.ok) { "[OK]  " } else { "[X]   " }
        Write-Host ("    {0}{1}" -f $mk, $r.text) -ForegroundColor $col
        Write-Host ("          {0}" -f $r.detail) -ForegroundColor DarkGray
    }
    if (@($Result.Floor.Results).Count -eq 0) { Write-Host "    (no deterministic checks in this packet)" -ForegroundColor DarkGray }

    if (@($Result.Unverified).Count -gt 0) {
        Write-Host "  UNVERIFIED IN CREO (headless cannot confirm):" -ForegroundColor Yellow
        foreach ($u in $Result.Unverified) { Write-Host ("    [~]   {0}" -f $u) -ForegroundColor Yellow }
    }
    if (@($Result.Warnings).Count -gt 0) {
        Write-Host "  Warnings:" -ForegroundColor Yellow
        foreach ($w in $Result.Warnings) { Write-Host ("    [!]   {0}" -f $w) -ForegroundColor Yellow }
    }
    if (@($Result.Refutations).Count -gt 0) {
        Write-Host "  REFUTATIONS (must fix to converge):" -ForegroundColor Red
        foreach ($r in $Result.Refutations) { Write-Host ("    [X]   {0}" -f $r) -ForegroundColor Red }
    }

    if ($null -ne $Result.Verdict -and -not ($Result.Verdict.PSObject.Properties.Name -contains "error") -and $Result.Verdict.summary) {
        Write-Host ("  Judge summary: {0}" -f $Result.Verdict.summary) -ForegroundColor DarkGray
    }

    Write-Host ""
    if ($Result.Passed) {
        Write-Host "  CONVERGED - claims backed by evidence (Creo-behavioral items remain UNVERIFIED)." -ForegroundColor Green
    } else {
        Write-Host "  NOT CONVERGED - revise to address the refutations above." -ForegroundColor Red
    }
    return $Result.Passed
}

# This file is a LIBRARY (dot-source it). The CLI entry point that wires these
# functions together for a hook lives in lib\run_response_eval.ps1, which
# dot-sources this file and parses -PacketPath / -RepoRoot. Keeping the CLI
# separate lets the offline tests dot-source this file with no side effects.
