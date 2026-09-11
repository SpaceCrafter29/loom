#!/usr/bin/env bash
# Loom, by SpaceCrafter29 -- https://github.com/SpaceCrafter29/loom
# Turn a minimal Arch install into Loom.
#
# Safe to run on a machine you already care about, and safe to run twice: it
# installs packages, lays down configuration, and enables services, but it never
# partitions a disk, never touches your bootloader choice, and never rewrites a
# kernel command line it did not write. The destructive parts live in
# loom-install, which only ever runs from the ISO.
#
#   sudo ./scripts/bootstrap.sh --user alice
#   sudo ./scripts/bootstrap.sh --user alice --no-gui --no-dev
#   sudo ./scripts/bootstrap.sh --dry-run
#
# It is also the second half of the ISO installer: loom-install pacstraps a base
# system and then runs this inside the chroot, so there is exactly one
# definition of what Loom is.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

REPO="$(cd -- "$SCRIPT_DIR/.." && pwd)"
[[ -d $REPO/packages ]] || REPO="/usr/share/loom-payload"
[[ -d $REPO/packages ]] || die "cannot find the Loom payload next to this script"

WANT_LAPTOP=1
WANT_GUI=1
WANT_DEV=1
WANT_AUR=0
DRY_RUN=0
ASSUME_YES=0
TARGET_USER=""

usage() {
    cat <<EOF
${C_B}usage:${C_RESET} sudo $0 [options]

  --user NAME     configure this user (shell, groups, dotfiles)
  --no-laptop     skip TLP, fwupd, thermald and friends
  --no-gui        skip cage/river/firefox; 'loomctl gui' will have nothing to run
  --no-dev        skip toolchains and podman
  --aur           build paru and install the optional AUR packages
  --yes           do not ask for confirmation
  --dry-run       print what would happen and change nothing
  -h, --help      this

Package groups live in $REPO/packages/, configuration in $REPO/rootfs/.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)      TARGET_USER="${2:-}"; shift 2 ;;
        --user=*)    TARGET_USER="${1#*=}"; shift ;;
        --no-laptop) WANT_LAPTOP=0; shift ;;
        --no-gui)    WANT_GUI=0; shift ;;
        --no-dev)    WANT_DEV=0; shift ;;
        --aur)       WANT_AUR=1; shift ;;
        --yes|-y)    ASSUME_YES=1; shift ;;
        --dry-run)   DRY_RUN=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           die "unknown option: $1 (try --help)" ;;
    esac
done

run() {
    if (( DRY_RUN )); then
        printf '  %swould run:%s %s\n' "$C_DIM" "$C_RESET" "$*"
        return 0
    fi
    "$@"
}

# --- 1. preflight ------------------------------------------------------------

preflight() {
    step "Preflight"

    (( DRY_RUN )) || need_root
    is_arch || die "this is not an Arch system (no pacman, no /etc/arch-release)"
    need_cmd pacman sed awk find

    note "payload:  $REPO"
    note "log:      $LOOM_LOG"
    in_chroot && note "running inside a chroot: services will be enabled, not started"

    local fstype
    fstype=$(findmnt -no FSTYPE -T / 2>/dev/null || echo unknown)
    if [[ $fstype == btrfs ]]; then
        ok "root filesystem is Btrfs"
        if ! findmnt -rn /.snapshots >/dev/null 2>&1; then
            note "/.snapshots is not mounted yet; snapper setup will deal with it"
        fi
    else
        warn "root filesystem is '$fstype', not Btrfs"
        warn "snapshots and rollback will not be available -- the rest still works"
    fi

    if [[ -d /efi ]] && findmnt -rn /efi >/dev/null 2>&1; then
        ok "ESP mounted at /efi"
    elif findmnt -rn /boot >/dev/null 2>&1 && [[ $(findmnt -no FSTYPE -T /boot) == vfat ]]; then
        warn "your ESP is at /boot, not /efi"
        warn "Loom's kernel presets write to /efi; boot configuration will be skipped"
    else
        warn "no EFI system partition found; boot configuration will be skipped"
    fi

    if (( ! DRY_RUN && ! ASSUME_YES )); then
        printf '\n'
        confirm "Install Loom onto this running system?" n || die "aborted"
    fi
}

# --- 2. packages -------------------------------------------------------------

collect_packages() {
    local -a lists=("$REPO/packages/core.txt" "$REPO/packages/session.txt" "$REPO/packages/tui.txt")
    (( WANT_DEV ))    && lists+=("$REPO/packages/dev.txt")
    (( WANT_LAPTOP )) && lists+=("$REPO/packages/laptop.txt")
    (( WANT_GUI ))    && lists+=("$REPO/packages/gui.txt")

    local l
    for l in "${lists[@]}"; do
        read_pkg_list "$l"
    done | sort -u
}

install_packages() {
    step "Packages"

    local -a pkgs=()
    mapfile -t pkgs < <(collect_packages)
    note "${#pkgs[@]} packages across $(( 3 + WANT_DEV + WANT_LAPTOP + WANT_GUI )) groups"

    if (( DRY_RUN )); then
        printf '%s\n' "${pkgs[@]}" | paste -sd' ' - | fold -s -w 76 | sed 's/^/    /'
        return 0
    fi

    run pacman -Sy --noconfirm

    # A single typo in a package list would otherwise abort the whole
    # transaction with a message about the wrong thing.
    step "Checking that every listed package exists"
    local -a missing=()
    mapfile -t missing < <(unknown_packages "${pkgs[@]}" | sed '/^$/d')
    if (( ${#missing[@]} > 0 )); then
        bad "${#missing[@]} package(s) are not in any configured repository:"
        printf '      %s\n' "${missing[@]}"
        note "a package may have been renamed or moved to the AUR upstream"
        note "remove it from packages/*.txt, or add it to packages/aur.txt"
        die "refusing to start a transaction that cannot finish"
    fi
    ok "all ${#pkgs[@]} packages resolve"

    step "Installing"
    run pacman -S --needed --noconfirm "${pkgs[@]}"
    ok "packages installed"
}

# --- 3. configuration --------------------------------------------------------

install_config() {
    step "Configuration"
    if (( DRY_RUN )); then
        note "would copy $REPO/rootfs/ over /"
        find "$REPO/rootfs" -type f -printf '    /%P\n' | sort
        return 0
    fi

    install_tree "$REPO/rootfs" /
    chmod 0755 /usr/local/bin/loomctl /usr/local/bin/loom-session \
               /usr/local/bin/loom-gui /usr/local/bin/loom-sign-boot \
               /usr/local/bin/loom-build-rescue
    chmod 0755 /etc/initcpio/install/loom-rescue /etc/initcpio/hooks/loom-rescue
    chmod 0755 /usr/share/loom/rescue/rescue.sh
    chmod 0440 /etc/sudoers.d/loom
    ok "configuration installed"

    # visudo -c catches a syntax error now, rather than the first time you need
    # sudo and cannot get it.
    if have visudo; then
        if visudo -cf /etc/sudoers.d/loom >/dev/null 2>&1; then
            ok "sudoers snippet validates"
        else
            rm -f /etc/sudoers.d/loom
            die "the sudoers snippet failed validation and was removed"
        fi
    fi

    run systemd-tmpfiles --create /etc/tmpfiles.d/loom.conf 2>/dev/null || true

    install_skel

    # Network printer and .local host discovery.
    if [[ -f /etc/nsswitch.conf ]] && ! grep -q 'mdns' /etc/nsswitch.conf; then
        sed -i 's/^hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/' \
            /etc/nsswitch.conf
        ok "nsswitch.conf: mDNS resolution enabled"
    fi
}

# The per-user configs, as source:destination-relative-to-$HOME. Used for
# /etc/skel (so that every account created later gets them) and for the account
# named with --user.
loom_user_configs() {
    cat <<'EOF'
/usr/share/loom/zellij/config.kdl:.config/zellij/config.kdl
/usr/share/loom/zellij/layouts/loom.kdl:.config/zellij/layouts/loom.kdl
/usr/share/loom/nvim/init.lua:.config/nvim/init.lua
/usr/share/loom/starship.toml:.config/starship.toml
/usr/share/loom/btop/btop.conf:.config/btop/btop.conf
EOF
}

install_skel() {
    local pair src dst n=0
    while IFS= read -r pair; do
        src="${pair%%:*}"; dst="/etc/skel/${pair#*:}"
        [[ -r $src ]] || continue
        install -Dm644 "$src" "$dst"
        n=$((n + 1))
    done < <(loom_user_configs)
    ok "$n config file(s) into /etc/skel, for accounts created later"
}

# --- 4. boot -----------------------------------------------------------------

configure_boot() {
    step "Boot"

    if ! findmnt -rn /efi >/dev/null 2>&1; then
        warn "no ESP at /efi; skipping kernel image configuration"
        note "Loom expects the ESP at /efi and unified kernel images in"
        note "/efi/EFI/Linux. See docs/install.md if yours is laid out differently."
        return 0
    fi

    if [[ ! -f /etc/kernel/cmdline ]]; then
        warn "/etc/kernel/cmdline does not exist"
        note "a unified kernel image needs an embedded command line, and guessing"
        note "yours would be a good way to produce an unbootable machine."
        note "Write it yourself (see /usr/share/loom/boot/cmdline.example), then:"
        note "  sudo loomctl rebuild-boot"
        return 0
    fi

    run install -Dm644 /usr/share/loom/boot/linux.preset /etc/mkinitcpio.d/linux.preset
    run install -Dm644 /usr/share/loom/boot/loom-rescue.preset /etc/mkinitcpio.d/loom-rescue.preset
    ok "mkinitcpio presets installed (unified kernel images to /efi/EFI/Linux)"

    run mkdir -p /efi/EFI/Linux

    step "Building kernel images"
    if (( DRY_RUN )); then
        note "would run mkinitcpio -P and loom-build-rescue"
        return 0
    fi
    mkinitcpio -P || die "mkinitcpio failed -- do not reboot until this succeeds"
    ok "unified kernel images built"
    /usr/local/bin/loom-build-rescue || warn "the rescue image failed to build"

    if have sbctl; then
        if [[ -d /var/lib/sbctl/keys || -d /usr/share/secureboot/keys ]]; then
            /usr/local/bin/loom-sign-boot
        else
            note "Secure Boot keys have not been created on this machine."
            note "See docs/secure-boot.md -- it is three commands and a firmware"
            note "setting, and it is what makes the signed kernel images mean anything."
        fi
    fi
}

# --- 5. snapshots ------------------------------------------------------------

apply_snapper_settings() {
    local cfg="$1" file="$2" line key value
    [[ -r $file ]] || return 0
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        [[ -z $line ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        run snapper -c "$cfg" set-config "$key=$value" \
            || warn "snapper: could not set $key on config '$cfg'"
    done <"$file"
    ok "snapper '$cfg' configured"
}

configure_snapshots() {
    step "Snapshots"

    if [[ $(findmnt -no FSTYPE -T / 2>/dev/null) != btrfs ]]; then
        warn "root is not Btrfs; skipping snapper"
        return 0
    fi
    have snapper || { warn "snapper is not installed; skipping"; return 0; }

    if (( DRY_RUN )); then
        note "would create snapper configs for / and /home and apply"
        note "$REPO/rootfs/usr/share/loom/snapper/*.settings"
        return 0
    fi

    # snapper create-config insists on creating /.snapshots itself and fails if
    # anything is already there. On a Loom install @snapshots is already mounted
    # at /.snapshots, so we move it out of the way and put it back.
    if [[ ! -f /etc/snapper/configs/root ]]; then
        local remount=0
        if findmnt -rn /.snapshots >/dev/null 2>&1; then
            umount /.snapshots && remount=1
        fi
        rmdir /.snapshots 2>/dev/null || true

        if snapper -c root create-config /; then
            ok "snapper config 'root' created"
        else
            warn "snapper create-config failed for /"
        fi

        # Delete the nested subvolume snapper just made: snapshots must live in
        # their own top-level subvolume, or a rollback of @ would take the
        # snapshots with it and there would be nothing to roll back to next time.
        if btrfs subvolume show /.snapshots >/dev/null 2>&1; then
            btrfs subvolume delete /.snapshots >/dev/null \
                && ok "removed the nested .snapshots subvolume"
        fi
        mkdir -p /.snapshots
        chmod 750 /.snapshots
        if (( remount )); then
            mount /.snapshots && ok "@snapshots remounted at /.snapshots"
        elif grep -q '[[:space:]]/\.snapshots[[:space:]]' /etc/fstab; then
            mount /.snapshots 2>/dev/null && ok "@snapshots mounted at /.snapshots"
        else
            warn "/.snapshots has no fstab entry"
            note "snapshots will be created inside @ and lost on rollback."
            note "Add a line like:"
            note "  UUID=<btrfs-uuid> /.snapshots btrfs subvol=@snapshots,compress=zstd:1,noatime 0 0"
        fi
    else
        ok "snapper config 'root' already exists"
    fi

    apply_snapper_settings root "$REPO/rootfs/usr/share/loom/snapper/root.settings"

    if findmnt -rn /home >/dev/null 2>&1 && [[ ! -f /etc/snapper/configs/home ]]; then
        if snapper -c home create-config /home 2>/dev/null; then
            ok "snapper config 'home' created"
            apply_snapper_settings home "$REPO/rootfs/usr/share/loom/snapper/home.settings"
        else
            note "could not create a snapper config for /home (is it its own subvolume?)"
        fi
    elif [[ -f /etc/snapper/configs/home ]]; then
        apply_snapper_settings home "$REPO/rootfs/usr/share/loom/snapper/home.settings"
    fi

    # The first snapshot is the one you will want and will not have taken.
    if snapper -c root list >/dev/null 2>&1; then
        local n
        n=$(snapper -c root create --type single --cleanup-algorithm number \
            --description "loom bootstrap" --print-number 2>/dev/null || true)
        if [[ -n $n ]]; then ok "baseline snapshot $n created"; fi
    fi
}

# --- 6. services -------------------------------------------------------------

configure_services() {
    step "Services"

    local -a units=(
        NetworkManager.service
        loom-console-palette.service
        loom-update-prefetch.timer
        fstrim.timer
        systemd-timesyncd.service
    )
    have snapper && units+=(snapper-cleanup.timer)
    [[ -f /usr/lib/systemd/system/btrfs-scrub@.timer ]] && units+=('btrfs-scrub@-.timer')
    pacman -Qq bluez     >/dev/null 2>&1 && units+=(bluetooth.service)
    pacman -Qq cups      >/dev/null 2>&1 && units+=(cups.socket)
    pacman -Qq avahi     >/dev/null 2>&1 && units+=(avahi-daemon.service)
    pacman -Qq fwupd     >/dev/null 2>&1 && units+=(fwupd-refresh.timer)
    pacman -Qq thermald  >/dev/null 2>&1 && units+=(thermald.service)
    pacman -Qq openssh   >/dev/null 2>&1 && note "sshd is installed but intentionally left disabled"

    if pacman -Qq tlp >/dev/null 2>&1; then
        units+=(tlp.service)
        # TLP and systemd's own power management fight over the same knobs.
        run systemctl mask systemd-rfkill.service systemd-rfkill.socket 2>/dev/null || true
    fi

    if (( DRY_RUN )); then
        printf '    %s\n' "${units[@]}"
        return 0
    fi
    enable_units "${units[@]}"

    # PipeWire is a user service; enable it in the default user profile so that
    # every account gets sound without a per-user ritual.
    if pacman -Qq pipewire >/dev/null 2>&1; then
        if systemctl --global enable pipewire.socket pipewire-pulse.socket \
            wireplumber.service >/dev/null 2>&1; then
            ok "PipeWire enabled for all users"
        else
            warn "could not enable the PipeWire user units"
        fi
    fi
}

# --- 7. the user -------------------------------------------------------------

guess_user() {
    awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "nobody" { print $1; exit }' /etc/passwd
}

configure_user() {
    step "User"

    if [[ -z $TARGET_USER ]]; then
        TARGET_USER=$(guess_user || true)
        [[ -n $TARGET_USER ]] && note "no --user given; using '$TARGET_USER'"
    fi
    if [[ -z $TARGET_USER ]]; then
        warn "no normal user account found; skipping user configuration"
        note "create one, then re-run with: --user <name>"
        return 0
    fi
    if ! id "$TARGET_USER" >/dev/null 2>&1; then
        die "user '$TARGET_USER' does not exist"
    fi

    local home
    home=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    note "user: $TARGET_USER ($home)"

    # wheel for sudo; the rest are for the hardware this user is expected to
    # touch without asking.
    local -a groups=(wheel)
    getent group video   >/dev/null && groups+=(video)
    getent group input   >/dev/null && groups+=(input)
    getent group audio   >/dev/null && groups+=(audio)
    getent group storage >/dev/null && groups+=(storage)
    getent group lp      >/dev/null && groups+=(lp)
    run usermod -aG "$(IFS=,; printf '%s' "${groups[*]}")" "$TARGET_USER"
    ok "groups: ${groups[*]}"

    if have fish && [[ $(getent passwd "$TARGET_USER" | cut -d: -f7) != */fish ]]; then
        run chsh -s "$(command -v fish)" "$TARGET_USER"
        ok "login shell set to fish"
    fi

    if (( DRY_RUN )); then
        note "would install zellij, neovim, starship and btop configs into $home/.config"
        return 0
    fi

    # Per-user configs, never overwriting something the user has edited.
    local group pair src dst
    group=$(id -gn "$TARGET_USER")
    while IFS= read -r pair; do
        src="${pair%%:*}"; dst="$home/${pair#*:}"
        [[ -r $src ]] || continue
        if [[ -e $dst ]]; then
            note "kept existing $dst"
            continue
        fi
        install -Dm644 -o "$TARGET_USER" -g "$group" "$src" "$dst"
        ok "installed $dst"
    done < <(loom_user_configs)
    install -d -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" \
        "$home/.local/state/loom" "$home/.local/share/loom"
}

# --- 8. AUR ------------------------------------------------------------------

configure_aur() {
    (( WANT_AUR )) || return 0
    step "AUR"

    if (( DRY_RUN )); then
        note "would build paru and install: $(read_pkg_list "$REPO/packages/aur.txt" | paste -sd' ' -)"
        return 0
    fi
    if in_chroot; then
        warn "cannot build AUR packages inside the installer chroot"
        note "run this after first boot:  ./scripts/bootstrap.sh --aur --user $TARGET_USER"
        return 0
    fi
    [[ -n $TARGET_USER ]] || { warn "no user to build as; skipping AUR"; return 0; }

    if ! have paru; then
        local tmp
        tmp=$(sudo -u "$TARGET_USER" mktemp -d)
        note "building paru in $tmp"
        if sudo -u "$TARGET_USER" git clone --depth 1 https://aur.archlinux.org/paru-bin.git "$tmp/paru-bin" \
            && (cd "$tmp/paru-bin" && sudo -u "$TARGET_USER" makepkg -si --noconfirm); then
            ok "paru installed"
        else
            warn "could not build paru; skipping the AUR group"
            rm -rf "$tmp"
            return 0
        fi
        rm -rf "$tmp"
    fi

    local -a aur=()
    mapfile -t aur < <(read_pkg_list "$REPO/packages/aur.txt")
    (( ${#aur[@]} == 0 )) && return 0
    note "installing: ${aur[*]}"
    sudo -u "$TARGET_USER" paru -S --needed --noconfirm "${aur[@]}" \
        || warn "some AUR packages failed; none of them are load-bearing"
}

# --- 9. done -----------------------------------------------------------------

finish() {
    step "Done"
    if (( DRY_RUN )); then
        note "dry run: nothing was changed"
        return 0
    fi

    printf '\n'
    /usr/local/bin/loomctl health || true

    cat <<EOF

${C_CYN}${C_B}Loom is installed.${C_RESET}

  ${C_B}tty1${C_RESET}        your session: zellij, started at login
  ${C_B}tty2-tty6${C_RESET}   plain login shells, always, no matter what you break
  ${C_B}Alt+f g m w${C_RESET} files / git / system / browser, in a new pane

  ${C_B}sudo loomctl update${C_RESET}     upgrade, with a snapshot taken first
  ${C_B}sudo loomctl rollback${C_RESET}   undo the last upgrade
  ${C_B}loomctl health${C_RESET}          what is wrong with this machine
  ${C_B}loomctl gui firefox${C_RESET}     pixels, on demand

  Reboot to get the session, the palette and the rescue boot entry.
EOF
}

main() {
    preflight
    install_packages
    install_config
    configure_boot
    configure_snapshots
    configure_services
    configure_user
    configure_aur
    finish
}

main "$@"
