#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
awk '/^trap on_exit EXIT$/{exit} {print}' "$repo/system-integrity-audit" > "$test_dir/defs"
source "$test_dir/defs"
set +e
work_dir=$test_dir
findings_events_file=$test_dir/events
notification_next_state_file=$test_dir/next
resolved_findings_file=$test_dir/resolved
NOTIFICATION_STATE_FILE=$test_dir/state/findings.tsv
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
clear_coverage() {
 execution_error=0; kernel_scan_error=0; kernel_persistence_error=0
 filesystem_check_error_count=0; smart_error_count=0; smart_unsupported_count=0
 package_run_status=0; coverage_status=0; coverage_count=0
 kernel_coverage_gap=0; kernel_coverage_unknown=0
 KERNEL_LOG_CHECK_ENABLED=1; FILESYSTEM_CHECKS_ENABLED=1; SMART_CHECK_ENABLED=1
 XFS_SCRUB_AUTO=1; REPORT_COVERAGE_GAPS=1
 smart_selftest_verified=()
 smart_health_verified=(); filesystem_resource_verified=()
}
seed() {
 clear_coverage
 rm -f "$NOTIFICATION_STATE_FILE"
 : > "$findings_events_file"
 record_finding ALERT "$1" "$2" 'previous failure'
 prepare_notifications
 save_notification_state 1 || fail 'seed state'
 old_state=$(cat "$NOTIFICATION_STATE_FILE")
 : > "$findings_events_file"
}
retained() {
 prepare_notifications
 [[ $notification_resolved_count == 0 && $notification_unverified_count == 1 ]] || fail 'unverified finding reported resolved'
 save_notification_state 1 || fail 'save retained state'
 [[ $(cat "$NOTIFICATION_STATE_FILE") == "$old_state" ]] || fail 'retained state or last-mailed timestamp changed'
}
seed PACKAGE /critical
execution_error=1
record_finding ERROR EXECUTION audit 'scan failed'
prepare_notifications
[[ $notification_resolved_count == 0 && $notification_unverified_count == 1 ]] || fail 'scan failure resolved prior package alert'
save_notification_state 1
[[ $(grep /critical "$NOTIFICATION_STATE_FILE") == "$old_state" ]] || fail 'failed scan dropped previous package alert'
clear_coverage
: > "$findings_events_file"
prepare_notifications
[[ $notification_resolved_count == 2 ]] || fail 'successful full scan did not resolve old findings'
pass 'failed scan preserves prior alerts until successful coverage returns'
for kind in disabled partial unsupported self-test xfs; do
 case $kind in
 disabled) seed SMART /dev/a; SMART_CHECK_ENABLED=0 ;;
 partial) seed PACKAGE /critical; coverage_count=1 ;;
 unsupported) seed SMART /dev/a; smart_unsupported_count=1 ;;
 self-test) seed SMART '/dev/nvme0 [self-test]' ;;
 xfs) seed XFS-SCRUB /; XFS_SCRUB_AUTO=0 ;;
 esac
 retained
 done
pass 'disabled, partial and unsupported checks preserve prior state and notification timestamps'
seed SMART '/dev/nvme0 [self-test]'
smart_selftest_verified['/dev/nvme0 [self-test]']=1
prepare_notifications
[[ $notification_resolved_count == 1 ]] || fail 'verified clean self-test result did not resolve warning'
seed KERNEL journal
kernel_coverage_unknown=1
retained
pass 'self-test resolution requires verified history and kernel resolution requires coverage'
seed SMART /dev/missing
smart_health_verified[/dev/present]=1
retained
smart_health_verified[/dev/missing]=1
prepare_notifications
[[ $notification_resolved_count == 1 ]] || fail 'queried SMART resource could not resolve'
seed SPACE /missing-mount
mark_filesystem_resource_verified SPACE /present-mount
retained
mark_filesystem_resource_verified SPACE /missing-mount
prepare_notifications
[[ $notification_resolved_count == 1 ]] || fail 'checked mounted resource could not resolve'
seed ZFS-POOL missing-pool
mark_filesystem_resource_verified ZFS-POOL present-pool
retained
mark_filesystem_resource_verified ZFS-POOL missing-pool
prepare_notifications
[[ $notification_resolved_count == 1 ]] || fail 'checked pool resource could not resolve'
pass 'absent devices, mounts and pools remain unverified until that resource is positively checked'
seed PACKAGE /critical
: > "$findings_events_file"
prepare_notifications
before=$(cat "$NOTIFICATION_STATE_FILE")
(
 trap '' XFSZ
 ulimit -f 0
 save_notification_state 0
) 2> "$test_dir/write-error"
rc=$?
[[ $rc != 0 && $(cat "$NOTIFICATION_STATE_FILE") == "$before" ]] || fail 'state-write error lost notification state'
pass 'notification state write errors preserve existing state and return failure'
echo 'All notification regression tests passed.'
