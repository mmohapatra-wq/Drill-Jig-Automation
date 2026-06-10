<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "PARAM-PROBE"
$ErrorActionPreference = "Stop"

# ============================================================================
# PARAM-PROBE  (boxinator-parametric branch — EXPERIMENT, not production)
# ============================================================================
# Goal: find out whether PowerShell can drive a box dimension PARAMETRICALLY
# via the VB API — i.e. change width/height/depth WITHOUT mapkeys, sketch
# picking, or the gated sketch-open repair boxinator currently needs.
#
# The wall (per CLAUDE.md): a raw $dim.DimValue write STICKS for feature-level
# dims (depth) but SNAPS BACK on regen for SKETCH dims (width/height). The VB
# API exposes no "modify sketch dim" that survives regen.
#
# The hypothesis this probe tests: a RELATION is authoritative — Creo re-asserts
# it on EVERY regen. So if we make the sketch dim DRIVEN by a relation
# (`d3 = PARAM_d3`), the regen that normally snaps the dim back should instead
# re-drive it to the parameter's value. Change the PARAMETER from PowerShell and
# the dim should follow. That is true parametric control.
#
# Confirmed available from the Creo 12.4.3.0 VB example pfcRelationsExamples.vb:
#   - feature.CreateParam(name, CreateDoubleParamValue(v))   (IpfcParameterOwner)
#   - CType(owner, IpfcRelationOwner).Relations = <Cstringseq>   <-- .Relations IS settable
#   - relations.Append("d3 = PARAM_d3")
# Model, feature, surface, edge all inherit IpfcParameterOwner AND IpfcRelationOwner,
# so we drive everything at MODEL scope (simplest: param + relation both on the part).
#
# This probe is NON-DESTRUCTIVE to existing relations: it reads the current
# relation set, drops only any relation whose left-hand side is the dim we're
# driving, keeps the rest, and adds ours.
#
# PREREQ: a part with at least one box already open in Creo. Run with ONE Creo
# session open (no multi-session picker here — this is a probe).
# ============================================================================

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

# ---------------------------------------------------------------------------
# COM construction helpers with ProgID fallbacks.
# The CC*/CM* "factory" class names from the docs are NOT standalone ProgIDs
# (see CLAUDE.md). Sequence + utility classes are reached under one of a few
# pfcls ProgIDs depending on the build, so we try a list and keep the first
# that constructs.
# ---------------------------------------------------------------------------
function New-FirstCom {
    param([string[]]$ProgIds)
    foreach ($id in $ProgIds) {
        try {
            $o = New-Object -ComObject $id
            if ($null -ne $o) { return @{ Obj = $o; ProgId = $id } }
        } catch {}
    }
    return $null
}

# Build a double IpfcParamValue. The example uses (New CMpfcModelItem).CreateDoubleParamValue(v).
# CMpfcModelItem is a utility class; try its likely ProgID projections.
function New-DoubleParamValue {
    param([double]$Value)
    $util = New-FirstCom @("pfcls.CMpfcModelItem", "pfcls.MpfcModelItem", "pfcls.pfcModelItem")
    if ($null -eq $util) { throw "Could not construct a CMpfcModelItem utility object (tried CMpfcModelItem / MpfcModelItem / pfcModelItem)." }
    Write-Host "    [diag] param-value utility ProgID = $($util.ProgId)" -ForegroundColor DarkGray
    return $util.Obj.CreateDoubleParamValue($Value)
}

# Get an EMPTY Cstringseq to hold relation strings.
# The standalone ProgID for Cstringseq is unreliable across builds, so the
# robust path is to reuse the live sequence object that $Owner.Relations already
# hands back (guaranteed-correct COM type) and .Clear() it. We only fall back to
# constructing one (e.g. when the owner has no relations yet, so .Relations is null).
# Naming rule confirmed live: VB "CMpfcModelItem" -> ProgID "pfcls.MpfcModelItem"
# (leading C dropped), so "Cstringseq" -> "pfcls.stringseq".
function New-StringSeq {
    param($Owner)
    try {
        $live = $Owner.Relations
        if ($null -ne $live) {
            $live.Clear()
            Write-Host "    [diag] string-seq source = live `$Owner.Relations (cleared & reused)" -ForegroundColor DarkGray
            return $live
        }
    } catch {}
    $seq = New-FirstCom @("pfcls.stringseq", "pfcls.Stringseq", "pfcls.Cstringseq", "pfcls.CStringseq", "pfcls.pfcStringseq")
    if ($null -eq $seq) { throw "Could not obtain a Cstringseq: `$Owner.Relations was null and no stringseq ProgID constructed." }
    Write-Host "    [diag] string-seq ProgID = $($seq.ProgId)" -ForegroundColor DarkGray
    return $seq.Obj
}

# Read $owner.Relations into a plain string[] (or @() if none/null).
function Read-Relations {
    param($Owner)
    $out = @()
    try {
        $rel = $Owner.Relations
        if ($null -ne $rel) {
            for ($i = 0; $i -lt $rel.Count; $i++) {
                try { $out += [string]$rel.Item($i) } catch {}
            }
        }
    } catch {}
    return $out
}

# Left-hand side of a relation line, lowercased/trimmed (text before first '=' that is not '==').
function Get-RelationLhs {
    param([string]$Line)
    $eq = $Line.IndexOf('=')
    if ($eq -lt 1) { return $null }
    return $Line.Substring(0, $eq).Trim().ToLower()
}

# ============================================
# HEADER
# ============================================
Write-Host ""
Write-Host "  PARAM-PROBE — parametric dimension experiment" -ForegroundColor Cyan
Write-Host "  (boxinator-parametric branch — does NOT modify boxinator.cmd)" -ForegroundColor DarkGray
Write-Host ""

# ============================================
# CONNECT (single session)
# ============================================
$procs = @(Get-Process | Where-Object { $_.ProcessName -eq "xtop" })
if ($procs.Count -eq 0) { throw "Creo (xtop.exe) is not running" }
if ($procs.Count -gt 1) {
    throw "More than one Creo session is open. This probe expects exactly ONE (no session picker here)."
}
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
if ($null -eq $model) { throw "No active model. Open a part with a box first." }

Write-Host "  Connected. Active model: $($model.FileName)" -ForegroundColor Green
Write-Host ""

try {

$pfcType = New-Object -ComObject pfcls.pfcModelItemType

# ============================================
# 1. ENUMERATE LINEAR DIMENSIONS
# ============================================
# ListItems(ITEM_DIMENSION) is the proven Solid-model path (gauginator/diminator).
# Filter to Linear (DimType 0) — width/height/depth are all Linear.
$dims = @()
foreach ($d in $model.ListItems($pfcType.ITEM_DIMENSION)) {
    try {
        if ($d.DimType -eq 0) {
            $dims += [pscustomobject]@{ Symbol = [string]$d.Symbol; Value = [double]$d.DimValue }
        }
    } catch {}
}
if ($dims.Count -eq 0) { throw "No Linear dimensions found on the model." }

Write-Host "  Linear dimensions on the model:" -ForegroundColor Green
for ($i = 0; $i -lt $dims.Count; $i++) {
    Write-Host ("    [{0}] {1,-6} = {2}" -f ($i + 1), $dims[$i].Symbol, $dims[$i].Value) -ForegroundColor White
}
Write-Host ""

$sel = Read-Host "  Pick a dimension to drive parametrically (number)"
$idx = 0
if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $dims.Count) {
    throw "Invalid selection '$sel'."
}
$targetDim = $dims[$idx - 1]
$dimSym    = $targetDim.Symbol
$paramName = "PARAM_$dimSym"
Write-Host "  Driving $dimSym (currently $($targetDim.Value)) via parameter $paramName." -ForegroundColor Cyan
Write-Host ""

$newVal = [double](Read-Host "  Enter the FIRST target value for $dimSym")
Write-Host ""

# ============================================
# 2. CREATE / UPDATE THE PARAMETER
# ============================================
Write-Host "  Creating parameter $paramName = $newVal ..." -ForegroundColor White
$pv = New-DoubleParamValue -Value $newVal
$existingParam = $null
try { $existingParam = $model.GetParam($paramName) } catch {}
if ($null -eq $existingParam) {
    $model.CreateParam($paramName, $pv) | Out-Null
    Write-Host "    created." -ForegroundColor Green
} else {
    $existingParam.Value = $pv
    Write-Host "    updated existing param." -ForegroundColor Green
}

# ============================================
# 3. SET THE RELATION  (dimSym = paramName)
# ============================================
# Non-destructive: keep every existing relation EXCEPT any whose LHS is our dim
# (a second relation driving the same dim would conflict), then add ours.
$relText = "$dimSym = $paramName"
Write-Host ""
Write-Host "  Setting relation: $relText" -ForegroundColor White

$existing = Read-Relations -Owner $model
if ($existing.Count -gt 0) {
    Write-Host "    existing relations ($($existing.Count)):" -ForegroundColor DarkGray
    foreach ($r in $existing) { Write-Host "      $r" -ForegroundColor DarkGray }
}

$seq = New-StringSeq -Owner $model   # reads $existing already copied out above, so clearing the live seq is safe
$kept = 0
foreach ($r in $existing) {
    if ((Get-RelationLhs $r) -eq $dimSym.ToLower()) { continue }   # drop prior driver of this dim
    $seq.Append($r); $kept++
}
$seq.Append($relText)
$model.Relations = $seq
Write-Host "    relation set (kept $kept existing, added 1)." -ForegroundColor Green

# Confirm the write by reading .Relations back.
$after = Read-Relations -Owner $model
$found = @($after | Where-Object { (Get-RelationLhs $_) -eq $dimSym.ToLower() })
if ($found.Count -ge 1) {
    Write-Host "    confirmed in model: $($found[0])" -ForegroundColor Green
} else {
    Write-Host "    WARNING: relation did NOT read back — .Relations assignment may not have taken." -ForegroundColor Yellow
}

# ============================================
# 4. REGENERATE — does the param-driven relation beat snap-back?
# ============================================
Write-Host ""
Write-Host "  Regenerating to apply the relation..." -NoNewline
try { $model.RegenerateRelations() } catch {}   # solve the relation set first
try { $model.Regenerate($null); Write-Host " done." -ForegroundColor Green }
catch { Write-Host " warning: $($_.Exception.Message)" -ForegroundColor Yellow }

# Re-read the DIM (fresh handle — old COM object may be stale after regen).
function Read-DimValue {
    param([string]$Sym)
    try { return [double]$model.GetItemByName($pfcType.ITEM_DIMENSION, $Sym).DimValue } catch { return $null }
}
$post = Read-DimValue -Sym $dimSym
Write-Host ""
if ($null -eq $post) {
    Write-Host "  Could not re-read $dimSym after regen." -ForegroundColor Yellow
} elseif ([math]::Abs($post - $newVal) -lt 1e-4) {
    Write-Host "  RESULT: $dimSym = $post  ->  param-driven relation HELD through regen. Snap-back beaten." -ForegroundColor Green
} else {
    Write-Host "  RESULT: $dimSym = $post  (wanted $newVal)  ->  relation did NOT drive the dim." -ForegroundColor Yellow
}

# ============================================
# 5. PARAMETRIC LOOP — change the PARAM, watch the dim follow
# ============================================
# This is the real demonstration: with the relation in place, we never touch the
# dim again — we only change PARAM_<sym> and regen. If the dim tracks the param,
# PowerShell has full parametric control.
Write-Host ""
Write-Host "  Parametric loop — enter a new value for $paramName, or blank to finish." -ForegroundColor Cyan
while ($true) {
    $raw = Read-Host "  New $paramName value"
    if ([string]::IsNullOrWhiteSpace($raw)) { break }
    $v = 0.0
    if (-not [double]::TryParse($raw, [ref]$v)) { Write-Host "    not a number." -ForegroundColor Yellow; continue }

    $pv2 = New-DoubleParamValue -Value $v
    $p = $model.GetParam($paramName)
    $p.Value = $pv2
    try { $model.RegenerateRelations() } catch {}
    try { $model.Regenerate($null) } catch {}
    $now = Read-DimValue -Sym $dimSym
    if ($null -ne $now -and [math]::Abs($now - $v) -lt 1e-4) {
        Write-Host "    $paramName = $v  ->  $dimSym = $now  (tracked)" -ForegroundColor Green
    } else {
        Write-Host "    $paramName = $v  ->  $dimSym = $now  (did NOT track)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "  Probe complete." -ForegroundColor Cyan

} finally {
    $connection.Disconnect($null)
}

Write-Host ""
Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
