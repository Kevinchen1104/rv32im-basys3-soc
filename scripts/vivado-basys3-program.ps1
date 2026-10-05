<#
Script: scripts\vivado-basys3-program.ps1
Purpose: Validates and optionally programs the canonical direct-100-MHz Basys3 bitstream through Vivado Hardware Manager.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\vivado-basys3-program.ps1 -DryRun
Outputs:
  A JSON summary under results\ and, only in physical mode, a Vivado programming log/result file.
Scope:
  One-shot JTAG programming helper; DryRun never opens hardware, and programming alone is not physical validation.
#>
param(
    [string] $BitstreamPath = "",
    [string] $ExpectedSha256 = "",
    [long] $ExpectedSizeBytes = 0,
    [string] $DeviceSelector = "*xc7a35t*",
    [switch] $DryRun,
    [string] $SummaryPath = "results\vivado-basys3-program-summary.json",
    [string] $LogPath = "results\vivado-basys3-program.log"
)

. "$PSScriptRoot/script-common.ps1"
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/result-format.ps1"
. "$PSScriptRoot/process-runner.ps1"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

. (Join-Path $PSScriptRoot "canonical-basys3-evidence.ps1")

$resolvedSummaryPath = Resolve-RepoPath $SummaryPath
$resolvedLogPath = Resolve-RepoPath $LogPath
$resolvedBitstreamPath = $null
$tclResultPath = [IO.Path]::ChangeExtension($resolvedSummaryPath, 'hardware.json')
$detectPath = [IO.Path]::ChangeExtension($resolvedSummaryPath, 'detect.json')
Ensure-ParentDirectory $resolvedSummaryPath

$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = "starting"
    vivado_version = $null
    vivado_path = $null
    board = "Digilent Basys3"
    fpga_part = "xc7a35tcpg236-1"
    device_selector = $DeviceSelector
    device = $null
    top = "RISCVCPU_basys3_top"
    bitstream_path = $BitstreamPath
    bitstream_absolute_path = $null
    bitstream_size_bytes = $null
    expected_size_bytes = $ExpectedSizeBytes
    bitstream_sha256 = $null
    expected_sha256 = $ExpectedSha256
    bitstream_matches_canonical = $false
    source_commit = $null
    source_fingerprint = $null
    fingerprint_input_count = $null
    repository_head = $null
    dry_run = [bool] $DryRun
    hardware_opened = $false
    device_found = $false
    device_programmed = $false
    retry_count = 0
    log_path = $LogPath
    tcl_result_path = if ($DryRun) { $null } else { $tclResultPath }
    physical_validation_status = "not_run"
    physical_validation_scope = "needs_revalidation"
    error = $null
    claim_boundary = "Programming verifies configuration only; UART, LED and reset behavior require a separate board test. DryRun does not open hardware."
}
Write-ResultJson $summary $resolvedSummaryPath

$failureMessage = $null

try {
    if ([string]::IsNullOrWhiteSpace($DeviceSelector)) {
        throw "DeviceSelector must not be empty."
    }

    $evidence = Get-CanonicalBasys3Evidence -RequestedBitstreamPath $BitstreamPath -RequestedSha256 $ExpectedSha256 -RequestedSizeBytes $ExpectedSizeBytes -AllowPendingPhysicalEvidence
    $BitstreamPath = $evidence.bitstream_path
    $ExpectedSha256 = $evidence.bitstream_sha256
    $ExpectedSizeBytes = $evidence.bitstream_size_bytes
    $expectedHash = $evidence.bitstream_sha256
    $resolvedBitstreamPath = $evidence.bitstream_absolute_path
    $summary.bitstream_path = $BitstreamPath
    $summary.bitstream_absolute_path = $resolvedBitstreamPath
    $summary.expected_size_bytes = $ExpectedSizeBytes
    $summary.expected_sha256 = $expectedHash
    $summary.source_commit = $evidence.source_commit
    $summary.source_fingerprint = $evidence.source_fingerprint
    $summary.fingerprint_input_count = $evidence.fingerprint_input_count

    if (-not (Test-Path -LiteralPath $resolvedBitstreamPath -PathType Leaf)) {
        throw "Bitstream not found: $BitstreamPath"
    }
    $bitstreamItem = Get-Item -LiteralPath $resolvedBitstreamPath
    $actualHash = (Get-FileHash -LiteralPath $resolvedBitstreamPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $summary.bitstream_size_bytes = $bitstreamItem.Length
    $summary.bitstream_sha256 = $actualHash

    if ($bitstreamItem.Length -ne $ExpectedSizeBytes) {
        throw "Bitstream size mismatch: expected $ExpectedSizeBytes bytes, got $($bitstreamItem.Length)."
    }
    if ($actualHash -ne $expectedHash) {
        throw "Bitstream SHA256 mismatch: expected $expectedHash, got $actualHash."
    }
    $summary.bitstream_matches_canonical = $true

    $summary.repository_head = (& git rev-parse HEAD).Trim()

    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "vivado-detect.ps1") -OutputPath $detectPath
    $detectSummary = Read-JsonFile $detectPath
    if ($detectSummary.status -ne "available" -or [string]::IsNullOrWhiteSpace($detectSummary.tool.path)) {
        throw "Vivado is required for Basys3 programming but was not found."
    }
    $summary.vivado_version = $detectSummary.tool.version
    $summary.vivado_path = $detectSummary.tool.path

    if ($DryRun) {
        $summary.status = "dry_run"
    } else {
        Ensure-ParentDirectory $resolvedLogPath
        Ensure-ParentDirectory $tclResultPath
        if (Test-Path -LiteralPath $tclResultPath) {
            Remove-Item -LiteralPath $tclResultPath -Force
        }

        $tclPath = (Resolve-Path -LiteralPath "fpga\vivado\basys3_program.tcl").Path
        $workDir = Resolve-RepoPath 'build/vivado/program'
        New-Item -ItemType Directory -Force -Path $workDir | Out-Null
        $vivadoArgs = @(
            "-mode", "batch",
            "-log", (Join-Path $workDir 'vivado.log'),
            "-journal", (Join-Path $workDir 'vivado.jou'),
            "-source", $tclPath.Replace("\", "/"),
            "-tclargs",
            "-bitstream", $resolvedBitstreamPath.Replace("\", "/"),
            "-device_selector", $DeviceSelector,
            "-result_path", $tclResultPath.Replace("\", "/")
        )

        $programming = Invoke-LoggedVendorTool -FilePath $summary.vivado_path -Arguments $vivadoArgs `
            -WorkingDirectory $workDir -LogPath $resolvedLogPath

        if (Test-Path -LiteralPath $tclResultPath -PathType Leaf) {
            $hardwareResult = Read-JsonFile $tclResultPath
            $summary.hardware_opened = [bool] $hardwareResult.hardware_opened
            $summary.device_found = [bool] $hardwareResult.device_found
            $summary.device_programmed = [bool] $hardwareResult.device_programmed
            $summary.device = if ([string]::IsNullOrWhiteSpace($hardwareResult.device_name)) { $null } else { $hardwareResult.device_name }
            if (-not [string]::IsNullOrWhiteSpace($hardwareResult.error)) {
                $summary.error = $hardwareResult.error
            }
        }

        if ($programming.status -ne 'passed') {
            throw "Vivado Hardware Manager programming $($programming.status); see $LogPath."
        }
        if (-not $summary.hardware_opened -or -not $summary.device_found -or -not $summary.device_programmed) {
            throw "Vivado returned without complete one-shot programming confirmation."
        }
        $summary.status = "pass"
    }
} catch {
    $failureMessage = $_.Exception.Message
    $summary.status = "fail"
    if ([string]::IsNullOrWhiteSpace($summary.error)) {
        $summary.error = $failureMessage
    }
} finally {
    $summary.generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    Write-ResultJson $summary $resolvedSummaryPath
}

Write-Host "========================================"
Write-Host "Basys3 direct-100-MHz JTAG programming flow"
Write-Host ("Status: {0}" -f $summary.status)
Write-Host ("Vivado: {0}" -f ($(if ($null -eq $summary.vivado_version) { "not determined" } else { ($summary.vivado_version -split "`n")[0] })))
Write-Host ("Top/device: {0} / {1}" -f $summary.top, $summary.device_selector)
Write-Host ("Bitstream: {0}" -f $summary.bitstream_path)
Write-Host ("Size/SHA256: {0} / {1}" -f $summary.bitstream_size_bytes, $summary.bitstream_sha256)
Write-Host ("Hardware opened: {0}" -f $summary.hardware_opened)
Write-Host ("Device found/programmed: {0}/{1}" -f $summary.device_found, $summary.device_programmed)
Write-Host ("Retry count: {0}" -f $summary.retry_count)
Write-Host ("Summary: {0}" -f $SummaryPath)

if ($summary.status -eq "dry_run") {
    Write-Host "Dry run only: Hardware Manager and hw_server were not opened, and no device was programmed."
    exit 0
}
if ($summary.status -ne "pass") {
    throw $failureMessage
}

Write-Host "PASS: canonical bitstream programmed once; UART/LED physical validation remains pending."
