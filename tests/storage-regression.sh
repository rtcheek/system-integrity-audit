#!/usr/bin/env bash
# Safe function-level storage/parser tests. No real storage commands are run.
set -euo pipefail
SCRIPT=${1:-"$(dirname "$0")/../system-integrity-audit"}
SCRIPT=$(readlink -f -- "$SCRIPT")
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
awk '/^trap on_exit EXIT$/{exit} {print}' "$SCRIPT" > "$test_dir/definitions.sh"
# shellcheck disable=SC1090
source "$test_dir/definitions.sh"
set +e # The audit deliberately captures nonzero probe statuses.
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
assert_eq() { [[ $1 == "$2" ]] || fail "$3 (got '$1', expected '$2')"; }
work_dir=$test_dir
local_filesystems_file=$test_dir/filesystems
filesystem_findings_file=$test_dir/fs-findings
filesystem_details_file=$test_dir/fs-details
changed_file=$test_dir/rpm-input
diagnostics_file=$test_dir/rpm-diagnostics
findings_file=$test_dir/package-findings
ignored_findings_file=$test_dir/package-ignored
diagnostics_safe_file=$test_dir/safe-diagnostics
coverage_safe_file=$test_dir/coverage
FORCE_REPORT=0
PACKAGE_BACKEND=rpm
lookup_package_owners() { printf 'fixture-package-1.0\n'; }
# Presence detection sees these functions, and every invocation is intercepted
# by run_probe below. Never fall back to commands installed on the host.
btrfs() { fail 'unmocked btrfs invocation'; }
zpool() { fail 'unmocked zpool invocation'; }
run_probe() {
    printf '%s\n' "$*" >> "$test_dir/probes"
    case "$2:$3" in
        btrfs:device) cat "$test_dir/btrfs-device"; return 0 ;;
        btrfs:scrub) cat "$test_dir/btrfs-scrub"; return "${MOCK_BTRFS_STATUS:-0}" ;;
        zpool:list) printf 'tank\n'; return 0 ;;
        zpool:status)
            [[ ${4:-}:${5:-}:${6:-} == -p:-v:tank ]] || fail 'ZFS counters must request exact numeric output'
            cat "$test_dir/zpool-status"
            return "${MOCK_ZFS_STATUS:-0}"
            ;;
        *) fail "unexpected probe: $*" ;;
    esac
}
reset_fs() {
    filesystem_resource_verified=()
    filesystem_alert_count=0
    filesystem_warning_count=0
    filesystem_notice_count=0
    filesystem_check_error_count=0
    btrfs_filesystem_count=0
    zfs_pool_count=0
    : > "$filesystem_findings_file"
    : > "$filesystem_details_file"
    : > "$test_dir/probes"
    MOCK_BTRFS_STATUS=0
    MOCK_ZFS_STATUS=0
}
prepare_btrfs() {
    reset_fs
    printf '/dev/fixture\t/test\tbtrfs\trw\n' > "$local_filesystems_file"
    printf '[/dev/fixture].read_io_errs 0\n[/dev/fixture].corruption_errs 0\n' > "$test_dir/btrfs-device"
}
write_btrfs_scrub() {
    printf 'UUID: fixture\nStatus: finished\nError summary: csum=3\n  Corrected: %s\n  Uncorrectable: %s\n  Unverified: %s\n' "$1" "$2" "$3" > "$test_dir/btrfs-scrub"
}
prepare_zfs() {
    reset_fs
    printf 'tank/data\t/test\tzfs\trw\n' > "$local_filesystems_file"
    {
        printf '  pool: tank\n state: ONLINE\n'
        printf '  scan: scrub repaired 0B in 00:00:01 with 0 errors on %s\n' "$(date)"
        printf 'config:\n\n'
        printf '        %-64s %-8s %5s %5s %5s\n' NAME STATE READ WRITE CKSUM
        zfs_row tank ONLINE 0 0 0
        zfs_row '  mirror-0' ONLINE 0 0 0
    } > "$test_dir/zpool-status"
}
zfs_row() { printf '        %-64s %-8s %5s %5s %5s\n' "$1" "$2" "$3" "$4" "$5"; }
finish_zfs() { printf '\nerrors: No known data errors\n' >> "$test_dir/zpool-status"; }

# Timestamp policy applies to config files as well as ordinary payloads.
: > "$diagnostics_file"
printf '.......T.  c /etc/fixture.conf\n.......T.    /usr/share/fixture.txt\n' > "$changed_file"
RPM_REPORT_TIMESTAMP_ONLY=0 build_rpm_findings
assert_eq "$rpm_timestamp_ignored_count:$package_warning_count:$package_notice_count" '2:0:0' 'RPM timestamp-only config policy'
[[ ! -s $findings_file ]] || fail 'timestamp-only records leaked into default findings'
pass 'RPM timestamp-only config and payload drift is ignored by default'

RPM_REPORT_TIMESTAMP_ONLY=1 build_rpm_findings
assert_eq "$package_warning_count:$package_notice_count" '0:2' 'RPM timestamp opt-in must be NOTICE for config and payload'
assert_eq "$(grep -c '^TIMESTAMP' "$findings_file")" 2 'RPM timestamp opt-in classifications'
pass 'RPM timestamp opt-in produces notices consistently for config and payload'

printf '..5....T.  c /etc/fixture.conf\n..5......    /usr/bin/fixture\nmissing   c /etc/missing.conf\n' > "$changed_file"
RPM_REPORT_TIMESTAMP_ONLY=0 build_rpm_findings
assert_eq "$package_warning_count:$changed_count:$missing_count" '1:1:1' 'RPM real changes and missing files retain severity'
pass 'RPM non-timestamp config changes, payload changes and missing files keep their classifications'

prepare_btrfs; write_btrfs_scrub 3 0 0
check_btrfs_status
assert_eq "$filesystem_alert_count:$filesystem_warning_count:$filesystem_check_error_count" '0:1:0' 'modern Btrfs corrected-only result'
grep -q 'corrected 3 error' "$filesystem_findings_file" || fail 'Btrfs corrected count absent'
pass 'modern Btrfs corrected-only scrub is WARNING rather than ALERT'

prepare_btrfs; write_btrfs_scrub 3 2 0
check_btrfs_status
assert_eq "$filesystem_alert_count:$filesystem_warning_count" '1:0' 'Btrfs uncorrectable errors take precedence'
grep -q '2 uncorrectable' "$filesystem_findings_file" || fail 'Btrfs uncorrectable count absent'
pass 'modern Btrfs uncorrectable errors remain ALERT even with corrected errors'

prepare_btrfs; write_btrfs_scrub 3 0 2
check_btrfs_status
assert_eq "$filesystem_alert_count:$filesystem_warning_count" '1:0' 'Btrfs unverified errors must not become corrected-only'
pass 'Btrfs unverified errors cannot be hidden by a corrected count'

prepare_btrfs
printf 'Status: finished\ncorrected_errors: 3\nuncorrectable_errors: 0\nunverified_errors: 0\n' > "$test_dir/btrfs-scrub"
check_btrfs_status
assert_eq "$filesystem_alert_count:$filesystem_warning_count:$filesystem_check_error_count" '0:1:0' 'raw/older Btrfs counters'
pass 'raw and older Btrfs counter labels remain supported'

prepare_btrfs
printf 'Status: finished\nError summary: no errors found\n' > "$test_dir/btrfs-scrub"
check_btrfs_status
assert_eq "$filesystem_alert_count:$filesystem_warning_count" '0:0' 'clean Btrfs scrub'
prepare_btrfs
printf 'Status: finished\nError summary: csum=3\nCorrected: 3\nUncorrectable: unknown\nUnverified: 0\n' > "$test_dir/btrfs-scrub"
check_btrfs_status
assert_eq "$filesystem_alert_count" 1 'unknown remaining counters cannot establish corrected-only result'
pass 'Btrfs clean output remains clean and malformed remaining counts fail closed'

prepare_zfs
zfs_row '    disk-a' ONLINE 0 0 5 >> "$test_dir/zpool-status"
zfs_row '    disk-b' ONLINE 0 0 0 >> "$test_dir/zpool-status"
finish_zfs
check_zfs_status
assert_eq "$filesystem_alert_count:$filesystem_warning_count:$filesystem_check_error_count" '0:1:0' 'ONLINE ZFS checksum error detection'
grep -q 'ZFS-DEVICE.*disk-a.*READ=0 WRITE=0 CKSUM=5' "$filesystem_findings_file" || fail 'ZFS leaf counter finding missing'
[[ -s $filesystem_details_file ]] || fail 'ZFS vdev errors did not retain status detail'
pass 'ONLINE ZFS pool with checksum errors generates a finding and retains details'

prepare_zfs
zfs_row '    disk-a' ONLINE 7 0 0 >> "$test_dir/zpool-status"
zfs_row '    disk-b' ONLINE 0 3 0 >> "$test_dir/zpool-status"
finish_zfs
check_zfs_status
assert_eq "$filesystem_warning_count:$filesystem_check_error_count" '2:0' 'ZFS read/write error detection'
pass 'ZFS read and write error counters generate per-vdev warnings'

prepare_zfs
zfs_row '    disk-a' ONLINE 0 0 0 >> "$test_dir/zpool-status"
printf '\n        spares\n' >> "$test_dir/zpool-status"
printf '        %-64s %-8s\n' spare-a AVAIL >> "$test_dir/zpool-status"
printf '        %-64s %-8s currently in use\n' spare-b INUSE >> "$test_dir/zpool-status"
finish_zfs
check_zfs_status
assert_eq "$filesystem_alert_count:$filesystem_warning_count:$filesystem_check_error_count" '0:0:0' 'ZFS clean pool and spare rows'
pass 'clean ZFS pools and spare-only AVAIL/INUSE rows remain clean'

prepare_zfs
zfs_row '    /dev/disk with spaces' ONLINE 0 0 4 >> "$test_dir/zpool-status"
zfs_row '    disk ONLINE 1 2 3' ONLINE 0 0 0 >> "$test_dir/zpool-status"
finish_zfs
check_zfs_status
assert_eq "$filesystem_warning_count:$filesystem_check_error_count" '1:0' 'ZFS paths containing whitespace'
grep -Fq 'tank [/dev/disk with spaces]' "$filesystem_findings_file" || fail 'ZFS vdev path truncated'
pass 'ZFS aligned columns preserve paths with spaces and state-like words'

prepare_zfs
zfs_row '    good-counter-row' ONLINE 0 0 7 >> "$test_dir/zpool-status"
zfs_row '    malformed-counter-row' ONLINE 0 0 '?' >> "$test_dir/zpool-status"
finish_zfs
check_zfs_status
assert_eq "$filesystem_warning_count:$filesystem_check_error_count" '2:1' 'partial ZFS counter parsing'
grep -q 'good-counter-row.*CKSUM=7' "$filesystem_findings_file" || fail 'partial ZFS parse discarded known errors'
pass 'malformed ZFS counter rows mark coverage incomplete without hiding known errors'

prepare_zfs
zfs_row '    disk-a' ONLINE 0 0 5 >> "$test_dir/zpool-status"
finish_zfs
MOCK_ZFS_STATUS=1
check_zfs_status
assert_eq "$filesystem_warning_count:$filesystem_check_error_count" '2:1' 'failed ZFS query with usable partial output'
grep -q 'ZFS-DEVICE.*CKSUM=5' "$filesystem_findings_file" || fail 'failed ZFS query discarded known counter error'
pass 'ZFS failed queries retain usable error counters and report incomplete coverage'

prepare_zfs
zfs_row '    disk-a' DEGRADED 0 0 5 >> "$test_dir/zpool-status"
printf '\nerrors: Permanent errors have been detected\n' >> "$test_dir/zpool-status"
sed -i 's/^ state: ONLINE$/ state: DEGRADED/' "$test_dir/zpool-status"
check_zfs_status
assert_eq "$filesystem_alert_count:$filesystem_warning_count" '2:1' 'ZFS pool/data failures keep alert severity'
pass 'ZFS device-counter warnings do not downgrade pool or permanent-data alerts'

printf 'All storage parser regression tests passed.\n'
