#! /bin/bash

NEW_USER=admin

# Error handling
# -e: raise error as soon as a command returns 1
# -u: raise error if a variable is unset while fulfilling a string
set -eu

# Basics
apt update && apt upgrade -y
apt install -y nginx snapd htop vim zsh ca-certificates curl

# Create user admin
adduser $NEW_USER
usermod -aG sudo $NEW_USER
mkdir -p /home/$NEW_USER/.ssh
cat /root/.ssh/authorized_keys > /home/$NEW_USER/.ssh/authorized_keys

# SSL Certifies
snap install --classic certbot
ln -s /snap/bin/certbot /usr/bin/certbot

# Docker
apt remove $(dpkg --get-selections docker.io docker-compose docker-doc podman-docker containerd runc | cut -f1)
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

apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
groupadd docker
usermod -aG docker $NEW_USER

# Oh My Zsh
wget https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -O install-zsh.sh
sh -c install-zsh.sh
chsh -s /usr/bin/zsh $NEW_USER
wget https://raw.githubusercontent.com/aris997/dotfiles/refs/heads/main/zsh/themes/rivar.zsh-theme
mv {,/home/$NEW_USER/oh-my-zsh/custom/}rivar.zsh-theme
wget https://raw.githubusercontent.com/aris997/dotfiles/refs/heads/main/zsh/.zshrc
if [[ -n /home/$NEW_USER/.oh-my-zsh/custom/secrets.zsh ]]; then
    mkdir -p /home/$NEW_USER/.oh-my-zsh/custom
    echo "# secrets.zsh" > /home/$NEW_USER/.oh-my-zsh/custom/secrets.zsh
fi
mv {,/home/$NEW_USER/}.zshrc

echo 'Done.'
echo 'You have now nginx, docker, snap, certbot.'

