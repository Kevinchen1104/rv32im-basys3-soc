<#
Script: scripts\perf-counter-data.ps1
Purpose: Provides shared performance-counter scenario metadata for report helpers.
Common usage:
  . scripts\perf-counter-data.ps1
Outputs:
  PowerShell objects consumed by performance-counter helper scripts.
Scope:
  Internal data helper only; not a standalone verification result.
Audience:
  Internal helper dot-sourced by performance-counter scripts.
#>
$ErrorActionPreference = "Stop"

function Get-PerfCounterRows {
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
