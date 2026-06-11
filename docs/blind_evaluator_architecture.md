# Blind-Evaluator Convergence Layer for the Creo Automation Toolkit

*Adapted from mlogsdon's "Proposed Regression Test Development with Agentic Workflow"
(itself inspired by Shaun Gilliam's Trident). This memo maps that PLC-regression idea onto
the NGS Orthogrid Creo toolkit and documents the layer now wired into `plane-probe.cmd`.*

---

## Architectural Notes

### 1. What does this architecture do?

It adds a **convergence loop** on top of the toolkit's existing one-shot verification. After a
tool does something to a Creo model (build a box, drill holes, round edges), the loop:

1. **States a claim** — what the tool asserts it did, as a list of short, individually-checkable
   statements ("the box width is 4.0").
2. **Slices the ground truth** — measures *only the in-scope geometry* of the finished model
   (`EvalOutline` extents, cylinder counts at a radius, re-read dim values) and deliberately
   omits everything about *how* the result was produced — no mapkeys, no heuristic thresholds,
   no offset→axis mapping.
3. **Asks a blind judge** — an LLM (BlueGPT, via the LiteLLM REST gateway) that receives only the
   claim + the geometry slice and returns, per claim, `confirm` / `refute` / `uncertain`, plus an
   overall verdict and a one-line summary.
4. **Gates the report** — the tool prints green "confirmed" *only* if the judge confirmed against
   measured geometry; otherwise it is honestly yellow/red. An eval packet is always written to
   disk so the same claim can be judged offline later.

### 2. What does "slice" mean here, and why blind?

In the PLC proposal, the blind evaluator is handed the generated test plus an **L5X sliced to
only the devices that test touches**, and asked: *does the implementation match the test?* It is
blind to how the test was written, so it can catch a **bad generalization** the test-writing
agent made.

Our analog is a **geometry slice**: the measured truth of just the geometry in scope. The judge
never sees the mapkey strings, the dimension symbols, or the tool's internal axis assumptions —
so it cannot inherit the tool's blind spot. It re-derives the verdict from geometry alone. The
slice builder (`Get-GeometrySlice`) and the unit tests both enforce this: a slice may contain
measured numbers and nothing about provenance.

### 3. How are we injecting trust?

By making the judge **independent of the producing code path**. The toolkit's history is a list
of bugs that an independent check would have caught at creation time, not weeks later:

- boxinator's original symbol capture *"could silently verify the wrong dim"* — no VB API
  property distinguishes the width edge from the height edge, so it could confirm the wrong one.
- the `FEATTYPE_PROTRUSION` filter that *silently skipped* the authoritative depth write.
- plane-probe's resize loop today proves a plane "held" by re-reading the **dimension symbol** —
  while never measuring that the **solid** actually resized. The premise "resizing the planes IS
  resizing the box" was asserted, never measured.

Each is a *bad generalization*: a plausible claim the geometry does not actually support. The
blind judge, matching claims **by value** against measured extents, catches exactly this class.

> **Honest limit.** The judge does not replace numeric measurement — `EvalOutline` and the COM
> surface walk remain the source of truth and run in the (deterministic) shared library. The
> judge's job is the *semantic* call: does this measured geometry actually back the claim, which
> measured extent corresponds to which named dimension (without being told), and is anything a
> bad generalization. Numbers come from CAD; judgment comes from the LLM.

---

## PLC proposal → Creo toolkit mapping

| PLC blind-evaluator (wiki) | Creo toolkit analog |
|---|---|
| Pattern input (`_PT_` tag filter) | Selection-buffer / by-ID set / length+radius range — how radinator, holeinator, gripenator already scope work |
| Infer functionality from **tag naming** (cheap proxy) | Infer intent from the **tool's spec + mapkey/VB vocabulary** — cheap, no live model needed |
| The **generated test** | The tool's **claim** ("built a 4×3×2 box", "drilled N holes at Ø", "these 12 edges are node fillets") |
| Blind eval vs **sliced L5X** (devices in scope only) | Blind eval vs **geometry slice** — only `EvalOutline` extents / cylinders at radius r / projected (U,V) for in-scope items |
| Catches a bad generalization about a tag class | Catches the silent-wrong-dim / wrong-feature / off-plane / mis-classified-edge class |
| Judge is an LLM (ladder logic needs reading, not arithmetic) | Judge is an LLM (semantic "does geometry back the claim", value-matching without an axis map) |

---

## The convergence loop (implementation)

```
tool does work ─▶ New-EvalClaim ─┐
                                 ├─▶ Write-EvalPacket  ─▶  <model>_eval.json   (durable artifact)
measure solid  ─▶ Get-GeometrySlice ┘                          │
   (Measure-Extents / Count-Cylinders / Read-DimValue)         │  reload (judge what's on disk)
                                                                ▼
                              Get-JudgeConfig ─▶ Invoke-BlindJudge ─▶ verdict {perClaim[],overall,summary}
                                                                              │
                                                                              ▼
                                                              Show-ConvergenceReport ─▶ bool gate
```

- **Transport:** `POST {base}/v1/chat/completions`, `Authorization: Bearer <token>`,
  `response_format: json_schema` (strict). BlueGPT is LiteLLM-fronted / OpenAI-compatible.
  Verified live 2026-06-11 against `https://litellm.leap.blueorigin.com`.
- **Config:** reuses the `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` env vars already present
  for Claude Code on the workstation; or `BLUEGPT_API_BASE`/`BLUEGPT_API_KEY`; or a gitignored
  `.bluegpt_judge.json`. If none resolve, the packet is still written and the REST call is
  skipped (offline-judge path) — the tool degrades, never fails.
- **Code:** `lib\blind_evaluator.ps1` (loop) + `lib\creo_geometry.ps1` (the shared measurement
  helpers, lifted from the copies that had drifted across datinator/boxinator/holeinator/
  plane-probe). Offline unit tests in `lib\tests\run_tests.ps1`; a `--probe-judge` flag
  (`Invoke-JudgeProbe`) validates the live gateway with a synthetic true/false packet.

### Eval packet schema (`<model>_eval.json`)
```json
{ "tool": "plane-probe", "operation": "build-box", "when": "<iso8601>",
  "model": "boxtest.prt",
  "claims": ["the box width is 4.0", "..."],
  "slice":  { "measured_extents_sorted_desc": [4.0009, 3.0001, 2.0],
              "offset_dims": { "Width": 4.0, "Height": 3.0, "Depth": 2.0 } } }
```

---

## Per-tool slice & claim contracts

### plane-probe.cmd — WIRED (the proof)
- **Claim (build):** each box extent equals its driving offset dim; the three measured extents
  each equal one of the three offsets.
- **Claim (resize):** "the box {width|height|depth} is {v}" after a plane offset is driven.
- **Slice:** `Measure-Extents` of the solid (datum-excluded, sorted desc) + each created plane's
  re-read offset dim, labeled by box dimension. No mapkeys, no axis map.
- **What it catches:** a dim that "held" symbolically while the solid did not resize (broken
  coupling), and any width/height/depth swap — neither visible to the current dim re-read.

### radinator.cmd — NEXT
- **Claim:** "edge {id} (length L, adjoining a convex cylinder r≤0.875 and a plane) is a
  node-to-stiffener fillet and was rounded at radius R."
- **Slice:** for each matched edge — its length, the two adjacent surface types/orientations, the
  cylinder radius; and post-round, the presence of a new round surface. NOT the heuristic
  thresholds that selected it.
- **What it catches:** the heuristic mis-classifying an edge (the bad generalization), and rounds
  that fired but produced no geometry. Today radinator mutates with **zero** independent check.

### holeinator.cmd — NEXT
- **Claim:** "N holes of diameter Ø were created on the target datum points, on the jig face."
- **Slice:** `Count-Cylinders`/`Get-CylinderAxes` at the target radius before/after + the
  on-plane projection of each target point — the same measurements its own verify uses, but read
  by an **independent** judge so a bug in the shared surface walk can't hide from its own check.

### boxinator.cmd — REFERENCE
- Already verifies via `EvalOutline`. Wiring the judge here is mainly a reference implementation
  of the plumbing on a known-good numeric case; lowest new safety, useful as a worked example.

---

## Status

- Shared library + blind-evaluator + offline unit tests: **built, 43/43 tests passing**.
- Live REST round-trip: **verified** (`--probe-judge` confirms a true claim, refutes a false one).
- plane-probe.cmd: **wired end-to-end** (build + resize evaluation, gated final report).
- radinator / holeinator: contracts documented above; follow the proven pattern next.
