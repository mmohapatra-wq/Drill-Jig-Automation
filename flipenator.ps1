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

# Use StringBuilder for efficient string concatenation when building large mapkeys
# [void] casting prevents console output of AppendLine return values
$StringBuilder = New-Object System.Text.StringBuilder

# Set Visible Mapkeys to No (speeds up execution and prevents display issues)
[void]$StringBuilder.AppendLine("visible_mapkeys no")

# Create flip sub-mapkey - reusable routine for flip operation
[void]$StringBuilder.AppendLine("mapkey sub$name @MAPKEY_LABELsub$name;~ Timer `` `` ``popupMenuRMBTimerCB``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Close ``rmb_popup`` ``PopupMenu``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdRedefine@PopupMenuGraphicWinStack`` ;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``maindashInst0.Flip``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``dashInst0.Done``;")

# Start main mapkey
[void]$StringBuilder.AppendLine("mapkey $name @MAPKEY_LABEL$name;\")

# Generate mapkey that iterates through each selected feature:
# 1. Search and select feature by ID
# 2. Call flip sub-routine
# 3. Clean selection buffer
foreach ($item in $featIds)
{
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``buffer_clean``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdMdlTreeSearch`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Open ``selspecdlg0`` ``SelOptionRadio``;~ Close ``selspecdlg0`` ``SelOptionRadio``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Feature``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$item``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``EvaluateBtn``;~ Activate ``selspecdlg0`` ``ApplyBtn``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``CancelButton``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) %sub$name;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``buffer_clean``;\")
}

# Re-select the original bodies for user reference
# Open selection dialog to select geometric bodies by ID
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdMdlTreeSearch`` ;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Open ``selspecdlg0`` ``SelOptionRadio``;~ Close ``selspecdlg0`` ``SelOptionRadio``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Geometric Body``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;\")

# Iterate through each body ID and add to selection
foreach ($item in $bodyIds)
{
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$item``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``EvaluateBtn``;~ Activate ``selspecdlg0`` ``ApplyBtn``;\")
}

# End main mapkey
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``CancelButton``;")

# Write the generated mapkey to user's working folder
$username = $env:USERNAME
$StringBuilder.ToString() | Out-File "C:\Users\$username\working_folder\$name.pro"

# Import generated mapkey file into Creo configuration:
# 1. Open Ribbon Options dialog
# 2. Navigate to Configuration page
# 3. Load the generated .pro file
# 4. Accept configuration changes
$session.RunMacro("~ Close ``main_dlg_cur`` ``appl_casc``")
$session.RunMacro(" ~ Command ``ProCmdRibbonOptionsDlg``")
$session.RunMacro(" ~ Select ``ribbon_options_dialog`` ``PageSwitcherPageList`` 1 ``ConfigLayout``")
$session.RunMacro(" ~ Activate ``ribbon_options_dialog`` ``ConfigLayout.Open``")
$session.RunMacro(" ~ Update ``file_open`` ``Inputname`` ``$name.pro``")
$session.RunMacro(" ~ Activate ``file_open`` ``Inputname``")
$session.RunMacro(" ~ Activate ``ribbon_options_dialog`` ``OkPshBtn``")
$session.RunMacro(" ~ FocusIn ``UITools Msg Dialog Future`` ``no``")
$session.RunMacro(" ~ Activate ``UITools Msg Dialog Future`` ``no``")

# Execute the generated mapkey
$session.RunMacro("%$name")

# Clean up VB API connection
$connection.Disconnect($null)