# ============================================================================
# lib\tests\run_edge_round_tests.ps1 - offline unit tests for lib\edge_round.ps1
# ============================================================================
# Runs WITHOUT Creo and WITHOUT network. Covers the HANDS-FREE corner-round engine
# shared by the flat drill jig (drilljig.cmd / drilljig-gui.cmd STAGE 2b) AND now the
# CURVED jig GUI (drilljig3d-gui.cmd Surface stage), via the global wrapper.
#
# PIECES UNDER TEST (the published edge_round contract - verified by reading
# lib\edge_round.ps1, not trusted from any summary):
#   * Select-LowestDimensionEdges -Edges [-Target] [-Tol] -> PURE (no COM): $Target<0
#     => AUTO (the lowest length present, rounded to 4dp); else match |len-target|<=Tol.
#     Returns @{ Target; Matches=@(...) }. This is the length-selection heart of the
#     round; a flat plate's shortest edges ARE its through-thickness verticals, and a
#     curved blank targets its thicken length explicitly.
#   * Build-EdgeRoundMacro -Radius -> PURE: the proven ProCmdRound mapkey string with
#     the radius threaded into cir_rad_list (Input + Update + Activate).
#   * Invoke-CurvedCornerRound -Session -Model -TypeObj [-Radius] [-Thickness] [-Tol]
#     [-OnPoll] -> the CURVED entry point. `function global:` (a curved-GUI step closure
#     resolves GLOBAL scope only). Forwards Thickness>0 -> -Target=Thickness (mode
#     'thickness'); Thickness<=0 -> -Target=-1 (mode 'auto'). Delegates to the plain
#     Invoke-AutoCornerRound and tags the result .Mode. We STUB Invoke-AutoCornerRound
#     to CAPTURE the -Target it receives (proving the target-forwarding) without Creo.
#
# HARD REPO RULES honored: the PURE pieces run FOR REAL (more coverage); the ONE COM
# orchestrator (Invoke-AutoCornerRound) is stubbed to capture args. Assertions are NOT
# weakened to force a pass. Modeled on run_conformal_blank_tests.ps1 (Assert-True/Approx,
# guarded dot-source, pass/fail counter, exit 0 all-pass / 1 on any failure).
#
# Run:  powershell -ExecutionPolicy Bypass -File lib\tests\run_edge_round_tests.ps1
# Exit code 0 = all passed, 1 = at least one failure.
# ============================================================================

$ErrorActionPreference = "Stop"
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here

$p = Join-Path $libDir 'edge_round.ps1'
if (Test-Path $p) { . $p } else { Write-Host "  [FAIL] edge_round.ps1 not found" -ForegroundColor Red; exit 1 }

$script:pass = 0
$script:fail = 0
function Assert-True {
    param([string]$Name, [bool]$Cond, [string]$Detail = "")
    if ($Cond) { Write-Host "  [PASS] $Name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  [FAIL] $Name $Detail" -ForegroundColor Red; $script:fail++ }
}
function Approx { param([double]$A, [double]$B, [double]$Tol = 1e-9) return [Math]::Abs($A - $B) -le $Tol }

# ----------------------------------------------------------------------------
# 1. Select-LowestDimensionEdges - PURE length selection.
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "  -- Select-LowestDimensionEdges (pure) --" -ForegroundColor White

# empty input -> no target, no matches, never throws.
$r = Select-LowestDimensionEdges -Edges @()
Assert-True "empty edges -> Target null" ($null -eq $r.Target)
Assert-True "empty edges -> 0 matches"   (@($r.Matches).Count -eq 0)

# AUTO (Target -1): picks the lowest length present and matches all within tol.
$edges = @(
    @{ Id=1; Length=0.25 }, @{ Id=2; Length=0.25 }, @{ Id=3; Length=0.25 }, @{ Id=4; Length=0.25 }
    @{ Id=5; Length=6.0 },  @{ Id=6; Length=6.0 },  @{ Id=7; Length=4.0 },  @{ Id=8; Length=4.0 }
)
$r = Select-LowestDimensionEdges -Edges $edges -Target -1 -Tol 0.01
Assert-True "AUTO picks lowest length 0.25" (Approx ([double]$r.Target) 0.25)
Assert-True "AUTO matches the 4 through-thickness edges" (@($r.Matches).Count -eq 4)
Assert-True "AUTO did NOT grab the long perimeter edges" (@($r.Matches | Where-Object { [double]$_.Length -gt 1 }).Count -eq 0)

# EXPLICIT target (the CURVED case): target the thicken length, not the lowest.
# Here the through-thickness edges are 0.5 but there are SHORTER 0.1 stray edges;
# an explicit target must grab the 0.5 group, NOT the 0.1 (auto would pick 0.1).
$edges2 = @(
    @{ Id=1; Length=0.1 },  @{ Id=2; Length=0.1 }
    @{ Id=3; Length=0.5 },  @{ Id=4; Length=0.5 }, @{ Id=5; Length=0.5 }, @{ Id=6; Length=0.5 }
    @{ Id=7; Length=7.2 },  @{ Id=8; Length=7.2 }
)
$r = Select-LowestDimensionEdges -Edges $edges2 -Target 0.5 -Tol 0.05
Assert-True "explicit target 0.5 selected (not the lower 0.1)" (Approx ([double]$r.Target) 0.5)
Assert-True "explicit target matches the 4 thicken-length edges" (@($r.Matches).Count -eq 4)
$autoWouldPick = Select-LowestDimensionEdges -Edges $edges2 -Target -1 -Tol 0.05
Assert-True "AUTO on the same set would WRONGLY pick 0.1 (why curved targets)" (Approx ([double]$autoWouldPick.Target) 0.1)

# tolerance band: a length just inside tol matches; just outside does not.
$edges3 = @( @{ Id=1; Length=0.25 }, @{ Id=2; Length=0.29 }, @{ Id=3; Length=0.36 } )
$r = Select-LowestDimensionEdges -Edges $edges3 -Target 0.25 -Tol 0.05
Assert-True "tol 0.05: 0.25 and 0.29 match, 0.36 excluded" (@($r.Matches).Count -eq 2)

# ----------------------------------------------------------------------------
# 2. Build-EdgeRoundMacro - PURE macro string.
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "  -- Build-EdgeRoundMacro (pure) --" -ForegroundColor White
$m = Build-EdgeRoundMacro -Radius 0.25
Assert-True "macro fires ProCmdRound"                 ($m -match 'ProCmdRound')
Assert-True "macro threads the radius into cir_rad_list" ($m -match 'cir_rad_list.*0\.25')
Assert-True "macro commits with dashInst0.Done"        ($m -match 'dashInst0\.Done')
$m2 = Build-EdgeRoundMacro -Radius 0.5
Assert-True "radius 0.5 threaded"                      ($m2 -match 'cir_rad_list.*0\.5')

# ----------------------------------------------------------------------------
# 3. Invoke-CurvedCornerRound - global wrapper + target forwarding.
#    STUB Invoke-AutoCornerRound to CAPTURE the -Target/-Radius/-Tol it receives.
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "  -- Invoke-CurvedCornerRound (global wrapper, target forwarding) --" -ForegroundColor White

# the wrapper MUST be global-scoped (a curved-GUI step closure resolves global only).
$cmd = Get-Command Invoke-CurvedCornerRound -ErrorAction SilentlyContinue
Assert-True "Invoke-CurvedCornerRound resolves" ($null -ne $cmd)

# capture what target the wrapper forwards. Redefine Invoke-AutoCornerRound as a
# capturing stub in THIS scope (the wrapper calls the name; PS resolves to our stub).
$script:capTarget = $null; $script:capRadius = $null; $script:capTol = $null; $script:capPolled = $false
function Invoke-AutoCornerRound {
    param($Session,$Model,$TypeObj,[double]$Radius=0.25,[double]$Target=-1,[double]$Tol=0.01,[int]$SweepMax=5000,[int]$BatchSize=40,[scriptblock]$OnPoll=$null)
    $script:capTarget = $Target; $script:capRadius = $Radius; $script:capTol = $Tol
    if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }
    return @{ Found=8; Target=$Target; Matched=4; SelfTestOk=$true; BatchesFired=1; ModelChanged=1; TotalBatches=1; Aborted=$false; Reason='stub'; Lengths=@(@{Len=0.5;Count=4}); LengthSummary='0.5x4' }
}

# thickness > 0 -> target = thickness, mode 'thickness'.
$res = Invoke-CurvedCornerRound -Session 's' -Model 'm' -TypeObj 't' -Radius 0.25 -Thickness 0.5
Assert-True "thickness 0.5 -> forwards -Target 0.5" (Approx ([double]$script:capTarget) 0.5)
Assert-True "thickness>0 -> Mode 'thickness'"       ([string]$res.Mode -eq 'thickness')
Assert-True "radius forwarded"                       (Approx ([double]$script:capRadius) 0.25)

# thickness <= 0 -> AUTO target -1, mode 'auto'.
$res = Invoke-CurvedCornerRound -Session 's' -Model 'm' -TypeObj 't' -Radius 0.25 -Thickness 0
Assert-True "thickness 0 -> forwards -Target -1 (AUTO)" (Approx ([double]$script:capTarget) -1)
Assert-True "thickness<=0 -> Mode 'auto'"               ([string]$res.Mode -eq 'auto')

# custom radius forwarded.
$res = Invoke-CurvedCornerRound -Session 's' -Model 'm' -TypeObj 't' -Radius 0.125 -Thickness 0.75
Assert-True "custom radius 0.125 forwarded" (Approx ([double]$script:capRadius) 0.125)

# OnPoll is threaded through (the GUI passes a DoEvents pump).
$script:polled = $false
$poll = { $script:polled = $true }
[void](Invoke-CurvedCornerRound -Session 's' -Model 'm' -TypeObj 't' -Radius 0.25 -Thickness 0.5 -OnPoll $poll)
Assert-True "OnPoll forwarded + invoked" ($script:polled -eq $true)

# the result shape carries the underlying orchestrator fields (chip logic reads them).
$res = Invoke-CurvedCornerRound -Session 's' -Model 'm' -TypeObj 't' -Radius 0.25 -Thickness 0.5
foreach ($k in @('Found','Target','Matched','ModelChanged','TotalBatches','Mode','LengthSummary')) {
    Assert-True "result carries .$k" ($res.ContainsKey($k))
}

# ----------------------------------------------------------------------------
# 4. AUTO-FALLBACK: when the thicken target matches NO edges but the sweep found
#    some, the wrapper re-runs with AUTO (lowest). Stub Invoke-AutoCornerRound to
#    return matched=0 for a >0 target and matched>0 for the AUTO (-1) target.
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "  -- Invoke-CurvedCornerRound AUTO fallback (target miss -> lowest) --" -ForegroundColor White
$script:calls = New-Object System.Collections.ArrayList
function Invoke-AutoCornerRound {
    param($Session,$Model,$TypeObj,[double]$Radius=0.25,[double]$Target=-1,[double]$Tol=0.01,[int]$SweepMax=5000,[int]$BatchSize=40,[scriptblock]$OnPoll=$null)
    [void]$script:calls.Add($Target)
    if ($Target -gt 0) {
        # thicken target: found edges but NONE match (the wall-vs-slab bug shape)
        return @{ Found=12; Target=$Target; Matched=0; SelfTestOk=$false; BatchesFired=0; ModelChanged=0; TotalBatches=0; Aborted=$false; Reason='no edges matched target'; LengthSummary='0.5x8, 6x4' }
    }
    # AUTO: matches the lowest (the real walls)
    return @{ Found=12; Target=0.5; Matched=8; SelfTestOk=$true; BatchesFired=1; ModelChanged=1; TotalBatches=1; Aborted=$false; Reason='rounded 8'; LengthSummary='0.5x8, 6x4' }
}
$res = Invoke-CurvedCornerRound -Session 's' -Model 'm' -TypeObj 't' -Radius 0.25 -Thickness 0.25
Assert-True "fallback: tried the thicken target 0.25 first" ($script:calls -contains 0.25)
Assert-True "fallback: then retried AUTO (-1)"              ($script:calls -contains -1)
Assert-True "fallback: adopted the AUTO result (matched 8)" ([int]$res.Matched -eq 8)
Assert-True "fallback: Mode tagged 'auto-fallback'"         ([string]$res.Mode -eq 'auto-fallback')

# NO fallback when the thicken target DID match (Matched>0): only one call, mode 'thickness'.
$script:calls = New-Object System.Collections.ArrayList
function Invoke-AutoCornerRound {
    param($Session,$Model,$TypeObj,[double]$Radius=0.25,[double]$Target=-1,[double]$Tol=0.01,[int]$SweepMax=5000,[int]$BatchSize=40,[scriptblock]$OnPoll=$null)
    [void]$script:calls.Add($Target)
    return @{ Found=12; Target=$Target; Matched=4; SelfTestOk=$true; BatchesFired=1; ModelChanged=1; TotalBatches=1; Aborted=$false; Reason='rounded 4'; LengthSummary='0.5x4' }
}
$res = Invoke-CurvedCornerRound -Session 's' -Model 'm' -TypeObj 't' -Radius 0.25 -Thickness 0.5
Assert-True "no fallback when target matched (single call)" (@($script:calls).Count -eq 1)
Assert-True "matched-target Mode stays 'thickness'"         ([string]$res.Mode -eq 'thickness')

# NO fallback when the sweep found NOTHING (Found=0): a dead sweep is not a target miss.
$script:calls = New-Object System.Collections.ArrayList
function Invoke-AutoCornerRound {
    param($Session,$Model,$TypeObj,[double]$Radius=0.25,[double]$Target=-1,[double]$Tol=0.01,[int]$SweepMax=5000,[int]$BatchSize=40,[scriptblock]$OnPoll=$null)
    [void]$script:calls.Add($Target)
    return @{ Found=0; Target=$Target; Matched=0; SelfTestOk=$false; BatchesFired=0; ModelChanged=0; TotalBatches=0; Aborted=$false; Reason='sweep found no edges'; LengthSummary='' }
}
$res = Invoke-CurvedCornerRound -Session 's' -Model 'm' -TypeObj 't' -Radius 0.25 -Thickness 0.5
Assert-True "no fallback on a dead sweep (Found=0 -> single call)" (@($script:calls).Count -eq 1)

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ("  edge_round tests: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
Write-Host "  ============================================" -ForegroundColor Cyan
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
