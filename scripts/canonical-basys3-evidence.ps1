# Resolve a current, timing-closed bitstream independently of historical board runs.
. "$PSScriptRoot/release-package.ps1"
. "$PSScriptRoot/basys3-physical-evidence.ps1"

function Get-CanonicalBasys3BuildInputIdentity {
    param($Build)
    $paths = @('fpga/fpga_sources.f', 'fpga/vivado/basys3_build.tcl', 'fpga/boards/basys3/basys3.xdc')
    $paths += @(Get-Content 'fpga/fpga_sources.f' | ForEach-Object { $_.Trim().Replace('\', '/') } |
        Where-Object { $_ -and -not $_.StartsWith('#') })
    $records = @($Build.source_inputs)
    if ((Get-ReleaseFingerprint $records) -ne $Build.source_fingerprint -or
        -not (Test-ReleaseInputs $records $PWD.Path 'raw')) {
        throw 'The bitstream build does not match its recorded build inputs.'
    }
    foreach ($path in $paths) {
        if (@($records | Where-Object path -eq $path).Count -ne 1) {
            throw "Hardware input missing from the build identity: $path"
        }
    }
    [ordered]@{ fingerprint=$Build.source_fingerprint; inputs=$records }
}

function Get-CanonicalBasys3Evidence {
    param(
        [string]$RequestedBitstreamPath = '',
        [string]$RequestedSha256 = '',
        [long]$RequestedSizeBytes = 0,
        [switch]$AllowPendingPhysicalEvidence
    )
    $board = Read-ReleaseJson 'fpga/boards/basys3/board.json'
    $build = Read-ReleaseJson 'results/vivado-basys3-build-summary.json'
    Assert-ImplementationResult $build
    if ($build.mode -ne 'bitstream' -or $build.bitstream_status -ne 'pass' -or
        $build.top -ne 'RISCVCPU_basys3_top' -or $build.part -ne 'xc7a35tcpg236-1' -or
        $build.architecture_profile -ne 'default' -or $build.timing_period_ns -ne 10 -or
        $board.top_module -ne $build.top -or $board.fpga_part -ne $build.part) {
        throw 'Expected a passing direct-100-MHz Basys3 bitstream build.'
    }
    # Accept the builder's complete input domain, including its own tooling.
    # Unrelated host scripts are not part of this hardware identity.
    $identity = Get-CanonicalBasys3BuildInputIdentity $build
    $relative = ([string]$build.bitstream).Replace('\', '/')
    $path = Resolve-ReleasePath $PWD.Path $relative
    $size = (Get-Item -LiteralPath $path).Length
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($size -le 0) { throw 'The bitstream is empty.' }
    if ($build.bitstream_sha256 -ne $hash) { throw 'Bitstream differs from its build hash; rebuild it.' }
    if ($RequestedBitstreamPath -and [IO.Path]::GetFullPath($RequestedBitstreamPath) -ne $path) {
        throw 'Requested bitstream differs from the current build.'
    }
    if ($RequestedSha256 -and $RequestedSha256.ToLowerInvariant() -ne $hash) { throw 'Bitstream SHA256 mismatch.' }
    if ($RequestedSizeBytes -gt 0 -and $RequestedSizeBytes -ne $size) { throw 'Bitstream size mismatch.' }
    $physical = $null
    if (-not $AllowPendingPhysicalEvidence) {
        $physical = Get-Basys3PhysicalEvidence
        if ($physical.source_fingerprint -ne $identity.fingerprint -or $physical.bitstream_sha256 -ne $hash) {
            throw 'The recorded physical run describes a different hardware image.'
        }
    }
    [ordered]@{
        bitstream_path=$relative; bitstream_absolute_path=$path
        bitstream_sha256=$hash; bitstream_size_bytes=$size
        source_commit=$build.source_commit; repository_head=(& git rev-parse HEAD).Trim()
        source_fingerprint=$identity.fingerprint; fingerprint_input_count=$identity.inputs.Count
        rtl_source_count=@($identity.inputs | Where-Object path -like 'rtl/*').Count
        manifest_sha256=(Get-FileHash 'fpga/fpga_sources.f' -Algorithm SHA256).Hash.ToLowerInvariant()
        physical_validation_status=if ($physical) { $physical.physical_validation_status } else { 'not_run' }
        physical_validation_scope=if ($physical) { $physical.physical_validation_scope } else { 'pending_board_run' }
    }
}
