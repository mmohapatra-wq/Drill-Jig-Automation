<#
  probes\overview3d-repro.ps1 - reproduce the drilljig-gui "3D overview does not
  show up" report END TO END, exactly as a user hits it:
    1. extract the REAL drilljig-gui.zip from handbook/dist/index.html to %TEMP%
       (the same bytes the handbook download button hands out), OR use -FromRepo
       to test the live repo docs/ + UNPATCHED launcher path instead.
    2. dot-source the bundle's own webview2_host.ps1.
    3. create a WebView2, navigate the SAME WAY the (patched) launcher does
       (Set-WebView2LocalScene -> https://drilljig.local/ virtual host), push a
       real #embed payload, then probe the live DOM:
         - did three.js import succeed?  (window.__three_ok, set by a shim)
         - is the "could not load three.js" #loaderr banner visible?
         - how many meshes ended up in the scene?
  Prints a clear PASS/FAIL with the failure REASON. -STA is self-applied.

  Usage:
    powershell -File probes\overview3d-repro.ps1            # test the shipped zip
    powershell -File probes\overview3d-repro.ps1 -FromRepo  # test raw repo file:// path (expected to FAIL modules)
    powershell -File probes\overview3d-repro.ps1 -Keep      # leave the extracted bundle for inspection
#>
[CmdletBinding()]
param(
  [switch]$FromRepo,
  [switch]$Keep,
  [switch]$SimulateDownload,   # stamp Mark-of-the-Web on the extracted files (as Explorer does) BEFORE running
  [int]$TimeoutSec = 25
)
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Repo = Split-Path -Parent $ScriptDir

# --- self-relaunch STA (WebView2/WinForms needs a single-threaded apartment) ----
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
  $ps = (Get-Process -Id $PID).Path
  $argsList = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$MyInvocation.MyCommand.Path)
  if ($FromRepo) { $argsList += '-FromRepo' }
  if ($Keep)     { $argsList += '-Keep' }
  if ($SimulateDownload) { $argsList += '-SimulateDownload' }
  $argsList += @('-TimeoutSec',$TimeoutSec)
  & $ps @argsList
  exit $LASTEXITCODE
}

function Say($m,$c='Gray'){ Write-Host $m -ForegroundColor $c }
Say "== overview3d-repro (STA) ==" 'Cyan'

# ---------------------------------------------------------------- stage the bundle
$stage = Join-Path $env:TEMP ('overview3d_repro_' + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $stage | Out-Null
$docsFolder = $null
$launcherPatched = $null

if ($FromRepo) {
  # raw repo path: the UNPATCHED launcher navigates file://<repo>\docs\...#embed
  $docsFolder = Join-Path $Repo 'docs'
  Say "mode: FROM REPO (raw file:// path, unpatched launcher). docs=$docsFolder" 'Yellow'
  if (-not (Test-Path (Join-Path $docsFolder 'vendor\three\three.module.js'))) {
    Say "  NOTE: repo docs has NO vendored three.js -> modules cannot load even under a vhost." 'DarkYellow'
  }
} else {
  $dist = Join-Path $Repo 'handbook\dist\index.html'
  if (-not (Test-Path $dist)) { Say "handbook/dist/index.html not found - run handbook/build.ps1 first, or use -FromRepo." 'Red'; exit 3 }
  Say "extracting the shipped drilljig-gui.zip from $dist ..." 'Gray'
  $html = [System.IO.File]::ReadAllText($dist)
  $m = [regex]::Match($html, 'id="pl_gui_zip"[^>]*>([A-Za-z0-9+/=\s]+?)</script>')
  if (-not $m.Success) { Say "could not find pl_gui_zip payload in dist/index.html" 'Red'; exit 3 }
  $b64 = ($m.Groups[1].Value -replace '\s','')
  $zipPath = Join-Path $stage 'drilljig-gui.zip'
  [System.IO.File]::WriteAllBytes($zipPath, [Convert]::FromBase64String($b64))
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $stage)
  $bundleRoot = Join-Path $stage 'drilljig-gui'
  $docsFolder = Join-Path $bundleRoot 'docs'
  $launcher = Join-Path $bundleRoot 'drilljig-gui.cmd'
  $lc = [System.IO.File]::ReadAllText($launcher)
  $launcherPatched = ([regex]::Matches($lc,'Set-WebView2LocalScene -WebView')).Count
  Say ("extracted -> $bundleRoot   (launcher Set-WebView2LocalScene calls = {0})" -f $launcherPatched) 'Gray'

  if ($SimulateDownload) {
    # stamp Zone.Identifier=3 (Internet) on EVERY extracted file, exactly as a
    # browser download + Explorer extract does -> this is the real user scenario.
    Say "SIMULATING DOWNLOAD: stamping Mark-of-the-Web (ZoneId=3) on the extracted bundle..." 'Yellow'
    $stamped = 0
    Get-ChildItem $bundleRoot -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
      try { Set-Content -LiteralPath ($_.FullName + ':Zone.Identifier') -Value "[ZoneTransfer]`r`nZoneId=3`r`n" -Encoding Ascii -ErrorAction Stop; $stamped++ } catch {}
    }
    Say ("  stamped {0} files with MOTW." -f $stamped) 'DarkYellow'
    Say "  NOT unblocking in the harness - the SHIPPED Add-WebView2Assemblies must self-heal (Unblock-File + byte-load fallback)." 'DarkYellow'
  }

  # dot-source the BUNDLE'S webview2_host.ps1 (what the extracted tool actually runs)
  $hostPs = Join-Path $bundleRoot 'lib\webview2_host.ps1'
  . $hostPs
  # make the bundle's own webview2\ SDK discoverable (Resolve-WebView2Assets prefers <root>\webview2)
  Set-Variable -Name ScriptDir -Scope Global -Value ($bundleRoot + '\')
}

if ($FromRepo) { . (Join-Path $Repo 'lib\webview2_host.ps1'); Set-Variable -Name ScriptDir -Scope Global -Value ($Repo + '\') }

$previewHtml = Join-Path $docsFolder 'drilljig_3d_preview.html'
if (-not (Test-Path $previewHtml)) { Say "preview HTML missing at $previewHtml" 'Red'; exit 3 }

# ---------------------------------------------------------------- load WebView2
try { Add-WebView2Assemblies | Out-Null; Say "WebView2 SDK loaded." 'Green' }
catch { Say ("Add-WebView2Assemblies FAILED: {0}" -f $_.Exception.Message) 'Red'; exit 4 }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = 'overview3d-repro'; $form.Width = 900; $form.Height = 680
$wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
$props = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
$props.UserDataFolder = Join-Path $env:TEMP 'overview3d_repro_udf'
$wv.CreationProperties = $props
$wv.Dock = 'Fill'
$form.Controls.Add($wv)

# a real #embed payload (same shape drilljig-gui builds): a small valid orthogrid
$payload = '{"valid":true,"width":2.75,"height":2.25,"holeDia":0.25,"thickness":1.0,"slotDepth":0.25,"rowAxis":"X","slotFace":"side","points":[{"X":0.375,"Z":0.375},{"X":0.375,"Z":0.875},{"X":0.875,"Z":0.375},{"X":0.875,"Z":0.875}]}'

$script:navDone = $false
$script:probe = $null
$script:events = New-Object System.Collections.Generic.List[string]

$script:consoleMsgs = New-Object System.Collections.Generic.List[string]
$wv.add_CoreWebView2InitializationCompleted({
  param($s,$e)
  $script:events.Add("InitCompleted IsSuccess=$($e.IsSuccess)")
  if ($e.IsSuccess) {
    try {
      # capture console.error/warn + unhandled exceptions from the page
      $s.CoreWebView2.add_WebResourceResponseReceived({
        param($ss,$ee)
        try {
          $st = $ee.Response.StatusCode
          if ($st -ge 400) { $script:consoleMsgs.Add("HTTP $st  $($ee.Request.Uri)") }
        } catch {}
      })
    } catch {}
  }
}.GetNewClosure())

$wv.add_NavigationStarting({
  param($s,$e)
  $script:events.Add("NavStarting uri=$($e.Uri)")
}.GetNewClosure())

$wv.add_NavigationCompleted({
  param($s,$e)
  $script:events.Add("NavCompleted IsSuccess=$($e.IsSuccess) status=$($e.WebErrorStatus)")
  try { $null = $s.ExecuteScriptAsync("setJigGeometry(" + $payload + ")") } catch {}
}.GetNewClosure())

# drive navigation EXACTLY like the patched launcher
$form.add_Shown({
  # Set-WebView2LocalScene sets up the vhost + navigates (or falls back to file://)
  try {
    Set-WebView2LocalScene -WebView $wv -DocsFolder $docsFolder -HtmlFile 'drilljig_3d_preview.html' -Hash '#embed'
    $script:events.Add("Set-WebView2LocalScene invoked")
  } catch { $script:events.Add("Set-WebView2LocalScene THREW: $($_.Exception.Message)") }
})

# Show the form non-modally, then drive a manual DoEvents pump so we stay on the UI
# thread while polling the DOM. Poll until a TERMINAL state (three loaded OR the error
# banner shows), capturing the RAW ExecuteScriptAsync result each cycle.
$form.Show()
$form.Activate()

# install error hooks + a one-shot direct import probe as soon as we can
$hookJs = @'
(function(){
  if (window.__hooked) return "already";
  window.__hooked = true;
  window.__errs = [];
  window.addEventListener('error', function(ev){
    window.__errs.push('error: ' + (ev.message||'') + ' @ ' + (ev.filename||'') + ':' + (ev.lineno||''));
  });
  window.addEventListener('unhandledrejection', function(ev){
    window.__errs.push('reject: ' + (ev.reason && ev.reason.message ? ev.reason.message : String(ev.reason)));
  });
  // directly attempt the SAME import the page's boot() does, and record the outcome
  window.__importState = 'pending';
  import('./vendor/three/three.module.js')
    .then(function(m){ window.__importState = 'ok:' + (m && m.REVISION ? m.REVISION : 'noRev'); })
    .catch(function(e){ window.__importState = 'fail:' + (e && e.message ? e.message : String(e)); });
  return "hooked";
})()
'@

$js = @'
(function(){
  try {
    var le = document.getElementById('loaderr');
    var vis = le ? (getComputedStyle(le).display !== 'none') : false;
    var cv = document.getElementById('cv');
    // GROUND TRUTH that the 3D actually RENDERED: read the WebGL canvas back and
    // count non-background pixels. THREE is module-scoped (not global) so we cannot
    // see it directly; the canvas is the real evidence the scene drew.
    var canvasPainted = false, wh = '', nonBg = 0, sampled = 0;
    if (cv) {
      wh = cv.width + 'x' + cv.height;
      try {
        var gl = cv.getContext('webgl2') || cv.getContext('webgl');
        if (gl) {
          var w = cv.width, h = cv.height;
          var px = new Uint8Array(w*h*4);
          gl.readPixels(0,0,w,h,gl.RGBA,gl.UNSIGNED_BYTE,px);
          // background is 0x1E2A44 (30,42,68). Count pixels that differ from it.
          for (var i=0;i<px.length;i+=4){
            sampled++;
            var dr=Math.abs(px[i]-30), dg=Math.abs(px[i+1]-42), db=Math.abs(px[i+2]-68);
            if (dr+dg+db > 24) nonBg++;
          }
          canvasPainted = (nonBg > 50);
        }
      } catch(er){ wh += ' readPixels:'+er; }
    }
    return JSON.stringify({
      canvasPainted: canvasPainted,
      nonBgPixels: nonBg,
      canvasWH: wh,
      importState: window.__importState || 'n/a',
      errs: (window.__errs||[]).slice(0,6),
      loaderrVisible: vis,
      loaderrText: le? le.textContent.trim().slice(0,140): '',
      origin: location.origin,
      selftest: (document.getElementById('selftest')||{}).textContent||''
    });
  } catch(e){ return JSON.stringify({error:String(e)}); }
})()
'@

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$script:hookInstalled = $false
$script:rawProbe = $null
while ((Get-Date) -lt $deadline) {
  [System.Windows.Forms.Application]::DoEvents()
  Start-Sleep -Milliseconds 250
  if ($null -eq $wv.CoreWebView2) { continue }
  # install the error hooks + direct-import probe once
  if (-not $script:hookInstalled) {
    try {
      $ht = $wv.ExecuteScriptAsync($hookJs)
      $hdl = (Get-Date).AddSeconds(3)
      while (-not $ht.IsCompleted -and (Get-Date) -lt $hdl) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
      if ($ht.IsCompleted) { $script:hookInstalled = $true; $script:events.Add("hook: " + ($ht.Result)) }
    } catch {}
  }
  $task = $null
  try { $task = $wv.ExecuteScriptAsync($js) } catch { continue }
  # pump while the async JS runs
  $tdl = (Get-Date).AddSeconds(3)
  while (-not $task.IsCompleted -and (Get-Date) -lt $tdl) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
  if (-not $task.IsCompleted) { continue }
  $r = $null; try { $r = $task.Result } catch {}
  if ($r -and $r.Trim('"').Length -gt 2 -and $r -ne 'null') {
    $script:rawProbe = $r
    $dec = $null
    try { $d1 = $r | ConvertFrom-Json; $dec = if ($d1 -is [string]) { $d1 | ConvertFrom-Json } else { $d1 } } catch {}
    # terminal: canvas actually painted, OR the error banner shows, OR import failed
    if ($dec -and ($dec.canvasPainted -eq $true -or $dec.loaderrVisible -eq $true -or ("$($dec.importState)" -match '^fail:'))) { $script:probe = $r; break }
  }
}
if (-not $script:probe) { $script:probe = if ($script:rawProbe) { $script:rawProbe } else { '{"error":"no non-empty probe before timeout"}' } }
Say ("RAW probe result: {0}" -f $script:probe) 'DarkGray'
try { $form.Close() } catch {}

# ---------------------------------------------------------------- verdict
Say ""
Say "-- WebView2 event log --" 'Cyan'
foreach ($ev in $script:events) { Say ("   " + $ev) 'DarkGray' }
if ($script:consoleMsgs.Count -gt 0) {
  Say "-- HTTP >=400 (failed sub-resource fetches) --" 'Yellow'
  foreach ($cm in $script:consoleMsgs) { Say ("   " + $cm) 'Yellow' }
}
Say ""
if (-not $script:probe) { Say "NO PROBE RESULT (navigation/JS never returned within ${TimeoutSec}s)." 'Red'; if (-not $Keep){ try{Remove-Item $stage -Recurse -Force}catch{} }; exit 5 }
# ExecuteScriptAsync returns a JSON-encoded STRING LITERAL (the whole result is
# quoted + inner quotes escaped). Decode TWICE: outer literal -> inner JSON string,
# then inner string -> object. Do NOT .Trim('"') (that leaves \" escapes and breaks
# the parse - the bug the loop decoder already avoids).
$decoded = $null
try {
  $d1 = $script:probe | ConvertFrom-Json
  $decoded = if ($d1 -is [string]) { $d1 | ConvertFrom-Json } else { $d1 }
} catch { $decoded = $null }
Say ("probe: {0}" -f ($decoded | ConvertTo-Json -Compress)) 'White'

$ok = $false
if ($decoded -and -not $decoded.error) {
  $ok = ($decoded.canvasPainted -eq $true -and $decoded.loaderrVisible -ne $true)
}
Say ""
if ($ok) {
  Say ("PASS - 3D RENDERS. WebGL canvas painted {0} non-background pixels ({1}) under origin {2}; three.js import={3}." -f $decoded.nonBgPixels, $decoded.canvasWH, $decoded.origin, $decoded.importState) 'Green'
} else {
  Say "FAIL - 3D did NOT render." 'Red'
  if ($decoded.origin -and $decoded.origin -notmatch 'drilljig\.local') {
    Say ("  ROOT CAUSE: page origin is '{0}', NOT the https vhost -> Set-WebView2LocalScene fell back to file:// and Chromium blocked the ES-module import." -f $decoded.origin) 'Yellow'
  } elseif ("$($decoded.importState)" -match '^fail:') {
    Say ("  ROOT CAUSE: three.js module import FAILED: {0}" -f $decoded.importState) 'Yellow'
  } elseif ($decoded.loaderrVisible) {
    Say ("  loader-error banner is showing: {0}" -f $decoded.loaderrText) 'Yellow'
  } elseif ($decoded.canvasPainted -ne $true) {
    Say ("  canvas present ({0}) but blank (nonBg={1}); import={2}, errs={3}. Scene built but nothing drew." -f $decoded.canvasWH, $decoded.nonBgPixels, $decoded.importState, ($decoded.errs -join ' | ')) 'Yellow'
  } elseif ($decoded.error) {
    Say ("  JS probe error: {0}" -f $decoded.error) 'Yellow'
  }
}
if ($launcherPatched -ne $null -and $launcherPatched -lt 2) {
  Say ("  WARNING: shipped launcher had only {0}/2 Set-WebView2LocalScene calls (patch incomplete)." -f $launcherPatched) 'Yellow'
}
if (-not $Keep) { try { Remove-Item $stage -Recurse -Force } catch {} } else { Say "kept: $stage" 'Gray' }
exit ($(if ($ok) { 0 } else { 1 }))
