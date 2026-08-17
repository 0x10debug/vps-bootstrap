#!/usr/bin/env bash
# modules/ssh.sh — SSH hardening

mb_module_ssh() {
    mb_step "SSH hardening"

    local sshd_config="/etc/ssh/sshd_config"
    local sshd_config_d="/etc/ssh/sshd_config.d"

    # Backup before modifying
    mb_backup_file "$sshd_config" ssh
    [ -d "$sshd_config_d" ] && mb_backup_dir "$sshd_config_d" ssh

    # Determine SSH port
    local ssh_port="${MB_CONFIG_SSH_PORT:-}"
    if [ -z "$ssh_port" ]; then
        # Generate a random high port between 10000-65535
        ssh_port=$(( (RANDOM % 55535) + 10000 ))
        local custom_port
        custom_port=$(mb_ask_value "SSH port (recommended: use a non-standard port)" "$ssh_port")
        ssh_port="$custom_port"
    fi

    # Determine allowed users
    local allow_users="${MB_CONFIG_ALLOW_USERS:-}"
    if [ -z "$allow_users" ]; then
        allow_users=$(mb_env_get MB_USERNAME)
        if [ -z "$allow_users" ]; then
            allow_users=$(mb_ask_value "Allowed SSH users (space-separated)" "deploy")
        fi
    fi

    # Verify SSH key is configured before disabling password auth
    local has_key=false
    local username
    username=$(mb_env_get MB_USERNAME)
    if [ -n "$username" ] && [ -f "/home/${username}/.ssh/authorized_keys" ]; then
        if [ -s "/home/${username}/.ssh/authorized_keys" ]; then
            has_key=true
        fi
    fi

    # Build hardening config in a drop-in file (cleaner than editing main config)
    local dropin_file="${sshd_config_d}/99-mb-hardening.conf"
    mkdir -p "$sshd_config_d"

    {
        echo "# mb SSH hardening — generated $(date)"
        echo "# Do not edit manually. Use 'mb rollback ssh' to revert."
        echo ""
        echo "Port ${ssh_port}"
        echo "PermitRootLogin no"
        echo "PasswordAuthentication $([ "$has_key" = true ] && echo no || echo yes)"
        echo "PermitEmptyPasswords no"
        echo "KbdInteractiveAuthentication $([ "$has_key" = true ] && echo no || echo yes)"
        echo "X11Forwarding no"
        echo "AllowUsers ${allow_users}"
        echo "LoginGraceTime 30"
        echo "MaxAuthTries 3"
        echo "ClientAliveInterval 300"
        echo "ClientAliveCountMax 2"
        echo "Protocol 2"
    } > "$dropin_file"

    mb_detail "SSH hardening config written to: $dropin_file"
    mb_detail "  Port: $ssh_port"
    mb_detail "  Root login: disabled"
    mb_detail "  Password auth: $([ "$has_key" = true ] && echo "disabled (SSH key present)" || echo "enabled (no SSH key found)")"
    mb_detail "  Allowed users: $allow_users"

    # Validate sshd config syntax
    mb_info "Validating SSH configuration..."
    if ! sshd -t 2>/dev/null; then
        mb_error "SSH config validation failed! Rolling back..."
        rm -f "$dropin_file"
        mb_service_restart sshd 2>/dev/null || mb_service_restart ssh 2>/dev/null || true
        mb_die "SSH hardening failed due to config error. Original config preserved."
    fi

    # Restart SSH service
    # IMPORTANT: We restart but don't kill existing connections.
    # The user should keep their current session open and test the new port.
    mb_info "Restarting SSH service..."
    if [ "$MB_OS_FAMILY" = "debian" ]; then
        mb_service_restart ssh 2>/dev/null || mb_service_restart sshd 2>/dev/null
    else
        mb_service_restart sshd
    fi

    # Save to environment
    mb_env_set MB_SSH_PORT "$ssh_port"
    mb_env_set MB_SSH_ALLOW_USERS "$allow_users"

    # Warn the user
    echo ""
    mb_warn "SSH port changed to ${ssh_port}. DO NOT close this session yet!"
    mb_warn "Open a new terminal and test: ssh -p ${ssh_port} ${allow_users%% *}@$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<your-server-ip>')"
    echo ""
    mb_warn "If you can't connect on the new port, run: mb rollback ssh"

    mb_mark_done ssh
    mb_success "SSH hardening complete (port: $ssh_port)"
}
