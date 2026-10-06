# Publish a portable verification snapshot after validating the staged package.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/release-package.ps1"
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $root
& "$PSScriptRoot/release-evidence.ps1"
$evidence = Read-ReleaseJson 'results/release-evidence-summary.json'
$identity = Get-VerificationSourceIdentity -IncludeRecords
$stage = New-ReleaseStage $root
try {
    $gates = @(foreach ($gate in $evidence.gates) {
        $relative = 'evidence/' + $gate.path.Substring('results/'.Length)
        Copy-ReleaseText $gate.path (Join-Path $stage $relative) $root
        [ordered]@{ path=$relative; required=$gate.required }
    })
    Copy-ReleaseText 'docs/test_catalog.json' (Join-Path $stage 'test_catalog.json') $root
    $source = [ordered]@{ hash_mode='verification'; fingerprint=$identity.verification_input_fingerprint; inputs=$identity.inputs }
    Write-ResultJson $source (Join-Path $stage 'source-inputs.json')
    $package = [ordered]@{
        schema_version=1; kind='portable'; status='pass'; generated_at_utc=(Get-Date).ToUniversalTime().ToString('o')
        source_commit=$identity.source_commit; source_fingerprint=$source.fingerprint; input_count=$identity.verification_input_count
        gates=$gates; omitted_optional=$evidence.omitted
    }
    Write-ResultJson $package (Join-Path $stage 'package.json')
    @('# Portable verification snapshot', '',
        "Source revision: ``$($identity.source_commit)``.", '',
        "Full workflow: $((Read-ReleaseJson 'results/check-summary.json').planned_steps) stages; RTL regression: $((Read-ReleaseJson 'results/regression-summary.json').passed) tests.", '',
        'Read `package.json` for included gates and omitted optional tools; `evidence/` contains their recorded summaries.', '',
        '`source-inputs.json` identifies the tested input files. `artifacts.json` checks every packaged file by size and SHA-256.', '',
        'Verify integrity with `powershell -File scripts/final-audit.ps1 -PackagedEvidence` from the repository root.',
        'Add `-Scope portable -RequireCurrent` to check this portable snapshot against the current checkout.') |
        Set-Content -LiteralPath (Join-Path $stage 'README.md') -Encoding UTF8
    Write-ReleaseManifest $stage
    Publish-ReleasePackage $stage 'release/current' $root
} catch { Write-Host "Package not published; diagnostic staging directory: $stage"; throw }
Write-Host 'Published: release/current (portable verification)'
