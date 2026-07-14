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
3. **Datum planes** — the tool auto-finds `TOP`/`SIDE`/`FRONT` by name (no clicks). If
   it can't, you Ctrl-click the three datums once.
4. **Box** — three offset datum planes + an extrude between them build the plate.
   **PAUSE:** draw a rough rectangle in the sketcher (2 clicks); the tool finishes it.
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
   X-normal / Y-normal / Z-normal).
10. **Export** — writes, next to the part:
    - `<part>_holes_from_index_csys.csv` — every hole's coordinate **in the index csys
      frame** (machine-readable).
    - `<part>_index_report.txt` — a readable provenance report (part, date, csys id,
      index hole, units, and an aligned table).
11. **Csys-referenced datum points** *(optional)* — creates datum points **offset from
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
| `--slot-depth-pct N` | Slot depth as a % of plate thickness (default 20). |
| `--slot-flip`, `--pattern-flip`, `--no-pattern` | Slot direction / pattern controls. |
| `--no-index-csys` | Skip the index coordinate system (and the export + csys points). |
| `--no-csys-points` | Create the csys + export, but skip the csys-referenced datum points. |
| `--probe-judge` | Validate the blind-evaluator REST judge, then exit (no Creo). |

---

## Notes & current status

- **Point/hole creation is proven-live and must not change.** Every "smart" read the
  tool does (tying holes to points, building the export) happens *after* a creation
  loop finishes — never between creation macros.
- **Index csys:** the 3-plane → `ProCmdDatumCsys` recipe is confirmed live. If clicking
  a hole "isn't read," click its **datum point** instead — both resolve.
- **Csys-referenced datum points (step 11):** the "Datum Point → Offset Coordinate
  System" dialog widgets are a **best guess** (no recording exists yet). The step is
  canary-gated — if it creates nothing, it says so. To lock it: in Creo set
  `visible_mapkeys yes`, create one such feature with two rows, and hand the trail
  lines back so the macro can be transcribed (see `Build-CsysOffsetPointsMacro`).
- Honesty bar: a stage reports "done" only when the model actually changed / a feature
  actually appeared — never just because a macro fired. Always eyeball the result in
  Creo.

See `CLAUDE.md` for the full developer notes (per-stage internals, the shared engine,
the blind-evaluator convergence layer, and the API-fact registry).
