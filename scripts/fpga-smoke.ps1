<#
Script: scripts\fpga-smoke.ps1
Purpose: Elaborates FPGA-facing top modules with the local simulation toolchain.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\fpga-smoke.ps1
Outputs:
  Temporary FPGA top elaboration artifacts under wave\fpga-smoke.
Scope:
  Elaboration smoke evidence only; not synthesis timing closure or physical board validation.
Audience:
  Public FPGA smoke check used by scripts\check.ps1.
#>
param(
    [ValidateSet("all", "generic", "packet_uart_boot", "packet_uart_boot_bram_soc", "packet_uart_boot_runtime_soc", "debug_led", "basys3", "basys3_board_smoke", "basys3_full_lowfreq")]
    [string]$Top = "all"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$tops = @{
    generic = "RISCVCPU_fpga_top"
    packet_uart_boot = "RISCVCPU_uart_boot_fpga_top"
    packet_uart_boot_bram_soc = "RISCVCPU_uart_boot_bram_soc_top"
    packet_uart_boot_runtime_soc = "RISCVCPU_uart_boot_runtime_soc_top"
    debug_led = "RISCVCPU_fpga_debug_led_top"
    basys3 = "RISCVCPU_basys3_top"
    basys3_board_smoke = "RISCVCPU_basys3_board_smoke_top"
    basys3_full_lowfreq = "RISCVCPU_basys3_full_lowfreq_top"
}

$sourceList = "fpga/fpga_sources.f"

if (-not (Test-Path $sourceList)) {
    Write-Host "Missing FPGA source manifest: $sourceList"
    exit 1
}

$manifestLines = Get-Content $sourceList
$sourceEntries = @()

for ($i = 0; $i -lt $manifestLines.Count; $i++) {
    $source = $manifestLines[$i].Trim()

    if ($source -eq "" -or $source.StartsWith("#")) {
        continue
    }

    $sourceEntries += [PSCustomObject]@{
        Path = $source
        Line = $i + 1
    }
}

if ($sourceEntries.Count -eq 0) {
    Write-Host "FPGA source manifest is empty: $sourceList"
    exit 1
}

$seenSources = @{}

foreach ($entry in $sourceEntries) {
    $source = $entry.Path
    $sourceKey = $source.ToLowerInvariant()

    if ($seenSources.ContainsKey($sourceKey)) {
        Write-Host "FPGA source manifest contains duplicate source on line $($entry.Line): $source"
        Write-Host "First listed on line $($seenSources[$sourceKey])"
        exit 1
    }

    $seenSources[$sourceKey] = $entry.Line

    if ($source -match "^(tb|wave)/" -or $source -match "^(tb|wave)\\") {
        Write-Host "FPGA source manifest should not include simulation artifact on line $($entry.Line): $source"
        exit 1
    }

    if (-not (Test-Path $source)) {
        Write-Host "FPGA source listed in manifest does not exist on line $($entry.Line): $source"
        exit 1
    }
}

if ($Top -eq "all") {
    $selected = @("generic", "packet_uart_boot", "packet_uart_boot_bram_soc", "packet_uart_boot_runtime_soc", "debug_led", "basys3", "basys3_board_smoke", "basys3_full_lowfreq")
} else {
    $selected = @($Top)
}

$checkedTopModules = [System.Collections.Generic.List[string]]::new()

foreach ($name in $selected) {
    $topModule = $tops[$name]
    $checkedTopModules.Add($topModule) | Out-Null

    Write-Host "========================================"
    Write-Host "Checking FPGA top elaboration: $topModule"

    iverilog -g2012 -Wall -s $topModule -tnull `
        -f $sourceList

    if ($LASTEXITCODE -ne 0) {
        Write-Host "FPGA top elaboration failed: $topModule"
        exit $LASTEXITCODE
    }
}

$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = "pass"
    requested_top = $Top
    source_manifest = $sourceList
    checked_tops = $checkedTopModules.ToArray()
    claim_boundary = "Elaboration smoke only; not synthesis, timing closure, bitstream, or physical board validation."
}

New-Item -ItemType Directory -Force -Path "wave" | Out-Null
$summary | ConvertTo-Json -Depth 5 | Set-Content -Path "wave\fpga-smoke-summary.json" -Encoding Ascii

Write-Host "========================================"
Write-Host "PASS: FPGA top elaboration smoke checks passed"
