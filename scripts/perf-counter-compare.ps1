<#
Script: scripts\perf-counter-compare.ps1
Purpose: Compares two performance-counter snapshot JSON files.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\perf-counter-compare.ps1 -BaselinePath <old.json> -CurrentPath <new.json>
Outputs:
  Console table of counter deltas and optional failure status.
Scope:
  Counter regression helper only; not a speedup, CPI, timing, or benchmark proof.
Audience:
  Internal performance-counter helper.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$BaselinePath,

    [Parameter(Mandatory = $true)]
    [string]$CurrentPath,

    [string]$ThresholdPath,

    [switch]$FailOnDifference
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$expectedSchema = "riscv-cpu-performance-counter-snapshot-v1"
$expectedThresholdSchema = "riscv-cpu-performance-counter-thresholds-v1"
$metricNames = @(
    "Cycles",
    "Retired",
    "BranchMisses",
    "ICacheMisses",
    "DCacheMisses",
    "StallCycles"
)

function Resolve-RepoPath {
    param([string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return (Join-Path $repoRoot $Path)
}

function Read-Snapshot {
    param(
        [string]$Path,
        [string]$Label
    )

    $resolvedPath = Resolve-RepoPath $Path
    if (-not (Test-Path $resolvedPath)) {
        throw "$Label snapshot not found: $resolvedPath"
    }

    $snapshot = Get-Content -Raw $resolvedPath | ConvertFrom-Json
    if ($snapshot.Schema -ne $expectedSchema) {
        throw "$Label snapshot schema mismatch: expected $expectedSchema, got $($snapshot.Schema)"
    }

    return $snapshot
}

function Read-Thresholds {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $resolvedPath = Resolve-RepoPath $Path
    if (-not (Test-Path $resolvedPath)) {
        throw "Threshold file not found: $resolvedPath"
    }

    $thresholds = Get-Content -Raw $resolvedPath | ConvertFrom-Json
    if ($thresholds.Schema -ne $expectedThresholdSchema) {
        throw "Threshold schema mismatch: expected $expectedThresholdSchema, got $($thresholds.Schema)"
    }

    $rulesByScenario = @{}
    foreach ($rule in $thresholds.Rules) {
        if ([string]::IsNullOrWhiteSpace($rule.Scenario)) {
            throw "Threshold file contains a rule without Scenario"
        }

        if ($rulesByScenario.ContainsKey($rule.Scenario)) {
            throw "Threshold file contains duplicate Scenario '$($rule.Scenario)'"
        }

        foreach ($metric in $rule.Metrics.PSObject.Properties.Name) {
            if ($metricNames -notcontains $metric) {
                throw "Threshold rule '$($rule.Scenario)' contains unknown metric '$metric'"
            }

            if ($null -eq $rule.Metrics.$metric.MaxAbsDelta) {
                throw "Threshold rule '$($rule.Scenario)' metric '$metric' is missing MaxAbsDelta"
            }
        }

        $rulesByScenario[$rule.Scenario] = $rule
    }

    return $rulesByScenario
}

function Get-RowsByScenario {
    param(
        [object[]]$Rows,
        [string]$Label
    )

    $rowsByScenario = @{}
    foreach ($row in $Rows) {
        if ([string]::IsNullOrWhiteSpace($row.Scenario)) {
            throw "$Label snapshot contains a row without Scenario"
        }

        if ($rowsByScenario.ContainsKey($row.Scenario)) {
            throw "$Label snapshot contains duplicate Scenario '$($row.Scenario)'"
        }

        $rowsByScenario[$row.Scenario] = $row
    }

    return $rowsByScenario
}

$baseline = Read-Snapshot $BaselinePath "Baseline"
$current = Read-Snapshot $CurrentPath "Current"
$thresholdRules = Read-Thresholds $ThresholdPath

$baselineRows = Get-RowsByScenario $baseline.Rows "Baseline"
$currentRows = Get-RowsByScenario $current.Rows "Current"

$allScenarios = @($baselineRows.Keys + $currentRows.Keys | Sort-Object -Unique)
$differences = @()

foreach ($scenario in $allScenarios) {
    if (-not $baselineRows.ContainsKey($scenario)) {
        $differences += [pscustomobject]@{
            Scenario = $scenario
            Metric = "<row>"
            Baseline = "<missing>"
            Current = "<present>"
            Delta = ""
        }
        continue
    }

    if (-not $currentRows.ContainsKey($scenario)) {
        $differences += [pscustomobject]@{
            Scenario = $scenario
            Metric = "<row>"
            Baseline = "<present>"
            Current = "<missing>"
            Delta = ""
        }
        continue
    }

    foreach ($metric in $metricNames) {
        $baselineValue = [int64]$baselineRows[$scenario].$metric
        $currentValue = [int64]$currentRows[$scenario].$metric
        $delta = $currentValue - $baselineValue

        if ($delta -ne 0) {
            $differences += [pscustomobject]@{
                Scenario = $scenario
                Metric = $metric
                Baseline = $baselineValue
                Current = $currentValue
                Delta = $delta
            }
        }
    }
}

$thresholdViolations = @()
if ($null -ne $thresholdRules) {
    foreach ($difference in $differences) {
        if ($difference.Metric -eq "<row>") {
            $thresholdViolations += [pscustomobject]@{
                Scenario = $difference.Scenario
                Metric = $difference.Metric
                Delta = $difference.Delta
                MaxAbsDelta = ""
                Reason = "Row added or removed"
            }
            continue
        }

        if (-not $thresholdRules.ContainsKey($difference.Scenario)) {
            $thresholdViolations += [pscustomobject]@{
                Scenario = $difference.Scenario
                Metric = $difference.Metric
                Delta = $difference.Delta
                MaxAbsDelta = ""
                Reason = "No threshold rule for scenario"
            }
            continue
        }

        $rule = $thresholdRules[$difference.Scenario]
        $metricRuleProperty = $rule.Metrics.PSObject.Properties[$difference.Metric]
        if ($null -eq $metricRuleProperty) {
            $thresholdViolations += [pscustomobject]@{
                Scenario = $difference.Scenario
                Metric = $difference.Metric
                Delta = $difference.Delta
                MaxAbsDelta = ""
                Reason = "No threshold for metric"
            }
            continue
        }

        $maxAbsDelta = [int64]$metricRuleProperty.Value.MaxAbsDelta
        if ([Math]::Abs([int64]$difference.Delta) -gt $maxAbsDelta) {
            $thresholdViolations += [pscustomobject]@{
                Scenario = $difference.Scenario
                Metric = $difference.Metric
                Delta = $difference.Delta
                MaxAbsDelta = $maxAbsDelta
                Reason = "Delta exceeds threshold"
            }
        }
    }
}

if ($differences.Count -eq 0) {
    Write-Host "PASS: performance counter snapshots match"
    return
}

Write-Host "Performance counter differences:"
$differences | Format-Table -AutoSize

if ($null -ne $thresholdRules) {
    if ($thresholdViolations.Count -eq 0) {
        Write-Host "PASS: performance counter differences are within configured thresholds"
    }
    else {
        Write-Host "Performance counter threshold violations:"
        $thresholdViolations | Format-Table -AutoSize
    }
}

if ($FailOnDifference -and (($null -eq $thresholdRules) -or ($thresholdViolations.Count -gt 0))) {
    throw "Performance counter snapshots differ"
}
