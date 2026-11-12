# System Integrity Audit

Linux package-integrity, storage-health, and filesystem auditing, with terminal and optional multipart email reporting.

> **Development preview:** `2.0.0-dev.6` implements both Debian/Ubuntu (`debsums`) and Rocky Linux/RHEL (`rpm`) package-integrity backends. Regression fixtures pass, and one Rocky Linux 9.8 host has completed a live audit. **Broader Rocky/RHEL host validation and production certification remain pending**. Do not treat this branch as a certified production release. The existing `debsums-audit` v1.7.1 remains the known-working Ubuntu baseline.

## Platform support

| OS family | Package verification | Validation |
| --- | --- | --- |
| Ubuntu 20.04 LTS | `debsums -ca` and `debsums -l` | systemd 245, journald, and end-to-end mock regressions pass; live host validation pending |
| Ubuntu 22.04/24.04 LTS | `debsums -ca` and `debsums -l` | Preserved Ubuntu regression suite; v2 live validation pending |
| Ubuntu 18.04 and earlier | Not supported | Rejected explicitly; minimum Ubuntu release is 20.04 |
| Debian | `debsums` | Experimental |
| Rocky Linux / RHEL 9 | `rpm -Va --noscripts --noghost` | Mock regression tests pass; one live Rocky Linux 9.8 audit completed |
| AlmaLinux / CentOS | RPM backend selected | Experimental; not certified |
| Rocky Linux / RHEL 8 and 10 | RPM backend selected | Experimental; compatibility testing pending |

A platform recognized by the script is **not** automatically a tested platform. Ubuntu 20.04's `journalctl` lacks `--lines=+1`; the audit uses a timeout-bounded first-entry stream instead. See [Ubuntu 20.04 compatibility notes](docs/ubuntu2004-compatibility.md). Ubuntu 18.04 and earlier are rejected explicitly.

## Package-integrity interpretation

On RPM systems, the script performs **read-only verification** of installed RPM package files. It classifies missing or changed package payloads as alerts; modified configuration files and metadata as warnings; and ignores timestamp-only drift unless `RPM_REPORT_TIMESTAMP_ONLY=1` is set. `%ghost` runtime files are skipped. Unreadable or unrecognized verification records and RPM command failures cause **incomplete/error** reporting, not a false all-clear. A missing RPM-owned **directory under `/run`** is reported as a `NOTICE` only when RPM metadata confirms that exact path is a directory; otherwise missing paths remain alerts. Expected modifications may use `EXCEPTIONS_FILE` globs, but they cannot hide missing files. A separate `MISSING_EXCEPTIONS_FILE` provides **literal, explicit approvals** of known missing files on Debian/Ubuntu or RPM hosts. Approved paths remain visible in the ignored-findings section.

### Approved missing-file policy

Missing regular package files remain **ALERT** by default. For a verified local customization, create a root-owned text file at `/usr/local/etc/system-integrity-audit.missing.ignore`, with **one exact absolute path per line**, such as:

```text
/var/opt/aesmd/data/white_list_cert_to_be_verify.bin
```

Set mode `0600`. Comments beginning with `#` and blank lines are accepted; wildcard patterns are **rejected**. To set another location, configure `MISSING_EXCEPTIONS_FILE`.

The existing `/usr/local/etc/system-integrity-audit.ignore` is different: it is for expected **modifications**, and continues to accept glob patterns. See [RPM backend notes](docs/rpm-backend.md) for details.

The RPM scan calls `rpm -Va --noscripts --noghost` with a timeout. Verification uses the installed package database as its reference; it is not a proof of system integrity against a compromised or modified RPM database. See [RPM backend notes](docs/rpm-backend.md) for limitations.

## Email reporting

Email delivery is available, but disabled by the exact default placeholder:

```bash
REPORT_TO="username@email.address"
```

An unchanged placeholder or empty `REPORT_TO` means **no email is sent**, including error notifications. To enable sending, configure a real recipient and a working sendmail-compatible local mailer:

```bash
sudo env REPORT_TO="admin@example.org" FORCE_REPORT=1 ./system-integrity-audit
```

`REPORT_FROM_NAME`, `REPORT_FROM_ADDRESS`, and `SUBJECT_PREFIX` customize sender and subject settings. No organization-specific email address is embedded in the repository.

## Safe host defaults

`AUTO_INSTALL_REQUIREMENTS=0` and `AUTO_ENABLE_PERSISTENT_JOURNAL=0` are defaults: no automatic package installation (APT or DNF) and no automatic persistent-journald configuration changes. The audit writes private lock, temp, and notification-state files; many checks require root. Automatic installation can be explicitly enabled, but **do not enable it on an unfamiliar system without reviewing the actions first**.

The initial live-audit configuration on a Rocky Linux host can be:

```bash
sudo env AUTO_INSTALL_REQUIREMENTS=0 AUTO_ENABLE_PERSISTENT_JOURNAL=0 \
  REPORT_TO=username@email.address FORCE_REPORT=1 ./system-integrity-audit
```

This avoids automatic package/journald changes and email, but does not disable all local writes (locks and notification state).

## Development tests

```bash
git checkout develop/v2.0
bash ./system-integrity-audit --version
sudo bash tests/regression.sh
sudo bash tests/rpm-regression.sh
```

The shared suite includes approved-missing regression cases and also mocks Ubuntu's `dpkg-query`, so its Ubuntu scenarios run on RPM-based test hosts without requiring Debian packages. The regression suites use simulated hardware, journals, RPM results, and email. They cannot validate real device and storage behavior. Inspect the report's **Audit coverage** section and review all unexpected RPM differences on your actual machine before wider deployment.

See [example environment options](config/example.env). Suggestions and redacted false-positive examples are welcome through GitHub issues.

## Security and licensing

Redact serial numbers, hostnames, usernames, addresses, and other private operational details before posting logs publicly. MIT license; see [LICENSE](LICENSE).
