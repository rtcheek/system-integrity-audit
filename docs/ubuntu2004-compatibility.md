# Ubuntu 20.04 LTS compatibility (v2.0.0-dev.4)

**Status:** Development-preview compatibility verified with simulated Ubuntu 20.04 inputs and systemd **245** behavior. No live Ubuntu 20.04 host has yet been used for certification.

## Checked interfaces

- **Bash / package verification:** Ubuntu uses the same `dpkg-query`, `debsums -ca`, and `debsums -l` adapter as Ubuntu 22.04 and 24.04.
- **Kernel journal:** Focal's systemd 245 does not support `journalctl --lines=+1`. The audit's **bounded, early-terminating stream** reads the oldest available `_TRANSPORT=kernel` event instead; it never has to export the complete retained history just to estimate coverage. A valid oldest entry is required; unexpected query failures and timeouts still mark coverage incomplete.
- **Persistent journald:** `systemd-analyze cat-config systemd/journald.conf` is supported on Focal. The audit reads it without automatically changing journald settings.
- **Filesystem, SMART, and RAID:** The existing generic Linux checks are retained. Behavior for particular devices still needs real-host validation.
- **Ubuntu 18.04 or older:** Explicitly rejected rather than silently claiming a complete audit. The minimum Ubuntu version recognized by this development line is 20.04 LTS.

## Regression tests

Run the simulated tests first:

```bash
bash tests/regression.sh
bash tests/rpm-regression.sh
```

The shared suite now covers mocked systemd 245, 249, and 255 journal branches; journald storage modes; an Ubuntu 20.04 end-to-end package/journal report with email disabled; and rejection of Ubuntu 18.04. The RPM suite guards against regressions to Rocky/RHEL.

### Optional cautious live test on a Focal host

Review the script first. Since v2.0.0-dev.8, automatic prerequisite installation and persistent journald setup are **enabled by default** when the script runs with sufficient privileges. For a cautious first live test on Ubuntu 20.04, disable both explicitly:

```bash
sudo env \
  REPORT_TO=username@email.address \
  AUTO_INSTALL_REQUIREMENTS=0 \
  AUTO_ENABLE_PERSISTENT_JOURNAL=0 \
  FORCE_REPORT=1 \
  bash ./system-integrity-audit
```

This performs the audit without emailing or automatically installing packages/configuring journald. It may create local lock, temporary, and notification-state files. Review the **Audit coverage** section for incomplete checks and capture sanitized diagnostic output if an Ubuntu 20.04 incompatibility appears.

Ubuntu 20.04 ended its standard five-year support period in April 2025; plan for a supported upgrade or appropriate Ubuntu Pro/ESM coverage before production use.

## Release policy

This is a **development preview**, not a production-supported promise for every Focal system. Keep the existing Ubuntu `debsums-audit` v1.7.1 deployment as the known working reference until you validate the new version on representative hardware.
