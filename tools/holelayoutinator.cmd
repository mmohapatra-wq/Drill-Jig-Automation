<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir=((Split-Path -Parent ('%~dp0'.TrimEnd('\')))+'\'); $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "HOLELAYOUTINATOR (drilled holes -> layout)"
$ErrorActionPreference = "Stop"

# ============================================================================
# HOLELAYOUTINATOR -- read the DRILLED HOLES in the open model as a 2D jig layout,
#                     analyse the pattern, and write it to a STANDALONE handoff file
#                     (hole_layout.json). A hole-first inspection/capture sandbox.
# ============================================================================
# WHY A SEPARATE TOOL (user 2026-07-24): this is deliberately NOT fastenator /
# drilljig / drilljig-gui and must NOT affect any of them. It dot-sources the shared
# read + projection libs READ-ONLY (loading a file cannot change another tool's
# behavior) and writes its OWN file (hole_layout.json, NOT fastener_layout.json), via
# its OWN pure lib (lib\hole_layout.ps1) whose function names are all unique. So
# nothing drilljig-gui needs is edited, and no shared function is shadowed.
#
# WHAT IT DOES:
#   1. connect to the open model (part or assembly), guard on exactly one Creo.
#   2. read the SELECTED hole (bore) SURFACES via the proven shared reader
#      Read-FastenerCentersFromModel -Selected (one center PER BORE, deduped by axis
#      origin, member->root transform in an assembly). NEVER reads IpfcPoint.Point.
#   3. project to a 2D (X,Z) layout via ConvertTo-LayoutXZ (panel-plane, tilt-safe,
#      -AlignGrid) -- so holes on ANY plane orientation project to true spacing.
#   4. ANALYSE the pattern (Get-HoleLayoutStats: bounding box, min/max spacing,
#      nearest pair, optional bore-collision check) and PRINT a report.
#   5. WRITE hole_layout.json (Write-HoleLayout) for a future consumer.
#
# FLAGS:
#   --axis-x X|Y|Z   model axis -> layout X   (default X)
#   --axis-z X|Y|Z   model axis -> layout Z   (default Z)
#   --flip-x / --flip-z   negate that axis (mirror fix)
#   --margin <m>     plate border added to every point (default = median bore dia)
#   --holedia <d>    bore/bit diameter for the collision check (default = median dia)
#   --out <path>     output file (default <repo>\hole_layout.json)
#   --units inch|mm  record source units (else prompted)
#   --no-align       do NOT de-rotate the grid to the axes (keep raw projection)
#
# Standalone; touches no other tool. Open the model with the holes; ONE session.
# ============================================================================

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

# ----------------------------------------------------------------------------
# flag parsing helpers
# ----------------------------------------------------------------------------
function Get-FlagValue { param([string]$Name) if ($ScriptArgs -match ("(?i)" + [regex]::Escape($Name) + "\s+([^\s]+)")) { return $Matches[1] } return $null }
function Has-Flag      { param([string]$Name) return ($ScriptArgs -match ("(?i)" + [regex]::Escape($Name) + "(\s|$)")) }

$optAxisX  = Get-FlagValue '--axis-x'
$optAxisZ  = Get-FlagValue '--axis-z'
$optFlipX  = Has-Flag '--flip-x'
$optFlipZ  = Has-Flag '--flip-z'
$optMargin = Get-FlagValue '--margin'
$optHoleDia= Get-FlagValue '--holedia'
$optOut    = Get-FlagValue '--out'
$optUnits  = Get-FlagValue '--units'
$optNoAlign= Has-Flag '--no-align'

# ----------------------------------------------------------------------------
# libs: shared READ + projection (dot-sourced READ-ONLY -- never modified here) +
# this tool's OWN pure analysis/handoff lib.
# ----------------------------------------------------------------------------
. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')     # Read-FastenerCentersFromModel (read-only use)
. (Join-Path $ScriptDir 'lib\fastener_layout.ps1')   # ConvertTo-LayoutXZ / Test-FastenerLayoutSane (read-only use)
. (Join-Path $ScriptDir 'lib\hole_layout.ps1')       # NEW: Get-HoleLayoutStats / Format-HoleLayoutReport / Write-HoleLayout

# ============================================
# HEADER
# ============================================
Write-Host ""
Write-Host "  HOLELAYOUTINATOR -- capture the open model's DRILLED HOLES as a jig hole layout" -ForegroundColor Cyan
Write-Host "  Reads SELECTED bore surfaces, projects to (X,Z), analyses spacing, writes hole_layout.json." -ForegroundColor DarkGray
Write-Host "  (Standalone -- does not touch fastenator / drilljig / drilljig-gui.)" -ForegroundColor DarkGray
Write-Host ""

# ============================================
# CONNECT (single session)
# ============================================
$procs = @(Get-Process -Name xtop -ErrorAction SilentlyContinue)
if ($procs.Count -eq 0) { throw "Creo (xtop.exe) is not running. Open Creo and the model with the holes, then re-run." }
if ($procs.Count -gt 1) { throw "More than one Creo session is open. This tool expects exactly ONE." }
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
$model      = $session.GetActiveModel()
if ($null -eq $model) { throw "No active model. Open the model with the holes first." }

$pfcType = New-Object -ComObject pfcls.pfcModelItemType
$fname = try { [string]$model.FileName } catch { "" }
$isAsm = ($fname -match '(?i)\.asm(\.\d+)?$')
Write-Host "  Connected. Active model: $fname" -ForegroundColor Green
Write-Host ""

try {

# ============================================
# 1. READ the SELECTED hole (bore) centers -- GUESS-FREE candidate selection
# ============================================
# The prior version called the shared reader, which used ONE fixed representation
# (the cylinder descriptor axis origin). On an ASSEMBLY that origin is read in the
# COMPONENT-LOCAL frame, so N holes modelled at the same local spot all read the
# SAME point -> "8 picked -> 1 bore center (merged 7 coincident)". The fix is to NOT
# assume which read is right: per selected bore we build THREE candidate locations --
#   Member : the descriptor axis origin (component-local; what failed)
#   Xform  : the component member->root transform origin (its assembly position)
#   Root   : composed = Xform.O + basis * Member  (the true assembly-frame hole)
# then Select-BestHoleCenters picks whichever representation gives the MOST DISTINCT
# points (= your hole count). This is the "relative math off the coordinate system"
# done for real, and it self-diagnoses (prints the distinct counts + which it chose).
# NEVER reads IpfcPoint.Point. All helpers dot-sourced read-only; nothing shared is
# modified, so drilljig-gui is untouched.
Write-Host "  SELECT the HOLE (bore) SURFACES in Creo (Ctrl-click them in graphics)," -ForegroundColor Cyan
Write-Host "  one bore surface per hole. Then return here and press ENTER." -ForegroundColor Cyan
$buf = @()
try { $buf = @(($session.CurrentSelectionBuffer()).Contents) } catch {}
if ($buf.Count -eq 0) {
    Read-Host "  Press ENTER once the hole bores are selected" | Out-Null
    try { $buf = @(($session.CurrentSelectionBuffer()).Contents) } catch {}
}
if ($buf.Count -eq 0) { throw "The selection buffer is empty. Select the hole bore SURFACES, then re-run." }

# Build the three candidate reads per selected bore (ID-only + descriptor + transform;
# never IpfcPoint.Point). $ax is the cylinder descriptor read (member-frame in an asm);
# the component Path gives the member->root transform for Xform + Root.
# Read one bore axis off any CYLINDRICAL sub-surface of a SelItem. The probe showed a
# selected hole is a Type=0 FEATURE (not a surface itself), so its bore geometry is a
# CHILD -- reach it via ListSubItems(ITEM_SURFACE) (the radinator/holeinator route).
# Returns @{ A=<origin>; D=<dir>; Radius } off the first cylindrical sub-surface, or $null.
function Get-BoreFromSubSurfaces {
    param($Item)
    if ($null -eq $Item) { return $null }
    $tv = $null; try { $tv = $pfcType.ITEM_SURFACE } catch {}
    if ($null -eq $tv) { return $null }
    $subs = @(); try { $subs = @($Item.ListSubItems($tv)) } catch {}
    foreach ($sub in $subs) {
        $sax = $null; try { $sax = Get-CylinderAxisFromSurface -Surf $sub } catch {}
        if ($null -ne $sax -and $null -ne $sax.A) { return $sax }
    }
    return $null
}

# Read the clicked hole's bore from the LEAF PART's own model. The probe proved that
# in an assembly the pick's SelItem is a component/feature whose surface descriptor is
# UNreadable through the assembly, BUT SelItem.DBParent resolves to the leaf part model
# (live: 150-110-2101-007.prt, ListItems=True) and the SelItem.Id is an entity id IN
# that part -- where the PROVEN part cylinder read works. Look the id up as a SURFACE,
# else as a FEATURE -> its bore sub-surface. Returns @{A;D;Radius} in the LEAF-PART
# frame (compose with the component transform for the assembly frame), or $null.
function Get-LeafBoreById {
    param($Sel)
    if ($null -eq $Sel) { return $null }
    $si = $null; try { $si = $Sel.SelItem } catch {}
    if ($null -eq $si) { return $null }
    $selId = $null; try { $selId = [int]$si.Id } catch {}
    if ($null -eq $selId) { return $null }
    $lm = $null; try { $lm = $si.DBParent } catch {}          # leaf part model (proven)
    if ($null -eq $lm) { try { $lm = $Sel.Path.Leaf } catch {} }
    if ($null -eq $lm) { return $null }
    # the clicked id as a SURFACE
    $surf = $null; try { $surf = $lm.GetItemById($pfcType.ITEM_SURFACE, $selId) } catch {}
    if ($null -ne $surf) { $a = $null; try { $a = Get-CylinderAxisFromSurface -Surf $surf } catch {}; if ($null -ne $a -and $null -ne $a.A) { return $a } }
    # else the clicked id as a FEATURE -> its first cylindrical sub-surface
    $feat = $null; try { $feat = $lm.GetItemById($pfcType.ITEM_FEATURE, $selId) } catch {}
    if ($null -ne $feat) {
        $fs = @(); try { $fs = @($feat.ListSubItems($pfcType.ITEM_SURFACE)) } catch {}
        foreach ($f in $fs) { $a = $null; try { $a = Get-CylinderAxisFromSurface -Surf $f } catch {}; if ($null -ne $a -and $null -ne $a.A) { return $a } }
    }
    return $null
}

# THE WINNING READ (confirmed live 2026-07 on 150-110-0030-101.asm, probe [H]:
# arc-kind=arc, 8 distinct). On this imported/foreign geometry EVERY cylinder-surface
# read fails (.Origin unreadable), but a hole leaves a CIRCULAR EDGE whose ARC CENTER
# reads via the CURVE descriptor -- and edges are the channel proven readable on
# foreign bodies (edginator). Resolve the clicked item's edges (GetItemById in the leaf
# part -> ListSubItems(ITEM_EDGE), else the SelItem's own), and take the FIRST edge that
# reads as a round arc WITH a center. Returns @{ A=<arc center, LEAF-PART frame>; D=$null;
# Radius } or $null. NEVER reads IpfcPoint.Point (arc .Center is the curve descriptor,
# the same read family proven for cylinder .Origin -- here it succeeds where surfaces don't).
function Get-LeafEdgeArc {
    param($Sel)
    if ($null -eq $Sel) { return $null }
    $si = $null; try { $si = $Sel.SelItem } catch {}
    if ($null -eq $si) { return $null }
    $selId = $null; try { $selId = [int]$si.Id } catch {}
    $lm = $null; try { $lm = $si.DBParent } catch {}
    if ($null -eq $lm) { try { $lm = $Sel.Path.Leaf } catch {} }
    # gather the edges belonging to THIS pick (feature/surface by id in the leaf, else the SelItem's own)
    $edges = @()
    if ($null -ne $lm -and $null -ne $selId) {
        foreach ($tk in @('ITEM_FEATURE','ITEM_SURFACE')) {
            $it = $null; try { $it = $lm.GetItemById($pfcType.$tk, $selId) } catch {}
            if ($null -ne $it) { $ee = @(); try { $ee = @($it.ListSubItems($pfcType.ITEM_EDGE)) } catch {}; if ($ee.Count -gt 0) { $edges = $ee; break } }
        }
    }
    if ($edges.Count -eq 0) { try { $edges = @($si.ListSubItems($pfcType.ITEM_EDGE)) } catch {} }
    foreach ($e in $edges) {
        $a = $null; try { $a = Get-EdgeArcCenter -Edge $e } catch {}
        if ($null -ne $a -and $a.IsRound -and $null -ne $a.Center) { return @{ A = $a.Center; D = $null; Radius = $a.Radius } }
    }
    return $null
}

$cands   = @()
$axesDir = @()   # bore axis direction (root-composed when possible) for panel-plane projection
$diams   = @()
$skipNoBore = 0
foreach ($sel in $buf) {
    $si = $null; try { $si = $sel.SelItem } catch {}
    if ($null -eq $si) { $skipNoBore++; continue }

    # FOUR bore reads off the selected item, most-reliable FIRST at use time:
    #  - edge:   resolve the SelItem's leaf PART + read the clicked hole's CIRCULAR EDGE
    #            arc CENTER (the read CONFIRMED LIVE to give 8 distinct; edges read where
    #            cylinder surfaces don't on this foreign body).
    #  - leaf:   the clicked id's bore CYLINDER in the leaf part (cylinder read).
    #  - sub:    the SelItem is a hole FEATURE; the bore is a sub-surface.
    #  - direct: the SelItem IS a cylinder surface (part-mode / a surface pick).
    # All read BEFORE the skip decision so a Type=0 component/feature pick is not discarded.
    $axEdge   = Get-LeafEdgeArc -Sel $sel
    $axDirect = $null; try { $axDirect = Get-CylinderAxisFromSurface -Surf $si } catch {}
    $axSub    = Get-BoreFromSubSurfaces -Item $si
    $axLeaf   = Get-LeafBoreById -Sel $sel
    if (($null -eq $axEdge -or $null -eq $axEdge.A) -and ($null -eq $axDirect -or $null -eq $axDirect.A) -and ($null -eq $axSub -or $null -eq $axSub.A) -and ($null -eq $axLeaf -or $null -eq $axLeaf.A)) { $skipNoBore++; continue }

    # The LEAF source (feeds the LeafById candidate) prefers the proven EDGE arc center,
    # then the cylinder-by-id read.
    $axLeafBest = if ($null -ne $axEdge -and $null -ne $axEdge.A) { $axEdge } elseif ($null -ne $axLeaf -and $null -ne $axLeaf.A) { $axLeaf } else { $null }

    # median-dia sampling from whichever read gave a radius (leaf/edge preferred, it's the bore)
    $rr = $null
    if ($null -ne $axLeafBest -and $null -ne $axLeafBest.Radius) { $rr = $axLeafBest.Radius }
    elseif ($null -ne $axDirect -and $null -ne $axDirect.Radius) { $rr = $axDirect.Radius }
    elseif ($null -ne $axSub -and $null -ne $axSub.Radius) { $rr = $axSub.Radius }
    if ($null -ne $rr) { $diams += (2.0 * [double]$rr) }

    $member = if ($null -ne $axDirect) { $axDirect.A } else { $null }   # descriptor axis origin off the SelItem
    $subM   = if ($null -ne $axSub)    { $axSub.A }    else { $null }   # bore axis origin off the sub-surface
    $leafM  = if ($null -ne $axLeafBest) { $axLeafBest.A } else { $null }   # arc center / bore axis in the LEAF-PART frame
    $memberDir = if ($null -ne $axDirect) { $axDirect.D } else { $null }
    $subDir    = if ($null -ne $axSub)    { $axSub.D }    else { $null }
    $leafDir   = if ($null -ne $axLeafBest) { $axLeafBest.D } else { $null }  # $null for the edge read (arc has no axis)
    # prefer the leaf bore's own direction, then the sub, then the descriptor
    $rootDir   = if ($null -ne $leafDir) { $leafDir } elseif ($null -ne $subDir) { $subDir } else { $memberDir }

    # LeafById defaults to the part-frame origin (correct relative layout even with no
    # transform); overwritten with the assembly-composed point when a transform is read.
    $xformO = $null; $rootP = $null; $subRootP = $null; $leafById = $leafM
    $path = $null; try { $path = $sel.Path } catch {}
    if ($null -ne $path) {
        $xf = $null; try { $xf = $path.GetTransform($true) } catch {}
        if ($null -ne $xf) {
            $to = $null; $bx = $null; $by = $null; $bz = $null
            try { $to = Get-Comp $xf.GetOrigin() } catch {}
            try { $bx = Get-Comp $xf.GetXAxis() } catch {}
            try { $by = Get-Comp $xf.GetYAxis() } catch {}
            try { $bz = Get-Comp $xf.GetZAxis() } catch {}
            $xformO = $to
            if ($null -ne $member) { $rootP    = Get-ComposedRootPoint -Member $member -O $to -Bx $bx -By $by -Bz $bz }
            if ($null -ne $subM)   { $subRootP = Get-ComposedRootPoint -Member $subM   -O $to -Bx $bx -By $by -Bz $bz }
            if ($null -ne $leafM)  { $lr = Get-ComposedRootPoint -Member $leafM -O $to -Bx $bx -By $by -Bz $bz; if ($null -ne $lr) { $leafById = $lr } }
            # compose the chosen direction into root (rotate only) when possible
            $dsrc = $rootDir
            if ($null -ne $dsrc -and $null -ne $bx -and $null -ne $by -and $null -ne $bz) {
                $rd = Get-ComposedRootPoint -Member $dsrc -O @(0.0,0.0,0.0) -Bx $bx -By $by -Bz $bz
                if ($null -ne $rd) { $rootDir = $rd }
            }
            # the EDGE read has no bore axis; default the direction to the component Z axis
            # so -Axes is NON-NULL and ConvertTo-LayoutXZ engages PANEL-PLANE mode (its
            # normal comes from the best-fit of the hole POSITIONS, so it finds the true
            # panel plane even when the normal is a global axis -- e.g. X here). Without a
            # non-null axis it would global-drop and collapse a normal-X panel.
            if ($null -eq $rootDir -and $null -ne $bz) { $rootDir = $bz }
        }
    }
    if ($null -eq $rootDir) { $rootDir = @(0.0, 0.0, 1.0) }   # last-resort placeholder -> plane mode engages
    $cands   += [pscustomobject]@{ LeafById = $leafById; Member = $member; Sub = $subM; Xform = $xformO; Root = $rootP; SubRoot = $subRootP }
    $axesDir += ,$rootDir
}
if ($cands.Count -eq 0) { throw "No readable holes in the selection. Ctrl-click the holes (bore surfaces / hole features / component instances) in Creo, then re-run." }

# Auto-choose the representation that actually distinguishes the holes.
$pick = Select-BestHoleCenters -Candidates $cands
$centers = $pick.Centers
Write-Host ""
Write-Host ("  Selection: {0} picked, {1} readable bore(s)." -f $buf.Count, $cands.Count) -ForegroundColor Green
if ($skipNoBore -gt 0) { Write-Host ("    - skipped {0} pick(s) with no readable bore (not a hole surface/feature)." -f $skipNoBore) -ForegroundColor Yellow }
Write-Host ("  Distinct locations by read:  leaf-by-id={0}  descriptor(local)={1}  sub-surface={2}  transform-origin={3}  composed-root={4}  sub-root={5}" -f `
    $pick.Counts.leafbyid, $pick.Counts.member, $pick.Counts.sub, $pick.Counts.xform, $pick.Counts.root, $pick.Counts.subroot) -ForegroundColor DarkGray
Write-Host ("  -> using the '{0}' read: {1} distinct hole location(s)." -f $pick.Which, $pick.Distinct) -ForegroundColor Green
if ($pick.Distinct -lt $cands.Count) {
    Write-Host ("  NOTE: {0} distinct < {1} bores read -- some holes truly share a location on ALL reads" -f $pick.Distinct, $cands.Count) -ForegroundColor Yellow
    Write-Host "        (a real stacked/duplicate pick), or the assembly exposes no per-hole transform." -ForegroundColor Yellow
}
$medianDia = 0.25
$sortedD = @($diams | Where-Object { $_ -gt 0 } | Sort-Object)
if ($sortedD.Count -gt 0) { $medianDia = [double]$sortedD[[int]([math]::Floor($sortedD.Count / 2))] }
Write-Host ("  Median bore diameter ~ {0:0.####}" -f $medianDia) -ForegroundColor DarkGray
Write-Host ""

# ============================================
# 2. AXIS MAPPING + margin/holedia/units
# ============================================
function Read-Axis {
    param([string]$Prompt, [string]$Default)
    while ($true) {
        $ans = Read-Host ("  $Prompt (X/Y/Z, default $Default)")
        if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
        $u = $ans.Trim().ToUpper()
        if (@('X','Y','Z') -contains $u) { return $u }
        Write-Host "    Enter X, Y, or Z." -ForegroundColor Yellow
    }
}
$axisX = if ($null -ne $optAxisX) { $optAxisX.Trim().ToUpper() } else { Read-Axis -Prompt "Model axis for layout X" -Default 'X' }
$axisZ = if ($null -ne $optAxisZ) { $optAxisZ.Trim().ToUpper() } else { Read-Axis -Prompt "Model axis for layout Z" -Default 'Z' }
$signX = if ($optFlipX) { -1.0 } else { 1.0 }
$signZ = if ($optFlipZ) { -1.0 } else { 1.0 }

$margin = $medianDia
if ($null -ne $optMargin) { try { $margin = [double]$optMargin } catch {} }
if ($margin -le 0) { $margin = 0.25 }

$holeDia = $medianDia
if ($null -ne $optHoleDia) { try { $holeDia = [double]$optHoleDia } catch {} }
if ($holeDia -lt 0) { $holeDia = 0.0 }

$units = if ($null -ne $optUnits) { $optUnits.Trim().ToLower() } else {
    $u = Read-Host "  Source model length units (inch/mm, ENTER=unknown)"
    if ([string]::IsNullOrWhiteSpace($u)) { 'unknown' } else { $u.Trim().ToLower() }
}
Write-Host ""

# ============================================
# 3. PROJECT (panel-plane, tilt-safe) + canary
# ============================================
# -Axes = each bore's own axis (parallel to $centers, root-composed) -> project onto
# the hole PANEL plane so true spacing survives holes on a non-XZ plane. -AlignGrid
# de-rotates the pattern to the layout axes (unless --no-align). DedupTol = 0: selected
# holes are 1:1, distinct holes must NEVER proximity-merge (coincidence surfaces above).
$fastAxes = $axesDir
$layout = if ($optNoAlign) {
    ConvertTo-LayoutXZ -Centers $centers -Axes $fastAxes -AxisX $axisX -AxisZ $axisZ -AxisXSign $signX -AxisZSign $signZ -Margin $margin -DedupTol 0.0
} else {
    ConvertTo-LayoutXZ -Centers $centers -Axes $fastAxes -AxisX $axisX -AxisZ $axisZ -AxisXSign $signX -AxisZSign $signZ -Margin $margin -DedupTol 0.0 -AlignGrid
}
if (-not $layout.Valid) {
    Write-Host "  Could not build a valid layout:" -ForegroundColor Red
    foreach ($e in $layout.Errors) { Write-Host ("    - $e") -ForegroundColor Red }
    Write-Host "  (Select at least 3 holes that are NOT all in one row/column so the panel plane is defined.)" -ForegroundColor Yellow
    throw "Projection failed."
}
if ($layout.Frame -eq 'plane') {
    Write-Host ("  Projected onto the hole PANEL plane (axis spread {0:0.##} deg) -- true spacing preserved." -f [double]$layout.AxisSpreadDeg) -ForegroundColor DarkGray
} else {
    Write-Host "  NOTE: bore axes were not readable -- used global-axis projection (may distort a tilted panel)." -ForegroundColor Yellow
}

$sane = Test-FastenerLayoutSane -Layout $layout
if (-not $sane.Ok) {
    Write-Host "  SANITY CHECK FAILED -- the read likely returned bad coordinates, NOT writing the file:" -ForegroundColor Red
    foreach ($e in $sane.Errors) { Write-Host ("    - $e") -ForegroundColor Red }
    throw "Sanity canary refused the layout."
}
Write-Host ""

# ============================================
# 4. ANALYSE + REPORT
# ============================================
$stats = Get-HoleLayoutStats -Points $layout.Points -HoleDia $holeDia
Write-Host "  HOLE LAYOUT ANALYSIS" -ForegroundColor White
foreach ($ln in (Format-HoleLayoutReport -Stats $stats -Layout $layout)) { Write-Host $ln -ForegroundColor Gray }
if (@($stats.Collisions).Count -gt 0) {
    Write-Host "  (Collisions are reported, not merged -- the holes are kept as read.)" -ForegroundColor Yellow
}
Write-Host ""

# ============================================
# 5. WRITE the standalone handoff file
# ============================================
$outPath = if ($null -ne $optOut) { $optOut } else { Join-Path $ScriptDir 'artifacts\hole_layout.json' }
$whenIso = (Get-Date).ToString('o')
# provenance: which candidate representation Select-BestHoleCenters auto-picked.
# ($read was a stale leftover from the shared-reader design and never existed here,
#  so ReadMethod was silently written as $null -- use the actual chosen read instead.)
$readMethod = "selected bores (auto-picked '$($pick.Which)' read)"
$ok = Write-HoleLayout -Path $outPath -Layout $layout -Stats $stats -SourceModel $fname -Units $units -ReadMethod $readMethod -WhenIso $whenIso
if ($ok) {
    Write-Host ("  Wrote hole layout -> {0}" -f $outPath) -ForegroundColor Green
    if ($units -ne 'unknown') { Write-Host ("  (Layout is in '$units' units.)") -ForegroundColor DarkGray }
} else {
    Write-Host ("  FAILED to write $outPath") -ForegroundColor Red
}

} finally {
    try { $connection.Disconnect($null) } catch {}
}

Write-Host ""
Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
