# Updates, and every way to undo one

## The normal path

```bash
sudo loomctl update
```

In order, that:

1. **Checks the news.** If `informant` is installed and there is unread Arch
   news, it stops. On a rolling release the news is the changelog: every manual
   intervention Arch has ever required was announced there first. Read it with
   `sudo loomctl news`. To disable the gate, set `LOOM_REQUIRE_NEWS="0"` in
   `/etc/loom/loom.conf` — but the gate is the single highest-value thing on this
   list.
2. **Refreshes mirrors** with `reflector`, at most once every 24 hours.
3. **Snapshots.** `snap-pac` puts a `pre` and a `post` snapshot around the pacman
   transaction automatically. If `snap-pac` is missing, `loomctl` does it by
   hand.
4. **Upgrades.** `pacman -Syu`. The packages are usually already in the cache —
   see *Prefetching* below — so this is mostly a local operation.
5. **Rebuilds the boot** if the kernel version changed: both unified kernel
   images plus the rescue image, then re-signs everything for Secure Boot.
6. **Reports.** Reboot needed, `.pacnew` files, failed units, ESP space.

Useful variants:

```bash
sudo loomctl update --dry-run    # what is pending, install nothing
sudo loomctl update --aur        # also paru -Sua, as your user, not as root
sudo loomctl update --no-confirm
```

### Prefetching

`loom-update-prefetch.timer` runs `pacman -Syuw` once a day, at idle priority,
only on AC power. It downloads into the package cache and installs nothing.

This is what "fluid updates" means in practice: the slow, failure-prone part of
an upgrade is the download, and it happens while you are not waiting for it. When
you do run `loomctl update`, it is a local transaction that either completes or
does not — no half-downloaded state because the network dropped.

```bash
sudo loomctl prefetch    # do it now
```

## Undoing one

Four levels, cheapest first.

### 1. One package

```bash
ls /var/cache/pacman/pkg/ | grep <name>
sudo pacman -U /var/cache/pacman/pkg/<name>-<old-version>.pkg.tar.zst
```

The cache is why `paccache` is configured to keep the last three versions rather
than clearing aggressively. Add the package to `IgnorePkg` in
`/etc/pacman.conf` until the upstream bug is fixed.

### 2. Some files

```bash
snapper -c root status 42..0          # what changed since snapshot 42
snapper -c root diff 42..0 /etc/foo   # how it changed
sudo snapper -c root undochange 42..0 /etc/foo
```

This reverts specific paths without touching anything else, and is almost always
the right tool when you know what broke.

### 3. The whole system, from the running system

```bash
loomctl snapshots             # list them
sudo loomctl rollback         # pick one interactively
sudo loomctl rollback 42      # or name it
```

This renames `@` to `@.broken-<timestamp>` and recreates `@` from the snapshot.
`/home` is not touched. Reboot immediately afterwards: anything written between
the rename and the reboot goes into the copy that gets thrown away.

The old root is kept, not deleted. Once you are confident:

```bash
sudo loomctl prune-broken
```

> **The kernel is not in the snapshot.** Kernel images live on the ESP, which is
> a FAT filesystem outside Btrfs entirely. Rolling back to a snapshot from before
> a kernel upgrade gives you old modules and a new kernel. If the system then
> fails to boot, use Loom Rescue's chroot and run `loomctl rebuild-boot`.

### 4. The whole system, when it will not boot

Pick **Loom Rescue** in the boot menu.

It is a self-contained initramfs — `cryptsetup`, `btrfs`, `bash` and a rescue
shell, all embedded — that never mounts your root filesystem to get started. The
menu:

```
1  unlock and mount the root filesystem
2  list snapshots
3  roll back to a snapshot
4  chroot into the installed system
5  shell here (initramfs, nothing mounted)
6  reboot
7  power off
```

Option 3 performs the same rename-and-recreate as `loomctl rollback`, reading
snapper's metadata directly out of `info.xml` rather than depending on snapper
being runnable. Option 4 binds `/dev`, `/proc`, `/sys`, `/home` *and the ESP*, so
`mkinitcpio` and `pacman` both work properly inside the chroot.

## Snapshot policy

Set in `/usr/share/loom/snapper/*.settings`, applied with `snapper set-config`:

| | `/` | `/home` |
|---|---|---|
| timeline snapshots | no | yes — 6 hourly, 7 daily, 4 weekly, 2 monthly |
| pacman snapshots | yes, via `snap-pac` | n/a |
| keep | 12 (6 "important") | 20 |
| empty pre/post pairs | cleaned up | n/a |

`/` gets no timeline snapshots because the useful snapshot of a system is "the
moment before pacman touched it", not "every hour". `/home` is the reverse:
nothing in a package transaction touches it, but you edit it all day.

What the snapshots cost:

```bash
sudo btrfs filesystem du -s /.snapshots
sudo btrfs filesystem usage /
```

Cleanup runs on `snapper-cleanup.timer`. If `/` creeps past 85% full,
`loomctl health` says so and points at that command.

## When something is wrong

```bash
loomctl health
```

It checks: kernel images exist and are signed, ESP has room for the next one,
Secure Boot state, `/.snapshots` is actually a separate mount, snapshot count,
Btrfs space, whether the running kernel's modules still exist, failed units,
`.pacnew` files, orphaned packages, and whether the timers are enabled.

Two of those deserve their own explanation.

**"`/.snapshots` is not mounted"** means snapshots are being created *inside* `@`.
The first rollback would then destroy every snapshot, leaving nothing to roll back
to next time. Fix it by adding the fstab entry and re-running `bootstrap.sh`.

**"only N MB free on the ESP"** matters because a unified kernel image is 40–80 MB
and the rescue image is around 100 MB. An ESP that is too full to write the next
kernel is how an upgrade ends with no bootable system. `ls -la /efi/EFI/Linux`
and remove images for kernels you no longer have.
