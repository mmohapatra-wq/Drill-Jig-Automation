# Isolation check for the standalone holelayoutinator tool (used by the response-
# convergence packet). Exit 0 = isolated: (1) no file drilljig-gui.cmd dot-sources
# was modified since the base ref, and (2) only the new tool + its test reference
# lib\hole_layout.ps1. Exit 1 otherwise. Pure/offline; never touches Creo.
param([string]$BaseRef = '127d6cdf48862daf8c1c5c5d09f9730b720df3c3')
# Deliberately NOT ErrorActionPreference='Stop': `git` writes a benign
# "LF will be replaced by CRLF" line to STDERR, and under Stop a native command's
# stderr becomes a TERMINATING error in PS 5.1 (the documented trap) -- which made
# this exit -999 ("threw") under the convergence harness's cmd /c even though the
# logic passed. Continue + a 2>$null redirect keeps git's stderr from ever throwing.
$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Push-Location $repo
try {
    $chg = @(git diff --name-only $BaseRef 2>$null)
    $guiDeps = @('drilljig-gui.cmd','drilljig.cmd','fastenator.cmd',
        'lib/creo_geometry.ps1','lib/edge_round.ps1','lib/orthogrid.ps1','lib/orthogrid_gui.ps1',
        'lib/orthogrid_points.ps1','lib/fastener_layout.ps1','lib/drilljig_core.ps1',
        'lib/bushing_svg.ps1','lib/wpf3d_preview.ps1','lib/webview2_host.ps1','lib/wizard.ps1')
    foreach ($f in $guiDeps) {
        if ($chg -contains $f) { Write-Host "FAIL: drilljig-gui dependency edited: $f"; exit 1 }
    }
    $files = Get-ChildItem -Recurse -Include *.cmd,*.ps1 | Where-Object { $_.FullName -notlike '*\.git\*' }
    $refs = @(Select-String -Path $files.FullName -Pattern 'hole_layout.ps1' -SimpleMatch -ErrorAction SilentlyContinue |
             ForEach-Object { Split-Path $_.Path -Leaf } | Sort-Object -Unique)
    $allowed = @('holelayoutinator.cmd','hole_layout.ps1','run_hole_layout_tests.ps1','check_holelayout_isolation.ps1')
    foreach ($f in $refs) {
        if ($allowed -notcontains $f) { Write-Host "FAIL: unexpected dependency on hole_layout.ps1: $f"; exit 1 }
    }
    Write-Host "OK: standalone tool is isolated (no drilljig-gui dep edited; only new tool refs the new lib)"
    exit 0
} finally { Pop-Location }
