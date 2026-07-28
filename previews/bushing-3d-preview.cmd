<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -STA -Command "$ScriptDir=((Split-Path -Parent ('%~dp0'.TrimEnd('\')))+'\'); $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

# ============================================================================
# bushing-3d-preview.cmd - STANDALONE 3D preview of a bushing / drill bushing
# ============================================================================
# The 3D sibling of bushing-preview.cmd (the 2D SVG schematic), and the bushing
# analog of drilljig-3d-preview.cmd. A native Windows PowerShell window that shows
# the SELECTED catalog bushing/sleeve as BOTH a 2D schematic (GDI+ Draw-BushingSchematic)
# and a live 3D model (WPF Media3D), driven by the SAME database rows + geometry.
#   * pick a bushing/sleeve from the catalog (data\bushings.csv + bushings_drill.csv)
#   * the 2D SVG schematic (top) and the 3D model (below) both update
#   * DRILL BUSHINGS render HEADED (a flange); SLEEVES render HEADLESS - the same
#     distinction the 2D schematic makes (Get-BushingHeadDia)
#
# STANDALONE & ADDITIVE: touches nothing else; drilljig-gui.cmd is untouched. Same
# staged rollout as the SVG + the jig 3D: standalone window first, GUI integration later.
#
# 3D: a HOLLOW TUBE (real bore, no CSG needed) + optional head flange, built by
# Build-BushingModelGroup (lib\wpf3d_preview.ps1). Media3D Viewport3D in a WinForms
# Form via ElementHost. Drag = orbit, wheel = zoom, right-drag = pan.
# FRAME: bushing axis along Y (up), centered at the origin; head at the top.
# ============================================================================

$Host.UI.RawUI.WindowTitle = "BUSHING 3D PREVIEW"
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

# ---- shared 2D schematic + 3D mesh/scene builders --------------------------
. (Join-Path $ScriptDir 'lib\bushing_svg.ps1')      # Get-BushingHeadDia / Draw-BushingSchematic (2D)
. (Join-Path $ScriptDir 'lib\wpf3d_preview.ps1')    # Build-BushingModelGroup + mesh helpers (3D)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName WindowsFormsIntegration
[System.Windows.Forms.Application]::EnableVisualStyles()

# ============================================================================
# 1) CATALOG PRESETS (real rows from the database)
# ============================================================================
$dataDir = Join-Path $ScriptDir 'data'
$script:presets = @()
foreach ($fn in @('bushings.csv','bushings_drill.csv')) {
    $path = Join-Path $dataDir $fn
    if (Test-Path $path) {
        foreach ($r in @(Import-Csv $path)) {
            $od = 0.0; $id = 0.0; $ln = 0.0
            if (-not [double]::TryParse([string]$r.OD, [ref]$od))     { continue }
            if (-not [double]::TryParse([string]$r.ID, [ref]$id))     { continue }
            if (-not [double]::TryParse([string]$r.Length, [ref]$ln)) { continue }
            if ($od -le 0 -or $id -le 0 -or $ln -le 0 -or $id -ge $od) { continue }
            $script:presets += [pscustomobject]@{ Name=[string]$r.EasyName; OD=$od; ID=$id; Len=$ln; PN=([string]$r.PartNumber) }
        }
    }
}
if ($script:presets.Count -eq 0) {
    # fallback if the CSVs are missing - a couple of representative rows
    $script:presets = @(
        [pscustomobject]@{ Name='Sleeve | OD 3/4 x ID 1/2 x 3/4 Lg'; OD=0.75; ID=0.5; Len=0.75; PN='3556N158' }
        [pscustomobject]@{ Name='Drill Bushing | OD 1/2 x ID 0.25 x 1/4 Lg'; OD=0.5; ID=0.25; Len=0.25; PN='8493A072' }
    )
}

# current bushing state (set from the selected preset)
$script:B = @{ OD=0.75; ID=0.5; Length=0.75; HeadDia=0.0; Name=''; PN='' }
function Set-Bushing { param($p)
    $hd = Get-BushingHeadDia -EasyName $p.Name -OD ([double]$p.OD)
    $script:B = @{ OD=[double]$p.OD; ID=[double]$p.ID; Length=[double]$p.Len; HeadDia=[double]$hd; Name=[string]$p.Name; PN=[string]$p.PN }
}

# ============================================================================
# 2) 3D SCENE (mesh/scene builders in lib\wpf3d_preview.ps1)
# ============================================================================
$script:viewport = New-Object System.Windows.Controls.Viewport3D
$script:cam = New-Object System.Windows.Media.Media3D.PerspectiveCamera
$script:cam.FieldOfView = 46
$script:viewport.Camera = $script:cam

$lightGroup = New-Object System.Windows.Media.Media3D.Model3DGroup
$lightGroup.Children.Add((New-Object System.Windows.Media.Media3D.AmbientLight([System.Windows.Media.Color]::FromRgb(96,106,126))))
$dl1 = New-Object System.Windows.Media.Media3D.DirectionalLight([System.Windows.Media.Color]::FromRgb(255,255,255), (New-Object System.Windows.Media.Media3D.Vector3D(-0.5,-1,-0.6)))
$dl2 = New-Object System.Windows.Media.Media3D.DirectionalLight([System.Windows.Media.Color]::FromRgb(120,150,200), (New-Object System.Windows.Media.Media3D.Vector3D(0.6,-0.3,0.5)))
$lightGroup.Children.Add($dl1); $lightGroup.Children.Add($dl2)
$lightVisual = New-Object System.Windows.Media.Media3D.ModelVisual3D
$lightVisual.Content = $lightGroup
$script:viewport.Children.Add($lightVisual)

$script:modelVisual = New-Object System.Windows.Media.Media3D.ModelVisual3D
$script:viewport.Children.Add($script:modelVisual)

# camera orbit state
$script:az = 0.9; $script:el = 0.5; $script:rad = 4.0
$script:target = New-Object System.Windows.Media.Media3D.Point3D(0,0,0)
$script:dragging = $false; $script:panning = $false
$script:lastMx = 0.0; $script:lastMy = 0.0

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
    $b = $script:B
    $headLen = if ($b.HeadDia -gt $b.OD) { $b.OD * 0.3 } else { 0.0 }
    $H = [double]$b.Length + $headLen
    $maxDim = [math]::Max([math]::Max([double]$b.OD, [double]$b.HeadDia), $H)
    if ($maxDim -le 0) { $maxDim = 1 }
    $script:rad = ($maxDim / (2*[math]::Tan(($script:cam.FieldOfView*[math]::PI/180)/2))) * 1.9
    $script:target = New-Object System.Windows.Media.Media3D.Point3D(0,0,0)
    Update-Camera
}
function Rebuild-3D {
    $b = $script:B
    $script:modelVisual.Content = Build-BushingModelGroup -OD ([double]$b.OD) -ID ([double]$b.ID) `
        -Length ([double]$b.Length) -HeadDia ([double]$b.HeadDia) -Segments 48
}

# ============================================================================
# 3) SELF-TEST (Build-BushingModelGroup model counts + head rule) -> live badge
# ============================================================================
function Run-SelfTest {
    $fails = @()
    $gh = Build-BushingModelGroup -OD 0.5 -ID 0.25 -Length 0.25 -HeadDia 0.675 -Segments 12
    if ($gh.Children.Count -ne 6) { $fails += ('headed=' + $gh.Children.Count) }
    $gs = Build-BushingModelGroup -OD 0.75 -ID 0.5 -Length 0.75 -HeadDia 0 -Segments 12
    if ($gs.Children.Count -ne 4) { $fails += ('headless=' + $gs.Children.Count) }
    $gi = Build-BushingModelGroup -OD 0.5 -ID 0.6 -Length 0.5
    if ($gi.Children.Count -ne 0) { $fails += ('invalid=' + $gi.Children.Count) }
    if ((Get-BushingHeadDia -EasyName 'Drill Bushing' -OD 0.5) -le 0) { $fails += 'drill-not-headed' }
    if ((Get-BushingHeadDia -EasyName 'Sleeve' -OD 0.5) -ne 0)        { $fails += 'sleeve-headed' }
    return @{ total=5; pass=(5 - $fails.Count); fails=$fails }
}

# ============================================================================
# 4) WINFORMS SHELL (left panel + right: 2D schematic on top, 3D fill)
# ============================================================================
$ink    = [System.Drawing.Color]::FromArgb(238,242,248)
$muted  = [System.Drawing.Color]::FromArgb(158,172,196)
$accent = [System.Drawing.Color]::FromArgb(90,169,255)
$formBk = [System.Drawing.Color]::FromArgb(20,30,52)
$viewBk = [System.Drawing.Color]::FromArgb(30,42,68)
$svgBk  = [System.Drawing.Color]::FromArgb(32,33,39)

$form = New-Object System.Windows.Forms.Form
$form.Text = "Bushing 3D Preview  -  standalone (no Creo)"
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1180, 800)
$form.MinimumSize = New-Object System.Drawing.Size(900, 600)
$form.BackColor = $formBk

$panel = New-Object System.Windows.Forms.Panel
$panel.Dock = 'Left'; $panel.Width = 340; $panel.BackColor = $formBk
$panel.AutoScroll = $true; $panel.Padding = New-Object System.Windows.Forms.Padding(14)
$form.Controls.Add($panel)

$viewHost = New-Object System.Windows.Forms.Panel
$viewHost.Dock = 'Fill'; $viewHost.BackColor = $viewBk
$form.Controls.Add($viewHost)
$form.Controls.SetChildIndex($viewHost, 0)

# 2D schematic (top of the right area) - the SVG-style GDI+ drawing
$script:svg2d = New-Object System.Windows.Forms.Panel
$script:svg2d.Dock = 'Top'; $script:svg2d.Height = 220; $script:svg2d.BackColor = $svgBk
try {
    $dbp = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
    $dbp.SetValue($script:svg2d, $true, $null)
} catch {}
$script:svg2d.Add_Paint({
    param($snd, $ev)
    try {
        $b = $script:B
        Draw-BushingSchematic -Graphics $ev.Graphics -OD ([double]$b.OD) -ID ([double]$b.ID) -Length ([double]$b.Length) -HeadDia ([double]$b.HeadDia) `
            -ClientW $snd.ClientSize.Width -ClientH $snd.ClientSize.Height -ShowEnd $true -ShowDims $true -Background $svgBk -Label ([string]$b.Name)
    } catch {}
})
$script:svg2d.Add_Resize({ $script:svg2d.Invalidate() })
$viewHost.Controls.Add($script:svg2d)

$splitLbl = New-Object System.Windows.Forms.Label
$splitLbl.Dock = 'Top'; $splitLbl.Height = 20; $splitLbl.BackColor = $formBk; $splitLbl.ForeColor = $muted
$splitLbl.Text = "  2D schematic (above)   .   3D model (below) - drag to orbit, wheel to zoom"
$splitLbl.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$viewHost.Controls.Add($splitLbl)

$view3d = New-Object System.Windows.Forms.Panel
$view3d.Dock = 'Fill'; $view3d.BackColor = $viewBk
$viewHost.Controls.Add($view3d)
$viewHost.Controls.SetChildIndex($view3d, 0)

$ink2 = $ink
function New-Lbl { param($text,$y,$w=310,$color=$ink2,$bold=$false,$size=9)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point(2, $y); $l.Size = New-Object System.Drawing.Size($w, 20)
    $l.ForeColor = $color; $l.BackColor = [System.Drawing.Color]::Transparent
    $style = if ($bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $l.Font = New-Object System.Drawing.Font('Segoe UI', $size, $style)
    $panel.Controls.Add($l); return $l
}

$y = 6
New-Lbl "Bushing 3D Preview" $y 320 $ink $true 13 | Out-Null; $y += 24
New-Lbl "standalone . 2D schematic + WPF Media3D . catalog-driven" $y 330 $muted $false 8 | Out-Null; $y += 24

# self-test badge
$st = Run-SelfTest
$script:lblSelfTest = New-Object System.Windows.Forms.Label
$script:lblSelfTest.Location = New-Object System.Drawing.Point(2, $y); $script:lblSelfTest.Size = New-Object System.Drawing.Size(316, 34)
$script:lblSelfTest.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$script:lblSelfTest.BackColor = [System.Drawing.Color]::FromArgb(34,49,79)
$script:lblSelfTest.TextAlign = 'MiddleLeft'; $script:lblSelfTest.Padding = New-Object System.Windows.Forms.Padding(6,0,0,0)
if ($st.fails.Count -eq 0) {
    $script:lblSelfTest.ForeColor = [System.Drawing.Color]::FromArgb(120,210,150)
    $script:lblSelfTest.Text = ("[PASS] 3D self-test: {0}/{1} (model counts + head rule)" -f $st.pass, $st.total)
} else {
    $script:lblSelfTest.ForeColor = [System.Drawing.Color]::FromArgb(245,120,110)
    $script:lblSelfTest.Text = ("[FAIL] self-test {0}/{1}: {2}" -f $st.pass, $st.total, ($st.fails -join ' | '))
}
$panel.Controls.Add($script:lblSelfTest); $y += 44

# catalog selector
New-Lbl "Bushing / sleeve (from catalog)" $y 320 $ink $false 9 | Out-Null; $y += 22
$script:cbo = New-Object System.Windows.Forms.ComboBox
$script:cbo.Location = New-Object System.Drawing.Point(2, $y); $script:cbo.Size = New-Object System.Drawing.Size(316, 26)
$script:cbo.DropDownStyle = 'DropDownList'; $script:cbo.BackColor = [System.Drawing.Color]::FromArgb(40,54,84); $script:cbo.ForeColor = $ink
$script:cbo.DropDownHeight = 420
foreach ($p in $script:presets) { [void]$script:cbo.Items.Add($p.Name) }
$panel.Controls.Add($script:cbo); $y += 34

# info labels
$script:lblInfo = New-Object System.Windows.Forms.Label
$script:lblInfo.Location = New-Object System.Drawing.Point(2, $y); $script:lblInfo.Size = New-Object System.Drawing.Size(320, 96)
$script:lblInfo.ForeColor = $ink; $script:lblInfo.BackColor = [System.Drawing.Color]::Transparent
$script:lblInfo.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$panel.Controls.Add($script:lblInfo); $y += 104

function Update-Info {
    $b = $script:B
    $headed = ($b.HeadDia -gt $b.OD)
    $kind = if ($headed) { 'Drill bushing (HEADED)' } else { 'Sleeve (headless)' }
    $pn = if ($b.PN -and $b.PN -notmatch '^\(|n/a|unspecified') { $b.PN } else { '(none on file)' }
    $script:lblInfo.Text = (
        ("Type: {0}" -f $kind) + "`r`n" +
        ("OD (hole): {0}""    ID (bore): {1}""" -f (Get-BushingFracLabel $b.OD), (Get-BushingFracLabel $b.ID)) + "`r`n" +
        ("Length (body): {0}""    Wall: {1:0.###}""" -f (Get-BushingFracLabel $b.Length), (($b.OD - $b.ID)/2.0)) + "`r`n" +
        ("Part number: {0}" -f $pn)
    )
}

# view buttons
$script:btnY = $y
function New-Btn { param($text,$x,$w,$onClick)
    $bt = New-Object System.Windows.Forms.Button
    $bt.Text = $text; $bt.Location = New-Object System.Drawing.Point($x, $script:btnY); $bt.Size = New-Object System.Drawing.Size($w, 28)
    $bt.BackColor = [System.Drawing.Color]::FromArgb(34,49,79); $bt.ForeColor = $ink; $bt.FlatStyle = 'Flat'
    $bt.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(58,77,118)
    $bt.Add_Click($onClick); $panel.Controls.Add($bt); return $bt
}
function Set-Ori { param($az,$el) $script:az=$az; $script:el=$el; Update-Camera }
New-Btn "Iso"   2   72 { Set-Ori 0.9 0.5 } | Out-Null
New-Btn "Side"  78  72 { Set-Ori 1.5708 0.02 } | Out-Null
New-Btn "Top"   154 72 { Set-Ori 1.5708 1.5533 } | Out-Null
New-Btn "Reset" 230 88 { Set-Ori 0.9 0.5; Fit-View } | Out-Null
$y += 36

New-Lbl "drag = orbit  .  wheel = zoom  .  right-drag = pan" $y 320 $muted $false 8 | Out-Null; $y += 18
New-Lbl "3D: real hollow bore; drill bushings show a head flange" $y 320 $muted $false 8 | Out-Null; $y += 18
New-Lbl "sleeves are headless (no head), same as the 2D schematic" $y 320 $muted $false 8 | Out-Null

# ---- ElementHost hosting the WPF Viewport3D (in a Grid for hit-testing) ----
$grid = New-Object System.Windows.Controls.Grid
$grid.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(30,42,68))
$grid.Children.Add($script:viewport)
$eh = New-Object System.Windows.Forms.Integration.ElementHost
$eh.Dock = 'Fill'; $eh.Child = $grid
$view3d.Controls.Add($eh)

# ---- mouse orbit / pan / zoom ----
$grid.Add_MouseDown({
    param($s,$e)
    $pos = $e.GetPosition($grid); $script:lastMx = $pos.X; $script:lastMy = $pos.Y
    if ($e.RightButton -eq [System.Windows.Input.MouseButtonState]::Pressed) { $script:panning = $true } else { $script:dragging = $true }
    $grid.CaptureMouse() | Out-Null
})
$grid.Add_MouseMove({
    param($s,$e)
    $pos = $e.GetPosition($grid); $dx = $pos.X - $script:lastMx; $dy = $pos.Y - $script:lastMy
    if ($script:dragging) {
        $script:az -= $dx * 0.01; $script:el += $dy * 0.01
        $script:el = [math]::Max(-1.55, [math]::Min(1.55, $script:el)); Update-Camera
    } elseif ($script:panning) {
        $scale = $script:rad * 0.0016
        $nx = $script:target.X - $dx * $scale; $ny = $script:target.Y + $dy * $scale
        $script:target = New-Object System.Windows.Media.Media3D.Point3D($nx, $ny, $script:target.Z); Update-Camera
    }
    $script:lastMx = $pos.X; $script:lastMy = $pos.Y
})
$grid.Add_MouseUp({ param($s,$e) $script:dragging=$false; $script:panning=$false; $grid.ReleaseMouseCapture() | Out-Null })
$grid.Add_MouseWheel({
    param($s,$e)
    $factor = if ($e.Delta -gt 0) { 0.88 } else { 1.136 }
    $script:rad = [math]::Max(0.2, [math]::Min(200.0, $script:rad * $factor)); Update-Camera
})

# ---- selection drives BOTH views ----
$script:cbo.Add_SelectedIndexChanged({
    $i = $script:cbo.SelectedIndex
    if ($i -lt 0 -or $i -ge $script:presets.Count) { return }
    Set-Bushing $script:presets[$i]
    Rebuild-3D; Fit-View; Update-Info
    $script:svg2d.Invalidate()
})

# ---- first paint: pick a sensible default (a headed drill bushing if present) ----
$defaultIdx = 0
for ($k = 0; $k -lt $script:presets.Count; $k++) { if ($script:presets[$k].Name -match '(?i)drill bushing') { $defaultIdx = $k; break } }
$form.Add_Shown({
    $script:cbo.SelectedIndex = $defaultIdx
    if ($script:cbo.SelectedIndex -eq $defaultIdx) { Set-Bushing $script:presets[$defaultIdx]; Rebuild-3D; Fit-View; Update-Info; $script:svg2d.Invalidate() }
    $form.Activate()
})

[void]$form.ShowDialog()
