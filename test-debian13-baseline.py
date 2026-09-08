#!/usr/bin/env python3
"""Isolated shell-function tests; these do not provision or validate a real host."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("debian13-baseline.sh")

HARNESS = r'''
source "$SCRIPT_UNDER_TEST"
CONFIG_DIR="$FIXTURE/config"
STATE_DIR="$FIXTURE/state"
UNIT_DIR="$FIXTURE/units"
SSH_FILE="$FIXTURE/sshd.conf"
INSTALL_PATH="$FIXTURE/debian13-baseline"
COMMAND_LOG="$FIXTURE/commands"
NFT_APPLIED="$FIXTURE/nft-applied"
NEW_USER=administrator-service
SSH_PORT=22
PUBLIC_INTERFACE=eth0
PUBLIC_TCP_PORTS='80 443'
TCP_PORTS=(80 443)
SUDO_USER="$NEW_USER"
SSH_CONNECTION='198.51.100.2 12345 203.0.113.2 22'
mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$UNIT_DIR"
: > "$COMMAND_LOG"
record() { printf '%s\n' "$*" >> "$COMMAND_LOG"; }
function /usr/sbin/sshd {
    record "sshd $*"
    [[ "${FAIL_SSHD:-0}" != 1 ]]
}
systemctl() {
    record "systemctl $*"
    case "$1" in
        is-active)
            case "${!#}" in
                "$ROLLBACK_UNIT.timer") [[ "${TIMER_ACTIVE:-1}" == 1 ]] ;;
                "$FIREWALL_UNIT") [[ "${FIREWALL_ACTIVE:-0}" == 1 ]] ;;
                *) return 1 ;;
            esac
            ;;
        is-enabled) return 1 ;;
        *) return 0 ;;
    esac
}
nft() {
    record "nft $*"
    case "$*" in
        'list table inet debian_baseline') return 1 ;;
        '--check --file '*) [[ "${FAIL_NFT_CHECK:-0}" != 1 ]] ;;
        '--file '*)
            cat "$2" >> "$NFT_APPLIED"
            [[ "${FAIL_NFT_APPLY:-0}" != 1 ]]
            ;;
        *) return 0 ;;
    esac
}
ip() { record "ip $*"; }
verify_ssh() { record 'verify_ssh'; }
apt-get() { record "UNEXPECTED apt-get $*"; return 98; }
adduser() { record "UNEXPECTED adduser $*"; return 98; }
usermod() { record "UNEXPECTED usermod $*"; return 98; }
timedatectl() { record "UNEXPECTED timedatectl $*"; return 98; }
'''


class BaselineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory(prefix="debian-baseline-test-")
        self.addCleanup(self.directory.cleanup)
        self.fixture = Path(self.directory.name)

    def run_shell(self, body: str) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update(SCRIPT_UNDER_TEST=str(SCRIPT), FIXTURE=str(self.fixture))
        return subprocess.run(
            ["/bin/bash", "-c", HARNESS + "\n" + body],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def assert_success(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def commands(self) -> str:
        return (self.fixture / "commands").read_text()

    def test_unknown_command_and_extra_arguments_fail_before_host_checks(self) -> None:
        for arguments in ("unknown", "prepare unexpected"):
            with self.subTest(arguments=arguments):
                result = self.run_shell(
                    'require_host() { record "UNEXPECTED require_host"; }\n'
                    f"main {arguments}"
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.commands(), "")
                self.assertIn("ERROR:", result.stderr)

    def test_help_requires_no_root_or_host_inspection(self) -> None:
        result = self.run_shell(
            'require_host() { record "UNEXPECTED require_host"; }\nmain --help'
        )
        self.assert_success(result)
        self.assertIn("Usage:", result.stdout)
        self.assertEqual(self.commands(), "")

    def test_invalid_settings_fail_without_external_commands(self) -> None:
        cases = (
            "NEW_USER=root",
            "NEW_USER='bad user'",
            "NEW_USER='-admin'",
            "PUBLIC_INTERFACE=lo",
            "PUBLIC_INTERFACE='eth0 eth1'",
            "PUBLIC_INTERFACE='eth0;true'",
            "SSH_PORT=0",
            "SSH_PORT=65536",
            "SSH_PORT=22,23",
            "PUBLIC_TCP_PORTS='80 65536'",
            "PUBLIC_TCP_PORTS='80;true'",
            "PUBLIC_TCP_PORTS=$'80\\n443'",
        )
        for settings in cases:
            with self.subTest(settings=settings):
                result = self.run_shell(settings + "\nvalidate_settings")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("ERROR:", result.stderr)
                self.assertEqual(self.commands(), "")

    def test_prepare_rejects_existing_administrator_before_installing_packages(self) -> None:
        result = self.run_shell(
            'function /usr/sbin/sshd { printf "port 22\\n"; }\n'
            'id() { return 0; }\nTIMEZONE=UTC\nprepare'
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already exists", result.stderr)
        self.assertNotIn("UNEXPECTED", self.commands())
        self.assertFalse((self.fixture / "config/settings").exists())

    def test_prepare_rejects_missing_public_key_before_installing_packages(self) -> None:
        result = self.run_shell(
            'function /usr/sbin/sshd { printf "port 22\\n"; }\n'
            'id() { return 1; }\nTIMEZONE=UTC\n'
            'SSH_KEY_FILE="$FIXTURE/missing-key"\nprepare'
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SSH_KEY_FILE", result.stderr)
        self.assertNotIn("UNEXPECTED", self.commands())
        self.assertFalse((self.fixture / "config/settings").exists())

    def test_prepare_rejects_invalid_timezone_before_installing_packages(self) -> None:
        result = self.run_shell(
            'function /usr/sbin/sshd { printf "port 22\\n"; }\n'
            'TIMEZONE=../../etc/passwd\nprepare'
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid TIMEZONE", result.stderr)
        self.assertNotIn("UNEXPECTED", self.commands())

    def test_prepare_resumes_marker_and_retains_it_after_package_failure(self) -> None:
        result = self.run_shell(
            'printf "%s\\n" "NEW_USER=administrator-service" "SSH_PORT=22" '
            '"PUBLIC_INTERFACE=eth0" "PUBLIC_TCP_PORTS=80" "TIMEZONE=UTC" '
            '> "$CONFIG_DIR/preparing"\n'
            'id() { return 0; }\nprepare'
        )
        self.assertEqual(result.returncode, 98)
        self.assertIn("Resuming preparation for administrator-service", result.stdout)
        self.assertIn("UNEXPECTED apt-get update", self.commands())
        self.assertTrue((self.fixture / "config/preparing").is_file())
        self.assertFalse((self.fixture / "config/settings").exists())
        self.assertNotIn("UNEXPECTED adduser", self.commands())

    def test_completed_prepare_does_not_run_packages_or_recreate_administrator(self) -> None:
        result = self.run_shell(
            'printf "%s\\n" "NEW_USER=administrator-service" "SSH_PORT=22" '
            '"PUBLIC_INTERFACE=eth0" "PUBLIC_TCP_PORTS=80" '
            '> "$CONFIG_DIR/settings"\nprepare'
        )
        self.assert_success(result)
        self.assertIn("Already prepared", result.stdout)
        self.assertEqual(self.commands(), "")

    def test_prepare_merges_public_keys_without_final_newlines(self) -> None:
        result = self.run_shell(
            r"""
# Relocate prepare's fixed home paths; execute its actual key-merging code.
prepare_definition=$(declare -f prepare)
prepare_definition=${prepare_definition//\/home\//\$FIXTURE\/home\/}
eval "$prepare_definition"
printf '%s\n' 'NEW_USER=administrator-service' 'SSH_PORT=22' \
    'PUBLIC_INTERFACE=eth0' 'PUBLIC_TCP_PORTS=80' 'TIMEZONE=UTC' \
    > "$CONFIG_DIR/preparing"
mkdir -p "$FIXTURE/home/$NEW_USER/.ssh"
printf 'ssh-ed25519 AAAAinitial initial' > "$CONFIG_DIR/authorized_keys"
printf 'ssh-ed25519 BBBBexisting existing\nssh-ed25519 AAAAinitial initial' \
    > "$FIXTURE/home/$NEW_USER/.ssh/authorized_keys"
apt-get() { record "apt-get $*"; }
timedatectl() { record "timedatectl $*"; }
usermod() { record "usermod $*"; }
id() { return 0; }
getent() {
    printf '%s:x:1001:1001::%s/home/%s:/bin/bash\n' "$NEW_USER" "$FIXTURE" "$NEW_USER"
}
install() {
    local arguments=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|-g) shift 2 ;;
            -m) arguments+=("$1" "$2"); shift 2 ;;
            -d) arguments+=("$1"); shift ;;
            *)
                [[ "$1" == "$FIXTURE/"* ]] || fail "Unmapped install path: $1"
                arguments+=("$1"); shift
                ;;
        esac
    done
    command install "${arguments[@]}"
}
# Stop before the first sudoers install or fixed /etc write.
visudo() { record 'stopped at visudo'; return 77; }
prepare
"""
        )
        self.assertEqual(result.returncode, 77, result.stdout + result.stderr)
        self.assertIn("stopped at visudo", self.commands())
        keys = self.fixture / "home/administrator-service/.ssh/authorized_keys"
        self.assertEqual(
            keys.read_text(),
            "ssh-ed25519 AAAAinitial initial\nssh-ed25519 BBBBexisting existing\n",
        )
        self.assertFalse((self.fixture / "config/settings").exists())

    def test_port_bounds_and_leading_zero_ports(self) -> None:
        result = self.run_shell(
            "PUBLIC_TCP_PORTS='1 65535 00080'\nvalidate_settings\nrender_firewall"
        )
        self.assert_success(result)
        self.assertIn("tcp dport { 22, 1, 65535, 80 } accept", result.stdout)

    def test_session_guards_reject_root_missing_and_malformed_connections(self) -> None:
        cases = (
            "SUDO_USER=root",
            "unset SUDO_USER",
            "unset SSH_CONNECTION",
            "SSH_CONNECTION='198.51.100.2 12345 203.0.113.2 2222'",
            "SSH_CONNECTION='198.51.100.2 12345 203.0.113.2 22 extra'",
            "SSH_CONNECTION='198.51.100.2 x 203.0.113.2 22'",
            "SSH_CONNECTION='hostname 12345 203.0.113.2 22'",
        )
        for settings in cases:
            with self.subTest(settings=settings):
                result = self.run_shell(settings + "\nrequire_admin_session")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.commands(), "")

    def test_admin_session_accepts_ipv6(self) -> None:
        result = self.run_shell(
            "SSH_CONNECTION='2001:db8::2 12345 2001:db8::3 22'\n"
            "require_admin_session\nprintf '%s %s' \"$CLIENT_IP\" \"$SERVER_IP\""
        )
        self.assert_success(result)
        self.assertEqual(result.stdout, "2001:db8::2 2001:db8::3")

    def test_confirm_requires_a_different_ssh_connection(self) -> None:
        result = self.run_shell(
            'mkdir "$STATE_DIR/pending"\n'
            'touch "$STATE_DIR/pending/armed"\n'
            'printf "%s\\n" "$SSH_CONNECTION" > "$STATE_DIR/pending/connection"\n'
            'confirm_access'
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Reconnect", result.stderr)
        self.assertEqual(self.commands(), "")
        self.assertTrue((self.fixture / "state/pending/armed").is_file())

    def test_firewall_preserves_network_control_and_other_interfaces(self) -> None:
        result = self.run_shell("render_firewall")
        self.assert_success(result)
        rules = result.stdout
        for expected in (
            "destroy table inet debian_baseline",
            'iifname != "eth0" accept',
            "ct state established,related accept",
            "meta l4proto { icmp, ipv6-icmp } accept",
            "meta nfproto ipv4 udp sport 67 udp dport 68 accept",
            "meta nfproto ipv6 udp sport 547 udp dport 546 accept",
            "ct state new tcp dport { 22, 80, 443 } accept",
            "counter drop",
        ):
            self.assertIn(expected, rules)
        self.assertNotIn("flush ruleset", rules)
        self.assertNotIn("flush table", rules)
        self.assertLess(rules.index("hook prerouting"), rules.index("counter drop"))
        self.assertLess(rules.index("ipv6-icmp"), rules.index("counter drop"))

    def test_ssh_rendering_preserves_local_tunnels_and_requires_keys(self) -> None:
        result = self.run_shell("render_ssh")
        self.assert_success(result)
        for setting in (
            "AuthenticationMethods publickey",
            "PermitRootLogin no",
            "PasswordAuthentication no",
            "KbdInteractiveAuthentication no",
            "PermitEmptyPasswords no",
            "AllowUsers administrator-service",
            "AllowTcpForwarding local",
            "AllowAgentForwarding no",
            "GatewayPorts no",
        ):
            self.assertIn(setting + "\n", result.stdout)

    def test_timer_units_gate_retry_on_armed_marker(self) -> None:
        result = self.run_shell("install_rollback_units")
        self.assert_success(result)
        service = (self.fixture / "units/debian-baseline-rollback.service").read_text()
        timer = (self.fixture / "units/debian-baseline-rollback.timer").read_text()
        self.assertIn(f"ConditionPathExists={self.fixture}/state/pending/armed", service)
        self.assertIn("Restart=on-failure", service)
        self.assertIn("RestartSec=30s", service)
        self.assertIn("OnActiveSec=5min", timer)

    def test_apply_requires_active_rollback_timer_before_restricting_access(self) -> None:
        result = self.run_shell(
            'printf "old ssh\\n" > "$SSH_FILE"\nTIMER_ACTIVE=0\napply_access'
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not arm automatic rollback", result.stderr)
        self.assertEqual((self.fixture / "sshd.conf").read_text(), "old ssh\n")
        self.assertFalse((self.fixture / "config/firewall.nft").exists())
        self.assertNotIn("verify_ssh", self.commands())
        self.assertNotIn("systemctl reload ssh.service", self.commands())
        self.assertTrue((self.fixture / "state/pending/armed").is_file())

    def test_apply_cancels_previous_retries_before_creating_pending(self) -> None:
        result = self.run_shell(
            r"""
systemctl_definition=$(declare -f systemctl)
eval "${systemctl_definition/systemctl ()/mock_systemctl ()}"
systemctl() {
    if [[ "$1" == stop && "$2" == "$ROLLBACK_UNIT.timer" ]]; then
        [[ "$#" == 3 && "$3" == "$ROLLBACK_UNIT.service" ]] || \
            fail 'Both previous rollback units must be stopped'
        [[ ! -d "$STATE_DIR/pending" ]] || fail 'New pending state created too early'
        record 'previous retries cancelled before pending'
    fi
    mock_systemctl "$@"
}
FAIL_NFT_CHECK=1
apply_access
"""
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("previous retries cancelled before pending", self.commands())
        self.assertTrue((self.fixture / "state/pending").is_dir())
        self.assertFalse((self.fixture / "state/pending/armed").exists())
        self.assertNotIn("New pending state created too early", result.stderr)

    def test_apply_with_pending_change_keeps_its_rollback_running(self) -> None:
        result = self.run_shell(
            'mkdir "$STATE_DIR/pending"\n'
            'touch "$STATE_DIR/pending/armed"\napply_access'
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already pending", result.stderr)
        self.assertNotIn("systemctl stop", self.commands())
        self.assertTrue((self.fixture / "state/pending/armed").is_file())

    def test_failed_firewall_validation_cleans_only_unarmed_pending(self) -> None:
        result = self.run_shell(
            'printf "old ssh\\n" > "$SSH_FILE"\n'
            'printf "keep\\n" > "$STATE_DIR/unrelated"\n'
            'FAIL_NFT_CHECK=1\ntrap on_exit EXIT\napply_access'
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.fixture / "state/pending").exists())
        self.assertEqual((self.fixture / "state/unrelated").read_text(), "keep\n")
        self.assertEqual((self.fixture / "sshd.conf").read_text(), "old ssh\n")
        self.assertNotIn("enable --now debian-baseline-rollback.timer", self.commands())

    def rollback_fixture(self) -> str:
        return r'''
mkdir "$STATE_DIR/pending"
touch "$STATE_DIR/pending/armed"
printf 'old ssh\n' > "$STATE_DIR/pending/ssh.conf"
printf 'new ssh\n' > "$SSH_FILE"
printf 'old firewall\n' > "$STATE_DIR/pending/firewall.nft"
printf 'new firewall\n' > "$CONFIG_DIR/firewall.nft"
printf 'old unit\n' > "$STATE_DIR/pending/firewall.service"
printf 'new unit\n' > "$UNIT_DIR/$FIREWALL_UNIT"
printf 'table inet debian_baseline { }\n' > "$STATE_DIR/pending/table.nft"
printf 'unrelated\n' > "$STATE_DIR/unrelated"
'''

    def test_rollback_restores_only_managed_state_and_archives_after_success(self) -> None:
        result = self.run_shell(self.rollback_fixture() + "\nrollback_access")
        self.assert_success(result)
        self.assertEqual((self.fixture / "sshd.conf").read_text(), "old ssh\n")
        self.assertEqual((self.fixture / "config/firewall.nft").read_text(), "old firewall\n")
        self.assertEqual(
            (self.fixture / "units/debian-baseline-firewall.service").read_text(), "old unit\n"
        )
        self.assertEqual((self.fixture / "state/unrelated").read_text(), "unrelated\n")
        self.assertFalse((self.fixture / "state/pending").exists())
        self.assertEqual(len(list((self.fixture / "state").glob("rolled-back-*"))), 1)
        self.assertEqual(
            (self.fixture / "nft-applied").read_text(),
            "destroy table inet debian_baseline\ntable inet debian_baseline { }\n",
        )
        self.assertIn("disable --now debian-baseline-rollback.timer", self.commands())
        self.assertNotIn("flush", self.commands())

    def test_rollback_without_previous_files_removes_only_managed_files(self) -> None:
        result = self.run_shell(
            self.rollback_fixture()
            + '\nrm "$STATE_DIR/pending/ssh.conf" "$STATE_DIR/pending/firewall.nft" '
            '"$STATE_DIR/pending/firewall.service" "$STATE_DIR/pending/table.nft"\n'
            'rollback_access'
        )
        self.assert_success(result)
        self.assertFalse((self.fixture / "sshd.conf").exists())
        self.assertFalse((self.fixture / "config/firewall.nft").exists())
        self.assertFalse((self.fixture / "units/debian-baseline-firewall.service").exists())
        self.assertTrue((self.fixture / "state/unrelated").exists())
        self.assertEqual(
            (self.fixture / "nft-applied").read_text(), "destroy table inet debian_baseline\n"
        )

    def test_rollback_failure_keeps_backups_and_timer_for_retry(self) -> None:
        result = self.run_shell(self.rollback_fixture() + "\nFAIL_NFT_APPLY=1\nrollback_access")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.fixture / "state/pending/armed").is_file())
        self.assertEqual((self.fixture / "state/pending/ssh.conf").read_text(), "old ssh\n")
        self.assertNotIn("disable --now debian-baseline-rollback.timer", self.commands())
        self.assertEqual(list((self.fixture / "state").glob("rolled-back-*")), [])
        self.assertEqual((self.fixture / "sshd.conf").read_text(), "old ssh\n")
        self.assertIn("systemctl reload-or-restart ssh.service", self.commands())

    def test_rollback_restores_firewall_even_when_ssh_validation_fails(self) -> None:
        result = self.run_shell(self.rollback_fixture() + "\nFAIL_SSHD=1\nrollback_access")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sshd -t\n", self.commands())
        self.assertIn("nft --file", self.commands())
        self.assertNotIn("reload-or-restart ssh.service", self.commands())
        self.assertNotIn("disable --now debian-baseline-rollback.timer", self.commands())
        self.assertTrue((self.fixture / "state/pending/armed").exists())
        self.assertEqual((self.fixture / "config/firewall.nft").read_text(), "old firewall\n")
        self.assertTrue((self.fixture / "nft-applied").exists())

    def test_failed_automatic_rollback_preserves_original_failure_status(self) -> None:
        result = self.run_shell(
            'rollback_access() { record "rollback attempted"; return 1; }\n'
            'ROLLBACK_ON_ERROR=1\ntrap on_exit EXIT\nexit 42'
        )
        self.assertEqual(result.returncode, 42)
        self.assertEqual(self.commands(), "rollback attempted\n")
        self.assertIn("Rollback failed; backups remain", result.stderr)
        self.assertIn("timer will retry", result.stderr)

    def test_unarmed_rollback_performs_no_commands(self) -> None:
        result = self.run_shell("rollback_access")
        self.assert_success(result)
        self.assertIn("No armed access change", result.stdout)
        self.assertEqual(self.commands(), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
