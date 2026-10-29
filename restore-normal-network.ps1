<##
.SYNOPSIS
    Restore ordinary direct browsing after using PKU VPN + Clash.
#>
[CmdletBinding()]
param(
    [switch]$NoPause
)

$ErrorActionPreference = 'Continue'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

Write-Host '[1/4] Stopping the PKU-VPN route monitor...' -ForegroundColor Cyan
$watchers = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.CommandLine -and
        $_.CommandLine -match 'pku-clash\.ps1' -and
        $_.CommandLine -match '(?i)-Action[\s''"]+watch'
    }
foreach ($watcher in $watchers) {
    try {
        Stop-Process -Id ([int]$watcher.ProcessId) -Force -ErrorAction Stop
        Write-Host ("  stopped process {0}" -f $watcher.ProcessId)
    }
    catch {
        Write-Warning ("  could not stop process {0}: {1}" -f $watcher.ProcessId, $_.Exception.Message)
    }
}

Write-Host '[2/4] Removing PKU-Clash routes...' -ForegroundColor Cyan
$routeScript = Join-Path $root 'pku-clash.ps1'
if (Test-Path -LiteralPath $routeScript) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $routeScript -Action revert
}

Write-Host '[3/4] Restoring Edge to system proxy mode...' -ForegroundColor Cyan
$edgePolicy = 'HKCU:\Software\Policies\Microsoft\Edge'
foreach ($name in @('ProxyMode', 'ProxyServer', 'ProxyBypassList', 'ProxyPacUrl')) {
    Remove-ItemProperty -Path $edgePolicy -Name $name -ErrorAction SilentlyContinue
}

Write-Host '[4/4] Disabling the Windows system proxy...' -ForegroundColor Cyan
$settings = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
Set-ItemProperty -Path $settings -Name ProxyEnable -Value 0 -Type DWord
Remove-ItemProperty -Path $settings -Name AutoConfigURL -ErrorAction SilentlyContinue
Set-ItemProperty -Path $settings -Name AutoDetect -Value 0 -Type DWord -ErrorAction SilentlyContinue

try {
    Add-Type -Namespace Win32 -Name WinInetRestore -MemberDefinition @'
[DllImport("wininet.dll", SetLastError = true)]
public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
'@ -ErrorAction SilentlyContinue
    [void][Win32.WinInetRestore]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
    [void][Win32.WinInetRestore]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
}
catch { }

Write-Host ''
Write-Host '普通上网模式已恢复。请完全重启 Edge，使代理策略立即生效。' -ForegroundColor Green
if (-not $NoPause) { Read-Host '按 Enter 关闭' }
