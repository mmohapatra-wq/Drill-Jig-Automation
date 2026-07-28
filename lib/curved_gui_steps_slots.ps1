# ============================================================================
# lib\curved_gui_steps_slots.ps1 - the SLOTS (chip-relief) step group for the
# INPUT-FIRST curved drill jig wizard GUI (drilljig3d-gui.cmd), Stage 'Slots'.
# ============================================================================
# Defines ONE global function, Add-CurvedSlotSteps -Steps <ArrayList>, appending
# TWO steps (Stage 'Slots') that run AFTER the hands-free STAGE-4 Build:
#
#   1. slot-select (pick) - the operator Ctrl-clicks ALL the fastener COMPONENTS
#      again so we capture a FRESH IpfcComponentPath per fastener. The STAGE-1
#      selection's path went stale across the whole build (the documented staleness
#      -- the widened select->fire gap), so relief RE-SELECTS here to get live paths
#      for the TOP-plane sketch. Stored in $ctx.ReliefComponents (a SEPARATE field
#      from $ctx.FastenerComponents so the drill record is never clobbered).
#      SKIP-GATE: when relief is disabled (ReliefDepth <= 0) or no blank body was
#      built, the step is a pass-through (Validate returns $true, Build explains).
#   2. slot-loop (pick) - one 'Cut all relief pockets' button iterates
#      $ctx.ReliefComponents; per fastener it re-resolves the TOP plane fresh and
#      calls the PROVEN Invoke-FastenerRelief (curved_relief.ps1): arm a sketch on
#      that fastener's TOP plane -> operator draws ONE rectangle -> SYMMETRIC
#      remove-material extrude (typed depth = 2 x relief). Canary-gated per pocket;
#      tallies $ctx.ReliefsCut. This is this session's TOP-plane symmetric relief
#      engine reused VERBATIM -- only the CALL SITE moved out of the drill loop into
#      this terminal stage (operator decision: STAGE 4 hands-free, STAGE 5 draws).
#
# HARD RULES honored (repo house style):
#   * EDITS NOTHING existing -- only appends steps.
#   * `function global:` so the .cmd dot-source scope + any closure resolves it.
#   * A Build's Add_Click/OnVerify closure references ONLY its captured $c/$wiz +
#     captured LOCALS + GLOBAL functions -- never a runtime $script:X= write
#     ([[project_gui_scope_bugs]]). Invoke-FastenerRelief / Add-ComponentDefaultPlanesToBuffer
#     / Get-BufferComponentPath are all `function global:`.
#   * The loop click REBINDS COM handles from $c at its top (a bare $session read is
#     stale) and NEVER claims success on a canary miss
#     ([[feedback_canary_must_not_assume_on_failure]]).
#   * ID-only reads ($sel.Path.ComponentIds); never IpfcPoint.Point. ASCII-only.
#   * No $pid / read-only automatic assignments.
# ============================================================================

function global:Add-CurvedSlotSteps {
    param($Steps)

    # ========================================================================
    # STEP 1 - slot-select (pick): re-select the fasteners for FRESH TOP-plane paths.
    # ========================================================================
    $selStep = New-WizardStep -Key 'slot-select' -Title 'Select fasteners for chip relief' -Stage 'Slots' -Kind 'pick' -PrimaryText 'Continue' `
        -Validate {
            param($c)
            # skippable when relief is off or there is no blank body to cut into.
            $r = 0.0; try { if ($null -ne $c.ReliefDepth) { $r = [double]$c.ReliefDepth } } catch { $r = 0.0 }
            if ($r -le 0 -or $null -eq $c.BodyIndex) { return $true }
            $n = 0; try { if ($null -ne $c.ReliefComponents) { $n = @($c.ReliefComponents).Count } } catch { $n = 0 }
            return [bool]($n -ge 1)
        } `
        -Build {
            param($panel, $c, $wiz)
            $r = 0.0; try { if ($null -ne $c.ReliefDepth) { $r = [double]$c.ReliefDepth } } catch { $r = 0.0 }
            if ($r -le 0) {
                Add-Para $panel ("Chip relief is disabled (relief depth 0). Press Next to skip to the summary.") 8 0 'gray'
                return
            }
            if ($null -eq $c.BodyIndex) {
                Add-Para $panel ("No conformal blank body was built, so there is nothing to cut a relief pocket into. Press Next to skip (or go Back and build the blank).") 8 0 'yellow'
                return
            }
            $y = (Add-Para $panel ("Chip relief cuts a shallow SYMMETRIC pocket (2 x {0}`" = {1}`") on each fastener's TOP plane to clear chips. The fastener references from the Build stage have gone stale, so re-select the fasteners now for fresh references. In Creo (jig part ACTIVATED), Ctrl-click ALL the fastener COMPONENTS again, then click the verify button." -f $r, (2.0 * $r)) 8 0 $null).Bottom + 6
            $n = 0; try { if ($null -ne $c.ReliefComponents) { $n = @($c.ReliefComponents).Count } } catch { $n = 0 }
            if ($n -ge 1) {
                $y = (Add-Para $panel (("Captured {0} fastener(s) for relief. Re-verify to change the selection." -f $n)) $y 0 'green').Bottom + 6
            }
            $yb = (Add-ArmBanner $panel ("Ctrl-click every fastener component in Creo, then click 'I clicked it - verify'.") ($y + 4))
            Add-VerifyControls -Panel $panel -Context $c -Wizard $wiz -Top ($yb + 14) -OnVerify {
                param($Context, $Wizard)
                # read each selected COMPONENT via the proven $sel.Path channel (dedup on
                # ComponentIds), capturing a FRESH path. ID-only, never .Point. Stored in a
                # SEPARATE field (ReliefComponents) so the drill record is untouched.
                $buf = @()
                try { $buf = @(($Context.Session.CurrentSelectionBuffer()).Contents) } catch { $buf = @() }
                if (@($buf).Count -lt 1) { return @{ Ok = $false; Message = 'Nothing selected. Ctrl-click the fastener components and try again.' } }
                $comps = @()
                $seen = @{}
                foreach ($sel in $buf) {
                    $path = $null
                    try { $path = $sel.Path } catch { $path = $null }
                    if ($null -eq $path) { continue }
                    $ids = @()
                    try { $ids = @($path.ComponentIds) } catch { $ids = @() }
                    $key = ($ids -join '|')
                    if ([string]::IsNullOrEmpty($key) -or $seen.ContainsKey($key)) { continue }
                    $seen[$key] = $true
                    $origin = $null
                    try { $origin = Get-Comp (($path.GetTransform($true)).GetOrigin()) } catch { $origin = $null }
                    $comps += [pscustomobject]@{ Path = $path; CompIds = @($ids | ForEach-Object { [int]$_ }); Origin = $origin }
                }
                if (@($comps).Count -lt 1) {
                    return @{ Ok = $false; Message = 'No fastener COMPONENT read (the selection exposed no component path). Ctrl-click the fasteners themselves (not their planes/faces) and try again.' }
                }
                $Context.ReliefComponents = @($comps)
                return @{ Ok = $true; Message = ("Captured {0} fastener(s) for chip relief." -f @($comps).Count) }
            }
        } `
        -OnNext {
            param($c, $wiz)
            $r = 0.0; try { if ($null -ne $c.ReliefDepth) { $r = [double]$c.ReliefDepth } } catch { $r = 0.0 }
            if ($r -le 0 -or $null -eq $c.BodyIndex) { $wiz.SetChip('reliefs', 'relief: skipped', 'set'); return $true }
            $n = 0; try { if ($null -ne $c.ReliefComponents) { $n = @($c.ReliefComponents).Count } } catch { $n = 0 }
            if ($n -ge 1) { $wiz.SetChip('reliefsel', ("relief: {0} selected" -f $n), 'set') }
            return $true
        }
    [void]$Steps.Add($selStep)

    # ========================================================================
    # STEP 2 - slot-loop (pick): cut a symmetric relief pocket on each fastener's TOP plane.
    # ========================================================================
    $loopStep = New-WizardStep -Key 'slot-loop' -Title 'Cut the chip-relief pockets' -Stage 'Slots' -Kind 'pick' -PrimaryText 'Done - continue' `
        -Validate { param($c) return $true } `
        -Build {
            param($panel, $c, $wiz)
            $r = 0.0; try { if ($null -ne $c.ReliefDepth) { $r = [double]$c.ReliefDepth } } catch { $r = 0.0 }
            if ($r -le 0) {
                Add-Para $panel ("Chip relief is disabled (relief depth 0). Press Next to continue to the summary.") 8 0 'gray'
                return
            }
            if ($null -eq $c.BodyIndex) {
                Add-Para $panel ("No conformal blank body to cut into - chip relief is skipped. Press Next.") 8 0 'yellow'
                return
            }
            $made = 0; try { if ($null -ne $c.ReliefsCut) { $made = [int]$c.ReliefsCut } } catch { $made = 0 }
            $nComp = 0; try { if ($null -ne $c.ReliefComponents) { $nComp = @($c.ReliefComponents).Count } } catch { $nComp = 0 }
            if ($nComp -lt 1) {
                Add-Para $panel ("No fasteners captured for relief. Go Back one step and select the fastener components first.") 8 0 'yellow'
                return
            }
            $y = (Add-ArmBanner $panel ("Click 'Cut all relief pockets'. For each of the {0} fastener(s): Creo opens a sketch on that fastener's TOP plane - draw ONE rectangle over the hole and click OK, and it cuts a symmetric {1}`" pocket (2 x {2}`" relief). It advances to the next automatically." -f $nComp, (2.0 * $r), $r) 8)
            $y = (Add-Para $panel ("Relief pockets cut so far: {0}." -f $made) ($y + 10) 0 $(if ($made -ge 1) { 'green' } else { 'gray' })).Bottom + 6

            # ACTIVE-MODEL ADVISORY (dynamic; the remove-material cut needs the jig PART active).
            $activeNote = $null
            try {
                $am = $c.Session.GetActiveModel()
                $an = if ($null -ne $am) { [string]$am.FileName } else { '' }
                if ($an -match '(?i)\.asm(\.\d+)?$') {
                    $activeNote = ("Creo's ACTIVE model is the ASSEMBLY ('{0}'). Activate the drilljig PART (right-click it in the tree -> Activate) before cutting the relief pockets." -f $an)
                }
            } catch { $activeNote = $null }
            if ($activeNote) { $y = (Add-Para $panel $activeNote $y 0 'yellow').Bottom + 8 }
            else { $y = (Add-Para $panel ("The DRILLJIG PART must be ACTIVE in Creo. Each pocket straddles the TOP plane; verify the depth visually on the first one.") $y 0 'gray').Bottom + 8 }

            $thm = $script:WizTheme
            $accent = if ($thm) { $thm.Accent } else { [System.Drawing.Color]::FromArgb(64,132,232) }
            $okCol  = Get-UiColor 'green'
            $errCol = Get-UiColor 'red'
            $warnCol = Get-UiColor 'yellow'

            $result = New-Object System.Windows.Forms.Label
            $result.AutoSize    = $true
            $result.MaximumSize = New-Object System.Drawing.Size(([Math]::Max(80, $panel.Width - 8 - 26)), 0)
            $result.Location    = New-Object System.Drawing.Point(8, ($y + 44))
            $result.Font        = New-Object System.Drawing.Font('Segoe UI', 10)
            $result.ForeColor   = Get-UiColor ''
            $result.BackColor   = [System.Drawing.Color]::Transparent
            $panel.Controls.Add($result)

            $btn = New-Object System.Windows.Forms.Button
            $btn.Text     = 'Cut all relief pockets'
            $btn.Size     = New-Object System.Drawing.Size(220, 36)
            $btn.Location = New-Object System.Drawing.Point(8, $y)
            $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            $btn.FlatAppearance.BorderSize = 0
            $btn.BackColor = $accent
            $btn.ForeColor = [System.Drawing.Color]::White
            $btn.Font      = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
            $panel.Controls.Add($btn)

            $btn.Add_Click({
                $old = $ErrorActionPreference
                try {
                    $ErrorActionPreference = 'Continue'
                    $btn.Enabled = $false
                    try {
                        # REBIND COM from $c (a bare $session read is stale).
                        $session = $c.Session; $model = $c.Model; $pfcType = $c.Type
                        if ($null -eq $session -or $null -eq $model) {
                            $result.ForeColor = $errCol; $result.Text = 'No live Creo session. Cannot cut relief.'; return
                        }
                        $rd = 0.0
                        try { if ($null -ne $c.ReliefDepth) { $rd = [double]$c.ReliefDepth } } catch { $rd = 0.0 }
                        if ($rd -le 0) { $result.ForeColor = $errCol; $result.Text = 'Chip relief is disabled (relief depth 0).'; return }
                        $bodyIx = $null
                        try { if ($null -ne $c.BodyIndex) { $bodyIx = [int]$c.BodyIndex } } catch { $bodyIx = $null }
                        if ($null -eq $bodyIx) { $result.ForeColor = $errCol; $result.Text = 'No blank body to cut into - relief skipped.'; return }
                        $comps = @()
                        try { if ($null -ne $c.ReliefComponents) { $comps = @($c.ReliefComponents) } } catch { $comps = @() }
                        if (@($comps).Count -lt 1) {
                            $result.ForeColor = $errCol; $result.Text = 'No fasteners captured. Go Back and select the fastener components.'; return
                        }

                        # ACTIVE-MODEL GATE: the remove-material cut needs the jig PART active.
                        $activeName = ''
                        try { $am = $session.GetActiveModel(); if ($null -ne $am) { $activeName = [string]$am.FileName } } catch { $activeName = '' }
                        if ($activeName -match '(?i)\.asm(\.\d+)?$') {
                            $result.ForeColor = $errCol
                            $result.Text = ("Creo's ACTIVE model is the assembly ('{0}'), not the drilljig part. Activate the drilljig PART, then click 'Cut all relief pockets' again." -f $activeName)
                            [void]$wiz.AskInline('Activate the drilljig part',
                                ("The active model is the assembly ('" + $activeName + "'). Right-click the DRILLJIG PART in the Creo tree -> Activate, then click OK and press 'Cut all relief pockets' again."),
                                'OK', $true)
                            return
                        }

                        $poll = { try { [System.Windows.Forms.Application]::DoEvents() } catch {} }
                        $cut = 0; $fail = 0
                        $ci = 0
                        foreach ($comp in $comps) {
                            $ci++
                            # FRESH component path for the TOP-plane sketch feed. Re-buffer the planes
                            # from the stored $comp.Path (just re-selected this stage, so live) then read
                            # a fresh path from the buffer; default to $comp.Path on a miss.
                            $reliefPath = $comp.Path
                            try { [void](Add-ComponentDefaultPlanesToBuffer -Session $session -Model $model -TypeObj $pfcType -ComponentPath $comp.Path) } catch {}
                            $fp = $null; try { $fp = Get-BufferComponentPath -Session $session } catch { $fp = $null }
                            if ($null -ne $fp) { $reliefPath = $fp }

                            # DrawPrompt: pause for the operator to draw the rectangle (NoActivate).
                            $drawPrompt = {
                                [void]$wiz.AskInline('Draw the relief pocket',
                                    ("Fastener {0}: draw the rectangle over the hole on the sketch Creo just opened, leave the sketch OPEN, then click OK. The tool cuts a symmetric chip-relief pocket." -f $ci),
                                    'OK', $true)
                            }.GetNewClosure()
                            # PlanePrompt: operator fallback if the by-ID TOP-plane pre-select misses.
                            $planePrompt = {
                                [void]$wiz.AskInline('Pick the TOP plane',
                                    ("Fastener {0}: the automatic TOP-plane pick for the relief sketch did not take. In Creo, click THIS fastener's TOP datum plane (the sketch plane), then click OK." -f $ci),
                                    'OK', $true)
                            }.GetNewClosure()

                            $rr = $null
                            try { $rr = Invoke-FastenerRelief -Session $session -Model $model -TypeObj $pfcType -ComponentPath $reliefPath -TopPlaneId 1 -ReliefDepth $rd -BodyIndex $bodyIx -DrawPrompt $drawPrompt -PlanePrompt $planePrompt -OnPoll $poll } catch { $rr = $null }
                            if ($null -ne $rr -and $rr.Cut) {
                                $cut++
                                if ($null -eq $c.ReliefsCut) { $c.ReliefsCut = 0 }
                                $c.ReliefsCut = [int]$c.ReliefsCut + 1
                                $result.ForeColor = $okCol
                                $result.Text = ("+ relief pocket {0}/{1} cut (total {2}). Verify visually." -f $ci, @($comps).Count, [int]$c.ReliefsCut)
                                $wiz.SetChip('reliefs', ("relief pockets: {0}" -f [int]$c.ReliefsCut), 'built')
                            } else {
                                $fail++
                                $result.ForeColor = $warnCol
                                $result.Text = ("Fastener {0}: the relief pocket did not cut (model unchanged) - skipped. Inspect Creo." -f $ci)
                            }

                            # PER-ITERATION SAFETY-CLOSE (matches the drill loop): guarantee a fresh
                            # dashboard for the next fastener; harmless no-op when none is open.
                            try { $session.RunMacro("~ Enter ``main_dlg_cur`` ``dashInst0.Quit``;~ Exit ``main_dlg_cur`` ``dashInst0.Quit``;~ Activate ``main_dlg_cur`` ``dashInst0.Done``;") } catch {}
                            try { $wiz.Pump() } catch {}
                        }

                        if ($cut -gt 0) { $wiz.MarkCommitted() }
                        $summ = ("Done: {0} relief pocket(s) cut" -f $cut)
                        if ($fail -gt 0) { $summ += ("; {0} missed - re-run to retry them" -f $fail) }
                        $result.ForeColor = if ($fail -eq 0 -and $cut -ge 1) { $okCol } elseif ($cut -ge 1) { $warnCol } else { $errCol }
                        $result.Text = $summ
                        try { $wiz.Rerender() } catch {}
                    } finally { $btn.Enabled = $true }
                } catch {
                    try { $wiz.LogError($_, 'slot loop click') } catch {}
                } finally { $ErrorActionPreference = $old }
            }.GetNewClosure())
        } `
        -OnNext {
            param($c, $wiz)
            $made = 0
            try { if ($null -ne $c.ReliefsCut) { $made = [int]$c.ReliefsCut } } catch { $made = 0 }
            if ($made -ge 1) { $wiz.SetChip('reliefs', ("relief pockets: {0}" -f $made), 'built') }
            return $true
        }
    [void]$Steps.Add($loopStep)
}
