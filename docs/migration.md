# Migration Guide

How to migrate your mb-hardened VPS configuration to a new server.

## Overview

mb makes migration straightforward by separating configuration from data:

1. **Configuration** — exported via `mb export` (SSH port, usernames, module states, etc.)
2. **Data** — exported via backup-kit (Docker volumes, application data)

This guide covers the configuration side. For data migration, see [backup-kit](https://github.com/0x10debug/backup-kit).

## Step 1: Export Configuration (Old Server)

On your current server:

```bash
mb export
```

This creates a file like `mb-export-20260816-120000.tar.gz` containing:
- `/etc/mb/env.sh` — environment variables (SSH port, username, etc.)
- `/var/lib/mb/` — module completion states
- `manifest.yaml` — human-readable summary

## Step 2: Transfer to New Server

```bash
# From your local machine
scp mb-export-*.tar.gz user@new-server:/tmp/

# Or from old server directly
scp mb-export-*.tar.gz user@new-server:/tmp/
```

## Step 3: Install mb on New Server

On the new server:

```bash
curl -fsSL https://raw.githubusercontent.com/0x10debug/vps-bootstrap/main/install.sh | bash
```

## Step 4: Extract and Apply Configuration

```bash
# Extract the export
cd /tmp
tar xzf mb-export-*.tar.gz

# Review the manifest
cat manifest.yaml

# Apply the configuration
mb init --config manifest.yaml
```

This will re-run all modules on the new server with the same settings as the old one.

## Step 5: Migrate Data

Use backup-kit to restore your application data:

```bash
# On new server (if backup-kit installed)
mb backup restore --latest
```

See [backup-kit documentation](https://github.com/0x10debug/backup-kit) for details.

## Step 6: Verify

```bash
# Check hardening status
mb status

# Test SSH on the configured port
ssh -p <port> <user>@new-server-ip

# Verify Docker containers are running
docker ps

# Verify CrowdSec is active
cscli status
```

## Step 7: Update DNS / Firewall

- Update DNS records to point to the new server's IP
- Update any firewall rules that reference the old IP
- Update monitoring (monitor-stack) to point to the new server

## Step 8: Decommission Old Server

Only after verifying everything works on the new server:

```bash
# On old server: stop all services
docker compose down  # for each compose project

# Verify no critical data remains
# Then decommission the old VPS from your provider's dashboard
```

## Partial Migration

If you only want to migrate specific modules:

```bash
# Export only includes configuration, not module selection
# To run only specific modules on the new server:
mb init --module system,ssh,firewall --config manifest.yaml
```

## Troubleshooting

### SSH port conflict
If the new server already has SSH on a different port, mb will use the port from the exported config. Make sure your SSH provider allows the port.

### Docker data directory
If you set a custom `docker_data_dir` in the old config, make sure the same path exists (with enough space) on the new server.

### CrowdSec
CrowdSec will register as a new instance on the new server. Your old server's decisions and alerts are not migrated (they're server-specific).
