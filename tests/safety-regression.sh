#!/usr/bin/env bash
# Focused safety regressions; only scratch files and fake administrative tools.
set -euo pipefail
SCRIPT=${1:-"$(dirname "$0")/../system-integrity-audit"}
SCRIPT=$(readlink -f -- "$SCRIPT")
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
awk '/^trap on_exit EXIT$/{exit} {print}' "$SCRIPT" > "$test_dir/definitions.sh"
source "$test_dir/definitions.sh"
set +e # Audit functions deliberately capture nonzero command statuses.
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
assert_eq() { [[ $1 == "$2" ]] || fail "$3 (got '$1', expected '$2')"; }
key_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
key_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SMART_SHORT_TEST_STATE_FILE="$test_dir/state/starts.tsv"
mkdir -m 700 "$test_dir/state"
printf '%s\t100\n' "$key_a" > "$SMART_SHORT_TEST_STATE_FILE"
cp "$SMART_SHORT_TEST_STATE_FILE" "$test_dir/original-state"
# Ignore XFSZ so real kernel write errors return to the function. Neither
# copying old rows nor appending the new intent may be masked by a later mv.
(
    trap '' XFSZ
    ulimit -f 0
    smart_short_test_record_start "$key_b" 200
) >/dev/null 2>/dev/null
rc=$?
(( rc != 0 )) || fail 'SMART state-copy write failure returned success'
cmp -s "$SMART_SHORT_TEST_STATE_FILE" "$test_dir/original-state" || fail 'SMART write failure replaced old state'
[[ $(find "$test_dir/state" -name '.smart-short-tests.*' | wc -l) == 0 ]] || fail 'SMART failed temporary state retained'
pass 'SMART old-row write failure preserves existing cooldown records'

rm "$SMART_SHORT_TEST_STATE_FILE"
(
    trap '' XFSZ
    ulimit -f 0
    smart_short_test_record_start "$key_b" 200
) >/dev/null 2>/dev/null
rc=$?
(( rc != 0 )) || fail 'SMART intent write failure returned success'
[[ ! -e $SMART_SHORT_TEST_STATE_FILE ]] || fail 'SMART empty state published after failed intent write'
smart_short_test_record_start "$key_a" 100 || fail 'SMART successful initial record'
smart_short_test_record_start "$key_b" 200 || fail 'SMART successful second record'
assert_eq "$(wc -l < "$SMART_SHORT_TEST_STATE_FILE")" 2 'SMART successful state row count'
grep -Fxq "$key_a"$'\t100' "$SMART_SHORT_TEST_STATE_FILE" || fail 'SMART old row lost on success'
grep -Fxq "$key_b"$'\t200' "$SMART_SHORT_TEST_STATE_FILE" || fail 'SMART new intent absent'
pass 'SMART new-intent write failure fails closed and normal state writes retain both records'

# All mail is consumed by this executable; no host mailer is invoked.
mkdir "$test_dir/bin"
cat > "$test_dir/bin/sendmail" <<'MOCK'
#!/usr/bin/env bash
cat > "$SAFETY_TEST_ROOT/captured-email"
case ${SAFETY_MAIL_MODE:-ok} in
    ok) exit 0 ;;
    fail) exit 75 ;;
    hang) sleep 30 ;;
esac
MOCK
chmod +x "$test_dir/bin/sendmail"
PATH="$test_dir/bin:$PATH"
export PATH SAFETY_TEST_ROOT=$test_dir
REPORT_TO=auditor@example.invalid
printf 'plain report\n' > "$test_dir/body"
printf '<p>html report</p>\n' > "$test_dir/body.html"
MAIL_TIMEOUT_SECONDS=1
SAFETY_MAIL_MODE=ok send_report fixture "$test_dir/body" "$test_dir/body.html" || fail 'successful mocked mail delivery'
grep -q 'plain report' "$test_dir/captured-email" || fail 'plain body absent'
grep -q 'html report' "$test_dir/captured-email" || fail 'HTML body absent'
SAFETY_MAIL_MODE=fail send_report fixture "$test_dir/body" "$test_dir/body.html" >/dev/null 2>&1
assert_eq "$?" 75 'sendmail failure status preserved'
SAFETY_MAIL_MODE=hang send_report fixture "$test_dir/body" "$test_dir/body.html" >/dev/null 2> "$test_dir/mail-timeout"
assert_eq "$?" 124 'stalled sendmail must time out'
grep -q 'TIMEOUT: sendmail exceeded 1 seconds' "$test_dir/mail-timeout" || fail 'mailer timeout diagnostic absent'
pass 'sendmail success/failure statuses survive and stalled transport is time bounded'

SAFETY_MAIL_MODE=hang preflight_failure_email 1 'fixture preflight' >/dev/null 2> "$test_dir/preflight-timeout"
assert_eq "$?" 124 'preflight mail must use the same delivery timeout'
pass 'early failure notifications also obey the mail-delivery timeout'

(
    run_probe() {
        printf '%s' "$1" > "$test_dir/early-mail-deadline"
        cat >/dev/null
        return 124
    }
    for invalid in 0 abc 9999999999999999999999; do
        MAIL_TIMEOUT_SECONDS=$invalid preflight_failure_email 64 'invalid configuration' >/dev/null 2>&1
        assert_eq "$?" 124 'early mail stub status'
        assert_eq "$(cat "$test_dir/early-mail-deadline")" 120 'unsafe early-mail timeout did not fall back to bounded default'
    done
    MAIL_TIMEOUT_SECONDS=0009 send_report fixture "$test_dir/body" "$test_dir/body.html" >/dev/null 2>&1
    assert_eq "$(cat "$test_dir/early-mail-deadline")" 9 'early mail did not normalize a valid decimal deadline'
) || fail 'early mail deadline validation fixture'
pass 'early error mail uses a safe deadline before startup normalization'

# Exercise the post-normalization validation block without root/admin startup.
# Leading-zero input is tested by the separate configuration-normalization suite.
awk '
    /^if ! \[\[ \$MAIL_TIMEOUT_SECONDS =~/ { copy=1 }
    copy { print }
    copy && /^fi$/ { exit }
' "$SCRIPT" > "$test_dir/mail-validation.sh"
[[ -s $test_dir/mail-validation.sh ]] || fail 'mail timeout validation block absent'
for valid in 1 120 86400; do
    env PROGRAM_NAME=fixture MAIL_TIMEOUT_SECONDS="$valid" bash "$test_dir/mail-validation.sh" >/dev/null 2>&1
    assert_eq "$?" 0 'valid mail timeout rejected'
done
for invalid in 0 -1 86401 9999999999999999999999 abc; do
    env PROGRAM_NAME=fixture MAIL_TIMEOUT_SECONDS="$invalid" bash "$test_dir/mail-validation.sh" >/dev/null 2>&1
    assert_eq "$?" 64 'invalid mail timeout accepted'
done
bash "$SCRIPT" --help | grep -q 'MAIL_TIMEOUT_SECONDS=120' || fail 'mail timeout help absent'
pass 'mail timeout validates positive bounded seconds and appears in help'

# No systemctl, journalctl, systemd-tmpfiles or /var writes are real: every
# administrative operation is intercepted and the probe rejects unknown calls.
(
    JOURNAL_PERSISTENCE_DROPIN="$test_dir/journald.conf"
    printf '[Journal]\nStorage=persistent\n' > "$JOURNAL_PERSISTENCE_DROPIN"
    KERNEL_LOG_CHECK_ENABLED=1
    AUTO_ENABLE_PERSISTENT_JOURNAL=1
    automatic_changes_file="$test_dir/automatic-changes"
    execution_notes_file="$test_dir/execution-notes"
    : > "$automatic_changes_file"; : > "$execution_notes_file"
    automatic_change_count=0; automatic_warning_count=0
    kernel_persistence_error=0; kernel_persistence_changed=0
    persistent_journal_is_configured() { return 1; }
    verify_persistent_journal_storage() { printf 'verify\n' >> "$test_dir/journal-operations"; return 0; }
    mkdir() {
        [[ $# == 3 && $1 == -p && $2 == -- && $3 == /var/log/journal ]] || return 98
        printf 'prepare\n' >> "$test_dir/journal-operations"
    }
    systemd-tmpfiles() {
        [[ $* == '--create --prefix /var/log/journal' ]] || return 98
        printf 'tmpfiles\n' >> "$test_dir/journal-operations"
    }
    run_probe() {
        shift
        case "$*" in
            'systemctl restart systemd-journald.service')
                printf 'restart\n' >> "$test_dir/journal-operations"
                return "${SAFETY_RESTART_RC:-0}"
                ;;
            'journalctl --flush') printf 'flush\n' >> "$test_dir/journal-operations" ;;
            *) printf 'unexpected administrative command: %s\n' "$*" >&2; return 98 ;;
        esac
    }
    logger() { :; }
    : > "$test_dir/journal-operations"
    ensure_persistent_journal_storage || fail 'mocked journald persistence setup'
    assert_eq "$(cat "$test_dir/journal-operations")" $'prepare\ntmpfiles\nrestart\nflush\nverify' 'journald restart/flush/verification order'
    assert_eq "$kernel_persistence_error" 0 'journald success marked failed'
    pass 'journald setup restarts through systemctl before flushing and verifying, without SIGHUP'
    : > "$test_dir/journal-operations"
    kernel_persistence_error=0
    SAFETY_RESTART_RC=1 ensure_persistent_journal_storage >/dev/null 2>&1
    (( $? != 0 )) || fail 'journald restart failure returned success'
    assert_eq "$kernel_persistence_error" 1 'journald restart failure not marked incomplete'
    if grep -qE 'flush|verify' "$test_dir/journal-operations"; then
        fail 'journald flush/verification continued after failed restart'
    fi
    pass 'failed journald restart stops before flush and reports incomplete setup'
) || fail 'journald safety fixture'
printf 'All safety regression tests passed.\n'
