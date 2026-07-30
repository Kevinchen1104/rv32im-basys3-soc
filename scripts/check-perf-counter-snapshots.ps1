<#
Script: scripts\check-perf-counter-snapshots.ps1
Purpose: Checks performance-counter snapshot fixtures against live simulation output.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\check-perf-counter-snapshots.ps1
Outputs:
  Console freshness report and temporary comparison data under wave\.
Scope:
  Counter observability regression only; not a timing, CPI, speedup, or benchmark claim.
Audience:
  Internal helper used by scripts\check.ps1.
#>
param(
    [switch]$SkipAssemble
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

. (Join-Path $PSScriptRoot "perf-counter-data.ps1")

if (-not $SkipAssemble) {
    & (Join-Path $PSScriptRoot "assemble.ps1") -Check
}

$metricFields = @(
    "Cycles",
    "Retired",
    "BranchMisses",
    "ICacheMisses",
    "DCacheMisses",
    "StallCycles"
)

function Invoke-CounterTest {
    param(
        [string]$Scenario,
        [string]$InfoPrefix
    )

    $output = & (Join-Path $PSScriptRoot "run.ps1") -Test $Scenario -SkipAssemble 2>&1
    if ($LASTEXITCODE -ne 0) {
        $output | ForEach-Object { Write-Host $_ }
        throw "Counter snapshot source test failed: $Scenario"
    }

    $pattern = "INFO: $InfoPrefix cycles=(\d+) retired=(\d+) branch_miss=(\d+) icache_miss=(\d+) dcache_miss=(\d+) stall_cycles=(\d+)"
    $match = $output | Select-String -Pattern $pattern | Select-Object -Last 1

    if ($null -eq $match) {
        $output | ForEach-Object { Write-Host $_ }
        throw "Missing counter INFO line for $Scenario"
    }

    $groups = $match.Matches[0].Groups
    return [pscustomobject]@{
        Scenario = $Scenario
        Cycles = [int]$groups[1].Value
        Retired = [int]$groups[2].Value
        BranchMisses = [int]$groups[3].Value
        ICacheMisses = [int]$groups[4].Value
        DCacheMisses = [int]$groups[5].Value
        StallCycles = [int]$groups[6].Value
    }
}

$expectedRows = @(Get-PerfCounterRows)
$actualRows = @(
    Invoke-CounterTest -Scenario "perf_counters" -InfoPrefix "perf counters"
    Invoke-CounterTest -Scenario "program_counter_loop" -InfoPrefix "counter_loop"
)

$mismatches = @()

foreach ($actual in $actualRows) {
    $expected = $expectedRows | Where-Object { $_.Scenario -eq $actual.Scenario } | Select-Object -First 1
    if ($null -eq $expected) {
        $mismatches += "Missing expected snapshot row for $($actual.Scenario)"
        continue
    }

    foreach ($field in $metricFields) {
        if ($expected.$field -ne $actual.$field) {
            $mismatches += "$($actual.Scenario) $field expected=$($expected.$field) actual=$($actual.$field)"
        }
    }
}

foreach ($expected in $expectedRows) {
    $actual = $actualRows | Where-Object { $_.Scenario -eq $expected.Scenario } | Select-Object -First 1
    if ($null -eq $actual) {
        $mismatches += "Snapshot row has no live test coverage: $($expected.Scenario)"
    }
}

if ($mismatches.Count -ne 0) {
    Write-Host "FAIL: performance counter snapshots are stale"
    $mismatches | ForEach-Object { Write-Host "  $_" }
    throw "Performance counter snapshot check failed"
}

Write-Host "PASS: performance counter snapshots match live test INFO lines"
