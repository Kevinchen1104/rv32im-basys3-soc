<#
Script: scripts\verilator-lint.ps1
Purpose: Runs Verilator lint over the RTL source manifest when Verilator is available.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\verilator-lint.ps1
Outputs:
  Command logs under results/logs/lint; JSON summary under results/.
#>
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. "$PSScriptRoot\verification-source-identity.ps1"
. "$PSScriptRoot/process-runner.ps1"
$summaryPath = 'results/verilator-lint-summary.json'
$summary = [ordered]@{ status='running'; started_at_utc=(Get-Date).ToUniversalTime().ToString('o'); checked_tops=@(); error_message=$null }
Write-ResultJson $summary $summaryPath
try {
$startingIdentity = Add-VerificationIdentityFields $summary

$verilatorCommand = Get-Command verilator -ErrorAction SilentlyContinue
if ($null -eq $verilatorCommand) {
    throw "Verilator not found on PATH. Install Verilator to run optional RTL lint."
}

$sources = Get-Content -LiteralPath "rtl/rtl_sources.f" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
foreach ($source in $sources) {
    if (-not (Test-Path $source)) {
        throw "Missing lint source: $source"
    }
}

New-Item -ItemType Directory -Force -Path "results" | Out-Null

$sourceArgs = ($sources | ForEach-Object { $_ -replace "\\", "/" }) -join " "
$verilatorIsMsysLauncher =
    ($env:OS -eq 'Windows_NT') -and
    $verilatorCommand.Source -and
    ([System.IO.Path]::GetExtension($verilatorCommand.Source) -eq "")
$repoRootMsys = ""

if ($verilatorIsMsysLauncher) {
    $msysRoot = Split-Path (Split-Path (Split-Path $verilatorCommand.Source -Parent) -Parent) -Parent
    $bashPath = Join-Path $msysRoot 'usr/bin/bash.exe'
    $cygpathPath = Join-Path $msysRoot 'usr/bin/cygpath.exe'
    if (-not (Test-Path $bashPath) -or -not (Test-Path $cygpathPath)) {
        throw "MSYS2 Verilator launcher found, but bash/cygpath is missing."
    }

    $repoRootMsys = (& $cygpathPath -u $repoRoot.Path).Trim().Replace("'", "'\''")
    $toolBinMsys = (& $cygpathPath -u (Split-Path $verilatorCommand.Source -Parent)).Trim().Replace("'", "'\''")
}

$tops = @(
    "RISCVCPU",
    "RISCVCPU_fpga_top",
    "RISCVCPU_uart_boot_fpga_top",
    "RISCVCPU_uart_boot_bram_soc_top",
    "RISCVCPU_uart_boot_runtime_soc_top",
    "RISCVCPU_fpga_debug_led_top",
    "RISCVCPU_basys3_top",
    "RISCVCPU_basys3_board_smoke_top",
    "RISCVCPU_basys3_full_lowfreq_top"
)
$checkedTops = [System.Collections.Generic.List[string]]::new()
$cases = @($tops | ForEach-Object { [pscustomobject]@{ name=$_; top=$_; parameters=@() } })
foreach ($bytes in @(64, 128)) {
    foreach ($victims in @(0, 1, 2, 4, 8)) {
        $cases += [pscustomobject]@{
            name = "RISCVCPU_dcache${bytes}_victim${victims}"
            top = 'RISCVCPU'
            parameters = @("-GDCACHE_BYTES=$bytes", "-GDCACHE_VICTIM_LINES=$victims")
        }
    }
}
$checkedConfigurations = [System.Collections.Generic.List[object]]::new()

foreach ($case in $cases) {
    $top = $case.top
    $name = $case.name
    $parameterArgs = $case.parameters -join ' '
    $buildDir = "build/verilator/$name"

    Write-Host "========================================"
    Write-Host "Running optional Verilator lint: $name"

    if ($verilatorIsMsysLauncher) {
        $buildDirArg = $buildDir -replace "\\", "/"
        $bashScript = "cd '$repoRootMsys' && PATH='$toolBinMsys':/usr/bin:`$PATH verilator --lint-only -I. -Irtl --top-module $top --Mdir $buildDirArg $parameterArgs $sourceArgs"
        $result = Invoke-LoggedProcess -FilePath $bashPath -Arguments @('-lc', $bashScript) -LogPath "results/logs/lint/$name.log" -WorkingDirectory $repoRoot -TimeoutSeconds 180
    } else {
        $result = Invoke-LoggedProcess -FilePath $verilatorCommand.Source -Arguments (@('--lint-only', '-I.', '-Irtl', '--top-module', $top, '--Mdir', $buildDir) + @($case.parameters) + @($sources)) -LogPath "results/logs/lint/$name.log" -WorkingDirectory $repoRoot -TimeoutSeconds 180
    }

    if ($result.status -ne 'passed') {
        throw "Verilator lint failed: $name. See $($result.log)"
    }
    if (-not $checkedTops.Contains($top)) { $checkedTops.Add($top) }
    $checkedConfigurations.Add($case)
}

$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = "pass"
    checked_tops = $checkedTops.ToArray()
    checked_configurations = $checkedConfigurations.ToArray()
    source_count = $sources.Count
    method = 'Verilator --lint-only'
    log_directory = 'results/logs/lint'
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
Write-Host "PASS: optional Verilator lint checks passed"
