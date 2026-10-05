# Shared result JSON: two-space indentation, compact scalar arrays, UTF-8/LF.
# JSON values are serialized by PowerShell; this helper changes only whitespace.
function Format-ResultJsonText {
    param([string]$Json)
    $quoted = '"(?:\\.|[^"\\])*"'
    $depth = 0
    $lines = foreach ($line in ($Json -split '\r?\n')) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        $trimmed = [regex]::Replace($trimmed, "$quoted|:\s*", {
            param($match)
            if ($match.Value.StartsWith('"')) { return $match.Value }
            return ': '
        })
        $syntax = [regex]::Replace($trimmed, $quoted, '""')
        $leadingClose = if ($syntax -match '^[}\]]') { 1 } else { 0 }
        ('  ' * [math]::Max(0, $depth - $leadingClose)) + $trimmed
        $depth += ([regex]::Matches($syntax, '[{\[]').Count - [regex]::Matches($syntax, '[}\]]').Count)
    }
    $text = $lines -join "`n"
    $scalar = '(?:' + $quoted + '|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null)'
    $array = '\[\s*(?:' + $scalar + '(?:\s*,\s*' + $scalar + ')*)?\s*\]'
    # Match entire strings first so text such as "[1, 2]" is never reformatted.
    $text = [regex]::Replace($text, "$quoted|$array", {
        param($match)
        if (-not $match.Value.StartsWith('[')) { return $match.Value }
        $items = @([regex]::Matches($match.Value, $scalar) | ForEach-Object { $_.Value })
        $compact = '[' + ($items -join ', ') + ']'
        $lineStart = $text.LastIndexOf("`n", $match.Index) + 1
        if ($match.Index - $lineStart + $compact.Length -le 120) { return $compact }
        $indent = [regex]::Match($text.Substring($lineStart), '^ *').Value
        $rows = New-Object 'System.Collections.Generic.List[string]'
        $row = New-Object 'System.Collections.Generic.List[string]'
        foreach ($item in $items) {
            $candidate = (@($row) + $item) -join ', '
            if ($row.Count -gt 0 -and ($row.Count -eq 8 -or $indent.Length + 2 + $candidate.Length + 1 -gt 120)) {
                $rows.Add(($row -join ', '))
                $row.Clear()
            }
            $row.Add($item)
        }
        $rows.Add(($row -join ', '))
        return "[`n" + (($rows | ForEach-Object { $indent + '  ' + $_ }) -join ",`n") + "`n" + $indent + ']'
    })
    # ASCII escapes keep Unicode readable by JSON parsers on both PS 5.1 and 7,
    # without a BOM or dependence on the host's default text encoding.
    $text = [regex]::Replace($text, '[^\x00-\x7f]', {
        param($match)
        return '\u{0:x4}' -f [int][char]$match.Value
    })
    return $text + "`n"
}

function ConvertTo-ResultJson {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return "null`n" }
    # -InputObject preserves root arrays, including empty/single-item arrays.
    Format-ResultJsonText (ConvertTo-Json -InputObject $Value -Depth 24 -WarningAction Stop)
}

function Write-ResultJson {
    param([AllowNull()]$Value, [string]$Path)
    $text = ConvertTo-ResultJson $Value
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    [IO.File]::WriteAllText($resolved, $text, (New-Object Text.UTF8Encoding $false))
}
