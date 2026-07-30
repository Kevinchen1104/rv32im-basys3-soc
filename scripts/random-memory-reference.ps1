<#
Script: scripts\random-memory-reference.ps1
Purpose: Generates or checks deterministic random memory-operation reference fixtures.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\random-memory-reference.ps1 -Check -SkipSimulation
Outputs:
  fixtures\generated\reference\random_memory_reference* artifacts or freshness diagnostics.
Scope:
  Directed random-reference evidence only; not exhaustive verification.
Audience:
  Internal helper used by scripts\check.ps1.
#>
param(
    [int]$Seed = 2027,
    [int]$GeneratedMemoryOps = 48,
    [switch]$Check,
    [switch]$SkipSimulation
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$programPath = Join-Path $repoRoot "fixtures/generated/reference/random_memory_reference.hex"
$dmemInitPath = Join-Path $repoRoot "fixtures/generated/reference/random_memory_reference_dmem_init.hex"
$expectedRegsPath = Join-Path $repoRoot "fixtures/generated/reference/random_memory_reference_expected_regs.hex"
$expectedDmemPath = Join-Path $repoRoot "fixtures/generated/reference/random_memory_reference_expected_dmem.hex"
$expectedJsonPath = Join-Path $repoRoot "fixtures/generated/reference/random_memory_reference_expected.json"

function Normalize-TextForArtifactCompare {
    param([string]$Text)

    if ($null -eq $Text) {
        return ""
    }

    $normalized = $Text.TrimEnd()
    $normalized = $normalized -replace "`r`n", "`n"
    return ($normalized -replace "`r", "`n")
}

function Write-AsciiLfFile {
    param(
        [string]$Path,
        [AllowEmptyCollection()][object[]]$Value
    )

    $text = (@($Value | ForEach-Object { [string]$_ }) -join "`n")
    $text = $text -replace "`r`n", "`n"
    $text = $text -replace "`r", "`n"
    if (-not $text.EndsWith("`n")) {
        $text += "`n"
    }
    [System.IO.File]::WriteAllText($Path, $text, [System.Text.Encoding]::ASCII)
}

function To-UInt32 {
    param([int64]$Value)
    return [uint32]($Value -band 0xffffffffL)
}

function To-SInt32 {
    param([uint32]$Value)
    if (($Value -band 0x80000000) -ne 0) {
        return [int64]$Value - 4294967296L
    }
    return [int64]$Value
}

function Sign-Extend {
    param([uint32]$Value, [int]$Bits)
    $mask = [uint32]((1L -shl $Bits) - 1)
    $sign = [uint32](1L -shl ($Bits - 1))
    $masked = [uint32]($Value -band $mask)
    if (($masked -band $sign) -ne 0) {
        return To-UInt32 ([int64]$masked - (1L -shl $Bits))
    }
    return $masked
}

function Encode-RType {
    param([int]$Funct7, [int]$Rs2, [int]$Rs1, [int]$Funct3, [int]$Rd)
    return [uint32](([uint64]$Funct7 -shl 25) -bor
                    ([uint64]$Rs2 -shl 20) -bor
                    ([uint64]$Rs1 -shl 15) -bor
                    ([uint64]$Funct3 -shl 12) -bor
                    ([uint64]$Rd -shl 7) -bor [uint64]0x33)
}

function Encode-IType {
    param([int]$Immediate, [int]$Rs1, [int]$Funct3, [int]$Rd, [int]$Opcode)
    return [uint32](([uint64]($Immediate -band 0xfff) -shl 20) -bor
                    ([uint64]$Rs1 -shl 15) -bor
                    ([uint64]$Funct3 -shl 12) -bor
                    ([uint64]$Rd -shl 7) -bor [uint64]$Opcode)
}

function Encode-SType {
    param([int]$Immediate, [int]$Rs2, [int]$Rs1, [int]$Funct3)
    $imm = $Immediate -band 0xfff
    return [uint32](([uint64](($imm -shr 5) -band 0x7f) -shl 25) -bor
                    ([uint64]$Rs2 -shl 20) -bor
                    ([uint64]$Rs1 -shl 15) -bor
                    ([uint64]$Funct3 -shl 12) -bor
                    ([uint64]($imm -band 0x1f) -shl 7) -bor [uint64]0x23)
}

function Encode-UType {
    param([int]$Immediate, [int]$Rd)
    return [uint32](([uint64]($Immediate -band 0xfffff) -shl 12) -bor
                    ([uint64]$Rd -shl 7) -bor [uint64]0x37)
}

function Format-HexWord {
    param([uint32]$Value)
    return "{0:x8}" -f $Value
}

function Get-WidthBytes {
    param([string]$Op)
    switch ($Op) {
        { $_ -in @("lb", "lbu", "sb") } { return 1 }
        { $_ -in @("lh", "lhu", "sh") } { return 2 }
        { $_ -in @("lw", "sw") } { return 4 }
        default { throw "unknown memory op '$Op'" }
    }
}

function Test-IsLoadOp {
    param([string]$Op)
    return $Op -in @("lw", "lh", "lhu", "lb", "lbu")
}

function Fail-RandomMemoryReference {
    param([string]$Message)
    throw "random memory reference artifact check failed: $Message"
}

function Assert-Contains {
    param(
        [object[]]$Values,
        [string]$Expected,
        [string]$FieldName
    )

    if (@($Values) -notcontains $Expected) {
        Fail-RandomMemoryReference "$FieldName is missing '$Expected'"
    }
}

function Assert-ArtifactConsistency {
    param(
        [object]$Metadata,
        [string[]]$ProgramLines,
        [string[]]$InitialDmemLines,
        [string[]]$ExpectedRegLines,
        [string[]]$ExpectedDmemLines
    )

    if ($Metadata.program_words -ne $ProgramLines.Count) {
        Fail-RandomMemoryReference "program_words $($Metadata.program_words) does not match program hex line count $($ProgramLines.Count)"
    }
    if ($Metadata.initial_dmem_words -ne $InitialDmemLines.Count) {
        Fail-RandomMemoryReference "initial_dmem_words $($Metadata.initial_dmem_words) does not match DMemory init line count $($InitialDmemLines.Count)"
    }
    if ($Metadata.checked_dmem_words -ne $ExpectedDmemLines.Count) {
        Fail-RandomMemoryReference "checked_dmem_words $($Metadata.checked_dmem_words) does not match expected DMemory line count $($ExpectedDmemLines.Count)"
    }
    if ($ExpectedRegLines.Count -ne 32) {
        Fail-RandomMemoryReference "expected register file must contain 32 lines, got $($ExpectedRegLines.Count)"
    }
    if ($Metadata.generated_memory_ops -ne @($Metadata.operations).Count) {
        Fail-RandomMemoryReference "generated_memory_ops $($Metadata.generated_memory_ops) does not match operation count $(@($Metadata.operations).Count)"
    }

    foreach ($operation in @($Metadata.operations)) {
        if ($operation.affected_word_index -ge $Metadata.checked_dmem_words) {
            Fail-RandomMemoryReference "operation $($operation.index) affected word $($operation.affected_word_index), outside checked_dmem_words $($Metadata.checked_dmem_words)"
        }
    }

    Assert-Contains $Metadata.coverage "sw/lw" "coverage"
    Assert-Contains $Metadata.coverage "sb/lb/lbu" "coverage"
    Assert-Contains $Metadata.coverage "sh/lh/lhu" "coverage"
    Assert-Contains $Metadata.coverage "overlapping subword writes" "coverage"
    Assert-Contains $Metadata.coverage "load-after-store dependency" "coverage"
    Assert-Contains $Metadata.coverage "signed negative byte/halfword loads" "coverage"
    Assert-Contains $Metadata.coverage "unsigned byte/halfword zero extension" "coverage"
}

function Add-LoadImmediate {
    param(
        [System.Collections.Generic.List[uint32]]$Words,
        [uint32[]]$Registers,
        [int]$Rd,
        [uint32]$Value
    )

    $upper = [int]((([uint64]$Value + [uint64]0x800) -shr 12) -band [uint64]0xfffff)
    $base = To-UInt32 ([int64]$upper -shl 12)
    $lower = [int64]$Value - [int64]$base
    if ($lower -gt 2047) { $lower -= 4096 }
    if ($lower -lt -2048 -or $lower -gt 2047) {
        throw "cannot encode immediate load for $(Format-HexWord $Value)"
    }

    $Words.Add((Encode-UType $upper $Rd))
    $Registers[$Rd] = $base
    $Words.Add((Encode-IType ([int]$lower) $Rd 0 $Rd 0x13))
    $Registers[$Rd] = To-UInt32 ((To-SInt32 $Registers[$Rd]) + $lower)
}

function Read-Byte {
    param([byte[]]$Memory, [int]$Address)
    return [uint32]$Memory[$Address]
}

function Read-Half {
    param([byte[]]$Memory, [int]$Address)
    return [uint32](([uint32]$Memory[$Address]) -bor ([uint32]$Memory[$Address + 1] -shl 8))
}

function Read-Word {
    param([byte[]]$Memory, [int]$Address)
    return [uint32](([uint32]$Memory[$Address]) -bor
                    ([uint32]$Memory[$Address + 1] -shl 8) -bor
                    ([uint32]$Memory[$Address + 2] -shl 16) -bor
                    ([uint32]$Memory[$Address + 3] -shl 24))
}

function Write-Byte {
    param([byte[]]$Memory, [int]$Address, [uint32]$Value)
    $Memory[$Address] = [byte]($Value -band 0xff)
}

function Write-Half {
    param([byte[]]$Memory, [int]$Address, [uint32]$Value)
    Write-Byte -Memory $Memory -Address $Address -Value $Value
    Write-Byte -Memory $Memory -Address ($Address + 1) -Value ($Value -shr 8)
}

function Write-Word {
    param([byte[]]$Memory, [int]$Address, [uint32]$Value)
    Write-Byte -Memory $Memory -Address $Address -Value $Value
    Write-Byte -Memory $Memory -Address ($Address + 1) -Value ($Value -shr 8)
    Write-Byte -Memory $Memory -Address ($Address + 2) -Value ($Value -shr 16)
    Write-Byte -Memory $Memory -Address ($Address + 3) -Value ($Value -shr 24)
}

function Invoke-MemoryOp {
    param(
        [string]$Op,
        [int]$Address,
        [int64]$Value = 0
    )

    $value32 = To-UInt32 $Value
    $loadedValue = $null
    $script:memoryOpCount++

    switch ($Op) {
        "sw" {
            Add-LoadImmediate $script:words $script:registers 20 $value32
            $script:words.Add((Encode-SType $Address 20 0 2))
            Write-Word -Memory $script:memoryBytes -Address $Address -Value $value32
        }
        "sh" {
            Add-LoadImmediate $script:words $script:registers 20 $value32
            $script:words.Add((Encode-SType $Address 20 0 1))
            Write-Half -Memory $script:memoryBytes -Address $Address -Value $value32
        }
        "sb" {
            Add-LoadImmediate $script:words $script:registers 20 $value32
            $script:words.Add((Encode-SType $Address 20 0 0))
            Write-Byte -Memory $script:memoryBytes -Address $Address -Value $value32
        }
        "lw" {
            $loaded = Read-Word -Memory $script:memoryBytes -Address $Address
            $loadedValue = $loaded
            $script:words.Add((Encode-IType $Address 0 2 21 0x03))
            $script:registers[21] = $loaded
            $script:words.Add((Encode-RType 0 21 31 4 31))
            $script:registers[31] = To-UInt32 ($script:registers[31] -bxor $loaded)
        }
        "lh" {
            $loaded = Sign-Extend (Read-Half -Memory $script:memoryBytes -Address $Address) 16
            $loadedValue = $loaded
            $script:words.Add((Encode-IType $Address 0 1 21 0x03))
            $script:registers[21] = $loaded
            $script:words.Add((Encode-RType 0 21 31 4 31))
            $script:registers[31] = To-UInt32 ($script:registers[31] -bxor $loaded)
        }
        "lhu" {
            $loaded = Read-Half -Memory $script:memoryBytes -Address $Address
            $loadedValue = $loaded
            $script:words.Add((Encode-IType $Address 0 5 21 0x03))
            $script:registers[21] = $loaded
            $script:words.Add((Encode-RType 0 21 31 4 31))
            $script:registers[31] = To-UInt32 ($script:registers[31] -bxor $loaded)
        }
        "lb" {
            $loaded = Sign-Extend (Read-Byte -Memory $script:memoryBytes -Address $Address) 8
            $loadedValue = $loaded
            $script:words.Add((Encode-IType $Address 0 0 21 0x03))
            $script:registers[21] = $loaded
            $script:words.Add((Encode-RType 0 21 31 4 31))
            $script:registers[31] = To-UInt32 ($script:registers[31] -bxor $loaded)
        }
        "lbu" {
            $loaded = Read-Byte -Memory $script:memoryBytes -Address $Address
            $loadedValue = $loaded
            $script:words.Add((Encode-IType $Address 0 4 21 0x03))
            $script:registers[21] = $loaded
            $script:words.Add((Encode-RType 0 21 31 4 31))
            $script:registers[31] = To-UInt32 ($script:registers[31] -bxor $loaded)
        }
        default {
            throw "unknown memory op '$Op'"
        }
    }

    $script:registers[0] = [uint32]0
    $isLoad = Test-IsLoadOp $Op
    $script:operationRows += [pscustomobject]@{
        index = $script:memoryOpCount - 1
        op = $Op
        address = $Address
        width_bytes = Get-WidthBytes $Op
        store_value = if ($isLoad) { $null } else { Format-HexWord $value32 }
        loaded_value = if ($isLoad) { Format-HexWord $loadedValue } else { $null }
        checksum_after = Format-HexWord $script:registers[31]
        affected_word_index = $Address -shr 2
    }
}

$random = [System.Random]::new($Seed)
$script:registers = New-Object 'uint32[]' 32
$script:words = [System.Collections.Generic.List[uint32]]::new()
$script:memoryBytes = New-Object 'byte[]' 512
$script:operationRows = @()
$script:memoryOpCount = 0

for ($i = 0; $i -lt 32; $i++) {
    $script:registers[$i] = [uint32]$i
}
$script:registers[0] = [uint32]0

for ($wordIndex = 0; $wordIndex -lt 128; $wordIndex++) {
    Write-Word -Memory $script:memoryBytes -Address ($wordIndex * 4) -Value (To-UInt32 $random.Next())
}

$initialMemoryBytes = [byte[]]::new($script:memoryBytes.Length)
[array]::Copy($script:memoryBytes, $initialMemoryBytes, $script:memoryBytes.Length)

Add-LoadImmediate $script:words $script:registers 31 0

# Directed prefix: lock in the edge cases this flow is meant to guard.
Invoke-MemoryOp "sw" 16 0x11223344
Invoke-MemoryOp "lw" 16
Invoke-MemoryOp "sb" 17 0x000000ff
Invoke-MemoryOp "lb" 17
Invoke-MemoryOp "lbu" 17
Invoke-MemoryOp "sh" 18 0x000080ff
Invoke-MemoryOp "lh" 18
Invoke-MemoryOp "lhu" 18
Invoke-MemoryOp "lw" 16
Invoke-MemoryOp "sw" 32 0xa5a55a5a
Invoke-MemoryOp "lw" 32
Invoke-MemoryOp "sh" 34 0x00001234
Invoke-MemoryOp "lw" 32
Invoke-MemoryOp "sb" 35 0x00000080
Invoke-MemoryOp "lb" 35
Invoke-MemoryOp "lbu" 35
Invoke-MemoryOp "lw" 32

$ops = @("sw", "sh", "sb", "lw", "lh", "lhu", "lb", "lbu")
while ($script:memoryOpCount -lt $GeneratedMemoryOps) {
    $op = $ops[$random.Next(0, $ops.Count)]
    $address = $random.Next(0, 128)
    if ($op -in @("sw", "lw")) {
        $address = $address -band (-bnot 3)
    } elseif ($op -in @("sh", "lh", "lhu")) {
        $address = $address -band (-bnot 1)
    }

    $value = To-UInt32 (([int64]$random.Next() -shl 1) -bor $random.Next(0, 2))
    Invoke-MemoryOp $op $address $value
}

foreach ($evictAddress in @(256, 272, 288, 304)) {
    $script:words.Add((Encode-IType $evictAddress 0 2 0 0x03))
}

for ($i = 0; $i -lt 12; $i++) {
    $script:words.Add([uint32]0x00000013)
}

$programLines = @($script:words | ForEach-Object { Format-HexWord $_ })
$initialWords = for ($i = 0; $i -lt 128; $i++) { Format-HexWord (Read-Word -Memory $initialMemoryBytes -Address ($i * 4)) }
$expectedRegs = @($script:registers | ForEach-Object { Format-HexWord $_ })
$expectedDmem = for ($i = 0; $i -lt 32; $i++) { Format-HexWord (Read-Word -Memory $script:memoryBytes -Address ($i * 4)) }

$expectedObject = [ordered]@{
    seed = $Seed
    generated_memory_ops = $GeneratedMemoryOps
    program_words = $script:words.Count
    initial_dmem_words = 128
    checked_dmem_words = 32
    final_checksum_register = "x31"
    final_checksum = Format-HexWord $script:registers[31]
    coverage = @(
        "sw/lw",
        "sb/lb/lbu",
        "sh/lh/lhu",
        "overlapping subword writes",
        "load-after-store dependency",
        "signed negative byte/halfword loads",
        "unsigned byte/halfword zero extension"
    )
    operations = $script:operationRows
}
$expectedJson = $expectedObject | ConvertTo-Json -Depth 5

Assert-ArtifactConsistency $expectedObject $programLines $initialWords $expectedRegs $expectedDmem

if ($Check) {
    $existingProgram = if (Test-Path $programPath) { @(Get-Content $programPath) } else { @() }
    $existingDmemInit = if (Test-Path $dmemInitPath) { @(Get-Content $dmemInitPath) } else { @() }
    $existingRegs = if (Test-Path $expectedRegsPath) { @(Get-Content $expectedRegsPath) } else { @() }
    $existingDmem = if (Test-Path $expectedDmemPath) { @(Get-Content $expectedDmemPath) } else { @() }
    $existingJson = if (Test-Path $expectedJsonPath) { Get-Content -Raw $expectedJsonPath } else { "" }

    if ($existingJson -ne "") {
        $existingObject = $existingJson | ConvertFrom-Json
        Assert-ArtifactConsistency $existingObject $existingProgram $existingDmemInit $existingRegs $existingDmem
    }

    if (($programLines -join "`n") -ne ($existingProgram -join "`n")) {
        throw "Generated random memory reference program differs from fixtures/generated/reference/random_memory_reference.hex. Run scripts\random-memory-reference.ps1 to update it."
    }
    if (($initialWords -join "`n") -ne ($existingDmemInit -join "`n")) {
        throw "Generated random memory reference DMemory init differs from fixtures/generated/reference/random_memory_reference_dmem_init.hex. Run scripts\random-memory-reference.ps1 to update it."
    }
    if (($expectedRegs -join "`n") -ne ($existingRegs -join "`n")) {
        throw "Generated random memory reference registers differ from fixtures/generated/reference/random_memory_reference_expected_regs.hex. Run scripts\random-memory-reference.ps1 to update it."
    }
    if (($expectedDmem -join "`n") -ne ($existingDmem -join "`n")) {
        throw "Generated random memory reference DMemory differs from fixtures/generated/reference/random_memory_reference_expected_dmem.hex. Run scripts\random-memory-reference.ps1 to update it."
    }
    if ((Normalize-TextForArtifactCompare $expectedJson) -ne (Normalize-TextForArtifactCompare $existingJson)) {
        throw "Generated random memory reference metadata differs from fixtures/generated/reference/random_memory_reference_expected.json. Run scripts\random-memory-reference.ps1 to update it."
    }

    Write-Host "PASS: random memory reference artifacts match seed $Seed ($($script:words.Count) words, $GeneratedMemoryOps memory ops)"
} else {
    Write-AsciiLfFile -Path $programPath -Value $programLines
    Write-AsciiLfFile -Path $dmemInitPath -Value $initialWords
    Write-AsciiLfFile -Path $expectedRegsPath -Value $expectedRegs
    Write-AsciiLfFile -Path $expectedDmemPath -Value $expectedDmem
    Write-AsciiLfFile -Path $expectedJsonPath -Value $expectedJson
    Write-Host "Generated random memory reference artifacts with seed $Seed ($($script:words.Count) words, $GeneratedMemoryOps memory ops)"
}

if (-not $SkipSimulation) {
    & (Join-Path $PSScriptRoot "run.ps1") -Test random_memory_reference
}
