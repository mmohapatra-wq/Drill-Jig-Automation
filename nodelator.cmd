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

#------------- NODELATOR AUTOMATION LOGIC ---------------------

# Set script name for mapkey generation
$name = "nodelator"

# Collect current selection from Creo's selection buffer
$node = ($session.CurrentSelectionBuffer()).Contents

# Prompt the user if selection was empty - provide clear prerequisites
if ($node -eq $null)
{
    Write-Output "PREREQUISITES:"
    Write-Output "1. Create an example node feature (extrude that creates new body)"
    Write-Output "2. Create datum points at desired node locations"
    Write-Output "3. Select the example node feature when prompted"
    Read-Host -Prompt "Select feature of the example node, return to this window, and press enter"
    $node = ($session.CurrentSelectionBuffer()).Contents
}
# Extract the node feature ID for copying
$nodeID = $node[0].SelItem.Id

# Collect target datum point locations
Read-Host -Prompt "Select the datum points for the nodes, return to this window, and press enter"
$points = ($session.CurrentSelectionBuffer()).Contents

# Extract datum point IDs from selection
$pointIDs=@()
foreach ($item in $points)
{
    $pointIDs += $item.SelItem.Id
}

# Use StringBuilder for efficient string concatenation when building large mapkeys
# [void] casting prevents console output of AppendLine return values
$StringBuilder = New-Object System.Text.StringBuilder

# Set Visible Mapkeys to No (speeds up execution and prevents display issues)
[void]$StringBuilder.AppendLine("visible_mapkeys no")

# Start main mapkey - begins with copying the example node feature
[void]$StringBuilder.AppendLine("mapkey $name @MAPKEY_LABEL$name;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``buffer_clean``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdMdlTreeSearch`` ;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Open ``selspecdlg0`` ``SelOptionRadio``;~ Close ``selspecdlg0`` ``SelOptionRadio``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Feature``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$nodeID``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``EvaluateBtn``;~ Activate ``selspecdlg0`` ``ApplyBtn``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``CancelButton``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdEditCopy``;\")

# Generate mapkey that iterates through each datum point:
# 1. Paste Special with by-reference assembly operations
# 2. Configure external reference table for node placement
# 3. Select target datum point for positioning
foreach ($item in $pointIDs)
{
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``buffer_clean``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdEditPasteSpecial`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``paste_special`` ``makecopyiesPB`` 0;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``paste_special`` ``pastebyrefPB`` 1;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``paste_special`` ``okPB``;\")

    # Configure Paste Special dialog for by-reference copying:
    # - Navigate through external reference table
    # - Enable body creation option
    # - Select target datum point for node placement
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Trigger ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 ``5`` ``ext_ref_list``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Trigger ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 ``4`` ``ext_ref_list``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 ``4`` ``ext_ref_list``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Trigger ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 ``3`` ``ext_ref_list``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Trigger ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 ``2`` ``ext_ref_list``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Trigger ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 ```` ````;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``Odui_Dlg_00`` ``t1.body_add_chk_btn`` 1;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Trigger ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 ``5`` ``ext_ref_list``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 ``5`` ``ext_ref_list``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Trigger ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 ```` ````;\")

    # Select target datum point by ID for node positioning
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdMdlTreeSearch`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Open ``selspecdlg0`` ``SelOptionRadio``;~ Close ``selspecdlg0`` ``SelOptionRadio``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Point``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$item``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``EvaluateBtn``;~ Activate ``selspecdlg0`` ``ApplyBtn``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``CancelButton``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;\")
}


# End main mapkey
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``buffer_clean``;")

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
