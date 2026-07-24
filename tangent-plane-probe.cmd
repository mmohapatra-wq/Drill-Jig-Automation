<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "TANGENT-PLANE-PROBE"
$ErrorActionPreference = "Stop"

# ============================================================================
# TANGENT-PLANE-PROBE  -- confirm the tangent-plane recipe LIVE
# ============================================================================
# THE CURVED-JIG LINCHPIN (user 2026-07-24; recording in
# docs\tangent_plane_at_point_on_surface.mapkey.txt, fact
# tangent-plane-at-point-on-surface): a datum plane constrained TANGENT to a
# curved SURFACE AT a datum POINT has its NORMAL == the surface normal there.
# So per hole: fastener/layout -> datum POINT -> TANGENT PLANE at (point,surface)
# gives BOTH (a) a real normal-to-surface reference for drilling AND (b) the
# ideal seed-sketch host for the chip-relief slot.
#
# THE OPEN QUESTION this probe settles: the recording consumed the datum POINT
# + curved SURFACE from screen picks. Can those two refs be fed BY ID (accumulated,
# the same channel proven for the 3-plane intersection point + the csys), so
# ProCmdDatumPlane + constr_type1_OPTMENU1 = Tangent + stdbtn_1 creates the
# tangent plane HANDS-FREE? And which reference ORDER (surface-first vs
# point-first) does the command accept?
#
# HOW IT WORKS: the operator SELECTS one datum POINT + the curved SURFACE it
# sits on (Ctrl-click), presses ENTER. The probe reads their ids (ID-ONLY:
# SelItem.Id + SelItem.Type; it NEVER reads IpfcPoint.Point -- that crashes on
# this build, the holeinator lesson), then calls Invoke-TangentPlane and reports
# whether a NEW datum plane was created (feature-diff canary) + its id. It tries
# BOTH ref orders (surface-first, then point-first) if the first misses.
#
# NOTE: unlike fastener-probe/slotplane-probe this probe DOES create a datum
# plane (that is the whole point). It is NOT purely read-only. The plane is a
# harmless throwaway -- delete it in Creo after the run.
#
# Best-effort (read-only): if a BORE cylinder is also in the selection, it reads
# the bore axis so the report can note it -- but it does NOT read the new plane's
# NORMAL to compare (plane normals are null on this build; do not depend on them).
#
# Writes tangent_plane_probe_report.txt (gitignored). ONE Creo session; .prt only.
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
Write-Host "  TANGENT-PLANE-PROBE -- does a datum plane TANGENT to a surface AT a point build BY ID?" -ForegroundColor Cyan
Write-Host "  Creates ONE throwaway datum plane and reports (feature-diff canary) whether it landed." -ForegroundColor DarkGray
Write-Host "  Delete the test plane in Creo after the run." -ForegroundColor DarkGray
Write-Host ""

# ============================================
# SHARED LIBRARY
# ============================================
# creo_geometry: Get-Comp, Get-CylinderAxisFromSurface (best-effort bore read).
# drilljig_core: Initialize-DrilljigCore ($script:DJSession/DJModel/DJType scope),
#   Get-FeatureIdSet, Read-SelectedId, Wait-ModelModified, Invoke-Macro.
# tangent_plane: Invoke-TangentPlane (the recipe under test).
. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')
. (Join-Path $ScriptDir 'lib\drilljig_core.ps1')

$tangentLib = Join-Path $ScriptDir 'lib\tangent_plane.ps1'
if (-not (Test-Path $tangentLib)) {
    throw "lib\tangent_plane.ps1 not found. This probe drives Invoke-TangentPlane from that library."
}
. $tangentLib
if (-not (Get-Command Invoke-TangentPlane -ErrorAction SilentlyContinue)) {
    throw "Invoke-TangentPlane is not defined by lib\tangent_plane.ps1."
}

# ============================================
# CONNECT (single session, .prt guard)
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
if ($null -eq $model) { throw "No active model. Open a PART with a curved surface + a datum point on it." }

$fname = try { [string]$model.FileName } catch { "" }
if ($fname -match '(?i)\.asm(\.\d+)?$') {
    throw "Active model is an assembly ($fname). Open the PART (.prt) with the curved surface."
}
Write-Host "  Connected. Active model: $fname" -ForegroundColor Green
Write-Host ""

# Type object + init the shared engine so Invoke-TangentPlane (and Get-FeatureIdSet /
# Read-SelectedId / Wait-ModelModified) all read the SAME $script:DJSession/DJModel/
# DJType scope. -Log $null -> Write-Host (console).
$pfcType = New-Object -ComObject pfcls.pfcModelItemType
Initialize-DrilljigCore -Session $session -Model $model -TypeObj $pfcType -DataDir $ScriptDir -Log $null

# ----------------------------------------------------------------------------
# small helpers for the report
# ----------------------------------------------------------------------------
$script:report = @()
function Rep { param([string]$Line, [string]$Color = 'Gray') Write-Host ("  " + $Line) -ForegroundColor $Color; $script:report += $Line }
function Fmt-Pt { param($P) if ($null -eq $P) { return '(null)' }; try { return ('({0:0.####}, {1:0.####}, {2:0.####})' -f [double]$P[0], [double]$P[1], [double]$P[2]) } catch { return '(unreadable)' } }

# Normalize whatever Invoke-TangentPlane returns into { Ok; FeatId; Count; Reason }.
# The shared canary orchestrators in this repo return @{ Ok; NewFeatId; NewFeatCount;
# Reason } (Invoke-IndexCsys) or @{ Ok; ...; Reason } (Invoke-SlotPatternFromSeed), so
# accept the common key spellings without assuming one.
function Read-TangentResult {
    param($R)
    $out = @{ Ok = $false; FeatId = $null; Count = 0; Reason = '' }
    if ($null -eq $R) { $out.Reason = 'Invoke-TangentPlane returned $null'; return $out }
    if ($R -is [bool]) { $out.Ok = [bool]$R; $out.Reason = "returned bare bool $R"; return $out }
    foreach ($k in @('Ok','Success','Created')) { if ($R.PSObject.Properties.Name -contains $k -or ($R -is [hashtable] -and $R.ContainsKey($k))) { try { $out.Ok = [bool]$R.$k } catch {}; break } }
    foreach ($k in @('NewFeatId','FeatId','PlaneId','NewFeatureId','Id')) {
        $has = ($R -is [hashtable] -and $R.ContainsKey($k)) -or ($R.PSObject.Properties.Name -contains $k)
        if ($has) { try { $v = $R.$k; if ($null -ne $v) { $out.FeatId = [int]$v } } catch {}; if ($null -ne $out.FeatId) { break } }
    }
    foreach ($k in @('NewFeatCount','Count','NewCount')) {
        $has = ($R -is [hashtable] -and $R.ContainsKey($k)) -or ($R.PSObject.Properties.Name -contains $k)
        if ($has) { try { $out.Count = [int]$R.$k } catch {}; break }
    }
    foreach ($k in @('Reason','Message','Error')) {
        $has = ($R -is [hashtable] -and $R.ContainsKey($k)) -or ($R.PSObject.Properties.Name -contains $k)
        if ($has) { try { if ($R.$k) { $out.Reason = [string]$R.$k } } catch {}; if ($out.Reason) { break } }
    }
    # If the orchestrator did not flag Ok but a new feature id came back, treat that as success.
    if (-not $out.Ok -and $null -ne $out.FeatId -and $out.FeatId -gt 0) { $out.Ok = $true }
    return $out
}

Rep ("TANGENT-PLANE-PROBE report  model=$fname  when=" + (Get-Date).ToString('o')) 'Cyan'
Rep ""

try {

# ============================================
# 1. READ THE SELECTION (ID-ONLY): one datum POINT + the curved SURFACE
# ============================================
Write-Host "  In Creo, Ctrl-CLICK the datum POINT and the curved SURFACE it sits on," -ForegroundColor Cyan
Write-Host "  then press ENTER here. (Optionally also select the matching BORE cylinder for" -ForegroundColor Cyan
Write-Host "  a best-effort axis read -- not required.)" -ForegroundColor Cyan
Read-Host

$buf = @()
try { $buf = @(($session.CurrentSelectionBuffer()).Contents) } catch {}
Rep ("Selection buffer holds {0} item(s)." -f $buf.Count)

$pointId    = 0
$surfaceId  = 0
$boreAxis   = $null   # best-effort, read-only
foreach ($sel in $buf) {
    $si = $null
    try { $si = $sel.SelItem } catch {}
    if ($null -eq $si) { continue }
    $id = 0; $ty = -1
    try { $id = [int]$si.Id } catch {}
    try { $ty = [int]$si.Type } catch {}
    $tname = "?"; try { $tname = [string]$si.Type } catch {}
    if ($id -le 0) { continue }
    if ($ty -eq [int]$pfcType.ITEM_POINT) {
        if ($pointId -le 0) { $pointId = $id; Rep ("  datum POINT   id=$id  (type $tname)") 'Green' } else { Rep ("  (extra point id=$id ignored -- using the first)") 'DarkGray' }
    } elseif ($ty -eq [int]$pfcType.ITEM_SURFACE) {
        # A surface could be the curved face OR a bore cylinder. Read it as a cylinder
        # best-effort; if it IS a cylinder, keep it as the (optional) bore axis; use the
        # FIRST non-cylinder (or first surface) as the tangent target. NEVER IpfcPoint.Point.
        $ax = $null
        try { $ax = Get-CylinderAxisFromSurface -Surf $si } catch {}
        if ($null -ne $ax -and $null -eq $boreAxis) {
            $boreAxis = $ax
            Rep ("  BORE cylinder id=$id  r={0:0.####}  origin {1}  (best-effort axis, not required)" -f [double]$ax.Radius, (Fmt-Pt $ax.A)) 'DarkGray'
            # if we don't yet have a tangent target surface, tentatively hold this id too
            if ($surfaceId -le 0) { $surfaceId = $id }
        } else {
            $surfaceId = $id
            Rep ("  curved SURFACE id=$id  (type $tname) -- tangent target") 'Green'
        }
    } else {
        Rep ("  (ignored selection id=$id type $tname -- not a point or surface)") 'DarkGray'
    }
}
Rep ""

if ($pointId -le 0) { throw "No datum POINT was selected. Select the point + its surface, then re-run." }
if ($surfaceId -le 0) { throw "No SURFACE was selected. Select the curved surface + its point, then re-run." }

Rep ("INPUT: pointId=$pointId  surfaceId=$surfaceId") 'White'
Rep ""

# ============================================
# 2. FIRE Invoke-TangentPlane -- try BOTH ref orders (canary on each)
# ============================================
# The recording did not settle which reference order ProCmdDatumPlane accepts for
# the Tangent constraint (the point/surface correspondence). Try surface-first;
# if the feature-diff canary MISSES, try point-first. Each attempt is canary-gated:
# a NEW datum plane must appear, else it is a MISS (never assume success on failure).
Rep "== FIRE Invoke-TangentPlane ==" 'Cyan'

$attempts = @(
    @{ Label = 'surface-first (-SurfaceFirst)'; SurfaceFirst = $true  },
    @{ Label = 'point-first';                   SurfaceFirst = $false }
)

$made       = $false
$planeId    = 0
$whichOrder = ''
foreach ($a in $attempts) {
    Rep ("Attempt: {0}" -f $a.Label) 'Cyan'
    $beforeFeat = Get-FeatureIdSet
    $res = $null
    try {
        if ($a.SurfaceFirst) {
            $res = Invoke-TangentPlane -SurfaceId $surfaceId -PointId $pointId -SurfaceFirst
        } else {
            $res = Invoke-TangentPlane -SurfaceId $surfaceId -PointId $pointId
        }
    } catch {
        Rep ("  Invoke-TangentPlane threw: $($_.Exception.Message)") 'Red'
    }
    $tr = Read-TangentResult $res

    # Independent feature-diff canary (do NOT trust the return alone): re-diff the
    # feature set so we KNOW a plane appeared even if the return shape surprised us.
    $afterFeat = Get-FeatureIdSet
    $newFeats  = @($afterFeat.Keys | Where-Object { -not $beforeFeat.ContainsKey($_) } | Sort-Object)
    $diffCount = $newFeats.Count
    $diffId    = if ($diffCount -ge 1) { [int]$newFeats[-1] } else { 0 }

    if ($tr.Reason) { Rep ("  Invoke-TangentPlane reason: {0}" -f $tr.Reason) 'DarkGray' }
    Rep ("  return: Ok={0} FeatId={1} Count={2}" -f $tr.Ok, $tr.FeatId, $tr.Count) 'DarkGray'
    Rep ("  feature-diff canary: {0} new feature(s){1}" -f $diffCount, $(if ($diffId -gt 0) { " (id $diffId)" } else { "" })) $(if ($diffCount -ge 1) {'Green'} else {'Yellow'})

    if ($diffCount -ge 1) {
        $made       = $true
        $planeId    = if ($null -ne $tr.FeatId -and $tr.FeatId -gt 0) { $tr.FeatId } else { $diffId }
        $whichOrder = $a.Label
        Rep ("-> NEW DATUM PLANE CREATED (id $planeId) with ref order: {0}" -f $whichOrder) 'Green'
        break
    }
    Rep "  MISS: no new plane appeared for this ref order." 'Yellow'
    Rep ""
}
Rep ""

# ============================================
# 3. OPTIONAL best-effort NORMAL vs BORE AXIS note (do NOT depend on it)
# ============================================
Rep "== NORMAL vs BORE AXIS (best-effort; plane normals are null on this build) ==" 'Cyan'
if (-not $made) {
    Rep "No plane was created -- nothing to compare." 'DarkGray'
} elseif ($null -eq $boreAxis) {
    Rep "No bore cylinder was selected -- no axis to compare the tangent normal against." 'DarkGray'
    Rep "(To sanity-check normal-to-surface, ALSO select the matching bore and re-run;" 'DarkGray'
    Rep " but the definitive check is VISUAL -- the plane should look tangent at the point.)" 'DarkGray'
} else {
    # We do NOT read the new plane's normal (null on this build). We can only report
    # the bore axis we read for the operator's own eyeball comparison against the
    # tangent plane in Creo.
    Rep ("Bore axis read (for your visual comparison): origin {0}, r={1:0.####}" -f (Fmt-Pt $boreAxis.A), [double]$boreAxis.Radius) 'Green'
    Rep "Compare visually: the tangent plane's normal at the point should align with how the" 'Gray'
    Rep "hole will drill. Plane-normal COM reads are null here, so this stays a visual check." 'Gray'
}
Rep ""

# ============================================
# 4. VERDICT + WRITE THE REPORT
# ============================================
Rep "== VERDICT ==" 'Cyan'
if ($made) {
    Rep ("TANGENT PLANE BUILT BY ID (no screen pick). Working ref order: {0}. New plane id $planeId." -f $whichOrder) 'Green'
    Rep "-> The curved-jig per-hole flow CAN build a tangent plane hands-free from (point, surface) ids." 'Green'
    Rep "   Confirm VISUALLY that the plane is tangent to the surface at the point before wiring it in." 'Green'
    Rep "   Wire Invoke-TangentPlane with this ref order into the per-hole loop; use the plane both as" 'Green'
    Rep "   the normal-to-surface drilling reference AND the seed-sketch host for the chip-relief slot." 'Green'
    Rep "   (This test plane is a throwaway -- delete it in Creo.)" 'Yellow'
} else {
    Rep "NEITHER ref order created a datum plane by ID on this build." 'Yellow'
    Rep "  - Verify the SELECTED items really were a datum point + a curved surface (see section 1)." 'Yellow'
    Rep "  - The by-ID accumulate feed may not load these refs into ProCmdDatumPlane's Tangent" 'Yellow'
    Rep "    constraint the way it does for the intersection point / csys. If so, the per-hole loop" 'Yellow'
    Rep "    must fall back to a SCREEN-PICK of the point + surface (like boxinator's manual pick)." 'Yellow'
    Rep "  - Re-record docs\tangent_plane_at_point_on_surface.mapkey.txt with visible_mapkeys yes and" 'Yellow'
    Rep "    reconcile the exact constr_type1_OPTMENU1 / constrs_table tokens." 'Yellow'
}

$reportFile = Join-Path $ScriptDir 'tangent_plane_probe_report.txt'
try {
    Set-Content -Path $reportFile -Value ($script:report -join [Environment]::NewLine) -Encoding UTF8
    Write-Host ""
    Write-Host ("  Report written: $reportFile") -ForegroundColor Cyan
    Write-Host "  (tangent_plane_probe_report.txt is already gitignored -- probe reports are not committed.)" -ForegroundColor DarkGray
} catch {
    Write-Host ("  Could not write report: $($_.Exception.Message)") -ForegroundColor Yellow
    Write-Host "  (Reminder: add tangent_plane_probe_report.txt to .gitignore if it is not already.)" -ForegroundColor Yellow
}

} finally {
    try { $connection.Disconnect($null) } catch {}
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}

Write-Host ""
Write-Host "  This probe created a throwaway datum plane -- delete it in Creo when done." -ForegroundColor Yellow
Write-Host ""
Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
