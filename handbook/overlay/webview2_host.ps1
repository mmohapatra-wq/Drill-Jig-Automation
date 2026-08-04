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
    # OFFLINE BUNDLE (drilljig-gui zip): prefer the WebView2 DLLs vendored beside the
    # tool (<root>\webview2\) over scavenging Office/Teams/Creo at runtime -- this is what
    # makes the shipped zip self-contained (no dependency on any other app being present).
    # $PSScriptRoot is THIS lib's dir (<root>\lib) even when dot-sourced, so the bundle
    # sits one level up in \webview2; the global $ScriptDir set by the launcher is a fallback.
    $bundleCand = @()
    if ($PSScriptRoot) { $bundleCand += (Join-Path (Split-Path $PSScriptRoot -Parent) 'webview2') }
    try { $gsd = Get-Variable -Name ScriptDir -Scope Global -ValueOnly -ErrorAction SilentlyContinue; if ($gsd) { $bundleCand += (Join-Path $gsd 'webview2') } } catch {}
    foreach ($b in $bundleCand) {
        if ($b -and (Test-Path (Join-Path $b 'Microsoft.Web.WebView2.Core.dll')) -and
                    (Test-Path (Join-Path $b 'Microsoft.Web.WebView2.WinForms.dll')) -and
                    (Test-Path (Join-Path $b 'WebView2Loader.dll'))) {
            # MARK-OF-THE-WEB: when the user DOWNLOADS drilljig-gui.zip from the handbook
            # and extracts it with Explorer, every file carries a Zone.Identifier (Internet)
            # NTFS stream. .NET Framework then REFUSES to Add-Type the managed WebView2 DLLs
            # (FileLoadException, HRESULT 0x80131515 "Operation is not supported") -- so the
            # 3D overview silently shows "3D overview unavailable" while the rest of the GUI
            # runs (the .cmd/.ps1 are read as TEXT, so only the assembly load is blocked).
            # Confirmed live via probes\motw-webview2-test.ps1. Strip the mark, best-effort:
            # Unblock-File is safe to run when there is no mark, and a failure here just leaves
            # today's behavior (the caller still tries, and falls back to the WPF window / a note).
            try { Get-ChildItem -LiteralPath $b -Filter *.dll -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue } catch {}
            return $b
        }
    }

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

# Load ONE managed WebView2 DLL, MARK-OF-THE-WEB proof. When the bundle was
# downloaded + Explorer-extracted, each DLL carries a Zone.Identifier (Internet)
# stream and .NET Framework REFUSES to Add-Type it (FileLoadException, HRESULT
# 0x80131515 "Operation is not supported") -- which silently kills the 3D overview.
# Three escalating attempts, each immune to the previous failure:
#   1. Add-Type as-is (fast path; already-unblocked / trusted-zone machines).
#   2. Unblock-File (strip the Zone.Identifier stream) + retry Add-Type.
#   3. LOAD FROM BYTES: [Reflection.Assembly]::Load([byte[]]) has NO file path, so
#      the zone check never runs -- proven to load a MARKED DLL (motw-webview2-test).
# Returns $true on success. Throwing is left to the caller only if ALL THREE fail.
function global:Import-WebView2Dll {
    param([string]$Path)
    try { Add-Type -Path $Path -ErrorAction Stop; return $true } catch {}
    try { Unblock-File -LiteralPath $Path -ErrorAction SilentlyContinue } catch {}
    try { Add-Type -Path $Path -ErrorAction Stop; return $true } catch {}
    # last resort: byte-array load (bypasses Mark-of-the-Web entirely)
    try { [void][System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($Path)); return $true } catch {}
    return $false
}

# Resolve + load the WebView2 assemblies into the AppDomain. Prepends the stage
# folder to PATH so the co-located native loader resolves. Returns the stage dir.
# MARK-OF-THE-WEB proof (see Import-WebView2Dll): a downloaded+extracted bundle
# would otherwise fail to load and hide the 3D overview (and its slot-face toggle).
function global:Add-WebView2Assemblies {
    $stage = Resolve-WebView2Assets
    if ($env:PATH -notlike "*$stage*") { $env:PATH = "$stage;$env:PATH" }
    # unblock the whole staged/bundle folder first (native WebView2Loader.dll too --
    # a marked native DLL can fail to map even when the managed ones load by bytes).
    try { Get-ChildItem -LiteralPath $stage -Filter *.dll -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue } catch {}
    $core = Join-Path $stage 'Microsoft.Web.WebView2.Core.dll'
    $wf   = Join-Path $stage 'Microsoft.Web.WebView2.WinForms.dll'
    if (-not (Import-WebView2Dll $core)) { throw "WebView2 Core.dll could not be loaded (even after unblock + byte-load): $core" }
    if (-not (Import-WebView2Dll $wf))   { throw "WebView2 WinForms.dll could not be loaded (even after unblock + byte-load): $wf" }
    return $stage
}

# ============================================================================
# Set-WebView2LocalScene - navigate a WebView2 control to the local preview HTML
# OFFLINE. A raw file:// origin BLOCKS the page's ES-module imports (Chromium/
# WebView2 CORS: module fetch from origin 'null' is denied), so the vendored
# three.js under docs\vendor only loads when the folder is served under a virtual
# https origin. This maps $DocsFolder -> https://drilljig.local/ and navigates
# there. If the runtime is too old for SetVirtualHostNameToFolderMapping (or any
# step throws), it FALLS BACK to the original file:// navigation -- i.e. exactly
# today's behavior (offline that shows the page's graceful "needs three.js" note).
# So this is a strict superset: it can make the preview work offline, never regress.
# ============================================================================
function global:Set-WebView2LocalScene {
    param($WebView, [string]$DocsFolder, [string]$HtmlFile, [string]$Hash = '')
    $vhost   = 'drilljig.local'
    $navUrl  = "https://$vhost/$HtmlFile$Hash"
    $fileUri = ([System.Uri](Join-Path $DocsFolder $HtmlFile)).AbsoluteUri + $Hash
    # captured by value so it survives past this function into the init event
    $apply = {
        param($ctl)
        $ok = $false
        try {
            $ctl.CoreWebView2.SetVirtualHostNameToFolderMapping($vhost, $DocsFolder, [Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind]::Allow)
            $ctl.CoreWebView2.Navigate($navUrl); $ok = $true
        } catch { $ok = $false }
        if (-not $ok) { try { $ctl.Source = New-Object System.Uri($fileUri) } catch {} }
    }.GetNewClosure()
    if ($null -ne $WebView.CoreWebView2) {
        & $apply $WebView
    } else {
        $WebView.add_CoreWebView2InitializationCompleted({
            param($s, $e)
            if ($e.IsSuccess) { & $apply $s } else { try { $s.Source = New-Object System.Uri($fileUri) } catch {} }
        }.GetNewClosure())
        try { $null = $WebView.EnsureCoreWebView2Async($null) }
        catch { try { $WebView.Source = New-Object System.Uri($fileUri) } catch {} }
    }
}
