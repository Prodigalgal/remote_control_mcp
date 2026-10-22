[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$MacAddress,
    [Parameter(Mandatory = $true)][string]$InterfaceAlias,
    [ValidateRange(1, 65535)][int]$Port = 9,
    [ValidateRange(1, 5)][int]$PacketCount = 3,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-WakeMagicPacket([string]$MacAddress) {
    $hex = $MacAddress.Replace('-', '').Replace(':', '')
    if ($hex -notmatch '^[0-9a-fA-F]{12}$') { throw 'MacAddress must contain exactly six hexadecimal bytes.' }
    $mac = [byte[]]::new(6)
    for ($i = 0; $i -lt 6; $i++) { $mac[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
    $packet = [byte[]]::new(102)
    for ($i = 0; $i -lt 6; $i++) { $packet[$i] = 255 }
    for ($i = 0; $i -lt 16; $i++) { [Array]::Copy($mac, 0, $packet, 6 + $i * 6, 6) }
    return ,$packet
}

function Get-WakeBroadcast([string]$Address, [ValidateRange(1, 30)][int]$PrefixLength) {
    $ip = [Net.IPAddress]::Parse($Address)
    if ($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'Wake relay requires an IPv4 LAN interface.' }
    $bytes = $ip.GetAddressBytes()
    for ($i = 0; $i -lt 4; $i++) {
        $networkBits = [Math]::Min(8, [Math]::Max(0, $PrefixLength - 8 * $i))
        $bytes[$i] = $bytes[$i] -bor (255 -shr $networkBits)
    }
    return [Net.IPAddress]::new($bytes).ToString()
}

$packet = New-WakeMagicPacket $MacAddress
$adapter = Get-NetAdapter -Name $InterfaceAlias
if ($adapter.Status -ne 'Up') { throw "Wake relay interface is not Up: $InterfaceAlias" }
$addresses = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 |
    Where-Object { $_.AddressState -eq 'Preferred' -and $_.IPAddress -notmatch '^(127\.|169\.254\.)' })
if ($addresses.Count -ne 1) { throw 'Select a LAN interface with exactly one preferred IPv4 address.' }
$source = $addresses[0]
$broadcast = Get-WakeBroadcast $source.IPAddress $source.PrefixLength
if (-not $DryRun) {
    $udp = [Net.Sockets.UdpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
    try {
        $udp.EnableBroadcast = $true
        $udp.Client.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Parse($source.IPAddress), 0))
        # Pin only this socket to the selected interface. TUN/VPN routing must
        # not send the local broadcast through a remote proxy or exit node.
        # .NET Framework (Windows PowerShell 5.1) omits the enum member, but
        # Windows still supports IP_UNICAST_IF (31). Cast the native value.
        $udp.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::IP, [Net.Sockets.SocketOptionName]31,
            [Net.IPAddress]::HostToNetworkOrder([int]$adapter.ifIndex))
        for ($i = 0; $i -lt $PacketCount; $i++) {
            $sent = $udp.Send($packet, $packet.Length, $broadcast, $Port)
            if ($sent -ne $packet.Length) { throw 'Incomplete wake packet transmission.' }
            if ($i + 1 -lt $PacketCount) { Start-Sleep -Milliseconds 200 }
        }
    } finally { $udp.Dispose() }
}
[ordered]@{
    status = $(if ($DryRun) { 'prepared' } else { 'sent' })
    target_mac = $MacAddress; source = $source.IPAddress; broadcast = $broadcast; port = $Port
    packets = $PacketCount; verification = 'Transmission does not prove wake success; verify a new heartbeat and a completed command.'
} | ConvertTo-Json -Compress
