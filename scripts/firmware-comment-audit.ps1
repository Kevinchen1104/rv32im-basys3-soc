<#
Script: scripts\firmware-comment-audit.ps1
Purpose: Checks firmware assembly sources for required intent header fields.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\firmware-comment-audit.ps1
Outputs:
  Console report listing firmware sources missing header fields.
Scope:
  Documentation consistency check only; not ISA proof, compliance, or hardware evidence.
Audience:
  Public maintenance check used by scripts\check.ps1.
#>
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$firmwareFiles = @(Get-ChildItem -Path "firmware/src" -Recurse -Filter "*.S" | Sort-Object FullName)
if ($firmwareFiles.Count -eq 0) {
    throw "No firmware assembly sources found under firmware/src"
}

$requiredFields = @(
    "Program",
    "Purpose",
    "Exercises",
    "Observable result",
    "Used by"
)

$missing = @()
foreach ($file in $firmwareFiles) {
    $text = Get-Content -Raw -LiteralPath $file.FullName
    $missingFields = @()
    $relativePath = $file.FullName.Substring($repoRoot.Path.Length + 1).Replace("\", "/")

    foreach ($field in $requiredFields) {
        $escapedField = [regex]::Escape($field)
        if ($text -notmatch "(?m)^# $escapedField`:") {
            $missingFields += $field
        }
    }
    if ($relativePath -match '^firmware/src/(isa|showcase)/' -and
        $text -notmatch '(?m)^# Does not claim:') {
        $missingFields += "Does not claim"
    }

    if ($missingFields.Count -gt 0) {
        $missing += [pscustomobject]@{
            File = $relativePath
            Missing = ($missingFields -join ", ")
        }
    }
}

if ($missing.Count -gt 0) {
    Write-Host "Firmware comment audit failed. Missing assembly header fields:"
    $missing | Format-Table -AutoSize | Out-String | Write-Host
    exit 1
}

$boundaryCount = @($firmwareFiles | Where-Object {
    $_.FullName.Substring($repoRoot.Path.Length + 1).Replace("\", "/") -match '^firmware/src/(isa|showcase)/'
}).Count
Write-Host "PASS: firmware comment audit checked $($firmwareFiles.Count) files ($boundaryCount scoped boundary headers)"
