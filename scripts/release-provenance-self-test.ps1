<#
Script: scripts\release-provenance-self-test.ps1
Purpose: Checks source-bound and repository-bound release gate ordering.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\release-provenance-self-test.ps1
Outputs:
  Console pass/fail result only.
Scope:
  Static release-flow contract check; does not generate packages or run hardware.
Audience:
  Release maintainers and the portable project check.
#>
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$freezeText = Get-Content -LiteralPath "scripts\release-freeze.ps1" -Raw
$fpgaPackageIndex = $freezeText.IndexOf("scripts\fpga-release.ps1")
$finalDocsIndex =
    $freezeText.IndexOf('(Join-Path $finalRoot "limitations.md")')
$documentationGateIndex =
    $freezeText.IndexOf("scripts\documentation-coverage-audit.ps1")
$artifactManifestIndex = $freezeText.IndexOf('$artifactManifest = @(')

if ($fpgaPackageIndex -lt 0 -or
    $finalDocsIndex -lt 0 -or
    $documentationGateIndex -lt 0 -or
    $artifactManifestIndex -lt 0 -or
    -not (
        $fpgaPackageIndex -lt $finalDocsIndex -and
        $finalDocsIndex -lt $documentationGateIndex -and
        $documentationGateIndex -lt $artifactManifestIndex
    )) {
    throw "Documentation gates must run after package content generation and before the final artifact manifest."
}

$releaseEvidenceText =
    Get-Content -LiteralPath "scripts\release-evidence.ps1" -Raw
if ($releaseEvidenceText -match
    'scripts\\(?:documentation-coverage-audit|docs-link-audit|claim-audit)\.ps1') {
    throw "release-evidence.ps1 must not rerun repository-bound documentation gates."
}

$finalAuditText = Get-Content -LiteralPath "scripts\final-audit.ps1" -Raw
if ($finalAuditText -match
    '& powershell[^\r\n]+(?:documentation-coverage-audit|docs-link-audit|claim-audit)') {
    throw "final-audit.ps1 must validate fixed documentation summaries without rerunning them."
}

Write-Host "PASS: release provenance domains and package/audit ordering are separated"
