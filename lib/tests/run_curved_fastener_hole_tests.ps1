# ============================================================================
# lib\tests\run_curved_fastener_hole_tests.ps1 - offline unit tests for
# lib\curved_fastener_hole.ps1
# ============================================================================
# Runs WITHOUT Creo and WITHOUT network. Exercises the FASTENER-PLANE hole engine:
#   * the PURE macro builders (Build-FastenerPointMacro, Build-PreselectedHoleMacro) -- the
#     on-point hole is ProCmdHole + Done with the point + TOP plane PRE-SELECTED (the operator's
#     'holeexctrude' recording 2026-07-28: ProCmdHole auto-assigns the pre-selected refs, so NO
#     collector/placement-page/diameter tokens); user decision "match recording exactly".
#   * the ID-only buffer readers (Resolve-SelectedPlaneIds, Get-DatumPointIdSet /
#     Resolve-NewDatumPointIds) -- never .Point, dedup, degrade to empty.
#   * Add-ComponentDefaultPlanesToBuffer + the shared Resolve-ComponentLeafModel +
#     Select-ComponentPlaneById (the TOP-plane -> ft_dir direction feed) -- path-qualified
#     component-subitem selection (the hands-free enabler). Stubbed COM: a fake
#     ComponentPath -> Leaf (as-model or via GetModel()) -> GetItemById 1/3/5 role planes; a
#     fake CMpfcSelect factory whose CreateModelItemSelection($item,$path) records the args;
#     a fake selection buffer capturing AddSelection. Asserts Added=3, roles ordered
#     Top/Side/Front, the COMPONENT PATH is passed as the 2nd arg (not $null), name-verify
#     rejects a wrong model, and NEVER throws on a null path / throwing model.
#
# HARD REPO RULES honored: PURE builders NEVER throw; COM readers degrade to
# empty/$null; ID-only (asserted the readers never touch .Point); no Creo, no network.
#
# Run:  powershell -ExecutionPolicy Bypass -File lib\tests\run_curved_fastener_hole_tests.ps1
# Exit code 0 = all passed, 1 = at least one failure.
# ============================================================================

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here
# curved_fastener_hole.ps1 depends on creo_geometry.ps1 + drilljig_core.ps1
# (Resolve-PlaneRole, Get-SelectDatumByIdMacro, Get-FeatureIdSet, Wait-ModelModified).
# Dot-source them FIRST; guard each so a load hiccup never wedges the suite.
foreach ($dep in @('creo_geometry.ps1', 'orthogrid.ps1', 'orthogrid_points.ps1', 'drilljig_core.ps1', 'conformal_blank.ps1')) {
    $p = Join-Path $libDir $dep
    if (Test-Path $p) { try { . $p } catch {} }
}
$p = Join-Path $libDir 'curved_fastener_hole.ps1'
if (Test-Path $p) { try { . $p } catch {} }

$script:pass = 0
$script:fail = 0

function Assert-True {
    param([string]$Name, [bool]$Cond, [string]$Detail = "")
    if ($Cond) { Write-Host "  [PASS] $Name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  [FAIL] $Name $Detail" -ForegroundColor Red; $script:fail++ }
}
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
function Count-Token {
    param([string]$S, [string]$Token)
    if ([string]::IsNullOrEmpty($S)) { return 0 }
    return ([regex]::Matches($S, [regex]::Escape($Token))).Count
}

Write-Host ""
Write-Host "  Running curved-fastener-hole unit tests (offline, stubbed COM)..." -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# Build-FastenerPointMacro  --  PURE
# ============================================================================
Write-Host "  -- Build-FastenerPointMacro (3-plane intersection point) --" -ForegroundColor White
$pt = Build-FastenerPointMacro
Assert-True "fastpt: non-empty string" (($pt -is [string]) -and ($pt.Length -gt 0))
Assert-True "fastpt: fires ProCmdDatumPointGeneral" ($pt -match 'ProCmdDatumPointGeneral')
Assert-True "fastpt: confirms with stdbtn_1" ($pt -match 'stdbtn_1')

# ============================================================================
# Build-PreselectedHoleMacro  --  PURE, the WHOLE on-point hole: ProCmdHole + Done.
# (verbatim from the operator's 'holeexctrude' recording 2026-07-28: the point + TOP plane are
#  PRE-SELECTED, so ProCmdHole auto-assigns them -- NO collector/page/diameter tokens at all.)
# ============================================================================
Write-Host "  -- Build-PreselectedHoleMacro (ProCmdHole on pre-selected point+plane, Done) --" -ForegroundColor White
$hm = Build-PreselectedHoleMacro
Assert-True "prehole: non-empty string" (($hm -is [string]) -and ($hm.Length -gt 0))
Assert-True "prehole: one ProCmdHole" ((Count-Token $hm 'ProCmdHole') -eq 1)
Assert-True "prehole: confirms with one dashInst0.Done" ((Count-Token $hm 'dashInst0.Done') -eq 1)
# The refs are PRE-SELECTED before the command, so the macro carries NO collector/page tokens.
Assert-True "prehole: NO placement-page triggers (refs are pre-selected)" (-not ($hm -match 'hole_fb_plcmnt_page'))
Assert-True "prehole: NO prim_ref collector" (-not ($hm -match 'PH\.ui_hole_prim_ref_cui_lst'))
Assert-True "prehole: NO ft_dir collector" (-not ($hm -match 'PH\.ui_hole_ft_dir_cui_lst'))
# MATCH RECORDING EXACTLY: NO diameter / thru-all / target-body tokens.
Assert-True "prehole: NO diameter token (inherits Creo's setting)" (-not ($hm -match 'diameter_mip_OptionMenu'))
Assert-True "prehole: NO thru-all token" (-not ($hm -match 'StrHoleDepThruAllF'))
Assert-True "prehole: NO target-body token" (-not ($hm -match 'bodyselectrepwdg_list'))

# ============================================================================
# Add-ComponentDefaultPlanesToBuffer  --  NEW path-qualified component-subitem select
# (also exercises the shared Resolve-ComponentLeafModel + Select-ComponentPlaneById below)
# ============================================================================
Write-Host "  -- Add-ComponentDefaultPlanesToBuffer (path-qualified component planes) --" -ForegroundColor White

# ITEM_* constants (arbitrary distinct ints; the reader compares against $TypeObj)
$cfhType = [pscustomobject]@{ ITEM_FEATURE = 901; ITEM_SURFACE = 904; ITEM_POINT = 905 }

# a fake datum-plane feature: .Id + a role name via GetName().
function New-FakePlane { param([int]$Id, [string]$Name)
    $f = [pscustomobject]@{ Id = $Id }
    Add-Member -InputObject $f -MemberType NoteProperty -Name _nm -Value $Name
    Add-Member -InputObject $f -MemberType ScriptMethod -Name GetName -Value { return [string]$this._nm }
    return $f
}
# the component's own solid model. PRIMARY: GetItemById(ITEM_FEATURE, 1/3/5) returns
# the TOP/SIDE/FRONT planes (the constant-id fact from fastenerplane-probe.cmd).
# SECONDARY: ListItems(ITEM_FEATURE) for the name-match fallback (used only when the
# constant ids do not resolve). $script:-scoped so the fake ScriptMethod bodies below
# resolve it (a ScriptMethod body reads $script:, NOT a bare script-file local).
$script:cfhCompModel = [pscustomobject]@{}
Add-Member -InputObject $script:cfhCompModel -MemberType ScriptMethod -Name GetItemById -Value {
    param($t, $id)
    if ([int]$t -eq 901) {
        switch ([int]$id) {
            1 { return (New-FakePlane -Id 1 -Name 'TOP') }
            3 { return (New-FakePlane -Id 3 -Name 'SIDE') }
            5 { return (New-FakePlane -Id 5 -Name 'FRONT') }
        }
    }
    return $null
}
Add-Member -InputObject $script:cfhCompModel -MemberType ScriptMethod -Name ListItems -Value {
    param($t)
    if ([int]$t -eq 901) {
        return @(
            (New-FakePlane -Id 12 -Name 'DTM_SIDE'),
            (New-FakePlane -Id 13 -Name 'FRONT'),
            (New-FakePlane -Id 11 -Name 'TOP'),
            (New-FakePlane -Id 99 -Name 'SOME_OTHER_FEATURE')
        )
    }
    return @()
}
# the fastener component path: .Leaf.GetModel() -> $script:cfhCompModel.
$fakeLeaf = [pscustomobject]@{}
Add-Member -InputObject $fakeLeaf -MemberType ScriptMethod -Name GetModel -Value { $script:cfhCompModel } -Force
$script:cfhFakeLeaf = $fakeLeaf
$fakeCompPath = [pscustomobject]@{}
Add-Member -InputObject $fakeCompPath -MemberType ScriptProperty -Name Leaf -Value { $script:cfhFakeLeaf }

# the fake selection buffer: records AddSelection'd items; Clear resets.
$script:cfhAdded = @()
$script:cfhCleared = 0
$fakeBuf = [pscustomobject]@{}
Add-Member -InputObject $fakeBuf -MemberType ScriptMethod -Name Clear -Value { $script:cfhAdded = @(); $script:cfhCleared++ }
Add-Member -InputObject $fakeBuf -MemberType ScriptMethod -Name AddSelection -Value { param($sel) $script:cfhAdded += ,$sel }

# the fake session: CurrentSelectionBuffer -> $fakeBuf.
$fakeSession = [pscustomobject]@{}
Add-Member -InputObject $fakeSession -MemberType ScriptMethod -Name CurrentSelectionBuffer -Value { $fakeBuf }

# the fake CMpfcSelect factory: CreateModelItemSelection($item,$path) records the args
# and returns a marker so AddSelection has something to capture. We shadow the named
# Get-ComSelectFactory helper (the repo's proven stub pattern -- see how
# run_conformal_blank_tests.ps1 shadows Wait-ModelModified / Invoke-ForceRegen).
$script:cfhSelArgs = @()
$fakeFactory = [pscustomobject]@{}
Add-Member -InputObject $fakeFactory -MemberType ScriptMethod -Name CreateModelItemSelection -Value {
    param($item, $path)
    $script:cfhSelArgs += ,([pscustomobject]@{ ItemId = ([int]$item.Id); Path = $path })
    return ([pscustomobject]@{ SelItem = $item; Path = $path })
}
function Get-ComSelectFactory { return $fakeFactory }

# HAPPY path: the 3 role planes resolve by CONSTANT feature id (1/3/5), path-qualified,
# accumulated in Top/Side/Front order.
$script:cfhAdded = @(); $script:cfhSelArgs = @(); $script:cfhCleared = 0
$r = Add-ComponentDefaultPlanesToBuffer -Session $fakeSession -Model $null -TypeObj $cfhType -ComponentPath $fakeCompPath
Assert-True "addplanes: Added == 3" (([int](Get-Field $r @('Added'))) -eq 3)
$roles = @(Get-Field $r @('Roles'))
Assert-True "addplanes: roles ordered Top/Side/Front" (($roles[0] -eq 'Top') -and ($roles[1] -eq 'Side') -and ($roles[2] -eq 'Front'))
$ids = @(Get-Field $r @('Ids'))
Assert-True "addplanes: ids are the CONSTANT feature ids (1 Top, 3 Side, 5 Front)" (($ids[0] -eq 1) -and ($ids[1] -eq 3) -and ($ids[2] -eq 5))
Assert-True "addplanes: buffer was cleared first (default)" ($script:cfhCleared -eq 1)
Assert-True "addplanes: 3 selections AddSelection'd" (@($script:cfhAdded).Count -eq 3)
# THE KEY NEW BEHAVIOR: the COMPONENT PATH is passed as the 2nd arg (NOT $null).
Assert-True "addplanes: CreateModelItemSelection got the component PATH as the 2nd arg" (@($script:cfhSelArgs).Count -eq 3 -and $null -ne $script:cfhSelArgs[0].Path)
Assert-True "addplanes: the path passed IS the fastener's component path" ([object]::ReferenceEquals($script:cfhSelArgs[0].Path, $fakeCompPath))

# LIVE-BUILD PATTERN (fastenerplane-probe.cmd SECTION 3, 2026-07-28): $ComponentPath.Leaf IS
# the solid model directly (answers GetItemById; NO .GetModel()) -- hole_layout.ps1 proves
# Path.Leaf is used as a model. The resolver MUST accept Leaf-as-model, not require .GetModel()
# (the old code's .GetModel() on a solid returned null -> the live "could not resolve" miss).
$script:cfhLeafModel = [pscustomobject]@{}
Add-Member -InputObject $script:cfhLeafModel -MemberType ScriptMethod -Name GetItemById -Value {
    param($t,$id)
    if ([int]$t -eq 901) {
        switch ([int]$id) {
            1 { return (New-FakePlane -Id 1 -Name 'TOP') }
            3 { return (New-FakePlane -Id 3 -Name 'SIDE') }
            5 { return (New-FakePlane -Id 5 -Name 'FRONT') }
        }
    }
    return $null
}
# deliberately NO GetModel member -> mirrors a real IpfcSolid (calling .GetModel() on it fails).
$leafIsModelPath = [pscustomobject]@{}
Add-Member -InputObject $leafIsModelPath -MemberType ScriptProperty -Name Leaf -Value { $script:cfhLeafModel }
$script:cfhAdded = @(); $script:cfhSelArgs = @(); $script:cfhCleared = 0
$rL = Add-ComponentDefaultPlanesToBuffer -Session $fakeSession -Model $null -TypeObj $cfhType -ComponentPath $leafIsModelPath
Assert-True "addplanes(Leaf IS model): Added == 3 (resolver uses Leaf-as-model, not .GetModel())" (([int](Get-Field $rL @('Added'))) -eq 3)
$lIds = @(Get-Field $rL @('Ids'))
Assert-True "addplanes(Leaf IS model): constant ids 1/3/5" (($lIds[0] -eq 1) -and ($lIds[1] -eq 3) -and ($lIds[2] -eq 5))

# WRONG-MODEL GUARD: if Leaf resolves to a model whose feature ids 1/3/5 are NOT named
# TOP/SIDE/FRONT (e.g. the root ASSEMBLY), the by-id picks must be REJECTED by the name check
# (a wrong-model point would falsely pass the point canary). Here ids 1/3/5 resolve but to
# mis-named datums -> the constant-id picks are rejected; the name-walk secondary also finds
# nothing role-named -> Added 0 (forces the manual fallback).
$script:cfhWrongModel = [pscustomobject]@{}
Add-Member -InputObject $script:cfhWrongModel -MemberType ScriptMethod -Name GetItemById -Value {
    param($t,$id)
    if ([int]$t -eq 901) {
        switch ([int]$id) {
            1 { return (New-FakePlane -Id 1 -Name 'ASM_DEF_CSYS') }
            3 { return (New-FakePlane -Id 3 -Name 'A_1') }
            5 { return (New-FakePlane -Id 5 -Name 'A_2') }
        }
    }
    return $null
}
Add-Member -InputObject $script:cfhWrongModel -MemberType ScriptMethod -Name ListItems -Value {
    param($t) if ([int]$t -eq 901) { return @((New-FakePlane -Id 1 -Name 'ASM_DEF_CSYS'),(New-FakePlane -Id 3 -Name 'A_1'),(New-FakePlane -Id 5 -Name 'A_2')) } return @()
}
$wrongPath = [pscustomobject]@{}
Add-Member -InputObject $wrongPath -MemberType ScriptProperty -Name Leaf -Value { $script:cfhWrongModel }
$script:cfhAdded = @(); $script:cfhSelArgs = @(); $script:cfhCleared = 0
$rW = Add-ComponentDefaultPlanesToBuffer -Session $fakeSession -Model $null -TypeObj $cfhType -ComponentPath $wrongPath
Assert-True "addplanes(wrong-model names): Added == 0 (mis-named ids 1/3/5 rejected by the name check)" (([int](Get-Field $rW @('Added'))) -eq 0)

# PARTIAL-SELECTION GUARD: a component that resolves only 2 of 3 planes must CLEAR the
# buffer and return Added=0 (never leave a degenerate 1-2 plane set for the point macro).
$script:cfhPartModel = [pscustomobject]@{}
Add-Member -InputObject $script:cfhPartModel -MemberType ScriptMethod -Name GetItemById -Value {
    param($t,$id) if ([int]$t -eq 901) { switch ([int]$id) { 1 { return (New-FakePlane -Id 1 -Name 'TOP') } 3 { return (New-FakePlane -Id 3 -Name 'SIDE') } } } return $null   # NO id 5
}
Add-Member -InputObject $script:cfhPartModel -MemberType ScriptMethod -Name ListItems -Value {
    param($t) if ([int]$t -eq 901) { return @((New-FakePlane -Id 1 -Name 'TOP'),(New-FakePlane -Id 3 -Name 'SIDE')) } return @()   # only 2 by name too
}
$script:cfhPartLeaf = [pscustomobject]@{}
Add-Member -InputObject $script:cfhPartLeaf -MemberType ScriptMethod -Name GetModel -Value { $script:cfhPartModel } -Force
$partPath = [pscustomobject]@{}
Add-Member -InputObject $partPath -MemberType ScriptProperty -Name Leaf -Value { $script:cfhPartLeaf }
$script:cfhAdded = @(); $script:cfhSelArgs = @(); $script:cfhCleared = 0
$rP = Add-ComponentDefaultPlanesToBuffer -Session $fakeSession -Model $null -TypeObj $cfhType -ComponentPath $partPath
Assert-True "addplanes(partial 2/3): Added forced to 0" (([int](Get-Field $rP @('Added'))) -eq 0)
Assert-True "addplanes(partial 2/3): buffer was cleared to discard the partial set" ($script:cfhCleared -ge 2)
Assert-True "addplanes(partial 2/3): a Reason names the partial clear" ((([string](Get-Field $rP @('Reason'))) -match 'partial'))

# -NoClear: does NOT clear the buffer (accumulate onto an existing selection).
$script:cfhAdded = @(); $script:cfhSelArgs = @(); $script:cfhCleared = 0
$rNC = Add-ComponentDefaultPlanesToBuffer -Session $fakeSession -Model $null -TypeObj $cfhType -ComponentPath $fakeCompPath -NoClear
Assert-True "addplanes(-NoClear): did NOT clear the buffer" ($script:cfhCleared -eq 0)
Assert-True "addplanes(-NoClear): still added 3" (([int](Get-Field $rNC @('Added'))) -eq 3)

# DEGRADE: null path -> Added 0 + Reason, no throw.
$threw = $false; $rNull = $null
try { $rNull = Add-ComponentDefaultPlanesToBuffer -Session $fakeSession -Model $null -TypeObj $cfhType -ComponentPath $null } catch { $threw = $true }
Assert-True "addplanes(null path): did NOT throw" (-not $threw)
Assert-True "addplanes(null path): Added 0" (([int](Get-Field $rNull @('Added'))) -eq 0)
Assert-True "addplanes(null path): a Reason is set" (-not [string]::IsNullOrEmpty([string](Get-Field $rNull @('Reason'))))

# SECONDARY fallback: GetItemById returns null (non-default fastener) -> the name-match
# ListItems walk resolves TOP/SIDE/FRONT (ids 11/12/13 from the fake ListItems above).
$script:cfhNoIdModel = [pscustomobject]@{}
Add-Member -InputObject $script:cfhNoIdModel -MemberType ScriptMethod -Name GetItemById -Value { param($t,$id) return $null }
Add-Member -InputObject $script:cfhNoIdModel -MemberType ScriptMethod -Name ListItems -Value {
    param($t)
    if ([int]$t -eq 901) { return @((New-FakePlane -Id 12 -Name 'SIDE'),(New-FakePlane -Id 13 -Name 'FRONT'),(New-FakePlane -Id 11 -Name 'TOP')) }
    return @()
}
$script:cfhNoIdLeaf = [pscustomobject]@{}
Add-Member -InputObject $script:cfhNoIdLeaf -MemberType ScriptMethod -Name GetModel -Value { $script:cfhNoIdModel } -Force
$noIdPath = [pscustomobject]@{}
Add-Member -InputObject $noIdPath -MemberType ScriptProperty -Name Leaf -Value { $script:cfhNoIdLeaf }
$script:cfhAdded = @(); $script:cfhSelArgs = @(); $script:cfhCleared = 0
$rSec = Add-ComponentDefaultPlanesToBuffer -Session $fakeSession -Model $null -TypeObj $cfhType -ComponentPath $noIdPath
Assert-True "addplanes(secondary/name-walk): Added == 3 when constant ids miss" (([int](Get-Field $rSec @('Added'))) -eq 3)
$secRoles = @(Get-Field $rSec @('Roles'))
Assert-True "addplanes(secondary): roles resolved Top/Side/Front by name" (($secRoles -contains 'Top') -and ($secRoles -contains 'Side') -and ($secRoles -contains 'Front'))

# DEGRADE: a component whose model throws on BOTH GetItemById and ListItems -> Added 0 + Reason, no throw.
$script:cfhThrowModel = [pscustomobject]@{}
Add-Member -InputObject $script:cfhThrowModel -MemberType ScriptMethod -Name GetItemById -Value { param($t,$id) throw "boom-id" }
Add-Member -InputObject $script:cfhThrowModel -MemberType ScriptMethod -Name ListItems -Value { param($t) throw "boom" }
$script:cfhThrowLeaf = [pscustomobject]@{}
Add-Member -InputObject $script:cfhThrowLeaf -MemberType ScriptMethod -Name GetModel -Value { $script:cfhThrowModel } -Force
$throwPath = [pscustomobject]@{}
Add-Member -InputObject $throwPath -MemberType ScriptProperty -Name Leaf -Value { $script:cfhThrowLeaf }
$threw2 = $false; $rThrow = $null
try { $rThrow = Add-ComponentDefaultPlanesToBuffer -Session $fakeSession -Model $null -TypeObj $cfhType -ComponentPath $throwPath } catch { $threw2 = $true }
Assert-True "addplanes(throwing model): did NOT throw" (-not $threw2)
Assert-True "addplanes(throwing model): Added 0 + a Reason" ((([int](Get-Field $rThrow @('Added'))) -eq 0) -and (-not [string]::IsNullOrEmpty([string](Get-Field $rThrow @('Reason')))))

# ============================================================================
# Resolve-ComponentLeafModel  --  Leaf-as-model, then Leaf.GetModel() fallback
# (shared resolver; uses the fakes set up above)
# ============================================================================
Write-Host "  -- Resolve-ComponentLeafModel (Leaf-as-model / GetModel fallback) --" -ForegroundColor White
# (a) Leaf IS the model (answers GetItemById directly -- the live build shape).
$leafModelPath = [pscustomobject]@{}
Add-Member -InputObject $leafModelPath -MemberType ScriptProperty -Name Leaf -Value { $script:cfhLeafModel2 }
$script:cfhLeafModel2 = [pscustomobject]@{}
Add-Member -InputObject $script:cfhLeafModel2 -MemberType ScriptMethod -Name GetItemById -Value { param($t,$id) if ([int]$t -eq 901 -and [int]$id -eq 1) { return (New-FakePlane -Id 1 -Name 'TOP') } return $null }
$rlm1 = Resolve-ComponentLeafModel -ComponentPath $leafModelPath -TypeObj $cfhType
Assert-True "leafmodel(Leaf-as-model): returns the leaf when it resolves feature 1" ([object]::ReferenceEquals($rlm1, $script:cfhLeafModel2))
# (b) Leaf wraps the model via GetModel() (the fakeCompPath -> fakeLeaf -> cfhCompModel above).
$rlm2 = Resolve-ComponentLeafModel -ComponentPath $fakeCompPath -TypeObj $cfhType
Assert-True "leafmodel(GetModel fallback): resolves the wrapped model" ([object]::ReferenceEquals($rlm2, $script:cfhCompModel))
# (c) null path -> $null, never throws.
$threwLM = $false; $rlm0 = 'x'; try { $rlm0 = Resolve-ComponentLeafModel -ComponentPath $null -TypeObj $cfhType } catch { $threwLM = $true }
Assert-True "leafmodel(null path): did NOT throw" (-not $threwLM)
Assert-True "leafmodel(null path): returns null" ($null -eq $rlm0)

# ============================================================================
# Select-ComponentPlaneById  --  path-qualify ONE plane into the buffer (the TOP-plane -> ft_dir feed)
# ============================================================================
Write-Host "  -- Select-ComponentPlaneById (TOP plane -> ft_dir, name-verified) --" -ForegroundColor White
# happy: TOP plane (id 1) name-confirms -> Ok, path-qualified, buffer cleared then added.
$script:cfhAdded = @(); $script:cfhSelArgs = @(); $script:cfhCleared = 0
$sp = Select-ComponentPlaneById -Session $fakeSession -TypeObj $cfhType -ComponentPath $fakeCompPath -PlaneId 1 -Role 'Top'
Assert-True "selplane(Top): Ok" ([bool](Get-Field $sp @('Ok')))
Assert-True "selplane(Top): Id == 1" (([int](Get-Field $sp @('Id'))) -eq 1)
Assert-True "selplane(Top): one AddSelection" (@($script:cfhAdded).Count -eq 1)
Assert-True "selplane(Top): passed the component PATH as the 2nd arg" (@($script:cfhSelArgs).Count -eq 1 -and [object]::ReferenceEquals($script:cfhSelArgs[0].Path, $fakeCompPath))
Assert-True "selplane(Top): cleared the buffer first (default)" ($script:cfhCleared -eq 1)
# -NoClear: accumulate onto an existing selection.
$script:cfhAdded = @(); $script:cfhCleared = 0
$spNC = Select-ComponentPlaneById -Session $fakeSession -TypeObj $cfhType -ComponentPath $fakeCompPath -PlaneId 1 -Role 'Top' -NoClear
Assert-True "selplane(-NoClear): did NOT clear" ($script:cfhCleared -eq 0)
Assert-True "selplane(-NoClear): still Ok" ([bool](Get-Field $spNC @('Ok')))
# name-mismatch REJECT: id 1 resolves but is NOT named a TOP role (wrong model) -> Ok false, nothing added.
$script:cfhAdded = @(); $script:cfhCleared = 0
$spWrong = Select-ComponentPlaneById -Session $fakeSession -TypeObj $cfhType -ComponentPath $wrongPath -PlaneId 1 -Role 'Top'
Assert-True "selplane(wrong name): Ok false (name did not confirm the role)" (-not [bool](Get-Field $spWrong @('Ok')))
Assert-True "selplane(wrong name): nothing AddSelection'd" (@($script:cfhAdded).Count -eq 0)
# degrade: null path -> Ok false + Reason, never throws.
$threwSP = $false; $spN = $null
try { $spN = Select-ComponentPlaneById -Session $fakeSession -TypeObj $cfhType -ComponentPath $null -PlaneId 1 -Role 'Top' } catch { $threwSP = $true }
Assert-True "selplane(null path): did NOT throw" (-not $threwSP)
Assert-True "selplane(null path): Ok false + Reason" ((-not [bool](Get-Field $spN @('Ok'))) -and (-not [string]::IsNullOrEmpty([string](Get-Field $spN @('Reason')))))

# ============================================================================
# Get-BufferComponentPath  --  live fresh-path read from the selection buffer
# (the loop uses this to avoid a stale stored $comp.Path handle)
# ============================================================================
Write-Host "  -- Get-BufferComponentPath (fresh path from the buffer) --" -ForegroundColor White
# a fake buffer whose Contents is settable per-case.
$script:gbcpContents = @()
$gbcpBuf = [pscustomobject]@{}
# Contents is a PROPERTY on the real buffer (Resolve-SelectedPlaneIds + the probe read
# ($session.CurrentSelectionBuffer()).Contents without parens), so fake it as a ScriptProperty.
Add-Member -InputObject $gbcpBuf -MemberType ScriptProperty -Name Contents -Value { $script:gbcpContents } -Force
$gbcpSession = [pscustomobject]@{}
Add-Member -InputObject $gbcpSession -MemberType ScriptMethod -Name CurrentSelectionBuffer -Value { $gbcpBuf } -Force
# a selection whose .Path carries ComponentIds (a path-qualified plane).
$gbcpPath = [pscustomobject]@{ ComponentIds = @(76) }
$gbcpSelWithPath = [pscustomobject]@{ Path = $gbcpPath }
# a selection with NO path (a local datum point) -> must be skipped.
$gbcpSelNoPath = [pscustomobject]@{ Path = $null }
# case 1: buffer holds a path-qualified item -> returns its Path.
$script:gbcpContents = @($gbcpSelNoPath, $gbcpSelWithPath)
$g1 = Get-BufferComponentPath -Session $gbcpSession
Assert-True "bufpath: returns the first path with ComponentIds (skips the no-path point)" ([object]::ReferenceEquals($g1, $gbcpPath))
# case 2: buffer holds only a no-path item -> $null.
$script:gbcpContents = @($gbcpSelNoPath)
$g2 = Get-BufferComponentPath -Session $gbcpSession
Assert-True "bufpath: no path-qualified item -> null" ($null -eq $g2)
# case 3: null session -> $null, never throws.
$threwG = $false; $g3 = 'x'; try { $g3 = Get-BufferComponentPath -Session $null } catch { $threwG = $true }
Assert-True "bufpath(null session): did NOT throw" (-not $threwG)
Assert-True "bufpath(null session): returns null" ($null -eq $g3)

# ============================================================================
# Resolve-SelectedPlaneIds / Resolve-NewDatumPointIds  --  ID-only buffer reads
# ============================================================================
Write-Host "  -- Resolve-SelectedPlaneIds / Resolve-NewDatumPointIds (ID-only) --" -ForegroundColor White

# a fake SelItem whose .Point THROWS (proves the reader never touches it).
function New-SelItem { param([int]$Id, [int]$Type, [string]$Name = '')
    $si = [pscustomobject]@{ Id = $Id; Type = $Type }
    Add-Member -InputObject $si -MemberType ScriptProperty -Name Point -Value { throw "IpfcPoint.Point must NOT be read (ID-only)" }
    Add-Member -InputObject $si -MemberType NoteProperty -Name _nm -Value $Name
    Add-Member -InputObject $si -MemberType ScriptMethod -Name GetName -Value { return [string]$this._nm }
    return $si
}
function New-BufItem { param($SelItem) $it = [pscustomobject]@{}; Add-Member -InputObject $it -MemberType NoteProperty -Name SelItem -Value $SelItem; return $it }

$script:cfhBuffer = @(
    (New-BufItem (New-SelItem -Id 11 -Type 904 -Name 'TOP')),
    (New-BufItem (New-SelItem -Id 12 -Type 904 -Name 'SIDE')),
    (New-BufItem (New-SelItem -Id 11 -Type 904 -Name 'TOP')),   # DUP
    (New-BufItem (New-SelItem -Id 13 -Type 904 -Name 'FRONT'))
)
$plSession = [pscustomobject]@{}
Add-Member -InputObject $plSession -MemberType ScriptMethod -Name CurrentSelectionBuffer -Value {
    $buf = [pscustomobject]@{}
    Add-Member -InputObject $buf -MemberType ScriptProperty -Name Contents -Value { $script:cfhBuffer }
    return $buf
}
$rpl = Resolve-SelectedPlaneIds -Session $plSession -TypeObj $cfhType
$plIds = @(Get-Field $rpl @('Ids'))
Assert-True "planeids: 3 distinct plane ids (deduped)" ($plIds.Count -eq 3)
Assert-True "planeids: contains 11/12/13" (($plIds -contains 11) -and ($plIds -contains 12) -and ($plIds -contains 13))
$plRoles = @(Get-Field $rpl @('Roles'))
Assert-True "planeids: roles resolved (Top/Side/Front by name)" (($plRoles -contains 'Top') -and ($plRoles -contains 'Side') -and ($plRoles -contains 'Front'))

# null buffer -> empty, no throw.
$script:cfhBuffer = $null
$threw3 = $false; $rEmpty = $null
try { $rEmpty = Resolve-SelectedPlaneIds -Session $plSession -TypeObj $cfhType } catch { $threw3 = $true }
Assert-True "planeids: null buffer did NOT throw" (-not $threw3)
Assert-True "planeids: null buffer -> 0 ids" ((@(Get-Field $rEmpty @('Ids'))).Count -eq 0)

# Resolve-NewDatumPointIds: only ids NOT in the before-set, as ints.
$ptModel = [pscustomobject]@{}
Add-Member -InputObject $ptModel -MemberType ScriptMethod -Name ListItems -Value {
    param($t) if ([int]$t -eq 905) { return @([pscustomobject]@{Id=201},[pscustomobject]@{Id=202},[pscustomobject]@{Id=203}) } return @()
}
$before = @{ 201 = $true }
$newPts = @(Resolve-NewDatumPointIds -Model $ptModel -TypeObj $cfhType -Before $before)
Assert-True "newpts: only the 2 new point ids (202,203)" (($newPts.Count -eq 2) -and ($newPts -contains 202) -and ($newPts -contains 203))
Assert-True "newpts: excludes the pre-existing 201" (-not ($newPts -contains 201))

# ============================================================================
# Invoke-FastenerPoint  --  robust point canary (new point id OR VersionStamp move)
# ============================================================================
Write-Host "  -- Invoke-FastenerPoint (robust canary: point id OR VersionStamp) --" -ForegroundColor White
# Wait-ModelModified is a drilljig_core COM waiter; shadow it deterministically here.
function Wait-ModelModified { param($Model,$PreviousStamp,$TimeoutMs=30000,$OnPoll=$null) if ($null -ne $OnPoll) { try { & $OnPoll } catch {} } return $script:ifpStampMoves }
$script:ifpStampMoves = $false

# SIGNAL 1 (part-active): a NEW ITEM_POINT id appears -> Created + PointId, no stamp needed.
$script:ifpPts = @(201)
$ifpModel = [pscustomobject]@{ VersionStamp = 'v0' }
Add-Member -InputObject $ifpModel -MemberType ScriptMethod -Name ListItems -Value {
    param($t) if ([int]$t -eq 905) { return @($script:ifpPts | ForEach-Object { [pscustomobject]@{ Id = [int]$_ } }) } return @()
}
$ifpSession = [pscustomobject]@{}
Add-Member -InputObject $ifpSession -MemberType ScriptMethod -Name RunMacro -Value { param($m) $script:ifpPts = @(201, 202) }   # a new point 202 appears
$r1 = Invoke-FastenerPoint -Session $ifpSession -Model $ifpModel -TypeObj $cfhType
Assert-True "fastpoint(new id): Created" ([bool](Get-Field $r1 @('Created')))
Assert-True "fastpoint(new id): PointId == 202" (([int](Get-Field $r1 @('PointId'))) -eq 202)
Assert-True "fastpoint(new id): not ViaStamp (id was enumerable)" (-not [bool](Get-Field $r1 @('ViaStamp')))

# SIGNAL 2 (assembly-active): NO new ITEM_POINT id (ListItems blind), but the VersionStamp
# MOVES -> Created via stamp, PointId 0. This is the false-miss the probe exposed.
$script:ifpPts = @(201)                 # ListItems never grows (assembly blind)
$script:ifpStampMoves = $true           # but the stamp moves
$ifpSession2 = [pscustomobject]@{}
Add-Member -InputObject $ifpSession2 -MemberType ScriptMethod -Name RunMacro -Value { param($m) }   # point lands in the PART; assembly ListItems stays 0
$r2 = Invoke-FastenerPoint -Session $ifpSession2 -Model $ifpModel -TypeObj $cfhType
Assert-True "fastpoint(stamp only): Created (VersionStamp move accepted)" ([bool](Get-Field $r2 @('Created')))
Assert-True "fastpoint(stamp only): ViaStamp" ([bool](Get-Field $r2 @('ViaStamp')))
Assert-True "fastpoint(stamp only): PointId 0 (not enumerable on the assembly)" (([int](Get-Field $r2 @('PointId'))) -eq 0)

# MISS: no new id AND no stamp move -> Created false + Reason.
$script:ifpPts = @(201)
$script:ifpStampMoves = $false
$r3 = Invoke-FastenerPoint -Session $ifpSession2 -Model $ifpModel -TypeObj $cfhType
Assert-True "fastpoint(miss): Created false" (-not [bool](Get-Field $r3 @('Created')))
Assert-True "fastpoint(miss): a Reason is set" (-not [string]::IsNullOrEmpty([string](Get-Field $r3 @('Reason'))))

# ============================================================================
# SUMMARY
# ============================================================================
Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ("  curved-fastener-hole tests: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { "Green" } else { "Red" })
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ""
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
