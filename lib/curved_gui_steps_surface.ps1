# ============================================================================
# lib\curved_gui_steps_surface.ps1 - the SURFACE step group for the CURVED drill
# jig wizard GUI (drilljig3d-gui.cmd).
# ============================================================================
# Defines ONE global function, Add-CurvedSurfaceSteps -Steps <ArrayList>, that
# appends TWO wizard steps (built via New-WizardStep, appended with
# [void]$Steps.Add(...)) mirroring the flat GUI's box-a / box-b arm/verify SPLIT,
# adapted to the SURFACE pick + the STAGE-1 offset+thicken conformal blank:
#
#   1. surface-arm  (Stage 'Surface', pick) - ARM the surface pick: the operator
#      Ctrl-clicks the surface(s) the jig follows; a verify button reads the buffer
#      ID-only (Resolve-SelectedSurfaces) and stashes $ctx.SurfIds. Next gated on
#      >=1 surface. No macro fires here (a pick step).
#   2. surface-run  (Stage 'Surface', run) - fire ONE atomic offset(StandOff)+
#      thicken(Thickness) via Invoke-ConformalBlank (lib\conformal_blank.ps1): it
#      canary-gates on VersionStamp, regenerative-dimensions the offset + thickness,
#      and diffs for the NEW blank BODY. Stashes $ctx.BlankMade / BodyIndex / BodyId
#      / BodyName for the Drill stage. MarkCommitted; idempotent on re-entry.
#
# HARD RULES honored (repo house style -- identical to the sibling step libs):
#   * EDITS NOTHING existing -- only appends steps.
#   * `function global:` so the .cmd's [scriptblock]::Create dot-source scope + any
#     closure resolves it.
#   * Build/Validate/OnNext handed to New-WizardStep are plain {param(...)} blocks;
#     a button/verify Add_Click closure (inside Add-VerifyControls) references ONLY
#     its params + $ctx + GLOBAL fns (state lives in $ctx, never a Build-local).
#   * The RUN step REBINDS the COM handles from $ctx at the top of OnNext (a bare
#     $session read can be stale -- [[project_gui_scope_bugs]]) and NEVER claims
#     success on a canary miss ([[feedback_canary_must_not_assume_on_failure]]).
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
            $y = (Add-Para $panel ("The conformal jig blank is an OFFSET of the surface you pick, thickened into a new body. In Creo, Ctrl-click the surface(s) the jig should follow (several faces of one quilt are fine), then click the verify button below.") 8 0 $null).Bottom + 6
            # show what is already captured (so a revisit reads clearly)
            $n = 0
            try { if ($null -ne $c.SurfIds) { $n = @($c.SurfIds).Count } } catch { $n = 0 }
            if ($n -ge 1) {
                $y = (Add-Para $panel (("Captured {0} surface(s): {1}. Re-verify to change the selection." -f $n, (@($c.SurfIds) -join ', '))) $y 0 'green').Bottom + 6
            }
            $yb = (Add-ArmBanner $panel ("Ctrl-click the surface(s) to follow in Creo, then click 'I clicked it - verify'.") ($y + 4))
            # $OnVerify reads the buffer ID-only and stashes $ctx.SurfIds.
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
                return @{ Ok = $true; Message = $msg }
            }
        } `
        -OnNext {
            param($c, $wiz)
            $n = 0
            try { if ($null -ne $c.SurfIds) { $n = @($c.SurfIds).Count } } catch { $n = 0 }
            if ($n -ge 1) { $wiz.SetChip('surface', ("surface: {0} face(s) picked" -f $n), 'set') }
            return $true
        }
    [void]$Steps.Add($armStep)

    # ========================================================================
    # STEP 2 - surface-run (run): offset + thicken -> conformal blank body.
    # ========================================================================
    $runStep = New-WizardStep -Key 'surface-run' -Title 'Build the conformal blank' -Stage 'Surface' -Kind 'run' -PrimaryText 'Build the conformal blank' `
        -Validate {
            param($c)
            $n = 0
            try { if ($null -ne $c.SurfIds) { $n = @($c.SurfIds).Count } } catch { $n = 0 }
            $t = 0.0
            try { if ($null -ne $c.Thickness) { $t = [double]$c.Thickness } } catch { $t = 0.0 }
            return [bool](($n -ge 1) -and ($t -gt 0))
        } `
        -Build {
            param($panel, $c, $wiz)
            if ($c.BlankMade) {
                Add-RebuiltNotice -Panel $panel -Context $c -Wizard $wiz -Message ("The conformal blank is already built" + $(if ($c.BodyName) { " ('" + [string]$c.BodyName + "')" } else { "" }) + ".") `
                    -ResetFlags @('BlankMade') -GoToKey 'surface-arm'
                return
            }
            $n = 0
            try { if ($null -ne $c.SurfIds) { $n = @($c.SurfIds).Count } } catch { $n = 0 }
            $t = 0.0; try { if ($null -ne $c.Thickness) { $t = [double]$c.Thickness } } catch { $t = 0.0 }
            $so = 0.0; try { if ($null -ne $c.StandOff)  { $so = [double]$c.StandOff }  } catch { $so = 0.0 }
            $soNote = if ($so -gt 0) { ("standoff {0} (jig floats off the part)" -f $so) } else { "standoff 0 (flush / coincident)" }
            Add-Para $panel (("Offset the {0} picked surface(s) at {1}, then thicken to {2} into a NEW solid body. Press 'Build the conformal blank' to begin. Do not touch Creo while it runs." -f $n, $soNote, $t)) 8 0 $null
        } `
        -OnNext {
            param($c, $wiz)
            if ($c.BlankMade) { return $true }   # idempotent: revisited after building -> do not re-build

            # REBIND COM handles from $ctx (a bare $session read can be stale). The
            # conformal-blank engine also reads the core scope set by Initialize-DrilljigCore.
            $session = $null; $model = $null; $pfcType = $null
            if ($null -ne $c.Session) { $session = $c.Session }
            if ($null -ne $c.Model)   { $model   = $c.Model }
            if ($null -ne $c.Type)    { $pfcType = $c.Type }
            if ($null -eq $session -or $null -eq $model) {
                $wiz.SetChip('surface', 'surface: aborted (no session)', 'aborted')
                return $true
            }

            $surfIds = @()
            try { if ($null -ne $c.SurfIds) { $surfIds = @($c.SurfIds | ForEach-Object { [int]$_ }) } } catch { $surfIds = @() }
            if (@($surfIds).Count -lt 1) {
                $wiz.SetChip('surface', 'surface: no surface picked', 'warning')
                [void]$wiz.AskInline('Conformal blank', 'No surface was captured. Go Back to the surface pick and verify a surface first.', 'OK')
                return $false
            }
            $thickness = 0.0; try { $thickness = [double]$c.Thickness } catch {}
            $standoff  = 0.0; try { if ($null -ne $c.StandOff) { $standoff = [double]$c.StandOff } } catch {}

            $wiz.BeginRun('Creating the conformal blank (offset + thicken)...')
            $wiz.Log(("Offsetting {0} surface(s) at standoff {1}, thickening to {2}..." -f @($surfIds).Count, $standoff, $thickness))

            $poll = { try { [System.Windows.Forms.Application]::DoEvents() } catch {} }
            $res = $null
            try {
                $res = Invoke-ConformalBlank -Session $session -Model $model -TypeObj $pfcType `
                    -SurfIds $surfIds -Thickness $thickness -StandOff $standoff -OnPoll $poll
            } catch {
                $wiz.Log("  offset+thicken error: $($_.Exception.Message)")
                $wiz.SetChip('surface', 'surface: FAILED', 'aborted')
                [void]$wiz.AskInline('Conformal blank', ("The offset+thicken raised an error:" + [Environment]::NewLine + $_.Exception.Message + [Environment]::NewLine + [Environment]::NewLine + "Inspect Creo. You can retry this step."), 'OK')
                return $false
            }

            if ($null -eq $res -or -not $res.Made) {
                $why = if ($null -ne $res -and $res.Reason) { [string]$res.Reason } else { 'the model did not change' }
                $wiz.Log("  NOT built: $why")
                $wiz.SetChip('surface', 'surface: FAILED', 'aborted')
                [void]$wiz.AskInline('Conformal blank', ("The conformal blank was NOT created (" + $why + ")." + [Environment]::NewLine + [Environment]::NewLine + "Check Creo: did the offset dashboard pick up the pre-selected surface, and did the widget names still match? You can retry this step."), 'OK')
                return $false   # stay so the operator can inspect / retry
            }

            # Built. Stash the results for the Drill stage + report honestly.
            $c.BlankMade  = $true
            $c.BodyIndex  = $res.BodyIndex
            $c.BodyId     = $res.BodyId
            $c.BodyName   = $res.BodyName
            $offMsg = if ($res.OffsetHeld)    { "offset held at $standoff" } else { "offset NOT confirmed" }
            $thkMsg = if ($res.ThicknessHeld) { "thickness held at $thickness" } else { "thickness NOT confirmed (set it by hand in Creo if needed)" }
            $wiz.Log("  Conformal blank created. $offMsg; $thkMsg.")
            if ($null -ne $res.BodyIndex) {
                $wiz.Log(("  New blank body: '{0}' (index {1}, id {2})." -f $res.BodyName, $res.BodyIndex, $res.BodyId))
            } else {
                $wiz.Log("  (could not auto-identify the new body; the Drill stage will ask which body to drill.)")
            }
            $wiz.Log("  NOTE: dims re-read, NOT a geometric measurement of the curved slab. Verify the blank visually in Creo.")
            $chipState = if ($res.ThicknessHeld) { 'built' } else { 'unverified' }
            $wiz.SetChip('surface', 'surface: blank built', $chipState)
            $wiz.MarkCommitted()
            return $true
        }
    [void]$Steps.Add($runStep)
}
