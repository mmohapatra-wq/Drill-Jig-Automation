/* =====================================================================
   FSAE Thermal Academy — interactive calculator engine
   Each entry: { title, blurb, inputs[], compute(v) -> {outputs[], note} }
   inputs: {key,label,unit,def,min,max,step}
   compute returns outputs:[{label,value,unit,hl?}] and a note string.
   All formulas match curriculum.js (verified). Pure functions, no deps.
   ===================================================================== */
(function () {
  const f = (x, d = 3) => {
    if (!isFinite(x)) return "—";
    const a = Math.abs(x);
    if (a !== 0 && (a < 1e-3 || a >= 1e5)) return x.toExponential(d - 1);
    return Number(x.toFixed(d)).toString();
  };

  window.CALCULATORS = {

    /* ---- M1: series resistance chain ---- */
    resistanceChain: {
      title: "Series Thermal-Resistance Chain",
      blurb: "Cell core → TIM → wall → coolant. Series resistances add; the largest dominates. ΔT = Q̇·R_total.",
      inputs: [
        { key: "Q", label: "Heat dissipated Q̇", unit: "W", def: 2.5, min: 0.1, max: 2000, step: 0.1 },
        { key: "Rtim", label: "TIM contact R₁", unit: "K/W", def: 1.2, min: 0, max: 20, step: 0.05 },
        { key: "Rwall", label: "Wall conduction R₂", unit: "K/W", def: 0.3, min: 0, max: 20, step: 0.05 },
        { key: "Rconv", label: "Coolant convection R₃", unit: "K/W", def: 0.8, min: 0, max: 20, step: 0.05 },
        { key: "Tcool", label: "Coolant temperature", unit: "°C", def: 40, min: -20, max: 120, step: 1 },
      ],
      compute(v) {
        const Rtot = v.Rtim + v.Rwall + v.Rconv;
        const dT = v.Q * Rtot;
        const Tcore = v.Tcool + dT;
        const parts = [["TIM", v.Rtim], ["wall", v.Rwall], ["convection", v.Rconv]];
        parts.sort((a, b) => b[1] - a[1]);
        const dom = parts[0];
        const pct = Rtot > 0 ? (100 * dom[1] / Rtot) : 0;
        return {
          outputs: [
            { label: "Total resistance R_total", value: f(Rtot), unit: "K/W" },
            { label: "Core-to-coolant rise ΔT", value: f(dT, 4), unit: "K" },
            { label: "Cell core temperature", value: f(Tcore, 4), unit: "°C", hl: true },
            { label: "Dominant resistance", value: dom[0] + " (" + f(pct, 3) + "%)", unit: "" },
          ],
          note: Tcore > 60
            ? "⚠ Core exceeds the ~60 °C Li-ion limit. Attack the " + dom[0] + " resistance first (it's the biggest term) or lower coolant temperature."
            : "✓ Core under the 60 °C limit. The " + dom[0] + " resistance dominates — improving it buys the most margin.",
        };
      },
    },

    /* ---- M2: conduction + contact ---- */
    conduction: {
      title: "Conduction & Contact-Joint ΔT",
      blurb: "Plane-wall conduction R = L/(k·A) in series with a contact joint R = 1/(h_c·A). See which dominates.",
      inputs: [
        { key: "Q", label: "Heat through joint Q̇", unit: "W", def: 1500, min: 1, max: 10000, step: 10 },
        { key: "k", label: "Wall conductivity k", unit: "W/m·K", def: 200, min: 1, max: 420, step: 1 },
        { key: "L", label: "Wall thickness L", unit: "mm", def: 5, min: 0.2, max: 50, step: 0.1 },
        { key: "A", label: "Interface area A", unit: "cm²", def: 96, min: 1, max: 1000, step: 1 },
        { key: "hc", label: "Contact conductance h_c", unit: "W/m²·K", def: 5000, min: 100, max: 50000, step: 100 },
      ],
      compute(v) {
        const A = v.A * 1e-4, L = v.L * 1e-3;
        const Rcond = L / (v.k * A);
        const Rcont = 1 / (v.hc * A);
        const Rtot = Rcond + Rcont;
        const dT = v.Q * Rtot;
        const dom = Rcont >= Rcond ? "contact joint (the TIM)" : "wall conduction";
        return {
          outputs: [
            { label: "Wall conduction R_cond", value: f(Rcond, 4), unit: "K/W" },
            { label: "Contact resistance R_contact", value: f(Rcont, 4), unit: "K/W" },
            { label: "Temperature drop ΔT", value: f(dT, 3), unit: "K", hl: true },
            { label: "Bottleneck", value: dom, unit: "" },
          ],
          note: "The " + dom + " is the larger resistance. " +
            (Rcont >= Rcond
              ? "A better thermal-interface material (higher h_c) or more clamping pressure cuts the junction temperature fastest."
              : "Conduction dominates — a thinner wall or higher-k metal (copper) helps most."),
        };
      },
    },

    /* ---- M3: forced convection (Gnielinski + Dittus-Boelter) ---- */
    convection: {
      title: "Cold-Plate Convection (Gnielinski vs Dittus-Boelter)",
      blurb: "Internal channel flow → Re, then Nu by both correlations, then h = Nu·k/D_h. Watch the regime flag.",
      inputs: [
        { key: "mdot", label: "Coolant mass flow ṁ", unit: "kg/s", def: 0.05, min: 0.005, max: 1, step: 0.005 },
        { key: "D", label: "Channel hydraulic dia. D_h", unit: "mm", def: 6, min: 1, max: 30, step: 0.5 },
        { key: "rho", label: "Coolant density ρ", unit: "kg/m³", def: 1050, min: 700, max: 1100, step: 5 },
        { key: "mu", label: "Dynamic viscosity μ", unit: "Pa·s", def: 0.0025, min: 0.0003, max: 0.05, step: 0.0001 },
        { key: "k", label: "Coolant conductivity k", unit: "W/m·K", def: 0.40, min: 0.1, max: 0.7, step: 0.01 },
        { key: "cp", label: "Specific heat cp", unit: "J/kg·K", def: 3400, min: 1500, max: 4200, step: 10 },
      ],
      compute(v) {
        const D = v.D * 1e-3;
        const A = Math.PI * D * D / 4;
        const V = v.mdot / (v.rho * A);
        const Re = v.rho * V * D / v.mu;
        const Pr = v.cp * v.mu / v.k;
        let regime = Re < 2300 ? "laminar" : (Re < 4000 ? "transitional" : "turbulent");
        // Gnielinski
        let NuG, hG;
        if (Re > 3000) {
          const fr = Math.pow(0.790 * Math.log(Re) - 1.64, -2);
          NuG = (fr / 8) * (Re - 1000) * Pr / (1 + 12.7 * Math.sqrt(fr / 8) * (Math.pow(Pr, 2 / 3) - 1));
          hG = NuG * v.k / D;
        } else {
          NuG = 3.66; hG = NuG * v.k / D; // laminar const-Twall floor
        }
        // Dittus-Boelter (heating the coolant, n=0.4)
        const NuDB = Re >= 1 ? 0.023 * Math.pow(Re, 0.8) * Math.pow(Pr, 0.4) : 0;
        const hDB = NuDB * v.k / D;
        return {
          outputs: [
            { label: "Channel velocity V", value: f(V, 3), unit: "m/s" },
            { label: "Reynolds Re", value: f(Re, 4), unit: "(" + regime + ")" },
            { label: "Prandtl Pr", value: f(Pr, 3), unit: "" },
            { label: "h (Gnielinski)", value: f(hG, 4), unit: "W/m²·K", hl: true },
            { label: "h (Dittus-Boelter)", value: f(hDB, 4), unit: "W/m²·K" },
          ],
          note: Re < 2300
            ? "⚠ Laminar — Nu locks to ~3.66 regardless of geometry, so HTC is poor. Raise pump flow to go turbulent."
            : Re < 4000
              ? "Transitional band: trust Gnielinski (Dittus-Boelter is least accurate here and over-predicts). Push flow higher to clear it."
              : "Turbulent: both are valid, but Gnielinski (±10%) is more accurate than Dittus-Boelter (±25%).",
        };
      },
    },

    /* ---- M4: Biot + time constant ---- */
    biot: {
      title: "Biot Number & Thermal Time Constant",
      blurb: "Bi = h·L_c/k decides lump vs discretize. τ = m·cp/(h·A) is the heat-soak response time.",
      inputs: [
        { key: "h", label: "Convective coeff. h", unit: "W/m²·K", def: 40, min: 2, max: 100000, step: 1 },
        { key: "Lc", label: "Characteristic length L_c", unit: "mm", def: 5.25, min: 0.2, max: 100, step: 0.05 },
        { key: "k", label: "Solid conductivity k", unit: "W/m·K", def: 1.5, min: 0.2, max: 420, step: 0.1 },
        { key: "m", label: "Body mass m", unit: "g", def: 70, min: 1, max: 50000, step: 1 },
        { key: "cp", label: "Specific heat cp", unit: "J/kg·K", def: 1000, min: 100, max: 4200, step: 10 },
        { key: "As", label: "Convecting area A_s", unit: "cm²", def: 45, min: 1, max: 5000, step: 1 },
        { key: "Ti", label: "Initial temp T_i", unit: "°C", def: 25, min: -50, max: 200, step: 1 },
        { key: "Tinf", label: "Ambient/coolant T∞", unit: "°C", def: 55, min: -50, max: 200, step: 1 },
        { key: "t", label: "Elapsed time t", unit: "s", def: 1500, min: 0, max: 20000, step: 10 },
      ],
      compute(v) {
        const Lc = v.Lc * 1e-3, m = v.m * 1e-3, As = v.As * 1e-4;
        const Bi = v.h * Lc / v.k;
        const tau = m * v.cp / (v.h * As);
        const Tt = v.Tinf + (v.Ti - v.Tinf) * Math.exp(-v.t / tau);
        const frac = 100 * (1 - Math.exp(-v.t / tau));
        return {
          outputs: [
            { label: "Biot number Bi", value: f(Bi, 4), unit: "", hl: true },
            { label: "Model recommendation", value: Bi < 0.1 ? "lump (1 node OK)" : "discretize through thickness", unit: "" },
            { label: "Time constant τ", value: f(tau, 4), unit: "s  (" + f(tau / 60, 3) + " min)" },
            { label: "Temperature at t", value: f(Tt, 3), unit: "°C" },
            { label: "Fraction of swing complete", value: f(frac, 3), unit: "%" },
          ],
          note: Bi < 0.1
            ? "✓ Bi < 0.1 — body is essentially isothermal; a single lumped node is accurate (<~5% error). It reaches ~63% of its swing in one τ."
            : "⚠ Bi ≥ 0.1 — significant internal gradients. A single node under-predicts the hot-spot; mesh through the thickness (the mesh-sensitivity lesson) and refine until peak temp stops changing.",
        };
      },
    },

    /* ---- M5: effectiveness-NTU radiator sizing ---- */
    ntu: {
      title: "Radiator Sizing — Effectiveness-NTU (crossflow, both unmixed)",
      blurb: "Given Q̇, inlets and both flows, solve required ε → NTU → UA → frontal area. Outlets are an output, not an input.",
      inputs: [
        { key: "Q", label: "Heat to reject Q̇", unit: "kW", def: 8, min: 0.5, max: 60, step: 0.1 },
        { key: "mh", label: "Coolant flow ṁ_h", unit: "kg/s", def: 0.30, min: 0.02, max: 3, step: 0.01 },
        { key: "cph", label: "Coolant cp", unit: "J/kg·K", def: 3400, min: 1500, max: 4200, step: 10 },
        { key: "Thin", label: "Coolant inlet T_h,in", unit: "°C", def: 65, min: 30, max: 120, step: 1 },
        { key: "mc", label: "Air flow ṁ_c", unit: "kg/s", def: 0.45, min: 0.05, max: 5, step: 0.01 },
        { key: "cpc", label: "Air cp", unit: "J/kg·K", def: 1007, min: 1000, max: 1100, step: 1 },
        { key: "Tcin", label: "Air inlet T_c,in", unit: "°C", def: 35, min: -10, max: 50, step: 1 },
        { key: "UAperA", label: "Core UA per frontal area", unit: "W/K·m²", def: 1500, min: 400, max: 4000, step: 50 },
      ],
      compute(v) {
        const Q = v.Q * 1000;
        const Ch = v.mh * v.cph, Cc = v.mc * v.cpc;
        const Cmin = Math.min(Ch, Cc), Cmax = Math.max(Ch, Cc);
        const Cr = Cmin / Cmax;
        const Qmax = Cmin * (v.Thin - v.Tcin);
        const eps = Q / Qmax;
        // invert crossflow-both-unmixed: eps = 1 - exp{ (1/Cr) NTU^.22 [exp(-Cr NTU^.78) -1] }
        function epsOf(NTU) {
          if (Cr <= 1e-9) return 1 - Math.exp(-NTU);
          return 1 - Math.exp((1 / Cr) * Math.pow(NTU, 0.22) * (Math.exp(-Cr * Math.pow(NTU, 0.78)) - 1));
        }
        let NTU = NaN, feasible = eps < 1;
        if (feasible) {
          let lo = 1e-4, hi = 50;
          for (let i = 0; i < 80; i++) {
            const mid = 0.5 * (lo + hi);
            (epsOf(mid) < eps ? (lo = mid) : (hi = mid));
          }
          NTU = 0.5 * (lo + hi);
        }
        const UA = feasible ? NTU * Cmin : NaN;
        const Afront = feasible ? UA / v.UAperA : NaN;
        const ThOut = v.Thin - Q / Ch;
        const TcOut = v.Tcin + Q / Cc;
        return {
          outputs: [
            { label: "C_min / C_max", value: f(Cmin, 3) + " / " + f(Cmax, 3), unit: "W/K" },
            { label: "Capacity ratio C_r", value: f(Cr, 3), unit: "" },
            { label: "Required effectiveness ε", value: f(eps, 3), unit: "" },
            { label: "Required NTU", value: feasible ? f(NTU, 3) : "∞ (impossible)", unit: "" },
            { label: "Required UA", value: feasible ? f(UA, 4) : "—", unit: "W/K", hl: true },
            { label: "Frontal area A_front", value: feasible ? f(Afront, 3) : "—", unit: "m²", hl: true },
            { label: "Coolant out / Air out", value: f(ThOut, 3) + " / " + f(TcOut, 3), unit: "°C" },
          ],
          note: !feasible
            ? "⚠ ε ≥ 1 — impossible with this airflow/inlet temp. Increase air flow (bigger fan/duct), lower air inlet temp, or accept a higher coolant temperature."
            : "✓ Feasible. Air is C_min here (dominates UA) — fan/duct/ram-air design matters as much as core size. Bigger A_front buys margin but costs cooling drag (Module 9).",
        };
      },
    },

    /* ---- M6: radiation ---- */
    radiation: {
      title: "Radiation Heat Flux & Convection Crossover",
      blurb: "q = ε·σ·(T⁴ − T_surr⁴). Compare the linearized radiative h_r to forced convection to see which wins.",
      inputs: [
        { key: "T", label: "Surface temperature", unit: "°C", def: 527, min: -50, max: 1200, step: 1 },
        { key: "Tsurr", label: "Surroundings temperature", unit: "°C", def: 27, min: -270, max: 200, step: 1 },
        { key: "eps", label: "Emissivity ε", unit: "", def: 0.8, min: 0.02, max: 1, step: 0.01 },
        { key: "hconv", label: "Forced-convection h (compare)", unit: "W/m²·K", def: 80, min: 2, max: 400, step: 1 },
      ],
      compute(v) {
        const sig = 5.670374e-8;
        const T = v.T + 273.15, Ts = v.Tsurr + 273.15;
        const q = v.eps * sig * (Math.pow(T, 4) - Math.pow(Ts, 4));
        const Tm = 0.5 * (T + Ts);
        const hr = 4 * v.eps * sig * Math.pow(Tm, 3);
        const qconv = v.hconv * (T - Ts);
        const ratio = qconv !== 0 ? q / qconv : Infinity;
        return {
          outputs: [
            { label: "Radiative flux q_rad", value: f(q, 4), unit: "W/m²", hl: true },
            { label: "Linearized radiative h_r", value: f(hr, 3), unit: "W/m²·K" },
            { label: "Convective flux q_conv (compare)", value: f(qconv, 4), unit: "W/m²" },
            { label: "Radiation / convection", value: f(ratio, 3), unit: "×" },
          ],
          note: ratio > 1
            ? "🔥 Radiation EXCEEDS convection here — high surface temp (T⁴ explodes). This is the brake-rotor / hot-component / vacuum regime where emissivity coatings matter."
            : "Convection dominates (ratio < 1) — the normal moving-car regime where radiation off cool bodywork is secondary. Radiation 'switches on' as T climbs.",
        };
      },
    },

    /* ---- M7: explicit stability ---- */
    stability: {
      title: "Explicit-Integration Stability Step",
      blurb: "Forward-Euler is stable only if Δt < C/ΣG for every node. Finer meshes shrink the limit — or go implicit.",
      inputs: [
        { key: "m", label: "Node mass m", unit: "g", def: 200, min: 0.1, max: 50000, step: 1 },
        { key: "cp", label: "Specific heat cp", unit: "J/kg·K", def: 1000, min: 100, max: 4200, step: 10 },
        { key: "Gsum", label: "Sum of conductors ΣG", unit: "W/K", def: 50, min: 0.01, max: 5000, step: 0.1 },
        { key: "dt", label: "Chosen time step Δt", unit: "s", def: 4, min: 0.001, max: 5000, step: 0.1 },
      ],
      compute(v) {
        const C = (v.m * 1e-3) * v.cp;
        const tau = C / v.Gsum;
        const stable = v.dt < tau;
        return {
          outputs: [
            { label: "Node capacitance C", value: f(C, 3), unit: "J/K" },
            { label: "Node time constant C/ΣG", value: f(tau, 4), unit: "s", hl: true },
            { label: "Max stable Δt (explicit)", value: f(tau, 4), unit: "s" },
            { label: "Your Δt vs limit", value: f(v.dt) + " / " + f(tau, 3), unit: "s" },
          ],
          note: stable
            ? "✓ Δt < C/ΣG — forward-Euler is stable for this node. (Check the SMALLEST C/ΣG across the whole model — the stiffest node sets the limit.)"
            : "⚠ Δt ≥ C/ΣG — explicit integration will oscillate and diverge. Shrink Δt below " + f(tau, 3) + " s, or switch to an implicit (unconditionally stable) solver.",
        };
      },
    },

    /* ---- M8: aero downforce/drag ---- */
    aero: {
      title: "Downforce, Drag & Cornering Gain",
      blurb: "L = ½ρV²·ClA, D = ½ρV²·CdA. See the V² scaling and how much grip aero adds to a corner.",
      inputs: [
        { key: "V", label: "Car speed", unit: "km/h", def: 60, min: 10, max: 130, step: 1 },
        { key: "rho", label: "Air density ρ", unit: "kg/m³", def: 1.225, min: 1.0, max: 1.3, step: 0.005 },
        { key: "ClA", label: "Lift-area ClA", unit: "m²", def: 3.5, min: 0.5, max: 6, step: 0.1 },
        { key: "CdA", label: "Drag-area CdA", unit: "m²", def: 1.3, min: 0.4, max: 2.5, step: 0.05 },
        { key: "mass", label: "Car + driver mass", unit: "kg", def: 280, min: 150, max: 400, step: 5 },
        { key: "mu", label: "Tire friction μ", unit: "", def: 1.4, min: 0.8, max: 1.8, step: 0.05 },
      ],
      compute(v) {
        const V = v.V / 3.6;
        const q = 0.5 * v.rho * V * V;
        const L = q * v.ClA, D = q * v.CdA;
        const W = v.mass * 9.81;
        const aeroPct = 100 * L / W;
        const LD = v.CdA > 0 ? v.ClA / v.CdA : 0;
        const gNoAero = v.mu;                       // lateral g without aero (=μ)
        const gAero = v.mu * (W + L) / W;           // with aero load
        return {
          outputs: [
            { label: "Downforce L", value: f(L, 4), unit: "N  (" + f(L / 9.81, 3) + " kgf)", hl: true },
            { label: "Drag D", value: f(D, 4), unit: "N" },
            { label: "Aero load vs weight", value: f(aeroPct, 3), unit: "%" },
            { label: "Aero efficiency L/D", value: f(LD, 3), unit: "" },
            { label: "Max lateral grip", value: f(gNoAero, 3) + " → " + f(gAero, 3), unit: "g (no aero → with aero)", hl: true },
          ],
          note: "Downforce scales with V²: at half this speed you'd get a quarter the load. Aero adds ~" + f(aeroPct, 2) +
            "% to vertical load here, lifting cornering grip from " + f(gNoAero, 2) + "g to ~" + f(gAero, 2) +
            "g (before tire load-sensitivity). On low-speed FSAE courses, more ClA usually beats lower CdA.",
        };
      },
    },

    /* ---- M9: cooling drag / duct sizing ---- */
    coolingdrag: {
      title: "Radiator Duct & Cooling-Drag Sizing",
      blurb: "Continuity sizes the inlet to the air you need; diffusing to a low core-face velocity slashes ΔP and cooling drag (both ∝ V_core²).",
      inputs: [
        { key: "mdot", label: "Required air flow ṁ_air", unit: "kg/s", def: 0.45, min: 0.05, max: 3, step: 0.01 },
        { key: "V", label: "Vehicle speed", unit: "km/h", def: 54, min: 10, max: 120, step: 1 },
        { key: "rho", label: "Air density ρ", unit: "kg/m³", def: 1.2, min: 1.0, max: 1.3, step: 0.005 },
        { key: "Vcore", label: "Target core-face velocity", unit: "m/s", def: 6, min: 1, max: 30, step: 0.5 },
        { key: "Vexit", label: "Duct exit velocity (after nozzle)", unit: "m/s", def: 11, min: 0, max: 60, step: 0.5 },
        { key: "K", label: "Core loss coefficient K", unit: "", def: 8, min: 1, max: 40, step: 0.5 },
      ],
      compute(v) {
        const V = v.V / 3.6;
        const q = 0.5 * v.rho * V * V;
        const Ainlet = v.mdot / (v.rho * V);
        const Acore = v.mdot / (v.rho * v.Vcore);
        const ratio = Acore / Ainlet;
        const dP = v.K * 0.5 * v.rho * v.Vcore * v.Vcore;
        const dPfreestream = v.K * 0.5 * v.rho * V * V;
        const dragReduction = (V > 0 && v.Vcore > 0) ? Math.pow(V / v.Vcore, 2) : 1;
        const Dcool = v.mdot * (V - v.Vexit);
        return {
          outputs: [
            { label: "Dynamic pressure q", value: f(q, 3), unit: "Pa" },
            { label: "Inlet area A_inlet (capture)", value: f(Ainlet, 4), unit: "m²" },
            { label: "Core area A_core (diffused)", value: f(Acore, 4), unit: "m²", hl: true },
            { label: "Diffusion area ratio", value: f(ratio, 3), unit: "×" },
            { label: "Core ΔP at V_core", value: f(dP, 3), unit: "Pa" },
            { label: "ΔP cut vs no diffusion", value: f(dragReduction, 3), unit: "×" },
            { label: "Cooling drag D_cool", value: f(Dcool, 3), unit: "N", hl: true },
          ],
          note: "Diffusing from " + f(V, 2) + " to " + f(v.Vcore, 2) + " m/s cuts core ΔP by ~" + f(dragReduction, 2) +
            "× (it scales with V_core²). Seal the duct so all captured air passes the core, and route the outlet into a low-pressure wake to pull flow at low speed. Meredith thrust recovery is negligible at q=" + f(q, 0) + " Pa.",
        };
      },
    },
  };
})();
