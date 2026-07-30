<#
Script: scripts\vivado-drc-parser-self-test.ps1
Purpose: Proves the Vivado DRC parser reconciles counts and fails closed on unknown or incomplete reports.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\vivado-drc-parser-self-test.ps1
Outputs:
  Temporary report fixtures under wave\, removed before exit.
Scope:
  Parser policy self-test only; does not invoke Vivado or inspect a synthesized design.
Audience:
  Release maintainers and CI-style local verification.
#>
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. "$PSScriptRoot\vivado-drc-report.ps1"

New-Item -ItemType Directory -Force -Path "wave" | Out-Null
$fixtures = [System.Collections.Generic.List[string]]::new()

function Write-DrcFixture {
    param([string] $Name, [string] $Body)

    $path = Join-Path "wave" ("drc-parser-self-test-" + $Name + ".rpt")
    [System.IO.File]::WriteAllText($path, $Body, [System.Text.Encoding]::ASCII)
    $fixtures.Add($path) | Out-Null
    return $path
}

try {
    $clean = Read-DrcReportSummary (Write-DrcFixture "clean" @"
            Checks found: 0
+------+----------+-------------+--------+
| Rule | Severity | Description | Checks |
+------+----------+-------------+--------+
"@)
    if (-not $clean.report_parse_complete -or -not $clean.release_approved) {
        throw "Zero-check DRC report was not accepted."
    }

    $knownBad = Read-DrcReportSummary (Write-DrcFixture "reqp" @"
            Checks found: 6
| REQP-1839 | Warning  | RAMB36 async control check | 6 |
"@)
    if (-not $knownBad.report_parse_complete -or $knownBad.release_approved -or
        $knownBad.bram_async_control_warning_count -ne 6) {
        throw "REQP-1839 report did not fail with the expected count."
    }

    $incomplete = Read-DrcReportSummary (Write-DrcFixture "incomplete" @"
            Checks found: 6
"@)
    if ($incomplete.report_parse_complete -or $incomplete.release_approved) {
        throw "Incomplete DRC table failed open."
    }

    $unknown = Read-DrcReportSummary (Write-DrcFixture "unknown" @"
            Checks found: 1
| NEW-1 | Warning | Newly introduced warning | 1 |
"@)
    if (-not $unknown.report_parse_complete -or $unknown.release_approved -or
        $unknown.unapproved_warning_count -ne 1) {
        throw "Unknown DRC warning failed open."
    }

    Write-Host "PASS: Vivado DRC parser reconciles counts and fails closed"
} finally {
    foreach ($path in $fixtures) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}
