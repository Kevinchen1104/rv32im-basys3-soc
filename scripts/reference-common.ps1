# Stateless encoding and file helpers shared by reference generators. Execution oracles remain separate.

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

function Split-LoadImmediate {
    param([uint32]$Value)
    # ADDI sign-extends its low 12 bits; LUI supplies the remaining bits modulo 2^32.
    $lower = [int]($Value -band 0xfff)
    if ($lower -ge 2048) { $lower -= 4096 }
    $upper = [int]((([int64]$Value - $lower) -shr 12) -band 0xfffff)
    return [pscustomobject]@{ Upper = $upper; Lower = $lower }
}

function Encode-IType {
    param([int]$Immediate, [int]$Rs1, [int]$Funct3, [int]$Rd, [int]$Opcode)
    return [uint32](([uint64]($Immediate -band 0xfff) -shl 20) -bor
                    ([uint64]$Rs1 -shl 15) -bor
                    ([uint64]$Funct3 -shl 12) -bor
                    ([uint64]$Rd -shl 7) -bor [uint64]$Opcode)
}

function Encode-RType {
    param([int]$Funct7, [int]$Rs2, [int]$Rs1, [int]$Funct3, [int]$Rd)
    return [uint32](([uint64]$Funct7 -shl 25) -bor
                    ([uint64]$Rs2 -shl 20) -bor
                    ([uint64]$Rs1 -shl 15) -bor
                    ([uint64]$Funct3 -shl 12) -bor
                    ([uint64]$Rd -shl 7) -bor [uint64]0x33)
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

function Format-TraceRow {
    param([uint32]$Pc, [uint32]$Instruction, [int]$Rd, [bool]$RegWrite, [uint32]$Value)
    $meta = [uint32]($Rd -band 0x1f)
    if ($RegWrite) { $meta = $meta -bor [uint32]0x20 }
    return '{0}{1}{2}{3}' -f (Format-HexWord $Pc), (Format-HexWord $Instruction),
                              (Format-HexWord $meta), (Format-HexWord $Value)
}

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
