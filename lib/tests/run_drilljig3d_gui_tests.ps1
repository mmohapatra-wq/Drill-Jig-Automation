# ============================================================================
# lib\tests\run_drilljig3d_gui_tests.ps1 - offline smoke of drilljig3d-gui.cmd
# ============================================================================
# drilljig3d-gui.cmd is the curved-jig wizard GUI (a WinForms .cmd that cannot run
# headless). This suite verifies the OFFLINE-checkable wiring so a regression is
# caught without Creo or a display:
#   1. Every new curved-GUI file parses clean (PSParser.Tokenize, 0 errors).
#   2. The shell's contract: -STA launcher, the $stages list, the curved dot-sources,
#      the four Add-Curved*Steps calls, and that it EDITS NOTHING (no drilljig-gui /
#      shared-lib writes -- enforced by only READING here).
#   3. RESOLVE + BUILD: dot-source the whole curved-GUI lib chain, call each
#      Add-Curved*Steps against a fresh $steps ArrayList, and assert the full ordered
#      step inventory (keys + stages) + that every declared $stages pill is covered.
#
# Run:  powershell -ExecutionPolicy Bypass -File lib\tests\run_drilljig3d_gui_tests.ps1
# Exit 0 = all pass.
# ============================================================================

$ErrorActionPreference = "Stop"
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir  = Split-Path -Parent $here
$root    = Split-Path -Parent $libDir

$script:pass = 0; $script:fail = 0
function Assert-True { param([string]$Name, [bool]$Cond, [string]$Detail = "")
    if ($Cond) { Write-Host "  [PASS] $Name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  [FAIL] $Name  $Detail" -ForegroundColor Red; $script:fail++ }
}

# Resolve a repo file that may live at the root OR under a tool subdir (a parallel
# repo reorg moves the .cmd tools into pipeline\ / tools\ / probes\; lib\ stays at
# root). Returns the first existing absolute path, else $null. Keeps this suite
# robust whether or not the reorg has landed.
function Resolve-RepoFile {
    param([string]$Leaf, [string[]]$SubDirs = @('', 'pipeline', 'tools', 'probes', 'previews'))
    foreach ($sd in $SubDirs) {
        $p = if ($sd -eq '') { Join-Path $root $Leaf } else { Join-Path $root (Join-Path $sd $Leaf) }
        if (Test-Path $p) { return $p }
    }
    return $null
}

# ----------------------------------------------------------------------------
# 1. PARSE every new curved-GUI file. (.cmd may be at root or under pipeline\;
#    the lib\*.ps1 stay at root.)
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "  -- parse: curved-GUI files --" -ForegroundColor White
$files = @(
    'lib\conformal_blank.ps1',
    'lib\curved_gui_helpers.ps1',
    'lib\curved_gui_steps_bushing.ps1',
    'lib\curved_gui_steps_surface.ps1',
    'lib\curved_gui_steps_drill.ps1',
    'lib\curved_gui_steps_relief.ps1'
)
foreach ($rel in $files) {
    $p = Join-Path $root $rel
    if (-not (Test-Path $p)) { Assert-True "exists: $rel" $false "missing"; continue }
    $raw = Get-Content -Raw $p
    $perr = $null
    [void][System.Management.Automation.PSParser]::Tokenize($raw, [ref]$perr)
    Assert-True "parses clean: $rel" ($perr.Count -eq 0) ("({0} errors)" -f $perr.Count)
}
# the shell .cmd -- found at root or under a moved-tools subdir.
$guiPath = Resolve-RepoFile 'drilljig3d-gui.cmd'
Assert-True "exists: drilljig3d-gui.cmd (root or pipeline\)" ($null -ne $guiPath) "missing"
$guiRaw = $null
if ($null -ne $guiPath) {
    $guiRaw = Get-Content -Raw $guiPath
    $perr = $null
    [void][System.Management.Automation.PSParser]::Tokenize($guiRaw, [ref]$perr)
    Assert-True "parses clean: drilljig3d-gui.cmd" ($perr.Count -eq 0) ("({0} errors)" -f $perr.Count)
}

# ----------------------------------------------------------------------------
# 2. Shell contract.
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "  -- shell contract: drilljig3d-gui.cmd --" -ForegroundColor White
if ($null -ne $guiRaw) {
    Assert-True "launcher uses -STA (WinForms)"           ($guiRaw -match '(?m)powershell .*-STA')
    Assert-True 'stages = Welcome/Bushing/Surface/Drill/Relief/Done' `
        ($guiRaw -match "\`$stages\s*=\s*@\(\s*'Welcome'\s*,\s*'Bushing'\s*,\s*'Surface'\s*,\s*'Drill'\s*,\s*'Relief'\s*,\s*'Done'\s*\)")
    Assert-True "dot-sources lib\wizard.ps1"              ($guiRaw -match 'lib\\wizard\.ps1')
    Assert-True "dot-sources lib\conformal_blank.ps1"     ($guiRaw -match 'lib\\conformal_blank\.ps1')
    Assert-True "dot-sources lib\tangent_plane.ps1"       ($guiRaw -match 'lib\\tangent_plane\.ps1')
    Assert-True "dot-sources lib\curved_slots.ps1"        ($guiRaw -match 'lib\\curved_slots\.ps1')
    Assert-True "dot-sources lib\curved_slot_macros.ps1"  ($guiRaw -match 'lib\\curved_slot_macros\.ps1')
    Assert-True "dot-sources lib\curved_gui_helpers.ps1"  ($guiRaw -match 'lib\\curved_gui_helpers\.ps1')
    Assert-True "calls Add-CurvedBushingSteps"            ($guiRaw -match 'Add-CurvedBushingSteps')
    Assert-True "calls Add-CurvedSurfaceSteps"            ($guiRaw -match 'Add-CurvedSurfaceSteps')
    Assert-True "calls Add-CurvedDrillSteps"              ($guiRaw -match 'Add-CurvedDrillSteps')
    Assert-True "calls Add-CurvedReliefSteps"             ($guiRaw -match 'Add-CurvedReliefSteps')
    Assert-True "re-inits DrilljigCore with the live session" ($guiRaw -match 'Initialize-DrilljigCore\s+-Session\s+\$session')
    Assert-True ".asm mode guard present"                 ($guiRaw -match '\\.asm')
    # It must not INVOKE/dot-source drilljig-gui.cmd (a comment MENTION of it as "the
    # curved analog of drilljig-gui.cmd" is fine; an actual call/dot-source is not).
    Assert-True "does NOT invoke/dot-source drilljig-gui.cmd" `
        (-not ($guiRaw -match "(?im)^\s*(\.|&)\s+.*drilljig-gui\.cmd|Invoke-Expression.*drilljig-gui\.cmd"))
}

# ----------------------------------------------------------------------------
# 3. RESOLVE + BUILD the step inventory (no Show-Wizard, no Creo).
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "  -- resolve + build: Add-Curved*Steps append the expected steps --" -ForegroundColor White
foreach ($dep in @('creo_geometry.ps1','orthogrid.ps1','orthogrid_points.ps1','drilljig_core.ps1',
                   'conformal_blank.ps1','tangent_plane.ps1','curved_slots.ps1','curved_slot_macros.ps1',
                   'wizard.ps1','curved_gui_helpers.ps1',
                   'curved_gui_steps_bushing.ps1','curved_gui_steps_surface.ps1',
                   'curved_gui_steps_drill.ps1','curved_gui_steps_relief.ps1')) {
    $p = Join-Path $libDir $dep
    if (Test-Path $p) { try { . $p } catch { Write-Host "    (load note: $dep -> $($_.Exception.Message))" -ForegroundColor DarkGray } }
}
foreach ($fn in @('Add-CurvedBushingSteps','Add-CurvedSurfaceSteps','Add-CurvedDrillSteps','Add-CurvedReliefSteps')) {
    Assert-True "resolves: $fn" ($null -ne (Get-Command $fn -ErrorAction SilentlyContinue))
}

$steps = New-Object System.Collections.ArrayList
$built = $true
foreach ($adder in @('Add-CurvedBushingSteps','Add-CurvedSurfaceSteps','Add-CurvedDrillSteps','Add-CurvedReliefSteps')) {
    if ($null -ne (Get-Command $adder -ErrorAction SilentlyContinue)) {
        try { & $adder -Steps $steps } catch { $built = $false; Write-Host "    ($adder threw: $($_.Exception.Message))" -ForegroundColor DarkGray }
    }
}
Assert-True "all four adders ran without throwing" $built
Assert-True "produced >= 12 steps" (@($steps).Count -ge 12) ("got {0}" -f @($steps).Count)

# collect the (Key, Stage) inventory
$keys   = @($steps | ForEach-Object { [string]$_.Key })
$stagesSeen = @($steps | ForEach-Object { [string]$_.Stage } | Select-Object -Unique)
Write-Host ("    steps: " + ($keys -join ', ')) -ForegroundColor DarkGray

foreach ($k in @('welcome','tree','thickness','standoff','surface-arm','surface-run',
                 'drill-mode','drill-arm-points','drill-diameter','drill-run',
                 'relief-intro','relief-plan','relief-run','done')) {
    Assert-True "has step '$k'" ($keys -contains $k)
}
foreach ($stg in @('Welcome','Bushing','Surface','Drill','Relief','Done')) {
    Assert-True "stage '$stg' is covered by >=1 step" ($stagesSeen -contains $stg)
}
# welcome first, done last
Assert-True "first step is 'welcome'" (@($keys)[0] -eq 'welcome')
Assert-True "last step is 'done'"     (@($keys)[-1] -eq 'done')

# every step object has the framework shape
$shapeOk = $true
foreach ($s in $steps) {
    if ($null -eq $s.Key -or $null -eq $s.Stage -or $null -eq $s.Kind) { $shapeOk = $false; break }
    if (@('info','choice','pick','run') -notcontains [string]$s.Kind) { $shapeOk = $false; break }
}
Assert-True "every step has Key/Stage/valid-Kind" $shapeOk

# ----------------------------------------------------------------------------
# 4. LINT: no assignment to a read-only automatic variable. $pid/$true/$false/
#    $PSHome/$ShellId/$ExecutionContext are read-only or constant -- assigning to
#    one throws "Cannot overwrite variable X because it is read-only or constant"
#    at RUNTIME. Parse-checks + the render/build smoke above do NOT catch it (the
#    statement is syntactically valid; it only throws when the handler executes),
#    which is exactly how a `$pid = 0` in the drill-run OnNext slipped to a live
#    handler error. $null is EXCLUDED ($null = ... is the valid discard sink).
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "  -- lint: no read-only automatic-variable assignments --" -ForegroundColor White
# TOKENIZE (not regex) so a mention of "$false" inside a COMMENT or STRING is never
# flagged -- only a real Variable token immediately followed by an assignment operator
# ( = += -= *= /= %= ) counts. Read-only/constant automatics ($pid/$true/$false/$PSHome/
# $ShellId/$ExecutionContext) throw on assignment; $null is EXCLUDED (valid discard sink).
$badNames = @('pid', 'true', 'false', 'pshome', 'shellid', 'executioncontext')
$asgnOps  = @('=', '+=', '-=', '*=', '/=', '%=')
function Find-ReadOnlyAssignments {
    param([string]$Raw)
    $perr = $null
    $toks = $null
    try { $toks = [System.Management.Automation.PSParser]::Tokenize($Raw, [ref]$perr) } catch { return @() }
    if ($null -eq $toks) { return @() }
    $out = @()
    for ($i = 0; $i -lt $toks.Count; $i++) {
        $t = $toks[$i]
        if ($t.Type -ne 'Variable') { continue }
        if ($badNames -notcontains ([string]$t.Content).ToLower()) { continue }
        # next non-newline token must be an assignment operator (member/index access,
        # comparison -eq, or use-as-value all have a different next token)
        $j = $i + 1
        while ($j -lt $toks.Count -and $toks[$j].Type -eq 'NewLine') { $j++ }
        if ($j -lt $toks.Count -and $toks[$j].Type -eq 'Operator' -and ($asgnOps -contains [string]$toks[$j].Content)) {
            $out += ('$' + $t.Content + ' (line ' + $t.StartLine + ')')
        }
    }
    return @($out)
}
$lintTargets = @($files)
foreach ($rel in $lintTargets) {
    $p = Join-Path $root $rel
    if (-not (Test-Path $p)) { continue }
    $bad = Find-ReadOnlyAssignments (Get-Content -Raw $p)
    Assert-True "no read-only automatic assignment in $rel" (@($bad).Count -eq 0) ("(" + (@($bad) -join ', ') + ")")
}
# and the shell .cmd
if ($null -ne $guiRaw) {
    $bad = Find-ReadOnlyAssignments $guiRaw
    Assert-True "no read-only automatic assignment in drilljig3d-gui.cmd" (@($bad).Count -eq 0) ("(" + (@($bad) -join ', ') + ")")
}

# ----------------------------------------------------------------------------
# 5. LINT: every $c.*Valid gate field a step READS is SEEDED in the shell $ctx
#    initializer. An unseeded *Valid flag reads $null -> [bool]$null -> $false, so a
#    -Validate/-OnNext that gates Next on it could disable Next before that step's Build
#    runs (the ctx-contract class the runtime audit surfaced for StandOffValid/
#    ThicknessValid). Tokenizer-based: a READ is $c/$ctx/$Context . <Member ending 'Valid'>
#    whose next token is NOT an assignment op; a SEED is any 'Valid'-suffixed key '= ...'
#    in the shell hash. (Property access + hashtable keys both tokenize as Member; verified.)
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "  -- lint: every `$c.*Valid gate field is seeded in the `$ctx initializer --" -ForegroundColor White
function Get-TokensSafe { param([string]$Raw) $e = $null; try { return @([System.Management.Automation.PSParser]::Tokenize($Raw, [ref]$e)) } catch { return @() } }
$asgn = @('=', '+=', '-=', '*=', '/=', '%=')
# READS: $c./$ctx./$Context. <Member ...Valid> not immediately assigned, across the step libs
$validReads = @{}
foreach ($rel in $files) {
    $p = Join-Path $root $rel
    if (-not (Test-Path $p)) { continue }
    $tk = Get-TokensSafe (Get-Content -Raw $p)
    for ($i = 0; $i -lt $tk.Count - 2; $i++) {
        if ($tk[$i].Type -eq 'Variable' -and (@('c', 'ctx', 'context') -contains ([string]$tk[$i].Content).ToLower()) `
                -and $tk[$i + 1].Type -eq 'Operator' -and [string]$tk[$i + 1].Content -eq '.' `
                -and $tk[$i + 2].Type -eq 'Member' -and ([string]$tk[$i + 2].Content) -match 'Valid$') {
            $isWrite = ($i + 3 -lt $tk.Count -and $tk[$i + 3].Type -eq 'Operator' -and ($asgn -contains [string]$tk[$i + 3].Content))
            if (-not $isWrite) { $validReads[[string]$tk[$i + 2].Content] = $rel }
        }
    }
}
# SEEDS: any 'Valid'-suffixed key initialized in the shell .cmd
$seeded = @{}
if ($null -ne $guiRaw) {
    $tk = Get-TokensSafe $guiRaw
    for ($i = 0; $i -lt $tk.Count - 1; $i++) {
        $cont = [string]$tk[$i].Content
        if ($cont -cmatch 'Valid$') {
            $j = $i + 1
            while ($j -lt $tk.Count -and $tk[$j].Type -eq 'NewLine') { $j++ }
            if ($j -lt $tk.Count -and $tk[$j].Type -eq 'Operator' -and [string]$tk[$j].Content -eq '=') { $seeded[$cont] = $true }
        }
    }
}
if ($validReads.Count -eq 0) {
    Assert-True "at least one `$c.*Valid gate field was found to check" $false "(tokenizer found none -- lint may be mis-wired)"
} else {
    foreach ($f in ($validReads.Keys | Sort-Object)) {
        Assert-True "ctx gate field `$c.$f (read in $($validReads[$f])) is seeded in the `$ctx initializer" ($seeded.ContainsKey($f)) "(not seeded -> reads $null->false before its Build runs)"
    }
}

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ("  drilljig3d-gui smoke tests: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
Write-Host "  ============================================" -ForegroundColor Cyan
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
