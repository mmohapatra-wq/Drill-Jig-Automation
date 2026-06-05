# Creo Mapkey Automation Reference Guide

This guide documents the methodology for creating PowerShell scripts that generate dynamic Creo mapkeys for automation tasks. It serves as a comprehensive reference for building new automation tools and can be used as a foundation for future Claude sessions or skills.

## Table of Contents

1. [Overview](#overview)
2. [Core Architecture](#core-architecture)
3. [Automation Approaches](#automation-approaches)
4. [Mapkey Formatting Challenges and Solutions](#mapkey-formatting-challenges-and-solutions)
5. [Core Automation Tools](#core-automation-tools)
6. [VB API Integration](#vb-api-integration)
7. [Selection and ID Management](#selection-and-id-management)
8. [Mapkey Generation Techniques](#mapkey-generation-techniques)
9. [File Management and Execution](#file-management-and-execution)
10. [Template Script Usage](#template-script-usage)
11. [Best Practices](#best-practices)
12. [Troubleshooting](#troubleshooting)
13. [Example Workflows](#example-workflows)

---

## Overview

### Problem Statement
Creo's native mapkey system is powerful but limited:
- Cannot accept arbitrary inputs or parameters
- Cannot perform logic operations (loops, conditionals)
- Raw recorded output contains excessive extraneous information
- Not user-friendly for complex automation tasks

### Solution Approach
Use PowerShell scripts to:
1. Connect to Creo session via VB API (read-only)
2. Extract necessary information from active model
3. Dynamically generate clean, purpose-built mapkeys
4. Write mapkeys to temporary `.pro` files
5. Import and execute mapkeys automatically
6. Provide seamless user experience

### Key Advantages
- **No elevated permissions required** - Users run with standard Creo license
- **Modular design** - Sub-mapkeys enable reusable components
- **Dynamic content** - Scripts can loop to generate repetitive actions
- **Clean automation** - Eliminates manual mapkey cleanup and formatting

---

## Core Architecture

All automation scripts follow a consistent **4-phase architecture**:

### Phase 1: Environment Setup
```powershell
# Find running Creo process
$proc = Get-Process | Where-Object {$_.ProcessName -eq "xtop"}
if ($null -eq $proc) {
    throw "Running Creo process (xtop) not found"
}

# Set required environment variables
$pc_path = $proc.Path -replace "xtop.exe", "pro_comm_msg.exe"
$Env:PRO_DIRECTORY = $proc.Path.TrimEnd("xtop.exe")
$Env:PRO_COMM_MSG_EXE = $pc_path

# Auto-register VB API if needed
try {
    New-Object -ComObject pfcls.pfcAsyncConnection | Out-Null
}
catch {
    $vb_path = $proc.Path -replace "Common Files(.*)$", "Parametric\bin\vb_api_register.bat"
    Start-Process -Wait -FilePath $vb_path
}
```

### Phase 2: Connection & Session
```powershell
$async = New-Object -ComObject pfcls.pfcAsyncConnection
$connection = $async.Connect($null, $null, $null, $null)
$session = $connection.Session
$model = $session.GetActiveModel()
```

### Phase 3: Selection & Processing
```powershell
# Get current selection from Creo's selection buffer
$selection = ($session.CurrentSelectionBuffer()).Contents

# Prompt user if no selection
if ($selection -eq $null) {
    Read-Host -Prompt "Select objects, return to this window, and press enter"
    $selection = ($session.CurrentSelectionBuffer()).Contents
}

# Extract IDs based on selection type
$ids = @()
foreach ($item in $selection) {
    $ids += $item.SelItem.Id
    # For features: $item.SelItem.getFeatures() | Select-Object -ExpandProperty Id
    # For composite: $item.SelItem.ListElements()
}
```

### Phase 4: Mapkey Generation & Execution
```powershell
# Build mapkey using StringBuilder
$StringBuilder = New-Object System.Text.StringBuilder
[void]$StringBuilder.AppendLine("visible_mapkeys no")
# ... build mapkey content ...

# Write to temporary .pro file
$username = $env:USERNAME
$StringBuilder.ToString() | Out-File "C:\Users\$username\working_folder\$name.pro"

# Import and execute (Creo 12+ compatible)
$session.RunMacro("~ Command ``ProCmdUtilMacros``")
# ... import sequence (see File Management and Execution section) ...
$session.RunMacro("%$name")

# Clean up
$connection.Disconnect($null)
```

---

## Automation Approaches

There are two primary approaches for Creo automation, each with distinct advantages depending on the use case:

### 1. Direct Feature Creation (Recommended for General Use)
**Examples**: thickenator.ps1, surfenator.ps1, flipenator.ps1

**Approach**: Generate mapkeys that create features from scratch using Creo's native feature creation commands.

**Advantages**:
- **Model-agnostic**: Works across different models without requiring specific template features
- **Predictable**: Behavior is consistent regardless of existing model structure
- **Robust**: No dependency on reference table mappings or existing feature configurations
- **User-friendly**: Other users can apply to their models without setup

**When to Use**:
- Feature creation is relatively straightforward via mapkeys
- Maximum portability across different models is required
- Multiple users will use the automation tool
- The feature creation process is well-understood and can be easily recorded

**Example Pattern** (Thickenator approach):
```powershell
# For each selected quilt:
#   1. Select quilt by ID using Find tool
#   2. Invoke Thicken command directly
#   3. Apply standard parameters
#   4. Complete feature creation
```

### 2. Template Copying with Reference Redirection
**Examples**: nodelator.ps1

**Approach**: Create one complex "template" feature manually, then use Paste Special to copy it while redirecting specific references to new targets.

**Advantages**:
- **Efficient for complex features**: Avoids recreating complicated feature definitions
- **Handles advanced constraints**: Template can contain complex geometric relationships
- **Fewer lines of code**: Once template exists, copying is more concise than recreation
- **Sophisticated geometry**: Can handle features that would be difficult to create via pure mapkeys

**When to Use**:
- The desired feature is complex or difficult to create via direct mapkey commands
- Template feature can be pre-created in the model
- Reference redirection requirements are well-understood
- Working within a controlled environment where template setup is feasible

**Limitations**:
- **Reference table complexity**: Requires understanding which table row contains which reference
- **Model-dependent**: Needs template feature to exist in the target model
- **Less portable**: May require adjustment for different model structures
- **Setup overhead**: User must create and maintain template features

**Example Pattern** (Nodelator approach):
```powershell
# For each target datum point:
#   1. Copy template node feature to clipboard
#   2. Initiate Paste Special with reference configuration
#   3. Select appropriate row in external reference table
#   4. Use Find tool to select new datum point reference
#   5. Complete paste operation
```

### 3. Hybrid Approaches
Some automation scenarios benefit from combining both approaches:
- Use direct feature creation for simple, standard operations
- Use template copying for complex, specialized geometry
- Chain multiple approaches within a single script

### Choosing the Right Approach

**Prefer Direct Feature Creation when**:
- The feature can be easily created with standard Creo commands
- Maximum portability is required
- Multiple users will use the tool
- Feature parameters are straightforward

**Prefer Template Copying when**:
- Direct feature creation would be extremely complex or fragile
- The template feature contains sophisticated geometric relationships
- Working in a controlled environment with consistent model structure
- The reference redirection pattern is well-understood from recorded examples

---

## Mapkey Formatting Challenges and Solutions

### Challenge 1: Backtick Escaping
**Problem**: Mapkeys use backticks (`) frequently, but PowerShell treats backticks as escape characters.

**Solution**: Double all backticks in mapkey strings:
```powershell
# Wrong - will cause PowerShell parsing errors
[void]$StringBuilder.AppendLine("~ Command `ProCmdMdlTreeSearch` ;")

# Correct - double backticks for PowerShell
[void]$StringBuilder.AppendLine("~ Command ``ProCmdMdlTreeSearch`` ;")
```

### Challenge 2: Line Continuations
**Problem**: Mapkeys use backslash (`\`) for line continuation, and the final line must NOT end with backslash.

**Solution**: Consistent continuation formatting:
```powershell
# All lines except last end with ;\
[void]$StringBuilder.AppendLine("mapkey $name @MAPKEY_LABEL$name;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdMdlTreeSearch`` ;\")
# Final line - no backslash
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``CancelButton``;")
```

### Challenge 3: StringBuilder Efficiency
**Problem**: String concatenation with `+=` is inefficient for large mapkeys.

**Solution**: Use `System.Text.StringBuilder` with `[void]` casting:
```powershell
$StringBuilder = New-Object System.Text.StringBuilder
# [void] prevents console output of AppendLine return values
[void]$StringBuilder.AppendLine("content")
```

### Challenge 4: Raw Recording Cleanup
**Problem**: Raw recorded mapkeys contain excessive information (mouse movements, timers, etc.).

**Solution**: Extract only essential commands:
```powershell
# Raw recording might include:
# ~ Timer `` `` `popupMenuRMBTimerCB`;
# ~ Close `rmb_popup` `PopupMenu`;

# Clean version focuses on core action:
# ~ Command `ProCmdRedefine@PopupMenuGraphicWinStack` ;
```

### Challenge 5: VB API Property vs Method Access
**Problem**: Some VB API operations expose properties (not methods) that should be accessed directly without parentheses.

**Common Errors and Solutions**:
```powershell
# Wrong - will cause "does not contain a method named 'GetFullName'" error
Write-Output "Model: $($model.GetFullName())"

# Correct - access property directly
Write-Output "Model: $($model.FullName)"

# Wrong - will cause "does not contain a method named 'getFeatures'" error
$templateFeature = $templateSelection[0].SelItem.getFeatures()

# Correct - access Id property directly for feature selections
$templateFeatureId = $templateSelection[0].SelItem.Id
```

**VB API Property Access Patterns**:
- **Model names**: Use `$model.FullName` not `$model.GetFullName()`
- **Feature selections**: Use `$item.SelItem.Id` for direct feature selections
- **Body selections**: Use `$item.SelItem.getFeatures()` when selecting bodies that contain features
- **Composite curves**: Use `$item.SelItem.ListElements()` for curve element access

### Challenge 6: Selection Buffer Contamination
**Problem**: Multiple selections in Creo's buffer can cause paste special operations to enter unexpected states.

**Critical Solution**: Always clear selection buffer before using Find tool:
```powershell
# Essential buffer clearing before each Find tool usage
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``buffer_clean``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdMdlTreeSearch`` ;\")
```

**Why This Is Critical**:
- **Paste Special expects clean state** - Multiple selections confuse the operation
- **Find tool reliability** - Previous selections can interfere with new selections
- **UI dialog consistency** - Mixed selections cause dialogs to behave unpredictably

**Buffer Management Best Practice**:
```powershell
# Template copying workflow with proper buffer management
foreach ($targetId in $targetIds) {
    # 1. Clear buffer before selecting template
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``buffer_clean``;\")
    # 2. Find and select template feature
    [Find tool selection of template]
    # 3. Copy template
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdEditCopy`` ;\")
    # 4. Start paste special
    [Paste Special workflow]
    # 5. Clear buffer before selecting new reference
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``buffer_clean``;\")
    # 6. Find and select target reference
    [Find tool selection of target]
    # 7. Complete paste operation
}
```

---

## Core Automation Tools

Creo automation relies on two primary tools accessible via mapkeys. These tools enable programmatic selection and sophisticated feature copying, forming the foundation of most automation workflows.

### 1. Find Tool (ProCmdMdlTreeSearch)

The Find tool is the **primary method for programmatic object selection** in mapkeys. It provides reliable, ID-based selection that works consistently across different Creo sessions and models.

#### **Basic Find Tool Pattern**
```powershell
~ Command ``ProCmdMdlTreeSearch`` ;\
~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``$objectType``;\     # Object type selection
~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;\                   # Switch to ID-based rules
~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$id``;\
~ Activate ``selspecdlg0`` ``EvaluateBtn``;~ Activate ``selspecdlg0`` ``ApplyBtn``;\
~ Activate ``selspecdlg0`` ``CancelButton``;\
```

#### **Object Type Variations**
- **Features**: `~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Feature``;`
- **Points**: `~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Point``;`
- **Curves**: `~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Curve``;`
- **Geometric Bodies**: `~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Geometric Body``;`
- **Quilts**: `~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Quilt``;`
- **Surfaces**: `~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Surface``;`
- **Datum Planes**: `~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Plane``;`
- **Coordinate Systems**: `~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Csys``;`

#### **Object Type Consistency Validation**

**Problem**: A common Find tool failure occurs when there's a mismatch between what users select in Creo and what the script searches for in the Find tool.

**Example Failure Scenario**:
```powershell
# User selects individual surfaces in Creo
# But script searches for quilts
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Quilt``;\")
# Result: Find tool fails to locate the surface by ID because it's searching wrong object type
```

**Solution Strategy**:

1. **Document Expected Selection**: Clearly specify in script documentation what objects users should select
2. **Consider Selection Variations**: Some operations may work with multiple object types

**Object Type Selection Guidelines**:

| **User Selects** | **Find Tool Type** | **Use Case** |
|------------------|-------------------|--------------|
| Individual surfaces | `Surface` | Surface-specific operations (offset, extend, trim) |
| Surface quilts | `Quilt` | Quilt operations (thicken, solidify) |
| Solid bodies | `Body` | Body operations (shell, split) |
| Features in model tree | `Feature` | Feature modification (redefine, suppress) |
| Datum points | `Point` | Point-based constraints and references |
| Datum planes | `Plane` | Plane-based operations and references |
| Curves/edges | `Curve` | Curve operations (project, trim, extend) |

**Validation Techniques**:

```powershell
# Method 1: Test selection type during development
# Manually select objects and check what type they report as
$selection = ($session.CurrentSelectionBuffer()).Contents
foreach ($item in $selection) {
    Write-Output "Selected object type: $($item.SelItem.GetType().Name)"
    Write-Output "Object ID: $($item.SelItem.Id)"
    # Use this information to set correct Find tool object type
}

# Method 2: Provide clear user guidance in script documentation
# Example from offsetenator.ps1:
# "Select surface quilts when prompted (or pre-select before running)"
# Corresponding Find tool setting: ``Surface`` or ``Quilt`` as appropriate

# Method 3: Add validation in script
if ($selection -eq $null -or $selection.Count -eq 0) {
    Write-Output "ERROR: No SURFACES selected. Please select individual surfaces (not quilts) and try again."
    # Be specific about what type of object to select
}
```

**Common Object Type Mapping Issues**:
- **Surfaces vs Quilts**: All Quilts are surfaces, but not all surfaces are quilts. Surfaces can be associated with solid bodies or not. Quilts are independant of solid geometry. Operations that act on existing solid bodies (like offsets) will usually need to select surfaces. 
- **Bodies vs Features**: Selecting a solid body may require `Body` or `Feature` depending on the operation
- **Curves vs Edges**: Curve features use `Curve`, but edge selections may need different approaches
- **Points vs Vertices**: Datum points use `Point`, but vertex selections have different requirements

**Debugging Failed Find Operations**:
1. **Check object type consistency** - Most common issue
2. **Verify ID extraction** - Ensure IDs are being extracted correctly from selection
3. **Test Find tool manually** - Use Creo's Find tool with the same object type and ID
4. **Review selection buffer** - Check what's actually in the selection when script runs

#### **Advanced Find Tool Options**
```powershell
# Disable query builder for simple ID-based selection
~ Select ``selspecdlg0`` ``CascadeButton1``;\
~ Close ``selspecdlg0`` ``CascadeButton1``;\
~ Activate ``selspecdlg0`` ``CondBuilderCheck`` 0;\

# Control selection scope (current model vs all models)
~ Activate ``selspecdlg0`` ``SelScopeCheck`` 0;\

# Alternative verbose pattern (more robust for some Creo versions)
~ Open ``selspecdlg0`` ``SelOptionRadio``;~ Close ``selspecdlg0`` ``SelOptionRadio``;\
~ Select ``selspecdlg0`` ``RuleTypes`` 1 ``ID``;\
```

#### **Replacing @PAUSE_FOR_SCREEN_PICK**
When cleaning recorded mapkeys, replace manual selection with Find tool:
```powershell
# Original recorded mapkey:
# @PAUSE_FOR_SCREEN_PICK;

# Replace with Find tool selection:
~ Command ``ProCmdMdlTreeSearch`` ;\
~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Curve``;\
~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;\
~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$curveId``;\
~ Activate ``selspecdlg0`` ``EvaluateBtn``;~ Activate ``selspecdlg0`` ``ApplyBtn``;\
~ Activate ``selspecdlg0`` ``CancelButton``;\
```

### 2. Paste Special Tool (ProCmdEditPasteSpecial)

Paste Special enables **template-based feature creation** by copying existing features and redirecting their references to new targets. This is particularly powerful for complex features that would be difficult to recreate from scratch.

#### **Complete Paste Special Workflow**
```powershell
# 1. Copy template feature to clipboard
~ Command ``ProCmdMdlTreeSearch`` ;\
~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Feature``;\
~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$templateFeatureId``;\
~ Activate ``selspecdlg0`` ``EvaluateBtn``;~ Activate ``selspecdlg0`` ``ApplyBtn``;\
~ Activate ``selspecdlg0`` ``CancelButton``;\
~ Command ``ProCmdEditCopy`` ;\

# 2. Initiate Paste Special with advanced reference configuration
~ Command ``ProCmdEditPasteSpecial`` ;\
~ Activate ``paste_special`` ``makecopyiesPB`` 0;\               # Create independent copy
~ Activate ``paste_special`` ``pastebyrefPB`` 1;\                # Enable reference redefinition
~ Activate ``paste_special`` ``okPB``;\

# 3. Select reference to redefine in external reference table
~ Trigger ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 ``$rowNumber`` ``ext_ref_list``;\
~ Select ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 ``$rowNumber`` ``ext_ref_list``;\
~ Trigger ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 `` ````;

# 4. Use Find tool to select new reference (replaces @PAUSE_FOR_SCREEN_PICK)
~ Command ``ProCmdMdlTreeSearch`` ;\
~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``$newReferenceType``;\
~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;\
~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$newReferenceId``;\
~ Activate ``selspecdlg0`` ``EvaluateBtn``;~ Activate ``selspecdlg0`` ``ApplyBtn``;\
~ Activate ``selspecdlg0`` ``CancelButton``;\

# 5. Complete paste operation
~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;\                       # Accept settings
~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;\                       # Final confirmation
```

#### **Paste Special Dialog Options**
```powershell
# Main Paste Special Options:
~ Activate ``paste_special`` ``makecopyiesPB`` 0;\      # Disable "Dependent Copy" (default=1)
~ Activate ``paste_special`` ``pastebyrefPB`` 1;\       # Enable "Advanced reference configuration" (default=0)
# Note: "Apply move/rotation transformations" is typically left at default (0)
```

#### **External Reference Table Navigation**
```powershell
# Select specific row in reference table (row numbers determined from recorded examples)
~ Trigger ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 ``$rowNumber`` ``ext_ref_list``;\
~ Select ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 ``$rowNumber`` ``ext_ref_list``;\

# Multiple reference changes (sequential processing)
# For each additional reference:
# 1. Select different row number
# 2. Use Find tool to select new reference
# 3. Repeat as needed
```

#### **Reference Table Row Identification Strategy**
Since there's no reliable programmatic way to determine reference table mappings, use **recorded mapkey analysis**:

1. **User provides recorded example**: User records manual Paste Special operation showing which table row contains the target reference
2. **Extract row information**: Identify the row number from the recorded `t1.ext_ref_table` commands
3. **Incorporate into automation**: Use the extracted row number in the generated mapkey

**Example User Request Format**:
```
Task: Copy template extrude feature and redirect curve reference for each target curve

Recorded Example: [user provides paste special mapkey showing row 4 contains curve reference]

Template Feature ID: 12345
Target Curve IDs: [list of curve IDs to redirect to]
```

#### **Reference Types Supported**
Paste Special can redirect virtually any feature reference:
- **Geometric References**: Curves, surfaces, edges, vertices
- **Datum References**: Planes, axes, points, coordinate systems
- **Feature References**: Other features used as parents or constraints
- **Assembly References**: Components, assembly features, layouts

### 3. Tool Integration Patterns

#### **Find Tool + Direct Feature Creation**
```powershell
foreach ($id in $targetIds) {
    # Select object using Find tool
    [Find tool selection pattern]

    # Apply feature command directly
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdFtThicken`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Input ``main_dlg_cur`` ``maindashInst0.Thickness`` ``$thickness``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``dashInst0.Done``;\")
}
```

#### **Find Tool + Paste Special Integration**
```powershell
foreach ($targetId in $targetIds) {
    # Copy template feature
    [Find tool selection of template + ProCmdEditCopy]

    # Paste Special with reference redirection
    [Paste Special workflow redirecting to $targetId]
}
```

#### **Buffer Management Between Operations**
```powershell
# Clear selection buffer between operations
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``buffer_clean``;\")
```

## Common Patterns and Templates

### Basic Mapkey Structure
```powershell
$StringBuilder = New-Object System.Text.StringBuilder
[void]$StringBuilder.AppendLine("visible_mapkeys no")

# Optional: Create sub-mapkey for reusable operations
[void]$StringBuilder.AppendLine("mapkey sub$name @MAPKEY_LABELsub$name;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdSomeAction`` ;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``dashInst0.Done``;")

# Main mapkey
[void]$StringBuilder.AppendLine("mapkey $name @MAPKEY_LABEL$name;\")
foreach ($id in $ids) {
    # Select object by ID
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdMdlTreeSearch`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$id``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``EvaluateBtn``;~ Activate ``selspecdlg0`` ``ApplyBtn``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``CancelButton``;\")

    # Call sub-mapkey or perform action
    [void]$StringBuilder.AppendLine("mapkey(continued) %sub$name;\")
}
# Final line - no backslash
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``buffer_clean``;")
```

### Find Tool Selection Pattern
The most reliable way to select objects in mapkeys:
```powershell
# Open Find dialog
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdMdlTreeSearch`` ;\")

# Set selection type (Feature, Point, Quilt, Geometric Body, etc.)
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Open ``selspecdlg0`` ``SelOptionRadio``;~ Close ``selspecdlg0`` ``SelOptionRadio``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Feature``;\")

# Switch to ID-based selection
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;\")

# Enter specific ID
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$id``;\")

# Evaluate and apply selection
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``EvaluateBtn``;~ Activate ``selspecdlg0`` ``ApplyBtn``;\")

# Close dialog
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``CancelButton``;\")
```

### Buffer Management
Clean selection buffers between operations:
```powershell
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``buffer_clean``;\")
```

---

## VB API Integration

### Selection Types and ID Extraction
Different Creo objects require different ID extraction methods:

#### Simple Objects (Bodies, Quilts, Points)
```powershell
foreach ($item in $selection) {
    $id = $item.SelItem.Id
}
```

#### Features
```powershell
foreach ($item in $selection) {
    $feature = $item.SelItem.getFeatures()
    $featureId = ($feature | Select-Object -ExpandProperty Id)
}
```

#### Composite Curves
```powershell
foreach ($item in $selection) {
    $elements = $item.SelItem.ListElements()
    foreach ($element in $elements) {
        $elementId = $element.Id
    }
}
```

#### Mixed Selection Processing
```powershell
$bodyIds = @()
$featIds = @()
foreach ($item in $selection) {
    $bodyIds += $item.SelItem.Id
    $feature = $item.SelItem.getFeatures()
    $featIds += ($feature | Select-Object -ExpandProperty Id)
}
```

### Connection Management
Always properly disconnect:
```powershell
try {
    # Main script logic
}
catch {
    Write-Output "Error: $_"
}
finally {
    if ($connection) {
        $connection.Disconnect($null)
    }
}
```

---

## Selection and ID Management

### Selection Buffer Usage
Creo maintains a selection buffer that scripts can access:
```powershell
# Get current selections
$selection = ($session.CurrentSelectionBuffer()).Contents

# Check for empty selection
if ($selection -eq $null) {
    Read-Host -Prompt "Select objects, return to this window, and press enter"
    $selection = ($session.CurrentSelectionBuffer()).Contents
}
```

### ID-Based Operations
IDs are the key to programmatic selection in mapkeys:
- **Feature IDs**: Used for feature-based operations (flip, modify, etc.)
- **Body IDs**: Used for body-based operations (selection, measurement, etc.)
- **Element IDs**: Used for individual curve elements in composite features

### Selection Validation
```powershell
if ($selection -eq $null -or $selection.Count -eq 0) {
    Write-Output "No objects selected. Exiting..."
    exit
}
```

---

## Mapkey Generation Techniques

### Sub-Mapkey Strategy
Create reusable sub-routines for repetitive operations:

```powershell
# Sub-mapkey for flip operation
[void]$StringBuilder.AppendLine("mapkey sub$name @MAPKEY_LABELsub$name;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdRedefine@PopupMenuGraphicWinStack`` ;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``maindashInst0.Flip``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``dashInst0.Done``;")

# Main mapkey calls sub-mapkey for each object
foreach ($id in $featureIds) {
    # Select object...
    [void]$StringBuilder.AppendLine("mapkey(continued) %sub$name;\")
}
```

### Parameter Injection
Inject dynamic values from PowerShell variables:
```powershell
$thickness = "0.1"
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Input ``main_dlg_cur`` ``maindashInst0.Thickness`` ``$thickness``;\")
```

### Conditional Logic
PowerShell enables conditional mapkey generation:
```powershell
if ($selection.Count -gt 10) {
    # Generate batch processing mapkey
} else {
    # Generate individual processing mapkey
}
```

---

## File Management and Execution

### Temporary File Strategy
Always use temporary files in user's working folder:
```powershell
$username = $env:USERNAME
$filePath = "C:\Users\$username\working_folder\$name.pro"
$StringBuilder.ToString() | Out-File $filePath
```

**Never** overwrite `config.pro` or other system files.

### Import Sequence

#### Creo 12+ (Mapkey Editor Approach)
Standard sequence to import and execute mapkeys in Creo 12 and later:
```powershell
# Open Mapkey Editor
$session.RunMacro("~ Command ``ProCmdUtilMacros``")

# Click Import button
$session.RunMacro("~ Activate ``mapkey_main`` ``psh_import``")

# Navigate to file dialog
$session.RunMacro("~ Trail `` `` ``DLG_PREVIEW_POST`` ``file_open``")

# Select the generated .pro file
$session.RunMacro("~ Select ``file_open`` ``Ph_list.Filelist`` 1 ``$name.pro``")

# Confirm file selection
$session.RunMacro("~ Command ``ProFileSelPushOpen_Standard@context_dlg_open_cmd``")

# Close Mapkey Editor and save imported mapkeys
$session.RunMacro("~ Activate ``mapkey_main`` ``CloseButton``")
$session.RunMacro("~ Activate ``unsaved_mapkeys`` ``yes``")

# Execute the mapkey
$session.RunMacro("%$name")
```

#### Creo 11 and Earlier (Configuration Editor Approach - Legacy)
For reference only - use Creo 12+ approach for new scripts:
```powershell
# This approach no longer works reliably in Creo 12
# See CREO_12_MIGRATION_GUIDE.md for updating older scripts

$session.RunMacro("~ Command ``ProCmdRibbonOptionsDlg``")
$session.RunMacro(" ~ Select ``ribbon_options_dialog`` ``PageSwitcherPageList`` 1 ``ConfigLayout``")
# ... etc - deprecated in Creo 12
```

**Migration Note**: If you have scripts using the older Configuration Editor approach, see [CREO_12_MIGRATION_GUIDE.md](CREO_12_MIGRATION_GUIDE.md) for step-by-step update instructions.

### File Cleanup
Consider cleaning up temporary files:
```powershell
# Optional cleanup after execution
Remove-Item $filePath -ErrorAction SilentlyContinue
```

---

## Best Practices

### Script Organization
1. **Consistent naming**: Use descriptive names ending in "ator" (flipenator, thickenator, etc.)
2. **Comprehensive headers**: Include SYNOPSIS, DESCRIPTION, PREREQUISITES, USAGE, AUTHOR
3. **Error handling**: Wrap VB API calls in try-catch blocks
4. **Clean disconnection**: Always disconnect VB API connection

### Mapkey Design
1. **Disable visible mapkeys**: Always start with `visible_mapkeys no`
2. **Use sub-mapkeys**: Create reusable components for repetitive actions
3. **Buffer management**: Clean selection buffers between operations
4. **Robust selection**: Use Find tool (`ProCmdMdlTreeSearch`) for reliable selection

### Performance Optimization
1. **StringBuilder usage**: Use for efficient string building
2. **Batch operations**: Group similar operations together
3. **Minimize UI updates**: Disable visible mapkeys and unnecessary displays

### User Experience
1. **Clear prompts**: Provide helpful user prompts for selections
2. **Error messages**: Give meaningful feedback on failures
3. **Silent execution**: Import and execute mapkeys automatically
4. **Selection persistence**: Re-select original objects when helpful
5. **Honest messaging**: Never claim mapkey success - scripts cannot detect mapkey execution results

### Script Messaging Guidelines
**CRITICAL**: Due to mapkey limitations, scripts must use honest, factual messaging:

#### **Correct Messaging Patterns**:
```powershell
# ✓ GOOD - States intention and facts
Write-Output "Executing mapkey..."
$session.RunMacro("%$name")
Write-Output "Mapkey execution call completed"
Write-Output "Check your Creo model for results"

# ✓ GOOD - Progress reporting without success claims
Write-Output "Processing $($targetIds.Count) objects"
Write-Output "Mapkey written to: $mapkeyPath"
Write-Output "Calling mapkey: %$name"
```

#### **Incorrect Messaging Patterns**:
```powershell
# ❌ BAD - Scripts cannot detect mapkey success
Write-Output "Automation completed successfully!"
Write-Output "All features created successfully"
Write-Output "Mapkey executed without errors"

# ❌ BAD - Implies verification that didn't happen
Write-Output "All quilts thickened successfully"
Write-Output "Node features created at all locations"
Write-Output "Operation completed without issues"
```

#### **Recommended Script Conclusion**:
```powershell
Write-Output ""
Write-Output "================================="
Write-Output "  $name EXECUTION COMPLETE"
Write-Output "================================="
Write-Output "Processed $($targetIds.Count) objects"
Write-Output "Mapkey execution call finished"
Write-Output "Please verify results in your Creo model"
```

---

## Troubleshooting

### Mapkey Execution Failures and Recovery

#### **Critical Limitation: No Error Reporting**
**IMPORTANT**: Mapkeys provide **no error reporting mechanism** back to PowerShell scripts. This means:
- **No success/failure status**: Scripts cannot determine if mapkeys executed successfully
- **No exception handling**: PowerShell try-catch blocks cannot detect mapkey failures
- **No return values**: Mapkeys do not communicate results back to the calling script
- **Silent failures**: Mapkey failures may go unnoticed until manual inspection

#### **Nature of Mapkey Failures**
Mapkeys are **sequential command streams with no error handling**. They simulate user GUI interactions, which means:
- **State-dependent**: Each command expects Creo to be in a specific UI state
- **No error recovery**: If one command fails, subsequent commands will likely fail
- **Cascading failures**: Failed commands leave Creo in unexpected states, causing all following commands to execute uselessly
- **No feedback mechanism**: Scripts cannot programmatically detect these failure conditions

#### **Common Failure Scenarios**
- **Find tool object type mismatches**: Mapkey searches for wrong object type (e.g., searches for "Quilt" when user selected individual "Surface" objects)
- **Dialog state mismatches**: Expected dialog not open or in wrong configuration
- **Selection buffer issues**: Previous selections not cleared properly
- **Model regeneration problems**: Features fail to create, blocking subsequent operations
- **UI timing issues**: Commands executed before dialogs fully load
- **Invalid references**: Features reference non-existent geometry

#### **Limited Recovery Options**
Since mapkeys have no built-in error handling:
- **No programmatic detection**: Can't detect mid-execution failures from within mapkey
- **Manual intervention required**: User must identify and resolve issues manually
- **Restart approach**: Often easier to fix underlying issue and re-run entire script

#### **Prevention Strategies**
```powershell
# 1. CRITICAL: Validate object type consistency before mapkey generation
# Test with actual user selection to ensure Find tool object type matches
$selection = ($session.CurrentSelectionBuffer()).Contents
foreach ($item in $selection) {
    Write-Output "Selected: $($item.SelItem.GetType().Name), ID: $($item.SelItem.Id)"
}
# Ensure Find tool object type matches what users actually select

# 2. Robust buffer management
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``buffer_clean``;\")

# 3. Consistent dialog state establishment
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Open ``selspecdlg0`` ``SelOptionRadio``;~ Close ``selspecdlg0`` ``SelOptionRadio``;\")

# 4. Validation of inputs before mapkey generation
foreach ($id in $ids) {
    if ($id -eq $null -or $id -eq "") {
        Write-Output "Error: Invalid ID detected. Aborting mapkey generation."
        exit
    }
}

# 4. Conservative dialog handling (keep verbose UI sequences)
# Prefer keeping "redundant" UI commands over risking state mismatches
```

### Performance and Scalability

#### **Performance Characteristics**
- **PowerShell script execution**: Very fast even with hundreds of objects
- **Mapkey generation**: Scales linearly with number of target objects
- **Creo execution time**: Can be slow (minutes) for large mapkeys, but still much faster than manual work
- **No parallel execution**: Mapkeys must run sequentially

#### **Performance Optimization Options**
```powershell
# Add performance optimizations to .pro file before mapkey
[void]$StringBuilder.AppendLine("dynamic_preview unattached")  # Faster preview rendering
# Alternative: "dynamic_preview no" for maximum speed (but less user feedback)
[void]$StringBuilder.AppendLine("visible_mapkeys no")           # Disable mapkey display
```

**Performance Settings Explanation**:
- **`dynamic_preview unattached`**: Shows lightweight preview during feature creation
- **`dynamic_preview no`**: No preview (fastest, but user gets no visual feedback)
- **Default behavior**: Full rendering during creation (slowest, but best user experience)

#### **Scalability Testing Results**
- **Hundreds of objects**: No significant PowerShell performance issues
- **Large mapkey execution**: Creo may take 5+ minutes, but still faster than manual work
- **Memory usage**: Generally not problematic for typical automation tasks

### Selection Type Edge Cases and Solutions

#### **Flexible Selection Processing Pattern**
```powershell
# Adaptive selection processing based on user input
$targetIds = @()
foreach ($item in $selection) {
    try {
        # Try composite feature approach (for complex curves, etc.)
        $elements = $item.SelItem.ListElements()
        foreach ($element in $elements) {
            $targetIds += $element.Id
        }
        Write-Output "Processed composite feature with $($elements.Count) elements"
    }
    catch {
        try {
            # Try feature-based approach (for solid bodies, etc.)
            $features = $item.SelItem.getFeatures()
            foreach ($feature in $features) {
                $targetIds += $feature.Id
            }
            Write-Output "Processed feature-based selection"
        }
        catch {
            # Fall back to direct ID (for simple objects)
            $targetIds += $item.SelItem.Id
            Write-Output "Processed direct ID selection"
        }
    }
}
```

#### **Selection Validation Strategies**
```powershell
# Validate selection compatibility before processing
if ($selection -eq $null -or $selection.Count -eq 0) {
    Write-Output "No objects selected. Please select target objects and try again."
    exit
}

# Check for mixed selection types if needed
$selectionTypes = @()
foreach ($item in $selection) {
    $selectionTypes += $item.SelItem.GetType().Name
}
$uniqueTypes = $selectionTypes | Select-Object -Unique
if ($uniqueTypes.Count -gt 1) {
    Write-Output "Warning: Mixed selection types detected: $($uniqueTypes -join ', ')"
    # Handle mixed types or prompt user for clarification
}
```

#### **Advanced Selection Processing**
For complex selection scenarios requiring deeper VB API knowledge, utilize the **Creo VB API MCP server** available in this repository. The MCP server provides:
- Detailed interface documentation for selection methods
- Examples of `ListElements()`, `getFeatures()`, and direct ID access patterns
- Guidance on handling different object types and composite features
- Interactive exploration of VB API object models

**MCP Server Usage**: Query the VB API documentation server with specific interface names or conceptual questions about selection handling to get targeted guidance for complex edge cases.

### Common Issues and Solutions

#### VB API Connection Failures
```powershell
# Check if Creo is running
$proc = Get-Process | Where-Object {$_.ProcessName -eq "xtop"}
if ($null -eq $proc) {
    Write-Output "Creo is not running. Please start Creo and try again."
    exit
}
```

#### Find Tool Object Type Failures
**Problem**: Mapkey executes but no objects are selected, causing subsequent commands to fail silently.

**Root Cause**: Mismatch between user selection type and Find tool search type.

**Symptoms**:
- Mapkey completes execution but no features are created
- No error messages, but automation appears to do nothing
- Find tool opens but doesn't select anything

**Debugging Steps**:
```powershell
# Step 1: Verify what users actually selected
$selection = ($session.CurrentSelectionBuffer()).Contents
foreach ($item in $selection) {
    Write-Output "Object Type: $($item.SelItem.GetType().Name)"
    Write-Output "Object ID: $($item.SelItem.Id)"
}

# Step 2: Test Find tool manually in Creo
# - Open Find tool manually
# - Use same object type and ID from debug output above
# - Verify Find tool can locate the object

# Step 3: Check script's Find tool object type
# Look for lines like:
# ~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Quilt``;
# Ensure this matches what users actually selected
```

**Common Object Type Corrections**:
- **Individual surfaces** → Use `Surface` not `Quilt`
- **Surface quilts** → Use `Quilt` not `Surface`
- **Solid bodies** → May need `Body` or `Feature` depending on context
- **Datum elements** → Use specific type (`Point`, `Plane`, `Csys`)

**Prevention**:
1. Test script with actual user workflow during development
2. Document exact selection requirements in script header
3. Add validation that checks selection types match Find tool types
4. Provide specific error messages about required selection types

#### Mapkey Syntax Issues
- **Backtick escaping**: Ensure all backticks are doubled (`ProCmd` becomes ``ProCmd``)
- **Line continuation**: Check backslash usage on mapkey lines (all except last end with `;\`)
- **StringBuilder usage**: Use `[void]` casting to prevent console spam

#### Dialog State Issues
- **Buffer management**: Always clean selection buffers between operations
- **Dialog sequences**: Preserve verbose Open/Close patterns for robustness
- **State validation**: Ensure expected dialogs are available before issuing commands

### Debugging Techniques

#### **Development Phase Debugging**
1. **Console output**: Add `Write-Output` statements to track progress
2. **File inspection**: Examine generated `.pro` files manually for syntax issues
3. **Incremental testing**: Start with small selections and gradually increase complexity

#### **Execution Phase Debugging**
1. **Manual mapkey testing**: Execute mapkey commands individually via `$session.RunMacro()`
2. **Trail file analysis**: Check Creo's trail files for actual executed commands
3. **UI state verification**: Manually verify Creo is in expected state before running automation

#### **Post-Execution Verification Limitations**
```powershell
# IMPORTANT: $session.RunMacro() blocks until mapkey completion, but does NOT indicate success
$session.RunMacro("%$name")  # This returns when mapkey finishes, not when it succeeds

# Common INCORRECT assumptions:
# ❌ If RunMacro() returns without exception, the mapkey succeeded
# ❌ Mapkey failures will throw PowerShell exceptions
# ❌ Scripts can detect mapkey success/failure programmatically

# Correct approach - scripts should:
# ✓ State what they are attempting ("Executing mapkey...")
# ✓ Report completion of the call ("Mapkey execution call completed")
# ✓ Instruct user to verify results manually ("Check Creo model for results")
# ✓ Never claim success without manual verification
```

#### **Error Recovery Workflow**
1. **Identify failure point**: Review Creo UI state and error messages
2. **Fix underlying issue**: Correct invalid selections, resolve model problems
3. **Restart clean**: Re-run entire script rather than attempting partial recovery
4. **Incremental validation**: Test with smaller selections to isolate problems

---

## Example Workflows

### Workflow 1: Direct Feature Creation (Thickenator Pattern)
**Approach**: Direct feature creation with Find tool selection
**Use Case**: Apply consistent operation to multiple objects with standard parameters

```powershell
# 1. Get selection and extract object IDs
$selection = ($session.CurrentSelectionBuffer()).Contents
$quiltIds = @()
foreach ($item in $selection) {
    $quiltIds += $item.SelItem.Id
}

# 2. Define parameters
$thickness = "0.1"

# 3. Create sub-mapkey for reusable thicken operation
[void]$StringBuilder.AppendLine("mapkey sub$name @MAPKEY_LABELsub$name;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdFtThicken`` ;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Input ``main_dlg_cur`` ``maindashInst0.Thickness`` ``$thickness``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``maindashInst0.Flip``;\")
[void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``dashInst0.Done``;")

# 4. Main mapkey processes each quilt
[void]$StringBuilder.AppendLine("mapkey $name @MAPKEY_LABEL$name;\")
foreach ($id in $quiltIds) {
    # Select quilt using Find tool
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdMdlTreeSearch`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Quilt``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$id``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``EvaluateBtn``;~ Activate ``selspecdlg0`` ``ApplyBtn``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``CancelButton``;\")

    # Apply thicken operation
    [void]$StringBuilder.AppendLine("mapkey(continued) %sub$name;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``buffer_clean``;\")
}
```

### Workflow 2: Template Copying with Reference Redirection (Nodelator Pattern)
**Approach**: Paste Special with external reference table modification
**Use Case**: Create multiple copies of complex feature with different reference targets

```powershell
# 1. Get template feature and target locations
$templateFeatureId = "12345"  # Pre-existing complex feature
$selection = ($session.CurrentSelectionBuffer()).Contents
$datumPointIds = @()
foreach ($item in $selection) {
    $datumPointIds += $item.SelItem.Id
}

# 2. Row number from user's recorded Paste Special example
$datumPointRowNumber = "3"  # Extracted from recorded mapkey

# 3. Main mapkey for template copying
[void]$StringBuilder.AppendLine("mapkey $name @MAPKEY_LABEL$name;\")
foreach ($pointId in $datumPointIds) {
    # Copy template feature to clipboard
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdMdlTreeSearch`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Feature``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$templateFeatureId``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``EvaluateBtn``;~ Activate ``selspecdlg0`` ``ApplyBtn``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``CancelButton``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdEditCopy`` ;\")

    # Paste Special with reference redirection
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdEditPasteSpecial`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``paste_special`` ``makecopyiesPB`` 0;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``paste_special`` ``pastebyrefPB`` 1;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``paste_special`` ``okPB``;\")

    # Select datum point reference row in external reference table
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Trigger ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 ``$datumPointRowNumber`` ``ext_ref_list``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 ``$datumPointRowNumber`` ``ext_ref_list``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Trigger ``Odui_Dlg_00`` ``t1.ext_ref_table`` 2 `` ````;")

    # Use Find tool to select new datum point reference
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdMdlTreeSearch`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Point``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$pointId``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``EvaluateBtn``;~ Activate ``selspecdlg0`` ``ApplyBtn``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``CancelButton``;\")

    # Complete paste operation
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;\")
}
```

### Workflow 3: Multi-Selection Direct Creation (Surfenator Pattern)
**Approach**: Direct feature creation with complex multi-selection setup
**Use Case**: Create features requiring multiple different types of references

```powershell
# 1. Collect curves selection
Read-Host -Prompt "Select curves, return here, and press enter"
$curveSelection = ($session.CurrentSelectionBuffer()).Contents
$curveIds = @()
foreach ($item in $curveSelection) {
    # Handle composite curves if needed
    try {
        $elements = $item.SelItem.ListElements()
        foreach ($element in $elements) {
            $curveIds += $element.Id
        }
    }
    catch {
        # Simple curve - direct ID
        $curveIds += $item.SelItem.Id
    }
}

# 2. Get plane references
Read-Host -Prompt "Select midplane (sketch plane), return here, and press enter"
$midplaneId = ($session.CurrentSelectionBuffer()).Contents[0].SelItem.Id

Read-Host -Prompt "Select top plane (extrude bound), return here, and press enter"
$topPlaneId = ($session.CurrentSelectionBuffer()).Contents[0].SelItem.Id

Read-Host -Prompt "Select bottom plane (extrude bound), return here, and press enter"
$bottomPlaneId = ($session.CurrentSelectionBuffer()).Contents[0].SelItem.Id

# 3. Generate surface creation mapkey for each curve
[void]$StringBuilder.AppendLine("mapkey $name @MAPKEY_LABEL$name;\")
foreach ($curveId in $curveIds) {
    # Select curve for projection
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdMdlTreeSearch`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Curve``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$curveId``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``EvaluateBtn``;~ Activate ``selspecdlg0`` ``ApplyBtn``;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``selspecdlg0`` ``CancelButton``;\")

    # Create extrude feature with projection and depth constraints
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdFtExtrude`` ;\")
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Command ``ProCmdSketProject``  1;\")
    # [Additional mapkey commands for midplane selection, projection, depth bounds to top/bottom planes]
    [void]$StringBuilder.AppendLine("mapkey(continued) ~ Activate ``main_dlg_cur`` ``dashInst0.Done``;\")
}
```

### Workflow 4: Hybrid Approach Example
**Approach**: Combine direct creation and template copying as needed
**Use Case**: Complex automation requiring both approaches

```powershell
# Phase 1: Create standard features directly
foreach ($standardId in $standardFeatureIds) {
    # Use direct feature creation for simple, standardizable features
}

# Phase 2: Use template copying for complex features
foreach ($complexId in $complexFeatureIds) {
    # Use Paste Special for sophisticated geometry that's hard to recreate
}

# Phase 3: Final cleanup and organization
# Buffer cleans, re-selections, etc.
```

---

## Template Script Usage

### TEMPLATE.PS1 - Starting Point for New Automation Scripts

A comprehensive template script ([TEMPLATE.PS1](TEMPLATE.PS1)) is available in this repository to serve as the foundation for all new Creo automation scripts. This template incorporates all best practices, common patterns, and the 4-phase architecture documented in this guide.

#### **Template Benefits**
- **Consistent Structure**: Follows proven 4-phase architecture (Environment → Connection → Selection → Generation)
- **Comprehensive Error Handling**: Robust error checking and user-friendly error messages
- **Multiple Selection Patterns**: Handles simple objects, feature-based selections, and composite objects
- **Performance Optimizations**: Configurable preview settings and efficient mapkey generation
- **Extensive Documentation**: Well-commented code with customization instructions

#### **Using the Template**

1. **Copy the Template**:
   ```powershell
   # Copy TEMPLATE.PS1 to your new script name
   Copy-Item "TEMPLATE.PS1" "your_automation_name.ps1"
   ```

2. **Header Customization**:
   - Update `.SYNOPSIS`, `.DESCRIPTION`, `.USAGE` sections
   - Replace `[TEMPLATE_NAME]` with your script name
   - Update `.AUTHOR` with your information

3. **Parameters Section**:
   ```powershell
   # Customize these for your specific automation
   $name = "your_automation_name"        # Script identifier
   $thickness = "0.1"                    # Example parameter
   $distance = "5.0"                     # Example parameter
   $createNewBody = $true                # Example boolean
   ```

4. **Selection Processing**:
   - Choose appropriate selection patterns for your object types
   - The template provides three patterns:
     - **Pattern 1**: Simple objects (quilts, bodies, points, planes)
     - **Pattern 2**: Feature-based objects (solid bodies containing features)
     - **Pattern 3**: Composite objects (curves with multiple elements)

5. **Mapkey Generation**:
   - Replace the Find tool object type (`Feature`, `Quilt`, `Point`, etc.)
   - Add your specific automation commands in the marked section
   - Choose between direct creation, sub-mapkey, or paste special approaches

6. **Testing & Validation**:
   - Test with small selections first
   - Verify generated mapkey syntax
   - Validate results in Creo model

#### **Template Customization Checklist**

The template includes a comprehensive checklist at the bottom for systematic customization:

**✓ Header Customization**
- Update all documentation sections
- Replace placeholder names and values

**✓ Parameters Section**
- Define automation-specific parameters
- Set appropriate default values

**✓ Selection Processing**
- Choose correct selection patterns
- Add specific validation rules

**✓ Mapkey Generation**
- Update object types for Find tool
- Implement automation-specific commands
- Ensure proper mapkey syntax

**✓ Testing & Documentation**
- Validate with various input scenarios
- Document usage examples and limitations

#### **Template File Location**
[TEMPLATE.PS1](TEMPLATE.PS1) - Located in the root of this repository

#### **Quick Start Example**
```powershell
# 1. Copy template to new script
Copy-Item "TEMPLATE.PS1" "chamferator.ps1"

# 2. Edit key sections:
# - Change $name = "chamferator"
# - Update object type to "Edge" for chamfer operations
# - Add chamfer-specific mapkey commands
# - Update documentation for chamfer automation

# 3. Test with small selection in Creo
# 4. Expand to full automation
```

## Future Development Guidelines

### For Creating New Automation Scripts

1. **Start with TEMPLATE.PS1** - Always begin with the provided template for consistency and reliability
2. **Follow the 4-phase architecture** - Environment, Connection, Selection, Generation
3. **Use established patterns** - Find tool selection, StringBuilder, sub-mapkeys
4. **Handle edge cases** - Empty selections, connection failures, ID validation
5. **Provide user guidance** - Clear prompts and error messages
6. **Test thoroughly** - Validate with different selection types and quantities

### Raw Mapkey Cleanup Strategy

When processing raw recorded mapkeys from users, apply conservative cleanup:

#### **Safe to Remove (Common Noise Patterns)**:
- **Timer commands**: `~ Timer `` `` ``popupMenuRMBTimerCB``;`
- **Trail commands**: `~ Trail ``MiniToolbar`` ``MiniToolbar`` ``UIT_TRANSLUCENT`` ``NEED_TO_CLOSE``;`
- **Mouse hover events**: UI element hover without functional purpose
- **Redundant focus events**: Excessive `FocusIn`/`FocusOut` without clear purpose

#### **Always Keep (Functional Commands)**:
- **All `Command` calls**: Core Creo operations (`ProCmdFtExtrude`, `ProCmdMdlTreeSearch`, etc.)
- **Dialog interactions**: `Activate`, `Select`, `Update`, `Input` operations
- **State management**: `Open`/`Close` sequences that establish UI state
- **Parameter setting**: Value input and confirmation sequences

#### **Conservative Approach**:
- **Err on side of caution** - Keep verbose UI interactions rather than risk breaking functionality
- **Preserve dialog sequences** - Even if redundant-looking, they ensure proper UI state
- **Replace manual selection** - Convert `@PAUSE_FOR_SCREEN_PICK` to Find tool patterns
- **Test incrementally** - Remove noise gradually while validating functionality

### Template-Based Development Workflow

When requesting Claude assistance for new automation scripts, always reference the template:

#### **Template-Based Request Format**:
```
Task: Create [automation description] based on TEMPLATE.PS1

Template Customizations Needed:
1. Script name: [your_script_name]
2. Object types: [Feature, Quilt, Point, etc.]
3. Parameters: [list specific parameters like thickness, distance, etc.]
4. Automation approach: [Direct creation / Template copying / Hybrid]
5. Raw mapkey reference: [recorded example if available]

Selection Requirements: [describe what objects user will select]
Expected Behavior: [step-by-step user workflow]
```

#### **Template Advantages for Claude Development**:
- **Faster development**: Focus on automation logic rather than boilerplate
- **Consistent quality**: Proven error handling and connection management
- **Comprehensive patterns**: Multiple selection approaches already implemented
- **Extensive documentation**: Clear customization points and examples
- **Built-in validation**: Robust error checking and user guidance

### For Claude-Assisted Development

#### **Direct Feature Creation Requests**:
```
Task: Create automation for [specific operation] on multiple [object types]

Approach: Direct feature creation (recommended for portability)

Selection: User will select [object types] from model
Parameters: [configurable values like thickness, distance, etc.]
Raw Mapkey: [recorded example of single manual operation]

Expected Behavior:
1. User selects target objects
2. Script applies operation to each object with consistent parameters
3. [Any specific UI behavior requirements]
```

#### **Template Copying Requests**:
```
Task: Create automation for complex [feature type] at multiple locations

Approach: Template copying with reference redirection

Template Feature: [description of complex feature to be copied]
Target References: [what references should be redirected - curves, points, planes, etc.]
Recorded Paste Special Example: [raw mapkey showing reference table row identification]

Expected Behavior:
1. User selects target reference objects
2. Script copies template feature and redirects references
3. Creates independent copies at each location
```

#### **Required Information**:
1. **Task description**: What operation should be automated?
2. **Automation approach**: Direct creation vs template copying vs hybrid
3. **Selection requirements**: What objects need to be selected?
4. **Parameters**: What values should be configurable?
5. **Raw mapkey examples**: Manual operation recordings
6. **Reference mappings**: For Paste Special - which table rows contain which references
7. **Expected behavior**: Complete user workflow description

### Example Request Formats

#### **Direct Creation Example**:
```
Task: Automate applying chamfer to multiple edges with consistent parameters

Approach: Direct feature creation

Selection: User selects multiple edges from solid bodies
Parameters: Chamfer distance (default 0.5), chamfer type (distance-distance)
Raw Mapkey: [recorded mapkey of single chamfer operation]

Behavior:
1. User selects edges to chamfer
2. Script prompts for chamfer distance (optional)
3. Applies chamfer to each edge with consistent parameters
4. Leaves all created chamfers selected for review
```

#### **Template Copying Example**:
```
Task: Create mounting hole features at multiple datum point locations

Approach: Template copying (hole feature is complex with threads, counterbore, etc.)

Template Feature: Existing hole feature with full threading and counterbore definition
Target References: Datum points for hole placement, datum plane for hole direction
Recorded Paste Special: [raw mapkey showing row 2 = datum point, row 5 = direction plane]

Behavior:
1. User selects datum points for hole locations
2. User selects datum plane for hole direction (optional - could use default)
3. Script creates independent hole features at each location
4. All holes inherit complex threading/counterbore from template
```

---

## Conclusion

This reference guide captures the essential knowledge for creating Creo mapkey automation scripts using PowerShell and the VB API. The combination of programmatic selection with recorded user actions provides a powerful and accessible automation platform that works within standard Creo licensing constraints.

**Key Resources**:
- **[TEMPLATE.PS1](TEMPLATE.PS1)**: Comprehensive starting point for all new automation scripts
- **Existing Scripts**: Proven examples of different automation approaches (thickenator.ps1, nodelator.ps1, etc.)
- **This Guide**: Complete reference for patterns, techniques, and troubleshooting

The patterns and techniques documented here have been proven in production use for NGS Orthogrid automation and can be adapted for a wide variety of Creo automation tasks.

---

**Document Version**: 1.0
**Last Updated**: January 2026
**Author**: Compiled from Blue Origin NGS Orthogrid Automation Toolkit
**Repository**: `creo_automation_sandbox`