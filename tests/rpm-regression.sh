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
    case ${3:-} in
        /etc/modprobe.d/sctp-blacklist.conf)
            printf 'kernel-modules-extra-5.14.0-1.x86_64\n'
            printf 'kernel-modules-extra-5.14.0-2.x86_64\n'
            printf 'kernel-modules-extra-5.14.0-3.x86_64\n'
            ;;
        /run/gluster) printf 'glusterfs-6.0.x86_64\n' ;;
        /run/runtime-file) printf 'runtimepkg-1.2.x86_64\n' ;;
        /run/badmode) printf 'badpkg-1.2.x86_64\n' ;;
        *) printf 'samplepkg-1.2-3.x86_64\n' ;;
    esac
    exit 0
fi
if [[ ${1:-} == -q && ${2:-} == --dump && ${3:-} == -- ]]; then
    case ${4:-} in
        glusterfs-*)
            printf '/run/gluster 0 1652447070 %064d 040775 gluster gluster 0 0 0 X\n' 0
            ;;
        runtimepkg-*)
            printf '/run/runtime-file 123 1652447070 %064d 0100644 root root 0 0 0 X\n' 0
            ;;
        badpkg-*)
            printf '/run/badmode 0 1652447070 %064d BADMODE root root 0 0 0 X\n' 0
            ;;
    esac
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
    "MOCK_DIR=$test_dir" "AUTO_INSTALL_REQUIREMENTS=0" "AUTO_ENABLE_PERSISTENT_JOURNAL=0"
    "KERNEL_LOG_CHECK_ENABLED=0" "SMART_CHECK_ENABLED=0" "FILESYSTEM_CHECKS_ENABLED=0"
    "PROGRESS_OUTPUT=never" "TERMINAL_OUTPUT=always" "STATEFUL_NOTIFICATIONS=0"
    "EXCEPTIONS_FILE=$test_dir/nonexistent-exceptions"
    "MISSING_EXCEPTIONS_FILE=$test_dir/nonexistent-missing-exceptions"
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

# Missing runtime directories are only NOTICE if the owning RPM explicitly
# declares the exact path as a directory (040755/040775), never just by path.
cat > "$test_dir/rpm-verify.out" <<'EOF'
missing     /run/gluster
missing     /run/runtime-file
missing     /run/badmode
missing     /run/unverified-dir
EOF
run_case runtime-type MOCK_RPM_RC=1
[[ $(cat "$test_dir/runtime-type.exit") == 0 ]] || fail 'runtime classification should not be an execution error'
grep -q 'RUNTIME.* /run/gluster' "$test_dir/runtime-type.stdout" || fail 'verified /run directory should be NOTICE'
grep -q 'RPM runtime directories absent: 1 (NOTICE)' "$test_dir/runtime-type.stdout" || fail 'runtime notice count inaccurate'
grep -q 'MISSING.* /run/runtime-file' "$test_dir/runtime-type.stdout" || fail 'missing runtime regular file must ALERT'
grep -q 'MISSING.* /run/badmode' "$test_dir/runtime-type.stdout" || fail 'bad RPM metadata must not be trusted'
grep -q 'MISSING.* /run/unverified-dir' "$test_dir/runtime-type.stdout" || fail 'unverified /run path must ALERT'
pass 'RPM-verified missing runtime directory is NOTICE; runtime files remain ALERT'

printf 'missing     /run/gluster\n' > "$test_dir/rpm-verify.out"
run_case runtime-only MOCK_RPM_RC=1
grep -q 'Audit status: NOTICE' "$test_dir/runtime-only.stdout" || fail 'only missing RPM runtime dir should not alert'
grep -q 'Missing package files: *0' "$test_dir/runtime-only.stdout" || fail 'runtime dir counted as missing regular file'
pass 'missing RPM-owned runtime directory alone does not produce ALERT'

# Separate, exact-path approved missing-file list; unlike modified-file
# glob exceptions it can explicitly accept an altered local SGX install.
sgx_file=/var/opt/aesmd/data/white_list_cert_to_be_verify.bin
cat > "$test_dir/rpm-verify.out" <<'EOF'
missing     /var/opt/aesmd/data/white_list_cert_to_be_verify.bin
missing     /usr/lib64/unrelated-missing.so
EOF
printf '%s\n' "$sgx_file" > "$test_dir/approved-missing.txt"
run_case approved-missing MOCK_RPM_RC=1 MISSING_EXCEPTIONS_FILE="$test_dir/approved-missing.txt"
grep -q 'APPROVED.*white_list_cert_to_be_verify.bin' "$test_dir/approved-missing.stdout" || fail 'SGX approved missing path not displayed'
grep -q 'Approved missing files ignored: 1' "$test_dir/approved-missing.stdout" || fail 'approved missing count inaccurate'
grep -q 'MISSING.*unrelated-missing.so' "$test_dir/approved-missing.stdout" || fail 'unrelated missing file hidden by exception'
! grep -q '^MISSING.*white_list_cert_to_be_verify.bin' "$test_dir/approved-missing.stdout" || fail 'approved SGX path still alerts'
pass 'explicitly approved missing SGX file ignored; unrelated missing remains ALERT'

printf 'missing     /var/opt/aesmd/data/white_list_cert_to_be_verify.bin\n' > "$test_dir/rpm-verify.out"
run_case approved-only MOCK_RPM_RC=1 MISSING_EXCEPTIONS_FILE="$test_dir/approved-missing.txt"
grep -q 'Audit status: TEST/OK' "$test_dir/approved-only.stdout" || fail 'approved-only missing file should be nonalert'
grep -q 'APPROVED.*white_list_cert_to_be_verify.bin' "$test_dir/approved-only.stdout" || fail 'approved missing file not visible in report'
pass 'only approved missing file produces no warning/alert'

# Missing-file exceptions never inherit broad modifications globs.
printf '/var/opt/aesmd/*\n' > "$test_dir/approved-missing-glob.txt"
run_case invalid-missing-exceptions MOCK_RPM_RC=1 MISSING_EXCEPTIONS_FILE="$test_dir/approved-missing-glob.txt"
[[ $(cat "$test_dir/invalid-missing-exceptions.exit") == 65 ]] || fail 'glob in exact missing exceptions file must fail preflight'
grep -q 'invalid exact missing-file path' "$test_dir/invalid-missing-exceptions.stderr" || fail 'invalid missing exception lacks explanation'
pass 'missing-file exceptions reject glob patterns'

# Multiple owners for the same file are comma-separated, not literal \n.
printf 'S.5...... c /etc/modprobe.d/sctp-blacklist.conf\n' > "$test_dir/rpm-verify.out"
run_case multiple-owners MOCK_RPM_RC=1
grep -q 'kernel-modules-extra-5.14.0-1.x86_64, kernel-modules-extra-5.14.0-2.x86_64, kernel-modules-extra-5.14.0-3.x86_64' "$test_dir/multiple-owners.stdout" || fail 'multiple RPM owners were not joined cleanly'
! grep -Fq '\n' "$test_dir/multiple-owners.stdout" || fail 'literal newline escaped into package-owner field'
pass 'multiple RPM package owners formatted without literal escaped newlines'

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
