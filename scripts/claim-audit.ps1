<#
Script: scripts\claim-audit.ps1
Purpose: Scans project documentation for wording that could overstate verification claims.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\claim-audit.ps1
Outputs:
  Console claim-audit report.
Scope:
  Documentation wording audit only; not hardware evidence or legal certification.
Audience:
  Public release audit check.
#>
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. "$PSScriptRoot\verification-source-identity.ps1"

New-Item -ItemType Directory -Force -Path "wave" | Out-Null

function Get-RepoRelativePath {
    param([string] $Path)

    $resolved = Resolve-Path -LiteralPath $Path
    $basePath = $repoRoot.Path
    if (-not $basePath.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $basePath += [System.IO.Path]::DirectorySeparatorChar
    }

    $baseUri = [System.Uri]::new($basePath)
    $pathUri = [System.Uri]::new($resolved.Path)
    return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($pathUri).ToString()).Replace("/", "\")
}

function Get-ClaimClause {
    param(
        [string] $Line,
        [int] $MatchIndex
    )

    $start = 0
    $end = $Line.Length
    # Treat additive/contrast conjunctions as new claim clauses. Negation does
    # not automatically carry across "and this core is ..." or similar text.
    foreach ($delimiter in [regex]::Matches(
        $Line,
        "(?i)[;.!?]|\b(?:and|but|yet|while|whereas)\b"
    )) {
        if ($delimiter.Index -lt $MatchIndex) {
            $start = $delimiter.Index + $delimiter.Length
        } else {
            $end = $delimiter.Index
            break
        }
    }

    return $Line.Substring($start, $end - $start)
}

function Test-AllowedContext {
    param(
        [string] $Line,
        [string] $Context,
        [int] $MatchIndex,
        [bool] $InNonClaimArray = $false
    )

    if ($InNonClaimArray) {
        return $true
    }

    $structuredLineAllowPatterns = @(
        "(?i)\bnon-claims?\b",
        "(?i)`"(?:boundary|claim_boundary)`"\s*:",
        "(?i)\b(?:not_run|not_applicable|needs_revalidation|blocked_no_vivado|blocked_no_tool)\b",
        "(?i)^\s*Timing closure:\s*met\.?\s*$"
    )

    foreach ($pattern in $structuredLineAllowPatterns) {
        if ($Line -match $pattern) {
            return $true
        }
    }

    $claimClause = Get-ClaimClause -Line $Line -MatchIndex $MatchIndex
    foreach ($pattern in @(
        "(?i)\b(?:no|not|never|without)\b",
        "(?i)\b(?:only claimed if|only if|until|unless)\b"
    )) {
        if ($claimClause -match $pattern) {
            return $true
        }
    }

    # A lowercase Markdown continuation may inherit a negation only from the
    # immediately preceding unfinished line. Completed sentences never carry
    # their negation into the next line.
    $trimmedLine = $Line.TrimStart()
    $isWrappedContinuation = $trimmedLine -cmatch "^[a-z]"
    $contextLines = @($Context -split "\r?\n")
    if ($isWrappedContinuation -and $contextLines.Count -ge 2) {
        $previousLine = $contextLines[$contextLines.Count - 2].TrimEnd()
        if ($previousLine -ne "" -and $previousLine -notmatch "[.!?;:]\s*$") {
            $unfinishedLines = @()
            for ($i = $contextLines.Count - 2; $i -ge 0; $i--) {
                $candidate = $contextLines[$i].TrimEnd()
                if ($candidate -eq "" -or $candidate -match "[.!?;:]\s*$") {
                    break
                }
                $unfinishedLines = @($candidate) + $unfinishedLines
            }
            if (($unfinishedLines -join " ") -match
                "(?i)\b(?:no|not|never|without)\b") {
                return $true
            }
        }
    }

    return $false
}

$policyTests = @(
    @{
        name = "unqualified positive claim"
        line = "This core is RISC-V compliant."
        context = "This core is RISC-V compliant."
        match_text = "RISC-V compliant"
        in_non_claim_array = $false
        expected = $false
    },
    @{
        name = "explicit same-line negation"
        line = "This core is not RISC-V compliant."
        context = "This core is not RISC-V compliant."
        match_text = "RISC-V compliant"
        in_non_claim_array = $false
        expected = $true
    },
    @{
        name = "unrelated nearby negation"
        line = "This core is RISC-V compliant."
        context = "This is not a benchmark.`nThis core is RISC-V compliant."
        match_text = "RISC-V compliant"
        in_non_claim_array = $false
        expected = $false
    },
    @{
        name = "same-line unrelated negation"
        line = "This is not a benchmark; this core is RISC-V compliant."
        context = "This is not a benchmark; this core is RISC-V compliant."
        match_text = "RISC-V compliant"
        in_non_claim_array = $false
        expected = $false
    },
    @{
        name = "same-clause conjunction negation"
        line = "This is not a benchmark and this core is RISC-V compliant."
        context = "This is not a benchmark and this core is RISC-V compliant."
        match_text = "RISC-V compliant"
        in_non_claim_array = $false
        expected = $false
    },
    @{
        name = "wrapped non-claim continuation"
        line = "multi-seed timing closure or timing signoff."
        context = "It is not official compliance, robust timing, or`nmulti-seed timing closure or timing signoff."
        match_text = "timing closure"
        in_non_claim_array = $false
        expected = $true
    },
    @{
        name = "lowercase claim after completed non-claim"
        line = "this core is RISC-V compliant."
        context = "This is not a benchmark.`nthis core is RISC-V compliant."
        match_text = "RISC-V compliant"
        in_non_claim_array = $false
        expected = $false
    },
    @{
        name = "legacy safe-wording label"
        line = "This core is RISC-V compliant."
        context = "Safe wording:`nThis core is RISC-V compliant."
        match_text = "RISC-V compliant"
        in_non_claim_array = $false
        expected = $false
    },
    @{
        name = "structured non-claim array"
        line = '"official RISC-V compliance",'
        context = '"official RISC-V compliance",'
        match_text = "official RISC-V compliance"
        in_non_claim_array = $true
        expected = $true
    },
    @{
        name = "evidence-backed generated timing status"
        line = "Timing closure: met."
        context = "Timing closure: met."
        match_text = "Timing closure"
        in_non_claim_array = $false
        expected = $true
    }
)

foreach ($test in $policyTests) {
    $matchIndex = $test.line.IndexOf(
        $test.match_text,
        [System.StringComparison]::OrdinalIgnoreCase
    )
    if ($matchIndex -lt 0) {
        throw "Claim-audit policy self-test has no match text: $($test.name)"
    }
    $actual = Test-AllowedContext `
        -Line $test.line `
        -Context $test.context `
        -MatchIndex $matchIndex `
        -InNonClaimArray $test.in_non_claim_array
    if ($actual -ne $test.expected) {
        throw "Claim-audit policy self-test failed: $($test.name)"
    }
}

$riskPatterns = @(
    @{ label = "official compliance"; regex = "(?i)official\s+RISC-V\s+compliance|passes\s+official\s+RISC-V\s+compliance|RISC-V\s+compliant|official\s+architectural\s+compliance\s+result|passed\s+official\s+arch-test\s+reference" },
    @{ label = "full ISA compliance"; regex = "(?i)full\s+RV32IM\s+compliance|full\s+RISC-V\s+compliance|complete\s+RV32IM\s+coverage|full\s+RV32\s+compliance" },
    @{ label = "full privileged architecture"; regex = "(?i)full\s+privileged|complete\s+privileged|full\s+CLINT|full\s+PLIC|Linux[-/ ]?RTOS|Linux[- ]?ready|Linux[- ]?capable|RTOS[- ]?ready" },
    @{ label = "board validation"; regex = "(?i)board-proven|FPGA-proven|Basys3-proven|physical\s+FPGA\s+validation|physical\s+board\s+validation|board\s+validation\s+(passed|complete|done)|board-tested|physically\s+validated" },
    @{ label = "timing signoff"; regex = "(?i)timing-closed|timing\s+closure|timing\s+signoff|maximum-frequency|maximum\s+frequency|area\s+signoff|bitstream\s+signoff" },
    @{ label = "production SoC or accelerator"; regex = "(?i)production\s+SoC|production\s+UART|production\s+AI\s+accelerator|production\s+NPU|production\s+DMA|tensor\s+core|systolic\s+array" },
    @{ label = "coherence"; regex = "(?i)cache-coherent|cache\s+coherent|coherent\s+DMA" },
    @{ label = "performance benchmark"; regex = "(?i)\bspeedup\b|\bthroughput\b|\bbenchmark\b|\bCPI\b" }
)

$stalePatterns = @(
    @{ label = "old regression count"; regex = "(?i)147\s+passed|152\s+passed" },
    @{ label = "obsolete MATVEC Scratchpad absence"; regex = "(?i)MATVEC\s+scratchpad\s+does\s+not\s+exist|no\s+external\s+DMEM|no\s+DMA-like\s+accelerator" }
)

$scanItems = @(
    "README.md",
    "docs",
    "formal\README.md",
    "fpga\boards",
    "release\final",
    "release\fpga",
    "scripts\README.md",
    ".github\workflows"
)

$files = [System.Collections.Generic.List[object]]::new()
foreach ($item in $scanItems) {
    if (-not (Test-Path -LiteralPath $item)) {
        continue
    }

    $resolvedItem = Resolve-Path -LiteralPath $item
    if ((Get-Item -LiteralPath $resolvedItem).PSIsContainer) {
        Get-ChildItem -LiteralPath $resolvedItem -Recurse -File |
            Where-Object { $_.FullName -notmatch "\\release\\final\\docs\\" } |
            Where-Object { $_.Extension -in @(".md", ".json", ".yml", ".yaml") } |
            ForEach-Object { $files.Add($_) | Out-Null }
    } else {
        $files.Add((Get-Item -LiteralPath $resolvedItem)) | Out-Null
    }
}

$suspiciousMatches = [System.Collections.Generic.List[object]]::new()
$allowedMatches = [System.Collections.Generic.List[object]]::new()
$staleMatches = [System.Collections.Generic.List[object]]::new()

foreach ($file in ($files | Sort-Object FullName -Unique)) {
    $relative = Get-RepoRelativePath $file.FullName
    $lines = @(Get-Content -LiteralPath $file.FullName)
    $nonClaimArrayDepth = 0

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $opens = ([regex]::Matches($line, "\[")).Count
        $closes = ([regex]::Matches($line, "\]")).Count
        $startsNonClaimArray = $nonClaimArrayDepth -eq 0 -and
            $line -match '(?i)"non_claims"\s*:\s*\['
        $inNonClaimArray = $nonClaimArrayDepth -gt 0 -or $startsNonClaimArray

        if ($startsNonClaimArray) {
            $nonClaimArrayDepth = $opens - $closes
        } elseif ($nonClaimArrayDepth -gt 0) {
            $nonClaimArrayDepth += $opens - $closes
        }

        $contextStart = [Math]::Max(0, $i - 2)
        $contextEnd = $i
        $contextLines = @()
        for ($j = $contextStart; $j -le $contextEnd; $j++) {
            $contextLines += $lines[$j]
        }
        $context = ($contextLines -join "`n")

        foreach ($pattern in $riskPatterns) {
            foreach ($riskMatch in [regex]::Matches($line, $pattern.regex)) {
                $entry = [ordered]@{
                    file = $relative
                    line = $i + 1
                    category = $pattern.label
                    matched_text = $riskMatch.Value
                    text = $line.Trim()
                }

                if (Test-AllowedContext `
                    -Line $line `
                    -Context $context `
                    -MatchIndex $riskMatch.Index `
                    -InNonClaimArray $inNonClaimArray) {
                    $allowedMatches.Add($entry) | Out-Null
                } else {
                    $suspiciousMatches.Add($entry) | Out-Null
                }
            }
        }

        foreach ($pattern in $stalePatterns) {
            if ($line -match $pattern.regex) {
                $staleMatches.Add([ordered]@{
                    file = $relative
                    line = $i + 1
                    category = $pattern.label
                    text = $line.Trim()
                }) | Out-Null
            }
        }
    }
}

$status = if ($suspiciousMatches.Count -eq 0 -and $staleMatches.Count -eq 0) { "pass" } else { "fail" }

$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = $status
    scanned_files = @($files | Sort-Object FullName -Unique).Count
    allowed_risky_language = $allowedMatches.Count
    suspicious_matches = $suspiciousMatches.ToArray()
    stale_matches = $staleMatches.ToArray()
    stale_match_count = $staleMatches.Count
    policy = [ordered]@{
        context_lines_before = 2
        context_lines_after = 0
        structured_non_claim_arrays = $true
        self_tests = $policyTests.Count
    }
    boundary = "Claim audit checks README, docs, release package metadata, and workflow text for unsafe public wording. Allowed matches require same-line or tightly wrapped negation, an explicit boundary field, a structured non_claims array, or an evidence-backed generated status line."
}
Add-DocumentationIdentityFields -Summary $summary | Out-Null

$summary | ConvertTo-Json -Depth 6 | Set-Content -Path "wave\claim-audit-summary.json" -Encoding Ascii

Write-Host "========================================"
Write-Host "Claim audit"
Write-Host ("Status: {0}" -f $summary.status)
Write-Host ("Scanned files: {0}" -f $summary.scanned_files)
Write-Host ("Allowed risky-language contexts: {0}" -f $summary.allowed_risky_language)
Write-Host ("Suspicious matches: {0}" -f $suspiciousMatches.Count)
Write-Host ("Stale matches: {0}" -f $staleMatches.Count)
Write-Host "Summary written to wave\claim-audit-summary.json"

if ($summary.status -ne "pass") {
    throw "Claim audit failed; inspect wave\claim-audit-summary.json"
}
