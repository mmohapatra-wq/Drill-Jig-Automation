# ============================================================================
# render_bushing3d_check.ps1 - headless render assertion for the WPF Media3D
# bushing preview (bushing-3d-preview.cmd + Build-BushingModelGroup in
# lib\wpf3d_preview.ps1).
# ============================================================================
# Proves the WPF Media3D bushing pipeline actually RASTERIZES on this machine
# (not just parses): builds a HEADED drill bushing and a HEADLESS sleeve via
# Build-BushingModelGroup, asserts their model counts (6 vs 4), renders a
# code-built Viewport3D off-screen through RenderTargetBitmap, and asserts a
# healthy non-empty pixel count. Also checks the head rule (Get-BushingHeadDia).
#
# WPF needs an STA thread; this script RE-LAUNCHES itself under -STA when the host
# is MTA, so a plain `powershell -File ...` works (offline runner / converge harness).
# ============================================================================
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-STA','-File', $MyInvocation.MyCommand.Path
    ) -Wait -PassThru -NoNewWindow
    exit $p.ExitCode
}

$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here
. (Join-Path $libDir 'bushing_svg.ps1')
. (Join-Path $libDir 'wpf3d_preview.ps1')
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase

$fail = 0

# ---- 1) head rule + model counts -------------------------------------------
$hd = Get-BushingHeadDia -EasyName 'Drill Bushing | OD 1/2 x ID 1/4 x 1/4 Lg' -OD 0.5
if ($hd -le 0.5) { Write-Host "  [FAIL] drill bushing not headed (headDia=$hd)"; $fail = 1 }
if ((Get-BushingHeadDia -EasyName 'Sleeve | OD 3/4 x ID 1/2 x 3/4 Lg' -OD 0.75) -ne 0) { Write-Host "  [FAIL] sleeve should be headless"; $fail = 1 }

$gh = Build-BushingModelGroup -OD 0.5 -ID 0.25 -Length 0.25 -HeadDia $hd -Segments 40
if ($gh.Children.Count -eq 6) { Write-Host "  [PASS] headed drill bushing -> 6 models (bore, body, bottom, head, shoulder, top)" }
else { Write-Host ("  [FAIL] headed -> {0} models, expected 6" -f $gh.Children.Count); $fail = 1 }

$gs = Build-BushingModelGroup -OD 0.75 -ID 0.5 -Length 0.75 -HeadDia 0 -Segments 40
if ($gs.Children.Count -eq 4) { Write-Host "  [PASS] headless sleeve -> 4 models (bore, body, bottom, top)" }
else { Write-Host ("  [FAIL] headless -> {0} models, expected 4" -f $gs.Children.Count); $fail = 1 }

$gi = Build-BushingModelGroup -OD 0.5 -ID 0.6 -Length 0.5
if ($gi.Children.Count -eq 0) { Write-Host "  [PASS] invalid (ID>=OD) -> empty group" }
else { Write-Host ("  [FAIL] invalid -> {0} models, expected 0" -f $gi.Children.Count); $fail = 1 }

# every mesh (headed AND headless) must carry positions + triangles
$badMesh = 0
foreach ($grp in @($gh, $gs)) { foreach ($m in $grp.Children) { if ($m.Geometry.Positions.Count -lt 3 -or $m.Geometry.TriangleIndices.Count -lt 3) { $badMesh++ } } }
if ($badMesh -eq 0) { Write-Host "  [PASS] all bushing meshes (headed + headless) have positions + triangles" }
else { Write-Host ("  [FAIL] {0} mesh(es) missing geometry" -f $badMesh); $fail = 1 }

# ---- 2) render the headed bushing off-screen and assert pixels -------------
$gh.Children.Add((New-Object System.Windows.Media.Media3D.AmbientLight([System.Windows.Media.Color]::FromRgb(120,130,150))))
$gh.Children.Add((New-Object System.Windows.Media.Media3D.DirectionalLight([System.Windows.Media.Color]::FromRgb(255,255,255), (New-Object System.Windows.Media.Media3D.Vector3D(-0.5,-1,-0.6)))))
$mv = New-Object System.Windows.Media.Media3D.ModelVisual3D; $mv.Content = $gh
$vp = New-Object System.Windows.Controls.Viewport3D
$cam = New-Object System.Windows.Media.Media3D.PerspectiveCamera; $cam.FieldOfView = 46
$cam.Position = New-Object System.Windows.Media.Media3D.Point3D(0.9,1.1,1.3)
$cam.LookDirection = New-Object System.Windows.Media.Media3D.Vector3D(-0.9,-1.1,-1.3)
$cam.UpDirection = New-Object System.Windows.Media.Media3D.Vector3D(0,1,0)
$vp.Camera = $cam; $vp.Children.Add($mv)
$W = 320; $H = 260; $vp.Width = $W; $vp.Height = $H
$vp.Measure((New-Object System.Windows.Size($W,$H)))
$vp.Arrange((New-Object System.Windows.Rect(0,0,$W,$H)))
$vp.UpdateLayout()
$rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($W,$H,96,96,[System.Windows.Media.PixelFormats]::Pbgra32)
$rtb.Render($vp)
$stride = $W*4; $buf = New-Object byte[] ($H*$stride); $rtb.CopyPixels($buf,$stride,0)
$nonEmpty = 0
for ($i=0; $i -lt $buf.Length; $i+=4) { if ($buf[$i] -or $buf[$i+1] -or $buf[$i+2] -or $buf[$i+3]) { $nonEmpty++ } }
if ($nonEmpty -gt 500) { Write-Host ("  [PASS] WPF Media3D rasterized {0} non-empty px" -f $nonEmpty) }
else { Write-Host ("  [FAIL] render produced only {0} px" -f $nonEmpty); $fail = 1 }

if ($fail -eq 0) { Write-Host "render_bushing3d_check: ALL PASS"; exit 0 } else { Write-Host "render_bushing3d_check: FAILURES"; exit 1 }
