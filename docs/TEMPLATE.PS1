<#
.SYNOPSIS
    [TEMPLATE] Creo Mapkey Automation Script Template

.DESCRIPTION
    This is a template script for creating Creo Parametric automation tools using PowerShell,
    VB API, and dynamically generated mapkeys. Follow this template structure for consistent,
    reliable automation scripts.

    CUSTOMIZATION INSTRUCTIONS:
    1. Update .SYNOPSIS, .DESCRIPTION, .USAGE with specific automation details
    2. Replace [TEMPLATE_NAME] with your script name (e.g., "chamferator", "offsetor")
    3. Implement your specific selection logic in the SELECTION PROCESSING section
    4. Add your mapkey generation logic in the MAPKEY GENERATION section
    5. Customize parameters and validation as needed

    This template follows the 4-phase architecture documented in CREO_MAPKEY_AUTOMATION_GUIDE.md:
    - Phase 1: Environment Setup
    - Phase 2: Connection & Session
    - Phase 3: Selection & Processing
    - Phase 4: Mapkey Generation & Execution

.PREREQUISITES
    - Active Creo Parametric session
    - Target objects created in the model (features, quilts, points, etc.)
    - VB API COM components registered (auto-setup included)
    - User working_folder directory exists (C:\Users\[username]\working_folder\)

.USAGE
    1. Create target objects in your Creo model
    2. Run [script_name]_RUN.bat or execute this script directly
    3. Select objects when prompted
    4. Script applies automation to each selected object

    Modify parameters in the PARAMETERS section as needed for your automation.

.AUTHOR
    [Your Name] - [Organization]
    Based on NGS Orthogrid Automation Toolkit Template

.REFERENCES
    VB API Documentation: C:/PTC/Creo [version]/Common Files/vbapi/vbapidoc/index.html
    Automation Guide: CREO_MAPKEY_AUTOMATION_GUIDE.md in this repository
#>

#================================================================
# PHASE 1: ENVIRONMENT SETUP
#================================================================

try {
    Write-Output "Setting up Creo VB API environment..."

    # Find running Creo process (xtop.exe) to determine installation paths
    $proc = Get-Process | Where-Object {$_.ProcessName -eq "xtop"}
    if ($null -eq $proc) {
        throw "Running Creo process (xtop) not found. Please start Creo Parametric and try again."
    }

    # Set required environment variables for VB API communication
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

# Check if VB API COM components are registered
# First-time setup automatically runs registration batch file if needed
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

try {
    Write-Output "Connecting to Creo session..."

    # Establish connection to active Creo session
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
# PARAMETERS (CUSTOMIZE FOR YOUR AUTOMATION)
#================================================================

# Set script name for mapkey generation (customize this)
$name = "[TEMPLATE_NAME]"  # Example: "chamferator", "offsetor", "arrayenator"

# Define automation parameters (customize these for your specific operation)
# $thickness = "0.1"          # Example thickness parameter
# $distance = "5.0"           # Example distance parameter
# $iterations = 1             # Example iteration count
# $createNewBody = $true      # Example boolean parameter

Write-Output "Script: $name"

#================================================================
# PHASE 3: SELECTION & PROCESSING
#================================================================

Write-Output "Processing selection..."

# Get current selection from Creo's selection buffer
$selection = ($session.CurrentSelectionBuffer()).Contents

# Prompt user if no selection found
if ($selection -eq $null -or $selection.Count -eq 0) {
    Write-Output ""
    Write-Output "SELECTION REQUIRED:"
    Write-Output "Please select the objects you want to process in Creo,"
    Write-Output "then return to this window and press Enter."
    Read-Host -Prompt "Press Enter after making your selection in Creo"

    # Get selection after user prompt
    $selection = ($session.CurrentSelectionBuffer()).Contents

    # Validate selection was made
    if ($selection -eq $null -or $selection.Count -eq 0) {
        Write-Output "ERROR: No objects selected. Please select objects in Creo and try again."
        $connection.Disconnect($null)
        Read-Host "Press Enter to exit"
        exit
    }
}

Write-Output "Found $($selection.Count) selected object(s)"

# SELECTION PROCESSING - Customize this section for your object types
# This section extracts IDs from different types of selected objects
# Use the patterns that match your automation requirements

$targetIds = @()

foreach ($item in $selection) {
    try {
        # PATTERN 1: Simple objects (quilts, bodies, points, planes)
        # Use this for most single-object selections
        $directId = $item.SelItem.Id
        if ($directId -ne $null) {
            $targetIds += $directId
            Write-Output "  Found object ID: $directId"
            continue
        }

        # PATTERN 2: Feature-based objects (when selecting solid bodies that contain features)
        # Use this when you need the feature ID rather than the body ID
        try {
            $features = $item.SelItem.getFeatures()
            if ($features -ne $null) {
                foreach ($feature in $features) {
                    $featureId = $feature.Id
                    if ($featureId -ne $null) {
                        $targetIds += $featureId
                        Write-Output "  Found feature ID: $featureId"
                    }
                }
                continue
            }
        }
        catch {
            # getFeatures() not applicable to this object type
        }

        # PATTERN 3: Composite objects (curves with multiple elements)
        # Use this for composite curves or other multi-element objects
        try {
            $elements = $item.SelItem.ListElements()
            if ($elements -ne $null) {
                foreach ($element in $elements) {
                    $elementId = $element.Id
                    if ($elementId -ne $null) {
                        $targetIds += $elementId
                        Write-Output "  Found element ID: $elementId"
                    }
                }
                continue
            }
        }
        catch {
            # ListElements() not applicable to this object type
        }

        Write-Output "  WARNING: Could not extract ID from selected object"
    }
    catch {
        Write-Output "  ERROR: Failed to process selected object: $_"
    }
}

# Validate we have IDs to work with
if ($targetIds.Count -eq 0) {
    Write-Output "ERROR: No valid object IDs extracted from selection."
    Write-Output "Make sure you have selected the correct type of objects for this automation."
    $connection.Disconnect($null)
    Read-Host "Press Enter to exit"
    exit
}

Write-Output "Ready to process $($targetIds.Count) objects"

#================================================================
# PHASE 4: MAPKEY GENERATION & EXECUTION
#================================================================

Write-Output "Generating mapkeys..."

# Use StringBuilder for efficient string concatenation when building large mapkeys
# [void] casting prevents console output of AppendLine return values
$StringBuilder = New-Object System.Text.StringBuilder

# Set Visible Mapkeys option - Needs to be "no" for reliable mapkey execution
[void]$StringBuilder.AppendLine("visible_mapkeys no")

# CREATE SUB-MAPKEY (OPTIONAL)
# Sub-mapkeys are reusable routines that can be called multiple times
# Use this pattern if you have repeated operations to perform on each object

<#  EXAMPLE SUB-MAPKEY - Uncomment and customize as needed
[void]$StringBuilder.AppendLine("mapkey sub$name @MAPKEY_LABELsub$name;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdYourOperation`` ;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Input ``main_dlg_cur`` ``YourParameter`` ``$thickness``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``YourControl``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``dashInst0.Done``;")
#>

# START MAIN MAPKEY
[void]$StringBuilder.AppendLine("mapkey $name @MAPKEY_LABEL$name;\")

# MAPKEY GENERATION LOOP
# This loop generates mapkey commands for each target object
# Customize this section for your specific automation

foreach ($id in $targetIds) {

    # BUFFER MANAGEMENT - Always clean selection buffer before Find tool operations
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``buffer_clean``;\")

    # FIND TOOL PATTERN - Select object by ID
    # This is the most reliable way to select objects programmatically in mapkeys
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdMdlTreeSearch`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Open ``selspecdlg0`` ``SelOptionRadio``;~ Close ``selspecdlg0`` ``SelOptionRadio``;\")

    # CUSTOMIZE OBJECT TYPE - Change this based on what you're selecting
    # Common types: Feature, Quilt, Point, Curve, Geometric Body, Plane, Csys
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Feature``;\")  # <-- CUSTOMIZE THIS
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$id``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``EvaluateBtn``;~ Activate ``selspecdlg0`` ``ApplyBtn``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``CancelButton``;\")

    # YOUR AUTOMATION COMMANDS GO HERE
    # Replace this section with your specific automation mapkey commands

    <# EXAMPLE: Direct Feature Creation Approach
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdYourFeature`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Input ``main_dlg_cur`` ``YourParameter`` ``$thickness``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``YourButton``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``dashInst0.Done``;\")
    #>

    <# EXAMPLE: Sub-mapkey Call
    [void]$StringBuilder.AppendLine("mapkey(continued) %sub$name;\")
    #>

    <# EXAMPLE: Template Copying with Paste Special Approach
    # Copy template feature first (outside the loop)
    # Then for each target:
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdEditPasteSpecial`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``paste_special`` ``makecopyiesPB`` 0;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``paste_special`` ``pastebyrefPB`` 1;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``paste_special`` ``okPB``;\")
    # [Additional Paste Special reference table commands here]
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;\")
    #>

    # PLACEHOLDER - ADD YOUR MAPKEY COMMANDS HERE
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``buffer_clean``;\")
}

# END MAIN MAPKEY - Final line must NOT end with backslash
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``buffer_clean``;")

#================================================================
# MAPKEY EXECUTION
#================================================================
# IMPORTANT LIMITATION: Mapkeys provide NO error reporting back to PowerShell
# Scripts cannot detect whether mapkeys executed successfully or failed
# All "success" messages must be factual about what PowerShell accomplished,
# not claims about mapkey execution results within Creo

try {
    Write-Output "Writing mapkey file..."

    # Write the generated mapkey to user's working folder
    $username = $env:USERNAME
    $mapkeyPath = "C:\Users\$username\working_folder\$name.pro"

    $StringBuilder.ToString() | Out-File $mapkeyPath -Encoding ASCII
    Write-Output "Mapkey written to: $mapkeyPath"

    Write-Output "Importing mapkey into Creo..."

    # Import generated mapkey file into Creo configuration
    # This sequence loads the .pro file and makes the mapkey available for execution
    $session.RunMacro("~ Command ``ProCmdUtilMacros``")
    $session.RunMacro("~ Activate ``mapkey_main`` ``psh_import``")
    $session.RunMacro("~ Trail `` `` ``DLG_PREVIEW_POST`` ``file_open``")
    $session.RunMacro("~ Select ``file_open`` ``Ph_list.Filelist`` 1 ``$name.pro``")
    $session.RunMacro("~ Command ``ProFileSelPushOpen_Standard@context_dlg_open_cmd``")
    $session.RunMacro("~ Activate ``mapkey_main`` ``CloseButton``")
    $session.RunMacro("~ Activate ``unsaved_mapkeys`` ``yes``")

    Write-Output "Calling mapkey: %$name"

    # Execute the generated mapkey
    # NOTE: RunMacro() blocks until mapkey finishes, but does NOT indicate success/failure
    $session.RunMacro("%$name")

    Write-Output "Mapkey execution call completed"
}
catch {
    Write-Output "ERROR: Failed during mapkey file import or PowerShell execution: $_"
    Write-Output "Note: This does not detect mapkey execution failures within Creo"
}
finally {
    # Always clean up VB API connection
    if ($connection) {
        Write-Output "Cleaning up connection..."
        $connection.Disconnect($null)
    }
}

Write-Output ""
Write-Output "================================="
Write-Output "  $name EXECUTION COMPLETE"
Write-Output "================================="
Write-Output "Processed $($targetIds.Count) objects"
Write-Output "Mapkey execution call finished"
Write-Output "Please verify results in your Creo model"

# Optional: Keep console window open for user review
Read-Host "Press Enter to exit"

<#
================================================================
CUSTOMIZATION CHECKLIST FOR NEW SCRIPTS:
================================================================

1. HEADER CUSTOMIZATION:
   □ Update .SYNOPSIS with specific operation description
   □ Update .DESCRIPTION with detailed explanation
   □ Update .PREREQUISITES with specific requirements
   □ Update .USAGE with step-by-step instructions
   □ Update .AUTHOR with your information
   □ Replace [TEMPLATE_NAME] with your script name

2. PARAMETERS SECTION:
   □ Set $name to your script name (e.g., "chamferator")
   □ Define parameters relevant to your automation
   □ Set appropriate default values

3. SELECTION PROCESSING:
   □ Choose appropriate selection pattern(s) for your object types
   □ Update Write-Output messages for clarity
   □ Add validation specific to your requirements

4. MAPKEY GENERATION:
   □ Replace object type in Find tool (Feature, Quilt, Point, etc.)
   □ Add your specific automation commands
   □ Choose between direct creation, sub-mapkey, or paste special approaches
   □ Ensure proper mapkey syntax (double backticks, line continuations)

5. TESTING & VALIDATION:
   □ Test with small selections first
   □ Verify mapkey syntax in generated .pro file
   □ Test error conditions (empty selection, invalid objects)
   □ Validate results in Creo model
   □ Ensure script messaging is honest (no false success claims)

6. DOCUMENTATION:
   □ Update CREO_MAPKEY_AUTOMATION_GUIDE.md with your script details
   □ Create usage examples
   □ Document any specific prerequisites or limitations

================================================================
#>