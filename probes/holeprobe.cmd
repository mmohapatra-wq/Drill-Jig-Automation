<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir=((Split-Path -Parent ('%~dp0'.TrimEnd('\')))+'\'); $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "HOLEPROBE (read-only diagnostic)"
$ErrorActionPreference = "Stop"

# ============================================================================
# HOLEPROBE -- READ-ONLY diagnostic. Creates/mutates NOTHING. For each SELECTED
# item in the buffer it dumps EVERY candidate location read so we can see, on the
# REAL assembly, why 8 selected holes collapse to 1 coincident point -- and which
# read gives DISTINCT per-hole locations relative to the coordinate system.
# ============================================================================
# WHY: holelayoutinator reported "8 picked -> 1 bore center (merged 7 coincident)".
# That means all 8 selected bores resolve to the SAME coordinate. Rather than guess
# again, this probe shows the raw numbers for each candidate read:
#   [A] surface descriptor cylinder axis  (Get-CylinderAxisFromSurface: member-frame?)
#   [B] component path present? ComponentIds (are the 8 in ONE component or 8?)
#   [C] component member->root transform origin (GetTransform($true).GetOrigin())
#   [D] the composed root point  = T.O + B * memberAxisOrigin
# Whichever COLUMN comes out DISTINCT across the 8 picks is the read the tool must
# use. Standalone; dot-sources creo_geometry.ps1 READ-ONLY (Get-Comp only). Never
# reads IpfcPoint.Point.
# ============================================================================

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

. (Join-Path $ScriptDir 'lib\creo_geometry.ps1')   # Get-Comp / Get-CylinderAxisFromSurface (read-only use)

function Fmt3 { param($p) if ($null -eq $p) { return '   <null>' }; try { return ('({0,9:0.####}, {1,9:0.####}, {2,9:0.####})' -f [double]$p[0], [double]$p[1], [double]$p[2]) } catch { return '   <unreadable>' } }

Write-Host ""
Write-Host "  HOLEPROBE -- read-only. Dumps every candidate location read per selected bore." -ForegroundColor Cyan
Write-Host "  Creates/mutates NOTHING." -ForegroundColor DarkGray
Write-Host ""

$procs = @(Get-Process -Name xtop -ErrorAction SilentlyContinue)
if ($procs.Count -eq 0) { throw "Creo (xtop.exe) is not running." }
if ($procs.Count -gt 1) { throw "More than one Creo session is open. Expect exactly ONE." }
$proc = $procs[0]
$Env:PRO_DIRECTORY    = $proc.Path.TrimEnd("xtop.exe")
$Env:PRO_COMM_MSG_EXE = $proc.Path -replace "xtop.exe", "pro_comm_msg.exe"
try { New-Object -ComObject pfcls.pfcAsyncConnection | Out-Null }
catch { Start-Process -Wait -FilePath ($proc.Path -replace "Common Files(.*)$", "Parametric\bin\vb_api_register.bat") }

$async      = New-Object -ComObject pfcls.pfcAsyncConnection
$connection = $async.Connect($null, $null, $null, $null)
$session    = $connection.Session
$model      = $session.GetActiveModel()
if ($null -eq $model) { throw "No active model." }
$pfcType = New-Object -ComObject pfcls.pfcModelItemType
$fname = try { [string]$model.FileName } catch { "" }
Write-Host "  Active model: $fname" -ForegroundColor Green
Write-Host ""
# Decode the ITEM enum ints so we can name a SelItem's Type (Type=0 seen live).
$itemTypeNames = @('ITEM_FEATURE','ITEM_SURFACE','ITEM_EDGE','ITEM_CURVE','ITEM_POINT','ITEM_AXIS','ITEM_QUILT','ITEM_COORD_SYS','ITEM_COMPONENT','ITEM_LAYER','ITEM_DIMENSION')
$typeIntToName = @{}
Write-Host "  ITEM enum values on this build:" -ForegroundColor DarkGray
foreach ($tn in $itemTypeNames) {
    $tv = $null; try { $tv = [int]$pfcType.$tn } catch {}
    if ($null -ne $tv) { $typeIntToName[$tv] = $tn; Write-Host ("    {0,-16} = {1}" -f $tn, $tv) -ForegroundColor DarkGray }
}
Write-Host ""
Write-Host "  SELECT the hole bore SURFACES in Creo (Ctrl-click, one per hole), then press ENTER." -ForegroundColor Cyan
Read-Host "  ENTER when selected" | Out-Null

try {
    # distinct-point counter (defined up front so [F] can use it too)
    function Count-Distinct { param($pts) $seen=@{}; $n=0; foreach($p in $pts){ if($null -eq $p){continue}; $k=('{0:0.###}|{1:0.###}|{2:0.###}' -f [double]$p[0],[double]$p[1],[double]$p[2]); if(-not $seen.ContainsKey($k)){ $seen[$k]=$true; $n++ } }; return $n }
    $buf = @()
    try { $buf = @(($session.CurrentSelectionBuffer()).Contents) } catch {}
    Write-Host ""
    Write-Host ("  Selection buffer: {0} item(s)." -f $buf.Count) -ForegroundColor Green
    Write-Host ""

    $i = 0
    $rootPts = @()
    $descPts = @()
    $xfPts   = @()
    $subPts  = @()   # [E] cylinder axis from the SelItem's sub-surfaces (feature -> child geometry)
    foreach ($sel in $buf) {
        $i++
        Write-Host ("  --- item #{0} -------------------------------------------------" -f $i) -ForegroundColor White

        # [item] SelItem id/type
        $si = $null; try { $si = $sel.SelItem } catch {}
        if ($null -eq $si) { Write-Host "    SelItem: <null> (not a model item)" -ForegroundColor Yellow }
        else {
            $sid = try { [int]$si.Id } catch { '?' }
            $sty = try { [int]$si.Type } catch { '?' }
            $styName = if ($typeIntToName.ContainsKey($sty)) { $typeIntToName[$sty] } else { '<unknown>' }
            Write-Host ("    SelItem: Id={0}  Type={1} ({2})" -f $sid, $sty, $styName) -ForegroundColor Gray
        }

        # [A] cylinder descriptor axis (as Get-CylinderAxisFromSurface reads it)
        $ax = $null; try { $ax = Get-CylinderAxisFromSurface -Surf $si } catch { Write-Host "    [A] descriptor read threw: $($_.Exception.Message)" -ForegroundColor Yellow }
        if ($null -ne $ax -and $null -ne $ax.A) {
            Write-Host ("    [A] descriptor axis origin : {0}   R={1:0.####}" -f (Fmt3 $ax.A), [double]$ax.Radius) -ForegroundColor Gray
            Write-Host ("        descriptor axis dir    : {0}" -f (Fmt3 $ax.D)) -ForegroundColor DarkGray
            $descPts += ,$ax.A
        } else { Write-Host "    [A] descriptor axis: <not a readable cylinder>" -ForegroundColor Yellow; $descPts += ,$null }

        # [E] SUB-ITEM exploration: the SelItem is a FEATURE, so its bore geometry is a
        # CHILD. Dump ListSubItems COUNTS for EVERY type (so we see what the feature
        # actually exposes -- and whether the foreign-body traversal wall applies), then
        # read a cylinder axis off any cylindrical sub-SURFACE (radinator/holeinator route).
        $subCyl = $null
        if ($null -ne $si) {
            $any = $false
            foreach ($stype in @('ITEM_SURFACE','ITEM_AXIS','ITEM_EDGE','ITEM_CURVE','ITEM_POINT','ITEM_COORD_SYS')) {
                $tv = $null; try { $tv = $pfcType.$stype } catch {}
                if ($null -eq $tv) { continue }
                $subs = @(); $err = $null
                try { $subs = @($si.ListSubItems($tv)) } catch { $err = $_.Exception.Message }
                if ($null -ne $err) { Write-Host ("    [E] ListSubItems({0}) threw: {1}" -f $stype, $err) -ForegroundColor Yellow; continue }
                if ($subs.Count -eq 0) { continue }
                $any = $true
                Write-Host ("    [E] ListSubItems({0}) : {1} item(s)" -f $stype, $subs.Count) -ForegroundColor Gray
                if ($stype -eq 'ITEM_SURFACE') {
                    foreach ($sub in $subs) {
                        $sty2 = $null; try { $sty2 = [int]$sub.GetSurfaceDescriptor().GetSurfaceType() } catch {}
                        $sax = $null; try { $sax = Get-CylinderAxisFromSurface -Surf $sub } catch {}
                        if ($null -ne $sax -and $null -ne $sax.A) {
                            Write-Host ("        -> sub-cylinder axis origin: {0}  R={1:0.####}" -f (Fmt3 $sax.A), [double]$sax.Radius) -ForegroundColor Green
                            if ($null -eq $subCyl) { $subCyl = $sax.A }
                        } else {
                            Write-Host ("        -> sub-surface type={0} (not a readable cylinder)" -f $(if ($null -ne $sty2) { $sty2 } else { '?' })) -ForegroundColor DarkGray
                        }
                    }
                }
            }
            if (-not $any) { Write-Host "    [E] ListSubItems returned NOTHING for any type (foreign-body traversal wall?)" -ForegroundColor Yellow }
        }
        if ($null -eq $subCyl) { Write-Host "    [E] no cylindrical sub-surface found" -ForegroundColor Yellow }
        $subPts += ,$subCyl

        # [B] component path?
        $path = $null; try { $path = $sel.Path } catch {}
        if ($null -eq $path) { Write-Host "    [B] Path: <null> (surface not resolved to a component)" -ForegroundColor Yellow }
        else {
            $ids = $null; try { $ids = $path.ComponentIds } catch {}
            $idsStr = if ($null -ne $ids) { try { ($ids -join '|') } catch { '?' } } else { '<null>' }
            Write-Host ("    [B] Path.ComponentIds : {0}" -f $idsStr) -ForegroundColor Gray

            # [C] member->root transform origin + axes
            $xf = $null; try { $xf = $path.GetTransform($true) } catch { Write-Host "        GetTransform threw: $($_.Exception.Message)" -ForegroundColor Yellow }
            if ($null -ne $xf) {
                $to = $null; $bx=$null; $by=$null; $bz=$null
                try { $to = Get-Comp $xf.GetOrigin() } catch {}
                try { $bx = Get-Comp $xf.GetXAxis() } catch {}
                try { $by = Get-Comp $xf.GetYAxis() } catch {}
                try { $bz = Get-Comp $xf.GetZAxis() } catch {}
                Write-Host ("    [C] transform origin  : {0}" -f (Fmt3 $to)) -ForegroundColor Cyan
                Write-Host ("        transform Xaxis   : {0}" -f (Fmt3 $bx)) -ForegroundColor DarkGray
                Write-Host ("        transform Yaxis   : {0}" -f (Fmt3 $by)) -ForegroundColor DarkGray
                Write-Host ("        transform Zaxis   : {0}" -f (Fmt3 $bz)) -ForegroundColor DarkGray
                $xfPts += ,$to

                # [D] composed root = T.O + B * memberAxisOrigin
                if ($null -ne $ax -and $null -ne $ax.A -and $null -ne $to -and $null -ne $bx -and $null -ne $by -and $null -ne $bz) {
                    $pm = $ax.A
                    $r0 = [double]$to[0] + [double]$bx[0]*[double]$pm[0] + [double]$by[0]*[double]$pm[1] + [double]$bz[0]*[double]$pm[2]
                    $r1 = [double]$to[1] + [double]$bx[1]*[double]$pm[0] + [double]$by[1]*[double]$pm[1] + [double]$bz[1]*[double]$pm[2]
                    $r2 = [double]$to[2] + [double]$bx[2]*[double]$pm[0] + [double]$by[2]*[double]$pm[1] + [double]$bz[2]*[double]$pm[2]
                    $rp = @($r0,$r1,$r2)
                    Write-Host ("    [D] composed ROOT pt  : {0}" -f (Fmt3 $rp)) -ForegroundColor Green
                    $rootPts += ,$rp
                } else { $rootPts += ,$null }
            } else { $xfPts += ,$null; $rootPts += ,$null }
        }
        Write-Host ""
    }

    # ============================================================
    # [F] LEAF PART model resolution (the definitive test). All picks resolve to ONE
    # component (same ComponentIds + transform), so the per-hole geometry lives in that
    # leaf component's OWN part model -- where the PROVEN part cylinder-axis read works
    # (it fails when reached THROUGH the assembly). Try a battery of ways to get the
    # leaf model, then read ALL its cylinder bores + transform to the assembly frame.
    # ============================================================
    Write-Host "  ============================================================" -ForegroundColor White
    Write-Host "  [F] LEAF PART model resolution + part-frame cylinder read:" -ForegroundColor White
    $sel0 = $buf[0]
    $si0 = $null; try { $si0 = $sel0.SelItem } catch {}
    $path0 = $null; try { $path0 = $sel0.Path } catch {}
    $leaf = $null
    $attempts = @(
        @{ n='SelItem.GetModelDescr -> Session.GetModelFromDescr'; f = { $d = $si0.GetModelDescr(); $session.GetModelFromDescr($d) } },
        @{ n='SelItem.GetModel';        f = { $si0.GetModel() } },
        @{ n='SelItem.DBParent';        f = { $si0.DBParent } },
        @{ n='Path.Leaf';               f = { $path0.Leaf } },
        @{ n='Path.Leaf.GetModel';      f = { $path0.Leaf.GetModel() } },
        @{ n='Selection.GetSelModel';   f = { $sel0.GetSelModel() } }
    )
    foreach ($a in $attempts) {
        $r = $null; $err = $null
        try { $r = & $a.f } catch { $err = $_.Exception.Message }
        if ($null -eq $r) { Write-Host ("    [F] {0,-42} -> null/err: {1}" -f $a.n, $err) -ForegroundColor DarkGray; continue }
        $tn = try { $r.GetType().Name } catch { '?' }
        $fn = ''; try { $fn = [string]$r.FileName } catch {}
        $listOk = $false; try { $null = @($r.ListItems($pfcType.ITEM_SURFACE)); $listOk = $true } catch {}
        Write-Host ("    [F] {0,-42} -> {1}  FileName='{2}'  ListItems={3}" -f $a.n, $tn, $fn, $listOk) -ForegroundColor Gray
        if ($listOk -and $null -eq $leaf) { $leaf = $r }
    }
    if ($null -ne $leaf) {
        $leafName = '?'; try { $leafName = [string]$leaf.FileName } catch {}
        Write-Host ("    [F] leaf model resolved: {0}" -f $leafName) -ForegroundColor Green
        $surfs = @(); try { $surfs = @(Get-AllSurfaces -Model $leaf -TypeObj $pfcType) } catch { Write-Host "        Get-AllSurfaces threw: $($_.Exception.Message)" -ForegroundColor Yellow }
        Write-Host ("    [F] leaf surfaces: {0}" -f $surfs.Count) -ForegroundColor Gray
        $leafCyl = @()
        foreach ($s in $surfs) {
            $sax = $null; try { $sax = Get-CylinderAxisFromSurface -Surf $s } catch {}
            if ($null -ne $sax -and $null -ne $sax.A) { $leafCyl += ,$sax.A }
        }
        Write-Host ("    [F] readable cylinder bores in leaf part: {0} ({1} distinct)" -f $leafCyl.Count, (Count-Distinct $leafCyl)) -ForegroundColor Magenta
        $shown = 0
        foreach ($p in $leafCyl) { if ($shown -ge 12) { break }; Write-Host ("        part-frame axis origin: {0}" -f (Fmt3 $p)) -ForegroundColor DarkGray; $shown++ }
    } else {
        Write-Host "    [F] could NOT resolve a leaf part model from the selection (see attempts above)." -ForegroundColor Yellow
    }
    Write-Host ""

    # ============================================================
    # [G] PER-PICK leaf GetItemById read (the read the TOOL will use). Each pick's
    # SelItem.Id is an entity id in the leaf part (DBParent). Resolve that part, look
    # the id up as a SURFACE then as a FEATURE (-> sub-surface cylinder), read the
    # cylinder axis in the PART frame (works there), and compose the pick's transform
    # to the assembly frame. If this gives 8 distinct, the tool's leaf-by-id read works.
    # ============================================================
    Write-Host "  [G] PER-PICK leaf GetItemById -> part-frame cylinder -> root:" -ForegroundColor White
    $gPts = @()
    $gi = 0
    foreach ($sel in $buf) {
        $gi++
        $si = $null; try { $si = $sel.SelItem } catch {}
        if ($null -eq $si) { $gPts += ,$null; continue }
        $selId = $null; try { $selId = [int]$si.Id } catch {}
        $lm = $null; try { $lm = $si.DBParent } catch {}
        if ($null -eq $lm) { try { $lm = $sel.Path.Leaf } catch {} }
        $gax = $null
        if ($null -ne $lm -and $null -ne $selId) {
            # as a SURFACE id
            $surf = $null; try { $surf = $lm.GetItemById($pfcType.ITEM_SURFACE, $selId) } catch {}
            if ($null -ne $surf) { try { $gax = Get-CylinderAxisFromSurface -Surf $surf } catch {} }
            # else as a FEATURE id -> its sub-surface cylinder
            if ($null -eq $gax -or $null -eq $gax.A) {
                $feat = $null; try { $feat = $lm.GetItemById($pfcType.ITEM_FEATURE, $selId) } catch {}
                if ($null -ne $feat) {
                    $fsubs = @(); try { $fsubs = @($feat.ListSubItems($pfcType.ITEM_SURFACE)) } catch {}
                    foreach ($fs in $fsubs) { $t=$null; try { $t = Get-CylinderAxisFromSurface -Surf $fs } catch {}; if ($null -ne $t -and $null -ne $t.A) { $gax = $t; break } }
                }
            }
        }
        if ($null -eq $gax -or $null -eq $gax.A) { Write-Host ("    [G] #{0} id={1}: no readable cylinder via leaf GetItemById" -f $gi, $selId) -ForegroundColor DarkGray; $gPts += ,$null; continue }
        # compose the pick's transform (part-frame -> root)
        $rp = $gax.A
        $p2 = $null; try { $p2 = $sel.Path } catch {}
        if ($null -ne $p2) {
            $xf2 = $null; try { $xf2 = $p2.GetTransform($true) } catch {}
            if ($null -ne $xf2) {
                $to=$null;$bx=$null;$by=$null;$bz=$null
                try { $to=Get-Comp $xf2.GetOrigin() } catch {}
                try { $bx=Get-Comp $xf2.GetXAxis() } catch {}
                try { $by=Get-Comp $xf2.GetYAxis() } catch {}
                try { $bz=Get-Comp $xf2.GetZAxis() } catch {}
                if ($null -ne $to -and $null -ne $bx -and $null -ne $by -and $null -ne $bz) {
                    $m=$gax.A
                    $c0=[double]$to[0]+[double]$bx[0]*[double]$m[0]+[double]$by[0]*[double]$m[1]+[double]$bz[0]*[double]$m[2]
                    $c1=[double]$to[1]+[double]$bx[1]*[double]$m[0]+[double]$by[1]*[double]$m[1]+[double]$bz[1]*[double]$m[2]
                    $c2=[double]$to[2]+[double]$bx[2]*[double]$m[0]+[double]$by[2]*[double]$m[1]+[double]$bz[2]*[double]$m[2]
                    $rp=@($c0,$c1,$c2)
                }
            }
        }
        Write-Host ("    [G] #{0} id={1}: root {2}  R={3:0.####}" -f $gi, $selId, (Fmt3 $rp), [double]$gax.Radius) -ForegroundColor Green
        $gPts += ,$rp
    }
    Write-Host ("    [G] leaf-by-id distinct: {0} of {1}" -f (Count-Distinct $gPts), $buf.Count) -ForegroundColor Magenta
    Write-Host ""

    # ============================================================
    # EDGE-BASED reads. The cylinder SURFACE descriptor (.Origin) is a dead end on
    # this foreign body -- even type=1 sub-surfaces read "not a readable cylinder".
    # But a drilled hole leaves CIRCULAR EDGES whose ARC CENTER is the hole center,
    # and edges are the channel PROVEN readable on foreign bodies (edginator). The
    # load-bearing unknown: does edge.GetCurveDescriptor().Center actually read here,
    # or degrade to arc-no-center (radius reads, center doesn't -- same failure the
    # surface descriptor showed)? These two sections settle it in ONE run.
    # arc = center readable (WIN); arc-no-center = round but center unreadable (still stuck).
    # ============================================================
    # transform helper (compose a LEAF/part-frame point to the assembly root frame)
    $tTo=$null;$tBx=$null;$tBy=$null;$tBz=$null
    $p0=$null; try { $p0 = $buf[0].Path } catch {}
    if ($null -ne $p0) {
        $xf0=$null; try { $xf0 = $p0.GetTransform($true) } catch {}
        if ($null -ne $xf0) {
            try { $tTo=Get-Comp $xf0.GetOrigin() } catch {}
            try { $tBx=Get-Comp $xf0.GetXAxis() } catch {}
            try { $tBy=Get-Comp $xf0.GetYAxis() } catch {}
            try { $tBz=Get-Comp $xf0.GetZAxis() } catch {}
        }
    }
    function ComposeRoot { param($m)
        if ($null -eq $m) { return $null }
        if ($null -eq $tTo -or $null -eq $tBx -or $null -eq $tBy -or $null -eq $tBz) { return $m }
        $c0=[double]$tTo[0]+[double]$tBx[0]*[double]$m[0]+[double]$tBy[0]*[double]$m[1]+[double]$tBz[0]*[double]$m[2]
        $c1=[double]$tTo[1]+[double]$tBx[1]*[double]$m[0]+[double]$tBy[1]*[double]$m[1]+[double]$tBz[1]*[double]$m[2]
        $c2=[double]$tTo[2]+[double]$tBx[2]*[double]$m[0]+[double]$tBy[2]*[double]$m[1]+[double]$tBz[2]*[double]$m[2]
        return @($c0,$c1,$c2)
    }
    # kind tally for the arc reads (is the CENTER readable at all on this build?)
    $arcKind = @{}
    function TallyArc { param($k) if (-not $arcKind.ContainsKey($k)) { $arcKind[$k]=0 }; $arcKind[$k]++ }

    # ---- [H] PER-PICK: the clicked leaf item's EDGES -> first readable arc center ----
    Write-Host "  [H] PER-PICK leaf-item EDGES -> arc center (matches the 8-hole selection):" -ForegroundColor White
    $hPts = @()
    $hi = 0
    foreach ($sel in $buf) {
        $hi++
        $si = $null; try { $si = $sel.SelItem } catch {}
        if ($null -eq $si) { $hPts += ,$null; continue }
        $selId = $null; try { $selId = [int]$si.Id } catch {}
        $lm = $null; try { $lm = $si.DBParent } catch {}; if ($null -eq $lm) { try { $lm = $sel.Path.Leaf } catch {} }
        # gather the edges belonging to THIS pick (feature/surface by id in the leaf, else the SelItem's own)
        $edges = @()
        if ($null -ne $lm -and $null -ne $selId) {
            foreach ($tk in @('ITEM_FEATURE','ITEM_SURFACE')) {
                $it = $null; try { $it = $lm.GetItemById($pfcType.$tk, $selId) } catch {}
                if ($null -ne $it) { $ee=@(); try { $ee=@($it.ListSubItems($pfcType.ITEM_EDGE)) } catch {}; if ($ee.Count -gt 0) { $edges = $ee; break } }
            }
        }
        if ($edges.Count -eq 0) { try { $edges = @($si.ListSubItems($pfcType.ITEM_EDGE)) } catch {} }
        # first readable arc center among these edges
        $ctr = $null; $kind = 'none'; $rad = $null
        foreach ($e in $edges) {
            $a = Get-EdgeArcCenter -Edge $e
            if ($a.IsRound) {
                if ($null -ne $a.Center) { $ctr = $a.Center; $kind='arc'; $rad = $a.Radius; break }
                elseif ($kind -eq 'none') { $kind='arc-no-center'; $rad = $a.Radius }
            }
        }
        TallyArc $kind
        $rp = ComposeRoot $ctr
        Write-Host ("    [H] #{0} id={1}: edges={2} kind={3} R={4} root {5}" -f $hi, $selId, $edges.Count, $kind, $(if($null -ne $rad){('{0:0.####}' -f [double]$rad)}else{'?'}), (Fmt3 $rp)) -ForegroundColor DarkGray
        $hPts += ,$rp
    }
    Write-Host ("    [H] arc-kind tally: {0}" -f (($arcKind.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')) -ForegroundColor Gray
    Write-Host ("    [H] per-pick edge arc-center distinct: {0} of {1}" -f (Count-Distinct $hPts), $buf.Count) -ForegroundColor Magenta
    Write-Host ""

    # ---- [I] FACE CONTOURS: planar sub-surfaces of item#1 -> INNER contours = holes ----
    # (the "click the face, read the holes in it" idea; runs on the planar sub-surfaces
    #  [E] already found. Outer contour = longest total edge length; inners = holes.)
    Write-Host "  [I] FACE CONTOURS (item#1 planar faces -> inner contours -> hole arcs):" -ForegroundColor White
    $iPts = @()
    $si1 = $null; try { $si1 = $buf[0].SelItem } catch {}
    $subs1 = @(); if ($null -ne $si1) { try { $subs1 = @($si1.ListSubItems($pfcType.ITEM_SURFACE)) } catch {} }
    $faceN = 0
    foreach ($s in $subs1) {
        $st = $null; try { $st = [int]$s.GetSurfaceDescriptor().GetSurfaceType() } catch {}
        if ($st -ne 0 -and $st -ne 9) { continue }     # planar faces only
        $faceN++
        $cons = $null; try { $cons = $s.ListContours() } catch { Write-Host ("    [I] face#{0} ListContours threw: {1}" -f $faceN, $_.Exception.Message) -ForegroundColor Yellow; continue }
        if ($null -eq $cons -or $cons.Count -eq 0) { Write-Host ("    [I] face#{0}: 0 contours" -f $faceN) -ForegroundColor DarkGray; continue }
        # per-contour total edge length (coordinate-free) -> outer = longest
        $crows = @()
        for ($ci = 0; $ci -lt $cons.Count; $ci++) {
            $ct = $null; try { $ct = $cons.Item($ci) } catch {}
            if ($null -eq $ct) { continue }
            $els = @(); try { $els = @($ct.ListElements()) } catch {}
            $len = 0.0; foreach ($el in $els) { try { $len += [double]$el.EvalLength() } catch {} }
            $crows += [pscustomobject]@{ Idx=$ci; Els=$els; Len=$len }
        }
        Write-Host ("    [I] face#{0}: {1} contour(s)" -f $faceN, $crows.Count) -ForegroundColor Gray
        if ($crows.Count -lt 2) { continue }            # 1 contour = no holes on this face
        $outer = ($crows | Sort-Object Len -Descending | Select-Object -First 1).Idx
        foreach ($cr in $crows) {
            if ($cr.Idx -eq $outer) { continue }         # skip the outer boundary
            $ctr=$null;$kind='none';$rad=$null
            foreach ($el in $cr.Els) {
                $a = Get-EdgeArcCenter -Edge $el
                if ($a.IsRound) { if ($null -ne $a.Center) { $ctr=$a.Center;$kind='arc';$rad=$a.Radius;break } elseif ($kind -eq 'none') { $kind='arc-no-center';$rad=$a.Radius } }
            }
            $rp = ComposeRoot $ctr
            Write-Host ("        inner contour #{0}: kind={1} R={2} root {3}" -f $cr.Idx, $kind, $(if($null -ne $rad){('{0:0.####}' -f [double]$rad)}else{'?'}), (Fmt3 $rp)) -ForegroundColor DarkGray
            if ($null -ne $rp) { $iPts += ,$rp }
        }
    }
    Write-Host ("    [I] face-contour hole-center distinct: {0} (planar faces scanned: {1})" -f (Count-Distinct $iPts), $faceN) -ForegroundColor Magenta
    Write-Host ""

    # -- distinctness summary: which read produced DISTINCT values across the picks? --
    Write-Host "  ============================================================" -ForegroundColor White
    Write-Host "  DISTINCTNESS (how many UNIQUE points each read gives):" -ForegroundColor White
    Write-Host ("    [A] descriptor axis origin    : {0} distinct of {1}" -f (Count-Distinct $descPts), $buf.Count) -ForegroundColor Gray
    Write-Host ("    [C] transform origin          : {0} distinct of {1}" -f (Count-Distinct $xfPts),   $buf.Count) -ForegroundColor Cyan
    Write-Host ("    [D] composed root point       : {0} distinct of {1}" -f (Count-Distinct $rootPts), $buf.Count) -ForegroundColor Green
    Write-Host ("    [E] sub-surface cylinder axis : {0} distinct of {1}" -f (Count-Distinct $subPts),  $buf.Count) -ForegroundColor Magenta
    Write-Host ("    [H] per-pick edge arc center  : {0} distinct of {1}" -f (Count-Distinct $hPts),   $buf.Count) -ForegroundColor Magenta
    Write-Host ("    [I] face-contour hole center  : {0} distinct" -f (Count-Distinct $iPts)) -ForegroundColor Magenta
    Write-Host "  ============================================================" -ForegroundColor White
    Write-Host "  -> The column with N distinct (= your hole count) is the read the tool must use." -ForegroundColor Yellow
    Write-Host "  -> [H]/[I] use EDGE arc centers. If their arc-kind tally shows 'arc' (not" -ForegroundColor Yellow
    Write-Host "     arc-no-center), the edge center reads and that is the winning technique." -ForegroundColor Yellow
    Write-Host ""
} finally {
    try { $connection.Disconnect($null) } catch {}
}

Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
