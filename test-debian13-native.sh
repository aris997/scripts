#!/bin/bash
# Run only in a disposable Debian 13 container with CAP_NET_ADMIN.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

[[ $EUID -eq 0 && -f /.dockerenv ]] || { printf 'Run this test in the documented disposable container.\n' >&2; exit 1; }
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=debian13-baseline.sh
source "$SCRIPT_DIR/debian13-baseline.sh"
# shellcheck source=/dev/null
. /etc/os-release
[[ "$ID" == debian && "$VERSION_ID" == 13 ]] || fail 'Debian 13 is required.'
[[ -z "$(nft list tables)" ]] || fail 'The test requires an empty container firewall.'

NATIVE_TMP=$(mktemp -d)
cleanup() {
    nft destroy table inet debian_baseline
    nft destroy table inet baseline_test_sentinel
    rm -rf "$NATIVE_TMP"
}
trap cleanup EXIT
NEW_USER=baseline-test
SSH_PORT=22
PUBLIC_INTERFACE=eth0
PUBLIC_TCP_PORTS='80 443'
CLIENT_IP=192.0.2.10
SERVER_IP=192.0.2.20
CONFIG_DIR="$NATIVE_TMP/config"
STATE_DIR="$NATIVE_TMP/state"
UNIT_DIR="$NATIVE_TMP/units"
INSTALL_PATH="$NATIVE_TMP/debian13-baseline"
mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$UNIT_DIR" /run/sshd
install -m 755 "$SCRIPT_DIR/debian13-baseline.sh" "$INSTALL_PATH"
validate_settings

render_firewall > "$CONFIG_DIR/firewall.nft"
nft add table inet baseline_test_sentinel
nft --check --file "$CONFIG_DIR/firewall.nft"
nft --file "$CONFIG_DIR/firewall.nft"
nft --file "$CONFIG_DIR/firewall.nft"
nft list table inet baseline_test_sentinel >/dev/null
nft list chain inet debian_baseline public_ingress >/dev/null
printf 'Native nftables validation and scoped replacement passed.\n'

ssh-keygen -q -t ed25519 -N '' -f "$NATIVE_TMP/host-key"
{
    printf 'HostKey %s\n' "$NATIVE_TMP/host-key"
    render_ssh
} > "$NATIVE_TMP/sshd_config"
# Exercise the verifier with a real sshd and a disposable configuration file.
function /usr/sbin/sshd {
    command /usr/sbin/sshd -f "$NATIVE_TMP/sshd_config" "$@"
}
verify_ssh
CLIENT_IP=2001:db8::10
SERVER_IP=2001:db8::20
verify_ssh
printf 'Native SSH configuration validation passed for IPv4 and IPv6.\n'

render_updates > "$NATIVE_TMP/apt.conf"
apt-config() {
    command apt-config --config-file "$NATIVE_TMP/apt.conf" "$@"
}
verify_updates
printf 'Native APT policy validation passed.\n'

# PID 1 is not systemd; validate units without activating them.
systemctl() { :; }
install_rollback_units
render_firewall_unit > "$UNIT_DIR/$FIREWALL_UNIT"
systemd-analyze verify "$UNIT_DIR/$FIREWALL_UNIT" "$UNIT_DIR/$ROLLBACK_UNIT.service" "$UNIT_DIR/$ROLLBACK_UNIT.timer"
printf 'Native systemd unit validation passed.\n'
