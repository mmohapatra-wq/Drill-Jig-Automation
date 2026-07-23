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
- **`lib\orthogrid.ps1`** — pure hole-layout MATH, no COM/state. `Get-OrthogridGeometry` (regular
  Nx×Nz grid) AND `Get-CustomPointsGeometry` (arbitrary per-point layout) — the latter returns a
  **shape-compatible** object (same members + `Mode`='custom'/'orthogrid') so every drilljig
  `$orthoGeo` consumer works for both. Used by drilljig STAGE 2.5. Also `Get-HoleBoundingRect`
  (rectpocketinator — bounding box of hole centers + margin → subset-rectangle pocket, fit-checked
  + bore advisory, never throws) and `Resolve-EdgeAxis` (STAGE 6). Tested by `run_orthogrid_tests.ps1`.
  - **HOLE-COLLISION (intersection) CHECK — `-HoleDia` (added 2026-07-17, user: catch too-small
    spacings before they drill overlapping holes).** BOTH geometry functions take an OPTIONAL
    `-HoleDia` (default `0` = OFF → byte-identical to the pre-existing behaviour, all old tests
    green). When `>0` a spacing that would make adjacent bores **overlap** becomes a `Valid=$false`
    + an `Errors` entry (so the GUIs' existing "show `.Errors`, gate OK on `.Valid`" wiring surfaces
    it with NO front-end change). **Tangent is allowed** — spacing **==** `HoleDia` (edges just
    touch) passes; only **<** `HoleDia` (minus a 1e-9 float-noise tol) fails. Orthogrid: closest
    neighbours are one `CcX` (X) / one `CcZ` (Z) apart, so it flags `CcX<HoleDia` (only when `Nx>=2`)
    and `CcZ<HoleDia` (only when `Nz>=2`) directly — no O(n²) scan, single column/row has no same-
    axis neighbour so it's skipped. Custom: an O(n²) **pairwise straight-line distance** over the
    KEPT points (origin already dropped), reporting the first 5 offending pairs by typed coords +
    a "…and N more" summary. `HoleDia` is echoed on both result objects. Threaded from all four GUI
    recompute sites as `-HoleDia $clearDia` (`$clearDia` already = the hole Ø, or `0` when unknown →
    check stays off), so `drilljig.cmd` (via the modal dialogs) + `drilljig-gui.cmd` (inline editors)
    both get it. Covered by `run_orthogrid_tests.ps1` (orthogrid axis/tangent/Nx=1-skip + custom
    pairwise/diagonal/tangent/cap cases).
  - **EDGE-MARGIN (hole-vs-part-edge) CHECK — same `-HoleDia` knob (added 2026-07-17, user: "error
    if [the edge margin is] smaller than hole radius").** Riding the SAME optional `-HoleDia` (still
    `0` = OFF), each border hole must keep at least one hole **RADIUS** of wall to the part edge;
    **tangent (wall == radius) is allowed**, only **<** radius fails. Orthogrid: because the plate is
    sized with `ClearDia` (= hole Ø), the `Edge` field IS the wall from a border hole's edge to the
    part edge and is uniform on all four sides, so ONE check — `Edge < HoleDia/2` (when `Nx>=1 &&
    Nz>=1`, so a single hole is checked too) — covers every border. Custom: per-hole, the wall to the
    NEAREST of the four part edges (`X=0`/`Z=0` near datum, `Width`/`Height` far) must be `>= HoleDia/2`
    (wall = distance-to-edge − `HoleDia/2`); the near-datum case is a REAL runoff (a hole typed closer
    than a radius to the corner runs off the part), the derived far wall of the outermost hole is
    exactly one radius (tangent, passes). Same capped-message pattern as the collision check. No new
    threading — it activates through the already-threaded `-HoleDia $clearDia` at all four GUI sites.
    Covered by `run_orthogrid_tests.ps1` (orthogrid Edge<radius/tangent/Nx=1/OFF + custom near-edge
    runoff/far/tangent/cap). NOTE: the custom collision tests now pass `-ClearDia` alongside `-HoleDia`
    to mirror the GUI (ClearDia == hole Ø), so the derived far wall is a clean tangent.
  - **INDEX-RELATIVE CUSTOM LAYOUT — `Get-IndexRelativeCustomGeometry` (added 2026-07-21, user: "the
    index hole is based off the XZ corner, the rest of the holes are inputted and modeled based on the
    index hole").** A thin WRAPPER over `Get-CustomPointsGeometry` for the index-centric Custom mode:
    the operator types the INDEX hole as an offset from the plate CORNER (`-IndexX/-IndexZ`, the ONLY
    corner-measured coord), then every OTHER hole as an offset FROM THE INDEX (`-OtherPoints`, may be
    negative as long as the absolute stays ≥0). It builds the ABSOLUTE `{X;Z}` list with the **index
    FIRST at `Points[0]`** (so a front-end sets index-first with `IndexKey=0`), calls
    `Get-CustomPointsGeometry` **with `-KeepOrigin`** (the index survives even at the corner + keeps
    its positional identity), and augments the result with `IndexRelative=$true` +
    `IndexGridX/IndexGridZ` (= the index's corner offset = its grid coord). An other-hole whose ABSOLUTE
    coord lands `<0` gets ONE clear "off the near edge" error AND is dropped (no duplicate "X must be
    ≥0"); malformed/`$null` others never throw. **All entered holes drill** (index + others); the XZ
    corner is REFERENCE-ONLY. Threads `-ClearDia/-HoleDia/-EdgeMargin/-Width/HeightOverride` straight
    through. The returned `.Points` stay **ABSOLUTE corner-relative** — only the INPUT model is
    index-relative — so slotinator, `Get-RowSlots`, `Get-SharedPlanePlan`, and every `$orthoGeo`
    consumer work unchanged. `Get-SharedPlanePlan` on the points minus the index recovers exactly the
    typed relative offsets (index column/row → 0 = the STAGE-2.5 anchor plane), which is why the whole
    **existing index-first machinery** (base csys built AT the index in STAGE 1.9, planes offset by
    `(grid−index)` in STAGE 2.5) engages with NO downstream change. Covered by `run_orthogrid_tests.ps1`
    (`idxrel:` — abs math, index-first-at-Points[0], downstream recovery, index-only, corner-kept,
    off-edge single-error, malformed/null no-throw, collision, ClearDia sizing, EdgeMargin passthrough).
- **`lib\orthogrid_gui.ps1`** — WinForms editors (depend on `lib\orthogrid.ps1` in scope):
  `Show-OrthogridDialog` (regular grid) and `Show-CustomPointsDialog` (DataGridView — operator adds
  each point + types its X/Z offset, live readout + dot preview, OK gated on validity). Both route
  ALL math through the lib and echo `Thickness`/`HoleDiameter`/`ReliefDiameter` context. Both previews
  draw a shared **`Draw-AxisGlyph`** (X→ right / Z↑ up indicator in the bottom-left corner) matching
  the X/Z offset fields + the bottom-left plate-corner origin. WinForms ⇒ not in the offline suite,
  but parse-checked, function-resolve smoke-checked, and the glyph has a headless render assertion
  (`lib\tests\render_axis_glyph_check.ps1`: draws onto an off-screen bitmap, asserts pixels land).
- **`lib\orthogrid_points.ps1`** — datum-point creation/resolution: `Resolve-NewPointIds`/
  `Get-PointIdSet` (ID-only set diff), `Build-IntersectPointMacro` (PROVEN 3-plane-intersection),
  `Build-EdgePlanePointMacro` (STAGE 6 edge∩plane point — edge+plane fed by ID, same
  `ProCmdDatumPointGeneral` recipe; edge+plane ref pair not yet live-confirmed),
  `Get-SharedPlanePlan` (**pure** — distinct X/Z offsets + per-point indices; generalises the
  grid's plane sharing to ANY point set, orthogrid-equivalent for a regular grid), `Show-OrthogridTable`
  (mode-aware), `Invoke-ManualPointGrid`. `Build-PointGridMacro` [UNVERIFIED widgets] is retained but
  unused (the intersection recipe replaced it). Macro builders call the consuming `.cmd`'s
  `Get-SelectByIdMacro` at fire time (shared dot-source scope).
- **`lib\edge_round.ps1`** — HANDS-FREE edge rounding by dimension, **NO find tool** (proven live
  2026-06-24). `Get-EdgesBySweep` (sweep `GetItemById(ITEM_EDGE,1..N)` — discovers edges with no
  selection even where `ListItems(ITEM_EDGE)`=0), `Select-LowestDimensionEdges` (pure; auto-picks the
  smallest length, unit-tested offline), `Resolve-EdgeSelectFactory` (CMpfcSelect ProgID cascade),
  `Add-EdgesToSelection` (`Clear`+`CreateModelItemSelection`+`AddSelection`), `Invoke-AutoCornerRound`
  (orchestrator: sweep → lowest dim → self-test → round, `VersionStamp` canary). Used by edginator.cmd
  and drilljig STAGE 2b.
- **`lib\creo_api_facts.ps1` / `.json`** — machine-checkable registry of confirmed/refuted VB API
  facts (query by id/symbol/category/status; `Test-ApiFactsSchema` integrity check).
- **`lib\drilljig_core.ps1`** — the SHARED drill-jig engine: the proven helper bodies behind
  drilljig.cmd, lifted into one dot-sourceable module so BOTH drilljig.cmd (console) and
  `drilljig-gui.cmd` (wizard) call the SAME live-verified code. Two kinds: PURE (no COM) —
  tree/catalog parsing (`ConvertTo-Decimal`, `Get-CatalogSpec`, `Get-CatalogRows`,
  `Group-CatalogByOD`, `New-IdUnspecifiedPick`, `Get-FixedOdSpec`), the by-ID select-macro
  fragments (`Get-SelectByIdMacro`, `Get-SelectDatumByIdMacro`), the hole/relief macro builders
  (`Build-HoleMacro`, `Build-ReliefHoleMacro` — byte-for-byte the recorded recipes),
  `Resolve-PlaneRole`; and COM ORCHESTRATION — `New-OffsetPlane`, `Set-PlaneOffset`,
  `Set-ReliefHoleDepth`, the buffer readers (`Read-SelectedId`, `Read-SelectionPlanePicks`,
  `Find-DefaultDatumPicks`, `Resolve-SelectedPointIds`), `Invoke-Macro`/`Invoke-ForceRegen`/
  `Wait-ModelModified`, `Get-BodyList`. The COM helpers read a one-time scope set by
  `Initialize-DrilljigCore -Session -Model -TypeObj -DataDir [-Log]` (keeps the bodies near-
  verbatim instead of threading three params everywhere); `-Log` routes status text (default
  Write-Host; the GUI passes a callback into its run-log). Depends on `lib\creo_geometry.ps1`.
- **`lib\wizard.ps1`** — a small reusable WinForms WIZARD framework (the "Guided Build" spine for
  `drilljig-gui.cmd`). PURE logic (offline-tested): `Get-BreadcrumbStates` (done/active/future per
  stage), `Get-MaxCommittedIndex`/`Test-CanGoBack`/`Test-BackButtonEnabled`/`Get-FirstStepIndexForStage`/
  `Resolve-BreadcrumbClickStage` (**INTERWOVEN navigation — user 2026-07-21 "all the pages interweaved so
  the user can go through and change anything at any point"**): (1) the Back button is HIGH-CONTRAST
  (was dark-on-dark = invisible → "there are no back buttons") and shown on EVERY page except the first
  (`Test-BackButtonEnabled` = `index>0` drives Visible+Enabled); (2) Back is FREE — no blocking modal
  (`Test-CanGoBack` is retained/tested but no longer gates the click); (3) the breadcrumb rail is
  CLICKABLE — click a stage pill to JUMP to its first step (`Resolve-BreadcrumbClickStage` maps click-X→
  stage via `floor(X/slot)`, `Get-FirstStepIndexForStage` → target index), gated to stages ALREADY
  REACHED (`$wz.MaxReached`, bumped on each advance) so you can jump BACK to re-edit but never SKIP AHEAD
  past setup. Safe re-entry: each RUN step's OnNext is IDEMPOTENT (box-b/drill/slot-b `if built return`
  → passing back through never duplicates geometry), and a revisited built RUN step shows `Add-RebuiltNotice`
  (drilljig-gui.cmd) = a "✓ already built" banner + a **Rebuild** button that WARNS (old feature stays in
  Creo — delete it first), resets that step's done-flags, and `$wiz.GoToStepKey`s to its arm step so a
  changed upstream choice (e.g. a different bushing) can actually be re-applied. `Resolve-ChipColorName`
  (honesty palette: gray=needs-input,
  steelblue=set, green=built+verified, goldenrod=unverified, firebrick=aborted), `New-WizardStep`.
  WinForms surface (parse + headless-instantiate checked): `Show-Wizard` (one never-closing
  window: breadcrumb-rail Paint + CLICKABLE jump + swappable canvas + chip band + Back/primary action bar +
  RUN view = marquee + live log + busy guard) and `Add-WizardChoiceCards` (flat choice cards;
  - **BREADCRUMB-RAIL RESIZE REPAINT (fixed 2026-07-21, user: "duplicates the progress chart" on
    maximize→restore→maximize).** The `$rail` panel is Right-anchored (STRETCHES on resize) and paints
    every pill at a WIDTH-PROPORTIONAL X (`$slot = ClientSize.Width / N`). A WinForms Panel does NOT
    repaint its whole surface on resize by default — on a GROW Windows blits the old pixels and
    invalidates only the newly-exposed strip, so the old pills stay drawn at their old-width positions
    while the Paint handler draws new ones at new positions → **two overlapping breadcrumbs**. It
    "self-heals on the next page" only because `$renderStep` issues a full `$rail.Invalidate()`. FIX
    (`lib\wizard.ps1`, right after the rail is created): `$rail.Add_Resize({ $s.Invalidate() })` (full
    client-rect invalidate on every resize — covers GROW and SHRINK, clearing stale pills before the
    repaint) + set the protected `ResizeRedraw`/`DoubleBuffered` Control properties via reflection
    (full-surface repaint + flicker-free during a drag-resize; reflection wrapped in try/catch, the
    `Add_Resize` invalidate is the belt-and-suspenders guarantee). Regression-tested in
    `run_wizard_tests.ps1` ("rail resize repaint" — source-level lock on the `Add_Resize`+`ResizeRedraw`
    wiring, plus a behavioral drive that GROWS a live wizard form and asserts a rail repaint fires
    across the resize).
  `-AfterPick rerender|advance|none`). The `$wiz` controller handed to each step exposes
  `SetChip`/`Log`/`SetProgress`/`BeginRun`/`EndRun`/`MarkCommitted`/`Refresh`/`Rerender`/`Next`/`GoToStepKey`.
  Blocking COM runs synchronously on the STA thread inside a step's OnNext; `BeginRun` hard-
  disables input (no re-entrant RunMacro) and `Pump`/DoEvents repaints BETWEEN atomic batches.
- **`lib\tests\run_tests.ps1`** — offline unit tests (no Creo, no network). Run:
  `powershell -ExecutionPolicy Bypass -File lib\tests\run_tests.ps1` (exit 0 = all pass).
  Companion suites: `run_orthogrid_tests.ps1` (grid math + point-grid macro/diff), `run_response_tests.ps1`
  (response-convergence harness), and `run_wizard_tests.ps1` (wizard breadcrumb/back-guard/chip
  palette + drilljig_core pure parsing/macro builders + a parse-and-resolve smoke of drilljig-gui.cmd).

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

### edginator.cmd
Rounds the edges of a given DIMENSION (edge length) **hands-free** — discovers the matching edges itself (no geometry selection), filters by length, and rounds them. The hands-free answer to "find an edge with a certain dimension, then round those corners," and the tool that broke cornerinator's foreign-body wall. **CONFIRMED LIVE 2026-06-24** (part 004-826-0638-001).

**The breakthrough — selection with NO find tool.** On the imported/"foreign" jig body the find tool is dead for ALL selection (select-all AND by-ID) and all four COM enumeration routes return 0 edges (see cornerinator). The pipeline that works is pure VB API:
1. **DISCOVER (no pick):** sweep `$model.GetItemById(ITEM_EDGE, 1..N)`. `GetItemById` resolves edges directly even when `ListItems(ITEM_EDGE)`=0 — it was never one of the 4 dead routes. Live: 28 edges in 1.9s, no selection.
2. **MEASURE:** `$edge.EvalLength()`.
3. **FILTER (PowerShell):** the Search tool CANNOT filter edges by length, so length filtering happens in code. Default target = the **LOWEST** dimension present (a plate's shortest edges are its through-thickness corners); `--target <len>` / `--tol <t>` override, no prompt.
4. **SELECT (no find tool):** `CMpfcSelect.CreateModelItemSelection(edge,$null)` → `($session.CurrentSelectionBuffer()).AddSelection(sel)`. The `CM*` factory is never a standalone ProgID (the `pfcRegenInstructions` gotcha) — `Resolve-SelectFactory` cascades candidate ProgIDs. Manual-pick fallback re-adds the original buffered `IpfcSelection` (Path 1a).
5. **ROUND:** the proven `ProCmdRound` mapkey (radinator), `VersionStamp` canary per ≤40-edge batch.

**Fully automatic, with safety gates that are NOT prompts.** Only the radius is asked (blank → 0.25). No target prompt, no proceed prompt. Before any mutation a **live self-test** selects one matched edge via the API and verifies the buffer — aborts cleanly (no geometry) if selection is broken. The canary aborts after batch 1 if the model didn't change. Honest reporting: *batches fired*, not rounds Creo accepted. The whole engine lives in `lib\edge_round.ps1` (shared with drilljig STAGE 2b).

**Probes that established this (read-only diagnostics):** `cornerinator-probe.cmd` fires 4 candidate find-tool select-all macros → all return an EMPTY buffer with no widget error (the results-list row-select→Add step has no mapkey token), proving the find-tool select-all path dead. `vbselect-probe.cmd` proves the replacement: `GetItemById` sweep discovery (count + length spread), `Clear`+`AddSelection` subset reselection, and that buffered foreign-body edges expose `EvalLength`. See [[project_find_edge_by_length]].

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
4. Bushing pick (`Invoke-BushingPick`) — TWO shapes, chosen by the catalog spec's filter column:
   - **METAL removable-bushing path (OD-FIRST — user 2026-07-22).** For **METAL → PFD / Hand Drill** the tree resolves to a **removable bushing filtered by OD** (PFD = `3/4 OD`; Hand Drill = `3/4 OD` + `1/2 OD`), and the drilled jig hole **IS** the removable bushing's OD — the technician doesn't care about the bore ID. So this path **DISPLAYS THE OD (never the ID), SKIPS the ID question entirely, and only `0.5"`/`0.75"` ODs ever show**, then asks the standardized length. Discriminator: `Test-OdFirstSpec` = the spec carries an **OD-column** filter (`Get-CatalogSpec` emits an OD filter ONLY for the metal removable leaves; the 3D-print sleeve leaves filter on **ID**) — no label re-parsing. `Get-OdGroups` gives the distinct OD cards (`-> hole 0.5"`/`0.75"`); the length menu is the SAME fixed `{1/2, 3/4, 1} + Custom`, but **recommended from the OD value** (`0.5 OD → 1/2"`, `0.75 OD → 3/4"`) via `Get-BushingLengthOptions -Id <OD>`. `Resolve-OdBushingPick` returns the pick with **`ID = '(any)'`**, `OD` = the drilled hole, `Length` = the chosen value (borrows a real `PartNumber` if a SKU at that (OD, length) exists, else `(ID unspecified)`). There is NO OD tie-break (OD is already chosen). The three pure helpers `Test-OdFirstSpec`/`Get-OdGroups`/`Resolve-OdBushingPick` live in `lib\drilljig_core.ps1` (shared) and are mirrored into `jiginator.cmd`/`.ps1`. In `drilljig-gui.cmd` the metal spec sets `$ctx.BushOdFirst=$true` + a new `'od1'` bush sub-stage (OD cards); `Set-BushLengthPick`'s OD-first branch resolves + finishes.
   - **3D-PRINT sleeve path (ID-FIRST — user 2026-07-21, UNCHANGED): ID → STANDARDIZED length menu → OD tie-break** (technician rule: sleeve lengths are standardized to the bore, so a 1/2" ID is normally 1/2" long, a 3/4" ID 3/4" long). **ID** first (the bore; its resolved-hole preview — `-> hole 0.5"` or `N OD options` — rides the ID card via `Get-IdOdOptions`). Then a **FIXED length menu {1/2, 3/4, 1} + Custom** (`Get-BushingLengthOptions`): the length matching the ID is **RECOMMENDED** (console: blank ENTER accepts it; GUI: the card is marked), and **Custom** takes any typed value (decimal / `3/8` / mixed `1 3/8`, validated by `Resolve-BushingLengthInput`, rejects ≤0). Because the fixed menu is **decoupled from the catalog's length rows**, **OD is re-keyed on ID ALONE** (the union of the ID's distinct ODs) — auto-resolved when unique, offered as a tie-breaker when the ID reaches >1 OD (OD IS the drilled hole, never silently chosen; the tie-break no longer references length). `Resolve-BushingPickRow` returns the real SKU row when an exact (ID, OD, length) exists, else a **synthesized** pick (`PartNumber = "(custom length)"`) carrying the chosen length.

   **CRITICAL (both paths): `.Length` is always the chosen (possibly custom) length** — it flows to `BushingLength` → drilljig STAGE 2 SIDE-plane offset (= plate thickness); `.OD` is always a real catalog value. The shared pure helpers live in `lib\drilljig_core.ps1` (used by drilljig.cmd + drilljig-gui.cmd) and are **mirrored as local copies in jiginator.cmd / jiginator.ps1** (self-contained). Machinist fractions ("3/4", "1 3/8") are shown from the row `EasyName` via `Get-FracLabel`. Offline-covered in `run_wizard_tests.ps1` (`odfirst:`/`odgroups:`/`odlen:`/`odpick:` + the tree-walk integration test now walking the metal OD-first path). LIVE-UNVERIFIED (the interactive console/GUI run is not exercised headless).
   - **CUSTOM HOLE OD — a "Custom hole OD" option on EVERY hole-diameter pick (user 2026-07-23, "add a custom HOLE OD option to all parts of the tree for hole diam").** At the hole-diameter level of BOTH chains — the metal OD-first list AND the 3D-print sleeve ID-first list — a trailing **"Custom hole OD…"** entry lets the operator type an ARBITRARY diameter (decimal / `3/8` / mixed `1 3/8`) instead of a catalog value. Because NO catalog SKU backs a typed OD, the flow prints a **bold verify-bushing warning** (console: yellow banner; GUI: a `'yellow'`-colored para — NOT `'warn'`, which `Get-UiColor` maps to ink) then continues **straight into the standard length menu** (recommended from the typed OD; no extra acknowledgment keystroke). Two PURE `global:` helpers in `lib\drilljig_core.ps1` drive it (mirrored into jiginator.cmd/.ps1): **`Resolve-CustomOdInput`** (parse; **BLANK is an ERROR** — no default hole Ø, unlike the length validator which defaults; reject ≤0 / NaN / Inf / `3/0`) and **`Resolve-CustomOdPick`** (synthesized pick: `OD`=typed, `ID='(custom)'`, `PartNumber='(verify bushing exists)'`, EasyName `"Bushing | OD <od> x ID (custom) x <len> Lg"` so `Get-FracLabel` still parses it). Console: an `Invoke-CustomOdPick` helper (OD-entry loop → warning → length menu) reachable as the last numbered item on both menus. GUI: a new `'customod'` `BushStage` (inline OD textbox + `Resolve-CustomOdInput` live echo + "Use this OD" → `'len'`), a trailing card on the `'od1'`/`'id'` stages (OnPick **index-guarded** past the group count → sets `BushCustom=$true`, clears `BushOdFirst`/`BushOD`/`BushID`), a `Set-BushLengthPick` **FIRST branch** `if ($Context.BushCustom)` (before OD-first/ID, else the ID-null guard would drop it), the 5 `BushCustom*` context fields threaded through Push/Pop/Reset-TreeHistory + the `'len'` recommend-source + Validate/OnNext `$lrv`/`$lenReady`, and a bold warn para + `(verify)` bore label in the confirmation schematic. Downstream is unchanged — a custom pick carries the same `.OD`/`.Length`/`.EasyName`/`.PartNumber` shape every consumer already reads. Offline: `run_wizard_tests.ps1` (`customod:` — parse/synth/Set-BushLengthPick-first-branch). LIVE-UNVERIFIED.
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

### point-probe.cmd
**EXPERIMENT (plane-probe-v2 branch), CONFIRMED LIVE 2026-06-24.** Creates a datum **POINT** at every X/Y/Z you type, using a recipe whose **every widget is proven-live** — no guessed dialog tokens, no screen picks.

**The recipe — a point is the INTERSECTION of 3 offset planes:** three mutually-perpendicular planes meet at exactly one point, so for a point at `(X,Y,Z)`:
1. create an offset plane `X` from base-plane #1, `Y` from #2, `Z` from #3 — the **proven** `ProCmdDatumPlane` + `t1.constr_dim1` + `stdbtn_1` recipe (plane-probe's `New-OffsetPlane`; a `0` coord reuses the base plane directly rather than making a degenerate plane);
2. select those 3 planes **BY ID** — repeated tree-search select-by-ID, `buffer_clean` on the FIRST only, the 2nd/3rd with `-NoClear` to **accumulate** into the buffer — then `ProCmdDatumPointGeneral` + `stdbtn_1`. The buffered planes are consumed as the point's references and OK drops the intersection point.

Every token here is recorded confirmed-live in `lib\creo_api_facts.json` (`datumpointgeneral-command`, `point-at-3-plane-intersection-by-id`, `selectbyid-accumulates-multiref`). The point is **parametric** — each coordinate is a drivable feature-level plane-offset dim — so the re-drive loop moves a point by re-writing one.

**Why this, not the obvious alternatives (the hard-won pivot):** the live Creo trail (`working_folder\trail.txt.N`) showed every datum point the user makes is placed by **clicking** a surface + edges to offset from (`@sel` mouse picks) via `ProCmdDatumPointGeneral` + `t1.OffsetRefsTable`/`OffsetRefsOffsetOptMnu_MRU1` — references that come from the mouse, which a `RunMacro` **cannot replay** (the holeinator pick wall; fact `datum-point-offset-from-refs-needs-picks`, refuted). The "Offset Coordinate System" X/Y/Z-table point is the only other pick-free mode but its widgets were never recorded. The 3-plane-intersection route sidesteps both: it needs only select-**by-ID** (proven) + the proven plane-offset recipe. `pointref-probe.cmd` (below) confirmed the load-bearing assumption live (3 planes fed by ID → 3/3 loaded as references → `F6 PNT0` created).

**Verification = TWO ID-only signals (never reads `IpfcPoint.Point`, which crashes — see holeinator):** (1) new-point **COUNT** == points entered (`Resolve-NewPointIds`, before/after `ITEM_POINT` set diff); (2) the offset-plane **DIMS** carry your X/Y/Z (`Get-LinearDimMap` diff + `Test-ExtentsMatch` by-magnitude multiset). "CONFIRMED" only when both pass; "PARTIAL" if points exist but dims didn't match.

**Flow:** enter points (`X Y Z` each, blank ends) → click the 3 perpendicular base planes in X/Y/Z order → confirm → per point: make up to 3 offset planes + intersect them into a point (hands-free, no picks) → VERIFY count + dims → re-drive loop. `.asm` guard; config-suppress + `finally`; ASCII-only output.

**History / why it's solid:** first built around the OCS X/Y/Z table with **guessed** widgets — fired clean but created nothing (wrong widgets + the table mode the user never uses). Pivoted by **reading the live trail** to find the real command (`ProCmdDatumPointGeneral`, not `ProCmdDatumPoint`) and the pick-bound reality, then `pointref-probe` proved the by-ID feed, then rewritten to the intersection recipe. A **verification workflow** (trail evidence + facts audit + PowerShell logic review) confirmed every create-path token is proven-live and caught **two HIGH discovery-logic bugs** in `New-OffsetPlane` (the feature-id diff was uncorrelated to the dim poll, sampled once, unbounded in count) — both fixed: require **exactly one** new feature (else `$null` → caller skips, fails closed) and poll the dim set + feature set **together**.

**Cost / next step:** 3 offset planes per point (model clutter). For a regular grid this should share planes — **1 face + Nx + Nz planes → Nx·Nz intersection points** — which is the natural follow-up and the path to wiring point creation into drilljig (replacing the "points must pre-exist" assumption).

### pointref-probe.cmd
**Observational diagnostic (creates NOTHING).** Answered the one make-or-break question behind `point-probe`: does `ProCmdDatumPointGeneral` **consume datum-plane references fed BY ID** (the way `ProCmdDatumPlane` consumes one)? It captures 3 plane IDs (3 clicks), fires ONE atomic macro that pre-selects all three by ID (accumulating via `-NoClear`) then opens the point dialog, asks the user how many references loaded (0/1/2/3), and has the user cancel. **Result 2026-06-24: 3/3** — by-ID feed AND accumulation both work, which greenlit `point-probe`'s recipe. Leaves `visible_mapkeys` on so the run is also captured in the trail.

### csys-probe.cmd
**EXPERIMENT** — the offset-COORDINATE-SYSTEM analog of `point-probe`/`plane-probe`: enter X/Y/Z translations (+optional rotations), create a datum csys, and verify the entered offsets bound to the new feature dims (before/after `Get-LinearDimMap`/`Get-AngularDimMap` diff + `Test-ExtentsMatch` multiset + fresh-handle re-read). Its create macro (`Build-CsysMacro`) is **UNVERIFIED best-guess widgets** (`ProCmdCsys`, `t1.OffsetX/Y/Z`), canary-gated, with a guaranteed manual-create fallback — not yet live-confirmed (the csys-create dialog was never recorded; a `visible_mapkeys yes` recipe is in the file header). `Get-AngularDimMap` (the DimType-3 companion to `Get-LinearDimMap`, for rotation offsets) was added to `lib\creo_geometry.ps1` (+offline test) for this.

### csysinator.cmd
Creates a datum **COORDINATE SYSTEM at the INTERSECTION of 3 mutually-perpendicular planes** — the standalone twin of drilljig's index-hole csys (STAGE 5). You select **3 planes IN ORDER** (X-normal, then Y-normal, then Z-normal); three perpendicular planes meet at ONE point, and that point becomes the CSYS **ORIGIN** with axes set by the selection order. Standalone; open the jig **PART** (not `.asm`). Dot-sources `lib\creo_geometry.ps1` + `lib\orthogrid(_points).ps1` + `lib\drilljig_core.ps1`.

**REWRITTEN 2026-07-13 — the round-edge-center / offset-plane / orientation-pick approach was SCRAPPED (user: "that is all crap").** That old flow (origin = a round edge's center, +Y from the edge, +X from a picked plane) deadlocked (`com-read-deadlocks-while-dialog-open` — a COM read while the csys dialog is open freezes the run) and needed MOUSE picks a `RunMacro` can't replay (`datumcsys-dialog-sequence`, its by-ID feed refuted). All of it (`Get-EdgeArcCenter`-driven center read, `Get-CsysAxisPlan`, `Get-CsysPointOriginMacro`, the offset planes → intersection-point → csys machinery) is GONE. The retained `Get-EdgeArcCenter` / `Read-CoordSysTransform` in `lib\creo_geometry.ps1` are now just general-purpose reads (still unit-tested, no longer used by csysinator).

**The NEW recipe — the exact analog of the proven 3-plane-intersection DATUM POINT (`Build-IntersectPointMacro` → `ProCmdDatumPointGeneral`):** select the 3 planes **accumulated BY ID** (tree-search select-by-ID, `buffer_clean` on the 1st only, `-NoClear` on the 2nd/3rd — `selectbyid-accumulates-multiref`), then `ProCmdDatumCsys` → `stdbtn_1` (OK). Same accumulate-selection, point command swapped for the csys command. Transcribed from the operator's recorded mapkey `yes` (2026-07-13; `docs\csys_at_3_plane_intersection.mapkey.txt`, fact `csys-at-3-plane-intersection`). The whole engine lives in **`lib\drilljig_core.ps1`** — `Build-CsysFromPlanesMacro` (PURE, ordered plane triple → the atomic macro) + `Invoke-IndexCsys` (COM orchestration + canary + optional show) + `Get-CsysShowMacro` — **SHARED** with drilljig STAGE 5 and drilljig-gui's Index stage.

**Order = axes (fixed 2026-07-13).** The plane SELECTION ORDER sets which axis aligns to which; the ORIGIN (the intersection) is correct regardless. drilljig feeds the triple in X/Y/Z-normal order `[X-plane(from TOP), SIDE-face, Z-plane(from FRONT)]`: per the grid contract ("X = TOP-direction offset, Z = FRONT-direction offset") the X-offset plane's normal IS the model X axis and the Z-offset plane's is Z, leaving the SIDE face as the Y-normal. This is a deliberate REORDER of the point-build order (the point is built `[face, X, Z]`; the intersection is order-independent, the csys axes are not). Plane normals read null on this build, so the axis assignment CANNOT be verified programmatically — the post-create report asks for a visual check, and if an axis is mirrored the fix is the plane pick order.

**Verify = feature-diff canary (the GATE).** `Invoke-IndexCsys` diffs `Get-FeatureIdSet` before/after; a NEW feature must appear or it reports "NOT created" — never "macro fired" ([[feedback_canary_must_not_assume_on_failure]]). Flags: `-v` verbose (prints the macro). Offline: `lib\tests\run_csys_tests.ps1` (56 cases — the retained `Get-EdgeArcCenter`/`Read-CoordSysTransform` reads + the new `Build-CsysFromPlanesMacro` token lock (fires `ProCmdDatumCsys`, one `buffer_clean`, NONE of the scrapped `t1.OriginPlacement`/`pg_vis_tab`/`AxisMenu`/`FlipBtn`/`DirectionTable` widgets) + `Get-CsysShowMacro` + `Resolve-IndexHolePlanes` match-precedence/never-throw). **NOT yet confirmed live in this by-ID form** (the operator's mapkey selected the planes in the model tree `PHTLeft.AssyTree`; the tool feeds them by tree-search select-by-ID, the accumulation channel proven for the sibling point command). Canary-gated, so a no-op is caught.

### drilljig.cmd
End-to-end drill-jig flow in ONE console session and a SINGLE Creo connection — a MERGE of three working tools (jiginator + plane-probe + holeinator), which are left untouched and still run standalone. STAGE 1 walks the decision tree (no Creo) → hole OD; STAGE 2 builds a parametric box from three offset datum planes (plane-probe v2); STAGE 3 drills an On-Point hole at every target datum point (holeinator) at the STAGE-1 diameter; STAGE 4 cuts **chip-relief SLOTS** (one blind rectangular slot per hole ROW — the slotinator method). The hole diameter is handed STAGE 1 → STAGE 3 as an in-process variable (NOT via `last_jig_spec.json`). Assumes the target datum points ALREADY EXIST in the part; open the jig PART (not `.asm`).

**CSYS-REFERENCED PLANES — the box + grid PITCH planes hang off a base coordinate system, not the default datums (2026-07-14; offline-green, LIVE-UNVERIFIED).** Formerly every datum plane was an offset from the `TOP`/`SIDE`/`FRONT` default datums. Now a **STAGE 1.9** creates a **base coordinate system** fully automatically from the part's default csys — `Find-DefaultCsysId` (enumerates `ITEM_COORD_SYS`, prefers a known default name `CSYS_PAT_DEF`/`PRT_CSYS_DEF`/…, else the first csys) → `Invoke-BaseCsys` → `Build-CsysFromCsysMacro` (select the csys by ID → `ProCmdDatumCsys` → OK), canary-gated on a new feature. The Top/Side/Front box planes AND the grid X/Z pitch planes are then created as **offsets from that csys + an axis** (`New-CsysOffsetPlane` → `Build-CsysOffsetPlaneMacro`: select csys by ID → `ProCmdDatumPlane` → `t1.constr_csys_axis`=`Axis_X/Y/Z` → optional `t1.constr_dim1` offset → OK; same `@{Symbol;FeatId}` return as `New-OffsetPlane`, LEFT INTACT for slotinator/`New-SlotGuidePlanes`). **Axis mapping**: grid-X ↔ `Axis_X`, SIDE ↔ `Axis_Y`, grid-Z ↔ `Axis_Z`. **The box still SKETCHES on the SIDE DEFAULT DATUM (a proven, correctly-oriented plane) and extrudes to the SIDE csys plane (`Axis_Y @ len`); the grid points intersect `(SIDE datum, Axis_X@Xoff, Axis_Z@Zoff)`; the slot seed sketches on the SIDE datum too.** (An earlier attempt sketched on an `Axis_Y @ 0` csys "F" plane — that offset-0 csys plane is a poor, under-defined sketch plane and BROKE the extrude live; F was removed. The face only sets Y=0, and the X/Z position comes entirely from the csys pitch planes, so an in-plane (X/Z) re-reference still moves every point with the csys — F bought nothing.) **STAGE 5.5 — CHANGE THE BASE CSYS TO THE INDEX HOLE, default `transform` (the user's mapkey-three method, reaffirmed 2026-07-15).** The base csys everything is offset from is relocated onto the index hole by **changing its coordinate-system TYPE to a file transform**: (1) Analysis → Transform (base → index) writes a static matrix to `info.trf`; (2) `ProCmdRedefine` the base csys with `t1.OffsetType=file` importing it. This is **NOT a reference cycle** — `OffsetType=file` bakes a *static matrix* relative to the base's parent (`CSYS_PAT_DEF`); the file is data, not a live feature reference to the index csys (the index csys is only *read* to compute the matrix, then frozen). So after the redefine the base is `CSYS_PAT_DEF + baked matrix` with no live edge back to the index csys, and the whole jig (planes → points → holes, offset from the base) follows. (An earlier note here wrongly called this a cycle — corrected; the earlier live break was the fragile file-dialog leg, not a cycle.) Engine: `Invoke-CsysTransformReimport` (`Build-CsysTransformExportMacro` + `Build-CsysReimportMacro`), canary-gated on the model changing, reported UNVERIFIED. **`--reref-method` methods:** **`transform`** (DEFAULT; `static` is an alias) → change the base onto the index csys directly; **`independent`** (`Invoke-IndependentReref`) → same file transform but onto an anchor csys built off `CSYS_PAT_DEF` at the index hole's `(GridX,0,GridZ)` — an alternative if targeting the index csys directly misbehaves live; **`output-csys`** (`Invoke-OutputCsys`) → do NOT move the base, instead build a *separate* datum csys at the index hole off `CSYS_PAT_DEF` (no file leg, no move) — fallback for when a named datum is preferred over a move; **`none`** (`--no-reref`) → nothing extra (STAGE 5 index csys + STAGE 6 export already reference the index hole). LIVE-UNVERIFIED: the `info.trf` Save-As/Open dialog widgets + an omitted `@PAUSE_FOR_SCREEN_PICK` (the move methods) and `datumplane-offset-from-csys-axis` (already on the run's critical path). The parentage caveat (`drilljig-no-single-movable-parent`) — plate sketched on the SIDE default datum, holes off the base csys — is a LIVE-VERIFY item, not a proven break. **Flags: `--no-base-csys`** (fully-legacy default-datum planes) and **`--reref-method transform|independent|output-csys|none`** (`--no-reref` == `none`). The default datums are REQUIRED in csys mode (the box/grid/slot sketch+intersect on the SIDE datum) — captured by API/`Find-DefaultDatumPicks`, else the multi-select/sequential fallback, exactly like legacy. **drilljig-gui.cmd mirrors all of this** (base csys in box-a's OnNext; csys pitch/guide planes in box-a + the drill step's grid; SIDE-datum sketch; STAGE 5.5 inside the Index stage). Engine in `lib\drilljig_core.ps1` (`Find-DefaultCsysId`, `Build-CsysFromCsysMacro`, `Invoke-BaseCsys`, `Build-CsysOffsetPlaneMacro`, `Resolve-NewPlaneAfterCommit`, `New-CsysOffsetPlane`, `Build-CsysTransformExportMacro`, `Build-CsysReimportMacro`, `Invoke-CsysTransformReimport`); token-locked in `run_csys_tests.ps1` (126); facts `csys-from-csys-reference` / `datumplane-offset-from-csys-axis` / `csys-transform-reimport` (all `docs-only`). **Constraint honored: the point/hole CREATION loops are byte-for-byte unchanged — only what the box/grid PLANES reference changed.**

**INDEX-FIRST MODE — reference the index hole WITHOUT moving anything (2026-07-15; the geometry-preserving answer to "features stay the same but reference the index hole").** Because every base-move (`transform`/`independent`) risks cutting the jig (`drilljig-no-single-movable-parent`: the plate is on the SIDE default datum, the holes hang off the base csys — they have no single movable parent), the clean fix is to **build the base csys AT the index hole from the start** rather than move it later. Right after the layout is captured (before any Creo work), the operator can pick one layout hole as the **index** (console: numbered prompt; GUI: an `index-choice` step under the Layout breadcrumb; both default to *none* = today's origin-based behavior). When chosen (the operator's construction): **STAGE 1.9** builds the base csys **AT the index hole** via `Invoke-OutputCsys -RefCsysId <CSYS_PAT_DEF> -GridX indexGridX -GridZ indexGridZ` — created **before** any holes are drilled, so the base csys **is** the index coordinate system. **EVERYTHING built off it is offset relative to it with the SAME `(dim − index) × flip` formula, so the whole jig stays in one frame:** the **STAGE 2 box plate planes** (`Top = Axis_X @ ((Width − indexGridX) × flipX)`, `Front = Axis_Z @ ((Height − indexGridZ) × flipZ)`, `Side = Axis_Y @ bushingLen` — Y has no index component) **and** the **STAGE 2.5 grid planes** (`Axis_X @ ((gridX − indexGridX) × flipX)`, `Axis_Z @ ((gridZ − indexGridZ) × flipZ)`). The index hole's own offset is **0** (its point lands on the csys origin); every other hole + the plate edges are the X/Z **margin difference**, so the plate and holes line up with each other and match the GUI layout. **THE FIX (2026-07-15, likely root cause):** earlier only the *grid* planes were index-relative while the *box* planes stayed absolute off the same index-hole base → the plate shifted by +index while the holes were index-relative, so the holes didn't line up with the plate/GUI; making the box planes index-relative too keeps plate + holes in one frame (and this holds even if the base csys origin isn't exactly at the index hole — plate and holes shift together, index hole always at the csys origin). **STAGE 5** records the base csys as the index csys (`$indexCsysFeatId = $baseCsysId`) and **STAGE 6** exports every hole relative to it (`Get-HolesRelativeToIndex`, index hole = 0,0). **STAGE 5.5** forces reref `none`. **ORIENTATION CAVEAT (the load-bearing live-unknown):** the index-hole base csys is built from 3 intersecting planes and this build reads plane normals as **null** (fact `csys-at-3-plane-intersection`), so its `Axis_X/Axis_Z` **directions** aren't programmatically verifiable — if the live holes come out **mirrored on an axis**, re-run with **`--index-flip-x` / `--index-flip-z`** (`$indexFlipX`/`$indexFlipZ` = −1, negating that axis's grid offset; no code change). This is the correct knob: a *global* offset sign flip cannot fix a *single* mirrored axis, which is why flipping the sign twice earlier failed (root-cause workflow, high confidence). Blank/no index → plain `CSYS_PAT_DEF` copy + absolute offsets (today's behavior). Pure helper `Get-IndexHolePlan` (`lib\orthogrid_points.ps1`) returns candidates + the chosen grid coords. Invariants (fact `drilljig-index-first-grid`): the point/hole CREATION loops are byte-for-byte unchanged (only the plane-offset VALUE + the base-csys build change); `$csysRecords.GridX/GridZ` stay **ABSOLUTE** (`Get-HolesRelativeToIndex` does its own `gridX−index`). Predefined-point mode (no `$orthoGeo`) never offers it. LIVE-UNVERIFIED (confirm the drilled pattern matches the GUI layout referenced from the index hole; if mirrored on an axis, use the flip flag).

**CHIP-RELIEF SLOTS replace relief holes + paths (2026-07-07).** The old STAGE 4 (coaxial relief holes) and STAGE 6 (relief paths) were **REMOVED** from drilljig.cmd AND drilljig-gui.cmd at the user's request ("I DO NOT WANT THE RELIEF HOLE AND REMOVAL PATH"). The new **STAGE 4 = chip-relief SLOTS**: after drilling, cut one blind rectangular remove-material slot per hole ROW (length = part length, width = the drilled hole dia, depth = `SLOT_DEPTH_ABS` — an ABSOLUTE 0.25" default, set 2026-07-21; the plate SIDE offset is padded by this same value, `plate = bushingLen + SLOT_DEPTH_ABS`, so `plate − slot = bushingLen` — the final guide depth equals the bushing length after the cut), seed-drawn once then patterned along a base datum plane's normal. It REUSES the context already gathered — `$holeDiaFinal` (slot width), the live SIDE offset (depth), `$orthoGeo` (rows) — with **NO re-prompts** (the standalone slotinator re-asks these only because it has no prior context). The engine is shared in **`lib\drilljig_core.ps1`**: `Build-CutFinishMacro`, `Invoke-VerifiedSeedCut` (console; reads the `$script:DJSession/DJModel` core scope), and `Build-SlotPatternMacro` (arm + datum-by-ID direction + count/spacing + confirm) — the SAME confirmed-live macros slotinator.cmd uses (deduped: slotinator no longer defines them locally). Material gate kept (`$is3dPrint` → auto; metal → ask). Needs a GUI layout (orthogrid/custom); PREDEFINED points have no rows → slots skipped. **GUIDE PLANES:** before the seed draw both front-ends call **`New-SlotGuidePlanes`** (`lib\drilljig_core.ps1`) — the slot-edge offset planes slotinator shows (one per distinct X edge off TOP + Z edge off FRONT; a ~0 offset reuses the base datum; pattern mode = the FIRST row's edges only), made visible via `ProCmdViewShow@PopupMenuTree` so the operator draws the rectangle to size. Flags: `--no-slot-relief`, `--pattern-flip`, `--slot-flip`, `--slot-depth N` (absolute inches, default 0.25), `--no-pattern`. Offline: `run_wizard_tests.ps1` (118) covers the slot macro token structure + `New-SlotGuidePlanes` (pattern<all-rows, no-throw) + slotinator parity; `run_orthogrid_tests.ps1` (272) covers `Get-RowSlots`/`Get-SlotPatternPlan`. **CONFIRMED LIVE 2026-07-08** (operator: slot pattern + guide planes work in the integrated drilljig + GUI).

**TIGHT / RESTRICTED-SPACE SLOT DEPTH — asked RIGHT AFTER the bushing decision tree (2026-07-21, user: "there might be a scenario where the user is working in really tight spaces, in which they might want the slot depth to be less").** The chip-relief slot depth doubles as the plate EXTRUDE PAD (`plate = bushingLen + slotDepth`; the slot removes `slotDepth`; so the final functional guide depth `== bushingLen` for **ANY** positive depth). A **smaller** slot depth therefore just makes a **thinner overall plate** — exactly what a tight/restricted space needs. So right after STAGE 1 (before the point-source choice) the operator is asked **"tight/restricted space?"**: **yes** → they type their own (usually smaller) depth → overall extrude `= bushing sleeve + entered depth`; **no** → keep the 0.25" default → extrude `= bushing + 0.25"`. **`--slot-depth N` is an explicit override that SKIPS the prompt.** This is the ONLY functional change — it sets the SAME `SLOT_DEPTH_ABS` the existing pad/cut machinery already flows end-to-end, so STAGE 2's plate pad and STAGE 4's slot cut both use the chosen value with no other plumbing change. **Console (drilljig.cmd):** a `Read-Host` y/N + a validated entry loop right after the tree (the old `$SLOT_DEPTH_ABS` init in the depth-budget block was removed — it is resolved once, up front). **GUI (drilljig-gui.cmd):** a new **`slot-depth` step under the `Bushing` stage** (after `tree`, before `layout`) with "Standard clearance / Tight" choice cards + an inline depth field on Tight; the value is threaded through **`$ctx.SlotDepth`** (a context field — NOT the top-level `$SLOT_DEPTH_ABS`, which a step block cannot reliably mutate) and box-a's pad + the done-summary read `$c.SlotDepth`. **PAD/CUT INVARIANT (adversarial-review fix 2026-07-21):** box-a bakes the pad `$c.ReliefPad = $c.SlotDepth` into the SIDE offset plane ONCE (frozen at box-build), but the wizard's interwoven back-navigation lets the operator jump back to the `slot-depth` step and RE-EDIT `$c.SlotDepth` after the box is built — so **slot-a's cut reads the FROZEN `$c.ReliefPad`, NOT the live `$c.SlotDepth`** (`$slotDepth = if ($c.ReliefPad -gt 0) { $c.ReliefPad } else { $c.SlotDepth }`), making `plate(bushingLen+ReliefPad) − slot(ReliefPad) == bushingLen` hold by construction; and the `slot-depth` step shows a "plate already built — re-run to change" note once `$c.BoxBuilt`. The console is single-pass (pad + cut both read `$SLOT_DEPTH_ABS` in order) so it was never exposed. Both front-ends validate the typed depth with the shared PURE **`Resolve-SlotDepthInput`** (`lib\drilljig_core.ps1`: blank → default; non-numeric/≤0 → error; else round-4dp), unit-tested in `run_wizard_tests.ps1`. Not yet live-confirmed (behavioral); offline suites green.

**STAGE 2 base-plane capture — AUTO-DISCOVERED by NAME via the API, NO selection (added 2026-06-25; multi-select kept as fallback).** The three default datums are named literally `TOP`/`SIDE`/`FRONT` and are the SAME every part, so the program finds them itself — no user click. `Find-DefaultDatumPicks` enumerates `$model.ListItems(ITEM_FEATURE)`, reads each `GetName()`, and keeps the FIRST feature whose name resolves to each role (`Resolve-PlaneRole`: SIDE tested first, then TOP, then FRONT). Returns one `{Id; Name; Role}` per role (same shape as `Read-SelectionPlanePicks`), so the existing auto-map block consumes it identically and the box build runs hands-free. ID-and-name ONLY, never coords.
- **Three-tier capture:** (1) PREFERRED — `Find-DefaultDatumPicks` (API, no clicks); if it yields ≥3 distinct roles, map silently. (2) If not, ONE multi-select of all three datums (Ctrl-click any order, read by NAME via `Read-SelectionPlanePicks`). (3) LAST RESORT — per-plane sequential one-click capture. All three feed the same `$byRole` auto-map → conflict/missing-role still falls through, so an oddly-named part never wedges.
- **Why name, not geometry:** reading plane orientation is a dead end on this build — see [[project_plane_normal_null]] (`descriptor.Origin.GetZAxis()` returns null for PLANE descriptors); no solid exists yet at capture time to measure either. `GetName()` is the only viable signal (proven live — the user's own run showed `ListItems`/buffer names `TOP`/`SIDE`/`FRONT`). `first-feature-per-role wins` guards against a later same-named feature shadowing the real default datum (defaults are created first → enumerate first).

**STAGE 2 hands-free box build — SIDE drives the references (confirmed live 2026-06-22):** once SIDE is identified by name and the mapping is accepted (`$autoMapped`), the box build needs NO further plane clicks — it sketches on the SIDE og/default datum (`sidePlane.BaseId`) and extrudes UP TO the SIDE offset plane (`sidePlane.FeatId`). The manual click-each-plane prompts remain as the fallback path. The only manual step left is drawing the rough rectangle (real screen picks a `RunMacro` can't do).
- **Extrude-to plane fed by ID — `Get-SelectDatumByIdMacro` (the fix for the manual up-to click):** Macro B feeds the extrude depth "to selected" collector with the up-to plane BY ID via a **DATUM-typed** tree search (`SelOptionRadio`=`Datum` + `LookByOptionMenu`=`Feature`), mirroring **surfenator's** proven up-to-plane feed — NOT the Feature-typed `Get-SelectByIdMacro`. A Feature-typed selection is correct for CONSUMING a buffered ref (`ProCmdDatumPlane`) or showing/hiding a feature (so base-plane creation + the sketch-plane pick use it), but does NOT satisfy the depth collector's geometric-reference filter — symptom: the extrude dashboard sits open waiting for a manual plane click. The datum helper has NO leading `buffer_clean` (clearing mid-dashboard deactivates the open collector). **General rule: feeding an OPEN dashboard reference collector by ID needs surfenator's Datum pattern, not the generic Feature select.**

The whole STAGE 2 flow now runs without per-plane clicks beyond the one multi-select and the rectangle draw. STAGE 4's blind-relief widget names remain GUESSED (see `Build-ReliefHoleMacro` header) until a blind hole is recorded live.

**STAGE 2b — auto corner-round, hands-free, just before the drill confirm (2026-06-24, confirmed live).** Immediately before STAGE 3's "Proceed? (y/N)" drill confirm, drilljig auto-rounds the box corner edges via `lib\edge_round.ps1` `Invoke-AutoCornerRound -Session $session -Model $model -TypeObj $pfcType` (the edginator engine: sweep `GetItemById` → filter to the LOWEST edge length = the through-thickness verticals → `CreateModelItemSelection`+`AddSelection` → `ProCmdRound`; **NO find tool**). FULLY AUTOMATIC — no target/proceed prompt; only `--corner-radius N` (default 0.25) / `--no-corner-round` flags. The self-test gate + `VersionStamp` canary keep it safe (aborts WITHOUT mutating on a bad selection primitive or a no-change first round). Positioned after the STAGE-2.5 seed + STAGE-3 setup so it rounds the FINALIZED box (post-resize), then asks whether to drill — moved here from its first post-extrude position at the user's request.

**Point source — 3-WAY choice right after the decision tree (added 2026-06-25, user ask: "exercise hole creation through datums even for non-ortho; let the user add individual points + X/Z each; ask first whether points already exist"):** before any Creo work the operator picks how the target hole points are sourced — **(1) PREDEFINED** (datum points already in the part → STAGE 2.5 skipped, STAGE 3 hand-selects), **(2) ORTHOGRID** (regular Nx×Nz grid via `Show-OrthogridDialog`), or **(3) CUSTOM** (arbitrary per-point layout via `Show-CustomPointsDialog`). Both create-modes capture into the SAME `$orthoGeo` variable (`$pointMode` tracks which); cancelling a create dialog falls back to PREDEFINED. The shape-compatibility of the two geometry objects (below) is what lets STAGE 2/2.5/3/4 stay mode-agnostic — they gate on `$gridPointIDs.Count -gt 0` (points were created), not on which dialog made them.

**CUSTOM is INDEX-RELATIVE + auto-engages index-first (2026-07-21, user: "the index hole is based off the XZ corner, but then the rest of the holes are inputted and modeled based on the index hole"):** the Custom editor now takes the INDEX hole as an offset from the plate CORNER (its only corner-measured coord) + every OTHER hole as an offset FROM THE INDEX, via `Get-IndexRelativeCustomGeometry` (see the lib bullet). All entered holes drill (index + others); the corner is reference-only. Because the returned result carries `IndexRelative=$true` + `IndexGridX/IndexGridZ` with the index at `Points[0]`, drilljig.cmd AUTO-sets `$indexFirst=$true; $indexKey=0; $indexGridX/$indexGridZ` right after the custom capture and **SKIPS the interactive index-hole menu** (`$offerIndex = ($null -ne $orthoGeo) -and -not $indexFirst`); drilljig-gui.cmd does the same in `Add-InlineCustomPoints`' recompute and shows a FIXED "Index hole = Hole #1" confirmation (no picker) in the index-choice step. STAGE 1.9 (base csys AT the index) + STAGE 2.5 (`(grid−index)` plane offsets) then run UNCHANGED — the whole change is the INPUT model, not the pipeline. ORTHOGRID never sets `IndexRelative`, so its index-hole picker is intact.

**STAGE 2.5 datum-point creation — GUI-driven, serves orthogrid AND custom (2026-06-23, generalised 2026-06-25):** between the STAGE-2 box build and STAGE-3 drilling, drilljig creates the target datum points itself (instead of requiring them to pre-exist), from whichever layout the GUI captured. Three dot-sourced libs (after `creo_geometry`):
- **`lib\orthogrid.ps1`** — pure layout MATH. `Get-OrthogridGeometry` (CcX/CcZ/Nx/Nz/Edge → plate Width/Height, Count, Points[{I;J;X;Z}], `Valid`/`Errors`, `Mode`='orthogrid') AND `Get-CustomPointsGeometry` (arbitrary {X;Z} list → SHAPE-COMPATIBLE result, `Mode`='custom'). Custom mode has **NO edge margin** (offset-driven, meaningless — user 2026-06-25): plate is either **DERIVED** (`Width=maxX+ClearDia`, the default; `WidthMode`='derived') OR **EXPLICIT** (`-WidthOverride`/`-HeightOverride`, validated ≥ the farthest hole; `WidthMode`='explicit'). A point at the **origin (0,0) is DROPPED** by default (no hole at the part corner; `-KeepOrigin` to keep, `SkippedOrigin` reports the count). `WidthMode`/`HeightMode` are PER-AXIS (a width-only override leaves `HeightMode`='derived'). `Edge` member kept = 0 for shape-compat. Both never throw. Single source of truth; 156 offline cases.
- **`lib\orthogrid_gui.ps1`** — `Show-OrthogridDialog` (regular grid; live readout + aspect-correct dot preview) and `Show-CustomPointsDialog` (DataGridView X/Z editor + Add/Remove + a **"Size part from holes" / "Specify part size W×H"** radio pair — NO edge field; same readout + preview, origin-skip shown as a green note). Both previews draw a **`Draw-AxisGlyph`** X→/Z↑ indicator (bottom-left, matching the X/Z fields + the bottom-left origin; verified live + by a headless render assertion). Both CALL the matching `*Geometry` for ALL math, gate OK on `Valid`, return geometry on OK / `$null` on cancel, echo `Thickness`/`HoleDiameter`/`ReliefDiameter`. PS 5.1 console is STA by default so the hybrid header (no `-STA`) drives `ShowDialog` fine. (`DrawToBitmap` does capture the preview panel's GDI+ drawing — the axis glyph + dots show in a snapshot — but NOT native TextBox painting; blank-looking text boxes in a screenshot are a capture artifact.)
- **`lib\orthogrid_points.ps1`** — `Get-PointIdSet`/`Resolve-NewPointIds` (before/after ITEM_POINT set diff, **ID-only**, never `.Point`), `Build-IntersectPointMacro` (PROVEN 3-plane intersection), `Get-SharedPlanePlan` (**pure**: distinct X/Z offsets + per-point `{Xi;Zi}` indices — the plane-sharing plan for ANY point set, **orthogrid-equivalent** for a regular grid so the live-confirmed path is byte-identical), `Show-OrthogridTable` (mode-aware header), `Invoke-ManualPointGrid` (guaranteed fallback). `Build-PointGridMacro` [UNVERIFIED widgets] retained but unused.

Flow (revised 2026-06-23/24/25 per user): the **GUI fires right after the decision tree, BEFORE the Creo connection** (it's pure WinForms) — `Show-OrthogridDialog`/`Show-CustomPointsDialog -HoleDiameter $holeDia -ReliefDiameter .. -Thickness $bushingLen`, so the tree's hole Ø, relief Ø and drill depth show as **read-only context rows** (echoed back on the result). It only CAPTURES the spec into `$orthoGeo`; the datum points are CREATED later in STAGE 2.5, once the box + its TOP/SIDE/FRONT datums exist.

**Plate-driven box offsets (added 2026-06-24):** when `$orthoGeo` is present, STAGE 2's **TOP plane offset = plate Width** and **FRONT offset = plate Height** (the plate is sized to hold the grid, so the box face IS the plate). Mapping follows the grid contract — X/Width runs along TOP, Z/Height along FRONT, so TOP←Width / FRONT←Height. SIDE stays = bushing length; any plane left unset still prompts. (`$orthoGeo` is in scope here because the GUI ran pre-connect.)

**ALL POINTS via 3-plane intersections → drill ALL → relief ALL (confirmed live 2026-06-25; generalised to shared-plane plan 2026-06-25).** Every target point is built by creating offset planes and intersecting them into datum points — NO pattern, NO screen picks, fully automatic, for BOTH the orthogrid and custom layouts. **STAGE 2.5** asks `Get-SharedPlanePlan` for the distinct X offsets + distinct Z offsets across all points, creates **one X-offset plane per distinct X** (from TOP base) + **one Z-offset plane per distinct Z** (from FRONT base) — sharing a plane wherever points line up — then one intersection point per layout point (each = SIDE face plane + its X-plane + its Z-plane via `Build-IntersectPointMacro`, indexed by the plan's per-point `{Xi;Zi}`). A coord of ~0 **reuses the base datum directly** (point-probe's trick) rather than a degenerate plane, so a custom point typed at X=0/Z=0 lands on the TOP/FRONT base datum. For the orthogrid (Edge>0, no ~0 coords) this produces the IDENTICAL planes/intersections the original Nx/Nz derivation did (unit-tested "orthogrid equivalence"). All points → `$gridPointIDs`. **STAGE 3** drills an On-Point hole at EVERY point (the proven holeinator loop). **STAGE 4** cuts chip-relief SLOTS (see the "CHIP-RELIEF SLOTS replace relief holes + paths" note above — the old coaxial relief here was removed 2026-07-07). **STAGE 5** (new 2026-07-13) is the optional INDEX-HOLE csys (below). The POINT-grid Direction-pattern approach was abandoned (screen picks for direction references can't be automated; chaining two single-direction patterns made an "L"; mid-dashboard tree-searches clobbered value fields) — note this is the POINT-grid pattern; the SLOT pattern (one direction) is separate and works.

**STAGE 5 — INDEX-HOLE coordinate system (new 2026-07-13; the csysinator, integrated).** The user picks ONE drilled hole to be the INDEX hole (the origin of a datum coordinate system), and drilljig re-uses the SAME 3 planes it built that hole's point from. Every grid point was created as `intersect(SIDE-face, X-plane[from TOP], Z-plane[from FRONT])` (STAGE 2.5); the SAME 3 planes fed to `ProCmdDatumCsys` make a coordinate system at that intersection. **Registry:** `$csysRecords` (top-level `@()`, same PS 5.1 scalar-`+=` guard as `$gridPlaneIds`) collects one `@{ PointId; HoleFeatId; PlaneIds=@(Xplane,face,Zplane)=X/Y/Z-normal; GridX; GridZ }` per created point (the triple is REORDERED from the point-build order to X/Y/Z-normal for the csys). STAGE 2.5 fills `PointId`+`PlaneIds` by an **incremental per-point diff** (snapshot the point set BEFORE each `Build-IntersectPointMacro` fire, resolve the single new id AFTER — additive; the end-of-loop `Resolve-NewPointIds`/count check is unchanged); STAGE 3 ties each hole's feature id to its point (a `Get-FeatureIdSet` diff around each `Build-HoleMacro`, only when `$csysRecords` is non-empty). STAGE 5 reads what the user selected (`Read-IndexSelectionIds` → feature ids + point ids, id-only, never `.Point`), `Resolve-IndexHolePlanes` finds the matching record (hole-feat-id → point-id → point-as-feature precedence), and `Invoke-IndexCsys` fires `Build-CsysFromPlanesMacro` for the ordered triple, **canary-gated** on a new feature (never "done" on a no-op). **Order = X/Y/Z-normal** (the triple order the point was built with, which under the default-datum convention IS X/Y/Z-normal); plane normals read null so the axis assignment is a VISUAL check. PREDEFINED mode (no registry) degrades to a manual 3-plane pick. All the reusable pieces live in `lib\drilljig_core.ps1` (`Build-CsysFromPlanesMacro`/`Get-CsysShowMacro`/`Resolve-IndexHolePlanes`/`Read-IndexSelectionIds`/`Invoke-IndexCsys`), shared with the standalone csysinator.cmd + drilljig-gui's Index stage. Flag: `--no-index-csys`. Offline: `run_csys_tests.ps1` (58).

**The csys MACRO is CONFIRMED LIVE (2026-07-13); the registry is built WITHOUT touching hole creation.** First live run: the csys got made via the manual 3-plane pick (so the by-ID `ProCmdDatumCsys` feed works), but **clicking the hole "was not read"** because `$csysRecords` was empty. My first fix (per-point/per-hole COM-read polling INSIDE the creation loops) **broke hole creation** — reading `ListItems` between creation macros disrupts the very commits it polls for (the "flooding Creo with COM reads during the operation" antipattern). **HARD RULE (user 2026-07-13): do NOT change how points/holes are created.** Both creation loops are now byte-for-byte the originals — they fire ONLY the creation macros (`Build-IntersectPointMacro` / `Build-HoleMacro` -> `RunMacro`), NO COM reads between them. The index registry is pure **post-processing**: (1) after the STAGE-2.5 loop, zip the already-computed `Resolve-NewPointIds` (sorted ascending = Creo's datum-point creation order) with `$plan.Triples` (also creation order) into `PointId -> PlaneIds` records, only when the counts match exactly (else leave it empty); (2) the STAGE-3 hole->point tie is a SINGLE `Get-FeatureIdSet` diff taken ONCE before + ONCE after the drill loop (outside the loop body), creation-order-zipped onto `$pointIDs` only when the new-feature count equals the hole count (a hole that also adds an axis/note fails that check -> the tie is skipped and the user clicks the datum POINT, which resolves via the point registry). STAGE 5 keeps the hole click as the sole input (registry path); the manual 3-plane pick remains only for PREDEFINED mode. On a resolve miss STAGE 5 prints diagnostics (read ids + registry size). **Re-verify live** that hole creation is unaffected AND the hole/point click resolves.

**Plane ORDER = X/Y/Z-normal (fixed 2026-07-13).** The registry stores each triple as `[xPlane, face, zPlane]` (NOT `[face, ...]`): per the grid contract ("X = TOP-direction offset, Z = FRONT-direction offset") the X-offset plane's normal IS the model X axis, the Z-offset plane's is Z, and the SIDE face is the remaining Y-normal. Feeding `ProCmdDatumCsys` in X-normal -> Y-normal -> Z-normal order fixes the flipped-axis direction. Axis SIGNS still follow the csys orientation (plane normals read null -> visual check).

**STAGE 6 — export hole coordinates relative to the index csys (2026-07-13).** After STAGE 5 creates the csys, drilljig writes a CSV of EVERY hole's coordinate in the index csys frame to `<model>_holes_from_index_csys.csv` (next to the eval packets). **No COM coordinate read** (`IpfcPoint.Point` crashes): the coords are pure math from the grid layout — the csys origin IS the index hole, csys X ∥ grid X, csys Z ∥ grid Z, csys Y = through-thickness = 0 (all holes on the SIDE face), so a hole's csys coord is `(gridX - indexX, 0, gridZ - indexZ)`. The registry records carry `GridX`/`GridZ` (the design offsets) for this. Shared pure helpers in `lib\drilljig_core.ps1`: `Get-HolesRelativeToIndex` (records + index point id -> rows: X_index/Y_index/Z_index + GridX/GridZ + Diameter + IsIndexHole) and `Export-IndexHoleCsv` (build + write). Wired into drilljig.cmd STAGE 5's registry-success block and drilljig-gui.cmd's index-b (path shown in the Done summary). Only in the registry path (grid data present); the manual/predefined path has no grid coords so it is skipped. Offline: `run_csys_tests.ps1`. Axis SIGNS follow the csys — verify against the created csys.

**STAGE 7 — create datum points REFERENCED FROM the index csys (2026-07-13; WIDGETS UNVERIFIED).** After the STAGE-6 export, drilljig optionally creates a datum-point feature OFFSET FROM the index csys at the exported coordinates (Creo "Datum Point -> Offset Coordinate System", pick the csys, Cartesian, type the X/Y/Z table) so the points are parametrically tied to that csys. `Build-CsysOffsetPointsMacro` (`lib\drilljig_core.ps1`) selects the csys by ID, opens `ProCmdDatumPoint` in offset-csys mode, adds one table row per coordinate, OKs; `Invoke-CsysOffsetPoints` fires it as ONE atomic macro and **canary-gates** on a NEW datum point appearing (before/after `ITEM_POINT` diff — never "macro fired"). Wired into drilljig.cmd STAGE 7 (y/N after the export) + drilljig-gui.cmd index-b (`Show-WizardMessage` YesNo); `--no-csys-points` skips. **The offset-csys dialog widget names are a BEST GUESS** inherited from the abandoned `Build-PointGridMacro` (no recording exists — fact `datum-point-offset-from-csys-table`, docs-only): if the canary reports 0 points created, the offset-csys mode needs a live recording (record `Datum Point > Offset Coordinate System` with 2 rows, transcribe the real tokens into `Build-CsysOffsetPointsMacro`). Offline: `run_csys_tests.ps1` (82) locks the macro token structure so a recording replaces only the widget names.

**Orthogrid hole placement — `buffer_clean` + SIDE OFFSET plane + Datum-type pre-select (confirmed live 2026-06-25).** Intersection-of-3-planes points "hang in space" (not sketched on a surface), so `ProCmdHole` can't auto-infer placement. The fix: `Build-HoleMacro -SurfacePlaneId $surfId` pre-selects the **SIDE OFFSET plane** (`$sidePlane.FeatId` = the box face the points sit on) as a Datum-typed reference, then the point (accumulated, no `buffer_clean`), then fires `ProCmdHole`. The CRITICAL sequencing: `buffer_clean` FIRST (wipes stale refs from prior ops — without it, `ProCmdHole` sees garbage and defaults to "Linear" instead of "On Point + plane"), then `Get-SelectDatumByIdMacro` (surface), then Point tree search (no clear, accumulates). A `maindashInst0.Flip` after `ProCmdHole` corrects the drill direction. Same pattern in `Build-ReliefHoleMacro`. Using `FeatId` (the offset plane = actual box face) instead of `BaseId` (the og datum behind it) is what makes the surface reference match the point's geometric location.

**Plate size includes the hole diameter (2026-06-24).** `Get-OrthogridGeometry` gained `-ClearDia` (default 0, validated >=0): `Width=(Nx-1)*CcX+2*Edge+ClearDia`, Height likewise. **Points are at `Edge + i*CcX` / `Edge + j*CcZ`** (the user's entered spacing from the base datum, unshifted — ClearDia only widens the plate, does NOT move the points). The GUI's `Show-OrthogridDialog` gained `-ReliefDiameter` → a read-only "Chip-relief dia" row + the readout `Part W x H | N holes | hole .. | relief .. | depth ..`, and passes `ClearDia = holeDia` so Width/Height include the hole clearance at the border (the operator no longer hand-adds the hole dia). drilljig defines `RELIEF_DIA_MULT=1.5` ONCE before the GUI (STAGE 4 reuses it), computes `reliefDiaForGui = holeDia*mult`, passes `-ReliefDiameter`; STAGE 2 TOP<-Width / FRONT<-Height. (Readout is ASCII — a literal O-with-stroke mojibake'd under PS 5.1.)

**De-clunked auto-mapped plane flow (2026-06-24):** when the one-multi-select cleanly maps all three datums to TOP/SIDE/FRONT by name (`$autoMapped`), the **"Accept this mapping?" and "Build the box now?" prompts are gone** — it proceeds and builds hands-free. Both prompts (and one-click-per-plane capture) remain ONLY for the ambiguous fallback (name conflict / missing role / empty buffer); the auto-build still routes through the hands-free path that requires the SIDE base+feat ids, so a degenerate map can't build with missing refs.

**[SUPERSEDED 2026-07-07 — the relief HOLES described below were replaced by chip-relief SLOTS; the MATERIAL GATE itself is retained and now gates the slot stage.]** **STAGE 4 chip-relief gate — MATERIAL-DRIVEN (confirmed live 2026-06-23):** the relief-hole step is auto-confirmed for **3D-printed** parts and stays human-gated for **metal**. Right after the STAGE-1 walk, `$is3dPrint` is derived from the decision `$path` (`$path -match '(?i)3d\s*print'`) — the "3d print" string only ever enters `$path` via the root material option (the metal sub-answers are "PFD"/"Hand Drill"), so the match is unambiguous. STAGE 4 now has a **single** confirmation — the entry "Add chip-relief holes? (y/N)", gated on `$is3dPrint` (3D-print sets it `y` with no `Read-Host`; metal/any-unresolved path asks). The former inner "Proceed? (y/N)" (and its "Do not touch Creo while this runs" line + cancel branch) was **REMOVED 2026-06-24 (user)**: a yes to the entry prompt now drills the relief holes straight away. (STAGE 3's own through-hole "Proceed? (y/N)" is unchanged — that is the kept drill confirm, and STAGE 2b's corner round fires just before it.) The plate-thickness *data-entry* fallback (`Read-Host` at the relief-depth step) is deliberately left manual: it only fires when the live SIDE-plane offset can't be read, and it needs a number that can't be derived. The decision-tree JSON is unchanged — this lives entirely in the `drilljig.cmd` method, keyed off the existing Metal/3D-print material options.

**[REMOVED 2026-07-07 — STAGE 6 relief paths were deleted from both drilljig.cmd and drilljig-gui.cmd, replaced by the chip-relief SLOTS in STAGE 4. The paragraph below is retained as history / for the widget provenance it records.]** **STAGE 6 chip-relief PATHS — holes along a user-picked edge, drilled normal to it (added 2026-06-25; redesigned same day after a trail finding).** A chip-relief PATH is a line of through-holes running ALONG an edge of the part, drilled NORMAL to it (through the plate thickness) to clear chips/debris. Distinct from STAGE 4's *coaxial* relief holes (those sit on top of each grid hole); STAGE 6 makes a NEW row.

**THE TRAIL FINDING that drove the design (`trail.txt.12` ~L49273-49298, 2026-06-25):** the first STAGE-6 attempt fed the picked EDGE to the datum-point dialog (`Get-SelectEdgeByIdMacro` + `Build-EdgePlanePointMacro` = edge ∩ plane). Reading the trail proved this DEAD on the imported/foreign jig body: `ProCmdDatumPointGeneral` opened with an EMPTY reference table (`!%CPSelect up to 3 references...`) and was cancelled (`stdbtn_2`) EVERY time — selecting an edge BY ID does **not** load it as a datum-point reference here (the edginator find-tool-dead-for-edges wall). The WORKING grid points (same trail ~L835-857) loaded fine because they select **Feature-type datum PLANES**. Both `Build-EdgePlanePointMacro` and `Get-SelectEdgeByIdMacro` were REMOVED. (Lesson reinforced: mine `trail.txt.N` for what actually happened before iterating — see [[reference_mine_trail_files_for_widgets]].)

**The redesign — pick the FACE, not an edge (final, 2026-06-25); points are the PROVEN 3-plane intersection.** Earlier iterations picked an EDGE and inferred the axis from its `EvalLength`, but length is ambiguous — a perpendicular/thickness edge has a length that still matches Width or Height, so the path silently built on the WRONG line. The fix: the user clicks the **boundary FACE the holes drill into**; that one click gives BOTH the location (the boundary plane of the intersection) AND the drill direction (the face's normal), with no length guess and no near/far question. **Flow:** gated on `$gridPlaneIds` (STAGE-2.5 offset planes). (1) user CLICKS the boundary OFFSET plane → `Read-SelectedId` (the clicked plane's feature id). (2) match that id to the box's **OFFSET planes only** (`FeatId`, NOT `BaseId` — only the FRONT OFFSET or TOP OFFSET plane is accepted; user 2026-06-25): equals the TOP offset → boundary=Top, or the FRONT offset → boundary=Front. If NEITHER, warn + skip — no silent wrong build, and the base datums / SIDE plane / arbitrary faces are explicitly rejected. **CROSS-AXIS FLIP (the load-bearing geometry, root-caused from the trail 2026-06-25):** the boundary must be crossed with the pitch planes **PERPENDICULAR** to it, NOT the family parallel to it. Grid 'X' planes are offset from TOP (normal X, parallel-to-TOP); 'Z' planes offset from FRONT (normal Z, parallel-to-FRONT). So **TOP boundary → cross the Z-pitch planes; FRONT boundary → cross the X-pitch planes.** Crossing a boundary with its OWN (parallel) family gives two PARALLEL planes → no unique point → the datum dialog opens EMPTY and creates NOTHING (the live no-points bug: FRONT boundary 2 crossed with Z-pitch 3981, both constant-Z → Cancel). (3) one relief point per pitch plane = **SIDE OFFSET face ∩ boundary face ∩ perpendicular pitch plane** via the unchanged `Build-IntersectPointMacro` (all three Feature-type planes, now GUARANTEED mutually perpendicular: ⊥Y SIDE + ⊥Z-or-X boundary + ⊥X-or-Z pitch). The SIDE ref is `$sidePlane.FeatId` (the SIDE OFFSET plane = the actual box face the points sit on; loads fine as a point ref — the no-points failures were the parallel-pitch bug, not this ref), falling back to `$sidePlane.BaseId` only if missing. (4) drill a Thru-All hole, Ø = **HALF the part extrude** (live SIDE offset ÷2), at each point via `Build-HoleMacro` + On-Point with the **BOUNDARY face** as the placement surface (`-SurfacePlaneId $boundaryId`) — so each hole drills NORMAL TO THE FACE the user picked (the user's rule "the hole is directed the same direction the plane goes"). NOT the SIDE face — that drilled through the thickness (the wrong direction, an earlier 2026-06-25 bug). **Gates:** ZERO relief points created → ABORT + report (never silent "Done"); per-hole `VersionStamp` canary on hole #1. `$gridPlaneIds` captured at end of STAGE 2.5 as `{FeatId; Axis; Offset}` per offset plane (X=0/Z=0 base-datum reuses excluded). **`$gridPlaneIds` MUST be initialised to `@()` at top level** (alongside `$gridPointIDs`, OUTSIDE the `if ($null -ne $orthoGeo)` block): STAGE 6 reads `.Count` unconditionally, and the STAGE 2.5 `+=` loop hits the PS 5.1 trap where an un-initialised `$null += obj` makes a SCALAR `PSObject` (not a 1-element array) and the SECOND `+=` throws *"does not contain a method named 'op_Addition'"*. (`Resolve-EdgeAxis` in `lib\orthogrid.ps1` — the by-length classifier from the abandoned edge approach — is retained + still has 9 offline tests, but is no longer called by drilljig.) The relief points reuse the grid's already-proven `Build-IntersectPointMacro` (no new unverified macro).

### drilljig-gui.cmd
A **GUI front-end** for the whole drill-jig flow — a single never-closing WinForms WIZARD window
that drives the SAME end-to-end sequence as drilljig.cmd (decision tree → point source → box →
datum points → corner round → drill → chip-relief SLOTS → index csys) with **no console typing**. Additive: drilljig.cmd
is LEFT UNTOUCHED and still runs standalone; this is a second front-end over the shared engine. Open
the jig PART (not `.asm`). Built on `lib\wizard.ps1` (the framework) + `lib\drilljig_core.ps1` (the
proven Creo engine, called VERBATIM) + the EXISTING `lib\orthogrid_gui.ps1` editors. Breadcrumb stages:
`Bushing / Layout / Datums / Box / Drill / Relief / Index / Done`.

**INDEX-HOLE csys in the GUI (2026-07-13).** After the `Relief` stage, a new **`Index` stage** = two steps: **index-a** (a pick/verify step — the operator selects the hole in Creo, `Read-IndexSelectionIds` + `Resolve-IndexHolePlanes` resolve its 3-plane triple from `$ctx.CsysRecords`, Next gates on a resolved triple) and **index-b** (a RUN step — `Invoke-IndexCsys` fires the csys, canary-gated → `index: csys created` / `not created` chip). `$ctx.CsysRecords` is filled in the drill step's point loop (per-point plane triple, incremental diff) + hole loop (hole-feat-id tie). Self-skips when there is no registry (predefined points) or `--no-index-csys`. Same shared engine as drilljig STAGE 5 / csysinator.cmd.

**CHIP-RELIEF SLOTS in the GUI (2026-07-07; CONFIRMED LIVE 2026-07-08).** The old relief-hole block (inside the drill RUN step) and the entire relief-PATHS wizard step were REMOVED; a new **`Relief` stage** = two steps mirroring box-a/box-b: **slot-a** (create the slot-edge guide planes via `New-SlotGuidePlanes`, then arm the seed sketch on the SIDE face; material gate — 3DP auto / metal asks via `Show-WizardMessage`; skips if no `$c.OrthoGeo` layout) and **slot-b** (finish the seed cut via `Build-CutFinishMacro`, verify direction with a Yes/No — wrong → `ProCmdEditUndo` + flip + re-arm the sketcher + stay so the operator redraws; right → operator selects the seed in the tree, then `Build-SlotPatternMacro` patterns it hands-free). Reuses ONLY stored context (`$c.HoleDiaFinal`, live SIDE offset, `$c.OrthoGeo`, `$c.Made/$c.SidePlane`, `$c.BodyIndex`) — no re-entry. Honesty chip `slots: built | unverified | aborted | skipped`.

**Design (from a fan-out + judge workflow, 2026-06-25):** three GUI paradigms were scored
(mission-control dashboard / linear wizard / spec-sheet card); the **Guided Build wizard won** because
its arm/pause/resume is a 1:1 mechanical match for drilljig.cmd's proven `Read-Host "...then ENTER"`
boundary — and it leaves all the geometry INVARIANTS untouched (the GUI only reframes WHEN the user is
asked; it never adds a COM read or changes a macro). Grafted in: the spec-sheet's honesty **status
chips** and (later milestones) the orthogrid dot-preview. The risky mission-control idea (a worker
thread for live responsiveness during a long mapkey) is DEFERRED behind the proven synchronous path.

**The constraint that shapes it:** drilljig has unavoidable live-Creo **mouse picks** (multi-select the
3 datums, draw the rough rectangle, hand-pick predefined points) that a `RunMacro` can NEVER replay, so
the GUI cannot replace the Creo window — it **arms** a pick (one imperative sentence, Next DISABLED),
**pauses** on a big "I clicked it — verify" button (no blocking Read-Host), then on click **reads the
selection buffer on the same STA thread** and only enables Next when it validates (`Read-SelectionPlanePicks`
GetName() role-map for datums; `Resolve-SelectedPointIds` ID-only for points — never `IpfcPoint.Point`).
A wrong/empty pick structurally cannot advance. The rectangle-draw maps to the split-macro reality:
Macro A arms the sketcher, a modal waits for the draw, Macro B finishes + extrudes.

**Steps (breadcrumb stages Bushing/Layout/Datums/Box/Drill/Done):** (1) the decision tree descends
card-by-card in ONE step that re-renders in place (`$wiz.Rerender()`), resolving the hole OD via the
catalog cards (OD→length→ID, machinist fractions) or a fixed-OD leaf; (2) point-source tiles
(predefined / orthogrid / custom) — orthogrid/custom open the EXISTING modal editors and capture
`$orthoGeo`; (3) datum capture (API auto-map by name first, else the multi-select arm/verify); (4) box
build as a RUN step (planes + the one rectangle draw + extrude → `box: built` chip on a `VersionStamp`
change, MarkCommitted so Back is locked); (5) optional predefined-point pick, then the RUN step that
creates STAGE-2.5 intersection points + STAGE-2b corner round + STAGE-3 drill + STAGE-4 relief, each
honestly chipped (built only on a real `VersionStamp` change, never "macro fired"); (6) summary.
**(Blind evaluator REMOVED 2026-07-21, user: it added confusing noise — the box-build eval report
spammed a false "expected N vs measured N.99" mismatch because the entered offsets aren't the solid's
sorted extents. `lib\blind_evaluator.ps1` is UNTOUCHED and still used by plane-probe.cmd / drilljig3d.cmd
/ the response-convergence harness — only the two drill-jig front-ends stopped calling it.)**

**Honesty + safety carried from the console tool:** the box build reports `box: built` on a real
`VersionStamp` change (verify dimensions visually in Creo). The `VersionStamp` canary aborts hole #1
if nothing changed (→ red chip). `MarkCommitted()` disables Back
into any step whose Creo geometry already exists. The RUN view's busy guard disables all input so a
stray click can't re-enter the non-reentrant session; `Application::DoEvents()` repaints only BETWEEN
atomic batches (a single multi-second mapkey still briefly blocks paint — honest marquee + copy).

**Milestone 1 status (offline-verified; two live GUI-plumbing bugs found + fixed 2026-06-26; not yet
RE-run live):** wizard framework, shared engine, and shell all built; `run_wizard_tests.ps1` (84 cases,
incl. an integration test that FIRES the tree OnPick callbacks) + headless instantiate/render + a
net-smoke (a throwing Build no longer crashes the form) pass; all four suites green (344 total).
**Two live bugs, both GUI plumbing (NOT geometry):** (1) a FREEZE — an unowned `[MessageBox]::Show`
shown while the user was in Creo got drawn BEHIND the Creo window; modal, so the wizard hung on a
dialog you couldn't see. Fix: `Show-WizardMessage` (owns the box with a tiny invisible TopMost form, so
it's always in front) + the box build SPLIT into box-a (create planes + open sketcher, stop) and box-b
(finish + extrude) so the rectangle draw is a non-blocking wizard PAUSE, not a modal. (2) a CRASH —
"Cannot index into a null array" → the .NET JIT dialog on a card click, because an OnPick scriptblock
referenced a **Build-LOCAL** variable (`$grouped`/`$panel`); a plain `{..}` handed to a later event does
NOT capture Build locals (only `.GetNewClosure()` would), so it was `$null` at click time. Fix: stash
what OnPick needs in the PERSISTENT context (`$c.Grouped`/`$c.LayoutPicked`); a wizard callback reads
ONLY its params + the shared context. Plus a GLOBAL SAFETY NET in wizard.ps1 (WinForms
`add_ThreadException` + `$wzLogError` + `$InvokeGuarded` wrapping render/click, EAP forced Continue) so
under `$ErrorActionPreference='Stop'` a handler error logs to `%TEMP%\drilljig-gui-error.log` + shows a
topmost dialog (or, for a render error, just the inline label) instead of crashing the message loop.
The render-only smoke MISSED bug 2, hence the OnPick-firing integration test. (3) the ACTUAL freeze
root cause, found from the on-disk error log 2026-06-26: the wizard state + logger were `$script:`-scoped
(`$script:wz`, `$script:wzLogError`), but **a `$script:` variable set in `Show-Wizard` is INVISIBLE inside
a `.GetNewClosure()` block** — it resolves to the closure's own empty module scope and reads `$null`. So
`$wz.Steps[$wz.Index]` and `$wiz.Refresh()` threw "Cannot index into a null array" on EVERY click, the
buttons never gated, and nothing responded (the safety net caught it but the UI was dead). **Fix: make
them LOCAL variables** — `.GetNewClosure()` captures a local by reference AND sees its live mutations (a
proven repro: a `$script:` ref in a GetNewClosure throws, a local ref reads the post-creation value). The
bug class — verified by a DRIVE test that clicks Next through a live wizard via `PerformClick` and asserts
Next stays enabled + advances + logs nothing (the test whose absence let the false-green through; the
net-smoke only checked "form survived", not that `Refresh()` worked). The Creo-facing code is
byte-for-byte the proven drilljig.cmd recipes (re-used via the lib), so the live risk is concentrated in
the GUI plumbing, not the geometry.

**UX pass after the first mostly-working live run (2026-06-26):** (a) **dark-blue theme + white text** —
a palette published to `$script:WizTheme` (FormBack RGB 20,30,52; near-white ink; bright-blue accent;
brightened chip/ok/warn/err for contrast) that the breadcrumb, chips, buttons, run-log, choice cards, and
the drilljig-gui helpers (`Get-UiColor`) all read. (b) **clipping fix** — the body panel is `AutoScroll`
(a step taller than the canvas scrolls instead of cutting off its lower controls) and `Add-Para` clamps
width + wraps. (c) **bushing picker confirm, not cycle** — once `TreeDone`, the tree step shows a
"Bushing selected: …" confirmation with a **Change selection** button (resets the cursor) instead of
re-rendering the OD cards endlessly. (d) **orthogrid editor EMBEDDED in-window** (no popup) —
`Add-InlineOrthogrid` builds the fields + live dot-preview into the layout canvas, reusing the pure
`Get-OrthogridGeometry` + `Draw-AxisGlyph`; fields persist in `$ctx.OrthoFields` (NOT a Build-local — the
captured-variable rule) and gate Next via `$ctx.OrthoValid`. The live-verified `Show-OrthogridDialog`
modal is **untouched** (still used by the standalone tools + the custom-points path). (e) **slowness** —
`Wait-ModelModified` was a tight CPU-spin for the whole op (also starved the UI thread); it now sleeps
40ms/poll and takes an `-OnPoll` callback (the GUI passes `{ DoEvents }` so the window repaints during
per-hole waits). The Creo macro/regen waits themselves are inherent. All verified by the WinForms
render/drive suite (`run_wizard_tests.ps1` now 94 cases).

**Remaining milestones** (every one independently usable): M4 spatial progress (preview dots fill as
points/holes are made) + committed-step guarding polish; embed the custom-points editor inline too
(orthogrid is done); M5 (optional, highest risk) the background STA worker thread for live responsiveness
during a long batch. Flags mirror drilljig.cmd: `--no-corner-round`, `--corner-radius N`.

### drilljig3d.cmd
Builds a **conformal 3D drill-jig blank** from a single clicked surface — the curved-surface analog of drilljig's flat plate. You enter a THICKNESS, click the SURFACE to follow, and the tool creates an **offset-surface feature at offset 0** (a coincident quilt copy of the face) then **thickens that quilt into a NEW solid body** of the entered thickness (STAGE 1). **STAGE 2 (optional)** then drills On-Point holes into that new body in the SAME session. Standalone; does NOT touch drilljig.cmd. Open the jig PART (not `.asm`). **STAGE 1 + STAGE 2 confirmed working live 2026-06-24** — offset+thicken (flipped away from the part), and On-Point holes normal to the surface.

Built from the user's recorded offset+thicken mapkey (`ProCmdFtOffset` → `mru_option_menu`/`ExclSrfColl` options → `dashInst0.Done` → `ProCmdFtThicken` → `dashInst0.Done`), with two deliberate departures, both proven elsewhere:
- **No screen pick.** The recording pauses for a manual surface click into the offset collector; a `RunMacro` can't pause. Instead the user pre-selects the surface, `Resolve-SelectedSurfaces` reads its ID (**ID-ONLY** — `.Id`/`.Type`=`ITEM_SURFACE`, never a coordinate, holeinator's lesson), and `Get-SelectSurfacesByIdMacro` re-selects it BY ID, so the whole offset+thicken fires as ONE atomic `RunMacro`. **CONFIRMED LIVE: `ProCmdFtOffset` consumes the pre-selected surface from the buffer** — the same pre-select-then-command pattern proven for `ProCmdFtExtrude` (surfenator) and `ProCmdDatumPlane` (plane-probe). This was the one live-unknown; it held, so no split-around-pick was needed. **LIVE FALLBACK** (documented in `Get-OffsetThickenMacro`) if a future build's offset opens empty: open `ProCmdFtOffset` first, then feed `PH.SrfCollTbl` by ID with `-NoClear` (surfenator's open-collector feed).
- **Regenerative dimensioning for the values.** The recorded mapkey sets neither offset nor thickness (takes dashboard defaults). The tool instead creates both features, finds each new feature by before/after feature-ID diff (`Get-NewFeatureLinearDims`, `Sort-Object Id` ascending = creation order), reads its linear dim via `feature.ListSubItems(ITEM_DIMENSION)` (gauginator's walk), writes `DimValue` (offset → 0, thickness → entered value) via `Set-DimAndConfirm`, `Invoke-ForceRegen`, and RE-READS to confirm. Both are FEATURE-level dims so the write holds on a closed feature (boxinator's extrude-depth path; sketch dims would snap back — [[project_sketch_dim_snapback]]).

**Two new features disambiguated by CREATION ORDER** — lower new feature ID = the offset (driven to 0), higher = the thicken (driven to the entered thickness) — so the right dim is driven without reading `EpfcFeatureType` enum ints (unconfirmed on this build — drilljig lesson). A swapped mapping would try thickness = 0, which fails loudly rather than silently. The console prints the mapping (`Offset feat N … / Thicken feat N …`) for an eyeball check.

**Thicken outputs a NEW body, grown AWAY from the part** — `Get-OffsetThickenMacro` fires thickenator's confirmed-working body-page widgets (`chkbn.body_page.0` then `body_page.0.0` `PH.bodyusechkbtnrepwdg`) right before `dashInst0.Done`, so the conformal blank is its own solid instead of merging into the body the offset surface came from. A single `maindashInst0.Flip` (thickenator's confirmed flip widget) makes the material grow AWAY from the part — the opposite side of the coincident offset surface — **confirmed needed live 2026-06-24** (the default thickened toward the part). ONE Activate = one flip off the default; it's the knob if a future part defaults the other way. Thickness is still driven by regen dimensioning afterward, so `maindashInst0.Thickness` is deliberately NOT set in the dashboard.

**Atomic macro (boxinator lesson):** the offset+thicken is ONE `RunMacro` because the thicken relies on the fresh offset quilt being active and a dashboard's command context doesn't survive across `RunMacro` calls. The recording's pre-pick `FocusOut references.1.0 PH.SrfCollTbl` line is omitted (it readied the EMPTY collector for a manual pick).

**Honesty (same bar as the other tools):** verification is a `VersionStamp` change — a canary that ABORTs and does NOT drive any dim blind if the macro was a no-op (never assumes-on-failure, [[feedback_canary_must_not_assume_on_failure]]). "Done" means each driven dim RE-READ at its target, NOT a geometric measurement (the slab is curved, so a bounding-box extent ≠ thickness — boxinator's `EvalOutline` proof does not apply). Verify the conformal blank visually before drilling. Multi-surface picks (Ctrl-click several faces of one quilt) feed one offset via the accumulate select-by-ID. `-v` for verbose feature/dim diagnostics.

**STAGE 2 — drill On-Point holes NORMAL to the surface (confirmed live 2026-06-24):** after the blank is built, drilljig3d offers to drill On-Point holes into it, reusing **holeinator's confirmed-live hole dashboard tail VERBATIM** (`ProCmdHole` → `StrHoleDepThruAllF` thru-all → `chkbn.body_page.0` + `body_page.1.0 PH.bodyselectrepwdg_list` → `diameter_mip_OptionMenu` → `Done`). The new blank BODY is auto-targeted by a before/after `ITEM_BODY` diff (`Get-BodyIdSet`; index in `ListItems(ITEM_BODY)` == the dashboard body-selector index — holeinator's assumption), falling back to a body-pick prompt if it can't be identified. Hole points are datum points the user selects, resolved **ID-only** (`Resolve-SelectedPoints` = holeinator's `ListSubItems(ITEM_POINT)` resolve, never `.Point`). Per-hole `VersionStamp` canary aborts after hole #1 if nothing changed.
- **Orientation = normal-to-surface, via SURFACE PRE-SELECT (CONFIRMED LIVE 2026-06-24).** `Build-NormalHoleMacro` selects the datum point BY ID (placement) THEN the STAGE-1 surface BY ID with `-NoClear` (a second buffered ref) before `ProCmdHole`. **CONFIRMED: the On-Point hole uses the buffered surface as its normal-direction reference** — so pre-selecting point + surface (no guessed dashboard widget) is enough to orient each hole normal to the face. This deliberately uses ONLY proven select-by-ID machinery, so even had it not oriented, the worst case was Creo's DEFAULT direction, never a broken macro. **`-defaultorient`** drops the surface pre-select = holeinator's exact point-only macro (kept as a fallback). The canary gates CREATION; orientation was confirmed by visual check on the live run.
  - **Per-hole orientation surface (added 2026-06-24):** STAGE 2 builds a `(PointId, SurfaceId)` pair list — **mode 1** (default) pairs all selected points with the one STAGE-1 surface (byte-for-byte the previous behavior); **mode 2** (curved/multi-face) loops, pairing each point with the surface it sits on (Ctrl-click point+surface, ENTER per hole; empty ENTER finishes). `Build-NormalHoleMacro` was already `-SurfaceId` per call, so the drill loop just iterates the pairs — each bore orients to its OWN face. Both modes ID-ONLY (the existing `Resolve-SelectedPoints`/`Resolve-SelectedSurfaces` buffer walks; no coordinate read). This closes the "v1 uses the first surface for every hole" gap that defeated conformality the moment holes spanned curvature.

**STAGE 1 inputs added 2026-06-24 (quick wins, default = unchanged behavior):** (1) a **standoff / chip-clearance offset** — the offset dim is no longer hard-driven to 0; it's a prompt defaulting to 0 (flush, as before), and >0 floats the jig off the part (reuses `Set-DimAndConfirm` on the offset dim). (2) **jiginator handoff pre-fill** — drilljig3d now reads `last_jig_spec.json` (the same file holeinator consumes) and pre-fills the STAGE-2 hole/seat diameter from `HoleDiameter` (= bushing OD; ENTER accepts), plus a forward-compatible `BushingLength`→thickness pre-fill. (3) **thickness guidance** — when the hole dia is known, STAGE 1 prints the recommended wall band (~1–2× dia) + bushing seating length (~1.5× dia) and soft-warns a too-thin wall (advisory, non-blocking). **Full improvement roadmap is in `docs\drilljig3d_improvements.md`** (done since: per-hole orientation surface, hole-count blind-evaluator gate; remaining: `--probe-orient` + the hole-axis-vs-normal gate, counterbore bushing seats, 3-2-1 locating, auto-grid).

**STAGE 2 hole-count + diameter blind-evaluator gate (added 2026-06-24):** STAGE 2 no longer reports "macros fired" as success — `Invoke-JigEval` measures the model independently and gates on it. It counts cylindrical surfaces AT the target radius (`Count-Cylinders -TargetRadius (holeDia/2)`) **before and after** drilling; the DELTA must equal the intended hole count (`Test-ExtentsMatch`, Tol 0.5). Counting *at the radius* checks COUNT and DIAMETER together (a wrong-diameter bore isn't counted at the target radius), and the before/after delta is robust to pre-existing same-radius cylinders. drilljig3d now dot-sources `lib\blind_evaluator.ps1` and resolves `Get-JudgeConfig` once; the deterministic delta is the gate, the LLM judge is advisory, and the `<model>_eval.json` packet is written either way. A 0-surface walk (foreign-body / dead `ListSurfaces`) returns `$null` = **UNVERIFIED (yellow), never a false green** — falling back to the per-fire VersionStamp signal, honestly labelled. Modeled verbatim on plane-probe's `Invoke-BoxEval`. (Hole-axis-vs-surface-normal — the orientation gate — still needs the `Eval3DData` probe; orientation stays a visual check for now.)

### pocketinator.cmd
Cuts ONE connected chip-clearance pocket by OFFSETTING the plate's existing outer boundary inward (a sketch Offset > Loop), extruded as a shallow blind REMOVE-MATERIAL cut. "All the area enclosed by the holes is chip clearance." Standalone; does NOT touch drilljig.cmd. **The CUT half is fully proven/mined**: `Build-CutFinishMacro` fires `ProCmdSketDone` → typed depth (`GrmTextTagEmbedMRU` + `Enter`/`Exit dashInst0.Quit` blur) → **`maindashInst0.remove_material_cb 1`** (the Remove-Material toggle, mined live from `trail.txt.8:1799`) → body (`chkbn.body_page.0` + `body_page.1.0 PH.bodyselectrepwdg_list`) → `dashInst0.Done`, as ONE atomic `RunMacro`. The OFFSET half is NOT recorded anywhere (no `ProCmdSketOffset` in any trail; the VB API has no programmatic sketch-offset), so the tool opens the internal sketcher and PAUSES while the operator runs Sketch > Offset > Loop by hand (like boxinator pauses for the rough-rectangle draw). Depth = % of plate thickness (default 20%, `Measure-Extents` on the up axis). Honesty = `VersionStamp` canary (the cut mutated the model), not a geometric measure of the inset.

### rectpocketinator.cmd
**The user's "chip relief + chip removal path is actually just one" idea (2026-07-01):** cuts ONE **subset-rectangle** chip-relief pocket sized to the hole cluster — the bounding box of the drilled holes + a margin — extruded DOWN into the plate as a REMOVE-MATERIAL cut. One connected relief region over every hole, replacing N coaxial relief holes (drilljig STAGE 4) / relief paths (STAGE 6). Standalone; does NOT touch drilljig.cmd or pocketinator.cmd. **CONFIRMED-LIVE cut machinery, GUIDED-DRAW rectangle, NOT yet run live end-to-end.**

**vs pocketinator:** pocketinator insets the plate's ENTIRE outer boundary (relief spans the whole plate). rectpocketinator cuts only the RECTANGLE hugging the holes, leaving a full-thickness plate border around the hole field. Both share the identical proven cut half (`Build-CutFinishMacro`, copied verbatim-with-provenance including the `remove_material_cb` toggle).

**How it learns the hole region — NO coordinate read (dodges the `IpfcPoint.Point` crash, holeinator lesson):** the operator RE-ENTERS the same layout in the grid GUI (`Show-OrthogridDialog` / `Show-CustomPointsDialog` — the exact editor used to place the holes), and the pocket rectangle is **pure math** on those `{X;Z}` offsets via **`Get-HoleBoundingRect`** (in `lib\orthogrid.ps1`): bounding box of the hole CENTERS expanded by `Margin` on all sides, near edges clamped to ≥0, fit-checked against the plate `Width`/`Height`, with a non-fatal advisory when `Margin < HoleDia/2` (the wall crosses the outer bores). Same plate-corner frame as the grid (X right / TOP, Z up / FRONT). NEVER throws; 38 offline tests in `run_orthogrid_tests.ps1` (orthogrid + custom sources, near-edge clamp, fit check, bore advisory, single-point, malformed).

**Flow:** STEP A re-enter layout (GUI, pre-connect) → STEP B margin + depth% + up-axis → connect + `.asm` guard → `Measure-Extents` thickness → `Get-HoleBoundingRect` (prints exact pocket W×H, corners, center) → STEP 1 pick face by ID → STEP 2 body → confirm → **Macro A** (select face by ID → `ProCmdFtExtrude` → `ProCmdViewSketchView` → `ProCmdSketRectangle 1` arm corner-rect) → **pause** while operator draws ONE rectangle enclosing the visible holes (a `RunMacro` can't draw geometry — the one manual step, guided by the printed target size) → **Macro B** (`Build-CutFinishMacro`: finish sketch → depth → `remove_material_cb` → body → Done, one atomic `RunMacro`). `VersionStamp` canary gates "Done"; verification is the model changed, NOT a geometric measure of the pocket.

**v2 (deferred):** drive the drawn rectangle to EXACT dims. The sketch-dim route (`mod_dim_emb`) snaps back on regen ([[project_sketch_dim_snapback]]); the robust exact path is feature-level offset planes (like drilljig's plate), which needs sketch-reference-snap widgets not yet recorded.

### slotinator.cmd
**The user's next chip-relief refinement (2026-07-06):** replace the round relief with a RECTANGULAR extrude cutout **per hole ROW**, auto-looped. For every row of holes cut ONE blind slot: **length = the full part length** along the row, **width = the ORIGINAL drilled hole diameter** (NOT the 1.5× relief mult), **depth = a % of plate thickness (default 20%)**, blind Remove-Material. Creates the slot-edge offset PLANES and MAKES THEM VISIBLE as draw guides, opens the SIDE-face sketch, arms `ProCmdSketRectangle 1`, operator draws, then auto-finishes + Remove-Material extrudes. Standalone; does NOT touch drilljig/pocketinator/rectpocketinator.

**Cut = `Build-CutFinishMacro`, spine from the operator's recording `trail.txt.32:4398-4412`** (a full drilljig session ending in the slot cut), with three fixes hammered out live over the session:
- `ProCmdSketDone` → **`maindashInst0.flip_pb`** (direction flip — the default cut went the WRONG way into the plate; `--no-flip` skips it) → **type blind depth into `maindashInst0.def_depth1_ip`** (Input/Update/Activate/FocusOut, the recorded extrude depth field `trail.txt.27:3973` — NOT boxinator's `GrmTextTagEmbedMRU`, which is wrong on this build; the field is directly editable on a Blind-default extrude, no `depth_flyout` needed) → `Enter`/`Exit dashInst0.Quit` (blur) → **`maindashInst0.remove_material_cb 1`** → body (`body_page.1.0 PH.bodyselectrepwdg_list`) → `dashInst0.Done`, ONE atomic RunMacro.
- Depth = `DepthPct` × plate thickness (`Measure-Extents` on the up axis; manual-thickness fallback). `Build-CutFinishMacro` only types the depth when >0, else falls back to Creo's default depth (never a bogus 0). **CAVEAT: `def_depth1_ip` is proven on protrusion extrudes but never recorded together with `remove_material_cb`** — a live run must confirm it drives a CUT's depth.

**Reuse + guide PLANES (no points — user 2026-07-06 "the points are useless, only create the planes and make them visible"):** DOT-SOURCE `lib\drilljig_core.ps1` (New-OffsetPlane, Find-DefaultDatumPicks, Read-SelectionPlanePicks, Get-SelectByIdMacro, Wait-ModelModified, Read-SelectedId, Get-BodyList) + `Initialize-DrilljigCore`; only `Build-CutFinishMacro` is a local copy. Datum discovery finds TOP/FRONT (by name, else one multi-select); `Get-RowSlots.Corners` → `Get-SharedPlanePlan` gives the distinct slot-edge X/Z offsets → one `New-OffsetPlane` per distinct edge (a ~0 offset reuses the base datum), then **each new plane is SHOWN via select-by-ID + `ProCmdViewShow@PopupMenuTree`** (proven: plane-probe + `trail.txt.32:227-255`). **The old 2-diagonal-corner datum POINTS were REMOVED** — they only landed on the sketch plane when the picked face was coincident with the SIDE datum (usually not), so they were useless; the visible edge planes are the guides now. Planes are OPTIONAL (degrade to freehand from the printed corners if TOP/FRONT don't resolve); row-1 cut is the abort canary. Row math = pure `Get-RowSlots` (lib\orthogrid.ps1, never-throws, ~44 offline tests): groups the re-entered GUI points into rows by cross-coord on a **PHYSICAL RowTol = max(SlotWidth/4, 0.01), NEVER 1e-6** (1e-6 is a float-equality guard that silently fragments a near-but-not-equal custom row into N full-width slots — a silent over-cut the VersionStamp bar can't catch). **Offline-verified (249 tests, parses clean), NOT yet fully confirmed live** (flip + depth + planes-visible are the open live checks).

**MULTI-SLOT via pattern — CONFIRMED LIVE 2026-07-07 (single-direction seed+pattern).** The user wants "draw 1 seed slot, then pattern it for the rest." An EXHAUSTIVE VB-docs sweep (2026-07-06 workflow) confirmed **NO programmatic pattern/copy API**: `IpfcFeaturePattern` read/delete-only, `IpfcCopyInstructions` = *"reserved for the future"*, no feature-mirror/move-copy, `IpfcSolid.CreateFeature` = *"not implemented"* (UDF placement is the only programmatic create route, needs a pre-authored `.gph`). The **DIMENSION** pattern (`ProCmdPattern`/`ui_pat_dim_*`) recorded once (`trail.txt.27`) but CANCELLED before its count/increment widgets — unusable. The **DIRECTION** pattern (`ProCmdGeomPattern` + `ui_pat_dir_dir1`/`ui_pat_dir_1_num_inst`/`ui_pat_dir_1_incr` + `dashInst0.stdbtn_1`, in `lib\orthogrid_points.ps1` `Build-PatternArm/Values/ConfirmMacro`) — widgets CONFIRMED against the user's full 2026-07-07 mapkey. So when `Get-SlotPatternPlan.CanPattern` (rows evenly spaced) and not `--no-pattern`, slotinator: (1) runs the VERIFIED seed cut on row 1 (`Invoke-VerifiedSeedCut` — open+draw+cut, then the operator confirms direction/depth; wrong → undo+flip+redraw once; the confirmed flip is reused), (2) **has the operator SELECT the seed slot in the model tree** and reads it via `Read-SelectedId` (a search-buffer select does NOT register as the pattern target — FIX 1 below), (3) fires the WHOLE pattern as ONE atomic macro (no direction pick — FIX 2): open pattern on the selected seed → activate `ui_pat_dir_dir1` → **feed the direction datum plane BY ID** (`Get-SelectDatumByIdMacro`) → count (`.Count`) → spacing (`.Increment`, optional `-Flip1` via `--pattern-flip`) → confirm, (4) `VersionStamp` canary; seed survives + `--no-pattern` per-row fallback on any miss. **`Get-SlotPatternPlan` (lib\orthogrid.ps1, pure, 17 tests)** gates it (single-increment pattern fits ONLY evenly-spaced rows; irregular → per-row).
- **FIX 1 (user 2026-07-07, gave the full working mapkey) — the seed must be SELECTED as the pattern target BEFORE `ProCmdGeomPattern`.** The recording clicks it in the model tree (`~ Select main_dlg_cur PHTLeft.AssyTree 1 <node>`); a **search-dialog buffer select does NOT register as the pattern target** on this build (works for round/copy/datum-consume, NOT for pattern). So `Build-PatternArmMacro` NO LONGER search-selects (`-FeatId` now optional, default 0); slotinator has the operator click the seed once, then arms on the live selection. Removed the too-strict "couldn't auto-identify seed feat id → can't pattern" guard. **CONFIRMED LIVE (trail.txt.33): the manual tree-select + `ProCmdGeomPattern` opens the pattern on the seed** (my FIX 1 worked).
- **FIX 2 (root-caused from trail.txt.33) — the DIRECTION reference is now a base DATUM PLANE fed BY ID, not an operator edge-pick.** The live failure: after the pattern opened, the operator picked a **curved EDGE** (id 1765) for the first direction; Creo **rejected** it (prompt *"Define the first direction. Select a Plane, Flat Face, Linear Curve, Csys Axis, or axis"* kept repeating) and the pattern was **cancelled** (`dashInst0.stdbtn_2` → "Do you really want to Cancel? yes"). A datum PLANE is ALWAYS a valid direction reference (its normal IS the direction), and slotinator already knows the base datum ids — so it now feeds the right one BY ID into the `ui_pat_dir_dir1` collector via **`Get-SelectDatumByIdMacro`** (surfenator's proven open-collector feed), **no pick**. Copies march along the datum normal: **CrossAxis Z (rows along X) → FRONT datum; CrossAxis X (rows along Z) → TOP datum.** The whole pattern is now ONE atomic macro after the seed-select (open pattern → activate collector → feed datum by ID → count `ui_pat_dir_1_num_inst` → spacing `ui_pat_dir_1_incr` → confirm `stdbtn_1`), with an optional `--pattern-flip` (`ui_pat_dir_1_flip`) if the copies march off the plate. Widgets CONFIRMED against the 2026-07-07 mapkey (single-direction; the recording's dir-2 block omitted). **CONFIRMED LIVE 2026-07-07: the datum-by-ID direction feed registers in `ui_pat_dir_dir1` and the pattern fires end-to-end** (the operator confirmed "works now"). Canary-gated (VersionStamp); on no-change the report says to pick the FRONT/TOP datum PLANE by hand.
- **FIX 3 (speedup, user 2026-07-07 "don't create unnecessary planes — just the first set") — pattern-mode guide planes for the FIRST row only.** In pattern mode the operator draws ONLY the seed (row 1) and the pattern replicates it, so guide planes for rows 2..N are never drawn against. `$planeCorners = if ($usePattern) { @($slots.Rows[0].Corner0, $slots.Rows[0].Corner1) } else { $slots.Corners }` — feed only the seed's 2 corners to `Get-SharedPlanePlan` in pattern mode (all corners in per-row mode). Encoded as a regression test in `run_orthogrid_tests.ps1`: a 3×3 grid drops from **7 offset planes → 3** (first-row-only is constant regardless of row count; the saving grows with rows). Offline suite now **272**.

### slotpat-probe.cmd
**RECORDER (creates a throwaway pattern you then delete; its purpose is capturing the widget names).** Reworked 2026-07-07 from an observational probe into a recorder, because the VB-docs sweep proved a mapkey is the only pattern lever and the sole recording was cancelled pre-count/increment. Flow: `Find-NewestTrail` marks the trail line count → enable `visible_mapkeys yes` (restore in finally) → select the pre-made seed slot cut BY ID + `ProCmdPattern` → **PAUSE while the operator completes ONE dimension pattern BY HAND** (click the position dim, type count + increment, OK) → DIFF the trail from the mark (handles a trail-file roll) → filter to widget/prompt lines (`~ Command`/`Open`/`Close`/`Select`/`Update`/`Input`/`Activate`/`Trigger`/`FocusOut`/… + `!%CP` prompts, dropping mouse/timer noise) → print + write `slotpat_recipe.txt` (gitignored). That recipe is transcribed into slotinator next as: draw 1 seed → arm pattern → operator clicks the dim (the one pick) → tool auto-types count = `Get-SlotPatternPlan.Count` + increment = `.Increment` → confirm. Mirrors `pointref-probe`/`cornerinator-probe` (mine, don't guess).

### holepat-probe.cmd
**RECORDER for the seed-hole GEOMETRY-PATTERN mapkey (creates a throwaway pattern you then delete; its purpose is capturing the 2-direction widget names).** Born from the **hole-creation-speedup study (2026-07-21, fan-out+verify workflow).** That study established the governing fact: the drill loop is **STRICTLY LINEAR — one `ProCmdHole` dashboard + one REGEN per point** (`drilljig.cmd` STAGE 3 `2052-2086`; `holeinator.cmd` `357-383`; `lib\drilljig_core.ps1` `Build-HoleMacro`/`Get-HolePointSelectMacro`), and the per-hole regen dominates wall-clock. Every **headless-safe** micro-optimization was researched against the VB docs + repo and **REJECTED**: trimming the "redundant" diameter/body/depth tokens on holes 2..N is UNSAFE (each hole opens a FRESH dashboard with Creo's DEFAULT diameter/body — they are must-set-per-dashboard, and skipping them silently drills defaults, a wrong-geometry the VersionStamp canary can't catch); dropping `buffer_clean` → silent **Linear** placement (canary-blind, confirmed-live 2026-06-25); the **mega-macro** (N dashboards in one `RunMacro`) KEEPS all N regens AND destroys the per-hole canary; **deferring regen** is blocked by No-Resolve mode (`Regenerate(instr)` throws `IpfcXToolkitBadContext`, `ExecuteFeatureOps` "not supported anymore", `resolve_mode` is the CS260154 dialog trap); the `OnAfterRegen` event listener needs a compiled `ICIPClientObject` PowerShell can't author. **The ONLY large win is to CUT THE REGEN COUNT** by replicating ONE seed hole with a Creo PATTERN (N holes → 1 seed dashboard + 1 pattern feature), exactly as radinator batches 40 rounds into one feature and slotinator patterns one seed slot. slotinator's **single-direction** `ProCmdGeomPattern` is proven live (2026-07-07: `ui_pat_dir_dir1` fed a base datum BY ID + `ui_pat_dir_1_num_inst`/`ui_pat_dir_1_incr` + `stdbtn_1`), but a hole grid is 2-D and the **SECOND direction's widgets were never recorded** (`ui_pat_dir_dir2`/`ui_pat_dir_2_num_inst`/`ui_pat_dir_2_incr`, best-guess). So this probe — same idiom as `slotpat-probe`/`csystrf-probe` — has the operator complete ONE 2-direction hole pattern BY HAND with `visible_mapkeys yes`, then `Find-NewestTrail` DIFFS the trail (handles a roll) → filters to widget/prompt lines → prints + writes `holepat_recipe.txt` (gitignored). The only macro it fires is the proven select-by-ID + `ProCmdPattern` open; it commits nothing. That recipe unblocks a future drilljig "pattern the holes" fast path (regular grids first — `Get-SlotPatternPlan`-style even-spacing gating already exists to copy) AND fills slotinator's missing dir-2 recipe. **Do NOT hand-write the pattern token stream from memory** (the mine-don't-guess rule — [[reference_mine_trail_files_for_widgets]]; `do NOT change how points/holes are created` without a live recording). Offline: the cost+safety model is fenced by new `run_wizard_tests.ps1` assertions (exactly ONE `dashInst0.Done` + ONE `ProCmdHole` per `Build-HoleMacro`/`Build-ReliefHoleMacro` = one regen; `buffer_clean` precedes the first `ProCmd` in every hole/relief/point-select macro = no silent Linear placement).

### csystrf-probe.cmd
**RECORDER for the "change coordinate system type" reref (creates NOTHING; drives NOTHING in Creo — you do every click; its purpose is capturing the file-dialog widget names).** Closes the load-bearing gap in drilljig's DEFAULT `--reref-method transform`: `Invoke-CsysTransformReimport`'s two macros (`Build-CsysTransformExportMacro` + `Build-CsysReimportMacro`, transcribed from the operator's 2026-07-14 "mapkey three") have UNVERIFIED file-dialog legs — the Save-As **never types a filename** (`file_saveas desktop_pb` + `OK` only), the reimport **never selects a specific file** (`file_open desktop_pb` + `ProFileSelPushOpen_Standard@context_dlg_open_cmd`), and the recording had an omitted `@PAUSE_FOR_SCREEN_PICK`. Flow (same idiom as slotpat-probe): `Find-NewestTrail` marks the line count → `visible_mapkeys yes` (restore in finally) → **PAUSE while the operator performs the WHOLE workflow by hand** (Analysis > Transform base↔index → Save-As info.trf with a real filename; then Redefine the base csys → OffsetType=file → open that info.trf → OK) → DIFF the trail (handles a roll) → filter to widget/prompt lines → print + write `csystrf_recipe.txt` (gitignored). That recipe is reconciled against the two `Build-*` macros — especially the Save-As filename + file-open tokens — then `csys-transform-reimport` can be promoted toward confirmed-live. Fact: `csys-transform-reimport-file-dialogs-unrecorded`. Mirrors `slotpat-probe`/`pointref-probe`/`cornerinator-probe` (mine, don't guess).

### fastenator.cmd
**IMPORT FASTENER LAYOUT — read an open part's fastener centers and reuse them as the jig hole layout (2026-07-20; offline-green, LIVE-UNVERIFIED read).** The user's ask: a part is open FULL of fasteners; build a drill jig (in a DIFFERENT blank part) whose holes land at those same positions. This is piece 1 of the feature (piece 2 = drilljig/drilljig-gui loading the file). fastenator connects to the active (fastener) model, reads each fastener BORE as a cylinder axis, projects the 3D centers onto the two user-picked model axes, and writes `fastener_layout.json`.
- **TWO read modes (auto-selected by model type).** **PART mode** = cylinder-axis: `Get-CylinderAxes` (`lib\creo_geometry.ps1`) sweeps common bore radii and reads each bore's `descriptor.Origin.GetOrigin()` (the path matrixinator uses live); `--selected` reads only pre-selected bores. **ASSEMBLY mode** (`--from-components`, auto-on when the active model is `.asm`) = component-path transform — **CONFIRMED LIVE 2026-07-20** on `004-956-8883-001.asm`: on an assembly `ListItems(ITEM_COMPONENT)`/`ITEM_BODY`/surfaces all return **0**, so the operator SELECTS the fastener components and each location is `Selection.Path.GetTransform($true).GetOrigin()` — the member→root-assembly transform origin (VB docs: `GetTransform(BottomUp as Boolean) as IpfcTransform3D`), read via the SAME `IpfcTransform3D.GetOrigin()` family proven for the csys read. 12 selected fasteners returned a clean 4×3 grid (X spacing 30, Z spacing 15, **Y=0 constant = the through-thickness axis, correctly ignored**); `BottomUp=$true` is the fastener position (`$false` is the inverse root→member transform, wrong for this). Neither mode ever reads `IpfcPoint.Point` (crashes — the holeinator lesson). Facts `fastener-center-via-cylinder-axis`, `fastener-assembly-component-path-transform` (confirmed-live).
- **PROJECT + HANDOFF = pure `lib\fastener_layout.ps1` (offline-tested).** `ConvertTo-LayoutXZ` picks the two model axes (`--axis-x`/`--axis-z`, optional `--flip-x`/`--flip-z`), corner-shifts so every point is `>= Margin` (default = the median bore Ø — so no point lands on the origin, which `Get-CustomPointsGeometry` would DROP), and dedups collinear bolt+washer+nut stacks by projected (X,Z) proximity (`--deduptol`, default = bore Ø ≥ the collision floor). `Test-FastenerLayoutSane` is the HONESTY canary — it refuses to write a layout with non-finite / degenerate / runaway-extent coords (never emit garbage from an unproven read). `Write-FastenerLayout` records source model + units + read method.
- **BUILD THE PLATE AROUND THE HOLES — `Set-LayoutMargin` re-anchor (user 2026-07-20, fixes the "layout error with edge margin").** The handoff file borders the layout for the FASTENER size, but the jig drills at the (usually larger) JIG hole dia (bushing OD from the decision tree). `Get-CustomPointsGeometry`'s edge-margin check needs each border hole to keep ≥ one JIG-hole RADIUS of wall to the plate edge, so the near-corner hole failed with *"leaves only N of wall … less than the hole radius"*. FIX: at CONSUMPTION time (drilljig.cmd fastener arm + GUI VIEW 3), `Set-LayoutMargin -Points $pts -Margin $jigHoleDia` re-anchors the near corner to the jig hole dia — a pure TRANSLATION that shifts every point equally, so all center-to-center spacings (the drilled PATTERN) are preserved EXACTLY; only the plate border grows to clear the hole on all four sides (the far edge is already sized by `ClearDia`). Verified on the live 12-fastener grid: OLD path failed at jigDia 0.375/0.5/0.75 with the exact edge-margin error, NEW path passes all with identical 4×3 spacing (plate 90.75×30.75 / 91×31 / 91.5×31.5). The holes are the important part — the plate is built around them.
- **Flags:** `--selected`, `--radius <list>`, `--radtol`, `--margin`, `--deduptol`, `--axis-x/-z X|Y|Z`, `--flip-x/-z`, `--out <path>`, `--units inch|mm`. Standalone; touches no other tool. Open the FASTENER part; ONE session. **LIVE-UNVERIFIED** (the cylinder read is proven elsewhere, but the full fastener→layout→jig round-trip is not yet run live).

### fastener-probe.cmd
**READ-ONLY diagnostic (creates/mutates NOTHING) — settles WHICH coordinate read returns fastener centers on this build BEFORE fastenator/drilljig trust one.** The whole feature hinges on reading a fastener center, and `IpfcPoint.Point` crashes here, so the read path must be PROVEN, not guessed (the mine-don't-guess methodology — [[reference_mine_trail_files_for_widgets]]). It connects to the active model and tries every candidate read in `try/catch`, reporting for each: ran-without-crashing? how many usable finite coords? samples. **[1] cylinder-axis** (`Get-CylinderAxes` swept radii — the winner in a PART, empty on an `.asm`); **[2] selected-bore** (`Get-CylinderAxisFromSurface` over the buffer); **[3] body CG** (`GetMassProperty($null).GravityCenter` per `ITEM_BODY` — gauginator path); **[4] component** (`ITEM_COMPONENT` count, then TRY `GetMassProperty`/transform); **[5] datum point/axis/csys** (counts + the proven `Read-CoordSysTransform` `.CoordSys.GetOrigin()`; NEVER `IpfcPoint.Point`); **[6] selected components** (`Selection.Path.GetTransform($true).GetOrigin()` — the ASSEMBLY read, the one that actually returns fastener positions on an `.asm`). **LIVE FINDING 2026-07-20 (`004-956-8883-001.asm`):** at the assembly top, `ListItems` returns 0 components, 0 bodies, 0 surfaces — only the default axis + csys — so sections [1]–[4] all come back empty and section [6] (select the components) is the read that works. Writes `fastener_probe_report.txt` (gitignored). Facts `fastener-component-and-datum-reads-unproven`, `fastener-assembly-component-path-transform`. Mirrors `pointref-probe`/`slotpat-probe`.

### Import-fastener-layout point-source mode (drilljig.cmd + drilljig-gui.cmd)
A **4th point-source mode** feeds the imported fastener layout into the drill-jig flow via the EXISTING `Get-CustomPointsGeometry` (so `$orthoGeo.Mode='custom'` and every downstream stage — box sizing, STAGE 2.5 point creation, drilling, index-hole, relief — is unchanged; the mode only produces the `{X;Z}` list). **ONE SHARED READER (2026-07-20 unification): `Read-FastenerCentersFromModel` (`lib\creo_geometry.ps1`)** does the live COM read for ALL three front-ends (fastenator.cmd, drilljig.cmd option 4, drilljig-gui.cmd) so the read never drifts — assembly (selection-buffer → component-path transform origin, deduped by leaf component id) vs part (cylinder-axis sweep, deduped by origin), returns `@{Ok;Centers;Count;IsAsm;ReadMethod;MedianDia;Message}`, never throws. The pure projection (`ConvertTo-LayoutXZ`) + handoff stay in `lib\fastener_layout.ps1`.
- **READ-FIRST FLOW (user 2026-07-20): the fastener import is offered at the VERY START, before material / DJ-type.** Console: an *"Import fastener layout? (y/N)"* prompt precedes STAGE 1; on yes, `Get-FastenerLayoutRawPoints` reads the RAW `{X;Z}` centers now (file OR throwaway-connection live read), and after the tree resolves the jig hole dia, `Build-OrthoGeoFromRawPoints` re-anchors (`Set-LayoutMargin`) + builds the plate and the point-source menu is SKIPPED. If not imported up front, the menu still offers option 4 (calls the same two helpers). GUI: a new **`Import` stage** (first in the breadcrumb, before `Bushing`) with a "Read fasteners now" button captures `$ctx.FastenerRawPoints`; the Layout stage AUTO-APPLIES them once the hole dia is known (re-anchor + build, tiles skipped, with a "Use a different layout" escape). The read is deferred-build because the plate border needs the jig hole dia, which only the tree knows.
- **ALL LAYOUTS CONVERGE — fastener is NOT special-cased; index hole ALWAYS set (GUI, 2026-07-21; supersedes the earlier "index-first OFF for imports" guard).** User directive: "every single layout page should converge to the same LAYOUTS and DATUMS page … the box creation for ALL methods is the same … there should be an index hole ALWAYS, so dont even say that is optional." So the GUI now routes EVERY laid-out layout (orthogrid / custom / imported FASTENER) through the IDENTICAL `index-choice → Datums → box-a/2.5` path: (1) the `index-choice` fastener guard + the dead `--fastener-index` flag were REMOVED (fastener no longer skips the index step); (2) `index-choice` is MANDATORY — the "None" card is gone and an index is auto-defaulted to the **corner-most candidate** (min X, then min Z, changeable via the remaining cards), for orthogrid AND fastener (index-relative custom already forced Hole #1); (3) both fastener Layout branches (up-front auto-apply + file-load VIEW 3) now render an **`Add-LayoutPreview` image** (the numbered dot preview, like the orthogrid/custom editors). The turn-1 fear that index-first "bugs out" (intersected-csys `Axis_X/Y/Z` unresolved) is MOOT: STAGE 2.5 was fixed to build the grid pitch planes off `CSYS_PAT_DEF` at absolute coords (`Get-IndexDirectionalPlanePlan`; see [[project_index_plane_direction]]), so the index-first box path works for all. box-a STAGE 1.9 builds the base csys AT the index for every laid-out layout; predefined (no `$orthoGeo`) still skips index-choice + uses the `Invoke-BaseCsys` copy. LIVE-UNVERIFIED. (The console `drilljig.cmd` still carries its own `$offerIndex=$false`-for-fastener guard + `--fastener-index`; unifying it the same way is a follow-up.)
- **GUI DATUMS PAGE = IDENTICAL FOR ALL LAYOUTS — session REPAIR after a fastener live read (2026-07-21; supersedes the re-fetch-only fix).** The GUI connects + binds `$model`/`$script:DJModel`/top-level `$session` ONCE at startup (~line 970 → `Initialize-DrilljigCore`), THEN the up-front Import stage runs the LIVE read via a **THROWAWAY `pfcAsyncConnection`** that it disconnects. On this build that round-trip leaves the startup session **unusable** at the **Datums stage**: `$c.Session.GetActiveModel()` throws / `$script:DJModel.ListItems(ITEM_FEATURE)` returns EMPTY → `Find-DefaultDatumPicks` finds 0 roles → the stage wrongly drops into the manual **"Ctrl-click TOP/SIDE/FRONT"** pick. Orthogrid/custom never toggle the active model, so their session stays live and they auto-discover — the divergence the user hit ("the DATUMS page should be the EXACT same for ALL layouts"). The console dodges it by connecting AFTER its read. **The re-fetch-only fix was insufficient** — its `try/catch` silently swallowed the throw on a dead session and never repaired anything. **FIX** (`drilljig-gui.cmd`, top of the Datums `-Build`): **(A)** if `$c.Session.GetActiveModel()` throws/returns null, **RECONNECT a fresh `pfcAsyncConnection`** (the console's guarantee) and repoint the TOP-LEVEL `$connection`/`$session` (the box/drill/slot steps call `$session.RunMacro`/`$model` directly) + `$c.Session`; **(B)** then rebind the jig handle to the live active model (guarded to the jig PART by normalized name, never an `.asm`) via `$c.Model`/`$script:model`/`Initialize-DrilljigCore`. Reachable because `-Build` is a plain `& $step.Build` block (not a closure), so `$script:` reaches the top-level. No-op when the session is already live (orthogrid/custom/file imports → `GetActiveModel` succeeds, no reconnect). LIVE-UNVERIFIED (confirm the datums auto-map after an up-front fastener import).
- **`drilljig.cmd` (console — one run, switch-active-model):** the live read uses a **THROWAWAY connection** (never `Initialize-DrilljigCore` — that would poison `$script:DJModel`) calling the shared reader; the main connect binds the jig part fresh, so switching the active model to the jig part is safe by construction. Cancel/empty/invalid → falls back to PREDEFINED.
- **`drilljig-gui.cmd` (wizard — file OR live, self-contained):** `Invoke-GuiFastenerLiveRead` is a THROWAWAY-connection read (shared `Read-FastenerCentersFromModel`) that **NEVER rebinds `$ctx.Model`/`$ctx.Session`/`Initialize-DrilljigCore`** (a wrong-model rebind would silently build on the fastener model). It uses owned TopMost `Show-WizardMessage` dialogs to (1) confirm the fastener model is active + components selected, (2) read + write the handoff, (3) prompt to switch back to the jig part. **`Invoke-GuiFastenerLiveRead` MUST be `function global:`** — it is invoked from a button `Add_Click` `.GetNewClosure()` handler, and a closure module can ONLY resolve GLOBAL functions (a plain script-scope function threw *"'Invoke-GuiFastenerLiveRead' is not recognized"* at click time — fixed + confirmed 2026-07-20; a global function invoked from a closure still resolves the script-scope dot-sourced libs it calls). Axis mapping defaults to X/Z (the confirmed flat-plate case); a non-default mapping is fastenator.cmd's `--axis-x/--axis-z`. `$ctx.FastenerLayoutPath`/`FastenerRawPoints` for provenance.
- **Offline:** `lib\tests\run_fastener_tests.ps1` (74 cases incl. `Set-LayoutMargin` re-anchor + the edge-margin bug/fix) and `lib\tests\run_tests.ps1` (the shared `Read-FastenerCentersFromModel` assembly branch: dedup-by-component-id + transform-origin read + never-throws, stubbed COM). `fastener_layout.json` + `fastener_probe_report.txt` are gitignored.
