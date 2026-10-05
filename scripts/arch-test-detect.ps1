<#
Script: scripts\arch-test-detect.ps1
Purpose: Detects local RISC-V architectural test inputs and optional toolchain availability.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\arch-test-detect.ps1
Outputs:
  Console environment report for arch-test related paths and tools.
#>
param(
    [string]$OutputPath = "results\arch-test-detect.json",
    [string]$ToolchainBin = "",
    [string]$Prefix = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. "$PSScriptRoot/result-format.ps1"
New-Item -ItemType Directory -Force -Path "results" | Out-Null

if ([string]::IsNullOrWhiteSpace($ToolchainBin) -and -not [string]::IsNullOrWhiteSpace($env:RISCV_TOOLCHAIN_BIN)) {
    $ToolchainBin = $env:RISCV_TOOLCHAIN_BIN
}

if ([string]::IsNullOrWhiteSpace($Prefix)) {
    if (-not [string]::IsNullOrWhiteSpace($env:RISCV_PREFIX)) {
        $Prefix = $env:RISCV_PREFIX
    } else {
        $Prefix = "riscv64-unknown-elf-"
    }
}

$fallbackDirs = @()
if (-not [string]::IsNullOrWhiteSpace($ToolchainBin)) {
    $fallbackDirs += $ToolchainBin
}
$fallbackDirs += @(
    "C:\AMDDesignTools\2026.1\gnu\riscv\nt\bin",
    "C:\msys64\ucrt64\bin",
    "C:\msys64\mingw64\bin",
    "C:\msys64\usr\bin",
    "C:\riscv\bin",
    "C:\riscv64-unknown-elf\bin"
)

function Find-Tool {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    foreach ($dir in $fallbackDirs) {
        foreach ($name in $Names) {
            $candidate = Join-Path $dir $name
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
    }

    foreach ($name in $Names) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $cmd) {
            return $cmd.Source
        }
    }

    return $null
}

function Get-PrefixedCandidates {
    param(
        [string]$PrefixValue,
        [string]$ToolName
    )

    return @(
        "$PrefixValue$ToolName.exe",
        "$PrefixValue$ToolName"
    )
}

function Get-VersionText {
    param(
        [string]$Path,
        [string[]]$Arguments
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    try {
        $output = & $Path @Arguments 2>&1 | Select-Object -First 3
        return (($output | ForEach-Object { $_.ToString() }) -join "`n")
    } catch {
        return "version probe failed: $($_.Exception.Message)"
    }
}

function New-ToolStatus {
    param(
        [string]$Name,
        [string[]]$Candidates,
        [string[]]$VersionArgs = @("--version"),
        [bool]$Required = $true
    )

    $path = Find-Tool -Names $Candidates
    return [ordered]@{
        name = $Name
        required = $Required
        present = (-not [string]::IsNullOrWhiteSpace($path))
        path = $path
        version = Get-VersionText -Path $path -Arguments $VersionArgs
    }
}

function Test-PythonModule {
    param(
        [string]$PythonPath,
        [string]$ModuleName
    )

    if ([string]::IsNullOrWhiteSpace($PythonPath)) {
        return [ordered]@{
            present = $false
            version = $null
            reason = "python not found"
        }
    }

    try {
        $output = & $PythonPath -m $ModuleName --version 2>&1
        $exitCode = $LASTEXITCODE
        return [ordered]@{
            present = ($exitCode -eq 0)
            version = if ($exitCode -eq 0) { (($output | ForEach-Object { $_.ToString() }) -join "`n") } else { $null }
            reason = if ($exitCode -eq 0) { $null } else { (($output | ForEach-Object { $_.ToString() }) -join "`n") }
        }
    } catch {
        return [ordered]@{
            present = $false
            version = $null
            reason = $_.Exception.Message
        }
    }
}

$tools = [ordered]@{}
$tools.git = New-ToolStatus -Name "git" -Candidates @("git.exe", "git")
$tools.python = New-ToolStatus -Name "python" -Candidates @("python.exe", "python", "py.exe", "py")
$tools.iverilog = New-ToolStatus -Name "iverilog" -Candidates @("iverilog.exe", "iverilog") -VersionArgs @("-V")
$tools.vvp = New-ToolStatus -Name "vvp" -Candidates @("vvp.exe", "vvp") -VersionArgs @("-V")
$tools.riscv_gcc = New-ToolStatus -Name "$($Prefix)gcc" -Candidates (Get-PrefixedCandidates -PrefixValue $Prefix -ToolName "gcc")
$tools.riscv_objcopy = New-ToolStatus -Name "$($Prefix)objcopy" -Candidates (Get-PrefixedCandidates -PrefixValue $Prefix -ToolName "objcopy")
$tools.riscv_objdump = New-ToolStatus -Name "$($Prefix)objdump" -Candidates (Get-PrefixedCandidates -PrefixValue $Prefix -ToolName "objdump")
$tools.riscof = New-ToolStatus -Name "riscof" -Candidates @("riscof.exe", "riscof") -Required $false
$tools.spike = New-ToolStatus -Name "spike" -Candidates @("spike.exe", "spike") -Required $false
$tools.sail = New-ToolStatus -Name "sail-riscv" -Candidates @("riscv_sim_RV32.exe", "riscv_sim_RV32", "sail-riscv.exe", "sail-riscv") -Required $false

$tools.python_riscof_module = Test-PythonModule -PythonPath $tools.python.path -ModuleName "riscof"

$requiredMissing = @(
    $tools.git,
    $tools.python,
    $tools.iverilog,
    $tools.vvp,
    $tools.riscv_gcc,
    $tools.riscv_objcopy,
    $tools.riscv_objdump
) | Where-Object { -not $_.present } | ForEach-Object { $_.name }

$status = if (@($requiredMissing).Count -eq 0) { "ready" } else { "blocked_no_tool" }

$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = $status
    required_missing = @($requiredMissing)
    toolchain = [ordered]@{
        prefix = $Prefix
        requested_bin = $ToolchainBin
        env_RISCV_TOOLCHAIN_BIN = $env:RISCV_TOOLCHAIN_BIN
        env_RISCV_PREFIX = $env:RISCV_PREFIX
        search_dirs = @($fallbackDirs)
    }
    tools = $tools
    notes = @(
        "RISCOF and Spike/Sail are optional for this harness.",
        "arch-test-run compares against the local RV32IM reference. Run scripts/sail_reference.py separately for the official Sail model; this detector does not probe WSL installations.",
        "passed_local_reference is not an official compliance result."
    )
}

Write-ResultJson $summary $OutputPath

Write-Host "========================================"
Write-Host "RISC-V arch-test integration tool detection"
Write-Host ("Status: {0}" -f $summary.status)
if (@($requiredMissing).Count -ne 0) {
    Write-Host ("Missing required tools: {0}" -f (@($requiredMissing) -join ", "))
} else {
    Write-Host "Required tools present."
}
Write-Host ("Detection written to {0}" -f $OutputPath)
