# System Integrity Audit

Linux package-integrity, storage-health, and filesystem auditing, with optional terminal and email reporting.

> **Development preview:** v2.0.0-dev.2 on the [development branch](https://github.com/rtcheek/system-integrity-audit/tree/develop/v2.0) is **Debian/Ubuntu-only**. The RPM verification backend for Rocky Linux/RHEL is planned but **not yet implemented**. Do not treat this repository as a production-ready v2.0 release.

## Email configuration

Email reporting is **included**, but disabled by the default placeholder:

```bash
REPORT_TO="username@email.address"
```

If `REPORT_TO` equals that exact placeholder, or is empty, **no email is sent**, including early error reports. The audit can still print its terminal report. To enable email, configure a real recipient on a machine with a working sendmail-compatible mail transfer agent:

```bash
sudo env REPORT_TO="admin@example.org" FORCE_REPORT=1 ./system-integrity-audit
```

The sender display name, envelope address, and subject prefix can be customized through `REPORT_FROM_NAME`, `REPORT_FROM_ADDRESS`, and `SUBJECT_PREFIX`. No campus-specific or organization-specific recipient address is embedded in this code.

## Safe host defaults

Automatic prerequisite installation (`AUTO_INSTALL_REQUIREMENTS=0`) and automatic persistent-journal changes (`AUTO_ENABLE_PERSISTENT_JOURNAL=0`) are **off** by default. Checks may still create local lock, temporary, and notification-state files. Many hardware and system-integrity checks require root privileges.

## Development and testing

To inspect the development preview and run its non-destructive mock-based regression tests:

```bash
git checkout develop/v2.0
bash tests/regression.sh
bash ./system-integrity-audit --version
```

Review `--help` and [the example configuration](config/example.env) before attempting a live audit. The regression suite mocks hardware, journals, and email; it does not constitute certification of a specific OS or controller.

### Planned platforms

- Ubuntu 22.04 and 24.04: existing v1.7.1 baseline, with v2 regression validation in progress.
- Rocky Linux/RHEL 9: planned RPM package integrity adapter, not yet available.
- Rocky Linux/RHEL 8 and 10: later validation targets.

## Security and contribution

When opening issues or sharing logs, redact hostnames, usernames, disk serial numbers, network addresses, and other sensitive identifiers. Do not paste sensitive email settings or audit reports into public issues.

Licensed under the [MIT License](LICENSE).
