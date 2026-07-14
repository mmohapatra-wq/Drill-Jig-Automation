/* =====================================================================
   FSAE Thermal Academy — curriculum data
   Content is adversarially-verified (8 research topics, 77 fact-checks).
   Every module bridges a real BE-3U rocket-engine thermal-model concept
   to a Formula Student EV cooling / aero design decision.
   Math strings use a tiny inline notation rendered by index.html:
     ^{...} superscript, _{...} subscript, *  → ·, plain text otherwise.
   ===================================================================== */
window.BRIDGE_TABLE = [
  { rocket: "Nodal SINDA network (nodes + conductors)", fsae: "Lumped thermal model of pack / motor / inverter / coolant", physics: "First-law energy balance C·dT/dt = ΣG·ΔT + Q at each node" },
  { rocket: "Contactors across bolted flanges, brazing, bearings", fsae: "Cell-to-cold-plate TIM joint, motor-to-mount interface", physics: "Contact conductance R = 1/(h_c·A); empirical, pressure/finish dependent" },
  { rocket: "Dittus-Boelter HTC on LH2/LOx ducts", fsae: "HTC inside battery/inverter cold-plate channels", physics: "Nu = 0.023·Re^0.8·Pr^n → h = Nu·k/D_h" },
  { rocket: "Forced convection over flat plate / around cylinder (interstage)", fsae: "Air over bodywork, radiator tubes, exposed components", physics: "Boundary-layer Nu(Re,Pr); same Re that drives aero drag" },
  { rocket: "Engine-balance fluid network scaled by ṁ·cp", fsae: "Water-glycol coolant loop carrying powertrain heat", physics: "Advected energy Q = ṁ·cp·ΔT between bulk-fluid nodes" },
  { rocket: "Surface-to-surface + orbital radiation (radks, α/ε)", fsae: "Brake-rotor glow, hot-pack IR, sun soak in the paddock", physics: "q = ε·σ·(T^4 − T_surr^4); matters when hot or still" },
  { rocket: "Biot-number / through-thickness mesh-sensitivity study", fsae: "How finely to mesh a cell stack or cold plate", physics: "Bi = h·L_c/k; <0.1 lump, ≥0.1 must discretize" },
  { rocket: "Hot/Cold Design-Day transient CONOPS", fsae: "Worst-case hot-ambient endurance lap (heat soak)", physics: "Transient T(t) toward steady state, time constant τ = m·cp/(h·A)" },
  { rocket: "Nozzle/TCA heat rejection to a coolant", fsae: "Radiator sizing to reject motor+inverter waste heat", physics: "ε-NTU / LMTD heat-exchanger sizing, UA = NTU·C_min" },
];

window.MODULES = [
  /* ============================ MODULE 1 ============================ */
  {
    id: "modes",
    title: "Heat-Transfer Modes & the Resistance Network",
    tag: "Foundations",
    physics: [
      "Heat moves three ways and a thermal model is just a bookkeeping of those paths. **Conduction** carries heat through solids and still fluids down a temperature gradient (Fourier's law). **Convection** carries it between a surface and a moving fluid (Newton's law of cooling). **Radiation** carries it as electromagnetic waves and needs no medium at all (Stefan-Boltzmann).",
      "The single most useful idea in the whole field is the **electrical analogy**: a temperature difference ΔT is like a voltage, a heat rate Q̇ is like a current, and every path has a **thermal resistance** R such that ΔT = Q̇·R. Resistances in a single heat path add in **series** (R_total = ΣR_i); parallel heat paths combine like parallel resistors (1/R_total = Σ1/R_i).",
      "This is exactly how a SINDA/Thermal Desktop model is built: lumps of mass (nodes) joined by conductors (G = 1/R). Once you can draw the resistor network for a problem, you can solve it — and that single skill carries from a rocket engine to a battery pack unchanged.",
    ],
    equations: [
      { name: "Conduction (Fourier)", formula: "Q̇ = (k·A/L)·ΔT  ⇒  R_cond = L/(k·A)", variables: "k = solid conductivity [W/m·K]; A = area normal to flow [m²]; L = path length [m]", validity: "1-D steady conduction, constant A" },
      { name: "Convection (Newton)", formula: "Q̇ = h·A·ΔT  ⇒  R_conv = 1/(h·A)", variables: "h = convective coefficient [W/m²·K]; A = wetted area [m²]", validity: "Uniform h and surface temperature" },
      { name: "Radiation (linearized)", formula: "Q̇ ≈ h_r·A·ΔT,  h_r = 4·ε·σ·T_m^3", variables: "ε = emissivity; σ = 5.67e-8 W/m²·K⁴; T_m = mean abs. temp [K]", validity: "Small ΔT about T_m (near-ambient)" },
      { name: "Series / parallel", formula: "Series R = ΣR_i ;  Parallel 1/R = Σ1/R_i", variables: "Combine path resistances; overall Q̇ = ΔT_total / R_total", validity: "1-D, Ohm's-law analogy" },
    ],
    rocket_anchor: "The BE-3U model strings these primitives together literally: a copper TCA liner conducts to the steel jacket (R_cond), the regen coolant convects heat off the hot wall (R_conv via a Dittus-Boelter HTC), and the engine externals radiate to space (R_rad). Each appears in the model as a conductor with units BTU/hr·°F — a thermal conductance G = 1/R.",
    fsae_bridge: "Your battery cell rejecting heat is a **series stack of resistances**: cell core → thermal-interface material (R_contact) → cold-plate wall (R_cond) → coolant film (R_conv) → coolant. Add them up and ΔT = Q̇·R_total tells you how far above coolant temperature the cell core sits. If the cell makes 3 W and R_total = 2.5 K/W, the core runs 7.5 K hotter than the coolant — that margin is your whole thermal design.",
    worked_example: "A 21700 cell dissipates Q̇ = 2.5 W. Paths to the cold plate: TIM contact R₁ = 1.2 K/W, aluminum wall conduction R₂ = 0.3 K/W, coolant convection R₃ = 0.8 K/W (all in series). R_total = 1.2 + 0.3 + 0.8 = 2.3 K/W. Core-to-coolant rise ΔT = Q̇·R_total = 2.5 × 2.3 = 5.75 K. If the coolant is 40 °C, the cell core sits at ≈ 45.8 °C — safely under the 60 °C limit, with the TIM joint (R₁) being the dominant resistance worth improving first.",
    calc: "resistanceChain",
    quiz: [
      { q: "In a series thermal path (TIM → wall → coolant film), which resistance most controls the cell temperature?", options: ["The smallest one", "The largest one", "They all matter equally regardless of value", "Only the convective one"], answer: 1, explanation: "Series resistances add, so the LARGEST term dominates ΔT. Here the TIM contact resistance is biggest, so improving the interface material buys the most." },
      { q: "Thermal resistance of pure convection over area A with coefficient h is:", options: ["h·A", "1/(h·A)", "h/A", "A/h"], answer: 1, explanation: "R_conv = 1/(h·A). Bigger area or higher h ⇒ lower resistance ⇒ easier heat removal." },
      { q: "Why can radiation usually be treated as a parallel 'convection-like' resistor near room temperature?", options: ["Because radiation is always negligible", "Because the T^4 law linearizes to h_r·ΔT for small ΔT", "Because air carries the photons", "Because emissivity is always 1"], answer: 1, explanation: "For small ΔT about a mean T_m, q = εσ(T⁴−T_surr⁴) ≈ h_r·ΔT with h_r ≈ 4εσT_m³ (~5 W/m²K at 300 K) — a resistor in parallel with convection." },
    ],
  },

  /* ============================ MODULE 2 ============================ */
  {
    id: "conduction",
    title: "Conduction & Contact Conductance Across Joints",
    tag: "Foundations",
    physics: [
      "Inside a solid, heat obeys Fourier's law and the resistance is R = L/(k·A): long thin paths and low-conductivity materials resist heat. Copper (k≈400 W/m·K) is a heat superhighway; stainless steel (~15) and titanium (~7) are bottlenecks; foams and G10 are near-insulators.",
      "The subtle, design-critical part is the **joint**. When two parts are bolted or clamped together, they only touch at microscopic asperities, so heat must funnel through tiny real contact spots. This gives a **thermal contact resistance** R_contact = 1/(h_c·A), where the contact conductance h_c depends on contact pressure, surface finish, the interstitial material (air, grease, TIM), and whether you're in air or vacuum.",
      "Because h_c is empirical and uncertain, it's one of the conductances thermal engineers deliberately **tune against test data**. A bolted flange isn't a single number you can look up — it's a number you anchor to a measured temperature drop.",
    ],
    equations: [
      { name: "Plane-wall conduction", formula: "R_cond = L/(k·A)", variables: "L = thickness [m]; k = conductivity [W/m·K]; A = area [m²]", validity: "1-D, constant A and k" },
      { name: "Radial (tube) conduction", formula: "R_cond = ln(r₂/r₁)/(2π·k·L)", variables: "r₁,r₂ = inner/outer radius; L = tube length", validity: "Radial 1-D through a cylinder wall" },
      { name: "Contact conductance", formula: "R_contact = 1/(h_c·A)", variables: "h_c = joint conductance [W/m²·K] (empirical); A = nominal interface area", validity: "Imperfect solid-solid interface" },
    ],
    rocket_anchor: "The BE-3U engine model carries a whole table of **contactors** with conductances in BTU/hr·°F: bolted flanges (e.g. LH2 HP duct ↔ MFV at 227 BTU/hr·°F), brazing (TCA liner ↔ MCC at a huge 149,832 — brazing is almost a short circuit), bearings, and Teflon/G10 spacers used deliberately as thermal isolators. Each is a real joint whose conductance was characterized so the model predicts the right interface temperature.",
    fsae_bridge: "Your battery module bolts cells (or busbars) to a cold plate through a thermal-interface pad. That pad IS the contactor. A pad with h_c = 2000 W/m²·K over a 30 cm² contact gives R = 1/(2000 × 0.003) = 0.17 K/W — but squeeze pressure, flatness, and pad choice can swing it 3–5×. The same lesson applies to motor-to-upright mounting and inverter baseplate-to-cold-plate: the joint, not the metal, is usually the hidden bottleneck.",
    worked_example: "Inverter baseplate to cold plate: aluminum (k=200) interface 120 mm × 80 mm, with a TIM of conductance h_c = 5000 W/m²·K. Area A = 0.12 × 0.08 = 0.0096 m². Contact resistance R_contact = 1/(5000 × 0.0096) = 0.0208 K/W. If the inverter sheds 1.5 kW through this joint, ΔT = 1500 × 0.0208 = 31 K across the TIM alone — large enough that a better pad (higher h_c) or more clamping pressure directly lowers the junction temperature.",
    calc: "conduction",
    quiz: [
      { q: "Brazing the TCA liner to the chamber gives a conductance of ~149,832 BTU/hr·°F. In resistance terms this joint is:", options: ["A near-open circuit (huge resistance)", "A near-short circuit (tiny resistance)", "Irrelevant to the model", "A radiation path"], answer: 1, explanation: "High conductance G = low resistance R = 1/G. Brazing bonds the parts almost perfectly, so heat passes with little temperature drop — a thermal short." },
      { q: "Why is contact conductance h_c treated as a tunable, test-anchored value rather than a handbook constant?", options: ["It never matters", "It depends on pressure, finish, interstitial medium and vacuum/air", "It equals the bulk conductivity", "It is set by emissivity"], answer: 1, explanation: "Real joints touch only at asperities; the effective h_c depends on many hard-to-predict factors, so engineers correlate it to measured ΔT." },
      { q: "A G10 or Teflon spacer in the engine is used as a deliberate:", options: ["Thermal short", "Thermal isolator (high resistance)", "Radiator", "Current path"], answer: 1, explanation: "Low-k polymers add large R_cond on purpose, blocking heat leak into temperature-sensitive hardware." },
    ],
  },

  /* ============================ MODULE 3 ============================ */
  {
    id: "convection",
    title: "Forced Convection: Dittus-Boelter & Gnielinski",
    tag: "Cooling Loop",
    physics: [
      "Convection coefficients aren't looked up — they're **computed** from three dimensionless groups. **Reynolds** Re = ρVL/μ is the inertia-to-viscosity ratio that sets the flow regime (in a pipe: laminar below ~2300, turbulent above ~4000). **Prandtl** Pr = ν/α = cp·μ/k compares how fast momentum vs heat diffuses (air ≈ 0.71, water ≈ 5.9 at 300 K, glycol mixes 10–30+). **Nusselt** Nu = hL/k is dimensionless HTC.",
      "The recipe is always: pick a correlation → get Nu(Re, Pr) → convert with **h = Nu·k/L**, where L is the same characteristic length the correlation was defined with. For non-circular cold-plate channels, use the **hydraulic diameter** D_h = 4A/P.",
      "Two workhorse turbulent-pipe correlations: **Dittus-Boelter** Nu = 0.023·Re^0.8·Pr^n (n = 0.4 when heating the fluid, 0.3 when cooling it) — simple, ±25%, valid Re ≳ 10⁴. **Gnielinski** is more accurate (±10%) and crucially valid down into the transitional band (Re ≥ 3000), which is exactly where cold-plate channels usually operate — so prefer it for liquid-loop design.",
    ],
    equations: [
      { name: "Reynolds number", formula: "Re = ρ·V·L/μ = V·L/ν", variables: "ρ density, V velocity, L (=D or D_h) length, μ viscosity, ν=μ/ρ", validity: "Pipe: laminar <2300, turbulent >~4000" },
      { name: "Prandtl number", formula: "Pr = ν/α = cp·μ/k", variables: "ν kinematic visc., α=k/(ρcp) thermal diffusivity", validity: "Fluid property; air≈0.71, water≈5.9 @300K" },
      { name: "Dittus-Boelter", formula: "Nu = 0.023·Re^0.8·Pr^n  (n=0.4 heat, 0.3 cool)", variables: "Then h = Nu·k/D_h", validity: "Re≳10⁴, 0.6≤Pr≤160, L/D≳10; ±25%" },
      { name: "Gnielinski", formula: "Nu = (f/8)(Re−1000)·Pr / [1 + 12.7√(f/8)·(Pr^{2/3}−1)],  f = (0.790·ln Re − 1.64)^{-2}", variables: "f = Darcy friction factor", validity: "3000≤Re≤5e6, 0.5≤Pr≤2000; ±10%" },
      { name: "Hydraulic diameter", formula: "D_h = 4A/P  (rect a×b: 2ab/(a+b))", variables: "A flow area, P wetted perimeter", validity: "Non-circular ducts" },
    ],
    rocket_anchor: "Every duct HTC in the BE-3U model is computed with **Dittus-Boelter**, scaled live by the propellant mass-flow registers (sc_mdot_Fuel/Oxidizer/Coolant). The doc lists HTC_Duct_HP_LOx, HTC_Duct_LP_LH2, etc., each a Dittus-Boelter coefficient that rises and falls with engine thrust. When the fluid goes single-phase the model switches to the Gnielinski subroutine — the same two correlations you'll use on a cold plate.",
    fsae_bridge: "A battery or inverter cold plate is a set of internal channels. Compute D_h for the channel cross-section, get Re from your pump flow and the (glycol-mix!) properties, then use Gnielinski to find h — because most cold-plate flows land at Re ≈ 3000–30000 where Dittus-Boelter is least accurate. That h sets R_conv = 1/(h·A), which sets how hot the silicon or cells run. Push pump flow up to stay turbulent: if a channel goes laminar, Nu locks to ~3.66–4.36 and HTC is poor no matter the geometry.",
    worked_example: "Water-glycol (ρ=1050, μ=0.0025 Pa·s, k=0.40 W/m·K, cp=3400, so Pr=cp·μ/k=21.3) flows at 0.05 kg/s through a 6 mm round cold-plate channel. V = ṁ/(ρ·A) = 0.05/(1050·π·0.003²) = 1.68 m/s. Re = ρVD/μ = 1050·1.68·0.006/0.0025 = 4234 (transitional → use Gnielinski). f = (0.790·ln4234 − 1.64)^-2 = 0.0400. Nu = (0.005)(3234)(21.3)/[1+12.7·0.0707·(21.3^{0.667}−1)] = 344/7.07 ≈ 48.7. h = Nu·k/D = 48.7·0.40/0.006 ≈ 3250 W/m²·K. (Dittus-Boelter would give Nu=0.023·4234^0.8·21.3^0.4 ≈ 0.023·797·3.42 ≈ 62.7 — ~30% higher, illustrating why the simple correlation over-predicts in this regime.)",
    calc: "convection",
    quiz: [
      { q: "For a cold-plate channel running at Re ≈ 5000, which correlation should you trust more?", options: ["Dittus-Boelter, it's simpler", "Gnielinski, it's valid and accurate in the transitional band", "Neither works below Re 10⁴", "Use the laminar Nu = 3.66"], answer: 1, explanation: "Re 5000 is transitional. Dittus-Boelter is only valid Re≳10⁴ and over-predicts here; Gnielinski is valid from Re 3000 and ±10%." },
      { q: "In Dittus-Boelter Nu = 0.023·Re^0.8·Pr^n, the exponent n is 0.4 when:", options: ["The fluid is being cooled", "The fluid is being heated", "Always 0.3", "Re < 2300"], answer: 1, explanation: "n = 0.4 for heating the fluid (wall hotter than fluid), n = 0.3 for cooling. A cold plate pulling heat OUT of coolant is heating the coolant → 0.4 at the wall." },
      { q: "Why convert Nu to h with h = Nu·k/D_h and not with the solid's conductivity?", options: ["k must be the FLUID conductivity — convection is about the boundary layer in the fluid", "It doesn't matter which k", "Use the wall metal's k", "Use the average of both"], answer: 0, explanation: "Nu compares convective to conductive transport IN THE FLUID, so k is always the fluid's thermal conductivity." },
    ],
  },

  /* ============================ MODULE 4 ============================ */
  {
    id: "transient",
    title: "Lumped Capacitance, the Biot Number & Mesh Sensitivity",
    tag: "Transient",
    physics: [
      "Can you treat a whole part as one uniform temperature, or must you slice it into layers? The **Biot number** Bi = h·L_c/k decides. It's the ratio of internal conduction resistance to surface convection resistance, with characteristic length L_c = V/A_s. **A flat plate convecting from BOTH faces has L_c = thickness/2; from one face only, L_c = full thickness** (long cylinder → D/4, sphere → D/6).",
      "If **Bi < 0.1**, internal conduction is at least ~10× easier than getting heat off the surface, so the body is essentially isothermal — a single 'lumped' node is accurate to within ~5%. The temperature then relaxes exponentially: T(t) = T∞ + (T_i − T∞)·e^{−t/τ}, with **time constant τ = m·cp/(h·A_s)**. One τ covers 63.2% of the swing; ~5τ ≈ steady state. τ = (thermal capacitance)·(convection resistance) — the direct thermal-RC analog.",
      "When **Bi ≥ 0.1** (e.g. very high h from boiling or aggressive liquid cooling), big internal gradients form. A single node then *under-predicts* the surface excursion — non-conservative for peak temperature. The fix is to **discretize through the thickness** into multiple finite-difference nodes and refine until the answer stops changing. This is exactly the Sinda-Fluint mesh-sensitivity study: with nucleate-boiling HTCs the Biot number is so high that node count had to climb before the model stopped being overly conservative.",
    ],
    equations: [
      { name: "Biot number", formula: "Bi = h·L_c/k_s,  L_c = V/A_s", variables: "h conv. coeff, k_s SOLID conductivity, L_c char. length", validity: "Bi<0.1 → lump (<~5% err); Bi≥0.1 → discretize" },
      { name: "Lumped transient", formula: "T(t) = T∞ + (T_i − T∞)·e^{−t/τ}", variables: "T_i initial, T∞ ambient/coolant temp", validity: "Bi<0.1, constant h & T∞" },
      { name: "Thermal time constant", formula: "τ = m·cp/(h·A_s) = C_th·R_conv", variables: "m mass, cp spec. heat, A_s convecting area", validity: "63.2% of swing at t=τ; ~99% at 5τ" },
    ],
    rocket_anchor: "The companion Sinda-Fluint page IS this lesson: a hot plate conducting into a cryo-wetted, pool-boiling surface. Nucleate-boiling HTCs are enormous (10⁴–10⁵ W/m²·K), driving Bi very high, so a coarse through-thickness mesh was wildly over-conservative. Sweeping node count showed conservatism dropping as the mesh refined — and the practical takeaway in the doc: approximate a high-node geometry with a two-node model that puts most of the mass toward the hot side.",
    fsae_bridge: "Compute Bi for a battery cell with your chosen cooling. Air cooling (low h) usually gives Bi < 0.1 → a single lumped node per cell is fine, and τ = m·cp/(h·A) tells you the pack's thermal inertia: how many minutes of an endurance run it takes to heat-soak toward its limit. Switch to a liquid cold plate (high h) on a thick cell stack and Bi climbs — now you must mesh through the stack or you'll under-predict the hot-spot cell and eat into your thermal-runaway margin. Brake rotors are always high-Bi: never lump them.",
    worked_example: "A 21700 cell: ~70 g, cp ≈ 1000 J/kg·K, surface A_s ≈ 0.0045 m², radius 10.5 mm so for radial cooling L_c ≈ R/2 ≈ 5.25 mm, cell radial k ≈ 1.5 W/m·K. Air cooling h ≈ 40 W/m²·K → Bi = 40·0.00525/1.5 = 0.14 (slightly above 0.1 — borderline, watch the core). Time constant τ = m·cp/(h·A) = 0.070·1000/(40·0.0045) = 70/0.18 = 389 s ≈ 6.5 min. Over a 25-min endurance (≈ 3.9τ) the cell reaches ~98% of its steady rise — so if steady-state predicts 55 °C, plan for it; the pack will get there before the race ends.",
    calc: "biot",
    quiz: [
      { q: "A cell cooled by a high-h liquid cold plate gives Bi = 0.4. The correct modeling choice is:", options: ["One lumped node — it's simpler", "Discretize through the thickness into multiple nodes", "Ignore conduction", "Assume steady state instantly"], answer: 1, explanation: "Bi ≥ 0.1 means significant internal gradients. A single node under-predicts the hot-spot; you must mesh through the thickness — the exact mesh-sensitivity lesson." },
      { q: "The thermal time constant τ = m·cp/(h·A) tells you:", options: ["The steady-state temperature", "How fast the body responds (how long to heat-soak)", "The Biot number", "The radiation load"], answer: 1, explanation: "τ is the response time: 63.2% of the temperature swing at t=τ, ~99% by 5τ. Large mass/cp = sluggish; large h·A = fast." },
      { q: "Why did high nucleate-boiling HTC force a finer mesh in the rocket study?", options: ["High h lowers Bi", "High h raises Bi, creating internal gradients a coarse mesh can't capture", "Boiling removes the need for nodes", "It doesn't affect meshing"], answer: 1, explanation: "Bi = hL/k rises with h. Huge boiling h ⇒ high Bi ⇒ steep internal gradients ⇒ a coarse/lumped mesh is over-conservative, so node count must increase." },
    ],
  },

  /* ============================ MODULE 5 ============================ */
  {
    id: "hx",
    title: "Radiator Sizing: LMTD & Effectiveness-NTU",
    tag: "Cooling Loop",
    physics: [
      "A radiator's job is set by an energy balance: Q̇ = ṁ·cp·ΔT on each stream (coolant gives up heat, air takes it). Define heat-capacity rates C = ṁ·cp; the smaller one is C_min, and C_r = C_min/C_max. On an FSAE car the **air side is usually C_min**.",
      "Two sizing methods. **LMTD** (Q̇ = U·A·F·LMTD) is best when you know all four terminal temperatures — a rating check. **Effectiveness-NTU** is best for *sizing*, because you know inlet temps and both flows but NOT the outlets. Define NTU = UA/C_min, max possible duty Q̇_max = C_min·(T_h,in − T_c,in), and effectiveness ε = Q̇/Q̇_max. Pick the ε-NTU relation for your flow arrangement — an automotive radiator is **crossflow, both fluids unmixed**.",
      "The overall conductance UA is a series of resistances: coolant-side film, wall, and air-side film. The **air side dominates** (low h ≈ 50–150 W/m²·K), which is why radiators are densely finned — fins multiply the air-side area to compensate. Size to the WORST case: low-speed endurance on a hot day, when ram air is weakest and the fan sets the airflow.",
    ],
    equations: [
      { name: "Stream energy balance", formula: "Q̇ = ṁ·cp·ΔT  (each stream)", variables: "Both streams carry the same Q̇ at steady state", validity: "Single phase, steady" },
      { name: "NTU & effectiveness", formula: "NTU = UA/C_min ;  ε = Q̇/Q̇_max ;  Q̇_max = C_min·(T_h,in − T_c,in)", variables: "C_r = C_min/C_max", validity: "General" },
      { name: "ε — crossflow both unmixed (radiator)", formula: "ε = 1 − exp{ (1/C_r)·NTU^{0.22}·[exp(−C_r·NTU^{0.78}) − 1] }", variables: "Invert numerically for NTU given ε", validity: "Auto tube-and-fin core; ±~1%" },
      { name: "ε — counterflow", formula: "ε = [1 − e^{−NTU(1−C_r)}] / [1 − C_r·e^{−NTU(1−C_r)}]", variables: "C_r<1; ε=NTU/(1+NTU) if C_r=1", validity: "Ideal counterflow (over-predicts a radiator)" },
      { name: "LMTD", formula: "Q̇ = U·A·F·LMTD,  LMTD = (ΔT₁−ΔT₂)/ln(ΔT₁/ΔT₂)", variables: "F crossflow correction (<1)", validity: "All terminal temps known" },
    ],
    rocket_anchor: "The BE-3U engine rejects its regen-circuit heat to the propellant — the doc's coolant path conductors (Path Coolant 01–10) are a distributed heat exchanger between the hot wall and the LH2 coolant, scaled by ṁ·cp. Same energy balance, same ε-NTU machinery you'll use to size a radiator; the engine just uses cryogenic propellant as its 'cold side.'",
    fsae_bridge: "Size the radiator with ε-NTU because you know coolant-in temp, ambient, and both flows but not the outlets. Model it as crossflow-both-unmixed (counterflow over-predicts and would undersize your core). The air side is C_min and dominates UA — so fan/duct/ram-air design matters as much as core size. The required frontal area feeds packaging (sidepod vs nose) and couples straight into the cooling-drag tradeoff in Module 9.",
    worked_example: "Reject Q̇ = 8 kW. Coolant (50/50 glycol) ṁ=0.30 kg/s, cp=3400 → C_h=1020 W/K, T_h,in=65 °C. Air ṁ=0.45 kg/s, cp=1007 → C_c=453 W/K (=C_min), T_c,in=35 °C. C_r=453/1020=0.444. Q̇_max=453·(65−35)=13.6 kW. Required ε=8000/13590=0.589. Invert the crossflow-both-unmixed relation at C_r=0.444: **NTU≈1.12** (not 1.05 — the naive read is low). UA=NTU·C_min=1.12·453≈**508 W/K**. At a typical core conductance ~1500 W/K per m² frontal, A_front≈508/1500≈**0.34 m²** (~0.55 m × 0.62 m, or split dual sidepods). Outlet check: air exits 35+8000/453=52.7 °C, coolant exits 65−8000/1020=57.2 °C — well below boiling, design feasible.",
    calc: "ntu",
    quiz: [
      { q: "For SIZING an FSAE radiator (inlets and flows known, outlets unknown), use:", options: ["LMTD method", "Effectiveness-NTU method", "Stefan-Boltzmann", "Bernoulli"], answer: 1, explanation: "ε-NTU gives required UA in one pass without iterating on unknown outlet temperatures — ideal for sizing." },
      { q: "Modeling an automotive radiator as counterflow instead of crossflow-both-unmixed will:", options: ["Be more conservative", "Over-predict performance and UNDERSIZE the core", "Make no difference", "Only change the air outlet temp"], answer: 1, explanation: "Counterflow is the best-case arrangement (higher ε at equal NTU). A real crossflow core performs worse, so assuming counterflow undersizes it." },
      { q: "Why are radiators so heavily finned on the air side?", options: ["For looks", "The air-side h is low and dominates UA, so you multiply its area with fins", "To add mass", "To raise the coolant-side resistance"], answer: 1, explanation: "Air-side h (~50–150) is far below coolant-side h (~3000–10000), so the air film dominates 1/UA. Fins multiply air-side area to compensate." },
    ],
  },

  /* ============================ MODULE 6 ============================ */
  {
    id: "radiation",
    title: "Thermal Radiation & When It Actually Matters",
    tag: "Foundations",
    physics: [
      "Every surface radiates q = ε·σ·T⁴ (σ = 5.67e-8 W/m²·K⁴, T absolute), and the *net* exchange with surroundings is q = ε·σ·(T⁴ − T_surr⁴). Two independent optical properties matter because they live in different wavebands: **emissivity ε** (how well it sheds IR) and **solar absorptivity α** (how much sunlight it soaks). Their ratio **α/ε** sets the equilibrium temperature of a sunlit surface in space.",
      "Exchange between surfaces is geometric, captured by **view factors** F_ij (with reciprocity A_i F_ij = A_j F_ji and Σ_j F_ij = 1). For real gray surfaces you solve a radiosity network; for complex geometry the exchange factors ('radks') are computed by **Monte-Carlo ray tracing** — firing photon bundles and tallying where they land.",
      "The key judgment: in **vacuum, radiation is the only way out** — it dominates spacecraft and hot engine externals. Near room temperature the T⁴ law linearizes to h_r ≈ 4εσT_m³ ≈ 5 W/m²·K — real but small next to forced convection over a moving car (50–200+ W/m²·K). So radiation matters for **hot** surfaces (glowing brakes at 700–900 K shed 15–30 kW/m²) and **still-air** soak (a car baking in the paddock sun), and is secondary for cool, fast-air-washed bodywork.",
    ],
    equations: [
      { name: "Stefan-Boltzmann (net)", formula: "q = ε·σ·(T⁴ − T_surr⁴)", variables: "ε emissivity, σ=5.67e-8, T in KELVIN", validity: "Gray diffuse surface; small object in large surroundings" },
      { name: "Sunlit equilibrium (to space)", formula: "T_eq = [(α/ε)·S·F_s/σ]^{1/4}", variables: "S solar flux ~1361 W/m², α solar absorptivity", validity: "Radiative equilibrium, no internal power" },
      { name: "Linearized radiation coeff.", formula: "h_r = 4·ε·σ·T_m^3", variables: "T_m mean of surface & surroundings [K]", validity: "Near-ambient ΔT; ~5 W/m²K at 300 K, ε=1" },
      { name: "View-factor rules", formula: "A_i·F_ij = A_j·F_ji ;  Σ_j F_ij = 1", variables: "F_ij fraction leaving i that reaches j", validity: "Diffuse emission, closed enclosure" },
    ],
    rocket_anchor: "The BE-3U model runs a full surface-to-surface radiation group (ENGINE_EXT) with Monte-Carlo radks (50k rays/node), plus three orbital loads — solar flux (1315/1429 W/m² cold/hot day), albedo (0.13/0.50), and IR planetshine (189/291 W/m²) — and an optical-property table of α and ε for every coating (white paint α/ε = 0.22/0.85 runs cold; bare Inconel 0.76/0.20 runs hot). It's the textbook spacecraft radiation problem.",
    fsae_bridge: "On a moving FSAE car, bodywork is convection-dominated — radiation off cool panels is minor. But the same physics is a real lever in two places: **(1) hot components** — brake rotors glow and dump tens of kW/m² by radiation, and a hot battery enclosure couples radiatively to surrounding structure; emissivity coatings and heat-shield view-factor management are deliberate design choices. **(2) the paddock soak** — parked in the sun with no airflow, α/ε of your wrap/paint sets how hot the cabin and pack get, exactly like a satellite. Choose a low-α/ε finish for sun-exposed pack lids.",
    worked_example: "A brake rotor at T = 800 K (527 °C), ε ≈ 0.8, radiating to 300 K surroundings: q = 0.8·5.67e-8·(800⁴ − 300⁴) = 0.8·5.67e-8·(4.096e11 − 8.1e9) = 0.8·5.67e-8·4.015e11 ≈ 1.82e4 W/m² ≈ **18 kW/m²**. Compare a 320 K (47 °C) body panel to 300 K air: q = 0.9·5.67e-8·(320⁴−300⁴) = 0.9·5.67e-8·(1.049e10−8.1e9) = 0.9·5.67e-8·2.39e9 ≈ **122 W/m²** — two orders of magnitude less, and dwarfed by forced convection at speed. Radiation only 'switches on' when T is high.",
    calc: "radiation",
    quiz: [
      { q: "Why is radiation usually secondary for a moving FSAE car's bodywork but dominant for a spacecraft?", options: ["Spacecraft are hotter", "In vacuum there's no convection, so radiation is the only path; near-ambient in air, forced convection vastly exceeds the linearized h_r", "Radiation doesn't work in air", "Bodywork has zero emissivity"], answer: 1, explanation: "In vacuum radiation is the sole rejection path. Near ambient, h_r≈5 W/m²K is tiny next to forced convection (50–200+), so convection wins on a moving car." },
      { q: "What governs the equilibrium temperature of a sun-baked surface with no internal heat?", options: ["Emissivity alone", "The α/ε ratio (solar absorptivity over IR emissivity)", "Conductivity", "Reynolds number"], answer: 1, explanation: "T_eq scales as (α/ε)^{1/4}. Low α/ε (white paint) runs cold; high α/ε (bare/dark metal) runs hot — the paddock-soak design lever." },
      { q: "The 'radks' in the rocket model are computed by:", options: ["Dittus-Boelter", "Monte-Carlo ray tracing of view/exchange factors", "Bernoulli's equation", "Measuring with thermocouples"], answer: 1, explanation: "Complex geometry radiation exchange factors are found by firing many photon bundles (Monte-Carlo) and tallying absorption — handling shadowing and cavities closed-form view factors can't." },
    ],
  },

  /* ============================ MODULE 7 ============================ */
  {
    id: "nodal",
    title: "The Nodal Network Method (SINDA / Thermal Desktop)",
    tag: "Methodology",
    physics: [
      "Both source models are built the same way: discretize the system into **nodes** (a mass with one temperature) joined by **conductors** (a heat path). Three node types: **diffusion** (finite capacitance C = m·cp, stores energy, used for transients), **arithmetic** (zero capacitance, balances instantly — foils, thin interfaces), and **boundary** (fixed temperature — deep space, a coolant plenum, ambient).",
      "Two conductor kinds. **Linear** conductors carry Q = G·(T₁−T₂): conduction G = kA/L, convection G = h·A, contact G = h_c·A — all linear because the rate is proportional to the *first power* of ΔT. (Note: the conductance G itself is independent of ΔT; it's the heat *rate* Q that's linear in ΔT.) **Radiation** conductors carry Q = G_rad·(T₁⁴−T₂⁴) with G_rad = σεFA — the fourth-power term makes the system nonlinear, requiring iteration.",
      "Assemble the first law at every node — C·dT/dt = Σ G·(T_j−T_i) + Σ G_rad·(T_j⁴−T_i⁴) + Q — and integrate. **Explicit** (forward Euler) is cheap but only stable if the step stays below each node's time constant C/ΣG; **implicit** is unconditionally stable at the cost of a matrix solve. The philosophy: use *few, well-chosen* nodes and **anchor uncertain conductances to test data** (~10–20% accuracy is normal for thermal, vs ~1–2% for structural FEA). Fluid loops are a parallel network of bulk-fluid 'lumps' joined by flow paths carrying ṁ·cp, tied to the solid network by convective 'ties' (UA = h·A).",
    ],
    equations: [
      { name: "Nodal capacitance", formula: "C = m·cp = ρ·V·cp", variables: "Diffusion: finite C; arithmetic: C=0; boundary: C=∞", validity: "Per-node thermal mass" },
      { name: "Linear conductor", formula: "Q = G·(T₁−T₂);  G = kA/L (cond), h·A (conv), h_c·A (contact)", variables: "G = conductance [W/K]; Q linear in ΔT, G independent of ΔT", validity: "Conduction/convection/contact" },
      { name: "Per-node energy balance", formula: "C_i·dT_i/dt = Σ_j G_ij(T_j−T_i) + Σ_k G_rad(T_k⁴−T_i⁴) + Q_i", variables: "First law at each node", validity: "Diffusion ODE; arithmetic LHS=0; boundary T fixed" },
      { name: "Explicit stability limit", formula: "Δt < C_i / Σ_j G_ij  (every node)", variables: "Node time constant sets the max stable step", validity: "Forward-Euler only; implicit is unconditional" },
      { name: "Advected fluid energy", formula: "Q ≈ ṁ·cp·(T_in − T_out);  tie: Q = (h·A)·(T_fluid − T_wall)", variables: "ṁ·cp = capacity rate of the stream", validity: "Bulk-fluid lumps + convective ties" },
    ],
    rocket_anchor: "The BE-3U model is a textbook instance: boundary nodes for engine-balance stations and IFC air, arithmetic path nodes for flow volumes, diffusion nodes for hardware, linear conductors scaled by ṁ·cp for the propellant flow, contactors for joints, and a radiation group for surface-to-surface exchange. It even mirrors the XREF philosophy — build the engine once, instance it twice — and deliberately keeps the GS2 structure coarse because that fidelity doesn't change the engine answer.",
    fsae_bridge: "Model your whole car this way instead of reaching for CFD first: nodes = cells/modules, motor stator, inverter, coolant segments, radiator core, ambient (boundary); conductors = busbar conduction, cell-to-plate contactors, fin-to-air convection. The energy balance C·dT/dt = ΣG·ΔT + Q predicts pack temperature over an endurance run, with Q the I²R/inverter/motor losses. The coolant loop is the fluid network (pump sets ṁ, ties couple coolant to plates). Build a small model you can run in seconds and correlate to thermocouple data — reserve CFD for the few spots (duct aero, channel design) where local detail truly matters. And the explicit-stability rule explains why a too-big time step makes a hand-rolled transient script blow up.",
    worked_example: "Two-node battery-module transient (explicit-stability check). Cell node: m=2 kg, cp=1000 → C=2000 J/K, coupled to a coolant boundary node by a convective conductor G = h·A = 60 W/m²·K × 0.05 m² = 3 W/K. Node time constant = C/ΣG = 2000/3 = 667 s. A stable forward-Euler step needs Δt < 667 s — easy here. But refine the cell into 10 sub-nodes (C=200 each) joined by stiff internal conduction G_int = kA/L = 1.5·0.001/0.005 = 0.3 W/K... if instead a sub-node sees ΣG = 50 W/K, its limit drops to 200/50 = 4 s — miss that and the solution oscillates and diverges. That's why finer meshes force smaller steps (or an implicit solver).",
    calc: "stability",
    quiz: [
      { q: "A boundary node in a thermal network represents:", options: ["A fixed-temperature source/sink (∞ capacitance)", "A massless instant-balance point", "The hottest part", "A radiation-only surface"], answer: 0, explanation: "Boundary nodes hold a fixed temperature (deep space, a coolant plenum, ambient) — effectively infinite thermal capacitance." },
      { q: "Radiation conductors make the nodal system nonlinear because:", options: ["G_rad is negative", "Heat rate depends on T⁴, not ΔT", "They have no capacitance", "They only work in air"], answer: 1, explanation: "Q = G_rad·(T₁⁴−T₂⁴) is fourth-power in temperature, so the equations must be solved iteratively." },
      { q: "Your explicit transient simulation oscillates and blows up. The most likely fix is:", options: ["Add more heat load", "Use a time step smaller than the smallest node's C/ΣG (or switch to implicit)", "Remove all conductors", "Increase emissivity"], answer: 1, explanation: "Forward-Euler is conditionally stable: Δt must be below every node's time constant C/ΣG. Finer meshes shrink that limit; implicit integration removes it." },
    ],
  },

  /* ============================ MODULE 8 ============================ */
  {
    id: "aero",
    title: "FSAE Aerodynamics: Downforce & Drag",
    tag: "Aerodynamics",
    physics: [
      "Two equations govern race-car aero: downforce L = ½·ρ·V²·Cl·A and drag D = ½·ρ·V²·Cd·A, with ρ ≈ 1.225 kg/m³. Because the reference area A is arbitrary for a complex car, engineers fold it into single **ClA** and **CdA** numbers (units m²) and compute force directly: L = ½·ρ·V²·ClA.",
      "The defining FSAE twist is **low speed**. Events average ~40–60 km/h and rarely top 97 km/h. Since force scales with V², downforce at 50 km/h is only a quarter of its 100 km/h value — aero is real but speed-limited, so teams chase **high-downforce, low-speed-tuned** packages, not low-drag ones.",
      "Downforce helps because tire grip ≈ μ·(m·g + L): adding aero load raises the cornering limit without adding mass (though tires are load-sensitive, so returns diminish). Efficiency is L/D = ClA/CdA (~2–3.5 for FSAE). On tight low-speed courses, laptime sims almost always favor MORE downforce despite the drag — the opposite of a fast circuit. **Aero balance** (center of pressure) should sit near the static weight split so handling stays neutral as speed builds.",
    ],
    equations: [
      { name: "Downforce", formula: "L = ½·ρ·V²·ClA", variables: "ρ≈1.225 kg/m³, V [m/s], ClA combined lift-area [m²]", validity: "Incompressible (M≪0.3)" },
      { name: "Drag", formula: "D = ½·ρ·V²·CdA", variables: "CdA combined drag-area [m²]", validity: "Incompressible; CdA rises with added downforce" },
      { name: "V² scaling", formula: "L(V₂)/L(V₁) = (V₂/V₁)²", variables: "Halving speed quarters downforce", validity: "Direct from the V² term" },
      { name: "Cornering grip with aero", formula: "F_lat,max = μ·(m·g + ½·ρ·V²·ClA)", variables: "μ≈1.2–1.6 (load-sensitive slicks)", validity: "Friction-circle point-mass model" },
      { name: "Aero efficiency", formula: "L/D = ClA/CdA", variables: "Speed-independent; FSAE ~2–3.5", validity: "Reynolds-insensitive over the speed range" },
    ],
    rocket_anchor: "Aero is where the bridge inverts: the rocket model's **interstage forced convection** uses 'flow over a flat plate' and 'flow around a cylinder' correlations at 5 ft/s — the *same boundary-layer physics* (driven by the same Reynolds number) that sets a car's drag and convective cooling. The link is literal: Re governs both whether your bodywork sheds heat and how much drag it makes, which is exactly why thermal and aero can't be designed separately (Module 9).",
    fsae_bridge: "This module IS the FSAE design problem directly. The dynamic-event points — Endurance 275 + Autocross 125 + Skidpad 75 = 475 corner-limited points vs only 100 for drag-penalized Acceleration — push most teams to an aggressive high-downforce package tuned for ~40–70 km/h. Lean on the undertray/diffuser (best L/D via ground effect), size wings to the target ClA, and set CoP near the ~45–50% static front weight split so balance holds as speed rises.",
    worked_example: "ClA = 3.5 at 60 km/h (16.67 m/s): L = ½·1.225·16.67²·3.5 = ½·1.225·277.9·3.5 = 595.5 ≈ **600 N (61 kgf)** of downforce. Drop to an autocross-typical 50 km/h (13.89 m/s): L = ½·1.225·192.9·3.5 = 413.4 ≈ **415 N (42 kgf)** — the V² law in action (415/600 = (50/60)² = 0.69). On a 280 kg car+driver, 600 N adds 600/(280·9.81) ≈ 22% to vertical load in a fast corner — meaningful grip. With CdA = 1.3, drag at 60 km/h is ½·1.225·277.9·1.3 = 221 N, giving L/D = 600/221 = 2.7.",
    calc: "aero",
    quiz: [
      { q: "Why do FSAE teams favor high downforce despite the drag penalty?", options: ["Top speed is the priority", "Events are low-speed and corner-limited (475 of 675 dynamic points), so cornering grip beats low drag", "Drag doesn't exist below 100 km/h", "Rules require maximum drag"], answer: 1, explanation: "Endurance+Autocross+Skidpad reward cornering at low speed; drag costs little laptime there, so more downforce wins despite a real L/D penalty." },
      { q: "Downforce at 40 km/h compared to 80 km/h is about:", options: ["Half", "One quarter", "The same", "Double"], answer: 1, explanation: "Force ∝ V². Halving speed → (1/2)² = 1/4 the downforce. This is why FSAE aero is 'speed-limited'." },
      { q: "Aero balance (center of pressure) should be placed:", options: ["As far forward as possible", "Near the car's static weight distribution so handling stays neutral with speed", "At the rear axle always", "Wherever drag is lowest"], answer: 1, explanation: "Matching CoP to the static weight split keeps front/rear grip balance roughly constant as downforce grows with speed, avoiding speed-dependent under/oversteer." },
    ],
  },

  /* ============================ MODULE 9 ============================ */
  {
    id: "coolingdrag",
    title: "Cooling Drag & Radiator Ducting (Thermal × Aero)",
    tag: "Aerodynamics",
    physics: [
      "This is where thermal and aero collide. **Cooling drag** is the drag penalty from forcing air through a radiator: the cooling stream enters at vehicle speed V and leaves slower, and that lost streamwise momentum is a rearward force — D_cool ≈ ṁ_air·(V − V_exit) plus net duct pressure forces. It can be ~10% of total vehicle drag.",
      "The coupling is unavoidable: heat rejected is Q = ṁ_air·cp·ΔT_air, so more cooling wants more airflow — but more airflow through a fixed core means more pressure drop (ΔP_core ∝ V_core²) and more momentum loss, i.e. more drag. The same lever (airflow) pulls both ways. The escape is to reject more heat *per unit airflow*: let the air dwell at low velocity in the core rather than blasting more through.",
      "Hence the canonical **diffuser → core → nozzle** duct. The diffuser inlet slows the air, converting dynamic pressure to static pressure (Bernoulli p_t = p_s + ½ρV²), so the core sees slow, high-pressure air and the same heat is rejected with far less momentum destroyed. The core is the dominant ΔP. The converging nozzle re-accelerates the heated air back toward freestream and returns it cleanly. Size the **inlet** by continuity ṁ = ρ·A_inlet·V to capture only the air you need (oversized inlets just spill and add drag), and **seal** the core so 100% of captured air passes through it. The WWII **Meredith effect** (heat addition recovering thrust) is negligible at FSAE speeds — at 25 m/s dynamic pressure is ~375 Pa vs ~13.5 kPa for a P-51 — so chase *less cooling drag*, not net thrust.",
    ],
    equations: [
      { name: "Dynamic (ram) pressure", formula: "q = ½·ρ·V²", variables: "ρ≈1.2 kg/m³, V relative airspeed", validity: "Incompressible; the 'budget' to push air through the core" },
      { name: "Bernoulli (diffuser)", formula: "p_t = p_s + ½·ρ·V² = const", variables: "Slowing V raises static pressure p_s ahead of the core", validity: "Low-loss flow; real ducts have η<1" },
      { name: "Continuity (inlet sizing)", formula: "ṁ_air = ρ·A_inlet·V = ρ·A_core·V_core", variables: "A_core/A_inlet = V/V_core (diffusion ratio)", validity: "Sealed duct, steady incompressible" },
      { name: "Cooling drag (momentum deficit)", formula: "D_cool ≈ ṁ_air·(V − V_exit)", variables: "V_exit duct outlet velocity", validity: "Control-volume momentum; recover V_exit→V to cut it" },
      { name: "Core pressure drop", formula: "ΔP_core ≈ K·½·ρ·V_core²", variables: "K core loss coefficient (supplier data)", validity: "Compact core, turbulent — halving V_core cuts ΔP ~4×" },
    ],
    rocket_anchor: "The rocket model's interstage forced convection (those 'flow over flat plate / around cylinder' conductors at 5 ft/s) is the same air-side convection problem, and its radk/duct geometry sensitivity mirrors radiator ducting. More deeply: it's the same Reynolds-driven boundary layer that produced a car's drag in Module 8 — so the engine's air-cooling and the car's aero are governed by one set of equations, which is the whole reason cooling and aero must be co-designed.",
    fsae_bridge: "Your radiator decision from Module 5 (needed UA → frontal area) lands here as a drag cost. The highest-leverage moves: **(1) diffuse hard** to a low core-face velocity — both ΔP and cooling drag scale with V_core², so slow air rejects the same heat with far less drag; **(2) seal the duct** so no air bypasses the core (all inlet drag, zero cooling otherwise — a classic FSAE mistake); **(3) size the inlet** to only the ṁ_air you need; **(4) put the outlet in a low-pressure region** (car wake, behind a wing) to pull flow through at low speed. Size everything for the low-speed endurance case where ram is weakest and the fan dominates. The radiator that cools best and the one that drags least are in tension — you converge core size, inlet/outlet areas, seal quality, and placement against a drag budget.",
    worked_example: "Need ṁ_air = 0.45 kg/s (from the Module 5 radiator) at an endurance speed V = 15 m/s (54 km/h), ρ = 1.2 kg/m³. Continuity for the INLET if we capture air at freestream: A_inlet = ṁ/(ρ·V) = 0.45/(1.2·15) = 0.025 m² (e.g. 0.10 m × 0.25 m). To drop the CORE-FACE velocity to V_core = 6 m/s for low drag, diffuse to A_core = ṁ/(ρ·V_core) = 0.45/(1.2·6) = 0.0625 m² — an area ratio of 2.5. Core pressure drop scales as V_core²: cutting face velocity from 15 to 6 m/s cuts ΔP by (15/6)² = 6.25×. Estimated cooling drag D_cool ≈ ṁ(V−V_exit); if a good nozzle recovers V_exit to 11 m/s, D_cool ≈ 0.45·(15−11) = 1.8 N — small, but every newton counts on an energy-limited endurance run.",
    calc: "coolingdrag",
    quiz: [
      { q: "The single highest-leverage move to reduce cooling drag is to:", options: ["Make the inlet as big as possible", "Diffuse the air to a low core-face velocity before the core", "Remove the radiator fan", "Point the outlet into high pressure"], answer: 1, explanation: "Both core ΔP and cooling drag scale with V_core². A diffuser inlet that slows the air lets the same heat be rejected with far less momentum loss." },
      { q: "Why is the Meredith effect (thrust recovery) essentially useless at FSAE speeds?", options: ["FSAE bans it", "Dynamic pressure ~½ρV² is ~30× smaller than at fighter-aircraft speeds, so there's little energy to recover", "Radiators don't add heat", "It only works in vacuum"], answer: 1, explanation: "Recovery scales with available ram pressure. At 25 m/s q≈375 Pa vs ~13.5 kPa for a P-51 — too little to matter, so you minimize drag rather than chase thrust." },
      { q: "Leaving gaps so air can bypass the radiator core gives you:", options: ["Better cooling and less drag", "All the inlet drag but little of the cooling", "No drag at all", "More downforce"], answer: 1, explanation: "Unsealed ducts let captured air slip past the core — you pay the inlet/momentum drag without rejecting the heat. Sealing the core is essential." },
    ],
  },
];

window.GLOSSARY = [
  { term: "Biot number (Bi)", def: "h·L_c/k — internal conduction vs surface convection resistance. <0.1 ⇒ lump as one node; ≥0.1 ⇒ must discretize through the thickness." },
  { term: "Nusselt number (Nu)", def: "h·L/k — dimensionless heat-transfer coefficient; ratio of convective to conductive transport in the fluid. Nu=1 is pure conduction." },
  { term: "Reynolds number (Re)", def: "ρVL/μ — inertia vs viscosity; sets laminar/turbulent regime. Governs BOTH convective cooling and aerodynamic drag." },
  { term: "Prandtl number (Pr)", def: "ν/α = cp·μ/k — momentum vs thermal diffusivity. Air ≈ 0.71, water ≈ 5.9, glycol mixes 10–30+." },
  { term: "Dittus-Boelter", def: "Nu = 0.023·Re^0.8·Pr^n (n=0.4 heating, 0.3 cooling). Simple turbulent-pipe HTC, ±25%, Re≳10⁴." },
  { term: "Gnielinski", def: "More accurate turbulent/transitional pipe correlation (±10%, valid Re≥3000). Preferred for cold-plate channels." },
  { term: "Effectiveness-NTU", def: "Heat-exchanger sizing method using NTU=UA/C_min and ε=Q/Q_max — no need to know outlet temps. Ideal for radiator sizing." },
  { term: "LMTD", def: "Log-mean temperature difference; Q=U·A·F·LMTD. Best when all four terminal temperatures are known (rating)." },
  { term: "Contact conductance (h_c)", def: "Heat transfer across an imperfect joint (bolted/brazed/clamped). Empirical, pressure & finish dependent; tuned to test data." },
  { term: "Time constant (τ)", def: "m·cp/(h·A) — thermal response time. 63.2% of the swing at t=τ, ~99% by 5τ. The thermal-RC analog (R·C)." },
  { term: "View factor (F_ij)", def: "Fraction of radiation leaving surface i that strikes surface j. Reciprocity A_i F_ij = A_j F_ji; Σ F_ij = 1." },
  { term: "α/ε ratio", def: "Solar absorptivity over IR emissivity — sets the sunlit equilibrium temperature. Low ⇒ runs cool; high ⇒ runs hot." },
  { term: "ClA / CdA", def: "Combined lift-area and drag-area (m²); fold the arbitrary reference area into the coefficient so force = ½ρV²·(ClA)." },
  { term: "Cooling drag", def: "Drag from forcing air through a radiator core (momentum deficit); ~10% of vehicle drag. Minimized by diffusing to low core-face velocity." },
  { term: "Meredith effect", def: "Thrust recovery from heat added to ducted radiator air (P-51 Mustang). Negligible at FSAE speeds." },
  { term: "Node / Conductor", def: "Nodal-model primitives: a node is a mass at one temperature; a conductor (G=1/R) is a heat path. The building blocks of SINDA/Thermal Desktop." },
];

window.SOURCE_MAP = {
  primary: [
    { title: "ENAN-187827 BE-3U System Thermal Model", note: "ANSYS Thermal Desktop / SINDA nodal model: conduction contactors, Dittus-Boelter duct HTC, interstage forced convection, surface-to-surface + orbital radiation, ṁ·cp fluid networks, hot/cold design-day transient CONOPS.", url: "https://wiki.blueorigin.com/spaces/BE3U/pages/2155568975" },
    { title: "Mesh Sensitivity of Thermal-Fluid Model in Sinda-Fluint", note: "Biot-number / through-thickness discretization study: nucleate boiling → very high Bi → coarse mesh over-conservative; two-node mass-toward-hot-side approximation.", url: "https://wiki.blueorigin.com/spaces/PA/pages/933163977" },
  ],
  related: [
    "Phase 5 MCC Thermal Analysis (2372428390) — steady-state HTC/BC-driven chamber model, SPECTRE wall temps",
    "BE-3U Quattro Nozzle Extension Flight Thermal Analysis (2344056660) — radiation + plume impingement, hot-streak BCs",
    "Phase 5 MCC: Throat & Aft Barrel Jacket (2369993134) / Slice-Acreage Model (2369993790)",
    "BE-3U EMA Bimetallic Shaft MPV & CCV Thermal Analysis (2379739742 / 2366831850)",
    "SINDA/Fluint Training deck (Nova Search KB) — node/conductor definitions, FLUINT lumps/paths/ties, ~10–20% test-correlation reality",
  ],
  external: [
    "Incropera, Bergman et al., Fundamentals of Heat & Mass Transfer (conduction, convection, ε-NTU, fin efficiency, FD stability)",
    "Çengel & Ghajar, Heat and Mass Transfer",
    "C&R Technologies — Introduction to SINDA / SINDA-FLUINT & Thermal Desktop docs",
    "Gilmore (ed.), Spacecraft Thermal Control Handbook",
    "KTH thesis — Modelling of battery cooling for Formula Student; FSG Academy EV Cooling System deck",
    "Wikipedia verified refs: Biot number, Nusselt/Reynolds/Prandtl, NTU method, LMTD, Stefan-Boltzmann, View factor, Meredith effect, Downforce, Formula SAE",
  ],
};
