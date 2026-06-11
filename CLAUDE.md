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
- `$model.Regenerate($null)` — **automatic (incremental)** regen. Can leave a freshly-written feature dim unpropagated — the symptom being a box whose new depth only updates after a manual edit/reopen of the feature's sketch.
- **Forced regen** — to make a `DimValue` write take effect immediately, pass a `RegenInstructions` object instead of `$null`:
  ```powershell
  $regenCls = New-Object -ComObject pfcls.pfcRegenInstructions   # CLASS object (holds static Create factory)
  $instr    = $regenCls.Create($false, $true, $null)             # Create(AllowFixUI, ForceRegen, FromFeat)
  $model.Regenerate($instr)
  ```
  - **ProgID is `pfcls.pfcRegenInstructions`, NOT `pfcls.CCpfcRegenInstructions`.** The latter is unregistered — `New-Object` on it throws `0x80040154 REGDB_E_CLASSNOTREG` (all-zeros CLSID). The docs name the factory `CCpfcRegenInstructions.Create()`, but the COM projection lives as the static `Create` method on the `pfcRegenInstructions` class object. The `CC*` factory names are a general gotcha — they are never standalone ProgIDs.
  - `Create()` returns the instance; its 8 settable properties are `AllowFixUI, ForceRegen, FromFeat, RefreshModelTree, ResolveModeRegen, ResumeExcludedComponents, UpdateAssemblyOnly, UpdateInstances` (confirmed by COM member inspection). These do NOT exist on the class object — only on the `Create()` return value.
  - `Regenerate(<non-null instr>)` throws `IpfcXToolkitBadContext` if Creo runs in **No-Resolve mode** (the default in Creo Elements/Pro). Always wrap forced regen in try/catch and fall back to `$model.Regenerate($null)`.
  - **Do NOT try to enable the forced path via `regen_failure_handling = resolve_mode`.** That config option is **deprecated** on current Creo builds — calling `SetConfigOption` on it pops a blocking *"to use a deprecated config option you will need to supply an authorization code with allow deprecated config (CS260154)"* dialog that stalls the entire automation run. There is no programmatic way to dismiss it. Accept the automatic-regen fallback instead, and make feature dims reliable by writing the feature-level `DimValue` directly (it sticks on a closed sketch regardless of regen mode).
- `$session.GetActiveModel()` — returns the **sketch model** when a sketch is open, the part model otherwise
- `$sketchModel.Regenerate($null)` — solves the sketch in place and marks it dirty (required before closing sketch for changes to propagate)
- `$solid.EvalOutline($null, $null)` → `IpfcOutline3D`, a 2-element sequence of corner `Point3D`s (min, max). The three axis extents (|Δx|, |Δy|, |Δz|) ARE the solid's real width/height/depth — independent of any dimension symbol. `$solid.GetOutline()` is the regeneration-outline fallback. Point3D components read via `$p[0..2]` bracket indexing (confirmed) or `.Item(i)`.

## VB API Documentation
When writing or debugging Creo VB API code, consult the vb-docs MCP server
(`mcp__vb-docs__*`) to verify method signatures, parameters, and return types
before relying on memory.

## Shared Library (`lib\`)
Dot-sourceable PowerShell modules that end the copy-paste of geometric-read code across the
`.cmd` tools. Load them inside the hybrid header pattern after `$ScriptDir` is set:
```powershell
. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')
. (Join-Path $ScriptDir 'lib\blind_evaluator.ps1')
```
- **`lib\creo_geometry.ps1`** — pure READS, no mutation. `Get-Comp`, `Dot`, `Dist-PointToAxis`,
  `New-ExcludeTypes`, `Get-OutlineExtents`, `Measure-Extents` (was boxinator's `Measure-BoxExtents`),
  `Get-AllSurfaces`, `Count-Cylinders`, `Get-CylinderAxes`, `Get-LinearDimMap`, `Read-DimValue`.
  Each takes its COM objects as params (no module-level `$session`/`$model`) so it loads in a
  plain host with stubbed objects for the unit tests.
- **`lib\blind_evaluator.ps1`** — the convergence layer (below).
- **`lib\tests\run_tests.ps1`** — offline unit tests (no Creo, no network). Run:
  `powershell -ExecutionPolicy Bypass -File lib\tests\run_tests.ps1` (exit 0 = all pass).

## Blind Evaluator / Convergence Layer
Adapts mlogsdon's PLC "blind evaluator" idea (see `docs\blind_evaluator_architecture.md`) to
Creo: **derive a claim cheaply, then converge by checking it against a narrowly-sliced ground
truth with a judge that never saw HOW the claim was produced** — to catch *bad generalizations*
(the silent-wrong-dim / wrong-feature / mis-classified-edge class this toolkit keeps hitting).

**Loop:** tool states a CLAIM from the user's INTENT (`New-EvalClaim` — the value you ASKED for,
NOT a value re-read from the model; re-reading makes the check outcome-vs-outcome and a
self-consistent wrong result passes) → measure only the in-scope geometry into a SLICE
(`Get-GeometrySlice`; `Measure-Extents`/`Count-Cylinders`/`Read-DimValue` — and NOTHING about
mapkeys/heuristics/axis maps, that omission is what makes the judge blind) → `Write-EvalPacket`
to `<model>_eval.json` (durable, repo-convention artifact like the gauginator/datinator CSVs) →
`Invoke-BlindJudge` → `Show-ConvergenceReport` returns a bool the caller uses to gate green "Done".

**Two gating layers (deliberate):**
- **Deterministic numeric (`Test-ExtentsMatch`, in `creo_geometry.ps1`)** owns the ARITHMETIC. A
  by-value, tolerance-based, multiset match (each measured value consumed once) — order-
  independent so a W/H/D swap still matches the right values. Same geometry → same verdict every
  run. When a numeric result is passed to `Show-ConvergenceReport -Numeric`, **it is the gate.**
- **LLM (`Invoke-BlindJudge`)** owns the SEMANTICS + narration. In numeric-gated mode the LLM is
  ADVISORY: a disagreement with the measurement is surfaced loudly (worth a human's eye) but does
  NOT flip the gate — a flaky/over-eager LLM can't green-light a geometric mismatch, and a gateway
  outage can't fail a measurably-correct result. With NO numeric layer (a purely-semantic claim
  like radinator's "is this really a node fillet?"), the LLM verdict IS the gate.

**Transport (verified live 2026-06-11):** BlueGPT is LiteLLM-fronted / OpenAI-compatible —
`POST {base}/v1/chat/completions`, `Authorization: Bearer <token>`, `response_format` =
`json_schema` (strict). `Get-JudgeConfig` resolves `{base,token,model}` from, in order: a
gitignored `.bluegpt_judge.json`, then `ANTHROPIC_BASE_URL`+`ANTHROPIC_AUTH_TOKEN` (already set
for Claude Code on this machine → `https://litellm.leap.blueorigin.com`), then
`BLUEGPT_API_BASE`+`BLUEGPT_API_KEY`. If none resolve, the packet is still written and the REST
call is skipped — the tool degrades to offline-judge, never fails. Validate the gateway in
isolation with `--probe-judge` (`Invoke-JudgeProbe`): sends a synthetic true+false packet and
expects confirm+refute.

**Key facts:**
- Claims encode INTENT (the asked-for value), are atomic ("the box width is 4.0"), and match
  **by VALUE** never by axis order — so a width/height/depth swap is still caught.
- A slice must carry measured geometry ONLY. The unit tests assert no mapkey/heuristic text
  (`RunMacro`, `ProCmd`, `dashInst`, `DimValue write`, ...) leaks into the judge input.
- Numeric truth comes from `EvalOutline`/COM via `Test-ExtentsMatch` (deterministic, the gate).
  The LLM never does the arithmetic — its job is the *semantic* call ("is this really a node
  fillet / is anything a bad generalization") and the human-readable summary. A verification gate
  that can flicker run-to-run is corrosive; keeping the gate deterministic fixes that.
- **A blind evaluator only earns its keep if the slice gives the judge signal the tool did NOT
  already use.** For a numeric claim, the new signal is the independent `EvalOutline` measurement
  vs. the asked-for value. For radinator, the slice must carry MORE than the heuristic's own
  inputs (local topology / neighbors / structural context) — feeding it back the same four facts
  that selected the edge is verification theater (the judge just re-runs a fuzzier copy of the
  rule). This is the make-or-break constraint for the semantic-judge tools.
- `*_eval.json` and `.bluegpt_judge.json` are gitignored.

**Wired:** `plane-probe.cmd` (build + per-resize; deterministic-gated, LLM advisory; claims use the
entered offsets). **Next (contracts in the memo):** radinator (semantic-gated — judge re-decides
each matched edge is really a node-to-stiffener fillet, slice MUST exceed the heuristic's inputs),
holeinator (numeric-gated cylinder count, judged independently of its own surface walk).

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
~ Enter `main_dlg_cur` `dashInst0.Quit`;
~ Exit  `main_dlg_cur` `dashInst0.Quit`;
~ Activate `main_dlg_cur` `dashInst0.Done`;
```

**CRITICAL: fire the entire dashboard sequence (open → depth → confirm) in ONE atomic `RunMacro` string.** A dashboard tool's command context does NOT survive across separate `RunMacro` calls — if you open the extrude in one call, set depth in another, and fire `dashInst0.Done` in a third, the confirm fires into a dashboard Creo has already lost track of and is **silently dropped** (no error), leaving the dashboard open and stalling the regen. Concatenate the whole sequence and pass it as a single `RunMacro`, exactly like thickenator's proven pattern. The `~ Enter`/`~ Exit` on `dashInst0.Quit` are hover events (NOT `~ Activate`) that blur the depth field so `Done` lands — they do not cancel anything.

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
Creates a rectangular extruded solid with exact width/height/depth. The mapkey writes (`mod_dim_emb` for the sketch, the authoritative depth `DimValue` for the feature) create the geometry; verification is **geometric** — the script measures the finished solid with `EvalOutline` and asserts the three real extents equal the three requested sizes. No dimension symbols are captured or bound.

**Why geometric, not symbol-based:** the original script tried to prove correctness by capturing each sketch dim's `Symbol` (`d0`, `d1`, …) from the selection buffer at placement time, then re-asserting those symbols. That binding was never reliable — no VB API property distinguishes the width edge from the height edge (`DimType` is Linear for both; `ListSubItems` order is Creo-internal), so it could silently verify the wrong dim. `EvalOutline` sidesteps the whole problem: it returns the solid's true min/max corners, and the sorted extents ARE the box size regardless of which axis the sketch mapped width/height onto.

**Flow:**
1. User inputs width, height, depth.
2. Script opens the Sketch tool (`ProCmdDatumSketCurve`) → user clicks the plane on screen while the dialog is open (a real pick is what populates the dialog's plane MRU) → presses ENTER → script fires `t1.PlnMru`/`t1.RefMru` + `stdbtn_1` to enter the sketcher → activates center-rectangle tool. **A `RunMacro` string runs atomically and cannot pause mid-sequence for a human pick, so the open is split into two macros around the user's plane click.**
3. User draws a rough rectangle (2 clicks), presses ENTER.
4. Script writes WIDTH then HEIGHT via `mod_dim_emb` (fixed pick order — the user dimensions a horizontal then a vertical edge between prompts).
5. Exit sketcher (`ProCmdSketDone`), then fire the extrude as **one atomic `RunMacro`**: `ProCmdFtExtrude` → `GrmTextTagEmbedMRU` depth → `Enter`/`Exit dashInst0.Quit` (blur the field) → `dashInst0.Done`. The whole sequence MUST be a single macro string — see key fact below. The extrude now confirms and regenerates automatically; no manual dashboard click or ENTER needed.
6. **Authoritative depth:** the dashboard depth field has produced wrong values, so the script finds the new protrusion feature (before/after `ListFeaturesByType(FEATTYPE_PROTRUSION)` ID diff), dumps all its dims, identifies the depth dim by elimination (the Linear dim matching neither width nor height), sets it via `DimValue`, and **forces a regen** (`Invoke-ForceRegen`) so the change propagates without a manual sketch reopen.
7. **Geometric verify:** `Measure-BoxExtents` calls `EvalOutline`, sorts the three measured extents descending, compares to the sorted `{width,height,depth}` target within tol `1e-4`. PASS only if all three match.
8. **Repair (only on mismatch):** depth mismatch is reported (not re-driven — it was already set authoritatively). Width/height mismatch offers a **y/n-gated** guided sketch repair: user opens the sketch, script maps each sketch dim to a target by nearest current value (geometric, not pick-order), writes `DimValue`, `$sketchModel.Regenerate($null)` while open, user closes, `$model.Regenerate($null)`, then **re-measures with EvalOutline** to confirm REPAIRED/STILL MISMATCHED.
9. Final report: green "Done … (measured and confirmed)" only if EvalOutline matches AND `$script:macroFailures -eq 0`; else yellow "NOT confirmed" with measured-vs-requested extents.

**Key facts:**
- Verification is a real measurement of the solid (`EvalOutline`), not a symbol echo. `"Done (confirmed)"` is backed by geometry.
- Sorting both the measured and requested triples means the script never needs to know which axis is width vs height — it asserts "the solid's three extents are W, H, D."
- Center-rectangle sketch dims are FULL values (not halved).
- Depth is a feature-level dim — its `DimValue` write sticks on a closed sketch; width/height are sketch dims that may snap back and need the gated sketch-open repair.
- **Depth reliability comes from the direct feature `DimValue` write, not from regen mode.** After the extrude, the script finds the new feature (type-agnostic — see below), identifies its depth dim by elimination, and writes `DimValue = depth`; that write sticks on a closed sketch. `Invoke-ForceRegen` then *attempts* a forced regen but falls back to automatic regen on No-Resolve sessions. **Do not try to force resolve mode via `regen_failure_handling = resolve_mode` — it is deprecated and pops a blocking authorization dialog (CS260154) that stalls the run (see VB API Key Facts → Forced regen).**
- **Type-agnostic feature lookup:** the new extrude is found by ID-diffing `ListFeaturesByType($FALSE)` (Type arg omitted) before/after the extrude — NOT filtered to `FEATTYPE_PROTRUSION`. A modern Creo extrude is not guaranteed to classify as PROTRUSION; filtering by type risked the new feature never being found, which silently skipped the authoritative-depth write and left depth at the unreliable dashboard value. `Get-AllFeatures` tries the single-arg call plus `$null`/`[Type]::Missing` fallbacks for the optional COM param.
- The guided sketch repair is gated behind an explicit y/n prompt: auto-driving the sketch open/close + regenerate sequence once produced a fatal Creo traceback when the model was half-committed, so it never runs without the user confirming Creo is idle.
- **The extrude fires as ONE atomic `RunMacro` (open → depth → `Enter`/`Exit Quit` → `dashInst0.Done`).** A prior version split open/depth/confirm into three separate `RunMacro` calls; the confirm was silently dropped because a dashboard's command context does not survive across `RunMacro` calls — the extrude dashboard stayed open AND the regen stalled (the half-alive dashboard is what made the regen look "slow"). Consolidating into a single macro (thickenator's proven pattern) makes `dashInst0.Done` land and the regen finish instantly. See Mapkey Patterns → Extrude depth.

**Current status:** Rebuilt around `EvalOutline` geometric verification (symbol-capture machinery removed). Parses clean. Live regressions found and fixed across several passes: (1) **sketch dialog came up with no plane** — the by-ID tree-search pre-select fed the selection buffer but not the dialog MRU; replaced with the confirmed split-macro flow (open Sketch tool → user clicks plane on screen → script enters sketcher). (2) **depth needed a manual reopen** — two independent causes addressed: the extrude was being missed by the `FEATTYPE_PROTRUSION` filter (now type-agnostic ID-diff), and depth is now made correct by the direct feature `DimValue` write rather than relying on regen mode. (3) **`regen_failure_handling = resolve_mode` removed** — it is deprecated on this Creo build and popped a blocking CS260154 authorization dialog that stalled the sketch step. (4) **extrude dashboard would not auto-close + regen looked slow** — the extrude had been split across three separate `RunMacro` calls, so `dashInst0.Done` was silently dropped and the half-alive dashboard stalled the regen; fixed by firing the whole extrude as one atomic `RunMacro` (confirmed live: extrude now confirms automatically and regen completes instantly). Confirm live: sketch dialog populates after the plane click, the extrude opens/sets depth/confirms in one shot with no manual click, depth propagates without a manual reopen, EvalOutline reports PASS, and a deliberate-mismatch negative test FAILS as expected.

**Parametric sketch-dim snap-back (ABANDONED):** A separate effort on this branch tried to drive a box's in-plane SKETCH dims (width/height) from PowerShell and have them survive regen. Four programmatic routes all FAILED — (1) raw `$dim.DimValue` write, (2) in-sketcher `mod_dim_emb` edit, (3) tree-Edit `mod_partdim_emb` (`ProCmdL05Edit@PopupMenuTree`), (4) direct relations `d# = value` via `$model.Relations`. Root cause: a rough rectangle has WEAK dims, so the sketch solver re-derives them from unchanged geometry on regen; routes 1–3 only change the displayed value, and the relations route failed too on this build. Abandoned 2026-06-10 (diminishing returns). The only untried mechanism is the UDF route (set dims by symbol at placement time). The working production fallback is boxinator's gated sketch-open repair. Feature-level dims (extrude depth, datum offset) are unaffected — they hold via a plain `DimValue` write.

### jiginator.cmd
Drill-jig decision-tree walker — the QUESTION FLOW only (no Creo connection; it produces the hole diameter that holeinator consumes). Has a companion `jiginator.ps1`. This is piece **(B)** of the drill-jig configurator.

**Flow:**
1. Load the decision tree from `docs\drill_jig_decision_tree.json` (authored in `docs\drill_jig_tree_builder.html` — the tree is the single source of truth; edit the HTML builder and the prompt updates with no code change).
2. Walk the user through the tree node-by-node (`Invoke-Walk`, recursive). Node kinds: `question`, `option`, `outcome`, `bushing`, `pattern`.
3. At an `outcome`, parse the label into a catalog query (`Get-CatalogSpec`): "removable"/"drill" → `data\bushings_drill.csv`, "sleeve" → `data\bushings.csv`, plus any `<fraction> ID|OD` constraints.
4. Three-stage bushing pick (`Invoke-BushingPick`): **OD** (drives the hole diameter) → **length** within that OD → **ID** (always explicit — ID never changes the jig hole, so the user may leave it unspecified). Machinist fractions ("3/4", "1 3/8") are shown from the row `EasyName` via `Get-FracLabel`.
5. End by printing the chosen path and resolved outcome(s): which catalog subset to show and the hole diameter (= selected bushing OD).
6. **Handoff to holeinator:** after a completed walk, the resolved hole spec is written to `last_jig_spec.json` in the repo root (file-based handoff, same style as the gauginator/diminator CSV handoff). If several outcomes resolve a bushing, the LAST pick wins as the active `HoleDiameter`; all picks are kept under `AllPicks`. holeinator reads this file to pre-fill its diameter.

**Handoff contract — `last_jig_spec.json`:** `{ HoleDiameter (= bushing OD, the jig hole Ø), Bushing (EasyName), PartNumber, Outcome (tree label), Path (decision path string), AllPicks[] }`. holeinator only requires `HoleDiameter`; the rest is provenance.

Helpers: `ConvertTo-Decimal` (fraction/number → decimal), `Read-Choice` (numbered menu with Q-to-quit). Main loop offers "Run again?".

### holeinator.cmd
Creates an **On-Point hole** at every target datum point — piece **(C)** of the drill-jig configurator (geometry creation), consuming jiginator's diameter (B). **Works live (confirmed 2026-06-11):** drilled clean through-holes at every selected point on a real multi-body jig part.

**Engine = native On-Point hole, ID-only, human-in-the-loop.** Each hole is created from scratch with Creo's native Hole tool in On-Point placement (no example feature — `IpfcSolid.CreateFeature` is "not implemented" on this build; no extrude-cut — that needs a screen pick per sketch and doesn't scale). The point is selected **by ID** (tree search), then the recorded hole dashboard fires as ONE atomic `RunMacro`. Diameter is set directly in the dashboard (never written-then-regenerated), so the sketch-dim snap-back trap never applies.

**ID-ONLY — the script never reads `IpfcPoint.Point` coordinates.** This is the key design fact and the result of a hard-won pivot (see below). The human makes the on-plane / which-body judgment **visually** (by selecting), so the tool needs only point IDs. Resolving a selected datum-point FEATURE into its point IDs uses `ListSubItems(ITEM_POINT)` → `$p.Id` — also id-only, no coords.

**Flow:**
1. Connect, null-check, print filename. **Mode guard:** filename `.asm` → STOP (assembly mode resolves selection against the `.asm`, not the part to drill). Keys off the filename extension, NOT `EpfcModelType` (enum ints unconfirmed on this build).
2. **STEP 1 — points:** user selects the target datum points in Creo, presses ENTER. Script reads the selection buffer and resolves each item to point IDs (direct point geometry, or a datum-point feature's `ListSubItems(ITEM_POINT)`). Dedup; report any non-point selections with their `.Type`.
3. **STEP 2 — body:** enumerate solid bodies via `ListItems(ITEM_BODY)`; single body → index 0 silently; multiple → numbered prompt. The recorded macro selects the body in the hole dashboard by list index.
4. **STEP 3 — diameter:** pre-filled from jiginator's `last_jig_spec.json` if present (user accepts with ENTER or overrides); loops until a positive value.
5. **CONFIRM (y/N)** — last stop before mutation.
6. **Fire:** per point, `Build-HoleMacro` → one atomic `RunMacro`. A **canary** validates hole #1 changed `VersionStamp` before committing to the rest (the live net against widget-name drift). Honest report: model-changed / no-op / macro-error counts.

**`Build-HoleMacro` (recorded live 2026-06-11)** — real widget names, fired as ONE atomic `RunMacro` (a dashboard's command context does not survive across `RunMacro` calls — boxinator lesson): select point by ID → `ProCmdHole` → depth-type flyout `maindashInst0.hole_depth_to_type_flybtn` → `maindashInst0.StrHoleDepThruAllF` (thru all) → body via `chkbn.body_page.0` + `PH.bodyselectrepwdg_list` → diameter via `maindashInst0.diameter_mip_OptionMenu` → `~ FocusOut` to blur → `dashInst0.Done`. `~ Trail`/`~ Timer` recording noise dropped.

**Verification = `VersionStamp` (did the model change), not geometric measurement.** Lighter than boxinator/radinator's cylinder-count proof; "Done" means the model changed for each hole, not that N correct holes were *measured*. Wiring holeinator's verify into the blind-evaluator lib (count cylinders at the hole radius, judge against sliced truth) is the natural next hardening step but is NOT done.

**History / why ID-only:** the original design read each point's xyz via `IpfcPoint.Point` to compute an **off-plane filter** and **idempotency** check. That COM coordinate read crashed repeatedly live (`op_Subtraction on System.Object[]` — the point marshals in an array shape `Get-Comp` didn't expect; multiple shape-coercion attempts all failed on the real object). The fix was architectural, not another patch: **drop coordinate reads entirely** and let the human judge visually. Off-plane filtering, idempotency, dry-run, and the geometric cylinder-count verify were all REMOVED in that rebuild (~50k → ~19k chars). datinator (piece A, the standalone point-reader) was deleted at the same time — nothing consumed its CSV and it carried the same unfixed coordinate bug. If off-plane/idempotency are ever wanted back, the COM point-marshaling shape must be solved first (a shape-agnostic `Get-Comp` that throws-with-type is in git history).
