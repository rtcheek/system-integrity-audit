#!/usr/bin/env bash
# Install system-integrity-audit with a local report address and weekly entry.
set -u
set -o pipefail
umask 077
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
export LC_ALL=C

INSTALLER_VERSION='2.0.2'
INSTALL_DIR='/usr/local/sbin'
CRON_DIR='/etc/cron.weekly'
LEGACY_BIN_DIR='/usr/local/bin'
DAILY_CRON_DIR='/etc/cron.daily'
PLACEHOLDER='username@email.address'
work_dir=''
staged_install=''
color_reset='' color_bold='' color_cyan='' color_green='' color_yellow='' color_red=''
if [[ -t 2 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then
    color_reset=$'\033[0m'; color_bold=$'\033[1m'; color_cyan=$'\033[36m'
    color_green=$'\033[32m'; color_yellow=$'\033[33m'; color_red=$'\033[31m'
fi
status() {
    local marker=$1 text=$2 color=$color_cyan
    case "$marker" in
        OK) color=$color_green ;;
        WARN|INSTALLING) color=$color_yellow ;;
        FAIL) color=$color_red ;;
    esac
    printf '%s%s[%s]%s %s%s%s\n' "$color_bold" "$color" "$marker" \
        "$color_reset" "$color" "$text" "$color_reset" >&2
}
die() { status FAIL "$1"; exit 1; }
cleanup() {
    [[ -z $staged_install ]] || rm -f -- "$staged_install"
    [[ -z $work_dir ]] || rm -rf -- "$work_dir"
    return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
# Follow only cron symlink chains, comparing each hop before dereferencing
# the old executable itself. This also works for dangling legacy links and
# avoids treating a legacy alias of the NEW audit as a reason to remove it.
links_to_legacy_audit() {
    local cursor=$1 raw parent leaf hop
    for ((hop=0; hop<40; hop++)); do
        [[ -L $cursor ]] || return 1
        raw=$(readlink -- "$cursor") || return 1
        [[ $raw == /* ]] || raw="${cursor%/*}/$raw"
        parent=${raw%/*}; leaf=${raw##*/}
        parent=$(readlink -m -- "$parent") || return 1
        cursor="${parent%/}/$leaf"
        [[ $cursor != "$LEGACY_BIN_DIR/debsums-audit" &&
           $cursor != "$INSTALL_DIR/debsums-audit" ]] || return 0
    done
    return 1
}
remove_legacy_installation() {
    local dir entry old removed=0
    local -a old_links=()
    status NOTICE 'Checking for legacy debsums-audit installations and cron symlinks'
    # Collect links before removing any, so aliases through other cron links
    # are still discoverable. Include hidden entries without following dirs.
    for dir in "$DAILY_CRON_DIR" "$CRON_DIR"; do
        [[ -d $dir ]] || continue
        for entry in "$dir/"* "$dir/".[!.]* "$dir/"..?*; do
            if [[ -L $entry ]]; then
                if [[ ${entry##*/} == debsums-audit ]] || links_to_legacy_audit "$entry"; then
                    old_links+=("$entry")
                fi
            elif [[ ${entry##*/} == debsums-audit && -e $entry ]]; then
                status WARN "Keeping non-symlink cron entry for manual review: $entry"
            fi
        done
    done
    for entry in "${old_links[@]}"; do
        rm -f -- "$entry" || die "New installation is ready, but could not remove legacy cron symlink: $entry"
        status OK "Removed legacy cron symlink: $entry"
        removed=$((removed + 1))
    done
    for old in "$LEGACY_BIN_DIR/debsums-audit" "$INSTALL_DIR/debsums-audit"; do
        if [[ -L $old || -f $old ]]; then
            rm -f -- "$old" || die "New installation is ready, but could not remove legacy script: $old"
            status OK "Removed legacy script: $old"
            removed=$((removed + 1))
        elif [[ -e $old ]]; then
            status WARN "Keeping non-file legacy path for manual review: $old"
        fi
    done
    (( removed != 0 )) || status OK 'No legacy debsums-audit files or cron symlinks to remove'
    return 0
}

usage() {
    cat <<'USAGE'
Usage: sudo ./install.sh [--email ADDRESS | --no-email]

Prompts for a report email address, installs a personalized copy into
/usr/local/sbin/system-integrity-audit, and creates the weekly symlink
/etc/cron.weekly/system-integrity-audit. After successful installation,
removes legacy debsums-audit files in /usr/local/bin and /usr/local/sbin
and their daily/weekly cron symlinks. Does not run the audit.

An existing installed default address is offered again during upgrades.
Press Enter to retain the offered value, or enter none to disable email.
Use --email ADDRESS or --no-email for a noninteractive installation.
The repository script and all other audit defaults are preserved.
USAGE
}
valid_email() {
    # A deliberately simple plain-address format, safe for a shell default.
    # No display names, lists, quoted local parts, whitespace or shell syntax.
    local pattern='^[A-Za-z0-9._%+-]+@[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$'
    local localpart=${1%@*} domain=${1##*@}
    [[ $1 =~ $pattern && $1 != *..* && $localpart != .* && $localpart != *. &&
       $domain != *.-* && $domain != *-.* && ${#1} -le 254 ]]
}
read_installed_email() {
    local line pattern='^REPORT_TO="\$\{REPORT_TO:-([^}]*)\}"$'
    local literal='^REPORT_TO="([^"]*)"$'
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line =~ $pattern || $line =~ $literal ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    done < "$1"
    return 1
}

selection='' supplied=0
while (( $# > 0 )); do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --email)
            (( supplied == 0 && $# >= 2 )) || die 'Use --email ADDRESS or --no-email once.'
            selection=$2; supplied=1; shift 2 ;;
        --no-email)
            (( supplied == 0 )) || die 'Use --email ADDRESS or --no-email once.'
            selection=$PLACEHOLDER; supplied=1; shift ;;
        *) usage >&2; die "Unknown option: $1" ;;
    esac
done
printf '%s%sinstall.sh%s %s%s%s (system-integrity-audit installer)\n' \
    "$color_bold" "$color_cyan" "$color_reset" "$color_green" "$INSTALLER_VERSION" "$color_reset" >&2
(( EUID == 0 )) || die 'Run this installer as root: sudo ./install.sh'
for tool in awk bash dirname install ln mktemp mv readlink rm; do
    command -v "$tool" >/dev/null 2>&1 || die "Required command missing: $tool"
done
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || die 'Cannot locate the repository directory.'
source_script="$source_dir/system-integrity-audit"
target="$INSTALL_DIR/system-integrity-audit"
weekly="$CRON_DIR/system-integrity-audit"
[[ -f $source_script && -r $source_script ]] || die "Audit script not found: $source_script"
bash -n "$source_script" || die 'Repository audit script failed Bash syntax verification.'
[[ -d $CRON_DIR ]] || die "Weekly cron directory is missing: $CRON_DIR. Configure cron/anacron first."
[[ ! -L $target && ( ! -e $target || -f $target ) ]] || die "Installed target is a symlink or non-regular file: $target"
if [[ -e $weekly || -L $weekly ]]; then
    [[ -L $weekly && $(readlink -- "$weekly") == "$target" ]] || \
        die "Weekly entry already exists and is not this installer's symlink: $weekly"
fi
status OK 'Checking installation prerequisites'

suggested=$PLACEHOLDER
if [[ -f $target ]]; then
    old_email=$(read_installed_email "$target" || true)
    if [[ -z $old_email || $old_email == "$PLACEHOLDER" ]] || valid_email "$old_email"; then
        suggested=${old_email:-$PLACEHOLDER}
    else
        status WARN 'Could not reuse the installed email setting; please enter it again.'
    fi
fi
if (( supplied == 0 )); then
    [[ -t 0 ]] || die 'No interactive terminal. Use --email ADDRESS or --no-email.'
    display=$suggested
    [[ $display != "$PLACEHOLDER" ]] || display=none
    while :; do
        printf '%sReport email [%s] (none disables email): %s' "$color_cyan" "$display" "$color_reset" >&2
        IFS= read -r answer || die 'No email choice received; nothing installed.'
        selection=${answer:-$suggested}
        [[ $selection != none ]] || selection=$PLACEHOLDER
        [[ $selection == "$PLACEHOLDER" ]] || valid_email "$selection" || {
            status WARN 'Enter one plain email address, such as admin@example.org, or none.'
            continue
        }
        break
    done
fi
[[ $selection == "$PLACEHOLDER" ]] || valid_email "$selection" || die 'Invalid email address; enter one plain address or use --no-email.'
if [[ $selection == "$PLACEHOLDER" ]]; then
    status NOTICE 'Email reporting disabled'
else
    status NOTICE "Default report email: $selection"
    command -v sendmail >/dev/null 2>&1 || status WARN 'No sendmail-compatible mailer found; configure one before using email reports.'
fi

work_dir=$(mktemp -d -t system-integrity-audit-install.XXXXXXXX) || die 'Cannot create installation workspace.'
# Replace only the default recipient in the installed copy. Validation above
# excludes shell interpolation characters; awk avoids sed replacement escaping.
awk -v email="$selection" '
    /^REPORT_TO="\$\{REPORT_TO:-[^}]*\}"$/ {
        print "REPORT_TO=\"${REPORT_TO:-" email "}\""
        count++
        next
    }
    { print }
    END { if (count != 1) exit 1 }
' "$source_script" > "$work_dir/audit" || die 'Expected exactly one REPORT_TO default in the repository script.'
bash -n "$work_dir/audit" || die 'Personalized audit script failed Bash syntax verification.'
status INSTALLING "$target"
install -d -o root -g root -m 0755 -- "$INSTALL_DIR" || die 'Cannot prepare the installation directory.'
staged_install=$(mktemp "$INSTALL_DIR/.system-integrity-audit.XXXXXXXX") || die 'Cannot stage the installed script.'
install -o root -g root -m 0755 -- "$work_dir/audit" "$staged_install" || die 'Cannot prepare the root-owned executable.'
mv -fT -- "$staged_install" "$target" || die 'Cannot activate the installed script.'
staged_install=''
status OK "Installed $target (root:root, mode 0755)"
if [[ -L $weekly ]]; then
    status OK "Weekly symlink already configured: $weekly"
else
    ln -s -- "$target" "$weekly" || die "Script installed, but weekly symlink creation failed: $weekly"
    status OK "Created weekly symlink: $weekly"
fi
remove_legacy_installation
status NOTICE 'Weekly execution uses the existing cron/anacron schedule. The audit was not run.'
status NOTICE 'Other audit defaults are unchanged; XFS check-only scrubbing remains opt-in.'
