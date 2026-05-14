# NGS Orthogrid Automation

A collection of PowerShell scripts that leverage the Creo Parametric VB API to automate complex modeling operations through dynamic mapkey generation. These tools enable advanced Creo automation without requiring additional software licenses beyond standard Creo Parametric.

## Overview

This repository contains five specialized automation tools designed for orthogrid and structural modeling workflows in Creo Parametric. Most tools use the Creo VB API COM interface to gather user selections and model data, then generate and execute custom mapkeys "on the fly" to perform complex operations that would be tedious to do manually. One tool focuses on data extraction and analysis.

## Tools

### 1. Flipenator ([flipenator.ps1](flipenator.ps1))
**Purpose:** Batch flip/mirror operations for selected geometric bodies

- Prompts user to select multiple solid bodies in Creo
- Generates mapkey that iterates through each selected body
- Applies flip operation to each body using Creo's built-in Flip feature
- Useful for creating mirrored components in orthogrid structures

**Usage:** Run [flipenator_RUN.bat](flipenator_RUN.bat) and select bodies to flip in Creo

### 2. Nodelator ([nodelator.ps1](nodelator.ps1))
**Purpose:** Duplicate node features at multiple datum point locations

- Requires pre-existing "example node" feature (typically an extruded solid body)
- User selects the example feature, then multiple datum points
- Generates mapkey that copies the node feature to each datum point location
- Uses Creo's Paste Special functionality with by-reference assembly operations
- Essential for creating node patterns in orthogrid structures

**Usage:** Create an example node feature, run [nodelator_RUN.bat](nodelator_RUN.bat), select the example and target datum points

### 3. Surfenator ([surfenator.ps1](surfenator.ps1))
**Purpose:** Create surfaces by extruding 3D curves between datum planes

- Collects user-selected 3D curves and three datum planes (midplane, top plane, bottom plane)
- For each curve: projects it onto the midplane, creates extrude feature extending from top to bottom plane
- Handles plane-based depth constraints and offset calculations
- Generates the surface structure between orthogrid planes

**Usage:** Create 3D curves and datum planes, run [surfenator_RUN.bat](surfenator_RUN.bat), select curves and planes as prompted

### 4. Thickenator ([thickenator.ps1](thickenator.ps1))
**Purpose:** Apply consistent thickness to multiple surface quilts

- Prompts user to select multiple quilt surfaces
- Generates mapkey with reusable sub-routine for thicken operations
- Applies consistent thickness (0.1 units) to each selected quilt
- Includes options for thickness direction and body creation
- Converts surface quilts to solid bodies for structural analysis

**Usage:** Create surface quilts, run [thickenator_RUN.bat](thickenator_RUN.bat), select quilts to thicken

### 5. Gauginator ([gauginator.ps1](gauginator.ps1))
**Purpose:** Extract geometric dimensions and properties from all solid bodies in the active model

- Analyzes all solid bodies in the current Creo model automatically (no user selection required)
- Extracts dimensional information from each body's feature parameters
- Captures mass properties including center of gravity coordinates
- Exports  data to CSV format for analysis and reporting

**Key Data Extracted:**
- Body ID for model reference
- Dimension types (Linear, Radial, Diameter, Angular)
- Dimension names and values from feature parameters
- Center of gravity coordinates (X, Y, Z) relative to default coordinate system

**Usage:** Run [gauginator_RUN.bat](gauginator_RUN.bat) with your model open - no selections needed. CSV file will be created in the script directory with filename based on the active model name.

**Output:** `[ModelName]_dimensions.csv` containing tabular data suitable for spreadsheet analysis

### 6. Gripenator ([gripenator.ps1](gripenator.ps1))
**Purpose:** Streamlines management of hi-lite fasteners
- Filter: Isolate valid HST fasteners (HST12, HST13, HST54, HST59) from a mixed selection
- Change: Modify fastener diameter and/or grip length, with automatic nut diameter updates
- Grounding: Convert fastener coatings to GD (grounding) variant across multiple fastener families

**SUPPORTED PART NUMBERS:**
Fasteners: HST{12|13|54|59}
Collars: HST1078

**CAUTION:** Always exit using the "E" command. Closing the terminal directly will leave orphaned Creo COM connections and interfer with future sessions.


## Requirements

### Software Prerequisites
- **Creo Parametric** (any recent version with VB API support)
- **Windows PowerShell** 5.1 or later
- **Active Creo session** running before script execution

### Creo VB API Setup
The scripts automatically handle VB API connection, but ensure:
- Creo VB API COM components are registered (happens during Creo installation)
- No additional Creo licenses required beyond standard Parametric license
- User must have appropriate Creo modeling rights for the operations being performed

## Usage Instructions

### Method 1: Double-Click Execution (Recommended)
Each PowerShell script has a corresponding batch file wrapper:
- Double-click the `*_RUN.bat` file for the desired tool
- Follow the prompts in the PowerShell window
- Switch to Creo when prompted to make selections
- Return to PowerShell window to continue

### Method 2: Direct PowerShell Execution
```powershell
# Navigate to script directory
cd "path\to\ngs-orthogrid-automation"

# Execute desired script
.\flipenator.ps1
.\nodelator.ps1
.\surfenator.ps1
.\thickenator.ps1
```

### General Workflow
1. **Open Creo** and load your model
2. **Run desired script** (via batch file or PowerShell)
3. **Follow prompts** to select geometry in Creo
4. **Wait for completion** - script will generate and execute mapkey automatically
5. **Review results** in Creo model


## Troubleshooting

### Common Issues

**"Cannot find Creo process"**
- Ensure Creo Parametric is running before executing scripts
- Only one Creo process should be active
- Try restarting Creo if connection fails

**"VB API registration error"**
- VB API COM components may need re-registration
- Run Creo installation repair, or contact IT for COM registration

**"Access denied to working folder"**
- Ensure `C:\Users\[username]\working_folder\` exists and is writable
- Check Windows permissions for the folder

**Script hangs during execution**
- Switch to Creo window - script may be waiting for user selection
- Check PowerShell window for prompts
- Ensure model is in appropriate mode (Part/Assembly as required)

### Getting Help
- Review script output in PowerShell window for specific error messages
- Check Creo message log for additional error details
- Ensure all prerequisite geometry exists before running scripts
- Try running scripts on simple test geometry first


## License

Internal Blue Origin toolset. See company policies for usage and distribution guidelines.

## Authors

- **Kyle Brooker** - Initial development and orthogrid automation workflows
- **Ethan Iglehart** - Gauginator development