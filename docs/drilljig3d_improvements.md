# drilljig3d — improvement research & roadmap

Research synthesis (fan-out of 6 parallel agents, 2026-06-24) into ways to make the
conformal 3D drill-jig tool (`drilljig3d.cmd`) better. Each item is tagged with
effort, whether it **needs a live `visible_mapkeys` recording**, and which **proven
primitive** it reuses, so it can be picked up without re-deriving.

**Sourcing caveat:** WebSearch was down during the research run. Hard numbers came
from one cleanly-fetched source (Carr Lane, *Understanding Standard Drill Bushing
Types*). All other numeric rules (edge margin, center distance, normality tol,
press-fit interference, 3‑2‑1) are long-established jig-and-fixture practice
(Hoffman *Jig and Fixture Design*; ASME B94.33; vendor catalogs) that could not be
re-verified live — treat them as **editable defaults**, not hard constants.

## Where drilljig3d stands
STAGE 1 (offset-surface + thicken→new body, flipped away from the part) and STAGE 2
(On-Point holes normal-to-surface via surface pre-select) are **confirmed working
live 2026-06-24**. The biggest open correctness question is whether the surface
pre-select truly orients each hole normal to the face (see Open Questions).

## Implemented so far (no live recording; defaults preserve prior behavior)
- **Per-hole orientation surface** (top rec #1, done) — STAGE 2 builds a `(point, surface)`
  pair list: mode 1 (default) = all points share the STAGE-1 surface (unchanged); mode 2 =
  pick each point with its own host surface for curved/multi-face jigs. Reuses
  `Build-NormalHoleMacro`'s per-call `-SurfaceId`. Closes the "one surface for every hole" gap.
- **Hole-count + diameter blind-evaluator gate** (top rec #3, done) — `Invoke-JigEval` counts
  cylinders at the target radius before/after; the delta must equal the intended count
  (`Test-ExtentsMatch`). Wires in `lib\blind_evaluator.ps1`; 0-surface walk = UNVERIFIED, not
  false-green.

### Quick wins (also done — first session)
- **Standoff / chip-clearance offset** — STAGE 1 no longer hard-drives the offset to
  0; it prompts for a standoff (default 0 = flush/coincident, exactly as before). >0
  floats the jig off the part for chip clearance. Reuses the existing `Set-DimAndConfirm`
  on the offset dim. (Carr Lane: drilling clearance ~0.5–1.5× tool dia.)
- **Bushing-OD handoff pre-fill** — drilljig3d now reads `last_jig_spec.json` (the
  same handoff holeinator consumes) and pre-fills the STAGE-2 hole/seat diameter
  (`HoleDiameter` = bushing OD; ENTER accepts, override to retype). Forward-compatible
  read of `BushingLength` to pre-fill thickness if jiginator ever emits it.
- **Thickness vs bushing sanity guidance** — when the hole diameter is known, STAGE 1
  prints the recommended wall band (~1–2× dia) and bushing seating length (~1.5× dia)
  and soft-warns (non-blocking) a too-thin wall. Pure PowerShell.

## Top recommendations (next, in priority order)
1. **Per-hole orientation surface** — *medium, no recording.* STAGE 2 currently uses
   `surfIds[0]`'s normal for **every** hole (the code admits "v1 uses the first"),
   which defeats "conformal" the moment points span curvature. `Build-NormalHoleMacro`
   is already parameterized `-SurfaceId` per call; the new work is pairing each point
   with its host surface. Safest v1 UX: per-point loop (Ctrl-click point + its surface,
   ENTER, fire). Depends on #2 being proven.
2. **`--probe-orient` diagnostic** — *medium, needs recording.* Pin the load-bearing
   assumption (does surface pre-select orient the hole normal?). Mirror
   `cornerinator-probe.cmd`: drill one hole, read its cylinder axis via `Get-CylinderAxes`
   (confirmed-live), compare to the surface normal from `IpfcSurface.Eval3DData(EvalParameters(p))`
   (docs-only — needs a live check; take the eval point from the cylinder axis base, NOT
   `IpfcPoint.Point` which crashes). `-defaultorient` is the existing fallback.
3. **Hole-count + bore-diameter blind-evaluator gate** — *medium, no recording.* Replace
   "macros fired" with measured truth: `Count-Cylinders -TargetRadius (dia/2)` restricted
   to the new blank body, gated by `Test-ExtentsMatch` on count AND on N copies of the
   diameter. Wire through one `Invoke-JigEval` modeled on plane-probe's `Invoke-BoxEval`
   (must dot-source `lib\blind_evaluator.ps1` — currently only `creo_geometry.ps1` is).
   Slice carries measured geometry ONLY (slice-purity assertions apply). Degrade to
   UNVERIFIED/yellow on a 0-surface walk, never green.

## More quick wins (low effort, no recording)
- **Auto-round the blank's sharp edges** — reuse `Invoke-AutoCornerRound` from
  `lib\edge_round.ps1` verbatim after STAGE 1 (the flat sibling drilljig already does
  this; it self-tests + canary-guards and runs on foreign bodies). Pass explicit
  `-Target` = thickness (don't trust auto "lowest dimension" on a curved blank). Make
  it an opt-in prompt since it mutates geometry.
- **STAGE-1 single-new-body + volume gate** — promote the existing silent `jigBodyId`
  diff into a deterministic check: exactly ONE new body of non-zero volume
  (`GetMassProperty($null).Volume` — confirmed for `.GravityCenter`, quick live check
  for `.Volume`). Catches a thicken that produced no body / merged into the source.

## Bigger bets
- **Counterbore / bushing-seat (stepped bore)** — what makes the jig actually HOLD a
  bushing: counterbore at bushing OD, depth = bushing length, over a smaller thru
  clearance hole. Route B (a SECOND coaxial On-Point hole at a different dia/blind
  depth, like drilljig STAGE 4's relief) reuses `Build-NormalHoleMacro` and needs only a
  blind-depth flyout recording; route A (native counterbore profile) is cleaner geometry
  but the profile widgets are unrecorded.
- **Headed-bushing counterbore + catalog data layer** — *blocked on data, not code.*
  `HeadDia`/`HeadHeight`/`PressFitHoleDia`/`PressFitTol`/`FitClass` are not in either
  CSV (seeded rows are all slip/liner, zero headed). Add columns from vendor spec + a
  press-fit interference offset (Carr Lane: 0.0005–0.0008″ headless, 0.0003–0.0005″
  headed). jiginator's optional-column guard degrades gracefully when absent.
- **Locating / registration (3‑2‑1)** — a conformal face alone leaves the jig free to
  slide/rotate on the surface. Locating-pin holes = a second labeled STAGE-2 pass at an
  independent diameter (zero new mapkeys). Round-vs-diamond-pin / 3‑2‑1 are design
  guidance the tool surfaces, not geometry it computes; keep human-pick.
- **Auto-generate the hole grid on the curved face** — bridge drilljig's orthogrid
  GUI + seed→pattern into the 3D tool. Hard part: an orthogonal X/Z grid does not map
  cleanly onto a curved face and a Direction-pattern keeps direction, not per-member
  normality. `Build-PointPatternMacro` widgets are UNVERIFIED. Keep `Invoke-ManualPointGrid`
  as the guaranteed path. Highest-risk item.
- **Stamp bushing identity as Creo parameters** (BUSHING_PN/OD/ID/LEN/DRILL_SIZE) so the
  jig is self-documenting. Param-create API is unverified on this build (toolkit has hit
  "not implemented" on CreateFeature) — confirm live or fall back to a `*_jig_spec.json`
  sidecar.

## Hole-axis-normal verification gate (high value, needs a live probe)
For each drilled cylinder, read its axis via `Get-CylinderAxes` (confirmed) and compare to
the local surface normal; deterministic gate `|dot(axis, normal)| ≥ cos(tol)`. Converts the
currently-eyeballed normality claim into a measured one. Blocked on the `Eval3DData` normal
read being usable on this build (and on `IpfcForeignSurface`) — the `--probe-orient` (#2)
settles it. Also a **thru-all "broke through" gate** via `GetMassProperty().Volume` delta.

## Open questions (settle before building the dependent items)
1. Does pre-selecting the surface orient the On-Point hole normal, or take Creo's default?
   (Load-bearing for the whole "conformal" claim. → `--probe-orient`.)
2. Does `IpfcSurface.Eval3DData(EvalParameters(p)).Normal` return a usable normal on this
   build, including on `IpfcForeignSurface`? (docs-only.)
3. Does an On-Point HOLE diameter dim hold a feature-level `DimValue` write, or snap back?
   (Proven for extrude/offset/thicken, not the hole tool — affects press-fit resize.)
4. Is `.Volume` readable on `GetMassProperty($null)`? (Confirmed only for `.GravityCenter`.)
5. Are headed/press-fit bushings actually in scope? (Catalog has zero headed rows — confirm
   demand before sourcing net-new vendor data.)

## Deliberately NOT recommended
- **Copy/Publish Geometry** — multi-model/assembly construct that conflicts with the
  `.asm` mode guard and the ID-only-against-active-model design. Only if "jig as a separate
  associative part" becomes a requirement (a different product).
- **Wrap / Flatten Quilt** — wrong direction (they map flat geometry onto a surface, not
  the inverse a conformal jig needs).
