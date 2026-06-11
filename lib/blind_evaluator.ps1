# ============================================================================
# lib\blind_evaluator.ps1 - blind-evaluator convergence layer
# ============================================================================
# Adapts mlogsdon's "Proposed Regression Test Development with Agentic Workflow"
# (the PLC blind-evaluator) to the Creo toolkit. The transferable idea:
#
#   derive a CLAIM cheaply (the tool says what it did), then CONVERGE by checking
#   it against a narrowly-SLICED ground truth with a JUDGE that never saw HOW the
#   claim was produced - so it can catch a bad generalization the tool made.
#
# Here the "sliced L5X" becomes a "geometry slice": only the in-scope measured
# truth (EvalOutline extents, cylinder counts, re-read dim values) - and crucially
# NONE of the mapkeys / heuristics / axis assumptions that produced the claim.
# That omission is what makes the judge BLIND and therefore trustworthy: it
# re-derives the verdict from geometry alone.
#
# Transport (verified live 2026-06-11 on this machine): BlueGPT is LiteLLM-fronted
# and OpenAI-compatible. POST {base}/v1/chat/completions with a Bearer token; the
# gateway honors response_format=json_schema (strict). Defaults reuse the env vars
# Claude Code already sets - ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN - so no new
# secret is needed; a gitignored .bluegpt_judge.json can override.
#
# Dot-source after creo_geometry.ps1:
#     . (Join-Path $ScriptDir 'lib\blind_evaluator.ps1')
# ============================================================================

# ----------------------------------------------------------------------------
# New-EvalClaim - structure what a tool ASSERTS it did. $Claims is an array of
# short, individually-checkable statements (one verdict each). Keep them atomic:
# "the box width is 4.0" beats "the box is 4x3x2" so the judge can confirm/refute
# each independently and name exactly which one failed.
# ----------------------------------------------------------------------------
function New-EvalClaim {
    param(
        [string]$Tool,
        [string]$Operation,
        [string[]]$Claims
    )
    return [pscustomobject]@{
        tool      = $Tool
        operation = $Operation
        claims    = @($Claims)
    }
}

# ----------------------------------------------------------------------------
# Get-GeometrySlice - assemble ONLY the in-scope ground truth. The caller has
# already measured the geometry (Measure-Extents, Count-Cylinders, Read-DimValue
# - all from creo_geometry.ps1); this function just shapes it into a labeled
# hashtable for the packet.
#
# DESIGN RULE (the whole point): a slice must contain measured geometry and
# nothing about HOW it was produced - no mapkey strings, no heuristic thresholds,
# no "the tool assumed X maps to Y". Pass measured facts only. The unit tests
# assert no mapkey text leaks into a slice.
# ----------------------------------------------------------------------------
function Get-GeometrySlice {
    param(
        [string]$Model,
        [hashtable]$Truth      # e.g. @{ measured_extents_sorted_desc = @(4.0009,3.0,2.0); offsets = @{ Side=4.0; Top=3.0; Front=2.0 } }
    )
    return [pscustomobject]@{
        model = $Model
        truth = $Truth
    }
}

# ----------------------------------------------------------------------------
# Write-EvalPacket - the durable live-capture artifact (repo convention:
# gauginator CSV, datinator _datums.csv, jiginator last_jig_spec.json). A packet
# is fully self-contained: { tool, operation, when, model, claim[], slice } - so
# it can be judged now over REST, or later offline (by Claude, or a re-run).
# Returns the path written.
#
# $WhenIso is passed in (the hybrid scripts have a real clock); defaulting to a
# fixed sentinel keeps this callable from a host where Get-Date is unavailable.
# ----------------------------------------------------------------------------
function Write-EvalPacket {
    param(
        [string]$Path,
        $Claim,                 # from New-EvalClaim
        $Slice,                 # from Get-GeometrySlice
        [string]$WhenIso = ""
    )
    $packet = [pscustomobject]@{
        tool      = $Claim.tool
        operation = $Claim.operation
        when      = $WhenIso
        model     = $Slice.model
        claims    = @($Claim.claims)
        slice     = $Slice.truth
    }
    $json = $packet | ConvertTo-Json -Depth 12
    Set-Content -Path $Path -Value $json -Encoding UTF8
    return $Path
}

# ----------------------------------------------------------------------------
# Get-JudgeConfig - resolve { base, token, model } for the REST judge.
# Precedence:
#   1. .bluegpt_judge.json at $RepoRoot (gitignored) - { base, token, model }
#   2. env: ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN (what Claude Code uses here)
#   3. env: BLUEGPT_API_BASE + BLUEGPT_API_KEY (explicit override names)
# Returns $null if no usable base+token is found - the caller then writes the
# packet and skips the REST call (offline-judge path) instead of failing.
# ----------------------------------------------------------------------------
function Get-JudgeConfig {
    param([string]$RepoRoot = ".", [string]$DefaultModel = "sonnet")

    # 1. repo-root config file
    $cfgPath = Join-Path $RepoRoot ".bluegpt_judge.json"
    if (Test-Path $cfgPath) {
        try {
            $c = Get-Content $cfgPath -Raw | ConvertFrom-Json
            $base  = if ($c.base)  { [string]$c.base }  else { $env:ANTHROPIC_BASE_URL }
            $token = if ($c.token) { [string]$c.token } else { $env:ANTHROPIC_AUTH_TOKEN }
            $model = if ($c.model) { [string]$c.model } else { $DefaultModel }
            if (-not [string]::IsNullOrWhiteSpace($base) -and -not [string]::IsNullOrWhiteSpace($token)) {
                return [pscustomobject]@{ base = $base.TrimEnd('/'); token = $token; model = $model }
            }
        } catch {}
    }

    # 2. ANTHROPIC_* (already present for Claude Code on this machine)
    $base  = $env:ANTHROPIC_BASE_URL
    $token = $env:ANTHROPIC_AUTH_TOKEN
    # 3. explicit BLUEGPT_* override
    if ([string]::IsNullOrWhiteSpace($base))  { $base  = $env:BLUEGPT_API_BASE }
    if ([string]::IsNullOrWhiteSpace($token)) { $token = $env:BLUEGPT_API_KEY }

    if ([string]::IsNullOrWhiteSpace($base) -or [string]::IsNullOrWhiteSpace($token)) { return $null }
    return [pscustomobject]@{ base = $base.TrimEnd('/'); token = $token; model = $DefaultModel }
}

# ----------------------------------------------------------------------------
# Get-BlindJudgeMessages - build the chat messages for a packet. Factored out of
# Invoke-BlindJudge so the unit tests can assert the prompt is BLIND and the
# slice carries no mapkey provenance, without any network call.
# ----------------------------------------------------------------------------
function Get-BlindJudgeMessages {
    param($Packet)

    $system = @"
You are a BLIND geometric evaluator for a CAD automation toolkit.

You did NOT see how the result was produced - no mapkeys, no scripts, no
assumptions about which axis maps to which dimension. You are given ONLY:
  (1) a list of CLAIMS the tool asserts about what it built or measured, and
  (2) a SLICE of measured ground truth from the finished CAD model.

Your job: for EACH claim, decide from the SLICE ALONE whether the geometry
confirms it, refutes it, or is uncertain. A claim that maps a named dimension
(e.g. "width") to a value is CONFIRMED if some measured extent matches that
value within a sensible tolerance (~1e-3 relative, or 0.1 absolute on inch-scale
parts); REFUTED if no measured value matches; UNCERTAIN if the slice lacks the
data to decide. Do not assume an axis order - match by VALUE.

Flag any "bad generalization": a claim that sounds plausible but the measured
geometry does not actually support. Be skeptical; default to refute/uncertain
when the slice does not clearly back the claim.
"@

    $userObj = [pscustomobject]@{
        tool      = $Packet.tool
        operation = $Packet.operation
        model     = $Packet.model
        claims    = @($Packet.claims)
        slice     = $Packet.slice
    }
    $user = "Evaluate these claims against the measured slice. Respond in the required JSON schema.`n`n" +
            ($userObj | ConvertTo-Json -Depth 12)

    return @(
        @{ role = "system"; content = $system },
        @{ role = "user";   content = $user }
    )
}

# The strict JSON schema the judge must return. perClaim is index-aligned to the
# packet's claims[]; overall is the rolled-up verdict; summary is one sentence.
function Get-BlindJudgeSchema {
    return @{
        type   = "json_schema"
        json_schema = @{
            name   = "convergence_verdict"
            strict = $true
            schema = @{
                type                 = "object"
                additionalProperties = $false
                properties = @{
                    perClaim = @{
                        type  = "array"
                        items = @{
                            type                 = "object"
                            additionalProperties = $false
                            properties = @{
                                claim   = @{ type = "string" }
                                verdict = @{ type = "string"; enum = @("confirm","refute","uncertain") }
                                reason  = @{ type = "string" }
                            }
                            required = @("claim","verdict","reason")
                        }
                    }
                    overall = @{ type = "string"; enum = @("confirm","refute","uncertain") }
                    summary = @{ type = "string" }
                }
                required = @("perClaim","overall","summary")
            }
        }
    }
}

# ----------------------------------------------------------------------------
# Invoke-BlindJudge - POST the packet to the OpenAI-compatible gateway and return
# the parsed verdict object { perClaim[], overall, summary }, or a structured
# error object { error = <msg> } so the caller can degrade gracefully (the packet
# is already on disk for offline judging). Never throws.
# ----------------------------------------------------------------------------
function Invoke-BlindJudge {
    param(
        $Packet,
        $Config,                       # from Get-JudgeConfig
        [int]$MaxTokens = 1200,
        [int]$TimeoutSec = 60
    )
    if ($null -eq $Config) {
        return [pscustomobject]@{ error = "no judge config (set ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN or .bluegpt_judge.json); packet written for offline judging" }
    }

    $body = @{
        model           = $Config.model
        max_tokens      = $MaxTokens
        messages        = Get-BlindJudgeMessages -Packet $Packet
        response_format = Get-BlindJudgeSchema
    } | ConvertTo-Json -Depth 20

    $headers = @{ "Authorization" = "Bearer $($Config.token)"; "Content-Type" = "application/json" }
    $uri = "$($Config.base)/v1/chat/completions"

    try {
        $resp = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -TimeoutSec $TimeoutSec
    } catch {
        return [pscustomobject]@{ error = "judge request failed: $($_.Exception.Message)" }
    }

    $content = $null
    try { $content = $resp.choices[0].message.content } catch {}
    if ([string]::IsNullOrWhiteSpace($content)) {
        return [pscustomobject]@{ error = "judge returned no content" }
    }
    try {
        return ($content | ConvertFrom-Json)
    } catch {
        return [pscustomobject]@{ error = "judge returned non-JSON content"; raw = $content }
    }
}

# ----------------------------------------------------------------------------
# Show-ConvergenceReport - render the convergence result and return the bool the
# caller uses to gate its final "Done".
#
# TWO GATING MODES, by design (see Test-ExtentsMatch for the why):
#   * -Numeric supplied (a Test-ExtentsMatch result): the DETERMINISTIC arithmetic
#     is the gate. Same geometry -> same gate, every run. The LLM verdict is shown
#     as ADVISORY (semantic flags + narration); if the LLM disagrees with the
#     deterministic result that disagreement is surfaced loudly - it is a real
#     signal worth a human's eye - but it does NOT flip the gate.
#   * -Numeric omitted: there is no number to check (a purely-semantic claim, e.g.
#     "is this edge really a node-to-stiffener fillet?"). Then the LLM verdict IS
#     the gate, exactly as before.
#
# An LLM error/uncertain returns $false (honest: not independently confirmed) in
# LLM-gated mode. In numeric-gated mode an LLM error does NOT fail the gate - the
# arithmetic already decided - but it is reported.
# ----------------------------------------------------------------------------
function Show-ConvergenceReport {
    param($Verdict, [string]$Title = "Blind evaluator", $Numeric = $null)

    Write-Host ""
    Write-Host "  === $Title ===" -ForegroundColor Cyan

    # --- deterministic numeric layer (the gate, when present) ----------------
    $numericGate = $null
    if ($null -ne $Numeric) {
        $numericGate = [bool]$Numeric.AllMatched
        Write-Host "  Deterministic measurement (gate):" -ForegroundColor White
        foreach ($p in @($Numeric.Pairs)) {
            $col  = if ($p.Ok) { "Green" } else { "Red" }
            $mark = if ($p.Ok) { "[OK]  " } else { "[X]   " }
            $meas = if ($null -eq $p.Matched) { "no measured extent within tol" } else { ("measured {0:0.####}" -f $p.Matched) }
            Write-Host ("    {0}expected {1:0.####}  ->  {2}" -f $mark, $p.Expected, $meas) -ForegroundColor $col
        }
        $gColor = if ($numericGate) { "Green" } else { "Red" }
        Write-Host ("    => geometry {0} the claimed values (tol {1})" -f ($(if ($numericGate) {"MATCHES"} else {"does NOT match"})), $Numeric.Tol) -ForegroundColor $gColor
        Write-Host ""
    }

    # --- LLM layer (advisory when numeric present; the gate otherwise) -------
    $llmConfirm = $null
    if ($null -eq $Verdict) {
        Write-Host "  Judge: no verdict (null)." -ForegroundColor Yellow
    }
    elseif ($Verdict.PSObject.Properties.Name -contains "error") {
        Write-Host "  Judge unavailable: $($Verdict.error)" -ForegroundColor Yellow
        if ($null -eq $numericGate) {
            Write-Host "  (Eval packet was written; it can be judged offline later.)" -ForegroundColor DarkGray
        }
    }
    else {
        $hdr = if ($null -ne $numericGate) { "Judge (advisory - semantics & summary):" } else { "Judge:" }
        Write-Host "  $hdr" -ForegroundColor White
        foreach ($c in @($Verdict.perClaim)) {
            $color = switch ($c.verdict) { "confirm" {"Green"} "refute" {"Red"} default {"Yellow"} }
            $mark  = switch ($c.verdict) { "confirm" {"[OK]  "} "refute" {"[X]   "} default {"[?]   "} }
            Write-Host ("    {0}{1}" -f $mark, $c.claim) -ForegroundColor $color
            Write-Host ("          -> {0}" -f $c.reason) -ForegroundColor DarkGray
        }
        $oColor = switch ($Verdict.overall) { "confirm" {"Green"} "refute" {"Red"} default {"Yellow"} }
        Write-Host ("    Overall: {0}" -f $Verdict.overall.ToUpper()) -ForegroundColor $oColor
        if ($Verdict.summary) { Write-Host ("    {0}" -f $Verdict.summary) -ForegroundColor White }
        $llmConfirm = ($Verdict.overall -eq "confirm")
    }

    # --- decide the gate + flag any deterministic/LLM disagreement -----------
    Write-Host ""
    if ($null -ne $numericGate) {
        # The numeric result is authoritative. Surface a divergence as a signal.
        if ($null -ne $llmConfirm -and $llmConfirm -ne $numericGate) {
            Write-Host ("  NOTE: judge ({0}) disagrees with the measurement ({1}). Measurement wins the gate;" -f `
                ($(if ($llmConfirm) {"confirm"} else {"not-confirm"})), ($(if ($numericGate) {"match"} else {"mismatch"}))) -ForegroundColor Magenta
            Write-Host "  worth a look - the claim wording or the slice may be misleading the judge." -ForegroundColor Magenta
        }
        return $numericGate
    }
    # No numeric layer: the LLM is the gate.
    return ([bool]$llmConfirm)
}

# ----------------------------------------------------------------------------
# Invoke-JudgeProbe - endpoint/auth discovery. Sends a synthetic packet with a
# known-true and a known-false claim and prints the round-trip result, so the
# REST transport + auth can be validated in isolation before any tool relies on
# it. Returns $true if the gateway answered with a parseable verdict.
# ----------------------------------------------------------------------------
function Invoke-JudgeProbe {
    param([string]$RepoRoot = ".", [string]$Model = "sonnet")

    Write-Host ""
    Write-Host "  [JUDGE PROBE] resolving config..." -ForegroundColor Magenta
    $cfg = Get-JudgeConfig -RepoRoot $RepoRoot -DefaultModel $Model
    if ($null -eq $cfg) {
        Write-Host "  No judge config found. Set ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN," -ForegroundColor Yellow
        Write-Host "  or BLUEGPT_API_BASE + BLUEGPT_API_KEY, or create .bluegpt_judge.json." -ForegroundColor Yellow
        return $false
    }
    Write-Host ("  base  = {0}" -f $cfg.base) -ForegroundColor Magenta
    Write-Host ("  model = {0}" -f $cfg.model) -ForegroundColor Magenta
    Write-Host ("  token = <{0} chars>" -f $cfg.token.Length) -ForegroundColor Magenta

    $claim  = New-EvalClaim -Tool "probe" -Operation "self-test" -Claims @(
        "the box width is 4.0",
        "the box height is 9.9"
    )
    $slice  = Get-GeometrySlice -Model "probe.prt" -Truth @{
        measured_extents_sorted_desc = @(4.0009, 3.0001, 2.0)
    }
    $packet = [pscustomobject]@{
        tool = $claim.tool; operation = $claim.operation; when = ""; model = $slice.model
        claims = @($claim.claims); slice = $slice.truth
    }

    Write-Host "  Sending synthetic packet (expect: width confirm, height refute)..." -ForegroundColor Magenta
    $verdict = Invoke-BlindJudge -Packet $packet -Config $cfg
    $ok = Show-ConvergenceReport -Verdict $verdict -Title "Judge probe"
    Write-Host ""
    if ($verdict.PSObject.Properties.Name -contains "error") {
        Write-Host "  [JUDGE PROBE] FAILED - see message above." -ForegroundColor Red
        return $false
    }
    Write-Host "  [JUDGE PROBE] round-trip OK - the gateway is reachable and returns verdicts." -ForegroundColor Green
    return $true
}
