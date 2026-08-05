# Verify the rebuilt handbook/dist/index.html embeds the METAL->PFD no-bushing update:
#   (1) the visible prose carries the "None -- direct drill" table row + "No bushing" card,
#   (2) the embedded drilljig-gui.zip carries the updated tree JSON (no "3/4 ID sleeves"),
#       the launcher wiring (Get-FixedOdChoiceSpec + Resolve-NoBushingPick), and the core
#       helpers (Get-FixedOdChoiceSpec / Get-FixedOdGroups / Resolve-NoBushingPick), and
#   (3) driving the EXTRACTED bundle's engine through the METAL->PFD leaf resolves a
#       no-bushing pick (ID '(no bushing)', OD 0.75, a positive plate thickness, no PN).
# Exit 0 iff every assertion holds; exit 1 otherwise. Used as a convergence cmd-check.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$idx  = Join-Path $repo 'handbook\dist\index.html'
$fail = @()
try {
    if (-not (Test-Path $idx)) { throw "dist/index.html not found -- run handbook\build.ps1 first" }
    $html = Get-Content $idx -Raw
    if ($html -notmatch 'None</strong> &mdash; direct drill') { $fail += 'prose: "None -- direct drill" table row missing' }
    if ($html -notmatch 'No bushing \(direct drill\)')        { $fail += 'prose: "No bushing (direct drill)" card missing' }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $m = [regex]::Match($html, '<script[^>]*id="pl_gui_zip"[^>]*>([A-Za-z0-9+/=]+)</script>')
    if (-not $m.Success) { throw 'embedded pl_gui_zip payload not found' }
    $bytes = [Convert]::FromBase64String($m.Groups[1].Value)
    $tmp = Join-Path $env:TEMP ('pfdverify_' + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $zpath = Join-Path $tmp 'gui.zip'; [System.IO.File]::WriteAllBytes($zpath, $bytes)
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zpath, $tmp)
        $root = Join-Path $tmp 'drilljig-gui'

        $tree = Get-Content (Join-Path $root 'docs\drill_jig_decision_tree.json') -Raw
        if ($tree -match '3/4 ID sleeves')          { $fail += 'embedded tree still says "3/4 ID sleeves"' }
        if ($tree -notmatch 'no bushing \(PFD')     { $fail += 'embedded tree missing the no-bushing PFD leaf' }

        $cmd = Get-Content (Join-Path $root 'drilljig-gui.cmd') -Raw
        if ($cmd -notmatch 'Get-FixedOdChoiceSpec') { $fail += 'embedded launcher missing Get-FixedOdChoiceSpec wiring' }
        if ($cmd -notmatch 'Resolve-NoBushingPick') { $fail += 'embedded launcher missing Resolve-NoBushingPick branch' }

        # Drive the EXTRACTED engine through the leaf.
        . (Join-Path $root 'lib\drilljig_core.ps1')
        Initialize-DrilljigCore -DataDir (Join-Path $root 'data') 2>$null | Out-Null
        $troot = Get-Content (Join-Path $root 'docs\drill_jig_decision_tree.json') -Raw | ConvertFrom-Json
        $metal = @($troot)[0].children | Where-Object { $_.label -eq 'Metal' }
        $pfd   = $metal.children[0].children | Where-Object { $_.label -eq 'PFD' }
        $leaf  = $pfd.children[0].label
        $choice = Get-FixedOdChoiceSpec -Label $leaf
        if ($null -eq $choice)                       { $fail += 'engine: METAL->PFD leaf not recognized as a no-bushing choice spec' }
        elseif (-not $choice.NoBushing)              { $fail += 'engine: choice spec NoBushing flag not set' }
        if ($null -ne (Get-CatalogSpec -Label $leaf)) { $fail += 'engine: METAL->PFD leaf wrongly parses as a catalog (sleeve) spec' }
        if ($choice) {
            $g = Get-FixedOdGroups -ODs $choice.Filters[0].Values
            $pick = Resolve-NoBushingPick -OD $g[0].OD -Length 0.75 -LenLabel '3/4' -OdLabel $g[0].ODLabel
            if ([math]::Abs([double]$pick.OD - 0.75) -gt 1e-6) { $fail += "engine: resolved hole OD is $($pick.OD), expected 0.75" }
            if ($pick.ID -ne '(no bushing)')                   { $fail += "engine: resolved ID is '$($pick.ID)', expected '(no bushing)'" }
            if ([double]$pick.Length -le 0)                    { $fail += 'engine: resolved plate thickness is not positive' }
            if ($pick.PartNumber -notmatch '(?i)n/a|no bushing') { $fail += "engine: resolved PartNumber '$($pick.PartNumber)' does not flag no-bushing" }
        }
    } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
} catch { $fail += "threw: $($_.Exception.Message)" }

if ($fail.Count -eq 0) {
    Write-Host "PFD no-bushing bundle verification: PASS (prose + embedded zip + engine walk)" -ForegroundColor Green
    exit 0
} else {
    Write-Host "PFD no-bushing bundle verification: FAIL" -ForegroundColor Red
    $fail | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
