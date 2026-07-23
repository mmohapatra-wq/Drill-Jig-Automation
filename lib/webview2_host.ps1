# ============================================================================
# lib\webview2_host.ps1 - locate + load the WebView2 SDK so a PowerShell WinForms
# window can embed an Edge (Chromium) browser control. NO download, NO vendored
# binaries: the SDK DLLs already ship on this class of machine (Office, the Teams
# add-in) and the native WebView2Loader.dll ships with Creo + Office; the
# Evergreen WebView2 Runtime is part of Windows 11. This module finds a matched
# set, STAGES it co-located in %TEMP% (so the native loader sits beside the
# managed DLLs and the bitness is correct), and Add-Type's it.
#
# Shared by drilljig-3d-webview.cmd (the standalone window) and the headless
# load-check test; the eventual drilljig-gui integration reuses it.
# ============================================================================

# Resolve a %TEMP% folder holding a co-located, correct-bitness WebView2 set
# (Core + WinForms managed DLLs + native WebView2Loader.dll). Copies from the
# on-disk SDK the first run, then reuses the stage. Throws a clear message if no
# usable set is found (the caller can fall back to the WPF window).
function global:Resolve-WebView2Assets {
    $stage = Join-Path $env:TEMP 'drilljig_wv2'
    $core  = Join-Path $stage 'Microsoft.Web.WebView2.Core.dll'
    $wf    = Join-Path $stage 'Microsoft.Web.WebView2.WinForms.dll'
    $ld    = Join-Path $stage 'WebView2Loader.dll'
    if ((Test-Path $core) -and (Test-Path $wf) -and (Test-Path $ld)) { return $stage }

    New-Item -ItemType Directory -Force -Path $stage | Out-Null

    # --- managed DLLs (AnyCPU): a folder that has BOTH Core + WinForms --------
    $mgmtDir = $null
    $mgmtCand = @()
    $teams = Join-Path $env:LOCALAPPDATA 'Microsoft\TeamsMeetingAdd-in'
    if (Test-Path $teams) {
        Get-ChildItem $teams -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | ForEach-Object {
            $mgmtCand += (Join-Path $_.FullName 'x64')
        }
    }
    foreach ($d in $mgmtCand) {
        if ((Test-Path (Join-Path $d 'Microsoft.Web.WebView2.Core.dll')) -and
            (Test-Path (Join-Path $d 'Microsoft.Web.WebView2.WinForms.dll'))) { $mgmtDir = $d; break }
    }
    if (-not $mgmtDir) {
        foreach ($r in @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if (-not $r -or -not (Test-Path $r)) { continue }
            $hit = Get-ChildItem $r -Recurse -Filter 'Microsoft.Web.WebView2.WinForms.dll' -ErrorAction SilentlyContinue -Depth 7 |
                   Where-Object { Test-Path (Join-Path $_.DirectoryName 'Microsoft.Web.WebView2.Core.dll') } | Select-Object -First 1
            if ($hit) { $mgmtDir = $hit.DirectoryName; break }
        }
    }
    if (-not $mgmtDir) { throw "WebView2 managed DLLs (Core + WinForms) not found on this machine." }
    Copy-Item (Join-Path $mgmtDir 'Microsoft.Web.WebView2.Core.dll') $core -Force
    Copy-Item (Join-Path $mgmtDir 'Microsoft.Web.WebView2.WinForms.dll') $wf -Force

    # --- native WebView2Loader.dll matching the process bitness ---------------
    $want64 = [Environment]::Is64BitProcess
    $ldCand = @()
    if (Test-Path (Join-Path $mgmtDir 'WebView2Loader.dll')) { $ldCand += (Join-Path $mgmtDir 'WebView2Loader.dll') }
    if ($want64) {
        $ldCand += (Join-Path ${env:ProgramFiles} 'Microsoft Office\root\Office16\WebView2Loader.dll')
        $ldCand += (Join-Path ${env:ProgramFiles} 'Common Files\PTC\Creo\Platform\12\WebView2Loader.dll')
    }
    $ldSrc = $null
    foreach ($c in $ldCand) { if ($c -and (Test-Path $c)) { $ldSrc = $c; break } }
    if (-not $ldSrc) {
        # broad search, biased to the right bitness (x86 paths excluded when 64-bit)
        foreach ($r in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
            if (-not $r -or -not (Test-Path $r)) { continue }
            $hit = Get-ChildItem $r -Recurse -Filter 'WebView2Loader.dll' -ErrorAction SilentlyContinue -Depth 7 |
                   Where-Object { if ($want64) { $_.FullName -notmatch '\\x86\\|WOW64' } else { $_.FullName -match '\\x86\\|SysWOW64' } } |
                   Select-Object -First 1
            if ($hit) { $ldSrc = $hit.FullName; break }
        }
    }
    if (-not $ldSrc) { throw "native WebView2Loader.dll not found on this machine." }
    Copy-Item $ldSrc $ld -Force
    return $stage
}

# Resolve + load the WebView2 assemblies into the AppDomain. Prepends the stage
# folder to PATH so the co-located native loader resolves. Returns the stage dir.
function global:Add-WebView2Assemblies {
    $stage = Resolve-WebView2Assets
    if ($env:PATH -notlike "*$stage*") { $env:PATH = "$stage;$env:PATH" }
    Add-Type -Path (Join-Path $stage 'Microsoft.Web.WebView2.Core.dll')
    Add-Type -Path (Join-Path $stage 'Microsoft.Web.WebView2.WinForms.dll')
    return $stage
}
