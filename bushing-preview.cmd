<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
echo.
exit /b %errorlevel%
#>

# ============================================================================
# bushing-preview.cmd - standalone WinForms preview of the bushing schematic
# ============================================================================
# TEST HARNESS (no Creo, no connection). Renders the drill-jig bushing schematic
# in a native Windows PowerShell / WinForms window using GDI+, to prove the
# "draw our own bushing from OD/ID/Length" idea works OUTSIDE the browser (the
# HTML prototype is docs\bushing_svg_preview.html) and in the exact tech the
# drilljig-gui.cmd wizard uses. If this looks right, Draw-BushingSchematic drops
# straight into the wizard's bushing-pick step.
#
# Run it: double-click bushing-preview.cmd, or `.\bushing-preview.cmd`.
# All drawing goes through lib\bushing_svg.ps1 (Draw-BushingSchematic / Get-BushingSvg),
# the SAME code a future drilljig integration would call.
# ============================================================================

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

. (Join-Path $ScriptDir 'lib\bushing_svg.ps1')

# --- dark theme (matches lib\wizard.ps1 WizTheme) ---
$cFormBack = [System.Drawing.Color]::FromArgb(20, 30, 52)
$cPanel    = [System.Drawing.Color]::FromArgb(30, 42, 68)
$cField    = [System.Drawing.Color]::FromArgb(40, 54, 84)
$cInk      = [System.Drawing.Color]::FromArgb(238, 242, 248)
$cMuted    = [System.Drawing.Color]::FromArgb(158, 172, 196)
$cAccent   = [System.Drawing.Color]::FromArgb(64, 132, 232)
$cPreview  = [System.Drawing.Color]::FromArgb(32, 33, 39)   # #202127, same as the SVG canvas
$cErr      = [System.Drawing.Color]::FromArgb(245, 120, 110)
$fUI       = New-Object System.Drawing.Font('Segoe UI', 9)

# --- real catalog presets (from data\bushings.csv + data\bushings_drill.csv) ---
# The last row is an OD-3/4 removable bushing whose PN was blanked+flagged 2026-07-22
# (real McMaster number was clipped from the source PDF) -> exercises the no-PN path.
$presets = @(
    [pscustomobject]@{ Name='Sleeve | OD 3/4 x ID 1/2 x 5/16 Lg';  OD=0.75; ID=0.5;   Len=0.3125; PN='3556N155' }
    [pscustomobject]@{ Name='Sleeve | OD 3/4 x ID 1/2 x 3/4 Lg';   OD=0.75; ID=0.5;   Len=0.75;   PN='3556N158' }
    [pscustomobject]@{ Name='Sleeve | OD 1 x ID 3/4 x 3/8 Lg';     OD=1.0;  ID=0.75;  Len=0.375;  PN='3556N179' }
    [pscustomobject]@{ Name='Drill Bushing | OD 1/4 x ID 0.125 x 1/4 Lg'; OD=0.25; ID=0.125; Len=0.25; PN='8493A002' }
    [pscustomobject]@{ Name='Drill Bushing | OD 1/2 x ID 0.25 x 1/4 Lg';  OD=0.5;  ID=0.25;  Len=0.25; PN='8493A072' }
    [pscustomobject]@{ Name='Drill Bushing | OD 3/4 x ID 1/2 x 3/4 Lg (removable, PN unverified)'; OD=0.75; ID=0.5; Len=0.75; PN='' }
)

# --- form ---
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Bushing SVG Schematic - WinForms/GDI+ preview'
$form.Size = New-Object System.Drawing.Size(1000, 560)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $cFormBack
$form.ForeColor = $cInk
$form.Font = $fUI
$form.MinimumSize = New-Object System.Drawing.Size(760, 440)

# left control column
$left = New-Object System.Windows.Forms.Panel
$left.Dock = 'Left'; $left.Width = 300; $left.BackColor = $cPanel; $left.Padding = New-Object System.Windows.Forms.Padding(14)
$form.Controls.Add($left)

# preview (fills the rest)
$preview = New-Object System.Windows.Forms.Panel
$preview.Dock = 'Fill'; $preview.BackColor = $cPreview
$form.Controls.Add($preview)
$form.Controls.SetChildIndex($preview, 0)   # fill goes behind the docked-left panel

# double-buffer + resize-repaint the preview (wizard.ps1's proven reflection trick)
try {
    $pi = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
    $pi.SetValue($preview, $true, $null)
    $rr = [System.Windows.Forms.Control].GetProperty('ResizeRedraw', [System.Reflection.BindingFlags]'Instance,NonPublic')
    $rr.SetValue($preview, $true, $null)
} catch {}
$preview.Add_Resize({ $preview.Invalidate() })

# --- left-column controls ---
function New-Label($text, $y, $muted) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.AutoSize = $true; $l.Location = New-Object System.Drawing.Point(14, $y)
    $l.ForeColor = $(if ($muted) { $cMuted } else { $cInk })
    $left.Controls.Add($l); return $l
}
function New-Num($y, $val) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point(14, $y); $t.Width = 120
    $t.BackColor = $cField; $t.ForeColor = $cInk; $t.BorderStyle = 'FixedSingle'
    $t.Text = "$val"
    $left.Controls.Add($t); return $t
}

$y = 6
New-Label 'Catalog preset (real rows)' $y $true | Out-Null
$y += 20
$cbo = New-Object System.Windows.Forms.ComboBox
$cbo.Location = New-Object System.Drawing.Point(14, $y); $cbo.Width = 266
$cbo.DropDownStyle = 'DropDownList'; $cbo.BackColor = $cField; $cbo.ForeColor = $cInk
$cbo.DropDownWidth = 460
foreach ($p in $presets) { [void]$cbo.Items.Add($p.Name) }
$left.Controls.Add($cbo)
$y += 34

New-Label 'OD (in)' $y $true | Out-Null;  New-Label 'ID / bore (in)' ($y) $true | Out-Null
$lblID = $left.Controls[$left.Controls.Count-1]; $lblID.Location = New-Object System.Drawing.Point(150, $y)
$y += 18
$tbOD = New-Num $y 0.75;  $tbID = New-Num $y 0.5;  $tbID.Location = New-Object System.Drawing.Point(150, $y); $tbID.Width = 120
$y += 34
New-Label 'Length (in)' $y $true | Out-Null;  New-Label 'Head Ø (opt)' ($y) $true | Out-Null
$lblHd = $left.Controls[$left.Controls.Count-1]; $lblHd.Location = New-Object System.Drawing.Point(150, $y)
$y += 18
$tbLen = New-Num $y 0.75;  $tbHead = New-Num $y '';  $tbHead.Location = New-Object System.Drawing.Point(150, $y); $tbHead.Width = 120
$y += 40

$chkEnd = New-Object System.Windows.Forms.CheckBox
$chkEnd.Text = 'Show end view'; $chkEnd.Checked = $true; $chkEnd.AutoSize = $true
$chkEnd.ForeColor = $cInk; $chkEnd.Location = New-Object System.Drawing.Point(14, $y)
$left.Controls.Add($chkEnd); $y += 26
$chkDim = New-Object System.Windows.Forms.CheckBox
$chkDim.Text = 'Show dimensions'; $chkDim.Checked = $true; $chkDim.AutoSize = $true
$chkDim.ForeColor = $cInk; $chkDim.Location = New-Object System.Drawing.Point(14, $y)
$left.Controls.Add($chkDim); $y += 38

$btnSvg = New-Object System.Windows.Forms.Button
$btnSvg.Text = 'Save SVG'; $btnSvg.Location = New-Object System.Drawing.Point(14, $y); $btnSvg.Width = 128
$btnSvg.FlatStyle = 'Flat'; $btnSvg.BackColor = $cAccent; $btnSvg.ForeColor = [System.Drawing.Color]::White
$left.Controls.Add($btnSvg)
$btnPng = New-Object System.Windows.Forms.Button
$btnPng.Text = 'Save PNG'; $btnPng.Location = New-Object System.Drawing.Point(152, $y); $btnPng.Width = 128
$btnPng.FlatStyle = 'Flat'; $btnPng.BackColor = $cField; $btnPng.ForeColor = $cInk
$left.Controls.Add($btnPng)
$y += 40

$lblErr = New-Object System.Windows.Forms.Label
$lblErr.AutoSize = $false; $lblErr.Location = New-Object System.Drawing.Point(14, $y); $lblErr.Size = New-Object System.Drawing.Size(270, 40)
$lblErr.ForeColor = $cErr
$left.Controls.Add($lblErr)
$y += 46
$lblPn = New-Object System.Windows.Forms.Label
$lblPn.AutoSize = $false; $lblPn.Location = New-Object System.Drawing.Point(14, $y); $lblPn.Size = New-Object System.Drawing.Size(270, 60)
$lblPn.ForeColor = $cMuted
$left.Controls.Add($lblPn)

# --- helpers to read the fields ---
$readNum = {
    param($tb)
    $v = 0.0
    if ([double]::TryParse(($tb.Text).Trim(), [ref]$v)) { return $v } else { return $null }
}

# --- preview Paint: parse fields, draw via the shared GDI+ helper ---
$preview.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $od  = & $readNum $tbOD
    $id  = & $readNum $tbID
    $len = & $readNum $tbLen
    $hd  = & $readNum $tbHead; if ($null -eq $hd) { $hd = 0.0 }
    if ($null -eq $od -or $null -eq $id -or $null -eq $len) { return }
    $lbl = ''
    if ($cbo.SelectedIndex -ge 0) { $lbl = [string]$presets[$cbo.SelectedIndex].Name }
    Draw-BushingSchematic -Graphics $g -OD $od -ID $id -Length $len -HeadDia $hd `
        -ClientW $sender.ClientSize.Width -ClientH $sender.ClientSize.Height `
        -ShowEnd $chkEnd.Checked -ShowDims $chkDim.Checked -Background $cPreview -Label $lbl
})

# --- update error + part-number panel + repaint on any change ---
$refresh = {
    $od  = & $readNum $tbOD; $id = & $readNum $tbID; $len = & $readNum $tbLen
    if ($null -eq $od -or $null -eq $id -or $null -eq $len) {
        $lblErr.Text = 'Enter numeric OD, ID and Length.'
    } else {
        $vd = Test-BushingDims -OD $od -ID $id -Length $len
        $lblErr.Text = $(if ($vd.Ok) { '' } else { $vd.Error })
    }
    # part-number row: link-worthy PN vs the blanked "no PN" case
    $pn = ''
    if ($cbo.SelectedIndex -ge 0) { $pn = [string]$presets[$cbo.SelectedIndex].PN }
    if ($pn -and $pn -notmatch '^\(|n/a|unspecified') {
        $lblPn.ForeColor = $cMuted
        $lblPn.Text = "Part number: $pn`r`n(a real PN -> a 'View on McMaster' link is safe here)"
    } else {
        $lblPn.ForeColor = [System.Drawing.Color]::FromArgb(245, 200, 90)
        $lblPn.Text = "No part number on file - look up on mcmaster.com by ID + length before ordering."
    }
    $preview.Invalidate()
}

# --- wire events ---
$cbo.Add_SelectedIndexChanged({
    $p = $presets[$cbo.SelectedIndex]
    # drill bushings are headed, sleeves headless -> auto-fill a representative head so
    # the standalone preview matches the drilljig-gui behavior (Get-BushingHeadDia).
    $hd = Get-BushingHeadDia -EasyName $p.Name -OD ([double]$p.OD)
    $tbOD.Text = "$($p.OD)"; $tbID.Text = "$($p.ID)"; $tbLen.Text = "$($p.Len)"
    $tbHead.Text = if ($hd -gt 0) { "$hd" } else { '' }
    & $refresh
})
$tbOD.Add_TextChanged($refresh)
$tbID.Add_TextChanged($refresh)
$tbLen.Add_TextChanged($refresh)
$tbHead.Add_TextChanged($refresh)
$chkEnd.Add_CheckedChanged($refresh)
$chkDim.Add_CheckedChanged($refresh)

$btnSvg.Add_Click({
    $od = & $readNum $tbOD; $id = & $readNum $tbID; $len = & $readNum $tbLen; $hd = & $readNum $tbHead; if ($null -eq $hd) { $hd = 0.0 }
    if ($null -eq $od -or $null -eq $id -or $null -eq $len) { return }
    $lbl = if ($cbo.SelectedIndex -ge 0) { [string]$presets[$cbo.SelectedIndex].Name } else { '' }
    $svg = Get-BushingSvg -OD $od -ID $id -Length $len -HeadDia $hd -ShowEnd $chkEnd.Checked -ShowDims $chkDim.Checked -Label $lbl
    if (-not $svg) { [System.Windows.Forms.MessageBox]::Show('Invalid dimensions - nothing to save.') | Out-Null; return }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'SVG (*.svg)|*.svg'; $dlg.FileName = 'bushing_schematic.svg'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        [System.IO.File]::WriteAllText($dlg.FileName, $svg, (New-Object System.Text.UTF8Encoding($false)))
    }
})
$btnPng.Add_Click({
    $od = & $readNum $tbOD; $id = & $readNum $tbID; $len = & $readNum $tbLen; $hd = & $readNum $tbHead; if ($null -eq $hd) { $hd = 0.0 }
    if ($null -eq $od -or $null -eq $id -or $null -eq $len) { return }
    $lbl = if ($cbo.SelectedIndex -ge 0) { [string]$presets[$cbo.SelectedIndex].Name } else { '' }
    $w = [math]::Max(200, $preview.ClientSize.Width); $h = [math]::Max(200, $preview.ClientSize.Height)
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear($cPreview)
    Draw-BushingSchematic -Graphics $g -OD $od -ID $id -Length $len -HeadDia $hd -ClientW $w -ClientH $h -ShowEnd $chkEnd.Checked -ShowDims $chkDim.Checked -Background $cPreview -Label $lbl
    $g.Dispose()
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'PNG (*.png)|*.png'; $dlg.FileName = 'bushing_schematic.png'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $bmp.Save($dlg.FileName, [System.Drawing.Imaging.ImageFormat]::Png) }
    $bmp.Dispose()
})

# initial state: select the 3/4 x 1/2 x 3/4 sleeve
$cbo.SelectedIndex = 1
& $refresh

[void]$form.ShowDialog()
$form.Dispose()
