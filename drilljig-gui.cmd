<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

# ============================================================================
# drilljig-gui.cmd - GUI front-end for the drill-jig flow (Milestone 1)
# ============================================================================
# A single never-closing WinForms WIZARD window that drives the SAME end-to-end
# drill-jig flow as drilljig.cmd (decision tree -> point source -> box -> datum
# points -> corner round -> drill -> chip relief), but with no console typing:
# every decision is a card or field, and every UNAVOIDABLE Creo mouse pick
# (multi-select the 3 datums, draw the rectangle, hand-pick points) is its own
# "arm + verify" step whose Next button stays disabled until the selection buffer
# validates -- so a wrong/empty pick structurally cannot leak into the geometry.
#
# Milestone 1 scope (this file):
#   * the wizard shell + breadcrumb + honesty chips + RUN view (lib\wizard.ps1)
#   * the proven Creo engine, called VERBATIM (lib\drilljig_core.ps1)
#   * the EXISTING orthogrid / custom editors launched AS MODALS for the layout
#     (lib\orthogrid_gui.ps1) -- the in-canvas embed is a later milestone
#   * the blind-evaluator box check (lib\blind_evaluator.ps1), gate -> green chip
#
# drilljig.cmd is LEFT UNTOUCHED and still runs standalone; this is an additive
# second front-end over the shared lib. Open the jig PART (not the .asm).
#
# Flags: --no-corner-round, --corner-radius N, --probe-judge (same as drilljig.cmd).
# ============================================================================

$Host.UI.RawUI.WindowTitle = "DRILLJIG GUI"
$ErrorActionPreference = "Stop"

$ProbeJudge = ($ScriptArgs -match '(?i)(^|\s)-{1,2}probe-judge(\s|$)')

trap {
    Write-Host ""
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $inv = $_.InvocationInfo
    if ($null -ne $inv) { Write-Host ("  at line {0}: {1}" -f $inv.ScriptLineNumber, $inv.Line.Trim()) -ForegroundColor DarkYellow }
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

# ---- dot-source the shared libs (order matters; same as drilljig.cmd) -------
. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')
. (Join-Path $ScriptDir 'lib\blind_evaluator.ps1')
. (Join-Path $ScriptDir 'lib\edge_round.ps1')
. (Join-Path $ScriptDir 'lib\orthogrid.ps1')
. (Join-Path $ScriptDir 'lib\orthogrid_gui.ps1')
. (Join-Path $ScriptDir 'lib\orthogrid_points.ps1')
. (Join-Path $ScriptDir 'lib\drilljig_core.ps1')
. (Join-Path $ScriptDir 'lib\wizard.ps1')

# --probe-judge: validate the REST judge in isolation, then exit (no Creo).
if ($ProbeJudge) {
    $ok = Invoke-JudgeProbe -RepoRoot $ScriptDir -Model "sonnet"
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit ([int](-not $ok))
}

$dataDir = Join-Path $ScriptDir 'data'

# Corner-round flags (same contract as drilljig.cmd).
$cornerRadius = 0.25
$mCr = [regex]::Match($ScriptArgs, '(?i)--corner-radius\s+([0-9]*\.?[0-9]+)')
if ($mCr.Success) { $cornerRadius = [double]$mCr.Groups[1].Value }
$noCornerRound = ($ScriptArgs -match '(?i)--no-corner-round')

$RELIEF_DIA_MULT  = 1.5
$RELIEF_DEPTH_PCT = 0.20

# ============================================================================
# The shared CONTEXT hashtable - every wizard step reads/writes it. Holds the
# decision-tree results, the captured layout, the Creo handles, and the captured
# plane/point ids as the run progresses.
# ============================================================================
$ctx = @{
    # STAGE 1
    TreePath    = Join-Path $ScriptDir 'docs\drill_jig_decision_tree.json'
    Path        = [System.Collections.ArrayList]::new()   # chosen labels (provenance)
    Picks       = [System.Collections.ArrayList]::new()    # resolved bushing picks
    HoleDia     = $null
    BushingLen  = $null
    Is3dPrint   = $false
    # tree-walk cursor (the decision-tree step descends this in place)
    TreeNode    = $null
    TreeDone    = $false
    # bushing pick cursor
    PendingSpec = $null      # catalog spec awaiting an OD/length/ID pick
    BushStage   = $null      # 'od' | 'len' | 'id'
    Grouped     = $null      # catalog grouped by OD (persistent so OnPick can index it)
    BushOD      = $null
    BushLen     = $null
    # POINT SOURCE
    PointMode    = 'predefined'
    OrthoGeo     = $null
    LayoutPicked = $false
    LayoutMode   = $null      # $null = show tiles; 'orthogrid'|'custom' = inline editor
    OrthoValid   = $false     # the inline editor's current validity (gates Next)
    OrthoFields  = $null      # persistent {CcX;CcZ;Nx;Nz;Edge} for the inline grid editor
    CustomRows   = $null      # persistent ArrayList of {X;Z} for the inline custom editor
    # Creo
    Session     = $null
    Model       = $null
    Type        = $null
    ModelName   = ''
    Connected   = $false
    # STAGE 2 planes
    Planes      = $null
    AutoMapped  = $false
    SidePlane   = $null
    Made        = @()
    BoxArmed    = $false   # Box-A armed the sketcher; gates Box-B
    SketchPlaneId = $null
    ExtrudeToId   = $null
    BoxBuilt    = $false
    BuildConfirmed = $null
    # STAGE 2.5 points
    GridPointIDs = @()
    GridPlaneIds = @()
    # STAGE 3
    PointIDs    = @()
    BodyIndex   = 0
    HoleDiaFinal = 0.0
    Drilled     = $false
    # STAGE 6 relief paths
    ReliefBoundaryId = $null
    ReliefCrossAxis  = $null
    ReliefBLabel     = $null
}

# ----------------------------------------------------------------------------
# Convenience: append a line to the wizard run log (used by the engine logger).
# Set when a RUN step starts so Initialize-DrilljigCore can route Write-DJ output
# into the on-screen log. $script:GuiWiz is the live $wiz controller.
# ----------------------------------------------------------------------------
$script:GuiWiz = $null
$djLogger = {
    param([string]$Text, [string]$Color)
    if ($null -ne $script:GuiWiz) { try { $script:GuiWiz.Log($Text) } catch {} }
}

# ============================================================================
# STEP BUILDERS - each returns a populated canvas. Helpers first.
# ============================================================================

# Resolve a friendly colour NAME to a dark-theme-bright RGB so text stays visible
# on the darkish-blue canvas. Reads $script:WizTheme (set by Show-Wizard) for the
# base ink/muted/ok/warn colours; falls back to sane brights if it isn't set.
function Get-UiColor {
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

# A simple paragraph label on the canvas. AutoSize off + a width clamp so long
# text WRAPS instead of being clipped to a fixed-width box; height is generous and
# the body panel scrolls if a step overflows (Show-Wizard sets $body.AutoScroll).
function Add-Para {
    param($Panel, [string]$Text, [int]$Top = 8, [int]$Height = 60, [string]$ColorName = $null, [bool]$Bold = $false)
    $l = New-Object System.Windows.Forms.Label
    $l.Location = New-Object System.Drawing.Point(8, $Top)
    $l.Size     = New-Object System.Drawing.Size(($Panel.Width - 28), $Height)
    $l.AutoSize = $false
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $l.Font     = New-Object System.Drawing.Font('Segoe UI', 11, $style)
    $l.ForeColor = Get-UiColor $ColorName
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.Text     = $Text
    $Panel.Controls.Add($l)
    return $l
}

# A big "look at Creo" arm banner for a pick step.
function Add-ArmBanner {
    param($Panel, [string]$Instruction, [int]$Top = 8)
    $hint = New-Object System.Windows.Forms.Label
    $hint.Location = New-Object System.Drawing.Point(8, $Top)
    $hint.Size     = New-Object System.Drawing.Size(($Panel.Width - 28), 24)
    $hint.Font     = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Italic)
    $hint.ForeColor = Get-UiColor 'warn'
    $hint.BackColor = [System.Drawing.Color]::Transparent
    $hint.Text     = ([char]0x2192) + " look at the Creo window"
    $Panel.Controls.Add($hint)

    $instr = New-Object System.Windows.Forms.Label
    $instr.Location = New-Object System.Drawing.Point(8, ($Top + 30))
    $instr.Size     = New-Object System.Drawing.Size(($Panel.Width - 28), 80)
    $instr.Font     = New-Object System.Drawing.Font('Segoe UI', 13)
    $instr.ForeColor = Get-UiColor ''
    $instr.BackColor = [System.Drawing.Color]::Transparent
    $instr.Text     = $Instruction
    $Panel.Controls.Add($instr)
}

# A verify button + result label for a pick step. $OnVerify reads the buffer and
# returns @{ Ok=[bool]; Message=string }. On Ok it stashes results in $ctx (the
# caller's $OnVerify does that) and enables Next via $wiz.Refresh.
function Add-VerifyControls {
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

    $result = New-Object System.Windows.Forms.Label
    $result.Location = New-Object System.Drawing.Point(8, ($Top + 48))
    $result.Size     = New-Object System.Drawing.Size(($Panel.Width - 28), 120)
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

# ============================================================================
# Add-InlineOrthogrid - build the orthogrid editor INSIDE the wizard canvas (no
# popup window; user request 2026-06-26). Reuses the PURE math Get-OrthogridGeometry
# and the shared Draw-AxisGlyph preview from lib\orthogrid_gui.ps1 - it does NOT
# touch the live-verified Show-OrthogridDialog (that modal stays for the standalone
# tools). Fields write into $Context.OrthoFields (persistent, so the recompute
# closure never reads a Build-local); each change recomputes and stores the result
# in $Context.OrthoGeo + sets $Context.OrthoValid (the step's Validate gates Next on
# it). $HoleDia/$ReliefDia/$Thickness are read-only context shown as a caption.
# ============================================================================
function Add-InlineOrthogrid {
    param($Panel, $Context, $Wizard)
    $thm = $script:WizTheme
    $ink   = if ($thm) { $thm.Ink }   else { [System.Drawing.Color]::FromArgb(238,242,248) }
    $muted = if ($thm) { $thm.Muted } else { [System.Drawing.Color]::FromArgb(158,172,196) }
    $cardBk= if ($thm) { $thm.CanvasBack } else { [System.Drawing.Color]::FromArgb(30,42,68) }
    $fieldBk = [System.Drawing.Color]::FromArgb(16,24,42)
    $errCol = if ($thm) { $thm.Err } else { [System.Drawing.Color]::FromArgb(245,120,110) }
    $okCol  = if ($thm) { $thm.Ok }  else { [System.Drawing.Color]::FromArgb(120,210,150) }

    # persistent field store (seed once from defaults / a prior edit)
    if ($null -eq $Context.OrthoFields) {
        $seed = @{ CcX = 0.5; CcZ = 0.5; Nx = 5; Nz = 4; Edge = 0.5 }
        if ($null -ne $Context.OrthoGeo -and $Context.OrthoGeo.Mode -eq 'orthogrid') {
            try { $seed.CcX = [double]$Context.OrthoGeo.CcX; $seed.CcZ = [double]$Context.OrthoGeo.CcZ; $seed.Nx = [int]$Context.OrthoGeo.Nx; $seed.Nz = [int]$Context.OrthoGeo.Nz; $seed.Edge = [double]$Context.OrthoGeo.Edge } catch {}
        }
        $Context.OrthoFields = $seed
    }
    $clearDia = 0.0
    if ($null -ne $Context.HoleDia -and [double]$Context.HoleDia -gt 0) { $clearDia = [double]$Context.HoleDia }

    # left column: labelled fields
    $rows = @(
        @{ Key='CcX';  Label='Center-to-center X' },
        @{ Key='CcZ';  Label='Center-to-center Z' },
        @{ Key='Nx';   Label='Holes along X (Nx)' },
        @{ Key='Nz';   Label='Holes along Z (Nz)' },
        @{ Key='Edge'; Label='Edge margin' }
    )
    $y = 6
    $boxes = @{}
    foreach ($rw in $rows) {
        $lab = New-Object System.Windows.Forms.Label
        $lab.Text = $rw.Label + ':'; $lab.Location = New-Object System.Drawing.Point(8, ($y+3)); $lab.Size = New-Object System.Drawing.Size(160, 20)
        $lab.ForeColor = $ink; $lab.BackColor = [System.Drawing.Color]::Transparent
        $Panel.Controls.Add($lab)
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Location = New-Object System.Drawing.Point(176, $y); $tb.Size = New-Object System.Drawing.Size(90, 24)
        $tb.Text = [string]$Context.OrthoFields[$rw.Key]
        $tb.BackColor = $fieldBk; $tb.ForeColor = $ink; $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $tb.Tag = $rw.Key
        $boxes[$rw.Key] = $tb
        $Panel.Controls.Add($tb)
        $y += 32
    }

    # context caption
    $capY = $y + 4
    $cap = "hole {0}" -f $(if ($clearDia -gt 0) { ('{0:0.###}"' -f $clearDia) } else { 'n/a' })
    if ($null -ne $Context.BushingLen) { $cap += ("    depth {0:0.###}`"" -f [double]$Context.BushingLen) }
    $lblCap = New-Object System.Windows.Forms.Label
    $lblCap.Location = New-Object System.Drawing.Point(8, $capY); $lblCap.Size = New-Object System.Drawing.Size(280, 20)
    $lblCap.ForeColor = $muted; $lblCap.BackColor = [System.Drawing.Color]::Transparent; $lblCap.Text = $cap
    $Panel.Controls.Add($lblCap)

    # readout + error
    $lblReadout = New-Object System.Windows.Forms.Label
    $lblReadout.Location = New-Object System.Drawing.Point(8, ($capY + 26)); $lblReadout.Size = New-Object System.Drawing.Size(300, 40)
    $lblReadout.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lblReadout.ForeColor = $okCol; $lblReadout.BackColor = [System.Drawing.Color]::Transparent
    $Panel.Controls.Add($lblReadout)
    $lblErr = New-Object System.Windows.Forms.Label
    $lblErr.Location = New-Object System.Drawing.Point(8, ($capY + 68)); $lblErr.Size = New-Object System.Drawing.Size(300, 40)
    $lblErr.ForeColor = $errCol; $lblErr.BackColor = [System.Drawing.Color]::Transparent
    $Panel.Controls.Add($lblErr)

    # right side: live dot preview
    $preview = New-Object System.Windows.Forms.Panel
    $preview.Location = New-Object System.Drawing.Point(320, 6)
    $preview.Size     = New-Object System.Drawing.Size(280, 200)
    $preview.BackColor = $fieldBk
    $preview.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $Panel.Controls.Add($preview)
    $preview.Add_Paint({
        param($s,$e)
        try {
            $g = $e.Graphics; $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $res = $Context.OrthoGeo
            if ($null -eq $res -or -not $res.Valid -or $res.Mode -ne 'orthogrid') { return }
            $w = [double]$res.Width; $h = [double]$res.Height
            if ($w -le 0 -or $h -le 0) { return }
            $cw = $s.ClientSize.Width; $ch = $s.ClientSize.Height; $margin = 18.0
            $availW = $cw - 2*$margin; $availH = $ch - 2*$margin
            if ($availW -le 1 -or $availH -le 1) { return }
            $scale = $availW / $w; if (($availH / $h) -lt $scale) { $scale = $availH / $h }
            if ($scale -le 0) { return }
            $drawW = $w*$scale; $drawH = $h*$scale
            $offX = ($cw-$drawW)/2.0; $offY = ($ch-$drawH)/2.0
            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(110,150,210), 1.5)
            $g.DrawRectangle($pen, [single]$offX, [single]$offY, [single]$drawW, [single]$drawH); $pen.Dispose()
            $br = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(240,120,110))
            foreach ($pt in $res.Points) {
                $px = $offX + ([double]$pt.X)*$scale; $py = $offY + $drawH - ([double]$pt.Z)*$scale
                $g.FillEllipse($br, [single]($px-3), [single]($py-3), 6, 6)
            }
            $br.Dispose()
            Draw-AxisGlyph -Graphics $g -ClientW $cw -ClientH $ch
        } catch {}
    }.GetNewClosure())

    # recompute closure: read the boxes -> Get-OrthogridGeometry -> store + gate.
    $recompute = {
        $f = $Context.OrthoFields
        $cx=0.0;$cz=0.0;$ed=0.0;$nx=0;$nz=0
        $okCx=[double]::TryParse([string]$f.CcX,[ref]$cx); $okCz=[double]::TryParse([string]$f.CcZ,[ref]$cz)
        $okEd=[double]::TryParse([string]$f.Edge,[ref]$ed); $okNx=[int]::TryParse([string]$f.Nx,[ref]$nx); $okNz=[int]::TryParse([string]$f.Nz,[ref]$nz)
        $perr=@()
        if (-not $okCx){$perr+='ccX not a number'}; if (-not $okCz){$perr+='ccZ not a number'}
        if (-not $okEd){$perr+='edge not a number'}; if (-not $okNx){$perr+='Nx not an integer'}; if (-not $okNz){$perr+='Nz not an integer'}
        $res=$null
        if ($perr.Count -eq 0) { try { $res = Get-OrthogridGeometry -CcX $cx -CcZ $cz -Nx $nx -Nz $nz -Edge $ed -ClearDia $clearDia } catch { $res=$null } }
        if ($null -ne $res -and $res.Valid) {
            if ($null -ne $Context.HoleDia)   { try { $res | Add-Member -NotePropertyName 'HoleDiameter'   -NotePropertyValue ([double]$Context.HoleDia)   -Force } catch {} }
            if ($null -ne $Context.BushingLen){ try { $res | Add-Member -NotePropertyName 'Thickness'      -NotePropertyValue ([double]$Context.BushingLen)-Force } catch {} }
            $Context.OrthoGeo = $res; $Context.OrthoValid = $true; $Context.PointMode = 'orthogrid'
            $lblReadout.Text = ('Part {0:0.00} x {1:0.00}  |  {2} holes' -f $res.Width, $res.Height, $res.Count)
            $lblErr.Text = ''
            $Wizard.SetChip('layout', ("grid: {0} holes" -f $res.Count), 'set')
            $Wizard.SetChip('plate', ("plate {0:0.0}x{1:0.0}" -f $res.Width, $res.Height), 'set')
        } else {
            $Context.OrthoValid = $false
            $lblReadout.Text=''
            if ($perr.Count -gt 0) { $lblErr.Text = ($perr -join '; ') }
            elseif ($null -ne $res -and $res.Errors -and $res.Errors.Count -gt 0) { $lblErr.Text = ($res.Errors -join '; ') }
            else { $lblErr.Text = 'Invalid input' }
        }
        try { $preview.Invalidate() } catch {}
        try { $Wizard.Refresh() } catch {}
    }.GetNewClosure()

    # wire each box: write to the persistent store, then recompute.
    foreach ($k in @($boxes.Keys)) {
        $boxes[$k].Add_TextChanged({
            param($s,$e)
            $Context.OrthoFields[[string]$s.Tag] = $s.Text
            & $recompute
        }.GetNewClosure())
    }
    & $recompute
}

# ============================================================================
# Add-InlineCustomPoints - the CUSTOM per-point editor embedded IN the wizard
# canvas (no popup; user request 2026-06-26 "custom still opens an extra window").
# A DataGridView of X/Z rows + Add/Remove buttons + a live dot-preview, reusing the
# pure Get-CustomPointsGeometry math. Rows persist in $Context.CustomRows (a
# System.Collections.ArrayList of @{X;Z} strings) so the recompute closure never
# reads a Build-local. Result stored in $Context.OrthoGeo (Mode='custom') + gates
# via $Context.OrthoValid, exactly like the orthogrid editor (shape-compatible).
# ============================================================================
function Add-InlineCustomPoints {
    param($Panel, $Context, $Wizard)
    $thm = $script:WizTheme
    $ink   = if ($thm) { $thm.Ink }   else { [System.Drawing.Color]::FromArgb(238,242,248) }
    $muted = if ($thm) { $thm.Muted } else { [System.Drawing.Color]::FromArgb(158,172,196) }
    $fieldBk = [System.Drawing.Color]::FromArgb(16,24,42)
    $errCol = if ($thm) { $thm.Err } else { [System.Drawing.Color]::FromArgb(245,120,110) }
    $okCol  = if ($thm) { $thm.Ok }  else { [System.Drawing.Color]::FromArgb(120,210,150) }
    $clearDia = 0.0
    if ($null -ne $Context.HoleDia -and [double]$Context.HoleDia -gt 0) { $clearDia = [double]$Context.HoleDia }

    # persistent row store (seed once: a couple of starter rows or a prior edit)
    if ($null -eq $Context.CustomRows) {
        $rows = New-Object System.Collections.ArrayList
        if ($null -ne $Context.OrthoGeo -and $Context.OrthoGeo.Mode -eq 'custom' -and $null -ne $Context.OrthoGeo.Points) {
            foreach ($p in $Context.OrthoGeo.Points) { [void]$rows.Add(@{ X = ('{0}' -f $p.X); Z = ('{0}' -f $p.Z) }) }
        }
        if ($rows.Count -eq 0) { [void]$rows.Add(@{ X='0.5'; Z='0.5' }); [void]$rows.Add(@{ X='1.5'; Z='0.5' }) }
        $Context.CustomRows = $rows
    }

    $lblHelp = New-Object System.Windows.Forms.Label
    $lblHelp.Location = New-Object System.Drawing.Point(8, 4); $lblHelp.Size = New-Object System.Drawing.Size(300, 36)
    $lblHelp.ForeColor = $muted; $lblHelp.BackColor = [System.Drawing.Color]::Transparent
    $lblHelp.Text = "Each row is one hole's X / Z offset from the plate corner. X runs along TOP, Z along FRONT."
    $Panel.Controls.Add($lblHelp)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(8, 44); $grid.Size = New-Object System.Drawing.Size(290, 150)
    $grid.AllowUserToAddRows = $false; $grid.RowHeadersVisible = $true
    $grid.BackgroundColor = $fieldBk; $grid.GridColor = [System.Drawing.Color]::FromArgb(72,92,132)
    $grid.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(30,42,68)
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $ink
    $grid.EnableHeadersVisualStyles = $false
    $grid.DefaultCellStyle.BackColor = $fieldBk; $grid.DefaultCellStyle.ForeColor = $ink
    $grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(54,72,112)
    $grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
    $colX = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $colX.HeaderText='X offset'; $colX.Name='X'
    $colZ = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $colZ.HeaderText='Z offset'; $colZ.Name='Z'
    $grid.Columns.Add($colX) | Out-Null; $grid.Columns.Add($colZ) | Out-Null
    foreach ($r in $Context.CustomRows) { $grid.Rows.Add(@([string]$r.X, [string]$r.Z)) | Out-Null }
    $Panel.Controls.Add($grid)

    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text='Add point'; $btnAdd.Size=New-Object System.Drawing.Size(90,26); $btnAdd.Location=New-Object System.Drawing.Point(8,200)
    $btnAdd.FlatStyle=[System.Windows.Forms.FlatStyle]::Flat; $btnAdd.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(90,104,132)
    $btnAdd.BackColor=[System.Drawing.Color]::FromArgb(30,42,68); $btnAdd.ForeColor=$ink
    $Panel.Controls.Add($btnAdd)
    $btnDel = New-Object System.Windows.Forms.Button
    $btnDel.Text='Remove'; $btnDel.Size=New-Object System.Drawing.Size(90,26); $btnDel.Location=New-Object System.Drawing.Point(104,200)
    $btnDel.FlatStyle=[System.Windows.Forms.FlatStyle]::Flat; $btnDel.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(90,104,132)
    $btnDel.BackColor=[System.Drawing.Color]::FromArgb(30,42,68); $btnDel.ForeColor=$ink
    $Panel.Controls.Add($btnDel)

    $lblReadout = New-Object System.Windows.Forms.Label
    $lblReadout.Location = New-Object System.Drawing.Point(8, 234); $lblReadout.Size = New-Object System.Drawing.Size(300, 24)
    $lblReadout.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lblReadout.ForeColor = $okCol; $lblReadout.BackColor = [System.Drawing.Color]::Transparent
    $Panel.Controls.Add($lblReadout)
    $lblErr = New-Object System.Windows.Forms.Label
    $lblErr.Location = New-Object System.Drawing.Point(8, 258); $lblErr.Size = New-Object System.Drawing.Size(300, 36)
    $lblErr.ForeColor = $errCol; $lblErr.BackColor = [System.Drawing.Color]::Transparent
    $Panel.Controls.Add($lblErr)

    $preview = New-Object System.Windows.Forms.Panel
    $preview.Location = New-Object System.Drawing.Point(320, 44); $preview.Size = New-Object System.Drawing.Size(280, 180)
    $preview.BackColor = $fieldBk; $preview.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $Panel.Controls.Add($preview)
    $preview.Add_Paint({
        param($s,$e)
        try {
            $g = $e.Graphics; $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $res = $Context.OrthoGeo
            if ($null -eq $res -or -not $res.Valid -or $res.Mode -ne 'custom') { return }
            $w=[double]$res.Width; $h=[double]$res.Height
            if ($w -le 0 -or $h -le 0) { return }
            $cw=$s.ClientSize.Width; $ch=$s.ClientSize.Height; $margin=18.0
            $availW=$cw-2*$margin; $availH=$ch-2*$margin
            if ($availW -le 1 -or $availH -le 1) { return }
            $scale=$availW/$w; if (($availH/$h) -lt $scale) { $scale=$availH/$h }
            if ($scale -le 0) { return }
            $drawW=$w*$scale; $drawH=$h*$scale; $offX=($cw-$drawW)/2.0; $offY=($ch-$drawH)/2.0
            $pen=New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(110,150,210),1.5)
            $g.DrawRectangle($pen,[single]$offX,[single]$offY,[single]$drawW,[single]$drawH); $pen.Dispose()
            $br=New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(240,120,110))
            foreach ($pt in $res.Points) { $px=$offX+([double]$pt.X)*$scale; $py=$offY+$drawH-([double]$pt.Z)*$scale; $g.FillEllipse($br,[single]($px-3),[single]($py-3),6,6) }
            $br.Dispose(); Draw-AxisGlyph -Graphics $g -ClientW $cw -ClientH $ch
        } catch {}
    }.GetNewClosure())

    # pull the grid rows into the persistent store, then recompute via the pure math.
    $recompute = {
        $pts = @()
        foreach ($row in $grid.Rows) {
            if ($row.IsNewRow) { continue }
            $xs=$null; $zs=$null
            try { $xs=[string]$row.Cells['X'].Value } catch {}
            try { $zs=[string]$row.Cells['Z'].Value } catch {}
            if ([string]::IsNullOrWhiteSpace($xs) -and [string]::IsNullOrWhiteSpace($zs)) { continue }
            $xv=0.0; $zv=0.0
            if ([double]::TryParse($xs,[ref]$xv) -and [double]::TryParse($zs,[ref]$zv)) { $pts += [pscustomobject]@{ X=[double]$xv; Z=[double]$zv } }
            else { $pts += [pscustomobject]@{ X=$null; Z=$null } }
        }
        # mirror into the persistent store so a rerender re-seeds correctly
        $store = New-Object System.Collections.ArrayList
        foreach ($p in $pts) { [void]$store.Add(@{ X=('{0}' -f $p.X); Z=('{0}' -f $p.Z) }) }
        $Context.CustomRows = $store
        $res=$null
        try { $res = Get-CustomPointsGeometry -Points $pts -ClearDia $clearDia } catch { $res=$null }
        if ($null -ne $res -and $res.Valid) {
            if ($null -ne $Context.HoleDia)   { try { $res | Add-Member -NotePropertyName 'HoleDiameter' -NotePropertyValue ([double]$Context.HoleDia) -Force } catch {} }
            if ($null -ne $Context.BushingLen){ try { $res | Add-Member -NotePropertyName 'Thickness'    -NotePropertyValue ([double]$Context.BushingLen) -Force } catch {} }
            $Context.OrthoGeo = $res; $Context.OrthoValid = $true; $Context.PointMode = 'custom'
            $note = if ($res.SkippedOrigin -gt 0) { ("  ({0} at origin dropped)" -f $res.SkippedOrigin) } else { '' }
            $lblReadout.Text = ('Part {0:0.00} x {1:0.00}  |  {2} hole(s){3}' -f $res.Width, $res.Height, $res.Count, $note)
            $lblErr.Text = ''
            $Wizard.SetChip('layout', ("custom: {0} holes" -f $res.Count), 'set')
            $Wizard.SetChip('plate', ("plate {0:0.0}x{1:0.0}" -f $res.Width, $res.Height), 'set')
        } else {
            $Context.OrthoValid = $false; $lblReadout.Text=''
            if ($null -ne $res -and $res.Errors -and $res.Errors.Count -gt 0) { $lblErr.Text = (($res.Errors | Select-Object -First 2) -join '; ') }
            else { $lblErr.Text = 'Add at least one point with numeric X / Z' }
        }
        try { $preview.Invalidate() } catch {}
        try { $Wizard.Refresh() } catch {}
    }.GetNewClosure()

    $btnAdd.Add_Click({ $grid.Rows.Add(@('0','0')) | Out-Null; & $recompute }.GetNewClosure())
    $btnDel.Add_Click({
        $toRemove = @()
        foreach ($cell in $grid.SelectedCells) { $rr = $grid.Rows[$cell.RowIndex]; if (-not $rr.IsNewRow -and ($toRemove -notcontains $rr)) { $toRemove += $rr } }
        foreach ($rr in $toRemove) { $grid.Rows.Remove($rr) }
        & $recompute
    }.GetNewClosure())
    $grid.Add_CellValueChanged({ & $recompute }.GetNewClosure())
    $grid.Add_CellEndEdit({ & $recompute }.GetNewClosure())
    & $recompute
}

# ============================================================================
# Build the connection up front (before the wizard) so the breadcrumb's later
# stages reflect a real session and pick steps have a live buffer to read. The
# decision tree + point-source are pure WinForms and could run before connecting,
# but a single connect here keeps the lifecycle identical to drilljig.cmd and
# lets the FIRST screen already say "Connected: <part>".
# ============================================================================
$procs = @(Get-Process | Where-Object { $_.ProcessName -eq "xtop" })
if ($procs.Count -eq 0) { throw "Creo (xtop.exe) is not running. Open Creo and the jig PART, then re-run." }
if ($procs.Count -gt 1) { throw "More than one Creo session is open. This tool expects exactly ONE." }
$proc = $procs[0]
$Env:PRO_DIRECTORY    = $proc.Path.TrimEnd("xtop.exe")
$Env:PRO_COMM_MSG_EXE = $proc.Path -replace "xtop.exe", "pro_comm_msg.exe"

try { New-Object -ComObject pfcls.pfcAsyncConnection | Out-Null }
catch {
    $reg = $proc.Path -replace "Common Files(.*)$", "Parametric\bin\vb_api_register.bat"
    Start-Process -Wait -FilePath $reg
}

$async      = New-Object -ComObject pfcls.pfcAsyncConnection
$connection = $async.Connect($null, $null, $null, $null)
$session    = $connection.Session
$model      = $session.GetActiveModel()
if ($null -eq $model) { throw "No active model. Open the jig PART (default datum planes; target datum points if predefined) first." }

$modelFile = ""
try { $modelFile = [string]$model.FileName } catch {}
if ($modelFile -match '\.asm(\.\d+)?$') {
    Write-Host ""
    Write-Host "  STOP: the active model is an ASSEMBLY ($modelFile)." -ForegroundColor Yellow
    Write-Host "  This tool builds + drills a single PART. Open the jig PART itself, then re-run." -ForegroundColor Yellow
    $connection.Disconnect($null)
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

# config suppress (restored in finally)
$origVisibleMapkeys = $null
$origDynamicPreview = $null
try { $vals = $session.GetConfigOptionValues("visible_mapkeys"); if ($null -ne $vals -and $vals.Count -gt 0) { $origVisibleMapkeys = $vals.Item(0) } } catch {}
try { $vals = $session.GetConfigOptionValues("dynamic_preview"); if ($null -ne $vals -and $vals.Count -gt 0) { $origDynamicPreview = $vals.Item(0) } } catch {}
try { $session.SetConfigOption("visible_mapkeys", "no") | Out-Null; $session.SetConfigOption("dynamic_preview", "no") | Out-Null } catch {}

$pfcType = New-Object -ComObject pfcls.pfcModelItemType

$judgeCfg = Get-JudgeConfig -RepoRoot $ScriptDir -DefaultModel "sonnet"

# wire the engine to this session + route its log into the wizard
Initialize-DrilljigCore -Session $session -Model $model -TypeObj $pfcType -DataDir $dataDir -Log $djLogger
$ctx.Session = $session
$ctx.Model   = $model
$ctx.Type    = $pfcType
$ctx.ModelName = $modelFile
$ctx.Connected = $true

# ============================================================================
# Blind-evaluator box check (mirrors drilljig.cmd's Invoke-BoxEval). Returns a
# bool gate; writes the eval packet either way. Uses the module-scope handles.
# ============================================================================
function Invoke-BoxEval {
    param([string]$Operation, $Expected)
    $excl = New-ExcludeTypes -TypeObj $pfcType
    $ext  = Measure-Extents -Solid $model -ExcludeTypes $excl
    $truth = @{}
    $measuredSorted = $null
    if ($null -ne $ext) {
        $measuredSorted = @($ext | Sort-Object -Descending | ForEach-Object { [math]::Round([double]$_, 4) })
        $truth["measured_extents_sorted_desc"] = $measuredSorted
    } else {
        $truth["measured_extents_sorted_desc"] = $null
        $truth["note"] = "EvalOutline returned no outline (the solid may not exist yet)"
    }
    $reqMap = @{}
    foreach ($e in $Expected) { $reqMap[[string]$e.Dim] = [double]$e.Value }
    $truth["requested_dims"] = $reqMap
    $expectedVals = @($Expected | ForEach-Object { [double]$_.Value })
    $measuredVals = if ($null -ne $measuredSorted) { @($measuredSorted | ForEach-Object { [double]$_ }) } else { @() }
    $numeric = Test-ExtentsMatch -Expected $expectedVals -Measured $measuredVals -Tol 0.1
    $claims = @($Expected | ForEach-Object { "the box {0} is {1}" -f $_.Dim.ToLower(), $_.Value })
    $modelName = try { [string]$model.FileName } catch { "(unknown)" }
    $claim = New-EvalClaim -Tool "drilljig-gui" -Operation $Operation -Claims $claims
    $slice = Get-GeometrySlice -Model $modelName -Truth $truth
    $base = ($modelName -replace '\.(prt|asm)(\.\d+)?$','') -replace '[^\w\-]','_'
    $packetPath = Join-Path $ScriptDir ($base + "_eval.json")
    $when = (Get-Date).ToString("o")
    Write-EvalPacket -Path $packetPath -Claim $claim -Slice $slice -WhenIso $when | Out-Null
    $packetObj = Get-Content $packetPath -Raw | ConvertFrom-Json
    $verdict = Invoke-BlindJudge -Packet $packetObj -Config $judgeCfg
    return (Show-ConvergenceReport -Verdict $verdict -Title "Blind evaluator: $Operation" -Numeric $numeric)
}

# ============================================================================
# WIZARD STEPS
# ============================================================================
$steps = New-Object System.Collections.ArrayList

# Initialise the tree cursor at the first root node.
try {
    if (-not (Test-Path $ctx.TreePath)) { throw "Decision tree not found at: $($ctx.TreePath)" }
    $treeRoot = Get-Content $ctx.TreePath -Raw | ConvertFrom-Json
    $ctx.TreeNode = @($treeRoot)[0]
} catch { throw "Could not load the decision tree: $($_.Exception.Message)" }

# ---- STAGE: Bushing -- the decision tree, descended card-by-card -----------
# This single step re-renders in place as the user picks each answer. It walks
# 'question' nodes as choice cards; at an 'outcome' it resolves the hole diameter
# (catalog pick or fixed OD) and marks the tree done, enabling Next.
$treeStep = New-WizardStep -Key 'tree' -Title 'Bushing & hole size' -Stage 'Bushing' -Kind 'choice' -PrimaryText 'Next' `
    -Validate { param($c) return [bool]$c.TreeDone } `
    -Build {
        param($panel, $c, $wiz)
        $node = $c.TreeNode

        # DONE? Show a CONFIRMATION (not the cards again) so the user can't keep
        # cycling. A 'Change selection' button resets the whole pick cursor and
        # re-renders, letting them re-walk. This is the user's ask 2026-06-26:
        # "once the user goes through the options, confirm a bushing is selected;
        # if they need to change, a change button."
        if ($c.TreeDone) {
            $active = if ($c.Picks.Count -gt 0) { $c.Picks[$c.Picks.Count - 1] } else { $null }
            if ($null -ne $active) {
                Add-Para $panel "Bushing selected:" 4 24 'gray' $true
                Add-Para $panel ([string]$active.Bushing) 30 26 '' $true
                $dia = [double]$active.HoleDiameter
                $line = ("Hole diameter (= OD): {0}`"" -f $dia)
                if ($null -ne $active.BushingLength) { $line += ("    Bushing length: {0}`"" -f [double]$active.BushingLength) }
                Add-Para $panel $line 60 24 'green'
                if ($active.PartNumber -and $active.PartNumber -notmatch 'n/a|unspecified') {
                    Add-Para $panel ("Part number: {0}" -f $active.PartNumber) 86 22 'gray'
                }
                Add-Para $panel ([char]0x2713 + " Registered. Press Next to continue, or change the selection below.") 116 24 'green' $true
            } else {
                Add-Para $panel "Selection complete (no catalog bushing was resolved)." 4 40 'gray'
            }
            # Change button: reset the pick cursor to the FIRST tree node + re-render.
            $btnChange = New-Object System.Windows.Forms.Button
            $btnChange.Text = 'Change selection'
            $btnChange.Size = New-Object System.Drawing.Size(180, 34)
            $btnChange.Location = New-Object System.Drawing.Point(8, 152)
            $btnChange.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            $thm = $script:WizTheme
            $btnChange.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90,104,132)
            $btnChange.BackColor = if ($thm) { $thm.CanvasBack } else { [System.Drawing.Color]::FromArgb(30,42,68) }
            $btnChange.ForeColor = Get-UiColor ''
            $btnChange.Add_Click({
                $old = $ErrorActionPreference
                try {
                    $ErrorActionPreference = 'Continue'
                    $c.TreeDone = $false; $c.PendingSpec = $null; $c.BushStage = $null
                    $c.Grouped = $null; $c.BushOD = $null; $c.BushLen = $null
                    $c.TreeNode = @($treeRoot)[0]
                    $c.Path.Clear()
                    if ($c.Picks.Count -gt 0) { $c.Picks.Clear() }
                    $c.HoleDia = $null; $c.BushingLen = $null
                    $wiz.Rerender()
                } catch { try { $wiz.LogError($_, 'change bushing') } catch {} }
                finally { $ErrorActionPreference = $old }
            }.GetNewClosure())
            $panel.Controls.Add($btnChange)
            return
        }

        # Are we mid bushing-pick (OD/length/ID)? Render that sub-flow instead.
        if ($null -ne $c.PendingSpec) {
            $rows = Get-CatalogRows -Spec $c.PendingSpec
            if ($rows.Count -eq 0) {
                Add-Para $panel "No catalog rows match this branch. (file: $(Split-Path $c.PendingSpec.File -Leaf))" 8 40 'Firebrick'
                $c.PendingSpec = $null; $c.TreeDone = $true
                return
            }
            # Stash the grouped catalog in the PERSISTENT context ($c.Grouped), NOT a
            # Build-local: the OnPick scriptblock fires AFTER Build returns and a plain
            # {..} does not capture Build locals, so a Build-local $grouped would be
            # $null at click time -> "Cannot index into a null array". $cc.Grouped lives.
            $c.Grouped = Group-CatalogByOD -Rows $rows
            if ($c.BushStage -eq 'od' -or $null -eq $c.BushStage) {
                Add-Para $panel "Select the OD (this IS the hole diameter):" 4 26 $null $true
                $opts = @()
                foreach ($g in $c.Grouped) {
                    $nlen = $g.Lengths.Count
                    $opts += @{ Title = ('OD ' + $g.ODLabel); Subtitle = ("hole {0:0.###}`"  -  {1} length{2}" -f $g.OD, $nlen, $(if($nlen -eq 1){''}else{'s'})) }
                }
                Add-WizardChoiceCards -Panel $panel -Options $opts -Context $c -Wizard $wiz -Top 40 -OnPick {
                    param($i,$opt,$cc,$w)
                    $cc.BushOD = $cc.Grouped[$i]
                    $cc.BushStage = 'len'
                }
                return
            }
            if ($c.BushStage -eq 'len') {
                $od = $c.BushOD
                Add-Para $panel ("OD {0}  ->  select length:" -f $od.ODLabel) 4 26 $null $true
                $opts = @()
                foreach ($l in $od.Lengths) {
                    $nid = $l.Rows.Count
                    $opts += @{ Title = ($l.LenLabel + ' Lg'); Subtitle = $(if ($nid -gt 1) { "$nid ID options" } else { 'single ID' }) }
                }
                Add-WizardChoiceCards -Panel $panel -Options $opts -Context $c -Wizard $wiz -Top 40 -OnPick {
                    param($i,$opt,$cc,$w)
                    $cc.BushLen = $cc.BushOD.Lengths[$i]
                    $cc.BushStage = 'id'
                }
                return
            }
            if ($c.BushStage -eq 'id') {
                $od = $c.BushOD; $ln = $c.BushLen
                Add-Para $panel ("OD {0} x {1} Lg  ->  pick ID (or leave unspecified - it does not change the jig hole):" -f $od.ODLabel, $ln.LenLabel) 4 40 $null $true
                $opts = @()
                $opts += @{ Title = 'Any ID'; Subtitle = 'leave unspecified (OD drives the hole)' }
                foreach ($r in $ln.Rows) {
                    $bit = ''
                    if ($r.PSObject.Properties.Name -contains 'DrillBitSize' -and $r.DrillBitSize) { $bit = "  ($($r.DrillBitSize))" }
                    $opts += @{ Title = ('ID ' + $r.ID); Subtitle = ("{0}{1}" -f $r.PartNumber, $bit) }
                }
                Add-WizardChoiceCards -Panel $panel -Options $opts -Context $c -Wizard $wiz -Top 56 -CardWidth 200 -CardHeight 96 -OnPick {
                    param($i,$opt,$cc,$w)
                    $pick = $null
                    if ($i -eq 0) {
                        $pick = New-IdUnspecifiedPick -ODLabel $cc.BushOD.ODLabel -LenLabel $cc.BushLen.LenLabel -Rows $cc.BushLen.Rows
                    } else {
                        $pick = $cc.BushLen.Rows[$i - 1]
                    }
                    $od = [double]$pick.OD
                    $blen = $null; try { if ($null -ne $pick.Length) { $blen = [double]$pick.Length } } catch {}
                    [void]$cc.Picks.Add([pscustomobject]@{ HoleDiameter=$od; BushingLength=$blen; Bushing=$pick.EasyName; PartNumber=$pick.PartNumber; Outcome=$cc.TreeNode.label })
                    $cc.PendingSpec = $null; $cc.BushStage = $null; $cc.TreeDone = $true
                }
                return
            }
        }

        # Normal tree descent.
        if ($null -eq $node) { $c.TreeDone = $true; Add-Para $panel "Tree finished." ; return }
        switch ($node.kind) {
            'question' {
                $kids = @($node.children)
                Add-Para $panel ([string]$node.label) 4 30 $null $true
                if ($node.notes) { Add-Para $panel ([string]$node.notes) 34 22 'Gray' }
                $opts = @()
                foreach ($k in $kids) { $opts += @{ Title = [string]$k.label; Subtitle = '' } }
                Add-WizardChoiceCards -Panel $panel -Options $opts -Context $c -Wizard $wiz -Top 64 -OnPick {
                    param($i,$opt,$cc,$w)
                    $chosen = @($cc.TreeNode.children)[$i]
                    [void]$cc.Path.Add([string]$chosen.label)
                    # descend: an 'option' carries a single child to continue into.
                    $next = $chosen
                    while ($next.kind -eq 'option' -and @($next.children).Count -ge 1) { $next = @($next.children)[0] }
                    $cc.TreeNode = $next
                    # if we've reached an outcome, resolve it now.
                    if ($next.kind -eq 'outcome') {
                        $spec = Get-CatalogSpec -Label $next.label
                        if ($spec) { $cc.PendingSpec = $spec; $cc.BushStage = 'od' }
                        else {
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
                if ($spec) { $c.PendingSpec = $spec; $c.BushStage = 'od'; $wiz.Rerender(); return }
                $fixed = Get-FixedOdSpec -Label $node.label
                if ($null -ne $fixed) {
                    [void]$c.Picks.Add([pscustomobject]@{ HoleDiameter=[double]$fixed; BushingLength=$null; Bushing='(fixed OD, no bushing)'; PartNumber='(n/a)'; Outcome=$node.label })
                }
                Add-Para $panel ([string]$node.label) 4 60
                $c.TreeDone = $true
                return
            }
            default {
                # option/bushing/pattern wrapper: skip into its first child
                $kids = @($node.children)
                if ($kids.Count -ge 1) { $c.TreeNode = $kids[0]; $wiz.Rerender(); return }
                $c.TreeDone = $true
            }
        }
    } `
    -OnNext {
        param($c, $wiz)
        # finalise STAGE-1 results into the shared vars (last pick wins)
        if ($c.Picks.Count -gt 0) {
            $active = $c.Picks[$c.Picks.Count - 1]
            $c.HoleDia = [double]$active.HoleDiameter
            if ($null -ne $active.BushingLength) { $c.BushingLen = [double]$active.BushingLength }
        }
        $c.Is3dPrint = @($c.Path | Where-Object { $_ -match '(?i)3d\s*print' }).Count -gt 0
        # chips
        if ($null -ne $c.HoleDia) { $wiz.SetChip('hole', ("hole {0:0.###}`"" -f $c.HoleDia), 'set') }
        if ($null -ne $c.BushingLen) { $wiz.SetChip('depth', ("depth {0:0.###}`"" -f $c.BushingLen), 'set') }
        return $true
    }
[void]$steps.Add($treeStep)

# ---- STAGE: Layout -- point-source choice; BOTH editors EMBEDDED in-window ------
# Renders mode-based: no mode chosen -> three tiles. Orthogrid -> the inline grid
# editor (Add-InlineOrthogrid); Custom -> the inline points editor
# (Add-InlineCustomPoints) - BOTH right in the canvas, NO popup window. A "Change
# layout type" button returns to the tiles. LayoutMode ('orthogrid'|'custom'|$null)
# tracks which view is showing.
$layoutStep = New-WizardStep -Key 'layout' -Title 'How are the hole points defined?' -Stage 'Layout' -Kind 'choice' -PrimaryText 'Next' `
    -Validate {
        param($c)
        # orthogrid/custom require a valid layout; predefined is ready once chosen.
        if ($c.PointMode -eq 'orthogrid' -or $c.PointMode -eq 'custom') { return [bool]$c.OrthoValid }
        return [bool]$c.LayoutPicked
    } `
    -Build {
        param($panel, $c, $wiz)

        # VIEW 1/2: an inline editor (orthogrid OR custom), embedded - no popup.
        if ($c.LayoutMode -eq 'orthogrid' -or $c.LayoutMode -eq 'custom') {
            $isGrid = ($c.LayoutMode -eq 'orthogrid')
            $hdr = if ($isGrid) { "Orthogrid - set the grid; the plate is sized to fit the holes + clearance." }
                   else { "Custom points - add each hole's X / Z offset; the plate is sized to fit them." }
            Add-Para $panel $hdr 4 24 'gray'
            # NB: do NOT name this $host -- $host is a PowerShell automatic variable.
            $editHost = New-Object System.Windows.Forms.Panel
            $editHost.Location = New-Object System.Drawing.Point(0, 32)
            $editHost.Size     = New-Object System.Drawing.Size(($panel.Width - 4), 300)
            $editHost.BackColor = [System.Drawing.Color]::Transparent
            $panel.Controls.Add($editHost)
            if ($isGrid) { Add-InlineOrthogrid -Panel $editHost -Context $c -Wizard $wiz }
            else         { Add-InlineCustomPoints -Panel $editHost -Context $c -Wizard $wiz }
            $btnBackType = New-Object System.Windows.Forms.Button
            $btnBackType.Text = 'Change layout type'
            $btnBackType.Size = New-Object System.Drawing.Size(170, 30)
            $btnBackType.Location = New-Object System.Drawing.Point(8, 338)
            $btnBackType.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            $btnBackType.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90,104,132)
            $btnBackType.BackColor = if ($script:WizTheme) { $script:WizTheme.CanvasBack } else { [System.Drawing.Color]::FromArgb(30,42,68) }
            $btnBackType.ForeColor = Get-UiColor ''
            $btnBackType.Add_Click({ $c.LayoutMode = $null; $c.PointMode='predefined'; $c.OrthoValid=$false; $wiz.Rerender() }.GetNewClosure())
            $panel.Controls.Add($btnBackType)
            return
        }

        # VIEW 0: the three tiles
        Add-Para $panel "Pick how the hole points are defined." 4 24 'Gray'
        $opts = @(
            @{ Title = 'Predefined'; Subtitle = 'datum points already in the part - select them in Creo later' },
            @{ Title = 'Orthogrid';  Subtitle = 'a regular Nx x Nz grid - edited right here in the window' },
            @{ Title = 'Custom';     Subtitle = 'type each point''s X / Z offset - edited right here too' }
        )
        Add-WizardChoiceCards -Panel $panel -Options $opts -Context $c -Wizard $wiz -Top 40 -CardHeight 120 -AfterPick 'rerender' -OnPick {
            param($i,$opt,$cc,$w)
            if ($i -eq 0) {
                $cc.PointMode = 'predefined'; $cc.OrthoGeo = $null; $cc.OrthoValid = $false; $cc.LayoutMode = $null
                $w.SetChip('layout', 'layout: predefined', 'set')
            } elseif ($i -eq 1) {
                # switch to the EMBEDDED grid editor view (no popup)
                $cc.PointMode = 'orthogrid'; $cc.LayoutMode = 'orthogrid'; $cc.OrthoValid = $false
            } else {
                # switch to the EMBEDDED custom-points editor view (no popup)
                $cc.PointMode = 'custom'; $cc.LayoutMode = 'custom'; $cc.OrthoValid = $false
            }
            $cc.LayoutPicked = $true
        }
        # echo for predefined (the editors show their own readout)
        if ($c.LayoutPicked -and $c.PointMode -eq 'predefined') {
            Add-Para $panel (([char]0x2713) + " Selected: Predefined - you will pick the points in Creo    (press Next)") 180 24 'DarkGreen' $true
        }
    } `
    -OnNext { param($c,$wiz) return $true }
[void]$steps.Add($layoutStep)

# ---- STAGE: Datums -- capture the 3 base datums (auto / pick) --------------
$datumStep = New-WizardStep -Key 'datums' -Title 'Base datum planes' -Stage 'Datums' -Kind 'pick' -PrimaryText 'Continue to box' `
    -Validate { param($c) return ($null -ne $c.Planes -and (@($c.Planes | Where-Object { $null -ne $_.BaseId }).Count -ge 3)) } `
    -Build {
        param($panel, $c, $wiz)
        if ($null -eq $c.Planes) {
            $c.Planes = @(
                [pscustomobject]@{ Label="Top";   Hint="TOP";   Offset=0.0; Sym=$null; BaseId=$null; FeatId=$null }
                [pscustomobject]@{ Label="Side";  Hint="SIDE";  Offset=0.0; Sym=$null; BaseId=$null; FeatId=$null }
                [pscustomobject]@{ Label="Front"; Hint="FRONT"; Offset=0.0; Sym=$null; BaseId=$null; FeatId=$null }
            )
        }
        # try the API first (no clicks)
        if (-not ($null -ne $c.Planes -and (@($c.Planes | Where-Object { $null -ne $_.BaseId }).Count -ge 3))) {
            $picks = @(Find-DefaultDatumPicks)
            $found = @($picks | Where-Object { $null -ne $_.Role } | Select-Object -ExpandProperty Role -Unique)
            if (@($found).Count -ge 3) {
                $byRole = @{}; foreach ($pk in $picks) { if ($null -ne $pk.Role -and -not $byRole.ContainsKey($pk.Role)) { $byRole[$pk.Role] = $pk.Id } }
                foreach ($p in $c.Planes) { $p.BaseId = [int]$byRole[$p.Label] }
                $c.AutoMapped = $true
            }
        }
        if ($null -ne $c.Planes -and (@($c.Planes | Where-Object { $null -ne $_.BaseId }).Count -ge 3)) {
            $lines = "Found the three default datums by name - no clicks needed:" + [Environment]::NewLine
            foreach ($p in $c.Planes) { $lines += ("    {0,-5} -> datum id {1}" -f $p.Hint, $p.BaseId) + [Environment]::NewLine }
            Add-Para $panel $lines 8 110 $null $false
            $wiz.SetChip('datums', 'datums: auto-mapped', 'set')
        } else {
            Add-ArmBanner $panel ("In Creo, Ctrl-click ALL THREE default datums (TOP, SIDE, FRONT) - any order." + [Environment]::NewLine + "They are matched to roles by NAME, not click order.") 8
            Add-VerifyControls -Panel $panel -Context $c -Wizard $wiz -Top 130 -OnVerify {
                param($cc, $w)
                $picks = @(Read-SelectionPlanePicks)
                if ($picks.Count -eq 0) { return @{ Ok=$false; Message='Nothing selected. Ctrl-click the three datums in Creo, then verify.' } }
                $byRole = @{}; $conflict = $false
                foreach ($pk in $picks) { if ($null -eq $pk.Role) { continue }; if ($byRole.ContainsKey($pk.Role)) { $conflict=$true; continue }; $byRole[$pk.Role] = $pk.Id }
                $all = ($byRole.ContainsKey('Top') -and $byRole.ContainsKey('Side') -and $byRole.ContainsKey('Front'))
                if ($conflict) { return @{ Ok=$false; Message='Two datums matched the same role - re-pick.' } }
                if (-not $all) {
                    $missing = @('Top','Side','Front' | Where-Object { -not $byRole.ContainsKey($_) })
                    return @{ Ok=$false; Message=("Could not match all three by name (missing: {0}). Re-pick." -f ($missing -join ', ')) }
                }
                foreach ($p in $cc.Planes) { $p.BaseId = [int]$byRole[$p.Label] }
                $cc.AutoMapped = $true
                $w.SetChip('datums', 'datums: mapped', 'set')
                $msg = ''
                foreach ($p in $cc.Planes) { $msg += ("{0} -> id {1}    " -f $p.Hint, $p.BaseId) }
                return @{ Ok=$true; Message=$msg }
            }
        }
    } `
    -OnNext { param($c,$wiz) return $true }
[void]$steps.Add($datumStep)

# ---- STAGE: Box -- SPLIT into Box-A (create planes + open sketcher) and Box-B
#      (finish + extrude), so the manual rectangle draw is a normal wizard PAUSE
#      between two steps, NOT a blocking modal. A MessageBox shown while the user
#      is interacting with Creo can be drawn BEHIND the Creo window and freeze the
#      whole wizard (the "can't click anything" bug). The split keeps the message
#      loop alive: Box-A stops after arming the sketcher; the user draws in Creo;
#      Box-B finishes. $c.BoxArmed gates the two.
$boxStepA = New-WizardStep -Key 'box-a' -Title 'Build the parametric box' -Stage 'Box' -Kind 'run' -PrimaryText 'Create planes + open sketcher' `
    -Validate { param($c) return $true } `
    -Build {
        param($panel, $c, $wiz)
        # resolve the three offsets (SIDE = bushing len; TOP/FRONT = plate W/H when a grid exists)
        foreach ($p in $c.Planes) {
            if ($p.Label -eq 'Side'  -and $null -ne $c.BushingLen) { $p.Offset = [double]$c.BushingLen }
            elseif ($p.Label -eq 'Top'   -and $null -ne $c.OrthoGeo) { $p.Offset = [double]$c.OrthoGeo.Width }
            elseif ($p.Label -eq 'Front' -and $null -ne $c.OrthoGeo) { $p.Offset = [double]$c.OrthoGeo.Height }
        }
        if ($c.BoxArmed) {
            Add-Para $panel ("Planes created and the sketcher is open in Creo." + [Environment]::NewLine +
                             "Draw the rectangle there, then press Next.") 8 60 'DarkGreen' $true
            return
        }
        $msg = "The box is three offset datum planes + an extrude between them." + [Environment]::NewLine + [Environment]::NewLine
        $msg += "Offsets:" + [Environment]::NewLine
        foreach ($p in $c.Planes) {
            $dim = switch ($p.Label) { 'Side' {'width/length'} 'Top' {'height'} 'Front' {'depth'} default {''} }
            $src = ''
            if ($p.Label -eq 'Side'  -and $null -ne $c.BushingLen) { $src = '(from bushing length)' }
            if ($p.Label -eq 'Top'   -and $null -ne $c.OrthoGeo)   { $src = '(from plate width)' }
            if ($p.Label -eq 'Front' -and $null -ne $c.OrthoGeo)   { $src = '(from plate height)' }
            $msg += ("    {0,-5} ({1,-12}) = {2,-7} {3}" -f $p.Hint, $dim, $p.Offset, $src) + [Environment]::NewLine
        }
        # any plane still 0 (no grid / no bushing) gets a small editable field
        $needsManual = @($c.Planes | Where-Object { [double]$_.Offset -le 0 })
        $top = 8 + ($c.Planes.Count + 4) * 18
        Add-Para $panel $msg 8 $top 'Gray'
        $y = $top + 8
        foreach ($p in $needsManual) {
            $lab = New-Object System.Windows.Forms.Label
            $lab.Text = ("{0} offset:" -f $p.Hint); $lab.Location = New-Object System.Drawing.Point(8, ($y+3)); $lab.Size = New-Object System.Drawing.Size(120, 20)
            $panel.Controls.Add($lab)
            $tb = New-Object System.Windows.Forms.TextBox
            $tb.Location = New-Object System.Drawing.Point(132, $y); $tb.Size = New-Object System.Drawing.Size(80, 22); $tb.Text = '1.0'
            $tb.Tag = $p
            $tb.Add_TextChanged({ param($s,$e) $v=0.0; if ([double]::TryParse($s.Text,[ref]$v) -and $v -gt 0) { $s.Tag.Offset = $v } }.GetNewClosure())
            $p.Offset = 1.0
            $panel.Controls.Add($tb)
            $y += 30
        }
        Add-Para $panel ("Press the button below: Creo creates the three planes and opens the sketcher. " +
                         "Then you draw a rough rectangle (2 clicks) in Creo - the next screen finishes it.") $y 50 'Gray'
    } `
    -OnNext {
        param($c, $wiz)
        if ($c.BoxArmed) { return $true }   # already armed (came back + re-Next) -> advance to Box-B
        $script:GuiWiz = $wiz
        $wiz.BeginRun('Creating planes + opening the sketcher...')
        $wiz.Log('Creating three offset datum planes (no clicks)...')
        foreach ($p in $c.Planes) {
            $wiz.Pump()
            $res = New-OffsetPlane -Label $p.Label -Offset $p.Offset -BaseId $p.BaseId
            $p.Sym = $res.Symbol; $p.FeatId = $res.FeatId
        }
        # show planes
        foreach ($p in @($c.Planes | Where-Object { $null -ne $_.FeatId })) {
            $wiz.Pump()
            Invoke-Macro "show $($p.Label) plane (id $($p.FeatId))" ((Get-SelectByIdMacro -FeatId $p.FeatId) + "~ Command ``ProCmdViewShow@PopupMenuTree``;")
        }
        $c.Made = @($c.Planes | Where-Object { $null -ne $_.Sym })
        if ($c.Made.Count -eq 0) {
            $wiz.Log('No offset planes produced a drivable dim - cannot build the box.')
            $wiz.SetChip('box', 'box: failed', 'aborted')
            Show-WizardMessage -Text 'No offset planes were created. Inspect Creo, then close + re-run.' -Title 'Drill Jig Builder' -Buttons 'OK' -Icon 'Warning' | Out-Null
            return $false
        }
        $side = @($c.Made | Where-Object { $_.Label -eq 'Side' }); $side = if ($side.Count -gt 0) { $side[0] } else { $null }
        $c.SidePlane = $side
        if ($null -eq $side -or $null -eq $side.BaseId -or $null -eq $side.FeatId) {
            $wiz.Log('SIDE plane is missing a base/offset id - cannot build hands-free.')
            $wiz.SetChip('box', 'box: failed', 'aborted')
            Show-WizardMessage -Text 'The SIDE plane was not created cleanly. Inspect Creo, then close + re-run.' -Title 'Drill Jig Builder' -Buttons 'OK' -Icon 'Warning' | Out-Null
            return $false
        }
        $c.SketchPlaneId = [int]$side.BaseId
        $c.ExtrudeToId   = [int]$side.FeatId

        # MACRO A: arm the extrude + sketcher. Returns immediately; the user now
        # draws the rectangle in Creo and presses Next (Box-B). NO blocking modal.
        $wiz.Log('Opening the sketcher on the SIDE datum...')
        $mkArm = (Get-SelectByIdMacro -FeatId ([int]$c.SketchPlaneId)) +
                 "~ Command ``ProCmdFtExtrude``;" +
                 "~ Command ``ProCmdViewSketchView``;" +
                 "~ Command ``ProCmdSketRectangle`` 1;"
        Invoke-Macro "arm extrude + rectangle" $mkArm
        $c.BoxArmed = $true
        $wiz.SetChip('box', 'box: sketcher open', 'set')
        $wiz.Log('Sketcher is open in Creo - draw the rectangle, then press Next.')
        return $true   # advance to Box-B (the manual draw happens between the steps)
    }
[void]$steps.Add($boxStepA)

# Box-B: the user has drawn the rectangle in Creo (no modal blocked the wizard);
# on Next, finish the sketch + extrude up to the SIDE offset plane + blind-eval.
$boxStepB = New-WizardStep -Key 'box-b' -Title 'Finish the box' -Stage 'Box' -Kind 'run' -PrimaryText 'Finish + extrude' `
    -Validate { param($c) return [bool]$c.BoxArmed } `
    -Build {
        param($panel, $c, $wiz)
        Add-ArmBanner $panel ("In Creo's sketcher: click one corner of the rectangle, then the opposite corner." + [Environment]::NewLine +
                              "Size doesn't matter. Press Esc to finish the rectangle.") 8
        Add-Para $panel ("When the rectangle is drawn, press 'Finish + extrude' - Creo finishes the sketch and " +
                         "extrudes up to the SIDE offset plane automatically.") 120 50 'Gray'
    } `
    -OnNext {
        param($c, $wiz)
        $script:GuiWiz = $wiz
        $wiz.BeginRun('Finishing the sketch + extruding...')
        $stamp = $null; try { $stamp = $model.VersionStamp } catch {}
        # MACRO B: finish the sketch, extrude up to the SIDE offset plane, confirm.
        $wiz.Log('Finishing the sketch and extruding up to the SIDE offset plane...')
        $mkFinish = "~ Command ``ProCmdSketDone``;" +
                    "~ Select ``main_dlg_cur`` ``maindashInst0.depth_flyout``;" +
                    "~ Close ``main_dlg_cur`` ``maindashInst0.depth_flyout``;" +
                    "~ Activate ``main_dlg_cur`` ``maindashInst0.toselected`` 1;" +
                    "~ Trigger ``extrev_1_placement.0.0`` ``PH.section_select_list`` ``0``;" +
                    "~ Trigger ``extrev_1_placement.0.0`` ``PH.section_select_list`` ````;" +
                    (Get-SelectDatumByIdMacro -FeatId ([int]$c.ExtrudeToId)) +
                    "~ Enter ``main_dlg_cur`` ``dashInst0.Quit``;" +
                    "~ Exit  ``main_dlg_cur`` ``dashInst0.Quit``;" +
                    "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"
        Invoke-Macro "finish + extrude + confirm" $mkFinish
        if ($null -ne $stamp) { for ($i=0; $i -lt 100; $i++) { try { if ($model.VersionStamp -ne $stamp) { break } } catch {}; Start-Sleep -Milliseconds 50 } }

        # blind-evaluate the box
        $expected = foreach ($mp in $c.Made) {
            $dim = switch ($mp.Label) { 'Side' {'Width'} 'Top' {'Height'} 'Front' {'Depth'} default {$mp.Label} }
            [pscustomobject]@{ Dim=$dim; Value=[double]$mp.Offset }
        }
        $c.BuildConfirmed = Invoke-BoxEval -Operation 'build-box' -Expected @($expected)
        $c.BoxBuilt = $true
        $wiz.MarkCommitted()    # geometry now exists; no Back past here
        if ($c.BuildConfirmed) { $wiz.SetChip('box', 'box: built + verified', 'built') }
        else { $wiz.SetChip('box', 'box: built (unverified)', 'unverified') }
        $wiz.Log('Box built.')
        return $true
    }
[void]$steps.Add($boxStepB)

# ---- STAGE: Drill -- 2.5 points + 2b corner round + 3 drill + 4 relief -----
# One RUN step does the remaining hands-free Creo work (after, optionally, a
# predefined-points hand-pick sub-step). Split so the predefined pick is armed/verified.
if ($true) {
    # predefined-points pick step (only meaningful when PointMode=predefined; it
    # self-skips by validating true + showing 'nothing to do' otherwise).
    $pickPointsStep = New-WizardStep -Key 'pickpoints' -Title 'Target datum points' -Stage 'Drill' -Kind 'pick' -PrimaryText 'Continue' `
        -Validate {
            param($c)
            if ($c.PointMode -ne 'predefined') { return $true }     # points auto-created later
            return (@($c.PointIDs).Count -ge 1)
        } `
        -Build {
            param($panel, $c, $wiz)
            if ($c.PointMode -ne 'predefined') {
                Add-Para $panel ("The {0} layout will be created automatically as datum points in the next step - nothing to pick here." -f $c.PointMode) 8 60 'Gray'
                return
            }
            Add-ArmBanner $panel ("In Creo, select the target datum points (they already exist in the part)." + [Environment]::NewLine + "Then click verify.") 8
            Add-VerifyControls -Panel $panel -Context $c -Wizard $wiz -Top 130 -OnVerify {
                param($cc, $w)
                $r = Resolve-SelectedPointIds
                if (@($r.Ids).Count -eq 0) { return @{ Ok=$false; Message='No datum points resolved. Select datum points (or a point-bearing feature), then verify.' } }
                $cc.PointIDs = @($r.Ids)
                $w.SetChip('points', ("points: {0}" -f $cc.PointIDs.Count), 'set')
                $extra = if (@($r.Rejected).Count -gt 0) { (" ({0} non-point item(s) ignored)" -f @($r.Rejected).Count) } else { '' }
                return @{ Ok=$true; Message=("Captured {0} datum point(s).{1}" -f $cc.PointIDs.Count, $extra) }
            }
        } `
        -OnNext { param($c,$wiz) return $true }
    [void]$steps.Add($pickPointsStep)
}

$drillStep = New-WizardStep -Key 'drill' -Title 'Create points, round corners, and drill' -Stage 'Drill' -Kind 'run' -PrimaryText 'Drill the holes' `
    -Validate { param($c) return $true } `
    -Build {
        param($panel, $c, $wiz)
        $n = if ($null -ne $c.OrthoGeo) { $c.OrthoGeo.Count } else { @($c.PointIDs).Count }
        $dia = if ($null -ne $c.HoleDia -and [double]$c.HoleDia -gt 0) { [double]$c.HoleDia } else { 0 }
        $msg = "Ready to drill." + [Environment]::NewLine + [Environment]::NewLine
        if ($null -ne $c.OrthoGeo) { $msg += ("- create {0} datum points from the {1} layout (3-plane intersections, no picks)" -f $c.OrthoGeo.Count, $c.OrthoGeo.Mode) + [Environment]::NewLine }
        if (-not $noCornerRound)   { $msg += ("- auto-round the box corner edges at radius {0}" -f $cornerRadius) + [Environment]::NewLine }
        $msg += ("- drill {0} through-hole(s) at diameter {1}`"" -f $n, $dia) + [Environment]::NewLine
        $relAuto = ($c.Is3dPrint -or $null -ne $c.OrthoGeo)
        $msg += ("- chip-relief holes: {0}" -f $(if ($relAuto) { 'yes (automatic)' } else { 'asked after drilling' })) + [Environment]::NewLine
        Add-Para $panel $msg 8 200 'Gray'
    } `
    -OnNext {
        param($c, $wiz)
        $script:GuiWiz = $wiz
        $wiz.BeginRun('Drilling...')

        # ---- STAGE 2.5: create datum points from the layout ----
        if ($null -ne $c.OrthoGeo) {
            $wiz.Log(("Creating {0} datum points ({1})..." -f $c.OrthoGeo.Count, $c.OrthoGeo.Mode))
            $topBaseId   = ($c.Planes | Where-Object { $_.Label -eq 'Top'   } | Select-Object -First 1).BaseId
            $frontBaseId = ($c.Planes | Where-Object { $_.Label -eq 'Front' } | Select-Object -First 1).BaseId
            $facePlaneId = if ($null -ne $c.SidePlane -and $null -ne $c.SidePlane.BaseId) { [int]$c.SidePlane.BaseId } else { $null }
            if ($null -ne $topBaseId -and $null -ne $frontBaseId -and $null -ne $facePlaneId) {
                $plan = Get-SharedPlanePlan -Points $c.OrthoGeo.Points
                $tol = 1e-6; $ok = $true
                $xPlaneIds = @()
                foreach ($xOff in $plan.XCoords) {
                    if ([math]::Abs([double]$xOff) -le $tol) { $xPlaneIds += [int]$topBaseId; continue }
                    $wiz.Pump()
                    $res = New-OffsetPlane -Label "X$($xPlaneIds.Count)" -Offset ([double]$xOff) -BaseId ([int]$topBaseId)
                    if ($null -eq $res.FeatId) { $ok = $false; break }
                    $xPlaneIds += [int]$res.FeatId
                }
                $zPlaneIds = @()
                if ($ok) {
                    foreach ($zOff in $plan.ZCoords) {
                        if ([math]::Abs([double]$zOff) -le $tol) { $zPlaneIds += [int]$frontBaseId; continue }
                        $wiz.Pump()
                        $res = New-OffsetPlane -Label "Z$($zPlaneIds.Count)" -Offset ([double]$zOff) -BaseId ([int]$frontBaseId)
                        if ($null -eq $res.FeatId) { $ok = $false; break }
                        $zPlaneIds += [int]$res.FeatId
                    }
                }
                if ($ok) {
                    for ($qi=0; $qi -lt $xPlaneIds.Count; $qi++) { if ([int]$xPlaneIds[$qi] -ne [int]$topBaseId) { $c.GridPlaneIds += [pscustomobject]@{ FeatId=[int]$xPlaneIds[$qi]; Axis='X'; Offset=[double]$plan.XCoords[$qi] } } }
                    for ($qi=0; $qi -lt $zPlaneIds.Count; $qi++) { if ([int]$zPlaneIds[$qi] -ne [int]$frontBaseId) { $c.GridPlaneIds += [pscustomobject]@{ FeatId=[int]$zPlaneIds[$qi]; Axis='Z'; Offset=[double]$plan.ZCoords[$qi] } } }
                    $beforePts = Get-PointIdSet -Model $model -TypeObj $pfcType
                    $pi = 0
                    foreach ($tri in $plan.Triples) {
                        $pi++
                        $wiz.SetProgress([Math]::Floor(($pi / $c.OrthoGeo.Count) * 100), ("point $pi / $($c.OrthoGeo.Count)"))
                        $macro = Build-IntersectPointMacro -PlaneIds @([int]$facePlaneId, [int]$xPlaneIds[$tri.Xi], [int]$zPlaneIds[$tri.Zi])
                        try { $session.RunMacro($macro) } catch { $ok = $false; break }
                    }
                    $newIds = Resolve-NewPointIds -Model $model -TypeObj $pfcType -Before $beforePts
                    if (@($newIds).Count -ge 1) { $c.GridPointIDs = @($newIds) }
                    if (@($newIds).Count -ne $c.OrthoGeo.Count) { $wiz.Log(("Point count: wanted {0}, got {1}." -f $c.OrthoGeo.Count, @($newIds).Count)) }
                }
                if ($c.GridPointIDs.Count -gt 0) {
                    $wiz.MarkCommitted()
                    try { $model.Regenerate($null) } catch {}
                    $wiz.SetChip('points', ("points: {0} created" -f $c.GridPointIDs.Count), 'built')
                } else {
                    $wiz.SetChip('points', 'points: creation failed', 'aborted')
                }
            }
        }

        # resolve the point id list for drilling
        if ($c.GridPointIDs.Count -gt 0) { $c.PointIDs = @($c.GridPointIDs) }
        if (@($c.PointIDs).Count -eq 0) {
            $wiz.Log('No points to drill - aborting drill.')
            $wiz.SetChip('drill', 'drill: no points', 'aborted')
            return $true   # advance to summary; nothing drilled
        }

        # body index
        $c.BodyIndex = 0
        $c.HoleDiaFinal = if ($null -ne $c.HoleDia -and [double]$c.HoleDia -gt 0) { [double]$c.HoleDia } else { 0.25 }

        # ---- STAGE 2b: auto corner round ----
        if (-not $noCornerRound) {
            $wiz.Log(("Auto-rounding box corner edges at radius {0}..." -f $cornerRadius))
            try {
                $cr = Invoke-AutoCornerRound -Session $session -Model $model -TypeObj $pfcType -Radius $cornerRadius
                $wiz.Log(("  corners: found $($cr.Found), matched $($cr.Matched)."))
                if ($cr.Matched -gt 0 -and $cr.TotalBatches -gt 0 -and $cr.ModelChanged -eq $cr.TotalBatches) { $wiz.SetChip('corners', 'corners: rounded', 'built') }
                elseif ($cr.Matched -eq 0) { $wiz.SetChip('corners', 'corners: none', 'warning') }
                else { $wiz.SetChip('corners', 'corners: check Creo', 'unverified') }
            } catch { $wiz.Log("  corner round error: $($_.Exception.Message)") }
        }

        # ---- STAGE 3: drill through holes ----
        $wiz.Log(("Drilling {0} through-hole(s) at diameter {1}..." -f @($c.PointIDs).Count, $c.HoleDiaFinal))
        $total = @($c.PointIDs).Count; $idx=0; $made=0; $noop=0; $failed=0; $aborted=$false
        foreach ($ptId in $c.PointIDs) {
            $idx++
            $wiz.SetProgress([Math]::Floor(($idx/$total)*100), ("hole $idx / $total"))
            $surfId = 0
            if ($c.GridPointIDs.Count -gt 0 -and $null -ne $c.SidePlane -and $null -ne $c.SidePlane.FeatId) { $surfId = [int]$c.SidePlane.FeatId }
            $macro = Build-HoleMacro -PointId $ptId -Diameter $c.HoleDiaFinal -BodyIndex $c.BodyIndex -SurfacePlaneId $surfId
            $changed = $false
            try { $stamp = $model.VersionStamp; $session.RunMacro($macro); $changed = Wait-ModelModified -Model $model -PreviousStamp $stamp -OnPoll { try { [System.Windows.Forms.Application]::DoEvents() } catch {} } } catch { $failed++ }
            if ($changed) { $made++ } else { $noop++ }
            if ($idx -eq 1 -and -not $changed) {
                $wiz.Log('ABORT: the first hole did not modify the model (canary). Check Creo.')
                $aborted = $true; break
            }
        }
        $c.Drilled = ($made -gt 0)
        if ($aborted) { $wiz.SetChip('drill', 'drill: aborted', 'aborted') }
        elseif ($made -eq $total -and $failed -eq 0) { $wiz.SetChip('drill', ("drill: {0} holes" -f $made), 'built') }
        else { $wiz.SetChip('drill', ("drill: {0}/{1}" -f $made, $total), 'unverified') }
        $wiz.Log(("Through-holes: {0} of {1} changed the model." -f $made, $total))

        # ---- STAGE 4: chip-relief holes ----
        if (-not $aborted -and $made -gt 0) {
            $relAuto = ($c.Is3dPrint -or $c.GridPointIDs.Count -gt 0)
            $doRelief = $relAuto
            if (-not $relAuto) {
                $ans = Show-WizardMessage -Text 'Add chip-relief holes on these points?' -Title 'Chip relief' -Buttons 'YesNo' -Icon 'Question'
                $doRelief = ($ans -eq [System.Windows.Forms.DialogResult]::Yes)
            }
            if ($doRelief) {
                # relief depth from live SIDE offset
                $reliefSide = @($c.Made | Where-Object { $_.Label -eq 'Side' }); $reliefSide = if ($reliefSide.Count -gt 0) { $reliefSide[0] } else { $null }
                $thickness = $null
                if ($null -ne $reliefSide -and $null -ne $reliefSide.Sym) { $live = Read-DimValue -Model $model -TypeObj $pfcType -Sym $reliefSide.Sym; if ($null -ne $live -and $live -gt 0) { $thickness = [double]$live } }
                if ($null -eq $thickness -or $thickness -le 0) {
                    $wiz.Log('No live SIDE offset - skipping chip relief (no thickness to size depth from).')
                    $wiz.SetChip('relief', 'relief: skipped', 'warning')
                } else {
                    $reliefDepth = [Math]::Round($thickness * $RELIEF_DEPTH_PCT, 4)
                    $reliefDia = [Math]::Round($c.HoleDiaFinal * $RELIEF_DIA_MULT, 4)
                    $wiz.Log(("Chip-relief: {0} hole(s), dia {1}, blind depth {2}..." -f @($c.PointIDs).Count, $reliefDia, $reliefDepth))
                    $rt=@($c.PointIDs).Count; $ri=0; $rm=0; $rab=$false; $rdh=0; $rdm=0
                    foreach ($ptId in $c.PointIDs) {
                        $ri++
                        $wiz.SetProgress([Math]::Floor(($ri/$rt)*100), ("relief $ri / $rt"))
                        $beforeMap = Get-LinearDimMap -Model $model -TypeObj $pfcType
                        $rSurf = 0; if ($c.GridPointIDs.Count -gt 0 -and $null -ne $c.SidePlane -and $null -ne $c.SidePlane.FeatId) { $rSurf = [int]$c.SidePlane.FeatId }
                        $macro = Build-ReliefHoleMacro -PointId $ptId -Diameter $reliefDia -BodyIndex $c.BodyIndex -SurfacePlaneId $rSurf
                        $changed = $false
                        try { $stamp = $model.VersionStamp; $session.RunMacro($macro); $changed = Wait-ModelModified -Model $model -PreviousStamp $stamp -OnPoll { try { [System.Windows.Forms.Application]::DoEvents() } catch {} } } catch {}
                        if ($changed) { $rm++; $dr = Set-ReliefHoleDepth -BeforeMap $beforeMap -Depth $reliefDepth; if ($dr.Status -eq 'held') { $rdh++ } else { $rdm++ } }
                        if ($ri -eq 1 -and -not $changed) { $wiz.Log('ABORT: first relief hole did not modify the model.'); $rab=$true; break }
                    }
                    if ($rab) { $wiz.SetChip('relief', 'relief: aborted', 'aborted') }
                    elseif ($rm -eq $rt -and $rdm -eq 0) { $wiz.SetChip('relief', ("relief: {0} @depth" -f $rm), 'built') }
                    else { $wiz.SetChip('relief', ("relief: {0}/{1}" -f $rm, $rt), 'unverified') }
                    $wiz.Log(("Chip-relief: {0} of {1} changed; {2} at correct depth." -f $rm, $rt, $rdh))
                }
            } else { $wiz.SetChip('relief', 'relief: skipped', 'set') }
        }
        return $true
    }
[void]$steps.Add($drillStep)

# ---- STAGE: Relief Paths -- chip-relief holes along a boundary edge ----------
# STAGE 6 from drilljig.cmd: the user picks a boundary OFFSET plane (TOP or FRONT
# offset only), a row of intersection points is created where that plane crosses the
# pitch planes, and a through-hole is drilled at each. Gated on $c.GridPlaneIds
# (STAGE 2.5 must have created offset planes). Uses the same shared primitives
# (Build-IntersectPointMacro, Build-HoleMacro, Resolve-NewPointIds, Get-PointIdSet).
$reliefPathStep = New-WizardStep -Key 'relief-paths' -Title 'Chip-relief paths (optional)' -Stage 'Relief' -Kind 'pick' -PrimaryText 'Skip' `
    -Validate { param($c) return $true } `
    -Build {
        param($panel, $c, $wiz)
        if (@($c.GridPlaneIds).Count -eq 0) {
            Add-Para $panel "No grid offset planes available (STAGE 2.5 was skipped or used predefined points). Chip-relief paths require an orthogrid/custom layout. Press Skip to continue." 8 60 'gray'
            return
        }
        Add-ArmBanner $panel ("In Creo, click the BOUNDARY OFFSET plane the relief holes drill INTO." + [Environment]::NewLine +
                              "Only the TOP OFFSET or FRONT OFFSET plane (the far box faces created earlier)." + [Environment]::NewLine +
                              "A row of holes is drilled into this face, normal to it, at the grid pitch.") 8
        Add-VerifyControls -Panel $panel -Context $c -Wizard $wiz -Top 140 -OnVerify {
            param($cc, $w)
            $boundaryId = Read-SelectedId
            if ($null -eq $boundaryId) { return @{ Ok=$false; Message='Nothing selected. Click the FRONT or TOP offset plane in Creo, then verify.' } }
            # match to a box OFFSET plane (FeatId only — not BaseId)
            $topP = @($cc.Planes | Where-Object { $_.Label -eq 'Top' } | Select-Object -First 1); $topP = if ($topP.Count -gt 0) { $topP[0] } else { $null }
            $frontP = @($cc.Planes | Where-Object { $_.Label -eq 'Front' } | Select-Object -First 1); $frontP = if ($frontP.Count -gt 0) { $frontP[0] } else { $null }
            $crossAxis = $null; $bLabel = $null
            if ($null -ne $topP -and $null -ne $topP.FeatId -and $boundaryId -eq [int]$topP.FeatId) { $bLabel='Top'; $crossAxis='Z' }
            elseif ($null -ne $frontP -and $null -ne $frontP.FeatId -and $boundaryId -eq [int]$frontP.FeatId) { $bLabel='Front'; $crossAxis='X' }
            if ($null -eq $crossAxis) { return @{ Ok=$false; Message='That is not the FRONT OFFSET or TOP OFFSET plane. Only those two are accepted.' } }
            $cc.ReliefBoundaryId = [int]$boundaryId
            $cc.ReliefCrossAxis = $crossAxis
            $cc.ReliefBLabel = $bLabel
            $w.SetChip('paths', ("relief path: {0} boundary" -f $bLabel), 'set')
            $crossPlanes = @($cc.GridPlaneIds | Where-Object { $_.Axis -eq $crossAxis })
            return @{ Ok=$true; Message=("{0} boundary (id {1}) -> crossing {2} perpendicular {3}-pitch plane(s)." -f $bLabel, $boundaryId, $crossPlanes.Count, $crossAxis) }
        }
    } `
    -OnNext {
        param($c, $wiz)
        # if no grid planes → just advance (Skip)
        if (@($c.GridPlaneIds).Count -eq 0) { return $true }
        # if no boundary picked → just advance (user pressed Skip)
        if ($null -eq $c.ReliefBoundaryId) { return $true }
        $script:GuiWiz = $wiz
        $wiz.BeginRun('Creating chip-relief path holes...')
        $crossPlanes = @($c.GridPlaneIds | Where-Object { $_.Axis -eq $c.ReliefCrossAxis } | Sort-Object Offset)
        $sideFaceId = if ($null -ne $c.SidePlane -and $null -ne $c.SidePlane.FeatId) { [int]$c.SidePlane.FeatId } elseif ($null -ne $c.SidePlane -and $null -ne $c.SidePlane.BaseId) { [int]$c.SidePlane.BaseId } else { $null }
        if ($null -eq $sideFaceId -or $crossPlanes.Count -eq 0) {
            $wiz.Log('Missing SIDE face or pitch planes - cannot build the relief path.')
            $wiz.SetChip('paths', 'paths: skipped', 'warning')
            return $true
        }
        # create intersection points: SIDE face n boundary n each pitch plane
        $wiz.Log(("Creating {0} relief point(s) (3-plane intersection)..." -f $crossPlanes.Count))
        $beforeRel = Get-PointIdSet -Model $model -TypeObj $pfcType
        $rpIdx = 0
        foreach ($pl in $crossPlanes) {
            $rpIdx++
            $wiz.SetProgress([Math]::Floor(($rpIdx / $crossPlanes.Count) * 100), ("relief point $rpIdx / $($crossPlanes.Count)"))
            $macro = Build-IntersectPointMacro -PlaneIds @([int]$sideFaceId, [int]$c.ReliefBoundaryId, [int]$pl.FeatId)
            try { $session.RunMacro($macro) } catch { $wiz.Log("  point $rpIdx errored: $($_.Exception.Message)") }
        }
        try { $model.Regenerate($null) } catch {}
        $relPointIDs = @(Resolve-NewPointIds -Model $model -TypeObj $pfcType -Before $beforeRel)
        if ($relPointIDs.Count -eq 0) {
            $wiz.Log('ABORT: no relief datum points were created.')
            $wiz.SetChip('paths', 'paths: no points', 'aborted')
            return $true
        }
        $wiz.Log(("{0} relief point(s) created." -f $relPointIDs.Count))
        # hole diameter = half the part extrude (live SIDE offset)
        $pathSide = @($c.Made | Where-Object { $_.Label -eq 'Side' }); $pathSide = if ($pathSide.Count -gt 0) { $pathSide[0] } else { $null }
        $extrudeLen = $null
        if ($null -ne $pathSide -and $null -ne $pathSide.Sym) { $lv = Read-DimValue -Model $model -TypeObj $pfcType -Sym $pathSide.Sym; if ($null -ne $lv -and $lv -gt 0) { $extrudeLen = [double]$lv } }
        $pathDia = if ($null -ne $extrudeLen -and $extrudeLen -gt 0) { [Math]::Round($extrudeLen / 2.0, 4) } else { 0.25 }
        $wiz.Log(("Drilling {0} relief-path hole(s) at diameter {1}, normal to the {2} boundary..." -f $relPointIDs.Count, $pathDia, $c.ReliefBLabel))
        # drill: On-Point, surface = boundary face, FlipCount=2
        $holeSurfId = [int]$c.ReliefBoundaryId
        $pTotal = $relPointIDs.Count; $pIdx=0; $pMade=0; $pAbort=$false
        foreach ($ptId in $relPointIDs) {
            $pIdx++
            $wiz.SetProgress([Math]::Floor(($pIdx / $pTotal) * 100), ("path hole $pIdx / $pTotal"))
            $macro = Build-HoleMacro -PointId ([int]$ptId) -Diameter $pathDia -BodyIndex $c.BodyIndex -SurfacePlaneId $holeSurfId -FlipCount 2
            $changed = $false
            try { $stamp = $model.VersionStamp; $session.RunMacro($macro); $changed = Wait-ModelModified -Model $model -PreviousStamp $stamp -OnPoll { try { [System.Windows.Forms.Application]::DoEvents() } catch {} } } catch {}
            if ($changed) { $pMade++ }
            if ($pIdx -eq 1 -and -not $changed) { $wiz.Log('ABORT: first relief-path hole did not modify the model.'); $pAbort=$true; break }
        }
        if ($pAbort) { $wiz.SetChip('paths', 'paths: aborted', 'aborted') }
        elseif ($pMade -eq $pTotal) { $wiz.SetChip('paths', ("paths: {0} holes" -f $pMade), 'built') }
        else { $wiz.SetChip('paths', ("paths: {0}/{1}" -f $pMade, $pTotal), 'unverified') }
        $wiz.Log(("Relief paths: {0} of {1} changed the model." -f $pMade, $pTotal))
        return $true
    }
[void]$steps.Add($reliefPathStep)

# ---- STAGE: Done -- summary -------------------------------------------------
$doneStep = New-WizardStep -Key 'done' -Title 'Done' -Stage 'Done' -Kind 'info' -PrimaryText 'Finish' `
    -Validate { param($c) return $true } `
    -Build {
        param($panel, $c, $wiz)
        $msg = "Drill-jig run complete." + [Environment]::NewLine + [Environment]::NewLine
        if ($c.BoxBuilt) {
            $msg += if ($c.BuildConfirmed) { "  Box: built and independently confirmed (solid measured)." } else { "  Box: built (NOT independently confirmed - see eval packet)." }
            $msg += [Environment]::NewLine
        }
        if (@($c.PointIDs).Count -gt 0) { $msg += ("  Points: {0}" -f @($c.PointIDs).Count) + [Environment]::NewLine }
        if ($c.Drilled) { $msg += "  Holes: drilled (verify visually in Creo)." + [Environment]::NewLine }
        if ($script:macroFailures -gt 0) { $msg += [Environment]::NewLine + ("  NOTE: {0} mapkey failure(s) during the run - inspect Creo." -f $script:macroFailures) }
        $msg += [Environment]::NewLine + [Environment]::NewLine + "Verify all geometry in Creo. Press Finish to close (the Creo session stays open)."
        Add-Para $panel $msg 8 260 $null $false
        $wiz.SetChip('done', 'run complete', $(if ($script:macroFailures -eq 0) { 'built' } else { 'unverified' }))
    } `
    -OnNext { param($c,$wiz) return $true }
[void]$steps.Add($doneStep)

# ============================================================================
# RUN THE WIZARD
# ============================================================================
$stages = @('Bushing','Layout','Datums','Box','Drill','Relief','Done')
$subtitle = "Connected: $([System.IO.Path]::GetFileName($modelFile))"

try {
    $completed = Show-Wizard -Steps @($steps.ToArray()) -Stages $stages -Title 'Drill Jig Builder' -SubTitle $subtitle -Context $ctx
    if ($completed) {
        Write-Host "  Wizard completed." -ForegroundColor Green
    } else {
        Write-Host "  Wizard closed before completing." -ForegroundColor Yellow
    }
} finally {
    try {
        if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null }
        if ($null -ne $origDynamicPreview)  { $session.SetConfigOption("dynamic_preview",  $origDynamicPreview)  | Out-Null }
    } catch {}
    try { $connection.Disconnect($null) } catch {}
}

Write-Host ""
Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
