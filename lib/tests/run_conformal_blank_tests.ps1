# ============================================================================
# lib\tests\run_conformal_blank_tests.ps1 - offline unit tests for
# lib\conformal_blank.ps1
# ============================================================================
# Runs WITHOUT Creo and WITHOUT network. Exercises the CONFORMAL JIG BLANK engine
# (STAGE 1 of the curved drill jig) - the offset+thicken macro builders, the
# On-Point NORMAL-hole macro, the new-feature/body diff readers, and the
# Invoke-ConformalBlank orchestrator (guards + canary). This module was lifted out
# of drilljig3d.cmd so BOTH the console tool and drilljig3d-gui.cmd call one source.
#
# PIECES UNDER TEST (the published conformal_blank contract - verified by reading
# lib\conformal_blank.ps1, not trusted from the task summary):
#   * Get-SelectSurfacesByIdMacro -SurfIds     -> PURE tree-search "select surface(s)
#     by id into the buffer" (buffer_clean, ProCmdMdlTreeSearch, SelOptionRadio
#     Surface, one InputIDPanel/EvaluateBtn/ApplyBtn per id (ACCUMULATE), CancelButton).
#   * Get-OffsetThickenMacro [-Thickness] [-StandOff] [-Flip] -> the ONE ATOMIC builder,
#     transcribed VERBATIM from the operator's freshest recording (trail.txt.15, the
#     'dumbclaude' mapkeys, 2026-07-27 15:43) + drilljig3d.cmd STAGE 1 (CONFIRMED LIVE
#     2026-06-24). Offset via mru_option_menu + ExclSrfColl; thicken via
#     maindashInst0.Thickness; the NEW BODY via thicken_control.0 + body_page.0 +
#     body_page.0.0 PH.bodyusechkbtnrepwdg. NO GrmTextTagEmbedMRU, NO ProCmdViewShow
#     (the 2026-07-27-AM 'curvedworkflow' reconciliation was a mis-read + dropped the
#     new-body widget, so the GUI Surface stage silently no-op'd). One ProCmdFtOffset +
#     one ProCmdFtThicken + two dashInst0.Done; -Flip emits one maindashInst0.Flip.
#   * Get-SelectItemByIdMacro -TypeName -Id [-NoClear] -> PURE generic select-by-id
#     (default leads with buffer_clean; -NoClear OMITS it to ACCUMULATE a 2nd ref).
#   * Build-NormalHoleMacro -PointId -SurfaceId -Diameter [-BodyIndex] [-DefaultOrient]
#     -> PURE On-Point hole macro NORMAL to a surface (point first w/ buffer_clean;
#     orientation surface appended with NoClear when SurfaceId>0 and not -DefaultOrient;
#     -DefaultOrient DROPS the surface select; exactly one ProCmdHole + one
#     dashInst0.Done; thru-all StrHoleDepThruAllF; diameter + body index threaded).
#   * Get-NewFeatureLinearDims -Model -TypeObj -BeforeIds -> COM read; only NEW
#     features (id NOT in $BeforeIds), sorted ascending by id, collecting ONLY
#     DimType-0 (Linear) symbols. NEVER throws on a null/empty/throwing model.
#   * Get-BodyIdSet -Model -TypeObj            -> COM read; ITEM_BODY id set; NEVER
#     throws on a throwing model.
#   * Set-DimAndConfirm -Model -TypeObj -Sym -Target -> COM; write DimValue by symbol,
#     force regen, re-read; $null on a write failure (GetItemByName throws). NEVER throws.
#   * Resolve-SelectedSurfaces / Resolve-SelectedPoints -Session -TypeObj -> COM
#     selection-buffer reads. ID-ONLY (never $si.Point); dedup; classify surfaces vs
#     points; a datum-point FEATURE expands via ListSubItems(ITEM_POINT); non-matching
#     selections -> Rejected; a NULL buffer -> empty, NO throw.
#   * Invoke-ConformalBlank -Session -Model -TypeObj -SurfIds -Thickness [-StandOff]
#     [-Flip] [-OnPoll] [-TimeoutMs] -> COM orchestrator, ONE ATOMIC canary-gated macro
#     (select surface by id + offset + thicken + new-body in a single RunMacro -- the
#     thicken relies on the freshly-created offset quilt, which a dashboard does not keep
#     across separate RunMacro calls). GUARDS: empty/null SurfIds -> Made=$false + Reason
#     (no fire); Thickness<=0 -> Made=$false. Canary: a no-stamp-change -> Made=$false +
#     Changed=$false + Reason (a MISS, never assumed success). Happy path: ONE fire,
#     Made/Changed true, BodyIndex is the NEW body's index, both dims driven+held by the
#     regen-dim backstop; -Flip forwards one maindashInst0.Flip into the macro.
#
# STUBBING (mirrors run_curved_slot_macros_tests.ps1): the COM helpers read the
# $script:DJSession/DJModel/DJType scope Initialize-DrilljigCore sets. We
# Set-Variable those to lightweight PSCustomObject stubs (RunMacro captures the fired
# macro; a mutable VersionStamp + a ListItems returning fake feature/body objects
# drive the canary + before/after diffs). Because Set-DimAndConfirm calls
# Invoke-ForceRegen (drilljig_core - tries a real COM RegenInstructions that throws
# offline, then a UI-macro regen loop) we shadow Invoke-ForceRegen with a no-op stub
# so the happy path is FAST and headless. The Invoke-ConformalBlank canary uses
# Wait-ModelModified (a stamp poll that spins for TimeoutMs); we shadow it with a
# deterministic, instant stub, exactly like the sibling suite.
#
# HARD REPO RULES honored: PURE builders NEVER throw; COM readers degrade to
# empty/$null (asserted); no Creo, no network, no IpfcPoint.Point (asserted the
# readers are ID-only). Assertions are NOT weakened to force a pass - where the live
# happy path cannot be faithfully stubbed offline (e.g. real regen), the never-throw
# + guard + canary-miss behavior is tested instead, and noted in a comment.
#
# Modeled EXACTLY on lib\tests\run_curved_slot_macros_tests.ps1 (Assert-True/Approx/
# Get-Field helpers, guarded dot-source pattern, pass/fail counter, exit 0 on
# all-pass / 1 on any failure).
#
# Run:  powershell -ExecutionPolicy Bypass -File lib\tests\run_conformal_blank_tests.ps1
# Exit code 0 = all passed, 1 = at least one failure.
# ============================================================================

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here
# conformal_blank.ps1 depends on creo_geometry.ps1 (Read-DimValue) and
# drilljig_core.ps1 (Invoke-ForceRegen / Wait-ModelModified / Get-FeatureIdSet).
# Dot-source them FIRST so they are in scope regardless of the lib's internal load
# order. drilljig_core needs creo_geometry + the orthogrid macro fragments in scope
# too; guard each optional dependency so a load hiccup on one never wedges the suite.
foreach ($dep in @('creo_geometry.ps1', 'orthogrid.ps1', 'orthogrid_points.ps1', 'drilljig_core.ps1')) {
    $p = Join-Path $libDir $dep
    if (Test-Path $p) { try { . $p } catch {} }
}
$p = Join-Path $libDir 'conformal_blank.ps1'
if (Test-Path $p) { try { . $p } catch {} }

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

# Tolerant field getter: returns the value of the FIRST field that exists on $obj
# from the candidate name list, or $null if none. Invoke-ConformalBlank returns a
# HASHTABLE (@{ Made=..; Changed=.. }), whose keys are NOT surfaced through
# $Obj.PSObject.Properties - so resolve BOTH hashtable keys AND PSCustomObject/
# NoteProperty members (dynamic member access), like the sibling suite.
function Get-Field {
    param($Obj, [string[]]$Names)
    if ($null -eq $Obj) { return $null }
    foreach ($n in $Names) {
        if (($Obj -is [System.Collections.IDictionary]) -and $Obj.Contains($n)) { return $Obj[$n] }
        $prop = $Obj.PSObject.Properties[$n]
        if ($null -ne $prop) { return $prop.Value }
        try { $v = $Obj.$n; if ($null -ne $v) { return $v } } catch {}
    }
    return $null
}

# Count members robustly (a single object is count 1, $null is 0).
function Count-Of {
    param($X)
    if ($null -eq $X) { return 0 }
    return (@($X) | Measure-Object).Count
}

# Count non-overlapping occurrences of a literal token in a string.
function Count-Token {
    param([string]$S, [string]$Token)
    if ([string]::IsNullOrEmpty($S)) { return 0 }
    return ([regex]::Matches($S, [regex]::Escape($Token))).Count
}

# ----------------------------------------------------------------------------
# STUB COM SCOPE. Build lightweight PSCustomObject stubs and Set-Variable them into
# the drilljig_core $script scope (what Initialize-DrilljigCore does, minus the real
# COM). A mutable VersionStamp lets a test flip "did the model change?"; a ListItems
# switched on the requested item type returns fake feature OR body objects so
# Get-FeatureIdSet / Get-BodyIdSet before/after diffs work.
#
# $script:cbFired  - captures every RunMacro string fired.
# $script:cbStamp  - the current VersionStamp value.
# $script:cbFeats  - the current ITEM_FEATURE id list (fake feature objects).
# $script:cbBodies - the current ITEM_BODY id list (fake body objects).
# $script:cbDims   - per-feature-id linear dim symbol lists (drives ListSubItems).
# ----------------------------------------------------------------------------
$script:cbFired  = @()
$script:cbStamp  = 'v0'
$script:cbFeats  = @()
$script:cbBodies = @()
$script:cbSurfs  = @()     # the current ITEM_SURFACE id list (the offset adds a quilt)
$script:cbDims   = @{}     # featureId -> @( @{ Sym; DimType }, ... )

# ITEM_* constants (arbitrary distinct ints; the readers compare against $TypeObj)
$cbType = [pscustomobject]@{
    ITEM_FEATURE   = 901
    ITEM_DIMENSION = 902
    ITEM_BODY      = 903
    ITEM_SURFACE   = 904
    ITEM_POINT     = 905
}

# Build a fake FEATURE object with .Id and a .ListSubItems(ITEM_DIMENSION) that
# returns fake dim objects (.DimType / .Symbol) from $script:cbDims for that id.
function New-FakeFeature {
    param([int]$Id)
    $f = [pscustomobject]@{ Id = $Id }
    Add-Member -InputObject $f -MemberType ScriptMethod -Name ListSubItems -Value {
        param($t)
        $dims = @()
        if ($script:cbDims.ContainsKey([int]$this.Id)) { $dims = @($script:cbDims[[int]$this.Id]) }
        return @($dims | ForEach-Object {
            $spec = $_
            $d = [pscustomobject]@{ Symbol = [string]$spec.Sym }
            Add-Member -InputObject $d -MemberType NoteProperty -Name DimType -Value ([int]$spec.DimType)
            $d
        })
    }
    return $f
}

# Build a fake BODY object with .Id + .GetName().
function New-FakeBody {
    param([int]$Id, [string]$Name = "")
    $b = [pscustomobject]@{ Id = $Id }
    $nm = if ($Name) { $Name } else { "BODY_$Id" }
    Add-Member -InputObject $b -MemberType NoteProperty -Name _nm -Value $nm
    Add-Member -InputObject $b -MemberType ScriptMethod -Name GetName -Value { return [string]$this._nm }
    return $b
}

# Build a fake SURFACE object with .Id (Get-SurfaceIdSet only reads .Id).
function New-FakeSurface {
    param([int]$Id)
    return [pscustomobject]@{ Id = $Id }
}

$cbSession = [pscustomobject]@{}
Add-Member -InputObject $cbSession -MemberType ScriptMethod -Name RunMacro -Value {
    param($x) $script:cbFired += ,([string]$x)
}
# CurrentSelectionBuffer().Contents - driven by $script:cbBuffer (a test sets it).
$script:cbBuffer = $null
Add-Member -InputObject $cbSession -MemberType ScriptMethod -Name CurrentSelectionBuffer -Value {
    $buf = [pscustomobject]@{}
    Add-Member -InputObject $buf -MemberType ScriptProperty -Name Contents -Value { $script:cbBuffer }
    return $buf
}

$cbModel = [pscustomobject]@{}
Add-Member -InputObject $cbModel -MemberType ScriptProperty -Name VersionStamp -Value { $script:cbStamp }
Add-Member -InputObject $cbModel -MemberType ScriptMethod -Name ListItems -Value {
    param($t)
    if ([int]$t -eq 901) { return @($script:cbFeats  | ForEach-Object { New-FakeFeature -Id ([int]$_) }) }
    if ([int]$t -eq 903) { return @($script:cbBodies | ForEach-Object { New-FakeBody    -Id ([int]$_) }) }
    if ([int]$t -eq 904) { return @($script:cbSurfs  | ForEach-Object { New-FakeSurface -Id ([int]$_) }) }
    return @()
}
Add-Member -InputObject $cbModel -MemberType ScriptMethod -Name Regenerate -Value { param($x) }
# GetItemByName drives Read-DimValue + Set-DimAndConfirm. A per-symbol value store;
# a symbol NOT in $script:cbDimStore THROWS (mirrors the real COM: missing item
# throws). A settable .DimValue records the written value so the re-read reflects it.
$script:cbDimStore = @{}
Add-Member -InputObject $cbModel -MemberType ScriptMethod -Name GetItemByName -Value {
    param($t, $sym)
    $key = [string]$sym
    if (-not $script:cbDimStore.ContainsKey($key)) { throw "no such dim: $key" }
    $holder = [pscustomobject]@{ _sym = $key }
    Add-Member -InputObject $holder -MemberType ScriptProperty -Name DimValue `
        -Value  { $script:cbDimStore[$this._sym] } `
        -SecondValue { param($v) $script:cbDimStore[$this._sym] = [double]$v }
    return $holder
}

Set-Variable -Name DJSession -Scope Script -Value $cbSession
Set-Variable -Name DJModel   -Scope Script -Value $cbModel
Set-Variable -Name DJType    -Scope Script -Value $cbType

# Shadow Invoke-ForceRegen (drilljig_core): the real one News a COM RegenInstructions
# that throws offline, then falls into a UI-macro/poll path. We only need the DimValue
# write + re-read to exercise Set-DimAndConfirm, so a no-op regen keeps it instant.
function Invoke-ForceRegen { param($Model = $null) }

# Shadow Wait-ModelModified with a deterministic, instant stamp check (the real one
# spins for TimeoutMs). $script:cbWaitForced: $null = derive from the stamp;
# $true/$false = force. Mirrors the sibling suite.
$script:cbWaitForced = $null
function Wait-ModelModified {
    param($Model = $null, [string]$PreviousStamp, [int]$TimeoutMs = 30000, [scriptblock]$OnPoll = $null)
    if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }
    if ($null -ne $script:cbWaitForced) { return [bool]$script:cbWaitForced }
    return ([string]$script:cbStamp -ne [string]$PreviousStamp)
}

Write-Host ""
Write-Host "  Running conformal-blank unit tests (offline, stubbed COM)..." -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# Get-SelectSurfacesByIdMacro  --  PURE macro string
# ============================================================================
Write-Host "  -- Get-SelectSurfacesByIdMacro (pure macro) --" -ForegroundColor White

$selSurf = Get-SelectSurfacesByIdMacro -SurfIds @(11, 22, 33)
Assert-True "selsurf: returns a non-empty string" (($selSurf -is [string]) -and ($selSurf.Length -gt 0))
Assert-True "selsurf: clears the buffer first (buffer_clean)"   ($selSurf -match 'buffer_clean')
Assert-True "selsurf: opens the tree search (ProCmdMdlTreeSearch)" ($selSurf -match 'ProCmdMdlTreeSearch')
Assert-True "selsurf: selects a Surface-type reference"         ($selSurf -match 'Surface')
Assert-True "selsurf: ends with CancelButton"                   ($selSurf -match 'CancelButton')
# buffer_clean precedes the first ProCmd (no stale refs into the search)
Assert-True "selsurf: buffer_clean precedes the first ProCmd" ($selSurf.IndexOf('buffer_clean') -lt $selSurf.IndexOf('ProCmd'))
# each id lands in the macro
Assert-True "selsurf: id 11 fed to InputIDPanel" ($selSurf -match 'InputIDPanel.*11')
Assert-True "selsurf: id 22 fed to InputIDPanel" ($selSurf -match 'InputIDPanel.*22')
Assert-True "selsurf: id 33 fed to InputIDPanel" ($selSurf -match 'InputIDPanel.*33')
# ApplyBtn/EvaluateBtn ACCUMULATE - one per id
Assert-True "selsurf: one InputIDPanel per id (3)" ((Count-Token $selSurf 'InputIDPanel') -eq 3)
Assert-True "selsurf: one EvaluateBtn per id (3)"  ((Count-Token $selSurf 'EvaluateBtn') -eq 3)
Assert-True "selsurf: one ApplyBtn per id (3)"     ((Count-Token $selSurf 'ApplyBtn') -eq 3)
# only ONE buffer_clean + ONE CancelButton (search opened/closed once)
Assert-True "selsurf: exactly one buffer_clean" ((Count-Token $selSurf 'buffer_clean') -eq 1)
Assert-True "selsurf: exactly one CancelButton" ((Count-Token $selSurf 'CancelButton') -eq 1)

# a single id -> one accumulate cycle
$selSurf1 = Get-SelectSurfacesByIdMacro -SurfIds @(77)
Assert-True "selsurf(1): one InputIDPanel" ((Count-Token $selSurf1 'InputIDPanel') -eq 1)
Assert-True "selsurf(1): id 77 present"    ($selSurf1 -match 'InputIDPanel.*77')

# ============================================================================
# Get-OffsetThickenMacro  --  the ONE ATOMIC builder, transcribed VERBATIM from the
# operator's freshest recording (trail.txt.15, the 'dumbclaude' mapkeys, 2026-07-27
# 15:43) + drilljig3d.cmd STAGE 1 (CONFIRMED LIVE 2026-06-24). Offset via
# mru_option_menu + ExclSrfColl; thicken via maindashInst0.Thickness; the NEW BODY
# via thicken_control.0 + body_page.0 + body_page.0.0 PH.bodyusechkbtnrepwdg. NO
# GrmTextTagEmbedMRU, NO ProCmdViewShow (the AM 'curvedworkflow' reconciliation was
# a mis-read + dropped the new-body widget). --flip emits ONE maindashInst0.Flip.
# ============================================================================
Write-Host "  -- Get-OffsetThickenMacro (recorded widgets; atomic offset+thicken+new-body) --" -ForegroundColor White

$ot = Get-OffsetThickenMacro -Thickness 0.5
Assert-True "offthk: non-empty string"                 (($ot -is [string]) -and ($ot.Length -gt 0))
Assert-True "offthk: exactly one ProCmdFtOffset"       ((Count-Token $ot 'ProCmdFtOffset') -eq 1)
Assert-True "offthk: exactly one ProCmdFtThicken"      ((Count-Token $ot 'ProCmdFtThicken') -eq 1)
Assert-True "offthk: exactly two dashInst0.Done"       ((Count-Token $ot 'dashInst0.Done') -eq 2)
Assert-True "offthk: offset uses mru_option_menu (recorded)" ($ot -match 'maindashInst0\.mru_option_menu')
Assert-True "offthk: offset uses ExclSrfColl (recorded)" ($ot -match 'maindashInst0\.ExclSrfColl')
Assert-True "offthk: thickness value .5 in maindashInst0.Thickness" ($ot -match 'maindashInst0\.Thickness` `0\.5`')
Assert-True "offthk: NEW-BODY checkbox PH.bodyusechkbtnrepwdg present" ($ot -match 'PH\.bodyusechkbtnrepwdg')
Assert-True "offthk: thicken_control.0 present"        ($ot -match 'chkbn\.thicken_control\.0')
Assert-True "offthk: body_page.0 present"              ($ot -match 'chkbn\.body_page\.0')
Assert-True "offthk: NO stale GrmTextTagEmbedMRU widget" (-not ($ot -match 'GrmTextTagEmbedMRU'))
Assert-True "offthk: NO stale ProCmdViewShow (no show-quilt dance)" (-not ($ot -match 'ProCmdViewShow'))
# a different thickness threads through
$ot25 = Get-OffsetThickenMacro -Thickness 0.25
Assert-True "offthk: a different thickness (.25) lands" ($ot25 -match 'maindashInst0\.Thickness` `0\.25`')

# --flip OFF (default) -> NO maindashInst0.Flip; --flip ON -> exactly one.
Assert-True "offthk: default (no -Flip) emits NO maindashInst0.Flip" (-not ($ot -match 'maindashInst0\.Flip'))
$otF = Get-OffsetThickenMacro -Thickness 0.5 -Flip
Assert-True "offthk(-Flip): exactly one maindashInst0.Flip" ((Count-Token $otF 'maindashInst0.Flip') -eq 1)
# the flip lands BEFORE the body-page block (grows material, then routes to new body)
Assert-True "offthk(-Flip): Flip precedes the new-body checkbox" ($otF.IndexOf('maindashInst0.Flip') -lt $otF.IndexOf('PH.bodyusechkbtnrepwdg'))

# ============================================================================
# Get-SelectItemByIdMacro  --  PURE generic select-by-id (clear vs accumulate)
# ============================================================================
Write-Host "  -- Get-SelectItemByIdMacro (clear/accumulate) --" -ForegroundColor White

$selClear = Get-SelectItemByIdMacro -TypeName 'Point' -Id 1234
Assert-True "selitem(clear): non-empty string" (($selClear -is [string]) -and ($selClear.Length -gt 0))
Assert-True "selitem(clear): leads with buffer_clean" ($selClear -match 'buffer_clean')
Assert-True "selitem(clear): buffer_clean precedes the first ProCmd" ($selClear.IndexOf('buffer_clean') -lt $selClear.IndexOf('ProCmd'))
Assert-True "selitem(clear): TypeName 'Point' lands in the macro" ($selClear -match '`Point`')
Assert-True "selitem(clear): Id 1234 fed to InputIDPanel" ($selClear -match 'InputIDPanel.*1234')

$selAcc = Get-SelectItemByIdMacro -TypeName 'Surface' -Id 5678 -NoClear
Assert-True "selitem(-NoClear): OMITS buffer_clean (accumulate)" (-not ($selAcc -match 'buffer_clean'))
Assert-True "selitem(-NoClear): TypeName 'Surface' lands in the macro" ($selAcc -match '`Surface`')
Assert-True "selitem(-NoClear): Id 5678 fed to InputIDPanel" ($selAcc -match 'InputIDPanel.*5678')

# ============================================================================
# Build-NormalHoleMacro  --  PURE On-Point hole macro, normal to a surface
# ============================================================================
Write-Host "  -- Build-NormalHoleMacro (On-Point normal hole) --" -ForegroundColor White

$hole = Build-NormalHoleMacro -PointId 300 -SurfaceId 400 -Diameter 0.375 -BodyIndex 2
Assert-True "normhole: non-empty string" (($hole -is [string]) -and ($hole.Length -gt 0))
# point selected first (its select clears the buffer)
Assert-True "normhole: contains buffer_clean (point select clears)" ($hole -match 'buffer_clean')
Assert-True "normhole: point id 300 fed to InputIDPanel" ($hole -match 'InputIDPanel.*300')
Assert-True "normhole: the point select is Point-typed" ($hole -match '`Point`')
Assert-True "normhole: point precedes the surface (placement before orientation)" ($hole.IndexOf('`Point`') -lt $hole.IndexOf('`Surface`'))
# orientation surface appended with NoClear (a 2nd select with NO 2nd buffer_clean)
Assert-True "normhole: exactly one buffer_clean (surface added w/ NoClear)" ((Count-Token $hole 'buffer_clean') -eq 1)
Assert-True "normhole: orientation surface id 400 present" ($hole -match 'InputIDPanel.*400')
Assert-True "normhole: the orientation select is Surface-typed" ($hole -match '`Surface`')
# exactly one ProCmdHole + one dashInst0.Done
Assert-True "normhole: exactly one ProCmdHole"     ((Count-Token $hole 'ProCmdHole') -eq 1)
Assert-True "normhole: exactly one dashInst0.Done" ((Count-Token $hole 'dashInst0.Done') -eq 1)
# thru-all token + diameter + body index threaded
Assert-True "normhole: thru-all token StrHoleDepThruAllF present" ($hole -match 'StrHoleDepThruAllF')
Assert-True "normhole: diameter 0.375 threaded"   ($hole -match '0\.375')
Assert-True "normhole: body index 2 threaded"     ($hole -match 'PH\.bodyselectrepwdg_list.*2')

# -DefaultOrient DROPS the orientation surface select entirely
$holeDef = Build-NormalHoleMacro -PointId 300 -SurfaceId 400 -Diameter 0.5 -DefaultOrient
Assert-True "normhole(-DefaultOrient): no Surface select" (-not ($holeDef -match '`Surface`'))
Assert-True "normhole(-DefaultOrient): surface id 400 absent" (-not ($holeDef -match 'InputIDPanel.*400'))
Assert-True "normhole(-DefaultOrient): point id 300 still present" ($holeDef -match 'InputIDPanel.*300')
Assert-True "normhole(-DefaultOrient): still one ProCmdHole" ((Count-Token $holeDef 'ProCmdHole') -eq 1)

# SurfaceId <= 0 also drops the orientation select (no usable surface)
$holeNoSurf = Build-NormalHoleMacro -PointId 300 -SurfaceId 0 -Diameter 0.25
Assert-True "normhole(SurfaceId 0): no Surface select" (-not ($holeNoSurf -match '`Surface`'))
Assert-True "normhole(SurfaceId 0): point id 300 present" ($holeNoSurf -match 'InputIDPanel.*300')

# ============================================================================
# Get-NewFeatureLinearDims  --  COM read: NEW features only, sorted, Linear dims only
# ============================================================================
Write-Host "  -- Get-NewFeatureLinearDims (new-feature diff) --" -ForegroundColor White

# state: features 1,2 existed before; 5 and 3 are NEW. Feature 5 has a Linear dim
# 'd7' + a NON-linear (radial=1) 'd8'; feature 3 has a Linear 'd2'. Feature 2 (old)
# also has a Linear dim but must be EXCLUDED (it was in BeforeIds).
$script:cbFeats = @(1, 2, 5, 3)
$script:cbDims  = @{
    1 = @( @{ Sym = 'd0'; DimType = 0 } )
    2 = @( @{ Sym = 'd1'; DimType = 0 } )
    5 = @( @{ Sym = 'd7'; DimType = 0 }, @{ Sym = 'd8'; DimType = 1 } )   # d8 is radial -> excluded
    3 = @( @{ Sym = 'd2'; DimType = 0 } )
}
$before = @{ 1 = $true; 2 = $true }
$newDims = @(Get-NewFeatureLinearDims -Model $cbModel -TypeObj $cbType -BeforeIds $before)
Assert-True "newdims: only the 2 NEW features returned" ($newDims.Count -eq 2)
# sorted ASCENDING by id -> feature 3 first, then feature 5
Assert-True "newdims: sorted ascending by id (3 before 5)" (([int]$newDims[0].Id -eq 3) -and ([int]$newDims[1].Id -eq 5))
Assert-True "newdims: old feature 1 excluded" (-not ($newDims | Where-Object { [int]$_.Id -eq 1 }))
Assert-True "newdims: old feature 2 excluded" (-not ($newDims | Where-Object { [int]$_.Id -eq 2 }))
# only Linear (DimType 0) symbols collected: feature 5 keeps 'd7', DROPS radial 'd8'
$feat5 = @($newDims | Where-Object { [int]$_.Id -eq 5 })[0]
Assert-True "newdims: feature 5 keeps its Linear dim d7" (@($feat5.Dims) -contains 'd7')
Assert-True "newdims: feature 5 DROPS its radial dim d8" (-not (@($feat5.Dims) -contains 'd8'))
$feat3 = @($newDims | Where-Object { [int]$_.Id -eq 3 })[0]
Assert-True "newdims: feature 3 keeps its Linear dim d2" (@($feat3.Dims) -contains 'd2')

# never throws on a null model
$threwND = $false; $ndNull = $null
try { $ndNull = @(Get-NewFeatureLinearDims -Model $null -TypeObj $cbType -BeforeIds @{}) } catch { $threwND = $true }
Assert-True "newdims: null model did NOT throw" (-not $threwND)
Assert-True "newdims: null model -> empty" ($ndNull.Count -eq 0)

# never throws on a throwing model
$throwModel = [pscustomobject]@{}
Add-Member -InputObject $throwModel -MemberType ScriptMethod -Name ListItems -Value { param($t) throw "boom" }
$threwND2 = $false; $ndThrow = $null
try { $ndThrow = @(Get-NewFeatureLinearDims -Model $throwModel -TypeObj $cbType -BeforeIds @{}) } catch { $threwND2 = $true }
Assert-True "newdims: throwing model did NOT throw" (-not $threwND2)
Assert-True "newdims: throwing model -> empty" ($ndThrow.Count -eq 0)

# ============================================================================
# Get-BodyIdSet  --  COM read: ITEM_BODY id set
# ============================================================================
Write-Host "  -- Get-BodyIdSet (body id set) --" -ForegroundColor White

$script:cbBodies = @(10, 20, 30)
$bodySet = Get-BodyIdSet -Model $cbModel -TypeObj $cbType
Assert-True "bodyset: is a hashtable" ($bodySet -is [System.Collections.IDictionary])
Assert-True "bodyset: contains id 10" ($bodySet.ContainsKey(10))
Assert-True "bodyset: contains id 20" ($bodySet.ContainsKey(20))
Assert-True "bodyset: contains id 30" ($bodySet.ContainsKey(30))
Assert-True "bodyset: does not contain a foreign id" (-not $bodySet.ContainsKey(99))
Assert-True "bodyset: has exactly 3 entries" ($bodySet.Count -eq 3)

# never throws on a throwing model -> empty set
$threwBS = $false; $bsThrow = $null
try { $bsThrow = Get-BodyIdSet -Model $throwModel -TypeObj $cbType } catch { $threwBS = $true }
Assert-True "bodyset: throwing model did NOT throw" (-not $threwBS)
Assert-True "bodyset: throwing model -> empty set" ($bsThrow.Count -eq 0)

# never throws on a null model
$threwBS2 = $false; $bsNull = $null
try { $bsNull = Get-BodyIdSet -Model $null -TypeObj $cbType } catch { $threwBS2 = $true }
Assert-True "bodyset: null model did NOT throw" (-not $threwBS2)
Assert-True "bodyset: null model -> empty set" ($bsNull.Count -eq 0)

# ============================================================================
# Set-DimAndConfirm  --  COM: write DimValue by symbol, regen, re-read
# ============================================================================
Write-Host "  -- Set-DimAndConfirm (write + confirm) --" -ForegroundColor White

# WRITE-FAILURE path (the contract's guaranteed-testable branch): a symbol that
# GetItemByName does not know THROWS -> Set-DimAndConfirm catches and returns $null
# WITHOUT throwing. (Invoke-ForceRegen is shadowed to a no-op above so the real
# COM regen never runs offline.)
$script:cbDimStore = @{}     # empty store -> every symbol is "missing" -> throws
$writeFail = Set-DimAndConfirm -Model $cbModel -TypeObj $cbType -Sym 'dNOPE' -Target 1.0
Assert-True "setdim: unknown symbol -> returns null (write failed)" ($null -eq $writeFail)
$threwSD = $false
try { $null = Set-DimAndConfirm -Model $cbModel -TypeObj $cbType -Sym 'dNOPE' -Target 2.0 } catch { $threwSD = $true }
Assert-True "setdim: write-failure path did NOT throw" (-not $threwSD)

# HAPPY path: the symbol EXISTS (seed the store), the write sticks, the re-read via
# Read-DimValue returns the written value. GetItemByName returns a holder whose
# settable .DimValue records into $script:cbDimStore, and Read-DimValue reads it back.
$script:cbDimStore = @{ 'd7' = 0.0 }     # symbol exists (pre-seeded), current value 0
$now = Set-DimAndConfirm -Model $cbModel -TypeObj $cbType -Sym 'd7' -Target 0.5
Assert-True "setdim: happy path -> returns the written value 0.5" (($null -ne $now) -and (Approx ([double]$now) 0.5 1e-9))
Assert-True "setdim: the store recorded the write" (Approx ([double]$script:cbDimStore['d7']) 0.5 1e-9)

# HAPPY path, a different target confirms the value really threads (not a constant)
$now2 = Set-DimAndConfirm -Model $cbModel -TypeObj $cbType -Sym 'd7' -Target 1.25
Assert-True "setdim: happy path -> a 2nd target (1.25) also confirmed" (($null -ne $now2) -and (Approx ([double]$now2) 1.25 1e-9))

# ============================================================================
# Resolve-SelectedSurfaces  --  COM buffer read, ID-ONLY, classify/dedup/reject
# ============================================================================
Write-Host "  -- Resolve-SelectedSurfaces (buffer -> surface ids) --" -ForegroundColor White

# Build a fake SelItem. -Trap makes .Point THROW so a test proves the reader never
# touches it (ID-only): if the code reads .Point the trap fires and the whole reader
# would fall over - but it must not, since it never accesses .Point.
function New-SelItem {
    param([int]$Id, [int]$Type, [int[]]$SubPointIds = @())
    $si = [pscustomobject]@{ Id = $Id; Type = $Type }
    Add-Member -InputObject $si -MemberType ScriptProperty -Name Point -Value { throw "IpfcPoint.Point must NOT be read (ID-only)" }
    Add-Member -InputObject $si -MemberType ScriptMethod -Name ListSubItems -Value {
        param($t)
        # only expand for ITEM_POINT (905); other types return empty
        if ([int]$t -eq 905 -and $this._subs.Count -gt 0) {
            return @($this._subs | ForEach-Object { [pscustomobject]@{ Id = [int]$_ } })
        }
        return @()
    }
    Add-Member -InputObject $si -MemberType NoteProperty -Name _subs -Value ([int[]]$SubPointIds)
    return $si
}
function New-BufferItem { param($SelItem) $it = [pscustomobject]@{}; Add-Member -InputObject $it -MemberType NoteProperty -Name SelItem -Value $SelItem; return $it }

# buffer: two surfaces (id 41, 42), a duplicate surface (41 again), and a point (99)
$script:cbBuffer = @(
    (New-BufferItem (New-SelItem -Id 41 -Type 904)),   # surface
    (New-BufferItem (New-SelItem -Id 42 -Type 904)),   # surface
    (New-BufferItem (New-SelItem -Id 41 -Type 904)),   # DUP surface
    (New-BufferItem (New-SelItem -Id 99 -Type 905))    # point -> rejected
)
$rs = Resolve-SelectedSurfaces -Session $cbSession -TypeObj $cbType
$rsSurf = @(Get-Field $rs @('Surfaces'))
Assert-True "selsurfaces: found the 2 distinct surfaces" ($rsSurf.Count -eq 2)
Assert-True "selsurfaces: contains id 41" ($rsSurf -contains 41)
Assert-True "selsurfaces: contains id 42" ($rsSurf -contains 42)
Assert-True "selsurfaces: deduped the repeated 41 (only 2 total)" (($rsSurf | Where-Object { $_ -eq 41 }).Count -eq 1)
$rsRej = @(Get-Field $rs @('Rejected'))
Assert-True "selsurfaces: the point (99) went to Rejected" ($rsRej.Count -ge 1)

# NULL buffer -> empty, no throw
$script:cbBuffer = $null
$threwRS = $false; $rsNull = $null
try { $rsNull = Resolve-SelectedSurfaces -Session $cbSession -TypeObj $cbType } catch { $threwRS = $true }
Assert-True "selsurfaces: null buffer did NOT throw" (-not $threwRS)
Assert-True "selsurfaces: null buffer -> 0 surfaces" ((@(Get-Field $rsNull @('Surfaces'))).Count -eq 0)

# ============================================================================
# Resolve-SelectedPoints  --  COM buffer read, ID-ONLY, direct point + feature expand
# ============================================================================
Write-Host "  -- Resolve-SelectedPoints (buffer -> point ids) --" -ForegroundColor White

# buffer: a direct point (id 51), a duplicate point (51 again), a datum-point FEATURE
# (id 60, but its ListSubItems(ITEM_POINT) yields point ids 61,62), and a surface (70,
# rejected). New-SelItem's .Point throws, proving ID-only expansion.
$script:cbBuffer = @(
    (New-BufferItem (New-SelItem -Id 51 -Type 905)),            # direct point
    (New-BufferItem (New-SelItem -Id 51 -Type 905)),            # DUP direct point
    (New-BufferItem (New-SelItem -Id 60 -Type 901 -SubPointIds @(61,62))),  # feature -> expands
    (New-BufferItem (New-SelItem -Id 70 -Type 904))             # surface -> rejected
)
$rp = Resolve-SelectedPoints -Session $cbSession -TypeObj $cbType
$rpPts = @(Get-Field $rp @('Points'))
Assert-True "selpoints: direct point 51 present" ($rpPts -contains 51)
Assert-True "selpoints: feature expanded to sub-point 61" ($rpPts -contains 61)
Assert-True "selpoints: feature expanded to sub-point 62" ($rpPts -contains 62)
Assert-True "selpoints: deduped the repeated 51" (($rpPts | Where-Object { $_ -eq 51 }).Count -eq 1)
Assert-True "selpoints: total distinct point ids == 3 (51,61,62)" ($rpPts.Count -eq 3)
$rpRej = @(Get-Field $rp @('Rejected'))
Assert-True "selpoints: the surface (70) went to Rejected" ($rpRej.Count -ge 1)

# NULL buffer -> empty, no throw
$script:cbBuffer = $null
$threwRP = $false; $rpNull = $null
try { $rpNull = Resolve-SelectedPoints -Session $cbSession -TypeObj $cbType } catch { $threwRP = $true }
Assert-True "selpoints: null buffer did NOT throw" (-not $threwRP)
Assert-True "selpoints: null buffer -> 0 points" ((@(Get-Field $rpNull @('Points'))).Count -eq 0)

# ============================================================================
# Invoke-ConformalBlank  --  COM orchestrator: guards + canary + body diff
# ============================================================================
Write-Host "  -- Invoke-ConformalBlank (guards + canary) --" -ForegroundColor White

# GUARD (a): empty SurfIds -> Made=$false + a Reason, NOTHING fired, no throw.
$script:cbFired = @()
$gEmpty = Invoke-ConformalBlank -Session $cbSession -Model $cbModel -TypeObj $cbType -SurfIds @() -Thickness 0.5
Assert-True "conf(empty surfids): Made false" (-not [bool](Get-Field $gEmpty @('Made')))
Assert-True "conf(empty surfids): a Reason is set" (-not [string]::IsNullOrEmpty([string](Get-Field $gEmpty @('Reason'))))
Assert-True "conf(empty surfids): nothing fired" (@($script:cbFired).Count -eq 0)

# GUARD (b): null SurfIds -> same
$script:cbFired = @()
$gNull = Invoke-ConformalBlank -Session $cbSession -Model $cbModel -TypeObj $cbType -SurfIds $null -Thickness 0.5
Assert-True "conf(null surfids): Made false" (-not [bool](Get-Field $gNull @('Made')))
Assert-True "conf(null surfids): nothing fired" (@($script:cbFired).Count -eq 0)

# GUARD (c): Thickness <= 0 -> Made=$false, nothing fired.
$script:cbFired = @()
$gThk0 = Invoke-ConformalBlank -Session $cbSession -Model $cbModel -TypeObj $cbType -SurfIds @(1) -Thickness 0
Assert-True "conf(thickness 0): Made false" (-not [bool](Get-Field $gThk0 @('Made')))
Assert-True "conf(thickness 0): a Reason is set" (-not [string]::IsNullOrEmpty([string](Get-Field $gThk0 @('Reason'))))
Assert-True "conf(thickness 0): nothing fired" (@($script:cbFired).Count -eq 0)
$gThkNeg = Invoke-ConformalBlank -Session $cbSession -Model $cbModel -TypeObj $cbType -SurfIds @(1) -Thickness -3
Assert-True "conf(negative thickness): Made false" (-not [bool](Get-Field $gThkNeg @('Made')))

# CANARY MISS: valid inputs, the atomic macro fires, but the model does NOT change
# (stamp stays). Made must be $false (a MISS is never assumed success -
# [[feedback_canary_must_not_assume_on_failure]]), Changed false, and a Reason set.
# The ONE fired macro carries BOTH the surface select + offset AND the thicken.
$script:cbFired = @()
$script:cbStamp = 'vNC'
$script:cbFeats = @(1, 2, 3)
$script:cbSurfs = @(50)
$script:cbBodies = @(10)
$script:cbWaitForced = $false     # force the canary to report "no change"
$missConf = Invoke-ConformalBlank -Session $cbSession -Model $cbModel -TypeObj $cbType -SurfIds @(41) -Thickness 0.5
Assert-True "conf(canary miss): exactly ONE macro fired (atomic)" (@($script:cbFired).Count -eq 1)
Assert-True "conf(canary miss): the fired macro contains ProCmdFtOffset" ($script:cbFired[0] -match 'ProCmdFtOffset')
Assert-True "conf(canary miss): the SAME macro contains ProCmdFtThicken (atomic)" ($script:cbFired[0] -match 'ProCmdFtThicken')
Assert-True "conf(canary miss): Made false (no change -> not assumed success)" (-not [bool](Get-Field $missConf @('Made')))
Assert-True "conf(canary miss): Changed false" (-not [bool](Get-Field $missConf @('Changed')))
Assert-True "conf(canary miss): a Reason is set" (-not [string]::IsNullOrEmpty([string](Get-Field $missConf @('Reason'))))

# HAPPY path (single atomic fire): the offset+thicken macro fires ONCE and mutates the
# model the way the real workflow does:
#   * a NEW offset feature (id 7, Linear dim 'do') + a NEW thicken feature (id 9, Linear
#     dim 'dt') appear, a NEW body (id 20, after-index 1) appears, and the stamp moves.
# Assert Made/Changed true, ONE fire that selects the surface + offsets + thickens in the
# same string, the new body is targeted, and both dims are driven-and-held by the backstop.
$script:cbFired = @()
$script:cbStamp = 'vH'
$script:cbFeats = @(1, 2, 3)               # before: 3 features
$script:cbSurfs = @(50)                     # before: 1 surface (the picked face)
$script:cbBodies = @(10)                    # before: 1 body (id 10) at index 0
$script:cbDims = @{}
$script:cbDimStore = @{}
$script:cbWaitForced = $null                # derive from the stamp (bumped by the fire)
Add-Member -InputObject $cbSession -MemberType ScriptMethod -Name RunMacro -Force -Value {
    param($x)
    $script:cbFired += ,([string]$x)
    # ONE atomic macro creates BOTH features + the new body and bumps the stamp.
    $script:cbFeats   = @(1, 2, 3, 7, 9)
    $script:cbDims[7] = @( @{ Sym = 'do'; DimType = 0 } )    # offset feature dim
    $script:cbDims[9] = @( @{ Sym = 'dt'; DimType = 0 } )    # thicken feature dim
    $script:cbDimStore['do'] = 5.0                            # pre-existing; backstop overwrites
    $script:cbDimStore['dt'] = 5.0
    $script:cbBodies  = @(10, 20)                             # NEW body id 20 at index 1
    $script:cbStamp   = 'vH-done'
}
$okConf = Invoke-ConformalBlank -Session $cbSession -Model $cbModel -TypeObj $cbType -SurfIds @(41) -Thickness 0.75 -StandOff 0.0
Assert-True "conf(happy): fired exactly ONE atomic macro" (@($script:cbFired).Count -eq 1) ("got {0}" -f @($script:cbFired).Count)
Assert-True "conf(happy): Made true"    ([bool](Get-Field $okConf @('Made')))
Assert-True "conf(happy): Changed true" ([bool](Get-Field $okConf @('Changed')))
# the single fire selects surface 41 by id AND offsets AND thickens (atomic)
Assert-True "conf(happy): fire selects surface id 41"  ($script:cbFired[0] -match 'InputIDPanel.*41')
Assert-True "conf(happy): fire runs ProCmdFtOffset"    ($script:cbFired[0] -match 'ProCmdFtOffset')
Assert-True "conf(happy): fire runs ProCmdFtThicken"   ($script:cbFired[0] -match 'ProCmdFtThicken')
Assert-True "conf(happy): fire creates a NEW BODY (PH.bodyusechkbtnrepwdg)" ($script:cbFired[0] -match 'PH\.bodyusechkbtnrepwdg')
# the NEW body (id 20) is at after-index 1 -> BodyIndex 1, BodyId 20
Assert-True "conf(happy): BodyIndex == 1 (the new body's index)" (([int](Get-Field $okConf @('BodyIndex'))) -eq 1)
Assert-True "conf(happy): BodyId == 20 (the new body)" (([int](Get-Field $okConf @('BodyId'))) -eq 20)
# backstop: lower new-feature id (7) = offset -> dim 'do' driven to StandOff 0.0 and HELD
Assert-True "conf(happy): OffsetSym resolved to the offset feature's dim (do)" ([string](Get-Field $okConf @('OffsetSym')) -eq 'do')
Assert-True "conf(happy): OffsetHeld true (offset driven to StandOff 0)" ([bool](Get-Field $okConf @('OffsetHeld')))
# higher new-feature id (9) = thicken -> dim 'dt' driven to Thickness 0.75 and HELD
Assert-True "conf(happy): ThickSym resolved to the thicken feature's dim (dt)" ([string](Get-Field $okConf @('ThickSym')) -eq 'dt')
Assert-True "conf(happy): ThicknessHeld true (thickness driven to 0.75)" ([bool](Get-Field $okConf @('ThicknessHeld')))

# --flip: the atomic macro forwards -Flip so the fired string carries maindashInst0.Flip.
$script:cbFired = @()
$script:cbStamp = 'vF'
$script:cbFeats = @(1, 2, 3)
$script:cbBodies = @(10)
$script:cbWaitForced = $true
$flipConf = Invoke-ConformalBlank -Session $cbSession -Model $cbModel -TypeObj $cbType -SurfIds @(41) -Thickness 0.5 -Flip
Assert-True "conf(-Flip): the fired macro carries maindashInst0.Flip" ($script:cbFired[0] -match 'maindashInst0\.Flip')

# restore the plain capture-only RunMacro
Add-Member -InputObject $cbSession -MemberType ScriptMethod -Name RunMacro -Force -Value {
    param($x) $script:cbFired += ,([string]$x)
}
$script:cbWaitForced = $null

# never throws on a macro that raises (RunMacro throwing -> caught, Made=$false)
Add-Member -InputObject $cbSession -MemberType ScriptMethod -Name RunMacro -Force -Value { param($x) throw "macro boom" }
$threwConf = $false; $confErr = $null
try { $confErr = Invoke-ConformalBlank -Session $cbSession -Model $cbModel -TypeObj $cbType -SurfIds @(41) -Thickness 0.5 } catch { $threwConf = $true }
Assert-True "conf(macro throws): did NOT throw" (-not $threwConf)
Assert-True "conf(macro throws): Made false + a Reason set" ((-not [bool](Get-Field $confErr @('Made'))) -and (-not [string]::IsNullOrEmpty([string](Get-Field $confErr @('Reason')))))
# restore
Add-Member -InputObject $cbSession -MemberType ScriptMethod -Name RunMacro -Force -Value {
    param($x) $script:cbFired += ,([string]$x)
}

# ============================================================================
# SUMMARY
# ============================================================================
Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ("  conformal-blank tests: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { "Green" } else { "Red" })
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ""
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
