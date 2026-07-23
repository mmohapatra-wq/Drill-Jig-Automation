# ---------------------------------------------------------------------------
# check_bushing_pn_integrity.ps1 - deterministic data-integrity check for the
# drill-bushing catalog after the 2026-07-22 refinement.
#
# Asserts, against data\bushings_drill.csv:
#   1. NONE of the truncated/duplicate part-number stubs (8493A0/A2/A3/A5) remain
#      as a PartNumber cell -- the OD-3/4 removable-bushing rows whose real
#      7-char McMaster number was clipped from the source PDF were blanked.
#   2. EXACTLY 54 rows are flagged with the "PN unverified" note (the blanked set).
#   3. Those 54 rows all have an EMPTY PartNumber and OD == 0.75.
#   4. The untouched OD-1/4 / OD-1/2 rows keep their valid part numbers (spot: 8493A001).
#   5. Row count is unchanged (149) and the PartNumberNote column exists.
#
# Exit 0 = all pass; exit 1 = any failure (prints which). No Creo, no network.
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$csv  = Join-Path $root 'data\bushings_drill.csv'

$fail = 0
function Bad($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:fail++ }
function Ok($m)  { Write-Host "ok:   $m" -ForegroundColor Green }

if (-not (Test-Path $csv)) { Bad "missing $csv"; exit 1 }
$rows = @(Import-Csv $csv)

# 5. row count + column present
if ($rows.Count -eq 149) { Ok "149 rows" } else { Bad "row count $($rows.Count), want 149" }
if ($rows[0].PSObject.Properties.Name -contains 'PartNumberNote') { Ok "PartNumberNote column present" }
else { Bad "PartNumberNote column missing" }

# 1. no truncated stubs remain as PartNumber cells
$stubs = @('8493A0','8493A2','8493A3','8493A5')
$stubHits = @($rows | Where-Object { $stubs -contains $_.PartNumber })
if ($stubHits.Count -eq 0) { Ok "no truncated PN stubs remain" }
else { Bad "$($stubHits.Count) rows still carry a truncated PN stub" }

# 2. exactly 54 flagged
$flagged = @($rows | Where-Object { $_.PartNumberNote -match 'PN unverified' })
if ($flagged.Count -eq 54) { Ok "54 rows flagged 'PN unverified'" }
else { Bad "$($flagged.Count) rows flagged, want 54" }

# 3. flagged rows: empty PN + OD 0.75
$badFlag = @($flagged | Where-Object { $_.PartNumber -ne '' -or $_.OD -ne '0.75' })
if ($badFlag.Count -eq 0) { Ok "all flagged rows have empty PN and OD 0.75" }
else { Bad "$($badFlag.Count) flagged rows have a non-empty PN or OD != 0.75" }

# 4. untouched valid PN preserved
$keep = @($rows | Where-Object { $_.PartNumber -eq '8493A001' })
if ($keep.Count -ge 1) { Ok "valid PN 8493A001 preserved" }
else { Bad "valid PN 8493A001 missing" }

# blanked count sanity: blank PN count must equal flagged count
$blank = @($rows | Where-Object { $_.PartNumber -eq '' })
if ($blank.Count -eq 54) { Ok "54 rows have empty PartNumber" }
else { Bad "$($blank.Count) rows have empty PN, want 54" }

if ($fail -eq 0) { Write-Host "`nbushing-PN integrity: ALL PASS" -ForegroundColor Green; exit 0 }
else { Write-Host "`nbushing-PN integrity: $fail FAILURE(S)" -ForegroundColor Red; exit 1 }
