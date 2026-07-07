# ============================================================================
# lib\orthogrid.ps1 - pure orthogrid plate / point-pattern math for the toolkit
# ============================================================================
# Pure MATH only - no COM, no network, no module-level state. The single source
# of truth for how a plate's extent and its datum-point grid are derived from the
# four user inputs (center-to-center X, center-to-center Z, counts Nx/Nz, edge
# margin). Every piece of the orthogrid flow depends on this EXACT shape, so the
# arithmetic lives in one place and is exercised by the offline unit tests.
#
# Dot-source from a hybrid .cmd after $ScriptDir is set (no connection needed):
#     . (Join-Path $ScriptDir 'lib\orthogrid.ps1')
#
# This file is also loadable in a plain PowerShell host - the offline unit tests
# (lib\tests\run_orthogrid_tests.ps1) dot-source it directly with no Creo present.
#
# CONVENTION (matches creo_geometry.ps1): a function that COMPUTES never throws -
# invalid input returns a result object with Valid=$false and Errors populated,
# best-effort geometry still filled in. A trap from a math helper would kill the
# whole automation run, so degrade loudly-but-gracefully instead.
# ============================================================================

# ----------------------------------------------------------------------------
# Get-OrthogridGeometry - derive plate extent + the datum-point grid from the
# four orthogrid inputs. This is the PUBLIC CONTRACT every consumer binds to.
#
# Inputs:
#   CcX  - center-to-center spacing along the X (cc-X) direction
#   CcZ  - center-to-center spacing along the Z (cc-Z) direction
#   Nx   - number of points along X (>=1)
#   Nz   - number of points along Z (>=1)
#   Edge - edge margin: distance from the plate corner to the first point, and
#          from the last point to the far edge (added on BOTH sides per axis)
#
# Returns a [pscustomobject]:
#   Valid   [bool]      $true iff CcX>0 AND CcZ>0 AND Nx>=1 AND Nz>=1 AND Edge>=0
#   Errors  [string[]]  human-readable reasons when -not Valid (empty when Valid)
#   CcX,CcZ,Edge [double]; Nx,Nz [int]   (echo of the inputs)
#   Width   [double] = (Nx-1)*CcX + 2*Edge   (plate extent along X)
#   Height  [double] = (Nz-1)*CcZ + 2*Edge   (plate extent along Z)
#   Count   [int]    = Nx*Nz
#   Points  [array]  of [pscustomobject]@{ I; J; X; Z }
#                    X = Edge + I*CcX,  Z = Edge + J*CcZ
#                    ordered I outer, J inner; the corner origin is (Edge,Edge)
#                    = the first point.
#
# Single column/row is legal: Nx=1 => Width = 2*Edge and one X coordinate (=Edge)
# because (Nx-1)*CcX = 0. Same for Nz=1.
#
# NEVER throws: bad input returns Valid=$false with Errors, and Width/Height/
# Count/Points still computed best-effort (Points may be @() when a count is < 1).
#
# global: scope so .GetNewClosure() blocks (drilljig-gui's inline orthogrid editor
# recompute) resolve it even when the host runs under & ([scriptblock]::Create(...))
# -- the hybrid .cmd model dot-sources this into a LOCAL scope a closure cannot see.
# Pure + idempotent, so global is safe; bare-name callers still resolve it.
# ----------------------------------------------------------------------------
function global:Get-OrthogridGeometry {
    param(
        [double]$CcX,
        [double]$CcZ,
        [int]$Nx,
        [int]$Nz,
        [double]$Edge,
        # ClearDia = the diameter of the WIDEST feature at each grid site (the
        # chip-relief hole, = hole dia x relief multiplier). The plate must clear
        # that circle at the border, so Edge is measured from the relief-circle
        # EDGE to the plate edge: Width/Height gain ClearDia (a radius on each side)
        # and the points inset by ClearDia/2 to stay centred. Default 0 reproduces
        # the original center-to-edge behaviour (and keeps existing tests green).
        [double]$ClearDia = 0.0
    )

    # -- validate (collect ALL reasons, do not throw) ------------------------
    $errors = @()
    if ($CcX -le 0)      { $errors += "CcX must be > 0 (got $CcX)" }
    if ($CcZ -le 0)      { $errors += "CcZ must be > 0 (got $CcZ)" }
    if ($Nx -lt 1)       { $errors += "Nx must be >= 1 (got $Nx)" }
    if ($Nz -lt 1)       { $errors += "Nz must be >= 1 (got $Nz)" }
    if ($Edge -lt 0)     { $errors += "Edge must be >= 0 (got $Edge)" }
    if ($ClearDia -lt 0) { $errors += "ClearDia must be >= 0 (got $ClearDia)" }
    $valid = ($errors.Count -eq 0)

    # -- plate extent (best-effort even on bad input) ------------------------
    # (Nx-1)*CcX so a single column (Nx=1) gives exactly 2*Edge (+ ClearDia).
    # ClearDia = a full feature diameter = a radius of clearance on EACH border.
    $width  = ($Nx - 1) * $CcX + 2 * $Edge + $ClearDia
    $height = ($Nz - 1) * $CcZ + 2 * $Edge + $ClearDia
    $count  = $Nx * $Nz

    # -- point grid ----------------------------------------------------------
    # Only enumerate when both counts are >= 1; otherwise leave Points empty so a
    # negative/zero count never spins a loop or emits bogus coordinates. Points are
    # CENTERED in the plate: inset = Edge + ClearDia/2, so the margin from the
    # nearest hole center to the plate edge is the same on BOTH sides (= Edge +
    # ClearDia/2). Without the ClearDia/2 shift the pattern is off-center -- the
    # right margin is Edge + ClearDia while the left is just Edge. When ClearDia=0
    # (no clearance) this reduces to the original $Edge inset.
    $inset  = $Edge + $ClearDia / 2.0
    $points = @()
    if ($Nx -ge 1 -and $Nz -ge 1) {
        for ($i = 0; $i -lt $Nx; $i++) {
            for ($j = 0; $j -lt $Nz; $j++) {
                # Build each coordinate on its own line (no comma-literal scalar
                # math) - same op_* on-array trap creo_geometry.ps1 documents.
                $x = $inset + $i * $CcX
                $z = $inset + $j * $CcZ
                $points += [pscustomobject]@{
                    I = $i
                    J = $j
                    X = [double]$x
                    Z = [double]$z
                }
            }
        }
    }

    return [pscustomobject]@{
        Valid    = $valid
        Errors   = [string[]]$errors
        Mode     = 'orthogrid'
        CcX      = [double]$CcX
        CcZ      = [double]$CcZ
        Nx       = [int]$Nx
        Nz       = [int]$Nz
        Edge     = [double]$Edge
        ClearDia = [double]$ClearDia
        Width    = [double]$width
        Height   = [double]$height
        Count    = [int]$count
        Points   = $points
    }
}

# ----------------------------------------------------------------------------
# Get-CustomPointsGeometry - the IRREGULAR-layout sibling of Get-OrthogridGeometry.
# Takes an ARBITRARY list of {X;Z} hole positions (the user typed each one's
# offset from the SIDE-face corner) and returns a result object with the SAME
# SHAPE as Get-OrthogridGeometry, so every drilljig $orthoGeo consumer (STAGE 2
# plate sizing, STAGE 2.5 point creation, STAGE 3/4 drilling) works unchanged.
#
# NO EDGE MARGIN (user 2026-06-25): in this offset-driven mode an edge margin is
# meaningless - every point is already an explicit offset FROM the corner, so the
# plate is sized either EXPLICITLY (the user types overall W x H) or DERIVED from
# the holes (max offset + ClearDia far-side hole clearance). There is no Edge knob.
#
# Inputs:
#   Points          - array of objects each exposing .X and .Z (doubles): the
#                     offset of each hole from the plate corner (the SIDE base
#                     datum), along TOP (X) / FRONT (Z) - same convention as the grid.
#   ClearDia        - widest-feature diameter (chip-relief Ø). In DERIVED sizing it
#                     is the far-side clearance the plate gains past the outermost
#                     hole (Width = maxX + ClearDia). Auto-derived from the hole
#                     size, NOT a user margin. Default 0.
#   WidthOverride   - explicit overall plate WIDTH ($null/<=0 -> derive from holes).
#   HeightOverride  - explicit overall plate HEIGHT ($null/<=0 -> derive).
#   KeepOrigin      - switch. By DEFAULT a point at the origin (0,0 within tol) is
#                     DROPPED (no datum point + no hole is made at the part origin
#                     corner - user 2026-06-25). Pass -KeepOrigin to keep it.
#
# Returns a [pscustomobject] (NEVER throws):
#   Valid       [bool]   $true iff ClearDia>=0 AND >=1 kept point AND every point
#                        has numeric X>=0 / Z>=0 AND (if explicit) the overall
#                        dim is large enough to contain the farthest hole.
#   Errors      [string[]] reasons when -not Valid (empty when Valid)
#   Mode        'custom'
#   WidthMode   'derived' | 'explicit'
#   SkippedOrigin [int]  how many origin (0,0) points were dropped
#   Edge        0.0      (kept for shape-compat with the orthogrid result; UNUSED here)
#   ClearDia    [double] (echo); CcX/CcZ/Nx/Nz set to 0 (not meaningful here)
#   Width/Height [double] explicit override when given, else maxX/maxZ + ClearDia
#   Count       [int]    number of KEPT points (origin excluded by default)
#   Points      [array]  of [pscustomobject]@{ I; J; X; Z } - I running index, J=0,
#                        X/Z echoed; origin excluded by default. Same members the
#                        GUI preview + STAGE 2.5 plane-sharing read.
#
# Datum-anchored plate: because every point is an offset FROM the corner, the near
# plate edges sit at the datum (offset 0) and only the far edges float. Derived
# Width measures corner -> far hole + ClearDia (no near-side margin), matching how
# the box is built (sketch on the SIDE datum, the plate grows toward the offsets).
# global: scope (see Get-OrthogridGeometry note) so closures resolve it under the
# hybrid .cmd scriptblock::Create model. Pure + idempotent.
# ----------------------------------------------------------------------------
function global:Get-CustomPointsGeometry {
    param(
        [array]$Points,
        [double]$ClearDia = 0.0,
        $WidthOverride    = $null,
        $HeightOverride   = $null,
        [switch]$KeepOrigin
    )

    $tol = 1e-6
    $errors = @()
    if ($ClearDia -lt 0) { $errors += "ClearDia must be >= 0 (got $ClearDia)" }

    # resolve the optional explicit overrides (null/<=0 -> derive). Untyped params
    # so $null is distinguishable from 0; coerce defensively without throwing.
    $wOver = $null; $hOver = $null
    try { if ($null -ne $WidthOverride  -and [double]$WidthOverride  -gt 0) { $wOver = [double]$WidthOverride  } } catch {}
    try { if ($null -ne $HeightOverride -and [double]$HeightOverride -gt 0) { $hOver = [double]$HeightOverride } } catch {}
    # WidthMode reflects the WIDTH specifically (per its name) so it is accurate even
    # for a one-axis override; the GUI only ever sends both W+H or neither, so its
    # readout still labels the whole part correctly. HeightMode is the Z companion.
    $widthMode  = if ($null -ne $wOver) { 'explicit' } else { 'derived' }
    $heightMode = if ($null -ne $hOver) { 'explicit' } else { 'derived' }

    # normalise the input into a clean {I;J;X;Z} list; collect per-point problems
    # without throwing on a malformed entry. Origin (0,0) points are dropped unless
    # -KeepOrigin (no hole at the part origin corner).
    $clean = @()
    $maxX  = 0.0
    $maxZ  = 0.0
    $skippedOrigin = 0
    $i = 0
    if ($null -ne $Points) {
        foreach ($pt in $Points) {
            # Explicit null-check BEFORE coercion: [double]$null silently yields 0.0
            # (no throw), so a missing .X/.Y would otherwise pass as (0,0). A legit
            # X=0 has $pt.X -ne $null, so it still passes this gate.
            $x = $null; $z = $null
            try { if ($null -ne $pt.X) { $x = [double]$pt.X } } catch {}
            try { if ($null -ne $pt.Z) { $z = [double]$pt.Z } } catch {}
            if ($null -eq $x -or $null -eq $z) {
                $errors += "point $($i + 1) is missing a numeric X/Z"
                $i++
                continue
            }
            if ($x -lt 0) { $errors += "point $($i + 1) X must be >= 0 (got $x)" }
            if ($z -lt 0) { $errors += "point $($i + 1) Z must be >= 0 (got $z)" }
            # drop the origin point unless explicitly kept (no hole at the part origin).
            if (-not $KeepOrigin -and [math]::Abs($x) -le $tol -and [math]::Abs($z) -le $tol) {
                $skippedOrigin++
                $i++
                continue
            }
            if ($x -gt $maxX) { $maxX = $x }
            if ($z -gt $maxZ) { $maxZ = $z }
            # I is the index AMONG KEPT points (parallel to $clean), so STAGE 2.5
            # never references a dropped origin.
            $clean += [pscustomobject]@{ I = $clean.Count; J = 0; X = [double]$x; Z = [double]$z }
            $i++
        }
    }

    if ($clean.Count -lt 1) { $errors += "need at least one point (origin-only layouts have nothing to drill)" }

    # plate extent: explicit override if given, else derived = farthest hole +
    # ClearDia far-side clearance. Best-effort even when invalid (GUI previews).
    $width  = if ($null -ne $wOver) { $wOver } else { $maxX + $ClearDia }
    $height = if ($null -ne $hOver) { $hOver } else { $maxZ + $ClearDia }

    # an explicit dim must contain the farthest hole's FULL BORE, else the hole
    # would overhang the plate edge. The bore is centred on the datum point and
    # ClearDia is its diameter, so the bore edge sits at maxX + ClearDia/2 -- the
    # plate must reach at least that far. Degrades to maxX when ClearDia = 0.
    $needX = $maxX + ($ClearDia / 2.0)
    $needZ = $maxZ + ($ClearDia / 2.0)
    if ($null -ne $wOver -and $clean.Count -ge 1 -and $wOver -lt ($needX - $tol)) {
        $errors += "part width $wOver is too small: the bore at X=$maxX (dia $ClearDia) needs width >= $needX"
    }
    if ($null -ne $hOver -and $clean.Count -ge 1 -and $hOver -lt ($needZ - $tol)) {
        $errors += "part height $hOver is too small: the bore at Z=$maxZ (dia $ClearDia) needs height >= $needZ"
    }

    $valid = ($errors.Count -eq 0)

    return [pscustomobject]@{
        Valid         = $valid
        Errors        = [string[]]$errors
        Mode          = 'custom'
        WidthMode     = $widthMode
        HeightMode    = $heightMode
        SkippedOrigin = [int]$skippedOrigin
        CcX      = 0.0
        CcZ      = 0.0
        Nx       = 0
        Nz       = 0
        Edge     = 0.0
        ClearDia = [double]$ClearDia
        Width    = [double]$width
        Height   = [double]$height
        Count    = [int]$clean.Count
        Points   = $clean
    }
}

# ----------------------------------------------------------------------------
# Resolve-EdgeAxis - classify which axis a picked plate edge runs along, from its
# LENGTH alone (NO coordinate read - reading IpfcPoint.Point crashes on this build,
# the holeinator lesson). Used by drilljig STAGE 6 (chip-relief paths): the SIDE
# face of the box is Width (X / TOP direction) x Height (Z / FRONT direction), so a
# face-perimeter edge is either Width-long (runs along X) or Height-long (along Z).
#
#   Length  - the picked edge's EvalLength
#   Width   - plate extent along X (= TOP offset)
#   Height  - plate extent along Z (= FRONT offset)
#   Tol     - relative match tolerance (fraction of the matched dim); default 0.20
#
# Returns [pscustomobject]:
#   Axis      'X' (edge runs along Width) or 'Z' (along Height) - the axis whose
#             PITCH PLANES are normal to the edge (so they are the planes to cross).
#   Boundary  'Front' (an X-edge sits at a constant Z, pinned by a FRONT plane) or
#             'Top'   (a Z-edge sits at a constant X, pinned by a TOP plane).
#   DW,DH     |Length-Width|, |Length-Height| (the raw distances).
#   Confident $true iff the nearer dim matches within Tol (rules out a thickness-
#             direction edge whose length matches neither Width nor Height).
#   Reason    short human string for the console.
# Pure: never throws, no COM.
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# Get-HoleBoundingRect - the PURE MATH behind rectpocketinator: given the hole
# CENTERS (the $orthoGeo.Points the operator re-entered) plus a margin, compute
# the rectangular chip-relief pocket that hugs the hole cluster. This is the
# subset-rectangle the user asked for: "a subset rectangle that is extruded down
# into the part where the holes are" - ONE connected relief region over all holes,
# replacing N individual coaxial relief holes / relief paths.
#
# It is PURE (no COM, never throws) because the hole positions come from the grid
# GUI re-entry, NOT from reading IpfcPoint.Point off the model (that read crashes
# on this build - the holeinator lesson). So the bounding box is arithmetic on the
# same {X;Z} coordinates the grid/box were built from, in the SAME plate-corner
# frame (X right / TOP direction, Z up / FRONT direction; origin at the SIDE-face
# corner - matches Draw-AxisGlyph and Get-OrthogridGeometry).
#
# Inputs:
#   Points  - array of objects each exposing numeric .X and .Z (the hole centers).
#             Typically $orthoGeo.Points from Get-OrthogridGeometry /
#             Get-CustomPointsGeometry.
#   Margin  - how far the pocket wall sits OUTSIDE the extreme hole centers, on
#             every side (>=0). The rect spans [minX-Margin, maxX+Margin] x
#             [minZ-Margin, maxZ+Margin]. Default 0.25.
#   Width   - plate extent along X (for the fit check). <=0 disables the check.
#   Height  - plate extent along Z (for the fit check). <=0 disables the check.
#   HoleDia - hole diameter, used ONLY for the advisory "the pocket wall clears the
#             far side of each bore" note (a bore of dia HoleDia centered on the
#             extreme hole reaches HoleDia/2 past the center; a Margin < HoleDia/2
#             means the pocket wall crosses the outer holes' bores). Default 0
#             (skip the advisory). Does NOT change the rectangle.
#
# Returns [pscustomobject] (NEVER throws):
#   Valid    [bool]   $true iff >=1 point with numeric X/Z AND Margin>=0 AND (when
#                     Width/Height>0) the rect fits inside the plate.
#   Errors   [string[]] reasons when -not Valid (empty when Valid)
#   Warnings [string[]] non-fatal advisories (e.g. Margin < HoleDia/2) - do NOT
#                     gate Valid; surfaced to the operator.
#   MinX,MaxX,MinZ,MaxZ [double]  hole-center extremes (bounding box of centers)
#   Margin   [double] echo
#   X0,X1,Z0,Z1 [double]  pocket rectangle corners (center-extremes +/- Margin).
#                     X0=MinX-Margin, X1=MaxX+Margin (clamped to >=0 at the near
#                     edges so a margin never pushes the wall off the datum/plate).
#   RectW,RectH [double]  pocket width/height (= X1-X0, Z1-Z0)
#   CenterX,CenterZ [double]  pocket rectangle center (for a center-rectangle draw)
#   Count    [int]    number of points used
#
# Single point is legal: MinX==MaxX so the rect is 2*Margin square around it.
# global: scope (see Get-OrthogridGeometry note) so closures resolve it. Pure.
# ----------------------------------------------------------------------------
function global:Get-HoleBoundingRect {
    param(
        [array]$Points,
        [double]$Margin  = 0.25,
        [double]$Width   = 0.0,
        [double]$Height  = 0.0,
        [double]$HoleDia = 0.0
    )

    $errors   = @()
    $warnings = @()
    if ($Margin -lt 0) { $errors += "Margin must be >= 0 (got $Margin)" }

    # collect the numeric hole centers; skip malformed entries (report if none survive).
    $xs = @()
    $zs = @()
    if ($null -ne $Points) {
        foreach ($pt in $Points) {
            # explicit null-check before coercion ([double]$null silently -> 0.0).
            $x = $null; $z = $null
            try { if ($null -ne $pt.X) { $x = [double]$pt.X } } catch {}
            try { if ($null -ne $pt.Z) { $z = [double]$pt.Z } } catch {}
            if ($null -eq $x -or $null -eq $z) { continue }
            $xs += $x
            $zs += $z
        }
    }
    $count = $xs.Count
    if ($count -lt 1) { $errors += "need at least one hole point to bound (got none with numeric X/Z)" }

    # bounding box of the hole CENTERS (best-effort even on bad input).
    $minX = 0.0; $maxX = 0.0; $minZ = 0.0; $maxZ = 0.0
    if ($count -ge 1) {
        $minX = ($xs | Measure-Object -Minimum).Minimum
        $maxX = ($xs | Measure-Object -Maximum).Maximum
        $minZ = ($zs | Measure-Object -Minimum).Minimum
        $maxZ = ($zs | Measure-Object -Maximum).Maximum
    }

    # pocket rectangle = center-box expanded by Margin on all sides. Clamp the NEAR
    # edges to >= 0 so a margin can never push the pocket wall off the near datum
    # (the plate near edges sit at coordinate 0 - the box is built from the SIDE
    # datum outward). The far edges are checked against Width/Height below.
    $x0 = $minX - $Margin
    $x1 = $maxX + $Margin
    $z0 = $minZ - $Margin
    $z1 = $maxZ + $Margin
    if ($x0 -lt 0) { $x0 = 0.0 }
    if ($z0 -lt 0) { $z0 = 0.0 }

    $rectW = $x1 - $x0
    $rectH = $z1 - $z0
    $centerX = ($x0 + $x1) / 2.0
    $centerZ = ($z0 + $z1) / 2.0

    # fit check: the pocket must stay inside the plate. Only enforced when the plate
    # dims are known (>0); a small tolerance absorbs float noise.
    $tol = 1e-6
    if ($Width -gt 0 -and $count -ge 1 -and $x1 -gt ($Width + $tol)) {
        $errors += ("pocket right edge $([math]::Round($x1,4)) exceeds plate width $([math]::Round($Width,4)) - reduce the margin")
    }
    if ($Height -gt 0 -and $count -ge 1 -and $z1 -gt ($Height + $tol)) {
        $errors += ("pocket top edge $([math]::Round($z1,4)) exceeds plate height $([math]::Round($Height,4)) - reduce the margin")
    }

    # advisory: if the margin is smaller than a bore radius, the pocket wall crosses
    # the outer holes' bores (the relief would not fully surround those bores). Not
    # fatal - the operator may want exactly the center-to-center bounding box.
    if ($HoleDia -gt 0 -and $count -ge 1 -and $Margin -lt (($HoleDia / 2.0) - $tol)) {
        $warnings += ("margin $([math]::Round($Margin,4)) < hole radius $([math]::Round($HoleDia/2.0,4)) - the pocket wall crosses the outer bores")
    }

    $valid = ($errors.Count -eq 0)

    return [pscustomobject]@{
        Valid    = $valid
        Errors   = [string[]]$errors
        Warnings = [string[]]$warnings
        Count    = [int]$count
        Margin   = [double]$Margin
        MinX     = [double]$minX
        MaxX     = [double]$maxX
        MinZ     = [double]$minZ
        MaxZ     = [double]$maxZ
        X0       = [double]$x0
        X1       = [double]$x1
        Z0       = [double]$z0
        Z1       = [double]$z1
        RectW    = [double]$rectW
        RectH    = [double]$rectH
        CenterX  = [double]$centerX
        CenterZ  = [double]$centerZ
    }
}

# ----------------------------------------------------------------------------
# Get-RowSlots - the PURE MATH behind slotinator: given the hole CENTERS (the
# $orthoGeo.Points the operator re-entered) plus the ORIGINAL hole diameter,
# group the holes into ROWS and return ONE rectangular chip-relief SLOT per row.
# This is the "rectangular extrude cutout, one per hole row" the user asked for -
# replacing the round coaxial relief holes (drilljig STAGE 4) / relief paths
# (STAGE 6) with a slot whose LENGTH = the full part length along the row and
# WIDTH = the ORIGINAL drilled hole diameter (NOT the 1.5x relief multiplier).
#
# It is PURE (no COM, never throws) because the hole positions come from the grid
# GUI re-entry, NOT from reading IpfcPoint.Point off the model (that read crashes
# on this build - the holeinator lesson). Same plate-corner frame as the rest of
# the toolkit: X right = TOP-offset direction / Width, Z up = FRONT-offset
# direction / Height, origin at the SIDE-face corner (matches Draw-AxisGlyph,
# Get-OrthogridGeometry, Get-HoleBoundingRect).
#
# ROW GROUPING - the load-bearing decision. A "row" is a set of holes collinear
# along the row axis, i.e. sharing a CROSS-coordinate. RowAxis='X' (default) =
# rows run left-right along X, so holes GROUP BY Z (CrossAxis='Z'); each orthogrid
# J index is one X-row of Nx holes. RowAxis='Z' swaps them. Grouping is
# single-linkage on the sorted cross-coordinate, splitting when the gap exceeds a
# PHYSICAL RowTol - NEVER the 1e-6 float-equality guard Get-SharedPlanePlan uses:
# on a clean grid rows land on bit-identical cross-coords, but a CUSTOM layout
# with near-but-not-equal values would fragment one intended row into N single-
# hole full-width slots (a silent over-cut - all N cuts fire, so the VersionStamp
# honesty bar can't catch it). RowTol=0 auto-resolves to max(SlotWidth/4, 0.01);
# the EFFECTIVE value is echoed. Each slot is centred on the MEAN cross-coord of
# its group (not the first point), so single-linkage jitter can't bias the band.
#
# Inputs:
#   Points     - array of objects each exposing numeric .X and .Z (hole centers).
#                Typically $orthoGeo.Points (custom mode has already dropped the
#                origin and re-indexed, so no phantom slot appears at the corner).
#   SlotWidth  - the slot's cross-axis WIDTH = the ORIGINAL hole diameter (>0).
#                NOT holeDia * RELIEF_DIA_MULT. Fatal if <= 0.
#   Width      - plate extent along X (slot LENGTH in 'full' mode when RowAxis='X';
#                cross-fit plate dim when RowAxis='Z'). <=0 handled gracefully.
#   Height     - plate extent along Z (analogous). <=0 disables that axis' checks,
#                same convention as Get-HoleBoundingRect.
#   RowAxis    - 'X' (default) rows run along X / group by Z; 'Z' the swap. A bad
#                string is reported in Errors and defaults to 'X' (NO [ValidateSet]
#                - that throws, breaking the file-wide never-throws contract).
#   LengthMode - 'full' (default) slot spans the whole plate along the row axis;
#                'holes' spans the row's own hole extent +/- Margin. Bad string ->
#                Errors + default 'full'.
#   Margin     - end margin for 'holes' mode (and the 'full'-with-unknown-plate
#                fallback). >= 0; fatal if < 0.
#   RowTol     - PHYSICAL row-grouping distance. 0 -> auto max(SlotWidth/4, 0.01).
#   StrictNoOverlap - switch. By default overlapping adjacent slots are a non-fatal
#                Warning (the union of relief regions is a legal operator intent);
#                this flag promotes overlap to a fatal Error.
#
# Returns [pscustomobject] (NEVER throws):
#   Valid    [bool]   $true iff >=1 numeric point AND SlotWidth>0 AND Margin>=0 AND
#                     no far-edge cross-spill AND (StrictNoOverlap => no overlap)
#                     AND RowAxis/LengthMode were valid strings.
#   Errors   [string[]] fatal reasons (empty when Valid)
#   Warnings [string[]] non-fatal advisories (overlap, near-edge clamp, crooked
#                     row, slot-spans-beyond-holes, coincident points, plate-dim
#                     fallback) - never gate Valid.
#   RowAxis, CrossAxis, LengthMode, SlotWidth, Margin, RowTolEffective, Width,
#            Height  - echoes / derived.
#   Count    [int]    number of rows = number of slots
#   PointCount [int]  clean points grouped
#   Rows     [array]  one per row, ascending cross-coord (see per-row members below)
#   Corners  [array]  flat list of every row's 2 diagonal corners as {X;Z} in the
#                     plate frame - feed straight into Get-SharedPlanePlan so slots
#                     sharing an edge (all 'full' slots share X0/X1) reuse planes.
#
# Per-row object:
#   Index, CrossCoord (MEAN), CrossLo = max(0, mean - SlotWidth/2), CrossHi =
#   mean + SlotWidth/2, AlongMin, AlongMax (0..alongPlate in 'full'; holeSpan+/-
#   Margin clamped in 'holes'), SlotLen = AlongMax-AlongMin, SlotWidth, HoleCount,
#   HoleAlongMin, HoleAlongMax, CenterX, CenterZ (rect center for a center-rect
#   draw), Corner0 {X;Z} = (AlongMin,CrossLo) mapped, Corner1 {X;Z} =
#   (AlongMax,CrossHi) mapped.
#
# global: scope (see Get-OrthogridGeometry note) so closures resolve it. Pure.
# ----------------------------------------------------------------------------
function global:Get-RowSlots {
    param(
        [array]$Points,
        [double]$SlotWidth = 0.0,
        [double]$Width     = 0.0,
        [double]$Height    = 0.0,
        [string]$RowAxis   = 'X',
        [string]$LengthMode= 'full',
        [double]$Margin    = 0.25,
        [double]$RowTol    = 0.0,
        [switch]$StrictNoOverlap
    )

    $tol      = 1e-6
    $errors   = @()
    $warnings = @()

    # -- normalise RowAxis / LengthMode WITHOUT [ValidateSet] (which throws) ----
    $ra = 'X'
    try { $ra = ("$RowAxis").Trim().ToUpper() } catch { $ra = 'X' }
    if ($ra -ne 'X' -and $ra -ne 'Z') { $errors += "RowAxis must be 'X' or 'Z' (got '$RowAxis'); defaulting to 'X'"; $ra = 'X' }
    $lm = 'full'
    try { $lm = ("$LengthMode").Trim().ToLower() } catch { $lm = 'full' }
    if ($lm -ne 'full' -and $lm -ne 'holes') { $errors += "LengthMode must be 'full' or 'holes' (got '$LengthMode'); defaulting to 'full'"; $lm = 'full' }

    $crossAxis = if ($ra -eq 'X') { 'Z' } else { 'X' }
    # the plate extent along the row (slot length in 'full') and across it (fit check)
    $alongPlate = if ($ra -eq 'X') { $Width } else { $Height }
    $crossPlate = if ($ra -eq 'X') { $Height } else { $Width }

    if ($SlotWidth -le 0) { $errors += "SlotWidth must be > 0 (got $SlotWidth)" }
    if ($Margin    -lt 0) { $errors += "Margin must be >= 0 (got $Margin)" }

    # effective physical row-grouping tolerance (NEVER 1e-6). Auto = SlotWidth/4
    # floored at 0.01; a caller-supplied positive RowTol wins.
    $rowTolEff = if ($RowTol -gt 0) { $RowTol } else { [math]::Max($SlotWidth / 4.0, 0.01) }

    # -- collect clean points as {Along; Cross; X; Z}; skip malformed -----------
    # explicit null-check BEFORE [double] coercion ([double]$null silently -> 0.0).
    $pts = @()
    $dupKeys = @{}
    $sawDup = $false
    if ($null -ne $Points) {
        foreach ($p in $Points) {
            $x = $null; $z = $null
            try { if ($null -ne $p.X) { $x = [double]$p.X } } catch {}
            try { if ($null -ne $p.Z) { $z = [double]$p.Z } } catch {}
            if ($null -eq $x -or $null -eq $z) { continue }
            $along = if ($ra -eq 'X') { $x } else { $z }
            $cross = if ($ra -eq 'X') { $z } else { $x }
            $pts += [pscustomobject]@{ Along = [double]$along; Cross = [double]$cross; X = [double]$x; Z = [double]$z }
            $k = ("{0:F6}|{1:F6}" -f $x, $z)
            if ($dupKeys.ContainsKey($k)) { $sawDup = $true } else { $dupKeys[$k] = $true }
        }
    }
    $pointCount = $pts.Count
    if ($pointCount -lt 1) { $errors += "need at least one hole point (got none with numeric X/Z)" }
    if ($sawDup) { $warnings += "coincident duplicate hole points present - they group into one row (no double slot)" }

    # -- single-linkage grouping on the sorted CROSS coordinate -----------------
    # sort ascending, start a new row when the gap to the previous point exceeds
    # the PHYSICAL rowTolEff (chaining), reusing Get-SharedPlanePlan's proven
    # sort-then-adjacent-compare shape but with a physical distance, never 1e-6.
    $groups = @()
    if ($pointCount -ge 1) {
        $sorted = @($pts | Sort-Object Cross)
        $cur = @()
        $prev = $null
        foreach ($p in $sorted) {
            if ($cur.Count -eq 0) { $cur = @($p); $prev = [double]$p.Cross; continue }
            if ([math]::Abs([double]$p.Cross - $prev) -gt $rowTolEff) {
                $groups += ,@($cur)
                $cur = @($p)
            } else {
                $cur += $p
            }
            $prev = [double]$p.Cross
        }
        if ($cur.Count -gt 0) { $groups += ,@($cur) }
    }

    # 'full' mode needs the along-plate extent; if unknown (<=0), fall back to the
    # per-row hole span +/- Margin so we never emit a zero/negative-length slot.
    $lmEff = $lm
    if ($lm -eq 'full' -and $alongPlate -le 0) {
        $warnings += "LengthMode='full' but the along-plate dimension is <= 0 - falling back to the per-row hole span +/- margin"
        $lmEff = 'holes'
    }

    # -- build one slot per row -------------------------------------------------
    $rows    = @()
    $corners = @()
    $idx = 0
    foreach ($g in $groups) {
        $crossVals = @($g | ForEach-Object { [double]$_.Cross })
        $mean = ($crossVals | Measure-Object -Average).Average
        $crossLo = $mean - $SlotWidth / 2.0
        $crossHi = $mean + $SlotWidth / 2.0
        if ($crossLo -lt 0) { $crossLo = 0.0; $warnings += "row $idx (${crossAxis}~$([math]::Round($mean,4))) near edge clamped to 0" }

        # far-edge cross spill = off-part cut -> fatal by default
        if ($crossPlate -gt 0 -and $crossHi -gt ($crossPlate + $tol)) {
            $errors += "row $idx slot cross edge $([math]::Round($crossHi,4)) exceeds plate $crossAxis extent $([math]::Round($crossPlate,4)) - would cut off the part"
        }

        $alongVals = @($g | ForEach-Object { [double]$_.Along })
        $holeAlongMin = ($alongVals | Measure-Object -Minimum).Minimum
        $holeAlongMax = ($alongVals | Measure-Object -Maximum).Maximum

        if ($lmEff -eq 'full') {
            $alongMin = 0.0
            $alongMax = [double]$alongPlate
        } else {
            $alongMin = $holeAlongMin - $Margin
            $alongMax = $holeAlongMax + $Margin
            if ($alongMin -lt 0) { $alongMin = 0.0 }
            if ($alongPlate -gt 0 -and $alongMax -gt $alongPlate) { $alongMax = [double]$alongPlate }
        }

        # within-row jitter: a hole center farther than the band half-width from the
        # mean sits outside its own slot -> the row is too crooked for one straight slot.
        $jit = 0.0
        foreach ($cv in $crossVals) { $d = [math]::Abs($cv - $mean); if ($d -gt $jit) { $jit = $d } }
        if ($jit -gt ($SlotWidth / 2.0 + $tol)) {
            $warnings += "row $idx too crooked: cross jitter $([math]::Round($jit,4)) > half the slot width - some holes fall outside the band"
        }

        # slot spans well beyond the holes in this row (full mode only, informational)
        if ($lmEff -eq 'full' -and $alongPlate -gt 0) {
            $holeSpan = $holeAlongMax - $holeAlongMin
            if ($holeSpan -lt ($alongPlate / 2.0)) {
                $warnings += "row $idx holes span only $([math]::Round($holeSpan,4)) of the $([math]::Round($alongPlate,4)) plate length - the full-length slot removes material well beyond the holes"
            }
        }

        # map (along, cross) -> plate-frame {X;Z} corners (diagonal)
        if ($ra -eq 'X') {
            $c0 = [pscustomobject]@{ X = [double]$alongMin; Z = [double]$crossLo }
            $c1 = [pscustomobject]@{ X = [double]$alongMax; Z = [double]$crossHi }
            $centerX = ($alongMin + $alongMax) / 2.0
            $centerZ = ($crossLo + $crossHi) / 2.0
        } else {
            $c0 = [pscustomobject]@{ X = [double]$crossLo; Z = [double]$alongMin }
            $c1 = [pscustomobject]@{ X = [double]$crossHi; Z = [double]$alongMax }
            $centerX = ($crossLo + $crossHi) / 2.0
            $centerZ = ($alongMin + $alongMax) / 2.0
        }

        $rows += [pscustomobject]@{
            Index        = [int]$idx
            CrossCoord   = [double]$mean
            CrossLo      = [double]$crossLo
            CrossHi      = [double]$crossHi
            AlongMin     = [double]$alongMin
            AlongMax     = [double]$alongMax
            SlotLen      = [double]($alongMax - $alongMin)
            SlotWidth    = [double]$SlotWidth
            HoleCount    = [int]$g.Count
            HoleAlongMin = [double]$holeAlongMin
            HoleAlongMax = [double]$holeAlongMax
            CenterX      = [double]$centerX
            CenterZ      = [double]$centerZ
            Corner0      = $c0
            Corner1      = $c1
        }
        $corners += $c0
        $corners += $c1
        $idx++
    }

    # -- adjacent-row overlap check (rows are ascending in cross) ---------------
    # band i overlaps band i+1 when CrossHi_i > CrossLo_{i+1}. Non-fatal Warning by
    # default (union of relief is legal); StrictNoOverlap promotes it to an Error.
    for ($r = 0; $r -lt ($rows.Count - 1); $r++) {
        if ([double]$rows[$r].CrossHi -gt ([double]$rows[$r + 1].CrossLo + $tol)) {
            $msg = "rows $r ($crossAxis~$([math]::Round($rows[$r].CrossCoord,4))) and $($r+1) ($crossAxis~$([math]::Round($rows[$r+1].CrossCoord,4))) slots overlap (spacing < slot width)"
            if ($StrictNoOverlap) { $errors += $msg } else { $warnings += "$msg - the relief regions will merge" }
        }
    }

    $valid = ($errors.Count -eq 0)

    return [pscustomobject]@{
        Valid           = $valid
        Errors          = [string[]]$errors
        Warnings        = [string[]]$warnings
        RowAxis         = [string]$ra
        CrossAxis       = [string]$crossAxis
        LengthMode      = [string]$lmEff
        SlotWidth       = [double]$SlotWidth
        Margin          = [double]$Margin
        RowTolEffective = [double]$rowTolEff
        Width           = [double]$Width
        Height          = [double]$Height
        Count           = [int]$rows.Count
        PointCount      = [int]$pointCount
        Rows            = @($rows)
        Corners         = @($corners)
    }
}

# ----------------------------------------------------------------------------
# Get-SlotPatternPlan - decide whether the row slots can be made by ONE native
# Creo DIMENSION PATTERN (draw one seed slot, pattern it N-1 more times) instead
# of drawing a rectangle per row. A dimension pattern advances a single dimension
# by a CONSTANT increment, so it can only reproduce EVENLY-SPACED rows. This pure
# helper answers "can we pattern, and with what count + increment?" from the row
# cross-coordinates - no COM, never throws.
#
# WHY it matters: slotinator's row slots come from Get-RowSlots. For a regular
# orthogrid the rows sit at a constant pitch (CcZ) -> a dimension pattern of
# count = #rows, increment = pitch makes them all from one seed. For an IRREGULAR
# custom layout the row gaps differ -> a single-increment pattern CANNOT reproduce
# them, so the caller must fall back to per-row cuts. This helper draws that line
# deterministically (and is exercised offline), so the live tool never tries a
# pattern that can't fit the layout.
#
# Inputs:
#   Rows  - the Get-RowSlots .Rows array (each exposes numeric .CrossCoord), OR any
#           array of objects with a numeric .CrossCoord. Malformed entries skipped.
#   Tol   - two consecutive gaps are "equal" when they differ by <= Tol (absolute,
#           inches). Default 1e-4. Orthogrid pitches are exact so any small tol
#           works; a custom layout's differing gaps exceed it and flag irregular.
#
# Returns [pscustomobject] (NEVER throws):
#   Valid        [bool]   $true iff >=1 row with a numeric CrossCoord
#   CanPattern   [bool]   $true iff >=2 rows AND evenly spaced within Tol
#   Count        [int]    number of rows = pattern instance count (0 if none)
#   Increment    [double] the common row-to-row cross gap (0 if <2 rows / irregular)
#   EvenlySpaced [bool]   were all consecutive gaps equal within Tol
#   Tol          [double] echo of the effective tolerance
#   Spacings     [double[]] the sorted consecutive gaps (for the console report)
#   Reason       [string] short human-readable explanation
# global: scope (see Get-OrthogridGeometry note) so closures resolve it. Pure.
# ----------------------------------------------------------------------------
function global:Get-SlotPatternPlan {
    param(
        [array]$Rows,
        [double]$Tol = 1e-4
    )

    # collect numeric cross-coordinates; skip malformed rows (explicit null-check
    # before coercion - the [double]$null -> 0.0 trap).
    $cs = @()
    if ($null -ne $Rows) {
        foreach ($r in $Rows) {
            $c = $null
            try { if ($null -ne $r.CrossCoord) { $c = [double]$r.CrossCoord } } catch {}
            if ($null -ne $c) { $cs += $c }
        }
    }
    $cs = @($cs | Sort-Object)
    $n  = $cs.Count

    if ($n -lt 1) {
        return [pscustomobject]@{
            Valid = $false; CanPattern = $false; Count = 0; Increment = 0.0
            EvenlySpaced = $false; Tol = [double]$Tol; Spacings = @()
            Reason = "no rows with a numeric CrossCoord"
        }
    }
    if ($n -eq 1) {
        return [pscustomobject]@{
            Valid = $true; CanPattern = $false; Count = 1; Increment = 0.0
            EvenlySpaced = $true; Tol = [double]$Tol; Spacings = @()
            Reason = "only one row - nothing to pattern (draw the single slot)"
        }
    }

    # consecutive gaps between sorted cross-coords
    $gaps = @()
    for ($i = 1; $i -lt $n; $i++) { $gaps += ([double]$cs[$i] - [double]$cs[$i - 1]) }
    $meanGap = ($gaps | Measure-Object -Average).Average

    # evenly spaced iff every gap is within Tol of the mean gap
    $even = $true
    foreach ($g in $gaps) { if ([math]::Abs([double]$g - [double]$meanGap) -gt $Tol) { $even = $false; break } }

    if ($even) {
        return [pscustomobject]@{
            Valid = $true; CanPattern = $true; Count = [int]$n; Increment = [double]$meanGap
            EvenlySpaced = $true; Tol = [double]$Tol; Spacings = @($gaps)
            Reason = ("{0} rows evenly spaced at pitch {1:0.####} - one dimension pattern of {0} fits" -f $n, $meanGap)
        }
    }
    return [pscustomobject]@{
        Valid = $true; CanPattern = $false; Count = [int]$n; Increment = 0.0
        EvenlySpaced = $false; Tol = [double]$Tol; Spacings = @($gaps)
        Reason = ("{0} rows are NOT evenly spaced (gaps vary) - a single-increment pattern can't fit; cut per-row" -f $n)
    }
}

function Resolve-EdgeAxis {
    param([double]$Length, [double]$Width, [double]$Height, [double]$Tol = 0.20)
    $dw = [math]::Abs($Length - $Width)
    $dh = [math]::Abs($Length - $Height)
    if ($dw -le $dh) {
        $axis = 'X'; $boundary = 'Front'; $near = $Width; $nearD = $dw; $nearName = 'Width'
    } else {
        $axis = 'Z'; $boundary = 'Top';   $near = $Height; $nearD = $dh; $nearName = 'Height'
    }
    $rel = if ($near -gt 0) { $nearD / $near } else { 1.0 }
    $confident = ($rel -le $Tol)
    if ($confident) {
        $reason = "length {0:0.###} ~ {1} ({2:0.###}) -> runs along {3}" -f $Length, $nearName, $near, $axis
    } else {
        $reason = "length {0:0.###} matches neither Width ({1:0.###}) nor Height ({2:0.###}) well (maybe a thickness edge)" -f $Length, $Width, $Height
    }
    return [pscustomobject]@{
        Axis      = $axis
        Boundary  = $boundary
        DW        = [double]$dw
        DH        = [double]$dh
        Confident = [bool]$confident
        Reason    = [string]$reason
    }
}
