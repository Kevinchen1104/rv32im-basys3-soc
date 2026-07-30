<#
Script: scripts\canonical-basys3-evidence.ps1
Purpose: Resolves and validates the source-matched canonical Basys3 bitstream evidence used by physical host tools.
Common usage:
  Dot-source this helper from an authorized Basys3 physical host script, then call Get-CanonicalBasys3Evidence.
Outputs:
  An in-memory evidence record; no files, processes, hardware sessions, or serial connections are created.
Scope:
  Read-only metadata, source-fingerprint, manifest, and local bitstream checks. This script never starts Vivado or XSDB, opens hardware, or accesses a serial port.
Audience:
  Public Basys3 host tools that must reject stale or source-mismatched bitstreams before physical operations.
#>

. "$PSScriptRoot\basys3-physical-evidence.ps1"
. "$PSScriptRoot\verification-source-identity.ps1"

function Get-CanonicalBasys3BuildInputIdentity {
    $inputPaths = [System.Collections.Generic.List[string]]::new()
    $inputPaths.Add("fpga\fpga_sources.f") | Out-Null
    foreach ($line in Get-Content -LiteralPath "fpga\fpga_sources.f") {
        $candidate = $line.Trim()
        if ($candidate -ne "" -and -not $candidate.StartsWith("#")) {
            $inputPaths.Add($candidate.Replace("/", "\")) | Out-Null
        }
    }
    $inputPaths.Add("fpga\vivado\basys3_build.tcl") | Out-Null
    $inputPaths.Add("fpga\boards\basys3\basys3.xdc") | Out-Null

    $records = @(
        foreach ($path in @($inputPaths | Sort-Object -Unique)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Canonical fingerprint input missing: $path"
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
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($identityText)
        $fingerprint = [System.BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace("-", "").ToLowerInvariant()
    } finally {
        $hasher.Dispose()
    }
    return [ordered]@{ fingerprint = $fingerprint; inputs = $records }
}

function Get-CanonicalBasys3Evidence {
    param(
        [string] $RequestedBitstreamPath = "",
        [string] $RequestedSha256 = "",
        [long] $RequestedSizeBytes = 0,
        [switch] $AllowPendingPhysicalEvidence
    )

    function Read-RequiredJson([string] $Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "Required canonical evidence is missing: $Path"
        }
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    function Resolve-EvidencePath([string] $Path) {
        if ([System.IO.Path]::IsPathRooted($Path)) {
            return [System.IO.Path]::GetFullPath($Path)
        }
        return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
    }
    function Normalize-EvidenceHash([string] $Hash) {
        if ([string]::IsNullOrWhiteSpace($Hash) -or $Hash -notmatch '^[0-9A-Fa-f]{64}$') {
            throw "Canonical evidence SHA256 must contain exactly 64 hexadecimal characters."
        }
        return $Hash.ToLowerInvariant()
    }

    $board = Read-RequiredJson "fpga\boards\basys3\board.json"
    $vivado = Read-RequiredJson "wave\vivado-basys3-build-summary.json"
    $robustness = Read-RequiredJson "wave\vivado-basys3-robustness-summary.json"
    $identity = Get-CanonicalBasys3BuildInputIdentity
    $verificationIdentity = Get-VerificationSourceIdentity
    $release = if ($AllowPendingPhysicalEvidence) {
        $null
    } else {
        Read-RequiredJson "release\fpga\basys3\status.json"
    }
    $physical = if ($AllowPendingPhysicalEvidence) {
        $null
    } else {
        Get-Basys3PhysicalEvidence
    }

    if ($board.fpga_part -ne "xc7a35tcpg236-1" -or $board.top_module -ne "RISCVCPU_basys3_top") {
        throw "Basys3 board metadata does not identify the canonical direct target."
    }
    if ($vivado.status -ne "pass" -or $vivado.mode -ne "bitstream" -or
        $vivado.top -ne "RISCVCPU_basys3_top" -or $vivado.implementation_status -ne "pass" -or
        $vivado.timing_closure_status -ne "met" -or
        $vivado.timing_constraint_status -ne "pass" -or
        $vivado.bitstream_status -ne "pass") {
        throw "Vivado summary is not a passing canonical implementation/bitstream result."
    }
    $postRoute = $vivado.reports.post_route_timing
    if ($null -eq $postRoute -or
        $null -eq $postRoute.wns_ns -or [double]$postRoute.wns_ns -lt 0.0 -or
        $null -eq $postRoute.tns_ns -or [double]$postRoute.tns_ns -ne 0.0 -or
        $null -eq $postRoute.whs_ns -or [double]$postRoute.whs_ns -lt 0.0 -or
        $null -eq $postRoute.ths_ns -or [double]$postRoute.ths_ns -ne 0.0 -or
        $null -eq $postRoute.no_clock_count -or [int]$postRoute.no_clock_count -ne 0 -or
        $null -eq $postRoute.unconstrained_internal_endpoint_count -or
            [int]$postRoute.unconstrained_internal_endpoint_count -ne 0 -or
        $null -eq $postRoute.no_input_delay_count -or [int]$postRoute.no_input_delay_count -ne 0 -or
        $null -eq $postRoute.no_output_delay_count -or [int]$postRoute.no_output_delay_count -ne 0) {
        throw "Canonical Vivado evidence requires complete internal and board-I/O timing constraints."
    }
    $postRouteDrc = $vivado.reports.post_route_drc
    if ($vivado.drc_status -ne "pass" -or
        $null -eq $postRouteDrc -or
        $postRouteDrc.present -ne $true -or
        $postRouteDrc.report_parse_complete -ne $true -or
        $postRouteDrc.release_approved -ne $true -or
        [int]$postRouteDrc.error_count -ne 0 -or
        [int]$postRouteDrc.critical_warning_count -ne 0 -or
        [int]$postRouteDrc.unapproved_warning_count -ne 0 -or
        [int]$postRouteDrc.bram_async_control_warning_count -ne 0) {
        throw "Canonical Vivado evidence requires a complete, release-approved DRC report."
    }
    if ($vivado.source_fingerprint -ne $identity.fingerprint) {
        throw "Current authoritative synthesis inputs do not match the canonical fingerprint."
    }
    $failedRobustnessRuns = @(
        $robustness.runs | Where-Object {
            $_.status -ne "pass" -or
            $_.implementation_status -ne "pass" -or
            $_.timing_closure_status -ne "met" -or
            $_.timing_constraint_status -ne "pass" -or
            [double]$_.wns_ns -lt 0.0 -or
            [double]$_.tns_ns -ne 0.0 -or
            [double]$_.whs_ns -lt 0.0 -or
            [double]$_.ths_ns -ne 0.0 -or
            [int]$_.no_clock_count -ne 0 -or
            [int]$_.unconstrained_internal_endpoint_count -ne 0 -or
            [int]$_.no_input_delay_count -ne 0 -or
            [int]$_.no_output_delay_count -ne 0 -or
            $_.drc_status -ne "pass" -or
            [int]$_.drc_error_count -ne 0 -or
            [int]$_.drc_critical_warning_count -ne 0 -or
            [int]$_.drc_unapproved_warning_count -ne 0 -or
            [int]$_.bram_async_control_warning_count -ne 0
        }
    )
    if ($robustness.status -ne "pass" -or
        $robustness.top -ne "RISCVCPU_basys3_top" -or
        [int]$robustness.run_count -ne 5 -or
        $robustness.all_implementations_passed -ne $true -or
        $robustness.identity_consistent -ne $true -or
        [string]$robustness.source_commit -ne [string]$vivado.source_commit -or
        $robustness.working_tree_dirty -ne $false -or
        [string]$robustness.source_fingerprint -ne $identity.fingerprint -or
        [string]$robustness.verification_input_fingerprint -ne
            $verificationIdentity.verification_input_fingerprint -or
        [int]$robustness.verification_input_count -ne
            $verificationIdentity.verification_input_count -or
        $robustness.verification_working_tree_dirty -ne $false -or
        @($robustness.runs).Count -ne 5 -or
        $failedRobustnessRuns.Count -ne 0) {
        throw "Canonical Basys3 evidence requires five source-matched, timing-closed implementation strategies."
    }
    if ($vivado.working_tree_dirty -ne $false -or
        [string]::IsNullOrWhiteSpace([string]$vivado.source_commit)) {
        throw "Canonical Vivado evidence must identify a clean committed synthesis revision."
    }
    if ([string]$vivado.verification_input_fingerprint -ne $verificationIdentity.verification_input_fingerprint -or
        [int]$vivado.verification_input_count -ne $verificationIdentity.verification_input_count -or
        $vivado.verification_working_tree_dirty -ne $false -or
        $verificationIdentity.verification_working_tree_dirty) {
        throw "Canonical Vivado evidence does not match the committed verification-source identity."
    }
    if (-not $AllowPendingPhysicalEvidence) {
        if ($release.status -ne "pass" -or $release.package_kind -ne "evidence_only" -or
            $release.board_profile -ne "basys3" -or $release.vivado_evidence_status -ne "current") {
            throw "Basys3 release status is not current evidence-only Vivado evidence."
        }
        if ($release.source_commit -ne $vivado.source_commit) {
            throw "Release and Vivado synthesis source commits do not match."
        }
        if ($release.source_fingerprint -ne $identity.fingerprint) {
            throw "Release evidence does not match the canonical fingerprint."
        }
        if ([string]$release.verification_input_fingerprint -ne $verificationIdentity.verification_input_fingerprint -or
            [int]$release.verification_input_count -ne $verificationIdentity.verification_input_count -or
            $release.verification_working_tree_dirty -ne $false) {
            throw "Release evidence does not match the committed verification-source identity."
        }
    }

    $identityCount = @($identity.inputs).Count
    $rtlSourceCount = @(
        Get-Content -LiteralPath "fpga\fpga_sources.f" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne "" -and -not $_.StartsWith("#") }
    ).Count
    $expectedIdentityCount = $rtlSourceCount + 3
    if ($identityCount -ne $expectedIdentityCount -or
        @($vivado.source_inputs).Count -ne $identityCount) {
        throw "Canonical source inventory count is inconsistent."
    }
    if (-not $AllowPendingPhysicalEvidence -and
        ([int]$release.rtl_source_count -ne $rtlSourceCount -or
         [int]$release.fingerprint_input_count -ne $identityCount)) {
        throw "Packaged canonical source inventory count is inconsistent."
    }
    foreach ($record in $identity.inputs) {
        $matches = @($vivado.source_inputs | Where-Object { $_.path -eq $record.path })
        if ($matches.Count -ne 1 -or $matches[0].sha256 -ne $record.sha256) {
            throw "Vivado source-input record does not match current file: $($record.path)"
        }
    }

    $repoManifestHash = (Get-FileHash -LiteralPath "fpga\fpga_sources.f" -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not $AllowPendingPhysicalEvidence) {
        $packagedManifestHash = (Get-FileHash -LiteralPath "release\fpga\basys3\fpga_sources.f" -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($repoManifestHash -ne $packagedManifestHash) {
            throw "Packaged FPGA source manifest does not match the authoritative manifest."
        }
    }

    $postRoute = $vivado.reports.post_route_timing
    if ($null -eq $postRoute.wns_ns -or [double]$postRoute.wns_ns -lt 0.0 -or
        $null -eq $postRoute.tns_ns -or [double]$postRoute.tns_ns -ne 0.0) {
        throw "Canonical post-route WNS/TNS requirements are not met."
    }
    $postRouteDrc = $vivado.reports.post_route_drc
    if ($null -eq $postRouteDrc -or $postRouteDrc.present -ne $true -or
        $postRouteDrc.report_parse_complete -ne $true -or
        $postRouteDrc.release_approved -ne $true -or
        [int]$postRouteDrc.error_count -ne 0 -or
        [int]$postRouteDrc.critical_warning_count -ne 0 -or
        [int]$postRouteDrc.unapproved_warning_count -ne 0 -or
        [int]$postRouteDrc.bram_async_control_warning_count -ne 0) {
        throw "Canonical post-route DRC requirements are not met."
    }
    if (-not $AllowPendingPhysicalEvidence) {
        if ($release.physical_validation_status -ne $physical.physical_validation_status -or
            $release.physical_validation_scope -ne $physical.physical_validation_scope -or
            $board.full_direct_100mhz_physical_validation_status -ne $physical.physical_validation_status -or
            $board.full_direct_100mhz_physical_validation_scope -ne $physical.physical_validation_scope -or
            $physical.source_commit -ne $release.source_commit -or
            $physical.source_fingerprint -ne $identity.fingerprint) {
            throw "Scoped physical evidence does not match the canonical source identity and release metadata."
        }
    }

    $canonicalPath = if ($AllowPendingPhysicalEvidence) {
        [string]$vivado.bitstream
    } else {
        [string]$release.bitstream_build_path
    }
    $canonicalHash = if ($AllowPendingPhysicalEvidence) {
        Normalize-EvidenceHash ((Get-FileHash -LiteralPath $canonicalPath -Algorithm SHA256).Hash)
    } else {
        Normalize-EvidenceHash ([string]$release.bitstream_sha256)
    }
    $canonicalSize = if ($AllowPendingPhysicalEvidence) {
        [long](Get-Item -LiteralPath $canonicalPath).Length
    } else {
        [long]$release.bitstream_size_bytes
    }
    if ([string]::IsNullOrWhiteSpace($canonicalPath) -or $canonicalSize -le 0) {
        throw "Release status does not identify a canonical local bitstream."
    }
    if ((Resolve-EvidencePath ([string]$vivado.bitstream)) -ne (Resolve-EvidencePath $canonicalPath)) {
        throw "Vivado summary and release status identify different bitstream paths."
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestedBitstreamPath) -and
        (Resolve-EvidencePath $RequestedBitstreamPath) -ne (Resolve-EvidencePath $canonicalPath)) {
        throw "Requested bitstream path does not match current release evidence."
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestedSha256) -and
        (Normalize-EvidenceHash $RequestedSha256) -ne $canonicalHash) {
        throw "Requested SHA256 does not match current release evidence."
    }
    if ($RequestedSizeBytes -gt 0 -and $RequestedSizeBytes -ne $canonicalSize) {
        throw "Requested size does not match current release evidence."
    }

    $resolvedBitstream = Resolve-EvidencePath $canonicalPath
    if (-not (Test-Path -LiteralPath $resolvedBitstream -PathType Leaf)) {
        throw "Canonical local bitstream is missing: $canonicalPath"
    }
    $bitstreamItem = Get-Item -LiteralPath $resolvedBitstream
    $actualHash = (Get-FileHash -LiteralPath $resolvedBitstream -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($bitstreamItem.Length -ne $canonicalSize -or $actualHash -ne $canonicalHash) {
        throw "Canonical local bitstream size or SHA256 does not match release evidence."
    }

    if (-not $AllowPendingPhysicalEvidence) {
        if ([string]$board.full_direct_100mhz_source_commit -ne [string]$release.source_commit -or
            [string]$board.full_direct_100mhz_source_fingerprint -ne $identity.fingerprint -or
            (Resolve-EvidencePath ([string]$board.full_direct_100mhz_bitstream_path)) -ne $resolvedBitstream -or
            [long]$board.full_direct_100mhz_bitstream_size_bytes -ne $canonicalSize -or
            (Normalize-EvidenceHash ([string]$board.full_direct_100mhz_bitstream_sha256)) -ne $canonicalHash) {
            throw "Descriptive Basys3 board metadata does not match canonical release evidence."
        }
    }

    return [ordered]@{
        bitstream_path = $canonicalPath
        bitstream_absolute_path = $resolvedBitstream
        bitstream_sha256 = $canonicalHash
        bitstream_size_bytes = $canonicalSize
        source_commit = [string]$vivado.source_commit
        repository_head = (& git rev-parse HEAD 2>$null).Trim()
        source_fingerprint = $identity.fingerprint
        verification_input_fingerprint = $verificationIdentity.verification_input_fingerprint
        verification_input_count = $verificationIdentity.verification_input_count
        rtl_source_count = $rtlSourceCount
        fingerprint_input_count = $identityCount
        robustness_run_count = [int]$robustness.run_count
        robustness_worst_wns_ns = [double]$robustness.worst_wns_ns
        robustness_best_wns_ns = [double]$robustness.best_wns_ns
        robustness_margin_target_status = [string]$robustness.margin_target_status
        manifest_sha256 = $repoManifestHash
        physical_validation_status = if ($AllowPendingPhysicalEvidence) { "not_run" } else { $physical.physical_validation_status }
        physical_validation_scope = if ($AllowPendingPhysicalEvidence) { "needs_revalidation" } else { $physical.physical_validation_scope }
        physical_evidence_summary_path = if ($AllowPendingPhysicalEvidence) { $null } else { $physical.summary_path }
        physical_evidence_summary_sha256 = if ($AllowPendingPhysicalEvidence) { $null } else { $physical.summary_sha256 }
    }
}
