<#
Script: scripts/script-comment-audit.ps1
Purpose: Checks PowerShell scripts for command-purpose header fields.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\script-comment-audit.ps1
Outputs:
  Console report listing any scripts missing required header fields.
Scope:
  Documentation consistency check only; not hardware evidence, timing closure,
  physical board validation, official RISC-V compliance, or benchmark proof.
Audience:
  Public maintenance check used by scripts\check.ps1.
#>

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$scriptFiles = @(Get-ChildItem -Path "scripts" -Recurse -Filter "*.ps1" | Sort-Object FullName)
if ($scriptFiles.Count -eq 0) {
    throw "No PowerShell scripts found under scripts"
}

$requiredFields = @(
    "Script",
    "Purpose",
    "Common usage",
    "Outputs",
    "Scope",
    "Audience"
)

$missing = @()
foreach ($file in $scriptFiles) {
    $text = Get-Content -Raw -LiteralPath $file.FullName
    $missingFields = @()

    foreach ($field in $requiredFields) {
        $escapedField = [regex]::Escape($field)
        if ($text -notmatch "(?m)^\s*$escapedField`:") {
            $missingFields += $field
        }
    }

    if ($missingFields.Count -gt 0) {
        $relativePath = Resolve-Path -Relative $file.FullName
        $missing += [pscustomobject]@{
            File = $relativePath
            Missing = ($missingFields -join ", ")
        }
    }
}

if ($missing.Count -gt 0) {
    Write-Host "Script comment audit failed. Missing command-purpose header fields:"
    $missing | Format-Table -AutoSize | Out-String | Write-Host
    exit 1
}

Write-Host "PASS: script comment audit checked $($scriptFiles.Count) files"
