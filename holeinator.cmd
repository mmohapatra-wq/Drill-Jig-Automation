<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

# ============================================================================
# holeinator.cmd - create an On-Point HOLE at every target datum point
# ============================================================================
# No example feature, no clipboard. Each hole is CREATED from scratch with
# Creo's native Hole tool in "On Point" placement: select the datum point by ID
# (tree search, exactly like nodelator/radinator -- no screen picks), invoke the
# hole, set diameter (= bushing OD, from jiginator's handoff) and a through-all
# depth, confirm. Looped per point, it scales to an arbitrary pattern entirely
# by-ID.
#
# Why On-Point instead of an extrude-cut: a cut would need a circle sketched and
# dimensioned onto each point, and sketch placement needs a human screen pick
# (boxinator's lesson) -- that does not scale. The native Hole feature places
# coaxially to the point with no sketch, so the whole loop is unattended.
#
# Diameter is the bushing OD and is set DIRECTLY in the hole dashboard, never
# written-then-regenerated, so the sketch-dim snap-back trap
# (see project_sketch_dim_snapback) never enters the picture.
#
# Verify is boxinator-style GEOMETRIC: count cylindrical surfaces of the hole
# radius before and after the loop and assert the increase matches the number
# of target points. "Done (confirmed)" means holes were measured, not that
# macros fired.
#
# ============================== MACRO PROVENANCE ============================
# The hole-creation macro in Build-HoleMacro was transcribed from a LIVE mapkey
# recording on the jig part (2026-06-11): command `ProCmdHole`, depth via the
# `hole_depth_to_type_flybtn` flyout -> `StrHoleDepThruAllF`, diameter via
# `diameter_mip_OptionMenu`, body via the body-selection panel, confirm via
# `dashInst0.Done`. `~ Trail`/`~ Timer` lines from the recording were dropped as
# UI noise. The whole select+dashboard runs as ONE atomic RunMacro -- a
# dashboard's command context does not survive across RunMacro calls (CLAUDE.md
# boxinator lesson). NOT yet confirmed by a live scripted run end-to-end: the
# canary (verify hole #1 produced a cylinder before committing) is the live
# safety net for any widget-name drift across Creo datecodes.
# ============================================================================

$Host.UI.RawUI.WindowTitle = "HOLEINATOR"
# --dry-run / -n : run the entire read-only pipeline (mode guard, point
# validation, off-plane filter, idempotency, diameter handoff) and report
# exactly what WOULD be drilled -- but never open the mutate gate or fire a
# create macro. Safe to run against any live part; validates ~all of the tool's
# logic without the hole-dashboard recording. Flag pattern mirrors radinator's.
$DryRun = $ScriptArgs -match '(?i)--dry-run|(?<![A-Za-z])-n(?![A-Za-z])'
$ErrorActionPreference = "Stop"

trap {
    Write-Host ""
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

$script:lastPct = -1
function Show-Progress {
    param([int]$Pct, [string]$Label)
    if ($Pct -eq $script:lastPct) { return }
    $script:lastPct = $Pct
    $filled = [Math]::Floor($Pct / 5)
    $empty = 20 - $filled
    $bar = ([char]9608).ToString() * $filled + ([char]9617).ToString() * $empty
    $color = if ($Pct -ge 100) { "Green" } else { "White" }
    $shortLabel = if ($Label.Length -gt 20) { $Label.Substring(0, 20) } else { $Label }
    Write-Host "`r  [$bar] $($Pct.ToString().PadLeft(3))%  $shortLabel   " -NoNewline -ForegroundColor $color
    if ($Pct -ge 100) { Write-Host "" }
}

function Wait-ModelModified {
    # Returns $true if the model's VersionStamp changed within the timeout
    # (i.e. the macro actually modified the model), $false otherwise. The bool
    # is the cheap per-point liveness signal the create loop uses to detect a
    # hole that silently did nothing -- without re-scanning every surface.
    param($Model, [string]$PreviousStamp, [int]$TimeoutMs = 30000)
    $deadline = [DateTime]::Now.AddMilliseconds($TimeoutMs)
    while ([DateTime]::Now -lt $deadline) {
        try {
            if ($Model.VersionStamp -ne $PreviousStamp) { return $true }
        } catch {}
    }
    return $false
}

# ============================================
# HEADER
# ============================================
Write-Host ""
Write-Host "  ██   ██  ██████  ██      ███████ ██ ███    ██  █████  ████████  ██████  ██████ " -ForegroundColor White
Write-Host "  ██   ██ ██    ██ ██      ██      ██ ████   ██ ██   ██    ██    ██    ██ ██   ██" -ForegroundColor White
Write-Host "  ███████ ██    ██ ██      █████   ██ ██ ██  ██ ███████    ██    ██    ██ ██████ " -ForegroundColor White
Write-Host "  ██   ██ ██    ██ ██      ██      ██ ██  ██ ██ ██   ██    ██    ██    ██ ██   ██" -ForegroundColor White
Write-Host "  ██   ██  ██████  ███████ ███████ ██ ██   ████ ██   ██    ██     ██████  ██   ██" -ForegroundColor White
Write-Host "  On-Point Hole Creation" -ForegroundColor White
if ($DryRun) { Write-Host "  *** DRY RUN -- analysis only, no geometry will be created ***" -ForegroundColor Magenta }
Write-Host ""

# ============================================
# PREREQUISITES
# ============================================
Write-Host "  Prerequisites:" -ForegroundColor Green
Write-Host "    1. Part open in Creo" -ForegroundColor White
Write-Host "    2. Datum points placed at every target hole location" -ForegroundColor White
Write-Host "    3. Hole diameter known (auto-filled from jiginator if run)" -ForegroundColor White
Write-Host "    4. Do not interact with Creo during processing" -ForegroundColor White
Write-Host ""

<#
.SYNOPSIS
    Creates an On-Point hole at every target datum point in Creo.

.DESCRIPTION
    Connects to an active Creo session, captures a set of target datum points
    and a hole diameter (from jiginator's handoff or prompted), then CREATES a
    native On-Point hole at each point by ID -- no example feature, no sketch,
    no screen picks. Finishes with a geometric verify: counts cylindrical
    surfaces of the hole radius before and after and confirms the increase
    equals the number of points.

    Part of the NGS Orthogrid Automation toolkit. This is piece (C) of the
    drill-jig configurator -- the geometry-creation step that follows
    datinator's point read and jiginator's bushing pick.

.AUTHOR
    Built on Kyle Brooker's nodelator skeleton - Blue Origin
#>

# ----------------------------------------------------------------------------
# Connect (identical pattern to nodelator / every toolkit script)
# ----------------------------------------------------------------------------
try {
    $proc = Get-Process | Where-Object {$_.ProcessName -eq "xtop"}
    if ($null -eq $proc) {
        throw "Running Creo process (xtop) not found"
    }
    $pc_path = $proc.Path -replace "xtop.exe", "pro_comm_msg.exe"
    $Env:PRO_DIRECTORY = $proc.Path.TrimEnd("xtop.exe")
    $Env:PRO_COMM_MSG_EXE = $pc_path
}
catch {
    $_
    exit
}

try {
    New-Object -ComObject pfcls.pfcAsyncConnection | Out-Null
}
catch {
    Write-Output "VB API not yet registered on this machine, performing first time setup..."
    $vb_path = $proc.Path -replace "Common Files(.*)$", "Parametric\bin\vb_api_register.bat"
    Start-Process -Wait -FilePath $vb_path
}

try {
    $async = New-Object -ComObject pfcls.pfcAsyncConnection
    $connection = $async.Connect($null, $null, $null, $null)
    $session = $connection.Session
}
catch {
    $_
    Write-Output "Could not connect to Creo session."
    Write-Output "Press any key to continue..."
}

$model = $session.GetActiveModel()
if ($null -eq $model) { throw "No active model in the Creo session. Open the drill-jig part first." }
Write-Host "  Connected: $($model.FileName)" -ForegroundColor Green

# ----------------------------------------------------------------------------
# Suppress UI noise, remember originals, restore in finally
# ----------------------------------------------------------------------------
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
try {
    $session.SetConfigOption("visible_mapkeys", "no") | Out-Null
    $session.SetConfigOption("dynamic_preview", "no") | Out-Null
} catch {}

try {
#------------- HOLEINATOR AUTOMATION LOGIC ---------------------

$name = "holeinator"

# ============================================
# MODE GUARD -- this tool operates on a PART, not an assembly
# ============================================
# The whole design assumes a single solid part: datum points come from the
# active model's ListItems(ITEM_POINT), the select-by-ID tree search targets
# part items, and "drill a hole" means cut one solid body. In assembly mode
# GetActiveModel() returns the .asm -- ITEM_POINT then yields assembly-level
# datums (not the component geometry we mean), the by-ID selection lands on
# assembly items, and "where does the hole go" is ambiguous. Rather than
# silently drill the wrong thing, detect it and stop.
#
# We key off the filename extension (.prt vs .asm) rather than the EpfcModelType
# enum: every toolkit script already reads .FileName, the extension is a
# universal Creo convention, and the enum's integer values are not confirmed on
# this build (CLAUDE.md: do not hardcode unverified enum ints).
$modelFile = ""
try { $modelFile = [string]$model.FileName } catch {}
if ($modelFile -match '\.asm(\.\d+)?$') {
    Write-Host ""
    Write-Host "  STOP: the active model is an ASSEMBLY ($modelFile)." -ForegroundColor Yellow
    Write-Host "  holeinator drills holes into a single PART. Open the jig PART" -ForegroundColor Yellow
    Write-Host "  itself (activate it in its own window), then re-run." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  (Why: in assembly mode the datum points and by-ID selection" -ForegroundColor DarkGray
    Write-Host "   resolve against the .asm, not the part you mean to drill.)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Nothing was changed." -ForegroundColor Green
    return
}
if ($modelFile -notmatch '\.prt(\.\d+)?$' -and $modelFile -ne "") {
    # Not clearly a part either (drawing, mfg, etc.) -- warn but let the user decide.
    Write-Host ""
    Write-Host "  WARNING: active model '$modelFile' does not look like a part (.prt)." -ForegroundColor Yellow
    $cont = Read-Host "  Continue anyway? (y/N)"
    if ($cont -notmatch '^[Yy]$') {
        Write-Host "  Cancelled -- nothing was changed." -ForegroundColor Yellow
        return
    }
}

# ============================================
# VECTOR HELPERS (datinator's proven accessor pattern)
# ============================================
# Used by the off-plane filter, the idempotency check, and the geometric verify.
# Defined once up here so every section shares the exact same component reads.
function Get-Comp {
    # Read the 3 components of an IpfcPoint3D/IpfcVector3D (bracket idx, .Item fallback).
    param($V)
    try   { return @([double]$V[0], [double]$V[1], [double]$V[2]) }
    catch { return @([double]$V.Item(0), [double]$V.Item(1), [double]$V.Item(2)) }
}
function Dot { param($A, $B) ($A[0]*$B[0] + $A[1]*$B[1] + $A[2]*$B[2]) }

# Perpendicular distance from point P to the infinite line through A with
# direction D (D need not be unit -- normalized here). Returns +inf if D is
# degenerate. This is the "does this point lie on that hole axis" metric.
function Dist-PointToAxis {
    param($P, $A, $D)
    $len = [Math]::Sqrt((Dot $D $D))
    if ($len -le 1e-12) { return [double]::PositiveInfinity }
    $u = @($D[0]/$len, $D[1]/$len, $D[2]/$len)
    $v = @($P[0]-$A[0], $P[1]-$A[1], $P[2]-$A[2])
    $t = Dot $v $u                                   # projection onto axis
    $perp = @($v[0]-$t*$u[0], $v[1]-$t*$u[1], $v[2]-$t*$u[2])
    return [Math]::Sqrt((Dot $perp $perp))
}

# ============================================
# SURFACE WALK (shared by the cylinder counter and the axis reader)
# ============================================
# Gather every surface across all solid bodies (fall back to default body).
# Centralized so the counter and the idempotency axis-reader can never diverge
# on which surfaces they see.
function Get-AllSurfaces {
    param($Model)
    $pfcType = New-Object -ComObject pfcls.pfcModelItemType
    $allSurfaces = @()
    try {
        $allBodies = @($Model.ListItems($pfcType.ITEM_BODY))
        foreach ($body in $allBodies) {
            try {
                $bs = $body.ListSurfaces()
                if ($null -ne $bs -and $bs.Count -gt 0) {
                    for ($i = 0; $i -lt $bs.Count; $i++) { $allSurfaces += $bs.Item($i) }
                }
            } catch {}
        }
    } catch {}
    if ($allSurfaces.Count -eq 0) {
        try {
            $surfaces = $Model.GetDefaultBody().ListSurfaces()
            if ($null -ne $surfaces -and $surfaces.Count -gt 0) {
                for ($i = 0; $i -lt $surfaces.Count; $i++) { $allSurfaces += $surfaces.Item($i) }
            }
        } catch {}
    }
    return $allSurfaces
}

# ============================================
# GEOMETRIC-VERIFY HELPER (radinator's proven accessor pattern)
# ============================================
# Count cylindrical surfaces. If $TargetRadius > 0, only count cylinders whose
# radius matches within $RadTol; otherwise count every cylinder. Read via
# $desc.Radius and [int]$type -eq 1 exactly as radinator does.
function Count-Cylinders {
    param($Model, [double]$TargetRadius = 0.0, [double]$RadTol = 1e-3)
    $count = 0
    foreach ($surf in (Get-AllSurfaces -Model $Model)) {
        try {
            $desc = $surf.GetSurfaceDescriptor()
            $type = [int]$desc.GetSurfaceType()
            if ($type -eq 1) {   # EpfcSURFACE_CYLINDER
                if ($TargetRadius -le 0.0) {
                    $count++
                } else {
                    $r = $null
                    try { $r = [double]$desc.Radius } catch {}
                    if ($null -ne $r -and [Math]::Abs($r - $TargetRadius) -le $RadTol) { $count++ }
                }
            }
        } catch {}
    }
    return $count
}

# ============================================
# IDEMPOTENCY HELPER -- read existing hole axes at the target radius
# ============================================
# A drilled hole leaves a same-radius cylinder whose axis passes through the
# original datum point. Reading those axes lets the create loop SKIP points that
# already carry a hole, so re-running doesn't stack a second hole on each point.
# The cylinder descriptor extends IpfcTransformedSurfaceDescriptor (.Origin is an
# IpfcTransform3D); axis point = Origin.GetOrigin(), axis dir = Origin.GetZAxis()
# (confirmed accessors). Returns an array of @{ A = <pt[3]>; D = <dir[3]> }.
function Get-CylinderAxes {
    param($Model, [double]$TargetRadius, [double]$RadTol = 1e-3)
    $axes = @()
    foreach ($surf in (Get-AllSurfaces -Model $Model)) {
        try {
            $desc = $surf.GetSurfaceDescriptor()
            if ([int]$desc.GetSurfaceType() -ne 1) { continue }      # cylinders only
            $r = $null
            try { $r = [double]$desc.Radius } catch {}
            if ($null -eq $r -or [Math]::Abs($r - $TargetRadius) -gt $RadTol) { continue }
            $xf = $desc.Origin                                       # IpfcTransform3D
            $a = Get-Comp $xf.GetOrigin()
            $d = Get-Comp $xf.GetZAxis()
            $axes += @{ A = $a; D = $d }
        } catch {}
    }
    return $axes
}

# ============================================
# CAPTURE: target datum points
# ============================================
# Build a map of REAL datum points in the model up front, keyed by ID (datinator's
# proven ListItems(ITEM_POINT) + $pt.Id). The map holds the IpfcPoint OBJECT, not
# just a bool, because the off-plane filter below needs each point's .Point xyz.
# Captured selections are validated against this map, so a stray surface/edge in
# the buffer, or a stale ID, is rejected before anything mutates the model.
$pfcType = New-Object -ComObject pfcls.pfcModelItemType
$pointById = @{}
try {
    foreach ($pt in @($model.ListItems($pfcType.ITEM_POINT))) {
        try { $pointById[[int]$pt.Id] = $pt } catch {}
    }
} catch {}
if ($pointById.Count -eq 0) {
    throw "No datum points exist in the active model -- nothing to drill. Create datum points first."
}

$points = ($session.CurrentSelectionBuffer()).Contents
if ($points -eq $null) {
    Write-Host "  Select the target datum points in Creo," -ForegroundColor White
    Write-Host "  then press ENTER here." -ForegroundColor White
    Read-Host
    $points = ($session.CurrentSelectionBuffer()).Contents
}
if ($points -eq $null) { throw "Selection buffer is empty -- no datum points selected." }

# Dedup + validate: keep first occurrence of each ID that is a real datum point.
$pointIDs = @()
$seen = @{}
$rejected = 0
foreach ($item in $points) {
    $id = $null
    try { $id = [int]$item.SelItem.Id } catch { continue }
    if ($seen.ContainsKey($id)) { continue }                 # duplicate selection
    $seen[$id] = $true
    if ($pointById.ContainsKey($id)) { $pointIDs += $id }    # real datum point
    else { $rejected++ }                                     # not a datum point
}

if ($rejected -gt 0) {
    Write-Host ("  Ignored {0} selected item(s) that are not datum points." -f $rejected) -ForegroundColor Yellow
}
if ($pointIDs.Count -eq 0) {
    throw "No valid datum points in the selection (selected items were not datum points)."
}
Write-Host ("  Captured {0} valid target point(s)." -f $pointIDs.Count) -ForegroundColor Green

# ============================================
# HOLE DIAMETER (= bushing OD) -- REQUIRED, it drives creation
# ============================================
# The diameter is set directly in the hole dashboard, so it is mandatory now
# (not verify-only as in the duplicate design). It is normally resolved upstream
# by jiginator, which writes it to last_jig_spec.json; we read that as the
# default so the configurator hands off end-to-end. The user accepts it (ENTER)
# or overrides with a number. A valid positive diameter is required to proceed.

# Pull jiginator's resolved hole diameter from the handoff file, if present.
$jigDia = $null
$jigInfo = $null
$handoffPath = Join-Path $ScriptDir 'last_jig_spec.json'
if (Test-Path $handoffPath) {
    try {
        $spec = Get-Content $handoffPath -Raw | ConvertFrom-Json
        if ($null -ne $spec.HoleDiameter -and [double]$spec.HoleDiameter -gt 0) {
            $jigDia  = [double]$spec.HoleDiameter
            $jigInfo = $spec.Bushing
            Write-Host ("  jiginator handoff: hole diameter {0}`"  ({1})" -f $jigDia, $jigInfo) -ForegroundColor Cyan
        }
    } catch {
        Write-Host "  (found last_jig_spec.json but could not parse it; ignoring)" -ForegroundColor Yellow
    }
}

# Resolve a valid positive diameter -- loop until we have one (it is required).
$holeDia = 0.0
while ($holeDia -le 0) {
    if ($null -ne $jigDia) {
        $diaInput = Read-Host ("  Hole diameter [ENTER = {0}, or number to override]" -f $jigDia)
        if ([string]::IsNullOrWhiteSpace($diaInput)) { $diaInput = "$jigDia" }
    } else {
        $diaInput = Read-Host "  Hole diameter (required)"
    }
    $d = 0.0
    if ([double]::TryParse($diaInput.Trim(), [ref]$d) -and $d -gt 0) {
        $holeDia = $d
    } else {
        Write-Host "  Enter a positive number for the hole diameter." -ForegroundColor Yellow
    }
}
$targetRadius = $holeDia / 2.0
Write-Host ("  Creating holes at diameter {0}`" (r={1})." -f $holeDia, $targetRadius) -ForegroundColor Green

# ============================================
# TARGET BODY (which solid body the hole cuts)
# ============================================
# The recorded hole macro selects a body in the dashboard's body panel by LIST
# INDEX (PH.bodyselectrepwdg_list). We enumerate solid bodies to choose that
# index: a single-body part defaults to 0 silently; a multi-body part prompts.
# The list index here is the body's position in ListItems(ITEM_BODY), which we
# assume matches the dashboard's body-list order (the dashboard lists the part's
# solid bodies in the same model order). On a single-body part the panel may not
# even appear -- index 0 is then harmless.
$bodyIndex = 0
$bodyList = @()
try { $bodyList = @($model.ListItems($pfcType.ITEM_BODY)) } catch {}
if ($bodyList.Count -gt 1) {
    Write-Host ""
    Write-Host ("  This part has {0} solid bodies. Which one should the holes cut?" -f $bodyList.Count) -ForegroundColor Cyan
    for ($i = 0; $i -lt $bodyList.Count; $i++) {
        $bn = try { $bodyList[$i].GetName() } catch { "(unnamed)" }
        Write-Host ("    {0,3}) body index {0} -- {1}" -f $i, $bn) -ForegroundColor White
    }
    Write-Host ""
    while ($true) {
        $raw = Read-Host ("  Pick body (0-{0})" -f ($bodyList.Count - 1))
        $n = -1
        if ([int]::TryParse($raw, [ref]$n) -and $n -ge 0 -and $n -lt $bodyList.Count) { $bodyIndex = $n; break }
        Write-Host ("  Enter a number between 0 and {0}." -f ($bodyList.Count - 1)) -ForegroundColor Yellow
    }
    Write-Host ("  Holes will cut body index {0}." -f $bodyIndex) -ForegroundColor Green
} elseif ($bodyList.Count -eq 1) {
    Write-Host "  Single-body part -- holes cut body index 0." -ForegroundColor DarkGray
}

# ============================================
# OFF-PLANE FILTER (mirror of datinator's projection math)
# ============================================
# A drill jig is a flat plate: every hole should sit ON the jig face. A datum
# point floating off that plane would drill a hole that misses the plate (or
# punches it at the wrong place). We project each point into a chosen CSYS frame
# exactly as datinator does -- off = (P - O) . Zaxis -- and treat |off| > tol as
# off-plane. The SAME frame and the SAME formula mean holeinator's verdict
# matches datinator's OffPlane column, so the two tools never disagree.
# (Get-Comp / Dot are defined once at the top of the logic block.)

# --- choose the projection frame (same logic as datinator) ---
$csysList = @()
try { $csysList = @($model.ListItems($pfcType.ITEM_COORD_SYS)) } catch {}

$origin = @(0.0, 0.0, 0.0)
$xAxis  = @(1.0, 0.0, 0.0)
$yAxis  = @(0.0, 1.0, 0.0)
$zAxis  = @(0.0, 0.0, 1.0)
$csysName = "(world)"

if ($csysList.Count -ge 1) {
    $chosenCsys = $null
    if ($csysList.Count -eq 1) {
        $chosenCsys = $csysList[0]
    } else {
        Write-Host ""
        Write-Host "  Multiple coordinate systems - pick the one that defines the jig plane:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $csysList.Count; $i++) {
            $nm = try { $csysList[$i].GetName() } catch { "(unnamed)" }
            Write-Host ("    {0,3}) {1}" -f ($i + 1), $nm) -ForegroundColor White
        }
        Write-Host ("    {0,3}) world frame (no transform)" -f 0) -ForegroundColor DarkGray
        Write-Host ""
        while ($true) {
            $raw = Read-Host "  Pick CSYS (0-$($csysList.Count))"
            $n = -1
            if ([int]::TryParse($raw, [ref]$n) -and $n -ge 0 -and $n -le $csysList.Count) {
                if ($n -ge 1) { $chosenCsys = $csysList[$n - 1] }
                break
            }
            Write-Host "  Enter a number between 0 and $($csysList.Count)." -ForegroundColor Yellow
        }
    }
    if ($null -ne $chosenCsys) {
        try {
            $xf = $chosenCsys.CoordSys
            $origin = Get-Comp $xf.GetOrigin()
            $xAxis  = Get-Comp $xf.GetXAxis()
            $yAxis  = Get-Comp $xf.GetYAxis()
            $zAxis  = Get-Comp $xf.GetZAxis()
            $csysName = try { $chosenCsys.GetName() } catch { "(unnamed)" }
        } catch {
            Write-Host "  Could not read CSYS transform; using world frame." -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "  No coordinate system in model - using world frame for the plane check." -ForegroundColor DarkGray
}
Write-Host ("  Plane-check frame: {0}" -f $csysName) -ForegroundColor Green

# --- filter the captured points by off-plane distance ---
# Cache each point's xyz as we read it so the idempotency check below doesn't
# have to call .Point a second time.
$offTol = 1e-4                              # same threshold datinator flags at
$onPlane = @()
$offPlane = @()
$xyzById = @{}
foreach ($id in $pointIDs) {
    $pt = $pointById[$id]
    $xyz = $null
    try { $xyz = Get-Comp $pt.Point } catch {}
    if ($null -eq $xyz) {
        # cannot read coords -> cannot vouch it's on-plane; treat as off-plane
        $offPlane += [pscustomobject]@{ Id = $id; Off = [double]::NaN }
        continue
    }
    $xyzById[$id] = $xyz
    $d = @($xyz[0] - $origin[0], $xyz[1] - $origin[1], $xyz[2] - $origin[2])
    $off = Dot $d $zAxis
    if ([Math]::Abs($off) -le $offTol) { $onPlane += $id }
    else { $offPlane += [pscustomobject]@{ Id = $id; Off = $off } }
}

if ($offPlane.Count -gt 0) {
    Write-Host ""
    Write-Host ("  {0} of {1} selected point(s) are OFF the '{2}' plane (|off| > {3}):" -f `
        $offPlane.Count, $pointIDs.Count, $csysName, $offTol) -ForegroundColor Yellow
    foreach ($o in ($offPlane | Sort-Object { [Math]::Abs($_.Off) } -Descending | Select-Object -First 10)) {
        $offTxt = if ([double]::IsNaN($o.Off)) { "(coords unreadable)" } else { ("{0:0.######}" -f $o.Off) }
        Write-Host ("      point id {0,-8} off-plane = {1}" -f $o.Id, $offTxt) -ForegroundColor White
    }
    if ($offPlane.Count -gt 10) {
        Write-Host ("      ... and {0} more" -f ($offPlane.Count - 10)) -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "  These would drill holes that miss the jig face." -ForegroundColor Yellow
    Write-Host "  [S] skip them and drill only the on-plane points (recommended)" -ForegroundColor White
    Write-Host "  [A] drill ALL selected points anyway (override)" -ForegroundColor White
    Write-Host "  [Q] quit without changing anything" -ForegroundColor White
    while ($true) {
        $resp = Read-Host "  Choice (S/A/Q)"
        if ($resp -match '^[Qq]$') {
            Write-Host "  Cancelled -- nothing was changed in the model." -ForegroundColor Yellow
            return
        }
        if ($resp -match '^[Aa]$') {
            Write-Host ("  Overriding -- drilling all {0} point(s) including off-plane." -f $pointIDs.Count) -ForegroundColor Yellow
            break
        }
        if ($resp -match '^[Ss]$' -or $resp -eq '') {
            $pointIDs = @($onPlane)
            Write-Host ("  Skipping off-plane points -- {0} on-plane point(s) remain." -f $pointIDs.Count) -ForegroundColor Green
            break
        }
        Write-Host "  Enter S, A, or Q." -ForegroundColor Yellow
    }
    if ($pointIDs.Count -eq 0) {
        throw "No on-plane datum points remain to drill."
    }
} else {
    Write-Host ("  All {0} selected point(s) lie on the plane." -f $pointIDs.Count) -ForegroundColor DarkGray
}

# ============================================
# BASELINE: cylinder count before any holes are created
# ============================================
$baselineCyl = Count-Cylinders -Model $model -TargetRadius $targetRadius
Write-Host ("  Baseline cylinders @ r={0}: {1}" -f $targetRadius, $baselineCyl) -ForegroundColor DarkGray

# ============================================
# IDEMPOTENCY -- skip points that already carry a hole at this radius
# ============================================
# Re-running on the same part should not stack a second hole on a point that was
# already drilled. Read every existing same-radius cylinder axis; a candidate
# point is "already drilled" if it lies on one of those axes (perpendicular
# distance ~0). Purely geometric -- no sidecar log that could drift from the
# model. The check only runs once we are sure the create macro is real (the
# placeholder guard is below); doing it here keeps all the read-only analysis
# together, and if the guard later SAFE-STOPs nothing was mutated anyway.
$existingAxes = Get-CylinderAxes -Model $model -TargetRadius $targetRadius
$axisTol = 1e-3                            # on-axis if perpendicular dist <= this
$toDrill = @()
$already = @()
foreach ($id in $pointIDs) {
    $xyz = $xyzById[$id]
    if ($null -eq $xyz) {
        # off-plane override kept a coords-unreadable point; can't test -> drill it
        $toDrill += $id
        continue
    }
    $hit = $false
    foreach ($ax in $existingAxes) {
        if ((Dist-PointToAxis -P $xyz -A $ax.A -D $ax.D) -le $axisTol) { $hit = $true; break }
    }
    if ($hit) { $already += $id } else { $toDrill += $id }
}

if ($already.Count -gt 0) {
    Write-Host ("  Idempotency: {0} of {1} point(s) already have a hole at r={2} -- skipping them." -f `
        $already.Count, $pointIDs.Count, $targetRadius) -ForegroundColor Cyan
    $pointIDs = @($toDrill)
}
if ($pointIDs.Count -eq 0) {
    Write-Host ""
    Write-Host "  Nothing to do -- every selected point is already drilled at this radius." -ForegroundColor Green
    Write-Host "  Model unchanged." -ForegroundColor Green
    return
}
Write-Host ("  {0} point(s) to drill." -f $pointIDs.Count) -ForegroundColor Green
Write-Host ""

# ============================================
# DRY-RUN -- report the plan, change nothing
# ============================================
# Everything to here is read-only analysis. In --dry-run we print exactly what
# WOULD be drilled (id + coords + projected U,V) and stop short of the mutate
# gate. This lets the whole pipeline be validated against a real part today,
# independent of the hole-dashboard recording.
if ($DryRun) {
    Write-Host "  === DRY RUN -- plan only, no geometry will be created ===" -ForegroundColor Magenta
    Write-Host ("  Hole diameter : {0}`"  (radius {1})" -f $holeDia, $targetRadius) -ForegroundColor White
    Write-Host ("  Plane frame   : {0}" -f $csysName) -ForegroundColor White
    Write-Host ("  Target body   : index {0}" -f $bodyIndex) -ForegroundColor White
    Write-Host ("  Would drill   : {0} hole(s)" -f $pointIDs.Count) -ForegroundColor White
    if ($already.Count -gt 0) { Write-Host ("  Already drilled (skipped): {0}" -f $already.Count) -ForegroundColor DarkGray }
    if ($offPlane.Count -gt 0) { Write-Host ("  Off-plane (per earlier choice): {0}" -f $offPlane.Count) -ForegroundColor DarkGray }
    Write-Host ""
    $planRows = foreach ($id in $pointIDs) {
        $xyz = $xyzById[$id]
        if ($null -ne $xyz) {
            $dd = @($xyz[0] - $origin[0], $xyz[1] - $origin[1], $xyz[2] - $origin[2])
            [pscustomobject]@{
                PointID = $id
                X = [math]::Round($xyz[0],4); Y = [math]::Round($xyz[1],4); Z = [math]::Round($xyz[2],4)
                PlaneU = [math]::Round((Dot $dd $xAxis),4)
                PlaneV = [math]::Round((Dot $dd $yAxis),4)
            }
        } else {
            [pscustomobject]@{ PointID = $id; X='?'; Y='?'; Z='?'; PlaneU='?'; PlaneV='?' }
        }
    }
    $planRows | Sort-Object PlaneV, PlaneU | Format-Table -AutoSize | Out-Host
    Write-Host "  Dry run complete -- model unchanged. Re-run without --dry-run to drill." -ForegroundColor Green
    return
}

# ============================================
# HOLE-MACRO BUILDER (RECORDED -- real widget names, 2026-06-11)
# ============================================
# Builds the per-point macro for one datum-point ID. Two parts:
#  (1) select the target datum point BY ID -- the proven nodelator/radinator
#      tree-search block. This leaves exactly the target point in the selection
#      buffer, so ProCmdHole comes up in On-Point placement automatically (the
#      placement type is implied by the pre-selected point -- there is no
#      separate "on point" widget to click).
#  (2) the hole dashboard, transcribed from a live recording on the jig part.
#      `~ Trail` / `~ Timer` lines from the recording are dropped (mouse/UI
#      noise, per CLAUDE.md). The whole thing is ONE concatenated RunMacro
#      string -- a dashboard's command context does not survive across RunMacro
#      calls (boxinator lesson).
#
# Recorded widget map (replaces the former <<placeholders>>):
#   command            : ProCmdHole
#   depth = thru all   : open `maindashInst0.hole_depth_to_type_flybtn` flyout,
#                        then `maindashInst0.StrHoleDepThruAllF`
#   diameter field     : `maindashInst0.diameter_mip_OptionMenu`
#   confirm            : `dashInst0.Done`
#   blur before Done   : `~ FocusOut` on the diameter field (recording's method;
#                        NOT the Enter/Exit Quit hover trick)
#
# MULTI-BODY: the recording targets a specific solid body via the body-selection
# panel (`chkbn.body_page.0` enables it, then `PH.bodyselectrepwdg_list` picks a
# body by list index). $BodyIndex selects which body the hole cuts; the recorded
# part used index 0. On a single-body part this panel may not appear -- see the
# note in the create-loop section.
function Build-HoleMacro {
    param([int]$PointId, [double]$Diameter, [int]$BodyIndex = 0)
    return "~ Activate ``main_dlg_cur`` ``buffer_clean``;" +
        # --- (1) select the target datum point by ID (proven select-by-ID block) ---
        "~ Command ``ProCmdMdlTreeSearch``;" +
        "~ Open ``selspecdlg0`` ``SelOptionRadio``;" +
        "~ Close ``selspecdlg0`` ``SelOptionRadio``;" +
        "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Point``;" +
        "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
        "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$PointId``;" +
        "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
        "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
        "~ Activate ``selspecdlg0`` ``CancelButton``;" +
        # --- (2) hole dashboard (recorded) -------------------------------------
        "~ Command ``ProCmdHole``;" +
        # depth -> through all (open the depth-type flyout, pick Thru All)
        "~ Select ``main_dlg_cur`` ``maindashInst0.hole_depth_to_type_flybtn``;" +
        "~ Close  ``main_dlg_cur`` ``maindashInst0.hole_depth_to_type_flybtn``;" +
        "~ Activate ``main_dlg_cur`` ``maindashInst0.StrHoleDepThruAllF`` 1;" +
        # standard-hole layout + hole-note toggles (as recorded)
        "~ Activate ``main_dlg_cur`` ``chkbn.std_hle_layout.0`` 1;" +
        "~ Activate ``main_dlg_cur`` ``chkbn.std_hole_note_layout.0`` 1;" +
        # body selection: enable the body page, then pick body $BodyIndex
        "~ Activate ``main_dlg_cur`` ``chkbn.body_page.0`` 1;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ``$BodyIndex``;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ````;" +
        "~ Focus  ``body_page.1.0`` ``PH.bodyselectrepwdg_list``;" +
        "~ Select ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` 1 ``$BodyIndex``;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ````;" +
        # diameter
        "~ Input  ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu`` ``$Diameter``;" +
        "~ Update ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu`` ``$Diameter``;" +
        "~ Activate ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu``;" +
        "~ FocusOut ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu``;" +
        # confirm
        "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"
}

# ============================================
# PLACEHOLDER GUARD -- never fire unrecorded macro text into a live model
# ============================================
# A macro still containing "<<...>>" tokens is a scaffold, not a real trail.
# Firing it would push literal placeholder strings into Creo's command stream
# (best case a no-op, worst case an unpredictable UI action). Refuse, and tell
# the user exactly which tokens are still unrecorded.
$probe = Build-HoleMacro -PointId 0 -Diameter 1.0
$placeholders = @([regex]::Matches($probe, '<<[^>]+>>') | ForEach-Object { $_.Value } | Select-Object -Unique)
if ($placeholders.Count -gt 0) {
    Write-Host ""
    Write-Host "  SAFE-STOP: the hole-creation macro is not recorded yet." -ForegroundColor Yellow
    Write-Host "  These placeholder tokens must be replaced with real Creo" -ForegroundColor Yellow
    Write-Host "  command/widget names before any holes can be created:" -ForegroundColor Yellow
    foreach ($p in $placeholders) { Write-Host "      $p" -ForegroundColor White }
    Write-Host ""
    Write-Host "  How: set 'visible_mapkeys yes' in config.pro, drop one On-Point" -ForegroundColor DarkGray
    Write-Host "  hole by hand, read the trail, edit Build-HoleMacro in this script." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Nothing was changed in the model." -ForegroundColor Green
    return
}

# ============================================
# MUTATE GATE -- explicit confirmation before changing the model
# ============================================
# Everything above this point is read-only. This is the last stop before the
# script writes geometry, so it states exactly what will happen and waits for an
# explicit 'y'. (Mirrors boxinator's gated repair: never auto-drive a mutation.)
Write-Host ""
Write-Host ("  About to create {0} hole(s) at diameter {1}`" (through all) in body index {2}." -f $pointIDs.Count, $holeDia, $bodyIndex) -ForegroundColor Cyan
Write-Host "  Do not touch Creo while this runs." -ForegroundColor DarkGray
$go = Read-Host "  Proceed? (y/N)"
if ($go -notmatch '^[Yy]$') {
    Write-Host "  Cancelled -- nothing was changed in the model." -ForegroundColor Yellow
    return
}
Write-Host ""

# ============================================
# CREATE loop -- one On-Point hole per datum point
# ============================================
# A CANARY first: create hole #1, verify the cylinder count actually rose, and
# only then commit to the rest. If the very first hole does not register, the
# macro is wrong -- abort immediately rather than firing a broken macro N times
# and leaving a mess. After the canary, a run of consecutive no-op/error holes
# also aborts (the model may have entered a bad state mid-run).
$totalPoints = $pointIDs.Count
$pointIndex = 0
$script:macroFailures = 0      # macro threw
$script:noOpCount = 0          # macro ran but VersionStamp never moved
$consecBad = 0
$aborted = $false

foreach ($item in $pointIDs) {
    $pointIndex++
    $pct = [Math]::Floor(($pointIndex / $totalPoints) * 100)
    Show-Progress $pct "Hole $pointIndex/$totalPoints"

    $createHole = Build-HoleMacro -PointId $item -Diameter $holeDia -BodyIndex $bodyIndex

    $changed = $false
    try {
        $stamp = $model.VersionStamp
        $session.RunMacro($createHole)
        $changed = Wait-ModelModified -Model $model -PreviousStamp $stamp
        if (-not $changed) { $script:noOpCount++ }
    } catch {
        $script:macroFailures++
    }

    if ($changed) {
        $consecBad = 0
    } else {
        $consecBad++
    }

    # --- canary: validate the FIRST hole geometrically before trusting the rest
    if ($pointIndex -eq 1) {
        $cylNow = Count-Cylinders -Model $model -TargetRadius $targetRadius
        if (($cylNow - $baselineCyl) -lt 1) {
            Show-Progress 100 "Canary failed"
            Write-Host ""
            Write-Host "  ABORT: the first hole did not register a new cylinder at" -ForegroundColor Red
            Write-Host ("  r={0}. The hole macro is firing but not producing geometry." -f $targetRadius) -ForegroundColor Red
            Write-Host "  Stopped after 1 attempt so the model is not littered with" -ForegroundColor Red
            Write-Host "  failed features. Re-record the hole dashboard trail." -ForegroundColor Red
            $aborted = $true
            break
        }
    }

    # --- consecutive-failure circuit breaker (after the canary) ---------------
    if ($consecBad -ge 3) {
        Show-Progress 100 "Aborted"
        Write-Host ""
        Write-Host ("  ABORT: {0} consecutive holes made no change to the model." -f $consecBad) -ForegroundColor Red
        Write-Host "  Stopping to avoid hammering a session in a bad state." -ForegroundColor Red
        $aborted = $true
        break
    }
}
if (-not $aborted) { Show-Progress 100 "Holes complete" }
Write-Host ""

# ============================================
# GEOMETRIC VERIFY (the piece nodelator lacks)
# ============================================
# Re-measure: count cylinders again and compare the increase to how many holes
# were actually ATTEMPTED (which may be < totalPoints if the run aborted).
# "Confirmed" means holes were measured on the solid, not that macros fired.
$finalCyl = Count-Cylinders -Model $model -TargetRadius $targetRadius
$created = $finalCyl - $baselineCyl
$attempted = $pointIndex                       # how many we actually tried

Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
Write-Host ("  Target points        : {0}" -f $totalPoints) -ForegroundColor White
if ($attempted -ne $totalPoints) {
    Write-Host ("  Holes attempted      : {0}  (run did not cover all points)" -f $attempted) -ForegroundColor Yellow
}
Write-Host ("  Cylinders @ r={0,-8}: {1} -> {2}  (+{3})" -f $targetRadius, $baselineCyl, $finalCyl, $created) -ForegroundColor White
if ($script:macroFailures -gt 0) {
    Write-Host ("  Macro errors (threw) : {0}" -f $script:macroFailures) -ForegroundColor Yellow
}
if ($script:noOpCount -gt 0) {
    Write-Host ("  No-op holes (no chg) : {0}" -f $script:noOpCount) -ForegroundColor Yellow
}
Write-Host ""

# Note: a straight through-bore typically contributes ONE cylindrical surface,
# but a counterbore/csink hole contributes more. Compare $created against the
# number ATTEMPTED, allowing an exact multiple (surfaces-per-hole).
$clean = ($script:macroFailures -eq 0 -and $script:noOpCount -eq 0 -and -not $aborted)

if ($aborted) {
    Write-Host "  STOPPED EARLY -- run aborted by a safety check (see above)." -ForegroundColor Red
    Write-Host ("  Measured +{0} cylinder(s) before stopping. Inspect the model" -f $created) -ForegroundColor Yellow
    Write-Host "  in Creo before re-running." -ForegroundColor Yellow
} elseif ($created -eq $attempted -and $clean) {
    Write-Host "  Done -- $created hole(s) created and confirmed (measured)." -ForegroundColor Green
} elseif ($attempted -gt 0 -and ($created % $attempted) -eq 0 -and $created -gt 0 -and $clean) {
    $per = $created / $attempted
    Write-Host "  Done -- $attempted hole(s) confirmed ($per cylindrical surfaces each)." -ForegroundColor Green
} else {
    Write-Host "  NOT confirmed: attempted $attempted, measured +$created cylinder(s)." -ForegroundColor Yellow
    Write-Host "  Inspect the model in Creo. If the macro fired but produced no" -ForegroundColor Yellow
    Write-Host "  geometry, the hole-dashboard trail likely needs re-recording." -ForegroundColor Yellow
}

} finally {
    try {
        if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null }
        if ($null -ne $origDynamicPreview)  { $session.SetConfigOption("dynamic_preview",  $origDynamicPreview)  | Out-Null }
    } catch {}
    $connection.Disconnect($null)
}
