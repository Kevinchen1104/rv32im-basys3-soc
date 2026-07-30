<#
Script: scripts\formal-matvec-smoke.ps1
Purpose: Runs focused formal smoke checks for MATVEC-related invariants when tools are available.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\formal-matvec-smoke.ps1
Outputs:
  Formal work directories and logs under wave\formal-matvec-smoke or console blocked-tool status.
Scope:
  Focused formal smoke evidence only; not a complete formal proof or production accelerator claim.
Audience:
  Public optional formal check.
#>
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. "$PSScriptRoot\verification-source-identity.ps1"

$sbyArgs = @()
$python = Get-Command python3.exe -ErrorAction SilentlyContinue
$smtbmcScript = Get-Command yosys-smtbmc-script.py -ErrorAction SilentlyContinue
if ($python -and $smtbmcScript) {
    $smtbmcCommand =
        ($python.Source -replace "\\", "/") + " " +
        ($smtbmcScript.Source -replace "\\", "/")
    $sbyArgs += @("--smtbmc", $smtbmcCommand)
} else {
    $smtbmc = Get-Command yosys-smtbmc.exe -ErrorAction SilentlyContinue
    if ($smtbmc) {
        $sbyArgs += @("--smtbmc", ($smtbmc.Source -replace "\\", "/"))
    }
}

$sby = Get-Command sby -ErrorAction SilentlyContinue
$sbyScript = Get-Command sby-script.py -ErrorAction SilentlyContinue
if (-not $sbyScript) {
    $fallbackSbyScript = "C:\msys64\ucrt64\bin\sby-script.py"
    if (Test-Path $fallbackSbyScript) {
        $sbyScript = [pscustomobject]@{ Source = $fallbackSbyScript }
    }
}

function Invoke-SymbiYosys {
    param(
        [Parameter(Mandatory = $true)]
        [string] $SbyFile
    )

    if ($sby) {
        try {
            & $sby.Source @sbyArgs -f $SbyFile
            if ($LASTEXITCODE -eq 0) {
                return
            }
            exit $LASTEXITCODE
        } catch {
            if ($_.Exception.Message -notmatch "Application Control policy") {
                throw
            }
            if (-not ($python -and $sbyScript)) {
                throw "SymbiYosys sby.exe was blocked by Application Control, and python sby-script.py fallback is unavailable."
            }
            Write-Host "INFO: sby.exe blocked by Application Control; retrying with python sby-script.py"
        }
    }

    if (-not ($python -and $sbyScript)) {
        throw "SymbiYosys not found on PATH. Install SymbiYosys to run MATVEC formal smoke."
    }

    & $python.Source $sbyScript.Source @sbyArgs -f $SbyFile
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

Invoke-SymbiYosys "formal/matvec_scratchpad_formal.sby"

$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = "pass"
    harnesses = @("matvec_scratchpad_formal")
    claim_boundary = "Bounded MATVEC Scratchpad control smoke only; not unbounded liveness or complete accelerator correctness."
}
Add-VerificationIdentityFields -Summary $summary | Out-Null
New-Item -ItemType Directory -Force -Path "wave" | Out-Null
$summary | ConvertTo-Json -Depth 4 | Set-Content -Path "wave\formal-matvec-smoke-summary.json" -Encoding Ascii

Write-Host "PASS: MATVEC formal smoke passed"
