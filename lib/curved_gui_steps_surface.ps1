# ============================================================================
# lib\curved_gui_steps_surface.ps1 - the SURFACE step group for the INPUT-FIRST
# curved drill jig wizard GUI (drilljig3d-gui.cmd), Stage 'Surface'.
# ============================================================================
# Defines ONE global function, Add-CurvedSurfaceSteps -Steps <ArrayList>, that
# appends the SINGLE surface-pick step. In the input-first re-sequence the operator
# picks the surface up front (STAGE 2, after the fasteners); the BUILD itself
# (offset+thicken -> new body, corner round, drilling) is fired hands-free later by
# the STAGE-4 build-run batch (lib\curved_gui_steps_build.ps1). The blank-build +
# corner-round steps that used to live here were RELOCATED into that batch as the
# global action helpers Invoke-CurvedBlankAction / Invoke-CurvedCornerAction, so the
# offset+thicken+new-body + corner-round logic has ONE home (the batch), fired in
# order after all input is collected.
#
# STEPS (Stage 'Surface'):
#   1. surface-arm (pick) - operator Ctrl-clicks the surface(s) the jig follows;
#      verify reads them ID-only into $ctx.SurfIds. Its OnNext also DEFAULTS
#      $ctx.FastenerSurfId from the picked surface (its home now that fasteners are
#      selected before the surface). The STAGE-4 batch pre-selects these ids by ID so
#      ProCmdFtOffset auto-consumes them (the proven select-by-ID -> offset channel).
#      verify ALSO reads the picked surface's RADIAL DISTANCE (cylinder radius+axis,
#      when it is a cylinder) into $ctx.RadialAxisGeom via Read-CurvedRadialGeomFromBuffer
#      (lib\curved_surface_radius.ps1) - the OVERRIDE the radial-pattern session consumes
#      ("self-compute + accept override"). Best-effort: a non-cylinder leaves it
#      Valid=$false and the pattern falls back to its self-computed increment.
#
# HARD RULES honored (repo house style):
#   * EDITS NOTHING existing -- only appends steps.
#   * `function global:` so the .cmd's [scriptblock]::Create dot-source scope + any
#     closure resolves it.
#   * The RUN step REBINDS the COM handles from $ctx at the top of OnNext (a bare
#     $session read can be stale -- [[project_gui_scope_bugs]]) and NEVER claims
#     success on a canary miss ([[feedback_canary_must_not_assume_on_failure]]) --
#     a build whose VersionStamp did not change STAYS on the step + reports.
#   * A button/verify Add_Click closure references ONLY its params + $ctx + GLOBAL fns.
#   * ID-only selection reads (Resolve-SelectedSurfaces; never IpfcPoint.Point).
#   * ASCII-only Write-Host / labels.
# ============================================================================

function global:Add-CurvedSurfaceSteps {
    param($Steps)

    # ========================================================================
    # STEP 1 - surface-arm (pick): pick the surface(s) the jig follows.
    # ========================================================================
    $armStep = New-WizardStep -Key 'surface-arm' -Title 'Pick the surface to follow' -Stage 'Surface' -Kind 'pick' -PrimaryText 'Continue' `
        -Validate {
            param($c)
            $n = 0
            try { if ($null -ne $c.SurfIds) { $n = @($c.SurfIds).Count } } catch { $n = 0 }
            return [bool]($n -ge 1)
        } `
        -Build {
            param($panel, $c, $wiz)
            $y = (Add-Para $panel ("The conformal jig blank is an OFFSET of the surface you pick, thickened into a NEW body. In Creo (with the jig part ACTIVATED in the assembly), Ctrl-click the surface(s) the jig should follow, then click the verify button below. The next step builds the blank in one shot - no further Creo picks.") 8 0 $null).Bottom + 6
            $n = 0
            try { if ($null -ne $c.SurfIds) { $n = @($c.SurfIds).Count } } catch { $n = 0 }
            if ($n -ge 1) {
                $y = (Add-Para $panel (("Captured {0} surface(s): {1}. Re-verify to change the selection." -f $n, (@($c.SurfIds) -join ', '))) $y 0 'green').Bottom + 6
            }
            $yb = (Add-ArmBanner $panel ("Ctrl-click the surface(s) to follow in Creo, then click 'I clicked it - verify'.") ($y + 4))
            Add-VerifyControls -Panel $panel -Context $c -Wizard $wiz -Top ($yb + 14) -OnVerify {
                param($Context, $Wizard)
                $res = $null
                try { $res = Resolve-SelectedSurfaces -Session $Context.Session -TypeObj $Context.Type } catch { $res = $null }
                if ($null -eq $res) { return @{ Ok = $false; Message = 'Could not read the selection buffer.' } }
                $ids = @($res.Surfaces)
                if ($ids.Count -lt 1) {
                    $rej = 0
                    try { $rej = @($res.Rejected).Count } catch { $rej = 0 }
                    $extra = if ($rej -gt 0) { (" ({0} non-surface selection(s) ignored)" -f $rej) } else { '' }
                    return @{ Ok = $false; Message = ("No surface read from the selection" + $extra + ". Click a model SURFACE (not a feature/edge/datum) and try again.") }
                }
                $Context.SurfIds = @($ids)
                $msg = ("Captured {0} surface(s): {1}." -f $ids.Count, ($ids -join ', '))
                try { if (@($res.Rejected).Count -gt 0) { $msg += (" ({0} non-surface selection(s) ignored.)" -f @($res.Rejected).Count) } } catch {}
                # RADIAL-DISTANCE OVERRIDE ("read radial distance" session, see the memory
                # note project_curved_radial_slot_pattern): if the picked follow-surface is a
                # genuine cylinder, read its RADIUS + AXIS off the surface descriptor and stash
                # it in $ctx.RadialAxisGeom for the radial-pattern step to consume as an
                # override (the "self-compute + accept override" contract). Best-effort, from
                # the SAME live buffer the ids came from, and NEVER throws: a non-cylindrical
                # follow surface leaves RadialAxisGeom Valid=$false and the pattern step falls
                # back to its self-computed increment + operator-picked axis. Read-*FromBuffer
                # is a GLOBAL fn (curved_surface_radius.ps1) so this closure resolves it.
                $geom = $null
                try { $geom = Read-CurvedRadialGeomFromBuffer -Session $Context.Session -TypeObj $Context.Type -PreferSurfId ([int]@($ids)[0]) } catch { $geom = $null }
                $Context.RadialAxisGeom = $geom
                try { if ($null -ne $geom) { $msg += (" " + (Format-CurvedRadialGeom $geom)) } } catch {}
                return @{ Ok = $true; Message = $msg }
            }
        } `
        -OnNext {
            param($c, $wiz)
            $n = 0
            try { if ($null -ne $c.SurfIds) { $n = @($c.SurfIds).Count } } catch { $n = 0 }
            if ($n -ge 1) { $wiz.SetChip('surface', ("surface: {0} face(s) picked" -f $n), 'set') }
            # Default the fastener orientation surface here (fasteners were picked BEFORE the
            # surface in the input-first flow, so this is the surface's home for that default).
            $sid = 0; try { if ($null -ne $c.FastenerSurfId) { $sid = [int]$c.FastenerSurfId } } catch { $sid = 0 }
            if ($sid -le 0) { try { if ($null -ne $c.SurfIds -and @($c.SurfIds).Count -ge 1) { $sid = [int]@($c.SurfIds)[0] } } catch { $sid = 0 } }
            $c.FastenerSurfId = $sid
            return $true
        }
    [void]$Steps.Add($armStep)

}
