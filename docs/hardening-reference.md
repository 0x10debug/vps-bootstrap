# Hardening Reference

This document explains every hardening parameter that mb applies and why. Use this to understand what mb does to your server, or to manually harden a server without using mb.

## SSH Hardening

| Parameter | Value | Why |
|---|---|---|
| `Port` | Non-standard (user-chosen) | Reduces automated brute-force scans that target port 22 |
| `PermitRootLogin` | `no` | Root login is the highest-value target; use sudo instead |
| `PasswordAuthentication` | `no` (if SSH key present) | Passwords can be brute-forced; SSH keys are cryptographically secure |
| `PermitEmptyPasswords` | `no` | Empty passwords are a critical vulnerability |
| `X11Forwarding` | `no` | X11 forwarding can be abused for privilege escalation; rarely needed on servers |
| `AllowUsers` | Specific users | Limits SSH access to known accounts only |
| `LoginGraceTime` | `30` | Disconnect unauthenticated sessions after 30 seconds |
| `MaxAuthTries` | `3` | Limits brute-force attempts per connection |
| `ClientAliveInterval` | `300` | Keep-alive check every 5 minutes |
| `ClientAliveCountMax` | `2` | Disconnect after 2 missed keep-alives (10 min total) |
| `Protocol` | `2` | Protocol 1 has known vulnerabilities |

## Firewall Rules

| Rule | Why |
|---|---|
| Default: deny incoming | Block all unsolicited inbound traffic |
| Default: allow outgoing | Server needs to reach the internet (updates, APIs) |
| Allow SSH port | Remote administration |
| Allow 80/tcp | HTTP (for Let's Encrypt challenges and redirect to HTTPS) |
| Allow 443/tcp | HTTPS (for web services) |
| All other ports | Denied by default; open only as needed |

## CrowdSec Configuration

| Setting | Why |
|---|---|
| `crowdsecurity/ssh-slow-bf` | Detects slow SSH brute-force attacks |
| `crowdsecurity/ssh-bf` | Detects fast SSH brute-force attacks |
| `crowdsecurity/http-cve` | Detects known CVE exploitation attempts (if web server present) |
| `crowdsecurity/http-generic` | Detects generic HTTP attacks (if web server present) |
| Community blocklist | Crowdsourced IP reputation — blocks IPs reported by other CrowdSec users globally |
| Firewall bouncer | Automatically blocks detected malicious IPs at the firewall level |
| Current IP whitelist | Prevents you from banning your own IP during testing |

**CrowdSec vs fail2ban**: CrowdSec is the modern successor to fail2ban. Key advantages:
- **Crowdsourced threat intelligence**: IPs banned on one server are shared globally
- **Multi-layer bouncers**: Block at firewall, web server, or CDN level
- **WAF capability**: Can inspect HTTP traffic, not just log patterns
- **Active development**: fail2ban is maintenance-only; CrowdSec is actively developed

## Kernel Parameters

| Parameter | Value | Why |
|---|---|---|
| `net.core.default_qdisc` | `fq` | Fair queuing — better for BBR and modern congestion control |
| `net.ipv4.tcp_congestion_control` | `bbr` | BBR algorithm — better throughput on high-latency/lossy links than CUBIC |
| `fs.file-max` | `1048576` | More file descriptors for servers handling many connections |
| `fs.inotify.max_user_instances` | `8192` | More inotify watchers for file monitoring (Docker, dev tools) |
| `fs.inotify.max_user_watches` | `1048576` | Same as above — watches per instance |
| `net.core.somaxconn` | `65535` | Larger connection queue — prevents dropped connections under load |
| `net.core.netdev_max_backlog` | `65535` | Larger packet backlog — prevents dropped packets under high network load |
| `net.ipv4.tcp_max_syn_backlog` | `65535` | More SYN packets queued — better resistance to SYN floods |
| `net.ipv4.tcp_rmem` | `4096 87380 67108864` | Larger receive buffer — better throughput on high-bandwidth links |
| `net.ipv4.tcp_wmem` | `4096 65536 67108864` | Larger send buffer — same as above |
| `net.ipv4.tcp_max_tw_buckets` | `1048576` | More TIME_WAIT sockets — prevents exhaustion under high connection churn |
| `net.ipv4.tcp_fin_timeout` | `15` | Faster FIN-WAIT-2 cleanup — frees sockets sooner |
| `net.ipv4.tcp_tw_reuse` | `1` | Reuse TIME_WAIT sockets — reduces socket exhaustion |
| `net.ipv4.tcp_keepalive_time` | `600` | Check dead connections after 10 min (default 2 hours) |
| `net.ipv4.tcp_syncookies` | `1` | SYN flood protection |
| `net.ipv4.conf.all.rp_filter` | `1` | Reverse path filtering — blocks spoofed packets |
| `net.ipv4.ip_local_port_range` | `1024 65535` | More ephemeral ports for outbound connections |

## Ulimit

| Limit | Value | Why |
|---|---|---|
| `nofile` soft | `65535` | Processes can open more files (default is often 1024) |
| `nofile` hard | `65535` | Maximum allowed file descriptors |

## Docker Configuration

| Setting | Value | Why |
|---|---|---|
| `log-driver` | `json-file` | Default, but with rotation (see below) |
| `log-opts.max-size` | `50m` | Rotate logs at 50MB — prevents disk exhaustion |
| `log-opts.max-file` | `3` | Keep 3 rotated files (150MB max per container) |
| `live-restore` | `true` | Containers keep running during Docker daemon restarts |
| `userland-proxy` | `false` | Disable the userland proxy — use iptables directly (faster) |
| Docker packages excluded from auto-update | — | Docker updates can break running containers; update manually |

## Auto-Update

| Setting | Value | Why |
|---|---|---|
| Only security updates | — | Avoid breaking running services with non-security upgrades |
| Docker packages blacklisted | — | Docker updates require manual intervention |
| Auto-reboot | `false` (default) | Reboots disrupt services; enable only if you can tolerate downtime |
| Autoclean | `7 days` | Remove downloaded package files weekly |

## References

- [CIS Benchmarks](https://www.cisecurity.org/cis-benchmarks) — Industry-standard hardening guidelines
- [CrowdSec Documentation](https://docs.crowdsec.net/) — CrowdSec configuration reference
- [Mozilla SSL Configuration Generator](https://ssl-config.mozilla.org/) — SSL/TLS best practices
- [Docker Security](https://docs.docker.com/engine/security/) — Docker daemon security guide
