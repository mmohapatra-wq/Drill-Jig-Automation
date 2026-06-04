# NGS Orthogrid Automation

## Repo Overview
Hybrid `.cmd` scripts (batch wrapper + PowerShell body) that automate Creo Parametric via the VB API (pfcls COM objects). Each script connects to a live Creo session, performs an operation, then disconnects.

## Script Conventions
- All scripts use the same CMD/PowerShell hybrid header (lines 1-6)
- All scripts suppress `visible_mapkeys` and `dynamic_preview` at start, restore in a `finally` block
- All scripts connect via `pfcls.pfcAsyncConnection` → `.Connect()` → `.Session` → `.GetActiveModel()`
- VB API registration is checked/performed automatically on first run via `vb_api_register.bat`
- Creo process is found by looking for `xtop.exe`
- Selection buffer read via `($session.CurrentSelectionBuffer()).Contents`
- Feature/point IDs captured via `$item.SelItem.Id`
- Mapkeys fired via `$session.RunMacro(string)`
- Model change detection via `$model.VersionStamp` — poll until it changes after each `RunMacro`

## VB API vs Mapkeys

Two distinct approaches used across the toolkit:

**Programmatic (VB API)** — reads/writes Creo data directly without touching the UI. Stable across Creo versions. Used for data extraction and geometry traversal (gauginator, radinator scan phase).
- `$model.ListItems(ITEM_BODY)` — enumerate bodies
- `$body.ListSurfaces()` — enumerate surfaces
- `$surface.ListContours()` → `.ListElements()` — enumerate edges
- `$edge.EvalLength()` — edge length
- `$edge.GetCurveDescriptor()` — geometry type (straight vs curved)
- `$edge.Surface1` / `$edge.Surface2` — adjacent surfaces
- `$surface.GetSurfaceDescriptor()` — surface type (0/9=plane, 1=cylinder)
- `$surface.GetOrientation()` — convex (1) vs concave
- `$item.GetMassProperty($null).GravityCenter` — center of gravity

**Mapkeys** — drives the Creo UI by replaying recorded button clicks and widget interactions. Fragile: widget names vary between Creo versions. Used for feature creation (rounds, extrudes, thickens, flips). Always verify widget names with `visible_mapkeys yes` in Creo config.pro when a mapkey stops working.

## VB API Key Facts
- `$dim.Symbol` — dimension name (e.g. `d0`, `d1`)
- `$dim.DimValue` — read/write double. **Write only sticks for feature-level (extrude/depth) dims when sketch is closed.** For sketch dims it accepts the write in-memory but Creo discards it on regen.
- `$dim.DimType` — 0=Linear, 1=Radial, 2=Diameter, 3=Angular
- `$model.GetItemByName(ITEM_DIMENSION, name)` — look up a dim by symbol name
- `$model.Regenerate($null)` — regenerates the part
- `$session.GetActiveModel()` — returns the **sketch model** when a sketch is open, the part model otherwise
- `$sketchModel.Regenerate($null)` — solves the sketch in place and marks it dirty (required before closing sketch for changes to propagate)

## VB API Documentation
When writing or debugging Creo VB API code, consult the vb-docs MCP server
(`mcp__vb-docs__*`) to verify method signatures, parameters, and return types
before relying on memory.

## Mapkey Patterns

**Select by ID (tree search):**
```
~ Command `ProCmdMdlTreeSearch`;
~ Open `selspecdlg0` `SelOptionRadio`;
~ Close `selspecdlg0` `SelOptionRadio`;
~ Select `selspecdlg0` `SelOptionRadio` 1 `<type>`;   # Feature / Point / Edge / Surface / Component
~ Select `selspecdlg0` `RuleTab` 1 `Misc`;
~ Update `selspecdlg0` `ExtRulesLayout.ExtBasicIDLayout.InputIDPanel` `<id>`;
~ Activate `selspecdlg0` `EvaluateBtn`;
~ Activate `selspecdlg0` `ApplyBtn`;
~ Activate `selspecdlg0` `CancelButton`;
```

**Mini-dashboard done/cancel:**
```
~ Activate `main_dlg_cur` `dashInst0.Done`;
~ Activate `main_dlg_cur` `dashInst0.Quit`;
```

**Clear selection buffer:**
```
~ Activate `main_dlg_cur` `buffer_clean`;
```

**Open sketcher on a plane (confirmed):**
```
~ Command `ProCmdDatumSketCurve`;
@PAUSE_FOR_SCREEN_PICK                          ← user picks sketch plane
~ Trigger `Odui_Dlg_00` `t1.PlnMru` `0`;       ← select plane from MRU
~ Trigger `Odui_Dlg_00` `t1.PlnMru` ``;
~ Trigger `Odui_Dlg_00` `t1.RefMru` `0`;       ← select orientation reference from MRU
~ Trigger `Odui_Dlg_00` `t1.RefMru` ``;
~ Activate `Odui_Dlg_00` `stdbtn_1`;           ← enter sketcher
```

**Sketch dimension input (confirmed):**
```
~ Command `ProCmdSketDimension` 1;
@PAUSE_FOR_SCREEN_PICK                          ← pick entity to dimension
~ Update `main_dlg_cur` `mod_dim_emb` `<value>`;
~ Activate `main_dlg_cur` `mod_dim_emb`;
```

**Sketch tools (confirmed):**
```
~ Command `ProCmdSketRectangle` 1;              ← corner rectangle
~ Command `ProCmdSketCenterRectangle` 1;        ← center rectangle
~ Command `ProCmdSketGeomPoint` 1;              ← sketch point (requires screen pick)
~ Command `ProCmdSketDone`;                     ← exit sketcher
```

**Extrude depth (confirmed):**
```
~ Command `ProCmdFtExtrude`;
~ Update `main_dlg_cur` `GrmTextTagEmbedMRU` `<depth>`;
~ Activate `main_dlg_cur` `GrmTextTagEmbedMRU`;
~ Activate `main_dlg_cur` `dashInst0.Done`;
```

Note: `@PAUSE_FOR_SCREEN_PICK` lines require actual mouse coordinates and cannot be driven programmatically. `~ Trail` lines are dragger/mouse noise — skip them in scripts. `~ Move` lines are dialog repositioning — skip them too.

## Scripts

### gauginator.cmd
Extracts all dimensions from solid bodies and exports to CSV.

**Flow:**
1. Get active model
2. List solid bodies via `ITEM_BODY`
3. Per body: extract CG via `GetMassProperty().GravityCenter`
4. Per body: get child features, list dims via `ListSubItems(ITEM_DIMENSION)`
5. Per dim: read Symbol, DimValue, DimType → build row
6. Export via `Export-Csv -NoTypeInformation` to `.\<modelname>.csv`

**Output CSV columns:** `BodyID, Dim_Type, Dim_Name, Value, GravityCenterX, GravityCenterY, GravityCenterZ`

Note: CG is per-body — every dim from the same body shares the same X/Y/Z values. Dimension order within a feature is Creo's internal storage order, not creation order — do not rely on it.

### diminator.cmd
Reads a gauginator CSV and writes dimension values back into the same Creo model.

**Flow:**
1. Prompt for CSV path, import and detect column names case-insensitively
2. Connect to Creo, get active part model
3. Parse and validate all rows, look up each dim by `Dim_Name` via `GetItemByName`
4. **Pass 1:** Set `DimValue` on all dims blindly → `$model.Regenerate($null)` → re-read each dim after regen to check if value stuck
5. **Pass 2 (sketch dims):** Any dim that snapped back gets collected. Script prompts user to open the sketch in Creo, then presses Enter. Script calls `$session.GetActiveModel()` to get the sketch model, sets `DimValue` on dims from the sketch model, calls `$sketchModel.Regenerate($null)` to solve and mark dirty, prompts user to close sketch, then calls `$model.Regenerate($null)` on the part.

**Known issues / development history:**
- `$row.Dim_Name` returns null if accessed directly — PowerShell CSV property access is case-sensitive. Fix: detect column names at runtime with `$rows[0].PSObject.Properties.Name` and `-ieq`.
- `$dim.Value = x` throws "Index was outside bounds of array" — `Value` expects an `IpfcParamValue` COM object. Use `$dim.DimValue = x` instead.
- `$dim.DimValue` after a write always reflects what you wrote in-memory — cannot be used as a truth check. Only re-reading after `Regenerate` tells you if the change actually stuck.
- `ITEM_PARAM` + `CreateDoubleParamValue` does not work for dimensions.
- `$model.ModifyDimension()` is not available on this API version.
- When sketch is open, `$session.GetActiveModel()` returns the sketch — must fetch dims from sketch model, not part model.
- Must call `$sketchModel.Regenerate($null)` while sketch is still open or Creo reports "Part not changed since last regen" and discards the edits.

**Current status:** Pass 1 (feature/extrude dims) confirmed working. Pass 2 (sketch dims with sketch-open flow + sketch regen) applied but not yet confirmed working.

### nodelator.cmd
Copies an example node feature (extrude set to create new body) to multiple datum point locations using paste-by-reference.

**Flow:**
1. User selects example node feature → capture feature ID
2. User selects all target datum points → capture point IDs
3. Copy feature once via `ProCmdEditCopy`
4. For each point: `ProCmdEditPasteSpecial` → paste by reference → reroute datum point reference in `Odui_Dlg_00` ext_ref_table → confirm

**Key requirement:** The example extrude must reference the datum point (sketch origin or placement reference). If the extrude just happens to sit near a point geometrically, paste-by-reference has nothing to reroute.

**Paste-by-reference ext_ref_table row sequence** (specific to node extrude reference structure — will differ for other feature types):
```
~ Trigger `Odui_Dlg_00` `t1.ext_ref_table` 2 `5` `ext_ref_list`;
~ Trigger `Odui_Dlg_00` `t1.ext_ref_table` 2 `4` `ext_ref_list`;
~ Select  `Odui_Dlg_00` `t1.ext_ref_table` 2 `4` `ext_ref_list`;
~ Trigger `Odui_Dlg_00` `t1.ext_ref_table` 2 `3` `ext_ref_list`;
~ Trigger `Odui_Dlg_00` `t1.ext_ref_table` 2 `2` `ext_ref_list`;
~ Trigger `Odui_Dlg_00` `t1.ext_ref_table` 2 `` ``;
~ Activate `Odui_Dlg_00` `t1.body_add_chk_btn` 1;
~ Trigger `Odui_Dlg_00` `t1.ext_ref_table` 2 `5` `ext_ref_list`;
~ Select  `Odui_Dlg_00` `t1.ext_ref_table` 2 `5` `ext_ref_list`;
~ Trigger `Odui_Dlg_00` `t1.ext_ref_table` 2 `` ``;
```

### flipenator.cmd
Flips the material direction of selected solid bodies.

**Flow:**
1. User selects solid bodies → capture both body IDs and feature IDs (`$item.SelItem.getFeatures()`)
2. For each feature: select by ID → `ProCmdRedefine@PopupMenuGraphicWinStack` → `maindashInst0.Flip` → `dashInst0.Done`
3. After all flips: re-select original bodies by body ID so user can see results

Note: body ID and feature ID are different — flip operates on the feature, final re-selection uses body ID.

### radinator.cmd
Applies rounds to node-to-stiffener edges matching a specified length range.

**Flow:**
1. User inputs edge length target (single + tolerance or min/max range) and radius value
2. **Scan phase (pure VB API):** traverse all bodies → surfaces → contours → edges. Per edge:
   - Check length is within range
   - Check edge is straight (`GetCurveDescriptor()` has endpoints)
   - Check one adjacent surface is a convex cylinder (type=1, orientation=1) and the other is a plane (type=0 or 9)
   - Check cylinder radius ≤ 0.875 in
3. **Round phase (mapkeys):** batch matched edges into groups of 40. Per batch: open tree search once, add each edge ID to selection buffer, close search, fire `ProCmdRound` with radius → `dashInst0.Done`

Round mapkey (confirmed working):
```
~ Activate `main_dlg_cur` `page_Model_control_btn` 1;
~ Command `ProCmdRound`;
~ Input  `main_dlg_cur` `maindashInst0.cir_rad_list` `<radius>`;
~ Update `main_dlg_cur` `maindashInst0.cir_rad_list` `<radius>`;
~ Activate `main_dlg_cur` `maindashInst0.cir_rad_list`;
~ Activate `main_dlg_cur` `dashInst0.Done`;
```

Supports `-v` / `--verbose` flag for edge/radius distribution breakdown.

### gripenator.cmd
Interactive menu tool for managing HST fasteners in an assembly.

**Flow:** Interactive loop with four commands:
- **F (Filter):** reads selection buffer, validates part numbers against HST regex, re-selects only valid fasteners
- **C (Change):** prompts for new diameter/grip codes, groups fasteners by coating, calls `ProCmdReplComp` to replace each group with the new part number. Also updates matching nuts.
- **G (Ground):** same as Change but forces coating to `GD`
- **E (Exit):** disconnects

Part numbers parsed via regex: `^HST(12|13|54|59)(coating)(\d{1,2})-(\d{1,2})$` for fasteners, `^HST1078(coating)(\d{1,2})$` for nuts.
Component IDs extracted from `$item.Path.ComponentIds[0]`, part numbers from `$item.SelectionString` (format: `assembly.asm:partnumber<template>.prt(#id)`).

### surfenator.cmd
Creates surface extrusions from 3D curves between two datum planes.

**Flow:**
1. User selects 3D curves, a midplane (sketch plane), top plane, bottom plane
2. Per curve: project curve onto midplane → create extrude feature from top to bottom plane → surface output

### thickenator.cmd
Thickens surface quilts into solid bodies.

**Flow:**
1. User selects quilts
2. Per quilt: select by ID → `ProCmdFtThicken` → set thickness → `dashInst0.Done`

Thicken mapkey (confirmed working):
```
~ Command `ProCmdFtThicken`;
~ Enter  `main_dlg_cur` `dashInst0.Quit`;
~ Exit   `main_dlg_cur` `dashInst0.Quit`;
~ Activate `main_dlg_cur` `maindashInst0.Flip`;
~ Activate `main_dlg_cur` `maindashInst0.Flip`;
~ Input  `main_dlg_cur` `maindashInst0.Thickness` `<value>`;
~ Activate `main_dlg_cur` `maindashInst0.Thickness`;
~ Activate `main_dlg_cur` `chkbn.body_page.0` 1;
~ Activate `body_page.0.0` `PH.bodyusechkbtnrepwdg` 1;
~ Activate `main_dlg_cur` `dashInst0.Done`;
```

### boxinator.cmd
Creates a rectangular extruded solid with exact width/height/depth. The inline `mod_dim_emb` (sketch) and `GrmTextTagEmbedMRU` (depth) writes create the geometry; a unified 2-pass verify/repair (mirrors diminator) is layered on top so a no-op'd mapkey can never report success on a wrong-sized box.

**Flow:**
1. User inputs width, height, depth
2. User selects sketch plane → script selects it by ID (tree search) → opens sketcher → activates center-rectangle tool
3. User draws a rough rectangle (2 clicks)
4. **Capture at placement:** user dimensions WIDTH then HEIGHT in fixed order; after each placement the script reads the selection buffer to bind that dim's `Symbol` into a `$dimPlan` entry. `mod_dim_emb` write remains the primary set.
5. Exit sketcher → `ProCmdFtExtrude` with `GrmTextTagEmbedMRU` depth. Depth dim located via a before/after `ListFeaturesByType(FEATTYPE_PROTRUSION)` ID diff (lone Linear `ListSubItems` dim), recorded into `$dimPlan` as a feature dim.
6. **Pass 1:** assert every captured symbol via `DimValue` + `$model.Regenerate($null)` + readback. Sticks → OK; snaps back → collected for repair.
7. **Pass 2 (sketch dims only):** prompt user to open the sketch, `$session.GetActiveModel()` → set `DimValue` on sketch model → `$sketchModel.Regenerate($null)` while open → prompt close → `$model.Regenerate($null)` → reread to confirm (REPAIRED / FAILED).
8. Report per-role OK / REPAIRED / FAILED / UNVERIFIED; counts mapkey failures; green "Done" only if all dims confirmed, else a yellow "NOT fully confirmed" warning.

**Key facts:**
- No VB API property distinguishes the width edge from the height edge — `DimType` is Linear for both and `ListSubItems` order is unreliable. Hence the fixed pick order + selection-buffer capture.
- Center-rectangle sketch dims are FULL values (not halved).
- Depth is a feature-level dim, so its `DimValue` write sticks in Pass 1; width/height are sketch dims and typically need the Pass 2 sketch-open repair.

**Current status:** 2-pass restructure applied and parses clean. The capture-at-placement selection-buffer step is **not yet confirmed against a live Creo session** — verify the buffer holds exactly the just-placed dim and `$item.Symbol` resolves; run with distinct W/H/D and deliberately swap edges to confirm the report flags a mismatch.
