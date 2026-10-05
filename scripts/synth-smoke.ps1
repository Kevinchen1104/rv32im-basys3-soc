<#
Script: scripts\synth-smoke.ps1
Purpose: Runs Yosys synthesis smoke checks for selected top-level modules when available.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\synth-smoke.ps1
Outputs:
  Work files under build/; command logs under results/logs/synthesis; JSON summary under results/.
#>
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. "$PSScriptRoot\verification-source-identity.ps1"
. "$PSScriptRoot/process-runner.ps1"
$summaryPath = 'results/synth-smoke-summary.json'
$summary = [ordered]@{ status='running'; started_at_utc=(Get-Date).ToUniversalTime().ToString('o'); checked_tops=@(); error_message=$null }
Write-ResultJson $summary $summaryPath
try {
$startingIdentity = Add-VerificationIdentityFields $summary

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

New-Item -ItemType Directory -Force -Path "results", "build" | Out-Null

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
    $logPath = "results/logs/synthesis/$top.log"
    $scriptPath = Join-Path 'build' "synth-smoke-$top.ys"
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

    $result = Invoke-LoggedProcess -FilePath $yosysCommand.Source -Arguments @('-s', $scriptPath) -LogPath $logPath -WorkingDirectory $repoRoot -TimeoutSeconds 300 -Quiet

    if ($result.status -ne 'passed') {
        Write-Host "Yosys synthesis smoke failed: $top"
        Get-Content -LiteralPath $logPath -Tail 40 | Write-Host
        Write-Host "See log: $logPath"
        throw "Yosys synthesis check failed: $top. See $logPath"
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
    method = 'Yosys hierarchy / proc / opt / check'
}
Assert-VerificationInputsUnchanged $startingIdentity
Add-VerificationIdentityFields -Summary $summary -Identity $startingIdentity | Out-Null

} catch {
    $summary.status = 'fail'
    $summary['error_message'] = $_.Exception.Message
    throw
} finally {
    $summary['generated_at_utc'] = (Get-Date).ToUniversalTime().ToString('o')
    Write-ResultJson $summary $summaryPath
}

Write-Host "========================================"
Write-Host "PASS: optional Yosys synthesis smoke checks passed"
