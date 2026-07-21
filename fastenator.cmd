<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "FASTENATOR (fastener -> hole-layout)"
$ErrorActionPreference = "Stop"

# ============================================================================
# FASTENATOR  -- read the fastener centers from the OPEN part, project them to a
#                2D (X,Z) hole layout, and write it to fastener_layout.json so the
#                drill-jig tools can build a jig whose holes match the fasteners.
# ============================================================================
# Piece 1 of the "import fastener layout" workflow (piece 2 = drilljig / drilljig-gui
# loading the file). The user has a part FULL of fasteners and wants the jig's holes
# at those same positions. This tool does the RISKY, COM-side half: read each
# fastener's center off the live model, then hand off the flat layout via a file.
#
# READ PATH: cylinder-axis (Get-CylinderAxes, descriptor.Origin.GetOrigin()) -- the
# ONLY proven non-crashing center read on this build (matrixinator uses it live; see
# fastener-probe.cmd, which confirms which read works). It reads the fastener BORES
# as cylinders and takes each bore's axis origin as the fastener center. It NEVER
# reads IpfcPoint.Point (that crashes -- the holeinator lesson). Optionally the
# operator can pre-SELECT the bores and we read only those (foreign-body-safe path).
#
# PROJECTION + HANDOFF: pure, in lib\fastener_layout.ps1 (offline-tested):
# ConvertTo-LayoutXZ (axis pick + corner-shift + stack dedup) ->
# Test-FastenerLayoutSane (honesty canary) -> Write-FastenerLayout.
#
# ASSEMBLY mode (--from-components, or auto when the active model is an .asm): the
# fasteners are assembly COMPONENTS, not bores in a part. ListItems(ITEM_COMPONENT)
# is empty on this build, so the operator SELECTS the fastener components and each
# location is IpfcComponentPath.GetTransform($true).GetOrigin() -- the member->root-
# assembly transform origin (VB docs: "current position ... in the root assembly"),
# read via the SAME IpfcTransform3D.GetOrigin() family proven for the csys read.
#
# FLAGS:
#   --from-components     ASSEMBLY mode: read SELECTED component locations via the
#                         component-path transform (auto-on when the model is .asm)
#   --selected            PART mode: read ONLY the pre-selected bores (else sweep)
#   --radius <r>          only cylinders at radius r (+/- tol); repeatable-ish via
#                         a comma list "--radius 0.125,0.25". Default: a sweep.
#   --radtol <t>          radius match tolerance (default 0.01)
#   --margin <m>          plate border added to every point (default = the median
#                         bore diameter, or 0.25 if unknown)
#   --deduptol <t>        merge points closer than t in the layout plane (default =
#                         the median bore diameter so bolt+nut stacks collapse)
#   --axis-x X|Y|Z        model axis -> layout X   (else prompted)
#   --axis-z X|Y|Z        model axis -> layout Z   (else prompted)
#   --flip-x / --flip-z   negate that axis (mirror fix, like drilljig --index-flip-x)
#   --out <path>          output file (default <repo>\fastener_layout.json)
#   --units inch|mm       record source units (else prompted)
#
# Standalone; touches no other tool. Open the FASTENER part/assembly; ONE session.
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

# ----------------------------------------------------------------------------
# flag parsing helpers
# ----------------------------------------------------------------------------
function Get-FlagValue { param([string]$Name) if ($ScriptArgs -match ("(?i)" + [regex]::Escape($Name) + "\s+([^\s]+)")) { return $Matches[1] } return $null }
function Has-Flag      { param([string]$Name) return ($ScriptArgs -match ("(?i)" + [regex]::Escape($Name) + "(\s|$)")) }

$optSelected = Has-Flag '--selected'
$optRadius   = Get-FlagValue '--radius'
$optRadTol   = Get-FlagValue '--radtol'
$optMargin   = Get-FlagValue '--margin'
$optDedup    = Get-FlagValue '--deduptol'
$optAxisX    = Get-FlagValue '--axis-x'
$optAxisZ    = Get-FlagValue '--axis-z'
$optFlipX    = Has-Flag '--flip-x'
$optFlipZ    = Has-Flag '--flip-z'
$optOut      = Get-FlagValue '--out'
$optUnits    = Get-FlagValue '--units'
$optFromComp = Has-Flag '--from-components'

# ----------------------------------------------------------------------------
# libs (pure projection + handoff; shared geometric reads)
# ----------------------------------------------------------------------------
. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')
. (Join-Path $ScriptDir 'lib\fastener_layout.ps1')

# ============================================
# HEADER
# ============================================
Write-Host ""
Write-Host "  FASTENATOR -- capture the open part's fastener centers as a jig hole layout" -ForegroundColor Cyan
Write-Host "  Reads cylinder bore axes (proven), projects to (X,Z), writes fastener_layout.json." -ForegroundColor DarkGray
Write-Host ""

# ============================================
# CONNECT (single session)
# ============================================
$procs = @(Get-Process -Name xtop -ErrorAction SilentlyContinue)
if ($procs.Count -eq 0) { throw "Creo (xtop.exe) is not running. Open Creo and the FASTENER part, then re-run." }
if ($procs.Count -gt 1) { throw "More than one Creo session is open. This tool expects exactly ONE." }
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
if ($null -eq $model) { throw "No active model. Open the FASTENER part (the one full of fasteners) first." }

$pfcType = New-Object -ComObject pfcls.pfcModelItemType
$fname = try { [string]$model.FileName } catch { "" }
$isAsm = ($fname -match '(?i)\.asm(\.\d+)?$')
Write-Host "  Connected. Active model: $fname" -ForegroundColor Green
if ($isAsm) {
    Write-Host ""
    Write-Host "  ASSEMBLY detected -> ASSEMBLY mode: SELECT the fastener components in Creo and" -ForegroundColor Cyan
    Write-Host "  their locations are read via the component-path transform (ListItems finds no" -ForegroundColor Cyan
    Write-Host "  components/bodies at the assembly top, so selection is the read path here)." -ForegroundColor Cyan
}
Write-Host ""

try {

# ============================================
# 1. READ the fastener bore centers (cylinder axes)
# ============================================
# Each fastener bore is a cylindrical surface; its axis ORIGIN is the center we want
# (projected to 2D later). Two modes: sweep the whole model, or read only selected bores.
$radTol = 0.01
if ($null -ne $optRadTol) { try { $radTol = [double]$optRadTol } catch {} }

# radii to look at: explicit list, or a broad sweep of common bushing/bolt bores.
$sweepRadii = @(0.0625, 0.086, 0.098, 0.1015, 0.125, 0.1285, 0.144, 0.1495, 0.166, 0.1875, 0.196, 0.201, 0.25, 0.3125, 0.375, 0.4375, 0.5)
if ($null -ne $optRadius) {
    $sweepRadii = @()
    foreach ($tok in ($optRadius -split ',')) { $v = $null; if ([double]::TryParse($tok.Trim(), [ref]$v)) { $sweepRadii += $v } }
    if ($sweepRadii.Count -eq 0) { throw "--radius given but no numeric value parsed from '$optRadius'." }
}

# collect { A=@(x,y,z); Radius } per bore, deduped by axis origin so the same
# cylinder read at two overlapping radii isn't counted twice.
$bores = @()
$seenAxis = @{}
function Add-Bore {
    param($A, $R)
    if ($null -eq $A) { return }
    $key = ('{0:0.###}|{1:0.###}|{2:0.###}' -f [double]$A[0], [double]$A[1], [double]$A[2])
    if ($seenAxis.ContainsKey($key)) { return }
    $seenAxis[$key] = $true
    $script:bores += [pscustomobject]@{ A = $A; Radius = [double]$R }
}

# ASSEMBLY mode reads component-path transform origins; PART mode reads bores.
# All three front-ends (this tool, drilljig.cmd option 4, drilljig-gui.cmd) share
# ONE reader -- Read-FastenerCentersFromModel (lib\creo_geometry.ps1) -- so the read
# never drifts. The ONLY case kept inline here is PART + --selected (read the
# operator's selected bore SURFACES rather than sweeping the whole part).
$asmMode = ($optFromComp -or $isAsm)
$centers = @()
$medianDia = 0.25

if (-not $asmMode -and $optSelected) {
    # ---- PART, --selected: read the SELECTED bore surfaces directly ----
    Write-Host "  PART mode: reading SELECTED bores from the selection buffer..." -ForegroundColor Cyan
    $buf = @()
    try { $buf = @(($session.CurrentSelectionBuffer()).Contents) } catch {}
    if ($buf.Count -eq 0) { throw "--selected given but the selection buffer is empty. Select the fastener bore surfaces in Creo, then re-run." }
    foreach ($sel in $buf) {
        $si = $null; try { $si = $sel.SelItem } catch {}
        if ($null -eq $si) { continue }
        $ax = $null; try { $ax = Get-CylinderAxisFromSurface -Surf $si } catch {}
        if ($null -ne $ax) { Add-Bore -A $ax.A -R $ax.Radius }
    }
    if ($bores.Count -eq 0) { throw "No cylindrical bores in the selection. Select the fastener bore SURFACES, then re-run." }
    $diams = @($bores | ForEach-Object { 2.0 * [double]$_.Radius } | Where-Object { $_ -gt 0 } | Sort-Object)
    $medianDia = if ($diams.Count -gt 0) { [double]$diams[[int]([math]::Floor($diams.Count / 2))] } else { 0.25 }
    $centers = @($bores | ForEach-Object { $_.A })
    Write-Host ("  Read {0} fastener bore center(s)." -f $centers.Count) -ForegroundColor Green
} else {
    if ($asmMode) {
        # ASSEMBLY: the SELECTION BUFFER is the read path -- prompt to select components first.
        Write-Host "  ASSEMBLY mode: reading SELECTED fastener component locations." -ForegroundColor Cyan
        $buf = @()
        try { $buf = @(($session.CurrentSelectionBuffer()).Contents) } catch {}
        if ($buf.Count -eq 0) {
            Write-Host "  Select the fastener COMPONENTS in Creo (Ctrl-click them in the tree or graphics)," -ForegroundColor Yellow
            Write-Host "  then return here and press ENTER." -ForegroundColor Yellow
            Read-Host "  Press ENTER once the fasteners are selected" | Out-Null
        }
    } else {
        Write-Host "  PART mode: sweeping the model for cylinder bores..." -ForegroundColor Cyan
    }
    $read = Read-FastenerCentersFromModel -Session $session -Model $model -TypeObj $pfcType -IsAsm $asmMode -Radii $sweepRadii -RadTol $radTol
    if (-not $read.Ok) {
        Write-Host ""
        Write-Host ("  {0}" -f $read.Message) -ForegroundColor Yellow
        Write-Host "  Try --selected / --radius (part), --from-components (assembly), or fastener-probe.cmd." -ForegroundColor Yellow
        throw "Nothing to lay out."
    }
    $centers = $read.Centers
    if ($read.MedianDia -gt 0) { $medianDia = $read.MedianDia; Write-Host ("  Median bore diameter ~ {0:0.####}" -f $medianDia) -ForegroundColor DarkGray }
    Write-Host ("  Read {0} fastener {1}." -f $centers.Count, $(if ($asmMode) { 'component location(s)' } else { 'bore center(s)' })) -ForegroundColor Green
}
Write-Host ""

# ============================================
# 2. AXIS MAPPING (which model axes -> layout X / Z) + margin/dedup/units
# ============================================
function Read-Axis {
    param([string]$Prompt, [string]$Default)
    while ($true) {
        $ans = Read-Host ("  $Prompt (X/Y/Z, default $Default)")
        if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
        $u = $ans.Trim().ToUpper()
        if (@('X','Y','Z') -contains $u) { return $u }
        Write-Host "    Enter X, Y, or Z." -ForegroundColor Yellow
    }
}

Write-Host "  Fastener centers are 3D; choose which two MODEL axes form the flat jig layout." -ForegroundColor Cyan
Write-Host "  (Layout X runs along the plate 'TOP' direction, layout Z along 'FRONT'. The third" -ForegroundColor DarkGray
Write-Host "   model axis is the through-thickness direction and is ignored.)" -ForegroundColor DarkGray
$axisX = if ($null -ne $optAxisX) { $optAxisX.Trim().ToUpper() } else { Read-Axis -Prompt "Model axis for layout X" -Default 'X' }
$axisZ = if ($null -ne $optAxisZ) { $optAxisZ.Trim().ToUpper() } else { Read-Axis -Prompt "Model axis for layout Z" -Default 'Z' }
$signX = if ($optFlipX) { -1.0 } else { 1.0 }
$signZ = if ($optFlipZ) { -1.0 } else { 1.0 }

$margin = $medianDia
if ($null -ne $optMargin) { try { $margin = [double]$optMargin } catch {} }
if ($margin -le 0) { $margin = 0.25 }

# Dedup default depends on the read: bolt+washer+nut BORES in a PART sit at the same
# (X,Z) but are separate cylinders -> merge at ~the bore dia. Assembly COMPONENTS are
# discrete instances; a bolt + its nut stack at the SAME (X,Z), but two DISTINCT
# fasteners spaced by their diameter must NOT merge -> a tight numeric-dup tol.
$dedup = if ($asmMode) { 1e-3 } else { $medianDia }
if ($null -ne $optDedup) { try { $dedup = [double]$optDedup } catch {} }
if ($dedup -lt 0) { $dedup = 0.0 }

$units = if ($null -ne $optUnits) { $optUnits.Trim().ToLower() } else {
    $u = Read-Host "  Source model length units (inch/mm, ENTER=unknown)"
    if ([string]::IsNullOrWhiteSpace($u)) { 'unknown' } else { $u.Trim().ToLower() }
}
Write-Host ""

# ============================================
# 3. PROJECT + CANARY
# ============================================
$layout = ConvertTo-LayoutXZ -Centers $centers -AxisX $axisX -AxisZ $axisZ -AxisXSign $signX -AxisZSign $signZ -Margin $margin -DedupTol $dedup
if (-not $layout.Valid) {
    Write-Host "  Could not build a valid layout:" -ForegroundColor Red
    foreach ($e in $layout.Errors) { Write-Host ("    - $e") -ForegroundColor Red }
    throw "Projection failed."
}

$sane = Test-FastenerLayoutSane -Layout $layout
if (-not $sane.Ok) {
    Write-Host "  SANITY CHECK FAILED -- the read likely returned bad coordinates, NOT writing the file:" -ForegroundColor Red
    foreach ($e in $sane.Errors) { Write-Host ("    - $e") -ForegroundColor Red }
    throw "Sanity canary refused the layout."
}

Write-Host ("  Layout: {0} hole(s) (merged {1} stack duplicate(s), skipped {2}), axes {3}/{4}, margin {5:0.###}." -f `
    $layout.Count, $layout.Dropped, $layout.Skipped, $axisX, $axisZ, $margin) -ForegroundColor Green
Write-Host ("  Projected extents (pre-shift): X span {0:0.###}, Z span {1:0.###}." -f $layout.SpanX, $layout.SpanZ) -ForegroundColor DarkGray
Write-Host "  Points (corner-relative X, Z):" -ForegroundColor White
$pi = 0
foreach ($p in $layout.Points) {
    if ($pi -ge 40) { Write-Host ("    ... ({0} more)" -f ($layout.Count - 40)) -ForegroundColor DarkGray; break }
    Write-Host ("    {0,3}: ({1:0.####}, {2:0.####})" -f ($pi + 1), [double]$p.X, [double]$p.Z) -ForegroundColor Gray
    $pi++
}
Write-Host ""

# ============================================
# 4. WRITE the handoff file
# ============================================
$outPath = if ($null -ne $optOut) { $optOut } else { Join-Path $ScriptDir 'fastener_layout.json' }
$whenIso = (Get-Date).ToString('o')
$readMethod = if ($asmMode) { 'component-path transform (selected components)' } elseif ($optSelected) { 'cylinder-axis (selected bores)' } else { 'cylinder-axis (model sweep)' }
$ok = Write-FastenerLayout -Path $outPath -Layout $layout -SourceModel $fname -Units $units -ReadMethod $readMethod -WhenIso $whenIso
if ($ok) {
    Write-Host ("  Wrote layout -> {0}" -f $outPath) -ForegroundColor Green
    Write-Host ""
    Write-Host "  NEXT: open the BLANK jig part in Creo, then run drilljig.cmd (point source option 4)" -ForegroundColor Cyan
    Write-Host "  or drilljig-gui.cmd (Layout > Import fastener layout) to build the jig at these holes." -ForegroundColor Cyan
    if ($units -ne 'unknown') { Write-Host ("  (Layout is in '$units' units -- make sure the jig part uses the same units.)") -ForegroundColor DarkGray }
} else {
    Write-Host ("  FAILED to write $outPath") -ForegroundColor Red
}

} finally {
    try { $connection.Disconnect($null) } catch {}
}

Write-Host ""
Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
