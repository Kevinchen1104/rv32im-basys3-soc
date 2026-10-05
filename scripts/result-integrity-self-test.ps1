# Fault injection for optional result writers; all failures run in isolated fixtures.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. "$PSScriptRoot/process-runner.ps1"
. "$PSScriptRoot/artifact-paths.ps1"
$fixture = Join-Path $root ('build/tests/result-integrity/' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path "$fixture/scripts", "$fixture/results" | Out-Null
$names = @('verilator-lint','synth-smoke','formal-smoke','formal-matvec-smoke')
$extraWriters = @('regression-evidence-report','check-test-catalog','vivado-basys3-robustness','trace-lockstep-seed-smoke','basys3-board-demo')
foreach ($file in @('process-runner.ps1','result-format.ps1','script-common.ps1','reference-common.ps1','verification-source-identity.ps1','arch-test-run.ps1','showcase-demo.ps1','interactive-showcase-demo.ps1','fpga-smoke.ps1','test-catalog.ps1') + @($extraWriters | ForEach-Object { "$_.ps1" }) + @($names | Where-Object { $_ -ne 'formal-matvec-smoke' } | ForEach-Object { "$_.ps1" })) {
    Copy-Item -LiteralPath "$PSScriptRoot/$file" -Destination "$fixture/scripts/$file"
}
$summary = [ordered]@{ status='running'; checks=@(); error_message=$null }
$output = Join-Path $root 'results/result-integrity-self-test-summary.json'
Write-ResultJson $summary $output
try {
    $sample = [ordered]@{ text='quoted "value" and { bracket }'; nested=@(@{ a=1; b=@(1,2,3) }); empty=@() }
    Write-ResultJson $sample "$fixture/format.json"
    $roundTrip = Get-Content "$fixture/format.json" -Raw | ConvertFrom-Json
    if ($roundTrip.text -ne $sample.text -or $roundTrip.nested[0].b.Count -ne 3) { throw 'JSON formatter changed values' }
    $summary.checks += 'JSON format round trip'
    $shell = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $absoluteLog = Join-Path $fixture 'absolute-path.log'
    $absoluteRun = Invoke-LoggedProcess -FilePath $shell -Arguments @('-NoProfile','-Command',"Write-Output 'absolute log check'") -WorkingDirectory $fixture -LogPath $absoluteLog -TimeoutSeconds 30 -Quiet
    if ($absoluteRun.status -ne 'passed' -or -not (Test-Path -LiteralPath $absoluteLog)) { throw 'Absolute log path was not handled correctly' }
    $summary.checks += 'Absolute log path is preserved'
    foreach ($name in $names) {
        $path = "$fixture/results/$name-summary.json"
        Write-ResultJson @{status='pass'; marker='old success'} $path
        $scriptName = if ($name -eq 'formal-matvec-smoke') { 'formal-smoke' } else { $name }
        $code = '$env:PATH=""; & ''' + "$fixture/scripts/$scriptName.ps1" + "'"
        if ($name -eq 'formal-matvec-smoke') { $code += ' -Group Matvec' }
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
        $run = Invoke-LoggedProcess -FilePath $shell -Arguments @('-NoProfile','-EncodedCommand',$encoded) -WorkingDirectory $fixture -LogPath "$name.log" -TimeoutSeconds 30 -Quiet
        $actual = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($run.status -eq 'passed' -or $actual.status -ne 'fail' -or -not $actual.error_message -or $actual.marker) {
            throw "$name retained stale success or omitted its failure"
        }
        $summary.checks += "$name missing tool replaces old PASS with diagnostic failure"
    }
    $path = "$fixture/results/arch-test-results.json"
    Write-ResultJson @{status='pass'; marker='old success'} $path
    $run = Invoke-LoggedProcess -FilePath $shell -Arguments @('-NoProfile','-File',"$fixture/scripts/arch-test-run.ps1",'-ProfilePath','missing-profile.json') -WorkingDirectory $fixture -LogPath 'arch-test-missing-profile.log' -TimeoutSeconds 30 -Quiet
    $actual = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($run.status -eq 'passed' -or $actual.status -ne 'fail' -or -not $actual.error_message -or $actual.marker) {
        throw 'arch-test retained stale success after a missing profile'
    }
    $summary.checks += 'arch-test missing profile replaces old PASS with diagnostic failure'
    foreach ($case in @(
        @('showcase-demo', 'showcase-summary'),
        @('interactive-showcase-demo', 'interactive-showcase-summary'),
        @('fpga-smoke', 'fpga-smoke-summary')
    )) {
        $path = "$fixture/results/$($case[1]).json"
        Write-ResultJson @{status='pass'; marker='old success'} $path
        $run = Invoke-LoggedProcess -FilePath $shell -Arguments @('-NoProfile','-File',"$fixture/scripts/$($case[0]).ps1") -WorkingDirectory $fixture -LogPath "$($case[0])-missing-input.log" -TimeoutSeconds 30 -Quiet
        $actual = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($run.status -eq 'passed' -or $actual.status -ne 'fail' -or -not $actual.error_message -or $actual.marker) {
            throw "$($case[0]) retained stale success after a missing input"
        }
        $summary.checks += "$($case[0]) missing input replaces old PASS with diagnostic failure"
    }
    foreach ($case in @(
        @('regression-evidence-report','regression-evidence-summary'),
        @('check-test-catalog','test-catalog-summary'),
        @('vivado-basys3-robustness','vivado-basys3-robustness-summary'),
        @('trace-lockstep-seed-smoke','trace-lockstep-seed-smoke-summary'),
        @('basys3-board-demo','board-precondition-summary')
    )) {
        $path = "$fixture/results/$($case[1]).json"
        Write-ResultJson @{status='pass'; marker='old success'} $path
        $arguments = @('-NoProfile','-File',"$fixture/scripts/$($case[0]).ps1")
        if ($case[0] -eq 'basys3-board-demo') { $arguments += @('-Target','FullDirect100','-Demo','Matvec','-Port','INVALID','-DryRun','-SummaryPath',$path) }
        $run = Invoke-LoggedProcess -FilePath $shell -Arguments $arguments -WorkingDirectory $fixture -LogPath "$($case[0])-precondition.log" -TimeoutSeconds 60 -Quiet
        $actual = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($run.status -eq 'passed' -or $actual.status -notin @('fail','failed') -or $actual.marker -or (-not $actual.error_message -and -not $actual.error)) {
            throw "$($case[0]) retained an old PASS or omitted failure diagnostics"
        }
        $summary.checks += "$($case[0]) replaces old PASS before checking prerequisites"
    }
    # A syntactically successful regression from other inputs must still be rejected.
    New-Item -ItemType Directory -Force -Path "$fixture/docs" | Out-Null
    Copy-Item "$root/docs/test_catalog.json" "$fixture/docs/test_catalog.json"
    & git -C $fixture init -q
    & git -C $fixture add scripts docs
    & git -C $fixture -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture
    if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize the source-identity fixture' }
    Write-ResultJson @{status='passed'; verification_input_fingerprint=('0' * 64); tests=@()} "$fixture/results/regression-summary.json"
    $run = Invoke-LoggedProcess -FilePath $shell -Arguments @('-NoProfile','-File',"$fixture/scripts/regression-evidence-report.ps1") -WorkingDirectory $fixture -LogPath 'stale-regression.log' -TimeoutSeconds 30 -Quiet
    $actual = Get-Content "$fixture/results/regression-evidence-summary.json" -Raw | ConvertFrom-Json
    if ($run.status -eq 'passed' -or $actual.error_message -notmatch 'inputs do not match') { throw 'Stale regression fingerprint was not rejected' }
    $summary.checks += 'Regression report rejects a successful result from different source inputs'

    # Preserve a user's locally edited reference even when all seed simulations fail.
    foreach ($name in @('generated-reference-seed-smoke','random-memory-reference','random-control-reference','random-hazard-reference','random-call-reference')) {
        Copy-Item "$PSScriptRoot/$name.ps1" "$fixture/scripts/$name.ps1"
    }
    New-Item -ItemType Directory -Force -Path "$fixture/fixtures/generated/reference" | Out-Null
    Get-ChildItem "$root/fixtures/generated/reference" -File -Filter 'random_*' | ForEach-Object {
        Copy-Item $_.FullName "$fixture/fixtures/generated/reference/$($_.Name)"
    }
    $edited = "$fixture/fixtures/generated/reference/random_memory_reference.hex"
    Add-Content -LiteralPath $edited -Value 'deadbeef' -Encoding ASCII
    $before = (Get-FileHash $edited).Hash
    Set-Content -LiteralPath "$fixture/scripts/run.ps1" -Value "throw 'intentional simulation failure'" -Encoding ASCII
    $run = Invoke-LoggedProcess -FilePath $shell -Arguments @('-NoProfile','-File',"$fixture/scripts/generated-reference-seed-smoke.ps1") -WorkingDirectory $fixture -LogPath 'edited-reference.log' -TimeoutSeconds 120 -Quiet
    $actual = Get-Content "$fixture/results/generated-reference-seed-smoke-summary.json" -Raw | ConvertFrom-Json
    if ($run.status -eq 'passed' -or (Get-FileHash $edited).Hash -ne $before -or $actual.default_artifacts_unchanged -cne $true -or $actual.default_artifact_checks_passed -cne $false) {
        throw 'Seed smoke did not preserve and report the edited reference correctly'
    }
    $summary.checks += 'Failed seed simulations preserve a locally edited reference byte-for-byte'

    $probe = Join-Path $fixture 'cleanup-probe'
    New-Item -ItemType Directory -Force -Path $probe | Out-Null
    Set-Content -LiteralPath (Join-Path $probe 'input.txt') -Value 'temporary fixture'
    $kept = Complete-TestFixture $root $probe 'failed'
    if ($kept -ne $probe -or -not (Test-Path -LiteralPath $probe)) { throw 'Failed fixture was removed.' }
    $summary.checks += 'Failed self-test retains its fixture'
    $kept = Complete-TestFixture $root $probe 'passed'
    if ($null -ne $kept -or (Test-Path -LiteralPath $probe)) { throw 'Successful fixture was not removed.' }
    $summary.checks += 'Successful self-test cleans its temporary fixture'
    $rejected = $false
    try { $null = Assert-ArtifactPath (Join-Path $root 'build/tests') (Join-Path $root 'rtl') } catch { $rejected = $true }
    if (-not $rejected) { throw 'Cleanup accepted a source directory outside build/tests.' }
    $summary.checks += 'Cleanup rejects a path outside its allowed subtree'
    # Test the validator only: never attempt recursive removal through a link.
    $linkTarget = Join-Path $fixture 'junction-target'
    $linkPath = Join-Path $fixture 'junction-root'
    New-Item -ItemType Directory -Path "$linkTarget/child" -Force | Out-Null
    Set-Content -LiteralPath "$linkTarget/child/input.txt" -Value 'must survive'
    New-Item -ItemType Junction -Path $linkPath -Target $linkTarget | Out-Null
    try {
        foreach ($allowedRoot in @($fixture, $linkPath, "$linkPath/child")) {
            $rejected = $false
            try { $null = Assert-ArtifactPath $allowedRoot "$linkPath/child/input.txt" } catch { $rejected = $true }
            if (-not $rejected) { throw "Cleanup accepted a junction under, at, or above its root: $allowedRoot" }
        }
        if ((Get-Content -LiteralPath "$linkTarget/child/input.txt" -Raw).Trim() -ne 'must survive') {
            throw 'Junction validation changed the target.'
        }
        $summary.checks += 'Cleanup rejects junctions under, at, and above the allowed root without touching their targets'
    } finally {
        # Exact fixture-local junction; non-recursive deletion removes only the link.
        [IO.Directory]::Delete($linkPath)
    }
    $cleanupRoot = Join-Path $fixture 'cleanup-repository'
    New-Item -ItemType Directory -Force -Path "$cleanupRoot/scripts", "$cleanupRoot/build/sim", "$cleanupRoot/build/vivado/old", "$cleanupRoot/build/vivado/native_byte_lanes_9p5" | Out-Null
    foreach ($file in @('clean-artifacts.ps1','artifact-paths.ps1','result-format.ps1')) {
        Copy-Item -LiteralPath "$PSScriptRoot/$file" -Destination "$cleanupRoot/scripts/$file"
    }
    # The fixture contains only synthetic files. Stub process discovery in this
    # copied script so unrelated tools cannot make the test machine-dependent.
    $cleanupScript = "$cleanupRoot/scripts/clean-artifacts.ps1"
    $cleanupText = Get-Content -LiteralPath $cleanupScript -Raw
    $processStub = @'
function Get-Process {
    [CmdletBinding()]
    param([string[]]$Name)
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'active-tool')) {
        [pscustomobject]@{ ProcessName = 'vvp' }
    }
}
'@
    $cleanupText = $cleanupText.Replace("`$ErrorActionPreference = 'Stop'", "`$ErrorActionPreference = 'Stop'`n$processStub")
    Set-Content -LiteralPath $cleanupScript -Value $cleanupText -Encoding UTF8
    & git -C $cleanupRoot init -q
    if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize isolated cleanup test repository.' }
    foreach ($path in @('build/sim/test.vvp','build/vivado/old/post_route.dcp','build/vivado/old/result.rpt','build/vivado/old/board.bit','build/vivado/native_byte_lanes_9p5/post_route.dcp')) {
        Set-Content -LiteralPath (Join-Path $cleanupRoot $path) -Value 'synthetic cleanup input'
    }
    $run = Invoke-LoggedProcess -FilePath $shell -Arguments @('-NoProfile','-File',"$cleanupRoot/scripts/clean-artifacts.ps1") -LogPath 'cleanup-preview.log' -WorkingDirectory $fixture -TimeoutSeconds 30 -Quiet
    if ($run.status -ne 'passed' -or -not (Test-Path "$cleanupRoot/build/sim/test.vvp")) { throw 'Cleanup preview changed files.' }
    $summary.checks += 'Cleanup preview leaves simulator files intact'
    Set-Content -LiteralPath "$cleanupRoot/scripts/active-tool" -Value 'synthetic active simulator'
    $run = Invoke-LoggedProcess -FilePath $shell -Arguments @('-NoProfile','-File',$cleanupScript,'-Apply') -LogPath 'cleanup-active-tool.log' -WorkingDirectory $fixture -TimeoutSeconds 30 -Quiet
    if ($run.status -eq 'passed' -or -not (Test-Path "$cleanupRoot/build/sim/test.vvp")) { throw 'Cleanup did not protect an active simulator.' }
    Remove-Item -LiteralPath "$cleanupRoot/scripts/active-tool"
    $summary.checks += 'Cleanup refuses to remove artifacts while a tool is active'
    $run = Invoke-LoggedProcess -FilePath $shell -Arguments @('-NoProfile','-File',"$cleanupRoot/scripts/clean-artifacts.ps1",'-Apply') -LogPath 'cleanup-apply.log' -WorkingDirectory $fixture -TimeoutSeconds 30 -Quiet
    if ($run.status -ne 'passed' -or (Test-Path "$cleanupRoot/build/sim/test.vvp")) { throw 'Simulator cleanup failed.' }
    $run = Invoke-LoggedProcess -FilePath $shell -Arguments @('-NoProfile','-File',"$cleanupRoot/scripts/clean-artifacts.ps1",'-Category','RetiredCheckpoints','-RetiredBuildDirectory','build/vivado/old','-Apply') -LogPath 'cleanup-checkpoints.log' -WorkingDirectory $fixture -TimeoutSeconds 30 -Quiet
    if ($run.status -ne 'passed' -or (Test-Path "$cleanupRoot/build/vivado/old/post_route.dcp")) { throw 'Retired checkpoint cleanup failed.' }
    foreach ($path in @('build/vivado/old/result.rpt','build/vivado/old/board.bit','build/vivado/native_byte_lanes_9p5/post_route.dcp')) {
        if (-not (Test-Path (Join-Path $cleanupRoot $path))) { throw "Cleanup removed protected evidence: $path" }
    }
    $summary.checks += 'Cleanup removes old checkpoints but preserves reports, bitstreams and protected checkpoints'
    Set-Content -LiteralPath "$cleanupRoot/build/sim/tracked.vvp" -Value 'tracked safety fixture'
    & git -C $cleanupRoot add build/sim/tracked.vvp
    if ($LASTEXITCODE -ne 0) { throw 'Cannot prepare tracked cleanup fixture.' }
    $run = Invoke-LoggedProcess -FilePath $shell -Arguments @('-NoProfile','-File',"$cleanupRoot/scripts/clean-artifacts.ps1",'-Apply') -LogPath 'cleanup-tracked.log' -WorkingDirectory $fixture -TimeoutSeconds 30 -Quiet
    if ($run.status -eq 'passed' -or -not (Test-Path "$cleanupRoot/build/sim/tracked.vvp")) { throw 'Cleanup did not reject a tracked artifact.' }
    $summary.checks += 'Cleanup refuses Git-tracked files'
    $summary.status = 'pass'
} catch {
    $summary.status = 'fail'; $summary.error_message = $_.Exception.Message
    throw
} finally {
    $summary.fixture = $fixture
    try { $summary.fixture = Complete-TestFixture $root $fixture $summary.status } catch {
        $summary.status = 'fail'; $summary.error_message = $_.Exception.Message
        throw
    } finally { Write-ResultJson $summary $output }
}
Write-Host "PASS: $($summary.checks.Count) result-integrity checks"
