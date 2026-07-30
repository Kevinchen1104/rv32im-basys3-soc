<#
Script: scripts\arch-test-run.ps1
Purpose: Builds and runs selected upstream-source architectural tests against the local CPU test flow.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\arch-test-run.ps1
Outputs:
  Generated images, simulation logs, and signature comparison artifacts under wave\arch-test.
Scope:
  Selected local arch-test integration only; not official RISC-V compliance or complete ISA proof.
Audience:
  Public optional arch-test integration entrypoint.
#>
param(
    [ValidateSet("rv32im-selected")]
    [string]$Profile = "rv32im-selected",
    [string]$ProfilePath = "",
    [int]$TimeoutCycles = 250000,
    [string]$OutputPath = "wave\arch-test-results.json",
    [string]$ToolchainBin = "",
    [string]$Prefix = "",
    [switch]$UseCachedPrograms
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
New-Item -ItemType Directory -Force -Path "wave" | Out-Null

if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $ProfilePath = "tools\arch-test\$Profile.json"
}

function Read-JsonIfPresent {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Invoke-Captured {
    param(
        [Parameter(Mandatory = $true)]
        [string]$File,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [string]$WorkingDirectory = ""
    )

    $originalLocation = (Get-Location).Path
    try {
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            Set-Location $WorkingDirectory
        }

        $toolDir = Split-Path -Parent $File
        $pathParts = @(
            $toolDir,
            "C:\msys64\ucrt64\bin",
            "C:\msys64\mingw64\bin",
            "C:\msys64\usr\bin",
            "C:\Windows\System32",
            "C:\Windows"
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
        $cleanPath = ($pathParts -join ";")
        $quotedFile = Convert-ToCmdArgument -Value $File
        $quotedArgs = @($Arguments | ForEach-Object { Convert-ToCmdArgument -Value $_ })
        $commandLine = "set ""PATH=$cleanPath"" && $quotedFile $($quotedArgs -join ' ')"

        $oldErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $output = & cmd.exe /d /s /c $commandLine 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }
        return [pscustomobject]@{
            exit_code = $exitCode
            output = (($output | ForEach-Object { $_.ToString() }) -join "`n")
        }
    } catch {
        return [pscustomobject]@{
            exit_code = 1
            output = $_.Exception.Message
        }
    } finally {
        Set-Location $originalLocation
    }
}

function Convert-ToCmdArgument {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    return '"' + ($Value.Replace('"', '\"')) + '"'
}

function Convert-ToToolPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    return $Path.Replace("\", "/")
}

function Add-TestResult {
    param(
        [System.Collections.Generic.List[object]]$List,
        [object]$Entry,
        [string]$Status,
        [string]$Reason,
        [string]$SourcePath = $null,
        [string]$WorkDir = $null,
        [string]$SignaturePath = $null,
        [int]$SignatureStartWord = 0,
        [int]$SignatureWords = 0,
        [int]$TohostWord = -1,
        [int]$TohostPassPc = -1,
        [int]$TohostFailPc = -1,
        [string]$ProgramHexPath = $null,
        [string]$DutTerminationStatus = $null,
        [string]$ReferenceKind = "none",
        [string]$ReferenceSignaturePath = $null,
        [string]$ReferenceStatusPath = $null,
        [int]$FirstMismatchIndex = -1,
        [string]$ExpectedWord = $null,
        [string]$ActualWord = $null
    )

    $List.Add([ordered]@{
        id = $Entry.id
        category = $Entry.category
        suite = $Entry.suite
        mnemonic = $Entry.mnemonic
        status = $Status
        reason = $Reason
        source_path = $SourcePath
        work_dir = $WorkDir
        program_hex_path = $ProgramHexPath
        program_image_mode = if ($UseCachedPrograms) { "cached_prebuilt" } else { "rebuilt" }
        program_hex_sha256 = if (-not [string]::IsNullOrWhiteSpace($ProgramHexPath) -and (Test-Path -LiteralPath $ProgramHexPath)) { (Get-FileHash -Algorithm SHA256 -LiteralPath $ProgramHexPath).Hash.ToLowerInvariant() } else { $null }
        dut_termination_status = $DutTerminationStatus
        dut_signature_path = $SignaturePath
        signature_start_word = $SignatureStartWord
        signature_words = $SignatureWords
        tohost_word = $TohostWord
        tohost_pass_pc = $TohostPassPc
        tohost_fail_pc = $TohostFailPc
        reference_kind = $ReferenceKind
        reference_signature_path = $ReferenceSignaturePath
        reference_status_path = $ReferenceStatusPath
        first_mismatch_index = $FirstMismatchIndex
        expected_word = $ExpectedWord
        actual_word = $ActualWord
    }) | Out-Null
}

function Resolve-ArchTestSource {
    param(
        [string]$CheckoutPath,
        [object]$Entry
    )

    foreach ($glob in @($Entry.path_globs)) {
        $normalized = $glob.Replace("/", "\")
        $pattern = Join-Path $CheckoutPath $normalized
        $matches = @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue | Sort-Object FullName)
        if ($matches.Count -ne 0) {
            return $matches[0].FullName
        }
    }

    $suiteSourceDir = Join-Path $CheckoutPath ("riscv-test-suite\" + $Entry.suite.Replace("/", "\") + "\src")
    if (Test-Path -LiteralPath $suiteSourceDir) {
        $mnemonicPattern = "^" + [regex]::Escape($Entry.mnemonic) + "(-|\.|$)"
        $fallback = @(Get-ChildItem -LiteralPath $suiteSourceDir -File -Filter "$($Entry.mnemonic)*.S" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $mnemonicPattern } |
            Sort-Object FullName)
        if ($fallback.Count -ne 0) {
            return $fallback[0].FullName
        }
    }

    $suiteLeaf = ($Entry.suite -split "/")[-1]
    if ($suiteLeaf -eq "I" -or $suiteLeaf -eq "M") {
        $modernSuiteSourceDir = Join-Path $CheckoutPath ("tests\rv32i\" + $suiteLeaf)
        if (Test-Path -LiteralPath $modernSuiteSourceDir) {
            $modernMatches = @(Get-ChildItem -LiteralPath $modernSuiteSourceDir -File -Filter "$suiteLeaf-$($Entry.mnemonic)-*.S" -ErrorAction SilentlyContinue |
                Sort-Object FullName)
            if ($modernMatches.Count -ne 0) {
                return $modernMatches[0].FullName
            }
        }
    }

    return $null
}

function Convert-BinaryToHexWords {
    param(
        [string]$BinaryPath,
        [string]$HexPath,
        [object[]]$ExecutableWordRanges = @()
    )

    [byte[]]$bytes = [System.IO.File]::ReadAllBytes($BinaryPath)
    $wordCount = [int][Math]::Ceiling($bytes.Length / 4.0)
    $lines = New-Object System.Collections.Generic.List[string]

    for ($wordIndex = 0; $wordIndex -lt $wordCount; $wordIndex++) {
        $base = $wordIndex * 4
        [uint32]$b0 = if ($base -lt $bytes.Length) { $bytes[$base] } else { 0 }
        [uint32]$b1 = if (($base + 1) -lt $bytes.Length) { $bytes[$base + 1] } else { 0 }
        [uint32]$b2 = if (($base + 2) -lt $bytes.Length) { $bytes[$base + 2] } else { 0 }
        [uint32]$b3 = if (($base + 3) -lt $bytes.Length) { $bytes[$base + 3] } else { 0 }
        [uint32]$word = $b0 -bor ($b1 -shl 8) -bor ($b2 -shl 16) -bor ($b3 -shl 24)
        if ($word -eq 0) {
            foreach ($range in $ExecutableWordRanges) {
                if ($wordIndex -ge $range.start_word -and $wordIndex -le $range.end_word) {
                    $word = 0x00000013
                    break
                }
            }
        }
        $lines.Add(("{0:x8}" -f $word)) | Out-Null
    }

    $lines | Set-Content -Path $HexPath -Encoding Ascii

    return [ordered]@{
        bytes = $bytes.Length
        words = $wordCount
    }
}

function Get-ExecutableWordRanges {
    param(
        [string]$ObjdumpPath,
        [string]$ElfPath
    )

    $ranges = [System.Collections.Generic.List[object]]::new()
    $dump = Invoke-Captured -File $ObjdumpPath -Arguments @("-h", $ElfPath)
    if ($dump.exit_code -ne 0) {
        return $ranges.ToArray()
    }

    foreach ($line in ($dump.output -split "`n")) {
        if ($line -match "^\s*\d+\s+(\S+)\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)") {
            $sectionName = $Matches[1]
            if (-not $sectionName.StartsWith(".text")) {
                continue
            }

            $sizeBytes = [Convert]::ToInt64($Matches[2], 16)
            $vma = [Convert]::ToInt64($Matches[3], 16)
            if ($sizeBytes -le 0) {
                continue
            }

            $startWord = [int][Math]::Floor($vma / 4)
            $endWord = [int][Math]::Ceiling(($vma + $sizeBytes) / 4.0) - 1
            $ranges.Add([pscustomobject]@{
                start_word = $startWord
                end_word = $endWord
                section = $sectionName
            }) | Out-Null
        }
    }

    return $ranges.ToArray()
}

function Get-SymbolAddress {
    param(
        [string]$ObjdumpPath,
        [string]$ElfPath,
        [string[]]$Names
    )

    $dump = Invoke-Captured -File $ObjdumpPath -Arguments @("-t", $ElfPath)
    if ($dump.exit_code -ne 0) {
        return $null
    }

    foreach ($line in ($dump.output -split "`n")) {
        foreach ($name in $Names) {
            $escaped = [regex]::Escape($name)
            if ($line -match "^\s*([0-9a-fA-F]+)\s+.*\s$escaped\s*$") {
                return [Convert]::ToInt64($Matches[1], 16)
            }
        }
    }

    return $null
}

function Find-ExpectedSignature {
    param([string]$SourcePath)

    $sourceDir = Split-Path -Parent $SourcePath
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($SourcePath)
    $candidateNames = @(
        "$baseName.reference_output",
        "$baseName.signature",
        "$baseName.sig",
        "$baseName.ref"
    )

    foreach ($name in $candidateNames) {
        $candidate = Join-Path $sourceDir $name
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $referenceDir = Join-Path (Split-Path -Parent $sourceDir) "references"
    if (Test-Path -LiteralPath $referenceDir) {
        foreach ($name in $candidateNames) {
            $candidate = Join-Path $referenceDir $name
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
    }

    return $null
}

function Get-OfficialReferenceSummary {
    param([object]$DetectJson)

    if ($null -eq $DetectJson -or -not ($DetectJson.PSObject.Properties.Name -contains "tools")) {
        return [ordered]@{
            available = $false
            missing = @("arch-test-detect metadata")
            reason = "official reference tools were not detected"
        }
    }

    $hasRiscofCli = ($DetectJson.tools.PSObject.Properties.Name -contains "riscof") -and $DetectJson.tools.riscof.present
    $hasRiscofModule = ($DetectJson.tools.PSObject.Properties.Name -contains "python_riscof_module") -and $DetectJson.tools.python_riscof_module.present
    $hasSpike = ($DetectJson.tools.PSObject.Properties.Name -contains "spike") -and $DetectJson.tools.spike.present
    $hasSail = ($DetectJson.tools.PSObject.Properties.Name -contains "sail") -and $DetectJson.tools.sail.present

    $missing = @()
    if (-not ($hasRiscofCli -or $hasRiscofModule)) {
        $missing += "RISCOF CLI or Python module"
    }
    if (-not ($hasSpike -or $hasSail)) {
        $missing += "Spike or Sail RISC-V simulator"
    }

    return [ordered]@{
        available = (@($missing).Count -eq 0)
        missing = @($missing)
        reason = if (@($missing).Count -eq 0) {
            "official reference tools detected; this harness still records generated local references unless an official signature flow is configured"
        } else {
            "official reference tools unavailable; falling back to the local independent RV32IM signature reference"
        }
    }
}

function Compare-Signatures {
    param(
        [string]$ExpectedPath,
        [string]$ActualPath
    )

    if (-not (Test-Path -LiteralPath $ExpectedPath)) {
        return [ordered]@{
            matched = $false
            first_mismatch_index = 0
            expected_word = $null
            actual_word = $null
            reason = "reference signature was not written"
        }
    }

    if (-not (Test-Path -LiteralPath $ActualPath)) {
        return [ordered]@{
            matched = $false
            first_mismatch_index = 0
            expected_word = $null
            actual_word = $null
            reason = "DUT signature was not written"
        }
    }

    $expectedLines = @(Get-Content -LiteralPath $ExpectedPath | ForEach-Object { $_.Trim().ToLowerInvariant() })
    $actualLines = @(Get-Content -LiteralPath $ActualPath | ForEach-Object { $_.Trim().ToLowerInvariant() })
    $limit = [Math]::Min($expectedLines.Count, $actualLines.Count)

    for ($i = 0; $i -lt $limit; $i++) {
        if ($expectedLines[$i] -ne $actualLines[$i]) {
            return [ordered]@{
                matched = $false
                first_mismatch_index = $i
                expected_word = $expectedLines[$i]
                actual_word = $actualLines[$i]
                reason = "signature word mismatch"
            }
        }
    }

    if ($expectedLines.Count -ne $actualLines.Count) {
        return [ordered]@{
            matched = $false
            first_mismatch_index = $limit
            expected_word = if ($limit -lt $expectedLines.Count) { $expectedLines[$limit] } else { $null }
            actual_word = if ($limit -lt $actualLines.Count) { $actualLines[$limit] } else { $null }
            reason = "signature length mismatch"
        }
    }

    return [ordered]@{
        matched = $true
        first_mismatch_index = -1
        expected_word = $null
        actual_word = $null
        reason = "signatures matched"
    }
}

function Get-DutTerminationStatus {
    param([string]$SimulationOutput)

    if ($SimulationOutput -match "tohost pass observed") {
        return "pass_tohost"
    }
    if ($SimulationOutput -match "tohost pass loop observed") {
        return "pass_pc"
    }
    if ($SimulationOutput -match "reported fail status") {
        return "fail"
    }
    if ($SimulationOutput -match "TIMEOUT") {
        return "timeout"
    }
    return "pass"
}

function Get-ArchTestIncludeArgs {
    param(
        [string]$CheckoutPath,
        [string]$SourcePath
    )

    $sourceDir = Split-Path -Parent $SourcePath
    $candidateDirs = @(
        (Join-Path $repoRoot "tools\arch-test\rv32im_soc"),
        $sourceDir,
        (Join-Path $CheckoutPath "tests\env"),
        (Join-Path $CheckoutPath "riscv-test-env"),
        (Join-Path $CheckoutPath "riscv-test-env\p"),
        (Join-Path $CheckoutPath "riscv-test-env\v"),
        (Join-Path $CheckoutPath "riscv-test-suite\env"),
        (Join-Path $CheckoutPath "riscv-test-suite\rv32i_m\env"),
        (Join-Path $CheckoutPath "riscv-test-suite\rv32i_m\I\env"),
        (Join-Path $CheckoutPath "riscv-test-suite\rv32i_m\M\env"),
        (Join-Path $CheckoutPath "env"),
        (Join-Path $CheckoutPath "macros")
    )

    $args = New-Object System.Collections.Generic.List[string]
    foreach ($dir in $candidateDirs) {
        if (Test-Path -LiteralPath $dir) {
            $args.Add("-I") | Out-Null
            $args.Add($dir) | Out-Null
        }
    }

    return @($args)
}

function Get-RtlSources {
    return @(
        "rtl/core/execute/riscv_alu.v",
        "rtl/core/execute/rv32m_multicycle_unit.v",
        "rtl/core/frontend/branch_predictor.v",
        "rtl/core/pipeline/hazard_unit.v",
        "rtl/core/pipeline/forwarding_unit.v",
        "rtl/core/execute/branch_jump_unit.v",
        "rtl/memory/load_store_format_unit.v",
        "rtl/core/pipeline/pipeline_control_unit.v",
        "rtl/core/csr/csr_unit.v",
        "rtl/core/csr/exception_decode_unit.v",
        "rtl/core/csr/trap_redirect_control_unit.v",
        "rtl/soc/perf/performance_counter_unit.v",
        "rtl/core/frontend/ras_unit.v",
        "rtl/memory/cache/icache_unit.v",
        "rtl/memory/cache/dcache_unit.v",
        "rtl/soc/mmio/mmio_decode.v",
        "rtl/soc/mmio/mmio_read_mux.v",
        "rtl/accelerators/matvec/int8_matvec_scratchpad_accelerator.v",
        "rtl/accelerators/matvec/int8_matvec_dma_lite.v",
        "rtl/peripherals/timer/machine_timer.v",
        "rtl/core/riscv_cpu_core.v",
        "rtl/memory/bram/external_dmem_bram.v",
        "rtl/boot/uart/boot_reset_controller.v",
        "rtl/peripherals/uart/uart_tx.v",
        "rtl/peripherals/uart/uart_rx.v",
        "rtl/peripherals/uart/uart_rx_mmio_buffer.v",
        "rtl/boot/uart/uart_packet_boot_imem.v",
        "rtl/boot/uart/uart_serial_packet_boot_imem.v",
        "rtl/top/generic/riscv_cpu_fpga_top.v",
        "rtl/top/soc/riscv_cpu_uart_boot_fpga_top.v",
        "rtl/top/soc/riscv_cpu_uart_boot_bram_soc_top.v",
        "rtl/top/soc/riscv_cpu_uart_boot_runtime_soc_top.v",
        "rtl/top/generic/riscv_cpu_fpga_debug_led_top.v"
    )
}

function Write-Results {
    param(
        [object]$ProfileJson,
        [object]$DetectJson,
        [object]$SetupJson,
        [System.Collections.Generic.List[object]]$Rows
    )

    $statusValues = @(
        "passed_official_reference",
        "passed_local_reference",
        "failed_signature",
        "failed",
        "unsupported",
        "blocked_no_tool",
        "blocked_no_reference",
        "build_failed",
        "timeout"
    )
    $totals = [ordered]@{}
    foreach ($statusName in $statusValues) {
        $totals[$statusName] = @($Rows | Where-Object { $_.status -eq $statusName }).Count
    }

    $attempted = @($Rows | Where-Object {
        $_.status -ne "unsupported" -and $_.status -ne "blocked_no_tool"
    }).Count

    $passedCount = $totals.passed_official_reference + $totals.passed_local_reference
    $officialReference = Get-OfficialReferenceSummary -DetectJson $DetectJson
    $localReferenceRows = @($Rows | Where-Object { $_.reference_kind -eq "local" })

    $overallStatus = "complete"
    if ($totals.failed_signature -ne 0 -or $totals.failed -ne 0 -or $totals.timeout -ne 0 -or $totals.build_failed -ne 0) {
        $overallStatus = "issues"
    } elseif ($totals.blocked_no_tool -ne 0 -and $attempted -eq 0) {
        $overallStatus = "blocked_no_tool"
    } elseif ($totals.blocked_no_reference -ne 0 -and $passedCount -eq 0) {
        $overallStatus = "blocked_no_reference"
    }

    $summary = [ordered]@{
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        status = $overallStatus
        profile = $ProfileJson.name
        profile_path = $ProfilePath
        upstream_repo = $ProfileJson.upstream.repo
        upstream_commit = if ($null -eq $SetupJson) { $null } else { $SetupJson.upstream_commit }
        detection_status = if ($null -eq $DetectJson) { $null } else { $DetectJson.status }
        setup_status = if ($null -eq $SetupJson) { $null } else { $SetupJson.status }
        program_image_mode = if ($UseCachedPrograms) { "cached_prebuilt" } else { "rebuilt" }
        program_image_claim_boundary = if ($UseCachedPrograms) {
            "Prebuilt ELF/BIN/HEX images from the pinned upstream checkout were reused because local policy blocked GCC; the current RTL and arch-test harness were still recompiled and every DUT simulation and local-reference comparison was rerun."
        } else {
            "Program images, the current RTL, and the arch-test harness were rebuilt for this run."
        }
        toolchain = if ($null -eq $DetectJson) { $null } else {
            [ordered]@{
                prefix = if ($DetectJson.PSObject.Properties.Name -contains "toolchain") { $DetectJson.toolchain.prefix } else { $null }
                requested_bin = if ($DetectJson.PSObject.Properties.Name -contains "toolchain") { $DetectJson.toolchain.requested_bin } else { $null }
                gcc = $DetectJson.tools.riscv_gcc
                objcopy = $DetectJson.tools.riscv_objcopy
                objdump = $DetectJson.tools.riscv_objdump
            }
        }
        reference_summary = [ordered]@{
            official = $officialReference
            local = [ordered]@{
                script = "tools/arch-test/rv32im_signature_ref.py"
                used_tests = @($localReferenceRows).Count
                passed_tests = $totals.passed_local_reference
                claim_boundary = "local independent RV32IM signature reference only; not an official compliance result"
            }
        }
        selected_tests = @($ProfileJson.tests).Count
        attempted_tests = $attempted
        totals = $totals
        claim_boundary = "selected official RISC-V arch-test sources; PASS is split by official or local reference kind and is not an official compliance result unless passed_official_reference is nonzero"
        tests = @($Rows)
    }

    $summary | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputPath -Encoding Ascii

    Write-Host "========================================"
    Write-Host "RISC-V arch-test selected profile run"
    Write-Host ("Status: {0}" -f $summary.status)
    Write-Host ("Profile: {0}" -f $summary.profile)
    Write-Host ("Upstream commit: {0}" -f $summary.upstream_commit)
    foreach ($statusName in $statusValues) {
        Write-Host ("{0}: {1}" -f $statusName, $totals[$statusName])
    }
    Write-Host ("Results written to {0}" -f $OutputPath)
}

if (-not (Test-Path -LiteralPath $ProfilePath)) {
    throw "Arch-test profile not found: $ProfilePath"
}

$profileJson = Read-JsonIfPresent $ProfilePath
$detectJson = Read-JsonIfPresent "wave\arch-test-detect.json"
$setupJson = Read-JsonIfPresent "wave\arch-test-setup.json"
$rows = [System.Collections.Generic.List[object]]::new()

if ($null -eq $detectJson -or -not [string]::IsNullOrWhiteSpace($ToolchainBin) -or -not [string]::IsNullOrWhiteSpace($Prefix)) {
    $detectArgs = @{}
    if (-not [string]::IsNullOrWhiteSpace($ToolchainBin)) {
        $detectArgs.ToolchainBin = $ToolchainBin
    }
    if (-not [string]::IsNullOrWhiteSpace($Prefix)) {
        $detectArgs.Prefix = $Prefix
    }
    & (Join-Path $PSScriptRoot "arch-test-detect.ps1") @detectArgs | Out-Host
    $detectJson = Read-JsonIfPresent "wave\arch-test-detect.json"
}

$requiredMissing = if ($null -eq $detectJson) { @("arch-test-detect failed") } else { @($detectJson.required_missing) }

if (@($requiredMissing).Count -ne 0) {
    foreach ($entry in @($profileJson.tests)) {
        Add-TestResult -List $rows -Entry $entry -Status "blocked_no_tool" -Reason ("missing required tools: " + (@($requiredMissing) -join ", "))
    }
    Write-Results -ProfileJson $profileJson -DetectJson $detectJson -SetupJson $setupJson -Rows $rows
    exit 0
}

if ($null -eq $setupJson -or $setupJson.status -ne "ready") {
    $reason = if ($null -eq $setupJson) {
        "riscv-arch-test checkout is not set up; run scripts\arch-test-setup.ps1"
    } else {
        $setupJson.reason
    }

    foreach ($entry in @($profileJson.tests)) {
        Add-TestResult -List $rows -Entry $entry -Status "blocked_no_tool" -Reason $reason
    }
    Write-Results -ProfileJson $profileJson -DetectJson $detectJson -SetupJson $setupJson -Rows $rows
    exit 0
}

$toolPaths = [ordered]@{
    python = $detectJson.tools.python.path
    gcc = $detectJson.tools.riscv_gcc.path
    objcopy = $detectJson.tools.riscv_objcopy.path
    objdump = $detectJson.tools.riscv_objdump.path
    iverilog = $detectJson.tools.iverilog.path
    vvp = $detectJson.tools.vvp.path
}

$checkoutPath = Join-Path $repoRoot $profileJson.upstream.checkout
$linkerScript = Join-Path $repoRoot "tools\arch-test\arch-test.ld"
$localReferenceScript = Join-Path $repoRoot "tools\arch-test\rv32im_signature_ref.py"
$profileWorkRoot = Join-Path $repoRoot ("wave\arch-test\" + $profileJson.name)
New-Item -ItemType Directory -Force -Path $profileWorkRoot | Out-Null

foreach ($entry in @($profileJson.tests)) {
    Write-Host "========================================"
    Write-Host ("Arch-test selected case: {0}" -f $entry.id)

    $sourcePath = Resolve-ArchTestSource -CheckoutPath $checkoutPath -Entry $entry
    if ([string]::IsNullOrWhiteSpace($sourcePath)) {
        Add-TestResult -List $rows -Entry $entry -Status "unsupported" -Reason "selected official source was not found in this riscv-arch-test checkout"
        continue
    }

    $caseWorkDir = Join-Path $profileWorkRoot $entry.id
    New-Item -ItemType Directory -Force -Path $caseWorkDir | Out-Null

    $elfPath = Join-Path $caseWorkDir "$($entry.id).elf"
    $binPath = Join-Path $caseWorkDir "$($entry.id).bin"
    $hexPath = Join-Path $caseWorkDir "$($entry.id).hex"
    $signaturePath = Join-Path $caseWorkDir "$($entry.id).dut_signature.hex"
    $referenceSignaturePath = Join-Path $caseWorkDir "$($entry.id).local_reference.hex"
    $referenceStatusPath = Join-Path $caseWorkDir "$($entry.id).local_reference.json"
    $vvpPath = Join-Path $caseWorkDir "$($entry.id).vvp"

    if ($UseCachedPrograms) {
        $missingCachedArtifacts = @($elfPath, $binPath, $hexPath) | Where-Object { -not (Test-Path -LiteralPath $_) }
        if ($missingCachedArtifacts.Count -ne 0) {
            Add-TestResult -List $rows -Entry $entry -Status "build_failed" -Reason ("cached program artifacts missing: " + ($missingCachedArtifacts -join ", ")) -SourcePath $sourcePath -WorkDir $caseWorkDir
            continue
        }

        $imageInfo = [pscustomobject]@{
            words = @(Get-Content -LiteralPath $hexPath).Count
        }
    } else {
        $gccArgs = New-Object System.Collections.Generic.List[string]
        $gccArgs.Add("-march=$($profileJson.target.march)") | Out-Null
        $gccArgs.Add("-mabi=$($profileJson.target.mabi)") | Out-Null
        $gccArgs.Add("-nostdlib") | Out-Null
        $gccArgs.Add("-nostartfiles") | Out-Null
        $gccArgs.Add("-Wl,--no-relax") | Out-Null
        $gccArgs.Add("-Wl,--build-id=none") | Out-Null
        $gccArgs.Add("-T") | Out-Null
        $gccArgs.Add($linkerScript) | Out-Null
        $gccArgs.Add("-DXLEN=32") | Out-Null
        foreach ($includeArg in Get-ArchTestIncludeArgs -CheckoutPath $checkoutPath -SourcePath $sourcePath) {
            $gccArgs.Add($includeArg) | Out-Null
        }
        $gccArgs.Add($sourcePath) | Out-Null
        $gccArgs.Add("-o") | Out-Null
        $gccArgs.Add($elfPath) | Out-Null

        $build = Invoke-Captured -File $toolPaths.gcc -Arguments ($gccArgs.ToArray())
        if ($build.exit_code -ne 0) {
            $buildLog = Join-Path $caseWorkDir "build.log"
            $build.output | Set-Content -Path $buildLog -Encoding Ascii
            Add-TestResult -List $rows -Entry $entry -Status "build_failed" -Reason "riscv gcc build failed; see build.log" -SourcePath $sourcePath -WorkDir $caseWorkDir
            continue
        }

        $objcopy = Invoke-Captured -File $toolPaths.objcopy -Arguments @("-O", "binary", $elfPath, $binPath)
        if ($objcopy.exit_code -ne 0) {
            $objcopy.output | Set-Content -Path (Join-Path $caseWorkDir "objcopy.log") -Encoding Ascii
            Add-TestResult -List $rows -Entry $entry -Status "build_failed" -Reason "objcopy to binary failed; see objcopy.log" -SourcePath $sourcePath -WorkDir $caseWorkDir
            continue
        }

        $executableWordRanges = Get-ExecutableWordRanges -ObjdumpPath $toolPaths.objdump -ElfPath $elfPath
        $imageInfo = Convert-BinaryToHexWords -BinaryPath $binPath -HexPath $hexPath -ExecutableWordRanges $executableWordRanges
    }
    if ($imageInfo.words -le 0 -or $imageInfo.words -gt [int]$profileJson.target.memory_words) {
        Add-TestResult -List $rows -Entry $entry -Status "unsupported" -Reason ("program image uses {0} words, beyond current {1}-word CPU harness memory" -f $imageInfo.words, $profileJson.target.memory_words) -SourcePath $sourcePath -WorkDir $caseWorkDir
        continue
    }

    $beginSignature = Get-SymbolAddress -ObjdumpPath $toolPaths.objdump -ElfPath $elfPath -Names @("begin_signature", "rvtest_signature_begin", "signature_start")
    $endSignature = Get-SymbolAddress -ObjdumpPath $toolPaths.objdump -ElfPath $elfPath -Names @("end_signature", "rvtest_signature_end", "signature_end")
    $tohostAddress = Get-SymbolAddress -ObjdumpPath $toolPaths.objdump -ElfPath $elfPath -Names @("tohost")
    $tohostPassPcAddress = Get-SymbolAddress -ObjdumpPath $toolPaths.objdump -ElfPath $elfPath -Names @("write_tohost_pass")
    $tohostFailPcAddress = Get-SymbolAddress -ObjdumpPath $toolPaths.objdump -ElfPath $elfPath -Names @("write_tohost_fail")
    $signatureStartWord = 0
    $signatureWords = 0
    $tohostWord = -1
    $tohostPassPc = -1
    $tohostFailPc = -1
    if ($null -ne $beginSignature -and $null -ne $endSignature -and $endSignature -gt $beginSignature) {
        $signatureStartWord = [int][Math]::Floor($beginSignature / 4)
        $signatureWords = [int][Math]::Ceiling(($endSignature - $beginSignature) / 4.0)
    }

    if ($null -ne $tohostAddress) {
        $tohostWord = [int][Math]::Floor($tohostAddress / 4)
    }
    if ($null -ne $tohostPassPcAddress) {
        $tohostPassPc = [int]$tohostPassPcAddress
    }
    if ($null -ne $tohostFailPcAddress) {
        $tohostFailPc = [int]$tohostFailPcAddress
    }

    if ($signatureStartWord -lt 0 -or ($signatureStartWord + $signatureWords) -gt [int]$profileJson.target.memory_words) {
        Add-TestResult -List $rows -Entry $entry -Status "unsupported" -Reason "signature range is outside the current CPU harness memory" -SourcePath $sourcePath -WorkDir $caseWorkDir -SignatureStartWord $signatureStartWord -SignatureWords $signatureWords -TohostWord $tohostWord -TohostPassPc $tohostPassPc -TohostFailPc $tohostFailPc
        continue
    }

    if ($tohostWord -ge [int]$profileJson.target.memory_words) {
        Add-TestResult -List $rows -Entry $entry -Status "unsupported" -Reason "tohost termination word is outside the current CPU harness memory" -SourcePath $sourcePath -WorkDir $caseWorkDir -SignatureStartWord $signatureStartWord -SignatureWords $signatureWords -TohostWord $tohostWord -TohostPassPc $tohostPassPc -TohostFailPc $tohostFailPc
        continue
    }

    $compileArgs = New-Object System.Collections.Generic.List[string]
    $compileArgs.Add("-g2012") | Out-Null
    $compileArgs.Add("-Wall") | Out-Null
    $compileArgs.Add("-I") | Out-Null
    $compileArgs.Add("tb") | Out-Null
    $compileArgs.Add("-o") | Out-Null
    $compileArgs.Add($vvpPath) | Out-Null
    foreach ($source in Get-RtlSources) {
        $compileArgs.Add($source) | Out-Null
    }
    $compileArgs.Add("tb/reference/tb_arch_test_signature.v") | Out-Null

    $compile = Invoke-Captured -File $toolPaths.iverilog -Arguments ($compileArgs.ToArray()) -WorkingDirectory $repoRoot
    if ($compile.exit_code -ne 0) {
        $compile.output | Set-Content -Path (Join-Path $caseWorkDir "iverilog.log") -Encoding Ascii
        Add-TestResult -List $rows -Entry $entry -Status "build_failed" -Reason "Icarus compile failed; see iverilog.log" -SourcePath $sourcePath -WorkDir $caseWorkDir -SignatureStartWord $signatureStartWord -SignatureWords $signatureWords
        continue
    }

    $vvpArgs = New-Object System.Collections.Generic.List[string]
    $vvpArgs.Add($vvpPath) | Out-Null
    $vvpArgs.Add("+test_name=$($entry.id)") | Out-Null
    $vvpArgs.Add("+program_hex=$(Convert-ToToolPath $hexPath)") | Out-Null
    $vvpArgs.Add("+signature_start=$signatureStartWord") | Out-Null
    $vvpArgs.Add("+signature_words=$signatureWords") | Out-Null
    if ($tohostWord -ge 0) {
        $vvpArgs.Add("+tohost_word=$tohostWord") | Out-Null
    }
    if ($tohostPassPc -ge 0) {
        $vvpArgs.Add("+tohost_pass_pc=$tohostPassPc") | Out-Null
    }
    if ($tohostFailPc -ge 0) {
        $vvpArgs.Add("+tohost_fail_pc=$tohostFailPc") | Out-Null
    }
    $vvpArgs.Add("+dut_signature=$(Convert-ToToolPath $signaturePath)") | Out-Null
    $vvpArgs.Add("+timeout_cycles=$TimeoutCycles") | Out-Null
    $simulation = Invoke-Captured -File $toolPaths.vvp -Arguments ($vvpArgs.ToArray()) -WorkingDirectory $repoRoot
    $simulation.output | Set-Content -Path (Join-Path $caseWorkDir "simulation.log") -Encoding Ascii

    if ($simulation.exit_code -ne 0) {
        $status = if ($simulation.output -match "timeout|TIMEOUT") { "timeout" } else { "failed" }
        Add-TestResult -List $rows -Entry $entry -Status $status -Reason "DUT signature simulation failed; see simulation.log" -SourcePath $sourcePath -WorkDir $caseWorkDir -ProgramHexPath $hexPath -SignaturePath $signaturePath -SignatureStartWord $signatureStartWord -SignatureWords $signatureWords -TohostWord $tohostWord -TohostPassPc $tohostPassPc -TohostFailPc $tohostFailPc -DutTerminationStatus (Get-DutTerminationStatus -SimulationOutput $simulation.output)
        continue
    }

    $dutTerminationStatus = Get-DutTerminationStatus -SimulationOutput $simulation.output

    if (-not (Test-Path -LiteralPath $localReferenceScript)) {
        Add-TestResult -List $rows -Entry $entry -Status "blocked_no_reference" -Reason "local RV32IM signature reference script is missing" -SourcePath $sourcePath -WorkDir $caseWorkDir -ProgramHexPath $hexPath -SignaturePath $signaturePath -SignatureStartWord $signatureStartWord -SignatureWords $signatureWords -TohostWord $tohostWord -TohostPassPc $tohostPassPc -TohostFailPc $tohostFailPc -DutTerminationStatus $dutTerminationStatus
        continue
    }

    $referenceArgs = @(
        $localReferenceScript,
        "--program-hex", $hexPath,
        "--signature-start-word", ([string]$signatureStartWord),
        "--signature-words", ([string]$signatureWords),
        "--tohost-word", ([string]$tohostWord),
        "--tohost-pass-pc", ([string]$tohostPassPc),
        "--tohost-fail-pc", ([string]$tohostFailPc),
        "--memory-words", ([string]$profileJson.target.memory_words),
        "--max-cycles", ([string]$TimeoutCycles),
        "--output-signature", $referenceSignaturePath,
        "--output-json", $referenceStatusPath
    )

    $reference = Invoke-Captured -File $toolPaths.python -Arguments $referenceArgs -WorkingDirectory $repoRoot
    $reference.output | Set-Content -Path (Join-Path $caseWorkDir "local_reference.log") -Encoding Ascii
    $referenceJson = Read-JsonIfPresent $referenceStatusPath

    if ($reference.exit_code -ne 0) {
        $referenceStatus = if ($null -eq $referenceJson) { $null } else { $referenceJson.status }
        $referenceReason = if ($null -eq $referenceJson) { "local reference failed before writing status JSON" } else { $referenceJson.reason }
        $status = switch ($referenceStatus) {
            "unsupported" { "unsupported" }
            "timeout" { "timeout" }
            default { "failed_signature" }
        }
        Add-TestResult -List $rows -Entry $entry -Status $status -Reason ("local reference did not produce a pass signature: {0}" -f $referenceReason) -SourcePath $sourcePath -WorkDir $caseWorkDir -ProgramHexPath $hexPath -SignaturePath $signaturePath -SignatureStartWord $signatureStartWord -SignatureWords $signatureWords -TohostWord $tohostWord -TohostPassPc $tohostPassPc -TohostFailPc $tohostFailPc -DutTerminationStatus $dutTerminationStatus -ReferenceKind "local" -ReferenceSignaturePath $referenceSignaturePath -ReferenceStatusPath $referenceStatusPath
        continue
    }

    $comparison = Compare-Signatures -ExpectedPath $referenceSignaturePath -ActualPath $signaturePath
    if ($comparison.matched) {
        Add-TestResult -List $rows -Entry $entry -Status "passed_local_reference" -Reason "DUT signature matched the local independent RV32IM reference signature" -SourcePath $sourcePath -WorkDir $caseWorkDir -ProgramHexPath $hexPath -SignaturePath $signaturePath -SignatureStartWord $signatureStartWord -SignatureWords $signatureWords -TohostWord $tohostWord -TohostPassPc $tohostPassPc -TohostFailPc $tohostFailPc -DutTerminationStatus $dutTerminationStatus -ReferenceKind "local" -ReferenceSignaturePath $referenceSignaturePath -ReferenceStatusPath $referenceStatusPath
    } else {
        Add-TestResult -List $rows -Entry $entry -Status "failed_signature" -Reason $comparison.reason -SourcePath $sourcePath -WorkDir $caseWorkDir -ProgramHexPath $hexPath -SignaturePath $signaturePath -SignatureStartWord $signatureStartWord -SignatureWords $signatureWords -TohostWord $tohostWord -TohostPassPc $tohostPassPc -TohostFailPc $tohostFailPc -DutTerminationStatus $dutTerminationStatus -ReferenceKind "local" -ReferenceSignaturePath $referenceSignaturePath -ReferenceStatusPath $referenceStatusPath -FirstMismatchIndex $comparison.first_mismatch_index -ExpectedWord $comparison.expected_word -ActualWord $comparison.actual_word
    }
}

Write-Results -ProfileJson $profileJson -DetectJson $detectJson -SetupJson $setupJson -Rows $rows
