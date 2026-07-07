# ============================================================================
# lib\tests\run_index_frame_tests.ps1 - offline unit tests for lib\index_frame.ps1
# ============================================================================
# Runs WITHOUT Creo and WITHOUT network. Exercises the pure change-of-basis math:
# frame construction, the (x,y) INVARIANCE under arbitrary along-bore axis-origin
# placement (the load-bearing property verified by the 3-way derivation +
# adversarial judge, 2026-06-26), the degenerate guards, and the runtime
# self-check (orthonormality + fixed points). Mirrors run_orthogrid_tests.ps1.
#
# Run:  powershell -ExecutionPolicy Bypass -File lib\tests\run_index_frame_tests.ps1
# Exit code 0 = all passed, 1 = at least one failure.
# ============================================================================

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here
. (Join-Path $libDir 'index_frame.ps1')

$script:pass = 0
$script:fail = 0

function Assert-True {
    param([string]$Name, [bool]$Cond, [string]$Detail = "")
    if ($Cond) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  [FAIL] $Name $Detail" -ForegroundColor Red
        $script:fail++
    }
}

function Approx {
    param([double]$A, [double]$B, [double]$Tol = 1e-9)
    return [Math]::Abs($A - $B) -le $Tol
}

Write-Host ""
Write-Host "  Running index-frame unit tests (offline)..." -ForegroundColor Cyan
Write-Host ""

# ----------------------------------------------------------------------------
# Vec3 helpers
# ----------------------------------------------------------------------------
Write-Host "  -- vec helpers --" -ForegroundColor White

Assert-True "IFrame-Dot basic" (Approx (IFrame-Dot @(1,2,3) @(4,5,6)) 32.0)
$cx = IFrame-Cross @(1,0,0) @(0,1,0)
Assert-True "IFrame-Cross x cross y = z" ((Approx $cx[0] 0) -and (Approx $cx[1] 0) -and (Approx $cx[2] 1))
Assert-True "IFrame-Norm 3-4-5" (Approx (IFrame-Norm @(3,4,0)) 5.0)
$u = IFrame-Unit @(0,0,5)
Assert-True "IFrame-Unit normalizes" ((Approx $u[0] 0) -and (Approx $u[2] 1))
Assert-True "IFrame-Unit degenerate -> null" ($null -eq (IFrame-Unit @(0,0,0)))

# ----------------------------------------------------------------------------
# Canonical axis-aligned frame: index holes on the X axis of a Z-up plate.
#   A1 = (0,0,0), A2 = (10,0,0), bores along +Z.
#   Expect Xhat=+X, Yhat=+Y, Zhat=+Z, IndexSep=10.
# ----------------------------------------------------------------------------
Write-Host "  -- canonical axis-aligned frame --" -ForegroundColor White

$Z = @(0,0,1)
$f = Get-IndexFrame -A1 @(0,0,0) -A2 @(10,0,0) -D1 $Z -D2 $Z
Assert-True "canonical: Valid" ($f.Valid)
Assert-True "canonical: Xhat = +X" ((Approx $f.Xhat[0] 1) -and (Approx $f.Xhat[1] 0) -and (Approx $f.Xhat[2] 0))
Assert-True "canonical: Yhat = +Y" ((Approx $f.Yhat[0] 0) -and (Approx $f.Yhat[1] 1) -and (Approx $f.Yhat[2] 0))
Assert-True "canonical: Zhat = +Z" ((Approx $f.Zhat[0] 0) -and (Approx $f.Zhat[1] 0) -and (Approx $f.Zhat[2] 1))
Assert-True "canonical: IndexSep = 10" (Approx $f.IndexSep 10.0)
Assert-True "canonical: AxisAngleDeg ~ 0" (Approx $f.AxisAngleDeg 0.0 1e-6)

# transform A1 -> (0,0,0), A2 -> (10,0,0)
$c1 = ConvertTo-IndexCoords -Frame $f -P @(0,0,0)
$c2 = ConvertTo-IndexCoords -Frame $f -P @(10,0,0)
Assert-True "canonical: A1 -> (0,0,0)" ((Approx $c1.X 0) -and (Approx $c1.Y 0) -and (Approx $c1.Z 0))
Assert-True "canonical: A1 flagged AtOrigin" ($c1.AtOrigin)
Assert-True "canonical: A2 -> (10,0,0)" ((Approx $c2.X 10) -and (Approx $c2.Y 0) -and (Approx $c2.Z 0))

# a target left of the 1->2 line (viewed from +Z down... here +Y) gets +y.
$cL = ConvertTo-IndexCoords -Frame $f -P @(5,3,0)
Assert-True "target at (5,3,0) -> x=5, y=3 (+Y is left of 1->2)" ((Approx $cL.X 5) -and (Approx $cL.Y 3))
$cR = ConvertTo-IndexCoords -Frame $f -P @(5,-3,0)
Assert-True "target at (5,-3,0) -> x=5, y=-3 (right of 1->2)" ((Approx $cR.X 5) -and (Approx $cR.Y -3))

# ----------------------------------------------------------------------------
# THE INVARIANCE TEST (load-bearing): slide each axis origin by an ARBITRARY
# amount along Zhat - the reported (x,y) must be UNCHANGED; only z changes.
# This is the property that lets us trust a cylinder descriptor that puts the
# axis origin anywhere along the bore.
# ----------------------------------------------------------------------------
Write-Host "  -- (x,y) invariance under along-bore origin shift --" -ForegroundColor White

# Baseline: a rotated, non-axis-aligned plate so the test isn't trivially X/Y.
#   Build a frame from tilted-but-parallel bores along d=(0,0,1), holes in the
#   z=0 plane, then shift origins by different amounts along z.
$A1 = @(2, 1, 0)
$A2 = @(2, 7, 0)         # 1->2 is along +Y this time
$D  = @(0, 0, 1)
$fb = Get-IndexFrame -A1 $A1 -A2 $A2 -D1 $D -D2 $D
Assert-True "invariance base: Valid" ($fb.Valid)
$P  = @(5, 4, 0)          # a target hole
$cBase = ConvertTo-IndexCoords -Frame $fb -P $P

# Now shift A1 by s1, A2 by s2, P by sp - all along Z - and rebuild + retransform.
$s1 = 3.3; $s2 = -1.7; $sp = 9.9
# Parenthesize each computed component: inside @(...) the comma binds tighter
# than +, so @($A1[0],$A1[1],$A1[2]+$s1) would build @(2,1,0) THEN +$s1 -> a
# 4-element @(2,1,0,3.3) (the documented comma-array trap). Parens force scalars.
$A1s = @($A1[0], $A1[1], ($A1[2] + $s1))
$A2s = @($A2[0], $A2[1], ($A2[2] + $s2))
$Ps  = @($P[0],  $P[1],  ($P[2]  + $sp))
$fs = Get-IndexFrame -A1 $A1s -A2 $A2s -D1 $D -D2 $D
$cShift = ConvertTo-IndexCoords -Frame $fs -P $Ps

Assert-True "invariance: x unchanged after arbitrary along-Z origin shifts" (Approx $cShift.X $cBase.X 1e-9)
Assert-True "invariance: y unchanged after arbitrary along-Z origin shifts" (Approx $cShift.Y $cBase.Y 1e-9)
Assert-True "invariance: z DID change (sp - s1 difference)" (-not (Approx $cShift.Z $cBase.Z 1e-6))
# z should change by exactly (sp - s1) since R = (P+sp Z) - (A1+s1 Z), z = R.Zhat
Assert-True "invariance: delta-z == (sp - s1)" (Approx ($cShift.Z - $cBase.Z) ($sp - $s1) 1e-9)

# A diagonal-bore variant: bores along a tilted-but-shared unit dir; shift along
# THAT dir. (x,y) still invariant because Xhat,Yhat perp to that shared Zhat.
$Dt = IFrame-Unit @(0.1, -0.2, 1.0)
$g  = Get-IndexFrame -A1 @(0,0,0) -A2 @(4,1,0) -D1 $Dt -D2 $Dt
$Pt = @(2.5, 2.0, 1.0)
$cg0 = ConvertTo-IndexCoords -Frame $g -P $Pt
$t = 6.25
$Pt2 = @(($Pt[0] + $t*$Dt[0]), ($Pt[1] + $t*$Dt[1]), ($Pt[2] + $t*$Dt[2]))
$cg1 = ConvertTo-IndexCoords -Frame $g -P $Pt2
Assert-True "tilted bore: x invariant under shift along shared axis" (Approx $cg0.X $cg1.X 1e-9)
Assert-True "tilted bore: y invariant under shift along shared axis" (Approx $cg0.Y $cg1.Y 1e-9)

# ----------------------------------------------------------------------------
# Sign-alignment: D2 returned ANTI-parallel must not break the frame (Zhat is
# averaged from sign-aligned dirs).
# ----------------------------------------------------------------------------
Write-Host "  -- anti-parallel descriptor sign-align --" -ForegroundColor White

$fAnti = Get-IndexFrame -A1 @(0,0,0) -A2 @(10,0,0) -D1 @(0,0,1) -D2 @(0,0,-1)
Assert-True "anti-parallel D2: still Valid (sign-aligned)" ($fAnti.Valid)
Assert-True "anti-parallel D2: Zhat aligned to D1 (+Z)" ($fAnti.Zhat[2] -gt 0.99)
Assert-True "anti-parallel D2: AxisAngleDeg ~ 0 (abs(dot))" (Approx $fAnti.AxisAngleDeg 0.0 1e-6)

# ----------------------------------------------------------------------------
# AllDirs averaging: pass several near-parallel dirs; Zhat is their normalized
# sign-aligned mean. Slight noise should average toward +Z.
# ----------------------------------------------------------------------------
Write-Host "  -- AllDirs noise averaging --" -ForegroundColor White

$dirsNoisy = @( @(0.001,0,1), @(-0.001,0.001,1), @(0,-0.001,1), @(0,0,1) )
$fAvg = Get-IndexFrame -A1 @(0,0,0) -A2 @(8,0,0) -D1 @(0,0,1) -D2 @(0,0,1) -AllDirs $dirsNoisy
Assert-True "AllDirs: Valid" ($fAvg.Valid)
Assert-True "AllDirs: Zhat ~ +Z after averaging" ($fAvg.Zhat[2] -gt 0.999)

# ----------------------------------------------------------------------------
# DEGENERATE GUARDS (judge spec section 3) - all return Valid=$false, never throw.
# ----------------------------------------------------------------------------
Write-Host "  -- degenerate guards --" -ForegroundColor White

# (1) index holes axially collinear: A2-A1 is purely along Zhat -> v ~ 0.
$fCol = Get-IndexFrame -A1 @(0,0,0) -A2 @(0,0,5) -D1 @(0,0,1) -D2 @(0,0,1)
Assert-True "collinear index holes -> Invalid" (-not $fCol.Valid)
Assert-True "collinear: error mentions in-plane separation" (($fCol.Errors -join ' ') -match 'collinear|in-plane')

# (2) anti-parallel that truly cancels Zhat: only two dirs, exactly opposite,
#     BUT sign-align fixes it -> so to actually cancel we need dirs that the
#     sign-align cannot save. With only D1,D2 sign-align always saves it, so
#     this guard is near-unreachable; assert sign-align indeed saves it.
$fOpp = Get-IndexFrame -A1 @(0,0,0) -A2 @(10,0,0) -D1 @(0,0,1) -D2 @(0,0,-1)
Assert-True "opposite D1/D2 saved by sign-align (not cancelled)" ($fOpp.Valid)

# (3) missing / malformed inputs
$fBad = Get-IndexFrame -A1 @(0,0) -A2 @(1,0,0) -D1 @(0,0,1) -D2 @(0,0,1)
Assert-True "short A1 vector -> Invalid, no throw" (-not $fBad.Valid)
$fNull = Get-IndexFrame -A1 $null -A2 @(1,0,0) -D1 @(0,0,1) -D2 @(0,0,1)
Assert-True "null A1 -> Invalid, no throw" (-not $fNull.Valid)

# (4) degenerate bore direction
$fZeroD = Get-IndexFrame -A1 @(0,0,0) -A2 @(10,0,0) -D1 @(0,0,0) -D2 @(0,0,1)
Assert-True "zero-length D1 -> Invalid" (-not $fZeroD.Valid)

# ConvertTo-IndexCoords on an invalid frame -> $null (no throw)
Assert-True "ConvertTo-IndexCoords on invalid frame -> null" ($null -eq (ConvertTo-IndexCoords -Frame $fCol -P @(1,2,3)))

# ----------------------------------------------------------------------------
# Test-IndexFrameValid - orthonormality + fixed-point self-check.
# ----------------------------------------------------------------------------
Write-Host "  -- Test-IndexFrameValid self-check --" -ForegroundColor White

$tv = Test-IndexFrameValid -Frame $f -A1 @(0,0,0) -A2 @(10,0,0)
Assert-True "self-check Ok on canonical frame" ($tv.Ok)
Assert-True "self-check: A1 maps to (0,0)" ((Approx $tv.Residuals['A1x'] 0 1e-9) -and (Approx $tv.Residuals['A1y'] 0 1e-9))
Assert-True "self-check: A2 on +X (y~0)" (Approx $tv.Residuals['A2y'] 0 1e-9)
Assert-True "self-check: A2x = d > 0" ($tv.Residuals['A2x'] -gt 0)
Assert-True "self-check: no warnings (parallel bores)" ($tv.Warnings.Count -eq 0)

# self-check WARNS when bores are non-parallel beyond MaxAxisAngleDeg.
# bores 0.2 deg apart: D1=+Z, D2 tilted by 0.2 deg in X.
$theta = 0.2 * [Math]::PI / 180.0
$D2tilt = IFrame-Unit @([Math]::Sin($theta), 0, [Math]::Cos($theta))
$fTilt = Get-IndexFrame -A1 @(0,0,0) -A2 @(10,0,0) -D1 @(0,0,1) -D2 $D2tilt
$tvTilt = Test-IndexFrameValid -Frame $fTilt -A1 @(0,0,0) -A2 @(10,0,0) -MaxAxisAngleDeg 0.05
Assert-True "non-parallel bores (0.2deg) -> self-check still Ok (orthonormal)" ($tvTilt.Ok)
Assert-True "non-parallel bores -> WARN about invariance degradation" ($tvTilt.Warnings.Count -ge 1)

# invalid frame -> Ok=$false
$tvInv = Test-IndexFrameValid -Frame $fCol
Assert-True "self-check on invalid frame -> not Ok" (-not $tvInv.Ok)

# ----------------------------------------------------------------------------
# REALISTIC SCENARIO: a 3x2 hole plate, index = corner + adjacent, origins read
# at DIFFERENT heights on each bore. Verify every reported (x,y) matches the
# plate layout regardless of per-hole axial slop.
# ----------------------------------------------------------------------------
Write-Host "  -- realistic plate w/ per-hole axial slop --" -ForegroundColor White

# True plate (in part coords, axis-aligned for the test): holes at
#   (0,0),(2,0),(4,0),(0,1.5),(2,1.5),(4,1.5) in XY, bores +Z.
# Index = hole at (0,0) [#1] and (4,0) [#2]. Frame X = +X, so reported (x,y)
# should equal the part XY exactly (origin already at hole1).
$layout = @(
    @{ XY=@(0,0);    H=0.0  },
    @{ XY=@(2,0);    H=0.7  },
    @{ XY=@(4,0);    H=-0.3 },
    @{ XY=@(0,1.5);  H=1.2  },
    @{ XY=@(2,1.5);  H=-0.9 },
    @{ XY=@(4,1.5);  H=0.4  }
)
function P-of { param($e) @($e.XY[0], $e.XY[1], $e.H) }   # axis origin = (x,y,height)
$frm = Get-IndexFrame -A1 (P-of $layout[0]) -A2 (P-of $layout[2]) -D1 @(0,0,1) -D2 @(0,0,1)
Assert-True "realistic: frame Valid" ($frm.Valid)
$allMatch = $true
foreach ($e in $layout) {
    $c = ConvertTo-IndexCoords -Frame $frm -P (P-of $e)
    if (-not ((Approx $c.X $e.XY[0] 1e-9) -and (Approx $c.Y $e.XY[1] 1e-9))) { $allMatch = $false }
}
Assert-True "realistic: every hole (x,y) matches plate XY despite per-hole height slop" $allMatch

# ----------------------------------------------------------------------------
# SUMMARY
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ("  index-frame tests: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { "Green" } else { "Red" })
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ""
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
