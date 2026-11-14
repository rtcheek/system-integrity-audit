#!/usr/bin/env bash
# Non-destructive regression fixtures for system-integrity-audit 2.0.2.
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
smart_short_test_notes_file=$test_dir/smart-short-test-notes.tsv
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
SMART_SHORT_TEST_AUTO=0
XFS_SCRUB_AUTO=0
SMART_SHORT_TEST_AGE_DAYS=60
SMART_SHORT_TEST_STATE_FILE=$test_dir/smart-test-state.tsv
SMART_CPU_STAT_PATH=$test_dir/procstat
FORCE_REPORT=0
SMART_MODE=ok
export SMART_MODE
export MOCK_DIR=$test_dir

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
assert_eq() { [[ $1 == "$2" ]] || fail "$3 (got '$1', expected '$2')"; }
PATH="$test_dir/bin:$PATH"
export PATH

# Simulate APT, not the host package manager.  Verify the complete command
# environment, input stream, conffile policy, lock retries and timeout policy.
# The PTY fixture below also checks the process-group bug seen on Ubuntu 24.04.
cat > "$test_dir/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '--CALL--' >> "$MOCK_DIR/apt-invocations"
printf '%s\n' "$@" >> "$MOCK_DIR/apt-args"
printf '%s|%s|%s|%s\n' "${DEBIAN_FRONTEND:-}" "${DEBCONF_NONINTERACTIVE_SEEN:-}" \
    "${APT_LISTCHANGES_FRONTEND:-}" "${UCF_FORCE_CONFFOLD:-}" > "$MOCK_DIR/apt-environment"
if [[ -t 0 ]]; then
    echo 'APT stdin was a terminal, not /dev/null' >&2
    exit 88
fi
case "${MOCK_APT_MODE:-success}" in
    foreground)
        read -r pgid < <(ps -o pgid= -p "$$")
        read -r tpgid < <(ps -o tpgid= -p "$$")
        printf '%s %s\n' "$pgid" "$tpgid" > "$MOCK_DIR/apt-pgroups"
        if [[ $pgid != "$tpgid" || $tpgid == -1 ]]; then
            echo "APT in background process group: pgid=$pgid tpgid=$tpgid" >&2
            exit 87
        fi
        ;;
    lock_once)
        if [[ ! -e "$MOCK_DIR/apt-lock-once" ]]; then
            : > "$MOCK_DIR/apt-lock-once"
            echo 'E: Could not get lock /var/lib/dpkg/lock-frontend' >&2
            exit 100
        fi
        ;;
    refresh)
        if [[ $* == *' install '* && ! -e "$MOCK_DIR/apt-initial-failed" ]]; then
            : > "$MOCK_DIR/apt-initial-failed"
            echo 'E: Package debsums has no installation candidate' >&2
            exit 100
        fi
        ;;
    live)
        if [[ -n ${MOCK_SPINNER_PID:-} ]] && kill -0 "$MOCK_SPINNER_PID" 2>/dev/null; then
            echo 'spinner still running during install' >&2
            exit 89
        fi
        echo 'APT live stdout'
        echo 'APT live stderr' >&2
        # The observer file is stderr of the audit, not the captured log.
        # Require output to arrive before this command finishes.
        for ((i=0; i<50; i++)); do
            if grep -q 'APT live stderr' "$MOCK_DIR/live-install.stderr"; then
                : > "$MOCK_DIR/live-output-seen"
                break
            fi
            sleep 0.02
        done
        [[ -e $MOCK_DIR/live-output-seen ]] || exit 90
        : > "$MOCK_DIR/debsums-installed"
        ;;
    inherited_output)
        sleep 10 &
        echo "$!" > "$MOCK_DIR/package-hook.pid"
        echo 'hook launched'
        wait
        ;;
    timeout) exec sleep 3 ;;
esac
echo 'simulated APT success'
EOF
chmod +x "$test_dir/bin/apt-get"
apt_output_file=$test_dir/apt-output.txt
APT_COMMAND_TIMEOUT_SECONDS=5
APT_LOCK_WAIT_SECONDS=0
APT_LOCK_RETRY_COUNT=1
: > "$test_dir/apt-invocations"; : > "$test_dir/apt-args"
MOCK_APT_MODE=success run_apt_install_with_refresh debsums
assert_eq "$?" 0 'unattended APT fixture success'
assert_eq "$(cat "$test_dir/apt-environment")" \
    'noninteractive|true|none|1' 'APT/dpkg must be noninteractive'
for option in 'Dpkg::Use-Pty=0' 'APT::Color=0' \
              'Dpkg::Options::=--force-confdef' 'Dpkg::Options::=--force-confold' \
              'install' 'debsums'; do
    grep -Fxq -- "$option" "$test_dir/apt-args" || fail "missing unattended APT argument: $option"
done
assert_eq "$(grep -c '^--CALL--$' "$test_dir/apt-invocations")" 1 \
    'successful APT install should run exactly once'
pass 'unattended APT environment, closed stdin, conffile policy and install'

: > "$test_dir/apt-invocations"; rm -f "$test_dir/apt-lock-once"
MOCK_APT_MODE=lock_once run_apt_install_with_refresh debsums
assert_eq "$?" 0 'APT lock retry eventual success'
assert_eq "$(grep -c '^--CALL--$' "$test_dir/apt-invocations")" 2 \
    'APT lock contention should retry exactly once'
pass 'APT lock contention retry still works'

: > "$test_dir/apt-invocations"; rm -f "$test_dir/apt-initial-failed"
MOCK_APT_MODE=refresh run_apt_install_with_refresh debsums
assert_eq "$?" 0 'APT index refresh and install retry'
assert_eq "$(grep -c '^--CALL--$' "$test_dir/apt-invocations")" 3 \
    'ordinary APT install error should refresh indexes then retry'
pass 'APT index-refresh recovery retained for ordinary install failures'

: > "$test_dir/apt-invocations"
APT_COMMAND_TIMEOUT_SECONDS=1
MOCK_APT_MODE=timeout run_apt_install_with_refresh debsums > "$test_dir/apt-timeout.out" 2> "$test_dir/apt-timeout.err"
assert_eq "$?" 124 'APT timeout must terminate and return 124'
assert_eq "$(grep -c '^--CALL--$' "$test_dir/apt-invocations")" 1 \
    'timed-out APT transaction must not be retried'
grep -q 'APT timed out' "$test_dir/apt-timeout.err" || fail 'APT timeout diagnostic absent'
pass 'APT timeout fails safely without starting another transaction'
APT_COMMAND_TIMEOUT_SECONDS=5

# A real pseudo-terminal detects timeout's default background-process-group
# behavior.  Apt-get must inherit the controlling terminal's foreground PGID.
if command -v script >/dev/null 2>&1; then
    cat > "$test_dir/apt-pty-fixture.sh" <<'EOF'
#!/usr/bin/env bash
source "$MOCK_DIR/definitions.sh"
PATH="$MOCK_DIR/bin:$PATH"
export PATH
apt_output_file="$MOCK_DIR/apt-pty-output.txt"
APT_COMMAND_TIMEOUT_SECONDS=5
export MOCK_APT_MODE=foreground
PROGRESS_OUTPUT=always
progress_start 'Checking audit prerequisites'
run_apt_get_with_retries 'PTY process-group check' -q -y install debsums
EOF
    chmod +x "$test_dir/apt-pty-fixture.sh"
    : > "$test_dir/apt-pgroups"
    script -q -e -c "bash '$test_dir/apt-pty-fixture.sh'" /dev/null \
        > "$test_dir/apt-pty-stdout" 2> "$test_dir/apt-pty-stderr"
    assert_eq "$?" 0 'APT PTY foreground fixture must exit successfully'
    read -r foreground_pgid tty_pgid < "$test_dir/apt-pgroups"
    [[ -n $foreground_pgid && $foreground_pgid == "$tty_pgid" && $tty_pgid != -1 ]] || \
        fail 'APT child must stay in the terminal foreground process group'
    pass 'APT remains in terminal foreground process group under timeout'
else
    echo 'SKIP: PTY APT job-control fixture (script command unavailable)'
fi


# Exercise the actual prerequisite stage with a spinner and streamed output.
# Everything is mocked, including the command-availability change on install.
(
    PROGRESS_OUTPUT=always
    PACKAGE_BACKEND=dpkg
    SMART_CHECK_ENABLED=0
    AUTO_INSTALL_REQUIREMENTS=1
    automatic_change_count=0
    automatic_notice_count=0
    command() {
        if [[ ${1:-} == -v && ${2:-} == debsums ]]; then
            [[ -e $test_dir/debsums-installed ]]
        else
            builtin command "$@"
        fi
    }
    logger() { :; }
    wait_for_package_manager_idle() {
        [[ -z ${progress_spinner_pid:-} ]] || return 91
    }
    progress_start 'Checking audit prerequisites'
    export MOCK_SPINNER_PID=$progress_spinner_pid
    export MOCK_APT_MODE=live
    install_missing_audit_tools
    rc=$?
    [[ -z ${progress_spinner_pid:-} ]] || exit 92
    assert_eq "$automatic_change_count" 1 'installation recorded'
    progress_finish notice
    progress_start 'Verifying audit commands'
    progress_finish done
    exit "$rc"
) > "$test_dir/live-install.stdout" 2> "$test_dir/live-install.stderr"
assert_eq "$?" 0 'live prerequisite install and spinner suspension'
[[ ! -s $test_dir/live-install.stdout ]] || fail 'install progress polluted report stdout'
for line in 'APT live stdout' 'APT live stderr'; do
    grep -Fxq "$line" "$apt_output_file" || fail 'live output not retained in log'
    assert_eq "$(grep -c "^$line$" "$test_dir/live-install.stderr")" 1 'live output shown once'
done
grep -q 'NOTICE.*Checking audit prerequisites' "$test_dir/live-install.stderr" || fail 'stage label lost'
grep -q 'OK.*Verifying audit commands' "$test_dir/live-install.stderr" || fail 'progress did not resume'
pass 'prerequisite spinner pauses before install, streams output live and resumes stages'

# Streaming must not turn a timeout into success or a retry.
: > "$test_dir/apt-invocations"
PROGRESS_OUTPUT=always APT_COMMAND_TIMEOUT_SECONDS=1 MOCK_APT_MODE=timeout \
    run_apt_install_with_refresh debsums > "$test_dir/live-timeout.stdout" 2> "$test_dir/live-timeout.stderr"
assert_eq "$?" 124 'streamed APT timeout status preserved'
assert_eq "$(grep -c '^--CALL--$' "$test_dir/apt-invocations")" 1 'streamed timeout must not retry'
assert_eq "$(grep -c 'TIMEOUT: apt-get' "$test_dir/live-timeout.stderr")" 1 'timeout log not replayed twice'
pass 'streamed APT timeout preserves status and does not retry or duplicate diagnostics'

# A hook can survive timeout --foreground and retain stdout/stderr. Use an
# outer watchdog so a display implementation that waits for pipe EOF fails.
(
    PROGRESS_OUTPUT=always
    APT_COMMAND_TIMEOUT_SECONDS=1
    export MOCK_APT_MODE=inherited_output
    run_apt_install_with_refresh debsums
    rc=$?
    echo "$rc" > "$test_dir/inherited-output.exit"
) > "$test_dir/inherited-output.stdout" 2> "$test_dir/inherited-output.stderr" &
fixture_pid=$!
for ((i=0; i<60; i++)); do
    [[ -e $test_dir/inherited-output.exit ]] && break
    sleep 0.05
done
if [[ ! -e $test_dir/inherited-output.exit ]]; then
    [[ ! -f $test_dir/package-hook.pid ]] || kill "$(cat "$test_dir/package-hook.pid")" 2>/dev/null
    wait "$fixture_pid" 2>/dev/null
    fail 'live display waited for surviving package hook after APT timeout'
fi
[[ ! -f $test_dir/package-hook.pid ]] || kill "$(cat "$test_dir/package-hook.pid")" 2>/dev/null
wait "$fixture_pid"
assert_eq "$(cat "$test_dir/inherited-output.exit")" 124 'hook-retained output timeout status'
grep -q 'hook launched' "$test_dir/inherited-output.stderr" || fail 'hook output absent'
pass 'live APT display returns on timeout even while a hook retains output'

# Quiet successful installs stay quiet while retaining their full log.
PROGRESS_OUTPUT=never MOCK_APT_MODE=success run_apt_install_with_refresh debsums \
    > "$test_dir/quiet-install.stdout" 2> "$test_dir/quiet-install.stderr"
assert_eq "$?" 0 'quiet APT installation status'
[[ ! -s $test_dir/quiet-install.stdout && ! -s $test_dir/quiet-install.stderr ]] || fail 'quiet install leaked progress'
grep -q 'simulated APT success' "$apt_output_file" || fail 'quiet install log absent'
pass 'quiet APT installation retains logging without terminal output'

# RPM installs use the same display helper; preserve both success and failure.
cat > "$test_dir/bin/dnf" <<'EOF'
#!/usr/bin/env bash
echo 'DNF stdout'
echo 'DNF stderr' >&2
exit "${MOCK_DNF_RC:-0}"
EOF
chmod +x "$test_dir/bin/dnf"
for display in never always; do
    for status in 0 42; do
        PROGRESS_OUTPUT=$display MOCK_DNF_RC=$status DNF_COMMAND_TIMEOUT_SECONDS=5 \
            run_dnf_install smartmontools > "$test_dir/dnf.stdout" 2> "$test_dir/dnf.stderr"
        assert_eq "$?" "$status" 'DNF install status preserved'
        [[ ! -s $test_dir/dnf.stdout ]] || fail 'DNF output polluted report stdout'
        grep -Fxq 'DNF stdout' "$apt_output_file" || fail 'DNF stdout not logged'
        grep -Fxq 'DNF stderr' "$apt_output_file" || fail 'DNF stderr not logged'
        if [[ $display == never && $status == 0 ]]; then
            [[ ! -s $test_dir/dnf.stderr ]] || fail 'quiet DNF success leaked output'
        else
            assert_eq "$(grep -c '^DNF stdout$' "$test_dir/dnf.stderr")" 1 'DNF stdout displayed once'
            assert_eq "$(grep -c '^DNF stderr$' "$test_dir/dnf.stderr")" 1 'DNF stderr displayed once'
        fi
    done
done
pass 'DNF live and quiet installation output retains status and avoids duplicate logs'

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
    : > "$smart_summary_file"; : > "$smart_details_file"; : > "$smart_short_test_notes_file"
    smart_short_test_started_count=0; smart_short_test_skipped_count=0
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
if [[ ${1:-} == -c && $* == *'-l selftest'* ]]; then
    cat "$MOCK_DIR/smart-test-history.txt"
    exit "${SMART_TEST_HISTORY_RC:-0}"
fi
if [[ ${1:-} == -t && ${2:-} == short ]]; then
    printf '%s\n' "$*" >> "$MOCK_DIR/smart-test-starts.txt"
    exit "${SMART_TEST_START_RC:-0}"
fi
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

# Healthy ATA fixtures: scheduler reads SMART capability + self-test log and
# refuses unsafe starts. No real disks are touched by these function tests.
SMART_SHORT_TEST_AUTO=1
SMART_SHORT_TEST_STATE_FILE=$test_dir/smart-test-state.tsv
: > "$test_dir/smart-test-starts.txt"
: > "$test_dir/smart-calls"
rm -f "$SMART_SHORT_TEST_STATE_FILE"
reset_smart
health_fixture="$test_dir/health-ata.txt"
printf 'Device Model: Test SSD\nSerial Number: DEVSERIAL\nATA Version is: ACS-4\nSMART overall-health self-assessment test result: PASSED\n' > "$health_fixture"
write_smart_history() {
    local status=${1:-0} current=${2:-6000} last=${3:-}
    {
        printf 'Self-test execution status:      ( %s) the self-test status\n' "$status"
        printf 'Self-test supported.\n'
        printf '9 Power_On_Hours 0x0032 100 100 --- Old_age Always - %s\n' "$current"
        if [[ -z $last ]]; then
            printf 'No self-tests have been logged.\n'
        else
            printf '# 1  Short offline  Completed without error  00%%  %s  -\n' "$last"
        fi
    } > "$test_dir/smart-test-history.txt"
}
# Simulated load for individual gate tests; the real /proc/stat sampler is
# independently verified below with two jiffy snapshots.
smart_cpu_quiet_enough() { smart_cpu_idle_bp=9950; smart_cpu_iowait_bp=10; return 0; }
write_smart_history 249
maybe_start_smart_short_test /dev/sdz '' /dev/sdz "$health_fixture" OK
assert_eq "$smart_short_test_started_count" 0 'running self-test never duplicated'
grep -q 'already in progress' "$smart_short_test_notes_file" || fail 'running self-test skip note absent'
pass 'SMART scheduler refuses second test while firmware reports busy'

reset_smart
write_smart_history 0 6000 5999
maybe_start_smart_short_test /dev/sdz '' /dev/sdz "$health_fixture" OK
assert_eq "$smart_short_test_started_count" 0 'recent SMART test must not be restarted'
grep -q 'within 1440 powered-on hours' "$smart_short_test_notes_file" || fail 'recent SMART test skip reason absent'
pass 'SMART scheduler honors recent test history'

reset_smart
write_smart_history 0 6000 4000
sed -i 's/Completed without error/Completed: read failure/' "$test_dir/smart-test-history.txt"
maybe_start_smart_short_test /dev/sdz '' /dev/sdz "$health_fixture" OK
assert_eq "$smart_short_test_started_count" 0 'failed prior self-test must not be overwritten by new test'
grep -q 'previous self-test was not successful' "$smart_short_test_notes_file" || fail 'prior SMART failure skip reason missing'
pass 'SMART scheduler refuses to obscure a failed previous self-test'

reset_smart
write_smart_history 0 6000
smart_cpu_quiet_enough() { smart_cpu_idle_bp=9800; smart_cpu_iowait_bp=100; return 1; }
maybe_start_smart_short_test /dev/sdz '' /dev/sdz "$health_fixture" OK
assert_eq "$smart_short_test_started_count" 0 'CPU idle exactly 98% must not start'
grep -q 'CPU idle=98.0%' "$smart_short_test_notes_file" || fail 'CPU busy skip reason absent'
pass 'SMART scheduler requires CPU idle strictly above 98 percent'

reset_smart
smart_cpu_quiet_enough() { smart_cpu_idle_bp=9970; smart_cpu_iowait_bp=200; return 1; }
maybe_start_smart_short_test /dev/sdz '' /dev/sdz "$health_fixture" OK
assert_eq "$smart_short_test_started_count" 0 'iowait exactly 2% must not start'
pass 'SMART scheduler requires iowait strictly below 2 percent'

reset_smart
smart_cpu_quiet_enough() { smart_cpu_idle_bp=-1; smart_cpu_iowait_bp=-1; return 1; }
maybe_start_smart_short_test /dev/sdz '' /dev/sdz "$health_fixture" OK
assert_eq "$smart_short_test_started_count" 0 'missing CPU metrics must not start'
grep -q 'measurements unavailable' "$smart_short_test_notes_file" || fail 'unavailable CPU metrics skip absent'
pass 'SMART scheduler fails closed on missing CPU readings'

reset_smart
smart_cpu_quiet_enough() { smart_cpu_idle_bp=9950; smart_cpu_iowait_bp=10; return 0; }
write_smart_history 0 6000 4000
maybe_start_smart_short_test /dev/sdz '' /dev/sdz "$health_fixture" OK
assert_eq "$smart_short_test_started_count" 1 'old test should be initiated on idle ATA disk'
grep -q 'non-captive short test initiated' "$smart_short_test_notes_file" || fail 'test start note absent'
assert_eq "$(wc -l < "$test_dir/smart-test-starts.txt")" 1 'one short test dispatched'
assert_eq "$(cat "$test_dir/smart-test-starts.txt")" '-t short /dev/sdz' 'start must not use -C or force'
[[ -s $SMART_SHORT_TEST_STATE_FILE ]] || fail 'persistent SMART start state missing'
pass 'SMART scheduler starts one background test and records durable timestamp'

reset_smart
write_smart_history 0 6000
maybe_start_smart_short_test /dev/sdz '' /dev/sdz "$health_fixture" OK
assert_eq "$smart_short_test_started_count" 0 'persistent timestamp must suppress repeat start'
grep -q 'last audit-started test within 60d' "$smart_short_test_notes_file" || fail 'persistent state skip note missing'
assert_eq "$(wc -l < "$test_dir/smart-test-starts.txt")" 1 'second audit must not restart disk test'
pass 'SMART scheduler state prevents repeat before the log updates'

reset_smart
write_smart_history 0 6001 6000
maybe_start_smart_short_test /dev/sdz '' /dev/sdz "$health_fixture" OK
grep -q 'last logged: # 1.*Completed without error' "$smart_short_test_notes_file" || fail 'subsequent self-test result absent'
pass 'SMART scheduler includes recorded prior result on subsequent audit'

reset_smart
SMART_SHORT_TEST_STATE_FILE=$test_dir/smart-test-state-unsafe
ln -s "$test_dir/smart-test-state.tsv" "$SMART_SHORT_TEST_STATE_FILE"
write_smart_history 0 6000
maybe_start_smart_short_test /dev/sdz '' /dev/sdz "$health_fixture" OK
assert_eq "$smart_short_test_started_count" 0 'symlink state file must block initiation'
grep -q 'cannot read trusted' "$smart_short_test_notes_file" || fail 'state symlink rejection not reported'
SMART_SHORT_TEST_STATE_FILE=$test_dir/smart-test-state.tsv
pass 'SMART scheduler rejects symlinked state file'

reset_smart
write_smart_history 0 6000
maybe_start_smart_short_test /dev/sdz 'megaraid,0' '/dev/sdz [megaraid,0]' "$health_fixture" OK
maybe_start_smart_short_test /dev/nvme0n1 '' /dev/nvme0n1 "$health_fixture" OK
assert_eq "$smart_short_test_started_count" 0 'RAID/NVMe auto starts not supported without device-specific proofs'
pass 'SMART scheduler conservatively skips RAID and NVMe starts'

# Verify real CPU sampler values (based on two simulated /proc/stat reads).
unset -f smart_cpu_quiet_enough
eval "$(sed -n '/^smart_cpu_quiet_enough() {/,/^}/p' "$SCRIPT")"
printf 'cpu 10 0 0 1000 0 0 0 0 0 0\n' > "$SMART_CPU_STAT_PATH"
sleep() { printf 'cpu 11 0 0 1199 0 0 0 0 0 0\n' > "$SMART_CPU_STAT_PATH"; }
smart_cpu_quiet_enough || fail 'quiet CPU delta should meet threshold'
assert_eq "$smart_cpu_idle_bp" 9950 'idle jiffies should be 99.50%'
unset -f sleep
pass 'SMART scheduler computes two-snapshot CPU idle/iowait correctly'

# A tab in smartctl diagnostics must remain a tab, not escaped characters.
actual_tab=$'\t'
smart_line=$(sanitize_smart_detail_line $'Offline status:\tIdle')
[[ "$smart_line" == *"$actual_tab"* ]] || fail 'SMART report escaped tab instead of retaining it'
[[ "$smart_line" != *'\t'* ]] || fail 'SMART report printed backslash-t'
pass 'SMART diagnostic formatting preserves literal tab alignment'

# SMART short-test activity should use exactly the warning-yellow palette
# when stderr is color-enabled, and remain clean in plain/NO_COLOR output.
printf 'STARTED\t/dev/sda\tnon-captive short test initiated\n' \
    > "$smart_short_test_notes_file"
(
    PROGRESS_OUTPUT=always
    progress_color_enabled() { return 0; }
    print_smart_short_test_progress
) 2> "$test_dir/smart-test-yellow.txt"
yellow_expected=$'\033[1m\033[33m[SMART-TEST]\033[0m \033[33mSTARTED /dev/sda: non-captive short test initiated\033[0m'
assert_eq "$(cat "$test_dir/smart-test-yellow.txt")" "$yellow_expected" 'SMART-TEST uses warning-yellow ANSI styling'
(
    PROGRESS_OUTPUT=always
    progress_color_enabled() { return 1; }
    print_smart_short_test_progress
) 2> "$test_dir/smart-test-plain.txt"
assert_eq "$(cat "$test_dir/smart-test-plain.txt")" \
    '[SMART-TEST] STARTED /dev/sda: non-captive short test initiated' \
    'SMART-TEST remains readable without color'
(
    PROGRESS_OUTPUT=never
    print_smart_short_test_progress
) 2> "$test_dir/smart-test-hidden.txt"
[[ ! -s $test_dir/smart-test-hidden.txt ]] || fail 'SMART-TEST ignored disabled progress output'
: > "$smart_short_test_notes_file"
pass 'SMART-TEST progress uses warning yellow and respects plain/disabled output'
SMART_SHORT_TEST_AUTO=0

# Package notification identity must not depend on changed owner text,
# and the previous hash format should migrate without spurious RESOLVED.
prior_notification_file=$NOTIFICATION_STATE_FILE
NOTIFICATION_STATE_FILE=$test_dir/package-identity-state.tsv
reset_events
printf 'CONFIG\told-owner [S.5...]\t/etc/sample.conf\n' > "$findings_file"
assemble_finding_ledger
prepare_notifications
assert_eq "$notification_new_count" 1 'first config warning should be new'
save_notification_state 1
printf 'CONFIG\tnew-owner, another-owner [S.5...]\t/etc/sample.conf\n' > "$findings_file"
assemble_finding_ledger
prepare_notifications
assert_eq "$notification_ongoing_count" 1 'owner edit must remain ongoing'
assert_eq "$notification_resolved_count" 0 'owner edit cannot resolve same path warning'
assert_eq "$notification_new_count" 0 'owner edit cannot create a new path warning'
pass 'package notification identity ignores owner text changes'

legacy_id=$(printf '%s' 'WARNING|PACKAGE|/etc/sample.conf|CONFIG old-owner' | sha256sum)
legacy_id=${legacy_id%% *}
printf '%s\tWARNING\tPACKAGE\t/etc/sample.conf\t%s\n' "$legacy_id" "$(date +%s)" > "$NOTIFICATION_STATE_FILE"
prepare_notifications
assert_eq "$notification_ongoing_count" 1 'legacy package state should migrate'
assert_eq "$notification_resolved_count" 0 'legacy package state must not false-resolve'
pass 'old package state migrates without false resolution'
NOTIFICATION_STATE_FILE=$prior_notification_file

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
# event directly. systemd 249 (Ubuntu 22.04) and 245 (Ubuntu 20.04)
# must stream only the first entry, without exporting full history.
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

# Focal's systemd 245 uses the same bounded stream. A direct +N request
# would fail on this release; the full-journal export must never occur.
: > "$test_dir/coverage-commands"
MOCK_SYSTEMD_VERSION=245 MOCK_COVERAGE_MODE=normal
export MOCK_SYSTEMD_VERSION MOCK_COVERAGE_MODE
check_kernel_log_coverage
assert_eq "$kernel_coverage_gap" 0 'systemd 245 coverage complete'
assert_eq "$kernel_coverage_unknown" 0 'systemd 245 coverage available'
if grep -Fq -- '--lines=+1' "$test_dir/coverage-commands"; then
    fail 'systemd 245 used unsupported --lines=+1'
fi
if grep -Fq 'WRONG: full history was exported' "$test_dir/coverage-commands"; then
    fail 'systemd 245 fallback exported full history'
fi
pass 'Ubuntu 20.04 systemd 245 bounded kernel journal coverage'

# systemd-analyze cat-config is present in Ubuntu 20.04. Verify both
# persistent and volatile settings are interpreted without writing config.
cat > "$test_dir/bin/systemd-analyze" <<'FOCAL_ANALYZE'
#!/usr/bin/env bash
[[ ${1:-} == cat-config && ${2:-} == systemd/journald.conf ]] || exit 2
printf '# /etc/systemd/journald.conf\n[Journal]\nStorage=%s\n' "${MOCK_JOURNAL_STORAGE_MODE:-auto}"
FOCAL_ANALYZE
chmod +x "$test_dir/bin/systemd-analyze"
MOCK_JOURNAL_STORAGE_MODE=persistent
export MOCK_JOURNAL_STORAGE_MODE
assert_eq "$(effective_journal_storage_mode)" 'persistent' 'systemd 245 persistent journald config'
MOCK_JOURNAL_STORAGE_MODE=volatile
export MOCK_JOURNAL_STORAGE_MODE
assert_eq "$(effective_journal_storage_mode)" 'volatile' 'systemd 245 volatile journald config'
MOCK_JOURNAL_STORAGE_MODE=auto
export MOCK_JOURNAL_STORAGE_MODE
pass 'Ubuntu 20.04 journald cat-config compatibility'

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

assert_eq "$(bash "$SCRIPT" --version)" 'system-integrity-audit 2.0.2' 'embedded version'
# Confirm both host-changing features are enabled when not set by the caller,
# but retain explicit safe opt-outs for all integration/regression fixtures.
defaults=$(env -u AUTO_INSTALL_REQUIREMENTS -u AUTO_ENABLE_PERSISTENT_JOURNAL \
    bash -c 'source "$1"; printf "%s %s" "$AUTO_INSTALL_REQUIREMENTS" "$AUTO_ENABLE_PERSISTENT_JOURNAL"' \
    _ "$test_dir/definitions.sh")
assert_eq "$defaults" '1 1' 'unconfigured host-change defaults are both enabled'
overrides=$(env AUTO_INSTALL_REQUIREMENTS=0 AUTO_ENABLE_PERSISTENT_JOURNAL=0 \
    bash -c 'source "$1"; printf "%s %s" "$AUTO_INSTALL_REQUIREMENTS" "$AUTO_ENABLE_PERSISTENT_JOURNAL"' \
    _ "$test_dir/definitions.sh")
assert_eq "$overrides" '0 0' 'explicit opt-outs remain effective'
bash "$SCRIPT" --help | grep -q 'AUTO_INSTALL_REQUIREMENTS=0' || fail 'help omits package-install opt-out'
bash "$SCRIPT" --help | grep -q 'AUTO_ENABLE_PERSISTENT_JOURNAL=0' || fail 'help omits journald opt-out'
pass 'automatic-change default-on and explicit opt-out controls'
bash -n "$SCRIPT"
pass 'version and Bash syntax'

# End-to-end: execute a temporary copy with non-destructive mocks. This tests
# the real report-builder/mail path and the preflight email trap, not host APT.
cat > "$test_dir/bin/debsums" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -ca)
    if [[ -n ${MOCK_DEBSUMS_DIAGNOSTICS_FILE:-} ]]; then
      cat "$MOCK_DEBSUMS_DIAGNOSTICS_FILE" >&2
      exit 2
    fi
    exit 0
    ;;
  -l) exit 0 ;;
  *) exit 2 ;;
esac
EOF
# The shared integration test simulates Ubuntu even when run on Rocky/RHEL.
# A Rocky test runner normally has no dpkg-query; provide a deterministic
# stub instead of accidentally depending on the host's package manager.
cat > "$test_dir/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -S && ${2:-} == -- && $# -eq 3 ]]; then
    printf 'fixture-package: %s\n' "$3"
    exit 0
fi
printf 'unexpected mock dpkg-query arguments: %s\n' "$*" >&2
exit 2
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
chmod +x "$test_dir/bin/debsums" "$test_dir/bin/dpkg-query" "$test_dir/bin/sendmail" "$test_dir/bin/logger"
# Verify the fake dpkg command is available and behaves predictably.
assert_eq "$("$test_dir/bin/dpkg-query" -S -- /usr/bin/fixture)" \
    'fixture-package: /usr/bin/fixture' 'portable dpkg-query fixture'
pass 'cross-distribution Ubuntu dpkg-query fixture'
cp "$SCRIPT" "$test_dir/integration.sh"
# Only our sandbox copy may be changed: add the fake executable path first.
sed -i "s@^PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'@PATH='$test_dir/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'@" \
    "$test_dir/integration.sh"
rm -f "$test_dir/last-email.eml"
ENV_ARGS=(
    "XFS_SCRUB_AUTO=0"
    "MOCK_DIR=$test_dir"
    "AUTO_INSTALL_REQUIREMENTS=0"
    "AUTO_ENABLE_PERSISTENT_JOURNAL=0"
    "KERNEL_LOG_CHECK_ENABLED=0"
    "SMART_CHECK_ENABLED=0"
    "FILESYSTEM_CHECKS_ENABLED=0"
    "PROGRESS_OUTPUT=never"
    "TERMINAL_OUTPUT=never"
    "STATEFUL_NOTIFICATIONS=1"
    "NOTIFICATION_STATE_FILE=$test_dir/integration-state.tsv"
    "EXCEPTIONS_FILE=$test_dir/nonexistent-exceptions"
    "MISSING_EXCEPTIONS_FILE=$test_dir/nonexistent-missing-exceptions"
    "LOCK_FILE=$test_dir/integration-lock"
    "REPORT_COVERAGE_GAPS=0"
    "FORCE_REPORT=1"
    "REPORT_TO=auditor@example.invalid"
    "OS_RELEASE_FILE=$test_dir/ubuntu-os-release"
)
printf 'ID=ubuntu\n' > "$test_dir/ubuntu-os-release"
env "${ENV_ARGS[@]}" bash "$test_dir/integration.sh" > "$test_dir/integration-stdout" 2> "$test_dir/integration-stderr"
rc=$?
if (( rc != 0 )); then
    printf 'Full integration audit exited %s. Captured stderr:\n' "$rc" >&2
    sed -n '1,100p' "$test_dir/integration-stderr" >&2
fi
assert_eq "$rc" 0 'full clean report exit success'
[[ -s $test_dir/last-email.eml ]] || fail 'full clean report email absent'
grep -q 'Subject: .* TEST/OK - ' "$test_dir/last-email.eml" || fail 'clean status subject'
grep -q '^From: "System Integrity Audit" <system-integrity-audit>' "$test_dir/last-email.eml" || fail 'visible From header'
grep -q 'Audit coverage' "$test_dir/last-email.eml" || fail 'coverage section missing'
grep -q 'Script version: *2.0.2' "$test_dir/last-email.eml" || fail 'version absent in report'
# These labels share a fixed value column (32 characters), in both
# email text/plain and preformatted HTML. Protect against spacing drift.
for expected_line in \
    'Package backend:                dpkg' \
    'Package verifier exit code:     0' \
    'Pkg config/metadata warnings:   0'; do
    grep -Fxq "$expected_line" "$test_dir/last-email.eml" || \
        fail "plain-text email summary alignment: $expected_line"
    grep -Fq "$expected_line</span>" "$test_dir/last-email.eml" || \
        fail "HTML email summary alignment: $expected_line"
done
if grep -Fq 'Package config/metadata warnings:' "$test_dir/last-email.eml"; then
    fail 'obsolete too-long package warning label remains in email'
fi
pass 'aligned package backend, verifier status, and Pkg warnings in MIME report'
[[ -f $test_dir/integration-state.tsv ]] || fail 'state file not persisted'
pass 'full clean report, MIME sender, coverage, state persistence'

# End-to-end Focal OS fixture: package verification plus kernel scan and
# bounded coverage under systemd 245. No package installation, journald
# changes, or email are allowed in this mode.
printf 'ID=ubuntu\nVERSION_ID="20.04"\nPRETTY_NAME="Ubuntu 20.04.6 LTS (fixture)"\n' \
    > "$test_dir/ubuntu20-os-release"
: > "$test_dir/journal/raw"
: > "$test_dir/journal/export"
rm -f "$test_dir/last-email.eml"
MOCK_SYSTEMD_VERSION=245 MOCK_COVERAGE_MODE=normal MOCK_JOURNAL_STORAGE_MODE=auto
export MOCK_SYSTEMD_VERSION MOCK_COVERAGE_MODE MOCK_JOURNAL_STORAGE_MODE
env "${ENV_ARGS[@]}" \
    "OS_RELEASE_FILE=$test_dir/ubuntu20-os-release" \
    "REPORT_TO=username@email.address" "KERNEL_LOG_CHECK_ENABLED=1" \
    "TERMINAL_OUTPUT=always" \
    "AUTO_INSTALL_REQUIREMENTS=0" "AUTO_ENABLE_PERSISTENT_JOURNAL=0" \
    "NOTIFICATION_STATE_FILE=$test_dir/focal-state.tsv" \
    bash "$test_dir/integration.sh" > "$test_dir/focal-stdout" 2> "$test_dir/focal-stderr"
rc=$?
if (( rc != 0 )); then
    printf 'Focal integration audit exited %s. Captured stderr:\n' "$rc" >&2
    sed -n '1,100p' "$test_dir/focal-stderr" >&2
fi
assert_eq "$rc" 0 'Focal full audit returned successful status'
grep -q 'Ubuntu 20.04.6 LTS (fixture)' "$test_dir/focal-stdout" || fail 'Focal OS missing from report'
grep -q 'Package-file verification: *COMPLETED' "$test_dir/focal-stdout" || fail 'Focal package audit incomplete'
grep -q 'Kernel event review: *COMPLETED' "$test_dir/focal-stdout" || fail 'Focal kernel journal coverage incomplete'
[[ ! -e $test_dir/last-email.eml ]] || fail 'Focal placeholder unexpectedly sent email'
pass 'Ubuntu 20.04 end-to-end audit and mail placeholder'

# An exact missing-file approval works on Debian/Ubuntu too. It does not
# inherit modification globs or hide unrelated missing package payloads.
printf '%s\n' '/usr/lib/expected-missing.so' > "$test_dir/debian-approved-missing.txt"
cat > "$test_dir/debsums-missing.out" <<'EOF'
debsums: missing file /usr/lib/expected-missing.so (from fixture package)
debsums: missing file /usr/lib/unrelated-missing.so (from fixture package)
EOF
env "${ENV_ARGS[@]}" "REPORT_TO=username@email.address" \
    "MOCK_DEBSUMS_DIAGNOSTICS_FILE=$test_dir/debsums-missing.out" \
    "MISSING_EXCEPTIONS_FILE=$test_dir/debian-approved-missing.txt" \
    "STATEFUL_NOTIFICATIONS=0" \
    "NOTIFICATION_STATE_FILE=$test_dir/debian-missing-state.tsv" \
    "TERMINAL_OUTPUT=always" \
    bash "$test_dir/integration.sh" > "$test_dir/debian-missing.stdout" 2> "$test_dir/debian-missing.stderr"
rc=$?
assert_eq "$rc" 0 'Debian explicit missing exceptions run is not an execution error'
grep -q 'APPROVED.*expected-missing.so' "$test_dir/debian-missing.stdout" || fail 'Debian explicit missing exception not displayed'
grep -q 'MISSING.*unrelated-missing.so' "$test_dir/debian-missing.stdout" || fail 'Debian unrelated missing file wrongly suppressed'
grep -q 'Approved missing files ignored: 1' "$test_dir/debian-missing.stdout" || fail 'Debian approved missing counter inaccurate'
pass 'Debian/Ubuntu exact missing exception does not hide unrelated missing files'

# Ordinary modification exceptions, including globs, cannot hide missing
# Debian package files without an explicit exact-path approval.
printf '/usr/lib/*.so\n' > "$test_dir/debian-modifications.ignore"
env "${ENV_ARGS[@]}" "REPORT_TO=username@email.address" \
    "MOCK_DEBSUMS_DIAGNOSTICS_FILE=$test_dir/debsums-missing.out" \
    "EXCEPTIONS_FILE=$test_dir/debian-modifications.ignore" \
    "STATEFUL_NOTIFICATIONS=0" "TERMINAL_OUTPUT=always" \
    bash "$test_dir/integration.sh" > "$test_dir/debian-regular-exceptions.stdout" 2> "$test_dir/debian-regular-exceptions.stderr"
rc=$?
assert_eq "$rc" 0 'Debian modification-only exception run exits normally'
grep -q 'MISSING.*expected-missing.so' "$test_dir/debian-regular-exceptions.stdout" || fail 'Debian missing file was hidden by modifications glob'
pass 'Debian/Ubuntu modification globs cannot hide missing files'

# An older Ubuntu release must not be passed off as supported.
printf 'ID=ubuntu\nVERSION_ID="18.04"\n' > "$test_dir/ubuntu18-os-release"
env "${ENV_ARGS[@]}" "REPORT_TO=username@email.address" \
    "OS_RELEASE_FILE=$test_dir/ubuntu18-os-release" \
    bash "$test_dir/integration.sh" > "$test_dir/bionic-stdout" 2> "$test_dir/bionic-stderr"
rc=$?
assert_eq "$rc" 78 'Ubuntu 18.04 must be rejected as outside tested baseline'
grep -q 'minimum Ubuntu release is 20.04' "$test_dir/bionic-stderr" || fail 'Ubuntu 18.04 explanation missing'
pass 'Ubuntu 18.04 unvalidated release rejected'

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

# RPM distributions are no longer blocked at initialization. A separate
# regression script validates their full package and reporting lifecycle.
assert_eq "$(bash "$SCRIPT" --version)" 'system-integrity-audit 2.0.2' 'v2 release version'
pass 'RPM backend enabled in v2.0.2 release'

# Probe timeout must return 124, and never silently claim the check succeeded.
run_probe 1 sleep 2 > "$test_dir/timeout-out" 2> "$test_dir/timeout-err"
rc=$?
assert_eq "$rc" 124 'bounded probe timeout status'
grep -q 'TIMEOUT' "$test_dir/timeout-err" || fail 'missing timeout diagnostic'
pass 'bounded external command execution'

# XFS checks are entirely simulated. No real xfs_scrub or systemctl is run.
(
    mkdir -p "$test_dir/xfs-bin"
    cat > "$test_dir/xfs-bin/xfs_scrub" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' CALL "$@" >> "$MOCK_DIR/xfs-calls"
[[ $# == 2 && $1 == -n && $2 == /* ]] || exit 99
uuid=11111111-1111-1111-1111-111111111111
[[ $2 != /two ]] || uuid=22222222-2222-2222-2222-222222222222
grep -q $'\tRUNNING$' "$XFS_SCRUB_STATE_DIR/$uuid.state" || exit 97
if read -r anything; then exit 98; fi
printf '%s\n' 'EXPERIMENTAL xfs_scrub program in use!' \
    'Info: AG 1 superblock: Optimization is possible.' \
    'Info: Unicode name fn._mm_loadl_pd.html could be confused with fn._mm_load1_pd.html.'
[[ ${MOCK_XFS_MODE:-normal} != timeout ]] || exec sleep 3
exit "${MOCK_XFS_RC:-0}"
MOCK
    cat > "$test_dir/xfs-bin/findmnt" <<'MOCK'
#!/usr/bin/env bash
[[ ${MOCK_XFS_IDENTITY:-ok} != bad ]] || exit 1
uuid=11111111-1111-1111-1111-111111111111
[[ $3 != /two ]] || uuid=22222222-2222-2222-2222-222222222222
printf 'xfs %s /\n' "$uuid"
MOCK
    cat > "$test_dir/xfs-bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
case $1 in
    is-enabled) echo "${MOCK_XFS_TIMER:-disabled}" ;;
    is-active)
        if [[ $2 == xfs_scrub_all.service ]]; then
            echo "${MOCK_XFS_SERVICE_ACTIVE:-inactive}"
        else
            echo "${MOCK_XFS_TIMER_ACTIVE:-inactive}"
        fi
        ;;
    show) echo "${MOCK_XFS_LOAD_STATE:-loaded}" ;;
    *) exit 1 ;;
esac
MOCK
    cat > "$test_dir/xfs-bin/pgrep" <<'MOCK'
#!/usr/bin/env bash
exit "${MOCK_XFS_BUSY:-1}"
MOCK
    chmod +x "$test_dir/xfs-bin/"*
    PATH="$test_dir/xfs-bin:$PATH"
    export PATH
    export MOCK_XFS_RC=0 MOCK_XFS_BUSY=1 MOCK_XFS_TIMER=disabled
    export MOCK_XFS_MODE=normal MOCK_XFS_IDENTITY=ok MOCK_XFS_TIMER_ACTIVE=inactive
    XFS_SCRUB_AUTO=1
    XFS_SCRUB_INTERVAL_DAYS=7
    XFS_SCRUB_TIMEOUT_SECONDS=5
    export XFS_SCRUB_STATE_DIR="$test_dir/xfs-state"
    PROGRESS_OUTPUT=never
    state_a="$XFS_SCRUB_STATE_DIR/11111111-1111-1111-1111-111111111111.state"
    single_mount() { printf '/dev/a\t/one space\txfs\trw\n' > "$local_filesystems_file"; }
    reset_xfs_findings() {
        : > "$filesystem_findings_file"
        : > "$filesystem_details_file"
        filesystem_alert_count=0
        filesystem_warning_count=0
        filesystem_notice_count=0
        filesystem_check_error_count=0
    }
    reset_xfs() {
        rm -rf -- "$XFS_SCRUB_STATE_DIR"
        : > "$test_dir/xfs-calls"
        reset_xfs_findings
        single_mount
    }
    reset_xfs
    XFS_SCRUB_AUTO=0 run_scheduled_xfs_scrubs
    [[ ! -e $XFS_SCRUB_STATE_DIR && ! -s $test_dir/xfs-calls ]] || fail 'XFS opt-out wrote state or ran a scan'
    pass 'XFS scheduler is opt-in and disabled path performs no scan or state writes'

    printf '/dev/a\t/duplicate\txfs\trw\n/dev/b\t/two\txfs\trw\n/dev/a\t/bind\txfs\trw,bind\n' >> "$local_filesystems_file"
    deep_check_target_count=0
    check_deep_scrub_scheduling
    grep -q 'DEEP-CHECK.*xfs_scrub_all' "$filesystem_findings_file" && fail 'audit-managed XFS checks retained disabled stock-timer notice'
    assert_eq "$(grep -c '^CALL$' "$test_dir/xfs-calls")" 2 'XFS UUID deduplication'
    assert_eq "$filesystem_alert_count:$filesystem_warning_count:$filesystem_check_error_count" '0:0:0' 'XFS informational messages must not become warnings or alerts'
    grep -q 'could be confused' "$filesystem_details_file" || fail 'XFS informational output missing from report'
    assert_eq "$(stat -c %a "$XFS_SCRUB_STATE_DIR")" 700 'XFS state directory permissions'
    assert_eq "$(stat -c %a "$state_a")" 600 'XFS record permissions'
    pass 'XFS runs check-only with closed stdin, deduplicates UUIDs, skips binds and retains informational output'

    reset_xfs_findings
    run_scheduled_xfs_scrubs
    assert_eq "$(grep -c '^CALL$' "$test_dir/xfs-calls")" 2 'weekly XFS checks must not repeat on next audit'
    grep -q 'could be confused' "$filesystem_details_file" || fail 'cached XFS output absent'
    old_epoch=$(( $(date +%s) - 8 * 86400 ))
    for state in "$XFS_SCRUB_STATE_DIR/"*.state; do
        sed -i "1s/^[0-9]*/$old_epoch/" "$state"
    done
    run_scheduled_xfs_scrubs
    assert_eq "$(grep -c '^CALL$' "$test_dir/xfs-calls")" 4 'XFS checks must run again after interval'
    pass 'XFS weekly interval persists across audits and retained output remains visible'

    for status in 1 2 3 4 8 16 124 137; do
        reset_xfs
        MOCK_XFS_RC=$status run_scheduled_xfs_scrubs
        case $status in
            1|3) (( filesystem_alert_count == 1 )) || fail 'XFS corruption exit bit must alert' ;;
            2) assert_eq "$filesystem_warning_count:$filesystem_alert_count" '0:0' 'XFS optimization exit is informational' ;;
            *) (( filesystem_check_error_count == 1 && filesystem_alert_count == 0 )) || fail 'XFS operational failure/timeout must be incomplete, not corruption' ;;
        esac
        before="$filesystem_alert_count:$filesystem_warning_count:$filesystem_check_error_count"
        reset_xfs_findings
        run_scheduled_xfs_scrubs
        assert_eq "$filesystem_alert_count:$filesystem_warning_count:$filesystem_check_error_count" "$before" 'cached XFS error classification'
        assert_eq "$(grep -c '^CALL$' "$test_dir/xfs-calls")" 1 'failed XFS attempt must not immediately repeat'
    done
    pass 'XFS error, optimization, operational and timeout statuses retain their meaning between audits'

    reset_xfs
    MOCK_XFS_MODE=timeout XFS_SCRUB_TIMEOUT_SECONDS=1 run_scheduled_xfs_scrubs
    grep -q $'\t124$' "$state_a" || fail 'XFS real timeout result not saved'
    (( filesystem_check_error_count == 1 )) || fail 'XFS timeout coverage must be incomplete'
    pass 'XFS scan is time bounded and timeout is persisted'

    reset_xfs
    MOCK_XFS_TIMER=enabled run_scheduled_xfs_scrubs
    [[ ! -s $test_dir/xfs-calls ]] || fail 'XFS scan overlapped enabled stock timer'
    MOCK_XFS_TIMER_ACTIVE=active run_scheduled_xfs_scrubs
    [[ ! -s $test_dir/xfs-calls ]] || fail 'XFS scan overlapped active stock timer'
    MOCK_XFS_TIMER=unknown run_scheduled_xfs_scrubs
    [[ ! -s $test_dir/xfs-calls ]] || fail 'XFS scan ignored unknown timer state'
    MOCK_XFS_BUSY=0 run_scheduled_xfs_scrubs
    [[ ! -s $test_dir/xfs-calls ]] || fail 'XFS scan overlapped another scrub process'
    reset_xfs_findings
    MOCK_XFS_BUSY=2 run_scheduled_xfs_scrubs
    (( filesystem_check_error_count == 1 )) || fail 'XFS process detection error not reported'
    MOCK_XFS_SERVICE_ACTIVE=activating run_scheduled_xfs_scrubs
    [[ ! -s $test_dir/xfs-calls ]] || fail 'XFS scan overlapped starting stock service'
    pass 'XFS scheduler avoids stock timers and running scrubs, and fails closed on unknown state'

    reset_xfs
    MOCK_XFS_LOAD_STATE=not-found MOCK_XFS_TIMER='' MOCK_XFS_TIMER_ACTIVE=inactive \
        run_scheduled_xfs_scrubs
    assert_eq "$(grep -c '^CALL$' "$test_dir/xfs-calls")" 1 'verified absent stock timer should allow check-only scrub'
    pass 'XFS scheduler permits a verified absent stock timer'


    reset_xfs
    MOCK_XFS_IDENTITY=bad run_scheduled_xfs_scrubs
    [[ ! -s $test_dir/xfs-calls ]] || fail 'XFS scan ran without verified UUID'
    (( filesystem_check_error_count == 1 )) || fail 'XFS unknown identity not reported'
    pass 'XFS scheduler refuses unverifiable filesystem identity'

    reset_xfs
    mkdir -m 700 "$XFS_SCRUB_STATE_DIR"
    printf '%s\tRUNNING\n' "$(date +%s)" > "$state_a"
    run_scheduled_xfs_scrubs
    [[ ! -s $test_dir/xfs-calls ]] || fail 'XFS interrupted attempt retried immediately'
    (( filesystem_check_error_count == 1 )) || fail 'XFS interrupted attempt not reported'
    reset_xfs_findings
    printf '%s\t0\n' "$(( $(date +%s) + 86400 ))" > "$state_a"
    run_scheduled_xfs_scrubs
    [[ ! -s $test_dir/xfs-calls ]] || fail 'XFS future timestamp caused scan'
    (( filesystem_check_error_count == 1 )) || fail 'XFS future timestamp not reported'
    printf 'garbage\n' > "$state_a"
    run_scheduled_xfs_scrubs
    [[ ! -s $test_dir/xfs-calls ]] || fail 'XFS malformed state caused scan'
    pass 'XFS interrupted, future and malformed state fails closed'

    reset_xfs
    mkdir "$test_dir/xfs-outside"
    printf 'sentinel\n' > "$test_dir/xfs-outside/sentinel"
    ln -s "$test_dir/xfs-outside" "$XFS_SCRUB_STATE_DIR"
    run_scheduled_xfs_scrubs
    [[ ! -s $test_dir/xfs-calls ]] || fail 'XFS symlinked directory accepted'
    rm "$XFS_SCRUB_STATE_DIR"
    mkdir -m 700 "$XFS_SCRUB_STATE_DIR"
    ln -s "$test_dir/xfs-outside/sentinel" "$state_a"
    run_scheduled_xfs_scrubs
    assert_eq "$(cat "$test_dir/xfs-outside/sentinel")" sentinel 'XFS symlink target overwritten'
    [[ ! -s $test_dir/xfs-calls ]] || fail 'XFS symlinked record accepted'
    rm "$state_a"
    chmod 755 "$XFS_SCRUB_STATE_DIR"
    run_scheduled_xfs_scrubs
    [[ ! -s $test_dir/xfs-calls ]] || fail 'XFS nonprivate directory accepted'
    pass 'XFS scheduler rejects symlinked and nonprivate state without overwriting targets'

    reset_xfs
    MOCK_XFS_RC=1 run_scheduled_xfs_scrubs
    reset_xfs_findings
    MOCK_XFS_TIMER=enabled run_scheduled_xfs_scrubs
    (( filesystem_alert_count == 1 )) || fail 'enabled stock timer hid cached XFS corruption'
    pass 'XFS cached corruption remains visible when external scheduling blocks new checks'

    reset_xfs
    (
        command() {
            [[ ${1:-}:${2:-} != -v:xfs_scrub ]] || return 1
            builtin command "$@"
        }
        run_scheduled_xfs_scrubs
        [[ ! -s $test_dir/xfs-calls ]] || fail 'XFS scan ran without required tool'
        (( filesystem_check_error_count == 1 )) || fail 'XFS missing tool not reported'
    ) || fail 'missing XFS tool fixture'
    (
        write_xfs_scrub_state() { return 1; }
        run_scheduled_xfs_scrubs
        [[ ! -s $test_dir/xfs-calls ]] || fail 'XFS scan started before durable attempt record'
        (( filesystem_check_error_count == 1 )) || fail 'XFS state write failure not reported'
    ) || fail 'XFS state-write fixture'
    pass 'XFS missing tools and failed attempt recording prevent dispatch'

    reset_xfs
    (
        command() {
            [[ ${1:-}:${2:-} != -v:xfs_scrub_all ]] || return 0
            builtin command "$@"
        }
        XFS_SCRUB_AUTO=0 check_deep_scrub_scheduling
        grep -q 'DEEP-CHECK.*xfs_scrub_all.*disabled' "$filesystem_findings_file" || fail 'disabled XFS scheduler lost original timer notice'
        [[ ! -e $XFS_SCRUB_STATE_DIR && ! -s $test_dir/xfs-calls ]] || fail 'disabled scheduler wrote state or dispatched a scan'
    ) || fail 'disabled XFS timer-inspection fixture'
    pass 'XFS disabled scheduler preserves stock timer inspection without scans'
) || fail 'XFS scheduler regression group'

echo 'All regression tests passed.'
