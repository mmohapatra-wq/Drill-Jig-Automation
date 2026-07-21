# ============================================================================
# lib\drilljig_core.ps1 - the shared DRILL-JIG engine (Creo-facing + pure)
# ============================================================================
# The proven helper bodies behind drilljig.cmd, lifted into one dot-sourceable
# module so BOTH the console drilljig.cmd and the new GUI front-end
# (drilljig-gui.cmd) call the SAME live-verified code. Nothing here changes the
# Creo behavior of the originals - the macro strings, the offset-plane creation,
# the hole dashboard tail, the canaries are byte-for-byte the recipes proven live
# (see CLAUDE.md drilljig.cmd / holeinator / plane-probe sections).
#
# TWO kinds of helper:
#   * PURE (no COM): tree/catalog parsing, the by-ID select-macro fragments, the
#     hole/relief macro builders, Resolve-PlaneRole. These take only strings/ints
#     and return strings, so lib\tests\run_wizard_tests.ps1 exercises them offline.
#   * COM ORCHESTRATION: New-OffsetPlane, Set-PlaneOffset, the buffer readers, the
#     canary waiter, etc. To keep the bodies near-verbatim (they referenced the
#     enclosing $session/$model/$pfcType), they read a one-time-initialised script
#     scope instead of threading three params through every call. Call
#     Initialize-DrilljigCore ONCE after connecting:
#         Initialize-DrilljigCore -Session $s -Model $m -TypeObj $t -DataDir $d -Log {param($m,$c) ...}
#     The -Log callback (optional) routes status text; it defaults to Write-Host
#     so the console tool is unaffected. The GUI passes a callback that appends to
#     the wizard's run log.
#
# This module depends on lib\creo_geometry.ps1 (Get-LinearDimMap / Read-DimValue /
# Measure-Extents / New-ExcludeTypes) being dot-sourced first, exactly as
# drilljig.cmd requires.
# ============================================================================

# ---- one-time COM context + logger (set by Initialize-DrilljigCore) ---------
$script:DJSession = $null
$script:DJModel   = $null
$script:DJType    = $null
$script:DJDataDir = $null
$script:DJLog     = $null
$script:macroFailures = 0    # mirrors drilljig.cmd's run-wide mapkey failure tally

function Initialize-DrilljigCore {
    param($Session, $Model, $TypeObj, [string]$DataDir, [scriptblock]$Log = $null)
    $script:DJSession = $Session
    $script:DJModel   = $Model
    $script:DJType    = $TypeObj
    $script:DJDataDir = $DataDir
    $script:DJLog     = $Log
    $script:macroFailures = 0
}

# Internal: emit a status line. Routes to the -Log callback when set (GUI), else
# Write-Host (console). $Color is a best-effort hint the console honors.
function Write-DJ {
    param([string]$Text, [string]$Color = 'Gray')
    if ($null -ne $script:DJLog) {
        try { & $script:DJLog $Text $Color; return } catch {}
    }
    try { Write-Host $Text -ForegroundColor $Color } catch { Write-Host $Text }
}

# ============================================================================
# STAGE 1 - decision tree + catalog (PURE; lifted from drilljig.cmd verbatim)
# ============================================================================

# Turn a machinist fraction or plain number ("3/4", "0.5") into a decimal.
# A zero denominator ("3/0") returns $null, NOT Infinity: PowerShell double division
# by zero yields [double]::PositiveInfinity (no exception), which would then slip past
# a naive ">0" gate and flow downstream as a garbage/infinite dimension.
function ConvertTo-Decimal {
    param([string]$Text)
    if ($Text -match '^\s*(\d+)\s*/\s*(\d+)\s*$') {
        if ([double]$matches[2] -eq 0) { return $null }
        return [double]$matches[1] / [double]$matches[2]
    }
    $d = 0.0
    if ([double]::TryParse($Text, [ref]$d)) { return $d }
    return $null
}

# Validate an operator-entered chip-relief SLOT DEPTH (inches). PURE (no COM/state)
# so both front-ends validate a typed depth the same way and it is unit-testable.
# The slot depth doubles as the plate EXTRUDE PAD: plate = bushingLen + slotDepth,
# the slot removes slotDepth, so the functional guide depth stays == bushingLen for
# ANY positive depth -- a smaller depth just yields a thinner overall plate (the
# tight/restricted-space case, user 2026-07-21). Rules:
#   * blank / whitespace / $null  -> Ok, Value = $Default (accept the default).
#   * not a number                -> Error.
#   * <= 0                        -> Error (a non-positive pad/cut is meaningless).
#   * otherwise                   -> Ok, Value = the number rounded to 4 dp.
# Returns @{ Ok = [bool]; Value = [double]; Error = [string]|$null }.
# MUST be `function global:` -- the GUI's slot-depth step calls it from a TextBox
# TextChanged .GetNewClosure() handler, and a closure module can ONLY resolve GLOBAL
# functions (a plain script-scope dot-sourced function throws "'Resolve-SlotDepthInput'
# is not recognized" at keystroke time -- confirmed live 2026-07-21). Same reason
# Get-OrthogridGeometry / Get-RowSlots / the Draw-* helpers are global. The console
# calls it directly (not a closure), which works either way.
function global:Resolve-SlotDepthInput {
    param([string]$Text, [double]$Default = 0.25)
    $r = @{ Ok = $false; Value = [double]$Default; Error = $null }
    if ($null -eq $Text -or [string]::IsNullOrWhiteSpace($Text)) { $r.Ok = $true; $r.Value = [double]$Default; return $r }
    $v = 0.0
    if (-not [double]::TryParse($Text.Trim(), [ref]$v)) { $r.Error = ("Not a number: '{0}'" -f $Text.Trim()); return $r }
    if ($v -le 0) { $r.Error = 'Slot depth must be greater than 0.'; return $r }
    $r.Ok = $true; $r.Value = [math]::Round($v, 4)
    return $r
}

# Pull the machinist-fraction label ("3/4", "1 3/8") for OD, ID or Lg out of an
# EasyName "<tag> | OD <od> x ID <id> x <len> Lg"; falls back to $Fallback.
# The 'ID' branch (added for the ID-first pick flow) reads the middle "x ID <id> x"
# token: drill-bushing IDs are decimals in EasyName so this returns the decimal
# unchanged (matching how drills already display), while sleeve IDs are fractions
# and render as such. OD/Lg branches are byte-identical to the original.
function Get-FracLabel {
    param([string]$EasyName, [string]$Which, [string]$Fallback)
    if ($EasyName) {
        if ($Which -eq 'OD' -and $EasyName -match 'OD\s+(.+?)\s+x') { return $matches[1].Trim() }
        if ($Which -eq 'ID' -and $EasyName -match 'x\s+ID\s+(.+?)\s+x') { return $matches[1].Trim() }
        if ($Which -eq 'Lg' -and $EasyName -match 'x\s+([^x]+?)\s+Lg') { return $matches[1].Trim() }
    }
    return $Fallback
}

# Parse a free-text outcome label into a catalog query
#   { File = '<csv path>'; Filters = @( @{ Column='ID'|'OD'; Values=@(<decimals>) } ) }
# or $null if it isn't a catalog-show instruction. Uses $script:DJDataDir.
function Get-CatalogSpec {
    param([string]$Label)
    if (-not $Label) { return $null }
    $low = $Label.ToLower()
    $file = $null
    if ($low -match 'removable|drill') { $file = Join-Path $script:DJDataDir 'bushings_drill.csv' }
    elseif ($low -match 'sleeve')      { $file = Join-Path $script:DJDataDir 'bushings.csv' }
    if (-not $file) { return $null }

    $byCol = @{}
    $rx = [regex]'(\d+(?:/\d+)?(?:\.\d+)?)\s*(ID|OD)'
    foreach ($m in $rx.Matches($Label)) {
        $val = ConvertTo-Decimal $m.Groups[1].Value
        $col = $m.Groups[2].Value.ToUpper()
        if ($null -eq $val) { continue }
        if (-not $byCol.ContainsKey($col)) { $byCol[$col] = @() }
        $byCol[$col] += $val
    }
    $filters = @()
    foreach ($col in $byCol.Keys) { $filters += @{ Column = $col; Values = @($byCol[$col] | Select-Object -Unique) } }
    return @{ File = $file; Filters = $filters }
}

# A FIXED-OD leaf ("the OD of the hole will be 3/4 in") -> the hole diameter, or $null.
function Get-FixedOdSpec {
    param([string]$Label)
    if (-not $Label) { return $null }
    if ($Label -notmatch '(?i)\bOD\b') { return $null }
    if ($Label -match '(?i)\bOD\b[^0-9]*(\d+(?:/\d+)?(?:\.\d+)?)') { return (ConvertTo-Decimal $matches[1]) }
    return $null
}

# Load a catalog file and apply a spec's filters, returning the matching rows
# (@() if none / file missing). PURE apart from Import-Csv (filesystem only, no
# Creo). Replaces the Read-Host-driven Invoke-BushingPick: the GUI renders these
# rows as cards (OD -> length -> ID), this just supplies the filtered data.
function Get-CatalogRows {
    param($Spec)
    if ($null -eq $Spec) { return ,@() }
    if (-not (Test-Path $Spec.File)) { return ,@() }
    $rows = @(Import-Csv $Spec.File)
    foreach ($f in $Spec.Filters) {
        $col = $f.Column; $vals = $f.Values
        $rows = @($rows | Where-Object {
            $cell = [double]$_.$col
            ($vals | Where-Object { [math]::Abs($cell - $_) -lt 1e-6 }).Count -gt 0
        })
    }
    return ,@($rows)
}

# Group catalog rows into the GUI's OD -> length -> ID hierarchy (ascending),
# carrying the machinist-fraction labels. Pure. Returns an array of
#   @{ OD; ODLabel; Lengths = @( @{ Length; LenLabel; Rows = @(<row>...) } ) }
function Group-CatalogByOD {
    param([array]$Rows)
    $out = @()
    if ($null -eq $Rows -or $Rows.Count -eq 0) { return ,@($out) }
    $odGroups = @($Rows | Group-Object OD | Sort-Object { [double]$_.Name })
    foreach ($og in $odGroups) {
        $odLabel = Get-FracLabel $og.Group[0].EasyName 'OD' $og.Name
        $lenOut = @()
        $lenGroups = @($og.Group | Group-Object Length | Sort-Object { [double]$_.Name })
        foreach ($lg in $lenGroups) {
            $lenLabel = Get-FracLabel $lg.Group[0].EasyName 'Lg' $lg.Name
            $lenOut += [pscustomobject]@{
                Length   = [double]$lg.Name
                LenLabel = $lenLabel
                Rows     = @($lg.Group | Sort-Object { [double]$_.ID })
            }
        }
        $out += [pscustomobject]@{
            OD      = [double]$og.Name
            ODLabel = $odLabel
            Lengths = $lenOut
        }
    }
    return ,@($out)
}

# Group catalog rows into the ID-FIRST hierarchy ID -> length -> OD (all ascending),
# carrying the machinist-fraction labels. Pure. The ID-first analog of
# Group-CatalogByOD, used by the reordered pick flow (user 2026-07-21: ask ID first,
# then length; after those the OD is usually unique so it is auto-resolved, and only
# offered as a tie-breaker when a bore+length exists at more than one OD). Returns an
# array of
#   @{ ID; IDLabel; Lengths = @( @{ Length; LenLabel; ODCount; ODs = @( @{ OD; ODLabel; Rows = @(<row>...) } ) } ) }
# The ODs tier is ALWAYS populated (even when ODCount == 1) so callers gate the
# tie-breaker on the ODCount integer and never have to null-check ODs. ODCount and
# ODs.Count are equal by construction. OD is THE drilled jig hole diameter, so it is
# never silently chosen when ODCount > 1.
function Group-CatalogByID {
    param([array]$Rows)
    $out = @()
    if ($null -eq $Rows -or $Rows.Count -eq 0) { return ,@($out) }
    $idGroups = @($Rows | Group-Object ID | Sort-Object { [double]$_.Name })
    foreach ($ig in $idGroups) {
        $idLabel = Get-FracLabel $ig.Group[0].EasyName 'ID' $ig.Name
        $lenOut = @()
        $lenGroups = @($ig.Group | Group-Object Length | Sort-Object { [double]$_.Name })
        foreach ($lg in $lenGroups) {
            $lenLabel = Get-FracLabel $lg.Group[0].EasyName 'Lg' $lg.Name
            $odOut = @()
            $odGroups = @($lg.Group | Group-Object OD | Sort-Object { [double]$_.Name })
            foreach ($og in $odGroups) {
                $odLabel = Get-FracLabel $og.Group[0].EasyName 'OD' $og.Name
                $odOut += [pscustomobject]@{
                    OD      = [double]$og.Name
                    ODLabel = $odLabel
                    # Rows here already share one (ID, Length, OD) - sort by PartNumber
                    # (NOT ID, which is constant at this leaf) so Rows[0] is DETERMINISTIC
                    # if a future catalog ever lists two part numbers at the same triplet.
                    Rows    = @($og.Group | Sort-Object PartNumber)
                }
            }
            $lenOut += [pscustomobject]@{
                Length   = [double]$lg.Name
                LenLabel = $lenLabel
                ODCount  = $odOut.Count      # the tie-breaker gate; == ODs.Count
                ODs      = $odOut
            }
        }
        $out += [pscustomobject]@{
            ID      = [double]$ig.Name
            IDLabel = $idLabel
            Lengths = $lenOut
        }
    }
    return ,@($out)
}

# ============================================================================
# STANDARDIZED-LENGTH PICK (user 2026-07-21): technicians report bushing sleeve
# lengths are effectively standardized to the bore -- a 1/2" ID sleeve is normally
# 1/2" long, a 3/4" ID 3/4" long. So the LENGTH menu is now a FIXED set {1/2, 3/4,
# 1} + a Custom (type-anything) option, with a length RECOMMENDED from the chosen ID.
# Because the fixed menu is DECOUPLED from the catalog's own length rows (a custom
# length may match no SKU at all), OD can no longer be keyed on (ID, length) -- it is
# re-keyed on ID ALONE (the union of the ID's distinct ODs). Applies to BOTH catalogs.
# These three helpers are PURE (no COM/state) and are mirrored into jiginator.cmd /
# jiginator.ps1 (which dot-source no lib). Flow stays ID -> length -> OD-tiebreak.
# ============================================================================

# The three standardized lengths (value -> machinist label), ascending.
$script:DJStdLengths = @(
    [pscustomobject]@{ Value = 0.5;  Label = '1/2' },
    [pscustomobject]@{ Value = 0.75; Label = '3/4' },
    [pscustomobject]@{ Value = 1.0;  Label = '1'   }
)

# Build the fixed length menu for a chosen ID (bore). Returns
#   @{ Options = @( {Value; Label; IsCustom} , ... , {Value=$null; Label='Custom'; IsCustom=$true} );
#      PreselectIndex = <int> }
# PreselectIndex is the standardized length matching the ID by value (0.5->0, 0.75->1,
# 1.0->2), or -1 when the ID matches none (e.g. drill ID 0.375). The recommendation is
# by ID VALUE, independent of whether the catalog lists a SKU at that length. Pure.
# `global:` so the GUI's Validate/OnNext/closures all resolve it (siblings Get-IdOdOptions /
# Resolve-BushingPickRow are global too).
function global:Get-BushingLengthOptions {
    param([double]$Id)
    $opts = @()
    foreach ($s in $script:DJStdLengths) {
        $opts += [pscustomobject]@{ Value = [double]$s.Value; Label = [string]$s.Label; IsCustom = $false }
    }
    $opts += [pscustomobject]@{ Value = $null; Label = 'Custom'; IsCustom = $true }
    $pre = -1
    for ($i = 0; $i -lt $script:DJStdLengths.Count; $i++) {
        if ([math]::Abs([double]$script:DJStdLengths[$i].Value - $Id) -lt 1e-6) { $pre = $i; break }
    }
    return @{ Options = $opts; PreselectIndex = $pre }
}

# Distinct ODs reachable by one Group-CatalogByID entry (the UNION across its length
# tier), ascending. Each -> @{ OD; ODLabel; Rows = @(all SKU rows at that OD) }. This
# is the OD set the tie-break / auto-resolve now works from (OD re-keyed on ID). Pure.
# `global:` so the GUI can call it from Build AND from .GetNewClosure() handlers (the
# same reason Get-OrthogridGeometry / Resolve-SlotDepthInput are global).
function global:Get-IdOdOptions {
    param($IdGroup)
    $byOd = @{}
    if ($null -ne $IdGroup) {
        foreach ($ln in @($IdGroup.Lengths)) {
            foreach ($od in @($ln.ODs)) {
                $key = ('{0:0.######}' -f [double]$od.OD)
                if (-not $byOd.ContainsKey($key)) {
                    $byOd[$key] = [pscustomobject]@{ OD = [double]$od.OD; ODLabel = [string]$od.ODLabel; Rows = @() }
                }
                $byOd[$key].Rows += @($od.Rows)
            }
        }
    }
    $out = @($byOd.Values | Sort-Object { [double]$_.OD })
    # Rows here span the ID's lengths at this OD. Each catalog row has ONE Length so it
    # lands in exactly one length group -> the union never repeats a row, so NO PartNumber
    # de-dup (the drill catalog has truncated/duplicated PartNumbers -- e.g. many "8493A2"
    # rows -- so a Sort-Unique on PartNumber would wrongly collapse distinct-length SKUs).
    # Sort by (Length, PartNumber) for a deterministic order.
    foreach ($o in $out) { $o.Rows = @($o.Rows | Sort-Object { [double]$_.Length }, PartNumber) }
    return ,@($out)
}

# Resolve the final pick object from (ID group, chosen OD option, chosen length). If an
# exact (ID, OD, Length) SKU row exists in the OD option's rows (matched within 1e-6),
# return it verbatim (real EasyName + PartNumber). Otherwise synthesize a pick carrying
# the chosen (possibly custom) length. Returns {EasyName; OD; ID; Length; PartNumber}.
# CRITICAL: .Length is ALWAYS the chosen double -- downstream BushingLength -> STAGE 2
# SIDE-plane offset (= plate thickness) reads it. .OD is ALWAYS a real catalog OD. Pure.
# `global:` so the GUI's OnPick / "Use this length" .GetNewClosure() handlers resolve it.
function global:Resolve-BushingPickRow {
    param($IdGroup, $OdOption, [double]$Length, [string]$LenLabel)
    $exact = @($OdOption.Rows | Where-Object { [math]::Abs([double]$_.Length - $Length) -lt 1e-6 } | Select-Object -First 1)
    if ($exact.Count -gt 0) { return $exact[0] }
    $tag = 'Bushing'
    if (@($OdOption.Rows).Count -gt 0 -and $OdOption.Rows[0].EasyName) {
        $tag = ($OdOption.Rows[0].EasyName -split '\|')[0].Trim()
    }
    return [pscustomobject]@{
        EasyName   = ("{0} | OD {1} x ID {2} x {3} Lg" -f $tag, $OdOption.ODLabel, $IdGroup.IDLabel, $LenLabel)
        OD         = [double]$OdOption.OD
        ID         = [double]$IdGroup.ID
        Length     = [double]$Length
        PartNumber = '(custom length)'
    }
}

# Validate an operator-entered CUSTOM bushing length (inches). PURE, unit-testable,
# and the single validator shared by console + GUI so they behave identically. Accepts
# a decimal ("0.9"), a simple fraction ("3/8"), OR a mixed number ("1 3/8") -- the
# machinist audience types mixed numbers, which ConvertTo-Decimal alone does NOT parse.
# Rules: blank/$null -> Ok, Value = $Default (accept the recommendation); non-numeric
# or <= 0 -> Error. Returns @{ Ok = [bool]; Value = [double]; Error = [string]|$null }.
# `function global:` for the same reason as Resolve-SlotDepthInput (called from a GUI
# TextBox TextChanged .GetNewClosure() handler, which resolves GLOBAL functions only).
function global:Resolve-BushingLengthInput {
    param([string]$Text, [double]$Default = 0.5)
    $r = @{ Ok = $false; Value = [double]$Default; Error = $null }
    if ($null -eq $Text -or [string]::IsNullOrWhiteSpace($Text)) { $r.Ok = $true; $r.Value = [double]$Default; return $r }
    $t = $Text.Trim()
    $v = $null
    # mixed number: "<whole> <num>/<den>"
    if ($t -match '^\s*(\d+)\s+(\d+)\s*/\s*(\d+)\s*$') {
        $den = [double]$matches[3]
        if ($den -ne 0) { $v = [double]$matches[1] + ([double]$matches[2] / $den) }
    } else {
        $v = ConvertTo-Decimal $t
    }
    if ($null -eq $v) { $r.Error = ("Not a number: '{0}'" -f $t); return $r }
    # Reject NaN / +/-Infinity (PS 5.1 has no [double]::IsFinite) before the >0 gate --
    # Infinity would pass "-gt 0" and Round() without throwing.
    if ([double]::IsNaN([double]$v) -or [double]::IsInfinity([double]$v)) { $r.Error = ("Not a number: '{0}'" -f $t); return $r }
    if ($v -le 0) { $r.Error = 'Length must be greater than 0.'; return $r }
    $r.Ok = $true; $r.Value = [math]::Round([double]$v, 4)
    return $r
}

# Synthesize an "ID unspecified" bushing pick from an OD+length group's rows
# (OD still drives the hole; the user may leave the exact ID open). Pure.
# RETAINED FOR BACK-COMPAT ONLY: this and Group-CatalogByOD are dead in the ID-first
# pick flow (ID is now the first mandatory question, so there is no hidden ID to leave
# unspecified). Kept because Group-CatalogByOD is still exported + unit-tested; if an
# "any bore" need returns, the clean home is a separate top-level "pick OD directly"
# branch reusing Group-CatalogByOD, not a first-position ID placeholder.
function New-IdUnspecifiedPick {
    param([string]$ODLabel, [string]$LenLabel, [array]$Rows)
    $tag = ($Rows[0].EasyName -split '\|')[0].Trim()
    return [pscustomobject]@{
        EasyName   = "$tag | OD $ODLabel x ID (any) x $LenLabel Lg"
        OD         = $Rows[0].OD
        ID         = '(any)'
        Length     = $Rows[0].Length
        PartNumber = '(ID unspecified)'
    }
}

# ============================================================================
# STAGE 2/3 - by-ID select macros + hole macros (PURE strings; verbatim)
# ============================================================================

# Tree-search select-by-ID fragment for a FEATURE (nodelator/flipenator pattern).
# -NoClear omits the leading buffer_clean (feed an already-open dashboard collector).
function Get-SelectByIdMacro {
    param([int]$FeatId, [switch]$NoClear)
    $clear = if ($NoClear) { "" } else { "~ Activate ``main_dlg_cur`` ``buffer_clean``;" }
    return $clear +
        "~ Command ``ProCmdMdlTreeSearch``;" +
        "~ Open ``selspecdlg0`` ``SelOptionRadio``;" +
        "~ Close ``selspecdlg0`` ``SelOptionRadio``;" +
        "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Feature``;" +
        "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
        "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$FeatId``;" +
        "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
        "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
        "~ Activate ``selspecdlg0`` ``CancelButton``;"
}

# Select a DATUM PLANE by ID into an already-open dashboard reference collector
# (surfenator's proven up-to-plane feed: type DATUM, LookBy Feature). No buffer_clean.
function Get-SelectDatumByIdMacro {
    param([int]$FeatId)
    return "~ Command ``ProCmdMdlTreeSearch``;" +
        "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Datum``;" +
        "~ Select ``selspecdlg0`` ``LookByOptionMenu`` 1 ``Feature``;" +
        "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
        "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$FeatId``;" +
        "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
        "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
        "~ Activate ``selspecdlg0`` ``CancelButton``;"
}

# Internal: the point-by-ID (+ optional surface-by-ID) selection prefix shared by
# Build-HoleMacro and Build-ReliefHoleMacro. SurfacePlaneId>0 pre-selects the SIDE
# offset plane (Datum) as the On-Point placement surface, then the point (Point,
# accumulated, no buffer_clean); =0 is the original point-only path.
function Get-HolePointSelectMacro {
    param([int]$PointId, [int]$SurfacePlaneId = 0)
    $pointSearch =
        "~ Command ``ProCmdMdlTreeSearch``;" +
        "~ Open ``selspecdlg0`` ``SelOptionRadio``;" +
        "~ Close ``selspecdlg0`` ``SelOptionRadio``;" +
        "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Point``;" +
        "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
        "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$PointId``;" +
        "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
        "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
        "~ Activate ``selspecdlg0`` ``CancelButton``;"
    if ($SurfacePlaneId -gt 0) {
        return "~ Activate ``main_dlg_cur`` ``buffer_clean``;" +
            (Get-SelectDatumByIdMacro -FeatId $SurfacePlaneId) +
            $pointSearch
    }
    return "~ Activate ``main_dlg_cur`` ``buffer_clean``;" + $pointSearch
}

# Recorded hole macro (transcribed live 2026-06-11). ID-driven, ONE atomic RunMacro.
function Build-HoleMacro {
    param([int]$PointId, [double]$Diameter, [int]$BodyIndex = 0, [int]$SurfacePlaneId = 0, [int]$FlipCount = 1)
    $sel = Get-HolePointSelectMacro -PointId $PointId -SurfacePlaneId $SurfacePlaneId
    $flip = ""
    if ($SurfacePlaneId -gt 0 -and $FlipCount -gt 0) {
        for ($f = 0; $f -lt $FlipCount; $f++) { $flip += "~ Activate ``main_dlg_cur`` ``maindashInst0.Flip``;" }
    }
    return $sel +
        "~ Command ``ProCmdHole``;" +
        $flip +
        "~ Select ``main_dlg_cur`` ``maindashInst0.hole_depth_to_type_flybtn``;" +
        "~ Close  ``main_dlg_cur`` ``maindashInst0.hole_depth_to_type_flybtn``;" +
        "~ Activate ``main_dlg_cur`` ``maindashInst0.StrHoleDepThruAllF`` 1;" +
        "~ Activate ``main_dlg_cur`` ``chkbn.std_hle_layout.0`` 1;" +
        "~ Activate ``main_dlg_cur`` ``chkbn.std_hole_note_layout.0`` 1;" +
        "~ Activate ``main_dlg_cur`` ``chkbn.body_page.0`` 1;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ``$BodyIndex``;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ````;" +
        "~ Focus  ``body_page.1.0`` ``PH.bodyselectrepwdg_list``;" +
        "~ Select ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` 1 ``$BodyIndex``;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ````;" +
        "~ Input  ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu`` ``$Diameter``;" +
        "~ Update ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu`` ``$Diameter``;" +
        "~ Activate ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu``;" +
        "~ FocusOut ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu``;" +
        "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"
}

# A BLIND chip-relief hole (depth set AFTER creation via Set-ReliefHoleDepth).
function Build-ReliefHoleMacro {
    param([int]$PointId, [double]$Diameter, [int]$BodyIndex = 0, [int]$SurfacePlaneId = 0)
    $blindDepthType = "StrHoleDepBlindF"   # CONFIRMED live (trail.txt.3 2026-06-22)
    $sel = Get-HolePointSelectMacro -PointId $PointId -SurfacePlaneId $SurfacePlaneId
    $flip = ""
    if ($SurfacePlaneId -gt 0) { $flip = "~ Activate ``main_dlg_cur`` ``maindashInst0.Flip``;" }
    return $sel +
        "~ Command ``ProCmdHole``;" +
        $flip +
        "~ Select ``main_dlg_cur`` ``maindashInst0.hole_depth_to_type_flybtn``;" +
        "~ Close  ``main_dlg_cur`` ``maindashInst0.hole_depth_to_type_flybtn``;" +
        "~ Activate ``main_dlg_cur`` ``maindashInst0.$blindDepthType`` 1;" +
        "~ Activate ``main_dlg_cur`` ``chkbn.std_hle_layout.0`` 1;" +
        "~ Activate ``main_dlg_cur`` ``chkbn.std_hole_note_layout.0`` 1;" +
        "~ Activate ``main_dlg_cur`` ``chkbn.body_page.0`` 1;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ``$BodyIndex``;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ````;" +
        "~ Focus  ``body_page.1.0`` ``PH.bodyselectrepwdg_list``;" +
        "~ Select ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` 1 ``$BodyIndex``;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ````;" +
        "~ Input  ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu`` ``$Diameter``;" +
        "~ Update ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu`` ``$Diameter``;" +
        "~ Activate ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu``;" +
        "~ FocusOut ``main_dlg_cur`` ``maindashInst0.diameter_mip_OptionMenu``;" +
        "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"
}

# Map a datum-plane NAME to its box role by substring (SIDE first so it can't be shadowed).
function Resolve-PlaneRole {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $u = $Name.ToUpper()
    if ($u -match 'SIDE')  { return 'Side' }
    if ($u -match 'TOP')   { return 'Top' }
    if ($u -match 'FRONT') { return 'Front' }
    return $null
}

# ============================================================================
# COM ORCHESTRATION - read $script:DJSession/DJModel/DJType (Initialize first)
# ============================================================================

# Fire a mapkey, count + surface failures (boxinator's pattern, GUI-log aware).
function Invoke-Macro {
    param([string]$Label, [string]$Macro)
    Write-DJ "  > $Label ..." 'DarkGray'
    try {
        $script:DJSession.RunMacro($Macro)
    } catch {
        Write-DJ "    FAILED: $($_.Exception.Message)" 'Red'
        $script:macroFailures++
    }
}

# Forced regen with fallbacks (boxinator). Forced API regen -> UI ProCmdRegenerate
# -> automatic. Safe on No-Resolve builds (the forced path throws, we fall through).
function Invoke-ForceRegen {
    param($Model = $null)
    if ($null -eq $Model) { $Model = $script:DJModel }
    try {
        $regenCls = New-Object -ComObject pfcls.pfcRegenInstructions
        $instr    = $regenCls.Create($false, $true, $null)
        $Model.Regenerate($instr)
        return
    } catch {}
    $before = $null
    try { $before = $Model.VersionStamp } catch {}
    Invoke-Macro "force regenerate (UI)" "~ Command ``ProCmdRegenerate``;"
    if ($null -ne $before) {
        for ($i = 0; $i -lt 30; $i++) {
            try { if ($Model.VersionStamp -ne $before) { return } } catch {}
            Start-Sleep -Milliseconds 50
        }
    }
    try { $Model.Regenerate($null) } catch {}
}

# $true if VersionStamp changed within the timeout (the canary signal).
# A short Start-Sleep between polls so this does NOT spin a CPU core flat-out for
# the whole operation (the original tight loop pegged a core, which under the GUI
# also starved the UI thread -> sluggishness). 40ms is far finer than any Creo
# regen, so it does not slow detection; it just stops the busy-wait. When a GUI
# is driving, the -OnPoll callback pumps the message loop so the window repaints.
function Wait-ModelModified {
    param($Model = $null, [string]$PreviousStamp, [int]$TimeoutMs = 30000, [scriptblock]$OnPoll = $null)
    if ($null -eq $Model) { $Model = $script:DJModel }
    $deadline = [DateTime]::Now.AddMilliseconds($TimeoutMs)
    while ([DateTime]::Now -lt $deadline) {
        try { if ($Model.VersionStamp -ne $PreviousStamp) { return $true } } catch {}
        if ($null -ne $OnPoll) { try { & $OnPoll } catch {} }
        Start-Sleep -Milliseconds 40
    }
    return $false
}

# Snapshot every ITEM_FEATURE id (for before/after diffs).
function Get-FeatureIdSet {
    $set = @{}
    try { foreach ($f in $script:DJModel.ListItems($script:DJType.ITEM_FEATURE)) { try { $set[[int]$f.Id] = $true } catch {} } } catch {}
    return $set
}

# Read the (last) selected feature ID from the selection buffer, or $null.
function Read-SelectedId {
    $contents = ($script:DJSession.CurrentSelectionBuffer()).Contents
    if ($null -eq $contents -or $contents.Count -eq 0) { return $null }
    try { return [int]$contents[$contents.Count - 1].SelItem.Id } catch { return $null }
}

# Read the buffer as datum-plane picks: one { Id; Name; Role } per UNIQUE item.
# ID-and-name only (never coords). De-dups by id. @() if empty.
function Read-SelectionPlanePicks {
    $picks = @()
    $contents = $null
    try { $contents = ($script:DJSession.CurrentSelectionBuffer()).Contents } catch {}
    if ($null -eq $contents -or $contents.Count -eq 0) { return @($picks) }
    $seen = @{}
    foreach ($item in $contents) {
        $si = $null
        try { $si = $item.SelItem } catch { continue }
        if ($null -eq $si) { continue }
        $id = $null
        try { $id = [int]$si.Id } catch { continue }
        if ($seen.ContainsKey($id)) { continue }
        $seen[$id] = $true
        $name = $null
        try { $name = [string]$si.GetName() } catch {}
        $picks += [pscustomobject]@{ Id = $id; Name = $name; Role = (Resolve-PlaneRole -Name $name) }
    }
    return @($picks)
}

# Auto-discover the three default datums by NAME (no selection). First feature per
# role wins. @() if enumeration fails. Same shape as Read-SelectionPlanePicks.
function Find-DefaultDatumPicks {
    $picks = @()
    $contents = $null
    try { $contents = @($script:DJModel.ListItems($script:DJType.ITEM_FEATURE)) } catch {}
    if ($null -eq $contents -or $contents.Count -eq 0) { return @($picks) }
    $rolesSeen = @{}
    foreach ($f in $contents) {
        $name = $null
        try { $name = [string]$f.GetName() } catch {}
        $role = Resolve-PlaneRole -Name $name
        if ($null -eq $role) { continue }
        if ($rolesSeen.ContainsKey($role)) { continue }
        $id = $null
        try { $id = [int]$f.Id } catch { continue }
        $rolesSeen[$role] = $true
        $picks += [pscustomobject]@{ Id = $id; Name = $name; Role = $role }
    }
    return @($picks)
}

# Resolve the CURRENT selection buffer into datum POINT ids (never reads .Point).
# Returns @{ Ids = @(int...); Rejected = @(string...) } - the STAGE-3 hand-select logic.
function Resolve-SelectedPointIds {
    $points = ($script:DJSession.CurrentSelectionBuffer()).Contents
    $ids = @(); $seen = @{}; $rejected = @()
    if ($null -eq $points) { return @{ Ids = @($ids); Rejected = @($rejected) } }
    foreach ($item in $points) {
        $si = $null
        try { $si = $item.SelItem } catch { continue }
        if ($null -eq $si) { continue }
        $isPointType = $false
        try { $isPointType = ([int]$si.Type -eq [int]$script:DJType.ITEM_POINT) } catch {}
        $subIds = @()
        try { foreach ($pt in @($si.ListSubItems($script:DJType.ITEM_POINT))) { try { $subIds += [int]$pt.Id } catch {} } } catch {}
        if ($subIds.Count -gt 0) {
            foreach ($sid in $subIds) { if (-not $seen.ContainsKey($sid)) { $seen[$sid] = $true; $ids += $sid } }
        } elseif ($isPointType) {
            $id = [int]$si.Id
            if (-not $seen.ContainsKey($id)) { $seen[$id] = $true; $ids += $id }
        } else {
            $tname = "?"; $rid = "?"
            try { $rid = [int]$si.Id } catch {}
            try { $tname = [string]$si.Type } catch {}
            $rejected += "id $rid (type $tname)"
        }
    }
    return @{ Ids = @($ids); Rejected = @($rejected) }
}

# Create ONE offset plane from a base ref selected BY ID. Returns
# [pscustomobject]@{ Symbol; FeatId } (either may be $null). GUI-log aware.
#
# WAIT STRATEGY (perf, 2026-07-09): the OLD loop re-enumerated the ENTIRE model
# dimension list (Get-LinearDimMap = ListItems(ITEM_DIMENSION) + 3 property reads
# per dim) every 100ms from t=0 for up to 20s. That heavy COM walk GROWS as planes
# accumulate AND competes with Creo for the main thread DURING the very commit it is
# polling for -- the same self-defeating busy-wait the VersionStamp waiters warn
# about (boxinator: "flooding Creo with COM reads *during* the regen it's waiting on
# slows the very operation it's polling for"). It also ran for grid/slot planes whose
# Symbol is never read. Now:
#   (A) wait for the commit with the CHEAP single-property VersionStamp poll, and
#   (B) do the heavy feature/dim enumeration only a FEW times, AFTER the commit is
#       signalled -- not from t=0.
# -SkipSymbolWait additionally skips the dim-map diff entirely: grid X/Z planes and
# slot-edge planes need only .FeatId (they are intersected / shown by id, never
# re-driven by symbol), so those planes never touch the dimension list at all. The
# box planes (SIDE/TOP/FRONT) omit the switch because their Symbol drives the resize
# loop + the slot-depth read.
function New-OffsetPlane {
    param([string]$Label, [double]$Offset, [int]$BaseId, [switch]$SkipSymbolWait)
    $needSym    = -not $SkipSymbolWait
    $before     = if ($needSym) { Get-LinearDimMap -Model $script:DJModel -TypeObj $script:DJType } else { @{} }
    $beforeFeat = Get-FeatureIdSet
    $preStamp   = $null; try { $preStamp = [string]$script:DJModel.VersionStamp } catch {}

    $macro =
        (Get-SelectByIdMacro -FeatId $BaseId) +
        "~ Command ``ProCmdDatumPlane``;" +
        "~ Input  ``Odui_Dlg_00`` ``t1.constr_dim1`` ``$Offset``;" +
        "~ Update ``Odui_Dlg_00`` ``t1.constr_dim1`` ``$Offset``;" +
        "~ FocusOut ``Odui_Dlg_00`` ``t1.constr_dim1``;" +
        "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;"
    Invoke-Macro "$Label plane: open + offset $Offset + OK" $macro

    # (A) CHEAP wait for the commit: poll ONE property (VersionStamp) until it moves.
    # Heavy models commit slower, so keep the generous 20s ceiling -- but each poll
    # touches a single COM property, not the whole (growing) dim list.
    $stampMoved = $false
    if ($null -ne $preStamp) {
        $deadlineA = [DateTime]::Now.AddSeconds(20)
        while ([DateTime]::Now -lt $deadlineA) {
            try { if ([string]$script:DJModel.VersionStamp -ne $preStamp) { $stampMoved = $true; break } } catch {}
            Start-Sleep -Milliseconds 40
        }
        if (-not $stampMoved) { Write-DJ "    (waiting for Creo to commit the $Label plane timed out at 20s)" 'DarkGray' }
    }

    # (B) Commit signalled -> enumerate to grab the new feature id (+ the new offset
    # dim symbol only when needed). Bounded by a short deadline so a missed signal
    # can't hang; the new feature/dim is normally enumerable the instant the stamp
    # moves. Take the first new feature (existing lib semantics; warn if >1 dim).
    $newFeatId = $null; $sym = $null; $after = $before
    $deadlineB = [DateTime]::Now.AddSeconds($(if ($stampMoved) { 8 } else { 1 }))
    while ($true) {
        $afterFeat = Get-FeatureIdSet
        $newFeats  = @($afterFeat.Keys | Where-Object { -not $beforeFeat.ContainsKey($_) })
        if ($newFeats.Count -ge 1) { $newFeatId = [int]$newFeats[0] }
        if ($needSym) {
            $after   = Get-LinearDimMap -Model $script:DJModel -TypeObj $script:DJType
            $newSyms = @($after.Keys | Where-Object { -not $before.ContainsKey($_) })
            if ($newSyms.Count -ge 1) {
                if ($newSyms.Count -gt 1) { Write-DJ "    More than one new dim appeared ($($newSyms -join ', ')); taking the first." 'Yellow' }
                $sym = [string]$newSyms[0]; break
            }
        } elseif ($null -ne $newFeatId) {
            break
        }
        if ([DateTime]::Now -ge $deadlineB) { break }
        Start-Sleep -Milliseconds 50
    }

    if ($needSym -and $null -eq $sym) {
        Write-DJ "    No new linear dim appeared for the $Label plane (feat id $newFeatId)." 'Yellow'
        return [pscustomobject]@{ Symbol = $null; FeatId = $newFeatId }
    }
    if (-not $needSym -and $null -eq $newFeatId) {
        Write-DJ "    No new feature appeared for the $Label plane." 'Yellow'
        return [pscustomobject]@{ Symbol = $null; FeatId = $null }
    }
    if ($needSym) { Write-DJ "    $Label offset dim: $sym = $($after[$sym])" 'Green' }
    else          { Write-DJ "    $Label plane feat id $newFeatId (offset $Offset)" 'DarkGray' }
    return [pscustomobject]@{ Symbol = $sym; FeatId = $newFeatId }
}

# ----------------------------------------------------------------------------
# CSYS-REFERENCED DATUM PLANES (the 2026-07-14 architecture change): planes are
# offset from a COORDINATE SYSTEM + one of its axes instead of from the TOP/SIDE/
# FRONT default datums, so re-placing that csys (via the transform-reimport) moves
# every plane -> point -> hole with it. New-OffsetPlane above is LEFT INTACT
# (slotinator / New-SlotGuidePlanes still offset from planes); this is a sibling.
# ----------------------------------------------------------------------------

# Build-CsysOffsetPlaneMacro - PURE. mapkey 2: select the csys BY ID, ProCmdDatumPlane,
# pick the csys axis (t1.constr_csys_axis = Axis_X/Y/Z), optional offset (t1.constr_dim1),
# OK. ONE atomic RunMacro. Offset ~0 -> the axis's principal plane (no dim typed, like
# the recorded axis-only planes). LIVE-UNVERIFIED that the axis dropdown + t1.constr_dim1
# combine in one plane (the mapkey showed them separately) - New-CsysOffsetPlane canary-
# gates; the fallback is the t1.constrs_table/column_2 path the recorded offset plane used.
function Build-CsysOffsetPlaneMacro {
    param([int]$CsysFeatId, [string]$Axis, [double]$Offset)
    $axTok = "Axis_" + ($Axis.ToUpper())
    $m = (Get-SelectByIdMacro -FeatId $CsysFeatId) +
        "~ Command ``ProCmdDatumPlane``;" +
        "~ Open  ``Odui_Dlg_00`` ``t1.constr_csys_axis``;" +
        "~ Close ``Odui_Dlg_00`` ``t1.constr_csys_axis``;" +
        "~ Select ``Odui_Dlg_00`` ``t1.constr_csys_axis`` 1 ``$axTok``;"
    if ([math]::Abs([double]$Offset) -gt 1e-9) {
        $m += "~ Input  ``Odui_Dlg_00`` ``t1.constr_dim1`` ``$Offset``;" +
              "~ Update ``Odui_Dlg_00`` ``t1.constr_dim1`` ``$Offset``;" +
              "~ Activate ``Odui_Dlg_00`` ``t1.constr_dim1``;" +
              "~ FocusOut ``Odui_Dlg_00`` ``t1.constr_dim1``;"
    }
    $m += "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;"
    return $m
}

# Resolve-NewPlaneAfterCommit - the (A) VersionStamp wait + (B) new-feature/new-dim
# discovery lifted verbatim from New-OffsetPlane, so New-CsysOffsetPlane shares the
# EXACT same commit-wait + symbol/feat discovery + return shape without touching the
# proven New-OffsetPlane. Caller snapshots $before (dim map, or @{} when !NeedSym),
# $beforeFeat (Get-FeatureIdSet), $preStamp, and fires the macro FIRST.
function Resolve-NewPlaneAfterCommit {
    param([hashtable]$BeforeFeat, [hashtable]$Before, [string]$PreStamp, [string]$Label, [bool]$NeedSym)
    $stampMoved = $false
    if ($null -ne $PreStamp) {
        $deadlineA = [DateTime]::Now.AddSeconds(20)
        while ([DateTime]::Now -lt $deadlineA) {
            try { if ([string]$script:DJModel.VersionStamp -ne $PreStamp) { $stampMoved = $true; break } } catch {}
            Start-Sleep -Milliseconds 40
        }
        if (-not $stampMoved) { Write-DJ "    (waiting for Creo to commit the $Label plane timed out at 20s)" 'DarkGray' }
    }
    $newFeatId = $null; $sym = $null; $after = $Before
    $deadlineB = [DateTime]::Now.AddSeconds($(if ($stampMoved) { 8 } else { 1 }))
    while ($true) {
        $afterFeat = Get-FeatureIdSet
        $newFeats  = @($afterFeat.Keys | Where-Object { -not $BeforeFeat.ContainsKey($_) })
        if ($newFeats.Count -ge 1) { $newFeatId = [int]$newFeats[0] }
        if ($NeedSym) {
            $after   = Get-LinearDimMap -Model $script:DJModel -TypeObj $script:DJType
            $newSyms = @($after.Keys | Where-Object { -not $Before.ContainsKey($_) })
            if ($newSyms.Count -ge 1) {
                if ($newSyms.Count -gt 1) { Write-DJ "    More than one new dim appeared ($($newSyms -join ', ')); taking the first." 'Yellow' }
                $sym = [string]$newSyms[0]; break
            }
        } elseif ($null -ne $newFeatId) {
            break
        }
        if ([DateTime]::Now -ge $deadlineB) { break }
        Start-Sleep -Milliseconds 50
    }
    if ($NeedSym -and $null -eq $sym) {
        Write-DJ "    No new linear dim appeared for the $Label plane (feat id $newFeatId)." 'Yellow'
        return [pscustomobject]@{ Symbol = $null; FeatId = $newFeatId }
    }
    if (-not $NeedSym -and $null -eq $newFeatId) {
        Write-DJ "    No new feature appeared for the $Label plane." 'Yellow'
        return [pscustomobject]@{ Symbol = $null; FeatId = $null }
    }
    if ($NeedSym) { Write-DJ "    $Label offset dim: $sym = $($after[$sym])" 'Green' }
    else          { Write-DJ "    $Label plane feat id $newFeatId" 'DarkGray' }
    return [pscustomobject]@{ Symbol = $sym; FeatId = $newFeatId }
}

# New-CsysOffsetPlane - the csys+axis+offset sibling of New-OffsetPlane. Same
# return shape @{ Symbol; FeatId } and same -SkipSymbolWait semantics, so every
# downstream .Sym/.FeatId consumer (resize loop, slot-depth read, grid intersections,
# show) is unchanged. Axis is 'X'|'Y'|'Z'.
function New-CsysOffsetPlane {
    param([int]$CsysFeatId, [ValidateSet('X','Y','Z')][string]$Axis, [double]$Offset, [switch]$SkipSymbolWait)
    $needSym    = -not $SkipSymbolWait
    $before     = if ($needSym) { Get-LinearDimMap -Model $script:DJModel -TypeObj $script:DJType } else { @{} }
    $beforeFeat = Get-FeatureIdSet
    $preStamp   = $null; try { $preStamp = [string]$script:DJModel.VersionStamp } catch {}
    $label      = "csys Axis_$Axis @ $Offset"
    Invoke-Macro "$label plane: csys+axis+offset + OK" (Build-CsysOffsetPlaneMacro -CsysFeatId $CsysFeatId -Axis $Axis -Offset $Offset)
    return (Resolve-NewPlaneAfterCommit -BeforeFeat $beforeFeat -Before $before -PreStamp $preStamp -Label $label -NeedSym $needSym)
}

# Write one plane's offset, force a regen, return the value that stuck (or $null).
function Set-PlaneOffset {
    param($Plane, [double]$Value)
    try {
        $d = $script:DJModel.GetItemByName($script:DJType.ITEM_DIMENSION, $Plane.Sym)
        $d.DimValue = $Value
    } catch {
        Write-DJ "    $($Plane.Label): could not write DimValue: $($_.Exception.Message)" 'Yellow'
        return $null
    }
    Invoke-ForceRegen -Model $script:DJModel
    return (Read-DimValue -Model $script:DJModel -TypeObj $script:DJType -Sym $Plane.Sym)
}

# Drive a freshly-created BLIND hole to depth (boxinator way). Returns
# @{ Status='held'|'wrote-unconfirmed'|'no-depth-dim'|'error'; Sym; Value }.
function Set-ReliefHoleDepth {
    param($BeforeMap, [double]$Depth)
    $after = Get-LinearDimMap -Model $script:DJModel -TypeObj $script:DJType
    $newSyms = @($after.Keys | Where-Object { -not $BeforeMap.ContainsKey($_) })
    if ($newSyms.Count -eq 0) { return @{ Status = 'no-depth-dim'; Sym = $null; Value = $null } }
    if ($newSyms.Count -gt 1) { Write-DJ "      (>1 new linear dim after hole: $($newSyms -join ', '); taking the largest as depth)" 'Yellow' }
    $depthSym = $newSyms | Sort-Object { [double]$after[$_] } -Descending | Select-Object -First 1
    try {
        $d = $script:DJModel.GetItemByName($script:DJType.ITEM_DIMENSION, [string]$depthSym)
        $d.DimValue = $Depth
    } catch {
        return @{ Status = 'error'; Sym = [string]$depthSym; Value = $null }
    }
    Invoke-ForceRegen -Model $script:DJModel
    $got = Read-DimValue -Model $script:DJModel -TypeObj $script:DJType -Sym ([string]$depthSym)
    if ($null -ne $got -and [math]::Abs([double]$got - $Depth) -lt 1e-4) {
        return @{ Status = 'held'; Sym = [string]$depthSym; Value = $got }
    }
    return @{ Status = 'wrote-unconfirmed'; Sym = [string]$depthSym; Value = $got }
}

# Enumerate solid bodies as @( @{ Index; Name } ) for the body picker. @() on failure.
function Get-BodyList {
    $out = @()
    $bodies = @()
    try { $bodies = @($script:DJModel.ListItems($script:DJType.ITEM_BODY)) } catch {}
    for ($i = 0; $i -lt $bodies.Count; $i++) {
        $bn = "(unnamed)"
        try { $bn = [string]$bodies[$i].GetName() } catch {}
        $out += [pscustomobject]@{ Index = $i; Name = $bn }
    }
    return ,@($out)
}

# ============================================================================
# CHIP-RELIEF SLOTS (slotinator engine, shared by slotinator.cmd + drilljig.cmd
# + drilljig-gui.cmd). Moved here 2026-07-07 so all three fire the SAME
# confirmed-live macros instead of copy-pasted bodies. A slot is a blind
# rectangular REMOVE-MATERIAL extrude per hole row (length = part length,
# width = hole dia, depth = % of thickness); rows are seed-drawn once then
# patterned along a base datum plane's normal.
# ============================================================================

# Build-CutFinishMacro - MACRO B: finish the internal sketch (which holds the
# rectangle the operator drew), optionally flip the cut direction, type the blind
# depth, toggle REMOVE MATERIAL, pick the body, confirm. ONE atomic RunMacro (a
# dashboard's command context does not survive across RunMacro calls). PURE builder
# (no COM). Widget provenance (all confirmed live, slotinator.cmd / trail.txt.32,
# .27:3973, .8:1758/1799):
#   ProCmdSketDone -> [maindashInst0.flip_pb] -> [def_depth1_ip blind depth] ->
#   Enter/Exit dashInst0.Quit (blur) -> remove_material_cb 1 -> body_page.1.0 body
#   -> dashInst0.Done.
function Build-CutFinishMacro {
    param([double]$Depth = 0.0, [int]$BodyIndex = 0, [bool]$Flip = $true)
    $flipMacro = if ($Flip) { "~ Activate ``main_dlg_cur`` ``maindashInst0.flip_pb``;" } else { "" }
    $depthMacro = if ($Depth -gt 0) {
        "~ Input  ``main_dlg_cur`` ``maindashInst0.def_depth1_ip`` ``$Depth``;" +
        "~ Update ``main_dlg_cur`` ``maindashInst0.def_depth1_ip`` ``$Depth``;" +
        "~ Activate ``main_dlg_cur`` ``maindashInst0.def_depth1_ip``;" +
        "~ FocusOut ``main_dlg_cur`` ``maindashInst0.def_depth1_ip``;"
    } else { "" }
    return "~ Command ``ProCmdSketDone``;" +
        $flipMacro +
        $depthMacro +
        "~ Enter ``main_dlg_cur`` ``dashInst0.Quit``;" +
        "~ Exit  ``main_dlg_cur`` ``dashInst0.Quit``;" +
        "~ Activate ``main_dlg_cur`` ``maindashInst0.remove_material_cb`` 1;" +
        "~ Activate ``main_dlg_cur`` ``chkbn.body_page.0`` 1;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ``$BodyIndex``;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ````;" +
        "~ Focus  ``body_page.1.0`` ``PH.bodyselectrepwdg_list``;" +
        "~ Select ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` 1 ``$BodyIndex``;" +
        "~ Trigger ``body_page.1.0`` ``PH.bodyselectrepwdg_list`` ````;" +
        "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"
}

# Build-SlotPatternMacro - the hands-free single-direction pattern, fired as ONE
# atomic macro AFTER the operator has SELECTED the seed slot in the model tree
# (a search-buffer select does NOT register as the pattern target - the operator
# must click it; see slotinator FIX 1). Direction is a base DATUM PLANE fed BY ID
# (FIX 2): open pattern -> activate ui_pat_dir_dir1 -> feed the datum by ID ->
# count + spacing (+ optional flip) -> confirm. CONFIRMED LIVE 2026-07-07.
# Uses Build-PatternArm/Values/ConfirmMacro (orthogrid_points.ps1) +
# Get-SelectDatumByIdMacro (above).
function Build-SlotPatternMacro {
    param([int]$DirDatumId, [int]$Count, [double]$Spacing, [switch]$Flip)
    return (Build-PatternArmMacro) +
           (Get-SelectDatumByIdMacro -FeatId $DirDatumId) +
           (Build-PatternValuesMacro -Count1 $Count -Spacing1 $Spacing -Flip1:$Flip) +
           (Build-PatternConfirmMacro)
}

# New-SlotGuidePlanes - create + SHOW the slot-edge offset planes that guide the
# manual rectangle draw (the 2-plus datum planes slotinator makes; essential for
# drawing the slot to the right size). One plane per distinct X edge (offset from
# the TOP base) + per distinct Z edge (from FRONT); a ~0 offset reuses the base
# datum (point-probe trick). -UsePattern => only the FIRST row's edges (the seed;
# the pattern replicates it), else every row's edges. Shows each via
# ProCmdViewShow@PopupMenuTree (proven: plane-probe / trail.txt.32). Reads the core
# scope ($script:DJSession/$script:DJModel); needs Get-SharedPlanePlan (orthogrid_
# points) + New-OffsetPlane + Get-SelectByIdMacro in scope. Returns
# @{ Ids=@(); XCount; ZCount }. Never throws on a plane failure (logs to $Log).
function New-SlotGuidePlanes {
    param(
        [array]$Rows,
        [int]$TopBaseId,
        [int]$FrontBaseId,
        [switch]$UsePattern,
        [scriptblock]$Log = $null
    )
    $ids = @()
    if ($null -eq $Rows -or @($Rows).Count -lt 1 -or $TopBaseId -le 0 -or $FrontBaseId -le 0) {
        return @{ Ids = @(); XCount = 0; ZCount = 0 }
    }
    $corners = if ($UsePattern) { @($Rows[0].Corner0, $Rows[0].Corner1) } else { @($Rows | ForEach-Object { $_.Corner0; $_.Corner1 }) }
    $plan = Get-SharedPlanePlan -Points $corners
    $tolP = 1e-6
    foreach ($xOff in $plan.XCoords) {
        if ([math]::Abs([double]$xOff) -le $tolP) { continue }   # X~0 -> the TOP base datum (already visible)
        $res = New-OffsetPlane -Label "SlotX$($ids.Count)" -Offset ([double]$xOff) -BaseId ([int]$TopBaseId) -SkipSymbolWait
        if ($null -ne $res.FeatId) { $ids += [int]$res.FeatId }
        elseif ($null -ne $Log) { & $Log ("  slot X-edge plane at offset $xOff FAILED (continuing).") }
    }
    foreach ($zOff in $plan.ZCoords) {
        if ([math]::Abs([double]$zOff) -le $tolP) { continue }   # Z~0 -> the FRONT base datum
        $res = New-OffsetPlane -Label "SlotZ$($ids.Count)" -Offset ([double]$zOff) -BaseId ([int]$FrontBaseId) -SkipSymbolWait
        if ($null -ne $res.FeatId) { $ids += [int]$res.FeatId }
        elseif ($null -ne $Log) { & $Log ("  slot Z-edge plane at offset $zOff FAILED (continuing).") }
    }
    # SHOW each created plane (select by id -> ProCmdViewShow@PopupMenuTree)
    foreach ($planeId in $ids) {
        $showMacro = (Get-SelectByIdMacro -FeatId ([int]$planeId)) + "~ Command ``ProCmdViewShow@PopupMenuTree``;"
        try { $script:DJSession.RunMacro($showMacro) } catch { if ($null -ne $Log) { & $Log ("  could not show plane id $planeId : $($_.Exception.Message)") } }
    }
    try { $script:DJModel.Regenerate($null) } catch {}
    return @{ Ids = @($ids); XCount = $plan.XCoords.Count; ZCount = $plan.ZCoords.Count }
}

# Invoke-VerifiedSeedCut - fire the FIRST slot cut and VERIFY it with the operator
# (console: uses Read-Host for the draw/verify pause). The correct cut DIRECTION
# depends on the sketch plane and cannot be known offline, so: open the sketch, the
# operator draws the rectangle, fire the cut, then ASK whether it cut INTO the plate
# at the right depth. If NOT, undo + TOGGLE the flip + redraw once (only two
# directions). Returns @{ Ok; Flip; FeatId } - the confirmed Flip is reused for the
# pattern / remaining rows, so direction is verified ONCE. Reads the core session
# scope ($script:DJSession/$script:DJModel), so slotinator.cmd AND drilljig.cmd share
# this one copy (both call Initialize-DrilljigCore). The GUI does NOT call this - it
# uses wizard arm/verify steps around the same Build-CutFinishMacro.
function Invoke-VerifiedSeedCut {
    param(
        [int]$FaceId,
        [double]$Depth,
        [int]$BodyIndex,
        [bool]$Flip,
        [string]$RowLabel = "row 1",
        [hashtable]$DrawInfo   # SlotLen, RowAxis, SlotWidth, CrossAxis, CrossCoord, HasPlanes
    )
    $curFlip = $Flip
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $dirWord = if ($curFlip) { "flipped" } else { "default" }
        $mkOpen =
            (Get-SelectByIdMacro -FeatId $FaceId) +
            "~ Command ``ProCmdFtExtrude``;" +
            "~ Command ``ProCmdViewSketchView``;" +
            "~ Command ``ProCmdSketRectangle`` 1;"
        Write-Host ""
        Write-Host ("  SEED SLOT ($RowLabel) - attempt $attempt, direction: $dirWord - opening the sketch...") -ForegroundColor Cyan
        try { $script:DJSession.RunMacro($mkOpen) }
        catch {
            Write-Host "    Could not open the sketch: $($_.Exception.Message)" -ForegroundColor Red
            return @{ Ok = $false; Flip = $curFlip; FeatId = $null }
        }

        Write-Host ""
        Write-Host "  MANUAL STEP - draw the rectangle over $RowLabel's holes:" -ForegroundColor Magenta
        Write-Host ("    target: {0:0.###} long (along {1}) x {2:0.###} wide (along {3}), centered on {3}~{4:0.###}" -f `
            $DrawInfo.SlotLen, $DrawInfo.RowAxis, $DrawInfo.SlotWidth, $DrawInfo.CrossAxis, $DrawInfo.CrossCoord) -ForegroundColor White
        if ($DrawInfo.HasPlanes) { Write-Host "    Snap the rectangle edges to the visible slot-edge planes." -ForegroundColor White }
        Write-Host "    Click one corner then the opposite corner (ONE closed rectangle). Esc drops the tool." -ForegroundColor White
        Write-Host "    Leave the rectangle drawn + sketch OPEN, then press ENTER here." -ForegroundColor Yellow
        Read-Host

        $beforeFeat = Get-FeatureIdSet
        $stamp = $null; try { $stamp = $script:DJModel.VersionStamp } catch {}
        $changed = $false
        try {
            $script:DJSession.RunMacro((Build-CutFinishMacro -Depth $Depth -BodyIndex $BodyIndex -Flip $curFlip))
            if ($null -ne $stamp) { $changed = Wait-ModelModified -PreviousStamp $stamp -TimeoutMs 30000 }
        } catch { Write-Host "    Macro error on the cut: $($_.Exception.Message)" -ForegroundColor Red }

        if (-not $changed) {
            Write-Host "  The cut did NOT modify the model (rectangle not a closed loop, or widget drift)." -ForegroundColor Red
            return @{ Ok = $false; Flip = $curFlip; FeatId = $null }
        }
        $afterFeat = Get-FeatureIdSet
        $newFeats  = @($afterFeat.Keys | Where-Object { -not $beforeFeat.ContainsKey($_) } | Sort-Object)
        $featId    = if ($newFeats.Count -ge 1) { [int]$newFeats[-1] } else { $null }

        Write-Host ""
        Write-Host "  VERIFY IN CREO: did this slot cut INTO the plate, at the right depth?" -ForegroundColor Magenta
        $ok = Read-Host "    y = correct (keep it, reuse this direction for all rows) / n = wrong (undo + flip + redraw)"
        if ($ok -match '^[Yy]') {
            Write-Host ("  Direction CONFIRMED ($dirWord). Reusing it for the remaining rows.") -ForegroundColor Green
            return @{ Ok = $true; Flip = $curFlip; FeatId = $featId }
        }

        if ($attempt -lt 2) {
            Write-Host "  Flipping the direction. First remove this wrong cut:" -ForegroundColor Yellow
            try { $script:DJSession.RunMacro("~ Command ``ProCmdEditUndo``;") } catch {}
            Write-Host "    (I fired Undo. If the wrong slot is STILL in the model, press Ctrl+Z in Creo now.)" -ForegroundColor Yellow
            Write-Host "    Press ENTER when the wrong slot is gone - you'll redraw with the flipped direction." -ForegroundColor Yellow
            Read-Host
            $curFlip = -not $curFlip
        } else {
            Write-Host "  Both directions tried and neither was confirmed. Leaving the last cut - inspect Creo." -ForegroundColor Yellow
            return @{ Ok = $false; Flip = $curFlip; FeatId = $featId }
        }
    }
}

# ============================================================================
# INDEX-HOLE COORDINATE SYSTEM (csysinator, shared by drilljig.cmd +
# drilljig-gui.cmd + the standalone csysinator.cmd). Moved here 2026-07-13.
# ============================================================================
# The user's flow: after the holes are drilled, they pick ONE hole to be the
# INDEX hole (the origin of a datum coordinate system). Every drilljig grid point
# was created as the INTERSECTION OF 3 mutually-perpendicular planes (STAGE 2.5,
# Build-IntersectPointMacro): SIDE face + an X-offset plane (from TOP) + a Z-offset
# plane (from FRONT). The SAME 3 planes, re-selected and fed to ProCmdDatumCsys,
# create a coordinate system at that intersection point.
#
# THE RECIPE (operator's recorded mapkey 'yes', 2026-07-13): select the 3
# perpendicular planes IN ORDER (X-normal, Y-normal, Z-normal), then
# ProCmdDatumCsys -> stdbtn_1 (OK). This is BYTE-FOR-BYTE the proven 3-plane
# intersection recipe (point-at-3-plane-intersection-by-id + selectbyid-accumulates-
# multiref, confirmed live 2026-06-24) with ProCmdDatumPointGeneral swapped for
# ProCmdDatumCsys. drilljig stores each hole's csys plane triple in X/Y/Z-normal
# order = [X-plane(from TOP), SIDE-face, Z-plane(from FRONT)]: the X-offset plane's
# normal is the model X axis (per the grid contract "X = TOP-direction offset"), the
# Z-offset plane's is Z, and the SIDE face is the Y-normal. NOTE this is a REORDER of
# the point-build order (Build-IntersectPointMacro is called [face, X, Z]); the
# intersection point is order-independent, but the csys axis assignment is not -- so
# the registry deliberately reorders to [X, face, Z] to get X/Y/Z-normal.
#
# NOT YET CONFIRMED LIVE in this by-ID form (the operator's mapkey selected the
# planes via the model tree PHTLeft.AssyTree; here they are fed by tree-search
# select-by-ID, the accumulation channel proven for ProCmdDatumPointGeneral). So
# it is CANARY-GATED (a new feature must appear) and never reports "created" on a
# no-op ([[feedback_canary_must_not_assume_on_failure]]).

# Build-CsysFromPlanesMacro - select the ordered plane triple BY ID (accumulate)
# then ProCmdDatumCsys -> OK. PURE (no COM). The 1st plane clears the buffer, the
# 2nd/3rd accumulate (-NoClear). Order = the caller's PlaneIds order (X/Y/Z-normal).
# ONE atomic RunMacro (a dialog's command context does not survive across calls).
function Build-CsysFromPlanesMacro {
    param([int[]]$PlaneIds)
    $m = (Get-SelectByIdMacro -FeatId $PlaneIds[0])
    for ($i = 1; $i -lt $PlaneIds.Count; $i++) {
        $m += (Get-SelectByIdMacro -FeatId $PlaneIds[$i] -NoClear)
    }
    $m += "~ Command ``ProCmdDatumCsys``;" +
          "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;"
    return $m
}

# Get-CsysShowMacro - unhide the created csys (select by id + ProCmdViewShow), the
# last two lines of the operator's mapkey. PURE.
function Get-CsysShowMacro {
    param([int]$FeatId)
    return (Get-SelectByIdMacro -FeatId $FeatId) +
           "~ Command ``ProCmdViewShow@PopupMenuTree``;"
}

# Resolve-IndexHolePlanes - PURE lookup. Given the drilljig csys registry
# ($Records: each @{ HoleFeatId; PointId; PlaneIds=@(int,int,int) }) and the ids
# resolved from the user's selection ($FeatureIds and $PointIds, both id-only),
# find the record for the picked index hole and return its ordered plane triple.
# Match precedence: HoleFeatId in FeatureIds, then PointId in PointIds, then
# PointId in FeatureIds (a datum-point feature can surface as a feature id).
# Returns @{ Ok; PlaneIds; PointId; HoleFeatId; Reason }. Never throws.
function Resolve-IndexHolePlanes {
    param([array]$Records, [array]$FeatureIds, [array]$PointIds)
    $feat = @{}; foreach ($f in @($FeatureIds)) { try { $feat[[int]$f] = $true } catch {} }
    $pts  = @{}; foreach ($p in @($PointIds))  { try { $pts[[int]$p]  = $true } catch {} }
    if ($null -eq $Records -or @($Records).Count -eq 0) {
        return @{ Ok = $false; PlaneIds = @(); PointId = $null; HoleFeatId = $null; Reason = 'no index registry (predefined points, or points/holes were not tracked this run)' }
    }
    foreach ($rec in $Records) {
        $hf = $null; try { if ($null -ne $rec.HoleFeatId) { $hf = [int]$rec.HoleFeatId } } catch {}
        if ($null -ne $hf -and $feat.ContainsKey($hf)) {
            return @{ Ok = $true; PlaneIds = @($rec.PlaneIds); PointId = $rec.PointId; HoleFeatId = $hf; Reason = 'matched hole feature id' }
        }
        # a hole can create >1 feature (hole + axis/note); match ANY of them so
        # whichever id a tree-click surfaces resolves.
        $hfAll = @()
        try { if ($null -ne $rec.HoleFeatIds) { $hfAll = @($rec.HoleFeatIds | ForEach-Object { [int]$_ }) } } catch {}
        foreach ($h in $hfAll) {
            if ($feat.ContainsKey([int]$h)) {
                return @{ Ok = $true; PlaneIds = @($rec.PlaneIds); PointId = $rec.PointId; HoleFeatId = $rec.HoleFeatId; Reason = 'matched a hole sub-feature id' }
            }
        }
    }
    foreach ($rec in $Records) {
        $pt = $null; try { if ($null -ne $rec.PointId) { $pt = [int]$rec.PointId } } catch {}
        if ($null -ne $pt -and $pts.ContainsKey($pt)) {
            return @{ Ok = $true; PlaneIds = @($rec.PlaneIds); PointId = $pt; HoleFeatId = $rec.HoleFeatId; Reason = 'matched datum point id' }
        }
    }
    foreach ($rec in $Records) {
        $pt = $null; try { if ($null -ne $rec.PointId) { $pt = [int]$rec.PointId } } catch {}
        if ($null -ne $pt -and $feat.ContainsKey($pt)) {
            return @{ Ok = $true; PlaneIds = @($rec.PlaneIds); PointId = $pt; HoleFeatId = $rec.HoleFeatId; Reason = 'matched datum point (selected as a feature)' }
        }
    }
    return @{ Ok = $false; PlaneIds = @(); PointId = $null; HoleFeatId = $null; Reason = 'the selection did not match any drilled index hole / grid point this run' }
}

# Read-IndexSelectionIds - read the current selection buffer into @{ FeatureIds;
# PointIds } (both id-only, deduped, never .Point coords). For each buffered item:
# its own .Id is a candidate feature id; a resolvable GetFeature().Id is added too
# (a hole surface/edge -> its owning feature); ListSubItems(ITEM_POINT) ids feed
# PointIds; an item that IS a datum point feeds PointIds. Reads $script:DJSession/
# DJType. @{ FeatureIds=@(); PointIds=@() } on an empty buffer.
function Read-IndexSelectionIds {
    $featSet = @{}; $ptSet = @{}
    $contents = $null
    try { $contents = ($script:DJSession.CurrentSelectionBuffer()).Contents } catch {}
    if ($null -eq $contents -or $contents.Count -eq 0) { return @{ FeatureIds = @(); PointIds = @() } }
    foreach ($item in $contents) {
        $si = $null
        try { $si = $item.SelItem } catch { continue }
        if ($null -eq $si) { continue }
        # the item's own id (feature id when a feature is picked in the tree)
        try { $featSet[[int]$si.Id] = $true } catch {}
        # owning feature (a picked surface/edge of the hole -> the hole feature)
        try { $ff = $si.GetFeature(); if ($null -ne $ff) { $featSet[[int]$ff.Id] = $true } } catch {}
        # the item IS a datum point
        try { if ([int]$si.Type -eq [int]$script:DJType.ITEM_POINT) { $ptSet[[int]$si.Id] = $true } } catch {}
        # a point-bearing feature -> its contained point ids
        try { foreach ($pt in @($si.ListSubItems($script:DJType.ITEM_POINT))) { try { $ptSet[[int]$pt.Id] = $true } catch {} } } catch {}
    }
    return @{ FeatureIds = @($featSet.Keys); PointIds = @($ptSet.Keys) }
}

# Resolve-HoleFeatGroups - PURE. Split the set of NEW feature ids that appeared
# across the whole drill loop into one contiguous group per hole, in creation order.
# A single hole can add more than one ITEM_FEATURE (the hole + an axis/note), so the
# old "new-feature-count must equal hole-count" tie was skipped whenever a hole added
# extras -> HoleFeatId stayed blank -> clicking the HOLE (vs its datum point) did not
# resolve in STAGE 5. Fix: when the new-feature count is an exact MULTIPLE (k) of the
# hole count, the holes were drilled in $pointIDs order and Creo assigns feature ids
# in ascending creation order, so the sorted ids form N contiguous groups of k. Group
# i belongs to hole i. Returns @{ Ok; Groups (array of int[] per hole); PerHole=k;
# Reason }. Ok=$false (no mis-attribution) when the count is not a clean multiple.
function Resolve-HoleFeatGroups {
    param([int[]]$NewFeatIds, [int]$HoleCount)
    $ids = @(@($NewFeatIds) | ForEach-Object { [int]$_ } | Sort-Object)
    if ($HoleCount -lt 1 -or $ids.Count -lt 1) { return @{ Ok = $false; Groups = @(); PerHole = 0; Reason = 'no new features or no holes' } }
    if (($ids.Count % $HoleCount) -ne 0)       { return @{ Ok = $false; Groups = @(); PerHole = 0; Reason = ("{0} new feature(s) is not a multiple of {1} hole(s)" -f $ids.Count, $HoleCount) } }
    $k = [int]($ids.Count / $HoleCount)
    $groups = @()
    for ($i = 0; $i -lt $HoleCount; $i++) {
        $g = @()
        for ($j = 0; $j -lt $k; $j++) { $g += [int]$ids[$i * $k + $j] }
        $groups += ,@($g)
    }
    return @{ Ok = $true; Groups = @($groups); PerHole = $k; Reason = 'ok' }
}

# Invoke-IndexCsys - COM orchestration: fire Build-CsysFromPlanesMacro for the
# ordered $PlaneIds, gate on a NEW FEATURE appearing (the canary - a csys creation
# adds exactly one feature; a no-op means the macro was silently dropped, so we do
# NOT report success). Optionally show the new csys. Reads $script:DJSession/DJModel/
# DJType. Returns @{ Ok; NewFeatId; NewFeatCount; Reason }.
function Invoke-IndexCsys {
    param([int[]]$PlaneIds, [switch]$Show)
    if ($null -eq $PlaneIds -or @($PlaneIds).Count -lt 3) {
        return @{ Ok = $false; NewFeatId = $null; NewFeatCount = 0; Reason = 'need 3 plane ids' }
    }
    $beforeFeat = Get-FeatureIdSet
    $preStamp = $null; try { $preStamp = [string]$script:DJModel.VersionStamp } catch {}
    Invoke-Macro "index csys: select 3 planes -> ProCmdDatumCsys -> OK" (Build-CsysFromPlanesMacro -PlaneIds $PlaneIds)
    if ($null -ne $preStamp) { [void](Wait-ModelModified -Model $script:DJModel -PreviousStamp $preStamp -TimeoutMs 15000) }
    else { Start-Sleep -Milliseconds 400 }   # no stamp to wait on -> a brief settle so a slow commit isn't misread as a no-op (false negative)
    $afterFeat = Get-FeatureIdSet
    $newFeats  = @($afterFeat.Keys | Where-Object { -not $beforeFeat.ContainsKey($_) } | Sort-Object)
    if ($newFeats.Count -lt 1) {
        return @{ Ok = $false; NewFeatId = $null; NewFeatCount = 0; Reason = 'no new feature appeared (the csys macro was a no-op - inspect Creo / widget drift)' }
    }
    $newId = [int]$newFeats[-1]
    if ($Show) {
        try { $script:DJSession.RunMacro((Get-CsysShowMacro -FeatId $newId)) } catch {}
    }
    return @{ Ok = $true; NewFeatId = $newId; NewFeatCount = $newFeats.Count; Reason = 'created' }
}

# ============================================================================
# BASE COORDINATE SYSTEM (mapkey 1) - the reference csys everything hangs off
# ============================================================================
# Find-DefaultCsysId - the feature id of the part's DEFAULT coordinate system, found
# fully automatically (no user pick). The default csys name varies by template
# (CSYS_PAT_DEF on this build; PRT_CSYS_DEF / ASM_CSYS_DEF / DEFAULT_CSYS / CS0
# elsewhere), so we enumerate the model's ACTUAL coordinate systems (ITEM_COORD_SYS)
# and (1) prefer one whose name matches a known default; (2) else take the FIRST csys
# in the model (the default is created first, so it enumerates first). Only if the
# model exposes NO coordinate system do we scan features by name as a last resort.
# ID-and-name ONLY; never reads geometry.
function Find-DefaultCsysId {
    $preferred = @('CSYS_PAT_DEF','PRT_CSYS_DEF','ASM_CSYS_DEF','DEFAULT_CSYS','CSYS_DEF','CS0')
    $firstCsysFeatId = $null
    try {
        foreach ($c in @($script:DJModel.ListItems($script:DJType.ITEM_COORD_SYS))) {
            # resolve this csys to its owning feature id (fall back to the item id)
            $fid = $null; $ff = $null
            try { $ff = $c.GetFeature(); if ($null -ne $ff) { $fid = [int]$ff.Id } } catch {}
            if ($null -eq $fid) { try { $fid = [int]$c.Id } catch {} }
            if ($null -eq $fid) { continue }
            if ($null -eq $firstCsysFeatId) { $firstCsysFeatId = $fid }   # remember the first as the fallback
            # name (prefer the feature's name; fall back to the item's)
            $nm = $null
            if ($null -ne $ff) { try { $nm = [string]$ff.GetName() } catch {} }
            if (-not $nm) { try { $nm = [string]$c.GetName() } catch {} }
            if ($nm -and ($preferred -contains $nm.ToUpper())) { return $fid }   # a known default -> use it
        }
    } catch {}
    if ($null -ne $firstCsysFeatId) { return $firstCsysFeatId }   # no known-name match -> first csys in the model
    # last resort: the model exposed no ITEM_COORD_SYS -> a FEATURE named like a default csys
    try {
        foreach ($f in @($script:DJModel.ListItems($script:DJType.ITEM_FEATURE))) {
            $nm = $null; try { $nm = [string]$f.GetName() } catch {}
            if ($nm -and ($preferred -contains $nm.ToUpper())) { try { return [int]$f.Id } catch {} }
        }
    } catch {}
    return $null
}

# Build-CsysFromCsysMacro - PURE. mapkey 1: select the reference csys BY ID ->
# ProCmdDatumCsys -> OK. The one-reference analog of Build-CsysFromPlanesMacro.
function Build-CsysFromCsysMacro {
    param([int]$RefCsysId)
    return (Get-SelectByIdMacro -FeatId $RefCsysId) +
        "~ Command ``ProCmdDatumCsys``;" +
        "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;"
}

# Invoke-BaseCsys - fire Build-CsysFromCsysMacro, GATE on a NEW feature (canary),
# return @{ Ok; CsysFeatId; Reason }. The base csys everything is offset from.
function Invoke-BaseCsys {
    param([int]$RefCsysId, [switch]$Show)
    if ($RefCsysId -le 0) { return @{ Ok = $false; CsysFeatId = $null; Reason = 'no reference csys id (no default coordinate system found)' } }
    $beforeFeat = Get-FeatureIdSet
    $preStamp = $null; try { $preStamp = [string]$script:DJModel.VersionStamp } catch {}
    Invoke-Macro "base csys: from ref csys $RefCsysId -> ProCmdDatumCsys -> OK" (Build-CsysFromCsysMacro -RefCsysId $RefCsysId)
    if ($null -ne $preStamp) { [void](Wait-ModelModified -Model $script:DJModel -PreviousStamp $preStamp -TimeoutMs 15000) } else { Start-Sleep -Milliseconds 400 }
    $afterFeat = Get-FeatureIdSet
    $newFeats  = @($afterFeat.Keys | Where-Object { -not $beforeFeat.ContainsKey($_) } | Sort-Object)
    if ($newFeats.Count -lt 1) { return @{ Ok = $false; CsysFeatId = $null; Reason = 'no new feature appeared (base csys not created)' } }
    $newId = [int]$newFeats[-1]
    if ($Show) { try { $script:DJSession.RunMacro((Get-CsysShowMacro -FeatId $newId)) } catch {} }
    return @{ Ok = $true; CsysFeatId = $newId; Reason = 'created' }
}

# ============================================================================
# TRANSFORM RE-IMPORT (mapkey 3) - re-reference the base csys onto the index hole
# ============================================================================
# After the index csys exists, capture the transform between the base csys and the
# index csys (Analysis -> Transform tool), save it to a file, then REDEFINE the base
# csys with OffsetType=file importing that transform -> the base csys (and every
# plane/point/hole hung off it) relocates to the index hole.
#
# *** LIVE-UNVERIFIED / FRAGILE. Transcribed faithfully from the operator's recorded
# *** mapkey, but it drives file Save-As / Open dialogs (Desktop) and the recording
# *** had a @PAUSE_FOR_SCREEN_PICK (which a RunMacro cannot replay, so it is omitted
# *** here). The Save-As uses Creo's DEFAULT filename to the Desktop and the reimport
# *** opens from the Desktop; wiring a specific $TrfPath filename + the pause are the
# *** expected live-tuning points. Invoke-CsysTransformReimport CANARY-GATES on the
# *** model changing and reports UNVERIFIED - never a false green.

# Build-CsysTransformExportMacro - PURE. Select index + base csys (accumulated BY ID),
# open the Measure>Transform analysis tool, produce the transform info, Save-As to the
# Desktop (default filename), exit the tool, close the text window. (mapkey 3, first half.)
# WIDGET SEQUENCE RECONCILED against the operator's live recording 2026-07-15
# (csystrf-probe.cmd -> csystrf_recipe.txt): the real command is ProCmdNaMeasureTransform
# (NOT ProCmdNmdTool) and it opens DIRECTLY into transform mode -- there is NO
# page_Analysis_control_btn activation and NO nmd_type_rg='Transform' selection (both were
# earlier GUESSES, now removed). The two csys are consumed from the pre-selection (the
# recording tree-selected them; we feed them by ID, the proven accumulate pattern). Exit is
# nmd_exit_pb THEN '~ Close texttool texttool' (the earlier 'texttool CloseButton' was wrong).
# NOTE: the Save-As types NO filename in the recording -> Creo writes its DEFAULT name to the
# Desktop, and the reimport opens that default (see Build-CsysReimportMacro); $TrfPath stays
# advisory (logged only). Reference ORDER (index-then-base) sets the transform direction --
# a live-verify item if the base moves the wrong way.
function Build-CsysTransformExportMacro {
    param([int]$IndexCsysId, [int]$BaseCsysId)
    return (Get-SelectByIdMacro -FeatId $IndexCsysId) +
        (Get-SelectByIdMacro -FeatId $BaseCsysId -NoClear) +
        "~ Command ``ProCmdNaMeasureTransform``;" +
        "~ Trigger ``nmd_1`` ``nmd_setup_tbl`` 2 ``0`` ``References``;" +
        "~ Trigger ``nmd_1`` ``nmd_setup_tbl`` 2 ```` ````;" +
        "~ Activate ``nmd_1`` ``nmd_info_pb``;" +
        "~ Select ``texttool`` ``MenuBar`` 1 ``FileMenu``;" +
        "~ Close ``texttool`` ``MenuBar``;" +
        "~ Activate ``texttool`` ``SaveAsPushButton``;" +
        "~ Activate ``file_saveas`` ``desktop_pb``;" +
        "~ Activate ``file_saveas`` ``OK``;" +
        "~ Activate ``nmd_1`` ``nmd_exit_pb``;" +
        "~ Close ``texttool`` ``texttool``;"
}

# Build-CsysReimportMacro - PURE. Redefine the base csys, switch its placement to
# OffsetType=file, open the transform file from the Desktop, OK. (mapkey 3, 2nd half.)
function Build-CsysReimportMacro {
    param([int]$BaseCsysId)
    return (Get-SelectByIdMacro -FeatId $BaseCsysId) +
        "~ Command ``ProCmdRedefine@PopupMenuTree``;" +
        "~ Open  ``Odui_Dlg_00`` ``t1.OffsetType``;" +
        "~ Close ``Odui_Dlg_00`` ``t1.OffsetType``;" +
        "~ Select ``Odui_Dlg_00`` ``t1.OffsetType`` 1 ``file``;" +
        "~ Activate ``file_open`` ``desktop_pb``;" +
        "~ Command ``ProFileSelPushOpen_Standard@context_dlg_open_cmd``;" +
        "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;"
}

# Invoke-CsysTransformReimport - fire the export then the reimport, canary on the
# model changing (the base-csys redefine mutates it). Returns @{ Ok; Reason }. The
# $TrfPath is advisory (logged); the macros use the recorded Desktop/default-name flow.
function Invoke-CsysTransformReimport {
    param([int]$BaseCsysId, [int]$IndexCsysId, [string]$TrfPath = '')
    if ($BaseCsysId -le 0 -or $IndexCsysId -le 0) { return @{ Ok = $false; Reason = 'need base + index csys ids' } }
    $preStamp = $null; try { $preStamp = [string]$script:DJModel.VersionStamp } catch {}
    Invoke-Macro "transform export (index $IndexCsysId vs base $BaseCsysId)$(if ($TrfPath) { " -> $TrfPath" })" (Build-CsysTransformExportMacro -IndexCsysId $IndexCsysId -BaseCsysId $BaseCsysId)
    Start-Sleep -Milliseconds 500
    Invoke-Macro "reimport transform into base csys $BaseCsysId (OffsetType=file)" (Build-CsysReimportMacro -BaseCsysId $BaseCsysId)
    $changed = $false
    if ($null -ne $preStamp) { $changed = Wait-ModelModified -Model $script:DJModel -PreviousStamp $preStamp -TimeoutMs 20000 }
    if (-not $changed) {
        return @{ Ok = $false; Reason = 'model did not change - transform export/reimport was a no-op (UNVERIFIED widgets: Analysis Transform tool + file Save-As/Open dialogs + the omitted screen-pick pause need live tuning)' }
    }
    return @{ Ok = $true; Reason = 're-referenced (verify the whole jig followed the base csys)' }
}

# Invoke-OutputCsys - build a ROBUST, INDEPENDENT coordinate system AT the index hole,
# referenced off the part DEFAULT csys (CSYS_PAT_DEF), NOT off the grid planes or the
# base csys. This is the SAFE, cycle-free way to deliver "the frame at the index hole":
# it creates a real datum coordinate-system FEATURE at the index hole that downstream
# machining/CMM can target, WITHOUT moving any geometry and WITHOUT the info.trf leg.
# ----------------------------------------------------------------------------
# The base csys is created coincident with CSYS_PAT_DEF, so the index hole is at design
# coords (GridX, GridY, GridZ) relative to CSYS_PAT_DEF. Three planes off CSYS_PAT_DEF at
# those offsets intersect exactly there; Build-CsysFromPlanesMacro (the live-confirmed
# 3-plane->ProCmdDatumCsys recipe) turns them into the csys. It references only
# CSYS_PAT_DEF + literal offsets -> it is a SIBLING of the base under CSYS_PAT_DEF, never
# a descendant of the base/grid, so nothing can cycle and it survives grid edits.
#
# THE Y (through-thickness) ANCHOR -- MUST be off CSYS_PAT_DEF Axis_Y for AXIS ALIGNMENT:
#   The index csys is intersected from the 3 anchor planes, and Creo derives its axis
#   DIRECTIONS from those planes' NORMALS. X/Z anchors off CSYS_PAT_DEF have deterministic
#   +X/+Z normals. The Y anchor's normal must ALSO be a deterministic +Y for the resulting
#   csys to come out model-aligned (+X,+Y,+Z, right-handed) -- which is what makes the
#   grid-plane OFFSET DIRECTION correct for any index hole.
#   *** DO NOT anchor Y off the SIDE default datum (the old -YBaseId path): a default datum's
#   *** normal SIGN is PART-SPECIFIC (+Y on some parts, -Y on others). A -Y makes (+X,-Y,+Z)
#   *** LEFT-handed, so Creo flips X or Z to restore right-handedness -> the csys is SOMETIMES
#   *** mirrored -> the offset direction is sometimes wrong (the 2026-07-17 bug). Anchoring Y
#   *** off CSYS_PAT_DEF Axis_Y @ GridY (always +Y) keeps the triple consistent -> aligned axes
#   *** every time (the same alignment the Invoke-BaseCsys copy gets). The Y ORIGIN then sits
#   *** at GridY off CSYS_PAT_DEF (pass 0 = the model-origin plane), NOT necessarily on the
#   *** plate face -- but the Y position is COSMETIC: it does not affect hole X/Z (those come
#   *** from the Axis_X/Axis_Z grid planes + the SIDE-datum-pinned points) nor the STAGE-6
#   *** export (Y_index = 0 for every hole). To sit the csys on the plate face WITH aligned
#   *** axes needs an offset-COORDINATE-SYSTEM (translate CSYS_PAT_DEF preserving axes), an
#   *** unrecorded dialog -- a follow-up if wanted. -YBaseId is RETAINED for compat but the
#   *** index-first callers no longer pass it (they must not, per the above).
# Returns @{ Ok; CsysFeatId; Reason; AnchorPlaneIds }. Canary-gated (Invoke-IndexCsys).
function Invoke-OutputCsys {
    param([int]$RefCsysId, [double]$GridX, [double]$GridZ, [double]$GridY = 0.0, $YBaseId = $null)
    if ($RefCsysId -le 0) { return @{ Ok = $false; CsysFeatId = $null; Reason = 'need the default (CSYS_PAT_DEF) csys id'; AnchorPlaneIds = @() } }
    # X + Z anchors off CSYS_PAT_DEF at the index hole's grid coords.
    $px = New-CsysOffsetPlane -CsysFeatId $RefCsysId -Axis 'X' -Offset ([double]$GridX) -SkipSymbolWait
    $pz = New-CsysOffsetPlane -CsysFeatId $RefCsysId -Axis 'Z' -Offset ([double]$GridZ) -SkipSymbolWait
    # Y anchor at the extrude-depth face: off the SIDE default datum @ GridY when its id
    # is known (the plate's own frame), else Axis_Y @ GridY off the csys (legacy fallback).
    if ($null -ne $YBaseId -and [int]$YBaseId -gt 0) {
        $py = New-OffsetPlane -Label "IdxY" -Offset ([double]$GridY) -BaseId ([int]$YBaseId) -SkipSymbolWait
    } else {
        $py = New-CsysOffsetPlane -CsysFeatId $RefCsysId -Axis 'Y' -Offset ([double]$GridY) -SkipSymbolWait
    }
    if ($null -eq $px.FeatId -or $null -eq $py.FeatId -or $null -eq $pz.FeatId) {
        return @{ Ok = $false; CsysFeatId = $null; Reason = 'could not create the 3 independent anchor planes (X/Z off CSYS_PAT_DEF, Y at the extrude depth)'; AnchorPlaneIds = @() }
    }
    # planeIds stay in X/Y/Z-normal order for the csys axis assignment.
    $planeIds = @([int]$px.FeatId, [int]$py.FeatId, [int]$pz.FeatId)
    # intersect them into the output csys (canary-gated on a new feature)
    $csys = Invoke-IndexCsys -PlaneIds $planeIds -Show
    if (-not $csys.Ok) { return @{ Ok = $false; CsysFeatId = $null; Reason = "independent output csys not created: $($csys.Reason)"; AnchorPlaneIds = $planeIds } }
    return @{ Ok = $true; CsysFeatId = [int]$csys.NewFeatId; Reason = 'created (independent; Y at extrude depth)'; AnchorPlaneIds = $planeIds }
}

# Invoke-IndependentReref - reref-method 'independent' (an ALTERNATIVE to the default
# 'transform'). Builds an anchor csys off CSYS_PAT_DEF at the index hole (Invoke-OutputCsys)
# then TRANSFORMS the base csys onto that anchor via the info.trf leg.
# ----------------------------------------------------------------------------
# The DEFAULT method is 'transform' (Invoke-CsysTransformReimport): change the base csys's
# coordinate-system TYPE to OffsetType=file importing the base->index transform. That is
# NOT a reference cycle -- OffsetType=file bakes a STATIC matrix relative to the base's
# parent (CSYS_PAT_DEF); the file is DATA, not a live feature reference to the index csys
# (the index csys is only READ to compute the matrix, then frozen). This 'independent'
# variant just targets an anchor off CSYS_PAT_DEF instead of the index csys directly --
# useful if targeting the index csys ever misbehaves live. Both are acyclic.
#
# *** LIVE-VERIFY caveat (drilljig-no-single-movable-parent): the plate is sketched on the
# *** SIDE DEFAULT DATUM ($sketchPlaneId = SIDE BaseId) while the holes hang off the base
# *** csys, so how the plate footprint behaves under a base transform is an unverified live
# *** question -- if it misbehaves, use reref-method 'output-csys' (a separate index-hole
# *** datum, no move). Also still LIVE-UNVERIFIED for the info.trf transform leg.
# Returns @{ Ok; Reason; AnchorCsysId }.
function Invoke-IndependentReref {
    param([int]$RefCsysId, [int]$BaseCsysId, [double]$GridX, [double]$GridZ, [string]$TrfPath = '')
    if ($RefCsysId -le 0 -or $BaseCsysId -le 0) { return @{ Ok = $false; Reason = 'need the default (CSYS_PAT_DEF) + base csys ids'; AnchorCsysId = $null } }
    # 1+2. build the independent anchor csys at the index hole (off CSYS_PAT_DEF)
    $anchor = Invoke-OutputCsys -RefCsysId $RefCsysId -GridX $GridX -GridZ $GridZ
    if (-not $anchor.Ok) { return @{ Ok = $false; Reason = $anchor.Reason; AnchorCsysId = $anchor.CsysFeatId } }
    # 3. transform the base onto the anchor (acyclic: anchor is off CSYS_PAT_DEF)
    $rr = Invoke-CsysTransformReimport -BaseCsysId $BaseCsysId -IndexCsysId ([int]$anchor.CsysFeatId) -TrfPath $TrfPath
    return @{ Ok = $rr.Ok; Reason = $rr.Reason; AnchorCsysId = [int]$anchor.CsysFeatId }
}

# ============================================================================
# EXPORT hole coordinates relative to the index coordinate system
# ============================================================================
# After the index csys is created (STAGE 5), export every drilled hole's coordinate
# IN THE INDEX CSYS FRAME. NO COM coordinate read (IpfcPoint.Point crashes on this
# build): we already know each hole's design coordinate from the grid layout, and the
# index csys was placed AT the index hole with axes aligned to the grid --
#   csys X  ||  grid X  (the X-offset plane's normal),
#   csys Z  ||  grid Z  (the Z-offset plane's normal),
#   csys Y  =   through-thickness (0 for every hole -- they all sit on the SIDE face).
# So a hole's csys coordinate is exactly (gridX - indexX, 0, gridZ - indexZ). Axis
# SIGNS follow the csys orientation (verified visually); the deltas are exact from the
# design layout, not a fragile measured read.

# Get-HolesRelativeToIndex - PURE (no COM). $Records = the csys registry (each with
# PointId + GridX + GridZ, optionally HoleFeatId); $IndexPointId = the picked index
# hole's datum-point id. Returns @{ Ok; Rows; Reason }, one row per hole with its
# coordinate relative to the index hole. Never throws.
function Get-HolesRelativeToIndex {
    param([array]$Records, $IndexPointId, [double]$Diameter = 0.0)
    if ($null -eq $Records -or @($Records).Count -eq 0) { return @{ Ok = $false; Rows = @(); Reason = 'no hole records to export' } }
    $idxRec = $null
    foreach ($r in $Records) { try { if ($null -ne $r.PointId -and [int]$r.PointId -eq [int]$IndexPointId) { $idxRec = $r; break } } catch {} }
    if ($null -eq $idxRec) { return @{ Ok = $false; Rows = @(); Reason = ("index point id {0} is not in the registry" -f $IndexPointId) } }
    $ix = 0.0; $iz = 0.0
    try { $ix = [double]$idxRec.GridX } catch {}
    try { $iz = [double]$idxRec.GridZ } catch {}
    $rows = @(); $n = 0
    foreach ($r in $Records) {
        $n++
        $gx = 0.0; $gz = 0.0
        try { $gx = [double]$r.GridX } catch {}
        try { $gz = [double]$r.GridZ } catch {}
        $isIdx = $false
        try { $isIdx = ($null -ne $r.PointId -and [int]$r.PointId -eq [int]$IndexPointId) } catch {}
        $hfid = $null; try { $hfid = $r.HoleFeatId } catch {}
        $rows += [pscustomobject]@{
            Hole        = $n
            PointId     = $r.PointId
            HoleFeatId  = $hfid
            X_index     = [math]::Round($gx - $ix, 6)
            Y_index     = 0.0
            Z_index     = [math]::Round($gz - $iz, 6)
            GridX       = [math]::Round($gx, 6)
            GridZ       = [math]::Round($gz, 6)
            Diameter    = [math]::Round([double]$Diameter, 6)
            IsIndexHole = $isIdx
        }
    }
    return @{ Ok = $true; Rows = @($rows); Reason = 'ok' }
}

# Export-IndexHoleCsv - build the rows (Get-HolesRelativeToIndex) and write a CSV.
# Returns @{ Ok; Path; Count; Reason }. The only IO is one Export-Csv.
function Export-IndexHoleCsv {
    param([array]$Records, $IndexPointId, [double]$Diameter, [string]$Path)
    $res = Get-HolesRelativeToIndex -Records $Records -IndexPointId $IndexPointId -Diameter $Diameter
    if (-not $res.Ok) { return @{ Ok = $false; Path = $Path; Count = 0; Reason = $res.Reason } }
    try {
        @($res.Rows) | Export-Csv -NoTypeInformation -Path $Path -Encoding UTF8
    } catch {
        return @{ Ok = $false; Path = $Path; Count = 0; Reason = ("could not write CSV: {0}" -f $_.Exception.Message) }
    }
    return @{ Ok = $true; Path = $Path; Count = @($res.Rows).Count; Reason = 'ok' }
}

# Format-IndexHoleReport - PURE. Turn the hole rows (Get-HolesRelativeToIndex output)
# + provenance metadata into a human-readable, inspection-friendly text report (a
# provenance header + an aligned table). Keeps the CSV strictly tabular for machines
# while this sidecar is for people / travelers. $Meta keys (all optional):
# PartNumber, CsysFeatId, Units, WhenIso. The index hole (IsIndexHole) supplies the
# origin point id + grid coords in the header. Returns the report string. No IO.
function Format-IndexHoleReport {
    param([array]$Rows, [hashtable]$Meta = @{})
    $part  = if ($Meta.ContainsKey('PartNumber') -and $Meta.PartNumber) { [string]$Meta.PartNumber } else { '(unknown)' }
    $csys  = if ($Meta.ContainsKey('CsysFeatId') -and $null -ne $Meta.CsysFeatId) { [string]$Meta.CsysFeatId } else { '(unknown)' }
    $units = if ($Meta.ContainsKey('Units') -and $Meta.Units) { [string]$Meta.Units } else { 'model units' }
    $when  = if ($Meta.ContainsKey('WhenIso') -and $Meta.WhenIso) { [string]$Meta.WhenIso } else { '(not stamped)' }
    $rows  = @($Rows)
    $idxRow = @($rows | Where-Object { $_.IsIndexHole }) | Select-Object -First 1
    $idxDesc = if ($null -ne $idxRow) { ("point {0}  (grid {1}, {2})" -f $idxRow.PointId, $idxRow.GridX, $idxRow.GridZ) } else { '(none)' }
    $others  = @($rows | Where-Object { -not $_.IsIndexHole }).Count

    $nl = [Environment]::NewLine
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("Drill-jig hole coordinates -- relative to the index coordinate system")
    [void]$sb.AppendLine("=====================================================================")
    [void]$sb.AppendLine(("Part number  : {0}" -f $part))
    [void]$sb.AppendLine(("Generated    : {0}" -f $when))
    [void]$sb.AppendLine(("Csys feature : {0}" -f $csys))
    [void]$sb.AppendLine(("Index hole   : {0}" -f $idxDesc))
    [void]$sb.AppendLine(("Units        : {0}" -f $units))
    [void]$sb.AppendLine(("Holes        : {0}  ({1} index + {2} other)" -f $rows.Count, $(if ($null -ne $idxRow) { 1 } else { 0 }), $others))
    [void]$sb.AppendLine("Axis frame   : X along grid X, Z along grid Z, Y = through-thickness (0 for holes on the face).")
    [void]$sb.AppendLine("               Origin is the index hole. Verify axis SIGNS against the created csys.")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine(("  {0,4}  {1,8}  {2,10}  {3,10}  {4,10}  {5,9}  {6}" -f 'Hole','PointId','X_index','Y_index','Z_index','Diameter','Index'))
    [void]$sb.AppendLine("  ----  --------  ----------  ----------  ----------  ---------  -----")
    foreach ($r in $rows) {
        $flag = if ($r.IsIndexHole) { 'YES' } else { '' }
        [void]$sb.AppendLine(("  {0,4}  {1,8}  {2,10:0.0000}  {3,10:0.0000}  {4,10:0.0000}  {5,9:0.0000}  {6}" -f `
            $r.Hole, $r.PointId, [double]$r.X_index, [double]$r.Y_index, [double]$r.Z_index, [double]$r.Diameter, $flag))
    }
    return $sb.ToString()
}

# Write-IndexHoleReport - build the rows + format the report + write it to $Path.
# Returns @{ Ok; Path; Count; Reason }. One Set-Content IO.
function Write-IndexHoleReport {
    param([array]$Records, $IndexPointId, [double]$Diameter, [hashtable]$Meta = @{}, [string]$Path)
    $res = Get-HolesRelativeToIndex -Records $Records -IndexPointId $IndexPointId -Diameter $Diameter
    if (-not $res.Ok) { return @{ Ok = $false; Path = $Path; Count = 0; Reason = $res.Reason } }
    try {
        $text = Format-IndexHoleReport -Rows @($res.Rows) -Meta $Meta
        Set-Content -Path $Path -Value $text -Encoding UTF8
    } catch {
        return @{ Ok = $false; Path = $Path; Count = 0; Reason = ("could not write report: {0}" -f $_.Exception.Message) }
    }
    return @{ Ok = $true; Path = $Path; Count = @($res.Rows).Count; Reason = 'ok' }
}

# ============================================================================
# CSYS-REFERENCED DATUM POINTS (STAGE 7) - create datum points OFFSET FROM the
# index csys at the exported coordinates, so the points are parametrically tied to
# that coordinate system (Creo: Datum Point -> "Offset Coordinate System", pick the
# csys, Cartesian, type an X/Y/Z table).
#
# *** WIDGET NAMES UNVERIFIED - BEST GUESS. THIS DIALOG HAS NOT BEEN RECORDED.   ***
# *** Treat exactly like the old Build-PointGridMacro: fire it, GATE it on a NEW ***
# *** point actually appearing (Invoke-CsysOffsetPoints canary), and if nothing  ***
# *** is created, print the RECORD-LIVE recipe and STOP -- never claim success.  ***
#
# RECORD-LIVE RECIPE to lock the widgets (do ONCE, then transcribe below):
#   1. Creo: config.pro visible_mapkeys = yes ; Apply. Note the active trail.txt.N.
#   2. Pre-select the index csys in the model tree.
#   3. Model > Datum > Point > Offset Coordinate System. Pick the csys as the
#      reference; set the dropdown to Cartesian.
#   4. Add a row, type a known X/Y/Z (e.g. 1 / 0 / 2). Add a SECOND row with a
#      different X/Y/Z so the row index + column tokens are unambiguous. Click OK.
#   5. Copy every ~ Command/Open/Close/Select/Update/Input/Activate/Trigger line
#      from the newest trail (drop ~ Trail/Timer/Move noise) and replace the guessed
#      tokens below, keeping the whole open->table->OK as ONE atomic RunMacro.

# Build-CsysOffsetPointsMacro - PURE. Select the csys BY ID, open the datum-point
# tool in Offset-Coordinate-System mode, add one table row per coordinate (Cartesian
# X/Y/Z), OK. ONE atomic RunMacro. $Rows: objects with .X_index/.Y_index/.Z_index
# (the Get-HolesRelativeToIndex output). GUESSED widgets flagged above.
function Build-CsysOffsetPointsMacro {
    param([int]$CsysFeatId, [array]$Rows)
    $m = (Get-SelectByIdMacro -FeatId $CsysFeatId) +
        "~ Command ``ProCmdDatumPoint``;" +
        "~ Open  ``Odui_Dlg_00`` ``t1.PntTypeOptMenu``;" +
        "~ Close ``Odui_Dlg_00`` ``t1.PntTypeOptMenu``;" +
        "~ Select ``Odui_Dlg_00`` ``t1.PntTypeOptMenu`` 1 ``Offset Coordinate System``;"
    $r = 0
    foreach ($row in @($Rows)) {
        $x = [double]$row.X_index; $y = [double]$row.Y_index; $z = [double]$row.Z_index
        $m += "~ Activate ``Odui_Dlg_00`` ``t1.add_pnt_btn``;" +
              "~ Update  ``Odui_Dlg_00`` ``t1.pnt_table`` $r ``xax`` ``$x``;" +
              "~ Update  ``Odui_Dlg_00`` ``t1.pnt_table`` $r ``yax`` ``$y``;" +
              "~ Update  ``Odui_Dlg_00`` ``t1.pnt_table`` $r ``zax`` ``$z``;"
        $r++
    }
    $m += "~ Activate ``Odui_Dlg_00`` ``stdbtn_1``;"
    return $m
}

# Invoke-CsysOffsetPoints - fire Build-CsysOffsetPointsMacro (ONE RunMacro) and GATE
# on new datum points actually appearing (before/after ITEM_POINT diff -- never
# "macro fired"). NO reads between the macro and the count (one RunMacro, one diff).
# Returns @{ Ok; Created; Expected; Reason }. Reads $script:DJSession/DJModel/DJType.
function Invoke-CsysOffsetPoints {
    param([int]$CsysFeatId, [array]$Rows)
    $expected = @($Rows).Count
    if ($CsysFeatId -le 0 -or $expected -lt 1) {
        return @{ Ok = $false; Created = 0; Expected = $expected; Reason = 'need a csys feature id and at least one row' }
    }
    $before = Get-PointIdSet -Model $script:DJModel -TypeObj $script:DJType
    $stamp  = $null; try { $stamp = [string]$script:DJModel.VersionStamp } catch {}
    Invoke-Macro "csys-referenced datum points ($expected)" (Build-CsysOffsetPointsMacro -CsysFeatId $CsysFeatId -Rows $Rows)
    if ($null -ne $stamp) { [void](Wait-ModelModified -Model $script:DJModel -PreviousStamp $stamp -TimeoutMs 20000) }
    $new = @(Resolve-NewPointIds -Model $script:DJModel -TypeObj $script:DJType -Before $before)
    if (@($new).Count -lt 1) {
        return @{ Ok = $false; Created = 0; Expected = $expected; Reason = 'no new datum point appeared (the offset-csys dialog widgets are UNVERIFIED - record the mapkey; see Build-CsysOffsetPointsMacro header)' }
    }
    $ok = (@($new).Count -eq $expected)
    return @{ Ok = $ok; Created = @($new).Count; Expected = $expected; Reason = $(if ($ok) { 'ok' } else { 'point count did not match the coordinate count - inspect Creo' }) }
}
