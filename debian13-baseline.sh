#!/bin/bash
# Debian 13 baseline for a fresh server with one public network interface.
set -euo pipefail

CONFIG_DIR=/etc/debian-baseline
STATE_DIR=/var/lib/debian-baseline
INSTALL_PATH=/usr/local/sbin/debian13-baseline
SSH_FILE=/etc/ssh/sshd_config.d/00-debian-baseline.conf
FIREWALL_UNIT=debian-baseline-firewall.service
ROLLBACK_UNIT=debian-baseline-rollback
UNIT_DIR=/etc/systemd/system
ROLLBACK_ON_ERROR=0
CLEAN_PENDING_ON_ERROR=0

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: debian13-baseline [prepare|apply|confirm|rollback|status]

prepare   Install the baseline and create a key-only administrator (default).
apply     Apply SSH/firewall restrictions from that administrator's SSH session.
confirm   Keep those restrictions after testing a fresh SSH connection.
rollback  Restore the previous SSH/firewall configuration.
status    Show the managed configuration and pending rollback.

Prepare settings (environment variables):
  NEW_USER          admin
  SSH_KEY_FILE      /root/.ssh/authorized_keys
  TIMEZONE          UTC
  PUBLIC_INTERFACE  auto-detected from the default routes
  PUBLIC_TCP_PORTS  "80 443" (the existing SSH port is always included)

SSH port changes are deliberately a separate operation. Run apply and confirm
with: sudo --preserve-env=SSH_CONNECTION debian13-baseline <command>
Unconfirmed access changes roll back after five minutes.
EOF
}

validate_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] || fail "Invalid TCP port: $1"
    (( 10#$1 >= 1 && 10#$1 <= 65535 )) || fail "Invalid TCP port: $1"
}

validate_settings() {
    local port
    [[ "$NEW_USER" =~ ^[a-z][a-z0-9_-]{0,31}$ && "$NEW_USER" != root ]] || fail "Invalid administrator name."
    [[ "$PUBLIC_INTERFACE" =~ ^[a-zA-Z0-9_.:-]{1,15}$ && "$PUBLIC_INTERFACE" != lo ]] || fail "Set PUBLIC_INTERFACE to one public interface."
    [[ "$PUBLIC_TCP_PORTS" != *$'\n'* && "$PUBLIC_TCP_PORTS" =~ ^[0-9\ ]*$ ]] || fail "PUBLIC_TCP_PORTS must be a space-separated list of TCP ports."
    validate_port "$SSH_PORT"
    read -r -a TCP_PORTS <<< "$PUBLIC_TCP_PORTS"
    for port in "${TCP_PORTS[@]}"; do
        validate_port "$port"
    done
}

require_host() {
    [[ $EUID -eq 0 ]] || fail "Run as root or through sudo."
    [[ -r /etc/os-release ]] || fail "Debian 13 is required."
    # shellcheck source=/dev/null
    . /etc/os-release
    [[ "$ID" == debian && "$VERSION_ID" == 13 ]] || fail "This script supports Debian 13 only."
    [[ -d /run/systemd/system ]] || fail "A running systemd host is required."
}

require_ssh() {
    /usr/sbin/sshd -t
    systemctl is-active --quiet ssh.service || fail "ssh.service must already be running."
}

check_firewall_managers() {
    local unit
    for unit in nftables.service ufw.service firewalld.service netfilter-persistent.service; do
        if systemctl is-active --quiet "$unit" || systemctl is-enabled --quiet "$unit" 2>/dev/null; then
            fail "$unit is active or enabled. Review the existing firewall before using this baseline."
        fi
    done
}

load_settings() {
    [[ -f "$CONFIG_DIR/settings" ]] || fail "Run prepare first."
    # This file and its parent directory are installed root-only by prepare.
    # shellcheck source=/dev/null
    . "$CONFIG_DIR/settings"
    validate_settings
}

require_admin_session() {
    local extra
    [[ "${SUDO_USER:-}" == "$NEW_USER" ]] || fail "Run through sudo as $NEW_USER after logging in with its SSH key."
    [[ -n "${SSH_CONNECTION:-}" ]] || fail "Preserve SSH_CONNECTION with sudo --preserve-env=SSH_CONNECTION."
    read -r CLIENT_IP CLIENT_PORT SERVER_IP SERVER_PORT extra <<< "$SSH_CONNECTION"
    [[ -z "$extra" && "$CLIENT_IP" =~ ^[0-9a-fA-F:.]+$ && "$SERVER_IP" =~ ^[0-9a-fA-F:.]+$ ]] || fail "Invalid SSH_CONNECTION."
    validate_port "$CLIENT_PORT"
    validate_port "$SERVER_PORT"
    [[ "$SERVER_PORT" == "$SSH_PORT" ]] || fail "Connect using the managed SSH port $SSH_PORT."
}

render_ssh() {
    cat <<EOF
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin no
AllowUsers $NEW_USER
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding local
GatewayPorts no
EOF
}

render_firewall() {
    local port ports="$SSH_PORT"
    for port in "${TCP_PORTS[@]}"; do
        ports+=", $((10#$port))"
    done
    cat <<EOF
destroy table inet debian_baseline
table inet debian_baseline {
    chain public_ingress {
        type filter hook prerouting priority -150; policy accept;
        iifname != "$PUBLIC_INTERFACE" accept
        ct state established,related accept
        meta l4proto { icmp, ipv6-icmp } accept
        meta nfproto ipv4 udp sport 67 udp dport 68 accept
        meta nfproto ipv6 udp sport 547 udp dport 546 accept
        ct state new tcp dport { $ports } accept
        counter drop
    }
}
EOF
}

render_firewall_unit() {
    cat <<EOF
[Unit]
Description=Debian baseline public interface firewall
DefaultDependencies=no
Wants=network-pre.target
Before=network-pre.target shutdown.target
After=local-fs.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft --file $CONFIG_DIR/firewall.nft
ExecReload=/usr/sbin/nft --file $CONFIG_DIR/firewall.nft
ExecStop=/usr/sbin/nft destroy table inet debian_baseline

[Install]
WantedBy=multi-user.target
EOF
}

install_rollback_units() {
    cat > "$UNIT_DIR/$ROLLBACK_UNIT.service" <<EOF
[Unit]
Description=Restore unconfirmed Debian baseline access settings
ConditionPathExists=$STATE_DIR/pending/armed

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH rollback
Restart=on-failure
RestartSec=30s
EOF
    cat > "$UNIT_DIR/$ROLLBACK_UNIT.timer" <<EOF
[Unit]
Description=Roll back unconfirmed Debian baseline access changes

[Timer]
OnActiveSec=5min
AccuracySec=1s
Unit=$ROLLBACK_UNIT.service

[Install]
WantedBy=timers.target
EOF
    chmod 644 "$UNIT_DIR/$ROLLBACK_UNIT.service" "$UNIT_DIR/$ROLLBACK_UNIT.timer"
    systemctl daemon-reload
}

render_updates() {
    cat <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=trixie-security,label=Debian-Security";
};
Unattended-Upgrade::Automatic-Reboot "false";
EOF
}

verify_updates() {
    local resolved
    resolved=$(apt-config dump)
    [[ "$(awk '$1 == "Unattended-Upgrade::Automatic-Reboot" {print $2}' <<< "$resolved")" == '"false";' ]] || fail "Another APT configuration overrides the no-reboot policy."
    [[ "$(awk '$1 == "Unattended-Upgrade::Origins-Pattern::" {print $2}' <<< "$resolved")" == '"origin=Debian,codename=trixie-security,label=Debian-Security";' ]] || fail "Another APT configuration overrides the security update origins."
    [[ -z "$(awk '$1 == "Unattended-Upgrade::Allowed-Origins::" {print $2}' <<< "$resolved")" ]] || fail "Another APT configuration adds automatic update origins."
}

prepare() {
    local interface_list existing_port ntp_active=0 service file
    if [[ -f "$CONFIG_DIR/settings" ]]; then
        load_settings
        printf 'Already prepared for %s. Use apply, confirm, rollback, or status.\n' "$NEW_USER"
        return
    fi
    if [[ -f "$CONFIG_DIR/preparing" ]]; then
        # shellcheck source=/dev/null
        . "$CONFIG_DIR/preparing"
        validate_settings
        printf 'Resuming preparation for %s.\n' "$NEW_USER"
    else
        NEW_USER="${NEW_USER:-admin}"
        SSH_KEY_FILE="${SSH_KEY_FILE:-/root/.ssh/authorized_keys}"
        TIMEZONE="${TIMEZONE:-UTC}"
        PUBLIC_TCP_PORTS="${PUBLIC_TCP_PORTS-80 443}"
        existing_port=$(/usr/sbin/sshd -T | awk '$1 == "port" {print $2}' | sort -u)
        SSH_PORT="$existing_port"
        interface_list=$( { ip -4 route show default; ip -6 route show default; } | awk '{for (i=1; i<NF; i++) if ($i == "dev") print $(i+1)}' | sort -u)
        PUBLIC_INTERFACE="${PUBLIC_INTERFACE:-$interface_list}"
        validate_settings
        ip link show dev "$PUBLIC_INTERFACE" >/dev/null
        [[ "$TIMEZONE" != /* && "$TIMEZONE" != *..* && -f "/usr/share/zoneinfo/$TIMEZONE" ]] || fail "Invalid TIMEZONE."
        if id "$NEW_USER" >/dev/null 2>&1; then
            fail "$NEW_USER already exists; this script only creates new administrators."
        fi
        [[ -s "$SSH_KEY_FILE" ]] || fail "SSH_KEY_FILE must contain at least one public key."
        ssh-keygen -l -f "$SSH_KEY_FILE" >/dev/null || fail "SSH_KEY_FILE has no valid public keys."
        [[ -f "${BASH_SOURCE[0]}" ]] || fail "Download and review this script before running it."
        check_firewall_managers
        for file in "$SSH_FILE" "$CONFIG_DIR" "$STATE_DIR" "$INSTALL_PATH" "$UNIT_DIR/$FIREWALL_UNIT" "$UNIT_DIR/$ROLLBACK_UNIT.service" "$UNIT_DIR/$ROLLBACK_UNIT.timer" /etc/sudoers.d/90-debian-baseline /etc/apt/apt.conf.d/52debian-baseline; do
            [[ ! -e "$file" && ! -L "$file" ]] || fail "Unmanaged path already exists: $file"
        done
        if command -v nft >/dev/null 2>&1; then
            [[ -z "$(nft list tables)" ]] || fail "Existing nftables tables found; review this host's firewall first."
        fi
        install -d -m 700 "$CONFIG_DIR" "$STATE_DIR"
        install -m 600 "$SSH_KEY_FILE" "$CONFIG_DIR/authorized_keys"
        for file in NEW_USER SSH_PORT PUBLIC_INTERFACE PUBLIC_TCP_PORTS TIMEZONE; do
            printf '%s=%q\n' "$file" "${!file}"
        done > "$CONFIG_DIR/preparing.new"
        mv "$CONFIG_DIR/preparing.new" "$CONFIG_DIR/preparing"
    fi
    check_firewall_managers

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade --yes --no-remove -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
    apt-get install --yes --no-remove --no-install-recommends sudo openssh-server ca-certificates curl nftables unattended-upgrades
    check_firewall_managers
    for service in systemd-timesyncd.service chrony.service ntpsec.service; do
        if systemctl is-active --quiet "$service"; then
            ntp_active=1
        fi
    done
    if [[ "$ntp_active" == 0 ]]; then
        apt-get install --yes --no-remove --no-install-recommends systemd-timesyncd
        systemctl enable --now systemd-timesyncd.service
    fi
    timedatectl set-timezone "$TIMEZONE"

    if ! id "$NEW_USER" >/dev/null 2>&1; then
        adduser --disabled-password --comment '' "$NEW_USER"
    fi
    [[ "$(getent passwd "$NEW_USER" | cut -d: -f6)" == "/home/$NEW_USER" ]] || fail "Unexpected home directory for $NEW_USER."
    usermod -aG sudo "$NEW_USER"
    install -d -o "$NEW_USER" -g "$NEW_USER" -m 700 "/home/$NEW_USER/.ssh"
    if [[ -f "/home/$NEW_USER/.ssh/authorized_keys" ]]; then
        awk '!seen[$0]++' "$CONFIG_DIR/authorized_keys" "/home/$NEW_USER/.ssh/authorized_keys" > "$CONFIG_DIR/merged-keys"
    else
        cp "$CONFIG_DIR/authorized_keys" "$CONFIG_DIR/merged-keys"
    fi
    install -o "$NEW_USER" -g "$NEW_USER" -m 600 "$CONFIG_DIR/merged-keys" "/home/$NEW_USER/.ssh/authorized_keys"
    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$NEW_USER" > "$CONFIG_DIR/sudoers"
    chmod 440 "$CONFIG_DIR/sudoers"
    visudo -cf "$CONFIG_DIR/sudoers"
    install -m 440 "$CONFIG_DIR/sudoers" /etc/sudoers.d/90-debian-baseline
    visudo -c
    runuser -u "$NEW_USER" -- sudo -n true

    render_updates > /etc/apt/apt.conf.d/52debian-baseline
    chmod 644 /etc/apt/apt.conf.d/52debian-baseline
    verify_updates
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service

    if [[ "$(readlink -f "${BASH_SOURCE[0]}")" != "$INSTALL_PATH" ]]; then
        install -m 755 "${BASH_SOURCE[0]}" "$INSTALL_PATH"
    fi
    install_rollback_units
    cp -p "$CONFIG_DIR/preparing" "$CONFIG_DIR/settings.new"
    mv "$CONFIG_DIR/settings.new" "$CONFIG_DIR/settings"
    rm -f "$CONFIG_DIR/preparing"
    printf '\nPrepared administrator %s with full passwordless sudo.\n' "$NEW_USER"
    printf 'SSH and firewall restrictions have not been applied.\n'
    printf 'Open a separate SSH connection as %s on port %s, verify sudo -n true, then run:\n' "$NEW_USER" "$SSH_PORT"
    printf '  sudo --preserve-env=SSH_CONNECTION debian13-baseline apply\n'
    if [[ -f /var/run/reboot-required ]]; then
        printf 'An OS reboot is required; schedule it manually.\n'
    fi
}

backup_file() {
    if [[ -f "$1" ]]; then
        cp -p "$1" "$STATE_DIR/pending/$2"
    fi
}

restore_file() {
    if [[ -f "$STATE_DIR/pending/$2" ]]; then
        cp -p "$STATE_DIR/pending/$2" "$1" || return 1
    else
        rm -f "$1" || return 1
    fi
}

verify_ssh() {
    local user actual key expected settings
    /usr/sbin/sshd -t
    for user in "$NEW_USER" root; do
        settings=$(/usr/sbin/sshd -T -C "user=$user,addr=$CLIENT_IP,host=$CLIENT_IP,laddr=$SERVER_IP,lport=$SSH_PORT")
        while read -r key expected; do
            actual=$(awk -v key="$key" '$1 == key {$1=""; sub(/^ /, ""); print}' <<< "$settings")
            [[ "$actual" == "$expected" ]] || fail "Effective SSH setting for $user: $key=$actual; expected $expected. Check other SSH configuration."
        done <<EOF
pubkeyauthentication yes
authenticationmethods publickey
passwordauthentication no
kbdinteractiveauthentication no
permitemptypasswords no
permitrootlogin no
allowusers $NEW_USER
x11forwarding no
allowagentforwarding no
allowtcpforwarding local
gatewayports no
EOF
    done
}

apply_access() {
    local pending="$STATE_DIR/pending"
    require_admin_session
    check_firewall_managers
    [[ ! -d "$pending" ]] || fail "An access change is already pending. Confirm it or roll it back first."
    # Cancel any service retry left by a previous rollback before reusing pending.
    systemctl stop "$ROLLBACK_UNIT.timer" "$ROLLBACK_UNIT.service"
    ip link show dev "$PUBLIC_INTERFACE" >/dev/null
    nft list tables >/dev/null
    CLEAN_PENDING_ON_ERROR=1
    install -d -m 700 "$pending"
    backup_file "$SSH_FILE" ssh.conf
    backup_file "$CONFIG_DIR/firewall.nft" firewall.nft
    backup_file "$UNIT_DIR/$FIREWALL_UNIT" firewall.service
    if nft list table inet debian_baseline >/dev/null 2>&1; then
        nft --stateless list table inet debian_baseline > "$pending/table.nft"
    fi
    if systemctl is-enabled --quiet "$FIREWALL_UNIT" 2>/dev/null; then
        touch "$pending/firewall-enabled"
    fi
    if systemctl is-active --quiet "$FIREWALL_UNIT"; then
        touch "$pending/firewall-active"
    fi
    printf '%s\n' "$SSH_CONNECTION" > "$pending/connection"
    render_ssh > "$pending/new-ssh.conf"
    render_firewall > "$pending/new-firewall.nft"
    render_firewall_unit > "$pending/new-firewall.service"
    nft --check --file "$pending/new-firewall.nft"

    touch "$pending/armed"
    ROLLBACK_ON_ERROR=1
    systemctl enable --now "$ROLLBACK_UNIT.timer"
    systemctl is-active --quiet "$ROLLBACK_UNIT.timer" || fail "Could not arm automatic rollback."
    install -m 644 "$pending/new-ssh.conf" "$SSH_FILE"
    verify_ssh
    install -m 600 "$pending/new-firewall.nft" "$CONFIG_DIR/firewall.nft"
    install -m 644 "$pending/new-firewall.service" "$UNIT_DIR/$FIREWALL_UNIT"
    systemctl daemon-reload
    systemctl enable "$FIREWALL_UNIT"
    if systemctl is-active --quiet "$FIREWALL_UNIT"; then
        systemctl reload "$FIREWALL_UNIT"
    else
        systemctl start "$FIREWALL_UNIT"
    fi
    systemctl reload ssh.service
    ROLLBACK_ON_ERROR=0
    CLEAN_PENDING_ON_ERROR=0
    printf '\nAccess restrictions applied; rollback is armed for five minutes.\n'
    printf 'Keep this session open. Reconnect as %s without SSH connection sharing, then run:\n' "$NEW_USER"
    printf '  sudo --preserve-env=SSH_CONNECTION debian13-baseline confirm\n'
}

archive_pending() {
    mv "$STATE_DIR/pending" "$STATE_DIR/$1-$(date +%Y%m%dT%H%M%S)-$$"
}

restore_firewall() {
    local pending="$STATE_DIR/pending" failed=0
    if systemctl is-active --quiet "$FIREWALL_UNIT"; then
        systemctl stop "$FIREWALL_UNIT" || failed=1
    fi
    if [[ -f "$UNIT_DIR/$FIREWALL_UNIT" ]]; then
        systemctl disable "$FIREWALL_UNIT" || failed=1
    fi
    restore_file "$CONFIG_DIR/firewall.nft" firewall.nft || failed=1
    restore_file "$UNIT_DIR/$FIREWALL_UNIT" firewall.service || failed=1
    systemctl daemon-reload || failed=1
    if [[ -f "$pending/firewall-enabled" ]]; then
        systemctl enable "$FIREWALL_UNIT" || failed=1
    fi
    if [[ -f "$pending/firewall-active" ]]; then
        systemctl reload-or-restart "$FIREWALL_UNIT" || failed=1
    fi
    {
        printf 'destroy table inet debian_baseline\n'
        if [[ -f "$pending/table.nft" ]]; then
            cat "$pending/table.nft"
        fi
    } > "$pending/restore.nft" || return 1
    nft --file "$pending/restore.nft" || failed=1
    return "$failed"
}

rollback_access() {
    local pending="$STATE_DIR/pending" failed=0
    if [[ ! -f "$pending/armed" ]]; then
        printf 'No armed access change to roll back.\n'
        return
    fi
    if ! restore_firewall; then
        printf 'Firewall recovery failed; pending backups retained.\n' >&2
        failed=1
    fi
    if restore_file "$SSH_FILE" ssh.conf && /usr/sbin/sshd -t; then
        systemctl reload-or-restart ssh.service || failed=1
    else
        printf 'SSH recovery failed; pending backups retained.\n' >&2
        failed=1
    fi
    [[ "$failed" == 0 ]] || return 1
    systemctl disable --now "$ROLLBACK_UNIT.timer" || return 1
    archive_pending rolled-back || return 1
    printf 'Previous SSH and firewall settings restored. Packages and administrator account retained.\n'
}

confirm_access() {
    require_admin_session
    [[ -f "$STATE_DIR/pending/armed" ]] || fail "No pending access change."
    [[ "$SSH_CONNECTION" != "$(cat "$STATE_DIR/pending/connection")" ]] || fail "Reconnect with ControlMaster=no and ControlPath=none before confirming."
    systemctl is-active --quiet "$FIREWALL_UNIT" || fail "The firewall service is not active."
    nft list table inet debian_baseline >/dev/null
    verify_ssh
    systemctl disable --now "$ROLLBACK_UNIT.timer"
    archive_pending confirmed
    printf 'Access verified. Root SSH login is disabled and the firewall is persistent.\n'
}

on_exit() {
    local status=$?
    trap - EXIT
    if [[ "$status" != 0 && "$ROLLBACK_ON_ERROR" == 1 ]]; then
        printf 'Apply failed; restoring previous access settings.\n' >&2
        rollback_access || printf 'Rollback failed; backups remain in %s/pending and the timer will retry.\n' "$STATE_DIR" >&2
    elif [[ "$status" != 0 && "$CLEAN_PENDING_ON_ERROR" == 1 ]]; then
        rm -rf "$STATE_DIR/pending"
    fi
    exit "$status"
}

main() {
    local action="${1:-prepare}"
    [[ $# -le 1 ]] || fail "Expected one command. Use --help."
    case "$action" in
        -h|--help) usage; return ;;
        prepare|apply|confirm|rollback|status) ;;
        *) fail "Unknown command: $action" ;;
    esac
    require_host
    if [[ "$action" == prepare || "$action" == apply || "$action" == confirm ]]; then
        require_ssh
    fi
    umask 077
    exec 9>/run/lock/debian13-baseline.lock
    flock -n 9 || fail "Another baseline operation is running."
    trap on_exit EXIT
    if [[ "$action" == prepare ]]; then
        prepare
        return
    fi
    if [[ "$action" != rollback ]]; then
        load_settings
    fi
    case "$action" in
        apply) apply_access ;;
        confirm) confirm_access ;;
        rollback) rollback_access ;;
        status)
            printf 'Administrator: %s\nSSH port: %s\nPublic interface: %s\nPublic TCP ports: %s %s\n' "$NEW_USER" "$SSH_PORT" "$PUBLIC_INTERFACE" "$SSH_PORT" "$PUBLIC_TCP_PORTS"
            if [[ -f "$STATE_DIR/pending/armed" ]]; then
                printf 'Access changes are UNCONFIRMED.\n'
                systemctl list-timers "$ROLLBACK_UNIT.timer" --no-pager
            fi
            /usr/sbin/sshd -T | awk '$1 ~ /^(permitrootlogin|passwordauthentication|authenticationmethods)$/ {print}'
            if nft list table inet debian_baseline >/dev/null 2>&1; then
                nft list table inet debian_baseline
            else
                printf 'Managed firewall has not been applied.\n'
            fi
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
