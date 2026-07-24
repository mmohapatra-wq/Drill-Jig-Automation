# ============================================================================
# lib\jig_tree.ps1 - the drill-jig DECISION-TREE WALK + bushing/hole pick
# ============================================================================
# The pure-console STAGE-1 walk (no Creo, no mapkeys) lifted out of drilljig.cmd
# so BOTH the flat tool (drilljig.cmd, which keeps its own inline copy) and the
# curved tool (drilljig3d.cmd STAGE 0) resolve a hole OD + bushing length through
# the SAME logic. Dot-source AFTER lib\drilljig_core.ps1 (this module calls its
# pure catalog helpers - Get-CatalogSpec, Get-FixedOdSpec, Test-OdFirstSpec,
# Get-OdGroups, Resolve-OdBushingPick, Group-CatalogByID, Get-IdOdOptions,
# Get-BushingLengthOptions, Resolve-BushingPickRow, Resolve-BushingLengthInput,
# Resolve-CustomOdInput, Resolve-CustomOdPick - all defined there):
#     . (Join-Path $ScriptDir 'lib\drilljig_core.ps1')
#     . (Join-Path $ScriptDir 'lib\jig_tree.ps1')
#
# SCOPE NOTE (deliberate): these are PLAIN (non-global) functions so that a
# dot-source lands them in the CONSUMER's script scope - Invoke-Walk writes
# $script:Picks, which must resolve to the consuming .cmd's script scope (the
# same way drilljig.cmd relies on it). A `global:` function would resolve
# $script: to THIS module's scope instead (the GUI-closure scope trap in memory
# project_gui_scope_bugs) - so keep them plain and dot-source, never call across
# a closure boundary.
#
# CONTRACT (matches drilljig.cmd STAGE 1):
#   $script:Picks = [System.Collections.ArrayList]::new()   # caller inits
#   $path     = [System.Collections.ArrayList]::new()
#   $outcomes = [System.Collections.ArrayList]::new()
#   foreach ($root in @($tree)) { if (-not (Invoke-Walk -Node $root -Path $path -Outcomes $outcomes)) { <quit> } }
#   # LAST pick wins as the active hole spec:
#   $active = $script:Picks[$script:Picks.Count - 1]   # .HoleDiameter, .BushingLength, .Bushing, .PartNumber
#
# This file is a faithful MIRROR of drilljig.cmd's STAGE-1 helpers (same
# precedent as jiginator.cmd keeping local catalog copies). drilljig.cmd is left
# untouched; a future dedup can point it here once this module is proven live.
# ============================================================================

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

# Numbered menu with Q-to-quit. Returns the chosen option object or $null on quit.
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
# Returns $true to continue, $false if the user quit. Appends each resolved hole
# spec to $script:Picks (the CONSUMER's script scope - see the SCOPE NOTE above).
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
