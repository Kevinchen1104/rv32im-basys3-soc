<#
Script: scripts\random-hazard-reference.ps1
Purpose: Generates or checks deterministic random pipeline-hazard reference fixtures.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\random-hazard-reference.ps1 -Check -SkipSimulation
Outputs:
  fixtures\generated\reference\random_hazard_reference* artifacts or freshness diagnostics.
#>
param(
    [int]$Seed = 2029,
    [switch]$Check,
    [switch]$SkipSimulation,
    [string]$ArtifactDirectory = "fixtures/generated/reference"
)

. "$PSScriptRoot/reference-common.ps1"
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
if (-not [IO.Path]::IsPathRooted($ArtifactDirectory)) { $ArtifactDirectory = Join-Path $repoRoot $ArtifactDirectory }
New-Item -ItemType Directory -Force -Path $ArtifactDirectory | Out-Null

$programPath = Join-Path $ArtifactDirectory "random_hazard_reference.hex"
$dmemInitPath = Join-Path $ArtifactDirectory "random_hazard_reference_dmem_init.hex"
$expectedRegsPath = Join-Path $ArtifactDirectory "random_hazard_reference_expected_regs.hex"
$expectedDmemPath = Join-Path $ArtifactDirectory "random_hazard_reference_expected_dmem.hex"
$expectedJsonPath = Join-Path $ArtifactDirectory "random_hazard_reference_expected.json"

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

function Write-Word {
    param([byte[]]$Memory, [int]$Address, [uint32]$Value)
    Write-Byte -Memory $Memory -Address $Address -Value $Value
    Write-Byte -Memory $Memory -Address ($Address + 1) -Value ($Value -shr 8)
    Write-Byte -Memory $Memory -Address ($Address + 2) -Value ($Value -shr 16)
    Write-Byte -Memory $Memory -Address ($Address + 3) -Value ($Value -shr 24)
}

function Add-Entry {
    param([hashtable]$Entry)
    if (-not $Entry.ContainsKey("hazard_tags")) {
        $Entry.hazard_tags = @()
    }
    $script:entries.Add([pscustomobject]$Entry) | Out-Null
}

function Add-Label {
    param([string]$Name)
    Add-Entry @{ kind = "label"; label = $Name }
}

function Add-Addi {
    param([int]$Rd, [int]$Rs1, [int]$Immediate, [string]$Note, [string[]]$HazardTags = @())
    Add-Entry @{ kind = "addi"; rd = $Rd; rs1 = $Rs1; imm = $Immediate; note = $Note; hazard_tags = $HazardTags }
}

function Add-RTypeOp {
    param([string]$Op, [int]$Rd, [int]$Rs1, [int]$Rs2, [string]$Note, [string[]]$HazardTags = @())
    Add-Entry @{ kind = $Op; rd = $Rd; rs1 = $Rs1; rs2 = $Rs2; note = $Note; hazard_tags = $HazardTags }
}

function Add-Lw {
    param([int]$Rd, [int]$Rs1, [int]$Immediate, [string]$Note, [string[]]$HazardTags = @())
    Add-Entry @{ kind = "lw"; rd = $Rd; rs1 = $Rs1; imm = $Immediate; note = $Note; hazard_tags = $HazardTags }
}

function Add-Sw {
    param([int]$Rs2, [int]$Rs1, [int]$Immediate, [string]$Note, [string[]]$HazardTags = @())
    Add-Entry @{ kind = "sw"; rs2 = $Rs2; rs1 = $Rs1; imm = $Immediate; note = $Note; hazard_tags = $HazardTags }
}

function Add-Branch {
    param([string]$Op, [int]$Rs1, [int]$Rs2, [string]$Target, [string]$Note, [string[]]$HazardTags = @())
    Add-Entry @{ kind = $Op; rs1 = $Rs1; rs2 = $Rs2; target = $Target; note = $Note; hazard_tags = $HazardTags }
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

function Fail-RandomHazardReference {
    param([string]$Message)
    throw "random hazard reference artifact check failed: $Message"
}

function Assert-Contains {
    param([object[]]$Values, [string]$Expected, [string]$FieldName)
    if (@($Values) -notcontains $Expected) {
        Fail-RandomHazardReference "$FieldName is missing '$Expected'"
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
        Fail-RandomHazardReference "program_words $($Metadata.program_words) does not match program hex line count $($ProgramLines.Count)"
    }
    if ($Metadata.initial_dmem_words -ne $InitialDmemLines.Count) {
        Fail-RandomHazardReference "initial_dmem_words $($Metadata.initial_dmem_words) does not match DMemory init line count $($InitialDmemLines.Count)"
    }
    if ($Metadata.checked_dmem_words -ne $ExpectedDmemLines.Count) {
        Fail-RandomHazardReference "checked_dmem_words $($Metadata.checked_dmem_words) does not match expected DMemory line count $($ExpectedDmemLines.Count)"
    }
    if ($ExpectedRegLines.Count -ne 32) {
        Fail-RandomHazardReference "expected register file must contain 32 lines, got $($ExpectedRegLines.Count)"
    }
    if ($Metadata.executed_instruction_count -ne @($Metadata.operations | Where-Object { $_.executed }).Count) {
        Fail-RandomHazardReference "executed_instruction_count does not match executed operation rows"
    }
    $orders = @($Metadata.operations | Where-Object { $_.executed } | ForEach-Object { $_.execution_order } | Sort-Object)
    for ($i = 0; $i -lt $orders.Count; $i++) {
        if ($orders[$i] -ne $i) {
            Fail-RandomHazardReference "execution_order values must be unique and contiguous from 0"
        }
    }
    if ($Metadata.final_pc -ne $Metadata.done_pc) {
        Fail-RandomHazardReference "final_pc $($Metadata.final_pc) does not match done_pc $($Metadata.done_pc)"
    }

    $requiredCoverage = @(
        "load-use dependency",
        "ALU-to-ALU forwarding",
        "ALU-to-store-data forwarding",
        "load-to-store-data dependency",
        "branch operand forwarding",
        "branch-after-load",
        "taken branch wrong-path register suppression",
        "taken branch wrong-path store suppression",
        "not-taken branch fallthrough",
        "final checksum"
    )

    foreach ($coverage in $requiredCoverage) {
        Assert-Contains $Metadata.coverage $coverage "coverage"
    }

    $allHazardTags = @($Metadata.operations | ForEach-Object { $_.hazard_tags } | ForEach-Object { $_ })
    foreach ($tag in @("load_use", "alu_forwarding", "store_data_forwarding", "load_to_store", "branch_forwarding", "branch_after_load", "wrong_path_register", "wrong_path_store")) {
        Assert-Contains $allHazardTags $tag "hazard_tags"
    }
    if (-not @($Metadata.operations | Where-Object { @($_.hazard_tags) -contains "wrong_path_register" -and -not $_.executed }).Count) {
        Fail-RandomHazardReference "metadata must include an unexecuted wrong-path register row"
    }
    if (-not @($Metadata.operations | Where-Object { @($_.hazard_tags) -contains "wrong_path_store" -and -not $_.executed }).Count) {
        Fail-RandomHazardReference "metadata must include an unexecuted wrong-path store row"
    }
}

$random = [System.Random]::new($Seed)
$script:entries = [System.Collections.Generic.List[object]]::new()

$loadValue = [uint32]$random.Next(17, 48)
$offsetA = [int]$random.Next(3, 9)
$offsetB = [int]$random.Next(5, 12)
$wrongStoreValue = [uint32]0x3de

Add-Label "start"
Add-Addi 31 0 0 "checksum = 0"
Add-Addi 1 0 0 "x1 = DMemory base"
Add-Addi 2 0 ([int]$wrongStoreValue) "wrong-path store data setup"
Add-Lw 5 1 0 "load source for load-use dependency"
Add-RTypeOp "add" 6 5 5 "load-use add consumes x5 immediately" @("load_use")
Add-Addi 7 6 $offsetA "ALU-to-ALU forwarding into addi" @("alu_forwarding")
Add-RTypeOp "sub" 8 7 5 "ALU result forwarded into sub" @("alu_forwarding")
Add-Addi 9 8 $offsetB "producer for store-data forwarding"
Add-Sw 9 1 4 "store consumes just-produced ALU result" @("store_data_forwarding")
Add-Lw 10 1 4 "load stored ALU result"
Add-Sw 10 1 8 "store consumes just-loaded value" @("load_to_store")
Add-Addi 11 10 1 "load result forwarded into addi" @("load_use")
Add-Addi 12 11 -1 "producer for branch operand forwarding"
Add-Branch "beq" 12 10 "branch_forward_taken" "branch consumes forwarded ALU result" @("branch_forwarding")
Add-Addi 13 0 13 "wrong-path register after branch-forwarding branch" @("wrong_path_register")
Add-Sw 2 1 12 "wrong-path store after branch-forwarding branch" @("wrong_path_store")
Add-Label "branch_forward_taken"
Add-Addi 31 31 1 "checksum branch forwarding"
Add-Lw 14 1 8 "load source for branch-after-load"
Add-Branch "beq" 14 10 "branch_after_load_taken" "branch consumes just-loaded value" @("branch_after_load")
Add-Addi 15 0 15 "wrong-path register after branch-after-load" @("wrong_path_register")
Add-Sw 2 1 12 "wrong-path store after branch-after-load" @("wrong_path_store")
Add-Label "branch_after_load_taken"
Add-Addi 31 31 2 "checksum branch-after-load"
Add-Branch "bne" 14 10 "not_taken_bad_target" "not-taken branch falls through" @("branch_forwarding")
Add-Addi 31 31 4 "checksum not-taken fallthrough"
Add-Branch "beq" 0 0 "after_not_taken_bad_target" "skip bad target"
Add-Label "not_taken_bad_target"
Add-Addi 16 0 16 "unreachable not-taken target" @("wrong_path_register")
Add-Label "after_not_taken_bad_target"
Add-RTypeOp "xor" 17 6 9 "mixed ALU dependency"
Add-RTypeOp "or" 18 17 31 "forwarded XOR into OR" @("alu_forwarding")
Add-RTypeOp "and" 19 18 10 "forwarded OR into AND" @("alu_forwarding")
Add-Sw 19 1 16 "store final mixed result"
Add-Lw 0 1 256 "evict dirty cache line 0"
Add-Lw 0 1 272 "evict dirty cache line 1"
Add-Addi 30 0 0x7ab "completion marker"
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

$words = [System.Collections.Generic.List[uint32]]::new()
$operations = [System.Collections.Generic.List[object]]::new()
$entryByPc = @{}
$donePc = [int]$labels["done"]
$pc = 0
$index = 0
foreach ($entry in $instructionEntries) {
    $kind = [string]$entry.kind
    $word = [uint32]0
    $targetPc = $null
    $rd = $null

    switch ($kind) {
        "addi" {
            $word = Encode-IType $entry.imm $entry.rs1 0 $entry.rd 0x13
            $rd = $entry.rd
        }
        "lw" {
            $word = Encode-IType $entry.imm $entry.rs1 2 $entry.rd 0x03
            $rd = $entry.rd
        }
        "sw" {
            $word = Encode-SType $entry.imm $entry.rs2 $entry.rs1 2
        }
        "add" {
            $word = Encode-RType 0 $entry.rs2 $entry.rs1 0 $entry.rd
            $rd = $entry.rd
        }
        "sub" {
            $word = Encode-RType 0x20 $entry.rs2 $entry.rs1 0 $entry.rd
            $rd = $entry.rd
        }
        "xor" {
            $word = Encode-RType 0 $entry.rs2 $entry.rs1 4 $entry.rd
            $rd = $entry.rd
        }
        "or" {
            $word = Encode-RType 0 $entry.rs2 $entry.rs1 6 $entry.rd
            $rd = $entry.rd
        }
        "and" {
            $word = Encode-RType 0 $entry.rs2 $entry.rs1 7 $entry.rd
            $rd = $entry.rd
        }
        { $_ -in @("beq", "bne", "blt", "bge", "bltu", "bgeu") } {
            $targetPc = [int]$labels[$entry.target]
            $offset = $targetPc - $pc
            $funct3 = @{ beq = 0; bne = 1; blt = 4; bge = 5; bltu = 6; bgeu = 7 }[$kind]
            $word = Encode-BType $offset $entry.rs2 $entry.rs1 $funct3
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
        kind = if ($kind -in @("beq", "bne", "blt", "bge", "bltu", "bgeu")) { "branch" } elseif ($kind -in @("add", "sub", "xor", "or", "and")) { "alu" } else { $kind }
        op = $kind
        note = $entry.note
        executed = $false
        execution_order = $null
        expected_next_pc_if_executed = if ($null -eq $targetPc) { Format-HexWord ([uint32]($pc + 4)) } else { $null }
        taken = $null
        target = if ($null -eq $targetPc) { $null } else { Format-HexWord ([uint32]$targetPc) }
        rd = $rd
        write_value = $null
        load_address = $null
        loaded_value = $null
        store_address = $null
        store_value = $null
        hazard_tags = @($entry.hazard_tags)
        checksum_after_if_executed = $null
    }
    $operations.Add($row) | Out-Null
    $entryByPc[$pc] = [pscustomobject]@{ entry = $entry; row = $row }
    $pc += 4
    $index++
}

$registers = New-Object 'uint32[]' 32
$memoryBytes = New-Object 'byte[]' 512
for ($i = 0; $i -lt 32; $i++) {
    $registers[$i] = [uint32]$i
}
$registers[0] = [uint32]0
for ($wordIndex = 0; $wordIndex -lt 128; $wordIndex++) {
    Write-Word -Memory $memoryBytes -Address ($wordIndex * 4) -Value (To-UInt32 $random.Next())
}
Write-Word -Memory $memoryBytes -Address 0 -Value $loadValue
Write-Word -Memory $memoryBytes -Address 4 -Value 0
Write-Word -Memory $memoryBytes -Address 8 -Value 0
Write-Word -Memory $memoryBytes -Address 12 -Value 0x1234abcd
Write-Word -Memory $memoryBytes -Address 16 -Value 0

$initialMemoryBytes = [byte[]]::new($memoryBytes.Length)
[array]::Copy($memoryBytes, $initialMemoryBytes, $memoryBytes.Length)

$pc = 0
$executionOrder = 0
$maxSteps = $words.Count * 4
while ($pc -ne $donePc) {
    if ($executionOrder -ge $maxSteps) {
        throw "random hazard reference interpreter exceeded max_steps=$maxSteps"
    }
    if (-not $entryByPc.ContainsKey($pc)) {
        throw ("random hazard reference interpreter reached PC outside program: {0}" -f (Format-HexWord ([uint32]$pc)))
    }

    $current = $entryByPc[$pc]
    $entry = $current.entry
    $row = $current.row
    $kind = [string]$entry.kind
    $nextPc = $pc + 4
    $targetPc = $null
    $taken = $null
    $writeValue = $null
    $loadAddress = $null
    $loadedValue = $null
    $storeAddress = $null
    $storeValue = $null

    switch ($kind) {
        "addi" {
            $writeValue = To-UInt32 ((To-SInt32 $registers[$entry.rs1]) + $entry.imm)
            if ($entry.rd -ne 0) { $registers[$entry.rd] = $writeValue }
        }
        "lw" {
            $loadAddress = [int](To-UInt32 ((To-SInt32 $registers[$entry.rs1]) + $entry.imm))
            $loadedValue = Read-Word -Memory $memoryBytes -Address $loadAddress
            $writeValue = $loadedValue
            if ($entry.rd -ne 0) { $registers[$entry.rd] = $loadedValue }
        }
        "sw" {
            $storeAddress = [int](To-UInt32 ((To-SInt32 $registers[$entry.rs1]) + $entry.imm))
            $storeValue = $registers[$entry.rs2]
            Write-Word -Memory $memoryBytes -Address $storeAddress -Value $storeValue
        }
        "add" {
            $writeValue = To-UInt32 ([int64]$registers[$entry.rs1] + [int64]$registers[$entry.rs2])
            if ($entry.rd -ne 0) { $registers[$entry.rd] = $writeValue }
        }
        "sub" {
            $writeValue = To-UInt32 ([int64]$registers[$entry.rs1] - [int64]$registers[$entry.rs2])
            if ($entry.rd -ne 0) { $registers[$entry.rd] = $writeValue }
        }
        "xor" {
            $writeValue = To-UInt32 ($registers[$entry.rs1] -bxor $registers[$entry.rs2])
            if ($entry.rd -ne 0) { $registers[$entry.rd] = $writeValue }
        }
        "or" {
            $writeValue = To-UInt32 ($registers[$entry.rs1] -bor $registers[$entry.rs2])
            if ($entry.rd -ne 0) { $registers[$entry.rd] = $writeValue }
        }
        "and" {
            $writeValue = To-UInt32 ($registers[$entry.rs1] -band $registers[$entry.rs2])
            if ($entry.rd -ne 0) { $registers[$entry.rd] = $writeValue }
        }
        { $_ -in @("beq", "bne", "blt", "bge", "bltu", "bgeu") } {
            $targetPc = [int]$labels[$entry.target]
            $taken = Get-BranchTaken $kind $registers[$entry.rs1] $registers[$entry.rs2]
            if ($taken) { $nextPc = $targetPc }
        }
        default {
            throw "unknown entry kind '$kind'"
        }
    }

    $registers[0] = [uint32]0
    $row["executed"] = $true
    $row["execution_order"] = $executionOrder
    $row["expected_next_pc_if_executed"] = Format-HexWord ([uint32]$nextPc)
    $row["taken"] = $taken
    $row["target"] = if ($null -eq $targetPc) { $row["target"] } else { Format-HexWord ([uint32]$targetPc) }
    $row["write_value"] = if ($null -eq $writeValue) { $null } else { Format-HexWord $writeValue }
    $row["load_address"] = if ($null -eq $loadAddress) { $null } else { Format-HexWord ([uint32]$loadAddress) }
    $row["loaded_value"] = if ($null -eq $loadedValue) { $null } else { Format-HexWord $loadedValue }
    $row["store_address"] = if ($null -eq $storeAddress) { $null } else { Format-HexWord ([uint32]$storeAddress) }
    $row["store_value"] = if ($null -eq $storeValue) { $null } else { Format-HexWord $storeValue }
    $row["checksum_after_if_executed"] = Format-HexWord $registers[31]

    $pc = $nextPc
    $executionOrder++
}

$programLines = @($words | ForEach-Object { Format-HexWord $_ })
$initialWords = for ($i = 0; $i -lt 128; $i++) { Format-HexWord (Read-Word -Memory $initialMemoryBytes -Address ($i * 4)) }
$expectedRegs = @($registers | ForEach-Object { Format-HexWord $_ })
$expectedDmem = for ($i = 0; $i -lt 32; $i++) { Format-HexWord (Read-Word -Memory $memoryBytes -Address ($i * 4)) }

$expectedObject = [ordered]@{
    seed = $Seed
    program_words = $words.Count
    executed_instruction_count = $executionOrder
    max_steps = $maxSteps
    initial_dmem_words = 128
    checked_dmem_words = 32
    done_pc = Format-HexWord ([uint32]$donePc)
    final_pc = Format-HexWord ([uint32]$pc)
    completion_register = "x30"
    completion_value = Format-HexWord $registers[30]
    final_checksum_register = "x31"
    final_checksum = Format-HexWord $registers[31]
    sentinel_word_index = 3
    sentinel_expected = Format-HexWord (Read-Word -Memory $memoryBytes -Address 12)
    coverage = @(
        "load-use dependency",
        "ALU-to-ALU forwarding",
        "ALU-to-store-data forwarding",
        "load-to-store-data dependency",
        "branch operand forwarding",
        "branch-after-load",
        "taken branch wrong-path register suppression",
        "taken branch wrong-path store suppression",
        "not-taken branch fallthrough",
        "final checksum"
    )
    operations = $operations
}
$expectedJson = $expectedObject | ConvertTo-Json -Depth 6

Assert-ArtifactConsistency $expectedObject $programLines $initialWords $expectedRegs $expectedDmem

if ($Check) {
    $existingProgram = if (Test-Path $programPath) { @(Get-Content $programPath) } else { @() }
    $existingDmemInit = if (Test-Path $dmemInitPath) { @(Get-Content $dmemInitPath) } else { @() }
    $existingRegs = if (Test-Path $expectedRegsPath) { @(Get-Content $expectedRegsPath) } else { @() }
    $existingDmem = if (Test-Path $expectedDmemPath) { @(Get-Content $expectedDmemPath) } else { @() }
    $existingJson = if (Test-Path $expectedJsonPath) { Get-Content -Raw $expectedJsonPath } else { "" }

    if ($existingJson -ne "") {
        Assert-ArtifactConsistency ($existingJson | ConvertFrom-Json) $existingProgram $existingDmemInit $existingRegs $existingDmem
    }
    if (($programLines -join "`n") -ne ($existingProgram -join "`n")) {
        throw "Generated random hazard reference program differs from fixtures/generated/reference/random_hazard_reference.hex. Run scripts\random-hazard-reference.ps1 to update it."
    }
    if (($initialWords -join "`n") -ne ($existingDmemInit -join "`n")) {
        throw "Generated random hazard reference DMemory init differs from fixtures/generated/reference/random_hazard_reference_dmem_init.hex. Run scripts\random-hazard-reference.ps1 to update it."
    }
    if (($expectedRegs -join "`n") -ne ($existingRegs -join "`n")) {
        throw "Generated random hazard reference registers differ from fixtures/generated/reference/random_hazard_reference_expected_regs.hex. Run scripts\random-hazard-reference.ps1 to update it."
    }
    if (($expectedDmem -join "`n") -ne ($existingDmem -join "`n")) {
        throw "Generated random hazard reference DMemory differs from fixtures/generated/reference/random_hazard_reference_expected_dmem.hex. Run scripts\random-hazard-reference.ps1 to update it."
    }
    if ((Normalize-TextForArtifactCompare $expectedJson) -ne (Normalize-TextForArtifactCompare $existingJson)) {
        throw "Generated random hazard reference metadata differs from fixtures/generated/reference/random_hazard_reference_expected.json. Run scripts\random-hazard-reference.ps1 to update it."
    }
    Write-Host "PASS: random hazard reference artifacts match seed $Seed ($($words.Count) words)"
} else {
    Write-AsciiLfFile -Path $programPath -Value $programLines
    Write-AsciiLfFile -Path $dmemInitPath -Value $initialWords
    Write-AsciiLfFile -Path $expectedRegsPath -Value $expectedRegs
    Write-AsciiLfFile -Path $expectedDmemPath -Value $expectedDmem
    Write-AsciiLfFile -Path $expectedJsonPath -Value $expectedJson
    Write-Host "Generated random hazard reference artifacts with seed $Seed ($($words.Count) words)"
}

if (-not $SkipSimulation) {
    & (Join-Path $PSScriptRoot "run.ps1") -Test random_hazard_reference -SkipAssemble -PlusArgs "+fixture_dir=`"$ArtifactDirectory`" +program_words=$($words.Count)"
}
