<#
Purpose: Collect advisory introductory-comment coverage without prescribing wording.
Usage: Dot-source this file, then call Get-DocumentationCoverage.
#>
function Test-IntroductoryComment {
    param([string]$Text, [string]$Extension)
    $prefix = ($Text -split "\r?\n" | Select-Object -First 40) -join "`n"
    switch ($Extension.ToLowerInvariant()) {
        '.v'   { return $prefix -match '(?m)^\s*(//\s*\S|/\*\s*\S)' }
        '.s'   { return $prefix -match '(?m)^\s*#\s*\S' }
        '.ps1' { return $prefix -match '(?m)^\s*(#\s*\S|<#)' }
        default { throw "Unsupported documentation source type: $Extension" }
    }
}

function Get-DocumentationCoverage {
    param(
        [string]$Root,
        [ValidateSet('rtl', 'testbench', 'firmware', 'script')][string]$Kind
    )
    $settings = @{
        rtl = @('rtl', '*.v')
        testbench = @('tb', '*.v')
        firmware = @('firmware/src', '*.S')
        script = @('scripts', '*.ps1')
    }
    $directory = Join-Path $Root $settings[$Kind][0]
    $files = @(Get-ChildItem -LiteralPath $directory -Recurse -File -Filter $settings[$Kind][1])
    if ($files.Count -eq 0) { throw "No $Kind source files found in $directory" }
    $findings = @(
        foreach ($file in $files | Sort-Object FullName) {
            if (-not (Test-IntroductoryComment -Text (Get-Content -LiteralPath $file.FullName -Raw) -Extension $file.Extension)) {
                [pscustomobject]@{
                    file = $file.FullName.Substring($Root.Length + 1).Replace('\', '/')
                    suggestion = 'Consider an introductory comment explaining this file.'
                }
            }
        }
    )
    [pscustomobject]@{
        kind = $Kind
        files_checked = $files.Count
        files_with_introductory_comment = $files.Count - $findings.Count
        findings = $findings
    }
}

function Write-DocumentationCoverage {
    param($Coverage)
    Write-Host ("ADVISORY: {0}: {1}/{2} files have an introductory comment." -f
        $Coverage.kind, $Coverage.files_with_introductory_comment, $Coverage.files_checked)
    if ($Coverage.findings.Count) {
        $Coverage.findings | Format-Table -AutoSize | Out-String | Write-Host
    }
}
