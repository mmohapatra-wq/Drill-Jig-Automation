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

$connection.Disconnect($null)
