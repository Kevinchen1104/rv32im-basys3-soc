# Check JSON readability, lossless serialization, and every repository JSON writer.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. "$PSScriptRoot/result-format.ps1"
$checks = New-Object 'System.Collections.Generic.List[string]'
function Assert-Format([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $checks.Add($Message)
}
$summary = [ordered]@{ status='running'; checks=@(); error_message=$null }
$output = Join-Path $root 'results/result-format-self-test-summary.json'
Write-ResultJson $summary $output
try {
    $sample = [ordered]@{
        text = 'escaped "quote", C:\path, [1,   2], { braces }, colon:  keep spacing'
        unicode = [string][char]0x6e2c + [char]0x8a66
        flags = @(1, -2.5, $true, $false, $null, 'x')
        empty = @()
        single = @('only')
        objects = @([ordered]@{ a=1 }, [ordered]@{ a=2 })
        long = @(('a' * 100), ('b' * 100))
        histogram = @(0..63)
    }
    $json = ConvertTo-ResultJson $sample
    $parsed = $json | ConvertFrom-Json
    Assert-Format ($parsed.text -ceq $sample.text -and $parsed.unicode -ceq $sample.unicode) 'Escapes, Unicode, and spaces inside strings survive'
    Assert-Format ($json.Contains('"flags": [1, -2.5, true, false, null, "x"]')) 'Short scalar arrays fit on one line'
    Assert-Format ($json.Contains('"empty": []') -and $json.Contains('"single": ["only"]')) 'Empty and single-item arrays keep their types'
    Assert-Format ($json.Contains('"objects": [' + "`n    {") -and $json.Contains('"long": [' + "`n")) 'Objects and long arrays remain readable on separate lines'
    Assert-Format ($json.Contains("`n  " + '"text": ') -and $json -notmatch '\r|\n\s*\n') 'Two-space indentation, one colon space, and LF endings'
    Assert-Format ($json -ceq (Format-ResultJsonText $json)) 'Formatting is idempotent'
    Assert-Format ($json.Contains("    0, 1, 2, 3, 4, 5, 6, 7,`n")) 'Long numeric arrays wrap into compact rows'
    Assert-Format (($parsed.histogram -join ',') -ceq ($sample.histogram -join ',')) 'Wrapped arrays preserve all values in order'
    Assert-Format ((ConvertTo-ResultJson @()) -ceq "[]`n") 'Root empty array is preserved'
    Assert-Format ((ConvertTo-ResultJson @(7)) -ceq "[7]`n") 'Root single-item array is preserved'
    Assert-Format ((ConvertTo-ResultJson $null) -ceq "null`n") 'Root null is preserved'

    $fixture = Join-Path $root 'build/tests/result-format/nested/roundtrip.json'
    Write-ResultJson $sample $fixture
    $bytes = [IO.File]::ReadAllBytes($fixture)
    Assert-Format ($bytes[0] -eq 123 -and [IO.File]::ReadAllText($fixture) -ceq $json) 'Files use UTF-8 without BOM and create parent directories'

    # These serializers produce golden test inputs, not result summaries.
    $rawSerializers = @{
        'random-call-reference.ps1' = 1
        'random-control-reference.ps1' = 1
        'random-hazard-reference.ps1' = 1
        'random-memory-reference.ps1' = 1
        'trace-lockstep-reference.ps1' = 1
        'trace-trap-reference.ps1' = 1
        'result-format.ps1' = 1
    }
    $files = @(Get-ChildItem $PSScriptRoot -Recurse -File -Filter '*.ps1')
    $writers = @()
    foreach ($file in $files) {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw "PowerShell parse error in $($file.Name): $errors" }
        if (@([regex]::Matches([IO.File]::ReadAllText($file.FullName), '(?m)^\. .*result-format\.ps1')).Count -gt 1) {
            throw "Duplicate formatter import in $($file.Name)"
        }
        $commands = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))
        $raw = @($commands | Where-Object { $_.GetCommandName() -eq 'ConvertTo-Json' })
        $expected = if ($rawSerializers.ContainsKey($file.Name)) { $rawSerializers[$file.Name] } else { 0 }
        if ($raw.Count -ne $expected) { throw "Unreviewed raw JSON serializer in $($file.Name): expected $expected, found $($raw.Count). Use Write-ResultJson." }
        if (@($commands | Where-Object { $_.GetCommandName() -eq 'Write-ResultJson' }).Count) { $writers += $file.Name }
    }
    Assert-Format ($writers.Count -gt 30) 'All PowerShell result writers use the common formatter; fixture exceptions are explicit'
    $pythonFiles = @(Get-ChildItem $PSScriptRoot, "$root/tools" -Recurse -File -Filter '*.py')
    foreach ($file in $pythonFiles) {
        $source = [IO.File]::ReadAllText($file.FullName)
        $calls = @([regex]::Matches($source, 'json\.dumps?\s*\('))
        # The two benchmark drivers serialize dictionaries only to hash source
        # identity. Reader-facing JSON still uses the common result formatter.
        $expected = if ($file.Name -in @('compiled_programs.py', 'architecture_benchmark.py', 'result_json.py')) { 1 } else { 0 }
        if ($calls.Count -ne $expected) { throw "Unreviewed Python JSON serializer in $($file.Name)" }
    }
    Assert-Format ($true) 'Python result serialization is centralized; source fingerprint serialization is separate'
    $summary.powershell_files_checked = $files.Count
    $summary.python_files_checked = $pythonFiles.Count
    $summary.result_writers = $writers
    $summary.fixture_serializer_exceptions = @($rawSerializers.Keys | Sort-Object)
    $summary.status = 'pass'
} catch {
    $summary.status = 'fail'
    $summary.error_message = $_.Exception.Message
    throw
} finally {
    $summary.checks = $checks.ToArray()
    Write-ResultJson $summary $output
}
Write-Host "PASS: $($checks.Count) result-format checks; $($files.Count) PowerShell and $($pythonFiles.Count) Python files inspected"
