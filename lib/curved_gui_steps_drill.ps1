# ============================================================================
# lib\curved_gui_steps_drill.ps1 - the DRILL step group for the CURVED drill
# jig wizard GUI (drilljig3d-gui.cmd).
# ============================================================================
# Defines ONE global function, Add-CurvedDrillSteps -Steps <ArrayList>, that
# appends FOUR wizard steps (all built via New-WizardStep, appended with
# [void]$Steps.Add(...)):
#
#   1. drill-mode        (Stage 'Drill', choice) - one surface for ALL holes
#      (fast) vs per-hole surface (curved/multi-face). Sets $ctx.DrillPerHole.
#   2. drill-arm-points  (Stage 'Drill', pick  ) - ARM the datum-point pick(s)
#      and build $ctx.HolePairs = @({PointId;SurfaceId;TangentPlaneId=0}). Mode 1
#      is ONE multi-pick (arm + verify); mode 2 loops one point+surface pair at a
#      time via AskInline (mirrors drilljig3d.cmd STAGE 2 per-hole mode).
#   3. drill-diameter    (Stage 'Drill', info  ) - inline textbox for the hole /
#      seat diameter, pre-filled from $ctx.HoleDiaFinal (or HoleDia); validates a
#      positive number into $ctx.HoleDiaDrill (+ $ctx.HoleDiaDrillValid).
#   4. drill-run         (Stage 'Drill', run   ) - the drill loop: per hole build
#      a TANGENT PLANE at (point, surface) for the orientation reference (canary-
#      gated; fall back to the surface id on a miss), fire Build-NormalHoleMacro,
#      Wait-ModelModified canary-gated on hole #1. Tally + honesty chip; stash
#      $ctx.HolesMade / $ctx.CurvedHolePairs / $ctx.CurvedHoleDiaFinal for Relief.
#
# HARD RULES honored (repo house style):
#   * This file EDITS NOTHING existing -- it only appends steps.
#   * `function global:` on Add-CurvedDrillSteps so the .cmd's dot-source scope
#     (a [scriptblock]::Create body) can call it AND so any closure resolves it.
#   * Build/Validate/OnNext handed to New-WizardStep are plain {param(...)} blocks
#     (the framework stores + invokes them, so no .GetNewClosure() is needed).
#   * A button/OnPick Add_Click handler attached inside a Build IS .GetNewClosure()
#     and references ONLY its params + $ctx + GLOBAL functions (the closure-scope
#     rule -- a Build-local var is invisible to a closure; state lives in $ctx).
#     Colors used inside such a closure are precomputed in Build + captured.
#   * RUN steps REBIND the COM handles from $ctx at the top of OnNext (a bare
#     $session read can be stale -- [[project_gui_scope_bugs]]), and NEVER claim
#     success on a canary miss (hole #1 must change the model or the loop aborts;
#     [[feedback_canary_must_not_assume_on_failure]]).
#   * ID-only throughout -- Resolve-SelectedPoints / Resolve-SelectedSurfaces are
#     ID-only buffer reads; never IpfcPoint.Point.
#   * ASCII-only Write-Host / labels.
# ============================================================================

function global:Add-CurvedDrillSteps {
    param($Steps)

    # ========================================================================
    # STEP 1 - drill-mode (choice): one surface for ALL holes vs per-hole
    # ========================================================================
    $modeStep = New-WizardStep -Key 'drill-mode' -Title 'Orientation surface' -Stage 'Drill' -Kind 'choice' -PrimaryText 'Next' `
        -Validate { param($c) return $true } `
        -Build {
            param($panel, $c, $wiz)
            # A blank must exist before we can drill into it (defence in depth -- the
            # step order guarantees this, but say so if somehow reached first).
            if (-not $c.BlankMade) {
                Add-Para $panel ("No conformal blank has been built yet. Go Back and build the blank in the Surface stage before drilling.") 8 0 'yellow'
                return
            }
            $y = (Add-Para $panel ("Each hole is drilled On-Point NORMAL to the curved surface. Choose how the orientation surface is picked:") 8 0 $null).Bottom + 10

            # honest note about tangent orientation.
            if ($c.DefaultOrient) {
                $y = (Add-Para $panel ("Orientation: Creo's DEFAULT On-Point direction (--default-orient) - the surface choice below is not used for orientation, only for the record.") $y 0 'gray').Bottom + 8
            } else {
                $y = (Add-Para $panel ("Orientation: a TANGENT PLANE is built at each hole's (point, surface) so the bore is normal-to-surface by construction; the tangent plane also hosts the chip-relief slot sketch.") $y 0 'gray').Bottom + 8
            }

            $s0 = 0
            try { if ($null -ne $c.SurfIds -and @($c.SurfIds).Count -ge 1) { $s0 = [int]@($c.SurfIds)[0] } } catch { $s0 = 0 }
            $sub1 = if ($s0 -gt 0) { ("Fast: every hole shares the surface picked in the Surface stage (id {0})." -f $s0) } else { "Fast: every hole shares the surface picked in the Surface stage." }
            $opts = @(
                @{ Title = '[1] One surface for ALL holes'; Subtitle = $sub1 },
                @{ Title = '[2] Per-hole surface';          Subtitle = 'Curved/multi-face: pick each point WITH the surface it sits on.' }
            )
            # HighlightIndex reflects the current $c.DrillPerHole so the operator sees
            # which mode is active on a revisit.
            $hi = if ($c.DrillPerHole) { 1 } else { 0 }
            Add-WizardChoiceCards -Panel $panel -Options $opts -Context $c -Wizard $wiz -Top ($y + 4) -CardWidth 250 -CardHeight 96 -AfterPick 'rerender' -HighlightIndex $hi -OnPick {
                param($i, $opt, $cc, $w)
                $cc.DrillPerHole = ($i -eq 1)
                if ($cc.DrillPerHole) { $w.SetChip('drillmode', 'drill: per-hole surface', 'set') }
                else                  { $w.SetChip('drillmode', 'drill: one surface', 'set') }
            }
        } `
        -OnNext {
            param($c, $wiz)
            # A default of mode 1 is fine if none picked.
            if ($null -eq $c.DrillPerHole) { $c.DrillPerHole = $false }
            return $true
        }
    [void]$Steps.Add($modeStep)

    # ========================================================================
    # STEP 2 - drill-arm-points (pick): build $ctx.HolePairs
    # ========================================================================
    # Each pair is a pscustomobject with PointId / SurfaceId / TangentPlaneId=0.
    # TangentPlaneId is present + mutable so the run step can set it in place after
    # building the tangent plane (the Relief stage reads $p.TangentPlaneId).
    $armStep = New-WizardStep -Key 'drill-arm-points' -Title 'Target datum points' -Stage 'Drill' -Kind 'pick' -PrimaryText 'Continue' `
        -Validate {
            param($c)
            $n = 0
            try { if ($null -ne $c.HolePairs) { $n = @($c.HolePairs).Count } } catch { $n = 0 }
            return [bool]($n -ge 1)
        } `
        -Build {
            param($panel, $c, $wiz)
            if ($c.DrillPerHole) {
                # ---- MODE 2: per-hole loop (Ctrl-click point + its surface, one at a time) ----
                $y = (Add-ArmBanner $panel ("Per-hole mode: in Creo, Ctrl-click ONE datum point AND the surface it sits on, then click 'Add this hole'. Repeat for every hole; click 'Done adding' when finished.") 8)
                $n = 0
                try { if ($null -ne $c.HolePairs) { $n = @($c.HolePairs).Count } } catch { $n = 0 }
                $y = (Add-Para $panel ("Holes captured so far: {0}." -f $n) ($y + 10) 0 $(if ($n -ge 1) { 'green' } else { 'gray' })).Bottom + 10

                $thm = $script:WizTheme
                $accent = if ($thm) { $thm.Accent } else { [System.Drawing.Color]::FromArgb(64,132,232) }
                $okCol  = Get-UiColor 'green'
                $errCol = Get-UiColor 'red'

                $result = New-Object System.Windows.Forms.Label
                $result.AutoSize    = $true
                $result.MaximumSize = New-Object System.Drawing.Size(([Math]::Max(80, $panel.Width - 8 - 26)), 0)
                $result.Location    = New-Object System.Drawing.Point(8, ($y + 44))
                $result.Font        = New-Object System.Drawing.Font('Segoe UI', 10)
                $result.ForeColor   = Get-UiColor ''
                $result.BackColor   = [System.Drawing.Color]::Transparent
                $panel.Controls.Add($result)

                # "Add this hole" - read the buffer, require exactly 1 point + >=1 surface,
                # append the pair to $c.HolePairs, then rerender so the running count updates.
                $btnAdd = New-Object System.Windows.Forms.Button
                $btnAdd.Text     = 'Add this hole'
                $btnAdd.Size     = New-Object System.Drawing.Size(180, 36)
                $btnAdd.Location = New-Object System.Drawing.Point(8, $y)
                $btnAdd.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
                $btnAdd.FlatAppearance.BorderSize = 0
                $btnAdd.BackColor = $accent
                $btnAdd.ForeColor = [System.Drawing.Color]::White
                $btnAdd.Font      = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
                $panel.Controls.Add($btnAdd)
                $btnAdd.Add_Click({
                    $old = $ErrorActionPreference
                    try {
                        $ErrorActionPreference = 'Continue'
                        $pp = @(); $ss = @()
                        try { $pp = @((Resolve-SelectedPoints   -Session $c.Session -TypeObj $c.Type).Points) } catch { $pp = @() }
                        try { $ss = @((Resolve-SelectedSurfaces -Session $c.Session -TypeObj $c.Type).Surfaces) } catch { $ss = @() }
                        if (@($pp).Count -ne 1 -or @($ss).Count -lt 1) {
                            $result.ForeColor = $errCol
                            $result.Text = ("Need exactly ONE datum point AND its surface selected (got {0} point / {1} surface). Try again." -f @($pp).Count, @($ss).Count)
                            return
                        }
                        if ($null -eq $c.HolePairs) { $c.HolePairs = @() }
                        $c.HolePairs = @($c.HolePairs) + @([pscustomobject]@{ PointId = [int]$pp[0]; SurfaceId = [int]$ss[0]; TangentPlaneId = 0 })
                        $result.ForeColor = $okCol
                        $result.Text = ("+ hole {0}: point {1} normal to surface {2}." -f @($c.HolePairs).Count, [int]$pp[0], [int]$ss[0])
                        try { $wiz.Rerender() } catch {}
                    } catch {
                        try { $wiz.LogError($_, 'drill add-hole click') } catch {}
                    } finally { $ErrorActionPreference = $old }
                }.GetNewClosure())

                # "Remove last" - undo the most recent capture (in case of a mis-pick).
                $btnUndo = New-Object System.Windows.Forms.Button
                $btnUndo.Text     = 'Remove last'
                $btnUndo.Size     = New-Object System.Drawing.Size(130, 36)
                $btnUndo.Location = New-Object System.Drawing.Point(196, $y)
                $btnUndo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
                $btnUndo.FlatAppearance.BorderSize  = 1
                $btnUndo.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(120,170,255)
                $btnUndo.BackColor = if ($thm) { $thm.CardBack } else { [System.Drawing.Color]::FromArgb(40,54,84) }
                $btnUndo.ForeColor = [System.Drawing.Color]::White
                $panel.Controls.Add($btnUndo)
                $btnUndo.Add_Click({
                    $old = $ErrorActionPreference
                    try {
                        $ErrorActionPreference = 'Continue'
                        $cur = @()
                        try { if ($null -ne $c.HolePairs) { $cur = @($c.HolePairs) } } catch { $cur = @() }
                        if ($cur.Count -ge 1) {
                            $c.HolePairs = @($cur[0..($cur.Count - 2)])
                            if ($cur.Count -eq 1) { $c.HolePairs = @() }
                        }
                        try { $wiz.Rerender() } catch {}
                    } catch {
                        try { $wiz.LogError($_, 'drill remove-last click') } catch {}
                    } finally { $ErrorActionPreference = $old }
                }.GetNewClosure())
            } else {
                # ---- MODE 1: one multi-pick of all points (arm + verify) ----
                $y = (Add-ArmBanner $panel ("In Creo, select ALL the target datum points on the blank, then click the verify button below.") 8)
                # $OnVerify reads Resolve-SelectedPoints and builds $ctx.HolePairs, each
                # point -> {PointId; SurfaceId=the STAGE-1 surface; TangentPlaneId=0}.
                Add-VerifyControls -Panel $panel -Context $c -Wizard $wiz -Top ($y + 14) -OnVerify {
                    param($Context, $Wizard)
                    $pres = $null
                    try { $pres = Resolve-SelectedPoints -Session $Context.Session -TypeObj $Context.Type } catch { $pres = $null }
                    if ($null -eq $pres) { return @{ Ok = $false; Message = 'Could not read the selection buffer.' } }
                    $pts = @($pres.Points)
                    if ($pts.Count -lt 1) {
                        $rej = 0
                        try { $rej = @($pres.Rejected).Count } catch { $rej = 0 }
                        $extra = if ($rej -gt 0) { (" ({0} non-point selection(s) ignored)" -f $rej) } else { '' }
                        return @{ Ok = $false; Message = ("No datum points read from the selection" + $extra + ". Select the target points in Creo and try again.") }
                    }
                    # the shared orientation surface = the STAGE-1 surface (SurfIds[0]).
                    $os = 0
                    try { if ($null -ne $Context.SurfIds -and @($Context.SurfIds).Count -ge 1) { $os = [int]@($Context.SurfIds)[0] } } catch { $os = 0 }
                    $pairs = @()
                    foreach ($p in $pts) { $pairs += [pscustomobject]@{ PointId = [int]$p; SurfaceId = [int]$os; TangentPlaneId = 0 } }
                    $Context.HolePairs = @($pairs)
                    $msg = ("Read {0} datum point(s)." -f $pts.Count)
                    try { if (@($pres.Rejected).Count -gt 0) { $msg += (" ({0} non-point selection(s) ignored.)" -f @($pres.Rejected).Count) } } catch {}
                    return @{ Ok = $true; Message = $msg }
                }
            }
        } `
        -OnNext {
            param($c, $wiz)
            $n = 0
            try { if ($null -ne $c.HolePairs) { $n = @($c.HolePairs).Count } } catch { $n = 0 }
            if ($n -lt 1) { return $false }
            $wiz.SetChip('holes', ("holes: {0} armed" -f $n), 'set')
            return $true
        }
    [void]$Steps.Add($armStep)

    # ========================================================================
    # STEP 3 - drill-diameter (info): inline textbox for the hole/seat diameter
    # ========================================================================
    $diaStep = New-WizardStep -Key 'drill-diameter' -Title 'Hole diameter' -Stage 'Drill' -Kind 'info' -PrimaryText 'Next' `
        -Validate { param($c) return [bool]$c.HoleDiaDrillValid } `
        -Build {
            param($panel, $c, $wiz)
            # pre-fill from the resolved bushing OD (HoleDiaFinal) or HoleDia; default the
            # textbox to whatever HoleDiaDrill already holds (a revisit) else the pre-fill.
            $prefill = $null
            try { if ($null -ne $c.HoleDiaFinal) { $prefill = [double]$c.HoleDiaFinal } } catch {}
            if ($null -eq $prefill) { try { if ($null -ne $c.HoleDia) { $prefill = [double]$c.HoleDia } } catch {} }
            $startVal = $null
            try { if ($null -ne $c.HoleDiaDrill) { $startVal = [double]$c.HoleDiaDrill } } catch {}
            if ($null -eq $startVal) { $startVal = $prefill }

            $y = (Add-Para $panel ("Enter the hole / bushing-seat diameter to drill (inches). Every armed hole is drilled at this diameter, thru all.") 8 0 $null).Bottom + 8
            if ($null -ne $prefill) {
                $y = (Add-Para $panel ("Pre-filled from the resolved bushing OD ({0})." -f $prefill) $y 0 'gray').Bottom + 8
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

            # Precompute the echo colors HERE (a Build body resolves script-local functions)
            # and CAPTURE them in the closure. Only $c + captured locals + globals are read
            # inside the TextChanged closure (the closure-scope rule). $wiz is a param of the
            # Build block and is captured by the closure too.
            $okCol   = Get-UiColor 'green'
            $warnCol = Get-UiColor 'warn'
            $updateEcho = {
                $raw = ''
                try { $raw = [string]$tb.Text } catch { $raw = '' }
                $d = 0.0
                $ok = ([double]::TryParse(($raw.Trim()), [ref]$d) -and $d -gt 0)
                if ($ok) {
                    $c.HoleDiaDrill = [double]$d
                    $c.HoleDiaDrillValid = $true
                    $lblEcho.ForeColor = $okCol
                    $lblEcho.Text = ("Hole diameter {0} (thru all)." -f [double]$d)
                    $wiz.SetChip('holedia', ('dia {0}' -f [double]$d), 'set')
                } else {
                    $c.HoleDiaDrillValid = $false
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
            if (-not $c.HoleDiaDrillValid) { return $false }
            return $true
        }
    [void]$Steps.Add($diaStep)

    # ========================================================================
    # STEP 4 - drill-run (run): the drill loop
    # ========================================================================
    $runStep = New-WizardStep -Key 'drill-run' -Title 'Drill the holes' -Stage 'Drill' -Kind 'run' -PrimaryText 'Drill the holes' `
        -Validate {
            param($c)
            $n = 0
            try { if ($null -ne $c.HolePairs) { $n = @($c.HolePairs).Count } } catch { $n = 0 }
            return [bool](($n -ge 1) -and $c.BlankMade)
        } `
        -Build {
            param($panel, $c, $wiz)
            if ($c.HolesMade -gt 0) {
                Add-RebuiltNotice -Panel $panel -Context $c -Wizard $wiz -Message ("Holes are already drilled ({0})." -f [int]$c.HolesMade) `
                    -GoToKey 'drill-arm-points'
                return
            }
            $n = 0
            try { if ($null -ne $c.HolePairs) { $n = @($c.HolePairs).Count } } catch { $n = 0 }
            $dia = 0.0
            try { if ($null -ne $c.HoleDiaDrill) { $dia = [double]$c.HoleDiaDrill } } catch { $dia = 0.0 }
            $orientNote = if ($c.DefaultOrient) { "Creo's default On-Point direction" }
                          elseif ($c.TangentOrient) { "normal to a TANGENT PLANE built at each hole (normal-to-surface by construction)" }
                          else { "normal to the picked surface (verify visually)" }
            Add-Para $panel ("{0} On-Point hole(s), diameter {1}, thru all - {2}. Press 'Drill the holes' to begin. Do not touch Creo while it runs." -f $n, $dia, $orientNote) 8 0 $null
        } `
        -OnNext {
            param($c, $wiz)
            if ($c.HolesMade -gt 0) { return $true }   # idempotent: revisited after drilling -> do not re-drill

            # REBIND COM handles from $ctx (a bare $session read can be stale --
            # [[project_gui_scope_bugs]]). The tangent-plane lib reads the core scope set
            # by Initialize-DrilljigCore; these locals are for the direct RunMacro below.
            $session = $null; $model = $null; $pfcType = $null
            if ($null -ne $c.Session) { $session = $c.Session }
            if ($null -ne $c.Model)   { $model   = $c.Model }
            if ($null -ne $c.Type)    { $pfcType = $c.Type }
            if ($null -eq $session -or $null -eq $model) {
                $wiz.SetChip('holes', 'holes: aborted (no session)', 'aborted')
                return $true
            }

            $pairs = @()
            try { if ($null -ne $c.HolePairs) { $pairs = @($c.HolePairs) } } catch { $pairs = @() }
            if ($pairs.Count -lt 1) { return $false }

            $dia = 0.0
            try { if ($null -ne $c.HoleDiaDrill) { $dia = [double]$c.HoleDiaDrill } } catch { $dia = 0.0 }
            if ($dia -le 0) {
                $wiz.SetChip('holes', 'holes: aborted (no diameter)', 'aborted')
                return $true
            }
            $bodyIx = 0
            try { if ($null -ne $c.BodyIndex) { $bodyIx = [int]$c.BodyIndex } } catch { $bodyIx = 0 }

            $wiz.BeginRun('Drilling the holes...')
            $poll = { try { [System.Windows.Forms.Application]::DoEvents() } catch {} }

            $total = $pairs.Count
            $idx = 0; $made = 0; $noop = 0; $fail = 0; $abort = $false

            foreach ($pair in $pairs) {
                $idx++
                $wiz.SetProgress([int][Math]::Floor(($idx / [double]$total) * 100), ("Hole {0}/{1}" -f $idx, $total))

                # ORIENTATION: build a TANGENT plane at (point, surface); its normal IS the
                # surface normal there -> drilling On-Point normal to it is normal-to-surface
                # by construction. Canary-gated inside Invoke-TangentPlane: on a miss we fall
                # back to the surface id for THIS hole (never assume; never block the drill).
                # The plane id is stashed on the pair so the Relief stage hosts the slot on it.
                # NOTE: use $ptId, NOT $pid -- $PID is a PowerShell read-only automatic
                # variable (the process id); assigning to it throws "Cannot overwrite
                # variable PID because it is read-only or constant".
                $ptId = 0
                try { $ptId = [int]$pair.PointId } catch { $ptId = 0 }
                $sid = 0
                try { $sid = [int]$pair.SurfaceId } catch { $sid = 0 }
                $orientRef = $sid   # default orientation reference is the surface id

                if ($c.TangentOrient -and -not $c.DefaultOrient -and $sid -gt 0 -and $ptId -gt 0) {
                    $tp = $null
                    try { $tp = Invoke-TangentPlane -PointId $ptId -SurfaceId $sid -OnPoll $poll } catch { $tp = $null }
                    if ($null -ne $tp -and $tp.Created -and [int]$tp.PlaneId -gt 0) {
                        try { $pair.TangentPlaneId = [int]$tp.PlaneId } catch {}
                        $orientRef = [int]$tp.PlaneId
                        $wiz.Log(("Hole {0}: tangent plane {1} created." -f $idx, [int]$tp.PlaneId))
                    } else {
                        $rsn = ''
                        try { if ($null -ne $tp) { $rsn = [string]$tp.Reason } } catch {}
                        $wiz.Log(("Hole {0}: tangent plane not created ({1}) - using the surface id {2} for orientation." -f $idx, $rsn, $sid))
                        $orientRef = $sid
                    }
                }

                # Build + fire the On-Point normal-hole macro. -SurfaceId here is the
                # ORIENTATION reference (a tangent plane feat id when we made one, else the
                # surface id). Canary via Wait-ModelModified on the VersionStamp.
                $hm = Build-NormalHoleMacro -PointId $ptId -SurfaceId $orientRef -Diameter $dia -BodyIndex $bodyIx -DefaultOrient:$c.DefaultOrient
                $changed = $false
                try {
                    $stamp = $model.VersionStamp
                    $session.RunMacro($hm)
                    $changed = Wait-ModelModified -Model $model -PreviousStamp $stamp -OnPoll $poll
                } catch {
                    $fail++
                    $wiz.Log(("Hole {0}: macro error - {1}" -f $idx, $_.Exception.Message))
                }
                if ($changed) { $made++; $wiz.Log(("Hole {0}/{1}: drilled." -f $idx, $total)) }
                elseif ($fail -eq 0) { $noop++; $wiz.Log(("Hole {0}/{1}: no change." -f $idx, $total)) }

                # CANARY GATE on hole #1: the first hole MUST change the model, else stop
                # (widget drift / a broken orientation pre-select). Never assume success.
                if ($idx -eq 1 -and -not $changed) {
                    $wiz.Log('ABORT: the first hole did not modify the model (VersionStamp unchanged).')
                    $wiz.Log('Check Creo: did the hole dashboard open / error? Re-run with --default-orient to use the proven point-only macro.')
                    $abort = $true
                    break
                }
            }

            $wiz.SetProgress(100, 'Holes done')
            $wiz.Log(("Points targeted: {0}  drilled: {1}  no-op: {2}  errors: {3}." -f $total, $made, $noop, $fail))

            if ($abort) {
                $wiz.SetChip('holes', 'holes: aborted', 'aborted')
                return $true
            }
            if ($made -lt 1) {
                $wiz.SetChip('holes', 'holes: 0 drilled', 'aborted')
                return $true
            }

            # SUCCESS: stash for the Relief stage.
            $c.HolesMade = $made
            $c.CurvedHolePairs = @($pairs)          # carry TangentPlaneId set above
            $c.CurvedHoleDiaFinal = [double]$dia
            $wiz.MarkCommitted()
            $state = if ($made -eq $total -and $fail -eq 0) { 'built' } else { 'unverified' }
            $wiz.SetChip('holes', ("holes: {0} drilled" -f $made), $state)
            return $true
        }
    [void]$Steps.Add($runStep)
}
