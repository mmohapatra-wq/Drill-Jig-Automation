# ============================================================================
# lib\curved_gui_steps_done.ps1 - the DONE step group for the CURVED drill jig
# wizard GUI (drilljig3d-gui.cmd).
# ============================================================================
# Defines ONE global function, Add-CurvedDoneSteps -Steps <ArrayList>, that appends
# the single 'done' summary step (Stage 'Done'). This step was RELOCATED out of the
# retired lib\curved_gui_steps_relief.ps1 when the separate tangent-plane Relief
# stage was removed (chip-relief is now cut INLINE in the Fasteners stage -- a
# symmetric remove-material pocket on each fastener's TOP plane). The recap here is
# rewritten to report the conformal blank, holes drilled, and RELIEF POCKETS cut
# ($c.ReliefsCut) instead of the old per-hole slot tallies.
#
# HARD RULES honored (repo house style):
#   * This file EDITS NOTHING existing -- it only appends a step.
#   * `function global:` on Add-CurvedDoneSteps so the .cmd's dot-source scope (a
#     [scriptblock]::Create body) can call it AND so any closure resolves it.
#   * The Build handed to New-WizardStep is a plain {param(...)} block (the framework
#     stores + invokes it later); it reads only $panel/$c/$wiz + globals.
#   * ASCII-only Write-Host / labels.
# ============================================================================

function global:Add-CurvedDoneSteps {
    param($Steps)

    # ========================================================================
    # done (info): summary recap of blank / holes / relief pockets.
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

            # Hole tally: the Fasteners stage sets FastenerHolesMade; the (unwired) manual
            # Drill stage set HolesMade. Read whichever is populated so the recap is honest
            # regardless of which hole method ran.
            $holesN = 0
            try {
                if ($null -ne $c.HolesMade -and [int]$c.HolesMade -gt 0) { $holesN = [int]$c.HolesMade }
                elseif ($null -ne $c.FastenerHolesMade) { $holesN = [int]$c.FastenerHolesMade }
            } catch { $holesN = 0 }
            if ($holesN -gt 0) {
                $msg += ("  Holes: {0} drilled (verify the size + orientation visually in Creo)." -f $holesN) + [Environment]::NewLine
            } else {
                $msg += "  Holes: none drilled." + [Environment]::NewLine
            }

            # Chip-relief tally: each fastener with relief > 0 got a symmetric pocket on its
            # TOP plane, cut INLINE in the Fasteners stage. Report the count honestly.
            $reliefN = 0
            try { if ($null -ne $c.ReliefsCut) { $reliefN = [int]$c.ReliefsCut } } catch { $reliefN = 0 }
            $reliefWanted = $false
            try { if ($null -ne $c.ReliefDepth -and [double]$c.ReliefDepth -gt 0) { $reliefWanted = $true } } catch { $reliefWanted = $false }
            if (-not $reliefWanted) {
                $msg += "  Chip-relief pockets: none (relief depth was 0)." + [Environment]::NewLine
            } elseif ($reliefN -gt 0) {
                $msg += ("  Chip-relief pockets: {0} cut (verify each straddles its hole at the correct depth)." -f $reliefN) + [Environment]::NewLine
                if ($holesN -gt 0 -and $reliefN -lt $holesN) {
                    $msg += ("    NOTE: {0} hole(s) have no relief pocket - inspect Creo / re-run the fastener loop." -f ($holesN - $reliefN)) + [Environment]::NewLine
                }
            } else {
                $msg += "  Chip-relief pockets: NONE cut (relief was requested but no pocket registered) - inspect Creo." + [Environment]::NewLine
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
