<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "FLIPENATOR"
$ErrorActionPreference = "Stop"

trap {
    Write-Host ""
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

$script:lastPct = -1
function Show-Progress {
    param([int]$Pct, [string]$Label)
    if ($Pct -eq $script:lastPct) { return }
    $script:lastPct = $Pct
    $filled = [Math]::Floor($Pct / 5)
    $empty = 20 - $filled
    $bar = ([char]9608).ToString() * $filled + ([char]9617).ToString() * $empty
    $color = if ($Pct -ge 100) { "Green" } else { "White" }
    $shortLabel = if ($Label.Length -gt 60) { $Label.Substring(0, 60) } else { $Label }
    Write-Host "`r  [$bar] $($Pct.ToString().PadLeft(3))%  $shortLabel   " -NoNewline -ForegroundColor $color
    if ($Pct -ge 100) { Write-Host "" }
}

<#
.SYNOPSIS
    Automates flipping/mirroring operations for selected geometric bodies in Creo Parametric

.DESCRIPTION
    This script connects to an active Creo session, collects user-selected solid bodies,
    generates custom mapkeys, and executes them to perform flip operations on each selected body.
    Part of the NGS Orthogrid Automation toolkit.

    The script uses the Creo VB API to gather selections, then generates mapkeys that:
    1. Search and select each feature by ID
    2. Apply Creo's built-in Flip command
    3. Re-select original bodies for user reference

.PREREQUISITES
    - Active Creo Parametric session with solid bodies
    - VB API COM components registered
    - User working_folder directory exists (C:\Users\[username]\working_folder\)

.USAGE
    Run flipenator_RUN.bat or execute this script directly. Select solid bodies in Creo when prompted.

.AUTHOR
    Kyle Brooker - Blue Origin

.REFERENCES
    VB API Documentation: C:/PTC/Creo [version]/Common Files/vbapi/vbapidoc/index.html
    Development Wiki: https://wiki.blueorigin.com/x/mAHdB
    Development Tools: https://code.visualstudio.com/
#>

# Set environment variables for VB API connection
try {
    # Find running Creo process (xtop.exe) to determine installation paths
    $proc = Get-Process | Where-Object {$_.ProcessName -eq "xtop"}
    if ($null -eq $proc) {
        throw "Running Creo process (xtop) not found"
    }

    # Set required environment variables for VB API communication
    $pc_path = $proc.Path -replace "xtop.exe", "pro_comm_msg.exe"
    $Env:PRO_DIRECTORY = $proc.Path.TrimEnd("xtop.exe")
    $Env:PRO_COMM_MSG_EXE = $pc_path
}
catch {
    # Display error and exit gracefully if Creo process not found
    $_
    exit
}

# Check if VB API COM components are registered
# First-time setup automatically runs registration batch file if needed
try {
    New-Object -ComObject pfcls.pfcAsyncConnection | Out-Null
}
catch {
    Write-Output "VB API not yet registered on this machine, performing first time setup..."
    $vb_path = $proc.Path -replace "Common Files(.*)$", "Parametric\bin\vb_api_register.bat"
    Start-Process -Wait -FilePath $vb_path
}

# Establish connection to active Creo session
try {
    $async = New-Object -ComObject pfcls.pfcAsyncConnection
    $connection = $async.Connect($null, $null, $null, $null)
    $session = $connection.Session
}
catch {
    $_
    Write-Output "Could not connect to Creo session."
    Write-Output "Press any key to continue..."
}

# Optional: Set regeneration failure handling (commented out)
# $session.SetConfigOption("regen_failure_handling", "resolve_mode")
$model = $session.GetActiveModel()

$origVisibleMapkeys = $null
$origDynamicPreview = $null
try {
    $vals = $session.GetConfigOptionValues("visible_mapkeys")
    if ($null -ne $vals -and $vals.Count -gt 0) { $origVisibleMapkeys = $vals.Item(0) }
} catch {}
try {
    $vals = $session.GetConfigOptionValues("dynamic_preview")
    if ($null -ne $vals -and $vals.Count -gt 0) { $origDynamicPreview = $vals.Item(0) }
} catch {}
try {
    $session.SetConfigOption("visible_mapkeys", "no") | Out-Null
    $session.SetConfigOption("dynamic_preview", "no") | Out-Null
} catch {}

try {
#------------- FLIPENATOR AUTOMATION LOGIC ---------------------

# Set script name for mapkey generation
$name = "flipenator"

# Collect current selection from Creo's selection buffer
$selection = ($session.CurrentSelectionBuffer()).Contents

# Prompt the user if selection was empty
if ($selection -eq $null)
{
    Read-Host -Prompt "Select bodies to be flipped, return to this window, and press enter"
    $selection = ($session.CurrentSelectionBuffer()).Contents
}

# Extract feature and body IDs from selected solid bodies
# Body IDs used for final re-selection, Feature IDs used for flip operations
$bodyIds=@()
$featIds=@()
foreach ($item in $selection)
{
    $bodyIds += $item.SelItem.Id
    $feature = $item.SelItem.getFeatures()
    $featIds += ($feature | Select-Object -ExpandProperty Id)
}

# Define flip sub-macro (reusable flip operation)
$flipSubMacro = "~ Command ``ProCmdRedefine@PopupMenuGraphicWinStack``;" +
    "~ Activate ``main_dlg_cur`` ``maindashInst0.Flip``;" +
    "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"

# Loop through features with progress reporting
$totalFeatures = $featIds.Count
$featureIndex = 0
foreach ($item in $featIds)
{
    $featureIndex++
    $pct = [Math]::Floor(($featureIndex / $totalFeatures) * 100)
    Show-Progress $pct "Flipping body ${featureIndex}/${totalFeatures}"

    # Select feature by ID and execute flip
    $selectAndFlip = "~ Activate ``main_dlg_cur`` ``buffer_clean``;" +
        "~ Command ``ProCmdMdlTreeSearch``;" +
        "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Feature``;" +
        "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
        "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$item``;" +
        "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
        "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
        "~ Activate ``selspecdlg0`` ``CancelButton``;" +
        $flipSubMacro +
        "~ Activate ``main_dlg_cur`` ``buffer_clean``;"

    try { $session.RunMacro($selectAndFlip) } catch {}
}
Show-Progress 100 "Flip complete"

# Re-select the original bodies for user reference
$reselect = "~ Command ``ProCmdMdlTreeSearch``;" +
    "~ Open ``selspecdlg0`` ``SelOptionRadio``;" +
    "~ Close ``selspecdlg0`` ``SelOptionRadio``;" +
    "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Geometric Body``;" +
    "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;"

foreach ($item in $bodyIds)
{
    $reselect += "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$item``;" +
        "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
        "~ Activate ``selspecdlg0`` ``ApplyBtn``;"
}

$reselect += "~ Activate ``selspecdlg0`` ``CancelButton``;"

try { $session.RunMacro($reselect) } catch {}

} finally {
    try {
        if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null }
        if ($null -ne $origDynamicPreview)  { $session.SetConfigOption("dynamic_preview",  $origDynamicPreview)  | Out-Null }
    } catch {}
    $connection.Disconnect($null)
}
