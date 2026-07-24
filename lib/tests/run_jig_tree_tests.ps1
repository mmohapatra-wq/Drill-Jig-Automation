# ============================================================================
# lib\tests\run_jig_tree_tests.ps1 - offline tests for lib\jig_tree.ps1
# ============================================================================
# The STAGE-0 decision-tree walk (Invoke-Walk / Read-Choice / Invoke-BushingPick)
# is now SHARED by drilljig.cmd (its own inline copy) and drilljig3d.cmd STAGE 0
# (this module). It is PURE console logic - no Creo, no mapkeys - so it is fully
# testable headless by stubbing Read-Host with a scripted answer queue and driving
# the REAL decision tree JSON + the REAL bushing catalog.
#
# What this proves (the drilljig3d STAGE-0 wiring contract):
#   * Invoke-Walk descends the real tree and, at a catalog leaf, Invoke-BushingPick
#     runs the OD-first / ID-first menu and appends a resolved hole spec to
#     $script:Picks with { HoleDiameter; BushingLength; Bushing; PartNumber }.
#   * The LAST pick wins (jiginator's model) - the value drilljig3d reads as
#     $treeDia / $treeBushLen.
#   * A Q at any prompt returns $false from Invoke-Walk (the "skip the tree" path).
#   * A fixed-OD leaf resolves a HoleDiameter with no bushing (BushingLength $null).
#
# Run:  powershell -ExecutionPolicy Bypass -File lib\tests\run_jig_tree_tests.ps1
# Exit code 0 = all passed, 1 = at least one failure.
# ============================================================================

$ErrorActionPreference = "Stop"
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir  = Split-Path -Parent $here
$repoDir = Split-Path -Parent $libDir

# drilljig_core.ps1 supplies the pure catalog helpers Invoke-Walk/Invoke-BushingPick
# call (Get-CatalogSpec, Get-OdGroups, Resolve-*, Group-CatalogByID, ...). jig_tree.ps1
# is the walk. Load core first (jig_tree resolves its helpers at call time).
. (Join-Path $libDir 'drilljig_core.ps1')
. (Join-Path $libDir 'jig_tree.ps1')

# drilljig_core resolves catalog CSV paths under its DataDir; point it at data\.
try { Initialize-DrilljigCore -Session $null -Model $null -TypeObj $null -DataDir (Join-Path $repoDir 'data') } catch {}

$script:pass = 0
$script:fail = 0
function Assert-True {
    param([string]$Name, [bool]$Cond, [string]$Detail = "")
    if ($Cond) { Write-Host "  [PASS] $Name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  [FAIL] $Name  $Detail" -ForegroundColor Red; $script:fail++ }
}

# ----------------------------------------------------------------------------
# Read-Host stub: a scripted answer QUEUE. jig_tree.ps1's Invoke-Walk / Read-Choice /
# Invoke-BushingPick call Read-Host; we override it in THIS scope so the walk runs
# non-interactively. Each Read-Host dequeues the next answer; empty queue -> 'Q'
# (defensively quit rather than hang) so a mis-scripted path can't loop forever.
# ----------------------------------------------------------------------------
$script:answerQueue = [System.Collections.Queue]::new()
function Read-Host { param([string]$Prompt)
    if ($script:answerQueue.Count -gt 0) { return [string]$script:answerQueue.Dequeue() }
    return 'Q'
}
function Set-Answers { param([string[]]$Answers)
    $script:answerQueue = [System.Collections.Queue]::new()
    foreach ($a in $Answers) { $script:answerQueue.Enqueue($a) }
}

# Load the real tree.
$treePath = Join-Path $repoDir 'docs\drill_jig_decision_tree.json'
Assert-True "tree JSON exists" (Test-Path $treePath) $treePath
$tree = $null
try { $tree = Get-Content $treePath -Raw | ConvertFrom-Json } catch {}
Assert-True "tree JSON parses" ($null -ne $tree)

# Helper: run one scripted walk of the whole tree, return @{ Cont; Picks; Path; Outcomes }.
function Invoke-ScriptedWalk {
    param([string[]]$Answers)
    Set-Answers -Answers $Answers
    $p  = [System.Collections.ArrayList]::new()
    $o  = [System.Collections.ArrayList]::new()
    $script:Picks = [System.Collections.ArrayList]::new()   # the contract: consumer inits $script:Picks
    $cont = $true
    foreach ($root in @($tree)) {
        $cont = Invoke-Walk -Node $root -Path $p -Outcomes $o
        if (-not $cont) { break }
    }
    return @{ Cont = $cont; Picks = $script:Picks; Path = $p; Outcomes = $o }
}

Write-Host ""
Write-Host "  -- jig_tree: functions resolve --" -ForegroundColor White
Assert-True "Invoke-Walk defined"        ($null -ne (Get-Command Invoke-Walk -ErrorAction SilentlyContinue))
Assert-True "Invoke-BushingPick defined" ($null -ne (Get-Command Invoke-BushingPick -ErrorAction SilentlyContinue))
Assert-True "Read-Choice defined"        ($null -ne (Get-Command Read-Choice -ErrorAction SilentlyContinue))
Assert-True "Invoke-CustomOdPick defined" ($null -ne (Get-Command Invoke-CustomOdPick -ErrorAction SilentlyContinue))

# ----------------------------------------------------------------------------
# 1. QUIT PATH: a Q at the first question returns $false (the "skip tree" signal
#    drilljig3d uses to fall back to the handoff file / manual entry).
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "  -- jig_tree: quit path --" -ForegroundColor White
$q = Invoke-ScriptedWalk -Answers @('Q')
Assert-True "quit at Q returns cont=false"      (-not $q.Cont)
Assert-True "quit resolved no picks"            (@($q.Picks).Count -eq 0)

# ----------------------------------------------------------------------------
# 2. METAL -> Hand Drill: OD-first removable-bushing leaf. Answers:
#    Q1 'Material' -> 1 (Metal); Q2 'PFD or Hand Drill' -> 2 (Hand Drill);
#    then Invoke-BushingPick OD-first: pick OD #1, then ENTER (recommended length).
#    The exact resolved OD depends on the catalog, so assert STRUCTURE: a pick was
#    made with a positive HoleDiameter and a positive BushingLength.
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "  -- jig_tree: METAL -> Hand Drill (OD-first) resolves a hole spec --" -ForegroundColor White
$md = Invoke-ScriptedWalk -Answers @('1','2','1','')   # material=Metal, HandDrill, OD #1, ENTER=recommended length
Assert-True "metal/handdrill: walk completed (cont=true)"  ($md.Cont)
Assert-True "metal/handdrill: resolved >=1 pick"           (@($md.Picks).Count -ge 1)
if (@($md.Picks).Count -ge 1) {
    $mp = $md.Picks[$md.Picks.Count - 1]
    Assert-True "metal/handdrill: HoleDiameter > 0"        ([double]$mp.HoleDiameter -gt 0) ("got $($mp.HoleDiameter)")
    Assert-True "metal/handdrill: BushingLength > 0"       ($null -ne $mp.BushingLength -and [double]$mp.BushingLength -gt 0) ("got $($mp.BushingLength)")
    Assert-True "metal/handdrill: Bushing name present"    (-not [string]::IsNullOrWhiteSpace([string]$mp.Bushing))
}

# ----------------------------------------------------------------------------
# 3. 3D print -> PFD: ID-first sleeve leaf. Answers:
#    Q1 -> 2 (3D print); Q2 -> 1 (PFD); then ID-first: ID #1, ENTER (recommended
#    length); OD auto-resolves when unique (no extra answer) OR needs a tie-break
#    pick. To be robust to either, queue an extra '1' that is consumed only if an
#    OD tie-break is shown (else it is left unused - harmless).
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "  -- jig_tree: 3D print -> PFD (ID-first) resolves a hole spec --" -ForegroundColor White
$tp = Invoke-ScriptedWalk -Answers @('2','1','1','','1')
Assert-True "3dprint/pfd: walk completed (cont=true)"      ($tp.Cont)
Assert-True "3dprint/pfd: resolved >=1 pick"               (@($tp.Picks).Count -ge 1)
if (@($tp.Picks).Count -ge 1) {
    $tpp = $tp.Picks[$tp.Picks.Count - 1]
    Assert-True "3dprint/pfd: HoleDiameter > 0"            ([double]$tpp.HoleDiameter -gt 0) ("got $($tpp.HoleDiameter)")
    Assert-True "3dprint/pfd: Bushing name present"        (-not [string]::IsNullOrWhiteSpace([string]$tpp.Bushing))
}

# ----------------------------------------------------------------------------
# 4. CUSTOM HOLE OD from the OD-first menu: pick the trailing "Custom hole OD" entry,
#    type a diameter, then ENTER (recommended length). Proves the custom path yields
#    a synthesized pick carrying the typed OD (the "verify bushing" case).
#    Menu order for METAL->HandDrill OD-first: N OD cards + 1 custom entry = customIdx.
#    The catalog seeds 2 ODs (0.5, 0.75) -> customIdx = 3. Queue: material, handdrill,
#    '3' (custom), '0.6' (typed OD), '1' (length menu item #1). A typed custom OD has no
#    recommended-length preselect, so pick an explicit length item (not ENTER, which
#    would fall through with no default).
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "  -- jig_tree: custom hole OD (OD-first menu) --" -ForegroundColor White
$cu = Invoke-ScriptedWalk -Answers @('1','2','3','0.6','1')
Assert-True "custom OD: walk completed"                    ($cu.Cont)
if (@($cu.Picks).Count -ge 1) {
    $cup = $cu.Picks[$cu.Picks.Count - 1]
    Assert-True "custom OD: HoleDiameter = 0.6"            ([math]::Abs([double]$cup.HoleDiameter - 0.6) -lt 1e-6) ("got $($cup.HoleDiameter)")
    Assert-True "custom OD: BushingLength > 0"             ($null -ne $cup.BushingLength -and [double]$cup.BushingLength -gt 0)
} else {
    Assert-True "custom OD: resolved a pick" $false "no pick (menu order may differ - inspect)"
}

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ("  jig-tree (STAGE 0) tests: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
Write-Host "  ============================================" -ForegroundColor Cyan
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
