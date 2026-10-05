<#
Purpose: Locate result/claim wording for human review; findings are advisory.
Usage: powershell -File scripts/claim-audit.ps1
Output: results/claim-audit-summary.json
#>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/result-format.ps1"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $repoRoot
. "$PSScriptRoot/verification-source-identity.ps1"
New-Item -ItemType Directory -Force -Path 'results' | Out-Null

# Both positive and negative statements are shown. Context and supporting
# evidence are reviewed by a person rather than inferred from nearby negation.
$pattern = '(?i)\b(full compliance|official.{0,16}compliance|fully coherent|cache coherent|production.ready|speedup|benchmark|timing closure)\b'
$paths = @('README.md', 'scripts/README.md', 'formal/README.md')
$paths += @(Get-ChildItem -LiteralPath 'docs' -Recurse -File -Filter '*.md' |
    Where-Object { $_.FullName -notmatch '[\\/]board_evidence[\\/]' } |
    ForEach-Object { $_.FullName })
$paths += @(Get-ChildItem -LiteralPath 'fpga/boards' -Recurse -File -Filter '*.md' |
    ForEach-Object { $_.FullName })
$findings = @(
    foreach ($path in $paths | Sort-Object -Unique) {
        $file = Get-Item -LiteralPath $path
        $lines = @(Get-Content -LiteralPath $file.FullName)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match $pattern) {
                [pscustomobject]@{
                    file = $file.FullName.Substring($repoRoot.Length + 1).Replace('\', '/')
                    line = $i + 1
                    text = $lines[$i].Trim()
                }
            }
        }
    }
)
$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    status = 'completed'
    mode = 'advisory'
    scanned_files = $paths.Count
    findings_count = $findings.Count
    findings = $findings
    checklist = 'docs/documentation-review.md'
    note = 'Matches are review prompts, not errors or approved claims. Historical board records and release snapshots are left unchanged.'
}
Add-DocumentationIdentityFields -Summary $summary | Out-Null
Write-ResultJson $summary 'results/claim-audit-summary.json'
Write-Host "ADVISORY: $($findings.Count) statements to review in $($paths.Count) documents."
Write-Host 'See results/claim-audit-summary.json and docs/documentation-review.md.'
