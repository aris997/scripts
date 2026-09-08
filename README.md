# Ignition Scripts

Choose **one installer for a fresh server**. The three scripts each manage users, SSH, and the firewall; do not run the existing Docker/Nginx installers on top of the Debian 13 baseline. Download or copy the selected script to the server, review it, and run it as root.

## Usage

### Debian 13 baseline

Use this for a Debian 13 server whose application runtime or reverse proxy will be installed separately.

**Prepare — in your existing root SSH session:**

```bash
wget -O debian13-baseline.sh https://raw.githubusercontent.com/aris997/scripts/main/debian13-baseline.sh
```

After reviewing the downloaded script:

```bash
NEW_USER=administrator-service \
PUBLIC_TCP_PORTS='' \
bash ./debian13-baseline.sh prepare
```

This example selects SSH-only public access. Omit `PUBLIC_TCP_PORTS=''` to also allow HTTP/HTTPS. The public interface is detected automatically, the existing SSH port is retained, and the default timezone is UTC.

**Apply — keep the root session open and connect from a second local terminal:**

Replace `SERVER` with the host/IP or your SSH alias. `-l` overrides an alias that defaults to root; add `-p PORT` if SSH uses a different port.

```bash
ssh -o ControlMaster=no -o ControlPath=none -l administrator-service SERVER
```

In that administrator session:

```bash
sudo -n true
sudo --preserve-env=SSH_CONNECTION debian13-baseline apply
```

**Confirm — within five minutes, open a third local terminal:**

```bash
ssh -o ControlMaster=no -o ControlPath=none -l administrator-service SERVER
```

In this fresh connection:

```bash
sudo --preserve-env=SSH_CONNECTION debian13-baseline confirm
sudo debian13-baseline status
```

If you cannot reconnect, wait for automatic rollback. Keep the earlier sessions open until confirmation succeeds. Afterward, set `User administrator-service` in your existing local SSH alias if it previously selected root.

### Existing Docker + Nginx installer

Use this standalone installer for Docker, the Compose plugin, Nginx, Certbot, and your existing shell setup.

In the root session, download and review:

```bash
wget -O debian-docker.sh https://raw.githubusercontent.com/aris997/scripts/main/debian-docker.sh
```

Then run with your settings:

```bash
NEW_USER=aris-dev \
SSH_PORT=22 \
TIMEZONE=Europe/Rome \
SKIP_SNAP=0 \
bash ./debian-docker.sh
```

### Existing Nginx installer

Use this standalone installer for Nginx and Certbot without Docker.

In the root session, download and review:

```bash
wget -O debian-nginx.sh https://raw.githubusercontent.com/aris997/scripts/main/debian-nginx.sh
```

Then run with your settings:

```bash
NEW_USER=aris-dev \
SSH_PORT=22 \
TIMEZONE=Europe/Rome \
SKIP_SNAP=0 \
bash ./debian-nginx.sh
```

For either existing installer, keep the original root session open and verify the selected user and port from a second terminal:

```bash
ssh -l aris-dev -p 22 SERVER
sudo -n true
```

The examples use key-only users with passwordless sudo. If you set `NEW_USER_PASSWORD`, use `sudo -v` and enter that password instead. These installers disable root SSH during their single run; they do not use the baseline's `prepare/apply/confirm` workflow.

## Debian 13 baseline settings

| Variable | Default | Meaning |
| --- | --- | --- |
| `NEW_USER` | `admin` | New administrator; an unrelated existing account is rejected. |
| `SSH_KEY_FILE` | `/root/.ssh/authorized_keys` | Authorized public keys, including any key restrictions. |
| `PUBLIC_INTERFACE` | Detected from default routes | Set explicitly only when detection is ambiguous. Exactly one public interface is supported. |
| `PUBLIC_TCP_PORTS` | `80 443` | Additional public TCP ports; `''` allows SSH only. |
| `TIMEZONE` | `UTC` | System timezone. |

Set these variables for `prepare`; subsequent commands use the saved root-only configuration. No private key or account password is needed. Passwordless sudo grants full root privileges; the separate account makes administrative actions explicit rather than limiting its authority.

`prepare` installs the command at `/usr/local/sbin/debian13-baseline`, configures the administrator and security updates, and retains active time synchronization. SSH and firewall restrictions are deferred to `apply`.

`apply` requires an administrator SSH session, validates effective SSH settings, and saves the previous access configuration before arming rollback. It disables root SSH, passwords, keyboard-interactive authentication, X11 forwarding, and agent forwarding. Local SSH tunnels remain available for services such as the Kubernetes API.

`confirm` requires a different SSH transport. The examples disable connection sharing to ensure a new transport. Verify both address families on a dual-stack host; confirmation itself proves only the connection used for that command.

### Recovery and maintenance

The five-minute timer is stored on disk and re-arms after a reboot. Apply errors trigger immediate recovery; failed recovery retains its backups and is retried. Rollback covers SSH/firewall access settings, while packages, users, and security-update configuration remain installed. You can also recover from a retained session or your provider's console:

```bash
sudo /usr/local/sbin/debian13-baseline rollback
```

Configuration lives in `/etc/debian-baseline`; access snapshots are retained in `/var/lib/debian-baseline`. Interrupted preparation can resume from its saved intent. A completed `prepare` is a no-op, so later environment overrides do not replace saved settings. Reapplying access restrictions creates another rollback window.

The firewall allows the existing SSH port, configured public TCP ports, established connections, ICMP/ICMPv6, and DHCP replies. Outbound traffic is unrestricted. It filters the selected public interface before destination NAT, covering forwarded container traffic as well as host services. It operates only on `inet debian_baseline`, never flushes the global ruleset, and leaves other interfaces unfiltered.

Preparation rejects existing firewall managers and nftables tables. Kubernetes can be installed afterward; multi-node clusters and UDP applications require additional firewall rules. Forwarding, IPv6 routing, and reverse-path filtering settings are preserved. The firewall uses its own systemd unit because stopping Debian's stock `nftables.service` flushes the global ruleset.

Automatic upgrades are limited to the Debian 13 security repository. Automatic reboots are disabled; schedule kernel reboots manually. Docker, Kubernetes, Nginx, Certbot, shell themes, and Fail2ban are separate from this baseline.

## Existing installer settings and versions

The two existing installers remain independent and unchanged. Both support `NEW_USER`, `NEW_USER_PASSWORD`, `SSH_PORT`, `TIMEZONE`, and `SKIP_SNAP`.

- `SKIP_SNAP=0` installs Certbot through Snap; `SKIP_SNAP=1` installs APT Certbot instead. The APT route needs the separate `python3-certbot-nginx` package to use Certbot's Nginx plugin.
- The Docker installer also supports `SKIP_DOCKER=1`. This skips Docker only; Nginx, Certbot, and the shell setup still run.
- Unlike the baseline, both existing installers enable unattended automatic reboots at 04:00 in the configured timezone.

Application versions are selected at execution time: system packages and Nginx follow the host's APT repositories, Docker follows its Debian stable repository for the OS codename, and Certbot follows Snap or APT. The Docker edition also downloads Oh My Zsh and personal dotfiles from their upstream branches. This repository does not pin those application versions.

See [CONTRIBUTING.md](CONTRIBUTING.md) for checks, native Debian validation, and the VM tests required before merging provisioning changes.
