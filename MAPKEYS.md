# Creo Mapkey Catalog — NGS Orthogrid Automation

A reference index of **every Creo mapkey actually fired or built across this toolkit** — the real
`ProCmd*` commands and widget recipes, deduplicated, categorized, and status-tagged. Where the
[`CREO_MAPKEY_AUTOMATION_GUIDE 1.md`](CREO_MAPKEY_AUTOMATION_GUIDE%201.md) explains *how* to build
mapkey scripts (the methodology), this file is the *what* — the catalog of proven recipes you can
copy from. It complements the confirmed-widget reference in [`DEV_NOTES.md`](DEV_NOTES.md) and the
per-script flow notes in [`CLAUDE.md`](CLAUDE.md).

> Compiled by sweeping all 34 `.cmd` scripts, `jiginator.ps1`, the `lib\*.ps1` macro builders, the
> `ps1 archive\` versions, and the reference docs (364 raw mapkey usages deduplicated). When a recipe
> stops working, re-record it in Creo with `visible_mapkeys yes` — widget names drift between Creo
> versions and this catalog reflects the current build.

**Legend:** ✅ confirmed live · ⚠️ built but widgets unverified · 🗄️ archived/historical (superseded) · ❔ unknown / documented-only

**How to read this:** the tables are the index (command → what it does → key widgets → which scripts
fire it → status). The fenced code blocks under each table are the reference — the exact recipe as
fired, with single backticks (double them for PowerShell string literals). Recipes are shown with
`main_dlg_cur` widget names as they appear in the source; a **⚠️** on a row means that specific
widget set was never confirmed against a live recording.

**The five rules that govern almost every recipe below** (details repeated in-context where they bite):

1. **Atomic dashboard** — open + set fields + `dashInst0.Done` must be ONE `$session.RunMacro()`. A
   dashboard's command context does not survive across separate `RunMacro` calls; splitting silently
   drops the confirm and stalls the regen.
2. **`buffer_clean` before a fresh Find** — omit it (`-NoClear`) only to *accumulate* multiple refs.
3. **`dashInst0.Quit` via `~ Enter`/`~ Exit` is a blur, not a cancel** — it commits the active field
   before `Done`.
4. **ID-only, never `IpfcPoint.Point`** — coordinate reads crash on this build; identify geometry by
   feature ID (tree search / VB-API), and gate every create on a `VersionStamp`/feature-count canary.
5. **`@PAUSE_FOR_SCREEN_PICK` can't be automated** — draw-a-rectangle / pick-a-plane steps force the
   macro to split around the human pick.

---

## Core Building Blocks

These are the foundational recipes that recur across nearly every script in the toolkit. Deduplicated here once; individual feature recipes reference them.

| Command | Operation | Key widgets | Used by | Status |
|---|---|---|---|---|
| `buffer_clean` | Clear the selection buffer before a new buffered selection | `main_dlg_cur`, `buffer_clean` | many (drilljig, drilljig3d, holeinator, slotinator, cornerinator, radinator, pocketinator, conformal_blank, thickenator, flipenator, nodelator, …) | ✅ |
| `ProCmdSelClear` | Clear all model selections + visual highlights (distinct from buffer_clean) | — | cornerinator, radinator, drilljig | ✅ |
| `dashInst0.Done` | Confirm/close a mini-dashboard (extrude, round, thicken, hole, pattern, offset, flip) | `main_dlg_cur`, `dashInst0.Done` | many (holeinator, drilljig, drilljig3d, cornerinator, radinator, boxinator, slotinator, thickenator, flipenator, nodelator, conformal_blank, …) | ✅ |
| `dashInst0.Quit` | Blur/unfocus the active field via hover (NOT a cancel) | `main_dlg_cur`, `dashInst0.Quit` | boxinator, drilljig, drilljig-gui, drilljig3d, thickenator | ✅ |
| `ProCmdRegenerate` | Force UI-level regeneration (fallback when API regen fails) | — | boxinator, drilljig3d | ✅ |
| `ProCmdEditUndo` | Undo the last Creo operation | — | drilljig, drilljig-gui, slotinator | ✅ |

```
~ Activate `main_dlg_cur` `buffer_clean`;
~ Command `ProCmdSelClear`;
~ Activate `main_dlg_cur` `dashInst0.Done`;
~ Enter `main_dlg_cur` `dashInst0.Quit`; ~ Exit `main_dlg_cur` `dashInst0.Quit`;
~ Command `ProCmdRegenerate`;
```

Gotchas:
- **Atomic-dashboard rule (the single most important gotcha):** every dashboard feature (`ProCmdFtExtrude`, `ProCmdHole`, `ProCmdRound`, `ProCmdFtThicken`, `ProCmdFtOffset`, `ProCmdGeomPattern`, …) MUST fire the tool-open, all field sets, and `dashInst0.Done` in ONE `$session.RunMacro()` call. Dashboard command context does NOT survive across separate RunMacro calls — splitting silently drops the confirm.
- **buffer_clean before Find:** always `buffer_clean` before starting a fresh select-by-ID sequence. Omitting it causes silent selection failures (pattern opens empty, extrude defaults to Linear placement). Omit `buffer_clean` (use `-NoClear`) only when deliberately accumulating multiple refs into one buffer.
- **`dashInst0.Quit` is a blur, not a cancel:** `~ Enter` / `~ Exit` are hover events that blur the active depth/value field so it commits before `Done`. Do not use `~ Activate` on it.
- **Forced regen:** API `RegenInstructions` with `ForceRegen=true` throws `IpfcXToolkitBadContext` in No-Resolve mode; fall back to UI `ProCmdRegenerate`. Do NOT try `regen_failure_handling = resolve_mode` — it is deprecated and pops a blocking CS260154 authorization dialog that stalls the run.
- **No coordinate reads:** never read `IpfcPoint.Point` coordinates on this Creo build (crashes). All geometry identification is ID-only via VB API or tree-search by feature ID.
- **VersionStamp canary gates:** after each create, verify the model VersionStamp changed; abort if unchanged (never assume success on a no-op).

## Mapkey Import & Execute (host-side)

How the PowerShell host loads a generated `.pro` mapkey into Creo and runs it (Creo 12+). Fired as a series of `$session.RunMacro(...)` calls, NOT a mapkey body itself.

```
$session.RunMacro("~ Command `ProCmdUtilMacros`")                                   # open Mapkey Editor
$session.RunMacro("~ Activate `mapkey_main` `psh_import`")                           # Import
$session.RunMacro("~ Trail ` ` `DLG_PREVIEW_POST` `file_open`")
$session.RunMacro("~ Select `file_open` `Ph_list.Filelist` 1 `$name.pro`")
$session.RunMacro("~ Command `ProFileSelPushOpen_Standard@context_dlg_open_cmd`")
$session.RunMacro("~ Activate `mapkey_main` `CloseButton`")
$session.RunMacro("~ Activate `unsaved_mapkeys` `yes`")
$session.RunMacro("%$name")                                                          # execute the mapkey
```

Gotchas:
- Write the `.pro` to `C:\Users\$env:USERNAME\working_folder\$name.pro` — **never** overwrite `config.pro`.
- `RunMacro("%$name")` blocks until the mapkey finishes but does **not** report success — verify with a `VersionStamp`/geometry canary.
- The newer scripts skip the file round-trip entirely and fire recipe strings directly through `RunMacro`; the import path above is for the older `.pro`-file tools.

## Selection & Reference (Tree Search by ID)

The tree-search Find-tool select-by-ID pattern is the backbone of hands-free selection. It is used by essentially every script. The type parameter (`Feature`, `Point`, `Edge`, `Surface`, `Datum`, `Quilt`, `Geometric Body`, `3D Curve`, `Component`, `Dimension`) is the only substantive variation.

| Command | Operation | Key widgets | Used by | Status |
|---|---|---|---|---|
| `ProCmdMdlTreeSearch` (Feature) | Select a feature by ID via tree search | `selspecdlg0`, `SelOptionRadio`, `RuleTab`, `InputIDPanel`, `EvaluateBtn`, `ApplyBtn`, `CancelButton` | many (drilljig, drilljig-gui, holeinator, csysinator, cornerinator, radinator, pocketinator, boxinator, thickenator, flipenator, nodelator, conformal_blank, slotpat/slotplane-probe, …) | ✅ |
| `ProCmdMdlTreeSearch` (Datum) | Select a datum by ID (`SelOptionRadio`=Datum, `LookByOptionMenu`=Feature) — feeds open-dashboard collectors | `selspecdlg0`, `SelOptionRadio`, `LookByOptionMenu`, `RuleTab`, `InputIDPanel` | drilljig_core (Get-SelectDatumByIdMacro), slotinator, surfenator | ✅ |
| `ProCmdMdlTreeSearch` (Point) | Select a datum point by ID | `selspecdlg0`, `SelOptionRadio`, `RuleTab`, `InputIDPanel` | drilljig_core (Get-PointByIdMacro), csysinator, tangent-plane-probe, nodelator | ✅ |
| `ProCmdMdlTreeSearch` (Surface/Edge accumulate) | Accumulate multiple surfaces/edges/points into buffer via looped ApplyBtn | `selspecdlg0`, `SelOptionRadio`, `RuleTab`, `InputIDPanel`, `EvaluateBtn`, `ApplyBtn`, `CancelButton` | drilljig3d (Get-SelectSurfacesByIdMacro, Get-SelectItemByIdMacro), cornerinator, radinator | ✅ |
| `ProCmdMdlTreeSearch` (Geometric Body) | Select bodies by ID (re-selection after flips) | `selspecdlg0`, `SelOptionRadio`, `RuleTab`, `InputIDPanel` | flipenator | ✅ |
| find-tool select-all-edges | Find + select ALL edges (no ID filter): Evaluate → FindNowBtn → SelAllBtn → ApplyBtn | `selspecdlg0`, `RuleTypes`, `FindNowBtn`, `SelAllBtn`, `ApplyBtn` | cornerinator, holeinator | ⚠️ |

Feature select-by-ID (the canonical sequence):
```
~ Command `ProCmdMdlTreeSearch`;
~ Open `selspecdlg0` `SelOptionRadio`;
~ Close `selspecdlg0` `SelOptionRadio`;
~ Select `selspecdlg0` `SelOptionRadio` 1 `Feature`;
~ Select `selspecdlg0` `RuleTab` 1 `Misc`;
~ Update `selspecdlg0` `ExtRulesLayout.ExtBasicIDLayout.InputIDPanel` `$id`;
~ Activate `selspecdlg0` `EvaluateBtn`;
~ Activate `selspecdlg0` `ApplyBtn`;
~ Activate `selspecdlg0` `CancelButton`;
```

Datum select-by-ID (feeds an already-open dashboard reference collector — note no `buffer_clean`):
```
~ Command `ProCmdMdlTreeSearch`;
~ Select `selspecdlg0` `SelOptionRadio` 1 `Datum`;
~ Select `selspecdlg0` `LookByOptionMenu` 1 `Feature`;
~ Select `selspecdlg0` `RuleTab` 1 `Misc`;
~ Update `selspecdlg0` `ExtRulesLayout.ExtBasicIDLayout.InputIDPanel` `$id`;
~ Activate `selspecdlg0` `EvaluateBtn`;
~ Activate `selspecdlg0` `ApplyBtn`;
~ Activate `selspecdlg0` `CancelButton`;
```

Multi-ref accumulate (loop ApplyBtn per ID; used for 3-plane intersection, multi-surface offset, edge batches):
```
# 1st ref: normal Get-SelectByIdMacro (leads with buffer_clean)
# 2nd/3rd refs: Get-SelectByIdMacro -NoClear (omits buffer_clean, accumulates)
# In-dialog: repeated ~ Activate `selspecdlg0` `ApplyBtn`; per ID before CancelButton
```

Find-tool select-all-edges (⚠️ FindNowBtn / SelAllBtn widget names are GUESSED):
```
~ Command `ProCmdSelClear`;
~ Command `ProCmdMdlTreeSearch`;
~ Select `selspecdlg0` `SelOptionRadio` 1 `Edge`;
~ Select `selspecdlg0` `LookByOptionMenu` 1 `Edge`;
~ Select `selspecdlg0` `RuleTab` 1 `Misc`;
~ Select `selspecdlg0` `RuleTypes` 1 `All`;
~ Activate `selspecdlg0` `EvaluateBtn`;
~ Activate `selspecdlg0` `FindNowBtn`;
~ Activate `selspecdlg0` `SelAllBtn`;
~ Activate `selspecdlg0` `ApplyBtn`;
~ Activate `selspecdlg0` `CancelButton`;
```

Gotchas:
- **Whole sequence is atomic** — Evaluate → Apply → Cancel must fire in one RunMacro.
- **`CancelButton` commits, not cancels:** despite the name it closes the dialog *keeping* the buffered selections (they remain in `CurrentSelectionBuffer()`).
- **`-NoClear` to accumulate:** the 1st selection leads with `buffer_clean`; subsequent selections use `-NoClear` to omit it and add to the buffer. Critical for 3-plane csys/intersection feeds and multi-surface offset.
- **Type filter subtleties:** edge/surface searches add a `LookByOptionMenu` step; datum searches use `SelOptionRadio`=Datum + `LookByOptionMenu`=Feature. `RuleTab`=Misc is what enables the ID panel.
- **Feeding an OPEN dashboard collector needs the Datum pattern, not the generic Feature select** — a Feature-typed selection consumes a buffered ref or shows/hides a feature, but does NOT satisfy a depth/direction collector's geometric-reference filter (symptom: dashboard sits open waiting for a manual pick). Use `Get-SelectDatumByIdMacro` (surfenator's proven feed) for those.
- **Tree-search channel is DEAD for pattern targets** (FIX 1, trail.txt.33) — geometry patterns need a datum pre-select feed, not tree-search of the seed. See Holes & Patterns.
- **⚠️ select-all-edges:** logic proven (EvalLength readback ~28 edges) but `FindNowBtn`/`SelAllBtn` widget names never confirmed live; if the buffer comes back empty, these need a `visible_mapkeys yes` recording to correct. On imported/"foreign" bodies the Find tool is dead for ALL edge selection — use raw-COM `CreateModelItemSelection` + `AddSelection` (edginator, see Rounds/Edges).

### MRU picks & popup-menu show

| Command | Operation | Key widgets | Used by | Status |
|---|---|---|---|---|
| `ProCmdViewShow@PopupMenuTree` | Show/unhide a selected feature (planes, csys) in tree/display | — | drilljig, drilljig-gui, drilljig_core, slotinator, csysinator | ✅ |
| `t1.PlnMru` / `t1.RefMru` | Pick sketch plane / orientation ref from the MRU list | `Odui_Dlg_00`, `t1.PlnMru`, `t1.RefMru` | curved_slot_macros, slotplane-probe, boxinator, drilljig | ✅ |

```
# Show a pre-selected feature (must be preceded by select-by-ID):
~ Command `ProCmdViewShow@PopupMenuTree`;

# MRU plane + orientation pick (each: index 0 selects top, empty confirms):
~ Trigger `Odui_Dlg_00` `t1.PlnMru` `0`; ~ Trigger `Odui_Dlg_00` `t1.PlnMru` ``;
~ Trigger `Odui_Dlg_00` `t1.RefMru` `0`; ~ Trigger `Odui_Dlg_00` `t1.RefMru` ``;
```

## Sketcher

| Command | Operation | Key widgets | Used by | Status |
|---|---|---|---|---|
| `ProCmdDatumSketCurve` | Open the Sketch tool on a pre-selected/MRU plane | `Odui_Dlg_00`, `t1.PlnMru`, `t1.RefMru`, `stdbtn_1` | boxinator, curved_slot_macros, slotplane-probe, drilljig, drilljig-gui | ✅ |
| `ProCmdViewSketchView` | Orient view to sketch plane / enter internal sketcher view | — | slotinator, curved_slot_macros, drilljig, drilljig-gui, drilljig3d, pocketinator | ✅ |
| `ProCmdSketRectangle` | Arm corner-rectangle tool (2 screen picks) | — | drilljig, drilljig-gui, slotinator, pocketinator, curved_slot_macros | ✅ |
| `ProCmdSketCenterRectangle` | Arm center-rectangle tool (center + corner picks) | — | boxinator, drilljig, drilljig-gui | ✅ |
| `ProCmdSketGeomPoint` | Arm sketch-point tool (1 screen pick) | — | drilljig | ✅ |
| `ProCmdSketDimension` | Arm dimension tool + set value via `mod_dim_emb` | `main_dlg_cur`, `mod_dim_emb` | boxinator | ✅ |
| `mod_dim_emb` | Set a sketch dimension value in the inline editor | `main_dlg_cur`, `mod_dim_emb` | boxinator | ✅ |
| `ProCmdSketDone` | Exit sketcher and finalize the sketch | — | many (boxinator, drilljig, drilljig-gui, drilljig3d, slotinator, pocketinator, curved_slot_macros, surfenator) | ✅ |
| `ProCmdSketProject` | Project curves onto the sketch plane | — | surfenator | ✅ (⚠️ in drilljig) |
| `ProCmdSketOffset` | Offset sketch geometry by distance | — | (none active) | 🗄️ |
| `ProCmdSketUse` | Use/reference external geometry in sketch | — | (none active) | 🗄️ |

Open sketch on plane (MRU-fed), then arm rectangle:
```
~ Command `ProCmdDatumSketCurve`;
~ Trigger `Odui_Dlg_00` `t1.PlnMru` `0`; ~ Trigger `Odui_Dlg_00` `t1.PlnMru` ``;
~ Trigger `Odui_Dlg_00` `t1.RefMru` `0`; ~ Trigger `Odui_Dlg_00` `t1.RefMru` ``;
~ Activate `Odui_Dlg_00` `stdbtn_1`;
```

Dimension set (double-click a dim opens the inline editor):
```
~ Update `main_dlg_cur` `mod_dim_emb` `<value>`;
~ Activate `main_dlg_cur` `mod_dim_emb`;
```

Gotchas:
- **`@PAUSE_FOR_SCREEN_PICK`:** `ProCmdSketRectangle`, `ProCmdSketCenterRectangle`, `ProCmdSketGeomPoint`, `ProCmdSketDimension` all require operator screen picks — split the macro around the pause. Rectangle/center-rectangle = 2 picks; point = 1 pick.
- **Split point:** the classic box-a arm phase is TWO RunMacro calls — Macro A does `ProCmdFtExtrude` + `ProCmdViewSketchView` + `ProCmdSketRectangle 1`, user draws, Macro B finishes.
- **`mod_dim_emb` uses FULL values** (not halved for center-rectangle), and each dimension needs its own double-click → set → confirm cycle (it does not advance to the next dim).
- **Sketch-dim snap-back:** weak sketch dims can snap back on regen — expected for `mod_dim_emb`-driven sketches. Feature-level dims (extrude depth, datum offset) hold via a plain `DimValue` write; sketch dims need the sketch-open repair flow (open sketch → set on sketch model → `$sketchModel.Regenerate($null)` while open → close → `$model.Regenerate($null)`).
- **boxinator SELECT-FIRST flow:** user clicks the plane on screen first, then fires `ProCmdDatumSketCurve` — the real pick is what populates the dialog's plane MRU. `stdbtn_1` fires after the dialog populates.

## Features — Extrude / Thicken / Surface / Offset / Flip

| Command | Operation | Key widgets | Used by | Status |
|---|---|---|---|---|
| `ProCmdFtExtrude` (blind depth via MRU) | Extrude with typed depth, blur, confirm | `main_dlg_cur`, `GrmTextTagEmbedMRU`, `dashInst0.Quit`, `dashInst0.Done` | boxinator, drilljig, drilljig-gui, drilljig3d, holeinator | ✅ |
| `ProCmdFtExtrude` (up-to-selected plane) | Extrude to a pre-selected offset plane via depth flyout | `maindashInst0.depth_flyout`, `maindashInst0.toselected`, `PH.section_select_list`, `dashInst0.Done` | drilljig, drilljig-gui | ✅ |
| `ProCmdFtExtrude` (2-plane surface, To-Selected both ends) | Surface extrude bounded by two planes | `chkbn.extrev_2_options.0`, `PH.depth1_om`, `PH.depth2_om`, `PH.depth2_sel_list`, `maindashInst0.solid_surf_rg` | surfenator | ✅ |
| `ProCmdFtOffset` | Create an offset surface from selected surface(s) | `maindashInst0.mru_option_menu`, `maindashInst0.ExclSrfColl`, `dashInst0.Done` | drilljig3d, conformal_blank, drilljig3d-probe | ✅ |
| `ProCmdFtThicken` | Thicken a surface quilt into a new solid body | `maindashInst0.Flip`, `maindashInst0.Thickness`, `chkbn.body_page.0`, `body_page.0.0`/`PH.bodyusechkbtnrepwdg`, `dashInst0.Done` | thickenator, drilljig3d, conformal_blank | ✅ |
| `ProCmdRedefine@PopupMenuGraphicWinStack` | Redefine a feature/body (flip material direction) | `maindashInst0.Flip`, `dashInst0.Done` | flipenator | ✅ |
| `ProCmdRedefine@PopupMenuTree` | Redefine a feature via tree context (e.g. csys → file transform) | `Odui_Dlg_00`, `t1.OffsetType` | drilljig, drilljig_core (Build-CsysReimportMacro) | ✅ (⚠️ file-dialog legs) |
| `maindashInst0.Flip` | Toggle flip/material direction | `main_dlg_cur`, `maindashInst0.Flip` | thickenator, flipenator, drilljig3d, conformal_blank | ✅ |

Extrude, blind depth (boxinator canonical — ONE atomic macro):
```
~ Command `ProCmdFtExtrude`;
~ Update `main_dlg_cur` `GrmTextTagEmbedMRU` `<depth>`;
~ Activate `main_dlg_cur` `GrmTextTagEmbedMRU`;
~ Enter `main_dlg_cur` `dashInst0.Quit`; ~ Exit `main_dlg_cur` `dashInst0.Quit`;
~ Activate `main_dlg_cur` `dashInst0.Done`;
```

Extrude up-to a pre-selected offset plane (drilljig box build — feed the plane by ID before opening):
```
~ Command `ProCmdFtExtrude`;
~ Command `ProCmdViewSketchView`;
~ Command `ProCmdSketRectangle` 1;
# ... user draws, sketch done ...
~ Select `main_dlg_cur` `maindashInst0.depth_flyout`;
~ Close  `main_dlg_cur` `maindashInst0.depth_flyout`;
~ Activate `main_dlg_cur` `maindashInst0.toselected` 1;
~ Trigger `extrev_1_placement.0.0` `PH.section_select_list` `0`;
~ Trigger `extrev_1_placement.0.0` `PH.section_select_list` ``;
# (Get-SelectDatumByIdMacro feeds the up-to plane here)
~ Enter `main_dlg_cur` `dashInst0.Quit`; ~ Exit `main_dlg_cur` `dashInst0.Quit`;
~ Activate `main_dlg_cur` `dashInst0.Done`;
```

Offset surface (drilljig3d / conformal_blank — must be atomic with the following Thicken):
```
~ Command `ProCmdFtOffset`;
~ Input  `main_dlg_cur` `maindashInst0.mru_option_menu` `0`;
~ Update `main_dlg_cur` `maindashInst0.mru_option_menu` `0`;
~ Trigger `main_dlg_cur` `maindashInst0.ExclSrfColl` `0`;
~ Trigger `main_dlg_cur` `maindashInst0.ExclSrfColl` ``;
~ FocusOut `main_dlg_cur` `maindashInst0.mru_option_menu`;
~ Activate `main_dlg_cur` `dashInst0.Done`;
```

Thicken → new body (drilljig3d / conformal_blank variant — flip once, route to new body):
```
~ Command `ProCmdFtThicken`;
~ Activate `main_dlg_cur` `maindashInst0.Flip`;
~ Activate `main_dlg_cur` `chkbn.body_page.0` 1;
~ Activate `body_page.0.0` `PH.bodyusechkbtnrepwdg` 1;
~ Activate `main_dlg_cur` `dashInst0.Done`;
```

Thicken with explicit thickness (thickenator variant — dual Flip + Thickness field):
```
~ Command `ProCmdFtThicken`;
~ Enter `main_dlg_cur` `dashInst0.Quit`; ~ Exit `main_dlg_cur` `dashInst0.Quit`;
~ Activate `main_dlg_cur` `maindashInst0.Flip`;
~ Activate `main_dlg_cur` `maindashInst0.Flip`;
~ Input `main_dlg_cur` `maindashInst0.Thickness` `<thickness>`;
~ Activate `main_dlg_cur` `maindashInst0.Thickness`;
~ Activate `main_dlg_cur` `chkbn.body_page.0` 1;
~ Activate `body_page.0.0` `PH.bodyusechkbtnrepwdg` 1;
~ Activate `main_dlg_cur` `dashInst0.Done`;
~ Activate `main_dlg_cur` `buffer_clean`;
```

**Curved conformal-blank workflow — AUTHORITATIVE operator recording (`curvedworkflow`, user 2026-07-27).**
This is the ground-truth offset+thicken sequence for the curved drill jig. It CORRECTS the two
entries above (which used the wrong widgets): the offset distance AND the thickness are both set via
`GrmTextTagEmbedMRU` (NOT `mru_option_menu`/`ExclSrfColl` for the offset, NOT `maindashInst0.Thickness`/
`Flip`/body-page for the thicken); and the offset quilt must be SHOWN (right-click the offset feature in
the tree → `ProCmdViewShow@PopupMenuTree`) BEFORE the thicken can pick it. TWO `@PAUSE_FOR_SCREEN_PICK`:
(1) pick the surface into the offset collector `references.1.0 PH.SrfCollTbl` after `ProCmdFtOffset`,
(2) pick the (now-shown) quilt after `ProCmdFtThicken`. A RunMacro CANNOT replay a pause, so automation
must either pre-select by ID (unverified for these two commands) or split into arm/pick/finish steps.
Verbatim:
```
mapkey curvedworkflow ~ Command `ProCmdFtOffset` ;
~ FocusOut `references.1.0` `PH.SrfCollTbl`; @PAUSE_FOR_SCREEN_PICK;   # pick the surface to offset
~ Open   `main_dlg_cur` `GrmTextTagEmbedMRU`;
~ Close  `main_dlg_cur` `GrmTextTagEmbedMRU`;
~ Update `main_dlg_cur` `GrmTextTagEmbedMRU` `0`;                       # offset distance (standoff) = 0
~ Activate `main_dlg_cur` `dashInst0.Done`;
# --- SHOW the offset quilt (it is hidden after creation) so thicken can pick it ---
~ RButtonArm `main_dlg_cur` `PHTLeft.AssyTree` `T3 20`;                 # right-click the offset feature node
~ PopupOver  `main_dlg_cur` `PM_PHTLeft.AssyTree` 1 `PHTLeft.AssyTree`;
~ Open  `main_dlg_cur` `PM_PHTLeft.AssyTree`; ~ Close `main_dlg_cur` `PM_PHTLeft.AssyTree`;
~ Command `ProCmdViewShow@PopupMenuTree` ;
~ Command `ProCmdFtThicken` ;
@PAUSE_FOR_SCREEN_PICK;                                                 # pick the (shown) quilt to thicken
~ Update `main_dlg_cur` `GrmTextTagEmbedMRU` `.25`;                     # thickness = .25
~ Activate `main_dlg_cur` `GrmTextTagEmbedMRU`;
~ Enter `main_dlg_cur` `dashInst0.Quit`; ~ Exit `main_dlg_cur` `dashInst0.Quit`;   # blur the field
~ Activate `main_dlg_cur` `dashInst0.Done`;
```
Reconciled into `lib/conformal_blank.ps1` (`Get-OffsetMacro` / `Get-ThickenMacro` / `Get-ShowByIdMacro` +
`Invoke-ConformalBlank` 2-phase) 2026-07-27; LIVE-UNVERIFIED (whether `ProCmdFtOffset`/`ProCmdFtThicken`
consume a pre-selected-by-ID surface here vs needing the operator pick).

Surface extrude bounded by two To-Selected planes (surfenator — complex, includes project + tree expand):
```
~ Command `ProCmdFtExtrude`;
~ Command `ProCmdSketProject` 1;   # project curves; embedded selection loop
~ Activate `Odui_Dlg_02` `stdbtn_1`;
~ Command `ProCmdSketDone`;
~ Activate `UI Message Dialog` `ok`;
~ Activate `main_dlg_cur` `chkbn.extrev_2_options.0` 1;
~ Select `extrev_2_options.0.0` `PH.depth1_om` 1 `toselected`;
~ Select `extrev_2_options.0.0` `PH.depth2_om` 1 `toselected`;
~ Expand `main_dlg_cur` `PHTLeft.AssyTree` `T7 10 21`;
~ Trigger `extrev_2_options.0.0` `PH.depth2_sel_list` `0`;
~ Focus   `extrev_2_options.0.0` `PH.depth2_sel_list`;
~ Select  `extrev_2_options.0.0` `PH.depth2_sel_list` 0;
~ Trigger `extrev_2_options.0.0` `PH.depth2_sel_list` ``;
```

Redefine → flip (flipenator):
```
~ Command `ProCmdRedefine@PopupMenuGraphicWinStack`;
~ Activate `main_dlg_cur` `maindashInst0.Flip`;
~ Activate `main_dlg_cur` `dashInst0.Done`;
```

Gotchas:
- **Two depth-field families:** boxinator/pocketinator use `GrmTextTagEmbedMRU`; drilljig_core's cut-finish uses `maindashInst0.def_depth1_ip`. They are not interchangeable — match the macro's own path.
- **Offset+Thicken must be ONE macro** so the thicken consumes the freshly-created offset surface from the buffer context.
- **Thicken flip direction:** default thickens *toward* the part; one `Flip` grows it *away* (confirmed needed live 2026-06-24). thickenator uses a *double* Flip to guarantee orientation.
- **`ExclSrfColl`:** `0` arms the collector to grab the buffered surface, empty string finalizes.
- **surfenator tree path `T7 10 21`** is model-specific — will differ on other assemblies.
- **`ProCmdSketProject` is ⚠️ unverified in drilljig** but ✅ confirmed in surfenator's extrude flow.
- **Extrude-to plane must be fed by the Datum-typed select** (`Get-SelectDatumByIdMacro`), not the Feature select — a Feature-typed selection won't satisfy the depth collector's geometric-reference filter.

## Datum — Planes / Csys / Points

| Command | Operation | Key widgets | Used by | Status |
|---|---|---|---|---|
| `ProCmdDatumPlane` (offset from plane) | Offset datum plane at typed distance from a pre-selected base plane | `Odui_Dlg_00`, `t1.constr_dim1`, `stdbtn_1` | drilljig_core (New-OffsetPlane), drilljig, plane-probe, csysinator | ✅ |
| `ProCmdDatumPlane` (offset from csys axis) | Datum plane offset from a csys axis | `Odui_Dlg_00`, `t1.constr_csys_axis`, `t1.constr_dim1`, `stdbtn_1` | drilljig_core (New-CsysOffsetPlane), drilljig, drilljig-gui | ✅ |
| `ProCmdDatumPlane` (Tangent) | Datum plane tangent to a curved surface through a point | `Odui_Dlg_00`, `constr_type1_OPTMENU1`, `stdbtn_1` | tangent_plane.ps1, tangent-plane-probe | ⚠️ |
| `ProCmdDatumCsys` (3-plane) | Csys at intersection of 3 perpendicular planes (X/Y/Z-normal order) | `Odui_Dlg_00`, `stdbtn_1` | drilljig_core (Build-CsysFromPlanesMacro), csysinator, drilljig | ✅ |
| `ProCmdDatumCsys` (from 1 ref csys) | Csys copied from a single reference csys | `Odui_Dlg_00`, `stdbtn_1` | drilljig_core (Build-CsysFromCsysMacro), drilljig | ✅ |
| `ProCmdDatumPointGeneral` (3-plane ∩) | Datum point at intersection of 3 pre-selected planes | `Odui_Dlg_00`, `stdbtn_1` | drilljig, drilljig-gui, orthogrid_points (Build-IntersectPointMacro) | ✅ (3-plane) / ⚠️ (edge∩plane) |
| `ProCmdDatumPoint` (Offset Coordinate System table) | Grid of datum points from an X/Y/Z table off a csys | `Odui_Dlg_00`, `t1.PntTypeOptMenu`, `t1.DirRefList`, `t1.add_pnt_btn`, `t1.pnt_table`, `stdbtn_1` | drilljig_core (Build-CsysOffsetPointsMacro), orthogrid_points (Build-PointGridMacro), drilljig STAGE 7 | ⚠️ |
| `ProCmdNaMeasureTransform` | Measure→Transform between two csys; export transform to file | `nmd_1`, `nmd_setup_tbl`, `nmd_info_pb`, `texttool`, `file_saveas` | drilljig_core (Build-CsysTransformExportMacro), drilljig --reref transform, csystrf-probe | ⚠️ |

Offset plane from a base plane (pre-select the base by ID first — atomic):
```
~ Command `ProCmdDatumPlane`;
~ Input  `Odui_Dlg_00` `t1.constr_dim1` `<offset>`;
~ Update `Odui_Dlg_00` `t1.constr_dim1` `<offset>`;
~ FocusOut `Odui_Dlg_00` `t1.constr_dim1`;
~ Activate `Odui_Dlg_00` `stdbtn_1`;
```

Offset plane from a csys axis (dimension optional — omit when offset ≈ 0 to reuse base datum):
```
~ Command `ProCmdDatumPlane`;
~ Open   `Odui_Dlg_00` `t1.constr_csys_axis`;
~ Close  `Odui_Dlg_00` `t1.constr_csys_axis`;
~ Select `Odui_Dlg_00` `t1.constr_csys_axis` 1 `Axis_X`;   # Axis_X|Y|Z
~ Input  `Odui_Dlg_00` `t1.constr_dim1` `<offset>`;
~ Update `Odui_Dlg_00` `t1.constr_dim1` `<offset>`;
~ Activate `Odui_Dlg_00` `t1.constr_dim1`;
~ FocusOut `Odui_Dlg_00` `t1.constr_dim1`;
~ Activate `Odui_Dlg_00` `stdbtn_1`;
```

Csys from 3 planes (pre-select 3 planes: 1st with buffer_clean, 2nd/3rd `-NoClear`):
```
~ Command `ProCmdDatumCsys`;
~ Activate `Odui_Dlg_00` `stdbtn_1`;
```

Datum point at 3-plane intersection (all three refs Feature-type, accumulated):
```
# Get-SelectByIdMacro -FeatId $PlaneIds[0]           (buffer_clean)
# Get-SelectByIdMacro -FeatId $PlaneIds[1] -NoClear  (accumulate)
# Get-SelectByIdMacro -FeatId $PlaneIds[2] -NoClear  (accumulate)
~ Command `ProCmdDatumPointGeneral`;
~ Activate `Odui_Dlg_00` `stdbtn_1`;
```

Datum-point grid from a csys offset table (⚠️ UNVERIFIED widgets — never recorded live):
```
~ Command `ProCmdDatumPoint`;
~ Open   `Odui_Dlg_00` `t1.PntTypeOptMenu`;
~ Close  `Odui_Dlg_00` `t1.PntTypeOptMenu`;
~ Select `Odui_Dlg_00` `t1.PntTypeOptMenu` 1 `Offset Coordinate System`;
~ Update `Odui_Dlg_00` `t1.DirRefList` `$TopBaseId`;
~ Update `Odui_Dlg_00` `t1.DirRefList` `$FrontBaseId`;
~ Activate `Odui_Dlg_00` `t1.add_pnt_btn`;
~ Update `Odui_Dlg_00` `t1.pnt_table` <row> `xax_axis` `<x>`;
~ Update `Odui_Dlg_00` `t1.pnt_table` <row> `zax_axis` `<z>`;
~ Activate `Odui_Dlg_00` `stdbtn_1`;
```

Csys → file transform reref (⚠️ file-dialog legs unverified):
```
# Redefine base csys offset type to 'file':
~ Command `ProCmdRedefine@PopupMenuTree`;
~ Open   `Odui_Dlg_00` `t1.OffsetType`;
~ Close  `Odui_Dlg_00` `t1.OffsetType`;
~ Select `Odui_Dlg_00` `t1.OffsetType` 1 `file`;
~ Activate `file_open` `desktop_pb`;
~ Command `ProFileSelPushOpen_Standard@context_dlg_open_cmd`;
~ Activate `Odui_Dlg_00` `stdbtn_1`;

# Measure→Transform export:
~ Command `ProCmdNaMeasureTransform`;
~ Trigger `nmd_1` `nmd_setup_tbl` 2 `0` `References`;
~ Trigger `nmd_1` `nmd_setup_tbl` 2 `` ``;
~ Activate `nmd_1` `nmd_info_pb`;
~ Select `texttool` `MenuBar` 1 `FileMenu`;
~ Activate `texttool` `SaveAsPushButton`;
~ Activate `file_saveas` `desktop_pb`;
~ Activate `file_saveas` `OK`;
~ Activate `nmd_1` `nmd_exit_pb`;
```

Gotchas:
- **Plane order = axis order** for `ProCmdDatumCsys` (3-plane): select in X/Y/Z-normal order for correct axis alignment. The ORIGIN (the intersection) is correct regardless of order; only the axis assignment depends on it. Plane normals read null on this build, so axis direction is a VISUAL check — if mirrored, reorder the plane picks / use a flip flag.
- **3-plane intersection point refs must be Feature-type** (`Get-SelectByIdMacro`, not the Datum/Point variant), else the intersection fails. A coord of ~0 reuses the base datum directly rather than making a degenerate plane.
- **⚠️ Tangent plane by-ID feed** (`constr_type1_OPTMENU1` = Tangent) is not yet confirmed live — surface + point accumulated; tangent constraint applies to the surface, the point is the through-point ref.
- **⚠️ Offset-csys datum-point table** widgets are best-guess (inherited from the abandoned `Build-PointGridMacro`; no recording exists). Gate with a VersionStamp canary AND an exact new-point COUNT check; fall through to the manual path on any miss.
- **⚠️ Transform reref file dialogs** (Save-As filename, file-open) are never typed in the recording — capture with `visible_mapkeys yes` before trusting (`csystrf-probe.cmd` is the recorder for this).
- **`ProCmdDatumPointGeneral` is the general command** (not `ProCmdDatumPoint`) — the 3-plane-intersection route is proven live; selecting an edge/surface by ID does NOT load it as a datum-point reference on imported bodies (edge∩plane refuted live).

## Holes & Patterns

| Command | Operation | Key widgets | Used by | Status |
|---|---|---|---|---|
| `ProCmdHole` (thru-all On-Point) | On-point hole, thru-all, standard layout, body select, diameter | `maindashInst0.hole_depth_to_type_flybtn`, `maindashInst0.StrHoleDepThruAllF`, `chkbn.std_hle_layout.0`, `chkbn.std_hole_note_layout.0`, `chkbn.body_page.0`, `body_page.1.0`/`PH.bodyselectrepwdg_list`, `maindashInst0.diameter_mip_OptionMenu`, `dashInst0.Done` | holeinator, drilljig_core (Build-HoleMacro), drilljig STAGE 3, drilljig3d, conformal_blank | ✅ |
| `ProCmdHole` (blind + optional flip/surface) | Blind-depth hole with optional surface pre-select + direction flip | + `maindashInst0.Flip`, `maindashInst0.StrHoleDepUpToSelSrf` | drilljig_core (Build-NormalHoleMacro), drilljig3d STAGE 2 | ✅ |
| `ProCmdGeomPattern` (arm dir-1) | Open direction pattern, arm dir-1 collector | `main_dlg_cur`, `maindashInst0.ui_pat_dir_dir1` | orthogrid_points (Build-PatternArmMacro), drilljig_core, slotinator | ✅ |
| Pattern dir-1 count/spacing/flip | Set dir-1 instances, increment, optional flip | `ui_pat_dir_1_num_inst`, `ui_pat_dir_1_incr`, `ui_pat_dir_1_flip` | orthogrid_points, slotinator, drilljig_core | ✅ |
| Pattern confirm | Finalize the pattern | `dashInst0.stdbtn_1` / `Odui_Dlg_00`/`stdbtn_1` | orthogrid_points, slotinator | ✅ |
| `ProCmdPattern` | General feature pattern (dimension/table) — recorder captures dir-2 | — | holepat-probe, slotpat-probe | ⚠️ |

On-point thru-all hole (place point by ID first; optional surface pre-select `-NoClear` for normal orientation — ONE atomic macro):
```
~ Command `ProCmdHole`;
~ Select `main_dlg_cur` `maindashInst0.hole_depth_to_type_flybtn`;
~ Close  `main_dlg_cur` `maindashInst0.hole_depth_to_type_flybtn`;
~ Activate `main_dlg_cur` `maindashInst0.StrHoleDepThruAllF` 1;
~ Activate `main_dlg_cur` `chkbn.std_hle_layout.0` 1;
~ Activate `main_dlg_cur` `chkbn.std_hole_note_layout.0` 1;
~ Activate `main_dlg_cur` `chkbn.body_page.0` 1;
~ Trigger `body_page.1.0` `PH.bodyselectrepwdg_list` `<body_index>`;
~ Trigger `body_page.1.0` `PH.bodyselectrepwdg_list` ``;
~ Focus  `body_page.1.0` `PH.bodyselectrepwdg_list`;
~ Select `body_page.1.0` `PH.bodyselectrepwdg_list` 1 `<body_index>`;
~ Trigger `body_page.1.0` `PH.bodyselectrepwdg_list` ``;
~ Input  `main_dlg_cur` `maindashInst0.diameter_mip_OptionMenu` `<diameter>`;
~ Update `main_dlg_cur` `maindashInst0.diameter_mip_OptionMenu` `<diameter>`;
~ Activate `main_dlg_cur` `maindashInst0.diameter_mip_OptionMenu`;
~ FocusOut `main_dlg_cur` `maindashInst0.diameter_mip_OptionMenu`;
~ Activate `main_dlg_cur` `dashInst0.Done`;
```

Blind hole with optional flip (leading `Flip` before `ProCmdHole` when non-default direction needed):
```
~ Activate `main_dlg_cur` `maindashInst0.Flip`;   # optional
~ Command `ProCmdHole`;
# ... depth-type flyout, then StrHoleDepUpToSelSrf (or blind) instead of StrHoleDepThruAllF ...
~ Activate `main_dlg_cur` `maindashInst0.StrHoleDepUpToSelSrf` 1;
# ... std layout toggles, body select, diameter, Done (same as above) ...
```

Direction pattern (split-macro; confirmed live 2026-07-07). Arm → user picks direction ref → set values → confirm:
```
# A) arm dir-1 (PAUSE_FOR_SCREEN_PICK: user picks direction reference):
~ Command `ProCmdGeomPattern`;
~ Trigger `main_dlg_cur` `maindashInst0.ui_pat_dir_dir1` `0`;
~ Trigger `main_dlg_cur` `maindashInst0.ui_pat_dir_dir1` ``;

# B) set count + spacing (optional flip first):
~ Activate `main_dlg_cur` `maindashInst0.ui_pat_dir_1_flip`;          # optional
~ Input  `main_dlg_cur` `maindashInst0.ui_pat_dir_1_num_inst` `<count>`;
~ Update `main_dlg_cur` `maindashInst0.ui_pat_dir_1_num_inst` `<count>`;
~ Activate `main_dlg_cur` `maindashInst0.ui_pat_dir_1_num_inst`;
~ FocusOut `main_dlg_cur` `maindashInst0.ui_pat_dir_1_num_inst`;
~ Input  `main_dlg_cur` `maindashInst0.ui_pat_dir_1_incr` `<spacing>`;
~ Update `main_dlg_cur` `maindashInst0.ui_pat_dir_1_incr` `<spacing>`;
~ Activate `main_dlg_cur` `maindashInst0.ui_pat_dir_1_incr`;
~ FocusOut `main_dlg_cur` `maindashInst0.ui_pat_dir_1_incr`;

# C) confirm:
~ Activate `main_dlg_cur` `dashInst0.stdbtn_1`;
```

Slotinator pattern direction fed BY DATUM (tree-search channel is dead for pattern targets):
```
# Get-SelectDatumByIdMacro -FeatId $dirDatumId -NoClear   (TOP for X-march, FRONT for Z-march)
# then trigger/activate ui_pat_dir_dir1, set ui_pat_dir_1_num_inst / ui_pat_dir_1_incr,
# optional ui_pat_dir_1_flip, then Odui_Dlg_00 stdbtn_1 to confirm.
```

Gotchas:
- **Entire hole dashboard is ONE atomic macro** — depth-type flyout, layout toggles, body select, diameter, Done all in a single RunMacro. Point must be pre-selected by ID *before* `ProCmdHole`; add a surface pre-select with `-NoClear` for On-Point normal orientation.
- **`StrHoleDepThruAllF` confirmed live 2026-06-11.** Blind holes swap in `StrHoleDepUpToSelSrf` (or the blind depth type) and an optional leading `Flip`.
- **On intersection ("hang-in-space") points, pre-select the SIDE OFFSET plane** (`$sidePlane.FeatId`, the box face the points sit on) as a Datum-typed reference before `ProCmdHole` — with `buffer_clean` FIRST — else `ProCmdHole` defaults to Linear placement instead of On-Point. A `maindashInst0.Flip` after corrects drill direction.
- **Pattern direction reference is a BASE DATUM PLANE** (TOP for X-march, FRONT for Z-march); copies march along the plane normal. The **tree-search select channel is DEAD for the pattern target** (FIX 1, trail.txt.33) — click the seed in the tree, or auto-reselect via raw-COM (`Invoke-SlotPatternFromSeed`).
- **⚠️ 2-direction pattern widgets** (`ui_pat_dir_dir2`, `ui_pat_dir_2_num_inst`, `ui_pat_dir_2_incr`) were never recorded — dir-2 needs a live capture (`holepat-probe.cmd` / `slotpat-probe.cmd` are the recorders). Single-direction (dir-1) is proven.
- **⚠️ Invoke-SlotPatternFromSeed** raw-COM target registration is proven for `ProCmdRound` (edginator) but unverified for `ProCmdGeomPattern`; falls back to the manual seed-click on any miss.
- **The drill loop is STRICTLY LINEAR** — one `ProCmdHole` dashboard + one regen per point. Trimming per-hole diameter/body/depth tokens silently drills Creo's DEFAULT values (canary-blind). The only real speedup is cutting the regen count via a pattern.

## Cuts (Remove-Material Extrude)

The cut-finish sequence closes a drawn sketch and drives a remove-material extrude with a target body. Used by every slot/pocket workflow.

| Command | Operation | Key widgets | Used by | Status |
|---|---|---|---|---|
| `Build-CutFinishMacro` | Finish sketch → optional flip → blind depth → remove-material → body select → confirm | `maindashInst0.flip_pb`, `maindashInst0.def_depth1_ip`, `dashInst0.Quit`, `maindashInst0.remove_material_cb`, `chkbn.body_page.0`, `body_page.1.0`/`PH.bodyselectrepwdg_list`, `dashInst0.Done` | drilljig_core, slotinator, pocketinator, drilljig STAGE 4 | ✅ |

Cut finish (ONE atomic macro; flip optional, depth typed only when > 0):
```
~ Command `ProCmdSketDone`;
~ Activate `main_dlg_cur` `maindashInst0.flip_pb`;                # optional (-Flip)
~ Input  `main_dlg_cur` `maindashInst0.def_depth1_ip` `<depth>`;
~ Update `main_dlg_cur` `maindashInst0.def_depth1_ip` `<depth>`;
~ Activate `main_dlg_cur` `maindashInst0.def_depth1_ip`;
~ FocusOut `main_dlg_cur` `maindashInst0.def_depth1_ip`;
~ Enter `main_dlg_cur` `dashInst0.Quit`; ~ Exit `main_dlg_cur` `dashInst0.Quit`;
~ Activate `main_dlg_cur` `maindashInst0.remove_material_cb` 1;
~ Activate `main_dlg_cur` `chkbn.body_page.0` 1;
~ Trigger `body_page.1.0` `PH.bodyselectrepwdg_list` `<body_index>`;
~ Trigger `body_page.1.0` `PH.bodyselectrepwdg_list` ``;
~ Focus  `body_page.1.0` `PH.bodyselectrepwdg_list`;
~ Select `body_page.1.0` `PH.bodyselectrepwdg_list` 1 `<body_index>`;
~ Trigger `body_page.1.0` `PH.bodyselectrepwdg_list` ``;
~ Activate `main_dlg_cur` `dashInst0.Done`;
```

Gotchas:
- **Proven live** (slotinator / trail.txt.32). `remove_material_cb` widget mined from trail.txt.8:1799.
- **Depth field is `def_depth1_ip`, NOT `GrmTextTagEmbedMRU`** — the latter is wrong on this build for a Blind-default cut. Depth is only typed when > 0, else Creo's default is used.
- **pocketinator variant** substitutes `GrmTextTagEmbedMRU` for the depth field (boxinator's path) — follows the user's manual sketch-Offset step.
- **Verify-direction loop:** when a seed cut goes the wrong way, `ProCmdEditUndo`, flip, redraw. `flip_pb` is the direction flip (the default cut often goes the wrong way into the plate); `--no-flip` skips it.

## Rounds / Edges

| Command | Operation | Key widgets | Used by | Status |
|---|---|---|---|---|
| `ProCmdRound` | Round/fillet buffered edges at a radius | `page_Model_control_btn`, `maindashInst0.cir_rad_list`, `dashInst0.Done` | radinator, cornerinator, edge_round.ps1, drilljig STAGE 2b, Invoke-AutoCornerRound | ✅ |
| select-edge-by-id (accumulate) | Configure Find tool for edges by ID and loop-accumulate into buffer | `selspecdlg0`, `SelOptionRadio`, `LookByOptionMenu`, `RuleTab`, `RuleTypes`, `InputIDPanel`, `EvaluateBtn`, `ApplyBtn` | cornerinator, radinator, edge_round.ps1 | ✅ |

Round buffered edges (ONE atomic macro; select/accumulate edges by ID first):
```
~ Activate `main_dlg_cur` `page_Model_control_btn` 1;
~ Command `ProCmdRound`;
~ Input  `main_dlg_cur` `maindashInst0.cir_rad_list` `<radius>`;
~ Update `main_dlg_cur` `maindashInst0.cir_rad_list` `<radius>`;
~ Activate `main_dlg_cur` `maindashInst0.cir_rad_list`;
~ Activate `main_dlg_cur` `dashInst0.Done`;
```

Edge select-by-ID setup (radinator/cornerinator — All→ID rule switch, then per-ID accumulate):
```
~ Select `selspecdlg0` `SelOptionRadio` 1 `Edge`;
~ Select `selspecdlg0` `LookByOptionMenu` 1 `Edge`;
~ Select `selspecdlg0` `RuleTab` 1 `Attributes`;
~ Select `selspecdlg0` `RuleTab` 1 `Misc`;
~ Select `selspecdlg0` `RuleTypes` 1 `All`;
~ Select `selspecdlg0` `RuleTypes` 1 `ID`;
# per edge:
~ Update `selspecdlg0` `ExtRulesLayout.ExtBasicIDLayout.InputIDPanel` `<id>`;
~ Activate `selspecdlg0` `EvaluateBtn`;
~ Activate `selspecdlg0` `ApplyBtn`;
```

Gotchas:
- **Atomic** — the full round (page switch → command → radius Input/Update/Activate → Done) must be one RunMacro. Proven live in radinator (node-to-stiffener fillets), edginator, cornerinator, and drilljig STAGE 2b.
- **Batch ≤ 40 edges per round** (Invoke-AutoCornerRound). Edges are accumulated into the buffer across the batch, then one round feature per batch; `ProCmdSelClear` between batches.
- **`Invoke-AutoCornerRound` / edginator use pure VB-API edge discovery + raw-COM selection (NO Find tool)** — `GetItemById(ITEM_EDGE, 1..N)` sweep → `CMpfcSelect.CreateModelItemSelection` + `CurrentSelectionBuffer().AddSelection`. This is the channel that works on imported/"foreign" bodies where the Find tool is dead for edges.

## Copy / Paste-Special (Template Redirection)

Used by nodelator to duplicate a node feature by reference and reroute its external references to a new datum point.

| Command | Operation | Key widgets | Used by | Status |
|---|---|---|---|---|
| `ProCmdEditCopy` | Copy the selected feature to clipboard | — | nodelator | ✅ |
| `ProCmdEditPasteSpecial` | Paste-by-reference (disable make-copies, enable paste-by-ref) | `paste_special`, `makecopyiesPB`, `pastebyrefPB`, `okPB` | nodelator | ✅ |
| `t1.ext_ref_table` | Reroute external references row-by-row + add-as-new-body | `Odui_Dlg_00`, `t1.ext_ref_table`, `ext_ref_list`, `t1.body_add_chk_btn` | nodelator | ✅ |

Paste-special by reference + external-ref rerouting (node extrude — atomic):
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
# then select the target datum point by ID and double-tap stdbtn_1 to complete:
~ Activate `Odui_Dlg_00` `stdbtn_1`;
~ Activate `Odui_Dlg_00` `stdbtn_1`;
```

Gotchas:
- **Row indices (2, 3, 4, 5) are specific to the node extrude reference structure** — different feature types have different rows. There is no reliable programmatic way to determine the row mapping; extract it from a recorded Paste-Special example.
- **`makecopyiesPB 0`** disables copy mode; **`pastebyrefPB 1`** enables paste-by-reference.
- **Double-tap `stdbtn_1`** completes the paste at the selected datum point.
- The example feature MUST actually reference the datum point (as sketch origin / placement ref) — paste-by-reference has nothing to reroute if the feature just sits near a point geometrically.

## Component Replacement (Assembly)

Gripenator swaps fastener/nut part numbers via the Replace Components dialog cascaded into the model browser + query dialogs.

| Command | Operation | Key widgets | Used by | Status |
|---|---|---|---|---|
| `ProCmdReplComp@PopupMenuGraphicWinStack` | Replace components with new part numbers | `gen_repl_dlg`, `mdlbrowser`, `brws_query` | gripenator | ✅ |
| `gen_repl_dlg` navigation | New-comp list/browse + Done | `Lst_NewComp`, `PB_NewComp`, `DoneBtn` | gripenator | ✅ |
| `mdlbrowser` navigation | Tree menu, Find, OK in model browser | `MBar`/`TreeMenu`, `Find`, `OK` | gripenator | ✅ |
| `brws_query` search | Class-menu filter + value input + find/select | `ClassOptMenu`, `ValueInput`, `AddBtn`, `FindNextBtn`, `SelectBtn`, `CloseBtn` | gripenator | ✅ |
| `HiliteScreenCheckBtn` | Disable on-screen highlight during selection | `selspecdlg0`, `HiliteScreenCheckBtn` | gripenator | ✅ |

Replace-component flow (atomic; cascades gen_repl_dlg → mdlbrowser → brws_query):
```
~ Command `ProCmdReplComp@PopupMenuGraphicWinStack`;
~ Trigger `gen_repl_dlg` `Lst_NewComp` `0`; ~ Trigger `gen_repl_dlg` `Lst_NewComp` ``;
~ Activate `gen_repl_dlg` `PB_NewComp`;
~ Select `mdlbrowser` `MBar` 1 `TreeMenu`; ~ Close `mdlbrowser` `MBar`;
~ Activate `mdlbrowser` `Find`;
~ Open   `brws_query` `ClassOptMenu`;
~ Close  `brws_query` `ClassOptMenu`;
~ Select `brws_query` `ClassOptMenu` 1 `Model Name`;
~ Input  `brws_query` `ValueInput` `<PartNumber>`;
~ Update `brws_query` `ValueInput` `<PartNumber>`;
~ Activate `brws_query` `AddBtn`;
~ Activate `brws_query` `FindNextBtn`;
~ Activate `brws_query` `SelectBtn`;
~ Activate `brws_query` `CloseBtn`;
~ Activate `mdlbrowser` `OK`;
~ Activate `gen_repl_dlg` `DoneBtn`;
```

Gotchas:
- **Full dialog cascade must be one atomic macro** — the browser and query dialogs share command context.
- Component selection uses the Find tool with `SelOptionRadio`=Component; `HiliteScreenCheckBtn 0` turns off screen highlighting during the pick.

## Legacy / Archived & Unknown Mapkeys

These appear in the `ps1 archive\` folder (superseded by the `.cmd` engines) or are documented-but-inactive tokens.

| Command | Operation | Status | Notes |
|---|---|---|---|
| `flipenator.ps1`, `gripenator.ps1`, `nodelator.ps1`, `radinator.ps1`, `surfenator.ps1`, `thickenator.ps1` (mapkey bodies) | Archived PowerShell versions of the corresponding `.cmd` tools | 🗄️ | Superseded by the active `.cmd` scripts; recipes identical. Historical reference only. |
| `maindashInst0.solid_surf_rg` | Set extrude output to Surface (not solid) | 🗄️ | surfenator.ps1 archive; live equivalent in surfenator.cmd extrude flow. |
| `ProCmdSketOffset` | Offset sketch geometry by distance | 🗄️ | Documented in code comments; not used in active scripts (VB API has no programmatic sketch-offset — pocketinator PAUSES for a manual Sketch > Offset). |
| `ProCmdSketUse` | Use/reference external geometry in sketch | 🗄️ | Sketcher tool, inactive. |
| `ProCmdViewShow` (generic) | Generic show hidden geometry | 🗄️ | Superseded by `ProCmdViewShow@PopupMenuTree`. |
| `ProCmdNmdTool` | Annotation / Note tool | 🗄️ | Not used in current automation. |
| `ProCmdNaMeasureTransform` | Measure/Transform utility | ❔ | Recorded from trail (csystrf-probe) but only actively wired into drilljig's `--reref transform` (⚠️) — see Datum section. |
| `ProCmdFtOffset` (DEV_NOTES ref) | Offset surface | ✅ | Documented in DEV_NOTES; live-confirmed in drilljig3d / conformal_blank (see Features). |
| `ProCmdDatumPointGeneral` (edge∩plane) | Datum point at edge∩plane | ⚠️ | `Build-EdgePlanePointMacro` not live-confirmed (edge-by-ID does not load as a datum-point ref on foreign bodies; the 3-plane ∩ variant IS confirmed). |

General notes:
- The archived `ps1` scripts fire the same mapkeys as their `.cmd` counterparts and follow the same atomic-dashboard discipline; **prefer the `.cmd` versions.**
- Where DEV_NOTES/CLAUDE.md status disagreed with a script's own recorded status, the more-confirmed live status was taken (e.g. `ProCmdFtOffset` promoted to ✅ on the strength of drilljig3d's recorded use).

---

## Recorder Probes (how to capture new widget names)

When a recipe above is marked ⚠️ or a new command is needed, use the recorder probes rather than guessing widget names (the "mine, don't guess" rule). Each enables `visible_mapkeys yes`, pauses while you perform the operation by hand, then diffs the trail file and writes a `*_recipe.txt` you transcribe into a macro builder:

| Probe | Captures |
|---|---|
| `slotpat-probe.cmd` | Single-direction feature-pattern widgets |
| `holepat-probe.cmd` | 2-direction hole geometry-pattern widgets (`ui_pat_dir_dir2`, …) |
| `csystrf-probe.cmd` | Csys "change type → file transform" file-dialog legs |
| `pointref-probe.cmd` | Whether a command consumes datum refs fed by ID |
| `cornerinator-probe.cmd` / `vbselect-probe.cmd` | Find-tool select-all vs raw-COM edge selection |
| `fastener-probe.cmd` | Which coordinate read returns fastener centers |

---

*Compiled from a full sweep of the toolkit (34 `.cmd` scripts, `jiginator.ps1`, `lib\*.ps1` macro
builders, `ps1 archive\`, and the reference docs) — 364 raw mapkey usages deduplicated. Source of
truth for individual scripts remains their own code + [`CLAUDE.md`](CLAUDE.md) /
[`DEV_NOTES.md`](DEV_NOTES.md). Re-record any ⚠️ recipe with `visible_mapkeys yes` before trusting it
on a new Creo build.*
