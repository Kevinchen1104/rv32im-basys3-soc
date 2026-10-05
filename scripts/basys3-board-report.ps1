# Publish one completed board session without modifying older board evidence.
param(
    [Parameter(Mandatory=$true)][string]$RunDirectory,
    [Parameter(Mandatory=$true)][ValidatePattern('^\d{4}-\d{2}-\d{2}$')][string]$Date,
    [Parameter(Mandatory=$true)][string]$LedObservation,
    [switch]$ResetConfirmed
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $root
. "$PSScriptRoot/canonical-basys3-evidence.ps1"
if (-not $ResetConfirmed -or -not $LedObservation.Trim()) { throw 'Record the actual LED and reset-button observations first.' }
$hardware = Get-CanonicalBasys3Evidence -AllowPendingPhysicalEvidence
$build = Read-ReleaseJson 'results/vivado-basys3-build-summary.json'
$names = @('Showcase', 'Interactive', 'HardwareValidation', 'Matvec', 'MatvecReset')
$captures = @(foreach ($name in $names) {
    $capture = Read-ReleaseJson (Join-Path $RunDirectory "$name/summary.json")
    if ($capture.status -ne 'pass' -or $capture.bitstream_sha256 -ne $hardware.bitstream_sha256) {
        throw "Missing or mismatched capture: $name"
    }
    [ordered]@{ name=$name; status='pass'; captured_at_utc=$capture.generated_at_utc }
})
$destination = "docs/fpga/board_evidence/basys3_full_direct_100mhz_$Date"
if (Test-Path -LiteralPath $destination) { throw "Evidence directory already exists: $destination" }
$target = New-ReleaseStage $root
Copy-ReleaseText 'results/vivado-basys3-build-summary.json' (Join-Path $target 'build.json') $root
foreach ($file in Get-ChildItem -LiteralPath $RunDirectory -File -Recurse) {
    $relative = $file.FullName.Substring((Resolve-Path $RunDirectory).Path.Length + 1)
    Copy-ReleaseText $file.FullName (Join-Path $target "captures/$relative") $root
}
$timing = $build.reports.post_route_timing
$summary = [ordered]@{
    schema_version=2; status='pass'; physical_validation_status='passed'
    physical_validation_scope='jtag_uart_boot_uart_runtime_rv32m_timer_irq_matvec_output_cycle_measurements_reset_reboot'
    date_local=$Date; timezone='America/New_York'; board='Digilent Basys3'
    fpga_part=$build.part; top=$build.top; soc_clock_mhz=100
    canonical_identity=[ordered]@{
        synthesis_source_commit=$hardware.source_commit; source_fingerprint=$hardware.source_fingerprint
        fingerprint_input_count=$hardware.fingerprint_input_count; bitstream_build_path=$hardware.bitstream_path
        bitstream_size_bytes=$hardware.bitstream_size_bytes; bitstream_sha256=$hardware.bitstream_sha256
        identity_evidence_level='host_verified_before_xsdb_programming'; on_board_readback_or_hash_verification='not_performed'
    }
    post_route_timing=[ordered]@{ vivado_version='2026.1'; status='met'; wns_ns=$timing.wns_ns; tns_ns=$timing.tns_ns; whs_ns=$timing.whs_ns; ths_ns=$timing.ths_ns }
    uart_runs=$captures
    operator=[ordered]@{ led_observation=$LedObservation; reset_button_confirmed=$true; evidence_level='operator_reported' }
    measurement=[ordered]@{ cases_per_run=90; outputs_per_run=2418; runs=2; clock_hz=100000000; interval='hardware cycle-counter reads around RAM-to-RAM work; excludes input preparation and UART printing' }
}
Write-ResultJson $summary (Join-Path $target 'summary.json')
$lines = @('# Basys3 100-MHz board run', '', "Date: $Date. Hardware source: ``$($hardware.source_commit)``.", '',
    'JTAG configuration and all five UART captures passed. MATVEC was repeated after an operator-pressed reset.', '',
    '| Check | Result |', '| --- | --- |',
    '| Showcase | UART TX, Scratchpad and counter self-checks passed |',
    '| Interactive | UART RX command M and response passed |',
    '| Hardware validation | RV32M, timer interrupt and DMA-lite passed |',
    '| MATVEC | 90 cases and 2,418 numerical outputs checked per run |',
    '| Reset repeat | Complete MATVEC firmware reloaded and rerun after BTN C |', '',
    "Operator observation: $LedObservation", '',
    '[First-run measurements](captures/Matvec/measurements.csv) | [Reset-repeat measurements](captures/MatvecReset/measurements.csv)', '',
    'See [measurement method](../../../matvec-benchmark.md#physical-board-measurements) for the board profile and timing interval.', '',
    'Capture copies normalize line endings and replace the absolute checkout path with a dot. Artifact hashes cover the published copies.')
[IO.File]::WriteAllText((Join-Path $target 'README.md'), ($lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
Write-ReleaseManifest $target
Read-Basys3BoardRun (Join-Path $target 'summary.json') | Out-Null
# Directory.Move fails if the destination appeared during validation; it never merges runs.
[IO.Directory]::Move($target, (Join-Path $root $destination))
Write-Host "PASS: published $destination; select its summary in fpga/boards/basys3/board.json after review."
