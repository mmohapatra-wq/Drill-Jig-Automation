# ============================================================================
# render_hole_circles_check.ps1 - headless render assertion for the TO-SCALE hole
# circles (Draw-HoleCircles) shown on every layout preview.
# ============================================================================
# Proves Draw-HoleCircles (a) resolves in global: scope + does not throw on null,
# (b) actually paints a crimson circle onto an off-screen Graphics, and (c) draws
# the circle TO SCALE - a larger hole diameter paints a proportionally larger circle,
# and a bigger circle than the fixed fallback dot (so the operator sees the real hole
# footprint, not a fixed marker). Runs headless (System.Drawing only, no WinForms
# message loop). Exit 0 = drawn to scale, 1 = failure. The circle analog of
# render_slot_preview_check.ps1 / render_hole_labels_check.ps1.
# ============================================================================
$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here
. (Join-Path $libDir 'orthogrid.ps1')
. (Join-Path $libDir 'orthogrid_gui.ps1')
Add-Type -AssemblyName System.Drawing -ErrorAction Stop

if ($null -eq (Get-Command Draw-HoleCircles -ErrorAction SilentlyContinue)) {
    Write-Host "  [FAIL] Draw-HoleCircles is not defined (dot-source / global scope problem)"
    exit 1
}
try { Draw-HoleCircles -Graphics $null -Points $null -OffX 0 -OffY 0 -DrawH 100 -Scale 1 -HoleDia 0.5 } catch { Write-Host "  [FAIL] Draw-HoleCircles threw on null input: $($_.Exception.Message)"; exit 1 }

# one hole at the center of a 4x4 plate, rendered on a 200x200 canvas.
$cw = 200; $ch = 200; $margin = 10.0
$pts = @([pscustomobject]@{ X = 2.0; Z = 2.0 })
$W = 4.0; $Ht = 4.0
$scale = ($cw - 2*$margin) / $W; if ((($ch - 2*$margin) / $Ht) -lt $scale) { $scale = ($ch - 2*$margin) / $Ht }
$drawW = $W * $scale; $drawH = $Ht * $scale
$offX = ($cw - $drawW) / 2.0; $offY = ($ch - $drawH) / 2.0

# count "reddish" pixels (both the translucent fill AND the crimson edge over white:
# R high, R >= G, clearly redder than blue) -> proportional to the drawn circle AREA.
function Measure-Red([double]$dia) {
    $bmp = New-Object System.Drawing.Bitmap($cw, $ch)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::White)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    Draw-HoleCircles -Graphics $g -Points $pts -OffX $offX -OffY $offY -DrawH $drawH -Scale $scale -HoleDia $dia
    $g.Dispose()
    $n = 0
    for ($x = 0; $x -lt $cw; $x++) { for ($y = 0; $y -lt $ch; $y++) {
        $p = $bmp.GetPixel($x, $y)
        if ($p.R -gt 200 -and $p.R -ge $p.G -and ($p.R - $p.B) -gt 20) { $n++ }
    } }
    $bmp.Dispose()
    return $n
}

$big   = Measure-Red 2.0    # a 2" hole in a 4" plate -> a big circle
$small = Measure-Red 0.5    # a 0.5" hole -> a much smaller circle
$dot   = Measure-Red 0.0    # unknown dia -> the fixed 6px fallback dot

# area scales with diameter^2: a 2.0 hole vs 0.5 hole is 4x the diameter -> ~16x area.
$okDrawn  = ($big -gt 200 -and $small -gt 10)
$okScales = ($big -gt ($small * 4))          # clearly larger, not a fixed size
$okVsDot  = ($small -gt $dot -or $big -gt ($dot * 4))   # the circle is a real footprint, not the marker dot
if ($okDrawn -and $okScales -and $okVsDot) {
    Write-Host "  [PASS] Draw-HoleCircles: to-scale (2.0 hole=$big px >> 0.5 hole=$small px; fallback dot=$dot px)"
    exit 0
} else {
    Write-Host "  [FAIL] Draw-HoleCircles render: big=$big (>200), small=$small (>10), scales=$okScales, vsDot(dot=$dot)=$okVsDot"
    exit 1
}
