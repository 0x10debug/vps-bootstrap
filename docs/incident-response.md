# Incident Response Guide

A guide for when things go wrong on your hardened VPS. Follow these steps if you suspect your server has been compromised.

## Signs of Compromise

- Unusual processes running (`ps aux`, `top`)
- Unexpected network connections (`ss -tulpn`, `netstat -tulpn`)
- Unfamiliar users in `/etc/passwd` or sudoers
- Modified system binaries (`dpkg --verify` on Debian)
- Unexpected crontab entries (`crontab -l`, `ls /etc/cron.d/`)
- CrowdSec alerts (check: `cscli alerts list`)
- High CPU/network usage without explanation
- Log entries showing successful logins from unknown IPs

## Step 1: Isolate (Stop the Bleeding)

```bash
# Check active connections
ss -tulpn

# Kill suspicious processes (replace PID)
kill -9 <PID>

# Block suspicious IPs immediately
cscli decisions add -i <suspicious_ip> -d 24h

# If severely compromised, consider disconnecting network
# (WARNING: This will cut your SSH access too)
# ip link set <interface> down
```

## Step 2: Preserve Evidence

```bash
# Save current process list
ps aux > /tmp/ps-snapshot.txt

# Save network state
ss -tulpn > /tmp/network-snapshot.txt

# Save auth logs
cp /var/log/auth.log /tmp/auth-log-backup  # Debian
cp /var/log/messages /tmp/messages-backup  # Alpine

# Save CrowdSec state
cscli alerts list -o json > /tmp/crowdsec-alerts.json
cscli decisions list -o json > /tmp/crowdsec-decisions.json

# Save last logins
last > /tmp/last-logins.txt
```

## Step 3: Investigate

```bash
# Check for new users
grep -v "^[^:]*:x:" /etc/passwd  # Users with passwords set
cat /etc/sudoers /etc/sudoers.d/* 2>/dev/null

# Check SSH keys
find / -name authorized_keys -exec ls -la {} \; 2>/dev/null
find / -name authorized_keys -exec cat {} \; 2>/dev/null

# Check crontabs
crontab -l  # Current user
for user in $(cut -f1 -d: /etc/passwd); do crontab -u "$user" -l 2>/dev/null; done
ls -la /etc/cron.d/ /etc/cron.daily/ /etc/cron.hourly/

# Check for rootkits (if chkrootkit installed)
chkrootkit 2>/dev/null

# Check modified files (last 24 hours)
find /etc /usr/bin /usr/sbin /bin /sbin -mtime -1 -type f 2>/dev/null

# Check Docker for suspicious containers
docker ps -a
docker images
```

## Step 4: Contain

```bash
# Disable compromised user accounts
usermod -L <username>  # Lock account

# Remove unauthorized SSH keys
# Edit /home/<user>/.ssh/authorized_keys

# Close unnecessary ports
ufw status verbose
ufw deny <port>

# Stop suspicious Docker containers
docker stop <container_id>
```

## Step 5: Eradicate

```bash
# Remove backdoors
# - Delete unauthorized users: userdel -r <username>
# - Remove unauthorized SSH keys
# - Remove suspicious cron jobs
# - Remove suspicious Docker containers/images

# Re-harden SSH if config was tampered
mb rollback ssh
mb init --module ssh

# Re-harden firewall
mb rollback firewall
mb init --module firewall

# Update all packages
apt update && apt upgrade -y  # Debian
apk update && apk upgrade     # Alpine

# Run security audit
# (if security-audit is installed)
mb audit run
```

## Step 6: Recover

```bash
# Restore data from backup (if data was damaged)
# Use backup-kit: mb backup restore --latest

# Verify all services are running correctly
docker ps
systemctl status crowdsec
systemctl status docker

# Test SSH access on the correct port
ssh -p <port> <user>@<server_ip>
```

## Step 7: Post-Incident

- **Document what happened**: timeline, entry point, impact, actions taken
- **Update passwords**: all user passwords, SSH keys, API tokens
- **Review logs**: check for data exfiltration, lateral movement
- **Consider rebuilding**: if compromise is deep, rebuild from scratch on a fresh VPS using `mb init`
- **Update monitoring**: add alerts for the indicators you missed

## Quick Reference

| Action | Command |
|---|---|
| Check CrowdSec alerts | `cscli alerts list` |
| Block an IP | `cscli decisions add -i <ip> -d 24h` |
| Check open ports | `ss -tulpn` |
| Check running processes | `ps aux` |
| Check Docker containers | `docker ps -a` |
| Rollback SSH config | `mb rollback ssh` |
| Rollback all config | `mb rollback all` |
| Re-run hardening | `mb init` |
| Restore from backup | `mb backup restore --latest` |
