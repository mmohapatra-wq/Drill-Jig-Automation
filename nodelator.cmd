<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "NODELATOR"
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
    $shortLabel = if ($Label.Length -gt 20) { $Label.Substring(0, 20) } else { $Label }
    Write-Host "`r  [$bar] $($Pct.ToString().PadLeft(3))%  $shortLabel   " -NoNewline -ForegroundColor $color
    if ($Pct -ge 100) { Write-Host "" }
}

function Wait-ModelModified {
    param($Model, [string]$PreviousStamp, [int]$TimeoutMs = 30000)
    $deadline = [DateTime]::Now.AddMilliseconds($TimeoutMs)
    while ([DateTime]::Now -lt $deadline) {
        try {
            if ($Model.VersionStamp -ne $PreviousStamp) { return }
        } catch {}
    }
    Write-Host "  (warning: feature creation timed out)" -ForegroundColor Yellow
}

# ============================================
# HEADER
# ============================================
Write-Host ""
Write-Host "  ███╗   ██╗ ██████╗ ██████╗ ███████╗██╗      █████╗ ████████╗ ██████╗ ██████╗ " -ForegroundColor White
Write-Host "  ████╗  ██║██╔═══██╗██╔══██╗██╔════╝██║     ██╔══██╗╚══██╔══╝██╔═══██╗██╔══██╗" -ForegroundColor White
Write-Host "  ██╔██╗ ██║██║   ██║██║  ██║█████╗  ██║     ███████║   ██║   ██║   ██║██████╔╝" -ForegroundColor White
Write-Host "  ██║╚██╗██║██║   ██║██║  ██║██╔══╝  ██║     ██╔══██║   ██║   ██║   ██║██╔══██╗" -ForegroundColor White
Write-Host "  ██║ ╚████║╚██████╔╝██████╔╝███████╗███████╗██║  ██║   ██║   ╚██████╔╝██║  ██║" -ForegroundColor White
Write-Host "  ╚═╝  ╚═══╝ ╚═════╝ ╚═════╝ ╚══════╝╚══════╝╚═╝  ╚═╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝" -ForegroundColor White
Write-Host "  Node Feature Duplication" -ForegroundColor White
Write-Host ""

# ============================================
# PREREQUISITES
# ============================================
Write-Host "  Prerequisites:" -ForegroundColor Green
Write-Host "    1. Part open in Creo" -ForegroundColor White
Write-Host "    2. Example node feature created (extrude that creates new body)" -ForegroundColor White
Write-Host "    3. Datum points placed at target node locations" -ForegroundColor White
Write-Host "    4. Do not interact with Creo during processing" -ForegroundColor White
Write-Host ""

<#
.SYNOPSIS
    Automates duplication of node features at multiple datum point locations in Creo Parametric

.DESCRIPTION
    This script connects to an active Creo session, uses an example node feature and target datum points,
    generates custom mapkeys, and executes them to copy the node feature to each datum point location.
    Part of the NGS Orthogrid Automation toolkit.

    The script uses the Creo VB API to gather selections, then generates mapkeys that:
    1. Copy the example node feature
    2. Use Paste Special with by-reference assembly operations
    3. Position each copy at the target datum point locations

.PREREQUISITES
    - Active Creo Parametric session (Part or Assembly mode)
    - Pre-existing "example node" feature (typically an extruded solid body that creates new body)
    - Datum points created at desired node locations
    - VB API COM components registered
    - User working_folder directory exists (C:\Users\[username]\working_folder\)

.USAGE
    1. Create an example node feature (extrude set to create new body)
    2. Create datum points at all desired node locations
    3. Run nodelator_RUN.bat or execute this script directly
    4. Select the example node feature when prompted
    5. Select all target datum points when prompted

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
#------------- NODELATOR AUTOMATION LOGIC ---------------------

# Set script name for mapkey generation
$name = "nodelator"

# Collect current selection from Creo's selection buffer
$node = ($session.CurrentSelectionBuffer()).Contents

# Prompt the user if selection was empty - provide clear prerequisites
if ($node -eq $null)
{
    Write-Host "  Select the example node feature in Creo," -ForegroundColor White
    Write-Host "  then press ENTER here." -ForegroundColor White
    Read-Host
    $node = ($session.CurrentSelectionBuffer()).Contents
}
# Extract the node feature ID for copying
$nodeID = $node[0].SelItem.Id

# Collect target datum point locations
Write-Host "  Select datum points for nodes in Creo," -ForegroundColor White
Write-Host "  then press ENTER here." -ForegroundColor White
Read-Host
$points = ($session.CurrentSelectionBuffer()).Contents

# Extract datum point IDs from selection
$pointIDs=@()
foreach ($item in $points)
{
    $pointIDs += $item.SelItem.Id
}

# Initial copy of the example node feature (once)
$copyNode = "~ Activate ``main_dlg_cur`` ``buffer_clean``;" +
    "~ Command ``ProCmdMdlTreeSearch``;" +
    "~ Open ``selspecdlg0`` ``SelOptionRadio``;" +
    "~ Close ``selspecdlg0`` ``SelOptionRadio``;" +
    "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Feature``;" +
    "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
    "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$nodeID``;" +
    "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
    "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
    "~ Activate ``selspecdlg0`` ``CancelButton``;" +
    "~ Command ``ProCmdEditCopy``;"

try { $session.RunMacro($copyNode) } catch {}

# Loop through datum points with progress reporting
$totalPoints = $pointIDs.Count
$pointIndex = 0
foreach ($item in $pointIDs)
{
    $pointIndex++
    $pct = [Math]::Floor(($pointIndex / $totalPoints) * 100)
    Show-Progress $pct "Node $pointIndex/$totalPoints"

    # Paste node at datum point with by-reference assembly operations
    $pasteAtPoint = "~ Activate ``main_dlg_cur`` ``buffer_clean``;" +
        "~ Command ``ProCmdEditPasteSpecial``;" +
        "~ Activate ``paste_special`` ``makecopyiesPB`` 0;" +
        "~ Activate ``paste_special`` ``pastebyrefPB`` 1;" +
        "~ Activate ``paste_special`` ``okPB``;" +
        "~ Trigger ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 ``5`` ``ext_ref_list``;" +
        "~ Trigger ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 ``4`` ``ext_ref_list``;" +
        "~ Select ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 ``4`` ``ext_ref_list``;" +
        "~ Trigger ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 ``3`` ``ext_ref_list``;" +
        "~ Trigger ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 ``2`` ``ext_ref_list``;" +
        "~ Trigger ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 ```` ````;" +
        "~ Activate ``Odui_Dlg_00`` ``t1.body_add_chk_btn`` 1;" +
        "~ Trigger ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 ``5`` ``ext_ref_list``;" +
        "~ Select ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 ``5`` ``ext_ref_list``;" +
        "~ Trigger ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 ```` ````;" +
        "~ Command ``ProCmdMdlTreeSearch``;" +
        "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Point``;" +
        "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
        "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$item``;" +
        "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
        "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
        "~ Activate ``selspecdlg0`` ``CancelButton``;" +
        "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;" +
        "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;"

    try {
        $stamp = $model.VersionStamp
        $session.RunMacro($pasteAtPoint)
        Wait-ModelModified -Model $model -PreviousStamp $stamp
    } catch {}
}
Show-Progress 100 "Nodes complete"

} finally {
    try {
        if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null }
        if ($null -ne $origDynamicPreview)  { $session.SetConfigOption("dynamic_preview",  $origDynamicPreview)  | Out-Null }
    } catch {}
    $connection.Disconnect($null)
}
