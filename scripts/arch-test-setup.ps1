<#
Script: scripts\arch-test-setup.ps1
Purpose: Prepares or validates local paths used by the optional architectural-test integration.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\arch-test-setup.ps1
Outputs:
  Console setup report and any local arch-test staging files requested by the user.
Scope:
  Local setup helper only; not hardware evidence or compliance certification.
Audience:
  Internal helper for optional arch-test workflows.
#>
param(
    [string]$RepoUrl = "https://github.com/riscv-non-isa/riscv-arch-test.git",
    [string]$CheckoutPath = "external\riscv-arch-test",
    [string]$OutputPath = "wave\arch-test-setup.json",
    [switch]$NoUpdate
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
New-Item -ItemType Directory -Force -Path "wave" | Out-Null
New-Item -ItemType Directory -Force -Path "external" | Out-Null

function Write-SetupSummary {
    param(
        [string]$Status,
        [string]$Reason,
        [string]$Commit = $null,
        [bool]$CheckoutPresent = $false,
        [bool]$Updated = $false
    )

    $summary = [ordered]@{
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        status = $Status
        reason = $Reason
        repo_url = $RepoUrl
        checkout_path = $CheckoutPath
        checkout_present = $CheckoutPresent
        updated = $Updated
        upstream_commit = $Commit
        external_policy = "external/ is gitignored; upstream riscv-arch-test is not vendored into this repository"
    }

    $summary | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputPath -Encoding Ascii

    Write-Host "========================================"
    Write-Host "RISC-V arch-test setup"
    Write-Host ("Status: {0}" -f $Status)
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        Write-Host ("Reason: {0}" -f $Reason)
    }
    if (-not [string]::IsNullOrWhiteSpace($Commit)) {
        Write-Host ("Upstream commit: {0}" -f $Commit)
    }
    Write-Host ("Setup summary written to {0}" -f $OutputPath)
}

function Get-UpstreamCommit {
    param([string]$Path)

    try {
        $commit = & git -C $Path rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0) {
            return ($commit | Select-Object -First 1).ToString().Trim()
        }
    } catch {
        return $null
    }

    return $null
}

$gitCommand = Get-Command git -ErrorAction SilentlyContinue
if ($null -eq $gitCommand) {
    Write-SetupSummary -Status "blocked_no_tool" -Reason "git is required to clone or update riscv-arch-test"
    exit 0
}

$checkoutFullPath = Join-Path $repoRoot $CheckoutPath
$gitDir = Join-Path $checkoutFullPath ".git"

if (Test-Path -LiteralPath $gitDir) {
    $updated = $false
    $updateReason = "existing checkout reused"

    if (-not $NoUpdate) {
        try {
            & git -C $checkoutFullPath fetch --all --tags --prune
            if ($LASTEXITCODE -eq 0) {
                $updated = $true
                $updateReason = "existing checkout fetched"
            } else {
                $updateReason = "fetch failed; existing checkout reused"
            }
        } catch {
            $updateReason = "fetch failed; existing checkout reused: $($_.Exception.Message)"
        }
    }

    $commit = Get-UpstreamCommit -Path $checkoutFullPath
    if ([string]::IsNullOrWhiteSpace($commit)) {
        Write-SetupSummary -Status "blocked_no_tool" -Reason "existing checkout is present but git commit could not be read" -CheckoutPresent $true -Updated $updated
    } else {
        Write-SetupSummary -Status "ready" -Reason $updateReason -Commit $commit -CheckoutPresent $true -Updated $updated
    }
    exit 0
}

try {
    & git clone --depth 1 $RepoUrl $checkoutFullPath
    if ($LASTEXITCODE -ne 0) {
        Write-SetupSummary -Status "blocked_no_tool" -Reason "git clone failed; check network access or repository URL"
        exit 0
    }
} catch {
    Write-SetupSummary -Status "blocked_no_tool" -Reason "git clone failed: $($_.Exception.Message)"
    exit 0
}

$commitAfterClone = Get-UpstreamCommit -Path $checkoutFullPath
if ([string]::IsNullOrWhiteSpace($commitAfterClone)) {
    Write-SetupSummary -Status "blocked_no_tool" -Reason "clone completed but upstream commit could not be read" -CheckoutPresent $true
    exit 0
}

Write-SetupSummary -Status "ready" -Reason "fresh checkout cloned" -Commit $commitAfterClone -CheckoutPresent $true -Updated $true
