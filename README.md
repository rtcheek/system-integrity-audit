# System Integrity Audit

Cross-distribution Linux package-integrity, filesystem, and storage-health auditing.

> **Status:** Version **2.0.0-dev.3** is an experimental development preview on [`develop/v2.0`](https://github.com/rtcheek/system-integrity-audit/tree/develop/v2.0). It includes Debian/Ubuntu (`debsums`) and Rocky Linux/RHEL (`rpm`) verification backends, but **live Rocky/RHEL validation is still required**. The existing `debsums-audit` v1.7.1 remains the stable Ubuntu reference.

## Get started

Read the [development README](https://github.com/rtcheek/system-integrity-audit/blob/develop/v2.0/README.md) for configuration, testing, and safe deployment. The development branch includes:

- [Audit script](https://github.com/rtcheek/system-integrity-audit/blob/develop/v2.0/system-integrity-audit)
- [Shared Ubuntu regressions](https://github.com/rtcheek/system-integrity-audit/blob/develop/v2.0/tests/regression.sh)
- [Rocky/RHEL regressions](https://github.com/rtcheek/system-integrity-audit/blob/develop/v2.0/tests/rpm-regression.sh)
- [RPM backend documentation](https://github.com/rtcheek/system-integrity-audit/blob/develop/v2.0/docs/rpm-backend.md)

## Safe defaults

Email reporting is retained. The default recipient is `username@email.address`; leaving that exact placeholder unchanged means **no email is sent**. Package auto-installation and journald auto-configuration are disabled by default.

## License

MIT; see [LICENSE](LICENSE).
