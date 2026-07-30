<#
Script: scripts\comment-audit.ps1
Purpose: Checks RTL files for required module documentation header fields.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\comment-audit.ps1
Outputs:
  Console report listing RTL files missing header fields.
Scope:
  Documentation consistency check only; not hardware evidence.
Audience:
  Public maintenance check used by scripts\check.ps1.
#>
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$rtlFiles = @(Get-ChildItem -Path "rtl" -Recurse -Filter "*.v" | Sort-Object FullName)
if ($rtlFiles.Count -eq 0) {
    throw "No RTL files found under rtl"
}

$missing = @()
foreach ($file in $rtlFiles) {
    $text = Get-Content -Raw -LiteralPath $file.FullName
    $missingFields = @()

    if ($text -notmatch '(?m)^// Module:') {
        $missingFields += "Module"
    }
    if ($text -notmatch '(?m)^// Role:') {
        $missingFields += "Role"
    }
    if ($text -notmatch '(?m)^// Key behavior:') {
        $missingFields += "Key behavior"
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
    Write-Host "RTL comment audit failed. Missing header fields:"
    $missing | Format-Table -AutoSize | Out-String | Write-Host
    exit 1
}

Write-Host "PASS: RTL comment audit checked $($rtlFiles.Count) files"
