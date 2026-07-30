<#
Script: scripts\perf-counter-json.ps1
Purpose: Exports the checked-in performance-counter comparison data as JSON.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\perf-counter-json.ps1 -OutputPath wave\perf-counter-comparison.json
Outputs:
  JSON performance-counter snapshot file.
Scope:
  Data-format helper only; not a benchmark or speedup claim.
Audience:
  Internal performance-counter helper.
#>
param(
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
. (Join-Path $PSScriptRoot "perf-counter-data.ps1")

$snapshot = [pscustomobject]@{
    Schema = "riscv-cpu-performance-counter-snapshot-v1"
    Units = [pscustomobject]@{
        Cycles = "cycles"
        Retired = "instructions"
        BranchMisses = "events"
        ICacheMisses = "events"
        DCacheMisses = "events"
        StallCycles = "cycles"
    }
    Rows = @(Get-PerfCounterRows)
    ClaimBoundary = "Simulation regression evidence only; not an FPGA frequency, CPI, or benchmark-performance claim."
}

$json = $snapshot | ConvertTo-Json -Depth 6

if ($OutputPath -eq "") {
    $json
    return
}

$resolvedOutputPath = if ([System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath
} else {
    Join-Path $repoRoot $OutputPath
}

$outputDirectory = Split-Path -Parent $resolvedOutputPath
if ($outputDirectory -ne "") {
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}

Set-Content -Path $resolvedOutputPath -Value $json -Encoding Ascii
Write-Host "Wrote performance counter JSON to $resolvedOutputPath"
