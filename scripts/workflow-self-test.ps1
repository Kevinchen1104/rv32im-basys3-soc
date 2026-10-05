<#
Script: scripts/workflow-self-test.ps1
Purpose: Checks catalog defaults, report data, and Quick/Full result separation.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts/workflow-self-test.ps1
Outputs:
  results/workflow-self-test-summary.json and isolated fixtures in build/tests/workflow/.
Scope:
  Workflow tests with synthetic child scripts; CPU behavior is checked by regression tests.
#>
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. "$PSScriptRoot/test-catalog.ps1"
. "$PSScriptRoot/check-report.ps1"
. "$PSScriptRoot/process-runner.ps1"
. "$PSScriptRoot/documentation-review.ps1"
. "$PSScriptRoot/artifact-paths.ps1"
. "$PSScriptRoot/script-common.ps1"
. "$PSScriptRoot/reference-common.ps1"
$fixture = Join-Path $repoRoot ('build/tests/workflow/' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path "$fixture/scripts", "$fixture/results", "$repoRoot/results" | Out-Null
$checks = New-Object 'System.Collections.Generic.List[string]'
function Assert-Workflow([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $checks.Add($Message)
}
function Write-Fixture([string]$Path, [string]$Text) {
    Set-Content -LiteralPath (Join-Path $fixture $Path) -Value $Text -Encoding UTF8
}
$status = 'running'
try {
    Assert-Workflow ((To-UInt32 -1) -eq [uint32]::MaxValue -and (To-SInt32 ([uint32]::MaxValue)) -eq -1) 'Shared integer helpers preserve RV32 wraparound'
    Assert-Workflow ((Encode-IType -1 0 0 1 0x13) -eq 0xfff00093L -and (Encode-RType 0x20 2 1 0 3) -eq 0x402081b3L) 'Shared encoders match hand-calculated ADDI and SUB words'
    Assert-Workflow ((Normalize-TextForArtifactCompare "a`r`nb`r`n") -eq "a`nb") 'Reference text comparison normalizes line endings'
    Assert-Workflow ((Resolve-RepoPath 'rtl') -eq (Join-Path $repoRoot 'rtl')) 'Shared path helper resolves from the repository'
    Assert-Workflow ($null -eq (Read-JsonIfPresent "$fixture/missing.json")) 'Optional JSON reader returns null for missing metadata'
    $rejected = $false
    try { Read-JsonFile "$fixture/missing.json" } catch { $rejected = $true }
    Assert-Workflow $rejected 'Required JSON reader rejects missing metadata'
    $rejected = $false
    try { Normalize-Hash 'not-a-hash' } catch { $rejected = $true }
    Assert-Workflow $rejected 'Hash validator rejects malformed digests'
    Assert-Workflow (Test-IntroductoryComment '// Computes a dot product.' '.v') 'Plain-language comments need no fixed header fields'
    Assert-Workflow (-not (Test-IntroductoryComment 'module m; endmodule' '.v')) 'Missing introductory comment is an advisory finding'
    Assert-Workflow (Test-IntroductoryComment '# Benchmark comparison' '.ps1') 'Comments do not require disclaimer phrases'
    $checkSource = Get-Content -LiteralPath "$PSScriptRoot/check.ps1" -Raw
    Assert-Workflow ($checkSource -notmatch "Step 'documentation-coverage-audit'") 'Functional workflow excludes editorial coverage checks'
    $coverageRoot = Join-Path $fixture 'coverage'
    New-Item -ItemType Directory -Force -Path "$coverageRoot/rtl" | Out-Null
    Write-Fixture 'coverage/rtl/bare.v' 'module bare; endmodule'
    $coverage = Get-DocumentationCoverage -Root $coverageRoot -Kind 'rtl'
    Assert-Workflow ($coverage.files_checked -eq 1 -and $coverage.findings.Count -eq 1) 'Undocumented source is reported without failing the scan'
    $missingInputRejected = $false
    try { Get-DocumentationCoverage -Root $coverageRoot -Kind 'firmware' | Out-Null } catch { $missingInputRejected = $true }
    Assert-Workflow $missingInputRejected 'Missing documentation-scan input remains an execution error'
    $catalog = Read-TestCatalog "$repoRoot/docs/test_catalog.json"
    Assert-Workflow (@($catalog.tests | Where-Object { $null -eq $_.included_in_full_regression }).Count -eq 0) 'Catalog entries inherit complete metadata'
    Write-Fixture 'catalog.json' '{"schema_version":3,"defaults":{"evidence_level":"directed","uses_hierarchical_access":true,"included_in_full_regression":true},"tests":[{"name":"a"},{"name":"b","included_in_full_regression":false,"uses_hierarchical_access":false}]}'
    $sample = Read-TestCatalog "$fixture/catalog.json"
    Assert-Workflow ($sample.tests[0].included_in_full_regression -and -not $sample.tests[1].included_in_full_regression -and -not $sample.tests[1].uses_hierarchical_access) 'Explicit false overrides catalog defaults'
    Write-Fixture 'catalog.json' '{"schema_version":3,"defaults":{"unexpected":true},"tests":[]}'
    $rejected = $false
    try { Read-TestCatalog "$fixture/catalog.json" | Out-Null } catch { $rejected = $true }
    Assert-Workflow $rejected 'Unknown catalog defaults are rejected'

    foreach ($name in @('check.ps1', 'check-report.ps1', 'process-runner.ps1', 'result-format.ps1')) {
        Copy-Item -LiteralPath "$PSScriptRoot/$name" -Destination "$fixture/scripts/$name"
    }
    $identityHelper = Get-Content -LiteralPath "$PSScriptRoot/verification-source-identity.ps1" -Raw
    Write-Fixture 'input.txt' 'original input'
    Write-Fixture 'scripts/verification-source-identity.ps1' ($identityHelper + @'

function Get-VerificationSourceIdentity {
    return @{ source_commit='fixture'; verification_input_fingerprint=(Get-FileHash "$PSScriptRoot/../input.txt").Hash; verification_input_count=1; verification_working_tree_dirty=$false }
}
'@)
    foreach ($name in @('assemble', 'static-rtl-check', 'check-test-catalog')) {
        Write-Fixture "scripts/$name.ps1" 'Write-Host "PASS: synthetic check"'
    }
    Write-Fixture 'scripts/run.ps1' @'
param($Test, [switch]$SkipAssemble, $SummaryJson)
if ($Test -ne 'quick' -or -not $SkipAssemble) { throw 'Unexpected quick arguments' }
'{"status":"passed","passed":2,"requested_total":2,"tests":[{"name":"a","status":"passed","duration_ms":10},{"name":"b","status":"passed","duration_ms":20}]}' | Set-Content -LiteralPath $SummaryJson
'@
    Write-Fixture 'results/RESULTS.md' 'Full summary sentinel'
    Write-Fixture 'results/check-summary.json' '{"status":"full-sentinel"}'
    Write-Fixture 'results/regression-summary.json' '{"status":"full-sentinel"}'
    $fullHashes = @{}
    foreach ($name in @('RESULTS.md', 'check-summary.json', 'regression-summary.json')) {
        $fullHashes[$name] = (Get-FileHash "$fixture/results/$name").Hash
    }
    $result = Invoke-LoggedProcess -FilePath 'powershell' -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$fixture/scripts/check.ps1", '-Mode', 'Quick') -LogPath 'success.log' -WorkingDirectory $fixture -TimeoutSeconds 90 -Quiet
    Assert-Workflow ($result.status -eq 'passed') 'Quick child-script workflow completes'
    $summary = Get-Content "$fixture/results/quick-check-summary.json" -Raw | ConvertFrom-Json
    Assert-Workflow ($summary.status -eq 'pass' -and $summary.steps.Count -eq 4 -and $summary.regression) 'Quick summary records all four steps'
    $report = Get-Content "$fixture/results/quick-RESULTS.md" -Raw
    Assert-Workflow ($report.Contains('2 / 2 tests passed') -and @(Import-Csv "$fixture/results/quick-regression.csv").Count -eq 2) 'Markdown and CSV use observed regression data'
    foreach ($name in $fullHashes.Keys) {
        Assert-Workflow ((Get-FileHash "$fixture/results/$name").Hash -eq $fullHashes[$name]) "Quick preserves Full $name"
    }
    $originalIdentity = $summary.verification_input_fingerprint
    Write-Fixture 'scripts/assemble.ps1' "Set-Content -LiteralPath input.txt -Value 'changed during run'"
    $result = Invoke-LoggedProcess -FilePath 'powershell' -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$fixture/scripts/check.ps1", '-Mode', 'Quick') -LogPath 'identity-drift.log' -WorkingDirectory $fixture -TimeoutSeconds 90 -Quiet
    $summary = Get-Content "$fixture/results/quick-check-summary.json" -Raw | ConvertFrom-Json
    Assert-Workflow ($result.status -eq 'failed' -and $summary.status -eq 'fail' -and $summary.error_message -like '*inputs changed*') 'Source changes during a workflow invalidate its result'
    Assert-Workflow ($summary.verification_input_fingerprint -eq $originalIdentity) 'A mixed-source run retains its starting identity rather than claiming the new source'
    Write-Fixture 'scripts/assemble.ps1' "throw 'Intentional workflow failure'"
    $result = Invoke-LoggedProcess -FilePath 'powershell' -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$fixture/scripts/check.ps1", '-Mode', 'Quick') -LogPath 'failure.log' -WorkingDirectory $fixture -TimeoutSeconds 90 -Quiet
    $summary = Get-Content "$fixture/results/quick-check-summary.json" -Raw | ConvertFrom-Json
    Assert-Workflow ($result.status -eq 'failed' -and $summary.status -eq 'fail' -and $summary.failed_step -eq 'assemble' -and $summary.steps.Count -eq 1) 'Failure stops the workflow and identifies its step'
    $report = Get-Content "$fixture/results/quick-RESULTS.md" -Raw
    Assert-Workflow (-not $report.Contains('2 / 2 tests passed') -and -not (Test-Path "$fixture/results/quick-regression.csv")) 'Failure report does not reuse stale successful regression data'
    Write-Fixture 'scripts/verification-source-identity.ps1' "function Add-VerificationIdentityFields { throw 'Intentional identity failure' }"
    $result = Invoke-LoggedProcess -FilePath 'powershell' -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$fixture/scripts/check.ps1", '-Mode', 'Quick') -LogPath 'identity-failure.log' -WorkingDirectory $fixture -TimeoutSeconds 90 -Quiet
    $summary = Get-Content "$fixture/results/quick-check-summary.json" -Raw | ConvertFrom-Json
    Assert-Workflow ($result.status -eq 'failed' -and $summary.status -eq 'fail' -and $summary.failed_step -eq 'source identity' -and $summary.steps.Count -eq 0) 'Identity setup failure is recorded before any check starts'
    $status = 'passed'
} catch {
    $status = 'failed'
    throw
} finally {
    $retainedFixture = $fixture
    try { $retainedFixture = Complete-TestFixture $repoRoot $fixture $status } catch {
        $status = 'failed'
        throw
    } finally {
        Write-ResultJson ([ordered]@{ status = $status; total = $checks.Count; checks = @($checks.ToArray()); fixture = $retainedFixture }) "$repoRoot/results/workflow-self-test-summary.json"
    }
}
Write-Host "PASS: $($checks.Count) workflow checks"
