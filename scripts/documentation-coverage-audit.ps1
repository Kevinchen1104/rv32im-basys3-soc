<#
Purpose: Summarize advisory comment coverage across source files.
Usage: powershell -File scripts/documentation-coverage-audit.ps1
Output: results/documentation-coverage-summary.json
#>
param([ValidateSet('all', 'rtl', 'testbench', 'firmware', 'script')][string]$Kind = 'all')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/result-format.ps1"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $repoRoot
. "$PSScriptRoot/documentation-review.ps1"
. "$PSScriptRoot/verification-source-identity.ps1"
New-Item -ItemType Directory -Force -Path 'results' | Out-Null

$coverage = @(
    foreach ($category in @('rtl', 'testbench', 'firmware', 'script')) {
        if ($Kind -ne 'all' -and $Kind -ne $category) { continue }
        $item = Get-DocumentationCoverage -Root $repoRoot -Kind $category
        Write-DocumentationCoverage $item
        $item
    }
)
$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    status = 'completed'
    mode = 'advisory'
    selection = $Kind
    files_checked = ($coverage | Measure-Object -Property files_checked -Sum).Sum
    findings_count = @($coverage | ForEach-Object { $_.findings }).Count
    coverage = $coverage
    note = 'Checks for an introductory comment within the first 40 lines. Review clarity manually; no header fields or disclaimer phrases are required.'
}
Add-DocumentationIdentityFields -Summary $summary | Out-Null
Write-ResultJson $summary 'results/documentation-coverage-summary.json'
Write-Host 'Documentation scan completed. See results/documentation-coverage-summary.json.'
