<#
Script: scripts\formal-smoke.ps1
Purpose: Runs portable formal smoke checks for selected core invariants when tools are available.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\formal-smoke.ps1
Outputs:
  Work files under build/formal; command logs under results/logs/formal; JSON summary under results/.
#>
param(
    [ValidateSet('Core', 'Matvec')][string]$Group = 'Core',
    [ValidateRange(1,86400)][int]$TimeoutSeconds = 900
)
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. "$PSScriptRoot\verification-source-identity.ps1"
. "$PSScriptRoot/process-runner.ps1"
$summaryPath = if ($Group -eq 'Core') { 'results/formal-smoke-summary.json' } else { 'results/formal-matvec-smoke-summary.json' }
$summary = [ordered]@{ status='running'; started_at_utc=(Get-Date).ToUniversalTime().ToString('o'); harnesses=@(); error_message=$null }
Write-ResultJson $summary $summaryPath
try {
$startingIdentity = Add-VerificationIdentityFields $summary

$sbyArgs = @()
$python = Get-Command python.exe, python3.exe -CommandType Application -All -ErrorAction SilentlyContinue |
    Where-Object { $_.Source -notmatch 'Microsoft\\WindowsApps' } | Select-Object -First 1
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
            $name = [IO.Path]::GetFileNameWithoutExtension($SbyFile)
            $result = Invoke-LoggedProcess -FilePath $sby.Source -Arguments (@($sbyArgs) + @('-f', '-d', "build/formal/$name", $SbyFile)) -LogPath "results/logs/formal/$name.log" -WorkingDirectory $repoRoot -TimeoutSeconds $TimeoutSeconds
            if ($result.status -eq 'passed') {
                return
            }
            throw "Formal check failed: $SbyFile. $($result.error_message) See $($result.log)"
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

    $name = [IO.Path]::GetFileNameWithoutExtension($SbyFile)
    $result = Invoke-LoggedProcess -FilePath $python.Source -Arguments (@($sbyScript.Source) + @($sbyArgs) + @('-f', '-d', "build/formal/$name", $SbyFile)) -LogPath "results/logs/formal/$name.log" -WorkingDirectory $repoRoot -TimeoutSeconds $TimeoutSeconds
    if ($result.status -ne 'passed') { throw "Formal check failed: $SbyFile. See $($result.log)" }
}

$harnesses = if ($Group -eq 'Core') {
    @('forwarding_alignment_equivalence', 'alu_result_classification',
      'registered_branch_miss_event', 'branch_predictor_payload_capture',
      'machine_timer_pending', 'trap_metadata_commit', 'x0_invariant')
} else { @('matvec_scratchpad_formal') }
foreach ($name in $harnesses) { Invoke-SymbiYosys "formal/$name.sby" }

$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = "pass"
    harnesses = @($harnesses)
    group = $Group
    method = 'SymbiYosys properties; modes and depths are specified in formal/*.sby'
    log_directory = 'results/logs/formal'
}
Assert-VerificationInputsUnchanged $startingIdentity
Add-VerificationIdentityFields -Summary $summary -Identity $startingIdentity | Out-Null
New-Item -ItemType Directory -Force -Path "results" | Out-Null
} catch {
    $summary.status = 'fail'
    $summary['error_message'] = $_.Exception.Message
    throw
} finally {
    $summary['generated_at_utc'] = (Get-Date).ToUniversalTime().ToString('o')
    Write-ResultJson $summary $summaryPath
}

Write-Host "PASS: optional formal smoke passed"
