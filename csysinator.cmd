<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
echo.
pause
exit /b %errorlevel%
#>

# ============================================================================
# csysinator.cmd - create a datum COORDINATE SYSTEM at a ROUND edge's center
# ============================================================================
# "Change of coordinate system using a round edge." You select ONE round edge
# (a hole/fastener rim - the important thing is that it's ROUND so its CENTER can
# be read); that circle center becomes the CSYS ORIGIN. You then orient +X toward
# a second reference (a datum PLANE that points in the X direction, or another
# edge). csysinator opens the Coordinate System dialog, GUIDES the picks, clicks
# OK, and VERIFIES a coordinate system feature actually landed at the edge center.
#
# WHY A ROUND EDGE (and why this replaces the old 2-hole-axis approach): a datum
# CSYS needs a POINT-like ORIGIN reference. Two parallel bore AXES give only a
# LINE - which UNDER-defines the origin, so the dialog stalls demanding more (the
# exact wall the old 2-axis csysinator hit; see project_index_frame memory). A
# round edge's CENTER is a well-defined point, which is precisely what the origin
# collector wants - so the round-edge route fixes the origin problem outright.
#
# HOW THE CENTER IS READ (ID/descriptor ONLY - never the crash-prone IpfcPoint.Point):
# a solid circular edge is an ARC; its GetCurveDescriptor() returns an
# IpfcArcDescriptor whose .Center (IpfcPoint3D) + .Radius are read via the SAME
# proven descriptor-read family as the live cylinder .Origin read (Get-EdgeArcCenter
# in lib\creo_geometry.ps1). This is best-effort: if the center can't be read on a
# given build the tool STILL creates the csys (guided picks) and just verifies
# visually - the center read is a verification anchor, not a gate.
#
# THE FLOW (a faithful replay of the operator's recorded mapkey, 2026-07-06):
#   1. Tool opens ProCmdDatumCsys and primes the origin collector.
#   2. PICK 1 - you click the ROUND hole edge  -> ORIGIN (its center) AND the first
#      direction; the tool assigns that direction to Axis_Y + flips it so +Y matches
#      the original Y (the hole's own axis IS the Y reference - no separate Y plane).
#   3. PICK 2 - you click the plane for +X (e.g. TOP) -> the second direction; the
#      remaining axis (X) is taken implicitly + flipped. Then the tool fires OK.
#   Two mouse picks; the tool drives the tabs / axis dropdown / flips / OK.
#
# WHY TWO PICKS (not hands-free): the recorded mapkey has TWO @PAUSE_FOR_SCREEN_PICK -
# ProCmdDatumCsys references are MOUSE-PICKED and a RunMacro cannot replay a pick (nor
# feed the csys ODUI collector by ID - that pre-select approach is refuted, fact
# datumcsys-dialog-sequence). So the sequence is split into 3 RunMacro segments around
# the two console pauses (Get-CsysOpenMacro / Get-CsysDir1Macro / Get-CsysFinishMacro).
#
# csys widgets - ALL RECORDED LIVE in the operator's mapkey (2026-07-06):
#     ~ Command ProCmdDatumCsys                          (opens Odui_Dlg_00)
#     ~ Trigger Odui_Dlg_00 t1.OriginPlacement ...       (prime origin collector)
#     ~ Select Odui_Dlg_00 pg_vis_tab 1 tab_1 / tab_2    (Placement / Orientation tabs)
#     <pick origin edge>    -> t1.OriginPlacement        (origin = circle center + dir 1)
#     ~ Select Odui_Dlg_00 t2.AxisMenu1 1 Axis_Y         (dir 1 -> Y)
#     ~ Activate Odui_Dlg_00 t2.FlipBtn1                  (flip Y)
#     <pick X plane>        -> t2.DirectionTable2         (dir 2 -> X implicitly)
#     ~ Activate Odui_Dlg_00 t2.FlipBtn2                  (flip X)
#     ~ Activate Odui_Dlg_00 stdbtn_1                     (OK -> CS0; ADDED by the tool,
#                                                          the recording stopped before OK)
#   NOTE: the real flow assigns ONLY Axis_Y (to the origin's direction); the X plane's
#   axis is implicit - there is NO AxisMenu2 / Axis_X (an earlier inference, now removed).
#
# FLIPS are geometry-specific: the recorded FlipBtn1/FlipBtn2 were right for the
# operator's hole/plane orientation. On a differently-drilled hole an axis may come out
# reversed - the post-create report says so and asks for a visual check.
#
# VERIFY: exactly ONE new coordinate-system feature must appear (feature-diff canary
# - a VersionStamp bump alone can come from a dialog open/close that created nothing:
# feedback_canary_must_not_assume_on_failure). Best-effort: read the picked edge's
# center from the buffer (no extra pick) and the new csys origin (Read-CoordSysTransform)
# to confirm origin==center; the axes are verified VISUALLY (plane normals read null).
# Nothing is claimed created unless a real feature appeared. --probe does everything
# EXCEPT the final OK so you can eyeball the csys preview before committing.
#
# FLAGS:
#   -v       verbose (origin-edge center + diagnostics)
#   --probe  drive the whole sequence EXCEPT the final OK, so you can eyeball the
#            csys preview before committing (nothing auto-created)
# Open the jig PART (not .asm).
# ============================================================================

$Host.UI.RawUI.WindowTitle = "CSYSINATOR"
$ErrorActionPreference = "Stop"

trap {
    Write-Host ""
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    exit 1
}

$Verbose = ($ScriptArgs -match '(?i)-v\b|--verbose')
$Probe   = ($ScriptArgs -match '(?i)--probe')

# Dot-source the shared geometric-read helpers (Get-Comp, Get-EdgeArcCenter,
# Read-CoordSysTransform, Dot). Pure reads, no state - safe to load.
. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')

# ----------------------------------------------------------------------------
# Helpers (canary primitives - proven idiom across the toolkit)
# ----------------------------------------------------------------------------

# $true if VersionStamp changed within the timeout.
function Wait-ModelModified {
    param($Model, [string]$PreviousStamp, [int]$TimeoutMs = 30000)
    $deadline = [DateTime]::Now.AddMilliseconds($TimeoutMs)
    while ([DateTime]::Now -lt $deadline) {
        try { if ($Model.VersionStamp -ne $PreviousStamp) { return $true } } catch {}
        # Sleep between polls - a tight spin pins one core at 100% for the whole
        # timeout on the no-change path (e.g. the user cancelled the dialog), the
        # exact anti-pattern already fixed elsewhere in the toolkit. 40ms is far
        # finer than any Creo regen commit, so the canary is unaffected.
        Start-Sleep -Milliseconds 40
    }
    return $false
}

# Snapshot feature IDs (the proven before/after-diff canary idiom). "csys created"
# = EXACTLY ONE new feature appears (a VersionStamp bump alone can come from a
# dialog open/close that created nothing - the canary memo's false-green guard).
function Get-FeatureIdSet {
    param($Model, $TypeObj)
    $set = @{}
    try { foreach ($f in $Model.ListItems($TypeObj.ITEM_FEATURE)) { try { $set[[int]$f.Id] = $true } catch {} } } catch {}
    return $set
}
function Count-NewFeatures {
    param($Model, $TypeObj, $Before)
    $n = 0
    try {
        foreach ($f in $Model.ListItems($TypeObj.ITEM_FEATURE)) {
            $id = $null; try { $id = [int]$f.Id } catch {}
            if ($null -ne $id -and -not $Before.ContainsKey($id)) { $n++ }
        }
    } catch {}
    return $n
}

# Snapshot coordinate-system item IDs. A new datum csys FEATURE also introduces a
# new ITEM_COORD_SYS geometry item; the before/after diff finds it so we can read
# its transform back (the verification signal the feature-diff canary alone lacks).
function Get-CoordSysIdSet {
    param($Model, $TypeObj)
    $set = @{}
    try { foreach ($c in $Model.ListItems($TypeObj.ITEM_COORD_SYS)) { try { $set[[int]$c.Id] = $true } catch {} } } catch {}
    return $set
}

# Find the newly-created coordinate system (ITEM_COORD_SYS id NOT in $Before) and
# read its transform. Returns @{ Id; Origin; X; Y; Z } or $null (none new / read
# unavailable). Best-effort read-back - NEVER throws, NEVER gates creation.
function Read-NewCsysTransform {
    param($Model, $TypeObj, $Before)
    try {
        foreach ($c in $Model.ListItems($TypeObj.ITEM_COORD_SYS)) {
            $id = $null; try { $id = [int]$c.Id } catch {}
            if ($null -eq $id -or $Before.ContainsKey($id)) { continue }
            $xf = Read-CoordSysTransform -Csys $c
            if ($null -ne $xf) { $xf.Id = $id; return $xf }
            return @{ Id = $id; Origin = $null; X = $null; Y = $null; Z = $null }
        }
    } catch {}
    return $null
}

# NOTE: a former Read-SelectedRoundEdge (buffer read for the origin edge's center)
# and Point-Distance (origin-vs-center compare) were REMOVED - reading the selection
# buffer / a curve descriptor WHILE the csys dialog is open deadlocks Creo (the
# main thread is in the dialog's pick loop and can't answer a COM query; froze live
# 2026-07-07). The origin is now verified only by the post-OK read-back + visually.
# Get-EdgeArcCenter stays in lib\creo_geometry.ps1 as a general (dialog-free) reader.

function Format-Vec {
    param($V)
    if ($null -eq $V) { return "(unavailable)" }
    return ("({0}, {1}, {2})" -f [Math]::Round([double]$V[0],4), [Math]::Round([double]$V[1],4), [Math]::Round([double]$V[2],4))
}

# ----------------------------------------------------------------------------
# The three csys macro segments, transcribed VERBATIM from the operator's recorded
# mapkey (2026-07-06). The recording has TWO @PAUSE_FOR_SCREEN_PICK (the origin edge
# and the X-direction plane) - real mouse picks a RunMacro cannot replay - so the
# sequence is split into 3 segments fired around two console pauses:
#   A (Get-CsysOpenMacro)   open + prime origin collector + tab toggle -> [PICK origin]
#   B (Get-CsysDir1Macro)   orient tab; the origin's own direction (DirectionTable1)
#                           assigned Axis_Y + FlipBtn1; prime DirectionTable2 -> [PICK X plane]
#   C (Get-CsysFinishMacro) FlipBtn2 on the 2nd direction + refresh; then OK (stdbtn_1)
# ALL widgets here are RECORDED-LIVE in that mapkey (t1.OriginPlacement, pg_vis_tab
# tab_1/tab_2, t2.DirectionTable1/2, t2.AxisMenu1=Axis_Y, t2.FlipBtn1, t2.FlipBtn2).
# The recording assigns ONLY Axis_Y (to the first/origin direction); the second
# direction (the TOP plane) takes the remaining axis (X) implicitly - there is NO
# AxisMenu2 / Axis_X in the real flow (my earlier inference was wrong). ~Timer noise
# is dropped. stdbtn_1 (OK) was not in the recording; the tool adds it to auto-confirm.

# Macro A: open the dialog, prime the origin collector, toggle tabs. The origin
# collector (t1.OriginPlacement, on the Placement tab) is left active for the pick.
function Get-CsysOpenMacro {
    return "~ Command ``ProCmdDatumCsys``;" +
        "~ Trigger ``Odui_Dlg_00`` ``t1.OriginPlacement`` 2 ``DuMmY`` ``constr``;" +
        "~ Trigger ``Odui_Dlg_00`` ``t1.OriginPlacement`` 2 `` ``;" +
        "~ Select ``Odui_Dlg_00`` ``pg_vis_tab`` 1 ``tab_2``;" +
        "~ Select ``Odui_Dlg_00`` ``pg_vis_tab`` 1 ``tab_1``;"
}

# Macro B: after the origin edge is picked, switch to the Orientation tab; the
# direction the origin edge supplies (DirectionTable1) is assigned Axis_Y and flipped
# so +Y matches the original Y; then DirectionTable2 is primed + focused for the
# X-plane pick. (DirectionTable1 already holds the origin's direction - no pick here.)
function Get-CsysDir1Macro {
    return "~ Select ``Odui_Dlg_00`` ``pg_vis_tab`` 1 ``tab_2``;" +
        "~ Trigger ``Odui_Dlg_00`` ``t2.DirectionTable1`` 2 ``0`` ``ref``;" +
        "~ Trigger ``Odui_Dlg_00`` ``t2.DirectionTable1`` 2 `` ``;" +
        "~ Open ``Odui_Dlg_00`` ``t2.AxisMenu1``;" +
        "~ Close ``Odui_Dlg_00`` ``t2.AxisMenu1``;" +
        "~ Select ``Odui_Dlg_00`` ``t2.AxisMenu1`` 1 ``Axis_Y``;" +
        "~ Activate ``Odui_Dlg_00`` ``t2.FlipBtn1``;" +
        "~ Trigger ``Odui_Dlg_00`` ``t2.DirectionTable2`` 2 ``DuMmY`` ``ref2``;" +
        "~ Focus ``Odui_Dlg_00`` ``t2.DirectionTable2``;" +
        "~ FocusIn ``Odui_Dlg_00`` ``t2.DirectionTable2``;" +
        "~ Select ``Odui_Dlg_00`` ``t2.DirectionTable2`` 2 ``DuMmY`` ``ref2``;" +
        "~ Trigger ``Odui_Dlg_00`` ``t2.DirectionTable2`` 2 `` ``;" +
        "~ FocusOut ``Odui_Dlg_00`` ``t2.DirectionTable2``;"
}

# Macro C: after the X-direction plane is picked (into DirectionTable2), flip the 2nd
# direction and refresh both collectors. -WithOK appends stdbtn_1 (OK) to auto-confirm;
# --probe omits it so the operator can eyeball the orientation before committing.
function Get-CsysFinishMacro {
    param([switch]$WithOK)
    $m = "~ Trigger ``Odui_Dlg_00`` ``t2.DirectionTable1`` 2 ``0`` ``ref``;" +
        "~ Trigger ``Odui_Dlg_00`` ``t2.DirectionTable1`` 2 `` ``;" +
        "~ Activate ``Odui_Dlg_00`` ``t2.FlipBtn2``;" +
        "~ Trigger ``Odui_Dlg_00`` ``t2.DirectionTable1`` 2 ``0`` ``ref``;" +
        "~ Trigger ``Odui_Dlg_00`` ``t2.DirectionTable1`` 2 `` ``;" +
        "~ Trigger ``Odui_Dlg_00`` ``t2.DirectionTable2`` 2 ``0`` ``ref2``;" +
        "~ Trigger ``Odui_Dlg_00`` ``t2.DirectionTable2`` 2 `` ``;"
    if ($WithOK) { $m += "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;" }
    return $m
}

# ============================================================================
# HEADER
# ============================================================================
Write-Host ""
Write-Host "  CSYSINATOR - datum coordinate system at a round edge's center" -ForegroundColor White
Write-Host "  -------------------------------------------------------------" -ForegroundColor DarkGray

# ----------------------------------------------------------------------------
# Connect (identical pattern to every toolkit script)
# ----------------------------------------------------------------------------
try {
    $proc = Get-Process | Where-Object { $_.ProcessName -eq "xtop" }
    if ($null -eq $proc) { throw "Running Creo process (xtop) not found" }
    $Env:PRO_DIRECTORY = $proc.Path.TrimEnd("xtop.exe")
    $Env:PRO_COMM_MSG_EXE = ($proc.Path -replace "xtop.exe", "pro_comm_msg.exe")
}
catch { $_; exit }

try { New-Object -ComObject pfcls.pfcAsyncConnection | Out-Null }
catch {
    Write-Output "VB API not yet registered, performing first time setup..."
    $vb_path = $proc.Path -replace "Common Files(.*)$", "Parametric\bin\vb_api_register.bat"
    Start-Process -Wait -FilePath $vb_path
}

try {
    $async = New-Object -ComObject pfcls.pfcAsyncConnection
    $connection = $async.Connect($null, $null, $null, $null)
    $session = $connection.Session
}
catch { $_; Write-Output "Could not connect to Creo session."; exit }

# Release the connection on an early-exit path (before the main try/finally is
# entered) so a guard failure doesn't leak the COM connection.
function Close-Connection {
    try { if ($null -ne $connection) { $connection.Disconnect($null) } } catch {}
    foreach ($o in @($session,$connection,$async)) { try { if ($null -ne $o) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($o) | Out-Null } } catch {} }
}

$model = $session.GetActiveModel()
if ($null -eq $model) { Close-Connection; throw "No active model. Open the jig part first." }
Write-Host "  Connected: $($model.FileName)" -ForegroundColor Green

$modelFile = ""; try { $modelFile = [string]$model.FileName } catch {}
if ($modelFile -match '\.asm(\.\d+)?$') {
    Write-Host ""
    Write-Host "  STOP: active model is an ASSEMBLY. Open the jig PART itself and re-run." -ForegroundColor Yellow
    Close-Connection
    exit 1
}

# config suppress + finally
$origVisibleMapkeys = $null; $origDynamicPreview = $null
try { $v = $session.GetConfigOptionValues("visible_mapkeys"); if ($null -ne $v -and $v.Count -gt 0) { $origVisibleMapkeys = $v.Item(0) } } catch {}
try { $v = $session.GetConfigOptionValues("dynamic_preview"); if ($null -ne $v -and $v.Count -gt 0) { $origDynamicPreview = $v.Item(0) } } catch {}
try { $session.SetConfigOption("visible_mapkeys", "no") | Out-Null; $session.SetConfigOption("dynamic_preview", "no") | Out-Null } catch {}

try {
    $pfcType = New-Object -ComObject pfcls.pfcModelItemType

    # ========================================================================
    # Guided create - replays the operator's recorded mapkey, split around the two
    # mandatory mouse picks (origin hole edge, X-direction plane). The tool drives
    # every widget (tabs, axis dropdown, flips, OK); you make only the two picks.
    # ========================================================================
    Write-Host ""
    Write-Host "  This creates a datum csys at a ROUND edge's center:" -ForegroundColor Cyan
    Write-Host "    origin + Y  <- the round hole edge you pick (Y = its axis, aligned to original Y)" -ForegroundColor Gray
    Write-Host "    +X          <- the plane you pick for the X direction (e.g. TOP)" -ForegroundColor Gray
    Write-Host "  You make TWO picks; the tool drives the tabs / axis / flips / OK." -ForegroundColor Gray
    if ($Probe) { Write-Host "  (--probe: everything EXCEPT the final OK, so you can eyeball it first.)" -ForegroundColor DarkGray }
    Write-Host ""
    $go = Read-Host "  Open the Coordinate System dialog now? (y/N)"
    # exit 0 here (NOT Close-Connection): we are INSIDE the main try, so the finally
    # owns cleanup - it restores visible_mapkeys/dynamic_preview then disconnects.
    if ($go -notmatch '^[Yy]') { Write-Host "  Skipped - nothing created." -ForegroundColor Yellow; exit 0 }

    $beforeFeat = Get-FeatureIdSet   -Model $model -TypeObj $pfcType
    $beforeCsys = Get-CoordSysIdSet  -Model $model -TypeObj $pfcType
    $preStamp   = ""; try { $preStamp = [string]$model.VersionStamp } catch {}

    # --- Macro A: open dialog, prime origin collector, toggle tabs -> PICK #1 -----
    try { $session.RunMacro((Get-CsysOpenMacro)) } catch {
        Write-Host "  Could not open the csys command: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  PICK 1 of 2 - click the ROUND hole edge for the ORIGIN (its center)." -ForegroundColor Cyan
    $null = Read-Host "  After clicking the round edge, press ENTER"

    # DO NOT read the selection buffer / edge descriptor here. A COM DATA read
    # (CurrentSelectionBuffer / GetCurveDescriptor / ListItems) while the csys dialog
    # is OPEN and collecting a reference DEADLOCKS: Creo's main thread is blocked in
    # the dialog's pick loop and cannot service the COM query -> PowerShell freezes
    # (observed live 2026-07-07, trail.txt.33). Only RunMacro (UI events) is safe
    # mid-dialog. All COM reads happen AFTER OK (dialog closed), in the VERIFY block.

    # --- Macro B: orient tab; origin's direction -> Axis_Y + flip; prime Dir2 -> PICK #2
    try { $session.RunMacro((Get-CsysDir1Macro)) } catch {
        Write-Host "  (orient step 1 reported: $($_.Exception.Message))" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "  PICK 2 of 2 - click the plane that sets +X (e.g. the TOP plane)." -ForegroundColor Cyan
    $null = Read-Host "  After clicking the X-direction plane, press ENTER"

    # --- Macro C: flip the 2nd direction + refresh; OK unless --probe -------------
    try { $session.RunMacro((Get-CsysFinishMacro -WithOK:(-not $Probe))) } catch {
        Write-Host "  (orient step 2 reported: $($_.Exception.Message))" -ForegroundColor DarkGray
    }

    if ($Probe) {
        Write-Host ""
        Write-Host "  PROBE: everything set EXCEPT OK. In Creo, check the csys preview:" -ForegroundColor Cyan
        Write-Host "    - origin at the hole center; +Y aligned to original Y; +X along your plane." -ForegroundColor Gray
        Write-Host "  If it looks right, run again without --probe to auto-OK. If a flip is" -ForegroundColor Gray
        Write-Host "  backwards, note which axis so I can adjust the recorded flips." -ForegroundColor Gray
        $null = Read-Host "  CLOSE the dialog in Creo (Cancel or OK), THEN press ENTER"
        Write-Host "  Probe done - nothing auto-created." -ForegroundColor Green
        exit 0
    }

    # GATE before any COM read: the tool fired OK, which should close the dialog. But
    # a COM data read (Count-NewFeatures/ListItems/VersionStamp) while a Creo dialog is
    # STILL open DEADLOCKS (com-read-deadlocks-while-dialog-open). So confirm the dialog
    # has closed before verifying - if OK was rejected (e.g. an under-defined csys),
    # the operator finishes/cancels it here first.
    Write-Host ""
    Write-Host "  Clicked OK. The Coordinate System dialog should now be CLOSED." -ForegroundColor Cyan
    $null = Read-Host "  Confirm the dialog is CLOSED in Creo, then press ENTER to verify"

    # give the feature a moment to commit (heavy models regen slowly)
    [void](Wait-ModelModified -Model $model -PreviousStamp $preStamp -TimeoutMs 8000)

    # ========================================================================
    # VERIFY - feature-diff canary is the GATE; csys read-back is advisory
    # ========================================================================
    $newFeat = Count-NewFeatures -Model $model -TypeObj $pfcType -Before $beforeFeat
    if ($newFeat -lt 1) {
        # OK may not have landed (e.g. the dialog needs one more input). Let the user
        # finish + OK by hand, then re-check - never claim "created" without a feature.
        Write-Host ""
        Write-Host "  No new csys feature yet. If the dialog is still open, finish it in Creo" -ForegroundColor Yellow
        Write-Host "  (origin = hole edge; +Y its axis; +X your plane) and click OK." -ForegroundColor Yellow
        $null = Read-Host "  After you click OK in Creo, press ENTER to verify"
        $newFeat = Count-NewFeatures -Model $model -TypeObj $pfcType -Before $beforeFeat
    }
    Write-Host ""
    if ($newFeat -lt 1) {
        Write-Host "  No new coordinate-system feature detected." -ForegroundColor Yellow
        Write-Host "  If you cancelled, that's expected - nothing was created. Otherwise" -ForegroundColor Yellow
        Write-Host "  complete the dialog (origin edge -> X plane -> OK) and re-run." -ForegroundColor DarkGray
        exit 1
    }
    if ($newFeat -gt 1) {
        Write-Host ("  {0} new features detected - more than the one csys expected; check Creo." -f $newFeat) -ForegroundColor Yellow
    } else {
        Write-Host "  CREATED: one new coordinate-system feature." -ForegroundColor Green
    }

    # Read-back (SAFE now - the dialog is closed after OK): report where the new csys
    # landed so you can eyeball the origin. (No numeric origin==edge-center compare:
    # reading the picked edge's center mid-dialog would deadlock - see the note above.)
    $newCs = Read-NewCsysTransform -Model $model -TypeObj $pfcType -Before $beforeCsys
    if ($null -ne $newCs -and $null -ne $newCs.Origin) {
        Write-Host ("  New csys origin: {0}" -f (Format-Vec $newCs.Origin)) -ForegroundColor Gray
        if ($null -ne $newCs.X) { Write-Host ("  New csys +X:     {0}" -f (Format-Vec $newCs.X)) -ForegroundColor Gray }
        if ($null -ne $newCs.Y) { Write-Host ("  New csys +Y:     {0}" -f (Format-Vec $newCs.Y)) -ForegroundColor Gray }
    } else {
        Write-Host "  Coordinate system created; its transform could not be read back on this build." -ForegroundColor Yellow
    }
    # ORIENTATION is not numerically verifiable here (plane normals read null), and the
    # recorded FLIPS are geometry-specific - so confirm the axes visually:
    Write-Host "  VERIFY the axes VISUALLY: +Y aligned to original Y, +X along the plane you" -ForegroundColor Yellow
    Write-Host "  picked. If an axis is reversed, the recorded flip was opposite for this" -ForegroundColor Yellow
    Write-Host "  geometry - tell me which axis and I'll adjust (or flip it in Creo)." -ForegroundColor DarkGray

} finally {
    if ($null -ne $origVisibleMapkeys) { try { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null } catch {} }
    if ($null -ne $origDynamicPreview) { try { $session.SetConfigOption("dynamic_preview",  $origDynamicPreview)  | Out-Null } catch {} }
    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($pfcType) | Out-Null } catch {}
    try { $connection.Disconnect($null) } catch {}
    foreach ($o in @($model,$session,$connection,$async)) { try { if ($null -ne $o) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($o) | Out-Null } } catch {} }
    [System.GC]::Collect()
}

Write-Host ""
