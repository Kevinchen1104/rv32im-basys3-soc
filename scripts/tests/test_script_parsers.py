"""Exercise pure PowerShell helpers without launching hardware tools or a regression."""

import os
from pathlib import Path
import subprocess
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]


class ScriptParserTests(unittest.TestCase):
    def test_programming_preflight_does_not_claim_unprobed_tool_is_missing(self):
        self.run_powershell(r"""
$scripts = $PWD.Path
foreach ($name in @('vivado-basys3-program.ps1', 'xsdb-basys3-program.ps1')) {
    $summary = [IO.Path]::GetTempFileName()
    try {
        $ErrorActionPreference = 'Continue'
        $output = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scripts $name) `
            -DeviceSelector ' ' -DryRun -SummaryPath $summary 2>&1 | Out-String
        $ErrorActionPreference = 'Stop'
        if ($LASTEXITCODE -eq 0) { throw 'Invalid device selector accepted' }
        if ($output -notmatch 'not determined' -or $output -match ': unavailable') {
            throw 'Unprobed tool was reported unavailable'
        }
        $record = Get-Content -Raw $summary | ConvertFrom-Json
        if ($record.status -ne 'fail' -or $record.device_programmed) { throw 'Bad preflight status' }
    } finally {
        [IO.File]::Delete($summary)
    }
}
""")

    def test_checkpoint_cleanup_requires_explicit_scoped_selection(self):
        self.run_powershell(r"""
foreach ($arguments in @(
    @{ Category = 'RetiredCheckpoints' },
    @{ Category = 'RetiredCheckpoints'; RetiredBuildDirectory = @('build/vivado') },
    @{ Category = 'RetiredCheckpoints'; RetiredBuildDirectory = @('docs') }
)) {
    $rejected = $false
    try { & ./clean-artifacts.ps1 @arguments } catch { $rejected = $true }
    if (-not $rejected) { throw 'Unsafe checkpoint cleanup selection accepted' }
}
""")

    def run_powershell(self, body):
        # Import function definitions only, not the scripts' execution sections.
        setup = r"""
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
function Import-Functions([string]$Path, [string[]]$Names) {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors -join '; ') }
    foreach ($name in $Names) {
        $function = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        if (-not $function) { throw "Missing function: $name" }
        Set-Item -Path "Function:script:$name" -Value $function.Body.GetScriptBlock()
    }
}
"""
        environment = {key: value for key, value in os.environ.items() if key.upper() != "PSMODULEPATH"}
        result = subprocess.run(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", setup + body],
            cwd=SCRIPTS, capture_output=True, text=True, encoding='utf-8', errors='replace',
            timeout=30, env=environment)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_control_immediates_roundtrip_at_signed_boundaries(self):
        self.run_powershell(r"""
. ./reference-common.ps1
Import-Functions ./random-control-reference.ps1 @('Add-Entry', 'Add-Addi', 'Add-LoadImmediate')
foreach ($value in @(0L, 2047L, 2048L, 4095L, 2147483647L, 2147483648L, 4294965248L, 4294967295L)) {
    $script:entries = [Collections.Generic.List[object]]::new()
    Add-LoadImmediate 4 ([uint32]$value)
    $upper = $script:entries[0].imm
    $lower = $script:entries[1].imm
    if ($lower -lt -2048 -or $lower -gt 2047) { throw "ADDI out of range: $lower" }
    if ((To-UInt32 (([int64]$upper -shl 12) + $lower)) -ne $value) { throw "Wrong immediate: $value" }
}
""")

    def test_vendor_launcher_preserves_arguments_and_failure(self):
        self.run_powershell(r"""
. ./process-runner.ps1
$log = [IO.Path]::GetTempFileName()
try {
    $result = Invoke-LoggedVendorTool -FilePath (Get-Command powershell).Source `
        -Arguments @('-NoProfile', '-Command', "Write-Output 'a b & c'; exit 7") `
        -WorkingDirectory $PWD.Path -LogPath $log -TimeoutSeconds 10
    if ($result.status -ne 'failed' -or $result.exit_code -ne 7) { throw 'Tool failure lost' }
    if ((Get-Content -Raw $log) -notmatch 'a b & c') { throw 'Tool arguments changed' }
    $result = Invoke-LoggedVendorTool -FilePath 'missing-vendor-tool-12345.exe' `
        -Arguments @() -WorkingDirectory $PWD.Path -LogPath $log -TimeoutSeconds 10
    if ($result.status -eq 'passed') { throw 'Missing tool accepted' }
} finally {
    [IO.File]::Delete($log)
}
""")

    def test_signatures_need_valid_words_and_explicit_termination(self):
        self.run_powershell(r"""
Import-Functions ./arch-test-run.ps1 @('Compare-Signatures', 'Get-DutTerminationStatus')
$expected = [IO.Path]::GetTempFileName()
$actual = [IO.Path]::GetTempFileName()
try {
    foreach ($text in @('', 'not-a-word', '000000000')) {
        [IO.File]::WriteAllText($expected, $text)
        [IO.File]::WriteAllText($actual, $text)
        if ((Compare-Signatures $expected $actual).matched) { throw 'Invalid signature accepted' }
    }
    [IO.File]::WriteAllText($expected, "0123ABCD`n")
    [IO.File]::WriteAllText($actual, "0123abcd`n")
    if (-not (Compare-Signatures $expected $actual).matched) { throw 'Valid signatures rejected' }
    if ((Get-DutTerminationStatus '') -ne 'unknown') { throw 'Missing termination accepted' }
    if ((Get-DutTerminationStatus 'tohost pass observed') -ne 'pass_tohost') { throw 'Pass not recognized' }
} finally {
    [IO.File]::Delete($expected)
    [IO.File]::Delete($actual)
}
""")

    def test_vivado_decimals_are_independent_of_windows_locale(self):
        self.run_powershell(r"""
Import-Functions ./vivado-basys3-build.ps1 @('Read-TimingReportSummary', 'Read-ClockReport')
$report = [IO.Path]::GetTempFileName()
$oldCulture = [Threading.Thread]::CurrentThread.CurrentCulture
try {
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
    [IO.File]::WriteAllText($report, "WNS(ns) TNS(ns)`n0.306 0.000 0 100 -0.015 -1.250`n")
    $timing = Read-TimingReportSummary $report
    if ($timing.wns_ns -ne 0.306 -or $timing.whs_ns -ne -0.015 -or $timing.ths_ns -ne -1.25) {
        throw 'Timing report parsed using local decimal separator'
    }
    [IO.File]::WriteAllText($report, "name period frequency generated`nclk 9.500 105.263 false`n")
    $clock = @(Read-ClockReport $report)[0]
    if ($clock.period_ns -ne 9.5 -or $clock.frequency_mhz -ne 105.263) { throw 'Clock decimal mismatch' }
} finally {
    [Threading.Thread]::CurrentThread.CurrentCulture = $oldCulture
    [IO.File]::Delete($report)
}
""")

    def test_arch_report_rejects_alias_without_overwriting_input(self):
        self.run_powershell(r"""
$inputFile = [IO.Path]::GetTempFileName()
try {
    [IO.File]::WriteAllText($inputFile, '{"status":"passed"}')
    $before = [IO.File]::ReadAllText($inputFile)
    $rejected = $false
    try {
        & ./arch-test-report.ps1 -ResultsPath $inputFile -OutputPath $inputFile
    } catch {
        $rejected = $_.Exception.Message -like '*must not overwrite*'
    }
    if (-not $rejected) { throw 'Input/output alias was accepted' }
    if ([IO.File]::ReadAllText($inputFile) -ne $before) { throw 'Input was overwritten' }
} finally {
    [IO.File]::Delete($inputFile)
}
""")


if __name__ == "__main__":
    unittest.main()
