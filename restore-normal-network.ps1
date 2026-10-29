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
$failed = $false

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
        if (Get-Process -Id $watcher.ProcessId -ErrorAction SilentlyContinue) {
            $failed = $true
        }
    }
}

Write-Host '[2/4] Removing PKU-Clash routes...' -ForegroundColor Cyan
$routeScript = Join-Path $root 'pku-clash.ps1'
if (Test-Path -LiteralPath $routeScript) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $routeScript -Action revert
    if ($LASTEXITCODE -ne 0) {
        Write-Warning ("  route cleanup failed with exit code {0}" -f $LASTEXITCODE)
        $failed = $true
    }
}
else {
    Write-Warning "  route script not found: $routeScript"
    $failed = $true
}

Write-Host '[3/4] Restoring Edge to system proxy mode...' -ForegroundColor Cyan
try {
    $edgePolicy = 'HKCU:\Software\Policies\Microsoft\Edge'
    if (Test-Path -LiteralPath $edgePolicy) {
        $properties = (Get-ItemProperty -LiteralPath $edgePolicy).PSObject.Properties.Name
        foreach ($name in @('ProxyMode', 'ProxyServer', 'ProxyBypassList', 'ProxyPacUrl')) {
            if ($properties -contains $name) {
                Remove-ItemProperty -LiteralPath $edgePolicy -Name $name -ErrorAction Stop
            }
        }
    }
}
catch {
    Write-Warning ("  failed to reset Edge proxy policy: {0}" -f $_.Exception.Message)
    $failed = $true
}

Write-Host '[4/4] Disabling the Windows system proxy...' -ForegroundColor Cyan
$settings = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
try {
    $currentSettings = Get-ItemProperty -LiteralPath $settings -ErrorAction Stop
    $settingNames = $currentSettings.PSObject.Properties.Name
    Set-ItemProperty -LiteralPath $settings -Name ProxyEnable -Value 0 -Type DWord -ErrorAction Stop
    if ($settingNames -contains 'AutoConfigURL') {
        Remove-ItemProperty -LiteralPath $settings -Name AutoConfigURL -ErrorAction Stop
    }
    if ($settingNames -contains 'AutoDetect') {
        Set-ItemProperty -LiteralPath $settings -Name AutoDetect -Value 0 -Type DWord -ErrorAction Stop
    }
    else {
        New-ItemProperty -LiteralPath $settings -Name AutoDetect -PropertyType DWord -Value 0 -ErrorAction Stop | Out-Null
    }
}
catch {
    Write-Warning ("  failed to disable the system proxy: {0}" -f $_.Exception.Message)
    $failed = $true
}

try {
    Add-Type -Namespace Win32 -Name WinInetRestore -MemberDefinition @'
[DllImport("wininet.dll", SetLastError = true)]
public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
'@ -ErrorAction SilentlyContinue
    $refreshSettings = [Win32.WinInetRestore]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
    $notifyChanged = [Win32.WinInetRestore]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
    if (-not $refreshSettings -or -not $notifyChanged) {
        Write-Warning '  WinINet did not report a successful proxy refresh'
        $failed = $true
    }
}
catch {
    Write-Warning ("  failed to refresh WinINet proxy settings: {0}" -f $_.Exception.Message)
    $failed = $true
}

Write-Host ''
if ($failed) {
    Write-Host '恢复过程没有完全成功，请根据上方警告检查网络状态。' -ForegroundColor Red
    if (-not $NoPause) { Read-Host '按 Enter 关闭' }
    exit 1
}

Write-Host '普通上网模式已恢复。请完全重启 Edge，使代理策略立即生效。' -ForegroundColor Green
if (-not $NoPause) { Read-Host '按 Enter 关闭' }
exit 0
