[CmdletBinding()]
param(
    [string]$InstallRoot = "$env:ProgramFiles\Remote Control MCP Agent",
    [string]$StateDir = "$env:ProgramData\RemoteControlMCPAgent",
    [string]$TaskName = 'RemoteControlMCPAgent',
    [ValidateRange(5, 120)][int]$StartTimeoutSeconds = 30,
    [string]$ReportPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$report = [ordered]@{ status='failed'; time=(Get-Date -Format o); task=$TaskName }
try {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run repair-agent-task.ps1 from an elevated Windows PowerShell or PowerShell 7 terminal.'
    }
    $hostPath = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $launcher = Join-Path $InstallRoot 'run-agent.ps1'
    $binary = Join-Path $InstallRoot 'rcm-agent.exe'
    foreach ($required in @($hostPath, $launcher, $binary)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required file is missing: $required" }
    }
    if (-not (Test-Path -LiteralPath $StateDir -PathType Container)) { throw "Agent state directory is missing: $StateDir" }
    $task = Get-ScheduledTask -TaskName $TaskName
    if ($task.Principal.UserId -notin @('SYSTEM', 'S-1-5-18', 'NT AUTHORITY\SYSTEM')) {
        throw 'Expected an existing SYSTEM Agent task; refusing to change a different account.'
    }
    $info = $task | Get-ScheduledTaskInfo
    $report.before = [ordered]@{ state=[string]$task.State; last_run=$info.LastRunTime; last_result=$info.LastTaskResult; actions=@($task.Actions | Select-Object Execute,Arguments) }
    $report.old_host_exists = @($task.Actions | ForEach-Object { Test-Path -LiteralPath $_.Execute -PathType Leaf })
    $backupDir = Join-Path $StateDir 'task-backups'
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    $backup = Join-Path $backupDir ($TaskName + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.xml')
    Export-ScheduledTask -TaskName $TaskName -TaskPath $task.TaskPath | Set-Content -LiteralPath $backup -Encoding Unicode
    $report.backup = $backup
    $action = New-ScheduledTaskAction -Execute $hostPath -Argument (
        '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $launcher)
    # Preserve the boot trigger, SYSTEM principal, retry and battery settings.
    Set-ScheduledTask -TaskName $TaskName -TaskPath $task.TaskPath -Action $action | Out-Null
    if ($task.State -eq 'Disabled') { Enable-ScheduledTask -TaskName $TaskName -TaskPath $task.TaskPath | Out-Null }
    Start-ScheduledTask -TaskName $TaskName -TaskPath $task.TaskPath
    $deadline = [DateTime]::UtcNow.AddSeconds($StartTimeoutSeconds)
    $agent = $null
    do {
        $agent = Get-CimInstance Win32_Process -Filter "Name='rcm-agent.exe'" | Where-Object { $_.ExecutablePath -ieq $binary } | Select-Object -First 1
        if ($agent) { break }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $agent) {
        $result = (Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $task.TaskPath).LastTaskResult
        throw "The stable task host was installed, but Agent did not start (last result: $result). Identity and configuration were preserved."
    }
    Start-Sleep -Seconds 3
    $agent = Get-CimInstance Win32_Process -Filter "ProcessId=$($agent.ProcessId)" | Select-Object Name,ProcessId,ExecutablePath,CreationDate
    if (-not $agent) { throw 'Agent exited during startup verification; inspect its configuration and task result.' }
    $after = Get-ScheduledTask -TaskName $TaskName -TaskPath $task.TaskPath
    $report.after = [ordered]@{ state=[string]$after.State; last_result=(Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $task.TaskPath).LastTaskResult; actions=@($after.Actions | Select-Object Execute,Arguments); process=$agent }
    $report.status = 'started'
    $report.verification = 'Local Agent process started; verify Center heartbeat and a real command separately.'
} catch {
    $report.error = $_.Exception.Message
} finally {
    $json = $report | ConvertTo-Json -Depth 6
    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) { $json | Set-Content -LiteralPath $ReportPath -Encoding UTF8 }
    Write-Output $json
}
if ($report.status -ne 'started') { exit 1 }
