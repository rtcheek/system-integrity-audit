# Rocky Linux / RHEL RPM backend (development preview)

The `develop/v2.0` branch now recognizes `ID=rocky`, `ID=rhel`, `ID=almalinux`, and `ID=centos` from `/etc/os-release`. This is **not certification** of any specific major release. Version `2.0.0-dev.8` has passed mock-based regression tests, and one real Rocky Linux 9.8 host has completed an audit. This is **not yet broad Rocky/RHEL compatibility certification**.

## Verification

The audit runs:

```bash
rpm -Va --noscripts --noghost
```

It uses the installed RPM database as the comparison baseline. RPM returns status 1 for verification differences; the audit does not treat that status alone as a failed scan. It classifies individual records based on RPM's attribute columns and file markers:

| RPM result | Default audit interpretation |
| --- | --- |
| Missing ordinary package-managed file | `MISSING` / ALERT, unless explicitly approved as an exact missing path |
| Missing RPM-owned `/run` directory | `RUNTIME` / NOTICE, **only** if `rpm -q --dump` confirms the exact missing path is a directory; otherwise ALERT |
| Changed size, checksum, or symlink target on ordinary payload | `CHANGED` / ALERT |
| Modified `%config` file | `CONFIG` / WARNING |
| Permissions, ownership, capabilities, other metadata differences | `METADATA` / WARNING |
| Only a modification-time difference | Ignored by default; `RPM_REPORT_TIMESTAMP_ONLY=1` includes a NOTICE |
| `%ghost` file | Ignored (created or managed at runtime) |
| Unreadable, unrecognized verification record | Incomplete/error reporting |
| RPM execution failure or unexpected status | Incomplete/error reporting |

The original `debsums` backend is retained for Debian/Ubuntu. Its modifications-exception list, `EXCEPTIONS_FILE`, does **not** hide missing package payloads. An administrator can explicitly approve a known missing path via `MISSING_EXCEPTIONS_FILE`. This is a separate file with *literal exact-path matching*, not globbing. Approvals are listed with status `APPROVED` under **Expected package verification differences ignored**, and counted separately in the summary.

Default files:

- `/usr/local/etc/system-integrity-audit.ignore`: known **modified** paths; shell globs allowed.
- `/usr/local/etc/system-integrity-audit.missing.ignore`: explicitly approved **missing** paths; one exact absolute path per line, with `#` comments and no globs.

Example: `/var/opt/aesmd/data/white_list_cert_to_be_verify.bin` may be locally removed as part of a custom Intel SGX install, but should **not** be globally suppressed for other hosts. For a host with that known modification, add only that exact path to its approved-missing file. Secure the file with root ownership and mode `0600`.

For `/run` paths, the runtime-directory downgrade is **fail closed**: if the owner lookup or `rpm --dump` check cannot establish a directory file type, the missing path remains an alert. Missing regular files under `/run` always remain alerts unless explicitly approved.

Some RPM output variations and package types may produce noisy records; please report redacted examples for refinement.

## Prerequisites and safety

The RPM backend requires `rpm`. SMART checks additionally require `smartctl` from `smartmontools`. `dnf` is used for automatic installation when required audit prerequisites are missing and installation is enabled. Since v2.0.0-dev.8, this is enabled by default; installing packages still requires sufficient privileges.

By default (since v2.0.0-dev.8):

```bash
AUTO_INSTALL_REQUIREMENTS=1
AUTO_ENABLE_PERSISTENT_JOURNAL=1
REPORT_TO="username@email.address"
```

**Running as root can now install missing packages with DNF and configure or restart journald automatically if persistent logging is not already enabled.** The switches only permit changes when needed; they do not force a transaction on an already configured host. Set either switch to `0` to opt out of that action. The placeholder email recipient still disables outgoing mail. The script creates temporary, lock, and local state files. **SMART_SHORT_TEST_AUTO=1 is a separate default introduced in v2.0.0-dev.7**: a non-captive firmware test may start under strict eligibility gates; opt out with `SMART_SHORT_TEST_AUTO=0`. See [SMART short-test scheduler](smart-short-tests.md).

The normal command timeout applies to hardware checks; RPM has a separate `RPM_VERIFY_TIMEOUT_SECONDS` (default 7200). A verification timeout or failure must produce an incomplete result rather than a clean audit.

## Live Rocky host validation

One Rocky Linux 9.8 host has successfully completed an audit and exposed realistic expected SGX changes and a transient Gluster directory. Continue testing with the regression suite, **then** run a reviewed audit without automatic package/journald changes, email or SMART test initiation:

```bash
sudo bash tests/regression.sh
sudo bash tests/rpm-regression.sh
sudo env REPORT_TO=username@email.address \
  AUTO_INSTALL_REQUIREMENTS=0 AUTO_ENABLE_PERSISTENT_JOURNAL=0 \
  SMART_SHORT_TEST_AUTO=0 FORCE_REPORT=1 ./system-integrity-audit
```

Review the terminal report's coverage summary, RPM classifications, and the kernel/filesystem sections. If there are unexpected alerts, use the native command `sudo rpm -Va --noscripts --noghost` for independent comparison. Redact machine-specific details before sharing.

## Limitations

- RPM verifies files against the **local RPM database**, not against independently trusted hashes. A tampered package database or intentionally replaced RPM package may evade detection.
- RPM payload verification does not assess unowned files, network-mounted data, application semantics, SELinux policy correctness, or runtime malware.
- Some RPM metadata differences are benign and need site-specific review.
- RHEL/Rocky versions may differ in packaged scrub timers, service units, and default journald policies; these shared checks require real-host verification.
- The dedicated DNF installation path is enabled by default when prerequisites are missing but has not been validated in a live package transaction; administrators should review host-change permissions.
- No deployment or signing key should be inferred from the repository. Review scripts before running as root.
