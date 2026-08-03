<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir=((Split-Path -Parent ('%~dp0'.TrimEnd('\')))+'\'); $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "RADIALPAT-PROBE"
$ErrorActionPreference = "Stop"

# ============================================================================
# RADIALPAT-PROBE -- prove the ROOT CAUSE of the curved chip-relief AXIS-pattern no-op
# and MINE the two tokens that unlock the atomic fix. ([[project_curved_radial_slot_pattern]])
# ============================================================================
# ROOT CAUSE (workflow-confirmed 2026-07-31): the operator's `axispattern` mapkey works
# under Creo's native interpreter (ONE continuous playback with an INTERNAL @PAUSE for the
# axis pick -- the dashboard context survives it). The tool fired it as THREE separate
# RunMacro calls (open -> operator axis dialog -> values+stdbtn_1); a dashboard's command
# context does NOT survive across separate RunMacro calls, so the confirm landed in a
# dashboard Creo had dropped -> nothing created ("opens but does nothing"). RunMacro CANNOT
# honor @PAUSE, so the ONLY viable radial via RunMacro is ONE atomic macro that feeds the
# rotation AXIS BY ID (no pick) -- like the flat slot pattern feeds its direction by id.
# That atomic macro needs TWO tokens NEVER recorded (mine-don't-guess): the axis-collector
# ARM widget + the datum-axis tree-search SelOptionRadio value. This probe records them.
#
#   SECTION A -- T0 ROOT-CAUSE DEMO (mutating; delete the throwaway after): fire the OLD
#     SPLIT sequence INLINE (Build-RadialPatternOpenMacro as RunMacro #1 -> you pick the
#     axis -> Build-RadialPatternValuesMacro as RunMacro #2). EXPECTED: dashboard opens but
#     VersionStamp does NOT move / no new feature -- confirming the split, not the tokens.
#
#   SECTION B -- T1/T2 RECORDER (creates NOTHING via macro; you do every click): with
#     visible_mapkeys on, create a datum AXIS (2 planes) then pattern using it by hand; the
#     probe DIFFS the trail -> artifacts\radialpat_recipe.txt. Look for (i) the axis-collector
#     ARM widget (the ui_pat_dir_dir1 analog for an Axis pattern) and (ii) the ProCmdMdlTreeSearch
#     SelOptionRadio value that selects a datum AXIS by id. Paste both into curved_relief.ps1's
#     $global:RadialAxisCollectorWidget / $global:RadialAxisSelType (or pass --axis-widget/--axis-seltype).
#
#   SECTION C -- T3/T4 ATOMIC-FIX TEST (mutating; runs only when both tokens are supplied):
#     fire the NEW single-RunMacro Build-RadialPatternAtomicMacro via Invoke-CurvedReliefRadialPattern
#     with a real datum-axis feature id. T3 = raw-COM seed; T4 = operator tree-clicks the seed
#     (--live-seed). SUCCESS = VersionStamp moves + a new feature. Proves atomicity fixes the
#     dropped confirm AND the axis collector accepts a by-id feed.
#
# ID-ONLY (Id / GetName); NEVER IpfcPoint.Point. ONE Creo session. Writes
# artifacts\radialpat_probe_report.txt + (Section B) radialpat_recipe.txt (both gitignored).
# FLAGS: -v verbose; --record-only (skip A, just record B); --axis-widget <w> / --axis-seltype <t>
#   (supply the mined tokens to run Section C); --axis-id <n> (datum-axis feature id for C);
#   --live-seed (T4: operator tree-clicks the seed instead of raw-COM).
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

$argStr     = [string]$ScriptArgs
$verbose    = $argStr -match '(?i)(^|\s)(-v|--verbose)(\s|$)'
$recordOnly = $argStr -match '(?i)--record-only'
$liveSeed   = $argStr -match '(?i)--live-seed'
$axisWidget = $null; if ($argStr -match '(?i)--axis-widget\s+(\S+)')  { $axisWidget = $Matches[1] }
$axisSelTyp = $null; if ($argStr -match '(?i)--axis-seltype\s+(\S+)') { $axisSelTyp = $Matches[1] }
$axisIdArg  = 0;     if ($argStr -match '(?i)--axis-id\s+(\d+)')      { $axisIdArg  = [int]$Matches[1] }

Write-Host ""
Write-Host "  RADIALPAT-PROBE -- confirm the curved chip-relief AXIS pattern + record the axis-from-planes idea." -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# SHARED LIBRARY
# ============================================================================
. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')
. (Join-Path $ScriptDir 'lib\drilljig_core.ps1')          # Initialize-DrilljigCore, Get-FeatureIdSet, Wait-ModelModified, Read-SelectedId
. (Join-Path $ScriptDir 'lib\conformal_blank.ps1')
. (Join-Path $ScriptDir 'lib\curved_fastener_hole.ps1')   # Get-ComSelectFactory
. (Join-Path $ScriptDir 'lib\curved_relief.ps1')          # Build-RadialPattern*Macro + Invoke-CurvedReliefRadialPattern
. (Join-Path $ScriptDir 'lib\curved_radial.ps1')          # (pure plan, for reference)

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
if ($null -eq $model) { throw "No active model. Open the jig PART with the curved blank + a chip-relief pocket already cut." }
$fname = try { [string]$model.FileName } catch { "" }

$pfcType = New-Object -ComObject pfcls.pfcModelItemType
Initialize-DrilljigCore -Session $session -Model $model -TypeObj $pfcType -DataDir $ScriptDir -Log $null
Write-Host "  Connected. Active model: $fname" -ForegroundColor Green
Write-Host ""

# config-suppress (restored in the finally)
$origVisibleMapkeys = $null; $origDynamicPreview = $null
try { $vals = $session.GetConfigOptionValues("visible_mapkeys"); if ($null -ne $vals -and $vals.Count -gt 0) { $origVisibleMapkeys = $vals.Item(0) } } catch {}
try { $vals = $session.GetConfigOptionValues("dynamic_preview"); if ($null -ne $vals -and $vals.Count -gt 0) { $origDynamicPreview = $vals.Item(0) } } catch {}

$script:report = @()
function Rep { param([string]$Line, [string]$Color = 'Gray') Write-Host ("  " + $Line) -ForegroundColor $Color; $script:report += $Line }

# Find the newest trail.txt.* under the working folder (for Section B's diff).
function Find-NewestTrail {
    $wf = Join-Path $env:USERPROFILE 'working_folder\trail'
    $cands = @()
    foreach ($dir in @($wf, (Join-Path $env:USERPROFILE 'working_folder'), (Get-Location).Path)) {
        try { if (Test-Path $dir) { $cands += @(Get-ChildItem -Path $dir -Filter 'trail.txt.*' -File -ErrorAction SilentlyContinue) } } catch {}
    }
    if (@($cands).Count -lt 1) { return $null }
    return (@($cands | Sort-Object LastWriteTime -Descending)[0])
}

$reportFile = Join-Path $ScriptDir 'artifacts\radialpat_probe_report.txt'
$reportDir = Split-Path -Parent $reportFile; if ($reportDir -and -not (Test-Path $reportDir)) { New-Item -ItemType Directory -Force -Path $reportDir | Out-Null }
Rep ("RADIALPAT-PROBE report  model=$fname  when=" + (Get-Date).ToString('o')) 'Cyan'
Rep ""

try {

try { $session.SetConfigOption("dynamic_preview", "no") | Out-Null } catch {}

# ============================================================================
# SECTION A -- DRIVER CONFIRM (skipped with --record-only).
# ============================================================================
if (-not $recordOnly) {
    try { $session.SetConfigOption("visible_mapkeys", "no") | Out-Null } catch {}
    Rep "== [A] T0 ROOT-CAUSE DEMO -- the OLD split (open RunMacro #1 -> pick -> values RunMacro #2) ==" 'Cyan'
    Rep "   EXPECTED: the dashboard opens but the model does NOT change -- proving the split drops the confirm." 'DarkGray'
    Write-Host "  In Creo, SELECT the SEED feature to pattern (a chip-relief extrude/cut) in the model tree, then press ENTER." -ForegroundColor Cyan
    Read-Host
    $seedId = 0
    try { $seedId = [int](Read-SelectedId) } catch { $seedId = 0 }
    Rep ("  selected seed feature id = {0}" -f $seedId) $(if ($seedId -gt 0) {'Green'} else {'Yellow'})
    if ($seedId -le 0) {
        Rep "  No feature id read from the selection -- select the seed feature (not a body/surface) and re-run Section A." 'Yellow'
    } else {
        $cnt = Read-Host "  Instance COUNT (total, incl. the seed) [default 2]"
        if ([string]::IsNullOrWhiteSpace($cnt)) { $cnt = '2' }
        $inc = Read-Host "  Angular INCREMENT in degrees [default 90]"
        if ([string]::IsNullOrWhiteSpace($inc)) { $inc = '90' }
        $countN = 2; [void][int]::TryParse($cnt, [ref]$countN); if ($countN -lt 2) { $countN = 2 }
        $incD = 90.0; [void][double]::TryParse($inc, [ref]$incD)
        # baseline canary (id-only): a NEW feature must appear for a real pattern.
        $before0 = Get-FeatureIdSet
        $stamp0 = $null; try { $stamp0 = $model.VersionStamp } catch { $stamp0 = $null }
        # T0 fires the SPLIT deliberately -- this is the KNOWN-BROKEN path the driver no longer uses.
        if ($verbose) { Rep ("  open macro : " + (Build-RadialPatternOpenMacro)) 'DarkGray' }
        try { $session.RunMacro((Build-RadialPatternOpenMacro)) } catch { Rep ("  open macro error: $($_.Exception.Message)") 'Yellow' }
        Write-Host "  >>> RunMacro #1 fired (dashboard should be OPEN, type=Axis). In Creo, CLICK the rotation axis, then press ENTER. <<<" -ForegroundColor Cyan
        Read-Host | Out-Null
        if ($verbose) { Rep ("  values macro: " + (Build-RadialPatternValuesMacro -Count $countN -IncrementDeg $incD)) 'DarkGray' }
        try { $session.RunMacro((Build-RadialPatternValuesMacro -Count $countN -IncrementDeg $incD)) } catch { Rep ("  values macro error: $($_.Exception.Message)") 'Yellow' }
        $moved0 = $false
        if ($null -ne $stamp0) { try { $moved0 = Wait-ModelModified -Model $model -PreviousStamp $stamp0 -TimeoutMs 8000 } catch { $moved0 = $false } }
        $after0 = Get-FeatureIdSet
        $new0 = @($after0.Keys | Where-Object { -not $before0.ContainsKey($_) })
        Rep ("  split result: VersionStamp moved={0}  new features={1}" -f $moved0, @($new0).Count) $(if (@($new0).Count -ge 1) {'Yellow'} else {'Green'})
        if (@($new0).Count -ge 1) {
            Rep "  RESULT [A/T0]: the split UNEXPECTEDLY created a feature on this build -- context DID survive; re-examine the hypothesis." 'Yellow'
            Rep "  (Delete the throwaway pattern in Creo: select it -> Delete, or Ctrl-Z.)" 'DarkGray'
        } else {
            Rep "  RESULT [A/T0]: CONFIRMED -- the split opened the dashboard but created NOTHING (the confirm was dropped)." 'Green'
            Rep "  This is the live 'tried but did nothing' bug. The fix is the ONE-atomic-macro axis-by-id path (Section C)." 'Green'
            Rep "  (If a dashboard is still open in Creo, Cancel/Esc it before Section B.)" 'DarkGray'
        }
    }
    Rep ""
}

# ============================================================================
# SECTION B -- RECORDER for the user's axis-from-2-planes idea + the axis-collector feed.
# ============================================================================
Rep "== [B] RECORDER -- create a datum AXIS from 2 planes, then pattern using it ==" 'Cyan'
$trail0 = Find-NewestTrail
$mark0  = 0
if ($null -ne $trail0) { try { $mark0 = @(Get-Content -Path $trail0.FullName).Count } catch { $mark0 = 0 } }
Rep ("  trail before: {0} (lines={1})" -f $(if ($null -ne $trail0) { $trail0.Name } else { '(none yet)' }), $mark0) 'DarkGray'
try { $session.SetConfigOption("visible_mapkeys", "yes") | Out-Null } catch {}
Write-Host ""
Write-Host "  By HAND in Creo, do the user's axis-from-intersection workflow, then press ENTER:" -ForegroundColor Cyan
Write-Host "    1. Create a DATUM AXIS through the intersection of TWO datum planes (Datum > Axis, pick 2 planes)." -ForegroundColor Cyan
Write-Host "    2. Select your seed pocket feature, open Pattern, set type = Axis, and pick THAT new datum axis." -ForegroundColor Cyan
Write-Host "    3. Set a count + increment, OK. (You can delete the throwaway pattern + axis after.)" -ForegroundColor Cyan
Read-Host
$trail1 = Find-NewestTrail
$recipe = @()
if ($null -eq $trail1) {
    Rep "  No trail file found -- is visible_mapkeys writing a trail? (check working_folder\trail)" 'Yellow'
} else {
    $lines = @()
    try { $lines = @(Get-Content -Path $trail1.FullName) } catch {}
    # if the trail rolled to a new file, take it whole; else the tail since the mark.
    $slice = if ($trail1.FullName -eq ($trail0.FullName 2>$null)) { @($lines | Select-Object -Skip $mark0) } else { @($lines) }
    # keep widget/prompt lines; drop mouse/timer noise.
    $recipe = @($slice | Where-Object {
        $_ -match '^\s*~\s*(Command|Open|Close|Select|Update|Input|Activate|Trigger|FocusOut|Enter|Exit)\b' -or $_ -match '!%CP'
    })
    Rep ("  captured {0} widget/prompt lines from {1}" -f @($recipe).Count, $trail1.Name) 'Green'
    Rep "  --- look for: ProCmdDatumAxis (or the real axis command) + its plane refs + the ui_pat_type/ui_pat_axis feed ---" 'DarkGray'
    foreach ($ln in @($recipe | Select-Object -First 60)) { Rep ("    " + $ln.Trim()) 'DarkGray' }
}
$recipeFile = Join-Path $ScriptDir 'artifacts\radialpat_recipe.txt'
try { Set-Content -Path $recipeFile -Value (@($recipe) -join [Environment]::NewLine) -Encoding UTF8; Rep ("  recipe written: {0} (gitignored)" -f $recipeFile) 'Cyan' } catch { Rep ("  could not write recipe: $($_.Exception.Message)") 'Yellow' }
Rep ""

# ============================================================================
# SECTION C -- T3/T4 ATOMIC-FIX TEST. Runs only when both mined tokens are supplied
# (--axis-widget + --axis-seltype) AND a datum-axis feature id (--axis-id). Fires the NEW
# single-RunMacro Build-RadialPatternAtomicMacro via the driver -- no operator axis pick.
# ============================================================================
if ((-not [string]::IsNullOrWhiteSpace($axisWidget)) -and (-not [string]::IsNullOrWhiteSpace($axisSelTyp)) -and $axisIdArg -gt 0) {
    try { $session.SetConfigOption("visible_mapkeys", "no") | Out-Null } catch {}
    $global:RadialAxisCollectorWidget = $axisWidget
    $global:RadialAxisSelType         = $axisSelTyp
    $tag = if ($liveSeed) { 'T4 (operator tree-clicks the seed)' } else { 'T3 (raw-COM seed)' }
    Rep ("== [C] ATOMIC-FIX TEST -- {0}; axis-widget={1} seltype={2} axis-id={3} ==" -f $tag, $axisWidget, $axisSelTyp, $axisIdArg) 'Cyan'
    Rep ("  ready = {0}" -f (Test-RadialPatternReady)) $(if (Test-RadialPatternReady) {'Green'} else {'Yellow'})
    Write-Host "  In Creo, SELECT the SEED feature to pattern in the model tree, then press ENTER." -ForegroundColor Cyan
    Read-Host
    $seedC = 0; try { $seedC = [int](Read-SelectedId) } catch { $seedC = 0 }
    Rep ("  selected seed feature id = {0}" -f $seedC) $(if ($seedC -gt 0) {'Green'} else {'Yellow'})
    if ($seedC -gt 0) {
        $cntC = Read-Host "  Instance COUNT (total, incl. the seed) [default 4]"; if ([string]::IsNullOrWhiteSpace($cntC)) { $cntC = '4' }
        $incC = Read-Host "  Angular INCREMENT in degrees [default 90]"; if ([string]::IsNullOrWhiteSpace($incC)) { $incC = '90' }
        $cN = 4; [void][int]::TryParse($cntC, [ref]$cN); if ($cN -lt 2) { $cN = 2 }
        $iD = 90.0; [void][double]::TryParse($incC, [ref]$iD)
        if ($verbose) { Rep ("  atomic macro: " + [string](Build-RadialPatternAtomicMacro -AxisFeatId $axisIdArg -Count $cN -IncrementDeg $iD)) 'DarkGray' }
        $resC = if ($liveSeed) {
            Invoke-CurvedReliefRadialPattern -Session $session -Model $model -TypeObj $pfcType -SeedFeatId $seedC -Count $cN -IncrementDeg $iD -AxisFeatId $axisIdArg -UseLiveSelection
        } else {
            Invoke-CurvedReliefRadialPattern -Session $session -Model $model -TypeObj $pfcType -SeedFeatId $seedC -Count $cN -IncrementDeg $iD -AxisFeatId $axisIdArg
        }
        $patC = $false; try { $patC = [bool]$resC.Patterned } catch {}
        Rep ("  ViaAxisId={0}  Patterned={1}  NewFeatures={2}  Reason: {3}" -f ([bool]$resC.ViaAxisId), $patC, [int]$resC.NewFeatures, [string]$resC.Reason) $(if ($patC) {'Green'} else {'Yellow'})
        if ($patC) {
            Rep ("  RESULT [C]: SUCCESS -- the ATOMIC by-id macro created the pattern ({0}). The fix works; wire it in the GUI." -f $tag) 'Green'
            Rep "  (Delete the throwaway pattern in Creo.) Next: paste the tokens into curved_relief.ps1's globals + populate RadialAxisFeatId." 'DarkGray'
        } else {
            Rep ("  RESULT [C]: NO PATTERN with {0} -- if T3 failed, try --live-seed (T4). If both fail, the axis collector may reject" -f $tag) 'Yellow'
            Rep "             a by-id feed (need a different SelOptionRadio / channel) -- re-check Section B's recipe." 'Yellow'
        }
    }
    $global:RadialAxisCollectorWidget = $null; $global:RadialAxisSelType = $null
    Rep ""
} else {
    Rep "== [C] ATOMIC-FIX TEST -- SKIPPED (supply --axis-widget <w> --axis-seltype <t> --axis-id <n> from Section B's recipe) ==" 'DarkGray'
    Rep ""
}

Rep "== VERDICT ==" 'Cyan'
Rep "[A/T0] NOTHING created => CONFIRMS the split drops the confirm (the live no-op). This is expected." 'Gray'
Rep "[B] => open radialpat_recipe.txt: find the AXIS-collector ARM widget (the ui_pat_dir_dir1 analog) + the" 'Gray'
Rep "    ProCmdMdlTreeSearch SelOptionRadio value for a datum AXIS. Paste both into curved_relief.ps1:" 'Gray'
Rep "    \$global:RadialAxisCollectorWidget / \$global:RadialAxisSelType (or pass them to Section C to test first)." 'Gray'
Rep "[C] SUCCESS => the atomic by-id fix works; set the two globals as defaults + populate \$ctx.RadialAxisFeatId" 'Gray'
Rep "    (build/resolve a datum axis for the cylinder) so the GUI radial path lights up. Keep the per-fastener fallback." 'Gray'

}
finally {
    try { if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null } } catch {}
    try { if ($null -ne $origDynamicPreview) { $session.SetConfigOption("dynamic_preview", $origDynamicPreview) | Out-Null } } catch {}
    try {
        Set-Content -Path $reportFile -Value ($script:report -join [Environment]::NewLine) -Encoding UTF8
        Write-Host ""
        Write-Host ("  Report written: $reportFile") -ForegroundColor Cyan
        Write-Host "  (radialpat_probe_report.txt + radialpat_recipe.txt are gitignored -- probe artifacts are not committed.)" -ForegroundColor DarkGray
    } catch { Write-Host ("  Could not write report: $($_.Exception.Message)") -ForegroundColor Yellow }
    try { $connection.Disconnect($null) } catch {}
    [System.GC]::Collect(); [System.GC]::WaitForPendingFinalizers()
}

Write-Host ""
Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
