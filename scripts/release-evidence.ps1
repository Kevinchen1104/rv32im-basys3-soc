<#
Script: scripts\release-evidence.ps1
Purpose: Builds a source-facing index of current regression, audit, formal, lint, synthesis, and Vivado evidence.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\release-evidence.ps1
Outputs:
  wave\release-evidence-summary.json.
Scope:
  Evidence indexing only. working_tree_dirty covers authoritative repository content and excludes generated release/** outputs.
  The script does not run a board, prove full correctness, or turn stale artifacts into current evidence.
Audience:
  Public release evidence entrypoint.
#>
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
New-Item -ItemType Directory -Force -Path "wave" | Out-Null
. "$PSScriptRoot\basys3-physical-evidence.ps1"
. "$PSScriptRoot\verification-source-identity.ps1"

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

function Get-StatusGate {
    param(
        [string] $Name,
        [string] $Path,
        [string] $ExpectedVerificationFingerprint,
        [int] $ExpectedVerificationInputCount,
        [string[]] $AllowedStatus = @("pass")
    )

    $json = Read-JsonIfPresent -Path $Path
    $identityMatches = (
        $null -ne $json -and
        [string]$json.verification_input_fingerprint -eq $ExpectedVerificationFingerprint -and
        [int]$json.verification_input_count -eq $ExpectedVerificationInputCount -and
        $json.verification_working_tree_dirty -eq $false -and
        [string]$json.source_commit -match '^[0-9a-f]{40}$'
    )
    $status = if ($null -eq $json) {
        "missing"
    } elseif (($AllowedStatus -contains $json.status) -and $identityMatches) {
        "pass"
    } else {
        "fail"
    }
    return [ordered]@{
        name = $Name
        path = $Path.Replace("\", "/")
        status = $status
        reported_status = if ($null -eq $json) { $null } else { $json.status }
        verification_identity_matches = $identityMatches
        source_commit = if ($null -eq $json) { $null } else { $json.source_commit }
        verification_input_fingerprint = if ($null -eq $json) { $null } else { $json.verification_input_fingerprint }
        verification_input_count = if ($null -eq $json) { $null } else { $json.verification_input_count }
        verification_working_tree_dirty = if ($null -eq $json) { $null } else { $json.verification_working_tree_dirty }
        generated_at_utc = if ($null -eq $json) { $null } else { $json.generated_at_utc }
        sha256 = if ($null -eq $json) { $null } else { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
}

function Get-BuildFingerprint {
    $paths = [System.Collections.Generic.List[string]]::new()
    $paths.Add("fpga\fpga_sources.f") | Out-Null
    foreach ($line in Get-Content -LiteralPath "fpga\fpga_sources.f") {
        $path = $line.Trim()
        if ($path -ne "" -and -not $path.StartsWith("#")) {
            $paths.Add($path.Replace("/", "\")) | Out-Null
        }
    }
    foreach ($path in @(
        "fpga\vivado\basys3_build.tcl",
        "fpga\boards\basys3\basys3.xdc"
    )) {
        $paths.Add($path) | Out-Null
    }
    $records = @(
        foreach ($path in @($paths | Sort-Object -Unique)) {
            "$($path.Replace('\', '/')):$((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant())"
        }
    )
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($records -join "`n"))
        return [System.BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace("-", "").ToLowerInvariant()
    } finally {
        $hasher.Dispose()
    }
}

$verificationIdentity = Get-VerificationSourceIdentity
$catalog = Get-Content -LiteralPath "docs\test_catalog.json" -Raw | ConvertFrom-Json
$catalogSummary = Read-JsonIfPresent "wave\test-catalog-summary.json"
$runTestCount = @($catalog.tests | Where-Object { $_.included_in_full_regression }).Count
$catalogGate = [ordered]@{
    name = "test catalog"
    path = "wave/test-catalog-summary.json"
    status = if (
        $null -ne $catalogSummary -and
        [int]$catalogSummary.total_catalog_entries -eq @($catalog.tests).Count -and
        [int]$catalogSummary.run_ps1_tests -eq $runTestCount -and
        [string]$catalogSummary.verification_input_fingerprint -eq $verificationIdentity.verification_input_fingerprint -and
        [int]$catalogSummary.verification_input_count -eq $verificationIdentity.verification_input_count -and
        $catalogSummary.verification_working_tree_dirty -eq $false
    ) { "pass" } else { "fail" }
    total_catalog_entries = @($catalog.tests).Count
    full_regression_entries = $runTestCount
    source_commit = if ($null -eq $catalogSummary) { $null } else { $catalogSummary.source_commit }
    verification_identity_matches = (
        $null -ne $catalogSummary -and
        [string]$catalogSummary.verification_input_fingerprint -eq $verificationIdentity.verification_input_fingerprint -and
        [int]$catalogSummary.verification_input_count -eq $verificationIdentity.verification_input_count -and
        $catalogSummary.verification_working_tree_dirty -eq $false
    )
    sha256 = if (Test-Path -LiteralPath "wave\test-catalog-summary.json") { (Get-FileHash -LiteralPath "wave\test-catalog-summary.json" -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
}

$regression = Read-JsonIfPresent "wave\regression-summary.json"
$expectedRegressionNames = @(
    $catalog.tests |
        Where-Object { $_.included_in_full_regression } |
        ForEach-Object { $_.name } |
        Sort-Object -Unique
)
$regressionNames = if ($null -eq $regression) {
    @()
} else {
    @($regression.tests | ForEach-Object { $_.name } | Sort-Object -Unique)
}
$regressionNameDifferences = @(
    Compare-Object -ReferenceObject $expectedRegressionNames -DifferenceObject $regressionNames |
        ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }
)
$regressionPass = (
    $null -ne $regression -and
    [int]$regression.total -eq $runTestCount -and
    [int]$regression.passed -eq $runTestCount -and
    [int]$regression.failed -eq 0 -and
    $regressionNameDifferences.Count -eq 0 -and
    @($regression.tests | Where-Object { $_.status -ne "passed" }).Count -eq 0 -and
    [string]$regression.verification_input_fingerprint -eq $verificationIdentity.verification_input_fingerprint -and
    [int]$regression.verification_input_count -eq $verificationIdentity.verification_input_count -and
    $regression.verification_working_tree_dirty -eq $false
)
$regressionGate = [ordered]@{
    name = "full regression"
    path = "wave/regression-summary.json"
    status = if ($regressionPass) { "pass" } else { "fail" }
    expected = $runTestCount
    total = if ($null -eq $regression) { $null } else { $regression.total }
    passed = if ($null -eq $regression) { $null } else { $regression.passed }
    failed = if ($null -eq $regression) { $null } else { $regression.failed }
    test_name_set_matches_catalog = ($regressionNameDifferences.Count -eq 0)
    source_commit = if ($null -eq $regression) { $null } else { $regression.source_commit }
    verification_identity_matches = (
        $null -ne $regression -and
        [string]$regression.verification_input_fingerprint -eq $verificationIdentity.verification_input_fingerprint -and
        [int]$regression.verification_input_count -eq $verificationIdentity.verification_input_count -and
        $regression.verification_working_tree_dirty -eq $false
    )
    name_differences = $regressionNameDifferences
    generated_at_utc = if ($null -eq $regression) { $null } else { $regression.generated_at_utc }
    sha256 = if ($null -eq $regression) { $null } else { (Get-FileHash -LiteralPath "wave\regression-summary.json" -Algorithm SHA256).Hash.ToLowerInvariant() }
}

$requiredGates = @(
    $catalogGate,
    $regressionGate,
    (Get-StatusGate -Name "regression evidence report" -Path "wave\regression-evidence-summary.json" -ExpectedVerificationFingerprint $verificationIdentity.verification_input_fingerprint -ExpectedVerificationInputCount $verificationIdentity.verification_input_count),
    (Get-StatusGate -Name "portable check" -Path "wave\check-summary.json" -ExpectedVerificationFingerprint $verificationIdentity.verification_input_fingerprint -ExpectedVerificationInputCount $verificationIdentity.verification_input_count),
    (Get-StatusGate -Name "Verilator lint" -Path "wave\verilator-lint-summary.json" -ExpectedVerificationFingerprint $verificationIdentity.verification_input_fingerprint -ExpectedVerificationInputCount $verificationIdentity.verification_input_count),
    (Get-StatusGate -Name "Yosys synthesis smoke" -Path "wave\synth-smoke-summary.json" -ExpectedVerificationFingerprint $verificationIdentity.verification_input_fingerprint -ExpectedVerificationInputCount $verificationIdentity.verification_input_count),
    (Get-StatusGate -Name "CPU formal smoke" -Path "wave\formal-smoke-summary.json" -ExpectedVerificationFingerprint $verificationIdentity.verification_input_fingerprint -ExpectedVerificationInputCount $verificationIdentity.verification_input_count),
    (Get-StatusGate -Name "MATVEC Scratchpad formal smoke" -Path "wave\formal-matvec-smoke-summary.json" -ExpectedVerificationFingerprint $verificationIdentity.verification_input_fingerprint -ExpectedVerificationInputCount $verificationIdentity.verification_input_count)
)
$failedGates = @($requiredGates | Where-Object { $_.status -ne "pass" })
if ($verificationIdentity.verification_working_tree_dirty) {
    $failedGates += [ordered]@{
        name = "verification source working tree"
        status = "fail"
    }
}
if ($failedGates.Count -ne 0) {
    throw "Release evidence rejected stale, failed, or dirty-source verification summaries: $(@($failedGates | ForEach-Object { $_.name }) -join ', ')"
}

$sourceFingerprint = Get-BuildFingerprint
$vivado = Read-JsonIfPresent "wave\vivado-basys3-build-summary.json"
$robustness = Read-JsonIfPresent "wave\vivado-basys3-robustness-summary.json"
$postRoute = if ($null -eq $vivado) { $null } else { $vivado.reports.post_route_timing }
$postRouteDrc = if ($null -eq $vivado) { $null } else { $vivado.reports.post_route_drc }
$vivadoCurrent = (
    $null -ne $vivado -and
    $vivado.status -eq "pass" -and
    $vivado.source_fingerprint -eq $sourceFingerprint -and
    $vivado.implementation_status -eq "pass" -and
    $vivado.timing_closure_status -eq "met" -and
    $vivado.timing_constraint_status -eq "pass" -and
    $null -ne $postRoute -and
    $null -ne $postRoute.wns_ns -and [double]$postRoute.wns_ns -ge 0.0 -and
    $null -ne $postRoute.tns_ns -and [double]$postRoute.tns_ns -eq 0.0 -and
    $null -ne $postRoute.whs_ns -and [double]$postRoute.whs_ns -ge 0.0 -and
    $null -ne $postRoute.ths_ns -and [double]$postRoute.ths_ns -eq 0.0 -and
    $null -ne $postRoute.no_clock_count -and [int]$postRoute.no_clock_count -eq 0 -and
    $null -ne $postRoute.unconstrained_internal_endpoint_count -and
        [int]$postRoute.unconstrained_internal_endpoint_count -eq 0 -and
    $null -ne $postRoute.no_input_delay_count -and [int]$postRoute.no_input_delay_count -eq 0 -and
    $null -ne $postRoute.no_output_delay_count -and [int]$postRoute.no_output_delay_count -eq 0 -and
    $vivado.drc_status -eq "pass" -and
    $null -ne $postRouteDrc -and
    $postRouteDrc.present -eq $true -and
    $postRouteDrc.report_parse_complete -eq $true -and
    $postRouteDrc.release_approved -eq $true -and
    [int]$postRouteDrc.error_count -eq 0 -and
    [int]$postRouteDrc.critical_warning_count -eq 0 -and
    [int]$postRouteDrc.unapproved_warning_count -eq 0 -and
    [int]$postRouteDrc.bram_async_control_warning_count -eq 0
)
$evidenceSourceCommit = if ($vivadoCurrent -and
    -not [string]::IsNullOrWhiteSpace([string]$vivado.source_commit)) {
    [string]$vivado.source_commit
} else {
    $null
}
$robustnessRunsCurrent = @(
    if ($null -ne $robustness) {
        $robustness.runs | Where-Object {
            $_.status -ne "pass" -or
            $_.implementation_status -ne "pass" -or
            $_.timing_closure_status -ne "met" -or
            $_.timing_constraint_status -ne "pass" -or
            $null -eq $_.wns_ns -or [double]$_.wns_ns -lt 0.0 -or
            $null -eq $_.tns_ns -or [double]$_.tns_ns -ne 0.0 -or
            $null -eq $_.whs_ns -or [double]$_.whs_ns -lt 0.0 -or
            $null -eq $_.ths_ns -or [double]$_.ths_ns -ne 0.0 -or
            [int]$_.no_clock_count -ne 0 -or
            [int]$_.unconstrained_internal_endpoint_count -ne 0 -or
            [int]$_.no_input_delay_count -ne 0 -or
            [int]$_.no_output_delay_count -ne 0 -or
            $_.drc_status -ne "pass" -or
            [int]$_.drc_error_count -ne 0 -or
            [int]$_.drc_critical_warning_count -ne 0 -or
            [int]$_.drc_unapproved_warning_count -ne 0 -or
            [int]$_.bram_async_control_warning_count -ne 0
        }
    }
)
$robustnessCurrent = (
    $null -ne $robustness -and
    $robustness.status -eq "pass" -and
    $robustness.top -eq "RISCVCPU_basys3_top" -and
    [int]$robustness.run_count -eq 5 -and
    $robustness.all_implementations_passed -eq $true -and
    $robustness.identity_consistent -eq $true -and
    [string]$robustness.source_commit -eq $evidenceSourceCommit -and
    $robustness.working_tree_dirty -eq $false -and
    [string]$robustness.source_fingerprint -eq $sourceFingerprint -and
    [string]$robustness.verification_input_fingerprint -eq
        $verificationIdentity.verification_input_fingerprint -and
    [int]$robustness.verification_input_count -eq
        $verificationIdentity.verification_input_count -and
    $robustness.verification_working_tree_dirty -eq $false -and
    @($robustness.runs).Count -eq 5 -and
    $robustnessRunsCurrent.Count -eq 0
)
if ($null -eq $evidenceSourceCommit -or
    @($requiredGates | Where-Object {
        [string]$_.source_commit -ne $evidenceSourceCommit
    }).Count -ne 0) {
    throw "Release evidence requires every verification gate to identify the canonical Vivado source commit."
}
if (-not $robustnessCurrent) {
    throw "Release evidence requires five source-matched, timing-closed Vivado implementation-strategy results."
}
$bitstreamCurrent = (
    $vivadoCurrent -and
    $vivado.bitstream_status -eq "pass" -and
    -not [string]::IsNullOrWhiteSpace($vivado.bitstream) -and
    (Test-Path -LiteralPath $vivado.bitstream)
)
$physicalEvidence = Get-Basys3PhysicalEvidence -VerifyCaptureSources
if (-not $bitstreamCurrent -or
    $physicalEvidence.source_commit -ne [string]$vivado.source_commit -or
    $physicalEvidence.source_fingerprint -ne $sourceFingerprint -or
    [long]$physicalEvidence.bitstream_size_bytes -ne (Get-Item -LiteralPath $vivado.bitstream).Length -or
    $physicalEvidence.bitstream_sha256 -ne (Get-FileHash -LiteralPath $vivado.bitstream -Algorithm SHA256).Hash.ToLowerInvariant()) {
    throw "Scoped physical evidence does not match the current canonical Vivado/bitstream identity."
}
$vivadoEvidence = [ordered]@{
    path = "wave/vivado-basys3-build-summary.json"
    status = if ($vivadoCurrent) { "current" } elseif ($null -eq $vivado) { "not_run" } else { "stale_or_nonmatching" }
    source_fingerprint = if ($null -eq $vivado) { $null } else { $vivado.source_fingerprint }
    mode = if ($null -eq $vivado) { $null } else { $vivado.mode }
    timing_closure_status = if ($vivadoCurrent) { $vivado.timing_closure_status } else { "not_run" }
    timing_constraint_status = if ($vivadoCurrent) { $vivado.timing_constraint_status } else { "not_run" }
    no_clock_count = if ($vivadoCurrent) { [int]$postRoute.no_clock_count } else { $null }
    unconstrained_internal_endpoint_count = if ($vivadoCurrent) { [int]$postRoute.unconstrained_internal_endpoint_count } else { $null }
    no_input_delay_count = if ($vivadoCurrent) { [int]$postRoute.no_input_delay_count } else { $null }
    no_output_delay_count = if ($vivadoCurrent) { [int]$postRoute.no_output_delay_count } else { $null }
    implementation_strategy = if ($vivadoCurrent) { $vivado.implementation_strategy } else { $null }
    drc_status = if ($vivadoCurrent) { $vivado.drc_status } else { "not_run" }
    drc_error_count = if ($vivadoCurrent) { [int]$postRouteDrc.error_count } else { $null }
    drc_critical_warning_count = if ($vivadoCurrent) { [int]$postRouteDrc.critical_warning_count } else { $null }
    drc_unapproved_warning_count = if ($vivadoCurrent) { [int]$postRouteDrc.unapproved_warning_count } else { $null }
    bram_async_control_warning_count = if ($vivadoCurrent) { [int]$postRouteDrc.bram_async_control_warning_count } else { $null }
    bitstream_status = if ($vivadoCurrent) { $vivado.bitstream_status } else { "not_run" }
    bitstream_build_path = if ($bitstreamCurrent) { $vivado.bitstream.Replace("\", "/") } else { $null }
    bitstream_size_bytes = if ($bitstreamCurrent) { (Get-Item -LiteralPath $vivado.bitstream).Length } else { $null }
    bitstream_sha256 = if ($bitstreamCurrent) { (Get-FileHash -LiteralPath $vivado.bitstream -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
    bitstream_file_tracked = $false
    binary_intentionally_not_packaged = $true
}
$robustnessEvidence = [ordered]@{
    path = "wave/vivado-basys3-robustness-summary.json"
    status = if ($robustnessCurrent) { "current" } elseif ($null -eq $robustness) { "not_run" } else { "stale_or_nonmatching" }
    methodology = if ($null -eq $robustness) { $null } else { $robustness.methodology }
    run_count = if ($robustnessCurrent) { [int]$robustness.run_count } else { $null }
    all_implementations_passed = if ($robustnessCurrent) { $robustness.all_implementations_passed } else { $false }
    worst_wns_ns = if ($robustnessCurrent) { $robustness.worst_wns_ns } else { $null }
    best_wns_ns = if ($robustnessCurrent) { $robustness.best_wns_ns } else { $null }
    minimum_wns_target_ns = if ($robustnessCurrent) { $robustness.minimum_wns_target_ns } else { $null }
    margin_target_status = if ($robustnessCurrent) { $robustness.margin_target_status } else { "not_run" }
    sha256 = if ($robustnessCurrent) {
        (Get-FileHash -LiteralPath "wave\vivado-basys3-robustness-summary.json" -Algorithm SHA256).Hash.ToLowerInvariant()
    } else {
        $null
    }
}
$authoritativeWorkingTreeStatus = @(Get-AuthoritativeWorkingTreeStatus)
$repositoryHead = (& git rev-parse HEAD 2>$null).Trim()
& git cat-file -e "${evidenceSourceCommit}^{commit}" 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Canonical source commit is not present in repository history: $evidenceSourceCommit"
}
& git merge-base --is-ancestor $evidenceSourceCommit $repositoryHead 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Canonical source commit is not an ancestor of the evidence-generation HEAD."
}

$summary = [ordered]@{
    schema_version = 3
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = if ($failedGates.Count -eq 0) { "pass" } else { "fail" }
    source_commit = $evidenceSourceCommit
    repository_head = $repositoryHead
    working_tree_dirty = $authoritativeWorkingTreeStatus.Count -ne 0
    working_tree_scope = "repository_excluding_release"
    source_fingerprint = $sourceFingerprint
    verification_input_fingerprint = $verificationIdentity.verification_input_fingerprint
    verification_input_count = $verificationIdentity.verification_input_count
    verification_working_tree_dirty = $verificationIdentity.verification_working_tree_dirty
    required_gates = $requiredGates
    failed_gates = @($failedGates | ForEach-Object { $_.name })
    regression = $regressionGate
    test_catalog = $catalogGate
    vivado = $vivadoEvidence
    vivado_robustness = $robustnessEvidence
    physical_validation_status = $physicalEvidence.physical_validation_status
    physical_validation_scope = $physicalEvidence.physical_validation_scope
    physical_evidence = [ordered]@{
        summary_path = $physicalEvidence.summary_path
        summary_sha256 = $physicalEvidence.summary_sha256
        programming_evidence_level = $physicalEvidence.programming_evidence_level
        uart_evidence_level = $physicalEvidence.uart_evidence_level
        led_reset_evidence_level = $physicalEvidence.led_reset_evidence_level
        cases = $physicalEvidence.cases
    }
    claim_boundary = "Current portable, bounded-tool, source-matched Vivado, and scoped Basys3 physical evidence index. XSDB programming/configured state and UART transcripts are machine-captured; LED/reset observations are operator-reported; no on-board bitstream readback/hash verification is claimed."
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "wave\release-evidence-summary.json" -Encoding Ascii

Write-Host "========================================"
Write-Host "Release evidence index"
Write-Host ("Status: {0}" -f $summary.status)
Write-Host ("Regression: {0}/{1}" -f $regressionGate.passed, $regressionGate.expected)
Write-Host ("Vivado evidence: {0}" -f $vivadoEvidence.status)
Write-Host ("Physical validation: {0} ({1})" -f $physicalEvidence.physical_validation_status, $physicalEvidence.physical_validation_scope)
Write-Host "Summary: wave\release-evidence-summary.json"

if ($summary.status -ne "pass") {
    throw "Release evidence is incomplete: $($summary.failed_gates -join ', ')"
}
