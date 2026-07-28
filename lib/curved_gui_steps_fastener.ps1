# ============================================================================
# lib\curved_gui_steps_fastener.ps1 - the FASTENERS step group for the CURVED
# drill jig wizard GUI (drilljig3d-gui.cmd). The `dumbclaude` workflow, integrated,
# with the HANDS-FREE by-ID fastener loop (user 2026-07-27).
# ============================================================================
# Defines ONE global function, Add-CurvedFastenerHoleSteps -Steps <ArrayList>,
# appending the fastener-plane hole steps (Stage 'Fasteners'). In the top-down
# assembly with the jig part ACTIVATED, the operator selects ALL fastener COMPONENTS
# ONCE; the tool then loops each fastener and does it all by ID: resolve that
# fastener's own default TOP/SIDE/FRONT datum planes (Add-ComponentDefaultPlanesToBuffer),
# create a datum POINT at their intersection (ProCmdDatumPointGeneral), build a TANGENT
# plane at the point (its normal IS the surface normal), and drill a hole placed BY
# REFERENCE (the point) + DIRECTION (that tangent plane fed by ID) NORMAL to the curved
# surface, thru all, into the blank body. Engine + verbatim macro tokens:
# lib\curved_fastener_hole.ps1 + lib\tangent_plane.ps1.
#
# HANDS-FREE + FALLBACK (user: "when the user selects the fasteners, you can go through
# 1 by 1 and do it all yourself"): the by-ID path (Add-ComponentDefaultPlanesToBuffer, a
# path-qualified component-subitem selection) is CONFIRMED LIVE (fastenerplane-probe.cmd
# SECTION 3, 2026-07-28: select ONE fastener component -> resolved its 1/3/5 planes by ID +
# path -> ProCmdDatumPointGeneral built the point id 959, correct location; the manual path
# built id 957 at the same place). So the by-ID path is PRIMARY and normally runs fully
# hands-free from the single fastener-component selection. It is still canary-gated at every
# mutation, and on ANY miss (planes not path-qualified, point not created -- e.g. a non-default
# fastener) the loop FALLS BACK to the proven MANUAL per-fastener flow: an AskInline pause
# (NoActivate) for the operator to Ctrl-click that fastener's 3 planes, then the SAME
# point/tangent/hole path. The by-ID path NEVER replaces manual -> worst case is exactly the
# old behavior, best case (the normal case now) is fully hands-free. No regression.
#
# The hole is HANDS-FREE too: an ON-POINT hole (placed on the datum point) ORIENTED to the
# fastener's OWN TOP plane (id 1) -> the drill axis is NORMAL to the jig (operator-confirmed),
# matching the operator's recording (2026-07-28). Invoke-FastenerHole feeds that TOP plane BY
# ID (path-qualified, Clear = REPLACE ft_dir's auto-default) into the ft_dir collector -- no
# screen pick, no tangent plane. CONFIRMED LIVE (onpointhole-probe.cmd 2026-07-28: point 1291
# -> on-point hole, TOP plane the sole ft_dir ref). If that ever misses, the loop falls back
# to an operator DIRECTION-pick pause (injected AskInline) between the open + finish macros.
#
# STEPS:
#   1. fastener-dia    (info) - inline textbox for the hole/seat diameter, pre-filled
#      from $ctx.HoleDiaFinal (bushing OD). -> $ctx.FastenerHoleDia (+ *Valid).
#   2. fastener-select (pick) - operator Ctrl-clicks ALL fastener COMPONENTS once; verify
#      reads each $sel.Path (the proven component channel) into $ctx.FastenerComponents,
#      dedup on ComponentIds. Also fixes the curved surface for tangent planes
#      ($ctx.FastenerSurfId, default $ctx.SurfIds[0]).
#   3. fastener-loop   (pick) - one 'Drill all fasteners' button iterates the captured
#      components: by-ID auto (planes -> point -> tangent plane -> hole) with the manual
#      3-plane fallback; tallies $ctx.FastenerHolesMade + $ctx.CurvedHolePairs.
#
# HARD RULES honored (repo house style):
#   * EDITS NOTHING existing -- only appends steps.
#   * `function global:` so the .cmd dot-source scope + any closure resolves it.
#   * A Build's Add_Click closure (.GetNewClosure) references ONLY its captured $c/$wiz
#     + captured LOCALS (precomputed colors, the button, the result label) + GLOBAL
#     functions -- never a runtime $script:X= write ([[project_gui_scope_bugs]]).
#   * The loop click REBINDS COM handles from $c at its top (a bare $session read is
#     stale) and NEVER claims success on a canary miss
#     ([[feedback_canary_must_not_assume_on_failure]]).
#   * ID-only reads (Resolve-SelectedPlaneIds / Resolve-NewDatumPointIds /
#     Get-FeatureIdSet; the component read is $sel.Path.ComponentIds); never
#     IpfcPoint.Point. Orientation is by tangent plane (plane normals read null, so it
#     is not verified programmatically -- a VISUAL check). ASCII-only labels.
#   * No $pid / read-only automatic assignments.
# ============================================================================

function global:Add-CurvedFastenerHoleSteps {
    param($Steps)

    # ========================================================================
    # STEP 1 - fastener-dia (info): hole/seat diameter.
    # ========================================================================
    $diaStep = New-WizardStep -Key 'fastener-dia' -Title 'Fastener hole diameter' -Stage 'Conditions' -Kind 'info' -PrimaryText 'Next' `
        -Validate { param($c) return [bool]$c.FastenerHoleDiaValid } `
        -Build {
            param($panel, $c, $wiz)
            $prefill = $null
            try { if ($null -ne $c.HoleDiaFinal) { $prefill = [double]$c.HoleDiaFinal } } catch {}
            if ($null -eq $prefill) { try { if ($null -ne $c.HoleDia) { $prefill = [double]$c.HoleDia } } catch {} }
            $startVal = $null
            try { if ($null -ne $c.FastenerHoleDia) { $startVal = [double]$c.FastenerHoleDia } } catch {}
            if ($null -eq $startVal) { $startVal = $prefill }

            $y = (Add-Para $panel ("Each fastener hole is drilled at this diameter, thru all, NORMAL to the curved surface, into the conformal blank. Enter the hole / bushing-seat diameter (inches).") 8 0 $null).Bottom + 8
            if ($null -ne $prefill) {
                $y = (Add-Para $panel ("Pre-filled from the resolved bushing OD ({0})." -f $prefill) $y 0 'gray').Bottom + 8
            }
            if (-not $c.BlankMade) {
                $y = (Add-Para $panel ("NOTE: no conformal blank has been built yet. Build it in the Surface stage first - the holes drill into that body.") $y 0 'yellow').Bottom + 8
            }

            $lab = New-Object System.Windows.Forms.Label
            $lab.Text = 'Diameter (in):'
            $lab.Location = New-Object System.Drawing.Point(8, ($y + 3))
            $lab.Size = New-Object System.Drawing.Size(120, 20)
            $lab.ForeColor = Get-UiColor ''
            $lab.BackColor = [System.Drawing.Color]::Transparent
            $panel.Controls.Add($lab)

            $tb = New-Object System.Windows.Forms.TextBox
            $tb.Location = New-Object System.Drawing.Point(132, $y)
            $tb.Size = New-Object System.Drawing.Size(90, 24)
            $tb.BackColor = [System.Drawing.Color]::FromArgb(16,24,42)
            $tb.ForeColor = Get-UiColor ''
            $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
            $tb.Text = if ($null -ne $startVal) { ('{0}' -f $startVal) } else { '' }
            $panel.Controls.Add($tb)

            $lblEcho = New-Object System.Windows.Forms.Label
            $lblEcho.AutoSize = $true
            $lblEcho.MaximumSize = New-Object System.Drawing.Size(560, 0)
            $lblEcho.Location = New-Object System.Drawing.Point(8, ($y + 34))
            $lblEcho.BackColor = [System.Drawing.Color]::Transparent
            $panel.Controls.Add($lblEcho)

            $okCol   = Get-UiColor 'green'
            $warnCol = Get-UiColor 'yellow'
            $updateEcho = {
                $raw = ''
                try { $raw = [string]$tb.Text } catch { $raw = '' }
                $d = 0.0
                $ok = ([double]::TryParse(($raw.Trim()), [ref]$d) -and $d -gt 0)
                if ($ok) {
                    $c.FastenerHoleDia = [double]$d
                    $c.FastenerHoleDiaValid = $true
                    $lblEcho.ForeColor = $okCol
                    $lblEcho.Text = ("Hole diameter {0} (thru all, normal to surface)." -f [double]$d)
                    $wiz.SetChip('fastdia', ('dia {0}' -f [double]$d), 'set')
                } else {
                    $c.FastenerHoleDiaValid = $false
                    $lblEcho.ForeColor = $warnCol
                    $lblEcho.Text = 'Enter a positive number.'
                }
                try { $wiz.Refresh() } catch {}
            }.GetNewClosure()
            $tb.Add_TextChanged({ param($s,$e) & $updateEcho }.GetNewClosure())
            & $updateEcho
        } `
        -OnNext {
            param($c, $wiz)
            if (-not $c.FastenerHoleDiaValid) { return $false }
            return $true
        }
    [void]$Steps.Add($diaStep)

    # ========================================================================
    # STEP 2 - fastener-select (pick): select ALL fastener components ONCE.
    # ========================================================================
    $selStep = New-WizardStep -Key 'fastener-select' -Title 'Select the fasteners' -Stage 'Fasteners' -Kind 'pick' -PrimaryText 'Continue' `
        -Validate {
            param($c)
            $n = 0
            try { if ($null -ne $c.FastenerComponents) { $n = @($c.FastenerComponents).Count } } catch { $n = 0 }
            return [bool]($n -ge 1)
        } `
        -Build {
            param($panel, $c, $wiz)
            $y = (Add-Para $panel ("This is the FIRST input step: tell the tool which fasteners to drill. In Creo (jig part ACTIVATED in the assembly), Ctrl-click ALL the fastener COMPONENTS you want drilled - select the fasteners themselves (one click each), NOT their planes. Then click the verify button. The Build stage later drills every hole for you.") 8 0 $null).Bottom + 6
            $n = 0
            try { if ($null -ne $c.FastenerComponents) { $n = @($c.FastenerComponents).Count } } catch { $n = 0 }
            if ($n -ge 1) {
                $y = (Add-Para $panel (("Captured {0} fastener(s). Re-verify to change the selection." -f $n)) $y 0 'green').Bottom + 6
            }
            $y = (Add-Para $panel ("Each hole is drilled ON its datum point and oriented to that fastener's own TOP plane, so the drill axis is normal to the jig. You pick the surface to follow on the next step.") $y 0 'gray').Bottom + 6
            $yb = (Add-ArmBanner $panel ("Ctrl-click every fastener component in Creo, then click 'I clicked it - verify'.") ($y + 4))
            Add-VerifyControls -Panel $panel -Context $c -Wizard $wiz -Top ($yb + 14) -OnVerify {
                param($Context, $Wizard)
                # read each selected COMPONENT via the proven $sel.Path channel (dedup on
                # ComponentIds); ID-only, never .Point. Store paths for the loop step.
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
                $Context.FastenerComponents = @($comps)
                # NOTE: FastenerSurfId is defaulted in the Surface stage (surface-arm), not here --
                # the surface is picked AFTER the fasteners in the input-first flow.
                return @{ Ok = $true; Message = ("Captured {0} fastener(s)." -f @($comps).Count) }
            }
        } `
        -OnNext {
            param($c, $wiz)
            $n = 0
            try { if ($null -ne $c.FastenerComponents) { $n = @($c.FastenerComponents).Count } } catch { $n = 0 }
            if ($n -ge 1) { $wiz.SetChip('fasteners', ("fasteners: {0} selected" -f $n), 'set') }
            return $true
        }
    [void]$Steps.Add($selStep)

}
