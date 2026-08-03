# ============================================================================
# lib\curved_gui_steps_bushing.ps1 - the Welcome + Bushing step group for the
# curved-jig wizard GUI (drilljig3d-gui.cmd).
# ============================================================================
# Defines ONE global function, Add-CurvedBushingSteps, that appends THREE wizard
# steps to the shared $Steps ArrayList:
#   1. welcome   (Stage 'Welcome') - plain-language overview, no Creo.
#   2. tree      (Stage 'Conditions') - the decision-tree card walk that resolves the
#                hole OD + bushing length. This PORTS the functional core of
#                drilljig-gui.cmd's tree step (~1737-2340) - the SAME walk state
#                machine (curved_gui_helpers.ps1's Push/Pop-TreeHistory,
#                Reset-TreeWalk, Set-BushLengthPick) + the SAME shared catalog
#                resolvers (drilljig_core.ps1) - so behaviour matches the flat GUI.
#                On the DONE confirmation it now ALSO draws the SAME 2D (+ optional
#                WPF 3D) bushing render drilljig-gui shows, via the ported global
#                Add-BushingConfirmSchematic (curved_gui_helpers.ps1). Everything else
#                (OD-first metal, ID-first sleeve, custom-OD, standardized length +
#                Custom, OD tie-break, in-flow Back) is preserved verbatim.
#   3. chip-clearance (Stage 'Conditions') - ONE choice (Standard 0.25" /
#                Tight-custom, green-preselected) that sizes the WHOLE blank. The
#                operator no longer types the wall thickness or the offset (user
#                2026-07-29): the part thickness is DERIVED as bushing length + chip
#                clearance and the offset is always 0. Set-CurvedChipClearance
#                (curved_gui_helpers.ps1) writes $c.Thickness / $c.ReliefDepth /
#                $c.StandOff. Mirrors drilljig-gui.cmd's slot-depth cards.
# (The old free-text 'thickness' + 'standoff' + 'relief-depth' steps are REMOVED --
#  the single chip-clearance card now derives all three values.)
#
# CONTRACT / RULES honoured (see the drilljig3d-gui.cmd header + [[project_gui_scope_bugs]]):
#  - global: on this function so the wizard resolves it after dot-sourcing.
#  - Build/Validate/OnNext handed to New-WizardStep are PLAIN {param(...)} blocks
#    (the framework stores + invokes them; they may call script-scope + global fns).
#  - Any BUTTON/OnPick Add_Click handler inside a Build is .GetNewClosure() and reads
#    ONLY its params + $ctx (the shared $Context) + GLOBAL functions. Build-local
#    state that a closure needs is precomputed + captured (e.g. echo colors) or
#    stashed in $ctx (never a bare Build-local, which a closure cannot see).
#  - No Creo work in these four steps (the tree walk is pure catalog math; the
#    thickness/standoff steps just validate numbers into $ctx). No COM reads at all.
#  - ASCII-only Write-Host (there is none here - all output is WinForms labels).
# ============================================================================

function global:Add-CurvedBushingSteps {
    param($Steps)

    # ========================================================================
    # STEP 1 - WELCOME (Stage 'Welcome'): plain-language overview. No Creo.
    # ========================================================================
    $welcomeStep = New-WizardStep -Key 'welcome' -Title 'Curved Drill Jig Builder' -Stage 'Welcome' -Kind 'info' -PrimaryText 'Get started' `
        -Validate { param($c) return $true } `
        -Build {
            param($panel, $c, $wiz)
            $y = 8
            $y = (Add-Para $panel "This wizard builds a CONFORMAL (curved) drill jig that follows a part's surface, drills bushing holes normal to that surface, and cuts chip-relief pockets. It is INPUT-FIRST: you make all the picks + enter all the numbers up front, then it builds everything hands-free." $y 0 '' $true).Bottom + 12
            $y = (Add-Para $panel "What happens, in order:" $y 0 'gray' $true).Bottom + 6
            $y = (Add-Para $panel ([char]0x2022 + " Fasteners - Ctrl-click the fastener components you want drilled.") $y 0 'gray').Bottom + 4
            $y = (Add-Para $panel ([char]0x2022 + " Surface - click the part surface the jig should follow.") $y 0 'gray').Bottom + 4
            $y = (Add-Para $panel ([char]0x2022 + " Conditions - pick the bushing + hole size, and enter the wall thickness, standoff, and chip-relief depth.") $y 0 'gray').Bottom + 4
            $y = (Add-Para $panel ([char]0x2022 + " Build - one click: the tool builds the conformal blank, rounds the corners, and drills every hole NORMAL to the surface. No Creo picks.") $y 0 'gray').Bottom + 4
            $y = (Add-Para $panel ([char]0x2022 + " Slots - re-select the fasteners once, then draw one chip-relief rectangle per hole (the only remaining interaction).") $y 0 'gray').Bottom + 12
            $y = (Add-Para $panel "When a step asks you to click in Creo (the fasteners, the surface, or to draw a rectangle), the wizard waits until your pick checks out. Activate the drilljig PART inside the assembly first, then press Get started." $y 0 'gray').Bottom + 12
            $y = (Add-Para $panel "Activate the jig PART in Creo (the fastener planes + surface are external references), then press Get started." $y 0 '' $true).Bottom + 8
        }
    [void]$Steps.Add($welcomeStep)

    # ========================================================================
    # STEP 2 - TREE (Stage 'Bushing'): the decision-tree card walk. PORTED from
    # drilljig-gui.cmd ~1737-2340 (schematic omitted - see file header).
    # ========================================================================
    $treeStep = New-WizardStep -Key 'tree' -Title 'Bushing & hole size' -Stage 'Conditions' -Kind 'choice' -PrimaryText 'Next' `
        -Validate {
            param($c)
            if ($c.TreeDone) { return $true }
            # Enable Next at the LENGTH stage when there is a length to commit WITHOUT a
            # click, so the operator can just press Next to take the recommendation.
            # Recommend from custom OD (typed) first, then metal OD-first, then sleeve ID.
            # The OD tie-break ('od') is NEVER auto-committed (OD is the drilled hole).
            if ($null -ne $c.PendingSpec -and $c.BushStage -eq 'len') {
                $lrv = if ($c.BushCustom -and $null -ne $c.BushCustomOd) { [double]$c.BushCustomOd }
                       elseif ($c.BushOdFirst -and $null -ne $c.BushOD) { [double]$c.BushOD.OD }
                       elseif (-not $c.BushOdFirst -and $null -ne $c.BushID) { [double]$c.BushID.ID }
                       else { $null }
                if ($null -eq $lrv) { return $false }
                if ($c.BushLenIsCustom) { return [bool]$c.BushLenValid }
                return ((Get-BushingLengthOptions -Id $lrv).PreselectIndex -ge 0)
            }
            return $false
        } `
        -Build {
            param($panel, $c, $wiz)
            $node = $c.TreeNode

            # ---- DONE? Show a TEXT confirmation (schematic omitted for the curved GUI) --
            if ($c.TreeDone) {
                $active = if (@($c.Picks).Count -gt 0) { $c.Picks[$c.Picks.Count - 1] } else { $null }
                $y = 8
                if ($null -ne $active) {
                    $y = (Add-Para $panel "Bushing selected:" $y 0 'gray' $true).Bottom + 4
                    $y = (Add-Para $panel ([string]$active.Bushing) $y 0 '' $true).Bottom + 6
                    $dia = [double]$active.HoleDiameter
                    $line = ("Hole diameter (= OD): {0}`"" -f $dia)
                    if ($null -ne $active.BushingLength) { $line += ("    Bushing length: {0}`"" -f [double]$active.BushingLength) }
                    $y = (Add-Para $panel $line $y 0 'green').Bottom + 6
                    if ($active.PartNumber -and $active.PartNumber -notmatch 'n/a|unspecified') {
                        $y = (Add-Para $panel ("Part number: {0}" -f $active.PartNumber) $y 0 'gray').Bottom + 6
                    }
                    $y = (Add-Para $panel ([char]0x2713 + " Registered. Press Next to continue, or change the selection below.") $y 0 'green' $true).Bottom + 10
                    # CUSTOM-OD warning: a typed hole OD has no catalog bushing behind it.
                    if ([string]$active.BushingID -eq '(custom)') {
                        $y = (Add-Para $panel ([char]0x26A0 + " Custom hole OD -- verify a drill bushing / bushing sleeve at this OD actually exists before machining.") $y 0 'yellow' $true).Bottom + 10
                    }
                    # DISPLAY-ONLY bushing render (user 2026-07-29): the SAME 2D cross-section
                    # (+ optional WPF 3D) drilljig-gui shows. No controls, no save -- just a
                    # picture of the picked bushing. Skipped for the fixed-OD "no bushing" leaf
                    # (BushingLength null -> Add-BushingConfirmSchematic returns $y unchanged).
                    $y = (Add-BushingConfirmSchematic -Panel $panel -Active $active -Top $y)
                } else {
                    $y = (Add-Para $panel "Selection complete (no catalog bushing was resolved)." $y 0 'gray').Bottom + 10
                }
                # Change buttons: "< Back to options" pops ONE decision; "Start over" resets.
                # BOTH read root/history from the CONTEXT ($c.*), never a top-level $treeRoot
                # (a closure does not capture the .cmd's $treeRoot).
                $thm = $script:WizTheme
                $bx = 8
                if (@($c.TreeHistory).Count -gt 0) {
                    $btnBackOne = New-Object System.Windows.Forms.Button
                    $btnBackOne.Text = ([char]0x2039) + ' Back to options'
                    $btnBackOne.Size = New-Object System.Drawing.Size(170, 34)
                    $btnBackOne.Location = New-Object System.Drawing.Point($bx, $y)
                    $btnBackOne.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
                    $btnBackOne.FlatAppearance.BorderSize = 1
                    $btnBackOne.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(120,170,255)
                    $btnBackOne.BackColor = [System.Drawing.Color]::FromArgb(54,72,112)
                    $btnBackOne.ForeColor = [System.Drawing.Color]::White
                    $btnBackOne.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
                    $btnBackOne.Add_Click({
                        $old = $ErrorActionPreference
                        try { $ErrorActionPreference = 'Continue'; [void](Pop-TreeHistory -Context $c); $wiz.Rerender() }
                        catch { try { $wiz.LogError($_, 'bushing back one') } catch {} }
                        finally { $ErrorActionPreference = $old }
                    }.GetNewClosure())
                    $panel.Controls.Add($btnBackOne)
                    $bx += 182
                }
                $btnChange = New-Object System.Windows.Forms.Button
                $btnChange.Text = 'Start over'
                $btnChange.Size = New-Object System.Drawing.Size(140, 34)
                $btnChange.Location = New-Object System.Drawing.Point($bx, $y)
                $btnChange.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
                $btnChange.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90,104,132)
                $btnChange.BackColor = if ($thm) { $thm.CanvasBack } else { [System.Drawing.Color]::FromArgb(30,42,68) }
                $btnChange.ForeColor = Get-UiColor ''
                $btnChange.Add_Click({
                    $old = $ErrorActionPreference
                    try { $ErrorActionPreference = 'Continue'; Reset-TreeWalk -Context $c; $wiz.Rerender() }
                    catch { try { $wiz.LogError($_, 'change bushing') } catch {} }
                    finally { $ErrorActionPreference = $old }
                }.GetNewClosure())
                $panel.Controls.Add($btnChange)
                return
            }

            # ---- IN-FLOW back: pop ONE decision during the walk -----------------
            $walkTop = 8
            if (@($c.TreeHistory).Count -gt 0) {
                $btnWalkBack = New-Object System.Windows.Forms.Button
                $btnWalkBack.Text = ([char]0x2039) + ' Back'
                $btnWalkBack.Size = New-Object System.Drawing.Size(90, 30)
                $btnWalkBack.Location = New-Object System.Drawing.Point(8, 6)
                $btnWalkBack.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
                $btnWalkBack.FlatAppearance.BorderSize = 1
                $btnWalkBack.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(120,170,255)
                $btnWalkBack.BackColor = [System.Drawing.Color]::FromArgb(54,72,112)
                $btnWalkBack.ForeColor = [System.Drawing.Color]::White
                $btnWalkBack.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
                $btnWalkBack.Add_Click({
                    $old = $ErrorActionPreference
                    try { $ErrorActionPreference = 'Continue'; [void](Pop-TreeHistory -Context $c); $wiz.Rerender() }
                    catch { try { $wiz.LogError($_, 'bushing walk back') } catch {} }
                    finally { $ErrorActionPreference = $old }
                }.GetNewClosure())
                $panel.Controls.Add($btnWalkBack)
                $walkTop = 46
            }

            # ---- Mid bushing-pick sub-flow (a spec is pending) ------------------
            if ($null -ne $c.PendingSpec) {
                $rows = Get-CatalogRows -Spec $c.PendingSpec
                if ($rows.Count -eq 0) {
                    Add-Para $panel ("No catalog rows match this branch. (file: " + (Split-Path $c.PendingSpec.File -Leaf) + ")") 8 0 'Firebrick'
                    $c.PendingSpec = $null; $c.TreeDone = $true
                    return
                }
                # OD-FIRST metal path: OD cards (no ID question), then the standardized length.
                # Persist OD groups in $c.BushOdGroups (never a Build-local).
                if ($c.BushOdFirst) {
                    $c.BushOdGroups = Get-OdGroups -Rows $rows
                    if ($c.BushStage -eq 'od1' -or $null -eq $c.BushStage) {
                        $hdrB = (Add-Para $panel "Select removable bushing OD:" $walkTop 0 $null $true).Bottom
                        $opts = @()
                        foreach ($og in $c.BushOdGroups) { $opts += @{ Title = ('OD ' + $og.ODLabel); Subtitle = ("-> hole {0:0.###}`"" -f $og.OD) } }
                        $opts += @{ Title = 'Custom hole OD...'; Subtitle = 'type any diameter' }
                        Add-WizardChoiceCards -Panel $panel -Options $opts -Context $c -Wizard $wiz -Top ($hdrB + 10) -CardWidth 200 -CardHeight 96 -OnPick {
                            param($i,$opt,$cc,$w)
                            Push-TreeHistory -Context $cc
                            if ($i -ge @($cc.BushOdGroups).Count) {
                                $cc.BushCustom = $true; $cc.BushOdFirst = $false; $cc.BushOD = $null
                                $cc.BushStage = 'customod'
                                $cc.BushCustomOdText = ''; $cc.BushCustomOdValid = $false; $cc.BushCustomOd = $null; $cc.BushCustomOdLabel = $null
                                return
                            }
                            $cc.BushOD = @($cc.BushOdGroups)[$i]
                            $cc.BushStage = 'len'
                            $cc.BushLenIsCustom = $false; $cc.BushLenCustomText = ''; $cc.BushLenValid = $true
                        }
                        return
                    }
                }
                # ID-FIRST sleeve path: stash grouped catalog in $c.Grouped (never a Build-local).
                if (-not $c.BushOdFirst) { $c.Grouped = Group-CatalogByID -Rows $rows }
                if (-not $c.BushOdFirst -and ($c.BushStage -eq 'id' -or $null -eq $c.BushStage)) {
                    $hdrB = (Add-Para $panel "Select DJ hole diameter:" $walkTop 0 $null $true).Bottom
                    $opts = @()
                    foreach ($g in $c.Grouped) {
                        $ods = Get-IdOdOptions -IdGroup $g
                        $sub = if (@($ods).Count -eq 1) { ("-> hole {0:0.###}`"" -f $ods[0].OD) } else { ("{0} OD options" -f @($ods).Count) }
                        $opts += @{ Title = ('ID ' + $g.IDLabel); Subtitle = $sub }
                    }
                    $opts += @{ Title = 'Custom hole OD...'; Subtitle = 'type any diameter' }
                    Add-WizardChoiceCards -Panel $panel -Options $opts -Context $c -Wizard $wiz -Top ($hdrB + 10) -OnPick {
                        param($i,$opt,$cc,$w)
                        Push-TreeHistory -Context $cc
                        if ($i -ge @($cc.Grouped).Count) {
                            $cc.BushCustom = $true; $cc.BushOdFirst = $false; $cc.BushOD = $null; $cc.BushID = $null; $cc.BushOdOptions = $null
                            $cc.BushStage = 'customod'
                            $cc.BushCustomOdText = ''; $cc.BushCustomOdValid = $false; $cc.BushCustomOd = $null; $cc.BushCustomOdLabel = $null
                            return
                        }
                        $cc.BushID = $cc.Grouped[$i]
                        $cc.BushOdOptions = Get-IdOdOptions -IdGroup $cc.BushID
                        $cc.BushStage = 'len'
                        $cc.BushLenIsCustom = $false; $cc.BushLenCustomText = ''; $cc.BushLenValid = $true
                    }
                    return
                }
                # CUSTOM-OD sub-state: inline OD textbox + "Use this OD" (NOT a modal).
                if ($c.BushStage -eq 'customod') {
                    $y = (Add-Para $panel "Custom hole OD -- type any diameter (NOT limited to the catalog):" $walkTop 0 $null $true).Bottom + 6
                    $y = (Add-Para $panel ([char]0x26A0 + " No catalog bushing backs a typed OD. Verify a drill bushing / bushing") $y 0 'yellow' $true).Bottom
                    $y = (Add-Para $panel "   sleeve at this OD actually EXISTS before machining." $y 0 'yellow' $true).Bottom + 8
                    $lab = New-Object System.Windows.Forms.Label
                    $lab.Text = 'Hole OD (in):'; $lab.Location = New-Object System.Drawing.Point(8, ($y + 3)); $lab.Size = New-Object System.Drawing.Size(94, 20)
                    $lab.ForeColor = Get-UiColor ''; $lab.BackColor = [System.Drawing.Color]::Transparent
                    $panel.Controls.Add($lab)
                    $tbOd = New-Object System.Windows.Forms.TextBox
                    $tbOd.Location = New-Object System.Drawing.Point(106, $y); $tbOd.Size = New-Object System.Drawing.Size(90, 24)
                    $tbOd.Text = [string]$c.BushCustomOdText
                    $tbOd.BackColor = [System.Drawing.Color]::FromArgb(16,24,42); $tbOd.ForeColor = Get-UiColor ''; $tbOd.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
                    $panel.Controls.Add($tbOd)
                    $lblOdEcho = New-Object System.Windows.Forms.Label
                    $lblOdEcho.AutoSize = $true; $lblOdEcho.MaximumSize = New-Object System.Drawing.Size(560, 0)
                    $lblOdEcho.Location = New-Object System.Drawing.Point(8, ($y + 34)); $lblOdEcho.BackColor = [System.Drawing.Color]::Transparent
                    $panel.Controls.Add($lblOdEcho)
                    # Precompute echo colors OUTSIDE the closure (Get-UiColor is global, but the
                    # captured colors avoid a per-keystroke resolve; same pattern as drilljig-gui).
                    $okColOd   = Get-UiColor 'green'
                    $warnColOd = Get-UiColor 'yellow'
                    $updateOdEcho = {
                        $res = Resolve-CustomOdInput -Text $tbOd.Text
                        $c.BushCustomOdText = [string]$tbOd.Text
                        if ($res.Ok) {
                            $c.BushCustomOd = [double]$res.Value; $c.BushCustomOdLabel = ('{0:0.###}' -f [double]$res.Value); $c.BushCustomOdValid = $true
                            $lblOdEcho.ForeColor = $okColOd
                            $lblOdEcho.Text = ("Hole OD {0:0.###}`" -- press Use this OD." -f [double]$res.Value)
                        } else {
                            $c.BushCustomOdValid = $false
                            $lblOdEcho.ForeColor = $warnColOd
                            $lblOdEcho.Text = $res.Error
                        }
                    }.GetNewClosure()
                    $tbOd.Add_TextChanged({ param($s,$e) & $updateOdEcho }.GetNewClosure())
                    & $updateOdEcho
                    $y = $lblOdEcho.Bottom + 12
                    $btnUseOd = New-Object System.Windows.Forms.Button
                    $btnUseOd.Text = 'Use this OD'
                    $btnUseOd.Size = New-Object System.Drawing.Size(140, 30)
                    $btnUseOd.Location = New-Object System.Drawing.Point(8, $y)
                    $btnUseOd.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
                    $btnUseOd.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(120,170,255)
                    $btnUseOd.BackColor = [System.Drawing.Color]::FromArgb(54,72,112)
                    $btnUseOd.ForeColor = [System.Drawing.Color]::White
                    $btnUseOd.Add_Click({
                        $old = $ErrorActionPreference
                        try {
                            $ErrorActionPreference = 'Continue'
                            $res = Resolve-CustomOdInput -Text $tbOd.Text
                            if (-not $res.Ok) { $c.BushCustomOdValid = $false; & $updateOdEcho; try { $wiz.Refresh() } catch {}; return }
                            Push-TreeHistory -Context $c
                            $c.BushCustomOd = [double]$res.Value; $c.BushCustomOdLabel = ('{0:0.###}' -f [double]$res.Value)
                            $c.BushStage = 'len'
                            $c.BushLenIsCustom = $false; $c.BushLenCustomText = ''; $c.BushLenValid = $true
                            $wiz.Rerender()
                        } catch { try { $wiz.LogError($_, 'custom OD') } catch {} }
                        finally { $ErrorActionPreference = $old }
                    }.GetNewClosure())
                    $panel.Controls.Add($btnUseOd)
                    return
                }
                # LENGTH stage: shared by ID-first (sleeve) + OD-first (metal) + custom-OD.
                if ($c.BushStage -eq 'len') {
                    $isOdFirst = [bool]$c.BushOdFirst
                    if ($c.BushCustom)  { $bushKind = 'OD'; $recVal = [double]$c.BushCustomOd; $recLabel = [string]$c.BushCustomOdLabel }
                    elseif ($isOdFirst) { $bushKind = 'OD'; $recVal = [double]$c.BushOD.OD; $recLabel = [string]$c.BushOD.ODLabel }
                    else                { $bushKind = 'ID'; $recVal = [double]$c.BushID.ID; $recLabel = [string]$c.BushID.IDLabel }
                    $lenOpt = Get-BushingLengthOptions -Id $recVal
                    $preIdx = [int]$lenOpt.PreselectIndex
                    if (-not $c.BushLenIsCustom) {
                        # FIXED menu: {1/2, 3/4, 1, Custom...} with the recommendation marked.
                        $recTxt = if ($preIdx -ge 0) { ("recommended for {0} {1}" -f $bushKind, $recLabel) } else { '' }
                        $hdrB = (Add-Para $panel ("{0} {1}  ->  select bushing length:" -f $bushKind, $recLabel) $walkTop 0 $null $true).Bottom
                        if ($preIdx -ge 0) { $hdrB = (Add-Para $panel ([char]0x2713 + (" {0}`" is standard for a {1}`" {2} -- recommended." -f $lenOpt.Options[$preIdx].Label, $recLabel, $bushKind)) ($hdrB + 4) 0 'green').Bottom }
                        $opts = @()
                        for ($li = 0; $li -lt @($lenOpt.Options).Count; $li++) {
                            $o = $lenOpt.Options[$li]
                            if ($o.IsCustom) { $opts += @{ Title = 'Custom...'; Subtitle = 'type any length' } }
                            else { $opts += @{ Title = ($o.Label + '" Lg'); Subtitle = $(if ($li -eq $preIdx) { $recTxt } else { '' }) } }
                        }
                        Add-WizardChoiceCards -Panel $panel -Options $opts -Context $c -Wizard $wiz -Top ($hdrB + 10) -CardWidth 190 -CardHeight 90 -HighlightIndex $preIdx -OnPick {
                            param($i,$opt,$cc,$w)
                            Push-TreeHistory -Context $cc
                            $lrv = if ($cc.BushCustom) { [double]$cc.BushCustomOd } elseif ($cc.BushOdFirst) { [double]$cc.BushOD.OD } else { [double]$cc.BushID.ID }
                            $lopt = (Get-BushingLengthOptions -Id $lrv).Options[$i]
                            if ($lopt.IsCustom) { $cc.BushLenIsCustom = $true; return }
                            [void](Set-BushLengthPick -Context $cc -LenValue ([double]$lopt.Value) -LenLabel ([string]$lopt.Label))
                        }
                        return
                    }
                    # CUSTOM sub-state: inline textbox + "Use this length" (NOT a modal).
                    $def = if ($preIdx -ge 0) { [double]$lenOpt.Options[$preIdx].Value } else { 0.5 }
                    $y = (Add-Para $panel ("{0} {1}  ->  enter a custom bushing length (inches):" -f $bushKind, $recLabel) $walkTop 0 $null $true).Bottom + 8
                    $lab = New-Object System.Windows.Forms.Label
                    $lab.Text = 'Length (in):'; $lab.Location = New-Object System.Drawing.Point(8, ($y + 3)); $lab.Size = New-Object System.Drawing.Size(90, 20)
                    $lab.ForeColor = Get-UiColor ''; $lab.BackColor = [System.Drawing.Color]::Transparent
                    $panel.Controls.Add($lab)
                    $tb = New-Object System.Windows.Forms.TextBox
                    $tb.Location = New-Object System.Drawing.Point(102, $y); $tb.Size = New-Object System.Drawing.Size(90, 24)
                    $tb.Text = [string]$c.BushLenCustomText
                    $tb.BackColor = [System.Drawing.Color]::FromArgb(16,24,42); $tb.ForeColor = Get-UiColor ''; $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
                    $panel.Controls.Add($tb)
                    $lblEcho = New-Object System.Windows.Forms.Label
                    $lblEcho.AutoSize = $true; $lblEcho.MaximumSize = New-Object System.Drawing.Size(560, 0)
                    $lblEcho.Location = New-Object System.Drawing.Point(8, ($y + 34)); $lblEcho.BackColor = [System.Drawing.Color]::Transparent
                    $panel.Controls.Add($lblEcho)
                    # Precompute echo colors OUTSIDE the closure (see the drilljig-gui note).
                    $okCol   = Get-UiColor 'green'
                    $warnCol = Get-UiColor 'warn'
                    $updateEcho = {
                        $res = Resolve-BushingLengthInput -Text $tb.Text -Default $def
                        $c.BushLenCustomText = [string]$tb.Text
                        if ($res.Ok) {
                            $c.BushLenValue = [double]$res.Value; $c.BushLenValid = $true
                            $lblEcho.ForeColor = $okCol
                            $lblEcho.Text = ("Length {0:0.###}`" -- press Use this length." -f [double]$res.Value)
                        } else {
                            $c.BushLenValid = $false
                            $lblEcho.ForeColor = $warnCol
                            $lblEcho.Text = $res.Error
                        }
                    }.GetNewClosure()
                    $tb.Add_TextChanged({ param($s,$e) & $updateEcho }.GetNewClosure())
                    & $updateEcho
                    $y = $lblEcho.Bottom + 12
                    $btnUse = New-Object System.Windows.Forms.Button
                    $btnUse.Text = 'Use this length'
                    $btnUse.Size = New-Object System.Drawing.Size(140, 30)
                    $btnUse.Location = New-Object System.Drawing.Point(8, $y)
                    $btnUse.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
                    $btnUse.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(120,170,255)
                    $btnUse.BackColor = [System.Drawing.Color]::FromArgb(54,72,112)
                    $btnUse.ForeColor = [System.Drawing.Color]::White
                    $btnUse.Add_Click({
                        $old = $ErrorActionPreference
                        try {
                            $ErrorActionPreference = 'Continue'
                            $res = Resolve-BushingLengthInput -Text $tb.Text -Default $def
                            if (-not $res.Ok) { $c.BushLenValid = $false; & $updateEcho; try { $wiz.Refresh() } catch {}; return }
                            Push-TreeHistory -Context $c
                            $c.BushLenIsCustom = $false
                            $lv = [double]$res.Value
                            [void](Set-BushLengthPick -Context $c -LenValue $lv -LenLabel ('{0:0.###}' -f $lv))
                            $wiz.Rerender()
                        } catch { try { $wiz.LogError($_, 'bushing custom length') } catch {} }
                        finally { $ErrorActionPreference = $old }
                    }.GetNewClosure())
                    $panel.Controls.Add($btnUse)
                    $btnBackFixed = New-Object System.Windows.Forms.Button
                    $btnBackFixed.Text = '< Length options'
                    $btnBackFixed.Size = New-Object System.Drawing.Size(140, 30)
                    $btnBackFixed.Location = New-Object System.Drawing.Point(156, $y)
                    $btnBackFixed.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
                    $btnBackFixed.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90,104,132)
                    $btnBackFixed.BackColor = if ($script:WizTheme) { $script:WizTheme.CanvasBack } else { [System.Drawing.Color]::FromArgb(30,42,68) }
                    $btnBackFixed.ForeColor = Get-UiColor ''
                    $btnBackFixed.Add_Click({
                        $old = $ErrorActionPreference
                        try { $ErrorActionPreference = 'Continue'; $c.BushLenIsCustom = $false; $wiz.Rerender() }
                        catch { try { $wiz.LogError($_, 'bushing custom back') } catch {} }
                        finally { $ErrorActionPreference = $old }
                    }.GetNewClosure())
                    $panel.Controls.Add($btnBackFixed)
                    return
                }
                # OD TIE-BREAK: this bore is available at more than one OD. OD IS the hole.
                if ($c.BushStage -eq 'od') {
                    $id = $c.BushID; $ods = @($c.BushOdOptions)
                    $hdrB = (Add-Para $panel ("ID {0} is available at more than one OD - OD IS the hole, pick it:" -f $id.IDLabel) $walkTop 0 $null $true).Bottom
                    $opts = @()
                    foreach ($od in $ods) { $opts += @{ Title = ('OD ' + $od.ODLabel); Subtitle = ("hole {0:0.###}`"" -f $od.OD) } }
                    Add-WizardChoiceCards -Panel $panel -Options $opts -Context $c -Wizard $wiz -Top ($hdrB + 10) -CardWidth 200 -CardHeight 96 -OnPick {
                        param($i,$opt,$cc,$w)
                        Push-TreeHistory -Context $cc
                        $pick = Resolve-BushingPickRow -IdGroup $cc.BushID -OdOption (@($cc.BushOdOptions)[$i]) -Length ([double]$cc.BushLenValue) -LenLabel ([string]$cc.BushLenLabel)
                        [void]$cc.Picks.Add([pscustomobject]@{ HoleDiameter=[double]$pick.OD; BushingID=$pick.ID; BushingLength=[double]$pick.Length; Bushing=$pick.EasyName; PartNumber=$pick.PartNumber; Outcome=$cc.TreeNode.label })
                        $cc.PendingSpec = $null; $cc.BushStage = $null; $cc.TreeDone = $true
                    }
                    return
                }
            }

            # ---- Normal tree descent --------------------------------------------
            if ($null -eq $node) { $c.TreeDone = $true; Add-Para $panel "Tree finished." $walkTop; return }
            switch ($node.kind) {
                'question' {
                    $kids = @($node.children)
                    $qB = (Add-Para $panel ([string]$node.label) $walkTop 0 $null $true).Bottom + 6
                    if ($node.notes) { $qB = (Add-Para $panel ([string]$node.notes) $qB 0 'Gray').Bottom + 6 }
                    $opts = @()
                    foreach ($k in $kids) { $opts += @{ Title = [string]$k.label; Subtitle = '' } }
                    Add-WizardChoiceCards -Panel $panel -Options $opts -Context $c -Wizard $wiz -Top ($qB + 6) -OnPick {
                        param($i,$opt,$cc,$w)
                        Push-TreeHistory -Context $cc
                        $chosen = @($cc.TreeNode.children)[$i]
                        [void]$cc.Path.Add([string]$chosen.label)
                        $next = $chosen
                        while ($next.kind -eq 'option' -and @($next.children).Count -ge 1) { $next = @($next.children)[0] }
                        $cc.TreeNode = $next
                        if ($next.kind -eq 'outcome') {
                            $spec = Get-CatalogSpec -Label $next.label
                            if ($spec) {
                                $cc.PendingSpec = $spec
                                if (Test-OdFirstSpec -Spec $spec) { $cc.BushOdFirst = $true;  $cc.BushStage = 'od1' }
                                else                              { $cc.BushOdFirst = $false; $cc.BushStage = 'id' }
                            } else {
                                $fixed = Get-FixedOdSpec -Label $next.label
                                if ($null -ne $fixed) {
                                    [void]$cc.Picks.Add([pscustomobject]@{ HoleDiameter=[double]$fixed; BushingLength=$null; Bushing='(fixed OD, no bushing)'; PartNumber='(n/a)'; Outcome=$next.label })
                                }
                                $cc.TreeDone = $true
                            }
                        }
                    }
                    return
                }
                'outcome' {
                    $spec = Get-CatalogSpec -Label $node.label
                    if ($spec) {
                        $c.PendingSpec = $spec
                        if (Test-OdFirstSpec -Spec $spec) { $c.BushOdFirst = $true;  $c.BushStage = 'od1' }
                        else                              { $c.BushOdFirst = $false; $c.BushStage = 'id' }
                        $wiz.Rerender(); return
                    }
                    $fixed = Get-FixedOdSpec -Label $node.label
                    if ($null -ne $fixed) {
                        [void]$c.Picks.Add([pscustomobject]@{ HoleDiameter=[double]$fixed; BushingLength=$null; Bushing='(fixed OD, no bushing)'; PartNumber='(n/a)'; Outcome=$node.label })
                    }
                    Add-Para $panel ([string]$node.label) $walkTop 0
                    $c.TreeDone = $true
                    return
                }
                default {
                    $kids = @($node.children)
                    if ($kids.Count -ge 1) { $c.TreeNode = $kids[0]; $wiz.Rerender(); return }
                    $c.TreeDone = $true
                }
            }
        } `
        -OnNext {
            param($c, $wiz)
            # PRESS-NEXT-TO-TAKE-THE-RECOMMENDATION: at the LENGTH stage (not TreeDone),
            # Next commits the recommended (or entered custom) length, then RE-RENDERS
            # (return $false = don't advance). An OD tie-break is NOT auto-committed.
            $lenReady = ($null -ne $c.PendingSpec -and $c.BushStage -eq 'len' -and
                         (($c.BushCustom -and $null -ne $c.BushCustomOd) -or ($c.BushOdFirst -and $null -ne $c.BushOD) -or (-not $c.BushOdFirst -and $null -ne $c.BushID)))
            if (-not $c.TreeDone -and $lenReady) {
                Push-TreeHistory -Context $c
                if ($c.BushLenIsCustom) {
                    $res = Resolve-BushingLengthInput -Text $c.BushLenCustomText -Default 0.5
                    if (-not $res.Ok) { return $false }
                    $c.BushLenIsCustom = $false
                    [void](Set-BushLengthPick -Context $c -LenValue ([double]$res.Value) -LenLabel ('{0:0.###}' -f [double]$res.Value))
                } else {
                    $lrv = if ($c.BushCustom) { [double]$c.BushCustomOd } elseif ($c.BushOdFirst) { [double]$c.BushOD.OD } else { [double]$c.BushID.ID }
                    $lenOpt = Get-BushingLengthOptions -Id $lrv
                    $pre = [int]$lenOpt.PreselectIndex
                    if ($pre -lt 0) { return $false }
                    $lopt = $lenOpt.Options[$pre]
                    [void](Set-BushLengthPick -Context $c -LenValue ([double]$lopt.Value) -LenLabel ([string]$lopt.Label))
                }
                $wiz.Rerender()
                return $false
            }
            # Finalise into the shared vars (last pick wins).
            if (@($c.Picks).Count -gt 0) {
                $active = $c.Picks[$c.Picks.Count - 1]
                $c.HoleDia = [double]$active.HoleDiameter
                $c.HoleDiaFinal = [double]$active.HoleDiameter
                if ($null -ne $active.BushingLength) { $c.BushingLen = [double]$active.BushingLength }
                # honesty chip: name the picked bushing.
                $wiz.SetChip('bushing', ("bushing: " + [string]$active.Bushing), 'set')
                if ($null -ne $c.HoleDia)    { $wiz.SetChip('hole',  ("hole {0:0.###}`"" -f $c.HoleDia), 'set') }
                if ($null -ne $c.BushingLen) { $wiz.SetChip('depth', ("depth {0:0.###}`"" -f $c.BushingLen), 'set') }
            }
            # 3D-print vs metal is derived from the walked path (only the root material
            # option ever puts a "3d print" label into $c.Path).
            $c.Is3dPrint = @($c.Path | Where-Object { $_ -match '(?i)3d\s*print' }).Count -gt 0
            return $true
        }
    [void]$Steps.Add($treeStep)

    # ========================================================================
    # STEP 3 - CHIP CLEARANCE (Stage 'Conditions'): ONE choice that sizes the whole
    # blank. The operator no longer types the wall thickness OR the offset (user
    # 2026-07-29): the offset is always 0 (flush), and the part thickness is DERIVED as
    # bushing length + chip clearance (mirroring the flat GUI's plate = bushingLen +
    # slotDepth). Two cards -- "Standard clearance" (0.25", green-preselected) and
    # "Tight / custom" (type your own) -- exactly like drilljig-gui.cmd's slot-depth
    # step. Set-CurvedChipClearance (curved_gui_helpers.ps1) does the derivation into
    # $c.Thickness (wall = bushingLen, or a fallback for the no-bushing leaf), $c.ReliefDepth
    # (= clearance), and $c.StandOff (= 0). The conformal-blank engine then thickens to
    # wall + relief = bushingLen + clearance. Validate/OnNext gate on ChipClearanceValid.
    # ========================================================================
    $clearanceStep = New-WizardStep -Key 'chip-clearance' -Title 'Chip clearance' -Stage 'Conditions' -Kind 'choice' -PrimaryText 'Next' `
        -Validate {
            param($c)
            # Standard (the seeded default) is ALWAYS valid, so Next is enabled on entry
            # (the fix for "Next not working"). Only custom must have a valid typed value.
            if ($c.ClearanceMode -eq 'custom') { return [bool]$c.ChipClearanceValid }
            return $true
        } `
        -Build {
            param($panel, $c, $wiz)
            # Seed the standard default (0.25, or the --slot-depth/--relief-depth flag) on
            # first entry so the recommended card is meaningful.
            if ($null -eq $c.ChipClearance) {
                $seed = 0.25
                try { if ($null -ne $c.SlotDepthAbs -and [double]$c.SlotDepthAbs -gt 0) { $seed = [double]$c.SlotDepthAbs } } catch { $seed = 0.25 }
                $c.ChipClearance = [double]$seed
            }
            # SEED the mode to 'standard' on first entry so Next is ENABLED immediately (the
            # preselected default). Without this, ClearanceMode was $null -> Validate false ->
            # Next disabled until a card click (the reported "Next not working"). The cards
            # stay visible below so the operator can still switch to custom.
            if ($null -eq $c.ClearanceMode) { $c.ClearanceMode = 'standard' }
            # bushing length (for the derived-thickness echo); fallback wall when unknown.
            $bl = 0.0; try { if ($null -ne $c.BushingLen -and [double]$c.BushingLen -gt 0) { $bl = [double]$c.BushingLen } } catch { $bl = 0.0 }
            $wallFallback = 0.0
            if ($bl -le 0) {
                $hd = 0.0; try { if ($null -ne $c.HoleDiaFinal -and [double]$c.HoleDiaFinal -gt 0) { $hd = [double]$c.HoleDiaFinal } } catch { $hd = 0.0 }
                $wallFallback = [Math]::Max((1.5 * $hd), 0.5)
            }
            $wallNow = if ($bl -gt 0) { $bl } else { $wallFallback }

            $y = (Add-Para $panel "Chip clearance sizes the jig. Each fastener hole gets a shallow SYMMETRIC relief pocket cut on its TOP plane to clear chips/debris while drilling, and the blank is thickened by this same amount so there is material to remove." 8 0 'gray').Bottom + 6
            $thkLine = if ($bl -gt 0) {
                ("Part thickness is AUTOMATIC: bushing length {0:0.###}`" + chip clearance. The offset is always 0 (flush) -- you are not asked for either." -f $bl)
            } else {
                ("Part thickness is AUTOMATIC: jig wall {0:0.###}`" (no bushing length on this leaf -- fallback ~1.5x the hole dia) + chip clearance. The offset is always 0 (flush)." -f $wallFallback)
            }
            $y = (Add-Para $panel $thkLine $y 0 'gray').Bottom + 12

            # ALWAYS show the two cards (green border on the ACTIVE mode) so the default is
            # preselected AND custom stays one click away. Standard = 0.25; Custom = type your own.
            $selIdx = if ($c.ClearanceMode -eq 'custom') { 1 } else { 0 }
            $stdC = 0.25
            $stdTotal = $wallNow + $stdC
            $stdSub = ("Chip clearance 0.25`". Part thickness = {0:0.###}`" ({1:0.###}`" + 0.25`")." -f $stdTotal, $wallNow)
            $opts = @(
                @{ Title = 'Standard clearance'; Subtitle = $stdSub },
                @{ Title = 'Tight / custom'; Subtitle = 'Enter my own (usually smaller) chip clearance.' }
            )
            Add-WizardChoiceCards -Panel $panel -Options $opts -Context $c -Wizard $wiz -Top ($y + 4) -CardWidth 250 -CardHeight 92 -HighlightIndex $selIdx -AfterPick 'rerender' -OnPick {
                param($i, $opt, $cc, $w)
                if ($i -eq 0) {
                    $cc.ClearanceMode = 'standard'
                    $dr = Set-CurvedChipClearance -Context $cc -Clearance 0.25
                    $w.SetChip('relief', 'clearance 0.25"', 'set')
                    $w.SetChip('thickness', ("part {0:0.###}`"" -f $dr.Total), 'set')
                } else {
                    $cc.ClearanceMode = 'custom'
                    $cur = 0.25; try { if ($null -ne $cc.ChipClearance -and [double]$cc.ChipClearance -gt 0) { $cur = [double]$cc.ChipClearance } } catch { $cur = 0.25 }
                    $cc.ChipClearanceValid = ([double]$cur -gt 0)
                }
            }
            # flow the confirmation/field BELOW the cards (Get-StackTop returns just under the
            # lowest control so it can never draw over the cards).
            $y = Get-StackTop $panel ($y + 4) 14

            if ($c.ClearanceMode -eq 'custom') {
                # CUSTOM: an editable clearance field, live-validated. Seeds Set-CurvedChipClearance
                # on every valid keystroke so the derived thickness + relief stay in sync.
                $y = (Add-Para $panel "Tight / custom -- enter your chip clearance (inches):" $y 0 $null $true).Bottom + 8
                $lab = New-Object System.Windows.Forms.Label
                $lab.Text = 'Chip clearance (in):'; $lab.Location = New-Object System.Drawing.Point(8, ($y + 3)); $lab.Size = New-Object System.Drawing.Size(136, 20)
                $lab.ForeColor = Get-UiColor ''; $lab.BackColor = [System.Drawing.Color]::Transparent
                $panel.Controls.Add($lab)
                $tb = New-Object System.Windows.Forms.TextBox
                $tb.Location = New-Object System.Drawing.Point(148, $y); $tb.Size = New-Object System.Drawing.Size(90, 24)
                $tb.Text = if ($null -ne $c.ChipClearance) { [string]$c.ChipClearance } else { '0.25' }
                $tb.BackColor = [System.Drawing.Color]::FromArgb(16,24,42); $tb.ForeColor = Get-UiColor ''; $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
                $panel.Controls.Add($tb)
                $lblEcho = New-Object System.Windows.Forms.Label
                $lblEcho.AutoSize = $true; $lblEcho.MaximumSize = New-Object System.Drawing.Size(560, 0)
                $lblEcho.Location = New-Object System.Drawing.Point(8, ($y + 34)); $lblEcho.BackColor = [System.Drawing.Color]::Transparent
                $panel.Controls.Add($lblEcho)
                # Precompute echo colors OUTSIDE the closure (Get-UiColor is global but capturing
                # avoids a per-keystroke resolve).
                $okCol  = Get-UiColor 'green'
                $errCol = Get-UiColor 'firebrick'
                $updateEcho = {
                    $t = [string]$tb.Text
                    $v = $null
                    if (-not [string]::IsNullOrWhiteSpace($t)) {
                        try { $v = [double]::Parse($t.Trim(), [System.Globalization.CultureInfo]::InvariantCulture) } catch { $v = $null }
                    }
                    if ($null -eq $v -or [double]::IsNaN($v) -or [double]::IsInfinity($v) -or $v -le 0) {
                        $c.ChipClearanceValid = $false
                        $lblEcho.ForeColor = $errCol
                        $lblEcho.Text = 'Enter a positive chip clearance in inches (e.g. 0.125).'
                    } else {
                        $dr = Set-CurvedChipClearance -Context $c -Clearance ([double]$v)
                        $lblEcho.ForeColor = $okCol
                        $lblEcho.Text = ("Chip clearance {0:0.###}`" (symmetric relief cut {1:0.###}`"). Part thickness = {2:0.###}`". Press Next." -f [double]$v, (2.0 * [double]$v), $dr.Total)
                        $wiz.SetChip('relief', ("clearance {0:0.###}`"" -f [double]$v), 'set')
                        $wiz.SetChip('thickness', ("part {0:0.###}`"" -f $dr.Total), 'set')
                    }
                    try { $wiz.Refresh() } catch {}
                }.GetNewClosure()
                $tb.Add_TextChanged({ param($s,$e) & $updateEcho }.GetNewClosure())
                & $updateEcho
            } else {
                # STANDARD (preselected default): confirm + derive. Next is already enabled.
                $dr = Set-CurvedChipClearance -Context $c -Clearance 0.25
                $y = (Add-Para $panel ([char]0x2713 + " Standard clearance 0.25`" (symmetric relief cut 0.5`") -- press Next, or pick Tight / custom above.") $y 0 'green' $true).Bottom + 6
                $ftxt = if ($dr.Fallback) { " (wall = fallback ~1.5x hole dia; no bushing length on this leaf)" } else { "" }
                $y = (Add-Para $panel ("Part thickness = {0:0.###}`" ({1:0.###}`" + 0.25`"){2}. Offset 0 (flush)." -f $dr.Total, $dr.Wall, $ftxt) $y 0 'gray').Bottom + 10
                $wiz.SetChip('relief', 'clearance 0.25"', 'set')
                $wiz.SetChip('thickness', ("part {0:0.###}`"" -f $dr.Total), 'set')
            }
        } `
        -OnNext {
            param($c, $wiz)
            # null mode defaults to standard (Next is enabled on entry, no card click needed).
            if ($null -eq $c.ClearanceMode) { $c.ClearanceMode = 'standard' }
            if ($c.ClearanceMode -eq 'custom' -and -not $c.ChipClearanceValid) { return $false }
            # Re-derive from the committed clearance so Thickness/ReliefDepth/StandOff are set
            # even if the operator advanced via Next without touching a card this render.
            $cl = 0.25
            if ($c.ClearanceMode -eq 'standard') { $cl = 0.25 }
            else { try { if ($null -ne $c.ChipClearance -and [double]$c.ChipClearance -gt 0) { $cl = [double]$c.ChipClearance } } catch { $cl = 0.25 } }
            [void](Set-CurvedChipClearance -Context $c -Clearance $cl)
            return $true
        }
    [void]$Steps.Add($clearanceStep)
}
