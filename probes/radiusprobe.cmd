<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir=((Split-Path -Parent ('%~dp0'.TrimEnd('\')))+'\'); $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "RADIUS-PROBE"
$ErrorActionPreference = "Stop"

# ============================================================================
# RADIUS-PROBE -- settle, LIVE, WHY the curved-DJ "read radial distance" failed
# and WHICH channel actually yields the follow-cylinder's radius + axis.
# ============================================================================
# The surface-arm producer (Read-CurvedRadialGeomFromBuffer, lib\curved_surface_radius.ps1)
# read the picked follow-surface's cylinder descriptor and came back Valid=$false with
# an "axis/descriptor unreadable" reason -- the classic IMPORTED/FOREIGN-body wall
# ([[project_curved_relief_extrude_plane]] / holelayoutinator: on a foreign body EVERY
# cylinder SURFACE descriptor read fails; only a hole's circular EDGE reads).
#
# This probe does NOT guess. It fires the EXACT descriptor read my producer uses, but
# SPLITS every sub-call so we see precisely which one dies on the foreign panel:
#     GetSurfaceDescriptor -> GetSurfaceType -> .Radius -> .Origin -> GetOrigin -> GetZAxis
# and it runs my real Read-CurvedSurfaceCylinderGeom alongside so its {Valid;Reason} is
# shown next to the granular truth.
#
# It probes TWO selections so we can pick the winning channel:
#   ROUND 1  the FOREIGN panel surface (the one picked for the jig)  -> expected: fails
#   ROUND 2  the NATIVE jig-blank inner curved face (offset+thicken body) -> expected: reads
# If ROUND 2 reads a cylinder radius+axis, the fix = source $ctx.RadialAxisGeom from the
# native blank (after STAGE-4 build), not the foreign panel.
#
# ID / descriptor reads ONLY; NEVER IpfcPoint.Point. Creates NOTHING (no features, no
# selection changes). Writes artifacts\radius_probe_report.txt (gitignored). ONE session.
#
# FLAGS:  -v  verbose (also dump raw type ints).
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

$argStr  = [string]$ScriptArgs
$verbose = $argStr -match '(?i)(^|\s)(-v|--verbose)(\s|$)'

Write-Host ""
Write-Host "  RADIUS-PROBE -- which channel yields the follow-cylinder radius + axis on THIS geometry?" -ForegroundColor Cyan
Write-Host "  Splits GetSurfaceDescriptor/Type/Radius/Origin/GetOrigin/GetZAxis so the foreign-body failure is exact." -ForegroundColor DarkGray
Write-Host ""

# ============================================================================
# SHARED LIBRARY
# ============================================================================
. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')           # Get-Comp
. (Join-Path $ScriptDir 'lib\drilljig_core.ps1')           # Initialize-DrilljigCore
. (Join-Path $ScriptDir 'lib\curved_surface_radius.ps1')   # Read-CurvedSurfaceCylinderGeom (the real producer)

# ============================================================================
# CONNECT (single session)
# ============================================================================
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
if ($null -eq $model) { throw "No active model. Open the assembly (imported panel + jig blank)." }

$fname = try { [string]$model.FileName } catch { "" }
$pfcType = New-Object -ComObject pfcls.pfcModelItemType
Initialize-DrilljigCore -Session $session -Model $model -TypeObj $pfcType -DataDir $ScriptDir -Log $null
Write-Host "  Connected. Active model: $fname" -ForegroundColor Green
Write-Host ""

$script:report = @()
function Rep { param([string]$Line, [string]$Color = 'Gray') Write-Host ("  " + $Line) -ForegroundColor $Color; $script:report += $Line }

$reportFile = Join-Path $ScriptDir 'artifacts\radius_probe_report.txt'
$reportDir  = Split-Path -Parent $reportFile; if ($reportDir -and -not (Test-Path $reportDir)) { New-Item -ItemType Directory -Force -Path $reportDir | Out-Null }
Rep ("RADIUS-PROBE report  model=$fname  when=" + (Get-Date).ToString('o')) 'Cyan'
Rep ""

# ----------------------------------------------------------------------------
# ok/err formatting so a THROW on a foreign body reads as a clear FAIL line, not a
# probe crash. Every read is wrapped; the probe NEVER throws mid-report.
# ----------------------------------------------------------------------------
function TryRead { param([scriptblock]$Do)
    try { return @{ Ok = $true; Val = (& $Do); Err = '' } }
    catch { return @{ Ok = $false; Val = $null; Err = $_.Exception.Message } }
}
function Fmt3 { param($V) if ($null -eq $V) { return '<null>' }; try { return ('[{0:0.####}, {1:0.####}, {2:0.####}]' -f [double]$V[0], [double]$V[1], [double]$V[2]) } catch { return '<unreadable>' } }

# ----------------------------------------------------------------------------
# Probe-Surface -- the granular per-call breakdown of the cylinder descriptor read.
# ----------------------------------------------------------------------------
function Probe-Surface { param($Surf, [int]$Id)
    Rep ("  -- surface id $Id --") 'White'
    $d = TryRead { $Surf.GetSurfaceDescriptor() }
    Rep ("    GetSurfaceDescriptor : {0}" -f $(if ($d.Ok -and $null -ne $d.Val) { 'OK' } else { 'FAIL (' + $d.Err + ')' })) $(if ($d.Ok -and $null -ne $d.Val) {'Green'} else {'Red'})
    if (-not $d.Ok -or $null -eq $d.Val) { return }
    $desc = $d.Val
    $t = TryRead { [int]$desc.GetSurfaceType() }
    Rep ("    GetSurfaceType       : {0}{1}" -f $(if ($t.Ok) { $t.Val } else { 'FAIL (' + $t.Err + ')' }), $(if ($t.Ok -and $t.Val -eq 1) { '  (1 = CYLINDER)' } else { '' })) $(if ($t.Ok -and $t.Val -eq 1) {'Green'} elseif ($t.Ok) {'Yellow'} else {'Red'})
    $r = TryRead { [double]$desc.Radius }
    Rep ("    .Radius              : {0}" -f $(if ($r.Ok) { ('{0:0.#####}' -f $r.Val) } else { 'FAIL (' + $r.Err + ')' })) $(if ($r.Ok) {'Green'} else {'Red'})
    $xf = TryRead { $desc.Origin }
    Rep ("    .Origin (transform)  : {0}" -f $(if ($xf.Ok -and $null -ne $xf.Val) { 'OK' } else { 'FAIL (' + $xf.Err + ')' })) $(if ($xf.Ok -and $null -ne $xf.Val) {'Green'} else {'Red'})
    if ($xf.Ok -and $null -ne $xf.Val) {
        $o = TryRead { Get-Comp $xf.Val.GetOrigin() }
        Rep ("    Origin.GetOrigin()   : {0}" -f $(if ($o.Ok) { (Fmt3 $o.Val) } else { 'FAIL (' + $o.Err + ')' })) $(if ($o.Ok -and $null -ne $o.Val) {'Green'} else {'Red'})
        $z = TryRead { Get-Comp $xf.Val.GetZAxis() }
        Rep ("    Origin.GetZAxis()    : {0}" -f $(if ($z.Ok) { (Fmt3 $z.Val) } else { 'FAIL (' + $z.Err + ')' })) $(if ($z.Ok -and $null -ne $z.Val) {'Green'} else {'Red'})
    }
    # what MY real producer returns for this exact surface (Valid + Reason).
    $g = $null
    try { $g = Read-CurvedSurfaceCylinderGeom -Surf $Surf -SurfId $Id } catch { $g = $null }
    if ($null -ne $g) {
        Rep ("    => Read-CurvedSurfaceCylinderGeom: Valid={0}  Radius={1}  Reason='{2}'" -f [bool]$g.Valid, $(if ($null -ne $g.Radius) { ('{0:0.#####}' -f $g.Radius) } else { '<null>' }), [string]$g.Reason) $(if ($g.Valid) {'Green'} else {'Yellow'})
    }
}

# ----------------------------------------------------------------------------
# Read the current selection buffer into (id, surf) surface pairs (ID-only gate).
# ----------------------------------------------------------------------------
function Get-SelectedSurfaces {
    $pairs = @()
    $contents = $null
    try { $contents = ($session.CurrentSelectionBuffer()).Contents } catch {}
    if ($null -eq $contents) { return $pairs }
    foreach ($item in $contents) {
        $si = $null; try { $si = $item.SelItem } catch { continue }
        if ($null -eq $si) { continue }
        $isSurf = $false; try { $isSurf = ([int]$si.Type -eq [int]$pfcType.ITEM_SURFACE) } catch {}
        if (-not $isSurf) {
            $tn = '?'; try { $tn = [string]$si.Type } catch {}
            Rep ("  (ignored a non-surface selection: type $tn)") 'DarkGray'
            continue
        }
        $id = 0; try { $id = [int]$si.Id } catch { $id = 0 }
        $pairs += @{ Id = $id; Surf = $si }
    }
    return $pairs
}

function Run-Round { param([string]$Title, [string]$Prompt)
    Rep ""
    Rep ("== $Title ==") 'Cyan'
    Write-Host ("  $Prompt") -ForegroundColor Cyan
    Write-Host "  (select in Creo, then press ENTER; or press ENTER with nothing selected to skip)" -ForegroundColor DarkGray
    Read-Host | Out-Null
    $pairs = @(Get-SelectedSurfaces)
    if ($pairs.Count -lt 1) { Rep "  (no surface selected -- skipped)" 'DarkGray'; return }
    Rep ("  read {0} selected surface(s)" -f $pairs.Count) 'DarkGray'
    foreach ($p in $pairs) { Probe-Surface -Surf $p.Surf -Id ([int]$p.Id) }
}

try {
    Run-Round -Title "[1] FOREIGN PANEL SURFACE (the jig follow-surface)" `
              -Prompt "In Creo, select the SURFACE you pick for the jig (on the imported panel)."
    Run-Round -Title "[2] NATIVE JIG-BLANK INNER FACE (the offset+thicken body)" `
              -Prompt "Now select the JIG BLANK's inner curved face (the native body you built)."

    Rep ""
    Rep "== READING GUIDE ==" 'Cyan'
    Rep "  If ROUND 1 fails at .Origin/GetOrigin/GetZAxis but ROUND 2 reads a cylinder (type 1) with" 'Gray'
    Rep "  a radius + axis, the fix is: source RadialAxisGeom from the NATIVE blank, not the panel." 'Gray'
    Rep "  If ROUND 2 ALSO fails, the blank inherits the foreign-read wall -> we use the arc-edge" 'Gray'
    Rep "  channel or the pattern's self-derived axis (operator picks the rotation axis)." 'Gray'
}
finally {
    try { $script:report | Set-Content -Path $reportFile -Encoding UTF8 } catch {}
    Write-Host ""
    Write-Host ("  Wrote $reportFile") -ForegroundColor DarkGray
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
