# ============================================================================
# render_axis_glyph_check.ps1 - headless render assertion for the X/Z axis glyph
# ============================================================================
# Proves Draw-AxisGlyph actually executes against a real Graphics surface (not
# just that the function is defined). Creates an off-screen bitmap, calls
# Draw-AxisGlyph on its Graphics, and confirms it returns without throwing AND
# that pixels were drawn (the glyph is non-blank). Exit 0 = drawn, 1 = failure.
# This is the evidence the response-convergence harness can see for the glyph.
# ============================================================================
$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here
. (Join-Path $libDir 'orthogrid.ps1')
. (Join-Path $libDir 'orthogrid_gui.ps1')
Add-Type -AssemblyName System.Drawing -ErrorAction Stop

$W = 210; $H = 190
$bmp = New-Object System.Drawing.Bitmap($W, $H)
$g   = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::White)

# call the real helper
Draw-AxisGlyph -Graphics $g -ClientW $W -ClientH $H
$g.Dispose()

# the glyph lives in the bottom-left ~40px box; count non-white pixels there.
$drawn = 0
for ($x = 0; $x -lt 45; $x++) {
    for ($y = $H - 45; $y -lt $H; $y++) {
        $px = $bmp.GetPixel($x, $y)
        if ($px.R -lt 250 -or $px.G -lt 250 -or $px.B -lt 250) { $drawn++ }
    }
}
$bmp.Dispose()

if ($drawn -gt 20) {
    Write-Host "  [PASS] Draw-AxisGlyph drew $drawn non-white pixels in the bottom-left (X/Z glyph present)"
    exit 0
} else {
    Write-Host "  [FAIL] Draw-AxisGlyph drew only $drawn pixels - glyph not rendered"
    exit 1
}
