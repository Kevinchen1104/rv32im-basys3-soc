<#
Script: scripts\assemble.ps1
Purpose: Assembles repository firmware sources into deterministic hex images.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\assemble.ps1 -Check
Outputs:
  firmware\hex\*.hex images or check-mode freshness messages.
#>
param(
    [string[]]$Programs = @("sum", "call_add", "nested_call", "stack_call", "memory_unsigned", "upper_branch", "alu_ops", "muldiv_ops", "csr_trap", "mret_trap", "mstatus_trap_return", "privileged_csr_edges", "exception_mcause_mtval", "misaligned_exception", "misaligned_control_after_branch", "access_fault_misaligned_control", "abi_call", "li_constants", "address_labels", "pointer_store", "array_sum", "byte_array_sum", "halfword_array_sum", "sum_function", "nested_sum_function", "byte_directive_sum", "half_directive_sum", "string_sum", "strlen_function", "strcmp_function", "string_escape_sum", "count_char_function", "counter_loop", "perf_mmio_read", "uart_gpio_demo", "uart_rx_back_to_back", "debug_status_victim_store", "showcase_demo", "interactive_showcase_demo", "hardware_validation_suite", "matvec_scratchpad_demo", "matvec_scratchpad_interrupt", "matvec_scratchpad_no_interrupt", "matvec_dma_demo", "machine_timer_interrupt", "machine_timer_no_interrupt", "compliance_basic", "rv32i_alu_compliance", "rv32i_control_compliance", "rv32i_memory_compliance", "rv32m_compliance", "board_smoke", "led_smoke"),
    [string]$ProgramDirectory = "",
    [string]$FirmwareSourceRoot = "firmware/src",
    [string]$FirmwareHexRoot = "firmware/hex",
    [switch]$Check,
    [switch]$All
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$programRoot = $null
if (-not [string]::IsNullOrWhiteSpace($ProgramDirectory)) {
    $programRoot = if ([System.IO.Path]::IsPathRooted($ProgramDirectory)) {
        Resolve-Path $ProgramDirectory
    } else {
        Resolve-Path (Join-Path $repoRoot $ProgramDirectory)
    }
}
$firmwareSourceRootPath = if ([System.IO.Path]::IsPathRooted($FirmwareSourceRoot)) {
    Resolve-Path $FirmwareSourceRoot
} else {
    Resolve-Path (Join-Path $repoRoot $FirmwareSourceRoot)
}
$firmwareHexRootPath = if ([System.IO.Path]::IsPathRooted($FirmwareHexRoot)) {
    [System.IO.Path]::GetFullPath($FirmwareHexRoot)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $FirmwareHexRoot))
}

function Resolve-ProgramImagePaths {
    param([string]$Program)

    if ($null -ne $programRoot) {
        return [pscustomobject]@{
            SourcePath = Join-Path $programRoot "$Program.S"
            HexPath = Join-Path $programRoot "$Program.hex"
        }
    }

    $matches = @(Get-ChildItem -LiteralPath $firmwareSourceRootPath -Recurse -File -Filter "$Program.S")
    if ($matches.Count -eq 0) {
        throw "Assembly source not found under $firmwareSourceRootPath`: $Program.S"
    }
    if ($matches.Count -gt 1) {
        throw "Assembly source name is ambiguous: $Program.S"
    }

    $sourcePath = $matches[0].FullName
    $sourceDir = Split-Path -Parent $sourcePath
    $relativeCategory = $sourceDir.Substring($firmwareSourceRootPath.Path.Length).TrimStart('\','/')
    $hexDir = if ([string]::IsNullOrWhiteSpace($relativeCategory)) {
        $firmwareHexRootPath
    } else {
        Join-Path $firmwareHexRootPath $relativeCategory
    }
    New-Item -ItemType Directory -Force -Path $hexDir | Out-Null
    return [pscustomobject]@{
        SourcePath = $sourcePath
        HexPath = Join-Path $hexDir "$Program.hex"
    }
}
function Fail-Assembly {
    param(
        [string]$Source,
        [int]$Line,
        [string]$Message
    )

    throw "${Source}:${Line}: $Message"
}

function Parse-Register {
    param(
        [string]$Token,
        [string]$Source,
        [int]$Line
    )

    $name = $Token.ToLowerInvariant()
    $aliases = @{
        zero = 0; ra = 1; sp = 2; gp = 3; tp = 4
        t0 = 5; t1 = 6; t2 = 7; s0 = 8; fp = 8; s1 = 9
        a0 = 10; a1 = 11; a2 = 12; a3 = 13; a4 = 14; a5 = 15; a6 = 16; a7 = 17
        s2 = 18; s3 = 19; s4 = 20; s5 = 21; s6 = 22; s7 = 23; s8 = 24; s9 = 25; s10 = 26; s11 = 27
        t3 = 28; t4 = 29; t5 = 30; t6 = 31
    }

    if ($aliases.ContainsKey($name)) {
        return [int]$aliases[$name]
    }

    if ($name -notmatch '^x([0-9]|[12][0-9]|3[01])$') {
        Fail-Assembly $Source $Line "expected an RV32I register name, got '$Token'"
    }
    return [int]$Matches[1]
}

function Parse-Immediate {
    param(
        [string]$Token,
        [string]$Source,
        [int]$Line
    )

    try {
        return [int]$Token
    } catch {
        Fail-Assembly $Source $Line "expected an integer immediate, got '$Token'"
    }
}

function Parse-Csr {
    param(
        [string]$Token,
        [string]$Source,
        [int]$Line
    )

    $name = $Token.ToLowerInvariant()
    $aliases = @{
        mstatus = 0x300
        mie = 0x304
        mtvec = 0x305
        mepc = 0x341
        mcause = 0x342
        mtval = 0x343
        mip = 0x344
    }

    if ($aliases.ContainsKey($name)) {
        return [int]$aliases[$name]
    }

    $value = Parse-Immediate $Token $Source $Line
    Require-UnsignedRange $value 12 $Source $Line
    return $value
}

function Parse-WordImmediate {
    param(
        [string]$Token,
        [string]$Source,
        [int]$Line
    )

    try {
        if ($Token -match '^0[xX]([0-9a-fA-F]+)$') {
            $value = [Convert]::ToInt64($Matches[1], 16)
        } else {
            $value = [int64]$Token
        }
    } catch {
        Fail-Assembly $Source $Line "expected a 32-bit integer immediate, got '$Token'"
    }

    if ($value -lt -2147483648 -or $value -gt 4294967295) {
        Fail-Assembly $Source $Line "immediate $Token does not fit in 32 bits"
    }

    if ($value -gt 2147483647) {
        return $value - 4294967296
    }
    return $value
}

function Parse-ByteImmediate {
    param(
        [string]$Token,
        [string]$Source,
        [int]$Line
    )

    $value = Parse-WordImmediate $Token $Source $Line
    if ($value -lt 0 -or $value -gt 255) {
        Fail-Assembly $Source $Line "byte value $Token does not fit in 8 bits"
    }
    return [int]$value
}

function Parse-HalfImmediate {
    param(
        [string]$Token,
        [string]$Source,
        [int]$Line
    )

    $value = Parse-WordImmediate $Token $Source $Line
    if ($value -lt 0 -or $value -gt 65535) {
        Fail-Assembly $Source $Line "halfword value $Token does not fit in 16 bits"
    }
    return [int]$value
}

function Parse-StringLiteral {
    param(
        [string]$Text,
        [string]$Source,
        [int]$Line
    )

    if ($Text -notmatch '^\.string\s+"(.*)"\s*$') {
        Fail-Assembly $Source $Line 'usage: .string "text"'
    }

    $body = $Matches[1]
    $bytes = [System.Collections.Generic.List[int]]::new()
    for ($index = 0; $index -lt $body.Length; $index++) {
        $char = $body[$index]
        if ($char -eq '\') {
            $index++
            if ($index -ge $body.Length) {
                Fail-Assembly $Source $Line "unfinished string escape"
            }

            $escaped = $body[$index]
            switch ($escaped) {
                '0' { $bytes.Add(0) }
                'n' { $bytes.Add(10) }
                'r' { $bytes.Add(13) }
                't' { $bytes.Add(9) }
                '"' { $bytes.Add(34) }
                '\' { $bytes.Add(92) }
                default { Fail-Assembly $Source $Line "unsupported string escape '\$escaped'" }
            }
        } else {
            $value = [int][char]$char
            if ($value -gt 127) {
                Fail-Assembly $Source $Line "only ASCII string characters are supported"
            }
            $bytes.Add($value)
        }
    }

    $bytes.Add(0)
    return $bytes.ToArray()
}

function Remove-AssemblyComment {
    param(
        [string]$Text,
        [string]$Source,
        [int]$Line
    )

    $inString = $false
    $escaped = $false
    for ($index = 0; $index -lt $Text.Length; $index++) {
        $char = $Text[$index]

        if ($escaped) {
            $escaped = $false
            continue
        }

        if ($inString -and $char -eq '\') {
            $escaped = $true
            continue
        }

        if ($char -eq '"') {
            $inString = -not $inString
            continue
        }

        if (-not $inString -and $char -eq '#') {
            return $Text.Substring(0, $index)
        }
    }

    if ($inString) {
        Fail-Assembly $Source $Line "unterminated string literal"
    }

    return $Text
}

function Require-SignedRange {
    param(
        [int]$Value,
        [int]$Bits,
        [string]$Source,
        [int]$Line
    )

    $minimum = -(1 -shl ($Bits - 1))
    $maximum = (1 -shl ($Bits - 1)) - 1
    if ($Value -lt $minimum -or $Value -gt $maximum) {
        Fail-Assembly $Source $Line "immediate $Value does not fit in signed $Bits bits"
    }
}

function Require-UnsignedRange {
    param(
        [int]$Value,
        [int]$Bits,
        [string]$Source,
        [int]$Line
    )

    $maximum = (1 -shl $Bits) - 1
    if ($Value -lt 0 -or $Value -gt $maximum) {
        Fail-Assembly $Source $Line "immediate $Value does not fit in unsigned $Bits bits"
    }
}

function Resolve-Offset {
    param(
        [string]$Token,
        [hashtable]$Labels,
        [int]$Pc,
        [string]$Source,
        [int]$Line
    )

    if ($Labels.ContainsKey($Token)) {
        return [int]$Labels[$Token] - $Pc
    }
    return Parse-Immediate $Token $Source $Line
}

function Encode-IType {
    param([int]$Immediate, [int]$Rs1, [int]$Funct3, [int]$Rd, [int]$Opcode)

    return [uint32](([uint64]($Immediate -band 0xfff) -shl 20) -bor
                    ([uint64]$Rs1 -shl 15) -bor ([uint64]$Funct3 -shl 12) -bor
                    ([uint64]$Rd -shl 7) -bor [uint64]$Opcode)
}

function Encode-RType {
    param([int]$Funct7, [int]$Rs2, [int]$Rs1, [int]$Funct3, [int]$Rd)

    return [uint32](([uint64]$Funct7 -shl 25) -bor
                    ([uint64]$Rs2 -shl 20) -bor ([uint64]$Rs1 -shl 15) -bor
                    ([uint64]$Funct3 -shl 12) -bor ([uint64]$Rd -shl 7) -bor
                    [uint64]0x33)
}

function Encode-SType {
    param([int]$Immediate, [int]$Rs2, [int]$Rs1, [int]$Funct3, [int]$Opcode)

    return [uint32](([uint64](($Immediate -shr 5) -band 0x7f) -shl 25) -bor
                    ([uint64]$Rs2 -shl 20) -bor ([uint64]$Rs1 -shl 15) -bor
                    ([uint64]$Funct3 -shl 12) -bor
                    ([uint64]($Immediate -band 0x1f) -shl 7) -bor [uint64]$Opcode)
}

function Encode-BType {
    param([int]$Offset, [int]$Rs2, [int]$Rs1, [int]$Funct3)

    return [uint32](([uint64](($Offset -shr 12) -band 0x1) -shl 31) -bor
                    ([uint64](($Offset -shr 5) -band 0x3f) -shl 25) -bor
                    ([uint64]$Rs2 -shl 20) -bor ([uint64]$Rs1 -shl 15) -bor
                    ([uint64]$Funct3 -shl 12) -bor
                    ([uint64](($Offset -shr 1) -band 0xf) -shl 8) -bor
                    ([uint64](($Offset -shr 11) -band 0x1) -shl 7) -bor [uint64]0x63)
}

function Encode-JType {
    param([int]$Offset, [int]$Rd)

    return [uint32](([uint64](($Offset -shr 20) -band 0x1) -shl 31) -bor
                    ([uint64](($Offset -shr 1) -band 0x3ff) -shl 21) -bor
                    ([uint64](($Offset -shr 11) -band 0x1) -shl 20) -bor
                    ([uint64](($Offset -shr 12) -band 0xff) -shl 12) -bor
                    ([uint64]$Rd -shl 7) -bor [uint64]0x6f)
}

function Encode-UType {
    param([int]$Immediate, [int]$Rd, [int]$Opcode)

    return [uint32](([uint64]$Immediate -shl 12) -bor
                    ([uint64]$Rd -shl 7) -bor [uint64]$Opcode)
}

function Get-ItemByteCount {
    param(
        [string]$Text,
        [int]$Pc,
        [string]$Source,
        [int]$Line
    )

    $tokens = @((($Text -replace '[,()]', ' ') -split '\s+') |
                Where-Object { $_ -ne "" })
    $op = $tokens[0].ToLowerInvariant()
    if ($op -eq ".word") {
        if ($tokens.Count -ne 2) {
            Fail-Assembly $Source $Line "usage: .word value"
        }
        if (($Pc -band 3) -ne 0) {
            Fail-Assembly $Source $Line ".word at byte address $Pc is not word aligned; use .align 2"
        }
        [void](Parse-WordImmediate $tokens[1] $Source $Line)
        return 4
    }
    if ($op -eq ".byte") {
        if ($tokens.Count -ne 2) {
            Fail-Assembly $Source $Line "usage: .byte value"
        }
        [void](Parse-ByteImmediate $tokens[1] $Source $Line)
        return 1
    }
    if ($op -eq ".string") {
        return @((Parse-StringLiteral $Text $Source $Line)).Count
    }
    if ($op -eq ".half") {
        if ($tokens.Count -ne 2) {
            Fail-Assembly $Source $Line "usage: .half value"
        }
        if (($Pc -band 1) -ne 0) {
            Fail-Assembly $Source $Line ".half at byte address $Pc is not halfword aligned; use .align 1"
        }
        [void](Parse-HalfImmediate $tokens[1] $Source $Line)
        return 2
    }
    if ($op -eq ".align") {
        if ($tokens.Count -ne 2) {
            Fail-Assembly $Source $Line "usage: .align power"
        }
        $power = Parse-Immediate $tokens[1] $Source $Line
        if ($power -lt 0 -or $power -gt 2) {
            Fail-Assembly $Source $Line ".align power must be from 0 to 2"
        }
        $alignment = 1 -shl $power
        return ($alignment - ($Pc % $alignment)) % $alignment
    }
    if (($Pc -band 3) -ne 0) {
        Fail-Assembly $Source $Line "instruction at byte address $Pc is not word aligned; use .align 2"
    }
    if ($op -eq "la") {
        if ($tokens.Count -ne 3) {
            Fail-Assembly $Source $Line "usage: la rd, label"
        }
        return 8
    }
    if ($op -ne "li") {
        return 4
    }
    if ($tokens.Count -ne 3) {
        Fail-Assembly $Source $Line "usage: li rd, immediate"
    }

    $immediate = Parse-WordImmediate $tokens[2] $Source $Line
    if ($immediate -ge -2048 -and $immediate -le 2047) {
        return 4
    }
    return 8
}

function Assemble-Instruction {
    param(
        [pscustomobject]$Instruction,
        [hashtable]$Labels,
        [string]$Source
    )

    $tokens = @((($Instruction.Text -replace '[,()]', ' ') -split '\s+') |
                Where-Object { $_ -ne "" })
    $op = $tokens[0].ToLowerInvariant()
    $pc = [int]$Instruction.Pc
    $line = [int]$Instruction.Line

    switch ($op) {
        ".word" {
            if ($tokens.Count -ne 2) { Fail-Assembly $Source $line "usage: .word value" }
            $value = Parse-WordImmediate $tokens[1] $Source $line
            if ($value -lt 0) {
                $value += 4294967296
            }
            return [uint32]$value
        }
        "nop" {
            if ($tokens.Count -ne 1) { Fail-Assembly $Source $line "usage: nop" }
            return Encode-IType 0 0 0 0 0x13
        }
        "li" {
            if ($tokens.Count -ne 3) { Fail-Assembly $Source $line "usage: li rd, immediate" }
            $rd = Parse-Register $tokens[1] $Source $line
            $immediate = Parse-WordImmediate $tokens[2] $Source $line
            if ($immediate -ge -2048 -and $immediate -le 2047) {
                return Encode-IType $immediate 0 0 $rd 0x13
            }

            $upper = (($immediate + 2048) -shr 12) -band 0xfffff
            $lower = $immediate -band 0xfff
            if ($lower -ge 2048) {
                $lower -= 4096
            }
            $words = @()
            $words += Encode-UType $upper $rd 0x37
            $words += Encode-IType $lower $rd 0 $rd 0x13
            return $words
        }
        "la" {
            if ($tokens.Count -ne 3) { Fail-Assembly $Source $line "usage: la rd, label" }
            $rd = Parse-Register $tokens[1] $Source $line
            if (-not $Labels.ContainsKey($tokens[2])) {
                Fail-Assembly $Source $line "unknown label '$($tokens[2])'"
            }

            $offset = [int]$Labels[$tokens[2]] - $pc
            $upper = ($offset + 2048) -shr 12
            $lower = $offset - ($upper -shl 12)
            Require-SignedRange $lower 12 $Source $line

            $words = @()
            $words += Encode-UType ($upper -band 0xfffff) $rd 0x17
            $words += Encode-IType $lower $rd 0 $rd 0x13
            return $words
        }
        "mv" {
            if ($tokens.Count -ne 3) { Fail-Assembly $Source $line "usage: mv rd, rs" }
            $rd = Parse-Register $tokens[1] $Source $line
            $rs = Parse-Register $tokens[2] $Source $line
            return Encode-IType 0 $rs 0 $rd 0x13
        }
        "j" {
            if ($tokens.Count -ne 2) { Fail-Assembly $Source $line "usage: j label" }
            $offset = Resolve-Offset $tokens[1] $Labels $pc $Source $line
            Require-SignedRange $offset 21 $Source $line
            if (($offset -band 1) -ne 0) { Fail-Assembly $Source $line "jump offset $offset must be aligned to 2 bytes" }
            return Encode-JType $offset 0
        }
        "call" {
            if ($tokens.Count -ne 2) { Fail-Assembly $Source $line "usage: call label" }
            $offset = Resolve-Offset $tokens[1] $Labels $pc $Source $line
            Require-SignedRange $offset 21 $Source $line
            if (($offset -band 1) -ne 0) { Fail-Assembly $Source $line "call offset $offset must be aligned to 2 bytes" }
            return Encode-JType $offset 1
        }
        "ret" {
            if ($tokens.Count -ne 1) { Fail-Assembly $Source $line "usage: ret" }
            return Encode-IType 0 1 0 0 0x67
        }
        "ecall" {
            if ($tokens.Count -ne 1) { Fail-Assembly $Source $line "usage: ecall" }
            return [uint32]0x00000073
        }
        "ebreak" {
            if ($tokens.Count -ne 1) { Fail-Assembly $Source $line "usage: ebreak" }
            return [uint32]0x00100073
        }
        "mret" {
            if ($tokens.Count -ne 1) { Fail-Assembly $Source $line "usage: mret" }
            return [uint32]0x30200073
        }
        { $_ -eq "csrrw" -or $_ -eq "csrrs" -or $_ -eq "csrrc" } {
            if ($tokens.Count -ne 4) { Fail-Assembly $Source $line "usage: $op rd, csr, rs1" }
            $rd = Parse-Register $tokens[1] $Source $line
            $csr = Parse-Csr $tokens[2] $Source $line
            $rs1 = Parse-Register $tokens[3] $Source $line
            $funct3 = switch ($op) {
                "csrrw" { 1 }
                "csrrs" { 2 }
                "csrrc" { 3 }
            }
            return Encode-IType $csr $rs1 $funct3 $rd 0x73
        }
        { $_ -eq "add" -or $_ -eq "sub" -or $_ -eq "and" -or $_ -eq "or" -or
          $_ -eq "xor" -or $_ -eq "sll" -or $_ -eq "srl" -or $_ -eq "sra" -or
          $_ -eq "slt" -or $_ -eq "sltu" -or
          $_ -eq "mul" -or $_ -eq "mulh" -or $_ -eq "mulhsu" -or $_ -eq "mulhu" -or
          $_ -eq "div" -or $_ -eq "divu" -or $_ -eq "rem" -or $_ -eq "remu" } {
            if ($tokens.Count -ne 4) { Fail-Assembly $Source $line "usage: $op rd, rs1, rs2" }
            $rd = Parse-Register $tokens[1] $Source $line
            $rs1 = Parse-Register $tokens[2] $Source $line
            $rs2 = Parse-Register $tokens[3] $Source $line
            $funct3 = switch ($op) {
                "add"  { 0 }
                "sub"  { 0 }
                "sll"  { 1 }
                "slt"  { 2 }
                "sltu" { 3 }
                "xor"  { 4 }
                "srl"  { 5 }
                "sra"  { 5 }
                "mul"  { 0 }
                "mulh" { 1 }
                "mulhsu" { 2 }
                "mulhu" { 3 }
                "div"  { 4 }
                "divu" { 5 }
                "rem"  { 6 }
                "remu" { 7 }
                "or"   { 6 }
                "and"  { 7 }
            }
            $funct7 = if ($op -eq "sub" -or $op -eq "sra") {
                0x20
            } elseif ($op -eq "mul" -or $op -eq "mulh" -or $op -eq "mulhsu" -or $op -eq "mulhu" -or
                      $op -eq "div" -or $op -eq "divu" -or $op -eq "rem" -or $op -eq "remu") {
                0x01
            } else {
                0
            }
            return Encode-RType $funct7 $rs2 $rs1 $funct3 $rd
        }
        { $_ -eq "addi" -or $_ -eq "slti" -or $_ -eq "sltiu" -or
          $_ -eq "xori" -or $_ -eq "ori" -or $_ -eq "andi" } {
            if ($tokens.Count -ne 4) { Fail-Assembly $Source $line "usage: $op rd, rs1, immediate" }
            $rd = Parse-Register $tokens[1] $Source $line
            $rs1 = Parse-Register $tokens[2] $Source $line
            $immediate = Parse-Immediate $tokens[3] $Source $line
            Require-SignedRange $immediate 12 $Source $line
            $funct3 = switch ($op) {
                "addi"  { 0 }
                "slti"  { 2 }
                "sltiu" { 3 }
                "xori"  { 4 }
                "ori"   { 6 }
                "andi"  { 7 }
            }
            return Encode-IType $immediate $rs1 $funct3 $rd 0x13
        }
        { $_ -eq "slli" -or $_ -eq "srli" -or $_ -eq "srai" } {
            if ($tokens.Count -ne 4) { Fail-Assembly $Source $line "usage: $op rd, rs1, shift_amount" }
            $rd = Parse-Register $tokens[1] $Source $line
            $rs1 = Parse-Register $tokens[2] $Source $line
            $shiftAmount = Parse-Immediate $tokens[3] $Source $line
            Require-UnsignedRange $shiftAmount 5 $Source $line
            $funct3 = if ($op -eq "slli") { 1 } else { 5 }
            $immediate = if ($op -eq "srai") { 0x400 + $shiftAmount } else { $shiftAmount }
            return Encode-IType $immediate $rs1 $funct3 $rd 0x13
        }
        { $_ -eq "lui" -or $_ -eq "auipc" } {
            if ($tokens.Count -ne 3) { Fail-Assembly $Source $line "usage: $op rd, immediate" }
            $rd = Parse-Register $tokens[1] $Source $line
            $immediate = Parse-Immediate $tokens[2] $Source $line
            Require-UnsignedRange $immediate 20 $Source $line
            $opcode = if ($op -eq "lui") { 0x37 } else { 0x17 }
            return Encode-UType $immediate $rd $opcode
        }
        { $_ -eq "lb" -or $_ -eq "lh" -or $_ -eq "lw" -or
          $_ -eq "lbu" -or $_ -eq "lhu" } {
            if ($tokens.Count -ne 4) { Fail-Assembly $Source $line "usage: $op rd, immediate(rs1)" }
            $rd = Parse-Register $tokens[1] $Source $line
            $immediate = Parse-Immediate $tokens[2] $Source $line
            $rs1 = Parse-Register $tokens[3] $Source $line
            Require-SignedRange $immediate 12 $Source $line
            $funct3 = switch ($op) {
                "lb"  { 0 }
                "lh"  { 1 }
                "lw"  { 2 }
                "lbu" { 4 }
                "lhu" { 5 }
            }
            return Encode-IType $immediate $rs1 $funct3 $rd 0x03
        }
        { $_ -eq "sb" -or $_ -eq "sh" -or $_ -eq "sw" } {
            if ($tokens.Count -ne 4) { Fail-Assembly $Source $line "usage: $op rs2, immediate(rs1)" }
            $rs2 = Parse-Register $tokens[1] $Source $line
            $immediate = Parse-Immediate $tokens[2] $Source $line
            $rs1 = Parse-Register $tokens[3] $Source $line
            Require-SignedRange $immediate 12 $Source $line
            $funct3 = switch ($op) {
                "sb" { 0 }
                "sh" { 1 }
                "sw" { 2 }
            }
            return Encode-SType $immediate $rs2 $rs1 $funct3 0x23
        }
        { $_ -eq "beq" -or $_ -eq "bne" -or $_ -eq "blt" -or
          $_ -eq "bge" -or $_ -eq "bltu" -or $_ -eq "bgeu" } {
            if ($tokens.Count -ne 4) { Fail-Assembly $Source $line "usage: $op rs1, rs2, label" }
            $rs1 = Parse-Register $tokens[1] $Source $line
            $rs2 = Parse-Register $tokens[2] $Source $line
            $offset = Resolve-Offset $tokens[3] $Labels $pc $Source $line
            Require-SignedRange $offset 13 $Source $line
            if (($offset -band 1) -ne 0) { Fail-Assembly $Source $line "branch offset $offset must be aligned to 2 bytes" }
            $funct3 = switch ($op) {
                "beq"  { 0 }
                "bne"  { 1 }
                "blt"  { 4 }
                "bge"  { 5 }
                "bltu" { 6 }
                "bgeu" { 7 }
            }
            return Encode-BType $offset $rs2 $rs1 $funct3
        }
        "jal" {
            if ($tokens.Count -ne 3) { Fail-Assembly $Source $line "usage: jal rd, label" }
            $rd = Parse-Register $tokens[1] $Source $line
            $offset = Resolve-Offset $tokens[2] $Labels $pc $Source $line
            Require-SignedRange $offset 21 $Source $line
            if (($offset -band 1) -ne 0) { Fail-Assembly $Source $line "jump offset $offset must be aligned to 2 bytes" }
            return Encode-JType $offset $rd
        }
        "jalr" {
            if ($tokens.Count -ne 4) { Fail-Assembly $Source $line "usage: jalr rd, immediate(rs1)" }
            $rd = Parse-Register $tokens[1] $Source $line
            $immediate = Parse-Immediate $tokens[2] $Source $line
            $rs1 = Parse-Register $tokens[3] $Source $line
            Require-SignedRange $immediate 12 $Source $line
            return Encode-IType $immediate $rs1 0 $rd 0x67
        }
        default {
            Fail-Assembly $Source $line "unsupported instruction '$op'"
        }
    }
}

if ($All) {
    $sourceRoot = if ($programRoot) { $programRoot } else { $firmwareSourceRootPath }
    $Programs = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse:(!$programRoot) -File -Filter '*.S' | ForEach-Object BaseName | Sort-Object)
    if (-not $Programs.Count) { throw "No assembly sources found under $sourceRoot" }
}
foreach ($program in $Programs) {
    $paths = Resolve-ProgramImagePaths $program
    $sourcePath = $paths.SourcePath
    $hexPath = $paths.HexPath
    $hexDisplayPath = $hexPath
    if ($hexDisplayPath.StartsWith("$repoRoot\")) {
        $hexDisplayPath = $hexDisplayPath.Substring("$repoRoot\".Length)
    }
    $hexDisplayPath = $hexDisplayPath -replace '\\', '/'
    if (-not (Test-Path $sourcePath)) {
        throw "Assembly source not found: $sourcePath"
    }

    $labels = @{}
    $instructions = [System.Collections.Generic.List[object]]::new()
    $pc = 0
    $lineNumber = 0
    foreach ($originalLine in Get-Content $sourcePath) {
        $lineNumber++
        $line = (Remove-AssemblyComment $originalLine $sourcePath $lineNumber).Trim()
        if ($line -eq "") {
            continue
        }

        while ($line -match '^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$') {
            $label = $Matches[1]
            if ($labels.ContainsKey($label)) {
                Fail-Assembly $sourcePath $lineNumber "duplicate label '$label'"
            }
            $labels[$label] = $pc
            $line = $Matches[2].Trim()
            if ($line -eq "") {
                break
            }
        }

        if ($line -ne "") {
            $byteCount = Get-ItemByteCount $line $pc $sourcePath $lineNumber
            $instructions.Add([pscustomobject]@{ Text = $line; Pc = $pc; Size = $byteCount; Line = $lineNumber })
            $pc += $byteCount
        }
    }

    $imageBytes = [System.Collections.Generic.List[byte]]::new()
    foreach ($item in $instructions) {
        $tokens = @((($item.Text -replace '[,()]', ' ') -split '\s+') |
                    Where-Object { $_ -ne "" })
        $op = $tokens[0].ToLowerInvariant()

        if ($op -eq ".byte") {
            $imageBytes.Add([byte](Parse-ByteImmediate $tokens[1] $sourcePath $item.Line))
        } elseif ($op -eq ".string") {
            foreach ($byteValue in @(Parse-StringLiteral $item.Text $sourcePath $item.Line)) {
                $imageBytes.Add([byte]$byteValue)
            }
        } elseif ($op -eq ".half") {
            $half = Parse-HalfImmediate $tokens[1] $sourcePath $item.Line
            $imageBytes.Add([byte]($half -band 0xff))
            $imageBytes.Add([byte](($half -shr 8) -band 0xff))
        } elseif ($op -eq ".align") {
            for ($padding = 0; $padding -lt $item.Size; $padding++) {
                $imageBytes.Add([byte]0)
            }
        } else {
            foreach ($word in @(Assemble-Instruction $item $labels $sourcePath)) {
                $imageBytes.Add([byte]($word -band 0xff))
                $imageBytes.Add([byte](($word -shr 8) -band 0xff))
                $imageBytes.Add([byte](($word -shr 16) -band 0xff))
                $imageBytes.Add([byte](($word -shr 24) -band 0xff))
            }
        }
    }

    while (($imageBytes.Count % 4) -ne 0) {
        $imageBytes.Add([byte]0)
    }

    $hexLines = @()
    for ($offset = 0; $offset -lt $imageBytes.Count; $offset += 4) {
        $word = [uint32]$imageBytes[$offset] -bor
                ([uint32]$imageBytes[$offset + 1] -shl 8) -bor
                ([uint32]$imageBytes[$offset + 2] -shl 16) -bor
                ([uint32]$imageBytes[$offset + 3] -shl 24)
        $hexLines += "{0:x8}" -f $word
    }
    $generated = $hexLines -join "`n"
    $existing = if (Test-Path $hexPath) { (Get-Content $hexPath) -join "`n" } else { $null }

    if ($Check) {
        if ($generated -ne $existing) {
            throw "Generated image differs from $hexPath. Run scripts\assemble.ps1 to update it."
        }
        Write-Host "PASS: verified $hexDisplayPath ($($hexLines.Count) words)"
    } elseif ($generated -ne $existing) {
        Set-Content -Path $hexPath -Value $hexLines -Encoding Ascii
        Write-Host "Assembled $hexDisplayPath ($($hexLines.Count) words)"
    } else {
        Write-Host "Up to date: $hexDisplayPath ($($hexLines.Count) words)"
    }
}

if ($Check) {
    Write-Host "PASS: assembly program images match their sources"
}
