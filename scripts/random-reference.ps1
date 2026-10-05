<#
Script: scripts\random-reference.ps1
Purpose: Generates or checks the baseline deterministic random instruction reference fixture.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\random-reference.ps1 -Check -SkipSimulation
Outputs:
  fixtures\generated\reference\random_reference* artifacts or freshness diagnostics.
#>
param(
    [int]$Seed = 1104,
    [int]$InstructionCount = 96,
    [switch]$Check,
    [switch]$SkipSimulation
)

. "$PSScriptRoot/reference-common.ps1"
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$hexPath = Join-Path $repoRoot "fixtures/generated/reference/random_reference.hex"
$expectedPath = Join-Path $repoRoot "fixtures/generated/reference/random_reference_expected.hex"

function Encode-UType {
    param([int]$Immediate, [int]$Rd, [int]$Opcode)
    return [uint32](([uint64]($Immediate -band 0xfffff) -shl 12) -bor
                    ([uint64]$Rd -shl 7) -bor [uint64]$Opcode)
}

$random = [System.Random]::new($Seed)
$registers = New-Object 'uint32[]' 32
$words = [System.Collections.Generic.List[uint32]]::new()

for ($i = 1; $i -le 31; $i++) {
    $upper = $random.Next(0, 0x100000)
    $lower = $random.Next(-2048, 2048)
    $words.Add((Encode-UType $upper $i 0x37))
    $registers[$i] = To-UInt32 ([int64]$upper -shl 12)
    $words.Add((Encode-IType $lower $i 0 $i 0x13))
    $registers[$i] = To-UInt32 ((To-SInt32 $registers[$i]) + $lower)
}

$rOps = @("add", "sub", "xor", "or", "and", "sll", "srl", "sra", "slt", "sltu")
$iOps = @("addi", "xori", "ori", "andi", "slti", "sltiu", "slli", "srli", "srai")

for ($instructionIndex = 0; $instructionIndex -lt $InstructionCount; $instructionIndex++) {
    $rd = $random.Next(1, 32)
    $rs1 = $random.Next(0, 32)
    $useRType = ($random.Next(0, 2) -eq 0)

    if ($useRType) {
        $rs2 = $random.Next(0, 32)
        $op = $rOps[$random.Next(0, $rOps.Count)]
        $funct3 = 0
        $funct7 = 0
        $result = [uint32]0

        switch ($op) {
            "add"  { $funct3 = 0; $result = To-UInt32 ((To-SInt32 $registers[$rs1]) + (To-SInt32 $registers[$rs2])) }
            "sub"  { $funct3 = 0; $funct7 = 0x20; $result = To-UInt32 ((To-SInt32 $registers[$rs1]) - (To-SInt32 $registers[$rs2])) }
            "sll"  { $funct3 = 1; $result = To-UInt32 ([uint64]$registers[$rs1] -shl [int]($registers[$rs2] -band 0x1f)) }
            "slt"  { $funct3 = 2; $result = if ((To-SInt32 $registers[$rs1]) -lt (To-SInt32 $registers[$rs2])) { [uint32]1 } else { [uint32]0 } }
            "sltu" { $funct3 = 3; $result = if ($registers[$rs1] -lt $registers[$rs2]) { [uint32]1 } else { [uint32]0 } }
            "xor"  { $funct3 = 4; $result = To-UInt32 ($registers[$rs1] -bxor $registers[$rs2]) }
            "srl"  { $funct3 = 5; $result = To-UInt32 ([uint32]$registers[$rs1] -shr [int]($registers[$rs2] -band 0x1f)) }
            "sra"  { $funct3 = 5; $funct7 = 0x20; $result = To-UInt32 ((To-SInt32 $registers[$rs1]) -shr [int]($registers[$rs2] -band 0x1f)) }
            "or"   { $funct3 = 6; $result = To-UInt32 ($registers[$rs1] -bor $registers[$rs2]) }
            "and"  { $funct3 = 7; $result = To-UInt32 ($registers[$rs1] -band $registers[$rs2]) }
        }

        $words.Add((Encode-RType $funct7 $rs2 $rs1 $funct3 $rd))
        $registers[$rd] = $result
    } else {
        $op = $iOps[$random.Next(0, $iOps.Count)]
        $funct3 = 0
        $immediate = 0
        $result = [uint32]0

        switch ($op) {
            "addi"  { $funct3 = 0; $immediate = $random.Next(-2048, 2048); $result = To-UInt32 ((To-SInt32 $registers[$rs1]) + $immediate) }
            "slti"  { $funct3 = 2; $immediate = $random.Next(-2048, 2048); $result = if ((To-SInt32 $registers[$rs1]) -lt $immediate) { [uint32]1 } else { [uint32]0 } }
            "sltiu" { $funct3 = 3; $immediate = $random.Next(-2048, 2048); $result = if ($registers[$rs1] -lt (To-UInt32 $immediate)) { [uint32]1 } else { [uint32]0 } }
            "xori"  { $funct3 = 4; $immediate = $random.Next(-2048, 2048); $result = To-UInt32 ($registers[$rs1] -bxor (To-UInt32 $immediate)) }
            "ori"   { $funct3 = 6; $immediate = $random.Next(-2048, 2048); $result = To-UInt32 ($registers[$rs1] -bor (To-UInt32 $immediate)) }
            "andi"  { $funct3 = 7; $immediate = $random.Next(-2048, 2048); $result = To-UInt32 ($registers[$rs1] -band (To-UInt32 $immediate)) }
            "slli"  { $funct3 = 1; $immediate = $random.Next(0, 32); $result = To-UInt32 ([uint64]$registers[$rs1] -shl $immediate) }
            "srli"  { $funct3 = 5; $immediate = $random.Next(0, 32); $result = To-UInt32 ([uint32]$registers[$rs1] -shr $immediate) }
            "srai"  { $funct3 = 5; $immediate = 0x400 + $random.Next(0, 32); $result = To-UInt32 ((To-SInt32 $registers[$rs1]) -shr ($immediate -band 0x1f)) }
        }

        $words.Add((Encode-IType $immediate $rs1 $funct3 $rd 0x13))
        $registers[$rd] = $result
    }

    $registers[0] = [uint32]0
}

for ($i = 0; $i -lt 12; $i++) {
    $words.Add([uint32]0x00000013)
}

$hexLines = @($words | ForEach-Object { Format-HexWord $_ })
$expectedLines = @($registers | ForEach-Object { Format-HexWord $_ })

if ($Check) {
    $existingHex = if (Test-Path $hexPath) { @(Get-Content $hexPath) } else { @() }
    $existingExpected = if (Test-Path $expectedPath) { @(Get-Content $expectedPath) } else { @() }
    if (($hexLines -join "`n") -ne ($existingHex -join "`n")) {
        throw "Generated random reference program differs from fixtures/generated/reference/random_reference.hex. Run scripts\random-reference.ps1 to update it."
    }
    if (($expectedLines -join "`n") -ne ($existingExpected -join "`n")) {
        throw "Generated random reference expected registers differ from fixtures/generated/reference/random_reference_expected.hex. Run scripts\random-reference.ps1 to update it."
    }
    Write-Host "PASS: random reference image matches seed $Seed ($($words.Count) words)"
} else {
    Set-Content -Path $hexPath -Value $hexLines -Encoding Ascii
    Set-Content -Path $expectedPath -Value $expectedLines -Encoding Ascii
    Write-Host "Generated fixtures/generated/reference/random_reference.hex and fixtures/generated/reference/random_reference_expected.hex with seed $Seed"
}

if (-not $SkipSimulation) {
    & (Join-Path $PSScriptRoot "run.ps1") -Test random_reference
}
