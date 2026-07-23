# ============================================================================
# render_drilljig3d_check.ps1 - headless render assertion for the WPF Media3D
# drill-jig preview (drilljig-3d-preview.cmd + lib\wpf3d_preview.ps1).
# ============================================================================
# Proves the WPF Media3D pipeline actually RASTERIZES the jig on this machine
# (not just that the code parses): dot-sources the REAL Get-OrthogridGeometry +
# the shared mesh builders, builds the plate + bores + slot markers via
# Build-JigModelGroup, renders a code-built Viewport3D off-screen through
# RenderTargetBitmap, and asserts a healthy count of non-empty pixels. Also runs
# a 5-case geometry self-test against the production function. Exit 0 = pass.
#
# WPF requires an STA thread; this script RE-LAUNCHES itself under -STA when the
# host is MTA, so `powershell -File render_drilljig3d_check.ps1` works either way
# (the offline runner / converge harness invoke it plainly).
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
. (Join-Path $libDir 'orthogrid.ps1')
. (Join-Path $libDir 'wpf3d_preview.ps1')
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase

$fail = 0

# ---- 1) geometry self-test vs the REAL production function -----------------
$cases = @(
  @{n='default'; in=@(0.5,0.5,5,4,0.25,0.25,0.25,0.25);      exp=@{v=$true; w=2.75; h=2.25; c=20; e=0; s=4}},
  @{n='single';  in=@(0.5,0.5,1,1,0.5,0.5,0.5,0.5);          exp=@{v=$true; w=1.5;  h=1.5;  c=1;  e=0; s=1}},
  @{n='collideX';in=@(0.4,0.6,3,3,0.5,0.5,0.5,0.5);          exp=@{v=$false;w=2.3;  h=2.7;  c=9;  e=1}},
  @{n='edgefail';in=@(0.6,0.6,3,3,0.1,0.5,0.5,0.5);          exp=@{v=$false;w=1.9;  h=1.9;  c=9;  e=1}},
  @{n='wide';    in=@(0.75,0.5,8,3,0.375,0.375,0.375,0.375); exp=@{v=$true; w=6.375;h=2.125;c=24; e=0; s=3}}
)
$T = 1e-4; $sfails = @()
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
    if ($f.Count) { $sfails += ("{0}:{1}" -f $c.n, ($f -join ',')) }
}
if ($sfails.Count -eq 0) { Write-Host "  [PASS] geometry self-test 5/5 (matches Get-OrthogridGeometry)" }
else { Write-Host ("  [FAIL] geometry self-test: " + ($sfails -join ' | ')); $fail = 1 }

# ---- 2) build the shared model group + count its children ------------------
$g = Get-OrthogridGeometry -CcX 0.5 -CcZ 0.5 -Nx 5 -Nz 4 -Edge 0.25 -ClearDia 0.25 -HoleDia 0.25 -EdgeMargin 0.25
$grp = Build-JigModelGroup -Geo $g -Thickness 1.0 -HoleDia 0.25 -SlotDepth 0.25 -ShowSlots -Segments 16
# expect: 1 plate + 20 bores + 4 slot rows = 25 models
$expected = 1 + $g.Count + 4
if ($grp.Children.Count -eq $expected) { Write-Host ("  [PASS] Build-JigModelGroup -> {0} models (plate + {1} bores + 4 slots)" -f $grp.Children.Count, $g.Count) }
else { Write-Host ("  [FAIL] Build-JigModelGroup -> {0} models, expected {1}" -f $grp.Children.Count, $expected); $fail = 1 }

# ---- 3) render the group off-screen and assert pixels ----------------------
$grp.Children.Add((New-Object System.Windows.Media.Media3D.AmbientLight([System.Windows.Media.Color]::FromRgb(120,130,150))))
$grp.Children.Add((New-Object System.Windows.Media.Media3D.DirectionalLight([System.Windows.Media.Color]::FromRgb(255,255,255), (New-Object System.Windows.Media.Media3D.Vector3D(-0.5,-1,-0.6)))))
$mv = New-Object System.Windows.Media.Media3D.ModelVisual3D; $mv.Content = $grp
$vp = New-Object System.Windows.Controls.Viewport3D
$cam = New-Object System.Windows.Media.Media3D.PerspectiveCamera; $cam.FieldOfView = 48
$cam.Position = New-Object System.Windows.Media.Media3D.Point3D(4,5,6)
$cam.LookDirection = New-Object System.Windows.Media.Media3D.Vector3D(-4,-4.5,-6)
$cam.UpDirection = New-Object System.Windows.Media.Media3D.Vector3D(0,1,0)
$vp.Camera = $cam; $vp.Children.Add($mv)
$W = 320; $H = 240; $vp.Width = $W; $vp.Height = $H
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

if ($fail -eq 0) { Write-Host "render_drilljig3d_check: ALL PASS"; exit 0 } else { Write-Host "render_drilljig3d_check: FAILURES"; exit 1 }
