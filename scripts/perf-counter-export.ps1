# Measure the two counter scenarios once, validate them, and export both views.
param([switch]$SkipAssemble, [switch]$MeasureOnly)
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
. "$PSScriptRoot/perf-counter-data.ps1"
. "$PSScriptRoot/result-format.ps1"
. "$PSScriptRoot/verification-source-identity.ps1"
$path = 'results/perf-counter-comparison.json'
$snapshot = [ordered]@{ Schema='riscv-cpu-performance-counter-snapshot-v1'; status='running'; Source='live simulation'; Rows=@() }
Write-ResultJson $snapshot $path
if (Test-Path 'results/perf-counter-comparison.csv') { Remove-Item -LiteralPath 'results/perf-counter-comparison.csv' }
try {
    $startingIdentity = Add-VerificationIdentityFields $snapshot
    $rows = @(Get-PerfCounterRows -SkipAssemble:$SkipAssemble)
    $snapshot.Rows = $rows
    if (-not $MeasureOnly) {
        $expected = @(Get-ExpectedPerfCounterRows)
        foreach ($row in $rows) {
            $gold = @($expected | Where-Object Scenario -eq $row.Scenario)
            if ($gold.Count -ne 1) { throw "Missing expected scenario: $($row.Scenario)" }
            foreach ($metric in @('Cycles','Retired','BranchMisses','ICacheMisses','DCacheMisses','StallCycles')) {
                if ($row.$metric -ne $gold[0].$metric) { throw "$($row.Scenario) $metric expected=$($gold[0].$metric) actual=$($row.$metric)" }
            }
        }
        if ($rows.Count -ne $expected.Count) { throw 'Counter scenario count mismatch' }
    }
    $snapshot.Rows = $rows
    $snapshot['MeasuredAtUtc'] = (Get-Date).ToUniversalTime().ToString('o')
    $snapshot['Units'] = @{ Cycles='cycles'; Retired='instructions'; BranchMisses='events'; ICacheMisses='events'; DCacheMisses='events'; StallCycles='cycles' }
    Assert-VerificationInputsUnchanged $startingIdentity
    $rows | Export-Csv -LiteralPath 'results/perf-counter-comparison.csv' -NoTypeInformation -Encoding UTF8
    $snapshot['expected_values_checked'] = -not $MeasureOnly
    $snapshot.status = if ($MeasureOnly) { 'measured' } else { 'pass' }
} catch {
    $snapshot.status = 'fail'
    $snapshot['error_message'] = $_.Exception.Message
    throw
} finally { Write-ResultJson $snapshot $path }
Write-Host "Counter measurement exported to JSON and CSV: $($snapshot.status)"
