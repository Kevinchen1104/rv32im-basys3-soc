<#
Script: scripts\showcase-demo.ps1
Purpose: Runs the main showcase demo simulation flow.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\showcase-demo.ps1
Outputs:
  Console transcript summary and simulation artifacts under wave\.
Scope:
  Simulation demo evidence only; not physical board validation or production software evidence.
Audience:
  Public showcase helper.
#>
param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$programName = "showcase_demo"
$programHex = "firmware\hex\showcase\$programName.hex"
$summaryPath = "wave\showcase-summary.json"
$expectedTranscript = "RV32IM SHOWCASE`nUART OK`nMATVEC PASS`nCOUNTERS PASS`nSHOWCASE PASS`n"
$tests = @("program_showcase_demo", "fpga_uart_boot_showcase", "fpga_uart_boot_bram_soc_showcase")

function To-UInt32 {
    param([int64]$Value)
    return [uint32]($Value -band 0xffffffffL)
}

function Format-HexWord {
    param([uint32]$Value)
    return "0x{0:x8}" -f $Value
}

Write-Host "========================================"
Write-Host "Assembling showcase program"
& (Join-Path $PSScriptRoot "assemble.ps1") -Programs $programName

if (-not (Test-Path -LiteralPath $programHex)) {
    throw "Showcase program hex missing after assembly: $programHex"
}

$payloadWords = [System.Collections.Generic.List[uint32]]::new()
foreach ($rawLine in Get-Content -LiteralPath $programHex) {
    $line = $rawLine.Trim()
    if ($line -eq "" -or $line.StartsWith("#")) {
        continue
    }
    $payloadWords.Add([uint32]([Convert]::ToUInt32($line, 16))) | Out-Null
}

$checksum = [uint32]0
foreach ($word in $payloadWords) {
    $checksum = To-UInt32 ([int64]$checksum + [int64]$word)
}
$bootPacketByteCount = ($payloadWords.Count + 5) * 4

Write-Host "========================================"
Write-Host "Checking showcase UART boot packet fixture"
& (Join-Path $PSScriptRoot "uart-boot-packet.ps1") -Hex $programHex -DryRun -Check

foreach ($test in $tests) {
    Write-Host "========================================"
    Write-Host "Running showcase test: $test"
    & (Join-Path $PSScriptRoot "run.ps1") -Test $test
}

New-Item -ItemType Directory -Force -Path "wave" | Out-Null

$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    program_hex = $programHex
    program_word_count = $payloadWords.Count
    boot_packet_byte_count = $bootPacketByteCount
    boot_packet_checksum = Format-HexWord $checksum
    expected_transcript = $expectedTranscript
    expected_gpio_phases = @(
        "0x00000001 start",
        "0x00000002 UART printed",
        "0x00000004 MATVEC running",
        "0x00000008 MATVEC pass",
        "0x00000010 counter sample pass",
        "0x000000a5 final pass"
    )
    observed_pass_signature = "0x5a5ecafe"
    matvec_case = "MATVEC Scratchpad x=[1,-2,3,-4], four signed int8 rows, expected y=[-10,-6,386,70], MATVEC_PERF.completed_ops=1"
    counter_checks = "cycle_count after >= before, retired_count nonzero, stall_cycle_count after >= before, MATVEC-related counter MMIO values sampled without changing meanings"
    external_dmem_path = "fpga_uart_boot_bram_soc_showcase checks external IMEM packet boot plus separate external DMem read/write traffic and stored MATVEC/counter snapshots"
    tests_run = $tests
    claim_boundary = "simulation only; not physical board evidence, timing evidence, or benchmark evidence"
}

$summary | ConvertTo-Json -Depth 5 | Set-Content -Path $summaryPath -Encoding Ascii

Write-Host "========================================"
Write-Host "PASS: showcase demo completed"
Write-Host "Showcase summary written to $summaryPath"
