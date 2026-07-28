# Drill-Jig Builder — Quickstart

An end-to-end tool that turns a bushing decision into a finished Creo drill-jig part:
it sizes a plate, lays out and drills the holes, cuts chip-relief slots, drops an
**index coordinate system** on a hole you choose, and **exports every hole's
coordinate relative to that coordinate system** (plus, optionally, datum points
referenced from it).

There are two front-ends over the **same proven engine** (`lib\drilljig_core.ps1`):

| Front-end | How you drive it |
|-----------|------------------|
| `drilljig.cmd` | Console prompts (type answers, press ENTER at each Creo pause). |
| `drilljig-gui.cmd` | A WinForms wizard — one decision per screen, "verify" buttons for Creo picks. |

Both do the identical sequence and produce the identical geometry + exports.

---

## Before you start

1. **Open the jig PART in Creo** (a `.prt`, **not** an assembly). It must have its
   three default datum planes (named `TOP`, `SIDE`, `FRONT`).
2. Exactly **one** Creo session running (`xtop.exe`). The tool connects to it via the
   VB API (auto-registers on first run).
3. Leave Creo visible — you will make a few **mouse picks / rough sketches** the tool
   cannot do for you (drawing a rectangle, selecting the index hole).

Double-click the `.cmd`, or run it from a terminal.

---

## The flow, stage by stage

> A "PAUSE" below is a spot where you act in Creo, then continue (press ENTER in the
> console, or click the wizard button). Everything else is automatic.

1. **Bushing / hole size** — walk the decision tree; it resolves the **hole diameter**
   (and, from the bushing, the plate thickness).
2. **Point source** — choose how the hole points are defined:
   - **Predefined** — datum points already in the part (you'll pick them later).
   - **Orthogrid** — a regular Nx×Nz grid (edited in a small dialog).
   - **Custom** — type each hole's X/Z offset.
2a. **Index hole (optional, recommended)** — for orthogrid/custom, you may pick one hole
   now to be the **index** (origin) the whole jig references. The part dimensions and hole
   positions stay **identical** — the chosen hole just becomes the coordinate-system origin.
   This is the geometry-preserving way to "reference the index hole": the base coordinate
   system is built **at** that hole from the start (nothing is moved later, nothing is cut),
   so step 10 becomes automatic and step 9's pick is skipped. Default: **None** (origin-based,
   exactly like before).
3. **Datum planes** — the tool auto-finds `TOP`/`SIDE`/`FRONT` by name (no clicks); if
   it can't, you Ctrl-click the three datums once. These are needed in every mode: the
   box is sketched on the SIDE datum and the grid points intersect it.
4. **Box** — the tool first creates a **base coordinate system** from the part's default
   csys (found automatically); the plate's **guide + grid-pitch planes** are then
   **offsets from that csys** (+ an axis), so the grid can later be re-referenced onto
   the index hole. The box itself is **sketched on the SIDE default datum** and extruded
   up to the SIDE csys plane (the proven, well-behaved build).
   **PAUSE:** draw the plate rectangle in the sketcher, then the tool finishes it. To
   snap the second corner to the intersection of the newly created planes, hold
   **CTRL + ALT** and select the 2 planes — done correctly, dotted blue lines form the
   rectangle shape — then draw the rectangle from corner to corner.
5. **(Orthogrid/Custom) Points** — every target point is created automatically as the
   intersection of 3 planes. No clicks.
6. **Corner round** — the plate's vertical corner edges are rounded (hands-free).
7. **Drill** — an On-Point hole is drilled at every point at the diameter from step 1.
   (Predefined mode: **PAUSE** to select your points first.)
8. **Chip-relief slots** — one blind rectangular slot per hole row.
   **PAUSE:** draw the seed slot rectangle; the rest are patterned. (Auto for 3D-print
   material; asked for metal.)
9. **Index coordinate system** *(optional)* — **PAUSE:** select ONE drilled hole (the
   hole feature in the model tree, **or** its datum point) to be the origin. The tool
   re-uses the 3 planes that built that hole and drops a datum csys there (axes:
   X-normal / Y-normal / Z-normal). *(SKIPPED automatically if you chose an index hole
   up front in step 2a — the base coordinate system is already the index csys.)*
10. **Reference the index hole** — **If you picked an index hole in step 2a (recommended),
    this is already done**: the base coordinate system was built *at* the index hole, so the
    whole jig references it with no move and no cut — this step is skipped. **Otherwise**, the
    tool relocates the base csys onto the index hole by **changing its coordinate-system type
    to a file transform** (`--reref-method transform`, default): Analysis → Transform
    (base → index) writes a static matrix to `info.trf`, then the base csys is redefined with
    `OffsetType=file` importing it. This is *not* a reference cycle (the file is a baked matrix
    relative to the part default csys, not a live link to the index csys), but moving the base
    *after* the fact can leave references off and cut the jig — which is exactly why **index-first
    (step 2a) is the preferred, geometry-preserving path**. Move alternatives: `--reref-method
    independent` / `output-csys` (a separate datum at the index hole, no move) / `none`
    (`--no-reref`). The move methods are canary-gated, reported UNVERIFIED, and leave the base
    untouched on any failure.
11. **Export** — writes, next to the part:
    - `<part>_holes_from_index_csys.csv` — every hole's coordinate **in the index csys
      frame** (machine-readable).
    - `<part>_index_report.txt` — a readable provenance report (part, date, csys id,
      index hole, units, and an aligned table).
12. **Csys-referenced datum points** *(optional)* — creates datum points **offset from
    the index csys** at those coordinates, so they are tied to the coordinate system.
    *(This last step's dialog widgets are not yet confirmed on this build — see Notes.)*

---

## What the export contains

`<part>_holes_from_index_csys.csv`:

| Column | Meaning |
|--------|---------|
| `Hole` | Creation order (1..N). |
| `PointId`, `HoleFeatId` | Creo ids (provenance; for tying back to the model). |
| `X_index`, `Y_index`, `Z_index` | Coordinate **relative to the index csys**. `Y_index` is 0 — all holes sit on the drilled face. |
| `GridX`, `GridZ` | The hole's original design offsets. |
| `Diameter` | Hole diameter. |
| `IsIndexHole` | `True` for the origin hole (its X/Y/Z are 0). |

**Axis note:** X runs along the grid X, Z along the grid Z. The magnitudes are exact
from the design layout; **verify the axis SIGNS visually against the created csys**
(the sign follows the csys orientation).

---

## Flags (both front-ends)

| Flag | Effect |
|------|--------|
| `--no-corner-round` | Skip the STAGE-2b corner round. |
| `--corner-radius N` | Corner radius (default 0.25). |
| `--no-slot-relief` | Skip chip-relief slots. |
| `--slot-depth N` | Slot depth in inches (default 0.25); the plate is padded by this so the final guide depth = the bushing length. Explicit override — SKIPS the tight/restricted-space prompt below. |
| `--slot-flip`, `--pattern-flip`, `--no-pattern` | Slot direction / pattern controls. |
| `--no-index-csys` | Skip the index coordinate system (and the export + csys points). |
| `--no-csys-points` | Create the csys + export, but skip the csys-referenced datum points. |
| `--no-base-csys` | Revert to the legacy default-datum planes (no base coordinate system). |
| `--reref-method transform\|independent\|output-csys\|none` | Step 10. `transform` (default) = change the base csys onto the index hole via a file transform (the whole jig follows); `independent` = same transform via an anchor off the default csys; `output-csys` = build a separate datum at the index hole (no move); `none` = skip. `--no-reref` = `none`. (`static` is an alias of `transform`.) |
| `--probe-judge` | Validate the blind-evaluator REST judge, then exit (no Creo). |

---

## Notes & current status

- **Point/hole creation is proven-live and must not change.** Every "smart" read the
  tool does (tying holes to points, building the export) happens *after* a creation
  loop finishes — never between creation macros.
- **Slot depth / tight space (asked right after the bushing decision tree):** the
  chip-relief slot depth doubles as the plate extrude pad — the plate is extruded to
  `bushing length + slot depth`, then the slot removes the slot depth, so the final
  guide depth = the bushing length for **any** positive depth. A **smaller** slot depth
  therefore yields a **thinner overall plate** — for a **tight / restricted space** the
  operator answers "yes" and types their own (usually smaller) depth. Otherwise the
  default 0.25″ is kept (extrude = bushing + 0.25″). Console = a `y/N` + entry prompt;
  GUI = a "Standard clearance / Tight space" step under the **Bushing** stage. `--slot-depth N`
  pins the value and skips the question.
- **Index csys:** the 3-plane → `ProCmdDatumCsys` recipe is confirmed live. If clicking
  a hole "isn't read," click its **datum point** instead — both resolve.
- **Csys-referenced planes + re-reference (steps 4 & 10):** default mode offsets the
  guide + grid-pitch planes from a base coordinate system (so re-placing it moves the
  grid). The box + slots still sketch on the SIDE **default datum** (proven), so the
  extrude is unchanged from the legacy build.
- **Step 10 changes the coordinate system type (not a reference cycle):** redefining the
  base csys with `OffsetType=file` bakes a *static* transform matrix relative to the part's
  default csys — the file is data, not a live link to the index csys — so the base ends up
  as `default csys + frozen matrix` with no edge back to the index csys, and nothing cycles.
  The remaining risk is purely the **live-unverified** plumbing (the `info.trf` Save-As/Open
  dialogs + an omitted screen pick), which is canary-gated and reported UNVERIFIED. Separately,
  the plate is sketched on the SIDE default datum while the holes hang off the base csys, so
  how the plate behaves under the base transform is a **live-verify** item — if it misbehaves,
  use `--reref-method output-csys` (a separate index-hole datum, no move) or re-root the plate.
- **Csys-referenced datum points (step 11):** the "Datum Point → Offset Coordinate
  System" dialog widgets are a **best guess** (no recording exists yet). The step is
  canary-gated — if it creates nothing, it says so. To lock it: in Creo set
  `visible_mapkeys yes`, create one such feature with two rows, and hand the trail
  lines back so the macro can be transcribed (see `Build-CsysOffsetPointsMacro`).
- Honesty bar: a stage reports "done" only when the model actually changed / a feature
  actually appeared — never just because a macro fired. Always eyeball the result in
  Creo.

See `context-files/CLAUDE.md` for the full developer notes (per-stage internals, the shared engine,
the blind-evaluator convergence layer, and the API-fact registry).
