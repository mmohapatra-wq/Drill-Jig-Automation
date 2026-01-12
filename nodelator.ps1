# This location on the network drive
# \\blueorigin\fs\ProEAdmin\Creo_Developer\vbs\playMacro\
 
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
$name = "nodelator"

# Collect current selection
$node = ($session.CurrentSelectionBuffer()).Contents

# Prompt the user if selection was empty
if ($node -eq $null) 
{
    Write-Output "This tool requires a single existing node to be built manually"
    Write-Output "Ensure that extrude feature is set to create a new body"
    Read-Host -Prompt "Select feature of the example node, return to this window, and press enter"
    $node = ($session.CurrentSelectionBuffer()).Contents
}
$nodeID = $node[0].SelItem.Id

Read-Host -Prompt "Select the datum points for the nodes, return to this window, and press enter"
$points = ($session.CurrentSelectionBuffer()).Contents

# Collect feature and body ids of selected bodies
$pointIDs=@()
foreach ($item in $points)
{
    $pointIDs += $item.SelItem.Id
}

# Create a new StringBuilder object
$StringBuilder = New-Object System.Text.StringBuilder

# Set Visible Mapkeys to No (Speeds up execution and have seen issues if not set to No)
[void]$StringBuilder.AppendLine("visible_mapkeys no")

# Start $main mapkey
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

#Iterate through all points
foreach ($item in $pointIDs)
{
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``buffer_clean``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdEditPasteSpecial`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``paste_special`` ``makecopyiesPB`` 0;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``paste_special`` ``pastebyrefPB`` 1;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``paste_special`` ``okPB``;\")
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
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdMdlTreeSearch`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Open ``selspecdlg0`` ``SelOptionRadio``;~ Close ``selspecdlg0`` ``SelOptionRadio``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Point``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$item``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``EvaluateBtn``;~ Activate ``selspecdlg0`` ``ApplyBtn``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``CancelButton``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;\")
}


# end main mapkey
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``buffer_clean``;")

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