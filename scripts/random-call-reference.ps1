<#
Script: scripts\random-call-reference.ps1
Purpose: Generates or checks deterministic random call/return reference fixtures.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\random-call-reference.ps1 -Check -SkipSimulation
Outputs:
  fixtures\generated\reference\random_call_reference* artifacts or freshness diagnostics.
#>
param(
    [int]$Seed = 2030,
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

$programPath = Join-Path $ArtifactDirectory "random_call_reference.hex"
$dmemInitPath = Join-Path $ArtifactDirectory "random_call_reference_dmem_init.hex"
$expectedRegsPath = Join-Path $ArtifactDirectory "random_call_reference_expected_regs.hex"
$expectedDmemPath = Join-Path $ArtifactDirectory "random_call_reference_expected_dmem.hex"
$expectedJsonPath = Join-Path $ArtifactDirectory "random_call_reference_expected.json"

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

function Add-Jal {
    param([int]$Rd, [string]$Target, [string]$Note, [string[]]$HazardTags = @())
    Add-Entry @{ kind = "jal"; rd = $Rd; target = $Target; note = $Note; hazard_tags = $HazardTags }
}

function Add-Jalr {
    param([int]$Rd, [int]$Rs1, [int]$Immediate, [string]$Note, [string[]]$HazardTags = @())
    Add-Entry @{ kind = "jalr"; rd = $Rd; rs1 = $Rs1; imm = $Immediate; note = $Note; hazard_tags = $HazardTags }
}

function Get-BranchTaken {
    param([string]$Kind, [uint32]$A, [uint32]$B)
    switch ($Kind) {
        "beq" { return $A -eq $B }
        "bne" { return $A -ne $B }
        default { throw "unknown branch kind '$Kind'" }
    }
}

function Fail-RandomCallReference {
    param([string]$Message)
    throw "random call reference artifact check failed: $Message"
}

function Assert-Contains {
    param([object[]]$Values, [string]$Expected, [string]$FieldName)
    if (@($Values) -notcontains $Expected) {
        Fail-RandomCallReference "$FieldName is missing '$Expected'"
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
        Fail-RandomCallReference "program_words $($Metadata.program_words) does not match program hex line count $($ProgramLines.Count)"
    }
    if ($Metadata.initial_dmem_words -ne $InitialDmemLines.Count) {
        Fail-RandomCallReference "initial_dmem_words $($Metadata.initial_dmem_words) does not match DMemory init line count $($InitialDmemLines.Count)"
    }
    if ($Metadata.checked_dmem_words -ne $ExpectedDmemLines.Count) {
        Fail-RandomCallReference "checked_dmem_words $($Metadata.checked_dmem_words) does not match expected DMemory line count $($ExpectedDmemLines.Count)"
    }
    if ($ExpectedRegLines.Count -ne 32) {
        Fail-RandomCallReference "expected register file must contain 32 lines, got $($ExpectedRegLines.Count)"
    }
    if ($ExpectedRegLines[0] -ne "00000000") {
        Fail-RandomCallReference "x0 expected line must be zero"
    }
    if ($ExpectedRegLines[2] -ne $Metadata.expected_stack_pointer) {
        Fail-RandomCallReference "x2 stack pointer was not restored to expected_stack_pointer"
    }
    if ($ExpectedRegLines[30] -ne $Metadata.completion_value) {
        Fail-RandomCallReference "x30 does not contain completion marker: expected $($Metadata.completion_value), got $($ExpectedRegLines[30])"
    }
    if ($Metadata.executed_instruction_count -ne @($Metadata.operations | Where-Object { $_.executed }).Count) {
        Fail-RandomCallReference "executed_instruction_count does not match executed operation rows"
    }
    $orders = @($Metadata.operations | Where-Object { $_.executed } | ForEach-Object { $_.execution_order } | Sort-Object)
    for ($i = 0; $i -lt $orders.Count; $i++) {
        if ($orders[$i] -ne $i) {
            Fail-RandomCallReference "execution_order values must be unique and contiguous from 0"
        }
    }
    if ($Metadata.final_pc -ne $Metadata.done_pc) {
        Fail-RandomCallReference "final_pc $($Metadata.final_pc) does not match done_pc $($Metadata.done_pc)"
    }

    foreach ($coverage in @(
        "jal_call",
        "jalr_return",
        "nested_call",
        "stack_store_load",
        "return_address_link",
        "wrong_path_register_suppression",
        "wrong_path_store_suppression",
        "final_completion_marker"
    )) {
        Assert-Contains $Metadata.coverage $coverage "coverage"
    }

    $allTags = @($Metadata.operations | ForEach-Object { $_.hazard_tags } | ForEach-Object { $_ })
    foreach ($tag in @("call", "return", "nested_call", "stack", "wrong_path_register", "wrong_path_store")) {
        Assert-Contains $allTags $tag "hazard_tags"
    }
    if (-not @($Metadata.operations | Where-Object { @($_.hazard_tags) -contains "wrong_path_register" -and -not $_.executed }).Count) {
        Fail-RandomCallReference "metadata must include an unexecuted wrong-path register row"
    }
    if (-not @($Metadata.operations | Where-Object { @($_.hazard_tags) -contains "wrong_path_store" -and -not $_.executed }).Count) {
        Fail-RandomCallReference "metadata must include an unexecuted wrong-path store row"
    }
}

$random = [System.Random]::new($Seed)
$script:entries = [System.Collections.Generic.List[object]]::new()

$argA = $random.Next(5, 12)
$argB = $random.Next(3, 9)
$calleeOffset = $random.Next(2, 6)
$wrongStoreValue = [int]0x3de
$initialSp = 64

Add-Label "start"
Add-Addi 2 0 $initialSp "initialize stack pointer" @("stack")
Add-Addi 31 0 0 "checksum = 0"
Add-Addi 20 0 $wrongStoreValue "wrong-path store data setup"
Add-Jal 1 "func_a" "main calls func_a" @("call")
Add-Addi 31 31 8 "caller resumed after nested call returns" @("return")
Add-Sw 10 0 0 "store returned result"
Add-Sw 2 0 4 "store restored stack pointer" @("stack")
Add-Sw 1 0 8 "store main return address" @("return_address_link")
Add-Lw 0 0 256 "evict dirty low memory line"
Add-Lw 0 0 272 "evict dirty stack line"
Add-Lw 0 0 288 "evict alternate dirty stack line"
Add-Lw 0 0 304 "evict second alternate dirty stack line"
Add-Branch "beq" 10 10 "complete" "taken branch skips final wrong path"
Add-Addi 22 0 222 "wrong-path register after final branch" @("wrong_path_register")
Add-Sw 20 0 12 "wrong-path store after final branch" @("wrong_path_store")
Add-Label "complete"
Add-Addi 30 0 0x7ac "completion marker" @("final_completion_marker")
Add-Branch "beq" 0 0 "done" "skip function bodies after completion"

Add-Label "func_a"
Add-Addi 2 2 -8 "func_a stack frame push" @("stack")
Add-Sw 1 2 4 "func_a saves ra" @("stack", "return_address_link")
Add-Addi 5 0 $argA "func_a argument A"
Add-Addi 6 5 $argB "func_a ALU dependency"
Add-Sw 6 2 0 "func_a stores local value" @("stack")
Add-Lw 7 2 0 "func_a reloads local value" @("stack")
Add-RTypeOp "add" 8 7 5 "func_a load-use ALU dependency"
Add-Jal 1 "func_b" "func_a nested call to func_b" @("call", "nested_call")
Add-Lw 1 2 4 "func_a restores ra" @("stack", "return_address_link")
Add-Addi 2 2 8 "func_a stack frame pop" @("stack")
Add-RTypeOp "add" 10 8 11 "func_a combines nested return value"
Add-Jalr 0 1 0 "func_a returns to main" @("return")
Add-Addi 23 0 123 "wrong-path register after func_a return" @("wrong_path_register")
Add-Sw 20 0 12 "wrong-path store after func_a return" @("wrong_path_store")

Add-Label "func_b"
Add-Addi 2 2 -8 "func_b stack frame push" @("stack", "nested_call")
Add-Sw 1 2 4 "func_b saves ra" @("stack", "return_address_link")
Add-Addi 11 8 $calleeOffset "func_b ALU dependency"
Add-Sw 11 2 0 "func_b stores local value" @("stack")
Add-Lw 13 2 0 "func_b reloads local value" @("stack")
Add-RTypeOp "sub" 11 13 5 "func_b load-use subtract dependency"
Add-Lw 1 2 4 "func_b restores ra" @("stack", "return_address_link")
Add-Addi 2 2 8 "func_b stack frame pop" @("stack")
Add-Jalr 0 1 0 "func_b returns to func_a" @("return", "nested_call")
Add-Addi 24 0 124 "wrong-path register after func_b return" @("wrong_path_register")
Add-Sw 20 0 12 "wrong-path store after func_b return" @("wrong_path_store")

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
        { $_ -in @("beq", "bne") } {
            $targetPc = [int]$labels[$entry.target]
            $offset = $targetPc - $pc
            $funct3 = @{ beq = 0; bne = 1 }[$kind]
            $word = Encode-BType $offset $entry.rs2 $entry.rs1 $funct3
        }
        "jal" {
            $targetPc = [int]$labels[$entry.target]
            $word = Encode-JType ($targetPc - $pc) $entry.rd
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
        kind = if ($kind -in @("beq", "bne")) { "branch" } elseif ($kind -in @("add", "sub")) { "alu" } else { $kind }
        op = $kind
        note = $entry.note
        executed = $false
        execution_order = $null
        expected_next_pc_if_executed = if ($null -eq $targetPc -and $kind -ne "jalr") { Format-HexWord ([uint32]($pc + 4)) } else { $null }
        taken = $null
        target = if ($null -eq $targetPc) { $null } else { Format-HexWord ([uint32]$targetPc) }
        rd = $rd
        write_value = $null
        link_register_value = $null
        stack_pointer_value = $null
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
Write-Word -Memory $memoryBytes -Address 0 -Value 0
Write-Word -Memory $memoryBytes -Address 4 -Value 0
Write-Word -Memory $memoryBytes -Address 8 -Value 0
Write-Word -Memory $memoryBytes -Address 12 -Value 0x1234abcd
Write-Word -Memory $memoryBytes -Address 56 -Value 0
Write-Word -Memory $memoryBytes -Address 60 -Value 0

$initialMemoryBytes = [byte[]]::new($memoryBytes.Length)
[array]::Copy($memoryBytes, $initialMemoryBytes, $memoryBytes.Length)

$pc = 0
$executionOrder = 0
$maxSteps = $words.Count * 4
while ($pc -ne $donePc) {
    if ($executionOrder -ge $maxSteps) {
        throw "random call reference interpreter exceeded max_steps=$maxSteps"
    }
    if (-not $entryByPc.ContainsKey($pc)) {
        throw ("random call reference interpreter reached PC outside program: {0}" -f (Format-HexWord ([uint32]$pc)))
    }

    $current = $entryByPc[$pc]
    $entry = $current.entry
    $row = $current.row
    $kind = [string]$entry.kind
    $nextPc = $pc + 4
    $targetPc = $null
    $taken = $null
    $writeValue = $null
    $linkValue = $null
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
        { $_ -in @("beq", "bne") } {
            $targetPc = [int]$labels[$entry.target]
            $taken = Get-BranchTaken $kind $registers[$entry.rs1] $registers[$entry.rs2]
            if ($taken) { $nextPc = $targetPc }
        }
        "jal" {
            $targetPc = [int]$labels[$entry.target]
            $linkValue = [uint32]($pc + 4)
            $writeValue = $linkValue
            if ($entry.rd -ne 0) { $registers[$entry.rd] = $linkValue }
            $taken = $true
            $nextPc = $targetPc
        }
        "jalr" {
            $targetPc = [int](($registers[$entry.rs1] + $entry.imm) -band 0xfffffffe)
            $linkValue = [uint32]($pc + 4)
            $writeValue = $linkValue
            if ($entry.rd -ne 0) { $registers[$entry.rd] = $linkValue }
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
    $row["expected_next_pc_if_executed"] = Format-HexWord ([uint32]$nextPc)
    $row["taken"] = $taken
    $row["target"] = if ($null -eq $targetPc) { $row["target"] } else { Format-HexWord ([uint32]$targetPc) }
    $row["write_value"] = if ($null -eq $writeValue) { $null } else { Format-HexWord $writeValue }
    $row["link_register_value"] = if ($null -eq $linkValue) { $null } else { Format-HexWord $linkValue }
    $row["stack_pointer_value"] = Format-HexWord $registers[2]
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
    expected_stack_pointer = Format-HexWord ([uint32]$initialSp)
    completion_register = "x30"
    completion_value = "000007ac"
    final_checksum_register = "x31"
    final_checksum = Format-HexWord $registers[31]
    sentinel_word_index = 3
    sentinel_expected = Format-HexWord (Read-Word -Memory $memoryBytes -Address 12)
    coverage = @(
        "jal_call",
        "jalr_return",
        "nested_call",
        "stack_store_load",
        "return_address_link",
        "wrong_path_register_suppression",
        "wrong_path_store_suppression",
        "final_completion_marker"
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
        throw "Generated random call reference program differs from fixtures/generated/reference/random_call_reference.hex. Run scripts\random-call-reference.ps1 to update it."
    }
    if (($initialWords -join "`n") -ne ($existingDmemInit -join "`n")) {
        throw "Generated random call reference DMemory init differs from fixtures/generated/reference/random_call_reference_dmem_init.hex. Run scripts\random-call-reference.ps1 to update it."
    }
    if (($expectedRegs -join "`n") -ne ($existingRegs -join "`n")) {
        throw "Generated random call reference registers differ from fixtures/generated/reference/random_call_reference_expected_regs.hex. Run scripts\random-call-reference.ps1 to update it."
    }
    if (($expectedDmem -join "`n") -ne ($existingDmem -join "`n")) {
        throw "Generated random call reference DMemory differs from fixtures/generated/reference/random_call_reference_expected_dmem.hex. Run scripts\random-call-reference.ps1 to update it."
    }
    if ((Normalize-TextForArtifactCompare $expectedJson) -ne (Normalize-TextForArtifactCompare $existingJson)) {
        throw "Generated random call reference metadata differs from fixtures/generated/reference/random_call_reference_expected.json. Run scripts\random-call-reference.ps1 to update it."
    }
    Write-Host "PASS: random call reference artifacts match seed $Seed ($($words.Count) words)"
} else {
    Write-AsciiLfFile -Path $programPath -Value $programLines
    Write-AsciiLfFile -Path $dmemInitPath -Value $initialWords
    Write-AsciiLfFile -Path $expectedRegsPath -Value $expectedRegs
    Write-AsciiLfFile -Path $expectedDmemPath -Value $expectedDmem
    Write-AsciiLfFile -Path $expectedJsonPath -Value $expectedJson
    Write-Host "Generated random call reference artifacts with seed $Seed ($($words.Count) words)"
}

if (-not $SkipSimulation) {
    & (Join-Path $PSScriptRoot "run.ps1") -Test random_call_reference -SkipAssemble -PlusArgs "+fixture_dir=`"$ArtifactDirectory`" +program_words=$($words.Count)"
}
