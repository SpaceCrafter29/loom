#!/usr/bin/env bash
# Loom, by SpaceCrafter29 -- https://github.com/SpaceCrafter29/loom
# Build the Loom install ISO.
#
# mkarchiso needs an Arch userspace and root, so this script takes whichever of
# the three routes is available:
#
#   1. running on Arch as root          -> build directly
#   2. docker or podman available       -> build in an archlinux:latest container
#   3. neither                          -> explain, and point at CI
#
# The profile in iso/ is never modified: it is copied to build/profile, the
# payload (packages/, rootfs/, scripts/) is injected into the copy, and the
# build happens there. That keeps the repo clean and makes the ISO reproducible
# from a fresh clone.
#
#   ./scripts/build-iso.sh
#   ./scripts/build-iso.sh --engine podman
#   ./scripts/build-iso.sh --out /tmp/iso

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

LOOM_LOG="$REPO/build/build.log"
WORK="$REPO/build/work"
PROFILE="$REPO/build/profile"
OUT="$REPO/out"
ENGINE=""
KEEP_WORK=0

usage() {
    cat <<EOF
${C_B}usage:${C_RESET} ./scripts/build-iso.sh [options]

  --engine native|docker|podman   force a build route (default: detect)
  --out DIR                       where to write the .iso (default: ./out)
  --keep-work                     do not delete build/work afterwards
  -h, --help                      this
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --engine)     ENGINE="${2:-}"; shift 2 ;;
        --engine=*)   ENGINE="${1#*=}"; shift ;;
        --out)        OUT="${2:-}"; shift 2 ;;
        --out=*)      OUT="${1#*=}"; shift ;;
        --keep-work)  KEEP_WORK=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

detect_engine() {
    [[ -n $ENGINE ]] && { printf '%s' "$ENGINE"; return 0; }
    if [[ -f /etc/arch-release ]] && command -v mkarchiso >/dev/null 2>&1; then
        printf 'native'
    elif command -v podman >/dev/null 2>&1; then
        printf 'podman'
    elif command -v docker >/dev/null 2>&1; then
        printf 'docker'
    else
        printf 'none'
    fi
}

# --- assemble the profile ----------------------------------------------------

prepare_profile() {
    step "Assembling the build profile"
    rm -rf "$PROFILE"
    mkdir -p "$PROFILE" "$OUT" "$(dirname "$LOOM_LOG")"
    cp -a "$REPO/iso/." "$PROFILE/"

    # The payload: one copy of Loom, used by both the installer and by anyone
    # running bootstrap.sh on an existing machine.
    local payload="$PROFILE/airootfs/usr/share/loom-payload"
    mkdir -p "$payload"
    cp -a "$REPO/packages" "$REPO/rootfs" "$REPO/scripts" "$payload/"
    cp -a "$REPO/README.md" "$REPO/docs" "$payload/" 2>/dev/null || true
    rm -rf "$payload/scripts/build-iso.sh"
    ok "payload injected into the live filesystem"

    # Executables. Git preserves the bit, but a zip download or a Windows
    # checkout does not, and a non-executable installer is a confusing failure.
    chmod 0755 "$PROFILE/airootfs/usr/local/bin/"* \
               "$payload/scripts/bootstrap.sh" \
               "$payload/rootfs/usr/local/bin/"* \
               "$payload/rootfs/usr/share/loom/rescue/rescue.sh" \
               "$payload/rootfs/etc/initcpio/install/loom-rescue" \
               "$payload/rootfs/etc/initcpio/hooks/loom-rescue"
    ok "permissions fixed"

    # Services for the live environment. These are symlinks rather than files,
    # so they are created here instead of being committed -- a repo that needs
    # symlinks is a repo that cannot be checked out on Windows.
    local wants="$PROFILE/airootfs/etc/systemd/system/multi-user.target.wants"
    mkdir -p "$wants"
    ln -sf /usr/lib/systemd/system/NetworkManager.service  "$wants/NetworkManager.service"
    ln -sf /usr/lib/systemd/system/systemd-timesyncd.service "$wants/systemd-timesyncd.service"
    ok "NetworkManager and time sync enabled on the medium"

    # sshd is installed for rescue work but must not listen by default on a
    # live medium with a known root account.
    ok "sshd left disabled"
}

# --- build -------------------------------------------------------------------

build_native() {
    step "Building with mkarchiso (native)"
    need_root
    need_cmd mkarchiso
    rm -rf "$WORK"
    mkdir -p "$WORK" "$OUT"
    mkarchiso -v -w "$WORK" -o "$OUT" "$PROFILE"
}

build_container() {
    local engine="$1"
    step "Building with mkarchiso inside $engine"
    need_cmd "$engine"

    # --privileged: mkarchiso needs loop devices, mount, and mknod.
    "$engine" run --rm --privileged \
        -v "$REPO:/loom" \
        -w /loom \
        docker.io/library/archlinux:latest \
        bash -euo pipefail -c '
            echo "==> installing build dependencies"
            pacman -Sy --noconfirm --needed archiso git >/dev/null
            echo "==> mkarchiso $(mkarchiso -h 2>&1 | head -n1)"
            rm -rf /loom/build/work
            mkdir -p /loom/build/work /loom/out
            mkarchiso -v -w /loom/build/work -o /loom/out /loom/build/profile
        '
}

finish() {
    step "Result"
    local -a isos=()
    mapfile -t isos < <(find "$OUT" -maxdepth 1 -name '*.iso' -newermt '-1 hour' 2>/dev/null | sort)
    if (( ${#isos[@]} == 0 )); then
        bad "no .iso appeared in $OUT"
        note "the full build log is in $LOOM_LOG"
        exit 1
    fi
    local iso
    for iso in "${isos[@]}"; do
        ok "$iso ($(du -h "$iso" | cut -f1))"
        if command -v sha256sum >/dev/null 2>&1; then
            (cd "$(dirname "$iso")" && sha256sum "$(basename "$iso")" > "$(basename "$iso").sha256")
            note "$(cat "$iso.sha256")"
        fi
    done

    cat <<EOF

  Write it to a USB stick:
    ${C_B}sudo dd if=${isos[-1]} of=/dev/sdX bs=4M status=progress oflag=sync${C_RESET}

  Or try it in a VM first (UEFI is required, so OVMF firmware is not optional):
    ${C_B}qemu-system-x86_64 -enable-kvm -m 4G -smp 4 \\
      -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \\
      -drive if=pflash,format=raw,file=OVMF_VARS.4m.fd \\
      -drive file=loom-test.qcow2,if=virtio \\
      -cdrom ${isos[-1]}${C_RESET}

  See docs/build.md for the VM recipe in full, including Secure Boot testing.
EOF
}

main() {
    local engine
    engine=$(detect_engine)
    note "build route: $engine"

    if [[ $engine == none ]]; then
        die "no way to build an ISO on this machine.

mkarchiso needs an Arch userspace and root privileges. You have three options:

  1. install docker or podman, then re-run this script
  2. run it on an Arch machine as root
  3. push the repo to GitHub: .github/workflows/iso.yml builds the ISO on every
     tag and attaches it to the release, which needs nothing installed locally

Option 3 is the one to use if you are on Windows or macOS."
    fi

    prepare_profile
    case "$engine" in
        native)        build_native ;;
        docker|podman) build_container "$engine" ;;
        *)             die "unknown engine '$engine'" ;;
    esac
    finish

    if (( ! KEEP_WORK )); then
        rm -rf "$WORK"
        note "build/work removed (--keep-work to keep it)"
    fi
}

main "$@"
