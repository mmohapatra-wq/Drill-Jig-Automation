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

> **Honest limit — and why there are two layers.** The judge does not do arithmetic. Numeric
> matching ("is 4.0 among [4.0009, 3.0, 2.0] within tol?") has one correct answer that must be the
> SAME every run; an LLM can flicker confirm/uncertain on identical input, and a verification gate
> that flickers is corrosive to trust. So the toolkit splits the work:
>
> - **Deterministic layer (`Test-ExtentsMatch`)** — the arithmetic, by value, tolerance-based,
>   order-independent. When present, **it is the gate.** Same geometry → same verdict.
> - **LLM layer (`Invoke-BlindJudge`)** — the *semantic* call ("does this measured geometry back
>   the claim, which extent is which without being told, is anything a bad generalization") plus a
>   readable summary. In numeric-gated mode it is **advisory**: a disagreement is surfaced loudly
>   but cannot flip the gate. For a claim with no number to check (e.g. "is this really a node
>   fillet?"), the LLM verdict *is* the gate.
>
> Numbers come from CAD; semantics come from the LLM; the gate stays deterministic wherever a
> number exists.
>
> **The make-or-break constraint.** A blind evaluator only adds value if the slice gives the judge
> signal the tool did not already use. A numeric claim gets that for free (independent `EvalOutline`
> measurement vs. the asked-for value). A *semantic* tool does not: if radinator's slice is the same
> four facts its heuristic used to select the edge, the judge just re-runs a fuzzier copy of the
> rule and "agreement" proves nothing. Semantic slices MUST carry more than the heuristic's inputs.

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

### radinator.cmd — NEXT (semantic-gated; the hard one)
- **Claim:** "edge {id} is a node-to-stiffener fillet and was rounded at radius R."
- **Slice — MUST exceed the heuristic's own inputs.** radinator selects an edge with four facts
  (straight, convex cylinder, adjacent plane, r ≤ 0.875). Feeding *those same four* to the judge
  is verification theater — it would just re-run a fuzzier copy of the selection rule. The slice
  has to add signal the heuristic never used: local topology around the edge, neighboring
  features, the edge's position/role in the part, what a "node" is structurally. That extra
  context is radinator's equivalent of the PLC evaluator reading the ladder logic.
- **Gating:** the "rounded at R" half is numeric (`Test-ExtentsMatch`-style: a new round surface of
  radius R appeared) — deterministic gate. The "is really a node fillet" half is semantic — LLM
  gate. Batch all edges into ONE judge call (the schema is already `perClaim[]`); never per-edge.
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

- Shared library + blind-evaluator + offline unit tests: **built, 56/56 tests passing** (incl. the
  deterministic-gating tests: numeric-fail gates FALSE even when the LLM says confirm; numeric-pass
  gates TRUE even when the LLM errors).
- Live REST round-trip: **verified** (`--probe-judge` confirms a true claim, refutes a false one;
  full dual-layer flow exercised live for a correct box and a deliberate depth-mismatch).
- plane-probe.cmd: **wired end-to-end** — claims use the user's ENTERED offsets (intent, not a
  re-read dim), deterministic numeric gate, LLM advisory, final report gated on the measurement.
- radinator / holeinator: contracts documented above; radinator's slice must exceed its heuristic's
  inputs (the make-or-break constraint) before it is worth wiring.
