# Collect current portable verification gates and list optional evidence separately.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/release-package.ps1"
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $root
$output = 'results/release-evidence-summary.json'
$summary = [ordered]@{ status='running'; generated_at_utc=(Get-Date).ToUniversalTime().ToString('o'); gates=@(); omitted=@(); error_message=$null }
Write-ResultJson $summary $output
try {
    $identity = Add-VerificationIdentityFields $summary
    if ($identity.verification_working_tree_dirty) { throw 'Commit verification inputs before collecting release evidence' }
    $required = @('check-summary.json', 'regression-summary.json', 'test-catalog-summary.json', 'regression-evidence-summary.json')
    $optional = @('verilator-lint-summary.json', 'synth-smoke-summary.json', 'formal-smoke-summary.json', 'formal-matvec-smoke-summary.json', 'arch-test-results.json', 'arch-test/sail/summary.json')
    $records = @{}
    foreach ($name in $required + $optional) {
        $path = "results/$name"
        $record = if (Test-Path -LiteralPath $path) { Read-ReleaseJson $path } else { $null }
        if (-not (Test-ReleaseGateIdentity $record $identity)) {
            if ($required -contains $name) { throw "Missing, stale, or uncommitted evidence: $path" }
            $summary.omitted += [ordered]@{ path=$path; reason=if ($null -eq $record) { 'not_run' } else { 'different_inputs' } }
            continue
        }
        if ($name -ne 'test-catalog-summary.json' -and $record.status -notin @('pass', 'passed')) { throw "Current evidence failed: $path" }
        $records[$name] = $record
        $summary.gates += [ordered]@{ path=$path; required=($required -contains $name); status='pass' }
    }
    Assert-PortableCoverage $records['check-summary.json'] $records['regression-summary.json'] `
        (Read-TestCatalog 'docs/test_catalog.json') $records['test-catalog-summary.json'] $records['regression-evidence-summary.json']
    $summary.status = 'pass'
} catch {
    $summary.status = 'fail'
    $summary.error_message = $_.Exception.Message
    throw
} finally { Write-ResultJson $summary $output }
Write-Host "PASS: $($summary.gates.Count) current evidence groups; $($summary.omitted.Count) optional groups omitted."
