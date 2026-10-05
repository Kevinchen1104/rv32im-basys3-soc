<#
Script: scripts\uart-boot-packet.ps1
Purpose: Builds or checks packetized UART boot images from firmware hex files.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\uart-boot-packet.ps1 -Hex firmware\hex\showcase\board_smoke.hex -Check
Outputs:
  fixtures\generated\boot\*.boot.bin packet images or freshness diagnostics.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$Hex,
    [string]$OutputBin = "",
    [switch]$DryRun,
    [switch]$Check,
    [string]$Port = "",
    [int]$Baud = 115200
)

. "$PSScriptRoot/reference-common.ps1"
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$magicWord = [uint32]0x52564254
$versionWord = [uint32]0x00000001
$startWordAddr = [uint32]0x00000000

function Resolve-RepoPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return (Join-Path $repoRoot $Path)
}

function Format-HexWord {
    param([uint32]$Value)
    return "0x{0:x8}" -f $Value
}

function Add-WordBytes {
    param(
        [System.Collections.Generic.List[byte]]$Bytes,
        [uint32]$Word
    )
    $Bytes.Add([byte]($Word -band 0xff))
    $Bytes.Add([byte](($Word -shr 8) -band 0xff))
    $Bytes.Add([byte](($Word -shr 16) -band 0xff))
    $Bytes.Add([byte](($Word -shr 24) -band 0xff))
}

function Test-ByteArraysEqual {
    param([byte[]]$Expected, [byte[]]$Actual)
    if ($Expected.Length -ne $Actual.Length) {
        return $false
    }
    for ($i = 0; $i -lt $Expected.Length; $i++) {
        if ($Expected[$i] -ne $Actual[$i]) {
            return $false
        }
    }
    return $true
}

$hexPath = Resolve-RepoPath $Hex
if (-not (Test-Path -LiteralPath $hexPath)) {
    throw "Hex file not found: $Hex"
}

$payloadWords = [System.Collections.Generic.List[uint32]]::new()
$lineNumber = 0
foreach ($rawLine in Get-Content -LiteralPath $hexPath) {
    $lineNumber++
    $line = $rawLine.Trim()
    if ($line -eq "" -or $line.StartsWith("#")) {
        continue
    }
    if ($line -notmatch '^[0-9a-fA-F]{1,8}$') {
        throw "Invalid hex word on line $lineNumber of $Hex`: '$line'"
    }
    $payloadWords.Add([uint32]([Convert]::ToUInt32($line, 16))) | Out-Null
}

$checksum = [uint32]0
foreach ($word in $payloadWords) {
    $checksum = To-UInt32 ([int64]$checksum + [int64]$word)
}

$packetBytes = [System.Collections.Generic.List[byte]]::new()
Add-WordBytes $packetBytes $magicWord
Add-WordBytes $packetBytes $versionWord
Add-WordBytes $packetBytes $startWordAddr
Add-WordBytes $packetBytes ([uint32]$payloadWords.Count)
Add-WordBytes $packetBytes $checksum
foreach ($word in $payloadWords) {
    Add-WordBytes $packetBytes $word
}

$packetArray = [byte[]]$packetBytes.ToArray()
$defaultFixture = Join-Path $repoRoot ("fixtures\generated\boot\{0}.boot.bin" -f [System.IO.Path]::GetFileNameWithoutExtension($hexPath))
$outputPath = if ([string]::IsNullOrWhiteSpace($OutputBin)) { "" } else { Resolve-RepoPath $OutputBin }

Write-Host "UART boot packet"
Write-Host "  hex: $hexPath"
Write-Host "  magic: $(Format-HexWord $magicWord)"
Write-Host "  version: $(Format-HexWord $versionWord)"
Write-Host "  start_word_addr: $(Format-HexWord $startWordAddr)"
Write-Host "  word_count: $($payloadWords.Count)"
Write-Host "  checksum: $(Format-HexWord $checksum)"
Write-Host "  byte_count: $($packetArray.Length)"
if (-not [string]::IsNullOrWhiteSpace($outputPath)) {
    Write-Host "  output_bin: $outputPath"
}
if ($DryRun) {
    Write-Host "  dry_run: true"
}

if ($Check) {
    if (-not (Test-Path -LiteralPath $defaultFixture)) {
        throw "Checked packet fixture not found: $defaultFixture"
    }
    $expectedBytes = [System.IO.File]::ReadAllBytes($defaultFixture)
    if (-not (Test-ByteArraysEqual $expectedBytes $packetArray)) {
        throw "Generated UART boot packet differs from checked fixture $defaultFixture"
    }
    Write-Host "PASS: UART boot packet fixture matches $defaultFixture"
}

if ($DryRun) {
    return
}

if (-not [string]::IsNullOrWhiteSpace($outputPath)) {
    $outputDirectory = Split-Path -Parent $outputPath
    if ($outputDirectory -ne "") {
        New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    }
    [System.IO.File]::WriteAllBytes($outputPath, $packetArray)
    Write-Host "Wrote UART boot packet to $outputPath"
}

if (-not [string]::IsNullOrWhiteSpace($Port)) {
    $serial = [System.IO.Ports.SerialPort]::new($Port, $Baud, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
    try {
        $serial.Open()
        $serial.Write($packetArray, 0, $packetArray.Length)
        Write-Host "Sent UART boot packet to $Port at $Baud baud"
    } finally {
        if ($serial.IsOpen) {
            $serial.Close()
        }
    }
}

if ([string]::IsNullOrWhiteSpace($outputPath) -and [string]::IsNullOrWhiteSpace($Port) -and -not $Check) {
    throw "Specify -OutputBin, -Port, -DryRun, or -Check"
}
