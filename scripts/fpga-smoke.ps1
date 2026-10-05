<#
Script: scripts\fpga-smoke.ps1
Purpose: Elaborates FPGA-facing top modules with the local simulation toolchain.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\fpga-smoke.ps1
Outputs:
  results/fpga-smoke-summary.json; elaboration diagnostics are printed to the console.
#>
param(
    [ValidateSet("all", "generic", "packet_uart_boot", "packet_uart_boot_bram_soc", "packet_uart_boot_runtime_soc", "debug_led", "basys3", "basys3_board_smoke", "basys3_full_lowfreq")]
    [string]$Top = "all"
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/result-format.ps1"
. "$PSScriptRoot/verification-source-identity.ps1"
. "$PSScriptRoot/process-runner.ps1"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
$summaryPath = 'results/fpga-smoke-summary.json'
$summary = [ordered]@{ status='running'; requested_top=$Top; checked_tops=@(); error_message=$null }
Write-ResultJson $summary $summaryPath
$checkedTopModules = [System.Collections.Generic.List[string]]::new()
try {
$startingIdentity = Add-VerificationIdentityFields -Summary $summary

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
    throw "Missing FPGA source manifest: $sourceList"
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
    throw "FPGA source manifest is empty: $sourceList"
}

$seenSources = @{}

foreach ($entry in $sourceEntries) {
    $source = $entry.Path
    $sourceKey = $source.ToLowerInvariant()

    if ($seenSources.ContainsKey($sourceKey)) {
        Write-Host "FPGA source manifest contains duplicate source on line $($entry.Line): $source"
        Write-Host "First listed on line $($seenSources[$sourceKey])"
        throw "Duplicate FPGA source: $source"
    }

    $seenSources[$sourceKey] = $entry.Line

    if ($source -match "^(tb|wave|results|build)[/\\]") {
        Write-Host "FPGA source manifest should not include simulation artifact on line $($entry.Line): $source"
        throw "FPGA source manifest includes a simulation artifact: $source"
    }

    if (-not (Test-Path $source)) {
        Write-Host "FPGA source listed in manifest does not exist on line $($entry.Line): $source"
        throw "Missing FPGA source: $source"
    }
}

if ($Top -eq "all") {
    $selected = @("generic", "packet_uart_boot", "packet_uart_boot_bram_soc", "packet_uart_boot_runtime_soc", "debug_led", "basys3", "basys3_board_smoke", "basys3_full_lowfreq")
} else {
    $selected = @($Top)
}

foreach ($name in $selected) {
    $topModule = $tops[$name]

    Write-Host "========================================"
    Write-Host "Checking FPGA top elaboration: $topModule"

    $result = Invoke-LoggedProcess -FilePath 'iverilog' -Arguments @('-g2012', '-Wall', '-s', $topModule, '-tnull', '-f', $sourceList) -LogPath "results/logs/fpga-smoke/$topModule.log" -WorkingDirectory $repoRoot -TimeoutSeconds 180
    if ($result.status -ne 'passed') {
        Write-Host "FPGA top elaboration failed: $topModule"
        throw "FPGA top elaboration failed: $topModule"
    }
    $checkedTopModules.Add($topModule) | Out-Null
}

Assert-VerificationInputsUnchanged $startingIdentity
$summary.status = 'pass'
$summary.source_manifest = $sourceList
} catch {
    $summary.status = 'fail'
    $summary.error_message = $_.Exception.Message
    throw
} finally {
    $summary.generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    $summary.checked_tops = $checkedTopModules.ToArray()
    Write-ResultJson $summary $summaryPath
}
Write-Host "========================================"
Write-Host "PASS: FPGA top elaboration smoke checks passed"
