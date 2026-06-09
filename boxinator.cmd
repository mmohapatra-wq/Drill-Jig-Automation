<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "BOXINATOR"
$ErrorActionPreference = "Stop"

# -probe / --probe: temporary diagnostic. Connect to the (single) live session and dump
# GetConnectionId().ExternalRep so we can learn the string format ConnectById() expects.
# This unblocks multi-session selection: once we know what ExternalRep looks like and
# whether it embeds the xtop PID, we can build a session picker. Run with exactly ONE
# Creo session open. Prints the rep and exits without touching the model.
$ProbeMode = ($ScriptArgs -match '(?i)(^|\s)-{1,2}probe(\s|$)')

trap {
    Write-Host ""
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    # Surface WHERE it threw — the bare exception message (e.g. XToolkitAmbiguous) names no
    # line, which makes a direct-COM failure impossible to locate. Print the script line.
    $inv = $_.InvocationInfo
    if ($null -ne $inv) {
        Write-Host ("  at line {0}: {1}" -f $inv.ScriptLineNumber, $inv.Line.Trim()) -ForegroundColor DarkYellow
    }
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
        # Sleep between polls. Without this the loop busy-waits, pegging a CPU core and
        # flooding Creo with COM VersionStamp reads *during* the regen it's waiting on,
        # which slows the very operation it's polling for. 50ms is well under human-perceptible.
        Start-Sleep -Milliseconds 50
    }
    Write-Host "  (warning: timed out waiting for model update)" -ForegroundColor Yellow
}

# Force an immediate, full regen so a freshly-written feature DimValue propagates without a
# manual sketch reopen. Automatic Regenerate($null) can leave a just-written depth dim
# unpropagated (symptom: depth only updates after editing/reopening the feature's sketch).
# A forced regen fixes that — but it throws IpfcXToolkitBadContext when Creo runs in
# No-Resolve mode (the default), so we always fall back to automatic regen on failure.
# ProgID is pfcls.pfcRegenInstructions (NOT CCpfcRegenInstructions — that is unregistered);
# the CC* factory name lives as the static Create method on the pfcRegenInstructions class.
function Invoke-ForceRegen {
    param($Model)
    # Why this is not just $Model.Regenerate(): on this build Creo runs in No-Resolve mode, where
    # the VB API explicitly does NOT support regeneration — $Model.Regenerate($instr) throws
    # IpfcXToolkitBadContext (confirmed in the docs), and the only documented workaround is the
    # deprecated regen_failure_handling=resolve_mode config, which pops a blocking CS260154 dialog
    # (see CLAUDE.md). The $null (automatic/incremental) regen does NOT propagate a freshly-written
    # feature DimValue to geometry — that was the live symptom: depth stayed stale until the feature
    # was manually reopened. So the real fix is to drive Creo's own Regenerate command through the
    # UI (ProCmdRegenerate), which does a full regenerate and is exactly what the manual reopen
    # accomplished. Order: API forced regen (works if a session is ever in Resolve mode) -> UI
    # regenerate mapkey (the reliable path here) -> automatic regen as a last resort.
    try {
        $regenCls = New-Object -ComObject pfcls.pfcRegenInstructions
        $instr    = $regenCls.Create($false, $true, $null)   # Create(AllowFixUI, ForceRegen, FromFeat)
        $Model.Regenerate($instr)
        return
    } catch {
        # No-Resolve mode (IpfcXToolkitBadContext) or unavailable factory — fall through to the UI command.
    }
    # UI regenerate — mirrors the manual feature reopen that DID propagate the depth. ProCmdRegenerate
    # is the standard Creo regenerate command; if it ever no-ops, re-record with visible_mapkeys yes.
    $before = $null
    try { $before = $Model.VersionStamp } catch {}
    Invoke-Macro "force regenerate (UI)" "~ Command ``ProCmdRegenerate``;"
    if ($null -ne $before) {
        # Give the regenerate a moment to bump the stamp; if it does, the model rebuilt.
        # Poll at 50ms (finer than the old 100ms) so a fast regen returns sooner; same ~1.5s ceiling.
        for ($i = 0; $i -lt 30; $i++) {
            try { if ($Model.VersionStamp -ne $before) { return } } catch {}
            Start-Sleep -Milliseconds 50
        }
    }
    try { $Model.Regenerate($null) } catch {}
}

# Fire a mapkey and report success/failure instead of swallowing it. A silent
# failure here is what made boxinator impossible to debug — a wrong widget name
# or unready dashboard would no-op and the script would march on to "Done".
# Failures are also counted so the final report can refuse a green "Done" when a
# mapkey no-op'd partway through.
$script:macroFailures = 0
function Invoke-Macro {
    param([string]$Label, [string]$Macro)
    if ($script:DebugMacros) {
        # Announce on its own line BEFORE firing so that, if the macro hangs or diverges
        # in Creo, we know exactly which step we were on. Also echo the raw macro string.
        Write-Host ""
        Write-Host "    > $Label" -ForegroundColor Cyan
        Write-Host "      $Macro" -ForegroundColor DarkGray
    } else {
        Write-Host "    > $Label ..." -NoNewline -ForegroundColor DarkGray
    }
    try {
        $session.RunMacro($Macro)
        if ($script:DebugMacros) { Write-Host "      -> ok" -ForegroundColor Green }
        else { Write-Host " ok" -ForegroundColor DarkGray }
    } catch {
        Write-Host "      -> FAILED: $($_.Exception.Message)" -ForegroundColor Red
        $script:macroFailures++
    }
}

# Snapshot every dimension SYMBOL currently on the solid model, mapped to its value and
# type. The extrude's new depth dim is identified by diffing this before vs. after the
# extrude — ListFeaturesByType returned nothing on the live build, so we never look the new
# feature up by Id. ListItems(ITEM_DIMENSION) is the proven Solid-model path that
# gauginator and diminator already rely on. Returns a hashtable keyed by symbol.
function Get-DimSymbols {
    param($Model, $TypeObj)
    $map = @{}
    try {
        foreach ($d in $Model.ListItems($TypeObj.ITEM_DIMENSION)) {
            try { $map[$d.Symbol] = @{ Symbol = $d.Symbol; DimType = $d.DimType; DimValue = [double]$d.DimValue } } catch {}
        }
    } catch {}
    return $map
}

# Read the three components of an IpfcPoint3D. The VB API exposes sequence members
# both via .Item(i) and as a direct array; gauginator reads GravityCenter as $CG[0..2]
# so bracket indexing is the confirmed path, with .Item as a fallback.
function Get-PointXYZ {
    param($Point)
    try { return @([double]$Point[0], [double]$Point[1], [double]$Point[2]) } catch {}
    try { return @([double]$Point.Item(0), [double]$Point.Item(1), [double]$Point.Item(2)) } catch {}
    # Return $null rather than throwing — a measurement failure must degrade to "UNVERIFIED",
    # not escape to the script trap and abort the whole run after the box is already built.
    return $null
}

# Build an IpfcModelItemTypes sequence holding the datum item types we want EvalOutline to
# ignore. Default datum planes/axes/csys are auto-sized slightly larger than the solid and,
# if included, inflate every measured extent by a uniform amount (~0.0856 seen live). We
# pass these as ExcludeTypes so the outline is the SOLID GEOMETRY only.
#
# NOTE on risk (unvalidated against a live session): a datum plane's geometry may register
# as ITEM_SURFACE, which is ALSO the type of the solid's own faces. The +0.0856 inflation
# comes from the DATUM PLANES, so ITEM_SURFACE is the only exclude type that could remove
# it — but excluding it could also strip the box faces and collapse the outline. We attempt
# the full exclude set (datum item types PLUS ITEM_SURFACE); Measure-BoxExtents then runs a
# degenerate-outline guard: if excluding produced a collapsed box (any extent ~0), it falls
# back to a plain no-exclude EvalOutline. In that fallback case the datum inflation remains,
# but the 0.1 tolerance comfortably absorbs the ~0.0856 so verification still passes.
function New-ExcludeTypes {
    param($TypeObj)
    $names = @("ITEM_AXIS", "ITEM_COORD_SYS", "ITEM_POINT", "ITEM_CURVE", "ITEM_SURFACE")
    foreach ($ctor in @("pfcls.pfcModelItemTypes", "pfcls.pfcmodelitemtypes")) {
        try {
            $seq = New-Object -ComObject $ctor
            foreach ($n in $names) {
                $val = $null
                try { $val = $TypeObj.$n } catch {}
                if ($null -eq $val) { continue }
                $added = $false
                foreach ($m in @("Append", "Add", "Insert", "Set")) {
                    try { $seq.$m($val) | Out-Null; $added = $true; break } catch {}
                }
                if (-not $added) { try { $seq.Item($seq.Count) = $val } catch {} }
            }
            if ($seq.Count -gt 0) { return $seq }
        } catch {}
    }
    return $null
}

# Read the raw min/max corners from an IpfcOutline3D and return per-axis extents @(dx,dy,dz),
# or $null if the outline could not be read.
function Get-OutlineExtents {
    param($Outline)
    if ($null -eq $Outline) { return $null }
    $p0 = $null; $p1 = $null
    try { $p0 = $Outline[0]; $p1 = $Outline[1] } catch {}
    if ($null -eq $p0 -or $null -eq $p1) {
        try { $p0 = $Outline.Item(0); $p1 = $Outline.Item(1) } catch {}
    }
    if ($null -eq $p0 -or $null -eq $p1) { return $null }
    $a = Get-PointXYZ -Point $p0
    $b = Get-PointXYZ -Point $p1
    if ($null -eq $a -or $null -eq $b) { return $null }
    return @([math]::Abs($b[0]-$a[0]), [math]::Abs($b[1]-$a[1]), [math]::Abs($b[2]-$a[2]))
}

# Measure the active solid's true size via its regeneration outline. EvalOutline returns an
# IpfcOutline3D — a 2-element sequence of corner Point3Ds (min, max). The three axis extents
# ARE the box's real X/Y/Z size. Returns per-axis @(dx, dy, dz) — NOT sorted — so the caller
# can map X=length, Z=width, Y=height. Datums are excluded so they don't inflate the result;
# if the exclude collapses the outline (e.g. a face type got stripped), fall back to the
# plain no-exclude measurement.
function Measure-BoxExtents {
    param($Solid, $ExcludeTypes)

    $ext = $null
    if ($null -ne $ExcludeTypes) {
        $o = $null
        try { $o = $Solid.EvalOutline($null, $ExcludeTypes) } catch {}
        $ext = Get-OutlineExtents -Outline $o
        # Guard: a collapsed/degenerate box (any extent ~0) means the exclude stripped real
        # geometry — discard it and fall through to the no-exclude path.
        if ($null -ne $ext -and ($ext[0] -lt 1e-6 -or $ext[1] -lt 1e-6 -or $ext[2] -lt 1e-6)) {
            $ext = $null
        }
    }
    if ($null -eq $ext) {
        $o = $null
        try { $o = $Solid.EvalOutline($null, $null) } catch {}
        if ($null -eq $o) { try { $o = $Solid.GetOutline() } catch {} }
        $ext = Get-OutlineExtents -Outline $o
    }
    return $ext
}

# ============================================
# SESSION SELECTION (multi-Creo support)
# ============================================
# Background (confirmed live via -probe): Connect($null,...) throws XToolkitAmbiguous when
# >1 xtop.exe is running — it cannot pick. The only API to target a specific session is
# ConnectById(IpfcConnectionId), where the id is built from an ExternalRep string. That rep
# looks like:
#   host:NAME:address_version:0:address_type:1:rpcnum:NNNN:rpcversion:2:netaddr:HEX:netaddr_length:4
# Everything is machine-constant EXCEPT rpcnum, which the RPC runtime assigns at session
# start. rpcnum is NOT derivable from the xtop PID (PID 6056 ↔ rpcnum 1073862945, no
# relation), but it IS stable for a session's lifetime (same value across probe runs). And
# there is no API to enumerate running sessions' ids without first connecting.
#
# Strategy: cache each session's rep keyed by PID whenever we successfully connect. With >1
# session, probe each cached rep (ConnectById → read model name → disconnect) to build a
# picker labeled by ACTIVE MODEL NAME (xtop exposes no window title — confirmed empty live).
# Any session without a usable cached rep falls back to the close-the-others flow.

$script:SessionCachePath = Join-Path $env:LOCALAPPDATA "boxinator\sessions.json"

function Get-SessionCache {
    # Returns a hashtable PID(string) -> @{ rep; model; lastSeen }. Missing/corrupt = empty.
    $map = @{}
    try {
        if (Test-Path $script:SessionCachePath) {
            $json = Get-Content -Raw -Encoding UTF8 $script:SessionCachePath | ConvertFrom-Json
            foreach ($p in $json.PSObject.Properties) {
                $map[$p.Name] = @{ rep = $p.Value.rep; model = $p.Value.model; lastSeen = $p.Value.lastSeen }
            }
        }
    } catch {}
    return $map
}

function Save-SessionEntry {
    # Record/refresh one PID's rep + model name. Best-effort: a cache write must never abort
    # the run, so all IO is wrapped.
    param([int]$ProcId, [string]$Rep, [string]$ModelName)
    if ([string]::IsNullOrWhiteSpace($Rep)) { return }
    try {
        $map = Get-SessionCache
        $map["$ProcId"] = @{ rep = $Rep; model = $ModelName; lastSeen = (Get-Date).ToString("o") }
        $dir = Split-Path $script:SessionCachePath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        ($map | ConvertTo-Json) | Set-Content -Encoding UTF8 -Path $script:SessionCachePath
    } catch {}
}

function Get-ConnectionRep {
    # The ExternalRep for an open connection, or $null. Property name confirmed via -probe.
    param($Conn)
    try { return [string]$Conn.GetConnectionId().ExternalRep } catch { return $null }
}

function Get-ActiveModelName {
    # IpfcModel.FileName gives the model name in "name"."type" format (confirmed via docs).
    param($Sess)
    try {
        $m = $Sess.GetActiveModel()
        if ($null -ne $m) { return [string]$m.FileName }
    } catch {}
    return "(no active model)"
}

function Connect-ById {
    # Build an IpfcConnectionId from a cached rep string and ConnectById to it. Returns the
    # live connection or $null. ProgID CCpfc* factories are NOT standalone ProgIDs (see
    # CLAUDE.md) — the Create factory lives as a static method on the pfcConnectionId class
    # object, mirroring the pfcRegenInstructions pattern.
    param($Async, [string]$Rep)
    if ([string]::IsNullOrWhiteSpace($Rep)) { return $null }
    foreach ($ctor in @("pfcls.pfcConnectionId", "pfcls.CCpfcConnectionId")) {
        try {
            $idCls = New-Object -ComObject $ctor
            $cid   = $idCls.Create($Rep)
            return $Async.ConnectById($cid, $null, $null)
        } catch { continue }
    }
    return $null
}

function Select-CreoSession {
    # Resolve a single live connection from possibly-many xtop.exe sessions. Returns a
    # connection object (already connected) or throws with an actionable message.
    #   1 session  -> Connect(); cache its rep.
    #   >1 session -> probe cached reps to label a picker by model name; ConnectById the pick.
    #                 Pick with no usable rep -> guide closing the others, then Connect().
    param($Async, $Procs)

    if ($Procs.Count -eq 1) {
        $conn = $Async.Connect($null, $null, $null, $null)
        $rep  = Get-ConnectionRep -Conn $conn
        Save-SessionEntry -ProcId $Procs[0].Id -Rep $rep -ModelName (Get-ActiveModelName -Sess $conn.Session)
        return $conn
    }

    Write-Host ""
    Write-Host "  $($Procs.Count) Creo sessions (xtop.exe) are running." -ForegroundColor Yellow
    $cache = Get-SessionCache

    # Build candidate list. For each PID with a cached rep, briefly ConnectById to read the
    # live model name so the picker is accurate (a part may have changed since last cached).
    $cands = @()
    foreach ($p in $Procs) {
        $entry = $cache["$($p.Id)"]
        $rep   = if ($null -ne $entry) { $entry.rep } else { $null }
        $model = "(unknown — not yet seen by boxinator alone)"
        $hasRep = $false
        if (-not [string]::IsNullOrWhiteSpace($rep)) {
            $probe = Connect-ById -Async $Async -Rep $rep
            if ($null -ne $probe) {
                $hasRep = $true
                $model  = Get-ActiveModelName -Sess $probe.Session
                Save-SessionEntry -ProcId $p.Id -Rep $rep -ModelName $model
                try { $probe.Disconnect($null) } catch {}
            }
        }
        $cands += [pscustomobject]@{ Proc = $p; Pid = $p.Id; Rep = $rep; HasRep = $hasRep; Model = $model }
    }

    Write-Host ""
    Write-Host "  Select a Creo session:" -ForegroundColor Green
    for ($i = 0; $i -lt $cands.Count; $i++) {
        $c = $cands[$i]
        $tag = if ($c.HasRep) { "" } else { "  [not directly selectable]" }
        Write-Host ("    [{0}] PID {1,-6}  {2}{3}" -f ($i + 1), $c.Pid, $c.Model, $tag) -ForegroundColor White
    }
    Write-Host ""
    $sel = Read-Host "  Enter the number of the session to use"
    $idx = 0
    if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $cands.Count) {
        throw "Invalid selection '$sel'."
    }
    $chosen = $cands[$idx - 1]

    if ($chosen.HasRep) {
        $conn = Connect-ById -Async $Async -Rep $chosen.Rep
        if ($null -ne $conn) {
            Save-SessionEntry -ProcId $chosen.Pid -Rep $chosen.Rep -ModelName (Get-ActiveModelName -Sess $conn.Session)
            Write-Host "  Connected to PID $($chosen.Pid)." -ForegroundColor Green
            return $conn
        }
        Write-Host "  Cached connection for PID $($chosen.Pid) failed — falling back." -ForegroundColor Yellow
    }

    # Fallback: no usable rep. ConnectById is impossible, so the only way to reach this
    # specific session is to make it the ONLY one running, then Connect().
    Write-Host ""
    Write-Host "  PID $($chosen.Pid) has no usable saved connection (boxinator has not seen it" -ForegroundColor Yellow
    Write-Host "  running by itself yet). To use it, close every OTHER Creo session and leave" -ForegroundColor Yellow
    Write-Host "  ONLY PID $($chosen.Pid) open, then press ENTER here." -ForegroundColor Yellow
    Read-Host
    $still = @(Get-Process | Where-Object { $_.ProcessName -eq "xtop" })
    if ($still.Count -ne 1) {
        throw ("Expected exactly 1 Creo session after closing the others, found $($still.Count). " +
               "Close all but PID $($chosen.Pid) and re-run.")
    }
    $conn = $Async.Connect($null, $null, $null, $null)
    $rep  = Get-ConnectionRep -Conn $conn
    Save-SessionEntry -ProcId $still[0].Id -Rep $rep -ModelName (Get-ActiveModelName -Sess $conn.Session)
    return $conn
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
Write-Host "    Length is the X extent, Width the Z extent (both drawn on the sketch plane)." -ForegroundColor Gray
Write-Host "    Height is the Y extent — the extrude depth." -ForegroundColor Gray
Write-Host ""
$length = [double](Read-Host "  Length (X)")
$width  = [double](Read-Host "  Width (Z)")
$height = [double](Read-Host "  Height (Y, extrude)")
Write-Host ""

# ============================================
# CONNECT TO CREO
# ============================================
$procs = @(Get-Process | Where-Object { $_.ProcessName -eq "xtop" })
if ($procs.Count -eq 0) { throw "Creo (xtop.exe) is not running" }
$proc = $procs[0]

$Env:PRO_DIRECTORY    = $proc.Path.TrimEnd("xtop.exe")
$Env:PRO_COMM_MSG_EXE = $proc.Path -replace "xtop.exe", "pro_comm_msg.exe"

try { New-Object -ComObject pfcls.pfcAsyncConnection | Out-Null }
catch {
    $reg = $proc.Path -replace "Common Files(.*)$", "Parametric\bin\vb_api_register.bat"
    Start-Process -Wait -FilePath $reg
}

$async = New-Object -ComObject pfcls.pfcAsyncConnection
# Resolve which session to attach to. With one xtop this is a plain Connect(); with several
# it presents a model-name picker backed by the per-PID rep cache (see Select-CreoSession).
$connection = Select-CreoSession -Async $async -Procs $procs
$session    = $connection.Session

# ---- PROBE MODE: dump the connection ID format, then exit -------------------
# We need the real ExternalRep string to build ConnectById()-based session
# selection. Inspect both the raw COM object and its string rep, and note the
# xtop PID so we can tell whether the rep embeds it.
if ($ProbeMode) {
    Write-Host ""
    Write-Host "  [PROBE] xtop PID = $($proc.Id)" -ForegroundColor Magenta
    try { Write-Host "  [PROBE] xtop MainWindowTitle = '$($proc.MainWindowTitle)'" -ForegroundColor Magenta } catch {}
    try {
        $cid = $connection.GetConnectionId()
        Write-Host "  [PROBE] GetConnectionId() COM type: $($cid.GetType().FullName)" -ForegroundColor Magenta
        $rep = $null
        try { $rep = $cid.ExternalRep } catch { Write-Host "  [PROBE] .ExternalRep threw: $($_.Exception.Message)" -ForegroundColor Yellow }
        Write-Host "  [PROBE] ExternalRep = >>>$rep<<<" -ForegroundColor Green
        Write-Host "  [PROBE] ExternalRep length = $(([string]$rep).Length) chars" -ForegroundColor Magenta
        # Enumerate any other readable members in case the rep is exposed under a
        # different property name on this COM build.
        Write-Host "  [PROBE] ConnectionId members:" -ForegroundColor Magenta
        try {
            $cid | Get-Member -ErrorAction SilentlyContinue |
                Where-Object { $_.MemberType -match 'Property|Method' } |
                ForEach-Object { Write-Host "      $($_.MemberType)  $($_.Name)" -ForegroundColor DarkGray }
        } catch {}
    } catch {
        Write-Host "  [PROBE] GetConnectionId() threw: $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  [PROBE] Done — paste the ExternalRep line above back to continue building session selection." -ForegroundColor Magenta
    try { $connection.Disconnect($null) } catch {}
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 0
}
# -----------------------------------------------------------------------------

$model      = $session.GetActiveModel()

# DEBUG VISIBILITY: when on, visible_mapkeys=yes makes each macro replay on screen
# so we can watch exactly which widget interaction diverges. Flip to $false once the
# sketch/extrude flow is confirmed, to restore the quiet repo-convention behavior.
$DebugMacros = $false

$origVis = $null; $origPrev = $null
try { $v = $session.GetConfigOptionValues("visible_mapkeys"); if ($v.Count -gt 0) { $origVis  = $v.Item(0) } } catch {}
try { $v = $session.GetConfigOptionValues("dynamic_preview");  if ($v.Count -gt 0) { $origPrev = $v.Item(0) } } catch {}
$visSetting = if ($DebugMacros) { "yes" } else { "no" }
try { $session.SetConfigOption("visible_mapkeys", $visSetting) | Out-Null } catch {}
try { $session.SetConfigOption("dynamic_preview",  "no") | Out-Null } catch {}
if ($DebugMacros) {
    Write-Host ""
    Write-Host "  [DEBUG] visible_mapkeys = yes — each macro will replay on screen in Creo." -ForegroundColor Magenta
    Write-Host "  [DEBUG] Watch which step diverges, then report the macro label shown below." -ForegroundColor Magenta
}
# NOTE: do NOT set regen_failure_handling here. It is deprecated on this Creo build and
# setting it pops a blocking "allow deprecated config (CS260154)" authorization dialog
# that stalls the whole run. Depth is made reliable by writing the feature depth DimValue
# directly then a plain Regenerate($null) + re-read (diminator's pattern), not by regen mode.

try {

# ============================================
# OPEN SKETCHER (confirmed pattern: real screen-pick populates the plane MRU)
# ============================================
# SELECT-FIRST flow. Clicking the plane *after* the Sketch dialog is open did NOT land
# it in the dialog's Plane field (confirmed live: "enter sketcher failed, plane field
# still empty"), so the t1.PlnMru trigger had nothing to select. Instead we have the user
# pick the plane on screen FIRST (a real graphics-window selection into the buffer), THEN
# fire ProCmdDatumSketCurve — with a plane already selected, this Creo opens the Sketch
# dialog with the Plane field auto-populated, and we just confirm with stdbtn_1. No MRU.
Write-Host ""
Write-Host "  In Creo: CLICK the datum plane you want to sketch on (it should highlight)." -ForegroundColor White
Write-Host "  Do NOT open any command — just select the plane, then press ENTER here." -ForegroundColor White
Read-Host

Invoke-Macro "open sketch tool (plane pre-selected)" "~ Command ``ProCmdDatumSketCurve``;"

# Give the Sketch dialog a moment to come up pre-populated, then confirm it. If this Creo
# jumps straight into the sketcher (no dialog) the stdbtn_1 Activate will no-op/fail
# harmlessly — watch the screen and report which happens.
Start-Sleep -Milliseconds 600
Invoke-Macro "enter sketcher" "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;"

# Activate center rectangle tool and wait for user to draw
$mkRectTool = "~ Command ``ProCmdSketCenterRectangle`` 1;"
Invoke-Macro "activate center-rectangle tool" $mkRectTool

Write-Host ""
Write-Host "  In Creo sketcher: click the center of the rectangle, then click a corner." -ForegroundColor White
Write-Host "  The size doesn't matter — dimensions will be set automatically." -ForegroundColor Gray
Write-Host "  Then press Esc to finish the rectangle." -ForegroundColor White
Write-Host ""

# ============================================
# SET SKETCH DIMENSIONS — one double-click PER dim, no per-edge dimension tool
# ============================================
# The inline dim editor (mod_dim_emb) only exists while a single dim is being edited.
# Double-clicking a sketch dim opens it (DEV_NOTES: "Also fires on double-click of existing
# dim"). A write + Activate commits that dim and CLOSES the editor — it does NOT advance to a
# second dim. (The earlier "one double-click fills both" attempt set only one value for exactly
# this reason.) So each dim needs its own double-click; the write+Activate then sticks it.
# This is still just two double-clicks total — no ProCmdSketDimension per-edge picking.
#
# LENGTH/WIDTH order is not load-bearing — the geometric EvalOutline verify (below) repairs a
# swap, so it doesn't matter which dim the user double-clicks first.
#
# NOTE: do NOT switch this to the VB API. A freshly drawn weak sketch dim is not yet a model
# item — $session.GetActiveModel().ListItems(ITEM_DIMENSION) returns 0 for an in-progress
# sketch (confirmed live), and the VB API exposes no live-sketcher dimension accessor.
foreach ($pass in @(
    @{ Label = 'FIRST';  Value = $length },
    @{ Label = 'SECOND'; Value = $width  }
)) {
    Write-Host ("  DOUBLE-CLICK the {0} dimension in Creo (its inline edit box must appear)," -f $pass.Label) -ForegroundColor White
    Write-Host "  then press ENTER here." -ForegroundColor White
    Read-Host

    $mk =
        "~ Update ``main_dlg_cur`` ``mod_dim_emb`` ``$($pass.Value)``;" +
        "~ Activate ``main_dlg_cur`` ``mod_dim_emb``;"
    Invoke-Macro "set $($pass.Label.ToLower()) sketch dim = $($pass.Value)" $mk
}

# ============================================
# EXIT SKETCHER
# ============================================
$stamp = $model.VersionStamp
Invoke-Macro "exit sketcher" "~ Command ``ProCmdSketDone``;"
Wait-ModelModified -Model $model -PreviousStamp $stamp

# ============================================
# EXTRUDE WITH EXACT DEPTH
# ============================================
# HEIGHT (Y) is the extrude depth. Approach mirrors diminator's proven path:
#   1. Snapshot every dimension SYMBOL on the model BEFORE the extrude.
#   2. Open the extrude tool, type the height into the dashboard, and fire dashInst0.Done
#      to commit programmatically — fully automatic, no manual green check.
#   3. Diff the dim symbols AFTER: the symbol(s) that appeared belong to the new extrude.
#   4. Identify the depth dim by elimination (the new Linear dim matching neither length nor
#      width), set its DimValue = height, force a regen (Invoke-ForceRegen) so it propagates
#      without a manual sketch reopen, then re-read to confirm it stuck.
$pfcModelItemType = New-Object -ComObject pfcls.pfcModelItemType

# Before-snapshot of dimension symbols (proven ListItems(ITEM_DIMENSION) path).
$beforeDims = Get-DimSymbols -Model $model -TypeObj $pfcModelItemType

Invoke-Macro "open extrude tool" "~ Command ``ProCmdFtExtrude``;"
Start-Sleep -Milliseconds 800

# Type the height into the dashboard MRU field, then commit with dashInst0.Done — fully
# automatic per the chosen flow. The authoritative feature DimValue write below still runs
# afterward to guarantee the depth is exact regardless of what the dashboard field produced.
$stamp = $model.VersionStamp
$mkExtrudeDepth =
    "~ Update ``main_dlg_cur`` ``GrmTextTagEmbedMRU`` ``$height``;" +
    "~ Activate ``main_dlg_cur`` ``GrmTextTagEmbedMRU``;" +
    "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"
Invoke-Macro "set depth = $height and commit extrude" $mkExtrudeDepth
Wait-ModelModified -Model $model -PreviousStamp $stamp

# ============================================
# IDENTIFY DEPTH DIM (no write yet — measure first, correct only if needed)
# ============================================
# Identify the new extrude's depth dim by diffing dimension symbols before vs. after.
# Whatever symbols are new belong to the extrude. Depth is the new Linear dim whose value
# matches NEITHER requested length NOR width (found by elimination). We DO NOT write/regen
# here: the extrude's dashInst0.Done already committed and regenerated the feature, so the
# geometry is usually already correct. A full $model.Regenerate($null) is the slow step, so
# we defer it — the EvalOutline measure below decides whether the authoritative DimValue
# write + regen is actually needed (only when the dashboard depth came out wrong).
$afterDims = Get-DimSymbols -Model $model -TypeObj $pfcModelItemType

$depthSym = $null
$newSymbols = @($afterDims.Keys | Where-Object { -not $beforeDims.ContainsKey($_) })
if ($newSymbols.Count -eq 0) {
    Write-Host "  WARNING: no new dimension appeared after the extrude — depth correction unavailable if needed." -ForegroundColor Yellow
} else {
    Write-Host "  New dimension(s) after extrude:" -ForegroundColor White
    foreach ($s in $newSymbols) {
        $info = $afterDims[$s]
        $tname = switch ($info.DimType) { 0 {"Linear"} 1 {"Radial"} 2 {"Diameter"} 3 {"Angular"} default {"?"} }
        Write-Host ("      {0,-6} {1,-8} = {2}" -f $info.Symbol, $tname, $info.DimValue) -ForegroundColor Gray
    }

    # Depth = new Linear dim matching neither length nor width (it is the height/Y extrude).
    $depthSymbols = @($newSymbols | Where-Object {
        $afterDims[$_].DimType -eq 0 -and
        [math]::Abs($afterDims[$_].DimValue - $length) -ge 1e-4 -and
        [math]::Abs($afterDims[$_].DimValue - $width)  -ge 1e-4
    })
    # Fall back: exactly one new Linear dim (even if it numerically equals L/W) is depth.
    if ($depthSymbols.Count -eq 0) {
        $newLinear = @($newSymbols | Where-Object { $afterDims[$_].DimType -eq 0 })
        if ($newLinear.Count -eq 1) { $depthSymbols = $newLinear }
    }

    if ($depthSymbols.Count -eq 1) {
        $depthSym = $depthSymbols[0]
        Write-Host "  Depth dim identified as $depthSym (will correct only if the measure disagrees)." -ForegroundColor Gray
    } elseif ($depthSymbols.Count -gt 1) {
        Write-Host "  WARNING: $($depthSymbols.Count) candidate depth dims (none match W/H) — cannot pick safely. Verify below." -ForegroundColor Yellow
    } else {
        Write-Host "  WARNING: no depth dim found among the new dimensions — verify below." -ForegroundColor Yellow
    }
}

# ============================================
# GEOMETRIC VERIFY (EvalOutline) — directional, datum-excluded
# ============================================
# Source of truth: measure the solid itself. The axes are mapped explicitly per the user's
# convention: X extent = LENGTH, Z extent = WIDTH, Y extent = HEIGHT (the extrude). No
# sorting — each measured axis is compared to its named target so a mismatch report names
# the wrong axis directly. Datums are excluded from the outline so they don't inflate the
# extents. Tolerance is in model units.
$tol = 0.1
$excludeTypes = New-ExcludeTypes -TypeObj $pfcModelItemType
$targetByAxis = @{ X = $length; Y = $height; Z = $width }

Write-Host ""
Write-Host "  Measuring the solid (EvalOutline, datums excluded)..." -ForegroundColor White
$measured = Measure-BoxExtents -Solid $model -ExcludeTypes $excludeTypes

$verifyPass = $false
if ($null -eq $measured) {
    Write-Host "  WARNING: could not read the solid outline — size is UNVERIFIED." -ForegroundColor Yellow
} else {
    Write-Host ("    measured  X={0:0.####} (len)  Z={2:0.####} (wid)  Y={1:0.####} (hgt)" -f $measured[0], $measured[1], $measured[2]) -ForegroundColor Gray
    Write-Host ("    requested X={0:0.####} (len)  Z={1:0.####} (wid)  Y={2:0.####} (hgt)" -f $length, $width, $height) -ForegroundColor Gray
    $verifyPass = $true
    if ([math]::Abs($measured[0] - $length) -ge $tol) { $verifyPass = $false; Write-Host ("    X (length) off: measured {0:0.####}, wanted {1:0.####}" -f $measured[0], $length) -ForegroundColor Yellow }
    if ([math]::Abs($measured[2] - $width)  -ge $tol) { $verifyPass = $false; Write-Host ("    Z (width) off:  measured {0:0.####}, wanted {1:0.####}" -f $measured[2], $width)  -ForegroundColor Yellow }
    if ([math]::Abs($measured[1] - $height) -ge $tol) { $verifyPass = $false; Write-Host ("    Y (height) off: measured {0:0.####}, wanted {1:0.####}" -f $measured[1], $height) -ForegroundColor Yellow }
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
# echo. Height (Y) is a feature-level depth dim (DimValue writes stick on a closed sketch);
# length (X) and width (Z) are sketch dims and need the sketch-open flow.
if ($null -ne $measured -and -not $verifyPass) {

    # Per-axis pass flags from the directional measurement (X=length, Z=width, Y=height).
    $lengthOk = [math]::Abs($measured[0] - $length) -lt $tol
    $widthOk  = [math]::Abs($measured[2] - $width)  -lt $tol
    $heightOk = [math]::Abs($measured[1] - $height) -lt $tol

    # Height (Y extrude) measured wrong — the dashboard depth came out off, so NOW run the
    # authoritative correction we deferred: diminator's feature-dim path (set DimValue +
    # $model.Regenerate($null) + re-read). This regen only fires in the wrong-depth case,
    # so the common correct-depth path skips it entirely (that was the slow step).
    if (-not $heightOk) {
        Write-Host ""
        if ($null -ne $depthSym) {
            Write-Host "  Height (Y extrude) measured wrong — correcting depth dim $depthSym = $height..." -ForegroundColor Yellow
            try {
                $depthDim = $model.GetItemByName($pfcModelItemType.ITEM_DIMENSION, $depthSym)
                $depthDim.DimValue = $height
                Write-Host "  Regenerating after depth set..." -NoNewline
                try { $model.Regenerate($null) } catch {}
                Write-Host " done." -ForegroundColor Green

                # Re-read after regen (diminator's truth check). Confirms the feature dim held.
                $confirm = $model.GetItemByName($pfcModelItemType.ITEM_DIMENSION, $depthSym).DimValue
                if ([math]::Abs([double]$confirm - $height) -lt 1e-4) {
                    Write-Host "  Set depth dim $depthSym = $height (held through regen)." -ForegroundColor Green
                } else {
                    Write-Host "  WARNING: depth dim $depthSym snapped back to $confirm after regen (wanted $height)." -ForegroundColor Yellow
                }
            } catch {
                Write-Host "  WARNING: depth DimValue write threw: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        } else {
            # No depth dim was identifiable — fall back to the manual guidance.
            Write-Host "  Height (Y extrude) measures wrong and no depth dim was identified to correct it." -ForegroundColor Yellow
            Write-Host "  In Creo, manually reopen/redefine the extrude feature (or run Regenerate) to force it," -ForegroundColor Yellow
            Write-Host "  then press ENTER here to re-measure." -ForegroundColor Yellow
            Read-Host
            try { $model.Regenerate($null) } catch {}
        }
    }

    # --- Sketch repair: length/width that did not land ---
    # GATED. Auto-driving the sketch open/close + Regenerate sequence has crashed Creo
    # (fatal traceback) when the model was in a half-committed state. So we never enter it
    # without an explicit y/n, and we tell the user to make sure no tool/dialog is open
    # first. If they decline, the box is reported NOT confirmed rather than risking a crash.
    if (-not $lengthOk -or -not $widthOk) {
        Write-Host ""
        Write-Host "  In-plane size is off (length and/or width did not stick)." -ForegroundColor Yellow
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
        # sketch dim to length or width by which CURRENT VALUE it sits closest to — the
        # geometric pairing, not the old pick-order guess. Whichever requested value is
        # missing gets written onto the dim currently nearest it.
        $sketchModel = $session.GetActiveModel()
        $sketchDims = @()
        try {
            foreach ($d in $sketchModel.ListItems($pfcModelItemType.ITEM_DIMENSION)) {
                if ($d.DimType -eq 0) { $sketchDims += $d }
            }
        } catch {}

        # Track dims already claimed by a target so a second target can't re-pick the
        # same edge. Without this, when both length and width are off the width pass
        # could select the dim the length pass just set (now == $length) and collapse
        # both requested sizes onto one edge, leaving the other unchanged.
        $script:usedSymbols = @()

        function Repair-SketchDim {
            param([double]$Target)
            $best = $null; $bestErr = [double]::MaxValue
            foreach ($d in $sketchDims) {
                if ($script:usedSymbols -contains $d.Symbol) { continue }
                $err = [math]::Abs([double]$d.DimValue - $Target)
                if ($err -lt $bestErr) { $bestErr = $err; $best = $d }
            }
            if ($null -ne $best) {
                try {
                    $best.DimValue = $Target
                    $script:usedSymbols += $best.Symbol
                    Write-Host "    set sketch dim $($best.Symbol) -> $Target" -ForegroundColor Green
                } catch {
                    Write-Host "    FAIL  sketch dim write threw: $($_.Exception.Message)" -ForegroundColor Red
                }
            } else {
                Write-Host "    FAIL  no unclaimed Linear sketch dim found to set to $Target." -ForegroundColor Red
            }
        }

        if (-not $lengthOk) { Repair-SketchDim -Target $length }
        if (-not $widthOk)  { Repair-SketchDim -Target $width }

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
    $measured = Measure-BoxExtents -Solid $model -ExcludeTypes $excludeTypes
    if ($null -eq $measured) {
        Write-Host "  WARNING: could not re-read the solid outline — size is UNVERIFIED." -ForegroundColor Yellow
        $verifyPass = $false
    } else {
        Write-Host ("    measured  X={0:0.####} (len)  Z={2:0.####} (wid)  Y={1:0.####} (hgt)" -f $measured[0], $measured[1], $measured[2]) -ForegroundColor Gray
        $verifyPass = (
            [math]::Abs($measured[0] - $length) -lt $tol -and
            [math]::Abs($measured[2] - $width)  -lt $tol -and
            [math]::Abs($measured[1] - $height) -lt $tol
        )
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
    Write-Host ("  Done. Box: Length(X)={0} Width(Z)={1} Height(Y)={2} (measured and confirmed)." -f `
        $length, $width, $height) -ForegroundColor Green
} elseif ($null -eq $measured) {
    Write-Host "  Box created but size UNVERIFIED (could not read the solid outline)." -ForegroundColor Yellow
    Write-Host "  Measure the solid in Creo before trusting these dimensions." -ForegroundColor Yellow
} else {
    Write-Host ("  Box created but NOT confirmed.") -ForegroundColor Yellow
    Write-Host ("    requested  Length(X)={0}  Width(Z)={1}  Height(Y)={2}" -f `
        $length, $width, $height) -ForegroundColor Yellow
    Write-Host ("    measured   Length(X)={0:0.####}  Width(Z)={1:0.####}  Height(Y)={2:0.####}" -f `
        $measured[0], $measured[2], $measured[1]) -ForegroundColor Yellow
    Write-Host "  Measure the solid in Creo before trusting these dimensions." -ForegroundColor Yellow
}

} finally {
    try { if ($null -ne $origVis)   { $session.SetConfigOption("visible_mapkeys", $origVis)   | Out-Null } } catch {}
    try { if ($null -ne $origPrev)  { $session.SetConfigOption("dynamic_preview",  $origPrev)  | Out-Null } } catch {}
    $connection.Disconnect($null)
}

Write-Host ""
Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
