# Export one measured implementation, or the generic integration configuration.
param(
    [ValidateSet('basys3', 'generic_uart_boot_runtime')][string]$BoardProfile = 'basys3',
    [string]$SummaryPath = 'results/vivado-basys3-build-summary.json'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/release-package.ps1"
. "$PSScriptRoot/script-common.ps1"
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $root
$stage = New-ReleaseStage $root
try {
    if ($BoardProfile -eq 'basys3') {
        $record = Read-ReleaseJson $SummaryPath
        Assert-ImplementationResult $record
        Assert-BuildReportArtifacts $record $root
        if (-not (Test-ReleaseInputs $record.source_inputs $root 'raw')) { throw 'Implementation inputs have changed; rebuild before exporting' }
        $inputs = @($record.source_inputs)
        $sourceCommit = $record.source_commit
        $kind = 'implementation'
        $destination = 'release/implementation/basys3'
        Copy-ReleaseText $SummaryPath (Join-Path $stage 'implementation.json') $root
        # Copy the complete report set beside the derivative summary, using package-relative links.
        $copy = Read-ReleaseJson (Join-Path $stage 'implementation.json')
        $copy | Add-Member -NotePropertyName original_report_artifacts -NotePropertyValue @($record.report_artifacts)
        $packagedReports = @()
        foreach ($property in $record.reports.PSObject.Properties) {
            $path = if ($property.Value -is [string]) { $property.Value } else { $property.Value.path }
            if ($path -isnot [string] -or -not $path) { continue }
            $relative = 'reports/' + $property.Name + '.rpt'
            Copy-ReleaseText $path (Join-Path $stage $relative) $root
            $packagedPath = Join-Path $stage $relative
            $packagedReports += [ordered]@{ path=$relative; size_bytes=(Get-Item $packagedPath).Length; sha256=(Get-FileHash $packagedPath -Algorithm SHA256).Hash.ToLowerInvariant() }
            if ($property.Value -is [string]) { $copy.reports.($property.Name) = $relative }
            else { $copy.reports.($property.Name).path = $relative }
        }
        $copy.report_artifacts = $packagedReports
        Write-ResultJson $copy (Join-Path $stage 'implementation.json')
    } else {
        $kind = 'configuration'
        $destination = 'release/configuration/generic_uart_boot_runtime'
        $sourceCommit = (& git rev-parse HEAD).Trim()
        $paths = @('fpga/fpga_sources.f', 'fpga/boards/generic_uart_boot_runtime/board.json')
        $inputs = @(foreach ($path in $paths) {
            Copy-ReleaseText $path (Join-Path $stage (Split-Path $path -Leaf)) $root
            [ordered]@{ path=$path; sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
        })
    }
    $fingerprint = Get-ReleaseFingerprint $inputs
    Write-ResultJson ([ordered]@{ hash_mode='raw'; fingerprint=$fingerprint; inputs=$inputs }) (Join-Path $stage 'source-inputs.json')
    $package = [ordered]@{
        schema_version=1; kind=$kind; status='pass'; generated_at_utc=(Get-Date).ToUniversalTime().ToString('o')
        source_commit=$sourceCommit; source_fingerprint=$fingerprint; input_count=$inputs.Count; board_profile=$BoardProfile
        physical_validation_status='not_run'
    }
    Write-ResultJson $package (Join-Path $stage 'package.json')
    $description = if ($kind -eq 'implementation') {
        "Routed Vivado implementation at $($record.timing_period_ns) ns: WNS $($record.reports.post_route_timing.wns_ns) ns; WHS $($record.reports.post_route_timing.whs_ns) ns."
    } else { 'Generic UART-boot integration configuration. Select a concrete board and constraints to run implementation.' }
    @("# $BoardProfile $kind", '', $description, '',
        "Measured/configuration revision: ``$sourceCommit``.", '',
        'Source inputs and report artifacts are indexed by SHA-256. Package integrity and source freshness are checked by `scripts/final-audit.ps1`.', '',
        'Physical board observations are recorded separately under `docs/fpga/board_evidence/`.') |
        Set-Content -LiteralPath (Join-Path $stage 'README.md') -Encoding UTF8
    Write-ReleaseManifest $stage
    Publish-ReleasePackage $stage $destination $root
} catch { Write-Host "Package not published; diagnostic staging directory: $stage"; throw }
Write-Host "Published: $destination ($kind)"
