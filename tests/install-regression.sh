#!/usr/bin/env bash
# Installer tests use only a private staging directory, even when run as root.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
mkdir -p "$test_dir/repo" "$test_dir/bin" "$test_dir/weekly" "$test_dir/daily" "$test_dir/local bin"
cp -- "$repo/system-integrity-audit" "$test_dir/repo/system-integrity-audit"
real_install=$(command -v install)
export INSTALL_TEST_ROOT=$test_dir INSTALL_TEST_REAL_INSTALL=$real_install
# Preserve real file operations but omit root ownership changes for rootless
# tests. The production installer still checks root and uses root:root.
cat > "$test_dir/bin/install" <<'MOCK'
#!/usr/bin/env bash
set -eu
args=()
while (( $# > 0 )); do
    case $1 in
        -o|-g) shift 2 ;;
        *) args+=("$1"); shift ;;
    esac
done
last=${args[${#args[@]}-1]}
[[ $last == "$INSTALL_TEST_ROOT/"* ]] || exit 98
exec "$INSTALL_TEST_REAL_INSTALL" "${args[@]}"
MOCK
chmod +x "$test_dir/bin/install"
# Rewrite only the copied installer's destinations, PATH and root guard.
# Verify those rewrites before executing it to prevent host installation.
awk -v root="$test_dir" '
    /^INSTALL_DIR=/ { print "INSTALL_DIR=\047" root "/local sbin\047"; dirs++; next }
    /^CRON_DIR=/ { print "CRON_DIR=\047" root "/weekly\047"; cron++; next }
    /^LEGACY_BIN_DIR=/ { print "LEGACY_BIN_DIR=\047" root "/local bin\047"; legacy++; next }
    /^DAILY_CRON_DIR=/ { print "DAILY_CRON_DIR=\047" root "/daily\047"; daily++; next }
    /^PATH=/ { print "PATH=\047" root "/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\047"; paths++; next }
    /^\(\( EUID == 0 \)\)/ { print ": # Test-only root guard bypass"; guards++; next }
    { print }
    END { if (dirs != 1 || cron != 1 || legacy != 1 || daily != 1 || paths != 1 || guards != 1) exit 1 }
' "$repo/install.sh" > "$test_dir/repo/install.sh" || fail 'installer staging rewrites'
grep -Fxq "INSTALL_DIR='$test_dir/local sbin'" "$test_dir/repo/install.sh" || fail 'unsafe staged destination'
grep -Fxq "CRON_DIR='$test_dir/weekly'" "$test_dir/repo/install.sh" || fail 'unsafe staged cron destination'
grep -Fxq "LEGACY_BIN_DIR='$test_dir/local bin'" "$test_dir/repo/install.sh" || fail 'unsafe staged legacy destination'
grep -Fxq "DAILY_CRON_DIR='$test_dir/daily'" "$test_dir/repo/install.sh" || fail 'unsafe staged daily cron destination'
installer="$test_dir/repo/install.sh"
target="$test_dir/local sbin/system-integrity-audit"
weekly="$test_dir/weekly/system-integrity-audit"
source_before=$(sha256sum "$test_dir/repo/system-integrity-audit")
run_installer() {
    bash "$installer" "$@" > "$test_dir/stdout" 2> "$test_dir/stderr"
}

bash -n "$repo/install.sh"
bash "$repo/install.sh" --help >/dev/null
if (( EUID != 0 )); then
    if bash "$repo/install.sh" --no-email > "$test_dir/root.stdout" 2> "$test_dir/root.stderr"; then
        fail 'production installer accepted non-root installation'
    fi
    grep -q 'Run this installer as root' "$test_dir/root.stderr" || fail 'root diagnostic absent'
fi
pass 'installer syntax, help and production root requirement'

run_installer --email 'admin+audit@example.org' || fail 'initial installation'
[[ -x $target && -L $weekly ]] || fail 'installed executable or symlink absent'
[[ $(readlink "$weekly") == "$target" ]] || fail 'weekly symlink target'
[[ $(stat -c %a "$target") == 755 ]] || fail 'installed executable mode'
grep -Fxq 'REPORT_TO="${REPORT_TO:-admin+audit@example.org}"' "$target" || fail 'installed email default'
bash -n "$target"
[[ $(sha256sum "$test_dir/repo/system-integrity-audit") == "$source_before" ]] || fail 'repository source modified'
[[ $(bash "$target" --version) == "$(bash "$repo/system-integrity-audit" --version)" ]] || fail 'installed version changed'
[[ ! -s $test_dir/stdout ]] || fail 'status output should use stderr'
if LC_ALL=C grep -q $'\033' "$test_dir/stderr"; then fail 'redirected output contains ANSI colors'; fi
pass 'personalized executable, weekly symlink, permissions and untouched repository source'

run_installer --email replacement@example.org || fail 'idempotent update'
grep -Fxq 'REPORT_TO="${REPORT_TO:-replacement@example.org}"' "$target" || fail 'updated email missing'
grep -q 'already configured' "$test_dir/stderr" || fail 'existing symlink not reused'
pass 'reinstallation updates installed email and reuses the weekly symlink'

installed_before=$(sha256sum "$target")
for address in '$(touch HACKED)@example.org' 'bad@example.org;echo' 'a b@example.org' 'bad@example.org,other@example.org' 'a@-bad.example.org' 'a..b@example.org' 'a.@example.org'; do
    if run_installer --email "$address"; then fail 'invalid email accepted'; fi
    [[ $(sha256sum "$target") == "$installed_before" ]] || fail 'invalid input changed installed script'
done
if run_installer </dev/null; then fail 'noninteractive install prompted without explicit selection'; fi
if run_installer --no-email --email admin@example.org; then fail 'conflicting options accepted'; fi
pass 'invalid input, shell syntax and ambiguous options cause no installation changes'

cp "$test_dir/repo/system-integrity-audit" "$test_dir/source-backup"
printf '\n%s\n' 'REPORT_TO="${REPORT_TO:-second@example.org}"' >> "$test_dir/repo/system-integrity-audit"
if run_installer --email admin@example.org; then fail 'ambiguous source defaults accepted'; fi
[[ $(sha256sum "$target") == "$installed_before" ]] || fail 'ambiguous source changed installed script'
cp "$test_dir/source-backup" "$test_dir/repo/system-integrity-audit"
pass 'ambiguous source recipient defaults are refused before replacing the installation'

rm "$weekly"
printf 'unrelated weekly job\n' > "$weekly"
if run_installer --email admin@example.org; then fail 'unrelated weekly file overwritten'; fi
[[ $(cat "$weekly") == 'unrelated weekly job' ]] || fail 'unrelated weekly file changed'
[[ $(sha256sum "$target") == "$installed_before" ]] || fail 'conflict changed installed script'
rm "$weekly"
ln -s "$test_dir/other" "$weekly"
if run_installer --email admin@example.org; then fail 'unrelated weekly symlink overwritten'; fi
[[ $(readlink "$weekly") == "$test_dir/other" ]] || fail 'unrelated weekly symlink changed'
rm "$weekly"
ln -s "$target" "$weekly"
pass 'unrelated weekly files and symlinks are preserved'

mv "$target" "$target.original"
ln -s "$target.original" "$target"
if run_installer --no-email; then fail 'symlinked installed target overwritten'; fi
[[ -L $target ]] || fail 'installed-target symlink changed'
rm "$target"
mv "$target.original" "$target"
pass 'symlinked executable target is refused'

run_installer --no-email || fail 'disable-email installation'
grep -Fxq 'REPORT_TO="${REPORT_TO:-username@email.address}"' "$target" || fail 'disabled email placeholder missing'
[[ $(sha256sum "$test_dir/repo/system-integrity-audit") == "$source_before" ]] || fail 'repository source modified after updates'
pass 'no-email option restores placeholder without modifying repository source'

# Exercise real terminal color detection and the actual interactive read.
if command -v script >/dev/null 2>&1; then
    run_installer --email retained@example.org
    printf '\n' | NO_COLOR=1 TERM=xterm script -q -e -c "bash '$installer'" /dev/null \
        > "$test_dir/prompt" 2>&1 || fail 'interactive default retention'
    grep -Fxq 'REPORT_TO="${REPORT_TO:-retained@example.org}"' "$target" || fail 'Enter did not retain installed email'
    if grep -q $'\033' "$test_dir/prompt"; then fail 'NO_COLOR ignored'; fi
    printf 'new@example.org\n' | env -u NO_COLOR TERM=xterm script -q -e -c "bash '$installer'" /dev/null \
        > "$test_dir/colors" 2>&1 || fail 'interactive email selection'
    grep -Fxq 'REPORT_TO="${REPORT_TO:-new@example.org}"' "$target" || fail 'interactive address missing'
    grep -Fq $'\033[33m[INSTALLING]' "$test_dir/colors" || fail 'installation warning-yellow styling absent'
    grep -Fq $'\033[32m[OK]' "$test_dir/colors" || fail 'successful-stage green styling absent'
    printf 'none\n' | NO_COLOR=1 TERM=xterm script -q -e -c "bash '$installer'" /dev/null \
        > "$test_dir/prompt-none" 2>&1 || fail 'interactive email disable'
    grep -Fxq 'REPORT_TO="${REPORT_TO:-username@email.address}"' "$target" || fail 'interactive none did not disable email'
    pass 'interactive email/default/none and terminal colors honor NO_COLOR'
else
    printf 'SKIP: interactive/color tests (script command unavailable)\n'
fi

legacy_bin="$test_dir/local bin/debsums-audit"
legacy_sbin="$test_dir/local sbin/debsums-audit"
printf 'old bin copy\n' > "$legacy_bin"
printf 'old sbin copy\n' > "$legacy_sbin"
ln -s "$legacy_bin" "$test_dir/daily/debsums-audit"
ln -s '../local bin/./debsums-audit' "$test_dir/daily/custom-relative"
ln -s "$legacy_sbin" "$test_dir/weekly/custom-absolute"
ln -s './custom-absolute' "$test_dir/weekly/chain"
ln -s "$legacy_bin" "$test_dir/daily/.legacy-hidden"
printf 'unrelated job\n' > "$test_dir/weekly/unrelated-job"
ln -s "$target" "$test_dir/daily/unrelated-new-audit"
run_installer --no-email || fail 'legacy migration'
for path in "$legacy_bin" "$legacy_sbin" "$test_dir/daily/debsums-audit" \
    "$test_dir/daily/custom-relative" "$test_dir/weekly/custom-absolute" \
    "$test_dir/weekly/chain" "$test_dir/daily/.legacy-hidden"; do
    [[ ! -e $path && ! -L $path ]] || fail "legacy path retained: $path"
done
[[ -x $target && $(readlink "$weekly") == "$target" ]] || fail 'legacy migration damaged new installation'
[[ $(cat "$test_dir/weekly/unrelated-job") == 'unrelated job' ]] || fail 'unrelated cron file changed'
[[ $(readlink "$test_dir/daily/unrelated-new-audit") == "$target" ]] || fail 'unrelated cron symlink changed'
grep -q 'Removed legacy script:' "$test_dir/stderr" || fail 'script removals not reported'
grep -q 'Removed legacy cron symlink:' "$test_dir/stderr" || fail 'cron removals not reported'
pass 'legacy copies and absolute, relative, chained and hidden cron aliases are removed'

ln -s "$legacy_bin" "$test_dir/daily/dangling"
printf 'outside sentinel\n' > "$test_dir/sentinel"
ln -s "$test_dir/sentinel" "$test_dir/weekly/debsums-audit"
run_installer --no-email || fail 'dangling and named legacy links'
[[ ! -L $test_dir/daily/dangling && ! -L $test_dir/weekly/debsums-audit ]] || fail 'dangling or named legacy link retained'
[[ $(cat "$test_dir/sentinel") == 'outside sentinel' ]] || fail 'legacy cron symlink target deleted'
pass 'dangling and legacy-named cron symlinks are removed without deleting outside targets'

ln -s "$test_dir/sentinel" "$legacy_bin"
ln -s "$target" "$legacy_sbin"
ln -s "$legacy_bin" "$test_dir/daily/through-old-bin"
ln -s "$legacy_sbin" "$test_dir/weekly/through-old-sbin"
run_installer --no-email || fail 'legacy executable symlink migration'
[[ ! -L $legacy_bin && ! -L $legacy_sbin ]] || fail 'legacy executable symlink retained'
[[ ! -L $test_dir/daily/through-old-bin && ! -L $test_dir/weekly/through-old-sbin ]] || fail 'cron alias through old executable symlink retained'
[[ $(cat "$test_dir/sentinel") == 'outside sentinel' && -x $target ]] || fail 'legacy symlink migration removed real target'
[[ $(readlink "$weekly") == "$target" ]] || fail 'new weekly link removed through old alias'
pass 'legacy executable symlinks are unlinked while new audit and external targets survive'

printf 'old installation\n' > "$legacy_bin"
ln -s "$legacy_bin" "$test_dir/daily/debsums-audit"
if run_installer --email 'invalid address'; then fail 'invalid email accepted during migration'; fi
[[ -f $legacy_bin && -L $test_dir/daily/debsums-audit ]] || fail 'input failure removed legacy installation'
rm "$weekly"
printf 'conflicting job\n' > "$weekly"
if run_installer --no-email; then fail 'conflicting weekly entry accepted during migration'; fi
[[ -f $legacy_bin && -L $test_dir/daily/debsums-audit ]] || fail 'failed installation removed legacy installation'
rm "$weekly"
ln -s "$target" "$weekly"
run_installer --no-email || fail 'successful migration after conflict resolved'
pass 'legacy installation survives failed validation or new-schedule conflict'

printf 'manual daily job\n' > "$test_dir/daily/debsums-audit"
mkdir "$legacy_bin"
run_installer --no-email || fail 'non-file legacy path handling'
[[ $(cat "$test_dir/daily/debsums-audit") == 'manual daily job' ]] || fail 'regular cron entry deleted'
[[ -d $legacy_bin ]] || fail 'legacy-named directory deleted'
grep -q 'Keeping non-symlink cron entry' "$test_dir/stderr" || fail 'regular cron entry not reported'
grep -q 'Keeping non-file legacy path' "$test_dir/stderr" || fail 'non-file legacy path not reported'
pass 'regular cron files and non-file legacy paths are retained with warnings'

printf 'All installer regression tests passed.\n'
