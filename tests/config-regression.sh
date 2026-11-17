#!/usr/bin/env bash
# Validate configuration without running the audit, firmware tools, or mailer.
set -euo pipefail
SCRIPT=${1:-"$(dirname "$0")/../system-integrity-audit"}
[[ -r $SCRIPT ]] || { printf 'Missing audit script: %s\n' "$SCRIPT" >&2; exit 1; }
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
awk '/^trap on_exit EXIT$/{exit} {print}' "$SCRIPT" > "$test_dir/definitions.sh"
awk '
    /^normalize_numeric_configuration \|\| exit \$\?$/ { copy=1 }
    /^core_commands=\(/ { exit }
    copy { print }
' "$SCRIPT" > "$test_dir/validation.sh"
grep -Fxq 'normalize_numeric_configuration || exit $?' "$test_dir/validation.sh"
grep -q 'SPACE_NOTICE_PERCENT < SPACE_WARNING_PERCENT' "$test_dir/validation.sh"
cat > "$test_dir/harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -u
source "$1"
source "$2"
for setting in APT_LOCK_WAIT_SECONDS APT_LOCK_RETRY_COUNT MEGARAID_MAX_INDEX \
    SCRUB_MAX_AGE_DAYS SPACE_NOTICE_PERCENT SPACE_WARNING_PERCENT SPACE_ALERT_PERCENT \
    INODE_NOTICE_PERCENT INODE_WARNING_PERCENT INODE_ALERT_PERCENT \
    LVM_THIN_NOTICE_PERCENT LVM_THIN_WARNING_PERCENT LVM_THIN_ALERT_PERCENT \
    SMART_SHORT_TEST_AGE_DAYS XFS_SCRUB_INTERVAL_DAYS XFS_SCRUB_TIMEOUT_SECONDS \
    MAIL_TIMEOUT_SECONDS SMART_TIMEOUT_SECONDS PROBE_TIMEOUT_SECONDS JOURNAL_TIMEOUT_SECONDS \
    APT_COMMAND_TIMEOUT_SECONDS DEBSUMS_TIMEOUT_SECONDS RPM_VERIFY_TIMEOUT_SECONDS \
    DNF_COMMAND_TIMEOUT_SECONDS ATA_CORRELATION_SECONDS NOTIFICATION_REPEAT_DAYS \
    MEGARAID_SCAN_BUDGET_SECONDS; do
    printf '%s=%s\n' "$setting" "${!setting}"
done
printf 'SMART_AGE_HOURS=%s\n' "$(( SMART_SHORT_TEST_AGE_DAYS * 24 ))"
printf 'NOTIFICATION_SECONDS=%s\n' "$(( NOTIFICATION_REPEAT_DAYS * 86400 ))"
HARNESS
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
run_config() {
    env -i PATH="$PATH" LC_ALL=C "$@" \
        bash "$test_dir/harness.sh" "$test_dir/definitions.sh" "$test_dir/validation.sh" \
        > "$test_dir/output" 2> "$test_dir/error"
}
expect_value() { grep -Fxq "$1=$2" "$test_dir/output" || fail "unexpected normalized value for $1"; }
expect_invalid() {
    local rc
    if run_config "$1=$2"; then
        fail "invalid setting accepted: $1"
    else
        rc=$?
    fi
    [[ $rc == 64 ]] || fail "invalid setting did not return configuration status 64: $1"
    grep -q "$1" "$test_dir/error" || fail "configuration diagnostic omits setting: $1"
    if grep -Eq 'value too great for base|syntax error|overflow' "$test_dir/error"; then
        fail "raw input reached shell arithmetic: $1"
    fi
}

run_config
expect_value SMART_SHORT_TEST_AGE_DAYS 60
expect_value SMART_AGE_HOURS 1440
expect_value XFS_SCRUB_INTERVAL_DAYS 7
pass 'default numeric configuration and documented interval values remain valid'

run_config SMART_SHORT_TEST_AGE_DAYS=060 XFS_SCRUB_INTERVAL_DAYS=007 \
    XFS_SCRUB_TIMEOUT_SECONDS=0003600 MAIL_TIMEOUT_SECONDS=00120 \
    APT_LOCK_WAIT_SECONDS=000240 APT_LOCK_RETRY_COUNT=005 MEGARAID_MAX_INDEX=063 \
    SCRUB_MAX_AGE_DAYS=045 SPACE_NOTICE_PERCENT=085 SPACE_WARNING_PERCENT=092 \
    SPACE_ALERT_PERCENT=097 INODE_NOTICE_PERCENT=085 INODE_WARNING_PERCENT=092 \
    INODE_ALERT_PERCENT=097 LVM_THIN_NOTICE_PERCENT=080 LVM_THIN_WARNING_PERCENT=090 \
    LVM_THIN_ALERT_PERCENT=095 SMART_TIMEOUT_SECONDS=090 PROBE_TIMEOUT_SECONDS=0120 \
    JOURNAL_TIMEOUT_SECONDS=0180 APT_COMMAND_TIMEOUT_SECONDS=01800 \
    DEBSUMS_TIMEOUT_SECONDS=07200 RPM_VERIFY_TIMEOUT_SECONDS=07200 \
    ATA_CORRELATION_SECONDS=0120 NOTIFICATION_REPEAT_DAYS=007 MEGARAID_SCAN_BUDGET_SECONDS=0240
expect_value SMART_SHORT_TEST_AGE_DAYS 60
expect_value SMART_AGE_HOURS 1440
expect_value MEGARAID_MAX_INDEX 63
expect_value PROBE_TIMEOUT_SECONDS 120
expect_value DNF_COMMAND_TIMEOUT_SECONDS 1800
expect_value MAIL_TIMEOUT_SECONDS 120
if grep -Eq '^[A-Z_]+=0[0-9]' "$test_dir/output"; then fail 'zero-prefixed configuration remained unnormalized'; fi
pass 'all numeric settings normalize leading zeros to decimal before arithmetic'

run_config SMART_SHORT_TEST_AGE_DAYS=08 APT_LOCK_WAIT_SECONDS=000 APT_LOCK_RETRY_COUNT=000 \
    XFS_SCRUB_INTERVAL_DAYS=08 SCRUB_MAX_AGE_DAYS=000
expect_value SMART_SHORT_TEST_AGE_DAYS 8
expect_value SMART_AGE_HOURS 192
expect_value XFS_SCRUB_INTERVAL_DAYS 8
expect_value APT_LOCK_WAIT_SECONDS 0
expect_value APT_LOCK_RETRY_COUNT 0
expect_value SCRUB_MAX_AGE_DAYS 0
[[ ! -s $test_dir/error ]] || fail '08 emitted an arithmetic diagnostic'
pass '08 is decimal eight and zero remains valid for nonnegative controls'

run_config SMART_SHORT_TEST_AGE_DAYS=3650 XFS_SCRUB_INTERVAL_DAYS=3650 \
    XFS_SCRUB_TIMEOUT_SECONDS=86400 MAIL_TIMEOUT_SECONDS=86400 MEGARAID_MAX_INDEX=255 \
    SPACE_NOTICE_PERCENT=0 SPACE_WARNING_PERCENT=1 SPACE_ALERT_PERCENT=100 \
    INODE_NOTICE_PERCENT=0 INODE_WARNING_PERCENT=1 INODE_ALERT_PERCENT=100 \
    LVM_THIN_NOTICE_PERCENT=0 LVM_THIN_WARNING_PERCENT=1 LVM_THIN_ALERT_PERCENT=100
expect_value SMART_SHORT_TEST_AGE_DAYS 3650
expect_value MAIL_TIMEOUT_SECONDS 86400
expect_value MEGARAID_MAX_INDEX 255
pass 'documented upper bounds and percentage ordering remain valid'

for bad in ' ' -1 +8 8.0 0x10 '1+2' '1;echo bad' '$(touch CONFIG_TEST_MUST_NOT_EXIST)'; do
    expect_invalid SMART_SHORT_TEST_AGE_DAYS "$bad"
done
for pair in SMART_SHORT_TEST_AGE_DAYS:0 SMART_SHORT_TEST_AGE_DAYS:3651 \
    XFS_SCRUB_INTERVAL_DAYS:0 XFS_SCRUB_INTERVAL_DAYS:3651 \
    XFS_SCRUB_TIMEOUT_SECONDS:0 XFS_SCRUB_TIMEOUT_SECONDS:86401 \
    MAIL_TIMEOUT_SECONDS:0 MAIL_TIMEOUT_SECONDS:86401 MEGARAID_MAX_INDEX:256 \
    SPACE_NOTICE_PERCENT:101 PROBE_TIMEOUT_SECONDS:0; do
    expect_invalid "${pair%:*}" "${pair#*:}"
done
pass 'nondecimal text and out-of-range configuration fail cleanly before audit execution'

huge=$(printf '9%.0s' {1..2000})
expect_invalid APT_LOCK_WAIT_SECONDS "$huge"
expect_invalid SMART_TIMEOUT_SECONDS 9223372036854775808
expect_invalid NOTIFICATION_REPEAT_DAYS 106751991167301
expect_invalid ATA_CORRELATION_SECONDS 4611686018427387904
run_config APT_LOCK_WAIT_SECONDS=9223372036854775807 \
    NOTIFICATION_REPEAT_DAYS=106751991167300 ATA_CORRELATION_SECONDS=4611686018427387903
expect_value APT_LOCK_WAIT_SECONDS 9223372036854775807
expect_value NOTIFICATION_SECONDS 9223372036854720000
pass 'oversized inputs are rejected by decimal string checks and day products cannot overflow'

zeros=$(printf '0%.0s' {1..2000})
run_config "SMART_SHORT_TEST_AGE_DAYS=${zeros}60"
expect_value SMART_SHORT_TEST_AGE_DAYS 60
expect_value SMART_AGE_HOURS 1440
pass 'long zero prefixes normalize safely without raw numeric evaluation'

if run_config SPACE_NOTICE_PERCENT=092 SPACE_WARNING_PERCENT=085; then
    fail 'normalization bypassed percentage threshold ordering'
else
    [[ $? == 64 ]] || fail 'threshold ordering did not return status 64'
fi
grep -q 'NOTICE thresholds must be lower' "$test_dir/error" || fail 'threshold ordering diagnostic absent'
pass 'threshold-order validation still applies after decimal normalization'
printf 'All configuration regression tests passed.\n'
