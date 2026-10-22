[CmdletBinding()]
param(
    [Security.SecureString]$NewToken,

    [string]$EnvFile = "center.env",

    [string]$Namespace = "remote-control-mcp",

    [string]$SecretName = "remote-control-mcp-secrets",

    [string]$DeploymentName = "remote-control-mcp-center",

    [string]$ConsoleUrl = "https://console.example.invalid",

    [string]$McpUrl = "https://gateway.example.invalid"
)

$ErrorActionPreference = "Stop"

$keys = @{
    admin = @{
        Env = "REMOTE_CONTROL_MCP_CENTER_ADMIN_TOKEN"
        Secret = "admin-token"
    }
}

function ConvertFrom-SecureValue([Security.SecureString]$Value) {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Read-EnvValues([string]$Path) {
    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') {
            $values[$matches[1]] = $matches[2]
        }
    }
    return $values
}

function Write-EnvValues([string]$Path, [hashtable]$Values) {
    $name = "REMOTE_CONTROL_MCP_CENTER_ADMIN_TOKEN"
    $lines = [System.Collections.Generic.List[string]]::new()
    $adminWritten = $false
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=') {
            $variable = $matches[1]
            if ($variable -in @("REMOTE_CONTROL_MCP_CENTER_MCP_TOKEN", "REMOTE_CONTROL_MCP_CENTER_ENROLLMENT_TOKEN")) {
                continue
            }
            if ($variable -eq $name) {
                if (-not $adminWritten) {
                    $lines.Add("$name=$($Values[$name])")
                    $adminWritten = $true
                }
                continue
            }
        }
        $lines.Add($line)
    }
    if (-not $adminWritten) { $lines.Add("$name=$($Values[$name])") }
    $temp = "$Path.tmp"
    [IO.File]::WriteAllLines($temp, $lines.ToArray(), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Set-LiveSecretValue([string]$SecretKey, [string]$Value) {
    $secret = kubectl -n $Namespace get secret $SecretName -o json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $secret) {
        throw "Cannot read Secret/$SecretName from namespace $Namespace."
    }
    $secret.data.$SecretKey = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
    $secret | ConvertTo-Json -Depth 30 -Compress | kubectl replace -f - | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot update Secret/$SecretName."
    }
}

function Test-NewCredential([string]$Token) {
    Invoke-RestMethod -Uri "$ConsoleUrl/api/v1/admin/machines" -Headers @{ Authorization = "Bearer $Token" } -TimeoutSec 15 | Out-Null
}

if (-not (Test-Path -LiteralPath $EnvFile)) {
    throw "Center env file was not found: $EnvFile"
}
if (-not $NewToken) {
    $NewToken = Read-Host "Enter the new Admin token" -AsSecureString
}
$plainToken = ConvertFrom-SecureValue $NewToken
if ($plainToken.Length -lt 32 -or $plainToken -match '[\r\n]' -or $plainToken.Contains("REMOTE_CONTROL_MCP_CENTER_")) {
    throw "Token must be one line, at least 32 characters, and must not contain an environment key."
}

$values = Read-EnvValues $EnvFile
foreach ($entry in $keys.Values) {
    if (-not $values.ContainsKey($entry.Env) -or [string]::IsNullOrWhiteSpace($values[$entry.Env])) {
        throw "Missing $($entry.Env) in $EnvFile."
    }
}
$selected = $keys.admin
$oldEnvContent = [IO.File]::ReadAllText($EnvFile)
$oldSecret = kubectl -n $Namespace get secret $SecretName -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $oldSecret) {
    throw "Cannot read the current Kubernetes Secret."
}
$oldSecretValue = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($oldSecret.data.($selected.Secret)))

try {
    $values[$selected.Env] = $plainToken
    Set-LiveSecretValue $selected.Secret $plainToken
    Write-EnvValues $EnvFile $values
    kubectl -n $Namespace rollout restart "deployment/$DeploymentName" | Out-Null
    kubectl -n $Namespace rollout status "deployment/$DeploymentName" --timeout=180s | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Center rollout did not complete."
    }
    $health = Invoke-RestMethod -Uri "$McpUrl/api/v1/healthz" -TimeoutSec 15
    if ($health.status -ne "ok") {
        throw "Center health check failed."
    }
    Test-NewCredential $plainToken
}
catch {
    Set-LiveSecretValue $selected.Secret $oldSecretValue
    [IO.File]::WriteAllText($EnvFile, $oldEnvContent, [Text.UTF8Encoding]::new($false))
    kubectl -n $Namespace rollout restart "deployment/$DeploymentName" | Out-Null
    kubectl -n $Namespace rollout status "deployment/$DeploymentName" --timeout=180s | Out-Null
    throw
}
finally {
    $plainToken = $null
    $oldSecretValue = $null
}

Write-Host "Admin token was updated in the private env file and Kubernetes Secret."
Write-Host "Sign in to the control console again with the new Admin token."
