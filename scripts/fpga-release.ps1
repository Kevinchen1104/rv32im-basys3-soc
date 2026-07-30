<#
Script: scripts\fpga-release.ps1
Purpose: Rebuilds a compact, source-identifiable FPGA evidence package.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\fpga-release.ps1 -BoardProfile basys3
Outputs:
  release\fpga\<profile> with status, manifests, and source-matched reports when available.
Scope:
  Generated evidence only. Repository sources remain the build input, and binary bitstreams are intentionally not packaged.
Audience:
  Public reviewers inspecting reproducible FPGA evidence.
#>
param(
    [ValidateSet("generic_uart_boot_runtime", "basys3")]
    [string] $BoardProfile = "generic_uart_boot_runtime"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. "$PSScriptRoot\basys3-physical-evidence.ps1"
. "$PSScriptRoot\verification-source-identity.ps1"

function Assert-GeneratedPackagePath {
    param([string] $Path)

    $allowedRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot.Path "release\fpga"))
    $target = [System.IO.Path]::GetFullPath($Path)
    if (-not $allowedRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $allowedRoot += [System.IO.Path]::DirectorySeparatorChar
    }
    if (-not $target.StartsWith($allowedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $target -eq $allowedRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar)) {
        throw "Refusing to modify path outside release/fpga: $target"
    }
}

function Read-JsonIfPresent {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-AuthoritativeWorkingTreeStatus {
    return @(& git status --porcelain=v1 -- . ":(exclude)release/**" 2>$null)
}

function Get-BuildInputIdentity {
    $inputPaths = [System.Collections.Generic.List[string]]::new()
    $manifestPath = "fpga\fpga_sources.f"
    $inputPaths.Add($manifestPath) | Out-Null
    foreach ($line in Get-Content -LiteralPath $manifestPath) {
        $candidate = $line.Trim()
        if ($candidate -ne "" -and -not $candidate.StartsWith("#")) {
            $inputPaths.Add($candidate.Replace("/", "\")) | Out-Null
        }
    }
    foreach ($supportPath in @(
        "fpga\vivado\basys3_build.tcl",
        "fpga\boards\basys3\basys3.xdc"
    )) {
        $inputPaths.Add($supportPath) | Out-Null
    }

    $records = @(
        foreach ($path in @($inputPaths | Sort-Object -Unique)) {
            if (-not (Test-Path -LiteralPath $path)) {
                throw "FPGA input missing: $path"
            }
            [ordered]@{
                path = $path.Replace("\", "/")
                sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    )
    $identityText = ($records | ForEach-Object { "$($_.path):$($_.sha256)" }) -join "`n"
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($identityText)
        $fingerprint = [System.BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace("-", "").ToLowerInvariant()
    } finally {
        $hasher.Dispose()
    }
    return [ordered]@{ fingerprint = $fingerprint; inputs = $records }
}

function Copy-PackageFile {
    param(
        [string] $Source,
        [string] $DestinationRelative,
        [switch] $Optional
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        if ($Optional) {
            return $false
        }
        throw "Required evidence input missing: $Source"
    }
    $destination = Join-Path $packageRoot $DestinationRelative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $destination -Force
    return $true
}

function ConvertTo-PublicEvidenceText {
    param(
        [string] $Text,
        [string[]] $AdditionalAbsolutePaths = @()
    )

    $result = $Text
    $pathReplacements = @(
        @{ path = $repoRoot.Path; replacement = "<repo>" },
        @{ path = [Environment]::GetFolderPath("UserProfile"); replacement = "<user-home>" }
    )
    foreach ($path in $AdditionalAbsolutePaths) {
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $pathReplacements += @{ path = $path; replacement = "<vivado>" }
        }
    }

    foreach ($entry in $pathReplacements) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.path)) {
            continue
        }
        $variants = @(
            [string]$entry.path,
            ([string]$entry.path).Replace("\", "/"),
            ([string]$entry.path).Replace("\", "\\")
        ) | Select-Object -Unique | Sort-Object { $_.Length } -Descending
        foreach ($variant in $variants) {
            $result = $result.Replace($variant, [string]$entry.replacement)
        }
    }

    $result = [regex]::Replace($result, '(?i)[A-Z]:[\\/]+Users[\\/]+[^\\/"\r\n\s]+', '<user-home>')
    $result = [regex]::Replace($result, '(?i)[A-Z]:[\\/]+(?:AMDDesignTools|AMD|Xilinx)[\\/]+[^\s"|,\r\n]+', '<vivado-install>')
    return $result
}

function Copy-PublicEvidenceFile {
    param(
        [string] $Source,
        [string] $DestinationRelative,
        [string[]] $AdditionalAbsolutePaths = @()
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Required public evidence input missing: $Source"
    }
    $destination = Join-Path $packageRoot $DestinationRelative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    $text = Get-Content -LiteralPath $Source -Raw
    $publicText = ConvertTo-PublicEvidenceText -Text $text -AdditionalAbsolutePaths $AdditionalAbsolutePaths
    $publicText = [regex]::Replace(
        $publicText,
        '(?m)^\| Host\s*:.*$',
        '| Host         : [redacted in public evidence package]'
    )
    [System.IO.File]::WriteAllText(
        $destination,
        $publicText,
        [System.Text.Encoding]::ASCII
    )
    return $true
}

function Get-PackageRelativePath {
    param([string] $Path)

    $base = [System.IO.Path]::GetFullPath($packageRoot)
    if (-not $base.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $base += [System.IO.Path]::DirectorySeparatorChar
    }
    return ([System.IO.Path]::GetFullPath($Path)).Substring($base.Length).Replace("\", "/")
}

$profilePath = "fpga\boards\$BoardProfile\board.json"
if (-not (Test-Path -LiteralPath $profilePath)) {
    throw "Unsupported or incomplete board profile: $BoardProfile"
}

$identity = Get-BuildInputIdentity
$verificationIdentity = Get-VerificationSourceIdentity
if ($verificationIdentity.verification_working_tree_dirty) {
    throw "FPGA evidence packaging requires committed verification source inputs."
}

$packageRoot = Join-Path $repoRoot.Path "release\fpga\$BoardProfile"
Assert-GeneratedPackagePath -Path $packageRoot
if (Test-Path -LiteralPath $packageRoot) {
    Remove-Item -LiteralPath $packageRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null

$gitHead = (& git rev-parse HEAD 2>$null).Trim()
$authoritativeWorkingTreeStatus = @(Get-AuthoritativeWorkingTreeStatus)
$workingTreeDirty = $authoritativeWorkingTreeStatus.Count -ne 0
$rtlSourceCount = @(
    Get-Content -LiteralPath "fpga\fpga_sources.f" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne "" -and -not $_.StartsWith("#") }
).Count

Copy-PackageFile -Source "fpga\fpga_sources.f" -DestinationRelative "fpga_sources.f" | Out-Null

$vivadoSummaryPath = "wave\vivado-basys3-build-summary.json"
$vivadoSummary = Read-JsonIfPresent $vivadoSummaryPath
$robustnessSummaryPath = "wave\vivado-basys3-robustness-summary.json"
$robustnessSummary = Read-JsonIfPresent $robustnessSummaryPath
$releaseEvidenceSummary = Read-JsonIfPresent "wave\release-evidence-summary.json"
$currentVivadoIdentity = (
    $null -ne $vivadoSummary -and
    $vivadoSummary.status -eq "pass" -and
    $vivadoSummary.top -eq "RISCVCPU_basys3_top" -and
    $vivadoSummary.source_fingerprint -eq $identity.fingerprint
)
$matchingVivadoBuild = ($BoardProfile -eq "basys3" -and $currentVivadoIdentity)
$matchingRobustnessSweep = (
    $BoardProfile -eq "basys3" -and
    $matchingVivadoBuild -and
    $null -ne $robustnessSummary -and
    $robustnessSummary.status -eq "pass" -and
    $robustnessSummary.top -eq "RISCVCPU_basys3_top" -and
    [int]$robustnessSummary.run_count -eq 5 -and
    $robustnessSummary.all_implementations_passed -eq $true -and
    $robustnessSummary.identity_consistent -eq $true -and
    [string]$robustnessSummary.source_commit -eq [string]$vivadoSummary.source_commit -and
    $robustnessSummary.working_tree_dirty -eq $false -and
    [string]$robustnessSummary.source_fingerprint -eq $identity.fingerprint -and
    [string]$robustnessSummary.verification_input_fingerprint -eq
        $verificationIdentity.verification_input_fingerprint -and
    [int]$robustnessSummary.verification_input_count -eq
        $verificationIdentity.verification_input_count -and
    $robustnessSummary.verification_working_tree_dirty -eq $false -and
    @($robustnessSummary.runs).Count -eq 5 -and
    @($robustnessSummary.runs | Where-Object {
        $_.status -ne "pass" -or
        $_.implementation_status -ne "pass" -or
        $_.timing_closure_status -ne "met" -or
        $_.timing_constraint_status -ne "pass" -or
        [double]$_.wns_ns -lt 0.0 -or
        [double]$_.tns_ns -ne 0.0 -or
        [double]$_.whs_ns -lt 0.0 -or
        [double]$_.ths_ns -ne 0.0 -or
        [int]$_.no_clock_count -ne 0 -or
        [int]$_.unconstrained_internal_endpoint_count -ne 0 -or
        [int]$_.no_input_delay_count -ne 0 -or
        [int]$_.no_output_delay_count -ne 0 -or
        $_.drc_status -ne "pass" -or
        [int]$_.drc_error_count -ne 0 -or
        [int]$_.drc_critical_warning_count -ne 0 -or
        [int]$_.drc_unapproved_warning_count -ne 0 -or
        [int]$_.bram_async_control_warning_count -ne 0
    }).Count -eq 0
)
$currentReleaseIdentity = (
    $null -ne $releaseEvidenceSummary -and
    $releaseEvidenceSummary.status -eq "pass" -and
    $releaseEvidenceSummary.source_fingerprint -eq $identity.fingerprint -and
    $releaseEvidenceSummary.verification_input_fingerprint -eq
        $verificationIdentity.verification_input_fingerprint -and
    [int]$releaseEvidenceSummary.verification_input_count -eq
        $verificationIdentity.verification_input_count -and
    $releaseEvidenceSummary.verification_working_tree_dirty -eq $false
)
$evidenceSourceCommit = if ($currentVivadoIdentity -and -not [string]::IsNullOrWhiteSpace([string]$vivadoSummary.source_commit)) {
    [string]$vivadoSummary.source_commit
} elseif ($currentReleaseIdentity -and -not [string]::IsNullOrWhiteSpace([string]$releaseEvidenceSummary.source_commit)) {
    [string]$releaseEvidenceSummary.source_commit
} else {
    $gitHead
}

$vivadoEvidenceStatus = if ($BoardProfile -eq "basys3") { "not_run_or_stale" } else { "not_applicable" }
$timingClosure = "not_run"
$timingConstraintStatus = "not_run"
$noClockCount = $null
$unconstrainedInternalEndpointCount = $null
$noInputDelayCount = $null
$noOutputDelayCount = $null
$implementationStrategy = $null
$robustnessEvidenceStatus = if ($BoardProfile -eq "basys3") { "not_run_or_stale" } else { "not_applicable" }
$robustnessRunCount = $null
$robustnessWorstWnsNs = $null
$robustnessBestWnsNs = $null
$robustnessMinimumWnsTargetNs = $null
$robustnessMarginTargetStatus = "not_run"
$bitstreamStatus = "not_run"
$bitstreamBuildPath = $null
$bitstreamSizeBytes = $null
$bitstreamSha256 = $null
$physicalEvidence = $null
$physicalValidationStatus = "not_run"
$physicalValidationScope = "needs_revalidation"
$drcStatus = if ($BoardProfile -eq "basys3") { "not_run_or_stale" } else { "not_applicable" }
$drcErrorCount = $null
$drcCriticalWarningCount = $null
$drcUnapprovedWarningCount = $null
$bramAsyncControlWarningCount = $null

if ($matchingVivadoBuild) {
    $vivadoEvidenceStatus = "current"
    $vivadoToolPath = [string]$vivadoSummary.tool.path
    Copy-PublicEvidenceFile -Source $vivadoSummaryPath -DestinationRelative "evidence\vivado-basys3-build-summary.json" -AdditionalAbsolutePaths @($vivadoToolPath) | Out-Null
    foreach ($reportProperty in @(
        "post_synth_utilization", "post_synth_timing", "post_synth_critical_path", "post_synth_clocks", "post_synth_drc",
        "post_route_utilization", "post_route_timing", "post_route_critical_path", "post_route_clocks", "post_route_drc"
    )) {
        $report = $vivadoSummary.reports.$reportProperty
        if ($null -ne $report -and $report.present -and -not [string]::IsNullOrWhiteSpace($report.path)) {
            Copy-PublicEvidenceFile -Source $report.path -DestinationRelative ("evidence\reports\" + (Split-Path -Leaf $report.path)) -AdditionalAbsolutePaths @($vivadoToolPath) | Out-Null
        }
    }
    foreach ($clockReportName in @("post_synth_clocks.rpt", "post_route_clocks.rpt")) {
        $clockReportSource = Join-Path $vivadoSummary.out_dir ("reports\" + $clockReportName)
        Copy-PublicEvidenceFile -Source $clockReportSource -DestinationRelative ("evidence\reports\" + $clockReportName) -AdditionalAbsolutePaths @($vivadoToolPath) | Out-Null
    }
    $timingExceptionsPath = [string]$vivadoSummary.reports.post_route_timing_exceptions
    if (-not [string]::IsNullOrWhiteSpace($timingExceptionsPath)) {
        Copy-PublicEvidenceFile `
            -Source $timingExceptionsPath `
            -DestinationRelative ("evidence\reports\" + (Split-Path -Leaf $timingExceptionsPath)) `
            -AdditionalAbsolutePaths @($vivadoToolPath) | Out-Null
    }

    $postRoute = $vivadoSummary.reports.post_route_timing
    $postRouteDrc = $vivadoSummary.reports.post_route_drc
    if ($null -ne $postRouteDrc -and $postRouteDrc.present) {
        $drcErrorCount = [int]$postRouteDrc.error_count
        $drcCriticalWarningCount = [int]$postRouteDrc.critical_warning_count
        $drcUnapprovedWarningCount = [int]$postRouteDrc.unapproved_warning_count
        $bramAsyncControlWarningCount = [int]$postRouteDrc.bram_async_control_warning_count
        $drcStatus = if (
            $postRouteDrc.report_parse_complete -eq $true -and
            $postRouteDrc.release_approved -eq $true
        ) { "pass" } else { "fail" }
    } else {
        $drcStatus = "missing"
    }
    if ($vivadoSummary.timing_constraint_status -eq "pass" -and
        $null -ne $postRoute.no_clock_count -and [int]$postRoute.no_clock_count -eq 0 -and
        $null -ne $postRoute.unconstrained_internal_endpoint_count -and
            [int]$postRoute.unconstrained_internal_endpoint_count -eq 0 -and
        $null -ne $postRoute.no_input_delay_count -and [int]$postRoute.no_input_delay_count -eq 0 -and
        $null -ne $postRoute.no_output_delay_count -and [int]$postRoute.no_output_delay_count -eq 0) {
        $timingConstraintStatus = "pass"
        $noClockCount = [int]$postRoute.no_clock_count
        $unconstrainedInternalEndpointCount = [int]$postRoute.unconstrained_internal_endpoint_count
        $noInputDelayCount = [int]$postRoute.no_input_delay_count
        $noOutputDelayCount = [int]$postRoute.no_output_delay_count
        $implementationStrategy = $vivadoSummary.implementation_strategy
    } else {
        $timingConstraintStatus = "fail"
    }
    if ($timingConstraintStatus -eq "pass" -and
        $vivadoSummary.timing_closure_status -eq "met" -and
        $null -ne $postRoute.wns_ns -and [double]$postRoute.wns_ns -ge 0.0 -and
        $null -ne $postRoute.tns_ns -and [double]$postRoute.tns_ns -eq 0.0 -and
        $null -ne $postRoute.whs_ns -and [double]$postRoute.whs_ns -ge 0.0 -and
        $null -ne $postRoute.ths_ns -and [double]$postRoute.ths_ns -eq 0.0) {
        $timingClosure = "met"
    } elseif ($vivadoSummary.implementation_status -eq "pass") {
        $timingClosure = "not_met_or_unverified"
    }

    if ($vivadoSummary.bitstream_status -eq "pass" -and
        -not [string]::IsNullOrWhiteSpace($vivadoSummary.bitstream) -and
        (Test-Path -LiteralPath $vivadoSummary.bitstream)) {
        $bitstreamFile = Get-Item -LiteralPath $vivadoSummary.bitstream
        $bitstreamStatus = "generated_current_sources"
        $bitstreamBuildPath = $vivadoSummary.bitstream.Replace("\", "/")
        $bitstreamSizeBytes = $bitstreamFile.Length
        $bitstreamSha256 = (Get-FileHash -LiteralPath $bitstreamFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

if ($matchingRobustnessSweep) {
    $robustnessEvidenceStatus = "current"
    $robustnessRunCount = [int]$robustnessSummary.run_count
    $robustnessWorstWnsNs = [double]$robustnessSummary.worst_wns_ns
    $robustnessBestWnsNs = [double]$robustnessSummary.best_wns_ns
    $robustnessMinimumWnsTargetNs = [double]$robustnessSummary.minimum_wns_target_ns
    $robustnessMarginTargetStatus = [string]$robustnessSummary.margin_target_status
    Copy-PublicEvidenceFile `
        -Source $robustnessSummaryPath `
        -DestinationRelative "evidence\vivado-basys3-robustness-summary.json" | Out-Null
}

if ($BoardProfile -eq "basys3") {
    if (-not $matchingVivadoBuild -or -not $matchingRobustnessSweep -or
        $timingClosure -ne "met" -or
        $timingConstraintStatus -ne "pass" -or
        $bitstreamStatus -ne "generated_current_sources" -or $drcStatus -ne "pass") {
        throw "Basys3 physical evidence requires current source-matched implementation, complete timing constraints, bitstream, timing closure, and clean DRC evidence."
    }
    $physicalEvidence = Get-Basys3PhysicalEvidence -VerifyCaptureSources
    if ($physicalEvidence.source_commit -ne $evidenceSourceCommit -or
        $physicalEvidence.source_fingerprint -ne $identity.fingerprint -or
        [long]$physicalEvidence.bitstream_size_bytes -ne [long]$bitstreamSizeBytes -or
        $physicalEvidence.bitstream_sha256 -ne $bitstreamSha256) {
        throw "Basys3 physical evidence does not match the current canonical build identity."
    }
    foreach ($physicalFile in @("README.md", "summary.json", "xsdb-programming-summary.json", "showcase-transcript.txt", "interactive-transcript.txt", "hardware-validation-transcript.txt")) {
        Copy-PackageFile -Source (Join-Path $physicalEvidence.evidence_root $physicalFile) -DestinationRelative ("evidence\physical\" + $physicalFile) | Out-Null
    }
    $physicalValidationStatus = $physicalEvidence.physical_validation_status
    $physicalValidationScope = $physicalEvidence.physical_validation_scope
}

@(
    "# FPGA Evidence Package",
    "",
    "This evidence-only directory is generated from the repository root. The source",
    "manifest identifies the repository files used by the build; source trees and",
    "binary bitstreams are intentionally not copied into this package.",
    "The working_tree_dirty field covers the repository except generated release/** outputs.",
    "source_commit identifies the fingerprint-matched synthesis inputs; repository_head identifies the package-generation HEAD.",
    "",
    "Rebuild package:",
    "",
    '```powershell',
    "powershell -ExecutionPolicy Bypass -File scripts/fpga-release.ps1 -BoardProfile $BoardProfile",
    '```',
    "",
    $(if ($BoardProfile -eq "basys3") { "For Basys3, timing is met only when post-route WNS is nonnegative and TNS is zero." } else { "This generic profile is a portable integration package without board-specific timing or physical-validation claims." }),
    $(if ($BoardProfile -eq "basys3") { "The physical pass is scoped by evidence/physical/summary.json; the bitstream binary is not packaged." } else { "Select a concrete board, constraints, and vendor flow before making implementation claims." })
) | Set-Content -LiteralPath (Join-Path $packageRoot "COMMANDS.md") -Encoding Ascii

$status = [ordered]@{
    schema_version = 3
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = "pass"
    package_kind = "evidence_only"
    board_profile = $BoardProfile
    package_path = "release/fpga/$BoardProfile"
    source_commit = $evidenceSourceCommit
    repository_head = $gitHead
    working_tree_dirty = $workingTreeDirty
    working_tree_scope = "repository_excluding_release"
    source_fingerprint = $identity.fingerprint
    verification_input_fingerprint = $verificationIdentity.verification_input_fingerprint
    verification_input_count = $verificationIdentity.verification_input_count
    verification_working_tree_dirty = $verificationIdentity.verification_working_tree_dirty
    rtl_source_count = $rtlSourceCount
    fingerprint_input_count = @($identity.inputs).Count
    vivado_evidence_status = $vivadoEvidenceStatus
    timing_closure_status = $timingClosure
    timing_constraint_status = $timingConstraintStatus
    no_clock_count = $noClockCount
    unconstrained_internal_endpoint_count = $unconstrainedInternalEndpointCount
    no_input_delay_count = $noInputDelayCount
    no_output_delay_count = $noOutputDelayCount
    implementation_strategy = $implementationStrategy
    robustness_evidence_status = $robustnessEvidenceStatus
    robustness_run_count = $robustnessRunCount
    robustness_worst_wns_ns = $robustnessWorstWnsNs
    robustness_best_wns_ns = $robustnessBestWnsNs
    robustness_minimum_wns_target_ns = $robustnessMinimumWnsTargetNs
    robustness_margin_target_status = $robustnessMarginTargetStatus
    drc_status = $drcStatus
    drc_error_count = $drcErrorCount
    drc_critical_warning_count = $drcCriticalWarningCount
    drc_unapproved_warning_count = $drcUnapprovedWarningCount
    bram_async_control_warning_count = $bramAsyncControlWarningCount
    bitstream_status = $bitstreamStatus
    bitstream_build_path = $bitstreamBuildPath
    bitstream_size_bytes = $bitstreamSizeBytes
    bitstream_sha256 = $bitstreamSha256
    bitstream_file_tracked = $false
    binary_intentionally_not_packaged = $true
    report_host_metadata_redacted = ($BoardProfile -eq "basys3" -and $matchingVivadoBuild)
    report_path_metadata_redacted = ($BoardProfile -eq "basys3" -and $matchingVivadoBuild)
    physical_validation_status = $physicalValidationStatus
    physical_validation_scope = $physicalValidationScope
    physical_evidence_summary_path = if ($null -eq $physicalEvidence) { $null } else { "evidence/physical/summary.json" }
    physical_evidence_summary_sha256 = if ($null -eq $physicalEvidence) { $null } else { $physicalEvidence.summary_sha256 }
    programming_evidence_level = if ($null -eq $physicalEvidence) { $null } else { $physicalEvidence.programming_evidence_level }
    uart_evidence_level = if ($null -eq $physicalEvidence) { $null } else { $physicalEvidence.uart_evidence_level }
    led_reset_evidence_level = if ($null -eq $physicalEvidence) { $null } else { $physicalEvidence.led_reset_evidence_level }
    artifact_manifest_self_excluded = $true
    claim_boundary = if ($BoardProfile -eq "basys3") { "Source-matched implementation plus scoped physical evidence. XSDB programming/configured state and UART transcripts are machine-captured; LED/reset observations are operator-reported; no on-board bitstream readback/hash verification is claimed." } else { "Source-identifiable generated evidence only. Repository sources are authoritative, the bitstream binary is not packaged, and this profile has no Basys3 physical-validation claim." }
}
$status | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $packageRoot "status.json") -Encoding Ascii

$artifactManifest = @(
    foreach ($file in Get-ChildItem -LiteralPath $packageRoot -Recurse -File | Where-Object { $_.Name -ne "artifacts.json" } | Sort-Object FullName) {
        [ordered]@{
            path = Get-PackageRelativePath -Path $file.FullName
            bytes = $file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
)
$artifactManifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $packageRoot "artifacts.json") -Encoding Ascii

Write-Host "========================================"
Write-Host "FPGA evidence package"
Write-Host ("Profile: {0}" -f $BoardProfile)
Write-Host ("Source fingerprint: {0}" -f $identity.fingerprint)
Write-Host ("Vivado evidence: {0}" -f $vivadoEvidenceStatus)
Write-Host ("Timing closure: {0}" -f $timingClosure)
Write-Host ("DRC: {0}; errors {1}; critical warnings {2}; unapproved warnings {3}; REQP-1839 {4}" -f $drcStatus, $drcErrorCount, $drcCriticalWarningCount, $drcUnapprovedWarningCount, $bramAsyncControlWarningCount)
Write-Host ("Bitstream: {0}; binary packaged: false" -f $bitstreamStatus)
Write-Host ("Physical validation: {0} ({1})" -f $physicalValidationStatus, $physicalValidationScope)
Write-Host ("Package: release\fpga\{0}" -f $BoardProfile)
