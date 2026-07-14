# FSAE Thermal Academy

Interactive learning software that teaches **thermal engineering** using a real
rocket-engine system thermal model (Blue Origin **BE-3U**, ANSYS Thermal Desktop /
SINDA) as the anchor, and **bridges every concept to designing the cooling system
and aerodynamics of a Formula Student / FSAE electric race car**.

## Run it

Open **`index.html`** in any browser — no server, no build, no internet.
(Double-click it, or `file:///…/fsae-thermal-academy/index.html`.)

## What's inside

- **9 modules**, each with: physics + exact equations → how the BE-3U rocket model
  uses it → the FSAE EV design bridge with realistic numbers → a fully worked numeric
  example → a **live calculator** → a short quiz.
  1. Heat-transfer modes & the resistance network
  2. Conduction & contact conductance across joints
  3. Forced convection: Dittus-Boelter & Gnielinski (cold plates)
  4. Lumped capacitance, the Biot number & mesh sensitivity
  5. Radiator sizing: LMTD & effectiveness-NTU
  6. Thermal radiation & when it actually matters
  7. The nodal network method (SINDA / Thermal Desktop)
  8. FSAE aerodynamics: downforce & drag
  9. Cooling drag & radiator ducting (thermal × aero)
- **9 interactive calculators** (resistance chain, conduction/contact, convection,
  Biot/time-constant, ε-NTU radiator sizing, radiation crossover, explicit-stability
  step, aero downforce/drag, cooling-drag duct sizing).
- **The Bridge Map** (rocket ↔ FSAE correlation table) and a **Glossary & Sources** page.
- Progress + quiz state persist in the browser (`localStorage`).

## Files

| File | Purpose |
|------|---------|
| `index.html` | App shell: design system, navigation, renderers, math notation, quiz logic |
| `curriculum.js` | All module content, bridge table, glossary, source map (data-driven) |
| `calculators.js` | The 9 calculator compute functions (pure JS) |

## Provenance & accuracy

Physics, equations, and numbers were researched across standard heat-transfer
references and **adversarially fact-checked** (62 of 77 claims confirmed correct;
the rest corrected and applied — e.g. the ε-NTU crossflow inversion giving
NTU ≈ 1.12 / UA ≈ 508 W/K, and the Biot characteristic-length convention).
The ε-NTU calculator's inversion was independently re-verified to reproduce the
worked example. The two Blue Origin Confluence pages are used to explain *modeling
methodology*; **no proprietary geometry, results, or controlled data are reproduced**.

Calculators are teaching tools — validate any real design against test data, as the
rocket team does (≈10–20 % thermal-model-to-test accuracy is normal).
