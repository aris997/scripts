#! /bin/bash

set -eu

NEW_USER=${NEW_USER:-admin}
NEW_USER_PASSWORD=${NEW_USER_PASSWORD:-}

# Basics
apt-get update && apt-get upgrade -y
apt-get install -y nginx git htop vim ca-certificates curl snapd

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
chown -R "$NEW_USER":"$NEW_USER" "/home/$NEW_USER"

# SSL Certificates
snap install --classic certbot
ln -s /snap/bin/certbot /usr/bin/certbot

echo 'Done.'
echo 'You have now nginx, snap, and certbot.'
