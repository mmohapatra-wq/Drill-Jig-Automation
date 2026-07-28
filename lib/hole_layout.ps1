# ============================================================================
# lib\hole_layout.ps1 - PURE hole-layout ANALYSIS + a STANDALONE handoff file
# ============================================================================
# Pure MATH + file I/O only - no COM, no network, no module-level state. This is
# the SAFE, offline half of holelayoutinator.cmd (the new standalone "read the
# drilled holes as a jig layout reference" tool). It takes a projected 2D {X;Z}
# layout (produced live by the existing ConvertTo-LayoutXZ, dot-sourced READ-ONLY
# from lib\fastener_layout.ps1) and (a) analyses the hole pattern (spacing,
# nearest-neighbour, bounding box) into a printable report, and (b) persists it to
# a SEPARATE handoff file, hole_layout.json.
#
# ISOLATION CONTRACT (user 2026-07-24): this file is NEW and is dot-sourced ONLY by
# holelayoutinator.cmd + its offline tests. NOTHING that drilljig-gui.cmd needs
# dot-sources it, and it dot-sources NOTHING itself, so it cannot change the
# behavior of drilljig-gui / drilljig / fastenator or any shared lib. Every public
# name here is UNIQUE (Get-HoleLayoutStats / Format-HoleLayoutReport /
# Write-HoleLayout / Read-HoleLayout) so that even if a future tool loads this
# ALONGSIDE fastener_layout.ps1, no function is shadowed. The handoff file is
# hole_layout.json, NOT fastener_layout.json - the fastener workflow is untouched.
#
# CONVENTION (matches orthogrid.ps1 / fastener_layout.ps1): a COMPUTE function never
# throws - bad input returns a result object with Valid=$false + Errors, best-effort
# fields still filled. A trap from a math helper would kill the automation run.
#
# FRAME: the layout is a plate-corner frame - X runs right, Z runs up, origin at the
# corner (identical to Get-CustomPointsGeometry / ConvertTo-LayoutXZ output), so a
# {X;Z} list from ConvertTo-LayoutXZ feeds straight in.
# ============================================================================

# ----------------------------------------------------------------------------
# Get-HoleLayoutStats - analyse a projected {X;Z} hole set into report-ready
# numbers. PURE, NEVER throws. This is the "increased functionality" the plain
# read didn't have: it tells the operator whether the read looks sane BEFORE it is
# trusted (min hole-to-hole spacing, nearest-neighbour pairs, bounding box, whether
# any two holes are closer than a given bit/bore diameter).
#
# Inputs:
#   Points   - array of objects each exposing numeric .X and .Z (ConvertTo-LayoutXZ
#              output, or a Read-HoleLayout result). Non-numeric entries are skipped.
#   HoleDia  - optional (default 0 = OFF). When > 0, any pair closer (center-to-
#              center) than HoleDia is reported as a COLLISION (bores would overlap);
#              tangent (== HoleDia) is allowed (matches Get-OrthogridGeometry's rule).
#
# Returns [pscustomobject] (NEVER throws):
#   Valid       [bool]      $true iff >= 1 numeric point AND HoleDia >= 0
#   Errors      [string[]]
#   Count       [int]       kept points
#   Skipped     [int]       non-numeric points dropped
#   MinX/MaxX/MinZ/MaxZ [double]   bounding box (0 when Count 0)
#   Width/Height        [double]   MaxX-MinX / MaxZ-MinZ
#   MinSpacing  [double]    smallest center-to-center distance (0 for < 2 holes)
#   MaxSpacing  [double]    largest center-to-center distance (0 for < 2 holes)
#   NearestPair [pscustomobject|$null]  @{ A; B; Dist } indices of the closest pair
#   Collisions  [array]     @{ A; B; Dist } pairs closer than HoleDia (empty if OFF)
#   HoleDia     [double]    echo
# ----------------------------------------------------------------------------
# Get-ComposedRootPoint - PURE. Compose a bore's MEMBER-frame axis origin with a
# component's member->root transform into the ROOT (assembly) coordinate:
#     root = O + Bx*m0 + By*m1 + Bz*m2        (B's columns are the X/Y/Z axes)
# This is the "relative math off the coordinate system" for a hole that lives in a
# component of an assembly. NEVER throws - any null/non-finite input -> $null.
#   Member  - the bore axis origin in the component's local frame @(x,y,z).
#   O       - the component transform origin (member->root) @(x,y,z).
#   Bx/By/Bz- the transform basis axes (columns) @(x,y,z) each.
# Returns @(x,y,z) or $null.
# ----------------------------------------------------------------------------
function global:Get-ComposedRootPoint {
    param($Member, $O, $Bx, $By, $Bz)
    foreach ($v in @($Member, $O, $Bx, $By, $Bz)) {
        if ($null -eq $v) { return $null }
        for ($i = 0; $i -lt 3; $i++) {
            $c = $null
            try { $c = [double]$v[$i] } catch { return $null }
            if ($null -eq $c -or [double]::IsNaN($c) -or [double]::IsInfinity($c)) { return $null }
        }
    }
    $m0 = [double]$Member[0]; $m1 = [double]$Member[1]; $m2 = [double]$Member[2]
    $r0 = [double]$O[0] + [double]$Bx[0]*$m0 + [double]$By[0]*$m1 + [double]$Bz[0]*$m2
    $r1 = [double]$O[1] + [double]$Bx[1]*$m0 + [double]$By[1]*$m1 + [double]$Bz[1]*$m2
    $r2 = [double]$O[2] + [double]$Bx[2]*$m0 + [double]$By[2]*$m1 + [double]$Bz[2]*$m2
    return @($r0, $r1, $r2)
}

# ----------------------------------------------------------------------------
# Get-DistinctPointCount - PURE. How many UNIQUE 3D points are in a list, by a
# rounded key (default 3 decimals). $null entries are ignored. Used to decide which
# candidate READ actually distinguishes the holes (the "8 picked -> 1" fix): the
# read whose points are most distinct is the one that carries the real per-hole
# location. NEVER throws.
# ----------------------------------------------------------------------------
function global:Get-DistinctPointCount {
    param([array]$Points, [int]$Decimals = 3)
    $fmt = '{0:0.' + ('#' * [Math]::Max(0,$Decimals)) + '}'
    $seen = @{}
    $n = 0
    if ($null -ne $Points) {
        foreach ($p in $Points) {
            if ($null -eq $p) { continue }
            $k = $null
            try { $k = (($fmt -f [double]$p[0]) + '|' + ($fmt -f [double]$p[1]) + '|' + ($fmt -f [double]$p[2])) } catch { continue }
            if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $n++ }
        }
    }
    return $n
}

# ----------------------------------------------------------------------------
# Select-BestHoleCenters - PURE. Given, per selected bore, a set of CANDIDATE
# location reads (member-frame descriptor origin, component transform origin, and
# the composed root point), pick the candidate representation that yields the MOST
# DISTINCT points across all bores - i.e. the read that actually tells the holes
# apart. This is the guess-free fix for "8 picked -> 1 bore center": on an assembly
# the descriptor origin can be member-local (all bores read the same point), while
# the composed-root / transform-origin reads are distinct. Rather than assume which,
# we MEASURE distinctness and choose.
#
#   Candidates - array (one entry per bore) of a hashtable/object exposing any of:
#                Member  = descriptor axis origin off the SelItem (component frame)
#                Sub     = cylinder axis origin off the SelItem's sub-surface (the bore
#                          INSIDE a Type=0 hole feature; component frame) -- the read the
#                          live probe pointed to when the SelItem is a feature, not a
#                          surface, and all holes share ONE component at the origin
#                Xform   = the component member->root transform origin
#                Root    = Member composed to root
#                SubRoot = Sub composed to root (bore geometry -> assembly frame)
#                Each is a 3-vector @(x,y,z) or $null (absent -> $null -> scores 0).
# Returns [pscustomobject]:
#   Which    'leafbyid'|'subroot'|'sub'|'root'|'xform'|'member'  (chosen representation)
#   Centers  [array] the chosen 3-vectors (nulls dropped), parallel-safe for projection
#   Distinct [int]   distinct-point count of the chosen representation
#   Counts   @{ leafbyid; member; sub; xform; root; subroot }  distinct counts (diagnostics)
# Preference on a TIE: leafbyid > subroot > sub > root > xform > member.
#   leafbyid = the clicked entity's bore read from the leaf part's OWN model (via
#     SelItem.DBParent + GetItemById), composed to the assembly frame -- the read PROVEN
#     to work when the picks are assembly components whose surfaces don't read through the
#     assembly (live 2026-07: DBParent -> 150-110-2101-007.prt, ListItems=True). It is the
#     most trustworthy because it reads the SPECIFIC clicked hole in the part frame.
#   subroot/sub = a hole feature's bore sub-surface (component/local). root/xform/member =
#     the earlier assembly-level reads. Absent keys score 0, so a plain PART (only Member)
#     still resolves to 'member'. NEVER throws.
# ----------------------------------------------------------------------------
function global:Select-BestHoleCenters {
    param([array]$Candidates)
    $leafbyid = @(); $member = @(); $sub = @(); $xform = @(); $root = @(); $subroot = @()
    if ($null -ne $Candidates) {
        foreach ($c in $Candidates) {
            if ($null -eq $c) { continue }
            $lv=$null; $mv=$null; $sv=$null; $xv=$null; $rv=$null; $srv=$null
            try { $lv = $c.LeafById } catch {}
            try { $mv = $c.Member }  catch {}
            try { $sv = $c.Sub }     catch {}
            try { $xv = $c.Xform }   catch {}
            try { $rv = $c.Root }    catch {}
            try { $srv = $c.SubRoot } catch {}
            $leafbyid += ,$lv
            $member  += ,$mv
            $sub     += ,$sv
            $xform   += ,$xv
            $root    += ,$rv
            $subroot += ,$srv
        }
    }
    $dl  = Get-DistinctPointCount -Points $leafbyid
    $dm  = Get-DistinctPointCount -Points $member
    $ds  = Get-DistinctPointCount -Points $sub
    $dx  = Get-DistinctPointCount -Points $xform
    $dr  = Get-DistinctPointCount -Points $root
    $dsr = Get-DistinctPointCount -Points $subroot
    # Ordered preference (most-preferred FIRST); keep the running max only on a STRICT
    # increase so a tie leaves the earlier (more-preferred) winner.
    $opts = @(
        [pscustomobject]@{ W='leafbyid'; D=$dl;  Pts=$leafbyid },
        [pscustomobject]@{ W='subroot'; D=$dsr; Pts=$subroot },
        [pscustomobject]@{ W='sub';     D=$ds;  Pts=$sub },
        [pscustomobject]@{ W='root';    D=$dr;  Pts=$root },
        [pscustomobject]@{ W='xform';   D=$dx;  Pts=$xform },
        [pscustomobject]@{ W='member';  D=$dm;  Pts=$member }
    )
    $bestOpt = $opts[0]
    foreach ($o in $opts) { if ($o.D -gt $bestOpt.D) { $bestOpt = $o } }
    $which = $bestOpt.W; $best = $bestOpt.D; $chosen = $bestOpt.Pts
    $centers = @($chosen | Where-Object { $null -ne $_ })
    return [pscustomobject]@{
        Which    = $which
        Centers  = $centers
        Distinct = [int]$best
        Counts   = [pscustomobject]@{ leafbyid = [int]$dl; member = [int]$dm; sub = [int]$ds; xform = [int]$dx; root = [int]$dr; subroot = [int]$dsr }
    }
}

# ============================================================================
# Read-HoleCentersFromModel - the SHARED "read the selected HOLES as centers" reader,
# the hole-side twin of creo_geometry.ps1's Read-FastenerCentersFromModel. It returns
# the SAME result SHAPE (Ok/Centers/Axes/Count/ReadMethod/MedianDia/Message + the
# selection diagnostics), so the drill-jig front-ends can feed its .Centers/.Axes into
# ConvertTo-LayoutXZ EXACTLY like the fastener read -- the ONLY thing that differs is
# HOW the centers are read off the buffer. This is what lets "fasteners OR holes"
# converge to one layout pipeline with no downstream change.
#
# THE READ (confirmed live 2026-07 on 150-110-0030-101.asm): the operator Ctrl-clicks
# individual HOLE features. On imported/foreign assembly geometry every cylinder-surface
# read fails (.Origin unreadable), but a hole's CIRCULAR EDGE arc CENTER reads via the
# curve descriptor and edges are readable there (the edginator channel). Per pick we take
# FOUR candidate reads (edge-arc, leaf cylinder-by-id, sub-surface cylinder, direct
# cylinder), resolving the clicked entity's leaf PART via SelItem.DBParent / Path.Leaf and
# composing the component transform to the assembly frame, then Select-BestHoleCenters
# auto-picks the representation that actually DISTINGUISHES the holes. NEVER reads
# IpfcPoint.Point. Requires creo_geometry.ps1 (Get-EdgeArcCenter / Get-CylinderAxisFromSurface
# / Get-Comp) dot-sourced alongside -- the front-ends always load both.
#
# IMPORTANT (operator guidance, surfaced by the callers): each hole must be its OWN
# feature/entity so its SelItem.Id resolves to that hole's edges -- see the front-end
# warning. Holes merged into one feature (a single patterned cut selected as a unit) may
# collapse; the caller shows the distinct count so a wrong read is visible.
#
# HL- helpers are file-private (prefixed to avoid clashing with holelayoutinator.cmd's
# same-named locals) and take $TypeObj explicitly (no module-level $pfcType).
# ----------------------------------------------------------------------------
function HL-BoreFromSubSurfaces {
    param($Item, $TypeObj)
    if ($null -eq $Item -or $null -eq $TypeObj) { return $null }
    $tv = $null; try { $tv = $TypeObj.ITEM_SURFACE } catch {}
    if ($null -eq $tv) { return $null }
    $subs = @(); try { $subs = @($Item.ListSubItems($tv)) } catch {}
    foreach ($sub in $subs) {
        $sax = $null; try { $sax = Get-CylinderAxisFromSurface -Surf $sub } catch {}
        if ($null -ne $sax -and $null -ne $sax.A) { return $sax }
    }
    return $null
}
function HL-LeafBoreById {
    param($Sel, $TypeObj)
    if ($null -eq $Sel -or $null -eq $TypeObj) { return $null }
    $si = $null; try { $si = $Sel.SelItem } catch {}
    if ($null -eq $si) { return $null }
    $selId = $null; try { $selId = [int]$si.Id } catch {}
    if ($null -eq $selId) { return $null }
    $lm = $null; try { $lm = $si.DBParent } catch {}
    if ($null -eq $lm) { try { $lm = $Sel.Path.Leaf } catch {} }
    if ($null -eq $lm) { return $null }
    $surf = $null; try { $surf = $lm.GetItemById($TypeObj.ITEM_SURFACE, $selId) } catch {}
    if ($null -ne $surf) { $a = $null; try { $a = Get-CylinderAxisFromSurface -Surf $surf } catch {}; if ($null -ne $a -and $null -ne $a.A) { return $a } }
    $feat = $null; try { $feat = $lm.GetItemById($TypeObj.ITEM_FEATURE, $selId) } catch {}
    if ($null -ne $feat) {
        $fs = @(); try { $fs = @($feat.ListSubItems($TypeObj.ITEM_SURFACE)) } catch {}
        foreach ($f in $fs) { $a = $null; try { $a = Get-CylinderAxisFromSurface -Surf $f } catch {}; if ($null -ne $a -and $null -ne $a.A) { return $a } }
    }
    return $null
}
function HL-LeafEdgeArc {
    param($Sel, $TypeObj)
    if ($null -eq $Sel -or $null -eq $TypeObj) { return $null }
    $si = $null; try { $si = $Sel.SelItem } catch {}
    if ($null -eq $si) { return $null }
    $selId = $null; try { $selId = [int]$si.Id } catch {}
    $lm = $null; try { $lm = $si.DBParent } catch {}
    if ($null -eq $lm) { try { $lm = $Sel.Path.Leaf } catch {} }
    $edges = @()
    if ($null -ne $lm -and $null -ne $selId) {
        foreach ($tk in @('ITEM_FEATURE','ITEM_SURFACE')) {
            $it = $null; try { $it = $lm.GetItemById($TypeObj.$tk, $selId) } catch {}
            if ($null -ne $it) { $ee = @(); try { $ee = @($it.ListSubItems($TypeObj.ITEM_EDGE)) } catch {}; if ($ee.Count -gt 0) { $edges = $ee; break } }
        }
    }
    if ($edges.Count -eq 0) { try { $edges = @($si.ListSubItems($TypeObj.ITEM_EDGE)) } catch {} }
    foreach ($e in $edges) {
        $a = $null; try { $a = Get-EdgeArcCenter -Edge $e } catch {}
        if ($null -ne $a -and $a.IsRound -and $null -ne $a.Center) { return @{ A = $a.Center; D = $null; Radius = $a.Radius } }
    }
    return $null
}
function global:Read-HoleCentersFromModel {
    param($Session, $Model, $TypeObj)
    $mk = {
        param($ok,$centers,$axes,$med,$msg,$raw,$skip,$which,$counts)
        [pscustomobject]@{
            Ok=$ok; Centers=$centers; Axes=$axes; Count=[int]@($centers).Count; IsAsm=$false
            ReadMethod='hole edge-arc (selected holes)'; MedianDia=[double]$med; Message=$msg
            RawSelected=[int]$raw; SkippedNoPath=0; SkippedNoXform=[int]$skip; MergedDuplicate=0
            AxisReads=[int]@($centers).Count; Which=$which; Counts=$counts
        }
    }
    if ($null -eq $Session -or $null -eq $TypeObj) { return (& $mk $false @() @() 0.0 'no session' 0 0 'none' $null) }
    $buf = @(); try { $buf = @(($Session.CurrentSelectionBuffer()).Contents) } catch {}
    $raw = @($buf).Count
    if ($raw -eq 0) { return (& $mk $false @() @() 0.0 'no holes selected - Ctrl-click the individual hole features/bores, then re-run' 0 0 'none' $null) }

    $cands = @(); $axesDir = @(); $diams = @(); $skip = 0
    foreach ($sel in $buf) {
        $si = $null; try { $si = $sel.SelItem } catch {}
        if ($null -eq $si) { $skip++; continue }
        $axEdge   = HL-LeafEdgeArc -Sel $sel -TypeObj $TypeObj
        $axDirect = $null; try { $axDirect = Get-CylinderAxisFromSurface -Surf $si } catch {}
        $axSub    = HL-BoreFromSubSurfaces -Item $si -TypeObj $TypeObj
        $axLeaf   = HL-LeafBoreById -Sel $sel -TypeObj $TypeObj
        if (($null -eq $axEdge -or $null -eq $axEdge.A) -and ($null -eq $axDirect -or $null -eq $axDirect.A) -and ($null -eq $axSub -or $null -eq $axSub.A) -and ($null -eq $axLeaf -or $null -eq $axLeaf.A)) { $skip++; continue }
        $axLeafBest = if ($null -ne $axEdge -and $null -ne $axEdge.A) { $axEdge } elseif ($null -ne $axLeaf -and $null -ne $axLeaf.A) { $axLeaf } else { $null }
        $rr = $null
        if     ($null -ne $axLeafBest -and $null -ne $axLeafBest.Radius) { $rr = $axLeafBest.Radius }
        elseif ($null -ne $axDirect   -and $null -ne $axDirect.Radius)   { $rr = $axDirect.Radius }
        elseif ($null -ne $axSub      -and $null -ne $axSub.Radius)      { $rr = $axSub.Radius }
        if ($null -ne $rr) { $diams += (2.0 * [double]$rr) }

        $member = if ($null -ne $axDirect)   { $axDirect.A }   else { $null }
        $subM   = if ($null -ne $axSub)      { $axSub.A }      else { $null }
        $leafM  = if ($null -ne $axLeafBest) { $axLeafBest.A } else { $null }
        $memberDir = if ($null -ne $axDirect)   { $axDirect.D }   else { $null }
        $subDir    = if ($null -ne $axSub)      { $axSub.D }      else { $null }
        $leafDir   = if ($null -ne $axLeafBest) { $axLeafBest.D } else { $null }
        $rootDir   = if ($null -ne $leafDir) { $leafDir } elseif ($null -ne $subDir) { $subDir } else { $memberDir }

        $xformO = $null; $rootP = $null; $subRootP = $null; $leafById = $leafM
        $path = $null; try { $path = $sel.Path } catch {}
        if ($null -ne $path) {
            $xf = $null; try { $xf = $path.GetTransform($true) } catch {}
            if ($null -ne $xf) {
                $to = $null; $bx = $null; $by = $null; $bz = $null
                try { $to = Get-Comp $xf.GetOrigin() } catch {}
                try { $bx = Get-Comp $xf.GetXAxis() } catch {}
                try { $by = Get-Comp $xf.GetYAxis() } catch {}
                try { $bz = Get-Comp $xf.GetZAxis() } catch {}
                $xformO = $to
                if ($null -ne $member) { $rootP    = Get-ComposedRootPoint -Member $member -O $to -Bx $bx -By $by -Bz $bz }
                if ($null -ne $subM)   { $subRootP = Get-ComposedRootPoint -Member $subM   -O $to -Bx $bx -By $by -Bz $bz }
                if ($null -ne $leafM)  { $lr = Get-ComposedRootPoint -Member $leafM -O $to -Bx $bx -By $by -Bz $bz; if ($null -ne $lr) { $leafById = $lr } }
                $dsrc = $rootDir
                if ($null -ne $dsrc -and $null -ne $bx -and $null -ne $by -and $null -ne $bz) {
                    $rd = Get-ComposedRootPoint -Member $dsrc -O @(0.0,0.0,0.0) -Bx $bx -By $by -Bz $bz
                    if ($null -ne $rd) { $rootDir = $rd }
                }
                if ($null -eq $rootDir -and $null -ne $bz) { $rootDir = $bz }
            }
        }
        if ($null -eq $rootDir) { $rootDir = @(0.0, 0.0, 1.0) }   # non-null -> ConvertTo-LayoutXZ engages panel-plane mode
        $cands   += [pscustomobject]@{ LeafById = $leafById; Member = $member; Sub = $subM; Xform = $xformO; Root = $rootP; SubRoot = $subRootP }
        $axesDir += ,$rootDir
    }
    if ($cands.Count -eq 0) { return (& $mk $false @() @() 0.0 'no readable holes in the selection - Ctrl-click the individual hole features/bores' $raw $skip 'none' $null) }

    $pick = Select-BestHoleCenters -Candidates $cands
    $centers = $pick.Centers
    $med = 0.25
    $sorted = @($diams | Where-Object { $_ -gt 0 } | Sort-Object)
    if ($sorted.Count -gt 0) { $med = [double]$sorted[[int]([math]::Floor($sorted.Count / 2))] }
    $ok = (@($centers).Count -ge 1)
    $msg = if ($ok) { '' } else { 'no distinct hole centers resolved' }
    return (& $mk $ok $centers $axesDir $med $msg $raw $skip $pick.Which $pick.Counts)
}

# ----------------------------------------------------------------------------
function global:Get-HoleLayoutStats {
    param([array]$Points, [double]$HoleDia = 0.0)

    $errors = @()
    if ($HoleDia -lt 0) { $errors += "HoleDia must be >= 0 (got $HoleDia)" }

    # collect numeric points defensively (never throw on a bad entry)
    $pts = @()
    $skipped = 0
    if ($null -ne $Points) {
        foreach ($p in $Points) {
            $x = $null; $z = $null
            try { if ($null -ne $p.X) { $x = [double]$p.X } } catch {}
            try { if ($null -ne $p.Z) { $z = [double]$p.Z } } catch {}
            if ($null -eq $x -or $null -eq $z) { $skipped++; continue }
            if ([double]::IsNaN($x) -or [double]::IsInfinity($x) -or [double]::IsNaN($z) -or [double]::IsInfinity($z)) { $skipped++; continue }
            $pts += [pscustomobject]@{ X = [double]$x; Z = [double]$z }
        }
    }
    if ($pts.Count -lt 1) { $errors += "no numeric points to analyse" }

    # bounding box
    $minX = 0.0; $maxX = 0.0; $minZ = 0.0; $maxZ = 0.0
    if ($pts.Count -ge 1) {
        $minX = ($pts | ForEach-Object { $_.X } | Measure-Object -Minimum).Minimum
        $maxX = ($pts | ForEach-Object { $_.X } | Measure-Object -Maximum).Maximum
        $minZ = ($pts | ForEach-Object { $_.Z } | Measure-Object -Minimum).Minimum
        $maxZ = ($pts | ForEach-Object { $_.Z } | Measure-Object -Maximum).Maximum
    }

    # pairwise spacing (O(n^2) - fine for a few dozen holes; the layouts here are small)
    $minSp = 0.0; $maxSp = 0.0; $nearest = $null
    $collisions = @()
    if ($pts.Count -ge 2) {
        $minSp = [double]::MaxValue
        for ($i = 0; $i -lt $pts.Count; $i++) {
            for ($j = $i + 1; $j -lt $pts.Count; $j++) {
                $dx = [double]$pts[$i].X - [double]$pts[$j].X
                $dz = [double]$pts[$i].Z - [double]$pts[$j].Z
                $d  = [Math]::Sqrt($dx * $dx + $dz * $dz)
                if ($d -lt $minSp) { $minSp = $d; $nearest = [pscustomobject]@{ A = $i; B = $j; Dist = [double]$d } }
                if ($d -gt $maxSp) { $maxSp = $d }
                # collision: strictly closer than HoleDia (tangent allowed), 1e-9 float tol
                if ($HoleDia -gt 0 -and $d -lt ($HoleDia - 1e-9)) {
                    $collisions += [pscustomobject]@{ A = $i; B = $j; Dist = [double]$d }
                }
            }
        }
        if ($minSp -eq [double]::MaxValue) { $minSp = 0.0 }
    }

    return [pscustomobject]@{
        Valid       = ($errors.Count -eq 0)
        Errors      = [string[]]$errors
        Count       = [int]$pts.Count
        Skipped     = [int]$skipped
        MinX        = [double]$minX
        MaxX        = [double]$maxX
        MinZ        = [double]$minZ
        MaxZ        = [double]$maxZ
        Width       = [double]($maxX - $minX)
        Height      = [double]($maxZ - $minZ)
        MinSpacing  = [double]$minSp
        MaxSpacing  = [double]$maxSp
        NearestPair = $nearest
        Collisions  = $collisions
        HoleDia     = [double]$HoleDia
    }
}

# ----------------------------------------------------------------------------
# Format-HoleLayoutReport - render a Get-HoleLayoutStats result (+ the layout) into
# a plain-text, ASCII-only report block (an array of lines). PURE, never throws.
# ASCII-only so PS 5.1's console doesn't mojibake it (the orthogrid readout lesson).
#   Stats   - a Get-HoleLayoutStats result.
#   Layout  - optional; if it exposes .Points they are listed (capped at MaxList).
#   MaxList - cap on per-point lines (default 40).
# Returns [string[]].
# ----------------------------------------------------------------------------
function global:Format-HoleLayoutReport {
    param($Stats, $Layout = $null, [int]$MaxList = 40)
    $lines = @()
    if ($null -eq $Stats) { return @("  (no stats)") }
    $lines += ("  Holes: {0}  (skipped {1} non-numeric)" -f $Stats.Count, $Stats.Skipped)
    $lines += ("  Bounding box: {0:0.####} x {1:0.####}  (X {2:0.###}..{3:0.###}, Z {4:0.###}..{5:0.###})" -f `
        $Stats.Width, $Stats.Height, $Stats.MinX, $Stats.MaxX, $Stats.MinZ, $Stats.MaxZ)
    if ($Stats.Count -ge 2) {
        $lines += ("  Spacing: min {0:0.####}, max {1:0.####}" -f $Stats.MinSpacing, $Stats.MaxSpacing)
        if ($null -ne $Stats.NearestPair) {
            $lines += ("  Closest pair: #{0} - #{1} at {2:0.####}" -f ($Stats.NearestPair.A + 1), ($Stats.NearestPair.B + 1), $Stats.NearestPair.Dist)
        }
    }
    if ($Stats.HoleDia -gt 0) {
        if (@($Stats.Collisions).Count -gt 0) {
            $lines += ("  COLLISION: {0} pair(s) closer than the {1:0.####} bore diameter (bores would overlap):" -f @($Stats.Collisions).Count, $Stats.HoleDia)
            $shown = 0
            foreach ($c in $Stats.Collisions) {
                if ($shown -ge 5) { $lines += ("      ...and {0} more" -f (@($Stats.Collisions).Count - 5)); break }
                $lines += ("      #{0} - #{1} at {2:0.####}" -f ($c.A + 1), ($c.B + 1), $c.Dist)
                $shown++
            }
        } else {
            $lines += ("  No collisions at bore diameter {0:0.####} (all pairs clear or tangent)." -f $Stats.HoleDia)
        }
    }
    if ($null -ne $Layout) {
        $pts = @()
        try { $pts = @($Layout.Points) } catch {}
        if ($pts.Count -gt 0) {
            $lines += "  Points (corner-relative X, Z):"
            $pi = 0
            foreach ($p in $pts) {
                if ($pi -ge $MaxList) { $lines += ("      ...({0} more)" -f ($pts.Count - $MaxList)); break }
                $lines += ("    {0,3}: ({1:0.####}, {2:0.####})" -f ($pi + 1), [double]$p.X, [double]$p.Z)
                $pi++
            }
        }
    }
    return $lines
}

# ----------------------------------------------------------------------------
# Write-HoleLayout - persist a projected layout to the STANDALONE handoff file
# hole_layout.json. Deliberately a DIFFERENT file + a DIFFERENT function name than
# Write-FastenerLayout so this tool never touches the fastener workflow. Records
# provenance (source model, units, read method) + the analysis stats snapshot.
#
#   Path        - full path to write (typically <repo>\hole_layout.json).
#   Layout      - a ConvertTo-LayoutXZ result (.Points, .AxisX/Z, .Margin, ...).
#   Stats       - optional Get-HoleLayoutStats result (snapshotted for provenance).
#   SourceModel - the read model's file name.
#   Units       - 'inch'|'mm'|'unknown'.
#   ReadMethod  - which read produced the centers.
#   WhenIso     - ISO timestamp string (passed in - Date.now-free-friendly).
# Returns $true on success, $false on any I/O error (never throws).
# ----------------------------------------------------------------------------
function global:Write-HoleLayout {
    param(
        [string]$Path,
        $Layout,
        $Stats = $null,
        [string]$SourceModel = '',
        [string]$Units = 'unknown',
        [string]$ReadMethod = 'unknown',
        [string]$WhenIso = ''
    )
    if ($null -eq $Layout) { return $false }
    try {
        # Ensure the destination dir exists (hole_layout.json now lives under
        # <repo>\artifacts\; Set-Content throws on a missing parent). Covers --out too.
        $parent = Split-Path -Parent $Path
        if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        $ptsOut = @()
        foreach ($p in @($Layout.Points)) {
            $ptsOut += [pscustomobject]@{ X = [double]$p.X; Z = [double]$p.Z }
        }
        $statObj = $null
        if ($null -ne $Stats) {
            $statObj = [pscustomobject]@{
                MinSpacing = [double]$Stats.MinSpacing
                MaxSpacing = [double]$Stats.MaxSpacing
                Width      = [double]$Stats.Width
                Height     = [double]$Stats.Height
            }
        }
        $ax = ''; $az = ''; $axS = 1.0; $azS = 1.0; $mg = 0.0
        try { $ax  = [string]$Layout.AxisX } catch {}
        try { $az  = [string]$Layout.AxisZ } catch {}
        try { $axS = [double]$Layout.AxisXSign } catch {}
        try { $azS = [double]$Layout.AxisZSign } catch {}
        try { $mg  = [double]$Layout.Margin } catch {}
        $obj = [pscustomobject]@{
            Kind        = 'hole-layout'          # distinguishes it from a fastener_layout.json
            SourceModel = [string]$SourceModel
            Units       = [string]$Units
            AxisX       = $ax
            AxisZ       = $az
            AxisXSign   = [double]$axS
            AxisZSign   = [double]$azS
            Margin      = [double]$mg
            Count       = [int]@($ptsOut).Count
            Points      = $ptsOut
            Stats       = $statObj
            ReadMethod  = [string]$ReadMethod
            WhenIso     = [string]$WhenIso
        }
        $json = $obj | ConvertTo-Json -Depth 6
        Set-Content -Path $Path -Value $json -Encoding UTF8
        return $true
    } catch {
        return $false
    }
}

# ----------------------------------------------------------------------------
# Read-HoleLayout - load hole_layout.json back into a normalized result. Mirrors
# Read-FastenerLayout's shape (Points shaped like Get-CustomPointsGeometry input +
# SpanX/SpanZ derived) but for the standalone file. Case-SENSITIVE key reads
# (ConvertFrom-Json is case-sensitive - the diminator lesson). NEVER throws.
#   Path - the file to read.
# ----------------------------------------------------------------------------
function global:Read-HoleLayout {
    param([string]$Path)
    $errors = @()
    $empty = {
        param($errs)
        [pscustomobject]@{
            Valid=$false; Errors=[string[]]$errs; Points=@(); Count=0;
            SourceModel=''; Units='unknown'; AxisX=''; AxisZ=''; Margin=0.0;
            ReadMethod='unknown'; WhenIso=''; SpanX=0.0; SpanZ=0.0; Kind=''
        }
    }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return (& $empty @("hole layout file not found: $Path"))
    }
    $raw = $null
    try { $raw = Get-Content $Path -Raw | ConvertFrom-Json } catch { return (& $empty @("could not parse ${Path}: $($_.Exception.Message)")) }
    if ($null -eq $raw) { return (& $empty @("empty layout file: $Path")) }

    $pts = @()
    $minX = $null; $maxX = $null; $minZ = $null; $maxZ = $null
    try {
        $srcPts = @($raw.Points)
        $j = 0
        foreach ($p in $srcPts) {
            $x = $null; $z = $null
            try { if ($null -ne $p.X) { $x = [double]$p.X } } catch {}
            try { if ($null -ne $p.Z) { $z = [double]$p.Z } } catch {}
            if ($null -eq $x -or $null -eq $z) { $errors += "point $($j + 1) is missing a numeric X/Z"; $j++; continue }
            $pts += [pscustomobject]@{ I = $pts.Count; J = 0; X = [double]$x; Z = [double]$z }
            if ($null -eq $minX -or $x -lt $minX) { $minX = $x }
            if ($null -eq $maxX -or $x -gt $maxX) { $maxX = $x }
            if ($null -eq $minZ -or $z -lt $minZ) { $minZ = $z }
            if ($null -eq $maxZ -or $z -gt $maxZ) { $maxZ = $z }
            $j++
        }
    } catch { $errors += "could not read Points array: $($_.Exception.Message)" }

    if ($pts.Count -lt 1) { $errors += "layout file has no usable points" }

    $units = 'unknown'; $ax=''; $az=''; $margin=0.0; $src=''; $rm='unknown'; $when=''; $kind=''
    try { if ($null -ne $raw.Units)       { $units  = [string]$raw.Units } } catch {}
    try { if ($null -ne $raw.AxisX)       { $ax     = [string]$raw.AxisX } } catch {}
    try { if ($null -ne $raw.AxisZ)       { $az     = [string]$raw.AxisZ } } catch {}
    try { if ($null -ne $raw.Margin)      { $margin = [double]$raw.Margin } } catch {}
    try { if ($null -ne $raw.SourceModel) { $src    = [string]$raw.SourceModel } } catch {}
    try { if ($null -ne $raw.ReadMethod)  { $rm     = [string]$raw.ReadMethod } } catch {}
    try { if ($null -ne $raw.WhenIso)     { $when   = [string]$raw.WhenIso } } catch {}
    try { if ($null -ne $raw.Kind)        { $kind   = [string]$raw.Kind } } catch {}

    $spanX = if ($null -ne $minX) { [double]($maxX - $minX) } else { 0.0 }
    $spanZ = if ($null -ne $minZ) { [double]($maxZ - $minZ) } else { 0.0 }

    return [pscustomobject]@{
        Valid       = ($errors.Count -eq 0)
        Errors      = [string[]]$errors
        Points      = $pts
        Count       = [int]$pts.Count
        SourceModel = $src
        Units       = $units
        AxisX       = $ax
        AxisZ       = $az
        Margin      = [double]$margin
        ReadMethod  = $rm
        WhenIso     = $when
        SpanX       = $spanX
        SpanZ       = $spanZ
        Kind        = $kind
    }
}
