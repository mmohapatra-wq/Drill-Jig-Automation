# ============================================================================
# run_bushing_tests.ps1 - offline unit tests for lib\bushing_svg.ps1 (PURE math)
# ============================================================================
# No Creo, no network, no WinForms. Covers Get-BushingFracLabel, Test-BushingDims,
# Get-BushingLayout, and Get-BushingSvg (well-formed XML). The GDI+ drawer is
# covered separately by render_bushing_check.ps1 (needs System.Drawing).
#   powershell -ExecutionPolicy Bypass -File lib\tests\run_bushing_tests.ps1
# exit 0 = all pass.
# ============================================================================
$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here
. (Join-Path $libDir 'bushing_svg.ps1')

$pass = 0; $fail = 0
function Assert-True($name, $cond) {
    if ($cond) { $script:pass++ } else { $script:fail++; Write-Host "  [FAIL] $name" -ForegroundColor Red }
}
function Approx($a, $b, $tol = 1e-6) { return [math]::Abs([double]$a - [double]$b) -lt $tol }

# ---- Get-BushingFracLabel ----
Assert-True "frac 0.75 -> 3/4"      ((Get-BushingFracLabel 0.75)   -eq '3/4')
Assert-True "frac 0.5 -> 1/2"       ((Get-BushingFracLabel 0.5)    -eq '1/2')
Assert-True "frac 0.25 -> 1/4"      ((Get-BushingFracLabel 0.25)   -eq '1/4')
Assert-True "frac 0.3125 -> 5/16"   ((Get-BushingFracLabel 0.3125) -eq '5/16')
Assert-True "frac 0.375 -> 3/8"     ((Get-BushingFracLabel 0.375)  -eq '3/8')
Assert-True "frac 0.125 -> 1/8"     ((Get-BushingFracLabel 0.125)  -eq '1/8')
Assert-True "frac 1.0 -> 1"         ((Get-BushingFracLabel 1.0)    -eq '1')
Assert-True "frac 1.375 -> 1 3/8"   ((Get-BushingFracLabel 1.375)  -eq '1 3/8')
Assert-True "frac 2.125 -> 2 1/8"   ((Get-BushingFracLabel 2.125)  -eq '2 1/8')
# 4-dp catalog decimals that are ROUNDED 64ths (0.4844=31/64=.484375, 0.2031=13/64=.203125)
# stay DECIMAL at the 1e-6 tolerance (matches the approved HTML prototype + the repo's
# convention of showing odd drill IDs as decimals, not fractions).
Assert-True "frac 0.4844 -> decimal (rounded 64th, >1e-6 off)" ((Get-BushingFracLabel 0.4844) -match '^0\.4844')
Assert-True "frac 0.2031 -> decimal" ((Get-BushingFracLabel 0.2031) -match '^0\.2031')
Assert-True "frac 0 -> '0' (no throw)" ((Get-BushingFracLabel 0) -eq '0')

# ---- Test-BushingDims ----
Assert-True "valid dims Ok"          ((Test-BushingDims -OD 0.75 -ID 0.5 -Length 0.75).Ok)
Assert-True "id=od invalid"     (-not (Test-BushingDims -OD 0.5  -ID 0.5 -Length 0.5).Ok)
Assert-True "id>od invalid"     (-not (Test-BushingDims -OD 0.5  -ID 0.6 -Length 0.5).Ok)
Assert-True "zero length invalid" (-not (Test-BushingDims -OD 0.5 -ID 0.25 -Length 0).Ok)
Assert-True "neg OD invalid"    (-not (Test-BushingDims -OD -1 -ID 0.25 -Length 0.5).Ok)
Assert-True "invalid carries an Error string" ((Test-BushingDims -OD 0.5 -ID 0.5 -Length 0.5).Error.Length -gt 0)

# ---- Get-BushingHeadDia (drill bushings are headed; sleeves headless) ----
Assert-True "head: drill bushing 3/4 -> OD*1.35" (Approx (Get-BushingHeadDia -EasyName 'Drill Bushing | OD 3/4 x ID 1/2 x 3/4 Lg' -OD 0.75) (0.75*1.35))
Assert-True "head: drill head > OD (flange protrudes)" ((Get-BushingHeadDia -EasyName 'Drill Bushing | OD 3/4 x ID 1/2 x 3/4 Lg' -OD 0.75) -gt 0.75)
Assert-True "head: sleeve -> 0 (headless)" ((Get-BushingHeadDia -EasyName 'Sleeve | OD 3/4 x ID 1/2 x 3/4 Lg' -OD 0.75) -eq 0)
Assert-True "head: metal removable (Drill Bushing, ID any) -> headed" ((Get-BushingHeadDia -EasyName 'Drill Bushing | OD 3/4 x ID (any) x 3/4 Lg' -OD 0.75) -gt 0)
Assert-True "head: case-insensitive DRILL BUSHING -> headed" ((Get-BushingHeadDia -EasyName 'DRILL BUSHING | OD 1/2 x ID 1/4 x 1/4 Lg' -OD 0.5) -gt 0)
Assert-True "head: 1/2 OD drill ~ 0.675 (near real 11/16)" (Approx (Get-BushingHeadDia -EasyName 'Drill Bushing' -OD 0.5) 0.675 1e-3)
Assert-True "head: blank EasyName -> 0" ((Get-BushingHeadDia -EasyName '' -OD 0.75) -eq 0)
Assert-True "head: null EasyName -> 0 (no throw)" ((Get-BushingHeadDia -EasyName $null -OD 0.75) -eq 0)
Assert-True "head: OD<=0 -> 0" ((Get-BushingHeadDia -EasyName 'Drill Bushing' -OD 0) -eq 0)
Assert-True "head: custom factor honored" (Approx (Get-BushingHeadDia -EasyName 'Drill Bushing' -OD 0.5 -Factor 1.5) 0.75)

# ---- Get-BushingLayout ----
$L = Get-BushingLayout -OD 0.75 -ID 0.5 -Length 0.75 -CanvasW 660 -CanvasH 340 -ShowEnd $true
Assert-True "layout: wall == (ODp-IDp)/2" (Approx $L.Wall (($L.ODp - $L.IDp)/2))
Assert-True "layout: bore band height == IDp" (Approx ($L.BoreB - $L.BoreT) $L.IDp)
Assert-True "layout: Cy centered in body" (Approx $L.Cy ($L.By + $L.ODp/2))
Assert-True "layout: fits canvas width" (($L.Bx + $L.Lp) -le 660.0001 -and $L.Bx -ge 0)
Assert-True "layout: fits canvas height" (($L.By + $L.ODp) -le 340.0001 -and $L.By -ge 0)
Assert-True "layout: bore smaller than OD" ($L.IDp -lt $L.ODp)
Assert-True "layout: end view present + to the RIGHT of side view" (($null -ne $L.Ecx) -and $L.Ecx -gt ($L.Bx + $L.Lp))
Assert-True "layout: Ro/Ri match ODp/IDp" ((Approx $L.Ro ($L.ODp/2)) -and (Approx $L.Ri ($L.IDp/2)))
Assert-True "layout: no head -> HeadW 0" (Approx $L.HeadW 0)

$Lh = Get-BushingLayout -OD 0.5 -ID 0.25 -Length 0.5 -HeadDia 0.625 -CanvasW 660 -CanvasH 340 -ShowEnd $true
Assert-True "layout(head): HeadW > 0" ($Lh.HeadW -gt 0)
Assert-True "layout(head): HDp scales head dia" (Approx $Lh.HDp (0.625 * $Lh.Scale))
Assert-True "layout(head): outer scale uses head (head>OD) -> head fits height" (($Lh.HDp) -le 340.0001)

# no-end mode gives the side view the FULL width. On the SAME canvas its scale must be
# >= the with-end scale (equal when height-limited, as for a square-ish bushing; strictly
# greater when width-limited, e.g. a long thin bushing).
$Lne = Get-BushingLayout -OD 0.75 -ID 0.5 -Length 0.75 -CanvasW 660 -CanvasH 340 -ShowEnd $false
Assert-True "layout(no end): Ecx null" ($null -eq $Lne.Ecx)
Assert-True "layout(no end): side scale >= with-end scale (same canvas)" ($Lne.Scale -ge $L.Scale - 1e-9)
$LneLong    = Get-BushingLayout -OD 0.25 -ID 0.125 -Length 2.125 -CanvasW 660 -CanvasH 340 -ShowEnd $false
$LwithEndLong = Get-BushingLayout -OD 0.25 -ID 0.125 -Length 2.125 -CanvasW 660 -CanvasH 340 -ShowEnd $true
Assert-True "layout(no end, long/width-limited): strictly bigger scale" ($LneLong.Scale -gt $LwithEndLong.Scale)

# a very long thin bushing still fits (scale clamps to width)
$Llong = Get-BushingLayout -OD 0.25 -ID 0.125 -Length 2.125 -CanvasW 660 -CanvasH 340 -ShowEnd $true
Assert-True "layout(long): fits width" (($Llong.Bx + $Llong.Lp) -le 660.0001)
Assert-True "layout(long): fits height" (($Llong.By + $Llong.ODp) -le 340.0001)

# ---- Get-BushingSvg ----
$svg = Get-BushingSvg -OD 0.75 -ID 0.5 -Length 0.75 -Label 'Sleeve | OD 3/4 x ID 1/2 x 3/4 Lg'
Assert-True "svg: non-empty" ($svg.Length -gt 200)
$xmlok = $false
try { [xml]$svg | Out-Null; $xmlok = $true } catch { }
Assert-True "svg: well-formed XML" $xmlok
Assert-True "svg: has <svg root" ($svg -match '<svg ')
Assert-True "svg: has hatch pattern" ($svg -match 'id="hatch"')
Assert-True "svg: labels the length" ($svg -match 'L = 3/4')
Assert-True "svg: OD dim present" ($svg -match 'OD ')
Assert-True "svg: end-view circle present" ($svg -match '<circle ')
Assert-True "svg: label escaped + present" ($svg -match 'Sleeve')

$svgHead = Get-BushingSvg -OD 0.5 -ID 0.25 -Length 0.5 -HeadDia 0.625
$xmlok2 = $false; try { [xml]$svgHead | Out-Null; $xmlok2 = $true } catch { }
Assert-True "svg(head): well-formed XML" $xmlok2

$svgNoEnd = Get-BushingSvg -OD 0.75 -ID 0.5 -Length 0.75 -ShowEnd $false
Assert-True "svg(no end): no circle" (-not ($svgNoEnd -match '<circle '))
$xmlok3 = $false; try { [xml]$svgNoEnd | Out-Null; $xmlok3 = $true } catch { }
Assert-True "svg(no end): well-formed XML" $xmlok3

Assert-True "svg: invalid dims -> empty string" ((Get-BushingSvg -OD 0.5 -ID 0.6 -Length 0.5) -eq '')
# a label with XML-special chars must not break well-formedness
$svgAmp = Get-BushingSvg -OD 0.75 -ID 0.5 -Length 0.75 -Label 'A & B <x> "q"'
$xmlok4 = $false; try { [xml]$svgAmp | Out-Null; $xmlok4 = $true } catch { }
Assert-True "svg: special-char label stays well-formed XML" $xmlok4

Write-Host ""
if ($fail -eq 0) { Write-Host "  RESULTS: $pass passed, 0 failed" -ForegroundColor Green; exit 0 }
else { Write-Host "  RESULTS: $pass passed, $fail failed" -ForegroundColor Red; exit 1 }
