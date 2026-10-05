<#
Script: scripts\vivado-basys3-robustness.ps1
Purpose: Runs several documented Vivado implementation strategies and summarizes timing robustness.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\vivado-basys3-robustness.ps1
Outputs:
  Per-strategy Vivado reports under build/vivado/basys3_robustness and one JSON summary under results/.
Scope:
  Multi-strategy implementation evidence; this is not a random-seed guarantee or physical-board validation.
#>
param(
    [double] $MinimumWnsNs = 0.200,
    [string] $OutRoot = "build\vivado\basys3_robustness",
    [string] $SummaryPath = "results\vivado-basys3-robustness-summary.json",
    [switch] $Resume
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/result-format.ps1"
. "$PSScriptRoot/script-common.ps1"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
$summary = [ordered]@{ status='running'; runs=@(); error_message=$null }
Write-ResultJson $summary $SummaryPath
try {

function Get-ReusableStrategyResult {
    param(
        [string] $Path,
        [System.Collections.IDictionary] $Profile
    )

    if (-not $Resume -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $candidate = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    } catch {
        return $null
    }
    if ($candidate.status -ne "pass" -or
        $candidate.implementation_status -ne "pass" -or
        $candidate.implementation_strategy.opt_directive -ne $Profile.opt -or
        $candidate.implementation_strategy.place_directive -ne $Profile.place -or
        $candidate.implementation_strategy.phys_opt_directive -ne $Profile.phys -or
        $candidate.implementation_strategy.route_directive -ne $Profile.route -or
        $null -eq $candidate.source_inputs) {
        return $null
    }

    foreach ($inputRecord in @($candidate.source_inputs)) {
        $pathFromSummary = ([string]$inputRecord.path).Replace("/", "\")
        if (-not (Test-Path -LiteralPath $pathFromSummary -PathType Leaf) -or
            (Get-FileHash -LiteralPath $pathFromSummary -Algorithm SHA256).Hash.ToLowerInvariant() -ne
                [string]$inputRecord.sha256) {
            return $null
        }
    }
    $timingReportPath = [string]$candidate.reports.post_route_timing.path
    try { Assert-BuildReportArtifacts $candidate $repoRoot } catch { return $null }
    $criticalReportPath = [string]$candidate.reports.post_route_critical_path.path
    if (-not (Test-Path -LiteralPath $timingReportPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $criticalReportPath -PathType Leaf)) {
        return $null
    }
    return $candidate
}

$profiles = @(
    [ordered]@{
        name = "remap_explore"
        opt = "ExploreWithRemap"
        place = "Explore"
        phys = "Explore"
        route = "NoTimingRelaxation"
    },
    [ordered]@{
        name = "remap_extra_place"
        opt = "ExploreWithRemap"
        place = "ExtraPostPlacementOpt"
        phys = "AggressiveExplore"
        route = "NoTimingRelaxation"
    },
    [ordered]@{
        name = "remap_aggressive"
        opt = "ExploreWithRemap"
        place = "Explore"
        phys = "AggressiveExplore"
        route = "AggressiveExplore"
    },
    [ordered]@{
        name = "remap_global_route"
        opt = "ExploreWithRemap"
        place = "Explore"
        phys = "AggressiveExplore"
        route = "MoreGlobalIterations"
    },
    [ordered]@{
        name = "remap_delay_cost"
        opt = "ExploreWithRemap"
        place = "ExtraPostPlacementOpt"
        phys = "AggressiveExplore"
        route = "HigherDelayCost"
    }
)

$runs = @()
foreach ($profile in $profiles) {
    $runOutDir = Join-Path $OutRoot $profile.name
    $runSummary = Join-Path "results" "vivado-basys3-robustness-$($profile.name).json"
    $runLog = Join-Path "results" "vivado-basys3-robustness-$($profile.name).log"
    $result = Get-ReusableStrategyResult -Path $runSummary -Profile $profile

    Write-Host "========================================"
    if ($null -ne $result) {
        Write-Host ("Reusing source-matched Vivado strategy: {0}" -f $profile.name)
    } else {
        Write-Host ("Running Vivado implementation strategy: {0}" -f $profile.name)
        & "$PSScriptRoot\vivado-basys3-build.ps1" `
            -Implementation `
            -OutDir $runOutDir `
            -SummaryPath $runSummary `
            -LogPath $runLog `
            -OptDirective $profile.opt `
            -PlaceDirective $profile.place `
            -PhysOptDirective $profile.phys `
            -RouteDirective $profile.route
        if ($LASTEXITCODE -ne 0) {
            throw "Vivado strategy failed to execute: $($profile.name)"
        }
        $result = Get-Content -Raw -LiteralPath $runSummary | ConvertFrom-Json
    }

    $runs += [ordered]@{
        name = $profile.name
        implementation_strategy = $result.implementation_strategy
        status = $result.status
        implementation_status = $result.implementation_status
        timing_closure_status = $result.timing_closure_status
        timing_constraint_status = $result.timing_constraint_status
        drc_status = $result.drc_status
        wns_ns = $result.reports.post_route_timing.wns_ns
        tns_ns = $result.reports.post_route_timing.tns_ns
        whs_ns = $result.reports.post_route_timing.whs_ns
        ths_ns = $result.reports.post_route_timing.ths_ns
        no_clock_count = $result.reports.post_route_timing.no_clock_count
        unconstrained_internal_endpoint_count =
            $result.reports.post_route_timing.unconstrained_internal_endpoint_count
        no_input_delay_count = $result.reports.post_route_timing.no_input_delay_count
        no_output_delay_count = $result.reports.post_route_timing.no_output_delay_count
        drc_error_count = $result.reports.post_route_drc.error_count
        drc_critical_warning_count = $result.reports.post_route_drc.critical_warning_count
        drc_unapproved_warning_count = $result.reports.post_route_drc.unapproved_warning_count
        bram_async_control_warning_count = $result.reports.post_route_drc.bram_async_control_warning_count
        critical_path = $result.reports.post_route_critical_path
        utilization = $result.reports.post_route_utilization
        peak_memory_mb = $result.peak_memory_mb
        out_dir = $result.out_dir
        summary_path = $runSummary.Replace("\", "/")
    }
}

$validWns = @($runs | Where-Object { $null -ne $_.wns_ns } | ForEach-Object { [double]$_.wns_ns })
$allImplemented = @($runs | Where-Object {
    $_.implementation_status -ne "pass" -or
    $_.timing_closure_status -ne "met" -or
    $_.timing_constraint_status -ne "pass" -or
    $_.drc_status -ne "pass" -or
    $null -eq $_.wns_ns -or [double]$_.wns_ns -lt 0.0 -or
    $null -eq $_.tns_ns -or [double]$_.tns_ns -ne 0.0 -or
    $null -eq $_.whs_ns -or [double]$_.whs_ns -lt 0.0 -or
    $null -eq $_.ths_ns -or [double]$_.ths_ns -ne 0.0 -or
    [int]$_.no_clock_count -ne 0 -or
    [int]$_.unconstrained_internal_endpoint_count -ne 0 -or
    [int]$_.no_input_delay_count -ne 0 -or
    [int]$_.no_output_delay_count -ne 0 -or
    [int]$_.drc_error_count -ne 0 -or
    [int]$_.drc_critical_warning_count -ne 0 -or
    [int]$_.drc_unapproved_warning_count -ne 0 -or
    [int]$_.bram_async_control_warning_count -ne 0
}).Count -eq 0
$worstWns = if ($validWns.Count -eq $runs.Count) {
    ($validWns | Measure-Object -Minimum).Minimum
} else {
    $null
}
$bestWns = if ($validWns.Count -gt 0) {
    ($validWns | Measure-Object -Maximum).Maximum
} else {
    $null
}
$marginTargetMet = $allImplemented -and
    $null -ne $worstWns -and
    [double]$worstWns -ge $MinimumWnsNs
$sourceCommits = @(
    $runs |
        ForEach-Object {
            $runSummary = Get-Content -Raw -LiteralPath $_.summary_path | ConvertFrom-Json
            [string]$runSummary.source_commit
        } |
        Sort-Object -Unique
)
$sourceFingerprints = @(
    $runs |
        ForEach-Object {
            $runSummary = Get-Content -Raw -LiteralPath $_.summary_path | ConvertFrom-Json
            [string]$runSummary.source_fingerprint
        } |
        Sort-Object -Unique
)
$verificationFingerprints = @(
    $runs |
        ForEach-Object {
            $runSummary = Get-Content -Raw -LiteralPath $_.summary_path | ConvertFrom-Json
            [string]$runSummary.verification_input_fingerprint
        } |
        Sort-Object -Unique
)
$verificationInputCounts = @(
    $runs |
        ForEach-Object {
            $runSummary = Get-Content -Raw -LiteralPath $_.summary_path | ConvertFrom-Json
            [int]$runSummary.verification_input_count
        } |
        Sort-Object -Unique
)
$workingTreeDirtyValues = @(
    $runs |
        ForEach-Object {
            $runSummary = Get-Content -Raw -LiteralPath $_.summary_path | ConvertFrom-Json
            [bool]$runSummary.working_tree_dirty
        } |
        Sort-Object -Unique
)
$verificationDirtyValues = @(
    $runs |
        ForEach-Object {
            $runSummary = Get-Content -Raw -LiteralPath $_.summary_path | ConvertFrom-Json
            [bool]$runSummary.verification_working_tree_dirty
        } |
        Sort-Object -Unique
)
$identityConsistent =
    $sourceCommits.Count -eq 1 -and
    -not [string]::IsNullOrWhiteSpace($sourceCommits[0]) -and
    $sourceFingerprints.Count -eq 1 -and
    -not [string]::IsNullOrWhiteSpace($sourceFingerprints[0]) -and
    $verificationFingerprints.Count -eq 1 -and
    -not [string]::IsNullOrWhiteSpace($verificationFingerprints[0]) -and
    $verificationInputCounts.Count -eq 1 -and
    $workingTreeDirtyValues.Count -eq 1 -and
    $verificationDirtyValues.Count -eq 1

$summary = [ordered]@{
    schema_version = 2
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = if ($allImplemented -and $identityConsistent) { "pass" } else { "fail" }
    top = "RISCVCPU_basys3_top"
    part = "xc7a35tcpg236-1"
    clock_mhz = 100
    source_commit = if ($identityConsistent) { $sourceCommits[0] } else { $null }
    working_tree_dirty = if ($identityConsistent) { $workingTreeDirtyValues[0] } else { $null }
    source_fingerprint = if ($identityConsistent) { $sourceFingerprints[0] } else { $null }
    verification_input_fingerprint = if ($identityConsistent) { $verificationFingerprints[0] } else { $null }
    verification_input_count = if ($identityConsistent) { $verificationInputCounts[0] } else { $null }
    verification_working_tree_dirty = if ($identityConsistent) { $verificationDirtyValues[0] } else { $null }
    methodology = "documented Vivado implementation-directive sweep; not random-seed evidence"
    run_count = $runs.Count
    required_all_timing_met = $true
    minimum_wns_target_ns = $MinimumWnsNs
    all_implementations_passed = $allImplemented
    identity_consistent = $identityConsistent
    margin_target_status = if ($marginTargetMet) { "met" } else { "not_met" }
    margin_target_met = $marginTargetMet
    worst_wns_ns = $worstWns
    best_wns_ns = $bestWns
    runs = $runs
    claim_boundary = "This sweep samples documented implementation strategies. It does not prove all placements, random seeds, external synchronous-I/O timing, or physical-board behavior."
}

$parent = Split-Path -Parent $SummaryPath
if (-not [string]::IsNullOrWhiteSpace($parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
}
Write-ResultJson $summary $SummaryPath
Write-Host "========================================"
Write-Host "Basys3 implementation robustness"
Write-Host ("Status: {0}" -f $summary.status)
Write-Host ("Runs: {0}" -f $summary.run_count)
Write-Host ("Worst WNS: {0} ns" -f $summary.worst_wns_ns)
Write-Host ("Best WNS: {0} ns" -f $summary.best_wns_ns)
Write-Host ("Minimum target: {0} ns" -f $summary.minimum_wns_target_ns)
Write-Host ("Summary: {0}" -f $SummaryPath)

if (-not $allImplemented -or -not $identityConsistent) {
    throw 'Implementation strategies failed or used inconsistent inputs.'
}
} catch {
    $summary.status = 'fail'
    $summary['error_message'] = $_.Exception.Message
    throw
} finally { Write-ResultJson $summary $SummaryPath }
