<#
Script: scripts\perf-counter-data.ps1
Purpose: Collects live performance counters and keeps regression expectations separate.
Common usage:
  . scripts\perf-counter-data.ps1
Outputs:
  PowerShell objects consumed by performance-counter helper scripts.
#>
$ErrorActionPreference = "Stop"

function Get-ExpectedPerfCounterRows {
    return @(
        [pscustomobject]@{
            Scenario = "perf_counters"
            Cycles = 120
            Retired = 53
            BranchMisses = 1
            ICacheMisses = 15
            DCacheMisses = 1
            StallCycles = 63
            SourceTest = "tb/unit/core/tb_perf_counters.v"
            Notes = "Compact directed smoke path for reset, branch, cache, and stall events"
        }
        [pscustomobject]@{
            Scenario = "program_counter_loop"
            Cycles = 101
            Retired = 71
            BranchMisses = 3
            ICacheMisses = 5
            DCacheMisses = 2
            StallCycles = 23
            SourceTest = "tb/program/examples/tb_program_counter_loop.v"
            Notes = "Assembled loop workload; branch and D-cache misses count accepted recovery/miss transactions once"
        }
    )
}

function Get-PerfCounterRows {
    param([switch]$SkipAssemble)

    $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    if (-not $SkipAssemble) { & (Join-Path $PSScriptRoot 'assemble.ps1') -Check }
    $scenarios = @(
        @{ Name = 'perf_counters'; Prefix = 'perf counters'; Source = 'tb/unit/core/tb_perf_counters.v';
           Notes = 'Compact directed smoke path for reset, branch, cache, and stall events' },
        @{ Name = 'program_counter_loop'; Prefix = 'counter_loop'; Source = 'tb/program/examples/tb_program_counter_loop.v';
           Notes = 'Assembled loop workload; branch and D-cache misses count accepted recovery/miss transactions once' }
    )
    foreach ($scenario in $scenarios) {
        $summaryPath = Join-Path $root "results/$($scenario.Name)-summary.json"
        & (Join-Path $PSScriptRoot 'run.ps1') -Test $scenario.Name -SkipAssemble -SummaryJson $summaryPath
        $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
        if ($summary.status -ne 'passed' -or $summary.tests.Count -ne 1) {
            throw "Counter source test did not pass: $($scenario.Name)"
        }
        $log = Join-Path $root $summary.tests[0].simulation.log
        $pattern = '^INFO: ' + [regex]::Escape($scenario.Prefix) +
            ' cycles=(\d+) retired=(\d+) branch_miss=(\d+) icache_miss=(\d+) dcache_miss=(\d+) stall_cycles=(\d+)\s*$'
        $matches = @(Select-String -LiteralPath $log -Pattern $pattern)
        if ($matches.Count -ne 1) {
            throw "Expected exactly one counter INFO line for $($scenario.Name); found $($matches.Count) in $log"
        }
        $groups = $matches[0].Matches[0].Groups
        [pscustomobject][ordered]@{
            Scenario = $scenario.Name
            Cycles = [int64]$groups[1].Value
            Retired = [int64]$groups[2].Value
            BranchMisses = [int64]$groups[3].Value
            ICacheMisses = [int64]$groups[4].Value
            DCacheMisses = [int64]$groups[5].Value
            StallCycles = [int64]$groups[6].Value
            SourceTest = $scenario.Source
            Notes = $scenario.Notes
        }
    }
}
