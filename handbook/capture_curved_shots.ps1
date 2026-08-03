<#  Headless screenshot capture of the CURVED drilljig3d-gui wizard PAGES.
    The curved analog of handbook\capture_shots.ps1: it renders each real curved
    wizard step's Build into an off-screen panel dressed in the live dark theme
    (breadcrumb + title + body + Back/primary bar) and DrawToBitmap -> PNG. No
    window is shown, no message loop, no Creo.

    It FUSES two proven harnesses:
      * handbook\capture_shots.ps1  -> the themed-frame + hand-painted breadcrumb
        + Capture-Page -> PNG renderer (flat GUI).
      * lib\tests\fuzz_curved_gui.ps1 -> the curved lib dot-source set + the COM
        stubs + New-CurvedCtx / New-CurvedWiz + the Set-* mid-run state builders.

    Unlike the flat capture (which extracts step regions from the .cmd via string
    markers), the curved GUI exposes its steps as GLOBAL functions, so the step
    list is built by calling Add-CurvedInputFirstSteps -Steps $steps (exactly what
    the shell drilljig3d-gui.cmd builds). $script:Wpf3dOk stays $false so the
    bushing confirmation renders its GDI+ 2D schematic (no WPF/STA needed).

    Output: handbook\shots\c01-welcome.png .. c10-done.png (one per live step).
    Run:  powershell -ExecutionPolicy Bypass -File handbook\capture_curved_shots.ps1  #>

$ErrorActionPreference = 'Stop'
$root   = Split-Path $PSScriptRoot -Parent   # repo root (handbook/..)
$libDir = Join-Path $root 'lib'
$shots  = Join-Path $PSScriptRoot 'shots'
if (-not (Test-Path $shots)) { New-Item -ItemType Directory -Force -Path $shots | Out-Null }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- dot-source the real curved libs (the exact set drilljig3d-gui.cmd loads) ---
. (Join-Path $libDir 'creo_geometry.ps1')
. (Join-Path $libDir 'blind_evaluator.ps1')
. (Join-Path $libDir 'drilljig_core.ps1')
. (Join-Path $libDir 'conformal_blank.ps1')
. (Join-Path $libDir 'edge_round.ps1')
. (Join-Path $libDir 'curved_fastener_hole.ps1')
. (Join-Path $libDir 'tangent_plane.ps1')
. (Join-Path $libDir 'curved_slots.ps1')
. (Join-Path $libDir 'curved_slot_macros.ps1')
. (Join-Path $libDir 'curved_relief.ps1')
. (Join-Path $libDir 'curved_radial.ps1')
. (Join-Path $libDir 'curved_surface_radius.ps1')
. (Join-Path $libDir 'wizard.ps1')
. (Join-Path $libDir 'bushing_svg.ps1')
. (Join-Path $libDir 'wpf3d_preview.ps1')
$script:Wpf3dOk = $false   # 2D GDI+ bushing schematic only (no WPF/STA); matches the fuzz harness
. (Join-Path $libDir 'curved_gui_helpers.ps1')
. (Join-Path $libDir 'curved_gui_steps_bushing.ps1')
. (Join-Path $libDir 'curved_gui_steps_surface.ps1')
. (Join-Path $libDir 'curved_gui_steps_fastener.ps1')
. (Join-Path $libDir 'curved_gui_steps_build.ps1')
. (Join-Path $libDir 'curved_gui_steps_slots.ps1')
. (Join-Path $libDir 'curved_gui_steps_done.ps1')
. (Join-Path $libDir 'curved_gui_steps_compose.ps1')

# --- STUB only the COM-touching functions (canned valid-shaped returns, from
#     fuzz_curved_gui.ps1). The PURE pieces (bushing catalog resolvers, macro
#     builders, the radial-plan math) run FOR REAL, so every Build renders populated. ---
function Initialize-DrilljigCore { param($Session,$Model,$TypeObj,$DataDir,$Log) }
function Invoke-ConformalBlank {
    param($Session,$Model,$TypeObj,$SurfIds,$Thickness,$StandOff,[switch]$Flip,$OnPoll,$TimeoutMs)
    if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }
    @{ Made=$true; Changed=$true; OffsetSym='d7'; ThickSym='d9'; OffsetHeld=$true; ThicknessHeld=$true;
       BodyIndex=1; BodyId=20; BodyName='CONFORMAL_BLANK'; Reason='' }
}
function Invoke-TangentPlane {
    param($PointId,$SurfaceId,$OnPoll)
    if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }
    @{ Created=$true; PlaneId=(900 + [int]$PointId); Reason='' }
}
function Invoke-CurvedCornerRound {
    param($Session,$Model,$TypeObj,$Radius=0.25,$Thickness=0,$Tol=0.05,$SweepMax=5000,$BatchSize=40,$OnPoll=$null)
    if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }
    $mode = if ($Thickness -gt 0) { 'thickness' } else { 'auto' }
    $tgt  = if ($Thickness -gt 0) { [double]$Thickness } else { 0.25 }
    @{ Found=8; Target=$tgt; Matched=4; SelfTestOk=$true; BatchesFired=1; ModelChanged=1;
       TotalBatches=1; Aborted=$false; Reason=("rounded 4 edge(s)"); Mode=$mode;
       Lengths=@(@{Len=$tgt;Count=4},@{Len=6.0;Count=4}); LengthSummary=("{0}x4, 6x4" -f $tgt) }
}
function Add-ComponentDefaultPlanesToBuffer {
    param($Session,$Model,$TypeObj,$ComponentPath,[switch]$NoClear)
    @{ Added=3; Roles=@('Top','Side','Front'); Ids=@(11,12,13); Reason='added 3 plane(s): Top/Side/Front' }
}
function Resolve-SelectedPlaneIds { param($Session,$TypeObj) @{ Ids=@(11,12,13); Names=@('TOP','SIDE','FRONT'); Roles=@('Top','Side','Front') } }
function Get-DatumPointIdSet       { param($Model,$TypeObj) @{} }
function Resolve-NewDatumPointIds  { param($Model,$TypeObj,$Before) @(201) }
function Invoke-FastenerPoint      { param($Session,$Model,$TypeObj,$OnPoll,$TimeoutMs) if ($null -ne $OnPoll) { try { & $OnPoll } catch {} } @{ Created=$true; PointId=201; ViaStamp=$false; Reason='' } }
function Invoke-FastenerHole       { param($Session,$Model,$TypeObj,$PointId,$ComponentPath,$TopPlaneId,$DirectionPrompt,$OnPoll,$TimeoutMs) if ($null -ne $OnPoll) { try { & $OnPoll } catch {} } $viaPlane = ($null -ne $ComponentPath -and [int]$TopPlaneId -gt 0); @{ Drilled=$true; ViaPlane=$viaPlane; Reason='' } }
function Invoke-FastenerReliefArm  { param($Session,$Model,$TypeObj,$ComponentPath,$PointId=0,$SurfaceId=0,$HoleDia=0.0,$TopPlaneId=1,[switch]$GuidePlanes,$PlanePrompt,$OnPoll,$TimeoutMs=30000) if ($null -ne $OnPoll) { try { & $OnPoll } catch {} } @{ Armed=$true; ViaPlane=($null -ne $ComponentPath); PlaneId=0; BaseFeat=@{}; BaseStamp=1; Reason='' } }
function Invoke-FastenerReliefCut  { param($Session,$Model,$SymDepth=0.0,$BodyIndex=0,$BaseFeat,$BaseStamp,$OnPoll,$TimeoutMs=30000) if ($null -ne $OnPoll) { try { & $OnPoll } catch {} } if ($null -eq $BaseStamp) { return @{ Cut=$false; Reason='no baseline' } } @{ Cut=$true; Reason='' } }
function Invoke-FastenerRelief     { param($Session,$Model,$TypeObj,$ComponentPath,$TopPlaneId,$ReliefDepth,$BodyIndex,$PointId=0,$SurfaceId=0,$HoleDia=0.0,[switch]$GuidePlanes,$DrawPrompt,$PlanePrompt,$OnPoll,$TimeoutMs) if ([double]$ReliefDepth -le 0) { return @{ Cut=$false; ViaPlane=$false; Reason='relief depth <= 0' } } if ($null -ne $OnPoll) { try { & $OnPoll } catch {} } @{ Cut=$true; ViaPlane=([int]$PointId -gt 0 -and [int]$SurfaceId -gt 0); Reason='' } }
function Invoke-CurvedReliefRadialPattern { param($Session,$Model,$TypeObj,$SeedFeatId,$Count,$IncrementDeg,$AxisFeatId=0,[switch]$UseLiveSelection,$AxisPrompt=$null,$OnPoll=$null,$TimeoutMs=30000) if ($null -ne $OnPoll) { try { & $OnPoll } catch {} } @{ Patterned=$true; NewFeatures=([Math]::Max(1,[int]$Count-1)); ViaAxisId=([int]$AxisFeatId -gt 0); SeedSelected=$true; Reason='' } }
function New-CurvedGuidePlanes { param($Session,$Model,$TypeObj,$ComponentPath,$HoleDia=0.5,$Margin=0.125,$Log=$null,$OnPoll=$null,$TimeoutMs=15000) @{ Ids=@(801,802) } }
function Get-BufferComponentPath   { param($Session) return $null }
function Get-FeatureIdSet {
    $set = @{}
    $v = 0; try { $v = [int]$script:cfModel.VersionStamp } catch { $v = 0 }
    for ($i = 1; $i -le $v; $i++) { $set[(1000 + $i)] = $true }
    return $set
}
function Resolve-SelectedSurfaces { param($Session,$TypeObj) @{ Surfaces=@(41); Rejected=@() } }
function Resolve-SelectedPoints   { param($Session,$TypeObj) @{ Points=@(201,202,203); Rejected=@() } }
function Get-Comp { param($P) @(0.0, 0.0, 0.0) }
function Wait-ModelModified {
    param($Model,$PreviousStamp,$TimeoutMs=30000,$OnPoll=$null)
    if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }
    return $true
}

# --- fake $model / $session (from fuzz; a .prt FileName so any active-model gate passes) ---
$script:cfActiveName = '004-984-3965-001.prt'
$fakeModel = [pscustomobject]@{ VersionStamp = 1; FileName = '004-984-3965-001.prt' }
$fakeModel | Add-Member ScriptMethod Regenerate { param($x) } -Force
$fakeModel | Add-Member ScriptMethod GetActiveModel { $this } -Force -ErrorAction SilentlyContinue
$fakeSession = [pscustomobject]@{}
$fakeSession | Add-Member ScriptMethod RunMacro { param($m) $script:cfModel.VersionStamp = ([int]$script:cfModel.VersionStamp + 1) } -Force
$fakeSession | Add-Member ScriptMethod GetActiveModel { [pscustomobject]@{ FileName = $script:cfActiveName } } -Force
$fakeSession | Add-Member ScriptMethod CurrentSelectionBuffer { $b = [pscustomobject]@{ }; $b | Add-Member ScriptMethod Clear {} -Force; $b | Add-Member ScriptMethod Contents { @() } -Force; $b } -Force
$script:cfModel = $fakeModel; $script:cfSession = $fakeSession

$ScriptDir = $root; $ScriptArgs = ''
$script:macroFailures = 0
$treePath = Join-Path $root 'docs\drill_jig_decision_tree.json'

# --- theme (mirror capture_shots.ps1 so Get-UiColor + cards render dark-on-blue) ---
$accentColor = [System.Drawing.Color]::FromArgb(64,132,232)
$formBack    = [System.Drawing.Color]::FromArgb(20,30,52)
$canvasBack  = [System.Drawing.Color]::FromArgb(30,42,68)
$inkColor    = [System.Drawing.Color]::FromArgb(238,242,248)
$mutedColor  = [System.Drawing.Color]::FromArgb(158,172,196)
$script:WizTheme = [pscustomobject]@{
  Accent=$accentColor; FormBack=$formBack; CanvasBack=$canvasBack; Ink=$inkColor; Muted=$mutedColor
  CardBack=[System.Drawing.Color]::FromArgb(40,54,84); CardHover=[System.Drawing.Color]::FromArgb(54,72,112)
  Ok=[System.Drawing.Color]::FromArgb(120,210,150); Warn=[System.Drawing.Color]::FromArgb(245,200,90); Err=[System.Drawing.Color]::FromArgb(245,120,110)
}

# --- fresh $ctx (mirror the drilljig3d-gui.cmd initializer, from fuzz New-CurvedCtx) ---
function New-CurvedCtx {
    $c = @{
        Session = $fakeSession; Model = $fakeModel; Type = $null
        TreeRoot = $null; TreeNode = $null; TreeDone = $false
        TreeHistory = [System.Collections.ArrayList]::new()
        Path  = [System.Collections.ArrayList]::new()
        Picks = [System.Collections.ArrayList]::new()
        PendingSpec = $null; BushStage = $null
        BushID = $null; BushOdFirst = $false; BushOdGroups = $null; BushOD = $null; BushOdOptions = $null
        BushLenValue = $null; BushLenLabel = $null; BushLenIsCustom = $false; BushLenCustomText = ''; BushLenValid = $true
        BushCustom = $false; BushCustomOd = $null; BushCustomOdLabel = $null; BushCustomOdText = ''; BushCustomOdValid = $false
        Grouped = $null
        HoleDia = $null; HoleDiaFinal = $null; BushingLen = $null
        Thickness = $null; ThicknessValid = $false; StandOff = 0.0; StandOffValid = $true
        SurfIds = @(); BlankMade = $false; SurfaceArmed = $false
        BodyIndex = $null; BodyId = $null; BodyName = $null
        FastenerComponents = @(); FastenerSurfId = $null
        FastenerHoleDia = $null; FastenerHoleDiaValid = $false; FastenerHolesMade = 0
        DrillPerHole = $false; HolePairs = @(); HoleDiaDrill = $null; HoleDiaDrillValid = $false; DrillArmed = $false
        HolesMade = 0; CurvedHolePairs = @(); CurvedHoleDiaFinal = $null
        TangentOrient = $true; DefaultOrient = $false; FlipThicken = $false
        NoSlots = $false; SlotDepthAbs = 0.25
        SlotSkip = $false; SlotPlan = $null; SlotsCut = $false
        SlotArmed = $false; SlotRunIndex = 0; SlotsDone = $false; SlotAnyCut = $false
        SlotBaseFeat = @{}; SlotBaseStamp = $null; SlotRearmFails = 0
        SlotPatternMode = 'perfastener'; SlotRadialGroups = $null; SlotSeedFeatId = 0
        NoRadialPattern = $false; RadialAxisFeatId = 0; RadialAxisGeom = $null
        ReliefDepth = 0.25; ReliefDepthValid = $true; ReliefsCut = 0; ReliefComponents = @()
        ChipClearance = 0.25; ChipClearanceValid = $true; ClearanceMode = $null
        NoCornerRound = $false; CornerRadius = 0.25; CornersRounded = $false; BlankThickness = $null
        Is3dPrint = $false
    }
    try {
        $tr = Get-Content $treePath -Raw | ConvertFrom-Json
        $c.TreeRoot = @($tr)[0]; $c.TreeNode = @($tr)[0]
    } catch {}
    return $c
}

# --- fake $wiz controller with every method the curved steps call (from fuzz) ---
function New-CurvedWiz {
    $w = [pscustomobject]@{ Answer = 'Yes' }
    foreach ($m in 'SetChip','Refresh','Log','Pump','SetProgress','BeginRun','EndRun','MarkCommitted','SetStatus','Next','Rerender','GoToStepKey') {
        $w | Add-Member ScriptMethod $m { param($a,$b,$c) } -Force
    }
    $w | Add-Member ScriptMethod AskInline { param($h,$t,$btns='OK',$noact=$false) return $this.Answer } -Force
    $w | Add-Member ScriptMethod LogError { param($e,$where) } -Force
    return $w
}

# --- mid-run $ctx state builders (from fuzz Set-* helpers) ---
function Set-Bushing { param($C, [double]$Dia = 0.5)
    $C.HoleDia = $Dia; $C.HoleDiaFinal = $Dia; $C.BushingLen = 0.75
    $C.TreeDone = $true
    [void]$C.Picks.Add([pscustomobject]@{ HoleDiameter=$Dia; BushingID=0.25; BushingLength=0.75; Bushing='Drill Bushing | OD 1/2 x ID 1/4'; PartNumber='8493A072'; Outcome='x' })
}
function Set-Surface { param($C) $C.SurfIds = @(41); $C.Thickness = 0.25; $C.ThicknessValid = $true; $C.StandOff = 0.0; $C.StandOffValid = $true }
function Set-Blank   { param($C) Set-Surface $C; $C.BlankMade = $true; $C.BodyIndex = 1; $C.BodyId = 20; $C.BodyName = 'CONFORMAL_BLANK'; $C.BlankThickness = 0.5 }
function Set-Fasteners { param($C)
    Set-Blank $C
    $C.FastenerComponents = @(
        [pscustomobject]@{ Path = $null; CompIds = @(7);  Origin = @(0.0,0.0,0.0) }
        [pscustomobject]@{ Path = $null; CompIds = @(8);  Origin = @(1.0,0.0,0.0) }
    )
    $C.FastenerSurfId = 41
    $C.FastenerHoleDia = 0.5; $C.FastenerHoleDiaValid = $true
}
function Set-Holes   { param($C)
    Set-Blank $C
    $C.HolePairs = @(
        [pscustomobject]@{ PointId=201; SurfaceId=41; TangentPlaneId=0 }
        [pscustomobject]@{ PointId=202; SurfaceId=41; TangentPlaneId=0 }
    )
    $C.HoleDiaDrill = 0.5; $C.HoleDiaDrillValid = $true
}
function Set-Drilled { param($C)
    Set-Holes $C
    $C.HolesMade = 2
    $C.CurvedHolePairs = @(
        [pscustomobject]@{ PointId=201; TopPlaneId=1; ViaPlane=$true; ReliefCut=$false; CompPath=([pscustomobject]@{}) }
        [pscustomobject]@{ PointId=202; TopPlaneId=1; ViaPlane=$true; ReliefCut=$false; CompPath=([pscustomobject]@{}) }
    )
    $C.CurvedHoleDiaFinal = 0.5
    $C.FastenerSurfId = 41
    $C.FastenerHolesMade = 2
}
function Set-Inputs { param($C)
    Set-Bushing $C
    $C.SurfIds = @(41); $C.Thickness = 0.25; $C.ThicknessValid = $true; $C.StandOff = 0.0; $C.StandOffValid = $true
    $C.FastenerComponents = @(
        [pscustomobject]@{ Path = $null; CompIds = @(7); Origin = @(0.0,0.0,0.0) }
        [pscustomobject]@{ Path = $null; CompIds = @(8); Origin = @(1.0,0.0,0.0) }
    )
    $C.FastenerSurfId = 41; $C.FastenerHoleDia = 0.5; $C.FastenerHoleDiaValid = $true
}

# --- build the real $steps (exactly what the shell builds) ---
$steps = New-Object System.Collections.ArrayList
Add-CurvedInputFirstSteps -Steps $steps
$stepArr = @($steps.ToArray())
function Get-Step { param($Key) $stepArr | Where-Object { $_.Key -eq $Key } | Select-Object -First 1 }
Write-Host ("loaded {0} curved steps" -f $stepArr.Count)

# curved 7-stage breadcrumb rail (matches drilljig3d-gui.cmd $stages)
$STAGES = @('Welcome','Fasteners','Surface','Conditions','Build','Slots','Done')
$fH1  = New-Object System.Drawing.Font('Segoe UI',15,[System.Drawing.FontStyle]::Regular)
$fStep= New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
$fPill= New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
$fBtn = New-Object System.Drawing.Font('Segoe UI',10,[System.Drawing.FontStyle]::Bold)

# capture one page (ported from capture_shots.ps1; curved ctx/wiz + 7-stage rail)
function Capture-Page { param([string]$Key,[string]$Title,[string]$Stage,[scriptblock]$Setup,[string]$File,[int]$W=1240,[int]$H=820)
  $c = New-CurvedCtx
  if ($Setup) { & $Setup $c }
  $wiz = New-CurvedWiz
  $st = Get-Step $Key
  if ($null -eq $st) { Write-Host "  MISSING step $Key"; return $false }

  $frame = New-Object System.Windows.Forms.Panel
  $frame.Size = New-Object System.Drawing.Size($W,$H)
  $frame.BackColor = $formBack

  $ai = [array]::IndexOf($STAGES,$Stage)

  # card region (mirrors the wizard center card)
  $card = New-Object System.Windows.Forms.Panel
  $card.Location = New-Object System.Drawing.Point(16,76)
  $card.Size = New-Object System.Drawing.Size(($W-32),($H-76-70))
  $card.BackColor = $canvasBack
  $frame.Controls.Add($card)

  $lblNo = New-Object System.Windows.Forms.Label
  $lblNo.Location=New-Object System.Drawing.Point(28,18); $lblNo.AutoSize=$true; $lblNo.Font=$fStep; $lblNo.ForeColor=$mutedColor
  $idx=[array]::IndexOf(($stepArr|ForEach-Object{$_.Key}),$Key)
  $lblNo.Text=('Step {0} of {1}' -f ($idx+1),$stepArr.Count); $card.Controls.Add($lblNo)
  $lblT = New-Object System.Windows.Forms.Label
  $lblT.Location=New-Object System.Drawing.Point(26,38); $lblT.AutoSize=$true; $lblT.Font=$fH1; $lblT.ForeColor=$inkColor; $lblT.UseMnemonic=$false; $lblT.Text=$Title; $card.Controls.Add($lblT)

  $body = New-Object System.Windows.Forms.Panel
  $body.Location=New-Object System.Drawing.Point(14,84); $body.Size=New-Object System.Drawing.Size(($card.Width-28),($card.Height-96)); $body.BackColor=$canvasBack
  $card.Controls.Add($body)
  try { & $st.Build $body $c $wiz | Out-Null } catch { Write-Host ("  build fault {0}: {1}" -f $Key,$_.Exception.Message) }

  # bottom bar: Back + primary
  $bar = New-Object System.Windows.Forms.Panel
  $bar.Location=New-Object System.Drawing.Point(0,($H-64)); $bar.Size=New-Object System.Drawing.Size($W,64); $bar.BackColor=$formBack
  $frame.Controls.Add($bar)
  # primary is 220px wide (curved labels are long, e.g. "Open the first pocket sketch");
  # Back sits 12px to its left so the two never overlap.
  if ($ai -gt 0) {
    $bk=New-Object System.Windows.Forms.Button; $bk.Text=([char]0x2039)+' Back'; $bk.Size=New-Object System.Drawing.Size(120,36)
    $bk.Location=New-Object System.Drawing.Point(($W-16-220-12-120),14); $bk.FlatStyle='Flat'; $bk.FlatAppearance.BorderSize=1
    $bk.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(120,170,255); $bk.BackColor=[System.Drawing.Color]::FromArgb(54,72,112); $bk.ForeColor=[System.Drawing.Color]::White; $bk.Font=$fBtn
    $bar.Controls.Add($bk)
  }
  $nx=New-Object System.Windows.Forms.Button; $nx.Text=$(if($st.PrimaryText){$st.PrimaryText}else{'Next'}); $nx.Size=New-Object System.Drawing.Size(220,36)
  $nx.Location=New-Object System.Drawing.Point(($W-16-220),14); $nx.FlatStyle='Flat'; $nx.FlatAppearance.BorderSize=0; $nx.BackColor=$accentColor; $nx.ForeColor=[System.Drawing.Color]::White; $nx.Font=$fBtn
  $bar.Controls.Add($nx)

  # force layout, then render the whole frame to a bitmap
  $frame.PerformLayout()
  foreach($p in @($frame,$card,$body,$bar)){ try{$p.Refresh()}catch{} }
  $bmp = New-Object System.Drawing.Bitmap($W,$H)
  $frame.DrawToBitmap($bmp,(New-Object System.Drawing.Rectangle(0,0,$W,$H)))

  # draw the breadcrumb rail directly onto the bitmap (deterministic; no closure scope issues)
  try {
    $g=[System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode='AntiAlias'; $g.TextRenderingHint='ClearTypeGridFit'
    $n=$STAGES.Count; $slot=[double]$W/$n; $cy=30.0; $r=12.0
    $done=[System.Drawing.Color]::FromArgb(90,190,130)
    $lp=New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(70,84,112)),2
    $g.DrawLine($lp,[single]($slot*0.5),[single]$cy,[single]($slot*($n-0.5)),[single]$cy)
    for($i=0;$i -lt $n;$i++){
      $cx=$slot*($i+0.5); $rx=[single]($cx-$r); $ry=[single]($cy-$r); $d=[single]($r*2)
      if($i -lt $ai){
        $b=New-Object System.Drawing.SolidBrush($done); $g.FillEllipse($b,$rx,$ry,$d,$d); $b.Dispose()
        $cp=New-Object System.Drawing.Pen([System.Drawing.Color]::White),2
        $g.DrawLines($cp,@((New-Object System.Drawing.PointF([single]($cx-5),[single]$cy)),(New-Object System.Drawing.PointF([single]($cx-1),[single]($cy+4))),(New-Object System.Drawing.PointF([single]($cx+5),[single]($cy-5))))); $cp.Dispose()
      } elseif($i -eq $ai){
        $b=New-Object System.Drawing.SolidBrush($accentColor); $g.FillEllipse($b,$rx,$ry,$d,$d); $b.Dispose()
        $halo=New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(90,$accentColor.R,$accentColor.G,$accentColor.B)),3
        $g.DrawEllipse($halo,[single]($cx-$r-4),[single]($cy-$r-4),[single]($d+8),[single]($d+8)); $halo.Dispose()
      } else {
        $fb=New-Object System.Drawing.SolidBrush($formBack); $g.FillEllipse($fb,$rx,$ry,$d,$d); $fb.Dispose()
        $fp=New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(90,104,132)),2; $g.DrawEllipse($fp,$rx,$ry,$d,$d); $fp.Dispose()
      }
      $col=if($i -le $ai){$inkColor}else{[System.Drawing.Color]::FromArgb(130,144,168)}
      $lf=if($i -eq $ai){$fPill}else{New-Object System.Drawing.Font('Segoe UI',9)}
      $sf=New-Object System.Drawing.StringFormat; $sf.Alignment='Center'
      $tb=New-Object System.Drawing.SolidBrush($col)
      $g.DrawString($STAGES[$i],$lf,$tb,(New-Object System.Drawing.RectangleF([single]($cx-$slot/2),[single]($cy+$r+4),[single]$slot,18)),$sf)
      $tb.Dispose(); $sf.Dispose()
    }
    $lp.Dispose(); $g.Dispose()
  } catch { Write-Host ("  breadcrumb draw warn: "+$_.Exception.Message) }

  $bmp.Save($File,[System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose(); $frame.Dispose()
  Write-Host ("  saved {0}  ({1:N0} B)" -f (Split-Path $File -Leaf),(Get-Item $File).Length)
  return $true
}

# --- the page list (one representative capture per live curved wizard step) ---
# Order = Get-CurvedInputFirstOrder: welcome, fastener-select, surface-arm, tree,
# chip-clearance, fastener-dia, build-run, slot-arm, slot-finish, done.
$pages = @(
  @{ f='c01-welcome.png';         key='welcome';         title='Curved Drill Jig Builder';             stage='Welcome';    setup={param($c)} }
  @{ f='c02-fastener-select.png'; key='fastener-select'; title='Select the fasteners';                 stage='Fasteners';  setup={param($c) Set-Fasteners $c} }
  @{ f='c03-surface-arm.png';     key='surface-arm';     title='Pick the surface to follow';           stage='Surface';    setup={param($c) Set-Bushing $c; $c.SurfIds=@(41)} }
  @{ f='c04-tree.png';            key='tree';            title='Bushing & hole size';                  stage='Conditions'; setup={param($c) Set-Bushing $c} }
  @{ f='c05-chip-clearance.png';  key='chip-clearance';  title='Chip clearance';                       stage='Conditions'; setup={param($c) Set-Bushing $c; $c.ClearanceMode='standard'} }
  @{ f='c06-fastener-dia.png';    key='fastener-dia';    title='Fastener hole diameter';               stage='Conditions'; setup={param($c) Set-Bushing $c; $c.FastenerHoleDia=0.5; $c.FastenerHoleDiaValid=$true} }
  @{ f='c07-build-run.png';       key='build-run';       title='Build the jig (hands-free)';           stage='Build';      setup={param($c) Set-Inputs $c} }
  @{ f='c08-slot-arm.png';        key='slot-arm';        title='Chip-relief pockets: draw the first';  stage='Slots';      setup={param($c) Set-Drilled $c} }
  @{ f='c09-slot-finish.png';     key='slot-finish';     title='Chip-relief pockets: cut + next';      stage='Slots';      setup={param($c) Set-Drilled $c; $c.SlotArmed=$true; $c.SlotRunIndex=0} }
  @{ f='c10-done.png';            key='done';            title='Done';                                 stage='Done';       setup={param($c) Set-Drilled $c; $c.ReliefsCut=2} }
)

Write-Host "capturing curved pages..."
$saved = New-Object System.Collections.ArrayList
foreach ($p in $pages) {
  $out = Join-Path $shots $p.f
  $ok = Capture-Page -Key $p.key -Title $p.title -Stage $p.stage -Setup $p.setup -File $out
  if ($ok) { [void]$saved.Add($p.f) }
}
Write-Host ("DONE: {0}/{1} curved pages captured -> {2}" -f $saved.Count,$pages.Count,$shots)
