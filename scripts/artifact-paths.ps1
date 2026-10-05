# Shared checks for generated-artifact cleanup. Never follow directory links.
function Assert-ArtifactPath {
    param([string]$Root, [string]$Path)
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Artifact path is outside its allowed directory: $full"
    }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    # A junction at Root (or above it) redirects every child too. Check the
    # whole ancestor chain before cleanup, not just the relative suffix.
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Artifact cleanup refuses linked paths: $($item.FullName)"
        }
        $parent = Split-Path -Parent $item.FullName
        $item = if ($parent) { Get-Item -LiteralPath $parent -Force } else { $null }
    }
    return $full
}

function Complete-TestFixture {
    param([string]$Root, [string]$Fixture, [string]$Status)
    $full = Assert-ArtifactPath -Root (Join-Path $Root 'build/tests') -Path $Fixture
    if ($Status -notin @('pass', 'passed')) { return $full }
    $relative = $full.Substring($Root.TrimEnd('\', '/').Length + 1).Replace('\', '/')
    $tracked = @(& git -C $Root ls-files -- $relative)
    if ($LASTEXITCODE -ne 0 -or $tracked.Count) { throw "Cannot clean a tracked test fixture: $relative" }
    $files = @(Get-ChildItem -LiteralPath $full -Force -Recurse)
    foreach ($file in $files) { $null = Assert-ArtifactPath -Root $full -Path $file.FullName }
    # Preserve latest diagnostic logs, but not copied scripts and mock inputs.
    $category = $relative.Split('/')[2]
    $logRoot = Join-Path $Root "results/logs/self-tests/$category"
    foreach ($file in $files | Where-Object { -not $_.PSIsContainer -and $_.Extension -eq '.log' }) {
        $destination = Join-Path $logRoot $file.FullName.Substring($full.Length + 1)
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination
    }
    Remove-Item -LiteralPath $full -Recurse -Force
    return $null
}
