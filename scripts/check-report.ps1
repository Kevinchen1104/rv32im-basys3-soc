<#
Script: scripts/check-report.ps1
Purpose: Presents check and regression results as a short Markdown summary and CSV.
Common usage:
  Called by scripts/check.ps1 after each step.
Outputs:
  results/full-RESULTS.md and regression.csv; Quick uses a quick- filename prefix.
Scope:
  Renders current-run records without rerunning checks.
#>
function Write-CheckReport {
    param($Summary, [string]$ResultsDirectory, [string]$RegressionPath)

    $prefix = if ($Summary.mode -eq 'Quick') { 'quick-' } else { '' }
    $csvPath = Join-Path $ResultsDirectory "${prefix}regression.csv"
    $lines = @(
        "# $($Summary.mode) check results", '',
        "Status: **$($Summary.status)**. Completed $(@($Summary.steps | Where-Object { $_.status -eq 'passed' }).Count) of $($Summary.planned_steps) steps.", '',
        "Started (UTC): $($Summary.started_at_utc)", '',
        '| Step | Result | Seconds | Log |', '| --- | --- | ---: | --- |'
    )
    foreach ($step in $Summary.steps) {
        $relativeLog = $step.log -replace '^results/', ''
        $seconds = [math]::Round($step.duration_ms / 1000.0, 2)
        $label = if ($step.label) { $step.label } else { $step.name }
        $lines += "| $label | $($step.status) | $seconds | [log]($relativeLog) |"
    }
    if ($Summary.error_message) { $lines += @('', "Error: $($Summary.error_message)") }
    if ($Summary.regression -and (Test-Path -LiteralPath $RegressionPath)) {
        $regression = Get-Content -LiteralPath $RegressionPath -Raw | ConvertFrom-Json
        $lines += @('', '## Simulation', '',
            "$($regression.passed) / $($regression.requested_total) tests passed. See [test-by-test CSV](${prefix}regression.csv) and [JSON](${prefix}regression-summary.json).")
        $regression.tests | Select-Object name, source, status, duration_ms, waveform |
            Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    } elseif (Test-Path -LiteralPath $csvPath) {
        Remove-Item -LiteralPath $csvPath -Force
    }
    $lines += @('', '## Files', '',
        '- `logs/`: tool output and step commands.',
        '- `runs/`: input-isolated simulation logs and VCD files; exact paths are listed in the CSV and JSON.',
        '- `../build/`: rebuildable executables and temporary test inputs.',
        "- [Check JSON](${prefix}check-summary.json): timestamps, source identity, and step records.")
    $reportName = if ($Summary.mode -eq 'Quick') { 'quick-RESULTS.md' } else { 'full-RESULTS.md' }
    $lines | Set-Content -LiteralPath (Join-Path $ResultsDirectory $reportName) -Encoding UTF8
}
