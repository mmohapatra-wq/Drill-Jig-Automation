# ============================================================================
# lib\curved_gui_steps_compose.ps1 - the INPUT-FIRST composition layer for the
# curved drill jig wizard GUI (drilljig3d-gui.cmd).
# ============================================================================
# Defines ONE global function, Add-CurvedInputFirstSteps -Steps <ArrayList>, that
# builds the full wizard step list in the operator's INPUT-FIRST order:
#
#   Welcome | Fasteners | Surface | Conditions | Build | Slots | Done
#
# It calls the per-stage step-group adders (each still owns its step DEFINITIONS,
# retagged to the new stages) into a temp list, then appends them to $Steps in the
# exact contiguous-stage order the wizard breadcrumb requires (Get-BreadcrumbStates
# spans each stage pill from its steps' min/max index -- so a stage's steps MUST be
# contiguous, and $stages order MUST match this array order).
#
# ORDER (must match the shell's $stages: Welcome/Fasteners/Surface/Conditions/Build/Slots/Done):
#   welcome            (Welcome)
#   fastener-select    (Fasteners)   <- input 1: which fasteners (reused later by Slots)
#   surface-arm        (Surface)     <- input 2: which surface (also defaults FastenerSurfId)
#   tree, chip-clearance, fastener-dia  (Conditions)  <- input 3: bushing + clearance + dia
#                                        (thickness + offset are DERIVED, never typed)
#   build-run              (Build)   <- hands-free batch: blank -> corners -> drill all
#   slot-arm, slot-finish  (Slots)   <- flat-DJ two-step: slot-arm opens the first pocket
#                                        sketch; slot-finish cuts it + re-arms the next
#                                        (return-false loop), the operator drawing between.
#   done                   (Done)
#
# Dot-source AFTER all the curved_gui_steps_* libs it composes. The SHELL and BOTH
# offline harnesses (run_drilljig3d_gui_tests.ps1, fuzz_curved_gui.ps1) call THIS one
# function so the wizard + tests see the identical ordered inventory. NEVER throws on
# a missing step (defensive: appends any leftover not named in the order at the end).
# `function global:` so the .cmd dot-source scope resolves it. ASCII-only.
# ============================================================================

function global:Get-CurvedInputFirstOrder {
    # the canonical input-first step order (keys). Single source of truth for the
    # shell + the tests. Matches the shell's $stages grouping.
    # 2026-07-29: dropped the free-text 'thickness'/'standoff' steps + the 'slot-select'
    # re-pick; 'relief-depth' -> the 'chip-clearance' card (Standard/Custom) that derives
    # the auto thickness. The Slots stage now reuses the fasteners selected up front.
    return @('welcome', 'fastener-select', 'surface-arm',
             'tree', 'chip-clearance', 'fastener-dia',
             'build-run', 'slot-arm', 'slot-finish', 'done')
}

function global:Add-CurvedInputFirstSteps {
    param($Steps)
    # build every step into a temp list via the (retagged) per-stage adders.
    $tmp = New-Object System.Collections.ArrayList
    Add-CurvedBushingSteps      -Steps $tmp   # welcome + tree/thickness/standoff/relief-depth
    Add-CurvedSurfaceSteps      -Steps $tmp   # surface-arm
    Add-CurvedFastenerHoleSteps -Steps $tmp   # fastener-dia + fastener-select
    Add-CurvedBuildSteps        -Steps $tmp   # build-run
    Add-CurvedSlotSteps         -Steps $tmp   # slot-select + slot-loop
    Add-CurvedDoneSteps         -Steps $tmp   # done

    $order = Get-CurvedInputFirstOrder
    $byKey = @{}
    foreach ($s in $tmp) { try { if ($null -ne $s.Key -and -not $byKey.ContainsKey([string]$s.Key)) { $byKey[[string]$s.Key] = $s } } catch {} }

    # append in the canonical order.
    foreach ($k in $order) {
        if ($byKey.ContainsKey($k)) { [void]$Steps.Add($byKey[$k]); [void]$byKey.Remove($k) }
    }
    # defensive: any step NOT named in the order list still gets appended (never lost).
    foreach ($s in $tmp) {
        $k = try { [string]$s.Key } catch { $null }
        if ($null -ne $k -and $byKey.ContainsKey($k)) { [void]$Steps.Add($s); [void]$byKey.Remove($k) }
    }
}
