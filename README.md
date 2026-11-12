# System Integrity Audit

A cross-distribution Linux system-integrity and storage-health auditing project.

**Status:** Version 2.0 is under development. The existing Ubuntu `debsums-audit` v1.7.1 remains the stable reference implementation. The new code on [`develop/v2.0`](https://github.com/rtcheek/system-integrity-audit/tree/develop/v2.0) is an experimental Debian/Ubuntu-only preview; Rocky Linux/RHEL package verification is not implemented yet.

## Email reporting

Email reporting is retained. The default `REPORT_TO="username@email.address"` is a **placeholder**, not a destination. When that value is unchanged (or empty), the audit does not send email. Configure a real recipient to enable it. See the [development README](https://github.com/rtcheek/system-integrity-audit/blob/develop/v2.0/README.md) and [example configuration](https://github.com/rtcheek/system-integrity-audit/blob/develop/v2.0/config/example.env).

## License

MIT. See [LICENSE](LICENSE).
