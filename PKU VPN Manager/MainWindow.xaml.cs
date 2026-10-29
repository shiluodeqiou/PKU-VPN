using Microsoft.Win32;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Threading;

namespace PKUVpnManager;

public partial class MainWindow : Window
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunName = "PKUVpnManager";
    private const string LegacyRunCoexistName = "PKUVpnManagerCoexist";
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(5) };
    private readonly string _root = AppContext.BaseDirectory;
    private bool _loading;
    private bool _refreshing;

    private string ClashExe => ResolveExecutable(
        "PKU_CLASH_EXE",
        Path.GetFullPath(Path.Combine(_root, "..", "..", "..", "Clash Verge", "clash-verge.exe")),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Clash Verge", "clash-verge.exe"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Clash Verge", "clash-verge.exe"));

    private string PulseExe => ResolveExecutable(
        "PKU_PULSE_EXE",
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Common Files", "Pulse Secure", "JamUI", "Pulse.exe"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Common Files", "Pulse Secure", "JamUI", "Pulse.exe"));

    private string EdgeExe => ResolveExecutable(
        "PKU_EDGE_EXE",
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Microsoft", "Edge", "Application", "msedge.exe"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Microsoft", "Edge", "Application", "msedge.exe"));

    public MainWindow()
    {
        InitializeComponent();
        var runState = ReadRunState();
        _loading = true;
        StartWithWindowsCheckBox.IsChecked = runState.Enabled;
        AutoStartCoexistCheckBox.IsChecked = runState.Coexist;
        _loading = false;

        AppendLog("管理器启动");
        if (runState.NeedsMigration)
        {
            try
            {
                SetRunValue(runState.Enabled, runState.Coexist);
                AppendLog("已把旧的双开机启动项迁移为单一启动项");
            }
            catch (Exception ex)
            {
                AppendLog("迁移开机启动项失败：" + ex.Message);
            }
        }

        _timer.Tick += async (_, _) => await RefreshStatusAsync();
        Loaded += async (_, _) =>
        {
            await RefreshStatusAsync();
            if (Environment.GetCommandLineArgs().Contains("--startup-coexist", StringComparer.OrdinalIgnoreCase))
                await StartAllAsync();
            _timer.Start();
        };
        Closing += (_, _) => _timer.Stop();
    }

    private async Task RefreshStatusAsync()
    {
        if (_refreshing) return;
        _refreshing = true;
        try
        {
            var pulseAdapter = await GetPulseAdapterAsync();
            var pulseRunning = Process.GetProcessesByName("Pulse").Length > 0;
            var clashRunning = IsClashRunning();
            var proxy = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Internet Settings");
            var proxyEnabled = Convert.ToInt32(proxy?.GetValue("ProxyEnable", 0) ?? 0) == 1;
            var proxyServer = proxy?.GetValue("ProxyServer")?.ToString() ?? "";
            var edge = Registry.CurrentUser.OpenSubKey(@"Software\Policies\Microsoft\Edge");
            var edgeMode = edge?.GetValue("ProxyMode")?.ToString() ?? "";
            var edgeProxy = edge?.GetValue("ProxyServer")?.ToString() ?? "";
            var ignoreProxy = ReadPulseIgnoreProxy();

            PulseStatusText.Text = pulseAdapter is null ? "未连接" : "已连接";
            PulseStatusText.Foreground = FindResource(pulseAdapter is null ? "DangerBrush" : "SuccessBrush") as System.Windows.Media.Brush;
            PulseDetailText.Text = pulseAdapter is null
                ? "请在 Ivanti 中连接北大 VPN并完成二次验证"
                : $"{pulseAdapter}  ·  IgnoreEndpointProxy={(ignoreProxy ? "已启用" : "未启用")}";

            ClashStatusText.Text = clashRunning ? "运行中" : "未运行";
            ClashStatusText.Foreground = FindResource(clashRunning ? "SuccessBrush" : "DangerBrush") as System.Windows.Media.Brush;
            ClashDetailText.Text = proxyEnabled ? $"系统代理 {proxyServer}" : "系统代理已关闭";

            EdgeStatusText.Text = edgeMode == "fixed_servers" && edgeProxy.Contains("127.0.0.1:7897")
                ? "Clash 代理"
                : "系统默认";
            EdgeStatusText.Foreground = FindResource(edgeMode == "fixed_servers" ? "PrimaryBrush" : "TextMutedBrush") as System.Windows.Media.Brush;
            EdgeDetailText.Text = Process.GetProcessesByName("msedge").Length > 0
                ? "Edge 正在运行"
                : "Edge 已关闭";

            ModeText.Text = pulseAdapter is not null && clashRunning ? "Clash + Pulse 共存" : "普通模式 / 未完成连接";
            FooterStatusText.Text = DateTime.Now.ToString("HH:mm:ss");
            LastCheckText.Text = $"最近检查：{DateTime.Now:yyyy-MM-dd HH:mm:ss}";
        }
        catch (Exception ex)
        {
            AppendLog("状态检查失败：" + ex.Message);
        }
        finally { _refreshing = false; }
    }

    private async Task<string?> GetPulseAdapterAsync()
    {
        const string command = "@(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -match 'pulse|juniper|ivanti' -or $_.Name -match 'pulse|juniper' } | Where-Object Status -eq 'Up' | Select-Object -First 1).Name";
        var output = await RunPowerShellAsync(command);
        return string.IsNullOrWhiteSpace(output) ? null : output.Trim();
    }

    private bool ReadPulseIgnoreProxy()
    {
        foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
        {
            try
            {
                using var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view);
                using var key = baseKey.OpenSubKey(@"SOFTWARE\Pulse Secure\Pulse");
                if (Convert.ToInt32(key?.GetValue("IgnoreEndpointProxy", 0) ?? 0) == 1) return true;
            }
            catch { }
        }
        return false;
    }

    private async void StartAll_Click(object sender, RoutedEventArgs e) => await StartAllAsync();

    private async Task StartAllAsync()
    {
        try
        {
            if (!File.Exists(ClashExe)) throw new FileNotFoundException("找不到 Clash Verge", ClashExe);
            if (!File.Exists(PulseExe)) throw new FileNotFoundException("找不到 Ivanti/Pulse", PulseExe);

            if (!IsClashRunning())
            {
                Process.Start(new ProcessStartInfo(ClashExe) { UseShellExecute = true });
                AppendLog("已启动 Clash Verge");
                await Task.Delay(1200);
            }

            var watch = Path.Combine(_root, "watch-admin.cmd");
            if (File.Exists(watch))
            {
                Process.Start(new ProcessStartInfo(watch) { UseShellExecute = true, WorkingDirectory = _root });
                AppendLog("已启动管理员共存监视器（会弹出 UAC）");
                await Task.Delay(1200);
            }

            if (Process.GetProcessesByName("Pulse").Length == 0)
            {
                Process.Start(new ProcessStartInfo(PulseExe) { UseShellExecute = true });
                AppendLog("已启动 Ivanti Secure Access Client");
            }
            AppendLog("请在 Pulse 中连接北大 VPN并完成二次验证");
            await RefreshStatusAsync();
        }
        catch (Exception ex)
        {
            AppendLog("启动失败：" + ex.Message);
            MessageBox.Show(ex.Message, "启动失败", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void CloseEdge_Click(object sender, RoutedEventArgs e)
    {
        CloseEdgeProcesses();
        _ = RefreshStatusAsync();
    }

    private bool CloseEdgeProcesses()
    {
        var closed = true;
        foreach (var process in Process.GetProcessesByName("msedge"))
        {
            try { process.Kill(entireProcessTree: true); }
            catch (Exception ex)
            {
                closed = false;
                AppendLog("关闭 Edge 失败：" + ex.Message);
            }
        }

        foreach (var process in Process.GetProcessesByName("msedge"))
        {
            if (!process.WaitForExit(1500)) closed = false;
        }

        AppendLog(closed ? "已关闭 Edge" : "仍有个别 Edge 进程未关闭");
        return closed;
    }

    private async void RestoreEdge_Click(object sender, RoutedEventArgs e)
    {
        var result = MessageBox.Show("这会关闭 Edge、停止共存监视器、删除共存路由并恢复普通上网代理。继续吗？",
            "恢复普通 Edge", MessageBoxButton.YesNo, MessageBoxImage.Question);
        if (result != MessageBoxResult.Yes) return;

        var script = Path.Combine(_root, "restore-normal-network.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show($"恢复脚本不存在：{script}", "无法恢复", MessageBoxButton.OK, MessageBoxImage.Error);
            return;
        }

        try
        {
            var psi = new ProcessStartInfo("powershell.exe",
                $"-NoProfile -ExecutionPolicy Bypass -File \"{script}\" -NoPause")
            {
                UseShellExecute = true,
                Verb = "runas",
                WorkingDirectory = _root
            };

            using var process = Process.Start(psi)
                ?? throw new InvalidOperationException("无法启动恢复脚本。");
            AppendLog("正在等待恢复脚本完成...");
            await process.WaitForExitAsync();

            if (process.ExitCode != 0)
            {
                AppendLog($"恢复脚本失败，退出码 {process.ExitCode}");
                MessageBox.Show(
                    "恢复脚本未成功完成。Edge 将保持当前状态，请查看恢复窗口中的错误信息。",
                    "恢复失败",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
                return;
            }

            if (!CloseEdgeProcesses())
            {
                MessageBox.Show(
                    "网络已恢复，但部分 Edge 后台进程未能关闭。请从任务管理器结束 Edge 后重新打开。",
                    "Edge 未完全关闭",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
            if (File.Exists(EdgeExe))
                Process.Start(new ProcessStartInfo(EdgeExe) { UseShellExecute = true });
            AppendLog("已恢复普通 Edge；如需共存请再次点击一键启动");
        }
        catch (Win32Exception ex) when (ex.NativeErrorCode == 1223)
        {
            AppendLog("已取消管理员授权，未修改网络设置");
        }
        catch (Exception ex)
        {
            AppendLog("恢复普通 Edge 失败：" + ex.Message);
            MessageBox.Show(ex.Message, "恢复失败", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            await RefreshStatusAsync();
        }
    }

    private void Refresh_Click(object sender, RoutedEventArgs e) => _ = RefreshStatusAsync();

    private static bool IsClashRunning() =>
        Process.GetProcessesByName("clash-verge").Length > 0 ||
        Process.GetProcessesByName("verge-mihomo").Length > 0;

    private static string ResolveExecutable(string environmentVariable, params string[] candidates)
    {
        var configured = Environment.GetEnvironmentVariable(environmentVariable);
        if (!string.IsNullOrWhiteSpace(configured) && File.Exists(configured))
            return Path.GetFullPath(configured);

        foreach (var candidate in candidates)
        {
            if (!string.IsNullOrWhiteSpace(candidate) && File.Exists(candidate))
                return Path.GetFullPath(candidate);
        }

        return !string.IsNullOrWhiteSpace(configured) ? configured : candidates.FirstOrDefault() ?? "";
    }

    private void StartWithWindows_Changed(object sender, RoutedEventArgs e)
    {
        PersistStartupSettings();
    }

    private void AutoStartCoexist_Changed(object sender, RoutedEventArgs e)
    {
        PersistStartupSettings();
    }

    private void PersistStartupSettings()
    {
        if (_loading) return;

        if (AutoStartCoexistCheckBox.IsChecked == true)
            StartWithWindowsCheckBox.IsChecked = true;

        var enabled = StartWithWindowsCheckBox.IsChecked == true;
        var coexist = enabled && AutoStartCoexistCheckBox.IsChecked == true;
        _loading = true;
        if (!enabled) AutoStartCoexistCheckBox.IsChecked = false;
        _loading = false;

        try
        {
            SetRunValue(enabled, coexist);
        }
        catch (Exception ex)
        {
            AppendLog("保存开机启动设置失败：" + ex.Message);
            MessageBox.Show(ex.Message, "保存设置失败", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private static (bool Enabled, bool Coexist, bool NeedsMigration) ReadRunState()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        var legacyCoexist = key?.GetValue(LegacyRunCoexistName) is not null;
        if (key?.GetValue(RunName) is string configured)
        {
            var coexist = legacyCoexist ||
                configured.Contains("--startup-coexist", StringComparison.OrdinalIgnoreCase);
            return (true, coexist, legacyCoexist);
        }

        if (legacyCoexist)
            return (true, true, true);

        return (false, false, false);
    }

    private static void SetRunValue(bool enabled, bool coexist)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        key?.DeleteValue(LegacyRunCoexistName, false);
        if (!enabled)
        {
            key?.DeleteValue(RunName, false);
            return;
        }

        var exe = Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "PKUVpnManager.exe");
        var args = coexist ? " --startup-coexist" : string.Empty;
        key?.SetValue(RunName, $"\"{exe}\"{args}");
    }

    private async Task<string> RunPowerShellAsync(string command)
    {
        var utf8Command = "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; " + command;
        var psi = new ProcessStartInfo("powershell.exe", $"-NoProfile -ExecutionPolicy Bypass -Command \"{utf8Command.Replace("\"", "\\\"")}\"")
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8
        };
        using var process = Process.Start(psi)!;
        var output = await process.StandardOutput.ReadToEndAsync();
        await process.WaitForExitAsync();
        return output;
    }

    private void AppendLog(string message)
    {
        var line = $"[{DateTime.Now:HH:mm:ss}] {message}";
        LogTextBox.AppendText(line + Environment.NewLine);
        LogTextBox.ScrollToEnd();
    }
}
