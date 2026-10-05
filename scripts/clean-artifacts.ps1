# Preview rebuildable files; apply only explicitly selected categories.
param(
    [ValidateSet('Simulators','ToolScratch','LegacyFormal','RetiredCheckpoints')]
    [string[]]$Category = @('Simulators','ToolScratch'),
    [string[]]$RetiredBuildDirectory = @(),
    [switch]$Apply,
    [switch]$ListFiles
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. "$PSScriptRoot/artifact-paths.ps1"
. "$PSScriptRoot/result-format.ps1"
$tracked = @(& git -C $root ls-files)
if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate tracked source files.' }
$keepVivado = @('native_byte_lanes_10p0','native_byte_lanes_9p5','native_byte_lanes_9p0','basys3_full_100mhz_canonical')
$candidates = New-Object 'System.Collections.Generic.List[object]'
function Add-Candidates([string]$Scope, [string[]]$Extensions, [string]$Kind) {
    $directory = if ([IO.Path]::IsPathRooted($Scope)) { $Scope } else { Join-Path $root $Scope }
    if (-not (Test-Path -LiteralPath $directory)) { return }
    $null = Assert-ArtifactPath $root $directory
    foreach ($file in Get-ChildItem -LiteralPath $directory -File -Force -Recurse) {
        if ($Extensions.Count -and $file.Extension -notin $Extensions) { continue }
        $relative = $file.FullName.Substring($root.Length + 1).Replace('\','/')
        if ($Kind -eq 'RetiredCheckpoints' -and $relative.Split('/')[2] -in $keepVivado) { continue }
        $null = Assert-ArtifactPath $root $file.FullName
        if ($tracked -contains $relative) { throw "Refusing tracked artifact: $relative" }
        $candidates.Add([pscustomobject]@{path=$relative; bytes=$file.Length; category=$Kind})
    }
}
foreach ($kind in $Category | Select-Object -Unique) {
    switch ($kind) {
        'Simulators' {
            foreach ($scope in @('build/sim','build/arch-test','build/compiled-programs','build/matvec-benchmark','wave')) { Add-Candidates $scope @('.vvp') $kind }
        }
        'ToolScratch' {
            foreach ($file in Get-ChildItem -LiteralPath $root -File -Force | Where-Object {
                $_.Name -match '^vivado.*\.(log|jou)$|^clockInfo\.txt$|^tight_setup_hold_pins\.txt$'
            }) {
                $null = Assert-ArtifactPath $root $file.FullName
                if ($tracked -contains $file.Name) { throw "Refusing tracked file: $($file.Name)" }
                $candidates.Add([pscustomobject]@{path=$file.Name; bytes=$file.Length; category=$kind})
            }
            Add-Candidates '.Xil' @() $kind
        }
        'LegacyFormal' {
            foreach ($name in @('x0_invariant','matvec_scratchpad_formal','forwarding_alignment_equivalence','alu_result_classification','registered_branch_miss_event','branch_predictor_payload_capture','machine_timer_pending','trap_metadata_commit')) { Add-Candidates "formal/$name" @() $kind }
        }
        'RetiredCheckpoints' {
            if (-not $RetiredBuildDirectory.Count) {
                throw 'RetiredCheckpoints requires explicit -RetiredBuildDirectory paths under build/vivado/.'
            }
            $vivadoRoot = [IO.Path]::GetFullPath((Join-Path $root 'build/vivado'))
            foreach ($scope in $RetiredBuildDirectory) {
                $path = if ([IO.Path]::IsPathRooted($scope)) { $scope } else { Join-Path $root $scope }
                $directory = Assert-ArtifactPath $root $path
                if (-not $directory.StartsWith($vivadoRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'RetiredBuildDirectory must be a specific build beneath build/vivado/.'
                }
                if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw "Build directory not found: $scope" }
                Add-Candidates $directory @('.dcp','.rtd') $kind
            }
        }
    }
}
$files = @($candidates | Sort-Object path -Unique)
foreach ($group in $files | Group-Object category) {
    Write-Host ('{0}: {1} files, {2:N1} MiB' -f $group.Name,$group.Count,(($group.Group | Measure-Object bytes -Sum).Sum / 1MB))
}
if ($ListFiles) { $files | Format-Table category,path,bytes -AutoSize | Out-Host }
if (-not $Apply) {
    Write-Host 'Preview only. Add -Apply to remove these categories. Reports, bitstreams, dependencies, releases and results are retained.'
    exit 0
}
if (Get-Process -Name vivado,vvp,iverilog,ivl,yosys,sby -ErrorAction SilentlyContinue) { throw 'Finish FPGA/simulation/formal tools before cleanup.' }
$removed = New-Object 'System.Collections.Generic.List[object]'
$failure = $null
try {
    foreach ($file in $files) {
        $path = Assert-ArtifactPath $root (Join-Path $root $file.path)
        Remove-Item -LiteralPath $path -Force
        $removed.Add($file)
    }
} catch { $failure = $_.Exception.Message } finally {
    Write-ResultJson ([ordered]@{
        generated_at_utc=(Get-Date).ToUniversalTime().ToString('o')
        status=if ($failure) {'failed'} else {'pass'}
        categories=$Category; removed_count=$removed.Count
        removed_bytes=[long](($removed | Measure-Object bytes -Sum).Sum)
        error=$failure; files=$removed.ToArray()
    }) (Join-Path $root 'results/cleanup-summary.json')
}
if ($failure) { throw $failure }
Write-Host "Removed $($removed.Count) rebuildable files. Record: results/cleanup-summary.json"
