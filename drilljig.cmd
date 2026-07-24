<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

# ============================================================================
# drilljig.cmd - DRILL-JIG PROTOTYPE (jiginator + plane-probe + holeinator)
# ============================================================================
# One end-to-end run of the whole drill-jig flow, in a single console session
# and a SINGLE Creo connection:
#
#   STAGE 1   walk the decision tree (no Creo)        -> resolves the hole OD
#   (GUI)     POINT SOURCE -- right after the tree, the user picks how the target
#             hole points are sourced: (1) PREDEFINED (already in the CAD file),
#             (2) ORTHOGRID (regular Nx x Nz grid editor), or (3) CUSTOM (add each
#             point + type its X/Z offset). Modes 2/3 are pure WinForms, pre-filled
#             with the tree's hole Ã˜ + depth as read-only context, and capture the
#             spec into a shared $orthoGeo object (a .Mode tag distinguishes them);
#             no Creo yet.
#   STAGE 2   build a parametric box from offset planes (plane-probe v2). When a
#             layout was captured (mode 2/3), TOP offset = plate width and FRONT
#             offset = plate height come straight from the GUI (SIDE = bushing
#             length). Auto-mapped planes build the box with no prompts.
#   STAGE 2.5 (modes 2/3) create EVERY target datum point by the proven 3-plane
#             intersection recipe, with planes SHARED across points
#             (Get-SharedPlanePlan: 1 face + one plane per distinct X + one per
#             distinct Z). Works for both the regular grid and arbitrary custom
#             points. Falls back to manual point selection on any failure.
#   STAGE 3   drill an On-Point hole at every target point (created in 2.5, or
#             hand-selected in PREDEFINED mode), diameter from STAGE 1.
#   STAGE 4   (3DP: auto / metal: ask) cut chip-relief SLOTS -- one blind
#             rectangular remove-material slot per hole ROW (slotinator method:
#             seed-drawn once then patterned). Needs a GUI layout; skipped for
#             PREDEFINED points. REPLACES the old coaxial relief holes + relief
#             paths (both removed).
#
# This is a MERGE of three working tools (jiginator.cmd / plane-probe.cmd /
# holeinator.cmd). Those three are LEFT UNTOUCHED and still run standalone. The
# differences here vs. running them separately:
#   - the hole diameter is handed STAGE 1 -> STAGE 3 as an in-process variable,
#     NOT via last_jig_spec.json (the standalone tools still use that file);
#   - ONE Creo connection / config-suppress / finally wraps STAGES 2 + 3;
#   - the tree is walked ONCE (jiginator's "run again?" loop is dropped);
#   - only one press-any-key at the very end.
#
# DATUM POINTS: STAGE 2.5 GENERATES the target datum points from the GUI layout
# (orthogrid OR custom), laid out from the box's TOP/FRONT datums on the SIDE
# face. In PREDEFINED mode STAGE 2.5 is skipped and the prototype uses the
# original assumption -- the points ALREADY EXIST in the CAD file and STAGE 3
# hand-selects them. Open the jig PART (not the .asm) with its default datum
# planes (FRONT/RIGHT/TOP); pre-placed datum points are only needed in PREDEFINED
# mode.
#
# Provenance of the lifted logic (do not "improve" during the merge):
#   - jiginator helpers + tree walk (jiginator.cmd)
#   - plane-probe's v2 extrude-first / internal-sketch box build, the offset-
#     plane creation, and the resize loop
#   - holeinator's Build-HoleMacro (transcribed from a live recording) + canary
# ============================================================================

$Host.UI.RawUI.WindowTitle = "DRILLJIG"
$ErrorActionPreference = "Stop"


trap {
    Write-Host ""
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $inv = $_.InvocationInfo
    if ($null -ne $inv) {
        Write-Host ("  at line {0}: {1}" -f $inv.ScriptLineNumber, $inv.Line.Trim()) -ForegroundColor DarkYellow
    }
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

# ============================================================================
# STAGE 1 HELPERS - decision-tree walk (lifted from jiginator.cmd)
# ============================================================================

$dataDir = Join-Path $ScriptDir 'data'

# CUSTOM HOLE OD (user 2026-07-23): prompt for an ARBITRARY hole diameter (not limited to
# the catalog), print a BOLD warning that a real drill bushing / bushing sleeve must be
# verified (nothing in the catalog backs a typed OD), then run the standard length menu
# (recommended from the typed OD). Returns the synthesized pick (Resolve-CustomOdPick) or
# $null on cancel. Shared by BOTH the OD-first (metal) and ID-first (sleeve) menus, so the
# custom option is reachable from the hole-diameter level of either chain.
function Invoke-CustomOdPick {
    while ($true) {
        # --- enter the custom OD ---
        Write-Host ""
        Write-Host "  Custom hole OD (type any diameter -- NOT limited to the catalog):" -ForegroundColor Cyan
        $odVal = $null; $odLabel = $null
        while ($true) {
            $raw = Read-Host "  Enter hole diameter in inches (e.g. 0.6, 3/8, 1 3/8; Q to cancel)"
            if ($raw -match '^[Qq]$') { return $null }
            $res = Resolve-CustomOdInput -Text $raw
            if ($res.Ok) { $odVal = [double]$res.Value; $odLabel = ('{0:0.###}' -f $odVal); break }
            Write-Host "  $($res.Error)" -ForegroundColor Yellow
        }
        # --- bold warning: nothing in the catalog backs a typed OD ---
        Write-Host ""
        Write-Host ("  ** WARNING: custom hole OD {0}`" has NO catalog bushing behind it.  **" -f $odLabel) -ForegroundColor Yellow
        Write-Host   "  ** Verify a drill bushing / bushing sleeve at this OD actually       **" -ForegroundColor Yellow
        Write-Host   "  ** EXISTS before machining -- double-check against your supplier.     **" -ForegroundColor Yellow

        # --- standard length menu (recommended from the typed OD) ---
        $backToOd = $false
        while (-not $backToOd) {
            $lenOpt = Get-BushingLengthOptions -Id $odVal
            $opts   = @($lenOpt.Options)
            $preIdx = [int]$lenOpt.PreselectIndex
            Write-Host ""
            Write-Host ("  Select length (custom OD {0}`"):" -f $odLabel) -ForegroundColor Cyan
            for ($i = 0; $i -lt $opts.Count; $i++) {
                $o = $opts[$i]
                $tag = if ($i -eq $preIdx) { "   <- recommended" } elseif ($o.IsCustom) { "   (type any length)" } else { '' }
                $lbl = if ($o.IsCustom) { 'Custom' } else { ("{0}`" Lg" -f $o.Label) }
                Write-Host ("    {0,3}) {1,-10}{2}" -f ($i + 1), $lbl, $tag) -ForegroundColor White
            }
            $recNote = if ($preIdx -ge 0) { "ENTER = recommended ($($opts[$preIdx].Label)`"), " } else { '' }
            Write-Host ""
            $chosenLen = $null; $chosenLabel = $null
            while ($true) {
                $raw = Read-Host "  Pick length (1-$($opts.Count), ${recNote}B to change OD, or Q to skip)"
                if ($raw -match '^[Qq]$') { return $null }
                if ($raw -match '^[Bb]$') { $backToOd = $true; break }
                if ([string]::IsNullOrWhiteSpace($raw) -and $preIdx -ge 0) {
                    $chosenLen = [double]$opts[$preIdx].Value; $chosenLabel = $opts[$preIdx].Label; break
                }
                $n = 0
                if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $opts.Count) {
                    $o = $opts[$n - 1]
                    if ($o.IsCustom) {
                        $def = if ($preIdx -ge 0) { [double]$opts[$preIdx].Value } else { 0.5 }
                        while ($true) {
                            $ctxt = Read-Host "    Enter custom length in inches (e.g. 0.9, 3/8, 1 3/8; Q to cancel)"
                            if ($ctxt -match '^[Qq]$') { break }
                            $lres = Resolve-BushingLengthInput -Text $ctxt -Default $def
                            if ($lres.Ok) { $chosenLen = [double]$lres.Value; $chosenLabel = ('{0:0.###}' -f $chosenLen); break }
                            Write-Host "    $($lres.Error)" -ForegroundColor Yellow
                        }
                        if ($null -ne $chosenLen) { break }
                        continue
                    }
                    $chosenLen = [double]$o.Value; $chosenLabel = $o.Label; break
                }
                Write-Host "  Enter a number between 1 and $($opts.Count) (or ENTER / B / Q)." -ForegroundColor Yellow
            }
            if ($backToOd) { break }          # re-enter the OD
            if ($null -eq $chosenLen) { continue }
            Write-Host ("  Custom hole diameter = {0}`"; length = {1}`" (verify bushing exists)." -f $odLabel, $chosenLabel) -ForegroundColor Green
            return (Resolve-CustomOdPick -OD $odVal -Length $chosenLen -LenLabel $chosenLabel -OdLabel $odLabel)
        }
    }
}

# Load + filter the catalog and let the user pick one row.
# Returns the chosen row (PSCustomObject) or $null on quit / no matches.
function Invoke-BushingPick {
    param($Spec)

    if (-not (Test-Path $Spec.File)) {
        Write-Host "  Catalog file not found: $($Spec.File)" -ForegroundColor Red
        return $null
    }

    $rows = @(Import-Csv $Spec.File)

    foreach ($f in $Spec.Filters) {
        $col = $f.Column
        $vals = $f.Values
        $rows = @($rows | Where-Object {
            $cell = [double]$_.$col
            ($vals | Where-Object { [math]::Abs($cell - $_) -lt 1e-6 }).Count -gt 0
        })
    }

    if ($rows.Count -eq 0) {
        Write-Host "  No catalog rows match this selection." -ForegroundColor Yellow
        $crit = ($Spec.Filters | ForEach-Object { "$($_.Column) in {$($_.Values -join ', ')}" }) -join '; '
        Write-Host "  (file: $(Split-Path $Spec.File -Leaf); filter: $crit)" -ForegroundColor DarkGray
        return $null
    }

    # OD-FIRST metal path (user 2026-07-22): for METAL -> Hand Drill the tree gives a
    # removable-bushing spec filtered by OD (only 1/2" and 3/4" ODs). The technician does
    # not care about the bore ID -- the drilled jig hole IS the removable bushing's OD --
    # so DISPLAY THE OD, skip the ID question, then ask the standardized length only. The
    # length is recommended from the OD value (0.5 OD -> 1/2" Lg, 0.75 OD -> 3/4" Lg). The
    # 3D-print SLEEVE path AND METAL -> PFD (user 2026-07-23: leaf changed to "3/4 ID
    # sleeves") are ID-filtered specs that fall through to the ID-first flow below.
    if (Test-OdFirstSpec -Spec $Spec) {
        $odGroups = Get-OdGroups -Rows $rows
        while ($true) {
            # --- stage 1: distinct ODs (= the drilled hole), ascending; plus a trailing
            #     "Custom hole OD" entry so the operator can type any diameter. ---
            Write-Host ""
            Write-Host "  Select OD (removable bushing = the drilled hole diameter):" -ForegroundColor Cyan
            for ($i = 0; $i -lt $odGroups.Count; $i++) {
                $og = $odGroups[$i]
                Write-Host ("    {0,3}) OD {1,-7}   (-> hole {2:0.###}`")" -f ($i + 1), $og.ODLabel, $og.OD) -ForegroundColor White
            }
            $customIdx = $odGroups.Count + 1
            Write-Host ("    {0,3}) Custom hole OD... (type any diameter)" -f $customIdx) -ForegroundColor Yellow
            Write-Host ""

            $odPick = $null
            while ($true) {
                $raw = Read-Host "  Pick OD (1-$customIdx, or Q to skip)"
                if ($raw -match '^[Qq]$') { return $null }
                $n = 0
                if ([int]::TryParse($raw, [ref]$n) -and $n -eq $customIdx) {
                    $cpick = Invoke-CustomOdPick
                    if ($null -ne $cpick) { return $cpick }
                    break   # custom cancelled -> re-show the OD menu
                }
                if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $odGroups.Count) {
                    $odPick = $odGroups[$n - 1]; break
                }
                Write-Host "  Enter a number between 1 and $customIdx." -ForegroundColor Yellow
            }
            if ($null -eq $odPick) { continue }   # custom was cancelled; re-show the OD menu

            # --- stage 2: STANDARDIZED length menu {1/2, 3/4, 1} + Custom, OD-recommended ---
            $backToOd = $false
            while (-not $backToOd) {
                $lenOpt = Get-BushingLengthOptions -Id $odPick.OD   # recommend length from the OD value
                $opts   = @($lenOpt.Options)
                $preIdx = [int]$lenOpt.PreselectIndex
                Write-Host ""
                Write-Host ("  Select length (OD {0}):" -f $odPick.ODLabel) -ForegroundColor Cyan
                for ($i = 0; $i -lt $opts.Count; $i++) {
                    $o = $opts[$i]
                    $tag = if ($i -eq $preIdx) { "   <- recommended for OD $($odPick.ODLabel)" } elseif ($o.IsCustom) { "   (type any length)" } else { '' }
                    $lbl = if ($o.IsCustom) { 'Custom' } else { ("{0}`" Lg" -f $o.Label) }
                    Write-Host ("    {0,3}) {1,-10}{2}" -f ($i + 1), $lbl, $tag) -ForegroundColor White
                }
                $recNote = if ($preIdx -ge 0) { "ENTER = recommended ($($opts[$preIdx].Label)`"), " } else { '' }
                Write-Host ""

                $chosenLen = $null; $chosenLabel = $null
                while ($true) {
                    $raw = Read-Host "  Pick length (1-$($opts.Count), ${recNote}B to change OD, or Q to skip)"
                    if ($raw -match '^[Qq]$') { return $null }
                    if ($raw -match '^[Bb]$') { $backToOd = $true; break }
                    if ([string]::IsNullOrWhiteSpace($raw) -and $preIdx -ge 0) {
                        $chosenLen = [double]$opts[$preIdx].Value; $chosenLabel = $opts[$preIdx].Label; break
                    }
                    $n = 0
                    if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $opts.Count) {
                        $o = $opts[$n - 1]
                        if ($o.IsCustom) {
                            $def = if ($preIdx -ge 0) { [double]$opts[$preIdx].Value } else { 0.5 }
                            while ($true) {
                                $ctxt = Read-Host "    Enter custom length in inches (e.g. 0.9, 3/8, 1 3/8; Q to cancel)"
                                if ($ctxt -match '^[Qq]$') { break }
                                $res = Resolve-BushingLengthInput -Text $ctxt -Default $def
                                if ($res.Ok) { $chosenLen = [double]$res.Value; $chosenLabel = ('{0:0.###}' -f $chosenLen); break }
                                Write-Host "    $($res.Error)" -ForegroundColor Yellow
                            }
                            if ($null -ne $chosenLen) { break }
                            continue   # custom cancelled -> re-show the length menu
                        }
                        $chosenLen = [double]$o.Value; $chosenLabel = $o.Label; break
                    }
                    Write-Host "  Enter a number between 1 and $($opts.Count) (or ENTER / B / Q)." -ForegroundColor Yellow
                }
                if ($backToOd) { break }          # back to stage 1 (change OD)
                if ($null -eq $chosenLen) { continue }

                # OD is chosen (= the hole); no ID stage, no OD tie-break. Resolve + return.
                Write-Host ("  Hole diameter = {0:0.###}`" (OD {1}); length = {2}`" (ID unspecified)." -f $odPick.OD, $odPick.ODLabel, $chosenLabel) -ForegroundColor Green
                return (Resolve-OdBushingPick -OdGroup $odPick -Length $chosenLen -LenLabel $chosenLabel)
            }
        }
    }

    # ID-FIRST staged pick (user 2026-07-21): ID first, then a STANDARDIZED length menu
    # {1/2, 3/4, 1} + Custom with a length RECOMMENDED from the chosen ID (a 1/2" ID
    # sleeve is normally 1/2" long, a 3/4" ID 3/4" long -- technician rule of thumb).
    # Because the fixed menu is decoupled from the catalog's own length rows, OD is
    # re-keyed on ID ALONE (Get-IdOdOptions = the union of the ID's distinct ODs) and is
    # auto-resolved when unique, offered as a tie-breaker when not. Group-CatalogByID
    # still supplies the ID list; the shared helpers live in lib\drilljig_core.ps1.
    $byId = Group-CatalogByID -Rows $rows

    while ($true) {

        # --- stage 1: distinct IDs (bore size), ascending; plus a trailing "Custom hole
        #     OD" entry so the operator can type any diameter instead of a catalog bore. ---
        # The resolved-hole preview lives on the ID card now (OD no longer keys on length).
        Write-Host ""
        Write-Host "  Select ID (bore size):" -ForegroundColor Cyan
        for ($i = 0; $i -lt $byId.Count; $i++) {
            $g = $byId[$i]
            $ods = Get-IdOdOptions -IdGroup $g
            $hole = if (@($ods).Count -eq 1) { ("-> hole {0:0.###}`"" -f $ods[0].OD) } else { ("{0} OD options" -f @($ods).Count) }
            $bit = if ($g.Lengths[0].ODs[0].Rows[0].PSObject.Properties.Name -contains 'DrillBitSize' -and $g.Lengths[0].ODs[0].Rows[0].DrillBitSize) { "  ($($g.Lengths[0].ODs[0].Rows[0].DrillBitSize))" } else { '' }
            Write-Host ("    {0,3}) ID {1,-7}{2}   ({3})" -f ($i + 1), $g.IDLabel, $bit, $hole) -ForegroundColor White
        }
        $customIdx = $byId.Count + 1
        Write-Host ("    {0,3}) Custom hole OD... (type any diameter)" -f $customIdx) -ForegroundColor Yellow
        Write-Host ""

        $idPick = $null
        while ($true) {
            $raw = Read-Host "  Pick ID (1-$customIdx, or Q to skip)"
            if ($raw -match '^[Qq]$') { return $null }
            $n = 0
            if ([int]::TryParse($raw, [ref]$n) -and $n -eq $customIdx) {
                $cpick = Invoke-CustomOdPick
                if ($null -ne $cpick) { return $cpick }
                break   # custom cancelled -> re-show the ID menu
            }
            if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $byId.Count) {
                $idPick = $byId[$n - 1]; break
            }
            Write-Host "  Enter a number between 1 and $customIdx." -ForegroundColor Yellow
        }
        if ($null -eq $idPick) { continue }   # custom was cancelled; re-show the ID menu
        $odOptions = Get-IdOdOptions -IdGroup $idPick

        # --- stage 2: STANDARDIZED length menu {1/2, 3/4, 1} + Custom, ID-recommended ---
        $backToId = $false
        while (-not $backToId) {
            $lenOpt = Get-BushingLengthOptions -Id $idPick.ID
            $opts   = @($lenOpt.Options)
            $preIdx = [int]$lenOpt.PreselectIndex
            Write-Host ""
            Write-Host ("  Select length (ID {0}):" -f $idPick.IDLabel) -ForegroundColor Cyan
            for ($i = 0; $i -lt $opts.Count; $i++) {
                $o = $opts[$i]
                $tag = if ($i -eq $preIdx) { "   <- recommended for ID $($idPick.IDLabel)" } elseif ($o.IsCustom) { "   (type any length)" } else { '' }
                $lbl = if ($o.IsCustom) { 'Custom' } else { ("{0}`" Lg" -f $o.Label) }
                Write-Host ("    {0,3}) {1,-10}{2}" -f ($i + 1), $lbl, $tag) -ForegroundColor White
            }
            $recNote = if ($preIdx -ge 0) { "ENTER = recommended ($($opts[$preIdx].Label)`"), " } else { '' }
            Write-Host ""

            $chosenLen = $null; $chosenLabel = $null
            while ($true) {
                $raw = Read-Host "  Pick length (1-$($opts.Count), ${recNote}B to change ID, or Q to skip)"
                if ($raw -match '^[Qq]$') { return $null }
                if ($raw -match '^[Bb]$') { $backToId = $true; break }
                if ([string]::IsNullOrWhiteSpace($raw) -and $preIdx -ge 0) {
                    $chosenLen = [double]$opts[$preIdx].Value; $chosenLabel = $opts[$preIdx].Label; break
                }
                $n = 0
                if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $opts.Count) {
                    $o = $opts[$n - 1]
                    if ($o.IsCustom) {
                        # Custom: type any length (decimal, "3/8", or mixed "1 3/8"); reject <=0.
                        $def = if ($preIdx -ge 0) { [double]$opts[$preIdx].Value } else { 0.5 }
                        while ($true) {
                            $ctxt = Read-Host "    Enter custom length in inches (e.g. 0.9, 3/8, 1 3/8; Q to cancel)"
                            if ($ctxt -match '^[Qq]$') { break }
                            $res = Resolve-BushingLengthInput -Text $ctxt -Default $def
                            if ($res.Ok) { $chosenLen = [double]$res.Value; $chosenLabel = ('{0:0.###}' -f $chosenLen); break }
                            Write-Host "    $($res.Error)" -ForegroundColor Yellow
                        }
                        if ($null -ne $chosenLen) { break }
                        continue   # custom cancelled -> re-show the length menu
                    }
                    $chosenLen = [double]$o.Value; $chosenLabel = $o.Label; break
                }
                Write-Host "  Enter a number between 1 and $($opts.Count) (or ENTER / B / Q)." -ForegroundColor Yellow
            }
            if ($backToId) { break }          # back to stage 1
            if ($null -eq $chosenLen) { continue }

            # --- stage 3: OD - AUTO-RESOLVED when unique, tie-breaker only when not ---
            # OD is re-keyed on ID alone, so the tie-break no longer references length.
            if (@($odOptions).Count -eq 1) {
                $odPick = $odOptions[0]
                Write-Host ("  Hole diameter = {0:0.###}`" (the only OD for ID {1}); length = {2}`"." -f $odPick.OD, $idPick.IDLabel, $chosenLabel) -ForegroundColor Green
                return (Resolve-BushingPickRow -IdGroup $idPick -OdOption $odPick -Length $chosenLen -LenLabel $chosenLabel)
            }

            # ambiguous: this bore is available at more than one OD. OD IS the drilled
            # hole, so the operator MUST choose it - never silently picked.
            while ($true) {
                Write-Host ""
                Write-Host ("  ID {0} is available at more than one OD - OD IS the drilled hole, so pick it:" -f $idPick.IDLabel) -ForegroundColor Cyan
                for ($i = 0; $i -lt $odOptions.Count; $i++) {
                    $od = $odOptions[$i]
                    Write-Host ("    {0,3}) OD {1,-7} [hole = {2:0.###}]" -f ($i + 1), $od.ODLabel, $od.OD) -ForegroundColor White
                }
                Write-Host ""
                $raw = Read-Host "  Pick OD (1-$($odOptions.Count), B to change length, or Q to skip)"
                if ($raw -match '^[Qq]$') { return $null }
                if ($raw -match '^[Bb]$') { break }   # back to stage 2 (re-show length menu)
                $n = 0
                if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $odOptions.Count) {
                    return (Resolve-BushingPickRow -IdGroup $idPick -OdOption $odOptions[$n - 1] -Length $chosenLen -LenLabel $chosenLabel)
                }
                Write-Host "  Enter a number between 1 and $($odOptions.Count) (or B / Q)." -ForegroundColor Yellow
            }
        }
    }
}

function Read-Choice {
    param([array]$Options, [string]$Prompt = 'Select')
    while ($true) {
        for ($i = 0; $i -lt $Options.Count; $i++) {
            $label = if ($Options[$i].label) { $Options[$i].label } else { '(untitled)' }
            Write-Host ("  {0}) {1}" -f ($i + 1), $label) -ForegroundColor White
        }
        Write-Host ""
        $raw = Read-Host "$Prompt (1-$($Options.Count), or Q to quit)"
        if ($raw -match '^[Qq]$') { return $null }
        $n = 0
        if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) {
            return $Options[$n - 1]
        }
        Write-Host "  Please enter a number between 1 and $($Options.Count)." -ForegroundColor Yellow
        Write-Host ""
    }
}

# Walk a node. $Path accumulates the chosen labels; $Outcomes collects leaves.
# Returns $true to continue, $false if the user quit.
function Invoke-Walk {
    param($Node, [System.Collections.ArrayList]$Path, [System.Collections.ArrayList]$Outcomes)

    switch ($Node.kind) {

        'question' {
            $opts = @($Node.children)
            if ($opts.Count -eq 0) {
                Write-Host "  (question '$($Node.label)' has no options - nothing to ask)" -ForegroundColor Yellow
                return $true
            }
            Write-Host ""
            Write-Host ">> $($Node.label)" -ForegroundColor Cyan
            if ($Node.notes) { Write-Host "   ($($Node.notes))" -ForegroundColor DarkGray }
            $chosen = Read-Choice -Options $opts -Prompt 'Answer'
            if ($null -eq $chosen) { return $false }
            [void]$Path.Add($chosen.label)
            return (Invoke-Walk -Node $chosen -Path $Path -Outcomes $Outcomes)
        }

        'option' {
            # an answer label; descend through its children in order
            foreach ($child in @($Node.children)) {
                $cont = Invoke-Walk -Node $child -Path $Path -Outcomes $Outcomes
                if (-not $cont) { return $false }
            }
            return $true
        }

        'outcome' {
            $spec = Get-CatalogSpec -Label $Node.label
            if ($spec) {
                $pick = Invoke-BushingPick -Spec $spec
                if ($pick) {
                    $od = [double]$pick.OD
                    # Bushing length drives the SIDE plane offset (box length) in
                    # STAGE 2. Parse defensively - $null if the row has no usable
                    # Length so the caller can fall back to a manual entry.
                    $blen = $null
                    try { if ($null -ne $pick.Length) { $blen = [double]$pick.Length } } catch {}
                    [void]$Outcomes.Add(("Bushing: {0}  ->  hole diameter = {1}`" (OD), length = {2}`"" -f $pick.EasyName, $od, $blen))
                    # record the resolved hole spec for the in-process handoff to STAGE 3
                    [void]$script:Picks.Add([pscustomobject]@{
                        HoleDiameter  = $od
                        BushingLength = $blen
                        Bushing       = $pick.EasyName
                        PartNumber    = $pick.PartNumber
                        Outcome       = $Node.label
                    })
                } else {
                    [void]$Outcomes.Add("(no bushing selected) $($Node.label)")
                }
            } else {
                # Not a catalog leaf. Some leaves declare the hole OD outright
                # (e.g. a "the OD of the hole will be 3/4 in" leaf). Resolve the
                # diameter straight from the label, with NO bushing pick. There is
                # no bushing => no length, so BushingLength stays $null and STAGE 2's
                # SIDE offset falls back to a manual entry (only the OD is fixed).
                $fixedOd = Get-FixedOdSpec -Label $Node.label
                if ($null -ne $fixedOd) {
                    [void]$Outcomes.Add(("Fixed hole diameter = {0}`" (OD) -- {1}" -f $fixedOd, $Node.label))
                    [void]$script:Picks.Add([pscustomobject]@{
                        HoleDiameter  = [double]$fixedOd
                        BushingLength = $null
                        Bushing       = "(fixed OD, no bushing)"
                        PartNumber    = "(n/a)"
                        Outcome       = $Node.label
                    })
                } else {
                    [void]$Outcomes.Add($Node.label)
                }
            }
            return $true
        }

        'bushing' {
            # placeholder until the catalog filter + pick is wired in
            [void]$Outcomes.Add("[BUSHING PICK] $($Node.label)")
            foreach ($child in @($Node.children)) {
                $cont = Invoke-Walk -Node $child -Path $Path -Outcomes $Outcomes
                if (-not $cont) { return $false }
            }
            return $true
        }

        'pattern' {
            [void]$Outcomes.Add("[PATTERN GROUPING] $($Node.label)")
            foreach ($child in @($Node.children)) {
                $cont = Invoke-Walk -Node $child -Path $Path -Outcomes $Outcomes
                if (-not $cont) { return $false }
            }
            return $true
        }

        default {
            Write-Host "  (unknown node kind '$($Node.kind)' - skipping)" -ForegroundColor Yellow
            return $true
        }
    }
}

# ============================================================================
# STAGE 2 HELPERS - parametric box (lifted from plane-probe.cmd)
# ============================================================================

# Fire a mapkey and report success/failure instead of swallowing it (boxinator's
# pattern). A silent no-op from a wrong widget name is the hardest mapkey bug to
# find, so count failures and surface them.
$script:macroFailures = 0

# The three offsets ARE the box dimensions: Side->Width, Top->Height,
# Front->Depth. With the part's three default datums forming the box's anchored
# corner, these three offset planes are the three opposite faces.
function Show-BoxState {
    param($Made)
    Write-Host "  Parametric box planes (offset = box extent):" -ForegroundColor Green
    for ($i = 0; $i -lt $Made.Count; $i++) {
        $p   = $Made[$i]
        $now = Read-DimValue -Model $model -TypeObj $pfcType -Sym $p.Sym
        $dim = switch ($p.Label) { "Side" { "Width" } "Top" { "Height" } "Front" { "Depth" } default { "" } }
        Write-Host ("    [{0}] {1,-5} ({2,-6}) {3,-6} = {4}" -f ($i + 1), $p.Label, $dim, $p.Sym, $now) -ForegroundColor White
    }
}

# ============================================================================
# STAGE 3 HELPERS - hole creation (lifted from holeinator.cmd)
# ============================================================================

$script:lastPct = -1
function Show-Progress {
    param([int]$Pct, [string]$Label)
    if ($Pct -eq $script:lastPct) { return }
    $script:lastPct = $Pct
    $filled = [Math]::Floor($Pct / 5)
    $empty = 20 - $filled
    $bar = ([char]9608).ToString() * $filled + ([char]9617).ToString() * $empty
    $color = if ($Pct -ge 100) { "Green" } else { "White" }
    $shortLabel = if ($Label.Length -gt 20) { $Label.Substring(0, 20) } else { $Label }
    Write-Host "`r  [$bar] $($Pct.ToString().PadLeft(3))%  $shortLabel   " -NoNewline -ForegroundColor $color
    if ($Pct -ge 100) { Write-Host "" }
}

# ============================================================================
# HEADER
# ============================================================================
Write-Host ""
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "   DRILLJIG  -  tree -> parametric box -> drill holes (one session)" -ForegroundColor Cyan
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "  (prototype: merges jiginator + plane-probe + holeinator; originals" -ForegroundColor DarkGray
Write-Host "   are untouched and still run standalone)" -ForegroundColor DarkGray
Write-Host ""

# ============================================================================
# SHARED LIBRARY (geometry reads)
# ============================================================================
. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')
# hands-free edge rounding (sweep GetItemById -> filter by EvalLength -> AddSelection
# -> round; NO find tool). Used right after the STAGE 2 box build to round corners.
. (Join-Path $ScriptDir 'lib\edge_round.ps1')
# STAGE 2.5 orthogrid: grid MATH (pure), the WinForms editor, and the datum-point
# grid creation/resolution. _gui needs _math (Get-OrthogridGeometry) in scope;
# _points' Build-PointGridMacro calls Get-SelectByIdMacro (defined below in this
# file) at fire time -- dot-sourcing shares one scope, so the order here is fine.
. (Join-Path $ScriptDir 'lib\orthogrid.ps1')
. (Join-Path $ScriptDir 'lib\orthogrid_gui.ps1')
. (Join-Path $ScriptDir 'lib\orthogrid_points.ps1')
# Import-fastener-layout mode (point source #4): PURE projection + the
# fastener_layout.json handoff. ConvertTo-LayoutXZ / Read-FastenerLayout /
# Test-FastenerLayoutSane. The RISKY center read lives in fastenator.cmd; here we
# only load a handoff file (or do a throwaway-connection live read in the mode arm).
. (Join-Path $ScriptDir 'lib\fastener_layout.ps1')
# The shared Creo engine: drilljig-gui.cmd + this console tool share ONE copy of
# the proven helpers (Build-HoleMacro, New-OffsetPlane, etc.) via this lib. A
# parity test in the suite fails if any helper drifts back into this file.
. (Join-Path $ScriptDir 'lib\drilljig_core.ps1')
# Initialize with DataDir now (for the tree/catalog walk in STAGE 1); session/model/
# type are not available until connect (~line 1204). Re-initialized after connect.
Initialize-DrilljigCore -Session $null -Model $null -TypeObj $null -DataDir $dataDir -Log $null

# ----------------------------------------------------------------------------
# Get-FastenerLayoutRawPoints -- READ fastener centers -> a {X;Z} list, from an
# existing fastener_layout.json OR a LIVE read of the open fastener part/assembly.
# Defined BEFORE STAGE 1 so the import can run at the very start of the flow (user
# 2026-07-20: read the fasteners FIRST, before material / DJ-type selection). The
# JIG hole dia is NOT known yet here, so this returns the RAW corner-relative
# points; the plate is re-anchored to the jig hole dia AFTER the tree (Set-LayoutMargin).
#
# LIVE read uses a THROWAWAY connection (never Initialize-DrilljigCore -- that would
# poison the shared $script:DJModel; the main connect binds the jig part fresh) and
# the ONE shared reader Read-FastenerCentersFromModel (assembly = selected components
# -> component-path transform origin; part = cylinder-axis sweep). NEVER reads
# IpfcPoint.Point. After a live read the operator switches Creo to the blank jig part.
# ----------------------------------------------------------------------------
function Get-FastenerLayoutRawPoints {
    $layoutFile = Join-Path $ScriptDir 'fastener_layout.json'
    $useFile = $false
    if (Test-Path $layoutFile) {
        $peek = Read-FastenerLayout -Path $layoutFile
        if ($peek.Valid) {
            Write-Host ("  Found fastener_layout.json: {0} hole(s) from '{1}' (axes {2}/{3}, {4})." -f `
                $peek.Count, $peek.SourceModel, $peek.AxisX, $peek.AxisZ, $peek.Units) -ForegroundColor Green
            $ans = Read-Host "  Use this saved layout? (Y = use file / n = read the open part live)"
            if ($ans.Trim().ToLower() -ne 'n') { $useFile = $true }
        }
    }

    if ($useFile) {
        $r = Read-FastenerLayout -Path $layoutFile
        if (-not $r.Valid) { Write-Host "  The saved layout could not be read." -ForegroundColor Yellow; return $null }
        if ($r.Units -ne 'unknown') { Write-Host ("  (Layout units: {0} -- ensure the jig part matches.)" -f $r.Units) -ForegroundColor DarkGray }
        return $r.Points
    }

    # ---- LIVE read of the currently-open fastener part (throwaway connection) ----
    Write-Host ""
    Write-Host "  LIVE read: make sure the FASTENER part/assembly (the one full of fasteners) is" -ForegroundColor Cyan
    Write-Host "  the ACTIVE model in Creo right now, then press ENTER (or Q to cancel)." -ForegroundColor Cyan
    $go = Read-Host "  ENTER to read / Q to cancel"
    if ($go.Trim().ToLower() -eq 'q') { return $null }

    $fConn = $null; $fPoints = $null
    try {
        $fAsync = New-Object -ComObject pfcls.pfcAsyncConnection
        $fConn  = $fAsync.Connect($null, $null, $null, $null)
        $fSess  = $fConn.Session
        $fModel = $fSess.GetActiveModel()
        if ($null -eq $fModel) { Write-Host "  No active model to read." -ForegroundColor Yellow; return $null }
        $fType  = New-Object -ComObject pfcls.pfcModelItemType
        $fName  = try { [string]$fModel.FileName } catch { "" }
        $fIsAsm = ($fName -match '(?i)\.asm(\.\d+)?$')

        # ASSEMBLY reads need the components SELECTED first (the buffer is the read
        # path); prompt, then hand off to the ONE shared reader used by fastenator.cmd.
        if ($fIsAsm) {
            Write-Host ("  ASSEMBLY: {0}. SELECT the fastener components in Creo (Ctrl-click them)." -f $fName) -ForegroundColor Cyan
            Write-Host "  Select ONE component per hole -- the BOLT SHANKS only, NOT their washers/nuts" -ForegroundColor Cyan
            Write-Host "  (a bolt+washer+nut stack reads as 2-3 holes at the same spot). Then press ENTER." -ForegroundColor Cyan
            Read-Host "  Press ENTER once the fasteners are selected" | Out-Null
        } else {
            Write-Host ("  Reading fastener bores from PART: {0}" -f $fName) -ForegroundColor DarkGray
        }
        $read = Read-FastenerCentersFromModel -Session $fSess -Model $fModel -TypeObj $fType -IsAsm $fIsAsm
        if (-not $read.Ok) {
            Write-Host ("  {0}" -f $read.Message) -ForegroundColor Yellow
            Write-Host "  Run fastener-probe.cmd to see which read works, or use fastenator.cmd + a file." -ForegroundColor Yellow
            return $null
        }
        $centers = $read.Centers
        $readMethodLbl = $read.ReadMethod
        Write-Host ("  Read {0} fastener {1}." -f $centers.Count, $(if ($fIsAsm) { 'component location(s)' } else { 'bore center(s)' })) -ForegroundColor Green
        # COUNT FEEDBACK: surface the selection accounting so a wrong count is visible.
        if ($fIsAsm) {
            Write-Host ("  Selection: {0} picked -> {1} location(s) read." -f $read.RawSelected, $centers.Count) -ForegroundColor DarkGray
            if ($read.SkippedNoPath   -gt 0) { Write-Host ("    - skipped {0} pick(s) with no component (surface/edge? select whole instances)." -f $read.SkippedNoPath) -ForegroundColor Yellow }
            if ($read.SkippedNoXform  -gt 0) { Write-Host ("    - skipped {0} component(s) whose location was unreadable." -f $read.SkippedNoXform) -ForegroundColor Yellow }
            if ($read.MergedDuplicate -gt 0) { Write-Host ("    - merged {0} duplicate pick(s) of the same component." -f $read.MergedDuplicate) -ForegroundColor DarkGray }
        }

        # axis mapping (user picks which model axes map to layout X / Z)
        function Read-Ax { param($P,$D) while ($true) { $a = Read-Host ("  $P (X/Y/Z, default $D)"); if ([string]::IsNullOrWhiteSpace($a)) { return $D }; $u=$a.Trim().ToUpper(); if (@('X','Y','Z') -contains $u) { return $u }; Write-Host "    Enter X, Y, or Z." -ForegroundColor Yellow } }
        Write-Host "  Choose which two MODEL axes form the flat jig layout (the third is through-thickness)." -ForegroundColor Cyan
        $axX = Read-Ax "Model axis for layout X" 'X'
        $axZ = Read-Ax "Model axis for layout Z" 'Z'
        # the jig hole dia is not known yet (tree not walked) -> use a nominal margin;
        # the plate is RE-ANCHORED to the real jig hole dia after the tree.
        $mg = 0.25
        # ASSEMBLY: NO proximity merge (user 2026-07-23: "the amount picked = the amount
        # of fasteners" -- one selected fastener is one hole). DedupTol=0 so distinct
        # fasteners can NEVER be collapsed; the reader already removed exact same-instance
        # re-picks by component path, and two genuinely-coincident holes surface via the
        # collision check, not a silent merge. (PART mode keeps $mg to merge a bolt's
        # several swept bore-cylinders.)
        $dt = if ($fIsAsm) { 0.0 } else { $mg }

        # -Axes = each fastener's own bore axis (parallel to $centers) => project onto
        # the fastener PANEL plane so true hole spacing survives a tilted panel (the fix
        # for "only some register" / "holes too close" on higher-level assemblies).
        $fastAxes = if ($null -ne $read) { $read.Axes } else { $null }
        # -AlignGrid: de-rotate so the hole grid runs perpendicular to the layout axes.
        $layout = ConvertTo-LayoutXZ -Centers $centers -Axes $fastAxes -AxisX $axX -AxisZ $axZ -Margin $mg -DedupTol $dt -AlignGrid
        if (-not $layout.Valid) {
            Write-Host "  Could not build a valid layout:" -ForegroundColor Red
            foreach ($e in $layout.Errors) { Write-Host ("    - $e") -ForegroundColor Red }
            Write-Host "  (Select at least 3 fasteners spanning the panel in 2 directions -- not all in one row/column; one flat panel at a time.)" -ForegroundColor Yellow
            return $null
        }
        if ($layout.Frame -eq 'plane') {
            Write-Host ("  Projected onto the fastener PANEL plane (axis spread {0:0.##} deg)." -f [double]$layout.AxisSpreadDeg) -ForegroundColor DarkGray
        } else {
            Write-Host "  NOTE: fastener axes not readable -- used global-axis projection (may distort a tilted panel)." -ForegroundColor Yellow
        }
        $sane = Test-FastenerLayoutSane -Layout $layout
        if (-not $sane.Ok) {
            Write-Host "  Sanity check failed (the read likely returned bad coords) -- not using this layout:" -ForegroundColor Red
            foreach ($e in $sane.Errors) { Write-Host ("    - $e") -ForegroundColor Red }
            return $null
        }
        # cache to the handoff file so a re-run can reuse it
        try { Write-FastenerLayout -Path $layoutFile -Layout $layout -SourceModel $fName -Units 'unknown' -ReadMethod $readMethodLbl -WhenIso ((Get-Date).ToString('o')) | Out-Null } catch {}
        Write-Host ("  Layout: {0} hole(s) (merged {1} duplicate(s)), axes {2}/{3}." -f $layout.Count, $layout.Dropped, $axX, $axZ) -ForegroundColor Green
        $fPoints = $layout.Points
    } catch {
        Write-Host ("  Live read failed: $($_.Exception.Message)") -ForegroundColor Yellow
        $fPoints = $null
    } finally {
        # ALWAYS drop the throwaway connection so the main connect binds the jig part.
        if ($null -ne $fConn) { try { $fConn.Disconnect($null) } catch {} }
    }

    if ($null -ne $fPoints) {
        Write-Host ""
        Write-Host "  ============================================================" -ForegroundColor Magenta
        Write-Host "  NOW SWITCH Creo's active window to the BLANK JIG PART (you can do this now or" -ForegroundColor Magenta
        Write-Host "  after the decision tree -- just make sure the jig part is active BEFORE the box" -ForegroundColor Magenta
        Write-Host "  build). The jig is built in a NEW part; the fastener part was only read." -ForegroundColor Magenta
        Write-Host "  ============================================================" -ForegroundColor Magenta
    }
    return $fPoints
}

# ============================================================================
# FASTENER LAYOUT IMPORT -- offered FIRST, before the decision tree (user 2026-07-20)
# ============================================================================
# Reading the fasteners up front means the operator captures the hole pattern from
# the source part/assembly before touching material / DJ-type questions. The RAW
# points are held here; the plate is sized + re-anchored to the JIG hole dia AFTER
# the tree resolves it. If imported, the post-tree point-source prompt is SKIPPED.
$fastenerRawPoints = $null
Write-Host "  Import a fastener layout from an open part/assembly to place the jig holes?" -ForegroundColor Cyan
Write-Host "    (Reads the fastener centers now; the jig is built at those positions later.)" -ForegroundColor DarkGray
$impAns = Read-Host "  Import fastener layout? (y/N)"
if ($impAns.Trim().ToLower() -eq 'y') {
    try { $fastenerRawPoints = Get-FastenerLayoutRawPoints } catch { $fastenerRawPoints = $null }
    if ($null -ne $fastenerRawPoints -and @($fastenerRawPoints).Count -gt 0) {
        Write-Host ("  Fastener layout captured ({0} hole(s)). It will be used automatically after the decision tree." -f @($fastenerRawPoints).Count) -ForegroundColor Green
    } else {
        Write-Host "  No fastener layout imported - you can still choose a point source after the tree." -ForegroundColor Yellow
        $fastenerRawPoints = $null
    }
}
Write-Host ""

# ============================================================================
# STAGE 1 -- DECISION TREE (no Creo). Walk ONCE -> the hole diameter.
# ============================================================================
$treePath = Join-Path $ScriptDir 'docs\drill_jig_decision_tree.json'
if (-not (Test-Path $treePath)) {
    throw "Decision tree not found at: $treePath  (build it in docs\drill_jig_tree_builder.html first)"
}
try {
    $tree = Get-Content $treePath -Raw | ConvertFrom-Json
} catch {
    throw "Could not parse the tree JSON: $($_.Exception.Message)"
}
# ConvertFrom-Json gives a single object if the root array has one element;
# normalize to an array either way.
$roots = @($tree)

Write-Host "  STAGE 1 - Drill-jig decision tree" -ForegroundColor Green
Write-Host "  Reading tree: $treePath" -ForegroundColor DarkGray

$path     = [System.Collections.ArrayList]::new()
$outcomes = [System.Collections.ArrayList]::new()
$script:Picks = [System.Collections.ArrayList]::new()

$quit = $false
foreach ($root in $roots) {
    $cont = Invoke-Walk -Node $root -Path $path -Outcomes $outcomes
    if (-not $cont) { $quit = $true; break }
}

if ($quit) {
    Write-Host ""
    Write-Host "  Cancelled in the decision tree - nothing built, no Creo connection made." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 0
}

Write-Host ""
Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
Write-Host "  Your selections:" -ForegroundColor Green
Write-Host ("    " + ($path -join "  >  ")) -ForegroundColor White
Write-Host ""
Write-Host "  Result:" -ForegroundColor Green
foreach ($o in $outcomes) { Write-Host "    $o" -ForegroundColor White }
Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
Write-Host ""

# In-process handoff: if several outcomes resolved a bushing, the LAST pick wins
# (matches jiginator's model). NO file is written here - these are carried into
# STAGES 2/3 as variables:
#   $holeDia    -> the STAGE 3 hole diameter (= bushing OD), used WITHOUT prompting
#   $bushingLen -> the STAGE 2 SIDE-plane offset (box length = bushing/sleeve length)
$holeDia    = $null
$bushingLen = $null
if ($script:Picks.Count -gt 0) {
    $active  = $script:Picks[$script:Picks.Count - 1]
    $holeDia = [double]$active.HoleDiameter
    if ($null -ne $active.BushingLength) { $bushingLen = [double]$active.BushingLength }
    Write-Host ("  Hole diameter from the tree: {0}`"  ({1})" -f $holeDia, $active.Bushing) -ForegroundColor Cyan
    if ($null -ne $bushingLen) {
        Write-Host ("  Bushing length from the tree: {0}`"  -> SIDE plane offset (box length)" -f $bushingLen) -ForegroundColor Cyan
    } else {
        Write-Host "  (the chosen bushing row had no usable Length - SIDE offset will be entered by hand)" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  The decision tree did not resolve a bushing / hole diameter." -ForegroundColor Yellow
    Write-Host "  You can still build the box now and enter the dimensions by hand." -ForegroundColor DarkGray
}
Write-Host ""

# Material drives STAGE 4's chip-relief-SLOT gate. A 3D-printed part ALWAYS gets the
# slots made automatically (no y/N) so the run doesn't pause for a confirmation we
# already know the answer to; metal (or any non-3D-print / unresolved path) keeps the
# human y/N gate. The material is the user's answer to the root question, which the
# walk recorded into $path -- the "3d print" signal only ever enters $path via that
# material option (the metal sub-answers are "PFD"/"Hand Drill"), so matching $path
# for it is unambiguous. Safe default: auto-act ONLY on the explicit 3D-print choice.
$is3dPrint = @($path | Where-Object { $_ -match '(?i)3d\s*print' }).Count -gt 0
if ($is3dPrint) {
    Write-Host "  Material: 3D print -> chip-relief slots will be added automatically (STAGE 4, no prompt)." -ForegroundColor Cyan
    Write-Host ""
}

# ============================================================================
# SLOT / GUIDE DEPTH -- tight/restricted-space question (right after the tree)
# ============================================================================
# The chip-relief slot depth ($SLOT_DEPTH_ABS) doubles as the plate EXTRUDE PAD:
# the plate is extruded to (bushing length + slot depth), then STAGE 4's slot
# removes the slot depth, so the FINAL functional guide depth == bushing length
# for ANY positive depth. A SMALLER slot depth therefore yields a THINNER overall
# plate -- exactly what a tight/restricted space needs. (User 2026-07-21: ask about
# tight spaces right after the bushing decision tree; if restricted, the operator
# enters their own slot depth and the overall extrude = bushing sleeve + entered
# depth; otherwise keep the default 0.25", extrude = bushing + 0.25".)
#   * --slot-depth N on the command line is an explicit override -> SKIP the prompt.
#   * Resolved HERE (not in the later depth-budget block) so it is set right after
#     the tree; STAGE 2 pads the plate and STAGE 4 cuts the slot with this value.
$SLOT_DEPTH_ABS = 0.25
$mSdp = [regex]::Match($ScriptArgs, '(?i)--slot-depth\s+([0-9]*\.?[0-9]+)')
$slotDepthFromFlag = $false
if ($mSdp.Success) { $pSdp = [double]$mSdp.Groups[1].Value; if ($pSdp -gt 0) { $SLOT_DEPTH_ABS = $pSdp; $slotDepthFromFlag = $true } }
if ($slotDepthFromFlag) {
    Write-Host ("  Slot depth = {0}`" (from --slot-depth); overall plate extrude = bushing length + {0}`"." -f $SLOT_DEPTH_ABS) -ForegroundColor DarkGray
} else {
    $ansTight = Read-Host "  Are you working in a TIGHT / restricted space (need a thinner plate / shallower relief slot)? (y/N)"
    if ($ansTight -match '^[Yy]') {
        # The operator enters their own (usually smaller) slot depth. Loop until a
        # positive number; blank keeps the 0.25" default. Validation is shared with
        # the GUI via Resolve-SlotDepthInput so both front-ends behave identically.
        while ($true) {
            $ansDepth = Read-Host ("  Enter the chip-relief slot depth in inches (ENTER = default {0}`")" -f $SLOT_DEPTH_ABS)
            $chk = Resolve-SlotDepthInput -Text $ansDepth -Default $SLOT_DEPTH_ABS
            if ($chk.Ok) { $SLOT_DEPTH_ABS = [double]$chk.Value; break }
            Write-Host ("    {0}  Enter a positive number (e.g. 0.125), or ENTER for the default." -f $chk.Error) -ForegroundColor Yellow
        }
        Write-Host ("  Tight space: slot depth = {0}`". Overall plate extrude = bushing length + {0}`" (thinner plate; guide depth still = bushing length after the cut)." -f $SLOT_DEPTH_ABS) -ForegroundColor Cyan
    } else {
        Write-Host ("  Standard clearance: slot depth = default {0}`". Overall plate extrude = bushing length + {0}`"." -f $SLOT_DEPTH_ABS) -ForegroundColor DarkGray
    }
}
Write-Host ""

# ============================================================================
# POINT SOURCE (GUI) -- right after the decision tree, BEFORE Creo.
# ============================================================================
# The user picks HOW the target hole points are sourced -- three modes:
#   1. PREDEFINED  -- the datum points already exist in the CAD file; STAGE 2.5 is
#                     skipped and STAGE 3 hand-selects them (the original flow).
#   2. ORTHOGRID   -- regular Nx x Nz grid laid out in Show-OrthogridDialog.
#   3. CUSTOM      -- arbitrary, per-point layout in Show-CustomPointsDialog: the
#                     operator adds each point and types its X/Z offset.
# Both create-modes are pure WinForms (no Creo), so they run here while the tree's
# numbers are fresh and BEFORE we connect. They only CAPTURE the spec into the
# shared $orthoGeo object (Get-Custom/OrthogridGeometry are shape-compatible, with
# a .Mode tag); the datum points are CREATED later in STAGE 2.5 once the box + its
# TOP/SIDE/FRONT datums exist. The decision-tree hole diameter ($holeDia) and bushing
# length / drill depth ($bushingLen) are passed in as read-only context. The hole dia
# ALSO sizes the plate (the dialog feeds it to the math layer as -ClearDia), so the
# box Width/Height clears the hole at the border. Cancelling a create dialog falls
# back to PREDEFINED (hand-selected).
$orthoGeo  = $null
$pointMode = 'predefined'

# Build a plate from a raw {X;Z} fastener point list at the (now-known) JIG hole dia:
# re-anchor the near corner so the nearest hole CENTER sits 1.5x the jig hole dia in
# from the corner (Set-LayoutMargin -- pure translation, pattern unchanged). 1.5x =
# the bore radius (0.5 dia) + one full-diameter wall, so the border hole-edge -> part-
# edge WALL is exactly one hole diameter (user 2026-07-21). Get-CustomPointsGeometry is
# then called with -EdgeMargin = the hole dia so the DERIVED far edge matches and the
# edge check enforces the same one-diameter wall. Returns the $orthoGeo (custom-shaped)
# or $null.
function Build-OrthoGeoFromRawPoints {
    param([array]$Points, [double]$HoleDia)
    if ($null -eq $Points -or @($Points).Count -lt 1) { return $null }
    $pts = $Points
    $clear = if ($HoleDia -gt 0) { [double]$HoleDia } else { 0.0 }
    # center inset = one radius (bore) + one diameter (wall) = 1.5 * dia, so the wall is
    # a full diameter on every side.
    $centerInset = $clear * 1.5
    if ($clear -gt 0) {
        try {
            $reanc = Set-LayoutMargin -Points $pts -Margin $centerInset
            if ($reanc.Valid) {
                $pts = $reanc.Points
                Write-Host ("  Plate re-anchored around the holes: {0}"" wall (one hole dia) to each edge (pattern unchanged)." -f $clear) -ForegroundColor DarkGray
            }
        } catch {}
    }
    $geo = $null
    try { $geo = Get-CustomPointsGeometry -Points $pts -ClearDia $clear -HoleDia $clear -EdgeMargin $clear } catch { $geo = $null }
    return $geo
}

# If a fastener layout was imported UP FRONT (before the tree), use it now that the
# jig hole dia ($holeDia) is known -- no point-source menu, per user 2026-07-20.
if ($null -ne $fastenerRawPoints -and @($fastenerRawPoints).Count -gt 0) {
    $orthoGeo = Build-OrthoGeoFromRawPoints -Points $fastenerRawPoints -HoleDia $(if ($null -ne $holeDia) { [double]$holeDia } else { 0.0 })
    if ($null -eq $orthoGeo -or -not $orthoGeo.Valid) {
        Write-Host "  Imported fastener layout did not produce a valid plate:" -ForegroundColor Yellow
        if ($null -ne $orthoGeo) { foreach ($e in $orthoGeo.Errors) { Write-Host ("    - $e") -ForegroundColor Yellow } }
        Write-Host "  Falling back to the point-source menu." -ForegroundColor Yellow
        $orthoGeo = $null
    } else {
        $pointMode = 'fastener'
        Write-Host ("  Fastener layout applied: {0} hole(s), part {1:0.00} x {2:0.00} ({3}). Points created in STAGE 2.5." -f `
            $orthoGeo.Count, $orthoGeo.Width, $orthoGeo.Height, $orthoGeo.WidthMode) -ForegroundColor Green
    }
}

if ($null -ne $orthoGeo) {
    # already have the layout from the up-front fastener import -> skip the menu.
} else {
Write-Host "  How should the target hole points be sourced?" -ForegroundColor Cyan
Write-Host "    1) I already have datum points in the part   (select them later)" -ForegroundColor White
Write-Host "    2) Create a regular orthogrid pattern         (Nx x Nz grid editor)" -ForegroundColor White
Write-Host "    3) Create custom points one at a time         (type each X/Z offset)" -ForegroundColor White
Write-Host "    4) Import fastener layout from an open part   (read fastener centers)" -ForegroundColor White
$modeRaw = Read-Host "  Choose 1 / 2 / 3 / 4 (default 1)"
switch ($modeRaw.Trim()) {
    '2'     { $pointMode = 'orthogrid' }
    '3'     { $pointMode = 'custom' }
    '4'     { $pointMode = 'fastener' }
    default { $pointMode = 'predefined' }
}

if ($pointMode -eq 'predefined') {
    Write-Host "  Using PRE-EXISTING datum points - STAGE 3 will hand-select them." -ForegroundColor DarkGray
} elseif ($pointMode -eq 'orthogrid') {
    try { $orthoGeo = Show-OrthogridDialog -HoleDiameter $holeDia -Thickness $bushingLen } catch { $orthoGeo = $null }
    if ($null -eq $orthoGeo) {
        Write-Host "  Orthogrid editor cancelled (or unavailable) - STAGE 3 will use hand-selected points." -ForegroundColor Yellow
        $pointMode = 'predefined'
    } else {
        Write-Host ("  Grid captured: {0} holes, part {1:0.00} x {2:0.00} (Nx={3}, Nz={4}, cc {5}x{6}, edge {7}, relief-clear {8}). Points created in STAGE 2.5." -f `
            $orthoGeo.Count, $orthoGeo.Width, $orthoGeo.Height, $orthoGeo.Nx, $orthoGeo.Nz, $orthoGeo.CcX, $orthoGeo.CcZ, $orthoGeo.Edge, $orthoGeo.ClearDia) -ForegroundColor Green
    }
} elseif ($pointMode -eq 'fastener') {
    # import a fastener layout NOW (chose option 4 without importing up front). Read the
    # raw {X;Z} points, then build the plate around them at the jig hole dia (shared
    # Build-OrthoGeoFromRawPoints -- re-anchor + Get-CustomPointsGeometry).
    $fPts = $null
    try { $fPts = Get-FastenerLayoutRawPoints } catch { $fPts = $null }
    if ($null -ne $fPts -and @($fPts).Count -gt 0) {
        $orthoGeo = Build-OrthoGeoFromRawPoints -Points $fPts -HoleDia $(if ($null -ne $holeDia) { [double]$holeDia } else { 0.0 })
    }
    if ($null -eq $orthoGeo -or -not $orthoGeo.Valid) {
        Write-Host "  No valid fastener layout imported - STAGE 3 will use hand-selected points." -ForegroundColor Yellow
        if ($null -ne $orthoGeo) { foreach ($e in $orthoGeo.Errors) { Write-Host ("    - $e") -ForegroundColor Yellow } }
        $orthoGeo = $null
        $pointMode = 'predefined'
    } else {
        Write-Host ("  Fastener layout captured: {0} hole(s), part {1:0.00} x {2:0.00} ({3}, relief-clear {4}). Points created in STAGE 2.5." -f `
            $orthoGeo.Count, $orthoGeo.Width, $orthoGeo.Height, $orthoGeo.WidthMode, $orthoGeo.ClearDia) -ForegroundColor Green
    }
} else {
    # custom -- arbitrary per-point layout
    try { $orthoGeo = Show-CustomPointsDialog -HoleDiameter $holeDia -Thickness $bushingLen } catch { $orthoGeo = $null }
    if ($null -eq $orthoGeo) {
        Write-Host "  Custom-points editor cancelled (or unavailable) - STAGE 3 will use hand-selected points." -ForegroundColor Yellow
        $pointMode = 'predefined'
    } else {
        Write-Host ("  Custom layout captured: {0} hole(s), part {1:0.00} x {2:0.00} ({3}, relief-clear {4}). Points created in STAGE 2.5." -f `
            $orthoGeo.Count, $orthoGeo.Width, $orthoGeo.Height, $orthoGeo.WidthMode, $orthoGeo.ClearDia) -ForegroundColor Green
        if ($orthoGeo.SkippedOrigin -gt 0) {
            Write-Host ("  ({0} point(s) at the origin were dropped - no hole will be drilled at the part corner.)" -f $orthoGeo.SkippedOrigin) -ForegroundColor DarkGray
        }
    }
}
}   # end: point-source menu (only shown when no up-front fastener layout)
Write-Host ""

# ============================================================================
# CHIP-RELIEF SLOT DIRECTION (X or Z) -- offered for an IMPORTED FASTENER layout
# ============================================================================
# STAGE 4 cuts one blind chip-relief slot per hole ROW. The removal-path DIRECTION
# decides how holes group into rows: 'X' (default) = slots run along X (rows grouped by
# Z); 'Z' = slots run along Z (rows grouped by X). Get-RowSlots -RowAxis already supports
# both, and STAGE 4's pattern-direction datum is picked from the DERIVED CrossAxis, so
# threading this one axis is enough -- the guide planes + pattern datum auto-adapt.
# Orthogrid/custom layouts keep the 'X' default (the operator laid those out with X as the
# natural row axis, so the direction is not re-asked); an IMPORTED FASTENER pattern comes
# from an arbitrary source part with no operator-chosen primary axis, so the operator is
# ASKED which way the slots should run (user 2026-07-23). --slot-dir X|Z pins it (skips
# the prompt) for any mode / for scripted runs. Resolved here (once $pointMode is final)
# and reused verbatim by STAGE 4 -- $slotRowAxis defaults to 'X' so every non-fastener
# path is byte-identical to before.
$slotRowAxis = 'X'
$mSlotDir = [regex]::Match($ScriptArgs, '(?i)--slot-dir\s+([XZxz])')
if ($mSlotDir.Success) {
    $slotRowAxis = Resolve-SlotRowAxis -Text $mSlotDir.Groups[1].Value
    Write-Host ("  Chip-relief slot direction = {0} (from --slot-dir): slots run along {0}." -f $slotRowAxis) -ForegroundColor DarkGray
} elseif ($pointMode -eq 'fastener' -and $null -ne $orthoGeo) {
    Write-Host "  The hole layout was imported from a fastener pattern. Chip-relief slots are cut" -ForegroundColor Cyan
    Write-Host "  one per hole ROW -- choose which direction they run:" -ForegroundColor Cyan
    Write-Host "    X = slots run along X (rows grouped by Z)   [default]" -ForegroundColor White
    Write-Host "    Z = slots run along Z (rows grouped by X)" -ForegroundColor White
    $sdRaw = Read-Host "  Slot direction - X (default) or Z (blank -> X)"
    $slotRowAxis = Resolve-SlotRowAxis -Text $sdRaw
    Write-Host ("  Chip-relief slot direction: {0}." -f $slotRowAxis) -ForegroundColor Green
    Write-Host ""
}

# ============================================================================
# INDEX-FIRST CHOICE (2026-07-15) -- pick the index hole UP FRONT (before Creo)
# ============================================================================
# The user wants the jig's features to reference the index hole without moving any
# geometry (moving the base csys after the fact cuts the jig). If the operator picks
# an index hole now, STAGE 1.9 creates the base csys AT that hole (not at the origin)
# and STAGE 2.5 offsets every grid plane RELATIVE to it: offset = gridCoord - indexCoord.
# A datum plane offset from the index csys's axis is measured FROM THE CSYS ORIGIN
# (confirmed live 2026-07-16: an ABSOLUTE-valued plane off the index csys OVERSHOT the
# hole by +index), so the relative offset places the hole at its correct absolute
# position while parented to the index hole. The index hole's own column/row is offset 0
# and REUSES the csys anchor plane -- no redundant plane -- so a row of N holes makes N-1
# new offset planes (e.g. cc 2 -> planes at +2,+4,+6). Blank/none = origin-based behavior.
# Only offered for a grid/custom layout (predefined has no $orthoGeo). See fact
# drilljig-index-first-grid.
$indexFirst = $false
$indexGridX = $null
$indexGridZ = $null
$indexKey   = $null
# INDEX-RELATIVE CUSTOM LAYOUT (user 2026-07-21): a custom layout entered index-first
# (the operator typed the INDEX hole as an offset from the corner, then every OTHER hole
# as an offset FROM the index) comes back tagged IndexRelative with IndexGridX/IndexGridZ
# = the index hole's corner offset (= its grid coord). The index hole IS Points[0], so we
# AUTO-engage index-first with IndexKey = 0 and SKIP the interactive index-hole menu (the
# operator already chose the index by typing it). STAGE 1.9 builds the base csys AT this
# hole and STAGE 2.5 offsets every grid plane by (grid - index) -- exactly as if the hole
# had been picked from the menu. Orthogrid never sets IndexRelative, so its menu is intact.
if ($null -ne $orthoGeo -and ($orthoGeo.PSObject.Properties.Name -contains 'IndexRelative') -and $orthoGeo.IndexRelative) {
    $indexFirst = $true
    $indexKey   = 0
    $indexGridX = [double]$orthoGeo.IndexGridX
    $indexGridZ = [double]$orthoGeo.IndexGridZ
    Write-Host ("  Index-relative custom layout: index hole @ grid ({0:0.###}, {1:0.###}) from the corner." -f $indexGridX, $indexGridZ) -ForegroundColor Green
    Write-Host "  The base csys is built AT the index hole; every other hole is offset from it (no menu)." -ForegroundColor Green
    Write-Host ""
}
# IMPORTED FASTENER LAYOUTS default to origin-based (NON-index) plane creation, which
# is the PROVEN path (absolute offsets off the CSYS_PAT_DEF copy, exactly like a working
# orthogrid/custom run). Index-first for an import builds the base csys by INTERSECTING 3
# planes, then offsets every grid plane from THAT csys's Axis_X/Y/Z -- an intersected csys
# does not reliably expose the standard axis names, so STAGE 2.5 plane creation bugs out
# (the reported symptom). Opt back in with --fastener-index once that path is verified live.
# An index-relative custom layout ALREADY set index-first above -> do not also show the menu.
$offerIndex = ($null -ne $orthoGeo) -and -not $indexFirst
if ($pointMode -eq 'fastener' -and -not ($ScriptArgs -match '(?i)--fastener-index')) {
    $offerIndex = $false
    Write-Host "  (Imported fastener layout: building at the fasteners' absolute positions." -ForegroundColor DarkGray
    Write-Host "   Index-hole referencing is off for imports by default; add --fastener-index to enable.)" -ForegroundColor DarkGray
    Write-Host ""
}
if ($offerIndex) {
    $ihPlan = Get-IndexHolePlan -Points $orthoGeo.Points
    $cands  = @($ihPlan.Candidates)
    if ($cands.Count -gt 0) {
        Write-Host "  ====================================================================" -ForegroundColor Cyan
        Write-Host "   INDEX HOLE (optional) - build the jig referenced FROM one hole" -ForegroundColor Cyan
        Write-Host "  ====================================================================" -ForegroundColor Cyan
        Write-Host "  Pick a hole to be the index (origin) the whole jig references. The part" -ForegroundColor White
        Write-Host "  dimensions + hole positions stay identical; the chosen hole just becomes" -ForegroundColor White
        Write-Host "  the coordinate-system origin (nothing moves, nothing is cut)." -ForegroundColor White
        Write-Host "    0 = none (default; origin-based, exactly like today)" -ForegroundColor DarkGray
        foreach ($c in $cands) { Write-Host ("    {0} = {1}" -f ($c.Key + 1), $c.Label) -ForegroundColor DarkGray }
        $ans = Read-Host "  Index hole # (ENTER / 0 for none)"
        $sel = 0
        if (-not [string]::IsNullOrWhiteSpace($ans) -and [int]::TryParse($ans.Trim(), [ref]$sel) -and $sel -ge 1 -and $sel -le $cands.Count) {
            $indexKey = $cands[$sel - 1].Key
            $ihChosen = Get-IndexHolePlan -Points $orthoGeo.Points -IndexKey $indexKey
            if ($ihChosen.HasIndex) {
                $indexFirst = $true
                $indexGridX = [double]$ihChosen.IndexGridX
                $indexGridZ = [double]$ihChosen.IndexGridZ
                Write-Host ("  Index hole = {0} (grid {1:0.###}, {2:0.###}). The base csys will be built AT this hole;" -f $cands[$sel-1].Label, $indexGridX, $indexGridZ) -ForegroundColor Green
                Write-Host "  every grid offset is taken relative to it (geometry unchanged, no base move)." -ForegroundColor Green
            }
        }
        if (-not $indexFirst) { Write-Host "  No index hole chosen - origin-based build (today's behavior)." -ForegroundColor DarkGray }
        Write-Host ""
    }
}
# INDEX-FIRST axis-flip flags: the index-hole base csys is built from 3 intersecting planes,
# and this build reads plane normals as null, so its Axis_X/Axis_Z DIRECTIONS cannot be
# verified programmatically -- if the holes come out mirrored on an axis, flip that axis's
# grid offset sign with --index-flip-x / --index-flip-z (no code change / re-run needed).
$indexFlipX = if ($ScriptArgs -match '(?i)--index-flip-x') { -1.0 } else { 1.0 }
$indexFlipZ = if ($ScriptArgs -match '(?i)--index-flip-z') { -1.0 } else { 1.0 }

# ============================================================================
# CHIP-RELIEF DEPTH BUDGET (decided UP FRONT so STAGE 2 can pad the plate)
# ============================================================================
# The bushing sleeve length ($bushingLen) is the FINAL functional guide depth the jig
# must have AFTER the relief slot is cut. The relief slot removes SLOT_DEPTH_ABS (an
# ABSOLUTE depth, inches) from the near face. So if we extruded the plate to exactly
# $bushingLen and then cut the slot, the remaining full-thickness guide would be only
# bushingLen - SLOT_DEPTH_ABS -- too shallow. To land the guide at EXACTLY $bushingLen we
# PAD the extrude by the relief depth: plate = bushingLen + SLOT_DEPTH_ABS, slot removes
# SLOT_DEPTH_ABS, leaving bushingLen. (User 2026-07-21: "set slot depth to 0.25 inches.
# this would mean the original extrude is 0.25 + bushing sleeve length" -- an ABSOLUTE
# pad, not the former percentage-of-length model.)
#   * $SLOT_DEPTH_ABS was already resolved RIGHT AFTER THE TREE (the tight/restricted-
#     space prompt / --slot-depth flag). STAGE 4 reuses it, no re-parse; here we only
#     read it to pad the plate. Only the slot DIRECTION flags are parsed in this block.
#   * $willSlotRelief decides whether relief will actually be cut -- ONLY then do we pad
#     (a metal part where the operator declines relief must keep plate == bushingLen).
#     3D-print -> auto yes; metal -> ask now (STAGE 4 no longer re-asks); --no-slot-relief
#     or a predefined-point run (no $orthoGeo -> no rows) -> no relief, no pad.
#   * $reliefPad = SLOT_DEPTH_ABS (inches) when relief will be cut, else 0. STAGE 2 SIDE
#     offset = bushingLen + reliefPad; STAGE 4 slot depth = SLOT_DEPTH_ABS (absolute, the
#     same value removed -- so plate - slot = bushingLen exactly).
$slotFlip        = ($ScriptArgs -match '(?i)--slot-flip')
$slotPatternFlip = ($ScriptArgs -match '(?i)--pattern-flip')
$slotNoPattern   = ($ScriptArgs -match '(?i)--no-pattern')

$willSlotRelief = $false
if ($ScriptArgs -match '(?i)--no-slot-relief') {
    Write-Host "  (--no-slot-relief) no chip-relief slots -- the plate is NOT padded (thickness = bushing length)." -ForegroundColor DarkGray
} elseif ($null -eq $orthoGeo) {
    Write-Host "  Predefined points (no grid/custom layout) -- no chip-relief slots, so the plate is NOT padded." -ForegroundColor DarkGray
} elseif ($is3dPrint) {
    Write-Host "  Material is 3D print -- chip-relief slots WILL be added; padding the plate by the relief depth." -ForegroundColor Cyan
    $willSlotRelief = $true
} else {
    $ansPad = Read-Host ("  Add chip-relief slots? The plate will be padded by {0}"" so the final guide depth = the bushing length. (y/N)" -f $SLOT_DEPTH_ABS)
    $willSlotRelief = ($ansPad -match '^[Yy]$')
    if (-not $willSlotRelief) { Write-Host "  No chip-relief slots -- the plate is NOT padded (thickness = bushing length)." -ForegroundColor DarkGray }
}
# The absolute depth (inches) added to the extrude so that guide-after-slot == bushingLen. 0 when no relief.
$reliefPad = if ($willSlotRelief) { [double]$SLOT_DEPTH_ABS } else { 0.0 }
if ($willSlotRelief -and $null -ne $bushingLen) {
    Write-Host ("  Depth budget: bushing length {0}"" + {1}"" relief pad = extrude {2}""; slot removes {1}""; final guide {0}""." -f `
        [Math]::Round([double]$bushingLen,4), $SLOT_DEPTH_ABS, [Math]::Round([double]$bushingLen+$reliefPad,4)) -ForegroundColor Green
}
Write-Host ""

# ============================================================================
# CONNECT ONCE (single session) -- wraps STAGES 2 + 3
# ============================================================================

$procs = @(Get-Process -Name xtop -ErrorAction SilentlyContinue)
if ($procs.Count -eq 0) { throw "Creo (xtop.exe) is not running" }
if ($procs.Count -gt 1) {
    throw "More than one Creo session is open. This prototype expects exactly ONE (no session picker here)."
}
$proc = $procs[0]
$Env:PRO_DIRECTORY    = $proc.Path.TrimEnd("xtop.exe")
$Env:PRO_COMM_MSG_EXE = $proc.Path -replace "xtop.exe", "pro_comm_msg.exe"

try { New-Object -ComObject pfcls.pfcAsyncConnection | Out-Null }
catch {
    $reg = $proc.Path -replace "Common Files(.*)$", "Parametric\bin\vb_api_register.bat"
    Start-Process -Wait -FilePath $reg
}

# Connect to Creo's async COM server WITH RETRY. RPC_E_SERVERFAULT (0x80010105 "the server
# threw an exception") and similar faults HERE are almost always a TRANSIENT Creo state --
# the session is mid-regen, a modal dialog is still open, or the COM server is momentarily
# busy -- not a script bug. Retry a few times with a short pause, using a FRESH connection
# object each attempt (a faulted async object can stay poisoned), then give actionable
# recovery guidance if it still will not connect.
$async      = New-Object -ComObject pfcls.pfcAsyncConnection
$connection = $null
$connErr    = $null
for ($cattempt = 1; $cattempt -le 5; $cattempt++) {
    try { $connection = $async.Connect($null, $null, $null, $null); break }
    catch {
        $connErr = $_
        if ($cattempt -lt 5) {
            Write-Host ("  Creo refused the connection (attempt $cattempt/5): $($_.Exception.Message)") -ForegroundColor Yellow
            Write-Host "  Retrying in 2s -- click into Creo and make sure it is IDLE (no open dialog, not mid-regen)..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 2
            try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($async) | Out-Null } catch {}
            $async = New-Object -ComObject pfcls.pfcAsyncConnection
        }
    }
}
if ($null -eq $connection) {
    throw ("Could not connect to Creo after 5 attempts ($($connErr.Exception.Message)). This is a Creo-SIDE " +
           "connection fault (the Creo COM server threw), NOT a script error. Recover by: (1) click into the Creo " +
           "window and DISMISS any open dialog / finish or cancel any in-progress feature; (2) make sure a PART is " +
           "open and Creo is fully loaded and idle; (3) if it still fails, SAVE and RESTART Creo, then re-run.")
}
$session    = $connection.Session
$model      = $session.GetActiveModel()
if ($null -eq $model) { throw "No active model. Open the jig PART (default datum planes + the target datum points) first." }

Write-Host "  Connected. Active model: $($model.FileName)" -ForegroundColor Green

# Mode guard: this tool drills a PART. In assembly mode the datum points and
# by-ID selection resolve against the .asm, not the part to drill. Key off the
# filename extension (EpfcModelType enum ints are unconfirmed on this build).
$modelFile = ""
try { $modelFile = [string]$model.FileName } catch {}
if ($modelFile -match '\.asm(\.\d+)?$') {
    Write-Host ""
    Write-Host "  STOP: the active model is an ASSEMBLY ($modelFile)." -ForegroundColor Yellow
    Write-Host "  This prototype builds + drills a single PART. Open the jig PART" -ForegroundColor Yellow
    Write-Host "  itself (activate it in its own window), then re-run." -ForegroundColor Yellow
    Write-Host ""
    $connection.Disconnect($null)
    exit 1
}
Write-Host ""

# Suppress UI noise during the run, restore in finally (toolkit convention).
$origVisibleMapkeys = $null
$origDynamicPreview = $null
try {
    $vals = $session.GetConfigOptionValues("visible_mapkeys")
    if ($null -ne $vals -and $vals.Count -gt 0) { $origVisibleMapkeys = $vals.Item(0) }
} catch {}
try {
    $vals = $session.GetConfigOptionValues("dynamic_preview")
    if ($null -ne $vals -and $vals.Count -gt 0) { $origDynamicPreview = $vals.Item(0) }
} catch {}
try {
    $session.SetConfigOption("visible_mapkeys", "no") | Out-Null
    $session.SetConfigOption("dynamic_preview", "no") | Out-Null
} catch {}

# $pfcType defined ONCE here, shared by STAGES 2 + 3.
$pfcType = New-Object -ComObject pfcls.pfcModelItemType
# Re-initialize the shared engine now that session/model/type are available (the
# first Initialize before STAGE 1 only set DataDir for the catalog walk).
Initialize-DrilljigCore -Session $session -Model $model -TypeObj $pfcType -DataDir $dataDir -Log $null

try {

# ============================================================================
# STAGE 1.9 -- BASE COORDINATE SYSTEM (2026-07-14: everything hangs off a csys)
# ============================================================================
# Create a reference coordinate system from the part's DEFAULT csys, fully
# automatically: Find-DefaultCsysId locates it (CSYS_PAT_DEF / PRT_CSYS_DEF / the
# first csys in the model), then Invoke-BaseCsys selects it and fires
# ProCmdDatumCsys -> OK (no user pick). Every box + grid plane is then created as an
# OFFSET FROM THIS csys + an axis (not from the TOP/SIDE/FRONT default datums), so
# re-placing this csys (STAGE 5.5 transform-reimport, onto the index hole) moves the
# whole jig with it. --no-base-csys reverts to the legacy default-datum planes. If no
# coordinate system can be found/made, we fall back to the legacy path so the tool runs.
$baseCsysId = $null
# Index-hole ANCHOR planes: Invoke-OutputCsys builds the base csys from 3 planes off
# CSYS_PAT_DEF at the index hole's ABSOLUTE grid coords -- [X@indexX, Y@0, Z@indexZ].
# The X-anchor sits at model-X = indexX and the Z-anchor at model-Z = indexZ, so they
# ARE the index hole's own row/column planes. STAGE 2.5 REUSES them for the grid
# coordinate that coincides with the index hole (effective offset 0) instead of making
# a redundant coincident plane -> a row of N makes N-1 NEW planes, not N.
$indexAnchorX = $null
$indexAnchorZ = $null
if ($ScriptArgs -match '(?i)--no-base-csys') {
    Write-Host "  (--no-base-csys) using the legacy default-datum planes." -ForegroundColor DarkGray
} else {
    Write-Host "  ====================================================================" -ForegroundColor Cyan
    Write-Host "   STAGE 1.9 - base coordinate system (planes will reference it)" -ForegroundColor Cyan
    Write-Host "  ====================================================================" -ForegroundColor Cyan
    # INDEX-FIRST (user's construction): build the base csys AT the index hole so it IS the
    # index coordinate system, created BEFORE the holes are drilled. Then STAGE 2.5 offsets
    # every grid plane RELATIVE to it: Axis_X @ (gridX-indexGridX). A datum plane offset from
    # a coordinate system's axis is measured FROM THAT CSYS ORIGIN (confirmed live 2026-07-16:
    # an absolute-valued plane off the index csys OVERSHOT by +index), so the index hole's own
    # column/row is offset 0 (reuses the anchor plane -- see $indexAnchorX/Z) and every other
    # hole is the cc DIFFERENCE (e.g. a row of 4 at cc 2 -> planes at +2,+4,+6 = 3 new planes).
    #   NON-INDEX: base csys = a plain COPY of CSYS_PAT_DEF (origin + axes), grid planes absolute.
    # ORIENTATION CAVEAT: the index-hole base csys is built from 3 intersecting planes and this
    # build reads plane normals as null, so its Axis_X/Axis_Z DIRECTIONS aren't programmatically
    # verifiable. If the live holes come out mirrored on an axis, re-run with --index-flip-x /
    # --index-flip-z (applied via $indexFlipX/$indexFlipZ in STAGE 2.5) -- no code change needed.
    $refCsysId = Find-DefaultCsysId
    if ($null -eq $refCsysId) {
        Write-Host "  No default coordinate system found - falling back to legacy default-datum planes." -ForegroundColor Yellow
    } elseif ($indexFirst) {
        # AXIS-DIRECTION FIX (2026-07-17): build ALL 3 anchor planes off CSYS_PAT_DEF so the
        # index csys comes out with axes DETERMINISTICALLY aligned to the model (+X/+Y/+Z),
        # which is what makes the grid-plane offset DIRECTION correct for ANY index hole.
        #   Why: the index csys is intersected from 3 planes; Creo derives its axis DIRECTIONS
        #   from those planes' normals. X/Z anchors off CSYS_PAT_DEF have deterministic +X/+Z
        #   normals, but the earlier "Y anchor off the SIDE default datum" (to sit the csys at
        #   the extrude-depth face) has a PART-SPECIFIC normal sign (+Y on some parts, -Y on
        #   others). A -Y makes (+X,-Y,+Z) left-handed, so Creo flips X or Z to restore right-
        #   handedness -> the csys is SOMETIMES mirrored -> the offset direction is sometimes
        #   wrong (the user's report). Anchoring Y off CSYS_PAT_DEF Axis_Y (always +Y) keeps
        #   the triple consistent -> aligned axes every time (like the Invoke-BaseCsys copy).
        #   TRADE-OFF: the csys Y ORIGIN now sits at the model-origin plane (GridY 0 off
        #   CSYS_PAT_DEF), not the extrude-depth face. That is COSMETIC -- the csys Y does not
        #   affect drilling (holes are On-Point at the SIDE-face intersections) nor the STAGE-6
        #   export (Y_index = 0 for every hole). To also sit it on the plate face WITH aligned
        #   axes needs an offset-COORDINATE-SYSTEM (translate CSYS_PAT_DEF, preserve axes) --
        #   an unrecorded dialog; a follow-up if wanted. --index-flip-x/-z remains a backstop.
        Write-Host ("  INDEX-FIRST: building the base coordinate system AT the index hole (grid {0:0.###}, {1:0.###}) off csys id $refCsysId, axes aligned to the model (Y anchor off CSYS_PAT_DEF, not the SIDE datum)..." -f $indexGridX, $indexGridZ) -ForegroundColor Cyan
        $baseCsysRes = Invoke-OutputCsys -RefCsysId $refCsysId -GridX $indexGridX -GridZ $indexGridZ -GridY 0.0
        if ($baseCsysRes.Ok) {
            $baseCsysId = [int]$baseCsysRes.CsysFeatId
            # Capture the anchor planes so STAGE 2.5 can reuse the index hole's own row/column
            # (AnchorPlaneIds = [X@indexX, Y@depth, Z@indexZ]); guard shape defensively.
            $anchors = @($baseCsysRes.AnchorPlaneIds)
            if ($anchors.Count -ge 3) { $indexAnchorX = [int]$anchors[0]; $indexAnchorZ = [int]$anchors[2] }
            Write-Host "  Base coordinate system created AT the index hole (feature id $baseCsysId). Grid planes are offset RELATIVE to it." -ForegroundColor Green
            Write-Host "  (If holes come out mirrored on an axis, re-run with --index-flip-x / --index-flip-z.)" -ForegroundColor DarkGray
        } else {
            Write-Host "  *****************************************************************" -ForegroundColor Red
            Write-Host "  *** INDEX-FIRST base csys NOT created: $($baseCsysRes.Reason)" -ForegroundColor Red
            Write-Host "  *** Falling back to a plain ORIGIN base csys + ABSOLUTE offsets." -ForegroundColor Red
            Write-Host "  *** The holes will be at their correct absolute positions but NOT" -ForegroundColor Red
            Write-Host "  *** referenced from the index hole (re-run to retry the index csys)." -ForegroundColor Red
            Write-Host "  *****************************************************************" -ForegroundColor Red
            # CLEAR the index coords too: without the index-hole csys the base sits at the
            # ORIGIN, so subtracting the index in STAGE 2.5 would drag every hole toward the
            # part corner (offset = gridX - index, off an origin csys). Dropping the index
            # here makes the fallback use ABSOLUTE offsets off the origin csys = correct
            # positions (just not index-referenced). $indexFirst gates the up-front choice.
            $indexFirst = $false
            $indexGridX = $null
            $indexGridZ = $null
        }
    }
    if ($null -ne $refCsysId -and $null -eq $baseCsysId -and -not $indexFirst) {
        Write-Host "  Found the default coordinate system (id $refCsysId); selecting it and confirming (ProCmdDatumCsys -> OK)..." -ForegroundColor Cyan
        $baseCsysRes = Invoke-BaseCsys -RefCsysId $refCsysId -Show
        if ($baseCsysRes.Ok) {
            $baseCsysId = [int]$baseCsysRes.CsysFeatId
            Write-Host "  Base coordinate system created (feature id $baseCsysId). All planes reference it." -ForegroundColor Green
        } else {
            Write-Host "  Base csys NOT created ($($baseCsysRes.Reason)) - falling back to legacy default-datum planes." -ForegroundColor Yellow
        }
    }
    Write-Host ""
}
$useCsys = ($null -ne $baseCsysId)
# index-first requires the csys base; if that fell back to legacy, drop index-first.
if ($indexFirst -and -not $useCsys) { $indexFirst = $false }

# ============================================================================
# STAGE 2 -- PARAMETRIC BOX (planes offset from the base csys, or legacy datums)
# ============================================================================
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "   STAGE 2 - parametric box$(if ($useCsys) { ' (planes referenced from the base csys)' } else { ' (legacy default-datum planes)' })" -ForegroundColor Cyan
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host ""

# Each label maps to a csys AXIS (Side=Y=box length, Top=X=plate width, Front=Z=plate
# height) in the csys build; in the legacy build it maps to the like-named default datum.
$planes = @(
    [pscustomobject]@{ Label = "Top";   Hint = "TOP";   Axis = "X"; Offset = 0.0; Sym = $null; BaseId = $null; FeatId = $null }
    [pscustomobject]@{ Label = "Side";  Hint = "SIDE";  Axis = "Y"; Offset = 0.0; Sym = $null; BaseId = $null; FeatId = $null }
    [pscustomobject]@{ Label = "Front"; Hint = "FRONT"; Axis = "Z"; Offset = 0.0; Sym = $null; BaseId = $null; FeatId = $null }
)

# Plane-offset sources, in priority order:
#   * SIDE  = box LENGTH, fixed by the decision tree = the bushing/sleeve length
#             ($bushingLen). Not prompted when the tree resolved a length.
#   * TOP   = plate WIDTH  and  FRONT = plate HEIGHT, taken from the orthogrid GUI
#             ($orthoGeo) when a pattern was laid out -- the plate is sized to hold
#             the grid, so the box face dims ARE the grid's plate extents. Per the
#             grid contract X/Width runs along TOP and Z/Height along FRONT, so
#             TOP<-Width, FRONT<-Height. Not prompted when $orthoGeo is present.
#   * anything still unset -> manual prompt (blank/0 -> 1.0 so it has a drivable dim).
Write-Host "  Box offsets:" -ForegroundColor Cyan
foreach ($p in $planes) {
    if ($p.Label -eq "Side" -and $null -ne $bushingLen) {
        # SIDE = the box LENGTH (through-thickness). PADDED by the relief depth so the
        # guide depth AFTER the slot cut equals the bushing length exactly (see the
        # "chip-relief depth budget" block above). No relief -> reliefPad 0 -> plain length.
        # ADDITIVE pad (absolute inches): plate = bushingLen + reliefPad.
        $p.Offset = [double]$bushingLen + $reliefPad
        if ($reliefPad -gt 0) {
            Write-Host ("    SIDE offset (box length) = {0} = bushing {1} + {2}"" relief pad (final guide = {1} after the slot; not asked)" -f `
                [Math]::Round($p.Offset,4), [Math]::Round([double]$bushingLen,4), $reliefPad) -ForegroundColor Green
        } else {
            Write-Host ("    SIDE offset (box length) = {0} (from the bushing length; not asked)" -f $p.Offset) -ForegroundColor Green
        }
        continue
    }
    if ($p.Label -eq "Top" -and $null -ne $orthoGeo) {
        $p.Offset = [double]$orthoGeo.Width
        Write-Host ("    TOP offset (plate width)  = {0} (from the orthogrid plate; not asked)" -f $p.Offset) -ForegroundColor Green
        continue
    }
    if ($p.Label -eq "Front" -and $null -ne $orthoGeo) {
        $p.Offset = [double]$orthoGeo.Height
        Write-Host ("    FRONT offset (plate height) = {0} (from the orthogrid plate; not asked)" -f $p.Offset) -ForegroundColor Green
        continue
    }
    $raw = Read-Host "    $($p.Label) plane offset (from $($p.Hint))"
    $v = 0.0
    if (-not [double]::TryParse($raw, [ref]$v) -or $v -eq 0) {
        Write-Host "      using 1.0" -ForegroundColor Yellow
        $v = 1.0
    }
    $p.Offset = $v
}
Write-Host ""

# --- capture the three base-plane IDs ---------------------------------------
# PREFERRED (no clicks): AUTO-DISCOVER the three default datums by NAME via the API
# (Find-DefaultDatumPicks enumerates ITEM_FEATURE + GetName()). The default datums
# are named literally TOP/SIDE/FRONT and are the same every part, so no user
# selection is needed -- the program finds them itself.
#   2nd CHOICE: if auto-discovery doesn't yield a clean all-three mapping (oddly
#     named part, GetName() miss), ONE multi-select of all three datums (Ctrl-click,
#     any order) read by NAME (Read-SelectionPlanePicks).
#   LAST RESORT: per-plane sequential capture (one click each).
# All three feed the SAME auto-map block, so the box build runs hands-free once the
# roles are known (SIDE drives the sketch plane + the extrude-to plane).
$autoMapped = $false

# 1) try the API first -- no selection, no prompt.
$picks = @(Find-DefaultDatumPicks)
$autoFound = ($picks | Where-Object { $null -ne $_.Role } | Select-Object -ExpandProperty Role -Unique)
if (@($autoFound).Count -ge 3) {
    Write-Host "  Found the three default datums by name (no selection needed):" -ForegroundColor Cyan
} else {
    # 2) API didn't find all three -- ask for the one multi-select. (Needed in BOTH
    # modes: even in csys mode the box sketches + the grid points intersect on the
    # SIDE default datum, so the three datums must be identified.)
    Write-Host "  Could not auto-find all three default datums by name -- identify them." -ForegroundColor Yellow
    Write-Host "  In Creo, Ctrl-click ALL THREE default datums (TOP, SIDE, FRONT) - any order -" -ForegroundColor White
    Write-Host "  then press ENTER here. (They are matched to roles by NAME, not click order.)" -ForegroundColor White
    Read-Host
    $picks = @(Read-SelectionPlanePicks)
}

if ($picks.Count -gt 0) {
    Write-Host ("  Read {0} selected datum(s):" -f $picks.Count) -ForegroundColor DarkGray
    foreach ($pk in $picks) {
        $nm = if ($pk.Name) { $pk.Name } else { "(no name)" }
        $rl = if ($pk.Role) { $pk.Role.ToUpper() } else { "unmatched" }
        Write-Host ("      id $($pk.Id)  name '$nm'  -> $rl") -ForegroundColor DarkGray
    }

    # assign each plane its base id by matched role; flag any conflict/gap
    $byRole = @{}
    $conflict = $false
    foreach ($pk in $picks) {
        if ($null -eq $pk.Role) { continue }
        if ($byRole.ContainsKey($pk.Role)) { $conflict = $true; continue }   # two datums claim the same role
        $byRole[$pk.Role] = $pk.Id
    }
    $allRolesPresent = ($byRole.ContainsKey('Top') -and $byRole.ContainsKey('Side') -and $byRole.ContainsKey('Front'))

    if ($allRolesPresent -and -not $conflict) {
        foreach ($p in $planes) { $p.BaseId = [int]$byRole[$p.Label] }
        Write-Host ""
        Write-Host "  Auto-mapped by name:" -ForegroundColor Green
        foreach ($p in $planes) {
            $dim = switch ($p.Label) { "Side" {"Width/length"} "Top" {"Height"} "Front" {"Depth"} default {""} }
            Write-Host ("      {0,-5} ({1,-12}) = datum id {2}" -f $p.Hint, $dim, $p.BaseId) -ForegroundColor White
        }
        Write-Host "  SIDE also becomes the sketch plane + extrude-to reference (hands-free box build)." -ForegroundColor DarkGray
        # Clean, unambiguous all-three mapping by name -> proceed automatically (no
        # accept prompt). The ambiguous cases below (conflict / missing role / empty
        # buffer) still fall back to one-click-per-plane.
        $autoMapped = $true
        Write-Host "  Proceeding with this mapping automatically." -ForegroundColor DarkGray
    } else {
        Write-Host ""
        if ($conflict) {
            Write-Host "  Two datums matched the same role - cannot auto-map by name." -ForegroundColor Yellow
        } else {
            $missing = @('Top','Side','Front' | Where-Object { -not $byRole.ContainsKey($_) })
            Write-Host ("  Could not match all three roles by name (missing: {0})." -f ($missing -join ', ')) -ForegroundColor Yellow
        }
        Write-Host "  Falling back to one-click-per-plane capture." -ForegroundColor Yellow
    }
} else {
    Write-Host "  Nothing was selected - falling back to one-click-per-plane capture." -ForegroundColor Yellow
}

# FALLBACK: original sequential capture - one quick click per plane, in order.
# Needed in BOTH modes: the box sketches on the SIDE default datum and the grid points
# intersect it, so the three datums must be captured even in csys mode.
if (-not $autoMapped) {
    Write-Host ""
    foreach ($p in $planes) {
        Read-Host "    Click the $($p.Hint) plane in Creo, then press ENTER"
        $contents = ($session.CurrentSelectionBuffer()).Contents
        if ($null -eq $contents -or $contents.Count -eq 0) {
            throw "Nothing was selected for the $($p.Hint) plane. Click the plane, then press ENTER."
        }
        $p.BaseId = [int]$contents[$contents.Count - 1].SelItem.Id
        Write-Host "      $($p.Hint) base feature ID = $($p.BaseId)" -ForegroundColor DarkGray
    }
}
Write-Host ""

# --- create the three BOX offset planes -- ALWAYS off the default datums ---
# The BOX is a LOCAL slab: it SKETCHES on the SIDE default datum and EXTRUDES up to the
# SIDE offset plane, so the plate THICKNESS is the distance between those two planes.
# For thickness == bushingLen EXACTLY, the SIDE offset plane MUST be offset bushingLen
# FROM the SIDE default datum (the sketch plane) -- i.e. a plain New-OffsetPlane, in BOTH
# csys and legacy modes.
#   *** BUG FIXED 2026-07-16: in csys mode the SIDE plane used to be Axis_Y @ bushingLen
#   *** off the BASE CSYS (measured from the csys/CSYS_PAT_DEF Y-origin), while the box
#   *** sketched on the SIDE DEFAULT DATUM -- a different Y origin. The extrude then spanned
#   *** (SIDE-datum-to-csys-origin gap) + bushingLen, so the plate came out MUCH taller than
#   *** the bushing length (measured 3.37 vs a 0.75 bushing). Offsetting the box planes from
#   *** the default datums (the sketch plane's own frame) makes the thickness exact.
# The csys is ONLY for the hole GRID: STAGE 2.5's per-coord Axis_X/Axis_Z pitch planes are
# offset from the base csys so the holes reference the index hole. The box footprint is the
# hand-drawn rectangle on the SIDE datum, so the TOP/FRONT planes are just visual guides and
# their default-datum offsets land at the same absolute plate boundary either way (an
# index-relative offset off the index-hole csys cancels back to the absolute coord).
Write-Host "  Creating the three box offset planes off the default datums (no clicks needed)..." -ForegroundColor Cyan
if ($useCsys) { Write-Host "  (box planes are datum-referenced; only the STAGE 2.5 grid pitch planes reference the base csys.)" -ForegroundColor DarkGray }
Write-Host ""
foreach ($p in $planes) {
    Write-Host "  --- $($p.Label) plane (offset $($p.Offset) from $($p.Hint), id $($p.BaseId)) ---" -ForegroundColor Cyan
    $res = New-OffsetPlane -Label $p.Label -Offset $p.Offset -BaseId $p.BaseId
    $p.Sym    = $res.Symbol
    $p.FeatId = $res.FeatId
    Write-Host ""
}

# --- show (unhide) the new planes; runs on FeatId, before the dim gate ---
$toShow = @($planes | Where-Object { $null -ne $_.FeatId })
if ($toShow.Count -gt 0) {
    Write-Host "  Showing the $($toShow.Count) new plane(s)..." -ForegroundColor Cyan
    foreach ($p in $toShow) {
        $showMacro =
            (Get-SelectByIdMacro -FeatId $p.FeatId) +
            "~ Command ``ProCmdViewShow@PopupMenuTree``;"
        Invoke-Macro "show $($p.Label) plane (id $($p.FeatId))" $showMacro
    }
    Write-Host ""
}

# Gate the parametric/resize half on planes that produced a DRIVABLE dim.
$made = @($planes | Where-Object { $null -ne $_.Sym })
if ($made.Count -eq 0) {
    throw "No offset planes produced a drivable dim - nothing to resize. (Any planes that WERE created have been shown above.)"
}
if ($made.Count -lt 3) {
    Write-Host "  WARNING: only $($made.Count) of 3 planes produced a drivable dim." -ForegroundColor Yellow
    Write-Host ""
}

Show-BoxState -Made $made
Write-Host ""

# --- CREATE THE BOX: extrude-first with an internal sketch (plane-probe v2) ---
# DIRECTION: sketch ON the og/default datum, extrude UP TO the offset plane, so
# the feature reads og -> offset. Stays parametric because the og datum and the
# offset plane are separated by exactly the offset dim. Both refs captured BY ID
# up front; the ONLY manual step is drawing the rough rectangle (forces ONE split
# into two macros around the user's draw).
$sidePlane = @($made | Where-Object { $_.Label -eq "Side" })
$sidePlane = if ($sidePlane.Count -gt 0) { $sidePlane[0] } else { $null }

$sketchPlaneId = $null
$extrudeToId   = $null

if ($useCsys) {
    # CSYS PATH (hands-free): sketch on the SIDE DEFAULT DATUM and extrude UP TO the SIDE
    # OFFSET plane -- which is now offset bushingLen FROM the SIDE default datum (a plain
    # New-OffsetPlane, same as legacy), so the plate thickness == bushingLen EXACTLY. (The
    # SIDE plane used to be Axis_Y @ len off the base csys, a different Y origin than the
    # sketch plane -> the plate came out much taller than the bushing; fixed 2026-07-16.)
    if ($null -ne $sidePlane -and $null -ne $sidePlane.BaseId -and $null -ne $sidePlane.FeatId) {
        $sketchPlaneId = [int]$sidePlane.BaseId
        $extrudeToId   = [int]$sidePlane.FeatId
        Write-Host "  Building the box (sketch on the SIDE datum, extrude to the SIDE offset plane):" -ForegroundColor Green
        Write-Host "      sketch on   SIDE default datum (id $sketchPlaneId)" -ForegroundColor White
        Write-Host "      extrude to  SIDE offset plane  (bushingLen from the SIDE datum, id $extrudeToId)" -ForegroundColor White
    } else {
        Write-Host "  SIDE datum or SIDE offset plane missing - cannot build the box hands-free." -ForegroundColor Yellow
        Write-Host "  (The default datums must be captured in csys mode; skipping the box, resize still available.)" -ForegroundColor Yellow
    }
} else {
    # LEGACY PATH: build against the default datums (auto-mapped by name, or manual).
    if ($autoMapped) {
        $doBox = "y"
        Write-Host "  Building the box automatically (planes mapped by name; extrude-first, internal sketch)..." -ForegroundColor Cyan
    } else {
        Write-Host "  Build the box now? (Extrude-first, internal sketch; og -> offset direction)" -ForegroundColor Cyan
        $doBox = Read-Host "    (y to create the box, anything else to skip and go straight to resize)"
    }
    if ($doBox.Trim().ToUpper() -eq "Y") {
        if ($null -eq $sidePlane) {
            Write-Host "  No SIDE plane was created, so there is nothing to build against. Skipping box." -ForegroundColor Yellow
        }
        # HANDS-FREE PATH: the all-three multi-select already identified SIDE by name
        # AND confirmed once, so the box's two references are known with no further
        # clicks - sketch ON the SIDE og/default datum ($sidePlane.BaseId), extrude UP
        # TO the SIDE offset plane ($sidePlane.FeatId). Requires both ids.
        elseif ($autoMapped -and $null -ne $sidePlane.BaseId -and $null -ne $sidePlane.FeatId) {
            $sketchPlaneId = [int]$sidePlane.BaseId
            $extrudeToId   = [int]$sidePlane.FeatId
            Write-Host ""
            Write-Host "  Box references taken from the SIDE mapping (no clicks needed):" -ForegroundColor Green
            Write-Host "      sketch on   SIDE og/default datum (id $sketchPlaneId)" -ForegroundColor White
            Write-Host "      extrude to  SIDE offset plane      (id $extrudeToId)" -ForegroundColor White
        }
        # FALLBACK PATH: no clean auto-map (or SIDE ids missing) - click each plane.
        else {
            Write-Host ""
            Write-Host "  In Creo: CLICK the og/default datum to sketch the box footprint on," -ForegroundColor White
            Write-Host "  then press ENTER. (Tip: this is normally the SIDE datum.)" -ForegroundColor White
            Read-Host
            $sketchPlaneId = Read-SelectedId
            if ($null -eq $sketchPlaneId) {
                Write-Host "  Nothing selected for the sketch plane - skipping box." -ForegroundColor Yellow
            } else {
                Write-Host "      sketch plane feature ID = $sketchPlaneId" -ForegroundColor DarkGray
            }

            if ($null -ne $sketchPlaneId) {
                Write-Host ""
                Write-Host "  In Creo: CLICK the OFFSET plane to extrude UP TO (the box grows" -ForegroundColor White
                Write-Host "  from the og plane toward this datum), then press ENTER. Or just" -ForegroundColor White
                Write-Host "  press ENTER to use the SIDE offset plane." -ForegroundColor White
                Read-Host
                $extrudeToId = Read-SelectedId
                if ($null -eq $extrudeToId) {
                    $extrudeToId = $sidePlane.FeatId
                    Write-Host "      extruding up to SIDE offset plane (id $extrudeToId)" -ForegroundColor DarkGray
                } else {
                    Write-Host "      extrude-to feature ID = $extrudeToId" -ForegroundColor DarkGray
                }
            }
        }
    }
}

if ($null -ne $sketchPlaneId) {

        $stamp = $null
        try { $stamp = $model.VersionStamp } catch {}

        # MACRO A: select sketch plane BY ID FIRST (its buffer_clean wipes the
        # stale offset plane), -> ProCmdFtExtrude consumes the og datum -> orient
        # -> arm the corner-rectangle tool. Stops before the manual draw.
        $mkArm =
            (Get-SelectByIdMacro -FeatId $sketchPlaneId) +
            "~ Command ``ProCmdFtExtrude``;" +
            "~ Command ``ProCmdViewSketchView``;" +
            "~ Command ``ProCmdSketRectangle`` 1;"
        Invoke-Macro "select sketch plane (id $sketchPlaneId) + extrude + arm rectangle" $mkArm

        Write-Host ""
        Write-Host "  In Creo (internal sketcher): draw the plate rectangle." -ForegroundColor White
        Write-Host "  To snap the second corner of the rectangle in the intersection point of the" -ForegroundColor White
        Write-Host "  newly created planes, hold CTRL + ALT, and then select the 2 planes." -ForegroundColor White
        Write-Host "  If done correctly, there should be dotted blue lines that form the rectangle" -ForegroundColor White
        Write-Host "  shape. Then draw the rectangle from corner to corner. Press Esc to finish the" -ForegroundColor White
        Write-Host "  rectangle, then press ENTER here." -ForegroundColor White
        Read-Host

        # MACRO B: finish the internal sketch, set depth UP TO the extrude-to
        # plane, blur the field, confirm. The extrude-to plane is fed to the open
        # depth collector via Get-SelectDatumByIdMacro (type DATUM, surfenator's
        # proven up-to-plane feed) -- NOT the Feature-typed Get-SelectByIdMacro,
        # which left the dashboard waiting for a manual plane click. No buffer_clean
        # (clearing mid-dashboard can deactivate the open collector).
        $mkFinish =
            "~ Command ``ProCmdSketDone``;" +
            "~ Select ``main_dlg_cur`` ``maindashInst0.depth_flyout``;" +
            "~ Close ``main_dlg_cur`` ``maindashInst0.depth_flyout``;" +
            "~ Activate ``main_dlg_cur`` ``maindashInst0.toselected`` 1;" +
            "~ Trigger ``extrev_1_placement.0.0`` ``PH.section_select_list`` ``0``;" +
            "~ Trigger ``extrev_1_placement.0.0`` ``PH.section_select_list`` ````;" +
            (Get-SelectDatumByIdMacro -FeatId $extrudeToId) +
            "~ Enter ``main_dlg_cur`` ``dashInst0.Quit``;" +
            "~ Exit  ``main_dlg_cur`` ``dashInst0.Quit``;" +
            "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"
        Invoke-Macro "finish sketch + extrude up to plane id $extrudeToId + confirm" $mkFinish

        if ($null -ne $stamp) {
            for ($i = 0; $i -lt 100; $i++) {
                try { if ($model.VersionStamp -ne $stamp) { break } } catch {}
                Start-Sleep -Milliseconds 50
            }
        }
        Write-Host ""
}

# --- RESIZE LOOP -- A = all three, 1..N = one plane, D/blank = done (-> STAGE 3) ---
# In orthogrid mode, the box was sized from the GUI's plate dimensions -- skip the
# resize loop entirely (no manual adjustments needed).
if ($null -ne $orthoGeo) {
    Write-Host "  Resize loop skipped (box sized by orthogrid plate dimensions)." -ForegroundColor DarkGray
} else {
Write-Host "  Resize loop (optional - adjust the box before drilling):" -ForegroundColor Cyan
Write-Host "    A = set ALL three (resize the box),  1-$($made.Count) = one plane,  D/blank = done -> drill" -ForegroundColor White
}
while ($null -eq $orthoGeo) {
    $cmd = Read-Host "  Command (A / 1-$($made.Count) / D)"
    if ([string]::IsNullOrWhiteSpace($cmd) -or $cmd.Trim().ToUpper() -eq "D") {
        Write-Host "  Done resizing - moving to drilling." -ForegroundColor Cyan
        break
    }

    if ($cmd.Trim().ToUpper() -eq "A") {
        $targets = @()
        foreach ($p in $made) {
            $dim = switch ($p.Label) { "Side" { "Width" } "Top" { "Height" } "Front" { "Depth" } default { "" } }
            $raw = Read-Host "    $($p.Label) ($dim) new offset"
            $v = 0.0
            if (-not [double]::TryParse($raw, [ref]$v)) { Write-Host "      not a number - skipping $($p.Label)." -ForegroundColor Yellow; continue }
            $targets += [pscustomobject]@{ Plane = $p; Want = $v }
        }
        foreach ($t in $targets) {
            $now = Set-PlaneOffset -Plane $t.Plane -Value $t.Want
            if ($null -ne $now -and [math]::Abs($now - $t.Want) -lt 1e-4) {
                Write-Host "    $($t.Plane.Label) $($t.Plane.Sym) = $now  (held)" -ForegroundColor Green
            } else {
                Write-Host "    $($t.Plane.Label) $($t.Plane.Sym) = $now  (wanted $($t.Want) - did NOT hold)" -ForegroundColor Yellow
            }
        }
        Write-Host ""
        Show-BoxState -Made $made
        Write-Host ""
        continue
    }

    $sel = 0
    if (-not [int]::TryParse($cmd, [ref]$sel) -or $sel -lt 1 -or $sel -gt $made.Count) {
        Write-Host "    enter A or 1-$($made.Count)." -ForegroundColor Yellow; continue
    }
    $p = $made[$sel - 1]

    $valRaw = Read-Host "    New offset for $($p.Label) ($($p.Sym))"
    $v = 0.0
    if (-not [double]::TryParse($valRaw, [ref]$v)) { Write-Host "    not a number." -ForegroundColor Yellow; continue }

    $now = Set-PlaneOffset -Plane $p -Value $v
    if ($null -ne $now -and [math]::Abs($now - $v) -lt 1e-4) {
        Write-Host "    $($p.Label) $($p.Sym) = $now  (held)" -ForegroundColor Green
    } else {
        Write-Host "    $($p.Label) $($p.Sym) = $now  (wanted $v - did NOT hold)" -ForegroundColor Yellow
    }
}
Write-Host ""

# ============================================================================
# STAGE 2.5 -- DATUM-POINT CREATION (plane intersections, all by ID)
# ============================================================================
# Programmatic creation of EVERY target point via the PROVEN 3-plane-intersection
# recipe (point-probe.cmd, confirmed live 2026-06-24): for each point, the point =
# intersection of (SIDE face) + (an X-offset plane from TOP) + (a Z-offset plane
# from FRONT). Planes are SHARED via Get-SharedPlanePlan -- ONE plane per DISTINCT
# X offset + one per distinct Z offset -- so this serves BOTH the orthogrid
# (1 face + Nx + Nz planes -> Nx*Nz points) AND the custom layout (1 face +
# distinctX + distinctZ planes -> Count points). ALL widgets confirmed live; NO
# screen picks; each RunMacro is atomic + independent. Each coordinate is a
# drivable feature-level offset dim -> fully parametric.
#
# A coordinate of ~0 reuses the BASE datum directly (point-probe's trick) instead
# of a degenerate offset plane -- so a custom point typed at X=0 / Z=0 lands on the
# TOP / FRONT base datum. For the orthogrid (Edge>0) no coordinate is ~0, so this
# produces the IDENTICAL planes + intersections the live-confirmed path always did.
#
# If the plane/point creation fails, falls back to Invoke-ManualPointGrid (user
# creates + selects all points by hand). Never drills a zero-point "Done".
$gridPointIDs = @()
# $gridPlaneIds records the offset planes STAGE 2.5 creates (the X/Z loops below do
# `$gridPlaneIds += ...`). It no longer feeds a later stage (the chip-relief PATHS
# stage that consumed it was removed when slots replaced relief) but is kept as a
# harmless record. MUST be initialised to @() here at top level: an un-initialised
# `$null += obj` makes it a SCALAR PSObject (not a 1-element array), and the SECOND
# += then throws "does not contain a method named 'op_Addition'".
$gridPlaneIds = @()
# $csysRecords WAS the INDEX-HOLE csys registry consumed by the post-slot index-hole
# stages (index-hole coordinate system + coordinate export + csys-referenced points).
# Those stages were REMOVED 2026-07-21 (the index hole is already established up front in
# STAGE 1.9 / index-first mode -- no need to re-pick a csys after the slots), so this
# registry now has NO consumer. It is LEFT as a harmless record (exactly like $gridPlaneIds
# above): STAGE 2.5 still fills PointId + PlaneIds and STAGE 3 still fills HoleFeatId, but
# nothing reads them. MUST be @() at top level (same scalar-PSObject += trap as
# $gridPlaneIds above).
$csysRecords = @()
if ($null -ne $orthoGeo) {
    $modeLabel = if ($orthoGeo.Mode -eq 'custom') { "custom layout" } else { "orthogrid" }
    Write-Host "  ====================================================================" -ForegroundColor Cyan
    Write-Host "   STAGE 2.5 - create all $($orthoGeo.Count) datum points ($modeLabel, plane intersections)" -ForegroundColor Cyan
    Write-Host "  ====================================================================" -ForegroundColor Cyan
    Write-Host ""
    if ($orthoGeo.Mode -eq 'custom') {
        Write-Host ("  {0} custom point(s), plate {1:0.00} x {2:0.00}." -f $orthoGeo.Count, $orthoGeo.Width, $orthoGeo.Height) -ForegroundColor Green
    } else {
        Write-Host ("  Grid: {0} points, plate {1:0.00} x {2:0.00} (Nx={3}, Nz={4}, cc {5}x{6})." -f `
            $orthoGeo.Count, $orthoGeo.Width, $orthoGeo.Height, $orthoGeo.Nx, $orthoGeo.Nz, $orthoGeo.CcX, $orthoGeo.CcZ) -ForegroundColor Green
    }

    # Base datum ids for the offset planes (already captured in STAGE 2 -- still set
    # by the API discovery even in csys mode, and used by the legacy grid path).
    $topBaseId   = ($planes | Where-Object { $_.Label -eq "Top"   } | Select-Object -First 1).BaseId
    $frontBaseId = ($planes | Where-Object { $_.Label -eq "Front" } | Select-Object -First 1).BaseId
    if ($useCsys) {
        # csys grid: each point = (SIDE default datum = the box near face) n
        # (Axis_X @ Xoff, from the base csys) n (Axis_Z @ Zoff, from the base csys).
        # The face only sets Y=0 (proven datum); the X/Z position comes entirely from
        # the csys-referenced pitch planes, so re-placing the base csys (STAGE 5.5)
        # still moves every point in X/Z with it.
        $facePlaneId = if ($null -ne $sidePlane -and $null -ne $sidePlane.BaseId) { [int]$sidePlane.BaseId } else { $null }
        $canAutoGrid = ($null -ne $baseCsysId -and $null -ne $facePlaneId)
    } else {
        # legacy grid: the SIDE BASE datum (og/default) is the face all points sit on;
        # X planes offset from TOP, Z planes from FRONT. ClearDia only widens the plate,
        # does NOT shift the point positions (the inset fix), so dimensions are correct.
        $facePlaneId = if ($null -ne $sidePlane -and $null -ne $sidePlane.BaseId) { [int]$sidePlane.BaseId } else { $null }
        $canAutoGrid = ($null -ne $topBaseId -and $null -ne $frontBaseId -and $null -ne $facePlaneId)
    }
    if (-not $canAutoGrid) {
        Write-Host "  Missing base datum or SIDE offset plane - cannot auto-create the points." -ForegroundColor Yellow
        Write-Host "  Falling back to the manual path (you create + select all points by hand)." -ForegroundColor Yellow
    } else {
        # Shared-plane plan: distinct X/Z offsets + each point's index into them.
        # Works identically for orthogrid + custom (the orthogrid's distinct X
        # offsets are {Edge, Edge+CcX, ...}, so a column-I point indexes XCoords[I]).
        $plan = Get-SharedPlanePlan -Points $orthoGeo.Points
        $tol  = 1e-6
        Write-Host ("  Creating {0} X-plane(s) + {1} Z-plane(s) + {2} intersection point(s)..." -f `
            $plan.XCoords.Count, $plan.ZCoords.Count, $orthoGeo.Count) -ForegroundColor Cyan
        Write-Host "  (All by ID, no picks, no pattern - fully automatic.)" -ForegroundColor DarkGray
        $ok = $true

        # 1. One X-offset plane per DISTINCT X coord. $xPlaneIds is parallel to
        #    $plan.XCoords so a point's .Xi indexes straight into it.
        # INDEX-FIRST: the base csys sits AT the index hole, so each grid plane is offset
        # RELATIVE to it -> Axis_X @ ((gridX - indexGridX) * flipX). The index hole's own X
        # becomes 0 (its point is on the csys origin); every other hole is the X margin
        # DIFFERENCE, so the drilled pattern matches the GUI layout referenced from the index
        # hole. flipX (+/-1, --index-flip-x) corrects a mirrored axis without a code change.
        # NON-INDEX csys mode: idxX=0, flipX=1 -> plain absolute Axis_X @ gridX off the origin
        # base csys. Legacy mode: a ~0 coord reuses the TOP/FRONT base datum directly.
        # THE SUBTRACTION (user's spec): when an index hole was chosen, every grid plane
        # offset is the ABSOLUTE grid coord MINUS the index hole's coord, so the index hole
        # lands at offset 0 (on the csys) and the others are the margin difference. Gate on
        # indexGridX being SET (an index was chosen) -- NOT on $indexFirst, which can get
        # reset (e.g. by the base-csys build) and was leaving the offsets ABSOLUTE at runtime.
        $idxX = if ($null -ne $indexGridX) { [double]$indexGridX } else { 0.0 }
        $idxZ = if ($null -ne $indexGridZ) { [double]$indexGridZ } else { 0.0 }
        $fX   = if ($null -ne $indexGridX) { [double]$indexFlipX } else { 1.0 }
        $fZ   = if ($null -ne $indexGridZ) { [double]$indexFlipZ } else { 1.0 }
        # ---- INDEX-FIRST: RELIABLE-FRAME build off CSYS_PAT_DEF (2026-07-21 fix) ----
        # ROOT CAUSE of the "scattered holes, same every run, --index-flip doesn't help"
        # bug on a NON-CORNER index: the grid pitch planes were offset off the INTERSECTED
        # index csys ($baseCsysId) at a SIGNED offset (grid-index). That csys's axis
        # DIRECTIONS come from 3 intersecting planes' normals, which read NULL on this
        # build -> its +/- orientation is not deterministic. A min-corner index has all
        # offsets >=0 so it never bit; an interior index splits into -cc..0..+cc and the
        # negative-side planes resolved to the WRONG side while the +side landed right ->
        # scattered, deterministic, and un-fixable by --index-flip (negating ALL offsets
        # just swaps which side is wrong).
        #   THE FIX: build every pitch plane off CSYS_PAT_DEF ($refCsysId) -- whose axes
        # ARE the model axes -- at the ABSOLUTE grid coordinate. Absolute-coordinate
        # ordering IS the column/row (N) ordering, so a hole with N>index-N lands on the
        # +side of the index automatically (the DIRECTION the user wants) with NO negative
        # offsets and NO null-normal dependency. The index's OWN column/row is the anchor
        # plane (already off CSYS_PAT_DEF at the index coord -> same frame). The index csys
        # is still created AT the index hole for STAGE 5 reference + STAGE 6 export
        # (unchanged); nothing moves. This mirrors the proven non-index csys path (absolute
        # off a reliable csys) and the legacy path (absolute off the TOP/FRONT datums).
        # $idxRefBuild gates it: index chosen ($indexGridX set) AND a reliable CSYS_PAT_DEF
        # id in hand. If $refCsysId is somehow missing, fall back to the OLD index-csys-
        # relative build (never crash) -- flagged loudly so a live run shows which path ran.
        $idxRefBuild = ($null -ne $indexGridX -and $null -ne $refCsysId)
        $dirPlan = $null
        if ($null -ne $indexGridX) {
            # The user's N-INDEXED DIRECTIONAL CHECK, made visible: per distinct X column /
            # Z row -- its N (1..count), the index hole's N, RelN, the +/-/0 direction, and
            # the absolute coord the reliable-frame plane is offset to.
            $dirPlan = Get-IndexDirectionalPlanePlan -Points $orthoGeo.Points -IndexGridX $idxX -IndexGridZ $idxZ
            Write-Host "  INDEX DIRECTIONAL CHECK (N per direction; index hole = the N=IndexN column/row):" -ForegroundColor Magenta
            Write-Host ("    X columns (Nx={0}, index column N={1}):" -f $dirPlan.Nx, $dirPlan.IndexNX) -ForegroundColor Magenta
            foreach ($e in @($dirPlan.XPlanes)) {
                $tag = if ($e.IsIndex) { "INDEX (own column, offset 0 -> reuse anchor)" } elseif ($e.Direction -lt 0) { "- side (left of index)" } else { "+ side (right of index)" }
                Write-Host ("      N={0}  coord={1:0.###}  RelN={2,2}  dir={3,2}  {4}" -f $e.N, $e.AbsCoord, $e.RelN, $e.Direction, $tag) -ForegroundColor DarkGray
            }
            Write-Host ("    Z rows (Nz={0}, index row N={1}):" -f $dirPlan.Nz, $dirPlan.IndexNZ) -ForegroundColor Magenta
            foreach ($e in @($dirPlan.ZPlanes)) {
                $tag = if ($e.IsIndex) { "INDEX (own row, offset 0 -> reuse anchor)" } elseif ($e.Direction -lt 0) { "- side (below index)" } else { "+ side (above index)" }
                Write-Host ("      N={0}  coord={1:0.###}  RelN={2,2}  dir={3,2}  {4}" -f $e.N, $e.AbsCoord, $e.RelN, $e.Direction, $tag) -ForegroundColor DarkGray
            }
            if ($idxRefBuild) {
                Write-Host ("    Building pitch planes off CSYS_PAT_DEF (id {0}) at the ABSOLUTE coord above (reliable model axes; --index-flip is a no-op here)." -f $refCsysId) -ForegroundColor Green
            } else {
                Write-Host "    WARNING: no CSYS_PAT_DEF id ($refCsysId) -- falling back to the OLD index-csys-relative build (the path with the scatter bug)." -ForegroundColor Yellow
            }
        } else {
            Write-Host "  (NOT index-first: grid planes use absolute offsets off the origin base csys.)" -ForegroundColor DarkGray
        }
        $xPlaneIds = @()
        foreach ($xOff in $plan.XCoords) {
            if ($useCsys) {
                # INDEX-FIRST RELIABLE-FRAME build: off CSYS_PAT_DEF at the ABSOLUTE coord.
                if ($idxRefBuild) {
                    # index's OWN column (coord == index coord) -> reuse the X anchor plane
                    # (already off CSYS_PAT_DEF at the index coord: same frame, no new plane).
                    if ($null -ne $indexAnchorX -and [math]::Abs([double]$xOff - $idxX) -le $tol) {
                        $xPlaneIds += [int]$indexAnchorX
                        Write-Host "    X column at the index coord -> reusing index anchor plane $indexAnchorX (no new plane)" -ForegroundColor DarkGray
                        continue
                    }
                    $res = New-CsysOffsetPlane -CsysFeatId $refCsysId -Axis 'X' -Offset ([double]$xOff) -SkipSymbolWait
                    if ($null -eq $res.FeatId) { Write-Host "  X-plane (CSYS_PAT_DEF Axis_X @ $xOff) FAILED." -ForegroundColor Red; $ok = $false; break }
                    $xPlaneIds += [int]$res.FeatId
                    continue
                }
                # NON-INDEX csys mode (or the $refCsysId-missing fallback): off the base csys.
                # In non-index mode $idxX=0/$fX=1 so this is a plain absolute Axis_X @ gridX.
                $xEff = ([double]$xOff - $idxX) * $fX
                # INDEX hole's own column (relative offset ~0): REUSE the X anchor plane that
                # already built the index csys (it sits at model-X = indexX) instead of making
                # a redundant coincident plane. This is why a row of N makes only N-1 new
                # planes (user's spec). Only when an index anchor exists (index-first mode).
                if ($null -ne $indexAnchorX -and [math]::Abs($xEff) -le $tol) {
                    $xPlaneIds += [int]$indexAnchorX
                    Write-Host "    X offset 0 (index column) -> reusing index anchor plane $indexAnchorX (no new plane)" -ForegroundColor DarkGray
                    continue
                }
                $res = New-CsysOffsetPlane -CsysFeatId $baseCsysId -Axis 'X' -Offset $xEff -SkipSymbolWait
                if ($null -eq $res.FeatId) { Write-Host "  X-plane (csys Axis_X @ $xEff) FAILED." -ForegroundColor Red; $ok = $false; break }
                $xPlaneIds += [int]$res.FeatId
            } else {
                if ([math]::Abs([double]$xOff) -le $tol) {
                    $xPlaneIds += [int]$topBaseId
                    Write-Host "    X=0 -> using TOP base datum $topBaseId directly" -ForegroundColor DarkGray
                    continue
                }
                $res = New-OffsetPlane -Label "X$($xPlaneIds.Count)" -Offset ([double]$xOff) -BaseId ([int]$topBaseId) -SkipSymbolWait
                if ($null -eq $res.FeatId) { Write-Host "  X-plane at offset $xOff FAILED." -ForegroundColor Red; $ok = $false; break }
                $xPlaneIds += [int]$res.FeatId
            }
        }
        if ($ok) { Write-Host ("  {0} X-plane reference(s) ready." -f $xPlaneIds.Count) -ForegroundColor DarkGray }

        # 2. One Z-offset plane per DISTINCT Z coord (csys Axis_Z, or offset from FRONT base).
        $zPlaneIds = @()
        if ($ok) {
            foreach ($zOff in $plan.ZCoords) {
                if ($useCsys) {
                    # INDEX-FIRST RELIABLE-FRAME build: off CSYS_PAT_DEF at the ABSOLUTE coord.
                    if ($idxRefBuild) {
                        if ($null -ne $indexAnchorZ -and [math]::Abs([double]$zOff - $idxZ) -le $tol) {
                            $zPlaneIds += [int]$indexAnchorZ
                            Write-Host "    Z row at the index coord -> reusing index anchor plane $indexAnchorZ (no new plane)" -ForegroundColor DarkGray
                            continue
                        }
                        $res = New-CsysOffsetPlane -CsysFeatId $refCsysId -Axis 'Z' -Offset ([double]$zOff) -SkipSymbolWait
                        if ($null -eq $res.FeatId) { Write-Host "  Z-plane (CSYS_PAT_DEF Axis_Z @ $zOff) FAILED." -ForegroundColor Red; $ok = $false; break }
                        $zPlaneIds += [int]$res.FeatId
                        continue
                    }
                    # NON-INDEX csys mode (or fallback): off the base csys (idxZ=0/fZ=1 -> absolute).
                    $zEff = ([double]$zOff - $idxZ) * $fZ
                    # INDEX hole's own row (relative offset ~0): REUSE the Z anchor plane
                    # (at model-Z = indexZ) instead of a redundant coincident plane.
                    if ($null -ne $indexAnchorZ -and [math]::Abs($zEff) -le $tol) {
                        $zPlaneIds += [int]$indexAnchorZ
                        Write-Host "    Z offset 0 (index row) -> reusing index anchor plane $indexAnchorZ (no new plane)" -ForegroundColor DarkGray
                        continue
                    }
                    $res = New-CsysOffsetPlane -CsysFeatId $baseCsysId -Axis 'Z' -Offset $zEff -SkipSymbolWait
                    if ($null -eq $res.FeatId) { Write-Host "  Z-plane (csys Axis_Z @ $zEff) FAILED." -ForegroundColor Red; $ok = $false; break }
                    $zPlaneIds += [int]$res.FeatId
                } else {
                    if ([math]::Abs([double]$zOff) -le $tol) {
                        $zPlaneIds += [int]$frontBaseId
                        Write-Host "    Z=0 -> using FRONT base datum $frontBaseId directly" -ForegroundColor DarkGray
                        continue
                    }
                    $res = New-OffsetPlane -Label "Z$($zPlaneIds.Count)" -Offset ([double]$zOff) -BaseId ([int]$frontBaseId) -SkipSymbolWait
                    if ($null -eq $res.FeatId) { Write-Host "  Z-plane at offset $zOff FAILED." -ForegroundColor Red; $ok = $false; break }
                    $zPlaneIds += [int]$res.FeatId
                }
            }
            if ($ok) { Write-Host ("  {0} Z-plane reference(s) ready." -f $zPlaneIds.Count) -ForegroundColor DarkGray }
        }

        # Record the grid offset planes (tagged with axis + offset). This was
        # consumed by the old chip-relief PATHS stage (removed); kept as a harmless
        # record. Skip the reused base datums (legacy X=0/Z=0) AND the reused index
        # anchor planes (csys index column/row) -- neither is a NEW offset plane.
        if ($ok) {
            for ($qi = 0; $qi -lt $xPlaneIds.Count; $qi++) {
                if ([int]$xPlaneIds[$qi] -ne [int]$topBaseId -and ($null -eq $indexAnchorX -or [int]$xPlaneIds[$qi] -ne [int]$indexAnchorX)) {
                    $gridPlaneIds += [pscustomobject]@{ FeatId = [int]$xPlaneIds[$qi]; Axis = 'X'; Offset = [double]$plan.XCoords[$qi] }
                }
            }
            for ($qi = 0; $qi -lt $zPlaneIds.Count; $qi++) {
                if ([int]$zPlaneIds[$qi] -ne [int]$frontBaseId -and ($null -eq $indexAnchorZ -or [int]$zPlaneIds[$qi] -ne [int]$indexAnchorZ)) {
                    $gridPlaneIds += [pscustomobject]@{ FeatId = [int]$zPlaneIds[$qi]; Axis = 'Z'; Offset = [double]$plan.ZCoords[$qi] }
                }
            }
        }

        # 3. One intersection point per input point: face n X-plane[Xi] n Z-plane[Zi].
        # This loop is the ORIGINAL point-creation code -- it fires ONLY the creation
        # macros, with NO COM reads between them (reading ListItems mid-loop disrupts
        # the very commits it would poll for). The index-csys registry is built AFTER
        # the loop as pure post-processing (below), so it cannot affect point creation.
        if ($ok) {
            $beforePts = Get-PointIdSet -Model $model -TypeObj $pfcType
            $ptIdx = 0
            foreach ($tri in $plan.Triples) {
                $ptIdx++
                Show-Progress ([Math]::Floor(($ptIdx / $orthoGeo.Count) * 100)) "Point $ptIdx/$($orthoGeo.Count)"
                $macro = Build-IntersectPointMacro -PlaneIds @([int]$facePlaneId, [int]$xPlaneIds[$tri.Xi], [int]$zPlaneIds[$tri.Zi])
                try { $session.RunMacro($macro) } catch {
                    Write-Host "  Point $ptIdx macro errored: $($_.Exception.Message)" -ForegroundColor Red
                    $ok = $false; break
                }
            }
            Show-Progress 100 "Done"
            $newIds = Resolve-NewPointIds -Model $model -TypeObj $pfcType -Before $beforePts
            # INDEX-CSYS REGISTRY (post-processing; does NOT touch point creation):
            # Creo assigns datum-point ids in ascending CREATION order and $plan.Triples
            # is in creation order, so index k of the sorted new ids IS the k-th triple.
            # Zip them into PointId -> PlaneIds records. PLANE ORDER = X-normal, then
            # Y-normal, then Z-normal (the order ProCmdDatumCsys assigns axes from):
            #   X-normal = the X-offset plane (offset from TOP; per the grid contract,
            #              "X = TOP-direction offset", so TOP's normal IS the X axis),
            #   Y-normal = the SIDE face (the box length/thickness axis),
            #   Z-normal = the Z-offset plane (offset from FRONT; FRONT's normal = Z).
            # So the order is [xPlane, face, zPlane] -- NOT [face, xPlane, zPlane]
            # (that put SIDE=Y first and flipped the csys direction). Only when the
            # counts match exactly, else leave the registry empty. (The post-slot index
            # stage that consumed this was removed 2026-07-21; this is now a dead record.)
            if (@($newIds).Count -eq @($plan.Triples).Count) {
                $csysRecords = @()
                for ($k = 0; $k -lt $newIds.Count; $k++) {
                    $tri = $plan.Triples[$k]
                    # GridX/GridZ = the hole's design coordinate (offset from the base
                    # datums). (The coord-export stage that used this was removed 2026-07-21.)
                    $csysRecords += [pscustomobject]@{ PointId = [int]$newIds[$k]; HoleFeatId = $null; PlaneIds = @([int]$xPlaneIds[$tri.Xi], [int]$facePlaneId, [int]$zPlaneIds[$tri.Zi]); GridX = [double]$tri.X; GridZ = [double]$tri.Z }
                }
                Write-Host ("  (index-csys registry: {0} point(s) mapped to their planes, X/Y/Z-normal)" -f @($csysRecords).Count) -ForegroundColor DarkGray
            }
            if ($newIds.Count -eq $orthoGeo.Count) {
                $gridPointIDs = @($newIds)
                Write-Host ("  All {0} datum points created. IDs: {1}" -f $newIds.Count, (($newIds | Select-Object -First 10) -join ", ")) -ForegroundColor Green
            } else {
                Write-Host ("  Point-count MISMATCH: expected {0}, got {1}. Some intersections may have failed." -f $orthoGeo.Count, $newIds.Count) -ForegroundColor Yellow
                if ($newIds.Count -gt 0) { $gridPointIDs = @($newIds) }  # use what we have
                $ok = $false
            }
        }

        if (-not $ok) {
            Write-Host "  Auto point creation had issues. Falling back to manual point selection." -ForegroundColor Yellow
            if ($gridPointIDs.Count -eq 0) {
                $gridPointIDs = @(Invoke-ManualPointGrid -Geo $orthoGeo -Session $session -TypeObj $pfcType)
            }
        }
    }

    if ($gridPointIDs.Count -gt 0) {
        Write-Host ("  Points ready: {0} point(s) for STAGE 3 drilling." -f $gridPointIDs.Count) -ForegroundColor Green
    } else {
        if (-not $canAutoGrid) {
            $gridPointIDs = @(Invoke-ManualPointGrid -Geo $orthoGeo -Session $session -TypeObj $pfcType)
        }
        if ($gridPointIDs.Count -eq 0) {
            Write-Host "  No points captured - STAGE 3 will fall back to a manual selection." -ForegroundColor Yellow
        }
    }
    Write-Host ""

    # Regenerate the model after creating the planes + points so Creo recognizes
    # them as valid hole-placement references. Without this, ProCmdHole may not
    # "see" the just-created datum points (they exist in the feature tree but the
    # model geometry isn't committed). This matches holeinator's assumption that
    # points PRE-EXIST before drilling starts.
    if ($gridPointIDs.Count -gt 0) {
        Write-Host "  Regenerating model (commit all new planes + points before drilling)..." -ForegroundColor DarkGray
        try { $model.Regenerate($null) } catch {}
    }
}

# ============================================================================
# STAGE 3 -- DRILL HOLES (holeinator) at the diameter from STAGE 1
# ============================================================================
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "   STAGE 3 - drill an On-Point hole at every target datum point" -ForegroundColor Cyan
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host ""

# --- STEP 1: target datum points ---
# Prefer the orthogrid grid created in STAGE 2.5 (all NxÂ·Nz points, no pattern);
# otherwise fall back to selecting pre-existing datum points.
$pointIDs = @()
if ($gridPointIDs.Count -gt 0) {
    $pointIDs = @($gridPointIDs)
    Write-Host ("  STEP 1 -- using the {0} orthogrid point id(s) from STAGE 2.5: {1}" -f $pointIDs.Count, (($pointIDs | Select-Object -First 10) -join ", ")) -ForegroundColor Green
} else {
    Write-Host "  STEP 1 -- In Creo, select the target datum points (they already exist" -ForegroundColor Cyan
    Write-Host "           in the part, on another plane), then press ENTER here." -ForegroundColor Cyan
    Read-Host
    $points = ($session.CurrentSelectionBuffer()).Contents
    if ($null -eq $points) { throw "Selection buffer is empty -- no datum points selected in Creo." }

    # Resolve selections into POINT IDs only (never reads .Point coordinates).
    $seen = @{}
    $rejected = @()
    foreach ($item in $points) {
        $si = $null
        try { $si = $item.SelItem } catch { continue }
        if ($null -eq $si) { continue }

        $isPointType = $false
        try { $isPointType = ([int]$si.Type -eq [int]$pfcType.ITEM_POINT) } catch {}

        $subIds = @()
        try {
            foreach ($pt in @($si.ListSubItems($pfcType.ITEM_POINT))) {
                try { $subIds += [int]$pt.Id } catch {}
            }
        } catch {}

        if ($subIds.Count -gt 0) {
            # a feature that contains points -> use the contained point ids
            foreach ($sid in $subIds) {
                if (-not $seen.ContainsKey($sid)) { $seen[$sid] = $true; $pointIDs += $sid }
            }
        } elseif ($isPointType) {
            # the selection IS a datum point -> use its id
            $id = [int]$si.Id
            if (-not $seen.ContainsKey($id)) { $seen[$id] = $true; $pointIDs += $id }
        } else {
            $tname = "?"; $rid = "?"
            try { $rid = [int]$si.Id } catch {}
            try { $tname = [string]$si.Type } catch {}
            $rejected += "id $rid (type $tname)"
        }
    }

    if ($rejected.Count -gt 0) {
        Write-Host ("  Ignored {0} selected item(s) that are neither datum points nor point-bearing features:" -f $rejected.Count) -ForegroundColor Yellow
        foreach ($r in ($rejected | Select-Object -First 10)) { Write-Host "      $r" -ForegroundColor DarkGray }
    }
    if ($pointIDs.Count -eq 0) {
        throw "No datum point ids resolved from the selection. Select datum points (or a datum-point feature) and try again."
    }
    Write-Host ("  Captured {0} target point id(s): {1}" -f $pointIDs.Count, ($pointIDs -join ", ")) -ForegroundColor Green
}

# --- STEP 2: user picks the target body ---
Write-Host ""
Write-Host "  STEP 2 -- Target body." -ForegroundColor Cyan
$bodyList = @()
try { $bodyList = @($model.ListItems($pfcType.ITEM_BODY)) } catch {}

$bodyIndex = 0
# When points were created programmatically (orthogrid or custom) auto-pick body 0
# with no prompt. In manual mode, ask only if >1 body.
if ($gridPointIDs.Count -gt 0) {
    Write-Host "  Body index: 0 (auto, programmatic points)." -ForegroundColor DarkGray
} elseif ($bodyList.Count -gt 1) {
    Write-Host ("  This part has {0} solid bodies:" -f $bodyList.Count) -ForegroundColor White
    for ($i = 0; $i -lt $bodyList.Count; $i++) {
        $bn = try { $bodyList[$i].GetName() } catch { "(unnamed)" }
        Write-Host ("      {0}) {1}" -f $i, $bn) -ForegroundColor White
    }
    Write-Host "  Highlight/verify the body in Creo if unsure, then choose here." -ForegroundColor DarkGray
    while ($true) {
        $raw = Read-Host ("  Enter body index (0-{0}), then ENTER" -f ($bodyList.Count - 1))
        $n = -1
        if ([int]::TryParse($raw, [ref]$n) -and $n -ge 0 -and $n -lt $bodyList.Count) { $bodyIndex = $n; break }
        Write-Host ("  Enter a number between 0 and {0}." -f ($bodyList.Count - 1)) -ForegroundColor Yellow
    }
} elseif ($bodyList.Count -eq 1) {
    Write-Host "  Single-body part -- using body index 0." -ForegroundColor DarkGray
} else {
    Write-Host "  (could not enumerate bodies; defaulting to body index 0)" -ForegroundColor Yellow
}
Write-Host ("  Target body index: {0}" -f $bodyIndex) -ForegroundColor Green

# --- STEP 3: hole diameter, taken from STAGE 1 (in-process, no prompt) ---
# The decision tree's resolved OD IS the hole diameter; use it directly and do
# NOT ask. Only fall back to a manual prompt if the tree produced no diameter
# (e.g. the walk ended without resolving a bushing).
Write-Host ""
Write-Host "  STEP 3 -- Hole diameter." -ForegroundColor Cyan
$holeDiaFinal = 0.0
if ($null -ne $holeDia -and [double]$holeDia -gt 0) {
    $holeDiaFinal = [double]$holeDia
    Write-Host ("  Using the decision-tree diameter: {0}`" (not asked)" -f $holeDiaFinal) -ForegroundColor Green
} else {
    Write-Host "  The decision tree did not resolve a diameter - enter it by hand." -ForegroundColor Yellow
    while ($holeDiaFinal -le 0) {
        $raw = Read-Host "  Enter hole diameter (required)"
        $d = 0.0
        if ([double]::TryParse($raw.Trim(), [ref]$d) -and $d -gt 0) { $holeDiaFinal = $d }
        else { Write-Host "  Enter a positive number." -ForegroundColor Yellow }
    }
    Write-Host ("  Hole diameter: {0}" -f $holeDiaFinal) -ForegroundColor Green
}

# ============================================================================
# STAGE 2b -- AUTO-ROUND THE BOX CORNER EDGES (hands-free, just before drilling)
# ============================================================================
# Right BEFORE the drill confirmation below, round the box corner edges: the
# edges of the LOWEST dimension present (the through-thickness verticals of the
# plate). FULLY AUTOMATIC - no target prompt, no proceed prompt (user, 2026-06-24).
# Mechanism = lib\edge_round.ps1 (Invoke-AutoCornerRound): sweep GetItemById ->
# filter by EvalLength to the smallest length -> CreateModelItemSelection +
# AddSelection -> proven round mapkey. NO find tool (dead on foreign bodies).
# It self-tests selection on one edge and aborts WITHOUT mutating if that fails;
# a VersionStamp canary aborts if the first round changes nothing.
# Override radius with --corner-radius N (default 0.25); --no-corner-round skips.
$cornerRadius = 0.25
$mCr = [regex]::Match($ScriptArgs, '(?i)--corner-radius\s+([0-9]*\.?[0-9]+)')
if ($mCr.Success) { $cornerRadius = [double]$mCr.Groups[1].Value }
if ($ScriptArgs -match '(?i)--no-corner-round') {
    Write-Host "  (--no-corner-round) skipping automatic corner rounding." -ForegroundColor DarkGray
} else {
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "   STAGE 2b - auto-rounding box corner edges (lowest dimension)" -ForegroundColor Cyan
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "  Hands-free: finding the smallest-length edges and rounding them" -ForegroundColor White
    Write-Host "  at radius $cornerRadius." -ForegroundColor White
    $cr = Invoke-AutoCornerRound -Session $session -Model $model -TypeObj $pfcType -Radius $cornerRadius
    Write-Host ("  Found $($cr.Found) edge(s); target length $($cr.Target); matched $($cr.Matched).") -ForegroundColor White
    if ($cr.Matched -gt 0 -and -not $cr.SelfTestOk) {
        Write-Host "  Corner round SKIPPED (safe) - $($cr.Reason)" -ForegroundColor Yellow
    } elseif ($cr.Aborted) {
        Write-Host "  Corner round ABORTED after canary - $($cr.Reason). Inspect Creo." -ForegroundColor Red
    } elseif ($cr.Matched -eq 0) {
        Write-Host "  No corner edges matched - $($cr.Reason). Skipped." -ForegroundColor Yellow
    } elseif ($cr.TotalBatches -gt 0 -and $cr.ModelChanged -eq $cr.TotalBatches) {
        Write-Host "  Rounded $($cr.Matched) corner edge(s) in $($cr.BatchesFired) batch(es) (model changed each)." -ForegroundColor Green
        Write-Host "  NOTE: batches FIRED, not rounds Creo geometrically accepted - verify visually." -ForegroundColor DarkGray
    } else {
        Write-Host "  Corner round finished with issues - $($cr.ModelChanged)/$($cr.TotalBatches) batch(es) changed the model. Inspect Creo." -ForegroundColor Yellow
    }
    Write-Host ""
}

# --- CONFIRM (last stop before mutating the model) ---
Write-Host ""
Write-Host ("  Ready: {0} hole(s), diameter {1}, through all, body index {2}." -f $pointIDs.Count, $holeDiaFinal, $bodyIndex) -ForegroundColor Cyan
Write-Host "  Do not touch Creo while this runs." -ForegroundColor DarkGray
# Programmatic points (orthogrid/custom): auto-proceed (the user committed at the
# GUI; everything after is automatic).
if ($gridPointIDs.Count -gt 0) {
    $go = 'y'
    Write-Host "  Proceeding automatically (points created from the GUI layout)." -ForegroundColor Cyan
} else {
    $go = Read-Host "  Proceed? (y/N)"
}
if ($go -notmatch '^[Yy]$') {
    Write-Host "  Cancelled -- the box was built but no holes were drilled." -ForegroundColor Yellow
} else {
    Write-Host ""

    # --- FIRE -- canary first, then the rest ---
    $total = $pointIDs.Count
    $idx = 0
    $madeHoles = 0
    $noop = 0
    $failed = 0
    $aborted = $false

    # index-csys: ONE feature snapshot BEFORE the drill loop (outside it, so hole
    # creation is untouched). After the loop we diff ONCE and, if the new-feature
    # count matches the hole count exactly, zip sorted-ascending (= creation order)
    # onto $pointIDs to record each point's HoleFeatId. If it doesn't match cleanly
    # (a hole added an axis/note), we skip the tie -- clicking the datum POINT still
    # resolves via the point registry. Only when a registry exists to enrich.
    $beforeDrillFeat = if (@($csysRecords).Count -gt 0) { Get-FeatureIdSet } else { $null }

    foreach ($ptId in $pointIDs) {
        $idx++
        Show-Progress ([Math]::Floor(($idx / $total) * 100)) "Hole $idx/$total"

        # Orthogrid mode: pass the SIDE base datum as the placement surface (the
        # intersection points aren't on a solid face, so Creo needs it explicitly).
        # Pre-select the SIDE OFFSET plane (the box face the points sit on) as the
        # hole placement surface. Point + matching surface -> "On Point" mode.
        $surfId = 0
        if ($gridPointIDs.Count -gt 0 -and $null -ne $sidePlane -and $null -ne $sidePlane.FeatId) {
            $surfId = [int]$sidePlane.FeatId
        }
        $macro = Build-HoleMacro -PointId $ptId -Diameter $holeDiaFinal -BodyIndex $bodyIndex -SurfacePlaneId $surfId
        $changed = $false
        try {
            $stamp = $model.VersionStamp
            $session.RunMacro($macro)
            $changed = Wait-ModelModified -Model $model -PreviousStamp $stamp
        } catch {
            $failed++
        }
        if ($changed) { $madeHoles++ } else { $noop++ }

        # canary: after the FIRST hole, require the model to have changed.
        if ($idx -eq 1 -and -not $changed) {
            Show-Progress 100 "Canary failed"
            Write-Host ""
            Write-Host "  ABORT: the first hole did not modify the model (VersionStamp" -ForegroundColor Red
            Write-Host "  unchanged). Stopped after 1 attempt. Check Creo: did the hole" -ForegroundColor Red
            Write-Host "  dashboard open / error? The recorded widget names may need a" -ForegroundColor Red
            Write-Host "  refresh for this Creo build." -ForegroundColor Red
            $aborted = $true
            break
        }
    }
    if (-not $aborted) { Show-Progress 100 "Done" }

    # index-csys registry: tie holes to points OUTSIDE the loop (one diff), creation-order
    # groups. Resolve-HoleFeatGroups splits the new features into one group per hole (a hole
    # may add an axis/note as well as the hole feature). NOTE: the post-slot index stage that
    # consumed this registry was removed 2026-07-21; this tie now feeds nothing (dead record).
    if ($null -ne $beforeDrillFeat -and -not $aborted -and $madeHoles -gt 0) {
        $afterDrillFeat = Get-FeatureIdSet
        $newDrillFeats  = @($afterDrillFeat.Keys | Where-Object { -not $beforeDrillFeat.ContainsKey($_) } | Sort-Object)
        $grp = Resolve-HoleFeatGroups -NewFeatIds $newDrillFeats -HoleCount @($pointIDs).Count
        if ($grp.Ok) {
            for ($k = 0; $k -lt $pointIDs.Count; $k++) {
                $rec = $csysRecords | Where-Object { $null -ne $_.PointId -and [int]$_.PointId -eq [int]$pointIDs[$k] } | Select-Object -First 1
                if ($null -ne $rec) {
                    $rec.HoleFeatId = [int]$grp.Groups[$k][0]
                    try { $rec | Add-Member -NotePropertyName HoleFeatIds -NotePropertyValue @($grp.Groups[$k]) -Force } catch {}
                }
            }
            $extra = if ($grp.PerHole -gt 1) { (" ({0} features each)" -f $grp.PerHole) } else { "" }
            Write-Host ("  (index-csys: {0} hole(s) tied to their points{1})" -f @($pointIDs).Count, $extra) -ForegroundColor DarkGray
        } else {
            Write-Host ("  (index-csys: hole->point tie skipped -- {0}; click the datum POINT for the index csys)" -f $grp.Reason) -ForegroundColor DarkGray
        }
    }

    Write-Host ""

    # --- REPORT ---
    Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
    Write-Host ("  Points targeted   : {0}" -f $total) -ForegroundColor White
    Write-Host ("  Holes attempted   : {0}" -f $idx) -ForegroundColor White
    Write-Host ("  Model changed     : {0}" -f $madeHoles) -ForegroundColor White
    if ($noop   -gt 0) { Write-Host ("  No-op (no change) : {0}" -f $noop) -ForegroundColor Yellow }
    if ($failed -gt 0) { Write-Host ("  Macro errors      : {0}" -f $failed) -ForegroundColor Yellow }
    Write-Host ""
    if ($aborted) {
        Write-Host "  STOPPED after the canary -- inspect the model in Creo." -ForegroundColor Red
    } elseif ($madeHoles -eq $total -and $failed -eq 0) {
        Write-Host "  Done -- $madeHoles hole(s) created (model changed for each)." -ForegroundColor Green
        Write-Host "  Verify the holes visually in Creo." -ForegroundColor DarkGray
    } else {
        Write-Host "  Finished with issues -- $madeHoles of $total changed the model. Inspect Creo." -ForegroundColor Yellow
    }
}

# ============================================================================
# STAGE 4 -- CHIP-RELIEF SLOTS (rectangular remove-material, one per hole row)
# ============================================================================
# Replaces the old coaxial relief holes + relief paths with the slotinator method:
# ONE blind rectangular slot per hole ROW (length = the part length along the row,
# width = the drilled hole diameter, depth = SLOT_DEPTH_ABS (absolute inches)),
# seed-drawn once then patterned along a base datum plane's normal. Reuses the shared
# engine in lib\drilljig_core.ps1 (Get-RowSlots / Get-SlotPatternPlan /
# Invoke-VerifiedSeedCut / Build-SlotPatternMacro / Build-CutFinishMacro) and ALL the
# context already gathered this run -- the hole diameter ($holeDiaFinal), the bushing
# length ($bushingLen), and hole layout ($orthoGeo) are NOT re-asked. Requires a GUI
# layout (orthogrid/custom); PREDEFINED points carry no row info (we never read point
# coordinates -- the IpfcPoint.Point crash), so slots are skipped there.
#   $SLOT_DEPTH_ABS + the slot flags + the $willSlotRelief decision were resolved UP
#   FRONT (the "chip-relief depth budget" block) so STAGE 2 could pad the plate; here we
#   REUSE $willSlotRelief (no re-ask) and the DEPTH is SLOT_DEPTH_ABS (an ABSOLUTE depth),
#   the SAME value STAGE 2 padded the plate by -- so plate(bushingLen + SLOT_DEPTH_ABS) -
#   slot(SLOT_DEPTH_ABS) = bushingLen exactly.
Write-Host ""
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "   STAGE 4 - chip-relief SLOTS (one rectangular slot per hole row)" -ForegroundColor Cyan
Write-Host "  ====================================================================" -ForegroundColor Cyan

# GATE: the material decision was already made UP FRONT ($willSlotRelief -- 3D print auto,
# metal asked, --no-slot-relief / predefined = no). Reuse it so the operator is not asked
# twice AND so the pad and the cut always agree (a second, different answer here would
# leave the plate padded but uncut, or unpadded but cut).
# $reliefCut tracks whether a relief slot was ACTUALLY cut. The plate is ALREADY padded
# by SLOT_DEPTH_ABS (STAGE 2, up front). If we padded but then never cut a slot (no valid
# rows / SIDE datum missing / seed not confirmed), the full-thickness guide is LEFT TOO
# THICK by exactly the pad -- the inverse of the pre-fix bug. We warn loudly at the end of
# the stage in that case (never silently ship an oversized guide).
$reliefCut = $false
$doSlots = $willSlotRelief
if (-not $doSlots) {
    Write-Host "  Chip-relief slots: not adding (decided up front). The plate was NOT padded." -ForegroundColor DarkGray
} elseif ($null -eq $orthoGeo) {
    # defensive: $willSlotRelief is already false when $orthoGeo is null, so this is unreachable.
    Write-Host "  No grid/custom layout (predefined points) -- chip-relief slots skipped." -ForegroundColor Yellow
    $doSlots = $false
} else {
    Write-Host "  Adding chip-relief slots (decided up front; the plate was padded by the relief depth)." -ForegroundColor Cyan
}

if ($doSlots) {
    # --- rows from the SAME layout the holes came from (NO re-entry) ---
    # $slotRowAxis (resolved up front): 'X' for orthogrid/custom, or the operator's X/Z
    # choice for an imported fastener layout (--slot-dir pins it). CrossAxis + the pattern
    # datum below derive from it, so a 'Z' choice flows through the whole slot build.
    $slots = Get-RowSlots -Points $orthoGeo.Points -SlotWidth $holeDiaFinal -Width $orthoGeo.Width -Height $orthoGeo.Height -RowAxis $slotRowAxis
    if (-not $slots.Valid -or @($slots.Rows).Count -lt 1) {
        Write-Host "  The layout produced no valid slot rows -- skipping chip-relief slots." -ForegroundColor Yellow
        foreach ($er in @($slots.Errors)) { Write-Host "    - $er" -ForegroundColor Yellow }
    } else {
        # --- slot depth = SLOT_DEPTH_ABS (an ABSOLUTE depth, inches): plate is
        # bushingLen + SLOT_DEPTH_ABS (STAGE 2 padded it by this same value), so removing
        # SLOT_DEPTH_ABS leaves exactly bushingLen of full-thickness guide. The depth is a
        # fixed value, NOT derived from the (padded) live SIDE offset. ---
        $slotDepth = [double]$SLOT_DEPTH_ABS
        if ($null -ne $bushingLen -and [double]$bushingLen -gt 0) {
            Write-Host ("  Slot depth = {0}"" (final guide depth = {1}"" after the cut)." -f `
                $slotDepth, [Math]::Round([double]$bushingLen,4)) -ForegroundColor Green
        } else {
            Write-Host ("  Slot depth = {0}"" (bushing length unknown this run -- guide depth not reported)." -f $slotDepth) -ForegroundColor Yellow
        }
        # --- sketch face = the SIDE default datum (the box near face, in BOTH modes:
        # the csys box now also sketches on the SIDE datum). Pattern direction datum
        # from the march axis: CrossAxis Z -> FRONT, X -> TOP ---
        $slotFaceId = if ($null -ne $sidePlane -and $null -ne $sidePlane.BaseId) { [int]$sidePlane.BaseId } else { $null }
        $frontBase = @($made | Where-Object { $_.Label -eq "Front" }); $frontBase = if ($frontBase.Count -gt 0) { $frontBase[0] } else { $null }
        $topBase   = @($made | Where-Object { $_.Label -eq "Top" });   $topBase   = if ($topBase.Count -gt 0) { $topBase[0] } else { $null }
        $dirDatumId = $null; $dirName = $null
        if ($slots.CrossAxis -eq 'Z') { if ($null -ne $frontBase -and $null -ne $frontBase.BaseId) { $dirDatumId = [int]$frontBase.BaseId; $dirName = 'FRONT' } }
        else                          { if ($null -ne $topBase   -and $null -ne $topBase.BaseId)   { $dirDatumId = [int]$topBase.BaseId;   $dirName = 'TOP' } }

        if ($null -eq $slotFaceId) {
            Write-Host "  The SIDE datum was not captured this run -- cannot sketch the slots. Skipping." -ForegroundColor Yellow
        } else {
            $depthNote = if ($slotDepth -gt 0) { "$slotDepth""" } else { "Creo default depth" }
            Write-Host ("  {0} slot row(s), width {1}"" (= hole dia), {2}, sketched on the SIDE face (id {3})." -f @($slots.Rows).Count, $slots.SlotWidth, $depthNote, $slotFaceId) -ForegroundColor Cyan

            $patPlan = Get-SlotPatternPlan -Rows $slots.Rows
            $usePattern = ($patPlan.CanPattern -and -not $slotNoPattern -and @($slots.Rows).Count -ge 2 -and $null -ne $dirDatumId)

            # --- GUIDE PLANES: create + show the slot-edge offset planes (the 2+ datum
            # planes slotinator makes) so the operator draws the seed rectangle to the
            # right size. Pattern mode -> FIRST row's edges only (the seed). Needs the
            # TOP + FRONT bases. Best-effort; freehand if the bases weren't captured. ---
            $slotHasPlanes = $false
            $topBaseIdN   = if ($null -ne $topBase   -and $null -ne $topBase.BaseId)   { [int]$topBase.BaseId }   else { 0 }
            $frontBaseIdN = if ($null -ne $frontBase -and $null -ne $frontBase.BaseId) { [int]$frontBase.BaseId } else { 0 }
            if ($topBaseIdN -gt 0 -and $frontBaseIdN -gt 0) {
                Write-Host "  Creating the slot-edge guide planes (draw references)..." -ForegroundColor Cyan
                $gp = New-SlotGuidePlanes -Rows $slots.Rows -TopBaseId $topBaseIdN -FrontBaseId $frontBaseIdN -UsePattern:$usePattern -Log { param($m) Write-Host $m -ForegroundColor Yellow }
                if (@($gp.Ids).Count -gt 0) { $slotHasPlanes = $true; Write-Host ("  {0} slot-edge guide plane(s) created + shown." -f @($gp.Ids).Count) -ForegroundColor Green }
                else { Write-Host "  No new guide planes needed (edges lie on base datums) - draw freehand." -ForegroundColor DarkGray }
            } else {
                Write-Host "  TOP/FRONT base datums not both captured - skipping guide planes (draw freehand)." -ForegroundColor Yellow
            }

            # --- SEED slot (row 1): draw + verify direction/depth; learn the flip ---
            $seedRow = $slots.Rows[0]
            $seed = Invoke-VerifiedSeedCut -FaceId $slotFaceId -Depth $slotDepth -BodyIndex $bodyIndex `
                -Flip $slotFlip -RowLabel "row 1 (seed)" -DrawInfo @{
                    SlotLen = $seedRow.SlotLen; RowAxis = $slots.RowAxis; SlotWidth = $slots.SlotWidth
                    CrossAxis = $slots.CrossAxis; CrossCoord = $seedRow.CrossCoord; HasPlanes = $slotHasPlanes }

            if (-not $seed.Ok) {
                Write-Host "  The seed slot was not confirmed -- no further slots made. Inspect Creo." -ForegroundColor Yellow
            } elseif ($usePattern) {
                $reliefCut = $true   # the seed row IS a real relief cut; the plate is (at least partly) relieved
                # --- PATTERN the seed to the remaining rows: HANDS-FREE (user 2026-07-23) ---
                # Re-select the seed feature by its captured id ($seed.FeatId) via the
                # edginator-proven raw-COM channel (Select-FeatureById) - NO manual tree
                # click - and fire the pattern. $usePattern already required $dirDatumId.
                # Canary-gated; on a no-change fall back to the manual reselect.
                Write-Host ""
                Write-Host ("  Re-selecting the seed slot (id {0}) and patterning {1} copies at pitch {2:0.####} along {3}, direction = the {4} datum (by ID)..." -f $seed.FeatId, $patPlan.Count, $patPlan.Increment, $slots.CrossAxis, $dirName) -ForegroundColor Cyan
                $pr = Invoke-SlotPatternFromSeed -SeedFeatId ([int]$seed.FeatId) -DirDatumId ([int]$dirDatumId) -Count ([int]$patPlan.Count) -Spacing ([double]$patPlan.Increment) -Flip:$slotPatternFlip
                $patChanged = ($pr.Selected -and $pr.Changed)
                if (-not $patChanged) {
                    Write-Host ("  Auto-reselect did not pattern ({0}). SELECT THE SEED SLOT CUT in Creo's model tree, then press ENTER." -f $pr.Reason) -ForegroundColor Magenta
                    Read-Host
                    $selSeed = Read-SelectedId
                    if ($null -eq $selSeed) {
                        Write-Host "  Nothing selected -- the seed slot IS cut; pattern by hand, or re-run with --no-pattern." -ForegroundColor Yellow
                    } else {
                        $stampP = $null; try { $stampP = $model.VersionStamp } catch {}
                        try {
                            $session.RunMacro((Build-SlotPatternMacro -DirDatumId $dirDatumId -Count ([int]$patPlan.Count) -Spacing ([double]$patPlan.Increment) -Flip:$slotPatternFlip))
                            if ($null -ne $stampP) { $patChanged = Wait-ModelModified -Model $model -PreviousStamp $stampP -TimeoutMs 30000 }
                        } catch { Write-Host "    pattern macro error: $($_.Exception.Message)" -ForegroundColor Red }
                    }
                }
                if ($patChanged) {
                    Write-Host ("  Done -- seed slot patterned to the remaining rows (model changed). {0} slots total, one per" -f $patPlan.Count) -ForegroundColor Green
                    Write-Host ("  row, spaced {0:0.####}. If the copies marched the WRONG way (off the plate), re-run with --pattern-flip." -f $patPlan.Increment) -ForegroundColor DarkGray
                } else {
                    Write-Host "  The pattern did NOT change the model. The seed slot IS cut; finish by hand or re-run with --no-pattern." -ForegroundColor Yellow
                }
            } else {
                # --- PER-ROW: seed is row 1; draw the rest with the confirmed flip ---
                $reliefCut = $true   # the seed row IS a real relief cut; the plate is (at least partly) relieved
                $confirmedFlip = $seed.Flip
                $rowNum = 1; $slMade = 1; $slNoop = 0
                foreach ($row in @($slots.Rows | Select-Object -Skip 1)) {
                    $rowNum++
                    Write-Host ""
                    Write-Host ("  ROW $rowNum of $(@($slots.Rows).Count) ($($slots.CrossAxis)~{0:0.###})" -f $row.CrossCoord) -ForegroundColor Cyan
                    $mkOpenR = (Get-SelectByIdMacro -FeatId $slotFaceId) + "~ Command ``ProCmdFtExtrude``;" + "~ Command ``ProCmdViewSketchView``;" + "~ Command ``ProCmdSketRectangle`` 1;"
                    try { $session.RunMacro($mkOpenR) } catch { Write-Host "    open error: $($_.Exception.Message)" -ForegroundColor Red; continue }
                    Write-Host ("    Draw this row's slot rectangle ({0:0.###} long x {1:0.###} wide), then press ENTER." -f $row.SlotLen, $slots.SlotWidth) -ForegroundColor Magenta
                    if ($slotHasPlanes) {
                        Write-Host "    To snap it: hold CTRL + ALT, click the two planes spanning the LENGTH of the part" -ForegroundColor White
                        Write-Host "    (X direction) and the RIGHT-SIDE EDGE of the jig; dotted blue lines form the rectangle." -ForegroundColor White
                    }
                    Read-Host
                    $stampR = $null; try { $stampR = $model.VersionStamp } catch {}
                    $chgR = $false
                    try { $session.RunMacro((Build-CutFinishMacro -Depth $slotDepth -BodyIndex $bodyIndex -Flip $confirmedFlip)); if ($null -ne $stampR) { $chgR = Wait-ModelModified -Model $model -PreviousStamp $stampR -TimeoutMs 30000 } } catch { Write-Host "    cut error: $($_.Exception.Message)" -ForegroundColor Red }
                    if ($chgR) { $slMade++; Write-Host "    Slot cut (model changed)." -ForegroundColor Green } else { $slNoop++; Write-Host "    No change." -ForegroundColor Yellow }
                }
                Write-Host ""
                Write-Host ("  Done -- {0} of {1} slot(s) cut (per-row). Verify in Creo." -f $slMade, @($slots.Rows).Count) -ForegroundColor $(if ($slNoop -eq 0) { 'Green' } else { 'Yellow' })
            }
        }
    }
}

# HONESTY GUARD (never ship an oversized guide silently): the plate was padded by
# SLOT_DEPTH_ABS UP FRONT so that AFTER the relief slot is cut the guide == bushingLen.
# If relief was intended ($willSlotRelief) but NOTHING was cut (no valid rows / SIDE datum
# missing / seed not confirmed / operator aborted), the guide is now TOO THICK by exactly
# the pad. Warn loudly and tell the operator how to fix it (cut by hand, or re-run without
# relief so the plate = bushingLen).
if ($willSlotRelief -and -not $reliefCut -and $null -ne $bushingLen -and [double]$bushingLen -gt 0) {
    $padAmt = [double]$SLOT_DEPTH_ABS
    Write-Host ""
    Write-Host "  *** WARNING: the plate was PADDED for chip relief that was NOT cut ***" -ForegroundColor Red
    Write-Host ("  The plate is {0}"" thick (bushing {1}"" + {2}"" relief pad), but no relief slot was cut," -f `
        [Math]::Round([double]$bushingLen+$SLOT_DEPTH_ABS,4), [Math]::Round([double]$bushingLen,4), $padAmt) -ForegroundColor Red
    Write-Host ("  so the full-thickness bushing guide is OVERSIZED by {0}"" (it is the padded {1}"", not {2}"")." -f `
        $padAmt, [Math]::Round([double]$bushingLen+$SLOT_DEPTH_ABS,4), [Math]::Round([double]$bushingLen,4)) -ForegroundColor Red
    Write-Host ("  Fix: cut the relief slot(s) by hand ({0}"" deep), OR re-run declining chip relief" -f $padAmt) -ForegroundColor Yellow
    Write-Host "  (--no-slot-relief) so the plate is built at exactly the bushing length." -ForegroundColor Yellow
}

# ============================================================================
# FINAL WORD
# ============================================================================
Write-Host ""
if ($script:macroFailures -eq 0) {
    Write-Host "  Run complete (no mapkey failures)." -ForegroundColor Cyan
} else {
    Write-Host "  Run complete with $($script:macroFailures) mapkey failure(s) - see red lines above." -ForegroundColor Yellow
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
