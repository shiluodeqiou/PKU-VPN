# PKU VPN + Clash 共存工具（Windows）

让 Pulse Secure / Ivanti 的北大 VPN 与 Clash Verge 同时工作，在访问校园资源和图书馆数据库时走北大隧道，同时保留 Clash 对 Google、GitHub、Codex 等站点的代理能力。

![PKU VPN 管理器](PKU%20VPN%20Manager/app-preview-v2.png)

本仓库只包含源码、脚本、配置模板和图标。运行日志、路由缓存、构建产物、发布包、本机订阅和个人路径不会提交到 Git。

## 快速开始

环境要求：

- Windows 10/11 x64；
- Clash Verge Rev；
- Pulse Secure 或 Ivanti Secure Access Client；
- 可选的桌面管理器需要 .NET 6 Desktop Runtime；自行发布时只需 .NET SDK 6。

1. 按本文第一节配置 Pulse Secure，按第二节把 [`clash/pku-direct.js`](./clash/pku-direct.js) 的内容放进 Clash Verge 的全局扩展脚本。
2. 双击 `start-pku-clash.cmd`。它会启动 Clash、请求管理员权限运行路由监视器，并启动 Pulse/Ivanti。
3. 在 Pulse/Ivanti 中连接北大的“全网”模式并完成二次验证。
4. 退出时双击 `restore-normal-network.cmd`，删除本项目添加的路由并恢复普通系统代理状态。

程序会优先读取以下环境变量：

| 环境变量 | 用途 |
| --- | --- |
| `PKU_CLASH_EXE` | `clash-verge.exe` 的完整路径 |
| `PKU_PULSE_EXE` | `Pulse.exe` 的完整路径 |
| `PKU_EDGE_EXE` | `msedge.exe` 的完整路径 |

未设置时会自动检查常见安装目录，以及仓库父目录下的 `Clash Verge` 文件夹。

构建桌面管理器：

```powershell
dotnet build '.\PKU VPN Manager\PKUVpnManager.csproj' -c Release
dotnet publish '.\PKU VPN Manager\PKUVpnManager.csproj' -c Release -r win-x64 `
  --self-contained true -p:PublishSingleFile=true `
  -p:IncludeNativeLibrariesForSelfExtract=true `
  -p:EnableCompressionInSingleFile=true `
  -o '.\dist\PKU-VPN-Manager'
```

发布包位于 `dist\PKU-VPN-Manager\PKUVpnManager.exe`，`dist` 默认不进入 Git。

---

## 先看结论

| 你的需求 | 用哪个 VPN 入口 | 与 Clash 的关系 |
| --- | --- | --- |
| 图书馆电子资源、知网、按校园 IP 授权的数据库（**你的场景**） | `vpn.pku.edu.cn`（全网模式） | VPN 接管默认路由：文献库必须走 `DIRECT`（见第 2 节），Clash 自己连机场节点需要按第 4 节绕过校园隧道 |
| 只访问校内业务系统（门户、教务、办公系统） | `pacvpn.pku.edu.cn`（北大内网模式） | **天然共存**，VPN 只接管校内网段，Clash 不用任何额外设置 |

建议让 Clash 使用系统代理模式，并关闭 TUN。Pulse 全网模式接管默认路由后，`pku-clash.ps1` 会给 Clash 所需的目标补充更具体的 `/32` 路由。

## 桌面管理器

项目包含一个 WPF 桌面管理器：

- 一键启动 Clash Verge、Pulse Secure 和共存监视器；
- Pulse、Clash、Edge 实时状态卡片；
- 开机自启动软件和开机自动启动共存模式；
- 关闭 Edge、恢复普通 Edge；
- 通过 UAC 调用已有共存与恢复脚本，避免把网络逻辑复制成两份。

管理器图标源文件为 `PKU VPN Manager\app-icon-v2.png`，并已生成包含
16–256 px 多尺寸帧的 `PKU VPN Manager\app-icon-v2.ico`，同时嵌入 EXE 和窗口标题栏。

仓库同时提供一份可直接粘贴到 Clash Verge 的全局扩展脚本，以及用于检测、修复、维持和回滚路由的 `pku-clash.ps1`。

---

## 原理（为什么全网模式会出问题）

```
全网模式连接后：

  App ──> 127.0.0.1:7897 (Clash) ──> 机场节点 IP
                                        │
                          默认路由被 Pulse 改成 VPN 隧道
                                        │
                                        ▼
                              北大校园网出口 ──> 机场节点

问题：Clash 到机场节点这一段也进了校园隧道。
```

Pulse Secure 全网模式会抢占默认路由（`0.0.0.0/0`），而 Clash 只是本地代理：App 到 `127.0.0.1:7897` 不受影响，但 Clash 自己连机场节点时仍按路由表走，于是被塞进校园隧道。

修复思路只有一句话：**给机场节点、DNS、VPN 登录服务器的 IP 各加一条 `/32` 明细路由，指向物理网关。** 因为路由匹配是「最长前缀优先」，`/32` 一定赢过 VPN 的默认路由，Clash 的出站就回到物理网卡；校内流量仍然走 Pulse 的校园路由。

---

## 一、配置 Pulse Secure

1. 打开 Pulse Secure（开始菜单里找「Pulse Secure」）。
2. 点左下角 `+` 添加连接，**建议两个都加**：
   - 名称 `PKU-全网`，URL：`https://vpn.pku.edu.cn`
   - 名称 `PKU-内网`，URL：`https://pacvpn.pku.edu.cn`
3. 连接时：
   - 用户名：IAAA 账号（学号）
   - 密码：IAAA 密码
   - 若提示 `Token Code` / 二次验证：输入**身份证号后六位**
     （部分账号会改成手机号第 4–7 位，以客户端提示为准）
4. 连上后任务栏图标变绿，`ipconfig` 里会多出一个 Pulse/Juniper 虚拟网卡。

> 新版官方客户端可能是 iSecSP（地址 `arrayvpn.pku.edu.cn`），但 Pulse Secure 目前仍能连上面两个地址，继续用 Pulse 即可。

---

## 二、Clash Verge 配置

保持当前设置即可：

- **系统代理：开**（`127.0.0.1:7897`）
- **TUN 模式：关**

将 [`clash/pku-direct.js`](./clash/pku-direct.js) 的全部内容粘贴到 Clash Verge 的**全局扩展脚本**：

`%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\profiles\Script.js`

```javascript
const pkuRules = [
  "DOMAIN-SUFFIX,vpn.pku.edu.cn,DIRECT",
  "DOMAIN-SUFFIX,pacvpn.pku.edu.cn,DIRECT",
  "DOMAIN-SUFFIX,arrayvpn.pku.edu.cn,DIRECT",
  "DOMAIN-SUFFIX,pku.edu.cn,DIRECT",
  "IP-CIDR,162.105.0.0/16,DIRECT,no-resolve",
  "IP-CIDR,222.29.0.0/16,DIRECT,no-resolve",
  "IP-CIDR,202.112.0.0/16,DIRECT,no-resolve",
  "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
  "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
];
```

脚本还会给 DNS 加上 `+.pku.edu.cn` 的 fake-ip 例外，并用系统解析器解析校内域名（连上 VPN 后就是校园 DNS）。

> Clash Verge 2.x 的「扩展配置 / Merge」里写 `prepend-rules` 会被静默忽略，所以这里使用扩展脚本。修改后需要重启 Clash Verge，或重新应用订阅。

规则作用：

- `vpn.pku.edu.cn` 等登录域名永远直连，**这是 TUN 模式能兼容 VPN 的前提**；
- `pku.edu.cn` 和校园网段不经过机场节点，交给系统路由（即 Pulse 隧道）。

生效后可以这样确认：

```powershell
Select-String -Path "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml" -Pattern "pku.edu.cn"
# 输出里应能看到 vpn.pku.edu.cn,DIRECT 等规则，以及 +.pku.edu.cn
```

### 看文献的关键：数据库域名必须 DIRECT

图书馆是按**校园 IP** 授权的。如果 Clash 把 `sciencedirect.com` 这类域名丢给机场节点，出版社看到的是境外节点 IP，认证就会失败（表现为要求登录/付费，或者只给摘要）。

所以扩展脚本里除了北大域名，还加了一份**学术出版社/数据库直连清单**（`academicRules`），它们全部 `DIRECT`，也就是经 Pulse 隧道、以校园 IP 出网：

- Elsevier / ScienceDirect、Springer / Nature、Wiley、Cell
- Taylor & Francis、SAGE、OUP、Cambridge
- IEEE Xplore、ACM
- JSTOR、EBSCO、ProQuest、Web of Science、Scopus
- APS、IOP、RSC、ACS、AMS、Annual Reviews
- 知网、万方、维普
- DOI、arXiv、PubMed、ResearchGate、Semantic Scholar

ScienceDirect 还会使用 Cloudflare 的验证主机。当前脚本只把已观察到的精确主机
`brunhild.challenges.cloudflare.com` 和 `sciencedirectassets.com` 设为 `DIRECT`，并保留其他 Cloudflare 域名的原有代理规则。这样 ScienceDirect 页面和验证请求使用同一个北大出口，同时不会把所有 Cloudflare 验证都切到直连，减少对 Codex 的影响。

如果你要用的库不在名单里，编辑 `Script.js` 的 `academicRules`，加一行再重启 Clash Verge：

```javascript
"DOMAIN-SUFFIX,你的数据库域名,DIRECT",
```

两个注意点：

1. Clash 必须保持**规则模式（Rule）**，不能用全局模式（Global），否则规则会被忽略。
2. Google Scholar 仍然走代理（国内直连不通）；但点进出版社的全文链接后会命中上面的 DIRECT 规则，用校园 IP 拿到全文，这个组合是正常的。

确认生效：重启 Clash Verge 后打开「连接」页，访问 `sciencedirect.com`；主页面应命中 `DOMAIN-SUFFIX,sciencedirect.com` / `DIRECT`，验证主机应命中 `DOMAIN,brunhild.challenges.cloudflare.com` / `DIRECT`。

---

## 三、Codex 的代理

如果使用 Clash 的系统代理，可在 `%USERPROFILE%\.codex\.env` 中设置：

```
HTTP_PROXY="http://127.0.0.1:7897"
HTTPS_PROXY="http://127.0.0.1:7897"
ALL_PROXY="socks5://127.0.0.1:7897"
```

如果 Codex 或本地转发器不读取这个文件，可以设置用户级环境变量，然后重启相关程序：

```powershell
[Environment]::SetEnvironmentVariable('HTTP_PROXY','http://127.0.0.1:7897','User')
[Environment]::SetEnvironmentVariable('HTTPS_PROXY','http://127.0.0.1:7897','User')
[Environment]::SetEnvironmentVariable('ALL_PROXY','socks5://127.0.0.1:7897','User')
[Environment]::SetEnvironmentVariable('NO_PROXY','localhost,127.0.0.1,::1,.pku.edu.cn,162.105.0.0/16,10.0.0.0/8','User')
```

撤销：

```powershell
foreach ($n in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY') {
  [Environment]::SetEnvironmentVariable($n,$null,'User')
}
```

> 注意：全局环境变量对所有新启动的程序生效。如果哪天不开 Clash，部分命令行工具会报连接失败，届时删掉即可。

---

## 四、全网模式下的关键一步：让 Clash 绕过校园隧道

### 0. 先连上 VPN，然后体检

```powershell
$ProjectRoot = (Get-Location).Path
pwsh -File "$ProjectRoot\pku-clash.ps1" status
```

输出里重点看 `Route check` 表的 `Pulse` 列：

- 全是 `False` → 已经正常，什么都不用做；
- 出现 `True` → 说明该 IP 正被塞进校园隧道，继续下一步。

同时脚本会顺便测试 Clash 到 ChatGPT / Google 的连通性。

### 1. 加绕过路由（需要管理员）

右键「Windows PowerShell」→「以管理员身份运行」，然后：

```powershell
pwsh -File "$ProjectRoot\pku-clash.ps1" apply
```

它会：

- 自动找到物理网卡和物理网关；
- 解析当前订阅里的**所有机场节点域名**、Clash 的 DoH DNS、以及 `vpn.pku.edu.cn` 等登录地址；
- 为每个 IP 添加 `x.x.x.x/32` 路由，指向物理网关，metric 1；
- 把结果记录到 `pku-clash-routes.json`，方便回滚。

修改订阅、机场换 IP 后，重新跑一次 `apply` 即可（脚本每次都会重新解析域名）。

### 2. 让监视脚本在连接前准备路由

请在 Pulse 尚未连接时启动监视脚本，再从 Pulse 客户端建立 VPN：

- 双击 `watch-admin.cmd`（会弹 UAC，同意即可）；或
- 管理员 PowerShell 里运行：

```powershell
Start-Process pwsh -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$ProjectRoot\pku-clash.ps1",'-Action','watch'
```

脚本会在 Pulse 虚拟网卡尚未启动时解析并添加路由；检测到 Pulse 网卡已经启动后，只检查代理，不再重写路由，避免触发 Pulse 的网络变化检测。日志在 `pku-clash.log`。

### 3. 回滚

```powershell
# 管理员
pwsh -File "$ProjectRoot\pku-clash.ps1" revert
```

只删除脚本自己加的 `/32` 路由，不会动 Pulse 的路由。

---

## 五、验证清单

连上 VPN、执行完 `apply` 后：

```powershell
# 1) Clash 到外网：期望 204
curl.exe -x http://127.0.0.1:7897 -s -o NUL -w "%{http_code}`n" https://www.google.com/generate_204

# 2) Codex/OpenAI 上游：期望有 HTTP 状态码（403/401 都算通，000 才算不通）
curl.exe -x http://127.0.0.1:7897 -s -o NUL -w "%{http_code}`n" https://chatgpt.com/backend-api/

# 3) 校内站点：期望 200/302
curl.exe -s -o NUL -w "%{http_code}`n" https://portal.pku.edu.cn/

# 4) 看某个节点 IP 实际走哪张网卡（IP 用 status 输出里的那个）
Find-NetRoute -RemoteIPAddress 18.166.177.228 | Format-Table InterfaceAlias,NextHop,DestinationPrefix
```

### 关于 TUN 模式（可选，不推荐首选）

系统代理模式已经满足 Codex 网页/CLI 的需求，TUN 只在这类情况下才需要：某个程序完全不认系统代理（部分游戏、Electron 旧版本、某些 CLI）。

如果一定要 TUN：

1. 规则顺序必须先 `vpn.pku.edu.cn → DIRECT`（第 2 节已经加好）；
2. **先开 Clash，再连 Pulse**；
3. 在 `profiles\Merge.yaml`（扩展配置）里追加隧道排除，`tun` 对象会被逐项合并：

```yaml
tun:
  route-exclude-address:
    - 222.29.159.224/32
    - 222.29.159.226/32
    - 162.105.0.0/16
    - 222.29.0.0/16
    - 10.0.0.0/8
    - 172.16.0.0/12
```

4. 仍然建议用 `watch` 维持路由，因为 Pulse 全网模式会重写默认路由。

TUN + Pulse 全网属于「两个程序都想当默认网关」，稳定性天然不如系统代理方案。能不开就不开。

---

## 六、常见问题

**连上十几秒就掉线、每次刷新网页都要重新输身份证号？**

这是 Pulse 自己走了 Clash 代理导致的。Pulse 日志里能看到：

```
attempting to get proxy settings for https://vpn.pku.edu.cn/
Got proxy 127.0.0.1:7897
Connecting to host 127.0.0.1:7897
...
received IVE fatal error string: agentd error
```

Pulse 把系统代理（Clash）当成了自己连网关的代理，隧道经过 HTTP 代理不稳定，网关约 10–20 秒后主动断开，重连时会话恢复失败，于是又弹二次验证。

已经做的修复：

1. 系统代理绕过列表加入了 `*.pku.edu.cn;pku.edu.cn;162.105.*;222.29.*;106.120.124.*;111.205.231.*`，Pulse 连 `vpn.pku.edu.cn` 时会直连；
2. `pku-clash.ps1 fixproxy` 会在需要时清掉 Pulse 连上后写入的 `instantproxy.pac`，把系统代理重新设回 Clash；如果系统代理已经正确，脚本不会重复刷新 WinINet。管理员运行 `apply/watch` 时还会设置 Ivanti 官方的 `IgnoreEndpointProxy=1`，让 Pulse 建立网关连接时忽略本机代理设置，避免 Clash/PAC 变化触发 Pulse 重连。

如果 `status` 里仍然显示 `last connection attempt used proxy 127.0.0.1`，管理员执行下面这段，让 Pulse **完全忽略**系统代理，然后托盘右键完全退出 Pulse 再重开：

```powershell
$paths = 'HKLM:\SOFTWARE\Pulse Secure\Pulse','HKLM:\SOFTWARE\WOW6432Node\Pulse Secure\Pulse'
foreach ($p in $paths) {
  New-Item -Path $p -Force | Out-Null
  New-ItemProperty -Path $p -Name IgnoreEndpointProxy -PropertyType DWord -Value 1 -Force | Out-Null
}
```

验证：

```powershell
pwsh -File "$ProjectRoot\pku-clash.ps1" status
# VPN proxy isolation 一节应显示：
#   bypass list  : pku.edu.cn is excluded from the system proxy (OK)
#   pulse log    : last connection attempt went direct (OK)
```

**断开 VPN 后上不了网？**

Pulse/openconnect 断开时可能残留路由或 DNS。最省事的修复：禁用再启用物理网卡。

```powershell
# 管理员
Restart-NetAdapter -Name '以太网'
```

**Clash 所有节点都超时？**

先看校园网认证是否通过：临时关掉系统代理，打开任意 http 网站看是否跳认证页。另外把 `its.pku.edu.cn`、`captive.apple.com` 保持在直连（本配置已覆盖 pku.edu.cn）。

**Pulse 一直连不上？**

- 确认 Clash 的 TUN 是关的；
- 换 `pacvpn.pku.edu.cn` 试；
- 确认二次验证输入的是**身份证号后六位**（以客户端提示为准）；
- 账号被锁定/密码问题时联系 `its.pku.edu.cn`。

**`apply` 之后 Clash 仍然不通？**

先再跑一次 `status`，确认表格里 `Pulse` 那一列已经是 `False`、`Via` 是物理网卡（`以太网`）。如果路由已经对了但还是不通，说明 Pulse 的驱动层在做强制重定向（部分 Ivanti 版本会这样）。这时有两条路：

1. 如果只需要校内业务系统，改用 `pacvpn.pku.edu.cn`（内网模式），冲突直接消失；
2. 必须用全网模式时，改用「openconnect + 本地 SOCKS」架构（参考文末 PKU-VPN 仓库），让 VPN 只服务显式走 SOCKS 的流量，而不是接管整机路由。

**`apply` 报 “Access is denied”**

没在管理员窗口里运行。右键 PowerShell →「以管理员身份运行」。

**连上 VPN 了，文献库还是提示登录/付费？**

按顺序查：

1. Clash 是不是**规则模式**（不是全局）；
2. Clash Verge「连接」页里，该数据库域名命中的是不是 `DIRECT`——如果是某个代理组，说明域名不在 `academicRules` 里，加一行再重启；
3. 浏览器有没有装会改代理的插件（SwitchyOmega 之类），以及有没有开 Clash 的 TUN；
4. 该库是否本来就要求单独登录（例如部分数据库需要在校内注册个人账号）。

**机场订阅更新失败**

订阅域名如果被 Clash 规则代理到境外，可能更新失败；本配置已经把机场域名交给 DNS 策略直连解析。若仍失败，先断开北大 VPN 更新一次订阅。

---

## 七、已知限制

- 路由行为与 Pulse/Ivanti、Clash Verge、网卡名称及驱动版本有关，升级网络客户端后应重新运行 `status`。
- 当前桌面管理器以 .NET 6 为目标框架。.NET 6 已结束官方支持，建议后续升级到当前 LTS，并用新版 SDK 构建。
- 自带脚本没有自动化测试；Windows 路由、代理注册表和 UAC 行为需要在实际环境验证。
- “恢复普通 Edge”依赖系统恢复脚本在固定等待时间内完成。若 UAC 被取消，管理器仍会尝试启动 Edge，因此需要手动检查网络状态。
- 本仓库当前未声明开源许可证；公开或允许他人再分发前应先补充合适的 `LICENSE`。

## 八、本目录文件

| 文件 | 作用 |
| --- | --- |
| `start-pku-clash.cmd` | 一键启动 Clash、管理员监视器和 Pulse/Ivanti |
| `restore-normal-network.cmd` | 恢复普通网络状态 |
| `PKU VPN Manager/` | WPF 共存管理器源码与图标 |
| `clash/pku-direct.js` | Clash Verge 全局扩展脚本模板 |
| `pku-clash.ps1` | 检测 / 加绕过路由 / 常驻维持 / 回滚 / 修复被 Pulse 顶掉的系统代理 |
| `watch-admin.cmd` | 双击以管理员身份启动 `watch` |

Clash 侧改动：`%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\profiles\Script.js`（全局扩展脚本）。建议修改前自行备份原文件。运行后生成的 `pku-clash-routes.json` 和 `pku-clash.log` 默认被 `.gitignore` 排除。

---

## 参考

- [STILatPKU/PKU-VPN](https://github.com/STILatPKU/PKU-VPN)：用 openconnect 连北大 VPN，实现 VPN + Clash 同时开启
- [zhuozhiyongde/PKU-VPN](https://github.com/zhuozhiyongde/PKU-VPN)：同思路的 macOS 脚本
- [PKUfudawei/pkuvpn](https://github.com/PKUfudawei/pkuvpn)：原始 openconnect 方案
- [arthals：PKU VPN 2 - 真正实现 PKU VPN 和 Clash 兼容使用](https://arthals.ink/blog/pku-vpn-perfect)：`vpn.pku.edu.cn → DIRECT` 规则顺序的出处
- [北大计算中心 VPN 服务说明](https://its.pku.edu.cn/service_1_vpn.jsp)
