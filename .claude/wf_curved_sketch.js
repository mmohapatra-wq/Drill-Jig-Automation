export const meta = {
  name: 'curved-jig-sketch-wave',
  description: 'Curved-jig SKETCH wave: investigate per-hole normal-plane slot sketching (reuse the proven by-ID sketch open) + build the pure per-hole slot planning lib, split into granular parallel tasks referencing drilljig-gui',
  phases: [
    { title: 'Investigate', detail: '3 read-only investigators: normal-plane construction, curved slot replicate, hole-point+plane tie' },
    { title: 'Build', detail: '2 disjoint pure files: lib/curved_slots.ps1 + its tests' },
    { title: 'Verify', detail: 'parse + run the new offline suite + regression' },
  ],
}

const REPO = 'C:\\\\Users\\\\mmohapatra\\\\ngs-orthogrid-automation'

const CONTEXT = `
REPO: ${REPO}  (Creo Parametric VB-API automation; hybrid .cmd = batch + PowerShell body)

We are bringing the CURVED (conformal) drill jig (drilljig3d.cmd) to parity with the FLAT jig
(drilljig.cmd / drilljig-gui.cmd). USER'S ARCHITECTURE + key steers:
  1. Surface/part creation: DONE (drilljig3d STAGE 1: offset-surface + thicken -> new body).
  2. Hole creation: holes positioned RELATIVELY, drilled THROUGH the part as through-holes.
     USER CORRECTION: the hole does NOT need to be created ON the surface -- it just needs to go
     THROUGH the part. A datum point in SPACE + On-Point thru-all is fine.
  3. Slot relief (THIS WAVE'S FOCUS): "draw ONE rectangle on an offset plane at one hole, then
     replicate at every hole. Since the holes are located through planes anyway, planes already
     exist to host the sketch." The flat tool draws ONE seed slot on the SIDE face + patterns it
     with a single-direction linear pattern; on a curved face per-hole normals differ so a single
     linear pattern will NOT replicate to arbitrary curved positions.

JUST-PROVEN LIVE (2026-07-24, slotplane-probe.cmd -> fact sketch-open-on-plane-by-id): a sketch
CAN be opened on a datum PLANE fed BY ID with NO screen pick. Recipe (recorded trail):
  buffer_clean; ProCmdMdlTreeSearch; SelOptionRadio=Datum; LookByOptionMenu=Feature;
  InputIDPanel=<id>; EvaluateBtn; ApplyBtn; CancelButton;
  ProCmdDatumSketCurve; Trigger Odui_Dlg_00 t1.PlnMru 0 (then empty); t1.RefMru 0 (then empty);
  <draw>; ProCmdSketDone.
This is the linchpin: the per-hole curved slot loop can ARM each seed sketch hands-free by ID.

REFERENCE (user: "refer to drilljig-gui, a lot has been figured out, just needs tweaking"):
 - drilljig-gui.cmd Relief stage slot-a (line ~3766) + slot-b (~3902): the mature arm->draw->cut->
   verify-direction->pattern wizard loop. slot-a arms the seed sketch on the SIDE face via
   (Get-SelectByIdMacro FaceId) + ProCmdFtExtrude + ProCmdViewSketchView + ProCmdSketRectangle 1;
   slot-b runs Build-CutFinishMacro, verifies direction (undo+flip+redraw on wrong), then patterns.
 - lib\\drilljig_core.ps1: Build-CutFinishMacro:1122 (sketch-exit->flip->blind-depth->remove_material
   ->body->Done, SURFACE-AGNOSTIC, reuse verbatim), Invoke-VerifiedSeedCut:1296 (console seed-cut +
   verify loop), New-SlotGuidePlanes:1250, Get-SelectByIdMacro:608, Get-SelectDatumByIdMacro:625,
   Wait-ModelModified:774, Get-FeatureIdSet:787.
 - lib\\orthogrid.ps1: Get-RowSlots:869 (group holes into rows -> slot rectangles, flat),
   Get-SlotSeedPatterns:1317 (decompose rows into from-seed pattern groups, flat).
 - lib\\orthogrid_points.ps1: Get-SharedPlanePlan:369 (distinct X/Z offsets + per-point indices),
   Build-IntersectPointMacro:309 (3-plane intersection datum point, proven live).
 - lib\\curved_jig.ps1 (NEW this session): Get-BoreAngularity:118 (bore axis -> dir cosines + angle
   off OG Z), Get-CurvedHolePlan:213 (per-hole angularity records), Get-CurvedIndexExport:317.
 - drilljig3d.cmd: Build-NormalHoleMacro:404 (On-Point hole; point + surface pre-select for normal
   orientation), STAGE 2 hole loop ~1010, Resolve-SelectedPoints:360.

HARD REPO RULES: pure math (no COM) NEVER throws -> return { Valid=$false; Errors=@() }; component-
per-line vectors (PS 5.1 COM-array trap); global: scope for lib fns; NEVER read IpfcPoint.Point;
distinguish PROVEN-LIVE / CONFIRMED-IN-CODE / DOCS-ONLY / UNPROVEN-GUESS for every claim; a canary
that can't be read is a MISS not a success. Do NOT modify drilljig3d.cmd or drilljig-gui.cmd or any
existing shared lib in this wave -- investigators are READ-ONLY, builders write ONLY their one new file.
`

phase('Investigate')
const INVS = [
  {
    key: 'normal-plane',
    title: 'Per-hole normal offset plane for the slot sketch',
    q: `Determine HOW to obtain, per curved hole, a datum PLANE suitable to host the chip-relief
seed rectangle -- ideally reusing a plane that ALREADY EXISTS from hole placement (the user's
insight), else constructing one. Concretely:
 - In the flat tool the seed sketch is drawn on the SIDE face (one flat plane for all holes). On a
   curved face there is no single flat side; the user says draw on "an offset plane NORMAL to the
   curved surface at one hole." Enumerate the options to get such a plane per hole and rate each
   PROVEN vs DOCS-ONLY vs UNPROVEN:
     (a) if holes are placed by 3-plane intersection (Build-IntersectPointMacro), do TWO of those
         planes pass through the hole such that one is usable as the slot sketch plane? (The user:
         "planes already exist.") Trace what planes exist at a curved hole in the fastener-import
         and synthetic paths.
     (b) a datum plane THROUGH the hole axis + normal to the surface: is there a proven
         plane-creation recipe (New-OffsetPlane / New-CsysOffsetPlane in drilljig_core, or
         Build-CsysOffsetPlaneMacro) that can build a plane referencing the bore axis / a csys axis?
     (c) a plane offset from a base datum (New-OffsetPlane:893) at the hole's coordinate -- same as
         the flat guide planes (New-SlotGuidePlanes:1250) -- does that transfer?
 - CRUCIAL given the user correction (hole just needs to go THROUGH the part): the slot sketch plane
   does NOT need to be tangent/normal to the true surface -- it needs to be a plane through the part
   at the hole so the rectangle cut clears chips. So a plane the placement already made (or a simple
   offset plane at the hole coordinate) may suffice. Assess whether the flat New-SlotGuidePlanes +
   SIDE-face-style approach can be reused with the curved blank's own datums, given the by-ID sketch
   open is now proven.
 - Output the RECOMMENDED per-hole slot-plane strategy for the MVP (reuse-existing vs build-offset),
   the exact proven macro/function it uses, and the fallback.`,
  },
  {
    key: 'curved-replicate',
    title: 'Replicating the seed slot to every curved hole',
    q: `The flat tool patterns ONE seed slot with a single-direction linear pattern
(Build-SlotPatternMacro + Get-SlotSeedPatterns). On a curved face the holes are at arbitrary 3D
positions with per-hole normals, so one linear pattern cannot replicate the seed. Determine the
honest replication strategy:
 - Confirm from CLAUDE.md + memory + lib\\creo_api_facts.json that there is NO programmatic
   pattern/copy API (IpfcFeaturePattern read/delete-only, IpfcCopyInstructions reserved,
   CreateFeature refuted-or-unimplemented). Cite the exact facts.
 - Given no copy API: the MVP curved slot loop must be PER-HOLE individual seed cuts (arm sketch on
   hole i's plane by ID -> operator draws -> Build-CutFinishMacro -> canary -> next hole), exactly
   like drilljig-gui slot-b's PER-ROW fallback mode (line ~3951). Verify that per-row fallback loop
   is the right template and enumerate precisely what changes for curved (per-HOLE not per-ROW; the
   sketch plane is per-hole by ID, proven).
 - Is nodelator.cmd's paste-by-reference (ProCmdEditCopy/ProCmdEditPasteSpecial, reroute a datum-
   point reference) a viable "replicate the seed to each hole" mechanism, or is it too feature-
   structure-specific? Assess honestly (it is used for node extrudes; a slot cut referencing a
   per-hole plane may or may not reroute). Rate PROVEN vs UNPROVEN.
 - Recommend the MVP replicate strategy (near-certainly: per-hole individual cuts, hands-free-armed
   by the proven by-ID sketch open, canary-gated each) + the honest report wording (per-hole cuts,
   not a pattern).`,
  },
  {
    key: 'point-plane-tie',
    title: 'Curved hole-point creation + its tie to the slot plane',
    q: `Trace end-to-end how a curved hole is placed and drilled today (drilljig3d STAGE 2), and how
that ties to the slot sketch plane, so the slot loop can reuse hole-placement planes:
 - drilljig3d STAGE 2 currently drills On-Point holes at HAND-SELECTED datum points
   (Build-NormalHoleMacro:404: point + surface pre-select). For PARITY with the flat tool's
   fastener/orthogrid/custom layouts, curved holes should be placed from a LAYOUT (fastener import,
   or synthetic). Given the user correction (hole just needs to go THROUGH the part), can the flat
   3-plane-intersection point creation (Build-IntersectPointMacro + Get-SharedPlanePlan) be reused
   to place curved-jig hole points IN SPACE, then drilled thru-all? What breaks vs the flat case?
 - If the hole points ARE created by 3-plane intersection, those planes (per Get-SharedPlanePlan:
   one per distinct X offset, one per distinct Z offset) persist in the model. Which of them is
   usable as the slot sketch plane for a given hole (the user's "planes already exist")? Map hole ->
   its X-plane + Z-plane and pick which is the slot plane (the one spanning the row direction).
 - For the FASTENER-import curved path: positions/axes are READ, not synthesized. Do we still create
   datum points (from the read transform) and 3-plane planes, or drill directly? What's the cleanest
   proven placement? (Note Build-CsysOffsetPointsMacro is docs-only/guess.)
 - Recommend the MVP data contract that the slot planner (lib\\curved_slots.ps1, being built in this
   wave) should consume: a per-hole record { Pos; Axis?; SketchPlaneId?; RowKey } so the slot loop
   knows each hole's sketch plane + which holes share a slot.`,
  },
]
const invs = await parallel(INVS.map(v => () =>
  agent(`${CONTEXT}\n\nYOUR INVESTIGATION: ${v.title}\n\n${v.q}\n\nRead the actual files. READ-ONLY -- modify nothing. Cite file:line for every load-bearing claim.`,
    { label: v.key, phase: 'Investigate', agentType: 'Explore',
      schema: { type:'object', additionalProperties:false,
        required:['topic','findings','recommendation','proven','unproven'],
        properties:{
          topic:{type:'string'},
          findings:{type:'string'},
          recommendation:{type:'string'},
          proven:{type:'array',items:{type:'string'}},
          unproven:{type:'array',items:{type:'string',description:'needs a probe/recording'}},
        } } }
  ).then(r => ({ key:v.key, title:v.title, r }))
)).then(rs => rs.filter(Boolean))

const invJson = JSON.stringify(invs, null, 1)

phase('Build')
const builds = await parallel([
  { key:'curved-slots-lib', file:'lib/curved_slots.ps1', tests:false },
  { key:'curved-slots-tests', file:'lib/tests/run_curved_slots_tests.ps1', tests:true },
].map(b => () =>
  agent(
    `${CONTEXT}\n\nINVESTIGATION RESULTS (use these to inform the design; the point->plane tie + the
per-hole slot-plane strategy are settled here):\n${invJson}\n\n${
  b.tests
  ? `Create the offline test suite ${REPO}\\\\${b.file} for lib\\curved_slots.ps1. Model it EXACTLY on
lib\\tests\\run_curved_tests.ps1 (read it for the Assert-True/Approx helpers, dot-source pattern,
pass/fail counter, exit-0-on-pass). Dot-source ..\\curved_slots.ps1 (and any lib it depends on).
Cover the PURE planner functions below to their PUBLISHED CONTRACT. NO Creo, NO network. The lib is
being written in PARALLEL; write tests to the contract names exactly.`
  : `Create a NEW pure-math planning library ${REPO}\\\\${b.file} (NO COM, NO state, NEVER throws;
component-per-line vectors; every function global:). It plans the CURVED chip-relief slot loop from a
per-hole layout, so the (later) drilljig3d slot stage can arm each seed sketch by ID and cut. Reuse
the row-grouping IDEA from Get-RowSlots but adapt to per-hole (curved holes are grouped by a RowKey,
not a flat cross-coordinate).`
}

FUNCTIONS + PUBLISHED CONTRACT (both the lib and the tests must use these EXACT names/fields):
 1. Get-CurvedSlotPlan -Holes @(@{ Id; Pos=@(x,y,z); Axis=@(x,y,z); RowKey; SketchPlaneId }, ...)
      [-SlotWidth <double>] [-Mode 'per-hole'|'per-row']
    Returns { Valid; Errors; Mode; Seeds=@( { Key; HoleIds=@(); SketchPlaneId; SlotWidth; Members } ),
              Count; Warnings=@() }.
    - 'per-hole' (default, the MVP): ONE seed per hole -> Seeds has one entry per hole, each with that
      hole's SketchPlaneId (the plane the slot sketch is armed on by ID). Count = hole count.
    - 'per-row': group holes by RowKey -> one seed per row (fewer cuts when a row shares a plane),
      each seed's HoleIds = the row's holes, SketchPlaneId = the row's shared plane.
    - A hole with no usable SketchPlaneId (0/null) is reported in Warnings (the caller falls back to a
      screen-pick for that seed) but does NOT invalidate the plan.
    - NEVER throws; empty/malformed Holes => Valid=$false + Errors.
 2. Group-CurvedHolesByRow -Holes (...) [-Tol <double>]
    Returns { Valid; Errors; Rows=@( { Key; HoleIds; Members } ) } -- group holes whose RowKey matches
    (string equality) OR, if RowKey is absent, by a projected coordinate within -Tol (a PHYSICAL tol,
    default max(SlotWidth/4, 0.01) style like Get-RowSlots -- NEVER 1e-6). Pure grouping used by
    Get-CurvedSlotPlan's per-row mode.
 3. Test-CurvedSlotPlan -Plan (a Get-CurvedSlotPlan result)
    Returns { Ok; Issues=@() } -- a cheap sanity gate: >=1 seed, every seed has >=1 hole, and either a
    SketchPlaneId or a recorded Warning (so the caller knows to screen-pick). Deterministic.

Add a top-of-file house-style comment block. This file has NO Creo calls. After writing, it will be
parse-checked + the test suite run.`,
    { label:b.key, phase:'Build',
      schema:{ type:'object', additionalProperties:false,
        required:['file','summary','functions','parseClean'],
        properties:{ file:{type:'string'}, summary:{type:'string'},
          functions:{type:'array',items:{type:'string'}}, parseClean:{type:'boolean'} } } }
  ).then(r => ({ key:b.key, file:b.file, r }))
)).then(rs => rs.filter(Boolean))

phase('Verify')
const verify = await agent(
  `Verify the curved-slot build in ${REPO}:
 1. PS AST parse-check lib\\curved_slots.ps1 and lib\\tests\\run_curved_slots_tests.ps1
    (powershell -NoProfile -Command "[void][System.Management.Automation.Language.Parser]::ParseFile('<abs>',[ref]$null,[ref]$e); if($e){$e|%{$_.Message}}else{'PARSE OK'}").
 2. Run: powershell -ExecutionPolicy Bypass -File lib\\tests\\run_curved_slots_tests.ps1 -- report pass/fail + exit code; on failure quote the FIRST failing assertion.
 3. Regression: powershell -ExecutionPolicy Bypass -File lib\\tests\\run_curved_tests.ps1 (tail) still green.
Report crisp PASS/FAIL per item with output tails.`,
  { label:'verify', phase:'Verify',
    schema:{ type:'object', additionalProperties:false,
      required:['parse','slotSuite','regression','overall','fixesNeeded'],
      properties:{ parse:{type:'array',items:{type:'string'}}, slotSuite:{type:'string'},
        regression:{type:'string'}, overall:{type:'string',enum:['all-green','issues']},
        fixesNeeded:{type:'array',items:{type:'string'}} } } }
)

return { invs, builds, verify }
