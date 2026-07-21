# ============================================================================
# render_slot_preview_check.ps1 - headless render assertion for the chip-relief
# SLOT overlay (Draw-SlotRects) shown on the layout previews.
# ============================================================================
# Proves Draw-SlotRects actually executes against a real Graphics surface and
# paints the relief-slot bands (not just that the function is defined). Creates an
# off-screen bitmap, computes a real Get-RowSlots result from a sample orthogrid,
# calls Draw-SlotRects through the SAME plate-frame -> screen transform the preview
# Paint uses, and confirms amber pixels landed. Runs headless (System.Drawing only,
# NO WinForms message loop) so it never hangs like the interactive wizard-drive
# test. Exit 0 = drawn, 1 = failure. This is the evidence the response-convergence
# harness can see for the slot overlay (the analog of render_axis_glyph_check.ps1).
# ============================================================================
$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here
. (Join-Path $libDir 'orthogrid.ps1')
. (Join-Path $libDir 'orthogrid_gui.ps1')
Add-Type -AssemblyName System.Drawing -ErrorAction Stop

if ($null -eq (Get-Command Draw-SlotRects -ErrorAction SilentlyContinue)) {
    Write-Host "  [FAIL] Draw-SlotRects is not defined (dot-source / global scope problem)"
    exit 1
}

# a 3x3 grid at 2" pitch, 0.75" hole -> Get-RowSlots gives 3 full-width slot bands.
$geo   = Get-OrthogridGeometry -CcX 2.0 -CcZ 2.0 -Nx 3 -Nz 3 -Edge 2.0 -ClearDia 0.75
$slots = Get-RowSlots -Points $geo.Points -SlotWidth 0.75 -Width $geo.Width -Height $geo.Height -RowAxis 'X'
if (-not $slots.Valid -or $slots.Count -lt 1) {
    Write-Host "  [FAIL] sample layout produced no slots (Valid=$($slots.Valid), Count=$($slots.Count))"
    exit 1
}

# canvas px are $cw/$ch (NOT $W/$H): PowerShell vars are case-insensitive, so a
# $W canvas + a $w=[double]$geo.Width model dim are the SAME variable and collide
# (the model dim clobbers the canvas -> negative scale). The GUI preview avoids
# this by using $cw/$ch vs $w/$h; mirror that here.
$cw = 280; $ch = 200; $margin = 18.0
$bmp = New-Object System.Drawing.Bitmap($cw, $ch)
$g   = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::White)

# replicate the preview transform (aspect-preserving; plate-frame origin bottom-left)
$w = [double]$geo.Width; $h = [double]$geo.Height
$scale = ($cw - 2*$margin) / $w
if ((($ch - 2*$margin) / $h) -lt $scale) { $scale = ($ch - 2*$margin) / $h }
$drawW = $w * $scale; $drawH = $h * $scale
$offX = ($cw - $drawW) / 2.0; $offY = ($ch - $drawH) / 2.0

Draw-SlotRects -Graphics $g -Slots $slots -OffX $offX -OffY $offY -DrawH $drawH -Scale $scale
$g.Dispose()

# count amber-ish pixels (the ARGB(70,245,200,90) fill blended over white -> high R,
# mid-high G, low-ish B). Sample every other pixel for speed.
$amber = 0
for ($x = 0; $x -lt $cw; $x += 2) {
    for ($y = 0; $y -lt $ch; $y += 2) {
        $px = $bmp.GetPixel($x, $y)
        if ($px.R -gt 235 -and $px.G -gt 205 -and $px.G -lt 250 -and $px.B -lt 235) { $amber++ }
    }
}
$bmp.Dispose()

if ($amber -gt 20) {
    Write-Host "  [PASS] Draw-SlotRects painted $amber (sampled) amber slot-band pixels for $($slots.Count) rows"
    exit 0
} else {
    Write-Host "  [FAIL] Draw-SlotRects drew only $amber amber pixels - slot bands not rendered"
    exit 1
}
