# Installing

## Requirements

- **UEFI.** Not negotiable: unified kernel images and Secure Boot do not exist
  under legacy BIOS. Turn off CSM / legacy boot in the firmware. The installer
  refuses to run otherwise, and says why.
- x86-64, 4 GB RAM, 20 GB disk (40 GB if you want the dev and graphics groups).
- A wired connection, or wifi you can bring up with `nmtui`.

## From the ISO

Write the image and boot it:

```bash
sudo dd if=loom-2026.09.11-x86_64.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

The medium autologs in as root on `tty1` and prints what to do. Get a network
first (`ip a` for wired, `nmtui` for wifi), then:

```bash
loom-install --dry-run
```

That asks every question, prints the complete plan, and exits without touching a
disk. Read the plan. When it says what you expect:

```bash
loom-install
```

It will not write anything until you have typed the full disk path back to it.

### What it asks

| | |
|---|---|
| disk | erased completely |
| hostname, username | the user gets `wheel`, `video`, `input`, `audio`, `storage`, `lp` |
| timezone, locale, keymap | timezone is guessed from your IP, and the guess is editable |
| LUKS2 encryption | default yes |
| swapfile size | default 0 — zram already gives you compressed swap in RAM. A disk swapfile is only worth it for hibernation, which needs at least as much swap as RAM |
| Secure Boot | default yes; skipped gracefully if the firmware is not in Setup Mode |
| package groups | dev (toolchains, podman), laptop (TLP, fwupd), gui (cage, river, firefox) |

Passwords are set by running `passwd` inside the new system. They are never read
into a shell variable, written to a file, or logged.

## The disk layout

```
/dev/sdX1   1 GiB    EFI system partition, FAT32        -> /efi
/dev/sdX2   rest     LUKS2 (argon2id) -> Btrfs
```

Inside the Btrfs filesystem:

| subvolume | mountpoint | why it is separate |
|---|---|---|
| `@` | `/` | the system; this is what a rollback replaces |
| `@home` | `/home` | your files, never touched by a rollback |
| `@snapshots` | `/.snapshots` | top level, so a rollback of `@` cannot destroy the snapshots |
| `@log` | `/var/log` | the logs that explain a failed upgrade must survive the rollback |
| `@cache` | `/var/cache` | no point snapshotting a package cache |
| `@containers` | `/var/lib/containers` | `nodatacow`: copy-on-write plus an overlay store fragments badly |
| `@swap` | `/swap` | only if you asked for a swapfile; `nodatacow`, which a Btrfs swapfile requires |

Mount options: `noatime,compress=zstd:1,ssd,discard=async,space_cache=v2`.
`zstd:1` is the level where compression is still faster than the disk it saves
writes to.

## Boot layout

```
/efi/EFI/loom/loom-linux.efi            normal boot
/efi/EFI/loom/loom-linux-fallback.efi   same, every module, no autodetect
/efi/EFI/loom/loom-rescue.efi           offline rollback and repair
/efi/EFI/systemd/systemd-bootx64.efi     the bootloader
/efi/loader/loader.conf                  3s menu, editor off
```

The kernel command line is embedded in each image and lives in
`/etc/kernel/cmdline`:

```
rd.luks.name=<LUKS-UUID>=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet loglevel=3 nowatchdog
```

Change that file, then `sudo loomctl rebuild-boot`. Nothing else reads it.

## Onto an existing Arch install

`bootstrap.sh` installs packages, lays down configuration and enables services.
It never partitions a disk, never changes your bootloader, and never rewrites a
kernel command line it did not write.

```bash
git clone <repo> loom && cd loom
sudo ./scripts/bootstrap.sh --dry-run        # read this first
sudo ./scripts/bootstrap.sh --user "$USER"
```

Options: `--no-gui`, `--no-dev`, `--no-laptop`, `--aur`, `--yes`.

It adapts to what it finds:

- **Root is not Btrfs** — everything works except snapshots and rollback. It says
  so and continues.
- **No ESP at `/efi`** — it skips boot configuration entirely rather than guess.
  If your ESP is at `/boot`, either move it, or adapt
  `/usr/share/loom/boot/linux.preset` yourself.
- **No `/etc/kernel/cmdline`** — it will not invent one. It points you at
  `/usr/share/loom/boot/cmdline.example` and tells you to run
  `loomctl rebuild-boot` afterwards.
- **`/.snapshots` already exists** — it unmounts it, lets `snapper create-config`
  do its thing, deletes the nested subvolume snapper creates, and remounts the
  top-level `@snapshots`.

Re-running it is safe and is the intended way to pick up changes to the repo.
Existing files in `~/.config` are never overwritten.

## First boot

1. LUKS passphrase.
2. Log in as your user on `tty1`. zellij starts by itself — that is the session.
3. `loomctl health`. Expect one or two warnings on a fresh install: Secure Boot
   is not enabled in the firmware yet, and there is only the one baseline
   snapshot.
4. If you chose Secure Boot and the keys were enrolled, reboot into the firmware
   and turn Secure Boot on. If it was not in Setup Mode at install time, see
   [secure-boot.md](secure-boot.md).

## If it does not boot

1. Pick **Loom Rescue** in the boot menu. It asks for your LUKS passphrase, then
   offers to list snapshots, roll back, or chroot into the system.
2. If the boot menu itself does not appear, the firmware is booting something
   else. Check the boot order; `efibootmgr -v` from any live medium shows it.
3. If the firmware rejects the kernel image, Secure Boot is on with keys that do
   not match. Turn Secure Boot off, boot, and run `sudo loomctl sign-boot`.
