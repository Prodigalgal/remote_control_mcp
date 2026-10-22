# Runs on Windows PowerShell 5.1 as well as PowerShell 7. All external
# commands are mocked; no installed Agent or scheduled task is modified.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
$root = Split-Path -Parent $PSScriptRoot
$script:passed = 0

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    $caught = $null
    try { & $Action } catch { $caught = $_ }
    Assert-True ($null -ne $caught) "Expected an error matching: $Pattern"
    Assert-True ($caught.Exception.Message -match $Pattern) "Unexpected error: $($caught.Exception.Message)"
}
function Test-Case([string]$Name, [scriptblock]$Action) {
    & $Action
    $script:passed++
    Write-Output "PASS: $Name"
}
function Get-FunctionDefinition([string]$Script, [string]$Name) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Script, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    if (-not $node) { throw "Function $Name not found in $Script" }
    return [scriptblock]::Create($node.Extent.Text)
}

function Remove-TestDirectory([string]$Path) {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + '\'
    $target = [IO.Path]::GetFullPath($Path)
    if (-not $target.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($target) -notmatch '^rcm-(archive|download)-test-[0-9a-f]{32}$') {
        throw "Refusing to remove a directory outside the generated test workspace: $target"
    }
    Remove-Item -LiteralPath $target -Recurse -Force
}

Test-Case 'Every PowerShell script parses under the task host' {
    foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File) {
        $tokens = $null; $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        Assert-True ($errors.Count -eq 0) "Parse error in $($file.Name): $($errors | Out-String)"
    }
}

& {
    $installer = Join-Path $PSScriptRoot 'install-agent.ps1'
    foreach ($name in @('Resolve-AgentTaskHostPath','Resolve-AgentInstallPaths','Register-AgentTask','Start-AgentTaskAndWait','Assert-NativeArchive')) {
        . (Get-FunctionDefinition $installer $name)
    }
    Test-Case 'Installer rejects dangerous roots, relative paths and overlapping state' {
        $base = [IO.Path]::GetTempPath()
        $install = Join-Path $base 'rcm-path-test-install'
        $state = Join-Path $base 'rcm-path-test-state'
        Assert-Throws { Resolve-AgentInstallPaths ([IO.Path]::GetPathRoot($base)) $state } 'drive root|protected'
        Assert-Throws { Resolve-AgentInstallPaths $env:ProgramFiles $state } 'protected'
        Assert-Throws { Resolve-AgentInstallPaths 'relative-agent' $state } 'absolute'
        Assert-Throws { Resolve-AgentInstallPaths $install (Join-Path $install 'state') } 'non-overlapping'
        $paths = Resolve-AgentInstallPaths $install $state
        Assert-True ($paths.InstallRoot -eq $install.TrimEnd('\')) 'Install path was not normalized correctly'
    }
    Test-Case 'Store version deletion cannot change the startup action' {
        $oldOverride = $env:REMOTE_CONTROL_MCP_PWSH_PATH
        try {
            $env:REMOTE_CONTROL_MCP_PWSH_PATH = 'C:\Program Files\WindowsApps\Microsoft.PowerShell_deleted\pwsh.exe'
            function New-ScheduledTaskAction { param($Execute,$Argument) [pscustomobject]@{Execute=$Execute;Arguments=$Argument} }
            function New-ScheduledTaskTrigger { param([switch]$AtStartup) @{boot=$AtStartup.IsPresent} }
            function New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel) @{user=$UserId} }
            function New-ScheduledTaskSettingsSet { param([switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,[switch]$StartWhenAvailable,$RestartCount,$RestartInterval,$ExecutionTimeLimit) @{retry=$RestartCount;limit=$ExecutionTimeLimit} }
            function Register-ScheduledTask { param($TaskName,$Action,$Trigger,$Principal,$Settings,$Description,[switch]$Force) $script:registeredAction=$Action; $script:registeredPrincipal=$Principal; $script:registeredSettings=$Settings }
            Register-AgentTask -Name 'test-only' -LauncherPath 'C:\test path\run-agent.ps1'
            Assert-True ($script:registeredAction.Execute -ieq (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')) 'Task depends on a user/Store runtime'
            Assert-True ($script:registeredPrincipal.user -eq 'SYSTEM') 'Lost SYSTEM startup account'
            Assert-True ($script:registeredSettings.retry -eq 3 -and $script:registeredSettings.limit -eq [TimeSpan]::Zero) 'Lost recovery/no-time-limit settings'
        } finally { $env:REMOTE_CONTROL_MCP_PWSH_PATH = $oldOverride }
    }
    Test-Case 'A Running task without its Agent process is rejected' {
        function Start-ScheduledTask { param($TaskName) }
        function Get-ScheduledTask { param($TaskName,$ErrorAction) [pscustomobject]@{State='Running'} }
        function Get-ScheduledTaskInfo { param($TaskName,$ErrorAction) [pscustomobject]@{LastTaskResult=267009} }
        function Get-CimInstance { param($ClassName,$Filter) [pscustomobject]@{ExecutablePath='C:\other-agent\rcm-agent.exe';ProcessId=1} }
        Assert-Throws { Start-AgentTaskAndWait -Name 'test-only' -ExecutablePath 'C:\expected\rcm-agent.exe' -TimeoutSeconds 1 } 'process did not remain running'
    }
    Test-Case 'A stable matching Agent process passes startup verification' {
        function Start-ScheduledTask { param($TaskName) }
        function Get-ScheduledTask { param($TaskName,$ErrorAction) [pscustomobject]@{State='Running'} }
        function Get-CimInstance { param($ClassName,$Filter) [pscustomobject]@{ExecutablePath='C:\expected\rcm-agent.exe';ProcessId=17} }
        Start-AgentTaskAndWait -Name 'test-only' -ExecutablePath 'C:\expected\rcm-agent.exe' -TimeoutSeconds 5
    }
    Test-Case 'Malformed and nested bundles are rejected before installation' {
        $temp = Join-Path ([IO.Path]::GetTempPath()) ('rcm-archive-test-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temp | Out-Null
        try {
            foreach ($entry in @('rcm-agent.exe','nested/rcm-agent.exe','wrong.exe')) {
                $zip = Join-Path $temp ([Guid]::NewGuid().ToString('N') + '.zip')
                $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
                [void]$archive.CreateEntry($entry); $archive.Dispose()
                if ($entry -eq 'rcm-agent.exe') { Assert-NativeArchive -Path $zip -Executable 'rcm-agent.exe' }
                else { Assert-Throws { Assert-NativeArchive -Path $zip -Executable 'rcm-agent.exe' } 'exactly one flat' }
            }
        } finally { Remove-TestDirectory $temp }
    }
}

foreach ($scriptName in @('first-install-agent.ps1','deploy-desktop-browser.ps1')) {
    & {
        param($scriptName)
        . (Get-FunctionDefinition (Join-Path $PSScriptRoot $scriptName) 'Save-Download')
        $temp = Join-Path ([IO.Path]::GetTempPath()) ('rcm-download-test-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temp | Out-Null
        try {
            Test-Case "$scriptName retries temporary failures and publishes complete files" {
                $script:downloadAttempts = 0
                function Start-Sleep { param($Seconds) }
                function Invoke-WebRequest {
                    param([switch]$UseBasicParsing,$Uri,$OutFile,$TimeoutSec,$ErrorAction)
                    $script:downloadAttempts++
                    if ($script:downloadAttempts -lt 3) { Set-Content -LiteralPath $OutFile -Value 'partial'; throw [Net.WebException]::new('temporary disconnect') }
                    Set-Content -LiteralPath $OutFile -Value 'complete'
                }
                $destination = Join-Path $temp 'asset.zip'
                Save-Download -Uri 'https://example.invalid/asset.zip' -Destination $destination
                Assert-True ($script:downloadAttempts -eq 3) 'Temporary download was not retried within the budget'
                Assert-True ((Get-Content -LiteralPath $destination -Raw).Trim() -eq 'complete') 'Partial download was published'
                Assert-True (@(Get-ChildItem -LiteralPath $temp -Filter '*.download').Count -eq 0) 'Temporary files leaked'
            }
            Test-Case "$scriptName preserves the previous file after exhausted retries" {
                $script:downloadAttempts = 0
                function Start-Sleep { param($Seconds) }
                function Invoke-WebRequest {
                    param([switch]$UseBasicParsing,$Uri,$OutFile,$TimeoutSec,$ErrorAction)
                    $script:downloadAttempts++
                    Set-Content -LiteralPath $OutFile -Value 'partial'
                    throw [Net.WebException]::new('temporary disconnect')
                }
                $destination = Join-Path $temp 'existing.zip'; Set-Content -LiteralPath $destination -Value 'previous'
                Assert-Throws { Save-Download -Uri 'https://example.invalid/asset.zip' -Destination $destination } 'temporary disconnect'
                Assert-True ($script:downloadAttempts -eq 3) 'Download retry budget was not bounded'
                Assert-True ((Get-Content -LiteralPath $destination -Raw).Trim() -eq 'previous') 'Previous file was damaged'
                Assert-True (@(Get-ChildItem -LiteralPath $temp -Filter '*.download').Count -eq 0) 'Temporary files leaked on failure'
            }
            Test-Case "$scriptName rejects a permanent HTTP failure immediately" {
                $script:downloadAttempts = 0
                function Invoke-WebRequest {
                    param([switch]$UseBasicParsing,$Uri,$OutFile,$TimeoutSec,$ErrorAction)
                    $script:downloadAttempts++
                    $failure = [Exception]::new('HTTP 404')
                    $failure | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{StatusCode=404})
                    throw $failure
                }
                Assert-Throws { Save-Download -Uri 'https://example.invalid/missing' -Destination (Join-Path $temp 'missing.zip') } 'HTTP 404'
                Assert-True ($script:downloadAttempts -eq 1) 'Permanent failure was retried'
            }
            Test-Case "$scriptName does not retry local permission failures" {
                $script:downloadAttempts = 0
                function Invoke-WebRequest {
                    param([switch]$UseBasicParsing,$Uri,$OutFile,$TimeoutSec,$ErrorAction)
                    $script:downloadAttempts++
                    throw [UnauthorizedAccessException]::new('destination denied')
                }
                Assert-Throws { Save-Download -Uri 'https://example.invalid/asset.zip' -Destination (Join-Path $temp 'denied.zip') } 'destination denied'
                Assert-True ($script:downloadAttempts -eq 1) 'Local permission failure was treated as a network failure'
            }
        } finally { Remove-TestDirectory $temp }
    } $scriptName
}
& {
    foreach ($name in @('New-WakeMagicPacket','Get-WakeBroadcast')) {
        . (Get-FunctionDefinition (Join-Path $PSScriptRoot 'wake-machine.ps1') $name)
    }
    Test-Case 'Wake packet contains the exact target MAC sixteen times' {
        $packet = New-WakeMagicPacket '02-11-22-33-44-55'
        Assert-True ($packet.Length -eq 102) 'Invalid magic packet length'
        Assert-True (([BitConverter]::ToString($packet[0..5])) -eq 'FF-FF-FF-FF-FF-FF') 'Invalid magic packet header'
        for ($i = 0; $i -lt 16; $i++) {
            Assert-True (([BitConverter]::ToString($packet[(6 + 6 * $i)..(11 + 6 * $i)])) -eq '02-11-22-33-44-55') 'Wake packet targets the wrong device'
        }
        Assert-Throws { New-WakeMagicPacket 'invalid-address' } 'six hexadecimal bytes'
    }
    Test-Case 'Wake broadcast follows the selected IPv4 subnet' {
        Assert-True ((Get-WakeBroadcast '192.0.2.220' 24) -eq '192.0.2.255') 'Incorrect /24 broadcast'
        Assert-True ((Get-WakeBroadcast '198.51.100.4' 20) -eq '198.51.111.255') 'Incorrect /20 broadcast'
        Assert-Throws { Get-WakeBroadcast '::1' 24 } 'IPv4 LAN interface'
    }
}
Write-Output "Windows script contracts: $script:passed passed."
