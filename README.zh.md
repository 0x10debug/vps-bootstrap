# 一条命令安全加固你的 VPS

一条命令完成新 VPS 的初始化和生产级安全加固。更新系统、创建非 root 用户并配置 SSH 密钥、加固 SSH、配置防火墙、安装 CrowdSec 入侵防护、调优内核参数、启用自动安全更新、安装 Docker——一次搞定。适用于 Ubuntu、Debian 和 Alpine 服务器。

> **第一次接触 VPS 安全？** 这个工具自动应用行业标准加固配置。不需要读 50 页指南——运行 `mb init`，你的服务器几分钟内从裸机变成生产就绪。

## 为什么需要这个工具

拿到新 VPS 后，在安全运行生产服务之前需要做几件事：

1. **更新系统** — 修补已知漏洞
2. **创建非 root 用户** — 不要用 root 跑所有东西
3. **加固 SSH** — 禁用 root 登录、禁用密码认证、改端口
4. **开启防火墙** — 只暴露需要的端口
5. **安装入侵防护** — 自动封禁暴力破解
6. **调优内核** — 优化服务器工作负载（BBR、文件描述符、网络）
7. **启用自动更新** — 自动获取安全补丁
8. **安装 Docker** — 现代服务部署的基础

手动做这些需要 30-60 分钟，而且容易遗漏。这个工具一条命令搞定，有安全默认值，所有参数都可自定义。

## 功能

- **一条命令设置** — `mb init` 全部搞定，交互式或配置文件驱动
- **SSH 加固** — 禁用 root 登录、禁用密码认证、改端口、限制用户
- **防火墙** — UFW（Debian/Ubuntu）或 nftables（Alpine），默认只开 SSH/HTTP/HTTPS
- **CrowdSec 入侵防护** — fail2ban 的现代替代品，众包威胁情报
- **内核调优** — BBR 拥塞控制、提高文件描述符限制、优化网络栈
- **自动安全更新** — 自动安装安全补丁（Docker 除外，避免破坏运行中的容器）
- **Docker + Compose** — 从官方仓库安装，配置日志轮转
- **MOTD 仪表盘** — 每次登录看到系统状态、Docker 容器、CrowdSec 告警、待更新数
- **幂等** — 可安全重复运行，只应用未完成的变更
- **回滚** — 每次修改都备份，`mb rollback` 一键恢复
- **迁移** — 导出配置，应用到新服务器

## 快速开始

```bash
# 安装 mb
curl -fsSL https://raw.githubusercontent.com/0x10debug/vps-bootstrap/main/install.sh | bash

# 运行初始化向导（交互式，全模块，安全默认值）
mb init
```

就这么简单。回答问题（或接受默认值），服务器就加固好了。

## 用法

```bash
mb init                          # 交互式设置（全模块，安全默认值）
mb init --module system,ssh      # 只运行指定模块
mb init --config my-vps.yaml     # 声明式配置（无交互）
mb status                        # 查看加固状态
mb rollback ssh                  # 撤销 SSH 变更（或 'mb rollback all'）
mb export                        # 导出配置用于迁移
mb update                        # 更新 mb 并重新运行系统更新
mb help                          # 显示所有命令
```

## 模块

| 模块 | 功能 |
|---|---|
| `system` | 系统更新、基础工具、时区、主机名 |
| `user` | 非 root 用户、sudo、SSH 密钥 |
| `ssh` | SSH 加固（禁用 root、禁用密码、改端口） |
| `firewall` | UFW 或 nftables（拒绝入站，允许出站，开 SSH/HTTP/HTTPS） |
| `crowdsec` | CrowdSec 入侵防护：SSH/Web/端口扫描场景，防火墙/nginx/Cloudflare bouncer，auditd 日志联动，邮件与 webhook 告警 |
| `kernel` | BBR、文件描述符、网络栈调优 |
| `autoupdate` | 自动安全更新（Docker 除外） |
| `docker` | Docker Engine + Compose v2，配置日志轮转 |
| `motd` | 每次 SSH 登录显示状态仪表盘 |
| `cis_align` | CIS Benchmark v14.0 L1 对齐报告（只读审计） |
| `partition_check` | 分区隔离 + 挂载选项检查（只读） |
| `auditd` | auditd 安装 + 关键文件完整性监控 + 特权命令审计 |
| `apparmor` | AppArmor 强制访问控制：enforce 模式、profile 管理、关键服务覆盖审计 |
| `auto_updates` | 自动安全更新：unattended-upgrades（Debian）、dnf-automatic（RHEL）、apk cron（Alpine）；重启与邮件配置 |
| `tailscale` | Tailscale/Netbird 网状 VPN：安装、auth key 认证、exit node、Tailscale SSH、accept-routes、ACL 审计 |

## 配置

声明式（非交互）设置，使用配置文件：

```bash
mb init --config my-vps.yaml
```

示例配置：

```yaml
modules:
  system: true
  user: true
  ssh: true
  firewall: true
  crowdsec: true
  kernel: true
  autoupdate: true
  docker: true
  motd: true

timezone: "Asia/Shanghai"
username: "deploy"
ssh_port: "22222"
enable_bbr: true
docker_log_max_size: "50m"
```

完整选项见 `config/example.yaml`。预置配置：`config/default.yaml`（全模块）、`config/minimal.yaml`（仅基础）。

## 常见问题

### 如何在新 VPS 上加固 SSH？

运行 `mb init`——它会禁用 root 登录、禁用密码认证（如果你有 SSH 密钥）、改端口为非标准端口、限制可连接的用户。每个变更都有备份，可以用 `mb rollback ssh` 回滚。

### 如何在 Ubuntu 或 Debian 上配置防火墙？

`firewall` 模块用安全默认值配置 UFW：拒绝所有入站、允许出站、只开 SSH（你配置的端口）、HTTP（80）、HTTPS（443）。可通过配置开放额外端口。

### CrowdSec 和 fail2ban 哪个更好？

CrowdSec 是 fail2ban 的现代继任者。它使用众包威胁情报（一台服务器封禁的 IP 全球共享）、支持多层 bouncer（防火墙、Web 服务器、CDN）、可以检查 HTTP 流量。fail2ban 只读日志并在本地封禁 IP。mb 默认使用 CrowdSec。

### 如何在 VPS 上安全安装 Docker？

`docker` 模块从官方仓库安装 Docker Engine 和 Compose v2，配置日志轮转（防止磁盘撑满）、将非 root 用户加入 docker 组、不把 Docker daemon 暴露到网络。

### 如何为生产环境加固 VPS？

运行 `mb init` 启用所有模块。你会得到：更新后的系统、非 root 用户、加固的 SSH、活跃的防火墙、入侵防护、调优的内核、自动安全更新、就绪的 Docker、状态仪表盘。要更深入的审计，使用 [security-audit](https://github.com/0x10debug/security-audit)。

## 对比

| 功能 | mb | 手动设置 | 其他脚本 |
|---|---|---|---|
| 系统更新 | ✅ | 自己做 | 有时 |
| 非 root 用户 | ✅ | 自己做 | 有时 |
| SSH 加固 | ✅ | 自己做 | 通常 |
| 防火墙 | ✅ | 自己做 | 有时 |
| CrowdSec | ✅ | 自己装 | ❌（大多用 fail2ban） |
| 内核调优 | ✅ | 自己研究 | 很少 |
| 自动安全更新 | ✅ | 自己配 | 很少 |
| Docker | ✅ | 自己装 | 有时 |
| MOTD 仪表盘 | ✅ | ❌ | ❌ |
| 幂等 | ✅ | ❌ | 很少 |
| 回滚 | ✅ | ❌ | ❌ |
| 配置文件 | ✅ | ❌ | 很少 |

## 支持的操作系统

- Ubuntu 22.04+（推荐 LTS）
- Debian 12+
- Alpine 3.22+（模块支持有限）

## 文档

- [加固参考](docs/hardening-reference.md) — 每个参数的作用和原因
- [应急响应](docs/incident-response.md) — 服务器被入侵后的应对步骤
- [迁移指南](docs/migration.md) — 如何将配置迁移到新服务器

## 贡献

欢迎 Pull Request。重大变更请先开 Issue 讨论。

## 许可证

[MIT](./LICENSE)
