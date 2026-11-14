# System Integrity Audit

Linux package-integrity, storage-health, and filesystem auditing, with terminal and optional multipart email reporting.

Version **2.0.0** provides Debian/Ubuntu (`debsums`) and Rocky Linux/RHEL (`rpm`) package-integrity backends. Live audits and automatic prerequisite reinstallation have completed on Ubuntu 24.04 and Rocky Linux 9.8. Check-only XFS scans of `/`, `/boot`, and `/home` completed successfully on the Rocky test host. The platform table below distinguishes live validation from simulated coverage and experimental platforms.

## Get started

```bash
git clone https://github.com/rtcheek/system-integrity-audit.git
cd system-integrity-audit
git switch main
./system-integrity-audit --version
sudo bash tests/regression.sh
sudo bash tests/rpm-regression.sh
```

Expected version: `system-integrity-audit 2.0.0`. Review the automatic-change defaults below before running an audit as root. For an existing checkout, switch to `main` and run `git pull --ff-only` before checking the version.

## Platform support

| OS family | Package verification | Validation |
| --- | --- | --- |
| Ubuntu 20.04 LTS | `debsums -ca` and `debsums -l` | systemd 245, journald, and end-to-end mock regressions pass; live host validation pending |
| Ubuntu 22.04/24.04 LTS | `debsums -ca` and `debsums -l` | Ubuntu 24.04 live audit completed; Ubuntu 22.04 simulated regressions pass, live validation pending |
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

## Automatic SMART short self-tests

**Enabled by default** in v2.0.0: `SMART_SHORT_TEST_AUTO=1`. The audit may start a *non-captive*, background ATA SMART short self-test on a directly attached disk if **all** of these checks pass:

- The device's focused SMART health result is OK, ATA self-tests are supported, and self-test history is readable.
- No self-test is already running, no previous self-test has an unreviewed failure, and no recent test is recorded. Previous script-initiated tests use a calendar timestamp; older ATA history uses elapsed **power-on hours as a conservative proxy**, not a guaranteed calendar age.
- At least 60 days have elapsed since the last audit-started test, and older completed test history is at least 1,440 powered-on hours old. If history is ambiguous, the test is skipped.
- A one-second aggregate `/proc/stat` CPU sample measures **idle strictly above 98%** and **I/O wait strictly below 2%**. If metrics are unavailable or thresholds fail, the test is skipped.
- No other test has been started during this audit. The script never uses captive mode or a force flag, does not wait for completion, and stores a root-only start timestamp before dispatching the command to prevent duplicate starts.

SMART short-test activity appears in the terminal progress and full report, with `STARTED`, `SKIPPED`, or `DISABLED` and the reason. On color-capable terminals, `[SMART-TEST]` progress uses the same warning-yellow coloring as `[WARN]`; plain output and `NO_COLOR` remain unchanged. Logged self-test results are examined on subsequent audits. Other health checks still run on NVMe, SCSI, and RAID devices, but **automatic test initiation skips them** until their semantics are separately validated.

To opt out for a single run:

```bash
sudo env SMART_SHORT_TEST_AUTO=0 REPORT_TO=username@email.address FORCE_REPORT=1 ./system-integrity-audit
```

See [SMART scheduler notes](docs/smart-short-tests.md) for details and caveats. Starting a non-captive SMART test is designed to allow ongoing disk I/O, but it **can temporarily reduce performance**; test on representative hardware before routine scheduling.

## Periodic check-only XFS scrubbing

**Opt-in:** `XFS_SCRUB_AUTO=0` by default. To let a recurring audit perform weekly metadata checks:

```bash
sudo env XFS_SCRUB_AUTO=1 XFS_SCRUB_INTERVAL_DAYS=7 \
  AUTO_ENABLE_PERSISTENT_JOURNAL=0 SMART_SHORT_TEST_AUTO=0 \
  REPORT_TO=username@email.address FORCE_REPORT=1 ./system-integrity-audit
```

Use `XFS_SCRUB_AUTO=1` in the environment of each scheduled audit to keep this behavior enabled. The script does not install a timer or daemon: the first enabled audit checks eligible filesystems immediately, and later audits check again when at least seven days have elapsed since each filesystem's **last attempt**. Failed or interrupted attempts also wait for that interval; they do not cause an expensive scan on every audit.

- Requires `FILESYSTEM_CHECKS_ENABLED=1` and an existing `xfs_scrub` executable. No XFS package is installed or timer enabled by this feature.
- Runs only `xfs_scrub -n <mountpoint>`, sequentially, with closed stdin. It requests **no repairs or optimizations**, no `xfs_scrub_all` invocation and no file-data/media scan. XFS online scrubbing may still be experimental on your installed version and can consume substantial I/O/CPU resources; keep current backups and choose an appropriate audit window.
- Defaults to a **3,600-second timeout per filesystem**, configurable with `XFS_SCRUB_TIMEOUT_SECONDS` (1–86,400). Several filesystems can extend an audit by several hours. A timeout is reported as incomplete; it is never described as a successful check.
- Verifies mounted XFS UUID and filesystem root, deduplicates UUIDs, and skips bind-marked/subdirectory mounts. UUID-based scheduling survives device-path aliases. Filesystems whose identity cannot be verified are skipped with an incomplete-check warning.
- Starts no new scan if the stock `xfs_scrub_all.timer` is enabled/active, its state is unknown, the stock scrub service is active/starting, or another `xfs_scrub`/`xfs_scrub_all` process is detected. Process detection is checked before each scan. External administrators must still avoid starting other scrub jobs concurrently; this is not a shared lock with external tools. The audit's own singleton lock prevents overlapping audit runs using the same lock file.
- Stores timestamps, exit results and output in private UUID-named files under `XFS_SCRUB_STATE_DIR` (default `/var/lib/system-integrity-audit/xfs-scrub`). The directory must be owned by the audit user (root in normal runs), mode `0700`; records must be mode `0600`. Symlinks, malformed state and future timestamps fail closed. An attempt is recorded **before** dispatch, so an interrupted audit is reported as incomplete on subsequent runs.
- Includes the last saved result and sanitized output in later reports, even when another scan is not due. Exit 0 informational optimization/confusable-name messages remain informational. Exit bit 1 reports uncorrected filesystem errors as ALERT; bit 2 alone is NOTICE; operational/usage errors, signals and timeouts mark coverage incomplete. These exit bits apply to `xfs_scrub`, not `xfs_scrub_all`.

`[XFS-SCRUB]` progress shows each check's start and finish in warning yellow, honoring `NO_COLOR` and progress settings. During a scan the filesystem-stage spinner is paused; detailed command output appears in the report. When audit-managed XFS checks are enabled, their results replace the disabled-stock-timer notice. With `XFS_SCRUB_AUTO=0`, the existing timer-inspection behavior is unchanged. Disabling all filesystem checks also disables this scheduler.

A successful metadata check is evidence about filesystem consistency; it does not establish that file contents or storage hardware are healthy. Mock regressions cover interval suppression, persistent results and failure handling. Script-managed check-only scans completed with exit 0 on all three XFS filesystems on a Rocky Linux 9.8 host. A repeat live audit confirming interval suppression remains pending.

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

## Automatic host changes (enabled by default since v2.0.0-dev.8)

**Both switches now default to `1`:**

```bash
AUTO_INSTALL_REQUIREMENTS=1
AUTO_ENABLE_PERSISTENT_JOURNAL=1
```

When run with sufficient privileges, the audit **may install missing prerequisites using APT (Debian/Ubuntu) or DNF (RPM systems)** and **may configure/restart journald to enable persistent kernel logs when necessary**. These are conditional actions: setting `1` does not force a package transaction or journal change when everything is already configured. The opt-in XFS scheduler can run bounded check-only metadata scans. The audit also creates private lock, temporary, and state files, and the default SMART short-test scheduler may start a non-captive drive self-test under its strict eligibility gates. **Review the script and these side effects before running it as root on a production host.**

Since v2.0.0-dev.11, automatic APT installation on Debian/Ubuntu runs with noninteractive debconf, standard input from `/dev/null`, dpkg pseudo-terminal disabled, and conservative conffile options. GNU `timeout --foreground` avoids the stopped/background-process-group behavior seen during a live Ubuntu 24.04 `debsums` install. APT output is captured in the audit's temporary log. Since v2.0.0-dev.12, when progress display is enabled (`PROGRESS_OUTPUT=auto` on a terminal, or `always`), the prerequisite spinner stops before installation messages or lock waits, and APT/DNF output streams to standard error while also being logged. The prerequisite result is printed afterward and normal audit progress resumes. With progress disabled, successful installation output stays in the log; failure diagnostics retain their existing behavior. Timeouts fail the installation without automatically starting another package transaction; foreground timeout cannot guarantee termination of all package-maintenance child processes. The unattended APT fix has mock and pseudo-terminal regression coverage and passed a live Ubuntu 24.04 reinstall test; the audit then advanced through prerequisite verification and built its report.

For the new default behavior, with email disabled:

```bash
sudo env REPORT_TO=username@email.address FORCE_REPORT=1 ./system-integrity-audit
```

To **disable both automatic host changes** for a cautious first run or unattended use where host modifications are not approved:

```bash
sudo env AUTO_INSTALL_REQUIREMENTS=0 AUTO_ENABLE_PERSISTENT_JOURNAL=0 \
  REPORT_TO=username@email.address FORCE_REPORT=1 ./system-integrity-audit
```

The controls are independent: set either to `0` to disable just that action. Neither setting disables local lock/state writes or SMART self-test initiation; use `SMART_SHORT_TEST_AUTO=0` separately to opt out of firmware tests. The placeholder `REPORT_TO` still disables email.

The report's package-backend and verifier-exit fields use the same fixed-width value column as other summary fields. The count label is abbreviated to `Pkg config/metadata warnings` to preserve alignment in both plain-text and HTML email reports.

## Regression tests

```bash
git switch main
bash ./system-integrity-audit --version
sudo bash tests/regression.sh
sudo bash tests/rpm-regression.sh
```

The shared suite includes unattended APT command, timeout, lock-retry and pseudo-terminal job-control tests, SMART self-test scheduling, report formatting, stable-notification identity and approved-missing regression cases and also mocks Ubuntu's `dpkg-query`, so its Ubuntu scenarios run on RPM-based test hosts without requiring Debian packages. The regression suites use simulated hardware, journals, RPM results, and email. They cannot validate real device and storage behavior. Inspect the report's **Audit coverage** section and review all unexpected RPM differences on your actual machine before wider deployment.

See [example environment options](config/example.env). Suggestions and redacted false-positive examples are welcome through GitHub issues.

## Security and licensing

Redact serial numbers, hostnames, usernames, addresses, and other private operational details before posting logs publicly. MIT license; see [LICENSE](LICENSE).
