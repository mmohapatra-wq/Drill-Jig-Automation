<# :
@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -Command "$ScriptDir=((Split-Path -Parent ('%~dp0'.TrimEnd('\')))+'\'); $ScriptArgs='%*'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~f0')))"
exit /b %errorlevel%
#>

$Host.UI.RawUI.WindowTitle = "RADINATOR"
$Verbose = $ScriptArgs -match '(?i)-v|--verbose'
$ErrorActionPreference = "Stop"
$startTime = Get-Date

trap {
    Write-Host ""
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    if ($Verbose -and $_.ScriptStackTrace) {
        Write-Host "  $($_.ScriptStackTrace)" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

function Write-Log {
    param([string]$Msg, [string]$Color = 'Gray')
    if ($Verbose) { Write-Host "  $Msg" -ForegroundColor $Color }
}

$script:lastPct = -1
function Show-Progress {
    param([int]$Pct, [string]$Label)
    if ($Pct -eq $script:lastPct) { return }
    $script:lastPct = $Pct
    $filled = [Math]::Floor($Pct / 5)
    $empty = 20 - $filled
    $bar = ([char]9608).ToString() * $filled + ([char]9617).ToString() * $empty
    $color = if ($Pct -ge 100) { "Green" } else { "White" }
    $shortLabel = if ($Label.Length -gt 60) { $Label.Substring(0, 60) } else { $Label }
    Write-Host "`r  [$bar] $($Pct.ToString().PadLeft(3))%  $shortLabel   " -NoNewline -ForegroundColor $color
    if ($Pct -ge 100) { Write-Host "" }
}

# ============================================
# HEADER
# ============================================
Write-Host ""
Write-Host "  ██████╗  █████╗ ██████╗ ██╗███╗   ██╗ █████╗ ████████╗ ██████╗ ██████╗ " -ForegroundColor White
Write-Host "  ██╔══██╗██╔══██╗██╔══██╗██║████╗  ██║██╔══██╗╚══██╔══╝██╔═══██╗██╔══██╗" -ForegroundColor White
Write-Host "  ██████╔╝███████║██║  ██║██║██╔██╗ ██║███████║   ██║   ██║   ██║██████╔╝" -ForegroundColor White
Write-Host "  ██╔══██╗██╔══██║██║  ██║██║██║╚██╗██║██╔══██║   ██║   ██║   ██║██╔══██╗" -ForegroundColor White
Write-Host "  ██║  ██║██║  ██║██████╔╝██║██║ ╚████║██║  ██║   ██║   ╚██████╔╝██║  ██║" -ForegroundColor White
Write-Host "  ╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝ ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝" -ForegroundColor White
Write-Host "  Node-to-Stiffener Radius Automation" -ForegroundColor White
Write-Host ""

# ============================================
# PREREQUISITES
# ============================================
Write-Host "  Prerequisites:" -ForegroundColor Green
Write-Host "    1. Fully merged orthogrid model (w/ nodes) open in Creo" -ForegroundColor White
Write-Host "    2. Edge length or range to target for round application" -ForegroundColor White
Write-Host "    3. Do not interact with Creo during processing" -ForegroundColor White
Write-Host ""

# ============================================
# USER INPUT
# ============================================
Write-Host "  How would you like to specify edge length?" -ForegroundColor White
Write-Host "    [1] Single dimension (with tolerance)" -ForegroundColor White
Write-Host "    [2] Range (min to max)" -ForegroundColor White
Write-Host ""

$searchMode = Read-Host "  Choice (1 or 2)"

$MinLength = 0.0
$MaxLength = 0.0
$Tolerance = 0.005
$RadiusValue = 0.125

if ($searchMode -eq "1") {
    $targetInput = Read-Host "  Target edge length (inches)"
    $target = [double]$targetInput

    $tolInput = Read-Host "  Tolerance (press enter to accept .005 default)"
    if (-not [string]::IsNullOrWhiteSpace($tolInput)) {
        $Tolerance = [double]$tolInput
    }

    $MinLength = $target - $Tolerance
    $MaxLength = $target + $Tolerance
    Write-Host "  Searching: $target +/- $Tolerance inches" -ForegroundColor White
}
elseif ($searchMode -eq "2") {
    $minInput = Read-Host "  Minimum edge length (inches)"
    $MinLength = [double]$minInput

    $maxInput = Read-Host "  Maximum edge length (inches)"
    $MaxLength = [double]$maxInput

    if ($MinLength -gt $MaxLength) {
        Write-Host "  Min ($MinLength) > Max ($MaxLength)." -ForegroundColor Yellow
        $swapChoice = Read-Host "  Swap values? (Y/N)"
        if ($swapChoice -eq "Y" -or $swapChoice -eq "y") {
            $temp = $MinLength
            $MinLength = $MaxLength
            $MaxLength = $temp
        }
        else {
            $minInput = Read-Host "  Minimum edge length (inches)"
            $MinLength = [double]$minInput
            $maxInput = Read-Host "  Maximum edge length (inches)"
            $MaxLength = [double]$maxInput
        }
    }

    Write-Host "  Searching: $MinLength to $MaxLength inches" -ForegroundColor White
}
else {
    Write-Host "  FAILED: Invalid choice." -ForegroundColor Red
    exit 1
}

Write-Host ""
$radiusInput = Read-Host "  Round radius to apply (inches, default 0.125)"
if (-not [string]::IsNullOrWhiteSpace($radiusInput)) {
    $parsedRadius = 0.0
    if ([double]::TryParse($radiusInput, [ref]$parsedRadius)) {
        if ($parsedRadius -gt 0) {
            $RadiusValue = $parsedRadius
        }
        else {
            Write-Host "  Invalid radius (must be positive). Using default: $RadiusValue" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "  Invalid input. Using default: $RadiusValue" -ForegroundColor Yellow
    }
}
Write-Host "  Radius: $RadiusValue inches" -ForegroundColor White
Write-Host ""

# ============================================
# CONNECT TO CREO
# ============================================
Write-Host "  Connecting to Creo..." -NoNewline

$proc = Get-Process -Name "xtop" -ErrorAction SilentlyContinue
if ($null -eq $proc) {
    Write-Host ""
    Write-Host "  FAILED: Creo process not found. Please start Creo Parametric." -ForegroundColor Red
    exit 1
}

$creoPath = $proc.Path
$Env:PRO_DIRECTORY = $creoPath.TrimEnd("xtop.exe")
$Env:PRO_COMM_MSG_EXE = $creoPath -replace "xtop.exe", "pro_comm_msg.exe"

try {
    $async = New-Object -ComObject pfcls.pfcAsyncConnection
}
catch {
    Write-Log "Attempting VB API registration..."
    $vb_path = $creoPath -replace "Common Files(.*)$", "Parametric\bin\vb_api_register.bat"
    if (Test-Path $vb_path) {
        Start-Process -Wait -FilePath $vb_path
        $async = New-Object -ComObject pfcls.pfcAsyncConnection
    }
    else {
        Write-Host ""
        Write-Host "  FAILED: VB API registration script not found." -ForegroundColor Red
        exit 1
    }
}

$connection = $async.Connect($null, $null, $null, $null)
$session = $connection.Session
$model = $session.CurrentModel

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
# ENUMERATE BODIES AND SURFACES
# ============================================
Write-Host "  Scanning surfaces..." -NoNewline

$matchingEdges = @()
$totalEdgesScanned = 0
$allSurfaces = @()

$modelItemType = New-Object -ComObject pfcls.pfcModelItemType
try {
    $allBodies = $model.ListItems($modelItemType.ITEM_BODY)
    if ($null -ne $allBodies -and $allBodies.Count -gt 0) {
        Write-Log "Found $($allBodies.Count) bodies in model"
        for ($b = 0; $b -lt $allBodies.Count; $b++) {
            $body = $allBodies.Item($b)
            try {
                $bodySurfaces = $body.ListSurfaces()
                if ($null -ne $bodySurfaces -and $bodySurfaces.Count -gt 0) {
                    for ($bs = 0; $bs -lt $bodySurfaces.Count; $bs++) {
                        $allSurfaces += $bodySurfaces.Item($bs)
                    }
                }
            }
            catch {
                Write-Log "Could not list surfaces for body $b" "Yellow"
            }
        }
    }
}
catch {
    Write-Log "ListItems(ITEM_BODY) failed: $($_.Exception.Message)" "Yellow"
}

# Fallback to GetDefaultBody if body enumeration failed
if ($allSurfaces.Count -eq 0) {
    Write-Log "Falling back to GetDefaultBody()..." "Yellow"
    try {
        $defaultBody = $model.GetDefaultBody()
        if ($null -ne $defaultBody) {
            $surfaces = $defaultBody.ListSurfaces()
            if ($null -ne $surfaces -and $surfaces.Count -gt 0) {
                for ($fs = 0; $fs -lt $surfaces.Count; $fs++) {
                    $allSurfaces += $surfaces.Item($fs)
                }
            }
        }
    }
    catch {
        Write-Host ""
        Write-Host "  FAILED: Could not find any surfaces in model." -ForegroundColor Red
        exit 1
    }
}

if ($allSurfaces.Count -eq 0) {
    Write-Host ""
    Write-Host "  FAILED: No surfaces found in model." -ForegroundColor Red
    exit 1
}

Write-Host " $($allSurfaces.Count) surfaces found." -ForegroundColor Green

# ============================================
# SCAN EDGES
# ============================================
Write-Host ""
$processedEdgeIds = @{}
$processedSurfaceIds = @{}
$script:lastPct = -1

for ($s = 0; $s -lt $allSurfaces.Count; $s++) {
    $pct = [Math]::Floor(($s / $allSurfaces.Count) * 100)
    Show-Progress $pct "Scanning edges"

    try {
        $surface = $allSurfaces[$s]
    }
    catch { continue }

    $surfaceId = $null
    try { $surfaceId = $surface.Id }
    catch { $surfaceId = $s }

    if ($processedSurfaceIds.ContainsKey($surfaceId)) { continue }
    $processedSurfaceIds[$surfaceId] = $true

    try {
        $contours = $surface.ListContours()
        if ($null -eq $contours) { continue }

        for ($c = 0; $c -lt $contours.Count; $c++) {
            $contour = $contours.Item($c)

            try {
                $edges = $contour.ListElements()
                if ($null -eq $edges) { continue }

                for ($e = 0; $e -lt $edges.Count; $e++) {
                    $edge = $edges.Item($e)

                    try { $edgeId = $edge.Id }
                    catch { $edgeId = "$s-$c-$e" }

                    if ($processedEdgeIds.ContainsKey($edgeId)) { continue }
                    $processedEdgeIds[$edgeId] = $true
                    $totalEdgesScanned++

                    try {
                        $length = $edge.EvalLength()

                        if ($length -ge $MinLength -and $length -le $MaxLength) {
                            $includeEdge = $false
                            $cylinderRadius = $null

                            # Check if edge is straight
                            $isEdgeStraight = $false
                            $curveDesc = $null
                            try {
                                $curveDesc = $edge.GetCurveDescriptor()
                                $testEnd = $curveDesc.End1
                                if ($null -ne $testEnd) { $isEdgeStraight = $true }
                            }
                            catch { $isEdgeStraight = $false }
                            finally {
                                if ($null -ne $curveDesc) {
                                    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($curveDesc) | Out-Null } catch {}
                                }
                            }

                            if (-not $isEdgeStraight) { continue }

                            $surf1 = $null
                            $surf2 = $null
                            $desc1 = $null
                            $desc2 = $null
                            try {
                                $surf1 = $edge.Surface1
                                $surf2 = $edge.Surface2

                                if ($null -ne $surf1 -and $null -ne $surf2) {
                                    $desc1 = $surf1.GetSurfaceDescriptor()
                                    $desc2 = $surf2.GetSurfaceDescriptor()

                                    $surfType1 = $desc1.GetSurfaceType()
                                    $surfType2 = $desc2.GetSurfaceType()

                                    $surf1IsCylinder = $false
                                    $surf2IsCylinder = $false
                                    $surf1IsPlane = $false
                                    $surf2IsPlane = $false
                                    $surf1IsConvex = $false
                                    $surf2IsConvex = $false

                                    $type1 = [int]$surfType1
                                    $type2 = [int]$surfType2

                                    if ($type1 -eq 1) {
                                        $orient1 = $surf1.GetOrientation()
                                        $surf1IsCylinder = $true
                                        $surf1IsConvex = ([int]$orient1 -eq 1)
                                        try { $cylinderRadius = $desc1.Radius } catch {}
                                    }
                                    elseif ($type1 -eq 0 -or $type1 -eq 9) {
                                        $surf1IsPlane = $true
                                    }

                                    if ($type2 -eq 1) {
                                        $orient2 = $surf2.GetOrientation()
                                        $surf2IsCylinder = $true
                                        $surf2IsConvex = ([int]$orient2 -eq 1)
                                        try { $cylinderRadius = $desc2.Radius } catch {}
                                    }
                                    elseif ($type2 -eq 0 -or $type2 -eq 9) {
                                        $surf2IsPlane = $true
                                    }

                                    $maxNodeRadius = 0.875
                                    $isValidNodeEdge = $false

                                    if ($surf1IsCylinder -and $surf2IsPlane -and $surf1IsConvex) {
                                        $isValidNodeEdge = $true
                                    }
                                    elseif ($surf2IsCylinder -and $surf1IsPlane -and $surf2IsConvex) {
                                        $isValidNodeEdge = $true
                                    }

                                    if ($isValidNodeEdge -and $null -ne $cylinderRadius -and $cylinderRadius -le $maxNodeRadius) {
                                        $includeEdge = $true
                                    }
                                }
                            }
                            catch { $includeEdge = $false }
                            finally {
                                if ($null -ne $desc1) { try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($desc1) | Out-Null } catch {} }
                                if ($null -ne $desc2) { try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($desc2) | Out-Null } catch {} }
                                if ($null -ne $surf1) { try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($surf1) | Out-Null } catch {} }
                                if ($null -ne $surf2) { try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($surf2) | Out-Null } catch {} }
                            }

                            if ($includeEdge) {
                                $matchingEdges += @{
                                    Id = $edgeId
                                    Length = $length
                                    SurfaceId = $surfaceId
                                    CylinderRadius = $cylinderRadius
                                }
                            }
                        }
                    }
                    catch {}
                }
            }
            catch {}
        }
    }
    catch {}
}

Show-Progress 100 "Scanning edges - ${totalEdgesScanned} found, $($matchingEdges.Count) matched"
Write-Host ""

# ============================================
# APPLY ROUNDS
# ============================================
if ($matchingEdges.Count -gt 0) {
    # Show distribution in verbose mode
    if ($Verbose) {
        $radiusGroups = $matchingEdges | Group-Object { [Math]::Round($_.CylinderRadius * 2, 3) } | Sort-Object Name
        Write-Log "Node diameter distribution:"
        foreach ($group in $radiusGroups) {
            Write-Log "  Diameter $($group.Name) in: $($group.Count) edges"
        }
        $lengthGroups = $matchingEdges | Group-Object { [Math]::Round($_.Length, 3) } | Sort-Object Name
        Write-Log "Length distribution:"
        foreach ($group in $lengthGroups) {
            Write-Log "  Length $($group.Name) in: $($group.Count) edges"
        }
    }

    $batchSize = 40
    $totalBatches = [Math]::Ceiling($matchingEdges.Count / $batchSize)
    Write-Host "  Applying rounds: $($matchingEdges.Count) edges in $totalBatches batches" -ForegroundColor White
    Write-Host ""
    Write-Host "  Monitor Creo and click Ok if any rounds fail." -ForegroundColor Gray
    Write-Host "  You can fix them after this process completes." -ForegroundColor Gray
    Write-Host ""

    $batchNum = 0
    $totalSuccess = 0
    $script:lastPct = -1

    for ($batchStart = 0; $batchStart -lt $matchingEdges.Count; $batchStart += $batchSize) {
        $batchNum++
        $batchEnd = [Math]::Min($batchStart + $batchSize, $matchingEdges.Count)
        $batchEdges = $matchingEdges[$batchStart..($batchEnd - 1)]

        # Clear selection
        try {
            $session.RunMacro("~ Command ``ProCmdSelClear``;")
        }
        catch {}

        # Select this batch's edges into the buffer as ONE macro. The find-tool
        # dialog (selspecdlg0) survives across the accumulate loop, so the whole
        # open -> per-id search/apply -> close sequence is a SINGLE RunMacro instead
        # of N+2 separate calls. This is byte-for-byte cornerinator's proven-live
        # Build-EdgeSelectMacro pattern (confirmed on the foreign jig body). Selection
        # does not regen, so there is no dashboard-atomicity concern -- collapsing the
        # calls just removes ~N COM round-trips per batch (the dominant selection-phase
        # cost on a big node model). The round dashboard below stays its own atomic macro.
        Show-Progress ([Math]::Floor(($batchEnd / $matchingEdges.Count) * 100)) "Batch ${batchNum}/${totalBatches}"
        $selectMacro = "~ Command ``ProCmdMdlTreeSearch``;" +
            "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Edge``;" +
            "~ Select ``selspecdlg0`` ``LookByOptionMenu`` 1 ``Edge``;" +
            "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Attributes``;" +
            "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
            "~ Select ``selspecdlg0`` ``RuleTypes`` 1 ``All``;" +
            "~ Select ``selspecdlg0`` ``RuleTypes`` 1 ``ID``;"
        foreach ($edgeData in $batchEdges) {
            $selectMacro += "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$($edgeData.Id)``;" +
                "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
                "~ Activate ``selspecdlg0`` ``ApplyBtn``;"
        }
        $selectMacro += "~ Activate ``selspecdlg0`` ``CancelButton``;"
        try { $session.RunMacro($selectMacro) } catch {}

        # Create round feature
        try {
            $roundMapkey = "~ Activate ``main_dlg_cur`` ``page_Model_control_btn`` 1;" +
                "~ Command ``ProCmdRound``;" +
                "~ Input ``main_dlg_cur`` ``maindashInst0.cir_rad_list`` ``$RadiusValue``;" +
                "~ Update ``main_dlg_cur`` ``maindashInst0.cir_rad_list`` ``$RadiusValue``;" +
                "~ Activate ``main_dlg_cur`` ``maindashInst0.cir_rad_list``;" +
                "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"

            $session.RunMacro($roundMapkey)
            $totalSuccess++
            Write-Log "Batch $batchNum round created" "Green"
        }
        catch {
            Write-Log "Batch $batchNum macro error: $($_.Exception.Message)" "Yellow"
        }

    }

    Show-Progress 100 "Rounds complete"
}
else {
    Write-Host "  No matching edges found in range $MinLength - $MaxLength inches" -ForegroundColor Yellow
}

} finally {
    try {
        if ($null -ne $origVisibleMapkeys) { $session.SetConfigOption("visible_mapkeys", $origVisibleMapkeys) | Out-Null }
        if ($null -ne $origDynamicPreview)  { $session.SetConfigOption("dynamic_preview",  $origDynamicPreview)  | Out-Null }
    } catch {}

    # ============================================
    # CLEANUP
    # ============================================
    if ($null -ne $allBodies) {
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($allBodies) | Out-Null } catch {}
    }
    if ($null -ne $modelItemType) {
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($modelItemType) | Out-Null } catch {}
    }
    if ($null -ne $model) {
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($model) | Out-Null } catch {}
    }
    if ($null -ne $session) {
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($session) | Out-Null } catch {}
    }
    if ($null -ne $connection) {
        try {
            $connection.Disconnect(2)
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($connection) | Out-Null
        } catch {}
    }
    if ($null -ne $async) {
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($async) | Out-Null } catch {}
    }
    try {
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    } catch {}
}

# ============================================
# FINAL REPORT
# ============================================
$elapsed = (Get-Date) - $startTime
$timeStr = "{0:mm\:ss}" -f $elapsed

Write-Host ""
Write-Host "  ==============================" -ForegroundColor Green
Write-Host "  RADINATOR COMPLETE" -ForegroundColor Green
Write-Host "  ==============================" -ForegroundColor Green
Write-Host "  Surfaces scanned: $($processedSurfaceIds.Count)" -ForegroundColor White
Write-Host "  Edges scanned:    $totalEdgesScanned" -ForegroundColor White
Write-Host "  Edges matched:    $($matchingEdges.Count)" -ForegroundColor White
if ($matchingEdges.Count -gt 0) {
    Write-Host "  Batches created:  $totalSuccess" -ForegroundColor White
}
Write-Host "  Time:             $timeStr" -ForegroundColor White
Write-Host ""

Write-Host "  Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
