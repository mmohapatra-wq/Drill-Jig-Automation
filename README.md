# NGS Orthogrid Automation

A collection of PowerShell automation tools that leverage the Creo Parametric VB API to automate complex modeling operations through dynamic mapkey generation. These tools enable advanced Creo automation without requiring additional software licenses beyond standard Creo Parametric.

## Overview

This repository contains specialized automation tools designed for orthogrid and structural modeling workflows in Creo Parametric. All tools are packaged as single-file .cmd executables that embed PowerShell code for ease of use. Most tools use the Creo VB API COM interface to gather user selections and model data, then generate and execute custom mapkeys "on the fly" to perform complex operations that would be tedious to do manually. One tool focuses on data extraction and analysis.

**Note:** All tools now use the .cmd format (hybrid batch/PowerShell) for simplified execution. Legacy .ps1 source files are archived in the `ps1 archive/` folder for reference.

## Tools

### 1. Flipenator ([flipenator.cmd](flipenator.cmd))
**Purpose:** Batch flip/mirror operations for selected geometric bodies

- Prompts user to select multiple solid bodies in Creo
- Generates mapkey that iterates through each selected body
- Applies flip operation to each body using Creo's built-in Flip feature
- Useful for creating mirrored components in orthogrid structures

**Usage:** Double-click `flipenator.cmd` and select bodies to flip in Creo

### 2. Nodelator ([nodelator.cmd](nodelator.cmd))
**Purpose:** Duplicate node features at multiple datum point locations

- Requires pre-existing "example node" feature (typically an extruded solid body)
- User selects the example feature, then multiple datum points
- Generates mapkey that copies the node feature to each datum point location
- Uses Creo's Paste Special functionality with by-reference assembly operations
- Essential for creating node patterns in orthogrid structures

**Usage:** Create an example node feature, double-click `nodelator.cmd`, select the example and target datum points

### 3. Surfenator ([surfenator.cmd](surfenator.cmd))
**Purpose:** Create surfaces by extruding 3D curves between datum planes

- Collects user-selected 3D curves and three datum planes (midplane, top plane, bottom plane)
- For each curve: projects it onto the midplane, creates extrude feature extending from top to bottom plane
- Handles plane-based depth constraints and offset calculations
- Generates the surface structure between orthogrid planes

**Usage:** Create 3D curves and datum planes, double-click `surfenator.cmd`, select curves and planes as prompted

### 4. Thickenator ([thickenator.cmd](thickenator.cmd))
**Purpose:** Apply consistent thickness to multiple surface quilts

- Prompts user to select multiple quilt surfaces
- Generates mapkey with reusable sub-routine for thicken operations
- Applies consistent thickness (0.1 units) to each selected quilt
- Includes options for thickness direction and body creation
- Converts surface quilts to solid bodies for structural analysis

**Usage:** Create surface quilts, double-click `thickenator.cmd`, select quilts to thicken

### 5. Gauginator ([gauginator.cmd](gauginator.cmd))
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

**Usage:** Double-click `gauginator.cmd` with your model open - no selections needed. CSV file will be created in the script directory with filename based on the active model name.

**Output:** `[ModelName]_dimensions.csv` containing tabular data suitable for spreadsheet analysis

### 6. Gripenator ([gripenator.cmd](gripenator.cmd))
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

### Execution (Simple Double-Click)
All tools are now packaged as single-file .cmd executables:
- Double-click the desired `.cmd` file (e.g., `flipenator.cmd`, `gauginator.cmd`)
- Follow the prompts in the PowerShell window
- Switch to Creo when prompted to make selections
- Return to PowerShell window to continue

**Available Tools:**
- `flipenator.cmd` - Flip/mirror operations
- `gauginator.cmd` - Extract dimensions to CSV
- `gripenator.cmd` - Fastener management (interactive menu)
- `nodelator.cmd` - Duplicate node features
- `radinator.cmd` - Node-to-stiffener radius automation
- `surfenator.cmd` - Surface extrusion from curves
- `thickenator.cmd` - Thicken surface quilts

### General Workflow
1. **Open Creo** and load your model
2. **Double-click** the desired .cmd file
3. **Follow prompts** to select geometry in Creo
4. **Wait for completion** - script will generate and execute mapkey automatically
5. **Review results** in Creo model

### Legacy Source Files
Original .ps1 source files are preserved in the `ps1 archive/` folder for reference and version control purposes. The .cmd files are self-contained and do not require the .ps1 files to run.


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