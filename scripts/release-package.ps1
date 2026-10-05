# Shared package integrity, provenance, and publication helpers.
. "$PSScriptRoot/result-format.ps1"
. "$PSScriptRoot/verification-source-identity.ps1"
. "$PSScriptRoot/test-catalog.ps1"

function Read-ReleaseJson([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing evidence: $Path" }
    $value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    return $value
}

function Resolve-ReleasePath([string]$Root, [string]$Relative) {
    if (-not $Relative -or $Relative -match '[:\\]' -or
        @($Relative.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count) {
        throw "Unsafe package path: $Relative"
    }
    $path = [IO.Path]::GetFullPath($Root)
    foreach ($part in @('') + $Relative.Split('/')) {
        if ($part) { $path = Join-Path $path $part }
        if ((Test-Path -LiteralPath $path) -and
            ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Reparse point is not a package input: $path"
        }
    }
    $path
}

function Get-ReleaseFingerprint($Inputs) {
    if (@($Inputs).Count -eq 0) { throw 'Empty source manifest' }
    $byPath = @{}
    foreach ($item in $Inputs) {
        Resolve-ReleasePath $PWD.Path $item.path | Out-Null
        if ($item.sha256 -notmatch '^[0-9a-f]{64}$' -or $byPath.ContainsKey($item.path)) {
            throw "Invalid or duplicate source record: $($item.path)"
        }
        $byPath[$item.path] = $item.sha256
    }
    $text = (@(Get-OrdinalUniquePaths @($byPath.Keys)) | ForEach-Object { "${_}:$($byPath[$_])" }) -join "`n"
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
}

function Test-ReleaseInputs($Inputs, [string]$Root, [string]$HashMode) {
    foreach ($item in $Inputs) {
        $path = Resolve-ReleasePath $Root $item.path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        $hash = if ($HashMode -eq 'raw') { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
            elseif ($HashMode -eq 'verification') { Get-VerificationFileSha256 $path }
            else { throw "Unknown input hash mode: $HashMode" }
        if ($hash -ne $item.sha256) { return $false }
    }
    return $true
}

function Test-ReleaseGateIdentity($Record, $Identity) {
    return ($null -ne $Record -and
        $Record.verification_input_fingerprint -eq $Identity.verification_input_fingerprint -and
        $Record.verification_input_count -eq $Identity.verification_input_count -and
        $Record.verification_working_tree_dirty -ceq $false -and
        $Record.source_commit -match '^[0-9a-f]{40}$')
}

function Assert-PortableCoverage($Check, $Regression, $Catalog, $CatalogResult, $Coverage) {
    $names = @($Catalog.tests | Where-Object included_in_full_regression | ForEach-Object name)
    $actual = @($Regression.tests | ForEach-Object name)
    if ($Check.status -ne 'pass' -or $Check.mode -ne 'Full' -or
        $Check.planned_steps -lt 1 -or @($Check.steps).Count -ne $Check.planned_steps -or
        @($Check.steps | Where-Object { $_.status -ne 'passed' -or $_.exit_code -ne 0 }).Count) {
        throw 'Full workflow is incomplete or failed'
    }
    if (-not $names.Count -or $names.Count -ne ($names | Select-Object -Unique).Count -or
        $actual.Count -ne $names.Count -or ($actual | Select-Object -Unique).Count -ne $names.Count -or
        @(Compare-Object $names $actual).Count -or $Regression.status -notin @('pass', 'passed') -or
        $Regression.total -ne $names.Count -or $Regression.passed -ne $names.Count -or
        $Regression.failed -ne 0 -or @($Regression.tests | Where-Object status -ne 'passed').Count) {
        throw 'Regression coverage does not match the full test catalog'
    }
    if ($CatalogResult.total_catalog_entries -ne @($Catalog.tests).Count -or
        $CatalogResult.run_ps1_tests -ne $names.Count -or $Coverage.status -ne 'pass' -or
        $Coverage.total_tests -ne $names.Count -or $Coverage.passed -ne $names.Count -or $Coverage.failed -ne 0) {
        throw 'Catalog or regression evidence counts disagree'
    }
}

function Assert-ImplementationResult($Record) {
    $timing = $Record.reports.post_route_timing
    $drc = $Record.reports.post_route_drc
    if ($Record.status -ne 'pass' -or $Record.execution_status -ne 'pass' -or
        $Record.timing_status -ne 'pass' -or $timing.present -cne $true -or
        $drc.present -cne $true -or $drc.report_parse_complete -cne $true -or $drc.release_approved -cne $true) {
        throw 'Implementation, post-route timing, or DRC did not pass'
    }
    foreach ($name in @('wns_ns', 'whs_ns')) {
        if ($null -eq $timing.$name -or $timing.$name -lt 0) { throw "Timing failed: $name" }
    }
    foreach ($name in @('tns_ns', 'ths_ns', 'no_clock_count', 'unconstrained_internal_endpoint_count', 'no_input_delay_count', 'no_output_delay_count')) {
        if ($null -eq $timing.$name -or $timing.$name -ne 0) { throw "Timing/constraint check failed: $name" }
    }
    foreach ($name in @('error_count', 'critical_warning_count', 'unapproved_warning_count')) {
        if ($null -eq $drc.$name -or $drc.$name -ne 0) { throw "DRC failed: $name" }
    }
    if (@($Record.source_inputs).Count -eq 0 -or $Record.source_commit -notmatch '^[0-9a-f]{40}$' -or
        $Record.working_tree_dirty -cne $false) {
        throw 'Implementation input identity is missing'
    }
}

function Write-ReleaseManifest([string]$Root) {
    $base = (Resolve-Path -LiteralPath $Root).Path
    $records = @(foreach ($file in Get-ChildItem -LiteralPath $base -Recurse -File -Force | Sort-Object FullName) {
        $relative = $file.FullName.Substring($base.Length + 1).Replace('\', '/')
        if ($relative -eq 'artifacts.json') { continue }
        Resolve-ReleasePath $base $relative | Out-Null
        [ordered]@{ path=$relative; bytes=$file.Length; sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    Write-ResultJson $records (Join-Path $base 'artifacts.json')
}

function Assert-ReleaseManifest([string]$Root) {
    $base = (Resolve-Path -LiteralPath $Root).Path
    Resolve-ReleasePath $base 'artifacts.json' | Out-Null
    $records = @(Read-ReleaseJson (Join-Path $base 'artifacts.json'))
    if (-not $records.Count) { throw 'Empty artifact manifest' }
    $seen = @{}
    foreach ($r in $records) {
        $path = Resolve-ReleasePath $base $r.path
        if ($seen.ContainsKey($r.path) -or $r.path -eq 'artifacts.json' -or
            $r.sha256 -notmatch '^[0-9a-f]{64}$' -or $null -eq $r.bytes -or
            -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Invalid artifact: $($r.path)" }
        $seen[$r.path] = $true
        if ((Get-Item -LiteralPath $path).Length -ne $r.bytes -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $r.sha256) {
            throw "Artifact content changed: $($r.path)"
        }
    }
    $files = @(Get-ChildItem -LiteralPath $base -Recurse -File -Force)
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($base.Length + 1).Replace('\', '/')
        Resolve-ReleasePath $base $relative | Out-Null
        if ($relative -ne 'artifacts.json' -and -not $seen.ContainsKey($relative)) { throw "Unlisted artifact: $relative" }
    }
    $records.Count
}

function Assert-ReleasePackage([string]$Root, [string]$SourceRoot, [switch]$RequireCurrent) {
    $count = Assert-ReleaseManifest $Root
    $summary = Read-ReleaseJson (Join-Path $Root 'package.json')
    $source = Read-ReleaseJson (Join-Path $Root 'source-inputs.json')
    $fingerprint = Get-ReleaseFingerprint $source.inputs
    if ($summary.schema_version -ne 1 -or $summary.status -ne 'pass' -or $summary.source_commit -notmatch '^[0-9a-f]{40}$' -or
        $source.hash_mode -notin @('verification', 'raw') -or
        $source.fingerprint -ne $fingerprint -or $summary.source_fingerprint -ne $fingerprint -or
        $summary.input_count -ne @($source.inputs).Count) { throw 'Package identity is inconsistent' }
    $current = Test-ReleaseInputs $source.inputs $SourceRoot $source.hash_mode
    if ($summary.kind -eq 'portable') {
        $id = @{ verification_input_fingerprint=$fingerprint; verification_input_count=@($source.inputs).Count }
        $gates = @{}
        foreach ($entry in $summary.gates) {
            if ($gates.ContainsKey($entry.path)) { throw "Duplicate evidence gate: $($entry.path)" }
            $record = Read-ReleaseJson (Resolve-ReleasePath $Root $entry.path)
            if (-not (Test-ReleaseGateIdentity $record $id)) { throw "Evidence identity mismatch: $($entry.path)" }
            if ($entry.path -ne 'evidence/test-catalog-summary.json' -and $record.status -notin @('pass', 'passed')) {
                throw "Evidence gate did not pass: $($entry.path)"
            }
            $gates[$entry.path] = $record
        }
        Assert-PortableCoverage $gates['evidence/check-summary.json'] $gates['evidence/regression-summary.json'] `
            (Read-TestCatalog (Join-Path $Root 'test_catalog.json')) $gates['evidence/test-catalog-summary.json'] $gates['evidence/regression-evidence-summary.json']
        $catalogInput = @($source.inputs | Where-Object path -eq 'docs/test_catalog.json')
        if ($catalogInput.Count -ne 1 -or (Get-VerificationFileSha256 (Join-Path $Root 'test_catalog.json')) -ne $catalogInput[0].sha256) {
            throw 'Packaged catalog does not match the verified input manifest'
        }
        # Detect added/removed inputs too, not only changes to already listed files.
        Push-Location $SourceRoot
        try { $now = Get-VerificationSourceIdentity }
        finally { Pop-Location }
        $current = $current -and $now.verification_input_fingerprint -eq $fingerprint -and -not $now.verification_working_tree_dirty
    } elseif ($summary.kind -eq 'implementation') {
        $record = Read-ReleaseJson (Join-Path $Root 'implementation.json')
        Assert-ImplementationResult $record
        if ((Get-ReleaseFingerprint $record.source_inputs) -ne $fingerprint) { throw 'Implementation identity mismatch' }
        foreach ($property in $record.reports.PSObject.Properties) {
            $path = if ($property.Value -is [string]) { $property.Value } else { $property.Value.path }
            if ($path -is [string] -and $path -and -not (Test-Path -LiteralPath (Resolve-ReleasePath $Root $path) -PathType Leaf)) {
                throw "Missing implementation report: $path"
            }
        }
    } elseif ($summary.kind -ne 'configuration') { throw "Unknown package kind: $($summary.kind)" }
    if ($RequireCurrent -and -not $current) { throw 'Package inputs do not match the current committed source' }
    [ordered]@{ path=$Root; kind=$summary.kind; integrity='pass'; source_match=if ($current) { 'current' } else { 'historical' }; artifacts=$count; source_commit=$summary.source_commit }
}

function New-ReleaseStage([string]$RepoRoot) {
    $path = Resolve-ReleasePath $RepoRoot ('build/release/stage-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $path
}

function Publish-ReleasePackage([string]$Stage, [string]$Destination, [string]$RepoRoot) {
    $stageRoot = [IO.Path]::GetFullPath((Join-Path $RepoRoot 'build/release')).TrimEnd('\', '/')
    if (-not [IO.Path]::GetFullPath($Stage).StartsWith($stageRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Publication staging must be inside build/release'
    }
    # Validate before changing a previous published snapshot.
    Assert-ReleasePackage $Stage $RepoRoot -RequireCurrent | Out-Null
    $allowed = @('release/current', 'release/implementation/basys3', 'release/configuration/generic_uart_boot_runtime')
    if ($Destination -notin $allowed) { throw "Unsupported publication destination: $Destination" }
    $target = Resolve-ReleasePath $RepoRoot $Destination
    $backup = Resolve-ReleasePath $RepoRoot ('build/release/previous-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
    $hadPrevious = Test-Path -LiteralPath $target
    if ($hadPrevious) {
        Assert-ReleaseManifest $target | Out-Null
        Move-Item -LiteralPath $target -Destination $backup
    }
    try { Move-Item -LiteralPath $Stage -Destination $target }
    catch {
        if ($hadPrevious) { Move-Item -LiteralPath $backup -Destination $target }
        throw
    }
    # backup was resolved inside build/release above; only the replaced snapshot is removed.
    if ($hadPrevious) {
        Remove-Item -LiteralPath $backup -Recurse -Force
    }
}

function Copy-ReleaseText([string]$Source, [string]$Destination, [string]$RepoRoot) {
    $text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Source))
    # Redact host-specific paths in derivative review copies; originals stay unchanged.
    foreach ($root in @($RepoRoot.Replace('\', '\\'), $RepoRoot.Replace('\', '/'), $RepoRoot)) {
        $text = $text.Replace($root, '.')
    }
    $text = [regex]::Replace($text, '(?m)^(\s*(?:#|\|)?\s*Host\s*[:|]).*$', '$1 <host>')
    $parent = Split-Path $Destination
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [IO.File]::WriteAllText($Destination, $text.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
}
