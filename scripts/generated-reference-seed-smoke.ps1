<#
Script: scripts\generated-reference-seed-smoke.ps1
Purpose: Runs selected reference programs with extra seeds in isolated output directories.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\generated-reference-seed-smoke.ps1
Outputs:
  results\generated-reference-seed-smoke-summary.json and logs under results/logs/reference-seeds/. Checked-in fixtures are left untouched.
#>
param(
    [string]$SummaryJson = "results\generated-reference-seed-smoke-summary.json"
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/result-format.ps1"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

New-Item -ItemType Directory -Force -Path "results" | Out-Null

$families = @(
    [pscustomobject]@{
        name = "random_memory_reference"
        script = "random-memory-reference.ps1"
        test = "random_memory_reference"
        default_seed = 2027
        seeds = @(2027, 3027, 4027)
        artifacts = @(
            "fixtures/generated/reference/random_memory_reference.hex",
            "fixtures/generated/reference/random_memory_reference_dmem_init.hex",
            "fixtures/generated/reference/random_memory_reference_expected_regs.hex",
            "fixtures/generated/reference/random_memory_reference_expected_dmem.hex",
            "fixtures/generated/reference/random_memory_reference_expected.json"
        )
    },
    [pscustomobject]@{
        name = "random_control_reference"
        script = "random-control-reference.ps1"
        test = "random_control_reference"
        default_seed = 2028
        seeds = @(2028, 3028, 4028)
        artifacts = @(
            "fixtures/generated/reference/random_control_reference.hex",
            "fixtures/generated/reference/random_control_reference_expected_regs.hex",
            "fixtures/generated/reference/random_control_reference_expected_dmem.hex",
            "fixtures/generated/reference/random_control_reference_expected.json"
        )
    },
    [pscustomobject]@{
        name = "random_hazard_reference"
        script = "random-hazard-reference.ps1"
        test = "random_hazard_reference"
        default_seed = 2029
        seeds = @(2029, 3029, 4029)
        artifacts = @(
            "fixtures/generated/reference/random_hazard_reference.hex",
            "fixtures/generated/reference/random_hazard_reference_dmem_init.hex",
            "fixtures/generated/reference/random_hazard_reference_expected_regs.hex",
            "fixtures/generated/reference/random_hazard_reference_expected_dmem.hex",
            "fixtures/generated/reference/random_hazard_reference_expected.json"
        )
    },
    [pscustomobject]@{
        name = "random_call_reference"
        script = "random-call-reference.ps1"
        test = "random_call_reference"
        default_seed = 2030
        seeds = @(2030, 3030, 4030)
        artifacts = @(
            "fixtures/generated/reference/random_call_reference.hex",
            "fixtures/generated/reference/random_call_reference_dmem_init.hex",
            "fixtures/generated/reference/random_call_reference_expected_regs.hex",
            "fixtures/generated/reference/random_call_reference_expected_dmem.hex",
            "fixtures/generated/reference/random_call_reference_expected.json"
        )
    }
)

function Get-ArtifactHashes {
    param([object[]]$Families)

    $hashes = [ordered]@{}
    foreach ($family in $Families) {
        foreach ($artifact in $family.artifacts) {
            if (-not (Test-Path -LiteralPath $artifact)) {
                throw "missing generated reference artifact before seed smoke: $artifact"
            }
            $hashes[$artifact] = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifact).Hash
        }
    }
    return $hashes
}

function Test-ArtifactHashesMatch {
    param([object]$ExpectedHashes)
    if ($null -eq $ExpectedHashes) { return $false }

    foreach ($artifact in $ExpectedHashes.Keys) {
        if (-not (Test-Path -LiteralPath $artifact)) {
            return $false
        }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifact).Hash
        if ($actual -ne $ExpectedHashes[$artifact]) {
            return $false
        }
    }
    return $true
}

. "$PSScriptRoot/process-runner.ps1"

function Write-SmokeSummary {
    param(
        [object[]]$Rows,
        [bool]$ArtifactRestored,
        [bool]$DefaultChecksPassed,
        [int]$ExpectedCount,
        [string]$ErrorMessage
    )

    foreach ($row in $Rows) {
        $row.artifacts_unchanged = $ArtifactRestored
    }

    $summaryPath = if ([System.IO.Path]::IsPathRooted($SummaryJson)) {
        $SummaryJson
    } else {
        Join-Path $repoRoot $SummaryJson
    }
    $summaryDirectory = Split-Path -Parent $summaryPath
    if ($summaryDirectory -ne "") {
        New-Item -ItemType Directory -Force -Path $summaryDirectory | Out-Null
    }

    $summary = [ordered]@{
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        status = if ($Rows.Count -eq $ExpectedCount -and -not $ErrorMessage -and @($Rows | Where-Object { $_.status -ne "passed" }).Count -eq 0 -and $ArtifactRestored -and $DefaultChecksPassed) { "passed" } else { "failed" }
        planned = $ExpectedCount
        total = $Rows.Count
        passed = @($Rows | Where-Object { $_.status -eq "passed" }).Count
        failed = @($Rows | Where-Object { $_.status -ne "passed" }).Count
        default_artifacts_unchanged = $ArtifactRestored
        default_artifact_checks_passed = $DefaultChecksPassed
        error_message = $ErrorMessage
        tests = $Rows
    }

    Write-ResultJson $summary $summaryPath
    Write-Host "Generated reference seed smoke summary written to $summaryPath"
}

$initialHashes = $null
$rows = @()
$defaultChecksPassed = $false
$artifactRestored = $false
$runError = $null
$expectedCount = ($families | ForEach-Object { $_.seeds.Count } | Measure-Object -Sum).Sum
Write-ResultJson ([ordered]@{status='running'; tests=@()}) $SummaryJson
New-Item -ItemType Directory -Force -Path 'build/reference' | Out-Null
$seedLock = [IO.File]::Open((Join-Path $repoRoot 'build/reference/seed-smoke.lock'), 'OpenOrCreate', 'ReadWrite', 'None')

try {
    $initialHashes = Get-ArtifactHashes $families
    foreach ($family in $families) {
        foreach ($seed in $family.seeds) {
            $directory = "build/reference/$($family.name)/seed_$seed"
            $commandText = "powershell -NoProfile -ExecutionPolicy Bypass -File scripts\$($family.script) -Seed $seed -ArtifactDirectory $directory"
            Write-Host "========================================"
            Write-Host "Running generated reference seed smoke: $($family.name) seed $seed"
            $result = Invoke-ChildPowerShell `
                -Description $commandText `
                -Arguments @("-File", (Join-Path $PSScriptRoot $family.script), "-Seed", [string]$seed, '-ArtifactDirectory', $directory)

            $status = if ($result.exit_code -eq 0) { "passed" } else { "failed" }
            $lastLine = if ($result.output.Count -eq 0) { "" } else { $result.output[-1] }
            $rows += [pscustomobject]@{
                family = $family.name
                seed = $seed
                test_name = $family.test
                status = $status
                artifacts_unchanged = $false
                command = $commandText
                summary = $lastLine
                generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
                exit_code = $result.exit_code
            }

            if ($status -ne "passed") {
                Write-Host "FAIL: $($family.name) seed $seed failed"
                $result.output | ForEach-Object { Write-Host "  $_" }
            }
        }
    }
} catch {
    $runError = $_.Exception.Message
    throw
} finally {
  try {
    Write-Host "========================================"
    Write-Host "Checking that tracked reference artifacts remain unchanged"

    $artifactRestored = Test-ArtifactHashesMatch $initialHashes

    if ($artifactRestored) {
        Write-Host "PASS: tracked reference artifacts were not modified"
    } else {
        Write-Host "FAIL: tracked reference artifacts changed during the seed run"
    }

    $defaultChecksPassed = $true
    foreach ($family in $families) {
        $check = Invoke-ChildPowerShell `
            -Description "check tracked $($family.name)" `
            -Arguments @("-File", (Join-Path $PSScriptRoot $family.script), "-Check", "-SkipSimulation")
        if ($check.exit_code -ne 0) {
            $defaultChecksPassed = $false
            Write-Host "FAIL: default check failed for $($family.name)"
            $check.output | ForEach-Object { Write-Host "  $_" }
        }
    }

    if ($defaultChecksPassed) {
        Write-Host "PASS: tracked default reference artifacts pass freshness checks"
    }

  } catch {
    if (-not $runError) { $runError = $_.Exception.Message }
    throw
  } finally {
    try {
      Write-SmokeSummary -Rows $rows -ArtifactRestored $artifactRestored -DefaultChecksPassed $defaultChecksPassed -ExpectedCount $expectedCount -ErrorMessage $runError
    } finally {
    $seedLock.Dispose()
    }
  }
}

$failedRows = @($rows | Where-Object { $_.status -ne "passed" })
if ($failedRows.Count -ne 0 -or -not $artifactRestored -or -not $defaultChecksPassed) {
    throw "generated reference seed smoke failed"
}

Write-Host "========================================"
Write-Host "PASS: generated reference seed smoke passed ($($rows.Count) seed runs)"
