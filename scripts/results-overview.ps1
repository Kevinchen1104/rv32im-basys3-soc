# Rebuild the human-facing result index from saved evidence; does not rerun tools.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $root
. "$PSScriptRoot/verification-source-identity.ps1"
. "$PSScriptRoot/result-format.ps1"
$identity = Get-VerificationSourceIdentity
$documentationIdentity = Get-DocumentationInputIdentity
$readErrors = [System.Collections.Generic.List[object]]::new()
New-Item -ItemType Directory -Force -Path 'results' | Out-Null
# Invalidate the previous index before reading records. An unexpected failure
# must not leave the earlier index looking like a completed refresh.
Write-ResultJson ([ordered]@{ status='running'; source_commit=$identity.source_commit }) 'results/overview.json'
Set-Content -LiteralPath 'results/RESULTS.md' -Encoding UTF8 -Value '# Result index refresh in progress'

function Get-ResultFreshness($Result) {
    if ($Result.documentation_input_fingerprint) {
        if ($Result.documentation_input_fingerprint -eq $documentationIdentity.documentation_input_fingerprint) { return 'current documentation' }
        return 'stale documentation'
    }
    if ($Result.source_inputs) {
        foreach ($input in $Result.source_inputs) {
            if (-not (Test-Path -LiteralPath $input.path) -or
                (Get-FileHash -LiteralPath $input.path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $input.sha256) { return 'historical' }
        }
        return 'matching build inputs'
    }
    if ($Result.verification_input_fingerprint) {
        if ($Result.verification_input_fingerprint -eq $identity.verification_input_fingerprint) { return 'current' }
        return 'stale'
    }
    if ($Result.source.inputs) {
        foreach ($input in $Result.source.inputs.PSObject.Properties) {
            if (-not (Test-Path -LiteralPath $input.Name) -or
                (Get-NormalizedTextSha256 $input.Name) -ne $input.Value) { return 'stale' }
        }
        return 'current'
    }
    if ($Result.inputs) {
        foreach ($input in $Result.inputs.PSObject.Properties) {
            if (-not (Test-Path -LiteralPath $input.Name) -or
                (Get-FileHash -LiteralPath $input.Name -Algorithm SHA256).Hash.ToLowerInvariant() -ne $input.Value) { return 'stale' }
        }
        return 'matching build inputs'
    }
    if ($Result.source_hashes) {
        foreach ($input in $Result.source_hashes.PSObject.Properties) {
            # Early viewer captures used script basenames; retain their identity semantics.
            $path = if ($input.Name -notmatch '[/\\]') { "scripts/$($input.Name)" } else { $input.Name }
            if (-not (Test-Path -LiteralPath $path) -or
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $input.Value) { return 'stale' }
        }
        return 'matching build inputs'
    }
    return 'identity unavailable'
}
function Get-ArtifactIntegrity($Result, [string]$RecordPath) {
    $checked = 0
    foreach ($field in @('files','artifacts','capture_hashes')) {
        foreach ($artifact in $Result.$field.PSObject.Properties) {
            $path = if ($field -eq 'capture_hashes') { $artifact.Name } else { Join-Path (Split-Path $RecordPath) $artifact.Name }
            if (-not (Test-Path -LiteralPath $path) -or
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $artifact.Value) { return 'missing or changed' }
            $checked++
        }
    }
    if ($checked) { return 'hashes match' }
    return 'not recorded'
}
function Read-Result($Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $text = Get-Content -LiteralPath $Path -Raw
        if (-not $text.TrimStart().StartsWith('{')) { throw 'Expected a JSON object.' }
        $record = $text | ConvertFrom-Json
        return $record
    } catch {
        $readErrors.Add([pscustomobject]@{ path=$Path; error=$_.Exception.Message })
        return [pscustomobject]@{ status='invalid record' }
    }
}
$groups = @(
    @('Full portable workflow','check-summary.json'),
    @('Quick workflow','quick-check-summary.json'),
    @('RTL simulations','regression-summary.json'),
    @('GCC / Unicorn','compiled-programs/summary.json'),
    @('Interactive FIR application','signal-console/summary.json'),
    @('Python tools and viewer','python-tests/summary.json'),
    @('Physical viewer validation','signal-console/viewer-validation.json'),
    @('MATVEC end-to-end benchmark','matvec-benchmark/summary.json'),
    @('CPU / accelerator study: internal RAM','architecture/complete/summary.json'),
    @('CPU / accelerator study: synchronous BRAM','architecture/complete-external/summary.json'),
    @('I-cache architecture study','architecture/icache-complete-external/summary.json'),
    @('D-cache architecture study','architecture/dcache-complete-external/summary.json'),
    @('D-cache extra latency 4','architecture/dcache-latency4-complete-external/summary.json'),
    @('D-cache extra latency 12','architecture/dcache-latency12-complete-external/summary.json'),
    @('Physical FIR: 1 KiB I-cache, no victims','architecture/dcache-board/baseline-fir.json'),
    @('Physical FIR: 1 KiB I-cache, 4 victims','architecture/dcache-board/victim4-fir.json'),
    @('Physical FIR: candidate reload','architecture/dcache-board/victim4-reload-fir.json'),
    @('Physical FIR: compact victim implementation','signal-console/board-burst/compact.json'),
    @('Physical FIR: compact implementation reload','signal-console/board-burst/compact-reload.json'),
    @('Selected architectural tests','arch-test-results.json'),
    @('Official Sail signature cross-check','arch-test/sail/summary.json'),
    @('Verilator lint','verilator-lint-summary.json'),
    @('Yosys structure','synth-smoke-summary.json'),
    @('Core formal properties','formal-smoke-summary.json'),
    @('MATVEC formal properties','formal-matvec-smoke-summary.json'),
    @('Performance counters','perf-counter-comparison.json')
)
foreach ($file in Get-ChildItem 'results/signal-console/board-burst' -Filter 'capacity-*.json' -File -ErrorAction SilentlyContinue) {
    if ($file.BaseName -notlike '*-programming') {
        $groups += ,@("Physical FIR: $($file.BaseName)", "signal-console/board-burst/$($file.Name)")
    }
}
$rows = foreach ($group in $groups) {
    $result = Read-Result "results/$($group[1])"
    $count = '-'
    if ($null -ne $result) {
        if ($result.requested_total) { $count = "$($result.passed)/$($result.requested_total) tests" }
        elseif ($result.planned_steps) { $count = "$(@($result.steps | Where-Object status -eq 'passed').Count)/$($result.planned_steps) stages" }
        elseif ($result.cases) {
            $planned = if ($result.planned_cases) { $result.planned_cases } else { @($result.cases).Count }
            $unit = if ($result.case_unit) { $result.case_unit } else { 'programs' }
            $count = "$(@($result.cases | Where-Object status -eq 'passed').Count)/$planned $unit"
            if ($result.samples_checked) { $count += "; $($result.samples_checked) outputs" }
        }
        elseif ($null -ne $result.test_samples_checked) {
            $outputs = $result.test_samples_checked + $result.stress_samples_checked + $result.client_samples_checked
            $count = "$outputs outputs; $($result.stress_batches_checked) stress batches"
        }
        elseif ($result.tests_run) { $count = "$($result.tests_passed)/$($result.tests_run) tests; $(@($result.skipped).Count) skipped" }
        elseif ($result.selected_tests) { $count = "$($result.totals.passed_local_reference + $result.totals.passed_official_reference)/$($result.selected_tests) signatures" }
        elseif ($result.checked_tops) { $count = "$(@($result.checked_tops).Count) tops" }
        elseif ($result.harnesses) { $count = "$(@($result.harnesses).Count) harnesses" }
        elseif ($result.Rows) { $count = "$(@($result.Rows).Count) scenarios" }
        elseif ($result.sessions) { $count = "$(@($result.sessions).Count) UART sessions" }
    }
    [pscustomobject]@{
        check=$group[0]; status=if ($result.status) { $result.status } elseif ($result) { 'unclassified' } else { 'not run' }
        detail=$count; identity=if ($result) { Get-ResultFreshness $result } else { '-' }
        source_commit=if ($result.source_commit) { $result.source_commit } else { $result.source.commit }
        path=$group[1]
        artifacts=if ($result) { Get-ArtifactIntegrity $result "results/$($group[1])" } else { '-' }
    }
}
$lines = @('# CPU project results','',
    "Index generated (UTC): $((Get-Date).ToUniversalTime().ToString('o'))",'',
    "Working revision: ``$($identity.source_commit.Substring(0,7))``. Verification inputs: ``$($identity.verification_input_fingerprint.Substring(0,12))``.",'',
    '## Verification','',
    '| Check | Recorded result | Coverage | Source identity | Linked files | Details |',
    '| --- | --- | --- | --- | --- | --- |')
foreach ($row in ($rows | Where-Object identity -notin @('stale','historical'))) {
    $lines += "| $($row.check) | $($row.status) | $($row.detail) | $($row.identity) | $($row.artifacts) | [record]($($row.path)) |"
}
$olderVerification = @($rows | Where-Object identity -in @('stale','historical'))
if ($olderVerification.Count) {
    $lines += @('', '<details>', "<summary>Earlier verification records ($($olderVerification.Count) records)</summary>", '',
        '| Check | Recorded result | Coverage | Source identity | Linked files | Details |',
        '| --- | --- | --- | --- | --- | --- |')
    foreach ($row in $olderVerification) {
        $lines += "| $($row.check) | $($row.status) | $($row.detail) | $($row.identity) | $($row.artifacts) | [record]($($row.path)) |"
    }
    $lines += @('', '</details>')
}
$lines += @('', 'Current means the recorded verification inputs still match. Stale/historical rows describe earlier inputs; they are not current passes.', '',
    'Linked-file hashes are a separate check. `missing or changed` invalidates the saved evidence even when its source identity still matches. `captured` is a data snapshot, not a correctness test.', '',
    '[Full stages](full-RESULTS.md) | [Quick stages](quick-RESULTS.md) | [Simulation CSV](regression.csv) | [Compiled programs](compiled-programs/RESULTS.md) | [MATVEC benchmark](matvec-benchmark/RESULTS.md)')
$lines += @('', '[CPU / accelerator analysis](../docs/architecture-evaluation.md) | [I-cache analysis](../docs/icache-study.md) | [D-cache analysis](../docs/dcache-study.md)', '',
    'The study rows count program executions, not distinct tests. Internal RAM and synchronous BRAM are separate experiments; their cycle counts must not be pooled.')
$catalog = Read-Result 'results/regression-evidence-summary.json'
if ($catalog -and (Get-ResultFreshness $catalog) -eq 'current') {
    $lines += @('', '### Simulation coverage', '', '| Category | Tests |', '| --- | ---: |')
    foreach ($p in $catalog.counts_by_category.PSObject.Properties) { $lines += "| $($p.Name) | $($p.Value) |" }
}
$timingRows = @()
$timingFiles = @()
# Prefer the normal build output as the link when an archived copy is identical.
if (Test-Path 'results/vivado-basys3-build-summary.json') { $timingFiles += Get-Item 'results/vivado-basys3-build-summary.json' }
$timingFiles += @(Get-ChildItem 'results/timing' -Filter '*.json' -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName)
$timingFiles += @(Get-ChildItem 'results/architecture' -Filter '*-implementation.json' -File -ErrorAction SilentlyContinue | Sort-Object FullName)
$timingByHash = @{}
foreach ($file in $timingFiles) {
    $r = Read-Result $file.FullName
    if (-not $r.reports.post_route_timing.present) { continue }
    $path = $file.FullName.Substring((Join-Path $root 'results').Length+1).Replace('\','/')
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    if ($timingByHash.ContainsKey($hash)) {
        $timingByHash[$hash].aliases += $path
        continue
    }
    $profile = if ($null -ne $r.icache_bytes) { "$($r.architecture_profile), I-cache $($r.icache_bytes) B / lookup $($r.icache_parallel_lookup)" } elseif ($r.architecture_profile) { $r.architecture_profile } else { $r.top }
    if ($null -ne $r.dcache_bytes) { $profile += ", D-cache $($r.dcache_bytes) B" }
    if ($null -ne $r.dcache_victim_lines) { $profile += ", D-cache victims $($r.dcache_victim_lines)" }
    $row = [pscustomobject]@{
        profile=$profile
        period_ns=if ($r.timing_period_ns) { $r.timing_period_ns } elseif (@($r.reports.post_route_clocks | Where-Object name -eq 'sys_clk_pin').Count -eq 1) { ($r.reports.post_route_clocks | Where-Object name -eq 'sys_clk_pin').period_ns } else { '-' }; timing=$r.timing_status; wns_ns=$r.reports.post_route_timing.wns_ns
        whs_ns=$r.reports.post_route_timing.whs_ns; identity=(Get-ResultFreshness $r)
        source_commit=$r.source_commit; date=$r.generated_at_utc
        path=$path; aliases=@()
    }
    $timingRows += $row
    $timingByHash[$hash] = $row
}
$lines += @('', '## Current FPGA implementation', '', '| Profile | Target (ns) | Timing | WNS (ns) | WHS (ns) | Input match | Revision | Evidence |', '| --- | ---: | --- | ---: | ---: | --- | --- | --- |')
foreach ($row in ($timingRows | Where-Object identity -eq 'matching build inputs' | Sort-Object profile,period_ns,date)) {
    $lines += "| $($row.profile) | $($row.period_ns) | $($row.timing) | $($row.wns_ns) | $($row.whs_ns) | $($row.identity) | $($row.source_commit.Substring(0,7)) | [record]($($row.path)) |"
}
$older = @($timingRows | Where-Object identity -ne 'matching build inputs')
$lines += @('', '<details>', "<summary>Earlier implementation experiments ($($older.Count) records)</summary>", '',
    '| Profile | Target (ns) | Timing | WNS (ns) | WHS (ns) | Revision | Evidence |', '| --- | ---: | --- | ---: | ---: | --- | --- | --- |')
foreach ($row in ($older | Sort-Object date -Descending)) {
    $lines += "| $($row.profile) | $($row.period_ns) | $($row.timing) | $($row.wns_ns) | $($row.whs_ns) | $($row.source_commit.Substring(0,7)) | [record]($($row.path)) |"
}
$lines += @('', '</details>', '', 'Byte-identical record copies share one row; their paths are retained in `overview.json` as `aliases`. Separate builds remain separate records.', '',
    '[Current timing analysis](../docs/timing_baseline.md) | [Optimization history](../docs/timing_history.md)')
$lines += @('', 'These rows report routed implementation timing. Recorded physical runs remain in [board evidence](../docs/fpga/board_evidence/).', '',
    '## Files', '',
    '- `runs/`: per-input simulation summaries, logs, and captured waveforms. Repeating the same context replaces only that context.',
    '- `logs/`: workflow and optional-tool diagnostics.',
    '- `compiled-programs/`, `arch-test/`: program traces, signatures, and comparisons.',
    '- `architecture/`: same-binary CPU/cache experiments, counters and stall breakdowns.',
    '- `timing/`: retained implementation experiments, including failed candidates.',
    '- `../build/`: rebuildable tool work directories.', '',
    'Refresh this index with `powershell -ExecutionPolicy Bypass -File scripts/results-overview.ps1`.')
$otherRows = @()
$mainPaths = @($groups | ForEach-Object { $_[1] }) + @('overview.json', 'vivado-basys3-build-summary.json')
foreach ($file in Get-ChildItem 'results' -File -Filter '*.json' | Sort-Object Name) {
    if ($mainPaths -contains $file.Name) { continue }
    $record = Read-Result $file.FullName
    $otherRows += [pscustomobject]@{
        path = $file.Name
        status = if ($record.status) { $record.status } else { 'unclassified' }
        identity = Get-ResultFreshness $record
        recorded_at = if ($record.generated_at_utc) { $record.generated_at_utc } elseif ($record.finished_at_utc) { $record.finished_at_utc } else { '-' }
    }
}
$captures = @(Get-ChildItem 'results/signal-console' -File -Filter '*.json' -ErrorAction SilentlyContinue)
foreach ($file in $captures) {
    $record = Read-Result $file.FullName
    if ($record.status -ne 'captured' -and $file.Name -ne 'start-programming.json') { continue }
    $otherRows += [pscustomobject]@{
        path = "signal-console/$($file.Name)"; status = if ($record.status -eq 'captured') { "captured ($($record.saved_samples) samples)" } else { $record.status }
        identity = Get-ResultFreshness $record
        recorded_at = if ($record.captured_at_utc) { $record.captured_at_utc } else { $record.finished_at_utc }
        artifacts = Get-ArtifactIntegrity $record $file.FullName
    }
}
$lines += @('', '## Supporting records', '',
    'Utility, demo, documentation, and package records are listed separately from the verification gates above. `identity unavailable` means freshness cannot be established from that record alone.', '',
    '<details>', '<summary>Saved supporting summaries</summary>', '',
    '| Record | Recorded status | Source identity | Linked files | Recorded time (UTC) |',
    '| --- | --- | --- | --- | --- |')
foreach ($row in $otherRows) { $lines += "| [$($row.path)]($($row.path)) | $($row.status) | $($row.identity) | $($row.artifacts) | $($row.recorded_at) |" }
$lines += @('', '</details>')
if ($readErrors.Count) {
    $lines += @('', '## Unreadable records', '', 'These records were not accepted as evidence:','')
    foreach ($errorRecord in $readErrors) { $lines += "- ``$($errorRecord.path)``: invalid or unreadable JSON; see `overview.json` for the diagnostic." }
}
$lines | Set-Content -LiteralPath 'results/RESULTS.md' -Encoding UTF8
Write-ResultJson ([ordered]@{ status=if ($readErrors.Count) {'incomplete'} else {'complete'}; generated_at_utc=(Get-Date).ToUniversalTime().ToString('o'); source_commit=$identity.source_commit; verification=$rows; timing=$timingRows; supporting=$otherRows; errors=@($readErrors.ToArray()) }) 'results/overview.json'
Write-Host 'Result index: results/RESULTS.md'
