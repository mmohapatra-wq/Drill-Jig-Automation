# ============================================================================
# lib\tests\run_csys_tests.ps1 - offline unit tests for the csysinator reads
# ============================================================================
# Runs WITHOUT Creo and WITHOUT network. Exercises:
#  (1) the pure descriptor-read helpers in lib\creo_geometry.ps1:
#      - Get-EdgeArcCenter    (round edge -> center + radius; straight/unreadable
#                              degrade to IsRound=$false, never throw)
#      - Read-CoordSysTransform (IpfcCoordSystem.CoordSys -> origin + axes; null
#                              when the read is unavailable, never throw)
#  (2) the pure csysinator.cmd csys macro segments, AST-extracted from the .cmd
#      (the repo already AST-loads a .cmd in run_wizard_tests.ps1) so the mapkey-
#      faithful token structure is LOCKED against silent drift:
#      - Get-CsysOpenMacro / Get-CsysDir1Macro / Get-CsysFinishMacro
# COM objects are stubbed with pscustomobjects exposing the same member NAMES the
# real IpfcArc/CircleDescriptor / IpfcCoordSystem / IpfcTransform3D / model expose.
# Mirrors run_index_frame_tests.ps1 / run_tests.ps1 harness style.
#
# Run:  powershell -ExecutionPolicy Bypass -File lib\tests\run_csys_tests.ps1
# Exit code 0 = all passed, 1 = at least one failure.
# ============================================================================

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here
$repoDir = Split-Path -Parent $libDir
. (Join-Path $libDir 'creo_geometry.ps1')

# AST-extract the PURE csysinator.cmd helpers into this scope (cannot dot-source the
# whole .cmd - its header would try to connect to Creo). Only pull the pure ones.
$csysCmd = Join-Path $repoDir 'csysinator.cmd'
if (Test-Path $csysCmd) {
    $wantFns = @('Get-CsysOpenMacro','Get-CsysDir1Macro','Get-CsysFinishMacro')
    $csysSrc = Get-Content -Raw -Encoding UTF8 $csysCmd
    $csysAst = [System.Management.Automation.Language.Parser]::ParseInput($csysSrc, [ref]$null, [ref]$null)
    $csysAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wantFns -contains $n.Name }, $true) |
        ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }
}

$script:pass = 0
$script:fail = 0

function Assert-True {
    param([string]$Name, [bool]$Cond, [string]$Detail = "")
    if ($Cond) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  [FAIL] $Name $Detail" -ForegroundColor Red
        $script:fail++
    }
}

function Approx {
    param([double]$A, [double]$B, [double]$Tol = 1e-9)
    return [Math]::Abs($A - $B) -le $Tol
}

# ----------------------------------------------------------------------------
# Stub builders - stand in for the COM objects Get-EdgeArcCenter /
# Read-CoordSysTransform read. A pscustomobject with the same member NAMES is
# enough because the helpers only touch .GetCurveDescriptor()/.Center/.Radius/.End1
# and .CoordSys/.GetOrigin()/.GetXAxis()/... - never a COM-only feature.
# ----------------------------------------------------------------------------

# An edge whose GetCurveDescriptor() returns an ARC descriptor (.Center + .Radius).
function New-StubArcEdge {
    param($Center, [double]$Radius)
    $desc = [pscustomobject]@{ Center = $Center; Radius = $Radius }
    return [pscustomobject]@{} |
        Add-Member -PassThru -MemberType ScriptMethod -Name GetCurveDescriptor -Value { $desc }.GetNewClosure()
}

# An edge whose descriptor is a straight LINE: has .End1, NO .Center.
function New-StubLineEdge {
    # .Center intentionally absent; .End1 present (a non-null marker object).
    $desc = [pscustomobject]@{ End1 = [pscustomobject]@{ x = 0.0 } }
    return [pscustomobject]@{} |
        Add-Member -PassThru -MemberType ScriptMethod -Name GetCurveDescriptor -Value { $desc }.GetNewClosure()
}

# An edge whose GetCurveDescriptor() THROWS (unreadable / foreign descriptor).
function New-StubThrowingEdge {
    return [pscustomobject]@{} |
        Add-Member -PassThru -MemberType ScriptMethod -Name GetCurveDescriptor -Value { throw "no descriptor" }
}

# A coordinate system whose .CoordSys transform exposes GetOrigin/GetXAxis/etc.
function New-StubCsys {
    param($Origin, $X, $Y, $Z)
    $xf = [pscustomobject]@{} |
        Add-Member -PassThru -MemberType ScriptMethod -Name GetOrigin -Value { $Origin }.GetNewClosure() |
        Add-Member -PassThru -MemberType ScriptMethod -Name GetXAxis  -Value { $X }.GetNewClosure() |
        Add-Member -PassThru -MemberType ScriptMethod -Name GetYAxis  -Value { $Y }.GetNewClosure() |
        Add-Member -PassThru -MemberType ScriptMethod -Name GetZAxis  -Value { $Z }.GetNewClosure()
    return [pscustomobject]@{ CoordSys = $xf }
}

Write-Host ""
Write-Host "  Running csysinator read-helper unit tests (offline)..." -ForegroundColor Cyan
Write-Host ""

# ----------------------------------------------------------------------------
# Get-EdgeArcCenter
# ----------------------------------------------------------------------------
Write-Host "  -- Get-EdgeArcCenter --" -ForegroundColor White

# round arc edge -> center + radius extracted, IsRound
$arc = New-StubArcEdge -Center @(2.0, 3.0, -1.5) -Radius 0.25
$r = Get-EdgeArcCenter -Edge $arc
Assert-True "arc: IsRound"        ($r.IsRound)
Assert-True "arc: Kind=arc"       ($r.Kind -eq 'arc')
Assert-True "arc: center read"    ($null -ne $r.Center -and (Approx $r.Center[0] 2.0) -and (Approx $r.Center[1] 3.0) -and (Approx $r.Center[2] -1.5))
Assert-True "arc: radius read"    (Approx $r.Radius 0.25)

# straight line edge -> rejected as straight, no center, no throw
$line = New-StubLineEdge
$rl = Get-EdgeArcCenter -Edge $line
Assert-True "line: not round"     (-not $rl.IsRound)
Assert-True "line: Kind=straight" ($rl.Kind -eq 'straight')
Assert-True "line: no center"     ($null -eq $rl.Center)

# throwing descriptor -> IsRound=$false, Kind=no-descriptor, no throw
$thrown = $false
try { $rt = Get-EdgeArcCenter -Edge (New-StubThrowingEdge) } catch { $thrown = $true }
Assert-True "throwing edge: no throw"          (-not $thrown)
Assert-True "throwing edge: not round"         (-not $rt.IsRound)
Assert-True "throwing edge: Kind=no-descriptor" ($rt.Kind -eq 'no-descriptor')

# $null edge -> benign 'none'
$rn = Get-EdgeArcCenter -Edge $null
Assert-True "null edge: not round"  (-not $rn.IsRound)
Assert-True "null edge: Kind=none"  ($rn.Kind -eq 'none')

# arc with unreadable radius still yields the center (radius best-effort)
$arcNoR = [pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptMethod -Name GetCurveDescriptor -Value {
    [pscustomobject]@{ Center = @(1.0, 1.0, 1.0) }   # no Radius member
}
$rnr = Get-EdgeArcCenter -Edge $arcNoR
Assert-True "arc-no-radius: IsRound"     ($rnr.IsRound)
Assert-True "arc-no-radius: center read" ($null -ne $rnr.Center -and (Approx $rnr.Center[0] 1.0))

# CIRCULAR edge whose .Center is UNREADABLE on this build (has Radius, no Center,
# no straight-edge .End1) -> must still be ROUND so creation proceeds; center null
# so the caller degrades to visual verification. This locks in the honesty-bar fix:
# "is it round" must NOT be conflated with "could I read the center".
$arcNoCenter = [pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptMethod -Name GetCurveDescriptor -Value {
    [pscustomobject]@{ Radius = 0.5 }   # radius only: no Center, no End1
}
$rnc = Get-EdgeArcCenter -Edge $arcNoCenter
Assert-True "arc-no-center: IsRound (creation not blocked)" ($rnc.IsRound)
Assert-True "arc-no-center: Kind=arc-no-center"             ($rnc.Kind -eq 'arc-no-center')
Assert-True "arc-no-center: center is null (verify visually)" ($null -eq $rnc.Center)
Assert-True "arc-no-center: radius still read"              (Approx $rnc.Radius 0.5)

# fully unreadable descriptor (no Center, no Radius, no End1) -> NOT round, benign
$blank = [pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptMethod -Name GetCurveDescriptor -Value {
    [pscustomobject]@{}   # nothing readable
}
$rbl = Get-EdgeArcCenter -Edge $blank
Assert-True "blank descriptor: not round"           (-not $rbl.IsRound)
Assert-True "blank descriptor: Kind=no-descriptor"  ($rbl.Kind -eq 'no-descriptor')

# ----------------------------------------------------------------------------
# Read-CoordSysTransform
# ----------------------------------------------------------------------------
Write-Host "  -- Read-CoordSysTransform --" -ForegroundColor White

$cs = New-StubCsys -Origin @(5.0, 6.0, 7.0) -X @(1.0,0.0,0.0) -Y @(0.0,1.0,0.0) -Z @(0.0,0.0,1.0)
$t = Read-CoordSysTransform -Csys $cs
Assert-True "csys: transform read"  ($null -ne $t)
Assert-True "csys: origin"          ($null -ne $t -and (Approx $t.Origin[0] 5.0) -and (Approx $t.Origin[1] 6.0) -and (Approx $t.Origin[2] 7.0))
Assert-True "csys: +X"              ($null -ne $t -and (Approx $t.X[0] 1.0))
Assert-True "csys: +Z"              ($null -ne $t -and (Approx $t.Z[2] 1.0))

# $null csys -> $null, no throw
$thrown2 = $false
try { $tn = Read-CoordSysTransform -Csys $null } catch { $thrown2 = $true }
Assert-True "null csys: no throw"   (-not $thrown2)
Assert-True "null csys: null result" ($null -eq $tn)

# csys whose .CoordSys throws -> $null, no throw
$badCs = [pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptProperty -Name CoordSys -Value { throw "unavailable" }
$thrown3 = $false
try { $tb = Read-CoordSysTransform -Csys $badCs } catch { $thrown3 = $true }
Assert-True "throwing csys: no throw"    (-not $thrown3)
Assert-True "throwing csys: null result" ($null -eq $tb)

# csys with an unreadable origin (GetOrigin returns null) -> $null (origin required)
$csNoOrigin = New-StubCsys -Origin $null -X @(1.0,0.0,0.0) -Y @(0.0,1.0,0.0) -Z @(0.0,0.0,1.0)
$tno = Read-CoordSysTransform -Csys $csNoOrigin
Assert-True "csys-no-origin: null result" ($null -eq $tno)

# origin reads fine but an AXIS read THROWS -> origin still returned, that axis null
# (axes are best-effort, each in its own try/catch; a bad axis must not lose origin)
$xfBadZ = [pscustomobject]@{} |
    Add-Member -PassThru -MemberType ScriptMethod -Name GetOrigin -Value { @(9.0, 8.0, 7.0) } |
    Add-Member -PassThru -MemberType ScriptMethod -Name GetXAxis  -Value { @(1.0, 0.0, 0.0) } |
    Add-Member -PassThru -MemberType ScriptMethod -Name GetYAxis  -Value { @(0.0, 1.0, 0.0) } |
    Add-Member -PassThru -MemberType ScriptMethod -Name GetZAxis  -Value { throw "axis unavailable" }
$csBadZ = [pscustomobject]@{ CoordSys = $xfBadZ }
$thrown4 = $false
try { $tbz = Read-CoordSysTransform -Csys $csBadZ } catch { $thrown4 = $true }
Assert-True "throwing-axis: no throw"        (-not $thrown4)
Assert-True "throwing-axis: origin survived" ($null -ne $tbz -and (Approx $tbz.Origin[0] 9.0) -and (Approx $tbz.Origin[2] 7.0))
Assert-True "throwing-axis: bad Z is null"   ($null -ne $tbz -and $null -eq $tbz.Z)
Assert-True "throwing-axis: good X kept"     ($null -ne $tbz -and (Approx $tbz.X[0] 1.0))

# ----------------------------------------------------------------------------
# csysinator.cmd csys macro segments (AST-extracted above) - lock the token
# structure of the mapkey-faithful replay against silent drift.
# ----------------------------------------------------------------------------
Write-Host "  -- csysinator csys macro segments --" -ForegroundColor White

if ((Get-Command Get-CsysOpenMacro -ErrorAction SilentlyContinue) -and
    (Get-Command Get-CsysDir1Macro -ErrorAction SilentlyContinue) -and
    (Get-Command Get-CsysFinishMacro -ErrorAction SilentlyContinue)) {

    # Macro A: open + prime origin collector + tab toggle (ends on Placement tab tab_1).
    $mA = Get-CsysOpenMacro
    Assert-True "A: opens ProCmdDatumCsys"       ($mA.Contains('~ Command `ProCmdDatumCsys`'))
    Assert-True "A: primes origin collector"     ($mA.Contains('t1.OriginPlacement'))
    Assert-True "A: leaves Placement tab active" ($mA.Contains('pg_vis_tab` 1 `tab_1`'))
    Assert-True "A: does NOT fire OK"            (-not $mA.Contains('stdbtn_1'))

    # Macro B: orient tab; origin's direction -> Axis_Y + flip; prime DirectionTable2.
    $mB = Get-CsysDir1Macro
    Assert-True "B: switches to orientation tab" ($mB.Contains('pg_vis_tab` 1 `tab_2`'))
    Assert-True "B: DirectionTable1 (origin dir)" ($mB.Contains('t2.DirectionTable1'))
    Assert-True "B: AxisMenu1 = Axis_Y"          ($mB.Contains('t2.AxisMenu1` 1 `Axis_Y`'))
    Assert-True "B: flips Y (FlipBtn1)"          ($mB.Contains('t2.FlipBtn1'))
    Assert-True "B: primes DirectionTable2 for X pick" ($mB.Contains('t2.DirectionTable2'))
    Assert-True "B: no Axis_X / AxisMenu2 (implicit X)" (-not ($mB.Contains('Axis_X') -or $mB.Contains('AxisMenu2')))
    Assert-True "B: does NOT fire OK"            (-not $mB.Contains('stdbtn_1'))

    # Macro C: flip the 2nd direction; OK only with -WithOK.
    $mCprobe = Get-CsysFinishMacro
    $mCok    = Get-CsysFinishMacro -WithOK
    Assert-True "C: flips X (FlipBtn2)"          ($mCprobe.Contains('t2.FlipBtn2'))
    Assert-True "C: probe form does NOT OK"      (-not $mCprobe.Contains('stdbtn_1'))
    Assert-True "C: -WithOK fires stdbtn_1"      ($mCok.Contains('~ Activate `Odui_Dlg_00` `stdbtn_1`'))
} else {
    Assert-True "csys macro segments extracted from csysinator.cmd" $false "one or more functions not found (AST extract failed)"
}

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host ("  csys tests: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
Write-Host ""
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
