<#
Script: scripts\release-freeze.ps1
Purpose: Rebuilds the compact generated evidence package under release\final.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\release-freeze.ps1
Outputs:
  release\final metadata, evidence summaries, source manifests, and an artifact manifest.
Scope:
  Evidence-only handoff. It does not duplicate repository docs, sources, firmware, board files, tools, FPGA packages, or bitstreams.
Audience:
  Public reviewers who want to inspect recorded evidence without rerunning tools.
Package regeneration:
  Start from a clean, committed source revision; rebuild canonical Vivado evidence; run release-freeze
  and final-audit; then commit generated evidence separately.
#>
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. "$PSScriptRoot\basys3-physical-evidence.ps1"
. "$PSScriptRoot\verification-source-identity.ps1"

function Assert-FinalPackagePath {
    param([string] $Path)

    $expected = [System.IO.Path]::GetFullPath((Join-Path $repoRoot.Path "release\final"))
    $target = [System.IO.Path]::GetFullPath($Path)
    if (-not $target.Equals($expected, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to rebuild unexpected path: $target"
    }
}

function Copy-ReleaseFile {
    param(
        [string] $Source,
        [string] $DestinationRelative,
        [switch] $Optional
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        if ($Optional) {
            return $false
        }
        throw "Required freeze input missing: $Source"
    }
    $destination = Join-Path $finalRoot $DestinationRelative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $destination -Force
    return $true
}

function Get-FinalRelativePath {
    param([string] $Path)

    $base = [System.IO.Path]::GetFullPath($finalRoot)
    if (-not $base.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $base += [System.IO.Path]::DirectorySeparatorChar
    }
    return ([System.IO.Path]::GetFullPath($Path)).Substring($base.Length).Replace("\", "/")
}

function Read-Json {
    param([string] $Path)
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
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

function Redact-CopiedEvidenceFile {
    param(
        [string] $Path,
        [string[]] $AdditionalAbsolutePaths = @()
    )

    $text = Get-Content -LiteralPath $Path -Raw
    $publicText = ConvertTo-PublicEvidenceText -Text $text -AdditionalAbsolutePaths $AdditionalAbsolutePaths
    [System.IO.File]::WriteAllText($Path, $publicText, [System.Text.Encoding]::ASCII)
}

& powershell -NoProfile -ExecutionPolicy Bypass -File "scripts\release-evidence.ps1"
if ($LASTEXITCODE -ne 0) {
    throw "Release evidence gate failed"
}

foreach ($profile in @("generic_uart_boot_runtime", "basys3")) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File "scripts\fpga-release.ps1" -BoardProfile $profile
    if ($LASTEXITCODE -ne 0) {
        throw "FPGA evidence package failed: $profile"
    }
}

$releaseEvidence = Read-Json "wave\release-evidence-summary.json"
if ($releaseEvidence.status -ne "pass") {
    throw "release-evidence-summary.json does not report pass"
}

$finalRoot = Join-Path $repoRoot.Path "release\final"
Assert-FinalPackagePath -Path $finalRoot
if (Test-Path -LiteralPath $finalRoot) {
    Remove-Item -LiteralPath $finalRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $finalRoot | Out-Null

Copy-ReleaseFile -Source "rtl\rtl_sources.f" -DestinationRelative "source-manifests\rtl_sources.f" | Out-Null
Copy-ReleaseFile -Source "fpga\fpga_sources.f" -DestinationRelative "source-manifests\fpga_sources.f" | Out-Null

foreach ($summaryPath in @(
    "wave\check-summary.json",
    "wave\regression-summary.json",
    "wave\regression-evidence-summary.json",
    "wave\test-catalog-summary.json",
    "wave\verilator-lint-summary.json",
    "wave\synth-smoke-summary.json",
    "wave\formal-smoke-summary.json",
    "wave\formal-matvec-smoke-summary.json",
    "wave\vivado-detect-summary.json",
    "wave\vivado-basys3-build-summary.json",
    "wave\vivado-basys3-robustness-summary.json",
    "wave\release-evidence-summary.json"
)) {
    $destinationRelative = "evidence\" + (Split-Path -Leaf $summaryPath)
    if (Copy-ReleaseFile -Source $summaryPath -DestinationRelative $destinationRelative -Optional) {
        $destinationPath = Join-Path $finalRoot $destinationRelative
        $additionalPaths = @()
        if ((Split-Path -Leaf $summaryPath) -eq "vivado-detect-summary.json") {
            $detectSummary = Read-Json $summaryPath
            $additionalPaths += [string]$detectSummary.tool.path
        } elseif ((Split-Path -Leaf $summaryPath) -eq "vivado-basys3-build-summary.json") {
            $buildSummary = Read-Json $summaryPath
            $additionalPaths += [string]$buildSummary.tool.path
        }
        Redact-CopiedEvidenceFile -Path $destinationPath -AdditionalAbsolutePaths $additionalPaths
    }
}

$regression = Read-Json "wave\regression-summary.json"
$basys3Status = Read-Json "release\fpga\basys3\status.json"
if ($basys3Status.timing_constraint_status -ne "pass" -or
    $null -eq $basys3Status.no_clock_count -or [int]$basys3Status.no_clock_count -ne 0 -or
    $null -eq $basys3Status.unconstrained_internal_endpoint_count -or
        [int]$basys3Status.unconstrained_internal_endpoint_count -ne 0 -or
    $null -eq $basys3Status.no_input_delay_count -or [int]$basys3Status.no_input_delay_count -ne 0 -or
    $null -eq $basys3Status.no_output_delay_count -or [int]$basys3Status.no_output_delay_count -ne 0) {
    throw "Basys3 package does not prove complete internal and board-I/O timing constraints."
}
if ($basys3Status.robustness_evidence_status -ne "current" -or
    [int]$basys3Status.robustness_run_count -ne 5 -or
    $null -eq $basys3Status.robustness_worst_wns_ns -or
    [double]$basys3Status.robustness_worst_wns_ns -lt 0.0 -or
    $null -eq $basys3Status.robustness_best_wns_ns -or
    [double]$basys3Status.robustness_best_wns_ns -lt
        [double]$basys3Status.robustness_worst_wns_ns) {
    throw "Basys3 package does not contain five source-matched timing-closed implementation strategies."
}
$physicalEvidence = Get-Basys3PhysicalEvidence -VerifyCaptureSources
if ($basys3Status.physical_validation_status -ne $physicalEvidence.physical_validation_status -or
    $basys3Status.physical_validation_scope -ne $physicalEvidence.physical_validation_scope -or
    $basys3Status.physical_evidence_summary_sha256 -ne $physicalEvidence.summary_sha256) {
    throw "Basys3 package does not match the durable physical evidence suite."
}
foreach ($physicalFile in @("README.md", "summary.json", "xsdb-programming-summary.json", "showcase-transcript.txt", "interactive-transcript.txt", "hardware-validation-transcript.txt")) {
    Copy-ReleaseFile -Source (Join-Path $physicalEvidence.evidence_root $physicalFile) -DestinationRelative ("evidence\physical\" + $physicalFile) | Out-Null
}
$freezeSummary = [ordered]@{
    schema_version = 3
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = "pass"
    package_kind = "evidence_only"
    source_commit = $releaseEvidence.source_commit
    repository_head = $releaseEvidence.repository_head
    working_tree_dirty = $releaseEvidence.working_tree_dirty
    working_tree_scope = $releaseEvidence.working_tree_scope
    source_fingerprint = $releaseEvidence.source_fingerprint
    verification_input_fingerprint = $releaseEvidence.verification_input_fingerprint
    verification_input_count = $releaseEvidence.verification_input_count
    verification_working_tree_dirty = $releaseEvidence.verification_working_tree_dirty
    rtl_source_count = $basys3Status.rtl_source_count
    fingerprint_input_count = $basys3Status.fingerprint_input_count
    regression = [ordered]@{
        total = $regression.total
        passed = $regression.passed
        failed = $regression.failed
    }
    basys3_package_status = "../fpga/basys3/status.json"
    generic_package_status = "../fpga/generic_uart_boot_runtime/status.json"
    vivado_evidence_status = $basys3Status.vivado_evidence_status
    timing_closure_status = $basys3Status.timing_closure_status
    timing_constraint_status = $basys3Status.timing_constraint_status
    no_clock_count = $basys3Status.no_clock_count
    unconstrained_internal_endpoint_count = $basys3Status.unconstrained_internal_endpoint_count
    no_input_delay_count = $basys3Status.no_input_delay_count
    no_output_delay_count = $basys3Status.no_output_delay_count
    implementation_strategy = $basys3Status.implementation_strategy
    robustness_evidence_status = $basys3Status.robustness_evidence_status
    robustness_run_count = $basys3Status.robustness_run_count
    robustness_worst_wns_ns = $basys3Status.robustness_worst_wns_ns
    robustness_best_wns_ns = $basys3Status.robustness_best_wns_ns
    robustness_minimum_wns_target_ns = $basys3Status.robustness_minimum_wns_target_ns
    robustness_margin_target_status = $basys3Status.robustness_margin_target_status
    drc_status = $basys3Status.drc_status
    drc_error_count = $basys3Status.drc_error_count
    drc_critical_warning_count = $basys3Status.drc_critical_warning_count
    drc_unapproved_warning_count = $basys3Status.drc_unapproved_warning_count
    bram_async_control_warning_count = $basys3Status.bram_async_control_warning_count
    bitstream_status = $basys3Status.bitstream_status
    bitstream_build_path = $basys3Status.bitstream_build_path
    bitstream_size_bytes = $basys3Status.bitstream_size_bytes
    bitstream_sha256 = $basys3Status.bitstream_sha256
    bitstream_file_tracked = $false
    binary_intentionally_not_packaged = $true
    report_host_metadata_redacted = $basys3Status.report_host_metadata_redacted
    report_path_metadata_redacted = $basys3Status.report_path_metadata_redacted
    physical_validation_status = $physicalEvidence.physical_validation_status
    physical_validation_scope = $physicalEvidence.physical_validation_scope
    physical_evidence_summary_path = "evidence/physical/summary.json"
    physical_evidence_summary_sha256 = $physicalEvidence.summary_sha256
    programming_evidence_level = $physicalEvidence.programming_evidence_level
    uart_evidence_level = $physicalEvidence.uart_evidence_level
    led_reset_evidence_level = $physicalEvidence.led_reset_evidence_level
    artifact_manifest_self_excluded = $true
    primary_reading_path = "repository README and docs/README.md"
    claim_boundary = "Generated evidence package for direct inspection. The scoped physical evidence distinguishes machine-captured XSDB programming/configured state and UART transcripts from operator-reported LED/reset observations; no bitstream binary or on-board readback/hash verification is packaged or claimed."
}
$freezeSummary | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $finalRoot "release-summary.json") -Encoding Ascii

@(
    "# Generated Evidence Package",
    "",
    "This compact directory contains machine-readable evidence summaries and source",
    "manifests. The repository README and docs/README.md are the primary reading path.",
    "",
    "Recorded regression: $($regression.passed)/$($regression.total) passed.",
    "Vivado evidence: $($basys3Status.vivado_evidence_status).",
    "Timing closure: $($basys3Status.timing_closure_status).",
    "DRC: $($basys3Status.drc_status); errors $($basys3Status.drc_error_count); critical warnings $($basys3Status.drc_critical_warning_count); unapproved warnings $($basys3Status.drc_unapproved_warning_count); REQP-1839 $($basys3Status.bram_async_control_warning_count).",
    "Bitstream: $($basys3Status.bitstream_status); binary intentionally not packaged.",
    "Physical validation: $($physicalEvidence.physical_validation_status) (scoped; see evidence/physical/summary.json).",
    "source_commit identifies the fingerprint-matched synthesis inputs; repository_head identifies the evidence-generation HEAD.",
    "",
    "See evidence-index.md and release-summary.json. Top-level FPGA evidence packages",
    "are referenced rather than duplicated here.",
    "",
    "## Regenerating this package",
    "",
    "1. Start from a clean, committed source revision.",
    "2. From clean HEAD, rebuild the canonical Vivado implementation and bitstream.",
    "3. Run scripts/release-freeze.ps1; it rebuilds the evidence index and both FPGA profile packages.",
    "4. Run scripts/final-audit.ps1.",
    "5. Commit generated release evidence separately from source changes."
) | Set-Content -LiteralPath (Join-Path $finalRoot "README.md") -Encoding Ascii

@(
    "# Evidence Index",
    "",
    "- evidence/check-summary.json: portable regression orchestration",
    "- evidence/regression-summary.json: per-test simulation results",
    "- evidence/regression-evidence-summary.json: regression evidence checks",
    "- evidence/test-catalog-summary.json: current catalog counts",
    "- evidence/documentation-coverage-summary.json: source-header coverage",
    "- evidence/docs-link-audit-summary.json: documentation link audit",
    "- evidence/claim-audit-summary.json: bounded-claim audit",
    "- evidence/verilator-lint-summary.json: lint result",
    "- evidence/synth-smoke-summary.json: synthesis smoke result",
    "- evidence/formal-smoke-summary.json: bounded CPU properties",
    "- evidence/formal-matvec-smoke-summary.json: bounded MATVEC Scratchpad properties",
    "- evidence/vivado-basys3-build-summary.json: source-matched Vivado result when current",
    "- evidence/vivado-basys3-robustness-summary.json: five-profile implementation-directive sweep",
    "- evidence/physical/summary.json: scoped Basys3 direct-100-MHz physical evidence",
    "- evidence/physical/xsdb-programming-summary.json: sanitized machine-captured JTAG programming record",
    "- evidence/physical/*-transcript.txt: exact machine-captured UART transcripts",
    "- [Basys3 FPGA evidence](../fpga/basys3/status.json)",
    "- [Generic FPGA package status](../fpga/generic_uart_boot_runtime/status.json)",
    "",
    "Bitstream size and SHA-256 are recorded in status metadata, but the ignored binary",
    "is intentionally excluded. Physical programming identity was not read back from the FPGA."
) | Set-Content -LiteralPath (Join-Path $finalRoot "evidence-index.md") -Encoding Ascii

@(
    "# Evidence Boundaries",
    "",
    "The package records directed simulation, bounded formal checks, lint, synthesis,",
    "source-matched implementation evidence, and a scoped physical board suite. These",
    "results do not establish full formal correctness, official RISC-V compliance,",
    "every-instruction physical coverage, production accelerator/DMA behavior, robust",
    "multi-seed timing, external synchronous I/O signoff, benchmark speedup, power",
    "signoff, or on-board bitstream identity readback. No photo, video, or ILA evidence",
    "is included."
) | Set-Content -LiteralPath (Join-Path $finalRoot "limitations.md") -Encoding Ascii

$documentationGatePaths = [ordered]@{
    "scripts\documentation-coverage-audit.ps1" =
        "wave\documentation-coverage-summary.json"
    "scripts\docs-link-audit.ps1" =
        "wave\docs-link-audit-summary.json"
    "scripts\claim-audit.ps1" =
        "wave\claim-audit-summary.json"
}
foreach ($entry in $documentationGatePaths.GetEnumerator()) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $entry.Key
    if ($LASTEXITCODE -ne 0) {
        throw "Post-package documentation gate failed: $($entry.Key)"
    }
}

$documentationIdentity = Get-DocumentationInputIdentity
if ($documentationIdentity.documentation_source_working_tree_dirty) {
    throw "Documentation gates require committed non-release documentation inputs."
}
foreach ($summaryPath in $documentationGatePaths.Values) {
    $documentationSummary = Read-Json $summaryPath
    if ($documentationSummary.status -ne "pass" -or
        [string]$documentationSummary.documentation_repository_head -ne
            [string]$releaseEvidence.repository_head -or
        [string]$documentationSummary.documentation_input_fingerprint -ne
            $documentationIdentity.documentation_input_fingerprint -or
        [int]$documentationSummary.documentation_input_count -ne
            $documentationIdentity.documentation_input_count -or
        $documentationSummary.documentation_source_working_tree_dirty -ne $false) {
        throw "Documentation gate identity mismatch: $summaryPath"
    }
    $destinationRelative = "evidence\" + (Split-Path -Leaf $summaryPath)
    Copy-ReleaseFile -Source $summaryPath -DestinationRelative $destinationRelative | Out-Null
}

$artifactManifest = @(
    foreach ($file in Get-ChildItem -LiteralPath $finalRoot -Recurse -File | Where-Object { $_.Name -ne "artifacts.json" } | Sort-Object FullName) {
        [ordered]@{
            path = Get-FinalRelativePath -Path $file.FullName
            bytes = $file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
)
$artifactManifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $finalRoot "artifacts.json") -Encoding Ascii

Write-Host "========================================"
Write-Host "Final evidence freeze"
Write-Host ("Regression: {0}/{1}" -f $regression.passed, $regression.total)
Write-Host ("Vivado evidence: {0}" -f $basys3Status.vivado_evidence_status)
Write-Host ("Timing closure: {0}" -f $basys3Status.timing_closure_status)
Write-Host ("DRC: {0}; errors {1}; critical warnings {2}; unapproved warnings {3}; REQP-1839 {4}" -f $basys3Status.drc_status, $basys3Status.drc_error_count, $basys3Status.drc_critical_warning_count, $basys3Status.drc_unapproved_warning_count, $basys3Status.bram_async_control_warning_count)
Write-Host ("Bitstream: {0}; binary packaged: false" -f $basys3Status.bitstream_status)
Write-Host ("Physical validation: {0} ({1})" -f $physicalEvidence.physical_validation_status, $physicalEvidence.physical_validation_scope)
Write-Host "Package: release\final"
