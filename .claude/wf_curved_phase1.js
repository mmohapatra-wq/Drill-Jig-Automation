export const meta = {
  name: 'curved-jig-phase1-build',
  description: 'Fan out the Phase-1 curved drill-jig build: probes + pure angularity lib + design doc, on DISJOINT new files, each verified offline',
  phases: [
    { title: 'Build', detail: '4 writers on disjoint new files (probe, slotplane-probe, angularity lib+tests, design doc)' },
    { title: 'Verify', detail: 'parse/offline-test each new file' },
  ],
}

const REPO = 'C:\\\\Users\\\\mmohapatra\\\\ngs-orthogrid-automation'

const CONTEXT = `
REPO: ${REPO}  (Creo Parametric VB-API automation; hybrid .cmd = batch + PowerShell body)

USER'S ARCHITECTURE for the curved (conformal) drill jig, which is being brought to parity
with the proven FLAT drill jig:
  1. Surface/part creation: DONE in drilljig3d.cmd STAGE 1 (offset-surface + thicken -> new
     conformal body). Confirmed live 2026-06-24.
  2. Fastener reading: like the flat import, but fasteners are NOT axis-perpendicular. Read each
     fastener core POSITION + derive its ANGLE vs the original (OG) part csys. (Position read is
     proven; the fastener AXIS-as-normal is REFUTED live -- per-hole orientation must come from
     the DRILLED cylinder axis + surface normal, not the fastener component axis.)
  3. Hole creation: holes positioned RELATIVELY, drilled THROUGH the surface as through-holes.
     KEY USER CORRECTION (2026): the hole does NOT need to be created ON the surface -- it just
     needs to go THROUGH the part. So a datum point in SPACE (3-plane intersection, or a read
     transform) is fine; On-Point thru-all drills through the conformal blank regardless.
  4. Slot relief: draw ONE rectangle on an offset plane at one hole, replicate at every hole.
     The planes that locate holes already exist to host the sketch.

HARD REPO RULES (must obey):
 - Every hybrid .cmd starts with the 6-line CMD/PowerShell header (copy from fastener-probe.cmd
   lines 1-6). Suppress visible_mapkeys/dynamic_preview at start, restore in finally.
 - NEVER read IpfcPoint.Point (crashes -- op_Subtraction on System.Object[]). Read positions via
   cylinder-axis descriptor (Get-CylinderAxes / Get-CylinderAxisFromSurface: descriptor.Origin
   .GetOrigin()/.GetZAxis()) or component-path transforms. ID-only for selection.
 - "CC*/CM*" factory names are NEVER standalone ProgIDs -- cascade candidate ProgIDs.
 - Fire a whole dashboard sequence as ONE atomic RunMacro (context doesn't survive across calls).
 - A canary that can't be read = a MISS (skip/fall back), NEVER assume success on failure.
 - Pure math helpers (no COM) NEVER throw -- return { Valid=$false; Errors=@(...) }. Build each
   vector component on its OWN line (never comma-separated @(math,math,math) -- PS 5.1 COM-array trap).
 - Probes are READ-ONLY diagnostics that create at most a throwaway feature you then delete;
   they report + write a gitignored *_report.txt / *_recipe.txt. Mirror fastener-probe.cmd /
   slotpat-probe.cmd (mine, don't guess widgets).

PROVEN PRIMITIVES you can rely on (file:line):
 - lib\\creo_geometry.ps1: Get-CylinderAxes:238 (reads .A origin + .D direction + Radius off a
   cylinder descriptor, proven-live), Get-CylinderAxisFromSurface:273 (one selected surface),
   Count-Cylinders:209, Get-Comp:24, Read-CoordSysTransform:673 (docs-only), Get-AllSurfaces:177.
 - lib\\drilljig_core.ps1: Get-SelectByIdMacro:608 (Feature-type tree-search select-by-ID),
   Get-SelectDatumByIdMacro:625 (Datum-type, for feeding an OPEN dashboard collector),
   Get-FeatureIdSet:787, Wait-ModelModified:774, Invoke-ForceRegen:747, Initialize-DrilljigCore:38.
 - lib\\index_frame.ps1: Get-IndexFrame + ConvertTo-IndexCoords + Test-IndexFrameValid -- PURE 3D
   orthonormal-frame math from 2 index positions + bore axes; NO planarity assumption. Reusable.
 - drilljig3d.cmd: Get-OffsetThickenMacro:249, Build-NormalHoleMacro:404 (On-Point hole; surface
   pre-select is the orientation HYPOTHESIS), Get-CylinderAxes usage, connect block:596-668.
`

phase('Build')

const WRITERS = [
  {
    key: 'probe-orient',
    file: 'drilljig3d-probe.cmd',
    task: `Create a NEW read-mostly diagnostic ${REPO}\\\\drilljig3d-probe.cmd that settles the
load-bearing orientation + axis-read + volume questions for the curved jig. It is the go/no-go
for the MVP's "holes are normal to the surface" claim.

Model it on fastener-probe.cmd (read fastener-probe.cmd IN FULL for the exact header, connect
block, trap, config-suppress/restore, ASCII-only output, gitignored report file). It connects to
ONE live Creo session, part mode only (.asm guard like drilljig3d.cmd:646).

THREE probe modes, selected by $ScriptArgs flags (default: run --probe-orient):
 * --probe-orient : the operator has (a) built a conformal blank via drilljig3d, and (b) SELECTED
   ONE datum point on it + the surface it should be normal to. The probe drills ONE test hole via
   drilljig3d's Build-NormalHoleMacro recipe (you may dot-source drilljig3d? No -- it is a .cmd,
   not a lib. Instead RE-IMPLEMENT the minimal On-Point hole macro inline OR, cleaner, have the
   operator drill the hole and the probe only MEASURES). Simplest correct design: the probe does
   NOT drill; it reads. It asks the operator to select the JUST-DRILLED bore + its host surface,
   reads the bore axis via Get-CylinderAxisFromSurface (.D direction), reads the surface normal via
   IpfcSurface.Eval3DData (see below), computes |dot(axisDir, surfaceNormal)| and reports the angle
   off-normal. |dot| ~ 1 (angle ~ 0) => holes ARE normal to the surface. This is READ-ONLY.
   To read the surface normal: get the selected surface SelItem; call its Eval3DData -- the VB API
   is IpfcSurface.Eval3DData(IpfcParameters) returning IpfcGeomPoint3D-like with .Normal. Query the
   vb-docs MCP (mcp__vb-docs__query_vb_api_docs) for the EXACT signature of Eval3DData /
   EvalParameters / how to get a normal at a uv-parameter, and wrap the call in try/catch reporting
   whether .Normal is non-null on this build (it is docs-only, NEVER called in the repo). NEVER
   read IpfcPoint.Point. If Eval3DData is unusable, report that clearly (the fallback is a visual
   normality check).
 * --probe-axis-read : the operator selects 2+ drilled bores on the curved blank; report each
   bore's axis DIRECTION (Get-CylinderAxisFromSurface .D) and whether they are DISTINCT (they must
   differ where curvature differs -- proves per-hole angularity is readable). READ-ONLY.
 * --probe-volume : inline -- for each ITEM_BODY, TRY GetMassProperty($null).Volume in try/catch and
   report whether .Volume is readable + the value (confirmed only for .GravityCenter today). READ-ONLY.

Write the report to drilljig3d_probe_report.txt (add it to .gitignore if not covered). Dot-source
lib\\creo_geometry.ps1. Keep EVERYTHING read-only (no feature creation) so it is safe to run.
Ensure the file parses: after writing, it will be parse-checked. ASCII-only Write-Host text.`,
  },
  {
    key: 'slotplane-probe',
    file: 'slotplane-probe.cmd',
    task: `Create a NEW observational probe ${REPO}\\\\slotplane-probe.cmd that answers: can a
sketch be opened on a datum PLANE fed BY ID (no screen pick), so the per-hole curved slot loop can
arm the seed-rectangle sketch hands-free?

Model it on slotpat-probe.cmd (read it IN FULL for the recorder idiom) and pointref-probe-style
observation (fires ONE arm macro, asks the operator what happened, creates nothing it doesn't undo).

Flow: connect (one session, .prt guard). Ask the operator to SELECT one datum plane in Creo (or
type its feature id). Then fire ONE atomic macro that (a) selects that plane BY ID via
Get-SelectDatumByIdMacro (Datum-type, from lib\\drilljig_core.ps1 -- dot-source it +
Initialize-DrilljigCore) and (b) opens the sketcher on it. Consult CLAUDE.md "Open sketcher on a
plane (confirmed)" for the ProCmdDatumSketCurve + t1.PlnMru/t1.RefMru + stdbtn_1 recipe -- the OPEN
QUESTION is whether feeding the plane BY ID replaces the @PAUSE_FOR_SCREEN_PICK the recipe normally
needs. Enable visible_mapkeys yes so the run is captured in the trail. After firing, ASK the
operator (Read-Host) whether the sketcher opened on the intended plane (Y/N/partially) and whether
a plane was pre-loaded. If it opened, immediately fire ProCmdSketDone / an exit so nothing is
committed. Write findings to slotplane_probe_report.txt (gitignored). If the by-ID feed does NOT
open the sketch, the report should say the per-hole slot loop must fall back to a screen-pick of
the sketch plane. Dot-source lib\\creo_geometry.ps1 + lib\\drilljig_core.ps1. Parse-clean, ASCII-only.`,
  },
  {
    key: 'angularity-lib',
    file: 'lib/curved_jig.ps1',
    task: `Create a NEW pure-math library ${REPO}\\\\lib\\\\curved_jig.ps1 (NO COM, NO state, NEVER
throws -- returns { Valid; Errors } objects; component-per-line vectors) with the per-hole
angularity + curved-layout math the curved jig needs. It must be dot-sourceable in a plain
PowerShell host (the offline tests load it with no Creo) and should reuse index_frame.ps1's math
conventions (read lib\\index_frame.ps1 IN FULL first; you may reference IFrame-* style helpers but
define your own tiny CJ-Dot/CJ-Cross/CJ-Unit/CJ-Norm so this lib is independently testable).

Functions to implement (pure math, all offline-testable):
 1. Get-BoreAngularity -Axis @(x,y,z) [-RefX @(1,0,0)] [-RefY @(0,1,0)] [-RefZ @(0,0,1)] :
    given a bore axis DIRECTION (unit or not) and the OG csys axes (default = world X/Y/Z), return
    @{ Valid; Errors; DirCosX; DirCosY; DirCosZ; AngleFromZDeg; AzimuthDeg; PolarDeg } -- the
    direction cosines vs each OG axis, the angle off the OG Z (the nominal drilling axis), and
    spherical azimuth/polar. This is how "the fastener's angle relative to the OG coordinate
    system" is represented (user architecture #2). Degenerate/zero axis => Valid=$false.
 2. Get-CurvedHolePlan -Holes @(@{ Pos=@(x,y,z); Axis=@(x,y,z) }, ...) [-RefX/-RefY/-RefZ] :
    map a list of read holes (position + axis) into a per-hole record carrying Pos, Axis, and its
    Get-BoreAngularity result, plus a summary (max angle off nominal, whether any hole is tilted
    beyond a -MaxTiltDeg warn threshold). NEVER throws; a bad hole is flagged, not fatal.
 3. Get-CurvedIndexExport -Holes (same shape) -IndexA/-IndexB (two index-hole positions) : build
    the index frame (you may CALL Get-IndexFrame/ConvertTo-IndexCoords from index_frame.ps1 IF you
    dot-source it, OR re-derive minimally) and return per-hole rows { X_index; Y_index; Z_index;
    DirCos*; AngleFromZDeg; IsIndex } in the index frame -- the curved analog of the flat
    Get-HolesRelativeToIndex but keeping full 3D + orientation. Reuse index_frame.ps1 rather than
    re-deriving if clean.
Every function global: scoped (so a .cmd dot-source exposes them). Add a top-of-file comment block
in the repo's house style. This file has NO Creo calls at all.`,
  },
  {
    key: 'angularity-tests',
    file: 'lib/tests/run_curved_tests.ps1',
    task: `Create a NEW offline test suite ${REPO}\\\\lib\\\\tests\\\\run_curved_tests.ps1 for the
functions in lib\\curved_jig.ps1 (Get-BoreAngularity, Get-CurvedHolePlan, Get-CurvedIndexExport).
Model it EXACTLY on an existing suite (read lib\\tests\\run_index_frame_tests.ps1 IN FULL for the
Assert-True / Approx helpers, the dot-source-the-lib pattern, the pass/fail counter, and the exit
code convention -- exit 0 = all pass). It must dot-source ..\\curved_jig.ps1 (and ..\\index_frame.ps1
if curved_jig depends on it) with NO Creo, NO network.

Cover, at minimum:
 - Get-BoreAngularity: a bore axis exactly along +Z => AngleFromZDeg ~ 0, DirCosZ ~ 1. A 45-deg
   tilt => AngleFromZDeg ~ 45, DirCosZ ~ cos45. A horizontal axis (in XY) => AngleFromZDeg ~ 90.
   Non-unit input normalized correctly. Zero/degenerate axis => Valid=$false, no throw. Anti-parallel
   axis handled (use |dot| where appropriate, matching the impl).
 - Get-CurvedHolePlan: N holes with varying tilts => per-hole angularity correct + the max-tilt
   summary + the warn threshold flags the tilted one. A malformed/null hole flagged not fatal.
 - Get-CurvedIndexExport: 3 coplanar holes with parallel +Z axes => index frame math matches the
   proven index_frame result (index hole at origin, second index on the +X axis). A tilted hole's
   orientation carried through. Never throws on bad input.
IMPORTANT: since lib\\curved_jig.ps1 is being written IN PARALLEL by another agent, write the tests
to the PUBLISHED CONTRACT above (function names, param names, and returned field names EXACTLY as
specified in the angularity-lib task). If a field name is ambiguous, prefer the names in the
contract. The tests will be RUN after both files exist; they must pass against a faithful impl.`,
  },
]

const built = await parallel(WRITERS.map(w => () =>
  agent(
    `${CONTEXT}\n\nYOUR FILE (write ONLY this one file, do not touch any other file):\n  ${w.file}\n\n${w.task}\n\nReturn what you created.`,
    {
      label: w.key,
      phase: 'Build',
      schema: {
        type: 'object', additionalProperties: false,
        required: ['file', 'summary', 'functions', 'provenReused', 'unverifiedAssumptions', 'parseClean'],
        properties: {
          file: { type: 'string' },
          summary: { type: 'string' },
          functions: { type: 'array', items: { type: 'string' } },
          provenReused: { type: 'array', items: { type: 'string' } },
          unverifiedAssumptions: { type: 'array', items: { type: 'string' }, description: 'what needs a live probe/recording' },
          parseClean: { type: 'boolean', description: 'did you verify it parses (PS AST or offline run)' },
        },
      },
    }
  ).then(r => ({ key: w.key, file: w.file, result: r }))
)).then(rs => rs.filter(Boolean))

// ---- Verify: parse each .cmd/.ps1 and run the new offline suite ----------
phase('Verify')
const verify = await agent(
  `Verify the Phase-1 curved-jig build in ${REPO}. Do these checks with Bash/PowerShell and report:
 1. Parse-check each new file with PowerShell AST (no execution):
    powershell -NoProfile -Command "[void][System.Management.Automation.Language.Parser]::ParseFile('<abs path>',[ref]$null,[ref]$errs); if($errs){$errs|%{$_.Message}} else {'PARSE OK'}"
    for: drilljig3d-probe.cmd, slotplane-probe.cmd, lib\\curved_jig.ps1, lib\\tests\\run_curved_tests.ps1
    (For the .cmd files, the PowerShell body is inside a batch wrapper; parse the file anyway --
     the here-string header parses as PS comment. If AST parse errors on the leading '<# :' that's
     expected/benign for .cmd; note it but focus on the PS body.)
 2. Run the new offline suite: powershell -ExecutionPolicy Bypass -File lib\\tests\\run_curved_tests.ps1
    Report pass/fail count and exit code. If it fails, report the FIRST failing assertion verbatim.
 3. Confirm the existing suites still pass (no shared-file regression, though these are new files):
    powershell -ExecutionPolicy Bypass -File lib\\tests\\run_index_frame_tests.ps1  (tail only)
 4. Confirm .gitignore covers drilljig3d_probe_report.txt and slotplane_probe_report.txt (grep .gitignore;
    if not, note it -- do NOT edit files, just report).
Report a crisp PASS/FAIL per item with the exact command output tail.`,
  {
    label: 'verify',
    phase: 'Verify',
    schema: {
      type: 'object', additionalProperties: false,
      required: ['parseResults', 'curvedSuite', 'regression', 'gitignore', 'overall', 'fixesNeeded'],
      properties: {
        parseResults: { type: 'array', items: { type: 'string' } },
        curvedSuite: { type: 'string' },
        regression: { type: 'string' },
        gitignore: { type: 'string' },
        overall: { type: 'string', enum: ['all-green', 'issues'] },
        fixesNeeded: { type: 'array', items: { type: 'string' } },
      },
    },
  }
)

return { built, verify }
