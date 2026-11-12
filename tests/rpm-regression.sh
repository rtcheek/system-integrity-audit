#!/usr/bin/env bash
# Non-destructive RPM backend regression tests (Rocky Linux/RHEL fixtures).
set -euo pipefail
SCRIPT=${1:-"$(dirname "$0")/../system-integrity-audit"}
SCRIPT=$(readlink -f -- "$SCRIPT")
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/bin"
cat > "$test_dir/bin/rpm" <<'EOF'
#!/usr/bin/env bash
if [[ $* == *'-Va'* ]]; then
    printf '%s\n' "$*" >> "$MOCK_DIR/rpm-commands"
    cat "$MOCK_DIR/rpm-verify.out"
    exit "${MOCK_RPM_RC:-1}"
fi
if [[ ${1:-} == -qf ]]; then
    printf 'samplepkg-1.2-3.x86_64\n'
    exit 0
fi
exit 42
EOF
cat > "$test_dir/bin/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$test_dir/bin/sendmail" <<'EOF'
#!/usr/bin/env bash
cat > "$MOCK_DIR/email.eml"
EOF
chmod +x "$test_dir/bin"/*
cp "$SCRIPT" "$test_dir/integration.sh"
sed -i "s@^PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'@PATH='$test_dir/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'@" "$test_dir/integration.sh"
printf 'ID=rocky\nPRETTY_NAME="Rocky Linux 9 (test fixture)"\n' > "$test_dir/rocky-os-release"
printf 'ID=rhel\nPRETTY_NAME="Red Hat Enterprise Linux 9 (test fixture)"\n' > "$test_dir/rhel-os-release"
ENV_ARGS=(
    "MOCK_DIR=$test_dir" "AUTO_INSTALL_REQUIREMENTS=0"
    "KERNEL_LOG_CHECK_ENABLED=0" "SMART_CHECK_ENABLED=0" "FILESYSTEM_CHECKS_ENABLED=0"
    "PROGRESS_OUTPUT=never" "TERMINAL_OUTPUT=always" "STATEFUL_NOTIFICATIONS=0"
    "EXCEPTIONS_FILE=$test_dir/nonexistent-exceptions"
    "LOCK_FILE=$test_dir/test.lock" "REPORT_COVERAGE_GAPS=0"
    "FORCE_REPORT=1" "REPORT_TO=username@email.address"
    "NOTIFICATION_STATE_FILE=$test_dir/state.tsv"
    "OS_RELEASE_FILE=$test_dir/rocky-os-release"
)
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
run_case() {
    local name=$1 rc
    shift
    rm -f "$test_dir/email.eml"
    if env "${ENV_ARGS[@]}" "$@" bash "$test_dir/integration.sh" > "$test_dir/$name.stdout" 2> "$test_dir/$name.stderr"; then
        rc=0
    else
        rc=$?
    fi
    echo "$rc" > "$test_dir/$name.exit"
}
# Verify payload content and missing files ALERT, config and metadata warnings,
# time-only drift skipped, ephemeral ghost files skipped, and exception policy.
cat > "$test_dir/rpm-verify.out" <<'EOF'
S.5....T.    /usr/bin/modified-tool
missing     /usr/lib64/missing.so
S.5....T.  c /etc/app/config with spaces.conf
.M......P    /usr/bin/modified-capabilities
.......T.    /usr/share/doc/somepackage
missing     g /run/ephemeral-file
EOF
export MOCK_DIR=$test_dir
run_case changes MOCK_RPM_RC=1
[[ $(cat "$test_dir/changes.exit") == 0 ]] || fail 'RPM mismatch status must not be an execution error'
grep -q 'Audit status: ALERT' "$test_dir/changes.stdout" || fail 'payload/missing file must be ALERT'
grep -q 'MISSING.*missing.so' "$test_dir/changes.stdout" || fail 'missing package file missing'
grep -q 'CHANGED.*modified-tool' "$test_dir/changes.stdout" || fail 'payload change missing'
grep -q 'CONFIG.*config with spaces.conf' "$test_dir/changes.stdout" || fail 'config mismatch missing'
grep -q 'METADATA.*modified-capabilities' "$test_dir/changes.stdout" || fail 'metadata mismatch missing'
! grep -q 'somepackage\|ephemeral-file' "$test_dir/changes.stdout" || fail 'ghost/timestamp noise must be suppressed'
grep -q -- '-Va --noscripts --noghost' "$test_dir/rpm-commands" || fail 'RPM check must not run verify scriptlets or ghost payload'
[[ ! -e "$test_dir/email.eml" ]] || fail 'default placeholder should never send email'
pass 'Rocky RPM mismatch classifications and safe email default'

# The same backend works for RHEL and keeps multipart mail functional.
run_case rhel OS_RELEASE_FILE="$test_dir/rhel-os-release" REPORT_TO=auditor@example.invalid
grep -q 'Audit status: ALERT' "$test_dir/rhel.stdout" || fail 'RHEL backend failed'
grep -q '^Subject: .* ALERT - ' "$test_dir/email.eml" || fail 'RHEL alert email absent'
pass 'RHEL 9 backend selection and multipart email'

# Timestamp-only changes are common on RPM systems; no warning/alert.
printf '.......T.    /usr/bin/timeonly\n' > "$test_dir/rpm-verify.out"
run_case timestamp MOCK_RPM_RC=1
[[ $(cat "$test_dir/timestamp.exit") == 0 ]] || fail 'timestamp-only RPM drift should not error'
grep -q 'Audit status: TEST/OK' "$test_dir/timestamp.stdout" || fail 'timestamp-only drift should not warn'
run_case timestamp-opt-in MOCK_RPM_RC=1 RPM_REPORT_TIMESTAMP_ONLY=1
grep -q 'Audit status: NOTICE' "$test_dir/timestamp-opt-in.stdout" || fail 'opted-in timestamp-only should be NOTICE'
pass 'RPM timestamp-only handling and opt-in notice'

# Known modified files can be excepted, but missing files cannot.
cat > "$test_dir/rpm-verify.out" <<'EOF'
S.5....T.    /usr/bin/expected-modification
missing     /usr/lib64/missing.so
EOF
printf '/usr/bin/expected-modification\n/usr/lib64/missing.so\n' > "$test_dir/exceptions.txt"
run_case exceptions MOCK_RPM_RC=1 EXCEPTIONS_FILE="$test_dir/exceptions.txt"
grep -q 'IGNORED.*expected-modification' "$test_dir/exceptions.stdout" || fail 'expected modification not ignored'
grep -q 'MISSING.*missing.so' "$test_dir/exceptions.stdout" || fail 'missing file was incorrectly ignored'
pass 'RPM modification exceptions never hide missing files'

# A failed RPM scan must never produce an all-clear or a false mismatch count.
printf 'rpm database unreadable\n' > "$test_dir/rpm-verify.out"
run_case rpm-failure MOCK_RPM_RC=2
grep -q 'Audit status: ERROR' "$test_dir/rpm-failure.stdout" || fail 'RPM failure not reported as ERROR'
grep -q 'INCOMPLETE' "$test_dir/rpm-failure.stdout" || fail 'RPM failure coverage not reported'
pass 'RPM database/command failure marked incomplete'

# Unknown verification flags and unreadable files must be incomplete.
printf '.......?.    /usr/bin/unreadable\n' > "$test_dir/rpm-verify.out"
run_case unreadable MOCK_RPM_RC=1
grep -q 'Audit status: ERROR' "$test_dir/unreadable.stdout" || fail 'unreadable RPM file not reported incomplete'
grep -q 'UNKNOWN.*unreadable' "$test_dir/unreadable.stdout" || fail 'unreadable file missing from report'
pass 'RPM unreadable-file review is incomplete'

# Unsupported systems remain explicitly rejected.
printf 'ID=fedora\n' > "$test_dir/unsupported-os-release"
run_case unsupported MOCK_RPM_RC=0 OS_RELEASE_FILE="$test_dir/unsupported-os-release"
[[ $(cat "$test_dir/unsupported.exit") == 78 ]] || fail 'unsupported distro not rejected'
pass 'unsupported package families rejected safely'

echo 'All RPM regression tests passed.'
