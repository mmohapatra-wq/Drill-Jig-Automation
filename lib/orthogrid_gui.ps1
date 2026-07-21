# ============================================================================
# lib\orthogrid_gui.ps1 - modal WinForms editor for an orthogrid hole pattern
# ============================================================================
# Dot-source from a hybrid .cmd AFTER lib\orthogrid.ps1 (Get-OrthogridGeometry
# must be in scope - this dialog CALLS it for ALL math and never re-derives the
# box/point arithmetic). WinForms needs an STA thread; the Windows PowerShell 5.1
# console host is STA by default, so the standard hybrid header (no -STA) is fine.
#
#     . (Join-Path $ScriptDir 'lib\orthogrid.ps1')
#     . (Join-Path $ScriptDir 'lib\orthogrid_gui.ps1')
#     $geo = Show-OrthogridDialog -Thickness $bushingLen   # $null on cancel
#
# Verified live 2026-06-23: renders correctly, the readout/preview track the
# fields through Get-OrthogridGeometry, OK gates on Valid, close returns $null.
# ============================================================================

# ----------------------------------------------------------------------------
# Draw-AxisGlyph - draw a small "X -> / Z ^" axis indicator in the BOTTOM-LEFT
# of a preview panel, matching the panel's coordinate convention: X increases to
# the RIGHT, Z increases UP (the origin / plate corner is bottom-left). The field
# labels say "X offset" / "Z offset", so the glyph uses X and Z (NOT Y) to stay
# consistent with what the operator types. Pure drawing on the passed Graphics;
# never throws (a glyph failure must not crash the preview).
#   $g  - System.Drawing.Graphics (from the paint handler's $e.Graphics)
#   $cw,$ch - the panel client width/height (so the glyph anchors to the corner)
# ----------------------------------------------------------------------------
# global: scope so .GetNewClosure() Paint handlers (drilljig-gui's inline orthogrid
# preview) resolve it under the hybrid .cmd & ([scriptblock]::Create(...)) model,
# where a dot-sourced local function is invisible to closures. Pure drawing helper.
function global:Draw-AxisGlyph {
    param($Graphics, [double]$ClientW, [double]$ClientH)
    try {
        $g = $Graphics
        $len  = 22.0          # arrow length in px
        $padX = 10.0          # inset from the left edge
        $padY = 10.0          # inset from the bottom edge
        $ox = $padX                       # origin x (left)
        $oy = $ClientH - $padY            # origin y (bottom; screen y grows down)

        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::DimGray, 1.5)
        # arrowheads
        try { $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::ArrowAnchor } catch {}

        # X axis: origin -> right
        $g.DrawLine($pen, [single]$ox, [single]$oy, [single]($ox + $len), [single]$oy)
        # Z axis: origin -> up (smaller screen y)
        $g.DrawLine($pen, [single]$ox, [single]$oy, [single]$ox, [single]($oy - $len))
        $pen.Dispose()

        # labels: "X" past the right arrow, "Z" above the up arrow.
        $font  = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
        $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::DimGray)
        $g.DrawString('X', $font, $brush, [single]($ox + $len + 1), [single]($oy - 7))
        $g.DrawString('Z', $font, $brush, [single]($ox - 5), [single]($oy - $len - 16))
        $brush.Dispose()
        $font.Dispose()
    } catch {
        # a glyph failure must never crash the preview paint
    }
}

# ----------------------------------------------------------------------------
# Draw-SlotRects - overlay the chip-relief SLOTS on a layout preview. Given a
# Get-RowSlots result (the SAME pure math slotinator / drilljig STAGE 4 use to
# cut one blind rectangular slot per hole ROW) and the panel's plate-frame ->
# screen transform (the offX/offY/drawH/scale a preview Paint already computes for
# its dots), draw each row's slot as a translucent amber band with a solid outline.
# So the operator SEES the relief cuts before they are made, in the SAME frame as
# the hole dots (X right, Z up, origin bottom-left; a slot Corner0/Corner1 are
# {X;Z} in that frame). Bands are drawn UNDER the dots (call before FillEllipse) so
# the hole centers stay visible on top.
#
#   $Graphics       - System.Drawing.Graphics from the paint handler ($e.Graphics)
#   $Slots          - a Get-RowSlots result (uses .Valid + .Rows[].Corner0/Corner1)
#   $OffX,$OffY     - the plate rectangle's top-left in panel px (preview's $offX/$offY)
#   $DrawH          - the plate rectangle's drawn height in px (preview's $drawH)
#   $Scale          - model-units -> px scale (preview's $scale)
#
# Pure drawing; NEVER throws (a slot-overlay failure must not crash the preview).
# global: scope so .GetNewClosure() Paint handlers resolve it under the hybrid
# .cmd & ([scriptblock]::Create(...)) model (same reason as Draw-AxisGlyph).
# ----------------------------------------------------------------------------
function global:Draw-SlotRects {
    param($Graphics, $Slots, [double]$OffX, [double]$OffY, [double]$DrawH, [double]$Scale)
    try {
        if ($null -eq $Slots -or -not $Slots.Valid -or $null -eq $Slots.Rows) { return }
        $g = $Graphics
        # translucent amber fill + a more-opaque amber outline (distinct from the
        # SteelBlue plate outline and the Crimson hole dots).
        $fill = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(70, 245, 200, 90))
        $pen  = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(210, 235, 170, 60), 1.0)
        foreach ($row in $Slots.Rows) {
            $c0 = $row.Corner0; $c1 = $row.Corner1
            if ($null -eq $c0 -or $null -eq $c1) { continue }
            # map both diagonal corners through the same transform the dots use
            $x0 = $OffX + ([double]$c0.X) * $Scale
            $x1 = $OffX + ([double]$c1.X) * $Scale
            $y0 = $OffY + $DrawH - ([double]$c0.Z) * $Scale
            $y1 = $OffY + $DrawH - ([double]$c1.Z) * $Scale
            $rx = [Math]::Min($x0, $x1); $ry = [Math]::Min($y0, $y1)
            $rw = [Math]::Abs($x1 - $x0); $rh = [Math]::Abs($y1 - $y0)
            if ($rw -lt 1) { $rw = 1 }
            if ($rh -lt 1) { $rh = 1 }   # a hair-thin band still shows as a line
            $g.FillRectangle($fill, [single]$rx, [single]$ry, [single]$rw, [single]$rh)
            $g.DrawRectangle($pen,  [single]$rx, [single]$ry, [single]$rw, [single]$rh)
        }
        $fill.Dispose(); $pen.Dispose()
    } catch {
        # a slot-overlay failure must never crash the preview
    }
}

# ----------------------------------------------------------------------------
# Draw-HoleLabels - number each hole 1..N on a layout preview so the operator can
# tell WHICH physical hole a "Hole #N" card / a picked datum point refers to (the
# index-hole page's problem: the choice cards say "Hole #1..#N" but the dots were
# anonymous). Numbers are drawn in the SAME plate-frame -> screen transform the
# preview dots use (X right, Z up, origin bottom-left), so label #k sits on point
# ordinal k-1 (Get-IndexHolePlan Keys are 0-based; the label is Key+1 to match the
# 1-based "Hole #N" cards). $Points is any list of {X;Z} (an OrthoGeo.Points list).
#
#   $Graphics           - System.Drawing.Graphics from the paint handler ($e.Graphics)
#   $Points             - the layout points ({X;Z}; malformed points are skipped but
#                         still consume an ordinal, so numbering stays aligned to the
#                         cards, which are also keyed by input ordinal)
#   $OffX,$OffY,$DrawH  - the plate rectangle's top-left px + drawn height (preview's
#                         $offX/$offY/$drawH)
#   $Scale              - model-units -> px scale (preview's $scale)
#   $HighlightKey       - optional 0-based ordinal to RING + colour (the chosen index
#                         hole); $null = no highlight. Matches Get-IndexHolePlan Key.
#
# Draws OVER the hole dots (call AFTER FillEllipse) so the number reads on top; the
# highlight ring is drawn under its own number. Pure drawing; NEVER throws. global:
# scope for the hybrid .cmd .GetNewClosure() Paint handlers (same reason as the
# sibling helpers above).
# ----------------------------------------------------------------------------
function global:Draw-HoleLabels {
    param($Graphics, $Points, [double]$OffX, [double]$OffY, [double]$DrawH, [double]$Scale, $HighlightKey = $null, [double]$HoleDia = 0.0)
    try {
        if ($null -eq $Points) { return }
        $g = $Graphics
        $font  = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
        $ink   = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(245,245,250))
        # a dark halo behind each number so it reads over the red hole + amber band
        $halo  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(190, 20, 26, 42))
        $hiPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(120, 210, 150), 2.0)   # green ring = chosen index
        $hiInk = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 235, 175))
        $hk = $null
        if ($null -ne $HighlightKey) { try { $hk = [int]$HighlightKey } catch { $hk = $null } }
        # holes are drawn as to-scale circles (Draw-HoleCircles); place the ring + number
        # OUTSIDE that circle so a big hole is not hidden by its own label. $HoleDia=0 ->
        # the old fixed dot, so fall back to the fixed 7px ring / +4 number offset.
        $rPx = 0.0
        if ($HoleDia -gt 0 -and $Scale -gt 0) { $rPx = ($HoleDia * $Scale) / 2.0 }
        $ringR = [Math]::Max(7.0, $rPx + 3.0)
        $lblGap = [Math]::Max(4.0, $rPx + 2.0)
        $ord = 0
        foreach ($pt in $Points) {
            $x = $null; $z = $null
            try { if ($null -ne $pt.X) { $x = [double]$pt.X } } catch {}
            try { if ($null -ne $pt.Z) { $z = [double]$pt.Z } } catch {}
            if ($null -eq $x -or $null -eq $z) { $ord++; continue }   # keep ordinal aligned to the cards
            $px = $OffX + $x * $Scale
            $py = $OffY + $DrawH - $z * $Scale
            $isHi = ($null -ne $hk -and $ord -eq $hk)
            if ($isHi) {
                # ring the chosen index hole (just outside its circle) so it stands out
                $g.DrawEllipse($hiPen, [single]($px-$ringR), [single]($py-$ringR), [single]($ringR*2), [single]($ringR*2))
            }
            $txt = [string]($ord + 1)                    # 1-based, matches "Hole #N" cards
            $sz  = $g.MeasureString($txt, $font)
            # place the number just outside the hole circle so it does not hide the center
            $lx = $px + $lblGap; $ly = $py - $sz.Height - 2
            $g.FillRectangle($halo, [single]($lx-1), [single]($ly), [single]($sz.Width+2), [single]($sz.Height))
            $g.DrawString($txt, $font, $(if ($isHi) { $hiInk } else { $ink }), [single]$lx, [single]$ly)
            $ord++
        }
        $font.Dispose(); $ink.Dispose(); $halo.Dispose(); $hiPen.Dispose(); $hiInk.Dispose()
    } catch {
        # a label failure must never crash the preview paint
    }
}

# ----------------------------------------------------------------------------
# Draw-HoleCircles - draw each hole as a TO-SCALE circle (its real drilled footprint)
# instead of a fixed marker dot (user request 2026-07-17: "draw the hole as a circle,
# instead of a dot"). The circle diameter is the hole diameter mapped through the SAME
# plate-frame -> screen transform the preview uses ($HoleDia * $Scale), so the operator
# sees the true hole size relative to the plate - and holes that would overlap (spacing
# < diameter, the collision the HoleDia check flags) visibly overlap here too. A
# translucent crimson fill + a crisp crimson edge. Falls back to the old 6px marker dot
# when $HoleDia <= 0 (diameter unknown) or the circle would be sub-pixel, so a tiny hole
# still shows. Drawn OVER the slot bands, UNDER the number labels (call after
# Draw-SlotRects, before Draw-HoleLabels). Pure drawing; NEVER throws. global: scope for
# the hybrid .cmd .GetNewClosure() Paint handlers (same reason as the sibling helpers).
#
#   $Graphics           - System.Drawing.Graphics from the paint handler ($e.Graphics)
#   $Points             - the layout points ({X;Z}; malformed points skipped)
#   $OffX,$OffY,$DrawH  - the plate rectangle's top-left px + drawn height (preview's
#                         $offX/$offY/$drawH)
#   $Scale              - model-units -> px scale (preview's $scale)
#   $HoleDia            - hole diameter in MODEL units (0 = unknown -> fixed dot)
# ----------------------------------------------------------------------------
function global:Draw-HoleCircles {
    param($Graphics, $Points, [double]$OffX, [double]$OffY, [double]$DrawH, [double]$Scale, [double]$HoleDia = 0.0)
    try {
        if ($null -eq $Points) { return }
        $g = $Graphics
        $edge = [System.Drawing.Color]::FromArgb(240, 120, 110)                 # crimson edge / dot
        $fill = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(90, 240, 120, 110))  # translucent crimson footprint
        $pen  = New-Object System.Drawing.Pen($edge, 1.25)
        $dotBr= New-Object System.Drawing.SolidBrush($edge)
        $rPx = 0.0
        if ($HoleDia -gt 0 -and $Scale -gt 0) { $rPx = ($HoleDia * $Scale) / 2.0 }
        foreach ($pt in $Points) {
            $x = $null; $z = $null
            try { if ($null -ne $pt.X) { $x = [double]$pt.X } } catch {}
            try { if ($null -ne $pt.Z) { $z = [double]$pt.Z } } catch {}
            if ($null -eq $x -or $null -eq $z) { continue }
            $px = $OffX + $x * $Scale
            $py = $OffY + $DrawH - $z * $Scale
            if ($rPx -ge 2.0) {
                $d = [single]($rPx * 2)
                $g.FillEllipse($fill, [single]($px - $rPx), [single]($py - $rPx), $d, $d)
                $g.DrawEllipse($pen,  [single]($px - $rPx), [single]($py - $rPx), $d, $d)
            } else {
                # diameter unknown or sub-pixel -> the previous small marker dot
                $g.FillEllipse($dotBr, [single]($px - 3), [single]($py - 3), 6, 6)
            }
        }
        $fill.Dispose(); $pen.Dispose(); $dotBr.Dispose()
    } catch {
        # a circle-overlay failure must never crash the preview paint
    }
}

function Show-OrthogridDialog {
    # ------------------------------------------------------------------------
    # Show-OrthogridDialog - modal WinForms editor for an orthogrid hole pattern.
    #
    # This function CALLS Get-OrthogridGeometry (lib\orthogrid.ps1, must be
    # dot-sourced first) for ALL math (box extents, point list, validity) and
    # never re-derives it.
    #
    # Returns: on OK  -> the Get-OrthogridGeometry result object (same shape),
    #                    augmented with 'Thickness' and 'HoleDiameter' members when
    #                    those were supplied for context.
    #          on Cancel / window close -> $null.
    # Never throws: all parsing goes through TryParse and the whole body is wrapped
    # so a UI failure degrades to $null rather than killing the run.
    #
    # -HoleDiameter, -ReliefDiameter and -Thickness are CONTEXT from the decision
    # tree (read-only rows): the hole Ø, the chip-relief Ø (the WIDEST feature),
    # and the drill depth / bushing length. They are shown so the operator sizes
    # the grid against the real jig numbers, and are echoed back on the result.
    # ReliefDiameter ALSO drives the plate size: it is passed to
    # Get-OrthogridGeometry as -ClearDia so the overall Box W x H clears the relief
    # circle at the border (the operator no longer hand-adds the hole dia).
    # ------------------------------------------------------------------------
    param(
        [double]$CcX            = 0.5,
        [double]$CcZ            = 0.5,
        [int]   $Nx             = 5,
        [int]   $Nz             = 4,
        [double]$Edge           = 0.5,
        [double]$Thickness      = $null,
        [double]$HoleDiameter   = $null,
        [double]$ReliefDiameter = $null
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing       -ErrorAction Stop
    } catch {
        Write-Warning "Show-OrthogridDialog: could not load WinForms assemblies: $($_.Exception.Message)"
        return $null
    }

    # Were context values supplied? (params default to $null but bind to [double],
    # which coerces $null -> 0.0; treat <=0 as "not given".)
    $hasThickness = $false
    try { if ($null -ne $Thickness    -and [double]$Thickness    -gt 0) { $hasThickness = $true } } catch { $hasThickness = $false }
    $hasHoleDia = $false
    try { if ($null -ne $HoleDiameter -and [double]$HoleDiameter -gt 0) { $hasHoleDia = $true } } catch { $hasHoleDia = $false }
    $hasReliefDia = $false
    try { if ($null -ne $ReliefDiameter -and [double]$ReliefDiameter -gt 0) { $hasReliefDia = $true } } catch { $hasReliefDia = $false }
    # Plate clearance = the HOLE diameter (user decision 2026-06-24: Edge is measured
    # from the HOLE edge, so Width = (Nx-1)*CcX + holeDia + 2*Edge). The relief dia is
    # still SHOWN as context but does NOT size the plate. 0 when no hole dia given.
    $clearDia = 0.0
    if ($hasHoleDia) { $clearDia = [double]$HoleDiameter }

    # EDGE MARGIN = THE HOLE DIAMETER (user 2026-07-21: "the edge margin ... should
    # always be the same as the diameter of the hole"). Because the plate is sized with
    # ClearDia = the hole dia, the Edge field IS the wall from a border hole's EDGE to
    # the part edge, so forcing Edge = hole dia makes that wall exactly one diameter.
    # We LOCK the field (read-only, below) so the operator sees the value but cannot
    # break the rule. Only when the hole dia is known; with no dia we keep the field
    # editable at its normal default (a standalone orthogrid with no jig context).
    $lockEdge = ($clearDia -gt 0)
    if ($lockEdge) { $Edge = $clearDia }
    # pass the SAME wall to Get-OrthogridGeometry so its check + echoed .EdgeMargin agree
    # with the locked field (one diameter); -1 (legacy one-radius) when the dia is unknown.
    $edgeMargin = if ($lockEdge) { $clearDia } else { -1.0 }

    # script-scoped live state shared by the event handlers (avoids loop-var /
    # closure-capture pitfalls - handlers read $script:* by reference, always
    # seeing the latest recompute).
    $script:ogResult   = $null      # last Get-OrthogridGeometry result
    $script:ogAccepted = $false     # set true only when OK is clicked
    $script:ogSlotWidth = $clearDia # chip-relief slot width (= hole dia); 0 = none

    # --- Form ---------------------------------------------------------------
    $form = New-Object System.Windows.Forms.Form
    $form.Text            = 'Orthogrid Hole Pattern'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.MaximizeBox     = $false
    $form.MinimizeBox     = $false
    $form.ClientSize      = New-Object System.Drawing.Size(560, 420)

    # --- Input rows ---------------------------------------------------------
    # helper to build a label + textbox at a given row
    $labelX  = 12
    $boxX    = 150
    $rowTop  = 14
    $rowStep = 30

    function New-FieldLabel {
        param($Text, $Top)
        $l = New-Object System.Windows.Forms.Label
        $l.Text     = $Text
        $l.Location = New-Object System.Drawing.Point($labelX, ($Top + 3))
        $l.Size     = New-Object System.Drawing.Size(132, 20)
        $l.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
        return $l
    }
    function New-FieldBox {
        param($Value, $Top)
        $t = New-Object System.Windows.Forms.TextBox
        $t.Location = New-Object System.Drawing.Point($boxX, $Top)
        $t.Size     = New-Object System.Drawing.Size(90, 22)
        $t.Text     = [string]$Value
        return $t
    }

    $tbCcX  = New-FieldBox $CcX  $rowTop;                  $lbCcX  = New-FieldLabel 'Center-to-center X:' $rowTop
    $r2     = $rowTop + $rowStep
    $tbCcZ  = New-FieldBox $CcZ  $r2;                      $lbCcZ  = New-FieldLabel 'Center-to-center Z:' $r2
    $r3     = $r2 + $rowStep
    $tbNx   = New-FieldBox $Nx   $r3;                      $lbNx   = New-FieldLabel 'Holes along X (Nx):' $r3
    $r4     = $r3 + $rowStep
    $tbNz   = New-FieldBox $Nz   $r4;                      $lbNz   = New-FieldLabel 'Holes along Z (Nz):' $r4
    $r5     = $r4 + $rowStep
    $tbEdge = New-FieldBox $Edge $r5
    # locked to the hole dia when a jig hole dia is known (wall = one diameter); the
    # label calls it out so the operator understands why it cannot be edited.
    $lbEdge = New-FieldLabel $(if ($lockEdge) { 'Edge margin (= hole dia):' } else { 'Edge margin:' }) $r5
    if ($lockEdge) {
        $tbEdge.ReadOnly  = $true
        $tbEdge.TabStop   = $false
        $tbEdge.BackColor = [System.Drawing.SystemColors]::Control
    }

    $form.Controls.AddRange(@($lbCcX,$tbCcX,$lbCcZ,$tbCcZ,$lbNx,$tbNx,$lbNz,$tbNz,$lbEdge,$tbEdge))

    # Optional read-only CONTEXT rows from the decision tree: hole diameter
    # (the bushing OD = the size of each hole) and thickness (drill depth /
    # bushing length). Read-only - they don't change the grid, they just keep the
    # real jig numbers in front of the operator while they size the pattern.
    $r6 = $r5 + $rowStep
    if ($hasHoleDia) {
        $lbDia = New-FieldLabel 'Hole diameter:' $r6
        $tbDia = New-FieldBox ('{0:0.###}' -f [double]$HoleDiameter) $r6
        $tbDia.ReadOnly  = $true
        $tbDia.TabStop   = $false
        $tbDia.BackColor = [System.Drawing.SystemColors]::Control
        $form.Controls.AddRange(@($lbDia,$tbDia))
        $r6 = $r6 + $rowStep
    }
    if ($hasReliefDia) {
        $lbRel = New-FieldLabel 'Chip-relief dia:' $r6
        $tbRel = New-FieldBox ('{0:0.###}' -f [double]$ReliefDiameter) $r6
        $tbRel.ReadOnly  = $true
        $tbRel.TabStop   = $false
        $tbRel.BackColor = [System.Drawing.SystemColors]::Control
        $form.Controls.AddRange(@($lbRel,$tbRel))
        $r6 = $r6 + $rowStep
    }
    if ($hasThickness) {
        $lbThk = New-FieldLabel 'Thickness (depth):' $r6
        $tbThk = New-FieldBox ('{0:0.###}' -f [double]$Thickness) $r6
        $tbThk.ReadOnly  = $true
        $tbThk.TabStop   = $false
        $tbThk.BackColor = [System.Drawing.SystemColors]::Control
        $form.Controls.AddRange(@($lbThk,$tbThk))
        $r6 = $r6 + $rowStep
    }

    # --- Live readout + error labels ---------------------------------------
    # readout is 2 lines (it can carry Part .. | N holes | K slots | hole | relief | depth,
    # long enough to wrap); error is 3 lines. Both word-wrap so nothing is clipped, and
    # the preview + form height below flow from $r6 so they can never overlap.
    $lblReadout = New-Object System.Windows.Forms.Label
    $lblReadout.Location  = New-Object System.Drawing.Point($labelX, $r6)
    $lblReadout.Size      = New-Object System.Drawing.Size(536, 40)
    $lblReadout.Font      = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($lblReadout)

    $lblError = New-Object System.Windows.Forms.Label
    $lblError.Location  = New-Object System.Drawing.Point($labelX, ($r6 + 44))
    $lblError.Size      = New-Object System.Drawing.Size(536, 54)
    $lblError.ForeColor = [System.Drawing.Color]::Firebrick
    $form.Controls.Add($lblError)

    # --- Preview panel (fixed height; everything below it flows from $r6 so the
    #     optional context rows never crush the preview) ----------------------
    $panelTop    = $r6 + 104
    $panelHeight = 150
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location    = New-Object System.Drawing.Point($labelX, $panelTop)
    $panel.Size        = New-Object System.Drawing.Size(536, $panelHeight)
    $panel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $panel.BackColor   = [System.Drawing.Color]::White
    $form.Controls.Add($panel)

    # buttons sit just under the panel; the form height is derived from them so
    # the dialog grows when the context rows are present rather than clipping.
    $btnY = $panelTop + $panelHeight + 12
    $form.ClientSize = New-Object System.Drawing.Size(560, ($btnY + 28 + 12))

    # --- OK / Cancel --------------------------------------------------------
    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text     = 'OK'
    $btnOk.Size     = New-Object System.Drawing.Size(90, 28)
    $btnOk.Location = New-Object System.Drawing.Point(360, $btnY)
    $form.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text     = 'Cancel'
    $btnCancel.Size     = New-Object System.Drawing.Size(90, 28)
    $btnCancel.Location = New-Object System.Drawing.Point(458, $btnY)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)
    $form.CancelButton = $btnCancel

    # --- Recompute / refresh ------------------------------------------------
    # Single script block reused by every TextChanged handler. Parses with
    # TryParse, calls Get-OrthogridGeometry, refreshes labels, gates OK,
    # invalidates the preview. NEVER throws.
    $updateState = {
        $cx = 0.0; $cz = 0.0; $ed = 0.0; $nxv = 0; $nzv = 0
        $okCx = [double]::TryParse($tbCcX.Text,  [ref]$cx)
        $okCz = [double]::TryParse($tbCcZ.Text,  [ref]$cz)
        $okEd = [double]::TryParse($tbEdge.Text, [ref]$ed)
        $okNx = [int]::TryParse($tbNx.Text,      [ref]$nxv)
        $okNz = [int]::TryParse($tbNz.Text,      [ref]$nzv)

        $parseErrors = @()
        if (-not $okCx) { $parseErrors += 'ccX is not a number' }
        if (-not $okCz) { $parseErrors += 'ccZ is not a number' }
        if (-not $okEd) { $parseErrors += 'edge is not a number' }
        if (-not $okNx) { $parseErrors += 'Nx is not an integer' }
        if (-not $okNz) { $parseErrors += 'Nz is not an integer' }

        $res = $null
        if ($parseErrors.Count -eq 0) {
            # ClearDia = the relief (or hole) dia so the plate Width/Height clears
            # the widest feature at the border -- the operator no longer hand-adds it.
            # HoleDia = the hole dia so a too-small ccX/ccZ (adjacent bores overlap)
            # is caught and surfaced in $lblError, gating OK.
            try { $res = Get-OrthogridGeometry -CcX $cx -CcZ $cz -Nx $nxv -Nz $nzv -Edge $ed -ClearDia $clearDia -HoleDia $clearDia -EdgeMargin $edgeMargin }
            catch { $res = $null }
        }
        $script:ogResult = $res

        $valid = $false
        if ($null -ne $res -and $res.Valid) { $valid = $true }

        if ($valid) {
            # Width/Height already include the relief clearance -> this IS the overall part dimension.
            $txt = ('Part {0:0.00} x {1:0.00}  |  {2} holes' -f $res.Width, $res.Height, $res.Count)
            if ($script:ogSlotWidth -gt 0) {
                $slN = 0
                try { $slRc = Get-RowSlots -Points $res.Points -SlotWidth $script:ogSlotWidth -Width $res.Width -Height $res.Height -RowAxis 'X'; if ($slRc.Valid) { $slN = $slRc.Count } } catch {}
                $txt = $txt + ('  |  {0} relief slot(s)' -f $slN)
            }
            if ($hasHoleDia)   { $txt = $txt + ('  |  hole {0:0.###}' -f [double]$HoleDiameter) }
            if ($hasReliefDia) { $txt = $txt + ('  |  relief {0:0.###}' -f [double]$ReliefDiameter) }
            if ($hasThickness) { $txt = $txt + ('  |  depth {0:0.00}' -f [double]$Thickness) }
            $lblReadout.Text = $txt
            $lblError.Text   = ''
        } else {
            $lblReadout.Text = ''
            if ($parseErrors.Count -gt 0) {
                $lblError.Text = ($parseErrors -join '; ')
            } elseif ($null -ne $res -and $res.Errors -and $res.Errors.Count -gt 0) {
                $lblError.Text = ($res.Errors -join '; ')
            } else {
                $lblError.Text = 'Invalid input'
            }
        }

        $btnOk.Enabled = $valid
        $panel.Invalidate()
    }

    # --- Paint handler ------------------------------------------------------
    # Draws plate outline + a dot per grid point, aspect-preserving, with margin.
    # Uses $e.Graphics (auto-disposed). Reads $script:ogResult by reference.
    $panel.Add_Paint({
        param($s, $e)
        try {
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $res = $script:ogResult
            if ($null -eq $res -or -not $res.Valid) { return }

            $w = [double]$res.Width
            $h = [double]$res.Height
            if ($w -le 0 -or $h -le 0) { return }

            $cw = $s.ClientSize.Width
            $ch = $s.ClientSize.Height
            $margin = 18.0
            $availW = $cw - 2 * $margin
            $availH = $ch - 2 * $margin
            if ($availW -le 1 -or $availH -le 1) { return }

            # aspect-preserving scale (model W:H mapped into the panel)
            $sx = $availW / $w
            $sz = $availH / $h
            $scale = $sx
            if ($sz -lt $scale) { $scale = $sz }
            if ($scale -le 0) { return }

            $drawW = $w * $scale
            $drawH = $h * $scale
            $offX  = ($cw - $drawW) / 2.0
            # model Z increases "up"; flip to screen Y (down). Origin (corner) at bottom-left.
            $offY  = ($ch - $drawH) / 2.0

            # plate outline
            $penPlate = New-Object System.Drawing.Pen([System.Drawing.Color]::SteelBlue, 1.5)
            $rx = [single]$offX
            $ry = [single]$offY
            $rw = [single]$drawW
            $rh = [single]$drawH
            $g.DrawRectangle($penPlate, $rx, $ry, $rw, $rh)
            $penPlate.Dispose()

            # chip-relief slot bands (drawn UNDER the dots) - the SAME Get-RowSlots
            # math slotinator / drilljig STAGE 4 use, so the operator sees the relief
            # cuts (one per hole row) before the geometry is made.
            if ($script:ogSlotWidth -gt 0) {
                try {
                    $slR = Get-RowSlots -Points $res.Points -SlotWidth $script:ogSlotWidth -Width $w -Height $h -RowAxis 'X'
                    Draw-SlotRects -Graphics $g -Slots $slR -OffX $offX -OffY $offY -DrawH $drawH -Scale $scale
                } catch {}
            }

            # grid points as TO-SCALE hole circles (real drilled footprint; fixed dot
            # when the hole diameter is unknown). $script:ogSlotWidth == the hole dia.
            Draw-HoleCircles -Graphics $g -Points $res.Points -OffX $offX -OffY $offY -DrawH $drawH -Scale $scale -HoleDia $script:ogSlotWidth

            # axis indicator (X -> right, Z ^ up) so the operator sees which way
            # each offset runs. Matches the field labels (X / Z) and the bottom-left
            # origin used above.
            Draw-AxisGlyph -Graphics $g -ClientW $cw -ClientH $ch
        } catch {
            # a paint failure must never crash the dialog
        }
    })

    # --- Wire field changes -------------------------------------------------
    $tbCcX.Add_TextChanged($updateState)
    $tbCcZ.Add_TextChanged($updateState)
    $tbNx.Add_TextChanged($updateState)
    $tbNz.Add_TextChanged($updateState)
    $tbEdge.Add_TextChanged($updateState)

    # --- OK behavior --------------------------------------------------------
    # Do NOT set DialogResult on the button (it would close even when disabled
    # logic is bypassed). Validate again on click, then close explicitly.
    $btnOk.Add_Click({
        & $updateState
        $res = $script:ogResult
        if ($null -ne $res -and $res.Valid) {
            $script:ogAccepted = $true
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        }
    })

    # initial compute so the dialog opens populated
    & $updateState

    # --- Show modal ---------------------------------------------------------
    $dr = $form.ShowDialog()

    $accepted = ($script:ogAccepted -and $dr -eq [System.Windows.Forms.DialogResult]::OK)
    $result   = $script:ogResult
    $form.Dispose()

    if (-not $accepted) { return $null }
    if ($null -eq $result -or -not $result.Valid) { return $null }

    # echo the context values back onto the result for downstream use
    if ($hasThickness) {
        try { $result | Add-Member -NotePropertyName 'Thickness' -NotePropertyValue ([double]$Thickness) -Force } catch { }
    }
    if ($hasHoleDia) {
        try { $result | Add-Member -NotePropertyName 'HoleDiameter' -NotePropertyValue ([double]$HoleDiameter) -Force } catch { }
    }
    if ($hasReliefDia) {
        try { $result | Add-Member -NotePropertyName 'ReliefDiameter' -NotePropertyValue ([double]$ReliefDiameter) -Force } catch { }
    }
    return $result
}

# ============================================================================
# Show-CustomPointsDialog - modal WinForms editor for an IRREGULAR (non-grid)
# hole layout: the operator adds points one at a time and types each point's
# X / Z offset from the plate corner (the SIDE base datum). This is the
# "variability" path - any layout, not just a regular Nx x Nz grid.
#
# It CALLS Get-CustomPointsGeometry (lib\orthogrid.ps1, must be dot-sourced
# first) for ALL math (plate Width/Height, validity, the normalised point list)
# and never re-derives it. The returned object is SHAPE-COMPATIBLE with
# Show-OrthogridDialog's (Mode='custom'), so every drilljig consumer works
# unchanged.
#
# Returns: on OK  -> the Get-CustomPointsGeometry result, augmented with
#                    'Thickness'/'HoleDiameter'/'ReliefDiameter' context members
#                    when supplied. on Cancel / window close -> $null.
# Never throws: parsing is TryParse-based and the whole body is wrapped so a UI
# failure degrades to $null rather than killing the run.
#
# NO EDGE MARGIN (user 2026-06-25): this offset-driven mode has no edge knob. The
# operator instead chooses how the PLATE is sized:
#   * "Derive from holes" (default) -> plate = farthest hole + ClearDia clearance,
#   * "Specify part size"           -> the operator types overall Width x Height.
# ClearDia (the relief Ø, passed by the caller) is the automatic far-side clearance
# used in the derived case. The read-only context rows (-HoleDiameter/-ReliefDiameter/
# -Thickness) mirror Show-OrthogridDialog. A point at the origin (0,0) is dropped by
# Get-CustomPointsGeometry (no hole at the part corner); the readout flags it.
# ============================================================================
function Show-CustomPointsDialog {
    param(
        [array] $InitialPoints  = $null,
        [double]$HoleDiameter   = $null,
        [double]$ReliefDiameter = $null,
        [double]$Thickness      = $null
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing       -ErrorAction Stop
    } catch {
        Write-Warning "Show-CustomPointsDialog: could not load WinForms assemblies: $($_.Exception.Message)"
        return $null
    }

    $hasThickness = $false
    try { if ($null -ne $Thickness    -and [double]$Thickness    -gt 0) { $hasThickness = $true } } catch { $hasThickness = $false }
    $hasHoleDia = $false
    try { if ($null -ne $HoleDiameter -and [double]$HoleDiameter -gt 0) { $hasHoleDia = $true } } catch { $hasHoleDia = $false }
    $hasReliefDia = $false
    try { if ($null -ne $ReliefDiameter -and [double]$ReliefDiameter -gt 0) { $hasReliefDia = $true } } catch { $hasReliefDia = $false }
    # Plate clearance = the HOLE diameter (same decision as the orthogrid dialog).
    $clearDia = 0.0
    if ($hasHoleDia) { $clearDia = [double]$HoleDiameter }
    # EDGE MARGIN = THE HOLE DIAMETER (user 2026-07-21): each border hole keeps one
    # full diameter of wall to the part edge. Passed to Get-CustomPointsGeometry so
    # the DERIVED plate grows to give that wall AND the edge check enforces it. -1
    # (legacy) when the hole dia is unknown (a standalone custom layout, no jig dia).
    $edgeMargin = if ($clearDia -gt 0) { $clearDia } else { -1.0 }

    $script:cpResult   = $null
    $script:cpAccepted = $false
    $script:cpSlotWidth = $clearDia  # chip-relief slot width (= hole dia); 0 = none

    # --- Form ---------------------------------------------------------------
    $form = New-Object System.Windows.Forms.Form
    $form.Text            = 'Custom Hole Points'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.MaximizeBox     = $false
    $form.MinimizeBox     = $false
    $form.ClientSize      = New-Object System.Drawing.Size(620, 524)

    # --- Instructions -------------------------------------------------------
    $lblHelp = New-Object System.Windows.Forms.Label
    $lblHelp.Location = New-Object System.Drawing.Point(12, 10)
    $lblHelp.Size     = New-Object System.Drawing.Size(596, 30)
    $lblHelp.Text     = "First set the INDEX hole's X/Z offset from the plate corner. Then add each" + [Environment]::NewLine +
                        "OTHER hole as an offset FROM THE INDEX hole. X runs along TOP, Z along FRONT."
    $form.Controls.Add($lblHelp)

    # --- Index-hole fields (offset from the plate corner) -------------------
    # The index hole is the ONE hole measured from the plate corner; every other hole is
    # measured from IT. This becomes Points[0] and the index-first origin the jig
    # references. Default 1.5*holeDia so the seed clears the edge-margin rule out of the box
    # (near wall = index - radius >= EdgeMargin = holeDia -> index >= 1.5*holeDia); 0.5 when
    # the hole dia is unknown.
    $ixDefault = if ($hasHoleDia) { 1.5 * [double]$HoleDiameter } else { 0.5 }
    $lblIdx = New-Object System.Windows.Forms.Label
    $lblIdx.Text      = 'Index hole (from corner):'
    $lblIdx.Location  = New-Object System.Drawing.Point(12, 42)
    $lblIdx.Size      = New-Object System.Drawing.Size(160, 20)
    $lblIdx.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $form.Controls.Add($lblIdx)
    $lblIdxX = New-Object System.Windows.Forms.Label
    $lblIdxX.Text = 'X'; $lblIdxX.Location = New-Object System.Drawing.Point(176, 44); $lblIdxX.Size = New-Object System.Drawing.Size(14, 18)
    $form.Controls.Add($lblIdxX)
    $tbIdxX = New-Object System.Windows.Forms.TextBox
    $tbIdxX.Location = New-Object System.Drawing.Point(192, 42); $tbIdxX.Size = New-Object System.Drawing.Size(58, 22)
    $tbIdxX.Text = ('{0}' -f $ixDefault)
    $form.Controls.Add($tbIdxX)
    $lblIdxZ = New-Object System.Windows.Forms.Label
    $lblIdxZ.Text = 'Z'; $lblIdxZ.Location = New-Object System.Drawing.Point(256, 44); $lblIdxZ.Size = New-Object System.Drawing.Size(14, 18)
    $form.Controls.Add($lblIdxZ)
    $tbIdxZ = New-Object System.Windows.Forms.TextBox
    $tbIdxZ.Location = New-Object System.Drawing.Point(272, 42); $tbIdxZ.Size = New-Object System.Drawing.Size(58, 22)
    $tbIdxZ.Text = ('{0}' -f $ixDefault)
    $form.Controls.Add($tbIdxZ)

    # --- Points grid (DataGridView: editable X / Z columns = offsets FROM the index) ---
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location          = New-Object System.Drawing.Point(12, 72)
    $grid.Size              = New-Object System.Drawing.Size(360, 228)
    $grid.AllowUserToAddRows = $true
    $grid.AllowUserToDeleteRows = $true
    $grid.RowHeadersVisible  = $true
    $grid.SelectionMode      = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
    $grid.EditMode           = [System.Windows.Forms.DataGridViewEditMode]::EditOnEnter

    $colX = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colX.HeaderText = 'X from index'
    $colX.Name       = 'X'
    $colZ = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colZ.HeaderText = 'Z from index'
    $colZ.Name       = 'Z'
    $grid.Columns.Add($colX) | Out-Null
    $grid.Columns.Add($colZ) | Out-Null
    $form.Controls.Add($grid)

    # seed with any initial points (e.g. when re-opening to edit)
    if ($null -ne $InitialPoints) {
        foreach ($p in $InitialPoints) {
            $px = $null; $pz = $null
            try { $px = [double]$p.X } catch {}
            try { $pz = [double]$p.Z } catch {}
            if ($null -ne $px -and $null -ne $pz) {
                $grid.Rows.Add(@(("{0}" -f $px), ("{0}" -f $pz))) | Out-Null
            }
        }
    }

    # --- Add / Remove buttons under the grid --------------------------------
    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text     = 'Add point'
    $btnAdd.Size     = New-Object System.Drawing.Size(110, 26)
    $btnAdd.Location = New-Object System.Drawing.Point(12, 306)
    $form.Controls.Add($btnAdd)

    $btnDel = New-Object System.Windows.Forms.Button
    $btnDel.Text     = 'Remove selected'
    $btnDel.Size     = New-Object System.Drawing.Size(130, 26)
    $btnDel.Location = New-Object System.Drawing.Point(128, 306)
    $form.Controls.Add($btnDel)

    # --- Part-size choice: derive from holes (default) OR specify W x H ------
    # Two radio buttons; the explicit W/H boxes enable only when "Specify" is on.
    $rbDerive = New-Object System.Windows.Forms.RadioButton
    $rbDerive.Text     = 'Size part from holes'
    $rbDerive.Location = New-Object System.Drawing.Point(12, 340)
    $rbDerive.Size     = New-Object System.Drawing.Size(180, 20)
    $rbDerive.Checked  = $true
    $form.Controls.Add($rbDerive)

    $rbExplicit = New-Object System.Windows.Forms.RadioButton
    $rbExplicit.Text     = 'Specify part size:'
    $rbExplicit.Location = New-Object System.Drawing.Point(12, 364)
    $rbExplicit.Size     = New-Object System.Drawing.Size(130, 20)
    $form.Controls.Add($rbExplicit)

    $lblW = New-Object System.Windows.Forms.Label
    $lblW.Text      = 'W'
    $lblW.Location  = New-Object System.Drawing.Point(146, 366)
    $lblW.Size      = New-Object System.Drawing.Size(16, 18)
    $form.Controls.Add($lblW)
    $tbW = New-Object System.Windows.Forms.TextBox
    $tbW.Location = New-Object System.Drawing.Point(164, 364)
    $tbW.Size     = New-Object System.Drawing.Size(58, 22)
    $tbW.Enabled  = $false
    $form.Controls.Add($tbW)

    $lblH = New-Object System.Windows.Forms.Label
    $lblH.Text      = 'H'
    $lblH.Location  = New-Object System.Drawing.Point(228, 366)
    $lblH.Size      = New-Object System.Drawing.Size(16, 18)
    $form.Controls.Add($lblH)
    $tbH = New-Object System.Windows.Forms.TextBox
    $tbH.Location = New-Object System.Drawing.Point(246, 364)
    $tbH.Size     = New-Object System.Drawing.Size(58, 22)
    $tbH.Enabled  = $false
    $form.Controls.Add($tbH)

    # --- Context rows (read-only) on the right column -----------------------
    $ctxY = 50
    $mkCtx = {
        param($Caption, $Value, $Top)
        $l = New-Object System.Windows.Forms.Label
        $l.Text      = $Caption
        $l.Location  = New-Object System.Drawing.Point(392, ($Top + 3))
        $l.Size      = New-Object System.Drawing.Size(120, 20)
        $l.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
        $t = New-Object System.Windows.Forms.TextBox
        $t.Location  = New-Object System.Drawing.Point(516, $Top)
        $t.Size      = New-Object System.Drawing.Size(86, 22)
        $t.Text      = $Value
        $t.ReadOnly  = $true
        $t.TabStop   = $false
        $t.BackColor = [System.Drawing.SystemColors]::Control
        $form.Controls.AddRange(@($l, $t))
    }
    if ($hasHoleDia)   { & $mkCtx 'Hole diameter:'    ('{0:0.###}' -f [double]$HoleDiameter)   $ctxY; $ctxY += 30 }
    if ($hasReliefDia) { & $mkCtx 'Chip-relief dia:'  ('{0:0.###}' -f [double]$ReliefDiameter) $ctxY; $ctxY += 30 }
    if ($hasThickness) { & $mkCtx 'Thickness (depth):'('{0:0.###}' -f [double]$Thickness)      $ctxY; $ctxY += 30 }

    # --- Preview panel (right side) -----------------------------------------
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location    = New-Object System.Drawing.Point(392, ([Math]::Max($ctxY, 80)))
    $panel.Size        = New-Object System.Drawing.Size(210, 190)
    $panel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $panel.BackColor   = [System.Drawing.Color]::White
    $form.Controls.Add($panel)

    # --- Live readout + error labels ----------------------------------------
    # 2 lines: the index-relative readout (Part .. | index @ (..) + N more = M | K slots)
    # is long enough to wrap, so a 1-line box clipped its second line.
    $lblReadout = New-Object System.Windows.Forms.Label
    $lblReadout.Location = New-Object System.Drawing.Point(12, 372)
    $lblReadout.Size     = New-Object System.Drawing.Size(596, 40)
    $lblReadout.Font     = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($lblReadout)

    # 3 lines + word-wrap so a long / combined validation message is shown in full.
    $lblError = New-Object System.Windows.Forms.Label
    $lblError.Location  = New-Object System.Drawing.Point(12, 416)
    $lblError.Size      = New-Object System.Drawing.Size(596, 48)
    $lblError.ForeColor = [System.Drawing.Color]::Firebrick
    $form.Controls.Add($lblError)

    # --- OK / Cancel --------------------------------------------------------
    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text     = 'OK'
    $btnOk.Size     = New-Object System.Drawing.Size(90, 28)
    $btnOk.Location = New-Object System.Drawing.Point(420, 484)
    $form.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text     = 'Cancel'
    $btnCancel.Size     = New-Object System.Drawing.Size(90, 28)
    $btnCancel.Location = New-Object System.Drawing.Point(518, 484)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)
    $form.CancelButton = $btnCancel

    # --- read the grid into a {X;Z} array (TryParse; skips blank/partial rows) ---
    $readGridPoints = {
        $pts = @()
        foreach ($row in $grid.Rows) {
            if ($row.IsNewRow) { continue }
            $xs = $null; $zs = $null
            try { $xs = [string]$row.Cells['X'].Value } catch {}
            try { $zs = [string]$row.Cells['Z'].Value } catch {}
            if ([string]::IsNullOrWhiteSpace($xs) -and [string]::IsNullOrWhiteSpace($zs)) { continue }
            $xv = 0.0; $zv = 0.0
            $okx = [double]::TryParse($xs, [ref]$xv)
            $okz = [double]::TryParse($zs, [ref]$zv)
            # keep partial/bad rows as objects WITHOUT numeric X/Z so the math layer
            # reports them as errors (rather than silently dropping a typo'd row).
            if ($okx -and $okz) {
                $pts += [pscustomobject]@{ X = [double]$xv; Z = [double]$zv }
            } else {
                $pts += [pscustomobject]@{ X = $null; Z = $null }
            }
        }
        return ,@($pts)
    }

    # --- recompute / refresh ------------------------------------------------
    $updateState = {
        # explicit W/H boxes are live only when "Specify part size" is checked.
        $explicit = $rbExplicit.Checked
        $tbW.Enabled = $explicit
        $tbH.Enabled = $explicit

        # grid rows are the OTHER holes' offsets FROM THE INDEX hole.
        $pts = & $readGridPoints

        # index hole = the ONE hole measured from the plate corner. Parse both fields;
        # a bad/blank index field is a parse error surfaced below (blocks OK).
        $ixv = 0.0; $izv = 0.0
        $idxErrs = @()
        if (-not ([double]::TryParse($tbIdxX.Text, [ref]$ixv))) { $idxErrs += 'a numeric index X' }
        if (-not ([double]::TryParse($tbIdxZ.Text, [ref]$izv))) { $idxErrs += 'a numeric index Z' }
        $idxParseErr = if ($idxErrs.Count -gt 0) { 'Enter ' + ($idxErrs -join ' and ') + ' (offset from the corner)' } else { $null }

        # resolve the size overrides ($null -> derive). Only parse when explicit;
        # a blank/garbage box in explicit mode is a parse error surfaced below.
        # Collect W and H errors INDEPENDENTLY (not elseif) so a bad W never masks a
        # bad H -- the user sees every field that needs fixing in one pass.
        $wOver = $null; $hOver = $null
        $sizeErrs = @()
        if ($explicit) {
            $wv = 0.0; $hv = 0.0
            if ([double]::TryParse($tbW.Text, [ref]$wv) -and $wv -gt 0) { $wOver = $wv } else { $sizeErrs += 'positive part width' }
            if ([double]::TryParse($tbH.Text, [ref]$hv) -and $hv -gt 0) { $hOver = $hv } else { $sizeErrs += 'positive part height' }
        }
        $sizeParseErr = if ($sizeErrs.Count -gt 0) { 'Enter ' + ($sizeErrs -join ' and ') } else { $null }

        $res = $null
        # INDEX-RELATIVE: the index hole (ixv,izv) is measured from the corner; the grid
        # rows are offsets FROM the index. Get-IndexRelativeCustomGeometry converts to the
        # absolute {X;Z} list Get-CustomPointsGeometry consumes (index at Points[0]) and
        # tags the result IndexRelative/IndexGridX/IndexGridZ. HoleDia = the hole dia so
        # overlapping bores are caught and surfaced in $lblError, gating OK.
        if ($null -eq $idxParseErr) {
            try { $res = Get-IndexRelativeCustomGeometry -IndexX $ixv -IndexZ $izv -OtherPoints $pts -ClearDia $clearDia -WidthOverride $wOver -HeightOverride $hOver -HoleDia $clearDia -EdgeMargin $edgeMargin } catch { $res = $null }
        }
        $script:cpResult = $res

        $valid = ($null -ne $res -and $res.Valid)
        if ($null -ne $idxParseErr) {
            $lblReadout.Text = ''
            $lblError.ForeColor = [System.Drawing.Color]::Firebrick
            $lblError.Text   = $idxParseErr
            $btnOk.Enabled   = $false
        } elseif ($explicit -and $null -ne $sizeParseErr) {
            $lblReadout.Text = ''
            $lblError.ForeColor = [System.Drawing.Color]::Firebrick
            $lblError.Text   = $sizeParseErr
            $btnOk.Enabled   = $false
        } elseif ($valid) {
            $sizeTag = if ($res.WidthMode -eq 'explicit') { 'specified' } else { 'from holes' }
            # Count includes the index hole (Points[0]); show it explicitly so the
            # operator sees index + others all drill.
            $txt = ('Part {0:0.00} x {1:0.00} ({2})  |  index @ ({3:0.###},{4:0.###}) + {5} more = {6} hole(s)' -f `
                $res.Width, $res.Height, $sizeTag, $res.IndexGridX, $res.IndexGridZ, ($res.Count - 1), $res.Count)
            if ($script:cpSlotWidth -gt 0) {
                $slN = 0
                try { $slRc = Get-RowSlots -Points $res.Points -SlotWidth $script:cpSlotWidth -Width $res.Width -Height $res.Height -RowAxis 'X'; if ($slRc.Valid) { $slN = $slRc.Count } } catch {}
                $txt += ('  |  {0} relief slot(s)' -f $slN)
            }
            if ($hasHoleDia)   { $txt += ('  |  hole {0:0.###}' -f [double]$HoleDiameter) }
            if ($hasReliefDia) { $txt += ('  |  relief {0:0.###}' -f [double]$ReliefDiameter) }
            if ($hasThickness) { $txt += ('  |  depth {0:0.00}' -f [double]$Thickness) }
            $lblReadout.Text = $txt
            $lblError.Text = ''
            $btnOk.Enabled   = $true
        } else {
            $lblReadout.Text = ''
            $lblError.ForeColor = [System.Drawing.Color]::Firebrick
            if ($null -ne $res -and $res.Errors -and $res.Errors.Count -gt 0) {
                $lblError.Text = ($res.Errors | Select-Object -First 2) -join '; '
            } else {
                $lblError.Text = 'Add at least one point with numeric X / Z'
            }
            $btnOk.Enabled   = $false
        }
        $panel.Invalidate()
    }

    # --- preview paint ------------------------------------------------------
    $panel.Add_Paint({
        param($s, $e)
        try {
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $res = $script:cpResult
            if ($null -eq $res -or -not $res.Valid) { return }
            $w = [double]$res.Width; $h = [double]$res.Height
            if ($w -le 0 -or $h -le 0) { return }
            $cw = $s.ClientSize.Width; $ch = $s.ClientSize.Height
            $margin = 14.0
            $availW = $cw - 2 * $margin; $availH = $ch - 2 * $margin
            if ($availW -le 1 -or $availH -le 1) { return }
            $scale = $availW / $w
            if (($availH / $h) -lt $scale) { $scale = $availH / $h }
            if ($scale -le 0) { return }
            $drawW = $w * $scale; $drawH = $h * $scale
            $offX = ($cw - $drawW) / 2.0; $offY = ($ch - $drawH) / 2.0
            $penPlate = New-Object System.Drawing.Pen([System.Drawing.Color]::SteelBlue, 1.5)
            $g.DrawRectangle($penPlate, [single]$offX, [single]$offY, [single]$drawW, [single]$drawH)
            $penPlate.Dispose()
            # chip-relief slot bands (drawn UNDER the dots) - same Get-RowSlots math as slotinator.
            if ($script:cpSlotWidth -gt 0) {
                try {
                    $slR = Get-RowSlots -Points $res.Points -SlotWidth $script:cpSlotWidth -Width $w -Height $h -RowAxis 'X'
                    Draw-SlotRects -Graphics $g -Slots $slR -OffX $offX -OffY $offY -DrawH $drawH -Scale $scale
                } catch {}
            }
            # grid points as TO-SCALE hole circles (fixed dot when the dia is unknown).
            # $script:cpSlotWidth == the hole dia.
            Draw-HoleCircles -Graphics $g -Points $res.Points -OffX $offX -OffY $offY -DrawH $drawH -Scale $scale -HoleDia $script:cpSlotWidth

            # axis indicator (X -> right, Z ^ up) matching the X/Z offset fields.
            Draw-AxisGlyph -Graphics $g -ClientW $cw -ClientH $ch
        } catch { }
    })

    # --- wire events --------------------------------------------------------
    $btnAdd.Add_Click({ $grid.Rows.Add(@('0', '0')) | Out-Null; & $updateState })
    $btnDel.Add_Click({
        $toRemove = @()
        foreach ($cell in $grid.SelectedCells) {
            $r = $grid.Rows[$cell.RowIndex]
            if (-not $r.IsNewRow -and ($toRemove -notcontains $r)) { $toRemove += $r }
        }
        foreach ($r in $toRemove) { $grid.Rows.Remove($r) }
        & $updateState
    })
    $grid.Add_CellValueChanged({ & $updateState })
    $grid.Add_RowsAdded({ & $updateState })
    $grid.Add_RowsRemoved({ & $updateState })
    $rbDerive.Add_CheckedChanged($updateState)
    $rbExplicit.Add_CheckedChanged($updateState)
    $tbW.Add_TextChanged($updateState)
    $tbH.Add_TextChanged($updateState)
    $tbIdxX.Add_TextChanged($updateState)
    $tbIdxZ.Add_TextChanged($updateState)

    $btnOk.Add_Click({
        & $updateState
        $res = $script:cpResult
        if ($null -ne $res -and $res.Valid) {
            $script:cpAccepted = $true
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        }
    })

    & $updateState
    $dr = $form.ShowDialog()

    $accepted = ($script:cpAccepted -and $dr -eq [System.Windows.Forms.DialogResult]::OK)
    $result   = $script:cpResult
    $form.Dispose()

    if (-not $accepted) { return $null }
    if ($null -eq $result -or -not $result.Valid) { return $null }

    if ($hasThickness)  { try { $result | Add-Member -NotePropertyName 'Thickness'      -NotePropertyValue ([double]$Thickness)      -Force } catch { } }
    if ($hasHoleDia)    { try { $result | Add-Member -NotePropertyName 'HoleDiameter'   -NotePropertyValue ([double]$HoleDiameter)   -Force } catch { } }
    if ($hasReliefDia)  { try { $result | Add-Member -NotePropertyName 'ReliefDiameter' -NotePropertyValue ([double]$ReliefDiameter) -Force } catch { } }
    return $result
}
