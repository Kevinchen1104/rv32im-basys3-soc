<#
Script: scripts\project-doctor.ps1
Purpose: Checks repository layout and local tool readiness for common project flows.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\project-doctor.ps1
Outputs:
  Console project-doctor report.
Scope:
  Environment and layout check only; not hardware evidence.
Audience:
  Public maintenance helper.
#>
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

New-Item -ItemType Directory -Force -Path "wave" | Out-Null

$requiredIssues = [System.Collections.Generic.List[string]]::new()
$optionalIssues = [System.Collections.Generic.List[string]]::new()

function Get-VersionOutput {
    param(
        [string] $Path,
        [string[]] $Arguments = @("--version")
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    try {
        $output = & $Path @Arguments 2>&1 | Select-Object -First 5
        return (($output | ForEach-Object { $_.ToString() }) -join "`n")
    } catch {
        return "version query failed: $($_.Exception.Message)"
    }
}

function Find-ToolPath {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Candidates,
        [string[]] $FallbackDirs = @()
    )

    foreach ($candidate in $Candidates) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return $command.Source
        }
    }

    foreach ($dir in $FallbackDirs) {
        foreach ($candidate in $Candidates) {
            $path = Join-Path $dir $candidate
            if (Test-Path -LiteralPath $path) {
                return $path
            }
        }
    }

    return $null
}

function New-ToolCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $true)]
        [string[]] $Candidates,
        [string[]] $VersionArguments = @("--version"),
        [bool] $Required = $true,
        [string[]] $FallbackDirs = @()
    )

    $path = Find-ToolPath -Candidates $Candidates -FallbackDirs $FallbackDirs
    $status = "available"
    if ([string]::IsNullOrWhiteSpace($path)) {
        $status = if ($Required) { "missing" } else { "optional_missing" }
        if ($Required) {
            $requiredIssues.Add($Name) | Out-Null
        } else {
            $optionalIssues.Add($Name) | Out-Null
        }
    }

    return [ordered]@{
        name = $Name
        required = $Required
        status = $status
        path = $path
        version = Get-VersionOutput -Path $path -Arguments $VersionArguments
    }
}

function Invoke-DoctorScript {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Script,
        [string[]] $Arguments = @(),
        [Parameter(Mandatory = $true)]
        [string] $LogPath
    )

    $scriptPath = Join-Path $repoRoot $Script
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        return [ordered]@{
            status = "missing"
            command = "powershell -ExecutionPolicy Bypass -File $Script"
            exit_code = $null
            log = $LogPath
        }
    }

    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $output | Set-Content -Path $LogPath -Encoding Ascii

    return [ordered]@{
        status = if ($exitCode -eq 0) { "available" } else { "blocked" }
        command = "powershell -ExecutionPolicy Bypass -File $Script $($Arguments -join ' ')".Trim()
        exit_code = $exitCode
        log = $LogPath
    }
}

function Read-JsonIfPresent {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

$msysFallbackDirs = @(
    "C:\msys64\ucrt64\bin",
    "C:\msys64\mingw64\bin",
    "C:\msys64\usr\bin",
    "C:\riscv\bin",
    "C:\riscv64-unknown-elf\bin"
)

$checks = [ordered]@{}
$checks.git = New-ToolCheck -Name "Git" -Candidates @("git.exe", "git") -VersionArguments @("--version")
$checks.powershell = [ordered]@{
    name = "PowerShell"
    required = $true
    status = "available"
    path = (Get-Process -Id $PID).Path
    version = $PSVersionTable.PSVersion.ToString()
}
$checks.python = New-ToolCheck -Name "Python" -Candidates @("python.exe", "python", "py.exe", "py") -Required $false
$checks.icarus = [ordered]@{
    iverilog = New-ToolCheck -Name "Icarus Verilog" -Candidates @("iverilog.exe", "iverilog") -VersionArguments @("-V")
    vvp = New-ToolCheck -Name "VVP" -Candidates @("vvp.exe", "vvp") -VersionArguments @("-V")
}

$pathParts = @($env:PATH -split ";")
$msysDirsPresent = @($msysFallbackDirs | Where-Object { Test-Path -LiteralPath $_ })
$msysPathHits = @($pathParts | Where-Object { $_ -like "C:\msys64*" })
$msysStatus = if ($msysDirsPresent.Count -ne 0 -or $msysPathHits.Count -ne 0) { "available" } else { "optional_missing" }
if ($msysStatus -eq "optional_missing") {
    $optionalIssues.Add("MSYS2 path sanity") | Out-Null
}
$checks.msys2_path_sanity = [ordered]@{
    name = "MSYS2 path sanity"
    required = $false
    status = $msysStatus
    dirs_present = $msysDirsPresent
    path_entries = $msysPathHits
}

$archDetectPath = "wave\project-doctor-arch-test-detect.json"
$archDetect = Invoke-DoctorScript `
    -Script "scripts\arch-test-detect.ps1" `
    -Arguments @("-OutputPath", $archDetectPath) `
    -LogPath "wave\project-doctor-arch-test-detect.log"
$archDetectJson = Read-JsonIfPresent $archDetectPath
$riscvToolStatus = "optional_missing"
if ($null -ne $archDetectJson -and $archDetectJson.status -eq "ready") {
    $riscvToolStatus = "available"
} else {
    $optionalIssues.Add("RISC-V GNU toolchain") | Out-Null
}
$checks.riscv_gnu_toolchain = [ordered]@{
    name = "RISC-V GNU toolchain"
    required = $false
    status = $riscvToolStatus
    detect_script = $archDetect
    detect_summary = $archDetectPath
    tools = if ($null -eq $archDetectJson) { $null } else { $archDetectJson.tools }
}

$checks.verilator = New-ToolCheck -Name "Verilator" -Candidates @("verilator.exe", "verilator") -Required $false
$checks.yosys = New-ToolCheck -Name "Yosys" -Candidates @("yosys.exe", "yosys") -VersionArguments @("-V") -Required $false

$sbyPath = Find-ToolPath -Candidates @("sby.exe", "sby")
$sbyScript = Find-ToolPath -Candidates @("sby-script.py") -FallbackDirs @("C:\msys64\ucrt64\bin", "C:\msys64\mingw64\bin", "C:\msys64\usr\bin")
$python3Path = Find-ToolPath -Candidates @("python3.exe", "python3", "python.exe", "python")
$smtbmcPath = Find-ToolPath -Candidates @("yosys-smtbmc.exe", "yosys-smtbmc", "yosys-smtbmc-script.py") -FallbackDirs @("C:\msys64\ucrt64\bin", "C:\msys64\mingw64\bin", "C:\msys64\usr\bin")
$symbiStatus = if (-not [string]::IsNullOrWhiteSpace($sbyPath) -or (-not [string]::IsNullOrWhiteSpace($python3Path) -and -not [string]::IsNullOrWhiteSpace($sbyScript))) {
    "available"
} else {
    "optional_missing"
}
if ($symbiStatus -eq "optional_missing") {
    $optionalIssues.Add("SymbiYosys/python fallback") | Out-Null
}
$checks.symbiyosys_python_fallback = [ordered]@{
    name = "SymbiYosys/python fallback"
    required = $false
    status = $symbiStatus
    sby = $sbyPath
    sby_script = $sbyScript
    python = $python3Path
    smtbmc = $smtbmcPath
}

$profilePath = "tools\arch-test\rv32im-selected.json"
$profile = Read-JsonIfPresent $profilePath
$checkoutPath = if ($null -ne $profile -and $profile.PSObject.Properties.Name -contains "upstream") {
    $profile.upstream.checkout
} else {
    "external\riscv-arch-test"
}
$upstreamStatus = if (Test-Path -LiteralPath $checkoutPath) { "available" } else { "optional_missing" }
if ($upstreamStatus -eq "optional_missing") {
    $optionalIssues.Add("arch-test upstream checkout") | Out-Null
}
$checks.arch_test_upstream_availability = [ordered]@{
    name = "arch-test upstream availability"
    required = $false
    status = $upstreamStatus
    profile = $profilePath
    checkout = $checkoutPath
}

$fpgaDetect = Invoke-DoctorScript -Script "scripts\fpga-tool-detect.ps1" -LogPath "wave\project-doctor-fpga-tool-detect.log"
$fpgaDetectJson = Read-JsonIfPresent "wave\fpga-tool-detect.json"
if ($fpgaDetect.status -ne "available") {
    $optionalIssues.Add("FPGA tool detection") | Out-Null
}
$checks.fpga_tools = [ordered]@{
    name = "FPGA tools"
    required = $false
    status = $fpgaDetect.status
    detect_script = $fpgaDetect
    summary = "wave\fpga-tool-detect.json"
    tools = if ($null -eq $fpgaDetectJson) { $null } else { $fpgaDetectJson.tools }
    timing_readiness = if ($null -eq $fpgaDetectJson) { $null } else { $fpgaDetectJson.timing_readiness }
}

$vivadoDetect = Invoke-DoctorScript -Script "scripts\vivado-detect.ps1" -LogPath "wave\project-doctor-vivado-detect.log"
$vivadoDetectJson = Read-JsonIfPresent "wave\vivado-detect-summary.json"
$vivadoTargetStatus = if ($null -ne $vivadoDetectJson -and $vivadoDetectJson.status -eq "available") {
    "available"
} elseif ($vivadoDetect.status -eq "missing") {
    "missing"
} else {
    "blocked_no_vivado"
}
if ($vivadoTargetStatus -ne "available") {
    $optionalIssues.Add("Vivado Basys3 target flow ($vivadoTargetStatus)") | Out-Null
}
$checks.vivado_basys3_target = [ordered]@{
    name = "Vivado Basys3 target flow"
    required = $false
    status = $vivadoTargetStatus
    detect_script = $vivadoDetect
    summary = "wave\vivado-detect-summary.json"
    tool = if ($null -eq $vivadoDetectJson) { $null } else { $vivadoDetectJson.tool }
    basys3_target = if ($null -eq $vivadoDetectJson) { $null } else { $vivadoDetectJson.basys3_target }
}

$evidenceScripts = @(
    "scripts\check.ps1",
    "scripts\run.ps1",
    "scripts\assemble.ps1",
    "scripts\check-test-catalog.ps1",
    "scripts\showcase-demo.ps1",
    "scripts\interactive-showcase-demo.ps1",
    "scripts\release-evidence.ps1",
    "scripts\fpga-tool-detect.ps1",
    "scripts\fpga-release.ps1",
    "scripts\vivado-detect.ps1",
    "scripts\vivado-basys3-build.ps1",
    "scripts\arch-test-run.ps1",
    "scripts\arch-test-report.ps1",
    "scripts\project-doctor.ps1",
    "scripts\demo-smoke.ps1",
    "scripts\release-freeze.ps1",
    "scripts\claim-audit.ps1",
    "scripts\docs-link-audit.ps1",
    "scripts\final-audit.ps1"
)
$missingScripts = @($evidenceScripts | Where-Object { -not (Test-Path -LiteralPath $_) })
if ($missingScripts.Count -ne 0) {
    $requiredIssues.Add("evidence scripts: $($missingScripts -join ', ')") | Out-Null
}
$checks.evidence_scripts_availability = [ordered]@{
    name = "Evidence scripts availability"
    required = $true
    status = if ($missingScripts.Count -eq 0) { "available" } else { "missing" }
    checked = $evidenceScripts
    missing = $missingScripts
}

$overallStatus = if ($requiredIssues.Count -eq 0) { "available" } else { "blocked" }
$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = $overallStatus
    status_vocabulary = @("available", "missing", "optional_missing", "blocked", "blocked_no_vivado", "not_checked")
    required_issues = $requiredIssues.ToArray()
    optional_issues = $optionalIssues.ToArray()
    checks = $checks
    claim_boundary = "Project doctor reports local bring-up readiness only. Optional tool gaps do not invalidate the portable simulation gate, and this report is not timing, board-validation, speedup, or official compliance evidence."
}

$summary | ConvertTo-Json -Depth 10 | Set-Content -Path "wave\project-doctor-summary.json" -Encoding Ascii

Write-Host "========================================"
Write-Host "Project doctor"
Write-Host ("Status: {0}" -f $summary.status)
Write-Host ("Required issues: {0}" -f ($(if ($requiredIssues.Count -eq 0) { "none" } else { $requiredIssues -join ", " })))
Write-Host ("Optional issues: {0}" -f ($(if ($optionalIssues.Count -eq 0) { "none" } else { $optionalIssues -join ", " })))
Write-Host "Summary written to wave\project-doctor-summary.json"

if ($requiredIssues.Count -ne 0) {
    throw "Project doctor blocked by required missing items: $($requiredIssues -join '; ')"
}
