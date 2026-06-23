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

## Response Convergence (the loop turned on the AGENT)
Same blind-evaluator idea aimed at Claude Code's OWN responses: an LLM coding agent fires edits and
CLAIMS things ("tests pass", "all N call sites updated") — confident producers emit plausible-but-
wrong claims, exactly what the evaluator catches. `lib\response_eval.ps1` + `lib\run_response_eval.ps1`.
- **Claim packet** (`.claude\.converge_packet.json`): claims, each with a check of kind `symbol`/`cmd`
  (DETERMINISTIC floor — the gate), `semantic` (LLM-judged), or `creo` (behavioral → always emitted
  **UNVERIFIED IN CREO**, never green; headless cannot run Creo).
- **Blind slice** = the raw `git diff` + each cmd's exit/output — NOT the agent's prose. The judge
  re-derives from evidence and also flags **unclaimed** substantive diff hunks (anti-gaming: you
  can't slip a change past it). Unclaimed = warnings by default; opt into hard-fail with
  `"strictUnclaimed":true` in the packet.
- **Gate** = deterministic floor all-pass AND no semantic refute. The LLM can't override a failed
  symbol/cmd check (same flicker argument as the geometry gate). Reuses `Get-JudgeConfig` + the REST
  transport; bodies go through `ConvertTo-AsciiSafeJson` (a `±`/curly-quote/box-draw char in a diff
  400s the gateway via PS 5.1's literal-non-ASCII `ConvertTo-Json` — escape to `\uXXXX`).
- **Automated** via hooks in `.claude\settings.local.json` (gitignored): `UserPromptSubmit`
  (`converge_prompt.ps1`) resets per-turn state + snapshots the base ref + reminds Claude to write a
  packet; `Stop` (`converge_stop.ps1`) runs the harness, BLOCKS the stop with refutations if not
  converged, self-managed iteration cap = 2 (does NOT rely on `stop_hook_active`, which is not in the
  documented schema), **fails open** on any harness/IO error (a broken verifier must never wedge a
  turn). **To disable:** delete the `hooks` block from `.claude\settings.local.json`.
- Offline tests: `lib\tests\run_response_tests.ps1` (26, builds a throwaway git repo). Proven live
  against this repo: deterministic floor caught a planted false claim; semantic judge cited diff
  evidence; unclaimed-change sweep flagged real uncovered edits.

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
1. User inputs edge length target (single + tolerance, default ±0.005 / min/max range) and radius value (default 0.125 in).
2. **Surface enumeration:** list bodies via `ListItems(ITEM_BODY)` → `body.ListSurfaces()` into one flat list. Fallback to `model.GetDefaultBody().ListSurfaces()` if body enumeration yields nothing.
3. **Scan phase (pure VB API):** per surface → `ListContours()` → `contour.ListElements()` (edges). `$processedSurfaceIds` / `$processedEdgeIds` hashtables dedup — every edge is shared by two surfaces, so each would otherwise be examined twice. Filters applied cheapest-first; bail on first failure:
   - Length within `[Min,Max]` (`EvalLength()`)
   - Edge is straight (`GetCurveDescriptor().End1` is non-null)
   - One adjacent surface (`Surface1`/`Surface2`) is a convex cylinder (type=1, `GetOrientation()`=1) and the other is a plane (type=0 or 9) — the node-boss-meets-flat-stiffener fingerprint, checked both orderings
   - Cylinder radius (`desc.Radius`) ≤ 0.875 in (`$maxNodeRadius`)
   - Survivors pushed to `$matchingEdges` with `Id, Length, SurfaceId, CylinderRadius`. Descriptors/surfaces are `ReleaseComObject`'d inside the loop (a big scan touches thousands of COM objects).
4. **Round phase (mapkeys):** batch matched edges into groups of 40 (`$batchSize`). Per batch: `ProCmdSelClear` → open tree search once → loop the 40 edge IDs into the selection buffer (`InputIDPanel` → `EvaluateBtn` → `ApplyBtn`, accumulating) → close search → fire `ProCmdRound` with radius → `dashInst0.Done`. One round feature per 40 edges (why it's fast on big models).
5. **Cleanup:** `finally` restores config, `ReleaseComObject`s everything (bodies, model, session, connection, async) and forces a GC.

Round mapkey (confirmed working):
```
~ Activate `main_dlg_cur` `page_Model_control_btn` 1;
~ Command `ProCmdRound`;
~ Input  `main_dlg_cur` `maindashInst0.cir_rad_list` `<radius>`;
~ Update `main_dlg_cur` `maindashInst0.cir_rad_list` `<radius>`;
~ Activate `main_dlg_cur` `maindashInst0.cir_rad_list`;
~ Activate `main_dlg_cur` `dashInst0.Done`;
```

Supports `-v` / `--verbose` flag for node-diameter (radius×2) and edge-length distribution breakdown before rounds are applied.

**Caveat:** the round-phase `RunMacro` calls are wrapped in error-swallowing `try/catch`, and `$totalSuccess` counts *batches fired*, not rounds Creo actually accepted. A round that silently fails in Creo (e.g. geometry can't take the radius) won't show in the final count — hence the on-screen "Monitor Creo and click Ok if any rounds fail" note. Verify rounds visually after a run.

### cornerinator.cmd
Rounds the **vertical edges** of a rectangular drill-jig plate (the upright edges running through the plate thickness — "rounded corners" viewed from the top). Standalone (like radinator); does NOT touch drilljig.cmd. For a plain plate that's the 4 corners; a plate with extra vertical edges (pockets/bosses) gets them all — the confirm step shows the count first so nothing unexpected is rounded blind.

**Reuses proven machinery:** the round mapkey + edge-by-ID selection + batching (≤40 edges/round feature) verbatim from radinator (`radinator.cmd:470-519`); the `.prt`-only mode guard + `VersionStamp` canary + ID-only buffer read from holeinator/drilljig; `Measure-Extents` / `Get-AllSurfaces` / `Read-PlaneNormal` / `Dot` / `Cross` from `lib\creo_geometry.ps1`.

**Edge enumeration (`Get-AllEdges`) — FEATURE route first, "edges of the extrude".** LIVE 2026-06-22: the surface walk (`Get-AllSurfaces` → `ListContours` → `ListElements`) returned **0 surfaces** on a real jig plate AND whole-model/per-body `ListItems(ITEM_EDGE)` came back empty — so all geometry-container routes failed. The fix follows the user's directed approach ("find all edges that are equal to the extrude"): go through the **feature**, not the geometry container. The VB docs confirm the route — `IpfcGeomCurve.GetFeature()` links an edge to its owning feature, and `feature.ListSubItems(ITEM_EDGE)` lists a feature's own edges (`ITEM_EDGE` is a supported `ListSubItems` subitem; holeinator uses the same call live for `ITEM_POINT`). Cascade, stop at the first that yields edges: **(1) PRIMARY — feature tree:** each `feature.ListSubItems(ITEM_EDGE)`, deduped by Id; **(2)** `$model.ListItems(ITEM_EDGE)`; **(3)** per body `$body.ListItems(ITEM_EDGE)` / `ListSurfaces` walk; **(4)** the old `Get-AllSurfaces` walk as last resort. Each path logs its yield via `Write-Log` (`-v`), and the chosen path + edge count is printed (`Edge source: …`). The vertical corner edges are then the enumerated edges whose `EvalLength` ≈ the extrude depth (= `Measure-Extents` thinnest axis).

**Detection (`Get-VerticalEdges`) — PROVEN per-edge primitives; never reads edge endpoints.** PRIMARY gate: straight (`GetCurveDescriptor().End1` non-null — presence probe only, value never read) AND **length ≈ plate thickness** (`EvalLength` within ~5% of the up-axis extent). On a flat rectangular plate the only straight edges whose length equals the thinnest extent ARE the four verticals (perimeter edges are width/depth-long). OPTIONAL sub-gates that can only *tighten*, never empty the set: both adjacent faces planar (`Surface1`/`Surface2` → `GetSurfaceType` 0/9) — **SKIPPED, not failed, when `Surface1/2` are unreachable** from a `ListItems`-sourced edge; and normals ⟂ up, only when `Read-PlaneNormal` returns non-null. This uses only `EvalLength` + (optionally) `GetSurfaceType` + `Measure-Extents` — all proven live — and **deliberately avoids reading edge-endpoint coordinates** (the `IpfcPoint.Point`-style read that crashed holeinator live; see [[project_drill_jig_configurator]] / "History / why ID-only"). "up" defaults to the **thinnest** of the three `Measure-Extents` axis extents; overridable X/Y/Z. Assumes the plate is axis-aligned to the default datums. The detector returns per-gate survivor counts (`straight → length~thickness → planar-checked → both-planar → normals-read → normals-perp`) so a live "0 detected" run shows exactly which gate emptied the set.

**Flow:** header/flags (`-v`) → dot-source lib → input (radius default 0.25, up axis default auto) → connect → `.asm` mode guard → config-suppress + `try/finally` → measure extents + pick up axis → `Get-VerticalEdges` (which calls `Get-AllEdges`) → if ≥1: highlight them in Creo + print per-edge `id / length / |n·up|-or-gate` + confirm `(y/N)`; if 0: manual-pick fallback (user selects edges, `Resolve-SelectedEdgeIds` reads IDs only) → round (one atomic `RunMacro` per batch, `VersionStamp` canary aborts after batch #1 if the model didn't change) → honest report → finally (restore config, ReleaseComObject, GC).

**Live findings (2026-06-22), two separate root causes, both fixed:** (1) `Read-PlaneNormal`'s `.Origin.GetZAxis()` returns `$null` for PLANE descriptors on this build (works for cylinders via `Get-CylinderAxes`; VB docs never confirmed `.Origin` on a plane descriptor) — so the normal test was demoted to an optional refinement. (2) The surface walk returned **0 surfaces**, starving the scan — so edge enumeration was moved to the direct `ListItems(ITEM_EDGE)` cascade above. Throughout, the **manual-pick fallback rounded correctly**, proving the round mapkey + edge-by-ID select are sound; the work was making auto-detection feed them. If detection still finds 0, the `Edge source:` line + per-gate survivor counts pinpoint where it stops, and manual-pick always rounds hand-selected edges.

**Honesty (same bar as radinator):** "Done" means the model changed (`VersionStamp`) for each batch, NOT that N rounds were geometrically measured; the count is *batches fired*. Verify the rounded corners visually after a run.

**LIVE STATUS (2026-06-22): COM traversal is dead on this part — switched to the FIND TOOL → buffer.** FOUR COM enumeration routes returned 0 edges live (surface walk, `model.ListItems(ITEM_EDGE)`, per-body, feature `ListSubItems(ITEM_EDGE)`) while manual pick works every time. Conclusion: the jig body is **imported/"foreign" geometry** — *selectable* but not API-traversable. So detection was re-architected around the layer that works: **`Get-EdgesViaFindTool`** runs the find tool with object type = Edge and a select-all rule (no ID filter) to push every edge into the selection buffer, then reads them back via `CurrentSelectionBuffer().Contents` (the proven path manual pick uses), taking `.Id` + `EvalLength()` off each buffered `SelItem`. `Get-VerticalEdges` now takes `-Session` and uses this as the PRIMARY edge source (COM `Get-AllEdges` cascade only as fallback), and ALL per-edge sub-gates (straight, planar, normals) are now **skip-not-fail** so a foreign edge that exposes only `.Id`/`EvalLength` still passes on the length≈thickness gate alone. The `--probe-edges` diagnostic and the `GetActiveModel()` accessor (over `CurrentModel`) were added the same session. **CAVEAT — the select-all widget names are NOT yet recorded:** the macro layers `FindNowBtn` / `SelAllBtn` / `RuleTypes … All` (best-guess) onto the proven `selspecdlg0`/`EvaluateBtn`/`ApplyBtn` skeleton. If the select-all yields an empty buffer live, those exact widgets need a `visible_mapkeys yes` recording of "search Edges, select all" — the architecture (find tool → buffer → length gate) is correct regardless. **Manual pick remains the guaranteed path** until the select-all sequence is confirmed live.

**Offline tests:** `lib\tests\run_tests.ps1` covers the promoted lib helpers `Cross` (orthogonality/right-hand-rule) and `Read-PlaneNormal` (descriptor `.Origin.GetZAxis()` path + `GetNormal()` fallback + null-safety). The cornerinator-specific helpers (`Get-AllEdges` cascade, `Get-VerticalEdges` incl. the surfaceless-edge path, the macro builders, `Resolve-SelectedEdgeIds`) were verified offline with stubbed COM objects via throwaway harnesses during development (not persisted, since they need a full COM stub graph the lib suite isn't set up for).

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

### plane-probe.cmd
**EXPERIMENT, not production** (lives on the `boxinator-parametric` / `plane-probe-v2` branches — does NOT modify boxinator.cmd). Builds a fully **parametric box** from three offset datum planes, then a solid sized by them, and lets you resize it live. Single-session only (no picker — throws if >1 `xtop.exe`).

**Why offset planes:** a datum plane's OFFSET distance is a **feature-level** dim, so a plain `DimValue` write + regen HOLDS — unlike a SKETCH dim, which snaps back (see [[project_sketch_dim_snapback]]). The three offset planes (TOP/SIDE/FRONT), against the part's three default datums, bound a box whose every extent is driven by an offset dim from PowerShell.

**Flow:**
1. **Ask all three offsets up front** (TOP/SIDE/FRONT).
2. **Capture three base-plane IDs up front** — user clicks each default datum once (quick picks; nothing fires between them), script records each feature ID from the selection buffer.
3. **Create all three planes back-to-back, no clicks** (`New-OffsetPlane`): per plane, ONE atomic macro = select base BY ID → `ProCmdDatumPlane` (consumes the buffered ref as an Offset constraint) → type offset into `t1.constr_dim1` → `FocusOut` (blur) → `stdbtn_1` (OK). The new offset dim symbol is found by **before/after linear-dim-set diff**; the new plane's feature ID by **feature-ID-set diff**.
4. **Show all three** (`ProCmdViewShow@PopupMenuTree`, select-by-ID per plane). Runs on FeatId BEFORE the drivable-dim gate, so a created plane shows even if its dim wasn't captured.
5. **Build the box (v2: extrude-first, internal sketch)** — see below.
6. **Resize loop:** `A` = set all three offsets (resize whole box), `1-N` = one plane, `D` = done. Each write goes through `Set-PlaneOffset` (DimValue + `Invoke-ForceRegen`) and is re-read to confirm it held.

**v2 box build — extrude-first / internal sketch (current algorithm):** clicks Extrude FIRST and creates the sketch INSIDE the extrude (the feature owns the section from the start — no standalone-sketch section-binding fragility). Transcribed from a live recording (current `maindashInst0` widgets). The only manual step is drawing the rough rectangle (4 screen picks a `RunMacro` can't do), which forces ONE split into two macros:
- **Macro A:** select sketch plane BY ID **FIRST** (its `buffer_clean` wipes the stale extrude-to plane) → `ProCmdFtExtrude` (consumes the og datum) → `ProCmdViewSketchView` → `ProCmdSketRectangle 1` (arm corner-rect). User draws + ENTER.
- **Macro B:** `ProCmdSketDone` → `maindashInst0.depth_flyout` → `maindashInst0.toselected` → `extrev_1_placement.0.0` `PH.section_select_list` triggers → select extrude-to plane BY ID (**`-NoClear`**, so the open depth collector stays active) → `Enter`/`Exit dashInst0.Quit` (blur) → `dashInst0.Done`.

**DIRECTION (confirmed live):** sketch ON the **og/default datum**, extrude UP TO the **offset plane**, so the feature reads og → offset. Stays parametric because the og datum and offset plane are separated by EXACTLY the offset dim, so the up-to-plane depth equals the offset value — driving the offset dim still resizes the box. The sketch-plane select MUST run before `ProCmdFtExtrude`; firing the extrude first made it grab the stale offset plane from the buffer (sketch landed on the wrong plane).

**Shared helpers (also used by the blind evaluator):**
- `Get-SelectByIdMacro -FeatId [-NoClear]` — the nodelator/flipenator tree-search select-by-ID fragment, centralised (4 call sites). `-NoClear` omits the leading `buffer_clean` for feeding an already-open dashboard reference collector (clearing mid-dashboard can deactivate it; surfenator proves the tree-search feeds the collector).
- `Read-SelectedId` — last selected feature ID from the selection buffer.
- `New-OffsetPlane` **polls** for the new offset dim to appear (up to ~20s) rather than waiting a fixed interval — heavy models commit the datum plane more slowly, and a fixed wait diffed the dim set before the offset dim was enumerable (symptom: "No new linear dim" even though the plane was made).
- `Invoke-ForceRegen` — boxinator's forced-regen-with-fallback (forced API regen → UI `ProCmdRegenerate` → automatic).
- `Get-LinearDimMap` / `Read-DimValue` now live in `lib\creo_geometry.ps1` (shared so every tool reads dims the same way).

**Blind-evaluator wired:** build + per-resize claims (the entered offsets), deterministic-gated with LLM advisory — see the blind-evaluator section above. `--probe-judge` validates the BlueGPT REST judge round-trip with a synthetic packet (no Creo) before relying on it live.

**Key facts / gotchas:**
- Selecting base planes BY ID (captured up front) is what lets all three creations fire back-to-back — `ProCmdDatumPlane` consumes the buffer, so manual picks would otherwise have to interleave.
- The whole open→offset→OK per plane MUST be one atomic `RunMacro` (a dialog's command context does not survive across `RunMacro` calls — same rule as the extrude dashboard).
- The v2 extrude's "does select-by-ID feed the open `toselected`/`section_select_list` collector" was the last unverified assumption; confirmed working live.

### drilljig.cmd
End-to-end drill-jig flow in ONE console session and a SINGLE Creo connection — a MERGE of three working tools (jiginator + plane-probe + holeinator), which are left untouched and still run standalone. STAGE 1 walks the decision tree (no Creo) → hole OD; STAGE 2 builds a parametric box from three offset datum planes (plane-probe v2); STAGE 3 drills an On-Point hole at every target datum point (holeinator) at the STAGE-1 diameter; STAGE 4 (optional) adds coaxial chip-relief holes. The hole diameter is handed STAGE 1 → STAGE 3 as an in-process variable (NOT via `last_jig_spec.json`). Assumes the target datum points ALREADY EXIST in the part; open the jig PART (not `.asm`).

**STAGE 2 base-plane capture — ONE multi-select, auto-mapped by NAME (confirmed live 2026-06-22):** instead of three sequential single clicks, the user Ctrl-clicks ALL THREE default datums (TOP/SIDE/FRONT) at once; the script reads each pick's NAME via `SelItem.GetName()` and sorts them into box roles by substring (`Resolve-PlaneRole`: tests SIDE first, then TOP, then FRONT), so **click order does not matter** — the name carries the role. `Read-SelectionPlanePicks` returns one `{Id; Name; Role}` per unique buffer item (ID-and-name only, never reads coords). The mapping is shown and **confirmed ONCE**; on accept the box build runs hands-free. Parts use literal `TOP`/`SIDE`/`FRONT` datum names.
- **Why name, not geometry:** the auto-classifier must disambiguate three unlabeled IDs, and reading plane orientation is a dead end on this build — see [[project_plane_normal_null]] (`descriptor.Origin.GetZAxis()` returns null for PLANE descriptors); no solid exists yet at capture time to measure either. `GetName()` is the only viable signal (proven live on body items elsewhere).
- **Robustness:** the original sequential one-click-per-plane capture is KEPT as a fallback, triggered by `-not $autoMapped` whenever the multi-select doesn't yield a clean unambiguous all-three mapping (empty buffer, a missing role, or two datums claiming the same role). So an oddly-named part or a `GetName()` miss degrades gracefully, never wedges.

**STAGE 2 hands-free box build — SIDE drives the references (confirmed live 2026-06-22):** once SIDE is identified by name and the mapping is accepted (`$autoMapped`), the box build needs NO further plane clicks — it sketches on the SIDE og/default datum (`sidePlane.BaseId`) and extrudes UP TO the SIDE offset plane (`sidePlane.FeatId`). The manual click-each-plane prompts remain as the fallback path. The only manual step left is drawing the rough rectangle (real screen picks a `RunMacro` can't do).
- **Extrude-to plane fed by ID — `Get-SelectDatumByIdMacro` (the fix for the manual up-to click):** Macro B feeds the extrude depth "to selected" collector with the up-to plane BY ID via a **DATUM-typed** tree search (`SelOptionRadio`=`Datum` + `LookByOptionMenu`=`Feature`), mirroring **surfenator's** proven up-to-plane feed — NOT the Feature-typed `Get-SelectByIdMacro`. A Feature-typed selection is correct for CONSUMING a buffered ref (`ProCmdDatumPlane`) or showing/hiding a feature (so base-plane creation + the sketch-plane pick use it), but does NOT satisfy the depth collector's geometric-reference filter — symptom: the extrude dashboard sits open waiting for a manual plane click. The datum helper has NO leading `buffer_clean` (clearing mid-dashboard deactivates the open collector). **General rule: feeding an OPEN dashboard reference collector by ID needs surfenator's Datum pattern, not the generic Feature select.**

The whole STAGE 2 flow now runs without per-plane clicks beyond the one multi-select and the rectangle draw. STAGE 4's blind-relief widget names remain GUESSED (see `Build-ReliefHoleMacro` header) until a blind hole is recorded live.

**STAGE 4 chip-relief gate — MATERIAL-DRIVEN (confirmed live 2026-06-23):** the relief-hole step is auto-confirmed for **3D-printed** parts and stays human-gated for **metal**. Right after the STAGE-1 walk, `$is3dPrint` is derived from the decision `$path` (`$path -match '(?i)3d\s*print'`) — the "3d print" string only ever enters `$path` via the root material option (the metal sub-answers are "PFD"/"Hand Drill"), so the match is unambiguous. STAGE 4 then has **two** confirmation prompts, and BOTH are gated on `$is3dPrint`: the entry "Add chip-relief holes? (y/N)" AND the inner "Proceed? (y/N)" just before the fire loop. When `$is3dPrint`, each is set to `y` with no `Read-Host` so a 3D-print run drills the relief holes start-to-finish with zero prompts; metal (and any non-3D-print / unresolved path) still asks both. Missing the inner "Proceed?" prompt the first time was the bug — gating only the entry prompt still stalled the run. The plate-thickness *data-entry* fallback (`Read-Host` at the relief-depth step) is deliberately left manual: it only fires when the live SIDE-plane offset can't be read, and it needs a number that can't be derived. The decision-tree JSON is unchanged — this lives entirely in the `drilljig.cmd` method, keyed off the existing Metal/3D-print material options.
