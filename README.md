# Drill Jig Automation

Automation tooling that leverages the Creo Parametric VB API to **generate drill jigs** — locating geometry, bushing placements, and jig plates — directly from a part's hole pattern, without requiring software licenses beyond standard Creo Parametric.

Both **flat** (rectangular plate) and **curved / conformal** (a jig that follows a part's curved surface) jigs are supported, and each has a guided **WinForms wizard GUI** as well as a console front-end. The recommended way in is the GUI: **[`pipeline/drilljig-gui.cmd`](pipeline/drilljig-gui.cmd)** for a flat jig, or **[`pipeline/drilljig3d-gui.cmd`](pipeline/drilljig3d-gui.cmd)** for a curved one.

## Goal

Given a part (or its hole pattern), the target workflow is to:

1. Read hole locations and diameters from the source model — or define them by hand / from a decision tree
2. Select a drill bushing (OD → the drilled jig-hole diameter, ID → the bore, plus a standard length)
3. Build the jig body — a parametric box for a flat jig, or a conformal blank (offset + thicken of the picked surface) for a curved one
4. Drill a locating hole at every point, at the bushing diameter
5. Cut chip-relief slots so drilling debris can clear
6. Produce a jig model ready for downstream manufacturing

## Approach

All tooling is packaged as single-file `.cmd` executables that embed PowerShell. Each script connects to a live Creo session over the VB API COM interface (`pfcls`), uses the API to gather selections and model data, then executes operations through direct `RunMacro` commands. Complex, repetitive modeling operations can be performed reliably and at scale, with no add-on licenses required.

Two complementary techniques are used throughout:

- **Programmatic (VB API)** — reads and writes Creo data directly without touching the UI. Stable across Creo versions. Used for data extraction and geometry traversal (enumerating bodies, surfaces, edges, dimensions, mass properties). All reads are **ID-only** — the tools never read an `IpfcPoint.Point` coordinate (which crashes on this build), only item IDs, cylinder-axis descriptors, and proven transforms.
- **Mapkeys** — drives the Creo UI by replaying recorded command and widget interactions. Used for feature creation the API alone cannot do (offset, thicken, rounds, extrudes, holes, cuts). More version-sensitive, so widget names are always **transcribed from a real recording, never invented** (see the [`probes/`](probes/) recorders).

Two conventions make this trustworthy end to end:

- **Regenerative dimensioning** — feature-level dimensions (plate size, offset distance, wall thickness) are written via the API, forced through a regen, then re-read to confirm they stuck.
- **Canary gating** — every model-mutating macro is guarded by a `VersionStamp` / feature-diff canary. A macro that changes nothing (a mis-named widget) **aborts and reports**; it never silently no-ops or falsely claims success. A canary that can't be read is treated as a miss, never as an assumption of success.

---

## The Drill Jig GUI — `pipeline/drilljig-gui.cmd`

`drilljig-gui.cmd` is the flagship: a **guided WinForms wizard** over the entire flat drill-jig flow. It is a single hybrid `.cmd`/PowerShell file that launches Windows PowerShell (STA), dot-sources the wizard framework ([`lib/wizard.ps1`](lib/wizard.ps1)) and the shared drill-jig engine ([`lib/drilljig_core.ps1`](lib/drilljig_core.ps1)), and opens one never-closing window.

The window has a **breadcrumb rail** of stage "pills" across the top, a center canvas that swaps per step, and an honesty-chip band + Back/Next bar at the bottom. Navigation is linear, with a clickable breadcrumb to jump back to a reached stage. Blocking Creo work runs behind a **RUN view** (progress bar + live log). The wizard runs the *exact same* proven helpers as the console flow — the GUI and console share one engine, so both benefit from every live-verified fix.

### What the operator does, stage by stage

The breadcrumb shows ten stages (`Welcome · Import · Bushing · Layout · Overview · Datums · Box · Drill · Relief · Done`); several contain more than one screen.

| # | Stage | What happens | Creo picks? |
|---|-------|--------------|-------------|
| 1 | **Welcome** | Landing screen with a rotatable 3D render of a finished jig and a plain-language walkthrough. Purely informational. | No — just open the jig **part** (not an assembly) and keep Creo idle. |
| 2 | **Import** *(optional)* | Optionally read an existing part/assembly's fastener bore centers to use as the hole pattern, or skip and choose a layout later. | Optional — a live fastener read drives Creo via a throwaway connection. |
| 3 | **Bushing** | Walk a decision tree of answer cards to resolve the drilled **hole diameter** (bushing OD or fixed OD) and **bushing length** (fixed `{½, ¾, 1}` + Custom menu). | No — pure catalog cards. |
| 4 | **Bushing** → hole-to-edge margin | Pick/edit the wall margin from the hole to the plate edge (default: one hole diameter). Feeds plate sizing. | No. |
| 5 | **Bushing** → slot depth | Choose the chip-relief slot depth (standard clearance, or thinner for tight spaces). | No. |
| 6 | **Layout** | Choose the hole-point source: **orthogrid** (regular Nx×Nz grid), **custom** (type each X/Z), **fastener** (imported pattern), or **predefined** (datum points already in the model). An embedded editor + preview and an X/Z slot-direction toggle appear. | No — grid/custom/fastener are computed in-window; predefined defers its pick to step 12. |
| 7 | **Layout** → index hole | Pick which hole is the index/datum hole from the computed layout (or it is fixed to hole #1 for an index-relative custom layout). | No. |
| 8 | **Overview** | Rough 3D render (WebView2 + three.js) of the plate, holes, and slots for the chosen layout — drag to rotate. Also hosts the relief-face toggle. | No — in-window preview only. |
| 9 | **Datums** | The tool auto-maps the three default datum planes by name (TOP/SIDE/FRONT) with no clicks; falls back to a pick+verify if it can't. | Usually none. Fallback: Ctrl-click all three default datums, then verify in the GUI. |
| 10 | **Box** → build | Computes the three offset-plane distances (SIDE = bushing length + relief pad, TOP = plate width, FRONT = plate height), asks once whether to add relief slots, then creates the offset planes and opens the sketcher. | Tool-driven: planes + sketcher open automatically. |
| 11 | **Box** → finish | **You draw the plate rectangle** in Creo's open sketcher (CTRL+ALT snaps the corner to the plane intersection), then the tool finishes the sketch and extrudes to the SIDE plane. This is the commit point (no Back past here). | **Yes** — draw the rectangle, Esc to finish. |
| 12 | **Drill** → target points *(predefined only)* | In predefined mode, pick the existing target datum points and verify. Every other mode self-skips (points are created automatically next). | Only in predefined mode. |
| 13 | **Drill** → create + round + drill | Hands-free: creates every datum point as a 3-plane intersection, rounds the box corners, and drills every through-hole at the bushing diameter. | None — hands-free; don't touch Creo during the run. |
| 14 | **Relief** → draw seed | Opens the sketcher on the chosen relief face for one blind slot per hole row (length = part length, width = hole dia). Self-skips if relief is off. | Tool-driven: sketcher opens automatically. |
| 15 | **Relief** → cut + pattern | **You draw the seed slot** over the first row; the tool cuts it, you confirm the direction, and it patterns the seed onto every remaining row hands-free. | **Yes** — draw the seed rectangle, Esc to finish; confirm the pattern direction on the first cut. |
| 16 | **Done** | Summary of what was built, with any honesty warnings (e.g. plate padded for relief that wasn't cut). Finish closes the wizard; the Creo session stays open. | No — verify the geometry in Creo. |

> **Why two steps for the box and the slots.** The arm step (open planes/sketcher) is deliberately split from the finish step (draw + extrude/cut) so the manual rectangle draw is a *wizard pause* rather than a blocking modal that could freeze behind the Creo window.

---

## The Curved (Conformal) Drill Jig GUI — `pipeline/drilljig3d-gui.cmd`

`drilljig3d-gui.cmd` is the **curved analog** of the flat GUI, built for flat-jig parity for panels whose faces are curved and whose fastener bores are *not* axis-parallel. A curved jig cannot be a flat plate, so instead of a box it builds a **conformal blank**: it copies the part's curved face (an offset surface / quilt) and gives it wall thickness (a thicken into a new solid body) — a slab that follows the curvature exactly.

It uses the same [`lib/wizard.ps1`](lib/wizard.ps1) framework, with the curved-specific stages supplied by four step-group libraries ([`lib/curved_gui_steps_*.ps1`](lib/)) and the curved geometry engine ([`lib/conformal_blank.ps1`](lib/conformal_blank.ps1), [`lib/curved_fastener_hole.ps1`](lib/curved_fastener_hole.ps1), [`lib/tangent_plane.ps1`](lib/tangent_plane.ps1), [`lib/curved_slots.ps1`](lib/curved_slots.ps1)). It requires the jig **part** to be the *active* model (right-click-Activate it inside a top-down assembly first).

The breadcrumb stages are `Welcome · Bushing · Surface · Fasteners · Relief · Done`:

| # | Stage | What happens | Creo picks? |
|---|-------|--------------|-------------|
| 1 | **Welcome** | Plain-language overview; reminder to activate the jig part. | No. |
| 2 | **Bushing** | Same decision-tree card walk as the flat GUI (text confirmation, no schematic) to resolve hole diameter and bushing length. | No. |
| 3 | **Bushing** → thickness | Enter the conformal-blank wall thickness (the wall the bushing seats through). Soft-warns if thin. | No. |
| 4 | **Bushing** → standoff | Enter the standoff / chip-clearance offset — how far to float the jig off the part surface (default 0 = flush). | No. |
| 5 | **Surface** → pick surface | Ctrl-click the surface(s) the jig follows, then verify (read ID-only). | **Yes** — pick the surface(s). |
| 6 | **Surface** → open offset | Opens Creo's Offset dashboard on the picked surface(s). Leaves it open. | **Yes** — confirm the surface is in the offset collector; don't press Done. |
| 7 | **Surface** → finish offset | Sets the offset distance (= standoff) and finishes; canary-gated. Shows the new quilt for the thicken. | Indirect. |
| 8 | **Surface** → open thicken | Opens Creo's Thicken dashboard. Leaves it open. | **Yes** — Ctrl-click the shown quilt into the thicken collector; don't press Done. |
| 9 | **Surface** → finish thicken | Sets the thickness and finishes, then re-reads both dims as a backstop and identifies the **new conformal blank body**. Commit point. | Indirect — verify the blank visually. |
| 10 | **Fasteners** → diameter | Enter the fastener-hole / bushing-seat diameter (drilled thru-all into the blank). | No. |
| 11 | **Fasteners** → drill loop | Per fastener: pick that fastener's 3 datum planes, click "Drill this fastener" — the tool makes the 3-plane-intersection datum point, opens the hole, pauses for your **direction pick**, then finishes the hole (canary-gated). Repeat per fastener. | **Yes, repeatedly** — pick 3 planes per fastener + the drill direction reference. |
| 12 | **Relief** → intro | Explains per-hole chip-relief slots and decides whether to add them (auto-yes for 3D-print jigs; asks for metal). | No (in-wizard Yes/No). |
| 13 | **Relief** → plan | Builds the per-hole slot plan from the drilled holes' tangent planes. No Creo mutation. | No. |
| 14 | **Relief** → cut | Per hole: opens a sketch on the hole's tangent plane by ID; **you draw one rectangle** and click OK; the tool cuts it (first cut is verify/flip-checked). | **Yes, per slot** — draw the rectangle. |
| 15 | **Done** | Summary: blank built, holes drilled, slots cut/skipped, any warnings. Finish closes the wizard. | No — verify in Creo. |

> The curved jig drills its holes from **fastener planes** (the "curvedholes" workflow) rather than a manual datum-point Drill stage. Several curved legs (tangent-plane-by-ID, the fastener reference/direction hole) are transcribed from operator recordings and are **canary-gated but live-unverified** — they can only fail to build, never build silently wrong.

---

## Console front-ends

For scripted or headless-ish use, each jig type also has a console driver that runs the same engine over a single Creo COM connection:

- **[`pipeline/drilljig.cmd`](pipeline/drilljig.cmd)** — the flat drill-jig console flow. Merges the bushing pick, the parametric box, corner rounding, datum-point creation, On-Point drilling, and chip-relief slots into one connect → build → drill → slot pass. Supports all four point-source modes (predefined / orthogrid / custom / fastener import) and threads slot depth/direction/face decisions up front so the plate is padded for the relief cut. Flags include `--slot-depth N`, `--slot-dir X|Z`, `--slot-face …`, `--corner-radius N`, `--no-corner-round`, `--no-base-csys`, `--fastener-index`.
- **[`pipeline/drilljig3d.cmd`](pipeline/drilljig3d.cmd)** — the curved / conformal console flow. Click a surface → offset (at a standoff) → thicken into a new body → optionally drill On-Point holes normal to the surface → optionally cut one chip-relief slot per hole. `--no-tree`, `--tangent-orient`, `-defaultorient`, `--no-slots`, `--slot-depth N`.
- **[`pipeline/jiginator.cmd`](pipeline/jiginator.cmd)** — the **bushing selector** on its own. Walks the decision tree ([`docs/drill_jig_decision_tree.json`](docs/drill_jig_decision_tree.json)) and the bushing catalogs ([`data/`](data/)) to recommend a bushing OD/ID/length (OD = the drilled jig-hole diameter), with an OD-first metal path and an ID-first sleeve path. Writes `last_jig_spec.json` as a handoff to the drilling tools.

---

## Repository layout

The `.cmd` tools are grouped by role into four folders; shared PowerShell modules live in `lib/`.

| Folder | Contents |
|--------|----------|
| **[`pipeline/`](pipeline/)** | End-to-end drill-jig flow: `drilljig-gui`, `drilljig3d-gui` (the two wizard GUIs), `drilljig`, `drilljig3d` (consoles), `jiginator` (bushing selector) |
| **[`tools/`](tools/)** | Standalone geometry primitives (see below) |
| **[`previews/`](previews/)** | No-Creo visualizers: `bushing-preview`, `bushing-3d-preview`, `drilljig-3d-preview`, `drilljig-3d-webview` |
| **[`probes/`](probes/)** | Read-only diagnostics + mapkey trail recorders that de-risk a read path or widget sequence before it's trusted in the pipeline |
| **[`lib/`](lib/)** | Dot-sourced PowerShell modules (pure math + COM orchestration) shared by every tool and by both front-ends; `lib/tests/` holds the offline suites |
| **[`data/`](data/), [`docs/`](docs/)** | Bushing catalogs + the decision-tree JSON, plus reference docs, HTML prototypes, operator mapkey recordings, and `TEMPLATE.PS1` / `DEVELOPMENT_SETUP.html` |
| **`artifacts/`** | Machine-generated per-run files: cross-tool handoffs (`last_jig_spec.json`, `fastener_layout.json`, `hole_layout.json`), probe reports, trail recipes, and `<model>_eval.json` packets. Gitignored except a tracked `.gitkeep`; recreated on demand |

Each tool's hybrid header re-anchors `$ScriptDir` to the repo root, so `lib\`, `data\`, `docs\`, and the cross-tool handoff files (`last_jig_spec.json`, `fastener_layout.json`, `hole_layout.json`) resolve identically regardless of which subfolder a tool lives in. Those handoffs — and every other per-run artifact — are written under `artifacts\`, which each tool creates on its first write.

### Standalone tools (`tools/`)

Single-purpose "-inator" primitives. Most are proof-of-concept operations that deliberately do **not** touch the pipeline — each proves one Creo capability in isolation, and several are the building blocks the drill-jig flow later folds in.

| Tool | What it proves out |
|------|--------------------|
| **[boxinator.cmd](tools/boxinator.cmd)** | Creates a rectangular extrude to exact L/W/H, measures the solid, and auto-corrects the depth dimension if it came out wrong — verified parametric geometry creation. |
| **[cornerinator.cmd](tools/cornerinator.cmd)** | Auto-detects a plate's vertical corner edges and rounds them, with a manual-pick fallback. |
| **[csysinator.cmd](tools/csysinator.cmd)** | Creates a datum coordinate system at the intersection of three selected planes, fed by ID. |
| **[diminator.cmd](tools/diminator.cmd)** | Reads a CSV of dimensions back **into** a model (the read-back companion to gauginator), with a 2-pass verify/repair loop for sketch dims. |
| **[fastenator.cmd](tools/fastenator.cmd)** | Reads fastener bore centers from an open part/assembly (cylinder-axis, the proven non-crashing read), projects to a 2D (X,Z) layout, and writes `fastener_layout.json`. |
| **[flipenator.cmd](tools/flipenator.cmd)** | Batch selection capture and per-body flip/mirror redefine operations. |
| **[gauginator.cmd](tools/gauginator.cmd)** | Whole-model traversal + dimension/mass-property extraction to CSV (the export half of the round-trip). |
| **[gripenator.cmd](tools/gripenator.cmd)** | Interactive fastener/nut management in an assembly — filter valid HST fasteners, change diameter/grip with matching nuts, convert coatings to the grounding variant. |
| **[holeinator.cmd](tools/holeinator.cmd)** | Creates a native On-Point hole at every selected datum point, each an atomic select-by-ID + hole-dashboard macro (canary-verifies hole #1 before committing the rest). |
| **[holelayoutinator.cmd](tools/holelayoutinator.cmd)** | Read-only hole-pattern inspection sandbox: reads selected bore surfaces, projects to a tilt-safe 2D layout, and analyses spacing/collision; writes `hole_layout.json`. |
| **[nodelator.cmd](tools/nodelator.cmd)** | Copies a feature to many datum-point locations via Paste-Special by reference, rerouting each placement. |
| **[pocketinator.cmd](tools/pocketinator.cmd)** | Cuts one connected chip-clearance pocket as a shallow blind remove-material extrude, offset inward from the plate boundary. |
| **[radinator.cmd](tools/radinator.cmd)** | Pure-VB-API edge filtering (by length/curve type) feeding a batched round mapkey. |
| **[slotinator.cmd](tools/slotinator.cmd)** | Cuts one blind rectangular chip-relief slot per hole row (seed drawn once, then patterned). |
| **[surfenator.cmd](tools/surfenator.cmd)** | Creates surfaces by extruding selected 3D curves between datum planes. |
| **[thickenator.cmd](tools/thickenator.cmd)** | Thickens selected surface quilts into solid bodies (the pattern reused by boxinator and the conformal blank). |

### Previews / visualizers (`previews/`)

Standalone, **no-Creo** visualization — see what a jig or bushing will look like before any Creo work. Each is driven by the *same* production sources the live tools use (`lib/orthogrid.ps1`, `data/bushings*.csv`), never a re-implementation, and touches nothing in the live pipeline.

- **[bushing-preview.cmd](previews/bushing-preview.cmd)** — 2D bushing schematic (GDI+), rendered from OD/ID/Length via `lib/bushing_svg.ps1`.
- **[bushing-3d-preview.cmd](previews/bushing-3d-preview.cmd)** — a selected bushing as both the 2D schematic and a live 3D model (WPF Media3D, hollow bore + head flange).
- **[drilljig-3d-preview.cmd](previews/drilljig-3d-preview.cmd)** — 3D drill-jig plate with live sliders (WPF Media3D, **zero external DLLs**), dot-sourcing the real `lib/orthogrid.ps1` so it matches production. The zero-dependency fallback renderer.
- **[drilljig-3d-webview.cmd](previews/drilljig-3d-webview.cmd)** — high-fidelity 3D jig hosting the exact approved `docs/drilljig_3d_preview.html` (WebView2 + three.js/WebGL) via `lib/webview2_host.ps1`, which stages a matched WebView2 SDK from Office/Teams/Creo into `%TEMP%` (no download, no vendored binaries).

### Probes / diagnostics (`probes/`)

The "probe, don't guess" layer. Each probe answers one load-bearing live question about a VB-API read path or a mapkey widget sequence before that behavior is trusted in a production tool. Two flavors: **read-only** diagnostics that dump geometry without mutating the model (`fastener-probe`, `drilljig3d-probe`, `holeprobe`, `slotplane-probe`), and **trail recorders** that turn on `visible_mapkeys`, pause while the operator does a workflow by hand, then diff the trail to capture exact widget tokens (`csystrf-probe`, `holepat-probe`, `slotpat-probe`). A few (`tangent-plane-probe`, `curvedhole-probe`, `csys-negoffset-probe`) create one throwaway feature under a canary to settle a recipe. Their findings are transcribed into the `lib/` helpers — this is how the mapkeys stay honest.

---

## Requirements

### Software prerequisites
- **Creo Parametric** (any recent version with VB API support)
- **Windows PowerShell** 5.1 or later
- **Active Creo session** running before script execution (exactly one `xtop.exe`)

### Creo VB API setup
The scripts handle the VB API connection automatically, but ensure:
- Creo VB API COM components are registered (normally done during Creo installation; first run will attempt registration via `vb_api_register.bat`)
- No additional Creo licenses required beyond standard Parametric
- The user has appropriate Creo modeling rights for the operations being performed

---

## Usage

1. **Open Creo** and load your model (a jig **part** for the builders — not an assembly).
2. **Double-click** the tool you want — start with **`pipeline/drilljig-gui.cmd`** (flat) or **`pipeline/drilljig3d-gui.cmd`** (curved).
3. **Follow the wizard** (or the prompts, for the console tools).
4. **Switch to Creo** when the wizard arms a pick or a manual sketch draw, then return to continue.
5. **Review the built geometry** in Creo — the tools confirm dimensions and canaries, but final geometric verification is always yours.

### Legacy source files
Original `.ps1` source files for the baseline toolkit scripts are preserved in [`ps1 archive/`](ps1%20archive/) for reference. The `.cmd` files are self-contained and do not require them to run.

---

## Testing

`lib/tests/` is a purely **offline** PowerShell unit-test harness — no Creo, no network. It exercises the pure geometry/layout math and JSON round-trips that back the tools:

- **`run_*.ps1`** — unit suites (orthogrid, wizard, fastener, conformal_blank, the curved libs, drilljig3d, hole_layout, tangent_plane, csys, index_frame, jig_tree, bushing, response, and `run_tests.ps1` for `creo_geometry` + `blind_evaluator`).
- **`render_*.ps1`** — pixel/render checks for the preview renderers (bushing 2D/3D, hole circles/labels, slot preview, axis glyph, drilljig3d).
- **`check_*.ps1`** — data-integrity guards (bushing part-number integrity, hole-layout isolation).
- **`fuzz_*.ps1`** — headless WinForms fuzzers that render the real wizard steps and fire handlers to catch scope/closure bugs (`fuzz_gui` for the flat GUI, `fuzz_curved_gui` for the curved one).

There is no master runner — each suite self-tallies pass/fail and is invoked individually, e.g.:

```powershell
powershell -File lib\tests\run_wizard_tests.ps1
powershell -File lib\tests\run_orthogrid_tests.ps1
```

---

## Troubleshooting

**"Cannot find Creo process"**
- Ensure Creo Parametric is running before executing a script; only one `xtop.exe` should be active.

**"VB API registration error"**
- VB API COM components may need re-registration — run a Creo installation repair, or contact IT.

**The curved GUI rejects the model**
- `drilljig3d-gui.cmd` requires the jig **part** to be the *active* model. In a top-down assembly, right-click the jig part and **Activate** it first.

**Script hangs during execution**
- Switch to the Creo window — the tool may be waiting for a selection or a manual sketch draw. Check the wizard's RUN log / the PowerShell window for prompts.

**Mapkey-driven step stopped working after a Creo upgrade**
- Widget names can change between Creo versions. Set `visible_mapkeys yes` in `config.pro` to inspect the current widget names, or use the matching recorder in [`probes/`](probes/) to re-capture the sequence, then update the affected mapkey.

**A build step "did nothing"**
- The canary aborts a macro that changed no geometry rather than claiming false success. Check the reported reason; it usually means a pick wasn't armed, a widget name drifted, or the wrong model/body was active.

---

## License

Internal Blue Origin toolset. See company policies for usage and distribution guidelines.

## Authors

- **M. Mohapatra** — Drill jig automation (flat + curved pipeline, wizard GUIs, previews)
- **Kyle Brooker** — Baseline orthogrid automation workflows (proof of concept)
- **Ethan Iglehart** — Gauginator development (proof of concept)
