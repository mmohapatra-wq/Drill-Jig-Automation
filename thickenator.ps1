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
$name = "thickenator"

# Collect current selection
$selection = ($session.CurrentSelectionBuffer()).Contents

# Prompt the user if selection was empty
if ($selection -eq $null) 
{
    Read-Host -Prompt "Select quilts to be thickened, return to this window, and press enter"
    $selection = ($session.CurrentSelectionBuffer()).Contents
}

# Collect quilt Ids from selection
$i=0
$quilts=@()
foreach ($item in $selection)
{
    $quilts += $selection[$i].SelItem.Id
    $i++
}

# Create a new StringBuilder object
$StringBuilder = New-Object System.Text.StringBuilder

# Set Visible Mapkeys to No (Speeds up execution and have seen issues if not set to No)
[void]$StringBuilder.AppendLine("visible_mapkeys no")

# Create thicken feature sub-mapkey
[void]$StringBuilder.AppendLine("mapkey sub$name @MAPKEY_LABELsub$name;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdFtThicken`` ;~ Enter ``main_dlg_cur`` ``dashInst0.Quit``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Exit ``main_dlg_cur`` ``dashInst0.Quit``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``maindashInst0.Flip``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``maindashInst0.Flip``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Input ``main_dlg_cur`` ``maindashInst0.Thickness`` ``.1``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``maindashInst0.Thickness``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``chkbn.body_page.0`` 1;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``body_page.0.0`` ``PH.bodyusechkbtnrepwdg`` 1;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``dashInst0.Done``;")

# Start main mapkey
[void]$StringBuilder.AppendLine("mapkey $name @MAPKEY_LABEL$name;\")

#Iterate through all quilts
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

# End the mapkey
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
