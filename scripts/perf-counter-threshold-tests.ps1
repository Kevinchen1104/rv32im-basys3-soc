<#
Script: scripts\perf-counter-threshold-tests.ps1
Purpose: Self-tests performance-counter threshold comparison behavior.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\perf-counter-threshold-tests.ps1
Outputs:
  Temporary threshold-test JSON files under build\tests\perf-counters.
#>
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$fixtureDir = Join-Path $repoRoot "build\tests\perf-counters"
$baselinePath = Join-Path $fixtureDir "baseline.json"
$withinThresholdPath = Join-Path $fixtureDir "within-threshold.json"
$violationPath = Join-Path $fixtureDir "threshold-violation.json"
$thresholdPath = Join-Path $repoRoot "scripts\perf-counter-thresholds.example.json"

New-Item -ItemType Directory -Force -Path $fixtureDir | Out-Null

. "$PSScriptRoot/perf-counter-data.ps1"
. "$PSScriptRoot/result-format.ps1"
Write-ResultJson ([ordered]@{ Schema='riscv-cpu-performance-counter-snapshot-v1'; Status='fixture'; Source='synthetic threshold fixture'; Rows=@(Get-ExpectedPerfCounterRows) }) $baselinePath

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

    Write-ResultJson $snapshot $OutputPath
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

foreach ($case in @('failed', 'empty', 'missing', 'negative', 'fraction', 'boolean', 'overflow')) {
    $invalid = Get-Content -Raw $baselinePath | ConvertFrom-Json
    switch ($case) {
        failed { $invalid.Status = 'fail' }
        empty { $invalid.Rows = @() }
        missing { $invalid.Rows[0].PSObject.Properties.Remove('Cycles') }
        negative { $invalid.Rows[0].Cycles = -1 }
        fraction { $invalid.Rows[0].Cycles = 0.5 }
        boolean { $invalid.Rows[0].Cycles = $false }
        overflow { $invalid.Rows[0].Cycles = 4294967296L }
    }
    $invalidPath = Join-Path $fixtureDir "$case.json"
    Write-ResultJson $invalid $invalidPath
    $rejected = $false
    try {
        & "$PSScriptRoot/perf-counter-compare.ps1" -BaselinePath $invalidPath -CurrentPath $invalidPath -FailOnDifference
    } catch { $rejected = $true }
    if (-not $rejected) { throw "Invalid counter fixture was accepted: $case" }
}
Write-Host 'PASS: seven malformed/failed counter snapshots were rejected'
foreach ($value in @(-1, 0.5, $true, 4294967296L)) {
    $invalid = Get-Content -Raw $thresholdPath | ConvertFrom-Json
    $invalid.Rules[0].Metrics.Cycles.MaxAbsDelta = $value
    $invalidPath = Join-Path $fixtureDir 'invalid-threshold.json'
    Write-ResultJson $invalid $invalidPath
    $rejected = $false
    try {
        & "$PSScriptRoot/perf-counter-compare.ps1" -BaselinePath $baselinePath -CurrentPath $baselinePath -ThresholdPath $invalidPath -FailOnDifference
    } catch { $rejected = $_.Exception.Message -like '*MaxAbsDelta*' }
    if (-not $rejected) { throw "Invalid threshold was accepted: $value" }
}
Write-Host 'PASS: malformed thresholds were rejected even when counters match'
