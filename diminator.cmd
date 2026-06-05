<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir='%~dp0'; $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "DIMINATOR"
$ErrorActionPreference = "Stop"

trap {
    Write-Host ""
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

# ============================================
# HEADER
# ============================================
Write-Host ""
Write-Host "  ██████╗ ██╗███╗   ███╗██╗███╗   ██╗ █████╗ ████████╗ ██████╗ ██████╗ " -ForegroundColor White
Write-Host "  ██╔══██╗██║████╗ ████║██║████╗  ██║██╔══██╗╚══██╔══╝██╔═══██╗██╔══██╗" -ForegroundColor White
Write-Host "  ██║  ██║██║██╔████╔██║██║██╔██╗ ██║███████║   ██║   ██║   ██║██████╔╝" -ForegroundColor White
Write-Host "  ██║  ██║██║██║╚██╔╝██║██║██║╚██╗██║██╔══██║   ██║   ██║   ██║██╔══██╗" -ForegroundColor White
Write-Host "  ██████╔╝██║██║ ╚═╝ ██║██║██║ ╚████║██║  ██║   ██║   ╚██████╔╝██║  ██║" -ForegroundColor White
Write-Host "  ╚═════╝ ╚═╝╚═╝     ╚═╝╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝" -ForegroundColor White
Write-Host "  CSV to Dimension Import" -ForegroundColor White
Write-Host ""

# ============================================
# PREREQUISITES
# ============================================
Write-Host "  Prerequisites:" -ForegroundColor Green
Write-Host "    1. Part open in Creo (same model the CSV was exported from)" -ForegroundColor White
Write-Host "    2. CSV file produced by gauginator" -ForegroundColor White
Write-Host "    3. Do not interact with Creo during processing" -ForegroundColor White
Write-Host ""

# ============================================
# CSV INPUT
# ============================================
$csvInput = Read-Host "  Path to CSV file"
$csvPath = $csvInput.Trim('"')

if (-not (Test-Path $csvPath)) {
    Write-Host "  FAILED: File not found: $csvPath" -ForegroundColor Red
    exit 1
}

$rows = Import-Csv -Path $csvPath

if ($null -eq $rows -or $rows.Count -eq 0) {
    Write-Host "  FAILED: CSV is empty or could not be parsed." -ForegroundColor Red
    exit 1
}

# Detect actual column names (case-insensitive match for Dim_Name and Value)
$columns = $rows[0].PSObject.Properties.Name
Write-Host "  Columns found: $($columns -join ', ')" -ForegroundColor Gray

$colDimName = $columns | Where-Object { $_ -ieq "Dim_Name" } | Select-Object -First 1
$colValue   = $columns | Where-Object { $_ -ieq "Value"    } | Select-Object -First 1

if (-not $colDimName) {
    Write-Host "  FAILED: No 'Dim_Name' column found in CSV." -ForegroundColor Red
    exit 1
}
if (-not $colValue) {
    Write-Host "  FAILED: No 'Value' column found in CSV." -ForegroundColor Red
    exit 1
}

Write-Host "  Loaded $($rows.Count) dimension(s) from CSV." -ForegroundColor Green
Write-Host ""

# ============================================
# CONNECT TO CREO
# ============================================
Write-Host "  Connecting to Creo..." -NoNewline

$proc = Get-Process | Where-Object {$_.ProcessName -eq "xtop"}
if ($null -eq $proc) {
    Write-Host ""
    Write-Host "  FAILED: Creo process (xtop) not found." -ForegroundColor Red
    exit 1
}

$pc_path = $proc.Path -replace "xtop.exe", "pro_comm_msg.exe"
$Env:PRO_DIRECTORY = $proc.Path.TrimEnd("xtop.exe")
$Env:PRO_COMM_MSG_EXE = $pc_path

try {
    New-Object -ComObject pfcls.pfcAsyncConnection | Out-Null
}
catch {
    Write-Host ""
    Write-Host "  VB API not registered, performing first-time setup..." -ForegroundColor Yellow
    $vb_path = $proc.Path -replace "Common Files(.*)$", "Parametric\bin\vb_api_register.bat"
    Start-Process -Wait -FilePath $vb_path
}

$async = New-Object -ComObject pfcls.pfcAsyncConnection
$connection = $async.Connect($null, $null, $null, $null)
$session = $connection.Session
$model = $session.GetActiveModel()

if ($null -eq $model) {
    Write-Host ""
    Write-Host "  FAILED: No model open in Creo." -ForegroundColor Red
    exit 1
}

Write-Host " Connected to $($model.FileName)" -ForegroundColor Green

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

try {
# ============================================
# APPLY DIMENSIONS
# ============================================
Write-Host "  Applying dimensions..." -ForegroundColor White
Write-Host ""

$pfcModelItemType = New-Object -ComObject pfcls.pfcModelItemType

$successCount = 0
$skipCount = 0
$failCount = 0

# Parse and validate all rows upfront
$pending = @()
foreach ($row in $rows) {
    $dimName  = $row.$colDimName
    $dimValue = $row.$colValue

    if ([string]::IsNullOrWhiteSpace($dimName) -or [string]::IsNullOrWhiteSpace($dimValue)) {
        Write-Host "  SKIP  $dimName — missing name or value" -ForegroundColor Yellow
        $skipCount++
        continue
    }

    $parsedValue = 0.0
    if (-not [double]::TryParse($dimValue, [ref]$parsedValue)) {
        Write-Host "  SKIP  $dimName — value '$dimValue' is not a number" -ForegroundColor Yellow
        $skipCount++
        continue
    }

    $dim = $model.GetItemByName($pfcModelItemType.ITEM_DIMENSION, $dimName)
    if ($null -eq $dim) {
        Write-Host "  SKIP  $dimName — not found in model" -ForegroundColor Yellow
        $skipCount++
        continue
    }

    $pending += @{ Name = $dimName; Dim = $dim; OldValue = $dim.DimValue; NewValue = $parsedValue }
}

# Pass 1 — blindly set all dims, then regenerate to find out which actually stuck
foreach ($entry in $pending) {
    try { $entry.Dim.DimValue = $entry.NewValue } catch {}
}

Write-Host "  Regenerating (pass 1)..." -NoNewline
try { $model.Regenerate($null) } catch {}
Write-Host " Done." -ForegroundColor Green
Write-Host ""

# Check which dims actually took by re-reading after regen
$sketchPending = @()
foreach ($entry in $pending) {
    $actual = $model.GetItemByName($pfcModelItemType.ITEM_DIMENSION, $entry.Name).DimValue
    if ([Math]::Abs($actual - $entry.NewValue) -lt 1e-6) {
        Write-Host "  OK    $($entry.Name)  $($entry.OldValue) -> $($entry.NewValue)" -ForegroundColor Green
        $successCount++
    } else {
        $sketchPending += $entry
    }
}

# Pass 2 — sketch dims that snapped back: ask user to open the sketch
if ($sketchPending.Count -gt 0) {
    Write-Host ""
    Write-Host "  $($sketchPending.Count) dimension(s) snapped back after regen (sketch dims):" -ForegroundColor Yellow
    foreach ($entry in $sketchPending) {
        Write-Host "    $($entry.Name)  -> $($entry.NewValue)" -ForegroundColor White
    }
    Write-Host ""
    Write-Host "  In Creo, double-click the sketch feature to open it," -ForegroundColor Cyan
    Write-Host "  then press ENTER here to continue." -ForegroundColor Cyan
    Read-Host

    # When sketch is open, GetActiveModel returns the sketch — dims must be fetched from there
    $sketchModel = $session.GetActiveModel()
    Write-Host "  Active model after sketch open: $($sketchModel.FileName)" -ForegroundColor Gray

    foreach ($entry in $sketchPending) {
        try {
            $dim = $sketchModel.GetItemByName($pfcModelItemType.ITEM_DIMENSION, $entry.Name)
            if ($null -eq $dim) {
                $dim = $model.GetItemByName($pfcModelItemType.ITEM_DIMENSION, $entry.Name)
            }
            if ($null -eq $dim) {
                Write-Host "  FAIL  $($entry.Name) — dim not found in sketch or part model" -ForegroundColor Red
                $failCount++
                continue
            }
            $dim.DimValue = $entry.NewValue
            Write-Host "  SET   $($entry.Name)  -> $($entry.NewValue)" -ForegroundColor Green
            $successCount++
        } catch {
            Write-Host "  FAIL  $($entry.Name) — $($_.Exception.Message)" -ForegroundColor Red
            $failCount++
        }
    }

    # Regenerate the sketch model to solve it with new values and mark it dirty
    Write-Host "  Solving sketch..." -NoNewline
    try {
        $sketchModel.Regenerate($null)
        Write-Host " Done." -ForegroundColor Green
    } catch {
        Write-Host " Warning: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "  Close the sketch in Creo (click OK/checkmark), then press ENTER here." -ForegroundColor Cyan
    Read-Host
}

Write-Host ""

if ($successCount -gt 0) {
    Write-Host "  Regenerating model..." -NoNewline
    try {
        $model.Regenerate($null)
        Write-Host " Done." -ForegroundColor Green
    }
    catch {
        Write-Host ""
        Write-Host "  WARNING: Regeneration failed — $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  Dimensions were set but geometry may not have updated." -ForegroundColor Yellow
    }
}
else {
    Write-Host "  No dimensions were changed — skipping regeneration." -ForegroundColor Yellow
}

} finally {
    try {
        if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null }
        if ($null -ne $origDynamicPreview)  { $session.SetConfigOption("dynamic_preview",  $origDynamicPreview)  | Out-Null }
    } catch {}
    $connection.Disconnect($null)
}

# ============================================
# FINAL REPORT
# ============================================
Write-Host ""
Write-Host "  ==============================" -ForegroundColor Green
Write-Host "  DIMINATOR COMPLETE" -ForegroundColor Green
Write-Host "  ==============================" -ForegroundColor Green
Write-Host "  Applied:  $successCount" -ForegroundColor White
Write-Host "  Skipped:  $skipCount" -ForegroundColor White
Write-Host "  Failed:   $failCount" -ForegroundColor White
Write-Host ""
Write-Host "  Press any key to exit..." -ForegroundColor White
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
