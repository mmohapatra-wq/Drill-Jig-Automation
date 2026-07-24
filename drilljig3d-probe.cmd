<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "DRILLJIG3D-PROBE (READ-ONLY)"
$ErrorActionPreference = "Stop"

# ============================================================================
# DRILLJIG3D-PROBE  -- a READ-ONLY diagnostic (creates / mutates NOTHING)
# ============================================================================
# GOAL: settle the load-bearing questions for the CURVED (conformal) drill jig,
# the 3D analog of the flat drilljig -- BEFORE the MVP trusts that "the holes are
# normal to the surface". drilljig3d.cmd's Build-NormalHoleMacro pre-selects the
# host surface as an orientation HYPOTHESIS; the fastener component axis as the
# hole normal is REFUTED live (the bolt axis can lie IN the plate plane). So the
# per-hole angularity must be READ from geometry, and this probe proves the reads
# work on THIS build without guessing (the reference_mine_trail / fastener-probe /
# pointref-probe methodology: probe, don't guess).
#
# It NEVER creates a feature. It NEVER reads IpfcPoint.Point (crashes -- the
# holeinator lesson: op_Subtraction on System.Object[]). Positions/directions come
# ONLY from cylinder-axis descriptors (Get-CylinderAxes / Get-CylinderAxisFromSurface:
# descriptor.Origin.GetOrigin()/.GetZAxis()) and, for the surface normal, the
# docs-only IpfcSurface.Eval3DData family, wrapped so it can NEVER crash the run.
#
# THREE probe modes, selected by flags (default: --probe-orient):
#
#   --probe-orient  (go/no-go for "holes are normal to the surface"):
#       The operator has (a) built a conformal blank via drilljig3d and DRILLED one
#       test hole, then (b) SELECTED the just-drilled BORE surface + the host
#       surface it should be normal to. The probe READS:
#         - the bore axis DIRECTION via Get-CylinderAxisFromSurface (.D = GetZAxis),
#         - the surface NORMAL at the bore origin via IpfcSurface.Eval3DData,
#       computes |dot(axisDir, surfaceNormal)| and reports the angle off-normal.
#       |dot| ~ 1 (angle ~ 0 deg) => holes ARE normal to the surface (GO).
#       Eval3DData is DOCS-ONLY on this build (never called in the repo): every
#       call is in try/catch and reports whether it is usable; if not, the fallback
#       is a VISUAL normality check (stated clearly). READ-ONLY.
#
#   --probe-axis-read  (proves per-hole angularity is readable):
#       The operator selects 2+ drilled bores on the curved blank; the probe reports
#       each bore's axis DIRECTION and whether the directions are DISTINCT (they must
#       differ where curvature differs). Distinct dirs => angularity is readable per
#       hole and can drive per-hole orientation. READ-ONLY.
#
#   --probe-volume  (is body Volume readable?):
#       For each ITEM_BODY, TRY GetMassProperty($null).Volume in try/catch and report
#       whether .Volume reads + the value (only .GravityCenter is confirmed today).
#       READ-ONLY.
#
# Writes drilljig3d_probe_report.txt (gitignored). ONE Creo session, PART mode only
# (.asm guard). Open the conformal-blank PART with a drilled test hole (orient mode)
# or several drilled holes (axis-read mode).
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
$argStr = [string]$ScriptArgs
$doOrient   = $argStr -match '(?i)--probe-orient'
$doAxisRead = $argStr -match '(?i)--probe-axis-read'
$doVolume   = $argStr -match '(?i)--probe-volume'
# default: --probe-orient (the go/no-go the MVP hangs on)
if (-not ($doOrient -or $doAxisRead -or $doVolume)) { $doOrient = $true }

$modeList = @()
if ($doOrient)   { $modeList += 'orient' }
if ($doAxisRead) { $modeList += 'axis-read' }
if ($doVolume)   { $modeList += 'volume' }

# ============================================
# HEADER
# ============================================
Write-Host ""
Write-Host "  DRILLJIG3D-PROBE (READ-ONLY) -- curved-jig orientation / axis-read / volume checks" -ForegroundColor Cyan
Write-Host "  Creates nothing. Every read is in try/catch; NEVER reads IpfcPoint.Point." -ForegroundColor DarkGray
Write-Host ("  Modes: {0}" -f ($modeList -join ', ')) -ForegroundColor DarkGray
Write-Host ""

# shared read helpers (Get-Comp, Dot, Cross, Get-CylinderAxes,
# Get-CylinderAxisFromSurface, Get-AllSurfaces)
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
if ($null -eq $model) { throw "No active model. Open the conformal-blank PART to probe." }

$pfcType = New-Object -ComObject pfcls.pfcModelItemType

$fname = try { [string]$model.FileName } catch { "" }

# ----------------------------------------------------------------------------
# Mode guard: PART only. By-ID selection + geometry reads resolve against the
# active model; in assembly mode that is the .asm, not the part to jig. Key off
# the filename extension (EpfcModelType enum ints unconfirmed on this build --
# drilljig3d.cmd:646 lesson).
# ----------------------------------------------------------------------------
if ($fname -match '(?i)\.asm(\.\d+)?$') {
    Write-Host ""
    Write-Host "  STOP: the active model is an ASSEMBLY ($fname)." -ForegroundColor Yellow
    Write-Host "  This probe reads a single conformal-blank PART. Open the PART, then re-run." -ForegroundColor Yellow
    try { $connection.Disconnect($null) } catch {}
    exit 1
}

Write-Host "  Connected. Active model: $fname" -ForegroundColor Green
Write-Host ""

# ============================================
# CONFIG SUPPRESS (restore in finally) -- toolkit convention, even for a read-only
# run: keep the UI quiet. No mutation happens either way.
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
try {
    $session.SetConfigOption("visible_mapkeys", "no") | Out-Null
    $session.SetConfigOption("dynamic_preview", "no") | Out-Null
} catch {}

# ----------------------------------------------------------------------------
# report helpers
# ----------------------------------------------------------------------------
$script:report = @()
function Rep { param([string]$Line, [string]$Color = 'Gray') Write-Host ("  " + $Line) -ForegroundColor $Color; $script:report += $Line }
function Fmt-Pt { param($P) if ($null -eq $P) { return '(null)' }; try { return ('({0:0.#####}, {1:0.#####}, {2:0.#####})' -f [double]$P[0], [double]$P[1], [double]$P[2]) } catch { return '(unreadable)' } }

# ----------------------------------------------------------------------------
# Unit / Norm helpers (pure math, NEVER throw -- build each component on its own
# line, never a comma-separated @(math,math,math) literal: the PS 5.1 COM-array trap).
# ----------------------------------------------------------------------------
function P-Norm { param($V) if ($null -eq $V) { return 0.0 }; try { return [math]::Sqrt([double]$V[0]*[double]$V[0] + [double]$V[1]*[double]$V[1] + [double]$V[2]*[double]$V[2]) } catch { return 0.0 } }
function P-Unit {
    param($V)
    if ($null -eq $V) { return $null }
    $n = P-Norm $V
    if ($n -le 1e-12) { return $null }
    $x = [double]$V[0] / $n
    $y = [double]$V[1] / $n
    $z = [double]$V[2] / $n
    return @($x, $y, $z)
}

$reportFile = Join-Path $ScriptDir 'drilljig3d_probe_report.txt'
Rep ("DRILLJIG3D-PROBE report  model=$fname  modes=" + ($modeList -join ',') + "  when=" + (Get-Date).ToString('o')) 'Cyan'
Rep ""

try {

# ============================================================================
# READ THE SELECTION BUFFER ONCE -- shared by orient + axis-read modes.
# Each SelItem is a surface (bore or face); NEVER a coordinate read of a point.
# ============================================================================
function Get-SelectedBores {
    # returns @( @{ Radius; A; D; Surf; SelStr } ) for every selected item that
    # reads as a cylinder bore, plus the raw list for reporting non-cylinders.
    $bores = @(); $others = @(); $total = 0
    try {
        $buf = @(($session.CurrentSelectionBuffer()).Contents)
        $total = $buf.Count
        foreach ($sel in $buf) {
            $si = $null
            try { $si = $sel.SelItem } catch {}
            $ss = ''
            try { $ss = [string]$sel.SelectionString } catch {}
            if ($null -eq $si) { $others += [pscustomobject]@{ Sel = $ss; Why = 'no SelItem' }; continue }
            $ax = $null
            try { $ax = Get-CylinderAxisFromSurface -Surf $si } catch {}
            if ($null -ne $ax) {
                $bores += [pscustomobject]@{ Radius = [double]$ax.Radius; A = $ax.A; D = $ax.D; Surf = $si; SelStr = $ss }
            } else {
                # keep the surface item around (non-cylinder = the host FACE candidate for orient mode)
                $others += [pscustomobject]@{ Sel = $ss; Why = 'not a cylinder'; Surf = $si }
            }
        }
    } catch { Rep ("Selection-buffer read threw: $($_.Exception.Message)") 'Red' }
    return [pscustomobject]@{ Total = $total; Bores = $bores; Others = $others }
}

# ============================================================================
# SURFACE-NORMAL read (DOCS-ONLY on this build -- IpfcSurface.Eval3DData family).
# NEVER crashes the run: every COM leg is in try/catch; a miss returns $null with
# a human-readable reason, and the caller falls back to the visual normality check.
#
# Strategy (all read-only, no IpfcPoint.Point):
#   1. Build an IpfcPoint3D at the bore origin. We cannot hand Eval* a raw PS array
#      (that IS the op_Subtraction-on-array trap); we ask the geometry factory to
#      make one. "CC*/CM*" factory names are NEVER standalone ProgIDs, so cascade
#      candidate ProgIDs (pfcls.pfcPoint3D was seen registered for the sibling
#      transform reads); if none construct, Eval3DData is reported UNUSABLE here.
#   2. surf.EvalParameters(point) -> IpfcUVParams (project the origin onto the surf).
#   3. surf.Eval3DData(uv) -> IpfcSurfXYZData. Read the normal, trying in order:
#        a) .Normal  (docs list it among the returned fields),
#        b) cross(FirstDerivative rows)  (dU x dV = surface normal) if .Normal null.
# Returns @{ N = <unit normal[3]>; How = 'Normal'|'derivatives'; Uv = '(u,v)' } or
#   @{ N = $null; Reason = '<why>' }.
# ============================================================================
function New-Point3DAt {
    param($XYZ)   # @(x,y,z) doubles
    if ($null -eq $XYZ) { return $null }
    # cascade candidate ProgIDs for the Point3D value object (never the CC*/CM* name)
    foreach ($pid in @('pfcls.pfcPoint3D')) {
        $p = $null
        try { $p = New-Object -ComObject $pid } catch { continue }
        if ($null -eq $p) { continue }
        # set the three components; the object is a 3-sequence -- write by index,
        # then by .Item, whichever the projection accepts.
        $set = $false
        try { $p.Set(0, [double]$XYZ[0]); $p.Set(1, [double]$XYZ[1]); $p.Set(2, [double]$XYZ[2]); $set = $true } catch {}
        if (-not $set) { try { $p[0] = [double]$XYZ[0]; $p[1] = [double]$XYZ[1]; $p[2] = [double]$XYZ[2]; $set = $true } catch {} }
        if (-not $set) { try { $p.Item(0) = [double]$XYZ[0]; $p.Item(1) = [double]$XYZ[1]; $p.Item(2) = [double]$XYZ[2]; $set = $true } catch {} }
        if ($set) { return $p }
    }
    return $null
}

function Read-SurfaceNormalAt {
    param($Surf, $OriginXYZ)
    if ($null -eq $Surf) { return @{ N = $null; Reason = 'no surface item' } }

    # 1. IpfcPoint3D at the bore origin (for the projection). Read-only construction.
    $pt = $null
    try { $pt = New-Point3DAt $OriginXYZ } catch {}
    if ($null -eq $pt) {
        return @{ N = $null; Reason = 'could not construct an IpfcPoint3D (Eval3DData projection input) on this build' }
    }

    # 2. project the origin onto the surface -> UV params
    $uv = $null
    try { $uv = $Surf.EvalParameters($pt) } catch { return @{ N = $null; Reason = "EvalParameters threw: $($_.Exception.Message)" } }
    if ($null -eq $uv) { return @{ N = $null; Reason = 'EvalParameters returned null (point not on surface)' } }
    $uvStr = '(uv unreadable)'
    try { $uvStr = ('({0:0.###}, {1:0.###})' -f [double]$uv[0], [double]$uv[1]) } catch {}

    # 3. evaluate the surface at UV -> IpfcSurfXYZData
    $xyz = $null
    try { $xyz = $Surf.Eval3DData($uv) } catch { return @{ N = $null; Reason = "Eval3DData threw: $($_.Exception.Message)" } }
    if ($null -eq $xyz) { return @{ N = $null; Reason = 'Eval3DData returned null' } }

    # 3a. direct .Normal (docs list it among the fields)
    $n = $null
    try { $n = Get-Comp $xyz.Normal } catch {}
    if ($null -ne $n) {
        $u = P-Unit $n
        if ($null -ne $u) { return @{ N = $u; How = 'Normal'; Uv = $uvStr } }
    }

    # 3b. fall back to cross(FirstDerivative rows): dU x dV = the surface normal.
    #     FirstDerivative is a 2x3 (dU, dV); read both rows defensively.
    $du = $null; $dv = $null
    try {
        $fd = $xyz.FirstDerivative
        # try common shapes: .Row(0)/.Row(1), [0][*]/[1][*], .Item(0)/.Item(1)
        try { $du = Get-Comp $fd.Row(0); $dv = Get-Comp $fd.Row(1) } catch {}
        if ($null -eq $du -or $null -eq $dv) { try { $du = Get-Comp $fd[0]; $dv = Get-Comp $fd[1] } catch {} }
        if ($null -eq $du -or $null -eq $dv) { try { $du = Get-Comp $fd.Item(0); $dv = Get-Comp $fd.Item(1) } catch {} }
    } catch {}
    if ($null -ne $du -and $null -ne $dv) {
        $c = Cross $du $dv
        $u = P-Unit $c
        if ($null -ne $u) { return @{ N = $u; How = 'derivatives (dU x dV)'; Uv = $uvStr } }
    }

    return @{ N = $null; Reason = 'Eval3DData ran but neither .Normal nor FirstDerivative yielded a usable normal'; Uv = $uvStr }
}

# ============================================================================
# MODE: --probe-orient
# ============================================================================
if ($doOrient) {
    Rep "== [--probe-orient] BORE AXIS vs SURFACE NORMAL (is the hole normal to the face?) ==" 'Cyan'
    Rep "Select the just-drilled BORE surface AND the host surface it should be normal to," 'DarkGray'
    Rep "then run this mode. (The BORE reads as a cylinder; the host FACE does not.)" 'DarkGray'
    Rep ""
    $sel = Get-SelectedBores
    Rep ("Selection buffer holds {0} item(s): {1} cylinder bore(s), {2} other surface(s)." -f $sel.Total, $sel.Bores.Count, $sel.Others.Count) $(if ($sel.Bores.Count -gt 0){'Green'}else{'Yellow'})

    if ($sel.Bores.Count -lt 1) {
        Rep "No bore cylinder selected. Drill a test hole with drilljig3d, then SELECT the bore" 'Yellow'
        Rep "surface + host face and re-run --probe-orient." 'Yellow'
    } else {
        # host surface candidates = the selected NON-cylinder surface items
        $hostSurfs = @()
        foreach ($o in $sel.Others) { if ($null -ne $o.Surf) { $hostSurfs += $o.Surf } }
        Rep ("Host-surface candidates (selected non-cylinders): {0}" -f $hostSurfs.Count) $(if ($hostSurfs.Count -gt 0){'Green'}else{'Yellow'})
        Rep ""

        $bi = 0
        foreach ($b in $sel.Bores) {
            $bi++
            $axU = P-Unit $b.D
            if ($null -eq $axU) { Rep ("bore #$bi : axis direction unreadable (skipped).") 'Red'; continue }
            Rep ("bore #$bi  r={0:0.####}  origin {1}  axisDir {2}   {3}" -f [double]$b.Radius, (Fmt-Pt $b.A), (Fmt-Pt $axU), $b.SelStr) 'Green'

            if ($hostSurfs.Count -lt 1) {
                Rep "  (no host FACE selected -- cannot compare to a surface normal. Also select the" 'Yellow'
                Rep "   host face, then re-run. Falling back to a VISUAL normality check.)" 'Yellow'
                continue
            }

            # read the surface normal at the bore origin for each host candidate;
            # report |dot| and the off-normal angle.
            $hi = 0
            foreach ($hs in $hostSurfs) {
                $hi++
                $nr = Read-SurfaceNormalAt -Surf $hs -OriginXYZ $b.A
                if ($null -eq $nr.N) {
                    Rep ("  host #$hi : surface normal UNREADABLE -- {0}" -f $nr.Reason) 'Yellow'
                    Rep "           Eval3DData is docs-only on this build; if it never reads, the" 'Yellow'
                    Rep "           normality check stays VISUAL (report this line to me)." 'Yellow'
                    continue
                }
                $d = Dot $axU $nr.N
                $ad = [math]::Abs($d); if ($ad -gt 1.0) { $ad = 1.0 }
                $ang = [math]::Acos($ad) * 180.0 / [math]::PI
                $verdict = if ($ang -le 2.0) { 'NORMAL (GO)' } elseif ($ang -le 10.0) { 'near-normal' } else { 'OFF-NORMAL' }
                Rep ("  host #$hi : normal {0} (via {1}, uv {2})  |dot|={3:0.####}  angle={4:0.##} deg  -> {5}" -f (Fmt-Pt $nr.N), $nr.How, $nr.Uv, $ad, $ang, $verdict) $(if ($ang -le 2.0) {'Green'} elseif ($ang -le 10.0) {'Yellow'} else {'Red'})
            }
        }
        Rep ""
        Rep "Read |dot| ~ 1.0 / angle ~ 0 deg => the drilled bore IS normal to the surface (GO)." 'DarkGray'
        Rep "A large angle, OR an unreadable normal, means confirm normality VISUALLY for the MVP." 'DarkGray'
    }
    Rep ""
}

# ============================================================================
# MODE: --probe-axis-read
# ============================================================================
if ($doAxisRead) {
    Rep "== [--probe-axis-read] PER-HOLE BORE AXIS DIRECTIONS (are they DISTINCT?) ==" 'Cyan'
    Rep "Select 2+ drilled bores on the curved blank. Their axis directions must DIFFER" 'DarkGray'
    Rep "where curvature differs -- that proves per-hole angularity is readable." 'DarkGray'
    Rep ""
    $sel = Get-SelectedBores
    Rep ("Selection buffer holds {0} item(s): {1} readable cylinder bore(s)." -f $sel.Total, $sel.Bores.Count) $(if ($sel.Bores.Count -gt 0){'Green'}else{'Yellow'})

    if ($sel.Bores.Count -lt 1) {
        Rep "No bores selected. Select the drilled hole BORE surfaces and re-run --probe-axis-read." 'Yellow'
    } else {
        $dirs = @()
        $bi = 0
        foreach ($b in $sel.Bores) {
            $bi++
            $u = P-Unit $b.D
            if ($null -eq $u) { Rep ("bore #$bi : axis direction unreadable (skipped).") 'Red'; continue }
            $dirs += [pscustomobject]@{ I = $bi; U = $u; A = $b.A; R = [double]$b.Radius; S = $b.SelStr }
            Rep ("bore #$bi  r={0:0.####}  origin {1}  axisDir {2}   {3}" -f [double]$b.R, (Fmt-Pt $b.A), (Fmt-Pt $u), $b.SelStr) 'Green'
        }
        if ($dirs.Count -ge 2) {
            Rep ""
            Rep "Pairwise angles between bore axis directions:" 'Cyan'
            $maxAng = 0.0; $anyDistinct = $false
            for ($i = 0; $i -lt $dirs.Count; $i++) {
                for ($j = $i + 1; $j -lt $dirs.Count; $j++) {
                    $cs = Dot $dirs[$i].U $dirs[$j].U
                    $acs = [math]::Abs($cs); if ($acs -gt 1.0) { $acs = 1.0 }
                    $ang = [math]::Acos($acs) * 180.0 / [math]::PI
                    if ($ang -gt $maxAng) { $maxAng = $ang }
                    if ($ang -gt 0.5) { $anyDistinct = $true }
                    Rep ("  bore #{0} vs #{1}: {2:0.##} deg apart" -f $dirs[$i].I, $dirs[$j].I, $ang) $(if ($ang -gt 0.5) {'Green'} else {'DarkGray'})
                }
            }
            Rep ""
            if ($anyDistinct) {
                Rep ("-> axis directions DIFFER (max {0:0.##} deg). Per-hole angularity IS readable from the bores." -f $maxAng) 'Green'
            } else {
                Rep ("-> all axis directions are ~parallel (max {0:0.##} deg). Either the selected holes sit on" -f $maxAng) 'Yellow'
                Rep "   near-coplanar/low-curvature regions, or the surface is nearly flat there. Select bores" 'Yellow'
                Rep "   from clearly different curvature to confirm the read distinguishes them." 'Yellow'
            }
        } else {
            Rep "Only one readable bore -- select at least 2 to compare directions." 'Yellow'
        }
    }
    Rep ""
}

# ============================================================================
# MODE: --probe-volume
# ============================================================================
if ($doVolume) {
    Rep "== [--probe-volume] BODY VOLUME (GetMassProperty(null).Volume readable?) ==" 'Cyan'
    Rep "Only .GravityCenter is confirmed today; this checks whether .Volume also reads." 'DarkGray'
    try {
        $bodies = @($model.ListItems($pfcType.ITEM_BODY))
        Rep ("ListItems(ITEM_BODY) returned {0} bod(y/ies)." -f $bodies.Count) $(if ($bodies.Count -gt 0){'Green'}else{'Yellow'})
        $bi = 0; $volOk = 0
        foreach ($b in $bodies) {
            if ($bi -ge 20) { Rep ("  ... ({0} more bodies not sampled)" -f ($bodies.Count - 20)); break }
            $mp = $null
            try { $mp = $b.GetMassProperty($null) } catch { Rep ("  body #$bi GetMassProperty threw: $($_.Exception.Message)") 'Red'; $bi++; continue }
            if ($null -eq $mp) { Rep ("  body #$bi GetMassProperty returned null") 'Yellow'; $bi++; continue }
            # Volume
            $vol = $null
            try { $vol = [double]$mp.Volume } catch {}
            # CG (confirmed) for cross-reference / provenance
            $cg = $null
            try { $cg = Get-Comp $mp.GravityCenter } catch {}
            if ($null -ne $vol) {
                $volOk++
                Rep ("  body #$bi  Volume = {0:0.######}   CG {1}" -f $vol, (Fmt-Pt $cg)) 'Green'
            } else {
                Rep ("  body #$bi  Volume UNREADABLE   CG {0}" -f (Fmt-Pt $cg)) 'Yellow'
            }
            $bi++
        }
        Rep ""
        if ($bodies.Count -gt 0 -and $volOk -gt 0) {
            Rep ("-> body Volume reads on this build ({0} of the sampled bodies). Usable as a jig-mass / material check." -f $volOk) 'Green'
        } elseif ($bodies.Count -gt 0) {
            Rep "-> body Volume did NOT read (only GravityCenter is confirmed). Do not rely on .Volume." 'Yellow'
        }
    } catch { Rep ("ITEM_BODY enumeration threw: $($_.Exception.Message)") 'Red' }
    Rep ""
}

# ============================================
# VERDICT
# ============================================
Rep "== VERDICT ==" 'Cyan'
if ($doOrient)   { Rep "orient   : |dot(bore-axis, surface-normal)| ~ 1 => holes normal to face (GO). Unreadable normal => visual check." 'Gray' }
if ($doAxisRead) { Rep "axis-read: distinct per-hole axis directions => per-hole angularity is readable from the drilled bores." 'Gray' }
if ($doVolume)   { Rep "volume   : whether body .Volume reads (only .GravityCenter is confirmed today)." 'Gray' }
Rep "Nothing was created or modified. Re-run with different holes selected as needed." 'DarkGray'

}
finally {
    # ============================================
    # RESTORE CONFIG (even on a read-only run)
    # ============================================
    try { if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null } } catch {}
    try { if ($null -ne $origDynamicPreview) { $session.SetConfigOption("dynamic_preview", $origDynamicPreview) | Out-Null } } catch {}
}

# ============================================
# WRITE THE REPORT
# ============================================
try { Set-Content -Path $reportFile -Value ($script:report -join [Environment]::NewLine) -Encoding UTF8; Write-Host ""; Write-Host ("  Report written: $reportFile") -ForegroundColor Cyan }
catch { Write-Host ("  Could not write report: $($_.Exception.Message)") -ForegroundColor Yellow }

# ============================================
# CLEANUP
# ============================================
try { $connection.Disconnect($null) } catch {}
Write-Host ""
Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
