#!/usr/bin/env bash
# Non-destructive regression fixtures for system-integrity-audit 2.0.0-dev.2.
# Run: bash tests/regression.sh [path/to/system-integrity-audit]
set -euo pipefail
SCRIPT=${1:-"$(dirname "$0")/../system-integrity-audit"}
[[ -r $SCRIPT ]] || { echo "Missing script: $SCRIPT" >&2; exit 1; }
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
# Source only function definitions/configuration; do NOT execute the audit.
awk '/^trap on_exit EXIT$/{exit} {print}' "$SCRIPT" > "$test_dir/definitions.sh"
# shellcheck disable=SC1090
source "$test_dir/definitions.sh"
set +e # Script deliberately captures nonzero probe statuses; never use errexit
mkdir -p "$test_dir/bin" "$test_dir/journal"
work_dir=$test_dir
kernel_raw_file=$test_dir/kernel-raw.txt
kernel_export_file=$test_dir/kernel-export.txt
kernel_events_file=$test_dir/kernel-events.txt
kernel_matches_raw_file=$test_dir/kernel-matches.txt
kernel_findings_file=$test_dir/kernel-alerts.txt
kernel_warnings_file=$test_dir/kernel-warnings.txt
kernel_scan_error_file=$test_dir/kernel-errors.txt
smart_summary_file=$test_dir/smart-summary.tsv
smart_details_file=$test_dir/smart-details.txt
filesystem_findings_file=$test_dir/fs-findings.tsv
filesystem_details_file=$test_dir/fs-details.txt
local_filesystems_file=$test_dir/fs-local.tsv
findings_file=$test_dir/package-findings.tsv
automatic_changes_file=$test_dir/automatic-changes.tsv
findings_events_file=$test_dir/events.tsv
notification_next_state_file=$test_dir/next-state.tsv
resolved_findings_file=$test_dir/resolved.tsv
execution_notes_file=$test_dir/execution-notes.txt
NOTIFICATION_STATE_FILE=$test_dir/state/findings.tsv
KERNEL_LOG_CHECK_ENABLED=1
SMART_CHECK_ENABLED=1
JOURNAL_TIMEOUT_SECONDS=10
SMART_TIMEOUT_SECONDS=10
PROBE_TIMEOUT_SECONDS=10
STATEFUL_NOTIFICATIONS=1
NOTIFICATION_REPEAT_DAYS=7
SMART_EXTENDED_DETAILS=0
FORCE_REPORT=0
SMART_MODE=ok
export SMART_MODE
export MOCK_DIR=$test_dir

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
assert_eq() { [[ $1 == "$2" ]] || fail "$3 (got '$1', expected '$2')"; }
reset_fs() {
    : > "$filesystem_findings_file"
    : > "$filesystem_details_file"
    : > "$local_filesystems_file"
    filesystem_alert_count=0
    filesystem_warning_count=0
    filesystem_notice_count=0
    filesystem_ok_count=0
    filesystem_check_error_count=0
    fsck_unit_count=0
    fsck_finding_count=0
}
reset_smart() {
    : > "$smart_summary_file"; : > "$smart_details_file"
    smart_device_count=0; smart_ok_count=0; smart_warning_count=0
    smart_fail_count=0; smart_error_count=0; smart_unsupported_count=0
}
reset_events() {
    : > "$filesystem_findings_file"; : > "$smart_summary_file"
    : > "$kernel_findings_file"; : > "$kernel_warnings_file"
    : > "$findings_file"; : > "$automatic_changes_file"
    execution_error=0; kernel_persistence_error=0; kernel_scan_error=0
    kernel_coverage_gap=0; kernel_coverage_unknown=0; kernel_persistence_changed=0; coverage_alert=0
}
cat > "$test_dir/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then
    printf 'systemd %s (mock)\n' "${MOCK_SYSTEMD_VERSION:-255}"
elif [[ $* == *' -o export '* ]]; then
    cat "$MOCK_DIR/journal/export"
elif [[ $* == *' -o short-iso-precise '* && $* == *'--since'* ]]; then
    cat "$MOCK_DIR/journal/raw"
elif [[ $* == *' -t systemd-fsck '* ]]; then
    cat "$MOCK_DIR/fsck-journal"
elif [[ $* == *' -o short-unix '* ]]; then
    printf '%s\n' "$*" >> "$MOCK_DIR/coverage-commands"
    case "${MOCK_COVERAGE_MODE:-normal}" in
      error) echo 'journal query failed' >&2; exit 2 ;;
      empty) exit 0 ;;
      short) printf '%s mock kernel: oldest\n' "$(date -d '4 days ago' +%s)"; exit 0 ;;
      timeout) sleep 3; exit 124 ;;
      signal) printf '%s mock kernel: oldest\n' "$(date -d '9 days ago' +%s)"; exit 141 ;;
    esac
    printf '%s mock kernel: oldest\n' "$(date -d '9 days ago' +%s)"
    if [[ $* != *'--lines=+1'* ]]; then
        # Simulate a large history for older journalctl. A correctly
        # streaming caller must close the pipe after the first line.
        trap 'exit 141' PIPE
        for ((i=0;i<50000;i++)); do
            printf '%s mock kernel: entry %s\n' "$(date -d '1 day ago' +%s)" "$i" || exit 141
        done
        echo 'WRONG: full history was exported' >> "$MOCK_DIR/coverage-commands"
    fi
else
    :
fi
EOF
cat > "$test_dir/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list-units) printf '%s\n' 'systemd-fsck-root.service loaded inactive dead check' ;;
  show)
    case "$*" in *ExecMainStatus*) echo 0 ;; *) echo success ;; esac ;;
  *) : ;;
esac
EOF
cat > "$test_dir/bin/smartctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_DIR/smart-calls"
if [[ $* == *'--scan-open'* ]]; then
    echo '/dev/sda -d megaraid,0 # discovered disk'
    exit 0
fi
if [[ $* =~ megaraid,([0-9]+) && $* == *-i* ]]; then
    # Recognize zero, one (scan incomplete), and backplane 32.
    index=${BASH_REMATCH[1]}
    case "$index" in
      0) printf 'Device Model: ST500\nSerial Number: SN0\n'; exit 0 ;;
      1) printf 'Device Model: ST500\nSerial Number: SN1\n'; exit 0 ;;
      32) printf 'Product: BP14G+\n'; exit 0 ;;
      *) echo 'No MegaRAID device found'; exit 2 ;;
    esac
fi
if [[ $* == *' -x '* || $1 == -x ]]; then
    echo 'Optional SCT feature unsupported'
    exit 4
fi
printf 'Device Model: ST500\nSMART overall-health self-assessment test result: PASSED\n'
case "$SMART_MODE" in
  warning) exit 16 ;;
  fail) exit 8 ;;
  error) exit 2 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$test_dir/bin/"*
PATH="$test_dir/bin:$PATH"
export PATH
: > "$test_dir/smart-calls"
: > "$test_dir/fsck-journal"

# Build matching journalctl short/ISO and export fixtures with stable timestamps.
: > "$test_dir/journal/raw"; : > "$test_dir/journal/export"
add_kernel_event() {
    local epoch=$1 boot=$2 message=$3 iso
    iso=$(date -d "@$epoch" '+%Y-%m-%dT%H:%M:%S.000000%:z')
    printf '%s mock kernel: %s\n' "$iso" "$message" >> "$test_dir/journal/raw"
    printf '__REALTIME_TIMESTAMP=%s000000\n_BOOT_ID=%s\nMESSAGE=%s\n\n' \
        "$epoch" "$boot" "$message" >> "$test_dir/journal/export"
}
t0=$(date -d '2026-11-10 07:18:00 UTC' +%s)
add_kernel_event "$t0" boot1 'thermal thermal_zone0: failed to read out thermal zone (-61)'
add_kernel_event "$((t0+1))" boot1 'nvme nvme1: Shutdown timeout set to 16 seconds'
add_kernel_event "$((t0+2))" boot1 'megaraid_sas 0000:03:00.0: Online Controller Reset(OCR) : Enabled'
add_kernel_event "$((t0+3))" boot1 'ata2.01: failed to resume link (SControl 0)'
add_kernel_event "$((t0+4))" boot1 'ata2.00: hard resetting link'
add_kernel_event "$((t0+5))" boot1 'Buffer I/O error on dev sda, logical block 1'
scan_kernel_storage_logs
assert_eq "$(wc -l < "$kernel_warnings_file")" 1 'ATA sibling does not escalate resume'
assert_eq "$(wc -l < "$kernel_findings_file")" 2 'genuine resets and I/O errors retained'
pass 'kernel false positives / sibling ATA isolation'

: > "$test_dir/journal/raw"; : > "$test_dir/journal/export"
add_kernel_event "$t0" boot1 'ata2.01: failed to resume link (SControl 0)'
add_kernel_event "$((t0+70))" boot1 'ata2.01: failed to identify'
scan_kernel_storage_logs
assert_eq "$(wc -l < "$kernel_findings_file")" 2 'same-link failure within window escalates'
assert_eq "$(wc -l < "$kernel_warnings_file")" 0 'same-link no downgrade'
pass 'same-boot time-correlated ATA escalation'

: > "$test_dir/journal/raw"; : > "$test_dir/journal/export"
add_kernel_event "$t0" boot1 'ata2.01: failed to resume link (SControl 0)'
add_kernel_event "$((t0+60))" boot2 'ata2.01: failed to identify'
scan_kernel_storage_logs
assert_eq "$(wc -l < "$kernel_warnings_file")" 1 'cross-boot event isolation'
pass 'ATA cross-boot isolation'

: > "$test_dir/journal/raw"; : > "$test_dir/journal/export"
add_kernel_event "$t0" boot1 'ata2.01: failed to resume link (SControl 0)'
add_kernel_event "$((t0+300))" boot1 'ata2.01: failed to identify'
scan_kernel_storage_logs
assert_eq "$(wc -l < "$kernel_warnings_file")" 1 'unrelated distant reset'
pass 'ATA time-window isolation'

reset_smart
SMART_MODE=ok; export SMART_MODE
run_smart_target /dev/sdz
assert_eq "$smart_ok_count" 1 'focused healthy disk'
assert_eq "$(grep -Ec '(^| )-x ' "$test_dir/smart-calls" || true)" 0 'skip optional -x for healthy disk'
SMART_MODE=warning; export SMART_MODE
run_smart_target /dev/sdy
assert_eq "$smart_warning_count" 1 'SMART exit bit 16 warning'
assert_eq "$(grep -Ec '(^| )-x ' "$test_dir/smart-calls" || true)" 1 'collect supplemental detail for warning'
SMART_MODE=fail; export SMART_MODE
run_smart_target /dev/sdx
assert_eq "$smart_fail_count" 1 'SMART bit 3 failure'
pass 'focused SMART status, optional detail, health failure'

MEGARAID_MAX_INDEX=33
MEGARAID_COMPLETE_SCAN=1
megaraid_results=$(discover_megaraid_targets /dev/sda)
[[ $megaraid_results == *'megaraid,1'* ]] || fail 'missed disk beyond scan-open partial enumeration'
[[ $megaraid_results != *'megaraid,32'* ]] || { printf 'discovery result: %s\n' "$megaraid_results" >&2; fail 'backplane should be skipped'; }
pass 'partial MegaRAID scan complemented / backplane suppressed'

reset_events
printf 'WARNING\t/dev/sdb\tModel\tPASSED\n' > "$smart_summary_file"
assemble_finding_ledger
prepare_notifications
assert_eq "$event_alert_count" 0 'smart warning must not imply ALERT'
assert_eq "$event_warning_count" 1 'SMART warning stays WARNING'
assert_eq "$notification_due" 1 'first warning should notify'
save_notification_state 1
prepare_notifications
assert_eq "$notification_due" 0 'unchanged warning suppressed until repeat interval'
assert_eq "$notification_ongoing_count" 1 'ongoing warning tracked'
: > "$smart_summary_file"
assemble_finding_ledger
prepare_notifications
assert_eq "$notification_resolved_count" 1 'cleared finding triggers resolved notice'
assert_eq "$notification_due" 1 'resolution report due'
save_notification_state 1
pass 'finding ledger / stateful first, ongoing, resolved'

reset_events
printf 'FAIL\t/dev/sdb\tModel\tFAILED\n' > "$smart_summary_file"
assemble_finding_ledger
prepare_notifications
assert_eq "$event_alert_count" 1 'SMART FAIL emits alert'
save_notification_state 1
prepare_notifications
assert_eq "$notification_due" 1 'ALERT must never be suppressed'
pass 'critical alerts always notify'

reset_fs
cat > "$test_dir/fsck-journal" <<EOF
2026-11-10T10:00:00Z mock systemd-fsck[12]: UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY
EOF
check_boot_fsck_results
assert_eq "$fsck_finding_count" 1 'unloaded failure journal checked with loaded healthy unit'
assert_eq "$filesystem_alert_count" 1 'unloaded fsck failure alert'
pass 'loaded clean + unloaded failing fsck journal coverage'

# Kernel journal retention: systemd 255+ can seek to the oldest matching
# event directly. systemd 249 (Ubuntu 22.04) must stream just the first
# matching entry without exporting the entire retained kernel history.
KERNEL_LOG_SINCE='7 days ago'
kernel_scan_error=0
: > "$execution_notes_file"
: > "$test_dir/coverage-commands"
MOCK_SYSTEMD_VERSION=255 MOCK_COVERAGE_MODE=normal
export MOCK_SYSTEMD_VERSION MOCK_COVERAGE_MODE
check_kernel_log_coverage
assert_eq "$kernel_coverage_gap" 0 'systemd 255 coverage complete'
assert_eq "$kernel_coverage_unknown" 0 'systemd 255 coverage available'
grep -Fq -- '--lines=+1' "$test_dir/coverage-commands" || fail 'new journalctl did not use oldest-entry option'
[[ ! -e $test_dir/kernel-coverage-history.txt ]] || fail 'coverage must not dump entire journal history'
pass 'Ubuntu 24.04 direct oldest kernel entry'

: > "$test_dir/coverage-commands"
MOCK_SYSTEMD_VERSION=249
export MOCK_SYSTEMD_VERSION
check_kernel_log_coverage
assert_eq "$kernel_coverage_gap" 0 'systemd 249 coverage complete'
assert_eq "$kernel_coverage_unknown" 0 'systemd 249 coverage available'
if grep -Fq -- '--lines=+1' "$test_dir/coverage-commands"; then
    fail 'old journalctl must not use unsupported --lines=+1'
fi
if grep -Fq 'WRONG: full history was exported' "$test_dir/coverage-commands"; then
    fail 'legacy fallback did not stop after one entry'
fi
pass 'Ubuntu 22.04 bounded first-entry stream'

MOCK_SYSTEMD_VERSION=255 MOCK_COVERAGE_MODE=error
export MOCK_SYSTEMD_VERSION MOCK_COVERAGE_MODE
: > "$execution_notes_file"
check_kernel_log_coverage
assert_eq "$kernel_coverage_unknown" 1 'journal query error must be incomplete'
grep -q 'query failed or timed out' "$execution_notes_file" || fail 'journal query error note missing'
MOCK_COVERAGE_MODE=empty
export MOCK_COVERAGE_MODE
check_kernel_log_coverage
assert_eq "$kernel_coverage_unknown" 1 'empty journal must be incomplete'
MOCK_COVERAGE_MODE=short
export MOCK_COVERAGE_MODE
check_kernel_log_coverage
assert_eq "$kernel_coverage_gap" 1 'genuine four-day coverage gap must still be reported'
assert_eq "$kernel_coverage_unknown" 0 'short but readable history is not a query error'
MOCK_COVERAGE_MODE=signal
export MOCK_COVERAGE_MODE
check_kernel_log_coverage
assert_eq "$kernel_coverage_unknown" 1 'modern query SIGPIPE must not count as success'
MOCK_COVERAGE_MODE=timeout
JOURNAL_TIMEOUT_SECONDS=1
export MOCK_COVERAGE_MODE JOURNAL_TIMEOUT_SECONDS
check_kernel_log_coverage
assert_eq "$kernel_coverage_unknown" 1 'timed-out coverage must be incomplete'
JOURNAL_TIMEOUT_SECONDS=10
MOCK_SYSTEMD_VERSION=249 MOCK_COVERAGE_MODE=error
export JOURNAL_TIMEOUT_SECONDS MOCK_COVERAGE_MODE MOCK_SYSTEMD_VERSION
check_kernel_log_coverage
assert_eq "$kernel_coverage_unknown" 1 'legacy query failure must be incomplete'
MOCK_COVERAGE_MODE=empty
export MOCK_COVERAGE_MODE
check_kernel_log_coverage
assert_eq "$kernel_coverage_unknown" 1 'legacy empty journal must be incomplete'
MOCK_COVERAGE_MODE=normal
export JOURNAL_TIMEOUT_SECONDS MOCK_COVERAGE_MODE
pass 'coverage failures, empty history, short retention, and timeout handled safely'

assert_eq "$(bash "$SCRIPT" --version)" 'system-integrity-audit 2.0.0-dev.2' 'embedded version'
bash -n "$SCRIPT"
pass 'version and Bash syntax'

# End-to-end: execute a temporary copy with non-destructive mocks. This tests
# the real report-builder/mail path and the preflight email trap, not host APT.
cat > "$test_dir/bin/debsums" <<'EOF'
#!/usr/bin/env bash
case "$1" in -ca|-l) exit 0 ;; *) exit 2 ;; esac
EOF
cat > "$test_dir/bin/sendmail" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$MOCK_DIR/sendmail-args"
cat > "$MOCK_DIR/last-email.eml"
EOF
cat > "$test_dir/bin/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$test_dir/bin/debsums" "$test_dir/bin/sendmail" "$test_dir/bin/logger"
cp "$SCRIPT" "$test_dir/integration.sh"
# Only our sandbox copy may be changed: add the fake executable path first.
sed -i "s@^PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'@PATH='$test_dir/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'@" \
    "$test_dir/integration.sh"
rm -f "$test_dir/last-email.eml"
ENV_ARGS=(
    "MOCK_DIR=$test_dir"
    "AUTO_INSTALL_REQUIREMENTS=0"
    "KERNEL_LOG_CHECK_ENABLED=0"
    "SMART_CHECK_ENABLED=0"
    "FILESYSTEM_CHECKS_ENABLED=0"
    "PROGRESS_OUTPUT=never"
    "TERMINAL_OUTPUT=never"
    "STATEFUL_NOTIFICATIONS=1"
    "NOTIFICATION_STATE_FILE=$test_dir/integration-state.tsv"
    "EXCEPTIONS_FILE=$test_dir/nonexistent-exceptions"
    "LOCK_FILE=$test_dir/integration-lock"
    "REPORT_COVERAGE_GAPS=0"
    "FORCE_REPORT=1"
    "REPORT_TO=auditor@example.invalid"
    "OS_RELEASE_FILE=$test_dir/ubuntu-os-release"
)
printf 'ID=ubuntu\n' > "$test_dir/ubuntu-os-release"
env "${ENV_ARGS[@]}" bash "$test_dir/integration.sh" > "$test_dir/integration-stdout" 2> "$test_dir/integration-stderr"
rc=$?
assert_eq "$rc" 0 'full clean report exit success'
[[ -s $test_dir/last-email.eml ]] || fail 'full clean report email absent'
grep -q 'Subject: .* TEST/OK - ' "$test_dir/last-email.eml" || fail 'clean status subject'
grep -q '^From: "System Integrity Audit" <system-integrity-audit>' "$test_dir/last-email.eml" || fail 'visible From header'
grep -q 'Audit coverage' "$test_dir/last-email.eml" || fail 'coverage section missing'
grep -q 'Script version: *2.0.0-dev.2' "$test_dir/last-email.eml" || fail 'version absent in report'
[[ -f $test_dir/integration-state.tsv ]] || fail 'state file not persisted'
pass 'full clean report, MIME sender, coverage, state persistence'

# Invalid exception syntax fails before ordinary report assembly, but must
# still send a short ERROR email instead of vanishing from scheduled monitoring.
printf 'relative/path\n' > "$test_dir/invalid-exceptions"
rm -f "$test_dir/last-email.eml"
env "${ENV_ARGS[@]}" "EXCEPTIONS_FILE=$test_dir/invalid-exceptions" \
    bash "$test_dir/integration.sh" > "$test_dir/failure-stdout" 2> "$test_dir/failure-stderr"
rc=$?
assert_eq "$rc" 65 'early exception error exit'
[[ -s $test_dir/last-email.eml ]] || fail 'early-failure email absent'
grep -q 'Subject: .* ERROR - ' "$test_dir/last-email.eml" || fail 'early-failure subject'
grep -q 'loading exception rules' "$test_dir/last-email.eml" || fail 'failure stage absent'
pass 'early initialization failure email'

# Explicitly unset recipients must not send and must not claim delivery.
rm -f "$test_dir/last-email.eml"
env "${ENV_ARGS[@]}" "REPORT_TO=" "NOTIFICATION_STATE_FILE=$test_dir/no-mail-state.tsv" \
    bash "$test_dir/integration.sh" > "$test_dir/no-mail-stdout" 2> "$test_dir/no-mail-stderr"
rc=$?
assert_eq "$rc" 0 'no-mail audit exits normally'
[[ ! -e $test_dir/last-email.eml ]] || fail 'no-mail audit unexpectedly sent email'
pass 'empty recipient disables email'

# Placeholder recipient (and unset REPORT_TO, which uses that default) must
# never send, and must not claim a notification was delivered.
rm -f "$test_dir/last-email.eml"
env "${ENV_ARGS[@]}" "REPORT_TO=username@email.address" \
    "NOTIFICATION_STATE_FILE=$test_dir/placeholder-state.tsv" \
    bash "$test_dir/integration.sh" > "$test_dir/placeholder-stdout" 2> "$test_dir/placeholder-stderr"
rc=$?
assert_eq "$rc" 0 'placeholder recipient exits normally'
[[ ! -e $test_dir/last-email.eml ]] || fail 'placeholder recipient unexpectedly sent email'
pass 'placeholder recipient explicitly disables email'

# Test default behavior with REPORT_TO removed from the environment entirely.
ENV_DEFAULT_RECIPIENT=()
for assignment in "${ENV_ARGS[@]}"; do
    [[ $assignment == REPORT_TO=* ]] || ENV_DEFAULT_RECIPIENT+=("$assignment")
done
rm -f "$test_dir/last-email.eml"
env -u REPORT_TO "${ENV_DEFAULT_RECIPIENT[@]}" \
    "NOTIFICATION_STATE_FILE=$test_dir/default-mail-state.tsv" \
    bash "$test_dir/integration.sh" > "$test_dir/default-mail-stdout" 2> "$test_dir/default-mail-stderr"
rc=$?
assert_eq "$rc" 0 'default recipient exits normally'
[[ ! -e $test_dir/last-email.eml ]] || fail 'default recipient unexpectedly sent email'
pass 'default placeholder disables email'

# Early initialization errors must also leave email disabled on the placeholder.
rm -f "$test_dir/last-email.eml"
env "${ENV_ARGS[@]}" "REPORT_TO=username@email.address" \
    "EXCEPTIONS_FILE=$test_dir/invalid-exceptions" \
    bash "$test_dir/integration.sh" > "$test_dir/no-error-mail-stdout" 2> "$test_dir/no-error-mail-stderr"
rc=$?
assert_eq "$rc" 65 'placeholder early failure exit'
[[ ! -e $test_dir/last-email.eml ]] || fail 'placeholder sent early-failure email'
pass 'placeholder disables early-failure email'

# RPM hosts should fail explicitly, not execute apt/debsums commands.
printf 'ID=rocky\n' > "$test_dir/rocky-os-release"
env "${ENV_ARGS[@]}" "REPORT_TO=" "OS_RELEASE_FILE=$test_dir/rocky-os-release" \
    bash "$test_dir/integration.sh" > "$test_dir/rocky-stdout" 2> "$test_dir/rocky-stderr"
rc=$?
assert_eq "$rc" 78 'RPM host must be rejected until the backend is ready'
grep -q 'RPM package-integrity backend is not implemented' "$test_dir/rocky-stderr" || fail 'no explicit RPM limitation'
pass 'RPM platform guard prevents misleading verification'

# Probe timeout must return 124, and never silently claim the check succeeded.
run_probe 1 sleep 2 > "$test_dir/timeout-out" 2> "$test_dir/timeout-err"
rc=$?
assert_eq "$rc" 124 'bounded probe timeout status'
grep -q 'TIMEOUT' "$test_dir/timeout-err" || fail 'missing timeout diagnostic'
pass 'bounded external command execution'

echo 'All regression tests passed.'

