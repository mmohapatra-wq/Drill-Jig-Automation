# ============================================================================
# lib\tests\run_tangent_plane_tests.ps1 - offline unit tests for lib\tangent_plane.ps1
# ============================================================================
# Runs WITHOUT Creo and WITHOUT network. Exercises the CURVED-jig linchpin:
# a datum plane constrained TANGENT to a curved SURFACE AT a datum POINT (its
# normal == the surface normal there), which gives per hole both a real
# normal-to-surface DRILL reference AND the seed-sketch host for the chip-relief
# slot. Two published-contract entry points:
#
#   * Build-TangentPlaneMacro  - PURE string builder (no COM, never throws).
#     Emits the ONE atomic macro: select the SURFACE + the datum POINT by ID
#     (accumulated), ProCmdDatumPlane, the constraint TYPE = Tangent, then
#     stdbtn_1 (OK). -SurfaceFirst:$false swaps the ref order (surface after the
#     point instead of before). Tokens are copied VERBATIM from
#     docs\tangent_plane_at_point_on_surface.mapkey.txt.
#   * Invoke-TangentPlane      - COM orchestration, CANARY-GATED. Guards
#     PointId<=0 / SurfaceId<=0 (never touches Creo); fires the macro; a
#     no-VersionStamp-change is a MISS (Created=$false, never an assumed
#     success -- [[feedback_canary_must_not_assume_on_failure]]); a change +
#     a NEW feature id reports Created=$true + PlaneId=<the new id>. Reads the
#     $script:DJSession/DJModel/DJType scope set by Initialize-DrilljigCore, so
#     its guard/canary LOGIC is tested via STUBS (mirrors how
#     run_wizard_tests.ps1 stubs Invoke-SlotPatternFromSeed's COM).
#
# HARD REPO RULES honored here: pure builders NEVER throw; COM helpers read the
# core scope; a canary that can't be read is a MISS not success; ONE atomic
# RunMacro per dashboard; no Creo, no network, no IpfcPoint.Point. Modeled
# EXACTLY on lib\tests\run_curved_slots_tests.ps1 (Assert-True/Approx/Get-Field
# helpers, dot-source pattern, pass/fail counter, exit 0 on all-pass / 1 on any
# failure) with the COM-stub idiom from run_wizard_tests.ps1.
#
# Run:  powershell -ExecutionPolicy Bypass -File lib\tests\run_tangent_plane_tests.ps1
# Exit code 0 = all passed, 1 = at least one failure.
# ============================================================================

$ErrorActionPreference = "Stop"
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here

# tangent_plane.ps1 depends on drilljig_core.ps1 (Get-SelectByIdMacro,
# Initialize-DrilljigCore, Wait-ModelModified, Get-FeatureIdSet) which in turn
# needs a couple of pure helpers from creo_geometry / orthogrid at dot-source
# time. Load the same set the console/GUI tools load; none of these touch Creo.
# Guard optional deps so this file stays independently runnable.
foreach ($dep in @('creo_geometry.ps1', 'orthogrid.ps1', 'orthogrid_points.ps1')) {
    $p = Join-Path $libDir $dep
    if (Test-Path $p) { try { . $p } catch {} }
}
. (Join-Path $libDir 'drilljig_core.ps1')
. (Join-Path $libDir 'tangent_plane.ps1')

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

# Tolerant field getter: returns the value of the FIRST property that exists on
# $obj from the candidate name list, or $null if none. Works for both a hashtable
# (@{...}, what the COM orchestrator returns) and a [pscustomobject].
function Get-Field {
    param($Obj, [string[]]$Names)
    if ($null -eq $Obj) { return $null }
    foreach ($n in $Names) {
        if ($Obj -is [System.Collections.IDictionary]) {
            if ($Obj.Contains($n)) { return $Obj[$n] }
        } else {
            $prop = $Obj.PSObject.Properties[$n]
            if ($null -ne $prop) { return $prop.Value }
        }
    }
    return $null
}

# Index of the FIRST occurrence of $needle in $hay, or -1. Used to assert the
# relative ORDER of the two ref ids inside the built macro string.
function Index-Of {
    param([string]$Hay, [string]$Needle)
    return $Hay.IndexOf($Needle)
}

# Count how many times a literal token appears in a string.
function Count-Token {
    param([string]$Hay, [string]$Needle)
    if ([string]::IsNullOrEmpty($Hay) -or [string]::IsNullOrEmpty($Needle)) { return 0 }
    $n = 0; $i = 0
    while (($i = $Hay.IndexOf($Needle, $i)) -ge 0) { $n++; $i += $Needle.Length }
    return $n
}

Write-Host ""
Write-Host "  Running tangent-plane unit tests (offline)..." -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# Build-TangentPlaneMacro  --  PURE string builder, tested to the contract
# ============================================================================
Write-Host "  -- Build-TangentPlaneMacro (surface-first, default) --" -ForegroundColor White

$PID_POINT   = 4242
$ID_SURFACE  = 9191

$mSF = Build-TangentPlaneMacro -PointId $PID_POINT -SurfaceId $ID_SURFACE
Assert-True "macro: returns a non-empty string" ($mSF -is [string] -and $mSF.Length -gt 0)

# the load-bearing tokens from the recording MUST be present.
Assert-True "macro: contains ProCmdDatumPlane" ($mSF -match 'ProCmdDatumPlane')
Assert-True "macro: contains the Tangent constraint token" ($mSF -match 'Tangent')
Assert-True "macro: contains the constraint-type menu (constr_type1_OPTMENU1)" ($mSF -match 'constr_type1_OPTMENU1')
Assert-True "macro: contains stdbtn_1 (OK)" ($mSF -match 'stdbtn_1')

# BOTH reference ids must appear (surface + point fed by ID).
Assert-True "macro: contains the POINT id ($PID_POINT)" ($mSF -match "\b$PID_POINT\b")
Assert-True "macro: contains the SURFACE id ($ID_SURFACE)" ($mSF -match "\b$ID_SURFACE\b")

# it fires the plane command EXACTLY ONCE (one dashboard = one atomic macro).
Assert-True "macro: fires ProCmdDatumPlane exactly once" ((Count-Token $mSF '~ Command `ProCmdDatumPlane`;') -eq 1)
# and selects Tangent exactly once (no duplicated constraint set).
Assert-True "macro: selects Tangent exactly once" ((Count-Token $mSF '`Tangent`') -eq 1)
# and confirms exactly once.
Assert-True "macro: activates stdbtn_1 exactly once" ((Count-Token $mSF '`stdbtn_1`') -eq 1)

# surface-first (default): the SURFACE id appears BEFORE the POINT id.
$iSurf = Index-Of $mSF ([string]$ID_SURFACE)
$iPt   = Index-Of $mSF ([string]$PID_POINT)
Assert-True "macro (surface-first): surface id present in string" ($iSurf -ge 0)
Assert-True "macro (surface-first): point id present in string" ($iPt -ge 0)
Assert-True "macro (surface-first): SURFACE id appears BEFORE the POINT id" (($iSurf -ge 0) -and ($iPt -ge 0) -and ($iSurf -lt $iPt))

# the refs are accumulated: the buffer is cleared ONCE (the first ref), then the
# second is added with -NoClear (so exactly one buffer_clean in the select prefix).
Assert-True "macro (surface-first): buffer cleared exactly once (refs accumulate)" ((Count-Token $mSF 'buffer_clean') -eq 1)
# both refs go through the tree-search select-by-ID channel (two InputIDPanel rows).
Assert-True "macro (surface-first): two select-by-ID InputIDPanel feeds" ((Count-Token $mSF 'InputIDPanel') -eq 2)
# FIX 2026-07-27 (trail.txt.11): the surface MUST be fed as Surface GEOMETRY and
# the point as Point -- a Feature-typed face gave ProCmdDatumPlane no tangent-able
# reference, so the `Tangent` option never appeared and the dialog cancelled.
Assert-True "macro: surface fed as Surface type (not Feature)" ((Count-Token $mSF '`SelOptionRadio` 1 `Surface`') -eq 1)
Assert-True "macro: point fed as Point type" ((Count-Token $mSF '`SelOptionRadio` 1 `Point`') -eq 1)
Assert-True "macro: NEITHER ref fed as Feature (the pre-fix bug)" ((Count-Token $mSF '`SelOptionRadio` 1 `Feature`') -eq 0)
# the Tangent select comes AFTER the plane command (constraint set on the open dialog).
Assert-True "macro (surface-first): ProCmdDatumPlane precedes the Tangent select" ((Index-Of $mSF 'ProCmdDatumPlane') -lt (Index-Of $mSF '`Tangent`'))
# the plane command precedes stdbtn_1 (OK is last).
Assert-True "macro (surface-first): ProCmdDatumPlane precedes stdbtn_1 (OK)" ((Index-Of $mSF 'ProCmdDatumPlane') -lt (Index-Of $mSF 'stdbtn_1'))

# --------------------------------------------------------------------------
# -SurfaceFirst:$false  --  swaps the ref order (POINT id before SURFACE id)
# --------------------------------------------------------------------------
Write-Host "  -- Build-TangentPlaneMacro (-SurfaceFirst:`$false swaps ref order) --" -ForegroundColor White

$mPF = Build-TangentPlaneMacro -PointId $PID_POINT -SurfaceId $ID_SURFACE -SurfaceFirst $false
Assert-True "macro (point-first): returns a non-empty string" ($mPF -is [string] -and $mPF.Length -gt 0)
Assert-True "macro (point-first): still contains ProCmdDatumPlane" ($mPF -match 'ProCmdDatumPlane')
Assert-True "macro (point-first): still contains the Tangent token" ($mPF -match 'Tangent')
Assert-True "macro (point-first): still contains stdbtn_1" ($mPF -match 'stdbtn_1')
Assert-True "macro (point-first): still contains BOTH ids" (($mPF -match "\b$PID_POINT\b") -and ($mPF -match "\b$ID_SURFACE\b"))

# the ORDER is now reversed: POINT id BEFORE the SURFACE id.
$jPt   = Index-Of $mPF ([string]$PID_POINT)
$jSurf = Index-Of $mPF ([string]$ID_SURFACE)
Assert-True "macro (point-first): POINT id appears BEFORE the SURFACE id" (($jPt -ge 0) -and ($jSurf -ge 0) -and ($jPt -lt $jSurf))
# so the two orders are genuinely different strings.
Assert-True "macro: -SurfaceFirst toggle produces a DIFFERENT macro" ($mSF -ne $mPF)
# still one plane command, still one buffer_clean (the swap only reorders refs).
Assert-True "macro (point-first): fires ProCmdDatumPlane exactly once" ((Count-Token $mPF '~ Command `ProCmdDatumPlane`;') -eq 1)
Assert-True "macro (point-first): buffer cleared exactly once" ((Count-Token $mPF 'buffer_clean') -eq 1)

# -SurfaceFirst $true is byte-identical to the default.
$mSFexplicit = Build-TangentPlaneMacro -PointId $PID_POINT -SurfaceId $ID_SURFACE -SurfaceFirst $true
Assert-True "macro: explicit -SurfaceFirst `$true == default" ($mSFexplicit -eq $mSF)

# PURE builder never throws, even on bad ids (it is a string builder, no COM).
$threwB = $false; $mBad = $null
try { $mBad = Build-TangentPlaneMacro -PointId 0 -SurfaceId 0 } catch { $threwB = $true }
Assert-True "macro: bad ids did NOT throw (pure builder)" (-not $threwB)
Assert-True "macro: bad ids still returns a string" ($mBad -is [string])

# ============================================================================
# Invoke-TangentPlane  --  guard/canary LOGIC via STUBS
# ============================================================================
# COM-heavy, so (mirroring run_wizard_tests.ps1's Invoke-SlotPatternFromSeed
# block) we stub the ONE-TIME core scope Invoke-TangentPlane reads:
#   $script:DJSession - a RunMacro that RECORDS the fired macro(s),
#   $script:DJModel   - VersionStamp (ScriptProperty; can be made to throw for the
#                       "canary unreadable" branch) + ListItems (feeds
#                       Get-FeatureIdSet's before/after diff),
#   $script:DJType    - ITEM_FEATURE (the ListItems key Get-FeatureIdSet uses).
# We also SHADOW Wait-ModelModified so the change/no-change signal is deterministic
# offline (Get-FeatureIdSet + VersionStamp are the real code paths; the only thing
# we cannot exercise headless is the actual Creo regen, so its detector is stubbed).
# Placed LAST so the shadow of Wait-ModelModified is not seen by any earlier test.
# ----------------------------------------------------------------------------
Write-Host "  -- Invoke-TangentPlane (guard + canary logic, stubbed COM) --" -ForegroundColor White

$script:tpFired = @()
# $script:tpFeatureIds is the feature-id set the model reports NOW. Get-FeatureIdSet
# reads ListItems(ITEM_FEATURE) -> objects with .Id, so we return those. A "new plane"
# is simulated by APPENDING an id to this list between the before- and after-snapshot,
# which the RunMacro stub does when a build is expected to succeed.
$script:tpFeatureIds = @(11, 22, 33)
$script:tpNewIdToAdd  = 0    # when >0, RunMacro appends it (simulates Creo making a plane)
$script:tpStampThrows = $false

$tpStubS = [pscustomobject]@{}
Add-Member -InputObject $tpStubS -MemberType ScriptMethod -Name RunMacro -Value {
    param($x)
    $script:tpFired += ,([string]$x)
    # simulate Creo creating a new datum-plane feature: the after-snapshot then
    # differs from the before-snapshot by exactly this id.
    if ($script:tpNewIdToAdd -gt 0) { $script:tpFeatureIds = @($script:tpFeatureIds + [int]$script:tpNewIdToAdd) }
}
$tpStubM = [pscustomobject]@{}
Add-Member -InputObject $tpStubM -MemberType ScriptProperty -Name VersionStamp -Value {
    if ($script:tpStampThrows) { throw "stamp unreadable" }
    return ('v' + (@($script:tpFeatureIds)).Count)   # changes as the feature set changes
}
Add-Member -InputObject $tpStubM -MemberType ScriptMethod -Name ListItems -Value {
    param($type)
    return @($script:tpFeatureIds | ForEach-Object { [pscustomobject]@{ Id = [int]$_ } })
}
$tpStubT = [pscustomobject]@{ ITEM_FEATURE = 999 }

Set-Variable -Name DJSession -Scope Script -Value $tpStubS
Set-Variable -Name DJModel   -Scope Script -Value $tpStubM
Set-Variable -Name DJType    -Scope Script -Value $tpStubT

# Wait-ModelModified is the ONLY Creo-regen detector; shadow it so change/no-change
# is deterministic. It mirrors the real signature so a call is byte-compatible.
$script:tpWait = $true
function Wait-ModelModified {
    param($Model = $null, [string]$PreviousStamp, [int]$TimeoutMs = 30000, [scriptblock]$OnPoll = $null)
    return $script:tpWait
}

# --- guard: PointId <= 0 -> short-circuit, NO macro fired, Created=$false ---
$script:tpFired = @(); $script:tpNewIdToAdd = 44; $script:tpWait = $true
$gP = Invoke-TangentPlane -PointId 0 -SurfaceId $ID_SURFACE -TimeoutMs 50
Assert-True "guard PointId<=0: Created=false" (-not [bool](Get-Field $gP @('Created')))
Assert-True "guard PointId<=0: NO macro fired" ((@($script:tpFired)).Count -eq 0)
Assert-True "guard PointId<=0: PlaneId is null" ($null -eq (Get-Field $gP @('PlaneId')))
Assert-True "guard PointId<=0: Reason mentions point" (([string](Get-Field $gP @('Reason'))) -match '(?i)point')

# negative point id also short-circuits.
$script:tpFired = @()
$gPneg = Invoke-TangentPlane -PointId -5 -SurfaceId $ID_SURFACE -TimeoutMs 50
Assert-True "guard PointId<0: Created=false" (-not [bool](Get-Field $gPneg @('Created')))
Assert-True "guard PointId<0: NO macro fired" ((@($script:tpFired)).Count -eq 0)

# --- guard: SurfaceId <= 0 -> short-circuit, NO macro fired, Created=$false ---
$script:tpFired = @(); $script:tpNewIdToAdd = 44; $script:tpWait = $true
$gS = Invoke-TangentPlane -PointId $PID_POINT -SurfaceId 0 -TimeoutMs 50
Assert-True "guard SurfaceId<=0: Created=false" (-not [bool](Get-Field $gS @('Created')))
Assert-True "guard SurfaceId<=0: NO macro fired" ((@($script:tpFired)).Count -eq 0)
Assert-True "guard SurfaceId<=0: PlaneId is null" ($null -eq (Get-Field $gS @('PlaneId')))
Assert-True "guard SurfaceId<=0: Reason mentions surface" (([string](Get-Field $gS @('Reason'))) -match '(?i)surface')

# negative surface id also short-circuits.
$script:tpFired = @()
$gSneg = Invoke-TangentPlane -PointId $PID_POINT -SurfaceId -3 -TimeoutMs 50
Assert-True "guard SurfaceId<0: Created=false" (-not [bool](Get-Field $gSneg @('Created')))
Assert-True "guard SurfaceId<0: NO macro fired" ((@($script:tpFired)).Count -eq 0)

# --- happy path: change + a NEW feature id -> Created=$true, PlaneId=<new id> ---
$script:tpFeatureIds = @(11, 22, 33)   # reset the before-set
$script:tpFired = @(); $script:tpNewIdToAdd = 44; $script:tpWait = $true; $script:tpStampThrows = $false
$ok = Invoke-TangentPlane -PointId $PID_POINT -SurfaceId $ID_SURFACE -TimeoutMs 50
Assert-True "happy: Created=true" ([bool](Get-Field $ok @('Created')))
Assert-True "happy: fired exactly ONE macro (one atomic RunMacro)" ((@($script:tpFired)).Count -eq 1)
Assert-True "happy: the fired macro is the tangent-plane macro" (($script:tpFired[0]) -match 'ProCmdDatumPlane' -and ($script:tpFired[0]) -match 'Tangent')
Assert-True "happy: fired macro carries both ref ids" ((($script:tpFired[0]) -match "\b$PID_POINT\b") -and (($script:tpFired[0]) -match "\b$ID_SURFACE\b"))
Assert-True "happy: PlaneId == the new feature id (44)" (([int](Get-Field $ok @('PlaneId'))) -eq 44)
Assert-True "happy: Reason reports created" (([string](Get-Field $ok @('Reason'))) -match '(?i)creat')

# happy path fires the SURFACE-FIRST macro by default (surface id before point id).
$hi = ($script:tpFired[0]).IndexOf([string]$ID_SURFACE)
$hp = ($script:tpFired[0]).IndexOf([string]$PID_POINT)
Assert-True "happy: default fires surface-first macro" (($hi -ge 0) -and ($hp -ge 0) -and ($hi -lt $hp))

# --- happy path with -SurfaceFirst:$false -> fires the point-first macro ---
$script:tpFeatureIds = @(11, 22, 33)
$script:tpFired = @(); $script:tpNewIdToAdd = 55; $script:tpWait = $true
$okPF = Invoke-TangentPlane -PointId $PID_POINT -SurfaceId $ID_SURFACE -SurfaceFirst:$false -TimeoutMs 50
Assert-True "happy (point-first): Created=true" ([bool](Get-Field $okPF @('Created')))
Assert-True "happy (point-first): PlaneId == the new feature id (55)" (([int](Get-Field $okPF @('PlaneId'))) -eq 55)
$pi = ($script:tpFired[0]).IndexOf([string]$PID_POINT)
$ps = ($script:tpFired[0]).IndexOf([string]$ID_SURFACE)
Assert-True "happy (point-first): fired macro has POINT id before SURFACE id" (($pi -ge 0) -and ($ps -ge 0) -and ($pi -lt $ps))

# --- MISS: macro fires but the model does NOT change -> Created=$false ---
$script:tpFeatureIds = @(11, 22, 33)
$script:tpFired = @(); $script:tpNewIdToAdd = 0; $script:tpWait = $false; $script:tpStampThrows = $false
$miss = Invoke-TangentPlane -PointId $PID_POINT -SurfaceId $ID_SURFACE -TimeoutMs 50
Assert-True "miss (no change): Created=false" (-not [bool](Get-Field $miss @('Created')))
Assert-True "miss (no change): the macro DID fire (guards passed)" ((@($script:tpFired)).Count -eq 1)
Assert-True "miss (no change): PlaneId is null" ($null -eq (Get-Field $miss @('PlaneId')))
Assert-True "miss (no change): Reason mentions the model did not change" (([string](Get-Field $miss @('Reason'))) -match '(?i)change|miss|no tangent')

# --- MISS: VersionStamp unreadable BEFORE firing -> treated as a miss ---
# (Get-FeatureIdSet before still runs; the stamp read throws -> canary unavailable.)
$script:tpFeatureIds = @(11, 22, 33)
$script:tpFired = @(); $script:tpNewIdToAdd = 44; $script:tpWait = $true; $script:tpStampThrows = $true
$missStamp = Invoke-TangentPlane -PointId $PID_POINT -SurfaceId $ID_SURFACE -TimeoutMs 50
Assert-True "miss (stamp unreadable): Created=false" (-not [bool](Get-Field $missStamp @('Created')))
Assert-True "miss (stamp unreadable): PlaneId is null" ($null -eq (Get-Field $missStamp @('PlaneId')))
Assert-True "miss (stamp unreadable): Reason present" ((([string](Get-Field $missStamp @('Reason'))).Length) -gt 0)
$script:tpStampThrows = $false   # restore for any later use

# --- Invoke-TangentPlane NEVER throws (a stubbed RunMacro error is caught) ---
$errStubS = [pscustomobject]@{}
Add-Member -InputObject $errStubS -MemberType ScriptMethod -Name RunMacro -Value { param($x) throw "boom" }
Set-Variable -Name DJSession -Scope Script -Value $errStubS
$script:tpFeatureIds = @(11, 22, 33); $script:tpWait = $true
$threwInv = $false; $errRes = $null
try { $errRes = Invoke-TangentPlane -PointId $PID_POINT -SurfaceId $ID_SURFACE -TimeoutMs 50 } catch { $threwInv = $true }
Assert-True "error path: Invoke-TangentPlane did NOT throw on a RunMacro error" (-not $threwInv)
Assert-True "error path: returned an object" ($null -ne $errRes)
Assert-True "error path: Created=false on a macro error" (($null -ne $errRes) -and (-not [bool](Get-Field $errRes @('Created'))))
Assert-True "error path: Reason mentions the error" (([string](Get-Field $errRes @('Reason'))) -match '(?i)error|boom')
# put the recording stub back (harmless if nothing follows).
Set-Variable -Name DJSession -Scope Script -Value $tpStubS

# ============================================================================
# SUMMARY
# ============================================================================
Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ("  tangent-plane tests: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { "Green" } else { "Red" })
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ""
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
