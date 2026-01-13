#! /bin/bash

set -eu

NEW_USER=${NEW_USER:-admin}
SKIP_SNAP=${SKIP_SNAP:-0}

# Basics
apt update && apt upgrade -y
BASE_PACKAGES=(nginx git htop vim zsh ca-certificates curl)
if [ "$SKIP_SNAP" -eq 0 ]; then
    BASE_PACKAGES+=(snapd)
fi
apt install -y "${BASE_PACKAGES[@]}"

# Create user
adduser "$NEW_USER"
usermod -aG sudo "$NEW_USER"
mkdir -p "/home/$NEW_USER/.ssh"
cat /root/.ssh/authorized_keys > "/home/$NEW_USER/.ssh/authorized_keys"

# SSL Certificates
if [ "$SKIP_SNAP" -eq 0 ]; then
    snap install --classic certbot
    ln -s /snap/bin/certbot /usr/bin/certbot
else
    apt install -y certbot
fi

# Docker
REMOVE_PKGS=()
for pkg in docker.io docker-compose docker-doc podman-docker containerd runc; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        REMOVE_PKGS+=("$pkg")
    fi
done
if [ "${#REMOVE_PKGS[@]}" -gt 0 ]; then
    apt remove -y "${REMOVE_PKGS[@]}"
fi
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt update
apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
groupadd docker
usermod -aG docker $NEW_USER

# Oh My Zsh
sh -c "$(wget https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -O -)"
chsh -s /usr/bin/zsh $NEW_USER
wget https://raw.githubusercontent.com/aris997/dotfiles/refs/heads/main/zsh/themes/rivar.zsh-theme
mv {,/home/$NEW_USER/.oh-my-zsh/custom/}rivar.zsh-theme
wget https://raw.githubusercontent.com/aris997/dotfiles/refs/heads/main/zsh/.zshrc
if [[ -n /home/$NEW_USER/.oh-my-zsh/custom/secrets.zsh ]]; then
    mkdir -p /home/$NEW_USER/.oh-my-zsh/custom
    echo "# secrets.zsh" > /home/$NEW_USER/.oh-my-zsh/custom/secrets.zsh
fi
mv {,/home/$NEW_USER/}.zshrc

echo 'Done.'
echo 'You have now nginx, docker, snap, certbot.'
