<#
Script: scripts\arch-test-report.ps1
Purpose: Summarizes selected architectural-test integration artifacts and signature comparisons.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\arch-test-report.ps1
Outputs:
  Console and file report artifacts under wave\arch-test when run after arch-test execution.
Scope:
  Selected local integration reporting only; not official RISC-V compliance.
Audience:
  Public optional arch-test reporting helper.
#>
param(
    [string]$ResultsPath = "wave\arch-test-results.json",
    [string]$DetectPath = "wave\arch-test-detect.json",
    [string]$SetupPath = "wave\arch-test-setup.json",
    [string]$OutputPath = "wave\arch-test-report.json"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
New-Item -ItemType Directory -Force -Path "wave" | Out-Null

function Read-JsonIfPresent {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

$results = Read-JsonIfPresent $ResultsPath
$detect = Read-JsonIfPresent $DetectPath
$setup = Read-JsonIfPresent $SetupPath

if ($null -eq $results) {
    $report = [ordered]@{
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        status = "missing_results"
        results_path = $ResultsPath
        detection_status = if ($null -eq $detect) { $null } else { $detect.status }
        setup_status = if ($null -eq $setup) { $null } else { $setup.status }
        upstream_commit = if ($null -eq $setup) { $null } else { $setup.upstream_commit }
        claim_boundary = "no official arch-test result exists yet; no official compliance claim"
    }

    $report | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputPath -Encoding Ascii

    Write-Host "========================================"
    Write-Host "RISC-V arch-test report"
    Write-Host "Status: missing_results"
    Write-Host ("Run first: powershell -ExecutionPolicy Bypass -File scripts\arch-test-run.ps1 -Profile rv32im-selected")
    Write-Host ("Report written to {0}" -f $OutputPath)
    exit 0
}

$statusValues = @(
    "passed_official_reference",
    "passed_local_reference",
    "failed_signature",
    "failed",
    "unsupported",
    "blocked_no_tool",
    "blocked_no_reference",
    "build_failed",
    "timeout"
)
$totals = [ordered]@{}
foreach ($statusName in $statusValues) {
    $totals[$statusName] = if ($results.totals.PSObject.Properties.Name -contains $statusName) {
        $results.totals.$statusName
    } else {
        0
    }
}

$attemptedRows = @($results.tests | Where-Object {
    $_.status -ne "unsupported" -and $_.status -ne "blocked_no_tool"
})
$failedRows = @($results.tests | Where-Object {
    $_.status -eq "failed_signature" -or $_.status -eq "failed" -or $_.status -eq "timeout" -or $_.status -eq "build_failed"
})
$blockedRows = @($results.tests | Where-Object {
    $_.status -eq "blocked_no_tool" -or $_.status -eq "blocked_no_reference"
})

$report = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = $results.status
    profile = $results.profile
    upstream_repo = $results.upstream_repo
    upstream_commit = $results.upstream_commit
    detection_status = $results.detection_status
    setup_status = $results.setup_status
    toolchain = if ($results.PSObject.Properties.Name -contains "toolchain") { $results.toolchain } else { $null }
    reference_summary = if ($results.PSObject.Properties.Name -contains "reference_summary") { $results.reference_summary } else { $null }
    selected_tests = $results.selected_tests
    attempted_tests = @($attemptedRows).Count
    totals = $totals
    failures = @($failedRows | ForEach-Object {
        [ordered]@{
            id = $_.id
            status = $_.status
            reason = $_.reason
            work_dir = $_.work_dir
            reference_kind = if ($_.PSObject.Properties.Name -contains "reference_kind") { $_.reference_kind } else { $null }
            first_mismatch_index = if ($_.PSObject.Properties.Name -contains "first_mismatch_index") { $_.first_mismatch_index } else { -1 }
            dut_signature_path = if ($_.PSObject.Properties.Name -contains "dut_signature_path") { $_.dut_signature_path } else { $null }
            reference_signature_path = if ($_.PSObject.Properties.Name -contains "reference_signature_path") { $_.reference_signature_path } else { $null }
        }
    })
    blocked = @($blockedRows | ForEach-Object {
        [ordered]@{
            id = $_.id
            status = $_.status
            reason = $_.reason
        }
    })
    claim_boundary = "selected official RISC-V arch-test sources; signature comparison is split by official or local reference kind and is not an official compliance suite result"
}

$report | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputPath -Encoding Ascii

Write-Host "========================================"
Write-Host "RISC-V arch-test report"
Write-Host ("Status: {0}" -f $report.status)
Write-Host ("Profile: {0}" -f $report.profile)
Write-Host ("Upstream commit: {0}" -f $report.upstream_commit)
foreach ($statusName in $statusValues) {
    Write-Host ("{0}: {1}" -f $statusName, $totals[$statusName])
}
if ($null -ne $report.reference_summary) {
    Write-Host ("Official reference available: {0}" -f $report.reference_summary.official.available)
    Write-Host ("Local reference used tests: {0}" -f $report.reference_summary.local.used_tests)
}
Write-Host "Boundary: selected official RISC-V arch-test sources; not an official compliance suite result"
Write-Host ("Report written to {0}" -f $OutputPath)
