<#
Script: scripts\generated-reference-seed-smoke.ps1
Purpose: Regenerates selected reference programs with extra seeds and verifies fixture restoration.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\generated-reference-seed-smoke.ps1
Outputs:
  wave\generated-reference-seed-smoke-summary.json and temporary generated fixtures under wave\.
Scope:
  Determinism smoke evidence only; not exhaustive random verification.
Audience:
  Internal helper used by scripts\check.ps1.
#>
param(
    [string]$SummaryJson = "wave\generated-reference-seed-smoke-summary.json"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

New-Item -ItemType Directory -Force -Path "wave" | Out-Null

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

function Invoke-ChildPowerShell {
    param(
        [string]$Description,
        [string[]]$Arguments
    )

    $output = & powershell -NoProfile -ExecutionPolicy Bypass @Arguments 2>&1
    return [pscustomobject]@{
        description = $Description
        exit_code = $LASTEXITCODE
        output = @($output | ForEach-Object { $_.ToString() })
    }
}

function Write-SmokeSummary {
    param(
        [object[]]$Rows,
        [bool]$ArtifactRestored,
        [bool]$DefaultChecksPassed
    )

    foreach ($row in $Rows) {
        $row.artifact_restored = $ArtifactRestored
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
        status = if (@($Rows | Where-Object { $_.status -ne "passed" }).Count -eq 0 -and $ArtifactRestored -and $DefaultChecksPassed) { "passed" } else { "failed" }
        total = $Rows.Count
        passed = @($Rows | Where-Object { $_.status -eq "passed" }).Count
        failed = @($Rows | Where-Object { $_.status -ne "passed" }).Count
        default_artifacts_restored = $ArtifactRestored
        default_artifact_checks_passed = $DefaultChecksPassed
        tests = $Rows
    }

    $summary | ConvertTo-Json -Depth 6 | Set-Content -Path $summaryPath -Encoding Ascii
    Write-Host "Generated reference seed smoke summary written to $summaryPath"
}

$initialHashes = Get-ArtifactHashes $families
$rows = @()
$defaultChecksPassed = $false
$artifactRestored = $false

try {
    foreach ($family in $families) {
        foreach ($seed in $family.seeds) {
            $commandText = "powershell -NoProfile -ExecutionPolicy Bypass -File scripts\$($family.script) -Seed $seed"
            Write-Host "========================================"
            Write-Host "Running generated reference seed smoke: $($family.name) seed $seed"
            $result = Invoke-ChildPowerShell `
                -Description $commandText `
                -Arguments @("-File", (Join-Path $PSScriptRoot $family.script), "-Seed", [string]$seed)

            $status = if ($result.exit_code -eq 0) { "passed" } else { "failed" }
            $lastLine = if ($result.output.Count -eq 0) { "" } else { $result.output[-1] }
            $rows += [pscustomobject]@{
                family = $family.name
                seed = $seed
                test_name = $family.test
                status = $status
                artifact_restored = $false
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
} finally {
    Write-Host "========================================"
    Write-Host "Restoring checked-in default generated reference artifacts"
    foreach ($family in $families) {
        $restore = Invoke-ChildPowerShell `
            -Description "restore $($family.name) seed $($family.default_seed)" `
            -Arguments @("-File", (Join-Path $PSScriptRoot $family.script), "-Seed", [string]$family.default_seed, "-SkipSimulation")
        if ($restore.exit_code -ne 0) {
            Write-Host "FAIL: restore failed for $($family.name)"
            $restore.output | ForEach-Object { Write-Host "  $_" }
        }
    }

    $artifactRestored = Test-ArtifactHashesMatch $initialHashes

    if ($artifactRestored) {
        Write-Host "PASS: generated reference artifacts restored to pre-smoke checksums"
    } else {
        Write-Host "FAIL: generated reference artifacts were not restored to pre-smoke checksums"
    }

    $defaultChecksPassed = $true
    foreach ($family in $families) {
        $check = Invoke-ChildPowerShell `
            -Description "check restored $($family.name)" `
            -Arguments @("-File", (Join-Path $PSScriptRoot $family.script), "-Check", "-SkipSimulation")
        if ($check.exit_code -ne 0) {
            $defaultChecksPassed = $false
            Write-Host "FAIL: restored default check failed for $($family.name)"
            $check.output | ForEach-Object { Write-Host "  $_" }
        }
    }

    if ($defaultChecksPassed) {
        Write-Host "PASS: restored default generated reference artifacts pass freshness checks"
    }

    Write-SmokeSummary -Rows $rows -ArtifactRestored $artifactRestored -DefaultChecksPassed $defaultChecksPassed
}

$failedRows = @($rows | Where-Object { $_.status -ne "passed" })
if ($failedRows.Count -ne 0 -or -not $artifactRestored -or -not $defaultChecksPassed) {
    throw "generated reference seed smoke failed"
}

Write-Host "========================================"
Write-Host "PASS: generated reference seed smoke passed ($($rows.Count) seed runs)"
