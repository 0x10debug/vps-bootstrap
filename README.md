# Secure Your VPS in One Command

A single command to initialize a fresh VPS and harden it for production. Updates the system, creates a non-root user with SSH keys, hardens SSH, configures a firewall, installs CrowdSec intrusion prevention, tunes kernel parameters, enables automatic security updates, and installs Docker — all in one run. Built for Ubuntu, Debian, and Alpine servers.

> **New to VPS security?** This tool applies industry-standard hardening automatically. No need to read a 50-page guide — just run `mb init` and your server goes from bare OS to production-ready in minutes.

## Why This Exists

When you get a fresh VPS, you need to do several things before it's safe to run production services:

1. **Update the system** — patch known vulnerabilities
2. **Create a non-root user** — don't run everything as root
3. **Harden SSH** — disable root login, disable password auth, change the port
4. **Enable a firewall** — only expose ports you actually need
5. **Install intrusion prevention** — block brute-force attacks automatically
6. **Tune the kernel** — optimize for server workloads (BBR, file descriptors, network)
7. **Enable auto-updates** — get security patches automatically
8. **Install Docker** — the foundation for modern service deployment

Doing all of this manually takes 30-60 minutes and it's easy to miss something. This tool does it all in one command, with safe defaults and the ability to customize everything.

## Features

- **One-command setup** — `mb init` does everything, interactively or from config file
- **SSH hardening** — disables root login, disables password auth, changes port, limits users
- **Firewall** — UFW (Debian/Ubuntu) or nftables (Alpine), only SSH/HTTP/HTTPS open by default
- **CrowdSec intrusion prevention** — modern replacement for fail2ban with crowdsourced threat intelligence
- **Kernel tuning** — BBR congestion control, raised file descriptor limits, optimized network stack
- **Automatic security updates** — security patches applied automatically (Docker excluded to prevent breakage)
- **Docker + Compose** — installed from official repositories, with log rotation configured
- **MOTD dashboard** — see system status, Docker containers, CrowdSec alerts, and pending updates every time you log in
- **Idempotent** — safe to run multiple times; only applies changes that aren't already done
- **Rollback** — every change is backed up; revert with `mb rollback`
- **Migration** — export your configuration and apply it to a new server

## Quick Start

```bash
# Install mb
curl -fsSL https://raw.githubusercontent.com/0x10debug/vps-bootstrap/main/install.sh | bash

# Run the initialization wizard (interactive, all modules, safe defaults)
mb init
```

That's it. Answer the prompts (or accept defaults) and your server is hardened.

## Usage

```bash
mb init                          # Interactive setup (all modules, safe defaults)
mb init --module system,ssh      # Only run specific modules
mb init --config my-vps.yaml     # Declarative config (no interaction)
mb status                        # Check what's hardened and what's pending
mb rollback ssh                  # Undo SSH changes (or 'mb rollback all')
mb export                        # Export config for migration
mb update                        # Update mb and re-run system update
mb help                          # Show all commands
```

## Modules

| Module | What it does |
|---|---|
| `system` | System update, base tools, timezone, hostname |
| `user` | Non-root user, sudo, SSH key |
| `ssh` | SSH hardening (disable root, disable password, change port) |
| `firewall` | UFW or nftables (deny incoming, allow outgoing, open SSH/HTTP/HTTPS) |
| `crowdsec` | CrowdSec intrusion prevention: SSH/web/port-scan scenarios, firewall/nginx/Cloudflare bouncers, auditd log integration, email & webhook alerts |
| `kernel` | BBR, file descriptors, network stack tuning |
| `autoupdate` | Automatic security updates (Docker excluded) |
| `docker` | Docker Engine + Compose v2 with log rotation |
| `motd` | Status dashboard on every SSH login |
| `cis_align` | CIS Benchmark v14.0 L1 alignment report (read-only audit) |
| `partition_check` | Partition isolation + mount option check (read-only) |
| `auditd` | auditd install + file integrity monitoring + privileged command audit |

## Configuration

For declarative (non-interactive) setup, use a config file:

```bash
mb init --config my-vps.yaml
```

Example config:

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

timezone: "UTC"
username: "deploy"
ssh_port: "22222"
enable_bbr: true
docker_log_max_size: "50m"
```

See `config/example.yaml` for all options. Pre-built configs: `config/default.yaml` (all modules), `config/minimal.yaml` (essentials only).

## FAQ

### How to secure SSH on a fresh VPS?

Run `mb init` — it disables root login, disables password authentication (if you have an SSH key), changes the port to a non-standard one, and limits which users can connect. Every change is backed up and can be rolled back with `mb rollback ssh`.

### How to set up a firewall on Ubuntu or Debian?

The `firewall` module configures UFW with secure defaults: deny all incoming, allow outgoing, and only open SSH (on your configured port), HTTP (80), and HTTPS (443). Additional ports can be opened via config.

### CrowdSec vs fail2ban — which is better?

CrowdSec is the modern successor to fail2ban. It uses crowdsourced threat intelligence (IPs banned on one server are shared globally), supports multi-layer bouncers (firewall, web server, CDN), and can inspect HTTP traffic. fail2ban only reads logs and bans IPs locally. mb uses CrowdSec by default.

### How to install Docker on VPS securely?

The `docker` module installs Docker Engine and Compose v2 from official repositories, configures log rotation (to prevent disk exhaustion), adds your non-root user to the docker group, and does not expose the Docker daemon to the network.

### How to harden VPS for production?

Run `mb init` with all modules enabled. This gives you: updated system, non-root user, hardened SSH, active firewall, intrusion prevention, tuned kernel, automatic security updates, Docker ready, and a status dashboard. For deeper auditing, use [security-audit](https://github.com/0x10debug/security-audit).

## Comparison

| Feature | mb | Manual setup | Other scripts |
|---|---|---|---|
| System update | ✅ | You do it | Sometimes |
| Non-root user | ✅ | You do it | Sometimes |
| SSH hardening | ✅ | You do it | Usually |
| Firewall | ✅ | You do it | Sometimes |
| CrowdSec | ✅ | You install | ❌ (most use fail2ban) |
| Kernel tuning | ✅ | You research | Rarely |
| Auto security updates | ✅ | You configure | Rarely |
| Docker | ✅ | You install | Sometimes |
| MOTD dashboard | ✅ | ❌ | ❌ |
| Idempotent | ✅ | ❌ | Rarely |
| Rollback | ✅ | ❌ | ❌ |
| Config file | ✅ | ❌ | Rarely |

## Supported OS

- Ubuntu 22.04+ (LTS recommended)
- Debian 12+
- Alpine 3.22+ (limited module support)

## Documentation

- [Hardening Reference](docs/hardening-reference.md) — what every parameter does and why
- [Incident Response](docs/incident-response.md) — what to do if your server is compromised
- [Migration Guide](docs/migration.md) — how to move your config to a new server

## Contributing

Pull requests welcome. For major changes, open an issue first to discuss what you'd like to change.

## License

[MIT](./LICENSE)
