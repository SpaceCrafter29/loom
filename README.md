# Loom

An Arch-based Linux distribution whose window manager is a terminal multiplexer.

No display server starts at boot. You log in on `tty1` and land in a zellij
session: tabs, panes, a status bar, and the whole system driven from the
keyboard. Graphics exist, but only when you ask for them — `loomctl gui firefox`
borrows the console for one application and hands it back when you close it.

Rolling release, because a terminal-first system is a system you keep up to
date. Every `pacman` transaction is wrapped in a Btrfs snapshot, the boot menu
has a rescue entry that can undo one without booting the broken system, and the
kernel ships as a single signed file.

```
sudo loomctl update        # read the news, snapshot, upgrade, re-sign the boot
sudo loomctl rollback      # put the root filesystem back the way it was
loomctl health             # what is wrong with this machine
```

## What you get

| | |
|---|---|
| **base** | Arch, rolling |
| **session** | zellij on the Linux console, started at login on `tty1`. tmux is configured too, and one line switches |
| **escape hatch** | `tty2`–`tty6` are always plain login shells |
| **filesystem** | Btrfs, subvolume layout built for rollback |
| **encryption** | LUKS2 with argon2id, full disk |
| **boot** | systemd-boot + unified kernel images, signed with your own keys |
| **updates** | prefetched in the background; upgrade is local and fast |
| **undo** | snapper + snap-pac online, a self-contained rescue UKI offline |
| **graphics** | `cage` for one app, `river` for a full session, neither at boot |
| **power** | TLP, thermald, fwupd, zram swap |

## What it looks like

[`docs/preview/index.html`](docs/preview/index.html) draws the running system:
the boot menu, the LUKS prompt, the zellij session with its four tabs, what
`loomctl health` and `loomctl update` print, and the rescue shell. Clone the repo
and open that file in a browser — GitHub serves HTML as source, so the link above
will not render it for you.

It is a picture, not a demo; nothing in it runs. But the sixteen colours are the
exact values from
[`rootfs/usr/share/loom/console/palette`](rootfs/usr/share/loom/console/palette),
and the text is the real output of the scripts in this repo rather than an
impression of it — which is how two bugs turned up before the system had ever
booted: a summary line that said “nothing to clean up” immediately after asking
for a reboot, and a boot menu that would have listed three entries all called
*Arch Linux*.

## Getting it

```bash
git clone https://github.com/SpaceCrafter29/loom.git
cd loom
bash tools/check.sh     # static checks, no Arch needed
```

**From the ISO.** `scripts/build-iso.sh` builds the install medium if you have
Docker, Podman, or an Arch machine. If you have none of those, push the repo to
GitHub and [`.github/workflows/iso.yml`](.github/workflows/iso.yml) builds it in
CI and attaches it to the release — nothing to install locally. See
[docs/build.md](docs/build.md).

Boot it (UEFI only), then:

```bash
loom-install --dry-run   # the complete plan, touching nothing
loom-install             # the real thing
```

**Onto an Arch install you already have.** `bootstrap.sh` never partitions a
disk and never changes your bootloader choice:

```bash
sudo ./scripts/bootstrap.sh --user "$USER"
sudo ./scripts/bootstrap.sh --dry-run    # see what it would do first
```

**As a package.** [`pkg/loom-base`](pkg/loom-base) builds the configuration into
a pacman package, for when you have more than one Loom machine.

## The design, briefly

Six decisions are load-bearing. [docs/design.md](docs/design.md) argues them
properly; the short version:

- **The console, not a compositor.** The session is a multiplexer on a VT. This
  is cheap, survives a GPU driver regression, and works over a serial console.
  It also means 16 colours and no font ligatures — see [docs/tty.md](docs/tty.md)
  for what Loom does about that instead of pretending otherwise.
- **`tty2`–`tty6` are sacred.** A broken session config cannot lock you out.
  Two fast session failures disable autostart for the rest of the boot and hand
  you a shell with an explanation.
- **Unified kernel images, not GRUB.** GRUB cannot unlock a LUKS2 volume that
  uses argon2id, and we are not weakening the KDF to please a bootloader. One
  signed PE binary per kernel, discovered automatically by systemd-boot.
- **Rollback is a rename, not `snapper rollback`.** Loom mounts `/` with
  `subvol=@`, which ignores the Btrfs default subvolume that `snapper rollback`
  manipulates. `loomctl rollback` moves `@` aside and recreates it from a
  snapshot, which is what actually takes effect here.
- **An offline rollback path that carries its own tools.** `loom-rescue.efi` is
  a unified kernel image whose initramfs contains `cryptsetup`, `btrfs` and a
  bash rescue shell. It never reads the root filesystem to start, so it still
  works when the root filesystem is the problem.
- **Updates are prefetched.** A timer runs `pacman -Syuw` on idle, so the
  upgrade itself is a local operation rather than a download.

## Repository layout

```
packages/        package groups: core, session, tui, dev, laptop, gui, aur
rootfs/          files that land on /, as they land there
scripts/
  bootstrap.sh   minimal Arch -> Loom. Idempotent, non-destructive.
  build-iso.sh   builds the ISO natively, or in docker/podman
iso/             archiso profile + the installer that lives on the medium
pkg/loom-base/   the same configuration, as a pacman package
tools/check.sh   static checks; runs anywhere bash does
docs/
```

## Documentation

- [docs/design.md](docs/design.md) — why it is built this way
- [docs/install.md](docs/install.md) — installing, and the disk layout
- [docs/updates.md](docs/updates.md) — the update model, and every way to undo one
- [docs/secure-boot.md](docs/secure-boot.md) — keys, signing, TPM2 unlock
- [docs/tty.md](docs/tty.md) — the console's real limits, and the workarounds
- [docs/keys.md](docs/keys.md) — keybindings and where everything lives
- [docs/build.md](docs/build.md) — building the ISO and testing it in a VM

## Status

The repository is complete and statically checked (`bash tools/check.sh`), but
**no ISO built from it has been booted yet**. Treat the first install as a test
install: run it in a UEFI VM with `loom-install --dry-run` first. The VM recipe
is in [docs/build.md](docs/build.md).

## Licence

MIT. See [LICENSE](LICENSE).

---

Loom is built and maintained by [**SpaceCrafter29**](https://github.com/SpaceCrafter29).
Issues and pull requests welcome at
[github.com/SpaceCrafter29/loom](https://github.com/SpaceCrafter29/loom).
