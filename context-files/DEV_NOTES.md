# NGS Orthogrid Automation — Dev Notes

## Repo Overview
Hybrid `.cmd` scripts (batch wrapper + PowerShell body) that automate Creo Parametric via the VB API (pfcls COM objects). Each script connects to a live Creo session, performs an operation, then disconnects.

## Script Conventions
- All scripts use the same CMD/PowerShell hybrid header (lines 1-6)
- All scripts suppress `visible_mapkeys` and `dynamic_preview` at start, restore in `finally` block
- Connect via `pfcls.pfcAsyncConnection` → `.Connect()` → `.Session` → `.GetActiveModel()`
- VB API registration auto-runs `vb_api_register.bat` on first use
- Creo process found by looking for `xtop.exe`
- Selection buffer: `($session.CurrentSelectionBuffer()).Contents`
- Feature/point IDs: `$item.SelItem.Id`
- Mapkeys fired via: `$session.RunMacro(string)`
- Model change detection: poll `$model.VersionStamp` after each `RunMacro`

---

## VB API vs Mapkeys

**Programmatic (VB API)** — reads/writes Creo data directly, no UI. Stable across Creo versions.
- `$model.ListItems(ITEM_BODY)` — enumerate bodies
- `$body.ListSurfaces()` — enumerate surfaces
- `$surface.ListContours()` → `.ListElements()` — enumerate edges
- `$edge.EvalLength()` — edge length
- `$edge.GetCurveDescriptor()` — geometry type (straight vs curved)
- `$edge.Surface1` / `.Surface2` — adjacent surfaces
- `$surface.GetSurfaceDescriptor()` — surface type (0/9=plane, 1=cylinder)
- `$surface.GetOrientation()` — convex (1) vs concave
- `$item.GetMassProperty($null).GravityCenter` — center of gravity
- `$model.Regenerate($null)` — regenerate part
- `$session.GetActiveModel()` — returns sketch model when sketch is open, part model otherwise
- `$feat.ListSubItems(ITEM_DIMENSION)` — get all dims from a feature (**use this, not ListItems**)
- `$model.GetItemByName(ITEM_DIMENSION, symbol)` — look up dim by symbol name

**Mapkeys** — drives Creo UI by replaying widget interactions. Fragile: widget names vary between versions. Always verify with `visible_mapkeys yes` in config.pro when something stops working.

---

## Dimension Rules (Critical)

- `$dim.DimValue` — read/write. **Writes only stick for feature-level dims (extrude depth, etc.) when sketch is closed.** For sketch dims, Creo discards the write on regen.
- `$dim.DimType` — 0=Linear, 1=Radial, 2=Diameter, 3=Angular
- `$dim.Symbol` — name like `sd0`, `sd1`, `d0`
- **Do NOT use `ListItems(ITEM_DIMENSION)` on a sketch model** — returns 0 results. Use `ListSubItems(ITEM_DIMENSION)` on the feature from the part model instead, then look up by symbol via `GetItemByName` on the sketch model.
- **To modify sketch dims:** open the sketch in Creo, call `$session.GetActiveModel()` to get sketch model, look up dims by symbol with `GetItemByName`, set `DimValue`, call `$sketchModel.Regenerate($null)` while sketch is still open, close sketch, call `$model.Regenerate($null)` on part.
- Sketch dim values for center rectangle are **full values** (e.g. width=400, not 200). `mod_dim_emb` also uses full values — confirmed from mapkey recording.

---

## Confirmed Mapkey Widget Names

### Selection (tree search)
```
~ Command `ProCmdMdlTreeSearch`;
~ Open `selspecdlg0` `SelOptionRadio`;
~ Close `selspecdlg0` `SelOptionRadio`;
~ Select `selspecdlg0` `SelOptionRadio` 1 `<type>`;   # Feature / Point / Edge / Surface / Datum Plane / Component / Dimension
~ Select `selspecdlg0` `RuleTab` 1 `Misc`;
~ Update `selspecdlg0` `ExtRulesLayout.ExtBasicIDLayout.InputIDPanel` `<id>`;
~ Activate `selspecdlg0` `EvaluateBtn`;
~ Activate `selspecdlg0` `ApplyBtn`;
~ Activate `selspecdlg0` `CancelButton`;
```

### Dashboard done/quit
```
~ Activate `main_dlg_cur` `dashInst0.Done`;
~ Activate `main_dlg_cur` `dashInst0.Quit`;   # dismiss mini toolbar
~ Enter `main_dlg_cur` `dashInst0.Quit`;       # thickenator pattern
~ Exit  `main_dlg_cur` `dashInst0.Quit`;
```

### Clear selection buffer
```
~ Activate `main_dlg_cur` `buffer_clean`;
```

### Open sketcher on a plane (confirmed from recording)
```
~ Command `ProCmdDatumSketCurve`;
~ Trigger `Odui_Dlg_00` `t1.PlnMru` `0`;       # select plane from MRU
~ Trigger `Odui_Dlg_00` `t1.PlnMru` ``;
~ Trigger `Odui_Dlg_00` `t1.RefMru` `0`;       # select orientation reference from MRU
~ Trigger `Odui_Dlg_00` `t1.RefMru` ``;
~ Activate `Odui_Dlg_00` `stdbtn_1`;           # enter sketcher
```
*Pre-select the plane via tree search before running ProCmdDatumSketCurve so it appears in the MRU.*

### Sketch tools (confirmed)
```
~ Command `ProCmdSketRectangle` 1;              # corner rectangle (2 screen picks)
~ Command `ProCmdSketCenterRectangle` 1;        # center rectangle (2 screen picks)
~ Command `ProCmdSketGeomPoint` 1;              # sketch point (1 screen pick)
~ Command `ProCmdSketDimension` 1;              # dimension tool (screen picks + mod_dim_emb)
~ Command `ProCmdSketDone`;                     # exit sketcher
```

### Sketch dimension input (confirmed from recording)
```
~ Update `main_dlg_cur` `mod_dim_emb` `<value>`;   # FULL value (not halved)
~ Activate `main_dlg_cur` `mod_dim_emb`;
```
*Fires after picking an entity with the dimension tool. Also fires on double-click of existing dim.*

### Extrude (confirmed from recording)
```
~ Command `ProCmdFtExtrude`;
# Wait ~800ms for dashboard to load before setting depth
~ Update `main_dlg_cur` `GrmTextTagEmbedMRU` `<depth>`;
~ Activate `main_dlg_cur` `GrmTextTagEmbedMRU`;
~ Activate `main_dlg_cur` `dashInst0.Done`;
```

### Round (confirmed working)
```
~ Activate `main_dlg_cur` `page_Model_control_btn` 1;
~ Command `ProCmdRound`;
~ Input  `main_dlg_cur` `maindashInst0.cir_rad_list` `<radius>`;
~ Update `main_dlg_cur` `maindashInst0.cir_rad_list` `<radius>`;
~ Activate `main_dlg_cur` `maindashInst0.cir_rad_list`;
~ Activate `main_dlg_cur` `dashInst0.Done`;
```

### Thicken (confirmed working)
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

### Hole (confirmed from recording)
```
~ Command `ProCmdHole`;                                         # NOT ProCmdHoleCreate
~ Trigger `hole_fb_plcmnt_page.0.0` `PH.sketch_rep_list` `0`;  # select sketch for placement
~ Trigger `hole_fb_plcmnt_page.0.0` `PH.sketch_rep_list` ``;
~ Activate `main_dlg_cur` `dashInst0.Done`;
```
*Hole placement is sketch-driven: create a sketch with a point on the surface first, then ProCmdHole picks it up automatically. Hole parameter widget names (diameter, depth) not yet confirmed — record with visible_mapkeys yes.*

### Paste-by-reference (nodelator — node extrude specific)
```
~ Command `ProCmdEditPasteSpecial`;
~ Activate `paste_special` `makecopyiesPB` 0;
~ Activate `paste_special` `pastebyrefPB` 1;
~ Activate `paste_special` `okPB`;
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
*Row numbers are specific to node extrude reference structure. Different feature types will have different rows.*

---

## Trail File Notes
- `@PAUSE_FOR_SCREEN_PICK` — requires actual mouse coordinates, cannot be driven programmatically
- `~ Trail` lines — dragger/mouse drag noise, skip in scripts
- `~ Move` lines — dialog repositioning, skip in scripts
- `~ Key` lines with single characters — keyboard shortcuts (e.g. `D` for dimension tool)

---

## Scripts

### gauginator.cmd
Extracts all dimensions from solid bodies → CSV.
- `ListItems(ITEM_BODY)` → `GetMassProperty().GravityCenter` → `ListSubItems(ITEM_DIMENSION)`
- Output: `.\<modelname>.csv` — columns: `BodyID, Dim_Type, Dim_Name, Value, GravityCenterX/Y/Z`
- Dim order is Creo's internal order, not creation order — do not rely on it

### diminator.cmd
Reads gauginator CSV → writes dim values back into Creo.
- Pass 1: set `DimValue` on all dims → `Regenerate` → re-read to check if stuck
- Pass 2: sketch dims that snapped back — user opens sketch, script uses `GetItemByName` on sketch model, sets `DimValue`, calls `$sketchModel.Regenerate($null)`, user closes sketch, `$model.Regenerate($null)`
- **Known:** `$dim.Value = x` throws (expects COM object). Use `$dim.DimValue = x`
- **Known:** CSV property access is case-sensitive — use `$rows[0].PSObject.Properties.Name` + `-ieq` to detect column names
- **Status:** Pass 1 confirmed working. Pass 2 applied, not yet confirmed.

### nodelator.cmd
Copies example node extrude (create-new-body) to multiple datum points via paste-by-reference.
- Requires: example feature references datum point as placement reference
- Flow: copy feature once → loop: paste special → reroute datum point reference → confirm

### flipenator.cmd
Flips material direction of selected solid bodies.
- Captures body IDs AND feature IDs separately (`$item.SelItem.getFeatures()`)
- Flip operates on the feature; final re-selection uses body ID

### radinator.cmd
Applies rounds to node-to-stiffener edges matching a length range.
- Scan (VB API): traverse bodies→surfaces→contours→edges, filter by length + straight + convex-cylinder-meets-plane geometry + cylinder radius ≤ 0.875 in
- Round (mapkeys): batch 40 edges → tree search accumulates selection → ProCmdRound → Done
- Supports `-v` / `--verbose` flag

### gripenator.cmd
Interactive tool for HST fastener management in assemblies.
- F=Filter, C=Change diameter/grip, G=Ground (force GD coating), E=Exit
- Part numbers from `$item.SelectionString` format: `assembly.asm:partnumber<template>.prt(#id)`
- Replace via `ProCmdReplComp@PopupMenuGraphicWinStack`

### surfenator.cmd
Creates surface extrusions from 3D curves between datum planes.

### thickenator.cmd
Thickens surface quilts into solid bodies using ProCmdFtThicken.

### boxinator.cmd
Creates a rectangular extruded solid with exact dimensions. Inline `mod_dim_emb` writes are the primary mechanism; a unified diminator-style 2-pass verify/repair is layered on top so a no-op'd write can never report a green "Done" on a wrong-sized box.
- User inputs width, height, depth
- Script: selects plane via tree search → opens sketcher → activates center rectangle tool
- User: draws rough rectangle (2 clicks)
- **Capture at placement:** user dimensions WIDTH then HEIGHT (fixed order); after each placement the script reads the selection buffer (`Get-PlacedDimSymbol`) to bind that dim's `Symbol` into `$dimPlan`. The `mod_dim_emb` write is still the primary set. Warns + marks UNVERIFIED if a symbol can't be resolved or if height's symbol collides with width's.
- Depth: before/after `ListFeaturesByType(FEATTYPE_PROTRUSION)` ID diff locates the new extrude feature; its lone Linear `ListSubItems` dim is recorded into `$dimPlan` as a feature dim. Warns on >1 new protrusion or >1 Linear dim (no silent guess).
- **2-pass (modeled on diminator):** Pass 1 asserts every captured symbol via `DimValue` + `$model.Regenerate($null)` + readback (catches depth and any sketch dim that sticks). Pass 2 repairs snapped-back sketch dims via the sketch-open flow (`GetActiveModel` → set on sketch model → `$sketchModel.Regenerate($null)` while open → user closes → `$model.Regenerate($null)` → reread to confirm). Each entry ends OK / REPAIRED / FAILED / UNVERIFIED.
- Report: per-role status; counts `$script:macroFailures` from `Invoke-Macro`; green "Done" gated on all dims confirmed, else yellow "NOT fully confirmed" listing the bad roles.
- **Unconfirmed (needs live Creo):** the capture-at-placement selection-buffer step — verify the buffer holds exactly the just-placed dim and `$item.Symbol` resolves. Run with distinct W/H/D (e.g. 4/7/2), confirm the console echoes each captured symbol, and deliberately swap edges to confirm the report flags a mismatch rather than silently passing.
