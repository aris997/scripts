# Ignition Scripts

## Basics, certbot (snap), nginx and docker:
```shell
NEW_USER=aris-dev
# NEW_USER_PASSWORD=a-hard-password-but-a-good-to-remember
SSH_PORT=222
TIMEZONE="Europe/Rome"
SKIP_SNAP=0 # install snap, any other number will make it skip
wget https://raw.githubusercontent.com/aris997/scripts/refs/heads/main/debian-docker.sh
chmod +x debian-docker.sh
./debian-docker.sh
```

## Basics with certbot (snap) and nginx:
```shell
NEW_USER=aris-dev
# NEW_USER_PASSWORD=a-hard-password-but-a-good-to-remember
SSH_PORT=222
TIMEZONE="Europe/Rome"
SKIP_SNAP=0 # install snap, any other number will make it skip
wget https://raw.githubusercontent.com/aris997/scripts/refs/heads/main/debian-nginx.sh
chmod +x debian-nginx.sh
./debian-nginx.sh
```

---

See `CONTRIBUTING.md` for testing and contributor guidelines.
