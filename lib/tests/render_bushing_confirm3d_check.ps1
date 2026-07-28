# ============================================================================
# render_bushing_confirm3d_check.ps1 - integration check: the drilljig-gui bushing
# CONFIRMATION page shows the 3D bushing model NEXT TO the 2D schematic, headed for
# a drill bushing and headless for a sleeve (user 2026-07-22).
# ============================================================================
# Drives the REAL tree-step Build extracted from drilljig-gui.cmd (Creo COM stubbed,
# no wizard window) with WPF enabled ($script:Wpf3dOk = $true), for a DRILL pick and a
# SLEEVE pick, and asserts:
#   * a 2D schematic Panel AND a WPF ElementHost are both added to the confirmation
#   * the ElementHost's Viewport3D carries the bushing Model3DGroup with the right
#     model count (6 = headed drill, 4 = headless sleeve) -> the 3D actually reflects
#     drill-vs-sleeve, and the WPF pipeline rasterizes it (RenderTargetBitmap pixels)
#   * with WPF OFF ($script:Wpf3dOk = $false) NO ElementHost is added (2D-only fallback)
#
# WPF needs STA; self-relaunches under -STA when the host is MTA. Exit 0 = pass.
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
$root   = Split-Path -Parent $libDir

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName WindowsFormsIntegration

. (Join-Path $libDir 'creo_geometry.ps1')
. (Join-Path $libDir 'orthogrid.ps1')
. (Join-Path $libDir 'orthogrid_points.ps1')
. (Join-Path $libDir 'fastener_layout.ps1')
. (Join-Path $libDir 'drilljig_core.ps1')
. (Join-Path $libDir 'bushing_svg.ps1')
. (Join-Path $libDir 'wpf3d_preview.ps1')
. (Join-Path $libDir 'wizard.ps1')

$fail = 0
function Chk($n,$c){ if($c){Write-Host "  [PASS] $n"}else{Write-Host "  [FAIL] $n";$script:fail=1} }

# top-level vars the steps region reads (mirror the .cmd + fuzz_gui harness)
$ScriptDir = $root + '\'; $ScriptArgs = ''
$dataDir = Join-Path $root 'data'
$cornerRadius = 0.25; $noCornerRound = $false
$SLOT_DEPTH_ABS = 0.25; $slotDepthFromFlagG = $false; $slotFlipDefault = $false
$slotPatternFlip = $false; $slotNoPattern = $false; $noSlotRelief = $false
$noBaseCsys = $false; $indexFlipX = 1.0; $indexFlipZ = 1.0
$fakeModel = [pscustomobject]@{ VersionStamp = 1 }
$model = $fakeModel; $session = $null; $pfcType = $null; $modelFile = 'jig.prt'
$script:model = $fakeModel; $script:session = $null; $script:connection = $null; $script:macroFailures = 0

# extract the GUI helper region (defines New-BushingViewportHost, Add-Para, Get-UiColor, ...)
$src = Get-Content -Raw (Join-Path $root 'pipeline\drilljig-gui.cmd')
$h0 = $src.IndexOf('# STEP BUILDERS'); $h1 = $src.IndexOf('# Build the connection up front')
if ($h0 -lt 0 -or $h1 -lt 0) { Write-Host "  [FAIL] could not find helper region markers"; exit 1 }
Invoke-Expression $src.Substring($h0, $h1 - $h0) | Out-Null

# minimal fake wiz + ctx for the tree-step confirmation branch
function New-Wiz {
    $w = [pscustomobject]@{}
    foreach ($m in 'SetChip','Refresh','Log','Pump','SetProgress','BeginRun','EndRun','MarkCommitted','SetStatus','LogError','Next','Rerender','GoToStepKey') {
        $w | Add-Member ScriptMethod $m { param($a,$b,$c) } -Force
    }
    $w | Add-Member ScriptMethod AskInline { param($h,$t,$b='OK',$n=$false) 'OK' } -Force
    return $w
}
$ctx = @{ TreePath = Join-Path $root 'docs\drill_jig_decision_tree.json' }   # steps region reads $ctx.TreePath

# extract + define the wizard steps
$siR = $src.IndexOf('# WIZARD STEPS'); $eiR = $src.IndexOf('# RUN THE WIZARD')
if ($siR -lt 0 -or $eiR -lt 0) { Write-Host "  [FAIL] could not find steps region markers"; exit 1 }
$steps = New-Object System.Collections.ArrayList
Invoke-Expression $src.Substring($siR, $eiR - $siR) | Out-Null
$treeStep = @($steps.ToArray()) | Where-Object { $_.Key -eq 'tree' } | Select-Object -First 1
Chk "extracted the tree step" ($null -ne $treeStep)

function New-Ctx($pick) {
    $c = @{ TreeDone=$true; PendingSpec=$null; Picks=[System.Collections.ArrayList]::new(); TreeHistory=[System.Collections.ArrayList]::new()
            TreeNode=[pscustomobject]@{ label='x' } }
    [void]$c.Picks.Add($pick)
    return $c
}
function Render-Confirm($pick) {
    $c = New-Ctx $pick; $wiz = New-Wiz
    $pnl = New-Object System.Windows.Forms.Panel; $pnl.Size = New-Object System.Drawing.Size(920, 700)
    & $treeStep.Build $pnl $c $wiz | Out-Null
    return $pnl
}
# find the WPF Model3DGroup (the bushing) inside an ElementHost's Viewport3D
function Get-3dModelGroup($pnl) {
    $eh = @($pnl.Controls | Where-Object { $_ -is [System.Windows.Forms.Integration.ElementHost] }) | Select-Object -First 1
    if ($null -eq $eh) { return $null }
    $grid = $eh.Child
    $vp = @($grid.Children) | Where-Object { $_ -is [System.Windows.Controls.Viewport3D] } | Select-Object -First 1
    if ($null -eq $vp) { return $null }
    # pick the BUSHING group (children are GeometryModel3D), NOT the lights group
    # (children are Light objects) - both are Model3DGroups in the viewport.
    foreach ($mv in $vp.Children) {
        if ($mv.Content -is [System.Windows.Media.Media3D.Model3DGroup]) {
            $grp = $mv.Content
            if ($grp.Children.Count -gt 0 -and $grp.Children[0] -is [System.Windows.Media.Media3D.GeometryModel3D]) { return $grp }
        }
    }
    return $null
}

# ---- WPF ON: drill (headed, 6) + sleeve (headless, 4) ----
$script:Wpf3dOk = $true

$drill = [pscustomobject]@{ HoleDiameter=0.5; BushingID=0.25; BushingLength=0.25; Bushing='Drill Bushing | OD 1/2 x ID 1/4 x 1/4 Lg'; PartNumber='8493A072'; Outcome='x' }
$pd = Render-Confirm $drill
$has2d_d = (@($pd.Controls | Where-Object { $_ -is [System.Windows.Forms.Panel] }).Count -ge 1)
$eh_d = (@($pd.Controls | Where-Object { $_ -is [System.Windows.Forms.Integration.ElementHost] }).Count -ge 1)
Chk "drill: 2D schematic Panel present" $has2d_d
Chk "drill: 3D ElementHost present"     $eh_d
$mg_d = Get-3dModelGroup $pd
Chk "drill: 3D model is HEADED (6 models)" ($null -ne $mg_d -and $mg_d.Children.Count -eq 6)

$sleeve = [pscustomobject]@{ HoleDiameter=0.75; BushingID=0.5; BushingLength=0.75; Bushing='Sleeve | OD 3/4 x ID 1/2 x 3/4 Lg'; PartNumber='3556N158'; Outcome='x' }
$ps = Render-Confirm $sleeve
$mg_s = Get-3dModelGroup $ps
Chk "sleeve: 3D model is HEADLESS (4 models)" ($null -ne $mg_s -and $mg_s.Children.Count -eq 4)

# rasterize the drill viewport off-screen -> real pixels
$eh = @($pd.Controls | Where-Object { $_ -is [System.Windows.Forms.Integration.ElementHost] }) | Select-Object -First 1
$vp = @($eh.Child.Children) | Where-Object { $_ -is [System.Windows.Controls.Viewport3D] } | Select-Object -First 1
$W=300;$H=240; $vp.Width=$W; $vp.Height=$H
$vp.Measure((New-Object System.Windows.Size($W,$H))); $vp.Arrange((New-Object System.Windows.Rect(0,0,$W,$H))); $vp.UpdateLayout()
$rtb=New-Object System.Windows.Media.Imaging.RenderTargetBitmap($W,$H,96,96,[System.Windows.Media.PixelFormats]::Pbgra32); $rtb.Render($vp)
$stride=$W*4;$buf=New-Object byte[] ($H*$stride);$rtb.CopyPixels($buf,$stride,0)
$ne=0; for($i=0;$i -lt $buf.Length;$i+=4){ if($buf[$i]-or$buf[$i+1]-or$buf[$i+2]-or$buf[$i+3]){$ne++} }
Chk "drill: confirmation 3D viewport rasterizes ($ne px)" ($ne -gt 500)

# ---- WPF OFF: no ElementHost (2D-only fallback) ----
$script:Wpf3dOk = $false
$pOff = Render-Confirm $drill
$ehOff = (@($pOff.Controls | Where-Object { $_ -is [System.Windows.Forms.Integration.ElementHost] }).Count)
Chk "WPF off: 2D-only (no ElementHost added)" ($ehOff -eq 0)
Chk "WPF off: 2D schematic still present" (@($pOff.Controls | Where-Object { $_ -is [System.Windows.Forms.Panel] }).Count -ge 1)

if ($fail -eq 0) { Write-Host "render_bushing_confirm3d_check: ALL PASS"; exit 0 } else { Write-Host "render_bushing_confirm3d_check: FAILURES"; exit 1 }
