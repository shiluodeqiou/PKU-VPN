<#
.SYNOPSIS
    Keep Clash working while PKU VPN (Pulse Secure) is connected on Windows.

.DESCRIPTION
    PKU VPN "full tunnel" mode (vpn.pku.edu.cn) replaces the default route, so all
    traffic - including the connections Clash makes to its own proxy servers - is
    forced through the campus tunnel. This script pins the proxy server / DNS / VPN
    handshake addresses to the physical NIC with more-specific /32 routes, so that:

        app -> 127.0.0.1:7897 (Clash) -> physical NIC -> proxy server -> OpenAI
        app -> 162.105.x.x / pku.edu.cn -> Pulse tunnel -> campus

    Actions:
      status  Show Clash state, physical uplink, PKU adapter and where each
              Clash endpoint / PKU host actually leaves the machine.
      apply   Add the /32 bypass routes (needs an elevated shell).
      watch   Keep re-adding them, in case Pulse rewrites the route table.
      revert  Remove the routes added by this script.

.EXAMPLE
    pwsh -File .\pku-clash.ps1 status
    # run in an elevated PowerShell:
    pwsh -File .\pku-clash.ps1 apply
    pwsh -File .\pku-clash.ps1 watch -IntervalSeconds 60
    pwsh -File .\pku-clash.ps1 revert
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('status', 'apply', 'watch', 'revert', 'fixproxy')]
    [string]$Action = 'status',

    [int]$IntervalSeconds = 60,

    [string]$StatePath,

    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

$script:Root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if (-not $StatePath) { $StatePath = Join-Path $script:Root 'pku-clash-routes.json' }
if (-not $LogPath) { $LogPath = Join-Path $script:Root 'pku-clash.log' }

$ClashDir = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'
$PkuHosts = @('vpn.pku.edu.cn', 'pacvpn.pku.edu.cn', 'arrayvpn.pku.edu.cn')
$VirtualPattern = 'pulse|juniper|ivanti|meta|mihomo|clash|tun|tap|wireguard|openvpn|vmware|virtualbox|netease|bluetooth|loopback|wsl|hyper-v|vethernet|sangfor|isecsp'

$script:TargetCache = @{}
$script:TargetCacheTime = [datetime]::MinValue

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
    try {
        if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 1MB) {
            Remove-Item $LogPath -Force
        }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    }
    catch { }
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ProxyRefresh {
    try {
        Add-Type -Namespace Win32 -Name WinInet -MemberDefinition @'
[DllImport("wininet.dll", SetLastError = true)]
public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
'@ -ErrorAction SilentlyContinue
        [void][Win32.WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
        [void][Win32.WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
    }
    catch { }
}

function Get-ClashMixedPort {
    $configYaml = Join-Path $ClashDir 'config.yaml'
    if (Test-Path $configYaml) {
        $text = Get-Content -LiteralPath $configYaml -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($text -match '(?m)^mixed-port:\s*(\d+)') { return [int]$Matches[1] }
    }
    return 7897
}

function Invoke-EnsurePulseIgnoresProxy {
    if (-not (Test-Admin)) {
        Write-Log 'cannot set Pulse IgnoreEndpointProxy without an elevated shell' 'WARN'
        return $false
    }

    $paths = @(
        'HKLM:\SOFTWARE\Pulse Secure\Pulse',
        'HKLM:\SOFTWARE\WOW6432Node\Pulse Secure\Pulse'
    )
    $ok = $true
    foreach ($path in $paths) {
        try {
            if (-not (Test-Path $path)) {
                New-Item -Path $path -Force | Out-Null
            }
            $value = Get-ItemProperty -Path $path -Name IgnoreEndpointProxy -ErrorAction SilentlyContinue
            $enabled = $false
            if ($value -and $null -ne $value.IgnoreEndpointProxy) {
                try { $enabled = ([int]$value.IgnoreEndpointProxy -eq 1) } catch { $enabled = $false }
            }
            if (-not $enabled) {
                Remove-ItemProperty -Path $path -Name IgnoreEndpointProxy -ErrorAction SilentlyContinue
                New-ItemProperty -Path $path -Name IgnoreEndpointProxy -PropertyType DWord -Value 1 -Force | Out-Null
                Write-Log ("Pulse IgnoreEndpointProxy enabled: {0}" -f $path)
            }
        }
        catch {
            $ok = $false
            Write-Log ("failed to set Pulse IgnoreEndpointProxy at {0}: {1}" -f $path, $_.Exception.Message) 'WARN'
        }
    }
    return $ok
}

function Invoke-EnsureEdgeUsesClash {
    if (-not (Test-Admin)) {
        Write-Log 'cannot set Edge proxy policy without an elevated shell' 'WARN'
        return $false
    }

    $path = 'HKCU:\Software\Policies\Microsoft\Edge'
    try {
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        New-ItemProperty -Path $path -Name ProxyMode -PropertyType String -Value 'fixed_servers' -Force | Out-Null
        New-ItemProperty -Path $path -Name ProxyServer -PropertyType String -Value '127.0.0.1:7897' -Force | Out-Null
        New-ItemProperty -Path $path -Name ProxyBypassList -PropertyType String -Value '' -Force | Out-Null
        Write-Log 'Edge proxy policy set to fixed 127.0.0.1:7897'
        return $true
    }
    catch {
        Write-Log ("failed to set Edge proxy policy: {0}" -f $_.Exception.Message) 'WARN'
        return $false
    }
}

function Invoke-FixProxy {
    # Pulse Secure writes its own instantproxy.pac into AutoConfigURL when the
    # tunnel comes up, which silently replaces Clash's system proxy. Put Clash
    # back; the PAC is not needed because the PKU profile is a routed tunnel.
    $port = Get-ClashMixedPort
    $settings = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    try {
        $current = Get-ItemProperty -Path $settings -ErrorAction Stop
        $changed = $false
        if ([int]$current.ProxyEnable -ne 1) {
            Set-ItemProperty -Path $settings -Name ProxyEnable -Value 1 -Type DWord
            $changed = $true
        }
        if ([string]$current.ProxyServer -ne "127.0.0.1:$port") {
            Set-ItemProperty -Path $settings -Name ProxyServer -Value "127.0.0.1:$port" -Type String
            $changed = $true
        }
        if ([int]$current.AutoDetect -ne 0) {
            Set-ItemProperty -Path $settings -Name AutoDetect -Value 0 -Type DWord -ErrorAction SilentlyContinue
            $changed = $true
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$current.AutoConfigURL)) {
            Remove-ItemProperty -Path $settings -Name AutoConfigURL -ErrorAction SilentlyContinue
            $changed = $true
        }
        if ($changed) {
            Invoke-ProxyRefresh
            Write-Log ("system proxy restored to 127.0.0.1:{0} (Pulse PAC cleared)" -f $port)
        }
        else {
            Write-Log ("system proxy already points to 127.0.0.1:{0}; no refresh needed" -f $port)
        }
    }
    catch {
        Write-Log ("failed to restore system proxy: {0}" -f $_.Exception.Message) 'WARN'
    }
}

function Test-IsVirtualAdapter {
    param($Adapter)
    if (-not $Adapter) { return $true }
    return (($Adapter.Name -match $VirtualPattern) -or ($Adapter.InterfaceDescription -match $VirtualPattern))
}

function Resolve-HostIPv4 {
    param([string]$Name)
    $ips = @()
    try {
        $ips = Resolve-DnsName -Name $Name -Type A -ErrorAction Stop |
            Where-Object { $_.IPAddress } |
            Select-Object -ExpandProperty IPAddress
    }
    catch {
        try {
            $ips = [System.Net.Dns]::GetHostAddresses($Name) |
                Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
                ForEach-Object { $_.IPAddressToString }
        }
        catch { }
    }
    return @($ips | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Sort-Object -Unique)
}

function Get-ClashCurrentProfileFile {
    $profilesYaml = Join-Path $ClashDir 'profiles.yaml'
    if (Test-Path $profilesYaml) {
        $text = Get-Content -LiteralPath $profilesYaml -Raw -Encoding UTF8
        if ($text -match '(?m)^\s*current:\s*(\S+)\s*$') {
            $uid = $Matches[1]
            $pattern = '(?ms)^\s*-\s*uid:\s*' + [regex]::Escape($uid) + '\s*$(.*?)(?=^\s*-\s*uid:|\z)'
            if ($text -match $pattern) {
                $block = $Matches[1]
                if ($block -match '(?m)^\s*file:\s*(\S+)\s*$') {
                    $candidate = Join-Path $ClashDir ('profiles\' + $Matches[1])
                    if (Test-Path $candidate) { return $candidate }
                }
            }
        }
    }

    $profilesDir = Join-Path $ClashDir 'profiles'
    if (Test-Path $profilesDir) {
        $candidate = Get-ChildItem -LiteralPath $profilesDir -Filter '*.yaml' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '^(Merge|Script)' -and $_.Length -gt 5000 } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($candidate) { return $candidate.FullName }
    }
    return $null
}

function Get-ClashConfigFile {
    # The composed config is what the core actually runs (it already includes
    # subscription + extensions). Fall back to the raw subscription profile.
    $composed = Join-Path $ClashDir 'clash-verge.yaml'
    if (Test-Path $composed) { return $composed }
    return (Get-ClashCurrentProfileFile)
}

function Get-ClashProxyHosts {
    $profile = Get-ClashConfigFile
    if (-not $profile) { return @() }
    $text = Get-Content -LiteralPath $profile -Raw -ErrorAction SilentlyContinue
    if (-not $text) { return @() }

    # Handles both block style ("    server: host") and flow style
    # ("- { name: ..., server: host, port: ... }"); the look-behind keeps
    # "nameserver:" / "default-nameserver:" out of the result.
    $hosts = [regex]::Matches($text, '(?<![\w-])server:\s*[''"]?([^\s,''"}]+)') |
        ForEach-Object { $_.Groups[1].Value }

    return @($hosts |
        Where-Object { $_ -and $_ -notin @('0.0.0.0', '127.0.0.1', 'localhost') } |
        Sort-Object -Unique)
}

function Get-ClashDnsIPs {
    $profile = Get-ClashConfigFile
    if (-not $profile) { return @() }
    $text = Get-Content -LiteralPath $profile -Raw -ErrorAction SilentlyContinue
    if (-not $text) { return @() }

    $ips = @('223.5.5.5', '223.6.6.6', '119.29.29.29', '114.114.114.114')
    foreach ($m in [regex]::Matches($text, '(?:https?|tls|quic|h3)://(\d{1,3}(?:\.\d{1,3}){3})')) {
        $ips += $m.Groups[1].Value
    }
    return @($ips | Sort-Object -Unique)
}

function Get-PhysicalUplink {
    $candidates = @()

    foreach ($route in (Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)) {
        $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
        if (-not $adapter -or $adapter.Status -ne 'Up') { continue }
        if (Test-IsVirtualAdapter $adapter) { continue }
        if ($route.NextHop -eq '0.0.0.0') { continue }
        $candidates += [pscustomobject]@{
            InterfaceIndex = [int]$adapter.ifIndex
            InterfaceAlias = $adapter.Name
            Description    = $adapter.InterfaceDescription
            NextHop        = $route.NextHop
            RouteMetric    = [int]$route.RouteMetric
            IfMetric       = [int]$route.ifMetric
            Source         = 'default-route'
        }
    }

    if ($candidates.Count -eq 0) {
        # Pulse may remove the physical default route in full-tunnel mode. Its own
        # /32 route to the gateway host still points at the physical NIC.
        foreach ($hostName in $PkuHosts) {
            foreach ($ip in (Resolve-HostIPv4 $hostName)) {
                $route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "$ip/32" -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $route) { continue }
                $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
                if (-not $adapter -or (Test-IsVirtualAdapter $adapter)) { continue }
                $candidates += [pscustomobject]@{
                    InterfaceIndex = [int]$adapter.ifIndex
                    InterfaceAlias = $adapter.Name
                    Description    = $adapter.InterfaceDescription
                    NextHop        = $route.NextHop
                    RouteMetric    = [int]$route.RouteMetric
                    IfMetric       = [int]$route.ifMetric
                    Source         = "route-to-$hostName"
                }
            }
        }
    }

    if ($candidates.Count -eq 0) {
        foreach ($cfg in (Get-NetIPConfiguration -ErrorAction SilentlyContinue)) {
            if (-not $cfg.NetAdapter -or $cfg.NetAdapter.Status -ne 'Up') { continue }
            if (Test-IsVirtualAdapter $cfg.NetAdapter) { continue }
            if (-not $cfg.IPv4DefaultGateway -or -not $cfg.IPv4Address) { continue }
            $candidates += [pscustomobject]@{
                InterfaceIndex = [int]$cfg.NetAdapter.ifIndex
                InterfaceAlias = $cfg.NetAdapter.Name
                Description    = $cfg.NetAdapter.InterfaceDescription
                NextHop        = $cfg.IPv4DefaultGateway.NextHop
                RouteMetric    = [int]$cfg.IPv4DefaultGateway.RouteMetric
                IfMetric       = [int]$cfg.NetAdapter.ifIndex
                Source         = 'net-ipconfig'
            }
        }
    }

    if ($candidates.Count -eq 0) { return $null }
    return ($candidates | Sort-Object RouteMetric, IfMetric | Select-Object -First 1)
}

function Get-PulseAdapters {
    return @(Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -match 'pulse|juniper|ivanti' -or $_.Name -match 'pulse|juniper' })
}

function Test-PulseConnected {
    return [bool](@(Get-PulseAdapters | Where-Object { $_.Status -eq 'Up' }).Count -gt 0)
}

function Get-RouteForIP {
    param([string]$IP)
    try {
        $objects = Find-NetRoute -RemoteIPAddress $IP -ErrorAction Stop
        $route = $objects | Where-Object { $_.PSObject.Properties.Name -contains 'NextHop' } | Select-Object -First 1
        if ($route) {
            return [pscustomobject]@{
                InterfaceIndex = [int]$route.InterfaceIndex
                InterfaceAlias = $route.InterfaceAlias
                NextHop        = $route.NextHop
                Destination    = $route.DestinationPrefix
            }
        }
    }
    catch { }
    return $null
}

function Get-BypassTargets {
    param([switch]$Force)

    if (-not $Force -and $script:TargetCache.Count -gt 0 -and ((Get-Date) - $script:TargetCacheTime).TotalMinutes -lt 10) {
        return $script:TargetCache
    }

    $targets = [ordered]@{}
    foreach ($hostName in $PkuHosts) {
        foreach ($ip in (Resolve-HostIPv4 $hostName)) {
            if (-not $targets.Contains($ip)) { $targets[$ip] = "vpn:$hostName" }
        }
    }

    # Clash and the system resolver may see different edge IPs for the same
    # proxy host name. watch mode keeps re-resolving, so the route set grows
    # over time and covers rotated edges.
    foreach ($hostName in (Get-ClashProxyHosts)) {
        foreach ($ip in (Resolve-HostIPv4 $hostName)) {
            if (-not $targets.Contains($ip)) { $targets[$ip] = "clash:$hostName" }
        }
    }
    foreach ($ip in (Get-ClashDnsIPs)) {
        if (-not $targets.Contains($ip)) { $targets[$ip] = 'clash-dns' }
    }

    $script:TargetCache = $targets
    $script:TargetCacheTime = Get-Date
    return $script:TargetCache
}

function Get-ClashState {
    $result = [pscustomobject]@{
        SystemProxyEnabled = $false
        SystemProxyServer  = ''
        AutoConfigUrl      = ''
        TunEnabled         = $false
        Mode               = 'unknown'
        MixedPortListening = $false
        Profile            = Get-ClashCurrentProfileFile
    }

    try {
        $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        $result.SystemProxyEnabled = ([int]$ie.ProxyEnable -eq 1)
        $result.SystemProxyServer = [string]$ie.ProxyServer
        $result.AutoConfigUrl = [string]$ie.AutoConfigURL
    }
    catch { }

    $configYaml = Join-Path $ClashDir 'config.yaml'
    if (Test-Path $configYaml) {
        $text = Get-Content -LiteralPath $configYaml -Raw -Encoding UTF8
        $tunBlock = ''
        if ($text -match '(?ms)^tun:\s*\r?\n(.*?)(?=^\S)' ) { $tunBlock = $Matches[1] }
        if ($tunBlock -match '(?m)^\s*enable:\s*true') { $result.TunEnabled = $true }
    }

    $vergeYaml = Join-Path $ClashDir 'verge.yaml'
    if (Test-Path $vergeYaml) {
        $text = Get-Content -LiteralPath $vergeYaml -Raw -Encoding UTF8
        if ($text -match '(?m)^enable_tun_mode:\s*true') { $result.TunEnabled = $true }
    }

    $composed = Join-Path $ClashDir 'clash-verge.yaml'
    if (Test-Path $composed) {
        $text = Get-Content -LiteralPath $composed -Raw -Encoding UTF8
        if ($text -match '(?m)^mode:\s*(\S+)') { $result.Mode = $Matches[1] }
    }

    $result.MixedPortListening = [bool](Get-NetTCPConnection -LocalPort 7897 -State Listen -ErrorAction SilentlyContinue)
    return $result
}

function Invoke-Status {
    Write-Log '--- Clash ---'
    $clash = Get-ClashState
    $proxyState = if ($clash.SystemProxyEnabled) { "enabled ($($clash.SystemProxyServer))" } else { 'disabled' }
    Write-Log ("system proxy : {0}" -f $proxyState)
    Write-Log ("TUN mode     : {0}" -f $(if ($clash.TunEnabled) { 'enabled' } else { 'disabled' }))
    Write-Log ("mode         : {0}" -f $clash.Mode)
    if ($clash.Mode -and $clash.Mode -ne 'rule') {
        Write-Log 'Clash is not in rule mode: the PKU/library DIRECT rules will be ignored' 'WARN'
    }
    Write-Log ("port 7897    : {0}" -f $(if ($clash.MixedPortListening) { 'listening' } else { 'NOT listening' }))
    Write-Log ("profile      : {0}" -f $(if ($clash.Profile) { Split-Path $clash.Profile -Leaf } else { 'not found' }))
    if (-not $clash.SystemProxyEnabled) {
        Write-Log 'system proxy is disabled: programs that rely on it will bypass Clash' 'WARN'
    }
    if ($clash.AutoConfigUrl) {
        Write-Log ("PAC override : {0}" -f $clash.AutoConfigUrl) 'WARN'
        Write-Log 'Pulse replaced the system proxy with its PAC; run -Action fixproxy to put Clash back' 'WARN'
    }

    $composed = Join-Path $ClashDir 'clash-verge.yaml'
    if (Test-Path $composed) {
        $text = Get-Content -LiteralPath $composed -Raw -ErrorAction SilentlyContinue
        $checks = @(
            @{ Name = 'vpn.pku.edu.cn -> DIRECT'; Ok = [bool]($text -match '(?m)^-\s*DOMAIN-SUFFIX,vpn\.pku\.edu\.cn,DIRECT') },
            @{ Name = 'pku.edu.cn -> DIRECT'; Ok = [bool]($text -match '(?m)^-\s*DOMAIN-SUFFIX,pku\.edu\.cn,DIRECT') },
            @{ Name = 'academic DB -> DIRECT'; Ok = [bool]($text -match '(?m)^-\s*DOMAIN-SUFFIX,sciencedirect\.com,DIRECT') },
            @{ Name = 'ScienceDirect challenge -> DIRECT'; Ok = [bool]($text -match '(?m)^-\s*DOMAIN,brunhild\.challenges\.cloudflare\.com,DIRECT') },
            @{ Name = 'pku fake-ip bypass'; Ok = [bool]($text -match '\+\.pku\.edu\.cn') }
        )
        foreach ($check in $checks) {
            if ($check.Ok) {
                Write-Log ("rule check   : {0} OK" -f $check.Name)
            }
            else {
                Write-Log ("rule check   : {0} MISSING - restart Clash Verge and check the global extension script" -f $check.Name) 'WARN'
            }
        }
    }
    else {
        Write-Log 'rule check   : composed config not found (start Clash Verge once)' 'WARN'
    }

    Write-Log '--- VPN proxy isolation ---'
    try {
        $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        $bypass = [string]$ie.ProxyOverride
        if ($bypass -match 'pku\.edu\.cn') {
            Write-Log 'bypass list  : pku.edu.cn is excluded from the system proxy (OK)'
        }
        else {
            Write-Log 'bypass list  : pku.edu.cn is NOT excluded; Pulse will use Clash as its proxy and drop' 'WARN'
        }
    }
    catch { }

    $pulseIgnorePaths = @(
        'HKLM:\SOFTWARE\Pulse Secure\Pulse',
        'HKLM:\SOFTWARE\WOW6432Node\Pulse Secure\Pulse'
    )
    $pulseIgnoreOk = $true
    foreach ($pulseIgnorePath in $pulseIgnorePaths) {
        try {
            $pulseIgnoreValue = Get-ItemProperty -Path $pulseIgnorePath -Name IgnoreEndpointProxy -ErrorAction Stop
            if ([int]$pulseIgnoreValue.IgnoreEndpointProxy -ne 1) { $pulseIgnoreOk = $false }
        }
        catch { $pulseIgnoreOk = $false }
    }
    if ($pulseIgnoreOk) {
        Write-Log 'Pulse endpoint proxy : ignored by registry (OK)'
    }
    else {
        Write-Log 'Pulse endpoint proxy : not forced to direct; run apply/watch as administrator' 'WARN'
    }

    $pulseLog = 'C:\ProgramData\Pulse Secure\Logging\PulseClient.log'
    if (Test-Path $pulseLog) {
        $lines = @(Get-Content -LiteralPath $pulseLog -Tail 60000 -ErrorAction SilentlyContinue)
        $startIndex = -1
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ($lines[$i] -match 'attempting to get proxy settings for https://vpn\.pku\.edu\.cn') {
                $startIndex = $i
                break
            }
        }

        if ($startIndex -ge 0) {
            $result = 'unknown'
            $limit = [Math]::Min($startIndex + 40, $lines.Count)
            for ($j = $startIndex; $j -lt $limit; $j++) {
                if ($lines[$j] -match 'Got proxy ([0-9.]+:[0-9]+)') {
                    $result = $Matches[1]
                    break
                }
                if ($lines[$j] -match 'Connecting directly') {
                    $result = 'direct'
                    break
                }
            }

            if ($result -eq 'direct') {
                Write-Log 'pulse log    : last connection attempt went direct (OK)'
            }
            elseif ($result -eq 'unknown') {
                Write-Log 'pulse log    : could not determine how Pulse reached the gateway' 'WARN'
            }
            else {
                Write-Log ("pulse log    : last connection attempt used proxy {0}; Pulse must not use Clash" -f $result) 'WARN'
                Write-Log '               reconnect after the bypass fix, or set IgnoreEndpointProxy=1 (see README)' 'WARN'
            }
        }
        else {
            Write-Log 'pulse log    : no recent connection attempt found'
        }
    }

    Write-Log '--- Uplink ---'
    $uplink = Get-PhysicalUplink
    if ($uplink) {
        Write-Log ("physical NIC : {0} (if {1}, {2})  gw {3}  [{4}]" -f $uplink.InterfaceAlias, $uplink.InterfaceIndex, $uplink.Description, $uplink.NextHop, $uplink.Source)
    }
    else {
        Write-Log 'physical NIC : NOT FOUND' 'ERROR'
    }

    $pulse = Get-PulseAdapters
    if ($pulse.Count -gt 0) {
        foreach ($adapter in $pulse) {
            $addr = (Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty IPAddress)
            Write-Log ("PKU adapter  : {0} (if {1}) {2} status={3}" -f $adapter.Name, $adapter.ifIndex, $addr, $adapter.Status)
        }
    }
    else {
        Write-Log 'PKU adapter  : not connected'
    }

    Write-Log '--- Route check ---'
    $targets = Get-BypassTargets -Force
    $throughPulse = @()
    $rows = foreach ($ip in $targets.Keys) {
        $route = Get-RouteForIP $ip
        $via = if ($route) { $route.InterfaceAlias } else { '<unreachable>' }
        $isPulse = $false
        if ($route) {
            $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
            $isPulse = (($adapter.InterfaceDescription -match 'pulse|juniper|ivanti') -or ($adapter.Name -match 'pulse|juniper'))
        }
        if ($isPulse) { $throughPulse += $ip }
        [pscustomobject]@{
            Reason = $targets[$ip]
            IP     = $ip
            Via    = $via
            Pulse  = $isPulse
        }
    }
    $rows | Format-Table -AutoSize | Out-String -Width 160 | Write-Host

    if ($throughPulse.Count -gt 0) {
        Write-Log ("{0} endpoint(s) currently leave through the PKU tunnel: {1}" -f $throughPulse.Count, ($throughPulse -join ', ')) 'WARN'
        Write-Log 'Run this script with -Action apply in an elevated shell to pin them to the physical NIC.' 'WARN'
    }
    else {
        Write-Log 'All Clash / VPN endpoints leave through the physical NIC. Good.'
    }

    Write-Log '--- Connectivity through Clash ---'
    foreach ($probe in @(
            @{ Name = 'ChatGPT'; Url = 'https://chatgpt.com/backend-api/' },
            @{ Name = 'Google 204'; Url = 'https://www.google.com/generate_204' }
        )) {
        $code = & curl.exe -s -o NUL -w '%{http_code}' --max-time 12 -x 'http://127.0.0.1:7897' $probe.Url 2>$null
        if ([string]::IsNullOrWhiteSpace($code) -or $code -eq '000') {
            Write-Log ("{0,-12}: FAILED via 127.0.0.1:7897" -f $probe.Name) 'WARN'
        }
        else {
            Write-Log ("{0,-12}: HTTP {1} via 127.0.0.1:7897" -f $probe.Name, $code)
        }
    }
}

function Save-RouteState {
    param($Entries)
    try {
        $Entries | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StatePath -Encoding UTF8
    }
    catch {
        Write-Log ("failed to save state file: {0}" -f $_.Exception.Message) 'WARN'
    }
}

function Invoke-ApplyRoutes {
    param([switch]$RefreshTargets)

    if (-not (Test-Admin)) {
        Write-Log 'This action needs an elevated PowerShell (Run as Administrator).' 'ERROR'
        return $false
    }

    [void](Invoke-EnsurePulseIgnoresProxy)

    $uplink = Get-PhysicalUplink
    if (-not $uplink) {
        Write-Log 'Cannot find a physical uplink interface. Is the network up?' 'ERROR'
        return $false
    }
    Write-Log ("uplink: {0} (if {1}) gw {2}" -f $uplink.InterfaceAlias, $uplink.InterfaceIndex, $uplink.NextHop)

    $targets = if ($RefreshTargets) { Get-BypassTargets -Force } else { Get-BypassTargets }
    $state = New-Object System.Collections.ArrayList
    $added = 0
    $kept = 0
    $failed = 0

    foreach ($ip in $targets.Keys) {
        $prefix = "$ip/32"
        $reason = $targets[$ip]
        $alreadyOk = $false

        foreach ($existing in (Get-NetRoute -AddressFamily IPv4 -DestinationPrefix $prefix -ErrorAction SilentlyContinue)) {
            if ($existing.InterfaceIndex -eq $uplink.InterfaceIndex -and $existing.NextHop -eq $uplink.NextHop) {
                $alreadyOk = $true
            }
            else {
                try {
                    Remove-NetRoute -InputObject $existing -Confirm:$false -ErrorAction Stop
                    Write-Log ("replaced stale route {0} (if {1} via {2})" -f $prefix, $existing.InterfaceIndex, $existing.NextHop)
                }
                catch {
                    Write-Log ("could not remove stale route {0}: {1}" -f $prefix, $_.Exception.Message) 'WARN'
                }
            }
        }

        if (-not $alreadyOk) {
            try {
                New-NetRoute -DestinationPrefix $prefix -InterfaceIndex $uplink.InterfaceIndex -NextHop $uplink.NextHop -RouteMetric 1 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
                Write-Log ("added {0,-20} -> {1}  ({2})" -f $prefix, $uplink.NextHop, $reason)
                $added++
            }
            catch {
                $output = & route.exe add $ip mask 255.255.255.255 $uplink.NextHop metric 1 if $uplink.InterfaceIndex 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Log ("added {0,-20} -> {1}  ({2}) [route.exe]" -f $prefix, $uplink.NextHop, $reason)
                    $added++
                }
                else {
                    Write-Log ("FAILED {0}: {1}" -f $prefix, ($output -join ' ')) 'ERROR'
                    $failed++
                    continue
                }
            }
        }
        else {
            $kept++
        }

        [void]$state.Add([pscustomobject]@{
                Prefix         = $prefix
                InterfaceIndex = $uplink.InterfaceIndex
                NextHop        = $uplink.NextHop
                Reason         = $reason
            })
    }

    Save-RouteState -Entries @($state)
    Write-Log ("done: {0} added, {1} already present, {2} failed" -f $added, $kept, $failed)
    return ($failed -eq 0)
}

function Invoke-RevertRoutes {
    if (-not (Test-Admin)) {
        Write-Log 'This action needs an elevated PowerShell (Run as Administrator).' 'ERROR'
        return
    }
    if (-not (Test-Path $StatePath)) {
        Write-Log 'No saved route state found; nothing to revert.' 'WARN'
        return
    }

    $entries = @(Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json)
    foreach ($entry in $entries) {
        $existing = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix $entry.Prefix -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceIndex -eq $entry.InterfaceIndex -and $_.NextHop -eq $entry.NextHop }
        foreach ($route in $existing) {
            try {
                Remove-NetRoute -InputObject $route -Confirm:$false -ErrorAction Stop
                Write-Log ("removed {0}" -f $entry.Prefix)
            }
            catch {
                Write-Log ("failed to remove {0}: {1}" -f $entry.Prefix, $_.Exception.Message) 'WARN'
            }
        }
    }
    Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
    Write-Log 'revert done.'
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------

switch ($Action) {
    'status' { Invoke-Status }
    'apply' { [void](Invoke-ApplyRoutes -RefreshTargets); Invoke-FixProxy }
    'revert' { Invoke-RevertRoutes }
    'fixproxy' { Invoke-FixProxy }
    'watch' {
        if (-not (Test-Admin)) {
            Write-Log 'watch needs an elevated PowerShell (Run as Administrator).' 'ERROR'
            exit 1
        }

        $watchMutex = New-Object System.Threading.Mutex($false, 'Global\PKU-VPN-Clash-Watch')
        if (-not $watchMutex.WaitOne(0)) {
            Write-Log 'watch is already running; this instance will exit.' 'WARN'
            $watchMutex.Dispose()
            return
        }

        try {
        Write-Log ("watch started, interval {0}s. Press Ctrl+C to stop." -f $IntervalSeconds)
        [void](Invoke-EnsurePulseIgnoresProxy)
        [void](Invoke-EnsureEdgeUsesClash)
        $round = 0
        while ($true) {
            $round++
            Invoke-FixProxy
            if (Test-PulseConnected) {
                Write-Log 'Pulse adapter is up; skipping route rewrite to keep the VPN session stable'
            }
            else {
                [void](Invoke-ApplyRoutes -RefreshTargets)
            }
            Write-Log ("round {0} done, sleeping {1}s" -f $round, $IntervalSeconds)
            Start-Sleep -Seconds $IntervalSeconds
        }
        }
        finally {
            try { $watchMutex.ReleaseMutex() } catch { }
            $watchMutex.Dispose()
        }
    }
}
