<#
Script: scripts/process-runner.ps1
Purpose: Runs a native tool with a deadline and captures both output streams.
Common usage:
  . "$PSScriptRoot/process-runner.ps1"
Outputs:
  A per-command log and a result object with command, timestamps, status, and exit code.
Scope:
  Process execution and diagnostics.
#>

. "$PSScriptRoot/result-format.ps1"

function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Value)
    # Quote each argument, including embedded quotes and trailing backslashes.
    return '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function ConvertFrom-ProcessBytes {
    param([byte[]]$Bytes, [string]$EncodingName = 'auto')
    if ($EncodingName -ne 'auto') {
        return [Text.Encoding]::GetEncoding($EncodingName).GetString($Bytes)
    }
    # Native UTF-8 tools and Windows PowerShell's legacy console output coexist.
    # Never silently replace invalid UTF-8 bytes with U+FFFD.
    try { return (New-Object Text.UTF8Encoding($false, $true)).GetString($Bytes) }
    catch { return [Text.Encoding]::Default.GetString($Bytes) }
}

function ConvertFrom-ProcessCliXml {
    param([string]$Text)
    return [regex]::Replace($Text, '(?ms)^#< CLIXML\r?\n(<Objs\b.*?</Objs>)', {
        param($match)
        try {
            $objects = [Management.Automation.PSSerializer]::Deserialize($match.Groups[1].Value)
            return (@($objects | ForEach-Object {
                if ($_.PSObject.Properties['MessageData']) { [string]$_.MessageData }
                else { [string]$_ }
            }) -join "`n")
        } catch { return $match.Value }
    })
}

function Invoke-LoggedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$LogPath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 180,
        [string]$Label = '',
        [string]$OutputEncodingName = 'auto',
        [switch]$Quiet,
        [switch]$CaptureOutput
    )

    $started = (Get-Date).ToUniversalTime().ToString('o')
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $commandLine = (@(ConvertTo-NativeArgument $FilePath) + @(
        $Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }
    )) -join ' '
    $logTarget = if ([IO.Path]::IsPathRooted($LogPath)) { $LogPath } else { Join-Path $WorkingDirectory $LogPath }
    $fullLog = [System.IO.Path]::GetFullPath($logTarget)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fullLog) | Out-Null
    @("Task: $(if ($Label) { $Label } else { [IO.Path]::GetFileNameWithoutExtension($LogPath) })", "Started: $started", "Command: $commandLine", "Timeout: $TimeoutSeconds seconds") |
        Set-Content -LiteralPath $fullLog -Encoding UTF8

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo.FileName = $FilePath
    $process.StartInfo.Arguments = (@($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $process.StartInfo.WorkingDirectory = $WorkingDirectory
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $status = 'start_failed'
    $exitCode = $null
    $errorMessage = $null
    $stdout = ''
    $stderr = ''
    $didStart = $false
    $texts = $null
    try {
        $didStart = $process.Start()
        if (-not $didStart) { throw "Could not start $FilePath" }
        # Read chunks concurrently. The deadline includes pipe draining: a child
        # can inherit a pipe and keep it open after the parent has exited.
        $readers = @($process.StandardOutput.BaseStream, $process.StandardError.BaseStream)
        $buffers = @((New-Object byte[] 4096), (New-Object byte[] 4096))
        $texts = @([IO.MemoryStream]::new(), [IO.MemoryStream]::new())
        $tasks = @($readers[0].ReadAsync($buffers[0], 0, 4096), $readers[1].ReadAsync($buffers[1], 0, 4096))
        $done = @($false, $false)
        while ($clock.ElapsedMilliseconds -lt ($TimeoutSeconds * 1000)) {
            for ($i = 0; $i -lt 2; $i++) {
                if (-not $done[$i] -and $tasks[$i].IsCompleted) {
                    $count = $tasks[$i].GetAwaiter().GetResult()
                    if ($count -eq 0) { $done[$i] = $true }
                    else {
                        $texts[$i].Write($buffers[$i], 0, $count)
                        $tasks[$i] = $readers[$i].ReadAsync($buffers[$i], 0, 4096)
                    }
                }
            }
            if ($process.HasExited -and $done[0] -and $done[1]) { break }
            Start-Sleep -Milliseconds 10
        }
        $stdout = ConvertFrom-ProcessBytes $texts[0].ToArray() $OutputEncodingName
        $stderr = ConvertFrom-ProcessBytes $texts[1].ToArray() $OutputEncodingName
        if (-not ($process.HasExited -and $done[0] -and $done[1])) {
            $status = 'timed_out'
            $errorMessage = "Timed out after $TimeoutSeconds seconds (process and output streams)"
            # PowerShell 7 supports tree termination; Windows PowerShell 5.1 uses taskkill.
            if (-not $process.HasExited) {
                if ($PSVersionTable.PSVersion.Major -ge 7) { $process.Kill($true) }
                else {
                    $killer = [Diagnostics.Process]::Start([Diagnostics.ProcessStartInfo]@{
                        FileName = "$env:SystemRoot/System32/taskkill.exe"
                        Arguments = "/PID $($process.Id) /T /F"
                        UseShellExecute = $false
                        CreateNoWindow = $true
                    })
                    try { if (-not $killer.WaitForExit(5000)) { $killer.Kill() } }
                    finally { $killer.Dispose() }
                    if (-not $process.HasExited) { $process.Kill() }
                }
                [void]$process.WaitForExit(5000)
            }
        } else {
            $exitCode = $process.ExitCode
            $status = if ($exitCode -eq 0) { 'passed' } else { 'failed' }
        }
    } catch {
        $errorMessage = $_.Exception.Message
        if ($didStart) {
            $status = 'runner_failed'
            if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) }
            if ($texts) {
                $stdout = ConvertFrom-ProcessBytes $texts[0].ToArray() $OutputEncodingName
                $stderr = ConvertFrom-ProcessBytes $texts[1].ToArray() $OutputEncodingName
            }
        }
    } finally {
        $clock.Stop()
        $process.Dispose()
        if ($texts) { foreach ($stream in $texts) { $stream.Dispose() } }
    }
    $finished = (Get-Date).ToUniversalTime().ToString('o')
    $stdout = ConvertFrom-ProcessCliXml $stdout
    $stderr = ConvertFrom-ProcessCliXml $stderr
    $sections = @('')
    if ($stdout) { $sections += @('[stdout]', $stdout.TrimEnd()) }
    if ($stderr) { $sections += @('[stderr]', $stderr.TrimEnd()) }
    $sections += @('', "Result: $status", "Exit code: $exitCode")
    if ($errorMessage) { $sections += "Error: $errorMessage" }
    $sections += "Finished: $finished"
    $sections | Add-Content -LiteralPath $fullLog -Encoding UTF8
    if (-not $Quiet) {
        if ($stdout) { Write-Host $stdout.TrimEnd() }
        if ($stderr) { Write-Host $stderr.TrimEnd() }
        if ($errorMessage) { Write-Host $errorMessage }
    }
    $result = [pscustomobject][ordered]@{
        command = $commandLine
        executable = $FilePath
        arguments = @($Arguments)
        status = $status
        exit_code = $exitCode
        error_message = $errorMessage
        started_at_utc = $started
        finished_at_utc = $finished
        duration_ms = $clock.ElapsedMilliseconds
        log = $LogPath
        log_sha256 = (Get-FileHash -LiteralPath $fullLog -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    if ($CaptureOutput) {
        $outputLines = @((($stdout.TrimEnd() + "`n" + $stderr.TrimEnd()).Trim()) -split '\r?\n')
        $result | Add-Member -NotePropertyName output -NotePropertyValue $outputLines
    }
    return $result
}

function Invoke-LoggedVendorTool {
    param(
        [string]$FilePath, [string[]]$Arguments, [string]$LogPath,
        [string]$WorkingDirectory, [int]$TimeoutSeconds = 300
    )
    # Vendor launchers can be .bat files. PowerShell invokes those correctly;
    # single-quoted literals keep paths and Tcl arguments out of command syntax.
    $literals = @(@($FilePath) + $Arguments | ForEach-Object { "'" + $_.Replace("'", "''") + "'" })
    $command = '$ErrorActionPreference = ''Stop''; & ' + ($literals -join ' ') + '; exit $LASTEXITCODE'
    Invoke-LoggedProcess -FilePath 'powershell' -Arguments @('-NoProfile', '-Command', $command) `
        -LogPath $LogPath -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds
}

function Invoke-ChildPowerShell {
    param([string]$Description, [string[]]$Arguments)

    $safeName = ($Description -replace '[^a-zA-Z0-9_-]', '_')
    if ($safeName.Length -gt 48) { $safeName = $safeName.Substring(0, 48) }
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Description))).Replace('-', '').Substring(0, 12).ToLowerInvariant()
    } finally { $hasher.Dispose() }
    $result = Invoke-LoggedProcess -FilePath 'powershell' `
        -Arguments (@('-NoProfile', '-ExecutionPolicy', 'Bypass') + $Arguments) `
        -LogPath "results/logs/reference-seeds/$safeName-$hash.log" `
        -WorkingDirectory $repoRoot -TimeoutSeconds 300 -Quiet -CaptureOutput
    # Existing seed checks inspect exit_code; a process timeout has no native code.
    if ($result.status -ne 'passed' -and $null -eq $result.exit_code) { $result.exit_code = -1 }
    $result | Add-Member -NotePropertyName description -NotePropertyValue $Description
    return $result
}
