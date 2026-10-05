<#
Script: scripts\basys3-physical-evidence.ps1
Purpose: Validates the durable scoped physical-evidence suite for the canonical direct-100-MHz Basys3 target.
Common usage:
  Dot-source this helper and call Get-Basys3PhysicalEvidence; add -VerifyCaptureSources during evidence promotion.
Outputs:
  An in-memory validated evidence record; no hardware, serial port, tool process, or file is created.
Scope:
  Integrity and claim-boundary checks for tracked physical evidence, with optional local results/packet source checks.
#>

. "$PSScriptRoot/release-package.ps1"

function Read-Basys3BoardRun {
    param([string]$SummaryPath)
    $directory = Split-Path -Parent $SummaryPath
    $record = Read-ReleaseJson $SummaryPath
    Assert-ReleaseManifest $directory | Out-Null
    $build = Read-ReleaseJson (Join-Path $directory 'build.json')
    Assert-ImplementationResult $build
    $identity = $record.canonical_identity
    if ($record.status -ne 'pass' -or $record.physical_validation_status -ne 'passed' -or
        $record.top -ne 'RISCVCPU_basys3_top' -or $record.soc_clock_mhz -ne 100 -or
        $identity.source_fingerprint -ne $build.source_fingerprint -or
        $identity.synthesis_source_commit -ne $build.source_commit -or
        $record.operator.reset_button_confirmed -cne $true -or -not $record.operator.led_observation) {
        throw 'Incomplete board-run identity or operator observations.'
    }
    $names = @('Showcase', 'Interactive', 'HardwareValidation', 'Matvec', 'MatvecReset')
    if (@($record.uart_runs).Count -ne $names.Count) { throw 'Board-run case count differs.' }
    $cases = @{}
    foreach ($name in $names) {
        $capture = Read-ReleaseJson (Join-Path $directory "captures/$name/summary.json")
        $programName = if ($name -eq 'MatvecReset') { 'Matvec' } else { $name }
        $program = Read-ReleaseJson (Join-Path $directory "captures/$programName/program.json")
        if ($capture.status -ne 'pass' -or $capture.transcript_match -cne $true -or
            $capture.bitstream_sha256 -ne $identity.bitstream_sha256 -or
            $capture.bitstream_source_fingerprint -ne $identity.source_fingerprint -or
            $program.status -ne 'pass' -or $program.configuration_verified -cne $true -or
            $program.bitstream_sha256 -ne $identity.bitstream_sha256 -or $program.target_count -ne 1) {
            throw "Board capture/program identity failed: $name"
        }
        if ($name -like 'Matvec*') {
            $comparison = Read-ReleaseJson (Join-Path $directory "captures/$name/comparison.json")
            $transcript = Join-Path $directory "captures/$name/uart.txt"
            $csv = Join-Path $directory "captures/$name/measurements.csv"
            if ($comparison.status -ne 'passed' -or $comparison.cases_passed -ne 90 -or
                $comparison.outputs_checked -ne 2418 -or
                (Get-FileHash $transcript).Hash.ToLowerInvariant() -ne $comparison.transcript_sha256 -or
                (Get-FileHash $csv).Hash.ToLowerInvariant() -ne $comparison.measurements_sha256) {
                throw "MATVEC comparison evidence failed: $name"
            }
        }
        $cases[$name] = [ordered]@{ status='pass'; port=$capture.port; baud=$capture.baud }
    }
    [ordered]@{
        status='pass'; evidence_root=$directory.Replace('\','/'); summary_path=$SummaryPath.Replace('\','/')
        summary_sha256=(Get-FileHash $SummaryPath).Hash.ToLowerInvariant()
        physical_validation_status='passed'; physical_validation_scope=$record.physical_validation_scope
        date_local=$record.date_local; source_commit=$identity.synthesis_source_commit
        source_fingerprint=$identity.source_fingerprint; bitstream_sha256=$identity.bitstream_sha256
        bitstream_size_bytes=$identity.bitstream_size_bytes; cases=$cases
        programming_evidence_level='machine_captured'; uart_evidence_level='machine_captured'
        led_reset_evidence_level='operator_reported'
    }
}

# Adapt the recorded measurement to the existing evidence validators in memory.
# Hardware configuration and historical measurements have separate disk sources.
function Get-Basys3RecordedProfile {
    $board = Get-Content 'fpga/boards/basys3/board.json' -Raw | ConvertFrom-Json
    $path = [string]$board.recorded_physical_evidence
    if ($path -notmatch '^docs/fpga/board_evidence/[^/]+/summary\.json$') { throw 'Invalid recorded board evidence path.' }
    $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $identity = $record.canonical_identity
    $fields = @{
        full_direct_100mhz_physical_evidence=$path
        full_direct_100mhz_source_commit=$identity.synthesis_source_commit
        full_direct_100mhz_source_fingerprint=$identity.source_fingerprint
        full_direct_100mhz_fingerprint_input_count=$identity.fingerprint_input_count
        full_direct_100mhz_bitstream_path=$identity.bitstream_build_path
        full_direct_100mhz_bitstream_size_bytes=$identity.bitstream_size_bytes
        full_direct_100mhz_bitstream_sha256=$identity.bitstream_sha256
        full_direct_100mhz_vivado_version=$record.post_route_timing.vivado_version
        full_direct_100mhz_physical_validation_date=$record.date_local
        full_direct_100mhz_physical_validation_status=$record.physical_validation_status
        full_direct_100mhz_physical_validation_scope=$record.physical_validation_scope
        physical_validation_status=$record.physical_validation_status
        physical_validation_scope=$record.physical_validation_scope
    }
    foreach ($metric in @('wns_ns','tns_ns','whs_ns','ths_ns')) { $fields["full_direct_100mhz_$metric"] = $record.post_route_timing.$metric }
    foreach ($key in $fields.Keys) { $board | Add-Member -NotePropertyName $key -NotePropertyValue $fields[$key] }
    return $board
}

function Resolve-Basys3CapturePath {
    param([string]$Path, [string]$EvidenceRoot)
    # Original summaries remain byte-identical. Their historical wave/ paths
    # resolve to the preserved raw captures bundled beside the durable record.
    if ($Path.Replace('\','/').StartsWith('wave/')) {
        return Join-Path $EvidenceRoot ('captures/' + [IO.Path]::GetFileName($Path))
    }
    return $Path
}

function Get-Basys3PhysicalEvidence {
    param([switch] $VerifyCaptureSources)

    $boardPath = "fpga\boards\basys3\board.json"
    if (-not (Test-Path -LiteralPath $boardPath -PathType Leaf)) {
        throw "Basys3 board identity manifest is missing: $boardPath"
    }
    $board = Get-Basys3RecordedProfile
    $summaryPath = [string]$board.full_direct_100mhz_physical_evidence
    $normalizedSummaryPath = $summaryPath.Replace("\", "/")
    if ([string]::IsNullOrWhiteSpace($summaryPath) -or
        $normalizedSummaryPath -notmatch '^docs/fpga/board_evidence/[^/]+/summary\.json$' -or
        [System.IO.Path]::GetFileName($summaryPath) -ne "summary.json") {
        throw "Basys3 board identity manifest does not select a durable physical summary."
    }
    $evidenceRoot = Split-Path -Parent $summaryPath
    if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
        throw "Basys3 physical evidence summary is missing: $summaryPath"
    }
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    if ($summary.schema_version -eq 2) { return Read-Basys3BoardRun $summaryPath }
    $expectedSourceCommit = [string]$board.full_direct_100mhz_source_commit
    $expectedFingerprint = [string]$board.full_direct_100mhz_source_fingerprint
    $expectedBitstreamHash = [string]$board.full_direct_100mhz_bitstream_sha256
    $expectedBitstreamPath = ([string]$board.full_direct_100mhz_bitstream_path).Replace("\", "/")
    $expectedBitstreamSize = [long]$board.full_direct_100mhz_bitstream_size_bytes
    $expectedInputCount = [int]$board.full_direct_100mhz_fingerprint_input_count
    $expectedDate = [string]$board.full_direct_100mhz_physical_validation_date
    $expectedScope = [string]$board.full_direct_100mhz_physical_validation_scope
    foreach ($timingProperty in @(
        "full_direct_100mhz_wns_ns",
        "full_direct_100mhz_tns_ns",
        "full_direct_100mhz_whs_ns",
        "full_direct_100mhz_ths_ns"
    )) {
        if ($null -eq $board.$timingProperty) {
            throw "Basys3 board identity manifest is missing timing property: $timingProperty"
        }
    }
    $expectedWns = [double]$board.full_direct_100mhz_wns_ns
    $expectedTns = [double]$board.full_direct_100mhz_tns_ns
    $expectedWhs = [double]$board.full_direct_100mhz_whs_ns
    $expectedThs = [double]$board.full_direct_100mhz_ths_ns
    $vivadoVersionMatch = [regex]::Match(
        [string]$board.full_direct_100mhz_vivado_version,
        '[0-9]{4}\.[0-9]+'
    )
    if ([string]::IsNullOrWhiteSpace($expectedSourceCommit) -or
        $expectedSourceCommit -notmatch '^[0-9a-f]{40}$' -or
        $expectedFingerprint -notmatch '^[0-9a-f]{64}$' -or
        $expectedBitstreamHash -notmatch '^[0-9a-f]{64}$' -or
        [string]::IsNullOrWhiteSpace($expectedBitstreamPath) -or
        $expectedBitstreamSize -le 0 -or $expectedInputCount -le 0 -or
        [string]::IsNullOrWhiteSpace($expectedDate) -or
        [string]::IsNullOrWhiteSpace($expectedScope) -or
        -not $vivadoVersionMatch.Success) {
        throw "Basys3 board identity manifest is incomplete or malformed."
    }
    $expectedVivadoVersion = $vivadoVersionMatch.Value

    if ($summary.status -ne "pass" -or $summary.physical_validation_status -ne "passed" -or
        $summary.physical_validation_scope -ne $expectedScope -or
        $summary.date_local -ne $expectedDate -or $summary.timezone -ne "Asia/Taipei" -or
        $summary.board -ne "Digilent Basys3" -or $summary.fpga_part -ne "xc7a35tcpg236-1" -or
        $summary.top -ne $board.top_module -or
        [int]$summary.soc_clock_mhz -ne ([int]$board.full_direct_100mhz_soc_clock_hz / 1000000) -or
        $board.full_direct_100mhz_physical_validation_status -ne "passed") {
        throw "Basys3 physical evidence target/status metadata is inconsistent."
    }
    $identity = $summary.canonical_identity
    if ($identity.synthesis_source_commit -ne $expectedSourceCommit -or
        $identity.source_fingerprint -ne $expectedFingerprint -or
        [int]$identity.fingerprint_input_count -ne $expectedInputCount -or
        $identity.bitstream_build_path -ne $expectedBitstreamPath -or
        [long]$identity.bitstream_size_bytes -ne $expectedBitstreamSize -or
        $identity.bitstream_sha256 -ne $expectedBitstreamHash -or
        $identity.identity_evidence_level -ne "host_verified_before_xsdb_programming" -or
        $identity.on_board_readback_or_hash_verification -ne "not_performed") {
        throw "Basys3 physical evidence canonical identity is inconsistent."
    }
    $timing = $summary.post_route_timing
    if ($timing.vivado_version -ne $expectedVivadoVersion -or
        $timing.status -ne "met" -or [double]$timing.wns_ns -ne $expectedWns -or
        [double]$timing.tns_ns -ne $expectedTns -or
        [double]$timing.whs_ns -ne $expectedWhs -or
        [double]$timing.ths_ns -ne $expectedThs) {
        throw "Basys3 physical evidence timing identity is inconsistent."
    }
    $programming = $summary.programming
    if ($programming.status -ne "pass" -or
        $programming.evidence_level -ne "machine_captured" -or
        $programming.method -ne "amd_xsdb_jtag" -or
        $programming.xsdb_version -ne $expectedVivadoVersion -or
        $programming.hardware_connected -ne $true -or
        [int]$programming.target_count -ne 1 -or
        $programming.selected_target -ne "target_id=1 name=xc7a35t jtag_device_name=xc7a35t jtag_device_id=2" -or
        $programming.device_programmed -ne $true -or
        $programming.configuration_verified -ne $true -or
        $programming.configuration_state -ne "FPGA is configured" -or
        [int]$programming.retry_count -ne 0 -or
        $programming.cleanup_error -ne "" -or
        $programming.on_board_identity_verification -ne "configured_state_only; bitstream readback or hash verification not performed") {
        throw "Basys3 XSDB programming evidence is incomplete or overstates its identity boundary."
    }
    $programmingSummaryPath = [string]$programming.source_summary_path
    if (-not (Test-Path -LiteralPath $programmingSummaryPath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $programmingSummaryPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $programming.source_summary_sha256) {
        throw "Basys3 durable XSDB programming summary hash mismatch."
    }
    $programmingSummary = Get-Content -LiteralPath $programmingSummaryPath -Raw | ConvertFrom-Json
    if ($programmingSummary.status -ne "pass" -or
        $programmingSummary.bitstream_sha256 -ne $expectedBitstreamHash -or
        $programmingSummary.synthesis_source_commit -ne $expectedSourceCommit -or
        $programmingSummary.source_fingerprint -ne $expectedFingerprint -or
        $programmingSummary.canonical_match -ne $true -or
        $programmingSummary.hardware_connected -ne $true -or
        [int]$programmingSummary.target_count -ne 1 -or
        $programmingSummary.device_programmed -ne $true -or
        $programmingSummary.configuration_verified -ne $true -or
        [int]$programmingSummary.retry_count -ne 0) {
        throw "Basys3 durable XSDB programming summary content mismatch."
    }
    if ($VerifyCaptureSources) {
        $programmingCapturePath = Resolve-Basys3CapturePath $programming.capture_source_path $evidenceRoot
        if (-not (Test-Path -LiteralPath $programmingCapturePath -PathType Leaf) -or
            (Get-FileHash -LiteralPath $programmingCapturePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $programming.capture_source_sha256) {
            throw "Basys3 source XSDB programming summary hash mismatch."
        }
        $programmingCapture = Get-Content -LiteralPath $programmingCapturePath -Raw | ConvertFrom-Json
        if ($programmingCapture.status -ne "pass" -or
            $programmingCapture.bitstream_sha256 -ne $expectedBitstreamHash -or
            $programmingCapture.source_commit -ne $expectedSourceCommit -or
            $programmingCapture.source_fingerprint -ne $expectedFingerprint -or
            $programmingCapture.hardware_connected -ne $true -or
            [int]$programmingCapture.target_count -ne 1 -or
            $programmingCapture.device_programmed -ne $true -or
            $programmingCapture.configuration_verified -ne $true -or
            [int]$programmingCapture.retry_count -ne 0) {
            throw "Basys3 source XSDB programming summary content mismatch."
        }
    }

    $cases = @(
        [ordered]@{
            name = "showcase"; demo = "showcase"
            packet_path = "fixtures\generated\boot\showcase_demo.boot.bin"
            packet_bytes = 1096; packet_sha256 = "088a27132a09c5cb7ac1625fac85868a9ecca2bb1c8f60a9ba82863c69eaaa8a"
            transcript_bytes = 64; transcript_sha256 = "983a592b146062541104b69e82c2abe463b498d70c659545141f05fa8d73ef9a"
            transcript = "RV32IM SHOWCASE`nUART OK`nMATVEC PASS`nCOUNTERS PASS`nSHOWCASE PASS`n"
            led = "LED15:8=0xa5; LED7:4=0x4; LD3 blinking; LED2:0=000; no 0xee failure indication"
        },
        [ordered]@{
            name = "interactive"; demo = "interactive"
            packet_path = "fixtures\generated\boot\interactive_showcase_demo.boot.bin"
            packet_bytes = 1300; packet_sha256 = "13767ac723f26b39bbede004277b7774ff557495367322947b54126dd382cfb3"
            transcript_bytes = 74; transcript_sha256 = "3640188d8d3f56b1a613d7cb900d04798814d4654f50f48d738a66f11ef33736"
            transcript = "RV32IM INTERACTIVE`nREADY`nCMD M`nMATVEC PASS`nCOUNTERS PASS`nINTERACTIVE PASS`n"
            led = "LED15:8=0xa5; LED7:4=0x4; LD3 blinking; LED2:0=000; no 0xee failure indication"
        },
        [ordered]@{
            name = "hardware_validation"; demo = "hardware_validation"
            packet_path = "fixtures\generated\boot\hardware_validation_suite.boot.bin"
            packet_bytes = 2052; packet_sha256 = "eb3b6b2defad3093337f7dd466ec5ca8f767098d54107c94b965aa2bf39dce92"
            transcript_bytes = 82; transcript_sha256 = "e79c0a5cf34d98c178a4f4fe0a6f0cd65472daf786f0d523c2e97338725e6282"
            transcript = "RV32IM HW VALIDATION`nRV32M PASS`nTIMER IRQ PASS`nMATVEC DMA PASS`nHW VALIDATION PASS`n"
            led = "LED15:8=0xa6; LED7:4=0x6; LD3 blinking; LED2=1; LED1=0; LED0=1; no 0xee failure indication"
        }
    )
    $validatedCases = [ordered]@{}
    $capturePort = $null
    foreach ($case in $cases) {
        $record = $summary.uart_runs.($case.name)
        if ($null -eq $record -or $record.status -ne "pass" -or
            $record.evidence_level -ne "machine_captured_uart_plus_operator_observed_leds" -or
            [string]::IsNullOrWhiteSpace([string]$record.port) -or
            [int]$record.baud -ne 115200 -or
            [long]$record.packet_size_bytes -ne $case.packet_bytes -or
            $record.packet_sha256 -ne $case.packet_sha256 -or
            [long]$record.transcript_size_bytes -ne $case.transcript_bytes -or
            $record.transcript_sha256 -ne $case.transcript_sha256 -or
            $record.line_endings -ne "LF-only with final LF" -or
            [int]$record.retry_count -ne 0 -or $record.led_observation -ne $case.led) {
            throw "Basys3 physical evidence case metadata is inconsistent: $($case.name)"
        }
        if ($null -eq $capturePort) {
            $capturePort = [string]$record.port
        } elseif ([string]$record.port -ne $capturePort) {
            throw "Basys3 UART captures must use one consistent serial port."
        }
        if ($case.name -eq "interactive" -and
            ($record.ready_marker_observed -ne $true -or [int]$record.command_byte_count -ne 1 -or
             $record.command_byte_hex -ne "0x4d" -or $record.command_suffix -ne "none; no CR or LF")) {
            throw "Basys3 interactive single-command evidence is inconsistent."
        }
        if ($case.name -ne "hardware_validation" -and
            $record.reset_reboot_observation -ne "btnC pressed and released; boot-wait confirmed afterward") {
            throw "Basys3 reset/reboot observation is missing: $($case.name)"
        }

        $transcriptPath = [string]$record.transcript_path
        if (-not (Test-Path -LiteralPath $transcriptPath -PathType Leaf)) {
            throw "Basys3 durable transcript is missing: $transcriptPath"
        }
        $transcriptFile = Get-Item -LiteralPath $transcriptPath
        $transcriptHash = (Get-FileHash -LiteralPath $transcriptPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $actualBytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $transcriptPath))
        $expectedBytes = [System.Text.Encoding]::ASCII.GetBytes($case.transcript)
        if ($transcriptFile.Length -ne $case.transcript_bytes -or $transcriptHash -ne $case.transcript_sha256 -or
            $actualBytes.Length -ne $expectedBytes.Length) {
            throw "Basys3 durable transcript size/hash mismatch: $($case.name)"
        }
        for ($index = 0; $index -lt $expectedBytes.Length; $index += 1) {
            if ($actualBytes[$index] -ne $expectedBytes[$index]) {
                throw "Basys3 durable transcript byte mismatch: $($case.name) offset $index"
            }
        }

        if ($VerifyCaptureSources) {
            if (-not (Test-Path -LiteralPath $case.packet_path -PathType Leaf)) {
                throw "Basys3 source packet is missing: $($case.packet_path)"
            }
            $packetFile = Get-Item -LiteralPath $case.packet_path
            $packetHash = (Get-FileHash -LiteralPath $case.packet_path -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($packetFile.Length -ne $case.packet_bytes -or $packetHash -ne $case.packet_sha256) {
                throw "Basys3 source packet size/hash mismatch: $($case.name)"
            }
            $sourceSummaryPath = Resolve-Basys3CapturePath $record.source_summary_path $evidenceRoot
            if (-not (Test-Path -LiteralPath $sourceSummaryPath -PathType Leaf) -or
                (Get-FileHash -LiteralPath $sourceSummaryPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $record.source_summary_sha256) {
                throw "Basys3 source UART summary hash mismatch: $($case.name)"
            }
            $sourceSummary = Get-Content -LiteralPath $sourceSummaryPath -Raw | ConvertFrom-Json
            if ($sourceSummary.status -ne "pass" -or $sourceSummary.target -ne "FullDirect100" -or
                $sourceSummary.demo -ne $case.demo -or $sourceSummary.packet_sha256 -ne $case.packet_sha256 -or
                $sourceSummary.transcript_match -ne $true -or [int]$sourceSummary.retry_count -ne 0 -or
                $sourceSummary.bitstream_sha256 -ne $expectedBitstreamHash -or
                $sourceSummary.bitstream_source_fingerprint -ne $expectedFingerprint) {
                throw "Basys3 source UART summary content mismatch: $($case.name)"
            }
        }
        $validatedCases[$case.name] = [ordered]@{
            transcript_path = $transcriptPath.Replace("\", "/")
            transcript_size_bytes = $transcriptFile.Length
            transcript_sha256 = $transcriptHash
            packet_size_bytes = $case.packet_bytes
            packet_sha256 = $case.packet_sha256
            retry_count = 0
        }
    }

    return [ordered]@{
        status = "pass"
        evidence_root = $evidenceRoot.Replace("\", "/")
        summary_path = $summaryPath.Replace("\", "/")
        summary_sha256 = (Get-FileHash -LiteralPath $summaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        physical_validation_status = "passed"
        physical_validation_scope = $expectedScope
        date_local = $expectedDate
        source_commit = $expectedSourceCommit
        source_fingerprint = $expectedFingerprint
        bitstream_size_bytes = $expectedBitstreamSize
        bitstream_sha256 = $expectedBitstreamHash
        programming_evidence_level = "machine_captured"
        uart_evidence_level = "machine_captured"
        led_reset_evidence_level = "operator_reported"
        cases = $validatedCases
    }
}
