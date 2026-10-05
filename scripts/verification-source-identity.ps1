<#
Script: scripts\verification-source-identity.ps1
Purpose: Provides a shared, cross-platform identity for verification and release-gate inputs.
Common usage:
  . "$PSScriptRoot\verification-source-identity.ps1"
Outputs:
  No files; exposes verification-source and documentation-input identity helpers.
Scope:
  Separates functional verification inputs from public documentation/package inputs.
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

function Get-VerificationFileSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)

    if ([System.IO.Path]::GetExtension($Path).ToLowerInvariant() -eq ".bin") {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return Get-NormalizedTextSha256 -Path $Path
}

function Get-OrdinalUniquePaths {
    param([string[]]$Paths)
    $sorted = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $Paths) { [void]$sorted.Add($path) }
    foreach ($path in $sorted) { $path }
}

function Get-VerificationSourceIdentity {
    param([switch]$IncludeRecords)
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
            Where-Object { $_ -ne "" -and (Test-Path -LiteralPath $_ -PathType Leaf) }
    )
    if ($LASTEXITCODE -ne 0 -or $paths.Count -eq 0) {
        throw "Unable to enumerate verification source inputs."
    }

    $paths = @(Get-OrdinalUniquePaths $paths)
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

    $identity = [ordered]@{
        algorithm = "sha256(path:content-sha256 records; text LF-normalized, .bin raw)"
        source_commit = $sourceCommit
        verification_input_fingerprint = $fingerprint
        verification_input_count = $records.Count
        verification_working_tree_dirty = $workingTreeStatus.Count -ne 0
    }
    if ($IncludeRecords) { $identity.inputs = $records }
    return $identity
}

function Add-VerificationIdentityFields {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Summary,
        [System.Collections.IDictionary] $Identity = (Get-VerificationSourceIdentity)
    )

    $Summary["source_commit"] = $identity.source_commit
    $Summary["verification_input_fingerprint"] = $identity.verification_input_fingerprint
    $Summary["verification_input_count"] = $identity.verification_input_count
    $Summary["verification_working_tree_dirty"] = $identity.verification_working_tree_dirty
    return $identity
}

function Assert-VerificationInputsUnchanged {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Identity)
    $current = Get-VerificationSourceIdentity
    if ($current.verification_input_fingerprint -ne $Identity.verification_input_fingerprint) {
        throw 'Verification inputs changed during execution. Rerun with stable sources.'
    }
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
        "release/README.md",
        "release/current",
        "release/implementation",
        "release/configuration",
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
            }
    )
    if ($LASTEXITCODE -ne 0 -or $paths.Count -eq 0) {
        throw "Unable to enumerate documentation inputs."
    }

    $paths = @(Get-OrdinalUniquePaths $paths)
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
