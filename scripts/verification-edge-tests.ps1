# Regression tests for reference helpers and the architectural-test harness itself.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. "$PSScriptRoot/process-runner.ps1"
. "$PSScriptRoot/reference-common.ps1"
. "$PSScriptRoot/script-common.ps1"
. "$PSScriptRoot/artifact-paths.ps1"
$fixture = Join-Path $root ('build/tests/verification-edges/' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path "$fixture/results/waveforms" | Out-Null
$summary = [ordered]@{status='running'; checks=@(); error_message=$null}
$output = Join-Path $root 'results/verification-edge-tests-summary.json'
Write-ResultJson $summary $output
try {
    $values = @(0L, 1L, 2047L, 2048L, 4095L, 4096L, 2147483647L, 2147483648L, 4294965248L, 4294967295L)
    $random = [Random]::new(451)
    for ($i = 0; $i -lt 1000; $i++) { $values += [int64]$random.Next(0, 65536) * 65536 + $random.Next(0, 65536) }
    foreach ($value in $values) {
        $parts = Split-LoadImmediate ([uint32]$value)
        $actual = (([int64]$parts.Upper * 4096) + $parts.Lower) -band 0xffffffffL
        if ($actual -ne $value -or $parts.Lower -lt -2048 -or $parts.Lower -gt 2047) {
            throw "LUI/ADDI split failed for $value"
        }
    }
    $summary.checks += 'LUI/ADDI reconstruction: 1010 boundary and fixed-seed values'

    $reportPath = Join-Path $fixture 'timing.rpt'
    Set-Content -LiteralPath $reportPath -Value 'test report' -Encoding ASCII
    $record = [pscustomobject]@{
        report_artifacts=@([pscustomobject]@{path='timing.rpt'; size_bytes=(Get-Item $reportPath).Length; sha256=(Get-FileHash $reportPath).Hash.ToLowerInvariant()})
        reports=[pscustomobject]@{
            timing=[pscustomobject]@{path=$reportPath}
            clocks=@([pscustomobject]@{name='sys_clk'; period_ns=10}, [pscustomobject]@{name='board_output_budget'; period_ns=10})
        }
    }
    Assert-BuildReportArtifacts $record $fixture
    Add-Content -LiteralPath $reportPath -Value 'tampered' -Encoding ASCII
    $rejected = $false
    try { Assert-BuildReportArtifacts $record $fixture } catch { $rejected = $true }
    if (-not $rejected) { throw 'Tampered build report was accepted' }
    $summary.checks += 'Build report manifest accepts paths and clock metadata arrays, and rejects changed contents'

    $binary = Join-Path $fixture 'arch.vvp'
    $compile = Invoke-LoggedProcess -FilePath 'iverilog' -Arguments @('-g2012','-s','tb_arch_test_signature','-o',$binary,'-f','rtl/rtl_sources.f','tb/reference/tb_arch_test_signature.v') -WorkingDirectory $root -LogPath "$fixture/compile.log" -TimeoutSeconds 60 -Quiet
    if ($compile.status -ne 'passed') { throw "Architecture harness compilation failed: $($compile.log)" }
    $failProgram = @('0400006f') + @('00000013') * 15 + @('0000006f')
    $failProgram[2] = '0000006f' # Fetched along the wrong path, never retired.
    $dirtyProgram = @('000010b7','02a00113','0020a023') + @('00000013') * 13 + @('0000006f')
    Write-AsciiLfFile "$fixture/fail.hex" $failProgram
    Write-AsciiLfFile "$fixture/dirty.hex" $dirtyProgram
    Write-AsciiLfFile "$fixture/zero.hex" @('00000000')
    Write-AsciiLfFile "$fixture/expected.hex" @('0000002a')
    Write-AsciiLfFile "$fixture/unknown.hex" @('xxxxxxxx')
    $cases = @(
        @{name='wrong-path-pass'; program='fail.hex'; expected='zero.hex'; words=1; pass=8; fail=64; succeeds=$false},
        @{name='dirty-signature'; program='dirty.hex'; expected='expected.hex'; words=1; pass=64; fail=-1; succeeds=$true},
        @{name='empty-signature'; program='dirty.hex'; expected='expected.hex'; words=0; pass=64; fail=-1; succeeds=$false},
        @{name='overflow-signature-range'; program='dirty.hex'; expected='expected.hex'; words=1; start=2147483647; pass=64; fail=-1; succeeds=$false},
        @{name='unknown-signature'; program='dirty.hex'; expected='unknown.hex'; words=1; pass=64; fail=-1; succeeds=$false}
    )
    foreach ($case in $cases) {
        Write-AsciiLfFile "$fixture/actual.hex" @('deadbeef')
        $start = if ($case.ContainsKey('start')) { $case.start } else { 1024 }
        $arguments = @($binary, "+program_hex=$($case.program)", "+expected_signature=$($case.expected)", '+dut_signature=actual.hex', "+signature_start=$start", "+signature_words=$($case.words)", "+tohost_pass_pc=$($case.pass)", "+tohost_fail_pc=$($case.fail)", '+timeout_cycles=500')
        $run = Invoke-LoggedProcess -FilePath 'vvp' -Arguments $arguments -WorkingDirectory $fixture -LogPath "$($case.name).log" -TimeoutSeconds 30 -Quiet
        if (($run.status -eq 'passed') -ne $case.succeeds) { throw "Unexpected architecture harness result: $($case.name), $($run.log)" }
        $actual = (Get-Content -LiteralPath "$fixture/actual.hex" -Raw)
        if ($actual -match 'deadbeef') { throw 'Failed harness run kept stale signature output' }
        if ($case.succeeds -and $actual.Trim() -ne '0000002a') { throw 'Dirty cache signature was not exported correctly' }
        $summary.checks += "Architecture harness: $($case.name)"
    }
    $traceBinary = Join-Path $fixture 'trace.vvp'
    $compile = Invoke-LoggedProcess -FilePath 'iverilog' -Arguments @('-g2012','-s','tb_trace_lockstep_reference','-o',$traceBinary,'-f','rtl/rtl_sources.f','tb/reference/tb_trace_lockstep_reference.v') -WorkingDirectory $root -LogPath "$fixture/trace-compile.log" -TimeoutSeconds 60 -Quiet
    if ($compile.status -ne 'passed') { throw 'Trace harness compilation failed' }
    Write-AsciiLfFile "$fixture/trace.hex" @('00000000000000130000000000000000', '00000004000000130000000000000000')
    $run = Invoke-LoggedProcess -FilePath 'vvp' -Arguments @($traceBinary, '+program_hex=dirty.hex', '+expected_trace=trace.hex', '+trace_count=1') -WorkingDirectory $fixture -LogPath "$fixture/trace-prefix.log" -TimeoutSeconds 30 -Quiet
    if ($run.status -ne 'failed' -or (Get-Content -LiteralPath $run.log -Raw) -notmatch 'complete reference trace') { throw 'Trace prefix was not rejected' }
    $summary.checks += 'Trace harness rejects a requested prefix of the complete reference'
    $summary.status = 'pass'
} catch { $summary.status='fail'; $summary.error_message=$_.Exception.Message; throw }
finally {
    $summary.fixture = Complete-TestFixture $root $fixture $summary.status
    Write-ResultJson $summary $output
}
Write-Host "PASS: $($summary.checks.Count) verification edge checks"
