#!/usr/bin/env bash
# Shared helpers for the Loom scripts. Sourced, never executed.
# shellcheck shell=bash

# --- output ------------------------------------------------------------------

# C_CYN is used by the scripts that source this file, not by this file, so
# shellcheck cannot see a consumer for it when linting common.sh on its own.
# shellcheck disable=SC2034
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'; C_CYN=$'\033[36m'
else
    C_RESET=''; C_DIM=''; C_B=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_CYN=''
fi

LOOM_LOG="${LOOM_LOG:-/var/log/loom-setup.log}"

_log_raw() {
    [[ -n ${LOOM_LOG:-} ]] || return 0
    local dir; dir=$(dirname "$LOOM_LOG")
    [[ -d $dir ]] || mkdir -p "$dir" 2>/dev/null || return 0
    printf '%s %s\n' "$(date -Is)" "$*" >>"$LOOM_LOG" 2>/dev/null || true
}

step() { printf '\n%s==>%s %s%s%s\n' "$C_BLU$C_B" "$C_RESET" "$C_B" "$*" "$C_RESET"; _log_raw "STEP $*"; }
ok()   { printf '  %s+%s %s\n' "$C_GRN$C_B" "$C_RESET" "$*"; _log_raw "OK   $*"; }
note() { printf '  %s.%s %s\n' "$C_DIM" "$C_RESET" "$*"; _log_raw "NOTE $*"; }
warn() { printf '  %s!%s %s\n' "$C_YEL$C_B" "$C_RESET" "$*"; _log_raw "WARN $*"; }
bad()  { printf '  %sx%s %s\n' "$C_RED$C_B" "$C_RESET" "$*"; _log_raw "BAD  $*"; }

die() {
    printf '\n%serror:%s %s\n' "$C_RED$C_B" "$C_RESET" "$*" >&2
    _log_raw "DIE  $*"
    exit 1
}

# --- guards ------------------------------------------------------------------

need_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "this must run as root"
}

need_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
    done
}

have() { command -v "$1" >/dev/null 2>&1; }

is_arch() { [[ -f /etc/arch-release ]] || have pacman; }

# True while running inside an arch-chroot, where systemd is not up and
# `systemctl start` cannot work.
in_chroot() { [[ ! -d /run/systemd/system ]]; }

confirm() {
    local prompt="$1" default="${2:-n}" ans hint
    [[ $default == y ]] && hint="[Y/n]" || hint="[y/N]"
    read -r -p "$prompt $hint " ans || true
    ans="${ans:-$default}"
    [[ $ans == [yY] || $ans == yes ]]
}

# --- package lists -----------------------------------------------------------

# Read a package list, stripping comments and blank lines.
read_pkg_list() {
    local file="$1"
    [[ -r $file ]] || die "package list not found: $file"
    sed -e 's/#.*$//' -e 's/[[:space:]]*$//' -e '/^$/d' "$file"
}

# Packages in the list that pacman does not know about. A typo in a list would
# otherwise abort the whole transaction with a confusing message.
unknown_packages() {
    local -a pkgs=("$@") missing=()
    local p
    for p in "${pkgs[@]}"; do
        pacman -Si "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    printf '%s\n' "${missing[@]}"
}

# --- filesystem --------------------------------------------------------------

# Copy a rootfs tree over /, preserving modes. Uses rsync when available (it is
# in core.txt) and falls back to cp so that bootstrap works on a bare pacstrap.
install_tree() {
    local src="$1" dest="${2:-/}"
    [[ -d $src ]] || die "source tree not found: $src"
    if have rsync; then
        rsync -a --no-owner --no-group --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r "$src/" "$dest/"
    else
        cp -a "$src/." "$dest/"
    fi
}

# --- systemd -----------------------------------------------------------------

enable_units() {
    local u
    for u in "$@"; do
        if systemctl enable "$u" >/dev/null 2>&1; then
            ok "enabled $u"
        else
            warn "could not enable $u (is the package that provides it installed?)"
        fi
    done
}

# --- misc --------------------------------------------------------------------

loom_repo_root() {
    # Works whether the caller is scripts/foo.sh or an installed copy.
    local here
    here=$(cd -- "$(dirname -- "${BASH_SOURCE[1]:-$0}")" && pwd)
    if [[ -d $here/../packages ]]; then
        (cd -- "$here/.." && pwd)
    elif [[ -d $here/../../packages ]]; then
        (cd -- "$here/../.." && pwd)
    elif [[ -d /usr/share/loom-payload/packages ]]; then
        printf '/usr/share/loom-payload'
    else
        die "cannot locate the Loom payload (packages/, rootfs/)"
    fi
}
