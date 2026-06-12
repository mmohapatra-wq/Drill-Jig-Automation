# ============================================================================
# lib\tests\run_response_tests.ps1 - offline tests for the response-convergence
# harness (lib\response_eval.ps1). No network. Builds a throwaway git repo in
# TEMP so the diff/grep paths exercise real git + Select-String, then drives the
# deterministic floor, the blind-prompt shaping, and the gating logic with a
# stubbed semantic verdict (the LLM call itself is covered live elsewhere).
#
# Run: powershell -ExecutionPolicy Bypass -File lib\tests\run_response_tests.ps1
# ============================================================================
$ErrorActionPreference = "Stop"
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here
. (Join-Path $libDir 'blind_evaluator.ps1')
. (Join-Path $libDir 'response_eval.ps1')

$script:pass = 0; $script:fail = 0
function Assert-True { param([string]$Name,[bool]$Cond,[string]$Detail="")
    if ($Cond) { Write-Host "  [PASS] $Name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  [FAIL] $Name $Detail" -ForegroundColor Red; $script:fail++ } }

Write-Host ""
Write-Host "  Running response-convergence tests (offline)..." -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# Build a throwaway git repo: one committed file, then an uncommitted edit that
# adds a function + a deletion, plus a new untracked file. This is the "diff" a
# turn would produce.
# ---------------------------------------------------------------------------
$repo = Join-Path $env:TEMP ("resp_eval_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $repo | Out-Null
$savedLoc = Get-Location
$gitOk = $true
# git writes informational lines to stderr (e.g. the LF->CRLF warning on Windows).
# Under $ErrorActionPreference='Stop' a redirected native stderr line is wrapped as
# a terminating error, which would (wrongly) flip $gitOk. So drop to 'Continue' for
# the git fixture calls, disable autocrlf to silence that specific warning, and let
# the && chaining run plainly. (This is the exact native-stderr gotcha the harness
# itself avoids by NOT redirecting git stderr to $null in Get-ResponseSlice.)
$savedEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    Set-Location $repo
    & git init -q | Out-Null
    & git config core.autocrlf false | Out-Null
    & git config user.email "t@t" | Out-Null; & git config user.name "t" | Out-Null
    Set-Content -Path (Join-Path $repo 'mod.ps1') -Encoding UTF8 -Value @"
function Existing-Thing { 'keep' }
function Doomed-Thing { 'remove me' }
"@
    & git add -A | Out-Null; & git commit -qm base | Out-Null

    # the turn's edit: add Test-NewThing, delete Doomed-Thing
    Set-Content -Path (Join-Path $repo 'mod.ps1') -Encoding UTF8 -Value @"
function Existing-Thing { 'keep' }
function Test-NewThing { 'added this turn' }
"@
    # an untracked new file (an unclaimed change the judge should flag)
    Set-Content -Path (Join-Path $repo 'surprise.ps1') -Encoding UTF8 -Value "function Sneaky { 1 }"
} catch { $gitOk = $false } finally { Set-Location $savedLoc; $ErrorActionPreference = $savedEAP }

Assert-True "git fixture repo created" ($gitOk -and (Test-Path (Join-Path $repo '.git')))

# ---------------------------------------------------------------------------
# Test-SymbolClaim - the deterministic "did the edit actually land" check
# ---------------------------------------------------------------------------
Write-Host "  -- Test-SymbolClaim --" -ForegroundColor White
$r = Test-SymbolClaim -RepoRoot $repo -Pattern "function Test-NewThing" -Min 1 -In "mod.ps1"
Assert-True "claimed-added symbol is found in the named file" ($r.Ok -and $r.Count -ge 1)

$r = Test-SymbolClaim -RepoRoot $repo -Pattern "function Never-Added" -Min 1 -In "mod.ps1"
Assert-True "a symbol that was NOT added fails the check" (-not $r.Ok -and $r.Count -eq 0)

$r = Test-SymbolClaim -RepoRoot $repo -Pattern "function Doomed-Thing" -Min 1 -In "mod.ps1"
Assert-True "a deleted symbol is correctly absent" (-not $r.Ok)

# repo-wide search (no -In): Sneaky exists in the untracked file
$r = Test-SymbolClaim -RepoRoot $repo -Pattern "function Sneaky" -Min 1
Assert-True "repo-wide symbol search finds untracked-file content" ($r.Ok)

# min-count: claim "updated all 2 sites" but only 1 exists -> fail
$r = Test-SymbolClaim -RepoRoot $repo -Pattern "function Existing-Thing" -Min 2 -In "mod.ps1"
Assert-True "min-count gate fails when fewer occurrences than claimed" (-not $r.Ok -and $r.Count -eq 1)

# ---------------------------------------------------------------------------
# Get-ResponseSlice - real git diff + cmd capture
# ---------------------------------------------------------------------------
Write-Host "  -- Get-ResponseSlice --" -ForegroundColor White
$claims = @(
    [pscustomobject]@{ id="c1"; text="added Test-NewThing"; check=[pscustomobject]@{ kind="symbol"; pattern="function Test-NewThing"; min=1; in="mod.ps1" } },
    [pscustomobject]@{ id="c2"; text="echo runs clean";      check=[pscustomobject]@{ kind="cmd"; run="echo hi"; expectExit=0 } }
)
$slice = Get-ResponseSlice -RepoRoot $repo -BaseRef "" -Claims $claims
Assert-True "slice diff shows the added function"  ($slice.diff -match "Test-NewThing")
Assert-True "slice diff shows the deletion"        ($slice.diff -match "Doomed-Thing")
Assert-True "slice diff lists the untracked file"  ($slice.diff -match "surprise\.ps1")
Assert-True "slice ran the cmd check and captured exit 0" (@($slice.cmdResults | Where-Object { $_.id -eq 'c2' -and $_.exit -eq 0 }).Count -eq 1)

# ---------------------------------------------------------------------------
# Test-DeterministicFloor - the gate for mechanical claims
# ---------------------------------------------------------------------------
Write-Host "  -- Test-DeterministicFloor --" -ForegroundColor White
$floor = Test-DeterministicFloor -RepoRoot $repo -Claims $claims -Slice $slice
Assert-True "floor passes when symbol present + cmd exit matches" ($floor.AllPassed)

# now a claim that lies: says it added something it didn't
$claimsBad = @(
    [pscustomobject]@{ id="c1"; text="added Phantom"; check=[pscustomobject]@{ kind="symbol"; pattern="function Phantom"; min=1; in="mod.ps1" } }
)
$sliceBad = Get-ResponseSlice -RepoRoot $repo -BaseRef "" -Claims $claimsBad
$floorBad = Test-DeterministicFloor -RepoRoot $repo -Claims $claimsBad -Slice $sliceBad
Assert-True "floor FAILS a false 'I added X' claim" (-not $floorBad.AllPassed)

# a cmd claim with the wrong expected exit
$claimsExit = @(
    [pscustomobject]@{ id="c1"; text="this fails"; check=[pscustomobject]@{ kind="cmd"; run="exit 3"; expectExit=0 } }
)
$sliceExit = Get-ResponseSlice -RepoRoot $repo -BaseRef "" -Claims $claimsExit
$floorExit = Test-DeterministicFloor -RepoRoot $repo -Claims $claimsExit -Slice $sliceExit
Assert-True "floor FAILS when a cmd exits non-zero vs expectExit" (-not $floorExit.AllPassed)

# ---------------------------------------------------------------------------
# Blind prompt shaping: judge sees the diff, NOT agent prose
# ---------------------------------------------------------------------------
Write-Host "  -- Get-ResponseJudgeMessages (blind) --" -ForegroundColor White
$sem = @([pscustomobject]@{ id="s1"; text="the abstraction is honest" })
$msgs = Get-ResponseJudgeMessages -SemanticClaims $sem -Slice $slice
$sys = ($msgs | Where-Object { $_.role -eq 'system' }).content
$usr = ($msgs | Where-Object { $_.role -eq 'user' }).content
Assert-True "system prompt declares the judge BLIND" ($sys -match "BLIND")
Assert-True "system prompt asks for unclaimed-change detection" ($sys -match "unclaimed")
Assert-True "system prompt refuses to assume good intent" ($sys -match "do not assume good intent")
Assert-True "user payload carries the diff" ($usr -match "Test-NewThing")
Assert-True "user payload carries the semantic claim" ($usr -match "the abstraction is honest")
$schema = Get-ResponseJudgeSchema
Assert-True "schema requires unclaimedChanges" (@($schema.json_schema.schema.required) -contains "unclaimedChanges")

# ---------------------------------------------------------------------------
# Invoke-ResponseConverge gating - stub the judge by passing a null config and
# checking the deterministic floor still gates; then a strict-unclaimed path.
# (Live LLM behavior is exercised by the separate live check, not here.)
# ---------------------------------------------------------------------------
Write-Host "  -- Invoke-ResponseConverge gating --" -ForegroundColor White

# Write a real packet file (the function reads from disk).
$pktGood = Join-Path $repo 'pkt_good.json'
@{ baseRef=""; claims=@(
    @{ id="c1"; text="added Test-NewThing"; check=@{ kind="symbol"; pattern="function Test-NewThing"; min=1; in="mod.ps1" } },
    @{ id="c2"; text="echo ok"; check=@{ kind="cmd"; run="echo hi"; expectExit=0 } },
    @{ id="c3"; text="holeinator drills clean in Creo"; check=@{ kind="creo" } }
) } | ConvertTo-Json -Depth 8 | Set-Content -Path $pktGood -Encoding UTF8

# Config null -> semantic judge unavailable (warning, not a gate failure). Floor
# is all-pass and there are no semantic refutes, so it converges.
$res = Invoke-ResponseConverge -RepoRoot $repo -PacketPath $pktGood -Config $null
Assert-True "converges when floor passes and judge is unavailable" ($res.Passed)
Assert-True "creo claim is surfaced as UNVERIFIED, not green" (@($res.Unverified).Count -eq 1)
Assert-True "creo claim never appears in refutations" (@($res.Refutations | Where-Object { $_ -match 'holeinator' }).Count -eq 0)

# A lying packet: floor fails -> NOT converged regardless of judge.
$pktBad = Join-Path $repo 'pkt_bad.json'
@{ baseRef=""; claims=@(
    @{ id="c1"; text="added Phantom"; check=@{ kind="symbol"; pattern="function Phantom"; min=1; in="mod.ps1" } }
) } | ConvertTo-Json -Depth 8 | Set-Content -Path $pktBad -Encoding UTF8
$resBad = Invoke-ResponseConverge -RepoRoot $repo -PacketPath $pktBad -Config $null
Assert-True "does NOT converge when a deterministic claim is false" (-not $resBad.Passed)
Assert-True "the false claim appears as a refutation" (@($resBad.Refutations | Where-Object { $_ -match 'Phantom' }).Count -ge 1)

# ---------------------------------------------------------------------------
# Show-ResponseVerdict returns the Passed bool
# ---------------------------------------------------------------------------
Write-Host "  -- Show-ResponseVerdict --" -ForegroundColor White
Assert-True "verdict render returns true on converged"     (Show-ResponseVerdict -Result $res)
Assert-True "verdict render returns false on not-converged" (-not (Show-ResponseVerdict -Result $resBad))

# ---------------------------------------------------------------------------
# cleanup
# ---------------------------------------------------------------------------
Remove-Item $repo -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host ("  ============================================") -ForegroundColor Cyan
Write-Host ("  RESULTS: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { "Green" } else { "Red" })
Write-Host ("  ============================================") -ForegroundColor Cyan
Write-Host ""
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
