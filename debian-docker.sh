#!/bin/bash
# =============================================================================
# SERVER INITIALIZATION SCRIPT (DOCKER EDITION)
# =============================================================================
#
# Purpose:  Set up a fresh Debian/Ubuntu server with security hardening,
#           a non-root admin user, Docker, nginx, certbot, Oh My Zsh,
#           and essential tooling.
#
# Usage:    Run as root on a fresh server:
#               sudo bash debian-docker.sh
#
#           You can override defaults with environment variables:
#               NEW_USER=ricc NEW_USER_PASSWORD=supersecret bash debian-docker.sh
#
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
#  12. Docker
#  13. Oh My Zsh
#  14. Final summary
#
# =============================================================================

# -----------------------------------------------------------------------------
# STRICT MODE
# -----------------------------------------------------------------------------
# -e : Exit immediately if any command fails (non-zero exit code).
# -u : Treat unset variables as errors.
# -o pipefail : In a pipeline, the exit code is that of the LAST command that
#               failed, not just the final one.
set -euo pipefail

# -----------------------------------------------------------------------------
# CONFIGURATION — override any of these with environment variables
# -----------------------------------------------------------------------------
NEW_USER="${NEW_USER:-admin}"
NEW_USER_PASSWORD="${NEW_USER_PASSWORD:-}"   # Empty = no password, key-only auth
SSH_PORT="${SSH_PORT:-22}"                   # Change to a non-standard port if desired
TIMEZONE="${TIMEZONE:-UTC}"                  # e.g. "Europe/Rome"
SKIP_SNAP="${SKIP_SNAP:-0}"
SKIP_DOCKER="${SKIP_DOCKER:-0}"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

section_header() {
    echo ""
    echo "================================================================================"
    echo "  $1"
    echo "================================================================================"
    echo ""
}

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
# dialogs. --force-confdef/--force-confold keep existing config files.
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

BASE_PACKAGES=(
    nginx
    rsync
    git
    htop
    vim
    zsh
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

# Accurate time is critical for TLS certificates, cron jobs, and log analysis.
# Chrony is preferred over ntpd: faster drift correction, less memory.
timedatectl set-timezone "$TIMEZONE"
systemctl enable chrony
systemctl start chrony

echo "Timezone set to $TIMEZONE. Chrony NTP enabled."

# =============================================================================
# 4. USER CREATION & SSH KEY SETUP
# =============================================================================
section_header "4. CREATING USER: $NEW_USER"

if ! id -u "$NEW_USER" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$NEW_USER"
    echo "User '$NEW_USER' created."
else
    echo "User '$NEW_USER' already exists, skipping creation."
fi

# Set password via here-string instead of echo|pipe to avoid exposing the
# password in /proc/<pid>/cmdline.
if [ -n "$NEW_USER_PASSWORD" ]; then
    chpasswd <<< "$NEW_USER:$NEW_USER_PASSWORD"
    echo "Password set for '$NEW_USER'."
else
    echo "No password set. User '$NEW_USER' will use key-only authentication."
fi

usermod -aG sudo "$NEW_USER"

# --- SSH Key Setup ---
SSH_DIR="/home/$NEW_USER/.ssh"
mkdir -p "$SSH_DIR"

# chmod 700: only the owner can read/write/enter. OpenSSH silently ignores
# keys if .ssh permissions are too open.
chmod 700 "$SSH_DIR"

if [ -f /root/.ssh/authorized_keys ]; then
    cp /root/.ssh/authorized_keys "$SSH_DIR/authorized_keys"
    chmod 600 "$SSH_DIR/authorized_keys"
    echo "SSH authorized_keys copied from root to '$NEW_USER'."
else
    echo "================================================================" >&2
    echo "  WARNING: /root/.ssh/authorized_keys not found!" >&2
    echo "  The user '$NEW_USER' will have NO SSH key access." >&2
    echo "  Make sure to add keys manually before disabling password auth." >&2
    echo "================================================================" >&2
fi

chown -R "$NEW_USER":"$NEW_USER" "/home/$NEW_USER"

# =============================================================================
# 5. SUDO CONFIGURATION
# =============================================================================
section_header "5. CONFIGURING SUDO ACCESS"

# If no password was set, we MUST configure NOPASSWD — otherwise the user
# cannot use sudo at all (there's no password to type).
SUDOERS_FILE="/etc/sudoers.d/$NEW_USER"

if [ -z "$NEW_USER_PASSWORD" ]; then
    echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
    echo "NOPASSWD sudo configured (no password was set)."
else
    echo "$NEW_USER ALL=(ALL:ALL) ALL" > "$SUDOERS_FILE"
    echo "Password-required sudo configured."
fi

# chmod 440: sudo refuses to read files with other permissions.
chmod 440 "$SUDOERS_FILE"

# Validate syntax — if this fails, remove the file to avoid lockout.
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

SSHD_CONFIG="/etc/ssh/sshd_config"

# Back up the original config.
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

# Harden each directive:
#   PermitRootLogin no          — Force attackers to guess username + key
#   PasswordAuthentication no   — Keys only; stops 99% of brute-force
#   KbdInteractiveAuthentication no — Closes the other password auth path
#   X11Forwarding no            — No GUI forwarding on a headless server
#   MaxAuthTries 3              — Drop connection after 3 failures
#   AllowAgentForwarding no     — Prevent agent hijacking if server is compromised
sed -i "s/^#\?Port .*/Port $SSH_PORT/" "$SSHD_CONFIG"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' "$SSHD_CONFIG"
sed -i 's/^#\?X11Forwarding.*/X11Forwarding no/' "$SSHD_CONFIG"
sed -i 's/^#\?MaxAuthTries.*/MaxAuthTries 3/' "$SSHD_CONFIG"
sed -i 's/^#\?AllowAgentForwarding.*/AllowAgentForwarding no/' "$SSHD_CONFIG"

# AllowUsers whitelist — ONLY this user can SSH in.
sed -i '/^AllowUsers/d' "$SSHD_CONFIG"
echo "AllowUsers $NEW_USER" >> "$SSHD_CONFIG"

# Validate before restarting. A syntax error here = lockout.
if sshd -t; then
    systemctl restart sshd
    echo "SSH hardened and restarted on port $SSH_PORT."
else
    echo "ERROR: sshd config validation failed! Restoring backup." >&2
    cp "${SSHD_CONFIG}.bak."* "$SSHD_CONFIG" 2>/dev/null
    systemctl restart sshd
    exit 1
fi

# =============================================================================
# 7. FIREWALL (UFW)
# =============================================================================
section_header "7. CONFIGURING FIREWALL (UFW)"

ufw default deny incoming
ufw default allow outgoing

ufw allow "$SSH_PORT/tcp" comment "SSH"
ufw allow 80/tcp comment "HTTP"
ufw allow 443/tcp comment "HTTPS"

ufw --force enable

echo "UFW enabled. Allowed ports: $SSH_PORT (SSH), 80 (HTTP), 443 (HTTPS)."

# =============================================================================
# 8. FAIL2BAN (BRUTE-FORCE PROTECTION)
# =============================================================================
section_header "8. CONFIGURING FAIL2BAN"

cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
banaction = ufw

[sshd]
enabled  = true
port     = $SSH_PORT
logpath  = /var/log/auth.log
maxretry = 3

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

systemctl enable fail2ban
systemctl restart fail2ban

echo "Fail2ban configured and running."

# =============================================================================
# 9. KERNEL & NETWORK HARDENING (SYSCTL)
# =============================================================================
section_header "9. KERNEL & NETWORK HARDENING"

cat > /etc/sysctl.d/99-hardening.conf << 'EOF'
# IP Spoofing Protection (Reverse Path Filtering)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Smurf Attack Protection
net.ipv4.icmp_echo_ignore_broadcasts = 1

# ICMP Redirect Protection (prevent MITM via route manipulation)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# Source Routing Protection
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# SYN Flood Protection
net.ipv4.tcp_syncookies = 1

# ASLR — full randomization (stack, heap, libraries, mmap)
kernel.randomize_va_space = 2

# Log packets with impossible addresses
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
EOF

sysctl --system > /dev/null 2>&1

echo "Kernel and network hardening applied."

# =============================================================================
# 10. UNATTENDED SECURITY UPGRADES
# =============================================================================
section_header "10. CONFIGURING AUTOMATIC SECURITY UPDATES"

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

systemctl enable unattended-upgrades
systemctl restart unattended-upgrades

echo "Automatic security updates configured."

# =============================================================================
# 11. CERTBOT (LET'S ENCRYPT SSL)
# =============================================================================
section_header "11. INSTALLING CERTBOT"

if [ "$SKIP_SNAP" -eq 0 ]; then
    snap wait system seed.loaded
    snap install --classic certbot
    ln -sf /snap/bin/certbot /usr/bin/certbot
else
    apt-get install -y certbot
fi

echo "Certbot installed. Run 'certbot --nginx -d yourdomain.com' to get a certificate."

# =============================================================================
# 12. DOCKER
# =============================================================================
section_header "12. DOCKER INSTALLATION"

if [ "$SKIP_DOCKER" -eq 0 ]; then
    REMOVE_PKGS=()
    for pkg in docker.io docker-compose docker-doc podman-docker containerd runc; do
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            REMOVE_PKGS+=("$pkg")
        fi
    done
    if [ "${#REMOVE_PKGS[@]}" -gt 0 ]; then
        apt-get remove -y "${REMOVE_PKGS[@]}"
    fi
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    # shellcheck source=/etc/os-release disable=SC1091
    . /etc/os-release
    CODENAME="${VERSION_CODENAME:-bookworm}"
    tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $CODENAME
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    groupadd docker || true
    usermod -aG docker "$NEW_USER"
    echo "Docker installed and '$NEW_USER' added to docker group."
else
    echo "SKIP_DOCKER=1, skipping Docker installation."
fi

# =============================================================================
# 13. OH MY ZSH
# =============================================================================
section_header "13. OH MY ZSH"

export ZSH="/home/$NEW_USER/.oh-my-zsh"
export RUNZSH=no
export CHSH=no
sh -c "$(wget https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -O -)"
chsh -s /usr/bin/zsh "$NEW_USER"
mkdir -p "/home/$NEW_USER/.oh-my-zsh/custom/themes"
wget -O "/home/$NEW_USER/.oh-my-zsh/custom/themes/rivar.zsh-theme" https://raw.githubusercontent.com/aris997/dotfiles/refs/heads/main/zsh/themes/rivar.zsh-theme
wget -O "/home/$NEW_USER/.zshrc" https://raw.githubusercontent.com/aris997/dotfiles/refs/heads/main/zsh/.zshrc
if [ ! -f "/home/$NEW_USER/.oh-my-zsh/custom/secrets.zsh" ]; then
    echo "# secrets.zsh" > "/home/$NEW_USER/.oh-my-zsh/custom/secrets.zsh"
fi
chown -R "$NEW_USER":"$NEW_USER" "/home/$NEW_USER"

echo "Oh My Zsh installed and configured."

# =============================================================================
# 14. FINAL SUMMARY
# =============================================================================
section_header "SETUP COMPLETE"

DOCKER_STATUS="Installed"
if [ "$SKIP_DOCKER" -eq 1 ]; then
    DOCKER_STATUS="Skipped"
fi

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
  Certbot:        Installed
  Docker:         $DOCKER_STATUS
  Shell:          Zsh + Oh My Zsh

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
