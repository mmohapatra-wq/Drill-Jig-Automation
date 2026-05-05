<#
.SYNOPSIS
    Automates fastener and nut management in Creo Parametric

.DESCRIPTION
    Gripenator connects to an active Creo session and provides an interactive menu for:
    - Filter: Isolate valid HST fasteners from a selection
    - Change: Modify fastener diameter/grip and corresponding nut diameters
    - Grounding: Convert fastener coatings to GD (grounding) variant
    - Exit: Clean disconnect from Creo session

    Supports HST12, HST13, HST54, HST59 fasteners and HST1078 nuts.

.PREREQUISITES
    - Active Creo Parametric session with an open assembly
    - VB API COM components registered
    - User working_folder directory exists (C:\Users\[username]\working_folder\)

.AUTHOR
    Generated using Creo Mapkey Automation Template
    Part of the Creo Automation Toolkit

.REFERENCES
    VB API Documentation: C:/PTC/Creo [version]/Common Files/vbapi/vbapidoc/index.html
    Automation Guide: CREO_MAPKEY_AUTOMATION_GUIDE.md
#>

#================================================================
# PHASE 1: ENVIRONMENT SETUP
#================================================================

try {
    Write-Output "Setting up Creo VB API environment..."

    $proc = Get-Process | Where-Object {$_.ProcessName -eq "xtop"}
    if ($null -eq $proc) {
        throw "Running Creo process (xtop) not found. Please start Creo Parametric and try again."
    }

    $pc_path = $proc.Path -replace "xtop.exe", "pro_comm_msg.exe"
    $Env:PRO_DIRECTORY = $proc.Path.TrimEnd("xtop.exe")
    $Env:PRO_COMM_MSG_EXE = $pc_path

    Write-Output "Found Creo process: $($proc.ProcessName) (PID: $($proc.Id))"
}
catch {
    Write-Output "ERROR: Failed to set up environment: $_"
    Read-Host "Press Enter to exit"
    exit
}

try {
    New-Object -ComObject pfcls.pfcAsyncConnection | Out-Null
    Write-Output "VB API COM components are registered"
}
catch {
    Write-Output "VB API not yet registered on this machine, performing first time setup..."
    $vb_path = $proc.Path -replace "Common Files(.*)$", "Parametric\bin\vb_api_register.bat"
    if (Test-Path $vb_path) {
        Start-Process -Wait -FilePath $vb_path
        Write-Output "VB API registration completed"
    }
    else {
        Write-Output "ERROR: Could not find VB API registration file at: $vb_path"
        Read-Host "Press Enter to exit"
        exit
    }
}

#================================================================
# PHASE 2: CONNECTION & SESSION
#================================================================

Write-Output "Connecting to Creo session..."

try {
    $async = New-Object -ComObject pfcls.pfcAsyncConnection
    $connection = $async.Connect($null, $null, $null, $null)
    $session = $connection.Session
    $model = $session.GetActiveModel()

    Write-Output "Connected to model: $($model.FullName)"
}
catch {
    Write-Output "ERROR: Could not connect to Creo session: $_"
    Write-Output "Make sure Creo has an active model open and try again."
    Read-Host "Press Enter to exit"
    exit
}

#================================================================
# SETUP & VARIABLES
#================================================================

$Host.UI.RawUI.WindowTitle = "GRIPENATOR - Fastener Management Tool"
$scriptName = "gripenator"
$username = [Environment]::UserName
$workingFolder = "C:\Users\$username\working_folder"

$pfcModelItemType = New-Object -ComObject pfcls.pfcModelItemType

#================================================================
# HELPER FUNCTIONS
#================================================================

function Test-ValidFastener {
    param([string]$PartNumber)

    if ($PartNumber -match '^HST(12|13|54|59)((?:[A-Z]{2}|-))(\d{1,2})-(\d{1,2})$') {
        return @{
            Valid = $true
            Family = $matches[1]
            Coating = $matches[2]
            Diameter = $matches[3]
            Grip = $matches[4]
            Type = "Fastener"
        }
    }
    return @{Valid = $false}
}

function Test-ValidNut {
    param([string]$PartNumber)

    if ($PartNumber -match '^HST1078((?:[A-Z]{2}|-))(\d{1,2})$') {
        return @{
            Valid = $true
            Coating = $matches[1]
            Diameter = $matches[2]
            Type = "Nut"
        }
    }
    return @{Valid = $false}
}

function Get-FastenerSelection {
    # Get current selection from buffer
    $selection = ($session.CurrentSelectionBuffer()).Contents

    if ($null -eq $selection -or $selection.Count -eq 0) {
        Write-Host ""
        Write-Host "SELECTION REQUIRED:" -ForegroundColor Yellow
        Write-Host "Please select fasteners/nuts in Creo, then return here and press Enter."
        Read-Host "Press Enter after making your selection in Creo" | Out-Null
        $selection = ($session.CurrentSelectionBuffer()).Contents
    }

    if ($null -eq $selection -or $selection.Count -eq 0) {
        Write-Host "ERROR: No parts selected. Please select fasteners/nuts in Creo and try again." -ForegroundColor Red
        return $null
    }

    $fasteners = @()
    $nuts = @()

    foreach ($item in $selection) {
        try {
            # Extract component ID from Path.ComponentIds
            $componentIds = $item.Path.ComponentIds
            if ($null -eq $componentIds -or $componentIds.Count -eq 0) {
                continue
            }
            $id = $componentIds[0]

            # Extract part number from SelectionString
            # Format: assembly.asm:partnumber<template>.prt(#id)
            $selectionString = $item.SelectionString
            if ($null -eq $selectionString) {
                continue
            }

            # Extract part number between ':' and '<'
            if ($selectionString -match ':([^<]+)<') {
                $partNumber = $matches[1]
            } else {
                continue
            }

            # Standardize to uppercase
            $partNumber = $partNumber.ToUpper()

            $fastenerTest = Test-ValidFastener -PartNumber $partNumber
            if ($fastenerTest.Valid) {
                $fasteners += [PSCustomObject]@{
                    ID = $id
                    PartNumber = $partNumber
                    Family = $fastenerTest.Family
                    Coating = $fastenerTest.Coating
                    Diameter = $fastenerTest.Diameter
                    Grip = $fastenerTest.Grip
                }
                continue
            }

            $nutTest = Test-ValidNut -PartNumber $partNumber
            if ($nutTest.Valid) {
                $nuts += [PSCustomObject]@{
                    ID = $id
                    PartNumber = $partNumber
                    Coating = $nutTest.Coating
                    Diameter = $nutTest.Diameter
                }
            }
        }
        catch {
            # Skip items that can't be processed
        }
    }

    return @{
        Fasteners = $fasteners
        Nuts = $nuts
    }
}

function Write-SelectionSummary {
    param($Selection)

    if ($null -ne $Selection) {
        $fCount = @($Selection.Fasteners).Count
        $nCount = @($Selection.Nuts).Count
        Write-Host "Selection Summary: $fCount fastener(s), $nCount nut(s)" -ForegroundColor Cyan
    }
}

function New-FindToolMapkey {
    param(
        [array]$ComponentIds,
        [string]$MapkeyName
    )

    $stringBuilder = New-Object System.Text.StringBuilder

    [void]$stringBuilder.AppendLine("visible_mapkeys no")
    [void]$stringBuilder.AppendLine("mapkey $MapkeyName @MAPKEY_LABEL$MapkeyName;\")

    # Clear selection buffer
    [void]$stringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``buffer_clean``;\")

    # Open Find tool once
    [void]$stringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdMdlTreeSearch`` ;\")

    # Disable GUI highlighting during batch search for performance
    [void]$stringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Component``;\")
    [void]$stringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``CascadeButton1``;\")
    [void]$stringBuilder.AppendLine("mapkey(continued) ~ Close ``selspecdlg0`` ``CascadeButton1``;\")
    [void]$stringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``HiliteScreenCheckBtn`` 0;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;\")
    

    # For each component ID, search and apply without closing the dialog
    $idCount = @($ComponentIds).Count
    $idIndex = 0
    foreach ($id in $ComponentIds) {
        $idIndex++
        $isLast = ($idIndex -eq $idCount)

        [void]$stringBuilder.AppendLine("mapkey(continued) ~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$id``;\")
        [void]$stringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``EvaluateBtn``;\")

        if ($isLast) {
            [void]$stringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``ApplyBtn``;~ Activate ``selspecdlg0`` ``CancelButton``;")
        }
        else {
            [void]$stringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``ApplyBtn``;\")
        }
    }

    return $stringBuilder.ToString()
}

function New-ReplaceMapkey {
    param(
        [array]$ComponentIds,
        [string]$NewPartNumber,
        [string]$MapkeyName
    )

    $stringBuilder = New-Object System.Text.StringBuilder

    [void]$stringBuilder.AppendLine("visible_mapkeys no")
    [void]$stringBuilder.AppendLine("mapkey $MapkeyName @MAPKEY_LABEL$MapkeyName;\")

    # Clear selection buffer
    [void]$stringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``buffer_clean``;\")

    # Open Find tool once
    [void]$stringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdMdlTreeSearch`` ;\")

    # Disable GUI highlighting during batch search for performance
    [void]$stringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``CascadeButton1``;\")
    [void]$stringBuilder.AppendLine("mapkey(continued) ~ Close ``selspecdlg0`` ``CascadeButton1``;\")
    [void]$stringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``HiliteScreenCheckBtn`` 0;\")

    # Select all component IDs in batch
    $idCount = @($ComponentIds).Count
    $idIndex = 0
    foreach ($id in $ComponentIds) {
        $idIndex++
        $isLastId = ($idIndex -eq $idCount)

        [void]$stringBuilder.AppendLine("mapkey(continued) ~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` \")
        [void]$stringBuilder.AppendLine("mapkey(continued) ``$id``;~ Activate ``selspecdlg0`` ``EvaluateBtn``;\")

        if ($isLastId) {
            [void]$stringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``ApplyBtn``;~ Activate ``selspecdlg0`` ``CancelButton``;\")
        }
        else {
            [void]$stringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``ApplyBtn``;\")
        }
    }

    # Execute Replace tool with new part number
    [void]$stringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdReplComp@PopupMenuGraphicWinStack`` ;\")
    [void]$stringBuilder.AppendLine("mapkey(continued) ~ Trigger ``gen_repl_dlg`` ``Lst_NewComp`` ``0``;\")
    [void]$stringBuilder.AppendLine("mapkey(continued) ~ Trigger ``gen_repl_dlg`` ``Lst_NewComp`` ``;\")
    [void]$stringBuilder.AppendLine("mapkey(continued) ~ Activate ``gen_repl_dlg`` ``PB_NewComp``;\")
    [void]$stringBuilder.AppendLine("mapkey(continued) ~ Select ``mdlbrowser`` ``MBar`` 1 ``TreeMenu``;~ Close ``mdlbrowser`` ``MBar``;\")
    [void]$stringBuilder.AppendLine("mapkey(continued) ~ Activate ``mdlbrowser`` ``Find``;~ Open ``brws_query`` ``ClassOptMenu``;\")
    [void]$stringBuilder.AppendLine("mapkey(continued) ~ Close ``brws_query`` ``ClassOptMenu``;\")
    [void]$stringBuilder.AppendLine("mapkey(continued) ~ Select ``brws_query`` ``ClassOptMenu`` 1 ``Model Name``;\")
    [void]$stringBuilder.AppendLine("mapkey(continued) ~ Input ``brws_query`` ``ValueInput`` ``$NewPartNumber``;\")
    [void]$stringBuilder.AppendLine("mapkey(continued) ~ Update ``brws_query`` ``ValueInput`` ``$NewPartNumber``;\")
    [void]$stringBuilder.AppendLine("mapkey(continued) ~ Activate ``brws_query`` ``AddBtn``;~ Activate ``brws_query`` ``FindNextBtn``;\")
    [void]$stringBuilder.AppendLine("mapkey(continued) ~ Activate ``brws_query`` ``SelectBtn``;~ Activate ``brws_query`` ``CloseBtn``;\")
    [void]$stringBuilder.AppendLine("mapkey(continued) ~ Activate ``mdlbrowser`` ``OK``;~ Activate ``gen_repl_dlg`` ``DoneBtn``;")

    return $stringBuilder.ToString()
}

function Execute-Mapkey {
    param(
        [string]$MapkeyContent,
        [string]$MapkeyName
    )

    try {
        $mapkeyFile = "$workingFolder\${scriptName}_${MapkeyName}.pro"
        $MapkeyContent | Out-File -FilePath $mapkeyFile -Encoding ASCII

        Write-Host "Importing mapkey: $MapkeyName from $mapkeyFile" -ForegroundColor Green

        # Import generated mapkey file into Creo configuration
        # Use individual RunMacro calls for reliability
        $session.RunMacro("~ Close ``main_dlg_cur`` ``appl_casc``")
        $session.RunMacro(" ~ Command ``ProCmdRibbonOptionsDlg``")
        $session.RunMacro(" ~ Select ``ribbon_options_dialog`` ``PageSwitcherPageList`` 1 ``ConfigLayout``")
        $session.RunMacro(" ~ Activate ``ribbon_options_dialog`` ``ConfigLayout.Open``")
        $session.RunMacro(" ~ Update ``file_open`` ``Inputname`` ``${scriptName}_${MapkeyName}.pro``")
        $session.RunMacro(" ~ Activate ``file_open`` ``Inputname``")
        $session.RunMacro(" ~ Activate ``ribbon_options_dialog`` ``OkPshBtn``")
        $session.RunMacro(" ~ FocusIn ``UITools Msg Dialog Future`` ``no``")
        $session.RunMacro(" ~ Activate ``UITools Msg Dialog Future`` ``no``")

        Write-Host "Executing mapkey: %$MapkeyName" -ForegroundColor Green

        # Execute the generated mapkey
        $session.RunMacro("%$MapkeyName")

        Write-Host "Mapkey execution call completed" -ForegroundColor Green

        return $true
    }
    catch {
        Write-Host "ERROR executing mapkey: $_" -ForegroundColor Red
        return $false
    }
}

#================================================================
# FILTER FUNCTION
#================================================================

function Invoke-FilterFunction {
    Write-Host "`n=== FILTER FUNCTION ===" -ForegroundColor Cyan

    $selection = Get-FastenerSelection
    if ($null -eq $selection) {
        return
    }

    $fastenerCount = @($selection.Fasteners).Count

    if ($fastenerCount -eq 0) {
        Write-Host "ERROR: No valid fasteners found in selection." -ForegroundColor Red
        return
    }

    Write-Host "Found $fastenerCount valid fastener(s). Filtering selection..." -ForegroundColor Green

    $fastenerIds = $selection.Fasteners | ForEach-Object { $_.ID }
    $mapkey = New-FindToolMapkey -ComponentIds $fastenerIds -MapkeyName "filter"

    if (Execute-Mapkey -MapkeyContent $mapkey -MapkeyName "filter") {
        Write-Host "Filtered selection to $fastenerCount fastener(s)" -ForegroundColor Green
    }
}

#================================================================
# CHANGE FUNCTION
#================================================================

function Invoke-ChangeFunction {
    Write-Host "`n=== CHANGE FUNCTION ===" -ForegroundColor Cyan

    $selection = Get-FastenerSelection
    if ($null -eq $selection) {
        return
    }

    $fastenerCount = @($selection.Fasteners).Count
    $nutCount = @($selection.Nuts).Count

    if ($fastenerCount -eq 0) {
        Write-Host "ERROR: No valid fasteners found in selection." -ForegroundColor Red
        return
    }

    Write-Host "Found $fastenerCount fastener(s) and $nutCount nut(s)." -ForegroundColor Green

    # Validate all fasteners are same family
    $families = @($selection.Fasteners | ForEach-Object { $_.Family } | Sort-Object -Unique)
    if ($families.Count -gt 1) {
        Write-Host "ERROR: Selection contains mixed fastener families: $($families -join ', ')" -ForegroundColor Red
        Write-Host "Please reselect fasteners with the same family code (all HST12, all HST13, etc.)" -ForegroundColor Yellow
        return
    }

    # Get new diameter and grip codes
    $newDiameter = Read-Host "Enter new Diameter code. Leave blank for no change"
    $newGrip = Read-Host "Enter new Grip code. Leave blank for no change"

    if ([string]::IsNullOrWhiteSpace($newDiameter) -and [string]::IsNullOrWhiteSpace($newGrip)) {
        Write-Host "No changes specified." -ForegroundColor Yellow
        return
    }

    # Process fasteners
    if ($fastenerCount -gt 0) {
        $family = $selection.Fasteners[0].Family

        if (-not [string]::IsNullOrWhiteSpace($newDiameter)) {
            $newDiameter = $newDiameter.Trim()
        } else {
            $newDiameter = $selection.Fasteners[0].Diameter
        }

        if (-not [string]::IsNullOrWhiteSpace($newGrip)) {
            $newGrip = $newGrip.Trim()
        } else {
            $newGrip = $selection.Fasteners[0].Grip
        }

        # Group fasteners by coating to handle multiple coatings in one selection
        $fastenersByCoating = $selection.Fasteners | Group-Object -Property Coating

        foreach ($coatingGroup in $fastenersByCoating) {
            $coating = $coatingGroup.Name
            $fastenerIds = $coatingGroup.Group | ForEach-Object { $_.ID }
            $newFastenerPartNumber = "HST$family$coating$newDiameter-$newGrip"

            Write-Host "Changing $($fastenerIds.Count) fastener(s) with $coating coating to: $newFastenerPartNumber" -ForegroundColor Green

            # Create safe mapkey name (replace "-" with underscore for valid identifier)
            $safeCoatingName = $coating -replace '-', 'null'
            $mapkeyName = "change_fastener_$safeCoatingName"

            $mapkey = New-ReplaceMapkey -ComponentIds $fastenerIds -NewPartNumber $newFastenerPartNumber -MapkeyName $mapkeyName

            if (Execute-Mapkey -MapkeyContent $mapkey -MapkeyName $mapkeyName) {
                Write-Host "Changed $($fastenerIds.Count) fastener(s) with $coating coating" -ForegroundColor Green
            }
        }
    }

    # Process nuts if present and diameter was changed
    if ($nutCount -gt 0 -and -not [string]::IsNullOrWhiteSpace($newDiameter)) {
        $newDiameter = $newDiameter.Trim()

        # Group nuts by coating
        $nutsByCoating = $selection.Nuts | Group-Object -Property Coating

        foreach ($group in $nutsByCoating) {
            Write-Host "  Group Name='$($group.Name)' Count=$($group.Count)" -ForegroundColor Cyan
        }

        foreach ($coatingGroup in $nutsByCoating) {
            $coating = $coatingGroup.Name

            # Filter out nuts that already have the target diameter
            $nutsToChange = $coatingGroup.Group | Where-Object { $_.Diameter -ne $newDiameter }

            if ($nutsToChange.Count -eq 0) {
                Write-Host "Nuts with $coating coating already have diameter $newDiameter, skipping." -ForegroundColor Yellow
                continue
            }

            $nutIds = $nutsToChange | ForEach-Object { $_.ID }
            $newNutPartNumber = "HST1078" + $coating + $newDiameter

            Write-Host "Changing $($nutIds.Count) nut(s) with $coating coating to: $newNutPartNumber" -ForegroundColor Green

            # Create safe mapkey name (replace "-" with underscore for valid identifier)
            $safeCoatingName = $coating -replace '-', 'null'
            $mapkeyName = "change_nuts_$safeCoatingName"

            $mapkey = New-ReplaceMapkey -ComponentIds $nutIds -NewPartNumber $newNutPartNumber -MapkeyName $mapkeyName

            if (Execute-Mapkey -MapkeyContent $mapkey -MapkeyName $mapkeyName) {
                Write-Host "Changed $($nutIds.Count) nut(s) with $coating coating" -ForegroundColor Green
            }
        }
    }
}

#================================================================
# GROUNDING FUNCTION
#================================================================

function Invoke-GroundingFunction {
    Write-Host "`n=== GROUNDING FUNCTION ===" -ForegroundColor Cyan

    $selection = Get-FastenerSelection
    if ($null -eq $selection) {
        return
    }

    $fastenerCount = @($selection.Fasteners).Count

    if ($fastenerCount -eq 0) {
        Write-Host "ERROR: No valid fasteners found in selection." -ForegroundColor Red
        return
    }

    Write-Host "Found $fastenerCount fastener(s). Converting to GD coating..." -ForegroundColor Green

    # Group fasteners by unique family-diameter-grip combinations
    $combinations = $selection.Fasteners | Group-Object { "$($_.Family)-$($_.Diameter)-$($_.Grip)" }

    foreach ($combo in $combinations) {
        $comboKey = $combo.Name -split '-'
        $family = $comboKey[0]
        $diameter = $comboKey[1]
        $grip = $comboKey[2]
        $newPartNumber = "HST$family" + "GD" + "$diameter-$grip"
        $comboIds = $combo.Group | ForEach-Object { $_.ID }

        Write-Host "Grounding $($comboIds.Count) fastener(s): $newPartNumber" -ForegroundColor Green

        $mapkeyName = "ground_${family}_${diameter}_${grip}"
        $mapkey = New-ReplaceMapkey -ComponentIds $comboIds -NewPartNumber $newPartNumber -MapkeyName $mapkeyName

        if (Execute-Mapkey -MapkeyContent $mapkey -MapkeyName $mapkeyName) {
            Write-Host "Grounded $($comboIds.Count) fastener(s)" -ForegroundColor Green
        }
    }
}

#================================================================
# MAIN MENU LOOP
#================================================================


Write-Host ("=" * 50) -ForegroundColor Green
Write-Host "GRIPENATOR - Fastener Management Tool" -ForegroundColor Green
Write-Host ("=" * 50) -ForegroundColor Green

try {
    do {
        Write-Host "`n" -ForegroundColor Cyan
        Write-Host "F - Filter valid fasteners from selection" -ForegroundColor Yellow
        Write-Host "C - Change fastener diameter/grip" -ForegroundColor Yellow
        Write-Host "G - Convert to Grounding (GD coating)" -ForegroundColor Yellow
        Write-Host "E - Exit" -ForegroundColor Yellow

        $choice = Read-Host "Enter your choice (F/C/G/E)"

        switch ($choice.ToUpper()) {
            'F' { Invoke-FilterFunction }
            'C' { Invoke-ChangeFunction }
            'G' { Invoke-GroundingFunction }
            'E' {
                Write-Host "`nDisconnecting from Creo..." -ForegroundColor Yellow
                break
            }
            default {
                Write-Host "Invalid choice. Please enter F, C, G, or E." -ForegroundColor Red
            }
        }
    } while ($choice.ToUpper() -ne 'E')
}
finally {
    try {
        if ($null -ne $connection) {
            $connection.Disconnect($null)
            Write-Host "Disconnected from Creo session." -ForegroundColor Green
            Write-Host "Remember... DON'T REACT" -ForegroundColor Blue

        }
    }
    catch {
        Write-Host "Warning: Could not properly disconnect: $_" -ForegroundColor Yellow
    }
}
