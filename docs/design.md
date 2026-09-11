# Design

Every decision below has a cheaper alternative that most distributions pick.
This is the argument for not picking it.

## The session is a multiplexer on a VT

There is no display manager, no compositor, and no X server running when you log
in. `tty1`'s login shell calls `loom-session`, which attaches to (or creates) a
zellij session. That session *is* the desktop: tabs are workspaces, panes are
windows, and the status bar is the panel.

What this buys:

- It cannot be broken by a graphics driver. A kernel that fails to probe your
  GPU still gives you a working machine.
- It works identically over SSH and over a serial console, which is to say it
  works when the machine is in a state where nothing else does.
- Session state survives a logout: detach, log back in, everything is where you
  left it.
- It starts in milliseconds and idles at a few megabytes.

What it costs, honestly: 16 colours, no font ligatures, no inline images, and no
clipboard integration with graphical applications. Those are real, and
[docs/tty.md](tty.md) covers what Loom does about each instead of pretending the
console is a modern terminal emulator.

### Graphics on demand

`loomctl gui firefox` runs `cage` — a compositor that does exactly one
full-screen application — on the VT you are already sitting on. This works
because of a kernel detail worth knowing: when a compositor takes a VT it puts
it into graphics mode, and the kernel stops delivering keyboard input to the
terminal. zellij underneath simply blocks on a read that never returns. Close the
application and the VT goes back to text mode; your session is untouched.

`loomctl gui` with no argument starts `river`, a full tiling Wayland session, for
the days when one application is not enough.

## `tty2` through `tty6` are never touched

`logind.conf.d/loom.conf` reserves six VTs. Only `tty1` gets a session; the rest
are plain `agetty` login shells, always.

This is the single most important safety property in the system. A syntax error
in a zellij config, a bad keybinding, a missing binary — none of it can lock you
out, because `Ctrl+Alt+F2` is a shell that reads none of it.

Belt and braces: `loom-session` times its own startup. Two failures in under
five seconds and it writes `/run/loom/no-session`, which disables autostart for
the rest of the boot and prints the three commands you need to diagnose it. A
login loop is not an acceptable failure mode for a session manager.

## Unified kernel images and systemd-boot, not GRUB

A unified kernel image is one PE binary containing the kernel, the initramfs,
the CPU microcode and the embedded kernel command line.

systemd-boot can discover such images by itself, and Loom deliberately does not
let it. Auto-discovery titles each entry from the `PRETTY_NAME` embedded in the
image, and all three Loom images embed the same `/etc/os-release` — so the menu
would read *Arch Linux* three times, with the rescue entry indistinguishable
from the others at exactly the moment you need to find it. The images therefore
live in `/efi/EFI/loom`, which systemd-boot does not scan, and three entry files
in `/efi/loader/entries` name them:

```
10-loom.conf           Loom
20-loom-fallback.conf  Loom (fallback)
90-loom-rescue.conf    Loom Rescue
```

Nothing in them changes between kernel versions — they point at fixed filenames
that `mkinitcpio` rewrites in place — so this costs three static files and buys
a boot menu you can read. `tools/check.sh` verifies that each entry's `efi` path
matches a path the presets actually build.

The reason this is not a style preference: **GRUB cannot unlock a LUKS2 volume
whose KDF is argon2id.** The alternatives are to use GRUB with a weaker PBKDF2
key derivation, to keep an unencrypted `/boot`, or to not use GRUB. Loom takes
the third option. argon2id is memory-hard, which is the entire point of using it
on a device that can be stolen.

Secure Boot follows from the same decision. One file to sign per kernel, instead
of a signed kernel plus an unsigned initramfs plus a command line anyone at the
keyboard can edit. `sbctl` signs it, and a pacman hook re-signs after every
transaction that could have changed a boot payload.

`loader.conf` sets `editor no`. Allowing command-line editing at the boot menu
on a machine with Secure Boot and full-disk encryption would let anyone with the
keyboard append `init=/bin/sh`. The supported way in is the rescue entry, which
requires the LUKS passphrase like everything else.

## Rollback is a rename

Loom mounts the root filesystem with `rootflags=subvol=@`. This matters more than
it sounds: naming a subvolume explicitly means the Btrfs *default subvolume* is
ignored — and the default subvolume is precisely the mechanism `snapper rollback`
manipulates. On a system mounted this way, `snapper rollback` appears to succeed
and changes nothing at all.

So `loomctl rollback` does the operation that actually takes effect:

1. mount the Btrfs top level (`subvolid=5`), where `@` and `@snapshots` are
   ordinary directories
2. rename `@` to `@.broken-<timestamp>` — kept, not deleted
3. create a new writable `@` from `@snapshots/<N>/snapshot`
4. reboot

Renaming the live root subvolume while it is mounted is legal on Btrfs: the
running system keeps using it by inode. Anything written between the rename and
the reboot lands in the discarded copy, which is why `loomctl rollback` offers to
reboot immediately.

`loomctl prune-broken` cleans up the subvolumes left behind, once you are sure.

### Why `@snapshots` is a top-level subvolume

If snapshots lived inside `@` — which is what `snapper create-config` does by
default — then replacing `@` would replace the snapshots too, and the first
rollback would leave you with nothing to roll back to next time. `bootstrap.sh`
deletes the nested subvolume snapper creates and mounts the top-level
`@snapshots` at `/.snapshots` instead. `loomctl health` checks this, because it is
the kind of mistake that is invisible until the day it matters.

`@log` and `@cache` are separate for a related reason: the logs explaining why an
upgrade failed are worthless if the rollback reverts them, and a package cache is
not worth snapshotting at all.

## The rescue image carries its own tools

`loom-rescue.efi` is a second unified kernel image, built from the same kernel by
`/etc/mkinitcpio-rescue.conf`. Its initramfs contains `cryptsetup`,
`btrfs-progs`, `blkid`, `chroot` and a bash rescue shell. It is deliberately not
systemd-based and deliberately not `autodetect`-trimmed.

Its runtime hook never mounts the root filesystem. It takes over in early
userspace and presents a menu: unlock LUKS, list snapshots, roll back, or chroot
into the installed system to repair it by hand. Because it reads nothing off the
root filesystem to start, it still works when the root filesystem is the problem
— which is the only situation in which anyone ever boots a rescue image.

It is rebuilt by a pacman hook on every kernel change. A rescue image built
against 6.16 modules cannot read a 6.17 machine's disks, and a rescue image that
does not work is worse than none, because you find out at the worst moment.

## Updates are prefetched

`loom-update-prefetch.timer` runs `pacman -Syuw` daily on idle and on AC power.
It downloads and installs nothing. By the time you run `loomctl update`, the
packages are already in the cache and the upgrade is local: no waiting on a
mirror, no half-downloaded transaction if the network drops.

`loomctl update` then:

1. refuses to proceed if `informant` reports unread Arch news — on a rolling
   release the news *is* the changelog, and the handful of manual interventions
   Arch has ever required were all announced there
2. refreshes the mirrorlist with `reflector`, at most once a day
3. lets `snap-pac` put a pre/post snapshot around the transaction
4. runs `pacman -Syu`
5. rebuilds and re-signs the kernel images if the kernel changed
6. reports what needs attention: `.pacnew` files, failed units, whether a reboot
   is needed, how much room is left on the ESP

Step 6 exists because the usual way a rolling release bites is not a dramatic
failure. It is three months of ignored `.pacnew` files and an ESP with no space
for the next kernel.

## What Loom is not

- **Not immutable.** `pacman -S` works normally. An atomic A/B image system is a
  coherent design, but it means installing applications through Flatpak and
  containers, which sits badly with a system whose applications are all terminal
  programs.
- **Not a rice.** The palette is 16 values in one file, referenced by index
  everywhere. Change `/usr/share/loom/console/palette` and the whole system
  follows.
- **Not a fork of Arch.** There is no patched package, no custom repository and
  no mirror. `loom-base` is configuration and five scripts; everything else is
  Arch, from Arch's servers. If Loom disappears, you still have an Arch machine.
