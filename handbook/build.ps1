<#
  handbook/build.ps1 -- regenerate the Drill-Jig handbook (single self-contained index.html)
  from the CURRENT repo. Runs on Windows PowerShell 5.1 OR pwsh (Linux CI).

  What it does (all from the live repo, so code changes flow through):
    1. Rebuilds the offline drilljig-gui.zip  (repo launcher + libs + data + docs,
       re-applying the launcher's 2 offline patches; webview2_host + preview HTML come
       from handbook/overlay; three.js + WebView2 SDK from handbook/vendor).
    2. Rebuilds the ngs-orthogrid-toolkit.zip  (repo code/docs, secrets scrubbed).
    3. Assembles handbook/shell.html + parts/*.html, and embeds (base64): both zips,
       docs/DEVELOPMENT_SETUP.html, every other .cmd, and the committed screenshots.
    4. Writes -Out (default handbook/dist/index.html) and runs sanity checks.

  Screenshots are committed under handbook/shots (WinForms render needs Windows).
  Pass -Shots on a Windows machine to re-capture them first (calls capture_shots.ps1).

  Usage:
    pwsh -File handbook/build.ps1 -Out public/index.html -Sha $CI_COMMIT_SHORT_SHA
    powershell -File handbook\build.ps1 -Shots        # local, Windows, refresh screenshots too
#>
param(
  [string]$Out = "$PSScriptRoot/dist/index.html",
  [string]$Sha = 'local',
  [switch]$Shots,
  [switch]$Publish,
  [string]$PublishRepo = 'https://gitlab.blueorigin.com/mmohapatra/drilljig-handbook.git'
)
$ErrorActionPreference = 'Stop'
$HB   = $PSScriptRoot
$REPO = Split-Path $HB -Parent
$enc  = New-Object System.Text.UTF8Encoding($false)
function RT([string]$p){ [System.IO.File]::ReadAllText($p) }
function WT([string]$p,[string]$s){ $d=Split-Path $p -Parent; if($d -and -not (Test-Path $d)){ New-Item -ItemType Directory -Force -Path $d | Out-Null }; [System.IO.File]::WriteAllText($p,$s,$enc) }
function Need([string]$h,[string]$needle,[string]$what){ if($h.IndexOf($needle) -lt 0){ throw "PATCH ANCHOR MISSING ($what) -- the repo file changed shape; update handbook/build.ps1." } }
function B64([string]$p){ [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($p)) }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("hbbuild_" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
Write-Host "handbook build -- repo=$REPO  sha=$Sha"

# optional screenshot refresh (Windows only)
if ($Shots) {
  $onWin = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
  if (-not $onWin) { throw "-Shots needs Windows (WinForms DrawToBitmap). Run it on a Windows machine." }
  Write-Host "capturing screenshots..."
  & (Join-Path $HB 'capture_shots.ps1')
}

# ---------------------------------------------------------------- 1. offline drilljig-gui.zip
$stage = Join-Path $tmp 'drilljig-gui'
New-Item -ItemType Directory -Force -Path "$stage/lib","$stage/data","$stage/docs/vendor/three/addons/controls" | Out-Null

# launcher: live repo cmd + the 2 offline patches (flat ScriptDir + Set-WebView2LocalScene nav)
$cmd  = RT "$REPO/pipeline/drilljig-gui.cmd"
$old4 = '$ScriptDir=((Split-Path -Parent (''%~dp0''.TrimEnd(''\'')))+''\'')'
$new4 = '$ScriptDir=''%~dp0'''
Need $cmd $old4 'launcher line 4'; $cmd = $cmd.Replace($old4,$new4)
$wUri = '            $fileUri = ([System.Uri]$htmlPath).AbsoluteUri + ''#welcome''   # hero mode: seated bushings, no sidebar'
$wCall= '            Set-WebView2LocalScene -WebView $wv -DocsFolder (Join-Path $ScriptDir ''docs'') -HtmlFile ''drilljig_3d_preview.html'' -Hash ''#welcome'''
$wSrc = '            try { $wv.Source = New-Object System.Uri($fileUri) } catch {}'
Need $cmd $wUri 'welcome nav'; Need $cmd $wSrc 'welcome source'
$cmd = $cmd.Replace($wUri,$wCall).Replace($wSrc,'')
$oUri = '        $fileUri = ([System.Uri]$htmlPath).AbsoluteUri + ''#embed'''
$oCall= '        Set-WebView2LocalScene -WebView $wv -DocsFolder (Join-Path $ScriptDir ''docs'') -HtmlFile ''drilljig_3d_preview.html'' -Hash ''#embed'''
$oSrc = '        try { $wv.Source = New-Object System.Uri($fileUri) } catch {}'
Need $cmd $oUri 'overview nav'; Need $cmd $oSrc 'overview source'
$cmd = $cmd.Replace($oUri,$oCall).Replace($oSrc,'')
if (([regex]::Matches($cmd,'Set-WebView2LocalScene -WebView')).Count -ne 2) { throw "launcher: expected 2 Set-WebView2LocalScene calls after patching" }
WT "$stage/drilljig-gui.cmd" $cmd

# libs: ship EVERY lib from the live repo (lib/*.ps1, non-recursive so lib/tests is excluded),
# then overlay the offline-patched webview2_host. The launcher only dot-sources a subset, but
# shipping them all means a lib it needs (e.g. hole_layout.ps1) can NEVER be missing -- extras
# are harmless dead files. Completeness is then asserted against the launcher's dot-sources.
Get-ChildItem "$REPO/lib" -Filter *.ps1 -File | ForEach-Object { Copy-Item $_.FullName "$stage/lib/$($_.Name)" -Force }
Copy-Item "$HB/overlay/webview2_host.ps1" "$stage/lib/webview2_host.ps1" -Force
$needed = [regex]::Matches($cmd, "lib\\([A-Za-z0-9_]+\.ps1)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
foreach ($n in $needed) { if (-not (Test-Path "$stage/lib/$n")) { throw "offline bundle is MISSING a lib the launcher dot-sources: $n" } }
Write-Host ("  libs bundled: {0} .ps1 (launcher references {1}, all present incl. hole_layout.ps1)" -f (Get-ChildItem "$stage/lib" -Filter *.ps1).Count, @($needed).Count)
# data catalogs (committed under handbook/data -- the repo copies are gitignored, so
# they are absent in a fresh CI checkout; the committed handbook copy is the source of truth)
foreach ($c in 'bushings.csv','bushings_drill.csv','bushings_archive.csv') { if (Test-Path "$HB/data/$c") { Copy-Item "$HB/data/$c" "$stage/data/$c" -Force } }
# docs: decision tree (live) + patched preview + vendored three.js
Copy-Item "$REPO/docs/drill_jig_decision_tree.json" "$stage/docs/" -Force
Copy-Item "$HB/overlay/drilljig_3d_preview.html" "$stage/docs/drilljig_3d_preview.html" -Force
Copy-Item "$HB/vendor/three/three.module.js" "$stage/docs/vendor/three/three.module.js" -Force
Copy-Item "$HB/vendor/three/addons/controls/OrbitControls.js" "$stage/docs/vendor/three/addons/controls/OrbitControls.js" -Force
# vendored WebView2 SDK
Copy-Item -Recurse "$HB/vendor/webview2" "$stage/webview2" -Force
WT "$stage/README.md" ("drilljig-gui -- self-contained offline bundle.`nAuto-built from ngs-orthogrid-automation @ $Sha. See the code repo for full docs.`n")

$guiZip = Join-Path $tmp 'drilljig-gui.zip'
Compress-Archive -Path $stage -DestinationPath $guiZip -Force
Write-Host ("  offline zip: {0:N0} bytes" -f (Get-Item $guiZip).Length)

# ---------------------------------------------------------------- 2. toolkit zip (live repo, scrubbed)
$kit = Join-Path $tmp 'ngs-orthogrid-automation'
New-Item -ItemType Directory -Force -Path $kit | Out-Null
foreach ($d in 'pipeline','tools','previews','probes','lib','data','docs') { if (Test-Path "$REPO/$d") { Copy-Item -Recurse "$REPO/$d" $kit } }
# the catalogs are gitignored (absent in CI checkout) -- overlay them from the committed handbook copy
New-Item -ItemType Directory -Force -Path "$kit/data" | Out-Null
foreach ($c in 'bushings.csv','bushings_drill.csv','bushings_archive.csv') { if (Test-Path "$HB/data/$c") { Copy-Item "$HB/data/$c" "$kit/data/$c" -Force } }
if (Test-Path "$REPO/ps1 archive") { Copy-Item -Recurse "$REPO/ps1 archive" $kit }
if (Test-Path "$REPO/README.md")   { Copy-Item "$REPO/README.md" $kit }
if (Test-Path "$REPO/context-files") {
  New-Item -ItemType Directory -Force -Path "$kit/context-files" | Out-Null
  foreach ($f in 'CLAUDE.md','DEV_NOTES.md','MAPKEYS.md','CREO_MAPKEY_AUTOMATION_GUIDE.md') { if (Test-Path "$REPO/context-files/$f") { Copy-Item "$REPO/context-files/$f" "$kit/context-files/" } }
}
# scrub secrets / gitignored runtime that may have been copied
Get-ChildItem $kit -Recurse -File | Where-Object { $_.Name -match '(_eval\.json$)|(^\.bluegpt_judge\.json$)|(_index_report\.txt$)|(^\.converge)|(credential)' } | ForEach-Object { [System.IO.File]::Delete($_.FullName) }
$arts = Join-Path $kit 'artifacts'; if (Test-Path $arts) { Get-ChildItem $arts -File | Where-Object { $_.Name -ne '.gitkeep' } | ForEach-Object { [System.IO.File]::Delete($_.FullName) } }
$bad = Get-ChildItem $kit -Recurse -File | Where-Object { $_.Name -match 'credential|judge.*json|settings\.local' }
if ($bad) { throw ("secret leaked into toolkit stage: " + ($bad.Name -join ', ')) }
$kitZip = Join-Path $tmp 'ngs-orthogrid-toolkit.zip'
Compress-Archive -Path $kit -DestinationPath $kitZip -Force
Write-Host ("  toolkit zip: {0:N0} bytes" -f (Get-Item $kitZip).Length)

# ---------------------------------------------------------------- 3. assemble index.html
$html = RT "$HB/shell.html"
foreach ($k in 'tab1','tab2','tab3','tab4') {
  $pf = "$HB/parts/$k.html"; if (-not (Test-Path $pf)) { throw "missing fragment $pf" }
  $html = $html.Replace("<!--INCLUDE:$k-->", (RT $pf))
}
# freshness stamp in the footer
$stamp = (Get-Date).ToString('yyyy-MM-dd')
$html = $html.Replace('generated 2026-07-28', "generated $stamp &middot; build $Sha")
# inline screenshots: data-shot="FILE" -> src="data:image/png;base64,.."
$injShots = 0
foreach ($png in Get-ChildItem "$HB/shots" -Filter *.png) {
  $tok = 'data-shot="' + $png.Name + '"'
  if ($html.IndexOf($tok) -ge 0) { $html = $html.Replace($tok, 'src="data:image/png;base64,' + (B64 $png.FullName) + '"'); $injShots++ }
}
# inline tutorial video(s): data-video="FILE" -> src="data:video/mp4;base64,.." (same self-contained
# scheme as the screenshots -- the compressed mp4 lives under handbook/media and is committed source).
$injVids = 0
if (Test-Path "$HB/media") {
  foreach ($mp4 in Get-ChildItem "$HB/media" -Filter *.mp4 -File) {
    $tok = 'data-video="' + $mp4.Name + '"'
    if ($html.IndexOf($tok) -ge 0) { $html = $html.Replace($tok, 'src="data:video/mp4;base64,' + (B64 $mp4.FullName) + '"'); $injVids++ }
  }
}
# payload <script> blocks
$blocks = New-Object System.Collections.Generic.List[string]
function Payload($id,$file,$mime,$path){ "<script type=""application/octet-stream"" id=""$id"" data-filename=""$file"" data-mime=""$mime"">" + (B64 $path) + "</script>" }
$blocks.Add((Payload 'pl_gui_zip'     'drilljig-gui.zip'          'application/zip' $guiZip))
$blocks.Add((Payload 'pl_toolkit_zip' 'ngs-orthogrid-toolkit.zip' 'application/zip' $kitZip))
if (Test-Path "$REPO/docs/DEVELOPMENT_SETUP.html") { $blocks.Add((Payload 'pl_dev_html' 'DEVELOPMENT_SETUP.html' 'text/html' "$REPO/docs/DEVELOPMENT_SETUP.html")) }
$cmdCount = 0
foreach ($sub in 'pipeline','tools','previews','probes') {
  Get-ChildItem "$REPO/$sub" -Filter *.cmd -File | ForEach-Object {
    if ($_.Name -ieq 'drilljig-gui.cmd') { return }
    $id = 'pl_cmd_' + [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
    $blocks.Add((Payload $id $_.Name 'application/octet-stream' $_.FullName)); $script:cmdCount++
  }
}
$html = $html.Replace('<!--PAYLOADS-->', ($blocks -join "`n"))
WT $Out $html

# ---------------------------------------------------------------- 4. sanity checks
$final = RT $Out
$leftInc = ([regex]::Matches($final,'<!--INCLUDE:')).Count
$leftShot= ([regex]::Matches($final,'data-shot=')).Count
$leftVid = ([regex]::Matches($final,'data-video=')).Count
$leftPay = ([regex]::Matches($final,'<!--PAYLOADS-->')).Count
$refIds  = [regex]::Matches($final, "dl\('([^']+)'\)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
$haveIds = [regex]::Matches($final, 'id="(pl_[^"]+)"')  | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
$missing = $refIds | Where-Object { $_ -and ($haveIds -notcontains $_) }
$fi = Get-Item $Out
Write-Host ""
Write-Host ("WROTE {0}  ({1:N2} MB)" -f $Out, ($fi.Length/1MB))
Write-Host ("  screenshots inlined = {0}; videos inlined = {1}; individual .cmd embedded = {2}" -f $injShots, $injVids, $cmdCount)
Write-Host ("  unspliced markers: INCLUDE={0} PAYLOADS={1}; leftover data-shot={2} data-video={3} (all want 0)" -f $leftInc,$leftPay,$leftShot,$leftVid)
if ($missing) { throw ("buttons reference MISSING payloads: " + ($missing -join ', ')) }
if ($leftInc -ne 0 -or $leftPay -ne 0 -or $leftShot -ne 0 -or $leftVid -ne 0) { throw "unspliced markers remain -- build incomplete" }
Write-Host ("  every dl() button has a payload ({0} referenced). OK." -f (@($refIds).Count))

# cleanup temp
try { [System.IO.Directory]::Delete($tmp, $true) } catch {}

# ---------------------------------------------------------------- 5. optional one-command publish
# Rebuild + push index.html straight to the drilljig-handbook repo (Pages redeploys).
# Uses your local git credentials for gitlab.blueorigin.com (no CI needed).
if ($Publish) {
  Write-Host ""
  Write-Host "publishing to $PublishRepo ..."
  $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $env:GIT_TERMINAL_PROMPT = '0'; $env:GCM_INTERACTIVE = 'never'
  $wd = Join-Path ([System.IO.Path]::GetTempPath()) ("hbpub_" + [System.IO.Path]::GetRandomFileName())
  try {
    git clone $PublishRepo $wd
    if ($LASTEXITCODE -ne 0) { throw "publish: clone failed (check access/credentials to drilljig-handbook)" }
    $pub = Join-Path $wd 'public'
    if (-not (Test-Path $pub)) { New-Item -ItemType Directory -Force -Path $pub | Out-Null }
    Copy-Item $Out (Join-Path $pub 'index.html') -Force
    git -C $wd add public/index.html
    git -C $wd diff --cached --quiet
    if ($LASTEXITCODE -eq 0) {
      Write-Host "  handbook already up to date on the remote - nothing to publish."
    } else {
      git -C $wd -c user.email="handbook-build@blueorigin.com" -c user.name="Handbook Build" commit -m "Publish handbook from ngs-orthogrid-automation @ $Sha"
      git -C $wd push origin HEAD:main
      if ($LASTEXITCODE -ne 0) { throw "publish: push failed (protected branch / access?)" }
      Write-Host "  PUBLISHED -> drilljig-handbook. GitLab Pages will redeploy shortly."
    }
  } finally {
    $ErrorActionPreference = $prevEAP
    try { [System.IO.Directory]::Delete($wd, $true) } catch {}
  }
}
