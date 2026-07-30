<#
Script: scripts\random-control-reference.ps1
Purpose: Generates or checks deterministic random control-flow reference fixtures.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\random-control-reference.ps1 -Check -SkipSimulation
Outputs:
  fixtures\generated\reference\random_control_reference* artifacts or freshness diagnostics.
Scope:
  Directed random-reference evidence only; not exhaustive verification.
Audience:
  Internal helper used by scripts\check.ps1.
#>
param(
    [int]$Seed = 2028,
    [switch]$Check,
    [switch]$SkipSimulation
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$programPath = Join-Path $repoRoot "fixtures/generated/reference/random_control_reference.hex"
$expectedRegsPath = Join-Path $repoRoot "fixtures/generated/reference/random_control_reference_expected_regs.hex"
$expectedDmemPath = Join-Path $repoRoot "fixtures/generated/reference/random_control_reference_expected_dmem.hex"
$expectedJsonPath = Join-Path $repoRoot "fixtures/generated/reference/random_control_reference_expected.json"

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

function Encode-BType {
    param([int]$Immediate, [int]$Rs2, [int]$Rs1, [int]$Funct3)
    $imm = $Immediate -band 0x1fff
    return [uint32](([uint64](($imm -shr 12) -band 0x1) -shl 31) -bor
                    ([uint64](($imm -shr 5) -band 0x3f) -shl 25) -bor
                    ([uint64]$Rs2 -shl 20) -bor
                    ([uint64]$Rs1 -shl 15) -bor
                    ([uint64]$Funct3 -shl 12) -bor
                    ([uint64](($imm -shr 1) -band 0xf) -shl 8) -bor
                    ([uint64](($imm -shr 11) -band 0x1) -shl 7) -bor [uint64]0x63)
}

function Encode-JType {
    param([int]$Immediate, [int]$Rd)
    $imm = $Immediate -band 0x1fffff
    return [uint32](([uint64](($imm -shr 20) -band 0x1) -shl 31) -bor
                    ([uint64](($imm -shr 1) -band 0x3ff) -shl 21) -bor
                    ([uint64](($imm -shr 11) -band 0x1) -shl 20) -bor
                    ([uint64](($imm -shr 12) -band 0xff) -shl 12) -bor
                    ([uint64]$Rd -shl 7) -bor [uint64]0x6f)
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

function Add-Entry {
    param([hashtable]$Entry)
    $script:entries.Add([pscustomobject]$Entry) | Out-Null
}

function Add-Label {
    param([string]$Name)
    Add-Entry @{ kind = "label"; label = $Name }
}

function Add-Addi {
    param([int]$Rd, [int]$Rs1, [int]$Immediate, [string]$Note = "")
    Add-Entry @{ kind = "addi"; rd = $Rd; rs1 = $Rs1; imm = $Immediate; note = $Note; wrong_path = $false }
}

function Add-Sw {
    param([int]$Rs2, [int]$Rs1, [int]$Immediate, [string]$Note = "")
    Add-Entry @{ kind = "sw"; rs2 = $Rs2; rs1 = $Rs1; imm = $Immediate; note = $Note; wrong_path = $false }
}

function Add-Branch {
    param([string]$Op, [int]$Rs1, [int]$Rs2, [string]$Target, [string]$Note = "")
    Add-Entry @{ kind = $Op; rs1 = $Rs1; rs2 = $Rs2; target = $Target; note = $Note; wrong_path = $false }
}

function Add-Jal {
    param([int]$Rd, [string]$Target, [string]$Note = "")
    Add-Entry @{ kind = "jal"; rd = $Rd; target = $Target; note = $Note; wrong_path = $false }
}

function Add-Jalr {
    param([int]$Rd, [int]$Rs1, [int]$Immediate, [string]$Note = "")
    Add-Entry @{ kind = "jalr"; rd = $Rd; rs1 = $Rs1; imm = $Immediate; note = $Note; wrong_path = $false }
}

function Add-LoadImmediate {
    param([int]$Rd, [uint32]$Value, [string]$Note = "")
    $signedValue = To-SInt32 $Value
    $upper = [int]((($signedValue + 0x800) -shr 12) -band 0xfffff)
    $base = [int64]$upper -shl 12
    $lower = $signedValue - $base
    if ($lower -gt 2047) { $lower -= 4096 }
    if ($lower -lt -2048) { $lower += 4096 }
    Add-Entry @{ kind = "lui"; rd = $Rd; imm = $upper; note = $Note; wrong_path = $false }
    Add-Addi $Rd $Rd ([int]$lower) $Note
}

function Get-BranchTaken {
    param([string]$Kind, [uint32]$A, [uint32]$B)
    switch ($Kind) {
        "beq"  { return $A -eq $B }
        "bne"  { return $A -ne $B }
        "blt"  { return (To-SInt32 $A) -lt (To-SInt32 $B) }
        "bge"  { return (To-SInt32 $A) -ge (To-SInt32 $B) }
        "bltu" { return $A -lt $B }
        "bgeu" { return $A -ge $B }
        default { throw "unknown branch kind '$Kind'" }
    }
}

function Fail-RandomControlReference {
    param([string]$Message)
    throw "random control reference artifact check failed: $Message"
}

function Assert-ArtifactConsistency {
    param(
        [object]$Metadata,
        [string[]]$ProgramLines,
        [string[]]$ExpectedRegs,
        [string[]]$ExpectedDmem
    )

    if ($Metadata.program_words -ne $ProgramLines.Count) {
        Fail-RandomControlReference "program_words $($Metadata.program_words) does not match program hex line count $($ProgramLines.Count)"
    }
    if ($ExpectedRegs.Count -ne 32) {
        Fail-RandomControlReference "expected register file must contain 32 lines, got $($ExpectedRegs.Count)"
    }
    if ($Metadata.checked_dmem_words -ne $ExpectedDmem.Count) {
        Fail-RandomControlReference "checked_dmem_words $($Metadata.checked_dmem_words) does not match expected DMemory line count $($ExpectedDmem.Count)"
    }
    if (@($Metadata.operations).Count -eq 0) {
        Fail-RandomControlReference "metadata must contain operation rows"
    }
    if ($Metadata.executed_instruction_count -ne @($Metadata.operations | Where-Object { $_.executed }).Count) {
        Fail-RandomControlReference "executed_instruction_count does not match executed operation rows"
    }
    $orders = @($Metadata.operations | Where-Object { $_.executed } | ForEach-Object { $_.execution_order } | Sort-Object)
    if ($orders.Count -ne $Metadata.executed_instruction_count) {
        Fail-RandomControlReference "execution order count does not match executed_instruction_count"
    }
    for ($i = 0; $i -lt $orders.Count; $i++) {
        if ($orders[$i] -ne $i) {
            Fail-RandomControlReference "execution_order values must be unique and contiguous from 0"
        }
    }
    if (-not @($Metadata.operations | Where-Object { $_.wrong_path -and -not $_.executed -and $null -ne $_.rd }).Count) {
        Fail-RandomControlReference "metadata must include at least one unexecuted wrong-path register write"
    }
    if (-not @($Metadata.operations | Where-Object { $_.wrong_path -and -not $_.executed -and $_.op -eq "sw" }).Count) {
        Fail-RandomControlReference "metadata must include at least one unexecuted wrong-path store"
    }
    foreach ($operation in @($Metadata.operations | Where-Object { $_.op -in @("beq", "bne", "blt", "bge", "bltu", "bgeu", "jal", "jalr") })) {
        if ($null -eq $operation.target) {
            Fail-RandomControlReference "control operation at static index $($operation.static_index) is missing target"
        }
        if ($null -eq $operation.expected_next_pc_if_executed) {
            Fail-RandomControlReference "control operation at static index $($operation.static_index) is missing expected_next_pc_if_executed"
        }
    }
    if ($Metadata.final_pc -ne $Metadata.done_pc) {
        Fail-RandomControlReference "final_pc $($Metadata.final_pc) does not match done_pc $($Metadata.done_pc)"
    }

    $requiredCoverage = @(
        "beq taken",
        "beq not taken",
        "bne taken",
        "bne not taken",
        "blt/bge signed branches",
        "bltu/bgeu unsigned branches",
        "jal wrong-path suppression",
        "jalr odd target alignment",
        "wrong-path register suppression",
        "wrong-path store suppression"
    )

    foreach ($coverage in $requiredCoverage) {
        if (@($Metadata.coverage) -notcontains $coverage) {
            Fail-RandomControlReference "coverage is missing '$coverage'"
        }
    }
}

$random = [System.Random]::new($Seed)
$script:entries = [System.Collections.Generic.List[object]]::new()

$equalValue = $random.Next(3, 17)
$differentValue = $equalValue + $random.Next(1, 5)
$signedNegative = To-UInt32 (-$random.Next(3, 12))
$signedPositive = [uint32]$random.Next(1, 9)
$unsignedHigh = To-UInt32 0xfffffff0
$unsignedLow = [uint32]$random.Next(1, 10)

Add-Label "start"
Add-Addi 31 0 0 "checksum = 0"
Add-Addi 1 0 $equalValue "x1 = equal operand"
Add-Addi 2 0 $equalValue "x2 = equal operand"
Add-Addi 3 0 $differentValue "x3 = different operand"
Add-LoadImmediate 4 $signedNegative "x4 = signed negative operand"
Add-Addi 5 0 ([int]$signedPositive) "x5 = signed positive operand"
Add-LoadImmediate 6 $unsignedHigh "x6 = unsigned high operand"
Add-Addi 7 0 ([int]$unsignedLow) "x7 = unsigned low operand"
Add-LoadImmediate 12 0x0badc0de "x12 = wrong-path store data"

Add-Branch "beq" 1 2 "beq_taken_target" "beq taken skips wrong-path register/store"
Add-Addi 10 0 101 "wrong-path beq register write"
Add-Sw 12 0 28 "wrong-path beq store"
Add-Label "beq_taken_target"
Add-Addi 31 31 1 "checksum beq taken"

Add-Branch "beq" 1 3 "beq_not_taken_bad_target" "beq not taken"
Add-Addi 31 31 2 "checksum beq not taken"
Add-Jal 0 "after_beq_not_taken_bad_target" "skip bad target after beq not taken"
Add-Label "beq_not_taken_bad_target"
Add-Addi 10 0 102 "unreachable beq not-taken target"
Add-Label "after_beq_not_taken_bad_target"

Add-Branch "bne" 1 3 "bne_taken_target" "bne taken"
Add-Addi 10 0 103 "wrong-path bne taken register write"
Add-Label "bne_taken_target"
Add-Addi 31 31 4 "checksum bne taken"

Add-Branch "bne" 1 2 "bne_not_taken_bad_target" "bne not taken"
Add-Addi 31 31 8 "checksum bne not taken"
Add-Jal 0 "after_bne_not_taken_bad_target" "skip bad target after bne not taken"
Add-Label "bne_not_taken_bad_target"
Add-Addi 10 0 104 "unreachable bne not-taken target"
Add-Label "after_bne_not_taken_bad_target"

Add-Branch "blt" 4 5 "blt_taken_target" "signed blt taken"
Add-Addi 10 0 105 "wrong-path signed blt"
Add-Label "blt_taken_target"
Add-Addi 31 31 16 "checksum signed blt taken"

Add-Branch "bge" 5 4 "bge_taken_target" "signed bge taken"
Add-Addi 10 0 106 "wrong-path signed bge"
Add-Label "bge_taken_target"
Add-Addi 31 31 32 "checksum signed bge taken"

Add-Branch "bltu" 7 6 "bltu_taken_target" "unsigned bltu taken"
Add-Addi 10 0 107 "wrong-path unsigned bltu"
Add-Label "bltu_taken_target"
Add-Addi 31 31 64 "checksum unsigned bltu taken"

Add-Branch "bgeu" 6 7 "bgeu_taken_target" "unsigned bgeu taken"
Add-Addi 10 0 108 "wrong-path unsigned bgeu"
Add-Label "bgeu_taken_target"
Add-Addi 31 31 128 "checksum unsigned bgeu taken"

Add-Jal 8 "jal_target" "jal skips wrong-path writes and store"
Add-Addi 10 0 109 "wrong-path jal register write"
Add-Sw 12 0 28 "wrong-path jal store"
Add-Label "jal_target"
Add-Addi 31 31 256 "checksum jal target"

Add-LoadImmediate 13 0 "materialize odd jalr target"
Add-Jalr 9 13 0 "jalr clears bit 0 of odd target"
Add-Addi 10 0 110 "wrong-path jalr register write"
Add-Sw 12 0 28 "wrong-path jalr store"
Add-Label "jalr_target"
Add-Addi 31 31 512 "checksum jalr target"
Add-Jal 0 "done" "skip trailing wrong-path block"
Add-Label "never_reached"
Add-Addi 10 0 111 "unreachable final block"
Add-Label "done"

for ($i = 0; $i -lt 12; $i++) {
    Add-Addi 0 0 0 "trailing nop"
}

$pc = 0
$labels = @{}
$instructionEntries = @()
foreach ($entry in $script:entries) {
    if ($entry.kind -eq "label") {
        $labels[$entry.label] = $pc
    } else {
        $instructionEntries += $entry
        $pc += 4
    }
}

foreach ($entry in $instructionEntries) {
    if ($entry.kind -eq "lui" -and $entry.note -eq "materialize odd jalr target") {
        $target = [uint32]($labels["jalr_target"] + 1)
        $signedTarget = To-SInt32 $target
        $entry.imm = [int]((($signedTarget + 0x800) -shr 12) -band 0xfffff)
    } elseif ($entry.kind -eq "addi" -and $entry.note -eq "materialize odd jalr target") {
        $target = [uint32]($labels["jalr_target"] + 1)
        $signedTarget = To-SInt32 $target
        $upper = [int]((($signedTarget + 0x800) -shr 12) -band 0xfffff)
        $base = [int64]$upper -shl 12
        $lower = $signedTarget - $base
        if ($lower -gt 2047) { $lower -= 4096 }
        if ($lower -lt -2048) { $lower += 4096 }
        $entry.imm = [int]$lower
    }
}

$words = [System.Collections.Generic.List[uint32]]::new()
$operations = [System.Collections.Generic.List[object]]::new()
$entryByPc = @{}
$donePc = [int]$labels["done"]
$pc = 0
$index = 0
foreach ($entry in $instructionEntries) {
    $word = [uint32]0
    $kind = [string]$entry.kind
    $targetPc = $null
    $rd = $null

    switch ($kind) {
        "lui" {
            $word = Encode-UType $entry.imm $entry.rd
            $rd = $entry.rd
        }
        "addi" {
            $word = Encode-IType $entry.imm $entry.rs1 0 $entry.rd 0x13
            $rd = $entry.rd
        }
        "sw" {
            $word = Encode-SType $entry.imm $entry.rs2 $entry.rs1 2
        }
        { $_ -in @("beq", "bne", "blt", "bge", "bltu", "bgeu") } {
            $targetPc = [int]$labels[$entry.target]
            $offset = $targetPc - $pc
            $funct3 = @{ beq = 0; bne = 1; blt = 4; bge = 5; bltu = 6; bgeu = 7 }[$kind]
            $word = Encode-BType $offset $entry.rs2 $entry.rs1 $funct3
        }
        "jal" {
            $targetPc = [int]$labels[$entry.target]
            $offset = $targetPc - $pc
            $word = Encode-JType $offset $entry.rd
            $rd = $entry.rd
        }
        "jalr" {
            $word = Encode-IType $entry.imm $entry.rs1 0 $entry.rd 0x67
            $rd = $entry.rd
        }
        default {
            throw "unknown entry kind '$kind'"
        }
    }

    $words.Add($word)
    $row = [ordered]@{
        static_index = $index
        pc = Format-HexWord ([uint32]$pc)
        instruction = Format-HexWord $word
        kind = if ($kind -in @("beq", "bne", "blt", "bge", "bltu", "bgeu")) { "branch" } else { $kind }
        op = $kind
        note = $entry.note
        expected_next_pc_if_executed = if ($kind -eq "jal") { Format-HexWord ([uint32]$targetPc) } elseif ($kind -in @("beq", "bne", "blt", "bge", "bltu", "bgeu", "jalr")) { $null } else { Format-HexWord ([uint32]($pc + 4)) }
        executed = $false
        execution_order = $null
        taken = $null
        target = if ($null -eq $targetPc) { $null } else { Format-HexWord ([uint32]$targetPc) }
        rd = $rd
        write_value = $null
        store_address = $null
        store_value = $null
        checksum_after_if_executed = $null
        wrong_path = ($entry.note -like "wrong-path*" -or $entry.note -like "unreachable*")
    }
    $operations.Add($row) | Out-Null
    $entryByPc[$pc] = [pscustomobject]@{
        entry = $entry
        row = $row
    }

    $pc += 4
    $index++
}

$registers = New-Object 'uint32[]' 32
$dmem = New-Object 'uint32[]' 8
for ($i = 0; $i -lt 32; $i++) {
    $registers[$i] = [uint32]$i
}
$registers[0] = [uint32]0
$dmem[7] = [uint32]0x1234abcd

$pc = 0
$executionOrder = 0
$maxSteps = $words.Count * 4
while ($pc -ne $donePc) {
    if ($executionOrder -ge $maxSteps) {
        throw "random control reference interpreter exceeded max_steps=$maxSteps"
    }
    if (-not $entryByPc.ContainsKey($pc)) {
        throw ("random control reference interpreter reached PC outside program: {0}" -f (Format-HexWord ([uint32]$pc)))
    }

    $current = $entryByPc[$pc]
    $entry = $current.entry
    $row = $current.row
    $kind = [string]$entry.kind
    $nextPc = $pc + 4
    $targetPc = $null
    $taken = $null
    $writeValue = $null
    $storeAddress = $null
    $storeValue = $null

    switch ($kind) {
        "lui" {
            $writeValue = To-UInt32 ([int64]$entry.imm -shl 12)
            if ($entry.rd -ne 0) {
                $registers[$entry.rd] = $writeValue
            }
        }
        "addi" {
            $writeValue = To-UInt32 ((To-SInt32 $registers[$entry.rs1]) + $entry.imm)
            if ($entry.rd -ne 0) {
                $registers[$entry.rd] = $writeValue
            }
        }
        "sw" {
            $storeAddress = [int](To-UInt32 ((To-SInt32 $registers[$entry.rs1]) + $entry.imm))
            $storeValue = $registers[$entry.rs2]
            if (($storeAddress % 4) -eq 0 -and ($storeAddress / 4) -lt $dmem.Count) {
                $dmem[$storeAddress / 4] = $storeValue
            }
        }
        { $_ -in @("beq", "bne", "blt", "bge", "bltu", "bgeu") } {
            $targetPc = [int]$labels[$entry.target]
            $taken = Get-BranchTaken $kind $registers[$entry.rs1] $registers[$entry.rs2]
            if ($taken) {
                $nextPc = $targetPc
            }
        }
        "jal" {
            $targetPc = [int]$labels[$entry.target]
            $writeValue = [uint32]($pc + 4)
            if ($entry.rd -ne 0) {
                $registers[$entry.rd] = $writeValue
            }
            $taken = $true
            $nextPc = $targetPc
        }
        "jalr" {
            $targetPc = [int](($registers[$entry.rs1] + $entry.imm) -band 0xfffffffe)
            $writeValue = [uint32]($pc + 4)
            if ($entry.rd -ne 0) {
                $registers[$entry.rd] = $writeValue
            }
            $taken = $true
            $nextPc = $targetPc
        }
        default {
            throw "unknown entry kind '$kind'"
        }
    }

    $registers[0] = [uint32]0
    $row["executed"] = $true
    $row["execution_order"] = $executionOrder
    $row["taken"] = $taken
    $row["target"] = if ($null -eq $targetPc) { $row["target"] } else { Format-HexWord ([uint32]$targetPc) }
    $row["expected_next_pc_if_executed"] = Format-HexWord ([uint32]$nextPc)
    $row["write_value"] = if ($null -eq $writeValue) { $null } else { Format-HexWord $writeValue }
    $row["store_address"] = if ($null -eq $storeAddress) { $null } else { Format-HexWord ([uint32]$storeAddress) }
    $row["store_value"] = if ($null -eq $storeValue) { $null } else { Format-HexWord $storeValue }
    $row["checksum_after_if_executed"] = Format-HexWord $registers[31]

    $pc = $nextPc
    $executionOrder++
}

$hexLines = @($words | ForEach-Object { Format-HexWord $_ })
$expectedRegs = @($registers | ForEach-Object { Format-HexWord $_ })
$expectedDmem = @($dmem | ForEach-Object { Format-HexWord $_ })
$expectedObject = [ordered]@{
    seed = $Seed
    program_words = $words.Count
    executed_instruction_count = $executionOrder
    max_steps = $maxSteps
    checked_dmem_words = $dmem.Count
    done_pc = Format-HexWord ([uint32]$donePc)
    final_pc = Format-HexWord ([uint32]$pc)
    final_checksum_register = "x31"
    final_checksum = Format-HexWord $registers[31]
    sentinel_word_index = 7
    sentinel_expected = Format-HexWord $dmem[7]
    coverage = @(
        "beq taken",
        "beq not taken",
        "bne taken",
        "bne not taken",
        "blt/bge signed branches",
        "bltu/bgeu unsigned branches",
        "jal wrong-path suppression",
        "jalr odd target alignment",
        "wrong-path register suppression",
        "wrong-path store suppression"
    )
    operations = $operations
}
$expectedJson = $expectedObject | ConvertTo-Json -Depth 5

Assert-ArtifactConsistency $expectedObject $hexLines $expectedRegs $expectedDmem

if ($Check) {
    $existingHex = if (Test-Path $programPath) { @(Get-Content $programPath) } else { @() }
    $existingRegs = if (Test-Path $expectedRegsPath) { @(Get-Content $expectedRegsPath) } else { @() }
    $existingDmem = if (Test-Path $expectedDmemPath) { @(Get-Content $expectedDmemPath) } else { @() }
    $existingJson = if (Test-Path $expectedJsonPath) { Get-Content -Raw $expectedJsonPath } else { "" }

    if ($existingJson -ne "") {
        Assert-ArtifactConsistency ($existingJson | ConvertFrom-Json) $existingHex $existingRegs $existingDmem
    }
    if (($hexLines -join "`n") -ne ($existingHex -join "`n")) {
        throw "Generated random control reference program differs from fixtures/generated/reference/random_control_reference.hex. Run scripts\random-control-reference.ps1 to update it."
    }
    if (($expectedRegs -join "`n") -ne ($existingRegs -join "`n")) {
        throw "Generated random control reference registers differ from fixtures/generated/reference/random_control_reference_expected_regs.hex. Run scripts\random-control-reference.ps1 to update it."
    }
    if (($expectedDmem -join "`n") -ne ($existingDmem -join "`n")) {
        throw "Generated random control reference DMemory differs from fixtures/generated/reference/random_control_reference_expected_dmem.hex. Run scripts\random-control-reference.ps1 to update it."
    }
    if ((Normalize-TextForArtifactCompare $expectedJson) -ne (Normalize-TextForArtifactCompare $existingJson)) {
        throw "Generated random control reference metadata differs from fixtures/generated/reference/random_control_reference_expected.json. Run scripts\random-control-reference.ps1 to update it."
    }
    Write-Host "PASS: random control reference artifacts match seed $Seed ($($words.Count) words)"
} else {
    Write-AsciiLfFile -Path $programPath -Value $hexLines
    Write-AsciiLfFile -Path $expectedRegsPath -Value $expectedRegs
    Write-AsciiLfFile -Path $expectedDmemPath -Value $expectedDmem
    Write-AsciiLfFile -Path $expectedJsonPath -Value $expectedJson
    Write-Host "Generated random control reference artifacts with seed $Seed ($($words.Count) words)"
}

if (-not $SkipSimulation) {
    & (Join-Path $PSScriptRoot "run.ps1") -Test random_control_reference
}
