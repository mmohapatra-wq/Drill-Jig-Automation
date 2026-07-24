# ============================================================================
# lib\curved_slot_macros.ps1 - COM ORCHESTRATION for the CURVED chip-relief slot
# loop (the Creo-facing companion to the PURE planner lib\curved_slots.ps1)
# ============================================================================
# The CURVED (conformal) drill jig's slot stage cannot use the flat jig's ONE-
# seed-plus-linear-pattern trick: on a curved face every bore normal differs, so
# a single linear pattern cannot replicate one seed slot to arbitrary curved
# positions (established live; no programmatic pattern/copy API for arbitrary
# curved positions). Instead each hole already carries the datum PLANE it was
# intersected through (its SketchPlaneId - the tangent plane at the point, whose
# normal IS the surface normal there), and a sketch CAN be opened on that plane
# fed BY ID with NO screen pick (fact `sketch-open-on-plane-by-id`, PROVEN-LIVE
# 2026-07-24, slotplane-probe.cmd). So the curved loop cuts ONE slot per seed,
# arming each seed's sketch by ID, canary-gated per cut. This is the curved
# analog of drilljig-gui's slot-b PER-ROW fallback (~line 3951).
#
# WHAT THIS FILE ADDS OVER lib\curved_slots.ps1:
#   curved_slots.ps1 is PURE - it turns a per-hole layout into a Get-CurvedSlotPlan
#   result (a list of SEEDS, each naming its SketchPlaneId). This file CONSUMES
#   that plan and drives Creo: arm each seed's sketch by ID, let the operator draw
#   the rectangle, fire the proven Build-CutFinishMacro, and gate each cut on a
#   real VersionStamp change (never "macro fired" == success).
#
# FUNCTIONS:
#   1. Build-CurvedSlotArmMacro -SketchPlaneId     (PURE)  - the atomic arm macro
#      (select the tangent plane by ID + open the sketcher on it + arm the
#      rectangle tool). Token strings COPIED VERBATIM from slotplane-probe.cmd.
#   2. Invoke-CurvedSlotArm     -Seed | -SketchPlaneId    - fire the arm macro for
#      one seed's SketchPlaneId. SketchPlaneId<=0 => NEVER fires.
#   3. Invoke-CurvedSlotCut     -Depth -BodyIndex -Flip   - AFTER the operator drew,
#      fire Build-CutFinishMacro, feature-diff + VersionStamp canary-gated.
#   4. Invoke-CurvedSlotPlanRun -Plan -Depth -BodyIndex   - loop the seeds:
#      Arm -> DrawPrompt pause -> Cut -> (FIRST seed) VerifyPrompt (undo+flip+redraw
#      on 'wrong', reuse the flip) -> advance. Injected DrawPrompt/VerifyPrompt
#      scriptblocks (Read-Host in production, stubs in the offline tests) keep the
#      loop testable without a live console pause.
#
# HARD REPO RULES honored:
#   * PURE builder (Build-CurvedSlotArmMacro) takes only ints and returns a string,
#     so it is offline-unit-testable and NEVER throws on a value.
#   * COM helpers read the one-time core scope ($script:DJSession / $script:DJModel
#     / $script:DJType) set by Initialize-DrilljigCore (drilljig_core.ps1) - the
#     SAME pattern as Invoke-VerifiedSeedCut / Select-FeatureById. This file
#     assumes drilljig_core.ps1 is dot-sourced FIRST (it supplies Get-SelectDatumByIdMacro,
#     Build-CutFinishMacro, Get-FeatureIdSet, Wait-ModelModified, Invoke-Macro).
#   * ONE atomic RunMacro per dashboard (the arm macro; the cut macro) - a
#     dashboard's command context does not survive across RunMacro calls.
#   * A canary that CANNOT be read is a MISS (Changed=$false / Reason set), NEVER
#     assumed success ([[feedback_canary_must_not_assume_on_failure]]).
#   * A seed whose SketchPlaneId<=0 is SKIPPED with a warning - it is NEVER armed
#     and NEVER counted as cut.
#   * ID-only; never reads IpfcPoint.Point.
#   * global: scope on every function so closures resolve them under the hybrid
#     .cmd [scriptblock]::Create model.
#   * Get-SelectDatumByIdMacro is NOT redefined here - it is used from
#     drilljig_core.ps1 (surfenator's proven datum-by-ID feed).
# ============================================================================

# ----------------------------------------------------------------------------
# Build-CurvedSlotArmMacro - PURE. Assemble the atomic macro that arms a seed
# sketch on the tangent datum plane fed BY ID + arms the rectangle tool. This is
# the arm half of the loop; the operator then draws, and Invoke-CurvedSlotCut
# fires the finish (Build-CutFinishMacro).
#
# The token order is COPIED VERBATIM from slotplane-probe.cmd (the proven-live
# by-ID sketch-open arm, fact `sketch-open-on-plane-by-id`):
#     buffer_clean
#   + Get-SelectDatumByIdMacro($PlaneId)   (the DATUM plane by ID, no buffer_clean)
#   + ProCmdDatumSketCurve
#   + t1.PlnMru `0`/`` (select the fed plane from the sketch-plane MRU)
#   + t1.RefMru `0`/`` (select the orientation reference from the MRU)
#   + stdbtn_1          (enter the sketcher)
#   + ProCmdViewSketchView  (orient to the sketch plane, like Invoke-VerifiedSeedCut)
#   + ProCmdSketRectangle 1 (arm the corner-rectangle tool for the operator draw)
# The @PAUSE_FOR_SCREEN_PICK from the generic "open sketcher on a plane" recipe is
# DELIBERATELY OMITTED - the whole point of the by-ID feed is that it replaces the
# manual plane click (proven live). PlaneId<=0 returns the empty string (the caller
# must gate on that - a <=0 plane is a fall-back-to-pick seed, not something to arm).
# ----------------------------------------------------------------------------
function global:Build-CurvedSlotArmMacro {
    # Accept -SketchPlaneId (the field name every seed + caller uses) with -PlaneId as
    # an alias so both names bind to the same value regardless of caller.
    param(
        [Alias('PlaneId')]
        [int]$SketchPlaneId
    )
    if ($SketchPlaneId -le 0) { return "" }
    return "~ Activate ``main_dlg_cur`` ``buffer_clean``;" +
        (Get-SelectDatumByIdMacro -FeatId ([int]$SketchPlaneId)) +
        "~ Command ``ProCmdDatumSketCurve``;" +
        "~ Trigger ``Odui_Dlg_00`` ``t1.PlnMru`` ``0``;" +
        "~ Trigger ``Odui_Dlg_00`` ``t1.PlnMru`` ````;" +
        "~ Trigger ``Odui_Dlg_00`` ``t1.RefMru`` ``0``;" +
        "~ Trigger ``Odui_Dlg_00`` ``t1.RefMru`` ````;" +
        "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;" +
        "~ Command ``ProCmdViewSketchView``;" +
        "~ Command ``ProCmdSketRectangle`` 1;"
}

# ----------------------------------------------------------------------------
# Invoke-CurvedSlotArm - fire the arm macro for ONE seed (a Get-CurvedSlotPlan
# seed: has .SketchPlaneId). Reads the core session scope. Returns
#   @{ Armed=$bool; Reason=<string> }
# A seed with SketchPlaneId<=0 is NEVER fired (Armed=$false + Reason) - the caller
# skips it / falls back to a screen-pick. A macro error is caught, tallied into
# $script:macroFailures (via Invoke-Macro), and reported as Armed=$false. Firing
# the arm macro is a UI action with no VersionStamp change (nothing is committed
# yet - the sketch is only opened), so Armed reflects "the macro ran without a
# COM error", not a model change; the CUT is what the canary gates.
# ----------------------------------------------------------------------------
function global:Invoke-CurvedSlotArm {
    param($Seed)
    $res = @{ Armed = $false; Reason = '' }
    if ($null -eq $Seed) { $res.Reason = 'seed is null'; return $res }

    $planeId = 0
    try { $planeId = [int]$Seed.SketchPlaneId } catch { $planeId = 0 }
    if ($planeId -le 0) {
        $res.Reason = 'seed has no usable SketchPlaneId (<=0) - fall back to a screen-pick for this seed'
        return $res
    }

    $macro = Build-CurvedSlotArmMacro -PlaneId $planeId
    if ([string]::IsNullOrEmpty($macro)) {
        $res.Reason = "arm macro was empty for plane $planeId"
        return $res
    }

    $failBefore = $script:macroFailures
    Invoke-Macro "arm curved seed sketch on plane $planeId (by ID)" $macro
    if ($script:macroFailures -gt $failBefore) {
        $res.Reason = "arm macro raised a COM error (see log)"
        return $res
    }

    $res.Armed  = $true
    $res.Reason = "sketch armed on plane $planeId"
    return $res
}

# ----------------------------------------------------------------------------
# Invoke-CurvedSlotCut - AFTER the operator has drawn the rectangle in the armed
# sketch, finish + cut the slot. Fires Build-CutFinishMacro (drilljig_core.ps1 -
# the SURFACE-AGNOSTIC, proven-live cut: finish sketch -> optional flip -> blind
# depth -> remove_material -> body -> Done) as ONE atomic RunMacro, wrapped in a
# Get-FeatureIdSet before/after diff + a VersionStamp canary. Reads the core scope.
# Returns
#   @{ Changed=$bool; FeatId=<int|null>; Reason=<string> }
# Changed=$true ONLY when the model's VersionStamp actually moved (a real cut).
# Changed=$false on a no-change (rectangle not a closed loop, or widget drift) or a
# macro error - a MISS, never assumed success. FeatId is the newest feature id that
# appeared across the cut (the slot feature, for the caller's records) or $null when
# the diff yields none. -OnPoll is threaded to Wait-ModelModified (a GUI passes a
# DoEvents pump so the window repaints during the regen).
# ----------------------------------------------------------------------------
function global:Invoke-CurvedSlotCut {
    param(
        [double]$Depth,
        [int]$BodyIndex = 0,
        [bool]$Flip = $true,
        [scriptblock]$OnPoll = $null,
        [int]$TimeoutMs = 30000
    )
    $res = @{ Changed = $false; FeatId = $null; Reason = '' }

    $beforeFeat = Get-FeatureIdSet
    $stamp = $null
    try { $stamp = $script:DJModel.VersionStamp } catch {}

    try {
        $macro = Build-CutFinishMacro -Depth ([double]$Depth) -BodyIndex ([int]$BodyIndex) -Flip ([bool]$Flip)
        $script:DJSession.RunMacro($macro)
    } catch {
        $res.Reason = "cut macro error: $($_.Exception.Message)"
        return $res
    }

    if ($null -eq $stamp) {
        # Could not read the baseline stamp -> the canary cannot be evaluated. That
        # is a MISS, not success ([[feedback_canary_must_not_assume_on_failure]]).
        $res.Reason = 'could not read a baseline VersionStamp - cut cannot be verified (treated as a miss)'
        return $res
    }

    $res.Changed = Wait-ModelModified -PreviousStamp $stamp -TimeoutMs $TimeoutMs -OnPoll $OnPoll
    if (-not $res.Changed) {
        $res.Reason = 'the cut did not change the model (rectangle not a closed loop, or widget drift)'
        return $res
    }

    # newest feature id that appeared across the cut (the slot feature).
    $afterFeat = Get-FeatureIdSet
    $newFeats  = @($afterFeat.Keys | Where-Object { -not $beforeFeat.ContainsKey($_) } | Sort-Object)
    $res.FeatId = if ($newFeats.Count -ge 1) { [int]$newFeats[-1] } else { $null }
    $res.Reason = 'slot cut confirmed (VersionStamp changed)'
    return $res
}

# ----------------------------------------------------------------------------
# Invoke-CurvedSlotPlanRun - drive the WHOLE curved slot loop from a
# Get-CurvedSlotPlan result. For each seed:
#   1. Arm the seed sketch on its plane by ID (Invoke-CurvedSlotArm). A seed whose
#      SketchPlaneId<=0 is SKIPPED with a warning and NEVER counted as cut.
#   2. Pause for the operator to draw the rectangle - the injected -DrawPrompt
#      scriptblock (a Read-Host pause in production; a stub in the offline tests).
#   3. Fire the cut (Invoke-CurvedSlotCut), canary-gated on a VersionStamp change.
#   4. On the FIRST seed ONLY, verify the cut DIRECTION with the injected
#      -VerifyPrompt scriptblock (returns $true = correct / $false = wrong). On
#      'wrong': undo (ProCmdEditUndo) + TOGGLE the flip + redraw + re-cut ONCE
#      (there are only two directions). The confirmed flip is then REUSED for every
#      remaining seed, so direction is verified exactly once (like
#      Invoke-VerifiedSeedCut).
#
# The verify happens on the first SUCCESSFULLY-cut seed. If the first seed's cut is
# a MISS (canary did not fire), it is recorded as failed and the verify falls to the
# next seed that cuts, so a fluke first-cut miss does not skip direction verification.
#
# INJECTED PROMPTS (keep the loop offline-testable):
#   -DrawPrompt   scriptblock invoked with the current seed BEFORE the cut. In
#                 production a Read-Host pause ("draw the rectangle, then ENTER").
#                 The tests pass a stub that just returns. Its return value is
#                 ignored (it is a pause, not a decision).
#   -VerifyPrompt scriptblock invoked (first seed only) AFTER a successful cut; must
#                 return $true (direction correct) or $false (wrong -> undo+flip+
#                 redraw). Absent -> the direction is ASSUMED correct (no undo path)
#                 so a purely programmatic caller still completes.
#
# Returns @{ Ok; SeedsCut; SeedsFailed; SeedsSkipped; Flip; Warnings }:
#   Ok           $true when >=1 seed cut AND no seed FAILED its canary (a skipped
#                no-plane seed does not fail Ok - it is an expected fall-back).
#   SeedsCut     count of seeds whose cut canary fired.
#   SeedsFailed  count of seeds that were armed + drawn but whose cut was a MISS.
#   SeedsSkipped count of seeds with SketchPlaneId<=0 (never armed).
#   Flip         the confirmed cut-direction flag reused across the loop.
#   Warnings     one line per skipped / failed / redraw event (human-readable).
# NEVER assumes success on a canary miss; NEVER throws (a null/invalid plan returns
# Ok=$false + a warning).
# ----------------------------------------------------------------------------
function global:Invoke-CurvedSlotPlanRun {
    param(
        $Plan,
        [double]$Depth,
        [int]$BodyIndex = 0,
        [bool]$Flip = $true,
        [scriptblock]$OnPoll = $null,
        [scriptblock]$DrawPrompt = $null,
        [scriptblock]$VerifyPrompt = $null,
        [int]$TimeoutMs = 30000
    )
    $result = @{
        Ok = $false; SeedsCut = 0; SeedsFailed = 0; SeedsSkipped = 0
        Flip = [bool]$Flip; Warnings = @()
    }

    # validate the plan WITHOUT throwing.
    $seeds = @()
    if ($null -eq $Plan) {
        $result.Warnings += "plan is null - nothing to cut"
        return $result
    }
    $planValid = $false
    try { $planValid = [bool]$Plan.Valid } catch { $planValid = $false }
    if (-not $planValid) {
        $result.Warnings += "plan is not Valid - nothing to cut"
        return $result
    }
    try { if ($null -ne $Plan.Seeds) { $seeds = @($Plan.Seeds) } } catch { $seeds = @() }
    if ($seeds.Count -lt 1) {
        $result.Warnings += "plan has no seeds - nothing to cut"
        return $result
    }

    $curFlip = [bool]$Flip
    $directionVerified = $false   # becomes $true once the first successful cut is verified

    $si = 0
    foreach ($seed in $seeds) {
        $si++
        $key = "seed$si"
        try { if ($null -ne $seed.Key) { $key = "$($seed.Key)" } } catch {}

        # ---- 1. arm (never fire on a <=0 plane) --------------------------------
        $arm = Invoke-CurvedSlotArm -Seed $seed
        if (-not $arm.Armed) {
            $planeId = 0
            try { $planeId = [int]$seed.SketchPlaneId } catch { $planeId = 0 }
            if ($planeId -le 0) {
                $result.SeedsSkipped++
                $result.Warnings += "seed '$key' SKIPPED (no usable SketchPlaneId) - screen-pick this seed by hand"
            } else {
                $result.SeedsFailed++
                $result.Warnings += "seed '$key' could not be armed: $($arm.Reason)"
            }
            continue
        }

        # ---- 2. operator draws the rectangle (injected pause) ------------------
        if ($null -ne $DrawPrompt) { try { & $DrawPrompt $seed } catch {} }

        # ---- 3. cut (canary-gated) --------------------------------------------
        $cut = Invoke-CurvedSlotCut -Depth $Depth -BodyIndex $BodyIndex -Flip $curFlip -OnPoll $OnPoll -TimeoutMs $TimeoutMs
        if (-not $cut.Changed) {
            $result.SeedsFailed++
            $result.Warnings += "seed '$key' cut MISS: $($cut.Reason)"
            continue
        }

        # ---- 4. verify DIRECTION on the first successful cut only --------------
        if (-not $directionVerified -and $null -ne $VerifyPrompt) {
            $correct = $true
            try { $correct = [bool](& $VerifyPrompt $seed $curFlip) } catch { $correct = $true }
            if (-not $correct) {
                # undo the wrong cut, flip, redraw + re-cut ONCE (only two directions).
                try { $script:DJSession.RunMacro("~ Command ``ProCmdEditUndo``;") } catch {}
                $result.Warnings += "seed '$key' direction was WRONG - undid, flipped, redrawing"
                $curFlip = -not $curFlip

                # re-arm + redraw + re-cut with the flipped direction.
                $arm2 = Invoke-CurvedSlotArm -Seed $seed
                if (-not $arm2.Armed) {
                    $result.SeedsFailed++
                    $result.Warnings += "seed '$key' could not be RE-armed after the flip: $($arm2.Reason)"
                    continue
                }
                if ($null -ne $DrawPrompt) { try { & $DrawPrompt $seed } catch {} }
                $cut2 = Invoke-CurvedSlotCut -Depth $Depth -BodyIndex $BodyIndex -Flip $curFlip -OnPoll $OnPoll -TimeoutMs $TimeoutMs
                if (-not $cut2.Changed) {
                    $result.SeedsFailed++
                    $result.Warnings += "seed '$key' re-cut MISS after the flip: $($cut2.Reason)"
                    continue
                }
                # the flipped direction cut - accept it and reuse the flip.
            }
            # direction is now settled (either the first cut was correct, or the
            # flipped re-cut succeeded); reuse $curFlip for every remaining seed.
            $directionVerified = $true
        }

        $result.SeedsCut++
        $result.Flip = $curFlip
    }

    $result.Flip = $curFlip
    # Ok = at least one slot cut AND nothing that was armed+drawn failed its canary.
    # A skipped no-plane seed is an EXPECTED fall-back, not a failure.
    $result.Ok = ($result.SeedsCut -ge 1 -and $result.SeedsFailed -eq 0)
    return $result
}
