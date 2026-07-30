<#
Script: scripts\synth-smoke.ps1
Purpose: Runs Yosys synthesis smoke checks for selected top-level modules when available.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\synth-smoke.ps1
Outputs:
  Synthesis logs and JSON/stat artifacts under wave\synth-smoke or blocked-tool status.
Scope:
  Synthesis smoke evidence only; not timing closure or physical board validation.
Audience:
  Public optional synthesis check.
#>
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. "$PSScriptRoot\verification-source-identity.ps1"

$yosysCommand = Get-Command yosys -ErrorAction SilentlyContinue
if ($null -eq $yosysCommand) {
    throw "Yosys not found on PATH. Install Yosys to run optional synthesis smoke."
}

$sources = Get-Content -LiteralPath "rtl/rtl_sources.f" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
foreach ($source in $sources) {
    if (-not (Test-Path $source)) {
        throw "Missing synthesis source: $source"
    }
}

New-Item -ItemType Directory -Force -Path "wave" | Out-Null

$tops = @(
    "RISCVCPU",
    "RISCVCPU_fpga_top",
    "RISCVCPU_uart_boot_fpga_top",
    "RISCVCPU_uart_boot_bram_soc_top",
    "RISCVCPU_uart_boot_runtime_soc_top",
    "RISCVCPU_fpga_debug_led_top",
    "RISCVCPU_basys3_top",
    "RISCVCPU_basys3_board_smoke_top",
    "RISCVCPU_basys3_full_lowfreq_top",
    "int8_matvec_scratchpad_accelerator",
    "int8_matvec_dma_lite",
    "machine_timer",
    "mmio_decode",
    "csr_unit"
)

$readSources = ($sources | ForEach-Object { $_ -replace "\\", "/" }) -join " "
$checkedTops = [System.Collections.Generic.List[object]]::new()

foreach ($top in $tops) {
    $logPath = "wave\synth-smoke-$top.log"
    $scriptPath = "wave\synth-smoke-$top.ys"
    $yosysScript = @(
        "read_verilog -sv $readSources",
        "hierarchy -check -top $top",
        "proc",
        "opt",
        "check"
    )

    Set-Content -Path $scriptPath -Value $yosysScript -Encoding Ascii

    Write-Host "========================================"
    Write-Host "Running optional Yosys synthesis smoke: $top"

    yosys -q -l $logPath -s $scriptPath

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Yosys synthesis smoke failed: $top"
        Write-Host "See log: $logPath"
        exit $LASTEXITCODE
    }

    $checkedTops.Add([ordered]@{
        top = $top
        log = $logPath
        script = $scriptPath
    }) | Out-Null
}

$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = "pass"
    checked_tops = $checkedTops.ToArray()
    source_count = $sources.Count
    claim_boundary = "Generic Yosys hierarchy/proc/opt/check smoke only; not timing closure, FPGA-family implementation, bitstream, or physical board validation."
}
Add-VerificationIdentityFields -Summary $summary | Out-Null

$summary | ConvertTo-Json -Depth 6 | Set-Content -Path "wave\synth-smoke-summary.json" -Encoding Ascii

Write-Host "========================================"
Write-Host "PASS: optional Yosys synthesis smoke checks passed"
