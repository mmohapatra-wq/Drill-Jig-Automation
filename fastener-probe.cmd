<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "FASTENER-PROBE (READ-ONLY)"
$ErrorActionPreference = "Stop"

# ============================================================================
# FASTENER-PROBE  -- a READ-ONLY diagnostic (creates / mutates NOTHING)
# ============================================================================
# GOAL: discover which VB-API coordinate read actually returns usable fastener
# CENTERS on THIS Creo build, BEFORE fastenator.cmd / the drilljig import mode
# trust one. The whole "import fastener layout" feature hinges on reading a
# fastener's (x,y,z) center, and this codebase has a HARD rule that reading
# IpfcPoint.Point CRASHES (op_Subtraction on System.Object[], holeinator lesson) --
# so the read path must be PROVEN live, not guessed (reference_mine_trail_files
# / pointref-probe / slotpat-probe methodology: probe, don't guess).
#
# It tries, in try/catch, every candidate read and reports for each: did it run
# without crashing, how many usable finite coords came back, and a few samples.
# It NEVER calls IpfcPoint.Point.
#
#   1. CYLINDER-AXIS (Get-CylinderAxes) at a swept set of radii -- the PROVEN read
#      (descriptor.Origin.GetOrigin(), used live by matrixinator). Expected winner
#      in a PART; expected EMPTY on an assembly (ListItems(ITEM_BODY) is empty at
#      the top of an .asm -> Get-AllSurfaces finds nothing).
#   2. SELECTED-BORE (Get-CylinderAxisFromSurface over the selection buffer) --
#      the foreign-body-safe path; only if you have holes selected.
#   3. BODY CG (GetMassProperty($null).GravityCenter per ITEM_BODY) -- proven in a
#      part (gauginator); the CG of a fastener BODY as a plausible center.
#   4. COMPONENT (ITEM_COMPONENT count, then TRY GetMassProperty().GravityCenter)
#      -- UNPROVEN on this build; pure probe territory, must not crash the run.
#   5. DATUM POINT / AXIS / CSYS enumeration -- counts, and TRY the proven csys
#      transform read (Read-CoordSysTransform .CoordSys.GetOrigin()). NEVER reads
#      IpfcPoint.Point.
#
# Writes fastener_probe_report.txt (gitignored) for transcription into the tool.
# ONE Creo session. Open the FASTENER part/assembly you want to scan.
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
# HEADER
# ============================================
Write-Host ""
Write-Host "  FASTENER-PROBE (READ-ONLY) -- which coordinate read returns fastener centers?" -ForegroundColor Cyan
Write-Host "  Creates nothing. Tries every candidate read in try/catch and reports what works." -ForegroundColor DarkGray
Write-Host ""

# shared read helpers (Get-Comp, Get-CylinderAxes, Get-CylinderAxisFromSurface,
# Get-AllSurfaces, Read-CoordSysTransform, Get-EdgeArcCenter)
. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')
# pure projection math (Get-FastenerPlaneFrame) so section 6c can report the panel
# plane derived from the fastener axes the same way the tool will.
. (Join-Path $ScriptDir 'lib\fastener_layout.ps1')

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
$model      = $session.GetActiveModel()
if ($null -eq $model) { throw "No active model. Open the FASTENER part or assembly to scan." }

$pfcType = New-Object -ComObject pfcls.pfcModelItemType

$fname = try { [string]$model.FileName } catch { "" }
$isAsm = ($fname -match '(?i)\.asm(\.\d+)?$')
Write-Host "  Connected. Active model: $fname" -ForegroundColor Green
if ($isAsm) {
    Write-Host "  NOTE: this is an ASSEMBLY. The cylinder-axis read walks ITEM_BODY, which is" -ForegroundColor Yellow
    Write-Host "  usually empty at the top of an .asm (bodies live in the component parts), so" -ForegroundColor Yellow
    Write-Host "  the cylinder read may come back empty here -- that's a documented gap, not a bug." -ForegroundColor Yellow
}
Write-Host ""

# ----------------------------------------------------------------------------
# small helpers for the report
# ----------------------------------------------------------------------------
$script:report = @()
function Rep { param([string]$Line, [string]$Color = 'Gray') Write-Host ("  " + $Line) -ForegroundColor $Color; $script:report += $Line }
function Fmt-Pt { param($P) if ($null -eq $P) { return '(null)' }; try { return ('({0:0.####}, {1:0.####}, {2:0.####})' -f [double]$P[0], [double]$P[1], [double]$P[2]) } catch { return '(unreadable)' } }

$sweepRadii = @(0.0625, 0.086, 0.098, 0.1015, 0.125, 0.1285, 0.144, 0.1495, 0.166, 0.1875, 0.196, 0.201, 0.25, 0.3125, 0.375, 0.4375, 0.5)

Rep ("FASTENER-PROBE report  model=$fname  asm=$isAsm  when=" + (Get-Date).ToString('o')) 'Cyan'
Rep ""

# ============================================
# 1. CYLINDER-AXIS (the proven read) at a swept set of radii
# ============================================
Rep "== [1] CYLINDER-AXIS (Get-CylinderAxes, descriptor.Origin.GetOrigin) ==" 'Cyan'
$cylTotal = 0
$cylByRadius = @()
try {
    $allSurf = @(Get-AllSurfaces -Model $model -TypeObj $pfcType)
    Rep ("Get-AllSurfaces returned {0} surface(s)." -f $allSurf.Count) $(if ($allSurf.Count -gt 0) {'Green'} else {'Yellow'})
} catch { Rep ("Get-AllSurfaces threw: $($_.Exception.Message)") 'Red' }

foreach ($r in $sweepRadii) {
    $axes = @()
    try { $axes = @(Get-CylinderAxes -Model $model -TypeObj $pfcType -TargetRadius $r -RadTol 0.004) } catch { Rep ("  radius $r threw: $($_.Exception.Message)") 'Red' }
    if ($axes.Count -gt 0) {
        $cylTotal += $axes.Count
        $cylByRadius += ("r={0}: {1} cylinder(s), sample origin {2}" -f $r, $axes.Count, (Fmt-Pt $axes[0].A))
    }
}
if ($cylTotal -gt 0) {
    Rep ("FOUND {0} cylinder-axis reads across the swept radii:" -f $cylTotal) 'Green'
    foreach ($line in $cylByRadius) { Rep ("  " + $line) 'Green' }
    Rep "-> cylinder-axis is a WORKING center read on this model. Use it in fastenator.cmd." 'Green'
} else {
    Rep "No cylinders read at any swept radius (empty on an assembly, or foreign body)." 'Yellow'
}
Rep ""

# ============================================
# 2. SELECTED-BORE (Get-CylinderAxisFromSurface over the selection buffer)
# ============================================
Rep "== [2] SELECTED-BORE (Get-CylinderAxisFromSurface over the selection buffer) ==" 'Cyan'
$selCount = 0; $selCyl = 0
$script:selBoreAxes = @()   # accumulate readable bore axes for the section-6b offset check
try {
    $buf = ($session.CurrentSelectionBuffer()).Contents
    $selCount = @($buf).Count
    Rep ("Selection buffer holds {0} item(s)." -f $selCount)
    foreach ($sel in @($buf)) {
        $si = $null
        try { $si = $sel.SelItem } catch {}
        if ($null -eq $si) { continue }
        $ax = $null
        try { $ax = Get-CylinderAxisFromSurface -Surf $si } catch {}
        if ($null -ne $ax) {
            $selCyl++
            $script:selBoreAxes += [pscustomobject]@{ A = $ax.A; Radius = [double]$ax.Radius }
            if ($selCyl -le 6) { Rep ("  selected cylinder r={0:0.####} origin {1}" -f [double]$ax.Radius, (Fmt-Pt $ax.A)) 'Green' }
        }
    }
    if ($selCyl -gt 0) { Rep ("-> {0} of {1} selected items are readable cylinder bores." -f $selCyl, $selCount) 'Green' }
    elseif ($selCount -gt 0) { Rep "Selected items are not readable cylinders (select the hole BORE surfaces)." 'Yellow' }
    else { Rep "Nothing selected. To test this path, select some fastener hole surfaces first, then re-run." 'DarkGray' }
} catch { Rep ("Selection-buffer read threw: $($_.Exception.Message)") 'Red' }
Rep ""

# ============================================
# 3. BODY CG (GetMassProperty($null).GravityCenter per ITEM_BODY)
# ============================================
Rep "== [3] BODY CG (GetMassProperty(null).GravityCenter per ITEM_BODY) ==" 'Cyan'
try {
    $bodies = @($model.ListItems($pfcType.ITEM_BODY))
    Rep ("ListItems(ITEM_BODY) returned {0} bod(y/ies)." -f $bodies.Count) $(if ($bodies.Count -gt 0){'Green'}else{'Yellow'})
    $bi = 0
    foreach ($b in $bodies) {
        if ($bi -ge 12) { Rep ("  ... ({0} more bodies not sampled)" -f ($bodies.Count - 12)); break }
        $cg = $null
        try { $cg = (Get-Comp ($b.GetMassProperty($null).GravityCenter)) } catch { Rep ("  body #$bi CG read threw: $($_.Exception.Message)") 'Red' }
        if ($null -ne $cg) { Rep ("  body #$bi CG {0}" -f (Fmt-Pt $cg)) 'Green' }
        $bi++
    }
} catch { Rep ("ITEM_BODY enumeration threw: $($_.Exception.Message)") 'Red' }
Rep ""

# ============================================
# 4. COMPONENT (ITEM_COMPONENT count, TRY GetMassProperty / transform) -- UNPROVEN
# ============================================
Rep "== [4] COMPONENT (ITEM_COMPONENT -- UNPROVEN read, pure probe) ==" 'Cyan'
try {
    $comps = @($model.ListItems($pfcType.ITEM_COMPONENT))
    Rep ("ListItems(ITEM_COMPONENT) returned {0} component(s)." -f $comps.Count) $(if ($comps.Count -gt 0){'Green'}else{'DarkGray'})
    $ci = 0; $cgOk = 0
    foreach ($c in $comps) {
        if ($ci -ge 12) { Rep ("  ... ({0} more components not sampled)" -f ($comps.Count - 12)); break }
        # 4a. try component GetMassProperty().GravityCenter (unproven for components)
        $cg = $null
        try { $cg = (Get-Comp ($c.GetMassProperty($null).GravityCenter)) } catch {}
        # 4b. try to read a name / part number for provenance
        $nm = ''
        try { $nm = [string]$c.SelectionString } catch {}
        if ($null -ne $cg) { $cgOk++; Rep ("  comp #$ci CG {0}  {1}" -f (Fmt-Pt $cg), $nm) 'Green' }
        else { Rep ("  comp #$ci CG unreadable  {0}" -f $nm) 'Yellow' }
        $ci++
    }
    if ($comps.Count -gt 0) {
        if ($cgOk -gt 0) { Rep ("-> component GetMassProperty CG worked for {0} component(s) (PROMISING - verify the frame is the assembly's)." -f $cgOk) 'Green' }
        else { Rep "-> component CG did not read on this build (expected; components are unproven)." 'Yellow' }
    }
} catch { Rep ("ITEM_COMPONENT enumeration threw: $($_.Exception.Message)") 'Red' }
Rep ""

# ============================================
# 5. DATUM POINT / AXIS / CSYS enumeration (NEVER IpfcPoint.Point)
# ============================================
Rep "== [5] DATUM POINT / AXIS / CSYS counts (csys transform read is proven) ==" 'Cyan'
foreach ($pair in @(@('ITEM_POINT', $pfcType.ITEM_POINT), @('ITEM_AXIS', $pfcType.ITEM_AXIS), @('ITEM_COORD_SYS', $pfcType.ITEM_COORD_SYS))) {
    $nm = $pair[0]; $ty = $pair[1]
    $items = @()
    try { $items = @($model.ListItems($ty)) } catch { Rep ("  ListItems($nm) threw: $($_.Exception.Message)") 'Red'; continue }
    Rep ("  ListItems($nm) -> {0}" -f $items.Count) $(if ($items.Count -gt 0){'Green'}else{'DarkGray'})
    if ($nm -eq 'ITEM_COORD_SYS') {
        $ok = 0; $k = 0
        foreach ($cs in $items) {
            if ($k -ge 8) { break }
            $xf = $null
            try { $xf = Read-CoordSysTransform -Csys $cs } catch {}
            if ($null -ne $xf -and $null -ne $xf.Origin) { $ok++; Rep ("    csys #$k origin {0}" -f (Fmt-Pt $xf.Origin)) 'Green' }
            $k++
        }
        if ($items.Count -gt 0 -and $ok -gt 0) { Rep ("  -> csys transform read worked for {0} csys (proven family)." -f $ok) 'Green' }
    }
}
Rep "  (IpfcPoint.Point is NEVER read here -- it crashes on this build.)" 'DarkGray'
Rep ""

# ============================================
# 6. SELECTED COMPONENTS (assembly path transform origin) -- the ASSEMBLY read
# ============================================
# On an assembly ListItems returns 0 components (section [4]); the fasteners are
# reached through the SELECTION BUFFER instead (gripenator's proven pattern:
# SelItem.Path.ComponentIds / .SelectionString). Each selected component's
# LOCATION is IpfcComponentPath.GetTransform(BottomUp).GetOrigin() -- VB docs:
# "Signature: GetTransform(BottomUp as Boolean) as IpfcTransform3D". BottomUp=$true
# gives the ROOT->member transform, $false the member->root; the ORIGIN we want (the
# component's position in the assembly frame) is one of the two. This probe reports
# BOTH so the correct one is unambiguous on the first live run (fastenator uses
# $true). Read via the SAME IpfcTransform3D.GetOrigin() family proven in [5].
# Select the fasteners first (whole component instances), then re-run.
Rep "== [6] SELECTED COMPONENTS (Path.GetTransform(BottomUp).GetOrigin - the assembly read) ==" 'Cyan'
$compXfOk = 0
$script:compOrigins = @()   # kept BottomUp=$true origins (dedup by full path), for the checks below
try {
    $buf6 = @(($session.CurrentSelectionBuffer()).Contents)
    Rep ("Selection buffer holds {0} item(s)." -f $buf6.Count)
    $seen6 = @{}; $noPath6 = 0; $mergedPath6 = 0
    foreach ($sel in $buf6) {
        # raw selection string first (proves what got selected even if Path is null)
        $ss = ''
        try { $ss = [string]$sel.SelectionString } catch {}
        $pn = ''
        if ($ss -match ':([^<]+)<') { $pn = $matches[1] } elseif ($ss) { $pn = $ss }
        $path = $null
        try { $path = $sel.Path } catch {}
        if ($null -eq $path) { $noPath6++; Rep ("  selected item has NO component Path (not a component instance?)  {0}" -f $ss) 'Yellow'; continue }
        # DEDUP by the FULL component path (root->leaf), matching Read-FastenerCentersFromModel.
        # A leaf-only key would collapse distinct instances that share a leaf id in
        # different subassemblies; the full path '1|5|7' vs '1|6|7' keeps them apart.
        $key = $null
        try { $ids = $path.ComponentIds; if ($null -ne $ids -and $ids.Count -gt 0) { $key = ($ids -join '|') } } catch {}
        if ($null -ne $key) { if ($seen6.ContainsKey($key)) { $mergedPath6++; continue }; $seen6[$key] = $true }
        # LOCATION: report BOTH transform directions so the right one is obvious.
        # AXES: read ALL THREE axes (GetX/GetY/GetZAxis) off the BottomUp=$true transform.
        # The live GetZAxis read (1,0,0) LAY IN the plate plane (not the normal), so section
        # 6c compares each of the three against the point-cloud best-fit normal to find a
        # TRUE, selection-independent panel normal if one exists.
        $oT = $null; $oF = $null; $zAxis = $null; $xAxis = $null; $yAxis = $null
        try {
            $xfT = $path.GetTransform($true)
            $oT = Get-Comp $xfT.GetOrigin()
            try { $zAxis = Get-Comp $xfT.GetZAxis() } catch { $zAxis = $null }
            try { $xAxis = Get-Comp $xfT.GetXAxis() } catch { $xAxis = $null }
            try { $yAxis = Get-Comp $xfT.GetYAxis() } catch { $yAxis = $null }
        } catch { Rep ("  path=$key GetTransform(\$true) threw: $($_.Exception.Message)") 'Red' }
        try { $oF = Get-Comp (($path.GetTransform($false)).GetOrigin()) } catch { Rep ("  path=$key GetTransform(\$false) threw: $($_.Exception.Message)") 'Red' }
        if ($null -ne $oT -or $null -ne $oF) {
            $compXfOk++
            if ($null -ne $oT) { $script:compOrigins += [pscustomobject]@{ Key = $key; O = $oT; D = $zAxis; DX = $xAxis; DY = $yAxis; Pn = $pn } }
            $axStr = if ($null -ne $zAxis) { Fmt-Pt $zAxis } else { '(axis unreadable)' }
            Rep ("  path=$key  origin(`$true) {0}  |  origin(`$false) {1}  |  Zaxis {2}   {3}" -f (Fmt-Pt $oT), (Fmt-Pt $oF), $axStr, $pn) 'Green'
        } elseif ($null -ne $key) { Rep ("  path=$key transform unreadable  {0}" -f $pn) 'Yellow' }
    }
    if ($buf6.Count -eq 0) {
        Rep "Nothing selected. To test the ASSEMBLY read, SELECT the fasteners (Ctrl-click the" 'DarkGray'
        Rep "component instances in the tree or graphics), then re-run this probe." 'DarkGray'
    } elseif ($compXfOk -gt 0) {
        Rep ("-> component-path transform origin worked for {0} of {1} selected item(s)." -f $compXfOk, $buf6.Count) 'Green'
        if ($noPath6    -gt 0) { Rep ("   ({0} pick(s) had no component Path -- surface/edge/datum, silently skipped by the reader.)" -f $noPath6) 'Yellow' }
        if ($mergedPath6 -gt 0) { Rep ("   ({0} pick(s) were the SAME component path, merged.)" -f $mergedPath6) 'DarkGray' }
        Rep "   Pick the BottomUp value whose origins match the fasteners' real positions;" 'Green'
        Rep "   fastenator.cmd uses `$true. If `$false is the correct one, tell me and I'll flip it." 'Green'
    } else {
        Rep "Selected items exposed no readable component-path transform (select whole component instances)." 'Yellow'
    }
} catch { Rep ("Selected-component read threw: $($_.Exception.Message)") 'Red' }
Rep ""

# ============================================
# 6a. COINCIDENT-ORIGIN CHECK -- do selected components stack (bolt+washer+nut)?
# ============================================
# The #1 over-count cause: a bolt + washer + nut are 3 components at ~the same
# (x,y,z). If the selected set has clusters of near-coincident origins, the read
# returns N-per-hole and the tight assembly dedup (1e-3) won't merge them ->
# "too many holes". This makes that visible: count clusters at a few tolerances.
Rep "== [6a] COINCIDENT ORIGINS (bolt+washer+nut stacking -> over-count) ==" 'Cyan'
# build the vector list WITHOUT the pipeline (| ForEach { $_.O } FLATTENS each 3-vector
# into 3 scalars -> a bogus 3x count). Push each origin array as one element.
$origins = @()
foreach ($co in $script:compOrigins) { $origins += ,$co.O }
if ($origins.Count -lt 2) {
    Rep ("Only {0} readable component origin(s) -- select the fasteners in section [6] to test stacking." -f $origins.Count) 'DarkGray'
} else {
    foreach ($tol in @(1e-3, 0.01, 0.05, 0.1)) {
        # greedy cluster count: a new cluster for any origin farther than $tol (3D) from every kept rep
        $reps = @()
        foreach ($o in $origins) {
            $isNew = $true
            foreach ($r in $reps) {
                $dx = [double]$o[0]-[double]$r[0]; $dy = [double]$o[1]-[double]$r[1]; $dz = [double]$o[2]-[double]$r[2]
                if ([math]::Sqrt($dx*$dx+$dy*$dy+$dz*$dz) -le $tol) { $isNew = $false; break }
            }
            if ($isNew) { $reps += ,$o }
        }
        Rep ("  at tol {0,6:0.###}: {1} selected origin(s) -> {2} distinct location(s)." -f $tol, $origins.Count, $reps.Count) $(if ($reps.Count -lt $origins.Count) {'Yellow'} else {'Green'})
    }
    Rep "  If 'distinct location(s)' < selected at a small tol, you are selecting STACKS." 'Yellow'
    Rep "  Fix: select ONE component per hole (bolt shanks only), NOT washers/nuts." 'Yellow'
}
Rep ""

# ============================================
# 6b. ORIGIN-vs-BORE-AXIS CHECK -- is the placement csys ON the bore axis?
# ============================================
# The position question: GetTransform($true).GetOrigin() is the component's
# PLACEMENT csys origin, which for a purchased fastener may NOT sit on the bore
# axis -> every projected (X,Z) is offset from the true hole center. If bore
# surfaces were ALSO selected (section [2]), compare: for each component origin,
# the distance to the nearest selected bore axis origin should be ~0 if the csys
# is on-axis. A consistent nonzero offset means the read needs the bore, not the csys.
Rep "== [6b] COMPONENT ORIGIN vs BORE AXIS (is the placement csys on the bore?) ==" 'Cyan'
if ($script:compOrigins.Count -lt 1) {
    Rep "No component origins read (section [6]) -- nothing to compare." 'DarkGray'
} elseif ($script:selBoreAxes.Count -lt 1) {
    Rep "No bore axes were selected (section [2] empty). To run this check, ALSO select the" 'DarkGray'
    Rep "matching hole BORE surfaces alongside the components, then re-run." 'DarkGray'
} else {
    $offsets = @()
    foreach ($c in $script:compOrigins) {
        $best = [double]::MaxValue
        foreach ($b in $script:selBoreAxes) {
            $dx = [double]$c.O[0]-[double]$b.A[0]; $dy = [double]$c.O[1]-[double]$b.A[1]; $dz = [double]$c.O[2]-[double]$b.A[2]
            $d = [math]::Sqrt($dx*$dx+$dy*$dy+$dz*$dz)
            if ($d -lt $best) { $best = $d }
        }
        $offsets += $best
        if ($offsets.Count -le 6) { Rep ("  comp {0}: nearest bore axis is {1:0.####} away  {2}" -f $c.Key, $best, $c.Pn) $(if ($best -le 0.01) {'Green'} else {'Yellow'}) }
    }
    $mx = ($offsets | Measure-Object -Maximum).Maximum
    if ($mx -le 0.01) {
        Rep ("-> component origins sit ON the bore axes (max offset {0:0.####}). GetTransform origin is a good center." -f $mx) 'Green'
    } else {
        Rep ("-> component origins are OFF the bore axes (max offset {0:0.####})." -f $mx) 'Yellow'
        Rep "   The placement csys is NOT on the bore -> positions will be offset. Read the BORE" 'Yellow'
        Rep "   cylinder axis for assembly components instead of the transform origin." 'Yellow'
    }
}
Rep ""

# ============================================
# 6c. PANEL-PLANE DERIVATION -- the BEST-FIT PLANE of the hole positions
# ============================================
# The layout fix (user 2026-07-23): the tool projects the hole origins onto the
# plane the HOLES actually lie on (best-fit of the point cloud), which is an
# isometry -> true hole spacing preserved even when the panel is not square to the
# global axes. Live data showed the fastener's OWN axis can lie IN the plate plane
# (axis read (1,0,0) while the true normal was (0,-1,1)), so the axis is NOT a
# reliable normal -- the POINTS are. This reports the point-derived plane, its
# FLATNESS (how coplanar the holes are), and the angle between the fastener axis
# and that normal (large = the axis is not perpendicular to the plate -- fine).
Rep "== [6c] PANEL PLANE from HOLE POSITIONS (best-fit; the layout projection) ==" 'Cyan'
if ($script:compOrigins.Count -lt 3) {
    Rep ("Only {0} component origin(s) read -- need >=3 to fit a plane. Select more fasteners." -f $script:compOrigins.Count) 'DarkGray'
} else {
    $ctrs = @(); foreach ($co in $script:compOrigins) { $ctrs += ,$co.O }
    $axs  = @(); foreach ($co in $script:compOrigins) { $axs  += ,$co.D }
    $fr = Get-FastenerPlaneFrame -Centers $ctrs -Axes $axs -AxisX 'X' -AxisZ 'Z'
    if ($null -ne $fr -and $fr.Valid) {
        $flatStr = if ($null -ne $fr.Flatness) { ('{0:0.######}' -f [double]$fr.Flatness) } else { 'n/a' }
        $srStr   = if ($null -ne $fr.SpanRatio) { ('{0:0.######}' -f [double]$fr.SpanRatio) } else { 'n/a' }
        Rep ("Best-fit panel normal {0}  (source: {1})  flatness {2}  spanRatio {3}" -f (Fmt-Pt $fr.N), $fr.NormalSource, $flatStr, $srStr) $(if ($fr.NormalSource -eq 'points') {'Green'} else {'Yellow'})
        if ($fr.NormalSource -eq 'points' -and $null -ne $fr.Flatness -and [double]$fr.Flatness -lt 1e-4) {
            Rep "-> the holes are cleanly COPLANAR: the layout projects onto this plane with TRUE spacing." 'Green'
        } elseif ($fr.NormalSource -eq 'points') {
            Rep "-> holes are NOT flat (flatness > 1e-4): you may be selecting fasteners from MORE THAN ONE face." 'Yellow'
            Rep "   Select one panel/face at a time for a correct flat layout." 'Yellow'
        } else {
            Rep "-> holes are collinear/too few; fell back to the fastener AXIS as the normal." 'Yellow'
        }
        # PER-AXIS: which fastener axis (if any) IS the plate normal? A truly fixed
        # (selection-independent) normal is an axis that is BOTH ~parallel to the
        # best-fit normal AND consistent across all fasteners (near-zero spread). If one
        # exists we could skip fitting entirely; live GetZAxis (1,0,0) was 90deg off.
        $angTo = {
            param($AxList)
            $best = $null; $spread = 0.0; $ref = $null
            foreach ($v in $AxList) {
                if ($null -eq $v) { continue }
                $u = FL-Unit $v; if ($null -eq $u) { continue }
                if ($null -eq $ref) { $ref = $u }
                $cs = [Math]::Abs((FL-Dot $u $ref)); if ($cs -gt 1.0) { $cs = 1.0 }
                $d = [Math]::Acos($cs) * 180.0 / [Math]::PI
                if ($d -gt $spread) { $spread = $d }
                $cn = [Math]::Abs((FL-Dot $u $fr.N)); if ($cn -gt 1.0) { $cn = 1.0 }
                $an = [Math]::Acos($cn) * 180.0 / [Math]::PI
                if ($null -eq $best -or $an -lt $best) { $best = $an }
            }
            return @{ AngleToNormal = $best; Spread = $spread }
        }
        foreach ($nm in @('GetXAxis','GetYAxis','GetZAxis')) {
            # build the per-axis vector list WITHOUT a pipeline (| ForEach {$_.DX} flattens
            # each 3-vector into scalars); push each axis array as one element.
            $lst = @(); foreach ($co in $script:compOrigins) { if ($nm -eq 'GetXAxis') { $lst += ,$co.DX } elseif ($nm -eq 'GetYAxis') { $lst += ,$co.DY } else { $lst += ,$co.D } }
            $res = & $angTo $lst
            if ($null -eq $res.AngleToNormal) { Rep ("  $nm : unreadable on this build") 'DarkGray'; continue }
            $isNormal = ($res.AngleToNormal -le 2.0 -and $res.Spread -le 2.0)
            Rep ("  $nm : {0:0.##} deg from plate normal, cross-fastener spread {1:0.##} deg{2}" -f [double]$res.AngleToNormal, [double]$res.Spread, $(if ($isNormal) { '  <== candidate FIXED normal (selection-independent)' } else { '' })) $(if ($isNormal) {'Green'} else {'DarkGray'})
        }
        Rep "  (If one axis is ~0 deg from the normal AND ~0 spread, it is the true drill axis and could seed a fixed normal. Else the point-cloud best-fit is the only reliable normal -- select the FULL panel so it is well-conditioned.)" 'DarkGray'
        Rep ("Fastener GetZAxis vs plate normal: {0:0.##} deg (large = the bolt Z axis is NOT the plate normal; the POINTS still win)." -f [double]$fr.AxisSpreadDeg) 'DarkGray'
    } else {
        $emsg = if ($null -ne $fr) { ($fr.Errors -join '; ') } else { 'null frame' }
        Rep ("Could not derive a panel plane: {0}" -f $emsg) 'Yellow'
        Rep "-> layout will REFUSE this selection (collinear/too few/not coplanar) rather than distort - select 3+ fasteners spanning the panel." 'Yellow'
    }
}
Rep ""

# ============================================
# VERDICT + WRITE THE REPORT
# ============================================
Rep "== VERDICT ==" 'Cyan'
if ($cylTotal -gt 0) {
    Rep "Cylinder-axis is the proven center read available on this model. fastenator.cmd should use it (PART mode)." 'Green'
} elseif ($selCyl -gt 0) {
    Rep "Cylinder-axis via SELECTED bores works; use the selection-buffer read (foreign-body path)." 'Green'
} elseif ($compXfOk -gt 0) {
    Rep "ASSEMBLY read works: selected components expose Path.GetTransform().GetOrigin()." 'Green'
    Rep "Run fastenator.cmd, SELECT the fasteners, and use --from-components (assembly mode)." 'Green'
} else {
    Rep "No coordinate read succeeded here." 'Yellow'
    Rep "  - PART with bores: cylinder-axis should work (section [1]); open the PART." 'Yellow'
    Rep "  - ASSEMBLY: SELECT the fastener components first, then re-run (section [6])." 'Yellow'
}

$reportFile = Join-Path $ScriptDir 'fastener_probe_report.txt'
try { Set-Content -Path $reportFile -Value ($script:report -join [Environment]::NewLine) -Encoding UTF8; Write-Host ""; Write-Host ("  Report written: $reportFile") -ForegroundColor Cyan }
catch { Write-Host ("  Could not write report: $($_.Exception.Message)") -ForegroundColor Yellow }

# ============================================
# CLEANUP
# ============================================
try { $connection.Disconnect($null) } catch {}
Write-Host ""
Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
