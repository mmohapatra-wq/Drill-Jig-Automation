# ============================================================================
# lib\tests\run_hole_layout_tests.ps1 - offline unit tests for lib\hole_layout.ps1
# ============================================================================
# Runs WITHOUT Creo and WITHOUT network. Exercises the PURE half of the new
# standalone holelayoutinator.cmd tool: pattern analysis (Get-HoleLayoutStats),
# the ASCII report formatter (Format-HoleLayoutReport), and the hole_layout.json
# round-trip (Write-HoleLayout / Read-HoleLayout). Mirrors run_fastener_tests.ps1.
#
# ISOLATION: dot-sources ONLY lib\hole_layout.ps1 (the new pure lib). It does NOT
# load any shared lib, so a green run here proves the tool's offline logic without
# touching anything drilljig-gui depends on.
#
# Run:  powershell -ExecutionPolicy Bypass -File lib\tests\run_hole_layout_tests.ps1
# Exit code 0 = all passed, 1 = at least one failure.
# ============================================================================

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Split-Path -Parent $here
# creo_geometry.ps1 first: Read-HoleCentersFromModel calls its Get-EdgeArcCenter /
# Get-CylinderAxisFromSurface / Get-Comp (loaded read-only; no COM at load time).
. (Join-Path $libDir 'creo_geometry.ps1')
. (Join-Path $libDir 'hole_layout.ps1')

$script:pass = 0
$script:fail = 0
function Assert-True {
    param([string]$Name, [bool]$Cond, [string]$Detail = "")
    if ($Cond) { Write-Host "  [PASS] $Name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  [FAIL] $Name $Detail" -ForegroundColor Red; $script:fail++ }
}
function Approx { param([double]$A,[double]$B,[double]$Tol=1e-9) return ([Math]::Abs($A-$B) -le $Tol) }

Write-Host ""
Write-Host "  Running hole_layout unit tests (offline)..." -ForegroundColor Cyan
Write-Host ""

# ----------------------------------------------------------------------------
# Get-HoleLayoutStats - bounding box + spacing
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# Get-ComposedRootPoint / Get-DistinctPointCount / Select-BestHoleCenters
# (the "8 picked -> 1 bore center" fix: choose the read that distinguishes holes)
# ----------------------------------------------------------------------------
Write-Host "  -- Get-ComposedRootPoint / Select-BestHoleCenters --" -ForegroundColor White

# identity transform: root == member
$rIdent = Get-ComposedRootPoint -Member @(1,2,3) -O @(0,0,0) -Bx @(1,0,0) -By @(0,1,0) -Bz @(0,0,1)
Assert-True "composed: identity -> member unchanged" ((Approx $rIdent[0] 1) -and (Approx $rIdent[1] 2) -and (Approx $rIdent[2] 3))
# translation only: member (0,0,0) + O (10,20,30) -> (10,20,30)
$rTrans = Get-ComposedRootPoint -Member @(0,0,0) -O @(10,20,30) -Bx @(1,0,0) -By @(0,1,0) -Bz @(0,0,1)
Assert-True "composed: translation applied" ((Approx $rTrans[0] 10) -and (Approx $rTrans[1] 20) -and (Approx $rTrans[2] 30))
# 90deg-about-Z rotation: X->+Y, Y->-X. member (1,0,0), basis cols X=(0,1,0),Y=(-1,0,0),Z=(0,0,1) -> (0,1,0)
$rRot = Get-ComposedRootPoint -Member @(1,0,0) -O @(0,0,0) -Bx @(0,1,0) -By @(-1,0,0) -Bz @(0,0,1)
Assert-True "composed: 90deg-Z rotation (1,0,0)->(0,1,0)" ((Approx $rRot[0] 0) -and (Approx $rRot[1] 1) -and (Approx $rRot[2] 0))
# null / NaN inputs -> null, no throw
Assert-True "composed: null member -> null" ($null -eq (Get-ComposedRootPoint -Member $null -O @(0,0,0) -Bx @(1,0,0) -By @(0,1,0) -Bz @(0,0,1)))
Assert-True "composed: NaN -> null" ($null -eq (Get-ComposedRootPoint -Member @([double]::NaN,0,0) -O @(0,0,0) -Bx @(1,0,0) -By @(0,1,0) -Bz @(0,0,1)))

# distinct-point count
Assert-True "distinct: 3 unique of 4 (one dup)" ((Get-DistinctPointCount -Points @(@(0,0,0),@(1,0,0),@(0,0,0),@(2,0,0))) -eq 3)
Assert-True "distinct: nulls ignored" ((Get-DistinctPointCount -Points @(@(0,0,0),$null,@(1,0,0))) -eq 2)
Assert-True "distinct: empty -> 0" ((Get-DistinctPointCount -Points @()) -eq 0)

# THE REGRESSION: 8 bores in an assembly where the descriptor axis origin (Member) is
# the SAME component-local point for all 8 (the "8 -> 1" bug), but each component's
# transform origin (Xform) is distinct -> composed Root is distinct. Select-BestHoleCenters
# MUST pick 'root' (or 'xform') and yield 8 distinct, NOT collapse to 1.
$cands = @()
foreach ($k in 0..7) {
    $ox = 2.0 * $k        # 8 distinct component positions along X
    # Member is IDENTICAL for every bore (modelled at the part's own origin) -> the bug
    $cands += [pscustomobject]@{
        Member = @(0.5, 0.0, 0.0)
        Xform  = @($ox, 0.0, 0.0)
        Root   = (Get-ComposedRootPoint -Member @(0.5,0,0) -O @($ox,0,0) -Bx @(1,0,0) -By @(0,1,0) -Bz @(0,0,1))
    }
}
$sel = Select-BestHoleCenters -Candidates $cands
Assert-True "select: member read collapses to 1 (the bug)" ($sel.Counts.member -eq 1)
Assert-True "select: transform-origin read is 8 distinct" ($sel.Counts.xform -eq 8)
Assert-True "select: composed-root read is 8 distinct"    ($sel.Counts.root -eq 8)
Assert-True "select: chooses a distinguishing read (root or xform)" (@('root','xform') -contains $sel.Which)
Assert-True "select: prefers root on the tie"             ($sel.Which -eq 'root')
Assert-True "select: returns 8 centers"                   (@($sel.Centers).Count -eq 8)

# when NOTHING distinguishes (Member same, no Xform/Root) -> member, distinct 1 (honest)
$flat = @()
foreach ($k in 0..2) { $flat += [pscustomobject]@{ Member=@(1,1,1); Xform=$null; Root=$null } }
$selFlat = Select-BestHoleCenters -Candidates $flat
Assert-True "select: no distinguishing read -> member, distinct 1" ($selFlat.Which -eq 'member' -and $selFlat.Distinct -eq 1)

# when ONLY member distinguishes (a real part, no component paths) -> member, distinct N
$partC = @()
foreach ($k in 0..3) { $partC += [pscustomobject]@{ Member=@($k,0,0); Xform=$null; Root=$null } }
$selPart = Select-BestHoleCenters -Candidates $partC
Assert-True "select: part (member distinct) -> member, 4 distinct" ($selPart.Which -eq 'member' -and $selPart.Distinct -eq 4)

# THE REAL LIVE CASE (probe 2026-07): the SelItem is a Type=0 hole FEATURE, all 8 share
# ONE component at identity/origin, so Member and Xform BOTH collapse to 1 -- but each
# feature's bore SUB-surface has a distinct axis origin. Only Sub/SubRoot distinguish.
# Select-BestHoleCenters MUST choose the sub read and yield 8, not 1.
$subC = @()
foreach ($k in 0..7) {
    $sx = 1.5 * $k
    # Member (descriptor off the feature) unreadable-or-same; Xform identity origin (same);
    # Sub = the bore's own axis origin (distinct); SubRoot = Sub through identity = same as Sub.
    $subC += [pscustomobject]@{
        Member  = $null
        Sub     = @($sx, 0.0, 2.0)
        Xform   = @(0.0, 0.0, 0.0)
        Root    = $null
        SubRoot = (Get-ComposedRootPoint -Member @($sx,0,2) -O @(0,0,0) -Bx @(1,0,0) -By @(0,1,0) -Bz @(0,0,1))
    }
}
$selSub = Select-BestHoleCenters -Candidates $subC
Assert-True "select(sub): member collapses to 0/1"        ($selSub.Counts.member -le 1)
Assert-True "select(sub): xform collapses to 1 (identity)" ($selSub.Counts.xform -eq 1)
Assert-True "select(sub): sub-surface read is 8 distinct"  ($selSub.Counts.sub -eq 8)
Assert-True "select(sub): sub-root read is 8 distinct"     ($selSub.Counts.subroot -eq 8)
Assert-True "select(sub): chooses subroot (preferred over sub on tie)" ($selSub.Which -eq 'subroot')
Assert-True "select(sub): returns 8 centers"              (@($selSub.Centers).Count -eq 8)

# sub non-identity component: Sub member-frame same-ish but component transform distinct ->
# SubRoot distinguishes even if Sub alone doesn't. (each hole in its OWN component)
$subC2 = @()
foreach ($k in 0..3) {
    $ox = 5.0 * $k
    $subC2 += [pscustomobject]@{
        Member=$null; Sub=@(0.5,0.0,0.0); Xform=@($ox,0,0); Root=$null
        SubRoot=(Get-ComposedRootPoint -Member @(0.5,0,0) -O @($ox,0,0) -Bx @(1,0,0) -By @(0,1,0) -Bz @(0,0,1))
    }
}
$selSub2 = Select-BestHoleCenters -Candidates $subC2
Assert-True "select(sub2): sub alone collapses to 1"      ($selSub2.Counts.sub -eq 1)
Assert-True "select(sub2): subroot distinguishes -> 4"    ($selSub2.Counts.subroot -eq 4)
Assert-True "select(sub2): chooses subroot"               ($selSub2.Which -eq 'subroot')

# THE ACTUAL LIVE CASE (probe 2026-07, 150-110-0030-101.asm): every assembly-level read
# collapses (member/sub/xform/root/subroot all 1-or-0) because the 8 picks are one
# component whose surfaces don't read through the assembly -- ONLY the leaf-by-id read
# (clicked id resolved in the leaf part model + composed to root) gives 8 distinct.
# Select-BestHoleCenters MUST choose leafbyid.
$leafC = @()
foreach ($k in 0..7) {
    $lx = 1.25 * $k
    $leafC += [pscustomobject]@{
        LeafById = @($lx, 0.0, 3.0)     # per-hole distinct (leaf part frame + transform)
        Member   = $null                # unreadable through the assembly
        Sub      = @(0.0, 0.0, 0.0)     # sub read collapsed (all same)
        Xform    = @(0.0, 50.35, -27.5) # one component -> all identical
        Root     = $null
        SubRoot  = $null
    }
}
$selLeaf = Select-BestHoleCenters -Candidates $leafC
Assert-True "select(leaf): leaf-by-id read is 8 distinct"  ($selLeaf.Counts.leafbyid -eq 8)
Assert-True "select(leaf): assembly reads collapse (sub<=1, xform<=1)" ($selLeaf.Counts.sub -le 1 -and $selLeaf.Counts.xform -le 1)
Assert-True "select(leaf): chooses leafbyid"               ($selLeaf.Which -eq 'leafbyid')
Assert-True "select(leaf): returns 8 centers"              (@($selLeaf.Centers).Count -eq 8)
# leafbyid also wins a TIE against subroot (most trustworthy)
$tieC = @()
foreach ($k in 0..3) { $tieC += [pscustomobject]@{ LeafById=@($k,0,0); SubRoot=@($k,9,0) } }
$selTie = Select-BestHoleCenters -Candidates $tieC
Assert-True "select(leaf): leafbyid beats subroot on a tie" ($selTie.Which -eq 'leafbyid')
# a plain PART (only Member set) is unaffected -> still 'member'
$partOnly = @(); foreach ($k in 0..2) { $partOnly += [pscustomobject]@{ Member=@($k,0,0) } }
Assert-True "select(leaf): plain part still resolves member" ((Select-BestHoleCenters -Candidates $partOnly).Which -eq 'member')

Assert-True "select: null candidates -> no throw" ((Select-BestHoleCenters -Candidates $null).Distinct -eq 0)

Write-Host "  -- Get-HoleLayoutStats --" -ForegroundColor White

# a clean 3x2 grid: X in {0,2,4}, Z in {0,3}. spacing min = 2 (X step), max = the
# far diagonal sqrt(4^2+3^2)=5. bounding box 4 x 3.
$grid = @(
    [pscustomobject]@{ X=0; Z=0 }, [pscustomobject]@{ X=2; Z=0 }, [pscustomobject]@{ X=4; Z=0 },
    [pscustomobject]@{ X=0; Z=3 }, [pscustomobject]@{ X=2; Z=3 }, [pscustomobject]@{ X=4; Z=3 }
)
$st = Get-HoleLayoutStats -Points $grid
Assert-True "stats: valid, 6 holes"            ($st.Valid -and $st.Count -eq 6)
Assert-True "stats: bounding box 4 x 3"        ((Approx $st.Width 4.0) -and (Approx $st.Height 3.0))
Assert-True "stats: min spacing 2.0"           (Approx $st.MinSpacing 2.0)
Assert-True "stats: max spacing 5.0 (diag)"    (Approx $st.MaxSpacing 5.0)
Assert-True "stats: nearest pair distance 2.0" ($null -ne $st.NearestPair -and (Approx $st.NearestPair.Dist 2.0))

# single hole -> spacing 0, no nearest pair, still valid
$one = Get-HoleLayoutStats -Points @([pscustomobject]@{ X=1.5; Z=2.5 })
Assert-True "stats: single hole valid, spacing 0" ($one.Valid -and $one.Count -eq 1 -and (Approx $one.MinSpacing 0.0) -and ($null -eq $one.NearestPair))

# ----------------------------------------------------------------------------
# collision check (HoleDia): strictly-closer fails, tangent allowed
# ----------------------------------------------------------------------------
Write-Host "  -- Get-HoleLayoutStats collision check --" -ForegroundColor White

# two holes 0.5 apart; HoleDia 1.0 -> collision (0.5 < 1.0)
$close = @([pscustomobject]@{ X=0; Z=0 }, [pscustomobject]@{ X=0.5; Z=0 })
$stC = Get-HoleLayoutStats -Points $close -HoleDia 1.0
Assert-True "collision: 0.5 apart < 1.0 dia -> 1 collision" (@($stC.Collisions).Count -eq 1)
# tangent: exactly HoleDia apart -> allowed (no collision)
$tan = @([pscustomobject]@{ X=0; Z=0 }, [pscustomobject]@{ X=1.0; Z=0 })
$stT = Get-HoleLayoutStats -Points $tan -HoleDia 1.0
Assert-True "collision: tangent (== dia) allowed -> 0 collisions" (@($stT.Collisions).Count -eq 0)
# HoleDia 0 (default) -> check OFF
$stOff = Get-HoleLayoutStats -Points $close -HoleDia 0
Assert-True "collision: HoleDia 0 -> check OFF" (@($stOff.Collisions).Count -eq 0)
# HoleDia < 0 -> invalid, no throw
$stNeg = Get-HoleLayoutStats -Points $close -HoleDia -1
Assert-True "collision: negative HoleDia -> invalid, no throw" (-not $stNeg.Valid)

# ----------------------------------------------------------------------------
# defensive: non-numeric / NaN / empty / null
# ----------------------------------------------------------------------------
Write-Host "  -- Get-HoleLayoutStats defensive --" -ForegroundColor White

$mixed = @(
    [pscustomobject]@{ X=1; Z=1 },
    [pscustomobject]@{ X='oops'; Z=2 },       # non-numeric -> skipped
    [pscustomobject]@{ X=[double]::NaN; Z=3 },  # NaN -> skipped
    [pscustomobject]@{ X=4; Z=4 }
)
$stM = Get-HoleLayoutStats -Points $mixed
Assert-True "defensive: non-numeric + NaN skipped -> 2 kept, 2 skipped" ($stM.Count -eq 2 -and $stM.Skipped -eq 2)
$stEmpty = Get-HoleLayoutStats -Points @()
Assert-True "defensive: empty -> invalid, no throw" (-not $stEmpty.Valid -and $stEmpty.Count -eq 0)
$stNull = Get-HoleLayoutStats -Points $null
Assert-True "defensive: null Points -> invalid, no throw" (-not $stNull.Valid)

# ----------------------------------------------------------------------------
# Format-HoleLayoutReport - ASCII lines, no throw
# ----------------------------------------------------------------------------
Write-Host "  -- Format-HoleLayoutReport --" -ForegroundColor White

$layoutObj = [pscustomobject]@{ Points = $grid; AxisX='X'; AxisZ='Z'; Margin=0.25 }
$rep = Format-HoleLayoutReport -Stats $st -Layout $layoutObj
Assert-True "report: returns lines" (@($rep).Count -ge 3)
Assert-True "report: mentions holes count" (($rep -join "`n") -match 'Holes: 6')
Assert-True "report: lists points" (($rep -join "`n") -match 'Points \(corner-relative')
# ASCII-only (no non-ASCII byte would mojibake the console)
$nonAscii = ($rep -join "`n").ToCharArray() | Where-Object { [int]$_ -gt 126 }
Assert-True "report: ASCII-only output" (@($nonAscii).Count -eq 0)
Assert-True "report: null stats -> no throw" (@(Format-HoleLayoutReport -Stats $null).Count -ge 1)
# collision line appears when collisions exist
$repC = Format-HoleLayoutReport -Stats $stC
Assert-True "report: collision surfaced" (($repC -join "`n") -match 'COLLISION')

# ----------------------------------------------------------------------------
# Write-HoleLayout / Read-HoleLayout round-trip (own file, own function names)
# ----------------------------------------------------------------------------
Write-Host "  -- Write-HoleLayout / Read-HoleLayout round-trip --" -ForegroundColor White

$tmp = Join-Path $env:TEMP ("hole_layout_test_{0}.json" -f ([guid]::NewGuid().ToString('N')))
try {
    $layout = [pscustomobject]@{ Points = $grid; AxisX='X'; AxisZ='Z'; AxisXSign=1.0; AxisZSign=1.0; Margin=0.5 }
    $ok = Write-HoleLayout -Path $tmp -Layout $layout -Stats $st -SourceModel 'holes.prt' -Units 'inch' -ReadMethod 'cylinder-axis (selected bores)' -WhenIso '2026-07-24T00:00:00Z'
    Assert-True "roundtrip: write ok" ($ok -and (Test-Path $tmp))
    $rd = Read-HoleLayout -Path $tmp
    Assert-True "roundtrip: read valid, 6 points" ($rd.Valid -and $rd.Count -eq 6)
    Assert-True "roundtrip: Kind tag = hole-layout" ($rd.Kind -eq 'hole-layout')
    Assert-True "roundtrip: axes + units preserved" ($rd.AxisX -eq 'X' -and $rd.AxisZ -eq 'Z' -and $rd.Units -eq 'inch')
    Assert-True "roundtrip: margin preserved" (Approx $rd.Margin 0.5)
    Assert-True "roundtrip: SpanX/SpanZ derived (4 x 3)" ((Approx $rd.SpanX 4.0) -and (Approx $rd.SpanZ 3.0))
    Assert-True "roundtrip: source model preserved" ($rd.SourceModel -eq 'holes.prt')
} finally {
    Remove-Item -Path $tmp -ErrorAction SilentlyContinue
}

# missing file / null layout -> no throw
$rdMissing = Read-HoleLayout -Path (Join-Path $env:TEMP 'definitely_not_here_zzz.json')
Assert-True "roundtrip: missing file -> invalid, no throw" (-not $rdMissing.Valid)
Assert-True "roundtrip: write null layout -> false, no throw" (-not (Write-HoleLayout -Path $tmp -Layout $null))

# ----------------------------------------------------------------------------
# Read-HoleCentersFromModel - the shared reader used by the flat-DJ front-ends.
# Stubs the selection buffer -> SelItem whose EDGES (via DBParent leaf model
# GetItemById -> ListSubItems(ITEM_EDGE)) expose an arc center per hole (the proven
# live read). Asserts it returns the fastener-reader-shaped result with distinct
# centers, and the never-throws contract. Mirrors the live "8 holes -> 8 centers" case.
# ----------------------------------------------------------------------------
Write-Host "  -- Read-HoleCentersFromModel (shared hole reader) --" -ForegroundColor White

# a stub edge whose curve descriptor is a circle with .Center + .Radius (arc read).
function New-FakeArcEdge {
    param([double]$Cx, [double]$Cy, [double]$Cz, [double]$R)
    $ctr = @($Cx, $Cy, $Cz)
    $desc = [pscustomobject]@{ Center = $ctr; Radius = $R }
    return [pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptMethod -Name GetCurveDescriptor -Value { $desc }.GetNewClosure()
}
# a stub straight edge (no center) so the reader must skip past it to the arc.
function New-FakeStraightEdge {
    $desc = [pscustomobject]@{ End1 = @(0,0,0) }
    return [pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptMethod -Name GetCurveDescriptor -Value { $desc }.GetNewClosure()
}
# a hole pick: SelItem.Id + DBParent (leaf model) whose GetItemById(FEATURE) returns a
# feature whose ListSubItems(ITEM_EDGE) yields [straight, arc]; + Path.GetTransform
# (identity) so the composed root == the arc center. TypeObj exposes the ITEM_* ints.
function New-FakeHolePick {
    param([int]$Id, [double]$Cx, [double]$Cy, [double]$Cz, [double]$R)
    $arc = New-FakeArcEdge -Cx $Cx -Cy $Cy -Cz $Cz -R $R
    $straight = New-FakeStraightEdge
    $edges = @($straight, $arc)
    $feat = [pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptMethod -Name ListSubItems -Value { param($t) $edges }.GetNewClosure()
    $leaf = [pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptMethod -Name GetItemById -Value { param($t,$i) $feat }.GetNewClosure()
    $selItem = [pscustomobject]@{ Id = $Id; DBParent = $leaf }
    # identity transform (member==root)
    $xf = [pscustomobject]@{} |
        Add-Member -PassThru -MemberType ScriptMethod -Name GetOrigin -Value { @(0.0,0.0,0.0) }.GetNewClosure() |
        Add-Member -PassThru -MemberType ScriptMethod -Name GetXAxis  -Value { @(1.0,0.0,0.0) }.GetNewClosure() |
        Add-Member -PassThru -MemberType ScriptMethod -Name GetYAxis  -Value { @(0.0,1.0,0.0) }.GetNewClosure() |
        Add-Member -PassThru -MemberType ScriptMethod -Name GetZAxis  -Value { @(0.0,0.0,1.0) }.GetNewClosure()
    $path = [pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptMethod -Name GetTransform -Value { param($b) $xf }.GetNewClosure()
    return [pscustomobject]@{ SelItem = $selItem; Path = $path }
}
# TypeObj stub with the ITEM_* enum ints as they read on this build.
$hlType = [pscustomobject]@{ ITEM_FEATURE=0; ITEM_SURFACE=1; ITEM_EDGE=2; ITEM_AXIS=4 }
# 8 holes on a Y-Z panel (X constant) -- the real 2x4 pattern shape.
$hlPicks = @(
    (New-FakeHolePick -Id 74  -Cx 109.381 -Cy 25.9269 -Cz -10.75 -R 0.125),
    (New-FakeHolePick -Id 125 -Cx 109.381 -Cy 24.4269 -Cz -10.75 -R 0.125),
    (New-FakeHolePick -Id 126 -Cx 109.381 -Cy 24.4269 -Cz -12.25 -R 0.125),
    (New-FakeHolePick -Id 127 -Cx 109.381 -Cy 25.9269 -Cz -12.25 -R 0.125),
    (New-FakeHolePick -Id 128 -Cx 109.381 -Cy 25.9269 -Cz -15.25 -R 0.125),
    (New-FakeHolePick -Id 129 -Cx 109.381 -Cy 24.4269 -Cz -15.25 -R 0.125),
    (New-FakeHolePick -Id 130 -Cx 109.381 -Cy 24.4269 -Cz -16.75 -R 0.125),
    (New-FakeHolePick -Id 131 -Cx 109.381 -Cy 25.9269 -Cz -16.75 -R 0.125)
)
$hlSess = [pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptMethod -Name CurrentSelectionBuffer -Value { [pscustomobject]@{ Contents = $hlPicks } }.GetNewClosure()
$hr = Read-HoleCentersFromModel -Session $hlSess -Model ([pscustomobject]@{ FileName='x.asm' }) -TypeObj $hlType
Assert-True "hole-read: Ok"                              ($hr.Ok)
Assert-True "hole-read: 8 distinct centers"             ($hr.Count -eq 8)
Assert-True "hole-read: chose leafbyid (edge arc)"      ($hr.Which -eq 'leafbyid')
Assert-True "hole-read: axes parallel to centers"       (@($hr.Axes).Count -eq $hr.Count)
Assert-True "hole-read: median dia 0.25 (R=0.125)"      (Approx $hr.MedianDia 0.25 1e-9)
Assert-True "hole-read: read method labeled"            ($hr.ReadMethod -match 'hole edge-arc')
Assert-True "hole-read: first center is the arc center" (
    (Approx $hr.Centers[0][0] 109.381 1e-4) -and (Approx $hr.Centers[0][1] 25.9269 1e-4))
# empty selection -> not ok, no throw, helpful message
$hlEmptySess = [pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptMethod -Name CurrentSelectionBuffer -Value { [pscustomobject]@{ Contents = @() } }.GetNewClosure()
$hrEmpty = Read-HoleCentersFromModel -Session $hlEmptySess -Model $null -TypeObj $hlType
Assert-True "hole-read: empty selection -> not ok, no throw" (-not $hrEmpty.Ok -and $hrEmpty.Message -match 'select')
Assert-True "hole-read: null session -> not ok, no throw"    (-not (Read-HoleCentersFromModel -Session $null -Model $null -TypeObj $hlType).Ok)

# ----------------------------------------------------------------------------
# SUMMARY
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host ("  ============================================") -ForegroundColor Cyan
Write-Host ("  hole-layout tests: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { "Green" } else { "Red" })
Write-Host ("  ============================================") -ForegroundColor Cyan
Write-Host ""
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
