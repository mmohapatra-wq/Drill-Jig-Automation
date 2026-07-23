# ============================================================================
# lib\bushing_svg.ps1 - bushing schematic renderer (pure math + GDI+ + SVG)
# ============================================================================
# The "render our own bushing picture from OD/ID/Length" path (research 2026-07-22:
# McMaster product images cannot be pulled by part number, so we DRAW the bushing
# ourselves from dimensions the catalog already stores). This module is the
# PowerShell home of the HTML prototype in docs\bushing_svg_preview.html, split so
# BOTH a standalone WinForms window (bushing-preview.cmd) and the eventual
# drilljig-gui.cmd bushing-pick preview call the SAME code.
#
# Layers (mirrors lib\orthogrid.ps1 / lib\orthogrid_gui.ps1):
#   * PURE MATH (no COM, no GDI+, offline-unit-testable):
#       Get-BushingFracLabel  - decimal inch -> machinist fraction ("3/4", "1 3/8")
#       Test-BushingDims      - validate OD/ID/Length (>0 and ID<OD so a wall exists)
#       Get-BushingLayout     - screen coords (side-view rects + end-view circle) for
#                               a given canvas; the analog of Get-OrthogridGeometry.
#                               BOTH the GDI+ drawer and the SVG emitter consume it,
#                               so on-screen and exported SVG are geometrically identical.
#   * RENDERERS:
#       Draw-BushingSchematic - GDI+ draw onto a System.Drawing.Graphics (WinForms).
#                               global: so a .GetNewClosure() Paint handler resolves it
#                               under the hybrid .cmd & ([scriptblock]::Create(...)) model
#                               (same reason Draw-AxisGlyph is global).
#       Get-BushingSvg        - emit an SVG string (Save-SVG / export / docs parity).
#
# Dot-source AFTER Add-Type of System.Drawing when you intend to draw:
#     Add-Type -AssemblyName System.Drawing
#     . (Join-Path $ScriptDir 'lib\bushing_svg.ps1')
# The pure helpers need no assemblies.
# ============================================================================

# ----------------------------------------------------------------------------
# Get-BushingFracLabel - decimal inch -> machinist fraction label (reverse of
# ConvertTo-Decimal; matches EasyName style). Integers -> "1"; clean 1/2,1/4,...
# up to 1/64 -> reduced fraction (with a whole part, e.g. "1 3/8"); an odd drill
# size that reduces to nothing -> 4-dp decimal. Pure. global: so GUI closures resolve it.
# ----------------------------------------------------------------------------
function global:Get-BushingFracLabel {
    param([double]$X)
    if ([double]::IsNaN($X) -or [double]::IsInfinity($X) -or $X -le 0) { return [string]$X }
    $whole = [math]::Floor($X + 1e-9)
    $frac  = $X - $whole
    if ($frac -lt 1e-6) { return [string][int]$whole }
    foreach ($den in 2,4,8,16,32,64) {
        $num = [math]::Round($frac * $den)
        if ([math]::Abs($num / $den - $frac) -lt 1e-6) {
            $n = [int]$num; $d = [int]$den
            # reduce
            $a = $n; $b = $d
            while ($b -ne 0) { $t = $b; $b = $a % $b; $a = $t }
            $g = [math]::Max(1, $a)
            $n = $n / $g; $d = $d / $g
            $f = "$n/$d"
            if ($whole -gt 0) { return "$([int]$whole) $f" } else { return $f }
        }
    }
    return [string]([math]::Round($X, 4))
}

# ----------------------------------------------------------------------------
# Test-BushingDims - validate the three driving dimensions. Returns
# @{ Ok = [bool]; Error = [string] }. A bushing needs a wall, so ID must be < OD;
# all three must be positive. Pure; mirrors the JS validate() in the HTML.
# ----------------------------------------------------------------------------
function global:Test-BushingDims {
    param([double]$OD, [double]$ID, [double]$Length)
    if (-not ($OD -gt 0) -or -not ($ID -gt 0) -or -not ($Length -gt 0)) {
        return @{ Ok = $false; Error = 'OD, ID and Length must all be greater than 0.' }
    }
    if ($ID -ge $OD) {
        return @{ Ok = $false; Error = ("Bore (ID {0}) must be smaller than OD {1} -- a bushing needs a wall." -f $ID, $OD) }
    }
    return @{ Ok = $true; Error = '' }
}

# ----------------------------------------------------------------------------
# Get-BushingHeadDia - representative HEAD diameter for a bushing, from its type.
# Removable DRILL BUSHINGS (McMaster 8493A family, EasyName "Drill Bushing | ...")
# have a HEAD (a flange at one end that seats on the jig); SLEEVES/liners (3556N,
# EasyName "Sleeve | ...") are HEADLESS. So: EasyName matching "drill bushing" ->
# a representative head OD*Factor (schematic only, NOT a catalog dimension - the
# catalog stores no head OD; the head is drawn to distinguish a headed drill
# bushing from a headless sleeve, per user 2026-07-22); anything else -> 0 (no head).
# Factor 1.35 tracks the real ASME B94.33 head sizes (3/4 OD -> ~1", 1/2 OD -> ~11/16").
# PURE. global: so the GUI's .GetNewClosure() render + the standalone tool resolve it.
function global:Get-BushingHeadDia {
    param([string]$EasyName, [double]$OD, [double]$Factor = 1.35)
    if ([string]::IsNullOrWhiteSpace($EasyName) -or $OD -le 0) { return 0.0 }
    if ($EasyName -match '(?i)drill\s*bushing') { return [math]::Round([double]$OD * $Factor, 4) }
    return 0.0
}

# ----------------------------------------------------------------------------
# Get-BushingLayout - compute screen coordinates for a bushing schematic inside a
# CanvasW x CanvasH area (top-left origin, y grows down -- the SAME convention for
# GDI+ and SVG). Auto-scales so the largest extent fills ~90% of its region. When
# ShowEnd, the canvas is split into a side-view region (left) and an end-view region
# (right); both share ONE scale so the end circle matches the side height.
# Returns a hashtable of coordinates (all doubles). PURE - no GDI+, no assemblies.
#   Bx,By          side-view (cross-section) top-left
#   Lp,ODp,IDp     side-view length / OD / ID in px
#   Cy             axis center y
#   Wall           wall thickness in px = (ODp-IDp)/2
#   BoreT,BoreB    bore band edges (y)
#   HeadW,HDp      head flange width/height in px (0 when HeadDia<=0)
#   Ecx,Ecy,Ro,Ri  end-view center + outer/inner radius (Ecx=$null when not ShowEnd)
#   Rh             end-view head radius (0 when no head)
#   Scale
# ----------------------------------------------------------------------------
function global:Get-BushingLayout {
    param(
        [double]$OD, [double]$ID, [double]$Length, [double]$HeadDia = 0.0,
        [double]$CanvasW = 660, [double]$CanvasH = 340, [bool]$ShowEnd = $true
    )
    $outerDia = [math]::Max($OD, $HeadDia)
    if ($outerDia -le 0) { $outerDia = [math]::Max($OD, 1e-6) }

    $leftMargin  = $CanvasW * 0.11
    $rightMargin = $CanvasW * 0.06
    $topMargin   = $CanvasH * 0.16
    $botMargin   = $CanvasH * 0.18
    $regionH = $CanvasH - $topMargin - $botMargin
    if ($regionH -lt 1) { $regionH = 1 }

    $ecx = $null; $ecy = $null
    if ($ShowEnd) {
        $sideRegionW = ($CanvasW - $leftMargin - $rightMargin) * 0.56
        $endX0 = $leftMargin + $sideRegionW
        $endW  = $CanvasW - $rightMargin - $endX0
        $ecx = $endX0 + $endW / 2.0
        $ecy = $topMargin + $regionH / 2.0
    } else {
        $sideRegionW = $CanvasW - $leftMargin - $rightMargin
    }
    if ($sideRegionW -lt 1) { $sideRegionW = 1 }

    # A headed drill bushing = a short HEAD segment + a BODY. The catalog Length is the
    # BODY only (from the bottom of the head to the end) -- so the head is ADDED to the
    # body axially (not carved out of it), the total axial extent = Length + head length,
    # and the Length dimension spans the BODY only (user 2026-07-22). Head axial length is
    # a representative OD*0.3 (schematic; no head dim). Headless (sleeve) -> headLenIn 0,
    # so BodyX == Bx and everything is identical to the pre-head behavior.
    # A head only makes sense if it is WIDER than the body (HeadDia > OD); a head
    # <= OD is degenerate (would sit inside the body), so treat it as headless. This
    # threshold matches Build-BushingModelGroup (3D) so 2D and 3D agree.
    $headLenIn = if ($HeadDia -gt $OD) { $OD * 0.3 } else { 0.0 }
    $axialIn   = $Length + $headLenIn
    if ($axialIn -le 0) { $axialIn = [math]::Max($Length, 1e-6) }

    $scale = [math]::Min($sideRegionW / $axialIn, $regionH / $outerDia) * 0.90
    if ($scale -le 0 -or [double]::IsNaN($scale) -or [double]::IsInfinity($scale)) { $scale = 1 }

    $Lp = $Length * $scale; $ODp = $OD * $scale; $IDp = $ID * $scale; $HDp = $HeadDia * $scale
    $headW  = $headLenIn * $scale
    $totalW = $Lp + $headW
    $bx = $leftMargin + ($sideRegionW - $totalW) / 2.0   # left edge (head start; == body start when headless)
    $bodyX = $bx + $headW                                # BODY left edge = bottom of the head
    $by = $topMargin + ($regionH - $ODp) / 2.0
    $cy = $by + $ODp / 2.0
    $wall = ($ODp - $IDp) / 2.0
    $boreT = $by + $wall
    $boreB = $by + $wall + $IDp

    return @{
        CanvasW = $CanvasW; CanvasH = $CanvasH; ShowEnd = $ShowEnd; Scale = $scale
        Bx = $bx; BodyX = $bodyX; By = $by; Lp = $Lp; ODp = $ODp; IDp = $IDp
        Cy = $cy; Wall = $wall; BoreT = $boreT; BoreB = $boreB
        HeadW = $headW; HDp = $HDp; TotalW = $totalW
        Ecx = $ecx; Ecy = $ecy; Ro = ($ODp / 2.0); Ri = ($IDp / 2.0); Rh = ($HDp / 2.0)
    }
}

# ----------------------------------------------------------------------------
# Draw-BushingSchematic - render the schematic onto a GDI+ Graphics. This is the
# WinForms path: call it from a Panel/PictureBox Paint handler with $e.Graphics.
# Draws a longitudinal cross-section (walls hatched, bore open) + optional end view
# (concentric OD/ID circles) with dimension callouts. Does NOT fill the whole
# background (the host panel's BackColor shows through the hatch gaps) - pass the
# panel's back color as -Background so the ForwardDiagonal hatch blends.
# global: + fully try/catch-wrapped so a paint failure never crashes the window
# (same contract as Draw-AxisGlyph / Draw-SlotRects).
#   $Graphics             System.Drawing.Graphics
#   OD,ID,Length,HeadDia  dimensions (inch)
#   ClientW,ClientH       panel client size (the drawing auto-fits this)
#   ShowEnd,ShowDims      toggles (default both on)
#   Background            System.Drawing.Color behind the hatch (default #202127)
#   Label                 optional caption drawn along the bottom
# ----------------------------------------------------------------------------
function global:Draw-BushingSchematic {
    param(
        $Graphics, [double]$OD, [double]$ID, [double]$Length, [double]$HeadDia = 0.0,
        [double]$ClientW, [double]$ClientH, [bool]$ShowEnd = $true, [bool]$ShowDims = $true,
        $Background = $null, [string]$Label = '', [string]$IdLabel = ''
    )
    # -IdLabel overrides the bore dimension text. Use it when the true bore is
    # indeterminate (e.g. the METAL removable-bushing path where the pick's ID is
    # "(any)" - the drilled hole is the OD and any bushing bore may be slotted in):
    # pass a representative ID for the geometry + IdLabel='(any)' so the label is honest.
    try {
        $g = $Graphics
        $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

        # colors (match docs\bushing_svg_preview.html)
        if ($null -eq $Background) { $Background = [System.Drawing.Color]::FromArgb(32, 33, 39) }   # #202127
        $steel  = [System.Drawing.Color]::FromArgb(199, 204, 212)   # #c7ccd4 outline
        $hatchC = [System.Drawing.Color]::FromArgb(90, 96, 112)     # #5a6070 hatch lines
        $bore   = [System.Drawing.Color]::FromArgb(21, 22, 26)      # #15161a bore fill
        $muted  = [System.Drawing.Color]::FromArgb(154, 160, 166)   # #9aa0a6 dims
        $idCol  = [System.Drawing.Color]::FromArgb(143, 183, 255)   # #8fb7ff id dim
        $centerC= [System.Drawing.Color]::FromArgb(107, 114, 128)   # #6b7280 centerline
        $ink    = [System.Drawing.Color]::FromArgb(231, 232, 234)   # #e7e8ea title

        $vd = Test-BushingDims -OD $OD -ID $ID -Length $Length
        if (-not $vd.Ok) {
            $fb = New-Object System.Drawing.SolidBrush($muted)
            $ff = New-Object System.Drawing.Font('Segoe UI', 10)
            $sf = New-Object System.Drawing.StringFormat
            $sf.Alignment = [System.Drawing.StringAlignment]::Center
            $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
            $g.DrawString($vd.Error, $ff, $fb, (New-Object System.Drawing.RectangleF(0, 0, [single]$ClientW, [single]$ClientH)), $sf)
            $sf.Dispose(); $ff.Dispose(); $fb.Dispose()
            return
        }

        $L = Get-BushingLayout -OD $OD -ID $ID -Length $Length -HeadDia $HeadDia -CanvasW $ClientW -CanvasH $ClientH -ShowEnd $ShowEnd

        $hatch  = New-Object System.Drawing.Drawing2D.HatchBrush([System.Drawing.Drawing2D.HatchStyle]::ForwardDiagonal, $hatchC, $Background)
        $boreBr = New-Object System.Drawing.SolidBrush($bore)
        $penOut = New-Object System.Drawing.Pen($steel, 1.8)
        $penEdge= New-Object System.Drawing.Pen($steel, 1.4)
        $penCtr = New-Object System.Drawing.Pen($centerC, 1.0)
        $penCtr.DashPattern = @([single]10, [single]3, [single]2, [single]3)
        $dia = [char]0x2300   # diameter sign
        $q   = [char]0x0022   # inch mark "

        # --- SIDE VIEW (cross-section) ---
        # Layout: HEAD segment [Bx, Bx+HeadW] then BODY [BodyX, BodyX+Lp]; bore runs
        # through both. The catalog Length is the BODY only, so the head sits BEFORE the
        # body and the Length dim (below) spans the body, NOT the head (user 2026-07-22).
        $bodyX = [double]$L.BodyX; $endX = $bodyX + $L.Lp   # body left / far end
        # head segment (wider flange) at the left - only when the head is wider than
        # the body (HeadDia > OD); L.HeadW is already 0 otherwise.
        if ($HeadDia -gt $OD -and $L.HeadW -gt 0) {
            $hy = $L.Cy - $L.HDp / 2.0
            $g.FillRectangle($hatch, [single]$L.Bx, [single]$hy, [single]$L.HeadW, [single]$L.HDp)
            $g.DrawRectangle($penOut, [single]$L.Bx, [single]$hy, [single]$L.HeadW, [single]$L.HDp)
        }
        # body: hatched wall
        $g.FillRectangle($hatch, [single]$bodyX, [single]$L.By, [single]$L.Lp, [single]$L.ODp)
        $g.DrawRectangle($penOut, [single]$bodyX, [single]$L.By, [single]$L.Lp, [single]$L.ODp)
        # bore: open channel through head + body, with solid edges
        $g.FillRectangle($boreBr, [single]$L.Bx, [single]$L.BoreT, [single]$L.TotalW, [single]$L.IDp)
        $g.DrawLine($penEdge, [single]$L.Bx, [single]$L.BoreT, [single]$endX, [single]$L.BoreT)
        $g.DrawLine($penEdge, [single]$L.Bx, [single]$L.BoreB, [single]$endX, [single]$L.BoreB)
        # axis centerline (spans head + body)
        $g.DrawLine($penCtr, [single]($L.Bx - 16), [single]$L.Cy, [single]($endX + 16), [single]$L.Cy)

        # section-label font
        $lblFont = New-Object System.Drawing.Font('Segoe UI', 8)
        $mutedBr = New-Object System.Drawing.SolidBrush($muted)
        $sfC = New-Object System.Drawing.StringFormat; $sfC.Alignment = [System.Drawing.StringAlignment]::Center
        $g.DrawString('CROSS-SECTION', $lblFont, $mutedBr, [single]($L.Bx + $L.TotalW / 2.0), [single]($L.By - $L.ODp * 0.16 - 16), $sfC)

        if ($ShowDims) {
            # local arrowed-dimension helper (local scriptblock => always in scope here,
            # no global-function-resolution worry under the hybrid .cmd model)
            $dimPen = New-Object System.Drawing.Pen($muted, 1.0)
            try { $dimPen.StartCap = [System.Drawing.Drawing2D.LineCap]::ArrowAnchor; $dimPen.EndCap = [System.Drawing.Drawing2D.LineCap]::ArrowAnchor } catch {}
            $extPen = New-Object System.Drawing.Pen($muted, 0.8)
            $dimFont = New-Object System.Drawing.Font('Segoe UI', 9)

            # LENGTH (below) - spans the BODY only (bottom-of-head -> end), NOT the head
            $dy = $L.By + $L.ODp + [math]::Min(30.0, $L.ODp * 0.22 + 14)
            $g.DrawLine($extPen, [single]$bodyX, [single]($L.By + $L.ODp), [single]$bodyX, [single]($dy + 5))
            $g.DrawLine($extPen, [single]$endX, [single]($L.By + $L.ODp), [single]$endX, [single]($dy + 5))
            $g.DrawLine($dimPen, [single]($bodyX + 1), [single]$dy, [single]($endX - 1), [single]$dy)
            $sfC2 = New-Object System.Drawing.StringFormat; $sfC2.Alignment = [System.Drawing.StringAlignment]::Center; $sfC2.LineAlignment = [System.Drawing.StringAlignment]::Far
            $g.DrawString(("L = {0}{1}" -f (Get-BushingFracLabel $Length), $q), $dimFont, $mutedBr, [single]($bodyX + $L.Lp / 2.0), [single]($dy - 4), $sfC2)

            # OD (left, vertical)
            $dx = $L.Bx - [math]::Min(30.0, $L.Lp * 0.18 + 14)
            $g.DrawLine($extPen, [single]$L.Bx, [single]$L.By, [single]($dx - 5), [single]$L.By)
            $g.DrawLine($extPen, [single]$L.Bx, [single]($L.By + $L.ODp), [single]($dx - 5), [single]($L.By + $L.ODp))
            $g.DrawLine($dimPen, [single]$dx, [single]($L.By + 1), [single]$dx, [single]($L.By + $L.ODp - 1))
            $sfR = New-Object System.Drawing.StringFormat; $sfR.Alignment = [System.Drawing.StringAlignment]::Far; $sfR.LineAlignment = [System.Drawing.StringAlignment]::Center
            $g.DrawString(("OD {0}{1}{2}" -f $dia, (Get-BushingFracLabel $OD), $q), $dimFont, $mutedBr, [single]($dx - 4), [single]$L.Cy, $sfR)

            # ID (internal, near the left quarter of the BODY bore)
            $idx = $L.BodyX + $L.Lp * 0.30
            $idPen = New-Object System.Drawing.Pen($idCol, 1.0)
            try { $idPen.StartCap = [System.Drawing.Drawing2D.LineCap]::ArrowAnchor; $idPen.EndCap = [System.Drawing.Drawing2D.LineCap]::ArrowAnchor } catch {}
            $g.DrawLine($idPen, [single]$idx, [single]($L.BoreT + 1), [single]$idx, [single]($L.BoreB - 1))
            $idBr = New-Object System.Drawing.SolidBrush($idCol)
            $sfL = New-Object System.Drawing.StringFormat; $sfL.Alignment = [System.Drawing.StringAlignment]::Near; $sfL.LineAlignment = [System.Drawing.StringAlignment]::Center
            $idText = if ($IdLabel) { "ID $IdLabel" } else { ("ID {0}{1}{2}" -f $dia, (Get-BushingFracLabel $ID), $q) }
            $g.DrawString($idText, $dimFont, $idBr, [single]($idx + 6), [single]$L.Cy, $sfL)
            $idBr.Dispose(); $idPen.Dispose()

            $dimPen.Dispose(); $extPen.Dispose(); $dimFont.Dispose()
            $sfC2.Dispose(); $sfR.Dispose(); $sfL.Dispose()
        }

        # --- END VIEW ---
        if ($ShowEnd -and $null -ne $L.Ecx) {
            $ecx = [double]$L.Ecx; $ecy = [double]$L.Ecy; $rO = [double]$L.Ro; $rI = [double]$L.Ri
            if ($HeadDia -gt $OD -and $L.Rh -gt 0) {
                $g.FillEllipse($hatch, [single]($ecx - $L.Rh), [single]($ecy - $L.Rh), [single]($L.Rh * 2), [single]($L.Rh * 2))
                $g.DrawEllipse($penEdge, [single]($ecx - $L.Rh), [single]($ecy - $L.Rh), [single]($L.Rh * 2), [single]($L.Rh * 2))
            }
            $g.FillEllipse($hatch, [single]($ecx - $rO), [single]($ecy - $rO), [single]($rO * 2), [single]($rO * 2))
            $g.DrawEllipse($penOut, [single]($ecx - $rO), [single]($ecy - $rO), [single]($rO * 2), [single]($rO * 2))
            $g.FillEllipse($boreBr, [single]($ecx - $rI), [single]($ecy - $rI), [single]($rI * 2), [single]($rI * 2))
            $g.DrawEllipse($penEdge, [single]($ecx - $rI), [single]($ecy - $rI), [single]($rI * 2), [single]($rI * 2))
            # center cross
            $g.DrawLine($penCtr, [single]($ecx - $rO - 10), [single]$ecy, [single]($ecx + $rO + 10), [single]$ecy)
            $g.DrawLine($penCtr, [single]$ecx, [single]($ecy - $rO - 10), [single]$ecx, [single]($ecy + $rO + 10))
            $g.DrawString('END VIEW', $lblFont, $mutedBr, [single]$ecx, [single]($L.By - $L.ODp * 0.16 - 16), $sfC)
            if ($ShowDims) {
                $endId = if ($IdLabel) { $IdLabel } else { ("{0}{1}{2}" -f $dia, (Get-BushingFracLabel $ID), $q) }
                $g.DrawString(("OD {0}{1}{2}  ID {3}" -f $dia, (Get-BushingFracLabel $OD), $q, $endId), $lblFont, $mutedBr, [single]$ecx, [single]($ecy + $rO + 8), $sfC)
            }
        }

        # --- title ---
        if ($Label) {
            $tBr = New-Object System.Drawing.SolidBrush($ink)
            $tFont = New-Object System.Drawing.Font('Segoe UI', 9)
            $g.DrawString($Label, $tFont, $tBr, [single]($ClientW / 2.0), [single]($ClientH - 16), $sfC)
            $tFont.Dispose(); $tBr.Dispose()
        }

        $sfC.Dispose(); $lblFont.Dispose(); $mutedBr.Dispose()
        $hatch.Dispose(); $boreBr.Dispose(); $penOut.Dispose(); $penEdge.Dispose(); $penCtr.Dispose()
    } catch {
        # a paint failure must never crash the host window
    }
}

# ----------------------------------------------------------------------------
# Get-BushingSvg - emit an SVG string for the schematic (Save-SVG / export / docs
# parity with docs\bushing_svg_preview.html). Uses the SAME Get-BushingLayout, so
# the exported SVG matches the on-screen GDI+ render. PURE (string building only).
# Returns '' when the dims are invalid. The default canvas matches the HTML
# (660x340 with end view, 460x340 without).
# ----------------------------------------------------------------------------
function global:Get-BushingSvg {
    param(
        [double]$OD, [double]$ID, [double]$Length, [double]$HeadDia = 0.0,
        [bool]$ShowEnd = $true, [bool]$ShowDims = $true, [string]$Label = ''
    )
    $vd = Test-BushingDims -OD $OD -ID $ID -Length $Length
    if (-not $vd.Ok) { return '' }
    $W = if ($ShowEnd) { 660.0 } else { 460.0 }; $H = 340.0
    $L = Get-BushingLayout -OD $OD -ID $ID -Length $Length -HeadDia $HeadDia -CanvasW $W -CanvasH $H -ShowEnd $ShowEnd
    $f = { param($n) [math]::Round([double]$n, 2) }
    $dia = [char]0x2300; $q = '&#34;'
    function esc([string]$s) { return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;') }

    $s = New-Object System.Collections.Generic.List[string]
    $s.Add(('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {0} {1}" font-family="Segoe UI, sans-serif">' -f $W, $H))
    $s.Add('<defs><pattern id="hatch" width="7" height="7" patternTransform="rotate(45)" patternUnits="userSpaceOnUse"><line x1="0" y1="0" x2="0" y2="7" stroke="#5a6070" stroke-width="1"/></pattern></defs>')
    $s.Add(('<rect x="0" y="0" width="{0}" height="{1}" fill="#202127"/>' -f $W, $H))

    # side view: HEAD segment [Bx, Bx+HeadW] + BODY [BodyX, BodyX+Lp]; bore through both.
    # Catalog Length is the BODY only, so the head sits BEFORE the body and the length
    # dim spans the BODY, not the head (mirrors Draw-BushingSchematic; user 2026-07-22).
    $bodyX = [double]$L.BodyX; $endX = $bodyX + $L.Lp
    if ($HeadDia -gt $OD -and $L.HeadW -gt 0) {
        $hy = $L.Cy - $L.HDp / 2.0
        $s.Add(('<rect x="{0}" y="{1}" width="{2}" height="{3}" fill="url(#hatch)" stroke="#c7ccd4" stroke-width="1.5"/>' -f (& $f $L.Bx), (& $f $hy), (& $f $L.HeadW), (& $f $L.HDp)))
    }
    $s.Add(('<rect x="{0}" y="{1}" width="{2}" height="{3}" fill="url(#hatch)" stroke="#c7ccd4" stroke-width="1.8"/>' -f (& $f $bodyX), (& $f $L.By), (& $f $L.Lp), (& $f $L.ODp)))
    $s.Add(('<rect x="{0}" y="{1}" width="{2}" height="{3}" fill="#15161a"/>' -f (& $f $L.Bx), (& $f $L.BoreT), (& $f $L.TotalW), (& $f $L.IDp)))
    $s.Add(('<line x1="{0}" y1="{1}" x2="{2}" y2="{1}" stroke="#c7ccd4" stroke-width="1.4"/>' -f (& $f $L.Bx), (& $f $L.BoreT), (& $f $endX)))
    $s.Add(('<line x1="{0}" y1="{1}" x2="{2}" y2="{1}" stroke="#c7ccd4" stroke-width="1.4"/>' -f (& $f $L.Bx), (& $f $L.BoreB), (& $f $endX)))
    $s.Add(('<line x1="{0}" y1="{1}" x2="{2}" y2="{1}" stroke="#6b7280" stroke-width="1" stroke-dasharray="10 3 2 3"/>' -f (& $f ($L.Bx - 16)), (& $f $L.Cy), (& $f ($endX + 16))))

    if ($ShowDims) {
        $dy = $L.By + $L.ODp + [math]::Min(30.0, $L.ODp * 0.22 + 14)
        $s.Add(('<line x1="{0}" y1="{1}" x2="{2}" y2="{1}" stroke="#9aa0a6" stroke-width="1"/>' -f (& $f $bodyX), (& $f $dy), (& $f $endX)))
        $s.Add(('<text x="{0}" y="{1}" fill="#9aa0a6" font-size="12" text-anchor="middle">L = {2}{3}</text>' -f (& $f ($bodyX + $L.Lp / 2.0)), (& $f ($dy - 5)), (Get-BushingFracLabel $Length), $q))
        $dx = $L.Bx - [math]::Min(30.0, $L.Lp * 0.18 + 14)
        $s.Add(('<line x1="{0}" y1="{1}" x2="{0}" y2="{2}" stroke="#9aa0a6" stroke-width="1"/>' -f (& $f $dx), (& $f $L.By), (& $f ($L.By + $L.ODp))))
        $s.Add(('<text x="{0}" y="{1}" fill="#9aa0a6" font-size="12" text-anchor="end">OD {2}{3}{4}</text>' -f (& $f ($dx - 4)), (& $f ($L.Cy + 4)), $dia, (Get-BushingFracLabel $OD), $q))
        $idx = $bodyX + $L.Lp * 0.30
        $s.Add(('<line x1="{0}" y1="{1}" x2="{0}" y2="{2}" stroke="#8fb7ff" stroke-width="1"/>' -f (& $f $idx), (& $f $L.BoreT), (& $f $L.BoreB)))
        $s.Add(('<text x="{0}" y="{1}" fill="#8fb7ff" font-size="12" text-anchor="start">ID {2}{3}{4}</text>' -f (& $f ($idx + 6)), (& $f ($L.Cy + 4)), $dia, (Get-BushingFracLabel $ID), $q))
    }

    if ($ShowEnd -and $null -ne $L.Ecx) {
        if ($HeadDia -gt $OD -and $L.Rh -gt 0) { $s.Add(('<circle cx="{0}" cy="{1}" r="{2}" fill="url(#hatch)" stroke="#8b92a0" stroke-width="1.2"/>' -f (& $f $L.Ecx), (& $f $L.Ecy), (& $f $L.Rh))) }
        $s.Add(('<circle cx="{0}" cy="{1}" r="{2}" fill="url(#hatch)" stroke="#c7ccd4" stroke-width="1.8"/>' -f (& $f $L.Ecx), (& $f $L.Ecy), (& $f $L.Ro)))
        $s.Add(('<circle cx="{0}" cy="{1}" r="{2}" fill="#15161a" stroke="#c7ccd4" stroke-width="1.4"/>' -f (& $f $L.Ecx), (& $f $L.Ecy), (& $f $L.Ri)))
    }
    if ($Label) { $s.Add(('<text x="{0}" y="{1}" fill="#e7e8ea" font-size="12" text-anchor="middle">{2}</text>' -f (& $f ($W / 2.0)), (& $f ($H - 14)), (esc $Label))) }
    $s.Add('</svg>')
    return ($s -join "`n")
}
