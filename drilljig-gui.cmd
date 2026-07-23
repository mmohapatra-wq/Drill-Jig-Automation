<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -STA -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

# ============================================================================
# drilljig-gui.cmd - GUI front-end for the drill-jig flow (Milestone 1)
# ============================================================================
# A single never-closing WinForms WIZARD window that drives the SAME end-to-end
# drill-jig flow as drilljig.cmd (decision tree -> point source -> box -> datum
# points -> corner round -> drill -> chip relief), but with no console typing:
# every decision is a card or field, and every UNAVOIDABLE Creo mouse pick
# (multi-select the 3 datums, draw the rectangle, hand-pick points) is its own
# "arm + verify" step whose Next button stays disabled until the selection buffer
# validates -- so a wrong/empty pick structurally cannot leak into the geometry.
#
# Milestone 1 scope (this file):
#   * the wizard shell + breadcrumb + honesty chips + RUN view (lib\wizard.ps1)
#   * the proven Creo engine, called VERBATIM (lib\drilljig_core.ps1)
#   * the EXISTING orthogrid / custom editors launched AS MODALS for the layout
#     (lib\orthogrid_gui.ps1) -- the in-canvas embed is a later milestone
#
# drilljig.cmd is LEFT UNTOUCHED and still runs standalone; this is an additive
# second front-end over the shared lib. Open the jig PART (not the .asm).
#
# Flags: --no-corner-round, --corner-radius N (same as drilljig.cmd).
# ============================================================================

$Host.UI.RawUI.WindowTitle = "DRILLJIG GUI"
$ErrorActionPreference = "Stop"

trap {
    Write-Host ""
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $inv = $_.InvocationInfo
    if ($null -ne $inv) { Write-Host ("  at line {0}: {1}" -f $inv.ScriptLineNumber, $inv.Line.Trim()) -ForegroundColor DarkYellow }
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

# ---- dot-source the shared libs (order matters; same as drilljig.cmd) -------
. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')
. (Join-Path $ScriptDir 'lib\edge_round.ps1')
. (Join-Path $ScriptDir 'lib\orthogrid.ps1')
. (Join-Path $ScriptDir 'lib\orthogrid_gui.ps1')
. (Join-Path $ScriptDir 'lib\orthogrid_points.ps1')
# Import-fastener-layout mode (Layout tile #4): the GUI is FILE-ONLY (loads a
# fastener_layout.json written by fastenator.cmd -- no in-wizard live read, so
# $ctx.Model is never rebound to a fastener model). Read-FastenerLayout only.
. (Join-Path $ScriptDir 'lib\fastener_layout.ps1')
. (Join-Path $ScriptDir 'lib\drilljig_core.ps1')
# bushing schematic renderer (Draw-BushingSchematic / Get-BushingLayout / etc.) - a
# DISPLAY-ONLY GDI+ picture of the picked bushing shown on the bushing-confirmation
# page. All functions are global:, so the confirmation view's .GetNewClosure() Paint
# handler resolves them. System.Drawing is loaded by wizard.ps1 before any paint.
. (Join-Path $ScriptDir 'lib\bushing_svg.ps1')
# WPF Media3D bushing 3D preview (Build-BushingModelGroup + mesh helpers), shown NEXT
# TO the 2D schematic on the bushing-confirmation page. WPF needs its assemblies + an
# STA thread (the launcher passes -STA). Loaded GUARDED: if WPF is unavailable the
# confirmation degrades to the 2D schematic only (never crashes). $script:Wpf3dOk gates it.
. (Join-Path $ScriptDir 'lib\wpf3d_preview.ps1')
$script:Wpf3dOk = $false
try {
    Add-Type -AssemblyName PresentationCore -ErrorAction Stop
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    Add-Type -AssemblyName WindowsBase -ErrorAction Stop
    Add-Type -AssemblyName WindowsFormsIntegration -ErrorAction Stop
    $script:Wpf3dOk = $true
} catch { $script:Wpf3dOk = $false }
# WebView2 host (Resolve-WebView2Assets / Add-WebView2Assemblies) - lets the Overview
# AND Welcome stages embed the three.js 3D preview (docs\drilljig_3d_preview.html).
# Lazy-loaded when those pages are reached; the rest of the GUI is unaffected if
# WebView2 is unavailable (the pages degrade to a note).
. (Join-Path $ScriptDir 'lib\webview2_host.ps1')
. (Join-Path $ScriptDir 'lib\wizard.ps1')

$dataDir = Join-Path $ScriptDir 'data'

# Corner-round flags (same contract as drilljig.cmd).
$cornerRadius = 0.25
$mCr = [regex]::Match($ScriptArgs, '(?i)--corner-radius\s+([0-9]*\.?[0-9]+)')
if ($mCr.Success) { $cornerRadius = [double]$mCr.Groups[1].Value }
$noCornerRound = ($ScriptArgs -match '(?i)--no-corner-round')

# chip-relief SLOTS (slotinator method): depth = absolute inches (default 0.25");
# the plate is padded by this same value so the final guide depth = the bushing
# length after the slot is cut. Direction flags mirror slotinator/drilljig.cmd.
$SLOT_DEPTH_ABS  = 0.25
$mSdpG = [regex]::Match($ScriptArgs, '(?i)--slot-depth\s+([0-9]*\.?[0-9]+)')
$slotDepthFromFlagG = $false
if ($mSdpG.Success) { $pSdpG = [double]$mSdpG.Groups[1].Value; if ($pSdpG -gt 0) { $SLOT_DEPTH_ABS = $pSdpG; $slotDepthFromFlagG = $true } }
$slotFlipDefault = ($ScriptArgs -match '(?i)--slot-flip')
$slotPatternFlip = ($ScriptArgs -match '(?i)--pattern-flip')
$slotNoPattern   = ($ScriptArgs -match '(?i)--no-pattern')
$noSlotRelief    = ($ScriptArgs -match '(?i)--no-slot-relief')
# Chip-relief slot removal-path DIRECTION (X or Z). The 'slot-dir' step (Relief stage)
# OFFERS the choice for an imported FASTENER layout (user 2026-07-23); orthogrid/custom
# keep 'X'. --slot-dir X|Z pins it (skips the step's cards). $slotDirFlag = 'X'|'Z'|$null.
$mSlotDirG = [regex]::Match($ScriptArgs, '(?i)--slot-dir\s+([XZxz])')
$slotDirFlag = if ($mSlotDirG.Success) { Resolve-SlotRowAxis -Text $mSlotDirG.Groups[1].Value } else { $null }
# csys-referenced architecture: box + grid planes offset from a base csys (not the
# default datums), so re-placing the base csys onto the index hole moves the grid.
$noBaseCsys      = ($ScriptArgs -match '(?i)--no-base-csys')   # revert to legacy default-datum planes
# INDEX-FIRST axis-flip flags: the index-hole base csys is built from 3 intersecting planes
# and this build reads plane normals as null, so its Axis_X/Axis_Z DIRECTIONS aren't
# programmatically verifiable. If holes come out mirrored on an axis, flip that axis's grid
# offset sign with --index-flip-x / --index-flip-z (no code change / re-run needed).
$indexFlipX      = if ($ScriptArgs -match '(?i)--index-flip-x') { -1.0 } else { 1.0 }
$indexFlipZ      = if ($ScriptArgs -match '(?i)--index-flip-z') { -1.0 } else { 1.0 }
# (An earlier --fastener-index opt-in that DISABLED index-first for imported fastener
# layouts was REMOVED 2026-07-21: it made fastener diverge from orthogrid/custom. Every
# laid-out layout now converges to the SAME index-choice -> box path, and the index-first
# intersected-csys plane bug it feared was fixed in STAGE 2.5 (Get-IndexDirectionalPlanePlan
# builds the grid planes off CSYS_PAT_DEF at absolute coords). Index is ALWAYS set now.)
# (The STAGE 5.5 change-the-base-csys / --reref-method options were removed 2026-07-16:
# relocating the base after the jig was built left references off and CUT the jig. In
# index-first mode the base csys is born at the index hole, so no relocation is needed.)

# ============================================================================
# The shared CONTEXT hashtable - every wizard step reads/writes it. Holds the
# decision-tree results, the captured layout, the Creo handles, and the captured
# plane/point ids as the run progresses.
# ============================================================================
$ctx = @{
    # STAGE 1
    TreePath    = Join-Path $ScriptDir 'docs\drill_jig_decision_tree.json'
    Path        = [System.Collections.ArrayList]::new()   # chosen labels (provenance)
    Picks       = [System.Collections.ArrayList]::new()    # resolved bushing picks
    HoleDia     = $null
    BushingLen  = $null
    Is3dPrint   = $false
    # tree-walk cursor (the decision-tree step descends this in place)
    TreeNode    = $null
    TreeDone    = $false
    # bushing pick cursor (ID-first: ID -> STANDARDIZED length menu -> OD tie-break).
    # user 2026-07-21: length is a FIXED {1/2,3/4,1}+Custom menu recommended from the ID;
    # OD is re-keyed on ID ALONE (Get-IdOdOptions), auto-resolved when unique.
    PendingSpec = $null      # catalog spec awaiting an ID/length/OD pick
    BushStage   = $null      # 'id' | 'len' | 'od' (id-first) or 'od1' | 'len' (od-first metal)
    Grouped     = $null      # catalog grouped by ID (persistent so OnPick can index it)
    BushID      = $null      # chosen ID group (from Group-CatalogByID)
    # OD-FIRST metal path (user 2026-07-22): METAL -> PFD / Hand Drill is OD-filtered; the
    # operator picks the OD (= drilled hole) directly, ID is unspecified. BushOdFirst gates
    # the OD-first sub-flow; BushOdGroups = Get-OdGroups (persistent for OnPick); BushOD =
    # the chosen OD group. Set-BushLengthPick reads these when BushOdFirst is true.
    BushOdFirst = $false     # true when PendingSpec is the metal OD-first path
    BushOdGroups = $null     # Get-OdGroups for the metal spec (persistent for OnPick)
    BushOD      = $null      # chosen OD group (OD-first metal path)
    BushOdOptions   = $null  # Get-IdOdOptions for the chosen ID (persistent for OnPick)
    BushLenValue    = $null  # chosen length (double; fixed or custom)
    BushLenLabel    = $null  # chosen length machinist label ('1/2' / '3/4' / '1' / custom)
    BushLenIsCustom = $false # 'len' sub-state: showing the custom textbox
    BushLenCustomText = ''   # raw custom textbox string (survives Pop/Rerender)
    BushLenValid    = $true  # gates the custom "Use this length" commit
    # CUSTOM HOLE OD (user 2026-07-23): a "Custom hole OD..." card on BOTH the OD list
    # (metal) and the ID list (sleeve) lets the operator type an arbitrary hole diameter.
    # BushCustom gates the 'customod' sub-stage; the typed OD lives in BushCustomOd (double)
    # + BushCustomOdLabel/Text; BushCustomOdValid gates the "Use this OD" commit. There is
    # no catalog SKU behind a typed OD, so a bold verify-bushing warning is shown.
    BushCustom      = $false # true when the operator chose "Custom hole OD..."
    BushCustomOd    = $null  # typed hole diameter (double)
    BushCustomOdLabel = $null # typed OD machinist/decimal label
    BushCustomOdText  = ''   # raw custom-OD textbox string (survives Pop/Rerender)
    BushCustomOdValid = $false # gates the "Use this OD" commit (blank OD is invalid)
    # POINT SOURCE
    PointMode    = 'predefined'
    OrthoGeo     = $null
    LayoutPicked = $false
    # RADIO-SELECT the tiles (user 2026-07-22): the recommended tile is auto-SELECTED (green)
    # so Next works immediately; clicking a different tile only MOVES the green highlight (it
    # does NOT open the sub-view) -- Next COMMITS the selection. LayoutSel = the selected tile
    # index (0=Skeleton,1=Orthogrid,2=Custom,3=Fastener); default 3 = the recommended Fastener.
    LayoutSel    = 3
    LayoutMode   = $null      # $null = show tiles; 'orthogrid'|'custom'|'fastener' = inline editor
    # IMPORT FASTENER LAYOUT (Layout tile #4): FILE-ONLY here. The path of the
    # fastener_layout.json loaded (provenance); the live read lives in fastenator.cmd.
    FastenerLayoutPath = $null
    OrthoValid   = $false     # the inline editor's current validity (gates Next)
    OrthoFields  = $null      # persistent {CcX;CcZ;Nx;Nz;Edge} for the inline grid editor
    CustomRows   = $null      # persistent ArrayList of {X;Z} for the inline custom editor
                              # (each row = one OTHER hole's offset FROM THE INDEX hole)
    CustomIndex  = $null      # persistent @{X;Z} = the index hole's offset from the plate
                              # corner (the ONE corner-measured hole; = Points[0]). The
                              # inline custom editor is INDEX-RELATIVE (user 2026-07-21).
    # INDEX-FIRST (2026-07-15): the operator can pick an index hole in the layout step;
    # the base csys is then built AT that hole (STAGE 1.9) and grid offsets are relative
    # to it -> the jig references the index hole, geometry unchanged, no base move/cut.
    IndexFirst   = $false     # true once an index hole is chosen up front
    IndexKey     = $null      # the chosen candidate Key (ordinal into OrthoGeo.Points)
    # Creo
    Session     = $null
    Model       = $null
    Type        = $null
    ModelName   = ''
    Connected   = $false
    # STAGE 1.9 base coordinate system (everything hangs off it -> STAGE 5.5 re-ref)
    BaseCsysId  = $null    # feature id of the base csys (created in box-a's OnNext)
    RefCsysId   = $null    # feature id of the part default csys (CSYS_PAT_DEF) the base was made from
    # Index-hole ANCHOR planes (the 3 planes off CSYS_PAT_DEF that built the index csys,
    # [X@indexX, Y@0, Z@indexZ]). STAGE 2.5 REUSES the X/Z anchor for the grid coordinate
    # that coincides with the index hole (relative offset 0) instead of a redundant plane.
    IndexAnchorX = $null
    IndexAnchorZ = $null
    UseCsys     = $null    # $true once the base csys is made; $false = legacy datums
    FaceId      = $null    # reserved/unused: the box + grid sketch/intersect on the SIDE
                           # default datum in both modes (an Axis_Y @ 0 csys plane was a
                           # poor sketch plane and broke the extrude, so F was removed)
    # STAGE 2 planes
    Planes      = $null
    AutoMapped  = $false
    SidePlane   = $null
    Made        = @()
    BoxArmed    = $false   # Box-A armed the sketcher; gates Box-B
    SketchPlaneId = $null
    ExtrudeToId   = $null
    BoxBuilt    = $false
    # snapshot of what the COMMITTED plate was sized for (set in box-b). A later upstream
    # change (different bushing OD, edited layout) recomputes HoleDia/OrthoGeo but the built
    # plate + holes are frozen -> compare against these to WARN of a stale/oversized plate.
    BuiltHoleDia = $null
    BuiltPlateW  = $null
    BuiltPlateH  = $null
    # STAGE 2.5 points
    GridPointIDs = @()
    GridPlaneIds = @()
    # csys registry: WAS consumed by the post-slot index-hole stage (removed 2026-07-21;
    # the index hole is established up front / index-first). Left as a harmless record --
    # the drill step still fills it, but nothing reads it now.
    CsysRecords = @()
    # STAGE 3
    PointIDs    = @()
    BodyIndex   = 0
    HoleDiaFinal = 0.0
    Drilled     = $false
    # index-first grid coords: the index hole chosen UP FRONT (box-a's STAGE 1.9 + the
    # drill step offset the grid planes relative to these). NOT the removed post-slot stage.
    IndexGridX    = $null
    IndexGridZ    = $null
    # STAGE 4 chip-relief SLOTS (slotinator method; replaces relief holes + paths)
    SlotArmed    = $false     # slot-a armed the seed sketcher; gates slot-b
    SlotSkip     = $false     # metal declined, or no layout -> skip the slot stage
    SlotFlip     = $false     # confirmed cut-direction flip (learned on the seed)
    SlotPlan     = $null      # {Mode='pattern'|'perrow'; SeedRow; Patterns[]; Rows[]; SlotWidth; RowAxis; CrossAxis; Depth; FaceId; DirDatumId; DirName}
    SlotRunIndex = 0          # PER-ROW mode: which row slot-b is currently drawing/cutting
    SeedCut      = $false     # PATTERN mode: the ONE seed slot has been cut + direction-verified
    SlotAnyCut   = $false     # a slot was cut (>=1) -> the plate is at least partly relieved
    SlotWarn     = $false     # a pattern did not verify (seed only) -> surface it honestly at the summary
    SlotHasPlanes = $false    # slot-a made the visible slot-edge guide planes -> show the CTRL+ALT snap technique
    SlotsDone    = $false
    # SLOT DIRECTION (removal-path axis) -- 'X'|'Z', or $null = not chosen yet (defaults to
    # 'X' at the Get-RowSlots cut). The 'slot-dir' step (Relief stage) OFFERS X/Z for an
    # IMPORTED FASTENER layout (user 2026-07-23); orthogrid/custom keep 'X'. Seeded from
    # --slot-dir (pins it + marks SlotDirFromFlag so the step skips the cards).
    SlotRowAxis     = $slotDirFlag                    # 'X'|'Z'|$null
    SlotDirFromFlag = ($null -ne $slotDirFlag)        # --slot-dir given -> no cards, just confirm
    # CHIP-RELIEF DEPTH BUDGET -- decided in box-a's OnNext (BEFORE the planes are made) so
    # the SIDE/extrude offset can be PADDED by the relief depth: plate = bushingLen + SLOT_DEPTH_ABS,
    # the slot removes SLOT_DEPTH_ABS, so the final guide depth == bushingLen. $WillSlot is
    # the single relief decision (3D print auto / metal asked / --no-slot-relief or no
    # layout = no); reused by the Relief stage so the operator is not asked twice.
    WillSlot     = $null      # $null = not yet decided; $true/$false after box-a
    ReliefPad    = 0.0        # absolute inches added to the extrude (SlotDepth when WillSlot, else 0)
    # SLOT / GUIDE DEPTH -- the effective chip-relief slot depth (inches). Seeded from
    # $SLOT_DEPTH_ABS (default 0.25 / --slot-depth flag) and settable in the 'slot-depth'
    # step (Bushing stage) via the tight/restricted-space question. It doubles as the
    # plate EXTRUDE PAD (plate = bushing length + SlotDepth), so a smaller depth = a
    # thinner overall plate. Routed through $ctx (a hashtable, mutable across steps) so
    # a step's write is visible to box-a/slot-a/done -- a top-level $SLOT_DEPTH_ABS write
    # from inside a step block would NOT be (script-scope + closure trap). User 2026-07-21.
    SlotDepth        = [double]$SLOT_DEPTH_ABS
    SlotSpaceMode    = $null      # $null = not asked; 'standard' | 'tight' | 'flag'
    SlotDepthFromFlag = $slotDepthFromFlagG   # --slot-depth given -> skip the question
    SlotDepthValid   = $true      # gates Next in the tight branch (default 0.25 is valid)
    # HOLE-TO-EDGE MARGIN -- the required wall from a border hole's EDGE to the part
    # edge. Asked in the 'edge-margin' step (Bushing stage) RIGHT AFTER the bushing tree
    # and BEFORE the slot-depth step (user 2026-07-23: an option for SMALLER edge margins
    # so a border hole can sit closer to the part edge, shrinking the plate in tight jobs).
    # The default wall is one full hole DIAMETER (the 2026-07-21 rule). This value threads
    # into EVERY layout site (orthogrid Edge lock + -EdgeMargin, custom/index -EdgeMargin +
    # seed, fastener re-anchor + -EdgeMargin) via Get-EffectiveEdgeMargin. $null = not
    # chosen -> the sites default to the hole diameter, so this is backward-compatible.
    EdgeMargin       = $null      # chosen wall in inches, or $null = default (hole dia)
    EdgeMarginMode   = $null      # $null = not asked; 'standard' | 'custom'
    EdgeMarginValid  = $true      # gates Next in the custom branch (default is valid)
    # IMPORT-FIRST (user 2026-07-20): the fastener read is offered as the FIRST stage,
    # before Bushing. It captures RAW {X;Z} points here; the Layout stage builds the
    # plate from them once the hole dia is known (re-anchored via Set-LayoutMargin).
    FastenerRawPoints = $null  # captured raw points, or $null (not imported)
    FastenerAsked     = $false # the import step was visited (so it does not re-prompt)
}

# ----------------------------------------------------------------------------
# Convenience: append a line to the wizard run log (used by the engine logger).
# Set when a RUN step starts so Initialize-DrilljigCore can route Write-DJ output
# into the on-screen log. $script:GuiWiz is the live $wiz controller.
# ----------------------------------------------------------------------------
$script:GuiWiz = $null
$djLogger = {
    param([string]$Text, [string]$Color)
    if ($null -ne $script:GuiWiz) { try { $script:GuiWiz.Log($Text) } catch {} }
}

# ============================================================================
# STEP BUILDERS - each returns a populated canvas. Helpers first.
# ============================================================================

# Resolve a friendly colour NAME to a dark-theme-bright RGB so text stays visible
# on the darkish-blue canvas. Reads $script:WizTheme (set by Show-Wizard) for the
# base ink/muted/ok/warn colours; falls back to sane brights if it isn't set.
function Get-UiColor {
    param([string]$Name)
    $thm = $script:WizTheme
    $ink   = if ($thm) { $thm.Ink }   else { [System.Drawing.Color]::FromArgb(238,242,248) }
    $muted = if ($thm) { $thm.Muted } else { [System.Drawing.Color]::FromArgb(158,172,196) }
    $ok    = if ($thm) { $thm.Ok }    else { [System.Drawing.Color]::FromArgb(120,210,150) }
    $warn  = if ($thm) { $thm.Warn }  else { [System.Drawing.Color]::FromArgb(245,200,90) }
    $err   = if ($thm) { $thm.Err }   else { [System.Drawing.Color]::FromArgb(245,120,110) }
    switch (("" + $Name).ToLower()) {
        ''           { return $ink }
        'gray'       { return $muted }
        'darkgray'   { return $muted }
        'darkgreen'  { return $ok }
        'green'      { return $ok }
        'firebrick'  { return $err }
        'red'        { return $err }
        'yellow'     { return $warn }
        'goldenrod'  { return $warn }
        default      { return $ink }
    }
}

# ============================================================================
# Push-TreeHistory / Pop-TreeHistory - a decision-history STACK for the bushing
# decision tree + sleeve sub-flow (ID -> length -> OD), so the operator can step
# BACK and forth one decision at a time (user 2026-07-21: "go back and forth
# between the bushing sleeve selection"). Push a snapshot of the CURRENT tree-walk
# state at the START of every forward pick; Pop restores the previous snapshot.
# global: so the tree step's .GetNewClosure() OnPick/Button handlers resolve them.
# All state lives in the shared $Context (never a Build-local / top-level var - the
# captured-variable rule that caused the "Change selection -> Tree finished" bug).
# ============================================================================
function global:Push-TreeHistory {
    param($Context)
    if ($null -eq $Context.TreeHistory) { $Context.TreeHistory = [System.Collections.ArrayList]::new() }
    [void]$Context.TreeHistory.Add([pscustomobject]@{
        Node        = $Context.TreeNode
        PathCount   = @($Context.Path).Count
        PendingSpec = $Context.PendingSpec
        BushStage   = $Context.BushStage
        BushID      = $Context.BushID
        BushOdFirst = $Context.BushOdFirst
        BushOdGroups = $Context.BushOdGroups
        BushOD      = $Context.BushOD
        BushOdOptions   = $Context.BushOdOptions
        BushLenValue    = $Context.BushLenValue
        BushLenLabel    = $Context.BushLenLabel
        BushLenIsCustom = $Context.BushLenIsCustom
        BushLenCustomText = $Context.BushLenCustomText
        BushLenValid    = $Context.BushLenValid
        BushCustom      = $Context.BushCustom
        BushCustomOd    = $Context.BushCustomOd
        BushCustomOdLabel = $Context.BushCustomOdLabel
        BushCustomOdText  = $Context.BushCustomOdText
        BushCustomOdValid = $Context.BushCustomOdValid
        Grouped     = $Context.Grouped
        PicksCount  = @($Context.Picks).Count
    })
}
# Restore the previous snapshot. Returns $true if it moved back, $false if the
# history was empty (already at the first question). Trims $Context.Path and
# $Context.Picks back to the snapshot's counts and clears TreeDone.
function global:Pop-TreeHistory {
    param($Context)
    if ($null -eq $Context.TreeHistory -or @($Context.TreeHistory).Count -eq 0) { return $false }
    $li = $Context.TreeHistory.Count - 1
    $snap = $Context.TreeHistory[$li]
    $Context.TreeHistory.RemoveAt($li)
    $Context.TreeNode    = $snap.Node
    $Context.PendingSpec = $snap.PendingSpec
    $Context.BushStage   = $snap.BushStage
    $Context.BushID      = $snap.BushID
    $Context.BushOdFirst = $snap.BushOdFirst
    $Context.BushOdGroups = $snap.BushOdGroups
    $Context.BushOD      = $snap.BushOD
    $Context.BushOdOptions   = $snap.BushOdOptions
    $Context.BushLenValue    = $snap.BushLenValue
    $Context.BushLenLabel    = $snap.BushLenLabel
    $Context.BushLenIsCustom = $snap.BushLenIsCustom
    $Context.BushLenCustomText = $snap.BushLenCustomText
    $Context.BushLenValid    = $snap.BushLenValid
    $Context.BushCustom      = $snap.BushCustom
    $Context.BushCustomOd    = $snap.BushCustomOd
    $Context.BushCustomOdLabel = $snap.BushCustomOdLabel
    $Context.BushCustomOdText  = $snap.BushCustomOdText
    $Context.BushCustomOdValid = $snap.BushCustomOdValid
    $Context.Grouped     = $snap.Grouped
    $Context.TreeDone    = $false
    while (@($Context.Path).Count  -gt [int]$snap.PathCount)  { $Context.Path.RemoveAt($Context.Path.Count - 1) }
    while (@($Context.Picks).Count -gt [int]$snap.PicksCount) { $Context.Picks.RemoveAt($Context.Picks.Count - 1) }
    return $true
}
# Full reset of the tree walk back to the first question (Start over). Reads the
# root from the CONTEXT ($Context.TreeRoot), never a captured top-level var.
function global:Reset-TreeWalk {
    param($Context)
    $Context.TreeDone = $false; $Context.PendingSpec = $null; $Context.BushStage = $null
    $Context.Grouped = $null; $Context.BushID = $null
    $Context.BushOdFirst = $false; $Context.BushOdGroups = $null; $Context.BushOD = $null
    $Context.BushOdOptions = $null; $Context.BushLenValue = $null; $Context.BushLenLabel = $null
    $Context.BushLenIsCustom = $false; $Context.BushLenCustomText = ''; $Context.BushLenValid = $true
    $Context.BushCustom = $false; $Context.BushCustomOd = $null; $Context.BushCustomOdLabel = $null
    $Context.BushCustomOdText = ''; $Context.BushCustomOdValid = $false
    $Context.TreeNode = $Context.TreeRoot
    if ($null -ne $Context.Path)  { $Context.Path.Clear() }
    if ($null -ne $Context.Picks -and @($Context.Picks).Count -gt 0) { $Context.Picks.Clear() }
    if ($null -ne $Context.TreeHistory) { $Context.TreeHistory.Clear() }
    $Context.HoleDia = $null; $Context.BushingLen = $null
}
# Commit a chosen bushing length into the walk: record it, then resolve OD from the
# ID's OD set -- UNIQUE OD auto-resolves (records the pick + TreeDone), >1 OD advances
# to the 'od' tie-break. SHARED by the fixed-length card OnPick, the custom "Use this
# length" button, AND the "Next commits the recommended length" path so all three behave
# identically. global: so it resolves from any handler (closure or plain). Returns
# 'done' | 'od' (or 'noop' if inputs are missing). Note it calls Resolve-BushingPickRow,
# itself global, so this is safe inside a .GetNewClosure().
function global:Set-BushLengthPick {
    param($Context, [double]$LenValue, [string]$LenLabel)
    $Context.BushLenValue = [double]$LenValue
    $Context.BushLenLabel = [string]$LenLabel
    # CUSTOM-OD path (user 2026-07-23): the operator typed an arbitrary hole OD (no catalog
    # SKU behind it). $Context.BushCustomOd holds the typed diameter; resolve via
    # Resolve-CustomOdPick (ID '(custom)', PartNumber flags verify) and finish. This MUST be
    # the FIRST branch -- a custom pick sets neither BushOdFirst nor BushID, so without it
    # the ID-null guard below would no-op and the pick would silently drop.
    if ($Context.BushCustom) {
        if ($null -eq $Context.BushCustomOd) { return 'noop' }
        $pick = Resolve-CustomOdPick -OD ([double]$Context.BushCustomOd) -Length ([double]$LenValue) -LenLabel ([string]$LenLabel) -OdLabel ([string]$Context.BushCustomOdLabel)
        [void]$Context.Picks.Add([pscustomobject]@{ HoleDiameter=[double]$pick.OD; BushingID=$pick.ID; BushingLength=[double]$pick.Length; Bushing=$pick.EasyName; PartNumber=$pick.PartNumber; Outcome=$Context.TreeNode.label })
        $Context.PendingSpec = $null; $Context.BushStage = $null; $Context.TreeDone = $true
        return 'done'
    }
    # OD-FIRST metal path (user 2026-07-22): no ID was chosen (the drilled hole IS the
    # removable bushing's OD). $Context.BushOD holds the chosen OD group; resolve via
    # Resolve-OdBushingPick (ID unspecified) and finish -- there is never an OD tie-break.
    if ($Context.BushOdFirst) {
        if ($null -eq $Context.BushOD) { return 'noop' }
        $pick = Resolve-OdBushingPick -OdGroup $Context.BushOD -Length ([double]$LenValue) -LenLabel ([string]$LenLabel)
        [void]$Context.Picks.Add([pscustomobject]@{ HoleDiameter=[double]$pick.OD; BushingID=$pick.ID; BushingLength=[double]$pick.Length; Bushing=$pick.EasyName; PartNumber=$pick.PartNumber; Outcome=$Context.TreeNode.label })
        $Context.PendingSpec = $null; $Context.BushStage = $null; $Context.TreeDone = $true
        return 'done'
    }
    if ($null -eq $Context.BushID) { return 'noop' }
    $ods = @($Context.BushOdOptions)
    if (@($ods).Count -gt 1) { $Context.BushStage = 'od'; return 'od' }
    $pick = Resolve-BushingPickRow -IdGroup $Context.BushID -OdOption $ods[0] -Length ([double]$LenValue) -LenLabel ([string]$LenLabel)
    [void]$Context.Picks.Add([pscustomobject]@{ HoleDiameter=[double]$pick.OD; BushingID=$pick.ID; BushingLength=[double]$pick.Length; Bushing=$pick.EasyName; PartNumber=$pick.PartNumber; Outcome=$Context.TreeNode.label })
    $Context.PendingSpec = $null; $Context.BushStage = $null; $Context.TreeDone = $true
    return 'done'
}

# A paragraph label on the canvas. AUTO-HEIGHT + word-wrap: the label is AutoSize
# with a fixed MaximumSize/MinimumSize WIDTH and an unbounded height, so long text
# WRAPS at the width and the label GROWS DOWNWARD to fit every line -- nothing is
# ever clipped (the old fixed-$Height box clipped any text that wrapped past it, the
# "text cut off" bug). Callers FLOW the next control from the returned label's
# .Bottom (never a hardcoded Top), so an over-wrapped paragraph can never render
# underneath the control below it. The body panel's AutoScroll absorbs extra height.
#   -Top     y of the label's top-left.
#   -Height  IGNORED for sizing (kept for call-site back-compat); height is measured.
#   -Left    x of the label (default 8).
#   -Width   wrap width; default spans the panel minus the left inset and a scrollbar
#            gutter. Pass a smaller width for a LEFT COLUMN that must not run under a
#            right-hand widget (e.g. a preview panel).
# Returns the Label; read .Bottom to place the next control.
function Add-Para {
    param($Panel, [string]$Text, [int]$Top = 8, [int]$Height = 0, [string]$ColorName = $null, [bool]$Bold = $false, [int]$Left = 8, [int]$Width = 0)
    $w = if ($Width -gt 0) { $Width } else { [Math]::Max(80, $Panel.Width - $Left - 26) }
    $l = New-Object System.Windows.Forms.Label
    $l.AutoSize    = $true
    # fixed width, unbounded height -> word-wrap at $w and grow height to fit all lines
    $l.MaximumSize = New-Object System.Drawing.Size($w, 0)
    $l.MinimumSize = New-Object System.Drawing.Size($w, 0)
    $l.Location    = New-Object System.Drawing.Point($Left, $Top)
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $l.Font     = New-Object System.Drawing.Font('Segoe UI', 11, $style)
    $l.ForeColor = Get-UiColor $ColorName
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.Text     = $Text
    $Panel.Controls.Add($l)
    return $l
}

# Return a Y just BELOW the lowest control already in $Panel (+ a gap), or $Min when
# the panel is empty. A block that may render AFTER earlier content (a fall-through
# branch, e.g. the layout tiles rendered under a fallback message) starts its flow at
# Get-StackTop so it can never draw on top of what is already there.
function Get-StackTop {
    param($Panel, [int]$Min = 8, [int]$Gap = 10)
    $b = $null
    foreach ($ctl in $Panel.Controls) { try { if ($null -eq $b -or $ctl.Bottom -gt $b) { $b = $ctl.Bottom } } catch {} }
    if ($null -eq $b) { return $Min }
    return ([Math]::Max($Min, [int]$b + $Gap))
}

# New-BushingViewportHost - a WPF Media3D 3D view of a bushing as a WinForms
# ElementHost, for the confirmation page NEXT TO the 2D schematic. Drill bushings
# (HeadDia > OD) render HEADED; sleeves headless - the SAME distinction the 2D makes
# (the caller passes HeadDia from Get-BushingHeadDia). Drag orbits, wheel zooms.
# Returns $null on ANY failure so the caller falls back to a 2D-only layout (the 3D is
# a bonus, never a crash). Needs the WPF assemblies ($script:Wpf3dOk). global: so the
# step Build resolves it. Orbit state lives in captured hashtables (mutated across events).
function global:New-BushingViewportHost {
    param([double]$OD, [double]$ID, [double]$Length, [double]$HeadDia, [int]$Width, [int]$Height, $Background)
    try {
        $vp = New-Object System.Windows.Controls.Viewport3D
        $cam = New-Object System.Windows.Media.Media3D.PerspectiveCamera; $cam.FieldOfView = 46
        $vp.Camera = $cam
        $lg = New-Object System.Windows.Media.Media3D.Model3DGroup
        # NOTE: every collection .Add() below returns an int index; [void]-wrap them so
        # they do NOT leak into this function's output (else the return is an array, not
        # the ElementHost, and $eh3d.Location fails at the call site).
        [void]$lg.Children.Add((New-Object System.Windows.Media.Media3D.AmbientLight([System.Windows.Media.Color]::FromRgb(96,106,126))))
        [void]$lg.Children.Add((New-Object System.Windows.Media.Media3D.DirectionalLight([System.Windows.Media.Color]::FromRgb(255,255,255), (New-Object System.Windows.Media.Media3D.Vector3D(-0.5,-1,-0.6)))))
        [void]$lg.Children.Add((New-Object System.Windows.Media.Media3D.DirectionalLight([System.Windows.Media.Color]::FromRgb(120,150,200), (New-Object System.Windows.Media.Media3D.Vector3D(0.6,-0.3,0.5)))))
        $lv = New-Object System.Windows.Media.Media3D.ModelVisual3D; $lv.Content = $lg; [void]$vp.Children.Add($lv)
        $mv = New-Object System.Windows.Media.Media3D.ModelVisual3D
        $mv.Content = Build-BushingModelGroup -OD $OD -ID $ID -Length $Length -HeadDia $HeadDia -Segments 48
        [void]$vp.Children.Add($mv)
        # iso fit + orbit state (hashtable captured by the handlers => mutation persists)
        $headLen = if ($HeadDia -gt $OD) { $OD * 0.3 } else { 0.0 }
        $Hdim = $Length + $headLen
        $maxDim = [math]::Max([math]::Max($OD, $HeadDia), $Hdim); if ($maxDim -le 0) { $maxDim = 1 }
        $rad0 = ($maxDim / (2*[math]::Tan(($cam.FieldOfView*[math]::PI/180)/2))) * 1.9
        $st = @{ az=0.9; el=0.5; rad=$rad0; cam=$cam }
        $place = {
            $cx = $st.rad*[math]::Cos($st.el)*[math]::Cos($st.az)
            $cy = $st.rad*[math]::Sin($st.el)
            $cz = $st.rad*[math]::Cos($st.el)*[math]::Sin($st.az)
            $st.cam.Position = New-Object System.Windows.Media.Media3D.Point3D($cx,$cy,$cz)
            $st.cam.LookDirection = New-Object System.Windows.Media.Media3D.Vector3D((-$cx),(-$cy),(-$cz))
            $st.cam.UpDirection = New-Object System.Windows.Media.Media3D.Vector3D(0,1,0)
        }.GetNewClosure()
        & $place
        $grid = New-Object System.Windows.Controls.Grid
        $bg = if ($null -ne $Background) { $Background } else { [System.Drawing.Color]::FromArgb(30,42,68) }
        $grid.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb([byte]$bg.R,[byte]$bg.G,[byte]$bg.B))
        [void]$grid.Children.Add($vp)
        $drag = @{ on=$false; lx=0.0; ly=0.0 }
        $grid.Add_MouseDown({ param($s,$e) $p=$e.GetPosition($s); $drag.on=$true; $drag.lx=$p.X; $drag.ly=$p.Y; [void]$s.CaptureMouse() }.GetNewClosure())
        $grid.Add_MouseUp({ param($s,$e) $drag.on=$false; [void]$s.ReleaseMouseCapture() }.GetNewClosure())
        $grid.Add_MouseMove({ param($s,$e)
            if (-not $drag.on) { return }
            $p=$e.GetPosition($s); $dx=$p.X-$drag.lx; $dy=$p.Y-$drag.ly
            $st.az -= $dx*0.01; $st.el += $dy*0.01
            $st.el = [math]::Max(-1.55, [math]::Min(1.55, $st.el)); & $place
            $drag.lx=$p.X; $drag.ly=$p.Y
        }.GetNewClosure())
        $grid.Add_MouseWheel({ param($s,$e)
            $factor = if ($e.Delta -gt 0) { 0.88 } else { 1.136 }
            $st.rad = [math]::Max(0.2, [math]::Min(200.0, $st.rad*$factor)); & $place
        }.GetNewClosure())
        $eh = New-Object System.Windows.Forms.Integration.ElementHost
        $eh.Child = $grid
        return $eh
    } catch { return $null }
}

# A big "look at Creo" arm banner for a pick step. Both lines AUTO-HEIGHT + wrap, so
# a long instruction can never be clipped or render under the verify controls. RETURNS
# the bottom Y (instruction's .Bottom) so the caller flows the verify button below it.
function Add-ArmBanner {
    param($Panel, [string]$Instruction, [int]$Top = 8)
    $w = [Math]::Max(80, $Panel.Width - 8 - 26)
    $hint = New-Object System.Windows.Forms.Label
    $hint.AutoSize    = $true
    $hint.MaximumSize = New-Object System.Drawing.Size($w, 0)
    $hint.MinimumSize = New-Object System.Drawing.Size($w, 0)
    $hint.Location = New-Object System.Drawing.Point(8, $Top)
    $hint.Font     = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Italic)
    $hint.ForeColor = Get-UiColor 'warn'
    $hint.BackColor = [System.Drawing.Color]::Transparent
    $hint.Text     = ([char]0x2192) + " look at the Creo window"
    $Panel.Controls.Add($hint)

    $instr = New-Object System.Windows.Forms.Label
    $instr.AutoSize    = $true
    $instr.MaximumSize = New-Object System.Drawing.Size($w, 0)
    $instr.MinimumSize = New-Object System.Drawing.Size($w, 0)
    $instr.Location = New-Object System.Drawing.Point(8, ($hint.Bottom + 6))
    $instr.Font     = New-Object System.Drawing.Font('Segoe UI', 13)
    $instr.ForeColor = Get-UiColor ''
    $instr.BackColor = [System.Drawing.Color]::Transparent
    $instr.Text     = $Instruction
    $Panel.Controls.Add($instr)
    return $instr.Bottom
}

# A verify button + result label for a pick step. $OnVerify reads the buffer and
# returns @{ Ok=[bool]; Message=string }. On Ok it stashes results in $ctx (the
# caller's $OnVerify does that) and enables Next via $wiz.Refresh. The result label
# is AUTO-HEIGHT + wrap so a long diagnostic message is never clipped. -Top is the y
# of the verify button (callers pass the arm banner's returned bottom + a gap).
function Add-VerifyControls {
    param($Panel, $Context, $Wizard, [scriptblock]$OnVerify, [int]$Top = 130)
    $thm = $script:WizTheme
    $accent = if ($thm) { $thm.Accent } else { [System.Drawing.Color]::FromArgb(64,132,232) }
    $okCol  = if ($thm) { $thm.Ok }     else { [System.Drawing.Color]::FromArgb(120,210,150) }
    $errCol = if ($thm) { $thm.Err }    else { [System.Drawing.Color]::FromArgb(245,120,110) }
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text     = 'I clicked it - verify'
    $btn.Size     = New-Object System.Drawing.Size(220, 38)
    $btn.Location = New-Object System.Drawing.Point(8, $Top)
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 0
    $btn.BackColor = $accent
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.Font      = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $Panel.Controls.Add($btn)

    $rw = [Math]::Max(80, $Panel.Width - 8 - 26)
    $result = New-Object System.Windows.Forms.Label
    $result.AutoSize    = $true
    $result.MaximumSize = New-Object System.Drawing.Size($rw, 0)
    $result.MinimumSize = New-Object System.Drawing.Size($rw, 0)
    $result.Location = New-Object System.Drawing.Point(8, ($btn.Bottom + 10))
    $result.Font     = New-Object System.Drawing.Font('Segoe UI', 10)
    $result.ForeColor = Get-UiColor ''
    $result.BackColor = [System.Drawing.Color]::Transparent
    $Panel.Controls.Add($result)

    $btn.Add_Click({
        $old = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $res = @{ Ok = $false; Message = 'Nothing was read.' }
            try { $res = & $OnVerify $Context $Wizard } catch { $res = @{ Ok = $false; Message = "Read error: $($_.Exception.Message)" } }
            if ($res.Ok) {
                $result.ForeColor = $okCol
                $result.Text = $res.Message + [Environment]::NewLine + 'Looks good - you can continue.'
            } else {
                $result.ForeColor = $errCol
                $result.Text = $res.Message
            }
            try { $Wizard.Refresh() } catch {}
        } catch {
            try { $Wizard.LogError($_, 'verify click') } catch {}
        } finally {
            $ErrorActionPreference = $old
        }
    }.GetNewClosure())
}

# ============================================================================
# Add-RebuiltNotice - the "this step already built its geometry" panel shown when a
# RUN step is REVISITED (now that navigation is free: any page, any time). It draws a
# green "already built" line + an honest note that going back does NOT auto-undo Creo
# geometry, plus a "Rebuild this step" button. Rebuild WARNS (the old feature stays in
# Creo -> delete it first to avoid duplicates), then clears the step's done-flags
# ($ResetFlags -> $false, $ResetValues -> given value) and jumps to $GoToKey (the
# feature's arm/setup step) so the operator can redo it. Lets the user actually apply a
# changed upstream choice (e.g. a different bushing) instead of only navigating to it.
# ============================================================================
function Add-RebuiltNotice {
    param($Panel, $Context, $Wizard, [string]$Message,
          [string[]]$ResetFlags = @(), [hashtable]$ResetValues = $null,
          [string]$GoToKey = $null, [int]$Top = 8)
    $y = (Add-Para $Panel (([char]0x2713) + ' ' + $Message) $Top 0 'DarkGreen' $true).Bottom + 6
    $y = (Add-Para $Panel ("Navigation is free - use Back or click a stage in the breadcrumb to change any earlier choice. " +
                     "This step's geometry is already in Creo and will NOT change on its own. To redo it after changing " +
                     "an earlier selection (e.g. the bushing or layout), click Rebuild below.") $y 0 'gray').Bottom + 10
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = 'Rebuild this step'
    $btn.Size = New-Object System.Drawing.Size(170, 32)
    $btn.Location = New-Object System.Drawing.Point(8, $y)
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 1
    $btn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(120,170,255)
    $btn.BackColor = [System.Drawing.Color]::FromArgb(54,72,112)
    $btn.ForeColor = Get-UiColor ''
    $btn.Add_Click({
        $old = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $ans = $Wizard.AskInline('Rebuild step', ("Rebuild this step?" + [Environment]::NewLine + [Environment]::NewLine +
                "It re-runs the operation and creates NEW geometry in Creo - the previously built feature(s) STAY. " +
                "Delete the old feature(s) in Creo first if you don't want duplicates." + [Environment]::NewLine + [Environment]::NewLine +
                "Proceed?"), 'YesNo')
            if ($ans -ne 'Yes') { return }
            foreach ($f in $ResetFlags) { $Context[$f] = $false }
            if ($null -ne $ResetValues) { foreach ($k in @($ResetValues.Keys)) { $Context[$k] = $ResetValues[$k] } }
            if ($GoToKey) { $Wizard.GoToStepKey($GoToKey) } else { $Wizard.Rerender() }
        } catch { try { $Wizard.LogError($_, 'rebuild click') } catch {} }
        finally { $ErrorActionPreference = $old }
    }.GetNewClosure())
    $Panel.Controls.Add($btn)
}

# ============================================================================
# Invoke-GuiFastenerLiveRead - read fastener centers from a DIFFERENT open model
# and write fastener_layout.json, entirely from within the wizard (so the GUI is a
# self-contained "one interface" -- no separate fastenator.cmd run needed).
#
# SAFETY (the load-bearing rule): the read uses a THROWAWAY connection and NEVER
# touches $ctx.Model / $ctx.Session / $script:DJModel (which stay bound to the jig
# part). The operator switches Creo's active model to the fastener part, we read,
# then they switch back to the jig part -- all confirmed by IN-CANVAS prompts
# ($Wizard.AskInline) so no prompt hides behind the Creo window. The final "switch
# back" prompt uses -NoActivate so the wizard does not steal focus while the operator
# re-activates Creo (user 2026-07-21: all prompts inside the one GUI window).
#
# Uses the SAME shared reader (Read-FastenerCentersFromModel) + pure projection
# (ConvertTo-LayoutXZ) as fastenator.cmd/drilljig.cmd. Axis mapping defaults to the
# confirmed X->layoutX / Z->layoutZ (the flat-plate case); a non-default mapping is
# the standalone fastenator.cmd's job (--axis-x/--axis-z). Returns the written file
# path on success (the caller then rerenders and the file-load path displays it), or
# $null. On success the jig part must be re-activated before the wizard continues.
# ============================================================================
function global:Invoke-GuiFastenerLiveRead {
    # global: is REQUIRED -- this is called from a button Add_Click .GetNewClosure()
    # handler, and a closure module can ONLY resolve GLOBAL functions (a plain
    # script-scope function throws "not recognized" at click time -- confirmed live
    # 2026-07-20). A global function invoked from a closure can still resolve the
    # script-scope dot-sourced libs it calls (Read-FastenerCentersFromModel etc.).
    # $Wizard is threaded in so every prompt renders IN-CANVAS ($Wizard.AskInline)
    # instead of a floating popup.
    param($OutPath, [double]$HoleDia, $Wizard)
    # 1. confirm the fastener model is active
    $ans = $Wizard.AskInline('Import fastener layout - live read', ("Make the FASTENER model (the one full of fasteners) the ACTIVE window in Creo, then click OK.`r`n`r`nFor an ASSEMBLY, also SELECT the fastener components first (Ctrl-click them). Select ONE component per hole -- the BOLT SHANKS only, NOT their washers/nuts (a bolt+washer+nut stack reads as 2-3 holes at the same spot).`r`n`r`nThe jig part is only READ from here -- nothing is modified."), 'OKCancel')
    if ($ans -ne 'OK') { return $null }

    $fConn = $null; $written = $null
    try {
        $fAsync = New-Object -ComObject pfcls.pfcAsyncConnection
        $fConn  = $fAsync.Connect($null, $null, $null, $null)
        $fSess  = $fConn.Session
        $fModel = $fSess.GetActiveModel()
        if ($null -eq $fModel) { [void]$Wizard.AskInline('Live read', "No active model to read.", 'OK'); return $null }
        $fType  = New-Object -ComObject pfcls.pfcModelItemType
        $fName  = try { [string]$fModel.FileName } catch { "" }
        $fIsAsm = ($fName -match '(?i)\.asm(\.\d+)?$')

        $read = Read-FastenerCentersFromModel -Session $fSess -Model $fModel -TypeObj $fType -IsAsm $fIsAsm
        if (-not $read.Ok) {
            [void]$Wizard.AskInline('Live read', ("Could not read fastener centers from '$fName':`r`n`r`n$($read.Message)`r`n`r`nTip: run fastener-probe.cmd to see which read works on this model."), 'OK')
            return $null
        }
        $mg = if ($HoleDia -gt 0) { [double]$HoleDia } else { 0.25 }
        # ASSEMBLY: NO proximity merge (user 2026-07-23: one selected fastener = one hole,
        # picked count = hole count). DedupTol=0 so distinct fasteners can NEVER collapse;
        # the reader dropped exact same-instance re-picks by path, and coincident holes
        # surface via the collision check, not a silent merge.
        $dt = if ($fIsAsm) { 0.0 } else { $mg }
        # -Axes = each fastener's own bore axis (parallel to Centers) => project onto
        # the fastener PANEL plane so true hole spacing survives a panel not square to
        # the global axes (fixes "only some register" / "holes too close" in big asms).
        $layout = ConvertTo-LayoutXZ -Centers $read.Centers -Axes $read.Axes -AxisX 'X' -AxisZ 'Z' -Margin $mg -DedupTol $dt
        if (-not $layout.Valid) {
            [void]$Wizard.AskInline('Live read', ("Read $($read.Count) center(s) but could not build a layout:`r`n`r`n" + (($layout.Errors) -join "`r`n")), 'OK')
            return $null
        }
        $sane = Test-FastenerLayoutSane -Layout $layout
        if (-not $sane.Ok) {
            [void]$Wizard.AskInline('Live read', ("Sanity check failed (the read likely returned bad coords):`r`n`r`n" + (($sane.Errors) -join "`r`n")), 'OK')
            return $null
        }
        $ok = Write-FastenerLayout -Path $OutPath -Layout $layout -SourceModel $fName -Units 'unknown' -ReadMethod ($read.ReadMethod + ' (GUI live)') -WhenIso ((Get-Date).ToString('o'))
        if (-not $ok) { [void]$Wizard.AskInline('Live read', "Failed to write $OutPath.", 'OK'); return $null }
        $written = $OutPath
        # COUNT FEEDBACK: show the selection accounting so a wrong count is visible.
        $acct = ''
        if ($fIsAsm) {
            $acct = "`r`n`r`nSelection: $($read.RawSelected) picked -> $($layout.Count) hole(s)."
            if ($read.SkippedNoPath   -gt 0) { $acct += "`r`n  - skipped $($read.SkippedNoPath) pick(s) with no component (surface/edge? select whole instances)." }
            if ($read.SkippedNoXform  -gt 0) { $acct += "`r`n  - skipped $($read.SkippedNoXform) component(s) with an unreadable location." }
            if ($read.MergedDuplicate -gt 0) { $acct += "`r`n  - merged $($read.MergedDuplicate) duplicate pick(s) of the same component." }
            $acct += "`r`n`r`nIf that count looks wrong, select ONE component per hole (bolt shanks only) and re-read."
        }
        # projection-mode note: plane (tilt-corrected) vs global fallback.
        if ($layout.Frame -eq 'plane') {
            $acct += "`r`n`r`nProjected onto the fastener PANEL plane (axis spread {0:0.##} deg) -- true hole spacing preserved." -f [double]$layout.AxisSpreadDeg
        } else {
            $acct += "`r`n`r`nNOTE: fastener axes not readable -- used global-axis projection (may distort a tilted panel)."
        }
        # -NoActivate: the operator switches Creo's active window right after, so the
        # wizard must NOT steal focus (a focus grab would fight the window switch).
        [void]$Wizard.AskInline('Live read - switch back to the jig part', ("Read $($layout.Count) fastener location(s) from '$fName' and saved the layout.$acct`r`n`r`nNow switch Creo's active window BACK to the BLANK JIG PART, then click OK to continue."), 'OK', $true)
    } catch {
        [void]$Wizard.AskInline('Live read', ("Live read failed: $($_.Exception.Message)"), 'OK')
        $written = $null
    } finally {
        if ($null -ne $fConn) { try { $fConn.Disconnect($null) } catch {} }
    }
    return $written
}

# ============================================================================
# Add-InlineOrthogrid - build the orthogrid editor INSIDE the wizard canvas (no
# popup window; user request 2026-06-26). Reuses the PURE math Get-OrthogridGeometry
# and the shared Draw-AxisGlyph preview from lib\orthogrid_gui.ps1 - it does NOT
# touch the live-verified Show-OrthogridDialog (that modal stays for the standalone
# tools). Fields write into $Context.OrthoFields (persistent, so the recompute
# closure never reads a Build-local); each change recomputes and stores the result
# in $Context.OrthoGeo + sets $Context.OrthoValid (the step's Validate gates Next on
# it). $HoleDia/$ReliefDia/$Thickness are read-only context shown as a caption.
# ============================================================================
function Add-InlineOrthogrid {
    param($Panel, $Context, $Wizard)
    $thm = $script:WizTheme
    $ink   = if ($thm) { $thm.Ink }   else { [System.Drawing.Color]::FromArgb(238,242,248) }
    $muted = if ($thm) { $thm.Muted } else { [System.Drawing.Color]::FromArgb(158,172,196) }
    $cardBk= if ($thm) { $thm.CanvasBack } else { [System.Drawing.Color]::FromArgb(30,42,68) }
    $fieldBk = [System.Drawing.Color]::FromArgb(16,24,42)
    $errCol = if ($thm) { $thm.Err } else { [System.Drawing.Color]::FromArgb(245,120,110) }
    $okCol  = if ($thm) { $thm.Ok }  else { [System.Drawing.Color]::FromArgb(120,210,150) }

    # persistent field store (seed once from defaults / a prior edit)
    if ($null -eq $Context.OrthoFields) {
        $seed = @{ CcX = 0.5; CcZ = 0.5; Nx = 5; Nz = 4; Edge = 0.5 }
        if ($null -ne $Context.OrthoGeo -and $Context.OrthoGeo.Mode -eq 'orthogrid') {
            try { $seed.CcX = [double]$Context.OrthoGeo.CcX; $seed.CcZ = [double]$Context.OrthoGeo.CcZ; $seed.Nx = [int]$Context.OrthoGeo.Nx; $seed.Nz = [int]$Context.OrthoGeo.Nz; $seed.Edge = [double]$Context.OrthoGeo.Edge } catch {}
        }
        $Context.OrthoFields = $seed
    }
    $clearDia = 0.0
    if ($null -ne $Context.HoleDia -and [double]$Context.HoleDia -gt 0) { $clearDia = [double]$Context.HoleDia }

    # EDGE MARGIN = the chosen hole-to-edge wall (user 2026-07-23: default one hole
    # DIAMETER, or a SMALLER wall picked in the edge-margin step). The plate is sized with
    # ClearDia = the hole dia, so the Edge field IS the border hole-edge -> part-edge wall;
    # locking Edge = the chosen wall (via Get-EffectiveEdgeMargin: $c.EdgeMargin when set,
    # else the hole dia) enforces exactly that margin. The box is locked read-only (below)
    # so the operator can't fight the edge-margin step. Only when the dia is known (the jig
    # flow always knows it); with no dia the field stays editable + the check uses -1 (legacy
    # one-radius). $Context.EdgeMargin=$null -> default = hole dia = the prior behaviour.
    $lockEdge = ($clearDia -gt 0)
    $wallReq = Get-EffectiveEdgeMargin -ChosenMargin $Context.EdgeMargin -HoleDia $clearDia
    if ($lockEdge) { $Context.OrthoFields.Edge = $wallReq }
    # pass the SAME wall to Get-OrthogridGeometry so its check + echoed .EdgeMargin agree
    # with the locked field; -1 (legacy one-radius) when the dia is unknown.
    $edgeMargin = if ($lockEdge) { $wallReq } else { -1.0 }

    # left column: labelled fields. The Edge row is relabelled + locked when the hole
    # dia is known (wall = one diameter).
    $rows = @(
        @{ Key='CcX';  Label='Center-to-center X' },
        @{ Key='CcZ';  Label='Center-to-center Z' },
        @{ Key='Nx';   Label='Holes along X (Nx)' },
        @{ Key='Nz';   Label='Holes along Z (Nz)' },
        @{ Key='Edge'; Label=$(if ($lockEdge) { ('Edge margin (= {0:0.###}")' -f $wallReq) } else { 'Edge margin' }) }
    )
    $y = 6
    $boxes = @{}
    foreach ($rw in $rows) {
        $lab = New-Object System.Windows.Forms.Label
        $lab.Text = $rw.Label + ':'; $lab.Location = New-Object System.Drawing.Point(8, ($y+3)); $lab.Size = New-Object System.Drawing.Size(160, 20)
        $lab.ForeColor = $ink; $lab.BackColor = [System.Drawing.Color]::Transparent
        $Panel.Controls.Add($lab)
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Location = New-Object System.Drawing.Point(176, $y); $tb.Size = New-Object System.Drawing.Size(90, 24)
        $tb.Text = [string]$Context.OrthoFields[$rw.Key]
        $tb.BackColor = $fieldBk; $tb.ForeColor = $ink; $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $tb.Tag = $rw.Key
        # lock the Edge box to the hole dia (read-only) so the wall is always one dia.
        if ($lockEdge -and $rw.Key -eq 'Edge') {
            $tb.ReadOnly = $true; $tb.TabStop = $false
            $tb.BackColor = [System.Drawing.Color]::FromArgb(30,42,68)
        }
        $boxes[$rw.Key] = $tb
        $Panel.Controls.Add($tb)
        $y += 32
    }

    # context caption. LEFT-COLUMN width (300) keeps these clear of the preview at x320.
    $capY = $y + 4
    $cap = "hole {0}" -f $(if ($clearDia -gt 0) { ('{0:0.###}"' -f $clearDia) } else { 'n/a' })
    if ($null -ne $Context.BushingLen) { $cap += ("    depth {0:0.###}`"" -f [double]$Context.BushingLen) }
    $lblCap = New-Object System.Windows.Forms.Label
    $lblCap.Location = New-Object System.Drawing.Point(8, $capY); $lblCap.Size = New-Object System.Drawing.Size(300, 20)
    $lblCap.ForeColor = $muted; $lblCap.BackColor = [System.Drawing.Color]::Transparent; $lblCap.Text = $cap
    $Panel.Controls.Add($lblCap)

    # readout (2-line, wraps) + error (AUTO-HEIGHT so a long validation message is never
    # clipped -- it is the last left-column element, so it grows downward freely).
    $lblReadout = New-Object System.Windows.Forms.Label
    $lblReadout.Location = New-Object System.Drawing.Point(8, ($capY + 24)); $lblReadout.Size = New-Object System.Drawing.Size(300, 44)
    $lblReadout.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lblReadout.ForeColor = $okCol; $lblReadout.BackColor = [System.Drawing.Color]::Transparent
    $Panel.Controls.Add($lblReadout)
    $lblErr = New-Object System.Windows.Forms.Label
    $lblErr.AutoSize = $true
    $lblErr.MaximumSize = New-Object System.Drawing.Size(300, 0)
    $lblErr.MinimumSize = New-Object System.Drawing.Size(300, 0)
    $lblErr.Location = New-Object System.Drawing.Point(8, ($lblReadout.Bottom + 6))
    $lblErr.ForeColor = $errCol; $lblErr.BackColor = [System.Drawing.Color]::Transparent
    $Panel.Controls.Add($lblErr)

    # right side: live dot preview
    $preview = New-Object System.Windows.Forms.Panel
    $preview.Location = New-Object System.Drawing.Point(320, 6)
    $preview.Size     = New-Object System.Drawing.Size(280, 200)
    $preview.BackColor = $fieldBk
    $preview.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $Panel.Controls.Add($preview)
    # legend: red = holes, amber band = chip-relief slot (one per row)
    $lblLegend = New-Object System.Windows.Forms.Label
    $lblLegend.Location = New-Object System.Drawing.Point(320, 210); $lblLegend.Size = New-Object System.Drawing.Size(280, 20)
    $lblLegend.ForeColor = $muted; $lblLegend.BackColor = [System.Drawing.Color]::Transparent
    $lblLegend.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    $lblLegend.Text = [char]0x25CF + ' holes    ' + [char]0x25AC + ' chip-relief slots (1 per row)'
    $Panel.Controls.Add($lblLegend)
    $preview.Add_Paint({
        param($s,$e)
        try {
            $g = $e.Graphics; $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $res = $Context.OrthoGeo
            if ($null -eq $res -or -not $res.Valid -or $res.Mode -ne 'orthogrid') { return }
            $w = [double]$res.Width; $h = [double]$res.Height
            if ($w -le 0 -or $h -le 0) { return }
            $cw = $s.ClientSize.Width; $ch = $s.ClientSize.Height; $margin = 18.0
            $availW = $cw - 2*$margin; $availH = $ch - 2*$margin
            if ($availW -le 1 -or $availH -le 1) { return }
            $scale = $availW / $w; if (($availH / $h) -lt $scale) { $scale = $availH / $h }
            if ($scale -le 0) { return }
            $drawW = $w*$scale; $drawH = $h*$scale
            $offX = ($cw-$drawW)/2.0; $offY = ($ch-$drawH)/2.0
            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(110,150,210), 1.5)
            $g.DrawRectangle($pen, [single]$offX, [single]$offY, [single]$drawW, [single]$drawH); $pen.Dispose()
            # chip-relief slot bands (drawn UNDER the dots) - the SAME Get-RowSlots
            # math slot-a uses, so the operator sees the relief cuts on the layout.
            if ($clearDia -gt 0) {
                try {
                    $sl = Get-RowSlots -Points $res.Points -SlotWidth $clearDia -Width $w -Height $h -RowAxis 'X'
                    Draw-SlotRects -Graphics $g -Slots $sl -OffX $offX -OffY $offY -DrawH $drawH -Scale $scale
                } catch {}
            }
            # holes drawn as TO-SCALE circles (real footprint; fixed dot if dia unknown)
            Draw-HoleCircles -Graphics $g -Points $res.Points -OffX $offX -OffY $offY -DrawH $drawH -Scale $scale -HoleDia $clearDia
            Draw-AxisGlyph -Graphics $g -ClientW $cw -ClientH $ch
        } catch {}
    }.GetNewClosure())

    # recompute closure: read the boxes -> Get-OrthogridGeometry -> store + gate.
    $recompute = {
        $f = $Context.OrthoFields
        $cx=0.0;$cz=0.0;$ed=0.0;$nx=0;$nz=0
        $okCx=[double]::TryParse([string]$f.CcX,[ref]$cx); $okCz=[double]::TryParse([string]$f.CcZ,[ref]$cz)
        $okEd=[double]::TryParse([string]$f.Edge,[ref]$ed); $okNx=[int]::TryParse([string]$f.Nx,[ref]$nx); $okNz=[int]::TryParse([string]$f.Nz,[ref]$nz)
        $perr=@()
        if (-not $okCx){$perr+='ccX not a number'}; if (-not $okCz){$perr+='ccZ not a number'}
        if (-not $okEd){$perr+='edge not a number'}; if (-not $okNx){$perr+='Nx not an integer'}; if (-not $okNz){$perr+='Nz not an integer'}
        $res=$null
        if ($perr.Count -eq 0) { try { $res = Get-OrthogridGeometry -CcX $cx -CcZ $cz -Nx $nx -Nz $nz -Edge $ed -ClearDia $clearDia -HoleDia $clearDia -EdgeMargin $edgeMargin } catch { $res=$null } }
        if ($null -ne $res -and $res.Valid) {
            if ($null -ne $Context.HoleDia)   { try { $res | Add-Member -NotePropertyName 'HoleDiameter'   -NotePropertyValue ([double]$Context.HoleDia)   -Force } catch {} }
            if ($null -ne $Context.BushingLen){ try { $res | Add-Member -NotePropertyName 'Thickness'      -NotePropertyValue ([double]$Context.BushingLen)-Force } catch {} }
            $Context.OrthoGeo = $res; $Context.OrthoValid = $true; $Context.PointMode = 'orthogrid'
            $slotCount = 0
            if ($clearDia -gt 0) { try { $slp = Get-RowSlots -Points $res.Points -SlotWidth $clearDia -Width $res.Width -Height $res.Height -RowAxis 'X'; if ($slp.Valid) { $slotCount = $slp.Count } } catch {} }
            $lblReadout.Text = ('Part {0:0.00} x {1:0.00}  |  {2} holes  |  {3} relief slot(s)' -f $res.Width, $res.Height, $res.Count, $slotCount)
            $lblErr.Text = ''
            $Wizard.SetChip('layout', ("grid: {0} holes" -f $res.Count), 'set')
            $Wizard.SetChip('plate', ("plate {0:0.0}x{1:0.0}" -f $res.Width, $res.Height), 'set')
        } else {
            $Context.OrthoValid = $false
            $lblReadout.Text=''
            if ($perr.Count -gt 0) { $lblErr.Text = ($perr -join '; ') }
            elseif ($null -ne $res -and $res.Errors -and $res.Errors.Count -gt 0) { $lblErr.Text = ($res.Errors -join '; ') }
            else { $lblErr.Text = 'Invalid input' }
        }
        try { $preview.Invalidate() } catch {}
        try { $Wizard.Refresh() } catch {}
    }.GetNewClosure()

    # wire each box: write to the persistent store, then recompute.
    foreach ($k in @($boxes.Keys)) {
        $boxes[$k].Add_TextChanged({
            param($s,$e)
            $Context.OrthoFields[[string]$s.Tag] = $s.Text
            & $recompute
        }.GetNewClosure())
    }
    & $recompute
    # content bottom (max of the left column's error + the right column's legend) so the
    # caller can size its host panel to fit everything; +40 reserves room for a longer
    # error to grow into after an invalid edit without clipping.
    return ([Math]::Max([int]$lblErr.Bottom + 40, [int]$lblLegend.Bottom))
}

# ============================================================================
# Add-InlineCustomPoints - the CUSTOM per-point editor embedded IN the wizard
# canvas (no popup; user request 2026-06-26 "custom still opens an extra window").
# A DataGridView of X/Z rows + Add/Remove buttons + a live dot-preview, reusing the
# pure Get-CustomPointsGeometry math. Rows persist in $Context.CustomRows (a
# System.Collections.ArrayList of @{X;Z} strings) so the recompute closure never
# reads a Build-local. Result stored in $Context.OrthoGeo (Mode='custom') + gates
# via $Context.OrthoValid, exactly like the orthogrid editor (shape-compatible).
# ============================================================================
function Add-InlineCustomPoints {
    param($Panel, $Context, $Wizard)
    $thm = $script:WizTheme
    $ink   = if ($thm) { $thm.Ink }   else { [System.Drawing.Color]::FromArgb(238,242,248) }
    $muted = if ($thm) { $thm.Muted } else { [System.Drawing.Color]::FromArgb(158,172,196) }
    $fieldBk = [System.Drawing.Color]::FromArgb(16,24,42)
    $errCol = if ($thm) { $thm.Err } else { [System.Drawing.Color]::FromArgb(245,120,110) }
    $okCol  = if ($thm) { $thm.Ok }  else { [System.Drawing.Color]::FromArgb(120,210,150) }
    $clearDia = 0.0
    if ($null -ne $Context.HoleDia -and [double]$Context.HoleDia -gt 0) { $clearDia = [double]$Context.HoleDia }
    # EDGE MARGIN = the chosen hole-to-edge wall (user 2026-07-23: default one full hole
    # diameter, or a SMALLER wall from the edge-margin step). -1 (legacy one-radius rule)
    # when the hole dia is unknown. $Context.EdgeMargin=$null -> default = the hole dia.
    $edgeMargin = Get-EffectiveEdgeMargin -ChosenMargin $Context.EdgeMargin -HoleDia $clearDia

    # INDEX-RELATIVE (user 2026-07-21): the operator sets the INDEX hole (offset from the
    # plate corner) once, then each grid row is one OTHER hole's offset FROM THE INDEX.
    # persistent index store (seed once: prior edit, or a sane default). The default index
    # offset must clear the edge-margin rule: near wall = index - radius >= EdgeMargin, so
    # index >= radius + EdgeMargin. Seed at radius + the chosen wall so the default layout is
    # VALID (tangent) out of the box; 0.5 when the hole dia is unknown.
    if ($null -eq $Context.CustomIndex) {
        $ixSeed = if ($clearDia -gt 0) { (0.5 * $clearDia) + $edgeMargin } else { 0.5 }
        # re-open to edit: recover the index from the tagged OrthoGeo if present.
        if ($null -ne $Context.OrthoGeo -and ($Context.OrthoGeo.PSObject.Properties.Name -contains 'IndexGridX') -and $null -ne $Context.OrthoGeo.IndexGridX) {
            $Context.CustomIndex = @{ X = ('{0}' -f [double]$Context.OrthoGeo.IndexGridX); Z = ('{0}' -f [double]$Context.OrthoGeo.IndexGridZ) }
        } else {
            $Context.CustomIndex = @{ X = ('{0}' -f $ixSeed); Z = ('{0}' -f $ixSeed) }
        }
    }
    # persistent row store (seed once: OTHER-hole offsets from a prior edit, or 2 starters).
    # On re-open, OrthoGeo.Points[0] is the index; Points[1..] are index + offset, so the
    # stored offset = point - index (recover the RELATIVE value the operator typed).
    if ($null -eq $Context.CustomRows) {
        $rows = New-Object System.Collections.ArrayList
        if ($null -ne $Context.OrthoGeo -and $Context.OrthoGeo.Mode -eq 'custom' -and $null -ne $Context.OrthoGeo.Points -and ($Context.OrthoGeo.PSObject.Properties.Name -contains 'IndexGridX') -and $null -ne $Context.OrthoGeo.IndexGridX) {
            $igx = [double]$Context.OrthoGeo.IndexGridX; $igz = [double]$Context.OrthoGeo.IndexGridZ
            $pp = @($Context.OrthoGeo.Points)
            for ($ri = 1; $ri -lt $pp.Count; $ri++) { [void]$rows.Add(@{ X = ('{0}' -f ([double]$pp[$ri].X - $igx)); Z = ('{0}' -f ([double]$pp[$ri].Z - $igz)) }) }
        }
        if ($rows.Count -eq 0) { [void]$rows.Add(@{ X='1.0'; Z='0.0' }); [void]$rows.Add(@{ X='0.0'; Z='1.0' }) }
        $Context.CustomRows = $rows
    }

    # LEFT COLUMN flows top-to-bottom ($ly cursor) so the wrapped help line pushes the
    # fields down (never overlaps them) and every left label stays in the 300px column,
    # clear of the preview at x320. The preview + legend keep their fixed right-column x.
    $lw = 300
    $lblHelp = New-Object System.Windows.Forms.Label
    $lblHelp.AutoSize = $true
    $lblHelp.MaximumSize = New-Object System.Drawing.Size($lw, 0)
    $lblHelp.MinimumSize = New-Object System.Drawing.Size($lw, 0)
    $lblHelp.Location = New-Object System.Drawing.Point(8, 2)
    $lblHelp.ForeColor = $muted; $lblHelp.BackColor = [System.Drawing.Color]::Transparent
    $lblHelp.Text = "Set the INDEX hole (from the corner), then add each OTHER hole's offset FROM the index. X=TOP, Z=FRONT."
    $Panel.Controls.Add($lblHelp)
    $ly = $lblHelp.Bottom + 8

    # --- index-hole fields (offset from the plate corner) -------------------
    $lblIdx = New-Object System.Windows.Forms.Label
    $lblIdx.Text = 'Index (from corner):'; $lblIdx.ForeColor = $ink; $lblIdx.BackColor = [System.Drawing.Color]::Transparent
    $lblIdx.Location = New-Object System.Drawing.Point(8, ($ly + 2)); $lblIdx.Size = New-Object System.Drawing.Size(120, 20)
    $Panel.Controls.Add($lblIdx)
    $tbIdxX = New-Object System.Windows.Forms.TextBox
    $tbIdxX.Location = New-Object System.Drawing.Point(132, $ly); $tbIdxX.Size = New-Object System.Drawing.Size(50, 22)
    $tbIdxX.BackColor = $fieldBk; $tbIdxX.ForeColor = $ink; $tbIdxX.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $tbIdxX.Text = [string]$Context.CustomIndex.X; $tbIdxX.Tag = 'IdxX'
    $Panel.Controls.Add($tbIdxX)
    $tbIdxZ = New-Object System.Windows.Forms.TextBox
    $tbIdxZ.Location = New-Object System.Drawing.Point(186, $ly); $tbIdxZ.Size = New-Object System.Drawing.Size(50, 22)
    $tbIdxZ.BackColor = $fieldBk; $tbIdxZ.ForeColor = $ink; $tbIdxZ.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $tbIdxZ.Text = [string]$Context.CustomIndex.Z; $tbIdxZ.Tag = 'IdxZ'
    $Panel.Controls.Add($tbIdxZ)
    $ly += 30

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(8, $ly); $grid.Size = New-Object System.Drawing.Size(290, 132)
    $grid.AllowUserToAddRows = $false; $grid.RowHeadersVisible = $true
    $grid.BackgroundColor = $fieldBk; $grid.GridColor = [System.Drawing.Color]::FromArgb(72,92,132)
    $grid.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(30,42,68)
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $ink
    $grid.EnableHeadersVisualStyles = $false
    $grid.DefaultCellStyle.BackColor = $fieldBk; $grid.DefaultCellStyle.ForeColor = $ink
    $grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(54,72,112)
    $grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
    $colX = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $colX.HeaderText='X from index'; $colX.Name='X'
    $colZ = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $colZ.HeaderText='Z from index'; $colZ.Name='Z'
    $grid.Columns.Add($colX) | Out-Null; $grid.Columns.Add($colZ) | Out-Null
    foreach ($r in $Context.CustomRows) { $grid.Rows.Add(@([string]$r.X, [string]$r.Z)) | Out-Null }
    $Panel.Controls.Add($grid)
    $ly += 138

    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text='Add point'; $btnAdd.Size=New-Object System.Drawing.Size(90,26); $btnAdd.Location=New-Object System.Drawing.Point(8,$ly)
    $btnAdd.FlatStyle=[System.Windows.Forms.FlatStyle]::Flat; $btnAdd.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(90,104,132)
    $btnAdd.BackColor=[System.Drawing.Color]::FromArgb(30,42,68); $btnAdd.ForeColor=$ink
    $Panel.Controls.Add($btnAdd)
    $btnDel = New-Object System.Windows.Forms.Button
    $btnDel.Text='Remove'; $btnDel.Size=New-Object System.Drawing.Size(90,26); $btnDel.Location=New-Object System.Drawing.Point(104,$ly)
    $btnDel.FlatStyle=[System.Windows.Forms.FlatStyle]::Flat; $btnDel.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(90,104,132)
    $btnDel.BackColor=[System.Drawing.Color]::FromArgb(30,42,68); $btnDel.ForeColor=$ink
    $Panel.Controls.Add($btnDel)
    $ly += 34

    # readout (3-line, wraps -- the custom readout is long) + error (3-line, wraps). Both
    # in the 300px left column, generously tall so neither is clipped.
    $lblReadout = New-Object System.Windows.Forms.Label
    $lblReadout.Location = New-Object System.Drawing.Point(8, $ly); $lblReadout.Size = New-Object System.Drawing.Size(300, 60)
    $lblReadout.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lblReadout.ForeColor = $okCol; $lblReadout.BackColor = [System.Drawing.Color]::Transparent
    $Panel.Controls.Add($lblReadout)
    $ly += 64
    $lblErr = New-Object System.Windows.Forms.Label
    $lblErr.Location = New-Object System.Drawing.Point(8, $ly); $lblErr.Size = New-Object System.Drawing.Size(300, 56)
    $lblErr.ForeColor = $errCol; $lblErr.BackColor = [System.Drawing.Color]::Transparent
    $Panel.Controls.Add($lblErr)

    $preview = New-Object System.Windows.Forms.Panel
    $preview.Location = New-Object System.Drawing.Point(320, 44); $preview.Size = New-Object System.Drawing.Size(280, 180)
    $preview.BackColor = $fieldBk; $preview.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $Panel.Controls.Add($preview)
    # legend: red = holes, amber band = chip-relief slot (one per row)
    $lblLegend = New-Object System.Windows.Forms.Label
    $lblLegend.Location = New-Object System.Drawing.Point(320, 228); $lblLegend.Size = New-Object System.Drawing.Size(280, 20)
    $lblLegend.ForeColor = $muted; $lblLegend.BackColor = [System.Drawing.Color]::Transparent
    $lblLegend.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    $lblLegend.Text = [char]0x25CF + ' holes    ' + [char]0x25AC + ' chip-relief slots (1 per row)'
    $Panel.Controls.Add($lblLegend)
    $preview.Add_Paint({
        param($s,$e)
        try {
            $g = $e.Graphics; $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $res = $Context.OrthoGeo
            if ($null -eq $res -or -not $res.Valid -or $res.Mode -ne 'custom') { return }
            $w=[double]$res.Width; $h=[double]$res.Height
            if ($w -le 0 -or $h -le 0) { return }
            $cw=$s.ClientSize.Width; $ch=$s.ClientSize.Height; $margin=18.0
            $availW=$cw-2*$margin; $availH=$ch-2*$margin
            if ($availW -le 1 -or $availH -le 1) { return }
            $scale=$availW/$w; if (($availH/$h) -lt $scale) { $scale=$availH/$h }
            if ($scale -le 0) { return }
            $drawW=$w*$scale; $drawH=$h*$scale; $offX=($cw-$drawW)/2.0; $offY=($ch-$drawH)/2.0
            $pen=New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(110,150,210),1.5)
            $g.DrawRectangle($pen,[single]$offX,[single]$offY,[single]$drawW,[single]$drawH); $pen.Dispose()
            # chip-relief slot bands (drawn UNDER the dots) - same Get-RowSlots math as slot-a.
            if ($clearDia -gt 0) {
                try {
                    $sl = Get-RowSlots -Points $res.Points -SlotWidth $clearDia -Width $w -Height $h -RowAxis 'X'
                    Draw-SlotRects -Graphics $g -Slots $sl -OffX $offX -OffY $offY -DrawH $drawH -Scale $scale
                } catch {}
            }
            # holes drawn as TO-SCALE circles (real footprint; fixed dot if dia unknown)
            Draw-HoleCircles -Graphics $g -Points $res.Points -OffX $offX -OffY $offY -DrawH $drawH -Scale $scale -HoleDia $clearDia
            Draw-AxisGlyph -Graphics $g -ClientW $cw -ClientH $ch
        } catch {}
    }.GetNewClosure())

    # pull the index fields + grid rows into the persistent store, then recompute via the
    # pure INDEX-RELATIVE math. The grid rows are OTHER-hole offsets FROM THE INDEX; the
    # index fields are the index hole's offset from the plate corner. On a valid result we
    # AUTO-set the index-first context vars (IndexKey=0, IndexGridX/Z) so STAGE 1.9 builds
    # the base csys AT the index and STAGE 2.5 offsets by (grid - index) with NO separate
    # index-choice pick. Idempotent: re-run every edit re-derives them.
    $recompute = {
        # index hole (offset from the corner)
        $ixs = $null; $izs = $null
        try { $ixs = [string]$tbIdxX.Text } catch {}
        try { $izs = [string]$tbIdxZ.Text } catch {}
        $Context.CustomIndex = @{ X = [string]$ixs; Z = [string]$izs }
        $ixv = 0.0; $izv = 0.0
        $idxOk = ([double]::TryParse($ixs, [ref]$ixv) -and [double]::TryParse($izs, [ref]$izv))

        # OTHER holes (offsets FROM the index)
        $pts = @()
        foreach ($row in $grid.Rows) {
            if ($row.IsNewRow) { continue }
            $xs=$null; $zs=$null
            try { $xs=[string]$row.Cells['X'].Value } catch {}
            try { $zs=[string]$row.Cells['Z'].Value } catch {}
            if ([string]::IsNullOrWhiteSpace($xs) -and [string]::IsNullOrWhiteSpace($zs)) { continue }
            $xv=0.0; $zv=0.0
            if ([double]::TryParse($xs,[ref]$xv) -and [double]::TryParse($zs,[ref]$zv)) { $pts += [pscustomobject]@{ X=[double]$xv; Z=[double]$zv } }
            else { $pts += [pscustomobject]@{ X=$null; Z=$null } }
        }
        # mirror into the persistent store so a rerender re-seeds correctly
        $store = New-Object System.Collections.ArrayList
        foreach ($p in $pts) { [void]$store.Add(@{ X=('{0}' -f $p.X); Z=('{0}' -f $p.Z) }) }
        $Context.CustomRows = $store

        if (-not $idxOk) {
            $Context.OrthoValid = $false; $lblReadout.Text=''
            $lblErr.Text = 'Enter a numeric index X and Z (offset from the corner)'
            try { $preview.Invalidate() } catch {}
            try { $Wizard.Refresh() } catch {}
            return
        }

        $res=$null
        try { $res = Get-IndexRelativeCustomGeometry -IndexX $ixv -IndexZ $izv -OtherPoints $pts -ClearDia $clearDia -HoleDia $clearDia -EdgeMargin $edgeMargin } catch { $res=$null }
        if ($null -ne $res -and $res.Valid) {
            if ($null -ne $Context.HoleDia)   { try { $res | Add-Member -NotePropertyName 'HoleDiameter' -NotePropertyValue ([double]$Context.HoleDia) -Force } catch {} }
            if ($null -ne $Context.BushingLen){ try { $res | Add-Member -NotePropertyName 'Thickness'    -NotePropertyValue ([double]$Context.BushingLen) -Force } catch {} }
            $Context.OrthoGeo = $res; $Context.OrthoValid = $true; $Context.PointMode = 'custom'
            # AUTO-engage index-first: the index hole is Points[0]. STAGE 1.9 + STAGE 2.5
            # key off these, and the index-choice step shows a fixed confirmation (no pick).
            $Context.IndexFirst = $true; $Context.IndexKey = 0
            $Context.IndexGridX = [double]$res.IndexGridX; $Context.IndexGridZ = [double]$res.IndexGridZ
            $slotCount = 0
            if ($clearDia -gt 0) { try { $slp = Get-RowSlots -Points $res.Points -SlotWidth $clearDia -Width $res.Width -Height $res.Height -RowAxis 'X'; if ($slp.Valid) { $slotCount = $slp.Count } } catch {} }
            $lblReadout.Text = ('Part {0:0.00} x {1:0.00}  |  index + {2} = {3} hole(s)  |  {4} relief slot(s)' -f $res.Width, $res.Height, ($res.Count - 1), $res.Count, $slotCount)
            $lblErr.Text = ''
            $Wizard.SetChip('layout', ("custom: index + {0} holes" -f ($res.Count - 1)), 'set')
            $Wizard.SetChip('plate', ("plate {0:0.0}x{1:0.0}" -f $res.Width, $res.Height), 'set')
        } else {
            $Context.OrthoValid = $false; $lblReadout.Text=''
            if ($null -ne $res -and $res.Errors -and $res.Errors.Count -gt 0) { $lblErr.Text = (($res.Errors | Select-Object -First 2) -join '; ') }
            else { $lblErr.Text = 'Add at least one point with numeric X / Z' }
        }
        try { $preview.Invalidate() } catch {}
        try { $Wizard.Refresh() } catch {}
    }.GetNewClosure()

    $btnAdd.Add_Click({ $grid.Rows.Add(@('0','0')) | Out-Null; & $recompute }.GetNewClosure())
    $btnDel.Add_Click({
        $toRemove = @()
        foreach ($cell in $grid.SelectedCells) { $rr = $grid.Rows[$cell.RowIndex]; if (-not $rr.IsNewRow -and ($toRemove -notcontains $rr)) { $toRemove += $rr } }
        foreach ($rr in $toRemove) { $grid.Rows.Remove($rr) }
        & $recompute
    }.GetNewClosure())
    $grid.Add_CellValueChanged({ & $recompute }.GetNewClosure())
    $grid.Add_CellEndEdit({ & $recompute }.GetNewClosure())
    $tbIdxX.Add_TextChanged({ & $recompute }.GetNewClosure())
    $tbIdxZ.Add_TextChanged({ & $recompute }.GetNewClosure())
    & $recompute
    # content bottom (left-column error vs right-column legend) so the caller sizes its host.
    return ([Math]::Max([int]$lblErr.Bottom, [int]$lblLegend.Bottom))
}

# ============================================================================
# Add-LayoutPreview - a READ-ONLY numbered layout preview for the index-hole steps
# (user request 2026-07-17: "include the sample layout of the drilljig just like we
# see when selecting the distances ... label each hole so the user knows which index
# hole is what"). Draws the SAME plate + hole dots + chip-relief bands the layout
# editor shows, PLUS a number on each hole (Draw-HoleLabels) matching the "Hole #N"
# choice cards, and optionally RINGS the chosen index hole. Reads $Context.OrthoGeo
# (already captured by the layout step); does NOT edit anything. Reuses the pure
# Draw-SlotRects / Draw-HoleLabels / Draw-AxisGlyph helpers from lib\orthogrid_gui.ps1
# so the transform is identical to the inline editors' preview.
#
#   -Panel        the step canvas to add the preview into
#   -Context      the wizard context (for OrthoGeo + HoleDia)
#   -Top,-Left    top-left of the preview panel in the canvas (px)
#   -Width,-Height  preview panel size (defaults sized like the editor's preview)
#   -HighlightKeyRef  a [ref] to the 0-based index ordinal to ring; pass $null for
#                     no highlight. The Paint reads it live. Highlight refresh on a
#                     pick is driven by the step's -AfterPick 'rerender' (which rebuilds
#                     the whole Build + this panel with a fresh snapshot), NOT by a
#                     live .Invalidate() - no call site re-invalidates the returned panel.
# Returns the preview Panel. The panel .Tag is 'layout-preview' so tests can find it.
# ============================================================================
function Add-LayoutPreview {
    param($Panel, $Context, [int]$Top = 8, [int]$Left = 8, [int]$Width = 300, [int]$Height = 220, $HighlightKeyRef = $null)
    $thm = $script:WizTheme
    $muted   = if ($thm) { $thm.Muted } else { [System.Drawing.Color]::FromArgb(158,172,196) }
    $fieldBk = [System.Drawing.Color]::FromArgb(16,24,42)
    $clearDia = 0.0
    if ($null -ne $Context.HoleDia -and [double]$Context.HoleDia -gt 0) { $clearDia = [double]$Context.HoleDia }

    $preview = New-Object System.Windows.Forms.Panel
    $preview.Location  = New-Object System.Drawing.Point($Left, $Top)
    $preview.Size      = New-Object System.Drawing.Size($Width, $Height)
    $preview.BackColor = $fieldBk
    $preview.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $preview.Tag = 'layout-preview'   # so the offline test can locate + DrawToBitmap it
    $Panel.Controls.Add($preview)

    $lblLegend = New-Object System.Windows.Forms.Label
    $lblLegend.Location = New-Object System.Drawing.Point($Left, ($Top + $Height + 4)); $lblLegend.Size = New-Object System.Drawing.Size($Width, 20)
    $lblLegend.ForeColor = $muted; $lblLegend.BackColor = [System.Drawing.Color]::Transparent
    $lblLegend.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    $lblLegend.Text = [char]0x25CF + ' holes (numbered = Hole #)    ' + [char]0x25EF + ' chosen index'
    $Panel.Controls.Add($lblLegend)

    $preview.Add_Paint({
        param($s,$e)
        try {
            $g = $e.Graphics; $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $res = $Context.OrthoGeo
            if ($null -eq $res -or -not $res.Valid) { return }
            $w = [double]$res.Width; $h = [double]$res.Height
            if ($w -le 0 -or $h -le 0) { return }
            $cw = $s.ClientSize.Width; $ch = $s.ClientSize.Height; $margin = 20.0
            $availW = $cw - 2*$margin; $availH = $ch - 2*$margin
            if ($availW -le 1 -or $availH -le 1) { return }
            $scale = $availW / $w; if (($availH / $h) -lt $scale) { $scale = $availH / $h }
            if ($scale -le 0) { return }
            $drawW = $w*$scale; $drawH = $h*$scale
            $offX = ($cw-$drawW)/2.0; $offY = ($ch-$drawH)/2.0
            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(110,150,210), 1.5)
            $g.DrawRectangle($pen, [single]$offX, [single]$offY, [single]$drawW, [single]$drawH); $pen.Dispose()
            # chip-relief slot bands (UNDER the dots) - same Get-RowSlots math as the editor.
            # Honors $Context.SlotRowAxis (the layout-stage X/Z toggle) so the preview shows
            # which way the slots actually run; defaults to 'X' when unset (orthogrid/custom/
            # index previews, which never toggle it).
            if ($clearDia -gt 0) {
                try {
                    $slotRA = if ($Context.SlotRowAxis -eq 'Z') { 'Z' } else { 'X' }
                    $sl = Get-RowSlots -Points $res.Points -SlotWidth $clearDia -Width $w -Height $h -RowAxis $slotRA
                    Draw-SlotRects -Graphics $g -Slots $sl -OffX $offX -OffY $offY -DrawH $drawH -Scale $scale
                } catch {}
            }
            # holes drawn as TO-SCALE circles (real footprint; fixed dot if dia unknown)
            Draw-HoleCircles -Graphics $g -Points $res.Points -OffX $offX -OffY $offY -DrawH $drawH -Scale $scale -HoleDia $clearDia
            # numbers OVER the holes (match the "Hole #N" cards), ring the chosen index
            # (-HoleDia so the ring + number sit OUTSIDE the to-scale hole circle)
            $hk = $null
            if ($null -ne $HighlightKeyRef) { try { $hk = $HighlightKeyRef.Value } catch { $hk = $null } }
            Draw-HoleLabels -Graphics $g -Points $res.Points -OffX $offX -OffY $offY -DrawH $drawH -Scale $scale -HighlightKey $hk -HoleDia $clearDia
            Draw-AxisGlyph -Graphics $g -ClientW $cw -ClientH $ch
        } catch {}
    }.GetNewClosure())
    return $preview
}

# ============================================================================
# Add-SlotDirToggle - an inline X/Z chip-relief slot-DIRECTION picker for the LAYOUT
# stage (user 2026-07-23: the direction choice should live in the layout GUI so the
# operator SEES which way the slots run in the preview, not in a later Relief step).
# Two segmented toggle buttons ("Along X" / "Along Z"); the active one is accent-filled.
# Clicking sets $Context.SlotRowAxis and $Wizard.Rerender()s -- the rebuild re-runs
# Add-LayoutPreview, whose slot bands now read SlotRowAxis, so the preview updates live.
# Offered for the IMPORTED FASTENER layout (a fastener pattern has no operator-laid
# primary axis); orthogrid/custom keep 'X'. Returns the bottom Y of the row.
# ============================================================================
function Add-SlotDirToggle {
    param($Panel, $Context, $Wizard, [int]$Top, [int]$Left = 8)
    if ($null -eq $Context.SlotRowAxis) { $Context.SlotRowAxis = 'X' }
    $cur = if ($Context.SlotRowAxis -eq 'Z') { 'Z' } else { 'X' }
    $thm = $script:WizTheme
    $accent = if ($thm -and $thm.Accent) { $thm.Accent } else { [System.Drawing.Color]::FromArgb(40,90,170) }
    $idle   = if ($thm) { $thm.CanvasBack } else { [System.Drawing.Color]::FromArgb(30,42,68) }
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Chip-relief slot direction:'; $lbl.AutoSize = $true
    $lbl.Location = New-Object System.Drawing.Point($Left, ($Top + 5))
    $lbl.ForeColor = Get-UiColor ''; $lbl.BackColor = [System.Drawing.Color]::Transparent
    $Panel.Controls.Add($lbl)
    $bx = $Left + 175
    foreach ($opt in @(@{ A='X'; T='Along X' }, @{ A='Z'; T='Along Z' })) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $opt.T; $b.Size = New-Object System.Drawing.Size(92, 28)
        $b.Location = New-Object System.Drawing.Point($bx, $Top)
        $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90,104,132)
        $b.ForeColor = Get-UiColor ''
        $b.BackColor = if ($opt.A -eq $cur) { $accent } else { $idle }
        $ax = $opt.A
        $b.Add_Click({ param($s,$e) $Context.SlotRowAxis = $ax; $Wizard.Rerender() }.GetNewClosure())
        $Panel.Controls.Add($b)
        $bx += 100
    }
    return ($Top + 28)
}

# ============================================================================
# Build the connection up front (before the wizard) so the breadcrumb's later
# stages reflect a real session and pick steps have a live buffer to read. The
# decision tree + point-source are pure WinForms and could run before connecting,
# but a single connect here keeps the lifecycle identical to drilljig.cmd and
# lets the FIRST screen already say "Connected: <part>".
# ============================================================================
$procs = @(Get-Process -Name xtop -ErrorAction SilentlyContinue)
if ($procs.Count -eq 0) { throw "Creo (xtop.exe) is not running. Open Creo and the jig PART, then re-run." }
if ($procs.Count -gt 1) { throw "More than one Creo session is open. This tool expects exactly ONE." }
$proc = $procs[0]
$Env:PRO_DIRECTORY    = $proc.Path.TrimEnd("xtop.exe")
$Env:PRO_COMM_MSG_EXE = $proc.Path -replace "xtop.exe", "pro_comm_msg.exe"

# ----------------------------------------------------------------------------
# PREFLIGHT self-heal: clear ORPHANED repo automation shells before connecting.
# The #1 cause of a persistent RPC_E_SERVERFAULT (0x80010105 "the server threw
# an exception") on Connect() -- the fault that looks like "Creo needs
# restarting AGAIN" -- is a PRIOR run of a repo .cmd tool that is still ALIVE
# holding Creo's single async-COM slot: parked at "Press any key to exit" after
# a failure, a wizard window closed without pressing a key, or a leaked
# throwaway fastener connection. Creo serves ~one async client at a time, so the
# next Connect() faults until that process dies. Restarting Creo "fixes" it only
# because it drops the server side of the stale link -- killing the orphan does
# the same WITHOUT losing the Creo session. So self-heal here: find lingering
# repo-tool shells (the hybrid-.cmd launcher signature -- scriptblock::Create +
# Get-Content -Raw + THIS repo path -- which never matches a VS Code / Claude
# terminal) other than THIS process, and terminate them. Never throws: a CIM /
# permission hiccup must not block a legitimate launch (the retry loop below is
# the fallback). Because the tool already requires exactly ONE Creo, two repo
# automation shells can never usefully coexist -- killing the others is correct.
$selfPid = $PID
try {
    $repoPat = [regex]::Escape($ScriptDir.TrimEnd('\'))
    $orphans = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop | Where-Object {
        $_.ProcessId -ne $selfPid -and
        $null -ne $_.CommandLine -and
        $_.CommandLine -match 'scriptblock\]::Create' -and
        $_.CommandLine -match 'Get-Content -Raw' -and
        $_.CommandLine -match $repoPat
    })
    if ($orphans.Count -gt 0) {
        Write-Host ""
        Write-Host "  Found $($orphans.Count) lingering drill-jig automation shell(s) from a prior run." -ForegroundColor Yellow
        Write-Host "  These hold Creo's COM connection and are the usual cause of the 'server threw an exception' fault." -ForegroundColor DarkGray
        foreach ($o in $orphans) {
            Write-Host "    - terminating orphan PID $($o.ProcessId) (frees the Creo connection; no Creo restart needed)" -ForegroundColor DarkGray
            try { Stop-Process -Id $o.ProcessId -Force -ErrorAction Stop } catch {}
        }
        Start-Sleep -Milliseconds 1000   # let Creo's RPC server notice the dropped client and release the slot
        Write-Host "  Cleared. Connecting..." -ForegroundColor Green
    }
} catch {
    # CIM unavailable / access denied -- skip self-heal, fall through to the retry loop.
}

try { New-Object -ComObject pfcls.pfcAsyncConnection | Out-Null }
catch {
    $reg = $proc.Path -replace "Common Files(.*)$", "Parametric\bin\vb_api_register.bat"
    Start-Process -Wait -FilePath $reg
}

# Connect to Creo's async COM server WITH RETRY. RPC_E_SERVERFAULT (0x80010105 "the server
# threw an exception") and similar faults HERE are almost always a TRANSIENT Creo state --
# the session is mid-regen, a modal dialog is still open, or the COM server is momentarily
# busy -- not a script bug. Retry a few times with a short pause, using a FRESH connection
# object each attempt (a faulted async object can stay poisoned), then give actionable
# recovery guidance if it still will not connect.
$async      = New-Object -ComObject pfcls.pfcAsyncConnection
$connection = $null
$connErr    = $null
for ($cattempt = 1; $cattempt -le 5; $cattempt++) {
    try { $connection = $async.Connect($null, $null, $null, $null); break }
    catch {
        $connErr = $_
        if ($cattempt -lt 5) {
            Write-Host ("  Creo refused the connection (attempt $cattempt/5): $($_.Exception.Message)") -ForegroundColor Yellow
            Write-Host "  Retrying in 2s -- click into Creo and make sure it is IDLE (no open dialog, not mid-regen)..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 2
            try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($async) | Out-Null } catch {}
            $async = New-Object -ComObject pfcls.pfcAsyncConnection
        }
    }
}
if ($null -eq $connection) {
    # Release the faulted async object so THIS process leaves nothing holding the
    # Creo slot on its way out (a leaked $async here would poison the next launch too).
    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($async) | Out-Null } catch {}
    $async = $null
    throw ("Could not connect to Creo after 5 attempts ($($connErr.Exception.Message)). This is a Creo-SIDE " +
           "connection fault (the Creo COM server threw), NOT a script error. Recover by: (1) click into the Creo " +
           "window and DISMISS any open dialog / finish or cancel any in-progress feature; (2) make sure a PART is " +
           "open and Creo is fully loaded and idle; (3) if it still fails, SAVE and RESTART Creo, then re-run. " +
           "NOTE: a lingering prior run is the usual cause -- this tool now auto-clears those at launch, so a plain " +
           "re-run normally succeeds without touching Creo.")
}
$session    = $connection.Session
$model      = $session.GetActiveModel()
if ($null -eq $model) { throw "No active model. Open the jig PART (default datum planes; target datum points if predefined) first." }

$modelFile = ""
try { $modelFile = [string]$model.FileName } catch {}
if ($modelFile -match '\.asm(\.\d+)?$') {
    Write-Host ""
    Write-Host "  STOP: the active model is an ASSEMBLY ($modelFile)." -ForegroundColor Yellow
    Write-Host "  This tool builds + drills a single PART. Open the jig PART itself, then re-run." -ForegroundColor Yellow
    $connection.Disconnect($null)
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

# config suppress (restored in finally)
$origVisibleMapkeys = $null
$origDynamicPreview = $null
try { $vals = $session.GetConfigOptionValues("visible_mapkeys"); if ($null -ne $vals -and $vals.Count -gt 0) { $origVisibleMapkeys = $vals.Item(0) } } catch {}
try { $vals = $session.GetConfigOptionValues("dynamic_preview"); if ($null -ne $vals -and $vals.Count -gt 0) { $origDynamicPreview = $vals.Item(0) } } catch {}
try { $session.SetConfigOption("visible_mapkeys", "no") | Out-Null; $session.SetConfigOption("dynamic_preview", "no") | Out-Null } catch {}

$pfcType = New-Object -ComObject pfcls.pfcModelItemType

# wire the engine to this session + route its log into the wizard
Initialize-DrilljigCore -Session $session -Model $model -TypeObj $pfcType -DataDir $dataDir -Log $djLogger
$ctx.Session = $session
$ctx.Model   = $model
$ctx.Type    = $pfcType
$ctx.ModelName = $modelFile
$ctx.Connected = $true

# ============================================================================
# WIZARD STEPS
# ============================================================================
$steps = New-Object System.Collections.ArrayList

# ---- STAGE: Welcome -- a live 3D jig render + a plain-language process overview --
# The very first page. It shows a nice-quality 3D render of a finished drill jig via the
# SAME WebView2 + three.js renderer the Overview stage uses (WebGL, real anti-aliasing +
# PBR materials - the quality the user approved; WPF Media3D was rejected as "not rendered
# that well"). The shared HTML (docs\drilljig_3d_preview.html) loads in a dedicated
# '#welcome' mode: a generic jig WITH seated drill bushings + a chip-relief slot on the
# bottom, full-bleed, gently auto-orbiting (drag to rotate) - NOT the operator's real
# layout, which they have not chosen yet. Beside/below it is a numbered "here is what you
# will do" walkthrough, so an operator opening the tool cold knows what to expect.
# Purely informational: it touches no Creo, commits nothing, Validate/OnNext always allow
# (just "Get started"). Placed FIRST so it is the landing screen; the Import stage follows.
$welcomeStep = New-WizardStep -Key 'welcome' -Title 'Welcome to the Drill Jig Builder' -Stage 'Welcome' -Kind 'info' -PrimaryText 'Get started' `
    -Validate { param($c) return $true } `
    -OnNext { param($c, $wiz) return $true } `
    -Build {
        param($panel, $c, $wiz)

        # ---- static 3D jig render (top-left): the SAME WebView2 + three.js renderer the
        # Overview stage uses (WebGL, real anti-aliasing + PBR materials - the quality the
        # user approved; WPF Media3D was rejected as "not rendered that well"). It loads the
        # shared HTML in a dedicated '#welcome' mode: full-bleed hero, no sidebar, a generic
        # jig WITH seated drill bushings + a bottom chip-relief slot, gently auto-orbiting.
        # Drag to rotate. Sized to the left ~46% so the steps sit alongside on a wide window.
        $availW = [Math]::Max(360, $panel.Width - 26)
        $picW = [Math]::Max(300, [int]($availW * 0.46))
        $picH = [Math]::Max(220, [int]($picW * 0.60))
        $picBottom = 8 + $picH
        # HEADLESS GUARD (mirrors the Overview stage): only spin up WebView2 when a live
        # WinForms message loop is running; the offline fuzz/render tests render this Build
        # on a detached panel with no loop -> take the note path, no browser instantiated.
        $wvOk = $false
        if ([System.Windows.Forms.Application]::MessageLoop) {
            try { Add-WebView2Assemblies | Out-Null; $wvOk = $true } catch { $wvOk = $false }
        }
        if ($wvOk) {
            $wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
            $props = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
            # DISTINCT UserDataFolder from the Overview stage's WebView2: a shared folder is
            # LOCKED by whichever browser process is alive, so two WebView2s contending for it
            # can leave the second blank. (Each control is also disposed on step change - see
            # lib\wizard.ps1 renderStep - so processes don't leak/freeze.)
            $props.UserDataFolder = Join-Path $env:TEMP 'drilljig_wv2_welcome'
            $wv.CreationProperties = $props
            $wv.Location = New-Object System.Drawing.Point(8, 8)
            $wv.Size     = New-Object System.Drawing.Size($picW, $picH)
            $wv.Tag      = 'welcome-render'   # so the offline test can locate it
            $panel.Controls.Add($wv)
            $htmlPath = Join-Path $ScriptDir 'docs\drilljig_3d_preview.html'
            $fileUri = ([System.Uri]$htmlPath).AbsoluteUri + '#welcome'   # hero mode: seated bushings, no sidebar
            try { $wv.Source = New-Object System.Uri($fileUri) } catch {}
            $picBottom = $wv.Bottom
        } else {
            # WebView2 unavailable (or headless test): a bordered placeholder so the page still reads.
            $pic = New-Object System.Windows.Forms.Panel
            $pic.Location    = New-Object System.Drawing.Point(8, 8)
            $pic.Size        = New-Object System.Drawing.Size($picW, $picH)
            $pic.BackColor   = [System.Drawing.Color]::FromArgb(16, 24, 42)
            $pic.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
            $pic.Tag         = 'welcome-render'
            $lblPh = New-Object System.Windows.Forms.Label
            $lblPh.Dock = [System.Windows.Forms.DockStyle]::Fill
            $lblPh.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
            $lblPh.ForeColor = (Get-UiColor 'gray')
            $lblPh.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Italic)
            $lblPh.Text = "[3D drill-jig preview renders here in the live window]"
            $pic.Controls.Add($lblPh)
            $panel.Controls.Add($pic)
            $picBottom = $pic.Bottom
        }

        $capY = $picBottom + 4
        $cap = Add-Para $panel ("Illustrative 3D view of a finished jig - a plate with drill bushings seated in the guide holes and a chip-relief slot on the bottom (drag to rotate). Your jig is built from your own choices in the steps that follow.") $capY 0 'gray' $false 8 ($picW)
        $cap.Font = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Italic)

        # ---- process overview (right of / below the picture): brief instructions ----
        # If the window is wide enough, the text column sits to the RIGHT of the picture;
        # otherwise it flows BELOW it (so nothing is clipped on a narrow window).
        $wide = ($panel.Width - $picW - 40) -ge 320
        $tx   = if ($wide) { $picW + 28 } else { 8 }
        $ty   = if ($wide) { 8 } else { [Math]::Max($cap.Bottom + 14, $pic.Bottom + 14) }
        $tw   = if ($wide) { $panel.Width - $tx - 26 } else { $availW }

        $ty = (Add-Para $panel "What this tool does" $ty 0 '' $true $tx $tw).Bottom + 4
        $ty = (Add-Para $panel ("It walks you through building a drill-jig PART in the open Creo model: it sizes a plate, drills a guide hole at each point, rounds the corners, and cuts chip-relief slots - so you don't drive the mapkeys by hand.") $ty 0 'gray' $false $tx $tw).Bottom + 12

        $ty = (Add-Para $panel "What you'll go through" $ty 0 '' $true $tx $tw).Bottom + 4
        $stepsText = @(
            "1.  Import (optional) - reuse an existing part's fastener pattern as the hole layout, or skip.",
            "2.  Bushing & hole size - answer a few questions; the tool picks the bushing and the drilled hole size.",
            "3.  Slot depth - standard clearance, or a thinner plate for tight/restricted spaces.",
            "4.  Layout - a regular grid, hand-placed points, or the imported fastener pattern; then pick the index hole.",
            "5.  Datums - the tool finds the TOP/SIDE/FRONT planes (you confirm, or pick them once).",
            "6.  Box - it builds the parametric plate (you draw one rough rectangle in Creo).",
            "7.  Drill - it creates the points, rounds the corners, and drills every guide hole.",
            "8.  Chip-relief slots - one slot per hole row, drawn once and patterned.",
            "9.  Done - a summary of what was built."
        ) -join [Environment]::NewLine
        $ty = (Add-Para $panel $stepsText $ty 0 '' $false $tx $tw).Bottom + 12

        $ty = (Add-Para $panel ("Before you start: open the jig PART (not an assembly) in Creo, and keep Creo idle - the tool will tell you exactly when to click in the Creo window (draw a rectangle, pick a plane, select the seed slot). You can move Back and jump between stages at any time using the bar at the top.") $ty 0 'yellow' $false $tx $tw).Bottom + 8
        (Add-Para $panel ("Press 'Get started' to begin.") $ty 0 '' $true $tx $tw) | Out-Null
    }
[void]$steps.Add($welcomeStep)

# Initialise the tree cursor at the first root node.
try {
    if (-not (Test-Path $ctx.TreePath)) { throw "Decision tree not found at: $($ctx.TreePath)" }
    $treeRoot = Get-Content $ctx.TreePath -Raw | ConvertFrom-Json
    $ctx.TreeNode = @($treeRoot)[0]
    # Store the ROOT node + a decision HISTORY in the persistent context. The tree
    # step's button/OnPick closures run via .GetNewClosure() and resolve bare vars
    # against their captured scope + GLOBAL only -- a top-level local like $treeRoot is
    # NOT captured, so it reads $null at click time (that was the "Change selection ->
    # Tree finished" bug: $c.TreeNode = @($null)[0] = $null). Reading $c.TreeRoot /
    # $c.TreeHistory (context fields) is always safe. TreeHistory backs the in-flow
    # back-and-forth (Push/Pop-TreeHistory).
    $ctx.TreeRoot    = @($treeRoot)[0]
    $ctx.TreeHistory = [System.Collections.ArrayList]::new()
} catch { throw "Could not load the decision tree: $($_.Exception.Message)" }

# ---- STAGE: Import -- OPTIONAL fastener-layout read, FIRST (user 2026-07-20) -----
# Offered before the decision tree so the operator captures the hole pattern from the
# source part/assembly up front. Captures RAW {X;Z} points into $ctx.FastenerRawPoints;
# the Layout stage builds the plate from them once the hole dia is known. Skippable ->
# the normal Layout tiles still appear. This is additive: it does NOT change the proven
# file/live read (Invoke-GuiFastenerLiveRead) -- it just runs it earlier + stores raw pts.
$importStep = New-WizardStep -Key 'import' -Title 'Import fastener layout (optional)' -Stage 'Import' -Kind 'choice' -PrimaryText 'Next' `
    -Validate { param($c) return $true } `
    -Build {
        param($panel, $c, $wiz)
        $y = 8
        $y = (Add-Para $panel "Place the jig holes at an existing part/assembly's FASTENERS?" $y 0 'gray').Bottom + 6
        $y = (Add-Para $panel "Read the fastener centers now (before choosing bushing/material). The hole pattern is captured up front; the plate is sized to it after the bushing is picked. Or skip and choose a layout later." $y 0 'gray').Bottom + 8
        if ($null -ne $c.FastenerRawPoints -and @($c.FastenerRawPoints).Count -gt 0) {
            $y = (Add-Para $panel (([char]0x2713) + (" Captured {0} fastener hole(s). Press Next -- the layout is applied after the bushing step." -f @($c.FastenerRawPoints).Count)) $y 0 'DarkGreen' $true).Bottom + 8
        }
        $btnRead = New-Object System.Windows.Forms.Button
        $btnRead.Text = 'Read fasteners now'
        $btnRead.Size = New-Object System.Drawing.Size(190, 32)
        $btnRead.Location = New-Object System.Drawing.Point(8, ($y + 4))
        $btnRead.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnRead.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90,104,132)
        $btnRead.BackColor = if ($script:WizTheme -and $script:WizTheme.Accent) { $script:WizTheme.Accent } else { [System.Drawing.Color]::FromArgb(40,90,170) }
        $btnRead.ForeColor = Get-UiColor ''
        $btnRead.Add_Click({
            $out = Join-Path $ScriptDir 'fastener_layout.json'
            $written = Invoke-GuiFastenerLiveRead -OutPath $out -HoleDia 0.25 -Wizard $wiz   # nominal margin; re-anchored to the real hole dia in Layout; -Wizard so prompts render in-canvas
            if ($null -ne $written) {
                $back = Read-FastenerLayout -Path $written
                if ($back.Valid) { $c.FastenerRawPoints = $back.Points; $c.PointMode = 'fastener'; $wiz.SetChip('layout', ("layout: fastener ({0})" -f $back.Count), 'set') }
            }
            $wiz.Rerender()
        }.GetNewClosure())
        $panel.Controls.Add($btnRead)
    } `
    -OnNext { param($c,$wiz) $c.FastenerAsked = $true; return $true }
[void]$steps.Add($importStep)

# ---- STAGE: Bushing -- the decision tree, descended card-by-card -----------
# This single step re-renders in place as the user picks each answer. It walks
# 'question' nodes as choice cards; at an 'outcome' it resolves the hole diameter
# (catalog pick or fixed OD) and marks the tree done, enabling Next.
$treeStep = New-WizardStep -Key 'tree' -Title 'Bushing & hole size' -Stage 'Bushing' -Kind 'choice' -PrimaryText 'Next' `
    -Validate {
        param($c)
        if ($c.TreeDone) { return $true }
        # Enable Next at the LENGTH stage when there is a length to commit WITHOUT a
        # click, so the operator can just press Next to take the recommendation (user
        # 2026-07-21). Fixed sub-stage: a recommended length exists (PreselectIndex>=0).
        # Custom sub-stage: the typed value is valid (BushLenValid). OD tie-break ('od')
        # is NEVER auto-committed -- OD is the drilled hole, so it stays an explicit pick.
        # The length stage exists for BOTH the ID-first (sleeve, keyed on BushID) and the
        # OD-first (metal removable, keyed on BushOD) flows. Recommend from whichever is set.
        if ($null -ne $c.PendingSpec -and $c.BushStage -eq 'len') {
            # Recommend-source: custom OD (typed) first, then metal OD-first, then sleeve ID.
            $lrv = if ($c.BushCustom -and $null -ne $c.BushCustomOd) { [double]$c.BushCustomOd }
                   elseif ($c.BushOdFirst -and $null -ne $c.BushOD) { [double]$c.BushOD.OD }
                   elseif (-not $c.BushOdFirst -and $null -ne $c.BushID) { [double]$c.BushID.ID }
                   else { $null }
            if ($null -eq $lrv) { return $false }
            if ($c.BushLenIsCustom) { return [bool]$c.BushLenValid }
            return ((Get-BushingLengthOptions -Id $lrv).PreselectIndex -ge 0)
        }
        return $false
    } `
    -Build {
        param($panel, $c, $wiz)
        $node = $c.TreeNode

        # DONE? Show a CONFIRMATION (not the cards again) so the user can't keep
        # cycling. A 'Change selection' button resets the whole pick cursor and
        # re-renders, letting them re-walk. This is the user's ask 2026-06-26:
        # "once the user goes through the options, confirm a bushing is selected;
        # if they need to change, a change button."
        if ($c.TreeDone) {
            $active = if ($c.Picks.Count -gt 0) { $c.Picks[$c.Picks.Count - 1] } else { $null }
            $y = 8
            if ($null -ne $active) {
                $y = (Add-Para $panel "Bushing selected:" $y 0 'gray' $true).Bottom + 4
                $y = (Add-Para $panel ([string]$active.Bushing) $y 0 '' $true).Bottom + 6
                $dia = [double]$active.HoleDiameter
                $line = ("Hole diameter (= OD): {0}`"" -f $dia)
                if ($null -ne $active.BushingLength) { $line += ("    Bushing length: {0}`"" -f [double]$active.BushingLength) }
                $y = (Add-Para $panel $line $y 0 'green').Bottom + 6
                if ($active.PartNumber -and $active.PartNumber -notmatch 'n/a|unspecified') {
                    $y = (Add-Para $panel ("Part number: {0}" -f $active.PartNumber) $y 0 'gray').Bottom + 6
                }
                $y = (Add-Para $panel ([char]0x2713 + " Registered. Press Next to continue, or change the selection below.") $y 0 'green' $true).Bottom + 10

                # CUSTOM-OD warning (user 2026-07-23): a typed hole OD has no catalog bushing
                # behind it -- remind the operator to verify a real drill bushing / sleeve exists.
                if ([string]$active.BushingID -eq '(custom)') {
                    $y = (Add-Para $panel ([char]0x26A0 + " Custom hole OD -- verify a drill bushing / bushing sleeve at this OD actually exists before machining.") $y 0 'yellow' $true).Bottom + 10
                }

                # DISPLAY-ONLY bushing schematic (user 2026-07-22): a GDI+ picture of the
                # picked bushing (Draw-BushingSchematic, lib\bushing_svg.ps1). No controls,
                # no save, no selection - just a drawing. OD = the drilled hole; Length =
                # bushing length; ID = the bore, "(any)" for the METAL removable path where
                # the bore is operator-chosen (drilled hole IS the OD). Skipped for the
                # fixed-OD "no bushing" leaf (BushingLength null).
                $bsOD  = [double]$active.HoleDiameter
                $bsLen = if ($null -ne $active.BushingLength) { [double]$active.BushingLength } else { 0.0 }
                $bsIdVal = 0.0; $bsIdLabel = ''; $bsIdNum = 0.0
                if ($null -ne $active.BushingID -and [double]::TryParse([string]$active.BushingID, [ref]$bsIdNum) -and $bsIdNum -gt 0 -and $bsIdNum -lt $bsOD) {
                    $bsIdVal = $bsIdNum                                 # a real, known bore (sleeve / ID-first pick)
                } elseif ($bsOD -gt 0) {
                    $bsIdVal = $bsOD * 0.5                              # bore indeterminate
                    # metal removable = '(any)'; custom OD = '(verify)' (no catalog bushing behind it).
                    $bsIdLabel = if ([string]$active.BushingID -eq '(custom)') { '(verify)' } else { '(any)' }
                }
                if ($bsOD -gt 0 -and $bsLen -gt 0 -and $bsIdVal -gt 0) {
                    $bsLabel = [string]$active.Bushing
                    # DRILL BUSHINGS are headed; SLEEVES are headless (user 2026-07-22). A
                    # representative head (no dimension) is drawn so the two are not confused.
                    $bsHeadDia = Get-BushingHeadDia -EasyName $bsLabel -OD $bsOD
                    $bsBack  = if ($script:WizTheme) { $script:WizTheme.CanvasBack } else { [System.Drawing.Color]::FromArgb(30,42,68) }
                    # Layout: 2D schematic + 3D model SIDE BY SIDE (aside each other, user
                    # 2026-07-22); stack them when the canvas is too narrow, or when WPF 3D
                    # is unavailable show the 2D full-width.
                    $viewH = 290; $gap = 12
                    $avail = [Math]::Max(320, $panel.Width - 24)
                    $sideBySide = ($avail -ge 680) -and $script:Wpf3dOk
                    if ($sideBySide) {
                        $cellW = [Math]::Min(440, [int][Math]::Floor(($avail - $gap) / 2))
                        $x2d = 8; $y2d = $y; $x3d = 8 + $cellW + $gap; $y3d = $y
                    } else {
                        $cellW = [Math]::Min(600, $avail)
                        $x2d = 8; $y2d = $y; $x3d = 8; $y3d = $y + $viewH + 26
                    }
                    # 2D schematic panel (GDI+ Draw-BushingSchematic)
                    $bsPanel = New-Object System.Windows.Forms.Panel
                    $bsPanel.Size = New-Object System.Drawing.Size($cellW, $viewH)
                    $bsPanel.Location = New-Object System.Drawing.Point($x2d, $y2d)
                    $bsPanel.BackColor = $bsBack
                    try {
                        $dbp = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
                        $dbp.SetValue($bsPanel, $true, $null)
                    } catch {}
                    $bsPanel.Add_Paint({
                        param($snd, $ev)
                        try {
                            Draw-BushingSchematic -Graphics $ev.Graphics -OD $bsOD -ID $bsIdVal -Length $bsLen -HeadDia $bsHeadDia `
                                -ClientW $snd.ClientSize.Width -ClientH $snd.ClientSize.Height `
                                -ShowEnd $true -ShowDims $true -Background $bsBack -Label $bsLabel -IdLabel $bsIdLabel
                        } catch { }
                    }.GetNewClosure())
                    $panel.Controls.Add($bsPanel)
                    $lastBottom = $bsPanel.Bottom
                    # 3D model (WPF Media3D) - a BONUS view beside/below the 2D. Same HeadDia,
                    # so a sleeve is a headless tube and a drill bushing shows a head. On any
                    # WPF failure it is simply omitted (the 2D schematic always shows).
                    $eh3d = $null
                    if ($script:Wpf3dOk) {
                        try { $eh3d = New-BushingViewportHost -OD $bsOD -ID $bsIdVal -Length $bsLen -HeadDia $bsHeadDia -Width $cellW -Height $viewH -Background $bsBack } catch { $eh3d = $null }
                    }
                    if ($null -ne $eh3d) {
                        $eh3d.Location = New-Object System.Drawing.Point($x3d, $y3d)
                        $eh3d.Size = New-Object System.Drawing.Size($cellW, $viewH)
                        $panel.Controls.Add($eh3d)
                        $cap = New-Object System.Windows.Forms.Label
                        $cap.Text = ([char]0x2192 + " 3D: drag to rotate, wheel to zoom")
                        $cap.AutoSize = $true; $cap.ForeColor = Get-UiColor 'gray'; $cap.BackColor = [System.Drawing.Color]::Transparent
                        $cap.Font = New-Object System.Drawing.Font('Segoe UI', 8)
                        $cap.Location = New-Object System.Drawing.Point(($x3d + 2), ($y3d + $viewH + 1))
                        $panel.Controls.Add($cap)
                        $lastBottom = [Math]::Max([int]$lastBottom, [int]$cap.Bottom)
                    }
                    $y = [int]$lastBottom + 12
                }
            } else {
                $y = (Add-Para $panel "Selection complete (no catalog bushing was resolved)." $y 0 'gray').Bottom + 10
            }
            # Change buttons. Two ways to go back and forth in the sleeve selection:
            #   * "< Back to options" pops ONE decision (Pop-TreeHistory) -> re-enter the
            #     last sub-stage (OD / length / ID) or previous question, so you can tweak
            #     the sleeve without re-answering everything. Shown only if there's history.
            #   * "Start over" fully resets to the first question (Reset-TreeWalk).
            # BOTH read the root/history from the CONTEXT ($c.*), never the top-level
            # $treeRoot -- a .GetNewClosure() handler does NOT capture $treeRoot, so the old
            # `$c.TreeNode = @($treeRoot)[0]` read $null -> "Tree finished" (the reported bug).
            $thm = $script:WizTheme
            $bx = 8
            if (@($c.TreeHistory).Count -gt 0) {
                $btnBackOne = New-Object System.Windows.Forms.Button
                $btnBackOne.Text = ([char]0x2039) + ' Back to options'
                $btnBackOne.Size = New-Object System.Drawing.Size(170, 34)
                $btnBackOne.Location = New-Object System.Drawing.Point($bx, $y)
                $btnBackOne.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
                $btnBackOne.FlatAppearance.BorderSize = 1
                $btnBackOne.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(120,170,255)
                $btnBackOne.BackColor = [System.Drawing.Color]::FromArgb(54,72,112)
                $btnBackOne.ForeColor = [System.Drawing.Color]::White
                $btnBackOne.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
                $btnBackOne.Add_Click({
                    $old = $ErrorActionPreference
                    try { $ErrorActionPreference = 'Continue'; [void](Pop-TreeHistory -Context $c); $wiz.Rerender() }
                    catch { try { $wiz.LogError($_, 'bushing back one') } catch {} }
                    finally { $ErrorActionPreference = $old }
                }.GetNewClosure())
                $panel.Controls.Add($btnBackOne)
                $bx += 182
            }
            $btnChange = New-Object System.Windows.Forms.Button
            $btnChange.Text = 'Start over'
            $btnChange.Size = New-Object System.Drawing.Size(140, 34)
            $btnChange.Location = New-Object System.Drawing.Point($bx, $y)
            $btnChange.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            $btnChange.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90,104,132)
            $btnChange.BackColor = if ($thm) { $thm.CanvasBack } else { [System.Drawing.Color]::FromArgb(30,42,68) }
            $btnChange.ForeColor = Get-UiColor ''
            $btnChange.Add_Click({
                $old = $ErrorActionPreference
                try { $ErrorActionPreference = 'Continue'; Reset-TreeWalk -Context $c; $wiz.Rerender() }
                catch { try { $wiz.LogError($_, 'change bushing') } catch {} }
                finally { $ErrorActionPreference = $old }
            }.GetNewClosure())
            $panel.Controls.Add($btnChange)
            return
        }

        # IN-FLOW back: during the walk (questions + sleeve sub-flow) a compact "< Back"
        # pops ONE decision (Pop-TreeHistory), so the operator can step back and forth
        # through ID / length / OD or the earlier questions. Shown only when there is a
        # previous step. The header + cards below start at $walkTop so they clear it.
        $walkTop = 8
        if (@($c.TreeHistory).Count -gt 0) {
            $btnWalkBack = New-Object System.Windows.Forms.Button
            $btnWalkBack.Text = ([char]0x2039) + ' Back'
            $btnWalkBack.Size = New-Object System.Drawing.Size(90, 30)
            $btnWalkBack.Location = New-Object System.Drawing.Point(8, 6)
            $btnWalkBack.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            $btnWalkBack.FlatAppearance.BorderSize = 1
            $btnWalkBack.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(120,170,255)
            $btnWalkBack.BackColor = [System.Drawing.Color]::FromArgb(54,72,112)
            $btnWalkBack.ForeColor = [System.Drawing.Color]::White
            $btnWalkBack.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
            $btnWalkBack.Add_Click({
                $old = $ErrorActionPreference
                try { $ErrorActionPreference = 'Continue'; [void](Pop-TreeHistory -Context $c); $wiz.Rerender() }
                catch { try { $wiz.LogError($_, 'bushing walk back') } catch {} }
                finally { $ErrorActionPreference = $old }
            }.GetNewClosure())
            $panel.Controls.Add($btnWalkBack)
            $walkTop = 46
        }

        # Are we mid bushing-pick? Render the ID-FIRST sub-flow (user 2026-07-21):
        # ID first, length second, and OD auto-resolved after those UNLESS a bore+length
        # exists at more than one OD (ODCount > 1) -> then the OD tie-breaker card set is
        # shown. OD is the drilled jig hole, so it is never silently chosen.
        if ($null -ne $c.PendingSpec) {
            $rows = Get-CatalogRows -Spec $c.PendingSpec
            if ($rows.Count -eq 0) {
                Add-Para $panel "No catalog rows match this branch. (file: $(Split-Path $c.PendingSpec.File -Leaf))" 8 40 'Firebrick'
                $c.PendingSpec = $null; $c.TreeDone = $true
                return
            }
            # OD-FIRST metal path (user 2026-07-22): METAL -> PFD / Hand Drill is OD-filtered
            # (only 1/2" & 3/4" ODs). The drilled hole IS the removable bushing's OD, so show
            # OD cards (no ID question), then the standardized length. Persist the OD groups in
            # $c.BushOdGroups (never a Build-local -- the captured-variable rule).
            if ($c.BushOdFirst) {
                $c.BushOdGroups = Get-OdGroups -Rows $rows
                if ($c.BushStage -eq 'od1' -or $null -eq $c.BushStage) {
                    $hdrB = (Add-Para $panel "Select the OD (removable bushing = the drilled hole):" $walkTop 0 $null $true).Bottom
                    $opts = @()
                    foreach ($og in $c.BushOdGroups) { $opts += @{ Title = ('OD ' + $og.ODLabel); Subtitle = ("-> hole {0:0.###}`"" -f $og.OD) } }
                    # trailing "Custom hole OD..." card (user 2026-07-23): type any diameter.
                    $opts += @{ Title = 'Custom hole OD...'; Subtitle = 'type any diameter' }
                    Add-WizardChoiceCards -Panel $panel -Options $opts -Context $c -Wizard $wiz -Top ($hdrB + 10) -CardWidth 200 -CardHeight 96 -OnPick {
                        param($i,$opt,$cc,$w)
                        Push-TreeHistory -Context $cc   # snapshot the 'od1' stage so Back returns here
                        # index-guard: the last card is the custom-OD entry (past the OD groups).
                        if ($i -ge @($cc.BushOdGroups).Count) {
                            $cc.BushCustom = $true; $cc.BushOdFirst = $false; $cc.BushOD = $null
                            $cc.BushStage = 'customod'
                            $cc.BushCustomOdText = ''; $cc.BushCustomOdValid = $false; $cc.BushCustomOd = $null; $cc.BushCustomOdLabel = $null
                            return
                        }
                        $cc.BushOD = @($cc.BushOdGroups)[$i]
                        $cc.BushStage = 'len'
                        $cc.BushLenIsCustom = $false; $cc.BushLenCustomText = ''; $cc.BushLenValid = $true
                    }
                    return
                }
                # (BushStage 'len' for the OD-first path is handled by the shared 'len' block below.)
            }
            # Stash the grouped catalog in the PERSISTENT context ($c.Grouped), NOT a
            # Build-local: the OnPick scriptblock fires AFTER Build returns and a plain
            # {..} does not capture Build locals, so a Build-local $grouped would be
            # $null at click time -> "Cannot index into a null array". $cc.Grouped lives.
            if (-not $c.BushOdFirst) { $c.Grouped = Group-CatalogByID -Rows $rows }
            if (-not $c.BushOdFirst -and ($c.BushStage -eq 'id' -or $null -eq $c.BushStage)) {
                # ID cards carry the resolved-hole preview now (OD keys on ID, not length).
                $hdrB = (Add-Para $panel "Select the ID (bore size):" $walkTop 0 $null $true).Bottom
                $opts = @()
                foreach ($g in $c.Grouped) {
                    $ods = Get-IdOdOptions -IdGroup $g
                    $sub = if (@($ods).Count -eq 1) { ("-> hole {0:0.###}`"" -f $ods[0].OD) } else { ("{0} OD options" -f @($ods).Count) }
                    $opts += @{ Title = ('ID ' + $g.IDLabel); Subtitle = $sub }
                }
                # trailing "Custom hole OD..." card (user 2026-07-23): type any diameter.
                $opts += @{ Title = 'Custom hole OD...'; Subtitle = 'type any diameter' }
                Add-WizardChoiceCards -Panel $panel -Options $opts -Context $c -Wizard $wiz -Top ($hdrB + 10) -OnPick {
                    param($i,$opt,$cc,$w)
                    Push-TreeHistory -Context $cc   # snapshot the 'id' stage so Back returns here
                    # index-guard: the last card is the custom-OD entry (past the ID groups).
                    if ($i -ge @($cc.Grouped).Count) {
                        $cc.BushCustom = $true; $cc.BushOdFirst = $false; $cc.BushOD = $null; $cc.BushID = $null; $cc.BushOdOptions = $null
                        $cc.BushStage = 'customod'
                        $cc.BushCustomOdText = ''; $cc.BushCustomOdValid = $false; $cc.BushCustomOd = $null; $cc.BushCustomOdLabel = $null
                        return
                    }
                    $cc.BushID = $cc.Grouped[$i]
                    $cc.BushOdOptions = Get-IdOdOptions -IdGroup $cc.BushID
                    $cc.BushStage = 'len'
                    $cc.BushLenIsCustom = $false; $cc.BushLenCustomText = ''; $cc.BushLenValid = $true
                }
                return
            }
            if ($c.BushStage -eq 'customod') {
                # CUSTOM-OD sub-state (user 2026-07-23): inline OD textbox + "Use this OD",
                # mirroring the custom-LENGTH block below (slot-depth pattern, NOT a modal).
                # A BOLD warning makes clear no catalog bushing backs a typed OD, so the
                # operator MUST verify a real drill bushing / sleeve exists. Live-validate via
                # Resolve-CustomOdInput; the commit is gated on BushCustomOdValid. All writes
                # go to $c.* (never a Build-local -- the captured-variable rule).
                $y = (Add-Para $panel "Custom hole OD -- type any diameter (NOT limited to the catalog):" $walkTop 0 $null $true).Bottom + 6
                # Bold warning banner. Use 'yellow' (maps to $warn); 'warn' maps to ink (a latent bug).
                $y = (Add-Para $panel ([char]0x26A0 + " No catalog bushing backs a typed OD. Verify a drill bushing / bushing") $y 0 'yellow' $true).Bottom
                $y = (Add-Para $panel "   sleeve at this OD actually EXISTS before machining." $y 0 'yellow' $true).Bottom + 8
                $lab = New-Object System.Windows.Forms.Label
                $lab.Text = 'Hole OD (in):'; $lab.Location = New-Object System.Drawing.Point(8, ($y + 3)); $lab.Size = New-Object System.Drawing.Size(94, 20)
                $lab.ForeColor = Get-UiColor ''; $lab.BackColor = [System.Drawing.Color]::Transparent
                $panel.Controls.Add($lab)
                $tbOd = New-Object System.Windows.Forms.TextBox
                $tbOd.Location = New-Object System.Drawing.Point(106, $y); $tbOd.Size = New-Object System.Drawing.Size(90, 24)
                $tbOd.Text = [string]$c.BushCustomOdText
                $tbOd.BackColor = [System.Drawing.Color]::FromArgb(16,24,42); $tbOd.ForeColor = Get-UiColor ''; $tbOd.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
                $panel.Controls.Add($tbOd)
                $lblOdEcho = New-Object System.Windows.Forms.Label
                $lblOdEcho.AutoSize = $true; $lblOdEcho.MaximumSize = New-Object System.Drawing.Size(560, 0)
                $lblOdEcho.Location = New-Object System.Drawing.Point(8, ($y + 34)); $lblOdEcho.BackColor = [System.Drawing.Color]::Transparent
                $panel.Controls.Add($lblOdEcho)
                # Precompute echo colors OUTSIDE the closure (Get-UiColor is NOT global -- calling
                # it inside a .GetNewClosure() throws "not recognized"; same rule as the length field).
                $okColOd   = Get-UiColor 'green'
                $warnColOd = Get-UiColor 'yellow'
                $updateOdEcho = {
                    $res = Resolve-CustomOdInput -Text $tbOd.Text
                    $c.BushCustomOdText = [string]$tbOd.Text
                    if ($res.Ok) {
                        $c.BushCustomOd = [double]$res.Value; $c.BushCustomOdLabel = ('{0:0.###}' -f [double]$res.Value); $c.BushCustomOdValid = $true
                        $lblOdEcho.ForeColor = $okColOd
                        $lblOdEcho.Text = ("Hole OD {0:0.###}`" -- press Use this OD." -f [double]$res.Value)
                    } else {
                        $c.BushCustomOdValid = $false
                        $lblOdEcho.ForeColor = $warnColOd
                        $lblOdEcho.Text = $res.Error
                    }
                }.GetNewClosure()
                $tbOd.Add_TextChanged({ param($s,$e) & $updateOdEcho }.GetNewClosure())
                & $updateOdEcho
                $y = $lblOdEcho.Bottom + 12
                $btnUseOd = New-Object System.Windows.Forms.Button
                $btnUseOd.Text = 'Use this OD'
                $btnUseOd.Size = New-Object System.Drawing.Size(140, 30)
                $btnUseOd.Location = New-Object System.Drawing.Point(8, $y)
                $btnUseOd.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
                $btnUseOd.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(120,170,255)
                $btnUseOd.BackColor = [System.Drawing.Color]::FromArgb(54,72,112)
                $btnUseOd.ForeColor = [System.Drawing.Color]::White
                $btnUseOd.Add_Click({
                    $old = $ErrorActionPreference
                    try {
                        $ErrorActionPreference = 'Continue'
                        $res = Resolve-CustomOdInput -Text $tbOd.Text
                        if (-not $res.Ok) { $c.BushCustomOdValid = $false; & $updateOdEcho; try { $wiz.Refresh() } catch {}; return }
                        Push-TreeHistory -Context $c   # snapshot before advancing so Back returns to the OD field
                        $c.BushCustomOd = [double]$res.Value; $c.BushCustomOdLabel = ('{0:0.###}' -f [double]$res.Value)
                        $c.BushStage = 'len'           # proceed to the standard length menu
                        $c.BushLenIsCustom = $false; $c.BushLenCustomText = ''; $c.BushLenValid = $true
                        $wiz.Rerender()
                    } catch { try { $wiz.LogError($_, 'custom OD') } catch {} }
                    finally { $ErrorActionPreference = $old }
                }.GetNewClosure())
                $panel.Controls.Add($btnUseOd)
                return
            }
            if ($c.BushStage -eq 'len') {
                # The length menu serves BOTH the ID-first (sleeve) path and the OD-first
                # (metal removable) path. For OD-first, recommend the length from the OD value
                # and label by OD; for ID-first, from the ID value and label by ID. $bushKind
                # ('ID'/'OD') + $recVal/$recLabel unify the two so the widget code is shared.
                $isOdFirst = [bool]$c.BushOdFirst
                # Recommend-source: custom OD (typed) first, else metal OD-first, else sleeve ID.
                if ($c.BushCustom)  { $id = $null; $bushKind = 'OD'; $recVal = [double]$c.BushCustomOd; $recLabel = [string]$c.BushCustomOdLabel }
                elseif ($isOdFirst) { $id = $c.BushOD; $bushKind = 'OD'; $recVal = [double]$c.BushOD.OD; $recLabel = [string]$c.BushOD.ODLabel }
                else                { $id = $c.BushID; $bushKind = 'ID'; $recVal = [double]$c.BushID.ID; $recLabel = [string]$c.BushID.IDLabel }
                # NB: completion (resolve OD -> tie-break or finish) is INLINED into the
                # fixed-card OnPick and the custom "Use this length" button. It is NOT
                # factored into a Build-local scriptblock: a plain {..} OnPick does NOT
                # capture Build-locals, so a shared local helper would read $null at click
                # time (the documented captured-variable bug). Both paths use only their
                # params + $cc.* fields + GLOBAL helpers (Resolve-BushingPickRow etc.).
                $lenOpt = Get-BushingLengthOptions -Id $recVal
                $preIdx = [int]$lenOpt.PreselectIndex
                if (-not $c.BushLenIsCustom) {
                    # FIXED menu: {1/2, 3/4, 1, Custom...} with the ID/OD recommendation marked.
                    $recTxt = if ($preIdx -ge 0) { ("recommended for {0} {1}" -f $bushKind, $recLabel) } else { '' }
                    $hdrB = (Add-Para $panel ("{0} {1}  ->  select bushing length:" -f $bushKind, $recLabel) $walkTop 0 $null $true).Bottom
                    if ($preIdx -ge 0) { $hdrB = (Add-Para $panel ([char]0x2713 + (" {0}`" is standard for a {1}`" {2} -- recommended." -f $lenOpt.Options[$preIdx].Label, $recLabel, $bushKind)) ($hdrB + 4) 0 'green').Bottom }
                    $opts = @()
                    for ($li = 0; $li -lt @($lenOpt.Options).Count; $li++) {
                        $o = $lenOpt.Options[$li]
                        if ($o.IsCustom) { $opts += @{ Title = 'Custom...'; Subtitle = 'type any length' } }
                        else { $opts += @{ Title = ($o.Label + '" Lg'); Subtitle = $(if ($li -eq $preIdx) { $recTxt } else { '' }) } }
                    }
                    Add-WizardChoiceCards -Panel $panel -Options $opts -Context $c -Wizard $wiz -Top ($hdrB + 10) -CardWidth 190 -CardHeight 90 -HighlightIndex $preIdx -OnPick {
                        param($i,$opt,$cc,$w)
                        Push-TreeHistory -Context $cc   # snapshot the 'len' stage so Back returns here
                        # length menu keys off ID (sleeve) or OD (metal removable) -- same set.
                        $lrv = if ($cc.BushOdFirst) { [double]$cc.BushOD.OD } else { [double]$cc.BushID.ID }
                        $lopt = (Get-BushingLengthOptions -Id $lrv).Options[$i]
                        if ($lopt.IsCustom) {
                            $cc.BushLenIsCustom = $true       # reveal the inline custom field
                            return
                        }
                        # fixed length chosen -> record + resolve (ID-first: OD tie-break; OD-first: finish).
                        [void](Set-BushLengthPick -Context $cc -LenValue ([double]$lopt.Value) -LenLabel ([string]$lopt.Label))
                    }
                    return
                }
                # CUSTOM sub-state: inline textbox + "Use this length" (slot-depth pattern,
                # NOT a modal). Validate live via Resolve-BushingLengthInput; commit gated on
                # BushLenValid. Writes go to $c.* (hashtable fields), never a Build-local.
                $def = if ($preIdx -ge 0) { [double]$lenOpt.Options[$preIdx].Value } else { 0.5 }
                $y = (Add-Para $panel ("{0} {1}  ->  enter a custom bushing length (inches):" -f $bushKind, $recLabel) $walkTop 0 $null $true).Bottom + 8
                $lab = New-Object System.Windows.Forms.Label
                $lab.Text = 'Length (in):'; $lab.Location = New-Object System.Drawing.Point(8, ($y + 3)); $lab.Size = New-Object System.Drawing.Size(90, 20)
                $lab.ForeColor = Get-UiColor ''; $lab.BackColor = [System.Drawing.Color]::Transparent
                $panel.Controls.Add($lab)
                $tb = New-Object System.Windows.Forms.TextBox
                $tb.Location = New-Object System.Drawing.Point(102, $y); $tb.Size = New-Object System.Drawing.Size(90, 24)
                $tb.Text = [string]$c.BushLenCustomText
                $tb.BackColor = [System.Drawing.Color]::FromArgb(16,24,42); $tb.ForeColor = Get-UiColor ''; $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
                $panel.Controls.Add($tb)
                $lblEcho = New-Object System.Windows.Forms.Label
                $lblEcho.AutoSize = $true; $lblEcho.MaximumSize = New-Object System.Drawing.Size(560, 0)
                $lblEcho.Location = New-Object System.Drawing.Point(8, ($y + 34)); $lblEcho.BackColor = [System.Drawing.Color]::Transparent
                $panel.Controls.Add($lblEcho)
                # Precompute the echo colors HERE (the Build body can resolve the script-local
                # Get-UiColor) and CAPTURE them in the closure. Get-UiColor is NOT `function
                # global:`, so calling it INSIDE the .GetNewClosure() below throws "not
                # recognized" (closures see only GLOBAL functions + captured locals -- the same
                # rule that made Resolve-BushingLengthInput global). Mirrors the slot-depth field.
                $okCol   = Get-UiColor 'green'
                $warnCol = Get-UiColor 'warn'
                $updateEcho = {
                    $res = Resolve-BushingLengthInput -Text $tb.Text -Default $def
                    $c.BushLenCustomText = [string]$tb.Text
                    if ($res.Ok) {
                        $c.BushLenValue = [double]$res.Value; $c.BushLenValid = $true
                        $lblEcho.ForeColor = $okCol
                        $lblEcho.Text = ("Length {0:0.###}`" -- press Use this length." -f [double]$res.Value)
                    } else {
                        $c.BushLenValid = $false
                        $lblEcho.ForeColor = $warnCol
                        $lblEcho.Text = $res.Error
                    }
                }.GetNewClosure()
                $tb.Add_TextChanged({ param($s,$e) & $updateEcho }.GetNewClosure())
                & $updateEcho
                $y = $lblEcho.Bottom + 12
                $btnUse = New-Object System.Windows.Forms.Button
                $btnUse.Text = 'Use this length'
                $btnUse.Size = New-Object System.Drawing.Size(140, 30)
                $btnUse.Location = New-Object System.Drawing.Point(8, $y)
                $btnUse.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
                $btnUse.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(120,170,255)
                $btnUse.BackColor = [System.Drawing.Color]::FromArgb(54,72,112)
                $btnUse.ForeColor = [System.Drawing.Color]::White
                $btnUse.Add_Click({
                    $old = $ErrorActionPreference
                    try {
                        $ErrorActionPreference = 'Continue'
                        $res = Resolve-BushingLengthInput -Text $tb.Text -Default $def
                        if (-not $res.Ok) { $c.BushLenValid = $false; & $updateEcho; try { $wiz.Refresh() } catch {}; return }
                        Push-TreeHistory -Context $c   # snapshot before completing so Back returns to the custom field
                        $c.BushLenIsCustom = $false
                        # record + resolve OD (unique->finish, else 'od') via the shared helper.
                        $lv = [double]$res.Value
                        [void](Set-BushLengthPick -Context $c -LenValue $lv -LenLabel ('{0:0.###}' -f $lv))
                        $wiz.Rerender()
                    } catch { try { $wiz.LogError($_, 'bushing custom length') } catch {} }
                    finally { $ErrorActionPreference = $old }
                }.GetNewClosure())
                $panel.Controls.Add($btnUse)
                $btnBackFixed = New-Object System.Windows.Forms.Button
                $btnBackFixed.Text = '< Length options'
                $btnBackFixed.Size = New-Object System.Drawing.Size(140, 30)
                $btnBackFixed.Location = New-Object System.Drawing.Point(156, $y)
                $btnBackFixed.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
                $btnBackFixed.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90,104,132)
                $btnBackFixed.BackColor = if ($script:WizTheme) { $script:WizTheme.CanvasBack } else { [System.Drawing.Color]::FromArgb(30,42,68) }
                $btnBackFixed.ForeColor = Get-UiColor ''
                $btnBackFixed.Add_Click({
                    $old = $ErrorActionPreference
                    try { $ErrorActionPreference = 'Continue'; $c.BushLenIsCustom = $false; $wiz.Rerender() }
                    catch { try { $wiz.LogError($_, 'bushing custom back') } catch {} }
                    finally { $ErrorActionPreference = $old }
                }.GetNewClosure())
                $panel.Controls.Add($btnBackFixed)
                return
            }
            if ($c.BushStage -eq 'od') {
                # TIE-BREAKER: this bore is available at more than one OD. OD IS the drilled
                # jig hole, so the operator picks it (never silently chosen). OD keys on ID
                # alone now, so the header no longer references the length.
                $id = $c.BushID; $ods = @($c.BushOdOptions)
                $hdrB = (Add-Para $panel ("ID {0} is available at more than one OD - OD IS the hole, pick it:" -f $id.IDLabel) $walkTop 0 $null $true).Bottom
                $opts = @()
                foreach ($od in $ods) {
                    $opts += @{ Title = ('OD ' + $od.ODLabel); Subtitle = ("hole {0:0.###}`"" -f $od.OD) }
                }
                Add-WizardChoiceCards -Panel $panel -Options $opts -Context $c -Wizard $wiz -Top ($hdrB + 10) -CardWidth 200 -CardHeight 96 -OnPick {
                    param($i,$opt,$cc,$w)
                    Push-TreeHistory -Context $cc   # snapshot the 'od' stage so Back returns here
                    $pick = Resolve-BushingPickRow -IdGroup $cc.BushID -OdOption (@($cc.BushOdOptions)[$i]) -Length ([double]$cc.BushLenValue) -LenLabel ([string]$cc.BushLenLabel)
                    [void]$cc.Picks.Add([pscustomobject]@{ HoleDiameter=[double]$pick.OD; BushingID=$pick.ID; BushingLength=[double]$pick.Length; Bushing=$pick.EasyName; PartNumber=$pick.PartNumber; Outcome=$cc.TreeNode.label })
                    $cc.PendingSpec = $null; $cc.BushStage = $null; $cc.TreeDone = $true
                }
                return
            }
        }

        # Normal tree descent.
        if ($null -eq $node) { $c.TreeDone = $true; Add-Para $panel "Tree finished." ; return }
        switch ($node.kind) {
            'question' {
                $kids = @($node.children)
                $qB = (Add-Para $panel ([string]$node.label) $walkTop 0 $null $true).Bottom + 6
                if ($node.notes) { $qB = (Add-Para $panel ([string]$node.notes) $qB 0 'Gray').Bottom + 6 }
                $opts = @()
                foreach ($k in $kids) { $opts += @{ Title = [string]$k.label; Subtitle = '' } }
                Add-WizardChoiceCards -Panel $panel -Options $opts -Context $c -Wizard $wiz -Top ($qB + 6) -OnPick {
                    param($i,$opt,$cc,$w)
                    Push-TreeHistory -Context $cc   # snapshot this question so Back returns to it
                    $chosen = @($cc.TreeNode.children)[$i]
                    [void]$cc.Path.Add([string]$chosen.label)
                    # descend: an 'option' carries a single child to continue into.
                    $next = $chosen
                    while ($next.kind -eq 'option' -and @($next.children).Count -ge 1) { $next = @($next.children)[0] }
                    $cc.TreeNode = $next
                    # if we've reached an outcome, resolve it now. A metal removable-bushing
                    # (OD-filtered) spec starts the OD-first sub-flow ('od1', no ID question);
                    # a 3D-print sleeve (ID-filtered) spec starts the ID-first sub-flow ('id').
                    if ($next.kind -eq 'outcome') {
                        $spec = Get-CatalogSpec -Label $next.label
                        if ($spec) {
                            $cc.PendingSpec = $spec
                            if (Test-OdFirstSpec -Spec $spec) { $cc.BushOdFirst = $true;  $cc.BushStage = 'od1' }
                            else                              { $cc.BushOdFirst = $false; $cc.BushStage = 'id' }
                        }
                        else {
                            $fixed = Get-FixedOdSpec -Label $next.label
                            if ($null -ne $fixed) {
                                [void]$cc.Picks.Add([pscustomobject]@{ HoleDiameter=[double]$fixed; BushingLength=$null; Bushing='(fixed OD, no bushing)'; PartNumber='(n/a)'; Outcome=$next.label })
                            }
                            $cc.TreeDone = $true
                        }
                    }
                }
                return
            }
            'outcome' {
                $spec = Get-CatalogSpec -Label $node.label
                if ($spec) {
                    $c.PendingSpec = $spec
                    if (Test-OdFirstSpec -Spec $spec) { $c.BushOdFirst = $true;  $c.BushStage = 'od1' }
                    else                              { $c.BushOdFirst = $false; $c.BushStage = 'id' }
                    $wiz.Rerender(); return
                }
                $fixed = Get-FixedOdSpec -Label $node.label
                if ($null -ne $fixed) {
                    [void]$c.Picks.Add([pscustomobject]@{ HoleDiameter=[double]$fixed; BushingLength=$null; Bushing='(fixed OD, no bushing)'; PartNumber='(n/a)'; Outcome=$node.label })
                }
                Add-Para $panel ([string]$node.label) 4 60
                $c.TreeDone = $true
                return
            }
            default {
                # option/bushing/pattern wrapper: skip into its first child
                $kids = @($node.children)
                if ($kids.Count -ge 1) { $c.TreeNode = $kids[0]; $wiz.Rerender(); return }
                $c.TreeDone = $true
            }
        }
    } `
    -OnNext {
        param($c, $wiz)
        # PRESS-NEXT-TO-TAKE-THE-RECOMMENDATION (user 2026-07-21): if we're still at the
        # LENGTH stage (not TreeDone), Next commits the recommended (or the entered custom)
        # length -- exactly as clicking the recommended card would -- then RE-RENDERS in
        # place (return $false = don't advance). So spamming Next walks the recommendation
        # through: pick ID -> Next takes the recommended length -> (unique OD) confirmation
        # -> Next advances the wizard. A >1-OD tie-break is NOT auto-committed (Set-BushLengthPick
        # routes it to 'od'); the operator picks the OD, since OD is the drilled hole.
        $lenReady = ($null -ne $c.PendingSpec -and $c.BushStage -eq 'len' -and
                     (($c.BushCustom -and $null -ne $c.BushCustomOd) -or ($c.BushOdFirst -and $null -ne $c.BushOD) -or (-not $c.BushOdFirst -and $null -ne $c.BushID)))
        if (-not $c.TreeDone -and $lenReady) {
            Push-TreeHistory -Context $c
            if ($c.BushLenIsCustom) {
                $res = Resolve-BushingLengthInput -Text $c.BushLenCustomText -Default 0.5
                if (-not $res.Ok) { return $false }   # invalid custom entry -> stay put
                $c.BushLenIsCustom = $false
                [void](Set-BushLengthPick -Context $c -LenValue ([double]$res.Value) -LenLabel ('{0:0.###}' -f [double]$res.Value))
            } else {
                # recommend from the custom OD (typed), else metal OD, else sleeve ID
                $lrv = if ($c.BushCustom) { [double]$c.BushCustomOd } elseif ($c.BushOdFirst) { [double]$c.BushOD.OD } else { [double]$c.BushID.ID }
                $lenOpt = Get-BushingLengthOptions -Id $lrv
                $pre = [int]$lenOpt.PreselectIndex
                if ($pre -lt 0) { return $false }      # no recommendation -> require a click
                $lopt = $lenOpt.Options[$pre]
                [void](Set-BushLengthPick -Context $c -LenValue ([double]$lopt.Value) -LenLabel ([string]$lopt.Label))
            }
            $wiz.Rerender()
            return $false   # stay on the tree step (now showing the confirmation or the OD tie-break)
        }
        # finalise STAGE-1 results into the shared vars (last pick wins)
        if ($c.Picks.Count -gt 0) {
            $active = $c.Picks[$c.Picks.Count - 1]
            $c.HoleDia = [double]$active.HoleDiameter
            if ($null -ne $active.BushingLength) { $c.BushingLen = [double]$active.BushingLength }
        }
        $c.Is3dPrint = @($c.Path | Where-Object { $_ -match '(?i)3d\s*print' }).Count -gt 0
        # chips
        if ($null -ne $c.HoleDia) { $wiz.SetChip('hole', ("hole {0:0.###}`"" -f $c.HoleDia), 'set') }
        if ($null -ne $c.BushingLen) { $wiz.SetChip('depth', ("depth {0:0.###}`"" -f $c.BushingLen), 'set') }
        return $true
    }
[void]$steps.Add($treeStep)

# ---- STAGE: Bushing -- HOLE-TO-EDGE MARGIN (optional smaller wall) --------------
# Asked RIGHT AFTER the bushing decision tree and BEFORE the slot-depth step (user
# 2026-07-23). The edge margin is the wall from a BORDER hole's EDGE to the part edge.
# The standard/default wall is one full hole DIAMETER (the 2026-07-21 rule); this step
# lets the operator dial a SMALLER wall so the border holes sit closer to the edge and
# the plate shrinks (a tight-job option). The value lands in $c.EdgeMargin (a CONTEXT
# field, mutable across steps) which every layout site reads via Get-EffectiveEdgeMargin
# ($null -> default = hole dia). Same 'Bushing' stage as the tree/slot-depth, so the
# breadcrumb gains no new pill. Mirrors the slot-depth step's shape (cards + editable
# field + Change + BoxBuilt guard). The custom field is live-validated by the GLOBAL
# Resolve-EdgeMarginInput (a closure can only resolve global functions -- the "textbox
# error that pops up" if it were script-scope).
$edgeMarginStep = New-WizardStep -Key 'edge-margin' -Title 'Hole-to-edge margin' -Stage 'Bushing' -Kind 'choice' -PrimaryText 'Next' `
    -Validate {
        param($c)
        # Build auto-sets a mode for the dia-unknown case, so Next only needs a mode; the
        # custom branch additionally needs a valid (>= 0) entered wall.
        if ($null -eq $c.EdgeMarginMode) { return $false }
        if ($c.EdgeMarginMode -eq 'custom') { return [bool]$c.EdgeMarginValid }
        return $true
    } `
    -Build {
        param($panel, $c, $wiz)
        $hd = if ($null -ne $c.HoleDia -and [double]$c.HoleDia -gt 0) { [double]$c.HoleDia } else { 0.0 }

        # BOX ALREADY BUILT (operator jumped back via the breadcrumb): the plate was sized
        # with the edge margin at layout time, so re-editing here can NOT resize the
        # committed plate (it would only desync the display). Say so; do NOT offer editing.
        # Validate still passes because a mode was chosen on the first pass. Clear any stale
        # invalid flag so a leftover EdgeMarginValid=$false can't dead-end Next.
        if ($c.BoxBuilt) {
            $c.EdgeMarginValid = $true
            $shown = if ($null -ne $c.EdgeMargin) { [double]$c.EdgeMargin } elseif ($hd -gt 0) { $hd } else { 0.0 }
            Add-Para $panel ([char]0x2713 + (" The plate is already built with edge margin {0:0.###}`". Re-editing here will NOT resize the committed plate -- re-run the tool to change it. Press Next." -f $shown)) 8 0 'warn' $true
            $wiz.SetChip('edgemargin', ("edge {0:0.###}`" (built)" -f $shown), 'set')
            return
        }

        # Hole dia not known yet (e.g. jumped back before the tree resolved it): can't
        # default to a diameter, so leave EdgeMargin unset (layout falls back to the legacy
        # one-radius rule) and pass through. Auto-set a mode so Validate/Next work.
        if ($hd -le 0) {
            if ($null -eq $c.EdgeMarginMode) { $c.EdgeMarginMode = 'standard'; $c.EdgeMargin = $null }
            Add-Para $panel "The hole diameter is not known yet, so the edge margin uses the default (one hole radius). Press Next." 8 0 'gray'
            return
        }

        $thm = $script:WizTheme
        # NOT DECIDED yet -> two cards: Standard (one diameter) vs Smaller (own wall).
        if ($null -eq $c.EdgeMarginMode) {
            $y = (Add-Para $panel "Hole-to-edge margin (wall from a border hole's edge to the part edge):" 8 0 $null $true).Bottom + 6
            $y = (Add-Para $panel ("The standard margin is one full hole diameter ({0:0.###}"") on every side. For a tight part you can choose a SMALLER wall -- the border holes sit closer to the part edge, shrinking the plate. 0"" puts a border hole edge right on the part edge (tangent)." -f $hd) $y 0 'gray').Bottom + 12
            $stdSub = ("Wall = one hole diameter ({0:0.###}"")." -f $hd)
            $opts = @(
                @{ Title = 'Standard margin'; Subtitle = $stdSub },
                @{ Title = 'Smaller margin';  Subtitle = 'Enter my own (smaller) hole-to-edge wall.' }
            )
            Add-WizardChoiceCards -Panel $panel -Options $opts -Context $c -Wizard $wiz -Top ($y + 4) -CardWidth 250 -CardHeight 86 -AfterPick 'rerender' -OnPick {
                param($i, $opt, $cc, $w)
                if ($i -eq 0) {
                    $cc.EdgeMarginMode = 'standard'; $cc.EdgeMargin = $null; $cc.EdgeMarginValid = $true
                    $w.SetChip('edgemargin', 'edge = dia', 'set')
                } else {
                    $cc.EdgeMarginMode = 'custom'
                    # seed at a radius (half the hole dia) -- a sensible smaller wall -- when
                    # nothing is set yet, so the default custom layout is valid out of the box.
                    if ($null -eq $cc.EdgeMargin) { $cc.EdgeMargin = [math]::Round(([double]$cc.HoleDia) / 2.0, 4) }
                    $cc.EdgeMarginValid = ([double]$cc.EdgeMargin -ge 0)
                    $w.SetChip('edgemargin', ('edge {0:0.###}"' -f [double]$cc.EdgeMargin), 'set')
                }
            }
            return
        }
        # DECIDED. A "Change" button re-picks (interwoven navigation).
        if ($c.EdgeMarginMode -eq 'standard') {
            $y = (Add-Para $panel ([char]0x2713 + (" Standard margin: one hole diameter ({0:0.###}"") of wall on every side." -f $hd)) 8 0 'green' $true).Bottom + 10
            $c.EdgeMargin = $null
            $wiz.SetChip('edgemargin', 'edge = dia', 'set')
        } else {
            # SMALLER: an editable wall field, live-validated via Resolve-EdgeMarginInput.
            $y = (Add-Para $panel ("Smaller margin -- enter the hole-to-edge wall (inches). Standard is one diameter ({0:0.###}""); a smaller wall shrinks the plate. 0 = tangent to the edge." -f $hd) 8 0 $null $true).Bottom + 8
            $lab = New-Object System.Windows.Forms.Label
            $lab.Text = 'Edge margin (in):'; $lab.Location = New-Object System.Drawing.Point(8, ($y + 3)); $lab.Size = New-Object System.Drawing.Size(120, 20)
            $lab.ForeColor = Get-UiColor ''; $lab.BackColor = [System.Drawing.Color]::Transparent
            $panel.Controls.Add($lab)
            $tb = New-Object System.Windows.Forms.TextBox
            $tb.Location = New-Object System.Drawing.Point(132, $y); $tb.Size = New-Object System.Drawing.Size(90, 24)
            $defWall = [math]::Round($hd / 2.0, 4)
            $tb.Text = if ($null -ne $c.EdgeMargin) { [string]$c.EdgeMargin } else { [string]$defWall }
            $tb.BackColor = [System.Drawing.Color]::FromArgb(16,24,42); $tb.ForeColor = Get-UiColor ''; $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
            $panel.Controls.Add($tb)
            $lblEcho = New-Object System.Windows.Forms.Label
            $lblEcho.AutoSize = $true; $lblEcho.MaximumSize = New-Object System.Drawing.Size(560, 0)
            $lblEcho.Location = New-Object System.Drawing.Point(8, ($y + 34)); $lblEcho.BackColor = [System.Drawing.Color]::Transparent
            $panel.Controls.Add($lblEcho)
            # Precompute echo colors HERE (Build body resolves script-local functions) and
            # CAPTURE them in the closure -- Get-UiColor is NOT global, so calling it inside
            # the .GetNewClosure() below would throw "not recognized" (the closure-only-sees-
            # global-functions rule; Resolve-EdgeMarginInput IS global, so it is safe there).
            $okCol   = Get-UiColor 'green'
            $warnCol = Get-UiColor 'warn'
            $stdWall = $hd
            $updateEcho = {
                $res = Resolve-EdgeMarginInput -Text $tb.Text -Default ([double]$c.EdgeMargin)
                if ($res.Ok) {
                    $c.EdgeMargin = [double]$res.Value; $c.EdgeMarginValid = $true
                    $delta = if ($res.Value -lt $stdWall) { (" ({0:0.###}"" less wall than standard per side)" -f ($stdWall - $res.Value)) } elseif ($res.Value -gt $stdWall) { ' (larger than the standard wall)' } else { ' (= the standard wall)' }
                    $lblEcho.ForeColor = $okCol
                    $lblEcho.Text = ("Edge margin {0:0.###}`"{1}" -f [double]$c.EdgeMargin, $delta)
                    $wiz.SetChip('edgemargin', ('edge {0:0.###}"' -f [double]$c.EdgeMargin), 'set')
                } else {
                    $c.EdgeMarginValid = $false
                    $lblEcho.ForeColor = $warnCol
                    $lblEcho.Text = $res.Error
                }
                try { $wiz.Refresh() } catch {}
            }.GetNewClosure()
            $tb.Add_TextChanged({ param($s,$e) & $updateEcho }.GetNewClosure())
            & $updateEcho
            $y = $lblEcho.Bottom + 12
        }
        # Change button (re-pick standard vs smaller).
        $btnChange = New-Object System.Windows.Forms.Button
        $btnChange.Text = 'Change'
        $btnChange.Size = New-Object System.Drawing.Size(120, 30)
        $btnChange.Location = New-Object System.Drawing.Point(8, $y)
        $btnChange.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnChange.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90,104,132)
        $btnChange.BackColor = if ($thm) { $thm.CanvasBack } else { [System.Drawing.Color]::FromArgb(30,42,68) }
        $btnChange.ForeColor = Get-UiColor ''
        $btnChange.Add_Click({
            $old = $ErrorActionPreference
            try { $ErrorActionPreference = 'Continue'; $c.EdgeMarginMode = $null; $wiz.Rerender() }
            catch { try { $wiz.LogError($_, 'edge-margin change') } catch {} }
            finally { $ErrorActionPreference = $old }
        }.GetNewClosure())
        $panel.Controls.Add($btnChange)
    } `
    -OnNext {
        param($c, $wiz)
        $wall = if ($null -ne $c.EdgeMargin) { [double]$c.EdgeMargin } elseif ($null -ne $c.HoleDia -and [double]$c.HoleDia -gt 0) { [double]$c.HoleDia } else { $null }
        $desc = if ($c.EdgeMarginMode -eq 'custom') { 'smaller/custom' } else { 'standard (one hole diameter)' }
        if ($null -ne $wall) { $wiz.Log(("Hole-to-edge margin = {0:0.###}`" ({1}). Every border hole keeps this wall to the part edge." -f $wall, $desc)) }
        else { $wiz.Log("Hole-to-edge margin = default (one hole radius; hole dia not known yet).") }
        return $true
    }
[void]$steps.Add($edgeMarginStep)

# ---- STAGE: Bushing -- SLOT / GUIDE DEPTH (tight/restricted space) --------------
# Asked RIGHT AFTER the bushing decision tree (user 2026-07-21). The chip-relief
# slot depth doubles as the plate EXTRUDE PAD: plate = bushing length + slot depth,
# the slot removes the slot depth, so the FINAL guide depth == bushing length for any
# positive depth -> a SMALLER slot depth = a THINNER overall plate (a tight/restricted
# space). Two cards: "Standard clearance" (0.25") or "Tight / restricted space" (the
# operator types their own, usually smaller, depth). The value lands in $c.SlotDepth
# (a CONTEXT field, mutable across steps) which box-a's pad + slot-a's cut read -- a
# top-level $SLOT_DEPTH_ABS write from inside a step block would not propagate.
# Same 'Bushing' stage as the tree, so the breadcrumb gains no new pill.
$slotDepthStep = New-WizardStep -Key 'slot-depth' -Title 'Chip-relief slot depth' -Stage 'Bushing' -Kind 'choice' -PrimaryText 'Next' `
    -Validate {
        param($c)
        # Build auto-sets a mode for the flag/no-relief cases, so Next only needs a mode;
        # the tight branch additionally needs a valid (>0) entered depth.
        if ($null -eq $c.SlotSpaceMode) { return $false }
        if ($c.SlotSpaceMode -eq 'tight') { return [bool]$c.SlotDepthValid }
        return $true
    } `
    -Build {
        param($panel, $c, $wiz)
        # BOX ALREADY BUILT (operator jumped back here via the breadcrumb): the plate was
        # extruded to bushingLen + the pad ($c.ReliefPad) that was frozen at box-build time,
        # and the slot cut uses that SAME frozen pad -- so re-editing the slot depth here can
        # NOT resize the committed plate (it would only desync the display). Say so, and do
        # NOT offer editing; Validate still passes because a mode was chosen on the first pass.
        if ($c.BoxBuilt) {
            # Clear any stale invalid-entry flag: the plate is committed and this branch shows
            # no editable field, so a leftover SlotDepthValid=$false (from a prior tight-mode
            # typo before the jump-back) would leave Validate returning false with NO way to fix
            # it -> a dead-end Next. The committed pad is authoritative here, so the depth IS valid.
            $c.SlotDepthValid = $true
            $builtDepth = if ([double]$c.ReliefPad -gt 0) { [double]$c.ReliefPad } else { [double]$c.SlotDepth }
            Add-Para $panel ([char]0x2713 + (" The plate is already built with slot depth {0}`". Re-editing here will NOT resize the committed plate -- re-run the tool to change the plate thickness. Press Next." -f $builtDepth)) 8 0 'warn' $true
            $wiz.SetChip('slotdepth', ("slot {0:0.###}`" (built)" -f $builtDepth), 'set')
            return
        }
        # --slot-depth on the command line pins the depth -> no question, just confirm.
        if ($c.SlotDepthFromFlag) {
            if ($null -eq $c.SlotSpaceMode) { $c.SlotSpaceMode = 'flag' }
            $ex = if ($null -ne $c.BushingLen) { (" Overall plate extrude = {0:0.###}`" (bushing {1:0.###}`" + {2:0.###}`")." -f ([double]$c.BushingLen + [double]$c.SlotDepth), [double]$c.BushingLen, [double]$c.SlotDepth) } else { '' }
            Add-Para $panel ("Slot depth = {0}`" (from --slot-depth).{1} Press Next." -f [double]$c.SlotDepth, $ex) 8 0 'gray'
            $wiz.SetChip('slotdepth', ("slot {0:0.###}`"" -f [double]$c.SlotDepth), 'set')
            return
        }
        # --no-slot-relief: the slot depth is never used (no slots, no pad). Note + skip.
        if ($noSlotRelief) {
            if ($null -eq $c.SlotSpaceMode) { $c.SlotSpaceMode = 'standard'; $c.SlotDepth = 0.25 }
            Add-Para $panel "Chip-relief slots are disabled (--no-slot-relief), so the slot depth is not used. Press Next." 8 0 'gray'
            return
        }
        $thm = $script:WizTheme
        # NOT DECIDED yet -> two cards: Standard clearance vs Tight/restricted space.
        if ($null -eq $c.SlotSpaceMode) {
            $y = (Add-Para $panel "Are you working in a tight / restricted space?" 8 0 $null $true).Bottom + 6
            $y = (Add-Para $panel ("The chip-relief slot is cut into the plate; the plate is extruded to (bushing length + slot depth), and the slot removes the slot depth -- so the FINAL guide depth equals the bushing length no matter what depth you pick. A SMALLER slot depth just makes a THINNER overall plate, which is what a tight/restricted space needs.") $y 0 'gray').Bottom + 12
            $stdSub = 'Slot depth 0.25" (default).'
            if ($null -ne $c.BushingLen) { $stdSub += (" Plate extrude = {0:0.###}"" (bushing {1:0.###}"" + 0.25"")." -f ([double]$c.BushingLen + 0.25), [double]$c.BushingLen) }
            $opts = @(
                @{ Title = 'Standard clearance'; Subtitle = $stdSub },
                @{ Title = 'Tight / restricted space'; Subtitle = 'Enter my own (usually smaller) slot depth.' }
            )
            Add-WizardChoiceCards -Panel $panel -Options $opts -Context $c -Wizard $wiz -Top ($y + 4) -CardWidth 250 -CardHeight 86 -AfterPick 'rerender' -OnPick {
                param($i, $opt, $cc, $w)
                if ($i -eq 0) {
                    $cc.SlotSpaceMode = 'standard'; $cc.SlotDepth = 0.25; $cc.SlotDepthValid = $true
                    $w.SetChip('slotdepth', 'slot 0.25"', 'set')
                } else {
                    $cc.SlotSpaceMode = 'tight'; $cc.SlotDepthValid = ([double]$cc.SlotDepth -gt 0)
                    $w.SetChip('slotdepth', ('slot {0:0.###}"' -f [double]$cc.SlotDepth), 'set')
                }
            }
            return
        }
        # DECIDED. A "Change" button resets the choice (interwoven navigation).
        if ($c.SlotSpaceMode -eq 'standard') {
            $y = (Add-Para $panel ([char]0x2713 + " Standard clearance: chip-relief slot depth 0.25`".") 8 0 'green' $true).Bottom + 6
            if ($null -ne $c.BushingLen) { $y = (Add-Para $panel ("Overall plate extrude = {0:0.###}`" (bushing {1:0.###}`" + 0.25`")." -f ([double]$c.BushingLen + 0.25), [double]$c.BushingLen) $y 0 'gray').Bottom + 10 }
            else { $y = (Add-Para $panel "Overall plate extrude = bushing length + 0.25`"." $y 0 'gray').Bottom + 10 }
            $wiz.SetChip('slotdepth', 'slot 0.25"', 'set')
        } else {
            # TIGHT: an editable depth field, live-validated via Resolve-SlotDepthInput.
            $y = (Add-Para $panel "Tight / restricted space -- enter your chip-relief slot depth (inches):" 8 0 $null $true).Bottom + 8
            $lab = New-Object System.Windows.Forms.Label
            $lab.Text = 'Slot depth (in):'; $lab.Location = New-Object System.Drawing.Point(8, ($y + 3)); $lab.Size = New-Object System.Drawing.Size(120, 20)
            $lab.ForeColor = Get-UiColor ''; $lab.BackColor = [System.Drawing.Color]::Transparent
            $panel.Controls.Add($lab)
            $tb = New-Object System.Windows.Forms.TextBox
            $tb.Location = New-Object System.Drawing.Point(132, $y); $tb.Size = New-Object System.Drawing.Size(90, 24)
            $tb.Text = [string]$c.SlotDepth
            $tb.BackColor = [System.Drawing.Color]::FromArgb(16,24,42); $tb.ForeColor = Get-UiColor ''; $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
            $panel.Controls.Add($tb)
            $lblEcho = New-Object System.Windows.Forms.Label
            $lblEcho.AutoSize = $true; $lblEcho.MaximumSize = New-Object System.Drawing.Size(560, 0)
            $lblEcho.Location = New-Object System.Drawing.Point(8, ($y + 34)); $lblEcho.BackColor = [System.Drawing.Color]::Transparent
            $panel.Controls.Add($lblEcho)
            # Precompute the echo colors HERE (Build body resolves script-local functions)
            # and CAPTURE them in the closure. Get-UiColor is NOT `function global:`, so
            # calling it from inside the .GetNewClosure() below would throw "not recognized"
            # (same closure-only-sees-global-functions rule that made Resolve-SlotDepthInput
            # global). Resolve-SlotDepthInput IS global, so it is safe to call in the closure.
            $okCol   = Get-UiColor 'green'
            $warnCol = Get-UiColor 'warn'
            $updateEcho = {
                $res = Resolve-SlotDepthInput -Text $tb.Text -Default ([double]$c.SlotDepth)
                if ($res.Ok) {
                    $c.SlotDepth = [double]$res.Value; $c.SlotDepthValid = $true
                    $ex = if ($null -ne $c.BushingLen) { (" -> plate extrude = {0:0.###}`" (bushing {1:0.###}`" + {2:0.###}`")." -f ([double]$c.BushingLen + [double]$c.SlotDepth), [double]$c.BushingLen, [double]$c.SlotDepth) } else { '.' }
                    $lblEcho.ForeColor = $okCol
                    $lblEcho.Text = ("Slot depth {0:0.###}`"{1}" -f [double]$c.SlotDepth, $ex)
                    $wiz.SetChip('slotdepth', ('slot {0:0.###}"' -f [double]$c.SlotDepth), 'set')
                } else {
                    $c.SlotDepthValid = $false
                    $lblEcho.ForeColor = $warnCol
                    $lblEcho.Text = $res.Error
                }
                try { $wiz.Refresh() } catch {}
            }.GetNewClosure()
            $tb.Add_TextChanged({ param($s,$e) & $updateEcho }.GetNewClosure())
            & $updateEcho
            $y = $lblEcho.Bottom + 12
        }
        # Change button (re-pick standard vs tight).
        $btnChange = New-Object System.Windows.Forms.Button
        $btnChange.Text = 'Change'
        $btnChange.Size = New-Object System.Drawing.Size(120, 30)
        $btnChange.Location = New-Object System.Drawing.Point(8, $y)
        $btnChange.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnChange.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90,104,132)
        $btnChange.BackColor = if ($thm) { $thm.CanvasBack } else { [System.Drawing.Color]::FromArgb(30,42,68) }
        $btnChange.ForeColor = Get-UiColor ''
        $btnChange.Add_Click({
            $old = $ErrorActionPreference
            try { $ErrorActionPreference = 'Continue'; $c.SlotSpaceMode = $null; $wiz.Rerender() }
            catch { try { $wiz.LogError($_, 'slot-depth change') } catch {} }
            finally { $ErrorActionPreference = $old }
        }.GetNewClosure())
        $panel.Controls.Add($btnChange)
    } `
    -OnNext {
        param($c, $wiz)
        $wiz.Log(("Chip-relief slot depth = {0}`" ({1}). Plate will be extruded to bushing length + this value when relief is added." -f [double]$c.SlotDepth, $(if ($c.SlotSpaceMode -eq 'tight') { 'tight/restricted space' } elseif ($c.SlotSpaceMode -eq 'flag') { '--slot-depth' } else { 'standard' })))
        return $true
    }
[void]$steps.Add($slotDepthStep)

# ---- STAGE: Layout -- point-source choice; BOTH editors EMBEDDED in-window ------
# Renders mode-based: no mode chosen -> three tiles. Orthogrid -> the inline grid
# editor (Add-InlineOrthogrid); Custom -> the inline points editor
# (Add-InlineCustomPoints) - BOTH right in the canvas, NO popup window. A "Change
# layout type" button returns to the tiles. LayoutMode ('orthogrid'|'custom'|$null)
# tracks which view is showing.
$layoutStep = New-WizardStep -Key 'layout' -Title 'How are the hole points defined?' -Stage 'Layout' -Kind 'choice' -PrimaryText 'Next' `
    -Validate {
        param($c)
        # orthogrid/custom/fastener require a valid layout; predefined is ready once chosen.
        if ($c.PointMode -eq 'orthogrid' -or $c.PointMode -eq 'custom' -or $c.PointMode -eq 'fastener') { return [bool]$c.OrthoValid }
        # predefined (picked) OR the BARE tiles (nothing clicked): Next is ENABLED.
        # On the bare tiles it activates the RECOMMENDED default (Fastener-Driven Model)
        # via OnNext, so the green-highlighted card and the Next button agree (user 2026-07-22).
        return $true
    } `
    -Build {
        param($panel, $c, $wiz)

        # AUTO-APPLY the up-front fastener import (Import stage captured raw {X;Z} pts):
        # now that the hole dia is known, build the plate around the holes at that dia
        # (Set-LayoutMargin re-anchor + Get-CustomPointsGeometry) and skip the tiles.
        # Re-anchor the near corner to 1.5x the hole dia (bore radius + one-diameter wall)
        # and pass -EdgeMargin = the hole dia so every border wall is one full diameter.
        if ($null -ne $c.FastenerRawPoints -and @($c.FastenerRawPoints).Count -gt 0 -and $c.LayoutMode -ne 'orthogrid' -and $c.LayoutMode -ne 'custom') {
            $hd = if ($null -ne $c.HoleDia -and [double]$c.HoleDia -gt 0) { [double]$c.HoleDia } else { 0.25 }
            # EDGE MARGIN = the chosen wall (default one hole dia, or a smaller wall from the
            # edge-margin step). Re-anchor the near corner so the nearest hole CENTER sits a
            # bore radius + the wall in from the corner (pure translation, pattern unchanged);
            # pass -EdgeMargin = the same wall so the derived far edge + the check agree.
            $wallReq = Get-EffectiveEdgeMargin -ChosenMargin $c.EdgeMargin -HoleDia $hd
            $pts = $c.FastenerRawPoints
            try { $ra = Set-LayoutMargin -Points $pts -Margin ((0.5 * $hd) + $wallReq); if ($ra.Valid) { $pts = $ra.Points } } catch {}
            $geo = $null
            try { $geo = Get-CustomPointsGeometry -Points $pts -ClearDia $hd -HoleDia $hd -EdgeMargin $wallReq } catch { $geo = $null }
            if ($null -ne $geo -and $geo.Valid) {
                $c.OrthoGeo = $geo; $c.OrthoValid = $true; $c.PointMode = 'fastener'; $c.LayoutPicked = $true
                $y = 8
                $y = (Add-Para $panel "Fastener layout (imported first) applied to the plate." $y 0 'gray').Bottom + 6
                $y = (Add-Para $panel (("{0} hole(s), plate {1:0.00} x {2:0.00}. The pattern is fixed; the plate is sized around it at the {3}"" hole. Press Next." -f $geo.Count, $geo.Width, $geo.Height, $hd)) $y 0 'DarkGreen' $true).Bottom + 10
                $wiz.SetChip('layout', ("layout: fastener ({0})" -f $geo.Count), 'set')
                # SLOT DIRECTION (user 2026-07-23): X/Z toggle ABOVE the preview so the
                # operator sees which way the chip-relief slots run in the image below.
                Add-SlotDirToggle -Panel $panel -Context $c -Wizard $wiz -Top $y | Out-Null
                $y = (Get-StackTop $panel 6)
                # PREVIEW IMAGE (user 2026-07-21: the fastener layout should show how it looks,
                # like the orthogrid/custom editors) -- the same numbered dot preview the index
                # step uses, rendering $c.OrthoGeo (plate + to-scale holes + relief bands in the
                # chosen slot direction).
                [void](Add-LayoutPreview -Panel $panel -Context $c -Top $y -Left 8 -Width 320 -Height 172)
                $y = (Get-StackTop $panel 8)
                $btnRedo = New-Object System.Windows.Forms.Button
                $btnRedo.Text = 'Use a different layout'
                $btnRedo.Size = New-Object System.Drawing.Size(180, 30)
                $btnRedo.Location = New-Object System.Drawing.Point(8, $y)
                $btnRedo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
                $btnRedo.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90,104,132)
                $btnRedo.BackColor = if ($script:WizTheme) { $script:WizTheme.CanvasBack } else { [System.Drawing.Color]::FromArgb(30,42,68) }
                $btnRedo.ForeColor = Get-UiColor ''
                $btnRedo.Add_Click({ $c.FastenerRawPoints = $null; $c.OrthoGeo = $null; $c.OrthoValid = $false; $c.PointMode='predefined'; $c.LayoutPicked=$false; $c.LayoutMode=$null; $wiz.Rerender() }.GetNewClosure())
                $panel.Controls.Add($btnRedo)
                return
            } else {
                Add-Para $panel "The imported fastener layout did not form a valid plate; pick a layout below." 4 40 'goldenrod' $true
                # RESET the layout state fully to the bare-tiles baseline. Clearing ONLY
                # FastenerRawPoints left PointMode='fastener' with OrthoValid=$false, so the
                # layout Validate (PointMode in orthogrid/custom/fastener -> return OrthoValid)
                # kept Next DISABLED while the tiles were showing, AND OnNext's tile-commit
                # branch (requires PointMode 'predefined') could not fire -> the Next button
                # "bugged out" and clicking a tile did nothing (user 2026-07-23). Fall back to
                # the tiles invariant (predefined + no layout + no committed mode) so Next
                # gates on the tiles and OnNext commits the picked tile normally.
                $c.FastenerRawPoints = $null
                $c.PointMode   = 'predefined'
                $c.LayoutMode  = $null
                $c.OrthoGeo    = $null
                $c.OrthoValid  = $false
                $c.LayoutPicked = $false
            }
        }

        # VIEW 3: import a fastener layout from fastener_layout.json (file-only in the
        # GUI - the risky live read stays in fastenator.cmd so $ctx.Model is never
        # rebound to a fastener model). Loads the file, validates via the same
        # Get-CustomPointsGeometry the custom mode uses, and gates Next on OrthoValid.
        if ($c.LayoutMode -eq 'fastener') {
            $y = Get-StackTop $panel 8
            $y = (Add-Para $panel "Import fastener layout - load positions captured from a fastener part." $y 0 'gray').Bottom + 8
            $layoutFile = Join-Path $ScriptDir 'fastener_layout.json'
            $holeDiaLoc = if ($null -ne $c.HoleDia -and [double]$c.HoleDia -gt 0) { [double]$c.HoleDia } else { 0.25 }
            $peek = Read-FastenerLayout -Path $layoutFile
            if (-not $peek.Valid) {
                $y = (Add-Para $panel ("No fastener_layout.json yet. Click ""Read fasteners live now"" below to scan an open fastener model right here, OR run fastenator.cmd separately to create the file.") $y 0 'goldenrod' $true).Bottom + 10
                $c.OrthoValid = $false
            } else {
                # BUILD THE PLATE AROUND THE HOLES: the imported layout was bordered for
                # the FASTENER size; re-anchor the near corner so the nearest hole CENTER
                # sits 1.5x the (larger) JIG hole dia in from the corner (bore radius + one-
                # diameter wall), so the border WALL is one full hole diameter (user
                # 2026-07-21) and Get-CustomPointsGeometry's edge-margin check passes. Pure
                # translation -> the drilled pattern is unchanged.
                # EDGE MARGIN = the chosen wall (default one hole dia, or a smaller wall from
                # the edge-margin step); re-anchor to a bore radius + that wall.
                $wallReqLoc = Get-EffectiveEdgeMargin -ChosenMargin $c.EdgeMargin -HoleDia $holeDiaLoc
                $impPts = $peek.Points
                try { $ra = Set-LayoutMargin -Points $peek.Points -Margin ((0.5 * $holeDiaLoc) + $wallReqLoc); if ($ra.Valid) { $impPts = $ra.Points } } catch {}
                # build the plate geometry from the (re-anchored) points (same path as custom);
                # -EdgeMargin = the chosen wall so the derived far edge + the check agree.
                $geo = $null
                try { $geo = Get-CustomPointsGeometry -Points $impPts -ClearDia $holeDiaLoc -HoleDia $holeDiaLoc -EdgeMargin $wallReqLoc } catch { $geo = $null }
                if ($null -ne $geo -and $geo.Valid) {
                    $c.OrthoGeo = $geo; $c.OrthoValid = $true; $c.PointMode = 'fastener'; $c.FastenerLayoutPath = $layoutFile
                    $unitNote = if ($peek.Units -ne 'unknown') { ("  (units: {0} - match the jig part)" -f $peek.Units) } else { '' }
                    $y = (Add-Para $panel ("Loaded {0} hole(s) from '{1}'  -  axes {2}/{3}, plate {4:0.00} x {5:0.00}.{6}  Points are created in the drill step (3-plane intersections, no picks). Press Next." -f `
                        $geo.Count, $peek.SourceModel, $peek.AxisX, $peek.AxisZ, $geo.Width, $geo.Height, $unitNote) $y 0 'DarkGreen' $true).Bottom + 10
                    $wiz.SetChip('layout', ("layout: fastener ({0})" -f $geo.Count), 'set')
                    # SLOT DIRECTION (user 2026-07-23): X/Z toggle ABOVE the preview so the
                    # operator sees which way the chip-relief slots run in the image below.
                    Add-SlotDirToggle -Panel $panel -Context $c -Wizard $wiz -Top $y | Out-Null
                    $y = (Get-StackTop $panel 6)
                    # PREVIEW IMAGE (user 2026-07-21): show how the imported layout looks,
                    # like the orthogrid/custom editors (same numbered dot preview as the index step),
                    # with the relief bands drawn in the chosen slot direction.
                    [void](Add-LayoutPreview -Panel $panel -Context $c -Top $y -Left 8 -Width 320 -Height 172)
                    $y = (Get-StackTop $panel 8)
                } else {
                    $c.OrthoValid = $false
                    $msg = "The fastener layout loaded but did not form a valid plate:"
                    if ($null -ne $geo) { $msg += [Environment]::NewLine + "  - " + (($geo.Errors) -join ([Environment]::NewLine + "  - ")) }
                    $y = (Add-Para $panel $msg $y 0 'Firebrick' $true).Bottom + 10
                }
            }
            $y = (Add-Para $panel "No file yet, or want to re-scan? Read the fasteners live from an open Creo model:" $y 0 'gray').Bottom + 6
            $btnLive = New-Object System.Windows.Forms.Button
            $btnLive.Text = 'Read fasteners live now'
            $btnLive.Size = New-Object System.Drawing.Size(200, 30)
            $btnLive.Location = New-Object System.Drawing.Point(8, $y)
            $btnLive.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            $btnLive.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90,104,132)
            $btnLive.BackColor = if ($script:WizTheme -and $script:WizTheme.Accent) { $script:WizTheme.Accent } else { [System.Drawing.Color]::FromArgb(40,90,170) }
            $btnLive.ForeColor = Get-UiColor ''
            $btnLive.Add_Click({
                $hd = if ($null -ne $c.HoleDia -and [double]$c.HoleDia -gt 0) { [double]$c.HoleDia } else { 0.25 }
                $out = Join-Path $ScriptDir 'fastener_layout.json'
                $res = Invoke-GuiFastenerLiveRead -OutPath $out -HoleDia $hd -Wizard $wiz   # -Wizard so prompts render in-canvas
                # rerender either way: on success the file-load path above shows the new
                # layout; on cancel/failure the view is unchanged. $ctx.Model was never touched.
                $wiz.Rerender()
            }.GetNewClosure())
            $panel.Controls.Add($btnLive)

            $btnReload = New-Object System.Windows.Forms.Button
            $btnReload.Text = 'Reload file'
            $btnReload.Size = New-Object System.Drawing.Size(110, 30)
            $btnReload.Location = New-Object System.Drawing.Point(216, $y)
            $btnReload.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            $btnReload.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90,104,132)
            $btnReload.BackColor = if ($script:WizTheme) { $script:WizTheme.CanvasBack } else { [System.Drawing.Color]::FromArgb(30,42,68) }
            $btnReload.ForeColor = Get-UiColor ''
            $btnReload.Add_Click({ $wiz.Rerender() }.GetNewClosure())
            $panel.Controls.Add($btnReload)
            $btnBackType2 = New-Object System.Windows.Forms.Button
            $btnBackType2.Text = 'Change layout type'
            $btnBackType2.Size = New-Object System.Drawing.Size(150, 30)
            $btnBackType2.Location = New-Object System.Drawing.Point(332, $y)
            $btnBackType2.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            $btnBackType2.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90,104,132)
            $btnBackType2.BackColor = if ($script:WizTheme) { $script:WizTheme.CanvasBack } else { [System.Drawing.Color]::FromArgb(30,42,68) }
            $btnBackType2.ForeColor = Get-UiColor ''
            # Return to the tiles with NOTHING selected: reset LayoutPicked so the stray
            # "Selected: Skeleton Model" echo (gated on LayoutPicked && predefined) does NOT
            # fire on the bare tiles (user 2026-07-22).
            $btnBackType2.Add_Click({ $c.LayoutMode = $null; $c.PointMode='predefined'; $c.OrthoValid=$false; $c.OrthoGeo=$null; $c.LayoutPicked=$false; $wiz.Rerender() }.GetNewClosure())
            $panel.Controls.Add($btnBackType2)
            return
        }

        # VIEW 1/2: an inline editor (orthogrid OR custom), embedded - no popup.
        if ($c.LayoutMode -eq 'orthogrid' -or $c.LayoutMode -eq 'custom') {
            $isGrid = ($c.LayoutMode -eq 'orthogrid')
            $hdr = if ($isGrid) { "Orthogrid - set the grid; the plate is sized to fit the holes + clearance." }
                   else { "Custom points - add each hole's X / Z offset; the plate is sized to fit them." }
            $hdrB = (Add-Para $panel $hdr 8 0 'gray').Bottom + 8
            # NB: do NOT name this $host -- $host is a PowerShell automatic variable.
            # editHost is sized to the inline editor's own content (returned bottom) so a
            # taller editor is never clipped and the button below always clears it.
            $editHost = New-Object System.Windows.Forms.Panel
            $editHost.Location = New-Object System.Drawing.Point(0, $hdrB)
            $editHost.Size     = New-Object System.Drawing.Size(($panel.Width - 4), 320)
            $editHost.BackColor = [System.Drawing.Color]::Transparent
            $panel.Controls.Add($editHost)
            if ($isGrid) { [void](Add-InlineOrthogrid -Panel $editHost -Context $c -Wizard $wiz) }
            else         { [void](Add-InlineCustomPoints -Panel $editHost -Context $c -Wizard $wiz) }
            # size editHost to its ACTUAL laid-out children (robust: does not depend on the
            # inline function's return being a clean scalar) so nothing inside it is clipped.
            $editHost.Height = (Get-StackTop $editHost 320 10)
            $btnBackType = New-Object System.Windows.Forms.Button
            $btnBackType.Text = 'Change layout type'
            $btnBackType.Size = New-Object System.Drawing.Size(170, 30)
            $btnBackType.Location = New-Object System.Drawing.Point(8, ($editHost.Bottom + 8))
            $btnBackType.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            $btnBackType.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90,104,132)
            $btnBackType.BackColor = if ($script:WizTheme) { $script:WizTheme.CanvasBack } else { [System.Drawing.Color]::FromArgb(30,42,68) }
            $btnBackType.ForeColor = Get-UiColor ''
            # Return to the tiles with NOTHING selected: reset LayoutPicked so the stray
            # "Selected: Skeleton Model" echo (gated on LayoutPicked && predefined) does NOT
            # fire on the bare tiles (user 2026-07-22). Also clear OrthoGeo (match the fastener
            # VIEW 3 button) so no STALE geometry leaks back to the tiles / index-choice; the
            # inline editor re-derives OrthoGeo from the KEPT OrthoFields/CustomRows on re-entry,
            # so the operator's typed points are preserved (adversarial-review fix 2026-07-22).
            $btnBackType.Add_Click({ $c.LayoutMode = $null; $c.PointMode='predefined'; $c.OrthoValid=$false; $c.OrthoGeo=$null; $c.LayoutPicked=$false; $wiz.Rerender() }.GetNewClosure())
            $panel.Controls.Add($btnBackType)
            return
        }

        # VIEW 0: the four tiles. Start below any prior content (e.g. the invalid-import
        # fallback message that falls through to here) so nothing overlaps.
        $y = Get-StackTop $panel 8
        $y = (Add-Para $panel "Pick how the hole points are defined." $y 0 'Gray').Bottom + 4
        # RECOMMENDED default = import fastener layout (index 3). Mirrors the bushing-length
        # "recommended" pattern: a green note here + a persistent green highlight box on the
        # card via -HighlightIndex. Visual only -- every card is still fully clickable, so the
        # operator can pick any layout mode (user 2026-07-22).
        $y = (Add-Para $panel (([char]0x2713) + " Fastener-Driven Model is recommended -- reuse an existing part's fastener pattern. (Any option still works.)") $y 0 'green' $true).Bottom + 8
        $opts = @(
            @{ Title = 'Skeleton Model';    Subtitle = 'Hole layout determined from a Skeleton Model with datum points that drive hole location' },
            @{ Title = 'Orthogrid Model (rectangular pattern)'; Subtitle = 'Hole layout determined from a regular rectangular Nx x Nz grid - edited right here in the window' },
            @{ Title = 'User Generated Model'; Subtitle = 'Hole layout generated point-by-point by the user - type each hole''s X / Z offset, edited right here in the window' },
            @{ Title = 'Fastener-Driven Model'; Subtitle = 'Hole layout determined from an existing part''s fastener pattern - fastener centers read live from an open Creo model (or a saved layout file)' }
        )
        # RADIO-SELECT (user 2026-07-22): the recommended tile is auto-SELECTED (green, via
        # HighlightIndex = $c.LayoutSel; default 3 = Fastener). Clicking a tile only MOVES the
        # selection -- OnPick sets LayoutSel and the rerender re-draws VIEW 0 with the new card
        # green; LayoutMode stays null so the tiles STAY PUT (no sub-view opens on click). Next
        # COMMITS the selection (OnNext). So: the recommended is preselected + Next registers it;
        # clicking another option just highlights it green; the user presses NEXT to open it.
        $selIdx = if ($null -ne $c.LayoutSel) { [int]$c.LayoutSel } else { 3 }
        if ($selIdx -lt 0 -or $selIdx -ge $opts.Count) { $selIdx = 3 }
        Add-WizardChoiceCards -Panel $panel -Options $opts -Context $c -Wizard $wiz -Top $y -CardHeight 110 -HighlightIndex $selIdx -AfterPick 'rerender' -OnPick {
            param($i,$opt,$cc,$w)
            # SELECT ONLY -- move the green highlight; do NOT commit PointMode/LayoutMode (that
            # is Next's job in OnNext), so clicking never opens the sub-view. Moving away from
            # Custom clears any auto-set index-first pick (custom re-engages it on recompute).
            if ($i -ne 2 -and $cc.IndexFirst) { $cc.IndexFirst = $false; $cc.IndexKey = $null; $cc.IndexGridX = $null; $cc.IndexGridZ = $null }
            $cc.LayoutSel = $i
        }
        # SELECTED-tile hint (the green card is the primary cue; this restates it in words for
        # EVERY option, not just Skeleton). Flowed BELOW the cards so it never lands on one.
        $selTitle = [string]$opts[$selIdx].Title
        $ey = Get-StackTop $panel 8
        Add-Para $panel (([char]0x2713) + (" Selected: {0}. Press NEXT to use it, or click another option to change." -f $selTitle)) $ey 0 'DarkGreen' $true
    } `
    -OnNext {
        param($c,$wiz)
        # COMMIT the selected tile (user 2026-07-22 radio-select). Fires ONLY on the tiles
        # (LayoutMode null AND PointMode still 'predefined' -- the tiles invariant -- AND no
        # up-front fastener import). It maps $c.LayoutSel to the mode and either advances
        # (predefined) or opens the sub-view (return $false -> the engine re-renders THIS step,
        # which now shows the editor / fastener-import; Next there advances once OrthoValid).
        if ($null -eq $c.LayoutMode -and $c.PointMode -eq 'predefined' -and $null -eq $c.FastenerRawPoints) {
            $sel = if ($null -ne $c.LayoutSel) { [int]$c.LayoutSel } else { 3 }
            switch ($sel) {
                0 { $c.PointMode = 'predefined'; $c.OrthoGeo = $null; $c.OrthoValid = $false; $c.LayoutMode = $null; $c.LayoutPicked = $true; $wiz.SetChip('layout', 'layout: predefined', 'set'); return $true }
                1 { $c.PointMode = 'orthogrid'; $c.LayoutMode = 'orthogrid'; $c.OrthoValid = $false; $c.LayoutPicked = $true; return $false }
                2 { $c.PointMode = 'custom';    $c.LayoutMode = 'custom';    $c.OrthoValid = $false; $c.LayoutPicked = $true; return $false }
                default { $c.PointMode = 'fastener'; $c.LayoutMode = 'fastener'; $c.OrthoValid = $false; $c.OrthoGeo = $null; $c.LayoutPicked = $true; return $false }
            }
        }
        return $true
    }
[void]$steps.Add($layoutStep)

# ---- STAGE: Layout -- INDEX-HOLE choice (index-first mode; ALWAYS set) -------
# Pick which layout hole is the index (origin) the whole jig is referenced from. An index
# is ALWAYS set (user 2026-07-21: "there should be an index hole ALWAYS, so dont even say
# that is optional") -- default = the corner hole, changeable via the cards, no "None".
# The base csys is built AT that hole (box-a STAGE 1.9) and the grid pitch planes are built
# off CSYS_PAT_DEF at the index-relative coords (STAGE 2.5, Get-IndexDirectionalPlanePlan).
# EVERY non-predefined layout (orthogrid / custom / imported FASTENER) converges here and
# takes the IDENTICAL path -- fastener is NOT special-cased (the earlier fastener guard that
# skipped this + the intersected-csys plane bug it feared were removed once STAGE 2.5 was
# fixed to build off CSYS_PAT_DEF). Self-skips only for PREDEFINED (no $c.OrthoGeo layout).
$indexChoiceStep = New-WizardStep -Key 'index-choice' -Title 'Index hole' -Stage 'Layout' -Kind 'choice' -PrimaryText 'Next' `
    -Validate { param($c) return $true } `
    -Build {
        param($panel, $c, $wiz)
        if ($null -eq $c.OrthoGeo) {
            Add-Para $panel "No grid/custom/fastener layout - the index-hole option applies to a laid-out pattern. Press Next." 4 40 'Gray'
            return
        }
        # INDEX-RELATIVE CUSTOM LAYOUT (user 2026-07-21): the operator already chose the
        # index by TYPING it (the index hole = the corner-measured Points[0]) in the custom
        # editor, which auto-set IndexFirst/IndexKey=0/IndexGridX/Z. There is nothing to
        # pick here -- show a FIXED confirmation + the numbered preview (index = Hole #1),
        # no picker cards. box-a STAGE 1.9 + the drill step's STAGE 2.5 read these directly.
        if (($c.OrthoGeo.PSObject.Properties.Name -contains 'IndexRelative') -and $c.OrthoGeo.IndexRelative) {
            # keep IndexKey pinned to the index (Points[0]) even after a layout edit.
            $c.IndexFirst = $true; $c.IndexKey = 0
            $c.IndexGridX = [double]$c.OrthoGeo.IndexGridX; $c.IndexGridZ = [double]$c.OrthoGeo.IndexGridZ
            $y = (Add-Para $panel ("Index-relative custom layout: the INDEX hole (Hole #1) was set in the editor as an offset from the plate corner; every other hole is measured from it. The whole jig is referenced from the index hole -- nothing to pick here. Press Next.") 8 0 'Gray').Bottom + 8
            $hlKey0 = 0
            [void](Add-LayoutPreview -Panel $panel -Context $c -Top $y -Left 8 -Width 320 -Height 172 -HighlightKeyRef ([ref]$hlKey0))
            $y = Get-StackTop $panel 8
            Add-Para $panel (([char]0x2713) + " Index hole = Hole #1  (grid $([math]::Round($c.IndexGridX,3)), $([math]::Round($c.IndexGridZ,3))). Press Next.") $y 0 'DarkGreen' $true
            $wiz.SetChip('layout', 'layout: index hole set', 'set')
            return
        }
        $ihPlan = Get-IndexHolePlan -Points $c.OrthoGeo.Points
        $cands  = @($ihPlan.Candidates)
        if ($cands.Count -eq 0) {
            Add-Para $panel "No hole candidates in this layout. Press Next (origin-based build)." 4 40 'Gray'
            return
        }
        # AN INDEX HOLE IS ALWAYS SET. If none chosen yet, DEFAULT to the CORNER-most
        # candidate (min X, then min Z) so the jig references the plate corner; the operator
        # can pick a different hole from the cards (there is NO "None" - it is not optional).
        if (-not $c.IndexFirst -or $null -eq $c.IndexKey) {
            $corner = @($cands | Sort-Object @{Expression={[double]$_.X}}, @{Expression={[double]$_.Z}})[0]
            if ($null -ne $corner) {
                $c.IndexFirst = $true; $c.IndexKey = [int]$corner.Key
                $c.IndexGridX = [double]$corner.X; $c.IndexGridZ = [double]$corner.Z
            }
        }
        # RE-RESOLVE the chosen pick against the CURRENT layout: the operator can go Back and
        # edit the grid (index-choice sits before the first committed step), producing a NEW
        # OrthoGeo with new Points. Refresh the pick's coords if still valid; if the old key
        # no longer exists, fall back to the corner default (an index is NEVER left unset).
        if ($c.IndexFirst -and $null -ne $c.IndexKey) {
            $rehit = Get-IndexHolePlan -Points $c.OrthoGeo.Points -IndexKey $c.IndexKey
            if ($rehit.HasIndex) { $c.IndexGridX = [double]$rehit.IndexGridX; $c.IndexGridZ = [double]$rehit.IndexGridZ }
            else {
                $corner = @($cands | Sort-Object @{Expression={[double]$_.X}}, @{Expression={[double]$_.Z}})[0]
                if ($null -ne $corner) { $c.IndexKey = [int]$corner.Key; $c.IndexGridX = [double]$corner.X; $c.IndexGridZ = [double]$corner.Z }
            }
        }
        $y = (Add-Para $panel ("Pick which hole is the INDEX (origin) the whole jig is referenced from. An index is ALWAYS set (default = the corner hole); the layout below shows every hole NUMBERED - card ""Hole #N"" is dot #N.") 8 0 'Gray').Bottom + 8
        # numbered sample layout (same plate + dots + relief bands as the editors), so the
        # operator sees WHICH hole each "Hole #N" card is; the chosen index is ringed.
        # -AfterPick 'rerender' rebuilds this Build on every pick so the ring tracks it.
        $hlKey = $c.IndexKey
        [void](Add-LayoutPreview -Panel $panel -Context $c -Top $y -Left 8 -Width 320 -Height 172 -HighlightKeyRef ([ref]$hlKey))
        $y = Get-StackTop $panel 8
        $y = (Add-Para $panel (([char]0x2713) + " Index hole = Hole #$($c.IndexKey + 1)  (grid $([math]::Round($c.IndexGridX,3)), $([math]::Round($c.IndexGridZ,3))). Press Next.") $y 0 'DarkGreen' $true).Bottom + 8
        $opts = @()
        foreach ($cd in $cands) {
            # subtitle uses coords only (the "Hole #N" title is the single, 1-based
            # number, matching the numbered dot - no conflicting 0-based "#" here).
            $ijTxt = if ($null -ne $cd.I -and $null -ne $cd.J) { ("  (I={0},J={1})" -f $cd.I, $cd.J) } else { "" }
            $opts += @{ Title = ("Hole #" + ($cd.Key + 1)); Subtitle = ("X={0:0.###}  Z={1:0.###}{2}" -f $cd.X, $cd.Z, $ijTxt) }
        }
        # GREEN card border on the currently-selected index (matches the ring on the preview
        # + the green text above). $cands and $opts are the same order, so the card index is
        # the position of the IndexKey in $cands (user 2026-07-22: selected option shown green).
        $selCard = -1
        for ($ci = 0; $ci -lt @($cands).Count; $ci++) { if ([int]$cands[$ci].Key -eq [int]$c.IndexKey) { $selCard = $ci; break } }
        Add-WizardChoiceCards -Panel $panel -Options $opts -Context $c -Wizard $wiz -Top ($y + 4) -CardWidth 200 -CardHeight 84 -HighlightIndex $selCard -AfterPick 'rerender' -OnPick {
            param($i,$opt,$cc,$w)
            # every card is an index pick (no "None"); card $i maps straight to Candidates[$i].
            $plan = Get-IndexHolePlan -Points $cc.OrthoGeo.Points
            $cand = @($plan.Candidates)[$i]
            # guard an out-of-range index (the layout could have changed since the cards were
            # laid out): $cand would be $null and $cand.Key would silently no-op. Bail cleanly.
            if ($null -eq $cand) { return }
            $chosen = Get-IndexHolePlan -Points $cc.OrthoGeo.Points -IndexKey $cand.Key
            if ($chosen.HasIndex) {
                $cc.IndexFirst = $true; $cc.IndexKey = $cand.Key
                $cc.IndexGridX = [double]$chosen.IndexGridX; $cc.IndexGridZ = [double]$chosen.IndexGridZ
                $w.SetChip('layout', 'layout: index hole set', 'set')
            }
        }
    } `
    -OnNext { param($c,$wiz) return $true }
[void]$steps.Add($indexChoiceStep)

# ---- STAGE: Overview -- rough 3D look of the jig (WebView2 + three.js) ------
# A view-only "model overview" page between Layout and Datums: the operator can
# ROTATE the plate + drilled holes + chip-relief slots to sanity-check the shape
# before any Creo work. NO controls beyond orbit (the embedded HTML's slider panel
# is hidden via the #embed hash); it is explicitly labelled a GENERAL, approximate
# view. Renders the EXACT current layout by pushing $c.OrthoGeo to the three.js
# scene (docs\drilljig_3d_preview.html) over the WebView2 bridge. Lazy-loads
# WebView2; degrades to a plain note if it (or a layout) is unavailable. Purely
# informational -> Validate/OnNext always allow; nothing is committed here.
$overviewStep = New-WizardStep -Key 'overview' -Title '3D overview (rough)' -Stage 'Overview' -Kind 'info' -PrimaryText 'Continue to datums' `
    -Validate { param($c) return $true } `
    -OnNext { param($c, $wiz) return $true } `
    -Build {
        param($panel, $c, $wiz)
        $note = Add-Para $panel ("General view - APPROXIMATE, not exact. Rotate (drag) to inspect the rough shape of the plate, drilled holes, and chip-relief slots. The built jig may differ in detail.") 8 0 'yellow' $true
        $y = $note.Bottom + 8

        # need a computed layout (orthogrid / custom / imported). Predefined points
        # have no plate/hole model to preview -> show a note and let Next proceed.
        if ($null -eq $c.OrthoGeo -or -not $c.OrthoGeo.Valid) {
            Add-Para $panel ("No computed layout to preview (predefined points, or the layout is not yet valid). The 3D overview needs an orthogrid / custom / imported layout. Press Continue.") $y 0 'gray'
            return
        }

        # HEADLESS GUARD: only spin up a WebView2 when a WinForms message loop is
        # actually running (the live GUI). Headless render tests (fuzz_gui.ps1 /
        # run_wizard_tests.ps1) call this Build on a detached panel with NO message
        # loop, where WebView2 cannot init anyway -> skip it and just show a note, so
        # the tests exercise the Build path without instantiating a browser control.
        if (-not [System.Windows.Forms.Application]::MessageLoop) {
            Add-Para $panel ("[3D overview renders here in the live GUI window - headless render skipped]") $y 0 'gray'
            return
        }

        # lazy-load the WebView2 SDK; if unavailable, the jig still builds fine.
        try { Add-WebView2Assemblies | Out-Null }
        catch {
            Add-Para $panel ("3D overview unavailable - WebView2 could not load ({0}). This does not affect building the jig; press Continue. (A zero-dependency 3D window is available separately: drilljig-3d-preview.cmd.)" -f $_.Exception.Message) $y 0 'gray'
            return
        }

        # ---- build the geometry payload from the CURRENT layout ----
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $holeDia = if ($null -ne $c.HoleDiaFinal -and [double]$c.HoleDiaFinal -gt 0) { [double]$c.HoleDiaFinal }
                   elseif ($null -ne $c.HoleDia -and [double]$c.HoleDia -gt 0) { [double]$c.HoleDia } else { 0.25 }
        $slotDepth = if ($null -ne $c.SlotDepth -and [double]$c.SlotDepth -gt 0) { [double]$c.SlotDepth } else { 0.25 }
        $bushingLen = if ($null -ne $c.BushingLen -and [double]$c.BushingLen -gt 0) { [double]$c.BushingLen } else { 0.5 }
        $thickness = $bushingLen + $slotDepth
        # points JSON built by hand so it is ALWAYS a JS array (PS ConvertTo-Json drops
        # the brackets for a single element) and numbers use InvariantCulture (period
        # decimal) so the JSON is valid regardless of the machine's locale.
        $ptsJson = (@($c.OrthoGeo.Points) | ForEach-Object {
            '{"X":' + (([double]$_.X).ToString($inv)) + ',"Z":' + (([double]$_.Z).ToString($inv)) + '}'
        }) -join ','
        # slot removal-path direction (fastener X/Z toggle from the Layout stage) so the
        # 3D preview's chip-relief bands run the SAME way the operator chose; default X.
        $rowAxisJson = if ($c.SlotRowAxis -eq 'Z') { 'Z' } else { 'X' }
        $json = '{"valid":' + $(if ($c.OrthoGeo.Valid) { 'true' } else { 'false' }) +
            ',"width":'    + (([double]$c.OrthoGeo.Width).ToString($inv)) +
            ',"height":'   + (([double]$c.OrthoGeo.Height).ToString($inv)) +
            ',"holeDia":'  + (([double]$holeDia).ToString($inv)) +
            ',"thickness":'+ (([double]$thickness).ToString($inv)) +
            ',"slotDepth":'+ (([double]$slotDepth).ToString($inv)) +
            ',"rowAxis":"' + $rowAxisJson + '"' +
            ',"points":['  + $ptsJson + ']}'
        $c.Wv3dPayload = $json   # stashed in the persistent context so the NavigationCompleted closure reads it by reference

        # ---- the WebView2 control, filling the canvas below the note ----
        $wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
        $props = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
        # DISTINCT UserDataFolder from the Welcome stage's WebView2 (shared folder = lock
        # contention -> a blank second view). Each is disposed on step change (wizard.ps1).
        $props.UserDataFolder = Join-Path $env:TEMP 'drilljig_wv2_overview'
        $wv.CreationProperties = $props
        $cw = [Math]::Max(420, $panel.ClientSize.Width  - 16)
        $ch = [Math]::Max(320, $panel.ClientSize.Height - $y - 12)
        $wv.Location = New-Object System.Drawing.Point(8, $y)
        $wv.Size = New-Object System.Drawing.Size($cw, $ch)
        $wv.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
        $panel.Controls.Add($wv)

        # push the layout to the three.js scene once the page has loaded (setJigGeometry
        # stashes + applies whether it arrives before or after three.js finishes loading).
        $wv.add_NavigationCompleted({
            param($s, $e)
            try { $null = $s.ExecuteScriptAsync("setJigGeometry(" + $c.Wv3dPayload + ")") } catch {}
        }.GetNewClosure())

        # navigate to the shared HTML scene in EMBED mode (#embed hides its slider panel)
        $htmlPath = Join-Path $ScriptDir 'docs\drilljig_3d_preview.html'
        $fileUri = ([System.Uri]$htmlPath).AbsoluteUri + '#embed'
        try { $wv.Source = New-Object System.Uri($fileUri) } catch {}
    }
[void]$steps.Add($overviewStep)

# ---- STAGE: Datums -- capture the 3 base datums (auto / pick) --------------
$datumStep = New-WizardStep -Key 'datums' -Title 'Base datum planes' -Stage 'Datums' -Kind 'pick' -PrimaryText 'Continue to box' `
    -Validate { param($c) return ($null -ne $c.Planes -and (@($c.Planes | Where-Object { $null -ne $_.BaseId }).Count -ge 3)) } `
    -Build {
        param($panel, $c, $wiz)
        if ($null -eq $c.Planes) {
            $c.Planes = @(
                [pscustomobject]@{ Label="Top";   Hint="TOP";   Offset=0.0; Sym=$null; BaseId=$null; FeatId=$null }
                [pscustomobject]@{ Label="Side";  Hint="SIDE";  Offset=0.0; Sym=$null; BaseId=$null; FeatId=$null }
                [pscustomobject]@{ Label="Front"; Hint="FRONT"; Offset=0.0; Sym=$null; BaseId=$null; FeatId=$null }
            )
        }
        # try the API first (no clicks)
        if (-not ($null -ne $c.Planes -and (@($c.Planes | Where-Object { $null -ne $_.BaseId }).Count -ge 3))) {
            # MODEL-HANDLE REFRESH (fastener-import fix, 2026-07-21): the up-front fastener
            # LIVE read (Invoke-GuiFastenerLiveRead) toggles Creo's ACTIVE model
            # jig -> fastener -> jig via a THROWAWAY connection. That round-trip stales the
            # jig-part model handle captured ONCE at startup (~line 970 -> $script:DJModel),
            # so $script:DJModel.ListItems(ITEM_FEATURE) returns EMPTY and Find-DefaultDatumPicks
            # (below) yields 0 roles -> this stage WRONGLY drops into the manual "Ctrl-click
            # TOP/SIDE/FRONT" pick. Every OTHER point mode auto-discovers because it never
            # toggled the active model (the console avoids this by connecting AFTER the read).
            # Fix: re-fetch a FRESH jig-part handle from the still-live session and re-bind the
            # engine + the $model / $ctx.Model aliases the later box/drill steps read.
            # GUARDED: rebind ONLY when the ACTIVE model IS the jig PART (FileName == the startup
            # part, not an .asm) so it can NEVER bind the fastener model if the operator forgot
            # to switch back. No-op when the handle is already good. This -Build is a plain
            # (non-closure) block invoked via `& $step.Build`, so $script:model reaches the
            # top-level $model (top-level reads like $noCornerRound/$dataDir resolve here).
            # Runs only while auto-map is still needed (BaseIds unset), so the macroFailures
            # reset inside Initialize-DrilljigCore is a no-op (no macro fires before Datums).
            # NAME MATCH is NORMALIZED: IpfcModel.FileName can carry a version suffix
            # (".prt.3"; the startup .asm guard matches "\.asm(\.\d+)?$" for the same reason),
            # so an exact -eq between the startup capture and the re-fetch could wrongly miss
            # and fall to a manual pick. Strip a trailing ".<digits>" version and compare
            # case-insensitively -> matches the jig part reliably while STILL rejecting the
            # (differently-named) fastener model.
            if (-not [string]::IsNullOrWhiteSpace([string]$c.ModelName)) {
                $jigNorm = ([string]$c.ModelName -replace '\.\d+$','').ToLower()
                # (A) REPAIR THE SESSION. The fastener LIVE read opens a THROWAWAY
                # pfcAsyncConnection to the same running Creo and disconnects it; on this
                # build that leaves the startup session unusable -- $c.Session.GetActiveModel()
                # THROWS (or the jig handle can no longer enumerate features), so the Datums
                # auto-map (and every later RunMacro) fails ONLY after a fastener import. My
                # earlier fix only re-fetched GetActiveModel + rebound, and its try/catch
                # SILENTLY SWALLOWED the throw on a dead session -> no repair -> still the manual
                # pick. The console never hits this because it connects AFTER its read. So do the
                # console thing here: if the current session cannot return the active model,
                # RECONNECT a fresh pfcAsyncConnection and repoint the TOP-LEVEL $connection /
                # $session (the box/drill/slot steps use $session.RunMacro + $model directly) +
                # $c.Session. This is what makes the Datums page behave IDENTICALLY for every
                # layout (orthogrid/custom never toggle the active model, so their session stays
                # live; fastener now gets a live session back too).
                $sess = $c.Session; $am = $null
                try { if ($null -ne $sess) { $am = $sess.GetActiveModel() } } catch { $am = $null }
                if ($null -eq $sess -or $null -eq $am) {
                    try {
                        $reAsync = New-Object -ComObject pfcls.pfcAsyncConnection
                        $reConn  = $reAsync.Connect($null, $null, $null, $null)
                        $sess    = $reConn.Session
                        $am      = $sess.GetActiveModel()
                        $script:connection = $reConn; $script:session = $sess; $c.Session = $sess
                        $wiz.Log('Re-established the Creo connection after the fastener import (the live read had closed it).')
                    } catch { $am = $null }
                }
                # (B) REBIND the jig-model handle to the LIVE active model so the datum
                # enumeration below hits a fresh handle. Guarded to the jig PART (normalized
                # name, not an .asm) so it can never bind the fastener model; if the operator
                # is not on the jig, the auto-map finds <3 roles and the manual pick shows.
                try {
                    $amName = if ($null -ne $am) { [string]$am.FileName } else { '' }
                    $amNorm = ($amName -replace '\.\d+$','').ToLower()
                    if ($null -ne $am -and $amNorm -eq $jigNorm -and $amName -notmatch '(?i)\.asm(\.\d+)?$') {
                        $c.Model = $am; $script:model = $am
                        Initialize-DrilljigCore -Session $c.Session -Model $am -TypeObj $c.Type -DataDir $dataDir -Log $djLogger
                    } elseif ($null -ne $am -and $amNorm -ne $jigNorm) {
                        Add-Para $panel ("NOTE: Creo's active window is '" + $amName + "', not the jig part '" + [string]$c.ModelName + "'." + [Environment]::NewLine +
                                         "Activate the jig PART in Creo (if you imported fasteners, switch back to it), then click Back then Continue so the datums auto-map.") 8 44 'goldenrod' $true
                    }
                } catch {}
            }
            $picks = @(Find-DefaultDatumPicks)
            $found = @($picks | Where-Object { $null -ne $_.Role } | Select-Object -ExpandProperty Role -Unique)
            if (@($found).Count -ge 3) {
                $byRole = @{}; foreach ($pk in $picks) { if ($null -ne $pk.Role -and -not $byRole.ContainsKey($pk.Role)) { $byRole[$pk.Role] = $pk.Id } }
                foreach ($p in $c.Planes) { $p.BaseId = [int]$byRole[$p.Label] }
                $c.AutoMapped = $true
            }
        }
        if ($null -ne $c.Planes -and (@($c.Planes | Where-Object { $null -ne $_.BaseId }).Count -ge 3)) {
            $lines = "Found the three default datums by name - no clicks needed:" + [Environment]::NewLine
            foreach ($p in $c.Planes) { $lines += ("    {0,-5} -> datum id {1}" -f $p.Hint, $p.BaseId) + [Environment]::NewLine }
            Add-Para $panel $lines (Get-StackTop $panel 8) 0 $null $false
            $wiz.SetChip('datums', 'datums: auto-mapped', 'set')
        } else {
            $armB = Add-ArmBanner $panel ("In Creo, Ctrl-click ALL THREE default datums (TOP, SIDE, FRONT) - any order." + [Environment]::NewLine + "They are matched to roles by NAME, not click order.") (Get-StackTop $panel 8)
            Add-VerifyControls -Panel $panel -Context $c -Wizard $wiz -Top ($armB + 12) -OnVerify {
                param($cc, $w)
                $picks = @(Read-SelectionPlanePicks)
                if ($picks.Count -eq 0) { return @{ Ok=$false; Message='Nothing selected. Ctrl-click the three datums in Creo, then verify.' } }
                $byRole = @{}; $conflict = $false
                foreach ($pk in $picks) { if ($null -eq $pk.Role) { continue }; if ($byRole.ContainsKey($pk.Role)) { $conflict=$true; continue }; $byRole[$pk.Role] = $pk.Id }
                $all = ($byRole.ContainsKey('Top') -and $byRole.ContainsKey('Side') -and $byRole.ContainsKey('Front'))
                if ($conflict) { return @{ Ok=$false; Message='Two datums matched the same role - re-pick.' } }
                if (-not $all) {
                    $missing = @('Top','Side','Front' | Where-Object { -not $byRole.ContainsKey($_) })
                    return @{ Ok=$false; Message=("Could not match all three by name (missing: {0}). Re-pick." -f ($missing -join ', ')) }
                }
                foreach ($p in $cc.Planes) { $p.BaseId = [int]$byRole[$p.Label] }
                $cc.AutoMapped = $true
                $w.SetChip('datums', 'datums: mapped', 'set')
                $msg = ''
                foreach ($p in $cc.Planes) { $msg += ("{0} -> id {1}    " -f $p.Hint, $p.BaseId) }
                return @{ Ok=$true; Message=$msg }
            }
        }
    } `
    -OnNext { param($c,$wiz) return $true }
[void]$steps.Add($datumStep)

# ---- STAGE: Box -- SPLIT into Box-A (create planes + open sketcher) and Box-B
#      (finish + extrude), so the manual rectangle draw is a normal wizard PAUSE
#      between two steps, NOT a blocking modal. A MessageBox shown while the user
#      is interacting with Creo can be drawn BEHIND the Creo window and freeze the
#      whole wizard (the "can't click anything" bug). The split keeps the message
#      loop alive: Box-A stops after arming the sketcher; the user draws in Creo;
#      Box-B finishes. $c.BoxArmed gates the two.
$boxStepA = New-WizardStep -Key 'box-a' -Title 'Build the parametric box' -Stage 'Box' -Kind 'run' -PrimaryText 'Create planes + open sketcher' `
    -Validate { param($c) return $true } `
    -Build {
        param($panel, $c, $wiz)
        # resolve the three offsets (SIDE = bushing len; TOP/FRONT = plate W/H when a grid exists)
        # SIDE = bushing length, PADDED by the relief depth so the guide depth after the
        # slot cut equals the bushing length (the pad is applied for real in OnNext, once
        # $c.WillSlot is known; here we reflect $c.ReliefPad, which is 0 until then / 0 when
        # no relief). TOP/FRONT = plate W/H when a grid exists.
        foreach ($p in $c.Planes) {
            if ($p.Label -eq 'Side'  -and $null -ne $c.BushingLen) { $p.Offset = [double]$c.BushingLen + [double]$c.ReliefPad }
            elseif ($p.Label -eq 'Top'   -and $null -ne $c.OrthoGeo) { $p.Offset = [double]$c.OrthoGeo.Width }
            elseif ($p.Label -eq 'Front' -and $null -ne $c.OrthoGeo) { $p.Offset = [double]$c.OrthoGeo.Height }
        }
        if ($c.BoxArmed) {
            Add-Para $panel ("Planes created and the sketcher is open in Creo." + [Environment]::NewLine +
                             "Draw the rectangle there, then press Next.") 8 60 'DarkGreen' $true
            return
        }
        $msg = "The box is three offset datum planes + an extrude between them." + [Environment]::NewLine + [Environment]::NewLine
        $msg += "Offsets:" + [Environment]::NewLine
        foreach ($p in $c.Planes) {
            $dim = switch ($p.Label) { 'Side' {'width/length'} 'Top' {'height'} 'Front' {'depth'} default {''} }
            $src = ''
            if ($p.Label -eq 'Side'  -and $null -ne $c.BushingLen) {
                # The pad is applied in OnNext (once $c.WillSlot is known); on first render
                # $c.ReliefPad is still 0, so the shown value is the UNPADDED bushing length.
                # Annotate so the preview does not contradict the padded plate that gets built.
                if ([double]$c.ReliefPad -gt 0) { $src = ("(bushing length + {0}"" relief pad)" -f [double]$c.SlotDepth) }
                elseif ($c.WillSlot -eq $false) { $src = '(from bushing length; no relief pad)' }
                else { $src = ("(bushing length; will be padded +{0}"" if you add chip relief on Next)" -f [double]$c.SlotDepth) }
            }
            if ($p.Label -eq 'Top'   -and $null -ne $c.OrthoGeo)   { $src = '(from plate width)' }
            if ($p.Label -eq 'Front' -and $null -ne $c.OrthoGeo)   { $src = '(from plate height)' }
            $msg += ("    {0,-5} ({1,-12}) = {2,-7} {3}" -f $p.Hint, $dim, $p.Offset, $src) + [Environment]::NewLine
        }
        # any plane still 0 (no grid / no bushing) gets a small editable field
        $needsManual = @($c.Planes | Where-Object { [double]$_.Offset -le 0 })
        $y = (Add-Para $panel $msg 8 0 'Gray').Bottom + 10
        foreach ($p in $needsManual) {
            $lab = New-Object System.Windows.Forms.Label
            $lab.Text = ("{0} offset:" -f $p.Hint); $lab.Location = New-Object System.Drawing.Point(8, ($y+3)); $lab.Size = New-Object System.Drawing.Size(120, 20)
            $panel.Controls.Add($lab)
            $tb = New-Object System.Windows.Forms.TextBox
            $tb.Location = New-Object System.Drawing.Point(132, $y); $tb.Size = New-Object System.Drawing.Size(80, 22); $tb.Text = '1.0'
            $tb.Tag = $p
            $tb.Add_TextChanged({ param($s,$e) $v=0.0; if ([double]::TryParse($s.Text,[ref]$v) -and $v -gt 0) { $s.Tag.Offset = $v } }.GetNewClosure())
            $p.Offset = 1.0
            $panel.Controls.Add($tb)
            $y += 30
        }
        Add-Para $panel ("Press the button below: Creo creates the three planes and opens the sketcher. " +
                         "Then you draw a rough rectangle (2 clicks) in Creo - the next screen finishes it.") ($y + 4) 0 'Gray'
    } `
    -OnNext {
        param($c, $wiz)
        if ($c.BoxArmed) { return $true }   # already armed (came back + re-Next) -> advance to Box-B
        $script:GuiWiz = $wiz
        $wiz.BeginRun('Creating planes + opening the sketcher...')

        # CHIP-RELIEF DEPTH BUDGET (decided ONCE here, before the planes are made): the
        # bushing length is the FINAL guide depth wanted AFTER the relief slot is cut, so
        # if relief WILL be cut we PAD the extrude by the relief depth (plate =
        # bushingLen + SLOT_DEPTH_ABS); the slot then removes SLOT_DEPTH_ABS, leaving bushingLen.
        # Decide it here (not in -Build, which reruns every render) so the metal prompt
        # fires exactly once; the Relief stage reuses $c.WillSlot (no second ask).
        if ($null -eq $c.WillSlot) {
            if ($noSlotRelief -or $null -eq $c.OrthoGeo) {
                $c.WillSlot = $false   # --no-slot-relief, or predefined points (no rows) -> no relief, no pad
            } elseif ($c.Is3dPrint) {
                $c.WillSlot = $true    # 3D print -> relief added automatically
            } else {
                $ans = $wiz.AskInline('Chip-relief slots', ("Add chip-relief slots (one per hole row)?" + [Environment]::NewLine + [Environment]::NewLine + ("The plate will be padded by {0}"" so the FINAL guide depth equals the bushing length after the slot is cut." -f [double]$c.SlotDepth)), 'YesNo')
                $c.WillSlot = ($ans -eq 'Yes')
            }
            $c.ReliefPad = if ($c.WillSlot) { [double]$c.SlotDepth } else { 0.0 }
            $wiz.Log(("Chip-relief: {0}. Extrude pad = {1}"" (plate = bushing length + pad; final guide depth = bushing length)." -f $(if ($c.WillSlot) { 'YES (plate padded)' } else { 'no (plate not padded)' }), $c.ReliefPad))
        }
        # apply the pad to the SIDE offset now that the decision is known (Build set the
        # unpadded value on render; overwrite it here before the plane is created).
        foreach ($p in $c.Planes) {
            if ($p.Label -eq 'Side' -and $null -ne $c.BushingLen) { $p.Offset = [double]$c.BushingLen + [double]$c.ReliefPad }
        }

        # STAGE 1.9: base coordinate system (once), created fully automatically -- the
        # tool finds the part's DEFAULT csys (CSYS_PAT_DEF / PRT_CSYS_DEF / first csys),
        # selects it, and fires ProCmdDatumCsys -> OK (no user pick). The box + grid
        # planes then reference it, so re-placing it onto the index hole (Index stage)
        # moves the whole jig. --no-base-csys -> legacy default-datum planes; also falls
        # back to legacy if the part exposes no coordinate system or the create is a no-op.
        if ($null -eq $c.UseCsys) {
            $c.UseCsys = $false; $c.BaseCsysId = $null; $c.FaceId = $null
            if (-not $noBaseCsys) {
                $refCsysId = Find-DefaultCsysId
                if ($null -ne $refCsysId) {
                    $c.RefCsysId = [int]$refCsysId   # remembered for the reref methods
                    if ($c.IndexFirst) {
                        # INDEX-FIRST (user's construction): build the base csys AT the index hole
                        # (before drilling). STAGE 2.5 then offsets grid planes RELATIVE to it
                        # ((grid-index)*flip) so the drilled pattern matches the GUI layout referenced
                        # from the index hole. A datum plane offset from a csys axis is measured from
                        # THAT CSYS ORIGIN (confirmed live 2026-07-16: an absolute-valued plane off the
                        # index csys overshot by +index), so the index hole's own column reuses the
                        # anchor plane and the others are the cc DIFFERENCE.
                        # AXIS-DIRECTION FIX (2026-07-17): build ALL 3 anchor planes off CSYS_PAT_DEF so
                        # the index csys axes are DETERMINISTICALLY model-aligned (+X/+Y/+Z), which is
                        # what makes the offset DIRECTION correct for ANY index hole. The earlier "Y
                        # anchor off the SIDE default datum" (to sit the csys at the extrude-depth face)
                        # has a PART-SPECIFIC normal sign; a -Y makes the triple left-handed and Creo
                        # flips X or Z to restore right-handedness -> the csys is SOMETIMES mirrored ->
                        # offset direction sometimes wrong. Anchoring Y off CSYS_PAT_DEF Axis_Y (always
                        # +Y) keeps the triple consistent -> aligned axes every time. Trade-off: the csys
                        # Y origin sits at the model-origin plane (GridY 0), not the extrude-depth face
                        # -- cosmetic (Y does not affect drilling nor the export, which uses Y=0).
                        # --index-flip-x/-z remains a backstop.
                        $wiz.Log("INDEX-FIRST: building the base coordinate system AT the index hole (grid $([math]::Round($c.IndexGridX,3)), $([math]::Round($c.IndexGridZ,3))) off csys $refCsysId, axes aligned to the model (Y anchor off CSYS_PAT_DEF, not the SIDE datum)...")
                        $bc = Invoke-OutputCsys -RefCsysId $refCsysId -GridX ([double]$c.IndexGridX) -GridZ ([double]$c.IndexGridZ) -GridY 0.0
                        if ($bc.Ok) {
                            $c.BaseCsysId = [int]$bc.CsysFeatId; $c.UseCsys = $true
                            # capture the anchor planes ([X@indexX, Y@depth, Z@indexZ]) for the STAGE 2.5 reuse
                            $anchors = @($bc.AnchorPlaneIds)
                            if ($anchors.Count -ge 3) { $c.IndexAnchorX = [int]$anchors[0]; $c.IndexAnchorZ = [int]$anchors[2] }
                            $wiz.Log("Base csys created AT the index hole (feature id $($c.BaseCsysId)). Grid planes are offset relative to it. (If holes come out mirrored, re-run with --index-flip-x / --index-flip-z.)")
                        }
                        else {
                            # CLEAR the index coords: without the index-hole csys the base sits at the
                            # ORIGIN, so subtracting the index in STAGE 2.5 would drag holes to the part
                            # corner. Dropping it -> absolute offsets off the origin csys (correct
                            # positions, not index-referenced).
                            $c.IndexFirst = $false; $c.IndexGridX = $null; $c.IndexGridZ = $null
                            $wiz.Log("*** INDEX-FIRST base csys NOT created: $($bc.Reason). Falling back to a plain ORIGIN base csys + ABSOLUTE offsets -- correct positions but NOT referenced from the index hole (re-run to retry). ***")
                        }
                    }
                    if ($null -eq $c.BaseCsysId -and -not $c.IndexFirst) {
                        $wiz.Log('Creating the base coordinate system from the part default csys (automatic)...')
                        $bc = Invoke-BaseCsys -RefCsysId $refCsysId -Show
                        if ($bc.Ok) { $c.BaseCsysId = [int]$bc.CsysFeatId; $c.UseCsys = $true; $wiz.Log("Base coordinate system created (feature id $($c.BaseCsysId)). All planes reference it.") }
                        else { $wiz.Log("Base csys not created ($($bc.Reason)); using legacy default-datum planes.") }
                    }
                } else { $wiz.Log('No default coordinate system found; using legacy default-datum planes.') }
            } else { $wiz.Log('(--no-base-csys) using legacy default-datum planes.') }
            # index-first needs the csys base; if that fell back to legacy, drop index-first.
            if ($c.IndexFirst -and -not $c.UseCsys) { $c.IndexFirst = $false }
        }

        # Create the three BOX offset planes -- ALWAYS off the default datums (BOTH modes).
        # The box is a LOCAL slab: it sketches on the SIDE default datum and extrudes up to
        # the SIDE offset plane, so the plate THICKNESS is the gap between those planes. For
        # thickness == bushingLen EXACTLY, the SIDE plane must be offset bushingLen FROM the
        # SIDE default datum (the sketch plane) -- a plain New-OffsetPlane.
        #   *** BUG FIXED 2026-07-16: in csys mode the SIDE plane was Axis_Y @ bushingLen off
        #   *** the BASE CSYS (measured from the csys/CSYS_PAT_DEF Y-origin) while the box
        #   *** sketched on the SIDE DEFAULT DATUM -- a different Y origin -- so the plate came
        #   *** out much taller than the bushing (measured 3.37 vs a 0.75 bushing). The csys is
        #   *** ONLY for the hole GRID (STAGE 2.5's Axis_X/Axis_Z pitch planes); the box
        #   *** footprint is the hand-drawn rectangle, so TOP/FRONT are just visual guides.
        $wiz.Log('Creating three box offset datum planes off the default datums (no clicks)...')
        foreach ($p in $c.Planes) {
            $wiz.Pump()
            $ax = switch ($p.Label) { 'Top' {'X'} 'Side' {'Y'} 'Front' {'Z'} default {'Y'} }
            $res = New-OffsetPlane -Label $p.Label -Offset $p.Offset -BaseId $p.BaseId
            $p | Add-Member -NotePropertyName Axis -NotePropertyValue $ax -Force
            $p.Sym = $res.Symbol; $p.FeatId = $res.FeatId
        }
        # show planes
        $showList = @($c.Planes | Where-Object { $null -ne $_.FeatId })
        foreach ($p in $showList) {
            $wiz.Pump()
            Invoke-Macro "show $($p.Label) plane (id $($p.FeatId))" ((Get-SelectByIdMacro -FeatId $p.FeatId) + "~ Command ``ProCmdViewShow@PopupMenuTree``;")
        }
        $c.Made = @($c.Planes | Where-Object { $null -ne $_.Sym })
        if ($c.Made.Count -eq 0) {
            $wiz.Log('No offset planes produced a drivable dim - cannot build the box.')
            $wiz.SetChip('box', 'box: failed', 'aborted')
            [void]$wiz.AskInline('Drill Jig Builder', 'No offset planes were created. Inspect Creo, then close + re-run.', 'OK')
            return $false
        }
        $side = @($c.Made | Where-Object { $_.Label -eq 'Side' }); $side = if ($side.Count -gt 0) { $side[0] } else { $null }
        $c.SidePlane = $side

        # Box references (BOTH modes): sketch on the SIDE default datum (a proven,
        # correctly-oriented plane), extrude UP TO the SIDE offset plane -- which is now
        # offset bushingLen FROM the SIDE default datum in both modes, so the plate
        # thickness == bushingLen exactly (the SIDE plane is no longer csys-referenced).
        if ($null -eq $side -or $null -eq $side.BaseId -or $null -eq $side.FeatId) {
            $wiz.Log('SIDE datum/plane is missing a base/offset id - cannot build hands-free.')
            $wiz.SetChip('box', 'box: failed', 'aborted')
            [void]$wiz.AskInline('Drill Jig Builder', 'The SIDE plane was not created cleanly (the default datums must be captured). Inspect Creo, then close + re-run.', 'OK')
            return $false
        }
        $c.SketchPlaneId = [int]$side.BaseId
        $c.ExtrudeToId   = [int]$side.FeatId
        $wiz.Log('Opening the sketcher on the SIDE datum...')

        # MACRO A: arm the extrude + sketcher. Returns immediately; the user now
        # draws the rectangle in Creo and presses Next (Box-B). NO blocking modal.
        $mkArm = (Get-SelectByIdMacro -FeatId ([int]$c.SketchPlaneId)) +
                 "~ Command ``ProCmdFtExtrude``;" +
                 "~ Command ``ProCmdViewSketchView``;" +
                 "~ Command ``ProCmdSketRectangle`` 1;"
        Invoke-Macro "arm extrude + rectangle" $mkArm
        $c.BoxArmed = $true
        $wiz.SetChip('box', 'box: sketcher open', 'set')
        $wiz.Log('Sketcher is open in Creo - draw the rectangle, then press Next.')
        return $true   # advance to Box-B (the manual draw happens between the steps)
    }
[void]$steps.Add($boxStepA)

# Box-B: the user has drawn the rectangle in Creo (no modal blocked the wizard);
# on Next, finish the sketch + extrude up to the SIDE offset plane + blind-eval.
$boxStepB = New-WizardStep -Key 'box-b' -Title 'Finish the box' -Stage 'Box' -Kind 'run' -PrimaryText 'Finish + extrude' `
    -Validate { param($c) return [bool]$c.BoxArmed } `
    -Build {
        param($panel, $c, $wiz)
        if ($c.BoxBuilt) {
            Add-RebuiltNotice -Panel $panel -Context $c -Wizard $wiz -Message 'The box is already built.' `
                -ResetFlags @('BoxBuilt','BoxArmed') -GoToKey 'box-a'
            return
        }
        $armB = Add-ArmBanner $panel ("In Creo's sketcher, draw the plate rectangle:" + [Environment]::NewLine +
                              "To snap the second corner of the rectangle in the intersection point of the newly created planes, hold CTRL + ALT, and then select the 2 planes. " +
                              "If done correctly, there should be dotted blue lines that form the rectangle shape. " +
                              "Then draw the rectangle from corner to corner." + [Environment]::NewLine +
                              "Press Esc to finish the rectangle.") 8
        Add-Para $panel ("When the rectangle is drawn, press 'Finish + extrude' - Creo finishes the sketch and " +
                         "extrudes up to the SIDE offset plane automatically.") ($armB + 12) 0 'Gray'
    } `
    -OnNext {
        param($c, $wiz)
        if ($c.BoxBuilt) { return $true }   # idempotent: revisited after build -> don't re-extrude (no duplicate)
        $script:GuiWiz = $wiz
        # LIVE-HANDLE REBIND (fastener-import reconnect fix): read session/model/type from
        # the shared context ($c), NOT the top-level bare $session/$model. The Datums stage
        # may RECONNECT after an up-front fastener import and update $c.Session/$c.Model, but
        # a `$script:session =` write there does NOT reach a bare $session read in this OnNext
        # (proven: under the hybrid-.cmd `& ([scriptblock]::Create(...))` runtime, a sibling
        # plain-block's $script:/$global: write does not rebind another block's bare-var read;
        # only the $c hashtable, passed by reference, reliably carries the update). This makes
        # the macros below always fire into the LIVE handles; a no-op when no reconnect happened.
        if ($null -ne $c.Session) { $session = $c.Session }
        if ($null -ne $c.Model)   { $model   = $c.Model }
        if ($null -ne $c.Type)    { $pfcType = $c.Type }
        $wiz.BeginRun('Finishing the sketch + extruding...')
        $stamp = $null; try { $stamp = $model.VersionStamp } catch {}
        # MACRO B: finish the sketch, extrude up to the SIDE offset plane, confirm.
        $wiz.Log('Finishing the sketch and extruding up to the SIDE offset plane...')
        $mkFinish = "~ Command ``ProCmdSketDone``;" +
                    "~ Select ``main_dlg_cur`` ``maindashInst0.depth_flyout``;" +
                    "~ Close ``main_dlg_cur`` ``maindashInst0.depth_flyout``;" +
                    "~ Activate ``main_dlg_cur`` ``maindashInst0.toselected`` 1;" +
                    "~ Trigger ``extrev_1_placement.0.0`` ``PH.section_select_list`` ``0``;" +
                    "~ Trigger ``extrev_1_placement.0.0`` ``PH.section_select_list`` ````;" +
                    (Get-SelectDatumByIdMacro -FeatId ([int]$c.ExtrudeToId)) +
                    "~ Enter ``main_dlg_cur`` ``dashInst0.Quit``;" +
                    "~ Exit  ``main_dlg_cur`` ``dashInst0.Quit``;" +
                    "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"
        Invoke-Macro "finish + extrude + confirm" $mkFinish
        if ($null -ne $stamp) { for ($i=0; $i -lt 100; $i++) { try { if ($model.VersionStamp -ne $stamp) { break } } catch {}; Start-Sleep -Milliseconds 50 } }

        $c.BoxBuilt = $true
        # SNAPSHOT what the committed plate was sized for, so a LATER upstream change (jump
        # back to Bushing -> different OD, or edit the layout) can be DETECTED and warned about:
        # the plate + drilled holes are frozen, but $c.HoleDia / $c.OrthoGeo keep recomputing, so
        # they'd silently diverge from the committed geometry (agent-flagged C2 -- a wrong-size
        # plate makes bad hardware). The drill Build + done summary compare against these.
        $c.BuiltHoleDia = if ($null -ne $c.HoleDia) { [double]$c.HoleDia } else { $null }
        if ($null -ne $c.OrthoGeo) { $c.BuiltPlateW = [double]$c.OrthoGeo.Width; $c.BuiltPlateH = [double]$c.OrthoGeo.Height }
        $wiz.MarkCommitted()    # geometry now exists; no Back past here
        $wiz.SetChip('box', 'box: built', 'built')
        $wiz.Log('Box built.')
        return $true
    }
[void]$steps.Add($boxStepB)

# ---- STAGE: Drill -- 2.5 points + 2b corner round + 3 drill + 4 relief -----
# One RUN step does the remaining hands-free Creo work (after, optionally, a
# predefined-points hand-pick sub-step). Split so the predefined pick is armed/verified.
if ($true) {
    # predefined-points pick step (only meaningful when PointMode=predefined; it
    # self-skips by validating true + showing 'nothing to do' otherwise).
    $pickPointsStep = New-WizardStep -Key 'pickpoints' -Title 'Target datum points' -Stage 'Drill' -Kind 'pick' -PrimaryText 'Continue' `
        -Validate {
            param($c)
            if ($c.PointMode -ne 'predefined') { return $true }     # points auto-created later
            return (@($c.PointIDs).Count -ge 1)
        } `
        -Build {
            param($panel, $c, $wiz)
            if ($c.PointMode -ne 'predefined') {
                Add-Para $panel ("The {0} layout will be created automatically as datum points in the next step - nothing to pick here." -f $c.PointMode) 8 60 'Gray'
                return
            }
            $armB = Add-ArmBanner $panel ("In Creo, select the target datum points (they already exist in the part)." + [Environment]::NewLine + "Then click verify.") 8
            Add-VerifyControls -Panel $panel -Context $c -Wizard $wiz -Top ($armB + 12) -OnVerify {
                param($cc, $w)
                $r = Resolve-SelectedPointIds
                if (@($r.Ids).Count -eq 0) { return @{ Ok=$false; Message='No datum points resolved. Select datum points (or a point-bearing feature), then verify.' } }
                $cc.PointIDs = @($r.Ids)
                $w.SetChip('points', ("points: {0}" -f $cc.PointIDs.Count), 'set')
                $extra = if (@($r.Rejected).Count -gt 0) { (" ({0} non-point item(s) ignored)" -f @($r.Rejected).Count) } else { '' }
                return @{ Ok=$true; Message=("Captured {0} datum point(s).{1}" -f $cc.PointIDs.Count, $extra) }
            }
        } `
        -OnNext { param($c,$wiz) return $true }
    [void]$steps.Add($pickPointsStep)
}

$drillStep = New-WizardStep -Key 'drill' -Title 'Create points, round corners, and drill' -Stage 'Drill' -Kind 'run' -PrimaryText 'Drill the holes' `
    -Validate { param($c) return $true } `
    -Build {
        param($panel, $c, $wiz)
        if ($c.Drilled -or @($c.GridPointIDs).Count -gt 0) {
            Add-RebuiltNotice -Panel $panel -Context $c -Wizard $wiz -Message 'Points + holes are already created.' `
                -ResetFlags @('Drilled') -ResetValues @{ GridPointIDs = @(); GridPlaneIds = @(); CsysRecords = @() } -GoToKey 'drill'
            return
        }
        $n = if ($null -ne $c.OrthoGeo) { $c.OrthoGeo.Count } else { @($c.PointIDs).Count }
        $dia = if ($null -ne $c.HoleDia -and [double]$c.HoleDia -gt 0) { [double]$c.HoleDia } else { 0 }
        $msg = "Ready to drill." + [Environment]::NewLine + [Environment]::NewLine
        if ($null -ne $c.OrthoGeo) { $msg += ("- create {0} datum points from the {1} layout (3-plane intersections, no picks)" -f $c.OrthoGeo.Count, $c.OrthoGeo.Mode) + [Environment]::NewLine }
        if (-not $noCornerRound)   { $msg += ("- auto-round the box corner edges at radius {0}" -f $cornerRadius) + [Environment]::NewLine }
        $msg += ("- drill {0} through-hole(s) at diameter {1}`"" -f $n, $dia) + [Environment]::NewLine
        $msg += "- chip-relief SLOTS follow as the next step (draw one seed, then pattern)." + [Environment]::NewLine
        $y2 = (Add-Para $panel $msg 8 200 'Gray').Bottom + 6
        # STALE-PLATE WARNING (C2): the box is built to a FROZEN size. If the operator jumped
        # back and changed the bushing OD or the layout AFTER the box was built, the committed
        # plate no longer matches the current hole dia / plate footprint, but the holes below
        # WILL be drilled at the (new) $c.HoleDia into the (old) plate. Warn so they re-run
        # rather than make a mismatched jig. Only when a real divergence is detected.
        if ($c.BoxBuilt) {
            $warn = @()
            if ($null -ne $c.BuiltHoleDia -and $null -ne $c.HoleDia -and [Math]::Abs([double]$c.BuiltHoleDia - [double]$c.HoleDia) -gt 1e-6) {
                $warn += ("the hole diameter changed to {0}`" AFTER the box was built at {1}`"" -f [double]$c.HoleDia, [double]$c.BuiltHoleDia)
            }
            if ($null -ne $c.BuiltPlateW -and $null -ne $c.OrthoGeo -and ([Math]::Abs([double]$c.BuiltPlateW - [double]$c.OrthoGeo.Width) -gt 1e-6 -or [Math]::Abs([double]$c.BuiltPlateH - [double]$c.OrthoGeo.Height) -gt 1e-6)) {
                $warn += ("the layout footprint changed to {0:0.00} x {1:0.00} AFTER the box was built at {2:0.00} x {3:0.00}" -f [double]$c.OrthoGeo.Width, [double]$c.OrthoGeo.Height, [double]$c.BuiltPlateW, [double]$c.BuiltPlateH)
            }
            if ($warn.Count -gt 0) {
                Add-Para $panel (([char]0x26A0) + " WARNING: " + ($warn -join '; ') + ". The committed plate is FROZEN at the old size, so drilling now makes a MISMATCHED jig. Re-run the tool (or Rebuild the box) to resize the plate to match.") $y2 0 'warn' $true
            }
        }
    } `
    -OnNext {
        param($c, $wiz)
        if ($c.Drilled -or @($c.GridPointIDs).Count -gt 0) { return $true }   # idempotent: revisited after drilling -> don't re-create points/holes
        $script:GuiWiz = $wiz
        # LIVE-HANDLE REBIND (fastener-import reconnect fix): use $c.Session/$c.Model/$c.Type
        # (reliably updated by the Datums reconnect) instead of the bare top-level handles a
        # `$script:session =` write there can't reach. No-op when no reconnect happened.
        if ($null -ne $c.Session) { $session = $c.Session }
        if ($null -ne $c.Model)   { $model   = $c.Model }
        if ($null -ne $c.Type)    { $pfcType = $c.Type }
        $wiz.BeginRun('Drilling...')

        # ---- STAGE 2.5: create datum points from the layout ----
        if ($null -ne $c.OrthoGeo) {
            $wiz.Log(("Creating {0} datum points ({1})..." -f $c.OrthoGeo.Count, $c.OrthoGeo.Mode))
            $topBaseId   = ($c.Planes | Where-Object { $_.Label -eq 'Top'   } | Select-Object -First 1).BaseId
            $frontBaseId = ($c.Planes | Where-Object { $_.Label -eq 'Front' } | Select-Object -First 1).BaseId
            if ($c.UseCsys) {
                # csys grid: face = the SIDE default datum (the box near face); the X/Z
                # pitch planes are csys Axis_X / Axis_Z offsets. The face only sets Y=0;
                # the X/Z position comes from the csys planes, so re-placing the base csys
                # still moves every point in X/Z with it.
                $facePlaneId = if ($null -ne $c.SidePlane -and $null -ne $c.SidePlane.BaseId) { [int]$c.SidePlane.BaseId } else { $null }
                $canAutoGrid = ($null -ne $c.BaseCsysId -and $null -ne $facePlaneId)
            } else {
                $facePlaneId = if ($null -ne $c.SidePlane -and $null -ne $c.SidePlane.BaseId) { [int]$c.SidePlane.BaseId } else { $null }
                $canAutoGrid = ($null -ne $topBaseId -and $null -ne $frontBaseId -and $null -ne $facePlaneId)
            }
            if ($canAutoGrid) {
                $plan = Get-SharedPlanePlan -Points $c.OrthoGeo.Points
                $tol = 1e-6; $ok = $true
                # INDEX-FIRST: the base csys sits AT the index hole, so each grid plane is offset
                # RELATIVE to it -> Axis_X @ ((gridX-indexGridX)*flipX). The index hole's own X is
                # 0 (its point on the csys origin); others are the X margin DIFFERENCE, matching
                # the GUI layout referenced from the index hole. NON-INDEX csys mode: idx=0, flip=1
                # -> plain absolute Axis_X @ gridX off the origin base csys.
                # THE SUBTRACTION (user's spec): gate on IndexGridX being SET (an index hole was
                # chosen), NOT on $c.IndexFirst -- that flag can get reset (base-csys build) and
                # was leaving the offsets ABSOLUTE. Offset = absolute grid coord - index coord, so
                # the index hole lands at offset 0 on the csys and the others are the difference.
                $idxX = if ($null -ne $c.IndexGridX) { [double]$c.IndexGridX } else { 0.0 }
                $idxZ = if ($null -ne $c.IndexGridZ) { [double]$c.IndexGridZ } else { 0.0 }
                $fX   = if ($null -ne $c.IndexGridX) { [double]$indexFlipX } else { 1.0 }
                $fZ   = if ($null -ne $c.IndexGridZ) { [double]$indexFlipZ } else { 1.0 }
                # ---- INDEX-FIRST: RELIABLE-FRAME build off CSYS_PAT_DEF (2026-07-21 fix) ----
                # ROOT CAUSE of "scattered holes, same every run, --index-flip doesn't help" on a
                # NON-CORNER index: the pitch planes were offset off the INTERSECTED index csys at a
                # SIGNED offset (grid-index), and that csys's axis DIRECTIONS come from 3 planes'
                # normals which read NULL on this build -> its +/- orientation is not deterministic.
                # A min-corner index has all offsets >=0 (never bit); an interior index splits into
                # -cc..0..+cc and the negative-side planes resolved to the WRONG side while the +side
                # landed right -> scattered, deterministic, un-fixable by --index-flip.
                #   FIX: build every pitch plane off CSYS_PAT_DEF ($c.RefCsysId, whose axes ARE the
                # model axes) at the ABSOLUTE grid coord. Absolute ordering IS the N ordering, so a
                # hole with N>index-N lands on the +side automatically -- no negative offsets, no
                # null-normal dependency. The index's own column/row reuses its anchor plane (also off
                # CSYS_PAT_DEF, same frame). The index csys is still created AT the index hole for the
                # Index stage + export; nothing moves. Mirrors the proven non-index/legacy paths.
                $idxRefBuild = ($null -ne $c.IndexGridX -and $null -ne $c.RefCsysId)
                if ($null -ne $c.IndexGridX) {
                    # The user's N-INDEXED DIRECTIONAL CHECK, logged: N per column/row, index N, dir.
                    $dirPlan = Get-IndexDirectionalPlanePlan -Points $c.OrthoGeo.Points -IndexGridX $idxX -IndexGridZ $idxZ
                    $wiz.Log("INDEX DIRECTIONAL CHECK (N per direction; index hole = the N=IndexN column/row):")
                    $wiz.Log(("  X columns (Nx={0}, index column N={1}):" -f $dirPlan.Nx, $dirPlan.IndexNX))
                    foreach ($e in @($dirPlan.XPlanes)) {
                        $tag = if ($e.IsIndex) { "INDEX (offset 0 -> reuse anchor)" } elseif ($e.Direction -lt 0) { "- side" } else { "+ side" }
                        $wiz.Log(("    N={0} coord={1:0.###} RelN={2} dir={3} {4}" -f $e.N, $e.AbsCoord, $e.RelN, $e.Direction, $tag))
                    }
                    $wiz.Log(("  Z rows (Nz={0}, index row N={1}):" -f $dirPlan.Nz, $dirPlan.IndexNZ))
                    foreach ($e in @($dirPlan.ZPlanes)) {
                        $tag = if ($e.IsIndex) { "INDEX (offset 0 -> reuse anchor)" } elseif ($e.Direction -lt 0) { "- side" } else { "+ side" }
                        $wiz.Log(("    N={0} coord={1:0.###} RelN={2} dir={3} {4}" -f $e.N, $e.AbsCoord, $e.RelN, $e.Direction, $tag))
                    }
                    if ($idxRefBuild) {
                        $wiz.Log(("  Building pitch planes off CSYS_PAT_DEF (id {0}) at the ABSOLUTE coord (reliable model axes; --index-flip is a no-op here)." -f $c.RefCsysId))
                    } else {
                        $wiz.Log("  WARNING: no CSYS_PAT_DEF id -- falling back to the OLD index-csys-relative build (the path with the scatter bug).")
                    }
                } else {
                    $wiz.Log("(NOT index-first: grid planes use absolute offsets off the origin base csys.)")
                }
                $xPlaneIds = @()
                foreach ($xOff in $plan.XCoords) {
                    $wiz.Pump()
                    if ($c.UseCsys) {
                        # INDEX-FIRST RELIABLE-FRAME build: off CSYS_PAT_DEF at the ABSOLUTE coord.
                        if ($idxRefBuild) {
                            # index's own column (coord == index coord) -> reuse the X anchor plane
                            # (already off CSYS_PAT_DEF at the index coord: same frame, no new plane).
                            if ($null -ne $c.IndexAnchorX -and [math]::Abs([double]$xOff - $idxX) -le $tol) { $xPlaneIds += [int]$c.IndexAnchorX; continue }
                            $res = New-CsysOffsetPlane -CsysFeatId $c.RefCsysId -Axis 'X' -Offset ([double]$xOff) -SkipSymbolWait
                            if ($null -eq $res.FeatId) { $ok = $false; break }
                            $xPlaneIds += [int]$res.FeatId
                            continue
                        }
                        # NON-INDEX csys mode (or the RefCsysId-missing fallback): off the base csys.
                        $xEff = ([double]$xOff - $idxX) * $fX
                        # INDEX hole's own column (relative offset ~0): REUSE the X anchor plane
                        # that built the index csys (at model-X = indexX) -> a row of N makes N-1
                        # new planes, not N. Only in index-first mode (anchor captured in box-a).
                        if ($null -ne $c.IndexAnchorX -and [math]::Abs($xEff) -le $tol) { $xPlaneIds += [int]$c.IndexAnchorX; continue }
                        $res = New-CsysOffsetPlane -CsysFeatId $c.BaseCsysId -Axis 'X' -Offset $xEff -SkipSymbolWait
                        if ($null -eq $res.FeatId) { $ok = $false; break }
                        $xPlaneIds += [int]$res.FeatId
                    } else {
                        if ([math]::Abs([double]$xOff) -le $tol) { $xPlaneIds += [int]$topBaseId; continue }
                        $res = New-OffsetPlane -Label "X$($xPlaneIds.Count)" -Offset ([double]$xOff) -BaseId ([int]$topBaseId) -SkipSymbolWait
                        if ($null -eq $res.FeatId) { $ok = $false; break }
                        $xPlaneIds += [int]$res.FeatId
                    }
                }
                $zPlaneIds = @()
                if ($ok) {
                    foreach ($zOff in $plan.ZCoords) {
                        $wiz.Pump()
                        if ($c.UseCsys) {
                            # INDEX-FIRST RELIABLE-FRAME build: off CSYS_PAT_DEF at the ABSOLUTE coord.
                            if ($idxRefBuild) {
                                if ($null -ne $c.IndexAnchorZ -and [math]::Abs([double]$zOff - $idxZ) -le $tol) { $zPlaneIds += [int]$c.IndexAnchorZ; continue }
                                $res = New-CsysOffsetPlane -CsysFeatId $c.RefCsysId -Axis 'Z' -Offset ([double]$zOff) -SkipSymbolWait
                                if ($null -eq $res.FeatId) { $ok = $false; break }
                                $zPlaneIds += [int]$res.FeatId
                                continue
                            }
                            # NON-INDEX csys mode (or fallback): off the base csys.
                            $zEff = ([double]$zOff - $idxZ) * $fZ
                            # INDEX hole's own row (relative offset ~0): REUSE the Z anchor plane.
                            if ($null -ne $c.IndexAnchorZ -and [math]::Abs($zEff) -le $tol) { $zPlaneIds += [int]$c.IndexAnchorZ; continue }
                            $res = New-CsysOffsetPlane -CsysFeatId $c.BaseCsysId -Axis 'Z' -Offset $zEff -SkipSymbolWait
                            if ($null -eq $res.FeatId) { $ok = $false; break }
                            $zPlaneIds += [int]$res.FeatId
                        } else {
                            if ([math]::Abs([double]$zOff) -le $tol) { $zPlaneIds += [int]$frontBaseId; continue }
                            $res = New-OffsetPlane -Label "Z$($zPlaneIds.Count)" -Offset ([double]$zOff) -BaseId ([int]$frontBaseId) -SkipSymbolWait
                            if ($null -eq $res.FeatId) { $ok = $false; break }
                            $zPlaneIds += [int]$res.FeatId
                        }
                    }
                }
                if ($ok) {
                    # Skip reused base datums (legacy) AND reused index anchor planes (csys index column/row) -- not NEW offset planes.
                    for ($qi=0; $qi -lt $xPlaneIds.Count; $qi++) { if ([int]$xPlaneIds[$qi] -ne [int]$topBaseId -and ($null -eq $c.IndexAnchorX -or [int]$xPlaneIds[$qi] -ne [int]$c.IndexAnchorX)) { $c.GridPlaneIds += [pscustomobject]@{ FeatId=[int]$xPlaneIds[$qi]; Axis='X'; Offset=[double]$plan.XCoords[$qi] } } }
                    for ($qi=0; $qi -lt $zPlaneIds.Count; $qi++) { if ([int]$zPlaneIds[$qi] -ne [int]$frontBaseId -and ($null -eq $c.IndexAnchorZ -or [int]$zPlaneIds[$qi] -ne [int]$c.IndexAnchorZ)) { $c.GridPlaneIds += [pscustomobject]@{ FeatId=[int]$zPlaneIds[$qi]; Axis='Z'; Offset=[double]$plan.ZCoords[$qi] } } }
                    # ORIGINAL point-creation loop: fires ONLY the creation macros, no
                    # COM reads between them. The index-csys registry is built AFTER the
                    # loop (post-processing), so it cannot affect point creation.
                    $beforePts = Get-PointIdSet -Model $model -TypeObj $pfcType
                    $pi = 0
                    foreach ($tri in $plan.Triples) {
                        $pi++
                        $wiz.SetProgress([Math]::Floor(($pi / $c.OrthoGeo.Count) * 100), ("point $pi / $($c.OrthoGeo.Count)"))
                        $macro = Build-IntersectPointMacro -PlaneIds @([int]$facePlaneId, [int]$xPlaneIds[$tri.Xi], [int]$zPlaneIds[$tri.Zi])
                        try { $session.RunMacro($macro) } catch { $ok = $false; break }
                    }
                    $newIds = Resolve-NewPointIds -Model $model -TypeObj $pfcType -Before $beforePts
                    if (@($newIds).Count -ge 1) { $c.GridPointIDs = @($newIds) }
                    # INDEX-CSYS REGISTRY (post-processing; does NOT touch point creation):
                    # creation-order zip (sorted new point ids <-> $plan.Triples). PLANE
                    # ORDER = X-normal (X-offset plane, from TOP), Y-normal (SIDE face),
                    # Z-normal (Z-offset plane, from FRONT) -- the order ProCmdDatumCsys
                    # assigns axes from. See drilljig.cmd for the full rationale.
                    if (@($newIds).Count -eq @($plan.Triples).Count) {
                        $c.CsysRecords = @()
                        for ($k = 0; $k -lt $newIds.Count; $k++) {
                            $t2 = $plan.Triples[$k]
                            $c.CsysRecords += [pscustomobject]@{ PointId=[int]$newIds[$k]; HoleFeatId=$null; PlaneIds=@([int]$xPlaneIds[$t2.Xi], [int]$facePlaneId, [int]$zPlaneIds[$t2.Zi]); GridX=[double]$t2.X; GridZ=[double]$t2.Z }
                        }
                    }
                    if (@($newIds).Count -ne $c.OrthoGeo.Count) { $wiz.Log(("Point count: wanted {0}, got {1}." -f $c.OrthoGeo.Count, @($newIds).Count)) }
                }
                if ($c.GridPointIDs.Count -gt 0) {
                    $wiz.MarkCommitted()
                    try { $model.Regenerate($null) } catch {}
                    $wiz.SetChip('points', ("points: {0} created" -f $c.GridPointIDs.Count), 'built')
                } else {
                    $wiz.SetChip('points', 'points: creation failed', 'aborted')
                }
            }
        }

        # resolve the point id list for drilling
        if ($c.GridPointIDs.Count -gt 0) { $c.PointIDs = @($c.GridPointIDs) }
        if (@($c.PointIDs).Count -eq 0) {
            $wiz.Log('No points to drill - aborting drill.')
            $wiz.SetChip('drill', 'drill: no points', 'aborted')
            return $true   # advance to summary; nothing drilled
        }

        # body index
        $c.BodyIndex = 0
        $c.HoleDiaFinal = if ($null -ne $c.HoleDia -and [double]$c.HoleDia -gt 0) { [double]$c.HoleDia } else { 0.25 }

        # ---- STAGE 2b: auto corner round ----
        if (-not $noCornerRound) {
            $wiz.Log(("Auto-rounding box corner edges at radius {0}..." -f $cornerRadius))
            try {
                $cr = Invoke-AutoCornerRound -Session $session -Model $model -TypeObj $pfcType -Radius $cornerRadius
                $wiz.Log(("  corners: found $($cr.Found), matched $($cr.Matched)."))
                if ($cr.Matched -gt 0 -and $cr.TotalBatches -gt 0 -and $cr.ModelChanged -eq $cr.TotalBatches) { $wiz.SetChip('corners', 'corners: rounded', 'built') }
                elseif ($cr.Matched -eq 0) { $wiz.SetChip('corners', 'corners: none', 'warning') }
                else { $wiz.SetChip('corners', 'corners: check Creo', 'unverified') }
            } catch { $wiz.Log("  corner round error: $($_.Exception.Message)") }
        }

        # ---- STAGE 3: drill through holes ----
        # ORIGINAL drill loop: fires ONLY the hole macros, no COM reads between them.
        # The index-csys hole->point tie is done OUTSIDE the loop (one diff below), so
        # hole creation is untouched.
        $wiz.Log(("Drilling {0} through-hole(s) at diameter {1}..." -f @($c.PointIDs).Count, $c.HoleDiaFinal))
        $total = @($c.PointIDs).Count; $idx=0; $made=0; $noop=0; $failed=0; $aborted=$false
        $beforeDrillFeat = if (@($c.CsysRecords).Count -gt 0) { Get-FeatureIdSet } else { $null }
        foreach ($ptId in $c.PointIDs) {
            $idx++
            $wiz.SetProgress([Math]::Floor(($idx/$total)*100), ("hole $idx / $total"))
            $surfId = 0
            if ($c.GridPointIDs.Count -gt 0 -and $null -ne $c.SidePlane -and $null -ne $c.SidePlane.FeatId) { $surfId = [int]$c.SidePlane.FeatId }
            $macro = Build-HoleMacro -PointId $ptId -Diameter $c.HoleDiaFinal -BodyIndex $c.BodyIndex -SurfacePlaneId $surfId
            $changed = $false
            try { $stamp = $model.VersionStamp; $session.RunMacro($macro); $changed = Wait-ModelModified -Model $model -PreviousStamp $stamp -OnPoll { try { [System.Windows.Forms.Application]::DoEvents() } catch {} } } catch { $failed++ }
            if ($changed) { $made++ } else { $noop++ }
            if ($idx -eq 1 -and -not $changed) {
                $wiz.Log('ABORT: the first hole did not modify the model (canary). Check Creo.')
                $aborted = $true; break
            }
        }
        $c.Drilled = ($made -gt 0)
        # index-csys hole->point tie (outside the loop): one diff + creation-order groups
        # (a hole may add an axis/note, so match a GROUP per hole - see Resolve-HoleFeatGroups).
        if ($null -ne $beforeDrillFeat -and -not $aborted -and $made -gt 0) {
            $afterDrillFeat = Get-FeatureIdSet
            $newDrillFeats  = @($afterDrillFeat.Keys | Where-Object { -not $beforeDrillFeat.ContainsKey($_) } | Sort-Object)
            $grp = Resolve-HoleFeatGroups -NewFeatIds $newDrillFeats -HoleCount @($c.PointIDs).Count
            if ($grp.Ok) {
                for ($k = 0; $k -lt @($c.PointIDs).Count; $k++) {
                    $rec = $c.CsysRecords | Where-Object { $null -ne $_.PointId -and [int]$_.PointId -eq [int]$c.PointIDs[$k] } | Select-Object -First 1
                    if ($null -ne $rec) {
                        $rec.HoleFeatId = [int]$grp.Groups[$k][0]
                        try { $rec | Add-Member -NotePropertyName HoleFeatIds -NotePropertyValue @($grp.Groups[$k]) -Force } catch {}
                    }
                }
                $wiz.Log(("Index-csys: {0} hole(s) tied to their points ({1} feature(s) each)." -f @($c.PointIDs).Count, $grp.PerHole))
            } else {
                $wiz.Log(("Index-csys: hole->point tie skipped ({0}); click the datum POINT for the index csys." -f $grp.Reason))
            }
        }
        if ($aborted) { $wiz.SetChip('drill', 'drill: aborted', 'aborted') }
        elseif ($made -eq $total -and $failed -eq 0) { $wiz.SetChip('drill', ("drill: {0} holes" -f $made), 'built') }
        else { $wiz.SetChip('drill', ("drill: {0}/{1}" -f $made, $total), 'unverified') }
        $wiz.Log(("Through-holes: {0} of {1} changed the model." -f $made, $total))
        # Chip-relief SLOTS are a SEPARATE stage (slot-a / slot-b) after this one,
        # since the seed slot needs a manual rectangle DRAW (a RunMacro can't draw) -
        # the same arm/finish split the box build uses. See below.
        return $true
    }
[void]$steps.Add($drillStep)

# ---- STAGE: Relief -- chip-relief SLOTS (slotinator method) -----------------
# Replaces the old relief holes + relief paths with ONE blind rectangular slot per
# hole ROW (length = part length, width = hole dia, depth = % of thickness), seed-
# drawn once then patterned along a base datum plane's normal. Split into slot-a
# (arm the seed sketch) + slot-b (finish the cut, verify direction, pattern) exactly
# like box-a/box-b, because the seed rectangle is a manual DRAW a RunMacro can't do.
# Reuses ONLY context already gathered: hole dia ($c.HoleDiaFinal), plate thickness
# (live SIDE offset), layout ($c.OrthoGeo), datums ($c.Made/$c.SidePlane), body.
# Needs a GUI layout; PREDEFINED points have no rows -> the stage skips itself.
$slotArmStep = New-WizardStep -Key 'slot-a' -Title 'Chip-relief slots: draw the seed' -Stage 'Relief' -Kind 'run' -PrimaryText 'Open the seed sketch' `
    -Validate { param($c) return $true } `
    -Build {
        param($panel, $c, $wiz)
        if ($noSlotRelief) { Add-Para $panel "Chip-relief slots are disabled (--no-slot-relief). Press Next to finish." 8 60 'gray'; return }
        if ($null -eq $c.OrthoGeo) { Add-Para $panel ("No grid/custom layout was entered (predefined points). Chip-relief slots group holes into rows from the layout, so they need an orthogrid/custom run. Press Next to skip.") 8 60 'gray'; return }
        if ($c.SlotArmed) {
            $yA = (Add-Para $panel ("The seed sketcher is open in Creo. Draw ONE rectangle over the first hole row, then press Next.") 8 60 'DarkGreen' $true).Bottom + 8
            if ($c.SlotHasPlanes) {
                Add-Para $panel ("To snap the rectangular chip-relief slot in place, hold both CTRL + ALT, then click the two planes spanning across the LENGTH of the part (X direction) and also the RIGHT-SIDE EDGE of the drill jig. If done correctly, dotted blue lines will form the rectangle shape. Then snap the corners of the rectangle tool onto each corner.") $yA 0 'Gray'
            }
            return
        }
        $slotW = if ($null -ne $c.HoleDiaFinal -and [double]$c.HoleDiaFinal -gt 0) { [double]$c.HoleDiaFinal } elseif ($null -ne $c.HoleDia) { [double]$c.HoleDia } else { 0 }
        $gate = if ($c.WillSlot -eq $false) { 'not adding (decided earlier)' } elseif ($c.Is3dPrint) { 'added automatically (3D print)' } else { 'confirmed earlier' }
        # show the depth that will ACTUALLY be cut = the pad baked into the plate ($c.ReliefPad),
        # not the (possibly re-edited) $c.SlotDepth -- so the display matches the geometry.
        $shownDepth = if ([double]$c.ReliefPad -gt 0) { [double]$c.ReliefPad } else { [double]$c.SlotDepth }
        $y = (Add-Para $panel ("One blind rectangular slot per hole ROW: length = part length, width = the hole diameter ({0}`"), depth = {1}`" (the plate was padded by this so the final guide depth = the bushing length after the cut). Draw ONE seed slot; the rest are patterned. Chip relief: {2}." -f $slotW, $shownDepth, $gate) 8 0 'Gray').Bottom + 10
        Add-Para $panel "Press the button: Creo opens the sketcher on the SIDE face; then draw the seed rectangle over the first hole row." $y 0 'Gray'
    } `
    -OnNext {
        param($c, $wiz)
        if ($c.SlotArmed) { return $true }   # armed already (came back) -> advance to slot-b
        $script:GuiWiz = $wiz
        # RELIEF DECISION was made UP FRONT in box-a ($c.WillSlot) so the extrude could be
        # padded; REUSE it here (do NOT re-ask -- a second, different answer would leave the
        # plate padded-but-uncut, or unpadded-but-cut). Falls back to the old gate only if
        # box-a somehow never ran (WillSlot still $null).
        if ($noSlotRelief -or $null -eq $c.OrthoGeo) { $c.SlotSkip = $true; $wiz.SetChip('slots', 'slots: skipped', 'set'); return $true }
        if ($null -eq $c.WillSlot) {
            if (-not $c.Is3dPrint) {
                $ans = $wiz.AskInline('Chip-relief slots', 'Add chip-relief slots (one per hole row)?', 'YesNo')
                $c.WillSlot = ($ans -eq 'Yes')
            } else { $c.WillSlot = $true }
        }
        if (-not $c.WillSlot) { $c.SlotSkip = $true; $wiz.SetChip('slots', 'slots: skipped', 'set'); return $true }
        # compute the slot plan from the SAME layout the holes came from. Direction from
        # the 'slot-dir' step ($c.SlotRowAxis): 'X' for orthogrid/custom, or the operator's
        # X/Z choice for an imported fastener layout (defaults to 'X' if the step was skipped).
        # CrossAxis + the direction datum below derive from it, so a 'Z' pick flows through.
        $slotW = if ($null -ne $c.HoleDiaFinal -and [double]$c.HoleDiaFinal -gt 0) { [double]$c.HoleDiaFinal } else { 0.25 }
        $rowAx = if ($c.SlotRowAxis -eq 'Z') { 'Z' } else { 'X' }
        $slots = Get-RowSlots -Points $c.OrthoGeo.Points -SlotWidth $slotW -Width $c.OrthoGeo.Width -Height $c.OrthoGeo.Height -RowAxis $rowAx
        if (-not $slots.Valid -or @($slots.Rows).Count -lt 1) {
            $wiz.Log('The layout produced no valid slot rows - skipping chip-relief slots.')
            $c.SlotSkip = $true; $wiz.SetChip('slots', 'slots: skipped', 'warning'); return $true
        }
        $sSide = @($c.Made | Where-Object { $_.Label -eq 'Side' }); $sSide = if ($sSide.Count -gt 0) { $sSide[0] } else { $null }
        # slot depth = the pad THAT WAS ACTUALLY BAKED INTO THE PLATE ($c.ReliefPad), NOT
        # the still-editable $c.SlotDepth. box-a froze ReliefPad = SlotDepth into the SIDE
        # offset plane (plate = bushingLen + ReliefPad) exactly once; but the wizard's
        # interwoven navigation lets the operator jump BACK to the slot-depth step and
        # re-edit $c.SlotDepth AFTER the box is built (box-a then short-circuits, so the
        # plate keeps the OLD pad). Cutting the NEW SlotDepth would leave the guide
        # bushingLen + (old - new) -- oversized. Cutting the frozen ReliefPad instead makes
        # plate(bushingLen + ReliefPad) - slot(ReliefPad) == bushingLen by construction.
        # Fall back to SlotDepth only in the degenerate ReliefPad==0 case (no pad applied).
        $slotDepth = if ([double]$c.ReliefPad -gt 0) { [double]$c.ReliefPad } else { [double]$c.SlotDepth }
        # sketch face = the SIDE default datum (the box near face, in BOTH modes: the
        # csys box also sketches on the SIDE datum, so the slot cut into that same face
        # sketches there too). Direction datum from the march axis below.
        $faceId = if ($null -ne $c.SidePlane -and $null -ne $c.SidePlane.BaseId) { [int]$c.SidePlane.BaseId } else { $null }
        $frontB = @($c.Made | Where-Object { $_.Label -eq 'Front' }); $frontB = if ($frontB.Count -gt 0) { $frontB[0] } else { $null }
        $topB   = @($c.Made | Where-Object { $_.Label -eq 'Top' });   $topB   = if ($topB.Count -gt 0) { $topB[0] } else { $null }
        $dirId = $null; $dirName = $null
        if ($slots.CrossAxis -eq 'Z') { if ($null -ne $frontB -and $null -ne $frontB.BaseId) { $dirId = [int]$frontB.BaseId; $dirName='FRONT' } }
        else                          { if ($null -ne $topB   -and $null -ne $topB.BaseId)   { $dirId = [int]$topB.BaseId;   $dirName='TOP' } }
        if ($null -eq $faceId) {
            $wiz.Log('The SIDE datum was not captured - cannot sketch the slots. Skipping.')
            $c.SlotSkip = $true; $wiz.SetChip('slots', 'slots: skipped', 'warning'); return $true
        }
        # SINGLE SEED, MANY PATTERNS (user 2026-07-23: "you dont actually need to do a 2nd
        # seed sketch. just do as many patterns until all rows have a slot"). Draw ONE seed
        # slot (the lowest-cross row); every OTHER row is reached by patterning THAT SAME
        # seed again (the user confirmed re-patterning yields a "new sketch + new slot" on
        # this build). Get-SlotSeedPatterns decomposes the other rows into arithmetic-from-
        # seed groups -> one ProCmdGeomPattern per group. Manual draws = 1 (always).
        $canPattern = (-not $slotNoPattern -and $null -ne $dirId)
        $c.SlotRunIndex = 0
        $c.SlotAnyCut   = $false
        $c.SlotWarn     = $false
        $c.SeedCut      = $false
        $c.SlotFlip     = $slotFlipDefault
        if ($canPattern) {
            $seedPlan = Get-SlotSeedPatterns -Rows $slots.Rows
            $c.SlotPlan = @{ Mode='pattern'; SeedRow=$seedPlan.SeedRow; Patterns=@($seedPlan.Patterns)
                             SlotWidth=$slots.SlotWidth; RowAxis=$slots.RowAxis; CrossAxis=$slots.CrossAxis
                             Depth=$slotDepth; FaceId=$faceId; DirDatumId=$dirId; DirName=$dirName }
            $wiz.Log(("{0}" -f $seedPlan.Reason))
            $guideRows = @($seedPlan.SeedRow)      # only the seed is drawn -> guide the seed
        } else {
            # PER-ROW fallback (--no-pattern, or no TOP/FRONT direction datum): no patterning
            # available, so every row is drawn by hand (the pre-multi-pattern behavior).
            $c.SlotPlan = @{ Mode='perrow'; SeedRow=$slots.Rows[0]; Rows=@($slots.Rows)
                             SlotWidth=$slots.SlotWidth; RowAxis=$slots.RowAxis; CrossAxis=$slots.CrossAxis
                             Depth=$slotDepth; FaceId=$faceId; DirDatumId=$dirId; DirName=$dirName }
            $reasonWhy = if ($slotNoPattern) { '--no-pattern' } else { "no $dirName direction datum" }
            $wiz.Log(("Patterning off ({0}) - each of the {1} row(s) will be drawn by hand." -f $reasonWhy, @($slots.Rows).Count))
            $guideRows = @($slots.Rows)            # every row is drawn -> guide them all
        }
        $wiz.BeginRun('Creating slot-edge guide planes + opening the seed sketcher...')
        # GUIDE PLANES: the slot-edge datum planes slotinator makes, so the operator draws
        # the seed rectangle to the right size. Pattern mode draws ONLY the seed, so guide
        # just the seed row; per-row mode guides every row. Needs the TOP + FRONT bases.
        $topBaseIdN   = if ($null -ne $topB   -and $null -ne $topB.BaseId)   { [int]$topB.BaseId }   else { 0 }
        $frontBaseIdN = if ($null -ne $frontB -and $null -ne $frontB.BaseId) { [int]$frontB.BaseId } else { 0 }
        $c.SlotHasPlanes = $false
        if ($topBaseIdN -gt 0 -and $frontBaseIdN -gt 0) {
            $wiz.Log('Creating the slot-edge guide planes (draw references)...')
            $gp = New-SlotGuidePlanes -Rows $guideRows -TopBaseId $topBaseIdN -FrontBaseId $frontBaseIdN -Log { param($m) $wiz.Log($m) }
            if (@($gp.Ids).Count -gt 0) { $c.SlotHasPlanes = $true; $wiz.Log(("{0} slot-edge guide plane(s) created + shown." -f @($gp.Ids).Count)) }
            else { $wiz.Log('No new guide planes needed (edges lie on base datums).') }
        } else {
            $wiz.Log('TOP/FRONT base datums not both captured - skipping guide planes (draw freehand).')
        }
        # ARM the seed sketch (open extrude on the SIDE face + rectangle tool)
        $mkArm = (Get-SelectByIdMacro -FeatId ([int]$faceId)) + "~ Command ``ProCmdFtExtrude``;" + "~ Command ``ProCmdViewSketchView``;" + "~ Command ``ProCmdSketRectangle`` 1;"
        Invoke-Macro "arm seed slot sketch" $mkArm
        $c.SlotArmed = $true
        if ($c.SlotPlan.Mode -eq 'pattern') {
            $np = @($c.SlotPlan.Patterns).Count
            $wiz.SetChip('slots', 'slots: seed armed', 'set')
            $wiz.Log(("Seed slot sketcher open ({0} row(s), width {1}, depth {2}). Draw the ONE seed rectangle; {3} pattern(s) then cover the rest hands-free. Press Next." -f @($slots.Rows).Count, $slots.SlotWidth, $(if ($slotDepth -gt 0) { $slotDepth } else { 'Creo default' }), $np))
        } else {
            $wiz.SetChip('slots', ("slots: row 1/{0}" -f @($slots.Rows).Count), 'set')
            $wiz.Log(("Seed slot sketcher open ({0} row(s), width {1}, depth {2}). Draw each row's rectangle. Press Next." -f @($slots.Rows).Count, $slots.SlotWidth, $(if ($slotDepth -gt 0) { $slotDepth } else { 'Creo default' })))
        }
        return $true
    }
[void]$steps.Add($slotArmStep)

# slot-b: the user drew the seed rectangle; finish the cut, verify direction, then
# pattern the seed to the remaining rows (hands-free, datum-by-ID). Wrong direction
# -> undo + flip + re-arm the sketcher + stay so the operator redraws (mirrors the
# console Invoke-VerifiedSeedCut loop, adapted to the wizard).
$slotFinishStep = New-WizardStep -Key 'slot-b' -Title 'Chip-relief slots: cut + pattern' -Stage 'Relief' -Kind 'run' -PrimaryText 'Finish the seed slot' `
    -Validate { param($c) return [bool]($c.SlotArmed -or $c.SlotSkip) } `
    -Build {
        param($panel, $c, $wiz)
        if ($c.SlotsDone) {
            Add-RebuiltNotice -Panel $panel -Context $c -Wizard $wiz -Message 'Chip-relief slots are already cut.' `
                -ResetFlags @('SlotsDone','SlotArmed','SeedCut') -ResetValues @{ SlotRunIndex = 0; SlotAnyCut = $false; SlotWarn = $false } -GoToKey 'slot-a'
            return
        }
        if ($c.SlotSkip) { Add-Para $panel "Chip-relief slots were skipped. Press Next to finish." 8 60 'gray'; return }
        # mode-aware banner. PATTERN mode: draw ONE seed, patterns cover the rest.
        # PER-ROW mode: draw every row (which one is next).
        $mode = if ($null -ne $c.SlotPlan) { [string]$c.SlotPlan.Mode } else { 'pattern' }
        if ($mode -eq 'perrow') {
            $rTotB = if ($null -ne $c.SlotPlan) { @($c.SlotPlan.Rows).Count } else { 1 }
            $rNowB = [int]$c.SlotRunIndex + 1
            $armB = Add-ArmBanner $panel ("In Creo's sketcher: draw the slot rectangle for ROW $rNowB of $rTotB over its hole row (one corner, opposite corner), Esc to finish." + [Environment]::NewLine +
                                  "Then press 'Finish the seed slot' - Creo cuts it$(if ($rNowB -eq 1) { ', you confirm the direction' } else { '' }). Each row is drawn (patterning is off).") 8
        } else {
            $np = if ($null -ne $c.SlotPlan) { @($c.SlotPlan.Patterns).Count } else { 0 }
            $armB = Add-ArmBanner $panel ("In Creo's sketcher: draw the ONE seed rectangle over the first hole row (one corner, opposite corner), Esc to finish." + [Environment]::NewLine +
                                  "Then press 'Finish the seed slot' - Creo cuts it, you confirm the direction, then $np pattern(s) copy it onto every remaining row hands-free (you'll click the seed in the tree once per pattern - no more drawing).") 8
        }
        if ($c.SlotHasPlanes) {
            Add-Para $panel ("To snap the rectangular chip-relief slot in place, hold both CTRL + ALT, then click the two planes spanning across the LENGTH of the part (X direction) and also the RIGHT-SIDE EDGE of the drill jig. If done correctly, dotted blue lines will form the rectangle shape. Then snap the corners of the rectangle tool onto each corner.") ($armB + 12) 0 'Gray'
        }
    } `
    -OnNext {
        param($c, $wiz)
        if ($c.SlotsDone) { return $true }   # idempotent: revisited after the cut -> don't re-cut (no duplicate)
        if ($c.SlotSkip) { return $true }
        $script:GuiWiz = $wiz
        # LIVE-HANDLE REBIND (fastener-import reconnect fix): use $c.Session/$c.Model (reliably
        # updated by the Datums reconnect) instead of the bare top-level handles a `$script:session =`
        # write there can't reach. No-op when no reconnect happened.
        if ($null -ne $c.Session) { $session = $c.Session }
        if ($null -ne $c.Model)   { $model   = $c.Model }
        if ($null -ne $c.Type)    { $pfcType = $c.Type }
        $plan = $c.SlotPlan
        # DEFENSIVE (SUSPECTED S1): slot-b's Validate admits SlotArmed OR SlotSkip, but only
        # slot-a's OnNext sets $c.SlotPlan. If a future path sets SlotArmed without SlotPlan,
        # $plan would be $null and the cut below would throw on $plan.Depth. Guard it.
        if ($null -eq $plan) {
            $wiz.Log('Slot plan missing (slot-a did not run) - skipping chip-relief slots.')
            $wiz.SetChip('slots', 'slots: skipped', 'warning')
            return $true
        }
        $armMacro = (Get-SelectByIdMacro -FeatId ([int]$plan.FaceId)) + "~ Command ``ProCmdFtExtrude``;" + "~ Command ``ProCmdViewSketchView``;" + "~ Command ``ProCmdSketRectangle`` 1;"

        if ([string]$plan.Mode -eq 'perrow') {
            # ---- PER-ROW mode (--no-pattern / no direction datum): draw EVERY row. ----
            # One pass per row: cut this row's seed, verify direction on row 0 only (reuse
            # the flip), then advance -> re-arm the next row + return $false (stay), or finish.
            $rows = @($plan.Rows)
            $rn   = [int]$c.SlotRunIndex
            $rTot = @($rows).Count
            if ($rn -ge $rTot) { $c.SlotsDone = $true; $wiz.MarkCommitted(); return $true }
            $wiz.BeginRun(("Cutting slot row {0}/{1}..." -f ($rn + 1), $rTot))
            $stamp = $null; try { $stamp = $model.VersionStamp } catch {}
            $changed = $false
            try {
                $session.RunMacro((Build-CutFinishMacro -Depth ([double]$plan.Depth) -BodyIndex ([int]$c.BodyIndex) -Flip $c.SlotFlip))
                if ($null -ne $stamp) { $changed = Wait-ModelModified -Model $model -PreviousStamp $stamp -OnPoll { try { [System.Windows.Forms.Application]::DoEvents() } catch {} } }
            } catch { $wiz.Log("  row cut error: $($_.Exception.Message)") }
            if (-not $changed) {
                $wiz.Log(("Row {0}/{1} did not cut (rectangle not a closed loop?) - reopening the sketcher to redraw." -f ($rn + 1), $rTot))
                Invoke-Macro "re-arm slot row sketch (no change)" $armMacro
                $wiz.SetChip('slots', ("slots: row {0}/{1} redraw" -f ($rn + 1), $rTot), 'unverified')
                [void]$wiz.AskInline('Chip-relief slots', ("The slot did not cut. The sketcher is reopened - redraw row {0}/{1}'s rectangle, then press 'Finish the seed slot' again." -f ($rn + 1), $rTot), 'OK', $true)
                return $false
            }
            if ($rn -eq 0) {
                $ans = $wiz.AskInline('Verify slot', 'Did the slot cut INTO the plate at the right depth?', 'YesNo')
                if ($ans -ne 'Yes') {
                    $wiz.Log('Wrong direction - undoing, flipping, and reopening the sketcher to redraw.')
                    try { $session.RunMacro("~ Command ``ProCmdEditUndo``;") } catch {}
                    $c.SlotFlip = -not $c.SlotFlip
                    Invoke-Macro "re-arm slot row sketch (flipped)" $armMacro
                    $wiz.SetChip('slots', 'slots: redraw', 'unverified')
                    [void]$wiz.AskInline('Chip-relief slots', ("Flipped the direction and reopened the sketcher. If the wrong slot is still in Creo, press Ctrl+Z. Redraw the rectangle, then press 'Finish the seed slot' again."), 'OK', $true)
                    return $false
                }
                $wiz.Log('Direction confirmed - reusing it for the remaining rows.')
            }
            $c.SlotAnyCut = $true
            $c.SlotRunIndex = $rn + 1
            if ($c.SlotRunIndex -lt $rTot) {
                $nextN = $c.SlotRunIndex + 1
                Invoke-Macro ("arm slot row sketch (row $nextN)") $armMacro
                $wiz.SetChip('slots', ("slots: row {0}/{1}" -f $nextN, $rTot), 'set')
                [void]$wiz.AskInline('Chip-relief slots', ("Row {0}/{1} done. The sketcher is reopened for row {2}/{1} - draw its rectangle over the next hole row, then press 'Finish the seed slot' again." -f ($rn + 1), $rTot, $nextN), 'OK', $true)
                return $false
            }
            $wiz.SetChip('slots', ("slots: {0} row(s) cut" -f $rTot), 'built')
            $c.SlotsDone = $true; $wiz.MarkCommitted(); return $true
        }

        # ---- PATTERN mode: ONE seed, then many patterns (user 2026-07-23). ----
        # Step 1 (once): cut the seed the operator drew + verify direction. Step 2: fire ALL
        # the from-seed patterns inline -- each re-selects the SAME seed in the tree (FIX 1:
        # a search-buffer select does NOT register as a pattern target) and fires one
        # ProCmdGeomPattern. Re-patterning the seed makes a "new sketch + new slot" (operator-
        # confirmed on this build). No 2nd seed is ever drawn.
        if (-not $c.SeedCut) {
            $wiz.BeginRun('Cutting the seed slot...')
            $stamp = $null; try { $stamp = $model.VersionStamp } catch {}
            $changed = $false
            try {
                $session.RunMacro((Build-CutFinishMacro -Depth ([double]$plan.Depth) -BodyIndex ([int]$c.BodyIndex) -Flip $c.SlotFlip))
                if ($null -ne $stamp) { $changed = Wait-ModelModified -Model $model -PreviousStamp $stamp -OnPoll { try { [System.Windows.Forms.Application]::DoEvents() } catch {} } }
            } catch { $wiz.Log("  seed cut error: $($_.Exception.Message)") }
            if (-not $changed) {
                $wiz.Log('The seed slot cut did not modify the model (rectangle not a closed loop?) - reopening the sketcher to redraw.')
                Invoke-Macro "re-arm seed slot sketch (no change)" $armMacro
                $wiz.SetChip('slots', 'slots: seed redraw', 'unverified')
                [void]$wiz.AskInline('Chip-relief slots', ("The seed slot did not cut (the rectangle may not have been a closed loop). The sketcher is reopened - redraw the seed rectangle, then press 'Finish the seed slot' again."), 'OK', $true)
                return $false
            }
            $ans = $wiz.AskInline('Verify slot', 'Did the seed slot cut INTO the plate at the right depth?', 'YesNo')
            if ($ans -ne 'Yes') {
                $wiz.Log('Wrong direction - undoing, flipping, and reopening the sketcher to redraw.')
                try { $session.RunMacro("~ Command ``ProCmdEditUndo``;") } catch {}
                $c.SlotFlip = -not $c.SlotFlip
                Invoke-Macro "re-arm seed slot sketch (flipped)" $armMacro
                $wiz.SetChip('slots', 'slots: seed redraw', 'unverified')
                [void]$wiz.AskInline('Chip-relief slots', ("Flipped the direction and reopened the sketcher. If the wrong slot is still in Creo, press Ctrl+Z. Redraw the seed rectangle, then press 'Finish the seed slot' again."), 'OK', $true)
                return $false
            }
            $c.SeedCut = $true
            $c.SlotAnyCut = $true
            $wiz.Log('Seed slot confirmed - patterning it onto every remaining row (no more drawing).')
        }

        # fire ALL from-seed patterns inline (tree-select the seed once per pattern).
        $pats = @($plan.Patterns)
        $np = @($pats).Count
        if ($np -eq 0) {
            $wiz.SetChip('slots', 'slots: 1 cut', 'built')
            $wiz.Log('Single-row layout - the seed cut IS the only slot (no pattern needed).')
            $c.SlotsDone = $true; $wiz.MarkCommitted(); return $true
        }
        $accTot = @($pats | Where-Object { $_.Kind -eq 'accommodation' }).Count
        $wiz.BeginRun(("Patterning: 1 regular pattern + {0} accommodation pattern(s) from the one seed..." -f $accTot))
        $donePat = 0
        for ($k = 0; $k -lt $np; $k++) {
            $p = $pats[$k]
            # label the regular pattern vs the per-stray accommodations (user's model:
            # "the regular pattern" + "a second pattern to accommodate" each off-pattern row).
            $kindWord = if ([string]$p.Kind -eq 'regular') { ("REGULAR pattern ({0} slots at pitch {1:0.###})" -f $p.Count, $p.Increment) } else { ("accommodation pattern (stray row at +{0:0.###})" -f $p.Increment) }
            # -NoActivate: the operator clicks the seed slot in CREO's model tree WHILE this
            # prompt is up, then presses OK; a focus-stealing overlay would block that pick.
            [void]$wiz.AskInline('Chip-relief slots', ("Pattern {0} of {1} - {2}: select the SEED SLOT CUT in Creo's model tree (the remove-material extrude), then press OK. (Same seed every time - Creo makes a new slot each pattern.)" -f ($k + 1), $np, $kindWord), 'OK', $true)
            $selSeed = Read-SelectedId
            if ($null -eq $selSeed) {
                $wiz.Log(("Pattern {0}/{1} ({2}): nothing selected - skipped. Select the seed and re-run, or pattern by hand." -f ($k + 1), $np, $p.Kind))
                $c.SlotWarn = $true
                continue
            }
            $wiz.Log(("Pattern {0}/{1} - {2} along the {3} datum (by ID)..." -f ($k + 1), $np, $kindWord, $plan.DirName))
            $stampP = $null; try { $stampP = $model.VersionStamp } catch {}
            $patChanged = $false
            try {
                $session.RunMacro((Build-SlotPatternMacro -DirDatumId ([int]$plan.DirDatumId) -Count ([int]$p.Count) -Spacing ([double]$p.Increment) -Flip:$slotPatternFlip))
                if ($null -ne $stampP) { $patChanged = Wait-ModelModified -Model $model -PreviousStamp $stampP -OnPoll { try { [System.Windows.Forms.Application]::DoEvents() } catch {} } }
            } catch { $wiz.Log("  pattern error: $($_.Exception.Message)") }
            if ($patChanged) { $donePat++; $wiz.Log(("Pattern {0}/{1} placed its slot(s)." -f ($k + 1), $np)) }
            else { $c.SlotWarn = $true; $wiz.Log(("Pattern {0}/{1} did NOT change the model - the seed IS cut; pattern this group by hand." -f ($k + 1), $np)) }
            $wiz.SetChip('slots', ("slots: seed + {0}/{1} patterns" -f $donePat, $np), $(if ($donePat -eq ($k + 1)) { 'built' } else { 'unverified' }))
        }
        $c.SlotsDone = $true
        $wiz.MarkCommitted()
        $wiz.SetChip('slots', ("slots: seed + {0}/{1} patterns" -f $donePat, $np), $(if ($c.SlotWarn -eq $true) { 'unverified' } else { 'built' }))
        return $true
    }
[void]$steps.Add($slotFinishStep)

# ---- STAGE: Done -- summary -------------------------------------------------
$doneStep = New-WizardStep -Key 'done' -Title 'Done' -Stage 'Done' -Kind 'info' -PrimaryText 'Finish' `
    -Validate { param($c) return $true } `
    -Build {
        param($panel, $c, $wiz)
        $msg = "Drill-jig run complete." + [Environment]::NewLine + [Environment]::NewLine
        if ($c.BoxBuilt) {
            $msg += "  Box: built (verify dimensions visually in Creo)."
            $msg += [Environment]::NewLine
        }
        if (@($c.PointIDs).Count -gt 0) { $msg += ("  Points: {0}" -f @($c.PointIDs).Count) + [Environment]::NewLine }
        if ($c.Drilled) { $msg += "  Holes: drilled (verify visually in Creo)." + [Environment]::NewLine }
        if ($c.SlotsDone) {
            $msg += "  Chip-relief slots: cut (verify each spans its row, correct depth + face)." + [Environment]::NewLine
            if ($c.SlotWarn -eq $true) { $msg += "    NOTE: at least one run's pattern did not verify - check every hole row has its slot." + [Environment]::NewLine }
        }
        elseif ($c.SlotAnyCut -eq $true) { $msg += "  Chip-relief slots: PARTIALLY cut (the run loop did not finish - verify which hole rows have slots)." + [Environment]::NewLine }
        elseif ($c.SlotSkip) { $msg += "  Chip-relief slots: skipped." + [Environment]::NewLine }
        # HONESTY GUARD: if relief was intended ($c.WillSlot, so the plate was PADDED by the
        # slot depth) but NOTHING was cut (skipped / no-change / aborted before ANY seed), the
        # guide is LEFT TOO THICK by exactly the pad. Warn so the operator cuts it by hand or
        # re-runs. A PARTIAL cut ($c.SlotAnyCut) means the plate is at least partly relieved,
        # so this full-oversize warning does not apply (the partial-cut note above covers it).
        if ($c.WillSlot -eq $true -and -not $c.SlotsDone -and -not $c.SlotAnyCut -and $null -ne $c.BushingLen -and [double]$c.BushingLen -gt 0) {
            $padAmt = [double]$c.SlotDepth
            $msg += [Environment]::NewLine + ("  *** WARNING: the plate was PADDED by {0}`" for chip relief that was NOT cut, so the" -f $padAmt) + [Environment]::NewLine
            $msg += ("  bushing guide is OVERSIZED by {0}`" (it is {1}`", not the intended {2}`"). Cut the relief" -f $padAmt, [Math]::Round([double]$c.BushingLen+[double]$c.SlotDepth,4), [Math]::Round([double]$c.BushingLen,4)) + [Environment]::NewLine
            $msg += ("  slot(s) by hand ({0}`" deep), or re-run declining chip relief so the plate = bushing length." -f $padAmt) + [Environment]::NewLine
        }
        if ($script:macroFailures -gt 0) { $msg += [Environment]::NewLine + ("  NOTE: {0} mapkey failure(s) during the run - inspect Creo." -f $script:macroFailures) }
        $msg += [Environment]::NewLine + [Environment]::NewLine + "Verify all geometry in Creo. Press Finish to close (the Creo session stays open)."
        Add-Para $panel $msg 8 260 $null $false
        $wiz.SetChip('done', 'run complete', $(if ($script:macroFailures -eq 0) { 'built' } else { 'unverified' }))
    } `
    -OnNext { param($c,$wiz) return $true }
[void]$steps.Add($doneStep)

# ============================================================================
# RUN THE WIZARD
# ============================================================================
$stages = @('Welcome','Import','Bushing','Layout','Overview','Datums','Box','Drill','Relief','Done')
$subtitle = "Connected: $([System.IO.Path]::GetFileName($modelFile))"

try {
    $completed = Show-Wizard -Steps @($steps.ToArray()) -Stages $stages -Title 'Drill Jig Builder' -SubTitle $subtitle -Context $ctx
    if ($completed) {
        Write-Host "  Wizard completed." -ForegroundColor Green
    } else {
        Write-Host "  Wizard closed before completing." -ForegroundColor Yellow
    }
} finally {
    try {
        if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null }
        if ($null -ne $origDynamicPreview)  { $session.SetConfigOption("dynamic_preview",  $origDynamicPreview)  | Out-Null }
    } catch {}
    try { $connection.Disconnect($null) } catch {}
    # RELEASE every COM handle + force GC so this process holds NOTHING against
    # Creo's async slot once it parks at "Press any key to exit". Without this the
    # parked shell keeps the connection alive (RCWs live until GC), and the NEXT
    # launch faults on Connect() -- exactly the recurring 0x80010105 loop. The
    # preflight self-heal above is the belt; this is the suspenders (a clean exit
    # leaves no orphan to clear next time).
    foreach ($h in @('model','session','connection','async')) {
        try {
            $obj = Get-Variable -Name $h -ValueOnly -ErrorAction SilentlyContinue
            if ($null -ne $obj -and [System.Runtime.InteropServices.Marshal]::IsComObject($obj)) {
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($obj) | Out-Null
            }
        } catch {}
    }
    try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
}

Write-Host ""
Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
