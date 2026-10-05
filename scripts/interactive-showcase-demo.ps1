<#
Script: scripts\interactive-showcase-demo.ps1
Purpose: Runs the interactive UART showcase demo flow.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\interactive-showcase-demo.ps1
Outputs:
  Console transcript summary and simulation artifacts under results\.
#>
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/result-format.ps1"
. "$PSScriptRoot/verification-source-identity.ps1"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

New-Item -ItemType Directory -Force -Path "results" | Out-Null

$summary = [ordered]@{
    status = "running"
    claim_boundary = "simulation_only_not_board_proven"
    assembled = $false
    boot_packet_fixture = $false
    program_interactive_showcase_demo = $false
    fpga_uart_boot_runtime_rx_showcase = $false
    transcript = "RV32IM INTERACTIVE\nREADY\nCMD M\nMATVEC PASS\nCOUNTERS PASS\nINTERACTIVE PASS\n"
    gpio_phases = @("0x11", "0x22", "0x33", "0x44", "0x55", "0xa5")
    pass_marker = "0x1acecafe"
    started_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    finished_at_utc = $null
}

$caughtError = $null

function Write-InteractiveSummary {
    $summary.finished_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    Write-ResultJson $summary "results\interactive-showcase-summary.json"
    Write-Host "Interactive showcase summary written to results\interactive-showcase-summary.json"
}

Write-ResultJson $summary 'results/interactive-showcase-summary.json'
try {
    Add-VerificationIdentityFields -Summary $summary | Out-Null
    Write-Host "========================================"
    Write-Host "Assembling interactive showcase demo"
    & (Join-Path $PSScriptRoot "assemble.ps1")
    $summary.assembled = $true

    Write-Host "========================================"
    Write-Host "Checking interactive showcase UART boot packet fixture"
    & (Join-Path $PSScriptRoot "uart-boot-packet.ps1") -Hex "firmware\hex\showcase\interactive_showcase_demo.hex" -DryRun -Check
    $summary.boot_packet_fixture = $true

    Write-Host "========================================"
    Write-Host "Running direct CPU interactive showcase"
    & (Join-Path $PSScriptRoot "run.ps1") -Test program_interactive_showcase_demo -SkipAssemble
    $summary.program_interactive_showcase_demo = $true

    Write-Host "========================================"
    Write-Host "Running packet boot runtime RX showcase"
    & (Join-Path $PSScriptRoot "run.ps1") -Test fpga_uart_boot_runtime_rx_showcase -SkipAssemble
    $summary.fpga_uart_boot_runtime_rx_showcase = $true

    $summary.status = "pass"
} catch {
    $caughtError = $_
    $summary.status = "fail"
    $summary.error_message = $_.Exception.Message
    Write-Host "FAIL: interactive showcase demo helper failed"
    Write-Host $_.Exception.Message
} finally {
    Write-InteractiveSummary
}

if ($null -ne $caughtError) {
    throw $caughtError
}

Write-Host "========================================"
Write-Host "PASS: interactive showcase demo simulation flow completed"
