<#
Script: scripts\demo-smoke.ps1
Purpose: Runs a short reviewer-facing demo smoke sequence.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\demo-smoke.ps1
Outputs:
  Console demo summary and any generated simulation artifacts under wave\.
Scope:
  Local smoke evidence only; not timing closure, board validation, or benchmark proof.
Audience:
  Public demo helper.
#>
param(
    [switch] $UseCachedArchPrograms
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$waveDir = "wave"
$transcriptDir = Join-Path $waveDir "demo-smoke"
New-Item -ItemType Directory -Force -Path $transcriptDir | Out-Null

function Convert-StepNameToFileStem {
    param([string] $Name)

    return ([regex]::Replace($Name, "[^A-Za-z0-9_-]", "_")).Trim("_")
}

function Invoke-DemoStep {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $true)]
        [string] $Script,
        [string[]] $Arguments = @()
    )

    $scriptPath = Join-Path $repoRoot $Script
    $stem = Convert-StepNameToFileStem -Name $Name
    $logPath = Join-Path $transcriptDir "$stem.log"
    $displayCommand = "powershell -ExecutionPolicy Bypass -File $Script"
    if ($Arguments.Count -ne 0) {
        $displayCommand = "$displayCommand $($Arguments -join ' ')"
    }

    Write-Host "========================================"
    Write-Host ("Demo smoke step: {0}" -f $Name)
    Write-Host $displayCommand

    if (-not (Test-Path -LiteralPath $scriptPath)) {
        "Missing script: $Script" | Set-Content -Path $logPath -Encoding Ascii
        return [ordered]@{
            name = $Name
            command = $displayCommand
            status = "fail"
            exit_code = $null
            transcript = $logPath
            error_message = "missing script"
        }
    }

    $start = Get-Date
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $finish = Get-Date
    $output | Set-Content -Path $logPath -Encoding Ascii

    return [ordered]@{
        name = $Name
        command = $displayCommand
        status = if ($exitCode -eq 0) { "pass" } else { "fail" }
        exit_code = $exitCode
        transcript = $logPath
        started_at_utc = $start.ToUniversalTime().ToString("o")
        finished_at_utc = $finish.ToUniversalTime().ToString("o")
        duration_ms = [int64]($finish - $start).TotalMilliseconds
    }
}

function Read-JsonIfPresent {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

$summaryPath = Join-Path $waveDir "demo-smoke-summary.json"
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$steps = [System.Collections.Generic.List[object]]::new()
$failedStep = $null
$caughtError = $null

$summary = [ordered]@{
    generated_at_utc = $null
    status = "running"
    failed_step = $null
    error_message = $null
    steps = @()
    summary_artifacts = [ordered]@{}
    transcript_dir = $transcriptDir
    duration_ms = 0
    claim_boundary = "Focused demonstration smoke over showcase, DMA-lite, selected arch-test, and FPGA packaging. This is not the full regression, board validation, timing closure, or benchmark evidence."
}

try {
    $archTestArgs = @("-Profile", "rv32im-selected")
    if ($UseCachedArchPrograms) {
        $archTestArgs += "-UseCachedPrograms"
    }

    $stepPlan = @(
        @{ name = "showcase demo"; script = "scripts\showcase-demo.ps1"; args = @() },
        @{ name = "interactive showcase demo"; script = "scripts\interactive-showcase-demo.ps1"; args = @() },
        @{ name = "program MATVEC DMA demo"; script = "scripts\run.ps1"; args = @("-Test", "program_matvec_dma_demo") },
        @{ name = "external DMEM MATVEC DMA"; script = "scripts\run.ps1"; args = @("-Test", "external_dmem_matvec_dma") },
        @{ name = "selected arch-test run"; script = "scripts\arch-test-run.ps1"; args = $archTestArgs },
        @{ name = "selected arch-test report"; script = "scripts\arch-test-report.ps1"; args = @() },
        @{ name = "FPGA release package"; script = "scripts\fpga-release.ps1"; args = @("-BoardProfile", "generic_uart_boot_runtime") }
    )

    foreach ($plannedStep in $stepPlan) {
        $result = Invoke-DemoStep -Name $plannedStep.name -Script $plannedStep.script -Arguments $plannedStep.args
        $steps.Add($result) | Out-Null

        if ($result.status -ne "pass") {
            $failedStep = $result.name
            throw "Demo smoke failed during '$($result.name)'. See $($result.transcript)."
        }
    }

    $summary.status = "pass"
} catch {
    $caughtError = $_
    $summary.status = "fail"
    $summary.failed_step = $failedStep
    $summary.error_message = $_.Exception.Message
    Write-Host "FAIL: demo smoke failed"
    Write-Host $_.Exception.Message
} finally {
    $stopwatch.Stop()
    $summary.generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    $summary.steps = $steps.ToArray()
    $summary.duration_ms = $stopwatch.ElapsedMilliseconds
    $summary.summary_artifacts = [ordered]@{
        arch_program_image_mode = if ($UseCachedArchPrograms) { "cached_prebuilt" } else { "rebuilt" }
        showcase = [ordered]@{
            path = "wave\showcase-summary.json"
            present = (Test-Path -LiteralPath "wave\showcase-summary.json")
        }
        interactive_showcase = [ordered]@{
            path = "wave\interactive-showcase-summary.json"
            present = (Test-Path -LiteralPath "wave\interactive-showcase-summary.json")
        }
        arch_test_results = [ordered]@{
            path = "wave\arch-test-results.json"
            present = (Test-Path -LiteralPath "wave\arch-test-results.json")
            status = $(if ($null -eq (Read-JsonIfPresent "wave\arch-test-results.json")) { $null } else { (Read-JsonIfPresent "wave\arch-test-results.json").status })
        }
        arch_test_report = [ordered]@{
            path = "wave\arch-test-report.json"
            present = (Test-Path -LiteralPath "wave\arch-test-report.json")
            status = $(if ($null -eq (Read-JsonIfPresent "wave\arch-test-report.json")) { $null } else { (Read-JsonIfPresent "wave\arch-test-report.json").status })
        }
        fpga_release = [ordered]@{
            path = "release\fpga\generic_uart_boot_runtime\status.json"
            present = (Test-Path -LiteralPath "release\fpga\generic_uart_boot_runtime\status.json")
            status = $(if ($null -eq (Read-JsonIfPresent "release\fpga\generic_uart_boot_runtime\status.json")) { $null } else { (Read-JsonIfPresent "release\fpga\generic_uart_boot_runtime\status.json").status })
        }
    }
    $summary | ConvertTo-Json -Depth 8 | Set-Content -Path $summaryPath -Encoding Ascii
    Write-Host "Demo smoke summary written to wave\demo-smoke-summary.json"
}

if ($null -ne $caughtError) {
    throw $caughtError
}

Write-Host "========================================"
Write-Host "PASS: demo smoke completed"
