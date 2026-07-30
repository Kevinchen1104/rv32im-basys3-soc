<#
Script: scripts\verilator-lint.ps1
Purpose: Runs Verilator lint over the RTL source manifest when Verilator is available.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\verilator-lint.ps1
Outputs:
  Console lint report and optional logs under wave\verilator-lint.
Scope:
  Lint evidence only; not synthesis, timing closure, or hardware proof.
Audience:
  Public optional lint check.
#>
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. "$PSScriptRoot\verification-source-identity.ps1"

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

New-Item -ItemType Directory -Force -Path "wave" | Out-Null

$sourceArgs = ($sources | ForEach-Object { $_ -replace "\\", "/" }) -join " "
$verilatorIsMsysLauncher =
    $verilatorCommand.Source -and
    ([System.IO.Path]::GetExtension($verilatorCommand.Source) -eq "")
$bashPath = "C:\msys64\usr\bin\bash.exe"
$cygpathPath = "C:\msys64\usr\bin\cygpath.exe"
$repoRootMsys = ""

if ($verilatorIsMsysLauncher) {
    if (-not (Test-Path $bashPath) -or -not (Test-Path $cygpathPath)) {
        throw "MSYS2 Verilator launcher found, but bash/cygpath is missing."
    }

    $repoRootMsys = (& $cygpathPath -u $repoRoot.Path).Trim()
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

foreach ($top in $tops) {
    $buildDir = "wave\verilator-lint-$top"

    New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

    Write-Host "========================================"
    Write-Host "Running optional Verilator lint: $top"

    if ($verilatorIsMsysLauncher) {
        $buildDirArg = $buildDir -replace "\\", "/"
        $bashScript = "cd '$repoRootMsys' && PATH=/ucrt64/bin:/usr/bin:`$PATH verilator --lint-only -I. -Irtl --top-module $top --Mdir $buildDirArg $sourceArgs"
        & $bashPath -lc $bashScript
    } else {
        verilator --lint-only -I. -Irtl --top-module $top --Mdir $buildDir $sources
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Verilator lint failed: $top"
        exit $LASTEXITCODE
    }
    $checkedTops.Add($top) | Out-Null
}

$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = "pass"
    checked_tops = $checkedTops.ToArray()
    source_count = $sources.Count
    claim_boundary = "Verilator lint only; not simulation, synthesis, timing closure, or physical validation."
}
Add-VerificationIdentityFields -Summary $summary | Out-Null
$summary | ConvertTo-Json -Depth 4 | Set-Content -Path "wave\verilator-lint-summary.json" -Encoding Ascii

Write-Host "========================================"
Write-Host "PASS: optional Verilator lint checks passed"
