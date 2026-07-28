<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir=((Split-Path -Parent ('%~dp0'.TrimEnd('\')))+'\'); $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "CURVEDHOLE-PROBE"
$ErrorActionPreference = "Stop"

# ============================================================================
# CURVEDHOLE-PROBE  -- confirm the fastener-plane -> datum-point -> drilljig-hole
# workflow LIVE, in the top-down assembly (the `curvedholes` mapkey, 2026-07-27).
# ============================================================================
# THE WORKFLOW (user recording docs\curved_hole_from_fastener_planes.mapkey.txt,
# fact hole-by-reference-and-direction). AFTER the drilljig conformal surface is
# built, in a TOP-DOWN ASSEMBLY (curved-surface part + fasteners part + drilljig
# part), each fastener part instance carries its own TOP/SIDE/FRONT default datum
# planes AT the fastener. So:
#   1. Select that fastener's 3 datum planes (TOP/SIDE/FRONT).
#   2. ProCmdDatumPointGeneral + stdbtn_1  ->  a datum POINT at the 3-plane
#      INTERSECTION (= the fastener location). SAME command proven for the flat
#      3-plane-intersection point (point-at-3-plane-intersection-by-id); the only
#      new thing is that these 3 planes belong to a COMPONENT in an ASSEMBLY.
#   3. ProCmdHole placed BY REFERENCE: primary ref = the datum point (placement),
#      direction ref = a PICKED reference on the drilljig part that sets the drill
#      ORIENTATION -> the hole drills THROUGH the drilljig part in that direction.
#
# "we know how to do fastener selection, so using those fastener IDs, you know
# where to create datum points" (user): the fastener component selection is
# already solved (fastener-probe / fastenator: Selection.Path / ComponentIds).
# The load-bearing NEW questions this probe settles LIVE:
#   Q1  Does ProCmdDatumPointGeneral + stdbtn_1 consume the 3 fastener-COMPONENT
#       planes (selected in the ASSEMBLY) and create the intersection point?
#   Q2  Does the recorded ProCmdHole recipe (hole_fb_plcmnt_page.3.0 prim_ref +
#       ft_dir) then drill a hole at that point, oriented by a picked reference?
#   Q3  (diagnostic) What do the selected component planes look like in the buffer
#       -- Id / Type / GetName / Path.ComponentIds -- so the eventual TOOL can
#       select them programmatically from the known fastener component instead of
#       the fragile tree-node keys (`T3 6 0`) the recording used.
#
# WIDGET TOKENS ARE NOT GUESSED -- every macro token is transcribed VERBATIM from
# the operator's recording (mine-don't-guess: reference_mine_trail_files). The
# hole's DIRECTION reference is an @PAUSE_FOR_SCREEN_PICK in the recording, so the
# hole recipe SPLITS around the operator's pick (a RunMacro cannot screen-pick).
#
# ID-ONLY: reads SelItem.Id / .Type / .GetName / .Path only; NEVER IpfcPoint.Point
# (it crashes on this build -- the holeinator lesson). The fastener component
# origin is read via the PROVEN Path.GetTransform($true).GetOrigin() so the report
# can name where the point SHOULD land (the created point's own coords are never
# read).
#
# THIS PROBE MUTATES (like tangent-plane-probe): it creates ONE datum point and
# (unless --no-hole) ONE hole. Both are THROWAWAY -- Undo / delete them in Creo
# after the run. Every mutation is behind a y/N confirm and canary-gated (a
# NEW feature must appear, else it is a MISS -- never assumed on failure,
# feedback_canary_must_not_assume_on_failure).
#
# FLAGS:
#   --no-hole   stop after the datum point (test Q1 only; no hole is drilled).
#   -v          verbose (print each macro before firing).
#
# Writes curvedhole_probe_report.txt (gitignored). ONE Creo session; ASSEMBLY
# required (the fastener component planes only exist in the assembly context).
# ============================================================================

trap {
    Write-Host ""
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $inv = $_.InvocationInfo
    if ($null -ne $inv) {
        Write-Host ("  at line {0}: {1}" -f $inv.ScriptLineNumber, $inv.Line.Trim()) -ForegroundColor DarkYellow
    }
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

# ============================================
# FLAGS
# ============================================
$argStr  = [string]$ScriptArgs
$noHole  = $argStr -match '(?i)--no-hole'
$verbose = $argStr -match '(?i)(^|\s)(-v|--verbose)(\s|$)'

# ============================================
# HEADER
# ============================================
Write-Host ""
Write-Host "  CURVEDHOLE-PROBE -- fastener planes -> datum point -> drilljig hole (assembly)" -ForegroundColor Cyan
Write-Host "  Creates ONE datum point" $(if ($noHole) { "" } else { "+ ONE hole" }) "(throwaway -- Undo/delete in Creo after)." -ForegroundColor DarkGray
Write-Host "  Every mutation is confirmed + canary-gated. NEVER reads IpfcPoint.Point." -ForegroundColor DarkGray
Write-Host ""

# ============================================
# SHARED LIBRARY
# ============================================
# creo_geometry: Get-Comp (read a COM point/vector -> @(x,y,z)).
# drilljig_core: Initialize-DrilljigCore ($script:DJSession/DJModel/DJType scope),
#   Get-FeatureIdSet (feature-diff canary), Wait-ModelModified (VersionStamp poll).
. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')
. (Join-Path $ScriptDir 'lib\drilljig_core.ps1')

# ============================================
# CONNECT (single session)
# ============================================
$procs = @(Get-Process -Name xtop -ErrorAction SilentlyContinue)
if ($procs.Count -eq 0) { throw "Creo (xtop.exe) is not running" }
if ($procs.Count -gt 1) { throw "More than one Creo session is open. This probe expects exactly ONE." }
$proc = $procs[0]
$Env:PRO_DIRECTORY    = $proc.Path.TrimEnd("xtop.exe")
$Env:PRO_COMM_MSG_EXE = $proc.Path -replace "xtop.exe", "pro_comm_msg.exe"

try { New-Object -ComObject pfcls.pfcAsyncConnection | Out-Null }
catch {
    $reg = $proc.Path -replace "Common Files(.*)$", "Parametric\bin\vb_api_register.bat"
    Start-Process -Wait -FilePath $reg
}

$async      = New-Object -ComObject pfcls.pfcAsyncConnection
$connection = $async.Connect($null, $null, $null, $null)
$session    = $connection.Session
$model      = $null
try { $model = $session.GetActiveModel() } catch {}
if ($null -eq $model) { try { $model = $session.CurrentModel } catch {} }
if ($null -eq $model) { throw "No active model. Open the top-down ASSEMBLY (curved surface + fasteners + drilljig)." }

$fname = try { [string]$model.FileName } catch { "" }

# ----------------------------------------------------------------------------
# Mode guard: ASSEMBLY REQUIRED (the INVERSE of the usual .prt-only tools). The
# fastener component's TOP/SIDE/FRONT planes only exist to be selected in the
# assembly context; in a lone .prt there is no other component to reach. Key off
# the filename extension, NOT EpfcModelType (enum ints unconfirmed on this build).
# ----------------------------------------------------------------------------
if ($fname -notmatch '(?i)\.asm(\.\d+)?$') {
    Write-Host ""
    Write-Host "  STOP: the active model is NOT an assembly ($fname)." -ForegroundColor Yellow
    Write-Host "  This workflow selects a FASTENER COMPONENT's TOP/SIDE/FRONT planes, which only" -ForegroundColor Yellow
    Write-Host "  exist in the top-down ASSEMBLY. Open the .asm (curved surface + fasteners +" -ForegroundColor Yellow
    Write-Host "  drilljig), then re-run." -ForegroundColor Yellow
    try { $connection.Disconnect($null) } catch {}
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

$pfcType = New-Object -ComObject pfcls.pfcModelItemType
# init the shared engine so Get-FeatureIdSet / Wait-ModelModified read the SAME
# $script:DJSession/DJModel/DJType scope. -Log $null -> Write-Host (console).
Initialize-DrilljigCore -Session $session -Model $model -TypeObj $pfcType -DataDir $ScriptDir -Log $null

Write-Host "  Connected. Active model: $fname" -ForegroundColor Green
Write-Host ""

# ============================================
# CONFIG (capture originals now; SET + restore happen INSIDE the try/finally
# below so the finally ALWAYS restores them -- even on a throw in setup).
# ============================================
$origVisibleMapkeys = $null
$origDynamicPreview = $null
try {
    $vals = $session.GetConfigOptionValues("visible_mapkeys")
    if ($null -ne $vals -and $vals.Count -gt 0) { $origVisibleMapkeys = $vals.Item(0) }
} catch {}
try {
    $vals = $session.GetConfigOptionValues("dynamic_preview")
    if ($null -ne $vals -and $vals.Count -gt 0) { $origDynamicPreview = $vals.Item(0) }
} catch {}

# ----------------------------------------------------------------------------
# report helpers -- defined BEFORE the try so the finally can ALWAYS write the
# report (the trap runs the finally during unwinding before it exits).
# ----------------------------------------------------------------------------
$script:report = @()
function Rep { param([string]$Line, [string]$Color = 'Gray') Write-Host ("  " + $Line) -ForegroundColor $Color; $script:report += $Line }
function Fmt-Pt { param($P) if ($null -eq $P) { return '(null)' }; try { return ('({0:0.####}, {1:0.####}, {2:0.####})' -f [double]$P[0], [double]$P[1], [double]$P[2]) } catch { return '(unreadable)' } }

# ID-ONLY snapshot of every datum-point id in the active (assembly) model, as a
# set. Never reads .Point. Returns @{} on any failure.
function Get-PointIdSetLocal {
    $set = @{}
    try {
        foreach ($p in @($model.ListItems($pfcType.ITEM_POINT))) {
            try { $set[[int]$p.Id] = $true } catch {}
        }
    } catch {}
    return $set
}

# Fire ONE atomic macro (verbose-aware); count failures without throwing.
function Fire-Macro {
    param([string]$Label, [string]$Macro)
    if ($verbose) { Rep ("  macro[$Label]: $Macro") 'DarkGray' }
    try { $session.RunMacro($Macro); return $true }
    catch { Rep ("  RunMacro('$Label') threw: $($_.Exception.Message)") 'Red'; return $false }
}

$reportFile = Join-Path $ScriptDir 'artifacts\curvedhole_probe_report.txt'
$reportDir = Split-Path -Parent $reportFile; if ($reportDir -and -not (Test-Path $reportDir)) { New-Item -ItemType Directory -Force -Path $reportDir | Out-Null }
Rep ("CURVEDHOLE-PROBE report  model=$fname  no-hole=$noHole  when=" + (Get-Date).ToString('o')) 'Cyan'
Rep ""

# EVERYTHING that touches Creo config / geometry runs inside this try so the
# finally below ALWAYS restores config, writes the report, and DISCONNECTS --
# even on a throw (matches tangent-plane-probe's cleanup-in-finally pattern).
try {

# CONFIG SUPPRESS (restored in the finally below)
try {
    $session.SetConfigOption("visible_mapkeys", "no") | Out-Null
    $session.SetConfigOption("dynamic_preview", "no") | Out-Null
} catch {}

# ============================================================================
# SECTION 1 -- READ THE FASTENER'S 3 PLANES (diagnostic; ID-ONLY)
# ============================================================================
Write-Host "  In Creo, Ctrl-CLICK this fastener's THREE datum planes (TOP + SIDE + FRONT)" -ForegroundColor Cyan
Write-Host "  in the model tree or graphics -- the same 3 planes the mapkey selected. Then" -ForegroundColor Cyan
Write-Host "  press ENTER here." -ForegroundColor Cyan
Read-Host

$buf = @()
try { $buf = @(($session.CurrentSelectionBuffer()).Contents) } catch {}
Rep ("== [1] SELECTED PLANES (Id / Type / Name / component Path) ==") 'Cyan'
Rep ("Selection buffer holds {0} item(s)." -f $buf.Count) $(if ($buf.Count -ge 3) {'Green'} else {'Yellow'})

$planeCount = 0
$roles      = @{}          # role -> $true (TOP/SIDE/FRONT seen)
$fastPaths  = @{}          # component-path key -> $true (which fastener(s))
$fastOrigin = $null        # BottomUp=$true origin of the fastener component (proven read)
foreach ($sel in $buf) {
    $si = $null
    try { $si = $sel.SelItem } catch {}
    if ($null -eq $si) { Rep ("  (a selected item exposed no SelItem -- skipped)") 'DarkGray'; continue }
    $id = 0; $ty = -1
    try { $id = [int]$si.Id } catch {}
    try { $ty = [int]$si.Type } catch {}
    $tname = "?"; try { $tname = [string]$si.Type } catch {}
    $nm = ""; try { $nm = [string]$si.GetName() } catch {}
    $role = $null; try { $role = Resolve-PlaneRole -Name $nm } catch {}

    # component path (which fastener) -- the proven assembly read.
    $pathKey = ""
    $path = $null
    try { $path = $sel.Path } catch {}
    if ($null -ne $path) {
        try { $ids = $path.ComponentIds; if ($null -ne $ids -and $ids.Count -gt 0) { $pathKey = ($ids -join '|') } } catch {}
        if ($pathKey -ne "") { $fastPaths[$pathKey] = $true }
        # read the fastener component origin ONCE (proven Path.GetTransform($true).GetOrigin());
        # this is where the intersection point SHOULD land -- for the operator's visual check.
        if ($null -eq $fastOrigin) {
            try { $fastOrigin = Get-Comp (($path.GetTransform($true)).GetOrigin()) } catch {}
        }
    }
    $ss = ""; try { $ss = [string]$sel.SelectionString } catch {}

    $isPlaneish = ($null -ne $role) -or ($ty -eq [int]$pfcType.ITEM_SURFACE)
    if ($isPlaneish) { $planeCount++ }
    if ($null -ne $role) { $roles[$role] = $true }

    $roleTxt = if ($null -ne $role) { $role.ToUpper() } else { "(unclassified)" }
    $pathTxt = if ($pathKey -ne "") { "path=$pathKey" } else { "path=(none/top-level)" }
    Rep ("  id=$id  type=$tname  name='$nm'  role=$roleTxt  $pathTxt  $ss") $(if ($null -ne $role) {'Green'} else {'Yellow'})
}
Rep ""
$pathCount = @($fastPaths.Keys).Count
Rep ("Distinct fastener component path(s) captured from the plane items: {0}" -f $pathCount) $(if ($pathCount -eq 1) {'Green'} else {'Yellow'})
if ($pathCount -gt 1) {
    Rep "  WARNING: the selected planes span MORE THAN ONE fastener component. Select the" 'Yellow'
    Rep "  3 planes of ONE fastener only, or the intersection point will be meaningless." 'Yellow'
} elseif ($pathCount -eq 0) {
    # Q3 (the automation question): if a tree-selected component plane does NOT
    # expose its owning component Path, the eventual TOOL cannot map plane -> fastener
    # from the plane selection alone. This is the key finding for automating plane
    # selection from the KNOWN fastener component -- report it explicitly.
    Rep "  Q3 FINDING: none of the selected plane items exposed a component Path.ComponentIds." 'Yellow'
    Rep "  -> A tree-selected component datum plane does NOT carry its owning fastener's path" 'Yellow'
    Rep "     here, so the future TOOL cannot select the 3 planes from the plane picks alone." 'Yellow'
    Rep "     Automation must instead capture the fastener COMPONENT itself (the proven" 'Yellow'
    Rep "     fastener-probe/fastenator channel: select the component -> Path/ComponentIds),"  'Yellow'
    Rep "     then build a path-qualified raw-COM selection of its TOP/SIDE/FRONT planes." 'Yellow'
}
$rolesTxt = (@('Top','Side','Front') | Where-Object { $roles.ContainsKey($_) }) -join ', '
Rep ("Datum-plane ROLES matched by name: {0}" -f $(if ($rolesTxt) { $rolesTxt } else { '(none -- names did not resolve to TOP/SIDE/FRONT)' })) $(if (@($roles.Keys).Count -eq 3) {'Green'} else {'Yellow'})
if ($null -ne $fastOrigin) {
    Rep ("Fastener component origin (Path.GetTransform(`$true).GetOrigin) = {0}" -f (Fmt-Pt $fastOrigin)) 'Green'
    Rep "  -> the intersection point SHOULD land here (verify visually; the point's own coords" 'DarkGray'
    Rep "     are never read -- IpfcPoint.Point crashes on this build)." 'DarkGray'
}
Rep ""

if ($planeCount -lt 3) {
    Rep ("Only {0} plane-like item(s) selected -- need the fastener's 3 datum planes (TOP/SIDE/FRONT)." -f $planeCount) 'Yellow'
    Rep "Re-run and Ctrl-click all three planes of ONE fastener." 'Yellow'
    throw "Fewer than 3 datum planes selected; nothing to intersect."
}
if (@($roles.Keys).Count -lt 3) {
    Rep "NOTE: fewer than 3 of TOP/SIDE/FRONT resolved BY NAME, but 3+ plane-like items are" 'Yellow'
    Rep "selected -- proceeding on the item count (ProCmdDatumPointGeneral intersects whatever" 'Yellow'
    Rep "3 planes are in the buffer). Confirm the 3 are the fastener's default datums." 'Yellow'
    Rep ""
}

# ============================================
# CONFIRM before any mutation
# ============================================
Write-Host "  (Answer in THIS console -- do NOT click in Creo, or the 3-plane selection may clear.)" -ForegroundColor DarkGray
$ans = Read-Host "  Create the intersection datum point now? (y/N)"
if ($ans -notmatch '^(?i)y') {
    Rep "Aborted by operator before creating anything." 'Yellow'
    throw "Operator declined; no mutation performed."
}
Rep ""

# ============================================================================
# SECTION 2 -- CREATE THE DATUM POINT (ProCmdDatumPointGeneral + stdbtn_1)
# ============================================================================
# The 3 planes are already in the buffer (operator selection == the mapkey's
# tree-node select). Fire the SAME command proven for the flat 3-plane point,
# now on ASSEMBLY component planes. Canary: a NEW datum point must appear.
Rep "== [2] CREATE DATUM POINT AT THE 3-PLANE INTERSECTION ==" 'Cyan'

# Re-verify the buffer STILL holds >=3 items right before firing, so a MISS below
# means "the command did not consume the planes" (the real Q1 answer) rather than
# "the selection went stale between section [1] and here".
$nowBuf = 0
try { $nowBuf = @(($session.CurrentSelectionBuffer()).Contents).Count } catch {}
if ($nowBuf -lt 3) {
    Rep ("Selection buffer now holds {0} item(s) (<3) -- it changed since section [1]." -f $nowBuf) 'Yellow'
    Rep "Re-run and select the 3 planes WITHOUT clicking in Creo before the confirm." 'Yellow'
    throw "Selection buffer no longer holds the 3 planes; aborting to avoid a false MISS."
}

$ptBefore = Get-PointIdSetLocal
$stamp = $null; try { $stamp = [string]$model.VersionStamp } catch {}

$pointMacro = "~ Command ``ProCmdDatumPointGeneral``;" +
              "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;"
$null = Fire-Macro "datum point (3-plane intersection)" $pointMacro

$changed = $false
if ($null -ne $stamp) { $changed = Wait-ModelModified -Model $model -PreviousStamp $stamp -TimeoutMs 30000 }
else { Rep "  (VersionStamp unreadable before firing -- relying on the point-id diff below.)" 'Yellow' }

$ptAfter = Get-PointIdSetLocal
$newPts  = @($ptAfter.Keys | Where-Object { -not $ptBefore.ContainsKey($_) } | Sort-Object)
$newPtId = if ($newPts.Count -ge 1) { [int]$newPts[-1] } else { 0 }

$pointOk = ($newPts.Count -ge 1)
if ($pointOk) {
    Rep ("DATUM POINT CREATED: {0} new datum-point id(s) -> id {1} (model {2})." -f $newPts.Count, $newPtId, $(if ($changed) {'changed'} else {'change not signalled'})) 'Green'
    Rep "-> Q1 CONFIRMED: ProCmdDatumPointGeneral consumes the fastener-component planes and" 'Green'
    Rep "   creates the intersection point in the assembly. Verify it sits at the fastener origin." 'Green'
} else {
    Rep "NO new datum point appeared (MISS)." 'Yellow'
    Rep "  - The 3 fastener-component planes may not have loaded as references for" 'Yellow'
    Rep "    ProCmdDatumPointGeneral in the assembly, OR the OK (stdbtn_1) landed on an empty" 'Yellow'
    Rep "    dialog. Re-check section [1]: were 3 datum PLANES (one fastener) really selected?" 'Yellow'
    Rep "  - If the dialog is still open in Creo, Cancel it (Odui_Dlg_00 stdbtn_2 -> confirm yes)." 'Yellow'
}
Rep ""

# ============================================================================
# SECTION 3 -- DRILL THE HOLE at that point, oriented to the drilljig part
# ============================================================================
# The recorded ProCmdHole recipe: primary ref = the datum point (placement),
# direction ref = a PICKED reference on the drilljig part (the @PAUSE_FOR_SCREEN_
# PICK). We split the recipe around that pick. The just-created point stays
# selected after stdbtn_1, so ProCmdHole picks it up as the primary reference --
# but we ask the operator to confirm/re-select it first (robustness).
if ($noHole) {
    Rep "== [3] HOLE -- SKIPPED (--no-hole) ==" 'DarkGray'
    Rep "Re-run without --no-hole to also test the reference/direction-placed hole." 'DarkGray'
    Rep ""
} elseif (-not $pointOk) {
    Rep "== [3] HOLE -- SKIPPED (no datum point was created in section [2]) ==" 'Yellow'
    Rep "Fix the point creation first; the hole is placed ON that point." 'Yellow'
    Rep ""
} else {
    Rep "== [3] DRILL THE HOLE (reference-placed; direction = a drilljig pick) ==" 'Cyan'
    Write-Host ""
    Write-Host "  The new datum point should be SELECTED (highlighted). If it is NOT, click it once" -ForegroundColor Cyan
    Write-Host "  in the tree/graphics now. Then press ENTER to open the Hole tool on it." -ForegroundColor Cyan
    Read-Host

    $featBeforeHole = Get-FeatureIdSet
    $stampH = $null; try { $stampH = [string]$model.VersionStamp } catch {}

    # HOLE, part A: open + set the placement (primary) ref + arm the direction
    # collector, up to the direction pick. VERBATIM from the recording.
    $holeA =
        "~ Command ``ProCmdHole``;" +
        "~ Trigger ``hole_fb_plcmnt_page.3.0`` ``PH.ui_hole_prim_ref_cui_lst`` ``0``;" +
        "~ Trigger ``hole_fb_plcmnt_page.3.0`` ``PH.ui_hole_prim_ref_cui_lst`` ``1``;" +
        "~ Trigger ``hole_fb_plcmnt_page.3.0`` ``PH.ui_hole_prim_ref_cui_lst`` ````;" +
        "~ Trigger ``hole_fb_plcmnt_page.3.0`` ``PH.ui_hole_ft_dir_cui_lst`` ``0``;" +
        "~ Focus  ``hole_fb_plcmnt_page.3.0`` ``PH.ui_hole_ft_dir_cui_lst``;" +
        "~ Select ``hole_fb_plcmnt_page.3.0`` ``PH.ui_hole_ft_dir_cui_lst`` 1 ``0``;" +
        "~ Trigger ``hole_fb_plcmnt_page.3.0`` ``PH.ui_hole_ft_dir_cui_lst`` ````;"
    $null = Fire-Macro "hole part A (open + placement + arm direction)" $holeA

    Write-Host ""
    Write-Host "  The Hole dashboard is open. In Creo, PICK the DIRECTION reference on the drilljig" -ForegroundColor Cyan
    Write-Host "  part -- the surface / plane / axis that sets the drill ORIENTATION (the mapkey's" -ForegroundColor Cyan
    Write-Host "  @PAUSE_FOR_SCREEN_PICK). Then press ENTER here to finish the hole." -ForegroundColor Cyan
    Read-Host

    # HOLE, part B: commit the refs + confirm. VERBATIM from the recording.
    $holeB =
        "~ Trigger ``hole_fb_plcmnt_page.3.0`` ``PH.ui_hole_ft_dir_cui_lst`` ``0``;" +
        "~ Trigger ``hole_fb_plcmnt_page.3.0`` ``PH.ui_hole_ft_dir_cui_lst`` ````;" +
        "~ Trigger ``hole_fb_plcmnt_page.3.0`` ``PH.ui_hole_prim_ref_cui_lst`` ``1``;" +
        "~ Trigger ``hole_fb_plcmnt_page.3.0`` ``PH.ui_hole_prim_ref_cui_lst`` ``0``;" +
        "~ Trigger ``hole_fb_plcmnt_page.3.0`` ``PH.ui_hole_prim_ref_cui_lst`` ````;" +
        "~ Enter ``main_dlg_cur`` ``dashInst0.Quit``;" +
        "~ Exit  ``main_dlg_cur`` ``dashInst0.Quit``;" +
        "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"
    $null = Fire-Macro "hole part B (commit + Done)" $holeB

    $holeChanged = $false
    if ($null -ne $stampH) { $holeChanged = Wait-ModelModified -Model $model -PreviousStamp $stampH -TimeoutMs 30000 }
    $featAfterHole = Get-FeatureIdSet
    $newFeats = @($featAfterHole.Keys | Where-Object { -not $featBeforeHole.ContainsKey($_) } | Sort-Object)

    if ($newFeats.Count -ge 1 -or $holeChanged) {
        Rep ("HOLE FEATURE CREATED: {0} new feature(s){1}; model {2}." -f $newFeats.Count, $(if ($newFeats.Count -ge 1) { " (id $([int]$newFeats[-1]))" } else { "" }), $(if ($holeChanged) {'changed'} else {'change not signalled'})) 'Green'
        Rep "-> Q2: the point drives a reference/direction-placed hole feature. ORIENTATION is NOT" 'Green'
        Rep "   verified programmatically (plane normals read null on this build) -- confirm VISUALLY" 'Green'
        Rep "   that it drilled THROUGH the drilljig part in the picked direction." 'Green'
    } else {
        Rep "NO new hole feature appeared (MISS)." 'Yellow'
        Rep "  - The direction pick may not have registered, or the placement (primary) ref lost" 'Yellow'
        Rep "    the datum point. Re-check that the point was selected before part A." 'Yellow'
        Rep "  - If the Hole dashboard is still open in Creo, Cancel it (dashInst0.Quit / Esc)." 'Yellow'
    }
    Rep ""
}

# ============================================================================
# VERDICT
# ============================================================================
Rep "== VERDICT ==" 'Cyan'
if ($pointOk) {
    Rep "Q1 (datum point from fastener-component planes): CONFIRMED -- ProCmdDatumPointGeneral +" 'Green'
    Rep "   stdbtn_1 built the intersection point in the assembly. Automating the SELECTION of" 'Green'
    Rep "   the 3 planes (from the known fastener component -- Path/ComponentIds in section [1] --" 'Green'
    Rep "   via a path-qualified raw-COM selection, NOT the fragile T3 6 0 tree-node keys) is the" 'Green'
    Rep "   next tool step." 'Green'
} else {
    Rep "Q1: NOT confirmed here -- the datum point did not build from the selected planes." 'Yellow'
    Rep "   Re-check the selection (section [1]) and re-run." 'Yellow'
}
if (-not $noHole) {
    Rep "Q2 (reference/direction-placed hole): see section [3]. The DIRECTION reference is a" 'Gray'
    Rep "   screen pick in the recording; whether it can be fed BY ID (full automation) is the" 'Gray'
    Rep "   follow-up question -- record it with visible_mapkeys yes if the by-ID feed is wanted." 'Gray'
}
Rep "Design note (user): the chip-relief SLOT plane can be the fastener's own TOP plane -- no" 'Gray'
Rep "   tangent plane needed for that half of the curved-jig flow." 'Gray'
Rep "This probe created throwaway geometry -- Undo / delete the test point (and hole) in Creo." 'Yellow'

}
finally {
    # This finally runs on EVERY exit path -- clean fall-through AND any throw
    # (during unwinding, before the trap's exit 1). So config is always restored,
    # the report is always written, and the async COM connection never leaks.
    # ---- RESTORE CONFIG ----
    try { if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null } } catch {}
    try { if ($null -ne $origDynamicPreview) { $session.SetConfigOption("dynamic_preview", $origDynamicPreview) | Out-Null } } catch {}
    # ---- WRITE THE REPORT (best-effort) ----
    try {
        Set-Content -Path $reportFile -Value ($script:report -join [Environment]::NewLine) -Encoding UTF8
        Write-Host ""
        Write-Host ("  Report written: $reportFile") -ForegroundColor Cyan
        Write-Host "  (curvedhole_probe_report.txt is gitignored -- probe reports are not committed.)" -ForegroundColor DarkGray
    } catch {
        Write-Host ("  Could not write report: $($_.Exception.Message)") -ForegroundColor Yellow
    }
    # ---- DISCONNECT + GC (never leak the connection, even on a throw) ----
    try { $connection.Disconnect($null) } catch {}
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}

Write-Host ""
Write-Host "  This probe created a throwaway datum point (and hole) -- delete them in Creo." -ForegroundColor Yellow
Write-Host ""
Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
