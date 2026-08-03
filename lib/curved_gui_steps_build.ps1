# ============================================================================
# lib\curved_gui_steps_build.ps1 - the BUILD step group for the INPUT-FIRST curved
# drill jig wizard GUI (drilljig3d-gui.cmd), Stage 'Build'.
# ============================================================================
# Defines Add-CurvedBuildSteps -Steps <ArrayList>, appending ONE `run` step
# ('build-run') that fires the WHOLE hands-free build in one click after all input
# is front-loaded (Fasteners -> Surface -> Conditions). It drives an ordered,
# canary-gated, NO-ABORT batch (mirrors the per-fastener loop posture + the
# never-assume-success rule):
#   1. BLANK   (dependency root) - Invoke-CurvedBlankAction -> $blankOk.
#   2. CORNERS (advisory; skip if --no-corner-round or not blankOk).
#   3. DRILL   (only if blankOk) - Invoke-CurvedDrillAll: per fastener, point ->
#      on-point hole oriented to its TOP plane. NO relief here (relief is STAGE 5).
# Relief pockets are NOT cut here -- they are the terminal STAGE 5 (slot-select +
# slot-loop), which re-selects the fasteners for fresh TOP-plane references.
#
# The three sub-actions are extracted as `function global:` helpers so (a) the
# build-run OnNext is a thin orchestrator, (b) each is independently canary-gated,
# and (c) they resolve from the OnNext scope. build-run's OnNext ITSELF calls only
# GLOBAL helpers + engines (never a non-global drilljig_core primitive), and the
# per-fastener prompt closures capture $wiz/$ci by value ([[project_gui_scope_bugs]]).
#
# HARD RULES: EDITS NOTHING existing; `function global:`; rebind $session/$model/
# $pfcType from $c at the top; NEVER tally on a canary miss
# ([[feedback_canary_must_not_assume_on_failure]]); ID-only; ASCII-only; no $pid.
# ============================================================================

# ----------------------------------------------------------------------------
# Invoke-CurvedBlankAction - the STAGE-4 blank sub-action (blank-build OnNext logic,
# relocated). Thickens to wall + relief. Returns $true when the blank body is on
# record (fresh build OR already built), else $false so the caller SKIPS dependents.
# Logs via $Wizard.Log (no AskInline -- the batch reports, never blocks). NEVER throws.
# ----------------------------------------------------------------------------
function global:Invoke-CurvedBlankAction {
    param($Context, $Wizard, [scriptblock]$OnPoll = $null)
    $c = $Context; $wiz = $Wizard
    if ($c.BlankMade) { return $true }   # idempotent
    $session = $c.Session; $model = $c.Model; $pfcType = $c.Type
    if ($null -eq $session -or $null -eq $model) { $wiz.SetChip('surface', 'blank: aborted (no session)', 'aborted'); return $false }
    $t = 0.0; try { if ($null -ne $c.Thickness) { $t = [double]$c.Thickness } } catch { $t = 0.0 }
    if ($t -le 0) { $wiz.Log('  blank: wall thickness not set - skipping the build.'); $wiz.SetChip('surface', 'blank: no thickness', 'warning'); return $false }
    # THICKEN BUMP: wall + relief (relief <= 0 => wall only); backstop re-confirms wall+relief.
    $rlf = 0.0; try { if ($null -ne $c.ReliefDepth -and [double]$c.ReliefDepth -gt 0) { $rlf = [double]$c.ReliefDepth } } catch { $rlf = 0.0 }
    $tEff = $t + $rlf
    $so = 0.0; try { if ($null -ne $c.StandOff) { $so = [double]$c.StandOff } } catch { $so = 0.0 }
    $flip = $false; try { $flip = [bool]$c.FlipThicken } catch { $flip = $false }
    $surfIds = @()
    try { if ($null -ne $c.SurfIds) { $surfIds = @($c.SurfIds | ForEach-Object { [int]$_ }) } } catch { $surfIds = @() }
    if (@($surfIds).Count -lt 1) { $wiz.Log('  blank: no surface captured - skipping the build.'); $wiz.SetChip('surface', 'blank: no surface', 'warning'); return $false }

    $r = $null
    try {
        $r = Invoke-ConformalBlank -Session $session -Model $model -TypeObj $pfcType `
                -SurfIds $surfIds -Thickness $tEff -StandOff $so -Flip:$flip -OnPoll $OnPoll
    } catch {
        $wiz.Log("  blank: Invoke-ConformalBlank error: $($_.Exception.Message)")
        $wiz.SetChip('surface', 'blank: build FAILED', 'aborted')
        return $false
    }
    $made = $false; try { $made = [bool]$r.Made } catch { $made = $false }
    if (-not $made) {
        $reason = ''; try { $reason = [string]$r.Reason } catch { $reason = '' }
        $wiz.Log("  blank did not build (model unchanged): $reason")
        $wiz.SetChip('surface', 'blank: build FAILED', 'aborted')
        return $false
    }
    $c.BodyIndex = $null; $c.BodyId = $null; $c.BodyName = $null
    try { $c.BodyIndex = $r.BodyIndex } catch {}
    try { $c.BodyId    = $r.BodyId }    catch {}
    try { $c.BodyName  = $r.BodyName }  catch {}
    $offHeld = $false; try { $offHeld = [bool]$r.OffsetHeld } catch { $offHeld = $false }
    $thkHeld = $false; try { $thkHeld = [bool]$r.ThicknessHeld } catch { $thkHeld = $false }
    $c.BlankMade = $true
    # record the ACTUAL slab thickness (wall + relief) so the corner action targets the
    # blank's real through-thickness edges (targeting wall-only matches ZERO edges when
    # relief bumped the slab -- the "rounds nothing" bug).
    $c.BlankThickness = $tEff
    $thkNote = if ($rlf -gt 0) { ("$tEff (wall $t + relief $rlf)") } else { "$tEff" }
    $wiz.Log(("  Conformal blank created. offset {0}; thickness {1}." -f $(if ($offHeld) { "held at $so" } else { 'NOT confirmed' }), $(if ($thkHeld) { "held at $thkNote" } else { 'NOT confirmed (set by hand in Creo)' })))
    if ($null -ne $c.BodyIndex) { $wiz.Log(("  New blank body: '{0}' (index {1}, id {2})." -f $c.BodyName, $c.BodyIndex, $c.BodyId)) }
    else { $wiz.Log('  (could not auto-identify the new body; holes/relief target body index 0.)') }
    $wiz.MarkCommitted()
    $chipState = if ($thkHeld) { 'built' } else { 'unverified' }
    $wiz.SetChip('surface', 'blank: built', $chipState)
    return $true
}

# ----------------------------------------------------------------------------
# Invoke-CurvedCornerAction - the STAGE-4 corner-round sub-action (advisory). Rounds
# the blank's through-thickness edges (Invoke-CurvedCornerRound, global wrapper).
# ADVISORY: a miss logs the diagnostic + sets the chip but NEVER blocks the batch
# (unlike the standalone step which AskInline-explains). NEVER throws.
# ----------------------------------------------------------------------------
function global:Invoke-CurvedCornerAction {
    param($Context, $Wizard, [scriptblock]$OnPoll = $null)
    $c = $Context; $wiz = $Wizard
    if ($c.NoCornerRound) { $wiz.SetChip('corners', 'corners: skipped (--no-corner-round)', 'set'); return }
    if ($c.CornersRounded) { return }
    if (-not $c.BlankMade) { $wiz.SetChip('corners', 'corners: no blank', 'warning'); return }
    $session = $c.Session; $model = $c.Model; $pfcType = $c.Type
    if ($null -eq $session -or $null -eq $model) { $wiz.SetChip('corners', 'corners: aborted (no session)', 'aborted'); return }
    $rad = 0.25; try { if ($null -ne $c.CornerRadius -and [double]$c.CornerRadius -gt 0) { $rad = [double]$c.CornerRadius } } catch { $rad = 0.25 }
    # TARGET = the actual slab thickness (wall + relief), recorded by the blank action as
    # BlankThickness; fall back to wall + relief, then wall. Targeting wall-only matches
    # ZERO edges when relief bumped the slab.
    $thk = 0.0
    try {
        if ($null -ne $c.BlankThickness -and [double]$c.BlankThickness -gt 0) { $thk = [double]$c.BlankThickness }
        elseif ($null -ne $c.Thickness) {
            $thk = [double]$c.Thickness
            if ($null -ne $c.ReliefDepth -and [double]$c.ReliefDepth -gt 0) { $thk += [double]$c.ReliefDepth }
        }
    } catch { $thk = 0.0 }
    $cr = $null
    try { $cr = Invoke-CurvedCornerRound -Session $session -Model $model -TypeObj $pfcType -Radius $rad -Thickness $thk -OnPoll $OnPoll }
    catch { $wiz.Log("  corner round error: $($_.Exception.Message)"); $wiz.SetChip('corners', 'corners: error', 'aborted'); return }
    if ($null -eq $cr) { $wiz.SetChip('corners', 'corners: no-op', 'unverified'); return }
    $found = 0;   try { $found = [int]$cr.Found } catch {}
    $matched = 0; try { $matched = [int]$cr.Matched } catch {}
    $changed = 0; try { $changed = [int]$cr.ModelChanged } catch {}
    $batches = 0; try { $batches = [int]$cr.TotalBatches } catch {}
    $modeStr = 'auto'; try { if ($cr.Mode) { $modeStr = [string]$cr.Mode } } catch {}
    $reason = ''; try { $reason = [string]$cr.Reason } catch {}
    $lens = ''; try { $lens = [string]$cr.LengthSummary } catch {}
    $wiz.Log(("  corners: found {0}, matched {1} at target {2} (mode {3}); batches changed {4}/{5}. edge lengths: [{6}]. {7}" -f `
        $found, $matched, $cr.Target, $modeStr, $changed, $batches, $(if ($lens) { $lens } else { 'none' }), $reason))
    if ($matched -gt 0 -and $batches -gt 0 -and $changed -eq $batches) {
        $c.CornersRounded = $true; $wiz.MarkCommitted(); $wiz.SetChip('corners', ("corners: rounded ({0})" -f $modeStr), 'built')
    } elseif ($found -eq 0) {
        $wiz.SetChip('corners', 'corners: no edges found', 'warning')
    } elseif ($matched -eq 0) {
        $wiz.SetChip('corners', 'corners: none matched', 'warning')
    } else {
        $wiz.SetChip('corners', 'corners: check Creo', 'unverified')
    }
}

# ----------------------------------------------------------------------------
# Invoke-CurvedDrillAll - the STAGE-4 fastener DRILL loop (relief-stripped). Per
# $Context.FastenerComponents: by-ID planes -> datum point -> on-point hole oriented
# to that fastener's TOP plane (id 1), with the manual 3-plane fallback + per-iteration
# safety-close. Stores CurvedHolePairs {PointId;TopPlaneId=1;ViaPlane;ReliefCut=$false}.
# Feedback via $Wizard.Log (run-view). NO relief cut here (STAGE 5). NEVER throws.
# Reuses the stored $comp.Path (overwritten fresh via Get-BufferComponentPath at use).
# ----------------------------------------------------------------------------
function global:Invoke-CurvedDrillAll {
    param($Context, $Wizard, [scriptblock]$OnPoll = $null)
    $c = $Context; $wiz = $Wizard
    $session = $c.Session; $model = $c.Model; $pfcType = $c.Type
    $comps = @()
    try { if ($null -ne $c.FastenerComponents) { $comps = @($c.FastenerComponents) } } catch { $comps = @() }
    if (@($comps).Count -lt 1) { $wiz.Log('  drill: no fasteners captured - skipping.'); $wiz.SetChip('fastholes', 'fastener holes: none', 'warning'); return }
    # SELECTED hole diameter (the fastener-dia step). Passed to the hole macro so every hole
    # is drilled at the chosen size, not Creo's last dashboard value (the wrong-diameter bug).
    $holeDia = 0.0
    try { if ($null -ne $c.FastenerHoleDia -and [double]$c.FastenerHoleDia -gt 0) { $holeDia = [double]$c.FastenerHoleDia } } catch { $holeDia = 0.0 }
    if ($holeDia -le 0) { try { if ($null -ne $c.HoleDiaFinal -and [double]$c.HoleDiaFinal -gt 0) { $holeDia = [double]$c.HoleDiaFinal } } catch { $holeDia = 0.0 } }
    $drilled = 0; $autoN = 0; $manualN = 0; $failN = 0
    $ci = 0
    foreach ($comp in $comps) {
        $ci++
        $ptId = 0; $pointMade = $false
        $useCompPath = $comp.Path
        # (a) by-ID auto: planes 1/3/5 -> point (canary = new point id OR VersionStamp move).
        $autoAdded = 0
        try {
            $byId = Add-ComponentDefaultPlanesToBuffer -Session $session -Model $model -TypeObj $pfcType -ComponentPath $comp.Path
            if ($null -ne $byId) { $autoAdded = [int]$byId.Added }
        } catch { $autoAdded = 0 }
        if ($autoAdded -ge 3) {
            $fp = $null; try { $fp = Get-BufferComponentPath -Session $session } catch { $fp = $null }
            if ($null -ne $fp) { $useCompPath = $fp }
            $pr = $null
            try { $pr = Invoke-FastenerPoint -Session $session -Model $model -TypeObj $pfcType -OnPoll $OnPoll } catch { $pr = $null }
            if ($null -ne $pr -and $pr.Created) { $ptId = [int]$pr.PointId; $pointMade = $true; $autoN++ }
        }
        # (b) operator tree-pick fallback if auto did not land a point.
        if (-not $pointMade) {
            try { ($session.CurrentSelectionBuffer()).Clear() } catch {}
            [void]$wiz.AskInline('Select this fastener''s planes',
                ("Fastener {0} of {1}: in Creo, select THIS fastener's THREE datum planes (TOP + SIDE + FRONT) in the model tree (Ctrl-click all three), then click OK." -f $ci, @($comps).Count),
                'OK', $true)
            $pl = $null
            try { $pl = Resolve-SelectedPlaneIds -Session $session -TypeObj $pfcType } catch { $pl = $null }
            $pn = 0; try { if ($null -ne $pl) { $pn = @($pl.Ids).Count } } catch { $pn = 0 }
            if ($pn -lt 3) {
                $failN++
                $wiz.Log(("  fastener {0}: fewer than 3 planes selected (got {1}) - skipped." -f $ci, $pn))
                try { $wiz.Pump() } catch {}
                continue
            }
            $fp = $null; try { $fp = Get-BufferComponentPath -Session $session } catch { $fp = $null }
            if ($null -ne $fp) { $useCompPath = $fp }
            $pr = $null
            try { $pr = Invoke-FastenerPoint -Session $session -Model $model -TypeObj $pfcType -OnPoll $OnPoll } catch { $pr = $null }
            if ($null -eq $pr -or -not $pr.Created) {
                $failN++
                $wiz.Log(("  fastener {0}: no datum point created from the selected planes - skipped." -f $ci))
                try { $wiz.Pump() } catch {}
                continue
            }
            $ptId = [int]$pr.PointId; $pointMade = $true; $manualN++
        }

        # ---- HOLE: on-point placement + TOP-plane orientation (NO relief here) ----
        $dirPrompt = {
            [void]$wiz.AskInline('Add the TOP plane',
                ("Fastener {0}: the automatic TOP-plane pick did not take. In Creo, Ctrl-click THIS fastener's TOP datum plane to ADD it to the already-selected datum point (both must stay highlighted), then click OK." -f $ci),
                'OK', $true)
        }.GetNewClosure()
        $hr = $null
        try { $hr = Invoke-FastenerHole -Session $session -Model $model -TypeObj $pfcType -PointId $ptId -ComponentPath $useCompPath -TopPlaneId 1 -Diameter $holeDia -DirectionPrompt $dirPrompt -OnPoll $OnPoll } catch { $hr = $null }
        if ($null -ne $hr -and $hr.Drilled) {
            $drilled++
            if ($null -eq $c.FastenerHolesMade) { $c.FastenerHolesMade = 0 }
            $c.FastenerHolesMade = [int]$c.FastenerHolesMade + 1
            try {
                if ($null -eq $c.CurvedHolePairs) { $c.CurvedHolePairs = @() }
                # Store the fastener's ComponentPath alongside the datum PointId so the terminal
                # Slots stage pre-selects THIS fastener's TOP plane (id 1) before the relief extrude
                # + offsets the hole-bounding guide planes -- WITHOUT re-selecting the fasteners
                # (user 2026-07-29). Store the FRESH resolved path ($useCompPath, read back from the
                # live buffer via Get-BufferComponentPath) -- NOT the drill-time $comp.Path handle,
                # which can go stale; the Slots arm re-resolves once more before use as a backstop.
                # Origin = this fastener's position (component-path transform origin, captured
                # at fastener-select) so the terminal Slots stage can compute a RADIAL/axis
                # chip-relief pattern from the fastener ring WITHOUT a new live read
                # ([[project_curved_radial_slot_pattern]]). Stored per hole so it aligns 1:1
                # with the slot items even when a fastener's hole was skipped.
                $fOrigin = $null; try { $fOrigin = $comp.Origin } catch { $fOrigin = $null }
                $c.CurvedHolePairs = @($c.CurvedHolePairs) + @([pscustomobject]@{ PointId = $ptId; TopPlaneId = 1; ViaPlane = [bool]$hr.ViaPlane; ReliefCut = $false; CompPath = $useCompPath; Origin = $fOrigin })
            } catch {}
            $orientNote = if ($hr.ViaPlane) { 'oriented to its TOP plane' } else { 'oriented by your direction pick' }
            $wiz.Log(("  + fastener {0}/{1} drilled on-point, {2} (total {3})." -f $ci, @($comps).Count, $orientNote, [int]$c.FastenerHolesMade))
            $wiz.SetChip('fastholes', ("fastener holes: {0}" -f [int]$c.FastenerHolesMade), 'built')
        } else {
            $failN++
            $wiz.Log(("  fastener {0}: the hole did not create (model unchanged) - skipped." -f $ci))
        }

        # PER-ITERATION SAFETY-CLOSE: guarantee a fresh dashboard for the next fastener.
        try { $session.RunMacro("~ Enter ``main_dlg_cur`` ``dashInst0.Quit``;~ Exit ``main_dlg_cur`` ``dashInst0.Quit``;~ Activate ``main_dlg_cur`` ``dashInst0.Done``;") } catch {}
        try { $wiz.Pump() } catch {}
    }
    $summ = ("Holes: {0} drilled ({1} by ID, {2} manual)" -f $drilled, $autoN, $manualN)
    if ($failN -gt 0) { $summ += ("; {0} skipped/failed - re-run to retry them" -f $failN) }
    $wiz.Log("  $summ")
    if ($drilled -ge 1) { $wiz.SetChip('fastholes', ("fastener holes: {0}" -f [int]$c.FastenerHolesMade), $(if ($failN -eq 0) { 'built' } else { 'unverified' })) }
    elseif ($failN -gt 0) { $wiz.SetChip('fastholes', 'fastener holes: 0 (all failed)', 'aborted') }
}

function global:Add-CurvedBuildSteps {
    param($Steps)

    $buildStep = New-WizardStep -Key 'build-run' -Title 'Build the jig (hands-free)' -Stage 'Build' -Kind 'run' -PrimaryText 'Build everything' `
        -Validate {
            param($c)
            $n = 0; try { if ($null -ne $c.SurfIds) { $n = @($c.SurfIds).Count } } catch { $n = 0 }
            $t = 0.0; try { if ($null -ne $c.Thickness) { $t = [double]$c.Thickness } } catch { $t = 0.0 }
            $nf = 0; try { if ($null -ne $c.FastenerComponents) { $nf = @($c.FastenerComponents).Count } } catch { $nf = 0 }
            return [bool](($n -ge 1) -and ($t -gt 0) -and [bool]$c.FastenerHoleDiaValid -and ($nf -ge 1))
        } `
        -Build {
            param($panel, $c, $wiz)
            if ($c.BlankMade -and $c.FastenerHolesMade -ge 1) {
                Add-RebuiltNotice -Panel $panel -Context $c -Wizard $wiz -Message 'The jig is already built (blank + holes).' `
                    -ResetFlags @('BlankMade','CornersRounded') -GoToKey 'surface-arm'
                return
            }
            $t = 0.0; try { if ($null -ne $c.Thickness) { $t = [double]$c.Thickness } } catch { $t = 0.0 }
            $rlf = 0.0; try { if ($null -ne $c.ReliefDepth -and [double]$c.ReliefDepth -gt 0) { $rlf = [double]$c.ReliefDepth } } catch { $rlf = 0.0 }
            $nf = 0; try { if ($null -ne $c.FastenerComponents) { $nf = @($c.FastenerComponents).Count } } catch { $nf = 0 }
            $cornerNote = if ($c.NoCornerRound) { 'skips corner rounding' } else { ("rounds the corners at {0}" -f $(if ($null -ne $c.CornerRadius) { $c.CornerRadius } else { 0.25 })) }
            $y = (Add-Para $panel (("Press 'Build everything'. In ONE hands-free pass Creo: (1) offsets + thickens the surface to {0}`" (wall {1}`"{2}) into a new body, (2) {3}, (3) drills all {4} fastener hole(s) normal to the surface. No Creo picks - it only PAUSES to ask you to tree-pick a fastener's 3 planes if the automatic resolve misses." -f ($t + $rlf), $t, $(if ($rlf -gt 0) { " + relief $rlf`"" } else { '' }), $cornerNote, $nf)) 8 0 $null).Bottom + 6
            Add-Para $panel ("Chip-relief pockets are cut in the NEXT stage (they need you to draw a rectangle each). The drilljig PART must be ACTIVE in Creo. Do not touch Creo while it runs.") $y 0 'gray'
        } `
        -OnNext {
            param($c, $wiz)
            if ($c.BlankMade -and $c.FastenerHolesMade -ge 1) { return $true }   # idempotent revisit
            # REBIND COM (a bare $session read is stale).
            $session = $c.Session; $model = $c.Model; $pfcType = $c.Type
            if ($null -eq $session -or $null -eq $model) { $wiz.SetChip('surface', 'build: aborted (no session)', 'aborted'); return $true }

            # ACTIVE-MODEL GATE (once, at the top): the point + cut need the jig PART active.
            # An .asm-active run cannot land the datum point -> STAY on the step (return $false),
            # nothing mutated, so the operator can activate the part and retry.
            $activeName = ''
            try { $am = $session.GetActiveModel(); if ($null -ne $am) { $activeName = [string]$am.FileName } } catch { $activeName = '' }
            if ($activeName -match '(?i)\.asm(\.\d+)?$') {
                [void]$wiz.AskInline('Activate the drilljig part',
                    ("Creo's ACTIVE model is the assembly ('" + $activeName + "'), not the drilljig part - the datum points cannot be created. Right-click the DRILLJIG PART in the Creo tree -> Activate, then click OK and press 'Build everything' again."),
                    'OK', $true)
                $wiz.SetChip('surface', 'build: activate the jig part', 'warning')
                return $false
            }

            $wiz.BeginRun('Building the jig (blank -> corners -> holes)...')
            $poll = { try { [System.Windows.Forms.Application]::DoEvents() } catch {} }

            # 1. BLANK (root). 2. CORNERS (advisory, if blankOk). 3. DRILL (if blankOk).
            $blankOk = $false
            try { $blankOk = [bool](Invoke-CurvedBlankAction -Context $c -Wizard $wiz -OnPoll $poll) } catch { $wiz.Log("  blank action error: $($_.Exception.Message)") }
            if ($blankOk) {
                try { Invoke-CurvedCornerAction -Context $c -Wizard $wiz -OnPoll $poll } catch { $wiz.Log("  corner action error: $($_.Exception.Message)") }
                try { Invoke-CurvedDrillAll     -Context $c -Wizard $wiz -OnPoll $poll } catch { $wiz.Log("  drill action error: $($_.Exception.Message)") }
            } else {
                $wiz.Log('  blank not built - skipping corners + holes (they need the blank body).')
            }
            try { $wiz.Rerender() } catch {}
            return $true   # advance to Slots regardless of partial failure; the recap is honest.
        }
    [void]$Steps.Add($buildStep)
}
