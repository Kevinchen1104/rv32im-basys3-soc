<#
Script: scripts\vivado-basys3-build.ps1
Purpose: Runs the Basys3 Vivado synthesis/implementation wrapper when Vivado is available.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\vivado-basys3-build.ps1 -SynthOnly
Outputs:
  Vivado project, logs, reports, and optional bitstream artifacts under release or wave build paths.
Scope:
  Vivado build flow evidence only; not physical board validation, and timing depends on generated reports.
Audience:
  Public optional FPGA build helper.
#>
param(
    [switch] $SynthOnly,
    [switch] $Implementation,
    [switch] $Bitstream,
    [string] $Top = "RISCVCPU_basys3_top",
    [string] $SummaryPath = "",
    [string] $LogPath = "",
    [string] $OutDir = "build\vivado\basys3",
    [string] $OptDirective = "ExploreWithRemap",
    [string] $PlaceDirective = "Explore",
    [string] $PhysOptDirective = "Explore",
    [string] $RouteDirective = "NoTimingRelaxation"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. "$PSScriptRoot\vivado-drc-report.ps1"
. "$PSScriptRoot\verification-source-identity.ps1"

New-Item -ItemType Directory -Force -Path "wave" | Out-Null

function Read-JsonIfPresent {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-RepoRelativePathIfPresent {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $Path
    }

    $resolved = Resolve-Path -LiteralPath $Path
    $basePath = $repoRoot.Path
    if (-not $basePath.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $basePath += [System.IO.Path]::DirectorySeparatorChar
    }

    $baseUri = [System.Uri]::new($basePath)
    $pathUri = [System.Uri]::new($resolved.Path)
    return [System.Uri]::UnescapeDataString(
        $baseUri.MakeRelativeUri($pathUri).ToString()
    ).Replace("/", [System.IO.Path]::DirectorySeparatorChar)
}

function Ensure-ParentDirectory {
    param([string] $Path)

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
}

function Get-BuildInputIdentity {
    $inputPaths = [System.Collections.Generic.List[string]]::new()
    $manifestPath = "fpga\fpga_sources.f"
    $inputPaths.Add($manifestPath) | Out-Null

    foreach ($line in Get-Content -LiteralPath $manifestPath) {
        $candidate = $line.Trim()
        if ($candidate -eq "" -or $candidate.StartsWith("#")) {
            continue
        }
        $inputPaths.Add($candidate.Replace("/", "\")) | Out-Null
    }

    foreach ($supportPath in @(
        "fpga\vivado\basys3_build.tcl",
        "fpga\boards\basys3\basys3.xdc"
    )) {
        $inputPaths.Add($supportPath) | Out-Null
    }

    $records = @(
        foreach ($path in @($inputPaths | Sort-Object -Unique)) {
            if (-not (Test-Path -LiteralPath $path)) {
                throw "Vivado build input missing: $path"
            }
            [ordered]@{
                path = $path.Replace("\", "/")
                sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    )
    $identityText = ($records | ForEach-Object { "$($_.path):$($_.sha256)" }) -join "`n"
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $identityBytes = [System.Text.Encoding]::UTF8.GetBytes($identityText)
        $identityHash = [System.BitConverter]::ToString($hasher.ComputeHash($identityBytes)).Replace("-", "").ToLowerInvariant()
    } finally {
        $hasher.Dispose()
    }

    return [ordered]@{
        algorithm = "sha256(path:sha256 records)"
        fingerprint = $identityHash
        inputs = $records
    }
}

function Read-TimingReportSummary {
    param([string] $Path)

    $result = [ordered]@{
        path = $Path
        present = $false
        wns_ns = $null
        tns_ns = $null
        whs_ns = $null
        ths_ns = $null
        no_clock_count = $null
        unconstrained_internal_endpoint_count = $null
        no_input_delay_count = $null
        no_output_delay_count = $null
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return $result
    }

    $result.present = $true
    $text = Get-Content -Raw -LiteralPath $Path
    $match = [regex]::Match(
        $text,
        "WNS\(ns\)\s+TNS\(ns\).*?\r?\n\s*([-+]?[0-9]+(?:\.[0-9]+)?)\s+([-+]?[0-9]+(?:\.[0-9]+)?)\s+[0-9]+\s+[0-9]+\s+([-+]?[0-9]+(?:\.[0-9]+)?)\s+([-+]?[0-9]+(?:\.[0-9]+)?)",
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if ($match.Success) {
        $wns = 0.0
        $tns = 0.0
        if ([double]::TryParse($match.Groups[1].Value, [ref] $wns)) {
            $result.wns_ns = $wns
        }
        if ([double]::TryParse($match.Groups[2].Value, [ref] $tns)) {
            $result.tns_ns = $tns
        }
        $whs = 0.0
        $ths = 0.0
        if ([double]::TryParse($match.Groups[3].Value, [ref] $whs)) {
            $result.whs_ns = $whs
        }
        if ([double]::TryParse($match.Groups[4].Value, [ref] $ths)) {
            $result.ths_ns = $ths
        }
    }

    $checkNames = [ordered]@{
        no_clock_count = "no_clock"
        unconstrained_internal_endpoint_count = "unconstrained_internal_endpoints"
        no_input_delay_count = "no_input_delay"
        no_output_delay_count = "no_output_delay"
    }
    foreach ($field in $checkNames.Keys) {
        $checkMatch = [regex]::Match(
            $text,
            "checking\s+$([regex]::Escape($checkNames[$field]))\s+\(([0-9]+)\)"
        )
        if ($checkMatch.Success) {
            $result[$field] = [int]$checkMatch.Groups[1].Value
        }
    }

    return $result
}

function Read-UtilizationReport {
    param([string] $Path)

    $result = [ordered]@{
        path = $Path
        present = $false
        lut = $null
        ff = $null
        bram = $null
        dsp = $null
        io = $null
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return $result
    }

    $result.present = $true
    $text = Get-Content -Raw -LiteralPath $Path
    $rows = [ordered]@{
        lut = "Slice LUTs"
        ff = "Slice Registers"
        bram = "Block RAM Tile"
        dsp = "DSPs"
        io = "Bonded IOB"
    }
    foreach ($name in $rows.Keys) {
        $label = [regex]::Escape($rows[$name])
        $match = [regex]::Match(
            $text,
            "(?m)^\|\s*$label\*?\s*\|\s*([0-9,]+)\s*\|\s*[0-9,]+\s*\|\s*[0-9,]+\s*\|\s*([0-9,]+)\s*\|\s*([0-9.]+)\s*\|"
        )
        if ($match.Success) {
            $result[$name] = [ordered]@{
                used = [int]($match.Groups[1].Value.Replace(",", ""))
                available = [int]($match.Groups[2].Value.Replace(",", ""))
                percent = [double]$match.Groups[3].Value
            }
        }
    }
    return $result
}

function Read-CriticalPathSummary {
    param([string] $Path)

    $result = [ordered]@{
        path = $Path
        present = $false
        slack_ns = $null
        source = $null
        destination = $null
        path_group = $null
        logic_levels = $null
        cell_types = $null
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return $result
    }

    $result.present = $true
    $text = Get-Content -Raw -LiteralPath $Path
    $patterns = [ordered]@{
        slack_ns = "Slack \([^\)]+\)\s*:\s*([-+]?[0-9]+(?:\.[0-9]+)?)ns"
        source = "(?m)^\s*Source:\s+([^\r\n]+)"
        destination = "(?m)^\s*Destination:\s+([^\r\n]+)"
        path_group = "(?m)^\s*Path Group:\s+([^\r\n]+)"
        logic_levels = "(?m)^\s*Logic Levels:\s+([0-9]+)"
        cell_types = "(?m)^\s*Logic Levels:\s+[0-9]+\s*(\([^\r\n]+\))"
    }
    foreach ($name in $patterns.Keys) {
        $match = [regex]::Match($text, $patterns[$name])
        if ($match.Success) {
            if ($name -eq "slack_ns") {
                $result[$name] = [double]$match.Groups[1].Value
            } elseif ($name -eq "logic_levels") {
                $result[$name] = [int]$match.Groups[1].Value
            } else {
                $result[$name] = $match.Groups[1].Value.Trim()
            }
        }
    }
    return $result
}

function Read-ClockReport {
    param([string] $Path)

    $clocks = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }
    foreach ($line in Get-Content -LiteralPath $Path | Select-Object -Skip 1) {
        $parts = @($line -split "\s+" | Where-Object { $_ -ne "" })
        if ($parts.Count -ge 4) {
            $period = 0.0
            $frequency = 0.0
            $clocks.Add([ordered]@{
                name = $parts[0]
                period_ns = if ([double]::TryParse($parts[1], [ref] $period)) { $period } else { $parts[1] }
                frequency_mhz = if ([double]::TryParse($parts[2], [ref] $frequency)) { $frequency } else { $parts[2] }
                generated = $parts[3]
                source_pin = if ($parts.Count -ge 5) { ($parts[4..($parts.Count - 1)] -join " ") } else { $null }
            }) | Out-Null
        }
    }
    return $clocks.ToArray()
}

function Get-PeakMemoryMb {
    param([string] $Text)

    $peak = $null
    foreach ($match in [regex]::Matches($Text, "Memory \(MB\): peak =\s*([0-9]+(?:\.[0-9]+)?)")) {
        $value = [double]$match.Groups[1].Value
        if ($null -eq $peak -or $value -gt $peak) {
            $peak = $value
        }
    }
    return $peak
}

if (-not $SynthOnly -and -not $Implementation -and -not $Bitstream) {
    $SynthOnly = $true
}
if ($Bitstream) {
    $Implementation = $true
    $SynthOnly = $false
}
if ($Implementation) {
    $SynthOnly = $false
}

$detectScript = Join-Path $PSScriptRoot "vivado-detect.ps1"
& powershell -NoProfile -ExecutionPolicy Bypass -File $detectScript
$detectSummary = Read-JsonIfPresent "wave\vivado-detect-summary.json"
$buildInputIdentity = Get-BuildInputIdentity
$verificationIdentity = Get-VerificationSourceIdentity
$sourceCommit = (& git rev-parse HEAD 2>$null).Trim()
$workingTreeDirty = (@(& git status --porcelain 2>$null)).Count -ne 0

$summaryPath = if ([string]::IsNullOrWhiteSpace($SummaryPath)) { "wave\vivado-basys3-build-summary.json" } else { $SummaryPath }
$logPath = if ([string]::IsNullOrWhiteSpace($LogPath)) { "wave\vivado-basys3-build.log" } else { $LogPath }
$mode = if ($Bitstream) { "bitstream" } elseif ($Implementation) { "implementation" } else { "synth_only" }
Ensure-ParentDirectory $summaryPath
Ensure-ParentDirectory $logPath

if ($null -eq $detectSummary -or $detectSummary.status -ne "available") {
    $summary = [ordered]@{
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        status = "blocked_no_vivado"
        mode = $mode
        vivado = if ($null -eq $detectSummary) { $null } else { $detectSummary.tool }
        part = "xc7a35tcpg236-1"
        top = $Top
        source_commit = $sourceCommit
        working_tree_dirty = $workingTreeDirty
        source_fingerprint = $buildInputIdentity.fingerprint
        verification_input_fingerprint = $verificationIdentity.verification_input_fingerprint
        verification_input_count = $verificationIdentity.verification_input_count
        verification_working_tree_dirty = $verificationIdentity.verification_working_tree_dirty
        source_inputs = $buildInputIdentity.inputs
        out_dir = $OutDir
        log = $logPath
        synth_status = "blocked_no_vivado"
        implementation_status = "not_run"
        timing_status = "not_run"
        timing_closure_status = "not_run"
        timing_constraint_status = "not_run"
        implementation_strategy = [ordered]@{
            opt_directive = $OptDirective
            place_directive = $PlaceDirective
            phys_opt_directive = $PhysOptDirective
            route_directive = $RouteDirective
        }
        bitstream_status = "not_run"
        physical_validation_status = "not_run"
        claim_boundary = "Vivado may be unavailable; status reports blocked_no_vivado. No synthesis, timing, bitstream, or board validation result was produced."
    }

    "Vivado not found; Basys3 build blocked_no_vivado." | Set-Content -Path $logPath -Encoding Ascii
    $summary | ConvertTo-Json -Depth 7 | Set-Content -Path $summaryPath -Encoding Ascii

    Write-Host "========================================"
    Write-Host "Basys3 Vivado build"
    Write-Host "Status: blocked_no_vivado"
    Write-Host ("Summary: {0}" -f $summaryPath)
    exit 0
}

$vivadoPath = $detectSummary.tool.path
$tclPath = (Resolve-Path -LiteralPath "fpga\vivado\basys3_build.tcl").Path
if ([System.IO.Path]::IsPathRooted($OutDir)) {
    $resolvedOutDir = $OutDir
} else {
    $resolvedOutDir = Join-Path $repoRoot.Path $OutDir
}
$resolvedOutDir = (New-Item -ItemType Directory -Force -Path $resolvedOutDir).FullName
$topLogSuffix = if ($Top -eq "RISCVCPU_basys3_top") { "basys3" } else { "basys3-$($Top -replace '[^A-Za-z0-9_-]', '_')" }
$vivadoNativeLogPath = (Join-Path $repoRoot.Path "wave\vivado-$topLogSuffix-vivado.log")
$vivadoJournalPath = (Join-Path $repoRoot.Path "wave\vivado-$topLogSuffix-vivado.jou")
$vivadoTempDir = Join-Path $resolvedOutDir "tmp"
New-Item -ItemType Directory -Force -Path $vivadoTempDir | Out-Null
$repoRootForVivado = $repoRoot.Path.Replace("\", "/")
$tclPathForVivado = $tclPath.Replace("\", "/")
$resolvedOutDirForVivado = $resolvedOutDir.Replace("\", "/")
$vivadoNativeLogPathForVivado = $vivadoNativeLogPath.Replace("\", "/")
$vivadoJournalPathForVivado = $vivadoJournalPath.Replace("\", "/")
$vivadoTempDirForVivado = $vivadoTempDir.Replace("\", "/")
$runSynthOnly = if ($SynthOnly) { "1" } else { "0" }
$runImpl = if ($Implementation) { "1" } else { "0" }
$generateBitstream = if ($Bitstream) { "1" } else { "0" }
$reportDir = Join-Path $resolvedOutDir "reports"
$bitstreamPath = Join-Path $resolvedOutDir "$Top.bit"

# Remove only the exact generated files that this invocation can recreate.
# This prevents a failed Vivado startup from being summarized with reports or
# a bitstream left by an earlier invocation of the same output directory.
$generatedArtifacts = @(
    (Join-Path $resolvedOutDir "post_synth.dcp"),
    (Join-Path $resolvedOutDir "post_route.dcp"),
    $bitstreamPath,
    (Join-Path $reportDir "post_synth_utilization.rpt"),
    (Join-Path $reportDir "post_synth_timing_summary.rpt"),
    (Join-Path $reportDir "post_synth_critical_paths.rpt"),
    (Join-Path $reportDir "post_synth_drc.rpt"),
    (Join-Path $reportDir "post_synth_clocks.rpt"),
    (Join-Path $reportDir "post_route_utilization.rpt"),
    (Join-Path $reportDir "post_route_timing_summary.rpt"),
    (Join-Path $reportDir "post_route_critical_paths.rpt"),
    (Join-Path $reportDir "post_route_drc.rpt"),
    (Join-Path $reportDir "post_route_timing_exceptions.rpt"),
    (Join-Path $reportDir "post_route_clock_interaction.rpt"),
    (Join-Path $reportDir "post_route_clocks.rpt")
)
foreach ($artifact in $generatedArtifacts) {
    if (Test-Path -LiteralPath $artifact -PathType Leaf) {
        Remove-Item -LiteralPath $artifact -Force
    }
}

$vivadoArgs = @(
    "-mode", "batch",
    "-log", $vivadoNativeLogPathForVivado,
    "-journal", $vivadoJournalPathForVivado,
    "-tempDir", $vivadoTempDirForVivado,
    "-source", $tclPathForVivado,
    "-tclargs",
    "-repo_root", $repoRootForVivado,
    "-out_dir", $resolvedOutDirForVivado,
    "-top", $Top,
    "-run_synth_only", $runSynthOnly,
    "-run_impl", $runImpl,
    "-generate_bitstream", $generateBitstream,
    "-opt_directive", $OptDirective,
    "-place_directive", $PlaceDirective,
    "-phys_opt_directive", $PhysOptDirective,
    "-route_directive", $RouteDirective
)

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    $output = & $vivadoPath @vivadoArgs 2>&1
    $exitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
$output | Set-Content -Path $logPath -Encoding Ascii

$postSynthTiming = Read-TimingReportSummary (Join-Path $reportDir "post_synth_timing_summary.rpt")
$postRouteTiming = Read-TimingReportSummary (Join-Path $reportDir "post_route_timing_summary.rpt")
$postSynthUtilization = Read-UtilizationReport (Join-Path $reportDir "post_synth_utilization.rpt")
$postRouteUtilization = Read-UtilizationReport (Join-Path $reportDir "post_route_utilization.rpt")
$postSynthCriticalPath = Read-CriticalPathSummary (Join-Path $reportDir "post_synth_critical_paths.rpt")
$postRouteCriticalPath = Read-CriticalPathSummary (Join-Path $reportDir "post_route_critical_paths.rpt")
$postSynthClocks = Read-ClockReport (Join-Path $reportDir "post_synth_clocks.rpt")
$postRouteClocks = Read-ClockReport (Join-Path $reportDir "post_route_clocks.rpt")
$postSynthDrc = Read-DrcReportSummary (Join-Path $reportDir "post_synth_drc.rpt")
$postRouteDrc = Read-DrcReportSummary (Join-Path $reportDir "post_route_drc.rpt")
$peakMemoryMb = Get-PeakMemoryMb (($output | Out-String))

$timingStatus = "not_run"
$timingClosureStatus = "not_run"
$timingConstraintStatus = "not_run"
if ($Implementation) {
    if ($postRouteTiming.present -and
        [int]$postRouteTiming.no_clock_count -eq 0 -and
        [int]$postRouteTiming.unconstrained_internal_endpoint_count -eq 0 -and
        [int]$postRouteTiming.no_input_delay_count -eq 0 -and
        [int]$postRouteTiming.no_output_delay_count -eq 0) {
        $timingConstraintStatus = "pass"
    } elseif ($postRouteTiming.present) {
        $timingConstraintStatus = "fail"
    }
    if ($postRouteTiming.present -and
        $null -ne $postRouteTiming.wns_ns -and
        $null -ne $postRouteTiming.tns_ns -and
        $null -ne $postRouteTiming.whs_ns -and
        $null -ne $postRouteTiming.ths_ns) {
        if ([double] $postRouteTiming.wns_ns -ge 0.0 -and
            [double] $postRouteTiming.tns_ns -eq 0.0 -and
            [double] $postRouteTiming.whs_ns -ge 0.0 -and
            [double] $postRouteTiming.ths_ns -eq 0.0) {
            $timingStatus = "pass"
            $timingClosureStatus = "met"
        } else {
            $timingStatus = "fail"
            $timingClosureStatus = "not_met"
        }
    } elseif ($postRouteTiming.present) {
        $timingStatus = "unknown"
        $timingClosureStatus = "unknown"
    }
} elseif ($postSynthTiming.present) {
    $timingStatus = "synth_timing_report_only"
}
if ($exitCode -ne 0 -and $Implementation) {
    $timingStatus = "fail"
    $timingClosureStatus = "not_met_or_unverified"
}
$drcStatus = if ($Implementation) {
    if ($postRouteDrc.present -and $postRouteDrc.release_approved) { "pass" } else { "fail" }
} elseif ($postSynthDrc.present) {
    if ($postSynthDrc.release_approved) { "pass" } else { "fail" }
} else {
    "not_run"
}

$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = if ($exitCode -eq 0) { "pass" } else { "fail" }
    mode = $mode
    exit_code = $exitCode
    vivado = $detectSummary.tool
    part = "xc7a35tcpg236-1"
    top = $Top
    source_commit = $sourceCommit
    working_tree_dirty = $workingTreeDirty
    source_fingerprint = $buildInputIdentity.fingerprint
    verification_input_fingerprint = $verificationIdentity.verification_input_fingerprint
    verification_input_count = $verificationIdentity.verification_input_count
    verification_working_tree_dirty = $verificationIdentity.verification_working_tree_dirty
    source_inputs = $buildInputIdentity.inputs
    tcl = $tclPath
    out_dir = Get-RepoRelativePathIfPresent $resolvedOutDir
    log = $logPath
    vivado_log = $vivadoNativeLogPath
    vivado_journal = $vivadoJournalPath
    vivado_temp_dir = $vivadoTempDir
    command = "vivado -mode batch -log $vivadoNativeLogPathForVivado -journal $vivadoJournalPathForVivado -tempDir $vivadoTempDirForVivado -source $tclPathForVivado -tclargs -repo_root $repoRootForVivado -out_dir $resolvedOutDirForVivado -top $Top -run_synth_only $runSynthOnly -run_impl $runImpl -generate_bitstream $generateBitstream -opt_directive $OptDirective -place_directive $PlaceDirective -phys_opt_directive $PhysOptDirective -route_directive $RouteDirective"
    peak_memory_mb = $peakMemoryMb
    synth_status = if ($exitCode -eq 0) { "pass" } else { "fail" }
    implementation_status = if ($Implementation) { if ($exitCode -eq 0) { "pass" } else { "fail" } } else { "not_run" }
    timing_status = $timingStatus
    timing_closure_status = $timingClosureStatus
    timing_constraint_status = $timingConstraintStatus
    implementation_strategy = [ordered]@{
        opt_directive = $OptDirective
        place_directive = $PlaceDirective
        phys_opt_directive = $PhysOptDirective
        route_directive = $RouteDirective
    }
    drc_status = $drcStatus
    bitstream_status = if ($Bitstream) { if ($exitCode -eq 0 -and (Test-Path -LiteralPath $bitstreamPath)) { "pass" } else { "not_generated" } } else { "not_run" }
    reports = [ordered]@{
        post_synth_utilization = $postSynthUtilization
        post_synth_timing = $postSynthTiming
        post_synth_critical_path = $postSynthCriticalPath
        post_synth_clocks = $postSynthClocks
        post_synth_drc = $postSynthDrc
        post_route_utilization = $postRouteUtilization
        post_route_timing = $postRouteTiming
        post_route_critical_path = $postRouteCriticalPath
        post_route_clocks = $postRouteClocks
        post_route_drc = $postRouteDrc
        post_route_timing_exceptions = if (Test-Path -LiteralPath (Join-Path $reportDir "post_route_timing_exceptions.rpt")) {
            Get-RepoRelativePathIfPresent (Join-Path $reportDir "post_route_timing_exceptions.rpt")
        } else {
            $null
        }
    }
    bitstream = if ($exitCode -eq 0 -and (Test-Path -LiteralPath $bitstreamPath)) { Get-RepoRelativePathIfPresent $bitstreamPath } else { $null }
    physical_validation_status = "not_run"
    claim_boundary = "Timing closure is only claimed if Vivado implementation timing report passes. Bitstream generation does not equal board validation."
}

$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $summaryPath -Encoding Ascii

Write-Host "========================================"
Write-Host "Basys3 Vivado build"
Write-Host ("Status: {0}" -f $summary.status)
Write-Host ("Mode: {0}" -f $summary.mode)
Write-Host ("Top: {0}" -f $summary.top)
Write-Host ("Timing status: {0}" -f $summary.timing_status)
Write-Host ("Timing closure status: {0}" -f $summary.timing_closure_status)
Write-Host ("Timing constraint status: {0}" -f $summary.timing_constraint_status)
Write-Host ("DRC status: {0}" -f $summary.drc_status)
if ($postRouteTiming.present) {
    Write-Host ("Post-route timing: WNS {0} ns, TNS {1} ns, WHS {2} ns, THS {3} ns" -f $postRouteTiming.wns_ns, $postRouteTiming.tns_ns, $postRouteTiming.whs_ns, $postRouteTiming.ths_ns)
}
if ($postRouteDrc.present) {
    Write-Host ("Post-route DRC: errors {0}, critical warnings {1}, unapproved warnings {2}, REQP-1839 {3}, parse complete {4}" -f $postRouteDrc.error_count, $postRouteDrc.critical_warning_count, $postRouteDrc.unapproved_warning_count, $postRouteDrc.bram_async_control_warning_count, $postRouteDrc.report_parse_complete)
}
Write-Host ("Bitstream status: {0}" -f $summary.bitstream_status)
Write-Host ("Peak Vivado memory: {0} MB" -f $summary.peak_memory_mb)
Write-Host ("Physical validation status: {0}" -f $summary.physical_validation_status)
Write-Host ("Summary: {0}" -f $summaryPath)

if ($exitCode -ne 0) {
    throw "Vivado Basys3 build failed; see $logPath"
}
