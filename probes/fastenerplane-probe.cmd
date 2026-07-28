<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir=((Split-Path -Parent ('%~dp0'.TrimEnd('\')))+'\'); $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "FASTENERPLANE-PROBE"
$ErrorActionPreference = "Stop"

# ============================================================================
# FASTENERPLANE-PROBE -- settle, LIVE, exactly what a TREE-SELECTED fastener-
# component datum plane looks like in the selection buffer, and whether that
# selection builds the intersection datum point.
# ============================================================================
# WHY: the curved-jig GUI fastener loop could not register the fastener planes.
# The live trail (working_folder\trail\trail.txt.15) PROVES that operator TREE-
# node selects (Select PHTLeft.AssyTree 3 T3 6 0 T3 6 1 T3 6 2) DO build a point
# via ProCmdDatumPointGeneral + stdbtn_1 -- yet the tool's reader
# (Resolve-SelectedPlaneIds) counted 0, because it only accepted items whose
# Type == ITEM_SURFACE. This probe DUMPS the ground truth for each selected item
# so we stop guessing:
#   * Id / Type (int + name) / GetName / Path.ComponentIds / SelectionString
# so we KNOW whether a tree-selected component plane reports as ITEM_SURFACE,
# some other type, and whether it carries an owning-component Path.
#
# Then (unless --no-point) it fires the SAME point recipe the trail used
# (ProCmdDatumPointGeneral + stdbtn_1) with an ITEM_POINT diff canary, so we
# confirm the selection the operator just made actually intersects to a point.
#
# ID-ONLY: reads SelItem.Id / .Type / .GetName / .Path only; NEVER IpfcPoint.Point.
# MUTATES (one throwaway datum point unless --no-point) behind a y/N + canary.
# ASSEMBLY required (the fastener component planes only exist in the .asm).
# Writes artifacts\fastenerplane_probe_report.txt (gitignored). ONE Creo session.
#
# FLAGS:
#   --no-point   dump the buffer only; do NOT create a datum point.
#   -v           verbose (print each macro before firing).
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
$noPoint = $argStr -match '(?i)--no-point'
$verbose = $argStr -match '(?i)(^|\s)(-v|--verbose)(\s|$)'

Write-Host ""
Write-Host "  FASTENERPLANE-PROBE -- what does a tree-selected fastener plane look like?" -ForegroundColor Cyan
Write-Host "  Dumps the selection buffer (ID-only)$(if ($noPoint) { '' } else { ' + builds one throwaway point' }). NEVER reads IpfcPoint.Point." -ForegroundColor DarkGray
Write-Host ""

# ============================================================================
# SHARED LIBRARY
# ============================================================================
. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')   # Get-Comp
. (Join-Path $ScriptDir 'lib\drilljig_core.ps1')    # Initialize-DrilljigCore, Get-FeatureIdSet, Wait-ModelModified, Resolve-PlaneRole
. (Join-Path $ScriptDir 'lib\conformal_blank.ps1')      # (dep of curved_fastener_hole)
. (Join-Path $ScriptDir 'lib\curved_fastener_hole.ps1') # Add-ComponentDefaultPlanesToBuffer, Get-ComSelectFactory (SECTION 3 by-ID test)

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
if ($null -eq $model) { throw "No active model. Open the top-down ASSEMBLY (curved surface + fasteners + drilljig)." }

$fname = try { [string]$model.FileName } catch { "" }
if ($fname -notmatch '(?i)\.asm(\.\d+)?$') {
    Write-Host ""
    Write-Host "  NOTE: the active model is NOT an assembly ($fname)." -ForegroundColor Yellow
    Write-Host "  The fastener-component planes live in the .asm. If you ACTIVATED the drilljig" -ForegroundColor Yellow
    Write-Host "  PART inside the assembly, GetActiveModel() returns the .prt -- that is fine, the" -ForegroundColor Yellow
    Write-Host "  planes are still selectable as external refs. Proceeding." -ForegroundColor Yellow
    Write-Host ""
}

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

# ID-ONLY datum-point set (never .Point).
function Get-PointIdSetLocal {
    $set = @{}
    try { foreach ($p in @($model.ListItems($pfcType.ITEM_POINT))) { try { $set[[int]$p.Id] = $true } catch {} } } catch {}
    return $set
}

$reportFile = Join-Path $ScriptDir 'artifacts\fastenerplane_probe_report.txt'
$reportDir = Split-Path -Parent $reportFile; if ($reportDir -and -not (Test-Path $reportDir)) { New-Item -ItemType Directory -Force -Path $reportDir | Out-Null }
Rep ("FASTENERPLANE-PROBE report  model=$fname  no-point=$noPoint  when=" + (Get-Date).ToString('o')) 'Cyan'
Rep ""

try {

try { $session.SetConfigOption("visible_mapkeys", "no") | Out-Null; $session.SetConfigOption("dynamic_preview", "no") | Out-Null } catch {}

# ============================================================================
# SECTION 0 -- MAKE THE DRILLJIG PART ACTIVE (the gate the GUI's shell guards, and
# the step the operator's WORKING trail did that the earlier probe run MISSED).
# ProCmdDatumPointGeneral only builds the intersection point when the DRILLJIG PART
# is active (the fastener planes are external references); a run with the ASSEMBLY
# active MISSES. If the active model is an .asm, have the operator select the
# drilljig PART node and fire ProCmdMakeActive, then re-read.
# ============================================================================
$activeNow = ''
try { $am0 = $session.GetActiveModel(); if ($null -ne $am0) { $activeNow = [string]$am0.FileName } } catch {}
Rep ("== [0] ACTIVE MODEL == {0}" -f $activeNow) $(if ($activeNow -match '(?i)\.asm(\.\d+)?$') {'Yellow'} else {'Green'})
if ($activeNow -match '(?i)\.asm(\.\d+)?$') {
    Rep "  The ACTIVE model is the ASSEMBLY -- the point will MISS here (this was the earlier" 'Yellow'
    Rep "  probe's false-miss). In Creo, select the DRILLJIG PART node in the tree, then press ENTER;" 'Yellow'
    Rep "  the probe fires ProCmdMakeActive so the point can land in the jig." 'Yellow'
    Read-Host
    try { $session.RunMacro("~ Command ``ProCmdMakeActive@PopupMenuTree``;"); Rep "  fired ProCmdMakeActive on the selected node." 'DarkGray' } catch { Rep ("  ProCmdMakeActive error: $($_.Exception.Message)") 'Red' }
    $activeNow = ''
    try { $am0 = $session.GetActiveModel(); if ($null -ne $am0) { $activeNow = [string]$am0.FileName } } catch {}
    Rep ("  Active model after ProCmdMakeActive: {0}" -f $activeNow) $(if ($activeNow -match '(?i)\.asm(\.\d+)?$') {'Yellow'} else {'Green'})
}
Rep ""

# ============================================================================
# SECTION 1 -- DUMP THE BUFFER for a tree-selected fastener's 3 planes
# ============================================================================
Write-Host "  In Creo, select ONE fastener's THREE datum planes (TOP + SIDE + FRONT) in the" -ForegroundColor Cyan
Write-Host "  MODEL TREE (Ctrl-click all three) -- the SAME way you did it manually. Then press" -ForegroundColor Cyan
Write-Host "  ENTER here. (Answer in THIS console; do not click again in Creo or the selection clears.)" -ForegroundColor Cyan
Read-Host

$buf = @()
try { $buf = @(($session.CurrentSelectionBuffer()).Contents) } catch {}
Rep ("== [1] SELECTION BUFFER (Id / Type-int / Type-name / GetName / role / Path.ComponentIds / SelectionString) ==") 'Cyan'
Rep ("Buffer holds {0} item(s)." -f $buf.Count) $(if ($buf.Count -ge 3) {'Green'} else {'Yellow'})

$surfType = -1
try { $surfType = [int]$pfcType.ITEM_SURFACE } catch {}
Rep ("(for reference: ITEM_SURFACE = {0})" -f $surfType) 'DarkGray'

$typeHisto = @{}
$roleSeen  = @{}
$idx = 0
foreach ($sel in $buf) {
    $idx++
    $si = $null
    try { $si = $sel.SelItem } catch {}
    if ($null -eq $si) { Rep ("  [{0}] (no SelItem)" -f $idx) 'DarkGray'; continue }
    $id = 0;  try { $id = [int]$si.Id } catch {}
    $tyI = -1; try { $tyI = [int]$si.Type } catch {}
    $tyN = "?"; try { $tyN = [string]$si.Type } catch {}
    $nm = "";  try { $nm = [string]$si.GetName() } catch {}
    $role = $null; try { $role = Resolve-PlaneRole -Name $nm } catch {}
    if ($null -ne $role) { $roleSeen[$role] = $true }
    $typeHisto[[string]$tyI] = ([int]$typeHisto[[string]$tyI] + 1)
    $pathKey = ""
    try { $path = $sel.Path; if ($null -ne $path) { $ids = $path.ComponentIds; if ($null -ne $ids -and $ids.Count -gt 0) { $pathKey = ($ids -join '|') } } } catch {}
    $ss = ""; try { $ss = [string]$sel.SelectionString } catch {}
    $isSurf = ($tyI -eq $surfType)
    $roleTxt = if ($null -ne $role) { $role.ToUpper() } else { "(unclassified)" }
    Rep ("  [{0}] id={1}  type={2}({3}){4}  name='{5}'  role={6}  path={7}  ss={8}" -f `
        $idx, $id, $tyI, $tyN, $(if ($isSurf) { '=SURFACE' } else { '' }), $nm, $roleTxt, $(if ($pathKey) { $pathKey } else { '(none)' }), $ss) `
        $(if ($null -ne $role) {'Green'} else {'Yellow'})
}
Rep ""
Rep ("Type histogram (Type-int -> count): {0}" -f (($typeHisto.GetEnumerator() | ForEach-Object { "$($_.Key):$($_.Value)" }) -join '  ')) 'White'
$surfCount = [int]$typeHisto[[string]$surfType]
Rep ("Items reading as ITEM_SURFACE ({0}): {1} of {2}." -f $surfType, $surfCount, $buf.Count) $(if ($surfCount -eq $buf.Count -and $buf.Count -ge 3) {'Green'} else {'Yellow'})
if ($surfCount -lt $buf.Count) {
    Rep "  -> KEY FINDING: at least one selected plane does NOT report as ITEM_SURFACE." 'Yellow'
    Rep "     The old Resolve-SelectedPlaneIds (SURFACE-only) would have UNDERCOUNTED this" 'Yellow'
    Rep "     selection. The relaxed reader (count any distinct Id) is the correct fix; the" 'Yellow'
    Rep "     Type-int(s) above are the truth to encode if a tighter gate is ever wanted." 'Yellow'
}
$rolesTxt = (@('Top','Side','Front') | Where-Object { $roleSeen.ContainsKey($_) }) -join ', '
Rep ("Roles matched by name: {0}" -f $(if ($rolesTxt) { $rolesTxt } else { '(none -- names did not resolve to TOP/SIDE/FRONT)' })) $(if (@($roleSeen.Keys).Count -eq 3) {'Green'} else {'Yellow'})
Rep ""

if ($buf.Count -lt 3) {
    Rep ("Only {0} item(s) selected -- need the fastener's 3 datum planes. Re-run + tree-select all three." -f $buf.Count) 'Yellow'
    throw "Fewer than 3 items selected; nothing to intersect."
}

# ============================================================================
# SECTION 2 -- BUILD THE POINT (canary) from the operator's tree selection
# ============================================================================
if ($noPoint) {
    Rep "== [2] POINT -- SKIPPED (--no-point) ==" 'DarkGray'
} else {
    Write-Host "  (Answer in THIS console -- do NOT click in Creo, or the selection may clear.)" -ForegroundColor DarkGray
    $ans = Read-Host "  Fire ProCmdDatumPointGeneral + stdbtn_1 on this selection now? (y/N)"
    if ($ans -notmatch '^(?i)y') {
        Rep "Point creation declined by operator." 'Yellow'
    } else {
        Rep "== [2] BUILD DATUM POINT (ProCmdDatumPointGeneral + stdbtn_1) ==" 'Cyan'
        $nowBuf = 0; try { $nowBuf = @(($session.CurrentSelectionBuffer()).Contents).Count } catch {}
        if ($nowBuf -lt 3) {
            Rep ("Buffer now holds {0} item(s) (<3) -- it changed since section [1]. Re-run without clicking in Creo before the confirm." -f $nowBuf) 'Yellow'
            throw "Selection went stale; aborting to avoid a false miss."
        }
        $ptBefore = Get-PointIdSetLocal
        $stamp = $null; try { $stamp = [string]$model.VersionStamp } catch {}
        $macro = "~ Command ``ProCmdDatumPointGeneral``;~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;"
        if ($verbose) { Rep ("  macro: $macro") 'DarkGray' }
        try { $session.RunMacro($macro) } catch { Rep ("  RunMacro threw: $($_.Exception.Message)") 'Red' }
        $changed = $false
        if ($null -ne $stamp) { $changed = Wait-ModelModified -Model $model -PreviousStamp $stamp -TimeoutMs 30000 }
        $ptAfter = Get-PointIdSetLocal
        $newPts  = @($ptAfter.Keys | Where-Object { -not $ptBefore.ContainsKey($_) } | Sort-Object)
        # ROBUST canary: a new ITEM_POINT id (active model = the PART) OR a VersionStamp
        # move (active model = the ASSEMBLY, where ListItems(ITEM_POINT) returns 0 but the
        # point still lands in the drilljig part -- the first run's FALSE MISS was exactly this).
        if (@($newPts).Count -ge 1) {
            Rep ("POINT CREATED: {0} new datum-point id(s) -> id {1} (model changed={2})." -f @($newPts).Count, ([int]$newPts[-1]), $changed) 'Green'
            Rep "-> CONFIRMED: a TREE-selected fastener-component plane selection builds the point (id enumerable => part active)." 'Green'
        } elseif ($changed) {
            Rep "POINT CREATED (VersionStamp moved) but NO new ITEM_POINT id enumerated." 'Green'
            Rep "-> CONFIRMED + KEY FINDING: the point built, but ListItems(ITEM_POINT) is blind here" 'Green'
            Rep "   (active model is the ASSEMBLY; the point lands in the drilljig PART). The GUI point" 'Green'
            Rep "   canary MUST accept a VersionStamp move as success (Invoke-FastenerPoint does)." 'Green'
        } else {
            Rep "NO datum point evidence (no new id AND no VersionStamp change) - a real MISS." 'Yellow'
            Rep "  - If a dialog is still open in Creo, Cancel it. The 3 items may not be 3 mutually" 'Yellow'
            Rep "    intersecting planes, or the selection cleared. Re-check section [1]'s dump." 'Yellow'
        }
    }
}
Rep ""

# ============================================================================
# SECTION 3 -- BY-ID CHANNEL: does Add-ComponentDefaultPlanesToBuffer (constant
# feature ids 1/3/5, path-qualified) register the SAME 3 planes the manual pick did,
# and does the point then build? This is the hands-free path the GUI uses. Compare its
# buffer dump to section [1] byte-for-byte.
# ============================================================================
if ($noPoint) {
    Rep "== [3] BY-ID CHANNEL -- SKIPPED (--no-point) ==" 'DarkGray'
} else {
    Write-Host ""
    Write-Host "  SECTION 3 (by-ID): in Creo, select ONE fastener COMPONENT (the fastener itself in" -ForegroundColor Cyan
    Write-Host "  the tree, NOT its planes), then press ENTER. The probe resolves its 1/3/5 planes by" -ForegroundColor Cyan
    Write-Host "  ID + path and fires the point -- the exact hands-free path the GUI uses." -ForegroundColor Cyan
    Read-Host
    Rep "== [3] BY-ID PLANE SELECT (Add-ComponentDefaultPlanesToBuffer) ==" 'Cyan'
    # read the selected component's path
    $compPath = $null
    try {
        foreach ($sel in @(($session.CurrentSelectionBuffer()).Contents)) {
            $pp = $null; try { $pp = $sel.Path } catch {}
            if ($null -ne $pp) { $compPath = $pp; break }
        }
    } catch {}
    if ($null -eq $compPath) {
        Rep "  No component Path on the selection -- select the fastener COMPONENT (not a plane) and re-run section 3." 'Yellow'
    } else {
        $cids = ''; try { $cids = (@($compPath.ComponentIds) -join '|') } catch {}
        Rep ("  Selected fastener component path.ComponentIds = {0}" -f $(if ($cids) { $cids } else { '(none)' })) 'Gray'
        $byid = $null
        try { $byid = Add-ComponentDefaultPlanesToBuffer -Session $session -Model $model -TypeObj $pfcType -ComponentPath $compPath } catch { Rep ("  Add-ComponentDefaultPlanesToBuffer threw: $($_.Exception.Message)") 'Red' }
        if ($null -ne $byid) {
            $added = 0; try { $added = [int]$byid.Added } catch {}
            Rep ("  Add-ComponentDefaultPlanesToBuffer -> Added={0}  Roles={1}  Ids={2}  Reason={3}" -f $added, (@($byid.Roles) -join '/'), (@($byid.Ids) -join ','), [string]$byid.Reason) $(if ($added -ge 3) {'Green'} else {'Yellow'})
            # dump the resulting buffer (same per-item shape as section 1)
            $bbuf = @(); try { $bbuf = @(($session.CurrentSelectionBuffer()).Contents) } catch {}
            Rep ("  Buffer after by-ID select holds {0} item(s):" -f $bbuf.Count) $(if ($bbuf.Count -ge 3) {'Green'} else {'Yellow'})
            foreach ($b in $bbuf) {
                $bsi = $null; try { $bsi = $b.SelItem } catch {}
                if ($null -eq $bsi) { continue }
                $bid = 0; try { $bid = [int]$bsi.Id } catch {}
                $btn = ''; try { $btn = [string]$bsi.GetName() } catch {}
                $bpath = ''; try { $bp = $b.Path; if ($null -ne $bp) { $bpath = (@($bp.ComponentIds) -join '|') } } catch {}
                Rep ("    id={0}  name='{1}'  path={2}" -f $bid, $btn, $(if ($bpath) { $bpath } else { '(none)' })) 'Gray'
            }
            if ($added -ge 3) {
                $ptB = Get-PointIdSetLocal
                $stB = $null; try { $stB = [string]$model.VersionStamp } catch {}
                try { $session.RunMacro("~ Command ``ProCmdDatumPointGeneral``;~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;") } catch { Rep ("  point macro error: $($_.Exception.Message)") 'Red' }
                $chg = $false; if ($null -ne $stB) { $chg = Wait-ModelModified -Model $model -PreviousStamp $stB -TimeoutMs 30000 }
                $ptA = Get-PointIdSetLocal
                $np = @($ptA.Keys | Where-Object { -not $ptB.ContainsKey($_) })
                if (@($np).Count -ge 1 -or $chg) {
                    Rep ("  BY-ID POINT CREATED ({0}). -> the hands-free channel WORKS; wire it as primary." -f $(if (@($np).Count -ge 1) { "new id $([int]($np|Sort-Object)[-1])" } else { 'VersionStamp moved' })) 'Green'
                } else {
                    Rep "  BY-ID POINT MISS -- the path-qualified select put items in the buffer but the point did not build." 'Yellow'
                    Rep "  Compare this buffer dump to section [1]: if the items/paths differ, CreateModelItemSelection(plane,path) is the culprit." 'Yellow'
                }
            }
        }
    }
    Rep ""
}

# ============================================================================
# VERDICT
# ============================================================================
Rep "== VERDICT ==" 'Cyan'
Rep "Section [1]'s per-item Type-int + Path dump is the ground truth for how a tree-selected" 'Gray'
Rep "fastener-component datum plane registers on this build. If any item is NOT ITEM_SURFACE," 'Gray'
Rep "the relaxed Resolve-SelectedPlaneIds (count any distinct Id) is confirmed necessary; the" 'Gray'
Rep "point canary in section [2] is the real success gate for the GUI fastener loop." 'Gray'
if (-not $noPoint) { Rep "This probe created a throwaway datum point -- delete/Undo it in Creo." 'Yellow' }

}
finally {
    try { if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null } } catch {}
    try { if ($null -ne $origDynamicPreview) { $session.SetConfigOption("dynamic_preview", $origDynamicPreview) | Out-Null } } catch {}
    try {
        Set-Content -Path $reportFile -Value ($script:report -join [Environment]::NewLine) -Encoding UTF8
        Write-Host ""
        Write-Host ("  Report written: $reportFile") -ForegroundColor Cyan
        Write-Host "  (fastenerplane_probe_report.txt is gitignored -- probe reports are not committed.)" -ForegroundColor DarkGray
    } catch { Write-Host ("  Could not write report: $($_.Exception.Message)") -ForegroundColor Yellow }
    try { $connection.Disconnect($null) } catch {}
    [System.GC]::Collect(); [System.GC]::WaitForPendingFinalizers()
}

Write-Host ""
Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
