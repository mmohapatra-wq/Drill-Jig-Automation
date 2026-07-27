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
    if ($Context.BushCustom) {
        if ($null -eq $Context.BushCustomOd) { return 'noop' }
        $pick = Resolve-CustomOdPick -OD ([double]$Context.BushCustomOd) -Length ([double]$LenValue) -LenLabel ([string]$LenLabel) -OdLabel ([string]$Context.BushCustomOdLabel)
        [void]$Context.Picks.Add([pscustomobject]@{ HoleDiameter=[double]$pick.OD; BushingID=$pick.ID; BushingLength=[double]$pick.Length; Bushing=$pick.EasyName; PartNumber=$pick.PartNumber; Outcome=$Context.TreeNode.label })
        $Context.PendingSpec = $null; $Context.BushStage = $null; $Context.TreeDone = $true
        return 'done'
    }
    if ($Context.BushOdFirst) {
        if ($null -eq $Context.BushOD) { return 'noop' }
        $pick = Resolve-OdBushingPick -OdGroup $Context.BushOD -Length ([double]$LenValue) -LenLabel ([string]$LenLabel)
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
