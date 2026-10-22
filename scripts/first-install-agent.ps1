[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CenterUrl,
    [Parameter(Mandatory = $true)][string]$EnrollmentToken,
    [Parameter(Mandatory = $true)][ValidatePattern("^[A-Za-z_][A-Za-z0-9_.-]{0,63}$")][string]$AgentName,
    [string]$HostId = "",
    [Parameter(Mandatory = $true)][ValidatePattern("^v[0-9A-Za-z][0-9A-Za-z.-]*$")][string]$Version,
    [ValidatePattern("^[A-Za-z0-9_.-]{1,128}$")][string]$ReleaseTag = "",
    [ValidateSet("command", "full")][string]$Mode = "command",
    [switch]$Desktop,
    [switch]$Browser,
    [ValidatePattern("^[A-Za-z_][A-Za-z0-9_.-]{0,63}$")][string]$DesktopUser = "",
    [ValidateSet("0", "1")][string]$BrowserHeadless = "1",
    [string]$NodePath = "",
    [string]$InstallRoot = "$env:ProgramFiles\Remote Control MCP Agent",
    [string]$StateDir = "$env:ProgramData\RemoteControlMCPAgent",
    [switch]$ReEnroll,
    [switch]$InternalChild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Resolve-PowerShell7Path {
    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($env:REMOTE_CONTROL_MCP_PWSH_PATH)) {
        [void]$candidates.Add($env:REMOTE_CONTROL_MCP_PWSH_PATH)
    }
    [void]$candidates.Add((Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'))
    foreach ($package in @(Get-AppxPackage -Name Microsoft.PowerShell -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1)) {
        if (-not [string]::IsNullOrWhiteSpace($package.InstallLocation)) {
            [void]$candidates.Add((Join-Path $package.InstallLocation 'pwsh.exe'))
        }
    }
    foreach ($commandName in @('pwsh.exe', 'pwsh')) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command -and $command.Source) { [void]$candidates.Add([string]$command.Source) }
    }
    foreach ($candidate in $candidates) {
        try {
            $resolved = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
            if (Test-Path -LiteralPath $resolved -PathType Leaf) { return $resolved }
        } catch { }
    }
    throw 'PowerShell 7 was not found. Install Microsoft.PowerShell 7 or set REMOTE_CONTROL_MCP_PWSH_PATH to pwsh.exe.'
}

function Save-Download {
    param([string]$Uri, [string]$Destination, [int]$TimeoutSeconds = 30)
    $temporary = "$Destination.$([Guid]::NewGuid().ToString('N')).download"
    try {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $temporary -TimeoutSec $TimeoutSeconds -ErrorAction Stop
                Move-Item -LiteralPath $temporary -Destination $Destination -Force
                return
            } catch {
                $statusCode = $null
                if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
                    try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
                }
                $networkFailure = $_.Exception -is [Net.WebException] -or $_.Exception -is [OperationCanceledException] -or
                    $_.Exception -is [TimeoutException] -or $_.Exception.GetType().FullName -eq 'System.Net.Http.HttpRequestException'
                if ($attempt -eq 3 -or ($null -eq $statusCode -and -not $networkFailure) -or
                    ($null -ne $statusCode -and $statusCode -notin @(408, 429, 500, 502, 503, 504))) { throw }
                Write-Warning "Temporary download failure; retry $attempt/3."
                Start-Sleep -Seconds ([int][Math]::Pow(2, $attempt - 1))
            }
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function ConvertTo-CliArgument {
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-ElevatedPowerShell7 {
    $pwsh = Resolve-PowerShell7Path
    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)) {
        [void]$arguments.Add((ConvertTo-CliArgument $item))
    }
    $forward = @{
        CenterUrl = $CenterUrl; EnrollmentToken = $EnrollmentToken; AgentName = $AgentName
        HostId = $HostId; Version = $Version; ReleaseTag = $ReleaseTag; Mode = $Mode
        DesktopUser = $DesktopUser; BrowserHeadless = $BrowserHeadless; NodePath = $NodePath
        InstallRoot = $InstallRoot; StateDir = $StateDir
    }
    foreach ($entry in $forward.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.Value) -and $entry.Key -notin @('Mode', 'BrowserHeadless', 'InstallRoot', 'StateDir')) { continue }
        [void]$arguments.Add((ConvertTo-CliArgument ('-{0}' -f $entry.Key)))
        [void]$arguments.Add((ConvertTo-CliArgument ([string]$entry.Value)))
    }
    if ($Desktop) { [void]$arguments.Add('-Desktop') }
    if ($Browser) { [void]$arguments.Add('-Browser') }
    if ($ReEnroll) { [void]$arguments.Add('-ReEnroll') }
    $isAdmin = ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $start = @{ FilePath = $pwsh; ArgumentList = ($arguments -join ' '); Wait = $true; PassThru = $true; WindowStyle = 'Hidden' }
    if (-not $isAdmin) { $start.Verb = 'RunAs' }
    $child = Start-Process @start
    exit $child.ExitCode
}

# The command may be pasted into Windows PowerShell 5 or a non-elevated
# terminal. Re-enter once in PowerShell 7 and request elevation when needed;
# this is only the installer process, not a resident bootstrap component.
$isAdminNow = ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $InternalChild -and ($PSVersionTable.PSVersion.Major -lt 7 -or -not $isAdminNow)) {
    Invoke-ElevatedPowerShell7
}
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell 7 or newer is required.' }

if ([string]::IsNullOrWhiteSpace($HostId)) { $HostId = $AgentName }
if ([string]::IsNullOrWhiteSpace($ReleaseTag)) { $ReleaseTag = "java-$Version" }
if ($CenterUrl.Contains("`r") -or $CenterUrl.Contains("`n")) { throw 'CenterUrl must be one line.' }
$parsedCenterUrl = [Uri]$CenterUrl
if (-not $parsedCenterUrl.IsAbsoluteUri -or $parsedCenterUrl.Scheme -ne 'https') { throw 'CenterUrl must use HTTPS.' }
if ([string]::IsNullOrWhiteSpace($EnrollmentToken)) { throw 'EnrollmentToken is required.' }
if ($Mode -eq 'full') { $Desktop = $true; $Browser = $true }
if ($Desktop -and [string]::IsNullOrWhiteSpace($DesktopUser)) {
    $interactive = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if (-not [string]::IsNullOrWhiteSpace($interactive)) { $DesktopUser = $interactive.Substring($interactive.LastIndexOf([char]92) + 1) }
    if ([string]::IsNullOrWhiteSpace($DesktopUser)) { throw 'Desktop mode requires -DesktopUser or an active Windows user session.' }
}

$identity = Join-Path $StateDir 'identity.json'
$stage = Join-Path ([IO.Path]::GetTempPath()) ('rcm-first-install-' + [Guid]::NewGuid().ToString('N'))
$runtime = Join-Path $StateDir 'browser-runtime'
$camoufoxInstallDir = Join-Path $StateDir 'camoufox'
New-Item -ItemType Directory -Path $stage -Force | Out-Null
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

try {
    $releaseBase = "https://github.com/Prodigalgal/remote_control_mcp/releases/download/$ReleaseTag"
    $rawBase = "https://raw.githubusercontent.com/Prodigalgal/remote_control_mcp/$ReleaseTag"
    function Download-Verified {
        param([Parameter(Mandatory = $true)][string]$Asset, [switch]$Optional)
        $destination = Join-Path $stage $Asset
        try {
            Save-Download -Uri "$releaseBase/$Asset" -Destination $destination -TimeoutSeconds 180
        } catch {
            $statusCode = $null
            if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
                try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
            }
            if ($Optional -and $statusCode -eq 404) {
                Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
                Write-Warning "Release has no $Asset; the Agent's compatibility updater will be used."
                return $null
            }
            throw
        }
        $sidecar = "$destination.sha256"
        Save-Download -Uri "$releaseBase/$Asset.sha256" -Destination $sidecar
        $parts = ((Get-Content -LiteralPath $sidecar -Raw).Trim() -split '\s+')
        if ($parts.Count -lt 2 -or $parts[0] -notmatch '^[0-9a-fA-F]{64}$' -or ($parts[1].TrimStart('*') -ne $Asset)) { throw "invalid checksum sidecar for $Asset" }
        $actual = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($parts[0].ToLowerInvariant() -ne $actual) { throw "checksum mismatch for $Asset" }
        return $destination
    }

    $arch = 'windows-amd64'
    $agentZip = Download-Verified "remote-control-mcp-agent-$Version-$arch.zip"
    $updaterZip = Download-Verified "remote-control-mcp-updater-$Version-$arch.zip" -Optional
    $desktopZip = $null
    $browserZip = $null
    if ($Desktop) { $desktopZip = Download-Verified "remote-control-mcp-desktop-$Version-$arch.zip" }
    if ($Browser) { $browserZip = Download-Verified "remote-control-mcp-browser-$Version-$arch.zip" }
    $installer = Join-Path $stage 'install-agent.ps1'
    Save-Download -Uri "$rawBase/scripts/install-agent.ps1" -Destination $installer

    $adapter = ''
    if ($Browser) {
        if ([string]::IsNullOrWhiteSpace($NodePath)) { $NodePath = (Get-Command node.exe -ErrorAction Stop | Select-Object -First 1).Source }
        $NodePath = (Resolve-Path -LiteralPath $NodePath -ErrorAction Stop).Path
        $nodeDirectory = Split-Path -Parent $NodePath
        $npm = @(
            (Join-Path $nodeDirectory 'npm.cmd'),
            (Get-Command npm.cmd -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1),
            (Get-Command npm.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1)
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
        if (-not $npm) { throw 'Browser mode requires npm.cmd beside node.exe.' }
        $worker = Join-Path $runtime 'browser-worker.mjs'
        New-Item -ItemType Directory -Path $runtime, $camoufoxInstallDir -Force | Out-Null
        Save-Download -Uri "$rawBase/scripts/browser-worker.mjs" -Destination $worker
        foreach ($name in @('package.json', 'package-lock.json', 'resolve-executable.mjs')) {
            Save-Download -Uri "$rawBase/scripts/browser-runtime/$name" -Destination (Join-Path $runtime $name)
        }
        $nodeVersion = [version](& $NodePath -p 'process.versions.node')
        if ($nodeVersion -lt [version]'22.15.0') { throw 'Camoufox requires Node.js 22.15 or newer.' }
        & $npm ci --prefix $runtime --no-audit --no-fund --ignore-scripts
        if ($LASTEXITCODE -ne 0) { throw "Camoufox npm install failed with exit $LASTEXITCODE" }
        $env:CAMOUFOX_INSTALL_DIR = $camoufoxInstallDir
        $camoufoxCli = Join-Path $runtime 'node_modules\@camoufox\camoufox\dist\__main__.js'
        & $NodePath $camoufoxCli fetch
        if ($LASTEXITCODE -ne 0) { & $NodePath $camoufoxCli fetch }
        if ($LASTEXITCODE -ne 0) { throw "Camoufox browser install failed with exit $LASTEXITCODE" }
        $camoufoxExecutable = [string](& $NodePath (Join-Path $runtime 'resolve-executable.mjs'))
        if ($LASTEXITCODE -ne 0) { throw 'Camoufox executable path could not be resolved.' }
        $camoufoxExecutable = $camoufoxExecutable.Trim()
        $camoufoxInstallDir = Split-Path -Parent $camoufoxExecutable
        if (-not (Test-Path -LiteralPath $camoufoxExecutable -PathType Leaf)) { throw 'Camoufox executable is missing.' }
        $env:REMOTE_CONTROL_MCP_AGENT_CAMOUFOX_INSTALL_DIR = $camoufoxInstallDir
        $adapter = Join-Path $runtime 'browser-adapter.cmd'
        Set-Content -LiteralPath $adapter -Value "@echo off`r`nset `"CAMOUFOX_EXECUTABLE_PATH=$camoufoxExecutable`"`r`n`"$NodePath`" `"$worker`"`r`n" -Encoding ASCII -Force
    }

    $capabilities = 'command,durable_tasks,file_transfer'
    if ($Desktop) { $capabilities += ',desktop' }
    if ($Browser) { $capabilities += ',browser' }
    $env:REMOTE_CONTROL_MCP_PWSH_PATH = Resolve-PowerShell7Path
    if ($Desktop) { $env:USERNAME = $DesktopUser }
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $installer,
        '-BinaryPath', $agentZip, '-AgentName', $AgentName, '-HostId', $HostId,
        '-CenterUrl', $CenterUrl, '-EnrollmentToken', $EnrollmentToken,
        '-DefaultCwd', 'C:\', '-Capabilities', $capabilities,
        '-Version', $Version, '-InstallRoot', $InstallRoot, '-StateDir', $StateDir,
        '-MaxConcurrency', '1', '-MaxBrowserWorkers', '1', '-MaxChildProcesses', '32',
        '-MaxTotalChildProcesses', '32'
    )
    if (-not [string]::IsNullOrWhiteSpace($updaterZip)) {
        $arguments += @('-UpdaterBinaryPath', $updaterZip)
    }
    if ($Desktop) { $arguments += @('-DesktopEnabled', '-DesktopBinaryPath', $desktopZip) }
    if ($Browser) { $arguments += @('-BrowserBinaryPath', $browserZip, '-BrowserAdapter', $adapter, '-BrowserEngine', 'camoufox', '-BrowserName', 'firefox', '-BrowserHeadless', $BrowserHeadless, '-BrowserProfileDir', (Join-Path $StateDir 'browser-profile')) }
    if ($ReEnroll) { $arguments += '-ReEnroll' }
    & $env:REMOTE_CONTROL_MCP_PWSH_PATH @arguments
    if ($LASTEXITCODE -ne 0) { throw "Java Agent installation failed with exit $LASTEXITCODE" }
    [ordered]@{
        status = 'installed'; agent = $AgentName; version = $Version; capabilities = $capabilities
        desktop = [bool]$Desktop; browser = [bool]$Browser; identity_created = (Test-Path -LiteralPath $identity -PathType Leaf)
        installed_at = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Compress
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}
