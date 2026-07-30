<#
Script: scripts\static-rtl-check.ps1
Purpose: Runs lightweight static hygiene checks over RTL source text.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\static-rtl-check.ps1
Outputs:
  Console static RTL hygiene report.
Scope:
  Static source hygiene only; not synthesis, timing, or formal proof.
Audience:
  Internal helper used by scripts\check.ps1.
#>
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$failures = @()

function Add-Failure {
    param([string]$Message)
    $script:failures += $Message
}

function Get-ActiveVerilogFiles {
    param([string]$Root)

    if (-not (Test-Path $Root)) {
        return @()
    }

    return @(Get-ChildItem -Path $Root -Filter "*.v" -File -Recurse |
        Sort-Object FullName)
}

function Test-TextPattern {
    param(
        [object[]]$Files,
        [string]$Pattern,
        [string]$Description
    )

    foreach ($file in $Files) {
        $matches = Select-String -Path $file.FullName -Pattern $Pattern
        foreach ($match in $matches) {
            Add-Failure "$($file.FullName):$($match.LineNumber): $Description"
        }
    }
}

$rtlFiles = Get-ActiveVerilogFiles "rtl"
$tbFiles = Get-ActiveVerilogFiles "tb"
$activeFiles = @($rtlFiles + $tbFiles)

Test-TextPattern -Files $activeFiles -Pattern "`t" -Description "tab character in active RTL/TB"
Test-TextPattern -Files $activeFiles -Pattern "[ \t]+$" -Description "trailing whitespace in active RTL/TB"
Test-TextPattern -Files $activeFiles -Pattern "^(<<<<<<<|=======|>>>>>>>)" -Description "merge conflict marker"
Test-TextPattern -Files $rtlFiles -Pattern '\$(display|finish|fatal)\b' -Description "simulation-only system task in active CPU RTL"

$trackedWaveFiles = @(git ls-files wave)
$unexpectedWaveFiles = @($trackedWaveFiles | Where-Object { $_ -ne "wave/.gitkeep" })
foreach ($path in $unexpectedWaveFiles) {
    Add-Failure "Tracked generated wave artifact: $path"
}

if ($failures.Count -ne 0) {
    Write-Host "FAIL: static RTL hygiene check found issues"
    $failures | ForEach-Object { Write-Host "  $_" }
    throw "Static RTL hygiene check failed"
}

Write-Host "PASS: static RTL hygiene check passed"
