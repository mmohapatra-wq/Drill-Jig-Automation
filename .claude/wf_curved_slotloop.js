export const meta = {
  name: 'curved-jig-slotloop-wave',
  description: 'Build the curved slot-loop COM-orchestration layer (arm seed sketch by ID + cut + canary, consuming Get-CurvedSlotPlan) + investigate the drilljig3d STAGE-2 plane-capture plumbing, split into granular parallel tasks',
  phases: [
    { title: 'Build', detail: 'curved_slot_macros.ps1 (COM orchestration) + its offline tests' },
    { title: 'Investigate', detail: 'drilljig3d STAGE-2 plumbing to capture per-hole plane IDs + point layout' },
    { title: 'Verify', detail: 'parse + run new suite + regression' },
  ],
}

const REPO = 'C:\\\\Users\\\\mmohapatra\\\\ngs-orthogrid-automation'

const CONTEXT = `
REPO: ${REPO}  (Creo Parametric VB-API automation; hybrid .cmd = batch + PowerShell body)

Bringing the CURVED conformal drill jig (drilljig3d.cmd) to flat-jig parity. The SKETCH wave settled
the slot design (all PROVEN-LIVE):
 - Hole placement: reuse the flat 3-plane intersection (Build-IntersectPointMacro, orthogrid_points.ps1:309,
   proven live 2026-06-24). USER CORRECTION: the hole only needs to go THROUGH the part, not sit ON the
   curved surface -- so a point in space + On-Point thru-all is fine on a curved blank.
 - Slot sketch plane: REUSE one of the offset planes the hole placement already made (no new geometry);
   fall back to New-OffsetPlane at the hole coordinate.
 - Arm the seed sketch BY ID (NO screen pick) -- PROVEN LIVE 2026-07-24 (fact sketch-open-on-plane-by-id):
     Get-SelectDatumByIdMacro -FeatId <planeId> +
     "~ Command ``ProCmdDatumSketCurve``;" +
     "~ Trigger ``Odui_Dlg_00`` ``t1.PlnMru`` ``0``;" + "~ Trigger ``Odui_Dlg_00`` ``t1.PlnMru`` ````;" +
     "~ Trigger ``Odui_Dlg_00`` ``t1.RefMru`` ``0``;" + "~ Trigger ``Odui_Dlg_00`` ``t1.RefMru`` ````;" +
     "~ Command ``ProCmdSketRectangle`` 1;"   (arm the rectangle tool; user then draws)
 - Cut: Build-CutFinishMacro (drilljig_core.ps1:1122, SURFACE-AGNOSTIC, proven live): ProCmdSketDone ->
   flip -> blind depth -> remove_material_cb -> body page -> Done. ONE atomic RunMacro.
 - Replicate: NO programmatic pattern/copy API for arbitrary curved positions (facts: IpfcFeaturePattern
   read/delete-only, IpfcCopyInstructions reserved, CreateFeature not implemented). So curved slots are
   PER-HOLE (or per-row) individual seed cuts -- exactly like drilljig-gui slot-b's PER-ROW fallback loop
   (line ~3951): arm sketch -> operator draws -> Build-CutFinishMacro -> Wait-ModelModified canary ->
   verify direction on the FIRST cut only (undo+flip+redraw on wrong, reuse the flip) -> advance.

NEW pure planner already built + tested (lib\curved_slots.ps1, 82 offline tests):
 - Get-CurvedSlotPlan -Holes @(@{ Id; Pos; Axis; RowKey; PlaneId }) [-SlotWidth] [-Mode 'per-hole'|'per-row']
   -> { Valid; Errors; Mode; Seeds=@( { Key; HoleIds; SketchPlaneId; SlotWidth; Members } ); Count; Warnings }.
   NOTE the hole input field is named "PlaneId" and the seed output field is "SketchPlaneId".
 - Group-CurvedHolesByRow, Test-CurvedSlotPlan (Ok + Issues gate).

PROVEN shared helpers (drilljig_core.ps1): Build-CutFinishMacro:1122, Invoke-VerifiedSeedCut:1296 (console
seed-cut+verify loop -- STUDY it, it is the closest console template), Get-SelectByIdMacro:608,
Get-SelectDatumByIdMacro:625, Wait-ModelModified:774 (-OnPoll callback for DoEvents), Get-FeatureIdSet:787,
New-OffsetPlane:893, Initialize-DrilljigCore:38 (sets $script:DJSession/DJModel/DJType), Invoke-Macro:734.
drilljig-gui.cmd slot-b PER-ROW mode (~3951) is the wizard template for the arm->cut->verify->advance loop.

HARD REPO RULES: pure math (no COM) NEVER throws -> { Valid=$false; Errors }; COM helpers read the
$script:DJSession/DJModel/DJType scope set by Initialize-DrilljigCore (like Invoke-VerifiedSeedCut/
Select-FeatureById do) rather than threading params; a canary that can't be read is a MISS not success
([[feedback_canary_must_not_assume_on_failure]]); component-per-line vectors; NEVER read IpfcPoint.Point;
ONE atomic RunMacro per dashboard sequence; global: scope for lib fns. Do NOT modify drilljig3d.cmd,
drilljig-gui.cmd, or any existing shared lib -- builders write ONLY their one new file; the investigator
is READ-ONLY.
`

phase('Build')
const builds = await parallel([
  { key:'slotmacros', file:'lib/curved_slot_macros.ps1', tests:false },
  { key:'slotmacros-tests', file:'lib/tests/run_curved_slot_macros_tests.ps1', tests:true },
].map(b => () =>
  agent(
    `${CONTEXT}\n\n${
  b.tests
  ? `Create the offline test suite ${REPO}\\\\${b.file} for lib\\curved_slot_macros.ps1. Model it EXACTLY
on lib\\tests\\run_curved_slots_tests.ps1 (Assert-True/Approx helpers, dot-source pattern, pass/fail
counter, exit 0 on all-pass). Dot-source ..\\curved_slot_macros.ps1 (and ..\\curved_slots.ps1,
..\\drilljig_core.ps1 if needed for scope). Since the COM-firing functions need a live session, test the
PURE parts to their PUBLISHED CONTRACT: (1) Build-CurvedSlotArmMacro emits EXACTLY the proven by-ID
sketch-open token sequence (assert the string CONTAINS ProCmdDatumSketCurve, t1.PlnMru, ProCmdSketRectangle,
and that it routes the plane id through a datum-by-id select -- i.e. contains the plane id and the
SelOptionRadio Datum tokens; assert it does NOT contain a buffer_clean AFTER the sketch command, etc.);
(2) the canary/guard LOGIC in Invoke-CurvedSlotSeed is exercised via STUBS: stub $script:DJSession.RunMacro
+ $script:DJModel.VersionStamp so a no-change fire reports Changed=$false (a MISS, never assume success),
a seed id <=0 or plane id <=0 short-circuits without firing, and a VersionStamp change reports success +
captures the new feature id. Follow the same stubbing approach run_wizard_tests.ps1 uses for the
drilljig_core COM helpers. Cover happy path + every guard/miss branch.`
  : `Create a NEW library ${REPO}\\\\${b.file} = the COM-ORCHESTRATION layer for the curved chip-relief
slot loop. It consumes a Get-CurvedSlotPlan result (lib\\curved_slots.ps1) and drives Creo to cut one slot
per seed, arming each seed's sketch BY ID (the proven-live path). It is the curved analog of the flat
slot-b loop. COM helpers read the $script:DJSession/DJModel/DJType scope (set by Initialize-DrilljigCore),
matching Invoke-VerifiedSeedCut:1296 / Select-FeatureById exactly -- study those first.

FUNCTIONS + PUBLISHED CONTRACT (the lib + tests must use these EXACT names):
 1. Build-CurvedSlotArmMacro -PlaneId <int>   (PURE string builder, no COM)
    Returns the ONE atomic macro string that arms a seed slot sketch on the given datum PLANE BY ID with
    NO screen pick, then arms the rectangle tool. EXACT proven token order (fact sketch-open-on-plane-by-id):
      (Get-SelectDatumByIdMacro -FeatId $PlaneId)      # datum-type tree-search select-by-ID (NO buffer_clean issue: this helper handles it)
      + "~ Command ``ProCmdDatumSketCurve``;"
      + "~ Trigger ``Odui_Dlg_00`` ``t1.PlnMru`` ``0``;" + "~ Trigger ``Odui_Dlg_00`` ``t1.PlnMru`` ````;"
      + "~ Trigger ``Odui_Dlg_00`` ``t1.RefMru`` ``0``;" + "~ Trigger ``Odui_Dlg_00`` ``t1.RefMru`` ````;"
      + "~ Command ``ProCmdSketRectangle`` 1;"
    (Get-SelectDatumByIdMacro comes from drilljig_core.ps1; resolve it at call time via dot-source scope,
    the same way orthogrid_points.ps1 macro builders call Get-SelectByIdMacro. Do NOT redefine it.)
 2. Invoke-CurvedSlotSeed -Seed <a Get-CurvedSlotPlan seed obj> -Depth <double> -BodyIndex <int>
      -Flip <bool> [-OnPoll <scriptblock>] [-TimeoutMs 30000]
    ORCHESTRATION (fires COM; reads $script:DJSession/DJModel). It ARMS the sketch (Build-CurvedSlotArmMacro
    with the seed's SketchPlaneId) so the caller can pause for the operator's manual rectangle draw, and
    exposes a SEPARATE finish step -- because a RunMacro cannot pause for the human draw (the box-a/box-b,
    slot-a/slot-b split). So implement it as TWO functions:
      2a. Invoke-CurvedSlotArm -Seed ... -> fires Build-CurvedSlotArmMacro; returns @{ Armed=$bool; Reason }.
          Guard: SketchPlaneId <= 0 => Armed=$false + Reason 'no sketch plane for this seed' (NEVER fire).
      2b. Invoke-CurvedSlotCut -Depth -BodyIndex -Flip [-OnPoll] [-TimeoutMs] -> AFTER the operator drew,
          fires Build-CutFinishMacro (drilljig_core.ps1) inside a Get-FeatureIdSet before/after +
          VersionStamp canary; returns @{ Changed=$bool; FeatId=<int|null>; Reason }. Changed=$false on a
          no-model-change (a MISS -- caller reopens the sketcher to redraw). FeatId = the highest new feature.
 3. Invoke-CurvedSlotPlanRun -Plan <Get-CurvedSlotPlan result> -Depth -BodyIndex [-Flip] [-OnPoll]
      [-DrawPrompt <scriptblock>] [-VerifyPrompt <scriptblock>]
    The CONSOLE driver that loops the plan's Seeds: for each seed -> Invoke-CurvedSlotArm -> call
    -DrawPrompt (the caller's Read-Host pause for the manual draw; in tests a stub) -> Invoke-CurvedSlotCut
    -> on the FIRST seed call -VerifyPrompt (undo+flip+redraw on 'wrong', reuse the flip for the rest; the
    ProCmdEditUndo macro is "~ Command ``ProCmdEditUndo``;") -> advance. Canary-gated each. Returns
    @{ Ok; SeedsCut; SeedsFailed; SeedsSkipped; Flip; Warnings=@() }. A seed with no plane (SketchPlaneId<=0)
    is SKIPPED with a warning (the caller screen-picks it), NEVER silently reported as cut. NEVER assumes
    success on a canary miss. Keep the DrawPrompt/VerifyPrompt as injected scriptblocks so the whole driver
    is offline-testable with stubs (no real Read-Host).
Add a top-of-file house-style comment block explaining this is the curved analog of slot-b, all macros
proven-live, per-hole not patterned. After writing, it will be parse-checked + the suite run.`
}`,
    { label:b.key, phase:'Build',
      schema:{ type:'object', additionalProperties:false,
        required:['file','summary','functions','parseClean'],
        properties:{ file:{type:'string'}, summary:{type:'string'},
          functions:{type:'array',items:{type:'string'}}, parseClean:{type:'boolean'} } } }
  ).then(r => ({ key:b.key, file:b.file, r }))
)).then(rs => rs.filter(Boolean))

phase('Investigate')
const inv = await agent(
  `${CONTEXT}

INVESTIGATE (READ-ONLY, modify nothing) the exact plumbing to make drilljig3d.cmd STAGE 2 place curved
holes from a LAYOUT and CAPTURE each hole's slot sketch-plane id, so the curved slot loop
(lib\\curved_slot_macros.ps1, being built now) can consume a per-hole { Id; Pos; Axis; RowKey; PlaneId }.

Read drilljig3d.cmd STAGE 2 IN FULL (~line 807-1007), drilljig.cmd STAGE 2.5 (the flat point-creation loop
that uses Get-SharedPlanePlan + Build-IntersectPointMacro and captures $gridPlaneIds / $csysRecords), and
lib\\orthogrid_points.ps1 (Get-SharedPlanePlan, Build-IntersectPointMacro). Answer concretely:
 1. drilljig3d STAGE 2 today drills at HAND-SELECTED points (Build-NormalHoleMacro). To reach parity, it
    should place points from a layout ($orthoGeo / fastener) via the flat 3-plane intersection. Map the
    MINIMAL change: what block from drilljig.cmd STAGE 2.5 transfers, and what curved-specific difference
    exists (the base planes: flat uses SIDE/TOP/FRONT default datums + offset planes; the curved blank has
    its own datums -- which planes does the intersection use so the point lands in the blank)?
 2. During that point-creation loop, HOW is each hole's slot sketch-plane id captured? In the flat tool the
    offset planes are made by Get-SharedPlanePlan (one per distinct X, one per distinct Z) and each point =
    face + Xplane[i] + Zplane[j]. So each hole's usable slot plane = its Xplane (for a Z-row) or Zplane (for
    an X-row). Give the EXACT records to store per hole: { Id (new point/hole id); PlaneId (the chosen
    offset plane feat id); RowKey (which row it shares) } and where in the loop to capture them (cite the
    flat drilljig.cmd lines that already build $gridPlaneIds so it's a mirror, not new invention).
 3. What is the SMALLEST drilljig3d.cmd edit to (a) run the layout point creation, (b) capture the per-hole
    plane records, (c) after drilling, call Get-CurvedSlotPlan + Invoke-CurvedSlotPlanRun for the slot loop?
    Give a step-by-step integration plan with the specific insertion points (line numbers) and which
    existing drilljig3d helpers/vars are reused ($orthoGeo? there is none yet -- does STAGE 2 need the
    orthogrid GUI wired like drilljig.cmd, or is fastener/hand-point the MVP?). Be explicit about what is
    MVP (hand-selected or single-layout) vs deferred.
Cite file:line for every claim. Distinguish PROVEN vs UNPROVEN. Output a concrete, ordered integration plan.`,
  { label:'stage2-plumbing', phase:'Investigate', agentType:'Explore',
    schema:{ type:'object', additionalProperties:false,
      required:['pointPlacement','planeCapture','integrationPlan','mvpVsDeferred','proven','unproven'],
      properties:{
        pointPlacement:{type:'string'}, planeCapture:{type:'string'},
        integrationPlan:{type:'array',items:{type:'string'}},
        mvpVsDeferred:{type:'string'},
        proven:{type:'array',items:{type:'string'}}, unproven:{type:'array',items:{type:'string'}} } } }
)

phase('Verify')
const verify = await agent(
  `Verify the curved slot-loop build in ${REPO}:
 1. PS AST parse-check lib\\curved_slot_macros.ps1 + lib\\tests\\run_curved_slot_macros_tests.ps1.
 2. Run powershell -ExecutionPolicy Bypass -File lib\\tests\\run_curved_slot_macros_tests.ps1 -- report pass/fail + exit code; quote the FIRST failing assertion on failure.
 3. Regression: run lib\\tests\\run_curved_slots_tests.ps1 + lib\\tests\\run_curved_tests.ps1 (tails) still green.
Report crisp PASS/FAIL per item.`,
  { label:'verify', phase:'Verify',
    schema:{ type:'object', additionalProperties:false,
      required:['parse','suite','regression','overall','fixesNeeded'],
      properties:{ parse:{type:'array',items:{type:'string'}}, suite:{type:'string'},
        regression:{type:'string'}, overall:{type:'string',enum:['all-green','issues']},
        fixesNeeded:{type:'array',items:{type:'string'}} } } }
)

return { builds, inv, verify }
