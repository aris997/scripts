# Contributing

## Checks

Run syntax, lint, and isolated behavior tests from the repository root:

```bash
for script in *.sh; do bash -n "$script"; done
shellcheck --external-sources *.sh
python3 test-debian13-baseline.py
```

The Python tests use the standard library and isolated fixtures. They mock administrative commands and do not provision your workstation or prove live connectivity.

## Native Debian validation

Use a disposable container with its own network namespace. `NET_ADMIN` is required to validate nftables against the kernel; do not use host networking or a privileged container.

```bash
docker run --rm --cap-add NET_ADMIN \
    --volume "$PWD:/work:ro" --workdir /work \
    debian:13@sha256:f324c7ff54321e8d9c588493a20244965938ce0aa50bbd1022d38010e9ffc4b1 \
    bash -c '
        set -euo pipefail
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
            python3 shellcheck openssh-server nftables systemd sudo iproute2 unattended-upgrades
        shellcheck --external-sources *.sh
        python3 test-debian13-baseline.py
        bash test-debian13-native.sh
    '
```

Native checks use real Debian SSH, nftables, APT, and systemd parsers. They also apply and replace the test firewall inside the container and verify an unrelated table survives. They do not run the full installer, test live SSH reconnection, or exercise a running systemd rollback timer.

Before merging provisioning changes, test on a disposable Debian 13 VM: prepare, log in as the administrator, apply, confirm from a new connection, reapply and allow the timeout, and verify rollback. Check SSH over IPv4 and IPv6, DHCP renewal, package downloads, and persistence after reboot. When installing Kubernetes afterward, verify pod egress and public HTTPS while its API and overlay ports remain private.

## Initial Debian 13 baseline validation

The initial baseline passed all 26 isolated behavior tests, Bash syntax checks, ShellCheck, and native Debian SSH/nftables/APT/systemd configuration checks. The same script completed `prepare`, fresh administrator login and sudo, `apply`, and `confirm` on the Debian 13 `dp-logger` VM. The firewall was verified active and enabled; the rollback timer was disabled after confirmation.

Live timeout recovery, reboot persistence, IPv6 client connectivity, and DHCP renewal remain to be exercised. Container parser checks and the successful login flow do not substitute for those checks.

## Script conventions

- Keep scripts at the repository root with descriptive names and four-space indentation.
- Use Bash with `set -euo pipefail`, quoted variables, explicit permissions, and input validation.
- Keep preparation rerunnable, reject unrelated existing configuration, and preserve recoverable access.
- Never store private keys or passwords in the repository. Review and pin external dependencies where practical.
- Keep changes to application installers separate from the Debian baseline.

For pull requests, describe the resulting behavior, test commands and outcomes, target OS, and any live validation still required.
