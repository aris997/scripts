#!/bin/bash
# =============================================================================
# SERVER INITIALIZATION SCRIPT
# =============================================================================
#
# Purpose:  Set up a fresh Ubuntu/Debian server with security hardening,
#           a non-root admin user, nginx, certbot, and essential tooling.
#
# Usage:    Run as root on a fresh server:
#               sudo bash server-init.sh
#
#           You can override defaults with environment variables:
#               NEW_USER=ricc NEW_USER_PASSWORD=supersecret bash server-init.sh
#``
# What this script does (in order):
#   1. System updates
#   2. Essential package installation
#   3. Timezone & NTP (clock sync)
#   4. User creation & SSH key setup
#   5. Sudo configuration
#   6. SSH hardening
#   7. Firewall (UFW)
#   8. Fail2ban (brute-force protection)
#   9. Kernel / network hardening (sysctl)
#  10. Unattended security upgrades
#  11. Certbot (Let's Encrypt)
#  12. Final summary
#
# =============================================================================

# -----------------------------------------------------------------------------
# STRICT MODE
# -----------------------------------------------------------------------------
# -e : Exit immediately if any command fails (non-zero exit code).
# -u : Treat unset variables as errors. Prevents typos like $UNDFINED from
#      silently expanding to an empty string.
# -o pipefail : In a pipeline (cmd1 | cmd2), the exit code is that of the
#               LAST command that failed, not just the final one. Without this,
#               "false | true" would succeed silently.
set -euo pipefail

# -----------------------------------------------------------------------------
# CONFIGURATION — override any of these with environment variables
# -----------------------------------------------------------------------------
NEW_USER="${NEW_USER:-admin}"
NEW_USER_PASSWORD="${NEW_USER_PASSWORD:-}"  # Empty = no password, key-only auth
SSH_PORT="${SSH_PORT:-22}"                  # Change to a non-standard port if desired
TIMEZONE="${TIMEZONE:-UTC}"                 # e.g. "Europe/Rome"
SKIP_SNAP="${SKIP_SNAP:-0}"                # Set to 1 to skip snap/certbot-via-snap

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# section_header: prints a visible banner so you can follow progress in the
# terminal output. Each major block of work gets one of these.
section_header() {
    echo ""
    echo "================================================================================"
    echo "  $1"
    echo "================================================================================"
    echo ""
}

# check_root: this script must run as root because it modifies system config,
# installs packages, and creates users. We check early to give a clear error.
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: This script must be run as root." >&2
        exit 1
    fi
}

check_root

# =============================================================================
# 1. SYSTEM UPDATES
# =============================================================================
section_header "1. SYSTEM UPDATES"

# DEBIAN_FRONTEND=noninteractive prevents apt from popping up interactive
# dialogs (e.g. "A new version of /etc/grub.d/10_linux is available, what
# would you like to do?"). Without this, the script can hang forever waiting
# for input that never comes.
#
# --force-confdef : Keep the current config file if the maintainer hasn't
#                   changed the default; otherwise ask (but noninteractive
#                   means "keep current").
# --force-confold : If in doubt, always keep the old (currently installed)
#                   version of a config file.
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"

echo "System packages updated."

# =============================================================================
# 2. ESSENTIAL PACKAGES
# =============================================================================
section_header "2. INSTALLING ESSENTIAL PACKAGES"

# What each package is for:
#   nginx          — Web server / reverse proxy
#   rsync          — Efficient file transfer & sync (deployments, backups)
#   git            — Version control
#   htop           — Interactive process viewer (better than top)
#   vim            — Text editor
#   ca-certificates— Root certificates so HTTPS connections work
#   curl           — HTTP client for downloading things
#   snapd          — Snap package manager (needed for certbot)
#   ufw            — Uncomplicated Firewall (iptables frontend)
#   fail2ban       — Intrusion prevention (bans IPs after failed logins)
#   unattended-upgrades — Automatic security patches
#   apt-listchanges — Summarizes changelogs during upgrades
#   chrony         — NTP client for time synchronization (lighter than ntpd)
#   logrotate      — Manages log file rotation (usually pre-installed)
BASE_PACKAGES=(
    nginx
    rsync
    git
    htop
    vim
    ca-certificates
    curl
    ufw
    fail2ban
    unattended-upgrades
    apt-listchanges
    chrony
    logrotate
)
if [ "$SKIP_SNAP" -eq 0 ]; then
    BASE_PACKAGES+=(snapd)
fi
apt-get install -y "${BASE_PACKAGES[@]}"

echo "All packages installed."

# =============================================================================
# 3. TIMEZONE & NTP (TIME SYNCHRONIZATION)
# =============================================================================
section_header "3. TIMEZONE & NTP CONFIGURATION"

# Why this matters:
#   - TLS/SSL certificates have validity windows. If your clock drifts, HTTPS
#     connections fail with mysterious "certificate not yet valid" errors.
#   - Cron jobs run at wrong times.
#   - Log timestamps become unreliable, making incident investigation painful.
#   - Certbot renewal checks can misbehave.
#
# Chrony is preferred over ntpd because it's faster at correcting drift,
# handles intermittent connectivity better, and uses less memory.

if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone "$TIMEZONE"
fi
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable chrony
    systemctl start chrony
fi

echo "Timezone set to $TIMEZONE. Chrony NTP enabled."

# =============================================================================
# 4. USER CREATION & SSH KEY SETUP
# =============================================================================
section_header "4. CREATING USER: $NEW_USER"

# Why a non-root user?
#   Root has UID 0 and unlimited power. A typo like "rm -rf / tmp" (note the
#   space) can destroy the entire system. Using a regular user + sudo means:
#   - You must explicitly opt in to privilege with "sudo"
#   - Actions are logged in /var/log/auth.log
#   - If the account is compromised, damage is limited (without sudo password)

# --disabled-password : No password is set, which means the user cannot log in
#                       via password. They MUST use SSH keys.
# --gecos ""          : Skip the interactive "Full Name, Room Number..." prompts.
if ! id -u "$NEW_USER" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$NEW_USER"
    echo "User '$NEW_USER' created."
else
    echo "User '$NEW_USER' already exists, skipping creation."
fi

# If a password was provided, set it. This is useful if you want Option B
# (password required for sudo but not for SSH). If left empty, the user is
# key-only and we'll configure NOPASSWD sudo below.
if [ -n "$NEW_USER_PASSWORD" ]; then
    # We use a here-string (<<<) instead of echo|pipe because:
    #   echo "user:pass" | chpasswd
    # exposes the password in /proc/<pid>/cmdline to any user on the system.
    # The here-string is passed directly to chpasswd's stdin by the shell,
    # without spawning a separate echo process.
    chpasswd <<< "$NEW_USER:$NEW_USER_PASSWORD"
    echo "Password set for '$NEW_USER'."
else
    echo "No password set. User '$NEW_USER' will use key-only authentication."
fi

# Add to sudo group so the user can run privileged commands.
usermod -aG sudo "$NEW_USER"

# --- SSH Key Setup ---
# We copy root's authorized_keys to the new user so whoever provisioned the
# server (you) can SSH in as the new user immediately.

SSH_DIR="/home/$NEW_USER/.ssh"
mkdir -p "$SSH_DIR"

# chmod 700: only the owner can read/write/enter this directory.
# OpenSSH is very strict about .ssh permissions — if the directory is
# group-writable or world-readable, SSH silently ignores the keys inside.
chmod 700 "$SSH_DIR"

if [ -f /root/.ssh/authorized_keys ]; then
    cp /root/.ssh/authorized_keys "$SSH_DIR/authorized_keys"
    # chmod 600: only the owner can read/write. Again, SSH demands this.
    chmod 600 "$SSH_DIR/authorized_keys"
    echo "SSH authorized_keys copied from root to '$NEW_USER'."
else
    # This is critical! If there are no SSH keys AND we're about to disable
    # password auth in SSH, the new user will have NO way to log in.
    echo "================================================================" >&2
    echo "  WARNING: /root/.ssh/authorized_keys not found!" >&2
    echo "  The user '$NEW_USER' will have NO SSH key access." >&2
    echo "  Make sure to add keys manually before disabling password auth." >&2
    echo "================================================================" >&2
fi

# Ensure the home directory and everything inside belongs to the user.
# Without this, SSH may refuse to use the key files (wrong ownership).
chown -R "$NEW_USER":"$NEW_USER" "/home/$NEW_USER"

# =============================================================================
# 5. SUDO CONFIGURATION
# =============================================================================
section_header "5. CONFIGURING SUDO ACCESS"

# The sudo decision tree:
#
#   Was a password set?
#     YES → sudo will prompt for that password (default behavior).
#           This is "Option B" — an extra layer if someone hijacks your session.
#     NO  → We MUST configure NOPASSWD, otherwise the user literally cannot
#           use sudo (there's no password to type). This is "Option A" — common
#           on cloud VPS images (AWS, GCP, DigitalOcean all do this).
#
# We write to /etc/sudoers.d/<username> instead of editing /etc/sudoers directly
# because:
#   - It's modular: each user gets their own file
#   - It survives system upgrades that might overwrite /etc/sudoers
#   - It's easier to remove: just delete the file
#
# visudo -cf validates the syntax. A broken sudoers file can lock you out of
# sudo entirely, which on a remote server means you're done.

SUDOERS_FILE="/etc/sudoers.d/$NEW_USER"

if [ -z "$NEW_USER_PASSWORD" ]; then
    echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
    echo "NOPASSWD sudo configured (no password was set)."
else
    # If a password exists, require it for sudo (default behavior).
    # We still create the sudoers.d file for explicitness and documentation.
    echo "$NEW_USER ALL=(ALL:ALL) ALL" > "$SUDOERS_FILE"
    echo "Password-required sudo configured."
fi

# chmod 440: read-only for root and the sudo group. sudoers files MUST be
# 0440 or sudo will refuse to read them (security measure).
chmod 440 "$SUDOERS_FILE"

# Validate syntax — if this fails, we remove the file to avoid lockout.
if ! visudo -cf "$SUDOERS_FILE"; then
    echo "ERROR: sudoers syntax validation failed! Removing bad file." >&2
    rm -f "$SUDOERS_FILE"
    exit 1
fi

echo "Sudo configured and validated."

# =============================================================================
# 6. SSH HARDENING
# =============================================================================
section_header "6. HARDENING SSH"

# SSH is the front door to your server. Every default you don't tighten is an
# invitation. Here's what each setting does:
#
# PermitRootLogin no
#   → Disables SSH login as root entirely. Attackers LOVE to brute-force root
#     because it's a known username on every Linux box. Force them to guess
#     both the username AND the key.
#
# PasswordAuthentication no
#   → Disables password-based SSH login. Keys are cryptographically strong
#     (4096-bit RSA or Ed25519). Passwords are guessable. This single setting
#     stops 99% of brute-force attacks.
#
# KbdInteractiveAuthentication no
#   → Disables "keyboard-interactive" auth, which is another way to do
#     password-based login that bypasses the PasswordAuthentication setting.
#     You need to disable BOTH.
#
# X11Forwarding no
#   → X11 is the Linux GUI system. Forwarding it over SSH opens an attack
#     surface for zero benefit on a headless server.
#
# MaxAuthTries 3
#   → After 3 failed attempts, the connection is dropped. Slows down
#     brute-force attacks (fail2ban handles the rest).
#
# AllowAgentForwarding no
#   → Agent forwarding lets your local SSH keys be used through the server
#     to connect elsewhere. Handy, but if the server is compromised, the
#     attacker can use your forwarded agent to access other machines.
#
# AllowUsers $NEW_USER
#   → Whitelist: ONLY this user can SSH in. Even if other system users exist
#     (www-data, postgres, etc.), they can't be used for SSH access.
#
# Port $SSH_PORT
#   → Changing from 22 doesn't add real security (security through obscurity)
#     but it dramatically reduces log noise from automated scanners.

SSHD_CONFIG="/etc/ssh/sshd_config"

if [ -f "$SSHD_CONFIG" ]; then
    # Back up the original config so you can diff or restore if needed.
    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

    # We use sed to find and replace (or uncomment) each directive.
    # The regex ^#\? matches lines that are either commented out or active.
    sed -i "s/^#\?Port .*/Port $SSH_PORT/" "$SSHD_CONFIG"
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
    sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' "$SSHD_CONFIG"
    sed -i 's/^#\?X11Forwarding.*/X11Forwarding no/' "$SSHD_CONFIG"
    sed -i 's/^#\?MaxAuthTries.*/MaxAuthTries 3/' "$SSHD_CONFIG"
    sed -i 's/^#\?AllowAgentForwarding.*/AllowAgentForwarding no/' "$SSHD_CONFIG"

    # AllowUsers might not exist in the default config, so we append it.
    # First remove any existing AllowUsers line, then add ours at the end.
    sed -i '/^AllowUsers/d' "$SSHD_CONFIG"
    echo "AllowUsers $NEW_USER" >> "$SSHD_CONFIG"

    # Validate the config before restarting. A syntax error here = you get
    # locked out on next disconnect. sshd -t does a dry-run parse.
    if sshd -t; then
        systemctl restart sshd
        echo "SSH hardened and restarted on port $SSH_PORT."
    else
        echo "ERROR: sshd config validation failed! Restoring backup." >&2
        cp "${SSHD_CONFIG}.bak."* "$SSHD_CONFIG" 2>/dev/null
        systemctl restart sshd
        exit 1
    fi
else
    echo "SSHD config not found, skipping SSH hardening."
fi

# =============================================================================
# 7. FIREWALL (UFW)
# =============================================================================
section_header "7. CONFIGURING FIREWALL (UFW)"

# UFW = "Uncomplicated Firewall". It's a friendly wrapper around iptables
# (the low-level Linux firewall). The principle is simple:
#
#   DENY everything incoming by default, then punch holes only for what you need.
#
# This means if you accidentally install a service that listens on port 5432
# (PostgreSQL), it's NOT reachable from the internet unless you explicitly allow it.
#
# "default allow outgoing" lets the server make outbound connections (apt updates,
# DNS lookups, API calls, etc.).

if command -v ufw >/dev/null 2>&1; then
    ufw default deny incoming
    ufw default allow outgoing

    # Allow SSH — CRITICAL: if you forget this, UFW locks you out the moment it
    # enables. We use the variable in case you changed the port above.
    ufw allow "$SSH_PORT/tcp" comment "SSH"

    # Allow HTTP (needed for Let's Encrypt ACME challenges during cert issuance)
    ufw allow 80/tcp comment "HTTP"

    # Allow HTTPS (your actual web traffic)
    ufw allow 443/tcp comment "HTTPS"

    # --force skips the "are you sure?" interactive prompt.
    ufw --force enable

    echo "UFW enabled. Allowed ports: $SSH_PORT (SSH), 80 (HTTP), 443 (HTTPS)."
else
    echo "UFW not found, skipping firewall configuration."
fi

# =============================================================================
# 8. FAIL2BAN (BRUTE-FORCE PROTECTION)
# =============================================================================
section_header "8. CONFIGURING FAIL2BAN"

# Fail2ban watches log files for patterns of failed authentication and
# automatically bans the offending IP addresses using iptables/nftables.
#
# How it works:
#   1. It monitors /var/log/auth.log (for SSH) and other log files
#   2. When it sees "findtime" seconds with "maxretry" failures from one IP...
#   3. ...it adds a firewall rule to DROP all traffic from that IP
#   4. After "bantime" seconds, the ban is lifted automatically
#
# We write to jail.local (not jail.conf) because:
#   - jail.conf is the package default and gets overwritten on upgrades
#   - jail.local overrides jail.conf and survives upgrades

cat > /etc/fail2ban/jail.local << EOF
# jail.local — custom overrides for fail2ban
# This file takes precedence over jail.conf

[DEFAULT]
# Ban duration: 1 hour. Long enough to deter attackers, short enough that
# if you accidentally ban yourself, you're not locked out forever.
bantime  = 3600

# Observation window: look at the last 10 minutes of logs.
findtime = 600

# Threshold: 5 failures within the findtime window triggers a ban.
maxretry = 5

# Use UFW as the ban action since we're already using it as our firewall.
# This keeps all firewall rules in one system instead of mixing ufw + raw iptables.
banaction = ufw

[sshd]
enabled  = true
port     = $SSH_PORT
logpath  = /var/log/auth.log
maxretry = 3

# nginx jails — enable these if you use HTTP basic auth or have login pages
[nginx-http-auth]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/error.log
maxretry = 5

[nginx-botsearch]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/access.log
maxretry = 2
EOF

if command -v systemctl >/dev/null 2>&1; then
    systemctl enable fail2ban
    systemctl restart fail2ban
fi

echo "Fail2ban configured and running."

# =============================================================================
# 9. KERNEL & NETWORK HARDENING (SYSCTL)
# =============================================================================
section_header "9. KERNEL & NETWORK HARDENING"

# sysctl controls kernel parameters at runtime. These settings harden the
# TCP/IP stack against common network attacks. They're loaded at boot from
# files in /etc/sysctl.d/.
#
# Think of these as low-level immune system tweaks for the networking layer.

cat > /etc/sysctl.d/99-hardening.conf << 'EOF'
# --- IP Spoofing Protection ---
# Reverse Path Filtering: the kernel checks if the source IP of an incoming
# packet could actually be reached via the interface it arrived on. If not,
# the packet is dropped. This prevents IP spoofing attacks.
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# --- Smurf Attack Protection ---
# Ignore ICMP echo requests sent to broadcast addresses. "Smurf attacks"
# send pings to broadcast addresses with your IP as the source, causing
# every host on the network to reply to you simultaneously (amplification).
net.ipv4.icmp_echo_ignore_broadcasts = 1

# --- ICMP Redirect Protection ---
# ICMP redirects tell your server "hey, use this other router instead".
# Attackers use this to redirect your traffic through their machine (MITM).
# On a server, you know your routes — you don't need random packets changing them.
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# --- Source Routing Protection ---
# Source-routed packets specify their own path through the network. This is
# a debugging feature that attackers abuse to bypass firewalls.
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# --- SYN Flood Protection ---
# SYN cookies: when the SYN backlog is full (potential SYN flood attack),
# the kernel uses a cryptographic technique to handle new connections without
# allocating resources until the handshake completes. This prevents denial
# of service from half-open connections.
net.ipv4.tcp_syncookies = 1

# --- ASLR (Address Space Layout Randomization) ---
# Randomizes the memory layout of processes. Makes buffer overflow exploits
# much harder because the attacker can't predict where code/data lives.
# 2 = full randomization (stack, heap, libraries, mmap, etc.)
kernel.randomize_va_space = 2

# --- Log Suspicious Packets ---
# Log packets with impossible addresses (helps detect attacks/misconfigs).
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
EOF

# Apply all sysctl settings immediately (normally they load at next boot).
sysctl --system > /dev/null 2>&1

echo "Kernel and network hardening applied."

# =============================================================================
# 10. UNATTENDED SECURITY UPGRADES
# =============================================================================
section_header "10. CONFIGURING AUTOMATIC SECURITY UPDATES"

# The biggest risk to a running server isn't a sophisticated zero-day —
# it's a known CVE that was patched weeks ago but never applied because
# nobody logged in to run "apt upgrade".
#
# unattended-upgrades automatically installs security patches daily.
# It only touches packages from the security pocket, so it won't randomly
# upgrade your nginx to a new major version.

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
// Check for new package lists once a day.
APT::Periodic::Update-Package-Lists "1";

// Install security updates automatically once a day.
APT::Periodic::Unattended-Upgrade "1";

// Clean up downloaded .deb files every 7 days to save disk space.
APT::Periodic::AutocleanInterval "7";
EOF

# The 50unattended-upgrades file controls WHAT gets auto-upgraded.
# We ensure only security updates are enabled (the default on Ubuntu,
# but being explicit is safer).
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

// Automatically reboot at 4 AM if a kernel update requires it.
// Set to "false" if you prefer to reboot manually.
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";

// Remove unused kernel packages after upgrade to free disk space.
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

if command -v systemctl >/dev/null 2>&1; then
    systemctl enable unattended-upgrades
    systemctl restart unattended-upgrades
fi

echo "Automatic security updates configured."

# =============================================================================
# 11. CERTBOT (LET'S ENCRYPT SSL)
# =============================================================================
section_header "11. INSTALLING CERTBOT"

# Certbot automates getting free TLS/SSL certificates from Let's Encrypt.
# We install it via snap (not apt) because:
#   - The snap version is maintained by the Certbot team directly
#   - It updates automatically
#   - The apt version in older Ubuntu repos can be severely outdated
#
# snap wait: snapd needs time to "seed" (initialize) after installation.
# Without this, "snap install" can fail with "too early for operation, device
# not yet seeded" on fresh servers.

if [ "$SKIP_SNAP" -eq 0 ]; then
    snap wait system seed.loaded
    snap install --classic certbot

    # ln -sf: create a symlink so you can type "certbot" instead of "/snap/bin/certbot".
    # The -f (force) flag means it overwrites an existing symlink, making the script
    # safe to run multiple times (idempotent).
    ln -sf /snap/bin/certbot /usr/bin/certbot
else
    apt-get install -y certbot
fi

echo "Certbot installed. Run 'certbot --nginx -d yourdomain.com' to get a certificate."

# =============================================================================
# 12. FINAL SUMMARY
# =============================================================================
section_header "SETUP COMPLETE"

# Gather a quick status report so you can verify everything worked.
cat << EOF
Server initialization complete! Here's what was configured:

  User:           $NEW_USER (sudo access)
  SSH Port:       $SSH_PORT
  Root Login:     DISABLED
  Password Auth:  DISABLED (key-only)
  Firewall:       UFW active (ports $SSH_PORT, 80, 443)
  Fail2ban:       Active (SSH + nginx jails)
  Auto Updates:   Enabled (security patches)
  NTP:            Chrony (timezone: $TIMEZONE)
  Certbot:        Installed via snap

  ┌────────────────────────────────────────────────────────┐
  │  IMPORTANT NEXT STEPS:                                 │
  │                                                        │
  │  1. Test SSH access as '$NEW_USER' BEFORE closing      │
  │     this session:                                      │
  │       ssh -p $SSH_PORT $NEW_USER@<server-ip>           │
  │                                                        │
  │  2. Set up your nginx server blocks                    │
  │                                                        │
  │  3. Run certbot to get SSL certificates:               │
  │       sudo certbot --nginx -d yourdomain.com           │
  │                                                        │
  │  4. Verify fail2ban is running:                        │
  │       sudo fail2ban-client status sshd                 │
  │                                                        │
  │  5. Check firewall rules:                              │
  │       sudo ufw status verbose                          │
  └────────────────────────────────────────────────────────┘
EOF