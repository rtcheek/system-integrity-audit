# Conservative automatic SMART short self-tests (v2.0.0)

This feature is included in v2.0.0 and is enabled by default with `SMART_SHORT_TEST_AUTO=1`. It may send a short self-test command to a physical disk, which changes the disk's internal test state, **not** the filesystem or package database. Review and validate on your own hardware before deploying widely.

## Eligibility and scheduling

The audit considers only a **directly addressable ATA device** whose regular SMART health check is OK. It skips NVMe, SCSI, MegaRAID passthrough, and other device paths with unverified test semantics; these devices still receive their ordinary health checks.

For an ATA drive, the audit:

1. Requests capability, current execution status, the native SMART self-test log, and power-on hours using read-only `smartctl -c -l selftest -A DEVICE`.
2. Skips an unsupported, ambiguous or unreadable test status; skips when the firmware indicates a test in progress.
3. Skips if the most recent logged test **did not complete successfully**; a failed test requires attention, not an automatic replacement.
4. Uses the root-only last-start date for tests previously initiated by the audit. It will not start again within **60 calendar days** (`SMART_SHORT_TEST_AGE_DAYS`).
5. Interprets the drive's older ATA self-test log using its power-on-hour counter. It requires **at least 60 × 24 = 1,440 additional powered-on hours** since the last successful logged test, conservatively skipping when the device's power-on history is too short or ambiguous. **This is not a true 60-calendar-day guarantee** for drives that are powered off frequently or counters that wrap.
6. Samples aggregate CPU counters twice, one second apart from `/proc/stat`. The measured CPU *idle* must be **strictly greater than 98%**, and the measured I/O wait must be **strictly less than 2%**. If metrics are unavailable or inconsistent, it skips.
7. Starts **at most one device per audit invocation**, using `smartctl -t short DEVICE`. No captive (`-C`) or force option is used. It never waits for the test to finish.

The only automatic test-start state file is `/var/lib/system-integrity-audit/smart-short-tests.tsv` by default. It is protected by directory mode 0700 and file mode 0600; the audit uses its existing singleton lock to serialize access and records the start attempt before calling smartctl. Do not manually delete it simply to trigger another test. The normal notification-state file remains separate.

### Results and progress

The terminal progress stream includes lines such as:

```text
[SMART-TEST] STARTED /dev/sda: non-captive short test initiated; result checked next audit
[SMART-TEST] SKIPPED /dev/sda: last logged test within 1440 powered-on hours
[SMART-TEST] SKIPPED /dev/sda: firmware reports a self-test already in progress
```

The full audit includes **SMART short self-test activity** and initiated/skipped counters. Subsequent audits read the drive's test log to display the most recent result. A scheduled test is not waited on, and a successful initiation is **not** represented as a completed/passed test. The activity message may be visible even when the stateful email system decides no repeat report is due; use `FORCE_REPORT=1` to review the full report.

### Safety and operational trade-offs

- Non-captive self-tests allow mounted filesystems to remain online but can reduce drive performance temporarily.
- A one-second *aggregate CPU* sample measures host load, **not per-device disk saturation**. It is a strict quiet-host gate, not a guarantee the disk is idle. Consider off-peak scheduling for sensitive workloads.
- If SMART capability, history, hardware type, CPU counters or persistent state cannot be verified, **skip**; do not force the operation.
- The last-log power-on-hour comparison is a conservative approximation. Firmware that resets or wraps counters can be ambiguous; review unusual logs.
- Tests are not explicitly launched during the other Linux storage checks; they may still be running after this script exits. Run a subsequent audit or `smartctl -l selftest DEVICE` after the recommended test duration.
- SMART self-test success is not a substitute for backups, I/O error monitoring or filesystem integrity checks.

## Controls and rollback

Opt out on one invocation:

```bash
sudo env SMART_SHORT_TEST_AUTO=0 REPORT_TO=username@email.address FORCE_REPORT=1 ./system-integrity-audit
```

Or configure `SMART_SHORT_TEST_AUTO=0` permanently in the job environment. The audit still performs all original SMART health checks. `SMART_SHORT_TEST_AGE_DAYS=60` adjusts the interval, and `SMART_SHORT_TEST_STATE_FILE` changes the protected local tracking path.

Since v2.0.0-dev.8, `AUTO_INSTALL_REQUIREMENTS=1` and `AUTO_ENABLE_PERSISTENT_JOURNAL=1` are the default, independently of SMART scheduling. For a cautious first live test, keep email disabled with the exact placeholder `username@email.address` and **explicitly** turn both host-change switches off:

```bash
sudo env REPORT_TO=username@email.address FORCE_REPORT=1 \
  AUTO_INSTALL_REQUIREMENTS=0 AUTO_ENABLE_PERSISTENT_JOURNAL=0 \
  ./system-integrity-audit
```

This **may start a SMART short test** if every scheduling criterion is satisfied; the two host-change switches only control package installation and journald configuration, **not** SMART tests.

## Test coverage

The shared regression suite includes mocks for a busy self-test, recent/failed/ambiguous history, persisted cooldown, strict CPU sampling, missing metrics, direct ATA eligibility, and formatting. The RPM suite remains a separate regression gate. **No actual disk firmware test has been executed by the regression suite.** Live validation is required on representative hardware before this becomes a stable release.
