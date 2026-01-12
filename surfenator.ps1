# ANCIENT AND POWERFUL MAGICS
# DO NOT MODIFY THIS SECTION
 
# Visual Studio Code
# https://code.visualstudio.com/
 
# VB API Documentation
# C:/PTC/Creo 6.0.4.0/Common Files/vbapi/vbapidoc/index.html
# https://wiki.blueorigin.com/x/mAHdB
 
# Set environment variables before connecting in
try {
    $proc = Get-Process | Where-Object {$_.ProcessName -eq "xtop"}
    if ($null -eq $proc) {
        throw "Running Creo process (xtop) not found"
    }
    $pc_path = $proc.Path -replace "xtop.exe", "pro_comm_msg.exe"
    # $Env:PRO_COMM_MSG_EXE = "C:\PTC\Creo 3.0\M120\Common Files\x86e_win64\obj\pro_comm_msg.exe"
    $Env:PRO_DIRECTORY = $proc.Path.TrimEnd("xtop.exe")
    $Env:PRO_COMM_MSG_EXE = $pc_path
}
catch {
    $_
    exit
}
 
# Check if VB API is registered
try {
    New-Object -ComObject pfcls.pfcAsyncConnection | Out-Null
}
catch {
    Write-Output "VB API not yet registered on this machine, performing first time setup..."
    $vb_path = $proc.Path -replace "Common Files(.*)$", "Parametric\bin\vb_api_register.bat"
    Start-Process -Wait -FilePath $vb_path
}
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
 
# $session.SetConfigOption("regen_failure_handling", "resolve_mode")
$model = $session.GetActiveModel()

#------------- Start Sandbox ---------------------
# Set script name
$name = "surfenator"

# Collect curves from User
Read-Host -Prompt "Select curves to be extruded, return to this window, and press enter"
$selection = ($session.CurrentSelectionBuffer()).Contents

# Extract Curve IDs from both possible levels
$curves=@()
foreach ($temp1 in $selection)
{
    try
    {
        foreach ($temp2 in $temp1.SelItem.ListElements())
        {
            $curves += $temp2.id
        }
    }
    catch
    {
        $curves += $temp1.SelItem.Id    
    }

}

# Get plane IDs from the user
Read-Host -Prompt "Select the midplane for the extrudes, return to this window, and press enter"
$selection = ($session.CurrentSelectionBuffer()).Contents
$midPlane = $selection[0].SelItem.Id
Read-Host -Prompt "Select the topplane for the extrudes, return to this window, and press enter"
$selection = ($session.CurrentSelectionBuffer()).Contents
$topPlane = $selection[0].SelItem.Id
Read-Host -Prompt "Select the botplane for the extrudes, return to this window, and press enter"
$selection = ($session.CurrentSelectionBuffer()).Contents
$botPlane = $selection[0].SelItem.Id

# Create a new StringBuilder object
$StringBuilder = New-Object System.Text.StringBuilder

# Set Visible Mapkeys to No (Speeds up execution and have seen issues if not set to No)
[void]$StringBuilder.AppendLine("visible_mapkeys no")

# Start main mapkey
[void]$StringBuilder.AppendLine("mapkey $name @MAPKEY_LABEL$name;\")

# Build each curve's section of the mapkey
foreach ($item in $curves)
{
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``buffer_clean``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdMdlTreeSearch``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Datum``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``LookByOptionMenu`` 1 ``Feature``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$midPlane``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``EvaluateBtn``;~ Activate ``selspecdlg0`` ``ApplyBtn``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``CancelButton``;~ Command ``ProCmdFtExtrude`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdSketProject``  1;~ Command ``ProCmdMdlTreeSearch`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``3D Curve``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$item``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``EvaluateBtn``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``ApplyBtn``;~ Activate ``selspecdlg0`` ``CancelButton``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``Odui_Dlg_02`` ``stdbtn_1``;~ Command ``ProCmdSketDone`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``UI Message Dialog`` ``ok``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``chkbn.extrev_2_options.0`` 1;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``extrev_2_options.0.0`` ``PH.depth1_om`` 1 ``toselected``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdMdlTreeSearch`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Datum``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``LookByOptionMenu`` 1 ``Feature``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$topPlane``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``EvaluateBtn``;~ Activate ``selspecdlg0`` ``ApplyBtn``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``CancelButton``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``extrev_2_options.0.0`` ``PH.depth2_om`` 1 ``toselected``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Expand ``main_dlg_cur`` ``PHTLeft.AssyTree`` ``T7 10 21``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Trigger ``extrev_2_options.0.0`` ``PH.depth2_sel_list`` ``0``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Focus ``extrev_2_options.0.0`` ``PH.depth2_sel_list``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``extrev_2_options.0.0`` ``PH.depth2_sel_list`` 0;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Trigger ``extrev_2_options.0.0`` ``PH.depth2_sel_list`` ``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdMdlTreeSearch`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$botPlane``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``EvaluateBtn``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``ApplyBtn``;~ Activate ``selspecdlg0`` ``CancelButton``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``dashInst0.Done``;\")
}

# End the mapkey
[void]$StringBuilder.AppendLine('mapkey(continued) ~ Activate `main_dlg_cur` `buffer_clean`;')

# Write the mapkey to its own .pro file
$username = $env:USERNAME
$StringBuilder.ToString() | Out-File "C:\Users\$username\working_folder\$name.pro"

# Import new .pro file and run the mapkey
$session.RunMacro("~ Close ``main_dlg_cur`` ``appl_casc``")
$session.RunMacro(" ~ Command ``ProCmdRibbonOptionsDlg``")
$session.RunMacro(" ~ Select ``ribbon_options_dialog`` ``PageSwitcherPageList`` 1 ``ConfigLayout``")
$session.RunMacro(" ~ Activate ``ribbon_options_dialog`` ``ConfigLayout.Open``")
$session.RunMacro(" ~ Update ``file_open`` ``Inputname`` ``$name.pro``")
$session.RunMacro(" ~ Activate ``file_open`` ``Inputname``")
$session.RunMacro(" ~ Activate ``ribbon_options_dialog`` ``OkPshBtn``")
$session.RunMacro(" ~ FocusIn ``UITools Msg Dialog Future`` ``no``")
$session.RunMacro(" ~ Activate ``UITools Msg Dialog Future`` ``no``")

$session.RunMacro("%$name")

# Disconnect session
$connection.Disconnect($null)
