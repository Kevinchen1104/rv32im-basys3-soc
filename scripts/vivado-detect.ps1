<#
Script: scripts\vivado-detect.ps1
Purpose: Detects Vivado availability and reports version/path details.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\vivado-detect.ps1
Outputs:
  Console Vivado detection report.
#>
param(
    [switch] $Require,
    [string] $OutputPath = "results\vivado-detect-summary.json"
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/result-format.ps1"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

New-Item -ItemType Directory -Force -Path "results" | Out-Null

. "$PSScriptRoot/script-common.ps1"

function Find-CommonVivado { return Find-FpgaVendorTool vivado }

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

Write-ResultJson $summary $OutputPath
Write-Host "========================================"
Write-Host "Vivado detection"
Write-Host ("Status: {0}" -f $summary.status)
Write-Host ("Path: {0}" -f ($(if ([string]::IsNullOrWhiteSpace($vivadoPath)) { "<not found>" } else { $vivadoPath })))
Write-Host ("Basys3 target status: {0}" -f $summary.basys3_target.status)
Write-Host ("Summary: {0}" -f $OutputPath)

if ($Require -and $status -ne "available") {
    throw "Vivado is required but was not found."
}
