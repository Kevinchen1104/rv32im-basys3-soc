<#
Script: scripts\final-audit.ps1
Purpose: Verifies the current public architecture, evidence gates, and compact release packages.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\final-audit.ps1
Outputs:
  wave\final-audit-summary.json and a nonzero exit on any consistency failure.
Scope:
  Repository/release consistency only; it verifies recorded scoped physical evidence but never runs hardware or infers board behavior from a bitstream.
Audience:
  Public release audit entrypoint.
#>
param(
    [switch] $PackagedEvidence,
    [switch] $PublishedRelease
)

$ErrorActionPreference = "Stop"
if ($PublishedRelease -and -not $PackagedEvidence) {
    throw "-PublishedRelease requires -PackagedEvidence."
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
New-Item -ItemType Directory -Force -Path "wave" | Out-Null
. "$PSScriptRoot\basys3-physical-evidence.ps1"
. "$PSScriptRoot\verification-source-identity.ps1"

$issues = [System.Collections.Generic.List[string]]::new()
function Add-Issue {
    param([string] $Message)
    $issues.Add($Message) | Out-Null
}

function Read-JsonIfPresent {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-SummaryPath {
    param([string] $FileName)

    if ($PackagedEvidence) {
        return Join-Path "release\final\evidence" $FileName
    }
    return Join-Path "wave" $FileName
}

function Require-Path {
    param([string] $Path, [string] $Description)

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-Issue "$Description missing: $Path"
        return $false
    }
    return $true
}

function Require-Status {
    param([string] $Path, [string[]] $Allowed = @("pass"))

    $json = Read-JsonIfPresent $Path
    if ($null -eq $json) {
        Add-Issue "Summary missing: $Path"
        return $null
    }
    if (-not ($Allowed -contains $json.status)) {
        Add-Issue "$Path reports status '$($json.status)', expected $($Allowed -join ' or ')"
    }
    return $json
}

function Get-AuthoritativeWorkingTreeStatus {
    return @(& git status --porcelain=v1 -- . ":(exclude)release/**" 2>$null)
}

function Get-BuildInputIdentity {
    $inputPaths = [System.Collections.Generic.List[string]]::new()
    $manifestPath = "fpga\fpga_sources.f"
    $inputPaths.Add($manifestPath) | Out-Null

    foreach ($line in Get-Content -LiteralPath $manifestPath) {
        $candidate = $line.Trim()
        if ($candidate -ne "" -and -not $candidate.StartsWith("#")) {
            $inputPaths.Add($candidate.Replace("/", "\")) | Out-Null
        }
    }
    foreach ($supportPath in @(
        "fpga\vivado\basys3_build.tcl",
        "fpga\boards\basys3\basys3.xdc"
    )) {
        $inputPaths.Add($supportPath) | Out-Null
    }

    $records = @(
        foreach ($path in @($inputPaths | Sort-Object -Unique)) {
            if (-not (Test-Path -LiteralPath $path)) {
                Add-Issue "Current FPGA fingerprint input missing: $path"
                continue
            }
            [ordered]@{
                path = $path.Replace("\", "/")
                sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    )
    $identityText = ($records | ForEach-Object { "$($_.path):$($_.sha256)" }) -join "`n"
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($identityText)
        $fingerprint = [System.BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace("-", "").ToLowerInvariant()
    } finally {
        $hasher.Dispose()
    }

    return [ordered]@{
        fingerprint = $fingerprint
        inputs = $records
    }
}

function Test-ReleaseOnlyCommittedPaths {
    param([string[]] $Paths)

    return @($Paths | Where-Object { $_.Replace("\", "/") -notmatch '^release/' })
}

function Test-RepositoryHeadContract {
    param(
        [array] $MetadataRecords,
        [string] $CurrentHead
    )

    # repository_head is the clean package-generation base. A later evidence
    # commit is valid only when every committed path after that base is release/**.
    $reportedHeads = [System.Collections.Generic.List[string]]::new()
    foreach ($record in $MetadataRecords) {
        if ($null -eq $record.value) {
            continue
        }
        $reportedHead = [string]$record.value.repository_head
        if ([string]::IsNullOrWhiteSpace($reportedHead)) {
            Add-Issue "$($record.name) repository_head is missing"
            continue
        }
        if ($reportedHead -notmatch '^[0-9a-fA-F]{40}$') {
            Add-Issue "$($record.name) repository_head is not a full Git commit ID"
            continue
        }
        $reportedHeads.Add($reportedHead.ToLowerInvariant()) | Out-Null
    }

    $uniqueHeads = @($reportedHeads | Sort-Object -Unique)
    if ($uniqueHeads.Count -eq 0) {
        Add-Issue "Evidence metadata does not define a valid package-generation repository_head"
        return [ordered]@{ status = "fail"; base_head = $null; current_head = $CurrentHead; committed_paths = @(); non_release_paths = @() }
    }
    if ($uniqueHeads.Count -ne 1) {
        Add-Issue "Evidence metadata repository_head values are inconsistent: $($uniqueHeads -join ', ')"
        return [ordered]@{ status = "fail"; base_head = $null; current_head = $CurrentHead; committed_paths = @(); non_release_paths = @() }
    }

    $baseHead = $uniqueHeads[0]
    & git cat-file -e "${baseHead}^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Add-Issue "Evidence package-generation repository_head does not identify an existing commit: $baseHead"
        return [ordered]@{ status = "fail"; base_head = $baseHead; current_head = $CurrentHead; committed_paths = @(); non_release_paths = @() }
    }

    & git merge-base --is-ancestor $baseHead $CurrentHead 2>$null
    if ($LASTEXITCODE -ne 0) {
        Add-Issue "Evidence package-generation repository_head is not an ancestor of current HEAD: $baseHead"
        return [ordered]@{ status = "fail"; base_head = $baseHead; current_head = $CurrentHead; committed_paths = @(); non_release_paths = @() }
    }

    $committedPaths = @(& git diff --no-renames --name-only "$baseHead..$CurrentHead" -- 2>$null)
    if ($LASTEXITCODE -ne 0) {
        Add-Issue "Could not inspect committed paths after evidence package-generation repository_head"
        return [ordered]@{ status = "fail"; base_head = $baseHead; current_head = $CurrentHead; committed_paths = @(); non_release_paths = @() }
    }
    $nonReleasePaths = @(Test-ReleaseOnlyCommittedPaths -Paths $committedPaths)
    if ($nonReleasePaths.Count -ne 0) {
        Add-Issue "Evidence packages require refresh because committed non-release paths follow repository_head: $($nonReleasePaths -join ', ')"
    }

    return [ordered]@{
        status = if ($nonReleasePaths.Count -eq 0) { "pass" } else { "fail" }
        base_head = $baseHead
        current_head = $CurrentHead
        committed_paths = $committedPaths
        non_release_paths = $nonReleasePaths
    }
}

function Test-PublishedReleaseContract {
    param(
        [string] $CurrentHead,
        [System.Collections.IDictionary] $BuildIdentity,
        [System.Collections.IDictionary] $VerificationIdentity,
        [System.Collections.IDictionary] $DocumentationIdentity,
        [object] $ReleaseEvidence,
        [object] $PhysicalEvidence
    )

    $manifestPath = "SOURCE_IDENTITY.json"
    $manifest = Read-JsonIfPresent $manifestPath
    if ($null -eq $manifest) {
        Add-Issue "Published release identity is missing: $manifestPath"
        return [ordered]@{ status = "fail"; identity_mode = "missing"; current_head = $CurrentHead }
    }
    if ([int]$manifest.schema_version -ne 1 -or
        $manifest.identity_mode -ne "content_fingerprint") {
        Add-Issue "Published release identity schema or mode is invalid"
    }

    $requiredProjectionPaths = @(
        ".github/workflows/release-consistency.yml",
        "scripts/final-audit.ps1",
        "scripts/verification-source-identity.ps1"
    )
    $projectionPaths = @(
        $manifest.identity_projection.files.PSObject.Properties.Name |
            Sort-Object -Unique
    )
    $projectionDifferences = @(
        Compare-Object -ReferenceObject $requiredProjectionPaths `
            -DifferenceObject $projectionPaths |
            ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }
    )
    if ($projectionDifferences.Count -ne 0) {
        Add-Issue "Published release identity projection inventory is invalid: $($projectionDifferences -join ', ')"
    }

    if ($null -eq $ReleaseEvidence -or
        [string]$manifest.release_identity.source_fingerprint -ne
            [string]$ReleaseEvidence.source_fingerprint -or
        [string]$manifest.release_identity.source_fingerprint -ne
            [string]$BuildIdentity.fingerprint -or
        [string]$manifest.release_identity.verification_input_fingerprint -ne
            [string]$VerificationIdentity.verification_input_fingerprint -or
        [int]$manifest.release_identity.verification_input_count -ne
            [int]$VerificationIdentity.verification_input_count -or
        [string]$manifest.release_identity.documentation_input_fingerprint -ne
            [string]$DocumentationIdentity.documentation_input_fingerprint -or
        [int]$manifest.release_identity.documentation_input_count -ne
            [int]$DocumentationIdentity.documentation_input_count) {
        Add-Issue "Published release fingerprints do not match current content"
    }
    if ($null -eq $PhysicalEvidence -or
        [string]$manifest.release_identity.physical_evidence_summary_sha256 -ne
            [string]$PhysicalEvidence.summary_sha256 -or
        [string]$manifest.release_identity.bitstream_sha256 -ne
            [string]$PhysicalEvidence.bitstream_sha256) {
        Add-Issue "Published release physical/bitstream identity is inconsistent"
    }

    foreach ($entry in $manifest.artifact_manifests.PSObject.Properties) {
        $path = [string]$entry.Name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Add-Issue "Published release artifact manifest is missing: $path"
            continue
        }
        $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne [string]$entry.Value) {
            Add-Issue "Published release artifact manifest hash mismatch: $path"
        }
    }

    return [ordered]@{
        status = if ($issues.Count -eq 0) { "pass" } else { "fail" }
        identity_mode = "content_fingerprint"
        current_head = $CurrentHead
        projected_paths = $projectionPaths
    }
}

function Test-ExactInventory {
    param(
        [string] $Name,
        [string] $Root,
        [string[]] $Expected
    )

    $actual = @()
    if (Test-Path -LiteralPath $Root) {
        $actual = @(
            Get-ChildItem -LiteralPath $Root -Recurse -File |
                ForEach-Object { $_.FullName.Substring($repoRoot.Path.Length + 1).Replace("\", "/") } |
                Sort-Object -Unique
        )
    }
    $expectedSorted = @($Expected | Sort-Object -Unique)
    $differences = @(
        Compare-Object -ReferenceObject $expectedSorted -DifferenceObject $actual |
            ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }
    )
    if ($differences.Count -ne 0) {
        Add-Issue "$Name inventory mismatch: $($differences -join ', ')"
    }
    return [ordered]@{
        name = $Name
        status = if ($differences.Count -eq 0) { "pass" } else { "fail" }
        expected = $expectedSorted
        actual = $actual
        differences = $differences
    }
}

function Test-PackageLayout {
    param(
        [string] $PackageRoot,
        [string] $AllowedPattern
    )

    if (-not (Test-Path -LiteralPath $PackageRoot)) {
        Add-Issue "Package missing: $PackageRoot"
        return
    }
    $base = [System.IO.Path]::GetFullPath($PackageRoot)
    if (-not $base.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $base += [System.IO.Path]::DirectorySeparatorChar
    }
    foreach ($file in Get-ChildItem -LiteralPath $PackageRoot -Recurse -File) {
        $relative = $file.FullName.Substring($base.Length).Replace("\", "/")
        if ($relative -notmatch $AllowedPattern) {
            Add-Issue "Unexpected evidence-package file: $PackageRoot/$relative"
        }
    }
}

function Test-PublicPackagePathRedaction {
    param([string[]] $PackageRoots)

    $sensitivePattern = '(?i)[A-Z]:[\\/]+Users[\\/]+|[A-Z]:[\\/]+(?:AMDDesignTools|AMD|Xilinx)[\\/]'
    foreach ($packageRoot in $PackageRoots) {
        if (-not (Test-Path -LiteralPath $packageRoot)) {
            continue
        }
        foreach ($file in Get-ChildItem -LiteralPath $packageRoot -Recurse -File) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            if ($text -match $sensitivePattern) {
                $relative = $file.FullName.Substring($repoRoot.Path.Length + 1).Replace("\", "/")
                Add-Issue "Public package contains an absolute host/tool path: $relative"
            }
        }
    }
}

function Test-ArtifactManifest {
    param(
        [string] $PackageRoot,
        [string] $ManifestPath
    )

    if (-not (Require-Path -Path $ManifestPath -Description "artifact manifest")) {
        return [ordered]@{ status = "fail"; entries = 0; files = 0 }
    }
    $manifestJson = Read-JsonIfPresent $ManifestPath
    $manifest = @($manifestJson | ForEach-Object { $_ })
    $packageBase = [System.IO.Path]::GetFullPath($PackageRoot)
    if (-not $packageBase.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $packageBase += [System.IO.Path]::DirectorySeparatorChar
    }
    $manifestPaths = [System.Collections.Generic.List[string]]::new()
    $manifestIssueCount = 0

    foreach ($entry in $manifest) {
        $relative = [string]$entry.path
        $normalized = $relative.Replace("\", "/")
        if ([string]::IsNullOrWhiteSpace($normalized) -or [System.IO.Path]::IsPathRooted($relative) -or $normalized -match "(^|/)\.\.(/|$)") {
            Add-Issue "Unsafe artifact path in ${ManifestPath}: $relative"
            $manifestIssueCount += 1
            continue
        }
        if ($normalized.EndsWith(".bit", [System.StringComparison]::OrdinalIgnoreCase)) {
            Add-Issue "Bitstream binary listed in clone-facing manifest: $ManifestPath -> $normalized"
            $manifestIssueCount += 1
        }
        $target = [System.IO.Path]::GetFullPath((Join-Path $PackageRoot $relative))
        if (-not $target.StartsWith($packageBase, [System.StringComparison]::OrdinalIgnoreCase)) {
            Add-Issue "Artifact escapes package root: $ManifestPath -> $normalized"
            $manifestIssueCount += 1
            continue
        }
        $manifestPaths.Add($normalized) | Out-Null
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            Add-Issue "Manifest artifact missing: $ManifestPath -> $normalized"
            $manifestIssueCount += 1
            continue
        }
        $file = Get-Item -LiteralPath $target
        $actualHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        if ([long]$entry.bytes -ne $file.Length -or [string]$entry.sha256 -ne $actualHash) {
            Add-Issue "Artifact size/hash mismatch: $ManifestPath -> $normalized"
            $manifestIssueCount += 1
        }

        $repoRelative = $target.Substring($repoRoot.Path.Length + 1).Replace("\", "/")
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            & git check-ignore --no-index -q -- $repoRelative 2>$null
            $ignoreExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        if ($ignoreExitCode -eq 0) {
            Add-Issue "Manifest artifact is excluded by Git ignore rules: $repoRelative"
            $manifestIssueCount += 1
        }
    }

    $actualPaths = @(
        Get-ChildItem -LiteralPath $PackageRoot -Recurse -File |
            Where-Object { $_.FullName -ne [System.IO.Path]::GetFullPath($ManifestPath) } |
            ForEach-Object { $_.FullName.Substring($packageBase.Length).Replace("\", "/") } |
            Sort-Object -Unique
    )
    $manifestSorted = @($manifestPaths.ToArray() | Sort-Object -Unique)
    $coverageDifferences = @(
        Compare-Object -ReferenceObject $actualPaths -DifferenceObject $manifestSorted |
            ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }
    )
    if ($coverageDifferences.Count -ne 0) {
        Add-Issue "Artifact manifest coverage mismatch in ${ManifestPath}: $($coverageDifferences -join ', ')"
        $manifestIssueCount += $coverageDifferences.Count
    }
    return [ordered]@{
        status = if ($manifestIssueCount -eq 0) { "pass" } else { "fail" }
        entries = $manifestSorted.Count
        files = $actualPaths.Count
        coverage_differences = $coverageDifferences
    }
}

$basys3Profile = Read-JsonIfPresent "fpga\boards\basys3\board.json"
$requiredDocs = @(
    "README.md",
    "docs\README.md",
    "docs\architecture.md",
    "docs\isa_mmio.md",
    "docs\accelerators.md",
    "docs\verification.md",
    "docs\fpga_basys3.md",
    "docs\reproduce.md",
    "docs\limitations.md",
    "docs\evidence\README.md",
    "docs\test_catalog.json"
)
$physicalSummaryPath = if ($null -eq $basys3Profile) {
    ""
} else {
    [string]$basys3Profile.full_direct_100mhz_physical_evidence
}
$normalizedPhysicalSummaryPath = $physicalSummaryPath.Replace("\", "/")
if ($normalizedPhysicalSummaryPath -notmatch '^docs/fpga/board_evidence/[^/]+/summary\.json$') {
    Add-Issue "Basys3 board profile does not select a canonical durable physical-evidence summary"
} else {
    $physicalEvidenceRoot = Split-Path -Parent $physicalSummaryPath
    $requiredDocs += @(
        (Join-Path $physicalEvidenceRoot "README.md"),
        (Join-Path $physicalEvidenceRoot "summary.json"),
        (Join-Path $physicalEvidenceRoot "xsdb-programming-summary.json"),
        (Join-Path $physicalEvidenceRoot "showcase-transcript.txt"),
        (Join-Path $physicalEvidenceRoot "interactive-transcript.txt"),
        (Join-Path $physicalEvidenceRoot "hardware-validation-transcript.txt")
    )
}
foreach ($path in $requiredDocs) {
    Require-Path -Path $path -Description "public documentation" | Out-Null
}

$genericPackage = Read-JsonIfPresent "release\fpga\generic_uart_boot_runtime\status.json"
$basys3Package = Read-JsonIfPresent "release\fpga\basys3\status.json"
$finalPackage = Read-JsonIfPresent "release\final\release-summary.json"

$physicalEvidence = $null
try {
    if ($PackagedEvidence) {
        $physicalEvidence = Get-Basys3PhysicalEvidence
    } else {
        $physicalEvidence = Get-Basys3PhysicalEvidence -VerifyCaptureSources
    }
} catch {
    Add-Issue "Basys3 durable physical evidence failed integrity checks: $($_.Exception.Message)"
}

$architectureInventories = @(
    (Test-ExactInventory -Name "accelerator RTL" -Root "rtl\accelerators" -Expected @(
        "rtl/accelerators/matvec/int8_matvec_dma_lite.v",
        "rtl/accelerators/matvec/int8_matvec_scratchpad_accelerator.v"
    )),
    (Test-ExactInventory -Name "accelerator firmware source" -Root "firmware\src\accelerator" -Expected @(
        "firmware/src/accelerator/matvec_dma_demo.S",
        "firmware/src/accelerator/matvec_scratchpad_demo.S",
        "firmware/src/accelerator/matvec_scratchpad_interrupt.S",
        "firmware/src/accelerator/matvec_scratchpad_no_interrupt.S"
    )),
    (Test-ExactInventory -Name "accelerator firmware image" -Root "firmware\hex\accelerator" -Expected @(
        "firmware/hex/accelerator/matvec_dma_demo.hex",
        "firmware/hex/accelerator/matvec_scratchpad_demo.hex",
        "firmware/hex/accelerator/matvec_scratchpad_interrupt.hex",
        "firmware/hex/accelerator/matvec_scratchpad_no_interrupt.hex"
    )),
    (Test-ExactInventory -Name "accelerator unit test" -Root "tb\unit\accelerators" -Expected @(
        "tb/unit/accelerators/tb_int8_matvec_dma_lite.v",
        "tb/unit/accelerators/tb_int8_matvec_scratchpad_accelerator.v",
        "tb/unit/accelerators/tb_matvec_perf_counters.v"
    )),
    (Test-ExactInventory -Name "accelerator program test" -Root "tb\program\accelerator" -Expected @(
        "tb/program/accelerator/tb_program_matvec_dma_demo.v",
        "tb/program/accelerator/tb_program_matvec_scratchpad.v",
        "tb/program/accelerator/tb_program_matvec_scratchpad_interrupt.v",
        "tb/program/accelerator/tb_program_matvec_scratchpad_no_interrupt.v"
    ))
)

$rtlManifest = Get-Content -LiteralPath "rtl\rtl_sources.f" -Raw
$fpgaManifest = Get-Content -LiteralPath "fpga\fpga_sources.f" -Raw
foreach ($requiredSource in @(
    "rtl/accelerators/matvec/int8_matvec_scratchpad_accelerator.v",
    "rtl/accelerators/matvec/int8_matvec_dma_lite.v"
)) {
    if ($rtlManifest -notmatch [regex]::Escape($requiredSource)) {
        Add-Issue "RTL manifest does not include $requiredSource"
    }
    if ($fpgaManifest -notmatch [regex]::Escape($requiredSource)) {
        Add-Issue "FPGA manifest does not include $requiredSource"
    }
}

$coreText = Get-Content -LiteralPath "rtl\core\riscv_cpu_core.v" -Raw
foreach ($requiredPattern in @("accel_matvec", "matvec_irq_pending", "matvec_start_accepted", "matvec_done", "matvec_busy")) {
    if ($coreText -notmatch $requiredPattern) {
        Add-Issue "Core integration marker missing: $requiredPattern"
    }
}
$decodeTest = Get-Content -LiteralPath "tb\unit\peripherals\tb_mmio_decode.v" -Raw
$muxTest = Get-Content -LiteralPath "tb\unit\soc\tb_mmio_read_mux.v" -Raw
if ($decodeTest -notmatch "0x0400\.\.0x05ff" -or $decodeTest -notmatch "ordinary memory") {
    Add-Issue "MMIO decoder test does not cover ordinary-memory behavior for 0x0400..0x05ff"
}
if ($muxTest -notmatch "0x0400\.\.0x05ff" -or $muxTest -notmatch "ordinary memory") {
    Add-Issue "MMIO read-mux test does not cover ordinary-memory fallback for 0x0400..0x05ff"
}

$catalog = Get-Content -LiteralPath "docs\test_catalog.json" -Raw | ConvertFrom-Json
$expectedRegressionNames = @(
    $catalog.tests |
        Where-Object { $_.included_in_full_regression } |
        ForEach-Object { $_.name } |
        Sort-Object -Unique
)
$expectedRegressionCount = $expectedRegressionNames.Count
$regression = Read-JsonIfPresent (Get-SummaryPath "regression-summary.json")
$regressionNameDifferences = @()
if ($null -eq $regression) {
    Add-Issue "Full regression summary missing"
} else {
    $regressionNames = @($regression.tests | ForEach-Object { $_.name } | Sort-Object -Unique)
    $regressionNameDifferences = @(
        Compare-Object -ReferenceObject $expectedRegressionNames -DifferenceObject $regressionNames |
            ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }
    )
    if ([int]$regression.total -ne $expectedRegressionCount -or
        [int]$regression.passed -ne $expectedRegressionCount -or
        [int]$regression.failed -ne 0 -or
        @($regression.tests | Where-Object { $_.status -ne "passed" }).Count -ne 0 -or
        $regressionNameDifferences.Count -ne 0) {
        Add-Issue "Full regression does not exactly match the current catalog: expected=$expectedRegressionCount total=$($regression.total) passed=$($regression.passed) failed=$($regression.failed) name_diff=$($regressionNameDifferences -join ', ')"
    }
}

$sourceGateSummaries = @(
    (Get-SummaryPath "check-summary.json"),
    (Get-SummaryPath "regression-evidence-summary.json"),
    (Get-SummaryPath "verilator-lint-summary.json"),
    (Get-SummaryPath "synth-smoke-summary.json"),
    (Get-SummaryPath "formal-smoke-summary.json"),
    (Get-SummaryPath "formal-matvec-smoke-summary.json"),
    (Get-SummaryPath "vivado-basys3-robustness-summary.json"),
    (Get-SummaryPath "release-evidence-summary.json")
)
$documentationGateSummaries = @(
    (Get-SummaryPath "documentation-coverage-summary.json"),
    (Get-SummaryPath "docs-link-audit-summary.json"),
    (Get-SummaryPath "claim-audit-summary.json")
)
$currentVerificationIdentity = Get-VerificationSourceIdentity
$currentDocumentationIdentity = Get-DocumentationInputIdentity
if ($currentVerificationIdentity.verification_working_tree_dirty) {
    Add-Issue "Verification source inputs are dirty; release evidence requires a committed source/test/tooling inventory"
}
if ($currentDocumentationIdentity.documentation_source_working_tree_dirty) {
    Add-Issue "Non-release documentation inputs are dirty; documentation evidence requires committed inputs"
}
$gateObjects = [ordered]@{}
foreach ($path in $sourceGateSummaries) {
    $gateObject = Require-Status -Path $path
    $gateObjects[$path.Replace("\", "/")] = $gateObject
    if ($null -ne $gateObject -and (
        [string]$gateObject.verification_input_fingerprint -ne $currentVerificationIdentity.verification_input_fingerprint -or
        [int]$gateObject.verification_input_count -ne $currentVerificationIdentity.verification_input_count -or
        $gateObject.verification_working_tree_dirty -ne $false
    )) {
        Add-Issue "$path does not match the current committed verification-source identity"
    }
}
$documentationGateObjects = [ordered]@{}
foreach ($path in $documentationGateSummaries) {
    $gateObject = Require-Status -Path $path
    $documentationGateObjects[$path.Replace("\", "/")] = $gateObject
    if ($null -ne $gateObject -and (
        [string]$gateObject.documentation_input_fingerprint -ne
            $currentDocumentationIdentity.documentation_input_fingerprint -or
        [int]$gateObject.documentation_input_count -ne
            $currentDocumentationIdentity.documentation_input_count -or
        $gateObject.documentation_source_working_tree_dirty -ne $false
    )) {
        Add-Issue "$path does not match the current documentation/package identity"
    }
}
if ($null -ne $regression -and (
    [string]$regression.verification_input_fingerprint -ne $currentVerificationIdentity.verification_input_fingerprint -or
    [int]$regression.verification_input_count -ne $currentVerificationIdentity.verification_input_count -or
    $regression.verification_working_tree_dirty -ne $false
)) {
    Add-Issue "Full regression summary does not match the current committed verification-source identity"
}

$releaseEvidence = Read-JsonIfPresent (Get-SummaryPath "release-evidence-summary.json")
if ($null -ne $releaseEvidence) {
    foreach ($gateEntry in $gateObjects.GetEnumerator()) {
        if ($null -ne $gateEntry.Value -and
            [string]$gateEntry.Value.source_commit -ne
            [string]$releaseEvidence.source_commit) {
            Add-Issue "$($gateEntry.Key) source commit does not match release evidence"
        }
    }
    foreach ($gateEntry in $documentationGateObjects.GetEnumerator()) {
        if ($null -ne $gateEntry.Value -and
            [string]$gateEntry.Value.documentation_repository_head -ne
            [string]$releaseEvidence.repository_head) {
            Add-Issue "$($gateEntry.Key) repository HEAD does not match release generation"
        }
    }
    if ($null -ne $regression -and
        [string]$regression.source_commit -ne
        [string]$releaseEvidence.source_commit) {
        Add-Issue "Full regression source commit does not match release evidence"
    }
}
$vivadoDetect = Read-JsonIfPresent (Get-SummaryPath "vivado-detect-summary.json")
$vivadoBuild = Read-JsonIfPresent (Get-SummaryPath "vivado-basys3-build-summary.json")
$robustnessBuild = Read-JsonIfPresent (Get-SummaryPath "vivado-basys3-robustness-summary.json")
$vivadoRequired = if ($PackagedEvidence) {
    $null -ne $vivadoBuild
} else {
    $null -ne $vivadoDetect -and $vivadoDetect.status -eq "available"
}
$currentBuildIdentity = Get-BuildInputIdentity
$currentSourceFingerprint = $currentBuildIdentity.fingerprint
$vivadoPackageConsistent = $false
$vivadoMatchesCurrentSource = $false
$robustnessMatchesCurrentSource = $false
$bitstreamSha256 = $null
if ($vivadoRequired) {
    if ($null -eq $vivadoBuild) {
        Add-Issue "Vivado is available but the Basys3 build summary is missing"
    } else {
        $postRoute = $vivadoBuild.reports.post_route_timing
        $postRouteDrc = $vivadoBuild.reports.post_route_drc
        $vivadoPackageConsistent = (
            $null -ne $releaseEvidence -and
            $vivadoBuild.status -eq "pass" -and
            $vivadoBuild.mode -eq "bitstream" -and
            $vivadoBuild.top -eq "RISCVCPU_basys3_top" -and
            $vivadoBuild.source_fingerprint -eq $releaseEvidence.source_fingerprint -and
            $vivadoBuild.implementation_status -eq "pass" -and
            $vivadoBuild.timing_closure_status -eq "met" -and
            $vivadoBuild.timing_constraint_status -eq "pass" -and
            $null -ne $postRoute.wns_ns -and [double]$postRoute.wns_ns -ge 0.0 -and
            $null -ne $postRoute.tns_ns -and [double]$postRoute.tns_ns -eq 0.0 -and
            $null -ne $postRoute.whs_ns -and [double]$postRoute.whs_ns -ge 0.0 -and
            $null -ne $postRoute.ths_ns -and [double]$postRoute.ths_ns -eq 0.0 -and
            $null -ne $postRoute.no_clock_count -and [int]$postRoute.no_clock_count -eq 0 -and
            $null -ne $postRoute.unconstrained_internal_endpoint_count -and
                [int]$postRoute.unconstrained_internal_endpoint_count -eq 0 -and
            $null -ne $postRoute.no_input_delay_count -and [int]$postRoute.no_input_delay_count -eq 0 -and
            $null -ne $postRoute.no_output_delay_count -and [int]$postRoute.no_output_delay_count -eq 0 -and
            $vivadoBuild.drc_status -eq "pass" -and
            $null -ne $postRouteDrc -and $postRouteDrc.present -eq $true -and
            $postRouteDrc.report_parse_complete -eq $true -and
            $postRouteDrc.release_approved -eq $true -and
            [int]$postRouteDrc.error_count -eq 0 -and
            [int]$postRouteDrc.critical_warning_count -eq 0 -and
            [int]$postRouteDrc.unapproved_warning_count -eq 0 -and
            [int]$postRouteDrc.bram_async_control_warning_count -eq 0 -and
            $vivadoBuild.bitstream_status -eq "pass" -and
            -not [string]::IsNullOrWhiteSpace($vivadoBuild.bitstream) -and
            (
                ($PackagedEvidence -and
                 $null -ne $basys3Package -and
                 $basys3Package.bitstream_status -eq "generated_current_sources" -and
                 [string]$basys3Package.bitstream_sha256 -match '^[0-9a-f]{64}$') -or
                (-not $PackagedEvidence -and
                 (Test-Path -LiteralPath $vivadoBuild.bitstream))
            )
        )
        $vivadoMatchesCurrentSource = (
            $vivadoPackageConsistent -and
            $vivadoBuild.source_fingerprint -eq $currentSourceFingerprint
        )
        if ($vivadoMatchesCurrentSource) {
            $bitstreamSha256 = if ($PackagedEvidence) {
                [string]$basys3Package.bitstream_sha256
            } else {
                (Get-FileHash -LiteralPath $vivadoBuild.bitstream -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        } elseif ($vivadoPackageConsistent) {
            Add-Issue "Vivado package is internally consistent but does not match the current FPGA source fingerprint"
        } else {
            Add-Issue "Vivado package/build evidence is internally inconsistent or does not meet the direct-100-MHz implementation, bitstream, WNS/TNS, and DRC requirements"
        }
    }
}
$robustnessFailedRuns = @(
    if ($null -ne $robustnessBuild) {
        $robustnessBuild.runs | Where-Object {
            $_.status -ne "pass" -or
            $_.implementation_status -ne "pass" -or
            $_.timing_closure_status -ne "met" -or
            $_.timing_constraint_status -ne "pass" -or
            [double]$_.wns_ns -lt 0.0 -or
            [double]$_.tns_ns -ne 0.0 -or
            [double]$_.whs_ns -lt 0.0 -or
            [double]$_.ths_ns -ne 0.0 -or
            [int]$_.no_clock_count -ne 0 -or
            [int]$_.unconstrained_internal_endpoint_count -ne 0 -or
            [int]$_.no_input_delay_count -ne 0 -or
            [int]$_.no_output_delay_count -ne 0 -or
            $_.drc_status -ne "pass" -or
            [int]$_.drc_error_count -ne 0 -or
            [int]$_.drc_critical_warning_count -ne 0 -or
            [int]$_.drc_unapproved_warning_count -ne 0 -or
            [int]$_.bram_async_control_warning_count -ne 0
        }
    }
)
$robustnessMatchesCurrentSource = (
    $null -ne $robustnessBuild -and
    $robustnessBuild.status -eq "pass" -and
    $robustnessBuild.top -eq "RISCVCPU_basys3_top" -and
    [int]$robustnessBuild.run_count -eq 5 -and
    $robustnessBuild.all_implementations_passed -eq $true -and
    $robustnessBuild.identity_consistent -eq $true -and
    $robustnessBuild.working_tree_dirty -eq $false -and
    [string]$robustnessBuild.source_fingerprint -eq $currentSourceFingerprint -and
    [string]$robustnessBuild.verification_input_fingerprint -eq
        $currentVerificationIdentity.verification_input_fingerprint -and
    [int]$robustnessBuild.verification_input_count -eq
        $currentVerificationIdentity.verification_input_count -and
    $robustnessBuild.verification_working_tree_dirty -eq $false -and
    @($robustnessBuild.runs).Count -eq 5 -and
    $robustnessFailedRuns.Count -eq 0
)
if ($vivadoRequired -and -not $robustnessMatchesCurrentSource) {
    Add-Issue "Vivado robustness evidence does not contain five current-source timing-closed implementation strategies"
}

if ($null -eq $physicalEvidence -or $null -eq $basys3Profile -or
    $basys3Profile.physical_validation_status -ne $physicalEvidence.physical_validation_status -or
    $basys3Profile.physical_validation_scope -ne $physicalEvidence.physical_validation_scope -or
    $basys3Profile.full_direct_100mhz_source_commit -ne $physicalEvidence.source_commit -or
    $basys3Profile.full_direct_100mhz_source_fingerprint -ne $physicalEvidence.source_fingerprint -or
    $basys3Profile.full_direct_100mhz_bitstream_sha256 -ne $physicalEvidence.bitstream_sha256 -or
    [long]$basys3Profile.full_direct_100mhz_bitstream_size_bytes -ne [long]$physicalEvidence.bitstream_size_bytes) {
    Add-Issue "Basys3 board profile does not match the durable scoped physical evidence"
}

$authoritativeWorkingTreeStatus = @(Get-AuthoritativeWorkingTreeStatus)
$authoritativeWorkingTreeDirty = $authoritativeWorkingTreeStatus.Count -ne 0
$repositoryHead = (& git rev-parse HEAD 2>$null).Trim()
$currentRtlSourceCount = @(
    Get-Content -LiteralPath "fpga\fpga_sources.f" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne "" -and -not $_.StartsWith("#") }
).Count
$currentFingerprintInputCount = @($currentBuildIdentity.inputs).Count
foreach ($packageCheck in @(
    @{ name = "generic FPGA evidence package"; value = $genericPackage; physical_status = "not_run"; physical_scope = "needs_revalidation" },
    @{ name = "Basys3 FPGA evidence package"; value = $basys3Package; physical_status = if ($null -eq $physicalEvidence) { "passed" } else { $physicalEvidence.physical_validation_status }; physical_scope = if ($null -eq $physicalEvidence) { "invalid" } else { $physicalEvidence.physical_validation_scope } },
    @{ name = "final evidence package"; value = $finalPackage; physical_status = if ($null -eq $physicalEvidence) { "passed" } else { $physicalEvidence.physical_validation_status }; physical_scope = if ($null -eq $physicalEvidence) { "invalid" } else { $physicalEvidence.physical_validation_scope } }
)) {
    if ($null -eq $packageCheck.value -or $packageCheck.value.status -ne "pass" -or $packageCheck.value.package_kind -ne "evidence_only") {
        Add-Issue "$($packageCheck.name) is missing or not an evidence-only pass package"
    } else {
        if ($packageCheck.value.physical_validation_status -ne $packageCheck.physical_status -or
            $packageCheck.value.physical_validation_scope -ne $packageCheck.physical_scope) {
            Add-Issue "$($packageCheck.name) physical validation status/scope is inconsistent"
        }
        if ($packageCheck.value.bitstream_file_tracked -ne $false -or $packageCheck.value.binary_intentionally_not_packaged -ne $true) {
            Add-Issue "$($packageCheck.name) must mark the bitstream binary as untracked and intentionally not packaged"
        }
        if ($packageCheck.value.working_tree_scope -ne "repository_excluding_release") {
            Add-Issue "$($packageCheck.name) must define working-tree scope as repository_excluding_release"
        }
        if ([bool]$packageCheck.value.working_tree_dirty -ne $authoritativeWorkingTreeDirty) {
            Add-Issue "$($packageCheck.name) working_tree_dirty does not match the repository state excluding release outputs"
        }
        if ([int]$packageCheck.value.rtl_source_count -ne $currentRtlSourceCount -or
            [int]$packageCheck.value.fingerprint_input_count -ne $currentFingerprintInputCount) {
            Add-Issue "$($packageCheck.name) source/input counts do not match the current fingerprint inventory"
        }
        if ([string]$packageCheck.value.verification_input_fingerprint -ne $currentVerificationIdentity.verification_input_fingerprint -or
            [int]$packageCheck.value.verification_input_count -ne $currentVerificationIdentity.verification_input_count -or
            $packageCheck.value.verification_working_tree_dirty -ne $false) {
            Add-Issue "$($packageCheck.name) does not match the current committed verification-source identity"
        }
    }
}
if ($null -eq $releaseEvidence -or $releaseEvidence.working_tree_scope -ne "repository_excluding_release") {
    Add-Issue "Release evidence must define working-tree scope as repository_excluding_release"
} elseif ([bool]$releaseEvidence.working_tree_dirty -ne $authoritativeWorkingTreeDirty) {
    Add-Issue "Release evidence working_tree_dirty does not match the repository state excluding release outputs"
}
if ($null -ne $releaseEvidence) {
    if ([string]$releaseEvidence.verification_input_fingerprint -ne $currentVerificationIdentity.verification_input_fingerprint -or
        [int]$releaseEvidence.verification_input_count -ne $currentVerificationIdentity.verification_input_count -or
        $releaseEvidence.verification_working_tree_dirty -ne $false) {
        Add-Issue "Release evidence does not match the current committed verification-source identity"
    }
    if ($null -eq $physicalEvidence -or
        $releaseEvidence.physical_validation_status -ne $physicalEvidence.physical_validation_status -or
        $releaseEvidence.physical_validation_scope -ne $physicalEvidence.physical_validation_scope -or
        $releaseEvidence.physical_evidence.summary_sha256 -ne $physicalEvidence.summary_sha256) {
        Add-Issue "Release evidence does not match the durable scoped physical evidence"
    }
    if ($vivadoMatchesCurrentSource -and $releaseEvidence.source_commit -ne $vivadoBuild.source_commit) {
        Add-Issue "Release evidence source_commit does not match the current source-fingerprint-matched Vivado build"
    }
    foreach ($package in @($genericPackage, $basys3Package, $finalPackage)) {
        if ($null -ne $package -and $package.source_fingerprint -ne $releaseEvidence.source_fingerprint) {
            Add-Issue "Evidence package source fingerprint does not match release evidence"
        }
        if ($null -ne $package -and $package.source_commit -ne $releaseEvidence.source_commit) {
            Add-Issue "Evidence package synthesis source commit does not match release evidence"
        }
    }
}
foreach ($physicalPackage in @(
    @{ name = "Basys3 FPGA evidence package"; value = $basys3Package },
    @{ name = "final evidence package"; value = $finalPackage }
)) {
    if ($null -ne $physicalPackage.value -and $null -ne $physicalEvidence) {
        if ($physicalPackage.value.physical_evidence_summary_sha256 -ne $physicalEvidence.summary_sha256 -or
            $physicalPackage.value.programming_evidence_level -ne $physicalEvidence.programming_evidence_level -or
            $physicalPackage.value.uart_evidence_level -ne $physicalEvidence.uart_evidence_level -or
            $physicalPackage.value.led_reset_evidence_level -ne $physicalEvidence.led_reset_evidence_level) {
            Add-Issue "$($physicalPackage.name) physical evidence metadata is inconsistent"
        }
    }
}
$repositoryHeadContract = if ($PublishedRelease) {
    Test-PublishedReleaseContract `
        -CurrentHead $repositoryHead `
        -BuildIdentity $currentBuildIdentity `
        -VerificationIdentity $currentVerificationIdentity `
        -DocumentationIdentity $currentDocumentationIdentity `
        -ReleaseEvidence $releaseEvidence `
        -PhysicalEvidence $physicalEvidence
} else {
    Test-RepositoryHeadContract -CurrentHead $repositoryHead -MetadataRecords @(
        @{ name = "release evidence"; value = $releaseEvidence },
        @{ name = "generic FPGA evidence package"; value = $genericPackage },
        @{ name = "Basys3 FPGA evidence package"; value = $basys3Package },
        @{ name = "final evidence package"; value = $finalPackage }
    )
}

$sourceManifestPairs = @(
    @{ source = "fpga\fpga_sources.f"; copy = "release\fpga\generic_uart_boot_runtime\fpga_sources.f" },
    @{ source = "fpga\fpga_sources.f"; copy = "release\fpga\basys3\fpga_sources.f" },
    @{ source = "fpga\fpga_sources.f"; copy = "release\final\source-manifests\fpga_sources.f" },
    @{ source = "rtl\rtl_sources.f"; copy = "release\final\source-manifests\rtl_sources.f" }
)
foreach ($pair in $sourceManifestPairs) {
    if ((Require-Path -Path $pair.source -Description "authoritative source manifest") -and
        (Require-Path -Path $pair.copy -Description "packaged source manifest")) {
        $sourceHash = (Get-FileHash -LiteralPath $pair.source -Algorithm SHA256).Hash
        $copyHash = (Get-FileHash -LiteralPath $pair.copy -Algorithm SHA256).Hash
        if ($sourceHash -ne $copyHash) {
            Add-Issue "Packaged source manifest does not match authoritative manifest: $($pair.copy)"
        }
    }
}
if ($vivadoRequired -and $vivadoMatchesCurrentSource -and $null -ne $basys3Package) {
    if ($basys3Package.vivado_evidence_status -ne "current" -or
        $basys3Package.timing_closure_status -ne "met" -or
        $basys3Package.timing_constraint_status -ne "pass" -or
        [int]$basys3Package.no_clock_count -ne 0 -or
        [int]$basys3Package.unconstrained_internal_endpoint_count -ne 0 -or
        [int]$basys3Package.no_input_delay_count -ne 0 -or
        [int]$basys3Package.no_output_delay_count -ne 0 -or
        $basys3Package.drc_status -ne "pass" -or
        [int]$basys3Package.drc_error_count -ne 0 -or
        [int]$basys3Package.drc_critical_warning_count -ne 0 -or
        [int]$basys3Package.drc_unapproved_warning_count -ne 0 -or
        [int]$basys3Package.bram_async_control_warning_count -ne 0 -or
        $basys3Package.robustness_evidence_status -ne "current" -or
        [int]$basys3Package.robustness_run_count -ne 5 -or
        [double]$basys3Package.robustness_worst_wns_ns -lt 0.0 -or
        [double]$basys3Package.robustness_best_wns_ns -lt
            [double]$basys3Package.robustness_worst_wns_ns -or
        $basys3Package.bitstream_status -ne "generated_current_sources" -or
        $basys3Package.bitstream_sha256 -ne $bitstreamSha256) {
        Add-Issue "Basys3 package metadata does not match the current timing/bitstream evidence"
    }
    if ($basys3Package.report_host_metadata_redacted -ne $true) {
        Add-Issue "Basys3 package must redact host metadata from public Vivado reports"
    }
    if ($basys3Package.report_path_metadata_redacted -ne $true) {
        Add-Issue "Basys3 package must redact absolute repository and Vivado paths"
    }
}

$genericRequired = @("COMMANDS.md", "status.json", "artifacts.json", "fpga_sources.f")
foreach ($name in $genericRequired) {
    Require-Path -Path (Join-Path "release\fpga\generic_uart_boot_runtime" $name) -Description "generic package file" | Out-Null
}
$basys3Required = @(
    "COMMANDS.md", "status.json", "artifacts.json", "fpga_sources.f",
    "evidence\vivado-basys3-build-summary.json",
    "evidence\vivado-basys3-robustness-summary.json",
    "evidence\reports\post_synth_drc.rpt", "evidence\reports\post_route_drc.rpt",
    "evidence\reports\post_route_timing_exceptions.rpt",
    "evidence\physical\README.md", "evidence\physical\summary.json",
    "evidence\physical\xsdb-programming-summary.json",
    "evidence\physical\showcase-transcript.txt", "evidence\physical\interactive-transcript.txt",
    "evidence\physical\hardware-validation-transcript.txt"
)
foreach ($name in $basys3Required) {
    Require-Path -Path (Join-Path "release\fpga\basys3" $name) -Description "Basys3 package file" | Out-Null
}
$finalRequired = @(
    "README.md", "release-summary.json", "evidence-index.md", "limitations.md", "artifacts.json",
    "source-manifests\rtl_sources.f", "source-manifests\fpga_sources.f",
    "evidence\vivado-basys3-robustness-summary.json",
    "evidence\physical\README.md", "evidence\physical\summary.json",
    "evidence\physical\xsdb-programming-summary.json",
    "evidence\physical\showcase-transcript.txt", "evidence\physical\interactive-transcript.txt",
    "evidence\physical\hardware-validation-transcript.txt"
)
foreach ($name in $finalRequired) {
    Require-Path -Path (Join-Path "release\final" $name) -Description "final package file" | Out-Null
}

Test-PackageLayout -PackageRoot "release\fpga\generic_uart_boot_runtime" -AllowedPattern '^(COMMANDS\.md|status\.json|artifacts\.json|fpga_sources\.f)$'
Test-PackageLayout -PackageRoot "release\fpga\basys3" -AllowedPattern '^(COMMANDS\.md|status\.json|artifacts\.json|fpga_sources\.f|evidence/vivado-basys3-(build|robustness)-summary\.json|evidence/reports/[^/]+\.rpt|evidence/physical/(README\.md|summary\.json|xsdb-programming-summary\.json|showcase-transcript\.txt|interactive-transcript\.txt|hardware-validation-transcript\.txt))$'
Test-PackageLayout -PackageRoot "release\final" -AllowedPattern '^(README\.md|release-summary\.json|evidence-index\.md|limitations\.md|artifacts\.json|evidence/[^/]+\.json|evidence/physical/(README\.md|summary\.json|xsdb-programming-summary\.json|showcase-transcript\.txt|interactive-transcript\.txt|hardware-validation-transcript\.txt)|source-manifests/(rtl_sources|fpga_sources)\.f)$'
Test-PublicPackagePathRedaction -PackageRoots @("release\fpga\basys3", "release\final")

if ($null -ne $physicalEvidence) {
    foreach ($physicalFile in @("README.md", "summary.json", "xsdb-programming-summary.json", "showcase-transcript.txt", "interactive-transcript.txt", "hardware-validation-transcript.txt")) {
        $authoritativePath = Join-Path $physicalEvidence.evidence_root $physicalFile
        foreach ($packageRoot in @("release\fpga\basys3\evidence\physical", "release\final\evidence\physical")) {
            $packagedPath = Join-Path $packageRoot $physicalFile
            if ((Require-Path -Path $packagedPath -Description "packaged physical evidence") -and
                (Get-FileHash -LiteralPath $authoritativePath -Algorithm SHA256).Hash -ne
                (Get-FileHash -LiteralPath $packagedPath -Algorithm SHA256).Hash) {
                Add-Issue "Packaged physical evidence does not match durable source: $packagedPath"
            }
        }
    }
}

$expectedBasys3Reports = @(
    "post_synth_utilization.rpt",
    "post_synth_timing_summary.rpt",
    "post_synth_critical_paths.rpt",
    "post_synth_clocks.rpt",
    "post_synth_drc.rpt",
    "post_route_utilization.rpt",
    "post_route_timing_summary.rpt",
    "post_route_critical_paths.rpt",
    "post_route_clocks.rpt",
    "post_route_drc.rpt",
    "post_route_timing_exceptions.rpt"
)
$actualBasys3Reports = @(
    Get-ChildItem -LiteralPath "release\fpga\basys3\evidence\reports" `
        -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name } |
        Sort-Object
)
if ($vivadoRequired -and $vivadoMatchesCurrentSource) {
    $missingBasys3Reports = @(
        $expectedBasys3Reports | Where-Object { $_ -notin $actualBasys3Reports }
    )
    $unexpectedBasys3Reports = @(
        $actualBasys3Reports | Where-Object { $_ -notin $expectedBasys3Reports }
    )
    if ($missingBasys3Reports.Count -ne 0 -or
        $unexpectedBasys3Reports.Count -ne 0) {
        Add-Issue (
            "Basys3 Vivado report inventory mismatch; missing=[{0}], unexpected=[{1}]" -f
            ($missingBasys3Reports -join ", "),
            ($unexpectedBasys3Reports -join ", ")
        )
    }
}

$manifestResults = [ordered]@{
    generic = Test-ArtifactManifest -PackageRoot "release\fpga\generic_uart_boot_runtime" -ManifestPath "release\fpga\generic_uart_boot_runtime\artifacts.json"
    basys3 = Test-ArtifactManifest -PackageRoot "release\fpga\basys3" -ManifestPath "release\fpga\basys3\artifacts.json"
    final = Test-ArtifactManifest -PackageRoot "release\final" -ManifestPath "release\final\artifacts.json"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    $diffCheckOutput = @(& git diff --check 2>&1)
    $diffCheckExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
if ($diffCheckExitCode -ne 0) {
    Add-Issue "git diff --check failed: $($diffCheckOutput -join '; ')"
}
$stagedChanges = @(& git diff --cached --name-only)
if ($stagedChanges.Count -ne 0) {
    Add-Issue "Files are staged even though this work must remain unstaged: $($stagedChanges -join ', ')"
}

$packageFileCounts = [ordered]@{
    final = @(Get-ChildItem -LiteralPath "release\final" -Recurse -File).Count
    basys3 = @(Get-ChildItem -LiteralPath "release\fpga\basys3" -Recurse -File).Count
    generic = @(Get-ChildItem -LiteralPath "release\fpga\generic_uart_boot_runtime" -Recurse -File).Count
}
$summary = [ordered]@{
    schema_version = 3
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = if ($issues.Count -eq 0) { "pass" } else { "fail" }
    issue_count = $issues.Count
    issues = $issues.ToArray()
    public_docs = $requiredDocs
    architecture_inventories = $architectureInventories
    current_architecture = [ordered]@{
        accelerator_count = 2
        accelerators = @("MATVEC Scratchpad", "MATVEC DMA-lite")
        mmio_windows = @("0x0700..0x0720", "0x0900..0x0920")
        ordinary_memory_range = "0x0400..0x05ff"
    }
    test_catalog_entries = @($catalog.tests).Count
    full_regression_expected = $expectedRegressionCount
    full_regression_total = if ($null -eq $regression) { $null } else { $regression.total }
    regression_name_differences = $regressionNameDifferences
    required_gate_summaries = $gateObjects
    required_documentation_gate_summaries = $documentationGateObjects
    vivado_required = $vivadoRequired
    vivado_package_consistent = $vivadoPackageConsistent
    vivado_matches_current_source = $vivadoMatchesCurrentSource
    vivado_robustness_matches_current_source = $robustnessMatchesCurrentSource
    vivado_robustness_run_count = if ($null -eq $robustnessBuild) { $null } else { $robustnessBuild.run_count }
    vivado_robustness_worst_wns_ns = if ($null -eq $robustnessBuild) { $null } else { $robustnessBuild.worst_wns_ns }
    vivado_robustness_best_wns_ns = if ($null -eq $robustnessBuild) { $null } else { $robustnessBuild.best_wns_ns }
    vivado_robustness_margin_target_status = if ($null -eq $robustnessBuild) { "not_run" } else { $robustnessBuild.margin_target_status }
    current_source_fingerprint = $currentSourceFingerprint
    current_verification_input_fingerprint = $currentVerificationIdentity.verification_input_fingerprint
    current_verification_input_count = $currentVerificationIdentity.verification_input_count
    current_documentation_input_fingerprint = $currentDocumentationIdentity.documentation_input_fingerprint
    current_documentation_input_count = $currentDocumentationIdentity.documentation_input_count
    release_source_fingerprint = if ($null -eq $releaseEvidence) { $null } else { $releaseEvidence.source_fingerprint }
    audit_identity_mode = if ($PublishedRelease) { "content_fingerprint" } else { "development_commit_ancestry" }
    repository_head_contract = $repositoryHeadContract
    working_tree_dirty = $authoritativeWorkingTreeDirty
    working_tree_scope = "repository_excluding_release"
    authoritative_working_tree_entry_count = $authoritativeWorkingTreeStatus.Count
    rtl_source_count = $currentRtlSourceCount
    fingerprint_input_count = $currentFingerprintInputCount
    timing_closure_status = if ($vivadoMatchesCurrentSource) { $vivadoBuild.timing_closure_status } else { "not_run" }
    drc_status = if ($vivadoMatchesCurrentSource) { $vivadoBuild.drc_status } else { "not_run" }
    bitstream_status = if ($vivadoMatchesCurrentSource) { $vivadoBuild.bitstream_status } else { "not_run" }
    bitstream_sha256 = $bitstreamSha256
    bitstream_file_tracked = $false
    binary_intentionally_not_packaged = $true
    package_file_counts = $packageFileCounts
    artifact_manifests = $manifestResults
    physical_validation_status = if ($null -eq $physicalEvidence) { "fail" } else { $physicalEvidence.physical_validation_status }
    physical_validation_scope = if ($null -eq $physicalEvidence) { "invalid" } else { $physicalEvidence.physical_validation_scope }
    physical_evidence_summary_path = if ($null -eq $physicalEvidence) { $null } else { $physicalEvidence.summary_path }
    physical_evidence_summary_sha256 = if ($null -eq $physicalEvidence) { $null } else { $physicalEvidence.summary_sha256 }
    programming_evidence_level = if ($null -eq $physicalEvidence) { $null } else { $physicalEvidence.programming_evidence_level }
    uart_evidence_level = if ($null -eq $physicalEvidence) { $null } else { $physicalEvidence.uart_evidence_level }
    led_reset_evidence_level = if ($null -eq $physicalEvidence) { $null } else { $physicalEvidence.led_reset_evidence_level }
    git_diff_check = if ($diffCheckExitCode -eq 0) { "pass" } else { "fail" }
    staged_file_count = $stagedChanges.Count
    claim_boundary = "Checks the current two-accelerator architecture, public docs, exact test inventory, evidence gates, source-matched implementation metadata, exact scoped physical evidence, and clone-safe packages. Operator-reported USB/LED/reset evidence is not treated as machine-verified programming identity."
}
$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "wave\final-audit-summary.json" -Encoding Ascii

Write-Host "========================================"
Write-Host "Final audit"
Write-Host ("Status: {0}" -f $summary.status)
Write-Host ("Regression: {0}/{1}" -f $summary.full_regression_total, $summary.full_regression_expected)
Write-Host ("Vivado package consistent: {0}" -f $summary.vivado_package_consistent)
Write-Host ("Vivado matches current source: {0}" -f $summary.vivado_matches_current_source)
Write-Host ("Package files: final={0}, basys3={1}, generic={2}" -f $packageFileCounts.final, $packageFileCounts.basys3, $packageFileCounts.generic)
Write-Host ("Physical validation: {0} ({1})" -f $summary.physical_validation_status, $summary.physical_validation_scope)
Write-Host "Summary: wave\final-audit-summary.json"

if ($issues.Count -ne 0) {
    foreach ($issue in $issues) {
        Write-Host "ISSUE: $issue"
    }
    throw "Final audit failed with $($issues.Count) issue(s)"
}
