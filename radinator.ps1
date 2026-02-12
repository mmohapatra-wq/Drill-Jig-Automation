# radinator.ps1 - Find node-to-stiffener edges and apply radius
# Purpose: Query all edges in a Creo orthogrid model, find edges where
#          cylindrical NODES meet planar STIFFENERS, and apply round features
#          to simulate machined radii from end mill cutting

# Default values (will be overwritten by user input)
$RadiusValue = 0.125

# Global error handling - catch any unhandled exceptions
$ErrorActionPreference = "Stop"
trap {
    Write-Host ""
    Write-Host "[CRASH] Unhandled exception occurred:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    Write-Host "Stack trace:" -ForegroundColor Yellow
    Write-Host $_.ScriptStackTrace -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

# ============================================
# LOGGING FUNCTION
# ============================================
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "HH:mm:ss"
    $color = switch ($Level) {
        "SUCCESS" { "Green" }
        "WARNING" { "Yellow" }
        "ERROR"   { "Red" }
        default   { "White" }
    }

    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

# ============================================
# USER INPUT - EDGE LENGTH CRITERIA
# ============================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   RADINATOR - Node-to-Stiffener" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "This script finds edges where cylindrical NODES meet planar STIFFENERS"
Write-Host "and applies rounds to simulate machined radii from end mill cutting."
Write-Host ""
Write-Host "How would you like to specify edge length?"
Write-Host "  [1] Single dimension (with tolerance)"
Write-Host "  [2] Range (min to max)"
Write-Host ""

$searchMode = Read-Host "Enter choice (1 or 2)"

$MinLength = 0.0
$MaxLength = 0.0
$Tolerance = 0.005  # Default tolerance for single dimension

if ($searchMode -eq "1") {
    # Single dimension mode
    Write-Host ""
    $targetInput = Read-Host "Enter target edge length (inches)"
    $target = [double]$targetInput

    $tolInput = Read-Host "Enter tolerance (default 0.005)"
    if (-not [string]::IsNullOrWhiteSpace($tolInput)) {
        $Tolerance = [double]$tolInput
    }

    $MinLength = $target - $Tolerance
    $MaxLength = $target + $Tolerance

    Write-Host ""
    Write-Log "Search mode: Single dimension $target +/- $Tolerance inches" "INFO"
}
elseif ($searchMode -eq "2") {
    # Range mode
    Write-Host ""
    $minInput = Read-Host "Enter minimum edge length (inches)"
    $MinLength = [double]$minInput

    $maxInput = Read-Host "Enter maximum edge length (inches)"
    $MaxLength = [double]$maxInput

    # Check if user entered them backwards
    if ($MinLength -gt $MaxLength) {
        Write-Host ""
        Write-Host "Min ($MinLength) is greater than Max ($MaxLength)." -ForegroundColor Yellow
        $swapChoice = Read-Host "Swap values? (Y to swap, N to re-enter)"

        if ($swapChoice -eq "Y" -or $swapChoice -eq "y") {
            $temp = $MinLength
            $MinLength = $MaxLength
            $MaxLength = $temp
            Write-Log "Values swapped" "INFO"
        }
        else {
            Write-Host ""
            $minInput = Read-Host "Enter minimum edge length (inches)"
            $MinLength = [double]$minInput

            $maxInput = Read-Host "Enter maximum edge length (inches)"
            $MaxLength = [double]$maxInput
        }
    }

    Write-Host ""
    Write-Log "Search mode: Range $MinLength to $MaxLength inches" "INFO"
}
else {
    Write-Host "Invalid choice. Exiting." -ForegroundColor Red
    exit 1
}

# Prompt for radius value with validation
Write-Host ""
$radiusInput = Read-Host "Enter round radius to apply (inches, default 0.125)"
if (-not [string]::IsNullOrWhiteSpace($radiusInput)) {
    $parsedRadius = 0.0
    if ([double]::TryParse($radiusInput, [ref]$parsedRadius)) {
        if ($parsedRadius -gt 0) {
            $RadiusValue = $parsedRadius
        }
        else {
            Write-Host "Invalid radius (must be positive). Using default: $RadiusValue" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "Invalid input (not a number). Using default: $RadiusValue" -ForegroundColor Yellow
    }
}

Write-Log "Radius to apply: $RadiusValue inches" "INFO"

Write-Host ""

# ============================================
# CONNECT TO CREO
# ============================================
Write-Log "Connecting to Creo..." "INFO"

# Find running Creo process
$proc = Get-Process -Name "xtop" -ErrorAction SilentlyContinue
if ($null -eq $proc) {
    Write-Log "Creo process not found. Please start Creo Parametric." "ERROR"
    exit 1
}

Write-Log "Found Creo process" "SUCCESS"

# Set environment variables
$creoPath = $proc.Path
$Env:PRO_DIRECTORY = $creoPath.TrimEnd("xtop.exe")
$Env:PRO_COMM_MSG_EXE = $creoPath -replace "xtop.exe", "pro_comm_msg.exe"

# Create COM connection
try {
    $async = New-Object -ComObject pfcls.pfcAsyncConnection
    Write-Log "Created async connection object" "SUCCESS"
}
catch {
    Write-Log "Failed to create COM object. Attempting VB API registration..." "WARNING"
    $vb_path = $creoPath -replace "Common Files(.*)$", "Parametric\bin\vb_api_register.bat"
    if (Test-Path $vb_path) {
        Start-Process -Wait -FilePath $vb_path
        $async = New-Object -ComObject pfcls.pfcAsyncConnection
    }
    else {
        Write-Log "VB API registration script not found: $vb_path" "ERROR"
        exit 1
    }
}

# Connect to session
try {
    $connection = $async.Connect($null, $null, $null, $null)
    $session = $connection.Session
    Write-Log "Connected to Creo session" "SUCCESS"
}
catch {
    Write-Log "Failed to connect to Creo session: $($_.Exception.Message)" "ERROR"
    exit 1
}

# Get current model
$model = $session.CurrentModel
if ($null -eq $model) {
    Write-Log "No model open in Creo. Please open a part or assembly." "ERROR"
    exit 1
}

$modelName = $model.FileName
Write-Log "Current model: $modelName" "INFO"

# ============================================
# FIND EDGES BY LENGTH
# ============================================
Write-Log "Scanning model for edges..." "INFO"

$matchingEdges = @()
$totalEdgesScanned = 0
$surfaceCount = 0
$surfaces = $null

# Use GetDefaultBody() - best for merged models
try {
    $defaultBody = $model.GetDefaultBody()
    if ($null -ne $defaultBody) {
        $surfaces = $defaultBody.ListSurfaces()
        if ($null -ne $surfaces -and $surfaces.Count -gt 0) {
            $surfaceCount = $surfaces.Count
            Write-Log "Found $surfaceCount surfaces to scan" "SUCCESS"
        }
    }
}
catch {
    Write-Log "GetDefaultBody() failed: $($_.Exception.Message)" "ERROR"
}

# If still no surfaces, exit
if ($surfaceCount -eq 0) {
    Write-Log "Could not find any surfaces in model" "ERROR"
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

# Track unique edge IDs to avoid duplicates (edges are shared between surfaces)
$processedEdgeIds = @{}
# Track unique surface IDs to avoid duplicates
$processedSurfaceIds = @{}

# Handle both COM collections and PowerShell arrays
$surfaceArray = @()
if ($surfaces -is [array]) {
    $surfaceArray = $surfaces
}
else {
    for ($i = 0; $i -lt $surfaces.Count; $i++) {
        $surfaceArray += $surfaces.Item($i)
    }
}

for ($s = 0; $s -lt $surfaceArray.Count; $s++) {
    try {
        $surface = $surfaceArray[$s]
    }
    catch {
        continue
    }

    # Get surface ID once and use for both dedup and edge tracking
    $surfaceId = $null
    try {
        $surfaceId = $surface.Id
    }
    catch {
        $surfaceId = $s  # Fallback to loop index
    }

    # Skip duplicate surfaces
    if ($processedSurfaceIds.ContainsKey($surfaceId)) {
        continue
    }
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

                    # Skip if we already processed this edge
                    if ($processedEdgeIds.ContainsKey($edgeId)) { continue }
                    $processedEdgeIds[$edgeId] = $true
                    $totalEdgesScanned++

                    try {
                        $length = $edge.EvalLength()

                        # Check if length is within the specified range
                        if ($length -ge $MinLength -and $length -le $MaxLength) {
                            # Check if edge is at node-to-stiffener junction
                            # Node = cylindrical surface (convex), Stiffener = planar surface
                            $includeEdge = $false
                            $cylinderRadius = $null

                            # First check if edge is straight (skip curved edges)
                            # IpfcLineDescriptor has End1/End2 properties; other descriptors don't
                            $isEdgeStraight = $false
                            $curveDesc = $null
                            try {
                                $curveDesc = $edge.GetCurveDescriptor()
                                # Try to access End1 - only IpfcLineDescriptor has this
                                $testEnd = $curveDesc.End1
                                if ($null -ne $testEnd) {
                                    $isEdgeStraight = $true
                                }
                            }
                            catch {
                                # If End1 doesn't exist, it's not a line (curved edge)
                                $isEdgeStraight = $false
                            }
                            finally {
                                if ($null -ne $curveDesc) {
                                    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($curveDesc) | Out-Null } catch {}
                                }
                            }

                            if (-not $isEdgeStraight) {
                                continue  # Skip curved edges
                            }

                            $surf1 = $null
                            $surf2 = $null
                            $desc1 = $null
                            $desc2 = $null
                            try {
                                $surf1 = $edge.Surface1
                                $surf2 = $edge.Surface2

                                if ($null -ne $surf1 -and $null -ne $surf2) {
                                    # Get surface descriptors to determine geometry type
                                    $desc1 = $surf1.GetSurfaceDescriptor()
                                    $desc2 = $surf2.GetSurfaceDescriptor()

                                    # Get surface types using GetSurfaceType()
                                    $surfType1 = $desc1.GetSurfaceType()
                                    $surfType2 = $desc2.GetSurfaceType()

                                    # Check surface types - looking for cylinder + plane combination
                                    # EpfcSurfaceType: 0 = Plane, 1 = Cylinder
                                    $surf1IsCylinder = $false
                                    $surf2IsCylinder = $false
                                    $surf1IsPlane = $false
                                    $surf2IsPlane = $false
                                    $surf1IsConvex = $false
                                    $surf2IsConvex = $false

                                    # Convert to integer for comparison
                                    $type1 = [int]$surfType1
                                    $type2 = [int]$surfType2

                                    # Check if surface 1 is cylinder (1) or plane-like (0=Plane, 9=Ruled surface)
                                    # For cylinders, check orientation (1 = convex/node, 2 = concave/fillet)
                                    if ($type1 -eq 1) {
                                        $orient1 = $surf1.GetOrientation()
                                        $surf1IsCylinder = $true
                                        $surf1IsConvex = ([int]$orient1 -eq 1)
                                        try { $cylinderRadius = $desc1.Radius } catch {}
                                    }
                                    elseif ($type1 -eq 0 -or $type1 -eq 9) {
                                        $surf1IsPlane = $true
                                    }

                                    # Check if surface 2 is cylinder (1) or plane-like (0=Plane, 9=Ruled surface)
                                    if ($type2 -eq 1) {
                                        $orient2 = $surf2.GetOrientation()
                                        $surf2IsCylinder = $true
                                        $surf2IsConvex = ([int]$orient2 -eq 1)
                                        try { $cylinderRadius = $desc2.Radius } catch {}
                                    }
                                    elseif ($type2 -eq 0 -or $type2 -eq 9) {
                                        $surf2IsPlane = $true
                                    }

                                    # Include edge if one surface is CONVEX cylinder (node) and other is plane (stiffener)
                                    # Filter out large cylinders (rocket body curvature) - only include nodes under 1.75" diameter
                                    $maxNodeRadius = 0.875  # 1.75" diameter / 2

                                    $isValidNodeEdge = $false
                                    if ($surf1IsCylinder -and $surf2IsPlane -and $surf1IsConvex) {
                                        $isValidNodeEdge = $true
                                    }
                                    elseif ($surf2IsCylinder -and $surf1IsPlane -and $surf2IsConvex) {
                                        $isValidNodeEdge = $true
                                    }

                                    if ($isValidNodeEdge) {
                                        # Only include if cylinder radius is within node size range
                                        if ($null -ne $cylinderRadius -and $cylinderRadius -le $maxNodeRadius) {
                                            $includeEdge = $true
                                        }
                                    }
                                }
                            }
                            catch {
                                # If we can't evaluate surface types, skip this edge
                                $includeEdge = $false
                            }
                            finally {
                                # Release COM objects regardless of success/failure
                                if ($null -ne $desc1) {
                                    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($desc1) | Out-Null } catch {}
                                }
                                if ($null -ne $desc2) {
                                    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($desc2) | Out-Null } catch {}
                                }
                                if ($null -ne $surf1) {
                                    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($surf1) | Out-Null } catch {}
                                }
                                if ($null -ne $surf2) {
                                    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($surf2) | Out-Null } catch {}
                                }
                            }

                            if ($includeEdge) {
                                # Store only essential data, not the COM object reference
                                # This prevents memory leaks from holding edge COM objects
                                $matchingEdges += @{
                                    Id = $edgeId
                                    Length = $length
                                    SurfaceId = $surfaceId
                                    CylinderRadius = $cylinderRadius
                                }
                            }
                        }
                    }
                    catch {
                        # Skip edges that can't be evaluated
                    }
                }
            }
            catch {
                # Contour may not have elements
            }
        }
    }
    catch {
        # Surface may not have contours
    }

    # Progress update every 100 surfaces
    if (($s + 1) % 100 -eq 0) {
        Write-Log "Progress: $($s + 1)/$($surfaceArray.Count) surfaces, $totalEdgesScanned edges, $($matchingEdges.Count) matches" "INFO"
    }
}

# Update surfaceCount to reflect unique surfaces processed
$surfaceCount = $processedSurfaceIds.Count

# ============================================
# RESULTS SUMMARY
# ============================================
Write-Host ""
Write-Log "========================================" "INFO"
Write-Log "SCAN COMPLETE" "INFO"
Write-Log "========================================" "INFO"
Write-Log "Surfaces scanned: $surfaceCount" "INFO"
Write-Log "Unique edges scanned: $totalEdgesScanned" "INFO"
Write-Log "Matching edges found: $($matchingEdges.Count)" "INFO"
Write-Host ""

if ($matchingEdges.Count -gt 0) {
    # Group matches by cylinder radius (node diameter) for summary
    $radiusGroups = $matchingEdges | Group-Object { [Math]::Round($_.CylinderRadius * 2, 3) } | Sort-Object Name
    Write-Log "Node diameter distribution:" "INFO"
    foreach ($group in $radiusGroups) {
        Write-Host "  Node diameter $($group.Name) in: $($group.Count) edges"
    }
    Write-Host ""

    # Group matches by length for summary
    $lengthGroups = $matchingEdges | Group-Object { [Math]::Round($_.Length, 3) } | Sort-Object Name
    Write-Log "Length distribution:" "INFO"
    foreach ($group in $lengthGroups) {
        Write-Host "  Length $($group.Name) in: $($group.Count) edges"
    }
    Write-Host ""

    # ============================================
    # APPLY ROUNDS (AUTO)
    # ============================================
    $batchSize = 40
    $totalBatches = [Math]::Ceiling($matchingEdges.Count / $batchSize)
    Write-Log "Creating rounds: $($matchingEdges.Count) edges in $totalBatches batches ($batchSize edges per feature)" "INFO"
    Write-Log "IMPORTANT: Do not interact with Creo while processing!" "WARNING"
    Write-Host ""

    $batchNum = 0
    $totalSuccess = 0
    $totalFail = 0

    # Process edges in batches
    for ($batchStart = 0; $batchStart -lt $matchingEdges.Count; $batchStart += $batchSize) {
        $batchNum++
        $batchEnd = [Math]::Min($batchStart + $batchSize, $matchingEdges.Count)
        $batchEdges = $matchingEdges[$batchStart..($batchEnd - 1)]

        Write-Log "Batch $batchNum/$totalBatches - Selecting $($batchEdges.Count) edges..." "INFO"

        # Clear any existing selection first
        try {
            $session.RunMacro("~ Command ``ProCmdSelClear``;")
            Start-Sleep -Milliseconds 300
        }
        catch {}

        $selectCount = 0

        # Select edges for this batch
        foreach ($edgeData in $batchEdges) {
            $edgeId = $edgeData.Id
            $selectCount++

            # Progress update every 20 edges
            if ($selectCount % 20 -eq 0) {
                Write-Host "`r  Selecting: $selectCount / $($batchEdges.Count)..." -NoNewline
            }

            try {
                $selectMapkey = "~ Command ``ProCmdMdlTreeSearch``;" +
                    "~ Open ``selspecdlg0`` ``SelOptionRadio``;" +
                    "~ Close ``selspecdlg0`` ``SelOptionRadio``;" +
                    "~ Select ``selspecdlg0`` ``SelOptionRadio`` 1 ``Edge``;" +
                    "~ Open ``selspecdlg0`` ``LookByOptionMenu``;" +
                    "~ Close ``selspecdlg0`` ``LookByOptionMenu``;" +
                    "~ Select ``selspecdlg0`` ``LookByOptionMenu`` 1 ``Edge``;" +
                    "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Attributes``;" +
                    "~ Select ``selspecdlg0`` ``RuleTab`` 1 ``Misc``;" +
                    "~ Select ``selspecdlg0`` ``RuleTypes`` 1 ``All``;" +
                    "~ Select ``selspecdlg0`` ``RuleTypes`` 1 ``ID``;" +
                    "~ Update ``selspecdlg0`` ``ExtRulesLayout.ExtBasicIDLayout.InputIDPanel`` ``$edgeId``;" +
                    "~ Activate ``selspecdlg0`` ``EvaluateBtn``;" +
                    "~ Activate ``selspecdlg0`` ``ApplyBtn``;" +
                    "~ Activate ``selspecdlg0`` ``CancelButton``;"

                $session.RunMacro($selectMapkey)
            }
            catch {}

            Start-Sleep -Milliseconds 100
        }

        Write-Host "`r  Selection complete. Creating round feature..."

        # Create round feature for this batch
        try {
            $roundMapkey = "~ Activate ``main_dlg_cur`` ``page_Model_control_btn`` 1;" +
                "~ Command ``ProCmdRound``;" +
                "~ Input ``main_dlg_cur`` ``maindashInst0.cir_rad_list`` ``$RadiusValue``;" +
                "~ Update ``main_dlg_cur`` ``maindashInst0.cir_rad_list`` ``$RadiusValue``;" +
                "~ Activate ``main_dlg_cur`` ``maindashInst0.cir_rad_list``;" +
                "~ Activate ``main_dlg_cur`` ``dashInst0.Done``;"

            $session.RunMacro($roundMapkey)

            Write-Log "  Batch $batchNum round feature created!" "SUCCESS"
            $totalSuccess++
        }
        catch {
            Write-Log "  Batch $batchNum FAILED: $($_.Exception.Message)" "ERROR"
            $totalFail++
        }

        # Wait for Creo to process the round before next batch
        Start-Sleep -Seconds 2
    }

    Write-Host ""
    Write-Log "========================================" "INFO"
    Write-Log "COMPLETE: $totalSuccess batches succeeded, $totalFail failed" "SUCCESS"
    Write-Log "Total round features created: $totalSuccess" "INFO"
    Write-Log "========================================" "INFO"
}
else {
    Write-Log "No edges found in range $MinLength - $MaxLength inches" "WARNING"
    Write-Log "Try adjusting the length range parameters" "INFO"
}

# ============================================
# CLEANUP
# ============================================
Write-Log "Cleaning up COM connections..." "INFO"

# Give Creo a moment before disconnecting
Start-Sleep -Milliseconds 500

# Release each COM object in its own try-catch to ensure all get released
# even if one fails
if ($null -ne $surfaces) {
    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($surfaces) | Out-Null }
    catch { Write-Log "Warning releasing surfaces: $($_.Exception.Message)" "WARNING" }
}
if ($null -ne $defaultBody) {
    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($defaultBody) | Out-Null }
    catch { Write-Log "Warning releasing defaultBody: $($_.Exception.Message)" "WARNING" }
}
if ($null -ne $model) {
    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($model) | Out-Null }
    catch { Write-Log "Warning releasing model: $($_.Exception.Message)" "WARNING" }
}
if ($null -ne $session) {
    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($session) | Out-Null }
    catch { Write-Log "Warning releasing session: $($_.Exception.Message)" "WARNING" }
}
if ($null -ne $connection) {
    try {
        $connection.Disconnect(2)  # 2 = don't terminate Creo
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($connection) | Out-Null
    }
    catch { Write-Log "Warning releasing connection: $($_.Exception.Message)" "WARNING" }
}
if ($null -ne $async) {
    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($async) | Out-Null }
    catch { Write-Log "Warning releasing async: $($_.Exception.Message)" "WARNING" }
}

# Force garbage collection
try {
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}
catch {}

Write-Log "Cleanup complete" "SUCCESS"

Write-Log "Script completed" "INFO"

# Pause at end so user can see output
Write-Host ""
Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
