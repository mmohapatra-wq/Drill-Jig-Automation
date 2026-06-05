<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "BOXINATOR"
$ErrorActionPreference = "Stop"

trap {
    Write-Host ""
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

function Wait-ModelModified {
    param($Model, [string]$PreviousStamp, [int]$TimeoutMs = 30000)
    $deadline = [DateTime]::Now.AddMilliseconds($TimeoutMs)
    while ([DateTime]::Now -lt $deadline) {
        try { if ($Model.VersionStamp -ne $PreviousStamp) { return } } catch {}
    }
    Write-Host "  (warning: timed out waiting for model update)" -ForegroundColor Yellow
}

# Fire a mapkey and report success/failure instead of swallowing it. A silent
# failure here is what made boxinator impossible to debug — a wrong widget name
# or unready dashboard would no-op and the script would march on to "Done".
# Failures are also counted so the final report can refuse a green "Done" when a
# mapkey no-op'd partway through.
$script:macroFailures = 0
function Invoke-Macro {
    param([string]$Label, [string]$Macro)
    Write-Host "    > $Label ..." -NoNewline -ForegroundColor DarkGray
    try {
        $session.RunMacro($Macro)
        Write-Host " ok" -ForegroundColor DarkGray
    } catch {
        Write-Host " FAILED: $($_.Exception.Message)" -ForegroundColor Red
        $script:macroFailures++
    }
}

# Read the three components of an IpfcPoint3D. The VB API exposes sequence members
# both via .Item(i) and as a direct array; gauginator reads GravityCenter as $CG[0..2]
# so bracket indexing is the confirmed path, with .Item as a fallback.
function Get-PointXYZ {
    param($Point)
    try { return @([double]$Point[0], [double]$Point[1], [double]$Point[2]) } catch {}
    try { return @([double]$Point.Item(0), [double]$Point.Item(1), [double]$Point.Item(2)) } catch {}
    throw "Could not read X/Y/Z from a Point3D object."
}

# Measure the active solid's true size via its regeneration outline. EvalOutline returns
# an IpfcOutline3D — a 2-element sequence of corner Point3Ds (min, max). The three
# axis extents ARE the box's real width/height/depth, with no dependence on which
# dimension symbol is width vs height. Returns the three extents sorted descending,
# or $null if the outline could not be read.
function Measure-BoxExtents {
    param($Solid)
    $outline = $null
    try { $outline = $Solid.EvalOutline($null, $null) } catch {}
    if ($null -eq $outline) {
        try { $outline = $Solid.GetOutline() } catch {}
    }
    if ($null -eq $outline) { return $null }

    $p0 = $null; $p1 = $null
    try { $p0 = $outline[0]; $p1 = $outline[1] } catch {}
    if ($null -eq $p0 -or $null -eq $p1) {
        try { $p0 = $outline.Item(0); $p1 = $outline.Item(1) } catch {}
    }
    if ($null -eq $p0 -or $null -eq $p1) { return $null }

    $a = Get-PointXYZ -Point $p0
    $b = Get-PointXYZ -Point $p1
    $ex = [math]::Abs($b[0] - $a[0])
    $ey = [math]::Abs($b[1] - $a[1])
    $ez = [math]::Abs($b[2] - $a[2])
    return @($ex, $ey, $ez | Sort-Object -Descending)
}

# ============================================
# HEADER
# ============================================
Write-Host ""
Write-Host "  ██████╗  ██████╗ ██╗  ██╗██╗███╗   ██╗ █████╗ ████████╗ ██████╗ ██████╗ " -ForegroundColor White
Write-Host "  ██╔══██╗██╔═══██╗╚██╗██╔╝██║████╗  ██║██╔══██╗╚══██╔══╝██╔═══██╗██╔══██╗" -ForegroundColor White
Write-Host "  ██████╔╝██║   ██║ ╚███╔╝ ██║██╔██╗ ██║███████║   ██║   ██║   ██║██████╔╝" -ForegroundColor White
Write-Host "  ██╔══██╗██║   ██║ ██╔██╗ ██║██║╚██╗██║██╔══██║   ██║   ██║   ██║██╔══██╗" -ForegroundColor White
Write-Host "  ██████╔╝╚██████╔╝██╔╝ ██╗██║██║ ╚████║██║  ██║   ██║   ╚██████╔╝██║  ██║" -ForegroundColor White
Write-Host "  ╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝" -ForegroundColor White
Write-Host "  Rectangular Extrude Creation" -ForegroundColor White
Write-Host ""

# ============================================
# USER INPUTS
# ============================================
Write-Host "  Enter box dimensions (model units):" -ForegroundColor Green
Write-Host ""
$width  = [double](Read-Host "  Width")
$height = [double](Read-Host "  Height")
$depth  = [double](Read-Host "  Depth (extrude)")
Write-Host ""

# ============================================
# CONNECT TO CREO
# ============================================
$proc = Get-Process | Where-Object { $_.ProcessName -eq "xtop" }
if ($null -eq $proc) { throw "Creo (xtop.exe) is not running" }

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

$origVis = $null; $origPrev = $null
try { $v = $session.GetConfigOptionValues("visible_mapkeys"); if ($v.Count -gt 0) { $origVis  = $v.Item(0) } } catch {}
try { $v = $session.GetConfigOptionValues("dynamic_preview");  if ($v.Count -gt 0) { $origPrev = $v.Item(0) } } catch {}
# Suppress both per the repo convention. To debug a diverging widget interaction,
# temporarily set visible_mapkeys to "yes" so each macro replays on screen.
try { $session.SetConfigOption("visible_mapkeys", "no") | Out-Null } catch {}
try { $session.SetConfigOption("dynamic_preview",  "no") | Out-Null } catch {}

try {

# ============================================
# SELECT SKETCH PLANE
# ============================================
Write-Host "  In Creo: select the plane to sketch on, then press ENTER here." -ForegroundColor White
Read-Host
$planeSel = ($session.CurrentSelectionBuffer()).Contents
if ($null -eq $planeSel -or $planeSel.Count -eq 0) { throw "No plane selected." }
$planeID = $planeSel[0].SelItem.Id

# ============================================
# OPEN SKETCHER
# ============================================
# Select the plane by ID so the sketch setup dialog picks it up in the MRU list
$mkSelectPlane =
    "~ Activate ``main_dlg_cur`` ``buffer_clean``;" +
    "~ Command ``ProCmdMdlTreeSearch``;" +
    "~ Open ``selspecdlg0`` ``SelOptionRadio``;" +
    "~ Close ``selspecdlg0`` ``SelOptionRadio``;" +
    "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Datum Plane``;" +
    "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
    "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$planeID``;" +
    "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
    "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
    "~ Activate ``selspecdlg0`` ``CancelButton``;"

Invoke-Macro "select plane by ID" $mkSelectPlane

# Open sketcher — plane is now in MRU so t1.PlnMru item 0 picks it up
$mkOpenSketch =
    "~ Command ``ProCmdDatumSketCurve``;" +
    "~ Trigger ``Odui_Dlg_00`` ``t1.PlnMru`` ``0``;" +
    "~ Trigger ``Odui_Dlg_00`` ``t1.PlnMru`` ``````;" +
    "~ Trigger ``Odui_Dlg_00`` ``t1.RefMru`` ``0``;" +
    "~ Trigger ``Odui_Dlg_00`` ``t1.RefMru`` ``````;" +
    "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;"

# Opening the sketcher is a UI state change, not a part regen — it does not bump
# VersionStamp, so there is nothing to poll on here.
Invoke-Macro "open sketcher" $mkOpenSketch

# Activate center rectangle tool and wait for user to draw
$mkRectTool = "~ Command ``ProCmdSketCenterRectangle`` 1;"
Invoke-Macro "activate center-rectangle tool" $mkRectTool

Write-Host ""
Write-Host "  In Creo sketcher: click the center of the rectangle, then click a corner." -ForegroundColor White
Write-Host "  The size doesn't matter — dimensions will be set automatically." -ForegroundColor Gray
Write-Host ""
Write-Host "  Press ENTER here when done drawing." -ForegroundColor White
Read-Host

# ============================================
# SET SKETCH DIMENSIONS (pick-order: WIDTH then HEIGHT)
# ============================================
# The mod_dim_emb write is what actually creates the in-plane geometry. We keep the
# fixed WIDTH-then-HEIGHT pick order so the user knows which edge to dimension, but we
# NO LONGER try to capture each dim's symbol from the selection buffer — that binding
# was unreliable and could not tell width from height (DimType is Linear for both).
# Verification is now geometric (EvalOutline below), so the symbol is not needed here.
Write-Host "  Now dimension the rectangle. WIDTH first, then HEIGHT." -ForegroundColor White
Write-Host ""

# --- WIDTH ---
Invoke-Macro "activate dimension tool (width)" "~ Command ``ProCmdSketDimension`` 1;"
Write-Host "  [1/2 WIDTH]  Click a HORIZONTAL edge (top or bottom), then middle-click to place the dimension." -ForegroundColor Green
Write-Host "  Press ENTER here after the dimension is placed." -ForegroundColor White
Read-Host
$mkWidth =
    "~ Update ``main_dlg_cur`` ``mod_dim_emb`` ``$width``;" +
    "~ Activate ``main_dlg_cur`` ``mod_dim_emb``;"
Invoke-Macro "write width = $width" $mkWidth

# --- HEIGHT ---
Invoke-Macro "activate dimension tool (height)" "~ Command ``ProCmdSketDimension`` 1;"
Write-Host ""
Write-Host "  [2/2 HEIGHT] Click a VERTICAL edge (left or right), then middle-click to place the dimension." -ForegroundColor Green
Write-Host "  Press ENTER here after the dimension is placed." -ForegroundColor White
Read-Host
$mkHeight =
    "~ Update ``main_dlg_cur`` ``mod_dim_emb`` ``$height``;" +
    "~ Activate ``main_dlg_cur`` ``mod_dim_emb``;"
Invoke-Macro "write height = $height" $mkHeight

# ============================================
# EXIT SKETCHER
# ============================================
$stamp = $model.VersionStamp
Invoke-Macro "exit sketcher" "~ Command ``ProCmdSketDone``;"
Wait-ModelModified -Model $model -PreviousStamp $stamp

# ============================================
# EXTRUDE WITH EXACT DEPTH
# ============================================
# Snapshot existing protrusion feature IDs so the new one can be identified afterward
# (needed only by the depth-repair fallback — the EvalOutline check itself needs no IDs).
$pfcModelItemType = New-Object -ComObject pfcls.pfcModelItemType
$pfcFeatures      = New-Object -ComObject pfcls.pfcFeatureType

$beforeIds = @()
try {
    $existing = $model.ListFeaturesByType($FALSE, $pfcFeatures.FEATTYPE_PROTRUSION)
    foreach ($f in $existing) { $beforeIds += $f.Id }
} catch {}

Invoke-Macro "open extrude tool" "~ Command ``ProCmdFtExtrude``;"
Start-Sleep -Milliseconds 800

$mkExtrudeDepth =
    "~ Update ``main_dlg_cur`` ``GrmTextTagEmbedMRU`` ``$depth``;" +
    "~ Activate ``main_dlg_cur`` ``GrmTextTagEmbedMRU``;" +
    "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"

$stamp = $model.VersionStamp
Invoke-Macro "set dashboard depth + done" $mkExtrudeDepth
Wait-ModelModified -Model $model -PreviousStamp $stamp

Write-Host ""
Write-Host "  The extrude should now be committed (a solid box visible in Creo)." -ForegroundColor White
Write-Host "  Press ENTER here once the extrude dashboard has closed." -ForegroundColor White
Read-Host

# ============================================
# AUTHORITATIVE DEPTH (feature DimValue — the dashboard field is unreliable)
# ============================================
# DEV_NOTES: feature-level dim writes via DimValue DO stick on a closed sketch, while the
# GrmTextTagEmbedMRU dashboard field has produced the wrong depth. So rather than trusting
# the dashboard value, find the new extrude feature's depth dim and set it directly.
#
# Identifying the depth dim: the extrude feature may expose 1 linear dim (just depth) or
# several (depth plus the sketch's width/height, depending on how Creo nests them). We do
# NOT assume a count. Depth is the linear dim whose current value matches NEITHER the
# requested width NOR height — found by elimination. A full dump is printed regardless so
# the model's actual dim layout is visible if the elimination is ambiguous.
$newFeature = $null
try {
    $after = $model.ListFeaturesByType($FALSE, $pfcFeatures.FEATTYPE_PROTRUSION)
    foreach ($f in $after) { if ($beforeIds -notcontains $f.Id) { $newFeature = $f; break } }
} catch {}

if ($null -eq $newFeature) {
    Write-Host "  WARNING: could not identify the new extrude feature — leaving depth as the dashboard value." -ForegroundColor Yellow
} else {
    Write-Host "  New extrude feature Id $($newFeature.Id). Dimensions on this feature:" -ForegroundColor White
    $featLinear = @()
    try {
        foreach ($d in $newFeature.ListSubItems($pfcModelItemType.ITEM_DIMENSION)) {
            $tname = switch ($d.DimType) { 0 {"Linear"} 1 {"Radial"} 2 {"Diameter"} 3 {"Angular"} default {"?"} }
            Write-Host ("      {0,-6} {1,-8} = {2}" -f $d.Symbol, $tname, $d.DimValue) -ForegroundColor Gray
            if ($d.DimType -eq 0) { $featLinear += $d }
        }
    } catch { Write-Host "      (could not list feature dims: $($_.Exception.Message))" -ForegroundColor Yellow }

    # Depth = linear dim matching neither width nor height.
    $depthCandidates = @($featLinear | Where-Object {
        [math]::Abs([double]$_.DimValue - $width)  -ge 1e-4 -and
        [math]::Abs([double]$_.DimValue - $height) -ge 1e-4
    })
    if ($depthCandidates.Count -eq 0 -and $featLinear.Count -eq 1) {
        # Only one linear dim and it happened to equal width/height numerically — still depth.
        $depthCandidates = @($featLinear[0])
    }

    if ($depthCandidates.Count -eq 1) {
        try {
            $depthCandidates[0].DimValue = $depth
            $model.Regenerate($null)
            Write-Host "  Set depth dim $($depthCandidates[0].Symbol) = $depth (authoritative)." -ForegroundColor Green
        } catch {
            Write-Host "  WARNING: depth DimValue write threw: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    } elseif ($depthCandidates.Count -gt 1) {
        Write-Host "  WARNING: $($depthCandidates.Count) candidate depth dims (none match W/H) — cannot pick safely. Leaving dashboard depth; verify below." -ForegroundColor Yellow
    } else {
        Write-Host "  WARNING: no depth dim found on the extrude feature — leaving dashboard depth; verify below." -ForegroundColor Yellow
    }
}

# ============================================
# GEOMETRIC VERIFY (EvalOutline)
# ============================================
# Source of truth: measure the solid itself. The three sorted extents must equal the
# three requested sizes (also sorted), within tolerance. Sorting both triples means we
# never have to know which axis the sketch plane mapped width/height onto — we assert
# "the solid's three extents are 5, 3, 2" exactly as the user asked for.
$tol = 1e-4
$targetSorted = @($width, $height, $depth | Sort-Object -Descending)

Write-Host ""
Write-Host "  Measuring the solid (EvalOutline)..." -ForegroundColor White
$measured = Measure-BoxExtents -Solid $model

$verifyPass = $false
if ($null -eq $measured) {
    Write-Host "  WARNING: could not read the solid outline — size is UNVERIFIED." -ForegroundColor Yellow
} else {
    Write-Host ("    measured extents (sorted): {0:0.####} x {1:0.####} x {2:0.####}" -f $measured[0], $measured[1], $measured[2]) -ForegroundColor Gray
    Write-Host ("    requested      (sorted): {0:0.####} x {1:0.####} x {2:0.####}" -f $targetSorted[0], $targetSorted[1], $targetSorted[2]) -ForegroundColor Gray
    $verifyPass = $true
    for ($i = 0; $i -lt 3; $i++) {
        if ([math]::Abs($measured[$i] - $targetSorted[$i]) -ge $tol) { $verifyPass = $false }
    }
    if ($verifyPass) {
        Write-Host "    PASS — solid matches the requested size." -ForegroundColor Green
    } else {
        Write-Host "    MISMATCH — solid does not match the requested size." -ForegroundColor Yellow
    }
}

# ============================================
# REPAIR (only if the measurement disagrees)
# ============================================
# Every repaired claim below is re-confirmed by a fresh EvalOutline, never by a symbol
# echo. Depth is a feature-level dim (DimValue writes stick on a closed sketch); width/
# height are sketch dims and need the sketch-open flow.
if ($null -ne $measured -and -not $verifyPass) {

    # Which requested values are not yet present among the measured extents? Match by
    # value (geometric), not by symbol or pick-order.
    $remaining = [System.Collections.ArrayList]@($measured)
    function Test-Present {
        param([double]$Value)
        for ($j = 0; $j -lt $remaining.Count; $j++) {
            if ([math]::Abs([double]$remaining[$j] - $Value) -lt $tol) { $remaining.RemoveAt($j); return $true }
        }
        return $false
    }
    $depthOk  = Test-Present -Value $depth
    $widthOk  = Test-Present -Value $width
    $heightOk = Test-Present -Value $height

    # Depth was already set authoritatively above via the feature DimValue. If it still
    # reads wrong here, that is a genuine failure (not a sketch-snapback case) — report it
    # rather than re-driving the dashboard.
    if (-not $depthOk) {
        Write-Host ""
        Write-Host "  Depth still reads wrong after the authoritative set — this is unexpected." -ForegroundColor Red
        Write-Host "  Check the dim dump above; the depth dim may not have been identified correctly." -ForegroundColor Red
    }

    # --- Sketch repair: width/height that did not land ---
    # GATED. Auto-driving the sketch open/close + Regenerate sequence has crashed Creo
    # (fatal traceback) when the model was in a half-committed state. So we never enter it
    # without an explicit y/n, and we tell the user to make sure no tool/dialog is open
    # first. If they decline, the box is reported NOT confirmed rather than risking a crash.
    if (-not $widthOk -or -not $heightOk) {
        Write-Host ""
        Write-Host "  In-plane size is off (width and/or height did not stick)." -ForegroundColor Yellow
        Write-Host "  A guided sketch repair is available, but it drives Creo through a sketch" -ForegroundColor Yellow
        Write-Host "  open/close + regenerate — only safe if NO tool or dialog is currently open." -ForegroundColor Yellow
        Write-Host ""
        $ans = Read-Host "  Attempt guided sketch repair? Make sure Creo is idle first. (y/n)"
        if ($ans -notmatch '^(y|yes)$') {
            Write-Host "  Skipping sketch repair. Box will be reported NOT confirmed." -ForegroundColor Yellow
        } else {
        Write-Host "  In Creo, double-click the sketch feature to open it, then press ENTER here." -ForegroundColor Cyan
        Read-Host

        # When the sketch is open, GetActiveModel returns the sketch model. Map each
        # sketch dim to width or height by which CURRENT VALUE it sits closest to — the
        # geometric pairing, not the old pick-order guess. Whichever requested value is
        # missing gets written onto the dim currently nearest it.
        $sketchModel = $session.GetActiveModel()
        $sketchDims = @()
        try {
            foreach ($d in $sketchModel.ListItems($pfcModelItemType.ITEM_DIMENSION)) {
                if ($d.DimType -eq 0) { $sketchDims += $d }
            }
        } catch {}

        function Repair-SketchDim {
            param([double]$Target)
            $best = $null; $bestErr = [double]::MaxValue
            foreach ($d in $sketchDims) {
                $err = [math]::Abs([double]$d.DimValue - $Target)
                if ($err -lt $bestErr) { $bestErr = $err; $best = $d }
            }
            if ($null -ne $best) {
                try {
                    $best.DimValue = $Target
                    Write-Host "    set sketch dim $($best.Symbol) -> $Target" -ForegroundColor Green
                } catch {
                    Write-Host "    FAIL  sketch dim write threw: $($_.Exception.Message)" -ForegroundColor Red
                }
            } else {
                Write-Host "    FAIL  no Linear sketch dim found to set to $Target." -ForegroundColor Red
            }
        }

        if (-not $widthOk)  { Repair-SketchDim -Target $width }
        if (-not $heightOk) { Repair-SketchDim -Target $height }

        Write-Host "  Solving sketch..." -NoNewline
        try { $sketchModel.Regenerate($null); Write-Host " done." -ForegroundColor Green }
        catch { Write-Host " warning: $($_.Exception.Message)" -ForegroundColor Yellow }

        Write-Host ""
        Write-Host "  Close the sketch in Creo (click OK/checkmark), then press ENTER here." -ForegroundColor Cyan
        Read-Host
        try { $model.Regenerate($null) } catch {}
        }
    }

    # --- Re-confirm by measuring again ---
    Write-Host ""
    Write-Host "  Re-measuring the solid..." -ForegroundColor White
    $measured = Measure-BoxExtents -Solid $model
    if ($null -eq $measured) {
        Write-Host "  WARNING: could not re-read the solid outline — size is UNVERIFIED." -ForegroundColor Yellow
        $verifyPass = $false
    } else {
        Write-Host ("    measured extents (sorted): {0:0.####} x {1:0.####} x {2:0.####}" -f $measured[0], $measured[1], $measured[2]) -ForegroundColor Gray
        $verifyPass = $true
        for ($i = 0; $i -lt 3; $i++) {
            if ([math]::Abs($measured[$i] - $targetSorted[$i]) -ge $tol) { $verifyPass = $false }
        }
        if ($verifyPass) { Write-Host "    REPAIRED — solid now matches the requested size." -ForegroundColor Green }
        else             { Write-Host "    STILL MISMATCHED after repair." -ForegroundColor Red }
    }
}

# ============================================
# FINAL REPORT
# ============================================
Write-Host ""
$ok = $verifyPass
if ($script:macroFailures -gt 0) {
    Write-Host "    ($($script:macroFailures) mapkey command(s) reported FAILED during the run)" -ForegroundColor Yellow
    $ok = $false
}

Write-Host ""
if ($ok) {
    Write-Host "  Done. Box: $width x $height x $depth (measured and confirmed)." -ForegroundColor Green
} elseif ($null -eq $measured) {
    Write-Host "  Box created but size UNVERIFIED (could not read the solid outline)." -ForegroundColor Yellow
    Write-Host "  Measure the solid in Creo before trusting these dimensions." -ForegroundColor Yellow
} else {
    Write-Host ("  Box created but NOT confirmed. Requested {0} x {1} x {2}; measured (sorted) {3:0.####} x {4:0.####} x {5:0.####}." -f `
        $width, $height, $depth, $measured[0], $measured[1], $measured[2]) -ForegroundColor Yellow
    Write-Host "  Measure the solid in Creo before trusting these dimensions." -ForegroundColor Yellow
}

} finally {
    try { if ($null -ne $origVis)  { $session.SetConfigOption("visible_mapkeys", $origVis)  | Out-Null } } catch {}
    try { if ($null -ne $origPrev) { $session.SetConfigOption("dynamic_preview",  $origPrev) | Out-Null } } catch {}
    $connection.Disconnect($null)
}

Write-Host ""
Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
