<#
Script: scripts\perf-counter-csv.ps1
Purpose: Exports the checked-in performance-counter comparison data as CSV.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\perf-counter-csv.ps1 -OutputPath wave\perf-counter-comparison.csv
Outputs:
  CSV performance-counter snapshot file.
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

$rows = @(Get-PerfCounterRows)

if ($OutputPath -eq "") {
    $rows | ConvertTo-Csv -NoTypeInformation
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

$rows | Export-Csv -NoTypeInformation -Path $resolvedOutputPath
Write-Host "Wrote performance counter CSV to $resolvedOutputPath"
