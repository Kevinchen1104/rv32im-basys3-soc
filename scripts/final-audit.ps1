# Read-only integrity audit of published snapshots. RequireCurrent also checks source freshness.
param(
    [switch]$PackagedEvidence,
    [switch]$RequireCurrent,
    [ValidateSet('all', 'portable', 'implementation', 'configuration')][string]$Scope = 'all'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/release-package.ps1"
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $root
$output = 'results/final-audit-summary.json'
$summary = [ordered]@{
    status='running'; generated_at_utc=(Get-Date).ToUniversalTime().ToString('o')
    mode=if ($RequireCurrent) { 'integrity_and_current_inputs' } else { 'package_integrity' }
    scope=$Scope
    packages=@(); historical_packages=@(); error_message=$null
}
Write-ResultJson $summary $output
try {
    $paths = [ordered]@{ portable='release/current'; implementation='release/implementation/basys3'; configuration='release/configuration/generic_uart_boot_runtime' }
    foreach ($kind in $paths.Keys) {
        if ($Scope -ne 'all' -and $Scope -ne $kind) { continue }
        $path = $paths[$kind]
        if ($Scope -ne 'all' -or $kind -eq 'portable' -or (Test-Path -LiteralPath $path)) {
            $summary.packages += Assert-ReleasePackage $path $root -RequireCurrent:$RequireCurrent
        }
    }
    if ($Scope -eq 'all') {
      foreach ($path in @('release/final', 'release/fpga/basys3', 'release/fpga/generic_uart_boot_runtime')) {
        $count = Assert-ReleaseManifest $path
        $summary.historical_packages += [ordered]@{ path=$path; integrity='pass'; source_match='historical'; artifacts=$count }
      }
      . "$PSScriptRoot/basys3-physical-evidence.ps1"
      $physical = Get-Basys3PhysicalEvidence -VerifyCaptureSources
      $summary.physical_record = [ordered]@{ source_commit=$physical.source_commit; summary_sha256=$physical.summary_sha256; status='verified_historical_record' }
    }
    $summary.status = 'pass'
} catch { $summary.status='fail'; $summary.error_message=$_.Exception.Message; throw }
finally { Write-ResultJson $summary $output }
foreach ($package in $summary.packages) { Write-Host "$($package.path): integrity PASS; inputs $($package.source_match)" }
if ($Scope -eq 'all') { Write-Host 'Historical package manifests and recorded board captures: PASS' }
