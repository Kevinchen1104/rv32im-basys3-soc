<#
Script: scripts\assembler-tests.ps1
Purpose: Runs focused tests for the repository-local assembly parser and encoder.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\assembler-tests.ps1
Outputs:
  Temporary assembler test sources and hex files under wave\assembler-tests.
Scope:
  Assembler unit evidence only; not a complete assembler or ISA proof.
Audience:
  Internal helper used by scripts\check.ps1.
#>
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$testRoot = Join-Path $repoRoot "wave\assembler-tests"
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null

function Expect-AssemblerFailure {
    param(
        [string]$Program,
        [string]$Source,
        [string]$ExpectedMessage
    )

    Set-Content -Path (Join-Path $testRoot "$Program.S") -Value $Source -Encoding Ascii
    Remove-Item -Path (Join-Path $testRoot "$Program.hex") -ErrorAction SilentlyContinue

    $failed = $false
    $actualMessage = ""

    try {
        & (Join-Path $PSScriptRoot "assemble.ps1") `
            -ProgramDirectory $testRoot `
            -Programs @($Program) `
            -Check
    } catch {
        $failed = $true
        $actualMessage = $_.Exception.Message
    }

    if (-not $failed) {
        throw "Expected assembler test '$Program' to fail"
    }

    if ($actualMessage -notlike "*$ExpectedMessage*") {
        throw "Assembler test '$Program' failed with unexpected message: $actualMessage"
    }

    Write-Host "PASS: assembler rejected $Program"
}

$pseudoSource = @'
nop
li t0, -1
mv t1, t0
ret
'@

$pseudoHex = @(
    "00000013",
    "fff00293",
    "00028313",
    "00008067"
)

$directiveSource = @'
.word 0x12345678
.byte 0x41
.string "B#\n" # comment outside the string
.align 2
.half 0x1234
'@

$directiveHex = @(
    "12345678",
    "0a234241",
    "00000000",
    "00001234"
)

Set-Content -Path (Join-Path $testRoot "pseudo_smoke.S") -Value $pseudoSource -Encoding Ascii
Set-Content -Path (Join-Path $testRoot "pseudo_smoke.hex") -Value $pseudoHex -Encoding Ascii
Set-Content -Path (Join-Path $testRoot "directive_smoke.S") -Value $directiveSource -Encoding Ascii
Set-Content -Path (Join-Path $testRoot "directive_smoke.hex") -Value $directiveHex -Encoding Ascii

& (Join-Path $PSScriptRoot "assemble.ps1") `
    -ProgramDirectory $testRoot `
    -Programs @("pseudo_smoke", "directive_smoke") `
    -Check

Expect-AssemblerFailure `
    -Program "bad_register" `
    -Source "addi bad, zero, 1" `
    -ExpectedMessage "expected an RV32I register name"

Expect-AssemblerFailure `
    -Program "unterminated_string" `
    -Source '.string "unterminated' `
    -ExpectedMessage "unterminated string literal"

Write-Host "PASS: assembler focused tests passed"
