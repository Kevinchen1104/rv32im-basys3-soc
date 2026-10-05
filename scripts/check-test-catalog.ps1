<#
Script: scripts\check-test-catalog.ps1
Purpose: Validates that docs\test_catalog.json matches the executable regression manifest.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\check-test-catalog.ps1
Outputs:
  results\test-catalog-summary.json and console mismatch reports.
#>
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/result-format.ps1"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. "$PSScriptRoot\verification-source-identity.ps1"

$catalogPath = Join-Path $repoRoot "docs\test_catalog.json"
$runPath = Join-Path $repoRoot "scripts\run.ps1"
$summaryPath = Join-Path $repoRoot "results\test-catalog-summary.json"
$summary = [ordered]@{ status='running'; error_message=$null }
Write-ResultJson $summary $summaryPath
try {

$validCategories = @(
    "smoke",
    "alu",
    "memory",
    "hazard",
    "control_flow",
    "predictor",
    "ras",
    "csr_trap",
    "side_effect_flush",
    "cache",
    "mmio",
    "accelerator",
    "ai_hardware",
    "uart",
    "boot",
    "external_memory",
    "fpga_wrapper",
    "trace_reference",
    "invariant_monitor",
    "random_reference",
    "random_memory_reference",
    "performance_counter",
    "assembler"
)

$validTags = @(
    "alu",
    "memory",
    "load_store",
    "hazard",
    "forwarding",
    "control_flow",
    "branch",
    "jump",
    "predictor",
    "ras",
    "csr_trap",
    "exception",
    "side_effect_flush",
    "cache",
    "icache",
    "dcache",
    "mmio",
    "accelerator",
    "ai_hardware",
    "uart",
    "boot",
    "external_memory",
    "fpga_wrapper",
    "trace_reference",
    "invariant_monitor",
    "random_reference",
    "random_memory_reference",
    "performance_counter",
    "assembler",
    "reset",
    "x0_invariant",
    "smoke"
)

$validEvidenceLevels = @(
    "directed",
    "random_reference",
    "multi_seed_generated_smoke",
    "assertion_monitor",
    "trace_reference",
    "script_check",
    "static_check",
    "smoke"
)

function Fail-Catalog {
    param([string]$Message)
    throw "test catalog check failed: $Message"
}

if (-not (Test-Path -LiteralPath $catalogPath)) {
    Fail-Catalog "missing docs\test_catalog.json"
}

$runText = Get-Content -Raw -Path $runPath
$manifestBlockMatch = [regex]::Match(
    $runText,
    '\$testSources\s*=\s*\[ordered\]@\{(?<body>.*?)^\}',
    [System.Text.RegularExpressions.RegexOptions]::Singleline -bor
        [System.Text.RegularExpressions.RegexOptions]::Multiline
)
if (-not $manifestBlockMatch.Success) {
    Fail-Catalog "could not parse the testSources manifest from scripts\run.ps1"
}

$manifest = [ordered]@{}
$manifestMatches = [regex]::Matches(
    $manifestBlockMatch.Groups["body"].Value,
    '^\s*(?<name>[A-Za-z0-9_]+)\s*=\s*"(?<source>[^"]+)"',
    [System.Text.RegularExpressions.RegexOptions]::Multiline
)
foreach ($match in $manifestMatches) {
    $manifest[$match.Groups["name"].Value] = $match.Groups["source"].Value
}
$runTests = @($manifest.Keys)

. "$PSScriptRoot/test-catalog.ps1"
$catalog = Read-TestCatalog -Path $catalogPath
if ($catalog.schema_version -ne 3) {
    Fail-Catalog "schema_version must be 3"
}

$entries = @($catalog.tests)
if ($entries.Count -eq 0) {
    Fail-Catalog "catalog has no tests"
}

$names = @($entries | ForEach-Object { $_.name })
$duplicateNames = @($names | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
if ($duplicateNames.Count -ne 0) {
    Fail-Catalog "duplicate test names: $($duplicateNames -join ', ')"
}

$catalogByName = @{}
foreach ($entry in $entries) {
    $catalogByName[$entry.name] = $entry
}

$missingFromCatalog = @($runTests | Where-Object { -not $catalogByName.ContainsKey($_) })
if ($missingFromCatalog.Count -ne 0) {
    Fail-Catalog "run.ps1 tests missing from catalog: $($missingFromCatalog -join ', ')"
}

$scriptCheckEntries = @($entries | Where-Object { -not $manifest.Contains($_.name) })

$requiredTextFields = @("name", "source", "category", "contract", "boundary", "evidence_level")
$requiredBoolFields = @("uses_hierarchical_access", "included_in_full_regression")

foreach ($entry in $entries) {
    foreach ($field in $requiredTextFields) {
        if (-not ($entry.PSObject.Properties.Name -contains $field) -or [string]::IsNullOrWhiteSpace($entry.$field)) {
            Fail-Catalog "entry '$($entry.name)' has empty required field '$field'"
        }
    }

    foreach ($field in $requiredBoolFields) {
        if (-not ($entry.PSObject.Properties.Name -contains $field) -or $entry.$field.GetType().Name -ne "Boolean") {
            Fail-Catalog "entry '$($entry.name)' must have boolean field '$field'"
        }
    }

    if ($validCategories -notcontains $entry.category) {
        Fail-Catalog "entry '$($entry.name)' has invalid category '$($entry.category)'"
    }

    if ($validEvidenceLevels -notcontains $entry.evidence_level) {
        Fail-Catalog "entry '$($entry.name)' has invalid evidence_level '$($entry.evidence_level)'"
    }

    if (-not ($entry.PSObject.Properties.Name -contains "tags")) {
        Fail-Catalog "entry '$($entry.name)' is missing tags"
    }

    $entryTags = @($entry.tags)
    if ($entryTags.Count -eq 0) {
        Fail-Catalog "entry '$($entry.name)' must have at least one tag"
    }

    foreach ($tag in $entryTags) {
        if ([string]::IsNullOrWhiteSpace($tag)) {
            Fail-Catalog "entry '$($entry.name)' has an empty tag"
        }

        if ($validTags -notcontains $tag) {
            Fail-Catalog "entry '$($entry.name)' has invalid tag '$tag'"
        }
    }

    if ($manifest.Contains($entry.name)) {
        if ($entry.source -ne $manifest[$entry.name]) {
            Fail-Catalog "entry '$($entry.name)' source '$($entry.source)' does not match run.ps1 '$($manifest[$entry.name])'"
        }
    } else {
        if ($entry.included_in_full_regression) {
            Fail-Catalog "script-level entry '$($entry.name)' must have included_in_full_regression=false"
        }
        if (-not $entry.source.StartsWith("scripts/") -and -not $entry.source.StartsWith("scripts\")) {
            Fail-Catalog "script-level entry '$($entry.name)' must use a scripts/ source path"
        }
        if ($entry.evidence_level -ne "multi_seed_generated_smoke" -and $entry.evidence_level -ne "script_check") {
            Fail-Catalog "script-level entry '$($entry.name)' must use a script evidence level"
        }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $entry.source))) {
        Fail-Catalog "entry '$($entry.name)' source file does not exist: $($entry.source)"
    }

    if ($manifest.Contains($entry.name) -and -not $entry.included_in_full_regression) {
        Fail-Catalog "entry '$($entry.name)' is a run.ps1 test and must be included_in_full_regression=true"
    }
}

function Assert-TagContains {
    param(
        [string]$Tag,
        [string[]]$RequiredTests
    )

    $tagEntries = @($entries | Where-Object { @($_.tags) -contains $Tag } | ForEach-Object { $_.name })
    $missing = @($RequiredTests | Where-Object { $tagEntries -notcontains $_ })
    if ($missing.Count -ne 0) {
        Fail-Catalog "tag '$Tag' missing required tests: $($missing -join ', ')"
    }
}

Assert-TagContains "side_effect_flush" @(
    "assert_store_flush",
    "assert_mmio_flush",
    "assert_jump_side_effect_flush",
    "assert_jalr_side_effect_flush",
    "assert_trap_side_effect_flush",
    "assert_mret_side_effect_flush",
    "trace_trap_reference",
    "pipeline_invariants"
)

Assert-TagContains "csr_trap" @(
    "assert_trap",
    "assert_trap_side_effect_flush",
    "assert_illegal_csr",
    "assert_mret_redirect",
    "assert_mret_side_effect_flush",
    "program_csr_trap",
    "program_mret_trap",
    "trace_trap_reference",
    "pipeline_invariants"
)

Assert-TagContains "control_flow" @(
    "assert_flush",
    "assert_jump_flush",
    "assert_jalr_flush",
    "assert_jump_side_effect_flush",
    "assert_jalr_side_effect_flush",
    "branch",
    "program_call",
    "random_control_reference",
    "random_hazard_reference",
    "random_call_reference",
    "trace_trap_reference",
    "pipeline_invariants"
)

Assert-TagContains "predictor" @(
    "branch_prediction",
    "branch_predictor_warm_recovery",
    "branch_predictor_recovery"
)

Assert-TagContains "trace_reference" @(
    "trace",
    "trace_reference",
    "trace_trap_reference",
    "pipeline_invariants"
)

Assert-TagContains "invariant_monitor" @(
    "pipeline_invariants"
)

Assert-TagContains "random_reference" @(
    "random_reference",
    "random_memory_reference",
    "random_control_reference",
    "random_hazard_reference",
    "random_call_reference",
    "generated_reference_seed_smoke"
)

Assert-TagContains "memory" @(
    "memory",
    "program_memory",
    "random_memory_reference",
    "random_hazard_reference",
    "random_call_reference"
)

Assert-TagContains "hazard" @(
    "load_use_decode",
    "random_hazard_reference",
    "random_call_reference",
    "pipeline_invariants"
)

Assert-TagContains "ras" @(
    "jump_ras",
    "ras_flush",
    "ras_immediate_return",
    "random_call_reference"
)

New-Item -ItemType Directory -Force -Path "results" | Out-Null

$categoryCounts = [ordered]@{}
foreach ($group in ($entries | Group-Object category | Sort-Object Name)) {
    $categoryCounts[$group.Name] = $group.Count
}

$evidenceCounts = [ordered]@{}
foreach ($group in ($entries | Group-Object evidence_level | Sort-Object Name)) {
    $evidenceCounts[$group.Name] = $group.Count
}

$allTags = @($entries | ForEach-Object { @($_.tags) })
$tagCounts = [ordered]@{}
foreach ($group in ($allTags | Group-Object | Sort-Object Name)) {
    $tagCounts[$group.Name] = $group.Count
}

$summary = [ordered]@{
    status = 'pass'
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    total_catalog_entries = $entries.Count
    run_ps1_tests = $runTests.Count
    counts_by_category = $categoryCounts
    counts_by_tag = $tagCounts
    counts_by_evidence_level = $evidenceCounts
    hierarchical_tests = @($entries | Where-Object { $_.uses_hierarchical_access }).Count
}
Add-VerificationIdentityFields -Summary $summary | Out-Null

Write-ResultJson $summary $summaryPath
Write-Host "PASS: test catalog matches run.ps1 manifest and required coverage buckets"
Write-Host "Test catalog summary written to results\test-catalog-summary.json"
} catch {
    $summary.status = 'fail'
    $summary['error_message'] = $_.Exception.Message
    throw
} finally {
    Write-ResultJson $summary $summaryPath
}
