<#
Script: scripts\xsdb-basys3-program.ps1
Purpose: Validates and optionally programs the canonical direct-100-MHz Basys3 bitstream through AMD XSDB.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\xsdb-basys3-program.ps1 -DryRun
Outputs:
  An XSDB-specific JSON summary and log under results\, plus a physical result file only in physical mode.
Scope:
  Independent one-shot fallback; DryRun never starts XSDB, hw_server, target discovery, or programming.
#>
param(
    [string] $BitstreamPath = "",
    [string] $ExpectedSha256 = "",
    [long] $ExpectedSizeBytes = 0,
    [string] $DeviceSelector = "*xc7a35t*",
    [switch] $DryRun,
    [string] $SummaryPath = "results\xsdb-basys3-program-summary.json",
    [string] $LogPath = "results\xsdb-basys3-program.log"
)

. "$PSScriptRoot/script-common.ps1"
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/result-format.ps1"
. "$PSScriptRoot/process-runner.ps1"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

. (Join-Path $PSScriptRoot "canonical-basys3-evidence.ps1")

function Find-Xsdb {
    $path = Find-FpgaVendorTool xsdb
    if (-not $path) { throw 'AMD XSDB was not found on PATH or in a supported installation.' }
    $match = [regex]::Match($path, '[\\/](\d{4}\.\d+)[\\/]')
    $version = if ($match.Success) { $match.Groups[1].Value } else { '0.0' }
    return [pscustomobject]@{ Path=$path; Version=[version]$version; VersionText=$version }
}

$resolvedSummaryPath = Resolve-RepoPath $SummaryPath
$resolvedLogPath = Resolve-RepoPath $LogPath
$resolvedBitstreamPath = $null
$tclResultPath = [IO.Path]::ChangeExtension($resolvedSummaryPath, 'hardware.json')
Ensure-ParentDirectory $resolvedSummaryPath

$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = "starting"
    xsdb_version = $null
    xsdb_path = $null
    board = "Digilent Basys3"
    fpga_part = "xc7a35tcpg236-1"
    device_selector = $DeviceSelector
    top = "RISCVCPU_basys3_top"
    bitstream_path = $BitstreamPath
    bitstream_absolute_path = $resolvedBitstreamPath
    bitstream_size_bytes = $null
    expected_size_bytes = $ExpectedSizeBytes
    bitstream_sha256 = $null
    expected_sha256 = $ExpectedSha256
    canonical_match = $false
    source_commit = $null
    source_fingerprint = $null
    fingerprint_input_count = $null
    repository_head = $null
    dry_run = [bool] $DryRun
    hardware_connected = $false
    target_count = 0
    selected_target = $null
    device_programmed = $false
    configuration_verified = $false
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
    $resolvedBitstreamPath = Resolve-RepoPath $BitstreamPath
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
    $summary.canonical_match = $true
    $summary.repository_head = (& git rev-parse HEAD).Trim()

    $xsdb = Find-Xsdb
    $summary.xsdb_path = $xsdb.Path
    $summary.xsdb_version = $xsdb.VersionText

    if ($DryRun) {
        $summary.status = "dry_run"
        Ensure-ParentDirectory $resolvedLogPath
        @(
            "status=dry_run"
            "xsdb_path=$($summary.xsdb_path)"
            "canonical_match=$($summary.canonical_match)"
            "hardware_connected=false"
            "target_count=0"
            "device_programmed=false"
            "configuration_verified=false"
            "retry_count=0"
            "physical_validation_status=not_run"
            "XSDB, hw_server, target discovery, and programming were not started."
        ) | Set-Content -LiteralPath $resolvedLogPath -Encoding Ascii
    } else {
        Ensure-ParentDirectory $resolvedLogPath
        Ensure-ParentDirectory $tclResultPath
        if (Test-Path -LiteralPath $tclResultPath) {
            Remove-Item -LiteralPath $tclResultPath -Force
        }

        $tclPath = (Resolve-Path -LiteralPath "fpga\xsdb\basys3_program.tcl").Path.Replace("\", "/")
        $xsdbArgs = @(
            $tclPath,
            "-bitstream", $resolvedBitstreamPath.Replace("\", "/"),
            "-device_selector", $DeviceSelector,
            "-result_path", $tclResultPath.Replace("\", "/")
        )

        # AMD's bundled Tcl fileutil can mis-normalize Windows special folders
        # such as AppData and Desktop. Use a simple user-home temp path for the
        # process, then restore the caller's environment after the invocation.
        $userProfilePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        if ([string]::IsNullOrWhiteSpace($userProfilePath)) {
            throw "Unable to resolve the current Windows user profile for XSDB temporary files."
        }
        $xsdbTempPath = [System.IO.Path]::GetFullPath((Join-Path $userProfilePath ".xsdb-tmp"))
        New-Item -ItemType Directory -Force -Path $xsdbTempPath | Out-Null
        $savedTempEnvironment = [ordered]@{
            TEMP = [Environment]::GetEnvironmentVariable("TEMP", "Process")
            TMP = [Environment]::GetEnvironmentVariable("TMP", "Process")
            TMPDIR = [Environment]::GetEnvironmentVariable("TMPDIR", "Process")
        }
        try {
            $env:TEMP = $xsdbTempPath
            $env:TMP = $xsdbTempPath
            $env:TMPDIR = $xsdbTempPath
            $programming = Invoke-LoggedVendorTool -FilePath $summary.xsdb_path -Arguments $xsdbArgs `
                -WorkingDirectory $repoRoot.Path -LogPath $resolvedLogPath
        } finally {
            foreach ($name in $savedTempEnvironment.Keys) {
                $savedValue = $savedTempEnvironment[$name]
                if ($null -eq $savedValue) {
                    [Environment]::SetEnvironmentVariable($name, $null, "Process")
                } else {
                    [Environment]::SetEnvironmentVariable($name, $savedValue, "Process")
                }
            }
        }

        if (Test-Path -LiteralPath $tclResultPath -PathType Leaf) {
            $hardwareResult = Read-JsonFile $tclResultPath
            $summary.hardware_connected = [bool] $hardwareResult.hardware_connected
            $summary.target_count = [int] $hardwareResult.target_count
            $summary.selected_target = if ([string]::IsNullOrWhiteSpace($hardwareResult.selected_target)) { $null } else { $hardwareResult.selected_target }
            $summary.device_programmed = [bool] $hardwareResult.device_programmed
            $summary.configuration_verified = [bool] $hardwareResult.configuration_verified
            if (-not [string]::IsNullOrWhiteSpace($hardwareResult.error)) {
                $summary.error = $hardwareResult.error
            }
        }

        if ($programming.status -ne 'passed') {
            throw "XSDB programming $($programming.status); see $LogPath."
        }
        if (-not $summary.hardware_connected -or
            $summary.target_count -ne 1 -or
            [string]::IsNullOrWhiteSpace($summary.selected_target) -or
            -not $summary.device_programmed -or
            -not $summary.configuration_verified) {
            throw "XSDB returned without complete one-shot target, programming, and configured-state confirmation."
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
Write-Host "Basys3 direct-100-MHz XSDB programming fallback"
Write-Host ("Status: {0}" -f $summary.status)
Write-Host ("XSDB: {0} ({1})" -f ($(if ($null -eq $summary.xsdb_path) { "not determined" } else { $summary.xsdb_path })), $summary.xsdb_version)
Write-Host ("Top/device: {0} / {1}" -f $summary.top, $summary.device_selector)
Write-Host ("Bitstream: {0}" -f $summary.bitstream_path)
Write-Host ("Size/SHA256: {0} / {1}" -f $summary.bitstream_size_bytes, $summary.bitstream_sha256)
Write-Host ("Hardware connected: {0}" -f $summary.hardware_connected)
Write-Host ("Target count/programmed/configured: {0}/{1}/{2}" -f $summary.target_count, $summary.device_programmed, $summary.configuration_verified)
Write-Host ("Retry count: {0}" -f $summary.retry_count)
Write-Host ("Summary: {0}" -f $SummaryPath)

if ($summary.status -eq "dry_run") {
    Write-Host "Dry run only: XSDB, hw_server, target discovery, and programming were not started."
    exit 0
}
if ($summary.status -ne "pass") {
    throw $failureMessage
}

Write-Host "PASS: canonical bitstream programmed once through XSDB; UART/LED physical validation remains pending."
