[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AgentName,
    [string]$HostId = "",
    [string]$CenterUrl = "",
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$ReleaseTag = "",
    [string]$StageRoot = "",
    [string]$InstallRoot = "$env:ProgramFiles\Remote Control MCP Agent",
    [string]$StateDir = "$env:ProgramData\RemoteControlMCPAgent",
    [string]$NodePath = "",
    [ValidatePattern("^[A-Za-z_][A-Za-z0-9_.-]{0,63}$")]
    [string]$DesktopUser = "",
    [string]$BrowserProfileDir = "",
    [ValidateSet("0", "1")]
    [string]$BrowserHeadless = "1",
    [switch]$RuntimeOnly
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
    foreach ($package in @(@(Get-AppxPackage -AllUsers -Name Microsoft.PowerShell -ErrorAction SilentlyContinue) +
        @(Get-AppxPackage -Name Microsoft.PowerShell -ErrorAction SilentlyContinue) |
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

if ([string]::IsNullOrWhiteSpace($HostId)) { $HostId = $AgentName }
if ([string]::IsNullOrWhiteSpace($ReleaseTag)) { $ReleaseTag = "java-$Version" }
if ([string]::IsNullOrWhiteSpace($CenterUrl) -or $CenterUrl.Contains("`r") -or $CenterUrl.Contains("`n")) {
    throw "CenterUrl is required and must be one line."
}
$parsedCenterUrl = [Uri]$CenterUrl
if (-not $parsedCenterUrl.IsAbsoluteUri -or $parsedCenterUrl.Scheme -ne 'https') {
    throw "CenterUrl must use HTTPS."
}
if ([string]::IsNullOrWhiteSpace($StageRoot)) {
    $StageRoot = Join-Path $StateDir ("desktop-browser-" + $Version)
}
if ([string]::IsNullOrWhiteSpace($BrowserProfileDir)) {
    $BrowserProfileDir = Join-Path $StateDir "browser-profile"
}
$camoufoxInstallDir = Join-Path $StateDir 'camoufox'
New-Item -ItemType Directory -Path $camoufoxInstallDir -Force | Out-Null

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this deployment from an elevated PowerShell or SYSTEM task."
}
$pwsh = Resolve-PowerShell7Path

New-Item -ItemType Directory -Path $StageRoot -Force | Out-Null
$driveName = [IO.Path]::GetPathRoot($StageRoot).TrimEnd('\').TrimEnd(':')
$drive = Get-PSDrive -Name $driveName -ErrorAction Stop
if ($drive.Free -lt 1GB) { throw "free space on $driveName`: is below 1 GiB" }

$releaseBase = "https://github.com/Prodigalgal/remote_control_mcp/releases/download/$ReleaseTag"
$rawBase = "https://raw.githubusercontent.com/Prodigalgal/remote_control_mcp/$ReleaseTag"

function Download-Verified {
    param([Parameter(Mandatory = $true)][string]$Asset)
    $url = "$releaseBase/$Asset"
    $zip = Join-Path $StageRoot $Asset
    $shaFile = "$zip.sha256"
    Save-Download -Uri $url -Destination $zip -TimeoutSeconds 180
    Save-Download -Uri "$url.sha256" -Destination $shaFile
    $parts = ((Get-Content -LiteralPath $shaFile -Raw).Trim() -split '\s+')
    if ($parts.Count -lt 2 -or $parts[0] -notmatch '^[0-9a-fA-F]{64}$' -or $parts[1].TrimStart('*') -ne $Asset) {
        throw "invalid checksum sidecar for $Asset"
    }
    $expected = $parts[0].ToLowerInvariant()
    $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expected -ne $actual) { throw "checksum mismatch for $Asset" }
    return $zip
}

$agentZip = $null
$desktopZip = $null
$browserZip = $null
if (-not $RuntimeOnly) {
    $agentZip = Download-Verified "remote-control-mcp-agent-$Version-windows-amd64.zip"
    $desktopZip = Download-Verified "remote-control-mcp-desktop-$Version-windows-amd64.zip"
    $browserZip = Download-Verified "remote-control-mcp-browser-$Version-windows-amd64.zip"
}
$installer = Join-Path $StageRoot "install-agent.ps1"
# Prefer the checked-out installer when this script is run from the repository;
# this keeps local recovery aligned with the current PowerShell/MSIX fixes. A
# downloaded tagged copy remains the fallback for standalone deployments.
$localInstaller = Join-Path $PSScriptRoot 'install-agent.ps1'
if (Test-Path -LiteralPath $localInstaller -PathType Leaf) {
    Copy-Item -LiteralPath $localInstaller -Destination $installer -Force
} else {
    Save-Download -Uri "$rawBase/scripts/install-agent.ps1" -Destination $installer
}

$runtime = Join-Path $StageRoot "browser-runtime"
New-Item -ItemType Directory -Path $runtime -Force | Out-Null
$worker = Join-Path $runtime "browser-worker.mjs"
Save-Download -Uri "$rawBase/scripts/browser-worker.mjs" -Destination $worker
foreach ($name in @('package.json', 'package-lock.json', 'resolve-executable.mjs')) {
    Save-Download -Uri "$rawBase/scripts/browser-runtime/$name" -Destination (Join-Path $runtime $name)
}
$node = if ([string]::IsNullOrWhiteSpace($NodePath)) {
    (Get-Command node.exe -ErrorAction Stop).Source
} else {
    (Resolve-Path -LiteralPath $NodePath -ErrorAction Stop).Path
}
$nodeVersion = [version](& $node -p 'process.versions.node')
if ($nodeVersion -lt [version]'22.15.0') { throw 'Camoufox requires Node.js 22.15 or newer.' }
$env:CAMOUFOX_INSTALL_DIR = $camoufoxInstallDir
$nodeDirectory = Split-Path -Parent $node
$npm = @(
    (Join-Path $nodeDirectory "npm.cmd"),
    (Get-Command npm.cmd -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1),
    (Get-Command npm.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1)
) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
if ($npm) {
    & $npm ci --prefix $runtime --no-audit --no-fund --ignore-scripts
} else {
    $npmCli = Join-Path $nodeDirectory "node_modules\npm\bin\npm-cli.js"
    if (-not (Test-Path -LiteralPath $npmCli -PathType Leaf)) {
        throw "npm.cmd and npm-cli.js were not found beside node.exe"
    }
    & $node $npmCli ci --prefix $runtime --no-audit --no-fund --ignore-scripts
}
if ($LASTEXITCODE -ne 0) { throw "Camoufox npm install failed with exit $LASTEXITCODE" }
$camoufoxCli = Join-Path $runtime 'node_modules\@camoufox\camoufox\dist\__main__.js'
& $node $camoufoxCli fetch
if ($LASTEXITCODE -ne 0) { & $node $camoufoxCli fetch }
if ($LASTEXITCODE -ne 0) { throw "Camoufox browser install failed with exit $LASTEXITCODE" }
$camoufoxExecutable = [string](& $node (Join-Path $runtime 'resolve-executable.mjs'))
if ($LASTEXITCODE -ne 0) { throw 'Camoufox executable path could not be resolved.' }
$camoufoxExecutable = $camoufoxExecutable.Trim()
$camoufoxInstallDir = Split-Path -Parent $camoufoxExecutable
if (-not (Test-Path -LiteralPath $camoufoxExecutable -PathType Leaf)) { throw 'Camoufox executable is missing.' }
$adapterWrapper = Join-Path $runtime 'browser-adapter.cmd'
$adapterContent = "@echo off`r`nset `"CAMOUFOX_EXECUTABLE_PATH=$camoufoxExecutable`"`r`n`"$node`" `"$worker`"`r`n"
Set-Content -LiteralPath $adapterWrapper -Value $adapterContent -Encoding ASCII -Force
if ($RuntimeOnly) {
    [ordered]@{ status = 'completed'; worker = $worker; worker_sha256 = (Get-FileHash -LiteralPath $worker -Algorithm SHA256).Hash.ToLowerInvariant(); browser_adapter = $adapterWrapper; camoufox_executable = $camoufoxExecutable } | ConvertTo-Json
    return
}

function ConvertTo-PSLiteral {
    param([AllowEmptyString()][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

# The current command Agent must not stop itself while the installer replaces
# its loaded Native Image bundle.  A short-lived SYSTEM task applies the
# change after this staging command has returned to Center.
$apply = Join-Path $StageRoot "apply.ps1"
$statusFile = Join-Path $StageRoot "apply-status.json"
$applyTaskName = "RemoteControlMCPDesktopBrowserApply-" + ($Version -replace '[^A-Za-z0-9]', '')
$applyLines = @(
    '$ErrorActionPreference = "Stop"',
    '$ProgressPreference = "SilentlyContinue"',
    ('$stage = {0}' -f (ConvertTo-PSLiteral $StageRoot)),
    ('$statusFile = {0}' -f (ConvertTo-PSLiteral $statusFile)),
    ('$applyTaskName = {0}' -f (ConvertTo-PSLiteral $applyTaskName)),
    ('$agentName = {0}' -f (ConvertTo-PSLiteral $AgentName)),
    ('$hostId = {0}' -f (ConvertTo-PSLiteral $HostId)),
    ('$centerUrl = {0}' -f (ConvertTo-PSLiteral $CenterUrl)),
    ('$version = {0}' -f (ConvertTo-PSLiteral $Version)),
    ('$installRoot = {0}' -f (ConvertTo-PSLiteral $InstallRoot)),
    ('$stateDir = {0}' -f (ConvertTo-PSLiteral $StateDir)),
    ('$nodePath = {0}' -f (ConvertTo-PSLiteral $node)),
    ('$camoufoxInstallDir = {0}' -f (ConvertTo-PSLiteral $camoufoxInstallDir)),
    ('$camoufoxExecutable = {0}' -f (ConvertTo-PSLiteral $camoufoxExecutable)),
    ('$desktopUser = {0}' -f (ConvertTo-PSLiteral $DesktopUser)),
    ('$browserProfileDir = {0}' -f (ConvertTo-PSLiteral $BrowserProfileDir)),
    ('$browserHeadless = {0}' -f (ConvertTo-PSLiteral $BrowserHeadless)),
    ('function Resolve-PowerShell7Path {' + [Environment]::NewLine + ${function:Resolve-PowerShell7Path}.ToString() + [Environment]::NewLine + '}'),
    'try {',
    '  $pwsh = Resolve-PowerShell7Path',
    '  $u = (Get-CimInstance Win32_ComputerSystem).UserName',
    '  if ([string]::IsNullOrWhiteSpace($desktopUser)) { if (-not [string]::IsNullOrWhiteSpace($u)) { $desktopUser = $u.Substring($u.LastIndexOf([char]92) + 1) } }',
    '  if ([string]::IsNullOrWhiteSpace($desktopUser)) { throw "no interactive user; pass -DesktopUser for a not-yet-logged-in GUI host" }',
    '  $env:USERNAME = $desktopUser',
    '  $node = $nodePath',
    '  $env:REMOTE_CONTROL_MCP_PWSH_PATH = $pwsh',
    '  $worker = Join-Path $stage "browser-runtime\browser-worker.mjs"',
    # Keep the adapter executable invocation in a tiny .cmd shim.  Passing a
    # quoted multi-path command as one ProcessBuilder argument is parsed twice
    # by cmd.exe and fails on Windows when either path contains spaces.  The
    # shim is stable inside the staged runtime directory and retains normal
    # quoted paths for Node and the Worker.
    '  $adapterWrapper = Join-Path $stage "browser-runtime\browser-adapter.cmd"',
    '  $adapterContent = "@echo off`r`nset `"CAMOUFOX_EXECUTABLE_PATH=$camoufoxExecutable`"`r`n`"$node`" `"$worker`"`r`n"',
    '  Set-Content -LiteralPath $adapterWrapper -Value $adapterContent -Encoding ASCII -Force',
    '  $adapter = $adapterWrapper',
    '  $installer = Join-Path $stage "install-agent.ps1"',
    ('  $agent = Join-Path $stage {0}' -f (ConvertTo-PSLiteral (Split-Path -Leaf $agentZip))),
    ('  $desktop = Join-Path $stage {0}' -f (ConvertTo-PSLiteral (Split-Path -Leaf $desktopZip))),
    ('  $browser = Join-Path $stage {0}' -f (ConvertTo-PSLiteral (Split-Path -Leaf $browserZip))),
    '  & $pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installer -BinaryPath $agent -AgentName $agentName -HostId $hostId -CenterUrl $centerUrl -DefaultCwd "C:\" -Capabilities "command,durable_tasks,desktop,browser,file_transfer" -Version $version -DesktopEnabled -DesktopBinaryPath $desktop -BrowserBinaryPath $browser -BrowserAdapter $adapter -BrowserEngine camoufox -BrowserName firefox -BrowserHeadless $browserHeadless -CamoufoxInstallDir $camoufoxInstallDir -BrowserProfileDir $browserProfileDir -MaxConcurrency 1 -MaxBrowserWorkers 1 -DesktopMaxLaunchedProcesses 16 -MaxChildProcesses 32 -MaxTotalChildProcesses 32',
    '  if ($LASTEXITCODE -ne 0) { throw "agent installer failed with exit $LASTEXITCODE" }',
    '  try { Start-ScheduledTask -TaskName "RemoteControlMCPDesktopCompanion" -ErrorAction Stop } catch { }',
    '  Start-Sleep -Seconds 3',
    '  $desktopState = (Get-ScheduledTask -TaskName "RemoteControlMCPDesktopCompanion" -ErrorAction SilentlyContinue).State',
    '  [ordered]@{ status = "completed"; desktop_task_state = [string]$desktopState; browser_runtime = "camoufox"; finished_at = (Get-Date).ToUniversalTime().ToString("o") } | ConvertTo-Json | Set-Content -LiteralPath $statusFile -Encoding UTF8',
    '} catch {',
    '  [ordered]@{ status = "failed"; error = $_.Exception.Message; finished_at = (Get-Date).ToUniversalTime().ToString("o") } | ConvertTo-Json | Set-Content -LiteralPath $statusFile -Encoding UTF8',
    '  exit 1',
    '} finally {',
    '  Unregister-ScheduledTask -TaskName $applyTaskName -Confirm:$false -ErrorAction SilentlyContinue',
    '}'
)
Set-Content -LiteralPath $apply -Value ($applyLines -join [Environment]::NewLine) -Encoding Unicode -Force

$taskHost = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $taskHost -PathType Leaf)) { throw "Windows PowerShell task host is missing: $taskHost" }
$action = New-ScheduledTaskAction -Execute $taskHost -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $apply)
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(15)
$applyPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Unregister-ScheduledTask -TaskName $applyTaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $applyTaskName -Action $action -Trigger $trigger -Principal $applyPrincipal -Description "Remote Control MCP Desktop/Browser $Version apply" -Force | Out-Null
Start-ScheduledTask -TaskName $applyTaskName

[ordered]@{
    status = "staged"
    scheduled_task = $applyTaskName
    desktop_sha256_verified = $true
    browser_sha256_verified = $true
    browser_runtime = 'camoufox'
    scheduled_at = (Get-Date).ToUniversalTime().ToString("o")
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $StageRoot "stage-status.json") -Encoding UTF8
Write-Output "RCM_DESKTOP_BROWSER_STAGE_OK"
