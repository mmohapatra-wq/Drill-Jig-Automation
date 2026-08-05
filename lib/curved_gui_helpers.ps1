# ============================================================================
# lib\curved_gui_helpers.ps1 - pure WinForms canvas helpers + the bushing-tree
# walk state machine for drilljig3d-gui.cmd (the curved-jig wizard GUI).
# ============================================================================
# These are PORTED VERBATIM (as `function global:`) from drilljig-gui.cmd so the
# curved GUI reuses the identical, proven canvas primitives WITHOUT editing
# drilljig-gui.cmd. Dot-source AFTER lib\wizard.ps1 (they read $script:WizTheme set
# by Show-Wizard) and AFTER lib\drilljig_core.ps1 (Set-BushLengthPick calls the
# shared catalog resolvers Resolve-OdBushingPick / Resolve-BushingPickRow /
# Resolve-CustomOdPick).
#
# EVERY function is `function global:` -- the wizard's step Build/OnPick handlers run
# inside .GetNewClosure() blocks, and a closure resolves a bare function name against
# GLOBAL scope only (the closure-scope rule in [[project_gui_scope_bugs]]). A plain
# `function Foo` dot-sourced into the .cmd's scriptblock scope would be invisible to
# those handlers.
#
# ALL step state lives in the shared wizard $Context (never a Build-local captured
# var -- the captured-variable rule). These helpers only READ/WRITE $Context and the
# passed WinForms $Panel; they own no module state.
# ============================================================================

# Resolve a friendly colour NAME to a dark-theme-bright RGB (reads $script:WizTheme).
function global:Get-UiColor {
    param([string]$Name)
    $thm = $script:WizTheme
    $ink   = if ($thm) { $thm.Ink }   else { [System.Drawing.Color]::FromArgb(238,242,248) }
    $muted = if ($thm) { $thm.Muted } else { [System.Drawing.Color]::FromArgb(158,172,196) }
    $ok    = if ($thm) { $thm.Ok }    else { [System.Drawing.Color]::FromArgb(120,210,150) }
    $warn  = if ($thm) { $thm.Warn }  else { [System.Drawing.Color]::FromArgb(245,200,90) }
    $err   = if ($thm) { $thm.Err }   else { [System.Drawing.Color]::FromArgb(245,120,110) }
    switch (("" + $Name).ToLower()) {
        ''           { return $ink }
        'gray'       { return $muted }
        'darkgray'   { return $muted }
        'darkgreen'  { return $ok }
        'green'      { return $ok }
        'firebrick'  { return $err }
        'red'        { return $err }
        'yellow'     { return $warn }
        'goldenrod'  { return $warn }
        default      { return $ink }
    }
}

# A word-wrapped, auto-height paragraph label. Fixed width, unbounded height -> text
# wraps + grows DOWN so nothing clips. Callers flow the next control from .Bottom.
function global:Add-Para {
    param($Panel, [string]$Text, [int]$Top = 8, [int]$Height = 0, [string]$ColorName = $null, [bool]$Bold = $false, [int]$Left = 8, [int]$Width = 0)
    $w = if ($Width -gt 0) { $Width } else { [Math]::Max(80, $Panel.Width - $Left - 26) }
    $l = New-Object System.Windows.Forms.Label
    $l.AutoSize    = $true
    $l.MaximumSize = New-Object System.Drawing.Size($w, 0)
    $l.MinimumSize = New-Object System.Drawing.Size($w, 0)
    $l.Location    = New-Object System.Drawing.Point($Left, $Top)
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $l.Font     = New-Object System.Drawing.Font('Segoe UI', 11, $style)
    $l.ForeColor = Get-UiColor $ColorName
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.Text     = $Text
    $Panel.Controls.Add($l)
    return $l
}

# Return a Y just below the lowest control in $Panel (+ gap), or $Min if empty. A
# fall-through block starts its flow here so it can never draw over existing content.
function global:Get-StackTop {
    param($Panel, [int]$Min = 8, [int]$Gap = 10)
    $b = $null
    foreach ($ctl in $Panel.Controls) { try { if ($null -eq $b -or $ctl.Bottom -gt $b) { $b = $ctl.Bottom } } catch {} }
    if ($null -eq $b) { return $Min }
    return ([Math]::Max($Min, [int]$b + $Gap))
}

# A big "look at Creo" arm banner for a pick step (both lines auto-height + wrap).
# Returns the instruction label's .Bottom so the caller flows verify controls below.
function global:Add-ArmBanner {
    param($Panel, [string]$Instruction, [int]$Top = 8)
    $w = [Math]::Max(80, $Panel.Width - 8 - 26)
    $hint = New-Object System.Windows.Forms.Label
    $hint.AutoSize    = $true
    $hint.MaximumSize = New-Object System.Drawing.Size($w, 0)
    $hint.MinimumSize = New-Object System.Drawing.Size($w, 0)
    $hint.Location = New-Object System.Drawing.Point(8, $Top)
    $hint.Font     = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Italic)
    $hint.ForeColor = Get-UiColor 'warn'
    $hint.BackColor = [System.Drawing.Color]::Transparent
    $hint.Text     = ([char]0x2192) + " look at the Creo window"
    $Panel.Controls.Add($hint)

    $instr = New-Object System.Windows.Forms.Label
    $instr.AutoSize    = $true
    $instr.MaximumSize = New-Object System.Drawing.Size($w, 0)
    $instr.MinimumSize = New-Object System.Drawing.Size($w, 0)
    $instr.Location = New-Object System.Drawing.Point(8, ($hint.Bottom + 6))
    $instr.Font     = New-Object System.Drawing.Font('Segoe UI', 13)
    $instr.ForeColor = Get-UiColor ''
    $instr.BackColor = [System.Drawing.Color]::Transparent
    $instr.Text     = $Instruction
    $Panel.Controls.Add($instr)
    return $instr.Bottom
}

# A verify button + result label for a pick step. $OnVerify reads the buffer and
# returns @{ Ok=[bool]; Message=string }; on Ok the caller's $OnVerify stashes into
# $Context, and this enables Next via $Wizard.Refresh. Result label auto-height+wrap.
function global:Add-VerifyControls {
    param($Panel, $Context, $Wizard, [scriptblock]$OnVerify, [int]$Top = 130)
    $thm = $script:WizTheme
    $accent = if ($thm) { $thm.Accent } else { [System.Drawing.Color]::FromArgb(64,132,232) }
    $okCol  = if ($thm) { $thm.Ok }     else { [System.Drawing.Color]::FromArgb(120,210,150) }
    $errCol = if ($thm) { $thm.Err }    else { [System.Drawing.Color]::FromArgb(245,120,110) }
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text     = 'I clicked it - verify'
    $btn.Size     = New-Object System.Drawing.Size(220, 38)
    $btn.Location = New-Object System.Drawing.Point(8, $Top)
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 0
    $btn.BackColor = $accent
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.Font      = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $Panel.Controls.Add($btn)

    $rw = [Math]::Max(80, $Panel.Width - 8 - 26)
    $result = New-Object System.Windows.Forms.Label
    $result.AutoSize    = $true
    $result.MaximumSize = New-Object System.Drawing.Size($rw, 0)
    $result.MinimumSize = New-Object System.Drawing.Size($rw, 0)
    $result.Location = New-Object System.Drawing.Point(8, ($btn.Bottom + 10))
    $result.Font     = New-Object System.Drawing.Font('Segoe UI', 10)
    $result.ForeColor = Get-UiColor ''
    $result.BackColor = [System.Drawing.Color]::Transparent
    $Panel.Controls.Add($result)

    $btn.Add_Click({
        $old = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $res = @{ Ok = $false; Message = 'Nothing was read.' }
            try { $res = & $OnVerify $Context $Wizard } catch { $res = @{ Ok = $false; Message = "Read error: $($_.Exception.Message)" } }
            if ($res.Ok) {
                $result.ForeColor = $okCol
                $result.Text = $res.Message + [Environment]::NewLine + 'Looks good - you can continue.'
            } else {
                $result.ForeColor = $errCol
                $result.Text = $res.Message
            }
            try { $Wizard.Refresh() } catch {}
        } catch {
            try { $Wizard.LogError($_, 'verify click') } catch {}
        } finally {
            $ErrorActionPreference = $old
        }
    }.GetNewClosure())
}

# The "this step already built its geometry" notice for a REVISITED run step:
# green "already built" line + honest "going back does not auto-undo Creo geometry"
# note + a Rebuild button (WARNS, resets the given done-flags, jumps to $GoToKey).
function global:Add-RebuiltNotice {
    param($Panel, $Context, $Wizard, [string]$Message,
          [string[]]$ResetFlags = @(), [hashtable]$ResetValues = $null,
          [string]$GoToKey = $null, [int]$Top = 8)
    $y = (Add-Para $Panel (([char]0x2713) + ' ' + $Message) $Top 0 'DarkGreen' $true).Bottom + 6
    $y = (Add-Para $Panel ("Navigation is free - use Back or click a stage in the breadcrumb to change any earlier choice. " +
                     "This step's geometry is already in Creo and will NOT change on its own. To redo it after changing " +
                     "an earlier selection, click Rebuild below.") $y 0 'gray').Bottom + 10
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = 'Rebuild this step'
    $btn.Size = New-Object System.Drawing.Size(170, 32)
    $btn.Location = New-Object System.Drawing.Point(8, $y)
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 1
    $btn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(120,170,255)
    $btn.BackColor = [System.Drawing.Color]::FromArgb(54,72,112)
    $btn.ForeColor = Get-UiColor ''
    $btn.Add_Click({
        $old = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $ans = $Wizard.AskInline('Rebuild step', ("Rebuild this step?" + [Environment]::NewLine + [Environment]::NewLine +
                "It re-runs the operation and creates NEW geometry in Creo - the previously built feature(s) STAY. " +
                "Delete the old feature(s) in Creo first if you don't want duplicates." + [Environment]::NewLine + [Environment]::NewLine +
                "Proceed?"), 'YesNo')
            if ($ans -ne 'Yes') { return }
            foreach ($f in $ResetFlags) { $Context[$f] = $false }
            if ($null -ne $ResetValues) { foreach ($k in @($ResetValues.Keys)) { $Context[$k] = $ResetValues[$k] } }
            if ($GoToKey) { $Wizard.GoToStepKey($GoToKey) } else { $Wizard.Rerender() }
        } catch { try { $Wizard.LogError($_, 'rebuild click') } catch {} }
        finally { $ErrorActionPreference = $old }
    }.GetNewClosure())
    $Panel.Controls.Add($btn)
}

# ============================================================================
# Bushing CONFIRMATION render (2D schematic + optional 3D) - ported from
# drilljig-gui.cmd so the CURVED GUI shows the SAME picture of the picked bushing on
# the tree-done confirmation page (user 2026-07-29). global: so the tree step's Build
# closure resolves it. Reuses Draw-BushingSchematic / Get-BushingHeadDia (lib\bushing_svg.ps1,
# already global) + Build-BushingModelGroup (lib\wpf3d_preview.ps1). 3D is gated on
# $script:Wpf3dOk (the .cmd sets it after Add-Type'ing the WPF assemblies); when WPF is
# absent the 2D shows full-width. NEVER throws (a paint/WPF failure degrades to 2D-only).
# ============================================================================

# New-BushingViewportHost - a WPF Media3D 3D view of a bushing as a WinForms ElementHost,
# for the confirmation page NEXT TO the 2D schematic. Drill bushings (HeadDia > OD) render
# HEADED; sleeves headless - the SAME distinction the 2D makes (the caller passes HeadDia
# from Get-BushingHeadDia). Drag orbits, wheel zooms. Returns $null on ANY failure so the
# caller falls back to a 2D-only layout (the 3D is a bonus, never a crash). Needs the WPF
# assemblies ($script:Wpf3dOk). PORTED VERBATIM from drilljig-gui.cmd so both GUIs render
# identically. Orbit state lives in captured hashtables (mutated across events).
function global:New-BushingViewportHost {
    param([double]$OD, [double]$ID, [double]$Length, [double]$HeadDia, [int]$Width, [int]$Height, $Background)
    try {
        $vp = New-Object System.Windows.Controls.Viewport3D
        $cam = New-Object System.Windows.Media.Media3D.PerspectiveCamera; $cam.FieldOfView = 46
        $vp.Camera = $cam
        $lg = New-Object System.Windows.Media.Media3D.Model3DGroup
        # NOTE: every collection .Add() below returns an int index; [void]-wrap them so
        # they do NOT leak into this function's output (else the return is an array, not
        # the ElementHost, and $eh3d.Location fails at the call site).
        [void]$lg.Children.Add((New-Object System.Windows.Media.Media3D.AmbientLight([System.Windows.Media.Color]::FromRgb(96,106,126))))
        [void]$lg.Children.Add((New-Object System.Windows.Media.Media3D.DirectionalLight([System.Windows.Media.Color]::FromRgb(255,255,255), (New-Object System.Windows.Media.Media3D.Vector3D(-0.5,-1,-0.6)))))
        [void]$lg.Children.Add((New-Object System.Windows.Media.Media3D.DirectionalLight([System.Windows.Media.Color]::FromRgb(120,150,200), (New-Object System.Windows.Media.Media3D.Vector3D(0.6,-0.3,0.5)))))
        $lv = New-Object System.Windows.Media.Media3D.ModelVisual3D; $lv.Content = $lg; [void]$vp.Children.Add($lv)
        $mv = New-Object System.Windows.Media.Media3D.ModelVisual3D
        $mv.Content = Build-BushingModelGroup -OD $OD -ID $ID -Length $Length -HeadDia $HeadDia -Segments 48
        [void]$vp.Children.Add($mv)
        # iso fit + orbit state (hashtable captured by the handlers => mutation persists)
        $headLen = if ($HeadDia -gt $OD) { $OD * 0.3 } else { 0.0 }
        $Hdim = $Length + $headLen
        $maxDim = [math]::Max([math]::Max($OD, $HeadDia), $Hdim); if ($maxDim -le 0) { $maxDim = 1 }
        $rad0 = ($maxDim / (2*[math]::Tan(($cam.FieldOfView*[math]::PI/180)/2))) * 1.9
        $st = @{ az=0.9; el=0.5; rad=$rad0; cam=$cam }
        $place = {
            $cx = $st.rad*[math]::Cos($st.el)*[math]::Cos($st.az)
            $cy = $st.rad*[math]::Sin($st.el)
            $cz = $st.rad*[math]::Cos($st.el)*[math]::Sin($st.az)
            $st.cam.Position = New-Object System.Windows.Media.Media3D.Point3D($cx,$cy,$cz)
            $st.cam.LookDirection = New-Object System.Windows.Media.Media3D.Vector3D((-$cx),(-$cy),(-$cz))
            $st.cam.UpDirection = New-Object System.Windows.Media.Media3D.Vector3D(0,1,0)
        }.GetNewClosure()
        & $place
        $grid = New-Object System.Windows.Controls.Grid
        $bg = if ($null -ne $Background) { $Background } else { [System.Drawing.Color]::FromArgb(30,42,68) }
        $grid.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb([byte]$bg.R,[byte]$bg.G,[byte]$bg.B))
        [void]$grid.Children.Add($vp)
        $drag = @{ on=$false; lx=0.0; ly=0.0 }
        $grid.Add_MouseDown({ param($s,$e) $p=$e.GetPosition($s); $drag.on=$true; $drag.lx=$p.X; $drag.ly=$p.Y; [void]$s.CaptureMouse() }.GetNewClosure())
        $grid.Add_MouseUp({ param($s,$e) $drag.on=$false; [void]$s.ReleaseMouseCapture() }.GetNewClosure())
        $grid.Add_MouseMove({ param($s,$e)
            if (-not $drag.on) { return }
            $p=$e.GetPosition($s); $dx=$p.X-$drag.lx; $dy=$p.Y-$drag.ly
            $st.az -= $dx*0.01; $st.el += $dy*0.01
            $st.el = [math]::Max(-1.55, [math]::Min(1.55, $st.el)); & $place
            $drag.lx=$p.X; $drag.ly=$p.Y
        }.GetNewClosure())
        $grid.Add_MouseWheel({ param($s,$e)
            $factor = if ($e.Delta -gt 0) { 0.88 } else { 1.136 }
            $st.rad = [math]::Max(0.2, [math]::Min(200.0, $st.rad*$factor)); & $place
        }.GetNewClosure())
        $eh = New-Object System.Windows.Forms.Integration.ElementHost
        $eh.Child = $grid
        return $eh
    } catch { return $null }
}

# Add-BushingConfirmSchematic - render the picked bushing (2D cross-section + optional
# 3D view) onto $Panel starting at $Top, and RETURN the bottom Y so the caller flows its
# Change buttons below. $Active is the last $Context.Picks entry (HoleDiameter / BushingID
# / BushingLength / Bushing). Skips cleanly (returns $Top) for the fixed-OD "no bushing"
# leaf where the bore/length is indeterminate. PORTED from drilljig-gui.cmd:1806-1880.
function global:Add-BushingConfirmSchematic {
    param($Panel, $Active, [int]$Top = 8)
    $y = [int]$Top
    if ($null -eq $Active) { return $y }
    # OD = the drilled hole; Length = bushing length; ID = the bore, "(any)" for the METAL
    # removable path where the bore is operator-chosen (drilled hole IS the OD). Skipped for
    # the fixed-OD "no bushing" leaf (BushingLength null).
    $bsOD  = 0.0; try { $bsOD = [double]$Active.HoleDiameter } catch { $bsOD = 0.0 }
    $bsLen = 0.0; try { if ($null -ne $Active.BushingLength) { $bsLen = [double]$Active.BushingLength } } catch { $bsLen = 0.0 }
    $bsIdVal = 0.0; $bsIdLabel = ''; $bsIdNum = 0.0
    if ($null -ne $Active.BushingID -and [double]::TryParse([string]$Active.BushingID, [ref]$bsIdNum) -and $bsIdNum -gt 0 -and $bsIdNum -lt $bsOD) {
        $bsIdVal = $bsIdNum                                 # a real, known bore (sleeve / ID-first pick)
    } elseif ($bsOD -gt 0) {
        $bsIdVal = $bsOD * 0.5                              # bore indeterminate
        # metal removable = '(any)'; custom OD = '(verify)' (no catalog bushing behind it).
        $bsIdLabel = if ([string]$Active.BushingID -eq '(custom)') { '(verify)' } else { '(any)' }
    }
    if ($bsOD -le 0 -or $bsLen -le 0 -or $bsIdVal -le 0) { return $y }   # nothing sensible to draw

    $bsLabel = [string]$Active.Bushing
    # DRILL BUSHINGS are headed; SLEEVES are headless. A representative head (no dimension)
    # is drawn so the two are not confused.
    $bsHeadDia = Get-BushingHeadDia -EasyName $bsLabel -OD $bsOD
    $bsBack = if ($script:WizTheme) { $script:WizTheme.CanvasBack } else { [System.Drawing.Color]::FromArgb(30,42,68) }
    $wpfOk = $false; try { $wpfOk = [bool]$script:Wpf3dOk } catch { $wpfOk = $false }
    # Layout: 2D schematic + 3D model SIDE BY SIDE; stack them when the canvas is too
    # narrow, or when WPF 3D is unavailable show the 2D full-width.
    $viewH = 290; $gap = 12
    $avail = [Math]::Max(320, $Panel.Width - 24)
    $sideBySide = ($avail -ge 680) -and $wpfOk
    if ($sideBySide) {
        $cellW = [Math]::Min(440, [int][Math]::Floor(($avail - $gap) / 2))
        $x2d = 8; $y2d = $y; $x3d = 8 + $cellW + $gap; $y3d = $y
    } else {
        $cellW = [Math]::Min(600, $avail)
        $x2d = 8; $y2d = $y; $x3d = 8; $y3d = $y + $viewH + 26
    }
    # 2D schematic panel (GDI+ Draw-BushingSchematic)
    $bsPanel = New-Object System.Windows.Forms.Panel
    $bsPanel.Size = New-Object System.Drawing.Size($cellW, $viewH)
    $bsPanel.Location = New-Object System.Drawing.Point($x2d, $y2d)
    $bsPanel.BackColor = $bsBack
    try {
        $dbp = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
        $dbp.SetValue($bsPanel, $true, $null)
    } catch {}
    $bsPanel.Add_Paint({
        param($snd, $ev)
        try {
            Draw-BushingSchematic -Graphics $ev.Graphics -OD $bsOD -ID $bsIdVal -Length $bsLen -HeadDia $bsHeadDia `
                -ClientW $snd.ClientSize.Width -ClientH $snd.ClientSize.Height `
                -ShowEnd $true -ShowDims $true -Background $bsBack -Label $bsLabel -IdLabel $bsIdLabel
        } catch { }
    }.GetNewClosure())
    $Panel.Controls.Add($bsPanel)
    $lastBottom = $bsPanel.Bottom
    # 3D model (WPF Media3D) - a BONUS view beside/below the 2D. On any WPF failure it is
    # simply omitted (the 2D schematic always shows).
    $eh3d = $null
    if ($wpfOk) {
        try { $eh3d = New-BushingViewportHost -OD $bsOD -ID $bsIdVal -Length $bsLen -HeadDia $bsHeadDia -Width $cellW -Height $viewH -Background $bsBack } catch { $eh3d = $null }
    }
    if ($null -ne $eh3d) {
        $eh3d.Location = New-Object System.Drawing.Point($x3d, $y3d)
        $eh3d.Size = New-Object System.Drawing.Size($cellW, $viewH)
        $Panel.Controls.Add($eh3d)
        $cap = New-Object System.Windows.Forms.Label
        $cap.Text = ([char]0x2192 + " 3D: drag to rotate, wheel to zoom")
        $cap.AutoSize = $true; $cap.ForeColor = Get-UiColor 'gray'; $cap.BackColor = [System.Drawing.Color]::Transparent
        $cap.Font = New-Object System.Drawing.Font('Segoe UI', 8)
        $cap.Location = New-Object System.Drawing.Point(($x3d + 2), ($y3d + $viewH + 1))
        $Panel.Controls.Add($cap)
        $lastBottom = [Math]::Max([int]$lastBottom, [int]$cap.Bottom)
    }
    return ([int]$lastBottom + 12)
}

# Set-CurvedChipClearance - derive the conformal-blank inputs from ONE chip-clearance
# value (user 2026-07-29: the operator no longer types thickness/offset). The single
# clearance drives BOTH the wall + the relief:
#   * wall (Thickness)  = the bushing length (the bushing seats through it); a fallback
#     of max(1.5 x hole dia, 0.5") covers the rare fixed-OD "no bushing" leaf where the
#     length is unknown (Fallback=$true in the return so the caller can note it).
#   * ReliefDepth       = the clearance (the symmetric relief-pocket depth).
#   * StandOff          = 0 (offset is always flush; never prompted).
# The conformal-blank engine thickens to wall + ReliefDepth = bushingLen + clearance
# (Invoke-CurvedBlankAction: tEff = Thickness + ReliefDepth), so the finished PART
# thickness = bushing length + chip clearance -- mirroring the flat GUI's
# plate = bushingLen + slotDepth. Assumes $Clearance is already validated (>= 0);
# sets ThicknessValid + ChipClearanceValid true. Returns @{ Wall; Clearance; Total; Fallback }.
# global: so the chip-clearance step's card OnPick + custom-field closures resolve it.
function global:Set-CurvedChipClearance {
    param($Context, [double]$Clearance)
    $c = $Context
    $c.ChipClearance = [double]$Clearance
    $c.ReliefDepth   = [double]$Clearance
    $c.StandOff      = 0.0
    $c.StandOffValid = $true
    $wall = 0.0; $fallback = $false
    try { if ($null -ne $c.BushingLen -and [double]$c.BushingLen -gt 0) { $wall = [double]$c.BushingLen } } catch { $wall = 0.0 }
    if ($wall -le 0) {
        $fallback = $true
        $hd = 0.0; try { if ($null -ne $c.HoleDiaFinal -and [double]$c.HoleDiaFinal -gt 0) { $hd = [double]$c.HoleDiaFinal } } catch { $hd = 0.0 }
        $wall = [Math]::Max((1.5 * $hd), 0.5)
    }
    $c.Thickness      = [double]$wall
    $c.ThicknessValid = $true
    $c.ChipClearanceValid = $true
    return @{ Wall = [double]$wall; Clearance = [double]$Clearance; Total = ([double]$wall + [double]$Clearance); Fallback = [bool]$fallback }
}

# ============================================================================
# Bushing decision-tree WALK state machine (ported from drilljig-gui.cmd) - the
# history stack + the length-pick resolver. State lives in $Context.
# ============================================================================
function global:Push-TreeHistory {
    param($Context)
    if ($null -eq $Context.TreeHistory) { $Context.TreeHistory = [System.Collections.ArrayList]::new() }
    [void]$Context.TreeHistory.Add([pscustomobject]@{
        Node        = $Context.TreeNode
        PathCount   = @($Context.Path).Count
        PendingSpec = $Context.PendingSpec
        BushStage   = $Context.BushStage
        BushID      = $Context.BushID
        BushOdFirst = $Context.BushOdFirst
        BushOdGroups = $Context.BushOdGroups
        BushOD      = $Context.BushOD
        BushOdOptions   = $Context.BushOdOptions
        BushLenValue    = $Context.BushLenValue
        BushLenLabel    = $Context.BushLenLabel
        BushLenIsCustom = $Context.BushLenIsCustom
        BushLenCustomText = $Context.BushLenCustomText
        BushLenValid    = $Context.BushLenValid
        BushCustom      = $Context.BushCustom
        BushCustomOd    = $Context.BushCustomOd
        BushCustomOdLabel = $Context.BushCustomOdLabel
        BushCustomOdText  = $Context.BushCustomOdText
        BushCustomOdValid = $Context.BushCustomOdValid
        Grouped     = $Context.Grouped
        PicksCount  = @($Context.Picks).Count
    })
}
function global:Pop-TreeHistory {
    param($Context)
    if ($null -eq $Context.TreeHistory -or @($Context.TreeHistory).Count -eq 0) { return $false }
    $li = $Context.TreeHistory.Count - 1
    $snap = $Context.TreeHistory[$li]
    $Context.TreeHistory.RemoveAt($li)
    $Context.TreeNode    = $snap.Node
    $Context.PendingSpec = $snap.PendingSpec
    $Context.BushStage   = $snap.BushStage
    $Context.BushID      = $snap.BushID
    $Context.BushOdFirst = $snap.BushOdFirst
    $Context.BushOdGroups = $snap.BushOdGroups
    $Context.BushOD      = $snap.BushOD
    $Context.BushOdOptions   = $snap.BushOdOptions
    $Context.BushLenValue    = $snap.BushLenValue
    $Context.BushLenLabel    = $snap.BushLenLabel
    $Context.BushLenIsCustom = $snap.BushLenIsCustom
    $Context.BushLenCustomText = $snap.BushLenCustomText
    $Context.BushLenValid    = $snap.BushLenValid
    $Context.BushCustom      = $snap.BushCustom
    $Context.BushCustomOd    = $snap.BushCustomOd
    $Context.BushCustomOdLabel = $snap.BushCustomOdLabel
    $Context.BushCustomOdText  = $snap.BushCustomOdText
    $Context.BushCustomOdValid = $snap.BushCustomOdValid
    $Context.Grouped     = $snap.Grouped
    $Context.TreeDone    = $false
    while (@($Context.Path).Count  -gt [int]$snap.PathCount)  { $Context.Path.RemoveAt($Context.Path.Count - 1) }
    while (@($Context.Picks).Count -gt [int]$snap.PicksCount) { $Context.Picks.RemoveAt($Context.Picks.Count - 1) }
    return $true
}
function global:Reset-TreeWalk {
    param($Context)
    $Context.TreeDone = $false; $Context.PendingSpec = $null; $Context.BushStage = $null
    $Context.Grouped = $null; $Context.BushID = $null
    $Context.BushOdFirst = $false; $Context.BushOdGroups = $null; $Context.BushOD = $null
    $Context.BushOdOptions = $null; $Context.BushLenValue = $null; $Context.BushLenLabel = $null
    $Context.BushLenIsCustom = $false; $Context.BushLenCustomText = ''; $Context.BushLenValid = $true
    $Context.BushCustom = $false; $Context.BushCustomOd = $null; $Context.BushCustomOdLabel = $null
    $Context.BushCustomOdText = ''; $Context.BushCustomOdValid = $false
    $Context.TreeNode = $Context.TreeRoot
    if ($null -ne $Context.Path)  { $Context.Path.Clear() }
    if ($null -ne $Context.Picks -and @($Context.Picks).Count -gt 0) { $Context.Picks.Clear() }
    if ($null -ne $Context.TreeHistory) { $Context.TreeHistory.Clear() }
    $Context.HoleDia = $null; $Context.BushingLen = $null
}
# Commit a chosen bushing length into the walk (resolve OD; unique auto-resolves,
# >1 advances to the 'od' tie-break). SHARED by the fixed-length card, the custom
# "Use this length" button, and the recommended-length Next path. Returns
# 'done' | 'od' | 'noop'. Calls the shared drilljig_core resolvers.
function global:Set-BushLengthPick {
    param($Context, [double]$LenValue, [string]$LenLabel)
    $Context.BushLenValue = [double]$LenValue
    $Context.BushLenLabel = [string]$LenLabel
    # NO-BUSHING flag (METAL -> PFD, user 2026-08-04) -- PARITY with drilljig-gui.cmd. In the
    # CURVED GUI this branch is currently DEAD: the curved walk resolves METAL -> PFD via the
    # simpler Get-FixedOdSpec fallback (BushingLength=$null, thickness derived by the chip-
    # clearance step), never a NoBushing PendingSpec. Kept identical so the two verbatim copies
    # do not drift, and correct should the curved walk ever adopt the OD-card no-bushing flow.
    $noBush = ($null -ne $Context.PendingSpec -and $Context.PendingSpec.NoBushing)
    if ($Context.BushCustom) {
        if ($null -eq $Context.BushCustomOd) { return 'noop' }
        $pick = if ($noBush) { Resolve-NoBushingPick -OD ([double]$Context.BushCustomOd) -Length ([double]$LenValue) -LenLabel ([string]$LenLabel) -OdLabel ([string]$Context.BushCustomOdLabel) }
                else          { Resolve-CustomOdPick   -OD ([double]$Context.BushCustomOd) -Length ([double]$LenValue) -LenLabel ([string]$LenLabel) -OdLabel ([string]$Context.BushCustomOdLabel) }
        [void]$Context.Picks.Add([pscustomobject]@{ HoleDiameter=[double]$pick.OD; BushingID=$pick.ID; BushingLength=[double]$pick.Length; Bushing=$pick.EasyName; PartNumber=$pick.PartNumber; Outcome=$Context.TreeNode.label })
        $Context.PendingSpec = $null; $Context.BushStage = $null; $Context.TreeDone = $true
        return 'done'
    }
    if ($Context.BushOdFirst) {
        if ($null -eq $Context.BushOD) { return 'noop' }
        $pick = if ($noBush) { Resolve-NoBushingPick -OD ([double]$Context.BushOD.OD) -Length ([double]$LenValue) -LenLabel ([string]$LenLabel) -OdLabel ([string]$Context.BushOD.ODLabel) }
                else          { Resolve-OdBushingPick -OdGroup $Context.BushOD -Length ([double]$LenValue) -LenLabel ([string]$LenLabel) }
        [void]$Context.Picks.Add([pscustomobject]@{ HoleDiameter=[double]$pick.OD; BushingID=$pick.ID; BushingLength=[double]$pick.Length; Bushing=$pick.EasyName; PartNumber=$pick.PartNumber; Outcome=$Context.TreeNode.label })
        $Context.PendingSpec = $null; $Context.BushStage = $null; $Context.TreeDone = $true
        return 'done'
    }
    if ($null -eq $Context.BushID) { return 'noop' }
    $ods = @($Context.BushOdOptions)
    if (@($ods).Count -gt 1) { $Context.BushStage = 'od'; return 'od' }
    $pick = Resolve-BushingPickRow -IdGroup $Context.BushID -OdOption $ods[0] -Length ([double]$LenValue) -LenLabel ([string]$LenLabel)
    [void]$Context.Picks.Add([pscustomobject]@{ HoleDiameter=[double]$pick.OD; BushingID=$pick.ID; BushingLength=[double]$pick.Length; Bushing=$pick.EasyName; PartNumber=$pick.PartNumber; Outcome=$Context.TreeNode.label })
    $Context.PendingSpec = $null; $Context.BushStage = $null; $Context.TreeDone = $true
    return 'done'
}
