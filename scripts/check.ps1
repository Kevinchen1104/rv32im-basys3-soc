<#
Script: scripts/check.ps1
Purpose: Runs either the everyday Quick checks or the complete portable Full gate.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts/check.ps1 -Mode Quick
  powershell -ExecutionPolicy Bypass -File scripts/check.ps1 -Mode Full
Outputs:
  Mode-specific JSON and Markdown summaries, a regression CSV, and step logs under results/.
Scope:
  Portable checks; FPGA implementation and release packaging are separate workflows.
#>
param([ValidateSet('Quick', 'Full')][string]$Mode = 'Full')

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $repoRoot
. "$PSScriptRoot/verification-source-identity.ps1"
. "$PSScriptRoot/process-runner.ps1"
. "$PSScriptRoot/check-report.ps1"

# A step declares its script, arguments, completed flags, and deadline.
function Step {
    param([string]$Name, [string[]]$Arguments = @(), [string[]]$Flags = @(), [int]$Timeout = 300, [string]$Label = '')
    if (-not $Label) { $Label = $Name }
    [pscustomobject]@{ name = $Name; label = $Label; arguments = $Arguments; flags = $Flags; timeout = $Timeout }
}
$fullSteps = @(
    Step 'runner-self-test' @() @('runner_self_test')
    Step 'workflow-self-test'
    Step 'result-integrity-self-test'
    Step 'result-format-self-test'
    Step 'verification-edge-tests'
    Step 'assembler-tests'
    Step 'assemble' @('-Check') @('assembler_checks')
    Step 'static-rtl-check' @() @('static_rtl_check')
    Step 'vivado-drc-parser-self-test' @() @('vivado_drc_parser_self_test')
    Step 'verification-source-identity-self-test' @() @('verification_source_identity_self_test')
    Step 'release-provenance-self-test' @() @('release_provenance_self_test')
    Step 'check-test-catalog' @() @('test_catalog_check')
    Step 'random-reference' @('-Check', '-SkipSimulation')
    Step 'random-memory-reference' @('-Check', '-SkipSimulation') @('random_memory_reference_check')
    Step 'random-control-reference' @('-Check', '-SkipSimulation') @('random_control_reference_check')
    Step 'random-hazard-reference' @('-Check', '-SkipSimulation') @('random_hazard_reference_check')
    Step 'random-call-reference' @('-Check', '-SkipSimulation') @('random_call_reference_check')
    Step 'generated-reference-seed-smoke' @() @('generated_reference_seed_smoke_check') 900
    Step 'uart-boot-packet' @('-Hex', 'firmware/hex/showcase/board_smoke.hex', '-DryRun', '-Check') @('uart_boot_packet_check') -Label 'UART boot: board smoke'
    Step 'uart-boot-packet' @('-Hex', 'firmware/hex/showcase/showcase_demo.hex', '-DryRun', '-Check') @('showcase_boot_packet_check') -Label 'UART boot: showcase'
    Step 'uart-boot-packet' @('-Hex', 'firmware/hex/showcase/interactive_showcase_demo.hex', '-DryRun', '-Check') @('interactive_boot_packet_check') -Label 'UART boot: interactive showcase'
    Step 'uart-boot-packet' @('-Hex', 'firmware/hex/showcase/hardware_validation_suite.hex', '-DryRun', '-Check') @('hardware_validation_boot_packet_check') -Label 'UART boot: hardware validation'
    Step 'trace-reference' @('-Check', '-SkipSimulation')
    Step 'trace-trap-reference' @('-Check', '-SkipSimulation') @('trace_trap_reference_check')
    Step 'trace-lockstep-reference' @('-Check', '-SkipSimulation') @('trace_lockstep_reference_check')
    Step 'trace-lockstep-seed-smoke' @() @('trace_lockstep_seed_smoke_check') 900
    Step 'perf-counter-export' @('-SkipAssemble') @('perf_counter_snapshot_check')
    Step 'perf-counter-threshold-tests'
    Step 'run' @('-Test', 'all', '-SummaryJson', 'results/regression-summary.json') @('regression') 1800
    Step 'regression-evidence-report' @() @('regression_evidence_report')
    Step 'fpga-smoke' @() @('fpga_smoke')
)
$steps = if ($Mode -eq 'Quick') {
    @(
        Step 'assemble' @('-Check') @('assembler_checks')
        Step 'static-rtl-check' @() @('static_rtl_check')
        Step 'check-test-catalog' @() @('test_catalog_check')
        Step 'run' @('-Test', 'quick', '-SkipAssemble', '-SummaryJson', 'results/quick-regression-summary.json') @('regression')
    )
} else { $fullSteps }

$prefix = if ($Mode -eq 'Quick') { 'quick-' } else { '' }
$summaryPath = "results/${prefix}check-summary.json"
$regressionPath = "results/${prefix}regression-summary.json"
$clock = [System.Diagnostics.Stopwatch]::StartNew()
$summary = [ordered]@{
    status = 'running'; mode = $Mode; failed_step = ''; error_message = ''
    started_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    finished_at_utc = $null; duration_ms = 0
    planned_steps = $steps.Count; steps = @()
}
foreach ($flag in @($fullSteps | ForEach-Object { $_.flags } | Select-Object -Unique)) {
    $summary[$flag] = $false
}
New-Item -ItemType Directory -Force -Path 'results' | Out-Null
function Save-Summary {
    $summary.duration_ms = $clock.ElapsedMilliseconds
    Write-ResultJson $summary $summaryPath
    Write-CheckReport -Summary $summary -ResultsDirectory (Join-Path $repoRoot 'results') -RegressionPath $regressionPath
}

# Replace this mode's previous report before any subprocess starts.
New-Item -ItemType Directory -Force -Path 'build' | Out-Null
$workflowLock = [IO.File]::Open((Join-Path $repoRoot 'build/check.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
Save-Summary
if ($Mode -eq 'Full') { & "$PSScriptRoot/results-overview.ps1" }
$caughtError = $null
$currentStep = 'source identity'
try {
    $startingIdentity = Add-VerificationIdentityFields -Summary $summary
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $step = $steps[$i]
        $currentStep = $step.name
        Write-Host "[$($i + 1)/$($steps.Count)] $Mode - $currentStep $($step.arguments -join ' ')"
        $log = 'results/logs/check/{0}/{1:D2}-{2}.log' -f $Mode.ToLowerInvariant(), ($i + 1), $currentStep
        # Reference fixtures and provenance use the documented Windows PowerShell 5.1 flow.
        $result = Invoke-LoggedProcess -FilePath 'powershell' `
            -Arguments (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$PSScriptRoot/$currentStep.ps1") + $step.arguments) `
            -LogPath $log -WorkingDirectory $repoRoot -TimeoutSeconds $step.timeout -Quiet
        $summary.steps += [pscustomobject]@{
            name = $currentStep; label = $step.label; arguments = $step.arguments; status = $result.status
            exit_code = $result.exit_code; duration_ms = $result.duration_ms; log = $result.log
        }
        if ($result.status -ne 'passed') {
            throw "$currentStep $($result.status). See $log. $($result.error_message)"
        }
        foreach ($flag in $step.flags) { $summary[$flag] = $true }
        Save-Summary
    }
    $summary.status = 'pass'
} catch {
    $caughtError = $_
    $summary.status = 'fail'
    $summary.failed_step = $currentStep
    $summary.error_message = $_.Exception.Message
} finally {
    $clock.Stop()
    $summary.finished_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    try {
        if ($startingIdentity) { Assert-VerificationInputsUnchanged $startingIdentity }
    } catch {
        if ($null -eq $caughtError) { $caughtError = $_ }
        $summary.status = 'fail'
        $summary.failed_step = 'source identity'
        $summary.error_message = $_.Exception.Message
    }
    try {
        Save-Summary
        if ($Mode -eq 'Full') { & "$PSScriptRoot/results-overview.ps1" }
    } finally { $workflowLock.Dispose() }
}
if ($null -ne $caughtError) { throw $caughtError }
Write-Host "PASS: $Mode check completed. Read results/$($prefix)RESULTS.md"
