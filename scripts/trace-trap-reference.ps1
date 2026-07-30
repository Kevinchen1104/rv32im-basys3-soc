<#
Script: scripts\trace-trap-reference.ps1
Purpose: Generates or checks retired-trace reference fixtures for trap and wrong-path behavior.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\trace-trap-reference.ps1 -Check -SkipSimulation
Outputs:
  fixtures\generated\reference\trace_trap_reference* artifacts or freshness diagnostics.
Scope:
  Trace-reference regression evidence only; not complete trap proof or official compliance.
Audience:
  Internal helper used by scripts\check.ps1.
#>
param(
    [switch]$Check,
    [switch]$SkipSimulation
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$hexPath = Join-Path $repoRoot "fixtures/generated/reference/trace_trap_reference.hex"
$expectedPath = Join-Path $repoRoot "fixtures/generated/reference/trace_trap_reference_expected.hex"
$wrongPathPath = Join-Path $repoRoot "fixtures/generated/reference/trace_trap_reference_wrong_path.hex"
$jsonPath = Join-Path $repoRoot "fixtures/generated/reference/trace_trap_reference_expected.json"

function Normalize-TextForArtifactCompare {
    param([string]$Text)

    if ($null -eq $Text) {
        return ""
    }

    $normalized = $Text.TrimEnd()
    $normalized = $normalized -replace "`r`n", "`n"
    return ($normalized -replace "`r", "`n")
}

function To-UInt32 {
    param([int64]$Value)
    return [uint32]($Value -band 0xffffffffL)
}

function Encode-IType {
    param([int]$Immediate, [int]$Rs1, [int]$Funct3, [int]$Rd, [int]$Opcode)
    return [uint32](([uint64]($Immediate -band 0xfff) -shl 20) -bor
                    ([uint64]$Rs1 -shl 15) -bor
                    ([uint64]$Funct3 -shl 12) -bor
                    ([uint64]$Rd -shl 7) -bor [uint64]$Opcode)
}

function Encode-Csr {
    param([int]$Csr, [int]$Rs1, [int]$Funct3, [int]$Rd)
    return [uint32](([uint64]($Csr -band 0xfff) -shl 20) -bor
                    ([uint64]$Rs1 -shl 15) -bor
                    ([uint64]$Funct3 -shl 12) -bor
                    ([uint64]$Rd -shl 7) -bor [uint64]0x73)
}

function Format-HexWord {
    param([uint32]$Value)
    return "{0:x8}" -f $Value
}

function Format-TraceRow {
    param([uint32]$Pc, [uint32]$Instruction, [int]$Rd, [bool]$RegWrite, [uint32]$Value)

    $meta = [uint32]($Rd -band 0x1f)
    if ($RegWrite) {
        $meta = $meta -bor [uint32]0x20
    }

    return "{0}{1}{2}{3}" -f (Format-HexWord $Pc),
                              (Format-HexWord $Instruction),
                              (Format-HexWord $meta),
                              (Format-HexWord $Value)
}

function New-TraceEntry {
    param(
        [int]$Order,
        [uint32]$Pc,
        [uint32]$Instruction,
        [string]$Mnemonic,
        [string]$Kind,
        [int]$Rd,
        [bool]$RegWrite,
        [uint32]$Value,
        [string]$Note
    )

    return [pscustomobject]@{
        order = $Order
        pc = "0x{0:x8}" -f $Pc
        instruction_word = "0x{0:x8}" -f $Instruction
        mnemonic = $Mnemonic
        kind = $Kind
        rd = $Rd
        reg_write = $RegWrite
        writeback_value = if ($RegWrite) { "0x{0:x8}" -f $Value } else { $null }
        note = $Note
    }
}

$nop = [uint32]0x00000013
$ecall = [uint32]0x00000073
$mret = [uint32]0x30200073

$program = New-Object 'uint32[]' 15
for ($i = 0; $i -lt $program.Count; $i++) {
    $program[$i] = $nop
}

$addiMtvec = Encode-IType 32 0 0 5 0x13
$csrrwMtvec = Encode-Csr 0x305 5 1 0
$addiNormal = Encode-IType 7 0 0 6 0x13
$trapWrong0 = Encode-IType 88 0 0 8 0x13
$trapWrong1 = Encode-IType 89 0 0 9 0x13
$handlerAddi = Encode-IType 77 0 0 7 0x13
$addiMepc = Encode-IType 56 0 0 28 0x13
$csrrwMepc = Encode-Csr 0x341 28 1 0
$mretWrong0 = Encode-IType 99 0 0 10 0x13
$mretWrong1 = Encode-IType 100 0 0 11 0x13
$finalMarker = Encode-IType 0x7ad 0 0 30 0x13

$program[0] = $addiMtvec          # 0x00
$program[1] = $csrrwMtvec        # 0x04
$program[2] = $addiNormal        # 0x08
$program[3] = $ecall             # 0x0c
$program[4] = $trapWrong0        # 0x10
$program[5] = $trapWrong1        # 0x14
$program[8] = $handlerAddi       # 0x20
$program[9] = $addiMepc          # 0x24
$program[10] = $csrrwMepc        # 0x28
$program[11] = $mret             # 0x2c
$program[12] = $mretWrong0       # 0x30
$program[13] = $mretWrong1       # 0x34
$program[14] = $finalMarker      # 0x38

$expectedEntries = @(
    New-TraceEntry 0 0x00 $addiMtvec "addi x5, x0, 32" "normal" 5 $true (To-UInt32 32) "Prepare mtvec with the trap-handler PC."
    New-TraceEntry 1 0x04 $csrrwMtvec "csrrw x0, mtvec, x5" "normal" 0 $false 0 "Retired CSR setup row; rd=x0 is observable as no register write."
    New-TraceEntry 2 0x08 $addiNormal "addi x6, x0, 7" "normal" 6 $true (To-UInt32 7) "Normal retirement before the trap-causing ecall."
    New-TraceEntry 3 0x20 $handlerAddi "addi x7, x0, 77" "trap_handler" 7 $true (To-UInt32 77) "First retired trap-handler instruction after ecall redirects to mtvec."
    New-TraceEntry 4 0x24 $addiMepc "addi x28, x0, 56" "trap_handler" 28 $true (To-UInt32 56) "Prepare the explicit mret return target."
    New-TraceEntry 5 0x28 $csrrwMepc "csrrw x0, mepc, x28" "trap_handler" 0 $false 0 "Handler writes mepc for the directed return path; old value is not written because rd=x0."
    New-TraceEntry 6 0x2c $mret "mret" "mret" 0 $false 0 "mret retires as a non-writeback SYSTEM row and redirects to mepc."
    New-TraceEntry 7 0x38 $finalMarker "addi x30, x0, 0x7ad" "return_path" 30 $true (To-UInt32 0x7ad) "Final architectural completion marker on the mret target path."
)

$wrongPathPcs = @(
    [uint32]0x10,
    [uint32]0x14,
    [uint32]0x30,
    [uint32]0x34
)

$hexLines = @($program | ForEach-Object { Format-HexWord $_ })
$expectedLines = @($expectedEntries | ForEach-Object {
    Format-TraceRow ([uint32][Convert]::ToUInt32($_.pc.Substring(2), 16)) `
                    ([uint32][Convert]::ToUInt32($_.instruction_word.Substring(2), 16)) `
                    $_.rd `
                    $_.reg_write `
                    ($(if ($_.writeback_value) { [uint32][Convert]::ToUInt32($_.writeback_value.Substring(2), 16) } else { [uint32]0 }))
})
$wrongPathLines = @($wrongPathPcs | ForEach-Object { Format-HexWord $_ })

$json = [pscustomobject]@{
    schema_version = 1
    name = "trace_trap_reference"
    trace_contract = [ordered]@{
        observable_fields = @("trace_valid", "trace_pc", "trace_instruction", "trace_rd", "trace_reg_write", "trace_writeback_value")
        retired_only = $true
        trap_event_fields_present = $false
        faulting_ecall_trace_row = "not emitted by current RTL"
        wrong_path_rule = "fall-through instructions flushed by trap entry or mret redirect must not appear as retired trace rows"
        limitation = "This checks observable retired trace order only; CSR cause/PC side effects are checked by separate trap regressions."
    }
    expected_trace_rows = $expectedEntries
    wrong_path_pcs = @(
        [pscustomobject]@{ pc = "0x00000010"; note = "Fall-through instruction after ecall trap entry must not retire." }
        [pscustomobject]@{ pc = "0x00000014"; note = "Younger trap fall-through instruction must not retire." }
        [pscustomobject]@{ pc = "0x00000030"; note = "Fall-through instruction after mret redirect must not retire." }
        [pscustomobject]@{ pc = "0x00000034"; note = "Younger mret fall-through instruction must not retire." }
    )
    completion_marker = [ordered]@{
        pc = "0x00000038"
        register = "x30"
        value = "0x000007ad"
    }
    program_words = $hexLines.Count
}
$jsonText = $json | ConvertTo-Json -Depth 8

if ($Check) {
    $existingHex = if (Test-Path $hexPath) { @(Get-Content $hexPath) } else { @() }
    $existingExpected = if (Test-Path $expectedPath) { @(Get-Content $expectedPath) } else { @() }
    $existingWrongPath = if (Test-Path $wrongPathPath) { @(Get-Content $wrongPathPath) } else { @() }
    $existingJson = if (Test-Path $jsonPath) { Get-Content -Raw $jsonPath } else { "" }

    if (($hexLines -join "`n") -ne ($existingHex -join "`n")) {
        throw "Generated trace trap reference program differs from fixtures/generated/reference/trace_trap_reference.hex. Run scripts\trace-trap-reference.ps1 to update it."
    }
    if (($expectedLines -join "`n") -ne ($existingExpected -join "`n")) {
        throw "Generated trace trap reference expected rows differ from fixtures/generated/reference/trace_trap_reference_expected.hex. Run scripts\trace-trap-reference.ps1 to update it."
    }
    if (($wrongPathLines -join "`n") -ne ($existingWrongPath -join "`n")) {
        throw "Generated trace trap reference wrong-path rows differ from fixtures/generated/reference/trace_trap_reference_wrong_path.hex. Run scripts\trace-trap-reference.ps1 to update it."
    }
    if ((Normalize-TextForArtifactCompare $jsonText) -ne (Normalize-TextForArtifactCompare $existingJson)) {
        throw "Generated trace trap reference JSON differs from fixtures/generated/reference/trace_trap_reference_expected.json. Run scripts\trace-trap-reference.ps1 to update it."
    }

    Write-Host "PASS: trace trap reference artifacts match"
} else {
    Set-Content -Path $hexPath -Value $hexLines -Encoding Ascii
    Set-Content -Path $expectedPath -Value $expectedLines -Encoding Ascii
    Set-Content -Path $wrongPathPath -Value $wrongPathLines -Encoding Ascii
    Set-Content -Path $jsonPath -Value $jsonText -Encoding Ascii
    Write-Host "Generated trace trap reference artifacts"
}

if (-not $SkipSimulation) {
    & (Join-Path $PSScriptRoot "run.ps1") -Test trace_trap_reference
}
