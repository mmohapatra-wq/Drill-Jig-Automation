# verify_render.ps1 - headless browser-render check for the FSAE Thermal Academy app.
# Runs index.html in headless Edge, dumps the rendered DOM, strips <script> source,
# and asserts the JS actually built the page (home markers present) with no
# un-interpolated ${...} template or 'undefined' leakage. Exit 0 = render OK.
$ErrorActionPreference = 'Stop'
try {
    $html = Join-Path $PSScriptRoot 'index.html'
    if (-not (Test-Path $html)) { Write-Host "index.html not found"; exit 1 }

    $edge = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    if (-not (Test-Path $edge)) { $edge = "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe" }
    if (-not (Test-Path $edge)) { Write-Host "Edge not found - skipping render check (pass)"; exit 0 }

    $url = "file:///" + ($html -replace '\\','/')
    $out = Join-Path $env:TEMP ("cv_render_" + [System.Guid]::NewGuid().ToString('N') + ".txt")
    $err = $out + ".err"
    $args = @('--headless=new','--disable-gpu','--no-sandbox','--virtual-time-budget=6000','--dump-dom',$url)
    Start-Process -FilePath $edge -ArgumentList $args -NoNewWindow -Wait `
        -RedirectStandardOutput $out -RedirectStandardError $err | Out-Null

    if (-not (Test-Path $out)) { Write-Host "no DOM dump produced"; exit 1 }
    $c = Get-Content $out -Raw
    Remove-Item $out,$err -Force -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($c)) { Write-Host "empty DOM dump"; exit 1 }

    # strip <script>...</script> source (it legitimately contains ${...} template literals)
    $body = [regex]::Replace($c, '(?s)<script.*?</script>', '')

    $okHome   = ($body -match 'Begin Module 1') -and ($body -match 'Facts checked')
    $okNav    = ([regex]::Matches($body, 'class="navitem')).Count -ge 11   # welcome + 9 modules + 2 ref
    $noTmpl   = -not ($body -match '\$\{')
    $noUndef  = -not ($body.ToLower() -match '>undefined<|undefined<')

    Write-Host ("home=$okHome nav>=11=$okNav noTemplateLeak=$noTmpl noUndefined=$noUndef")
    if ($okHome -and $okNav -and $noTmpl -and $noUndef) { exit 0 } else { exit 1 }
}
catch {
    Write-Host "render check error: $($_.Exception.Message)"
    exit 1
}
