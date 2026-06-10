<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "PLANE-PROBE"
$ErrorActionPreference = "Stop"

# ============================================================================
# PLANE-PROBE  (boxinator-parametric branch — EXPERIMENT, not production)
# ============================================================================
# Creates THREE offset datum planes — Front, Side, Top — so the three new planes
# plus the part's three default datums (FRONT/RIGHT/TOP) bound a parametric BOX
# envelope. Each plane's offset is a FEATURE-LEVEL dim, so a plain DimValue write
# + regen HOLDS (no relations, no sketch-dim snap-back) — meaning all three box
# dimensions are parametrically drivable from PowerShell.
#
# Why this works (proven over earlier probes): driving a SKETCH dim via DimValue
# snaps back on regen, and the relations route (dim = PARAM) was fiddly. A datum
# plane's OFFSET distance, by contrast, is a feature-level dim — the same
# reliable path boxinator uses for extrude depth — so a DimValue write sticks.
#
# Per-plane flow (one atomic macro, run 3x):
#   1. Snapshot the linear dim-symbol set.
#   2. User CLICKS the base reference plane in Creo (into the selection buffer),
#      presses ENTER.
#   3. ONE atomic RunMacro: ProCmdDatumPlane (opens with the buffered ref pre-
#      loaded as an Offset constraint) -> type offset into t1.constr_dim1 ->
#      Update -> FocusOut (blur so it lands) -> OK stdbtn_1.
#      Must be a single RunMacro — a dialog's command context does NOT survive
#      across separate RunMacro calls (same rule as the extrude dashboard).
#   4. Diff the dim-symbol set; the ONE new symbol is that plane's offset dim.
#
# After all three are created, a parametric loop lets you resize the whole box
# (all three at once) or any single plane — write its offset DimValue +
# Invoke-ForceRegen, re-read to confirm it held. Resizing the planes IS resizing
# the box.
#
# Widget names confirmed from a live `visible_mapkeys yes` recording:
#   ~ Command `ProCmdDatumPlane`;
#   ~ FocusOut `Odui_Dlg_00` `t1.constr_dim1`;   <- offset value field
#   ~ Activate `Odui_Dlg_00` `stdbtn_1`;         <- OK
#
# PREREQ: a part open in Creo with the three default datum planes (FRONT/RIGHT/
# TOP) to offset FROM. Run with ONE Creo session (no picker here — this is a
# probe).
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

# ---------------------------------------------------------------------------
# Fire a mapkey and report success/failure instead of swallowing it (boxinator's
# pattern). A silent no-op from a wrong widget name is the hardest mapkey bug to
# find, so count failures and surface them.
# ---------------------------------------------------------------------------
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

# Forced regen with fallbacks (lifted verbatim-in-spirit from boxinator). On this
# No-Resolve build the API forced regen throws IpfcXToolkitBadContext, so the
# reliable path is the UI ProCmdRegenerate; automatic regen is the last resort.
function Invoke-ForceRegen {
    param($Model)
    try {
        $regenCls = New-Object -ComObject pfcls.pfcRegenInstructions
        $instr    = $regenCls.Create($false, $true, $null)   # Create(AllowFixUI, ForceRegen, FromFeat)
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

# Snapshot every LINEAR dimension symbol on the model -> value. New offset dims
# are found by diffing this before vs after each plane creation, so we never have
# to guess the dim symbol. ListItems(ITEM_DIMENSION) is the proven Solid path.
function Get-LinearDimMap {
    param($Model, $TypeObj)
    $map = @{}
    try {
        foreach ($d in $Model.ListItems($TypeObj.ITEM_DIMENSION)) {
            try { if ($d.DimType -eq 0) { $map[[string]$d.Symbol] = [double]$d.DimValue } } catch {}
        }
    } catch {}
    return $map
}

# Re-read one dim's value by symbol with a FRESH handle (old COM handles can go
# stale across a regen).
function Read-DimValue {
    param($Model, $TypeObj, [string]$Sym)
    try { return [double]$Model.GetItemByName($TypeObj.ITEM_DIMENSION, $Sym).DimValue } catch { return $null }
}

# Create ONE offset plane from a buffered base reference and return its new
# offset dim symbol (or $null if none/ambiguous appeared). Splits the work the
# proven way: caller stages the pick + ENTER, this fires the single atomic macro
# and resolves the new symbol by dim-set diff.
function New-OffsetPlane {
    param($Model, $TypeObj, [string]$Label, [double]$Offset)

    $before = Get-LinearDimMap -Model $Model -TypeObj $TypeObj

    # ONE atomic macro: open (ref pre-loaded from buffer) -> offset -> blur -> OK.
    $macro =
        "~ Command ``ProCmdDatumPlane``;" +
        "~ Input  ``Odui_Dlg_00`` ``t1.constr_dim1`` ``$Offset``;" +
        "~ Update ``Odui_Dlg_00`` ``t1.constr_dim1`` ``$Offset``;" +
        "~ FocusOut ``Odui_Dlg_00`` ``t1.constr_dim1``;" +
        "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;"

    $stamp = $null
    try { $stamp = $Model.VersionStamp } catch {}
    Invoke-Macro "$Label plane: open + offset $Offset + OK" $macro

    # Give Creo a moment to commit the feature before diffing dims.
    if ($null -ne $stamp) {
        for ($i = 0; $i -lt 40; $i++) {
            try { if ($Model.VersionStamp -ne $stamp) { break } } catch {}
            Start-Sleep -Milliseconds 50
        }
    }

    $after   = Get-LinearDimMap -Model $Model -TypeObj $TypeObj
    $newSyms = @($after.Keys | Where-Object { -not $before.ContainsKey($_) })

    if ($newSyms.Count -eq 0) {
        Write-Host "    No new linear dim appeared for the $Label plane. Either it wasn't" -ForegroundColor Yellow
        Write-Host "    created (no base plane in the buffer?), or the widget names" -ForegroundColor Yellow
        Write-Host "    (t1.constr_dim1 / stdbtn_1) differ on this build." -ForegroundColor Yellow
        return $null
    }
    if ($newSyms.Count -gt 1) {
        Write-Host "    More than one new dim appeared ($($newSyms -join ', ')); taking the first." -ForegroundColor Yellow
    }
    $sym = [string]$newSyms[0]
    Write-Host "    $Label offset dim: $sym = $($after[$sym])" -ForegroundColor Green
    return $sym
}

# ============================================
# HEADER
# ============================================
Write-Host ""
Write-Host "  PLANE-PROBE — three offset planes (Front/Side/Top) = parametric box" -ForegroundColor Cyan
Write-Host "  (boxinator-parametric branch — does NOT modify boxinator.cmd)" -ForegroundColor DarkGray
Write-Host ""

# ============================================
# CONNECT (single session)
# ============================================
$procs = @(Get-Process | Where-Object { $_.ProcessName -eq "xtop" })
if ($procs.Count -eq 0) { throw "Creo (xtop.exe) is not running" }
if ($procs.Count -gt 1) {
    throw "More than one Creo session is open. This probe expects exactly ONE (no session picker here)."
}
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
if ($null -eq $model) { throw "No active model. Open a part with the default datum planes first." }

Write-Host "  Connected. Active model: $($model.FileName)" -ForegroundColor Green
Write-Host ""

# Suppress UI noise during the run, restore in finally (toolkit convention).
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

$pfcType = New-Object -ComObject pfcls.pfcModelItemType

# ============================================
# 0. ASK FOR THE THREE BOX OFFSETS
# ============================================
# Each label is just descriptive — the actual base plane is whatever you pick.
# Typical mapping: Front offsets FRONT (depth), Side offsets RIGHT (width),
# Top offsets TOP (height).
$planes = @(
    [pscustomobject]@{ Label = "Front"; Hint = "FRONT"; Offset = 0.0; Sym = $null }
    [pscustomobject]@{ Label = "Side";  Hint = "RIGHT"; Offset = 0.0; Sym = $null }
    [pscustomobject]@{ Label = "Top";   Hint = "TOP";   Offset = 0.0; Sym = $null }
)

Write-Host "  Enter the three box offsets (blank/0 -> 1.0 so each has a drivable dim):" -ForegroundColor Cyan
foreach ($p in $planes) {
    $raw = Read-Host "    $($p.Label) plane offset (from $($p.Hint))"
    $v = 0.0
    if (-not [double]::TryParse($raw, [ref]$v) -or $v -eq 0) {
        Write-Host "      using 1.0" -ForegroundColor Yellow
        $v = 1.0
    }
    $p.Offset = $v
}
Write-Host ""

# ============================================
# 1. CREATE THE THREE OFFSET PLANES (pick base ref -> one atomic macro, x3)
# ============================================
Write-Host "  Creating three offset planes. For EACH one:" -ForegroundColor Cyan
Write-Host "    - CLICK the named base plane in Creo (into the selection buffer)," -ForegroundColor White
Write-Host "    - then press ENTER; the script opens the tool, sets the offset, OKs." -ForegroundColor White
Write-Host ""

foreach ($p in $planes) {
    Write-Host "  --- $($p.Label) plane (offset $($p.Offset) from $($p.Hint)) ---" -ForegroundColor Cyan
    Read-Host "  (click the $($p.Hint) plane in Creo, then press ENTER)"
    $p.Sym = New-OffsetPlane -Model $model -TypeObj $pfcType -Label $p.Label -Offset $p.Offset
    Write-Host ""
}

$made = @($planes | Where-Object { $null -ne $_.Sym })
if ($made.Count -eq 0) {
    throw "No offset planes were created — nothing to drive."
}
if ($made.Count -lt 3) {
    Write-Host "  WARNING: only $($made.Count) of 3 planes produced a drivable dim." -ForegroundColor Yellow
    Write-Host ""
}

# ============================================
# 2. SUMMARY — the parametric box skeleton
# ============================================
# The three offsets ARE the box dimensions: Side->Width, Top->Height,
# Front->Depth. With the part's three default datums forming the box's anchored
# corner, these three offset planes are the three opposite faces, so each offset
# distance equals one box extent.
function Show-BoxState {
    param($Made)
    Write-Host "  Parametric box planes (offset = box extent):" -ForegroundColor Green
    for ($i = 0; $i -lt $Made.Count; $i++) {
        $p   = $Made[$i]
        $now = Read-DimValue -Model $model -TypeObj $pfcType -Sym $p.Sym
        $dim = switch ($p.Label) { "Side" { "Width" } "Top" { "Height" } "Front" { "Depth" } default { "" } }
        Write-Host ("    [{0}] {1,-5} ({2,-6}) {3,-6} = {4}" -f ($i + 1), $p.Label, $dim, $p.Sym, $now) -ForegroundColor White
    }
}
Show-BoxState -Made $made
Write-Host ""

# ============================================
# 2b. CREATE THE BOX — corner-rectangle sketch, extrude UP TO the SIDE plane
# ============================================
# Goal: build the actual solid whose depth is parametrically driven by the SIDE
# offset plane. Resizing SIDE later (section 3) then resizes the box depth.
#
# Flow (mirrors boxinator's proven sketch path, corner rectangle instead of
# center):
#   1. User CLICKS the sketch plane in Creo (into the buffer), presses ENTER.
#   2. ProCmdDatumSketCurve opens pre-populated -> stdbtn_1 enters the sketcher.
#   3. ProCmdSketRectangle 1 (CORNER rectangle — confirmed in CLAUDE.md Sketch
#      tools) -> user draws a rough rectangle (2 corner clicks), presses ENTER.
#   4. ProCmdSketDone exits the sketcher. User presses ENTER in PowerShell.
#   5. Extrude UP TO the SIDE plane so depth tracks that plane parametrically.
#
# Widget names all confirmed from a live `visible_mapkeys yes` recording:
#   ProCmdDatumSketCurve / Odui_Dlg_00 stdbtn_1 / ProCmdSketRectangle 1 (CORNER) /
#   ProCmdSketDone / ProCmdFtExtrude / main_dlg_cur dashInst0.Done, plus the
#   up-to-plane depth option (maindashInst0.depth_flyout + maindashInst0.toselected)
#   wired into $mkUpToPlaneOption below.

$sidePlane = @($made | Where-Object { $_.Label -eq "Side" })
$sidePlane = if ($sidePlane.Count -gt 0) { $sidePlane[0] } else { $null }

Write-Host "  Build the box now? It will be extruded UP TO the SIDE plane." -ForegroundColor Cyan
$doBox = Read-Host "    (y to create the box, anything else to skip and go straight to resize)"
if ($doBox.Trim().ToUpper() -eq "Y") {
    if ($null -eq $sidePlane) {
        Write-Host "  No SIDE plane was created, so there is nothing to extrude up to. Skipping box." -ForegroundColor Yellow
    } else {

        # --- sketch plane pick + enter sketcher (boxinator's confirmed select-first flow) ---
        Write-Host ""
        Write-Host "  In Creo: CLICK the datum plane you want to sketch the box footprint on" -ForegroundColor White
        Write-Host "  (it should highlight). Do NOT open any command — just select it, then" -ForegroundColor White
        Write-Host "  press ENTER here." -ForegroundColor White
        Read-Host

        Invoke-Macro "open sketch tool (plane pre-selected)" "~ Command ``ProCmdDatumSketCurve``;"
        Start-Sleep -Milliseconds 300
        Invoke-Macro "enter sketcher" "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;"

        # CORNER rectangle (not center) — confirmed command name in CLAUDE.md.
        Invoke-Macro "activate corner-rectangle tool" "~ Command ``ProCmdSketRectangle`` 1;"

        Write-Host ""
        Write-Host "  In Creo sketcher: click one corner of the rectangle, then the opposite" -ForegroundColor White
        Write-Host "  corner. Size doesn't matter for this probe. Press Esc to finish, then" -ForegroundColor White
        Write-Host "  press ENTER here." -ForegroundColor White
        Read-Host

        Invoke-Macro "exit sketcher" "~ Command ``ProCmdSketDone``;"

        Write-Host ""
        Write-Host "  Sketch done. Press ENTER to extrude the box up to the SIDE plane." -ForegroundColor Cyan
        Read-Host

        # --- extrude UP TO the SIDE plane ---
        # Depth-option lines confirmed from a live `visible_mapkeys yes` recording:
        #   ~ Select   `main_dlg_cur` `maindashInst0.depth_flyout`;
        #   ~ Close     `main_dlg_cur` `maindashInst0.depth_flyout`;
        #   ~ Activate `main_dlg_cur` `maindashInst0.toselected` 1;
        #   @PAUSE_FOR_SCREEN_PICK;                 <- user clicks the target plane
        #   ~ Activate `main_dlg_cur` `dashInst0.Done`;
        # The recorded @PAUSE is a real screen pick of the SIDE plane. A RunMacro
        # string can't pause mid-sequence (and the dashboard must stay atomic), so
        # we drop the @PAUSE and instead PRE-SELECT the SIDE plane into the buffer
        # before firing — boxinator's proven select-first trick — letting the
        # `toselected` option consume the buffered plane. dashInst0.Done is appended
        # by the caller below, keeping the whole extrude one atomic macro.
        $mkUpToPlaneOption =
            "~ Select ``main_dlg_cur`` ``maindashInst0.depth_flyout``;" +
            "~ Close ``main_dlg_cur`` ``maindashInst0.depth_flyout``;" +
            "~ Activate ``main_dlg_cur`` ``maindashInst0.toselected`` 1;"

        $stamp = $null
        try { $stamp = $model.VersionStamp } catch {}

        # Parametric up-to-plane path. In the recording the plane pick is a
        # @PAUSE_FOR_SCREEN_PICK that fires AFTER `toselected` activates — i.e.
        # `toselected` opens a reference collector that waits for a fresh pick. A
        # RunMacro can't pause, so we PRE-SELECT the SIDE plane into the buffer and
        # hope `toselected` consumes the buffered selection instead of waiting.
        # THAT CONSUMPTION IS THE ONE UNVERIFIED ASSUMPTION — watch it live: if the
        # extrude stalls with the dashboard open waiting for a plane pick, the
        # collector did NOT take the buffered plane and we'll need to split the pick
        # out (or keep the buffer warm a different way).
        Write-Host ""
        Write-Host "  In Creo: CLICK the SIDE offset plane (so the extrude can bind to it)," -ForegroundColor White
        Write-Host "  then press ENTER here." -ForegroundColor White
        Read-Host

        $mkExtrude =
            "~ Command ``ProCmdFtExtrude``;" +
            $mkUpToPlaneOption +
            "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"
        Invoke-Macro "extrude up to SIDE plane (parametric) + confirm" $mkExtrude

        if ($null -ne $stamp) {
            for ($i = 0; $i -lt 100; $i++) {
                try { if ($model.VersionStamp -ne $stamp) { break } } catch {}
                Start-Sleep -Milliseconds 50
            }
        }
        Write-Host ""
    }
}

# Write one plane's offset, force a regen, return the value that actually stuck.
function Set-PlaneOffset {
    param($Plane, [double]$Value)
    try {
        $d = $model.GetItemByName($pfcType.ITEM_DIMENSION, $Plane.Sym)
        $d.DimValue = $Value
    } catch {
        Write-Host "    $($Plane.Label): could not write DimValue: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
    Invoke-ForceRegen -Model $model
    return (Read-DimValue -Model $model -TypeObj $pfcType -Sym $Plane.Sym)
}

# ============================================
# 3. PARAMETRIC LOOP — resize the box (all three) or one plane, watch each stick
# ============================================
# The box-resize demonstration. Commands:
#   A           -> set all three offsets in one pass (resize the whole box)
#   1..N        -> resize a single plane
#   D / blank   -> done (exit the loop)
# Either way each write goes through Set-PlaneOffset (DimValue + force regen) and
# is re-read to confirm it held.
Write-Host "  Resize loop:" -ForegroundColor Cyan
Write-Host "    A = set ALL three (resize the box),  1-$($made.Count) = one plane,  D/blank = done" -ForegroundColor White
while ($true) {
    $cmd = Read-Host "  Command (A / 1-$($made.Count) / D)"
    if ([string]::IsNullOrWhiteSpace($cmd) -or $cmd.Trim().ToUpper() -eq "D") {
        Write-Host "  Done resizing." -ForegroundColor Cyan
        break
    }

    if ($cmd.Trim().ToUpper() -eq "A") {
        # Resize the whole box: prompt each, write each, then report once.
        $targets = @()
        foreach ($p in $made) {
            $dim = switch ($p.Label) { "Side" { "Width" } "Top" { "Height" } "Front" { "Depth" } default { "" } }
            $raw = Read-Host "    $($p.Label) ($dim) new offset"
            $v = 0.0
            if (-not [double]::TryParse($raw, [ref]$v)) { Write-Host "      not a number — skipping $($p.Label)." -ForegroundColor Yellow; continue }
            $targets += [pscustomobject]@{ Plane = $p; Want = $v }
        }
        foreach ($t in $targets) {
            $now = Set-PlaneOffset -Plane $t.Plane -Value $t.Want
            if ($null -ne $now -and [math]::Abs($now - $t.Want) -lt 1e-4) {
                Write-Host "    $($t.Plane.Label) $($t.Plane.Sym) = $now  (held)" -ForegroundColor Green
            } else {
                Write-Host "    $($t.Plane.Label) $($t.Plane.Sym) = $now  (wanted $($t.Want) — did NOT hold)" -ForegroundColor Yellow
            }
        }
        Write-Host ""
        Show-BoxState -Made $made
        Write-Host ""
        continue
    }

    $sel = 0
    if (-not [int]::TryParse($cmd, [ref]$sel) -or $sel -lt 1 -or $sel -gt $made.Count) {
        Write-Host "    enter A or 1-$($made.Count)." -ForegroundColor Yellow; continue
    }
    $p = $made[$sel - 1]

    $valRaw = Read-Host "    New offset for $($p.Label) ($($p.Sym))"
    $v = 0.0
    if (-not [double]::TryParse($valRaw, [ref]$v)) { Write-Host "    not a number." -ForegroundColor Yellow; continue }

    $now = Set-PlaneOffset -Plane $p -Value $v
    if ($null -ne $now -and [math]::Abs($now - $v) -lt 1e-4) {
        Write-Host "    $($p.Label) $($p.Sym) = $now  (held)" -ForegroundColor Green
    } else {
        Write-Host "    $($p.Label) $($p.Sym) = $now  (wanted $v — did NOT hold)" -ForegroundColor Yellow
    }
}

Write-Host ""
if ($script:macroFailures -eq 0) {
    Write-Host "  Probe complete (no mapkey failures)." -ForegroundColor Cyan
} else {
    Write-Host "  Probe complete with $($script:macroFailures) mapkey failure(s) — see red lines above." -ForegroundColor Yellow
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
