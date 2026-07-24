export const meta = {
  name: 'curved-jig-parity-map',
  description: 'Map every flat drill-jig subsystem to its curved-jig equivalent + settle load-bearing API/geometry feasibility, then synthesize a parity matrix + phased plan',
  phases: [
    { title: 'Investigate', detail: '7 parallel investigators: each subsystem contract + 3D gap + feasibility' },
    { title: 'Adversarial', detail: 'skeptic pass on the two load-bearing unknowns (normal read, on-surface points)' },
    { title: 'Synthesize', detail: 'parity matrix + phased plan + risk register' },
  ],
}

// The user's architecture (embed in every investigator so they design TOWARD it):
const ARCH = `
USER'S ARCHITECTURE for the curved drill jig (design toward this, do not re-litigate):
1. SURFACE / PART CREATION: already implemented in drilljig3d.cmd STAGE 1 (offset-surface
   at standoff + thicken -> new conformal body). Confirmed live 2026-06-24. Reuse as-is.
2. FASTENER READING: same idea as the flat DJ fastener import, BUT the fasteners are no
   longer perpendicular to a fixed axis. We CAN read each fastener's core position AND
   derive its ANGLE relative to the original (OG) part coordinate system (proven: the flat
   fastener read + the "reorient normal" work established the axis/transform read is
   reliable). So the curved layout carries per-hole POSITION + ORIENTATION (angularity).
3. HOLE CREATION: same as flat -- holes positioned RELATIVELY, then drilled THROUGH the
   curved surface as THROUGH-HOLES (normal to the surface at each point). drilljig3d STAGE 2
   already drills On-Point holes normal-to-surface via surface pre-select (confirmed live).
4. SLOT RELIEF: ask the user to draw ONE rectangle on an OFFSET PLANE that is NORMAL to the
   curved surface at one hole, then REPLICATE it at every hole. KEY INSIGHT: because the
   holes are located via intersecting PLANES anyway, those planes ALREADY EXIST to host the
   sketch -- no new plane machinery needed for the common case.

The GOAL: bring the curved jig (drilljig3d) to full parity with the flat jig (drilljig.cmd /
drilljig-gui.cmd): bushing+hole selection via the decision tree, orthogrid/custom/fastener
layout, index-hole csys, slot relief, coordinate export -- adapted to a curved face.
`

const REPO = 'C:\\\\Users\\\\mmohapatra\\\\ngs-orthogrid-automation'

const INVESTIGATORS = [
  {
    key: 'surface-and-hole',
    title: 'Surface build + through-hole normal creation',
    focus: `Read drilljig3d.cmd IN FULL. Document the EXACT proven contract of STAGE 1
(offset+thicken -> new body; Get-OffsetThickenMacro; regenerative dimensioning; body diff)
and STAGE 2 (Build-NormalHoleMacro; per-hole orientation surface; the blind-eval gate).
Then answer for the CURVED HOLE-CREATION goal:
 - Is the "surface pre-select orients the On-Point hole normal" hypothesis confirmed or still
   a visual check? Cite the code + docs\\drilljig3d_improvements.md open questions.
 - For a hole to be placed at a RELATIVE position on a curved face and drilled through it
   normal to the surface: what proven primitives exist? (On-Point needs a datum point ON or
   near the surface. How are curved-face points created today vs the flat 3-plane
   intersection?) What's the gap to positioning holes at arbitrary relative (u,v)-like
   coordinates on the curved face?
 - Does the flat pipeline's 3-plane-intersection point creation (Get-SharedPlanePlan /
   Build-IntersectPointMacro in lib\\orthogrid_points.ps1) transfer to a curved face, or does
   a curved layout need points created a different way (e.g. offset-from-surface datum points,
   or the fastener csys/transform)? Be concrete about what is proven vs unproven.`,
  },
  {
    key: 'fastener-angularity',
    title: 'Fastener reading with angularity (position + orientation)',
    focus: `Read lib\\fastener_layout.ps1 IN FULL and lib\\creo_geometry.ps1
Read-FastenerCentersFromModel + Get-CylinderAxes + Get-CylinderAxisFromSurface, and the
fastener sections of CLAUDE.md and memory\\project_fastener_layout.md.
The flat import PROJECTS fasteners onto a best-fit plane and drops the normal (planar layout).
The CURVED goal KEEPS per-hole orientation (angularity vs OG csys). Answer:
 - What per-fastener data is already read? (position via component-path transform origin /
   cylinder-axis origin; axis direction via GetZAxis / GetTransform). Is the per-fastener AXIS
   DIRECTION reliably readable, or was it found unreliable (the (1,0,0)-in-plane finding)?
 - For a CURVED jig we do NOT want to flatten. Design the data contract for a curved layout:
   a list of per-hole {position(x,y,z), axis-direction(x,y,z) or angles vs OG csys}. What in
   FL-* / Get-FastenerPlaneFrame is reusable, what must change (skip the plane projection)?
 - How would each fastener's ANGLE relative to the OG coordinate system be derived and
   represented? (direction cosines? two angles?) What is proven-readable vs docs-only?
 - Does drilling normal-to-SURFACE (user's hole model) conflict with drilling along the
   fastener AXIS (angularity)? Which orientation wins per hole, and can both be supported?`,
  },
  {
    key: 'slot-relief-curved',
    title: 'Slot relief on a normal-plane, replicated per hole',
    focus: `Read the slot machinery: lib\\drilljig_core.ps1 (Build-CutFinishMacro,
Build-SlotPatternMacro, New-SlotGuidePlanes, Invoke-VerifiedSeedCut,
Invoke-SlotPatternFromSeed, Select-FeatureById) and slotinator.cmd, and the SLOT sections of
CLAUDE.md + memory\\project_chip_relief_pocket.md.
The flat slot = one blind rectangular remove-material slot per hole ROW, seed-drawn on the
SIDE face + patterned along a datum normal.
The user's CURVED slot model: draw ONE rectangle on an OFFSET PLANE NORMAL to the curved
surface at one hole, then REPLICATE at every hole -- and the planes used to LOCATE the holes
already exist to host that sketch. Answer:
 - What exactly does Build-CutFinishMacro do (remove_material_cb, depth field, body page)?
   Does it transfer verbatim to a sketch on a normal-plane of a curved face?
 - The flat pattern is a DIRECTION pattern (Build-SlotPatternMacro: ui_pat_dir_* fed a datum
   plane by ID). On a curved face the holes are NOT colinear/coplanar in one direction, so a
   single-direction linear pattern won't replicate a seed to arbitrary curved positions.
   What are the options? (per-hole individual seed cut vs a reference pattern vs feature copy)
   Cite what is proven (Invoke-SlotPatternFromSeed raw-COM reselect; the VB-docs finding that
   there is NO programmatic pattern/copy API) and what the honest fallback is (draw/place N
   seeds).
 - "the holes are located through planes anyways, so those planes already exist for the
   sketch": is that TRUE for the curved case? On the curved face are holes located by
   intersecting planes (like flat) or by offset-from-surface points? If planes exist per hole,
   which plane is 'normal to the curved surface at that hole' and can a sketch be opened on it
   by ID (ProCmdDatumSketCurve / the extrude-internal sketch)?`,
  },
  {
    key: 'decision-tree-bushing',
    title: 'Decision tree + bushing/hole selection reuse',
    focus: `Read the STAGE 1 decision-tree + bushing-pick machinery shared in
lib\\drilljig_core.ps1 (Get-CatalogSpec, Get-OdGroups, Resolve-OdBushingPick,
Get-BushingLengthOptions, Resolve-BushingPickRow, Resolve-CustomOdPick,
Get-IndexRelativeCustomGeometry) and how drilljig.cmd STAGE 1 + drilljig-gui.cmd 'tree' stage
consume them. Also read jiginator.cmd/.ps1 briefly.
drilljig3d TODAY only reads last_jig_spec.json for a diameter. The goal is FULL bushing+hole
selection parity. Answer:
 - Is the decision-tree walk / bushing pick PURE (no Creo) and therefore directly reusable in
   a curved-jig front-end with ZERO change? What produces holeDia + bushingLen and how do they
   map to a curved jig (bushingLen = wall thickness instead of plate thickness?).
 - What is the cleanest way to give drilljig3d the SAME tree UX: (a) console reuse of the STAGE
   1 block, (b) a GUI wizard stage like drilljig-gui. Enumerate the shared functions a curved
   front-end would call verbatim.
 - Counterbore/bushing-seat for a curved jig (drilljig3d_improvements 'bigger bets'): is a
   stepped bore in scope for parity, and what's proven?`,
  },
  {
    key: 'layout-grid-on-curved',
    title: 'Orthogrid / custom layout mapped onto a curved face',
    focus: `Read lib\\orthogrid.ps1 (Get-OrthogridGeometry, Get-CustomPointsGeometry,
Get-IndexRelativeCustomGeometry, Get-HoleBoundingRect), lib\\orthogrid_gui.ps1,
lib\\orthogrid_points.ps1 (Get-SharedPlanePlan, Build-IntersectPointMacro), and the STAGE 2.5
sections of drilljig.cmd + CLAUDE.md.
Flat layouts produce {X;Z} points on a plane, then 3-plane intersections. Answer:
 - Which layout MATH is pure/reusable as-is (the {X;Z} generation, validity, collision, edge
   margin)? The hard part per the roadmap: 'an orthogonal X/Z grid does not map cleanly onto a
   curved face.' Enumerate the concrete options to place a grid of points ON a curved face:
   (a) project planar {X;Z} points onto the surface (need a project-point-to-surface primitive
   -- proven?), (b) datum points offset from the surface, (c) fastener-driven only (no synthetic
   grid). Which is achievable with proven primitives, which is docs-only/unproven?
 - Does the flat 3-plane-intersection point creation land points ON the curved face or only in
   space? For a curved jig the points must sit on/normal-to the face for On-Point drilling.
 - What is the honest MVP: fastener-import layout (real positions) first, synthetic grid later?`,
  },
  {
    key: 'index-export-parity',
    title: 'Index-hole csys + coordinate export on a curved jig',
    focus: `Read the index-csys + export machinery in lib\\drilljig_core.ps1
(Invoke-IndexCsys, Build-CsysFromPlanesMacro, Resolve-IndexHolePlanes, Get-HolesRelativeToIndex,
Export-IndexHoleCsv, Invoke-BaseCsys, Invoke-OutputCsys) and the STAGE 5/5.5/6/7 sections of
CLAUDE.md. Also memory\\project_index_frame.md + csysinator.cmd.
Flat index csys is built from the 3 intersecting planes of the index hole; export coords are
pure math (gridX-indexX, 0, gridZ-indexZ). Answer:
 - On a curved jig, holes are NOT on one plane and NOT located by a shared 3-plane grid.
   Does the 3-plane-intersection csys transfer? What builds a csys at a curved-face hole
   (the fastener transform? a point + surface normal?)?
 - Coordinate export: the flat math assumes a planar grid. For curved holes with real 3D
   positions + orientations, what should the export contain (3D xyz + direction per hole, in
   the index frame)? Is Get-HolesRelativeToIndex reusable if fed real 3D coords?
 - Is index-csys parity a Phase-2 nicety or core? Recommend sequencing.`,
  },
  {
    key: 'gui-and-tests',
    title: 'GUI front-end + test harness parity',
    focus: `Read lib\\wizard.ps1 (framework), the drilljig-gui.cmd stage structure (breadcrumb
Import/Bushing/Layout/Overview/Datums/Box/Drill/Relief/Index/Done), and the test suites
lib\\tests\\run_wizard_tests.ps1, run_orthogrid_tests.ps1, run_fastener_tests.ps1,
run_csys_tests.ps1, fuzz_gui.ps1 (just their structure/what they cover). Also
memory\\project_gui_scope_bugs.md + project_drilljig_gui.md + project_3d_preview.md.
Answer:
 - drilljig3d is console-only. For parity it likely needs a wizard GUI too. Can lib\\wizard.ps1
   host a curved-jig flow with the SAME stages (swapping Box->SurfaceBuild, adding a curved
   layout stage)? What's reusable verbatim vs new?
 - The 3D preview work (project_3d_preview.md, drilljig-3d-webview.cmd, wpf3d_preview.ps1):
   how does a curved surface + angled holes render? Is the preview reusable or does curvature
   break Build-JigModelGroup?
 - What OFFLINE test coverage must a curved-jig effort add (pure-math layout-on-curved,
   angularity math, per-hole slot planning)? What are the known GUI scope traps to avoid
   (project_gui_scope_bugs.md: closure captures locals, $script: invisible in GetNewClosure,
   session rebind at each OnNext)?`,
  },
]

phase('Investigate')
const findings = await parallel(INVESTIGATORS.map(inv => () =>
  agent(
    `You are investigating ONE subsystem for a project that brings a CURVED (conformal) drill-jig
tool to full functional parity with the proven FLAT drill-jig tools, inside this repo:
  ${REPO}

${ARCH}

Your subsystem: ${inv.title}

${inv.focus}

Work in the repo. Read the actual files (use Read/Grep/Glob). Do NOT modify anything -- this is
read-only investigation. Cite file:line for every load-bearing claim. Distinguish PROVEN-LIVE vs
CONFIRMED-in-code vs DOCS-ONLY vs UNPROVEN/GUESS. Where something is unproven, say what live
recording or probe would settle it (mirror the repo's *-probe.cmd methodology).

Return a structured finding for this subsystem.`,
    {
      label: inv.key,
      phase: 'Investigate',
      agentType: 'Explore',
      schema: {
        type: 'object',
        additionalProperties: false,
        required: ['subsystem', 'flatContract', 'curvedGap', 'reusableVerbatim', 'newWork', 'feasibility', 'openQuestions', 'recommendation'],
        properties: {
          subsystem: { type: 'string' },
          flatContract: { type: 'string', description: 'The exact proven contract of the flat subsystem, with file:line cites' },
          curvedGap: { type: 'string', description: 'What is missing/different for the curved case, per the user architecture' },
          reusableVerbatim: { type: 'array', items: { type: 'string' }, description: 'Functions/files reusable with ZERO change (name + why)' },
          newWork: { type: 'array', items: { type: 'string' }, description: 'Concrete new functions/macros/recordings needed' },
          feasibility: {
            type: 'array',
            items: {
              type: 'object', additionalProperties: false,
              required: ['claim', 'status', 'evidence'],
              properties: {
                claim: { type: 'string' },
                status: { type: 'string', enum: ['proven-live', 'confirmed-in-code', 'docs-only', 'unproven-guess'] },
                evidence: { type: 'string', description: 'file:line or fact id or probe that would settle it' },
              },
            },
          },
          openQuestions: { type: 'array', items: { type: 'string' } },
          recommendation: { type: 'string', description: 'MVP-first sequencing for THIS subsystem' },
        },
      },
    }
  ).then(r => ({ key: inv.key, title: inv.title, finding: r }))
)).then(rs => rs.filter(Boolean))

// ---- Adversarial pass on the two load-bearing unknowns -------------------
phase('Adversarial')
const LOADBEARING = [
  {
    key: 'skeptic-normal-read',
    q: `LOAD-BEARING UNKNOWN #1: "We can read each fastener's core position AND its angle vs
the OG csys, AND we can drill a hole normal to a curved surface." The whole curved jig depends
on this. Adversarially VERIFY or REFUTE against the actual repo evidence:
 - Is surface-normal / fastener-axis direction ACTUALLY reliably readable on this Creo build,
   or is there a refuting finding? (Check: plane-descriptor-getzaxis-null fact; the
   (1,0,0)-in-plane fastener finding in memory\\project_fastener_layout.md; Get-CylinderAxes
   uses GetZAxis on a CYLINDER descriptor -- does that generalize to arbitrary surface normal?)
 - Does "surface pre-select orients the On-Point hole normal" have a confirmed-live fact, or is
   it still the drilljig3d_improvements.md open question #1?
 - Eval3DData(EvalParameters(p)).Normal for a true surface normal at a point: proven or
   docs-only, and does it work on IpfcForeignSurface?
State the VERDICT (confirmed / partially / refuted / needs-probe) and the EXACT probe that
settles each piece.`,
  },
  {
    key: 'skeptic-points-on-curved',
    q: `LOAD-BEARING UNKNOWN #2: "Holes can be positioned relatively on the curved face and the
planes that locate them already exist to host the slot sketch." Adversarially VERIFY or REFUTE:
 - How are datum points created ON a curved face today? The flat 3-plane-intersection lands a
   point in SPACE at plane intersections -- does that put a point ON the curved surface, or
   would On-Point drilling then miss the face? Is there a proven "point on surface" or
   "point offset from surface" primitive?
 - For the fastener-import path the positions are READ from existing fasteners -- do we even
   need to CREATE points, or do we drill at the existing fastener locations / at datum points
   we place from the read transforms? What's proven for placing a datum point at a known 3D
   transform (Build-CsysOffsetPointsMacro is docs-only/guess -- confirm)?
 - "the planes already exist for the slot sketch": trace whether the curved hole-placement
   actually produces a plane normal to the surface at each hole. If not, what creates that
   normal offset plane, and is opening a sketch on it by ID proven?
State the VERDICT + the exact probe/recording that settles each piece.`,
  },
]
const skeptic = await parallel(LOADBEARING.map(s => () =>
  agent(
    `Repo: ${REPO}\n${ARCH}\n\n${s.q}\n\nRead the actual files + memory + lib\\creo_api_facts.json.
Be a skeptic: the cost of a false "proven" here is weeks of building on sand. Cite file:line /
fact id for every claim.`,
    {
      label: s.key,
      phase: 'Adversarial',
      agentType: 'Explore',
      schema: {
        type: 'object', additionalProperties: false,
        required: ['unknown', 'verdict', 'evidence', 'probeToSettle', 'mvpImplication'],
        properties: {
          unknown: { type: 'string' },
          verdict: { type: 'string', enum: ['confirmed', 'partially-confirmed', 'refuted', 'needs-probe'] },
          evidence: { type: 'array', items: { type: 'string' } },
          probeToSettle: { type: 'string', description: 'The exact *-probe.cmd / visible_mapkeys recording that settles it' },
          mvpImplication: { type: 'string', description: 'What the MVP should assume given the verdict' },
        },
      },
    }
  ).then(r => ({ key: s.key, result: r }))
)).then(rs => rs.filter(Boolean))

// ---- Synthesis -----------------------------------------------------------
phase('Synthesize')
const findingsJson = JSON.stringify(findings, null, 1)
const skepticJson = JSON.stringify(skeptic, null, 1)

const plan = await agent(
  `You are the architect. ${ARCH}

Repo: ${REPO}

You have 7 subsystem investigations and 2 adversarial verdicts on the load-bearing unknowns.
Synthesize a SINGLE implementation plan to bring the curved drill jig (drilljig3d) to parity
with the flat jig, following the user's architecture. Be concrete and honest: separate what is
PROVEN and can be built now from what needs a live probe/recording first.

SUBSYSTEM FINDINGS:
${findingsJson}

ADVERSARIAL VERDICTS:
${skepticJson}

Produce the plan. The phasing MUST be MVP-first: the earliest phase should deliver end-to-end
value using ONLY proven primitives (the user's steer: surface build is done, fastener read is
proven, through-hole normal drilling exists, slot = draw-once-replicate). Later phases add the
harder parity (synthetic grid on curved, index csys, GUI, counterbore) and are explicitly gated
on the probes that must fire first. For each phase list the exact files/functions to create or
change, which proven primitive each reuses, and the offline tests to add. Call out every place a
live Creo recording/probe is a prerequisite, naming the probe (mirror the repo's *-probe.cmd
pattern).`,
  {
    label: 'architect',
    phase: 'Synthesize',
    schema: {
      type: 'object', additionalProperties: false,
      required: ['parityMatrix', 'loadBearingVerdicts', 'phases', 'probesNeeded', 'risks', 'mvpDefinition', 'recommendation'],
      properties: {
        parityMatrix: {
          type: 'array',
          items: {
            type: 'object', additionalProperties: false,
            required: ['subsystem', 'flatStatus', 'curvedStatus', 'gapSummary'],
            properties: {
              subsystem: { type: 'string' },
              flatStatus: { type: 'string' },
              curvedStatus: { type: 'string', enum: ['done', 'partial', 'reuse-verbatim', 'needs-build', 'needs-probe-first', 'phase-2'] },
              gapSummary: { type: 'string' },
            },
          },
        },
        loadBearingVerdicts: { type: 'array', items: { type: 'string' } },
        phases: {
          type: 'array',
          items: {
            type: 'object', additionalProperties: false,
            required: ['phase', 'goal', 'deliverable', 'filesAndFunctions', 'reusesProven', 'offlineTests', 'liveGate', 'blockedByProbe'],
            properties: {
              phase: { type: 'string' },
              goal: { type: 'string' },
              deliverable: { type: 'string' },
              filesAndFunctions: { type: 'array', items: { type: 'string' } },
              reusesProven: { type: 'array', items: { type: 'string' } },
              offlineTests: { type: 'array', items: { type: 'string' } },
              liveGate: { type: 'string', description: 'what to verify live before the phase is trusted' },
              blockedByProbe: { type: 'string', description: 'probe name that must fire first, or "none"' },
            },
          },
        },
        probesNeeded: {
          type: 'array',
          items: {
            type: 'object', additionalProperties: false,
            required: ['probe', 'settles', 'mirrors'],
            properties: {
              probe: { type: 'string' },
              settles: { type: 'string' },
              mirrors: { type: 'string', description: 'existing *-probe.cmd it mirrors' },
            },
          },
        },
        risks: { type: 'array', items: { type: 'string' } },
        mvpDefinition: { type: 'string' },
        recommendation: { type: 'string' },
      },
    },
  }
)

return { findings, skeptic, plan }
