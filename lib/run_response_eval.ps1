# ============================================================================
# lib\run_response_eval.ps1 - CLI runner for the response-convergence harness
# ============================================================================
# Thin wrapper the Stop hook (or a human, or Claude) invokes:
#   powershell -ExecutionPolicy Bypass -File lib\run_response_eval.ps1 `
#       -PacketPath <turn_claims.json> [-RepoRoot .] [-StrictUnclaimed]
#
# Exit codes (the hook contract depends on these):
#   0  = CONVERGED        (deterministic floor passed, no semantic refute)
#   1  = NOT CONVERGED    (refutations exist; the hook feeds them back to revise)
#   2  = HARNESS ERROR    (missing packet, bad JSON, etc.) -> FAIL OPEN upstream:
#                          a broken verifier must never block a turn. The hook
#                          treats exit 2 as "let the turn end" + prints why.
#
# FAIL-OPEN is deliberate and load-bearing: a self-verifier that can hang or
# wedge the session is worse than no verifier. Any internal throw is caught and
# turned into exit 2, never an unhandled error that stalls the hook.
# ============================================================================
param(
    [Parameter(Mandatory = $true)][string]$PacketPath,
    [string]$RepoRoot = ".",
    [switch]$StrictUnclaimed
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

try {
    . (Join-Path $here 'blind_evaluator.ps1')   # Get-JudgeConfig + REST plumbing
    . (Join-Path $here 'response_eval.ps1')      # the convergence functions
} catch {
    Write-Host "  response-eval: could not load libraries: $($_.Exception.Message)" -ForegroundColor Yellow
    exit 2
}

if (-not (Test-Path $PacketPath)) {
    Write-Host "  response-eval: packet not found: $PacketPath (nothing to verify)" -ForegroundColor Yellow
    exit 2
}

$RepoRoot = (Resolve-Path $RepoRoot).Path

try {
    $cfg = Get-JudgeConfig -RepoRoot $RepoRoot -DefaultModel "sonnet"
    $result = Invoke-ResponseConverge -RepoRoot $RepoRoot -PacketPath $PacketPath -Config $cfg -StrictUnclaimed:$StrictUnclaimed
    $passed = Show-ResponseVerdict -Result $result -Title "Response convergence"
    if ($passed) { exit 0 } else { exit 1 }
} catch {
    Write-Host "  response-eval: harness error: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  (failing open - the turn is not blocked by a broken verifier)" -ForegroundColor DarkGray
    exit 2
}
