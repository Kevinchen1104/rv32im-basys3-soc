<#
Script: scripts\verification-source-identity-self-test.ps1
Purpose: Checks line-ending normalization and raw binary hashing used by verification provenance.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\verification-source-identity-self-test.ps1
Outputs:
  Temporary fixtures under build\tests\, removed before exit.
Scope:
  Hashing-policy self-test only; does not run RTL, tools, or hardware.
#>
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. "$PSScriptRoot\verification-source-identity.ps1"

New-Item -ItemType Directory -Force -Path "build/tests" | Out-Null
$lfPath = "build\tests\verification-identity-lf.txt"
$crlfPath = "build\tests\verification-identity-crlf.txt"
$binaryAPath = "build\tests\verification-identity-a.bin"
$binaryBPath = "build\tests\verification-identity-b.bin"
$documentationPath = "docs\.documentation-identity-self-test-$PID.md"

try {
    $orderedPaths = @(Get-OrdinalUniquePaths @('a_z', 'a-z', 'A_z', 'a-z'))
    if (($orderedPaths -join ',') -cne 'A_z,a-z,a_z') {
        throw 'Source identity requires ordinal, case-sensitive path ordering.'
    }
    [System.IO.File]::WriteAllBytes(
        $lfPath,
        [System.Text.Encoding]::UTF8.GetBytes("alpha`nbeta`n")
    )
    [System.IO.File]::WriteAllBytes(
        $crlfPath,
        [System.Text.Encoding]::UTF8.GetBytes("alpha`r`nbeta`r`n")
    )
    [System.IO.File]::WriteAllBytes($binaryAPath, [byte[]](0, 10, 255))
    [System.IO.File]::WriteAllBytes($binaryBPath, [byte[]](0, 13, 10, 255))

    if ((Get-VerificationFileSha256 $lfPath) -ne
        (Get-VerificationFileSha256 $crlfPath)) {
        throw "Text line-ending normalization is not stable."
    }
    if ((Get-VerificationFileSha256 $binaryAPath) -eq
        (Get-VerificationFileSha256 $binaryBPath)) {
        throw "Binary fixtures were not hashed as raw bytes."
    }
    [System.IO.File]::WriteAllText(
        $documentationPath,
        "documentation identity alpha`n",
        [System.Text.Encoding]::ASCII
    )
    $verificationFingerprintA =
        (Get-VerificationSourceIdentity).verification_input_fingerprint
    $documentationFingerprintA =
        (Get-DocumentationInputIdentity).documentation_input_fingerprint
    [System.IO.File]::WriteAllText(
        $documentationPath,
        "documentation identity beta`n",
        [System.Text.Encoding]::ASCII
    )
    $verificationFingerprintB =
        (Get-VerificationSourceIdentity).verification_input_fingerprint
    $documentationFingerprintB =
        (Get-DocumentationInputIdentity).documentation_input_fingerprint
    if ($verificationFingerprintA -ne $verificationFingerprintB) {
        throw "Documentation-only changes invalidated the functional verification fingerprint."
    }
    if ($documentationFingerprintA -eq $documentationFingerprintB) {
        throw "Documentation input changes did not change the documentation fingerprint."
    }
    Write-Host "PASS: verification identities normalize text, preserve binary bytes, and bind documentation inputs"
} finally {
    foreach ($path in @(
        $lfPath,
        $crlfPath,
        $binaryAPath,
        $binaryBPath,
        $documentationPath
    )) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}
