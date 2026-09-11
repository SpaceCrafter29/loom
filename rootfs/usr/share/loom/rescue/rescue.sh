#!/usr/bin/env bash
# Loom, by SpaceCrafter29 -- https://github.com/SpaceCrafter29/loom
# Loom rescue shell -- runs inside the rescue initramfs, before root is mounted.
#
# Everything here assumes the installed system may be unbootable or unreadable.
# It therefore never sources anything off the root filesystem, never assumes
# snapper exists (it reads snapper's on-disk layout directly), and confirms
# before every destructive step.

set -u
set -o pipefail

MAPPER_NAME="loomrescue"
MNT="/loom"
TOP_SUBVOL_ID=5
ROOT_SUBVOL="@"
SNAP_SUBVOL="@snapshots"

ROOT_DEV=""
MOUNTED=0

export TERM="${TERM:-linux}"

C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'
C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
C_BLU=$'\033[34m'; C_CYN=$'\033[36m'

say()  { printf '%s\n' "$*"; }
info() { printf '%s==>%s %s\n' "$C_BLU$C_B" "$C_RESET" "$*"; }
ok()   { printf '%s ok%s  %s\n' "$C_GRN$C_B" "$C_RESET" "$*"; }
warn() { printf '%s!! %s  %s\n' "$C_YEL$C_B" "$C_RESET" "$*"; }
err()  { printf '%sERR%s  %s\n' "$C_RED$C_B" "$C_RESET" "$*" >&2; }
rule() { printf '%s%s%s\n' "$C_DIM" "----------------------------------------------------------------------" "$C_RESET"; }

pause() { printf '\n%spress enter to continue%s ' "$C_DIM" "$C_RESET"; read -r _ || true; }

# ask <prompt> <default> -> echoes the answer on stdout, prompts on stderr
ask() {
    local prompt="$1" def="${2-}" ans=""
    if [[ -n $def ]]; then
        printf '%s [%s]: ' "$prompt" "$def" >&2
    else
        printf '%s: ' "$prompt" >&2
    fi
    read -r ans || true
    printf '%s' "${ans:-$def}"
}

# Destructive steps require a typed "yes", never a single keystroke.
confirm() {
    local ans
    ans=$(ask "$1 (type 'yes')" "")
    [[ $ans == yes ]]
}

banner() {
    clear 2>/dev/null || true
    say ""
    say "  ${C_CYN}${C_B}L O O M${C_RESET}  ${C_DIM}rescue${C_RESET}"
    say "  ${C_DIM}early userspace -- the installed system is not mounted${C_RESET}"
    rule
}

# --- discovery ---------------------------------------------------------------

luks_devices()  { blkid -t TYPE=crypto_LUKS -o device 2>/dev/null | sort; }
btrfs_devices() { blkid -t TYPE=btrfs -o device 2>/dev/null | sort; }

wait_for_devices() {
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if [[ -n $(luks_devices) || -n $(btrfs_devices) ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# pick_from_list <title> <item...> -> echoes chosen item, empty on abort
pick_from_list() {
    local title="$1"; shift
    local -a items=("$@")
    local n=${#items[@]} i choice

    (( n == 0 )) && { printf ''; return 1; }
    if (( n == 1 )); then printf '%s' "${items[0]}"; return 0; fi

    say "$title" >&2
    for (( i = 0; i < n; i++ )); do
        printf '  %2d) %s\n' "$((i + 1))" "${items[i]}" >&2
    done
    choice=$(ask "choice (blank to abort)" "")
    [[ -z $choice ]] && { printf ''; return 1; }
    if ! [[ $choice =~ ^[0-9]+$ ]] || (( choice < 1 || choice > n )); then
        err "not a valid choice"
        printf ''
        return 1
    fi
    printf '%s' "${items[choice - 1]}"
}

# --- unlock + mount ----------------------------------------------------------

unlock_root() {
    ROOT_DEV=""

    local -a luks=()
    mapfile -t luks < <(luks_devices)

    if (( ${#luks[@]} > 0 )); then
        local dev try
        dev=$(pick_from_list "Encrypted volumes found:" "${luks[@]}") || return 1
        [[ -z $dev ]] && return 1

        if [[ -e /dev/mapper/$MAPPER_NAME ]]; then
            ROOT_DEV="/dev/mapper/$MAPPER_NAME"
            ok "already unlocked: $ROOT_DEV"
            return 0
        fi

        info "unlocking $dev"
        for try in 1 2 3; do
            if cryptsetup open "$dev" "$MAPPER_NAME"; then
                ROOT_DEV="/dev/mapper/$MAPPER_NAME"
                ok "unlocked as $ROOT_DEV"
                return 0
            fi
            warn "wrong passphrase or locked header (attempt $try of 3)"
        done
        err "could not unlock $dev"
        return 1
    fi

    # No LUKS container: a plain, unencrypted Btrfs install.
    local -a bt=()
    mapfile -t bt < <(btrfs_devices)
    if (( ${#bt[@]} == 0 )); then
        err "no LUKS or Btrfs volume visible -- is the storage controller module missing?"
        return 1
    fi
    ROOT_DEV=$(pick_from_list "Btrfs volumes found:" "${bt[@]}") || return 1
    [[ -z $ROOT_DEV ]] && return 1
    return 0
}

# Mount the Btrfs top level (subvolid=5), where @ and @snapshots both live.
mount_top() {
    mkdir -p "$MNT"
    if findmnt -rn "$MNT" >/dev/null 2>&1; then
        return 0
    fi
    if ! mount -t btrfs -o "subvolid=$TOP_SUBVOL_ID,rw" "$ROOT_DEV" "$MNT"; then
        err "could not mount $ROOT_DEV at $MNT"
        return 1
    fi
    ok "Btrfs top level mounted at $MNT"
    return 0
}

# --- snapshots ---------------------------------------------------------------

# Snapper's layout is <top>/@snapshots/<N>/snapshot for the read-only snapshot
# and <top>/@snapshots/<N>/info.xml for its metadata. We read the XML with sed
# rather than depend on snapper or an XML parser being in the initramfs.
xml_field() {
    local file="$1" tag="$2"
    sed -n "s:.*<$tag>\(.*\)</$tag>.*:\1:p" "$file" 2>/dev/null | head -n1
}

snapshot_nums() {
    local d
    for d in "$MNT/$SNAP_SUBVOL"/*; do
        [[ -d $d/snapshot ]] || continue
        basename "$d"
    done | sort -n
}

list_snapshots() {
    local -a nums=()
    mapfile -t nums < <(snapshot_nums)
    if (( ${#nums[@]} == 0 )); then
        warn "no snapshots found under $MNT/$SNAP_SUBVOL"
        return 1
    fi

    printf '%s%-6s %-20s %-10s %s%s\n' "$C_B" "#" "date" "type" "description" "$C_RESET"
    local n meta date type desc
    for n in "${nums[@]}"; do
        meta="$MNT/$SNAP_SUBVOL/$n/info.xml"
        date=$(xml_field "$meta" date)
        type=$(xml_field "$meta" type)
        desc=$(xml_field "$meta" description)
        printf '%-6s %-20s %-10s %s\n' "$n" "${date:-?}" "${type:-?}" "${desc:-}"
    done
    return 0
}

rollback_to() {
    local n="$1"
    local src="$MNT/$SNAP_SUBVOL/$n/snapshot"
    local live="$MNT/$ROOT_SUBVOL"
    local stamp broken

    if [[ ! -d $src ]]; then
        err "snapshot $n does not exist"
        return 1
    fi

    stamp=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo manual)
    broken="$MNT/${ROOT_SUBVOL}.broken-$stamp"

    rule
    say "About to roll the root subvolume back to snapshot ${C_B}$n${C_RESET}:"
    say "  ${C_DIM}$src${C_RESET}"
    say ""
    say "  1. ${C_YEL}$live${C_RESET} is renamed to ${C_YEL}$broken${C_RESET}"
    say "     (kept, not deleted -- remove it later with 'btrfs subvolume delete')"
    say "  2. a new writable ${C_YEL}$live${C_RESET} is created from snapshot $n"
    say ""
    say "  ${C_DIM}/home is a separate subvolume and is NOT touched.${C_RESET}"
    say "  ${C_DIM}The kernel images on the ESP are NOT touched either. If this${C_RESET}"
    say "  ${C_DIM}snapshot predates a kernel upgrade, chroot in afterwards and${C_RESET}"
    say "  ${C_DIM}run 'loomctl rebuild-boot'.${C_RESET}"
    rule

    confirm "Proceed?" || { warn "aborted"; return 1; }

    if [[ -e $broken ]]; then
        err "$broken already exists; refusing to clobber it"
        return 1
    fi

    info "renaming the current root aside"
    if ! mv -- "$live" "$broken"; then
        err "rename failed; nothing has changed"
        return 1
    fi

    info "creating a writable root from snapshot $n"
    if ! btrfs subvolume snapshot "$src" "$live"; then
        err "snapshot creation failed -- putting the previous root back"
        mv -- "$broken" "$live" || err "could not restore! your old root is at $broken"
        return 1
    fi

    ok "rolled back to snapshot $n"
    say ""
    say "Reboot now (option 6). If the kernel and userland no longer match, boot"
    say "Loom Rescue again, choose chroot, and run: loomctl rebuild-boot"
    return 0
}

# --- chroot ------------------------------------------------------------------

enter_chroot() {
    local target="$MNT/$ROOT_SUBVOL" esp rc
    if [[ ! -d $target ]]; then
        err "$target does not exist; nothing to chroot into"
        return 1
    fi

    info "binding kernel filesystems"
    mkdir -p "$target"/dev "$target"/proc "$target"/sys "$target"/run
    mount --bind /dev  "$target/dev"  2>/dev/null || warn "bind /dev failed"
    mount --bind /proc "$target/proc" 2>/dev/null || warn "bind /proc failed"
    mount --bind /sys  "$target/sys"  2>/dev/null || warn "bind /sys failed"
    mount --bind /run  "$target/run"  2>/dev/null || true

    # /home lives in its own subvolume; without this, a chroot looks like a
    # machine whose users all lost their home directories.
    if [[ -d $MNT/@home ]]; then
        mkdir -p "$target/home"
        mount -o "subvol=@home" "$ROOT_DEV" "$target/home" 2>/dev/null || true
    fi

    # The ESP lives outside the root subvolume, so mount it too -- otherwise
    # mkinitcpio inside the chroot writes its UKI into thin air.
    esp=$(blkid -t TYPE=vfat -o device 2>/dev/null | head -n1)
    if [[ -n $esp ]]; then
        mkdir -p "$target/efi"
        if mount "$esp" "$target/efi" 2>/dev/null; then
            ok "ESP $esp mounted at /efi inside the chroot"
        else
            warn "could not mount ESP $esp; boot files will not be writable"
        fi
    fi

    rule
    say "Entering the installed system. Useful commands in there:"
    say "  ${C_B}loomctl rebuild-boot${C_RESET}   regenerate and re-sign the kernel images"
    say "  ${C_B}pacman -Syu${C_RESET}            finish an interrupted upgrade"
    say "  ${C_B}pacman -U /var/cache/pacman/pkg/<file>${C_RESET}   downgrade one package"
    say "  ${C_B}exit${C_RESET}                   come back to this menu"
    rule
    pause

    chroot "$target" /usr/bin/bash --login
    rc=$?

    info "leaving chroot (exit $rc); unmounting"
    umount "$target/efi" 2>/dev/null || true
    umount "$target/home" 2>/dev/null || true
    umount -l "$target/dev" "$target/proc" "$target/sys" "$target/run" 2>/dev/null || true
    return 0
}

# --- teardown ----------------------------------------------------------------

cleanup() {
    info "unmounting"
    umount -R "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
    if [[ -e /dev/mapper/$MAPPER_NAME ]]; then
        cryptsetup close "$MAPPER_NAME" 2>/dev/null || true
    fi
    return 0
}

do_reboot() {
    cleanup
    sync
    info "rebooting"
    reboot -f 2>/dev/null || printf 'b' > /proc/sysrq-trigger
    sleep 10
}

do_poweroff() {
    cleanup
    sync
    info "powering off"
    poweroff -f 2>/dev/null || printf 'o' > /proc/sysrq-trigger
    sleep 10
}

# --- main --------------------------------------------------------------------

main() {
    [[ -r /usr/lib/loom/palette ]] && setvtrgb /usr/lib/loom/palette 2>/dev/null

    banner
    info "looking for disks"
    if ! wait_for_devices; then
        warn "no LUKS or Btrfs volume appeared after 10s"
    fi

    local choice n
    while :; do
        say ""
        rule
        if (( MOUNTED )); then
            say " ${C_GRN}root filesystem mounted${C_RESET} ${C_DIM}($ROOT_DEV at $MNT)${C_RESET}"
        else
            say " ${C_DIM}root filesystem not mounted yet${C_RESET}"
        fi
        rule
        say "  ${C_B}1${C_RESET}  unlock and mount the root filesystem"
        say "  ${C_B}2${C_RESET}  list snapshots"
        say "  ${C_B}3${C_RESET}  roll back to a snapshot"
        say "  ${C_B}4${C_RESET}  chroot into the installed system"
        say "  ${C_B}5${C_RESET}  shell here (initramfs, nothing mounted)"
        say "  ${C_B}6${C_RESET}  reboot"
        say "  ${C_B}7${C_RESET}  power off"
        say ""

        choice=$(ask 'loom-rescue' '')
        case "$choice" in
            1)
                if unlock_root && mount_top; then MOUNTED=1; else MOUNTED=0; fi
                pause
                ;;
            2)
                if (( MOUNTED )); then list_snapshots; else warn "mount the root filesystem first (option 1)"; fi
                pause
                ;;
            3)
                if (( MOUNTED )); then
                    if list_snapshots; then
                        n=$(ask "snapshot number to restore (blank to abort)" "")
                        if [[ -n $n ]]; then
                            if [[ $n =~ ^[0-9]+$ ]]; then
                                rollback_to "$n"
                            else
                                err "not a number"
                            fi
                        fi
                    fi
                else
                    warn "mount the root filesystem first (option 1)"
                fi
                pause
                ;;
            4)
                if (( MOUNTED )); then enter_chroot; else warn "mount the root filesystem first (option 1)"; fi
                pause
                ;;
            5)
                say "${C_DIM}type 'exit' to return to this menu${C_RESET}"
                bash --norc -i || true
                ;;
            6) do_reboot ;;
            7) do_poweroff ;;
            "") ;;
            *) warn "unknown choice: $choice" ;;
        esac
    done
}

main "$@"
