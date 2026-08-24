<div align="center">

# JQ's Proxy Stack Manager

**一站式 Linux 代理服务器管理工具 · Xray / sing-box / mihomo 三内核**

<p>
  <img src="https://img.shields.io/badge/Platform-Linux-1793D1?logo=linux&logoColor=white" alt="Platform">
  <img src="https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white" alt="Bash">
  <img src="https://img.shields.io/badge/Arch-x86__64%20%C2%B7%20arm64-FF8C00" alt="Arch">
  <img src="https://img.shields.io/badge/License-AGPL--3.0-blue" alt="License">
  <img src="https://img.shields.io/github/stars/jinqians/proxy-stack?style=flat&logo=github&color=yellow" alt="Stars">
</p>

<p>
  <b>简体中文</b> ·
  <a href="README_EN.md">English</a> ·
  <a href="README_KO.md">한국어</a> ·
  <a href="README_RU.md">Русский</a>
</p>

</div>

```
       _    ___          ____    ____    __  __
      | |  / _ \        |  _ \  / ___| |  \/  |
   _  | | | | | |       | |_) | \___ \ | |\/| |
  | |_| | | |_| |       |  __/   ___) | | |  | |
   \___/   \__\_|       |_|     |____/ |_|  |_|

  Proxy Stack Manager  ·····  ◆ jinqians.com
  ──────────────────────────────────────────
  IP    ▶  x.x.x.x              Nginx     ▶  1.x.x
  Xray  ▶  x.x.x                Hysteria2 ▶  2.x.x
  Sing-box ▶  x.x.x             Mihomo    ▶  v1.x.x
  ──────────────────────────────────────────
```

---

## 简介

**Proxy Stack Manager（PSM）** 是一套基于 Bash 的 Linux 代理服务器一站式管理工具，通过 `psm` 命令一键安装 VLESS Reality / Vision / XHTTP、Shadowsocks、Hysteria2、Snell、AnyTLS 等多种代理协议，内置 **Xray、sing-box 与 mihomo（Clash.Meta）三内核**，并统一管理 Nginx、SSL 证书、realm 中转转发、节点流量监控与 Telegram Bot 通知、VPS 安全防护、Docker 应用、Cloudflare 服务等。

每个节点都能自动生成密钥对，导出分享链接与二维码，支持 Clash Meta / Shadowrocket / Surge 配置导出；证书通过 acme.sh 自动签发续期，无需手动操作。多个协议节点还可以共用同一个 443 端口对外呈现（详见下文）。

界面支持 **简体中文 / English / 한국어 / Русский** 四种语言：安装时选择，主菜单里随时切换。

### 为什么选择 PSM

- **一条命令进入完整管理菜单**：安装后只需要运行 `psm`，所有功能都在同一个 CLI 菜单内
- **三内核可选**：Xray、sing-box、mihomo 三套内核并行管理，协议入站、路由分流、出站节点各自独立配置，互不干扰
- **多协议统一管理**：Reality / Vision / XHTTP / Hysteria2 / Snell / SS2022 / AnyTLS 可以共存，不需要每个协议维护一套脚本
- **适合长期维护的 VPS**：不是一次性安装脚本，而是把更新、备份、恢复、服务状态和安全加固放到同一套工具里
- **四语言界面**：中 / 英 / 韩 / 俄随时切换，`PSM_LANG=en psm` 可临时覆盖
- **透明可审计**：项目主体是 Bash 脚本，安装目录固定在 `/opt/psm`，系统写入路径在文档中明确列出

---

## 443 端口复用

多个协议节点可以共用同一个公网 443 端口对外呈现——不需要为每个协议 / 每个域名单独开一个端口。原理是 Nginx `stream` 层的 `ssl_preread`：在不解密流量的前提下读出 TLS ClientHello 里的 SNI（客户端要访问的域名），再按域名分发给对应的后端。

```mermaid
flowchart TD
    A(["客户端连接 443/TCP"]) --> B["Nginx stream 层<br/>ssl_preread 读取 SNI（不解密）"]

    B -->|"SNI = a.example.com"| C1["Reality 节点 1<br/>127.0.0.1:1443"]
    B -->|"SNI = b.example.com"| C2["Reality 节点 2<br/>127.0.0.1:1444"]
    B -->|"SNI = c.example.com"| D["Vision 节点<br/>127.0.0.1:1445"]
    B -->|"SNI = d.example.com"| E["XHTTP 节点<br/>127.0.0.1:1446"]
    B -->|"SNI 未匹配任何节点"| F["HTTPS 伪装站点<br/>127.0.0.1:8443"]

    G(["客户端连接 443/UDP"]) --> H["Hysteria2<br/>独立 QUIC 监听，互不冲突"]
```

带来的好处：

- **对外只暴露一个端口**：防火墙只需放行 443，减少可被扫描到的攻击面
- **一台机器多个身份**：不同协议节点、以及给 GFW 探测看的伪装网站，可以同时挂在 443 上，靠域名区分，互不干扰
- **一个节点多个租户**：不需要为每个用户单独开一个端口/一套密钥，同一个 SNI 下的多个 UUID 共享入口，各自流量独立计费
- **UDP 443 独立复用**：Hysteria2 走的是 UDP，和上面的 TCP 分流是两个独立的监听栈，端口号相同也不会冲突

> **三内核统一**：Xray 的 Reality / Vision / XHTTP，以及 sing-box、mihomo 的 Reality / AnyTLS 节点都可以挂到同一个 443 端口上，共用这张 SNI 分流表；跨内核若使用相同伪装域名会被自动检测并拦截，避免路由冲突。

---

## 如何使用

### 一键安装

以 root 身份在 VPS 上执行，自动安装至 `/opt/psm` 并注册 `psm` 命令：

```bash
# 使用 curl（推荐）
bash <(curl -fsSL https://psm.jinqians.com)

# 使用 wget（系统未安装 curl 时）
bash <(wget -qO- https://psm.jinqians.com)
```

> 已完整安装的机器上重复执行同一命令，会自动 `git pull` 更新；如果检测到旧版卸载遗留的半安装状态，会自动重新运行安装流程修复。

安装完成后，随时输入：

```bash
psm
```

进入交互式主菜单。

### 手动安装

```bash
git clone https://github.com/jinqians/proxy-stack.git /opt/psm
bash /opt/psm/install.sh
```

### 系统要求

| 发行版                  | 最低支持版本       |
| ----------------------- | ------------------ |
| Ubuntu                  | 20.04 LTS 及以上   |
| Debian                  | 10 (Buster) 及以上 |
| CentOS / RHEL           | 8 及以上           |
| Rocky Linux / AlmaLinux | 8 及以上           |
| Oracle Linux            | 8 及以上           |
| Amazon Linux            | 2 及以上           |
| Fedora                  | 较新的受支持版本   |

> 未在此列表内、或版本更低的系统（如 CentOS 7、Debian 9、Ubuntu 18.04 及更早）未做适配和测试，不保证可用。

| 项目     | 要求                                                                 |
| -------- | -------------------------------------------------------------------- |
| 运行权限 | root                                                                 |
| 系统架构 | x86_64 · arm64                                                      |
| 基础依赖 | `curl` 或 `wget`（预装其一即可）· `git`（bootstrap 自动安装） |

其余依赖（`jq`、`openssl`、`qrencode`、`unzip`、`iptables`、`fail2ban` 等）在各功能模块首次使用时按需自动安装。

### 主菜单

```
══════════════════════════════════════════════════════════════
                  JQ's Proxy Stack Manager
══════════════════════════════════════════════════════════════
   1. 系统管理              12. 中转管理 (realm)
   2. sing-box 管理         13. Cloudflare DDNS
   3. mihomo 内核           14. Docker 管理
   4. Xray 管理             15. 流量管理
   5. Snell 管理            16. Telegram Bot
   6. ss-rust 管理          17. 备份管理
   7. Hysteria2 管理        18. 恢复备份
   8. Nginx 管理            19. 更新 PSM
   9. 网站管理              20. 安全加固
  10. SSL 证书管理          21. 语言 / Language
  11. 查看所有节点
──────────────────────────────────────────────────────────────
   0. 退出
══════════════════════════════════════════════════════════════
```

### 非交互模式（用于 cron / systemd timer）

```bash
manager.sh --ddns-update           # 执行一次 Cloudflare DDNS 更新
manager.sh --backup-full           # 执行一次全量备份
manager.sh --backup-quick [标签]   # 执行一次快速备份
manager.sh --update                # 更新 PSM 脚本和组件
manager.sh --traffic-check         # 执行一次流量统计检查
manager.sh --tgbot                 # 启动 Telegram Bot 守护进程
manager.sh --reality-watchdog      # 执行一次 Reality 伪装目标测活
manager.sh --vpngate-watchdog      # 检查一次 VPNGate 免费家宽隧道，掉线时自动换节点
manager.sh --ruleset-update        # 更新一次订阅式规则集（Xray 侧内容变化时会重启）
manager.sh --honeypot-alert <ip> <port>  # 蜜罐命中告警（由 fail2ban 调用）
manager.sh --health-report         # 发送一次每日体检报告
```

这些都是各自功能模块背后的定时任务真正调用的入口，菜单里对应的"启用定时任务"选项会自动帮你注册好，不需要手动配置 cron。

### 诊断与节点自动化 CLI

```bash
psm doctor                         # 只读系统与配置诊断
psm doctor --json                  # 结构化 JSON 报告

psm node list --json               # 列出三内核的全部节点
psm node show xray reality node-1 --json
psm node add xray reality --tag node-1 --port 24443
psm node update xray reality node-1 --port 25443
psm node export xray reality node-1 --server 203.0.113.10
psm node delete xray reality node-1 --yes
```

节点 CLI 覆盖 Xray、sing-box 和 mihomo 的 14 类存储型节点，支持 JSON 输入、字段更新、默认密钥脱敏、并发锁、端口冲突检查和应用失败回滚。详细命令参数运行 `psm node help`。

### 卸载

```bash
bash /opt/psm/uninstall.sh
```

卸载器会清理 PSM 自身创建的快捷命令、cron、systemd timer/service、PSM 防火墙/Fail2ban 规则，并默认询问是否删除 `/opt/psm` 程序目录及其中配置状态。Nginx、Xray、sing-box、mihomo、Hysteria2、Snell、ss-rust、acme.sh、证书和 Docker Compose 应用等组件会逐一确认，避免误删你手动维护的系统服务。

---

## 项目功能特性

### Xray 内核

- **Xray** — Reality / Vision / XHTTP / SS2022，多节点管理，自动生成密钥对，导出 VLESS URI（含二维码）/ Clash Meta / Sing-box
- **Reality 多目标自动测活切换** — 为伪装目标配置多个候选 SNI，定期做真实 TLS 1.3 握手检测，挂了自动切换，旧客户端链接依然有效
- **Reality 伪装域名智能发现** — 配置 Reality / XHTTP 伪装 SNI 时，可通过网络空间测绘引擎（Netlas / Quake / ZoomEye / FOFA，用你自己的 API Key，免费额度即可）自动发现与本机 **同 ASN / 同机房** 的真实 TLS 1.3 站点作为伪装目标：就近、冷门、避开被教程用烂的大厂域名。候选会在本地逐个做真实握手校验（TLS 1.3 / X25519 / 证书匹配）后才采用，并可一键批量加入上面的测活候选池。**全程不做本机端口扫描**（避免触发服务商 abuse），发现由测绘引擎的数据集完成；未配置引擎时回退为手动输入
- **Cloudflare WARP 出站解锁** — 一键注册 WARP 身份并接入 Xray 出站，配合分流规则把 Netflix / OpenAI 等域名的流量导到 WARP
- **VPNGate 免费家宽 IP 出口** — 从 VPNGate 公开名单里筛出真正的住宅宽带 IP（ip-api 批量判定归属，剔除机房与 VPNGate 自营中继），用 openvpn 拉一条独立隧道，再以打 fwmark 的出站接进分流规则：Netflix / ChatGPT 这类按 IP 归属判风控的服务看到的是家宽出口，而机器自身的默认出网与 SSH 全程不受影响（隧道只写独立路由表，绝不碰主表）。隧道断开时命中规则的流量直接失败而不是漏回机房 IP，国家由你从名单里挑（列出真正有节点的国家和各自节点数），节点挂掉后自动在**同一个国家内**故障转移，出口国不会悄悄漂走；同一条隧道被 Xray / sing-box / mihomo 共用，换家宽 IP 时三个核心的配置一个字都不用改
- **规则集分流（订阅式）** — 贴一个社区规则表 URL（如 OpenAI.list）并选一个出口，该表描述的流量就从这个出口走。Xray 没有规则集机制，规则会内联展开进 `config.json`（域名与 IP 拆成两条规则——同一条里是 AND 语义，合并写会让规则永远不触发），也因此是三核里唯一需要重启才能生效的；每日自动更新只在内容真的变了时才重建重启
- **出站分流** — 自定义出站节点（VLESS-Reality / TLS / XHTTP、Shadowsocks、Trojan、SOCKS5），按域名 / GeoIP / GeoSite 规则转发到指定出站

### sing-box 内核（第二内核）

- **与 Xray 并行的完整协议栈** — VLESS Reality、SS2022、Hysteria2、AnyTLS（需 sing-box 1.12+）、Snell（需 sing-box 1.14+）多协议入站共用一个内核与配置文件
- **Xray 稳定版 / 预览版双通道** — XTLS 自 v26.3.27 起把每个发布都标成 prerelease，稳定通道可能落后数月，预览通道可取最新构建。选预览版时会明确提示：v26.4.13 起 REALITY 默认拒绝内核老于 v26.3.27 的客户端（含不少手机 App 内置内核），可在 Reality 菜单「客户端最低内核版本」按节点放宽
- **稳定版 / 预览版双通道** — 安装与升级时可选内核通道。默认稳定版；预览版装最新 beta/rc，用于上游尚未转正的协议（如 Snell 入站需 1.14+，而 1.14 目前仍是 beta）。已配置 Snell 节点时切回稳定版会被拦截并提示，避免配置校验失败导致服务起不来
- **路由分流管理** — geosite / geoip / 域名后缀 / IP CIDR / 入站标签 → 指定出站或拦截，内置一键去广告、禁 QUIC 预设
- **出站节点管理** — ss / vless-reality / vless-tls / trojan / socks / anytls / snell / hysteria2（Salamander 混淆）/ tuic 共 10 种出站类型
- **WARP 出站** — 复用 Xray 侧注册的 WARP 账户，一键接入 WireGuard endpoint
- **规则集分流（订阅式）** — 贴一个社区规则表 URL（如 OpenAI.list）并选一个出口，该表描述的流量就从这个出口走。走原生 `rule_set`（本地 source 文件，1.10+ 内核自己重载），刷新不重启、不断连。应用前先出体检报告：可用条数、被丢弃的客户端专用类型（PROCESS-NAME 等）一律明说；更新时比对条数，暴涨暴跌拦下来要人工确认
- **VPNGate 免费家宽出口** — 与 Xray 共用同一条家宽隧道，出站是 `direct` + `routing_mark`，换节点无需改配置（sing-box 1.12+ 自动改用 `domain_resolver` 锁 IPv4）
- **443 端口复用** — Reality 与 AnyTLS 节点可挂到 Nginx 443 SNI 分流，与 Xray / mihomo 节点共用公网 443，客户端只需连 443；也可继续直连独占端口
- **事务化配置变更** — 每次变更前自动备份，`sing-box check` 校验失败自动回滚配置与节点存储，不会留下坏配置导致服务起不来

### mihomo 内核（第三内核）

- **Clash.Meta 生态接入** — VLESS Reality、SS2022、Hysteria2、AnyTLS、Snell v4/v5 多协议入站共用 `/etc/mihomo/config.yaml`
- **Clash 规则分流** — 直接管理 `proxies` / `proxy-groups` / `rules`，支持 DOMAIN-SUFFIX / DOMAIN-KEYWORD / GEOSITE / GEOIP / IP-CIDR / IN-NAME，并固定兜底 `MATCH,DIRECT`
- **出站节点管理** — ss / vless-reality / vless-tls / trojan / socks5 / anytls / snell / hysteria2 / tuic / wireguard 等出站类型
- **WARP 出站复用** — 复用 Xray 侧注册的 WARP 账户，生成 mihomo wireguard proxy
- **规则集分流（订阅式）** — 同上，mihomo 侧直接生成原生 `rule-providers`，URL 交给内核自己按 interval 刷新；规则表里的 `IP-ASN` 这类只有 mihomo 支持的类型也能吃到
- **VPNGate 免费家宽出口** — 与 Xray 共用同一条家宽隧道，生成 `type: direct` + `routing-mark` + `ip-version: ipv4` 的代理，换节点无需改配置
- **443 端口复用** — Reality 与 AnyTLS 节点可挂到 Nginx 443 SNI 分流，与 Xray / sing-box 节点共用公网 443，客户端只需连 443；也可继续直连独占端口
- **事务化配置变更** — 每次变更都会重建配置并执行 `mihomo -t -d /etc/mihomo -f /etc/mihomo/config.yaml`，校验失败自动回滚，不影响正在运行的旧配置

### 独立协议与中转

- **Hysteria2** — UDP 代理，密码认证，带宽限制，masquerade 伪装
- **Snell** — v4 / v5 / v6，PSK 认证，Surge 格式导出
- **SS 2022** — shadowsocks-rust 独立部署，`ss://` URI 导出（含二维码）
- **realm 中转** — TCP / UDP 端口转发规则管理（中转机 → 落地机），中转服务器状态可通过 Telegram 推送报告

### 基础服务

- **Nginx** — SNI 多协议分流，站点管理，HTTPS 伪装站点
- **SSL 证书** — acme.sh 自动签发（HTTP-01 / DNS-01 通配符），自动续期
- **Cloudflare** — DDNS 动态更新、DNS 记录管理、DNS-01 通配符证书
- **Cloudflare Tunnel** — 免开放任何端口，把本机服务（Docker 应用、管理面板等）暴露到指定域名
- **Cloudflare Access** — 在 Tunnel/Nginx 暴露的域名前加一层邮箱验证门禁，专门用于保护 Portainer、Nginx Proxy Manager 这类管理类应用
- **Docker** — 安装管理、一键应用商店（Portainer / Uptime Kuma / Netdata / AdGuard Home / Vaultwarden / Alist 等）、部署前端口冲突检测、暴露方式可选（仅本机 / 直接公网 / Nginx 反代 / Cloudflare Tunnel）、数据卷纳入备份

### 安全加固

- **SSH 安全加固** — 一键切换密钥登录、禁用密码认证、更改监听端口；所有高风险改动都通过 `reload`（不掐断当前会话）应用，并带 5 分钟自动回滚保护，不确认就自动撤销，避免把自己锁在门外
- **Fail2ban 防爆破** — SSH 登录失败自动封禁，内置"惯犯"规则对多次被封的 IP 施以更长封禁，支持 IP 白名单
- **蜜罐诱捕** — 在 RDP / MSSQL / Telnet 等本机不该有服务的端口设置陷阱，一旦被连接即视为踩点扫描，自动永久封禁并推送 Telegram 告警；端口占用检测会自动排除 SSH、已配置的代理协议、Docker 服务等，不会误伤正常服务

### 运维监控

- **流量管理** — 覆盖 Xray / sing-box / mihomo 三内核节点，按节点设置月度流量配额，达阈值自动暂停并推送 Telegram 提醒，每分钟统计，月末自动重置
- **到期管理** — 按节点设置到期时间，临期 / 到期自动提醒并暂停服务，支持一键续费
- **每日体检报告** — 定时通过 Telegram 推送一份汇总报告：核心服务运行状态（Xray / sing-box / mihomo / Nginx 等）、流量预警、到期提醒、Reality 测活切换记录、SSH/BBR/Fail2ban/蜜罐/WARP 状态，一条消息看全貌
- **Telegram Bot** — 查询节点流量、管理用户绑定、到期续费、体检报告，全部可在 Telegram 内完成，无需登录服务器
- **备份与恢复** — 全量 / 选择性备份（含 Docker 数据卷），定时备份，一键恢复
- **系统管理** — BBR 拥塞控制、sysctl 网络调优、防火墙、DNS、时区、VPS 常用测试工具（本机体检、延迟/路由、NodeQuality、YABS、IP.Check.Place、RegionRestrictionCheck、bench.sh、LemonBench）
- **多语言界面** — 简体中文 / English / 한국어 / Русский，安装时选择、菜单随时切换，全部 2000+ 条界面文案完整翻译

---

## 目录结构

```
/opt/psm/
├── bootstrap.sh          # 一键安装入口
├── manager.sh            # 主入口（交互菜单 + 非交互调用）
├── install.sh            # 首次安装向导
├── update.sh             # 自更新和组件升级
├── uninstall.sh          # 引导式卸载
├── config/               # 运行时状态与配置（gitignore）
├── lang/                 # 语言表（zh / en / ko / ru）
├── lib/
│   ├── common.sh         # 公共工具函数
│   ├── i18n.sh           # 多语言框架
│   ├── xray/             # Reality / Vision / XHTTP / SS2022 / WARP / 出站分流 / 测活 / 伪装域名发现
│   ├── singbox/          # sing-box 第二内核（Reality / SS2022 / Hysteria2 / AnyTLS / Snell / 路由分流）
│   ├── mihomo/           # mihomo 第三内核（Reality / SS2022 / Hysteria2 / AnyTLS / Snell / 路由分流）
│   ├── vpngate/          # VPNGate 免费家宽 IP 出口（名单获取 / 家宽判定 / openvpn 隧道 / 三核接入）
│   ├── ruleset/          # 订阅式规则集（拉取 / 解析 / 体检 / 落地到 sing-box、mihomo）
│   ├── security/         # SSH 加固 / Fail2ban / 蜜罐
│   ├── cloudflare/       # Tunnel / Access
│   ├── docker/           # 数据卷备份等 Docker 扩展
│   ├── tgbot/            # Telegram 通知模板 / 每日体检报告 / 中转状态
│   ├── expiry/           # 到期管理
│   ├── hysteria2.sh / snell.sh / ssrust.sh / realm.sh
│   ├── nginx.sh / cert.sh / cloudflare.sh
│   ├── docker.sh / system.sh / vps_test.sh / backup.sh / traffic.sh
│   └── tg_bot.sh
├── scripts/              # 开发辅助脚本（i18n 校验等）
├── templates/            # 配置模板（含 Docker 应用商店模板）
└── backup/               # 备份归档
```

---

## 写入路径

PSM 会尽量把项目自身状态集中在 `/opt/psm`，但部分功能需要写入系统服务、证书、防火墙或应用配置。常见路径如下：

| 路径                                                                        | 用途                                                 |
| --------------------------------------------------------------------------- | ---------------------------------------------------- |
| `/opt/psm`                                                                | PSM 程序、运行状态、配置、备份和 Docker Compose 项目 |
| `/usr/local/bin/psm`                                                      | 全局快捷命令                                         |
| `/etc/systemd/system/psm-*.service` / `/etc/systemd/system/psm-*.timer` | PSM 定时任务和守护服务                               |
| `/usr/local/etc/xray` / `/usr/local/bin/xray`                           | Xray 配置和二进制                                    |
| `/etc/sing-box` / `/usr/local/bin/sing-box`                             | sing-box 配置和二进制                                |
| `/etc/hysteria` / `/usr/local/bin/hysteria`                             | Hysteria2 配置和二进制                               |
| `/etc/realm` / `/usr/local/bin/realm`                                   | realm 中转配置和二进制                               |
| `/etc/nginx`                                                              | Nginx 站点、stream 分流和 SSL 文件                   |
| `/root/.acme.sh`                                                          | acme.sh 账户和证书签发缓存                           |
| `/etc/fail2ban` / `iptables`                                            | Fail2ban 规则、蜜罐和流量统计链                      |
| `/etc/cron.d/psm-*`                                                       | 备份、DDNS 等 cron 入口                              |

如果你准备在生产 VPS 上使用，建议先阅读安装输出和卸载提示；如果机器上已有重要 Nginx、Docker 或 Cloudflare Tunnel 配置，先做快照或手动备份。

---

## 常见问题

### 如何切换界面语言？

主菜单选择「21. 语言 / Language」，即可在 简体中文 / English / 한국어 / Русский 之间切换并持久保存；也可以用 `PSM_LANG=en psm` 只对当次会话临时覆盖。

### 重复执行一键安装会怎样？

如果 `/opt/psm` 已是完整安装，脚本会执行 `git pull` 更新。若检测到旧版卸载后残留的半安装状态（例如 `.git` 还在但 `psm` 命令或配置目录缺失），会自动重新运行安装流程修复。

### Xray、sing-box 和 mihomo 有什么区别？该用哪个？

三者是并行的独立内核：Xray 侧功能最全（测活、伪装域名发现、流量统计等），sing-box 侧协议覆盖更广（AnyTLS、原生 Snell 入站等）且路由配置更现代，mihomo 侧适合 Clash.Meta 生态、规则分流（`proxies` / `proxy-groups` / `rules`）以及需要直接生成 Clash 配置的场景。可以只用其一，也可以同时运行，各自管理各自的端口和节点。

### 卸载后为什么还能选择保留某些组件？

Nginx、Docker、证书、Cloudflare Tunnel 等可能被其他站点或服务共用。PSM 的卸载器会默认清理 PSM 自身痕迹，并对共享组件逐一确认。

### 日志里出现「REALITY: Listening on non-443 ports」警告，要紧吗？

在 443 端口复用模式下不要紧，这是预期内的。Xray 从 v26.3.27 起会对监听非 443 端口的 REALITY 入站发这条警告，因为直连场景下非 443 端口确实更容易被 GFW 识别。但 PSM 的端口复用模式里，节点监听的是 `127.0.0.1` 上的回环端口（如 1443、2443），由 Nginx 在公网 443 上按 SNI 分流转发过来——**对外暴露的端口就是 443**，警告针对的风险并不成立。

如果节点没有挂在 Nginx 443 分流上，而是直接监听公网非 443 端口，那这条警告就是有效提醒，建议改用 443 或挂到端口复用上。

同版本还可能出现另外两条 REALITY 警告：伪装目标含 `apple` / `icloud` / `microsoft` 或 `.cn` / `.ru` / `.ir` 后缀时提示封禁风险（换个伪装域名即可），以及 v26.4.13 起提示默认最低客户端内核版本（见上文 Xray 内核一节）。

### 会不会覆盖现有 Nginx 配置？

PSM 会管理自己的站点和 stream 分流配置。已有生产站点建议先备份 `/etc/nginx`，并在菜单操作前确认域名、端口和证书路径。

### 支持非 root 用户安装吗？

不支持。PSM 需要安装系统包、写入 systemd、管理 Nginx、证书、防火墙和代理服务，因此必须使用 root。

### 适合多服务器集中管理吗？

当前 PSM 以单台 VPS 本地管理为主，暂不支持多服务器集中面板、状态同步或远程编排。realm 中转可以在多台机器间做流量转发，但各机器仍是独立管理。

---

## 项目资料

- [English README](README_EN.md) · [한국어 README](README_KO.md) · [Русский README](README_RU.md)
- [变更日志](CHANGELOG.md)

---

## 捐赠

如果这个项目对你有帮助，欢迎请作者喝杯咖啡 ☕️——支持 USDT 打赏。

| 网络              | 扫码捐赠 | 地址                                           |
| ----------------- | -------- | ---------------------------------------------- |
| **TRC20**   |          | `TUe1x22n9FPAgLt6YFcQyxWgvTZFNgKBgM`         |
| **Polygon** |          | `0x5632f6d76a03543c53d750918c9c6a4c372f1597` |

感谢每一位支持者！

---

## 许可证

本项目采用 [GNU Affero General Public License v3.0 (AGPL-3.0)](LICENSE) 开源协议。
