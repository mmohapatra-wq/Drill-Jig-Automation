# ============================================================================
# render_bushing_check.ps1 - headless render assertion for Draw-BushingSchematic
# ============================================================================
# Proves the GDI+ drawer actually executes against a real Graphics surface (not
# just that it's defined). Draws onto an off-screen bitmap and confirms it returns
# without throwing AND that pixels landed in BOTH the side-view region and the
# end-view region (i.e. the schematic is non-blank). Exit 0 = drawn, 1 = failure.
# This is the evidence the response-convergence harness can see for the WinForms
# path. Mirrors render_axis_glyph_check.ps1.
# ============================================================================
$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here
. (Join-Path $libDir 'bushing_svg.ps1')
Add-Type -AssemblyName System.Drawing -ErrorAction Stop

$W = 660; $H = 340
$bg = [System.Drawing.Color]::FromArgb(32, 33, 39)
$bmp = New-Object System.Drawing.Bitmap($W, $H)
$g   = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear($bg)

# call the real drawer with the same knobs the window uses
Draw-BushingSchematic -Graphics $g -OD 0.75 -ID 0.5 -Length 0.75 `
    -ClientW $W -ClientH $H -ShowEnd $true -ShowDims $true -Background $bg `
    -Label 'Sleeve | OD 3/4 x ID 1/2 x 3/4 Lg'
$g.Dispose()

function Count-NonBg($bmp, $x0, $x1, $y0, $y1, $bg) {
    $n = 0
    for ($x = $x0; $x -lt $x1; $x += 2) {
        for ($y = $y0; $y -lt $y1; $y += 2) {
            $p = $bmp.GetPixel($x, $y)
            if ([math]::Abs($p.R - $bg.R) + [math]::Abs($p.G - $bg.G) + [math]::Abs($p.B - $bg.B) -gt 24) { $n++ }
        }
    }
    return $n
}
# side view lives in the left ~55%, end view in the right region
$side = Count-NonBg $bmp 60  360 50 290 $bg
$end  = Count-NonBg $bmp 400 640 50 290 $bg
$bmp.Dispose()

$ok = ($side -gt 150) -and ($end -gt 80)

# ---- HEADED drill bushing: the head must protrude ABOVE the body top ----
# (user 2026-07-22: drill bushings are headed so they aren't confused with headless
# sleeves). Draw a drill bushing and count non-bg pixels in the head-only band -
# the strip ABOVE the body top, over the head's axial width. For a headless sleeve
# that band is empty; here it must be populated (the flange).
$odD = 0.75; $idD = 0.5; $lenD = 0.75
$headD = Get-BushingHeadDia -EasyName 'Drill Bushing | OD 3/4 x ID 1/2 x 3/4 Lg' -OD $odD
$Ld = Get-BushingLayout -OD $odD -ID $idD -Length $lenD -HeadDia $headD -CanvasW $W -CanvasH $H -ShowEnd $true
$bmp2 = New-Object System.Drawing.Bitmap($W, $H)
$g2 = [System.Drawing.Graphics]::FromImage($bmp2)
$g2.Clear($bg)
Draw-BushingSchematic -Graphics $g2 -OD $odD -ID $idD -Length $lenD -HeadDia $headD `
    -ClientW $W -ClientH $H -ShowEnd $true -ShowDims $true -Background $bg -Label 'Drill Bushing | OD 3/4 x ID 1/2 x 3/4 Lg'
$g2.Dispose()
# head-only protrusion band: x in [Bx, Bx+HeadW], y in [top-of-head, body-top)
$hx0 = [int][math]::Floor($Ld.Bx); $hx1 = [int][math]::Ceiling($Ld.Bx + $Ld.HeadW)
$hy0 = [int][math]::Floor($Ld.Cy - $Ld.HDp/2.0); $hy1 = [int][math]::Floor($Ld.By) - 2
$headPix = 0
for ($x = [math]::Max(0,$hx0); $x -lt [math]::Min($W,$hx1); $x++) {
    for ($y = [math]::Max(0,$hy0); $y -lt [math]::Max(0,$hy1); $y++) {
        $p = $bmp2.GetPixel($x, $y)
        if ([math]::Abs($p.R-$bg.R)+[math]::Abs($p.G-$bg.G)+[math]::Abs($p.B-$bg.B) -gt 24) { $headPix++ }
    }
}
$bmp2.Dispose()
$headOk = ($headD -gt $odD) -and ($headPix -gt 30)
$ok = $ok -and $headOk

if ($ok) {
    Write-Host "  [PASS] Draw-BushingSchematic rendered (side=$side, end=$end); drill HEAD protrudes above body ($headPix px, headDia=$headD)"
    exit 0
} else {
    Write-Host "  [FAIL] side=$side end=$end headPix=$headPix headDia=$headD (want side>150, end>80, headPix>30)"
    exit 1
}
