<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "SURFENATOR"
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
    Automates surface creation by extruding 3D curves between datum planes in Creo Parametric

.DESCRIPTION
    This script connects to an active Creo session, collects user-selected 3D curves and three datum planes,
    generates custom mapkeys, and executes them to create surfaces by extruding curves between the planes.
    Part of the NGS Orthogrid Automation toolkit.

    The script uses the Creo VB API to gather selections, then generates mapkeys that:
    1. Project each 3D curve onto the midplane
    2. Create extrude features extending from top plane to bottom plane
    3. Generate surface structure between orthogrid planes

.PREREQUISITES
    - Active Creo Parametric session with 3D curves and datum planes
    - 3D curves created at desired locations
    - Three datum planes: midplane (sketch plane), top plane, bottom plane
    - VB API COM components registered
    - User working_folder directory exists (C:\Users\[username]\working_folder\)

.USAGE
    1. Create 3D curves at desired surface locations
    2. Create three datum planes (midplane for sketching, top/bottom for extrude bounds)
    3. Run surfenator_RUN.bat or execute this script directly
    4. Select curves when prompted
    5. Select midplane, then top plane, then bottom plane when prompted

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
#------------- SURFENATOR AUTOMATION LOGIC ---------------------

# Set script name for mapkey generation
$name = "surfenator"

# Collect 3D curves from user
Read-Host -Prompt "Select curves to be extruded, return to this window, and press enter"
$selection = ($session.CurrentSelectionBuffer()).Contents

# Extract curve IDs handling both individual curves and composite selections
# Try ListElements() for composite features, fallback to direct ID for individual curves
$curves=@()
foreach ($temp1 in $selection)
{
    try
    {
        # Handle composite curve features (multiple elements)
        foreach ($temp2 in $temp1.SelItem.ListElements())
        {
            $curves += $temp2.id
        }
    }
    catch
    {
        # Handle individual curve selection
        $curves += $temp1.SelItem.Id
    }
}

# Collect three datum planes with specific roles
Read-Host -Prompt "Select the midplane (sketch plane for curve projection), return to this window, and press enter"
$selection = ($session.CurrentSelectionBuffer()).Contents
$midPlane = $selection[0].SelItem.Id

Read-Host -Prompt "Select the topplane (extrude end boundary), return to this window, and press enter"
$selection = ($session.CurrentSelectionBuffer()).Contents
$topPlane = $selection[0].SelItem.Id

Read-Host -Prompt "Select the botplane (extrude start boundary), return to this window, and press enter"
$selection = ($session.CurrentSelectionBuffer()).Contents
$botPlane = $selection[0].SelItem.Id

# Build one giant command string for all curves
$allCommands = ""

$totalCurves = $curves.Count
foreach ($item in $curves)
{
    # Add commands for this curve to the master string
    $allCommands += "~ Activate ``main_dlg_cur`` ``buffer_clean``;" +
        "~ Command ``ProCmdMdlTreeSearch``;" +
        "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Datum``;" +
        "~ Select ``selspecdlg0`` ``LookByOptionMenu`` 1 ``Feature``;" +
        "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
        "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$midPlane``;" +
        "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
        "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
        "~ Activate ``selspecdlg0`` ``CancelButton``;" +
        "~ Command ``ProCmdFtExtrude``;" +
        "~ Command ``ProCmdSketProject`` 1;" +
        "~ Command ``ProCmdMdlTreeSearch``;" +
        "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``3D Curve``;" +
        "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$item``;" +
        "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
        "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
        "~ Activate ``selspecdlg0`` ``CancelButton``;" +
        "~ Activate ``Odui_Dlg_02`` ``stdbtn_1``;" +
        "~ Command ``ProCmdSketDone``;" +
        "~ Activate ``UI Message Dialog`` ``ok``;" +
        "~ Activate ``main_dlg_cur`` ``chkbn.extrev_2_options.0`` 1;" +
        "~ Select ``extrev_2_options.0.0`` ``PH.depth1_om`` 1 ``toselected``;" +
        "~ Command ``ProCmdMdlTreeSearch``;" +
        "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Datum``;" +
        "~ Select ``selspecdlg0`` ``LookByOptionMenu`` 1 ``Feature``;" +
        "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$topPlane``;" +
        "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
        "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
        "~ Activate ``selspecdlg0`` ``CancelButton``;" +
        "~ Select ``extrev_2_options.0.0`` ``PH.depth2_om`` 1 ``toselected``;" +
        "~ Expand ``main_dlg_cur`` ``PHTLeft.AssyTree`` ``T7 10 21``;" +
        "~ Trigger ``extrev_2_options.0.0`` ``PH.depth2_sel_list`` ``0``;" +
        "~ Focus ``extrev_2_options.0.0`` ``PH.depth2_sel_list``;" +
        "~ Select ``extrev_2_options.0.0`` ``PH.depth2_sel_list`` 0;" +
        "~ Trigger ``extrev_2_options.0.0`` ``PH.depth2_sel_list`` ``;" +
        "~ Command ``ProCmdMdlTreeSearch``;" +
        "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$botPlane``;" +
        "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
        "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
        "~ Activate ``selspecdlg0`` ``CancelButton``;" +
        "~ Select ``main_dlg_cur`` ``maindashInst0.solid_surf_rg`` 1 ``Surface``;" +
        "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"
}

# Execute all commands as a single RunMacro call
Write-Host "Executing macro for $totalCurves surface extrusions..."
try {
    $session.RunMacro($allCommands)
} catch {
    Write-Host "Error during execution: $_" -ForegroundColor Red
}

} finally {
    try {
        if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null }
        if ($null -ne $origDynamicPreview)  { $session.SetConfigOption("dynamic_preview",  $origDynamicPreview)  | Out-Null }
    } catch {}
    $connection.Disconnect($null)
}
