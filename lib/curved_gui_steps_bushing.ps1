# ============================================================================
# lib\curved_gui_steps_bushing.ps1 - the Welcome + Bushing step group for the
# curved-jig wizard GUI (drilljig3d-gui.cmd).
# ============================================================================
# Defines ONE global function, Add-CurvedBushingSteps, that appends FOUR wizard
# steps to the shared $Steps ArrayList:
#   1. welcome   (Stage 'Welcome') - plain-language overview, no Creo.
#   2. tree      (Stage 'Bushing') - the decision-tree card walk that resolves the
#                hole OD + bushing length. This PORTS the functional core of
#                drilljig-gui.cmd's tree step (~1737-2340) - the SAME walk state
#                machine (curved_gui_helpers.ps1's Push/Pop-TreeHistory,
#                Reset-TreeWalk, Set-BushLengthPick) + the SAME shared catalog
#                resolvers (drilljig_core.ps1) - so behaviour matches the flat GUI.
#                DELIBERATELY OMITTED: the 2D/3D bushing schematic (bushing_svg /
#                WPF Media3D) that drilljig-gui draws on the confirmation page. The
#                curved GUI shows a TEXT confirmation only (name / hole dia / length)
#                - lighter, zero extra deps, and the geometry preview is not needed
#                to pick a bushing. Everything else (OD-first metal, ID-first sleeve,
#                custom-OD, standardized length + Custom, OD tie-break, in-flow Back)
#                is preserved verbatim.
#   3. thickness (Stage 'Bushing') - inline textbox for the conformal-blank
#                THICKNESS (jig wall). Pre-filled from the bushing length.
#   4. standoff  (Stage 'Bushing') - inline textbox for the STANDOFF / chip-clearance
#                offset (default 0 = flush).
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
            $y = (Add-Para $panel "This wizard builds a CONFORMAL (curved) drill jig that follows a part's surface, then drills bushing holes normal to that surface and cuts curved chip-relief slots." $y 0 '' $true).Bottom + 12
            $y = (Add-Para $panel "What happens, step by step:" $y 0 'gray' $true).Bottom + 6
            $y = (Add-Para $panel ([char]0x2022 + " Bushing & size - answer a few questions to pick the bushing and the hole diameter, and set the jig wall thickness.") $y 0 'gray').Bottom + 4
            $y = (Add-Para $panel ([char]0x2022 + " Surface - click the part surface to follow. The tool offsets a copy of that surface and thickens it into a NEW conformal blank body of your chosen thickness.") $y 0 'gray').Bottom + 4
            $y = (Add-Para $panel ([char]0x2022 + " Drill - pick the target points; each hole is drilled NORMAL to the surface at the bushing diameter.") $y 0 'gray').Bottom + 4
            $y = (Add-Para $panel ([char]0x2022 + " Relief - cut curved chip-relief slots along the hole rows to clear chips/debris.") $y 0 'gray').Bottom + 12
            $y = (Add-Para $panel "Some steps will ask you to click something in the Creo window (the surface, the points, or to draw a slot rectangle). When they do, the wizard waits and only continues once your pick checks out." $y 0 'gray').Bottom + 12
            $y = (Add-Para $panel "Open the jig PART in Creo (not an assembly), then press Get started." $y 0 '' $true).Bottom + 8
        }
    [void]$Steps.Add($welcomeStep)

    # ========================================================================
    # STEP 2 - TREE (Stage 'Bushing'): the decision-tree card walk. PORTED from
    # drilljig-gui.cmd ~1737-2340 (schematic omitted - see file header).
    # ========================================================================
    $treeStep = New-WizardStep -Key 'tree' -Title 'Bushing & hole size' -Stage 'Bushing' -Kind 'choice' -PrimaryText 'Next' `
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
    # STEP 3 - THICKNESS (Stage 'Bushing'): inline textbox for the conformal-blank
    # thickness (jig wall). Live-validate a POSITIVE number into $c.Thickness;
    # store the validity flag in $c.ThicknessValid (a Build-local cannot survive to
    # Validate). Soft-warn (yellow) when < 1.5x the hole dia. Mirrors the slot-depth
    # inline-textbox pattern: precompute echo colors OUTSIDE the closure (Get-UiColor
    # is global but capturing avoids a per-keystroke resolve), write to $c.*, Refresh.
    # ========================================================================
    $thicknessStep = New-WizardStep -Key 'thickness' -Title 'Jig wall thickness' -Stage 'Bushing' -Kind 'info' -PrimaryText 'Next' `
        -Validate { param($c) return [bool]$c.ThicknessValid } `
        -Build {
            param($panel, $c, $wiz)
            # Pre-fill from the bushing length on first entry (a good default wall = the
            # length the bushing seats through). Only when Thickness is still unset.
            if ($null -eq $c.Thickness -and $null -ne $c.BushingLen -and [double]$c.BushingLen -gt 0) {
                $c.Thickness = [double]$c.BushingLen
            }
            $y = 8
            $y = (Add-Para $panel "How thick should the conformal jig blank be? This is the wall the tool grows off the surface you follow (the bushing seats through it)." $y 0 'gray').Bottom + 6
            if ($null -ne $c.HoleDiaFinal -and [double]$c.HoleDiaFinal -gt 0) {
                $rec = 1.5 * [double]$c.HoleDiaFinal
                $y = (Add-Para $panel ("Guidance: at least ~1.5x the hole diameter ({0:0.###}`") gives the bushing enough wall to seat." -f $rec) $y 0 'gray').Bottom + 8
            }
            $lab = New-Object System.Windows.Forms.Label
            $lab.Text = 'Thickness (in):'; $lab.Location = New-Object System.Drawing.Point(8, ($y + 3)); $lab.Size = New-Object System.Drawing.Size(112, 20)
            $lab.ForeColor = Get-UiColor ''; $lab.BackColor = [System.Drawing.Color]::Transparent
            $panel.Controls.Add($lab)
            $tb = New-Object System.Windows.Forms.TextBox
            $tb.Location = New-Object System.Drawing.Point(124, $y); $tb.Size = New-Object System.Drawing.Size(90, 24)
            $tb.Text = if ($null -ne $c.Thickness) { [string]$c.Thickness } else { '' }
            $tb.BackColor = [System.Drawing.Color]::FromArgb(16,24,42); $tb.ForeColor = Get-UiColor ''; $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
            $panel.Controls.Add($tb)
            $lblEcho = New-Object System.Windows.Forms.Label
            $lblEcho.AutoSize = $true; $lblEcho.MaximumSize = New-Object System.Drawing.Size(560, 0)
            $lblEcho.Location = New-Object System.Drawing.Point(8, ($y + 34)); $lblEcho.BackColor = [System.Drawing.Color]::Transparent
            $panel.Controls.Add($lblEcho)
            # Precompute echo colors + the recommended wall OUTSIDE the closure (Get-UiColor
            # is global, but capturing keeps the closure free of a per-keystroke resolve;
            # $recWall is a plain double captured by value).
            $okCol   = Get-UiColor 'green'
            $warnCol = Get-UiColor 'warn'
            $errCol  = Get-UiColor 'firebrick'
            $recWall = if ($null -ne $c.HoleDiaFinal) { 1.5 * [double]$c.HoleDiaFinal } else { 0.0 }
            $updateEcho = {
                $t = [string]$tb.Text
                $v = $null
                if (-not [string]::IsNullOrWhiteSpace($t)) {
                    try { $v = [double]::Parse($t.Trim(), [System.Globalization.CultureInfo]::InvariantCulture) } catch { $v = $null }
                }
                if ($null -eq $v -or [double]::IsNaN($v) -or [double]::IsInfinity($v) -or $v -le 0) {
                    $c.ThicknessValid = $false
                    $lblEcho.ForeColor = $errCol
                    $lblEcho.Text = 'Enter a positive thickness in inches (e.g. 0.5).'
                } else {
                    $c.Thickness = [double]$v; $c.ThicknessValid = $true
                    if ($recWall -gt 0 -and $v -lt $recWall) {
                        $lblEcho.ForeColor = $warnCol
                        $lblEcho.Text = ([char]0x26A0 + (" Thickness {0:0.###}`" is thin -- below ~1.5x the hole dia ({1:0.###}`"). OK to continue, but verify the bushing has enough wall to seat." -f [double]$v, $recWall))
                    } else {
                        $lblEcho.ForeColor = $okCol
                        $lblEcho.Text = ("Thickness {0:0.###}`". Press Next." -f [double]$v)
                    }
                    $wiz.SetChip('thickness', ("wall {0:0.###}`"" -f [double]$v), 'set')
                }
                try { $wiz.Refresh() } catch {}
            }.GetNewClosure()
            $tb.Add_TextChanged({ param($s,$e) & $updateEcho }.GetNewClosure())
            & $updateEcho
        } `
        -OnNext { param($c, $wiz) return [bool]$c.ThicknessValid }
    [void]$Steps.Add($thicknessStep)

    # ========================================================================
    # STEP 4 - STANDOFF (Stage 'Bushing'): inline textbox for the standoff /
    # chip-clearance offset. Default 0 (flush). Live-validate a NON-NEGATIVE number
    # into $c.StandOff (blank == 0 is OK). Store the validity flag in $c.StandOffValid.
    # ========================================================================
    $standoffStep = New-WizardStep -Key 'standoff' -Title 'Standoff / chip clearance' -Stage 'Bushing' -Kind 'info' -PrimaryText 'Next' `
        -Validate { param($c) return [bool]$c.StandOffValid } `
        -Build {
            param($panel, $c, $wiz)
            # Default StandOff = 0 (flush) if unset; the field seeds from it.
            if ($null -eq $c.StandOff) { $c.StandOff = 0.0 }
            # Blank/0 is a VALID default, so the step can pass with no typing.
            if ($null -eq $c.StandOffValid) { $c.StandOffValid = $true }
            $y = 8
            $y = (Add-Para $panel "Standoff (chip-clearance offset): how far to float the jig off the part surface. Leave 0 for flush (the usual choice); a positive value lifts the jig to clear chips/debris." $y 0 'gray').Bottom + 8
            $lab = New-Object System.Windows.Forms.Label
            $lab.Text = 'Standoff (in):'; $lab.Location = New-Object System.Drawing.Point(8, ($y + 3)); $lab.Size = New-Object System.Drawing.Size(100, 20)
            $lab.ForeColor = Get-UiColor ''; $lab.BackColor = [System.Drawing.Color]::Transparent
            $panel.Controls.Add($lab)
            $tb = New-Object System.Windows.Forms.TextBox
            $tb.Location = New-Object System.Drawing.Point(112, $y); $tb.Size = New-Object System.Drawing.Size(90, 24)
            $tb.Text = if ($null -ne $c.StandOff) { [string]$c.StandOff } else { '0' }
            $tb.BackColor = [System.Drawing.Color]::FromArgb(16,24,42); $tb.ForeColor = Get-UiColor ''; $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
            $panel.Controls.Add($tb)
            $lblEcho = New-Object System.Windows.Forms.Label
            $lblEcho.AutoSize = $true; $lblEcho.MaximumSize = New-Object System.Drawing.Size(560, 0)
            $lblEcho.Location = New-Object System.Drawing.Point(8, ($y + 34)); $lblEcho.BackColor = [System.Drawing.Color]::Transparent
            $panel.Controls.Add($lblEcho)
            # Precompute echo colors OUTSIDE the closure (same pattern as above).
            $okCol  = Get-UiColor 'green'
            $errCol = Get-UiColor 'firebrick'
            $updateEcho = {
                $t = [string]$tb.Text
                if ([string]::IsNullOrWhiteSpace($t)) {
                    # blank == flush (0).
                    $c.StandOff = 0.0; $c.StandOffValid = $true
                    $lblEcho.ForeColor = $okCol
                    $lblEcho.Text = 'Standoff 0" (flush). Press Next.'
                    $wiz.SetChip('standoff', 'standoff 0"', 'set')
                } else {
                    $v = $null
                    try { $v = [double]::Parse($t.Trim(), [System.Globalization.CultureInfo]::InvariantCulture) } catch { $v = $null }
                    if ($null -eq $v -or [double]::IsNaN($v) -or [double]::IsInfinity($v) -or $v -lt 0) {
                        $c.StandOffValid = $false
                        $lblEcho.ForeColor = $errCol
                        $lblEcho.Text = 'Enter 0 (flush) or a positive offset in inches.'
                    } else {
                        $c.StandOff = [double]$v; $c.StandOffValid = $true
                        $lblEcho.ForeColor = $okCol
                        $lblEcho.Text = ("Standoff {0:0.###}`". Press Next." -f [double]$v)
                        $wiz.SetChip('standoff', ("standoff {0:0.###}`"" -f [double]$v), 'set')
                    }
                }
                try { $wiz.Refresh() } catch {}
            }.GetNewClosure()
            $tb.Add_TextChanged({ param($s,$e) & $updateEcho }.GetNewClosure())
            & $updateEcho
        } `
        -OnNext { param($c, $wiz) return [bool]$c.StandOffValid }
    [void]$Steps.Add($standoffStep)
}
