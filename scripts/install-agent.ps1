param(
    [switch]$Uninstall,
    [switch]$PurgeState,
    [switch]$ReEnroll,
    [string]$BinaryPath,
    [string]$CenterUrl = "https://remote-control-mcp-agent.example.invalid",
    [string]$EnrollmentToken = $env:REMOTE_CONTROL_MCP_AGENT_ENROLLMENT_TOKEN,
    [string]$AgentName = $env:COMPUTERNAME,
    [string]$HostId = "",
    [string]$DefaultCwd = "C:\",
    [string]$Capabilities = "command,durable_tasks,file_transfer",
    [string]$Version = "dev",
    [string]$BrowserAdapter = "",
    [string]$BrowserProfileDir = $env:REMOTE_CONTROL_MCP_AGENT_BROWSER_PROFILE_DIR,
    [ValidateSet("camoufox", "playwright", "patchright")]
    [string]$BrowserEngine = $(if ($env:REMOTE_CONTROL_MCP_AGENT_BROWSER_ENGINE) { $env:REMOTE_CONTROL_MCP_AGENT_BROWSER_ENGINE } else { "camoufox" }),
    [ValidateSet("chromium", "firefox", "webkit")]
    [string]$BrowserName = $(if ($env:REMOTE_CONTROL_MCP_AGENT_BROWSER) { $env:REMOTE_CONTROL_MCP_AGENT_BROWSER } else { "firefox" }),
    [ValidateSet("0", "1")]
    [string]$BrowserHeadless = $(if ($env:REMOTE_CONTROL_MCP_AGENT_BROWSER_HEADLESS) { $env:REMOTE_CONTROL_MCP_AGENT_BROWSER_HEADLESS } else { "1" }),
    [string]$PlaywrightBrowsersPath = $env:REMOTE_CONTROL_MCP_AGENT_PLAYWRIGHT_BROWSERS_PATH,
    [string]$CamoufoxInstallDir = $env:REMOTE_CONTROL_MCP_AGENT_CAMOUFOX_INSTALL_DIR,
    [string]$DesktopBinaryPath = "",
    [string]$BrowserBinaryPath = "",
    [string]$UpdaterBinaryPath = "",
    [switch]$DesktopEnabled,
    [ValidateRange(15, 600)]
    [int]$RegistrationTimeoutSeconds = 90,
    [ValidateRange(1, 32)]
    [int]$MaxConcurrency = 1,
    [ValidateRange(1, 8)]
    [int]$MaxBrowserWorkers = 1,
    [ValidateRange(1, 64)]
    [int]$DesktopMaxLaunchedProcesses = 16,
    [ValidateRange(1048576, 1073741824)]
    [long]$MaxOutputBytes = 67108864,
    [long]$MaxAggregateOutputBytes = 0,
    [ValidateRange(0, 2592000)]
    [long]$MaxTaskDurationSeconds = 0,
    [ValidateRange(1, 256)]
    [int]$MaxChildProcesses = 32,
    [ValidateRange(0, 4096)]
    [int]$MaxTotalChildProcesses = $(if ($env:REMOTE_CONTROL_MCP_AGENT_MAX_TOTAL_CHILD_PROCESSES) { [int]$env:REMOTE_CONTROL_MCP_AGENT_MAX_TOTAL_CHILD_PROCESSES } else { 0 }),
    [ValidateRange(0, 17179869184)]
    [long]$MaxRssBytes = 0,
    [ValidateRange(0, 2592000)]
    [long]$MaxCpuSeconds = 0,
    [ValidateRange(250, 10000)]
    [long]$ResourceSampleIntervalMs = 1000,
    [ValidateRange(5, 3600)]
    [long]$TransferStallTimeoutSeconds = $(if ($env:REMOTE_CONTROL_MCP_AGENT_TRANSFER_STALL_TIMEOUT_SECONDS) { [long]$env:REMOTE_CONTROL_MCP_AGENT_TRANSFER_STALL_TIMEOUT_SECONDS } else { 120 }),
    [string]$CgroupPath = $env:REMOTE_CONTROL_MCP_AGENT_CGROUP_PATH,
    [string]$InstallRoot = "$env:ProgramFiles\Remote Control MCP Agent",
    [string]$StateDir = "$env:ProgramData\RemoteControlMCPAgent"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$serviceName = "RemoteControlMCPAgent"
$companionTaskName = "RemoteControlMCPDesktopCompanion"

function ConvertTo-PowerShellLiteral {
    param([AllowEmptyString()][string]$Value)
    # Single-quoted PowerShell literals only need an embedded quote doubled.
    # This keeps paths/URLs/capability lists out of a command-line string and
    # prevents metacharacters in a custom installation path from becoming
    # executable code in the launcher.
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function ConvertTo-VBScriptLiteral {
    param([AllowEmptyString()][string]$Value)
    # WScript.Shell.Run receives one command-line string.  Escape embedded
    # double quotes for a VBScript string literal so paths with spaces remain
    # arguments and never become executable VBScript source.
    return '"' + ([string]$Value).Replace('"', '""') + '"'
}

function Remove-AgentScmService {
    param([Parameter(Mandatory = $true)][string]$Name)
    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) { return }
    if ($service.Status -ne "Stopped") {
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        try { $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(30)) } catch { }
    }
    & sc.exe delete $Name | Out-Null
    # Delete is asynchronous in SCM.  Do not create a task with the same
    # display/name until the stale service record has disappeared.
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Get-Service -Name $Name -ErrorAction SilentlyContinue)) { return }
        Start-Sleep -Milliseconds 250
    }
    throw "Windows SCM service '$Name' could not be removed."
}

function Remove-AgentTask {
    param([Parameter(Mandatory = $true)][string]$Name)
    $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if (-not $task) { return }
    if ($task.State -eq 'Running') { Stop-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue }
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $deadline) {
        $current = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
        if (-not $current -or $current.State -ne 'Running') { break }
        Start-Sleep -Milliseconds 250
    }
    Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
}

function Stop-AgentProcessForReplacement {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ExecutablePaths
    )
    $expected = @($ExecutablePaths | Where-Object { $_ } | ForEach-Object {
        try { [IO.Path]::GetFullPath($_) } catch { $null }
    } | Where-Object { $_ })
    if ($expected.Count -eq 0) { return }
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $processes = @()
        foreach ($name in @('rcm-agent.exe', 'rcm-desktop-companion.exe', 'rcm-browser-agent.exe', 'rcm-updater.exe')) {
            foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='$name'" -ErrorAction SilentlyContinue)) {
                if (-not $process.ExecutablePath) { continue }
                try {
                    $actual = [IO.Path]::GetFullPath([string]$process.ExecutablePath)
                    if ($expected | Where-Object { $_ -ieq $actual }) {
                        $processes += $process
                    }
                } catch { }
            }
        }
        if ($processes.Count -eq 0) { return }
        foreach ($process in $processes) {
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Agent process did not exit before bundle replacement."
}

function Resolve-AgentTaskHostPath {
    # Only installation needs PowerShell 7. The generated runtime launcher is
    # PowerShell 5.1 compatible: use the Windows-owned host, whose location is
    # stable across Store/MSIX updates and available to SYSTEM before logon.
    $hostPath = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $hostPath -PathType Leaf)) {
        throw "Windows PowerShell task host is missing: $hostPath. No versioned/user-scoped host will be registered."
    }
    return $hostPath
}

function Resolve-AgentInstallPaths([string]$InstallRoot, [string]$StateDir) {
    $resolved = @{}
    foreach ($entry in @(@{Name='InstallRoot';Value=$InstallRoot}, @{Name='StateDir';Value=$StateDir})) {
        if ($entry.Value -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+\\)') {
            throw "$($entry.Name) must be an absolute directory path."
        }
        $fullPath = [IO.Path]::GetFullPath($entry.Value)
        $path = $fullPath.TrimEnd('\','/')
        if ($path -ieq [IO.Path]::GetPathRoot($fullPath).TrimEnd('\','/')) {
            throw "$($entry.Name) cannot be a drive root or a protected system/profile directory."
        }
        $protected = @($env:SystemRoot, $env:ProgramFiles,
            ${env:ProgramFiles(x86)}, $env:ProgramData, [Environment]::GetFolderPath('UserProfile'))
        foreach ($directory in $protected) {
            if ($directory -and $path -ieq ([IO.Path]::GetFullPath($directory).TrimEnd('\','/'))) {
                throw "$($entry.Name) cannot be a drive root or a protected system/profile directory."
            }
        }
        $resolved[$entry.Name] = $path
    }
    $install = $resolved.InstallRoot
    $state = $resolved.StateDir
    if ($install -ieq $state -or $install.StartsWith($state + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $state.StartsWith($install + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'InstallRoot and StateDir must be separate, non-overlapping directories.'
    }
    return [pscustomobject]$resolved
}

function Register-AgentTask {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$LauncherPath
    )
    $taskHost = Resolve-AgentTaskHostPath
    $action = New-ScheduledTaskAction -Execute $taskHost -Argument (
        '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $LauncherPath)
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    # Task Scheduler rejects restart intervals below one minute (HRESULT
    # 0x80041318); use the platform minimum while retaining three retries.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $Name -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Description 'Remote Control MCP Java Agent (system startup task)' -Force | Out-Null
}

function Start-AgentTaskAndWait {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ExecutablePath,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 30
    )
    Start-ScheduledTask -TaskName $Name
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $stableSince = $null
    $stableProcessId = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
        $agent = @(Get-CimInstance Win32_Process -Filter "Name='rcm-agent.exe'" |
            Where-Object { $_.ExecutablePath -ieq $ExecutablePath })
        if ($task -and $task.State -eq 'Running' -and $agent.Count -gt 0) {
            if ($null -eq $stableSince -or $stableProcessId -ne $agent[0].ProcessId) {
                $stableSince = [DateTime]::UtcNow
                $stableProcessId = $agent[0].ProcessId
            }
            if (([DateTime]::UtcNow - $stableSince).TotalSeconds -ge 3) { return }
        } else { $stableSince = $null }
        Start-Sleep -Milliseconds 250
    }
    $info = Get-ScheduledTaskInfo -TaskName $Name -ErrorAction SilentlyContinue
    $result = if ($info) { $info.LastTaskResult } else { 'unknown' }
    throw "Remote Control MCP Agent process did not remain running (task: $Name; last result: $result; binary: $ExecutablePath)."
}

function Assert-NativeArchive {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Executable)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or [IO.Path]::GetExtension($Path) -ine '.zip') {
        throw "Expected a Native Image ZIP containing ${Executable}: $Path"
    }
    $archive = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
    try {
        $matches = @($archive.Entries | Where-Object { $_.Name -ieq $Executable })
        if ($matches.Count -ne 1 -or $matches[0].FullName -ine $Executable) {
            throw "Native Image ZIP must contain exactly one flat $Executable."
        }
    } finally { $archive.Dispose() }
}

if ($MaxTotalChildProcesses -eq 0) {
    $MaxTotalChildProcesses = [Math]::Min(256, [Math]::Max(32, $MaxConcurrency * 32))
}
if ($MaxTotalChildProcesses -lt 1 -or $MaxTotalChildProcesses -gt 4096) {
    throw "MaxTotalChildProcesses must be between 1 and 4096."
}

function Install-NativeCompanionBundle {
    param(
        [Parameter(Mandatory = $true)][string]$InputPath,
        [Parameter(Mandatory = $true)][string]$ExpectedExecutable,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory
    )

    $resolved = (Resolve-Path -LiteralPath $InputPath -ErrorAction Stop).Path
    $staging = $null
    try {
        if ([IO.Path]::GetExtension($resolved) -ieq '.zip') {
            $staging = Join-Path ([IO.Path]::GetTempPath()) ("rcm-companion-install-" + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $staging -Force | Out-Null
            Expand-Archive -LiteralPath $resolved -DestinationPath $staging -Force
            $candidates = @(Get-ChildItem -LiteralPath $staging -Filter $ExpectedExecutable -File -Recurse)
            if ($candidates.Count -ne 1) {
                throw "Companion ZIP must contain exactly one $ExpectedExecutable at a bundle root."
            }
            $source = $candidates[0]
            $sourceRoot = $source.Directory.FullName
            $sourceFiles = @($source) + @(Get-ChildItem -LiteralPath $sourceRoot -Filter '*.dll' -File -ErrorAction SilentlyContinue)
        } else {
            throw "Companion input must be a Native Image ZIP containing $ExpectedExecutable."
        }
        $sourceFiles = @($sourceFiles | Sort-Object Name -Unique)
        if (-not ($sourceFiles | Where-Object { $_.Name -ieq $ExpectedExecutable })) {
            throw "The selected companion bundle does not contain $ExpectedExecutable."
        }
        New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
        foreach ($old in @(Get-ChildItem -LiteralPath $DestinationDirectory -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -ieq '.exe' -or $_.Extension -ieq '.dll' })) {
            if (-not ($sourceFiles | Where-Object { $_.Name -ieq $old.Name })) {
                Remove-Item -LiteralPath $old.FullName -Force
            }
        }
        foreach ($file in $sourceFiles) {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $DestinationDirectory $file.Name) -Force
        }
        return (Join-Path $DestinationDirectory $ExpectedExecutable)
    } finally {
        if ($staging -and (Test-Path -LiteralPath $staging)) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script from an elevated PowerShell 7 window."
}
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7 or newer is required."
}
$targets = Resolve-AgentInstallPaths -InstallRoot $InstallRoot -StateDir $StateDir
$InstallRoot = $targets.InstallRoot
$StateDir = $targets.StateDir

if ($Uninstall) {
    Remove-AgentTask -Name $serviceName
    Remove-AgentTask -Name $companionTaskName
    Remove-AgentScmService -Name $serviceName
    if (Test-Path -LiteralPath $InstallRoot) { Remove-Item -LiteralPath $InstallRoot -Recurse -Force }
    if ($PurgeState -and (Test-Path -LiteralPath $StateDir)) { Remove-Item -LiteralPath $StateDir -Recurse -Force }
    Write-Host "Remote Control MCP Agent task removed."
    return
}

if ([string]::IsNullOrWhiteSpace($BinaryPath) -or -not (Test-Path -LiteralPath $BinaryPath -PathType Leaf)) {
    throw "BinaryPath must point to the current Windows Native Image Agent ZIP."
}
if ([string]::IsNullOrWhiteSpace($CenterUrl) -or $CenterUrl.Contains("`r") -or $CenterUrl.Contains("`n")) { throw "CenterUrl is required and must be one line." }
$parsedCenterUrl = [Uri]$CenterUrl
if (-not $parsedCenterUrl.IsAbsoluteUri -or $parsedCenterUrl.Scheme -ne 'https') { throw "CenterUrl must use HTTPS." }
if ([string]::IsNullOrWhiteSpace($AgentName)) { throw "AgentName is required." }
if ([string]::IsNullOrWhiteSpace($HostId)) { $HostId = $AgentName }
if ($CgroupPath -and ($CgroupPath.Contains("`r") -or $CgroupPath.Contains("`n") -or $CgroupPath.Length -gt 4096)) { throw "CgroupPath must be a single path up to 4096 characters." }
if (-not (Test-Path -LiteralPath $DefaultCwd -PathType Container)) { throw "DefaultCwd does not exist: $DefaultCwd" }
if ($MaxAggregateOutputBytes -eq 0) {
    $product = [decimal]$MaxOutputBytes * [decimal]$MaxConcurrency
    $MaxAggregateOutputBytes = [long][Math]::Max([decimal]$MaxOutputBytes, [Math]::Min([decimal]268435456, $product))
}
if ($MaxAggregateOutputBytes -lt $MaxOutputBytes -or $MaxAggregateOutputBytes -gt 4294967296) {
    throw "MaxAggregateOutputBytes must be between MaxOutputBytes and 4 GiB."
}
if ($MaxBrowserWorkers -gt $MaxConcurrency) {
        throw "MaxBrowserWorkers cannot exceed MaxConcurrency."
}

# Reject missing credentials, dependencies and malformed companion bundles
# before stopping any currently working Agent or replacing its executable.
[void](Resolve-AgentTaskHostPath)
$identity = Join-Path $StateDir 'identity.json'
if (($ReEnroll -or -not (Test-Path -LiteralPath $identity -PathType Leaf)) -and [string]::IsNullOrWhiteSpace($EnrollmentToken)) {
    throw 'EnrollmentToken is required for first registration or -ReEnroll; the existing Agent was not stopped.'
}
Assert-NativeArchive -Path $BinaryPath -Executable 'rcm-agent.exe'
foreach ($bundle in @(
    @{Path=$DesktopBinaryPath;Executable='rcm-desktop-companion.exe'},
    @{Path=$BrowserBinaryPath;Executable='rcm-browser-agent.exe'},
    @{Path=$UpdaterBinaryPath;Executable='rcm-updater.exe'}
)) {
    if (-not [string]::IsNullOrWhiteSpace($bundle.Path)) { Assert-NativeArchive -Path $bundle.Path -Executable $bundle.Executable }
}
if ($DesktopEnabled -and [string]::IsNullOrWhiteSpace($DesktopBinaryPath) -and
        -not (Test-Path -LiteralPath (Join-Path $InstallRoot 'desktop\rcm-desktop-companion.exe') -PathType Leaf)) {
    throw 'DesktopEnabled requires an installed companion or DesktopBinaryPath; the existing Agent was not stopped.'
}

$destination = Join-Path $InstallRoot "rcm-agent.exe"

# A Windows Native Image executable is not self-contained: the GraalVM runtime
# DLLs generated beside it (java.dll, jvm.dll, awt.dll, ...) must stay beside
# the executable. The installer accepts only the flat release ZIP produced by
# GitHub Actions so every runtime library is upgraded atomically as one bundle.
$inputPath = (Resolve-Path -LiteralPath $BinaryPath).Path
$staging = $null
$sourceFiles = @()
try {
    if ([IO.Path]::GetExtension($inputPath) -ieq '.zip') {
        $staging = Join-Path ([IO.Path]::GetTempPath()) ("rcm-agent-install-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        Expand-Archive -LiteralPath $inputPath -DestinationPath $staging -Force
        $candidates = @(Get-ChildItem -LiteralPath $staging -Filter 'rcm-agent.exe' -File -Recurse)
        if ($candidates.Count -ne 1) {
            throw "Agent ZIP must contain exactly one rcm-agent.exe at a bundle root."
        }
        $sourceRoot = $candidates[0].Directory.FullName
        $sourceFiles = @(Get-ChildItem -LiteralPath $sourceRoot -File |
            Where-Object { $_.Extension -ieq '.exe' -or $_.Extension -ieq '.dll' })
    } else {
        throw "BinaryPath must be a Native Image ZIP containing rcm-agent.exe."
    }
    if (-not ($sourceFiles | Where-Object { $_.Name -ieq 'rcm-agent.exe' })) {
        throw "The selected Agent bundle does not contain rcm-agent.exe."
    }
    $sourceFiles = @($sourceFiles | Sort-Object Name -Unique)

    # Stop before replacing a loaded executable/DLL. The startup task is
    # started again only after registration and the complete bundle are in place.
    $existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($existingService) { Remove-AgentScmService -Name $serviceName }
    # The interactive companion may still hold its Native Image DLLs while a
    # upgrade is replacing the sibling bundles. Stop/unregister the
    # old logon task; it is recreated below when DesktopEnabled is requested.
    Remove-AgentTask -Name $companionTaskName
    Remove-AgentTask -Name $serviceName
    Stop-AgentProcessForReplacement -ExecutablePaths @(
        (Join-Path $InstallRoot 'rcm-agent.exe'),
        (Join-Path $InstallRoot 'desktop\rcm-desktop-companion.exe'),
        (Join-Path $InstallRoot 'browser\rcm-browser-agent.exe')
    )

    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $StateDir 'desktop') -Force | Out-Null
    foreach ($oldDll in @(Get-ChildItem -LiteralPath $InstallRoot -Filter '*.dll' -File -ErrorAction SilentlyContinue)) {
        if (-not ($sourceFiles | Where-Object { $_.Name -ieq $oldDll.Name })) {
            Remove-Item -LiteralPath $oldDll.FullName -Force
        }
    }
    foreach ($file in $sourceFiles) {
        $destinationPath = Join-Path $InstallRoot $file.Name
        try {
            if ([IO.Path]::GetFullPath($file.FullName) -ieq [IO.Path]::GetFullPath($destinationPath)) {
                continue
            }
        } catch { }
        Copy-Item -LiteralPath $file.FullName -Destination $destinationPath -Force
    }
} finally {
    if ($staging -and (Test-Path -LiteralPath $staging)) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$desktopDestination = $null
$browserDestination = $null
if ($DesktopEnabled -or -not [string]::IsNullOrWhiteSpace($DesktopBinaryPath)) {
    if ([string]::IsNullOrWhiteSpace($DesktopBinaryPath)) {
        $existingDesktop = Join-Path $InstallRoot 'desktop\rcm-desktop-companion.exe'
        if (Test-Path -LiteralPath $existingDesktop -PathType Leaf) {
            $desktopDestination = $existingDesktop
        } else {
            throw 'DesktopEnabled requires DesktopBinaryPath pointing to the rcm-desktop-companion ZIP.'
        }
    } else {
        $desktopDestination = Install-NativeCompanionBundle -InputPath $DesktopBinaryPath -ExpectedExecutable 'rcm-desktop-companion.exe' -DestinationDirectory (Join-Path $InstallRoot 'desktop')
    }
}
if (-not [string]::IsNullOrWhiteSpace($BrowserBinaryPath)) {
    $browserDestination = Install-NativeCompanionBundle -InputPath $BrowserBinaryPath -ExpectedExecutable 'rcm-browser-agent.exe' -DestinationDirectory (Join-Path $InstallRoot 'browser')
}
$updaterDestination = $null
if (-not [string]::IsNullOrWhiteSpace($UpdaterBinaryPath)) {
    $updaterDestination = Install-NativeCompanionBundle -InputPath $UpdaterBinaryPath -ExpectedExecutable 'rcm-updater.exe' -DestinationDirectory (Join-Path $InstallRoot 'updater')
}

$identity = Join-Path $StateDir 'identity.json'
if ($ReEnroll -or -not (Test-Path -LiteralPath $identity -PathType Leaf)) {
    if ([string]::IsNullOrWhiteSpace($EnrollmentToken)) {
        throw "EnrollmentToken is required for first registration or -ReEnroll. It is not stored after registration."
    }
    $bootstrap = @{
        REMOTE_CONTROL_MCP_AGENT_CENTER_URL = $CenterUrl.TrimEnd('/')
        REMOTE_CONTROL_MCP_AGENT_ENROLLMENT_TOKEN = $EnrollmentToken.Trim()
        REMOTE_CONTROL_MCP_AGENT_NAME = $AgentName.Trim()
        REMOTE_CONTROL_MCP_AGENT_HOST_ID = $HostId.Trim()
        REMOTE_CONTROL_MCP_AGENT_DEFAULT_CWD = $DefaultCwd
        REMOTE_CONTROL_MCP_AGENT_CAPABILITIES = $Capabilities
        REMOTE_CONTROL_MCP_AGENT_VERSION = $Version.Trim()
        REMOTE_CONTROL_MCP_AGENT_BROWSER_ADAPTER = $BrowserAdapter.Trim()
        REMOTE_CONTROL_MCP_AGENT_BROWSER_PROFILE_DIR = [string]$BrowserProfileDir
        REMOTE_CONTROL_MCP_AGENT_BROWSER_ENGINE = $BrowserEngine
        REMOTE_CONTROL_MCP_AGENT_BROWSER = $BrowserName
        REMOTE_CONTROL_MCP_AGENT_BROWSER_HEADLESS = $BrowserHeadless
        REMOTE_CONTROL_MCP_AGENT_PLAYWRIGHT_BROWSERS_PATH = [string]$PlaywrightBrowsersPath
        REMOTE_CONTROL_MCP_AGENT_CAMOUFOX_INSTALL_DIR = [string]$CamoufoxInstallDir
        REMOTE_CONTROL_MCP_AGENT_DESKTOP_ENABLED = $DesktopEnabled.IsPresent.ToString().ToLowerInvariant()
        REMOTE_CONTROL_MCP_AGENT_STATE_DIR = $StateDir
        REMOTE_CONTROL_MCP_AGENT_MAX_CONCURRENCY = $MaxConcurrency.ToString()
        REMOTE_CONTROL_MCP_AGENT_MAX_BROWSER_WORKERS = $MaxBrowserWorkers.ToString()
        REMOTE_CONTROL_MCP_AGENT_DESKTOP_MAX_LAUNCHED_PROCESSES = $DesktopMaxLaunchedProcesses.ToString()
        REMOTE_CONTROL_MCP_AGENT_MAX_OUTPUT_BYTES = $MaxOutputBytes.ToString()
        REMOTE_CONTROL_MCP_AGENT_MAX_AGGREGATE_OUTPUT_BYTES = $MaxAggregateOutputBytes.ToString()
        REMOTE_CONTROL_MCP_AGENT_MAX_TASK_DURATION_SECONDS = $MaxTaskDurationSeconds.ToString()
        REMOTE_CONTROL_MCP_AGENT_MAX_CHILD_PROCESSES = $MaxChildProcesses.ToString()
        REMOTE_CONTROL_MCP_AGENT_MAX_TOTAL_CHILD_PROCESSES = $MaxTotalChildProcesses.ToString()
        REMOTE_CONTROL_MCP_AGENT_MAX_RSS_BYTES = $MaxRssBytes.ToString()
        REMOTE_CONTROL_MCP_AGENT_MAX_CPU_SECONDS = $MaxCpuSeconds.ToString()
        REMOTE_CONTROL_MCP_AGENT_RESOURCE_SAMPLE_INTERVAL_MS = $ResourceSampleIntervalMs.ToString()
        REMOTE_CONTROL_MCP_AGENT_TRANSFER_STALL_TIMEOUT_SECONDS = $TransferStallTimeoutSeconds.ToString()
        REMOTE_CONTROL_MCP_AGENT_CGROUP_PATH = [string]$CgroupPath
    }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $destination
    $psi.ArgumentList.Add('--register-once')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($entry in $bootstrap.GetEnumerator()) { $psi.Environment[$entry.Key] = [string]$entry.Value }
    $registration = [System.Diagnostics.Process]::new()
    $registration.StartInfo = $psi
    if (-not $registration.Start()) { throw "could not start Java Agent registration" }
    $stdout = $registration.StandardOutput.ReadToEndAsync()
    $stderr = $registration.StandardError.ReadToEndAsync()
    try {
        if (-not $registration.WaitForExit($RegistrationTimeoutSeconds * 1000)) {
            try { $registration.Kill($true) } catch { }
            [void]$registration.WaitForExit(5000)
            throw "Agent registration timed out after $RegistrationTimeoutSeconds seconds; check Center reachability and the enrollment credential."
        }
        if ($registration.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $identity -PathType Leaf)) {
            $detail = if ($stderr.Result) { $stderr.Result.Trim() } else { $stdout.Result.Trim() }
            throw "Java Agent registration failed (exit $($registration.ExitCode)): $detail"
        }
    } finally { $registration.Dispose() }
}

$environment = [string[]]@(
    "REMOTE_CONTROL_MCP_AGENT_CENTER_URL=$($CenterUrl.TrimEnd('/'))",
    "REMOTE_CONTROL_MCP_AGENT_NAME=$($AgentName.Trim())",
    "REMOTE_CONTROL_MCP_AGENT_HOST_ID=$($HostId.Trim())",
    "REMOTE_CONTROL_MCP_AGENT_DEFAULT_CWD=$DefaultCwd",
    "REMOTE_CONTROL_MCP_AGENT_CAPABILITIES=$Capabilities",
    "REMOTE_CONTROL_MCP_AGENT_VERSION=$($Version.Trim())",
    "REMOTE_CONTROL_MCP_AGENT_BROWSER_ADAPTER=$($BrowserAdapter.Trim())",
    "REMOTE_CONTROL_MCP_AGENT_BROWSER_PROFILE_DIR=$BrowserProfileDir",
    "REMOTE_CONTROL_MCP_AGENT_BROWSER_ENGINE=$BrowserEngine",
    "REMOTE_CONTROL_MCP_AGENT_BROWSER=$BrowserName",
    "REMOTE_CONTROL_MCP_AGENT_BROWSER_HEADLESS=$BrowserHeadless",
    "REMOTE_CONTROL_MCP_AGENT_PLAYWRIGHT_BROWSERS_PATH=$PlaywrightBrowsersPath",
    "REMOTE_CONTROL_MCP_AGENT_CAMOUFOX_INSTALL_DIR=$CamoufoxInstallDir",
    "REMOTE_CONTROL_MCP_AGENT_DESKTOP_ENABLED=$($DesktopEnabled.IsPresent.ToString().ToLowerInvariant())",
    "REMOTE_CONTROL_MCP_AGENT_STATE_DIR=$StateDir",
    "REMOTE_CONTROL_MCP_AGENT_MAX_CONCURRENCY=$MaxConcurrency",
    "REMOTE_CONTROL_MCP_AGENT_MAX_BROWSER_WORKERS=$MaxBrowserWorkers",
    "REMOTE_CONTROL_MCP_AGENT_DESKTOP_MAX_LAUNCHED_PROCESSES=$DesktopMaxLaunchedProcesses",
    "REMOTE_CONTROL_MCP_AGENT_MAX_OUTPUT_BYTES=$MaxOutputBytes",
    "REMOTE_CONTROL_MCP_AGENT_MAX_AGGREGATE_OUTPUT_BYTES=$MaxAggregateOutputBytes",
    "REMOTE_CONTROL_MCP_AGENT_MAX_TASK_DURATION_SECONDS=$MaxTaskDurationSeconds",
    "REMOTE_CONTROL_MCP_AGENT_MAX_CHILD_PROCESSES=$MaxChildProcesses",
    "REMOTE_CONTROL_MCP_AGENT_MAX_TOTAL_CHILD_PROCESSES=$MaxTotalChildProcesses",
    "REMOTE_CONTROL_MCP_AGENT_MAX_RSS_BYTES=$MaxRssBytes",
    "REMOTE_CONTROL_MCP_AGENT_MAX_CPU_SECONDS=$MaxCpuSeconds",
    "REMOTE_CONTROL_MCP_AGENT_RESOURCE_SAMPLE_INTERVAL_MS=$ResourceSampleIntervalMs",
    "REMOTE_CONTROL_MCP_AGENT_TRANSFER_STALL_TIMEOUT_SECONDS=$TransferStallTimeoutSeconds",
    "REMOTE_CONTROL_MCP_AGENT_CGROUP_PATH=$CgroupPath",
    "REMOTE_CONTROL_MCP_AGENT_BINARY_PATH=$destination",
    "REMOTE_CONTROL_MCP_AGENT_SERVICE_NAME=$serviceName"
)
if ($desktopDestination) {
    $environment += "REMOTE_CONTROL_MCP_DESKTOP_BINARY_PATH=$desktopDestination"
    $environment += "REMOTE_CONTROL_MCP_DESKTOP_SERVICE_NAME=$companionTaskName"
}
if ($browserDestination) {
    $environment += "REMOTE_CONTROL_MCP_AGENT_BROWSER_BINARY=$browserDestination"
    $environment += "REMOTE_CONTROL_MCP_BROWSER_BINARY_PATH=$browserDestination"
}
if ($updaterDestination) {
    $environment += "REMOTE_CONTROL_MCP_AGENT_UPDATER_BINARY_PATH=$updaterDestination"
}
if (-not [string]::IsNullOrWhiteSpace($PlaywrightBrowsersPath)) {
    $environment += "PLAYWRIGHT_BROWSERS_PATH=$PlaywrightBrowsersPath"
}
if (-not [string]::IsNullOrWhiteSpace($CamoufoxInstallDir)) {
    $environment += "CAMOUFOX_INSTALL_DIR=$CamoufoxInstallDir"
}
$launcherPath = Join-Path $InstallRoot 'run-agent.ps1'
$launcherLines = [System.Collections.Generic.List[string]]::new()
$launcherLines.Add('$ErrorActionPreference = "Stop"')
$launcherLines.Add('$ProgressPreference = "SilentlyContinue"')
foreach ($entry in $environment) {
    $parts = $entry.Split('=', 2)
    if ($parts.Count -eq 2) {
        $launcherLines.Add("[Environment]::SetEnvironmentVariable($(ConvertTo-PowerShellLiteral $parts[0]), $(ConvertTo-PowerShellLiteral $parts[1]), 'Process')")
    }
}
$launcherLines.Add('$binary = Join-Path $PSScriptRoot ''rcm-agent.exe''')
$launcherLines.Add('& $binary --run')
$launcherLines.Add('exit $LASTEXITCODE')
# Keep this launcher compatible with Windows PowerShell 5.1. Startup must not
# depend on an MSIX version, a user profile, PATH, or the installing terminal.
# Write UTF-16LE so paths and machine names remain lossless on both PS editions.
Set-Content -LiteralPath $launcherPath -Value $launcherLines -Encoding Unicode -Force
& icacls.exe $launcherPath /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
# Keep the advertised version in sync with a direct reinstall as well as with
# the detached self-upgrade helper; stale markers otherwise mask new bundles.
$versionMarker = Join-Path $StateDir 'agent-version'
Set-Content -LiteralPath $versionMarker -Value $Version.Trim() -Encoding ASCII -Force
& icacls.exe $versionMarker /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
& icacls.exe $StateDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($DesktopEnabled) {
    # The startup task remains the single Center identity. A per-logon task
    # hosts the independent companion binary in the interactive session so
    # AWT/User32 can see the desktop; it communicates through the protected
    # state/desktop loopback endpoint and never registers another Agent.
    $desktopDir = Join-Path $StateDir 'desktop'
    # The apply helper runs as SYSTEM and sets USERNAME to the interactive
    # account.  Resolve that account to a SID so a bare name cannot silently
    # produce an unusable ACL on localized/domain Windows installations.  The
    # user gets traverse-only access to the state root and modify access only
    # to the desktop IPC directory; the Agent identity/token files remain
    # inaccessible.
    $desktopSid = $null
    try {
        $account = [Security.Principal.NTAccount]::new($env:COMPUTERNAME, $env:USERNAME)
        $desktopSid = $account.Translate([Security.Principal.SecurityIdentifier]).Value
    } catch { }
    if ($desktopSid) {
        & icacls.exe $StateDir /grant:r "*${desktopSid}:(X)" | Out-Null
        & icacls.exe $desktopDir /grant:r "*${desktopSid}:(OI)(CI)M" | Out-Null
    } else {
        & icacls.exe $StateDir /grant:r "$($env:COMPUTERNAME)\$($env:USERNAME):(X)" | Out-Null
        & icacls.exe $desktopDir /grant:r "$($env:COMPUTERNAME)\$($env:USERNAME):(OI)(CI)M" | Out-Null
    }
    # Scheduled tasks do not inherit the SCM service's registry Environment
    # block. Embed the resolved state directory in the launcher so a custom
    # ProgramData path still points at the same protected IPC endpoint.
    if (-not $desktopDestination) { throw 'Desktop companion binary is not installed.' }
    # A console-subsystem Native Image started directly by an interactive
    # scheduled task opens a visible black window.  Keep the companion in the
    # user's desktop session but launch it through wscript.exe //B instead of
    # a PowerShell wrapper.  This avoids the short-lived console flash that can
    # still occur with -WindowStyle Hidden on some Windows builds.
    $desktopLauncherPath = Join-Path $InstallRoot 'run-desktop-companion.ps1'
    $desktopLauncherLines = [System.Collections.Generic.List[string]]::new()
    $desktopLauncherLines.Add('$ErrorActionPreference = "Stop"')
    $desktopLauncherLines.Add('$psi = [System.Diagnostics.ProcessStartInfo]::new()')
    $desktopLauncherLines.Add(('$psi.FileName = {0}' -f (ConvertTo-PowerShellLiteral $desktopDestination)))
    $desktopLauncherLines.Add(('$psi.Arguments = {0}' -f (ConvertTo-PowerShellLiteral ('--desktop-companion "{0}"' -f $StateDir))))
    $desktopLauncherLines.Add('$psi.UseShellExecute = $false')
    $desktopLauncherLines.Add('$psi.CreateNoWindow = $true')
    $desktopLauncherLines.Add('$psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden')
    $desktopLauncherLines.Add('$process = [System.Diagnostics.Process]::Start($psi)')
    $desktopLauncherLines.Add('if ($null -eq $process) { throw "could not start desktop companion" }')
    $desktopLauncherLines.Add('$process.WaitForExit()')
    $desktopLauncherLines.Add('exit $process.ExitCode')
    # UTF-16LE preserves non-ASCII install paths and machine names in the
    # generated diagnostic wrapper.
    Set-Content -LiteralPath $desktopLauncherPath -Value $desktopLauncherLines -Encoding Unicode -Force
    & icacls.exe $desktopLauncherPath /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
    if ($desktopSid) {
        & icacls.exe $desktopLauncherPath /grant:r "*${desktopSid}:RX" | Out-Null
    } else {
        & icacls.exe $desktopLauncherPath /grant:r "$($env:COMPUTERNAME)\$($env:USERNAME):RX" | Out-Null
    }
    $desktopVbsPath = Join-Path $InstallRoot 'run-desktop-companion.vbs'
    $desktopVbsCommand = '"{0}" --desktop-companion "{1}"' -f $desktopDestination, $StateDir
    $desktopVbsLines = [System.Collections.Generic.List[string]]::new()
    $desktopVbsLines.Add('Option Explicit')
    $desktopVbsLines.Add('Dim shell')
    $desktopVbsLines.Add('Set shell = CreateObject("WScript.Shell")')
    $desktopVbsLines.Add(('shell.Run {0}, 0, True' -f (ConvertTo-VBScriptLiteral $desktopVbsCommand)))
    $desktopVbsLines.Add('WScript.Quit 0')
    # ANSI is sufficient for the generated wrapper because the command string
    # is escaped as a VBScript literal; UTF-16LE is accepted by wscript.exe and
    # preserves non-ASCII install/state paths.
    Set-Content -LiteralPath $desktopVbsPath -Value $desktopVbsLines -Encoding Unicode -Force
    & icacls.exe $desktopVbsPath /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
    if ($desktopSid) {
        & icacls.exe $desktopVbsPath /grant:r "*${desktopSid}:RX" | Out-Null
    } else {
        & icacls.exe $desktopVbsPath /grant:r "$($env:COMPUTERNAME)\$($env:USERNAME):RX" | Out-Null
    }
    $hiddenWScript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $launcherArguments = '//B //NoLogo "{0}"' -f $desktopVbsPath
    $action = New-ScheduledTaskAction -Execute $hiddenWScript -Argument $launcherArguments
    $desktopUserId = if ($env:USERNAME -like '*\*') { $env:USERNAME } else { "$($env:COMPUTERNAME)\$($env:USERNAME)" }
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $desktopUserId
    # Interactive is the supported scheduled-task logon type for the user
    # session that owns the desktop companion.
    $principal = New-ScheduledTaskPrincipal -UserId $desktopUserId -LogonType Interactive -RunLevel Limited
    $desktopSettings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $companionTaskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $desktopSettings -Description "Interactive desktop companion for Remote Control MCP" -Force | Out-Null
} else {
    Unregister-ScheduledTask -TaskName $companionTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

Register-AgentTask -Name $serviceName -LauncherPath $launcherPath
Start-AgentTaskAndWait -Name $serviceName -ExecutablePath $destination
[pscustomobject]@{
    Task = $serviceName
    Status = (Get-ScheduledTask -TaskName $serviceName).State
    AgentName = $AgentName
    EnrollmentTokenStoredInService = $false
    Binary = $destination
    StateDir = $StateDir
    MaxConcurrency = $MaxConcurrency
    MaxBrowserWorkers = $MaxBrowserWorkers
    DesktopMaxLaunchedProcesses = $DesktopMaxLaunchedProcesses
    DesktopBinary = $desktopDestination
    BrowserBinary = $browserDestination
    MaxAggregateOutputBytes = $MaxAggregateOutputBytes
    CgroupPath = $CgroupPath
    Launcher = $launcherPath
}
