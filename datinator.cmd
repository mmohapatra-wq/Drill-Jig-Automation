<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

# datinator.cmd - skeleton datum-point reader (VB API, pure read)
#
# Connects to the live Creo session, enumerates every datum point in the
# active model, reads each point's true XYZ via IpfcPoint.Point, then projects
# the points into a chosen coordinate-system frame so the output is the 2D hole
# pattern (in-plane U,V) plus a signed off-plane distance (which doubles as a
# "does this point lie on the plane" check). Results are printed and exported
# to .\<modelname>_datums.csv.
#
# This is piece (A) of the drill-jig configurator: the source-geometry read.
# It writes nothing to the model - safe to run repeatedly against a live part.
#
# Projection math: for a world point P, frame origin O, and unit axes X,Y,Z,
#   local = ( (P-O).X , (P-O).Y , (P-O).Z )
# The in-plane coordinates are local.x / local.y; local.z is the signed
# distance off the plane (~0 means the point sits on the plane).

$Host.UI.RawUI.WindowTitle = "DATINATOR"
$ErrorActionPreference = "Stop"

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
Write-Host "  === DATINATOR ===" -ForegroundColor Green
Write-Host "  Skeleton datum-point reader (XYZ + in-plane projection)" -ForegroundColor White
Write-Host ""

# ============================================
# SINGLE-SESSION GUARD
# ============================================
$procs = @(Get-Process | Where-Object { $_.ProcessName -eq "xtop" })
if ($procs.Count -eq 0) {
    throw "Running Creo process (xtop) not found - open the skeleton in Creo first."
}
if ($procs.Count -gt 1) {
    throw "More than one Creo session (xtop) is running. Close all but the one holding the skeleton, then re-run."
}
$proc = $procs[0]

# ============================================
# CONNECT
# ============================================
Write-Host "  Connecting to Creo..." -ForegroundColor White

$Env:PRO_DIRECTORY    = $proc.Path.TrimEnd("xtop.exe")
$Env:PRO_COMM_MSG_EXE = $proc.Path -replace "xtop.exe", "pro_comm_msg.exe"

# Check / perform VB API registration on first run
try {
    New-Object -ComObject pfcls.pfcAsyncConnection | Out-Null
} catch {
    Write-Host "  VB API not registered - performing first-time setup..." -ForegroundColor Yellow
    $vb_path = $proc.Path -replace "Common Files(.*)$", "Parametric\bin\vb_api_register.bat"
    Start-Process -Wait -FilePath $vb_path
}

$async      = New-Object -ComObject pfcls.pfcAsyncConnection
$connection = $async.Connect($null, $null, $null, $null)
$session    = $connection.Session
$model      = $session.GetActiveModel()
if ($null -eq $model) { throw "No active model in the Creo session." }
Write-Host "  Connected: $($model.FileName)" -ForegroundColor Green

# Suppress UI noise; restore in finally
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
    # ============================================
    # VECTOR HELPERS (work on IpfcPoint3D / IpfcVector3D via [0..2] indexing)
    # ============================================
    function Get-Comp {
        # Read the 3 components of an IpfcPoint3D / IpfcVector3D into a plain
        # double[3]. Bracket indexing is confirmed; .Item(i) is the fallback.
        param($V)
        try   { return @([double]$V[0], [double]$V[1], [double]$V[2]) }
        catch { return @([double]$V.Item(0), [double]$V.Item(1), [double]$V.Item(2)) }
    }
    function Dot { param($A, $B) ($A[0]*$B[0] + $A[1]*$B[1] + $A[2]*$B[2]) }

    $pfcModelItemType = New-Object -ComObject pfcls.pfcModelItemType

    # ============================================
    # ENUMERATE DATUM POINTS
    # ============================================
    Write-Host "  Reading datum points..." -ForegroundColor White

    $points = @()
    try {
        $points = @($model.ListItems($pfcModelItemType.ITEM_POINT))
    } catch {
        throw "Could not list datum points (ITEM_POINT): $($_.Exception.Message)"
    }
    if ($points.Count -eq 0) {
        throw "No datum points (ITEM_POINT) found in the active model."
    }
    Write-Host "  Found $($points.Count) datum point(s)." -ForegroundColor Green

    # ============================================
    # PICK A COORDINATE-SYSTEM FRAME FOR PROJECTION
    # ============================================
    # No CSYS  -> project against the world frame (origin 0, identity axes).
    # One CSYS -> use it.
    # Many     -> let the user choose which one defines the plane.
    $csysList = @()
    try { $csysList = @($model.ListItems($pfcModelItemType.ITEM_COORD_SYS)) } catch {}

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
            Write-Host "  Multiple coordinate systems - pick the one that defines the plane:" -ForegroundColor Cyan
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
                Write-Host "  Could not read CSYS transform; falling back to world frame." -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "  No coordinate system in model - projecting against world frame." -ForegroundColor DarkGray
    }

    Write-Host "  Projection frame: $csysName" -ForegroundColor Green

    # ============================================
    # READ + PROJECT EACH POINT
    # ============================================
    $rows = @()
    foreach ($pt in $points) {
        $id   = $pt.Id
        $name = try { $pt.GetName() } catch { "" }

        # IpfcPoint.Point -> xyz of the datum point
        $xyz = $null
        try { $xyz = Get-Comp $pt.Point }
        catch {
            Write-Host "  (skipping point id $id - could not read .Point: $($_.Exception.Message))" -ForegroundColor Yellow
            continue
        }

        $d = @($xyz[0] - $origin[0], $xyz[1] - $origin[1], $xyz[2] - $origin[2])
        $u   = Dot $d $xAxis
        $v   = Dot $d $yAxis
        $off = Dot $d $zAxis

        $rows += [pscustomobject]@{
            PointID   = $id
            PointName = $name
            X         = [math]::Round($xyz[0], 6)
            Y         = [math]::Round($xyz[1], 6)
            Z         = [math]::Round($xyz[2], 6)
            PlaneU    = [math]::Round($u, 6)
            PlaneV    = [math]::Round($v, 6)
            OffPlane  = [math]::Round($off, 6)
            CsysName  = $csysName
        }
    }

    if ($rows.Count -eq 0) { throw "No datum points could be read." }

    # ============================================
    # REPORT
    # ============================================
    Write-Host ""
    Write-Host "  Datum points (in-plane projection against '$csysName'):" -ForegroundColor Green
    $rows | Sort-Object PlaneV, PlaneU | Format-Table PointID, PointName, X, Y, Z, PlaneU, PlaneV, OffPlane -AutoSize | Out-Host

    $maxOff = ($rows | ForEach-Object { [math]::Abs($_.OffPlane) } | Measure-Object -Maximum).Maximum
    if ($maxOff -gt 1e-4) {
        Write-Host ("  NOTE: largest off-plane distance is {0:0.######} - not all points lie on the chosen plane." -f $maxOff) -ForegroundColor Yellow
    } else {
        Write-Host "  All points lie on the chosen plane (off-plane < 1e-4)." -ForegroundColor DarkGray
    }

    # ============================================
    # EXPORT
    # ============================================
    $base = [System.IO.Path]::GetFileNameWithoutExtension($model.FileName)
    $outPath = Join-Path $ScriptDir "$base`_datums.csv"
    $rows | Export-Csv -Path $outPath -NoTypeInformation
    Write-Host ""
    Write-Host "  Exported $($rows.Count) point(s): $outPath" -ForegroundColor Green

} finally {
    try {
        if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null }
        if ($null -ne $origDynamicPreview) { $session.SetConfigOption("dynamic_preview",  $origDynamicPreview)  | Out-Null }
    } catch {}
    try { $connection.Disconnect($null) } catch {}
}

Write-Host ""
Write-Host "  Press any key to exit..." -ForegroundColor White
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
