<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -STA -Command "$ScriptDir=((Split-Path -Parent ('%~dp0'.TrimEnd('\')))+'\'); $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

# ============================================================================
# drilljig-3d-webview.cmd - HIGH-FIDELITY 3D drill-jig preview window (Stage 2b)
# ============================================================================
# A native Windows PowerShell window that hosts the EXACT three.js/WebGL scene
# from docs\drilljig_3d_preview.html inside an embedded WebView2 (Edge Chromium)
# control - so the picture is byte-for-byte the HTML you already approved, with
# real drilled thru-holes + GPU anti-aliasing + PBR lighting. The window is just
# a chromeless browser frame around that self-contained HTML (which carries its
# own live sliders + math self-test).
#
# WHY THIS over the WPF Media3D window (drilljig-3d-preview.cmd): WPF's software
# 3D fakes holes as peg markers and lacks WebGL AA/lighting. WebView2 renders the
# real thing. drilljig-3d-preview.cmd is KEPT as a zero-dependency fallback.
#
# DEPENDENCY: the WebView2 Runtime (part of Windows 11; present here v150) + the
# SDK DLLs, which already ship on this machine (Office / the Teams add-in) with
# the native loader shipping with Creo + Office. lib\webview2_host.ps1 locates a
# matched set and STAGES it co-located in %TEMP% (no download, no repo binaries).
# If WebView2 can't be loaded, this prints a clear message pointing at the WPF
# fallback window.
#
# STANDALONE & ADDITIVE: touches nothing else. Stage 3 = embed the same WebView2
# control (+ a JS data bridge) into drilljig-gui.cmd.
# ============================================================================

$Host.UI.RawUI.WindowTitle = "DRILLJIG 3D (WebView2)"
$ErrorActionPreference = "Stop"

trap {
    Write-Host ""
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $inv = $_.InvocationInfo
    if ($null -ne $inv) { Write-Host ("  at line {0}: {1}" -f $inv.ScriptLineNumber, $inv.Line.Trim()) -ForegroundColor DarkYellow }
    Write-Host ""
    Write-Host "  If WebView2 could not load, run the zero-dependency WPF window instead:" -ForegroundColor DarkYellow
    Write-Host "      .\drilljig-3d-preview.cmd" -ForegroundColor DarkYellow
    Write-Host ""
    Write-Host "  Press any key to exit..."
    try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch {}
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---- the HTML scene we host --------------------------------------------------
$htmlPath = Join-Path $ScriptDir 'docs\drilljig_3d_preview.html'
if (-not (Test-Path $htmlPath)) { throw "scene not found: $htmlPath" }

# ---- locate + load the WebView2 SDK -----------------------------------------
. (Join-Path $ScriptDir 'lib\webview2_host.ps1')
Write-Host "  locating WebView2 SDK (first run may take a few seconds)..." -ForegroundColor DarkGray
$stage = Add-WebView2Assemblies
Write-Host ("  WebView2 SDK loaded from: {0}" -f $stage) -ForegroundColor DarkGray

# ---- window ------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Drill-Jig 3D Preview  -  WebView2 / three.js  (standalone, no Creo)"
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1180, 780)
$form.MinimumSize = New-Object System.Drawing.Size(820, 560)
$form.BackColor = [System.Drawing.Color]::FromArgb(20,30,52)

$wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
$wv.Dock = 'Fill'
# per-user data folder in %TEMP% (the default would try to write next to
# powershell.exe in System32, which fails)
$props = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
$props.UserDataFolder = Join-Path $env:TEMP 'drilljig_wv2_udf'
$wv.CreationProperties = $props
$form.Controls.Add($wv)

# navigate once the control has a window handle (Add_Shown => handle exists =>
# implicit EnsureCoreWebView2Async runs, then loads the local HTML file)
$form.Add_Shown({
    try { $wv.Source = New-Object System.Uri($htmlPath) }
    catch { [System.Windows.Forms.MessageBox]::Show("WebView2 navigation failed: $($_.Exception.Message)","Drill-Jig 3D") | Out-Null }
    $form.Activate()
})

[void]$form.ShowDialog()
