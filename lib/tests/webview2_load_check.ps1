# ============================================================================
# webview2_load_check.ps1 - headless load assertion for the WebView2 host path
# (drilljig-3d-webview.cmd + lib\webview2_host.ps1).
# ============================================================================
# Proves the SDK can actually be located + loaded + a WebView2 control CONSTRUCTED
# on this machine (the part that can fail: DLL discovery, bitness, co-located
# native loader). It does NOT navigate/render (that needs a live window + the
# runtime); the caller runs the window for the visual check. Exit 0 = the load
# path works. WebView2 WinForms requires STA, so this self-relaunches under -STA.
# ============================================================================
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-STA','-File', $MyInvocation.MyCommand.Path
    ) -Wait -PassThru -NoNewWindow
    exit $p.ExitCode
}

$ErrorActionPreference = 'Stop'
$libDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $libDir 'webview2_host.ps1')
Add-Type -AssemblyName System.Windows.Forms

$fail = 0
try {
    $stage = Add-WebView2Assemblies
    if ((Test-Path (Join-Path $stage 'Microsoft.Web.WebView2.Core.dll')) -and
        (Test-Path (Join-Path $stage 'Microsoft.Web.WebView2.WinForms.dll')) -and
        (Test-Path (Join-Path $stage 'WebView2Loader.dll'))) {
        Write-Host ("  [PASS] staged co-located WebView2 set: {0}" -f $stage)
    } else { Write-Host "  [FAIL] stage missing one of Core/WinForms/Loader"; $fail = 1 }

    $wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
    if ($wv -is [Microsoft.Web.WebView2.WinForms.WebView2]) {
        Write-Host "  [PASS] WebView2 WinForms control constructed (type resolves, native loader beside managed DLLs)"
    } else { Write-Host "  [FAIL] control did not construct"; $fail = 1 }
    $wv.Dispose()
} catch {
    Write-Host ("  [FAIL] {0}" -f $_.Exception.Message); $fail = 1
}

if ($fail -eq 0) { Write-Host "webview2_load_check: ALL PASS"; exit 0 } else { Write-Host "webview2_load_check: FAILURES"; exit 1 }
