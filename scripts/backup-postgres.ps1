param(
    [string]$PgHost = $(if ($env:PGHOST) { $env:PGHOST } else { '127.0.0.1' }),
    [int]$Port = $(if ($env:PGPORT) { [int]$env:PGPORT } else { 5432 }),
    [string]$Database = $env:PGDATABASE,
    [string]$Username = $env:PGUSER,
    [string]$Password = $env:PGPASSWORD,
    [string]$OutputDir = (Join-Path (Get-Location) 'backups')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command pg_dump -ErrorAction SilentlyContinue)) {
    throw 'pg_dump was not found. Install the PostgreSQL client tools first.'
}
if (-not (Get-Command pg_restore -ErrorAction SilentlyContinue)) {
    throw 'pg_restore was not found. Install the PostgreSQL client tools first.'
}
if ([string]::IsNullOrWhiteSpace($Database) -or [string]::IsNullOrWhiteSpace($Username)) {
    throw 'Database and Username are required (or set PGDATABASE and PGUSER).'
}
if ($Port -lt 1 -or $Port -gt 65535) { throw 'Port must be between 1 and 65535.' }

$safeDatabase = ($Database -replace '[^A-Za-z0-9_.-]', '_')
if ([string]::IsNullOrWhiteSpace($safeDatabase)) { $safeDatabase = 'database' }
$timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$outputRoot = (New-Item -ItemType Directory -Path $OutputDir -Force).FullName
$destination = Join-Path $outputRoot "rcm-$safeDatabase-$timestamp.dump"
$temporary = "$destination.$([Guid]::NewGuid().ToString('N')).tmp"
$previousPassword = [Environment]::GetEnvironmentVariable('PGPASSWORD', 'Process')
try {
    if (-not [string]::IsNullOrEmpty($Password)) { $env:PGPASSWORD = $Password }
    $arguments = @('--no-password', '--format=custom', '--no-owner', '--no-acl', '--host', $PgHost, '--port', $Port.ToString(), '--username', $Username, '--dbname', $Database, '--file', $temporary)
    & pg_dump @arguments
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temporary -PathType Leaf)) {
        throw "pg_dump failed with exit code $LASTEXITCODE."
    }
    # Validate the archive index before publishing it. This catches truncated
    # dumps while the output is still a private temporary file.
    & pg_restore --list $temporary *> $null
    if ($LASTEXITCODE -ne 0) { throw "pg_restore could not read the generated dump (exit $LASTEXITCODE)." }
    Move-Item -LiteralPath $temporary -Destination $destination -Force
    $hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$destination.sha256" -Value "$hash  $(Split-Path -Leaf $destination)" -Encoding ascii
    $metadata = [ordered]@{
        generated_at = [DateTime]::UtcNow.ToString('o')
        database = $Database
        format = 'custom'
        bytes = (Get-Item -LiteralPath $destination).Length
        sha256 = $hash
    }
    $metadata | ConvertTo-Json -Compress | Set-Content -LiteralPath "$destination.json" -Encoding utf8
    Write-Host "PostgreSQL backup written: $destination" -ForegroundColor Green
    Write-Host "SHA-256: $hash"
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    if ($null -eq $previousPassword) { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue }
    else { $env:PGPASSWORD = $previousPassword }
}
