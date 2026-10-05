# Exercise package integrity, source identity, and failure-safe publication with fixtures.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/release-package.ps1"
. "$PSScriptRoot/artifact-paths.ps1"
. "$PSScriptRoot/canonical-basys3-evidence.ps1"
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $root
$fixture = Join-Path $root ('build/tests/release-provenance/' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $fixture | Out-Null
$checks = New-Object 'System.Collections.Generic.List[string]'
$summary = [ordered]@{ status='running'; checks=@(); error_message=$null; fixture=$fixture }
$output = Join-Path $root 'results/release-provenance-self-test-summary.json'
Write-ResultJson $summary $output
function Expect([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "Self-test failed: $Name" }
    $checks.Add($Name)
}
function Reject([scriptblock]$Action, [string]$Name) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Expect $rejected $Name
}
function Clone($Value) { ConvertTo-ResultJson $Value | ConvertFrom-Json }
function Write-FixturePackage([string]$Stage) {
    New-Item -ItemType Directory -Force -Path $Stage | Out-Null
    $inputs = @([ordered]@{ path='input.txt'; sha256=(Get-FileHash -LiteralPath (Join-Path $fixture 'input.txt')).Hash.ToLowerInvariant() })
    $fp = Get-ReleaseFingerprint $inputs
    Write-ResultJson ([ordered]@{ hash_mode='raw'; fingerprint=$fp; inputs=$inputs }) (Join-Path $Stage 'source-inputs.json')
    Write-ResultJson ([ordered]@{ schema_version=1; kind='configuration'; status='pass'; source_commit=('a' * 40); source_fingerprint=$fp; input_count=1 }) (Join-Path $Stage 'package.json')
    Write-ReleaseManifest $Stage
}
try {
    $identity = @{ verification_input_fingerprint=('a' * 64); verification_input_count=2 }
    $valid = @{ verification_input_fingerprint=('a' * 64); verification_input_count=2; verification_working_tree_dirty=$false; source_commit=('a' * 40) }
    Expect (Test-ReleaseGateIdentity (Clone $valid) $identity) 'Matching committed gate inputs accepted'
    foreach ($change in @(
        @{key='verification_input_fingerprint';value=('b' * 64)},
        @{key='verification_input_count';value=3},
        @{key='verification_working_tree_dirty';value=$true},
        @{key='verification_working_tree_dirty';value=$null},
        @{key='source_commit';value='invalid'}
    )) {
        $record = Clone $valid
        $record.($change.key) = $change.value
        Expect (-not (Test-ReleaseGateIdentity $record $identity)) "Invalid gate field rejected: $($change.key)=$($change.value)"
    }
    Expect (-not (Test-ReleaseGateIdentity $null $identity)) 'Missing gate rejected'
    $check = Clone @{status='pass';mode='Full';planned_steps=1;steps=@(@{status='passed';exit_code=0})}
    $regression = Clone @{status='passed';total=2;passed=2;failed=0;tests=@(@{name='a';status='passed'},@{name='b';status='passed'})}
    $catalog = Clone @{tests=@(@{name='a';included_in_full_regression=$true},@{name='b';included_in_full_regression=$true})}
    $catalogResult = Clone @{total_catalog_entries=2;run_ps1_tests=2}
    $coverage = Clone @{status='pass';total_tests=2;passed=2;failed=0}
    Assert-PortableCoverage $check $regression $catalog $catalogResult $coverage
    Expect $true 'Portable coverage needs no Vivado strategy or physical record'
    $bad = Clone $check
    $bad.steps = @()
    Reject { Assert-PortableCoverage $bad $regression $catalog $catalogResult $coverage } 'Incomplete workflow rejected'
    $bad = Clone $regression
    $bad.tests[1].name = 'a'
    Reject { Assert-PortableCoverage $check $bad $catalog $catalogResult $coverage } 'Duplicate regression name rejected'
    $bad = Clone $regression
    $bad.tests[1].status = 'failed'
    Reject { Assert-PortableCoverage $check $bad $catalog $catalogResult $coverage } 'Failed RTL test rejected despite success counters'
    $bad = Clone $coverage
    $bad.total_tests = 3
    Reject { Assert-PortableCoverage $check $regression $catalog $catalogResult $bad } 'Coverage count mismatch rejected'

    $implementation = Clone @{
        status='pass'; execution_status='pass'; timing_status='pass'; source_commit=('a' * 40); working_tree_dirty=$false
        source_inputs=@(@{path='rtl/example.v';sha256=('a' * 64)})
        reports=@{
            post_route_timing=@{present=$true;wns_ns=0.1;whs_ns=0.01;tns_ns=0;ths_ns=0;no_clock_count=0;unconstrained_internal_endpoint_count=0;no_input_delay_count=0;no_output_delay_count=0}
            post_route_drc=@{present=$true;report_parse_complete=$true;release_approved=$true;error_count=0;critical_warning_count=0;unapproved_warning_count=0}
        }
    }
    Assert-ImplementationResult $implementation
    Expect $true 'One routed timing/DRC result can be exported without a sweep or board run'
    foreach ($field in @('wns_ns', 'whs_ns', 'tns_ns', 'ths_ns', 'no_clock_count', 'unconstrained_internal_endpoint_count', 'no_input_delay_count', 'no_output_delay_count')) {
        $bad = Clone $implementation
        $bad.reports.post_route_timing.$field = if ($field -in @('wns_ns','whs_ns','tns_ns','ths_ns')) { -0.1 } else { 1 }
        Reject { Assert-ImplementationResult $bad } "Implementation timing failure rejected: $field"
    }
    $bad = Clone $implementation
    $bad.reports.post_route_timing.wns_ns = $null
    Reject { Assert-ImplementationResult $bad } 'Missing slack is not treated as zero'
    $bad = Clone $implementation
    $bad.reports.post_route_drc.unapproved_warning_count = 1
    Reject { Assert-ImplementationResult $bad } 'Unapproved DRC warning rejected'

    $boardFixture = Join-Path $fixture 'board-build'
    $boardFiles = @('fpga/fpga_sources.f', 'fpga/vivado/basys3_build.tcl',
                   'fpga/boards/basys3/basys3.xdc', 'rtl/unit.v', 'scripts/builder.ps1')
    foreach ($file in $boardFiles) {
        $path = Join-Path $boardFixture $file
        New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
        Set-Content -LiteralPath $path -Value $(if ($file -eq 'fpga/fpga_sources.f') { 'rtl/unit.v' } else { 'fixture' }) -Encoding ASCII
    }
    Push-Location $boardFixture
    try {
        $build = Clone $implementation
        $build.source_inputs = @(foreach ($path in $boardFiles) { @{path=$path;sha256=(Get-FileHash $path).Hash.ToLowerInvariant()} })
        $build | Add-Member -NotePropertyName source_fingerprint -NotePropertyValue (Get-ReleaseFingerprint $build.source_inputs)
        $matched = Get-CanonicalBasys3BuildInputIdentity $build
        Expect ($matched.inputs.Count -eq 5) 'Board identity accepts the complete build manifest including tooling'
        $bad = Clone $build
        $bad.source_inputs = @($bad.source_inputs | Where-Object path -ne 'rtl/unit.v')
        $bad.source_fingerprint = Get-ReleaseFingerprint $bad.source_inputs
        Reject { Get-CanonicalBasys3BuildInputIdentity $bad } 'Board identity rejects omitted RTL even with a recomputed fingerprint'
        $boardBuild = Clone $build
        foreach ($field in @{
            mode='bitstream'; bitstream_status='pass'; top='RISCVCPU_basys3_top'
            part='xc7a35tcpg236-1'; architecture_profile='default'; timing_period_ns=10
            bitstream='image.bit'
        }.GetEnumerator()) { $boardBuild | Add-Member -NotePropertyName $field.Key -NotePropertyValue $field.Value }
        Set-Content image.bit 'synthetic bitstream' -Encoding ASCII
        $boardBuild | Add-Member -NotePropertyName bitstream_sha256 -NotePropertyValue (Get-FileHash image.bit).Hash.ToLowerInvariant()
        Write-ResultJson @{top_module='RISCVCPU_basys3_top';fpga_part='xc7a35tcpg236-1'} 'fpga/boards/basys3/board.json'
        Write-ResultJson $boardBuild 'results/vivado-basys3-build-summary.json'
        $matched = Get-CanonicalBasys3Evidence -AllowPendingPhysicalEvidence
        Expect ($matched.bitstream_sha256 -eq $boardBuild.bitstream_sha256) 'Canonical board image requires the actual build hash'
        Add-Content image.bit 'changed'
        Reject { Get-CanonicalBasys3Evidence -AllowPendingPhysicalEvidence } 'Board image tampering rejected without an explicit requested hash'
        Set-Content image.bit 'synthetic bitstream' -Encoding ASCII
        $boardBuild.architecture_profile = 'fast_cpu'
        Write-ResultJson $boardBuild 'results/vivado-basys3-build-summary.json'
        Reject { Get-CanonicalBasys3Evidence -AllowPendingPhysicalEvidence } 'Default MATVEC board workflow rejects a CPU-only image'
        Add-Content scripts/builder.ps1 'changed'
        Reject { Get-CanonicalBasys3BuildInputIdentity $build } 'Board identity rejects changed build tooling'
    } finally { Pop-Location }

    Set-Content -LiteralPath (Join-Path $fixture 'input.txt') -Value 'original input' -Encoding ASCII
    $stage = New-ReleaseStage $fixture
    Write-FixturePackage $stage
    $result = Assert-ReleasePackage $stage $fixture -RequireCurrent
    Expect ($result.source_match -eq 'current' -and $result.artifacts -eq 2) 'Valid package and exact inventory accepted'
    $savedManifest = Read-ReleaseJson (Join-Path $stage 'artifacts.json')
    foreach ($path in @('../outside', '/absolute', 'C:/absolute', 'a//b', 'a/./b', 'a\b')) {
        Reject { Resolve-ReleasePath $stage $path } "Unsafe path rejected: $path"
    }
    $bad = Clone $savedManifest
    $bad[0].sha256 = '0' * 64
    Write-ResultJson $bad (Join-Path $stage 'artifacts.json')
    Reject { Assert-ReleaseManifest $stage } 'Artifact digest mismatch rejected'
    $bad = Clone $savedManifest
    $bad[0].bytes += 1
    Write-ResultJson $bad (Join-Path $stage 'artifacts.json')
    Reject { Assert-ReleaseManifest $stage } 'Artifact length mismatch rejected'
    Write-ResultJson @($savedManifest[0], $savedManifest[0]) (Join-Path $stage 'artifacts.json')
    Reject { Assert-ReleaseManifest $stage } 'Duplicate artifact rejected'
    Write-ResultJson $savedManifest (Join-Path $stage 'artifacts.json')
    Set-Content -LiteralPath (Join-Path $stage 'extra.txt') -Value 'extra'
    Reject { Assert-ReleaseManifest $stage } 'Unlisted artifact rejected'
    Remove-Item -LiteralPath (Join-Path $stage 'extra.txt')
    Move-Item -LiteralPath (Join-Path $stage 'package.json') -Destination (Join-Path $fixture 'saved-package.json')
    Reject { Assert-ReleaseManifest $stage } 'Missing artifact rejected'
    Move-Item -LiteralPath (Join-Path $fixture 'saved-package.json') -Destination (Join-Path $stage 'package.json')
    $source = Read-ReleaseJson (Join-Path $stage 'source-inputs.json')
    Reject { Get-ReleaseFingerprint @($source.inputs[0], $source.inputs[0]) } 'Duplicate source path rejected'
    Set-Content -LiteralPath (Join-Path $fixture 'input.txt') -Value 'changed input' -Encoding ASCII
    Expect ((Assert-ReleasePackage $stage $fixture).source_match -eq 'historical') 'Intact old evidence is labeled historical'
    Reject { Assert-ReleasePackage $stage $fixture -RequireCurrent } 'Historical evidence cannot be published as current'
    Write-FixturePackage $stage
    Publish-ReleasePackage $stage 'release/configuration/generic_uart_boot_runtime' $fixture
    $published = Join-Path $fixture 'release/configuration/generic_uart_boot_runtime'
    $before = (Get-FileHash -LiteralPath (Join-Path $published 'artifacts.json')).Hash
    $stage = New-ReleaseStage $fixture
    Write-FixturePackage $stage
    Set-Content -LiteralPath (Join-Path $stage 'package.json') -Value 'broken'
    Reject { Publish-ReleasePackage $stage 'release/configuration/generic_uart_boot_runtime' $fixture } 'Invalid staged package refused'
    Expect ((Get-FileHash -LiteralPath (Join-Path $published 'artifacts.json')).Hash -eq $before) 'Failed publication preserves previous package'
    Assert-ReleasePackage $published $fixture -RequireCurrent | Out-Null
    Write-FixturePackage $stage
    Reject { Publish-ReleasePackage $stage '../outside' $fixture } 'Publication destination is restricted'
    Publish-ReleasePackage $stage 'release/configuration/generic_uart_boot_runtime' $fixture
    Expect (-not (Test-Path -LiteralPath $stage)) 'Validated replacement publishes and clears its staging path'
    $textPath = Join-Path $fixture 'paths.txt'
    Set-Content -LiteralPath $textPath -Value ($root + "`n" + $root.Replace('\', '\\') + "`nHost : private-host")
    Copy-ReleaseText $textPath (Join-Path $fixture 'public.txt') $root
    $public = Get-Content -LiteralPath (Join-Path $fixture 'public.txt') -Raw
    Expect (-not $public.Contains($root) -and -not $public.Contains('private-host')) 'Derivative reports redact repository and host metadata'

    # A small committed repository exercises the entire portable-package path.
    $mini = Join-Path $fixture 'portable-repository'
    New-Item -ItemType Directory -Force -Path (Join-Path $mini 'docs') | Out-Null
    $compactCatalog = @{schema_version=3;defaults=@{included_in_full_regression=$true};tests=@(@{name='a'},@{name='b'})}
    Write-ResultJson $compactCatalog (Join-Path $mini 'docs/test_catalog.json')
    & git -C $mini init -q
    & git -C $mini add docs/test_catalog.json
    & git -C $mini -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm 'Synthetic package inputs'
    if ($LASTEXITCODE) { throw 'Cannot prepare portable package fixture' }
    Push-Location $mini
    try { $id = Get-VerificationSourceIdentity -IncludeRecords } finally { Pop-Location }
    $portable = New-ReleaseStage $mini
    Copy-Item -LiteralPath (Join-Path $mini 'docs/test_catalog.json') -Destination (Join-Path $portable 'test_catalog.json')
    $records = [ordered]@{'check-summary.json'=$check; 'regression-summary.json'=$regression; 'test-catalog-summary.json'=$catalogResult; 'regression-evidence-summary.json'=$coverage}
    $gates = @(foreach ($name in $records.Keys) {
        $r = Clone $records[$name]
        foreach ($field in @('verification_input_fingerprint','verification_input_count','verification_working_tree_dirty','source_commit')) {
            $r | Add-Member -NotePropertyName $field -NotePropertyValue $id[$field]
        }
        Write-ResultJson $r (Join-Path $portable "evidence/$name")
        @{path="evidence/$name";required=$true}
    })
    Write-ResultJson @{hash_mode='verification';fingerprint=$id.verification_input_fingerprint;inputs=$id.inputs} (Join-Path $portable 'source-inputs.json')
    Write-ResultJson @{schema_version=1;kind='portable';status='pass';source_commit=$id.source_commit;source_fingerprint=$id.verification_input_fingerprint;input_count=$id.verification_input_count;gates=$gates} (Join-Path $portable 'package.json')
    Write-ReleaseManifest $portable
    Expect ((Assert-ReleasePackage $portable $mini -RequireCurrent).source_match -eq 'current') 'Complete portable package accepts compact catalog defaults and passed simulation status'
    Publish-ReleasePackage $portable 'release/current' $mini
    $portable = Join-Path $mini 'release/current'
    New-Item -ItemType Directory -Force -Path (Join-Path $mini 'rtl') | Out-Null
    Set-Content -LiteralPath (Join-Path $mini 'rtl/new.v') -Value '// added verification input'
    Expect ((Assert-ReleasePackage $portable $mini).source_match -eq 'historical') 'New source file makes portable evidence historical'
    Reject { Assert-ReleasePackage $portable $mini -RequireCurrent } 'Current-only audit rejects added source inputs'
    Remove-Item -LiteralPath (Join-Path $mini 'rtl/new.v')
    $bad = Read-ReleaseJson (Join-Path $portable 'test_catalog.json')
    $bad.tests[0] | Add-Member -NotePropertyName description -NotePropertyValue 'changed after verification'
    Write-ResultJson $bad (Join-Path $portable 'test_catalog.json')
    Write-ReleaseManifest $portable
    Reject { Assert-ReleasePackage $portable $mini } 'Catalog copy must match the verified source hash even when artifact hashes are recomputed'
    $summary.status = 'pass'
} catch { $summary.status='fail'; $summary.error_message=$_.Exception.Message; throw }
finally {
    $summary.checks = $checks.ToArray()
    $summary.fixture = Complete-TestFixture $root $fixture $summary.status
    Write-ResultJson $summary $output
}
Write-Host "PASS: $($checks.Count) release provenance and publication checks"
