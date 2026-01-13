#! /bin/bash

set -eu

NEW_USER=${NEW_USER:-admin}
SKIP_SNAP=${SKIP_SNAP:-0}
SKIP_DOCKER=${SKIP_DOCKER:-0}
NEW_USER_PASSWORD=${NEW_USER_PASSWORD:-}

# Basics
apt-get update && apt-get upgrade -y
BASE_PACKAGES=(nginx git htop vim zsh ca-certificates curl)
if [ "$SKIP_SNAP" -eq 0 ]; then
    BASE_PACKAGES+=(snapd)
fi
apt-get install -y "${BASE_PACKAGES[@]}"

# Create user
if ! id -u "$NEW_USER" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$NEW_USER"
fi
if [ -n "$NEW_USER_PASSWORD" ]; then
    echo "$NEW_USER:$NEW_USER_PASSWORD" | chpasswd
fi
usermod -aG sudo "$NEW_USER"
mkdir -p "/home/$NEW_USER/.ssh"
if [ -f /root/.ssh/authorized_keys ]; then
    cat /root/.ssh/authorized_keys > "/home/$NEW_USER/.ssh/authorized_keys"
    chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"
fi

# SSL Certificates
if [ "$SKIP_SNAP" -eq 0 ]; then
    snap install --classic certbot
    ln -s /snap/bin/certbot /usr/bin/certbot
else
    apt-get install -y certbot
fi

# Docker
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
fi

# Oh My Zsh
sh -c "$(wget https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -O -)"
chsh -s /usr/bin/zsh "$NEW_USER"
wget https://raw.githubusercontent.com/aris997/dotfiles/refs/heads/main/zsh/themes/rivar.zsh-theme
mkdir -p "/home/$NEW_USER/.oh-my-zsh/custom"
mv {,/home/"$NEW_USER"/.oh-my-zsh/custom/}rivar.zsh-theme
wget https://raw.githubusercontent.com/aris997/dotfiles/refs/heads/main/zsh/.zshrc
if [ ! -f "/home/$NEW_USER/.oh-my-zsh/custom/secrets.zsh" ]; then
    mkdir -p "/home/$NEW_USER/.oh-my-zsh/custom"
    echo "# secrets.zsh" > "/home/$NEW_USER/.oh-my-zsh/custom/secrets.zsh"
fi
mv {,/home/"$NEW_USER"/}.zshrc
chown -R "$NEW_USER":"$NEW_USER" "/home/$NEW_USER"

echo 'Done.'
echo 'You have now nginx, docker, snap, certbot.'
