<#
Script: scripts\basys3-board-demo.ps1
Purpose: Sends a selected Basys3 demo boot packet and captures its UART protocol in one serial-port session.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\basys3-board-demo.ps1 -Demo Interactive -Port <COMx>
Outputs:
  Demo-specific UART transcript and JSON summary files under results\ by default.
Scope:
  Physical host utility for scoped Basys3 UART evidence; not exhaustive ISA, timing, compliance, or performance proof.
#>
param(
    [ValidateSet("FullLowfreq", "FullDirect100")]
    [string] $Target = "FullLowfreq",
    [Parameter(Mandatory = $true)]
    [ValidateSet("Showcase", "Interactive", "HardwareValidation", "Matvec")]
    [string] $Demo,
    [Parameter(Mandatory = $true)]
    [string] $Port,
    [int] $Baud = 115200,
    [int] $BootTimeoutSeconds = 30,
    [int] $CompletionTimeoutSeconds = 60,
    [switch] $DryRun,
    [string] $PacketPath,
    [string] $TranscriptPath,
    [string] $SummaryPath
)

. "$PSScriptRoot/script-common.ps1"
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/result-format.ps1"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$outputPrefix = if ($Target -eq 'FullDirect100') { 'results/basys3-full-direct-100mhz' } else { 'results/basys3-full-lowfreq' }
$demoSuffix = if ($Demo -eq 'HardwareValidation') { 'hardware-validation' } else { $Demo.ToLowerInvariant() }
if (-not $SummaryPath) { $SummaryPath = "$outputPrefix-$demoSuffix-summary.json" }
$resolvedSummaryPath = Resolve-RepoPath $SummaryPath
$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    status = 'running'; target = $Target; demo = $Demo; error = $null
}
Write-ResultJson $summary $resolvedSummaryPath
try {
. (Join-Path $PSScriptRoot "canonical-basys3-evidence.ps1")
$directEvidence = if ($Target -eq "FullDirect100") {
    Get-CanonicalBasys3Evidence -AllowPendingPhysicalEvidence
} else {
    $null
}

$targetConfig = if ($Target -eq "FullDirect100") {
    [ordered]@{
        output_prefix = "results\basys3-full-direct-100mhz"
        display_name = "full-direct-100-MHz"
        top = "RISCVCPU_basys3_top"
        soc_clock_mhz = 100
        vivado_version = "2026.1"
        bitstream = $directEvidence.bitstream_path
        bitstream_source_commit = $directEvidence.source_commit
        bitstream_source_fingerprint = $directEvidence.source_fingerprint
        bitstream_fingerprint_input_count = $directEvidence.fingerprint_input_count
        bitstream_size_bytes = $directEvidence.bitstream_size_bytes
        bitstream_sha256 = $directEvidence.bitstream_sha256
        physical_validation_status = $directEvidence.physical_validation_status
        physical_validation_scope = $directEvidence.physical_validation_scope
    }
} else {
    [ordered]@{
        output_prefix = "results\basys3-full-lowfreq"
        display_name = "full-low-frequency"
        top = "RISCVCPU_basys3_full_lowfreq_top"
        soc_clock_mhz = 6.25
        vivado_version = "2026.1"
        bitstream = $null
        bitstream_source_commit = $null
        bitstream_source_fingerprint = $null
        bitstream_fingerprint_input_count = $null
        bitstream_size_bytes = $null
        bitstream_sha256 = $null
        physical_validation_status = "not_run"
        physical_validation_scope = "needs_revalidation"
    }
}

$demoConfig = if ($Demo -eq "Matvec") {
    $firmwareBuild = Read-JsonFile 'build/board-matvec/build.json'
    if ($null -eq $firmwareBuild -or $firmwareBuild.status -ne 'passed') {
        throw 'Build board MATVEC firmware with scripts/board_matvec.py --build --simulate first.'
    }
    [ordered]@{
        name = 'matvec'
        packet_path = 'build/board-matvec/program.boot.bin'
        expected_packet_bytes = $firmwareBuild.firmware_bytes + 20
        expected_packet_sha256 = $firmwareBuild.packet_sha256
        transcript_path = "$($targetConfig.output_prefix)-matvec-transcript.txt"
        summary_path = "$($targetConfig.output_prefix)-matvec-summary.json"
        ready_marker = $null
        final_marker = "E 0000005a`n"
        expected_transcript = $null
        failure_marker = $null
        claim_scope_lowfreq = 'RAM-to-RAM MATVEC cycle measurements and all output values captured over UART.'
        claim_scope_direct = 'Ninety RAM-to-RAM MATVEC cycle measurements and 2,418 output values captured over UART at 100 MHz.'
    }
} elseif ($Demo -eq "Interactive") {
    [ordered]@{
        name = "interactive"
        packet_path = "fixtures\generated\boot\interactive_showcase_demo.boot.bin"
        expected_packet_bytes = 1300
        expected_packet_sha256 = "13767ac723f26b39bbede004277b7774ff557495367322947b54126dd382cfb3"
        transcript_path = "$($targetConfig.output_prefix)-interactive-transcript.txt"
        summary_path = "$($targetConfig.output_prefix)-interactive-summary.json"
        ready_marker = "RV32IM INTERACTIVE`nREADY`n"
        final_marker = "INTERACTIVE PASS`n"
        expected_transcript = "RV32IM INTERACTIVE`nREADY`nCMD M`nMATVEC PASS`nCOUNTERS PASS`nINTERACTIVE PASS`n"
        failure_marker = "BAD CMD"
        claim_scope_lowfreq = "Physical host flow for packet-boot-to-runtime UART RX handoff, CPU MMIO UART RX consumption of command M, UART TX, MATVEC Scratchpad self-checks, performance-counter observations, GPIO firmware execution, and the full-feature 6.25 MHz Basys3 configuration. This target has no current physical pass."
        claim_scope_direct = "Physical host flow for packet-boot-to-runtime UART RX handoff, one exact command byte 0x4d, CPU MMIO UART RX consumption, UART TX, MATVEC Scratchpad self-checks, counters, and GPIO on the timing-closed full direct-100-MHz Basys3 target. Each new capture remains pending until its operator LED/reset confirmation."
    }
} elseif ($Demo -eq "HardwareValidation") {
    [ordered]@{
        name = "hardware_validation"
        packet_path = "fixtures\generated\boot\hardware_validation_suite.boot.bin"
        expected_packet_bytes = 2052
        expected_packet_sha256 = "eb3b6b2defad3093337f7dd466ec5ca8f767098d54107c94b965aa2bf39dce92"
        transcript_path = "$($targetConfig.output_prefix)-hardware-validation-transcript.txt"
        summary_path = "$($targetConfig.output_prefix)-hardware-validation-summary.json"
        ready_marker = $null
        final_marker = "HW VALIDATION PASS`n"
        expected_transcript = "RV32IM HW VALIDATION`nRV32M PASS`nTIMER IRQ PASS`nMATVEC DMA PASS`nHW VALIDATION PASS`n"
        failure_marker = "FAIL"
        claim_scope_lowfreq = "Physical host flow for selected RV32M arithmetic, machine timer interrupt/trap return, MATVEC DMA-lite external-DMEM operation, UART TX, GPIO, and public status on the full-feature 6.25 MHz Basys3 target. This target has no current physical pass."
        claim_scope_direct = "Physical host flow for selected RV32M arithmetic, machine timer interrupt/trap return, MATVEC DMA-lite external-DMEM operation, UART TX, GPIO, and public status on the timing-closed full direct-100-MHz Basys3 target. Each new capture remains pending until its operator LED confirmation."
    }
} else {
    [ordered]@{
        name = "showcase"
        packet_path = "fixtures\generated\boot\showcase_demo.boot.bin"
        expected_packet_bytes = 1096
        expected_packet_sha256 = "088a27132a09c5cb7ac1625fac85868a9ecca2bb1c8f60a9ba82863c69eaaa8a"
        transcript_path = "$($targetConfig.output_prefix)-showcase-transcript.txt"
        summary_path = "$($targetConfig.output_prefix)-showcase-summary.json"
        ready_marker = $null
        final_marker = "SHOWCASE PASS`n"
        expected_transcript = "RV32IM SHOWCASE`nUART OK`nMATVEC PASS`nCOUNTERS PASS`nSHOWCASE PASS`n"
        failure_marker = $null
        claim_scope_lowfreq = "Physical UART host flow for packet boot, UART TX, showcase firmware self-checks, MATVEC Scratchpad, performance-counter reads, and GPIO firmware execution on the full-feature 6.25 MHz Basys3 target. This target has no current physical pass."
        claim_scope_direct = "Physical UART flow for packet boot, UART TX, showcase firmware self-checks, MATVEC Scratchpad, counter reads, and GPIO on the timing-closed full direct-100-MHz Basys3 target. Each new capture remains pending until its operator LED/reset confirmation."
    }
}

$claimBoundary = if ($Target -eq "FullDirect100") {
    "UART results apply to this capture and the host-identified bitstream. LED/button observations are recorded separately."
} else {
    "The full-feature 6.25 MHz target has no current physical pass; DryRun and a future transcript alone do not establish one without source identity and operator observations. It does not affect the separately validated direct-100-MHz top or prove every RV32IM instruction, official RISC-V compliance, production DMA, benchmark speedup, or power signoff."
}
$claimScope = if ($Target -eq "FullDirect100") { $demoConfig.claim_scope_direct } else { $demoConfig.claim_scope_lowfreq }

if ([string]::IsNullOrWhiteSpace($PacketPath)) {
    $PacketPath = $demoConfig.packet_path
}
if ([string]::IsNullOrWhiteSpace($TranscriptPath)) {
    $TranscriptPath = $demoConfig.transcript_path
}
if ([string]::IsNullOrWhiteSpace($SummaryPath)) {
    $SummaryPath = $demoConfig.summary_path
}

function Normalize-Transcript {
    param([AllowEmptyString()][string] $Text)

    if ($null -eq $Text) {
        return ""
    }
    return ($Text -replace "`r`n", "`n" -replace "`r", "`n")
}

function Write-JsonSummary {
    param(
        [System.Collections.IDictionary] $Summary,
        [string] $Path
    )

    Write-ResultJson $Summary $Path
}

$resolvedPacketPath = Resolve-RepoPath $PacketPath
$resolvedTranscriptPath = Resolve-RepoPath $TranscriptPath
$resolvedSummaryPath = Resolve-RepoPath $SummaryPath

Ensure-ParentDirectory $resolvedTranscriptPath
Ensure-ParentDirectory $resolvedSummaryPath

if ($resolvedTranscriptPath -eq $resolvedSummaryPath) {
    throw "TranscriptPath and SummaryPath must resolve to different files."
}

$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = "starting"
    target = $Target
    demo = $demoConfig.name
    board = "Digilent Basys3"
    fpga_part = "xc7a35tcpg236-1"
    top = $targetConfig.top
    soc_clock_mhz = $targetConfig.soc_clock_mhz
    vivado_version = $targetConfig.vivado_version
    bitstream = $targetConfig.bitstream
    bitstream_source_commit = $targetConfig.bitstream_source_commit
    repository_head = if ($Target -eq "FullDirect100") { $directEvidence.repository_head } else { (& git rev-parse HEAD 2>$null).Trim() }
    bitstream_source_fingerprint = $targetConfig.bitstream_source_fingerprint
    bitstream_fingerprint_input_count = $targetConfig.bitstream_fingerprint_input_count
    bitstream_size_bytes = $targetConfig.bitstream_size_bytes
    bitstream_sha256 = $targetConfig.bitstream_sha256
    device_programmed = $false
    physical_validation_status = $targetConfig.physical_validation_status
    physical_validation_scope = $targetConfig.physical_validation_scope
    port = $Port
    baud = $Baud
    packet_path = $PacketPath
    packet_sha256 = $null
    packet_byte_count = $null
    packet_expected_sha256 = $demoConfig.expected_packet_sha256
    packet_expected_byte_count = $demoConfig.expected_packet_bytes
    packet_hash_match = $false
    packet_fixture_valid = $false
    port_opened = $false
    packet_sent = $false
    ready_marker_seen = $false
    ready_observed_at_utc = $null
    command_byte_hex = if ($Demo -eq "Interactive") { "0x4d" } else { $null }
    command_sent = $false
    command_sent_at_utc = $null
    final_marker_seen = $false
    terminal_marker_seen = $false
    expected_transcript = $demoConfig.expected_transcript
    observed_transcript = ""
    transcript_match = $false
    boot_timeout_seconds = $BootTimeoutSeconds
    completion_timeout_seconds = $CompletionTimeoutSeconds
    timeout_seconds = $CompletionTimeoutSeconds
    dry_run = [bool]$DryRun
    retry_count = 0
    transcript_path = $TranscriptPath
    summary_path = $SummaryPath
    physical_led_confirmation = "pending_operator_confirmation"
    reset_reboot_precondition = "reset_or_reconfigure_before_capture"
    claim_scope = $claimScope
    claim_boundary = $claimBoundary
    error = $null
}

$serial = $null
$packetBytes = $null
$observedBuilder = [System.Text.StringBuilder]::new()
$failureMessage = $null

try {
    if ([string]::IsNullOrWhiteSpace($Port)) {
        throw "Port must not be empty."
    }
    if ($Baud -le 0) {
        throw "Baud must be greater than zero."
    }
    if ($BootTimeoutSeconds -le 0) {
        throw "BootTimeoutSeconds must be greater than zero."
    }
    if ($CompletionTimeoutSeconds -le 0) {
        throw "CompletionTimeoutSeconds must be greater than zero."
    }
    if (-not (Test-Path -LiteralPath $resolvedPacketPath -PathType Leaf)) {
        throw "$Demo boot packet fixture not found: $PacketPath"
    }

    $packetBytes = [System.IO.File]::ReadAllBytes($resolvedPacketPath)
    if ($packetBytes.Length -eq 0) {
        throw "$Demo boot packet fixture is empty: $PacketPath"
    }
    $summary.packet_byte_count = $packetBytes.Length
    $summary.packet_sha256 = (Get-FileHash -LiteralPath $resolvedPacketPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $canonicalPacketPath = Resolve-RepoPath $demoConfig.packet_path
    if ($resolvedPacketPath -eq $canonicalPacketPath) {
        $summary.packet_hash_match = ($summary.packet_sha256 -eq $demoConfig.expected_packet_sha256)
        $summary.packet_fixture_valid = ($summary.packet_hash_match -and $packetBytes.Length -eq $demoConfig.expected_packet_bytes)
        if (-not $summary.packet_fixture_valid) {
            throw "$Demo canonical packet fixture size/SHA256 does not match the pinned metadata."
        }
    }

    if ($DryRun) {
        $summary.status = "dry_run"
    } else {
        $availablePorts = @([System.IO.Ports.SerialPort]::GetPortNames())
        if ($availablePorts -notcontains $Port) {
            $availableText = if ($availablePorts.Count -eq 0) { "none" } else { $availablePorts -join ", " }
            throw "Serial port '$Port' was not found. Available ports: $availableText"
        }

        $serial = [System.IO.Ports.SerialPort]::new(
            $Port,
            $Baud,
            [System.IO.Ports.Parity]::None,
            8,
            [System.IO.Ports.StopBits]::One
        )
        $serial.Handshake = [System.IO.Ports.Handshake]::None
        $serial.DtrEnable = $false
        $serial.RtsEnable = $false
        $serial.Encoding = [System.Text.Encoding]::ASCII
        $serial.ReadTimeout = 250
        $serial.WriteTimeout = [Math]::Max(1000, [Math]::Max($BootTimeoutSeconds, $CompletionTimeoutSeconds) * 1000)

        try {
            $serial.Open()
        } catch {
            throw "Could not open serial port '$Port'. It may be busy or unavailable: $($_.Exception.Message)"
        }
        $summary.port_opened = $true

        $serial.DiscardInBuffer()
        $serial.DiscardOutBuffer()

        try {
            $serial.Write($packetBytes, 0, $packetBytes.Length)
        } catch {
            throw "Failed while sending the $($demoConfig.name) packet to '$Port': $($_.Exception.Message)"
        }
        $summary.packet_sent = $true

        if ($Demo -eq "Interactive") {
            $bootDeadline = [DateTime]::UtcNow.AddSeconds($BootTimeoutSeconds)
            while ([DateTime]::UtcNow -lt $bootDeadline) {
                $chunk = $serial.ReadExisting()
                if (-not [string]::IsNullOrEmpty($chunk)) {
                    $observedBuilder.Append($chunk) | Out-Null
                    $currentTranscript = Normalize-Transcript $observedBuilder.ToString()
                    if (-not [string]::IsNullOrEmpty($demoConfig.failure_marker) -and
                        $currentTranscript.Contains($demoConfig.failure_marker)) {
                        throw "The interactive firmware reported BAD CMD before the host command was sent."
                    }
                    if ($currentTranscript.Contains($demoConfig.ready_marker)) {
                        $summary.ready_marker_seen = $true
                        $summary.ready_observed_at_utc = (Get-Date).ToUniversalTime().ToString("o")
                        break
                    }
                }
                Start-Sleep -Milliseconds 10
            }

            if (-not $summary.ready_marker_seen) {
                throw "Timed out after $BootTimeoutSeconds seconds before receiving the exact interactive READY marker."
            }

            $commandByte = [byte[]]@(0x4d)
            try {
                $serial.Write($commandByte, 0, 1)
            } catch {
                throw "Failed while sending the single ASCII M command byte to '$Port': $($_.Exception.Message)"
            }
            $summary.command_sent = $true
            $summary.command_sent_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        }

        $completionDeadline = [DateTime]::UtcNow.AddSeconds($CompletionTimeoutSeconds)
        while ([DateTime]::UtcNow -lt $completionDeadline) {
            $chunk = $serial.ReadExisting()
            if (-not [string]::IsNullOrEmpty($chunk)) {
                $observedBuilder.Append($chunk) | Out-Null
                $currentTranscript = Normalize-Transcript $observedBuilder.ToString()
                if (-not [string]::IsNullOrEmpty($demoConfig.failure_marker) -and
                    $currentTranscript.Contains($demoConfig.failure_marker)) {
                    throw "The $($demoConfig.name) firmware reported failure marker '$($demoConfig.failure_marker)'."
                }
                if ($currentTranscript.Contains($demoConfig.final_marker)) {
                    break
                }
            }
            Start-Sleep -Milliseconds 10
        }

        $observedTranscript = Normalize-Transcript $observedBuilder.ToString()
        if (-not $observedTranscript.Contains($demoConfig.final_marker)) {
            throw "Timed out after $CompletionTimeoutSeconds seconds before receiving $($demoConfig.final_marker.Trim())."
        }
        if ($Demo -eq 'Matvec') {
            [IO.File]::WriteAllText($resolvedTranscriptPath, $observedTranscript, [Text.UTF8Encoding]::new($false))
            & '.venv/Scripts/python.exe' -B scripts/board_matvec.py --check-transcript $resolvedTranscriptPath
            if ($LASTEXITCODE -ne 0) { throw 'Board MATVEC output comparison failed.' }
            $comparison = Read-JsonFile (Join-Path (Split-Path -Parent $resolvedTranscriptPath) 'comparison.json')
            $summary.cases_passed = $comparison.cases_passed
            $summary.outputs_checked = $comparison.outputs_checked
            $summary.comparison_sha256 = (Get-FileHash (Join-Path (Split-Path -Parent $resolvedTranscriptPath) 'comparison.json')).Hash.ToLowerInvariant()
        } elseif ($observedTranscript -cne $demoConfig.expected_transcript) {
            throw "UART transcript was received but did not exactly match the expected $($demoConfig.name) text."
        }

        $summary.status = "pass"
        if ($Target -eq "FullDirect100") {
            $summary.physical_validation_status = "pending_operator_confirmation"
        }
    }
} catch {
    $failureMessage = $_.Exception.Message
    $summary.status = "fail"
    $summary.error = $failureMessage
} finally {
    if ($null -ne $serial) {
        try {
            if ($serial.IsOpen) {
                $serial.Close()
            }
        } catch {
            if ($null -eq $failureMessage) {
                $failureMessage = "Failed while closing serial port '$Port': $($_.Exception.Message)"
                $summary.status = "fail"
                $summary.error = $failureMessage
            }
        }
        try {
            $serial.Dispose()
        } catch {
            if ($null -eq $failureMessage) {
                $failureMessage = "Failed while disposing serial port '$Port': $($_.Exception.Message)"
                $summary.status = "fail"
                $summary.error = $failureMessage
            }
        }
    }

    $observedTranscript = Normalize-Transcript $observedBuilder.ToString()
    $summary.observed_transcript = $observedTranscript
    $summary.final_marker_seen = $observedTranscript.Contains($demoConfig.final_marker)
    $summary.terminal_marker_seen = $summary.final_marker_seen
    $summary.transcript_match = if ($Demo -eq 'Matvec') { $summary.status -eq 'pass' } else { $observedTranscript -ceq $demoConfig.expected_transcript }

    if (-not $DryRun) {
        [System.IO.File]::WriteAllText(
            $resolvedTranscriptPath,
            $observedTranscript,
            [System.Text.UTF8Encoding]::new($false)
        )
    }
    Write-JsonSummary -Summary $summary -Path $resolvedSummaryPath
}

Write-Host "========================================"
Write-Host ("Basys3 {0} {1} UART capture" -f $targetConfig.display_name, $demoConfig.name)
Write-Host ("Status: {0}" -f $summary.status)
Write-Host ("Port: {0} at {1} baud" -f $Port, $Baud)
Write-Host ("Packet: {0} bytes, SHA256 {1}" -f $summary.packet_byte_count, $summary.packet_sha256)
Write-Host ("Packet fixture valid: {0}" -f $summary.packet_fixture_valid)
if ($Demo -eq "Interactive") {
    Write-Host ("READY seen: {0}" -f $summary.ready_marker_seen)
    Write-Host ("Command 0x4d sent: {0}" -f $summary.command_sent)
}
Write-Host ("Transcript match: {0}" -f $summary.transcript_match)
Write-Host ("Summary: {0}" -f $SummaryPath)
if (-not $DryRun) {
    Write-Host ("Transcript: {0}" -f $TranscriptPath)
}

if ($summary.status -eq "dry_run") {
    Write-Host "Dry run only: COM port was not opened and no physical PASS is claimed."
    exit 0
}

if ($summary.status -ne "pass") {
    throw $failureMessage
}

Write-Host ("PASS: exact physical UART {0} transcript captured" -f $demoConfig.name)
} catch {
    $summary.status = 'fail'
    $summary.error = $_.Exception.Message
    Write-ResultJson $summary $resolvedSummaryPath
    throw
}
