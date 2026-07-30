<#
Script: scripts\verification-source-identity.ps1
Purpose: Provides a shared, cross-platform identity for verification and release-gate inputs.
Common usage:
  . "$PSScriptRoot\verification-source-identity.ps1"
Outputs:
  No files; exposes verification-source and documentation-input identity helpers.
Scope:
  Separates functional verification inputs from public documentation/package inputs.
Audience:
  Verification, audit, and release scripts that must reject stale PASS summaries.
#>

function Get-NormalizedTextSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)

    $text = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path))
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
        return [System.BitConverter]::ToString(
            $hasher.ComputeHash($bytes)
        ).Replace("-", "").ToLowerInvariant()
    } finally {
        $hasher.Dispose()
    }
}

function Get-PublishedReleaseIdentityProjection {
    if ($null -ne $script:PublishedReleaseIdentityProjection) {
        return $script:PublishedReleaseIdentityProjection
    }

    $manifestPath = Join-Path (Resolve-Path ".") "SOURCE_IDENTITY.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        $script:PublishedReleaseIdentityProjection = $false
        return $null
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.identity_mode -ne "content_fingerprint" -or
        $null -eq $manifest.identity_projection -or
        $null -eq $manifest.identity_projection.files) {
        throw "SOURCE_IDENTITY.json does not define a supported identity projection."
    }

    $script:PublishedReleaseIdentityProjection = $manifest.identity_projection
    return $script:PublishedReleaseIdentityProjection
}

function Get-VerificationFileSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)

    $normalizedPath = $Path.Replace("\", "/")
    $actualHash = if ([System.IO.Path]::GetExtension($Path).ToLowerInvariant() -eq ".bin") {
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    } else {
        Get-NormalizedTextSha256 -Path $Path
    }

    $projection = Get-PublishedReleaseIdentityProjection
    if ($null -ne $projection) {
        $property = $projection.files.PSObject.Properties[$normalizedPath]
        if ($null -ne $property) {
            $entry = $property.Value
            if ([string]$entry.published_sha256 -ne $actualHash) {
                throw "Published release file hash mismatch: $normalizedPath"
            }
            if ([string]$entry.recorded_sha256 -notmatch "^[0-9a-f]{64}$") {
                throw "Recorded release hash is invalid: $normalizedPath"
            }
            return [string]$entry.recorded_sha256
        }
    }

    return $actualHash
}

function Get-VerificationSourceIdentity {
    $pathSpecs = @(
        ".gitattributes",
        ".github/workflows",
        "docs/test_catalog.json",
        "firmware",
        "fixtures",
        "formal",
        "fpga/fpga_sources.f",
        "fpga/vivado",
        "fpga/xsdb",
        "fpga/boards/basys3/basys3.xdc",
        "rtl",
        "scripts",
        "tb",
        "tools"
    )

    $paths = @(
        & git ls-files --cached --others --exclude-standard -- @pathSpecs 2>$null |
            ForEach-Object { $_.Trim().Replace("\", "/") } |
            Where-Object { $_ -ne "" -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
            Sort-Object -Unique
    )
    if ($LASTEXITCODE -ne 0 -or $paths.Count -eq 0) {
        throw "Unable to enumerate verification source inputs."
    }

    $records = @(
        foreach ($path in $paths) {
            [ordered]@{
                path = $path
                sha256 = Get-VerificationFileSha256 -Path $path
            }
        }
    )
    $identityText = ($records | ForEach-Object {
        "$($_.path):$($_.sha256)"
    }) -join "`n"
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $identityBytes = [System.Text.Encoding]::UTF8.GetBytes($identityText)
        $fingerprint = [System.BitConverter]::ToString(
            $hasher.ComputeHash($identityBytes)
        ).Replace("-", "").ToLowerInvariant()
    } finally {
        $hasher.Dispose()
    }

    $sourceCommit = (& git rev-parse HEAD 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or $sourceCommit -notmatch "^[0-9a-f]{40}$") {
        throw "Unable to resolve verification source commit."
    }
    $workingTreeStatus = @(
        & git status --porcelain=v1 -- @pathSpecs 2>$null
    )
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect verification source working-tree state."
    }

    return [ordered]@{
        algorithm = "sha256(path:content-sha256 records; text LF-normalized, .bin raw)"
        source_commit = $sourceCommit
        verification_input_fingerprint = $fingerprint
        verification_input_count = $records.Count
        verification_working_tree_dirty = $workingTreeStatus.Count -ne 0
    }
}

function Add-VerificationIdentityFields {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Summary)

    $identity = Get-VerificationSourceIdentity
    $Summary["source_commit"] = $identity.source_commit
    $Summary["verification_input_fingerprint"] = $identity.verification_input_fingerprint
    $Summary["verification_input_count"] = $identity.verification_input_count
    $Summary["verification_working_tree_dirty"] = $identity.verification_working_tree_dirty
    return $identity
}

function Get-DocumentationInputIdentity {
    $sourcePathSpecs = @(
        ".github/workflows",
        "README.md",
        "docs",
        "firmware/src",
        "formal/README.md",
        "fpga/boards",
        "rtl",
        "scripts",
        "tb"
    )
    $packagePathSpecs = @(
        "release/final",
        "release/fpga"
    )
    $excludedGeneratedPaths = @(
        "release/final/artifacts.json",
        "release/final/evidence/documentation-coverage-summary.json",
        "release/final/evidence/docs-link-audit-summary.json",
        "release/final/evidence/claim-audit-summary.json"
    )

    $paths = @(
        & git ls-files --cached --others --exclude-standard -- @sourcePathSpecs @packagePathSpecs 2>$null |
            ForEach-Object { $_.Trim().Replace("\", "/") } |
            Where-Object { $_ -ne "" -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
            Where-Object { $excludedGeneratedPaths -notcontains $_ } |
            Where-Object {
                $path = $_
                $extension = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
                if ($path -eq "README.md") {
                    return $true
                }
                if ($path.StartsWith(".github/workflows/") -or
                    $path.StartsWith("docs/") -or
                    $path -eq "formal/README.md" -or
                    $path.StartsWith("fpga/boards/") -or
                    $path.StartsWith("release/")) {
                    return $extension -in @(".md", ".json", ".yml", ".yaml")
                }
                if ($path.StartsWith("rtl/") -or $path.StartsWith("tb/")) {
                    return $extension -in @(".v", ".vh", ".sv")
                }
                if ($path.StartsWith("firmware/src/")) {
                    return $extension -in @(".s", ".h", ".ld")
                }
                if ($path.StartsWith("scripts/")) {
                    return $extension -in @(".ps1", ".md")
                }
                return $false
            } |
            Sort-Object -Unique
    )
    if ($LASTEXITCODE -ne 0 -or $paths.Count -eq 0) {
        throw "Unable to enumerate documentation inputs."
    }

    $records = @(
        foreach ($path in $paths) {
            [ordered]@{
                path = $path
                sha256 = Get-VerificationFileSha256 -Path $path
            }
        }
    )
    $identityText = ($records | ForEach-Object {
        "$($_.path):$($_.sha256)"
    }) -join "`n"
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $identityBytes = [System.Text.Encoding]::UTF8.GetBytes($identityText)
        $fingerprint = [System.BitConverter]::ToString(
            $hasher.ComputeHash($identityBytes)
        ).Replace("-", "").ToLowerInvariant()
    } finally {
        $hasher.Dispose()
    }

    $repositoryHead = (& git rev-parse HEAD 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or $repositoryHead -notmatch "^[0-9a-f]{40}$") {
        throw "Unable to resolve documentation repository HEAD."
    }
    $sourceWorkingTreeStatus = @(
        & git status --porcelain=v1 -- @sourcePathSpecs 2>$null
    )
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect documentation source working-tree state."
    }

    return [ordered]@{
        algorithm = "sha256(path:content-sha256 records; text LF-normalized)"
        documentation_repository_head = $repositoryHead
        documentation_input_fingerprint = $fingerprint
        documentation_input_count = $records.Count
        documentation_source_working_tree_dirty = $sourceWorkingTreeStatus.Count -ne 0
        documentation_input_scope = "README, public docs/board metadata, audited source headers, workflows, and generated release text/metadata; generated audit copies and final artifact manifest excluded"
    }
}

function Add-DocumentationIdentityFields {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Summary)

    $identity = Get-DocumentationInputIdentity
    $Summary["documentation_repository_head"] = $identity.documentation_repository_head
    $Summary["documentation_input_fingerprint"] = $identity.documentation_input_fingerprint
    $Summary["documentation_input_count"] = $identity.documentation_input_count
    $Summary["documentation_source_working_tree_dirty"] = $identity.documentation_source_working_tree_dirty
    $Summary["documentation_input_scope"] = $identity.documentation_input_scope
    return $identity
}
