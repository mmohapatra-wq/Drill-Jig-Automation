# ============================================================================
# lib\curved_gui_steps_relief.ps1 - the RELIEF (+ Done) step group for the
# CURVED drill jig wizard GUI (drilljig3d-gui.cmd).
# ============================================================================
# Defines ONE global function, Add-CurvedReliefSteps -Steps <ArrayList>, that
# appends FOUR wizard steps (all built via New-WizardStep, appended with
# [void]$Steps.Add(...)):
#
#   1. relief-intro (Stage 'Relief', info) - explain the per-hole chip-relief
#      slot; MATERIAL GATE (3D print auto-yes, metal asks) that sets $ctx.SlotSkip.
#   2. relief-plan  (Stage 'Relief', run ) - OnNext-only PLANNING: build the
#      per-hole seed list from $ctx.CurvedHolePairs, call Get-CurvedSlotPlan +
#      Test-CurvedSlotPlan, stash $ctx.SlotPlan (or SlotSkip on a bad plan).
#   3. relief-run   (Stage 'Relief', run ) - drive Invoke-CurvedSlotPlanRun: arm
#      each seed sketch on its tangent plane BY ID, pause for the operator to draw
#      the rectangle (AskInline DrawPrompt), cut (canary-gated), verify direction
#      once (AskInline VerifyPrompt). MarkCommitted once anything cuts.
#   4. done         (Stage 'Done', info ) - a recap of blank/holes/slots + a
#      "verify in Creo" note; Finish closes the wizard.
#
# HARD RULES honored (repo house style):
#   * This file EDITS NOTHING existing -- it only appends steps.
#   * `function global:` on Add-CurvedReliefSteps so the .cmd's dot-source scope
#     (a [scriptblock]::Create body) can call it AND so any closure resolves it.
#   * Build/OnNext handed to New-WizardStep are plain {param(...)} blocks (the
#     framework stores them and invokes them LATER via & $step.Build). Because the
#     framework invokes them after Add-CurvedReliefSteps has returned, they must NOT
#     reference a function-local variable (its scope is gone by then -- a plain block
#     captures its SessionState, not a live local). So the per-hole tangent-plane
#     collection + the "any tangent plane?" test are INLINED in each step (reading
#     only params + $c + globals), never a shared function-local scriptblock.
#   * The DrawPrompt / VerifyPrompt scriptblocks are INVOKED BY the curved-slot
#     lib (Invoke-CurvedSlotPlanRun) from OUTSIDE this step's scope, so they must
#     not depend on a run-local capture: they read $script:GuiWiz, which the
#     relief-run OnNext assigns to $wiz at its top (the same pattern drilljig-gui's
#     slot-b uses).
#   * RUN steps REBIND the COM handles from $ctx at the top of OnNext (a bare
#     $session read can be stale -- [[project_gui_scope_bugs]]), and never claim
#     success on a canary miss (Invoke-CurvedSlotPlanRun already canary-gates each
#     cut on a real VersionStamp change; this file only reports its result).
#   * ID-only throughout -- the slot loop arms sketches BY plane ID and never reads
#     IpfcPoint.Point.
#   * ASCII-only Write-Host / labels.
# ============================================================================

function global:Add-CurvedReliefSteps {
    param($Steps)

    # ========================================================================
    # STEP 1 - relief-intro (info): explain + MATERIAL GATE
    # ========================================================================
    $introStep = New-WizardStep -Key 'relief-intro' -Title 'Chip-relief slots' -Stage 'Relief' -Kind 'info' -PrimaryText 'Next' `
        -Validate { param($c) return $true } `
        -Build {
            param($panel, $c, $wiz)
            $y = (Add-Para $panel ("Chip-relief: each drilled hole gets a shallow rectangular slot cut on its TANGENT PLANE, normal to the curved surface. The slot clears chips/debris away from the bore while drilling.") 8 0 $null).Bottom + 10

            # count holes + how many carry a usable tangent plane (INLINE, no shared
            # function-local scriptblock -- see the header rule).
            $pairs = @()
            try { if ($null -ne $c.CurvedHolePairs) { $pairs = @($c.CurvedHolePairs) } } catch { $pairs = @() }
            $withPlane = 0
            foreach ($p in $pairs) {
                if ($null -eq $p) { continue }
                $plid = 0
                try { if ($null -ne $p.TangentPlaneId) { $plid = [int]$p.TangentPlaneId } } catch { $plid = 0 }
                if ($plid -gt 0) { $withPlane++ }
            }
            $y = (Add-Para $panel ("Holes drilled: {0}   |   holes with a tangent plane: {1}" -f @($pairs).Count, $withPlane) $y 0 'gray').Bottom + 8

            # honesty: report whether relief will run, and WHY (material gate below).
            if ($c.NoSlots) {
                Add-Para $panel ("Chip-relief slots are disabled (--no-slots). Press Next to skip to the summary.") $y 0 'gray'
            } elseif (@($pairs).Count -lt 1) {
                Add-Para $panel ("No holes were drilled, so there are no slots to cut. Press Next to skip to the summary.") $y 0 'gray'
            } elseif ($withPlane -lt 1) {
                Add-Para $panel ("No drilled hole carries a tangent plane, so there is nothing to arm a slot sketch on. Re-run the Drill stage with tangent-orientation ON to create per-hole tangent planes. Press Next to skip chip-relief.") $y 0 'yellow'
            } elseif ($c.Is3dPrint) {
                Add-Para $panel ("This is a 3D-printed jig, so chip-relief slots are added automatically. Press Next to plan the slots.") $y 0 'green'
            } else {
                Add-Para $panel ("This is a metal jig - you will be asked whether to add chip-relief slots when you press Next.") $y 0 $null
            }
        } `
        -OnNext {
            param($c, $wiz)
            # decide $c.SlotSkip up front so the plan/run steps can short-circuit.
            $c.SlotSkip = $false

            $pairs = @()
            try { if ($null -ne $c.CurvedHolePairs) { $pairs = @($c.CurvedHolePairs) } } catch { $pairs = @() }
            $withPlane = 0
            foreach ($p in $pairs) {
                if ($null -eq $p) { continue }
                $plid = 0
                try { if ($null -ne $p.TangentPlaneId) { $plid = [int]$p.TangentPlaneId } } catch { $plid = 0 }
                if ($plid -gt 0) { $withPlane++ }
            }

            # skip when disabled, when nothing was drilled, or when no hole has a plane.
            if ($c.NoSlots) {
                $c.SlotSkip = $true
                $wiz.SetChip('slots', 'slots: skipped (--no-slots)', 'set')
                return $true
            }
            if (@($pairs).Count -lt 1) {
                $c.SlotSkip = $true
                $wiz.SetChip('slots', 'slots: skipped (no holes)', 'set')
                return $true
            }
            if ($withPlane -lt 1) {
                $c.SlotSkip = $true
                $wiz.SetChip('slots', 'slots: skipped (no tangent planes)', 'warning')
                return $true
            }

            # MATERIAL GATE: 3D print auto-yes; metal asks.
            if ($c.Is3dPrint) {
                $c.SlotSkip = $false
                $wiz.SetChip('slots', 'slots: planned (3D print)', 'set')
                return $true
            }
            $ans = $wiz.AskInline('Chip-relief slots', 'Add a chip-relief slot at each hole?', 'YesNo')
            if ($ans -eq 'Yes') {
                $c.SlotSkip = $false
                $wiz.SetChip('slots', 'slots: planned', 'set')
            } else {
                $c.SlotSkip = $true
                $wiz.SetChip('slots', 'slots: skipped', 'set')
            }
            return $true
        }
    [void]$Steps.Add($introStep)

    # ========================================================================
    # STEP 2 - relief-plan (run): OnNext-only PLANNING (no Creo mutation)
    # ========================================================================
    $planStep = New-WizardStep -Key 'relief-plan' -Title 'Chip-relief slots: plan' -Stage 'Relief' -Kind 'run' -PrimaryText 'Plan the slots' `
        -Validate { param($c) return $true } `
        -Build {
            param($panel, $c, $wiz)
            if ($c.SlotSkip) {
                Add-Para $panel ("Chip-relief slots were skipped. Press Next to continue.") 8 0 'gray'
                return
            }
            $n = 0
            try { if ($null -ne $c.CurvedHolePairs) { $n = @($c.CurvedHolePairs).Count } } catch { $n = 0 }
            Add-Para $panel ("One chip-relief slot will be planned per drilled hole ({0} hole(s)), each armed on that hole's own tangent plane. Press 'Plan the slots' to build the plan (no geometry is created yet)." -f $n) 8 0 $null
        } `
        -OnNext {
            param($c, $wiz)
            if ($c.SlotSkip) { return $true }

            # build the per-hole seed records from the drilled holes (INLINE): each curved
            # hole carries the datum POINT it was drilled at (PointId) + the tangent PLANE
            # at that point (TangentPlaneId, whose normal IS the surface normal there ->
            # the seed-sketch host). Get-CurvedSlotPlan / CS-CleanHoles accepts PlaneId
            # (or SketchPlaneId) as the plane field; per-hole mode -> RowKey is $null.
            $pairs = @()
            try { if ($null -ne $c.CurvedHolePairs) { $pairs = @($c.CurvedHolePairs) } } catch { $pairs = @() }
            $slotHoles = @()
            $hasPlane = $false
            foreach ($p in $pairs) {
                if ($null -eq $p) { continue }
                $pointId = $null
                try { $pointId = $p.PointId } catch { $pointId = $null }
                $plid = 0
                try { if ($null -ne $p.TangentPlaneId) { $plid = [int]$p.TangentPlaneId } } catch { $plid = 0 }
                if ($plid -lt 0) { $plid = 0 }
                if ($plid -gt 0) { $hasPlane = $true }
                $slotHoles += [pscustomobject]@{ Id = $pointId; PlaneId = [int]$plid; RowKey = $null }
            }

            if (-not $hasPlane) {
                [void]$wiz.AskInline('Chip-relief slots',
                    ("No drilled hole has a usable tangent plane, so no slot sketch can be armed by ID. Re-run the Drill stage with tangent-orientation ON (each hole gets a tangent plane), then plan the slots again. Chip-relief is skipped for now."),
                    'OK')
                $c.SlotSkip = $true
                $c.SlotPlan = $null
                $wiz.SetChip('slots', 'slots: skipped (no tangent planes)', 'warning')
                return $true
            }

            $slotW = 0.0
            try { if ($null -ne $c.CurvedHoleDiaFinal) { $slotW = [double]$c.CurvedHoleDiaFinal } } catch { $slotW = 0.0 }

            $plan = $null
            try { $plan = Get-CurvedSlotPlan -Holes $slotHoles -SlotWidth $slotW -Mode 'per-hole' } catch { $plan = $null }
            $test = Test-CurvedSlotPlan -Plan $plan
            if ($null -eq $plan -or -not $test.Ok) {
                $issues = ''
                try { if ($null -ne $test -and $null -ne $test.Issues) { $issues = (@($test.Issues) -join '; ') } } catch { $issues = '' }
                [void]$wiz.AskInline('Chip-relief slots',
                    ("The slot plan could not be built" + $(if ($issues) { ": $issues" } else { "." }) + [Environment]::NewLine + [Environment]::NewLine +
                     "Chip-relief is skipped. You can re-run the Drill stage and try again."),
                    'OK')
                $c.SlotSkip = $true
                $c.SlotPlan = $null
                $wiz.SetChip('slots', 'slots: skipped (bad plan)', 'warning')
                return $true
            }

            $c.SlotPlan = $plan
            $seedN = 0
            try { $seedN = [int]$plan.Count } catch { $seedN = 0 }
            $wiz.Log(("Planned {0} chip-relief slot seed(s) (per-hole mode, width {1})." -f $seedN, $(if ($slotW -gt 0) { $slotW } else { 'unknown' })))
            $warns = @()
            try { if ($null -ne $plan.Warnings) { $warns = @($plan.Warnings) } } catch { $warns = @() }
            if ($warns.Count -gt 0) {
                $wiz.Log(("{0} plan warning(s):" -f $warns.Count))
                foreach ($w in $warns) { $wiz.Log(("  - {0}" -f $w)) }
            }
            $wiz.SetChip('slots', ("slots: {0} planned" -f $seedN), 'set')
            return $true
        }
    [void]$Steps.Add($planStep)

    # ========================================================================
    # STEP 3 - relief-run (run): drive the curved slot loop
    # ========================================================================
    $runStep = New-WizardStep -Key 'relief-run' -Title 'Chip-relief slots: cut' -Stage 'Relief' -Kind 'run' -PrimaryText 'Cut the slots' `
        -Validate { param($c) return [bool]($c.SlotSkip -or $null -ne $c.SlotPlan) } `
        -Build {
            param($panel, $c, $wiz)
            if ($c.SlotSkip -or $null -eq $c.SlotPlan) {
                Add-Para $panel ("Chip-relief slots were skipped. Press Next to continue.") 8 0 'gray'
                return
            }
            if ($c.SlotsCut) {
                Add-RebuiltNotice -Panel $panel -Context $c -Wizard $wiz -Message 'Chip-relief slots are already cut.' `
                    -ResetFlags @('SlotsCut') -GoToKey 'relief-plan'
                return
            }
            $seedN = 0
            try { $seedN = [int]$c.SlotPlan.Count } catch { $seedN = 0 }
            $y = (Add-ArmBanner $panel ("For each of the {0} planned slot(s), Creo opens a sketch on that hole's tangent plane. Draw ONE rectangle over the hole, leave the sketch OPEN, then click OK in the prompt - Creo cuts the slot and (on the first one) asks you to confirm the direction." -f $seedN) 8)
            Add-Para $panel ("Press 'Cut the slots' to begin.") ($y + 12) 0 'gray'
        } `
        -OnNext {
            param($c, $wiz)
            if ($c.SlotSkip -or $null -eq $c.SlotPlan) { return $true }
            if ($c.SlotsCut) { return $true }   # idempotent: revisited after cutting -> do not re-cut

            # REBIND COM handles from $ctx (a bare $session read can be stale --
            # [[project_gui_scope_bugs]]). The curved-slot lib reads the core scope set
            # by Initialize-DrilljigCore, so these locals are for parity + any direct use.
            if ($null -ne $c.Session) { $session = $c.Session }
            if ($null -ne $c.Model)   { $model   = $c.Model }
            if ($null -ne $c.Type)    { $pfcType = $c.Type }

            # CAPTURE $wiz for the DrawPrompt/VerifyPrompt closures, which the slot lib
            # invokes from OUTSIDE this scope. $script:GuiWiz is the same channel
            # drilljig-gui's slot-b uses; the closures read it so they never depend on a
            # run-local capture.
            $script:GuiWiz = $wiz

            $wiz.BeginRun('Cutting chip-relief slots...')

            $depth = 0.25
            try { if ($null -ne $c.SlotDepthAbs -and [double]$c.SlotDepthAbs -gt 0) { $depth = [double]$c.SlotDepthAbs } } catch { $depth = 0.25 }
            $bodyIx = 0
            try { if ($null -ne $c.BodyIndex) { $bodyIx = [int]$c.BodyIndex } } catch { $bodyIx = 0 }

            # DrawPrompt: pause for the operator to draw the rectangle on the armed
            # sketch. -NoActivate so the wizard does NOT steal focus from Creo (the
            # operator is drawing IN Creo). Its return is ignored (a pause, not a choice).
            $drawPrompt = {
                param($seed)
                $k = 'this hole'
                try { if ($null -ne $seed.Key) { $k = "$($seed.Key)" } } catch {}
                [void]$script:GuiWiz.AskInline('Draw the slot',
                    ("Draw the rectangle over hole '$k', leave the sketch OPEN, then click OK."),
                    'OK', $true)
            }.GetNewClosure()

            # VerifyPrompt: confirm the FIRST cut went INTO the plate the right way.
            # Returns $true (correct) / $false (wrong -> lib undoes + flips + redraws).
            $verifyPrompt = {
                param($seed, $flip)
                $ans = $script:GuiWiz.AskInline('Verify slot',
                    'Did the slot cut INTO the plate at the right depth?', 'YesNo')
                return ($ans -eq 'Yes')
            }.GetNewClosure()

            $poll = { try { [System.Windows.Forms.Application]::DoEvents() } catch {} }

            $run = $null
            try {
                $run = Invoke-CurvedSlotPlanRun -Plan $c.SlotPlan -Depth $depth -BodyIndex $bodyIx `
                        -OnPoll $poll -DrawPrompt $drawPrompt -VerifyPrompt $verifyPrompt
            } catch {
                $wiz.Log("Slot loop error: $($_.Exception.Message)")
                $wiz.SetChip('slots', 'slots: aborted', 'aborted')
                return $true
            }

            if ($null -eq $run) {
                $wiz.Log('Slot loop returned nothing - treating as aborted.')
                $wiz.SetChip('slots', 'slots: aborted', 'aborted')
                return $true
            }

            $cut     = 0; try { $cut     = [int]$run.SeedsCut }     catch {}
            $failed  = 0; try { $failed  = [int]$run.SeedsFailed }  catch {}
            $skipped = 0; try { $skipped = [int]$run.SeedsSkipped } catch {}
            $wiz.Log(("Slots cut: {0}  failed: {1}  skipped (no plane): {2}." -f $cut, $failed, $skipped))
            $warns = @()
            try { if ($null -ne $run.Warnings) { $warns = @($run.Warnings) } } catch { $warns = @() }
            if ($warns.Count -gt 0) {
                $wiz.Log(("{0} warning(s):" -f $warns.Count))
                foreach ($w in $warns) { $wiz.Log(("  - {0}" -f $w)) }
            }

            if ($cut -gt 0) {
                $c.SlotsCut = $true
                $wiz.MarkCommitted()
                $state = if ($failed -eq 0 -and $skipped -eq 0) { 'built' } else { 'unverified' }
                $wiz.SetChip('slots', ("slots: {0} cut" -f $cut), $state)
            } elseif ($failed -gt 0 -or $skipped -gt 0) {
                $wiz.SetChip('slots', ("slots: 0 cut ({0} failed / {1} skipped)" -f $failed, $skipped), 'unverified')
            } else {
                $wiz.SetChip('slots', 'slots: 0 cut', 'aborted')
            }
            return $true
        }
    [void]$Steps.Add($runStep)

    # ========================================================================
    # STEP 4 - done (info): summary recap
    # ========================================================================
    $doneStep = New-WizardStep -Key 'done' -Title 'Done' -Stage 'Done' -Kind 'info' -PrimaryText 'Finish' `
        -Validate { param($c) return $true } `
        -Build {
            param($panel, $c, $wiz)
            $msg = "Curved drill-jig run complete." + [Environment]::NewLine + [Environment]::NewLine

            if ($c.BlankMade) {
                $msg += "  Conformal blank: built (verify the thickness/standoff visually in Creo)."
                $msg += [Environment]::NewLine
            } else {
                $msg += "  Conformal blank: NOT built."
                $msg += [Environment]::NewLine
            }

            $holesN = 0
            try { if ($null -ne $c.HolesMade) { $holesN = [int]$c.HolesMade } } catch { $holesN = 0 }
            if ($holesN -gt 0) {
                $msg += ("  Holes: {0} drilled normal to the surface (verify visually in Creo)." -f $holesN) + [Environment]::NewLine
            } else {
                $msg += "  Holes: none drilled." + [Environment]::NewLine
            }

            if ($c.SlotsCut) {
                $msg += "  Chip-relief slots: cut (verify each spans its hole at the correct depth)." + [Environment]::NewLine
            } elseif ($c.SlotSkip) {
                $msg += "  Chip-relief slots: skipped." + [Environment]::NewLine
            } else {
                $msg += "  Chip-relief slots: NOT cut." + [Environment]::NewLine
            }

            $warns = @()
            try { if ($null -ne $c.SlotPlan -and $null -ne $c.SlotPlan.Warnings) { $warns = @($c.SlotPlan.Warnings) } } catch { $warns = @() }
            if ($warns.Count -gt 0 -and -not $c.SlotSkip) {
                $msg += ("    NOTE: {0} slot-plan warning(s) - check every hole has its slot." -f $warns.Count) + [Environment]::NewLine
            }

            $mf = 0
            try { $mf = [int]$script:macroFailures } catch { $mf = 0 }
            if ($mf -gt 0) {
                $msg += [Environment]::NewLine + ("  NOTE: {0} mapkey failure(s) during the run - inspect Creo." -f $mf)
            }

            $msg += [Environment]::NewLine + [Environment]::NewLine + "Verify all geometry in Creo. Press Finish to close (the Creo session stays open)."
            Add-Para $panel $msg 8 0 $null $false

            $doneState = if ($mf -eq 0) { 'built' } else { 'unverified' }
            $wiz.SetChip('done', 'run complete', $doneState)
        } `
        -OnNext { param($c, $wiz) return $true }
    [void]$Steps.Add($doneStep)
}
