<#
Script: scripts\testbench-comment-audit.ps1
Purpose: Checks testbench files for required intent header fields.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\testbench-comment-audit.ps1
Outputs:
  Console report listing testbenches missing header fields.
Scope:
  Documentation consistency check only; not hardware evidence.
Audience:
  Public maintenance check used by scripts\check.ps1.
#>
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$testbenchFiles = @(Get-ChildItem -Path "tb" -Recurse -Filter "*.v" | Sort-Object FullName)
if ($testbenchFiles.Count -eq 0) {
    throw "No testbench files found under tb"
}

$requiredFields = @(
    "Testbench",
    "Purpose",
    "Checks",
    "Pass condition"
)

$missing = @()
foreach ($file in $testbenchFiles) {
    $text = Get-Content -Raw -LiteralPath $file.FullName
    $missingFields = @()
    $relativePath = $file.FullName.Substring($repoRoot.Path.Length + 1).Replace("\", "/")

    foreach ($field in $requiredFields) {
        $escapedField = [regex]::Escape($field)
        if ($text -notmatch "(?m)^// $escapedField`:") {
            $missingFields += $field
        }
    }
    if ($relativePath -match '^tb/(assertions|reference|program/isa|integration/fpga)/' -and
        $text -notmatch '(?m)^// Does not prove:') {
        $missingFields += "Does not prove"
    }

    if ($missingFields.Count -gt 0) {
        $missing += [pscustomobject]@{
            File = $relativePath
            Missing = ($missingFields -join ", ")
        }
    }
}

if ($missing.Count -gt 0) {
    Write-Host "Testbench comment audit failed. Missing intent header fields:"
    $missing | Format-Table -AutoSize | Out-String | Write-Host
    exit 1
}

$boundaryCount = @($testbenchFiles | Where-Object {
    $_.FullName.Substring($repoRoot.Path.Length + 1).Replace("\", "/") -match '^tb/(assertions|reference|program/isa|integration/fpga)/'
}).Count
Write-Host "PASS: testbench comment audit checked $($testbenchFiles.Count) files ($boundaryCount scoped boundary headers)"
