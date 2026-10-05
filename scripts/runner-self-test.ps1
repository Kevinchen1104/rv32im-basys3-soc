<#
Script: scripts/runner-self-test.ps1
Purpose: Exercises runner diagnostics, deadlines, waveform accounting, and live counter exports.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts/runner-self-test.ps1
Outputs:
  results/runner-self-test-summary.json and isolated fixtures/logs under build/tests/runner/.
Scope:
  Tests the execution/reporting scripts with small synthetic programs and testbenches.
#>
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'process-runner.ps1')
. "$PSScriptRoot/artifact-paths.ps1"
$fixture = Join-Path $root ('build/tests/runner/' + [guid]::NewGuid().ToString('N') + ' space')
$shell = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$checks = New-Object 'System.Collections.Generic.List[string]'
$summaryFile = Join-Path $root 'results/runner-self-test-summary.json'
$status = 'running'
$errorMessage = $null
New-Item -ItemType Directory -Force -Path $fixture, (Split-Path -Parent $summaryFile) | Out-Null

function Assert-Runner {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Write-Fixture {
    param([string]$RelativePath, [string]$Text)
    $path = Join-Path $fixture $RelativePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    Set-Content -LiteralPath $path -Value $Text -Encoding Ascii
}
function Invoke-Snippet {
    param([string]$Name, [string]$Code, [int]$Timeout = 30)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code))
    Invoke-LoggedProcess -FilePath $shell -Arguments @('-NoProfile', '-EncodedCommand', $encoded) `
        -WorkingDirectory $fixture -LogPath "$Name.log" -TimeoutSeconds $Timeout -Quiet
}
function Invoke-FixtureRunner {
    param([string]$Name = 'alu', [int]$Timeout = 10, [switch]$NoTools)
    $script = Join-Path $fixture 'scripts/run.ps1'
    $code = if ($NoTools) { '$env:PATH = ""; ' } else { '' }
    $code += "& '$($script.Replace("'", "''"))' -Test '$Name' -SkipAssemble -OpenWave -TimeoutSeconds $Timeout -SummaryJson results/result.json"
    $execution = Invoke-Snippet -Name "run-$($checks.Count)" -Code $code -Timeout 30
    $summary = Get-Content -LiteralPath (Join-Path $fixture 'results/result.json') -Raw | ConvertFrom-Json
    return @{ Execution = $execution; Summary = $summary }
}
function Check-Failure {
    param($Run, [string]$ExpectedStatus)
    Assert-Runner ($Run.Execution.status -eq 'failed') 'Failed runner did not propagate a nonzero exit.'
    Assert-Runner ($Run.Summary.status -eq 'failed') 'A failed run retained a success summary.'
    Assert-Runner ($Run.Summary.tests[0].status -eq $ExpectedStatus) "Wrong failure status; expected $ExpectedStatus"
    Assert-Runner ($Run.Summary.failed -eq 1 -and $Run.Summary.passed -eq 0) 'Wrong failure counts.'
}

try {
    $runText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'run.ps1') -Raw
    $sourcesBlock = [regex]::Match($runText, '(?s)\$testSources\s*=\s*\[ordered\]@\{(.*?)\n\}').Groups[1].Value
    $noWaveBlock = [regex]::Match($runText, '(?s)\$testsWithoutWaveforms\s*=\s*@\((.*?)\)').Groups[1].Value
    $noWave = @([regex]::Matches($noWaveBlock, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    $entries = [regex]::Matches($sourcesBlock, '(?m)^\s*(\w+) = "([^"]+)"')
    Assert-Runner ($entries.Count -gt 0) 'Test manifest could not be read.'
    foreach ($entry in $entries) {
        $name = $entry.Groups[1].Value
        $source = Get-Content -LiteralPath (Join-Path $root $entry.Groups[2].Value) -Raw
        $dumps = @([regex]::Matches($source, '\$dumpfile\("([^"]+)"\)'))
        if ($noWave -contains $name) {
            Assert-Runner ($dumps.Count -eq 0) "Waveform contract is stale for $name"
        } else {
            $expected = if ($name -eq 'main') { 'results/waveforms/dump.vcd' } else { "results/waveforms/tb_$name.vcd" }
            Assert-Runner ($dumps.Count -eq 1 -and $dumps[0].Groups[1].Value -eq $expected) "Waveform contract is stale for $name"
        }
    }
    $checks.Add('waveform declarations match all testbench dump paths')

    $run = Invoke-Snippet 'streams' '[Console]::Out.WriteLine("hello out"); [Console]::Error.WriteLine("hello err"); exit 7'
    $log = Get-Content -LiteralPath (Join-Path $fixture $run.log) -Raw
    Assert-Runner ($run.status -eq 'failed' -and $run.exit_code -eq 7) 'Native exit code was not preserved.'
    Assert-Runner ($log.Contains('hello out') -and $log.Contains('hello err')) 'One output stream was lost.'
    $checks.Add('native exit code and both output streams')

    $unicodeText = [string][char]0x6e2c + [char]0x8a66 + ' diagnostic'
    # Windows PowerShell can replace non-ANSI characters before emitting Write-Error.
    # Test the runner's Unicode byte transport separately from that host limitation.
    $run = Invoke-Snippet 'unicode-streams' ('$bytes = [Text.Encoding]::UTF8.GetBytes("' + $unicodeText + '"); ' +
        '[Console]::OpenStandardOutput().Write($bytes, 0, $bytes.Length); ' +
        '[Console]::OpenStandardError().Write($bytes, 0, $bytes.Length); exit 1')
    $log = Get-Content -LiteralPath (Join-Path $fixture $run.log) -Raw -Encoding UTF8
    Assert-Runner ($run.status -eq 'failed' -and ([regex]::Matches($log, [regex]::Escape($unicodeText))).Count -eq 2) 'Unicode stdout/stderr bytes were corrupted.'
    $xml = '#< CLIXML' + "`n" + [Management.Automation.PSSerializer]::Serialize($unicodeText)
    Assert-Runner ((ConvertFrom-ProcessCliXml $xml) -eq $unicodeText) 'Unicode CLIXML decoding changed text.'
    $run = Invoke-Snippet 'powershell-error' 'Write-Error "PowerShell diagnostic"; exit 1'
    $log = Get-Content -LiteralPath (Join-Path $fixture $run.log) -Raw -Encoding UTF8
    Assert-Runner ($run.status -eq 'failed' -and $log.Contains('PowerShell diagnostic')) 'PowerShell error text or failure status was lost.'
    Assert-Runner (-not $log.Contains('#< CLIXML') -and -not $log.Contains([string][char]0xfffd)) 'Error log retained XML or replacement characters.'
    Assert-Runner ((ConvertFrom-ProcessBytes ([Text.Encoding]::UTF8.GetBytes($unicodeText))) -eq $unicodeText) 'UTF-8 output decoding changed text.'
    $legacyText = 'caf' + [char]0x00e9 + ' diagnostic'
    $legacyBytes = [Text.Encoding]::GetEncoding(1252).GetBytes($legacyText)
    Assert-Runner ((ConvertFrom-ProcessBytes $legacyBytes -EncodingName 'windows-1252') -eq $legacyText) 'Explicit legacy output decoding changed text.'
    $checks.Add('Unicode stdout/stderr decoding and readable PowerShell errors')

    Write-Fixture 'argument echo.ps1' 'param([string]$Value, [string]$Empty); [Console]::Out.WriteLine("VALUE=<$Value>;EMPTY=<$Empty>")'
    $value = 'space and "quotes" with slash\'
    $run = Invoke-LoggedProcess -FilePath $shell `
        -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $fixture 'argument echo.ps1'), '-Value', $value, '-Empty', '') `
        -WorkingDirectory $fixture -LogPath 'arguments.log' -Quiet
    $log = Get-Content -LiteralPath (Join-Path $fixture $run.log) -Raw
    Assert-Runner ($run.status -eq 'passed' -and $log.Contains("VALUE=<$value>;EMPTY=<>")) 'Argument quoting changed an argument.'
    $checks.Add('spaces, quotes, trailing backslash, and empty argument')

    $run = Invoke-LoggedProcess -FilePath (Join-Path $fixture 'missing-tool') -WorkingDirectory $fixture -LogPath 'missing.log' -Quiet
    Assert-Runner ($run.status -eq 'start_failed' -and $null -eq $run.exit_code -and $run.error_message) 'Missing tool status is incorrect.'
    $checks.Add('tool cannot be started')

    $run = Invoke-Snippet 'timeout' '[Console]::Out.WriteLine("before timeout"); [Console]::Error.WriteLine("partial stderr"); Start-Sleep 20' -Timeout 2
    $log = Get-Content -LiteralPath (Join-Path $fixture $run.log) -Raw
    Assert-Runner ($run.status -eq 'timed_out') 'Deadline was not enforced.'
    Assert-Runner ($log.Contains('before timeout') -and $log.Contains('partial stderr')) 'Partial timeout output was lost.'
    $checks.Add('deadline and partial stdout/stderr')

    $run = Invoke-Snippet 'inherited-pipe' @'
[Console]::Out.WriteLine('parent output')
$child = [Diagnostics.ProcessStartInfo]@{ FileName='powershell'; Arguments='-NoProfile -Command "Start-Sleep 8; Write-Output child"'; UseShellExecute=$false; CreateNoWindow=$true }
[void][Diagnostics.Process]::Start($child)
'@ -Timeout 2
    $log = Get-Content -LiteralPath (Join-Path $fixture $run.log) -Raw
    Assert-Runner ($run.status -eq 'timed_out' -and $run.duration_ms -lt 5000 -and $log.Contains('parent output')) 'An inherited pipe bypassed the deadline or lost output.'
    $checks.Add('deadline includes inherited output pipes after parent exit')

    New-Item -ItemType Directory -Force -Path (Join-Path $fixture 'scripts') | Out-Null
    foreach ($name in @('run.ps1', 'process-runner.ps1', 'result-format.ps1', 'perf-counter-data.ps1', 'perf-counter-export.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $fixture "scripts/$name")
    }
    # Source identity already has its own self-test; isolate this fixture from Git.
    Write-Fixture 'scripts/verification-source-identity.ps1' @'
function Get-VerificationSourceIdentity { return @{ verification_input_fingerprint='fixture' } }
function Add-VerificationIdentityFields { param($Summary, $Identity=(Get-VerificationSourceIdentity)); $Summary.source_commit='fixture'; return $Identity }
function Assert-VerificationInputsUnchanged { param($Identity) }
'@
    Write-Fixture 'rtl/rtl_sources.f' 'rtl/empty.v'
    Write-Fixture 'rtl/empty.v' 'module empty; endmodule'
    Write-Fixture 'tb/unit/core/tb_alu.v' 'module t; initial begin $dumpfile("results/waveforms/tb_alu.vcd"); $dumpvars(0,t); $display("PASS: synthetic alu"); #1; $finish; end endmodule'
    # Do not launch a viewer for the positive waveform case.
    $script = Join-Path $fixture 'scripts/run.ps1'
    $run = Invoke-Snippet 'waveform' "& '$script' -Test alu -SkipAssemble -SummaryJson results/result.json"
    $s = Get-Content -LiteralPath (Join-Path $fixture 'results/result.json') -Raw | ConvertFrom-Json
    Assert-Runner ($run.status -eq 'passed' -and $s.status -eq 'passed') 'Waveform fixture failed.'
    Assert-Runner ($s.tests[0].waveform -like 'results/runs/*/waveforms/tb_alu.vcd') 'Generated VCD not reported in its context.'
    Assert-Runner (Test-Path -LiteralPath (Join-Path $fixture $s.tests[0].waveform)) 'Reported VCD does not exist.'
    Assert-Runner ($s.tools.iverilog.version -and $s.tools.vvp.version) 'Tool versions were not recorded.'
    $checks.Add('successful waveform, command metadata, and tool versions')
    $originalLog = Join-Path $fixture $s.tests[0].simulation.log
    $originalHash = (Get-FileHash -LiteralPath $originalLog).Hash
    $run = Invoke-Snippet 'other-seed' "& '$script' -Test alu -SkipAssemble -PlusArgs '+seed=303' -SummaryJson results/result.json"
    $seedSummary = Get-Content -LiteralPath (Join-Path $fixture 'results/result.json') -Raw | ConvertFrom-Json
    Assert-Runner ($run.status -eq 'passed' -and $seedSummary.tests[0].simulation.log -ne $s.tests[0].simulation.log) 'Different inputs shared a log path.'
    Assert-Runner ((Get-FileHash -LiteralPath $originalLog).Hash -eq $originalHash) 'Another input overwrote existing evidence.'
    Assert-Runner (Test-Path -LiteralPath (Join-Path $fixture "$($s.artifact_directory)/summary.json")) 'Result context lacks its own summary.'
    $checks.Add('different seeds preserve logs, waveforms, and context summary')

    Write-Fixture 'tb/unit/core/tb_csr_unit.v' 'module t; initial begin $display("PASS: no VCD"); $finish; end endmodule'
    Write-Fixture 'results/waveforms/tb_csr_unit.vcd' 'old file must not be reported'
    $r = Invoke-FixtureRunner -Name 'csr_unit'
    Assert-Runner ($r.Summary.status -eq 'passed' -and $null -eq $r.Summary.tests[0].waveform) 'Undeclared old VCD was reported.'
    $log = Get-Content -LiteralPath (Join-Path $fixture $r.Execution.log) -Raw
    Assert-Runner ($log.Contains('No waveform is generated') -and -not $log.Contains('Waveform written')) 'No-waveform message is incorrect.'
    $checks.Add('no waveform and OpenWave without a VCD')

    Write-Fixture 'tb/unit/core/tb_alu.v' 'this is intentionally invalid Verilog'
    $r = Invoke-FixtureRunner
    Check-Failure $r 'compile_failed'
    Assert-Runner ($null -eq $r.Summary.tests[0].waveform -and $null -eq $r.Summary.tests[0].simulation) 'Compile failure reused old outputs.'
    Assert-Runner (-not (Test-Path -LiteralPath (Join-Path $fixture 'results/waveforms/tb_alu.vcd'))) 'Old VCD was not removed.'
    $checks.Add('compile failure replaces stale PASS/VCD and skips simulation')

    Write-Fixture 'tb/unit/core/tb_alu.v' 'module t; initial begin $dumpfile("results/waveforms/tb_alu.vcd"); $dumpvars(0,t); #1; $fatal(1,"intentional simulation failure"); end endmodule'
    $r = Invoke-FixtureRunner
    Check-Failure $r 'simulation_failed'
    Assert-Runner ($r.Summary.tests[0].waveform_status -eq 'partial') 'Failure VCD was not marked partial.'
    $checks.Add('simulation failure and partial VCD')

    Write-Fixture 'tb/unit/core/tb_alu.v' 'module t; initial begin $display("before infinite simulation"); $fflush(); end always #1; endmodule'
    $r = Invoke-FixtureRunner -Timeout 1
    Check-Failure $r 'simulation_timed_out'
    $log = Get-Content -LiteralPath (Join-Path $fixture $r.Summary.tests[0].simulation.log) -Raw
    Assert-Runner ($log.Contains('before infinite simulation')) 'Simulation timeout output was lost.'
    $checks.Add('simulation timeout propagates failure and retains output')

    $r = Invoke-FixtureRunner -NoTools
    Check-Failure $r 'compile_start_failed'
    $checks.Add('missing compiler recorded in test summary')

    Write-Fixture 'tb/unit/core/tb_alu.v' 'module t; initial $finish; endmodule'
    $r = Invoke-FixtureRunner
    Check-Failure $r 'waveform_missing'
    Assert-Runner ($null -eq $r.Summary.tests[0].waveform) 'Missing declared artifact has a fake path.'
    $checks.Add('missing declared waveform')

    $r = Invoke-FixtureRunner -Name 'unknown_test'
    Assert-Runner ($r.Execution.status -eq 'failed' -and $r.Summary.status -eq 'failed' -and $r.Summary.total -eq 0) 'Unknown test retained a previous summary.'
    $checks.Add('setup failure replaces the prior summary')

    foreach ($case in @(
        @{Path='tb/unit/core/tb_perf_counters.v'; Name='perf_counters'; Prefix='perf counters'; Cycles=123},
        @{Path='tb/program/examples/tb_program_counter_loop.v'; Name='program_counter_loop'; Prefix='counter_loop'; Cycles=456}
    )) {
        Write-Fixture $case.Path ('module t; initial begin $dumpfile("results/waveforms/tb_' + $case.Name + '.vcd"); $dumpvars(0,t); ' +
            '$display("INFO: ' + $case.Prefix + ' cycles=' + $case.Cycles + ' retired=10 branch_miss=2 icache_miss=3 dcache_miss=4 stall_cycles=5"); #1; $finish; end endmodule')
    }
    $exportScript = Join-Path $fixture 'scripts/perf-counter-export.ps1'
    $run = Invoke-Snippet 'live-export' "& '$exportScript' -SkipAssemble -MeasureOnly" -Timeout 60
    Assert-Runner ($run.status -eq 'passed') 'Live counter export failed.'
    $json = Get-Content -LiteralPath (Join-Path $fixture 'results/perf-counter-comparison.json') -Raw | ConvertFrom-Json
    $csv = @(Import-Csv -LiteralPath (Join-Path $fixture 'results/perf-counter-comparison.csv'))
    Assert-Runner ($json.status -eq 'measured' -and -not $json.expected_values_checked) 'Unchecked measurements were labeled as verified.'
    Assert-Runner ($json.Rows[0].Cycles -eq 123 -and $json.Rows[1].Cycles -eq 456) 'JSON exported expectations instead of measurements.'
    Assert-Runner ($csv[0].Cycles -eq 123 -and $csv[1].Cycles -eq 456) 'CSV exported expectations instead of measurements.'
    $checks.Add('CSV and JSON use measured counters, not expected values')

    $run = Invoke-Snippet 'counter-mismatch' "& '$exportScript' -SkipAssemble" -Timeout 30
    Assert-Runner ($run.status -eq 'failed') 'Changed live counters did not fail the expectation check.'
    $checks.Add('expected values still detect counter regressions')

    Write-Fixture 'tb/unit/core/tb_perf_counters.v' 'module t; initial begin $dumpfile("results/waveforms/tb_perf_counters.vcd"); $dumpvars(0,t); #1; $finish; end endmodule'
    $run = Invoke-Snippet 'missing-counter' "& '$exportScript' -SkipAssemble -MeasureOnly"
    $failed = Get-Content -LiteralPath (Join-Path $fixture 'results/perf-counter-comparison.json') -Raw | ConvertFrom-Json
    Assert-Runner ($run.status -eq 'failed' -and $failed.status -eq 'fail' -and $failed.Rows.Count -eq 0) 'Missing counters left a stale export.'
    $checks.Add('missing counter line fails without leaving stale output')

    $repoRoot = $fixture
    $longDescription = ('long command description ' * 12)
    $first = Invoke-ChildPowerShell -Description ($longDescription + ' first') -Arguments @('-Command', 'exit 0')
    $second = Invoke-ChildPowerShell -Description ($longDescription + ' second') -Arguments @('-Command', 'exit 0')
    Assert-Runner ($first.status -eq 'passed' -and $second.status -eq 'passed') 'Long child descriptions failed.'
    Assert-Runner ((Split-Path -Leaf $first.log).Length -le 65 -and $first.log -ne $second.log) 'Child log names are unbounded or collide.'
    $checks.Add('bounded child log names distinguish long command descriptions')

    $tokens = $null; $parseErrors = $null
    $seedAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'generated-reference-seed-smoke.ps1'), [ref]$tokens, [ref]$parseErrors)
    $writer = $seedAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-SmokeSummary' }, $true)
    . ([scriptblock]::Create($writer.Extent.Text))
    $SummaryJson = 'results/seed-summary.json'
    $seedRows = @([pscustomobject]@{status='passed'; artifacts_unchanged=$true})
    foreach ($case in @(@{Planned=2; Error=''; Pass=$false}, @{Planned=1; Error='interrupted'; Pass=$false}, @{Planned=1; Error=''; Pass=$true})) {
        Write-SmokeSummary -Rows $seedRows -ArtifactRestored $true -DefaultChecksPassed $true -ExpectedCount $case.Planned -ErrorMessage $case.Error
        $record = Get-Content -LiteralPath (Join-Path $fixture $SummaryJson) -Raw | ConvertFrom-Json
        Assert-Runner (($record.status -eq 'passed') -eq $case.Pass) 'Incomplete or interrupted seed matrix reported PASS.'
    }
    $checks.Add('seed summaries require the complete matrix and no execution error')
    $status = 'passed'
} catch {
    $status = 'failed'
    $errorMessage = $_.Exception.Message
    throw
} finally {
    $retainedFixture = $fixture
    try { $retainedFixture = Complete-TestFixture $root $fixture $status } catch {
        $status = 'failed'; $errorMessage = $_.Exception.Message
        throw
    } finally {
        Write-ResultJson ([ordered]@{ status=$status; passed=$checks.Count; checks=@($checks.ToArray()); error_message=$errorMessage; fixture=$retainedFixture }) $summaryFile
    }
}
Write-Host "PASS: $($checks.Count) runner/reporting self-tests"
