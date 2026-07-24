export const meta = {
  name: 'curved-jig-mega-wave',
  description: 'Broad parallel curved-jig build: tangent-plane pipeline (probe+macro+tests), slot-loop COM layer (+tests), and two read-only integration investigations (STAGE-2 plumbing, fastener->curved)',
  phases: [
    { title: 'Build', detail: '5 disjoint new files in parallel: tangent-plane macro lib + tests, tangent-plane probe, slot-loop COM lib + tests' },
    { title: 'Investigate', detail: '2 read-only: drilljig3d STAGE-2 plane-capture plumbing, fastener->datum-point->tangent-plane feed' },
    { title: 'Verify', detail: 'parse + run new suites + regression' },
  ],
}

const REPO = 'C:\\\\Users\\\\mmohapatra\\\\ngs-orthogrid-automation'

// NOTE: NO Creo backtick-quoted mapkey tokens in this brief -- backticks are the JS
// template-literal delimiter and break the script. Agents READ the real macro strings
// from the repo files named below. Widget/command names appear here UNQUOTED only.
const CONTEXT = `
REPO: ${REPO}  (Creo Parametric VB-API automation; hybrid .cmd = batch + PowerShell body)

Bringing the CURVED conformal drill jig (drilljig3d.cmd) to flat-jig parity. Settled design (PROVEN-LIVE
unless noted):
 - Surface build: DONE (drilljig3d STAGE 1). Hole "goes THROUGH the part, not ON the surface" (user).
 - Hole placement: reuse the flat 3-plane intersection Build-IntersectPointMacro (orthogrid_points.ps1:309,
   proven live). A datum point in space + On-Point thru-all drills through the curved blank.
 - NEW LINCHPIN (user 2026-07-24, recording in docs\\tangent_plane_at_point_on_surface.mapkey.txt, fact
   tangent-plane-at-point-on-surface): a datum plane TANGENT to a curved SURFACE AT a datum POINT --
   ProCmdDatumPlane with constraint type Tangent -- has its NORMAL == the surface normal there. So per hole:
   fastener/layout -> datum POINT -> TANGENT PLANE at (point,surface) gives BOTH (a) a real normal-to-surface
   reference for drilling AND (b) the ideal seed-sketch host for the chip-relief slot. This REPLACES the old
   surface-pre-select orientation HYPOTHESIS as the PRIMARY strategy; the offset-plane reuse is the fallback.
 - Slot sketch open BY ID (NO screen pick): PROVEN LIVE 2026-07-24 (fact sketch-open-on-plane-by-id; recipe
   in slotplane-probe.cmd) -- arm the seed sketch on the tangent plane by ID.
 - Slot cut: Build-CutFinishMacro (drilljig_core.ps1:1122, SURFACE-AGNOSTIC, proven live). ONE atomic RunMacro.
 - Replicate: NO programmatic pattern/copy API for arbitrary curved positions -> per-hole individual seed
   cuts, canary-gated each (like drilljig-gui slot-b PER-ROW fallback ~line 3951). Verify direction on the
   FIRST cut only, reuse the flip.

READ THESE for exact proven macro strings (do NOT hand-retype widget tokens from this brief):
 - docs\\tangent_plane_at_point_on_surface.mapkey.txt  (the tangent-plane recording + script-usable token order)
 - slotplane-probe.cmd  (the proven by-ID sketch-open arm macro)
 - lib\\drilljig_core.ps1: Build-CutFinishMacro:1122, Invoke-VerifiedSeedCut:1296 (console seed-cut+verify
   template), Get-SelectByIdMacro:608, Get-SelectDatumByIdMacro:625, Wait-ModelModified:774 (-OnPoll),
   Get-FeatureIdSet:787, New-OffsetPlane:893, Initialize-DrilljigCore:38 (sets $script:DJSession/DJModel/DJType),
   Invoke-Macro:734, Build-IntersectPointMacro pattern.
 - lib\\orthogrid_points.ps1: Build-IntersectPointMacro:309, Get-SharedPlanePlan:369, Resolve-NewPointIds.
 - lib\\curved_slots.ps1 (NEW, 82 tests): Get-CurvedSlotPlan -Holes @(@{Id;Pos;Axis;RowKey;PlaneId})
   [-SlotWidth][-Mode 'per-hole'|'per-row'] -> {Valid;Errors;Mode;Seeds=@({Key;HoleIds;SketchPlaneId;SlotWidth;Members});Count;Warnings};
   Group-CurvedHolesByRow; Test-CurvedSlotPlan.
 - fastener-probe.cmd / lib\\tests\\run_curved_slots_tests.ps1 (probe idiom + test idiom to mirror).

HARD RULES: pure math (no COM) NEVER throws -> {Valid=$false;Errors}; COM helpers read $script:DJSession/
DJModel/DJType scope set by Initialize-DrilljigCore (mirror Invoke-VerifiedSeedCut / Select-FeatureById);
a canary that can't be read is a MISS not success ([[feedback_canary_must_not_assume_on_failure]]);
ONE atomic RunMacro per dashboard; component-per-line vectors; NEVER read IpfcPoint.Point; global: lib fns;
CM*/CC* names are never standalone ProgIDs. Probes are READ-mostly (create at most a throwaway feature +
feature-diff canary, report to a gitignored *_report.txt). Builders write ONLY their one new file;
investigators are READ-ONLY. Do NOT modify drilljig3d.cmd / drilljig-gui.cmd / existing shared libs.
`

phase('Build')
const builds = await parallel([
  {
    key:'tangent-lib', file:'lib/tangent_plane.ps1', kind:'lib',
    spec:`Create ${REPO}\\\\lib\\\\tangent_plane.ps1 -- the tangent-plane macro + orchestration for the curved
jig. COM helpers read the $script:DJSession/DJModel/DJType scope (mirror Invoke-VerifiedSeedCut). FUNCTIONS:
 1. Build-TangentPlaneMacro -PointId <int> -SurfaceId <int>  (PURE string builder, no COM)
    Returns the ONE atomic macro that selects the SURFACE + the datum POINT by ID (accumulate: first ref via
    Get-SelectByIdMacro, second via Get-SelectByIdMacro -NoClear), then fires ProCmdDatumPlane with the
    constraint type menu set to Tangent, then OK. COPY the exact backtick-quoted token strings from
    docs\\tangent_plane_at_point_on_surface.mapkey.txt (ProCmdDatumPlane; constr_type1_OPTMENU1 open/close/
    Select 1 Tangent; stdbtn_1). Get-SelectByIdMacro comes from drilljig_core.ps1 (dot-source scope; do NOT
    redefine). Take a -SurfaceFirst switch (default $true) so the ref order can be flipped if the probe shows
    the point must be selected first.
 2. Invoke-TangentPlane -PointId <int> -SurfaceId <int> [-SurfaceFirst] [-OnPoll] [-TimeoutMs 30000]
    ORCHESTRATION: snapshot Get-FeatureIdSet, fire Build-TangentPlaneMacro, Wait-ModelModified canary, then
    resolve the NEW plane feature id (highest new ITEM_FEATURE). Returns @{ Created=$bool; PlaneId=<int|null>;
    Reason }. Created=$false on a no-change (a MISS -- NEVER assume success). Guard: PointId<=0 or SurfaceId<=0
    => Created=$false + Reason, NEVER fire. This is the primary per-hole normal-plane builder for the curved jig.
Add a house-style comment block: tangent plane normal == surface normal, curved-jig linchpin, LIVE-UNVERIFIED
(needs tangent-plane-probe). Parse-clean.`,
  },
  {
    key:'tangent-tests', file:'lib/tests/run_tangent_plane_tests.ps1', kind:'test',
    spec:`Create ${REPO}\\\\lib\\\\tests\\\\run_tangent_plane_tests.ps1 for lib\\tangent_plane.ps1. Model it
EXACTLY on lib\\tests\\run_curved_slots_tests.ps1 (Assert-True/Approx, dot-source, pass/fail counter, exit 0).
Dot-source ..\\drilljig_core.ps1 then ..\\tangent_plane.ps1. Test to the PUBLISHED CONTRACT:
 - Build-TangentPlaneMacro emits a string that CONTAINS ProCmdDatumPlane, the Tangent token, stdbtn_1, and
   BOTH ids (point + surface); -SurfaceFirst:$false swaps the ref order (assert the surface id appears after
   the point id, or vice-versa per the switch). Assert it fires the plane command exactly once.
 - Invoke-TangentPlane guard/canary LOGIC via STUBS (mirror how run_wizard_tests.ps1 stubs drilljig_core COM):
   stub $script:DJSession.RunMacro + $script:DJModel (VersionStamp + a ListItems feature-set for the diff) so:
   PointId<=0 or SurfaceId<=0 short-circuits without firing (Created=$false); a no-VersionStamp-change reports
   Created=$false (MISS); a change + a new feature id reports Created=$true + PlaneId=<the new id>.
Cover happy path + every guard/miss branch.`,
  },
  {
    key:'tangent-probe', file:'tangent-plane-probe.cmd', kind:'probe',
    spec:`Create ${REPO}\\\\tangent-plane-probe.cmd -- a probe that confirms the tangent-plane recipe live.
Model it on fastener-probe.cmd (6-line hybrid header, connect block, trap, config-suppress/restore, ASCII-only,
gitignored report). .prt guard. Dot-source lib\\creo_geometry.ps1 + lib\\drilljig_core.ps1 + lib\\tangent_plane.ps1;
Initialize-DrilljigCore. FLOW: operator SELECTS one datum POINT + the curved SURFACE it sits on (Ctrl-click),
presses ENTER. The probe reads their ids (ID-ONLY: Resolve via the selection buffer SelItem.Id + .Type; NEVER
IpfcPoint.Point), then calls Invoke-TangentPlane and reports whether a NEW datum plane was created (feature-diff
canary) + its id. Try BOTH ref orders (-SurfaceFirst on/off) if the first misses. Optionally (read-only, best
effort) read the new plane's normal to compare against the bore axis if a bore is also selected -- but do NOT
depend on plane-normal reads (they are null on this build). Write findings + the created plane id to
tangent_plane_probe_report.txt (already gitignored via the *_probe_report pattern? if not, print a reminder).
It DOES create a datum plane (that is the point of the probe) -- it is NOT purely read-only; tell the operator
they can delete the test plane after. Parse-clean, ASCII-only.`,
  },
  {
    key:'slotmacros', file:'lib/curved_slot_macros.ps1', kind:'lib',
    spec:`Create ${REPO}\\\\lib\\\\curved_slot_macros.ps1 -- the COM-orchestration layer for the curved slot loop,
consuming a Get-CurvedSlotPlan result and cutting one slot per seed, arming each seed's sketch BY ID (proven-live).
Curved analog of drilljig-gui slot-b (~3951). COM helpers read $script:DJSession/DJModel scope. FUNCTIONS:
 1. Build-CurvedSlotArmMacro -PlaneId <int>  (PURE) -> the atomic macro that arms a seed sketch on the datum
    plane BY ID + arms the rectangle tool. Concatenate (Get-SelectDatumByIdMacro -FeatId $PlaneId) then the
    sketch-open + PlnMru/RefMru + rectangle-arm tokens -- COPY those token strings verbatim from
    slotplane-probe.cmd (proven-live). Do NOT redefine Get-SelectDatumByIdMacro.
 2. Invoke-CurvedSlotArm -Seed <a Get-CurvedSlotPlan seed> -> fires the arm macro with the seed's SketchPlaneId;
    returns @{ Armed=$bool; Reason }. SketchPlaneId<=0 => Armed=$false + Reason (NEVER fire).
 3. Invoke-CurvedSlotCut -Depth <double> -BodyIndex <int> -Flip <bool> [-OnPoll][-TimeoutMs 30000] -> AFTER the
    operator drew, fires Build-CutFinishMacro (drilljig_core.ps1) inside a Get-FeatureIdSet before/after +
    VersionStamp canary; returns @{ Changed=$bool; FeatId=<int|null>; Reason }. Changed=$false on no-change (MISS).
 4. Invoke-CurvedSlotPlanRun -Plan <Get-CurvedSlotPlan result> -Depth -BodyIndex [-Flip][-OnPoll]
      [-DrawPrompt <scriptblock>][-VerifyPrompt <scriptblock>] -> loops Seeds: Arm -> DrawPrompt (injected
    Read-Host pause; a stub in tests) -> Cut -> on the FIRST seed VerifyPrompt (undo via the ProCmdEditUndo
    command + flip + redraw on 'wrong', reuse the flip) -> advance. Canary-gated each. Returns @{ Ok; SeedsCut;
    SeedsFailed; SeedsSkipped; Flip; Warnings }. A seed with SketchPlaneId<=0 is SKIPPED with a warning (NEVER
    reported as cut). NEVER assume success on a canary miss. Injected prompts keep it offline-testable.
Add a house-style comment block. Parse-clean.`,
  },
  {
    key:'slotmacros-tests', file:'lib/tests/run_curved_slot_macros_tests.ps1', kind:'test',
    spec:`Create ${REPO}\\\\lib\\\\tests\\\\run_curved_slot_macros_tests.ps1 for lib\\curved_slot_macros.ps1.
Model EXACTLY on lib\\tests\\run_curved_slots_tests.ps1. Dot-source ..\\drilljig_core.ps1, ..\\curved_slots.ps1,
..\\curved_slot_macros.ps1. Test the PURE + STUBBED-COM parts:
 - Build-CurvedSlotArmMacro CONTAINS the proven sketch-open tokens (ProCmdDatumSketCurve, t1.PlnMru,
   ProCmdSketRectangle) + routes the plane id through the datum-by-id select.
 - Invoke-CurvedSlotArm: SketchPlaneId<=0 => Armed=$false, no fire; >0 => Armed=$true (stub RunMacro).
 - Invoke-CurvedSlotCut: stub VersionStamp so no-change => Changed=$false; change + new feature => Changed=$true
   + FeatId set.
 - Invoke-CurvedSlotPlanRun: with a 3-seed plan + stubbed DrawPrompt/VerifyPrompt + stubbed COM, assert
   SeedsCut counts correctly; a seed with SketchPlaneId<=0 is SKIPPED (SeedsSkipped++, a Warning) not cut;
   a canary miss increments SeedsFailed and does not claim success; the first-seed VerifyPrompt 'wrong' path
   flips and retries. Follow run_wizard_tests.ps1 stubbing for the COM scope.`,
  },
].map(b => () =>
  agent(`${CONTEXT}\n\nYOUR FILE (write ONLY this one): ${b.file}\n\n${b.spec}`,
    { label:b.key, phase:'Build',
      schema:{ type:'object', additionalProperties:false,
        required:['file','summary','functions','parseClean','unverified'],
        properties:{ file:{type:'string'}, summary:{type:'string'},
          functions:{type:'array',items:{type:'string'}}, parseClean:{type:'boolean'},
          unverified:{type:'array',items:{type:'string'}} } } }
  ).then(r => ({ key:b.key, file:b.file, r }))
)).then(rs => rs.filter(Boolean))

phase('Investigate')
const INVS = [
  {
    key:'stage2-plumbing', title:'drilljig3d STAGE-2 plane-capture plumbing',
    q:`INVESTIGATE (READ-ONLY) the minimal drilljig3d.cmd STAGE 2 change to place curved holes from a layout,
create a TANGENT PLANE per hole (Build-TangentPlaneMacro, being built now), drill normal-to-that-plane, and
CAPTURE each hole's { Id; Pos; Axis; RowKey; PlaneId } for the curved slot loop. Read drilljig3d.cmd STAGE 2
(~807-1007) + drilljig.cmd STAGE 2.5 (flat point-creation + $gridPlaneIds capture) + orthogrid_points.ps1.
Answer: (1) how points get placed (3-plane intersection vs from a read fastener transform) on the curved blank;
(2) where in the loop to create the tangent plane per hole (point + STAGE-1 surface -> Invoke-TangentPlane ->
capture PlaneId) and drill referencing it; (3) the ordered, line-referenced integration plan + MVP vs deferred.`,
  },
  {
    key:'fastener-curved', title:'fastener read -> datum point -> tangent plane feed',
    q:`INVESTIGATE (READ-ONLY) how the proven fastener read feeds the curved pipeline. Read lib\\creo_geometry.ps1
Read-FastenerCentersFromModel + Get-CylinderAxes/Get-CylinderAxisFromSurface, lib\\fastener_layout.ps1, and how
drilljig.cmd option 4 / drilljig-gui consume a fastener layout. Answer: (1) the fastener read gives per-hole
Pos + Axis (position + bore direction) -- for a CURVED jig do we CREATE a datum point at each read position
(how, given IpfcPoint.Point is banned and Build-CsysOffsetPointsMacro is docs-only?), or intersect 3 planes to
land it? (2) once a datum point exists at the hole, the TANGENT PLANE (point + curved surface) gives the normal
-- so the fastener AXIS is NOT needed for orientation (it was refuted as the normal anyway); is the fastener
axis still useful (angularity export via lib\\curved_jig.ps1 Get-BoreAngularity)? (3) the honest MVP path for
"fastener-positioned curved jig": what is proven end-to-end vs what needs a probe. Cite file:line.`,
  },
]
const invs = await parallel(INVS.map(v => () =>
  agent(`${CONTEXT}\n\nYOUR INVESTIGATION: ${v.title}\n\n${v.q}\n\nREAD-ONLY -- modify nothing. Cite file:line. Distinguish PROVEN vs UNPROVEN.`,
    { label:v.key, phase:'Investigate', agentType:'Explore',
      schema:{ type:'object', additionalProperties:false,
        required:['topic','findings','integrationPlan','proven','unproven','mvp'],
        properties:{ topic:{type:'string'}, findings:{type:'string'},
          integrationPlan:{type:'array',items:{type:'string'}},
          proven:{type:'array',items:{type:'string'}}, unproven:{type:'array',items:{type:'string'}},
          mvp:{type:'string'} } } }
  ).then(r => ({ key:v.key, title:v.title, r }))
)).then(rs => rs.filter(Boolean))

phase('Verify')
const verify = await agent(
  `Verify the mega-wave build in ${REPO} with Bash/PowerShell:
 1. PS AST parse-check each new file: lib\\tangent_plane.ps1, lib\\tests\\run_tangent_plane_tests.ps1,
    tangent-plane-probe.cmd, lib\\curved_slot_macros.ps1, lib\\tests\\run_curved_slot_macros_tests.ps1.
 2. Run each new suite: run_tangent_plane_tests.ps1 + run_curved_slot_macros_tests.ps1 -- report pass/fail +
    exit code; on any failure quote the FIRST failing assertion.
 3. Regression (tails, must stay green): run_curved_slots_tests.ps1, run_curved_tests.ps1, run_jig_tree_tests.ps1,
    run_tests.ps1.
 4. Check .gitignore covers tangent_plane_probe_report.txt (report if missing; do NOT edit).
Report crisp PASS/FAIL per item with output tails.`,
  { label:'verify', phase:'Verify',
    schema:{ type:'object', additionalProperties:false,
      required:['parse','suites','regression','gitignore','overall','fixesNeeded'],
      properties:{ parse:{type:'array',items:{type:'string'}}, suites:{type:'array',items:{type:'string'}},
        regression:{type:'string'}, gitignore:{type:'string'},
        overall:{type:'string',enum:['all-green','issues']}, fixesNeeded:{type:'array',items:{type:'string'}} } } }
)

return { builds, invs, verify }
