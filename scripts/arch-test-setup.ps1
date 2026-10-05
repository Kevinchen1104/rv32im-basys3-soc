# Prepare the pinned, minimal upstream checkout used by the selected test profile.
param(
    [string]$ProfilePath = 'tools/arch-test/rv32im-selected.json',
    [string]$RepoUrl = '',
    [string]$CheckoutPath = '',
    [string]$OutputPath = 'results/arch-test-setup.json',
    [switch]$NoUpdate
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $root
. "$PSScriptRoot/result-format.ps1"
. "$PSScriptRoot/artifact-paths.ps1"
$summary = [ordered]@{
    generated_at_utc=(Get-Date).ToUniversalTime().ToString('o')
    status='starting'; reason=$null; repo_url=$null; checkout_path=$null
    checkout_present=$false; updated=$false; upstream_commit=$null
    pinned_revision=$null; sparse_paths=@()
}
Write-ResultJson $summary $OutputPath
function Invoke-SetupGit([string[]]$GitArgs) {
    & git @GitArgs
    if ($LASTEXITCODE -ne 0) { throw "Git setup failed: git $($GitArgs -join ' ')" }
}
try {
    $profile = Get-Content -LiteralPath $ProfilePath -Raw | ConvertFrom-Json
    if (-not $RepoUrl) { $RepoUrl = $profile.upstream.repo }
    if (-not $CheckoutPath) { $CheckoutPath = $profile.upstream.checkout }
    $revision = [string]$profile.upstream.revision
    if ($revision -notmatch '^[0-9a-f]{40}$') { throw 'The profile must pin a full upstream commit.' }
    $summary.repo_url = $RepoUrl
    $summary.checkout_path = $CheckoutPath
    $summary.pinned_revision = $revision
    $summary.sparse_paths = @($profile.upstream.sparse_paths)
    $checkout = [IO.Path]::GetFullPath((Join-Path $root $CheckoutPath))
    if (-not $checkout.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Checkout must be inside the repository.' }
    if (Test-Path -LiteralPath $checkout) { $null = Assert-ArtifactPath $root $checkout }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git is required.' }
    if (-not (Test-Path -LiteralPath (Join-Path $checkout '.git'))) {
        if (Test-Path -LiteralPath $checkout) { throw 'Checkout directory exists without Git metadata; preserve it before setup.' }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $checkout) | Out-Null
        Invoke-SetupGit @('clone','--depth','1','--filter=blob:none','--no-checkout',$RepoUrl,$checkout)
        & git -C $checkout cat-file -e "$revision^{commit}" 2>$null
        if ($LASTEXITCODE -ne 0) { Invoke-SetupGit @('-C',$checkout,'fetch','--depth','1','origin',$revision) }
        Invoke-SetupGit (@('-C',$checkout,'sparse-checkout','set','--cone') + $summary.sparse_paths)
        Invoke-SetupGit @('-C',$checkout,'checkout','--detach',$revision)
        $summary.updated = $true
    } else {
        $dirty = @(& git -C $checkout status --porcelain)
        if ($LASTEXITCODE -ne 0 -or $dirty.Count) { throw 'Existing upstream checkout has local changes; no files were removed.' }
        $head = (& git -C $checkout rev-parse HEAD).Trim()
        if ($head -ne $revision) { throw "Existing checkout is $head, but the profile requires $revision. Keep this checkout or use a separate CheckoutPath." }
        # No fetch is needed when the pinned commit is already present.
        Invoke-SetupGit (@('-C',$checkout,'sparse-checkout','set','--cone') + $summary.sparse_paths)
    }
    $summary.upstream_commit = (& git -C $checkout rev-parse HEAD).Trim()
    $summary.checkout_present = $true
    $summary.status = 'ready'
    $summary.reason = 'Pinned revision and selected test directories are ready.'
} catch {
    $summary.status = 'failed'
    $summary.reason = $_.Exception.Message
    throw
} finally { Write-ResultJson $summary $OutputPath }
Write-Host "Arch-test ready: $($summary.upstream_commit); $($summary.sparse_paths -join ', ')"
