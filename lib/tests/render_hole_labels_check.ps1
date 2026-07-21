# ============================================================================
# render_hole_labels_check.ps1 - headless render assertion for the numbered
# hole labels (Draw-HoleLabels) shown on the index-hole layout previews.
# ============================================================================
# Proves Draw-HoleLabels actually executes against a real Graphics surface and
# paints hole NUMBERS + a highlight ring (not just that the function is defined).
# Creates an off-screen bitmap, builds a real orthogrid, and calls Draw-HoleLabels
# through the SAME plate-frame -> screen transform the index-hole preview uses,
# then confirms ink pixels landed (numbers) and green highlight-ring pixels landed
# (the chosen index hole). Runs headless (System.Drawing only, NO WinForms message
# loop) so it never hangs like the interactive wizard-drive test. Exit 0 = drawn,
# 1 = failure. This is the evidence the response-convergence harness can see for
# the numbered index-hole preview (the analog of render_slot_preview_check.ps1).
# ============================================================================
$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here
. (Join-Path $libDir 'orthogrid.ps1')
. (Join-Path $libDir 'orthogrid_gui.ps1')
Add-Type -AssemblyName System.Drawing -ErrorAction Stop

if ($null -eq (Get-Command Draw-HoleLabels -ErrorAction SilentlyContinue)) {
    Write-Host "  [FAIL] Draw-HoleLabels is not defined (dot-source / global scope problem)"
    exit 1
}

# no-throw guards (null points / null graphics must degrade, never crash the paint)
try { Draw-HoleLabels -Graphics $null -Points $null -OffX 0 -OffY 0 -DrawH 100 -Scale 1 } catch { Write-Host "  [FAIL] Draw-HoleLabels threw on null input: $($_.Exception.Message)"; exit 1 }

# a 3x3 grid at 2" pitch -> 9 numbered holes; highlight key 4 = the center hole.
$geo = Get-OrthogridGeometry -CcX 2.0 -CcZ 2.0 -Nx 3 -Nz 3 -Edge 2.0 -ClearDia 0.75
if (-not $geo.Valid -or @($geo.Points).Count -lt 9) {
    Write-Host "  [FAIL] sample layout invalid (Valid=$($geo.Valid), Count=$(@($geo.Points).Count))"
    exit 1
}

# canvas px are $cw/$ch (NOT $W/$H): PowerShell vars are case-insensitive, so a $W
# canvas + a $w=[double]$geo.Width model dim are the SAME variable and collide (the
# model dim clobbers the canvas -> negative scale). The preview uses $cw/$ch vs
# $w/$h to avoid exactly this; mirror it.
$cw = 320; $ch = 200; $margin = 20.0
$bmp = New-Object System.Drawing.Bitmap($cw, $ch)
$g   = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::White)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

# replicate the preview transform (aspect-preserving; plate-frame origin bottom-left)
$w = [double]$geo.Width; $h = [double]$geo.Height
$scale = ($cw - 2*$margin) / $w
if ((($ch - 2*$margin) / $h) -lt $scale) { $scale = ($ch - 2*$margin) / $h }
$drawW = $w * $scale; $drawH = $h * $scale
$offX = ($cw - $drawW) / 2.0; $offY = ($ch - $drawH) / 2.0

$hlKey = 4   # ring the 5th hole (0-based ordinal 4)
Draw-HoleLabels -Graphics $g -Points $geo.Points -OffX $offX -OffY $offY -DrawH $drawH -Scale $scale -HighlightKey $hlKey
$g.Dispose()

# count (a) dark number-halo pixels (halo box ARGB(190,20,26,42) over white = dark
# bluish) and (b) green highlight-ring pixels (ARGB green ~ (120,210,150)). ALSO verify
# POSITIONAL alignment: the ring for HighlightKey k must land on Points[k], not just
# "somewhere" - so bucket the green pixels near the expected dot vs. away from it. This
# locks the ordinal->screen mapping (a transform/ordinal regression would move the ring).
$exX = $offX + ([double]$geo.Points[$hlKey].X) * $scale
$exY = $offY + $drawH - ([double]$geo.Points[$hlKey].Z) * $scale
$nearR = 20.0    # px radius that comfortably contains the 14px ring + tinted number
$halo = 0; $green = 0; $greenNear = 0; $greenFar = 0
for ($x = 0; $x -lt $cw; $x++) {
    for ($y = 0; $y -lt $ch; $y++) {
        $px = $bmp.GetPixel($x, $y)
        # dark halo behind a number: low-ish R/B, all channels well below white
        if ($px.R -lt 120 -and $px.G -lt 130 -and $px.B -lt 160 -and ($px.R + $px.G + $px.B) -lt 330) { $halo++ }
        # green highlight ring: G clearly dominant, R/B moderate
        if ($px.G -gt 150 -and $px.G -gt ($px.R + 30) -and $px.G -gt ($px.B + 30)) {
            $green++
            $d = [Math]::Sqrt(($x - $exX)*($x - $exX) + ($y - $exY)*($y - $exY))
            if ($d -le $nearR) { $greenNear++ } else { $greenFar++ }
        }
    }
}
$bmp.Dispose()

$okHalo  = ($halo -gt 40)                       # 9 number halos -> plenty of dark pixels
$okGreen = ($green -gt 15)                       # the highlight ring around hole #5 (key 4)
$okAlign = ($greenNear -gt 15 -and $greenFar -eq 0)   # ALL green is at Points[4], none elsewhere
if ($okHalo -and $okGreen -and $okAlign) {
    Write-Host "  [PASS] Draw-HoleLabels: $halo halo px, $green green px, ring aligned on hole #$($hlKey+1) ($greenNear near / $greenFar far)"
    exit 0
} else {
    Write-Host "  [FAIL] Draw-HoleLabels render: halo=$halo (>40), green=$green (>15), alignNear=$greenNear (>15), alignFar=$greenFar (==0)"
    exit 1
}
