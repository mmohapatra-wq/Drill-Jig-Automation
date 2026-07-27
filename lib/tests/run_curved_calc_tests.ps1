# ============================================================================
# lib\tests\run_curved_calc_tests.ps1 - offline unit tests for lib\curved_calc.ps1
# ============================================================================
# Runs WITHOUT Creo/network. Exercises the pure normality-verification + QA math:
#   * Get-NormalityCheck    - measured bore axis vs intended normal -> off-normal
#     angle + within-tol gate; |cos| so anti-parallel counts as aligned; degenerate
#     guard; never throws.
#   * Get-CurvedHoleQaReport - per-hole normality report + summary (Checked/WithinTol/
#     MaxOffNormalDeg/AllWithinTol); a bad hole is flagged not fatal; never throws.
#
# Run:  powershell -ExecutionPolicy Bypass -File lib\tests\run_curved_calc_tests.ps1
# Exit 0 = all pass.
# ============================================================================

$ErrorActionPreference = "Stop"
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here
# curved_calc reuses curved_jig's CJ-* vector helpers; dot-source it first.
. (Join-Path $libDir 'curved_jig.ps1')
. (Join-Path $libDir 'curved_calc.ps1')

$script:pass = 0; $script:fail = 0
function Assert-True { param([string]$Name, [bool]$Cond, [string]$Detail = "")
    if ($Cond) { Write-Host "  [PASS] $Name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  [FAIL] $Name  $Detail" -ForegroundColor Red; $script:fail++ }
}
function Approx { param([double]$A, [double]$B, [double]$Tol = 1e-6) return ([math]::Abs($A - $B) -le $Tol) }

Write-Host ""
Write-Host "  -- Get-NormalityCheck --" -ForegroundColor White

# perfectly aligned (measured == intended)
$r = Get-NormalityCheck -MeasuredAxis @(0,0,1) -IntendedNormal @(0,0,1)
Assert-True "aligned: Valid"                 ($r.Valid)
Assert-True "aligned: OffNormalDeg ~ 0"      (Approx $r.OffNormalDeg 0.0 1e-6) ("got $($r.OffNormalDeg)")
Assert-True "aligned: DotAbs ~ 1"            (Approx $r.DotAbs 1.0 1e-9)
Assert-True "aligned: WithinTol"             ($r.WithinTol)

# anti-parallel (bore drilled the other way) -> STILL aligned (|cos|)
$r = Get-NormalityCheck -MeasuredAxis @(0,0,-1) -IntendedNormal @(0,0,1)
Assert-True "anti-parallel: OffNormalDeg ~ 0" (Approx $r.OffNormalDeg 0.0 1e-6) ("got $($r.OffNormalDeg)")
Assert-True "anti-parallel: WithinTol"        ($r.WithinTol)

# non-unit inputs normalized correctly (5*+Z vs 3*+Z)
$r = Get-NormalityCheck -MeasuredAxis @(0,0,5) -IntendedNormal @(0,0,3)
Assert-True "non-unit: OffNormalDeg ~ 0"     (Approx $r.OffNormalDeg 0.0 1e-6)

# a 3-degree tilt: within the default 5-deg tol
$rad = 3.0 * [math]::PI / 180.0
$r = Get-NormalityCheck -MeasuredAxis @([math]::Sin($rad),0,[math]::Cos($rad)) -IntendedNormal @(0,0,1)
Assert-True "3deg tilt: OffNormalDeg ~ 3"    (Approx $r.OffNormalDeg 3.0 1e-4) ("got $($r.OffNormalDeg)")
Assert-True "3deg tilt: within 5deg tol"     ($r.WithinTol)

# a 10-degree tilt: OUTSIDE the default 5-deg tol, but within an 12-deg tol
$rad = 10.0 * [math]::PI / 180.0
$m = @([math]::Sin($rad),0,[math]::Cos($rad))
$r = Get-NormalityCheck -MeasuredAxis $m -IntendedNormal @(0,0,1)
Assert-True "10deg tilt: OffNormalDeg ~ 10"  (Approx $r.OffNormalDeg 10.0 1e-4) ("got $($r.OffNormalDeg)")
Assert-True "10deg tilt: NOT within 5deg"    (-not $r.WithinTol)
$r12 = Get-NormalityCheck -MeasuredAxis $m -IntendedNormal @(0,0,1) -TolDeg 12
Assert-True "10deg tilt: within 12deg tol"   ($r12.WithinTol)

# perpendicular: 90 deg off-normal (worst case)
$r = Get-NormalityCheck -MeasuredAxis @(1,0,0) -IntendedNormal @(0,0,1)
Assert-True "perp: OffNormalDeg ~ 90"        (Approx $r.OffNormalDeg 90.0 1e-4) ("got $($r.OffNormalDeg)")
Assert-True "perp: NOT within tol"           (-not $r.WithinTol)

# degenerate / bad inputs: Valid=false, never throws
$threw = $false
try {
    $rz = Get-NormalityCheck -MeasuredAxis @(0,0,0) -IntendedNormal @(0,0,1)
    Assert-True "zero axis: Valid=false"      (-not $rz.Valid)
    Assert-True "zero axis: WithinTol=false"  (-not $rz.WithinTol)
    $rn = Get-NormalityCheck -MeasuredAxis $null -IntendedNormal @(0,0,1)
    Assert-True "null axis: Valid=false"      (-not $rn.Valid)
    $rb = Get-NormalityCheck -MeasuredAxis @(1,2) -IntendedNormal @(0,0,1)
    Assert-True "2-vec axis: Valid=false"     (-not $rb.Valid)
} catch { $threw = $true }
Assert-True "bad inputs never throw"          (-not $threw)

Write-Host ""
Write-Host "  -- Get-CurvedHoleQaReport --" -ForegroundColor White

# 3 holes: 2 normal, 1 tilted 10 deg (out of 5-deg tol)
$rad = 10.0 * [math]::PI / 180.0
$holes = @(
    [pscustomobject]@{ Id=101; MeasuredAxis=@(0,0,1);  IntendedNormal=@(0,0,1);  Pos=@(0,0,0) },
    [pscustomobject]@{ Id=102; MeasuredAxis=@(0,0,-1); IntendedNormal=@(0,0,1);  Pos=@(1,0,0) },
    [pscustomobject]@{ Id=103; MeasuredAxis=@([math]::Sin($rad),0,[math]::Cos($rad)); IntendedNormal=@(0,0,1); Pos=@(2,0,0) }
)
$rep = Get-CurvedHoleQaReport -Holes $holes -TolDeg 5
Assert-True "report: Valid"                  ($rep.Valid)
Assert-True "report: Count == 3"             ($rep.Count -eq 3)
Assert-True "report: Checked == 3"           ($rep.Checked -eq 3)
Assert-True "report: WithinTol == 2"         ($rep.WithinTol -eq 2) ("got $($rep.WithinTol)")
Assert-True "report: MaxOffNormalDeg ~ 10"   (Approx $rep.MaxOffNormalDeg 10.0 1e-4) ("got $($rep.MaxOffNormalDeg)")
Assert-True "report: NOT AllWithinTol"       (-not $rep.AllWithinTol)
Assert-True "report: 3 rows"                 (@($rep.Rows).Count -eq 3)
$row103 = @($rep.Rows | Where-Object { $_.Id -eq 103 })[0]
Assert-True "report: hole 103 off-normal ~10"(Approx $row103.OffNormalDeg 10.0 1e-4)
Assert-True "report: hole 103 not within tol"(-not $row103.WithinTol)
Assert-True "report: hole 101 carries Pos"   (@($rep.Rows | Where-Object { $_.Id -eq 101 })[0].Pos[0] -eq 0)

# all normal -> AllWithinTol true
$allNormal = @(
    [pscustomobject]@{ Id=1; MeasuredAxis=@(0,0,1); IntendedNormal=@(0,0,1) },
    [pscustomobject]@{ Id=2; MeasuredAxis=@(0,1,0); IntendedNormal=@(0,1,0) }
)
$rep2 = Get-CurvedHoleQaReport -Holes $allNormal -TolDeg 5
Assert-True "all-normal: AllWithinTol"       ($rep2.AllWithinTol)
Assert-True "all-normal: WithinTol == 2"     ($rep2.WithinTol -eq 2)

# a bad hole (missing MeasuredAxis) is flagged, not fatal; the good hole still checks
$mixed = @(
    [pscustomobject]@{ Id=1; MeasuredAxis=@(0,0,1); IntendedNormal=@(0,0,1) },
    [pscustomobject]@{ Id=2; IntendedNormal=@(0,0,1) },   # no MeasuredAxis
    $null                                                  # null record
)
$rep3 = Get-CurvedHoleQaReport -Holes $mixed
Assert-True "mixed: Count == 3"              ($rep3.Count -eq 3)
Assert-True "mixed: Checked == 1"            ($rep3.Checked -eq 1) ("got $($rep3.Checked)")
$badRow = @($rep3.Rows | Where-Object { $_.Id -eq 2 })[0]
Assert-True "mixed: hole 2 flagged not Ok"   (-not $badRow.Ok)
Assert-True "mixed: hole 2 has a Reason"     (-not [string]::IsNullOrWhiteSpace($badRow.Reason))
Assert-True "mixed: still Valid (1 checked)" ($rep3.Valid)

# empty / null input: not Valid, no throw
$threw2 = $false
try {
    $re = Get-CurvedHoleQaReport -Holes @()
    Assert-True "empty: not Valid"           (-not $re.Valid)
    $rn = Get-CurvedHoleQaReport -Holes $null
    Assert-True "null: not Valid"            (-not $rn.Valid)
} catch { $threw2 = $true }
Assert-True "empty/null never throw"          (-not $threw2)

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ("  curved-calc tests: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
Write-Host "  ============================================" -ForegroundColor Cyan
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
