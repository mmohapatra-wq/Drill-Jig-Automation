# ============================================================================
# lib\wizard.ps1 - a small, reusable WinForms WIZARD framework
# ============================================================================
# A single never-closing window with three permanent regions:
#   (1) TOP    a breadcrumb rail of stage "pills" (done / active / future),
#              drawn in a FAIL-SILENT Paint handler (same never-throw discipline
#              as lib\orthogrid_gui.ps1's Draw-AxisGlyph).
#   (2) CENTER a swappable canvas Panel whose children are rebuilt per step.
#   (3) BOTTOM a spec-recap CHIP band (honest status colors) + an action bar
#              (Back, a single accent primary button, a thin status line).
#
# This is the "Guided Build" wizard spine recommended for drilljig-gui.cmd: one
# decision per step, the primary button gated on a real condition, and every
# unavoidable Creo MOUSE PICK promoted to its own arm/verify step (there is no
# blocking Read-Host -- the thread simply waits on the user pressing a big
# "I clicked them - verify" button, whose handler reads the selection buffer on
# the SAME STA thread and only enables Next when the pick validates).
#
# THREADING: WinForms needs an STA thread; the Windows PowerShell 5.1 console
# host (what the hybrid .cmd header launches) is STA by default, so no -STA is
# needed (identical to lib\orthogrid_gui.ps1). Long blocking COM/RunMacro work
# runs synchronously on this one thread inside a step's OnNext handler; the
# wizard flips the canvas to a RUN view (marquee + live log) and the handler
# pumps [System.Windows.Forms.Application]::DoEvents() between ALREADY-ATOMIC
# macro batches so the window repaints between them. A hard BUSY GUARD disables
# all input for the duration of every run so a stray click cannot re-enter the
# STA-affine, non-reentrant Creo session.
#
# Dot-source AFTER the WinForms assemblies are available (this file loads them):
#     . (Join-Path $ScriptDir 'lib\wizard.ps1')
#     $steps = @( (New-WizardStep -Key intro -Title 'Welcome' -Stage 'Start' -Build {...}), ... )
#     $ok = Show-Wizard -Steps $steps -Stages @('Start','Build') -Title 'My Tool'
#
# The PURE logic (breadcrumb state, chip color, back-navigation safety) lives in
# functions with NO WinForms dependency so lib\tests\run_wizard_tests.ps1 can
# exercise them offline; the WinForms surface (Show-Wizard + the render helpers)
# is parse-checked + function-resolve smoke-checked, exactly like orthogrid_gui.
# ============================================================================

# ----------------------------------------------------------------------------
# PURE: New-WizardStep - build a step descriptor (no WinForms).
#   -Key        unique id (string)
#   -Title      heading shown at the top of the canvas
#   -Stage      breadcrumb pill this step belongs to (groups steps into stages)
#   -Kind       'info' | 'choice' | 'pick' | 'run' (styling/àffordance hint)
#   -PrimaryText  the primary button label for this step (default 'Next')
#   -Build      {param($panel,$ctx,$wiz)} populate the canvas. REQUIRED in
#               practice (a $null Build renders an empty canvas).
#   -Validate   {param($ctx) -> [bool]} gates the primary button. $null = always
#               enabled. Re-run on demand via $wiz.Refresh().
#   -OnNext     {param($ctx,$wiz) -> [bool]} runs when the primary is clicked.
#               Return $true to ADVANCE, $false to STAY (e.g. a pick that did not
#               validate). May do blocking Creo work (wrap in $wiz.BeginRun/EndRun).
#               $null = plain advance (gated by Validate).
# Returned object also carries mutable .Committed (set via $wiz.MarkCommitted()),
# which the back-navigation guard reads so the user can never step Back across a
# point where Creo geometry was already mutated.
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# Show-WizardMessage - a MessageBox that ALWAYS appears in front, even when the
# Creo window is the foreground app. A plain [MessageBox]::Show() with no owner
# can be drawn BEHIND whatever window has focus (Creo, after the user clicks in
# it) - and because the box is modal, the whole wizard then freezes waiting on a
# dialog the user can't see or click ("can't click anything"). The fix: own the
# box with a tiny invisible TopMost form, which forces it above Creo. Returns the
# DialogResult. Never throws (degrades to a plain Show on any failure).
#   $Buttons : 'OK' | 'OKCancel' | 'YesNo' | ...   $Icon : 'Information' | 'Warning' | 'Error' | 'Question'
# ----------------------------------------------------------------------------
function Show-WizardMessage {
    param(
        [string]$Text,
        [string]$Title   = 'Drill Jig Builder',
        [string]$Buttons = 'OK',
        [string]$Icon    = 'Information'
    )
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop } catch {}
    $owner = $null
    try {
        $owner = New-Object System.Windows.Forms.Form
        $owner.TopMost       = $true
        $owner.ShowInTaskbar = $false
        $owner.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $owner.Size          = New-Object System.Drawing.Size(1, 1)
        $owner.Opacity       = 0
        $owner.Show()
        $owner.Activate()
        $btn  = [System.Windows.Forms.MessageBoxButtons]$Buttons
        $icn  = [System.Windows.Forms.MessageBoxIcon]$Icon
        return [System.Windows.Forms.MessageBox]::Show($owner, $Text, $Title, $btn, $icn)
    } catch {
        try { return [System.Windows.Forms.MessageBox]::Show($Text, $Title) } catch { return [System.Windows.Forms.DialogResult]::OK }
    } finally {
        if ($null -ne $owner) { try { $owner.Close(); $owner.Dispose() } catch {} }
    }
}

function New-WizardStep {
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][string]$Title,
        [Parameter(Mandatory=$true)][string]$Stage,
        [ValidateSet('info','choice','pick','run')][string]$Kind = 'info',
        [string]$PrimaryText = 'Next',
        [scriptblock]$Build = $null,
        [scriptblock]$Validate = $null,
        [scriptblock]$OnNext = $null
    )
    return [pscustomobject]@{
        Key         = $Key
        Title       = $Title
        Stage       = $Stage
        Kind        = $Kind
        PrimaryText = $PrimaryText
        Build       = $Build
        Validate    = $Validate
        OnNext      = $OnNext
        Committed   = $false
    }
}

# ----------------------------------------------------------------------------
# PURE: Get-MaxCommittedIndex - the highest step index whose .Committed is true,
# or -1 if none. The back-navigation guard uses this: once a step has committed
# (Creo geometry created), no step at or before it may be revisited.
# ----------------------------------------------------------------------------
# NOTE: global: scope. These pure helpers are called from .GetNewClosure() blocks
# (the breadcrumb Paint handler, the button-enable logic, SetChip). A closure
# resolves bare function names against GLOBAL/module scope, NOT the local scope a
# function was dot-sourced into. drilljig-gui.cmd runs its whole body via
# & ([scriptblock]::Create(...)) (the hybrid .cmd header), which dot-sources these
# into that scriptblock's LOCAL scope -> a plain `function Foo` would be invisible
# to the closures ("The term 'Get-MaxCommittedIndex' is not recognized"), so
# $wiz.Refresh() threw, the Next button never enabled, and the inline editor looked
# dead. `function global:` makes them resolvable from any closure regardless of how
# the host script was launched. (Verified: a global fn resolves from a closure under
# scriptblock::Create; a local one does not.)
function global:Get-MaxCommittedIndex {
    param([array]$Steps)
    $max = -1
    if ($null -eq $Steps) { return $max }
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        $c = $false
        try { $c = [bool]$Steps[$i].Committed } catch { $c = $false }
        if ($c) { $max = $i }
    }
    return $max
}

# ----------------------------------------------------------------------------
# PURE: Test-CanGoBack - is Back allowed from $CurrentIndex? Back lands on the
# previous step ($CurrentIndex-1); it is allowed only when that target sits
# strictly AFTER the last committed step (so you can never cross a committed
# mutation boundary). At index 0 there is nowhere to go.
# ----------------------------------------------------------------------------
function global:Test-CanGoBack {
    param([int]$CurrentIndex, [int]$MaxCommittedIndex)
    if ($CurrentIndex -le 0) { return $false }
    return (($CurrentIndex - 1) -gt $MaxCommittedIndex)
}

# ----------------------------------------------------------------------------
# PURE: Get-BreadcrumbStates - given the ordered stage names, the step list, and
# the current step index, return one @{ Name; State } per stage where State is
# 'done' | 'active' | 'future'. A stage spans the index range of the steps that
# carry its name: active if the current index is inside that span, done if the
# current index is past the span's end, future if before its start. Stages with
# no steps are 'future'. Pure - no WinForms.
# ----------------------------------------------------------------------------
function global:Get-BreadcrumbStates {
    param([array]$Stages, [array]$Steps, [int]$CurrentIndex)
    $out = @()
    if ($null -eq $Stages) { return ,@($out) }
    foreach ($stage in $Stages) {
        $idxs = @()
        if ($null -ne $Steps) {
            for ($i = 0; $i -lt $Steps.Count; $i++) {
                if ([string]$Steps[$i].Stage -eq [string]$stage) { $idxs += $i }
            }
        }
        $state = 'future'
        if ($idxs.Count -gt 0) {
            $minI = ($idxs | Measure-Object -Minimum).Minimum
            $maxI = ($idxs | Measure-Object -Maximum).Maximum
            if     ($CurrentIndex -gt $maxI) { $state = 'done'   }
            elseif ($CurrentIndex -lt $minI) { $state = 'future' }
            else                             { $state = 'active'  }
        }
        $out += [pscustomobject]@{ Name = [string]$stage; State = $state }
    }
    return ,@($out)
}

# ----------------------------------------------------------------------------
# PURE: chip + breadcrumb honesty palette. Maps a semantic STATE string to a
# .NET color NAME (resolved to System.Drawing.Color only inside the WinForms
# layer), so tests can assert the mapping without loading System.Drawing.
#   needs-input -> gray      (not provided yet)
#   set         -> steelblue (provided, not built in Creo)
#   built       -> green     (built AND independently verified)
#   unverified  -> goldenrod (built but verification did not / could not confirm)
#   aborted     -> firebrick (a canary/abort stopped it)
# Any unknown state falls back to gray.
# ----------------------------------------------------------------------------
function global:Resolve-ChipColorName {
    param([string]$State)
    switch (("" + $State).ToLower()) {
        'needs-input' { return 'Gray' }
        'set'         { return 'SteelBlue' }
        'built'       { return 'SeaGreen' }
        'verified'    { return 'SeaGreen' }
        'unverified'  { return 'Goldenrod' }
        'warning'     { return 'Goldenrod' }
        'aborted'     { return 'Firebrick' }
        default       { return 'Gray' }
    }
}

# ----------------------------------------------------------------------------
# Show-Wizard - run the wizard modally and return $true if the user completed it
# (advanced past the last step) or $false if they cancelled / closed the window.
# Never throws on a UI failure: assembly load problems degrade to $false with a
# warning (so a caller can fall back to its console flow).
#
#   -Steps     array from New-WizardStep, in order. The flow is otherwise linear;
#              a step's OnNext may mutate $Context to drive later steps' Build.
#   -Stages    ordered breadcrumb pill names (a step's .Stage must be one of these).
#   -Title     window title.
#   -SubTitle  small text shown at the right of the action bar (e.g. the model).
#   -Context   shared hashtable handed to every Build/Validate/OnNext (the place
#              steps stash collected values). Defaults to a fresh @{}.
#   -Accent    accent color name (default 'SteelBlue').
# ----------------------------------------------------------------------------
function Show-Wizard {
    param(
        [Parameter(Mandatory=$true)][array]$Steps,
        [Parameter(Mandatory=$true)][array]$Stages,
        [string]$Title = 'Wizard',
        [string]$SubTitle = '',
        [hashtable]$Context = $null,
        [string]$Accent = 'SteelBlue'
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing       -ErrorAction Stop
    } catch {
        Write-Warning "Show-Wizard: could not load WinForms assemblies: $($_.Exception.Message)"
        return $false
    }

    if ($null -eq $Context) { $Context = @{} }

    # ------------------------------------------------------------------------
    # GLOBAL SAFETY NET. A bug inside any event handler (a $null array index, a
    # bad property access) is, under $ErrorActionPreference='Stop', promoted to a
    # TERMINATING exception that escapes the handler and pops the .NET "unhandled
    # exception" JIT dialog -- which kills the message loop, so the wizard dies and
    # nothing responds. We refuse that outcome two ways:
    #   1. Route WinForms thread exceptions to our own handler (no JIT dialog).
    #   2. $wzLogError writes the FULL PowerShell stack (ScriptStackTrace +
    #      the failing line) to drilljig-gui-error.log and shows a topmost dialog,
    #      then RETURNS so the loop keeps running.
    # $InvokeGuarded runs a scriptblock through this net (used to wrap renderStep
    # and the click bodies). EAP is forced to Continue inside handlers so an
    # ordinarily-survivable error (e.g. indexing past an array) does NOT terminate.
    # ------------------------------------------------------------------------
    $wzLogPath = $null
    try { $wzLogPath = Join-Path ([System.IO.Path]::GetTempPath()) 'drilljig-gui-error.log' } catch { $wzLogPath = 'drilljig-gui-error.log' }
    $wzLogError = {
        param($Err, [string]$Where, [bool]$ShowDialog = $true)
        $msg = ''
        try {
            if ($Err -is [System.Management.Automation.ErrorRecord]) {
                $msg = "$($Err.Exception.Message)`n`nAt: $($Err.InvocationInfo.PositionMessage)`n`nStack:`n$($Err.ScriptStackTrace)"
            } elseif ($Err -is [Exception]) {
                $msg = "$($Err.Message)`n`n$($Err.StackTrace)"
            } else {
                $msg = [string]$Err
            }
        } catch { $msg = 'unknown error (could not format)' }
        $stamp = ''
        try { $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } catch {}
        $line = "[$stamp] ($Where) $msg`n--------------------------------------------------------------------------------`n"
        try { Add-Content -Path $wzLogPath -Value $line -Encoding UTF8 } catch {}
        # A render error already shows an inline label on the canvas, so it logs
        # silently ($ShowDialog=$false). A click/OnNext error has no inline surface,
        # so it pops the topmost dialog. Either way the message loop stays alive.
        if ($ShowDialog) {
            try {
                Show-WizardMessage -Text ("Something went wrong in: $Where`n`n$($msg)`n`nThe wizard is still open - you can go Back or close it.`nFull detail logged to:`n$($wzLogPath)") -Title 'Drill Jig Builder - handler error' -Buttons 'OK' -Icon 'Error' | Out-Null
            } catch {}
        }
    }
    $InvokeGuarded = {
        param([scriptblock]$Block, [string]$Where, [bool]$ShowDialog = $true)
        $old = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $Block
        } catch {
            & $wzLogError $_ $Where $ShowDialog
        } finally {
            $ErrorActionPreference = $old
        }
    }
    try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch {}
    try {
        [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
        [System.Windows.Forms.Application]::add_ThreadException({
            param($s, $e)
            try { & $wzLogError $e.Exception 'WinForms thread exception' } catch {}
        })
    } catch {}

    $accentColor = [System.Drawing.Color]::SteelBlue
    # ---- THEME: darkish-blue background, white text (user request 2026-06-26) ----
    # A single palette every control reads. Published to $script:WizTheme so the
    # helper functions in drilljig-gui.cmd (Add-Para/Add-ArmBanner/Add-VerifyControls)
    # can colour themselves to match without each hard-coding a colour.
    $accentColor = [System.Drawing.Color]::FromArgb(64, 132, 232)    # bright blue (buttons/active)
    try { if ($Accent -ne 'SteelBlue') { $c2 = [System.Drawing.Color]::FromName($Accent); if ($c2.A -ne 0) { $accentColor = $c2 } } } catch {}
    $formBack    = [System.Drawing.Color]::FromArgb(20, 30, 52)      # darkish blue (window)
    $canvasBack  = [System.Drawing.Color]::FromArgb(30, 42, 68)      # slightly lighter card
    $inkColor    = [System.Drawing.Color]::FromArgb(238, 242, 248)   # near-white text
    $mutedColor  = [System.Drawing.Color]::FromArgb(158, 172, 196)   # light slate (secondary text)
    $cardBack    = [System.Drawing.Color]::FromArgb(40, 54, 84)      # choice-card fill
    $cardHover   = [System.Drawing.Color]::FromArgb(54, 72, 112)     # choice-card hover
    $okColor     = [System.Drawing.Color]::FromArgb(120, 210, 150)   # success text on dark
    $warnColor   = [System.Drawing.Color]::FromArgb(245, 200, 90)    # warning text on dark
    $errColor    = [System.Drawing.Color]::FromArgb(245, 120, 110)   # error text on dark
    $script:WizTheme = [pscustomobject]@{
        Accent = $accentColor; FormBack = $formBack; CanvasBack = $canvasBack
        Ink = $inkColor; Muted = $mutedColor; CardBack = $cardBack; CardHover = $cardHover
        Ok = $okColor; Warn = $warnColor; Err = $errColor
    }

    $fontH1   = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Regular)
    $fontBody = New-Object System.Drawing.Font('Segoe UI', 10)
    $fontStep = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $fontPill = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $fontChip = New-Object System.Drawing.Font('Segoe UI', 8.5)

    # --- shared mutable state (script-scoped so the closures see it live) -----
    # .Render holds the render scriptblock (set below, after it is defined) so the
    # $wiz.Rerender() method can re-invoke the current step's Build in place -- used
    # by the decision-tree step (descend card-by-card) and the pick steps (show the
    # verified result) without advancing.
    $wz = [pscustomobject]@{
        Index     = 0
        Steps     = $Steps
        Stages    = $Stages
        Context   = $Context
        Completed = $false
        Busy      = $false
        Render    = $null
    }

    # --- Form ---------------------------------------------------------------
    $form = New-Object System.Windows.Forms.Form
    $form.Text          = $Title
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.ClientSize    = New-Object System.Drawing.Size(900, 640)
    $form.MinimumSize   = New-Object System.Drawing.Size(820, 600)
    $form.BackColor     = $formBack
    $form.Font          = $fontBody

    # ---- region rectangles (anchored so a resize keeps the layout) ----------
    $railH   = 78
    $barH    = 86       # action bar + chip band
    $pad     = 16

    # --- TOP breadcrumb rail (custom Paint) ---------------------------------
    $rail = New-Object System.Windows.Forms.Panel
    $rail.Location = New-Object System.Drawing.Point(0, 0)
    $rail.Size     = New-Object System.Drawing.Size($form.ClientSize.Width, $railH)
    $rail.Anchor   = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $rail.BackColor = $formBack
    $form.Controls.Add($rail)

    $rail.Add_Paint({
        param($s, $e)
        try {
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
            $states = Get-BreadcrumbStates -Stages $wz.Stages -Steps $wz.Steps -CurrentIndex $wz.Index
            $n = @($states).Count
            if ($n -le 0) { return }
            $cw = $s.ClientSize.Width
            $slot = [double]$cw / [double]$n
            $cy = 30.0
            $r  = 12.0
            $doneFill   = [System.Drawing.Color]::FromArgb(90, 190, 130)
            $activeFill = $accentColor
            $futurePen  = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(90,104,132), 2)
            $linePen    = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(70,84,112), 2)

            # connector line through all pill centers
            $firstCx = $slot * 0.5
            $lastCx  = $slot * ($n - 0.5)
            $g.DrawLine($linePen, [single]$firstCx, [single]$cy, [single]$lastCx, [single]$cy)

            for ($i = 0; $i -lt $n; $i++) {
                $st = $states[$i]
                $cx = $slot * ($i + 0.5)
                $rectX = [single]($cx - $r); $rectY = [single]($cy - $r)
                $dia = [single]($r * 2)
                if ($st.State -eq 'done') {
                    $b = New-Object System.Drawing.SolidBrush($doneFill)
                    $g.FillEllipse($b, $rectX, $rectY, $dia, $dia); $b.Dispose()
                    # check mark
                    $cp = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 2)
                    $g.DrawLines($cp, @(
                        (New-Object System.Drawing.PointF([single]($cx-5), [single]$cy)),
                        (New-Object System.Drawing.PointF([single]($cx-1), [single]($cy+4))),
                        (New-Object System.Drawing.PointF([single]($cx+5), [single]($cy-5)))
                    ))
                    $cp.Dispose()
                } elseif ($st.State -eq 'active') {
                    $b = New-Object System.Drawing.SolidBrush($activeFill)
                    $g.FillEllipse($b, $rectX, $rectY, $dia, $dia); $b.Dispose()
                    $halo = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(90, $activeFill.R, $activeFill.G, $activeFill.B), 3)
                    $g.DrawEllipse($halo, [single]($cx-$r-4), [single]($cy-$r-4), [single]($dia+8), [single]($dia+8))
                    $halo.Dispose()
                } else {
                    $fb = New-Object System.Drawing.SolidBrush($formBack)
                    $g.FillEllipse($fb, $rectX, $rectY, $dia, $dia); $fb.Dispose()
                    $g.DrawEllipse($futurePen, $rectX, $rectY, $dia, $dia)
                }
                # label
                $isCur = ($st.State -eq 'active')
                $col = if ($st.State -eq 'future') { [System.Drawing.Color]::FromArgb(130,144,168) } else { $inkColor }
                $lbFont = if ($isCur) { New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold) } else { New-Object System.Drawing.Font('Segoe UI', 9) }
                $sf = New-Object System.Drawing.StringFormat
                $sf.Alignment = [System.Drawing.StringAlignment]::Center
                $tb = New-Object System.Drawing.SolidBrush($col)
                $g.DrawString([string]$st.Name, $lbFont, $tb, (New-Object System.Drawing.RectangleF([single]($cx - $slot/2), [single]($cy + $r + 4), [single]$slot, 18)), $sf)
                $tb.Dispose(); $lbFont.Dispose(); $sf.Dispose()
            }
            $futurePen.Dispose(); $linePen.Dispose()
        } catch {
            # a breadcrumb paint failure must never crash the wizard
        }
    })

    # --- CENTER canvas (a white card with a step heading + a body panel) -----
    $card = New-Object System.Windows.Forms.Panel
    $card.Location  = New-Object System.Drawing.Point($pad, ($railH + 4))
    $card.Size      = New-Object System.Drawing.Size(($form.ClientSize.Width - 2*$pad), ($form.ClientSize.Height - $railH - $barH - 12))
    $card.Anchor    = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $card.BackColor = $canvasBack
    $card.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $form.Controls.Add($card)

    $lblStepNo = New-Object System.Windows.Forms.Label
    $lblStepNo.Location  = New-Object System.Drawing.Point(28, 20)
    $lblStepNo.AutoSize  = $true
    $lblStepNo.Font      = $fontStep
    $lblStepNo.ForeColor = $mutedColor
    $card.Controls.Add($lblStepNo)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Location  = New-Object System.Drawing.Point(26, 40)
    $lblTitle.AutoSize  = $true
    $lblTitle.Font      = $fontH1
    $lblTitle.ForeColor = $inkColor
    $card.Controls.Add($lblTitle)

    # the per-step body host: cleared + rebuilt on every render. AutoScroll so a
    # step taller than the canvas gets a scrollbar instead of CLIPPING its lower
    # controls (the "boxes get cut off" report). A small right inset leaves room
    # for the scrollbar so it never overlaps content.
    $body = New-Object System.Windows.Forms.Panel
    $body.Location   = New-Object System.Drawing.Point(14, 84)
    $body.Size       = New-Object System.Drawing.Size(($card.Width - 28), ($card.Height - 96))
    $body.Anchor     = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $body.BackColor  = $canvasBack
    $body.AutoScroll = $true
    $card.Controls.Add($body)

    # --- BOTTOM: chip band + action bar -------------------------------------
    $chipBand = New-Object System.Windows.Forms.FlowLayoutPanel
    $chipBand.Location  = New-Object System.Drawing.Point($pad, ($form.ClientSize.Height - $barH))
    $chipBand.Size      = New-Object System.Drawing.Size(($form.ClientSize.Width - 2*$pad), 30)
    $chipBand.Anchor    = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $chipBand.WrapContents = $false
    $chipBand.AutoScroll   = $false
    $chipBand.BackColor    = $formBack
    $chipBand.Padding      = New-Object System.Windows.Forms.Padding(2, 4, 2, 0)
    $form.Controls.Add($chipBand)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location  = New-Object System.Drawing.Point(($pad + 2), ($form.ClientSize.Height - $barH + 34))
    $lblStatus.Size      = New-Object System.Drawing.Size(420, 22)
    $lblStatus.Anchor    = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $lblStatus.ForeColor = $mutedColor
    $lblStatus.Font      = $fontBody
    $form.Controls.Add($lblStatus)

    $lblSub = New-Object System.Windows.Forms.Label
    $lblSub.Size      = New-Object System.Drawing.Size(280, 22)
    $lblSub.Location  = New-Object System.Drawing.Point(($form.ClientSize.Width - 470), ($form.ClientSize.Height - $barH + 34))
    $lblSub.Anchor    = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $lblSub.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $lblSub.ForeColor = $mutedColor
    $lblSub.Text      = $SubTitle
    $form.Controls.Add($lblSub)

    $btnNext = New-Object System.Windows.Forms.Button
    $btnNext.Size      = New-Object System.Drawing.Size(160, 36)
    $btnNext.Location  = New-Object System.Drawing.Point(($form.ClientSize.Width - $pad - 160), ($form.ClientSize.Height - $barH + 30))
    $btnNext.Anchor    = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $btnNext.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnNext.FlatAppearance.BorderSize = 0
    $btnNext.BackColor = $accentColor
    $btnNext.ForeColor = [System.Drawing.Color]::White
    $btnNext.Font      = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $btnNext.Text      = 'Next'
    $form.Controls.Add($btnNext)

    $btnBack = New-Object System.Windows.Forms.Button
    $btnBack.Size      = New-Object System.Drawing.Size(96, 36)
    $btnBack.Location  = New-Object System.Drawing.Point(($form.ClientSize.Width - $pad - 160 - 108), ($form.ClientSize.Height - $barH + 30))
    $btnBack.Anchor    = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $btnBack.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnBack.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90,104,132)
    $btnBack.BackColor = $canvasBack
    $btnBack.ForeColor = $inkColor
    $btnBack.Font      = New-Object System.Drawing.Font('Segoe UI', 10)
    $btnBack.Text      = '< Back'
    $form.Controls.Add($btnBack)

    # --- RUN view controls (hidden until a blocking op runs) -----------------
    $runMarquee = New-Object System.Windows.Forms.ProgressBar
    $runMarquee.Style    = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $runMarquee.MarqueeAnimationSpeed = 30
    $runMarquee.Visible  = $false
    $runLog = New-Object System.Windows.Forms.TextBox
    $runLog.Multiline  = $true
    $runLog.ReadOnly   = $true
    $runLog.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $runLog.BackColor  = [System.Drawing.Color]::FromArgb(16, 24, 42)
    $runLog.ForeColor  = [System.Drawing.Color]::FromArgb(200, 214, 236)
    $runLog.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $runLog.Font       = New-Object System.Drawing.Font('Consolas', 9)
    $runLog.Visible    = $false

    # ========================================================================
    # The $wiz controller handed to every Build/Validate/OnNext. Methods close
    # over the form controls + $wz state above.
    # ========================================================================
    $wiz = [pscustomobject]@{ Context = $Context }

    # --- helpers the methods reuse ---
    $applyEnable = {
        param([bool]$on)
        $card.Enabled    = $on
        $btnBack.Enabled = ($on -and (Test-CanGoBack -CurrentIndex $wz.Index -MaxCommittedIndex (Get-MaxCommittedIndex -Steps $wz.Steps)))
        # btnNext enable is owned by Refresh (Validate); leave it to the caller
    }

    $wiz | Add-Member -MemberType ScriptMethod -Name SetStatus -Value {
        param([string]$Text)
        $lblStatus.Text = [string]$Text
        try { [System.Windows.Forms.Application]::DoEvents() } catch {}
    }.GetNewClosure()

    $wiz | Add-Member -MemberType ScriptMethod -Name Pump -Value {
        try { [System.Windows.Forms.Application]::DoEvents() } catch {}
    }.GetNewClosure()

    $wiz | Add-Member -MemberType ScriptMethod -Name Log -Value {
        param([string]$Text)
        try {
            if ($runLog.Text.Length -gt 0) { $runLog.AppendText([Environment]::NewLine) }
            $runLog.AppendText([string]$Text)
            $runLog.SelectionStart = $runLog.Text.Length
            $runLog.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        } catch {}
    }.GetNewClosure()

    $wiz | Add-Member -MemberType ScriptMethod -Name SetProgress -Value {
        param([int]$Pct, [string]$Label = '')
        try {
            if ($runMarquee.Style -ne [System.Windows.Forms.ProgressBarStyle]::Continuous) {
                $runMarquee.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
            }
            $p = [Math]::Max(0, [Math]::Min(100, $Pct))
            $runMarquee.Value = $p
            if ($Label) { $lblStatus.Text = $Label }
            [System.Windows.Forms.Application]::DoEvents()
        } catch {}
    }.GetNewClosure()

    # BeginRun: flip the canvas to the RUN view (marquee + live log), hard-disable
    # ALL input (the busy guard) so a stray click cannot re-enter the Creo session.
    $wiz | Add-Member -MemberType ScriptMethod -Name BeginRun -Value {
        param([string]$Heading = 'Working...')
        $wz.Busy = $true
        $body.Controls.Clear()
        $lblStepNo.Text = 'Working in Creo'
        $lblTitle.Text  = [string]$Heading
        $runMarquee.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        $runMarquee.Location = New-Object System.Drawing.Point(6, 6)
        $runMarquee.Size     = New-Object System.Drawing.Size(($body.Width - 12), 18)
        $runMarquee.Anchor   = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $runMarquee.Visible  = $true
        $runLog.Location = New-Object System.Drawing.Point(6, 32)
        $runLog.Size     = New-Object System.Drawing.Size(($body.Width - 12), ($body.Height - 44))
        $runLog.Anchor   = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $runLog.Text     = ''
        $runLog.Visible  = $true
        $body.Controls.Add($runMarquee)
        $body.Controls.Add($runLog)
        $btnBack.Enabled = $false
        $btnNext.Enabled = $false
        $card.Enabled    = $true   # keep the log visible/scrollable, but no actionable controls inside
        $lblStatus.Text  = 'This can take a moment - do not touch Creo.'
        try { [System.Windows.Forms.Application]::DoEvents() } catch {}
    }.GetNewClosure()

    $wiz | Add-Member -MemberType ScriptMethod -Name EndRun -Value {
        $runMarquee.Visible = $false
        $runLog.Visible     = $false
        $body.Controls.Remove($runMarquee)
        $body.Controls.Remove($runLog)
        $wz.Busy = $false
    }.GetNewClosure()

    $wiz | Add-Member -MemberType ScriptMethod -Name MarkCommitted -Value {
        try { $wz.Steps[$wz.Index].Committed = $true } catch {}
    }.GetNewClosure()

    # Public error sink so helper functions outside Show-Wizard (Add-WizardChoiceCards,
    # Add-VerifyControls) can route a caught exception through the same log+dialog
    # path instead of letting it escape to the JIT dialog.
    $wiz | Add-Member -MemberType ScriptMethod -Name LogError -Value {
        param($Err, [string]$Where)
        try { & $wzLogError $Err $Where } catch {}
    }.GetNewClosure()

    # SetChip: create-or-update a labelled status chip in the bottom recap band.
    # $State drives the dot color via Resolve-ChipColorName.
    $wiz | Add-Member -MemberType ScriptMethod -Name SetChip -Value {
        param([string]$Name, [string]$Label, [string]$State = 'needs-input')
        try {
            $key = 'chip_' + $Name
            $existing = $null
            foreach ($c in $chipBand.Controls) { if ($c.Name -eq $key) { $existing = $c; break } }
            if ($null -eq $existing) {
                $existing = New-Object System.Windows.Forms.Label
                $existing.Name      = $key
                $existing.AutoSize  = $true
                $existing.Font      = New-Object System.Drawing.Font('Segoe UI', 8.5)
                $existing.Margin    = New-Object System.Windows.Forms.Padding(0, 4, 14, 0)
                $existing.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
                [void]$chipBand.Controls.Add($existing)
            }
            # Brighter chip colours tuned for the dark-blue background (the palette
            # NAMES from Resolve-ChipColorName stay the contract; here they map to
            # high-contrast RGB so the chip reads on dark).
            $colName = Resolve-ChipColorName -State $State
            $col = switch ($colName) {
                'Gray'      { [System.Drawing.Color]::FromArgb(168, 182, 206) }
                'SteelBlue' { [System.Drawing.Color]::FromArgb(110, 170, 255) }
                'SeaGreen'  { [System.Drawing.Color]::FromArgb(120, 220, 150) }
                'Goldenrod' { [System.Drawing.Color]::FromArgb(245, 205, 95) }
                'Firebrick' { [System.Drawing.Color]::FromArgb(245, 120, 110) }
                default     { [System.Drawing.Color]::FromArgb(168, 182, 206) }
            }
            $existing.ForeColor = $col
            $existing.Text = ([char]9679) + ' ' + [string]$Label
        } catch {}
    }.GetNewClosure()

    # Refresh: re-run the current step's Validate to (re)gate the primary button,
    # and recompute Back enablement. Safe to call from any handler.
    $wiz | Add-Member -MemberType ScriptMethod -Name Refresh -Value {
        if ($wz.Busy) { return }
        $step = $wz.Steps[$wz.Index]
        $enable = $true
        if ($null -ne $step.Validate) {
            try { $enable = [bool](& $step.Validate $wz.Context) } catch { $enable = $false }
        }
        $btnNext.Enabled = $enable
        $btnBack.Enabled = (Test-CanGoBack -CurrentIndex $wz.Index -MaxCommittedIndex (Get-MaxCommittedIndex -Steps $wz.Steps))
    }.GetNewClosure()

    # Next: programmatic advance request (used by auto-advancing choice cards).
    # Marshalled via BeginInvoke so the current event unwinds before we rebuild
    # the canvas (rebuilding a control's parent mid-event is unsafe).
    $wiz | Add-Member -MemberType ScriptMethod -Name Next -Value {
        try { $form.BeginInvoke([Action]{ $btnNext.PerformClick() }) | Out-Null } catch {}
    }.GetNewClosure()

    # Rerender: rebuild the CURRENT step's body in place (no advance). Marshalled
    # so the triggering event unwinds first. Used to descend the decision tree
    # card-by-card and to show a pick's verified result.
    $wiz | Add-Member -MemberType ScriptMethod -Name Rerender -Value {
        try { $form.BeginInvoke([Action]{ if ($null -ne $wz.Render) { & $wz.Render } }) | Out-Null } catch {}
    }.GetNewClosure()

    # --- the render routine -------------------------------------------------
    # The WHOLE body runs through $InvokeGuarded so a render-time error logs +
    # shows instead of crashing the message loop. EAP is Continue inside.
    $renderStep = {
        & $InvokeGuarded {
            if ($wz.Index -ge $wz.Steps.Count) { return }
            $step = $wz.Steps[$wz.Index]
            $body.Controls.Clear()
            $lblStepNo.Text = ('Step {0} of {1}' -f ($wz.Index + 1), $wz.Steps.Count)
            $lblTitle.Text  = [string]$step.Title
            $btnNext.Text   = if ($step.PrimaryText) { [string]$step.PrimaryText } else { 'Next' }
            $rail.Invalidate()
            if ($null -ne $step.Build) {
                try { & $step.Build $body $wz.Context $wiz } catch {
                    $err = New-Object System.Windows.Forms.Label
                    $err.AutoSize = $false
                    $err.ForeColor = [System.Drawing.Color]::Firebrick
                    $err.Location = New-Object System.Drawing.Point(6, 6)
                    $err.Size = New-Object System.Drawing.Size(($body.Width - 12), 120)
                    $err.Text = "Step render error: $($_.Exception.Message)"
                    $body.Controls.Add($err)
                    # silent log ($false): the inline label above IS the surfaced error,
                    # so don't ALSO pop a modal on every render (that modal-on-open is
                    # what made the wizard look stuck behind its own dialog).
                    try { & $wzLogError $_ ("render step '" + $step.Key + "'") $false } catch {}
                }
            }
            $wiz.Refresh()
        } 'renderStep' $false
    }
    # expose the render block so $wiz.Rerender() can re-invoke it
    $wz.Render = $renderStep

    # --- Back click ---------------------------------------------------------
    $btnBack.Add_Click({
        & $InvokeGuarded {
            if ($wz.Busy) { return }
            if (Test-CanGoBack -CurrentIndex $wz.Index -MaxCommittedIndex (Get-MaxCommittedIndex -Steps $wz.Steps)) {
                $wz.Index = $wz.Index - 1
                & $renderStep
            }
        } 'Back click'
    }.GetNewClosure())

    # --- Next click ---------------------------------------------------------
    $btnNext.Add_Click({
        & $InvokeGuarded {
            if ($wz.Busy) { return }
            $step = $wz.Steps[$wz.Index]

            # gate on Validate (defence in depth - the button is already disabled
            # when invalid, but a programmatic Next must respect it too).
            if ($null -ne $step.Validate) {
                $ok = $false
                try { $ok = [bool](& $step.Validate $wz.Context) } catch { $ok = $false }
                if (-not $ok) { return }
            }

            # OnNext may do blocking Creo work and decides whether we advance.
            $advance = $true
            if ($null -ne $step.OnNext) {
                $wz.Busy = $true
                $btnBack.Enabled = $false
                $btnNext.Enabled = $false
                try {
                    $advance = [bool](& $step.OnNext $wz.Context $wiz)
                } catch {
                    $advance = $false
                    try { & $wzLogError $_ ("OnNext '" + $step.Key + "'") } catch {}
                }
                # ensure the run view is torn down even if OnNext forgot, and ALWAYS
                # clear Busy so the buttons come back.
                try { $wiz.EndRun() } catch {}
                $wz.Busy = $false
            }

            if (-not $advance) { & $renderStep; return }

            $wz.Index = $wz.Index + 1
            if ($wz.Index -ge $wz.Steps.Count) {
                $wz.Completed = $true
                $form.Close()
                return
            }
            & $renderStep
        } 'Next click'
    }.GetNewClosure())

    $form.Add_Shown({ & $InvokeGuarded { & $renderStep } 'form shown' $false }.GetNewClosure())

    # X / Alt-F4 = cancel (unless we already completed)
    $form.Add_FormClosed({ }.GetNewClosure())

    [void]$form.ShowDialog()
    $completed = [bool]$wz.Completed
    try { $form.Dispose() } catch {}
    return $completed
}

# ----------------------------------------------------------------------------
# Add-WizardChoiceCards - a reusable Build helper: lay out a row of flat "cards"
# in $Panel, one per option. Clicking a card runs $OnPick (which typically stashes
# the choice in $ctx) and then, depending on -AfterPick, EITHER re-renders the
# current step in place ('rerender', the DEFAULT - the decision tree descends and
# the bushing OD/length/ID flow advances by re-rendering the same step), advances
# the whole wizard to the next step ('advance'), or does nothing ('none', when the
# pick just toggles a value and the user presses Next themselves).
# Options are @( @{ Title; Subtitle } ... ). $OnPick = {param($index,$option,$ctx,$wiz)}.
# ----------------------------------------------------------------------------
function Add-WizardChoiceCards {
    param(
        [System.Windows.Forms.Panel]$Panel,
        [array]$Options,
        [scriptblock]$OnPick,
        $Context,
        $Wizard,
        [int]$Top = 8,
        [int]$CardWidth = 210,
        [int]$CardHeight = 120,
        [ValidateSet('rerender','advance','none')][string]$AfterPick = 'rerender'
    )
    # theme palette (dark-blue) with safe fallbacks if Show-Wizard wasn't the caller
    $thm = $script:WizTheme
    $cBack  = if ($thm) { $thm.CardBack }  else { [System.Drawing.Color]::FromArgb(40, 54, 84) }
    $cHover = if ($thm) { $thm.CardHover } else { [System.Drawing.Color]::FromArgb(54, 72, 112) }
    $cInk   = if ($thm) { $thm.Ink }       else { [System.Drawing.Color]::FromArgb(238, 242, 248) }
    $cMuted = if ($thm) { $thm.Muted }     else { [System.Drawing.Color]::FromArgb(158, 172, 196) }
    $cBorder = [System.Drawing.Color]::FromArgb(72, 92, 132)

    $gap = 18
    # honor -Top so the cards start BELOW the step heading (the heading is an
    # Add-Para at a small y; previously $cy ignored $Top and started at 8, so the
    # first row of cards OVERLAPPED the heading -- the "box spacing is wrong" report).
    # Reserve ~24px on the right for the body's vertical scrollbar so the rightmost
    # card is never clipped.
    $usableW = $Panel.Width - 8 - 24
    $perRow = [Math]::Max(1, [Math]::Floor($usableW / ($CardWidth + $gap)))
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $opt = $Options[$i]
        $col = $i % $perRow
        $row = [Math]::Floor($i / $perRow)
        $cx = 8 + $col * ($CardWidth + $gap)
        $cy = $Top + $row * ($CardHeight + $gap)

        $cardP = New-Object System.Windows.Forms.Panel
        $cardP.Location  = New-Object System.Drawing.Point($cx, $cy)
        $cardP.Size      = New-Object System.Drawing.Size($CardWidth, $CardHeight)
        $cardP.BackColor = $cBack
        $cardP.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $cardP.Cursor    = [System.Windows.Forms.Cursors]::Hand
        $cardP.Tag       = $i

        $t = New-Object System.Windows.Forms.Label
        $t.AutoSize  = $false
        $t.Location  = New-Object System.Drawing.Point(12, 12)
        $t.Size      = New-Object System.Drawing.Size(($CardWidth - 24), 44)
        $t.Font      = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
        $t.ForeColor = $cInk
        $t.BackColor = [System.Drawing.Color]::Transparent
        $t.Text      = [string]$opt.Title
        $cardP.Controls.Add($t)

        if ($opt.Subtitle) {
            $sb = New-Object System.Windows.Forms.Label
            $sb.AutoSize  = $false
            $sb.Location  = New-Object System.Drawing.Point(12, 56)
            $sb.Size      = New-Object System.Drawing.Size(($CardWidth - 24), ($CardHeight - 64))
            $sb.Font      = New-Object System.Drawing.Font('Segoe UI', 9)
            $sb.ForeColor = $cMuted
            $sb.BackColor = [System.Drawing.Color]::Transparent
            $sb.Text      = [string]$opt.Subtitle
            $cardP.Controls.Add($sb)
        }

        # hover affordance (capture the two theme colours by value in the closure)
        $enter = { param($s,$e) $s.BackColor = $cHover }.GetNewClosure()
        $leave = { param($s,$e) $s.BackColor = $cBack }.GetNewClosure()
        $cardP.Add_MouseEnter($enter); $cardP.Add_MouseLeave($leave)
        foreach ($child in $cardP.Controls) { $child.Add_MouseEnter($enter); $child.Add_MouseLeave($leave) }

        # click -> OnPick + (rerender | advance | none). Index per-iteration via closure.
        # EAP forced to Continue + a catch that routes to $Wizard.LogError so a bug in
        # an OnPick callback can never escape to the .NET JIT dialog.
        $idx = $i
        $click = {
            param($s, $e)
            $old = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $ci = [int]$s.Tag
                if ($null -ne $OnPick) { & $OnPick $ci $Options[$ci] $Context $Wizard }
                switch ($AfterPick) {
                    'advance'  { $Wizard.Next() }
                    'none'     { $Wizard.Refresh() }
                    default    { $Wizard.Rerender() }
                }
            } catch {
                try { $Wizard.LogError($_, 'choice card click') } catch {}
            } finally {
                $ErrorActionPreference = $old
            }
        }.GetNewClosure()
        $cardP.Add_Click($click)
        foreach ($child in $cardP.Controls) { $child.Tag = $i; $child.Add_Click($click) }

        $Panel.Controls.Add($cardP)
    }
}
