#!/usr/bin/env bash
# modules/kernel.sh — Kernel parameter tuning (BBR, file descriptors, network)

mb_module_kernel() {
    mb_step "Kernel parameter tuning"

    local sysctl_file="/etc/sysctl.d/99-mb.conf"
    mb_backup_file "$sysctl_file" kernel

    local enable_bbr="${MB_CONFIG_ENABLE_BBR:-true}"
    local enable_tfo="${MB_CONFIG_ENABLE_TCP_FAST_OPEN:-false}"
    local disable_ipv6="${MB_CONFIG_DISABLE_IPV6:-false}"

    # Build sysctl config
    {
        echo "# mb kernel tuning — generated $(date)"
        echo "# Do not edit manually. Use 'mb rollback kernel' to revert."
        echo ""
    } > "$sysctl_file"

    # BBR congestion control
    if [ "$enable_bbr" = "true" ]; then
        if modprobe tcp_bbr 2>/dev/null || [ -f "/proc/sys/net/ipv4/tcp_available_congestion_control" ]; then
            {
                echo "# BBR congestion control"
                echo "net.core.default_qdisc = fq"
                echo "net.ipv4.tcp_congestion_control = bbr"
            } >> "$sysctl_file"
            mb_detail "BBR congestion control: enabled"
        else
            mb_warn "BBR module not available. Skipping."
        fi
    fi

    # File descriptor limits
    {
        echo ""
        echo "# File descriptor limits"
        echo "fs.file-max = 1048576"
        echo "fs.inotify.max_user_instances = 8192"
        echo "fs.inotify.max_user_watches = 1048576"
    } >> "$sysctl_file"
    mb_detail "File descriptor limits: raised"

    # Network stack tuning
    {
        echo ""
        echo "# Network stack tuning"
        echo "net.core.somaxconn = 65535"
        echo "net.core.netdev_max_backlog = 65535"
        echo "net.ipv4.tcp_max_syn_backlog = 65535"
        echo "net.ipv4.tcp_rmem = 4096 87380 67108864"
        echo "net.ipv4.tcp_wmem = 4096 65536 67108864"
        echo "net.ipv4.tcp_max_tw_buckets = 1048576"
        echo "net.ipv4.tcp_fin_timeout = 15"
        echo "net.ipv4.tcp_tw_reuse = 1"
        echo "net.ipv4.tcp_keepalive_time = 600"
        echo "net.ipv4.tcp_keepalive_intvl = 30"
        echo "net.ipv4.tcp_keepalive_probes = 5"
        echo "net.ipv4.tcp_syncookies = 1"
        echo "net.ipv4.conf.all.rp_filter = 1"
        echo "net.ipv4.conf.default.rp_filter = 1"
        echo "net.ipv4.ip_local_port_range = 1024 65535"
    } >> "$sysctl_file"
    mb_detail "Network stack: tuned"

    # TCP Fast Open
    if [ "$enable_tfo" = "true" ]; then
        echo "" >> "$sysctl_file"
        echo "# TCP Fast Open" >> "$sysctl_file"
        echo "net.ipv4.tcp_fastopen = 3" >> "$sysctl_file"
        mb_detail "TCP Fast Open: enabled"
    fi

    # IPv6
    if [ "$disable_ipv6" = "true" ]; then
        {
            echo ""
            echo "# Disable IPv6"
            echo "net.ipv6.conf.all.disable_ipv6 = 1"
            echo "net.ipv6.conf.default.disable_ipv6 = 1"
            echo "net.ipv6.conf.lo.disable_ipv6 = 1"
        } >> "$sysctl_file"
        mb_detail "IPv6: disabled"
    fi

    # Apply
    mb_info "Applying kernel parameters..."
    if ! sysctl -p "$sysctl_file" >/dev/null 2>&1; then
        mb_warn "Some sysctl parameters failed to apply. This may be normal for certain kernels."
    fi

    # Update ulimit for the system
    local limits_file="/etc/security/limits.d/99-mb.conf"
    {
        echo "# mb ulimits — generated $(date)"
        echo "*       soft    nofile  65535"
        echo "*       hard    nofile  65535"
        echo "root    soft    nofile  65535"
        echo "root    hard    nofile  65535"
    } > "$limits_file"
    mb_detail "Ulimit defaults raised to 65535"

    mb_mark_done kernel
    mb_success "Kernel tuning complete"
}
