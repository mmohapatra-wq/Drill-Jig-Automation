<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -STA -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

# ============================================================================
# drilljig-3d-preview.cmd - STANDALONE 3D drill-jig preview window (Stage 2)
# ============================================================================
# A native Windows PowerShell window that shows the drill-jig plate in 3D with
# live sliders - the WPF Media3D sibling of the HTML prototype
# (docs\drilljig_3d_preview.html). NO Creo connection: it dot-sources the REAL
# lib\orthogrid.ps1 (Get-OrthogridGeometry / Get-RowSlots), so the picture is
# driven by the SAME production geometry the tools use - not a re-implementation.
#
# STANDALONE & ADDITIVE: this file touches NOTHING else. drilljig-gui.cmd is
# left completely alone. This is the middle stage of the user's staged rollout:
#     HTML prototype (done)  ->  THIS PowerShell/WPF window  ->  GUI integration.
#
# RENDERER: pure WPF Media3D (System.Windows.Media.Media3D) Viewport3D hosted in
# a WinForms Form via ElementHost - verified to load + rasterize on this machine
# (PS 5.1 / .NET 4.8.1) with ZERO external DLLs. Media3D has no boolean CSG, so:
#   * holes are rendered as DARK BORE cylinders that poke through the plate (dark
#     disks on the faces read as drilled openings); the plate silhouette stays
#     solid (the marker limitation - honest, and identical to the planned GUI).
#   * chip-relief slots are translucent amber recessed boxes (1 per hole row).
#
# CONTROLS: drag = orbit, wheel = zoom, right-drag = pan; sliders rebuild live
# (readout updates instantly, the 3D mesh rebuild is debounced ~90ms so a drag
# at high Nx*Nz stays smooth). A math SELF-TEST badge (top-left) runs 5 cases
# against the REAL Get-OrthogridGeometry on load = a live regression check.
#
# FRAME (matches the app + the HTML): X = plate width (right), Z = plate depth,
# Y = through-thickness (up). Holes thru-all along Y. thickness = bushing length
# + slot depth (the extrude pad; the slot removes slotDepth so the functional
# guide depth == bushing length).
# ============================================================================

$Host.UI.RawUI.WindowTitle = "DRILLJIG 3D PREVIEW"
$ErrorActionPreference = "Stop"

trap {
    Write-Host ""
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $inv = $_.InvocationInfo
    if ($null -ne $inv) { Write-Host ("  at line {0}: {1}" -f $inv.ScriptLineNumber, $inv.Line.Trim()) -ForegroundColor DarkYellow }
    Write-Host ""
    Write-Host "  Press any key to exit..."
    try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch {}
    exit 1
}

# ---- the REAL production geometry + the shared WPF mesh/scene builders -----
. (Join-Path $ScriptDir 'lib\orthogrid.ps1')
. (Join-Path $ScriptDir 'lib\wpf3d_preview.ps1')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName WindowsFormsIntegration
[System.Windows.Forms.Application]::EnableVisualStyles()

# ============================================================================
# 1) STATE
# ============================================================================
$script:P = @{ CcX=0.5; CcZ=0.5; Nx=5; Nz=4; HoleDia=0.25; BushingLen=0.75; SlotDepth=0.25; Edge=0.25 }
$script:lockEdge = $true
$script:showSlots = $true
$script:lastGeo = $null

# camera orbit state (spherical about target)
$script:az = 0.85; $script:el = 0.62; $script:rad = 8.0
$script:target = New-Object System.Windows.Media.Media3D.Point3D(0,0,0)
$script:dragging = $false; $script:panning = $false
$script:lastMx = 0.0; $script:lastMy = 0.0

# ============================================================================
# 2) SCENE  (mesh/scene builders live in lib\wpf3d_preview.ps1; the geometry is
#    rebuilt into $script:modelVisual.Content each recompute)
# ============================================================================
$script:viewport = New-Object System.Windows.Controls.Viewport3D
$script:cam = New-Object System.Windows.Media.Media3D.PerspectiveCamera
$script:cam.FieldOfView = 48
$script:viewport.Camera = $script:cam

# lights (added once)
$lightGroup = New-Object System.Windows.Media.Media3D.Model3DGroup
$lightGroup.Children.Add((New-Object System.Windows.Media.Media3D.AmbientLight([System.Windows.Media.Color]::FromRgb(90,100,120))))
$dl1 = New-Object System.Windows.Media.Media3D.DirectionalLight([System.Windows.Media.Color]::FromRgb(255,255,255), (New-Object System.Windows.Media.Media3D.Vector3D(-0.5,-1,-0.6)))
$dl2 = New-Object System.Windows.Media.Media3D.DirectionalLight([System.Windows.Media.Color]::FromRgb(120,150,200), (New-Object System.Windows.Media.Media3D.Vector3D(0.6,-0.3,0.5)))
$lightGroup.Children.Add($dl1); $lightGroup.Children.Add($dl2)
$lightVisual = New-Object System.Windows.Media.Media3D.ModelVisual3D
$lightVisual.Content = $lightGroup
$script:viewport.Children.Add($lightVisual)

$script:modelVisual = New-Object System.Windows.Media.Media3D.ModelVisual3D
$script:viewport.Children.Add($script:modelVisual)

function Update-Camera {
    $tx=$script:target.X; $ty=$script:target.Y; $tz=$script:target.Z
    $cx = $tx + $script:rad*[math]::Cos($script:el)*[math]::Cos($script:az)
    $cy = $ty + $script:rad*[math]::Sin($script:el)
    $cz = $tz + $script:rad*[math]::Cos($script:el)*[math]::Sin($script:az)
    $script:cam.Position = New-Object System.Windows.Media.Media3D.Point3D($cx,$cy,$cz)
    $script:cam.LookDirection = New-Object System.Windows.Media.Media3D.Vector3D(($tx-$cx),($ty-$cy),($tz-$cz))
    $script:cam.UpDirection = New-Object System.Windows.Media.Media3D.Vector3D(0,1,0)
}

function Fit-View {
    $g = $script:lastGeo; if ($null -eq $g) { return }
    $t = [double]$script:P.BushingLen + [double]$script:P.SlotDepth
    $maxDim = [math]::Max([math]::Max([double]$g.Width, [double]$g.Height), $t); if ($maxDim -le 0) { $maxDim = 1 }
    $script:rad = ($maxDim / (2*[math]::Tan(($script:cam.FieldOfView*[math]::PI/180)/2))) * 1.7
    $script:target = New-Object System.Windows.Media.Media3D.Point3D(0, ($t/2), 0)
    Update-Camera
}

function Rebuild-Scene {
    $g = Compute-Geo
    $script:lastGeo = $g
    Update-Readout $g
    $t = [double]$script:P.BushingLen + [double]$script:P.SlotDepth
    # all mesh/scene construction lives in lib\wpf3d_preview.ps1 (shared)
    $script:modelVisual.Content = Build-JigModelGroup -Geo $g -Thickness $t `
        -HoleDia ([double]$script:P.HoleDia) -SlotDepth ([double]$script:P.SlotDepth) `
        -ShowSlots:$script:showSlots -Segments 16
}

# ============================================================================
# 4) GEOMETRY (real production functions) + READOUT
# ============================================================================
function Compute-Geo {
    $clear = [double]$script:P.HoleDia                       # ClearDia = hole dia (app rule)
    $em = if ($script:lockEdge) { [double]$script:P.HoleDia } else { -1.0 }
    return Get-OrthogridGeometry -CcX ([double]$script:P.CcX) -CcZ ([double]$script:P.CcZ) `
        -Nx ([int][math]::Round($script:P.Nx)) -Nz ([int][math]::Round($script:P.Nz)) `
        -Edge ([double]$script:P.Edge) -ClearDia $clear -HoleDia ([double]$script:P.HoleDia) -EdgeMargin $em
}

function Update-Readout { param($g)
    $t = [double]$script:P.BushingLen + [double]$script:P.SlotDepth
    $slotN = 0
    if ($g.Valid) { try { $s = Get-RowSlots -Points $g.Points -SlotWidth ([double]$script:P.HoleDia) -Width $g.Width -Height $g.Height -RowAxis 'X'; if ($s.Valid) { $slotN = $s.Count } } catch {} }
    if ($g.Valid) {
        $script:lblReadout.ForeColor = [System.Drawing.Color]::FromArgb(120,210,150)
        $script:lblReadout.Text = ("Part {0:0.00} x {1:0.00}""   |   {2} holes   |   {3} relief slot(s)" -f $g.Width, $g.Height, $g.Count, $slotN)
        $script:lblErr.Text = ""
    } else {
        $script:lblReadout.ForeColor = [System.Drawing.Color]::FromArgb(245,200,90)
        $script:lblReadout.Text = ("Part {0:0.00} x {1:0.00}""  (invalid layout)" -f $g.Width, $g.Height)
        $script:lblErr.Text = ($g.Errors -join "`r`n")
    }
    $script:lblCtx.Text = ("hole {0:0.###}""   .   plate thickness {1:0.###}"" (bushing {2:0.##} + slot {3:0.##})" -f `
        [double]$script:P.HoleDia, $t, [double]$script:P.BushingLen, [double]$script:P.SlotDepth)
}

# ============================================================================
# 5) MATH SELF-TEST  (5 cases vs the REAL Get-OrthogridGeometry -> live regression)
#    Expected values captured from the production functions (2026-07-22).
# ============================================================================
function Run-SelfTest {
    $cases = @(
        @{ n='default';  in=@(0.5,0.5,5,4,0.25,0.25,0.25,0.25);       exp=@{v=$true;  w=2.75; h=2.25; c=20; e=0; s=4} },
        @{ n='single';   in=@(0.5,0.5,1,1,0.5,0.5,0.5,0.5);           exp=@{v=$true;  w=1.5;  h=1.5;  c=1;  e=0; s=1} },
        @{ n='collideX'; in=@(0.4,0.6,3,3,0.5,0.5,0.5,0.5);           exp=@{v=$false; w=2.3;  h=2.7;  c=9;  e=1} },
        @{ n='edgefail'; in=@(0.6,0.6,3,3,0.1,0.5,0.5,0.5);           exp=@{v=$false; w=1.9;  h=1.9;  c=9;  e=1} },
        @{ n='wide';     in=@(0.75,0.5,8,3,0.375,0.375,0.375,0.375);  exp=@{v=$true;  w=6.375;h=2.125;c=24; e=0; s=3} }
    )
    $T = 1e-4; $fails = @()
    foreach ($c in $cases) {
        $i = $c.in; $e = $c.exp
        $g = Get-OrthogridGeometry -CcX $i[0] -CcZ $i[1] -Nx ([int]$i[2]) -Nz ([int]$i[3]) -Edge $i[4] -ClearDia $i[5] -HoleDia $i[6] -EdgeMargin $i[7]
        $f = @()
        if ($g.Valid -ne $e.v) { $f += 'valid' }
        if ([math]::Abs([double]$g.Width  - $e.w) -gt $T) { $f += 'w' }
        if ([math]::Abs([double]$g.Height - $e.h) -gt $T) { $f += 'h' }
        if ([int]$g.Count -ne $e.c) { $f += 'count' }
        if ($g.Errors.Count -ne $e.e) { $f += 'errN' }
        if ($null -ne $e.s -and $g.Valid) {
            $s = Get-RowSlots -Points $g.Points -SlotWidth $i[6] -Width $g.Width -Height $g.Height -RowAxis 'X'
            if ([int]$s.Count -ne $e.s) { $f += 'slotN' }
        }
        if ($f.Count) { $fails += ("{0}:{1}" -f $c.n, ($f -join ',')) }
    }
    return @{ total=$cases.Count; pass=($cases.Count - $fails.Count); fails=$fails }
}

# ============================================================================
# 6) WINFORMS SHELL  (left control panel + right ElementHost/Viewport3D)
# ============================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "Drill-Jig 3D Preview  -  standalone (no Creo)"
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1180, 760)
$form.MinimumSize = New-Object System.Drawing.Size(900, 560)
$form.BackColor = [System.Drawing.Color]::FromArgb(20,30,52)

$panel = New-Object System.Windows.Forms.Panel
$panel.Dock = 'Left'; $panel.Width = 340; $panel.BackColor = [System.Drawing.Color]::FromArgb(20,30,52)
$panel.AutoScroll = $true; $panel.Padding = New-Object System.Windows.Forms.Padding(14)
$form.Controls.Add($panel)

$viewHost = New-Object System.Windows.Forms.Panel
$viewHost.Dock = 'Fill'; $viewHost.BackColor = [System.Drawing.Color]::FromArgb(30,42,68)
$form.Controls.Add($viewHost)
$form.Controls.SetChildIndex($viewHost, 0)   # fill first, panel docks left over it

$ink = [System.Drawing.Color]::FromArgb(238,242,248)
$muted = [System.Drawing.Color]::FromArgb(158,172,196)
$accent = [System.Drawing.Color]::FromArgb(90,169,255)

function New-Lbl { param($text,$y,$w=300,$color=$ink,$bold=$false,$size=9)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point(2, $y); $l.Size = New-Object System.Drawing.Size($w, 20)
    $l.ForeColor = $color; $l.BackColor = [System.Drawing.Color]::Transparent
    $style = if ($bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $l.Font = New-Object System.Drawing.Font('Segoe UI', $size, $style)
    $panel.Controls.Add($l); return $l
}

$y = 6
New-Lbl "Drill-Jig 3D Preview" $y 310 $ink $true 13 | Out-Null; $y += 24
New-Lbl "standalone WPF window . real Get-OrthogridGeometry" $y 320 $muted $false 8 | Out-Null; $y += 24

# self-test badge
$st = Run-SelfTest
$script:lblSelfTest = New-Object System.Windows.Forms.Label
$script:lblSelfTest.Location = New-Object System.Drawing.Point(2, $y); $script:lblSelfTest.Size = New-Object System.Drawing.Size(310, 34)
$script:lblSelfTest.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$script:lblSelfTest.BackColor = [System.Drawing.Color]::FromArgb(34,49,79)
$script:lblSelfTest.TextAlign = 'MiddleLeft'; $script:lblSelfTest.Padding = New-Object System.Windows.Forms.Padding(6,0,0,0)
if ($st.fails.Count -eq 0) {
    $script:lblSelfTest.ForeColor = [System.Drawing.Color]::FromArgb(120,210,150)
    $script:lblSelfTest.Text = ("[PASS] math self-test: {0}/{1} (3D == Get-OrthogridGeometry)" -f $st.pass, $st.total)
} else {
    $script:lblSelfTest.ForeColor = [System.Drawing.Color]::FromArgb(245,120,110)
    $script:lblSelfTest.Text = ("[FAIL] self-test {0}/{1}: {2}" -f $st.pass, $st.total, ($st.fails -join ' | '))
}
$panel.Controls.Add($script:lblSelfTest); $y += 44

# sliders
$sliderDefs = @(
    @{ k='Nx';        label='Holes along X (Nx)'; min=1;   max=15;  scale=1;   fmt='{0:0}' },
    @{ k='Nz';        label='Holes along Z (Nz)'; min=1;   max=15;  scale=1;   fmt='{0:0}' },
    @{ k='CcX';       label='Center-to-center X'; min=10;  max=300; scale=100; fmt='{0:0.00}"' },
    @{ k='CcZ';       label='Center-to-center Z'; min=10;  max=300; scale=100; fmt='{0:0.00}"' },
    @{ k='HoleDia';   label='Hole diameter';      min=5;   max=150; scale=100; fmt='{0:0.00}"' },
    @{ k='BushingLen';label='Bushing length';     min=10;  max=300; scale=100; fmt='{0:0.00}"' },
    @{ k='SlotDepth'; label='Slot depth';         min=0;   max=100; scale=100; fmt='{0:0.00}"' },
    @{ k='Edge';      label='Edge margin';        min=0;   max=100; scale=100; fmt='{0:0.00}"' }
)
$script:sliders = @{}
foreach ($sd in $sliderDefs) {
    New-Lbl $sd.label $y 200 $ink | Out-Null
    $valLbl = New-Object System.Windows.Forms.Label
    $valLbl.Location = New-Object System.Drawing.Point(210, $y); $valLbl.Size = New-Object System.Drawing.Size(110, 20)
    $valLbl.ForeColor = $accent; $valLbl.BackColor = [System.Drawing.Color]::Transparent
    $valLbl.TextAlign = 'MiddleRight'; $valLbl.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $panel.Controls.Add($valLbl)
    $y += 20
    $tb = New-Object System.Windows.Forms.TrackBar
    $tb.Location = New-Object System.Drawing.Point(2, $y); $tb.Size = New-Object System.Drawing.Size(318, 32)
    $tb.Minimum = [int]$sd.min; $tb.Maximum = [int]$sd.max; $tb.TickStyle = 'None'
    $tb.Value = [int][math]::Round([double]$script:P[$sd.k] * $sd.scale)
    $tb.Tag = $sd
    $valLbl.Text = ($sd.fmt -f ([double]$tb.Value / $sd.scale))
    $panel.Controls.Add($tb)
    $script:sliders[$sd.k] = @{ tb=$tb; lbl=$valLbl; def=$sd }
    $tb.Add_Scroll({
        param($s,$e)
        $d = $s.Tag
        $v = [double]$s.Value / $d.scale
        $script:P[$d.k] = $v
        $script:sliders[$d.k].lbl.Text = ($d.fmt -f $v)
        if ($script:lockEdge -and $d.k -eq 'HoleDia') { Set-EdgeToHole }
        Update-Readout (Compute-Geo)                 # numbers update instantly
        $script:reTimer.Stop(); $script:reTimer.Start()   # 3D rebuild debounced
    })
    $y += 34
}

function Set-EdgeToHole {
    $script:P.Edge = [double]$script:P.HoleDia
    $es = $script:sliders['Edge']
    $es.tb.Value = [Math]::Min($es.tb.Maximum, [Math]::Max($es.tb.Minimum, [int][math]::Round($script:P.Edge * $es.def.scale)))
    $es.lbl.Text = ($es.def.fmt -f $script:P.Edge)
}

# toggles
$chkEdge = New-Object System.Windows.Forms.CheckBox
$chkEdge.Text = "Edge = hole dia"; $chkEdge.Checked = $true; $chkEdge.ForeColor = $muted
$chkEdge.Location = New-Object System.Drawing.Point(2, $y); $chkEdge.Size = New-Object System.Drawing.Size(150, 22)
$chkEdge.Add_CheckedChanged({
    $script:lockEdge = $chkEdge.Checked
    $script:sliders['Edge'].tb.Enabled = -not $chkEdge.Checked
    if ($chkEdge.Checked) { Set-EdgeToHole }
    Update-Readout (Compute-Geo); $script:reTimer.Stop(); $script:reTimer.Start()
})
$panel.Controls.Add($chkEdge)

$chkSlots = New-Object System.Windows.Forms.CheckBox
$chkSlots.Text = "Slots"; $chkSlots.Checked = $true; $chkSlots.ForeColor = $muted
$chkSlots.Location = New-Object System.Drawing.Point(160, $y); $chkSlots.Size = New-Object System.Drawing.Size(90, 22)
$chkSlots.Add_CheckedChanged({ $script:showSlots = $chkSlots.Checked; $script:reTimer.Stop(); $script:reTimer.Start() })
$panel.Controls.Add($chkSlots)
$script:sliders['Edge'].tb.Enabled = $false   # start locked
$y += 30

# readout + errors + context
$script:lblReadout = New-Object System.Windows.Forms.Label
$script:lblReadout.Location = New-Object System.Drawing.Point(2, $y); $script:lblReadout.Size = New-Object System.Drawing.Size(318, 40)
$script:lblReadout.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$script:lblReadout.ForeColor = [System.Drawing.Color]::FromArgb(120,210,150); $script:lblReadout.BackColor = [System.Drawing.Color]::Transparent
$panel.Controls.Add($script:lblReadout); $y += 42
$script:lblErr = New-Object System.Windows.Forms.Label
$script:lblErr.Location = New-Object System.Drawing.Point(2, $y); $script:lblErr.Size = New-Object System.Drawing.Size(318, 60)
$script:lblErr.ForeColor = [System.Drawing.Color]::FromArgb(245,120,110); $script:lblErr.BackColor = [System.Drawing.Color]::Transparent
$script:lblErr.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$panel.Controls.Add($script:lblErr); $y += 62
$script:lblCtx = New-Object System.Windows.Forms.Label
$script:lblCtx.Location = New-Object System.Drawing.Point(2, $y); $script:lblCtx.Size = New-Object System.Drawing.Size(318, 34)
$script:lblCtx.ForeColor = $muted; $script:lblCtx.BackColor = [System.Drawing.Color]::Transparent
$script:lblCtx.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$panel.Controls.Add($script:lblCtx); $y += 38

# view buttons
function New-Btn { param($text,$x,$w,$onClick)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $script:btnY); $b.Size = New-Object System.Drawing.Size($w, 28)
    $b.BackColor = [System.Drawing.Color]::FromArgb(34,49,79); $b.ForeColor = $ink; $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(58,77,118)
    $b.Add_Click($onClick); $panel.Controls.Add($b); return $b
}
$script:btnY = $y
New-Btn "Iso"   2   72 { Set-Ori 0.85 0.62 } | Out-Null
New-Btn "Top"   78  72 { Set-Ori 1.5708 1.5533 } | Out-Null
New-Btn "Front" 154 72 { Set-Ori 1.5708 0.02 } | Out-Null
New-Btn "Reset" 230 88 { Set-Ori 0.85 0.62; Fit-View } | Out-Null
$y += 34

function Set-Ori { param($az,$el) $script:az=$az; $script:el=$el; Update-Camera }

# legend
New-Lbl "drag = orbit  .  wheel = zoom  .  right-drag = pan" $y 320 $muted $false 8 | Out-Null; $y += 18
New-Lbl "X = width   Y = thickness (up)   Z = depth" $y 320 $muted $false 8 | Out-Null; $y += 18
New-Lbl "holes = dark bores (Media3D marker; plate has no CSG cut)" $y 320 $muted $false 8 | Out-Null

# ---- ElementHost hosting the WPF Viewport3D (in a Grid so mouse events hit) ----
$grid = New-Object System.Windows.Controls.Grid
$grid.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(30,42,68))
$grid.Children.Add($script:viewport)
$eh = New-Object System.Windows.Forms.Integration.ElementHost
$eh.Dock = 'Fill'; $eh.Child = $grid
$viewHost.Controls.Add($eh)

# ---- mouse orbit / pan / zoom (WPF handlers on the hit-testable Grid) ----
$grid.Add_MouseDown({
    param($s,$e)
    $pos = $e.GetPosition($grid)
    $script:lastMx = $pos.X; $script:lastMy = $pos.Y
    if ($e.RightButton -eq [System.Windows.Input.MouseButtonState]::Pressed) { $script:panning = $true }
    else { $script:dragging = $true }
    $grid.CaptureMouse() | Out-Null
})
$grid.Add_MouseMove({
    param($s,$e)
    $pos = $e.GetPosition($grid); $dx = $pos.X - $script:lastMx; $dy = $pos.Y - $script:lastMy
    if ($script:dragging) {
        $script:az -= $dx * 0.01
        $script:el += $dy * 0.01
        $script:el = [math]::Max(-1.55, [math]::Min(1.55, $script:el))
        Update-Camera
    } elseif ($script:panning) {
        $t = [double]$script:P.BushingLen + [double]$script:P.SlotDepth
        $scale = $script:rad * 0.0016
        $nx = $script:target.X - $dx * $scale
        $ny = $script:target.Y + $dy * $scale
        $script:target = New-Object System.Windows.Media.Media3D.Point3D($nx, $ny, $script:target.Z)
        Update-Camera
    }
    $script:lastMx = $pos.X; $script:lastMy = $pos.Y
})
$grid.Add_MouseUp({ param($s,$e) $script:dragging=$false; $script:panning=$false; $grid.ReleaseMouseCapture() | Out-Null })
$grid.Add_MouseWheel({
    param($s,$e)
    $factor = if ($e.Delta -gt 0) { 0.88 } else { 1.136 }
    $script:rad = [math]::Max(0.3, [math]::Min(500.0, $script:rad * $factor))
    Update-Camera
})

# ---- debounce timer for the 3D mesh rebuild ----
$script:reTimer = New-Object System.Windows.Forms.Timer
$script:reTimer.Interval = 90
$script:reTimer.Add_Tick({ $script:reTimer.Stop(); Rebuild-Scene })

# ---- first paint ----
$form.Add_Shown({
    Rebuild-Scene
    Fit-View
    $form.Activate()
})

[void]$form.ShowDialog()
