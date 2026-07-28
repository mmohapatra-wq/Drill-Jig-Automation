<#  Headless screenshot capture of the drilljig-gui wizard PAGES.
    Renders each real wizard step's Build into an off-screen panel dressed in the
    live dark theme (breadcrumb + title + body + Back/primary bar) and DrawToBitmap
    -> PNG. No window is shown, no message loop, no Creo. Adapted from the proven
    lib\tests\fuzz_gui.ps1 headless harness.  #>

$ErrorActionPreference = 'Stop'
$root   = Split-Path $PSScriptRoot -Parent   # repo root (handbook/..)
$libDir = Join-Path $root 'lib'
$shots  = Join-Path $PSScriptRoot 'shots'
if (-not (Test-Path $shots)) { New-Item -ItemType Directory -Force -Path $shots | Out-Null }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- dot-source the real libs (same set the GUI loads) ---
. (Join-Path $libDir 'creo_geometry.ps1')
. (Join-Path $libDir 'blind_evaluator.ps1')
. (Join-Path $libDir 'orthogrid.ps1')
. (Join-Path $libDir 'orthogrid_gui.ps1')
. (Join-Path $libDir 'orthogrid_points.ps1')
. (Join-Path $libDir 'fastener_layout.ps1')
. (Join-Path $libDir 'drilljig_core.ps1')
. (Join-Path $libDir 'bushing_svg.ps1')
. (Join-Path $libDir 'wizard.ps1')

# --- stub the live-Creo helpers so Builds run without Creo (from fuzz_gui.ps1) ---
function Initialize-DrilljigCore { param($Session,$Model,$TypeObj,$DataDir,$Log) }
function Find-DefaultDatumPicks { @([pscustomobject]@{Id=101;Name='TOP';Role='Top'},[pscustomobject]@{Id=102;Name='SIDE';Role='Side'},[pscustomobject]@{Id=103;Name='FRONT';Role='Front'}) }
function Read-SelectionPlanePicks { @([pscustomobject]@{Id=101;Name='TOP';Role='Top'},[pscustomobject]@{Id=102;Name='SIDE';Role='Side'},[pscustomobject]@{Id=103;Name='FRONT';Role='Front'}) }
function Resolve-SelectedPointIds { @{ Ids=@(201,202,203); Rejected=@() } }
function Find-DefaultCsysId { 501 }
function Invoke-BaseCsys { param($RefCsysId) @{ Ok=$true; CsysFeatId=777; Reason='' } }
function Invoke-OutputCsys { param($RefCsysId,$GridX,$GridZ,$GridY) @{ Ok=$true; CsysFeatId=778; AnchorPlaneIds=@(311,312,313); Reason='' } }
function New-OffsetPlane { param($Label,$Offset,$BaseId,[switch]$SkipSymbolWait) @{ Symbol=('d'+$BaseId); FeatId=(400+[int]$BaseId) } }
function New-CsysOffsetPlane { param($CsysFeatId,$Axis,$Offset,[switch]$SkipSymbolWait) @{ Symbol=('c'+$Axis); FeatId=(600+[int]$Axis[0]) } }
function Invoke-Macro { param($Desc,$Macro) }
function Wait-ModelModified { param($Model,$PreviousStamp,$OnPoll) if ($null -ne $OnPoll){try{& $OnPoll}catch{}}; return $true }
function Get-PointIdSet { param($Model,$TypeObj) @{} }
function Resolve-NewPointIds { param($Model,$TypeObj,$Before) @(201..220) }
function Get-FeatureIdSet { @{} }
function Resolve-HoleFeatGroups { param($NewFeatIds,$HoleCount) @{ Ok=$true; PerHole=1; Groups=@(1..$HoleCount | ForEach-Object { @($_) }) } }
function Invoke-AutoCornerRound { param($Session,$Model,$TypeObj,$Radius) @{ Found=8; Matched=4; TotalBatches=1; ModelChanged=1 } }
function Read-SelectedId { 999 }
function Get-BodyList { @(0) }
function New-SlotGuidePlanes { param($Rows,$TopBaseId,$FrontBaseId,[switch]$UsePattern,$Log) @{ Ids=@(701,702) } }

$fakeModel = [pscustomobject]@{ VersionStamp = 1 }
$fakeModel | Add-Member ScriptMethod Regenerate { param($x) } -Force
$fakeSession = [pscustomobject]@{}
$fakeSession | Add-Member ScriptMethod RunMacro { param($m) } -Force
$fakeSession | Add-Member ScriptMethod GetActiveModel { $script:model } -Force
$fakeSession | Add-Member ScriptMethod GetConfigOptionValues { param($k) $null } -Force
$fakeSession | Add-Member ScriptMethod SetConfigOption { param($k,$v) } -Force

# --- extract the GUI helper region + steps region from the .cmd ---
$src = Get-Content -Raw (Join-Path $root 'pipeline\drilljig-gui.cmd')
$h0 = $src.IndexOf('# STEP BUILDERS'); $h1 = $src.IndexOf('# Build the connection up front')
Invoke-Expression $src.Substring($h0, $h1 - $h0) | Out-Null

$ScriptDir = $root; $ScriptArgs = ''; $dataDir = Join-Path $PSScriptRoot 'data'   # committed catalogs (repo copies are gitignored)
$script:DJDataDir = $dataDir   # the catalog helpers (Get-CatalogSpec/Get-CatalogRows) read this; normally set by Initialize-DrilljigCore
$cornerRadius = 0.25; $noCornerRound = $false
$SLOT_DEPTH_ABS = 0.25; $slotDepthFromFlagG = $false; $slotFlipDefault = $false
$slotPatternFlip = $false; $slotNoPattern = $false; $noSlotRelief = $false
$noBaseCsys = $false; $indexFlipX = 1.0; $indexFlipZ = 1.0
$model = $fakeModel; $session = $fakeSession; $pfcType = $null; $modelFile = 'bracket_jig.prt'
$script:model = $fakeModel; $script:session = $fakeSession; $script:connection = $null
$script:macroFailures = 0

# --- theme (mirror Show-Wizard so Get-UiColor + cards render dark-on-blue) ---
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

# --- fresh ctx (mirror the .cmd initializer, from fuzz_gui.ps1) ---
function New-Ctx {
  $c = @{
    TreePath = Join-Path $root 'docs\drill_jig_decision_tree.json'
    Path=[System.Collections.ArrayList]::new(); Picks=[System.Collections.ArrayList]::new()
    HoleDia=$null; BushingLen=$null; Is3dPrint=$false
    TreeNode=$null; TreeDone=$false; PendingSpec=$null; BushStage=$null; Grouped=$null; BushID=$null
    BushOdFirst=$false; BushOdGroups=$null; BushOD=$null; BushOdOptions=$null
    BushLenValue=$null; BushLenLabel=$null; BushLenIsCustom=$false; BushLenCustomText=''; BushLenValid=$true
    PointMode='predefined'; OrthoGeo=$null; LayoutPicked=$false; LayoutMode=$null
    FastenerLayoutPath=$null; OrthoValid=$false; OrthoFields=$null; CustomRows=$null; CustomIndex=$null
    IndexFirst=$false; IndexKey=$null
    Session=$fakeSession; Model=$fakeModel; Type=$null; ModelName='bracket_jig.prt'; Connected=$true
    BaseCsysId=$null; RefCsysId=$null; IndexAnchorX=$null; IndexAnchorZ=$null; UseCsys=$null; FaceId=$null
    Planes=$null; AutoMapped=$false; SidePlane=$null; Made=@(); BoxArmed=$false
    SketchPlaneId=$null; ExtrudeToId=$null; BoxBuilt=$false
    GridPointIDs=@(); GridPlaneIds=@(); CsysRecords=@()
    PointIDs=@(); BodyIndex=0; HoleDiaFinal=0.0; Drilled=$false
    IndexGridX=$null; IndexGridZ=$null
    SlotArmed=$false; SlotSkip=$false; SlotFlip=$false; SlotPlan=$null; SlotsDone=$false
    SlotRunIndex=0; SeedCut=$false; SlotAnyCut=$false; SlotWarn=$false
    WillSlot=$null; ReliefPad=0.0
    SlotDepth=[double]0.25; SlotSpaceMode=$null; SlotDepthFromFlag=$false; SlotDepthValid=$true
    SlotRowAxis=$null; SlotDirFromFlag=$false; SlotFaceMode=$null; SlotFaceFromFlag=$false
    EdgeMargin=$null; EdgeMarginMode=$null; EdgeMarginValid=$true
    FastenerRawPoints=$null; FastenerAsked=$false
  }
  $treeRoot = Get-Content $c.TreePath -Raw | ConvertFrom-Json
  $c.TreeNode=@($treeRoot)[0]; $c.TreeRoot=@($treeRoot)[0]; $c.TreeHistory=[System.Collections.ArrayList]::new()
  return $c
}
function New-Wiz {
  $w = [pscustomobject]@{ Answer='Yes' }
  foreach ($m in 'SetChip','Refresh','Log','Pump','SetProgress','BeginRun','EndRun','MarkCommitted','SetStatus','LogError','Next','Rerender','GoToStepKey') { $w | Add-Member ScriptMethod $m { param($a,$b,$c) } -Force }
  $w | Add-Member ScriptMethod AskInline { param($h,$t,$btns='OK',$noact=$false) return $this.Answer } -Force
  return $w
}
function Set-OrthoLayout { param($C,[double]$Dia=0.5)
  $C.HoleDia=$Dia; $C.BushingLen=0.75; $C.PointMode='orthogrid'; $C.LayoutMode='orthogrid'
  $C.OrthoFields=@{ CcX=0.75; CcZ=0.75; Nx=4; Nz=3; Edge=$Dia }
  $C.OrthoGeo=Get-OrthogridGeometry -CcX 0.75 -CcZ 0.75 -Nx 4 -Nz 3 -Edge $Dia -ClearDia $Dia -HoleDia $Dia -EdgeMargin $Dia
  $C.OrthoValid=[bool]$C.OrthoGeo.Valid
}
function Set-Datums { param($C)
  $C.Planes=@(
    [pscustomobject]@{Label='Top';Hint='TOP';Offset=3.0;Sym='d1';BaseId=101;FeatId=411}
    [pscustomobject]@{Label='Side';Hint='SIDE';Offset=0.75;Sym='d2';BaseId=102;FeatId=412}
    [pscustomobject]@{Label='Front';Hint='FRONT';Offset=2.0;Sym='d3';BaseId=103;FeatId=413}
  )
  $C.Made=@($C.Planes); $C.SidePlane=$C.Planes|Where-Object{$_.Label -eq 'Side'}|Select-Object -First 1; $C.AutoMapped=$true
}

# --- build the real $steps ---
$steps = New-Object System.Collections.ArrayList
$ctx = New-Ctx
$siR = $src.IndexOf('# WIZARD STEPS'); $eiR = $src.IndexOf('# RUN THE WIZARD')
Invoke-Expression $src.Substring($siR, $eiR - $siR) | Out-Null
$stepArr = @($steps.ToArray())
function Get-Step { param($Key) $stepArr | Where-Object { $_.Key -eq $Key } | Select-Object -First 1 }
Write-Host ("loaded {0} steps" -f $stepArr.Count)

$STAGES = @('Welcome','Import','Bushing','Layout','Overview','Datums','Box','Drill','Relief','Done')
$fH1  = New-Object System.Drawing.Font('Segoe UI',15,[System.Drawing.FontStyle]::Regular)
$fStep= New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
$fPill= New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
$fBtn = New-Object System.Drawing.Font('Segoe UI',10,[System.Drawing.FontStyle]::Bold)

# breadcrumb strip painter (compact reimpl of the wizard rail)
function Add-Breadcrumb { param($Parent,[int]$ActiveIdx,[int]$W)
  $rail = New-Object System.Windows.Forms.Panel
  $rail.Location = New-Object System.Drawing.Point(0,0)
  $rail.Size = New-Object System.Drawing.Size($W,72)
  $rail.BackColor = $formBack
  $rail.Add_Paint({ param($s,$e)
    try {
      $g=$e.Graphics; $g.SmoothingMode='AntiAlias'; $g.TextRenderingHint='ClearTypeGridFit'
      $n=$STAGES.Count; $cw=$s.ClientSize.Width; $slot=[double]$cw/$n; $cy=28.0; $r=12.0
      $done=[System.Drawing.Color]::FromArgb(90,190,130)
      $lp=New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(70,84,112),2)
      $g.DrawLine($lp,[single]($slot*0.5),[single]$cy,[single]($slot*($n-0.5)),[single]$cy)
      for($i=0;$i -lt $n;$i++){
        $cx=$slot*($i+0.5); $rx=[single]($cx-$r); $ry=[single]($cy-$r); $d=[single]($r*2)
        if($i -lt $ActiveIdx){ $b=New-Object System.Drawing.SolidBrush($done); $g.FillEllipse($b,$rx,$ry,$d,$d); $b.Dispose()
          $cp=New-Object System.Drawing.Pen([System.Drawing.Color]::White,2)
          $g.DrawLines($cp,@((New-Object System.Drawing.PointF([single]($cx-5),[single]$cy)),(New-Object System.Drawing.PointF([single]($cx-1),[single]($cy+4))),(New-Object System.Drawing.PointF([single]($cx+5),[single]($cy-5))))); $cp.Dispose()
        } elseif($i -eq $ActiveIdx){ $b=New-Object System.Drawing.SolidBrush($accentColor); $g.FillEllipse($b,$rx,$ry,$d,$d); $b.Dispose()
          $halo=New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(90,$accentColor.R,$accentColor.G,$accentColor.B),3); $g.DrawEllipse($halo,[single]($cx-$r-4),[single]($cy-$r-4),[single]($d+8),[single]($d+8)); $halo.Dispose()
        } else { $fb=New-Object System.Drawing.SolidBrush($formBack); $g.FillEllipse($fb,$rx,$ry,$d,$d); $fb.Dispose()
          $fp=New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(90,104,132),2); $g.DrawEllipse($fp,$rx,$ry,$d,$d); $fp.Dispose() }
        $col=if($i -eq $ActiveIdx){$inkColor}elseif($i -lt $ActiveIdx){$inkColor}else{[System.Drawing.Color]::FromArgb(130,144,168)}
        $lf=if($i -eq $ActiveIdx){$fPill}else{New-Object System.Drawing.Font('Segoe UI',9)}
        $sf=New-Object System.Drawing.StringFormat; $sf.Alignment='Center'
        $tb=New-Object System.Drawing.SolidBrush($col)
        $g.DrawString($STAGES[$i],$lf,$tb,(New-Object System.Drawing.RectangleF([single]($cx-$slot/2),[single]($cy+$r+4),[single]$slot,18)),$sf)
        $tb.Dispose(); $sf.Dispose()
      }
      $lp.Dispose()
    } catch {}
  }.GetNewClosure())
  $Parent.Controls.Add($rail)
  return $rail
}

# capture one page
function Capture-Page { param([string]$Key,[string]$Title,[string]$Stage,[scriptblock]$Setup,[string]$File,[int]$W=1240,[int]$H=820)
  $c = New-Ctx
  if ($Setup) { & $Setup $c }
  $wiz = New-Wiz
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
  if ($ai -gt 0) {
    $bk=New-Object System.Windows.Forms.Button; $bk.Text=([char]0x2039)+' Back'; $bk.Size=New-Object System.Drawing.Size(120,36)
    $bk.Location=New-Object System.Drawing.Point(($W-16-160-132),14); $bk.FlatStyle='Flat'; $bk.FlatAppearance.BorderSize=1
    $bk.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(120,170,255); $bk.BackColor=[System.Drawing.Color]::FromArgb(54,72,112); $bk.ForeColor=[System.Drawing.Color]::White; $bk.Font=$fBtn
    $bar.Controls.Add($bk)
  }
  $nx=New-Object System.Windows.Forms.Button; $nx.Text=$(if($st.PrimaryText){$st.PrimaryText}else{'Next'}); $nx.Size=New-Object System.Drawing.Size(160,36)
  $nx.Location=New-Object System.Drawing.Point(($W-16-160),14); $nx.FlatStyle='Flat'; $nx.FlatAppearance.BorderSize=0; $nx.BackColor=$accentColor; $nx.ForeColor=[System.Drawing.Color]::White; $nx.Font=$fBtn
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

# --- the page list (one representative capture per wizard screen) ---
$pages = @(
  @{ f='01-welcome.png';     key='welcome';      title='Welcome to the Drill Jig Builder'; stage='Welcome'; setup={param($c)} }
  @{ f='02-import.png';      key='import';        title='Import fastener layout (optional)'; stage='Import'; setup={param($c)} }
  @{ f='03-bushing-cards.png'; key='tree';        title='Bushing & hole size'; stage='Bushing'; setup={param($c)} }
  @{ f='04-bushing-confirm.png'; key='tree';      title='Bushing & hole size'; stage='Bushing'; setup={param($c) $c.TreeDone=$true; [void]$c.Picks.Add([pscustomobject]@{HoleDiameter=0.5;BushingID=0.25;BushingLength=0.25;Bushing='Drill Bushing | OD 1/2 x ID 1/4 x 1/4 Lg';PartNumber='8493A072';Outcome='x'}) } }
  @{ f='03b-bushing-drillmethod.png'; key='tree'; title='Bushing & hole size'; stage='Bushing'; setup={param($c) $m=@($c.TreeRoot.children)[0]; $c.TreeNode=@($m.children)[0]; [void]$c.Path.Add('Metal') } }
  @{ f='03c-bushing-od-cards.png';    key='tree'; title='Bushing & hole size'; stage='Bushing'; setup={param($c) $sp=Get-CatalogSpec -Label 'Show catalog of all 3/4 OD and 1/2 OD removable bushings for user to select'; $c.PendingSpec=$sp; $c.BushOdFirst=$true; $c.BushStage='od1' } }
  @{ f='03d-bushing-length.png';      key='tree'; title='Bushing & hole size'; stage='Bushing'; setup={param($c) $sp=Get-CatalogSpec -Label 'Show catalog of all 3/4 OD and 1/2 OD removable bushings for user to select'; $c.PendingSpec=$sp; $c.BushOdFirst=$true; $c.BushOD=[pscustomobject]@{OD=0.75; ODLabel='3/4'}; $c.BushStage='len'; $c.BushLenIsCustom=$false } }
  @{ f='03e-bushing-id-cards.png';    key='tree'; title='Bushing & hole size'; stage='Bushing'; setup={param($c) $sp=Get-CatalogSpec -Label 'Show catalog of all 3/4 ID and 1/2 ID sleeves for user to select'; $c.PendingSpec=$sp; $c.BushOdFirst=$false; $c.BushStage='id' } }
  @{ f='05-edge-margin.png'; key='edge-margin';   title='Hole-to-edge margin'; stage='Bushing'; setup={param($c) $c.HoleDia=0.5} }
  @{ f='06-slot-depth.png';  key='slot-depth';    title='Chip-relief slot depth'; stage='Bushing'; setup={param($c) $c.BushingLen=0.75} }
  @{ f='07-layout-tiles.png'; key='layout';       title='How are the hole points defined?'; stage='Layout'; setup={param($c) $c.HoleDia=0.5} }
  @{ f='08-layout-orthogrid.png'; key='layout';   title='How are the hole points defined?'; stage='Layout'; setup={param($c) $c.HoleDia=0.5;$c.BushingLen=0.75;$c.PointMode='orthogrid';$c.LayoutMode='orthogrid'} }
  @{ f='09-index-hole.png';  key='index-choice';  title='Index hole'; stage='Layout'; setup={param($c) Set-OrthoLayout $c} }
  @{ f='10-overview.png';    key='overview';      title='3D overview (rough)'; stage='Overview'; setup={param($c) Set-OrthoLayout $c; $c.HoleDiaFinal=0.5; $c.BushingLen=0.75; $c.SlotDepth=0.25; $c.SlotFaceMode='side'} }
  @{ f='11-datums.png';      key='datums';        title='Base datum planes'; stage='Datums'; setup={param($c) Set-OrthoLayout $c} }
  @{ f='12-box-a.png';       key='box-a';         title='Build the parametric box'; stage='Box'; setup={param($c) Set-OrthoLayout $c; Set-Datums $c} }
  @{ f='13-box-b.png';       key='box-b';         title='Finish the box'; stage='Box'; setup={param($c) Set-OrthoLayout $c; Set-Datums $c; $c.BoxArmed=$true; $c.SketchPlaneId=102; $c.ExtrudeToId=412} }
  @{ f='14-pickpoints.png';  key='pickpoints';    title='Target datum points'; stage='Drill'; setup={param($c) $c.PointMode='predefined'} }
  @{ f='15-drill.png';       key='drill';         title='Create points, round corners, and drill'; stage='Drill'; setup={param($c) Set-OrthoLayout $c; Set-Datums $c; $c.UseCsys=$false; $c.PointIDs=@()} }
  @{ f='16-slot-a.png';      key='slot-a';        title='Chip-relief slots: draw the seed'; stage='Relief'; setup={param($c) Set-OrthoLayout $c; Set-Datums $c; $c.HoleDiaFinal=0.5; $c.ReliefPad=0.25; $c.WillSlot=$true} }
  @{ f='17-slot-b.png';      key='slot-b';        title='Chip-relief slots: cut + pattern'; stage='Relief'; setup={param($c) Set-OrthoLayout $c; Set-Datums $c; $c.SlotArmed=$true; $c.SlotPlan=@{Mode='pattern';SeedRow=[pscustomobject]@{CrossCoord=0.5;SlotLen=10.0;Corner0=@{X=0;Z=0.5};Corner1=@{X=10;Z=0.5}};Patterns=@([pscustomobject]@{Increment=0.75;Count=3;Offsets=@(0.75,1.5)});SlotWidth=0.5;RowAxis='X';CrossAxis='Z';Depth=0.25;FaceId=102;DirDatumId=413;DirName='FRONT'}} }
  @{ f='18-done.png';        key='done';          title='Done'; stage='Done'; setup={param($c) Set-OrthoLayout $c; $c.BoxBuilt=$true; $c.Drilled=$true; $c.SlotsDone=$true; $c.PointIDs=@(1,2,3)} }
)

Write-Host "capturing pages..."
$saved = New-Object System.Collections.ArrayList
foreach ($p in $pages) {
  $out = Join-Path $shots $p.f
  $ok = Capture-Page -Key $p.key -Title $p.title -Stage $p.stage -Setup $p.setup -File $out
  if ($ok) { [void]$saved.Add($p.f) }
}
Write-Host ("DONE: {0}/{1} pages captured -> {2}" -f $saved.Count,$pages.Count,$shots)