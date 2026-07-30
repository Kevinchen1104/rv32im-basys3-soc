<#
Script: scripts\formal-smoke.ps1
Purpose: Runs portable formal smoke checks for selected core invariants when tools are available.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\formal-smoke.ps1
Outputs:
  Formal work directories and logs under wave\formal-smoke or console blocked-tool status.
Scope:
  Focused formal smoke evidence only; not a complete formal proof.
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
        throw "SymbiYosys not found. Install sby/SymbiYosys to run optional formal smoke; scripts/check.ps1 remains the main release gate."
    }

    & $python.Source $sbyScript.Source @sbyArgs -f $SbyFile
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

Invoke-SymbiYosys "formal\forwarding_alignment_equivalence.sby"
Invoke-SymbiYosys "formal\alu_result_classification.sby"
Invoke-SymbiYosys "formal\registered_branch_miss_event.sby"
Invoke-SymbiYosys "formal\branch_predictor_payload_capture.sby"
Invoke-SymbiYosys "formal\machine_timer_pending.sby"
Invoke-SymbiYosys "formal\trap_metadata_commit.sby"
Invoke-SymbiYosys "formal\x0_invariant.sby"

$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = "pass"
    harnesses = @(
        "forwarding_alignment_equivalence",
        "alu_result_classification",
        "registered_branch_miss_event",
        "branch_predictor_payload_capture",
        "machine_timer_pending",
        "trap_metadata_commit",
        "x0_invariant"
    )
    claim_boundary = "Bounded formal smoke checks only; not complete CPU formal verification."
}
Add-VerificationIdentityFields -Summary $summary | Out-Null
New-Item -ItemType Directory -Force -Path "wave" | Out-Null
$summary | ConvertTo-Json -Depth 4 | Set-Content -Path "wave\formal-smoke-summary.json" -Encoding Ascii

Write-Host "PASS: optional formal smoke passed"
