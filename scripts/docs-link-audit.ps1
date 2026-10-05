<#
Script: scripts\docs-link-audit.ps1
Purpose: Checks documentation links and referenced local files for stale paths.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\docs-link-audit.ps1
Outputs:
  Console link-audit report.
#>
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/result-format.ps1"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. "$PSScriptRoot\verification-source-identity.ps1"

New-Item -ItemType Directory -Force -Path "results" | Out-Null

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

function Test-ExternalOrAnchor {
    param([string] $Target)

    return ($Target -match "^(?i)(https?:|mailto:|data:)")
}

function Get-NormalizedTarget {
    param([string] $RawTarget)

    $target = $RawTarget.Trim()
    if ([string]::IsNullOrWhiteSpace($target)) {
        return $null
    }

    if ($target.StartsWith("<") -and $target.EndsWith(">")) {
        $target = $target.Substring(1, $target.Length - 2)
    }

    $quoteIndex = $target.IndexOf('"')
    if ($quoteIndex -ge 0) {
        $target = $target.Substring(0, $quoteIndex).Trim()
    }

    $spaceIndex = $target.IndexOf(" ")
    if ($spaceIndex -ge 0) {
        $target = $target.Substring(0, $spaceIndex).Trim()
    }

    if (Test-ExternalOrAnchor -Target $target) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($target)) {
        return $null
    }

    $target = [System.Uri]::UnescapeDataString($target)
    # Preserve a leading ./ so source-relative Markdown links stay relative.
    $target = $target.Trim([char[]]@('"', "'", " ", "`t", "`r", "`n", ",", ";", ":"))

    if ($target -match "[<>*?]") {
        return $null
    }

    return $target
}

function Resolve-LocalReference {
    param(
        [string] $Target,
        [string] $SourceFile,
        [switch] $RepoRootReference
    )

    $target = $Target.Replace("/", [System.IO.Path]::DirectorySeparatorChar).Replace("\", [System.IO.Path]::DirectorySeparatorChar)
    if ([System.IO.Path]::IsPathRooted($target)) {
        return [System.IO.Path]::GetFullPath($target)
    }

    if ($RepoRootReference) {
        return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $target))
    }

    $sourceDir = Split-Path -Parent $SourceFile
    return [System.IO.Path]::GetFullPath((Join-Path $sourceDir $target))
}

function Test-MarkdownAnchor {
    param([string]$Path, [string]$Anchor)
    $headings = @{}
    $used = @{}
    $inFence = $false
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*(```|~~~)') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        if ($line -match '^#{1,6}\s+(.+?)\s*#*\s*$') {
            $heading = $Matches[1].ToLowerInvariant()
            $heading = $heading -replace '\[([^\]]+)\]\([^)]+\)', '$1'
            $heading = $heading -replace '<[^>]+>', ''
            $heading = $heading -replace '[^\p{L}\p{N}\s_-]', '' -replace '\s', '-'
            $id = $heading
            if ($used.ContainsKey($heading)) { $used[$heading]++; $id = "$heading-$($used[$heading])" }
            else { $used[$heading] = 0 }
            $headings[$id] = $true
        }
        foreach ($match in [regex]::Matches($line, '(?i)(?:id|name)=["'']([^"'']+)["'']')) {
            $headings[$match.Groups[1].Value] = $true
        }
    }
    return $headings.ContainsKey($Anchor)
}

$scanFiles = [System.Collections.Generic.List[object]]::new()
if (Test-Path -LiteralPath "README.md") {
    $scanFiles.Add((Get-Item -LiteralPath "README.md")) | Out-Null
}
foreach ($publicReadme in @("formal\README.md", "scripts\README.md")) {
    if (Test-Path -LiteralPath $publicReadme) {
        $scanFiles.Add((Get-Item -LiteralPath $publicReadme)) | Out-Null
    }
}
if (Test-Path -LiteralPath "docs") {
    Get-ChildItem -LiteralPath "docs" -Recurse -File -Filter "*.md" |
        ForEach-Object { $scanFiles.Add($_) | Out-Null }
}
if (Test-Path -LiteralPath "fpga\boards") {
    Get-ChildItem -LiteralPath "fpga\boards" -Recurse -File -Filter "*.md" |
        ForEach-Object { $scanFiles.Add($_) | Out-Null }
}
if (Test-Path -LiteralPath "release") {
    Get-ChildItem -LiteralPath "release" -Recurse -File -Filter "*.md" |
        Where-Object { $_.FullName -notmatch "\\release\\final\\docs\\" } |
        ForEach-Object { $scanFiles.Add($_) | Out-Null }
}

$missing = [System.Collections.Generic.List[object]]::new()
$checked = [System.Collections.Generic.List[object]]::new()

foreach ($file in ($scanFiles | Sort-Object FullName -Unique)) {
    $relativeFile = Get-RepoRelativePath $file.FullName
    $text = Get-Content -LiteralPath $file.FullName -Raw

    $linkMatches = [regex]::Matches($text, "!?\[[^\]]*\]\((?<target>[^)]+)\)")
    foreach ($match in $linkMatches) {
        $target = Get-NormalizedTarget -RawTarget $match.Groups["target"].Value
        if ($null -eq $target) {
            continue
        }

        $parts = $target -split '#', 2
        $resolved = if ($parts[0]) { Resolve-LocalReference -Target $parts[0] -SourceFile $file.FullName } else { $file.FullName }
        $entry = [ordered]@{
            source = $relativeFile
            reference = $target
            kind = "markdown_link"
        }

        $valid = Test-Path -LiteralPath $resolved
        if ($valid -and $parts.Count -eq 2 -and $parts[1] -and $resolved -match '\.md$') {
            $valid = Test-MarkdownAnchor -Path $resolved -Anchor $parts[1]
        }
        if ($valid) {
            $checked.Add($entry) | Out-Null
        } else {
            $missing.Add($entry) | Out-Null
        }
    }

    $inlineMatches = [regex]::Matches($text, '`(?<target>[^`]+)`')
    foreach ($match in $inlineMatches) {
        $candidate = $match.Groups["target"].Value.Trim()
        if ($candidate -notmatch "^(\.?github[\\/]|docs[\\/]|scripts[\\/]|rtl[\\/]|tb[\\/]|firmware[\\/]|fixtures[\\/]|release[\\/]|fpga[\\/]|tools[\\/]|formal[\\/]|programs[\\/]|src[\\/]|README\.md$)") {
            continue
        }

        $target = Get-NormalizedTarget -RawTarget $candidate
        if ($null -eq $target) {
            continue
        }

        $resolved = Resolve-LocalReference -Target $target -SourceFile $file.FullName -RepoRootReference
        $entry = [ordered]@{
            source = $relativeFile
            reference = $target
            kind = "inline_code_reference"
        }

        if (Test-Path -LiteralPath $resolved) {
            $checked.Add($entry) | Out-Null
        } else {
            $missing.Add($entry) | Out-Null
        }
    }
}

$status = if ($missing.Count -eq 0) { "pass" } else { "fail" }
$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = $status
    scanned_markdown_files = @($scanFiles | Sort-Object FullName -Unique).Count
    checked_local_references = $checked.Count
    missing_local_references = $missing.ToArray()
    scope = "File-relative Markdown links and heading anchors; repo-root inline code paths. External URLs, placeholders, wildcards, and release/final docs snapshots are skipped."
}
Add-DocumentationIdentityFields -Summary $summary | Out-Null

Write-ResultJson $summary "results\docs-link-audit-summary.json"
Write-Host "========================================"
Write-Host "Docs link audit"
Write-Host ("Status: {0}" -f $summary.status)
Write-Host ("Scanned markdown files: {0}" -f $summary.scanned_markdown_files)
Write-Host ("Checked local references: {0}" -f $summary.checked_local_references)
Write-Host ("Missing local references: {0}" -f $missing.Count)
Write-Host "Summary written to results\docs-link-audit-summary.json"

if ($summary.status -ne "pass") {
    throw "Docs link audit failed; inspect results\docs-link-audit-summary.json"
}
