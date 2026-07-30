<#
Script: scripts\check.ps1
Purpose: Runs the main portable project regression gate.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\check.ps1
Outputs:
  wave\check-summary.json plus regression, reference, and helper artifacts under wave\.
Scope:
  Portable simulation/static/reference evidence only; not timing closure, physical board validation, official RISC-V compliance, or benchmark proof.
Audience:
  Public entrypoint.
#>
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. "$PSScriptRoot\verification-source-identity.ps1"

New-Item -ItemType Directory -Force -Path "wave" | Out-Null

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$checkSummary = [ordered]@{
    status = "running"
    failed_step = ""
    error_message = ""
    assembler_checks = $false
    static_rtl_check = $false
    vivado_drc_parser_self_test = $false
    verification_source_identity_self_test = $false
    release_provenance_self_test = $false
    rtl_comment_audit = $false
    testbench_comment_audit = $false
    firmware_comment_audit = $false
    script_comment_audit = $false
    documentation_coverage_audit = $false
    test_catalog_check = $false
    random_memory_reference_check = $false
    random_control_reference_check = $false
    random_hazard_reference_check = $false
    random_call_reference_check = $false
    generated_reference_seed_smoke_check = $false
    uart_boot_packet_check = $false
    showcase_boot_packet_check = $false
    interactive_boot_packet_check = $false
    hardware_validation_boot_packet_check = $false
    trace_trap_reference_check = $false
    trace_lockstep_reference_check = $false
    trace_lockstep_seed_smoke_check = $false
    perf_counter_snapshot_check = $false
    regression = $false
    regression_evidence_report = $false
    fpga_smoke = $false
    ci_gate_scope = "portable PowerShell/Icarus gate; local release gates are run separately"
    local_release_gates_run_separately = @(
        "scripts\project-doctor.ps1",
        "scripts\demo-smoke.ps1",
        "scripts\showcase-demo.ps1",
        "scripts\interactive-showcase-demo.ps1",
        "scripts\claim-audit.ps1",
        "scripts\docs-link-audit.ps1",
        "scripts\final-audit.ps1",
        "scripts\verilator-lint.ps1",
        "scripts\synth-smoke.ps1",
        "scripts\fpga-tool-detect.ps1",
        "scripts\fpga-release.ps1",
        "scripts\vivado-detect.ps1",
        "scripts\vivado-basys3-build.ps1 -SynthOnly",
        "scripts\fpga-release.ps1 -BoardProfile basys3",
        "scripts\formal-smoke.ps1",
        "scripts\formal-matvec-smoke.ps1",
        "scripts\release-evidence.ps1",
        "scripts\release-freeze.ps1"
    )
    started_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    finished_at_utc = $null
    duration_ms = 0
}

$currentStep = ""
$caughtError = $null

function Write-CheckSummary {
    $checkSummary.finished_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    $checkSummary.duration_ms = $stopwatch.ElapsedMilliseconds
    Add-VerificationIdentityFields -Summary $checkSummary | Out-Null
    $checkSummary | ConvertTo-Json -Depth 3 | Set-Content -Path "wave\check-summary.json" -Encoding Ascii
    Write-Host "Check summary written to wave\check-summary.json"
}

try {
    Write-Host "========================================"
    Write-Host "Running assembler focused tests"
    $currentStep = "assembler focused tests"
    & (Join-Path $PSScriptRoot "assembler-tests.ps1")

    Write-Host "========================================"
    Write-Host "Checking assembled program images"
    $currentStep = "assembled program images"
    & (Join-Path $PSScriptRoot "assemble.ps1") -Check
    $checkSummary.assembler_checks = $true

    Write-Host "========================================"
    Write-Host "Checking static RTL hygiene"
    $currentStep = "static RTL hygiene"
    & (Join-Path $PSScriptRoot "static-rtl-check.ps1")
    $checkSummary.static_rtl_check = $true

    Write-Host "========================================"
    Write-Host "Checking Vivado DRC parser fail-closed policy"
    $currentStep = "Vivado DRC parser self-test"
    & (Join-Path $PSScriptRoot "vivado-drc-parser-self-test.ps1")
    $checkSummary.vivado_drc_parser_self_test = $true

    Write-Host "========================================"
    Write-Host "Checking verification source identity hashing policy"
    $currentStep = "verification source identity self-test"
    & (Join-Path $PSScriptRoot "verification-source-identity-self-test.ps1")
    $checkSummary.verification_source_identity_self_test = $true

    Write-Host "========================================"
    Write-Host "Checking release provenance domain ordering"
    $currentStep = "release provenance self-test"
    & (Join-Path $PSScriptRoot "release-provenance-self-test.ps1")
    $checkSummary.release_provenance_self_test = $true

    Write-Host "========================================"
    Write-Host "Checking documentation coverage headers"
    $currentStep = "documentation coverage headers"
    & (Join-Path $PSScriptRoot "documentation-coverage-audit.ps1")
    $checkSummary.rtl_comment_audit = $true
    $checkSummary.testbench_comment_audit = $true
    $checkSummary.firmware_comment_audit = $true
    $checkSummary.script_comment_audit = $true
    $checkSummary.documentation_coverage_audit = $true

    Write-Host "========================================"
    Write-Host "Checking test coverage catalog"
    $currentStep = "test coverage catalog"
    & (Join-Path $PSScriptRoot "check-test-catalog.ps1")
    $checkSummary.test_catalog_check = $true

    Write-Host "========================================"
    Write-Host "Checking randomized reference program"
    $currentStep = "randomized reference program"
    & (Join-Path $PSScriptRoot "random-reference.ps1") -Check -SkipSimulation

    Write-Host "========================================"
    Write-Host "Checking randomized memory reference program"
    $currentStep = "randomized memory reference program"
    & (Join-Path $PSScriptRoot "random-memory-reference.ps1") -Check -SkipSimulation
    $checkSummary.random_memory_reference_check = $true

    Write-Host "========================================"
    Write-Host "Checking randomized control reference program"
    $currentStep = "randomized control reference program"
    & (Join-Path $PSScriptRoot "random-control-reference.ps1") -Check -SkipSimulation
    $checkSummary.random_control_reference_check = $true

    Write-Host "========================================"
    Write-Host "Checking randomized hazard reference program"
    $currentStep = "randomized hazard reference program"
    & (Join-Path $PSScriptRoot "random-hazard-reference.ps1") -Check -SkipSimulation
    $checkSummary.random_hazard_reference_check = $true

    Write-Host "========================================"
    Write-Host "Checking randomized call reference program"
    $currentStep = "randomized call reference program"
    & (Join-Path $PSScriptRoot "random-call-reference.ps1") -Check -SkipSimulation
    $checkSummary.random_call_reference_check = $true

    Write-Host "========================================"
    Write-Host "Checking generated reference multi-seed smoke"
    $currentStep = "generated reference multi-seed smoke"
    & (Join-Path $PSScriptRoot "generated-reference-seed-smoke.ps1")
    $checkSummary.generated_reference_seed_smoke_check = $true

    Write-Host "========================================"
    Write-Host "Checking UART boot packet fixture"
    $currentStep = "UART boot packet fixture"
    & (Join-Path $PSScriptRoot "uart-boot-packet.ps1") -Hex "firmware\hex\showcase\board_smoke.hex" -DryRun -Check
    $checkSummary.uart_boot_packet_check = $true

    Write-Host "========================================"
    Write-Host "Checking showcase UART boot packet fixture"
    $currentStep = "showcase UART boot packet fixture"
    & (Join-Path $PSScriptRoot "uart-boot-packet.ps1") -Hex "firmware\hex\showcase\showcase_demo.hex" -DryRun -Check
    $checkSummary.showcase_boot_packet_check = $true

    Write-Host "========================================"
    Write-Host "Checking interactive showcase UART boot packet fixture"
    $currentStep = "interactive showcase UART boot packet fixture"
    & (Join-Path $PSScriptRoot "uart-boot-packet.ps1") -Hex "firmware\hex\showcase\interactive_showcase_demo.hex" -DryRun -Check
    $checkSummary.interactive_boot_packet_check = $true

    Write-Host "========================================"
    Write-Host "Checking hardware validation UART boot packet fixture"
    $currentStep = "hardware validation UART boot packet fixture"
    & (Join-Path $PSScriptRoot "uart-boot-packet.ps1") -Hex "firmware\hex\showcase\hardware_validation_suite.hex" -DryRun -Check
    $checkSummary.hardware_validation_boot_packet_check = $true

    Write-Host "========================================"
    Write-Host "Checking trace reference program"
    $currentStep = "trace reference program"
    & (Join-Path $PSScriptRoot "trace-reference.ps1") -Check -SkipSimulation

    Write-Host "========================================"
    Write-Host "Checking trace trap reference program"
    $currentStep = "trace trap reference program"
    & (Join-Path $PSScriptRoot "trace-trap-reference.ps1") -Check -SkipSimulation
    $checkSummary.trace_trap_reference_check = $true

    Write-Host "========================================"
    Write-Host "Checking trace lockstep reference program"
    $currentStep = "trace lockstep reference program"
    & (Join-Path $PSScriptRoot "trace-lockstep-reference.ps1") -Check -SkipSimulation
    $checkSummary.trace_lockstep_reference_check = $true

    Write-Host "========================================"
    Write-Host "Checking trace lockstep multi-seed smoke"
    $currentStep = "trace lockstep multi-seed smoke"
    & (Join-Path $PSScriptRoot "trace-lockstep-seed-smoke.ps1")
    $checkSummary.trace_lockstep_seed_smoke_check = $true

    Write-Host "========================================"
    Write-Host "Checking performance counter CSV helper"
    $currentStep = "performance counter CSV helper"
    & (Join-Path $PSScriptRoot "perf-counter-csv.ps1") -OutputPath "wave\perf-counter-comparison.csv"

    Write-Host "========================================"
    Write-Host "Checking performance counter JSON helper"
    $currentStep = "performance counter JSON helper"
    & (Join-Path $PSScriptRoot "perf-counter-json.ps1") -OutputPath "wave\perf-counter-comparison.json"

    Write-Host "========================================"
    Write-Host "Checking performance counter comparison helper"
    $currentStep = "performance counter comparison helper"
    & (Join-Path $PSScriptRoot "perf-counter-compare.ps1") `
        -BaselinePath "wave\perf-counter-comparison.json" `
        -CurrentPath "wave\perf-counter-comparison.json" `
        -FailOnDifference

    Write-Host "========================================"
    Write-Host "Checking performance counter snapshot freshness"
    $currentStep = "performance counter snapshot freshness"
    & (Join-Path $PSScriptRoot "check-perf-counter-snapshots.ps1") -SkipAssemble
    $checkSummary.perf_counter_snapshot_check = $true

    Write-Host "========================================"
    Write-Host "Checking performance counter threshold fixtures"
    $currentStep = "performance counter threshold fixtures"
    & (Join-Path $PSScriptRoot "perf-counter-threshold-tests.ps1")

    Write-Host "========================================"
    Write-Host "Running full CPU regression"
    $currentStep = "full CPU regression"
    & (Join-Path $PSScriptRoot "run.ps1") -SummaryJson "wave\regression-summary.json"
    $checkSummary.regression = $true

    Write-Host "========================================"
    Write-Host "Checking regression evidence report"
    $currentStep = "regression evidence report"
    & (Join-Path $PSScriptRoot "regression-evidence-report.ps1")
    $checkSummary.regression_evidence_report = $true

    Write-Host "========================================"
    Write-Host "Checking FPGA top elaboration"
    $currentStep = "FPGA top elaboration"
    & (Join-Path $PSScriptRoot "fpga-smoke.ps1")
    $checkSummary.fpga_smoke = $true

    $checkSummary.status = "pass"
} catch {
    $caughtError = $_
    $checkSummary.status = "fail"
    $checkSummary.failed_step = $currentStep
    $checkSummary.error_message = $_.Exception.Message
    Write-Host "FAIL: project check failed during $currentStep"
    Write-Host $_.Exception.Message
} finally {
    $stopwatch.Stop()
    Write-CheckSummary
}

if ($null -ne $caughtError) {
    throw $caughtError
}

Write-Host "========================================"
Write-Host "PASS: project check completed"
