# Conservative automatic SMART short self-tests (v2.0.4)

ATA support was included in v2.0.0; native NVMe support was added in v2.0.3. The feature is enabled by default with `SMART_SHORT_TEST_AUTO=1`. It may send a short self-test command to a physical disk, which changes the disk's internal test state, **not** the filesystem or package database. Review and validate on your own hardware before deploying widely.

## Eligibility and scheduling

The audit considers a **directly addressable ATA disk** or a **verified native NVMe controller** whose regular SMART health check is OK. It skips SCSI, USB bridges, MegaRAID passthrough, and other paths with unverified test semantics; those devices still receive ordinary health checks.

For an ATA drive, the audit:

1. Requests capability, current execution status, the native SMART self-test log, and power-on hours using read-only `smartctl -c -l selftest -A DEVICE`.
2. Skips an unsupported, ambiguous or unreadable test status; skips when the firmware indicates a test in progress.
3. Skips if the most recent logged test **did not complete successfully**; a failed test requires attention, not an automatic replacement.
4. Uses the root-only last-start date for tests previously initiated by the audit. It will not start again within **60 calendar days** (`SMART_SHORT_TEST_AGE_DAYS`).
5. Interprets the drive's older ATA self-test log using its power-on-hour counter. It requires **at least 60 × 24 = 1,440 additional powered-on hours** since the last successful logged test, conservatively skipping when the device's power-on history is too short or ambiguous. **This is not a true 60-calendar-day guarantee** for drives that are powered off frequently or counters that wrap.
6. Samples aggregate CPU counters twice, one second apart from `/proc/stat`. The measured CPU *idle* must be **strictly greater than 98%**, and the measured I/O wait must be **strictly less than 2%**. If metrics are unavailable or inconsistent, it skips.
7. Attempts a test on **at most one device per audit invocation**, shared with NVMe, using `smartctl -t short DEVICE`. No captive (`-C`) or force option is used. It never waits for the test to finish.

### Native NVMe controllers

The NVMe path is separate from ATA parsing:

1. Map `/dev/nvmeNnM` namespaces to `/dev/nvmeN`. Deduplicate controller paths and model/serial identities. Ambiguous multipath names and non-native transports are not eligible.
2. Query `smartctl -H -i -c -A -l selftest -d nvme,0xffffffff /dev/nvmeN`. Require smartctl **7.4+**, advertised `Self_Test` support, PASSED health with `Critical Warning: 0x00`, an explicit idle self-test status, valid power-on hours and readable history. Old tools receive a specific skip reason; the script does not replace smartmontools or install nvme-cli.
3. Parse only the NVMe self-test log section and rows after its table header. Ignore numbered power-state and LBA-format tables, including row 0. Duplicate or malformed self-test sections fail closed. Refuse failed, aborted, unknown, contradictory or missing previous results. If there is a prior successful short/extended test, require at least 1,440 additional powered-on hours by default. Grouped values such as `6,000` are accepted; backwards counters are treated as reset/ambiguous, not wrapped.
4. Use a model/serial-derived key in the existing state file, so controller renumbering cannot bypass the 60-calendar-day cooldown. Reject unsafe, malformed or duplicate state. Apply the same strict CPU idle/iowait gates as ATA.
5. Persist intent, then re-read the log immediately before dispatch. Changed history, a running test or an unreadable status prevents dispatch; the cooldown remains in place. Manual tests started concurrently are also subject to smartctl's own busy check.
6. Attempt only `smartctl -t short -d nvme,0xffffffff /dev/nvmeN`: a short test with broadcast NSID, covering all namespaces. Explicit broadcast addressing works around the namespace-scoped self-test-log issue in smartctl 7.4. No force, abort, captive or extended-test command is used.
7. Report `STARTED` only when the command succeeds and acknowledges that the self-test began. A rejected or unconfirmed command is `FAILED`, keeps its cooldown, and consumes the shared per-audit attempt budget. Results are read on later audits; initiation is never described as a completed test. Unsuccessful/unrecognized latest results and failed/unacknowledged start commands create a normal SMART warning row and enter the existing notification policy, even when overall health still says PASSED.

The native NVMe path has mock-based coverage; live automatic initiation remains pending on representative hardware. NVMe firmware tests can temporarily affect performance even while normal I/O continues. Use the opt-out below for hosts on which automatic tests are not approved. To inspect capability/history manually without starting a test:

```bash
smartctl --version
sudo smartctl -H -i -c -A -l selftest -d nvme,0xffffffff /dev/nvme0
```

`FORCE_REPORT=1` retains the controller capability/history query in the audit report. Read a controller's completed test log with `sudo smartctl -l selftest -d nvme,0xffffffff /dev/nvme0`.

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

The shared regression suite includes ATA and NVMe mocks covering active/failed/ambiguous histories, old tools, unsupported capabilities, controller and namespace deduplication, renumbering, grouped power-on hours, cooldown and unsafe state, strict CPU gates, query timeouts, pre-dispatch races, missing acknowledgements and the shared attempt budget. The RPM suite remains a separate regression gate. **No actual disk firmware test has been executed by the regression suite.** Live automatic NVMe initiation still requires validation on representative hardware; existing health checks remain unchanged.
