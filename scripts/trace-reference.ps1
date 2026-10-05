<#
Script: scripts\trace-reference.ps1
Purpose: Generates or checks the baseline retired-trace reference fixture.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\trace-reference.ps1 -Check -SkipSimulation
Outputs:
  fixtures\generated\reference\trace_reference* artifacts or freshness diagnostics.
#>
param(
    [switch]$Check,
    [switch]$SkipSimulation
)

. "$PSScriptRoot/reference-common.ps1"
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$hexPath = Join-Path $repoRoot "fixtures/generated/reference/trace_reference.hex"
$expectedPath = Join-Path $repoRoot "fixtures/generated/reference/trace_reference_expected.hex"

function Encode-Csr {
    param([int]$Csr, [int]$Rs1, [int]$Funct3, [int]$Rd)
    return [uint32](([uint64]($Csr -band 0xfff) -shl 20) -bor
                    ([uint64]$Rs1 -shl 15) -bor
                    ([uint64]$Funct3 -shl 12) -bor
                    ([uint64]$Rd -shl 7) -bor [uint64]0x73)
}

$program = [System.Collections.Generic.List[uint32]]::new()
$expected = [System.Collections.Generic.List[string]]::new()
$registers = New-Object 'uint32[]' 32
$memoryWord = [uint32]0
$csrValues = @{
    0x300 = [uint32]0
    0x305 = [uint32]0
    0x341 = [uint32]0
    0x342 = [uint32]0
}

function Apply-CsrWriteSemantics {
    param([int]$Csr, [uint32]$RawValue)

    switch ($Csr) {
        0x300 { return [uint32](($RawValue -band [uint32]0x00000088) -bor [uint32]0x00001800) }
        0x304 { return [uint32]($RawValue -band [uint32]0x00000880) }
        0x305 { return [uint32]($RawValue -band [uint32]4294967292) }
        0x341 { return [uint32]($RawValue -band [uint32]4294967292) }
        0x344 { return [uint32]($RawValue -band [uint32]0x00000880) }
        default { return $RawValue }
    }
}

function Add-ExpectedInstruction {
    param([uint32]$Instruction, [int]$Rd, [bool]$RegWrite, [uint32]$Value)

    $pc = [uint32]($program.Count * 4)
    $program.Add($Instruction)
    if ($RegWrite) {
        $registers[$Rd] = $Value
    }
    $expected.Add((Format-TraceRow $pc $Instruction $Rd $RegWrite $Value))
}

function Add-ExpectedTraceRow {
    param([uint32]$Pc, [uint32]$Instruction, [int]$Rd, [bool]$RegWrite, [uint32]$Value)

    if ($RegWrite) {
        $registers[$Rd] = $Value
    }
    $expected.Add((Format-TraceRow $Pc $Instruction $Rd $RegWrite $Value))
}

function Add-CsrReadbackVariant {
    param([int]$Csr, [int]$ValueRegister, [int]$FirstReadRegister, [int]$ValueImmediate)

    Add-ExpectedInstruction (Encode-IType $ValueImmediate 0 0 $ValueRegister 0x13) $ValueRegister $true (To-UInt32 $ValueImmediate)

    $oldValue = [uint32]$csrValues[$Csr]
    Add-ExpectedInstruction (Encode-Csr $Csr $ValueRegister 1 $FirstReadRegister) $FirstReadRegister $true $oldValue
    $csrValues[$Csr] = Apply-CsrWriteSemantics $Csr $registers[$ValueRegister]

    $currentValue = [uint32]$csrValues[$Csr]
    Add-ExpectedInstruction (Encode-Csr $Csr 0 2 ($FirstReadRegister + 1)) ($FirstReadRegister + 1) $true $currentValue
    Add-ExpectedInstruction (Encode-Csr $Csr 0 3 ($FirstReadRegister + 2)) ($FirstReadRegister + 2) $true $currentValue
}

function To-Int32 {
    param([uint32]$Value)
    if (($Value -band [uint32]2147483648) -ne 0) {
        return [int32]([int64]$Value - 4294967296L)
    }
    return [int32]$Value
}

function Test-BranchTaken {
    param([int]$Funct3, [uint32]$Left, [uint32]$Right)

    switch ($Funct3) {
        0 { return $Left -eq $Right }
        1 { return $Left -ne $Right }
        4 { return (To-Int32 $Left) -lt (To-Int32 $Right) }
        5 { return (To-Int32 $Left) -ge (To-Int32 $Right) }
        6 { return $Left -lt $Right }
        7 { return $Left -ge $Right }
        default { throw "Unsupported branch funct3 $Funct3" }
    }
}

function Add-GeneratedBranchCase {
    param([int]$Index, [int]$Funct3, [int]$LeftImmediate, [int]$RightImmediate)

    Add-ExpectedInstruction (Encode-IType $LeftImmediate 0 0 10 0x13) 10 $true (To-UInt32 $LeftImmediate)
    Add-ExpectedInstruction (Encode-IType $RightImmediate 0 0 11 0x13) 11 $true (To-UInt32 $RightImmediate)

    $taken = Test-BranchTaken $Funct3 $registers[10] $registers[11]
    Add-ExpectedInstruction (Encode-BType 8 11 10 $Funct3) 0 $false ([uint32]0)

    $fallthroughValue = To-UInt32 (160 + $Index)
    $targetValue = To-UInt32 (192 + $Index)
    $fallthroughInstruction = Encode-IType $fallthroughValue 0 0 12 0x13
    $targetInstruction = Encode-IType $targetValue 0 0 13 0x13

    if ($taken) {
        $program.Add($fallthroughInstruction)
        Add-ExpectedInstruction $targetInstruction 13 $true $targetValue
    } else {
        Add-ExpectedInstruction $fallthroughInstruction 12 $true $fallthroughValue
        Add-ExpectedInstruction $targetInstruction 13 $true $targetValue
    }
}

function Add-GeneratedJumpCase {
    param([int]$Index, [int]$TargetValue)

    $jalLinkRegister = 21
    $jalTargetRegister = 22
    $jalrBaseRegister = 23
    $jalrLinkRegister = 24
    $jalrTargetRegister = 25

    Add-ExpectedInstruction (Encode-JType 12 $jalLinkRegister) $jalLinkRegister $true (To-UInt32 (($program.Count * 4) + 4))
    $program.Add((Encode-IType (300 + $Index) 0 0 26 0x13))
    $program.Add((Encode-IType (320 + $Index) 0 0 27 0x13))
    Add-ExpectedInstruction (Encode-IType $TargetValue 0 0 $jalTargetRegister 0x13) $jalTargetRegister $true (To-UInt32 $TargetValue)

    $jalrTargetPc = [uint32](($program.Count + 3) * 4)
    Add-ExpectedInstruction (Encode-IType ([int]$jalrTargetPc) 0 0 $jalrBaseRegister 0x13) $jalrBaseRegister $true $jalrTargetPc
    Add-ExpectedInstruction (Encode-IType 0 $jalrBaseRegister 0 $jalrLinkRegister 0x67) $jalrLinkRegister $true (To-UInt32 (($program.Count * 4) + 4))
    $program.Add((Encode-IType (340 + $Index) 0 0 28 0x13))
    Add-ExpectedInstruction (Encode-IType ($TargetValue + 1) 0 0 $jalrTargetRegister 0x13) $jalrTargetRegister $true (To-UInt32 ($TargetValue + 1))
}

function Add-GeneratedMixedBranchJumpCase {
    param([int]$Index, [int]$TargetValue)

    $leftRegister = 10
    $rightRegister = 11
    $jalLinkRegister = 21
    $jalTargetRegister = 22
    $jalrBaseRegister = 23
    $jalrLinkRegister = 24
    $jalrTargetRegister = 25

    Add-ExpectedInstruction (Encode-IType (48 + $Index) 0 0 $leftRegister 0x13) $leftRegister $true (To-UInt32 (48 + $Index))
    Add-ExpectedInstruction (Encode-IType (48 + $Index) 0 0 $rightRegister 0x13) $rightRegister $true (To-UInt32 (48 + $Index))

    Add-ExpectedInstruction (Encode-BType 8 $rightRegister $leftRegister 0) 0 $false ([uint32]0)
    $program.Add((Encode-IType (360 + $Index) 0 0 26 0x13))
    Add-ExpectedInstruction (Encode-JType 12 $jalLinkRegister) $jalLinkRegister $true (To-UInt32 (($program.Count * 4) + 4))
    $program.Add((Encode-IType (380 + $Index) 0 0 27 0x13))
    $program.Add((Encode-IType (400 + $Index) 0 0 28 0x13))
    Add-ExpectedInstruction (Encode-IType $TargetValue 0 0 $jalTargetRegister 0x13) $jalTargetRegister $true (To-UInt32 $TargetValue)

    $jalrTargetPc = [uint32](($program.Count + 4) * 4)
    Add-ExpectedInstruction (Encode-IType ([int]$jalrTargetPc) 0 0 $jalrBaseRegister 0x13) $jalrBaseRegister $true $jalrTargetPc
    Add-ExpectedInstruction (Encode-BType 8 $leftRegister $leftRegister 1) 0 $false ([uint32]0)
    Add-ExpectedInstruction (Encode-IType 0 $jalrBaseRegister 0 $jalrLinkRegister 0x67) $jalrLinkRegister $true (To-UInt32 (($program.Count * 4) + 4))
    $program.Add((Encode-IType (420 + $Index) 0 0 29 0x13))
    Add-ExpectedInstruction (Encode-IType ($TargetValue + 1) 0 0 $jalrTargetRegister 0x13) $jalrTargetRegister $true (To-UInt32 ($TargetValue + 1))
}

function Add-GeneratedHazardCase {
    param([int]$Index, [int]$BaseImmediate, [int]$OffsetImmediate)

    $baseRegister = 10
    $dependentRegister = 11
    $sumRegister = 12
    $xorRegister = 13

    Add-ExpectedInstruction (Encode-IType $BaseImmediate 0 0 $baseRegister 0x13) $baseRegister $true (To-UInt32 $BaseImmediate)

    $dependentValue = To-UInt32 ([int64]$registers[$baseRegister] + $OffsetImmediate)
    Add-ExpectedInstruction (Encode-IType $OffsetImmediate $baseRegister 0 $dependentRegister 0x13) $dependentRegister $true $dependentValue

    $sumValue = To-UInt32 ([uint64]$registers[$dependentRegister] + [uint64]$registers[$baseRegister])
    Add-ExpectedInstruction (Encode-RType 0 $baseRegister $dependentRegister 0 $sumRegister) $sumRegister $true $sumValue

    $xorValue = To-UInt32 ($registers[$sumRegister] -bxor $registers[$dependentRegister])
    Add-ExpectedInstruction (Encode-RType 0 $dependentRegister $sumRegister 4 $xorRegister) $xorRegister $true $xorValue
}

function Add-GeneratedHazardChainCase {
    param([int]$Index, [int]$BaseImmediate, [int]$ShiftAmount)

    $baseRegister = 10
    $shiftRegister = 11
    $leftShiftRegister = 12
    $rightShiftRegister = 13
    $compareRegister = 14
    $andRegister = 15
    $orRegister = 16

    Add-ExpectedInstruction (Encode-IType $BaseImmediate 0 0 $baseRegister 0x13) $baseRegister $true (To-UInt32 $BaseImmediate)
    Add-ExpectedInstruction (Encode-IType $ShiftAmount 0 0 $shiftRegister 0x13) $shiftRegister $true (To-UInt32 $ShiftAmount)

    $leftShiftValue = To-UInt32 ([uint64]$registers[$baseRegister] -shl ($registers[$shiftRegister] -band 0x1f))
    Add-ExpectedInstruction (Encode-RType 0 $shiftRegister $baseRegister 1 $leftShiftRegister) $leftShiftRegister $true $leftShiftValue

    $rightShiftValue = To-UInt32 ([uint32]$registers[$leftShiftRegister] -shr ($registers[$shiftRegister] -band 0x1f))
    Add-ExpectedInstruction (Encode-RType 0 $shiftRegister $leftShiftRegister 5 $rightShiftRegister) $rightShiftRegister $true $rightShiftValue

    $compareValue = if ($registers[$rightShiftRegister] -lt $registers[$baseRegister]) { [uint32]1 } else { [uint32]0 }
    Add-ExpectedInstruction (Encode-RType 0 $baseRegister $rightShiftRegister 3 $compareRegister) $compareRegister $true $compareValue

    $andValue = To-UInt32 ($registers[$rightShiftRegister] -band $registers[$leftShiftRegister])
    Add-ExpectedInstruction (Encode-RType 0 $leftShiftRegister $rightShiftRegister 7 $andRegister) $andRegister $true $andValue

    $orValue = To-UInt32 ($registers[$andRegister] -bor $registers[$compareRegister])
    Add-ExpectedInstruction (Encode-RType 0 $compareRegister $andRegister 6 $orRegister) $orRegister $true $orValue
}

function Add-GeneratedLoadStoreCase {
    param([int]$Index, [int]$AddressOffset, [int]$ValueImmediate)

    $valueRegister = 18
    $loadRegister = 19
    $dependentRegister = 20

    Add-ExpectedInstruction (Encode-IType $ValueImmediate 0 0 $valueRegister 0x13) $valueRegister $true (To-UInt32 $ValueImmediate)
    Add-ExpectedInstruction (Encode-SType $AddressOffset $valueRegister 0 2) 0 $false ([uint32]0)

    Add-ExpectedInstruction (Encode-IType $AddressOffset 0 2 $loadRegister 0x03) $loadRegister $true $registers[$valueRegister]

    $dependentValue = To-UInt32 ([uint64]$registers[$loadRegister] + [uint64]($Index + 1))
    Add-ExpectedInstruction (Encode-IType ($Index + 1) $loadRegister 0 $dependentRegister 0x13) $dependentRegister $true $dependentValue
}

function Expand-SubwordLoadValue {
    param([int]$RawValue, [int]$LoadFunct3)

    switch ($LoadFunct3) {
        0 {
            if (($RawValue -band 0x80) -ne 0) {
                return To-UInt32 ($RawValue -bor 0xffffff00)
            }
            return To-UInt32 $RawValue
        }
        1 {
            if (($RawValue -band 0x8000) -ne 0) {
                return To-UInt32 ($RawValue -bor 0xffff0000)
            }
            return To-UInt32 $RawValue
        }
        4 { return To-UInt32 ($RawValue -band 0xff) }
        5 { return To-UInt32 ($RawValue -band 0xffff) }
        default { throw "Unsupported generated subword load funct3 $LoadFunct3" }
    }
}

function Add-GeneratedSubwordLoadStoreCase {
    param([int]$Index, [int]$AddressOffset, [int]$StoreFunct3, [int]$LoadFunct3, [int]$ValueImmediate)

    $valueRegister = 26
    $loadRegister = 27
    $dependentRegister = 28
    $mask = if ($StoreFunct3 -eq 0) { 0xff } else { 0xffff }

    Add-ExpectedInstruction (Encode-IType $ValueImmediate 0 0 $valueRegister 0x13) $valueRegister $true (To-UInt32 $ValueImmediate)
    Add-ExpectedInstruction (Encode-SType $AddressOffset $valueRegister 0 $StoreFunct3) 0 $false ([uint32]0)

    $rawValue = $registers[$valueRegister] -band $mask
    $loadValue = Expand-SubwordLoadValue $rawValue $LoadFunct3
    Add-ExpectedInstruction (Encode-IType $AddressOffset 0 $LoadFunct3 $loadRegister 0x03) $loadRegister $true $loadValue

    $dependentValue = To-UInt32 ([uint64]$registers[$loadRegister] + [uint64]($Index + 3))
    Add-ExpectedInstruction (Encode-IType ($Index + 3) $loadRegister 0 $dependentRegister 0x13) $dependentRegister $true $dependentValue
}

function Add-GeneratedOverlappingSubwordCase {
    param([int]$AddressOffset)

    $valueRegister = 18
    $wordLoadRegister = 19
    $byteLoadRegister = 20
    $halfLoadRegister = 21

    Add-ExpectedInstruction (Encode-IType 0x321 0 0 $valueRegister 0x13) $valueRegister $true (To-UInt32 0x321)
    Add-ExpectedInstruction (Encode-SType $AddressOffset $valueRegister 0 2) 0 $false ([uint32]0)
    $overlapWord = $registers[$valueRegister]

    Add-ExpectedInstruction (Encode-IType 0x7e 0 0 $valueRegister 0x13) $valueRegister $true (To-UInt32 0x7e)
    Add-ExpectedInstruction (Encode-SType ($AddressOffset + 1) $valueRegister 0 0) 0 $false ([uint32]0)
    $overlapWord = To-UInt32 (($overlapWord -band 0xffff00ff) -bor (($registers[$valueRegister] -band 0xff) -shl 8))

    Add-ExpectedInstruction (Encode-IType -2 0 0 $valueRegister 0x13) $valueRegister $true (To-UInt32 -2)
    Add-ExpectedInstruction (Encode-SType ($AddressOffset + 2) $valueRegister 0 1) 0 $false ([uint32]0)
    $overlapWord = To-UInt32 (($overlapWord -band 0x0000ffff) -bor (($registers[$valueRegister] -band 0xffff) -shl 16))

    Add-ExpectedInstruction (Encode-IType $AddressOffset 0 2 $wordLoadRegister 0x03) $wordLoadRegister $true $overlapWord
    Add-ExpectedInstruction (Encode-IType ($AddressOffset + 1) 0 4 $byteLoadRegister 0x03) $byteLoadRegister $true (To-UInt32 (($overlapWord -shr 8) -band 0xff))
    Add-ExpectedInstruction (Encode-IType ($AddressOffset + 2) 0 1 $halfLoadRegister 0x03) $halfLoadRegister $true (Expand-SubwordLoadValue (($overlapWord -shr 16) -band 0xffff) 1)
}

Add-ExpectedInstruction (Encode-IType 5 0 0 1 0x13) 1 $true (To-UInt32 5)
Add-ExpectedInstruction (Encode-IType 7 1 0 2 0x13) 2 $true (To-UInt32 12)
Add-ExpectedInstruction (Encode-RType 0 2 1 0 3) 3 $true (To-UInt32 17)
Add-ExpectedInstruction (Encode-IType 0x0ff 3 4 4 0x13) 4 $true (To-UInt32 (17 -bxor 0x0ff))
Add-ExpectedInstruction (Encode-IType 0x100 4 6 5 0x13) 5 $true (To-UInt32 ($registers[4] -bor 0x100))
Add-ExpectedInstruction (Encode-IType 0x0f0 5 7 6 0x13) 6 $true (To-UInt32 ($registers[5] -band 0x0f0))
Add-ExpectedInstruction (Encode-IType 1 6 1 7 0x13) 7 $true (To-UInt32 ([uint64]$registers[6] -shl 1))
Add-ExpectedInstruction (Encode-IType 2 7 5 8 0x13) 8 $true (To-UInt32 ([uint32]$registers[7] -shr 2))
Add-ExpectedInstruction (Encode-SType 0 8 0 2) 0 $false ([uint32]0)
$memoryWord = $registers[8]
Add-ExpectedInstruction (Encode-IType 0 0 2 9 0x03) 9 $true $memoryWord
Add-ExpectedInstruction (Encode-JType 8 10) 10 $true (To-UInt32 (($program.Count * 4) + 4))
$program.Add((Encode-IType 99 0 0 11 0x13))
Add-ExpectedInstruction (Encode-IType 42 0 0 12 0x13) 12 $true (To-UInt32 42)
Add-ExpectedInstruction (Encode-IType 0x45 0 0 13 0x13) 13 $true (To-UInt32 0x45)
Add-ExpectedInstruction (Encode-IType 0 13 0 14 0x67) 14 $true (To-UInt32 (($program.Count * 4) + 4))
$program.Add((Encode-IType 123 0 0 16 0x13))
$program.Add([uint32]0x00000013)
Add-ExpectedInstruction (Encode-IType 77 0 0 15 0x13) 15 $true (To-UInt32 77)
Add-ExpectedInstruction (Encode-BType 8 15 15 0) 0 $false ([uint32]0)
$program.Add((Encode-IType 88 0 0 17 0x13))
Add-ExpectedInstruction (Encode-IType 66 0 0 18 0x13) 18 $true (To-UInt32 66)
Add-ExpectedInstruction (Encode-BType 8 15 15 1) 0 $false ([uint32]0)
Add-ExpectedInstruction (Encode-IType 33 0 0 19 0x13) 19 $true (To-UInt32 33)
Add-ExpectedInstruction (Encode-SType 1 15 0 0) 0 $false ([uint32]0)
$memoryWord = To-UInt32 (($memoryWord -band 0xffff00ff) -bor (($registers[15] -band 0xff) -shl 8))
Add-ExpectedInstruction (Encode-IType 1 0 4 20 0x03) 20 $true (To-UInt32 (($memoryWord -shr 8) -band 0xff))
Add-ExpectedInstruction (Encode-SType 2 6 0 0) 0 $false ([uint32]0)
$memoryWord = To-UInt32 (($memoryWord -band 0xff00ffff) -bor (($registers[6] -band 0xff) -shl 16))
$signedByte = ($memoryWord -shr 16) -band 0xff
if (($signedByte -band 0x80) -ne 0) {
    $signedByte = $signedByte -bor 0xffffff00
}
Add-ExpectedInstruction (Encode-IType 2 0 0 21 0x03) 21 $true (To-UInt32 $signedByte)
Add-ExpectedInstruction (Encode-SType 0 5 0 1) 0 $false ([uint32]0)
$memoryWord = To-UInt32 (($memoryWord -band 0xffff0000) -bor ($registers[5] -band 0xffff))
Add-ExpectedInstruction (Encode-IType 0 0 5 22 0x03) 22 $true (To-UInt32 ($memoryWord -band 0xffff))
Add-ExpectedInstruction (Encode-IType -2 0 0 23 0x13) 23 $true (To-UInt32 -2)
Add-ExpectedInstruction (Encode-SType 0 23 0 1) 0 $false ([uint32]0)
$memoryWord = To-UInt32 (($memoryWord -band 0xffff0000) -bor ($registers[23] -band 0xffff))
$signedHalfword = $memoryWord -band 0xffff
if (($signedHalfword -band 0x8000) -ne 0) {
    $signedHalfword = $signedHalfword -bor 0xffff0000
}
Add-ExpectedInstruction (Encode-IType 0 0 1 24 0x03) 24 $true (To-UInt32 $signedHalfword)
Add-ExpectedInstruction (Encode-BType 8 2 1 6) 0 $false ([uint32]0)
$program.Add((Encode-IType 55 0 0 26 0x13))
Add-ExpectedInstruction (Encode-IType 99 0 0 25 0x13) 25 $true (To-UInt32 99)
Add-ExpectedInstruction (Encode-BType 8 1 23 4) 0 $false ([uint32]0)
$program.Add((Encode-IType 44 0 0 27 0x13))
Add-ExpectedInstruction (Encode-IType 77 0 0 28 0x13) 28 $true (To-UInt32 77)
Add-ExpectedInstruction (Encode-BType 8 23 1 4) 0 $false ([uint32]0)
Add-ExpectedInstruction (Encode-IType 88 0 0 29 0x13) 29 $true (To-UInt32 88)
Add-ExpectedInstruction (Encode-BType 8 23 1 5) 0 $false ([uint32]0)
$program.Add((Encode-IType 22 0 0 30 0x13))
Add-ExpectedInstruction (Encode-IType 11 0 0 31 0x13) 31 $true (To-UInt32 11)
Add-ExpectedInstruction (Encode-BType 8 1 23 7) 0 $false ([uint32]0)
$program.Add((Encode-IType 33 0 0 30 0x13))
Add-ExpectedInstruction (Encode-IType 12 0 0 31 0x13) 31 $true (To-UInt32 12)
Add-ExpectedInstruction (Encode-BType 8 1 23 5) 0 $false ([uint32]0)
Add-ExpectedInstruction (Encode-IType 24 0 0 30 0x13) 30 $true (To-UInt32 24)
Add-ExpectedInstruction (Encode-IType 13 0 0 31 0x13) 31 $true (To-UInt32 13)
Add-ExpectedInstruction (Encode-BType 8 23 1 7) 0 $false ([uint32]0)
Add-ExpectedInstruction (Encode-IType 25 0 0 30 0x13) 30 $true (To-UInt32 25)
Add-ExpectedInstruction (Encode-IType 14 0 0 31 0x13) 31 $true (To-UInt32 14)
Add-ExpectedInstruction (Encode-BType 12 1 1 0) 0 $false ([uint32]0)
$program.Add((Encode-IType 26 0 0 30 0x13))
$program.Add((Encode-IType 15 0 0 31 0x13))
Add-ExpectedInstruction (Encode-IType 90 0 0 29 0x13) 29 $true (To-UInt32 90)

$forwardToBackwardPc = [uint32]($program.Count * 4)
$forwardToBackward = Encode-BType 16 1 1 0
$program.Add($forwardToBackward)
$backwardTargetPc = [uint32]($program.Count * 4)
$backwardTarget = Encode-IType 91 0 0 29 0x13
$program.Add($backwardTarget)
$exitBranchPc = [uint32]($program.Count * 4)
$exitBranch = Encode-BType 16 1 1 0
$program.Add($exitBranch)
$program.Add((Encode-IType 27 0 0 30 0x13))
$backwardBranchPc = [uint32]($program.Count * 4)
$backwardBranch = Encode-BType -12 1 1 0
$program.Add($backwardBranch)
$program.Add((Encode-IType 16 0 0 31 0x13))
$exitTargetPc = [uint32]($program.Count * 4)
$exitTarget = Encode-IType 92 0 0 28 0x13
$program.Add($exitTarget)
Add-ExpectedTraceRow $forwardToBackwardPc $forwardToBackward 0 $false ([uint32]0)
Add-ExpectedTraceRow $backwardBranchPc $backwardBranch 0 $false ([uint32]0)
Add-ExpectedTraceRow $backwardTargetPc $backwardTarget 29 $true (To-UInt32 91)
Add-ExpectedTraceRow $exitBranchPc $exitBranch 0 $false ([uint32]0)
Add-ExpectedTraceRow $exitTargetPc $exitTarget 28 $true (To-UInt32 92)

$branchRandom = [System.Random]::new(4817)
$branchFunct3Values = @(0, 1, 4, 5, 6, 7)
for ($caseIndex = 0; $caseIndex -lt 8; $caseIndex++) {
    $funct3 = $branchFunct3Values[$branchRandom.Next(0, $branchFunct3Values.Count)]
    $leftImmediate = $branchRandom.Next(-8, 9)
    $rightImmediate = $branchRandom.Next(-8, 9)
    if (($caseIndex % 3) -eq 0) {
        $rightImmediate = $leftImmediate
    }
    Add-GeneratedBranchCase $caseIndex $funct3 $leftImmediate $rightImmediate
}

$jumpRandom = [System.Random]::new(7249)
for ($caseIndex = 0; $caseIndex -lt 3; $caseIndex++) {
    Add-GeneratedJumpCase $caseIndex ($jumpRandom.Next(208, 240))
}

$mixedBranchJumpRandom = [System.Random]::new(6151)
for ($caseIndex = 0; $caseIndex -lt 2; $caseIndex++) {
    Add-GeneratedMixedBranchJumpCase $caseIndex ($mixedBranchJumpRandom.Next(240, 272))
}

$hazardRandom = [System.Random]::new(9321)
for ($caseIndex = 0; $caseIndex -lt 4; $caseIndex++) {
    $baseImmediate = $hazardRandom.Next(-16, 17)
    $offsetImmediate = $hazardRandom.Next(1, 9)
    Add-GeneratedHazardCase $caseIndex $baseImmediate $offsetImmediate
}

$hazardChainRandom = [System.Random]::new(7843)
for ($caseIndex = 0; $caseIndex -lt 3; $caseIndex++) {
    $baseImmediate = $hazardChainRandom.Next(2, 64)
    $shiftAmount = $hazardChainRandom.Next(1, 4)
    Add-GeneratedHazardChainCase $caseIndex $baseImmediate $shiftAmount
}

$loadStoreRandom = [System.Random]::new(2401)
$loadStoreOffsets = @(4, 8, 12, 16)
for ($caseIndex = 0; $caseIndex -lt $loadStoreOffsets.Count; $caseIndex++) {
    $valueImmediate = $loadStoreRandom.Next(17, 96)
    Add-GeneratedLoadStoreCase $caseIndex $loadStoreOffsets[$caseIndex] $valueImmediate
}

$subwordCases = @(
    @{ AddressOffset = 20; StoreFunct3 = 0; LoadFunct3 = 4; ValueImmediate = 0x7e },
    @{ AddressOffset = 21; StoreFunct3 = 0; LoadFunct3 = 0; ValueImmediate = -5 },
    @{ AddressOffset = 24; StoreFunct3 = 1; LoadFunct3 = 5; ValueImmediate = 0x734 },
    @{ AddressOffset = 26; StoreFunct3 = 1; LoadFunct3 = 1; ValueImmediate = -9 }
)
for ($caseIndex = 0; $caseIndex -lt $subwordCases.Count; $caseIndex++) {
    $case = $subwordCases[$caseIndex]
    Add-GeneratedSubwordLoadStoreCase $caseIndex $case.AddressOffset $case.StoreFunct3 $case.LoadFunct3 $case.ValueImmediate
}

Add-GeneratedOverlappingSubwordCase 28

Add-ExpectedInstruction (Encode-IType 0 0 2 14 0x03) 14 $true $memoryWord
Add-ExpectedInstruction (Encode-IType 5 14 0 15 0x13) 15 $true (To-UInt32 ([uint64]$registers[14] + 5))
Add-ExpectedInstruction (Encode-IType 0 0 2 16 0x03) 16 $true $memoryWord
Add-ExpectedInstruction (Encode-IType 9 16 0 16 0x13) 16 $true (To-UInt32 ([uint64]$registers[16] + 9))
Add-ExpectedInstruction (Encode-SType 0 16 0 2) 0 $false ([uint32]0)
$memoryWord = $registers[16]
Add-ExpectedInstruction (Encode-IType 0 0 2 17 0x03) 17 $true $memoryWord

Add-CsrReadbackVariant 0x300 11 12 0x55
Add-CsrReadbackVariant 0x305 14 15 0x180
Add-CsrReadbackVariant 0x342 18 19 0x20

$mretTargetPc = [uint32](($program.Count + 6) * 4)
Add-ExpectedInstruction (Encode-IType ([int]$mretTargetPc) 0 0 5 0x13) 5 $true $mretTargetPc
Add-ExpectedInstruction (Encode-Csr 0x341 5 1 8) 8 $true ([uint32]$csrValues[0x341])
$csrValues[0x341] = Apply-CsrWriteSemantics 0x341 $registers[5]
Add-ExpectedInstruction (Encode-Csr 0x341 0 2 9) 9 $true ([uint32]$csrValues[0x341])
Add-ExpectedInstruction (Encode-Csr 0x341 0 3 10) 10 $true ([uint32]$csrValues[0x341])
Add-ExpectedInstruction ([uint32]0x30200073) 0 $false ([uint32]0)
$program.Add((Encode-IType 66 0 0 6 0x13))
Add-ExpectedInstruction (Encode-IType 77 0 0 7 0x13) 7 $true (To-UInt32 77)

for ($i = 0; $i -lt 3; $i++) {
    Add-ExpectedInstruction ([uint32]0x00000013) 0 $false ([uint32]0)
}

$hexLines = @($program | ForEach-Object { Format-HexWord $_ })
$expectedLines = @($expected)

if ($Check) {
    $existingHex = if (Test-Path $hexPath) { @(Get-Content $hexPath) } else { @() }
    $existingExpected = if (Test-Path $expectedPath) { @(Get-Content $expectedPath) } else { @() }
    if (($hexLines -join "`n") -ne ($existingHex -join "`n")) {
        throw "Generated trace reference program differs from fixtures/generated/reference/trace_reference.hex. Run scripts\trace-reference.ps1 to update it."
    }
    if (($expectedLines -join "`n") -ne ($existingExpected -join "`n")) {
        throw "Generated trace reference expected rows differ from fixtures/generated/reference/trace_reference_expected.hex. Run scripts\trace-reference.ps1 to update it."
    }
    Write-Host "PASS: trace reference image and expected rows match"
} else {
    Set-Content -Path $hexPath -Value $hexLines -Encoding Ascii
    Set-Content -Path $expectedPath -Value $expectedLines -Encoding Ascii
    Write-Host "Generated fixtures/generated/reference/trace_reference.hex and fixtures/generated/reference/trace_reference_expected.hex"
}

if (-not $SkipSimulation) {
    & (Join-Path $PSScriptRoot "run.ps1") -Test trace_reference
}
