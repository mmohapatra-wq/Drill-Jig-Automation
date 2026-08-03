# ============================================================================
# lib\tests\run_curved_relief_tests.ps1 - offline unit tests for lib\curved_relief.ps1
# ============================================================================
# curved_relief.ps1 is the TOP-plane SYMMETRIC chip-relief engine for the curved
# drill jig: PURE macro builders (Build-CurvedReliefOpenMacro / RectMacro / the
# composed ArmMacro / CutMacro) + one COM driver (Invoke-FastenerRelief). The pure
# builders are asserted directly (the split open/rect token sets + order + the
# 2x-relief depth doubling). The driver is exercised against a FAKE session/model +
# stubbed Get-FeatureIdSet / Wait-ModelModified (the same fake-COM approach as
# fuzz_curved_gui.ps1) so its open -> plane-pick -> rect -> draw -> cut flow + canary
# is covered without Creo. The plane is picked ON SCREEN now (no raw-COM pre-select),
# so there is no Select-ComponentPlaneById stub and ViaPlane is always false.
#
# Run:  powershell -ExecutionPolicy Bypass -File lib\tests\run_curved_relief_tests.ps1
# Exit 0 = all pass.
# ============================================================================

$ErrorActionPreference = "Stop"
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here

$script:pass = 0; $script:fail = 0
function Assert-True { param([string]$Name, [bool]$Cond, [string]$Detail = "")
    if ($Cond) { Write-Host "  [PASS] $Name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  [FAIL] $Name  $Detail" -ForegroundColor Red; $script:fail++ }
}

# ----------------------------------------------------------------------------
# Dependencies. curved_relief.ps1 calls Get-FeatureIdSet / Wait-ModelModified
# (drilljig_core, non-global) + Select-ComponentPlaneById / Get-ComSelectFactory
# (curved_fastener_hole). For the pure-builder tests we only need the builders; for
# the driver tests we STUB the COM-touching helpers as globals (so the driver's
# calls resolve to canned returns). Dot-source drilljig_core + curved_fastener_hole
# first so their real (non-stubbed) helpers exist, then override the COM ones.
# ----------------------------------------------------------------------------
foreach ($dep in @('creo_geometry.ps1','orthogrid.ps1','orthogrid_points.ps1','drilljig_core.ps1','conformal_blank.ps1','curved_fastener_hole.ps1')) {
    $p = Join-Path $libDir $dep
    if (Test-Path $p) { try { . $p } catch {} }
}
. (Join-Path $libDir 'curved_relief.ps1')

# ============================================================================
# 1. SPLIT arm macros (PURE): Open (extrude only) + Rect (view + rectangle), plus the
#    composed Build-CurvedReliefArmMacro wrapper. The split is the fix for the
#    "sketch opens then immediately extrudes" bug: the open macro fires, the operator
#    picks the plane, THEN the rect macro arms on the now-open sketch (the old one-shot
#    open+view+rectangle fired the rectangle into the plane-reject error state).
#    See [[project_curved_relief_extrude_plane]].
# ============================================================================
Write-Host ""
Write-Host "  -- Build-CurvedReliefOpenMacro / RectMacro / ArmMacro (pure) --" -ForegroundColor White
$open = Build-CurvedReliefOpenMacro
Assert-True "open: opens ProCmdFtExtrude"        ($open -match 'ProCmdFtExtrude')
# the open macro must NOT arm the view/rectangle (those wait for the plane pick).
Assert-True "open: does NOT orient the view yet" (-not ($open -match 'ProCmdViewSketchView')) "(view waits for the plane pick)"
Assert-True "open: does NOT arm the rectangle yet" (-not ($open -match 'ProCmdSketSlantRectangle')) "(rectangle waits for the plane pick)"
# the open macro must NOT tree-search / pre-select a plane (the operator picks it on screen).
Assert-True "open: does NOT tree-search for the plane" (-not ($open -match 'ProCmdMdlTreeSearch')) "(operator picks the plane on screen)"

$rect = Build-CurvedReliefRectMacro
Assert-True "rect: orients ProCmdViewSketchView" ($rect -match 'ProCmdViewSketchView')
Assert-True "rect: arms ProCmdSketSlantRectangle"     ($rect -match 'ProCmdSketSlantRectangle')
Assert-True "rect: does NOT re-open the extrude"  (-not ($rect -match 'ProCmdFtExtrude')) "(the extrude is already open)"
$iRView = $rect.IndexOf('ProCmdViewSketchView'); $iRRect = $rect.IndexOf('ProCmdSketSlantRectangle')
Assert-True "rect: order = ViewSketchView -> Rectangle" (($iRView -lt $iRRect)) ("(view=$iRView rect=$iRRect)")

# the composed wrapper still exposes the full Extrude -> ViewSketchView -> Rectangle order.
$arm = Build-CurvedReliefArmMacro
Assert-True "arm: opens ProCmdFtExtrude"        ($arm -match 'ProCmdFtExtrude')
Assert-True "arm: orients ProCmdViewSketchView" ($arm -match 'ProCmdViewSketchView')
Assert-True "arm: arms ProCmdSketSlantRectangle"     ($arm -match 'ProCmdSketSlantRectangle')
$iExt = $arm.IndexOf('ProCmdFtExtrude'); $iView = $arm.IndexOf('ProCmdViewSketchView'); $iRect = $arm.IndexOf('ProCmdSketSlantRectangle')
Assert-True "arm: order = Extrude -> ViewSketchView -> Rectangle" (($iExt -lt $iView) -and ($iView -lt $iRect)) ("(ext=$iExt view=$iView rect=$iRect)")
Assert-True "arm: does NOT tree-search for the plane" (-not ($arm -match 'ProCmdMdlTreeSearch')) "(operator picks the plane on screen)"

# ============================================================================
# 1b. Build-CurvedReliefOpenByIdMacro (PURE) - HANDS-FREE open on a jig-part plane by id.
#     Mirrors the proven Invoke-VerifiedSeedCut FACE channel: tree-search the plane by
#     Feature id (Get-SelectByIdMacro), ProCmdFtExtrude, then arm the rectangle in ONE
#     shot (the plane is pre-selected). PlaneId<=0 -> "" (caller falls back).
# ============================================================================
Write-Host ""
Write-Host "  -- Build-CurvedReliefOpenByIdMacro (pure) --" -ForegroundColor White
$openById = Build-CurvedReliefOpenByIdMacro -PlaneId 942
Assert-True "open-by-id: tree-searches the plane by id (ProCmdMdlTreeSearch)" ($openById -match 'ProCmdMdlTreeSearch')
Assert-True "open-by-id: feeds the plane id 942"        ($openById -match '942')
Assert-True "open-by-id: opens ProCmdFtExtrude"         ($openById -match 'ProCmdFtExtrude')
Assert-True "open-by-id: arms the rectangle in one shot" ($openById -match 'ProCmdSketSlantRectangle')
# ORDER: select-by-id (tree search) BEFORE the extrude BEFORE the rectangle.
$iSel = $openById.IndexOf('ProCmdMdlTreeSearch'); $iOe = $openById.IndexOf('ProCmdFtExtrude'); $iOr = $openById.IndexOf('ProCmdSketSlantRectangle')
Assert-True "open-by-id: order = SelectById -> Extrude -> Rectangle" (($iSel -lt $iOe) -and ($iOe -lt $iOr)) ("(sel=$iSel ext=$iOe rect=$iOr)")
Assert-True "open-by-id: PlaneId<=0 -> empty string (caller falls back)" ([string]::IsNullOrEmpty((Build-CurvedReliefOpenByIdMacro -PlaneId 0)))

# ============================================================================
# 1c. Build-OffsetPlaneOnPreselectedMacro (PURE) - offset a datum plane from the plane
#     ALREADY in the buffer (a raw-COM pre-selected component plane); no tree-search.
# ============================================================================
Write-Host ""
Write-Host "  -- Build-OffsetPlaneOnPreselectedMacro (pure) --" -ForegroundColor White
$offNB = ((Build-OffsetPlaneOnPreselectedMacro -Offset 0.375) -replace '`','')
Assert-True "offset-preselected: opens ProCmdDatumPlane"      ($offNB -match 'ProCmdDatumPlane')
Assert-True "offset-preselected: types the offset into t1.constr_dim1" ($offNB -match 't1\.constr_dim1 0\.375')
Assert-True "offset-preselected: confirms with stdbtn_1"      ($offNB -match 'stdbtn_1')
Assert-True "offset-preselected: does NOT tree-search (base is pre-buffered)" (-not ($offNB -match 'ProCmdMdlTreeSearch')) "(the component base is raw-COM buffered by the caller)"

# ============================================================================
# 2. Build-CurvedReliefCutMacro (PURE) - the symmetric remove-material finish.
# ============================================================================
Write-Host ""
Write-Host "  -- Build-CurvedReliefCutMacro (pure) --" -ForegroundColor White
# The macro delimits widget names with single backticks; strip them so the
# assertions match plain "widget arg" substrings (a doubled-backtick pattern would
# never match the single-backtick rendered output).
$cut   = Build-CurvedReliefCutMacro -SymDepth 0.5 -BodyIndex 1
$cutNB = ($cut -replace '`','')
Assert-True "cut: finishes the sketch (ProCmdSketDone)"  ($cutNB -match 'ProCmdSketDone')
Assert-True "cut: opens the depth flyout"                ($cutNB -match 'maindashInst0\.depth_flyout')
Assert-True "cut: toggles Symmetric to 1"                ($cutNB -match 'maindashInst0\.Symmetric 1')
Assert-True "cut: types def_depth1_ip"                   ($cutNB -match 'maindashInst0\.def_depth1_ip')
Assert-True "cut: def_depth1_ip carries the SymDepth value 0.5" ($cutNB -match 'maindashInst0\.def_depth1_ip 0\.5')
Assert-True "cut: toggles remove_material_cb (a CUT)"    ($cutNB -match 'maindashInst0\.remove_material_cb 1')
Assert-True "cut: opens the body page"                   ($cutNB -match 'chkbn\.body_page\.0')
Assert-True "cut: selects the body index 1"              ($cutNB -match 'PH\.bodyselectrepwdg_list 1')
Assert-True "cut: commits with dashInst0.Done"           ($cutNB -match 'dashInst0\.Done')
# ORDER: SketDone -> Symmetric -> depth -> remove-material -> Done.
$iDone1 = $cutNB.IndexOf('ProCmdSketDone'); $iSym = $cutNB.IndexOf('Symmetric'); $iDepth = $cutNB.IndexOf('def_depth1_ip')
$iRem = $cutNB.IndexOf('remove_material_cb'); $iDone2 = $cutNB.LastIndexOf('dashInst0.Done')
Assert-True "cut: order SketDone<Symmetric<depth<removeMaterial<Done" `
    (($iDone1 -lt $iSym) -and ($iSym -lt $iDepth) -and ($iDepth -lt $iRem) -and ($iRem -lt $iDone2))
# NO flip_pb (symmetric removes the direction ambiguity -> no operator direction-verify).
Assert-True "cut: NO flip_pb (symmetric needs no direction flip)" (-not ($cutNB -match 'flip_pb'))
# SymDepth <= 0 emits NO depth tokens (Creo keeps its default).
$cut0 = ((Build-CurvedReliefCutMacro -SymDepth 0 -BodyIndex 0) -replace '`','')
Assert-True "cut: SymDepth<=0 emits no def_depth1_ip token" (-not ($cut0 -match 'def_depth1_ip')) "(no depth typed when <=0)"
Assert-True "cut: SymDepth<=0 still toggles Symmetric + cut" (($cut0 -match 'Symmetric') -and ($cut0 -match 'remove_material_cb'))
# body index threads through.
$cut3 = ((Build-CurvedReliefCutMacro -SymDepth 0.4 -BodyIndex 3) -replace '`','')
Assert-True "cut: body index 3 threads into the selector" ($cut3 -match 'PH\.bodyselectrepwdg_list 3')

# ============================================================================
# 3. Invoke-FastenerRelief (COM driver) - the split open -> PLANE PICK -> rect -> DRAW
#    -> cut flow + canary + 2x doubling. The plane is picked ON SCREEN (PlanePrompt
#    fires on EVERY call -- ProCmdFtExtrude rejects a raw-COM component-plane pre-select),
#    so ViaPlane is always $false and there is no Select-ComponentPlaneById anymore.
#    STUB the COM helpers as globals so the driver's calls resolve to canned data.
# ============================================================================
Write-Host ""
Write-Host "  -- Invoke-FastenerRelief (driver, stubbed COM) --" -ForegroundColor White

# a fake model whose VersionStamp bumps on each RunMacro, and a session that records
# the macros it fired (so we can assert the split macros + the 2x-relief cut depth).
$script:firedMacros = New-Object System.Collections.ArrayList
$fakeModel = [pscustomobject]@{ VersionStamp = 1 }
$fakeSession = [pscustomobject]@{}
$fakeSession | Add-Member ScriptMethod RunMacro { param($m) [void]$script:firedMacros.Add([string]$m); $script:cModel.VersionStamp = ([int]$script:cModel.VersionStamp + 1) } -Force
$script:cModel = $fakeModel

# stub the canary helpers (globals so they win over the reals).
# Get-FeatureIdSet grows with the VersionStamp so the before/after diff yields a new id.
function global:Get-FeatureIdSet { $set=@{}; $v=0; try { $v=[int]$script:cModel.VersionStamp } catch { $v=0 }; for ($i=1; $i -le $v; $i++) { $set[(1000+$i)]=$true }; return $set }
function global:Wait-ModelModified { param($Model,$PreviousStamp,$TimeoutMs=30000,$OnPoll=$null) if ($null -ne $OnPoll) { try { & $OnPoll } catch {} } return $true }
# stub the plane helpers the by-id / guide-plane path calls (globals so they win over any
# real). $script:tangentOk toggles the tangent-plane build (miss -> the operator-pick fallback).
$script:tangentOk = $true
function global:Invoke-TangentPlane { param([int]$PointId,[int]$SurfaceId,[switch]$SurfaceFirst,$OnPoll=$null,[int]$TimeoutMs=30000) if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }; if ($script:tangentOk) { @{ Created=$true; PlaneId=(900 + [int]$PointId); Reason='' } } else { @{ Created=$false; PlaneId=$null; Reason='stub miss' } } }
function global:Select-ComponentPlaneById { param($Session,$TypeObj,$ComponentPath,[int]$PlaneId,[string]$Role='',[switch]$NoClear) @{ Ok=$true; Id=[int]$PlaneId; Reason='' } }
# New-CurvedGuidePlanes runs FOR REAL against the fake session (it fires RunMacro via the
# stubbed session + the real canary stubs), so the best-effort guide-plane path is covered.

# 3a. happy path: PlanePrompt + DrawPrompt BOTH fire; Cut=$true; ViaPlane=$false (manual pick);
# the open macro fires BEFORE the rect macro (the split); 2x depth reaches the cut macro.
# NOTE the prompt scriptblocks are PLAIN blocks (NOT .GetNewClosure()) so the driver's
# `& $DrawPrompt` runs them in the driver's scope and their $script: writes reach here.
$script:firedMacros.Clear()
$script:drawFired2 = $false; $script:planeFired2 = $false
$r = Invoke-FastenerRelief -Session $fakeSession -Model $fakeModel -TypeObj $null -ComponentPath $null -TopPlaneId 1 -ReliefDepth 0.25 -BodyIndex 1 -DrawPrompt { $script:drawFired2 = $true } -PlanePrompt { $script:planeFired2 = $true } -OnPoll { }
Assert-True "driver: happy path Cut=true"        ([bool]$r.Cut)
Assert-True "driver: ViaPlane=false (operator picks the plane)" (-not [bool]$r.ViaPlane)
Assert-True "driver: fired the PlanePrompt (mandatory)" ($script:planeFired2)
Assert-True "driver: fired the DrawPrompt"       ($script:drawFired2)
# the OPEN macro (extrude only, no rectangle) fired BEFORE the RECT macro (view+rectangle).
$openIdx = -1; $rectIdx = -1
for ($mi=0; $mi -lt @($script:firedMacros).Count; $mi++) {
    $mm = [string]$script:firedMacros[$mi]
    if ($openIdx -lt 0 -and ($mm -match 'ProCmdFtExtrude') -and (-not ($mm -match 'ProCmdSketSlantRectangle'))) { $openIdx = $mi }
    if ($rectIdx -lt 0 -and ($mm -match 'ProCmdSketSlantRectangle') -and (-not ($mm -match 'ProCmdFtExtrude'))) { $rectIdx = $mi }
}
Assert-True "driver: fired a standalone OPEN macro (extrude, no rectangle)" ($openIdx -ge 0)
Assert-True "driver: fired a standalone RECT macro (rectangle, no extrude)" ($rectIdx -ge 0)
Assert-True "driver: OPEN fired BEFORE RECT (split arm)" (($openIdx -ge 0) -and ($rectIdx -gt $openIdx)) "(open=$openIdx rect=$rectIdx)"
$cutFired = @($script:firedMacros | Where-Object { $_ -match 'remove_material_cb' })
Assert-True "driver: fired a remove-material cut macro" (@($cutFired).Count -ge 1)
$cutFiredNB = (@($cutFired) -join "`n") -replace '`',''
Assert-True "driver: doubled the relief (0.25 -> def_depth1_ip 0.5)" ($cutFiredNB -match 'def_depth1_ip 0\.5') "(2 x relief must reach the cut)"

# 3b. relief depth 0 -> immediate no-op (no cut, clear reason), no macros fired.
$script:firedMacros.Clear()
$r0 = Invoke-FastenerRelief -Session $fakeSession -Model $fakeModel -TypeObj $null -ComponentPath $null -TopPlaneId 1 -ReliefDepth 0 -BodyIndex 1
Assert-True "driver: ReliefDepth<=0 -> Cut=false"     (-not [bool]$r0.Cut)
Assert-True "driver: ReliefDepth<=0 fires no macro"   (@($script:firedMacros).Count -eq 0)

# 3c. no ComponentPath / no PlanePrompt supplied -> still opens + cuts (the operator is
# expected to pick the plane during the OnPoll pump; the driver never depends on a path).
$script:firedMacros.Clear()
$r3 = Invoke-FastenerRelief -Session $fakeSession -Model $fakeModel -TypeObj $null -ReliefDepth 0.3 -BodyIndex 0 -DrawPrompt { } -OnPoll { }
Assert-True "driver: no path/prompt -> ViaPlane=false" (-not [bool]$r3.ViaPlane)
Assert-True "driver: no path/prompt still cuts"        ([bool]$r3.Cut)

# 3d. canary: no model change -> Cut=false (never assume success). Stub Wait-ModelModified false.
function global:Wait-ModelModified { param($Model,$PreviousStamp,$TimeoutMs=30000,$OnPoll=$null) return $false }
$r4 = Invoke-FastenerRelief -Session $fakeSession -Model $fakeModel -TypeObj $null -ComponentPath $null -TopPlaneId 1 -ReliefDepth 0.25 -BodyIndex 1 -DrawPrompt { } -PlanePrompt { } -OnPoll { }
Assert-True "driver: no VersionStamp move -> Cut=false (canary miss)" (-not [bool]$r4.Cut)
Assert-True "driver: canary-miss reason is set" ([string]$r4.Reason -ne '')

# restore the passing canary.
function global:Wait-ModelModified { param($Model,$PreviousStamp,$TimeoutMs=30000,$OnPoll=$null) if ($null -ne $OnPoll) { try { & $OnPoll } catch {} } return $true }

# 3e. HANDS-FREE TOP-PLANE PRE-SELECT: with a ComponentPath + the Select-ComponentPlaneById stub
# (Ok=$true), the driver PRE-SELECTS the fastener TOP plane (ViaPlane=$true) THEN opens the extrude,
# and does NOT fire the PlanePrompt; the open macro is bare ProCmdFtExtrude (the plane is staged by
# a raw-COM COM call, not a macro token -- no ProCmdMdlTreeSearch).
$script:firedMacros.Clear()
$script:planeFired5 = $false; $script:drawFired5 = $false
$r5 = Invoke-FastenerRelief -Session $fakeSession -Model $fakeModel -TypeObj $null -ComponentPath ([pscustomobject]@{}) -TopPlaneId 1 -ReliefDepth 0.25 -BodyIndex 1 -PointId 201 -SurfaceId 41 -HoleDia 0.5 -GuidePlanes -DrawPrompt { $script:drawFired5 = $true } -PlanePrompt { $script:planeFired5 = $true } -OnPoll { }
Assert-True "driver: pre-select Cut=true"                ([bool]$r5.Cut)
Assert-True "driver: pre-select ViaPlane=true (TOP plane staged before the extrude)" ([bool]$r5.ViaPlane)
Assert-True "driver: pre-select did NOT fire the PlanePrompt"  (-not $script:planeFired5)
Assert-True "driver: fired the DrawPrompt"               ($script:drawFired5)
$bareOpen = @($script:firedMacros | Where-Object { ($_ -match 'ProCmdFtExtrude') -and (-not ($_ -match 'ProCmdMdlTreeSearch')) })
Assert-True "driver: opened the extrude BARE (plane staged by raw-COM, not a tree-search token)" (@($bareOpen).Count -ge 1)
$cut5 = @($script:firedMacros | Where-Object { $_ -match 'remove_material_cb' })
Assert-True "driver: feed still cuts (remove-material fired)" (@($cut5).Count -ge 1)

# 3g. New-CurvedGuidePlanes (best-effort) creates offset planes off the fastener SIDE/FRONT.
$script:firedMacros.Clear()
$gp = New-CurvedGuidePlanes -Session $fakeSession -Model $fakeModel -TypeObj $null -ComponentPath ([pscustomobject]@{}) -HoleDia 0.5 -OnPoll { }
Assert-True "guide planes: created >=1 offset plane (best-effort)" (@($gp.Ids).Count -ge 1)
$gpMacros = @($script:firedMacros | Where-Object { $_ -match 'ProCmdDatumPlane' })
Assert-True "guide planes: fired ProCmdDatumPlane offset macro(s)" (@($gpMacros).Count -ge 1)
Assert-True "guide planes: null ComponentPath -> no planes, no throw" (@((New-CurvedGuidePlanes -Session $fakeSession -Model $fakeModel -TypeObj $null -ComponentPath $null).Ids).Count -eq 0)

# ============================================================================
# 4. Invoke-FastenerReliefArm / Invoke-FastenerReliefCut - the TWO-STEP split (the GUI
#    slot-arm/slot-finish path). Arm opens + returns a canary baseline; Cut gates on it.
# ============================================================================
Write-Host ""
Write-Host "  -- Invoke-FastenerReliefArm / Cut (two-step split) --" -ForegroundColor White
function global:Wait-ModelModified { param($Model,$PreviousStamp,$TimeoutMs=30000,$OnPoll=$null) if ($null -ne $OnPoll) { try { & $OnPoll } catch {} } return $true }
# 4a. ARM (hands-free pre-select): PRE-SELECTS the fastener TOP plane via Select-ComponentPlaneById
# (stub Ok=$true -> $fed) THEN opens the extrude BARE, so ViaPlane=$true, the PlanePrompt does NOT
# fire, the rectangle arms, and it returns a canary baseline. NO by-id tree-search open.
$script:firedMacros.Clear()
$script:planeFiredA = $false
$a1 = Invoke-FastenerReliefArm -Session $fakeSession -Model $fakeModel -TypeObj $null -ComponentPath ([pscustomobject]@{}) -PointId 201 -SurfaceId 41 -HoleDia 0.5 -TopPlaneId 1 -GuidePlanes -PlanePrompt { $script:planeFiredA = $true } -OnPoll { }
Assert-True "arm: Armed=true"            ([bool]$a1.Armed)
Assert-True "arm: pre-select ViaPlane=true (TOP plane staged before the extrude)" ([bool]$a1.ViaPlane)
Assert-True "arm: pre-select did NOT fire the PlanePrompt" (-not $script:planeFiredA)
Assert-True "arm: returns a BaseStamp (cut-canary baseline)" ($null -ne $a1.BaseStamp)
Assert-True "arm: opened the extrude BARE (plane staged by raw-COM, not a tree-search token)" (@($script:firedMacros | Where-Object { ($_ -match 'ProCmdFtExtrude') -and (-not ($_ -match 'ProCmdMdlTreeSearch')) }).Count -ge 1)
Assert-True "arm: armed the rectangle (ProCmdSketSlantRectangle)" (@($script:firedMacros | Where-Object { $_ -match 'ProCmdSketSlantRectangle' }).Count -ge 1)
Assert-True "arm: did NOT fire the cut yet (no remove_material)" (@($script:firedMacros | Where-Object { $_ -match 'remove_material_cb' }).Count -eq 0)
# 4b. CUT with the arm's baseline -> Cut=true, remove-material fired, 2x depth.
$script:firedMacros.Clear()
$cres = Invoke-FastenerReliefCut -Session $fakeSession -Model $fakeModel -SymDepth 0.5 -BodyIndex 1 -BaseFeat $a1.BaseFeat -BaseStamp $a1.BaseStamp -OnPoll { }
Assert-True "cut: Cut=true (new feature + stamp moved vs the arm baseline)" ([bool]$cres.Cut)
$cutNB2 = (@($script:firedMacros) -join "`n") -replace '`',''
Assert-True "cut: fired remove_material_cb"      ($cutNB2 -match 'remove_material_cb 1')
Assert-True "cut: def_depth1_ip carries 0.5"     ($cutNB2 -match 'def_depth1_ip 0\.5')
# 4c. CUT with a NULL baseline stamp -> miss (never assume success).
$cMiss = Invoke-FastenerReliefCut -Session $fakeSession -Model $fakeModel -SymDepth 0.5 -BodyIndex 1 -BaseFeat @{} -BaseStamp $null -OnPoll { }
Assert-True "cut: null baseline stamp -> Cut=false (canary miss)" (-not [bool]$cMiss.Cut)
# 4d. ARM FEED-MISS fallback: shadow Select-ComponentPlaneById to Ok=$false -> the feed misses,
# so the operator PlanePrompt FIRES, ViaPlane=$false, still Armed (clean degrade, no regression).
$script:savedSel = ${function:Select-ComponentPlaneById}
function global:Select-ComponentPlaneById { param($Session,$TypeObj,$ComponentPath,[int]$PlaneId,[string]$Role='',[switch]$NoClear) @{ Ok=$false; Id=0; Reason='stub miss' } }
$script:planeFiredA2 = $false
$a2 = Invoke-FastenerReliefArm -Session $fakeSession -Model $fakeModel -TypeObj $null -ComponentPath ([pscustomobject]@{}) -PointId 201 -SurfaceId 41 -HoleDia 0.5 -TopPlaneId 1 -PlanePrompt { $script:planeFiredA2 = $true } -OnPoll { }
Assert-True "arm: feed-miss fired the PlanePrompt (fallback)" ($script:planeFiredA2)
Assert-True "arm: feed-miss ViaPlane=false"     (-not [bool]$a2.ViaPlane)
Assert-True "arm: feed-miss still Armed"        ([bool]$a2.Armed)
${function:Select-ComponentPlaneById} = $script:savedSel
# 4e. ARM with NO ComponentPath -> feed skipped -> PlanePrompt fires (fasteners-only path).
$script:planeFiredA3 = $false
$a3 = Invoke-FastenerReliefArm -Session $fakeSession -Model $fakeModel -TypeObj $null -ComponentPath $null -PointId 0 -SurfaceId 0 -HoleDia 0.5 -PlanePrompt { $script:planeFiredA3 = $true } -OnPoll { }
Assert-True "arm: no-path fired the PlanePrompt" ($script:planeFiredA3)
Assert-True "arm: no-path ViaPlane=false"        (-not [bool]$a3.ViaPlane)
Assert-True "arm: no-path still Armed"           ([bool]$a3.Armed)

# ============================================================================
# 5. RADIAL / AXIS PATTERN: Build-RadialPatternOpenMacro / ValuesMacro (PURE, tokens
#    verbatim from the operator's `axispattern` mapkey) + Invoke-CurvedReliefRadialPattern
#    (driver: raw-COM seed select -> open -> axis pick / by-id -> values -> canary,
#    with the fallback on a canary miss). See [[project_curved_radial_slot_pattern]].
# ============================================================================
Write-Host ""
Write-Host "  -- Build-RadialPatternOpenMacro / ValuesMacro (pure) --" -ForegroundColor White
$ropen = (Build-RadialPatternOpenMacro) -replace '`',''
Assert-True "radial-open: opens ProCmdPattern"                   ($ropen -match 'ProCmdPattern')
Assert-True "radial-open: switches ui_pat_type to item 2 (Axis)" ($ropen -match '2 ui_pat_type')
Assert-True "radial-open: arms the axis reference collector"      ($ropen -match 'PH\.ui_pat_dim_1_array')
Assert-True "radial-open: no count/increment yet (waits for the axis pick)" ((-not ($ropen -match 'ui_pat_axis_1_num_inst')) -and (-not ($ropen -match 'ui_pat_axis_1_incr')))
Assert-True "radial-open: does NOT confirm yet (no stdbtn_1)"    (-not ($ropen -match 'stdbtn_1'))
Assert-True "radial-open: does NOT tree-search the seed (driver raw-COM selects it)" (-not ($ropen -match 'ProCmdMdlTreeSearch'))

$rvals = (Build-RadialPatternValuesMacro -Count 4 -IncrementDeg 90) -replace '`',''
Assert-True "radial-values: sets count ui_pat_axis_1_num_inst 4"  ($rvals -match 'ui_pat_axis_1_num_inst 4')
Assert-True "radial-values: sets increment ui_pat_axis_1_incr 90" ($rvals -match 'ui_pat_axis_1_incr 90')
Assert-True "radial-values: zeroes the 2nd axis dim (ui_pat_axis_2_incr 0)" ($rvals -match 'ui_pat_axis_2_incr 0')
Assert-True "radial-values: confirms with dashInst0.stdbtn_1"     ($rvals -match 'dashInst0\.stdbtn_1')
$iCnt=$rvals.IndexOf('ui_pat_axis_1_num_inst'); $iInc=$rvals.IndexOf('ui_pat_axis_1_incr'); $iCon=$rvals.LastIndexOf('stdbtn_1')
Assert-True "radial-values: order count < increment < confirm" (($iCnt -lt $iInc) -and ($iInc -lt $iCon))
$rvals2 = (Build-RadialPatternValuesMacro -Count 5 -IncrementDeg 20.5) -replace '`',''
Assert-True "radial-values: decimal increment 20.5 threads through" ($rvals2 -match 'ui_pat_axis_1_incr 20\.5')

Write-Host ""
Write-Host "  -- Test-RadialPatternReady / Get-SelectAxisByIdMacro / Build-RadialPatternAtomicMacro (pure, probe-gated) --" -ForegroundColor White
# The atomic axis-by-id macro is the FIX for the split-RunMacro no-op, but it needs TWO widget
# tokens that were never recorded. Default (tokens absent) -> not ready, builders return $null,
# so the driver CANNOT fire a guessed widget (mine-don't-guess).
$global:RadialAxisCollectorWidget = $null; $global:RadialAxisSelType = $null
Assert-True "ready: false when tokens absent"          (-not (Test-RadialPatternReady))
Assert-True "axis-by-id: null when SelType absent"     ($null -eq (Get-SelectAxisByIdMacro -FeatId 5))
Assert-True "atomic: null when recipe absent"          ($null -eq (Build-RadialPatternAtomicMacro -AxisFeatId 5 -Count 4 -IncrementDeg 90))
# tokens present -> ready; the atomic macro is ONE string: proven open + arm axis + feed-by-id + confirm.
$global:RadialAxisCollectorWidget = 'maindashInst0.ui_pat_axis_ref_TESTONLY'; $global:RadialAxisSelType = 'Axis'
Assert-True "ready: true when both tokens present"     (Test-RadialPatternReady)
Assert-True "atomic: null when AxisFeatId<=0"          ($null -eq (Build-RadialPatternAtomicMacro -AxisFeatId 0 -Count 4 -IncrementDeg 90))
$atmNB = [string](Build-RadialPatternAtomicMacro -AxisFeatId 777 -Count 4 -IncrementDeg 90)
Assert-True "atomic: single string, not null"          (-not [string]::IsNullOrWhiteSpace($atmNB))
Assert-True "atomic: contains ProCmdPattern open"      ($atmNB -match 'ProCmdPattern')
Assert-True "atomic: switches to Axis (2 ui_pat_type)" ($atmNB -match '2 ui_pat_type')
Assert-True "atomic: arms the axis collector token"    ($atmNB -match 'ui_pat_axis_ref_TESTONLY')
Assert-True "atomic: feeds the axis by id (777)"       (($atmNB -match 'ProCmdMdlTreeSearch') -and ($atmNB -match '777'))
Assert-True "atomic: SelOptionRadio uses the axis type" ($atmNB -match 'SelOptionRadio.+Axis')
Assert-True "atomic: sets count + increment (4 / 90)"  (($atmNB -match 'ui_pat_axis_1_num_inst.+4') -and ($atmNB -match 'ui_pat_axis_1_incr.+90'))
Assert-True "atomic: confirms with dashInst0.stdbtn_1" ($atmNB -match 'dashInst0.stdbtn_1')
$iP=$atmNB.IndexOf('ProCmdPattern'); $iArm=$atmNB.IndexOf('ui_pat_axis_ref_TESTONLY'); $iFeed=$atmNB.IndexOf('ProCmdMdlTreeSearch'); $iCount=$atmNB.IndexOf('ui_pat_axis_1_num_inst'); $iConf=$atmNB.IndexOf('dashInst0.stdbtn_1')
Assert-True "atomic: order open<arm<feed<values<confirm" (($iP -lt $iArm) -and ($iArm -lt $iFeed) -and ($iFeed -lt $iCount) -and ($iCount -lt $iConf))

Write-Host "  -- Invoke-CurvedReliefRadialPattern (driver, stubbed COM) --" -ForegroundColor White
# fresh fakes: a session with RunMacro (records + bumps the stamp) + a selection buffer
# (Clear/AddSelection), a model with GetItemById + a bumping VersionStamp, a ComSelect stub.
$script:rFired = New-Object System.Collections.ArrayList
$rBuf = [pscustomobject]@{ Added = 0 }
$rBuf | Add-Member ScriptMethod Clear { $this.Added = 0 } -Force
$rBuf | Add-Member ScriptMethod AddSelection { param($s) $this.Added = [int]$this.Added + 1 } -Force
$rModel = [pscustomobject]@{ VersionStamp = 1 }
$rModel | Add-Member ScriptMethod GetItemById { param($t,$id) [pscustomobject]@{ Id = [int]$id } } -Force
$rSession = [pscustomobject]@{}
$rSession | Add-Member ScriptMethod RunMacro { param($m) [void]$script:rFired.Add([string]$m); $script:rModelRef.VersionStamp = ([int]$script:rModelRef.VersionStamp + 1) } -Force
$rSession | Add-Member ScriptMethod CurrentSelectionBuffer { $script:rBufRef } -Force
$script:rModelRef = $rModel; $script:rBufRef = $rBuf
$rType = [pscustomobject]@{ ITEM_FEATURE = 999 }
# stub the ComSelect factory (the real one does New-Object -ComObject, which fails offline)
# + repoint the Get-FeatureIdSet canary model (stubbed in section 3) at $rModel.
function global:Get-ComSelectFactory { $f=[pscustomobject]@{}; $f | Add-Member ScriptMethod CreateModelItemSelection { param($item,$path) [pscustomobject]@{ It=$item } } -Force; return $f }
$script:cModel = $rModel
function global:Wait-ModelModified { param($Model,$PreviousStamp,$TimeoutMs=30000,$OnPoll=$null) if ($null -ne $OnPoll) { try { & $OnPoll } catch {} } return $true }

# tokens present (set in the pure block above) so the atomic path is reachable.
$global:RadialAxisCollectorWidget = 'maindashInst0.ui_pat_axis_ref_TESTONLY'; $global:RadialAxisSelType = 'Axis'

# 5a. ATOMIC happy path: tokens + AxisFeatId>0 -> ONE RunMacro (open+arm+feed-by-id+values+confirm),
#     Patterned=true, ViaAxisId=true, operator AxisPrompt NEVER fired (no pick in the atomic path).
$script:rFired.Clear(); $script:axisPicked = $false
$rp = Invoke-CurvedReliefRadialPattern -Session $rSession -Model $rModel -TypeObj $rType -SeedFeatId 42 -Count 4 -IncrementDeg 90 -AxisFeatId 777 -AxisPrompt { $script:axisPicked = $true } -OnPoll { }
Assert-True "driver: Patterned=true (atomic by-id)"   ([bool]$rp.Patterned)
Assert-True "driver: seed selected via raw-COM"       ([bool]$rp.SeedSelected)
Assert-True "driver: ViaAxisId=true (by-id, no pick)" ([bool]$rp.ViaAxisId)
Assert-True "driver: operator AxisPrompt NOT fired"   (-not $script:axisPicked)
# THE FIX: the WHOLE pattern is ONE atomic RunMacro (not split) -- exactly ONE fired string carries
# ProCmdPattern AND the axis-by-id feed (777) AND the count AND the stdbtn_1 confirm.
$oneShot = @($script:rFired | Where-Object { ($_ -match 'ProCmdPattern') -and ($_ -match 'ui_pat_axis_1_num_inst') -and ($_ -match 'dashInst0.stdbtn_1') -and ($_ -match '777') })
Assert-True "driver: fired ONE atomic macro (open+axis-by-id+values+confirm together)" (@($oneShot).Count -eq 1)
Assert-True "driver: did NOT split the dashboard across RunMacro calls" (@($script:rFired).Count -eq 1)

# 5b. PROBE-GATED (no recipe tokens) -> probe-gated miss, and NOTHING is fired (never the broken split).
$global:RadialAxisCollectorWidget = $null; $global:RadialAxisSelType = $null
$script:rFired.Clear()
$rGate = Invoke-CurvedReliefRadialPattern -Session $rSession -Model $rModel -TypeObj $rType -SeedFeatId 42 -Count 4 -IncrementDeg 90 -AxisFeatId 777 -OnPoll { }
Assert-True "driver: no recipe -> not patterned"      (-not [bool]$rGate.Patterned)
Assert-True "driver: probe-gated fired NOTHING"       (@($script:rFired).Count -eq 0)
Assert-True "driver: probe-gated reason says probe"   ([string]$rGate.Reason -match 'probe-gated')
$global:RadialAxisCollectorWidget = 'maindashInst0.ui_pat_axis_ref_TESTONLY'; $global:RadialAxisSelType = 'Axis'

# 5b2. tokens present but NO axis id -> not patterned, fired NOTHING (radial needs a datum-axis id).
$script:rFired.Clear()
$rNoAxis = Invoke-CurvedReliefRadialPattern -Session $rSession -Model $rModel -TypeObj $rType -SeedFeatId 42 -Count 4 -IncrementDeg 90 -AxisFeatId 0 -OnPoll { }
Assert-True "driver: no axis id -> not patterned"     (-not [bool]$rNoAxis.Patterned)
Assert-True "driver: no axis id fired NOTHING"        (@($script:rFired).Count -eq 0)

# 5c. guards (never fire the macro): seed<=0, count<2, increment<=0 (tokens+axis id present).
$g1 = Invoke-CurvedReliefRadialPattern -Session $rSession -Model $rModel -TypeObj $rType -SeedFeatId 0 -Count 4 -IncrementDeg 90 -AxisFeatId 777
$g2 = Invoke-CurvedReliefRadialPattern -Session $rSession -Model $rModel -TypeObj $rType -SeedFeatId 42 -Count 1 -IncrementDeg 90 -AxisFeatId 777
$g3 = Invoke-CurvedReliefRadialPattern -Session $rSession -Model $rModel -TypeObj $rType -SeedFeatId 42 -Count 4 -IncrementDeg 0 -AxisFeatId 777
Assert-True "driver: seed<=0 -> not patterned"       (-not [bool]$g1.Patterned)
Assert-True "driver: count<2 -> not patterned"       (-not [bool]$g2.Patterned)
Assert-True "driver: increment<=0 -> not patterned"  (-not [bool]$g3.Patterned)

# 5d. canary MISS: no VersionStamp move -> Patterned=false (fall back to per-fastener).
function global:Wait-ModelModified { param($Model,$PreviousStamp,$TimeoutMs=30000,$OnPoll=$null) return $false }
$rMiss = Invoke-CurvedReliefRadialPattern -Session $rSession -Model $rModel -TypeObj $rType -SeedFeatId 42 -Count 4 -IncrementDeg 90 -AxisFeatId 777 -OnPoll { }
Assert-True "driver: canary miss -> Patterned=false" (-not [bool]$rMiss.Patterned)
Assert-True "driver: canary miss reason is set"      ([string]$rMiss.Reason -ne '')
function global:Wait-ModelModified { param($Model,$PreviousStamp,$TimeoutMs=30000,$OnPoll=$null) if ($null -ne $OnPoll) { try { & $OnPoll } catch {} } return $true }
# leave the tokens cleared so a later dot-source consumer starts from the honest default.
$global:RadialAxisCollectorWidget = $null; $global:RadialAxisSelType = $null

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ("  curved_relief tests: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
Write-Host "  ============================================" -ForegroundColor Cyan
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
