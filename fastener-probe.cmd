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
try {
    $buf6 = @(($session.CurrentSelectionBuffer()).Contents)
    Rep ("Selection buffer holds {0} item(s)." -f $buf6.Count)
    $seen6 = @{}
    foreach ($sel in $buf6) {
        # raw selection string first (proves what got selected even if Path is null)
        $ss = ''
        try { $ss = [string]$sel.SelectionString } catch {}
        $pn = ''
        if ($ss -match ':([^<]+)<') { $pn = $matches[1] } elseif ($ss) { $pn = $ss }
        $path = $null
        try { $path = $sel.Path } catch {}
        if ($null -eq $path) { Rep ("  selected item has NO component Path (not a component instance?)  {0}" -f $ss) 'Yellow'; continue }
        # component id (dedup a component selected as several surfaces)
        $cid = $null
        try { $ids = $path.ComponentIds; if ($null -ne $ids -and $ids.Count -gt 0) { $cid = [int]$ids[$ids.Count - 1] } } catch {}
        if ($null -ne $cid) { if ($seen6.ContainsKey($cid)) { continue }; $seen6[$cid] = $true }
        # LOCATION: report BOTH transform directions so the right one is obvious.
        $oT = $null; $oF = $null
        try { $oT = Get-Comp (($path.GetTransform($true)).GetOrigin()) } catch { Rep ("  id=$cid GetTransform(\$true) threw: $($_.Exception.Message)") 'Red' }
        try { $oF = Get-Comp (($path.GetTransform($false)).GetOrigin()) } catch { Rep ("  id=$cid GetTransform(\$false) threw: $($_.Exception.Message)") 'Red' }
        if ($null -ne $oT -or $null -ne $oF) {
            $compXfOk++
            Rep ("  component id=$cid  BottomUp=`$true origin {0}  |  `$false origin {1}   {2}" -f (Fmt-Pt $oT), (Fmt-Pt $oF), $pn) 'Green'
        } elseif ($null -ne $cid) { Rep ("  component id=$cid transform unreadable  {0}" -f $pn) 'Yellow' }
    }
    if ($buf6.Count -eq 0) {
        Rep "Nothing selected. To test the ASSEMBLY read, SELECT the fasteners (Ctrl-click the" 'DarkGray'
        Rep "component instances in the tree or graphics), then re-run this probe." 'DarkGray'
    } elseif ($compXfOk -gt 0) {
        Rep ("-> component-path transform origin worked for {0} selected component(s)." -f $compXfOk) 'Green'
        Rep "   Pick the BottomUp value whose origins match the fasteners' real positions;" 'Green'
        Rep "   fastenator.cmd uses `$true. If `$false is the correct one, tell me and I'll flip it." 'Green'
    } else {
        Rep "Selected items exposed no readable component-path transform (select whole component instances)." 'Yellow'
    }
} catch { Rep ("Selected-component read threw: $($_.Exception.Message)") 'Red' }
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
