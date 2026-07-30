<#
Script: scripts\regression-evidence-report.ps1
Purpose: Builds a summary that reconciles regression results with the documented test catalog.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\regression-evidence-report.ps1
Outputs:
  wave\regression-evidence-summary.json and console evidence summary.
Scope:
  Regression reporting only; not additional hardware proof by itself.
Audience:
  Internal helper used by scripts\check.ps1 and release flows.
#>
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. "$PSScriptRoot\verification-source-identity.ps1"

$catalogPath = Join-Path $repoRoot "docs\test_catalog.json"
$regressionSummaryPath = Join-Path $repoRoot "wave\regression-summary.json"
$outputPath = Join-Path $repoRoot "wave\regression-evidence-summary.json"

function Fail-EvidenceReport {
    param([string]$Message)
    throw "regression evidence report failed: $Message"
}

if (-not (Test-Path -LiteralPath $catalogPath)) {
    Fail-EvidenceReport "missing docs\test_catalog.json"
}

if (-not (Test-Path -LiteralPath $regressionSummaryPath)) {
    Fail-EvidenceReport "missing wave\regression-summary.json"
}

$catalog = Get-Content -Raw -Path $catalogPath | ConvertFrom-Json
$summary = Get-Content -Raw -Path $regressionSummaryPath | ConvertFrom-Json

$entries = @($catalog.tests | Where-Object { $_.included_in_full_regression })
$results = @($summary.tests)

if ($summary.total -ne $results.Count) {
    Fail-EvidenceReport "summary total $($summary.total) does not match tests array count $($results.Count)"
}

$passedCount = @($results | Where-Object { $_.status -eq "passed" }).Count
$failedCount = @($results | Where-Object { $_.status -ne "passed" }).Count

if ($summary.passed -ne $passedCount -or $summary.failed -ne $failedCount) {
    Fail-EvidenceReport "summary pass/fail counts do not match tests array"
}

$catalogByName = @{}
foreach ($entry in $entries) {
    $catalogByName[$entry.name] = $entry
}

$resultByName = @{}
foreach ($result in $results) {
    if ($resultByName.ContainsKey($result.name)) {
        Fail-EvidenceReport "duplicate test result '$($result.name)'"
    }
    $resultByName[$result.name] = $result
}

$missingFromSummary = @($entries | Where-Object { -not $resultByName.ContainsKey($_.name) } | ForEach-Object { $_.name })
if ($missingFromSummary.Count -ne 0) {
    Fail-EvidenceReport "catalog entries missing from regression summary: $($missingFromSummary -join ', ')"
}

$extraInSummary = @($results | Where-Object { -not $catalogByName.ContainsKey($_.name) } | ForEach-Object { $_.name })
if ($extraInSummary.Count -ne 0) {
    Fail-EvidenceReport "regression summary tests missing catalog metadata: $($extraInSummary -join ', ')"
}

foreach ($result in $results) {
    $entry = $catalogByName[$result.name]
    if ($result.source -ne $entry.source) {
        Fail-EvidenceReport "test '$($result.name)' source '$($result.source)' does not match catalog '$($entry.source)'"
    }
}

$failedResults = @($results | Where-Object { $_.status -ne "passed" })
if ($failedResults.Count -ne 0) {
    $failedNames = @($failedResults | ForEach-Object { "$($_.name):$($_.status)" })
    Fail-EvidenceReport "regression has failed tests: $($failedNames -join ', ')"
}

function Get-CountMap {
    param([object[]]$Values)

    $map = [ordered]@{}
    foreach ($group in ($Values | Group-Object | Sort-Object Name)) {
        $map[$group.Name] = $group.Count
    }
    return $map
}

$failedByCategory = [ordered]@{}
$failedByTag = [ordered]@{}

foreach ($result in $failedResults) {
    $entry = $catalogByName[$result.name]
    if (-not $failedByCategory.Contains($entry.category)) {
        $failedByCategory[$entry.category] = @()
    }
    $failedByCategory[$entry.category] += $result.name

    foreach ($tag in @($entry.tags)) {
        if (-not $failedByTag.Contains($tag)) {
            $failedByTag[$tag] = @()
        }
        $failedByTag[$tag] += $result.name
    }
}

$report = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = "pass"
    total_tests = $results.Count
    passed = $passedCount
    failed = $failedCount
    counts_by_category = Get-CountMap @($entries | ForEach-Object { $_.category })
    counts_by_tag = Get-CountMap @($entries | ForEach-Object { @($_.tags) })
    counts_by_evidence_level = Get-CountMap @($entries | ForEach-Object { $_.evidence_level })
    hierarchical_tests = @($entries | Where-Object { $_.uses_hierarchical_access }).Count
    failed_by_category = $failedByCategory
    failed_by_tag = $failedByTag
}
Add-VerificationIdentityFields -Summary $report | Out-Null

New-Item -ItemType Directory -Force -Path "wave" | Out-Null
$report | ConvertTo-Json -Depth 6 | Set-Content -Path $outputPath -Encoding Ascii

Write-Host "PASS: regression evidence summary matches catalog and regression results"
Write-Host "Regression evidence summary written to wave\regression-evidence-summary.json"
