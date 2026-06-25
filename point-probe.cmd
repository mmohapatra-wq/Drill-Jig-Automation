<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "POINT-PROBE"
$ErrorActionPreference = "Stop"

# ============================================================================
# POINT-PROBE  (plane-probe-v2 branch -- create datum POINTS at entered X/Y/Z)
# ============================================================================
# Creates a datum point at each X/Y/Z you type, using a recipe whose EVERY widget
# is proven live -- no guessed dialog tokens:
#
#   point at (X,Y,Z) == INTERSECTION of 3 offset datum planes:
#     1. create an offset plane X from base-plane #1   (proven: ProCmdDatumPlane
#        + t1.constr_dim1 + stdbtn_1 -- plane-probe's New-OffsetPlane),
#     2. ditto Y from base #2, Z from base #3,
#     3. select those 3 planes BY ID and run ProCmdDatumPointGeneral + stdbtn_1.
#        Three mutually-perpendicular planes meet at exactly one point, so OK
#        drops a datum point at their intersection -- which is (X,Y,Z).
#
# WHY this, not the offset-coordinate-system table or offset-from-edges point:
# those need on-screen reference picks a RunMacro cannot replay (the holeinator
# wall). This recipe needs only select-BY-ID, which is proven. Confirmed live
# 2026-06-24: 3 planes fed by ID into ProCmdDatumPointGeneral -> OK created PNT0,
# with ZERO picks and zero offset-value widgets (the offsets live on the PLANES,
# via the proven t1.constr_dim1 field).
#
# BONUS: the point is fully PARAMETRIC -- each coordinate is a drivable plane
# offset dim. The re-drive loop at the end moves a point by re-writing one.
#
# VERIFY (both ID-only -- never reads a point's coordinates, which crash on this
# build): (1) new-point COUNT == points entered (Resolve-NewPointIds diff);
# (2) the offset-plane dims carry your X/Y/Z (Get-LinearDimMap diff +
# Test-ExtentsMatch multiset). "CONFIRMED" is gated on the measurement.
#
# COST: 3 offset planes per point (a 0 offset reuses the base plane instead of a
# degenerate plane). Fine for a handful of points; a regular grid should instead
# share planes (1 face + Nx + Nz planes for Nx*Nz points) -- a later optimisation.
#
# PREREQ: a PART (.prt) with 3 mutually-perpendicular base datum planes
# (RIGHT/TOP/FRONT or any 3 orthogonal datums). ONE Creo session.
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

$script:macroFailures = 0
function Invoke-Macro {
    param([string]$Label, [string]$Macro)
    Write-Host "    > $Label ..." -NoNewline -ForegroundColor DarkGray
    try {
        $session.RunMacro($Macro)
        Write-Host " ok" -ForegroundColor DarkGray
    } catch {
        Write-Host ""
        Write-Host "      FAILED: $($_.Exception.Message)" -ForegroundColor Red
        $script:macroFailures++
    }
}

function Invoke-ForceRegen {
    param($Model)
    try {
        $regenCls = New-Object -ComObject pfcls.pfcRegenInstructions
        $instr    = $regenCls.Create($false, $true, $null)
        $Model.Regenerate($instr)
        return
    } catch {}
    $before = $null
    try { $before = $Model.VersionStamp } catch {}
    Invoke-Macro "force regenerate (UI)" "~ Command ``ProCmdRegenerate``;"
    if ($null -ne $before) {
        for ($i = 0; $i -lt 30; $i++) {
            try { if ($Model.VersionStamp -ne $before) { return } } catch {}
            Start-Sleep -Milliseconds 50
        }
    }
    try { $Model.Regenerate($null) } catch {}
}

function Get-FeatureIdSet {
    param($Model, $TypeObj)
    $set = @{}
    try {
        foreach ($f in $Model.ListItems($TypeObj.ITEM_FEATURE)) {
            try { $set[[int]$f.Id] = $true } catch {}
        }
    } catch {}
    return $set
}

function Read-SelectedId {
    $contents = ($session.CurrentSelectionBuffer()).Contents
    if ($null -eq $contents -or $contents.Count -eq 0) { return $null }
    try { return [int]$contents[$contents.Count - 1].SelItem.Id } catch { return $null }
}

# Feature-typed tree-search select-by-ID (proven). -NoClear omits buffer_clean so
# repeated calls ACCUMULATE into the buffer (proven: radinator batching; and live
# 2026-06-24, 3 planes accumulated then consumed by ProCmdDatumPointGeneral).
function Get-SelectByIdMacro {
    param([int]$FeatId, [switch]$NoClear)
    $clear = if ($NoClear) { "" } else { "~ Activate ``main_dlg_cur`` ``buffer_clean``;" }
    return $clear +
        "~ Command ``ProCmdMdlTreeSearch``;" +
        "~ Open ``selspecdlg0`` ``SelOptionRadio``;" +
        "~ Close ``selspecdlg0`` ``SelOptionRadio``;" +
        "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Feature``;" +
        "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
        "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$FeatId``;" +
        "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
        "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
        "~ Activate ``selspecdlg0`` ``CancelButton``;"
}

# Create ONE offset plane from a base plane selected BY ID, at the given offset.
# PROVEN recipe (plane-probe New-OffsetPlane; also seen live in the trail creating
# DTM1/2/3): select base by ID -> ProCmdDatumPlane (consumes the buffered ref as
# an Offset constraint) -> type offset into t1.constr_dim1 -> blur -> stdbtn_1 OK.
# New offset dim symbol + new feature id are found by before/after diff (polled).
# Returns @{ FeatId; Sym; Value } (FeatId $null if creation could not be confirmed).
function New-OffsetPlane {
    param($Model, $TypeObj, [int]$BaseId, [double]$Offset)
    $before     = Get-LinearDimMap -Model $Model -TypeObj $TypeObj
    $beforeFeat = Get-FeatureIdSet -Model $Model -TypeObj $TypeObj

    $macro =
        (Get-SelectByIdMacro -FeatId $BaseId) +
        "~ Command ``ProCmdDatumPlane``;" +
        "~ Input  ``Odui_Dlg_00`` ``t1.constr_dim1`` ``$Offset``;" +
        "~ Update ``Odui_Dlg_00`` ``t1.constr_dim1`` ``$Offset``;" +
        "~ FocusOut ``Odui_Dlg_00`` ``t1.constr_dim1``;" +
        "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;"
    Invoke-Macro "offset plane $Offset from base $BaseId" $macro

    # Poll BOTH the dim set AND the feature set INSIDE the loop, and break only
    # when a new dim AND EXACTLY ONE new feature are enumerable. (Sampling the
    # feature set once after a dim-only poll raced: on a slow commit the feature
    # lagged the dim, so FeatId read $null and the point was wrongly skipped.)
    $MaxWaitSec = 20
    $newSyms = @(); $newFeats = @(); $after = $before
    for ($i = 0; $i -lt ($MaxWaitSec * 10); $i++) {
        $after     = Get-LinearDimMap -Model $Model -TypeObj $TypeObj
        $afterFeat = Get-FeatureIdSet -Model $Model -TypeObj $TypeObj
        $newSyms   = @($after.Keys     | Where-Object { -not $before.ContainsKey($_) })
        $newFeats  = @($afterFeat.Keys | Where-Object { -not $beforeFeat.ContainsKey($_) })
        if ($newSyms.Count -ge 1 -and $newFeats.Count -eq 1) { break }
        Start-Sleep -Milliseconds 100
    }
    # Require EXACTLY ONE new feature. 0 or >1 (a lagged prior regen / embedded
    # internal feature) is ambiguous -> return $null FeatId so the caller SKIPS
    # this point (fails closed) rather than feeding a wrong plane id to the intersect.
    $newFeatId = if ($newFeats.Count -eq 1) { [int]$newFeats[0] } else { $null }
    if ($newFeats.Count -gt 1) {
        Write-Host "    (ambiguous: $($newFeats.Count) new features in the window; cannot pin the plane id)" -ForegroundColor Yellow
    }
    $sym = if ($newSyms.Count -ge 1) { [string]$newSyms[0] } else { $null }
    $val = if ($null -ne $sym) { [double]$after[$sym] } else { $null }
    return [pscustomobject]@{ FeatId = $newFeatId; Sym = $sym; Value = $val }
}

# Build the ALL-PROVEN intersect-point macro: accumulate the 3 plane ids BY ID
# into the buffer, then ProCmdDatumPointGeneral consumes them and stdbtn_1 OK
# drops the intersection point. (Confirmed live 2026-06-24: F6 PNT0.)
function Build-IntersectPointMacro {
    param([int[]]$PlaneIds)
    $m = (Get-SelectByIdMacro -FeatId $PlaneIds[0])
    for ($i = 1; $i -lt $PlaneIds.Count; $i++) {
        $m += (Get-SelectByIdMacro -FeatId $PlaneIds[$i] -NoClear)
    }
    $m += "~ Command ``ProCmdDatumPointGeneral``;" +
          "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;"
    return $m
}

function Set-DimAndConfirm {
    param($Model, $TypeObj, [string]$Sym, [double]$Value)
    try {
        $d = $Model.GetItemByName($TypeObj.ITEM_DIMENSION, $Sym)
        $d.DimValue = $Value
    } catch {
        Write-Host "    could not write DimValue on $($Sym): $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
    Invoke-ForceRegen -Model $Model
    return (Read-DimValue -Model $Model -TypeObj $TypeObj -Sym $Sym)
}

function Read-Points {
    $pts = @()
    while ($true) {
        $raw = Read-Host "    Point $($pts.Count + 1)  'X Y Z' (blank to finish)"
        if ([string]::IsNullOrWhiteSpace($raw)) {
            if ($pts.Count -ge 1) { break }
            Write-Host "      using sample point  2 3 0.5" -ForegroundColor Yellow
            $pts += [pscustomobject]@{ X = 2.0; Y = 3.0; Z = 0.5 }
            break
        }
        $parts = @($raw -split '[,\s]+' | Where-Object { $_ -ne '' })
        if ($parts.Count -lt 3) { Write-Host "      need three numbers: X Y Z" -ForegroundColor Yellow; continue }
        $x = 0.0; $y = 0.0; $z = 0.0
        if (-not ([double]::TryParse($parts[0], [ref]$x) -and [double]::TryParse($parts[1], [ref]$y) -and [double]::TryParse($parts[2], [ref]$z))) {
            Write-Host "      not three numbers." -ForegroundColor Yellow; continue
        }
        $pts += [pscustomobject]@{ X = $x; Y = $y; Z = $z }
    }
    return ,$pts
}

# ============================================
# HEADER
# ============================================
Write-Host ""
Write-Host "  POINT-PROBE -- create datum points at X/Y/Z you enter," -ForegroundColor Cyan
Write-Host "  as the intersection of 3 offset planes (all-proven widgets, no picks)." -ForegroundColor Cyan
Write-Host ""

. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')
. (Join-Path $ScriptDir 'lib\orthogrid_points.ps1')

# ============================================
# CONNECT (single session)
# ============================================
$procs = @(Get-Process | Where-Object { $_.ProcessName -eq "xtop" })
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
if ($null -eq $model) { throw "No active model. Open a part with 3 base datum planes first." }

$fname = try { [string]$model.FileName } catch { "" }
if ($fname -match '(?i)\.asm(\.\d+)?$') {
    throw "Active model is an assembly ($fname). Open the PART (.prt)."
}
Write-Host "  Connected. Active model: $fname" -ForegroundColor Green
Write-Host ""

$origVisibleMapkeys = $null
$origDynamicPreview = $null
try { $vals = $session.GetConfigOptionValues("visible_mapkeys"); if ($null -ne $vals -and $vals.Count -gt 0) { $origVisibleMapkeys = $vals.Item(0) } } catch {}
try { $vals = $session.GetConfigOptionValues("dynamic_preview");  if ($null -ne $vals -and $vals.Count -gt 0) { $origDynamicPreview = $vals.Item(0) } } catch {}
try {
    $session.SetConfigOption("visible_mapkeys", "no") | Out-Null
    $session.SetConfigOption("dynamic_preview", "no") | Out-Null
} catch {}

try {

$pfcType = New-Object -ComObject pfcls.pfcModelItemType

# ============================================
# 0. ENTER THE POINTS
# ============================================
Write-Host "  Enter each point's X/Y/Z (offsets from the 3 base planes you'll pick next):" -ForegroundColor Cyan
$points = Read-Points
Write-Host ""
Write-Host "  $($points.Count) point(s) to create:" -ForegroundColor White
foreach ($p in $points) { Write-Host ("    X={0,-8} Y={1,-8} Z={2}" -f $p.X, $p.Y, $p.Z) -ForegroundColor White }
Write-Host ""

# ============================================
# 1. CAPTURE THE 3 BASE PLANES (3 clicks; X-base, Y-base, Z-base in order)
# ============================================
Write-Host "  Click the 3 base datum planes the X/Y/Z are measured FROM (perpendicular):" -ForegroundColor Cyan
$axisLabels = @("X", "Y", "Z")
$baseIds = @()
for ($k = 0; $k -lt 3; $k++) {
    Read-Host "    Click the plane to offset $($axisLabels[$k]) FROM, then press ENTER"
    $id = Read-SelectedId
    if ($null -eq $id) { throw "Nothing selected for the $($axisLabels[$k]) base plane." }
    $baseIds += $id
    Write-Host "      $($axisLabels[$k]) base plane ID = $id" -ForegroundColor DarkGray
}
Write-Host ""

# ============================================
# 2. CONFIRM then CREATE (3 offset planes + 1 intersection point per point)
# ============================================
Write-Host "  This creates up to 3 offset planes + 1 point per entered point" -ForegroundColor Cyan
Write-Host "  ($($points.Count) point(s) -> up to $($points.Count * 4) features). Proceed? (y/N)" -ForegroundColor Cyan
$go = Read-Host "  "
if ($go.Trim().ToUpper() -ne "Y") { Write-Host "  Aborted (nothing created)." -ForegroundColor Yellow; return }
Write-Host ""

$beforePts = Get-PointIdSet -Model $model -TypeObj $pfcType
$tol = 1e-6
$allOffsetSyms = @()        # every offset-plane dim symbol created (for the re-drive menu)
$enteredNZ = @()            # entered nonzero |coords| (for the dim multiset check)

for ($pi = 0; $pi -lt $points.Count; $pi++) {
    $p = $points[$pi]
    Write-Host "  --- point $($pi + 1): X=$($p.X) Y=$($p.Y) Z=$($p.Z) ---" -ForegroundColor Cyan
    $coords = @($p.X, $p.Y, $p.Z)
    $planeIdsForPoint = @()
    $ok = $true
    for ($a = 0; $a -lt 3; $a++) {
        $off = [double]$coords[$a]
        if ([math]::Abs($off) -le $tol) {
            # 0 offset -> the point lies ON this base plane; use it directly (no degenerate plane).
            $planeIdsForPoint += [int]$baseIds[$a]
            Write-Host "    $($axisLabels[$a])=0 -> using base plane $($baseIds[$a]) directly" -ForegroundColor DarkGray
            continue
        }
        $res = New-OffsetPlane -Model $model -TypeObj $pfcType -BaseId $baseIds[$a] -Offset $off
        if ($null -eq $res.FeatId) {
            Write-Host "    could not confirm the $($axisLabels[$a]) offset plane -- skipping this point." -ForegroundColor Yellow
            $ok = $false; break
        }
        $planeIdsForPoint += [int]$res.FeatId
        if ($null -ne $res.Sym) { $allOffsetSyms += $res.Sym; $enteredNZ += [math]::Abs($off) }
        Write-Host "    $($axisLabels[$a]) offset plane: id $($res.FeatId)  $($res.Sym)=$($res.Value)" -ForegroundColor DarkGray
    }
    if (-not $ok) { continue }

    # Intersect the 3 planes into a point (all-proven macro). Primary signal: a
    # NEW datum point becomes enumerable. Secondary: VersionStamp moved -- used
    # ONLY to distinguish a silent macro no-op from an enumeration lag in the
    # report. An unreadable stamp ($null) is NOT assumed-changed (fails closed,
    # per the canary-must-not-assume-on-failure rule).
    $ptsBeforeIx = Get-PointIdSet -Model $model -TypeObj $pfcType
    $stampBefore = $null; try { $stampBefore = $model.VersionStamp } catch {}
    Invoke-Macro "intersect 3 planes -> point" (Build-IntersectPointMacro -PlaneIds $planeIdsForPoint)
    $nw = @()
    for ($i = 0; $i -lt 60; $i++) {
        $nw = Resolve-NewPointIds -Model $model -TypeObj $pfcType -Before $ptsBeforeIx
        if ($nw.Count -ge 1) { break }
        Start-Sleep -Milliseconds 100
    }
    if ($nw.Count -ge 1) {
        Write-Host "    -> point id(s): $($nw -join ', ')" -ForegroundColor Green
    } else {
        $changed = $false
        try { $changed = ($null -ne $stampBefore -and $model.VersionStamp -ne $stampBefore) } catch {}
        if ($changed) {
            Write-Host "    -> model changed but no new datum point is enumerable yet (it may exist; enumeration lag)." -ForegroundColor Yellow
        } else {
            Write-Host "    -> no model change -- the intersect macro missed." -ForegroundColor Yellow
        }
    }
    Write-Host ""
}

# ============================================
# 3. VERIFY -- count + offset-plane dims (both ID-only / no coord reads)
# ============================================
$newPtIds = Resolve-NewPointIds -Model $model -TypeObj $pfcType -Before $beforePts
$countOk = ($newPtIds.Count -eq $points.Count)
Write-Host "  VERIFY (1) created point count:" -ForegroundColor Cyan
if ($countOk) {
    Write-Host "    $($newPtIds.Count) new point(s) == $($points.Count) entered  (OK)" -ForegroundColor Green
} else {
    Write-Host "    $($newPtIds.Count) new point(s) != $($points.Count) entered  (MISMATCH)" -ForegroundColor Yellow
}

Write-Host "  VERIFY (2) offset-plane dims carry the entered |X/Y/Z| (tol 0.01):" -ForegroundColor Cyan
$planeVals = @()
foreach ($s in $allOffsetSyms) { $v = Read-DimValue -Model $model -TypeObj $pfcType -Sym $s; if ($null -ne $v) { $planeVals += [math]::Abs([double]$v) } }
$dimRes = Test-ExtentsMatch -Expected @($enteredNZ) -Measured @($planeVals) -Tol 0.01
if (@($enteredNZ).Count -eq 0) {
    Write-Host "    (all entered coords were 0 -- nothing to match)" -ForegroundColor DarkGray
} else {
    foreach ($pair in $dimRes.Pairs) {
        if ($pair.Ok) { Write-Host ("    entered {0,-8} -> matched {1}  (OK)" -f $pair.Expected, $pair.Matched) -ForegroundColor Green }
        else          { Write-Host ("    entered {0,-8} -> NOT matched" -f $pair.Expected) -ForegroundColor Yellow }
    }
}
$dimOk = (@($enteredNZ).Count -eq 0) -or $dimRes.AllMatched
Write-Host ""

if ($countOk -and $dimOk) {
    Write-Host "  CONFIRMED: datum point(s) created at the entered X/Y/Z, and the driving offset" -ForegroundColor Green
    Write-Host "  dims match -- independently verified, ID-only (no coordinate reads)." -ForegroundColor Green
} elseif ($countOk) {
    Write-Host "  PARTIAL: the points were created (count OK) but some offset dims did not match." -ForegroundColor Yellow
} else {
    Write-Host "  NOT CONFIRMED: created-point count did not match. See the per-point lines above." -ForegroundColor Yellow
}
Write-Host ""

# ============================================
# 4. RE-DRIVE LOOP -- move a point by re-writing one of its plane offset dims
# ============================================
$driveSyms = @($allOffsetSyms | Sort-Object -Unique)
if ($driveSyms.Count -gt 0) {
    Write-Host "  Re-drive a plane offset dim to MOVE a point (write + force regen + re-read):" -ForegroundColor Cyan
    while ($true) {
        for ($i = 0; $i -lt $driveSyms.Count; $i++) {
            $s = $driveSyms[$i]
            Write-Host ("    [{0}] {1,-6} = {2}" -f ($i + 1), $s, (Read-DimValue -Model $model -TypeObj $pfcType -Sym $s)) -ForegroundColor White
        }
        $sel = Read-Host "  Pick 1-$($driveSyms.Count) to re-drive, or D/blank = done"
        if ([string]::IsNullOrWhiteSpace($sel) -or $sel.Trim().ToUpper() -eq "D") { break }
        $idx = 0
        if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $driveSyms.Count) {
            Write-Host "    enter 1-$($driveSyms.Count) or D." -ForegroundColor Yellow; continue
        }
        $sym = $driveSyms[$idx - 1]
        $valRaw = Read-Host "    New value for $sym"
        $v = 0.0
        if (-not [double]::TryParse($valRaw, [ref]$v)) { Write-Host "    not a number." -ForegroundColor Yellow; continue }
        $now = Set-DimAndConfirm -Model $model -TypeObj $pfcType -Sym $sym -Value $v
        if ($null -ne $now -and [math]::Abs($now - $v) -lt 1e-4) {
            Write-Host "    $sym = $now  (held)" -ForegroundColor Green
        } else {
            Write-Host "    $sym = $now  (wanted $v -- did NOT hold)" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
if ($script:macroFailures -eq 0) {
    Write-Host "  Probe complete (no mapkey failures)." -ForegroundColor Cyan
} else {
    Write-Host "  Probe complete with $($script:macroFailures) mapkey failure(s) -- see red lines above." -ForegroundColor Yellow
}

} finally {
    try {
        if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null }
        if ($null -ne $origDynamicPreview)  { $session.SetConfigOption("dynamic_preview",  $origDynamicPreview)  | Out-Null }
    } catch {}
    $connection.Disconnect($null)
}

Write-Host ""
Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
