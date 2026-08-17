#!/usr/bin/env bash
# modules/user.sh — Non-root user creation and SSH key setup

mb_module_user() {
    mb_step "Non-root user setup"

    # Determine username
    local username="${MB_CONFIG_USERNAME:-}"
    if [ -z "$username" ]; then
        username=$(mb_ask_value "Enter username for non-root account" "deploy")
    fi

    # Check if user already exists
    if id "$username" >/dev/null 2>&1; then
        mb_detail "User '$username' already exists"
    else
        # Create user
        if [ "$MB_OS_FAMILY" = "debian" ]; then
            adduser --quiet --gecos "" "$username"
        elif [ "$MB_OS_FAMILY" = "alpine" ]; then
            adduser -D "$username"
        fi
        mb_detail "Created user: $username"
    fi

    # Add to sudo/sudoers group
    local sudo_group
    case "$MB_OS_FAMILY" in
        debian) sudo_group="sudo" ;;
        alpine) sudo_group="wheel" ;;
    esac

    if id -nG "$username" | grep -qw "$sudo_group"; then
        mb_detail "User already in $sudo_group group"
    else
        usermod -aG "$sudo_group" "$username"
        mb_detail "Added $username to $sudo_group group"
    fi

    # Configure sudo: passwordless or with password
    local sudo_nopasswd="${MB_CONFIG_SUDO_NOPASSWD:-false}"
    local sudoers_file="/etc/sudoers.d/${username}"
    if [ "$sudo_nopasswd" = "true" ]; then
        echo "${username} ALL=(ALL) NOPASSWD:ALL" > "$sudoers_file"
        chmod 440 "$sudoers_file"
        mb_detail "Sudo configured: passwordless for $username"
    else
        # Ensure passwordless sudo is not set
        rm -f "$sudoers_file"
        mb_detail "Sudo configured: password required for $username"
    fi

    # SSH key setup
    local ssh_key="${MB_CONFIG_SSH_KEY:-}"
    local ssh_dir="/home/${username}/.ssh"
    local auth_file="${ssh_dir}/authorized_keys"

    mkdir -p "$ssh_dir"
    touch "$auth_file"

    if [ -n "$ssh_key" ]; then
        # Key provided via config
        if ! grep -q "$ssh_key" "$auth_file" 2>/dev/null; then
            echo "$ssh_key" >> "$auth_file"
            mb_detail "SSH key added from config"
        fi
    else
        # Interactive: ask if user wants to add a key now
        if mb_ask "Add an SSH public key for $username now?" "y"; then
            echo ""
            mb_info "Paste your SSH public key (one line, starts with ssh-ed25519 or ssh-rsa):"
            local pasted_key
            read -r pasted_key
            if [ -n "$pasted_key" ] && [[ "$pasted_key" == ssh-* ]]; then
                if ! grep -q "$pasted_key" "$auth_file" 2>/dev/null; then
                    echo "$pasted_key" >> "$auth_file"
                    mb_detail "SSH key added"
                else
                    mb_detail "SSH key already present"
                fi
            else
                mb_warn "Invalid SSH key format. Skipped."
            fi
        fi
    fi

    # Set proper permissions
    chown -R "$username":"$username" "$ssh_dir"
    chmod 700 "$ssh_dir"
    chmod 600 "$auth_file"

    # Save to environment
    mb_env_set MB_USERNAME "$username"

    mb_mark_done user
    mb_success "User setup complete: $username"
}
