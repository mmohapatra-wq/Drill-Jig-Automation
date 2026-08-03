# Curved drill-jig GUI — INPUT-FIRST workflow re-sequence (plan)

> **SUPERSEDED (2026-07-29).** This is the ORIGINAL planning doc; the input-first
> re-sequence it describes has since shipped AND been simplified further. The LIVE step
> order (owned by `curved_gui_steps_compose.ps1::Get-CurvedInputFirstOrder`) is now:
> `welcome, fastener-select, surface-arm, tree, chip-clearance, fastener-dia, build-run,
> slot-arm, slot-finish, done`. Key deltas vs the plan below: the free-text **thickness** +
> **standoff** steps are GONE — part thickness is DERIVED as bushing length + chip clearance
> and the offset is always 0; the old **relief-depth** free-text step is now the
> **chip-clearance** card (Standard 0.25" / Custom, seeded so Next works immediately); the
> hole is drilled at the SELECTED diameter (`maindashInst0.diameter_mip_OptionMenu`); the
> Slots stage no longer re-selects the fasteners (it reuses the up-front selection); and the
> chip relief is a flat-DJ-parity **two-step** flow — **slot-arm** PRE-SELECTS that fastener's
> **OWN TOP datum plane** (the same raw-COM reference the hole uses, id 1, staged BEFORE the
> extrude — the hole's proven pre-select-then-fire order; v5's post-open feed did not register)
> then opens the extrude so the sketch opens ON the TOP plane immediately — **no reference/guide
> planes** (retired 2026-07-29 per the operator); an operator plane-pick fallback fires only if
> the pre-select cannot stage (stale path); the operator draws; then **slot-finish** cuts the
> symmetric pocket and re-arms the next hole (a return-`$false` self-loop), re-resolving a fresh
> component path per fastener (see `[[project_curved_relief_extrude_plane]]`). Confirmed live
> 2026-07-29 (reliefplane-probe TEST A). The drilled hole is set to the selected diameter
> (`maindashInst0.diameter_mip_OptionMenu`). **RADIAL PATTERN (2026-07-30):** a *linear* pattern is
> not feasible on a curved face (fixed increment+orientation can't re-orient to a new normal), but a
> Creo **AXIS/radial** pattern rotates each copy about the cylinder axis and DOES re-orient it — so when
> the fasteners are uniformly spaced about the axis (`Get-CurvedRadialPatternPlan.CanPattern`, computed
> from `FastenerComponents[].Origin` + the live cylinder axis in `$ctx.RadialAxisGeom` from the "Read
> radial distance" half, `lib/curved_surface_radius.ps1`), **slot-arm** picks radial mode + swaps the
> seed to the arc-endpoint fastener, and **slot-finish** cuts that ONE seed then AXIS-patterns the rest
> (operator picks the rotation axis once; `Invoke-CurvedReliefRadialPattern`, canary-gated). Non-uniform,
> `--no-radial-pattern`, or a pattern miss → the per-fastener draw loop (unchanged, the guaranteed
> fallback). See `[[project_curved_radial_slot_pattern]]`. The historical plan below is kept for context only.

**Status:** PLAN ONLY (historical) — written 2026-07-28 from a research workflow over the
live code. Target file: `pipeline/drilljig3d-gui.cmd` + the `lib/curved_gui_steps_*.ps1` step groups.

## Goal (operator's requested workflow)

Front-load ALL operator input, then fire everything hands-free except one sketch at the end:

1. **STAGE 1 — Fasteners:** operator selects all fastener components once.
2. **STAGE 2 — Surface:** operator selects the surface the jig follows.
3. **STAGE 3 — Conditions:** operator enters every numeric/choice input.
4. **STAGE 4 — Build:** everything fires one-by-one (blank → corners → per-fastener point +
   on-point hole + chip-relief pocket on the fastener's TOP plane).
5. **STAGE 5 — Slot sketch:** the chip-relief rectangle draw. NOTE: today this draw happens
   per-fastener *inside* the STAGE-4 loop (`Invoke-FastenerRelief`), not batched at the end —
   see the "OPEN DESIGN DECISION" section (Option A keeps it interleaved; Option B defers it to a
   terminal pass to match this target literally).

Today the GUI is INPUT-then-EXECUTE *per stage* (Bushing input → Surface pick+build →
Fasteners pick+loop → Relief gate+plan+run). The change moves all picks/inputs to the front
and consolidates the firing into one batch.

## THE CRITICAL CONSTRAINT — identity-only state, re-resolve fresh at fire

Learned live 2026-07-28: a raw COM handle (`IpfcComponentPath`, a surface/plane `ModelItem`)
**stashed at selection time goes STALE** when reused many operations later — it failed after the
closure + loop + `RunMacro`/`DoEvents`. The fix was `Get-BufferComponentPath`
(`lib/curved_fastener_hole.ps1`) reading a LIVE path from the buffer at point-of-use.

Input-first **widens the select→fire gap to the whole run**, so this is the dominant risk. Rule:

- **Never persist a selection-lifetime COM object.** Store STABLE IDENTITY only
  (component ids, feature/surface ids, value tuples). Re-resolve fresh at fire time.
- The only long-lived COM handles are `$ctx.Session/Model/Type` (session-lifetime), rebound at
  the top of every fire-time handler (`$session=$c.Session; …` — a bare read is stale).
- The fastener TOP/SIDE/FRONT planes are the CONSTANT feature ids **1 / 3 / 5** — never stored per
  fastener, re-resolved by id at fire.

### `$ctx` contract
| Stage | Stores (identity-only) |
|-------|------------------------|
| 1 Fasteners | `$ctx.FastenerComponents = @({ CompIds=@(int); Origin=(x,y,z) })` — **DROP** the current `Path=$path` field (`curved_gui_steps_fastener.ps1:192`); it is the stale handle. `$ctx.FastenerSurfId` set in STAGE 2. |
| 2 Surface | `$ctx.SurfIds=@(int)` (already identity-only, `Resolve-SelectedSurfaces`). |
| 3 Conditions | pure values: `HoleDiaFinal/BushingLen/HoleDia`, `Thickness(+Valid)`, `StandOff(+Valid)`, `FastenerHoleDia(+Valid)`, `CornerRadius/NoCornerRound`, `SlotSkip/Is3dPrint/SlotDepthAbs`. No COM. |
| 4 Build | results: `BodyIndex/BodyId/BodyName/BlankMade`, `CornersRounded`, `CurvedHolePairs=@({PointId; TopPlaneId=1; ViaPlane; ReliefCut})`, `FastenerHolesMade`, `ReliefsCut`. (No `TangentPlaneId`, no `SlotPlan` — relief is a per-fastener TOP-plane cut, see the correction below.) |

### Fire-time re-resolve helpers (all already exist, all `function global:`)
- Surface: `Get-SelectSurfacesByIdMacro -SurfIds` (inside `Invoke-ConformalBlank`, `conformal_blank.ps1`).
- Fastener planes: `Add-ComponentDefaultPlanesToBuffer` (ids 1/3/5, path-qualified).
- Fresh path: `Get-BufferComponentPath` (reads the live buffer — replaces the dropped `$comp.Path`).
- TOP orientation: `Select-ComponentPlaneById -PlaneId 1 -Role 'Top'`.
- Canaries: `Resolve-NewDatumPointIds`, `Get-FeatureIdSet` diff, `Wait-ModelModified` (VersionStamp).

## CORRECTION (2026-07-28): relief is already TOP-plane based — the "tangent-plane gap" is OBSOLETE

An earlier draft of this plan (from the research workflow) claimed a must-fix "tangent-plane gap"
— that the fastener loop stored `CurvedHolePairs` without `TangentPlaneId`, so a tangent-plane
slot loop always skipped. **That is stale.** The branch has since redesigned chip relief:

- The slot machinery lives in **`lib/curved_relief.ps1`** (NOT `curved_gui_steps_relief.ps1`,
  which no longer exists). Its header states it **SUPERSEDES the retired tangent-plane per-hole
  slot loop (which gated on a `TangentPlaneId` the fastener loop never set → always skipped)**.
- Chip relief is now a **SYMMETRIC remove-material extrude on each fastener's OWN TOP plane**
  (component feature id 1 — the same plane the hole is oriented to), cut **right after each hole
  inside the fastener loop** via `Invoke-FastenerRelief -TopPlaneId 1 -ReliefDepth … -DrawPrompt
  … -PlanePrompt …` (`curved_gui_steps_fastener.ps1:472`). The operator draws one rectangle on the
  TOP-plane sketch (`DrawPrompt`), a symmetric cut (depth = 2×relief) straddles the plane; the
  conformal blank's thicken grows to `wall + relief` to leave material.
- The fastener loop stores `CurvedHolePairs = @({ PointId; TopPlaneId=1; ViaPlane; ReliefCut })`
  — **no `TangentPlaneId`**. There is NO tangent plane in the wired path anymore.

**Consequence: do NOT add `Invoke-TangentPlane`/`TangentPlaneId` — that re-introduces the retired
approach.** The `TangentPlaneId` references elsewhere (`curved_gui_steps_drill.ps1`,
`curved_slots.ps1`, `curved_slot_macros.ps1`, `run_drilljig3d_stage3_tests.ps1`) belong to the
OLD `drilljig3d.cmd` STAGE-3 slot flow and the unwired `curved_gui_steps_drill.ps1`, not the
current GUI fastener/relief path. Leave them; they are not on the input-first critical path.

## STAGE 4 — the batch-fire engine

One `run` step whose handler drives an ordered, canary-gated, **no-abort** batch (mirrors the
existing per-fastener loop posture + the never-assume-success rule):

- **Top (once):** rebind `$session/$model/$pfcType` from `$c`; run the **active-model `.asm`
  gate** (`fastener.ps1:320-329`) — if the assembly is active, `AskInline` to activate the jig
  part and return WITHOUT firing; `BeginRun`; `$poll = { [Windows.Forms.Application]::DoEvents() }`.
- **Ordered sub-actions, each own try/catch, each canary-gated, none aborts the batch:**
  1. **Blank** (dependency root) — `Invoke-ConformalBlank -SurfIds $c.SurfIds …`; gate on
     `.Made`; set `$blankOk`. On miss, SKIP dependents (they need `BodyIndex`).
  2. **Corners** (skip if `$c.NoCornerRound` or `-not $blankOk`) — `Invoke-CurvedCornerRound
     -Radius $c.CornerRadius -Thickness $c.Thickness`. Advisory; a miss continues.
  3. **Fastener loop** (only if `$blankOk`) — per `$c.FastenerComponents`, re-resolve fresh each
     iteration: `Add-ComponentDefaultPlanesToBuffer` (ids 1/3/5) → `Get-BufferComponentPath` →
     `Invoke-FastenerPoint` → `Invoke-FastenerHole -PointId $ptId -ComponentPath $fp -TopPlaneId 1
     -DirectionPrompt $dirPrompt`, then (per the CURRENT design) `Invoke-FastenerRelief -TopPlaneId 1
     -ReliefDepth … -DrawPrompt … -PlanePrompt …` → store `CurvedHolePairs = {PointId; TopPlaneId=1;
     ViaPlane; ReliefCut}`. Keep the per-iteration safety-close macro + the manual 3-plane fallback.
     Tally drilled/auto/manual/fail + reliefsCut/reliefFail.
- **End:** summary line; `MarkCommitted` once anything mutated; return `$true` to advance to the
  recap regardless of partial failures (the recap reports honestly). Idempotent done-flags
  (`BlankMade/CornersRounded`) show `Add-RebuiltNotice` on Back+revisit instead of re-firing.

## STAGE 5 / the slot sketch — an OPEN DESIGN DECISION (was based on the stale slot-plan model)

The original plan put "all slot sketches at the very end" as a terminal STAGE 5 driven by
`Invoke-CurvedSlotPlanRun` over a `$c.SlotPlan`. **That does not match the current code.** Today
chip relief is cut **inside the fastener loop, one per fastener**, via `Invoke-FastenerRelief`
(`curved_gui_steps_fastener.ps1:472`): per fastener the tool arms the sketch on that fastener's
TOP plane and the operator draws one rectangle (`DrawPrompt`) right then, before the loop advances.

So the operator's target ("everything hands-free except the chip-relief slot sketch at the very
end") needs a DECISION at implementation time:

- **Option A — keep per-fastener relief draw (matches current code, lowest risk):** STAGE 4 is
  hands-free EXCEPT one rectangle-draw per fastener interleaved in the loop. Simplest; reuses
  `Invoke-FastenerRelief` as-is. The "sketch at the end" goal is only partially met (draws are
  interleaved, not batched).
- **Option B — defer all relief sketches to a terminal batch (matches the target literally):**
  split `Invoke-FastenerRelief` into an ARM-all pass (STAGE 4, hands-free: drill every hole,
  record each fastener's TOP-plane id + geometry, NO sketch) and a DRAW-all pass (STAGE 5: for
  each recorded fastener, pre-select its TOP plane, arm the extrude sketch, `DrawPrompt`, cut).
  Requires refactoring `curved_relief.ps1` so arming and drawing are separable, and re-selecting
  each TOP plane fresh at draw time (identity-only: store `CompIds` + `TopPlaneId=1`, re-resolve).
  More work; delivers the literal "one sketch pass at the end."

Recommend confirming A vs B with the operator before implementing the re-sequence. Everything
else in this plan is independent of that choice.

## Reuse map

**Direct reuse (relocate the step object / OnNext body, no logic change):**
- `Add-CurvedBushingSteps` (welcome/tree/thickness/standoff) → welcome stays front; tree/thickness/
  standoff → STAGE 3.
- `curved_gui_steps_surface.ps1` surface-arm (:59-100) → STAGE 2; blank-build (:105-196) +
  corner-round (:218-303) OnNext bodies → STAGE 4 sub-actions.
- `curved_gui_steps_fastener.ps1` fastener-select (:147-213) → STAGE 1; fastener-dia (:71-142) →
  STAGE 3; the fastener-loop body (drill + per-fastener `Invoke-FastenerRelief`, :334-498) → STAGE 4
  fastener sub-loop.
- Relief engine is `lib/curved_relief.ps1` (`Invoke-FastenerRelief` + `Build-CurvedReliefArmMacro` /
  the symmetric remove-material cut). The material/relief-depth condition + a `done` recap live in
  the bushing/done step groups (`curved_gui_steps_done.ps1`) — verify exact locations at implement
  time (the workflow's `curved_gui_steps_relief.ps1:*` line refs are STALE; that file was removed).
- Engines unchanged (all global + canary-gated): `Invoke-ConformalBlank` / `Invoke-CurvedCornerRound`
  (`edge_round.ps1`) / the fastener engines (`curved_fastener_hole.ps1`) / `Invoke-FastenerRelief`
  (`curved_relief.ps1`). Framework unchanged: `New-WizardStep`/`Show-Wizard`/`SetChip`/`BeginRun`/
  `AskInline`/`MarkCommitted`.

**New work:**
1. Re-order the `Add-Curved*Steps` calls + the `$stages` list (`drilljig3d-gui.cmd`)
   to input-first, e.g. `@('Welcome','Fasteners','Surface','Conditions','Build','Done')` (+ a
   `Slots` stage only if Option B below is chosen). Cleanest: thin `Add-CurvedInputSteps` +
   `Add-CurvedBuildSteps` wrappers that append the reused step objects in the new order.
2. The consolidated STAGE-4 batch step chaining blank→corners→fastener-loop(drill + relief) with
   the `$blankOk` guard.
3. Drop the stale `$comp.Path` persistence (`fastener.ps1:192`); rely on `Get-BufferComponentPath`.
4. Move `FastenerSurfId` defaulting from fastener-select into surface-arm OnNext (fasteners are now
   picked before the surface exists).
5. Decide Option A vs B for the relief-sketch timing (see the STAGE 5 section). B is the only item
   that adds real new relief code (splitting `Invoke-FastenerRelief` into arm-all + draw-all).

## Risks → mitigations

| Risk | Mitigation |
|------|-----------|
| Stale COM handle across the widened select→fire gap | Identity-only storage; drop `$comp.Path`; re-resolve via `Get-SelectSurfacesByIdMacro` / `Add-ComponentDefaultPlanesToBuffer`+`Get-BufferComponentPath` at fire. |
| Closure-scope: batch button reads a `$script:` var/non-global fn → `$null`/throws | Every helper `function global:`; the closure references only captured `$c`/`$wiz` + globals (the `project_gui_scope_bugs` pattern). |
| Active-model gate: point only lands with the jig PART active; may drift 1→4 | Re-check `GetActiveModel().FileName` at the top of the STAGE-4 batch; on `.asm`, `AskInline`+return without firing. |
| Relief sketch draw interleaved in STAGE 4 (current design draws one rectangle per fastener in the loop) | This is the Option A/B decision (STAGE 5 section). Option A accepts the interleaved draw; Option B defers all draws to a terminal pass by splitting `Invoke-FastenerRelief` arm/draw. Confirm with the operator. |
| Ordering dependency (holes/corners/relief need the blank body) | Fire strictly blank→corners→fastener loop (drill+relief), guarded by `$blankOk`. |
| Partial-batch abort | Each sub-action + loop iteration own try/catch; a miss is tallied+skipped, never rethrown; batch always reaches the recap. |
| Back-nav re-fires committed geometry | `MarkCommitted` on STAGE 4; idempotent done-flags → `Add-RebuiltNotice` on revisit. |

## Sequencing (implement order)

1. **Merge first, don't block:** land the corners branch (`edge_round.ps1` + the surface
   corner-round step — already on `CURVED_DJ`, reflected in `fuzz_curved_gui.ps1`) and the relief
   branch, so STAGE-4 sub-actions wire to real helper names.
2. **Confirm Option A vs B** for relief-sketch timing (STAGE 5 section). If B, split
   `Invoke-FastenerRelief` into arm-all (STAGE 4) + draw-all (STAGE 5) first, independently tested.
3. **Drop stale `$comp.Path`**; loop uses `Get-BufferComponentPath` exclusively at fire.
4. **Re-sequence** into input-first grouping (wrappers + `$stages` + `FastenerSurfId` move).
5. **Build** the consolidated STAGE-4 batch step (`$blankOk` guard, single active-model gate,
   per-action try/catch, `MarkCommitted`).
6. **Fuzz** (`lib/tests/fuzz_curved_gui.ps1` rebuilds steps from the group fns + looks up by `.Key`,
   so re-order is auto-covered) — add scenarios driving the STAGE-4 batch OnNext: fresh, blank-miss
   (skips dependents), no-fasteners, `.asm`-active (gate returns), happy-path (each drilled hole has
   `ReliefCut` set when a relief depth is given).
7. **Lints** (`run_drilljig3d_gui_tests.ps1`): no persisted-then-read `$comp.Path`; batch closure
   references only `$c`/`$wiz`/globals; `$stages` matches step Stage tags.
8. **Wizard** (`run_wizard_tests.ps1`): Back from STAGE 5 into inputs is confirm-gated at the
   STAGE-4 committed boundary.
9. **Regression gates green:** `run_conformal_blank_tests` / `run_curved_fastener_hole_tests` /
   `run_tangent_plane_tests` / `run_curved_slots_tests` / `run_curved_slot_macros_tests` /
   `run_drilljig3d_stage3_tests`.
10. **Live-verify last:** `pipeline/drilljig3d-gui.cmd` in Creo, jig part active — full input-first
    flow builds blank+holes+tangent planes hands-free; STAGE 5 draws slots.
