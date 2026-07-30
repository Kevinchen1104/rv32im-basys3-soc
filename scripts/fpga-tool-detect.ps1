<#
Script: scripts\fpga-tool-detect.ps1
Purpose: Detects optional FPGA and verification tools available in the local environment.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\fpga-tool-detect.ps1
Outputs:
  Console tool-detection report.
Scope:
  Environment discovery only; not hardware evidence.
Audience:
  Public environment helper.
#>
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

New-Item -ItemType Directory -Force -Path "wave" | Out-Null

function Get-ToolVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [string[]] $Arguments
    )

    try {
        $output = & $Path @Arguments 2>&1 | Select-Object -First 4
        return ($output -join "`n")
    } catch {
        return ("version query failed: {0}" -f $_.Exception.Message)
    }
}

function Get-CommonVivadoPaths {
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($root in @("C:\Xilinx\Vivado", "C:\Program Files\Xilinx\Vivado")) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        foreach ($versionDir in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending) {
            foreach ($candidate in @("bin\vivado.bat", "bin\vivado.exe")) {
                $path = Join-Path $versionDir.FullName $candidate
                if (Test-Path -LiteralPath $path) {
                    $paths.Add($path) | Out-Null
                }
            }
        }
    }

    return $paths.ToArray()
}

function Get-ToolStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [string] $CommandName,
        [string[]] $VersionArguments = @("--version"),
        [string[]] $FallbackPaths = @()
    )

    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    $toolPath = if ($null -eq $command) { $null } else { $command.Source }

    if ([string]::IsNullOrWhiteSpace($toolPath)) {
        foreach ($fallbackPath in $FallbackPaths) {
            if (Test-Path -LiteralPath $fallbackPath) {
                $toolPath = $fallbackPath
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($toolPath)) {
        return [ordered]@{
            name = $Name
            command = $CommandName
            status = "missing"
            path = $null
            version = $null
        }
    }

    return [ordered]@{
        name = $Name
        command = $CommandName
        status = "available"
        path = $toolPath
        version = Get-ToolVersion -Path $toolPath -Arguments $VersionArguments
    }
}

$tools = [ordered]@{
    vivado = Get-ToolStatus -Name "Vivado" -CommandName "vivado" -VersionArguments @("-version") -FallbackPaths (Get-CommonVivadoPaths)
    quartus = Get-ToolStatus -Name "Quartus" -CommandName "quartus_sh" -VersionArguments @("--version")
    yosys = Get-ToolStatus -Name "Yosys" -CommandName "yosys" -VersionArguments @("-V")
    nextpnr_ice40 = Get-ToolStatus -Name "nextpnr-ice40" -CommandName "nextpnr-ice40" -VersionArguments @("--version")
    nextpnr_ecp5 = Get-ToolStatus -Name "nextpnr-ecp5" -CommandName "nextpnr-ecp5" -VersionArguments @("--version")
    nextpnr_generic = Get-ToolStatus -Name "nextpnr-generic" -CommandName "nextpnr-generic" -VersionArguments @("--version")
    openfpgaloader = Get-ToolStatus -Name "openFPGALoader" -CommandName "openFPGALoader" -VersionArguments @("--version")
}

$nextpnrAvailable =
    $tools.nextpnr_ice40.status -eq "available" -or
    $tools.nextpnr_ecp5.status -eq "available" -or
    $tools.nextpnr_generic.status -eq "available"

$vendorTimingToolAvailable =
    $tools.vivado.status -eq "available" -or
    $tools.quartus.status -eq "available" -or
    $nextpnrAvailable

$pnrToolStatus = if ($vendorTimingToolAvailable) { "available" } else { "blocked_no_tool" }
$basys3ProfileAvailable =
    (Test-Path -LiteralPath "fpga\boards\basys3\board.json") -and
    (Test-Path -LiteralPath "fpga\boards\basys3\basys3.xdc") -and
    (Test-Path -LiteralPath "rtl\top\boards\basys3\riscv_cpu_basys3_top.v")
$boardProfileStatus = if ($basys3ProfileAvailable) { "available_basys3" } else { "blocked_no_board_profile" }
$timingBlockers = [System.Collections.Generic.List[string]]::new()
if ($pnrToolStatus -ne "available") {
    $timingBlockers.Add($pnrToolStatus) | Out-Null
}
if ($boardProfileStatus -ne "available_basys3") {
    $timingBlockers.Add($boardProfileStatus) | Out-Null
}

$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = "pass"
    tools = $tools
    timing_readiness = [ordered]@{
        vendor_or_pnr_tool_available = $vendorTimingToolAvailable
        yosys_available = ($tools.yosys.status -eq "available")
        pnr_tool_status = $pnrToolStatus
        board_profile_status = $boardProfileStatus
        timing_status = "not_run"
        timing_closure_status = "not_run"
        blockers = $timingBlockers.ToArray()
        reason = "Tool detection only; Basys3 board profile may be present, but no implementation or timing report was run."
    }
    basys3_target = [ordered]@{
        profile_available = $basys3ProfileAvailable
        part = "xc7a35tcpg236-1"
        top = "RISCVCPU_basys3_top"
        vivado_status = if ($tools.vivado.status -eq "available") { "available" } else { "blocked_no_vivado" }
        physical_validation_status = "not_run"
        timing_closure_status = "not_run"
    }
    bitstream_status = "not_run"
    physical_validation_status = "not_run"
    claim_boundary = "Tool availability evidence only; no timing closure, bitstream, or physical board validation claim."
}

$summary | ConvertTo-Json -Depth 8 | Set-Content -Path "wave\fpga-tool-detect.json" -Encoding Ascii

Write-Host "========================================"
Write-Host "FPGA tool detection"
foreach ($toolName in $tools.Keys) {
    $tool = $tools[$toolName]
    Write-Host ("{0}: {1}" -f $tool.command, $tool.status)
}
Write-Host ("Timing status: {0}" -f $summary.timing_readiness.timing_status)
Write-Host ("Physical validation status: {0}" -f $summary.physical_validation_status)
Write-Host "Tool detection written to wave\fpga-tool-detect.json"
