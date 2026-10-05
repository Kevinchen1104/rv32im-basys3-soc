<#
Script: scripts\trace-lockstep-reference.ps1
Purpose: Generates or checks deterministic retired-trace lockstep reference fixtures.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\trace-lockstep-reference.ps1 -Check -SkipSimulation
Outputs:
  fixtures\generated\reference\trace_lockstep_reference* artifacts or freshness diagnostics.
#>
param(
    [int]$Seed = 6061,
    [int]$InstructionCount = 32,
    [switch]$Check,
    [switch]$SkipSimulation,
    [string]$ProgramPath = "fixtures/generated/reference/trace_lockstep_reference.hex",
    [string]$ExpectedTracePath = "fixtures/generated/reference/trace_lockstep_expected.hex",
    [string]$ExpectedJsonPath = "fixtures/generated/reference/trace_lockstep_expected.json"
)

. "$PSScriptRoot/reference-common.ps1"
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

function Resolve-ArtifactPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return (Join-Path $repoRoot $Path)
}

$programPathResolved = Resolve-ArtifactPath $ProgramPath
$expectedTracePathResolved = Resolve-ArtifactPath $ExpectedTracePath
$expectedJsonPathResolved = Resolve-ArtifactPath $ExpectedJsonPath
$script:UInt32SignBit = [uint32]2147483648
$script:UInt32AllOnes = [uint32]4294967295

function To-SInt32 {
    param([uint32]$Value)
    if (($Value -band $script:UInt32SignBit) -ne 0) {
        return [int64]$Value - 4294967296L
    }
    return [int64]$Value
}

function Sign-Extend {
    param([uint32]$Value, [int]$Bits)
    $mask = ([int64]1 -shl $Bits) - 1
    $sign = [int64]1 -shl ($Bits - 1)
    $v = [int64]($Value -band [uint32]$mask)
    if (($v -band $sign) -ne 0) {
        return To-UInt32 ($v - ([int64]1 -shl $Bits))
    }
    return To-UInt32 $v
}

function Encode-RType {
    param([int]$Funct7, [int]$Rs2, [int]$Rs1, [int]$Funct3, [int]$Rd)
    return [uint32](([uint64]($Funct7 -band 0x7f) -shl 25) -bor
                    ([uint64]($Rs2 -band 0x1f) -shl 20) -bor
                    ([uint64]($Rs1 -band 0x1f) -shl 15) -bor
                    ([uint64]($Funct3 -band 0x7) -shl 12) -bor
                    ([uint64]($Rd -band 0x1f) -shl 7) -bor [uint64]0x33)
}

function Encode-IType {
    param([int]$Immediate, [int]$Rs1, [int]$Funct3, [int]$Rd, [int]$Opcode)
    $imm = [int64]$Immediate -band 0xfff
    return [uint32](([uint64]$imm -shl 20) -bor
                    ([uint64]($Rs1 -band 0x1f) -shl 15) -bor
                    ([uint64]($Funct3 -band 0x7) -shl 12) -bor
                    ([uint64]($Rd -band 0x1f) -shl 7) -bor [uint64]($Opcode -band 0x7f))
}

function Encode-UType {
    param([int]$Immediate, [int]$Rd, [int]$Opcode)
    return [uint32](([uint64]($Immediate -band 0xfffff) -shl 12) -bor
                    ([uint64]($Rd -band 0x1f) -shl 7) -bor [uint64]($Opcode -band 0x7f))
}

function Add-Coverage {
    param([string[]]$Tags)
    foreach ($tag in @($Tags)) {
        if (-not [string]::IsNullOrWhiteSpace($tag) -and -not $script:coverage.Contains($tag)) {
            $script:coverage.Add($tag) | Out-Null
        }
    }
}

function Add-ExpectedInstruction {
    param(
        [uint32]$Instruction,
        [int]$Rd,
        [bool]$MayWriteRegister,
        [uint32]$Value,
        [string]$Note,
        [string[]]$Tags = @()
    )

    $pc = [uint32]($script:program.Count * 4)
    $script:program.Add($Instruction)
    $regWrite = $MayWriteRegister -and ($Rd -ne 0)
    if ($regWrite) {
        $script:registers[$Rd] = $Value
    }
    $script:expected.Add((Format-TraceRow $pc $Instruction $Rd $regWrite $Value))
    Add-Coverage $Tags
    $script:rows.Add([pscustomobject][ordered]@{
        index = $script:expected.Count - 1
        pc = Format-HexWord $pc
        instruction = Format-HexWord $Instruction
        reg_write = $regWrite
        rd = if ($regWrite) { "x$Rd" } else { $null }
        writeback_value = if ($regWrite) { Format-HexWord $Value } else { $null }
        note = $Note
        coverage = @($Tags)
    }) | Out-Null
}

function Add-UnexecutedInstruction {
    param([uint32]$Instruction, [string]$Note, [string[]]$Tags = @("wrong-path suppression"))
    $pc = [uint32]($script:program.Count * 4)
    $script:program.Add($Instruction)
    Add-Coverage $Tags
    $script:wrongPathRows.Add([pscustomobject][ordered]@{
        pc = Format-HexWord $pc
        instruction = Format-HexWord $Instruction
        note = $Note
        coverage = @($Tags)
    }) | Out-Null
}

function Add-Lui {
    param([int]$Rd, [int]$Immediate20, [string]$Note = "")
    $instruction = Encode-UType $Immediate20 $Rd 0x37
    $value = To-UInt32 ([int64]($Immediate20 -band 0xfffff) -shl 12)
    Add-ExpectedInstruction $instruction $Rd $true $value $Note @("ALU immediate")
}

function Add-Addi {
    param([int]$Rd, [int]$Rs1, [int]$Immediate, [string]$Note = "", [string[]]$Tags = @("ALU immediate"))
    $instruction = Encode-IType $Immediate $Rs1 0 $Rd 0x13
    $immValue = Sign-Extend ([uint32]($Immediate -band 0xfff)) 12
    $value = To-UInt32 ([int64]$script:registers[$Rs1] + [int64](To-SInt32 $immValue))
    Add-ExpectedInstruction $instruction $Rd $true $value $Note $Tags
}

function Add-LoadImmediate {
    param([int]$Rd, [uint32]$Value, [string]$Note = "")

    $signedValue = To-SInt32 $Value
    if ($signedValue -ge -2048 -and $signedValue -le 2047) {
        Add-Addi $Rd 0 ([int]$signedValue) $Note @("ALU immediate")
        return
    }

    $parts = Split-LoadImmediate $Value
    $upper = $parts.Upper
    $lower = $parts.Lower

    Add-Lui $Rd $upper $Note
    if ($lower -ne 0) {
        Add-Addi $Rd $Rd $lower $Note @("ALU immediate")
    }
}

function Get-AluRResult {
    param([string]$Op, [uint32]$A, [uint32]$B)
    $shamt = [int]($B -band 0x1f)
    switch ($Op) {
        "add"  { return To-UInt32 ([int64]$A + [int64]$B) }
        "sub"  { return To-UInt32 ([int64]$A - [int64]$B) }
        "and"  { return [uint32]($A -band $B) }
        "or"   { return [uint32]($A -bor $B) }
        "xor"  { return [uint32]($A -bxor $B) }
        "slt"  { return [uint32]([int]((To-SInt32 $A) -lt (To-SInt32 $B))) }
        "sltu" { return [uint32]([int]($A -lt $B)) }
        "sll"  { return To-UInt32 ([int64]$A -shl $shamt) }
        "srl"  { return [uint32](([uint64]$A) -shr $shamt) }
        "sra"  { return To-UInt32 ((To-SInt32 $A) -shr $shamt) }
        default { throw "unknown ALU R op $Op" }
    }
}

function Add-AluR {
    param([string]$Op, [int]$Rd, [int]$Rs1, [int]$Rs2, [string]$Note = "")
    $encoding = @{
        add = @(0x00, 0)
        sub = @(0x20, 0)
        and = @(0x00, 7)
        or = @(0x00, 6)
        xor = @(0x00, 4)
        slt = @(0x00, 2)
        sltu = @(0x00, 3)
        sll = @(0x00, 1)
        srl = @(0x00, 5)
        sra = @(0x20, 5)
    }
    $funct7 = $encoding[$Op][0]
    $funct3 = $encoding[$Op][1]
    $instruction = Encode-RType $funct7 $Rs2 $Rs1 $funct3 $Rd
    $value = Get-AluRResult $Op $script:registers[$Rs1] $script:registers[$Rs2]
    Add-ExpectedInstruction $instruction $Rd $true $value $Note @("ALU register")
}

function Get-AluIResult {
    param([string]$Op, [uint32]$A, [int]$Immediate)
    $immValue = Sign-Extend ([uint32]($Immediate -band 0xfff)) 12
    $shamt = $Immediate -band 0x1f
    switch ($Op) {
        "addi"  { return To-UInt32 ([int64]$A + [int64](To-SInt32 $immValue)) }
        "slti"  { return [uint32]([int]((To-SInt32 $A) -lt (To-SInt32 $immValue))) }
        "sltiu" { return [uint32]([int]($A -lt $immValue)) }
        "xori"  { return [uint32]($A -bxor $immValue) }
        "ori"   { return [uint32]($A -bor $immValue) }
        "andi"  { return [uint32]($A -band $immValue) }
        "slli"  { return To-UInt32 ([int64]$A -shl $shamt) }
        "srli"  { return [uint32](([uint64]$A) -shr $shamt) }
        "srai"  { return To-UInt32 ((To-SInt32 $A) -shr $shamt) }
        default { throw "unknown ALU I op $Op" }
    }
}

function Add-AluI {
    param([string]$Op, [int]$Rd, [int]$Rs1, [int]$Immediate, [string]$Note = "")
    $funct3Map = @{
        addi = 0
        slti = 2
        sltiu = 3
        xori = 4
        ori = 6
        andi = 7
        slli = 1
        srli = 5
        srai = 5
    }
    $encodedImmediate = $Immediate
    if ($Op -eq "srai") {
        $encodedImmediate = 0x400 -bor ($Immediate -band 0x1f)
    } elseif ($Op -eq "slli" -or $Op -eq "srli") {
        $encodedImmediate = $Immediate -band 0x1f
    }
    $instruction = Encode-IType $encodedImmediate $Rs1 $funct3Map[$Op] $Rd 0x13
    $value = Get-AluIResult $Op $script:registers[$Rs1] $Immediate
    Add-ExpectedInstruction $instruction $Rd $true $value $Note @("ALU immediate")
}

function Test-BranchTaken {
    param([int]$Funct3, [uint32]$Left, [uint32]$Right)
    switch ($Funct3) {
        0 { return $Left -eq $Right }
        1 { return $Left -ne $Right }
        4 { return (To-SInt32 $Left) -lt (To-SInt32 $Right) }
        5 { return (To-SInt32 $Left) -ge (To-SInt32 $Right) }
        6 { return $Left -lt $Right }
        7 { return $Left -ge $Right }
        default { throw "unsupported branch funct3 $Funct3" }
    }
}

function Add-BranchCase {
    param([string]$Name, [int]$Funct3, [uint32]$Left, [uint32]$Right, [bool]$ExpectedTaken, [int]$Marker)
    Add-LoadImmediate 5 $Left "$Name left"
    Add-LoadImmediate 6 $Right "$Name right"

    $taken = Test-BranchTaken $Funct3 $script:registers[5] $script:registers[6]
    if ($taken -ne $ExpectedTaken) {
        throw "branch case $Name expected taken=$ExpectedTaken, model got $taken"
    }

    $branch = Encode-BType 8 6 5 $Funct3
    Add-ExpectedInstruction $branch 0 $false ([uint32]0) $Name @("control flow", "branch")
    $fallthrough = Encode-IType $Marker 0 0 18 0x13
    $target = Encode-IType ($Marker + 100) 0 0 19 0x13

    if ($taken) {
        Add-UnexecutedInstruction $fallthrough "$Name wrong-path fallthrough"
        Add-ExpectedInstruction $target 19 $true (To-UInt32 ($Marker + 100)) "$Name target" @("control flow", "wrong-path suppression")
    } else {
        Add-ExpectedInstruction $fallthrough 18 $true (To-UInt32 $Marker) "$Name fallthrough" @("control flow")
        Add-ExpectedInstruction $target 19 $true (To-UInt32 ($Marker + 100)) "$Name sequential target" @("control flow")
    }
}

function Add-JalCase {
    $pc = [uint32]($script:program.Count * 4)
    $instruction = Encode-JType 8 7
    Add-ExpectedInstruction $instruction 7 $true (To-UInt32 ([int64]$pc + 4)) "jal link and wrong-path skip" @("control flow", "jump")
    Add-UnexecutedInstruction (Encode-IType 777 0 0 20 0x13) "jal wrong-path register write"
    Add-ExpectedInstruction (Encode-IType 778 0 0 21 0x13) 21 $true (To-UInt32 778) "jal target" @("control flow", "wrong-path suppression")
}

function Add-JalrCase {
    $targetWithBit0 = [uint32]((($script:program.Count + 3) * 4) -bor 1)
    if ($targetWithBit0 -gt 2047) {
        throw "jalr directed target grew beyond single addi immediate"
    }
    Add-Addi 8 0 ([int]$targetWithBit0) "jalr odd target setup" @("control flow", "jump")
    $pc = [uint32]($script:program.Count * 4)
    Add-ExpectedInstruction (Encode-IType 0 8 0 9 0x67) 9 $true (To-UInt32 ([int64]$pc + 4)) "jalr clears bit 0 and links" @("control flow", "jump")
    Add-UnexecutedInstruction (Encode-IType 779 0 0 22 0x13) "jalr wrong-path register write"
    Add-ExpectedInstruction (Encode-IType 780 0 0 23 0x13) 23 $true (To-UInt32 780) "jalr aligned target" @("control flow", "wrong-path suppression")
}

function Read-Byte {
    param([int]$Address)
    return [uint32]$script:memory[$Address]
}

function Write-ByteValue {
    param([int]$Address, [uint32]$Value)
    $script:memory[$Address] = [byte]($Value -band 0xff)
}

function Read-Half {
    param([int]$Address)
    return [uint32]((Read-Byte $Address) -bor ((Read-Byte ($Address + 1)) -shl 8))
}

function Write-Half {
    param([int]$Address, [uint32]$Value)
    Write-ByteValue $Address $Value
    Write-ByteValue ($Address + 1) ($Value -shr 8)
}

function Read-Word {
    param([int]$Address)
    return [uint32]((Read-Byte $Address) -bor
                    ((Read-Byte ($Address + 1)) -shl 8) -bor
                    ((Read-Byte ($Address + 2)) -shl 16) -bor
                    ((Read-Byte ($Address + 3)) -shl 24))
}

function Write-Word {
    param([int]$Address, [uint32]$Value)
    Write-ByteValue $Address $Value
    Write-ByteValue ($Address + 1) ($Value -shr 8)
    Write-ByteValue ($Address + 2) ($Value -shr 16)
    Write-ByteValue ($Address + 3) ($Value -shr 24)
}

function Add-Store {
    param([string]$Op, [int]$Rs2, [int]$Rs1, [int]$Immediate, [string]$Note = "")
    $funct3Map = @{ sb = 0; sh = 1; sw = 2 }
    $instruction = Encode-SType $Immediate $Rs2 $Rs1 $funct3Map[$Op]
    $address = [int](To-UInt32 ([int64]$script:registers[$Rs1] + $Immediate))
    $value = $script:registers[$Rs2]
    switch ($Op) {
        "sb" { Write-ByteValue $address $value }
        "sh" { Write-Half $address $value }
        "sw" { Write-Word $address $value }
        default { throw "unknown store op $Op" }
    }
    Add-ExpectedInstruction $instruction 0 $false ([uint32]0) $Note @("memory", "load/store")
}

function Add-Load {
    param([string]$Op, [int]$Rd, [int]$Rs1, [int]$Immediate, [string]$Note = "")
    $funct3Map = @{ lb = 0; lh = 1; lw = 2; lbu = 4; lhu = 5 }
    $instruction = Encode-IType $Immediate $Rs1 $funct3Map[$Op] $Rd 0x03
    $address = [int](To-UInt32 ([int64]$script:registers[$Rs1] + $Immediate))
    switch ($Op) {
        "lb"  { $value = Sign-Extend (Read-Byte $address) 8 }
        "lbu" { $value = [uint32](Read-Byte $address) }
        "lh"  { $value = Sign-Extend (Read-Half $address) 16 }
        "lhu" { $value = [uint32](Read-Half $address) }
        "lw"  { $value = Read-Word $address }
        default { throw "unknown load op $Op" }
    }
    Add-ExpectedInstruction $instruction $Rd $true $value $Note @("memory", "load/store")
}

function To-BigUnsigned32 {
    param([uint32]$Value)
    return [System.Numerics.BigInteger]([uint64]$Value)
}

function To-BigSigned32 {
    param([uint32]$Value)
    return [System.Numerics.BigInteger](To-SInt32 $Value)
}

function Big-To-UInt32Low {
    param([System.Numerics.BigInteger]$Value)
    $two32 = [System.Numerics.BigInteger]::Pow(2, 32)
    $reduced = $Value % $two32
    if ($reduced -lt 0) {
        $reduced += $two32
    }
    return [uint32][uint64]$reduced
}

function Big-To-UInt32High64 {
    param([System.Numerics.BigInteger]$Value)
    $two32 = [System.Numerics.BigInteger]::Pow(2, 32)
    $two64 = [System.Numerics.BigInteger]::Pow(2, 64)
    $reduced = $Value % $two64
    if ($reduced -lt 0) {
        $reduced += $two64
    }
    $high = ($reduced / $two32) % $two32
    return [uint32][uint64]$high
}

function Get-MResult {
    param([string]$Op, [uint32]$A, [uint32]$B)
    switch ($Op) {
        "mul"    { return Big-To-UInt32Low ((To-BigSigned32 $A) * (To-BigSigned32 $B)) }
        "mulh"   { return Big-To-UInt32High64 ((To-BigSigned32 $A) * (To-BigSigned32 $B)) }
        "mulhsu" { return Big-To-UInt32High64 ((To-BigSigned32 $A) * (To-BigUnsigned32 $B)) }
        "mulhu"  { return Big-To-UInt32High64 ((To-BigUnsigned32 $A) * (To-BigUnsigned32 $B)) }
        "div" {
            if ($B -eq 0) { return $script:UInt32AllOnes }
            if ($A -eq $script:UInt32SignBit -and $B -eq $script:UInt32AllOnes) { return $script:UInt32SignBit }
            $lhs = To-SInt32 $A
            $rhs = To-SInt32 $B
            $quotient = [int64][Math]::Truncate([double]$lhs / [double]$rhs)
            return To-UInt32 $quotient
        }
        "divu" {
            if ($B -eq 0) { return $script:UInt32AllOnes }
            $quotient = [uint64][Math]::Floor([double]([uint64]$A) / [double]([uint64]$B))
            return [uint32]$quotient
        }
        "rem" {
            if ($B -eq 0) { return $A }
            if ($A -eq $script:UInt32SignBit -and $B -eq $script:UInt32AllOnes) { return [uint32]0 }
            $lhs = To-SInt32 $A
            $rhs = To-SInt32 $B
            $quotient = [int64][Math]::Truncate([double]$lhs / [double]$rhs)
            return To-UInt32 ($lhs - ($quotient * $rhs))
        }
        "remu" {
            if ($B -eq 0) { return $A }
            $quotient = [uint64][Math]::Floor([double]([uint64]$A) / [double]([uint64]$B))
            return [uint32](([uint64]$A) - ($quotient * ([uint64]$B)))
        }
        default { throw "unknown RV32M op $Op" }
    }
}

function Add-MOp {
    param([string]$Op, [int]$Rd, [int]$Rs1, [int]$Rs2, [string]$Note = "")
    $funct3Map = @{
        mul = 0
        mulh = 1
        mulhsu = 2
        mulhu = 3
        div = 4
        divu = 5
        rem = 6
        remu = 7
    }
    $instruction = Encode-RType 0x01 $Rs2 $Rs1 $funct3Map[$Op] $Rd
    $value = Get-MResult $Op $script:registers[$Rs1] $script:registers[$Rs2]
    Add-ExpectedInstruction $instruction $Rd $true $value $Note @("RV32M")
}

function Assert-Contains {
    param([object[]]$Values, [string]$Expected)
    if (@($Values) -notcontains $Expected) {
        throw "trace lockstep reference metadata missing coverage '$Expected'"
    }
}

function Assert-ArtifactConsistency {
    param([object]$Metadata, [string[]]$ProgramLines, [string[]]$TraceLines)
    if ($Metadata.program_words -ne $ProgramLines.Count) {
        throw "program_words $($Metadata.program_words) does not match program hex line count $($ProgramLines.Count)"
    }
    if ($Metadata.trace_count -ne $TraceLines.Count) {
        throw "trace_count $($Metadata.trace_count) does not match expected trace line count $($TraceLines.Count)"
    }
    foreach ($line in $TraceLines) {
        if ($line -notmatch '^[0-9a-f]{32}$') {
            throw "expected trace line '$line' is not a 128-bit lowercase hex row"
        }
    }
    foreach ($coverage in @(
        "ALU register",
        "ALU immediate",
        "x0 invariant",
        "branch",
        "jump",
        "wrong-path suppression",
        "memory",
        "load/store",
        "RV32M"
    )) {
        Assert-Contains $Metadata.coverage $coverage
    }
    if (@($Metadata.wrong_path_rows).Count -lt 2) {
        throw "metadata must include wrong-path rows for branch/jump suppression evidence"
    }
}

$script:program = [System.Collections.Generic.List[uint32]]::new()
$script:expected = [System.Collections.Generic.List[string]]::new()
$script:rows = [System.Collections.ArrayList]::new()
$script:wrongPathRows = [System.Collections.ArrayList]::new()
$script:coverage = [System.Collections.ArrayList]::new()
$script:registers = New-Object 'uint32[]' 32
$script:memory = New-Object 'byte[]' 256

# Directed ALU and x0 cases.
Add-LoadImmediate 1 ([uint32]0x00000000) "x1 = 0"
Add-LoadImmediate 2 $script:UInt32AllOnes "x2 = -1"
Add-LoadImmediate 3 $script:UInt32SignBit "x3 = sign bit"
Add-LoadImmediate 4 ([uint32]0x0000001f) "x4 = shift 31"

Add-AluR "add" 10 1 2 "add zero plus -1"
Add-AluR "sub" 11 1 2 "sub zero minus -1"
Add-AluR "and" 12 2 3 "and sign bit"
Add-AluR "or" 13 1 3 "or sign bit"
Add-AluR "xor" 14 2 3 "xor sign bit"
Add-AluR "slt" 15 3 1 "signed sign-bit less than zero"
Add-AluR "sltu" 16 3 1 "unsigned sign-bit greater than zero"
Add-AluR "sll" 17 2 1 "shift left by 0"
Add-AluR "sll" 18 2 4 "shift left by 31"
Add-AluR "srl" 19 3 4 "logical shift right 31"
Add-AluR "sra" 20 3 4 "arithmetic shift right 31"

Add-AluI "addi" 21 2 1 "addi -1 + 1"
Add-AluI "slti" 22 3 0 "slti sign-bit < 0"
Add-AluI "sltiu" 23 1 -1 "sltiu zero < -1"
Add-AluI "xori" 24 3 -1 "xori sign-bit with -1"
Add-AluI "ori" 25 1 0x7f "ori small mask"
Add-AluI "andi" 26 2 0x55 "andi low mask"
Add-AluI "slli" 27 2 0 "slli by 0"
Add-AluI "slli" 28 2 31 "slli by 31"
Add-AluI "srli" 29 3 31 "srli by 31"
Add-AluI "srai" 30 3 31 "srai by 31"
Add-ExpectedInstruction (Encode-IType 99 1 0 0 0x13) 0 $true ([uint32]0) "attempted x0 write" @("x0 invariant")
Add-AluI "addi" 31 0 0 "read x0 after attempted write"

# Directed control-flow cases.
Add-BranchCase "beq taken" 0 ([uint32]5) ([uint32]5) $true 40
Add-BranchCase "beq not taken" 0 ([uint32]5) ([uint32]6) $false 41
Add-BranchCase "bne taken" 1 ([uint32]5) ([uint32]6) $true 42
Add-BranchCase "bne not taken" 1 ([uint32]5) ([uint32]5) $false 43
Add-BranchCase "blt signed taken" 4 $script:UInt32AllOnes ([uint32]1) $true 44
Add-BranchCase "bge signed not taken" 5 $script:UInt32SignBit $script:UInt32AllOnes $false 45
Add-BranchCase "bltu unsigned taken" 6 ([uint32]1) $script:UInt32SignBit $true 46
Add-BranchCase "bgeu unsigned taken" 7 $script:UInt32SignBit ([uint32]1) $true 47
Add-BranchCase "blt signed not taken" 4 ([uint32]5) $script:UInt32AllOnes $false 48
Add-BranchCase "bge signed taken" 5 $script:UInt32AllOnes $script:UInt32SignBit $true 49
Add-BranchCase "bltu unsigned not taken" 6 $script:UInt32SignBit ([uint32]1) $false 50
Add-BranchCase "bgeu unsigned not taken" 7 ([uint32]1) $script:UInt32SignBit $false 51
Add-JalCase
Add-JalrCase

# Directed memory cases.
Add-LoadImmediate 3 ([uint32]0) "memory base"
Add-LoadImmediate 4 ([uint32]2289526357) "word store pattern"
Add-Store "sw" 4 3 0 "sw word pattern"
Add-Load "lw" 5 3 0 "lw word pattern"
Add-Load "lb" 6 3 3 "lb signed high byte"
Add-Load "lbu" 7 3 3 "lbu high byte"
Add-LoadImmediate 8 ([uint32]0x000000aa) "byte overlap value"
Add-Store "sb" 8 3 1 "sb overlapping byte"
Add-Load "lw" 9 3 0 "lw after sb overlap"
Add-LoadImmediate 10 ([uint32]0x00008001) "halfword overlap value"
Add-Store "sh" 10 3 2 "sh overlapping high half"
Add-Load "lh" 11 3 2 "lh signed overlap"
Add-Load "lhu" 12 3 2 "lhu unsigned overlap"
Add-Load "lw" 13 3 0 "lw after sh overlap"

# Directed RV32M cases.
Add-LoadImmediate 1 $script:UInt32SignBit "rv32m lhs INT_MIN"
Add-LoadImmediate 2 $script:UInt32AllOnes "rv32m rhs -1"
Add-MOp "mul" 14 1 2 "mul INT_MIN * -1"
Add-MOp "mulh" 15 1 2 "mulh INT_MIN * -1"
Add-MOp "mulhsu" 16 1 2 "mulhsu signed/unsigned"
Add-MOp "mulhu" 17 1 2 "mulhu unsigned high"
Add-MOp "div" 18 1 2 "div INT_MIN / -1"
Add-MOp "rem" 19 1 2 "rem INT_MIN % -1"
Add-LoadImmediate 2 ([uint32]0) "rv32m divisor zero"
Add-MOp "div" 20 1 2 "div by zero"
Add-MOp "divu" 21 1 2 "divu by zero"
Add-MOp "rem" 22 1 2 "rem by zero"
Add-MOp "remu" 23 1 2 "remu by zero"
Add-LoadImmediate 1 ([uint32]4294967289) "rv32m lhs -7"
Add-LoadImmediate 2 ([uint32]3) "rv32m rhs 3"
Add-MOp "div" 24 1 2 "signed div negative"
Add-MOp "rem" 25 1 2 "signed rem negative"
Add-MOp "divu" 26 1 2 "unsigned div edge"
Add-MOp "remu" 27 1 2 "unsigned rem edge"

# Seeded bounded filler keeps the fixture useful beyond the hand-picked rows.
$random = [System.Random]::new($Seed)
for ($caseIndex = 0; $caseIndex -lt $InstructionCount; $caseIndex++) {
    $a = To-UInt32 $random.Next(-2048, 2048)
    $b = To-UInt32 $random.Next(-2048, 2048)
    Add-LoadImmediate 1 $a "seeded lhs $caseIndex"
    Add-LoadImmediate 2 $b "seeded rhs $caseIndex"
    switch ($caseIndex % 8) {
        0 { Add-AluR "add" 10 1 2 "seeded add $caseIndex" }
        1 { Add-AluR "xor" 11 1 2 "seeded xor $caseIndex" }
        2 { Add-AluI "slli" 12 1 ($random.Next(0, 32)) "seeded slli $caseIndex" }
        3 { Add-AluI "srai" 13 1 ($random.Next(0, 32)) "seeded srai $caseIndex" }
        4 { Add-BranchCase "seeded beq $caseIndex" 0 $a $a $true (80 + ($caseIndex % 32)) }
        5 { Add-BranchCase "seeded bne $caseIndex" 1 $a $b ($a -ne $b) (112 + ($caseIndex % 32)) }
        6 { Add-MOp "mul" 14 1 2 "seeded mul $caseIndex" }
        7 {
            $address = 32 + (($caseIndex % 8) * 4)
            Add-LoadImmediate 3 ([uint32]0) "seeded memory base $caseIndex"
            Add-Store "sw" 1 3 $address "seeded sw $caseIndex"
            Add-Load "lw" 15 3 $address "seeded lw $caseIndex"
        }
    }
}

for ($i = 0; $i -lt 3; $i++) {
    Add-ExpectedInstruction ([uint32]0x00000013) 0 $false ([uint32]0) "tail nop $i" @("control flow")
}

$hexLines = @($script:program | ForEach-Object { Format-HexWord $_ })
$expectedLines = @($script:expected)
$metadata = [ordered]@{
    seed = $Seed
    requested_instruction_count = $InstructionCount
    program_words = $hexLines.Count
    trace_count = $expectedLines.Count
    row_format = "pc,instruction,meta,value; meta bit5=reg_write, meta[4:0]=rd"
    comparison_contract = "CPU public retired trace ports: trace_valid, trace_pc, trace_instruction, trace_reg_write, trace_rd, trace_writeback_value"
    coverage = @($script:coverage)
    rows = @($script:rows)
    wrong_path_rows = @($script:wrongPathRows)
}
$expectedJson = ($metadata | ConvertTo-Json -Depth 8)

Assert-ArtifactConsistency ([pscustomobject]$metadata) $hexLines $expectedLines

if ($Check) {
    $existingHex = if (Test-Path -LiteralPath $programPathResolved) { @(Get-Content -LiteralPath $programPathResolved) } else { @() }
    $existingExpected = if (Test-Path -LiteralPath $expectedTracePathResolved) { @(Get-Content -LiteralPath $expectedTracePathResolved) } else { @() }
    $existingJson = if (Test-Path -LiteralPath $expectedJsonPathResolved) { Get-Content -Raw -LiteralPath $expectedJsonPathResolved } else { "" }

    if ($existingJson -ne "") {
        Assert-ArtifactConsistency ($existingJson | ConvertFrom-Json) $existingHex $existingExpected
    }
    if (($hexLines -join "`n") -ne ($existingHex -join "`n")) {
        throw "Generated trace lockstep program differs from $ProgramPath. Run scripts\trace-lockstep-reference.ps1 to update it."
    }
    if (($expectedLines -join "`n") -ne ($existingExpected -join "`n")) {
        throw "Generated trace lockstep expected rows differ from $ExpectedTracePath. Run scripts\trace-lockstep-reference.ps1 to update it."
    }
    if (($expectedJson.TrimEnd() -replace "`r`n", "`n") -ne ($existingJson.TrimEnd() -replace "`r`n", "`n")) {
        throw "Generated trace lockstep metadata differs from $ExpectedJsonPath. Run scripts\trace-lockstep-reference.ps1 to update it."
    }
    Write-Host "PASS: trace lockstep reference artifacts match seed $Seed ($($hexLines.Count) words, $($expectedLines.Count) trace rows)"
} else {
    foreach ($path in @($programPathResolved, $expectedTracePathResolved, $expectedJsonPathResolved)) {
        $directory = Split-Path -Parent $path
        if ($directory -ne "") {
            New-Item -ItemType Directory -Force -Path $directory | Out-Null
        }
    }
    Set-Content -Path $programPathResolved -Value $hexLines -Encoding Ascii
    Set-Content -Path $expectedTracePathResolved -Value $expectedLines -Encoding Ascii
    Set-Content -Path $expectedJsonPathResolved -Value $expectedJson -Encoding Ascii
    Write-Host "Generated trace lockstep reference artifacts with seed $Seed ($($hexLines.Count) words, $($expectedLines.Count) trace rows)"
}

if (-not $SkipSimulation) {
    & (Join-Path $PSScriptRoot "run.ps1") -Test trace_lockstep_reference
}
