<#
.SYNOPSIS
    Automates thickening operations for selected surface quilts in Creo Parametric

.DESCRIPTION
    This script connects to an active Creo session, collects user-selected surface quilts,
    generates custom mapkeys, and executes them to apply consistent thickness to each quilt.
    Part of the NGS Orthogrid Automation toolkit.

    The script uses the Creo VB API to gather selections, then generates mapkeys that:
    1. Search and select each quilt by ID
    2. Apply Creo's Thicken feature with standard parameters
    3. Create solid bodies from surface quilts

.PREREQUISITES
    - Active Creo Parametric session with surface quilts
    - Surface quilts created (collections of connected surfaces)
    - VB API COM components registered
    - User working_folder directory exists (C:\Users\[username]\working_folder\)

.USAGE
    1. Create surface quilts in your model
    2. Run thickenator_RUN.bat or execute this script directly
    3. Select surface quilts when prompted

    The script applies standard thickness of 0.1 units - modify $thickness variable as needed.

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

#------------- THICKENATOR AUTOMATION LOGIC ---------------------

# Set script name for mapkey generation
$name = "thickenator"

# Standard thickness for orthogrid structures (modify as needed for different thicknesses)
$thickness = "0.1"

# Collect current selection from Creo's selection buffer
$selection = ($session.CurrentSelectionBuffer()).Contents

# Prompt the user if selection was empty
if ($selection -eq $null)
{
    Read-Host -Prompt "Select quilts to be thickened, return to this window, and press enter"
    $selection = ($session.CurrentSelectionBuffer()).Contents
}

# Extract quilt IDs from selection
$i=0
$quilts=@()
foreach ($item in $selection)
{
    $quilts += $selection[$i].SelItem.Id
    $i++
}

# Use StringBuilder for efficient string concatenation when building large mapkeys
# [void] casting prevents console output of AppendLine return values
$StringBuilder = New-Object System.Text.StringBuilder

# Set Visible Mapkeys to No (speeds up execution and prevents display issues)
[void]$StringBuilder.AppendLine("visible_mapkeys no")

# Create thicken feature sub-mapkey - reusable routine for thicken operation
[void]$StringBuilder.AppendLine("mapkey sub$name @MAPKEY_LABELsub$name;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdFtThicken`` ;~ Enter ``main_dlg_cur`` ``dashInst0.Quit``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Exit ``main_dlg_cur`` ``dashInst0.Quit``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``maindashInst0.Flip``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``maindashInst0.Flip``;\")
# Apply standard thickness (modify $thickness variable at top of script as needed)
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Input ``main_dlg_cur`` ``maindashInst0.Thickness`` ``$thickness``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``maindashInst0.Thickness``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``chkbn.body_page.0`` 1;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``body_page.0.0`` ``PH.bodyusechkbtnrepwdg`` 1;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``dashInst0.Done``;")

# Start main mapkey
[void]$StringBuilder.AppendLine("mapkey $name @MAPKEY_LABEL$name;\")

# Generate mapkey that iterates through each selected quilt:
# 1. Search and select quilt by ID
# 2. Call thicken sub-routine
# 3. Clean selection buffer
foreach ($item in $quilts)
{
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``buffer_clean``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdMdlTreeSearch`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Open ``selspecdlg0`` ``SelOptionRadio``;~ Close ``selspecdlg0`` ``SelOptionRadio``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Quilt``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$item``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``EvaluateBtn``;~ Activate ``selspecdlg0`` ``ApplyBtn``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``CancelButton``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) %sub$name;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``buffer_clean``;\")
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
