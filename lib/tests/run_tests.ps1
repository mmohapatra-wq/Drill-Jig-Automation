# ============================================================================
# lib\tests\run_tests.ps1 - offline unit tests for the lib helpers
# ============================================================================
# Runs WITHOUT Creo and WITHOUT network. Exercises the pure-read geometry math,
# the eval-packet JSON round-trip, the blind-judge request shaping (against a
# fake $Model / fake packet - no Invoke-RestMethod call), and the convergence
# report rendering. Live REST is validated separately by Invoke-JudgeProbe
# (--probe-judge), which needs the gateway.
#
# Run:  powershell -ExecutionPolicy Bypass -File lib\tests\run_tests.ps1
# Exit code 0 = all passed, 1 = at least one failure.
# ============================================================================

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here
. (Join-Path $libDir 'creo_geometry.ps1')
. (Join-Path $libDir 'blind_evaluator.ps1')

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

Write-Host ""
Write-Host "  Running lib unit tests (offline)..." -ForegroundColor Cyan
Write-Host ""

# ----------------------------------------------------------------------------
# Get-Comp / Dot
# ----------------------------------------------------------------------------
Write-Host "  -- creo_geometry: Get-Comp / Dot --" -ForegroundColor White

# bracket-indexable array stands in for an IpfcPoint3D
$c = Get-Comp @(1.5, 2.5, 3.5)
Assert-True "Get-Comp reads bracket-indexed components" `
    ($null -ne $c -and (Approx $c[0] 1.5) -and (Approx $c[1] 2.5) -and (Approx $c[2] 3.5))

# object exposing only .Item(i) stands in for the .Item fallback path
$itemOnly = [pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptMethod -Name Item -Value { param($i) @(10.0,20.0,30.0)[$i] }
$c2 = Get-Comp $itemOnly
Assert-True "Get-Comp falls back to .Item(i)" `
    ($null -ne $c2 -and (Approx $c2[0] 10.0) -and (Approx $c2[2] 30.0))

Assert-True "Get-Comp returns null on unreadable input" ($null -eq (Get-Comp ([pscustomobject]@{ junk = 1 })))
Assert-True "Get-Comp returns null on null" ($null -eq (Get-Comp $null))

Assert-True "Dot computes 3D dot product" (Approx (Dot @(1,2,3) @(4,5,6)) 32.0)
Assert-True "Dot of orthogonal vectors is 0" (Approx (Dot @(1,0,0) @(0,1,0)) 0.0)

# ----------------------------------------------------------------------------
# Dist-PointToAxis
# ----------------------------------------------------------------------------
Write-Host "  -- creo_geometry: Dist-PointToAxis --" -ForegroundColor White

# point on the Z axis -> distance 0
Assert-True "point on axis has ~0 perpendicular distance" `
    (Approx (Dist-PointToAxis -P @(0,0,5) -A @(0,0,0) -D @(0,0,1)) 0.0)
# point offset 3 in x from the Z axis -> distance 3
Assert-True "point offset from axis returns the offset" `
    (Approx (Dist-PointToAxis -P @(3,0,5) -A @(0,0,0) -D @(0,0,1)) 3.0 1e-9)
# degenerate direction -> +inf
Assert-True "degenerate axis direction returns +inf" `
    ([double]::IsPositiveInfinity((Dist-PointToAxis -P @(1,1,1) -A @(0,0,0) -D @(0,0,0))))
# non-unit direction is normalized (3-4-5): point (0,5,0), axis dir (0,0,2) -> dist 5
Assert-True "non-unit axis direction is normalized" `
    (Approx (Dist-PointToAxis -P @(0,5,0) -A @(0,0,0) -D @(0,0,2)) 5.0 1e-9)

# ----------------------------------------------------------------------------
# Cross (cornerinator: vertical edge dir = normalize(cross(n1,n2)))
# ----------------------------------------------------------------------------
Write-Host "  -- creo_geometry: Cross --" -ForegroundColor White

# right-hand rule: x cross y = z
$xy = Cross @(1,0,0) @(0,1,0)
Assert-True "Cross x,y = z (right-hand rule)" `
    ((Approx $xy[0] 0.0) -and (Approx $xy[1] 0.0) -and (Approx $xy[2] 1.0))
# anti-commutative: y cross x = -z
$yx = Cross @(0,1,0) @(1,0,0)
Assert-True "Cross y,x = -z (anti-commutative)" (Approx $yx[2] -1.0)
# result is orthogonal to both inputs
$a = @(1,2,3); $b = @(4,5,6); $axb = Cross $a $b
Assert-True "Cross result is orthogonal to both inputs" `
    ((Approx (Dot $axb $a) 0.0) -and (Approx (Dot $axb $b) 0.0))
# parallel inputs -> zero vector
$par = Cross @(0,0,2) @(0,0,5)
Assert-True "Cross of parallel vectors is zero" `
    ((Approx $par[0] 0.0) -and (Approx $par[1] 0.0) -and (Approx $par[2] 0.0))

# ----------------------------------------------------------------------------
# Read-PlaneNormal (fake Surf whose descriptor.Origin.GetZAxis() is the normal)
# ----------------------------------------------------------------------------
Write-Host "  -- creo_geometry: Read-PlaneNormal --" -ForegroundColor White

# descriptor whose .Origin.GetZAxis() returns a bracket-indexable normal (the
# proven cylinder-sibling path); mirrors the Measure-Extents stub style.
# NB: Add-Member ScriptMethod bodies resolve free variables by DYNAMIC scope (the
# caller's scope at invoke time). Read-PlaneNormal has its own locals named $desc
# and $surf, so the stub MUST use distinct names ($pnXform/$pnDesc/$pnSurf) or the
# method body would pick up the function's half-assigned $desc and return null.
$pnXform = [pscustomobject]@{} |
    Add-Member -PassThru -MemberType ScriptMethod -Name GetZAxis -Value { @(0.0, 0.0, 1.0) }
$pnDesc = [pscustomobject]@{ Origin = $pnXform }
$pnSurf = [pscustomobject]@{} |
    Add-Member -PassThru -MemberType ScriptMethod -Name GetSurfaceDescriptor -Value { $pnDesc }
$n = Read-PlaneNormal -Surf $pnSurf
Assert-True "Read-PlaneNormal reads descriptor.Origin.GetZAxis()" `
    ($null -ne $n -and (Approx $n[0] 0.0) -and (Approx $n[1] 0.0) -and (Approx $n[2] 1.0))

# GetNormal() fallback when there is no .Origin
$pnSurfNorm = [pscustomobject]@{} |
    Add-Member -PassThru -MemberType ScriptMethod -Name GetSurfaceDescriptor -Value {
        [pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptMethod -Name GetNormal -Value { @(1.0, 0.0, 0.0) }
    }
$nf = Read-PlaneNormal -Surf $pnSurfNorm
Assert-True "Read-PlaneNormal falls back to GetNormal()" `
    ($null -ne $nf -and (Approx $nf[0] 1.0))

Assert-True "Read-PlaneNormal returns null on null surf (no throw)" ($null -eq (Read-PlaneNormal -Surf $null))

# ----------------------------------------------------------------------------
# Get-OutlineExtents
# ----------------------------------------------------------------------------
Write-Host "  -- creo_geometry: Get-OutlineExtents --" -ForegroundColor White

# IpfcOutline3D stand-in: a 2-element array of corner points (each bracket-indexable)
$outline = @( @(0.0, 0.0, 0.0), @(4.0, 3.0, 2.0) )
$ext = Get-OutlineExtents -Outline $outline
Assert-True "extents from min/max corners" `
    ($null -ne $ext -and (Approx $ext[0] 4.0) -and (Approx $ext[1] 3.0) -and (Approx $ext[2] 2.0))

# reversed corners (max first) -> abs() still gives positive extents
$outlineRev = @( @(4.0, 3.0, 2.0), @(0.0, 0.0, 0.0) )
$extRev = Get-OutlineExtents -Outline $outlineRev
Assert-True "extents are absolute regardless of corner order" `
    ($null -ne $extRev -and (Approx $extRev[0] 4.0) -and (Approx $extRev[2] 2.0))

# negative-coordinate corners
$outlineNeg = @( @(-1.0, -2.0, -3.0), @(1.0, 2.0, 3.0) )
$extNeg = Get-OutlineExtents -Outline $outlineNeg
Assert-True "extents span negative-to-positive corners" `
    ($null -ne $extNeg -and (Approx $extNeg[0] 2.0) -and (Approx $extNeg[1] 4.0) -and (Approx $extNeg[2] 6.0))

Assert-True "Get-OutlineExtents returns null on null outline" ($null -eq (Get-OutlineExtents -Outline $null))

# ----------------------------------------------------------------------------
# Measure-Extents (with a fake Solid exposing EvalOutline)
# ----------------------------------------------------------------------------
Write-Host "  -- creo_geometry: Measure-Extents --" -ForegroundColor White

# Fake solid: EvalOutline returns a good 2-corner outline regardless of args.
$goodSolid = [pscustomobject]@{} |
    Add-Member -PassThru -MemberType ScriptMethod -Name EvalOutline -Value { param($a,$b) @( @(0.0,0.0,0.0), @(5.0,4.0,1.0) ) }
$m = Measure-Extents -Solid $goodSolid -ExcludeTypes $null
Assert-True "Measure-Extents reads a clean outline" `
    ($null -ne $m -and (Approx $m[0] 5.0) -and (Approx $m[1] 4.0) -and (Approx $m[2] 1.0))

# Fake solid where the EXCLUDE path collapses (returns a degenerate ~0 extent) but
# the no-exclude path is good -> Measure-Extents must fall back and return the good one.
$collapseSolid = [pscustomobject]@{} |
    Add-Member -PassThru -MemberType ScriptMethod -Name EvalOutline -Value {
        param($a,$b)
        if ($null -ne $b) { return @( @(0.0,0.0,0.0), @(0.0,4.0,1.0) ) }  # collapsed dx=0 with excludes
        return @( @(0.0,0.0,0.0), @(5.0,4.0,1.0) )                        # good without excludes
    }
$mc = Measure-Extents -Solid $collapseSolid -ExcludeTypes ([pscustomobject]@{ Count = 1 })
Assert-True "Measure-Extents falls back when exclude collapses the outline" `
    ($null -ne $mc -and (Approx $mc[0] 5.0) -and (Approx $mc[1] 4.0))

# ----------------------------------------------------------------------------
# Get-LinearDimMap / Read-DimValue (fake Model + TypeObj)
# ----------------------------------------------------------------------------
Write-Host "  -- creo_geometry: Get-LinearDimMap / Read-DimValue --" -ForegroundColor White

$typeObj = [pscustomobject]@{ ITEM_DIMENSION = 1; ITEM_BODY = 2 }
# dims: two linear (DimType 0) + one radial (DimType 1, must be excluded)
$dims = @(
    [pscustomobject]@{ Symbol = "d0"; DimType = 0; DimValue = 4.0 },
    [pscustomobject]@{ Symbol = "d1"; DimType = 0; DimValue = 3.0 },
    [pscustomobject]@{ Symbol = "d2"; DimType = 1; DimValue = 0.5 },
    [pscustomobject]@{ Symbol = "d3"; DimType = 3; DimValue = 45.0 }
)
$fakeModel = [pscustomobject]@{ _dims = $dims }
$fakeModel | Add-Member -MemberType ScriptMethod -Name ListItems -Value { param($t) $this._dims }
$fakeModel | Add-Member -MemberType ScriptMethod -Name GetItemByName -Value {
    param($t,$sym) ($this._dims | Where-Object { $_.Symbol -eq $sym } | Select-Object -First 1)
}

$map = Get-LinearDimMap -Model $fakeModel -TypeObj $typeObj
Assert-True "Get-LinearDimMap keeps only linear dims" ($map.Count -eq 2 -and $map.ContainsKey("d0") -and -not $map.ContainsKey("d2"))
Assert-True "Get-LinearDimMap reads values" ((Approx $map["d0"] 4.0) -and (Approx $map["d1"] 3.0))
Assert-True "Read-DimValue reads by symbol" (Approx (Read-DimValue -Model $fakeModel -TypeObj $typeObj -Sym "d1") 3.0)
Assert-True "Read-DimValue returns null for unknown symbol" ($null -eq (Read-DimValue -Model $fakeModel -TypeObj $typeObj -Sym "nope"))

# Get-AngularDimMap: the DimType-3 companion (keeps only the angular dim d3; the
# two linear dims and the radial dim are excluded). Linear count above stays 2.
$amap = Get-AngularDimMap -Model $fakeModel -TypeObj $typeObj
Assert-True "Get-AngularDimMap keeps only angular dims" ($amap.Count -eq 1 -and $amap.ContainsKey("d3") -and -not $amap.ContainsKey("d0") -and -not $amap.ContainsKey("d2"))
Assert-True "Get-AngularDimMap reads values" (Approx $amap["d3"] 45.0)

# ----------------------------------------------------------------------------
# Test-ExtentsMatch - the deterministic by-value gate (this is the arithmetic the
# LLM no longer owns). Order-independent, tolerance-based, multiset (no reuse).
# ----------------------------------------------------------------------------
Write-Host "  -- creo_geometry: Test-ExtentsMatch --" -ForegroundColor White

# all three expected values present among measured (within default tol 0.1)
$r = Test-ExtentsMatch -Expected @(4.0, 3.0, 2.0) -Measured @(4.0009, 3.0001, 2.0)
Assert-True "all expected values matched -> AllMatched true" ($r.AllMatched)

# ORDER INDEPENDENCE: a width/height/depth swap still matches by value
$r = Test-ExtentsMatch -Expected @(2.0, 4.0, 3.0) -Measured @(4.0009, 3.0001, 2.0)
Assert-True "match is order-independent (swapped expected still matches)" ($r.AllMatched)

# one wrong expected value (the snap-back-to-wrong-size case) -> fails
$r = Test-ExtentsMatch -Expected @(4.0, 3.0, 9.9) -Measured @(4.0009, 3.0001, 2.0)
Assert-True "a value with no measured match -> AllMatched false" (-not $r.AllMatched)
$badPair = @($r.Pairs | Where-Object { -not $_.Ok })
Assert-True "the failing pair is identified" ($badPair.Count -eq 1 -and (Approx $badPair[0].Expected 9.9))

# MULTISET: two expected 4.0 but only one measured 4.0 -> second can't reuse it
$r = Test-ExtentsMatch -Expected @(4.0, 4.0) -Measured @(4.0, 2.0)
Assert-True "a measured extent is not consumed twice" (-not $r.AllMatched)

# two expected 4.0 with two measured 4.0 -> both match
$r = Test-ExtentsMatch -Expected @(4.0, 4.0) -Measured @(4.0, 4.0)
Assert-True "duplicate expected values match duplicate measured values" ($r.AllMatched)

# null / empty measured -> no match, no throw
$r = Test-ExtentsMatch -Expected @(4.0) -Measured $null
Assert-True "null measured -> AllMatched false (no throw)" (-not $r.AllMatched)

# tolerance is respected: 0.2 off fails at tol 0.1, passes at tol 0.3
Assert-True "outside tol fails"  (-not (Test-ExtentsMatch -Expected @(4.0) -Measured @(4.2) -Tol 0.1).AllMatched)
Assert-True "inside tol passes"  ((Test-ExtentsMatch -Expected @(4.0) -Measured @(4.2) -Tol 0.3).AllMatched)

# ----------------------------------------------------------------------------
# blind_evaluator: New-EvalClaim / Get-GeometrySlice / Write-EvalPacket round-trip
# ----------------------------------------------------------------------------
Write-Host "  -- blind_evaluator: claim / slice / packet --" -ForegroundColor White

$claim = New-EvalClaim -Tool "plane-probe" -Operation "build-box" -Claims @(
    "the box width is 4.0", "the box height is 3.0", "the box depth is 2.0"
)
Assert-True "New-EvalClaim captures tool/operation/claims" `
    ($claim.tool -eq "plane-probe" -and $claim.operation -eq "build-box" -and $claim.claims.Count -eq 3)

$slice = Get-GeometrySlice -Model "boxtest.prt" -Truth @{
    measured_extents_sorted_desc = @(4.0009, 3.0001, 2.0)
    offsets = @{ Side = 4.0; Top = 3.0; Front = 2.0 }
}
Assert-True "Get-GeometrySlice carries model + truth" `
    ($slice.model -eq "boxtest.prt" -and $slice.truth.offsets.Side -eq 4.0)

$tmp = Join-Path $env:TEMP "blind_eval_test_packet.json"
$written = Write-EvalPacket -Path $tmp -Claim $claim -Slice $slice -WhenIso "2026-06-11T00:00:00"
Assert-True "Write-EvalPacket returns the path" ($written -eq $tmp -and (Test-Path $tmp))

$reloaded = Get-Content $tmp -Raw | ConvertFrom-Json
Assert-True "packet round-trips tool" ($reloaded.tool -eq "plane-probe")
Assert-True "packet round-trips claims" (@($reloaded.claims).Count -eq 3)
Assert-True "packet round-trips sliced truth" (Approx $reloaded.slice.offsets.Side 4.0)
Assert-True "packet carries model + when" ($reloaded.model -eq "boxtest.prt" -and $reloaded.when -eq "2026-06-11T00:00:00")
Remove-Item $tmp -ErrorAction SilentlyContinue

# ----------------------------------------------------------------------------
# blind_evaluator: prompt shaping is BLIND (the central design rule)
# ----------------------------------------------------------------------------
Write-Host "  -- blind_evaluator: blind prompt + schema --" -ForegroundColor White

$packet = [pscustomobject]@{
    tool = "plane-probe"; operation = "build-box"; when = ""; model = "boxtest.prt"
    claims = @("the box width is 4.0", "the box depth is 2.0")
    slice  = @{ measured_extents_sorted_desc = @(4.0009, 3.0001, 2.0) }
}
$msgs = Get-BlindJudgeMessages -Packet $packet
$sys  = ($msgs | Where-Object { $_.role -eq "system" }).content
$usr  = ($msgs | Where-Object { $_.role -eq "user" }).content

Assert-True "system prompt declares the judge BLIND" ($sys -match "BLIND")
Assert-True "system prompt forbids axis-order assumptions" ($sys -match "match by VALUE" -or $sys -match "Do not assume an axis order")
Assert-True "system prompt asks for bad-generalization flagging" ($sys -match "bad generalization")
Assert-True "user message carries the claims" ($usr -match "the box width is 4.0")
Assert-True "user message carries the measured slice" ($usr -match "measured_extents_sorted_desc")

# The slice must NOT leak any mapkey / heuristic provenance into the judge input.
$forbidden = @("RunMacro", "mapkey", "dashInst", "main_dlg_cur", "ProCmd", "stdbtn_", "Odui_Dlg", "GetSurfaceType", "DimValue write")
$leak = $false
foreach ($f in $forbidden) { if ($usr -match [regex]::Escape($f)) { $leak = $true; break } }
Assert-True "slice carries NO mapkey/heuristic provenance (judge stays blind)" (-not $leak)

$schema = Get-BlindJudgeSchema
Assert-True "schema is json_schema, strict" ($schema.type -eq "json_schema" -and $schema.json_schema.strict -eq $true)
Assert-True "schema requires perClaim/overall/summary" `
    (@($schema.json_schema.schema.required) -contains "perClaim" -and @($schema.json_schema.schema.required) -contains "overall")

# ----------------------------------------------------------------------------
# blind_evaluator: Get-JudgeConfig precedence (no file -> env fallback)
# ----------------------------------------------------------------------------
Write-Host "  -- blind_evaluator: Get-JudgeConfig --" -ForegroundColor White

# Use a temp repo root with no .bluegpt_judge.json so we test the env path only.
$tmpRoot = Join-Path $env:TEMP ("blind_eval_cfg_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
$savedBase = $env:ANTHROPIC_BASE_URL; $savedTok = $env:ANTHROPIC_AUTH_TOKEN
$savedBB = $env:BLUEGPT_API_BASE; $savedBK = $env:BLUEGPT_API_KEY
try {
    $env:ANTHROPIC_BASE_URL = "https://example.test/"   # trailing slash should be trimmed
    $env:ANTHROPIC_AUTH_TOKEN = "tok-123"
    $env:BLUEGPT_API_BASE = $null; $env:BLUEGPT_API_KEY = $null
    $cfg = Get-JudgeConfig -RepoRoot $tmpRoot -DefaultModel "sonnet"
    Assert-True "config resolves from ANTHROPIC_* env" ($null -ne $cfg -and $cfg.token -eq "tok-123" -and $cfg.model -eq "sonnet")
    Assert-True "config trims trailing slash from base" ($cfg.base -eq "https://example.test")

    $env:ANTHROPIC_BASE_URL = $null; $env:ANTHROPIC_AUTH_TOKEN = $null
    $cfg2 = Get-JudgeConfig -RepoRoot $tmpRoot
    Assert-True "config returns null when nothing is set" ($null -eq $cfg2)
} finally {
    $env:ANTHROPIC_BASE_URL = $savedBase; $env:ANTHROPIC_AUTH_TOKEN = $savedTok
    $env:BLUEGPT_API_BASE = $savedBB; $env:BLUEGPT_API_KEY = $savedBK
    Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# Invoke-BlindJudge with null config must degrade, not throw.
$degraded = Invoke-BlindJudge -Packet $packet -Config $null
Assert-True "Invoke-BlindJudge degrades to error object on null config" `
    ($null -ne $degraded -and ($degraded.PSObject.Properties.Name -contains "error"))

# ----------------------------------------------------------------------------
# blind_evaluator: Show-ConvergenceReport gating
# ----------------------------------------------------------------------------
Write-Host "  -- blind_evaluator: Show-ConvergenceReport --" -ForegroundColor White

$vConfirm = [pscustomobject]@{
    perClaim = @( [pscustomobject]@{ claim="w=4"; verdict="confirm"; reason="matches 4.0009" } )
    overall  = "confirm"; summary = "all good"
}
$vRefute = [pscustomobject]@{
    perClaim = @( [pscustomobject]@{ claim="h=9.9"; verdict="refute"; reason="no extent near 9.9" } )
    overall  = "refute"; summary = "height wrong"
}
$vErr = [pscustomobject]@{ error = "judge request failed" }

# LLM-gated mode (no -Numeric): the verdict is the gate, as before.
Assert-True "report returns true only on overall=confirm" (Show-ConvergenceReport -Verdict $vConfirm)
Assert-True "report returns false on overall=refute" (-not (Show-ConvergenceReport -Verdict $vRefute))
Assert-True "report returns false on error verdict" (-not (Show-ConvergenceReport -Verdict $vErr))
Assert-True "report returns false on null verdict" (-not (Show-ConvergenceReport -Verdict $null))

# ----------------------------------------------------------------------------
# blind_evaluator: Show-ConvergenceReport DETERMINISTIC gating (the new layer)
# The numeric result is the gate; the LLM verdict is advisory and must not flip it.
# ----------------------------------------------------------------------------
Write-Host "  -- blind_evaluator: deterministic gating --" -ForegroundColor White

$numPass = Test-ExtentsMatch -Expected @(4.0,3.0) -Measured @(4.0009,3.0001)
$numFail = Test-ExtentsMatch -Expected @(4.0,9.9) -Measured @(4.0009,3.0001)

# numeric passes -> gate true even if the LLM hedged "uncertain"
$vUncertain = [pscustomobject]@{ perClaim=@(); overall="uncertain"; summary="not sure" }
Assert-True "numeric pass gates TRUE despite LLM 'uncertain'" `
    (Show-ConvergenceReport -Verdict $vUncertain -Numeric $numPass)

# numeric fails -> gate false even if the LLM said "confirm" (the dangerous case:
# a flaky/over-eager LLM must NOT be able to green-light a geometric mismatch)
Assert-True "numeric fail gates FALSE despite LLM 'confirm'" `
    (-not (Show-ConvergenceReport -Verdict $vConfirm -Numeric $numFail))

# numeric passes but the LLM/gateway errored -> gate still TRUE (arithmetic decided)
Assert-True "numeric pass gates TRUE despite LLM error" `
    (Show-ConvergenceReport -Verdict $vErr -Numeric $numPass)

# numeric passes with no LLM verdict at all -> gate TRUE
Assert-True "numeric pass gates TRUE with null verdict" `
    (Show-ConvergenceReport -Verdict $null -Numeric $numPass)

# ----------------------------------------------------------------------------
# Read-FastenerCentersFromModel - the shared fastener-center reader (assembly branch)
# Stubs the selection buffer -> SelItem.Path.GetTransform($true).GetOrigin() chain
# and asserts the dedup-by-component-id logic + never-throws contract. (The PART
# branch calls the live Get-CylinderAxes, exercised via the .cmd tools live.)
# ----------------------------------------------------------------------------
Write-Host "  -- creo_geometry: Read-FastenerCentersFromModel (assembly) --" -ForegroundColor White

# a fake selection whose Path yields a component id PATH + a transform whose origin
# is (ox,oy,oz). $Ids is the FULL root->leaf ComponentIds path (an int array).
function New-FakeCompSel {
    param($Ids, [double]$Ox, [double]$Oy, [double]$Oz)
    $fcOrigin = @($Ox, $Oy, $Oz)
    $fcXform  = [pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptMethod -Name GetOrigin -Value { $fcOrigin }.GetNewClosure()
    $fcPath   = [pscustomobject]@{ ComponentIds = @($Ids) } |
                Add-Member -PassThru -MemberType ScriptMethod -Name GetTransform -Value { param($b) $fcXform }.GetNewClosure()
    return [pscustomobject]@{ Path = $fcPath }
}
# a selection with NO component Path (a surface/edge/datum pick) -> must be skipped.
function New-FakeNoPathSel { return [pscustomobject]@{ Path = $null } }

$fkSelItems = @(
    (New-FakeCompSel -Ids @(57) -Ox -2.5547 -Oy 0 -Oz 3.0624),
    (New-FakeCompSel -Ids @(59) -Ox -2.5547 -Oy 0 -Oz 18.0624),
    (New-FakeCompSel -Ids @(59) -Ox -2.5547 -Oy 0 -Oz 18.0624)   # duplicate component path -> merged
)
$fkBuffer  = [pscustomobject]@{ Contents = $fkSelItems }
$fkSession = [pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptMethod -Name CurrentSelectionBuffer -Value { $fkBuffer }.GetNewClosure()
$fkModel   = [pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptMethod -Name FileName -Value { 'x.asm' }
# FileName is a property on the real COM object; here pass IsAsm explicitly to avoid the accessor.
$rd = Read-FastenerCentersFromModel -Session $fkSession -Model ([pscustomobject]@{ FileName = 'x.asm' }) -TypeObj $null -IsAsm $true
Assert-True "fastener read (asm): Ok" ($rd.Ok)
Assert-True "fastener read (asm): dedup by component path -> 2 centers" ($rd.Count -eq 2)
Assert-True "fastener read (asm): IsAsm flagged" ($rd.IsAsm)
Assert-True "fastener read (asm): read method labeled" ($rd.ReadMethod -match 'component-path')
Assert-True "fastener read (asm): first center is the transform origin" (
    (Approx $rd.Centers[0][0] -2.5547 1e-4) -and (Approx $rd.Centers[0][2] 3.0624 1e-4))
# diagnostics: 3 picked, 1 duplicate merged, 0 no-path/no-xform
Assert-True "fastener read (asm): RawSelected counts every pick"     ($rd.RawSelected -eq 3)
Assert-True "fastener read (asm): MergedDuplicate counts the dup"    ($rd.MergedDuplicate -eq 1)
Assert-True "fastener read (asm): SkippedNoPath 0 (all components)"  ($rd.SkippedNoPath -eq 0)
# Axes returned parallel to Centers; the stub xform has no GetZAxis -> null axes (no throw)
Assert-True "fastener read (asm): Axes parallel to Centers"          (@($rd.Axes).Count -eq $rd.Count)
Assert-True "fastener read (asm): no-GetZAxis stub -> null axes, AxisReads 0" ($rd.AxisReads -eq 0)

# AXIS CAPTURE: a stub whose transform DOES expose GetZAxis -> the fastener's own
# bore axis is read into .Axes (parallel to Centers) and AxisReads counts them.
function New-FakeCompSelAx {
    param($Ids, [double]$Ox, [double]$Oy, [double]$Oz, [double]$Zx, [double]$Zy, [double]$Zz)
    $fcOrigin = @($Ox, $Oy, $Oz)
    $fcZ      = @($Zx, $Zy, $Zz)
    $fcXform  = [pscustomobject]@{} |
                Add-Member -PassThru -MemberType ScriptMethod -Name GetOrigin -Value { $fcOrigin }.GetNewClosure() |
                Add-Member -PassThru -MemberType ScriptMethod -Name GetZAxis  -Value { $fcZ }.GetNewClosure()
    $fcPath   = [pscustomobject]@{ ComponentIds = @($Ids) } |
                Add-Member -PassThru -MemberType ScriptMethod -Name GetTransform -Value { param($b) $fcXform }.GetNewClosure()
    return [pscustomobject]@{ Path = $fcPath }
}
$fkAx = @(
    (New-FakeCompSelAx -Ids @(1) -Ox 0 -Oy 5 -Oz 0 -Zx 0 -Zy 1 -Zz 0),
    (New-FakeCompSelAx -Ids @(2) -Ox 2 -Oy 5 -Oz 0 -Zx 0 -Zy 1 -Zz 0),
    (New-FakeCompSelAx -Ids @(3) -Ox 0 -Oy 5 -Oz 3 -Zx 0 -Zy 1 -Zz 0)
)
$fkAxSess = [pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptMethod -Name CurrentSelectionBuffer -Value { [pscustomobject]@{ Contents = $fkAx } }.GetNewClosure()
$rdAx = Read-FastenerCentersFromModel -Session $fkAxSess -Model ([pscustomobject]@{ FileName='ax.asm' }) -TypeObj $null -IsAsm $true
Assert-True "fastener read (asm): GetZAxis captured -> AxisReads 3" ($rdAx.AxisReads -eq 3)
Assert-True "fastener read (asm): axis[0] is +Y"                    ((Approx $rdAx.Axes[0][1] 1.0 1e-9) -and (Approx $rdAx.Axes[0][0] 0.0 1e-9))

# NESTED assembly: two DISTINCT instances sharing a LEAF id (7) in different
# subassemblies (paths 1|5|7 vs 1|6|7) must NOT collapse -- the leaf-only dedup bug.
$fkNested = @(
    (New-FakeCompSel -Ids @(1,5,7) -Ox 1.0 -Oy 0 -Oz 2.0),
    (New-FakeCompSel -Ids @(1,6,7) -Ox 3.0 -Oy 0 -Oz 4.0)   # same leaf 7, different path
)
$fkNestSess = [pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptMethod -Name CurrentSelectionBuffer -Value { [pscustomobject]@{ Contents = $fkNested } }.GetNewClosure()
$rdN = Read-FastenerCentersFromModel -Session $fkNestSess -Model ([pscustomobject]@{ FileName='n.asm' }) -TypeObj $null -IsAsm $true
Assert-True "fastener read (asm nested): shared leaf id kept distinct -> 2 centers" ($rdN.Count -eq 2)
Assert-True "fastener read (asm nested): no false merge" ($rdN.MergedDuplicate -eq 0)

# TRULY duplicated full path (1|5|7 twice) SHOULD merge to 1.
$fkDupPath = @(
    (New-FakeCompSel -Ids @(1,5,7) -Ox 1.0 -Oy 0 -Oz 2.0),
    (New-FakeCompSel -Ids @(1,5,7) -Ox 1.0 -Oy 0 -Oz 2.0)
)
$fkDupSess = [pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptMethod -Name CurrentSelectionBuffer -Value { [pscustomobject]@{ Contents = $fkDupPath } }.GetNewClosure()
$rdD = Read-FastenerCentersFromModel -Session $fkDupSess -Model ([pscustomobject]@{ FileName='d.asm' }) -TypeObj $null -IsAsm $true
Assert-True "fastener read (asm): identical full path merges -> 1 center" ($rdD.Count -eq 1)

# no-Path picks (surfaces/edges) are skipped and COUNTED, not silently lost.
$fkMixed = @(
    (New-FakeCompSel -Ids @(10) -Ox 0.0 -Oy 0 -Oz 0.0),
    (New-FakeNoPathSel),
    (New-FakeNoPathSel)
)
$fkMixSess = [pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptMethod -Name CurrentSelectionBuffer -Value { [pscustomobject]@{ Contents = $fkMixed } }.GetNewClosure()
$rdM = Read-FastenerCentersFromModel -Session $fkMixSess -Model ([pscustomobject]@{ FileName='m.asm' }) -TypeObj $null -IsAsm $true
Assert-True "fastener read (asm): no-path picks skipped -> 1 center"   ($rdM.Count -eq 1)
Assert-True "fastener read (asm): SkippedNoPath counted (2)"           ($rdM.SkippedNoPath -eq 2)
Assert-True "fastener read (asm): RawSelected includes skipped (3)"    ($rdM.RawSelected -eq 3)

# empty selection -> Ok false, no throw
$fkEmptySess = [pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptMethod -Name CurrentSelectionBuffer -Value { [pscustomobject]@{ Contents = @() } }.GetNewClosure()
$rdEmpty = Read-FastenerCentersFromModel -Session $fkEmptySess -Model $null -TypeObj $null -IsAsm $true
Assert-True "fastener read (asm): empty selection -> not ok, no throw" (-not $rdEmpty.Ok)
Assert-True "fastener read: null model -> not ok, no throw" (-not (Read-FastenerCentersFromModel -Session $null -Model $null -TypeObj $null).Ok)

# ----------------------------------------------------------------------------
# SUMMARY
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host ("  ============================================") -ForegroundColor Cyan
Write-Host ("  RESULTS: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { "Green" } else { "Red" })
Write-Host ("  ============================================") -ForegroundColor Cyan
Write-Host ""

if ($script:fail -gt 0) { exit 1 } else { exit 0 }
