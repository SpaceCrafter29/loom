# Building the ISO, and testing it

`mkarchiso` needs an Arch userspace, root, and loop devices. There are three ways
to get that.

## 1. Docker or Podman

This works from any Linux or macOS machine, and from Windows with Docker Desktop
plus a WSL2 backend:

```bash
./scripts/build-iso.sh
```

It detects the engine, copies `iso/` to `build/profile`, injects the payload
(`packages/`, `rootfs/`, `scripts/`, `docs/`) into the live filesystem, fixes
permissions, creates the service symlinks, and runs `mkarchiso` in an
`archlinux:latest` container with `--privileged`. The result lands in `out/` with
a `.sha256` beside it.

The container needs `--privileged` because `mkarchiso` mounts loop devices and
creates device nodes. If that is not acceptable on your machine, use CI instead.

## 2. On Arch, natively

```bash
sudo pacman -S archiso
sudo ./scripts/build-iso.sh
```

## 3. GitHub Actions — nothing installed locally

This is the route to use from Windows or macOS without Docker.

`.github/workflows/iso.yml` runs `tools/check.sh`, then builds the ISO in a
privileged `archlinux` container on a GitHub runner. It uploads the image as a
build artifact on every push, and on a tag it attaches the image and
`SHA256SUMS` to a GitHub release.

```bash
git init && git add -A && git commit -m "loom"
git remote add origin git@github.com:SpaceCrafter29/loom.git
git push -u origin main            # builds, uploads an artifact
git tag v2026.09.11 && git push --tags   # builds, creates a release
```

The artifact is a few hundred megabytes, so it is kept for 14 days and uploaded
uncompressed (an ISO does not compress).

## Static checks

```bash
bash tools/check.sh
```

Runs anywhere bash does — no Arch, no root, no container — which makes it the one
check you can run on the machine you are writing on. It catches the failures that
are expensive precisely because they only appear at boot:

- **CRLF anywhere.** A shell script or initramfs hook with CR line endings fails
  with `bad interpreter`, or silently does nothing. The check compares each file
  against itself with CRs stripped, rather than using `grep $'\r'`, which
  misbehaves under MSYS — the exact platform where a CR is most likely to have
  crept in.
- `bash -n` on every shell file, and `shellcheck` at severity `warning` if it is
  installed.
- Every `file_permissions` entry in `profiledef.sh` resolves to a real file.
  `mkarchiso` fails the build otherwise, twenty minutes in.
- Every `add_file` in the rescue initcpio hook exists. A rename here breaks
  `mkinitcpio` at kernel-upgrade time, which is the worst moment to find out.
- Every `ExecStart=` in a shipped unit and every `Exec=` in a pacman hook points
  at a script that exists.
- `loomctl`'s help text and its dispatcher agree — no documented command that is
  not wired up.
- The console palette is exactly 3 × 16 integers in range. `setvtrgb` silently
  leaves the VGA defaults alone if it is not.
- Brace balance in the zellij KDL files, and that `loom.conf` is sourceable.
- Every `LOOM_*` variable a script reads has a default in `loom.conf`.

It does **not** prove the ISO boots. Nothing short of booting it does.

## Testing in a VM

UEFI is required, so OVMF firmware is not optional. On Arch, `pacman -S edk2-ovmf
qemu-full`.

```bash
# Writable copy of the firmware variables -- this is where boot entries and
# Secure Boot keys get stored.
cp /usr/share/edk2/x64/OVMF_VARS.4m.fd ./OVMF_VARS.4m.fd
qemu-img create -f qcow2 loom-test.qcow2 40G

qemu-system-x86_64 \
  -enable-kvm -machine q35 -cpu host -smp 4 -m 4G \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file=./OVMF_VARS.4m.fd \
  -drive file=loom-test.qcow2,if=virtio,format=qcow2 \
  -cdrom out/loom-*.iso \
  -netdev user,id=n0 -device virtio-net,netdev=n0 \
  -vga virtio -display gtk
```

### Testing Secure Boot

Use the `.secboot` firmware variant, which ships with Microsoft's keys already
enrolled and starts in Setup Mode:

```bash
cp /usr/share/edk2/x64/OVMF_VARS.4m.fd ./OVMF_VARS_SB.4m.fd
qemu-system-x86_64 \
  -enable-kvm -machine q35,smm=on -cpu host -smp 4 -m 4G \
  -global driver=cfi.pflash01,property=secure,value=on \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \
  -drive if=pflash,format=raw,file=./OVMF_VARS_SB.4m.fd \
  -drive file=loom-test.qcow2,if=virtio,format=qcow2 \
  -cdrom out/loom-*.iso
```

`loom-install` will find the firmware in Setup Mode and enrol its own keys. After
the install, enable Secure Boot from the OVMF setup menu and confirm it boots.

### Testing a TPM2 unlock

```bash
mkdir -p /tmp/loom-tpm
swtpm socket --tpm2 --tpmstate dir=/tmp/loom-tpm \
  --ctrl type=unixio,path=/tmp/loom-tpm/swtpm-sock &
# then add to the qemu command:
#   -chardev socket,id=chrtpm,path=/tmp/loom-tpm/swtpm-sock \
#   -tpmdev emulator,id=tpm0,chardev=chrtpm \
#   -device tpm-tis,tpmdev=tpm0
```

### What to actually check in the VM

1. `loom-install --dry-run` prints a plan that matches `docs/install.md`.
2. A real install completes, and the machine reboots into the LUKS prompt.
3. `tty1` lands in zellij with four tabs; `Ctrl+Alt+F2` gives a plain shell.
4. The palette is applied — the console is not VGA blue on black.
5. `loomctl health` passes, or only warns about things it should warn about.
6. The boot menu has a **Loom Rescue** entry, it unlocks the disk, and it lists
   the baseline snapshot.
7. `sudo loomctl snapshot test`, break something deliberately
   (`sudo rm -rf /usr/bin/fish`), `sudo loomctl rollback`, confirm it comes back.
8. `loomctl gui firefox`, then close it, and confirm zellij is still there.

Step 7 is the one that matters. A rollback path nobody has exercised is a rollback
path that does not work.

## Build artifacts

```
build/profile/   assembled archiso profile (payload injected)
build/work/      mkarchiso scratch, deleted unless --keep-work
build/build.log
out/             the .iso and its .sha256
```

None of these are tracked. `rm -rf build out` is always safe.
