# ============================================================================
# lib\curved_gui_steps_slots.ps1 - the SLOTS (chip-relief) step group for the
# INPUT-FIRST curved drill jig wizard GUI (drilljig3d-gui.cmd), Stage 'Slots'.
# ============================================================================
# TWO steps, mirroring the FLAT drill-jig's slot-a/slot-b PER-ROW flow (user
# 2026-07-29: "make opening/closing the sketch for chip relief work EXACTLY like the
# FLAT DJ -- the sketch opens, the user draws, confirms in the software, and the
# software does the rest"):
#
#   1. slot-arm (run) - opens the FIRST fastener's relief sketch immediately (NO reference/guide
#      planes): PRE-SELECTS that fastener's OWN TOP datum plane hands-free -- the same raw-COM
#      reference the hole uses -- THEN opens the extrude so it takes the TOP plane as its sketch
#      plane; an operator plane-pick fallback fires only if the pre-select cannot stage), then
#      ADVANCES with NO modal, leaving Creo's sketcher OPEN to draw.
#   2. slot-finish (run) - the operator has drawn the rectangle; on 'Finish this pocket'
#      it fires the SYMMETRIC remove-material cut (canary-gated), then RE-ARMS the next
#      fastener's sketch and RETURNS $false to STAY (the operator draws the next), looping
#      until every fastener is cut -> $c.SlotsDone -> advance. On a no-cut it re-arms the
#      SAME fastener and asks for a redraw (never tallies on a miss). This is the flat
#      slot-b PER-ROW self-loop, adapted per-fastener; there is NO direction verify (the
#      curved cut is SYMMETRIC -> no flip ambiguity).
#
# THE SKETCH SITS ON THE FASTENER'S OWN TOP PLANE (user 2026-07-29 "extrude first, within that
# extrude select the top plane"): the arm PRE-SELECTS that fastener's TOP datum plane (the plane
# its hole was drilled normal to) HANDS-FREE via the SAME raw-COM path-qualified reference the hole
# uses (Select-ComponentPlaneById + the stored CompPath), THEN opens ProCmdFtExtrude so it takes the
# TOP plane as its sketch plane -- the pre-select-then-fire pattern the hole proves (v5's post-open
# feed into the plane-wait did NOT register). If the pre-select cannot stage (stale path) an operator
# plane-pick fallback fires. Either way the sketch lands on the fastener's OWN TOP plane
# ([[project_curved_relief_extrude_plane]]). NO reference/guide planes are created -- the sketch
# opens on the TOP plane immediately (user 2026-07-29 "no need to create those reference planes").
#
# It does NOT re-ask for the fasteners (it reuses $ctx.CurvedHolePairs -- each carries the
# jig-part datum PointId + the fastener CompPath -- else the $ctx.FastenerComponents count)
# and it does NOT draw the rectangle (the operator draws). The relief engine (arm + cut
# halves) is lib\curved_relief.ps1 (Invoke-FastenerReliefArm / Invoke-FastenerReliefCut).
#
# PATTERNING NOTE (user asked "can the slots be patterned?"): on a CURVED face NO -- every
# hole sits on a tangent plane with a DIFFERENT surface normal, and the only pattern channel
# (a single-direction LINEAR pattern) carries one fixed increment + orientation, so it cannot
# re-orient a copy to a new normal. So each fastener gets its own draw (this per-fastener loop).
#
# HARD RULES honored (repo house style):
#   * EDITS NOTHING existing -- only appends steps + a global helper.
#   * `function global:` so the .cmd dot-source scope + any closure resolves it.
#   * OnNext rebinds COM handles from $c (a bare $session read is stale) and NEVER claims
#     success on a canary miss ([[feedback_canary_must_not_assume_on_failure]]).
#   * Prompt closures capture $wiz/$c/index as LOCALS (never $script:GuiWiz --
#     [[project_gui_scope_bugs]]) and call only `function global:` helpers.
#   * ASCII-only. No $pid / read-only automatic assignments.
# ============================================================================

# ----------------------------------------------------------------------------
# Invoke-CurvedReliefArmAt - arm ONE fastener's relief sketch (the shared arm used by
# slot-arm for the first fastener and by slot-finish to re-arm the next/same one). Pre-selects
# that fastener's TOP plane then opens the extrude (NO guide planes) via the global
# Invoke-FastenerReliefArm (curved_relief.ps1), stashes the cut-canary baseline on
# $Context.SlotBaseFeat/SlotBaseStamp, and returns $true when the sketch is armed.
# `function global:` so an OnNext/closure resolves it. NEVER throws. -OnPoll pumps DoEvents.
# ----------------------------------------------------------------------------
function global:Invoke-CurvedReliefArmAt {
    param($Context, $Wizard, $Plan, [int]$Index, [scriptblock]$OnPoll = $null)
    $c = $Context; $wiz = $Wizard
    if ($null -eq $Plan) { return $false }
    $items = @(); try { if ($null -ne $Plan.Items) { $items = @($Plan.Items) } } catch { $items = @() }
    if ($Index -lt 0 -or $Index -ge @($items).Count) { return $false }
    $item = $items[$Index]
    $ptId = 0;    try { if ($null -ne $item.PointId) { $ptId = [int]$item.PointId } } catch { $ptId = 0 }
    $compPath = $null; try { $compPath = $item.CompPath } catch { $compPath = $null }
    $n = $Index + 1; $tot = @($items).Count
    # FALLBACK ONLY: the arm PRE-SELECTS this fastener's TOP plane before the extrude (same
    # reference the hole uses); this prompt fires only if that pre-select could not stage (e.g. a
    # stale component path), so the operator clicks the TOP plane. Either way the sketch lands on
    # the fastener's own TOP plane.
    $planePrompt = {
        [void]$wiz.AskInline('Pick the fastener TOP plane',
            ("Pocket {0} of {1}: the automatic TOP-plane selection did not take. Creo opened an extrude and is waiting for a sketch plane -- in Creo, click THIS fastener's TOP datum plane (the same plane its hole was drilled normal to), then click OK." -f $n, $tot),
            'OK', $true)
    }.GetNewClosure()
    $session = $c.Session; $model = $c.Model; $pfcType = $c.Type
    # RE-RESOLVE a FRESH component path for THIS fastener before the arm (the drill loop's proven
    # refresh -- a stashed IpfcComponentPath can go stale across the run; user 2026-07-29 "go
    # through the fasteners one by one and find the ID 1 because that will always be true"). Re-buffer
    # this fastener's planes by id off the stored path, then read the live path back; KEEP the stored
    # path if the refresh misses (fallback -- never regresses the working case). id 1 is the TOP plane
    # in EVERY fastener, so Invoke-FastenerReliefArm pre-selects it (id 1) on this fresh path.
    if ($null -ne $compPath) {
        try {
            $byId = Add-ComponentDefaultPlanesToBuffer -Session $session -Model $model -TypeObj $pfcType -ComponentPath $compPath
            if ($null -ne $byId -and [int]$byId.Added -ge 1) {
                $fp = Get-BufferComponentPath -Session $session
                if ($null -ne $fp) { $compPath = $fp }
            }
        } catch {}
    }
    $arm = $null
    try {
        $arm = Invoke-FastenerReliefArm -Session $session -Model $model -TypeObj $pfcType -ComponentPath $compPath `
                -PointId $ptId -TopPlaneId 1 -PlanePrompt $planePrompt -OnPoll $OnPoll
    } catch { $arm = $null }
    if ($null -eq $arm) { $c.SlotBaseFeat = @{}; $c.SlotBaseStamp = $null; return $false }
    $c.SlotBaseFeat = $arm.BaseFeat
    $c.SlotBaseStamp = $arm.BaseStamp
    return [bool]$arm.Armed
}

function global:Add-CurvedSlotSteps {
    param($Steps)

    # ========================================================================
    # slot-arm (run): open the FIRST fastener's relief sketch, then advance.
    # ========================================================================
    $armStep = New-WizardStep -Key 'slot-arm' -Title 'Chip-relief pockets: draw the first' -Stage 'Slots' -Kind 'run' -PrimaryText 'Open the first pocket sketch' `
        -Validate { param($c) return $true } `
        -Build {
            param($panel, $c, $wiz)
            $r = 0.0; try { if ($null -ne $c.ReliefDepth) { $r = [double]$c.ReliefDepth } } catch { $r = 0.0 }
            if ($r -le 0) { Add-Para $panel ("Chip relief is disabled (chip clearance 0). Press Next to skip to the summary.") 8 0 'gray'; return }
            if ($null -eq $c.BodyIndex) { Add-Para $panel ("No conformal blank body to cut into - chip relief is skipped. Press Next.") 8 0 'yellow'; return }
            $nH = 0; try { if ($null -ne $c.CurvedHolePairs) { $nH = @($c.CurvedHolePairs).Count } } catch { $nH = 0 }
            $nF = 0; try { if ($null -ne $c.FastenerComponents) { $nF = @($c.FastenerComponents).Count } } catch { $nF = 0 }
            $nComp = if ($nH -gt 0) { $nH } else { $nF }
            if ($nComp -lt 1) { Add-Para $panel ("No fasteners on record. Go Back to the Fasteners stage and select the fastener components, then rebuild.") 8 0 'yellow'; return }
            if ($c.SlotArmed) {
                Add-Para $panel ([char]0x2713 + (" The pocket sketch is OPEN in Creo on this fastener's TOP plane. Draw ONE rectangle over the hole, leave the sketch OPEN, then press Next to finish + cut it. There are {0} pocket(s) total." -f $nComp)) 8 0 'green' $true
                return
            }
            $y = (Add-ArmBanner $panel ("Press 'Open the first pocket sketch'. For each of the {0} fastener(s) you already selected (no re-picking): the tool PRE-SELECTS THAT fastener's OWN TOP datum plane (the same plane its hole was drilled normal to), then opens the extrude so the sketch opens ON it immediately -- hands-free, no reference planes. You draw ONE rectangle, then confirm on the NEXT step -- the tool cuts a symmetric {1}`" pocket (2 x {2}`" clearance) and reopens the next hole's sketch for you." -f $nComp, (2.0 * $r), $r) 8)
            Add-Para $panel ("The DRILLJIG PART must be ACTIVE in Creo. If the automatic TOP-plane selection does not take, the tool asks you to click that plane.") ($y + 10) 0 'gray'
        } `
        -OnNext {
            param($c, $wiz)
            if ($c.SlotArmed) { return $true }   # idempotent: already armed -> advance to finish
            $session = $c.Session; $model = $c.Model; $pfcType = $c.Type
            $r = 0.0; try { if ($null -ne $c.ReliefDepth) { $r = [double]$c.ReliefDepth } } catch { $r = 0.0 }
            # SKIP gates -> pass through to the summary (relief off / no body / no fasteners).
            $nH = 0; try { if ($null -ne $c.CurvedHolePairs) { $nH = @($c.CurvedHolePairs).Count } } catch { $nH = 0 }
            $nF = 0; try { if ($null -ne $c.FastenerComponents) { $nF = @($c.FastenerComponents).Count } } catch { $nF = 0 }
            $nComp = if ($nH -gt 0) { $nH } else { $nF }
            if ($r -le 0 -or $null -eq $c.BodyIndex -or $nComp -lt 1) {
                $c.SlotSkip = $true; $wiz.SetChip('reliefs', 'relief: skipped', 'set'); return $true
            }
            if ($null -eq $session -or $null -eq $model) { $wiz.SetChip('reliefs', 'relief: no session', 'warning'); return $false }
            # ACTIVE-MODEL GATE: the cut needs the jig PART active.
            $activeName = ''
            try { $am = $session.GetActiveModel(); if ($null -ne $am) { $activeName = [string]$am.FileName } } catch { $activeName = '' }
            if ($activeName -match '(?i)\.asm(\.\d+)?$') {
                [void]$wiz.AskInline('Activate the drilljig part',
                    ("Creo's ACTIVE model is the assembly ('" + $activeName + "'), not the drilljig part. Right-click the DRILLJIG PART in the Creo tree -> Activate, then click OK and press 'Open the first pocket sketch' again."),
                    'OK', $true)
                $wiz.SetChip('reliefs', 'relief: activate the jig part', 'warning'); return $false
            }
            # build the per-fastener target plan (PointId + CompPath from the drilled holes,
            # else N empties from the fastener count -> PointId 0 forces the operator pick).
            $items = @()
            if ($nH -gt 0) {
                foreach ($p in @($c.CurvedHolePairs)) {
                    $pt = 0; try { if ($null -ne $p.PointId) { $pt = [int]$p.PointId } } catch { $pt = 0 }
                    $cp = $null; try { $cp = $p.CompPath } catch { $cp = $null }
                    $og = $null; try { $og = $p.Origin } catch { $og = $null }   # position, for the radial plan
                    $items += [pscustomobject]@{ PointId = $pt; CompPath = $cp; Origin = $og }
                }
            } else {
                $fcs = @(); try { if ($null -ne $c.FastenerComponents) { $fcs = @($c.FastenerComponents) } } catch { $fcs = @() }
                for ($k = 0; $k -lt $nF; $k++) {
                    $og = $null; try { if ($k -lt @($fcs).Count) { $og = $fcs[$k].Origin } } catch { $og = $null }
                    $items += [pscustomobject]@{ PointId = 0; CompPath = $null; Origin = $og }
                }
            }
            $surfId = 0; try { if ($null -ne $c.FastenerSurfId) { $surfId = [int]$c.FastenerSurfId } } catch { $surfId = 0 }
            $holeDia = 0.0
            try {
                if ($null -ne $c.CurvedHoleDiaFinal -and [double]$c.CurvedHoleDiaFinal -gt 0) { $holeDia = [double]$c.CurvedHoleDiaFinal }
                elseif ($null -ne $c.FastenerHoleDia -and [double]$c.FastenerHoleDia -gt 0) { $holeDia = [double]$c.FastenerHoleDia }
            } catch { $holeDia = 0.0 }
            # ---- RADIAL / AXIS-PATTERN decision (auto when uniform; user 2026-07-30) ----
            # If the fasteners are uniformly spaced about an axis, draw ONE seed pocket then
            # AXIS-pattern the rest around the cylinder (Get-CurvedRadialPatternPlan, pure).
            # Else stay in the proven per-fastener loop. The seed fastener (the arc endpoint)
            # is SWAPPED to items[0] so the pattern seeds on it AND a pattern-miss fallback
            # per-fastener sweep covers the remaining holes cleanly.
            # OVERRIDE (self-compute + accept override): the parallel "Read radial distance"
            # session reads the follow-surface cylinder's AXIS into $c.RadialAxisGeom
            # (lib\curved_surface_radius.ps1, at surface-arm). When Valid it feeds
            # Get-CurvedRadialPatternPlan -Axis/-AxisPoint (a live-read axis is more reliable
            # than the circle-fit, and it lets even 2 fasteners plan); else the plan self-derives
            # the axis from the fastener positions. [[project_curved_radial_slot_pattern]]
            # MULTI-PATTERN groups (user 2026-07-31: "you can also create multiple patterns, if the
            # patterns arent at constant angles"). Get-CurvedRadialPatternGroups splits the fasteners
            # into ONE regular axis pattern at the best-fit pitch + a count-2 accommodation per stray
            # (mirrors flat-DJ Get-SlotSeedPatterns). ALL groups rotate the SAME seed about the SAME
            # axis. 1 group == the uniform-ring case. PatternCount<1 => draw by hand (per-fastener).
            $c.SlotPatternMode = 'perfastener'; $c.SlotRadialGroups = $null; $c.SlotSeedFeatId = 0
            $noRadial = $false; try { $noRadial = [bool]$c.NoRadialPattern } catch { $noRadial = $false }
            # RADIAL is only attemptable when the ATOMIC axis-by-id recipe is recorded
            # (Test-RadialPatternReady) AND a datum-axis feature id is available ($c.RadialAxisFeatId).
            # RunMacro CANNOT drive the operator-pick pattern -- the confirm is silently dropped across
            # the open/values RunMacro split (workflow-confirmed 2026-07-31, [[project_curved_radial_slot_pattern]]) --
            # so until probes\radialpat-probe.cmd Section B records the axis-collector widget + the
            # datum-axis tree-search type, the radial path is DARK and we draw per-fastener (honest: the
            # feature genuinely cannot work yet). The pure group math below still runs under the gate so
            # the moment the tokens + axis id land it lights up with no other change.
            $radialReady = $false
            try { $radialReady = ((Test-RadialPatternReady) -and ([int]$c.RadialAxisFeatId -gt 0)) } catch { $radialReady = $false }
            if ((-not $noRadial) -and $radialReady) {
                $positions = @(); foreach ($it in @($items)) { try { if ($null -ne $it.Origin) { $positions += ,$it.Origin } } catch {} }
                # axis override from the Read-radial-distance half (cylinder axis+point), if Valid.
                $rAxis = $null; $rAxisPt = $null
                try {
                    if ($null -ne $c.RadialAxisGeom -and [bool]$c.RadialAxisGeom.Valid) {
                        $rAxis   = $c.RadialAxisGeom.AxisDir
                        $rAxisPt = $c.RadialAxisGeom.AxisPt
                    }
                } catch { $rAxis = $null; $rAxisPt = $null }
                $grp = $null
                try { $grp = Get-CurvedRadialPatternGroups -Positions $positions -Axis $rAxis -AxisPoint $rAxisPt } catch { $grp = $null }
                $gpc = 0; try { if ($null -ne $grp) { $gpc = [int]$grp.PatternCount } } catch { $gpc = 0 }
                if ($null -ne $grp -and [bool]$grp.Valid -and $gpc -ge 1) {
                    $c.SlotRadialGroups = $grp
                    $c.SlotPatternMode = 'radial'
                    $seedIdx = -1; try { $seedIdx = [int]$grp.SeedIndex } catch { $seedIdx = -1 }
                    if ($seedIdx -gt 0 -and $seedIdx -lt @($items).Count) {
                        $tmp = $items[0]; $items[0] = $items[$seedIdx]; $items[$seedIdx] = $tmp
                    }
                    $wiz.Log(("  chip relief: draw ONE seed pocket then RADIAL-pattern the rest -- {0}" -f [string]$grp.Reason))
                }
            } elseif ((-not $noRadial) -and (@($items).Count -ge 2)) {
                $wiz.Log('  chip relief: radial auto-pattern is not enabled on this build yet (run probes\radialpat-probe.cmd Section B to record the axis-pattern tokens); drawing each pocket individually.')
            }

            $c.SlotPlan = @{ Mode = $c.SlotPatternMode; Items = @($items); Depth = $r; SurfId = $surfId; HoleDia = $holeDia }
            $c.SlotRunIndex = 0; $c.SlotAnyCut = $false; $c.SlotsDone = $false
            $poll = { try { [System.Windows.Forms.Application]::DoEvents() } catch {} }
            $wiz.BeginRun('Opening the first chip-relief pocket sketch...')
            $armed = Invoke-CurvedReliefArmAt -Context $c -Wizard $wiz -Plan $c.SlotPlan -Index 0 -OnPoll $poll
            if (-not $armed) {
                $wiz.SetChip('reliefs', 'relief: sketch did not open', 'aborted')
                $wiz.Log('  chip relief: the first pocket sketch did not open - inspect Creo, then retry.')
                return $false
            }
            $c.SlotArmed = $true
            $wiz.SetChip('reliefs', ("pockets: 1/{0}" -f @($items).Count), 'set')
            $wiz.Log(("  chip relief: pocket sketch open ({0} total). Draw the rectangle, then press 'Finish this pocket'." -f @($items).Count))
            return $true   # advance to slot-finish; Creo's sketcher stays open for the draw.
        }
    [void]$Steps.Add($armStep)

    # ========================================================================
    # slot-finish (run): the operator drew -> cut this pocket, re-arm the next (loop).
    # ========================================================================
    $finishStep = New-WizardStep -Key 'slot-finish' -Title 'Chip-relief pockets: cut + next' -Stage 'Slots' -Kind 'run' -PrimaryText 'Finish this pocket' `
        -Validate { param($c) return [bool]($c.SlotArmed -or $c.SlotSkip) } `
        -Build {
            param($panel, $c, $wiz)
            if ($c.SlotSkip) { Add-Para $panel ("Chip relief was skipped. Press Next to continue to the summary.") 8 0 'gray'; return }
            if ($c.SlotsDone) {
                Add-RebuiltNotice -Panel $panel -Context $c -Wizard $wiz -Message 'All chip-relief pockets are cut.' `
                    -ResetFlags @('SlotsDone','SlotArmed') -ResetValues @{ SlotRunIndex = 0; SlotAnyCut = $false } -GoToKey 'slot-arm'
                return
            }
            $tot = 0; try { if ($null -ne $c.SlotPlan -and $null -ne $c.SlotPlan.Items) { $tot = @($c.SlotPlan.Items).Count } } catch { $tot = 0 }
            $n = 1; try { $n = [int]$c.SlotRunIndex + 1 } catch { $n = 1 }
            $made = 0; try { if ($null -ne $c.ReliefsCut) { $made = [int]$c.ReliefsCut } } catch { $made = 0 }
            # RADIAL SEED banner: when the run is patternable and this is the first (seed) pocket,
            # explain draw-one-then-pattern; otherwise the per-fastener draw-each message.
            $isRadialSeed = ($c.SlotPatternMode -eq 'radial' -and ([int]$c.SlotRunIndex -eq 0))
            if ($isRadialSeed) {
                $rc = 0; try { $rc = [int]$c.SlotRadialGroups.Count } catch { $rc = 0 }
                $rp = 1; try { $rp = [int]$c.SlotRadialGroups.PatternCount } catch { $rp = 1 }
                $patWord = if ($rp -gt 1) { ("{0} radial patterns (the columns are not all equi-angular)" -f $rp) } else { "one radial pattern" }
                $y = (Add-ArmBanner $panel ("Draw ONE rectangle over THIS hole (the seed), leave the sketch OPEN, then press 'Finish this pocket'. The tool cuts it, asks you to PICK the rotation axis in Creo, and replicates it around the axis via {0} to cover all {1} fasteners. If a pattern does not take, it falls back to drawing the rest by hand." -f $patWord, $rc) 8)
            } else {
                $y = (Add-ArmBanner $panel ("In Creo's OPEN sketch: draw ONE rectangle over hole {0} of {1}, leave the sketch OPEN, then press 'Finish this pocket'. The tool cuts the symmetric pocket, then reopens the next hole's sketch automatically." -f $n, $tot) 8)
            }
            Add-Para $panel ("Pockets cut so far: {0}." -f $made) ($y + 10) 0 $(if ($made -ge 1) { 'green' } else { 'gray' })
        } `
        -OnNext {
            param($c, $wiz)
            if ($c.SlotSkip) { $wiz.SetChip('reliefs', 'relief: skipped', 'set'); return $true }
            if ($c.SlotsDone) { return $true }
            $session = $c.Session; $model = $c.Model; $pfcType = $c.Type
            $plan = $c.SlotPlan
            if ($null -eq $plan) { $wiz.Log('  chip relief: no plan (slot-arm did not run) - skipping.'); $wiz.SetChip('reliefs', 'relief: skipped', 'warning'); return $true }
            $items = @(); try { $items = @($plan.Items) } catch { $items = @() }
            $i = 0; try { $i = [int]$c.SlotRunIndex } catch { $i = 0 }
            $tot = @($items).Count
            if ($i -ge $tot) { $c.SlotsDone = $true; $wiz.MarkCommitted(); return $true }
            if ($null -eq $session -or $null -eq $model) { $wiz.SetChip('reliefs', 'relief: no session', 'warning'); return $false }
            # ACTIVE-MODEL GATE (the cut needs the jig PART active).
            $activeName = ''
            try { $am = $session.GetActiveModel(); if ($null -ne $am) { $activeName = [string]$am.FileName } } catch { $activeName = '' }
            if ($activeName -match '(?i)\.asm(\.\d+)?$') {
                [void]$wiz.AskInline('Activate the drilljig part',
                    ("Creo's ACTIVE model is the assembly ('" + $activeName + "'). Activate the DRILLJIG PART, then click OK and press 'Finish this pocket' again."),
                    'OK', $true)
                $wiz.SetChip('reliefs', 'relief: activate the jig part', 'warning'); return $false
            }
            $rd = 0.0; try { if ($null -ne $plan.Depth) { $rd = [double]$plan.Depth } } catch { $rd = 0.0 }
            $bodyIx = 0; try { if ($null -ne $c.BodyIndex) { $bodyIx = [int]$c.BodyIndex } } catch { $bodyIx = 0 }
            $poll = { try { [System.Windows.Forms.Application]::DoEvents() } catch {} }
            $wiz.BeginRun(("Cutting chip-relief pocket {0}/{1}..." -f ($i + 1), $tot))

            # FIRE THE CUT for the CURRENT (already-armed + drawn) fastener, canary-gated
            # against the baseline slot-arm/the last re-arm stashed on $c.
            $cut = $null
            try { $cut = Invoke-FastenerReliefCut -Session $session -Model $model -SymDepth (2.0 * $rd) -BodyIndex $bodyIx -BaseFeat $c.SlotBaseFeat -BaseStamp $c.SlotBaseStamp -OnPoll $poll } catch { $cut = $null }

            # per-iteration safety-close (guarantee a fresh dashboard); harmless no-op.
            try { $session.RunMacro("~ Enter ``main_dlg_cur`` ``dashInst0.Quit``;~ Exit ``main_dlg_cur`` ``dashInst0.Quit``;~ Activate ``main_dlg_cur`` ``dashInst0.Done``;") } catch {}

            if ($null -eq $cut -or -not $cut.Cut) {
                # NO CUT -> re-arm the SAME fastener + ask for a redraw + STAY (never tally).
                # NO-PROGRESS guard (review F2 2026-07-31): this branch (and the re-arm-fail branch
                # below) are the two ways slot-finish returns WITHOUT advancing. A wedged Creo can loop
                # here indefinitely; count consecutive no-progress returns (reset by any successful cut)
                # and, past a threshold, add an escape-hatch line so the operator knows Back leaves the
                # stage cleanly rather than being trapped in Finish->fail->OK->Finish.
                $rf = 0; try { if ($null -ne $c.SlotRearmFails) { $rf = [int]$c.SlotRearmFails } } catch { $rf = 0 }
                $rf++; $c.SlotRearmFails = $rf
                $wiz.SetChip('reliefs', ("pocket {0}/{1} redraw" -f ($i + 1), $tot), 'unverified')
                [void](Invoke-CurvedReliefArmAt -Context $c -Wizard $wiz -Plan $plan -Index $i -OnPoll $poll)
                $hint = if ($rf -ge 3) { (" This pocket has not advanced in {0} tries -- if Creo is stuck, press Back to leave the Slots stage (the jig and its drilled holes are already saved; re-run Slots later to finish the pockets)." -f $rf) } else { '' }
                [void]$wiz.AskInline('Chip-relief pocket',
                    ("Pocket {0}/{1} did not cut (the rectangle may not be a closed loop, or the sketch plane was not consumed). The sketcher is reopened - redraw the rectangle over the hole, leave it OPEN, then press 'Finish this pocket' again.{2}" -f ($i + 1), $tot, $hint),
                    'OK', $true)
                try { $wiz.Rerender() } catch {}
                return $false
            }

            # CUT confirmed -> tally + advance.
            if ($null -eq $c.ReliefsCut) { $c.ReliefsCut = 0 }
            $c.ReliefsCut = [int]$c.ReliefsCut + 1
            $c.SlotAnyCut = $true
            $c.SlotRunIndex = $i + 1
            $c.SlotRearmFails = 0   # PROGRESS: a pocket cut -> clear the no-progress escape-hatch guard (review F2)
            $wiz.SetChip('reliefs', ("relief pockets: {0}" -f [int]$c.ReliefsCut), 'built')
            $wiz.Log(("  + relief pocket {0}/{1} cut (total {2})." -f ($i + 1), $tot, [int]$c.ReliefsCut))

            # ---- RADIAL PATTERN: the FIRST cut ($i==0) is the SEED (swapped to index 0 in
            # slot-arm). Replicate it around the operator-picked axis instead of drawing every
            # remaining pocket. Canary-gated; on a MISS, fall back to the proven per-fastener
            # loop for the rest (never regresses). ([[project_curved_radial_slot_pattern]])
            if ($c.SlotPatternMode -eq 'radial' -and $i -eq 0) {
                $seedId = 0; try { $seedId = [int]$cut.NewFeatId } catch { $seedId = 0 }
                if ($seedId -gt 0) { $c.SlotSeedFeatId = $seedId }
                # MULTI-PATTERN: fire ONE axis pattern per group (regular + count-2 accommodations),
                # all rotating the SAME seed about the SAME axis. Disjoint azimuth sets, so a group
                # failing never duplicates another's copies. NOTE: use $rgroups/$grp locals, NOT $plan
                # (the outer $plan = $c.SlotPlan must stay intact for the per-fastener fallback re-arm).
                $rgroups = @(); try { if ($null -ne $c.SlotRadialGroups -and $null -ne $c.SlotRadialGroups.Groups) { $rgroups = @($c.SlotRadialGroups.Groups) } } catch { $rgroups = @() }
                $axisId = 0;   try { if ($null -ne $c.RadialAxisFeatId) { $axisId = [int]$c.RadialAxisFeatId } } catch { $axisId = 0 }
                $totalFast = 0; try { $totalFast = [int]$c.SlotRadialGroups.Count } catch { $totalFast = 0 }
                $groupsTot = @($rgroups).Count
                $copiesMade = 0; $groupsOk = 0; $gi = 0
                foreach ($grp in $rgroups) {
                    $gi++
                    $pcount = 0; try { $pcount = [int]$grp.Count } catch { $pcount = 0 }
                    $pinc = 0.0;  try { $pinc = [double]$grp.Increment } catch { $pinc = 0.0 }
                    if ($pcount -lt 2 -or $pinc -le 0) { continue }
                    $axisPrompt = {
                        [void]$wiz.AskInline('Pick the rotation axis',
                            ("Radial pattern {0} of {1}: in Creo, click the axis the pockets rotate around -- the cylinder's axis (or a datum/csys axis through it) -- then click OK. Places {2} pockets, {3:0.##} deg apart." -f $gi, $groupsTot, $pcount, $pinc),
                            'OK', $true)
                    }.GetNewClosure()
                    # attempt 1 (hands-free raw-COM seed + axis pick / by-id)
                    $pat = $null
                    if ($c.SlotSeedFeatId -gt 0) {
                        try { $pat = Invoke-CurvedReliefRadialPattern -Session $session -Model $model -TypeObj $pfcType -SeedFeatId ([int]$c.SlotSeedFeatId) -Count $pcount -IncrementDeg $pinc -AxisFeatId $axisId -AxisPrompt $axisPrompt -OnPoll $poll } catch { $pat = $null }
                    }
                    # attempt 2 (PROVEN): raw-COM seed did not register as the pattern TARGET (LIVE-
                    # UNVERIFIED; the operator's mapkey CLICKED the seed in the tree). Cancel the half-open
                    # dashboard, ask the operator to CLICK the seed pocket, re-fire on the live selection.
                    if ($null -eq $pat -or -not $pat.Patterned) {
                        $r1 = ''; try { if ($null -ne $pat) { $r1 = [string]$pat.Reason } } catch { $r1 = '' }
                        $wiz.Log(("  radial pattern {0}/{1} (hands-free) missed{2}; retrying with a manual seed click." -f $gi, $groupsTot, $(if ($r1) { ": $r1" } else { '' })))
                        # SAFE NO-OP if no dashboard is open (review F3 2026-07-31): the tokens target the
                        # SPECIFIC pattern widget (main_dlg_cur/dashInst0); if attempt 1 threw before opening
                        # it, RunMacro finds no such widget and the try/catch swallows it -- it does NOT
                        # dismiss any other dialog. If attempt 1 left the dashboard half-open, this closes it
                        # so the manual-seed retry starts clean.
                        try { $session.RunMacro("~ Enter ``main_dlg_cur`` ``dashInst0.Quit``;~ Exit ``main_dlg_cur`` ``dashInst0.Quit``;~ Activate ``main_dlg_cur`` ``dashInst0.Done``;") } catch {}
                        [void]$wiz.AskInline('Select the seed pocket',
                            ("Radial pattern {0} of {1}: Creo needs the seed selected. In Creo, CLICK the chip-relief pocket you cut FIRST (the seed) in the model tree, then click OK -- the tool opens the axis pattern on it and asks you to pick the rotation axis." -f $gi, $groupsTot),
                            'OK', $true)
                        try { $pat = Invoke-CurvedReliefRadialPattern -Session $session -Model $model -TypeObj $pfcType -SeedFeatId ([int]$c.SlotSeedFeatId) -Count $pcount -IncrementDeg $pinc -AxisFeatId $axisId -UseLiveSelection -AxisPrompt $axisPrompt -OnPoll $poll } catch { $pat = $null }
                    }
                    if ($null -ne $pat -and $pat.Patterned) { $copiesMade += [Math]::Max(0, $pcount - 1); $groupsOk++ }
                    else { $wiz.Log(("  radial pattern {0}/{1} did not take." -f $gi, $groupsTot)) }
                    try { $wiz.Pump() } catch {}
                }
                # DELIBERATE $groupsOk -ge 1 (review F4 2026-07-31): on PARTIAL success we must NOT fall
                # through to the per-fastener loop -- that loop re-arms items[1..N-1] blindly and would
                # RE-CUT every hole the successful group(s) already patterned (double-cut), because it
                # cannot know which azimuths a pattern covered. So >=1 group => mark done, flag the
                # shortfall honestly (unverified chip + re-run guidance), and let the operator re-run the
                # Slots stage to add only the missing pockets. Only 0 groups (nothing placed => no
                # double-cut risk) routes to the full per-fastener fallback below.
                if ($groupsOk -ge 1) {
                    # seed (already tallied +1) + every copy the successful groups added.
                    $c.ReliefsCut = [int]$c.ReliefsCut + $copiesMade
                    $c.SlotsDone = $true
                    if ($groupsOk -eq $groupsTot) {
                        $wiz.SetChip('reliefs', ("relief pockets: {0} (radial x{1})" -f [int]$c.ReliefsCut, $groupsOk), 'built')
                        $wiz.Log(("  + radial: {0} pattern(s) placed {1} pocket(s) around the axis (total {2} of {3})." -f $groupsOk, $copiesMade, [int]$c.ReliefsCut, $totalFast))
                    } else {
                        $wiz.SetChip('reliefs', ("relief: {0}/{1} patterns, {2}/{3} pockets" -f $groupsOk, $groupsTot, [int]$c.ReliefsCut, $totalFast), 'unverified')
                        $wiz.Log(("  ! radial: only {0} of {1} pattern groups took ({2} of {3} pockets). Verify in Creo + draw any missing by hand (re-run the Slots stage to add them)." -f $groupsOk, $groupsTot, [int]$c.ReliefsCut, $totalFast))
                    }
                    $wiz.MarkCommitted()
                    try { $wiz.Rerender() } catch {}
                    return $true
                }
                # NO group took -> fall back to the proven per-fastener loop for the REMAINING holes.
                $c.SlotPatternMode = 'perfastener'
                $wiz.SetChip('reliefs', 'relief: pattern miss -> per-fastener', 'unverified')
                $wiz.Log('  radial pattern did not take (no group registered); drawing the remaining pockets one by one.')
                # fall through to the standard per-fastener re-arm block below (uses $plan = $c.SlotPlan).
            }

            if ($c.SlotRunIndex -lt $tot) {
                # RE-ARM the next fastener + STAY (the operator draws it, then presses Finish).
                $armed = Invoke-CurvedReliefArmAt -Context $c -Wizard $wiz -Plan $plan -Index $c.SlotRunIndex -OnPoll $poll
                $nn = $c.SlotRunIndex + 1
                if (-not $armed) {
                    # ESCAPE-HATCH counter (review F2 2026-07-31): count consecutive re-arm failures at
                    # the SAME fastener. SlotRunIndex only advances on a cut, so a persistently failing
                    # arm (Creo wedged / plane gone) would otherwise trap the operator in an endless
                    # Finish->fail->OK->Finish loop. After 3 tries, tell them Back leaves the stage
                    # cleanly (jig + drilled holes are already saved). Additive: a successful arm resets it.
                    $rf = 0; try { if ($null -ne $c.SlotRearmFails) { $rf = [int]$c.SlotRearmFails } } catch { $rf = 0 }
                    $rf++; $c.SlotRearmFails = $rf
                    $wiz.SetChip('reliefs', ("pocket {0}/{1} sketch failed" -f $nn, $tot), 'aborted')
                    if ($rf -ge 3) {
                        [void]$wiz.AskInline('Chip-relief pocket',
                            ("Pocket {0}/{1} has failed to open {2} times in a row - Creo may be busy or the sketch plane is unavailable. Fix it in Creo and press 'Finish this pocket' to retry, OR press Back to leave the Slots stage (the jig and its drilled holes are already saved; you can re-run Slots later)." -f $nn, $tot, $rf),
                            'OK', $true)
                    } else {
                        [void]$wiz.AskInline('Chip-relief pocket',
                            ("Pocket {0}/{1}: the next sketch did not open - inspect Creo, then press 'Finish this pocket' again to retry it." -f $nn, $tot),
                            'OK', $true)
                    }
                    try { $wiz.Rerender() } catch {}
                    return $false
                }
                $c.SlotRearmFails = 0
                $wiz.SetChip('reliefs', ("pockets: {0}/{1}" -f $nn, $tot), 'set')
                [void]$wiz.AskInline('Chip-relief pocket',
                    ("Pocket {0}/{1} cut. The sketcher is reopened for pocket {2}/{1} - draw its rectangle over that hole, leave it OPEN, then press 'Finish this pocket' again." -f ($i + 1), $tot, $nn),
                    'OK', $true)
                try { $wiz.Rerender() } catch {}
                return $false
            }

            # ALL DONE.
            $c.SlotsDone = $true
            $wiz.SetChip('reliefs', ("relief pockets: {0} cut" -f [int]$c.ReliefsCut), 'built')
            $wiz.MarkCommitted()
            try { $wiz.Rerender() } catch {}
            return $true
        }
    [void]$Steps.Add($finishStep)
}
