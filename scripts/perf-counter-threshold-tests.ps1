<#
Script: scripts\perf-counter-threshold-tests.ps1
Purpose: Self-tests performance-counter threshold comparison behavior.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\perf-counter-threshold-tests.ps1
Outputs:
  Temporary threshold-test JSON files under wave\perf-counter-threshold-tests.
Scope:
  Helper self-test only; not hardware performance evidence.
Audience:
  Internal helper used by scripts\check.ps1.
#>
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$fixtureDir = Join-Path $repoRoot "wave\perf-counter-threshold-tests"
$baselinePath = Join-Path $fixtureDir "baseline.json"
$withinThresholdPath = Join-Path $fixtureDir "within-threshold.json"
$violationPath = Join-Path $fixtureDir "threshold-violation.json"
$thresholdPath = Join-Path $repoRoot "scripts\perf-counter-thresholds.example.json"

New-Item -ItemType Directory -Force -Path $fixtureDir | Out-Null

& (Join-Path $PSScriptRoot "perf-counter-json.ps1") -OutputPath $baselinePath

function Write-AdjustedSnapshot {
    param(
        [string]$OutputPath,
        [string]$Scenario,
        [string]$Metric,
        [int64]$Delta
    )

    $snapshot = Get-Content -Raw $baselinePath | ConvertFrom-Json
    $matched = $false
    foreach ($row in $snapshot.Rows) {
        if ($row.Scenario -eq $Scenario) {
            $row.$Metric = [int64]$row.$Metric + $Delta
            $matched = $true
        }
    }

    if (-not $matched) {
        throw "Fixture scenario not found: $Scenario"
    }

    $snapshot | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputPath -Encoding Ascii
}

Write-AdjustedSnapshot `
    -OutputPath $withinThresholdPath `
    -Scenario "program_counter_loop" `
    -Metric "Cycles" `
    -Delta 1

& (Join-Path $PSScriptRoot "perf-counter-compare.ps1") `
    -BaselinePath $baselinePath `
    -CurrentPath $withinThresholdPath `
    -ThresholdPath $thresholdPath `
    -FailOnDifference

Write-AdjustedSnapshot `
    -OutputPath $violationPath `
    -Scenario "perf_counters" `
    -Metric "Cycles" `
    -Delta 1

$sawExpectedFailure = $false
try {
    & (Join-Path $PSScriptRoot "perf-counter-compare.ps1") `
        -BaselinePath $baselinePath `
        -CurrentPath $violationPath `
        -ThresholdPath $thresholdPath `
        -FailOnDifference
}
catch {
    if ($_.Exception.Message -notmatch "Performance counter snapshots differ") {
        throw
    }

    $sawExpectedFailure = $true
}

if (-not $sawExpectedFailure) {
    throw "Expected strict threshold violation did not fail"
}

Write-Host "PASS: performance counter threshold fixture tests passed"
