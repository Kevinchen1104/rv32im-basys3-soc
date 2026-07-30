<#
Script: scripts\vivado-detect.ps1
Purpose: Detects Vivado availability and reports version/path details.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\vivado-detect.ps1
Outputs:
  Console Vivado detection report.
Scope:
  Environment discovery only; not synthesis or timing evidence.
Audience:
  Public optional FPGA environment helper.
#>
param(
    [switch] $Require,
    [string] $OutputPath = "wave\vivado-detect-summary.json"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

New-Item -ItemType Directory -Force -Path "wave" | Out-Null

function Find-CommonVivado {
    $command = Get-Command vivado -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $roots = @(
        "C:\Xilinx\Vivado",
        "C:\Program Files\Xilinx\Vivado",
        "C:\AMD\Vivado"
    )

    foreach ($amdToolsRoot in Get-ChildItem -LiteralPath "C:\" -Directory -Filter "AMDDesignTools*" -ErrorAction SilentlyContinue) {
        foreach ($candidateRoot in Get-ChildItem -LiteralPath $amdToolsRoot.FullName -Directory -ErrorAction SilentlyContinue) {
            $vivadoRoot = Join-Path $candidateRoot.FullName "Vivado"
            if (Test-Path -LiteralPath $vivadoRoot) {
                $roots += $vivadoRoot
            }
        }
    }

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        foreach ($candidate in @("bin\vivado.bat", "bin\vivado.exe")) {
            $path = Join-Path $root $candidate
            if (Test-Path -LiteralPath $path) {
                return $path
            }
        }

        foreach ($versionDir in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending) {
            foreach ($candidate in @("bin\vivado.bat", "bin\vivado.exe")) {
                $path = Join-Path $versionDir.FullName $candidate
                if (Test-Path -LiteralPath $path) {
                    return $path
                }
            }
        }
    }

    return $null
}

function Get-VivadoVersion {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    try {
        $output = & $Path -version 2>&1 | Select-Object -First 8
        return (($output | ForEach-Object { $_.ToString() }) -join "`n")
    } catch {
        return "version query failed: $($_.Exception.Message)"
    }
}

$vivadoPath = Find-CommonVivado
$status = if ([string]::IsNullOrWhiteSpace($vivadoPath)) { "missing" } else { "available" }

$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = $status
    require = [bool] $Require
    tool = [ordered]@{
        name = "Vivado"
        command = "vivado"
        path = $vivadoPath
        version = Get-VivadoVersion -Path $vivadoPath
    }
    basys3_target = [ordered]@{
        status = if ($status -eq "available") { "available" } else { "blocked_no_vivado" }
        part = "xc7a35tcpg236-1"
        top = "RISCVCPU_basys3_top"
        physical_validation_status = "not_run"
        timing_closure_status = "not_run"
    }
    claim_boundary = "Vivado may be unavailable; status reports blocked_no_vivado. Detection is not synthesis, implementation, timing closure, bitstream generation, or board validation."
}

$summary | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputPath -Encoding Ascii

Write-Host "========================================"
Write-Host "Vivado detection"
Write-Host ("Status: {0}" -f $summary.status)
Write-Host ("Path: {0}" -f ($(if ([string]::IsNullOrWhiteSpace($vivadoPath)) { "<not found>" } else { $vivadoPath })))
Write-Host ("Basys3 target status: {0}" -f $summary.basys3_target.status)
Write-Host ("Summary: {0}" -f $OutputPath)

if ($Require -and $status -ne "available") {
    throw "Vivado is required but was not found."
}
