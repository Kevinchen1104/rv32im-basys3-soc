<#
Script: scripts\vivado-drc-report.ps1
Purpose: Parses Vivado DRC summaries with count reconciliation and fail-closed release policy.
Common usage:
  . "$PSScriptRoot\vivado-drc-report.ps1"
Outputs:
  No files; exposes Read-DrcReportSummary.
Scope:
  DRC report parsing only; no Vivado invocation or design correctness claim.
#>

function Read-DrcReportSummary {
    param([string] $Path)

    # No ordinary warnings are pre-approved. Add a rule here only after its
    # design impact and release wording have been reviewed.
    $allowedWarningRules = @()
    $result = [ordered]@{
        path = $Path
        present = $false
        checks_found = $null
        parsed_check_count = 0
        report_parse_complete = $false
        error_count = 0
        critical_warning_count = 0
        warning_count = 0
        advisory_count = 0
        unapproved_warning_count = 0
        bram_async_control_warning_count = 0
        release_approved = $false
        allowed_warning_rules = $allowedWarningRules
        unapproved_rules = @()
        rules = @()
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return $result
    }

    $result.present = $true
    $text = Get-Content -Raw -LiteralPath $Path
    $checksMatch = [regex]::Match($text, '(?m)^\s*Checks found:\s*([0-9,]+)\s*$')
    if ($checksMatch.Success) {
        $result.checks_found = [int]$checksMatch.Groups[1].Value.Replace(",", "")
    }

    $rules = [System.Collections.Generic.List[object]]::new()
    $unapprovedRules = [System.Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches(
        $text,
        '(?m)^\|\s*([A-Za-z0-9_-]+)\s*\|\s*(Error|Critical Warning|Warning|Advisory)\s*\|.*?\|\s*([0-9,]+)\s*\|\s*$'
    )) {
        $rule = $match.Groups[1].Value
        $severity = $match.Groups[2].Value
        $count = [int]$match.Groups[3].Value.Replace(",", "")
        $result.parsed_check_count += $count
        $rules.Add([ordered]@{
            rule = $rule
            severity = $severity
            count = $count
        }) | Out-Null
        switch ($severity) {
            "Error" { $result.error_count += $count }
            "Critical Warning" { $result.critical_warning_count += $count }
            "Warning" { $result.warning_count += $count }
            "Advisory" { $result.advisory_count += $count }
        }
        if ($rule -eq "REQP-1839") {
            $result.bram_async_control_warning_count += $count
        }
        if (($severity -eq "Warning" -or $severity -eq "Advisory") -and
            $allowedWarningRules -notcontains $rule) {
            $result.unapproved_warning_count += $count
            if (-not $unapprovedRules.Contains($rule)) {
                $unapprovedRules.Add($rule) | Out-Null
            }
        }
    }
    $result.rules = $rules.ToArray()
    $result.unapproved_rules = $unapprovedRules.ToArray()
    $result.report_parse_complete = (
        $null -ne $result.checks_found -and
        $result.parsed_check_count -eq $result.checks_found
    )
    $result.release_approved = (
        $result.report_parse_complete -and
        $result.error_count -eq 0 -and
        $result.critical_warning_count -eq 0 -and
        $result.unapproved_warning_count -eq 0 -and
        $result.bram_async_control_warning_count -eq 0
    )
    return $result
}
