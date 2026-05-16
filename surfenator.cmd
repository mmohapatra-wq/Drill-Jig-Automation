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

# Use StringBuilder for efficient string concatenation when building large mapkeys
# [void] casting prevents console output of AppendLine return values
$StringBuilder = New-Object System.Text.StringBuilder

# Set Visible Mapkeys to No (speeds up execution and prevents display issues)
[void]$StringBuilder.AppendLine("visible_mapkeys no")

# Start main mapkey
[void]$StringBuilder.AppendLine("mapkey $name @MAPKEY_LABEL$name;\")

# Generate mapkey for each curve - create surface by extruding between planes:
# 1. Select midplane as sketch plane
# 2. Project 3D curve onto sketch plane
# 3. Set up extrude with depth constraints from top to bottom plane
foreach ($item in $curves)
{
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``buffer_clean``;\")

    # Select midplane as sketch plane for extrude feature
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdMdlTreeSearch``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Datum``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``LookByOptionMenu`` 1 ``Feature``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$midPlane``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``EvaluateBtn``;~ Activate ``selspecdlg0`` ``ApplyBtn``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``CancelButton``;~ Command ``ProCmdFtExtrude`` ;\")

    # Project 3D curve onto the sketch plane
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdSketProject``  1;~ Command ``ProCmdMdlTreeSearch`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``3D Curve``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$item``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``EvaluateBtn``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``ApplyBtn``;~ Activate ``selspecdlg0`` ``CancelButton``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``Odui_Dlg_02`` ``stdbtn_1``;~ Command ``ProCmdSketDone`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``UI Message Dialog`` ``ok``;\")

    # Configure extrude depth constraints - from top plane to bottom plane
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``chkbn.extrev_2_options.0`` 1;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``extrev_2_options.0.0`` ``PH.depth1_om`` 1 ``toselected``;\")

    # Select top plane as first depth boundary
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdMdlTreeSearch`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Datum``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``LookByOptionMenu`` 1 ``Feature``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$topPlane``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``EvaluateBtn``;~ Activate ``selspecdlg0`` ``ApplyBtn``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``CancelButton``;\")

    # Configure second depth boundary to bottom plane
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``extrev_2_options.0.0`` ``PH.depth2_om`` 1 ``toselected``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Expand ``main_dlg_cur`` ``PHTLeft.AssyTree`` ``T7 10 21``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Trigger ``extrev_2_options.0.0`` ``PH.depth2_sel_list`` ``0``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Focus ``extrev_2_options.0.0`` ``PH.depth2_sel_list``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``extrev_2_options.0.0`` ``PH.depth2_sel_list`` 0;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Trigger ``extrev_2_options.0.0`` ``PH.depth2_sel_list`` ``;\")

    # Select bottom plane as second depth boundary
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdMdlTreeSearch`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$botPlane``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``EvaluateBtn``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``ApplyBtn``;~ Activate ``selspecdlg0`` ``CancelButton``;\")

    # Set extrude type to "Surface" (Creo 12 UI change)
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``main_dlg_cur`` ``maindashInst0.solid_surf_rg`` 1 ``Surface``;\")

    # Complete the extrude feature
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``dashInst0.Done``;\")
}

# End main mapkey
[void]$StringBuilder.AppendLine('mapkey(continued) ~ Activate `main_dlg_cur` `buffer_clean`;')

# Write the generated mapkey to user's working folder
$username = $env:USERNAME
$StringBuilder.ToString() | Out-File "C:\Users\$username\working_folder\$name.pro"

# Import generated mapkey file into Creo configuration:
# 1. Open Ribbon Options dialog
# 2. Navigate to Configuration page
# 3. Load the generated .pro file
# 4. Accept configuration changes
$session.RunMacro("~ Command ``ProCmdUtilMacros``")
$session.RunMacro("~ Activate ``mapkey_main`` ``psh_import``")
$session.RunMacro("~ Trail `` `` ``DLG_PREVIEW_POST`` ``file_open``")
$session.RunMacro("~ Select ``file_open`` ``Ph_list.Filelist`` 1 ``$name.pro``")
$session.RunMacro("~ Command ``ProFileSelPushOpen_Standard@context_dlg_open_cmd``")
$session.RunMacro("~ Activate ``mapkey_main`` ``CloseButton``")
$session.RunMacro("~ Activate ``unsaved_mapkeys`` ``yes``")

# Execute the generated mapkey
$session.RunMacro("%$name")

# Clean up VB API connection
$connection.Disconnect($null)
