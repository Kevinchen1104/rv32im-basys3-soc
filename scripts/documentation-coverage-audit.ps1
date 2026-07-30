<#
Script: scripts\documentation-coverage-audit.ps1
Purpose: Runs consolidated source documentation header coverage checks.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\documentation-coverage-audit.ps1
Outputs:
  wave\documentation-coverage-summary.json and console pass/fail summary.
Scope:
  Documentation coverage/readability evidence only; not hardware correctness,
  timing closure, physical board validation, official RISC-V compliance, or
  benchmark proof.
Audience:
  Public maintenance and release audit check used by scripts\check.ps1.
#>
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. "$PSScriptRoot\verification-source-identity.ps1"

New-Item -ItemType Directory -Force -Path "wave" | Out-Null

$auditPlan = @(
    [ordered]@{ name = "rtl_comment_audit"; script = "scripts\comment-audit.ps1" },
    [ordered]@{ name = "testbench_comment_audit"; script = "scripts\testbench-comment-audit.ps1" },
    [ordered]@{ name = "firmware_comment_audit"; script = "scripts\firmware-comment-audit.ps1" },
    [ordered]@{ name = "script_comment_audit"; script = "scripts\script-comment-audit.ps1" }
)

$auditsRun = [System.Collections.Generic.List[string]]::new()
$failedAudits = [System.Collections.Generic.List[string]]::new()
$auditResults = [System.Collections.Generic.List[object]]::new()

foreach ($audit in $auditPlan) {
    $scriptPath = Join-Path $repoRoot $audit.script
    $auditsRun.Add($audit.name) | Out-Null
    Write-Host "========================================"
    Write-Host ("Running documentation coverage audit: {0}" -f $audit.name)

    $status = "pass"
    $exitCode = 0
    $errorMessage = ""

    if (-not (Test-Path -LiteralPath $scriptPath)) {
        $status = "fail"
        $exitCode = $null
        $errorMessage = "missing script: $($audit.script)"
    } else {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $status = "fail"
            $errorMessage = "exit code $exitCode"
        }
    }

    if ($status -ne "pass") {
        $failedAudits.Add($audit.name) | Out-Null
    }

    $auditResults.Add([ordered]@{
        name = $audit.name
        script = $audit.script
        status = $status
        exit_code = $exitCode
        error_message = $errorMessage
    }) | Out-Null
}

$rtlFiles = @(Get-ChildItem -Path "rtl" -Recurse -Filter "*.v" | Sort-Object FullName)
$testbenchFiles = @(Get-ChildItem -Path "tb" -Recurse -Filter "*.v" | Sort-Object FullName)
$firmwareFiles = @(Get-ChildItem -Path "firmware/src" -Recurse -Filter "*.S" | Sort-Object FullName)
$scriptFiles = @(Get-ChildItem -Path "scripts" -Recurse -Filter "*.ps1" | Sort-Object FullName)

$status = if ($failedAudits.Count -eq 0) { "pass" } else { "fail" }

$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = $status
    rtl_files_checked = $rtlFiles.Count
    testbench_files_checked = $testbenchFiles.Count
    firmware_files_checked = $firmwareFiles.Count
    script_files_checked = $scriptFiles.Count
    audits_run = $auditsRun.ToArray()
    failed_audits = $failedAudits.ToArray()
    audit_results = $auditResults.ToArray()
    note = "Documentation coverage/readability evidence only; not hardware correctness, timing closure, physical board validation, official RISC-V compliance, or benchmark proof."
}
Add-DocumentationIdentityFields -Summary $summary | Out-Null

$summary | ConvertTo-Json -Depth 5 | Set-Content -Path "wave\documentation-coverage-summary.json" -Encoding Ascii

Write-Host "========================================"
Write-Host "Documentation coverage audit"
Write-Host ("Status: {0}" -f $summary.status)
Write-Host ("RTL files checked: {0}" -f $summary.rtl_files_checked)
Write-Host ("Testbench files checked: {0}" -f $summary.testbench_files_checked)
Write-Host ("Firmware files checked: {0}" -f $summary.firmware_files_checked)
Write-Host ("Script files checked: {0}" -f $summary.script_files_checked)
Write-Host "Summary written to wave\documentation-coverage-summary.json"

if ($summary.status -ne "pass") {
    throw "Documentation coverage audit failed; inspect wave\documentation-coverage-summary.json"
}
