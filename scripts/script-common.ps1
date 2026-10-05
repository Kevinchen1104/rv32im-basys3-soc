# Shared path, JSON, and hash validation. Resolve-RepoPath uses the caller's repoRoot.

function Find-FpgaVendorTool {
    param([ValidateSet('vivado','xsdb')][string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $roots = @($env:XILINX_VIVADO, 'C:\Xilinx\Vivado', 'C:\Program Files\Xilinx\Vivado', 'C:\AMD\Vivado')
    foreach ($installation in Get-ChildItem -LiteralPath 'C:\' -Directory -Filter 'AMDDesignTools*' -ErrorAction SilentlyContinue) {
        foreach ($version in Get-ChildItem -LiteralPath $installation.FullName -Directory -ErrorAction SilentlyContinue) {
            $roots += Join-Path $version.FullName 'Vivado'
        }
    }
    foreach ($root in ($roots | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique)) {
        $locations = @($root) + @(Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name -Descending | ForEach-Object FullName)
        foreach ($location in $locations) {
            foreach ($extension in @('bat','exe')) {
                $candidate = Join-Path $location "bin/$Name.$extension"
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
            }
        }
    }
    return $null
}

function Read-JsonIfPresent {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Assert-BuildReportArtifacts {
    param($Record, [string]$Root)
    if (@($Record.report_artifacts).Count -eq 0) { throw 'Build report hashes are missing; rebuild before export or reuse.' }
    $seen = @{}
    foreach ($artifact in $Record.report_artifacts) {
        $path = [string]$artifact.path
        if (-not $path -or $seen.ContainsKey($path) -or $artifact.sha256 -notmatch '^[0-9a-f]{64}$') {
            throw "Invalid build report record: $path"
        }
        $absolute = if ([IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $Root $path }
        $absolute = [IO.Path]::GetFullPath($absolute)
        if ($seen.ContainsKey($absolute)) { throw "Duplicate build report: $path" }
        $seen[$absolute] = $true
        if (-not (Test-Path -LiteralPath $absolute -PathType Leaf) -or
            (Get-Item -LiteralPath $absolute).Length -ne $artifact.size_bytes -or
            (Get-FileHash -LiteralPath $absolute -Algorithm SHA256).Hash.ToLowerInvariant() -ne $artifact.sha256) {
            throw "Build report has changed: $path"
        }
    }
    foreach ($property in $Record.reports.PSObject.Properties) {
        $path = if ($property.Value -is [string]) { $property.Value } else { $property.Value.path }
        if ($path -isnot [string] -or [string]::IsNullOrWhiteSpace($path)) { continue }
        $absolute = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $Root $path }))
        if (-not $seen.ContainsKey($absolute)) {
            throw "Report is absent from the build manifest: $path"
        }
    }
}

function Resolve-RepoPath {
    param([string] $Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Ensure-ParentDirectory {
    param([string] $Path)

    $parent = Split-Path -Parent $Path
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw "Output path has no parent directory: $Path"
    }
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
}

function Read-JsonFile {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required JSON metadata not found: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Normalize-Hash {
    param([string] $Hash)

    if ([string]::IsNullOrWhiteSpace($Hash) -or $Hash -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "ExpectedSha256 must contain exactly 64 hexadecimal characters."
    }
    return $Hash.ToLowerInvariant()
}
