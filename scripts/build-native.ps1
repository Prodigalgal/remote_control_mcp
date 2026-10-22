$ErrorActionPreference = 'Stop'

if ($env:GITHUB_ACTIONS -ne 'true') {
    throw 'Local Native Image compilation is disabled. Push a java-vX.Y.Z tag and let GitHub Actions build the matching runner artifact.'
}

$root = Split-Path -Parent $PSScriptRoot
$gradle = Join-Path $root 'java\gradlew.bat'
if (-not (Test-Path -LiteralPath $gradle)) { throw "Java Gradle Wrapper not found: $gradle" }

$native = Get-Command native-image -ErrorAction SilentlyContinue
if (-not $native) {
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($env:RCM_GRAALVM_HOME) { $candidates.Add($env:RCM_GRAALVM_HOME) }
    if ($env:GRAALVM_HOME) { $candidates.Add($env:GRAALVM_HOME) }
    if ($env:JAVA_HOME) { $candidates.Add($env:JAVA_HOME) }
    foreach ($candidate in $candidates | Select-Object -Unique) {
        $bin = Join-Path $candidate 'bin'
        if (Test-Path -LiteralPath (Join-Path $bin 'native-image.cmd')) {
            $env:JAVA_HOME = $candidate
            $env:Path = "$bin;$env:Path"
            $native = Get-Command native-image -ErrorAction SilentlyContinue
            if ($native) { break }
        }
    }
}
if (-not $native) {
    throw 'native-image was not found. Set RCM_GRAALVM_HOME to GraalVM/NIK 25.x; JVM JARs are not production binaries.'
}

$javaVersion = (& java -version 2>&1 | Select-Object -First 1)
if ($javaVersion -notmatch '25') {
    throw "Java 25 is required for the native build, detected: $javaVersion"
}

$os = if ($IsWindows) { 'windows' } else { 'linux' }
$archName = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$arch = switch ($archName) {
    'x64' { 'amd64' }
    'arm64' { 'arm64' }
    default { throw "Unsupported host architecture: $archName" }
}
$nativeMarch = switch ($arch) {
    'amd64' { 'x86-64-v2' }
    'arm64' { 'armv8-a' }
    default { throw "Unsupported Native Image architecture baseline: $arch" }
}
if ($os -eq 'windows' -and $arch -eq 'arm64') {
    throw 'GraalVM/NIK 25 Native Image does not publish a supported Windows ARM64 target; use a supported release target.'
}
$version = if ($env:RCM_RELEASE_VERSION) { $env:RCM_RELEASE_VERSION } else { (git describe --tags --always --dirty 2>$null) }
if ([string]::IsNullOrWhiteSpace($version)) { $version = 'dev' }
$out = Join-Path $root "dist\java-$os-$arch"
New-Item -ItemType Directory -Force -Path $out | Out-Null
# Do not leave generated files from a previous build in the published
# directory. Native Windows executables need their GraalVM runtime DLLs beside
# them; Center and Agent DLL sets are kept in separate directories because
# generated java.dll/jvm.dll files are not guaranteed byte-identical.
Get-ChildItem -LiteralPath $out -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(rcm-(center|agent|desktop-companion|browser-agent|updater)(\.exe|\.exe\.sha256)|.*\.dll(\.sha256)?|remote-control-mcp-.*\.zip(\.sha256)?|manifest\.json)$' } |
    Remove-Item -Force
if ($os -eq 'windows') {
    foreach ($bundle in @('center', 'agent', 'desktop', 'browser', 'updater')) {
        $bundlePath = Join-Path $out $bundle
        if (Test-Path -LiteralPath $bundlePath) { Remove-Item -LiteralPath $bundlePath -Recurse -Force }
    }
}

Push-Location (Join-Path $root 'java')
try {
    # Native Image is intentionally serialized; running Center and Agent
    # images together can consume several GiB per process.
    & $gradle -PnativeMarch=$nativeMarch :center:nativeCompile :agent:nativeCompile :desktop:nativeCompile :browser:nativeCompile :updater:nativeCompile --no-daemon --no-parallel
    if ($LASTEXITCODE -ne 0) { throw "Native Image build failed (exit $LASTEXITCODE); existing build output will not be packaged." }
    $suffix = if ($os -eq 'windows') { '.exe' } else { '' }
    $center = Join-Path (Get-Location) "center\build\native\nativeCompile\rcm-center$suffix"
    $agent = Join-Path (Get-Location) "agent\build\native\nativeCompile\rcm-agent$suffix"
    $desktop = Join-Path (Get-Location) "desktop\build\native\nativeCompile\rcm-desktop-companion$suffix"
    $browser = Join-Path (Get-Location) "browser\build\native\nativeCompile\rcm-browser-agent$suffix"
    $updater = Join-Path (Get-Location) "updater\build\native\nativeCompile\rcm-updater$suffix"
    if ($os -eq 'windows') {
        Copy-Item -LiteralPath (Join-Path $root 'scripts\first-install-agent.ps1') -Destination $out -Force
        $bundles = @(
            @{ Name = 'center'; Binary = $center }
            @{ Name = 'agent'; Binary = $agent }
            @{ Name = 'desktop'; Binary = $desktop }
            @{ Name = 'browser'; Binary = $browser }
            @{ Name = 'updater'; Binary = $updater }
        )
        foreach ($bundle in $bundles) {
            $bundleOut = Join-Path $out $bundle.Name
            New-Item -ItemType Directory -Force -Path $bundleOut | Out-Null
            $binary = $bundle.Binary
            if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw "Native artifact missing: $binary" }
            Copy-Item -LiteralPath $binary -Destination $bundleOut -Force
            $runtimeDir = Split-Path -Parent $binary
            Get-ChildItem -LiteralPath $runtimeDir -Filter '*.dll' -File -ErrorAction SilentlyContinue |
                ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $bundleOut -Force }
            Get-ChildItem -LiteralPath $bundleOut -File | ForEach-Object {
                $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
                Set-Content -LiteralPath (Join-Path $bundleOut "$($_.Name).sha256") -Value "$hash  $($_.Name)" -Encoding ascii
            }
        }
        # Produce the same usable Windows packages as the GitHub release:
        # a flat Agent archive for self-upgrade and an optional full bundle for
        # manual Center/Agent installation.  Checksums are kept beside them.
        $agentArchive = Join-Path $out "remote-control-mcp-agent-$version-$os-$arch.zip"
        Push-Location (Join-Path $out 'agent')
        try { Compress-Archive -Path '*.exe', '*.dll' -DestinationPath $agentArchive -CompressionLevel Optimal -Force }
        finally { Pop-Location }
        $agentArchiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $agentArchive).Hash.ToLowerInvariant()
        Set-Content -LiteralPath "$agentArchive.sha256" -Value "$agentArchiveHash  $(Split-Path -Leaf $agentArchive)" -Encoding ascii
        & (Join-Path $root 'scripts\verify-native-bundle.ps1') -AgentArchive $agentArchive

        $desktopArchive = Join-Path $out "remote-control-mcp-desktop-$version-$os-$arch.zip"
        Push-Location (Join-Path $out 'desktop')
        try { Compress-Archive -Path '*.exe', '*.dll' -DestinationPath $desktopArchive -CompressionLevel Optimal -Force }
        finally { Pop-Location }
        $desktopArchiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $desktopArchive).Hash.ToLowerInvariant()
        Set-Content -LiteralPath "$desktopArchive.sha256" -Value "$desktopArchiveHash  $(Split-Path -Leaf $desktopArchive)" -Encoding ascii
        & (Join-Path $root 'scripts\verify-native-bundle.ps1') -AgentArchive $desktopArchive -ExecutableName 'rcm-desktop-companion.exe'

        $browserArchive = Join-Path $out "remote-control-mcp-browser-$version-$os-$arch.zip"
        Push-Location (Join-Path $out 'browser')
        try { Compress-Archive -Path '*.exe', '*.dll' -DestinationPath $browserArchive -CompressionLevel Optimal -Force }
        finally { Pop-Location }
        $browserArchiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $browserArchive).Hash.ToLowerInvariant()
        Set-Content -LiteralPath "$browserArchive.sha256" -Value "$browserArchiveHash  $(Split-Path -Leaf $browserArchive)" -Encoding ascii
        & (Join-Path $root 'scripts\verify-native-bundle.ps1') -AgentArchive $browserArchive -ExecutableName 'rcm-browser-agent.exe'

        $updaterArchive = Join-Path $out "remote-control-mcp-updater-$version-$os-$arch.zip"
        Push-Location (Join-Path $out 'updater')
        try { Compress-Archive -Path '*.exe', '*.dll' -DestinationPath $updaterArchive -CompressionLevel Optimal -Force }
        finally { Pop-Location }
        $updaterArchiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $updaterArchive).Hash.ToLowerInvariant()
        Set-Content -LiteralPath "$updaterArchive.sha256" -Value "$updaterArchiveHash  $(Split-Path -Leaf $updaterArchive)" -Encoding ascii
        & (Join-Path $root 'scripts\verify-native-bundle.ps1') -AgentArchive $updaterArchive -ExecutableName 'rcm-updater.exe'

        $bundleArchive = Join-Path $out "remote-control-mcp-$version-$os-$arch.zip"
        Push-Location $out
        try { Compress-Archive -Path 'center', 'agent', 'desktop', 'browser', 'updater' -DestinationPath $bundleArchive -CompressionLevel Optimal -Force }
        finally { Pop-Location }
        $bundleArchiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $bundleArchive).Hash.ToLowerInvariant()
        Set-Content -LiteralPath "$bundleArchive.sha256" -Value "$bundleArchiveHash  $(Split-Path -Leaf $bundleArchive)" -Encoding ascii
    } else {
        foreach ($binary in @($center, $agent, $desktop, $browser, $updater)) {
            if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw "Native artifact missing: $binary" }
            Copy-Item -LiteralPath $binary -Destination $out -Force
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $binary).Hash.ToLowerInvariant()
            $name = Split-Path -Leaf $binary
            Set-Content -LiteralPath (Join-Path $out "$name.sha256") -Value "$hash  $name" -Encoding ascii
        }
    }
    $artifacts = Get-ChildItem -LiteralPath $out -File -Recurse |
        ForEach-Object { $_.FullName.Substring($out.Length + 1).Replace('\', '/') }
    [pscustomobject]@{ version = $version; os = $os; arch = $arch; output = $out; artifacts = $artifacts } |
        ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $out 'manifest.json') -Encoding utf8
}
finally {
    Pop-Location
}

Write-Host "Native Java artifacts written to $out" -ForegroundColor Green
