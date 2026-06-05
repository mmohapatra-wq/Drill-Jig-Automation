# Drill Jig Automation

Automation tooling that leverages the Creo Parametric VB API to **generate drill jigs** — locating geometry, bushing placements, and jig plates — directly from a part's hole pattern, without requiring software licenses beyond standard Creo Parametric.

## Goal

The objective of this repository is to automate the creation of drill jig tooling in Creo Parametric. Given a part or its hole pattern, the target workflow is to:

1. Read hole locations and diameters from the source model
2. Build the jig body / plate geometry
3. Place locating features and drill bushings at each hole
4. Produce a jig model ready for downstream manufacturing

The work builds on a proven set of Creo automation techniques (see **Baseline** below) that already demonstrate every primitive the jig workflow needs: capturing user selections, reading and writing model data through the VB API, and driving feature creation through scripted Creo commands.

## Approach

All tooling is packaged as single-file `.cmd` executables that embed PowerShell. Each script connects to a live Creo session over the VB API COM interface (`pfcls`), uses the API to gather selections and model data, then executes operations through direct `RunMacro` commands. This means complex, repetitive modeling operations can be performed reliably and at scale, with no add-on licenses required.

Two complementary techniques are used throughout:

- **Programmatic (VB API)** — reads and writes Creo data directly without touching the UI. Stable across Creo versions. Used for data extraction and geometry traversal (e.g. enumerating bodies, surfaces, edges, dimensions, and mass properties).
- **Mapkeys** — drives the Creo UI by replaying recorded command and widget interactions. Used for feature creation (rounds, extrudes, thickens, flips). More version-sensitive, but able to create geometry the API alone cannot.

## Baseline — Proven Techniques (Proof of Concept)

The tools below were developed for orthogrid and structural modeling workflows. They are included here as a **proof of concept and a reusable foundation**: each one demonstrates a capability the drill jig automation depends on. Rather than full end-user docs, the focus here is on *what technique each tool proves out*.

| Tool | Proves out | Relevance to drill jig automation |
|------|-----------|-----------------------------------|
| **[gauginator.cmd](gauginator.cmd)** | Whole-model traversal + data extraction to CSV — enumerate every body, read all dimensions (name/type/value), capture center-of-gravity mass properties | Reading hole locations, diameters, and reference geometry out of a source part |
| **[nodelator.cmd](nodelator.cmd)** | Copying a feature to many datum-point locations via Paste-Special **by reference**, rerouting each placement reference | Placing a bushing / locator feature at every hole in a pattern |
| **[surfenator.cmd](surfenator.cmd)** | Programmatic feature creation between datum planes — projecting curves and driving extrudes with plane-based depth | Building jig plate / body geometry constrained to reference planes |
| **[thickenator.cmd](thickenator.cmd)** | Mapkey-driven feature creation with parameter input (thicken quilt → solid, with direction and body options) | Turning surface geometry into solid jig bodies |
| **[flipenator.cmd](flipenator.cmd)** | Batch selection capture (body ID vs. feature ID) and per-feature redefine operations | Bulk operations across many jig features |
| **[radinator.cmd](radinator.cmd)** | Pure-VB-API geometry filtering (edge length, curve type, adjacent-surface analysis) feeding batched mapkey feature creation | Identifying and operating on specific edges/holes by geometric criteria |
| **[gripenator.cmd](gripenator.cmd)** | Interactive part-number filtering and component replacement in an assembly via regex matching | Selecting and swapping standardized hardware (bushings, fasteners) by part number |

Two additional development tools demonstrate the dimension read/write loop that exact-geometry jig generation requires:

- **[diminator.cmd](diminator.cmd)** — reads a CSV of dimensions back **into** a model, with a 2-pass verify/repair loop that handles the difference between feature-level dims (write sticks immediately) and sketch dims (require a sketch-open regen to persist).
- **[boxinator.cmd](boxinator.cmd)** — creates a rectangular solid to exact width/height/depth, capturing each sketch dimension at placement and verifying every value stuck before reporting success. Proves out reliable, *verified* parametric geometry creation end to end.

Together these establish that the full jig pipeline — **read source data → create geometry → place repeated features → verify dimensions** — is achievable with this toolchain.

## Requirements

### Software Prerequisites
- **Creo Parametric** (any recent version with VB API support)
- **Windows PowerShell** 5.1 or later
- **Active Creo session** running before script execution

### Creo VB API Setup
The scripts handle the VB API connection automatically, but ensure:
- Creo VB API COM components are registered (normally done during Creo installation; first run will attempt registration via `vb_api_register.bat`)
- No additional Creo licenses required beyond standard Parametric
- The user has appropriate Creo modeling rights for the operations being performed

## Usage

### Execution (Simple Double-Click)
All tools are packaged as single-file `.cmd` executables:

1. **Open Creo** and load your model
2. **Double-click** the desired `.cmd` file
3. **Follow the prompts** in the PowerShell window
4. **Switch to Creo** when prompted to make selections, then return to the PowerShell window to continue
5. **Review results** in the Creo model

### Legacy Source Files
Original `.ps1` source files are preserved in the `ps1 archive/` folder for reference. The `.cmd` files are self-contained and do not require the `.ps1` files to run.

## Troubleshooting

**"Cannot find Creo process"**
- Ensure Creo Parametric is running before executing a script
- Only one Creo process should be active; restart Creo if the connection fails

**"VB API registration error"**
- VB API COM components may need re-registration
- Run a Creo installation repair, or contact IT for COM registration

**Script hangs during execution**
- Switch to the Creo window — the script may be waiting for a selection
- Check the PowerShell window for prompts
- Ensure the model is in the appropriate mode (Part / Assembly as required)

**Mapkey-driven step stopped working after a Creo upgrade**
- Widget names can change between Creo versions. Set `visible_mapkeys yes` in `config.pro` to inspect the current widget names and update the affected mapkey.

### Getting Help
- Review the PowerShell window output for specific error messages
- Check the Creo message log for additional detail
- Ensure all prerequisite geometry exists before running a script
- Try a script on simple test geometry first

## License

Internal Blue Origin toolset. See company policies for usage and distribution guidelines.

## Authors

- **M. Mohapatra** — Drill jig automation
- **Kyle Brooker** — Baseline orthogrid automation workflows (proof of concept)
- **Ethan Iglehart** — Gauginator development (proof of concept)
