<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "GAUGINATOR"

# ============================================
# HEADER
# ============================================
Write-Host ""
Write-Host "   ██████╗  █████╗ ██╗   ██╗ ██████╗ ██╗███╗   ██╗ █████╗ ████████╗ ██████╗ ██████╗ " -ForegroundColor White
Write-Host "  ██╔════╝ ██╔══██╗██║   ██║██╔════╝ ██║████╗  ██║██╔══██╗╚══██╔══╝██╔═══██╗██╔══██╗" -ForegroundColor White
Write-Host "  ██║  ███╗███████║██║   ██║██║  ███╗██║██╔██╗ ██║███████║   ██║   ██║   ██║██████╔╝" -ForegroundColor White
Write-Host "  ██║   ██║██╔══██║██║   ██║██║   ██║██║██║╚██╗██║██╔══██║   ██║   ██║   ██║██╔══██╗" -ForegroundColor White
Write-Host "  ╚██████╔╝██║  ██║╚██████╔╝╚██████╔╝██║██║ ╚████║██║  ██║   ██║   ╚██████╔╝██║  ██║" -ForegroundColor White
Write-Host "   ╚═════╝ ╚═╝  ╚═╝ ╚═════╝  ╚═════╝ ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝" -ForegroundColor White
Write-Host "  Dimension Extraction to CSV" -ForegroundColor White
Write-Host ""

# ============================================
# PREREQUISITES
# ============================================
Write-Host "  Prerequisites:" -ForegroundColor Green
Write-Host "    1. Part open in Creo with solid features" -ForegroundColor White
Write-Host ""

Write-Host "  Connecting to Creo..." -ForegroundColor White

# Set environment variables before connecting in
try {
    $proc = Get-Process -Name xtop -ErrorAction SilentlyContinue
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
Write-Host "  Connected: $($model.FileName)" -ForegroundColor Green

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
#------------- Start Sandbox ---------------------

#Add in pertinent ComObjects
$pfcModelItemType = New-Object -ComObject pfcls.pfcModelItemType
$pfcFeatures = New-Object -ComObject pfcls.pfcFeatureType #Features Type
$pfcModelItems = New-Object -ComObject pfcls.pfcmodelitems #model Items class


#Create output file
$filename = $model.FileName.TrimEnd(".prt") + "_dimensions"
# Note: Model filename will be included in the CSV data if needed

#collect list of solid features in model
$features = $model.ListFeaturesByType($FALSE, $pfcFeatures.FEATTYPE_PROTRUSION) #Lists all features of type protrusion (thickens are a protrusion)

#collect list of solid bodies in model
$bodies = $model.listitems($pfcModelItemType.ITEM_body)    #lists bodies within the model

#Initiate Array
$dimension_Array=@()

Write-Host "  Analyzing model..." -ForegroundColor White

#Iterate through and collect dimensions of solid $feobjects
foreach ($item in $bodies)
{
    #Find Child features of current body (this expects only one child feature)
    $childfeatures = $item.getfeatures()

    #Extract mass properties relative to default CSYS and then extract CG coordinates
    $MassProperty = $item.GetMassProperty($null)
    $CG = $MassProperty.GravityCenter

    if($null -ne $childfeatures) #Ensure there are in fact features tied to this body - if not, this variable will be null
    {
        #Collect value and dimension name
        foreach($childfeature in $childfeatures)
        {
            #Extract features related to the current body
            $dims = $childfeature.ListSubItems($pfcModelItemType.ITEM_DIMENSION)
            foreach($dim in $dims)
            {
                #Create headers for array
                $dimension = "" | Select-Object BodyID, Dim_Type, Dim_Name, Value, GravityCenterX, GravityCenterY, GravityCenterZ
                $dimension.BodyID = $item.Id
                if ($dim.DimType -eq 0) {$dimension.Dim_Type = "Linear"}
                elseif ($dim.DimType -eq 1) {$dimension.Dim_Type = "Radial"}
                elseif ($dim.DimType -eq 2) {$dimension.Dim_Type = "Diameter"}
                elseif ($dim.DimType -eq 3) {$dimension.Dim_Type = "Angular"}
                else {$dimension.Dim_Type = "null"}
                $dimension.Dim_Name = $dim.Symbol
                $dimension.Value = $dim.DimValue
                $dimension.GravityCenterX = $CG[0]
                $dimension.GravityCenterY = $CG[1]
                $dimension.GravityCenterZ = $CG[2]
                $dimension_Array += $dimension

            }
        }
    }
}

# Export data to CSV format
$dimension_array | Export-Csv -Path ".\$filename.csv" -NoTypeInformation
Write-Host "  Exported: $filename.csv" -ForegroundColor Green

} finally {
    try {
        if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null }
        if ($null -ne $origDynamicPreview)  { $session.SetConfigOption("dynamic_preview",  $origDynamicPreview)  | Out-Null }
    } catch {}
    $connection.Disconnect($null)
}

Write-Host ""
Write-Host "  Press any key to exit..." -ForegroundColor White
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
