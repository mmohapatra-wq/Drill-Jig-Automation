
$Host.UI.RawUI.WindowTitle = "THICKENATOR"
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
        Start-Sleep -Milliseconds 50
    }
    Write-Host "  (warning: feature creation timed out)" -ForegroundColor Yellow
}

# ============================================
# HEADER
# ============================================
Write-Host ""
Write-Host "  ████████╗██╗  ██╗██╗ ██████╗██╗  ██╗███████╗███╗   ██╗ █████╗ ████████╗ ██████╗ ██████╗ " -ForegroundColor White
Write-Host "  ╚══██╔══╝██║  ██║██║██╔════╝██║ ██╔╝██╔════╝████╗  ██║██╔══██╗╚══██╔══╝██╔═══██╗██╔══██╗" -ForegroundColor White
Write-Host "     ██║   ███████║██║██║     █████╔╝ █████╗  ██╔██╗ ██║███████║   ██║   ██║   ██║██████╔╝" -ForegroundColor White
Write-Host "     ██║   ██╔══██║██║██║     ██╔═██╗ ██╔══╝  ██║╚██╗██║██╔══██║   ██║   ██║   ██║██╔══██╗" -ForegroundColor White
Write-Host "     ██║   ██║  ██║██║╚██████╗██║  ██╗███████╗██║ ╚████║██║  ██║   ██║   ╚██████╔╝██║  ██║" -ForegroundColor White
Write-Host "     ╚═╝   ╚═╝  ╚═╝╚═╝ ╚═════╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═══╝╚═╝  ╚═╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝" -ForegroundColor White
Write-Host "  Surface Quilt Thickening" -ForegroundColor White
Write-Host ""

# ============================================
# PREREQUISITES
# ============================================
Write-Host "  Prerequisites:" -ForegroundColor Green
Write-Host "    1. Part open in Creo with surface quilts" -ForegroundColor White
Write-Host "    2. Do not interact with Creo during processing" -ForegroundColor White
Write-Host ""

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
    Write-Host "  Select quilts to thicken in Creo," -ForegroundColor White
    Write-Host "  then press ENTER here." -ForegroundColor White
    Read-Host
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

# Define thicken sub-macro with thickness parameter
$thickenSubMacro = "~ Command ``ProCmdFtThicken``;" +
    "~ Enter ``main_dlg_cur`` ``dashInst0.Quit``;" +
    "~ Exit ``main_dlg_cur`` ``dashInst0.Quit``;" +
    "~ Activate ``main_dlg_cur`` ``maindashInst0.Flip``;" +
    "~ Activate ``main_dlg_cur`` ``maindashInst0.Flip``;" +
    "~ Input ``main_dlg_cur`` ``maindashInst0.Thickness`` ``$thickness``;" +
    "~ Activate ``main_dlg_cur`` ``maindashInst0.Thickness``;" +
    "~ Activate ``main_dlg_cur`` ``chkbn.body_page.0`` 1;" +
    "~ Activate ``body_page.0.0`` ``PH.bodyusechkbtnrepwdg`` 1;" +
    "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;" +
    "~ Activate ``main_dlg_cur`` ``buffer_clean``;"


# Loop through quilts with progress reporting
$totalQuilts = $quilts.Count
$quiltIndex = 0
foreach ($item in $quilts)
{
    $quiltIndex++
    $pct = [Math]::Floor(($quiltIndex / $totalQuilts) * 100)
    Show-Progress $pct "Quilt $quiltIndex/$totalQuilts"

    try {
        $selectQuilt = "~ Activate ``main_dlg_cur`` ``buffer_clean``;" +
            "~ Command ``ProCmdMdlTreeSearch``;" +
            "~ Open ``selspecdlg0`` ``SelOptionRadio``;" +
            "~ Close ``selspecdlg0`` ``SelOptionRadio``;" +
            "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Quilt``;" +
            "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
            "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$item``;" +
            "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
            "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
            "~ Activate ``selspecdlg0`` ``CancelButton``;"

        $stamp = $model.VersionStamp
        $session.RunMacro($selectQuilt + $thickenSubMacro)
        Wait-ModelModified -Model $model -PreviousStamp $stamp
    } catch {}
}
Show-Progress 100 "Thicken complete"

} finally {
    try {
        if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null }
        if ($null -ne $origDynamicPreview)  { $session.SetConfigOption("dynamic_preview",  $origDynamicPreview)  | Out-Null }
    } catch {}
    $connection.Disconnect($null)
}
