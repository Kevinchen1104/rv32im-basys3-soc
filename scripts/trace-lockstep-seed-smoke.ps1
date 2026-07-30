<#
Script: scripts\trace-lockstep-seed-smoke.ps1
Purpose: Runs extra-seed smoke checks for retired-trace lockstep reference generation.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\trace-lockstep-seed-smoke.ps1
Outputs:
  wave\trace-lockstep-seed-smoke-summary.json and temporary generated trace fixtures.
Scope:
  Determinism smoke evidence only; not exhaustive trace verification.
Audience:
  Internal helper used by scripts\check.ps1.
#>
param(
    [string]$SummaryJson = "wave\trace-lockstep-seed-smoke-summary.json"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

New-Item -ItemType Directory -Force -Path "wave" | Out-Null

$seeds = @(101, 202, 303)
$rows = @()

function Invoke-ChildPowerShell {
    param(
        [string]$Description,
        [string[]]$Arguments
    )

    $output = & powershell -NoProfile -ExecutionPolicy Bypass @Arguments 2>&1
    return [pscustomobject]@{
        description = $Description
        exit_code = $LASTEXITCODE
        output = @($output | ForEach-Object { $_.ToString() })
    }
}

function Write-SmokeSummary {
    param([object[]]$Rows)

    $summaryPath = if ([System.IO.Path]::IsPathRooted($SummaryJson)) {
        $SummaryJson
    } else {
        Join-Path $repoRoot $SummaryJson
    }
    $summaryDirectory = Split-Path -Parent $summaryPath
    if ($summaryDirectory -ne "") {
        New-Item -ItemType Directory -Force -Path $summaryDirectory | Out-Null
    }

    $summary = [ordered]@{
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        status = if (@($Rows | Where-Object { $_.status -ne "passed" }).Count -eq 0) { "passed" } else { "failed" }
        total = $Rows.Count
        passed = @($Rows | Where-Object { $_.status -eq "passed" }).Count
        failed = @($Rows | Where-Object { $_.status -ne "passed" }).Count
        tests = $Rows
    }

    $summary | ConvertTo-Json -Depth 6 | Set-Content -Path $summaryPath -Encoding Ascii
    Write-Host "Trace lockstep seed smoke summary written to $summaryPath"
}

foreach ($seed in $seeds) {
    $seedDir = "wave/trace_lockstep_seed_$seed"
    New-Item -ItemType Directory -Force -Path $seedDir | Out-Null

    $programPath = "$seedDir/trace_lockstep_reference.hex"
    $expectedPath = "$seedDir/trace_lockstep_expected.hex"
    $jsonPath = "$seedDir/trace_lockstep_expected.json"

    Write-Host "========================================"
    Write-Host "Generating trace lockstep seed smoke fixture: seed $seed"
    $generate = Invoke-ChildPowerShell `
        -Description "trace-lockstep-reference seed $seed" `
        -Arguments @(
            "-File", (Join-Path $PSScriptRoot "trace-lockstep-reference.ps1"),
            "-Seed", [string]$seed,
            "-ProgramPath", $programPath,
            "-ExpectedTracePath", $expectedPath,
            "-ExpectedJsonPath", $jsonPath,
            "-SkipSimulation"
        )

    if ($generate.exit_code -ne 0) {
        $rows += [pscustomobject]@{
            seed = $seed
            status = "generate_failed"
            trace_count = 0
            command = $generate.description
            exit_code = $generate.exit_code
            generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        }
        Write-Host "FAIL: seed $seed fixture generation failed"
        $generate.output | ForEach-Object { Write-Host "  $_" }
        continue
    }

    $metadata = Get-Content -Raw -Path $jsonPath | ConvertFrom-Json
    $traceCount = [int]$metadata.trace_count

    Write-Host "Running trace lockstep seed smoke: seed $seed, trace rows $traceCount"
    $run = Invoke-ChildPowerShell `
        -Description "run trace_lockstep_reference seed $seed" `
        -Arguments @(
            "-File", (Join-Path $PSScriptRoot "run.ps1"),
            "-Test", "trace_lockstep_reference",
            "-PlusArgs",
            "+program_hex=$programPath +expected_trace=$expectedPath +trace_count=$traceCount"
        )

    $status = if ($run.exit_code -eq 0) { "passed" } else { "simulation_failed" }
    $rows += [pscustomobject]@{
        seed = $seed
        status = $status
        trace_count = $traceCount
        program_hex = $programPath
        expected_trace = $expectedPath
        expected_json = $jsonPath
        command = $run.description
        exit_code = $run.exit_code
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    }

    if ($status -ne "passed") {
        Write-Host "FAIL: seed $seed lockstep simulation failed"
        $run.output | ForEach-Object { Write-Host "  $_" }
    }
}

Write-SmokeSummary -Rows $rows

$failedRows = @($rows | Where-Object { $_.status -ne "passed" })
if ($failedRows.Count -ne 0) {
    throw "trace lockstep seed smoke failed"
}

Write-Host "========================================"
Write-Host "PASS: trace lockstep seed smoke passed ($($rows.Count) seed runs)"
