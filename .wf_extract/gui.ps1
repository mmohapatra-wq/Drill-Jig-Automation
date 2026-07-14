function Show-OrthogridDialog {
    # ------------------------------------------------------------------------
    # Show-OrthogridDialog - modal WinForms editor for an orthogrid hole pattern.
    #
    # Spliced INLINE into drilljig.cmd, dot-sourced AFTER lib\orthogrid.ps1 so
    # Get-OrthogridGeometry is in scope. This function CALLS that helper for ALL
    # math (box extents, point list, validity) and never re-derives it.
    #
    # Returns: on OK  -> the Get-OrthogridGeometry result object (same shape),
    #                    augmented with a 'Thickness' member when a thickness was
    #                    supplied for context.
    #          on Cancel / window close -> $null.
    # Never throws: all parsing goes through TryParse and the whole body is wrapped
    # so a UI failure degrades to $null rather than killing the run.
    # ------------------------------------------------------------------------
    param(
        [double]$CcX       = 0.5,
        [double]$CcZ       = 0.5,
        [int]   $Nx        = 5,
        [int]   $Nz        = 4,
        [double]$Edge      = 0.5,
        [double]$Thickness = $null
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing       -ErrorAction Stop
    } catch {
        Write-Warning "Show-OrthogridDialog: could not load WinForms assemblies: $($_.Exception.Message)"
        return $null
    }

    # Was a thickness supplied? ($Thickness defaults to $null but binds to a
    # [double] param, which coerces $null -> 0.0; treat <=0 as "not provided".)
    $hasThickness = $false
    try { if ($null -ne $Thickness -and [double]$Thickness -gt 0) { $hasThickness = $true } } catch { $hasThickness = $false }

    # script-scoped live state shared by the event handlers (avoids loop-var /
    # closure-capture pitfalls - handlers read $script:* by reference, always
    # seeing the latest recompute).
    $script:ogResult   = $null      # last Get-OrthogridGeometry result
    $script:ogAccepted = $false     # set true only when OK is clicked

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
    $tbEdge = New-FieldBox $Edge $r5;                      $lbEdge = New-FieldLabel 'Edge margin:' $r5

    $form.Controls.AddRange(@($lbCcX,$tbCcX,$lbCcZ,$tbCcZ,$lbNx,$tbNx,$lbNz,$tbNz,$lbEdge,$tbEdge))

    # Optional read-only thickness (context only - bushing length / drill depth)
    $r6 = $r5 + $rowStep
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
    $lblReadout = New-Object System.Windows.Forms.Label
    $lblReadout.Location  = New-Object System.Drawing.Point($labelX, $r6)
    $lblReadout.Size      = New-Object System.Drawing.Size(536, 20)
    $lblReadout.Font      = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($lblReadout)

    $lblError = New-Object System.Windows.Forms.Label
    $lblError.Location  = New-Object System.Drawing.Point($labelX, ($r6 + 22))
    $lblError.Size      = New-Object System.Drawing.Size(536, 36)
    $lblError.ForeColor = [System.Drawing.Color]::Firebrick
    $form.Controls.Add($lblError)

    # --- Preview panel ------------------------------------------------------
    $panelTop = $r6 + 62
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location    = New-Object System.Drawing.Point($labelX, $panelTop)
    $panel.Size        = New-Object System.Drawing.Size(536, (340 - $panelTop))
    $panel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $panel.BackColor   = [System.Drawing.Color]::White
    $form.Controls.Add($panel)

    # --- OK / Cancel --------------------------------------------------------
    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text     = 'OK'
    $btnOk.Size     = New-Object System.Drawing.Size(90, 28)
    $btnOk.Location = New-Object System.Drawing.Point(360, 352)
    $form.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text     = 'Cancel'
    $btnCancel.Size     = New-Object System.Drawing.Size(90, 28)
    $btnCancel.Location = New-Object System.Drawing.Point(458, 352)
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
            try { $res = Get-OrthogridGeometry -CcX $cx -CcZ $cz -Nx $nxv -Nz $nzv -Edge $ed }
            catch { $res = $null }
        }
        $script:ogResult = $res

        $valid = $false
        if ($null -ne $res -and $res.Valid) { $valid = $true }

        if ($valid) {
            $txt = ('Box {0:0.00} x {1:0.00}  |  {2} holes' -f $res.Width, $res.Height, $res.Count)
            if ($hasThickness) { $txt = $txt + ('  |  thickness {0:0.00}' -f [double]$Thickness) }
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

            # grid points
            $dot   = 3.5
            $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Crimson)
            foreach ($pt in $res.Points) {
                $px = $offX + ([double]$pt.X) * $scale
                # flip Z so larger Z is nearer the top of the panel
                $py = $offY + $drawH - ([double]$pt.Z) * $scale
                $ex = [single]($px - $dot)
                $ey = [single]($py - $dot)
                $g.FillEllipse($brush, $ex, $ey, [single]($dot * 2), [single]($dot * 2))
            }
            $brush.Dispose()
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

    # augment with the chosen thickness for downstream depth use
    if ($hasThickness) {
        try { $result | Add-Member -NotePropertyName 'Thickness' -NotePropertyValue ([double]$Thickness) -Force } catch { }
    }
    return $result
}