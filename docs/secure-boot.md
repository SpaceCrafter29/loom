# Secure Boot, and TPM2 unlock

## What this actually protects you from

Full-disk encryption protects data when the machine is off. Secure Boot protects
the *boot path* when the machine is on: it stops the firmware executing a kernel
image that has been modified or replaced.

The two together close a specific attack. Without Secure Boot, an attacker with
physical access can replace your kernel image with one that captures the LUKS
passphrase the next time you type it, and hand the disk back unchanged. The
firmware refusing to run an unsigned image is what makes that attempt fail.

With Loom's layout the signature covers the kernel, the initramfs, the microcode
*and* the command line, because all four are one PE binary. This is why
`loader.conf` sets `editor no`: there would be little point signing the command
line if anyone at the keyboard could type a different one.

## Setting it up

`loom-install` does this for you if the firmware is in Setup Mode. If it was not,
or you used `bootstrap.sh`, here is the whole procedure.

**1. Put the firmware in Setup Mode.** Reboot into firmware setup, find the
Secure Boot section, and clear the existing keys. The wording varies: "Delete all
Secure Boot variables", "Erase all Secure Boot settings", or "Restore Factory
Keys" followed by a delete. You want `sbctl status` to report
`Setup Mode: Enabled`.

**2. Create and enrol your keys.**

```bash
sbctl status
sudo sbctl create-keys
sudo sbctl enroll-keys -m
```

`-m` keeps Microsoft's certificates enrolled alongside yours. **Do not omit it**
unless you know your hardware does not need it. Many machines have option ROMs —
including, on some laptops, the one that drives the display — signed only by
Microsoft. Enrolling without `-m` on such a machine can leave you with no video
output, which is a difficult thing to debug on a machine with no video output.

**3. Sign everything and verify.**

```bash
sudo loomctl rebuild-boot   # rebuilds both kernel images, the rescue image, and signs
sudo sbctl verify
```

`sbctl verify` should list every file as signed. If a file is missing, look at
`ls /efi/EFI/Linux`.

**4. Turn Secure Boot on** in the firmware, and reboot.

```bash
sbctl status        # Secure Boot: Enabled
loomctl health
```

## Staying signed

Two pacman hooks keep this true without you thinking about it:

- `60-loom-rescue-uki.hook` rebuilds `loom-rescue.efi` whenever the kernel,
  firmware or initcpio files change.
- `95-loom-sign-boot.hook` runs `loom-sign-boot` after any transaction that could
  have touched a boot payload. It adds new files to sbctl's database and re-signs
  anything whose contents changed.

`loom-sign-boot` is a deliberate no-op when no keys exist, so neither hook breaks
a machine that has not set Secure Boot up.

## Recovering

**The firmware refuses to boot anything after enrolling keys.** Turn Secure Boot
off in the firmware. The machine boots normally — the images are still valid
EFI binaries. Then `sudo sbctl verify` to find what is unsigned, and
`sudo loomctl rebuild-boot`.

**You are locked out of the firmware setup.** Clearing the CMOS resets Secure
Boot variables on most consumer hardware. Consult the board manual.

**A firmware update re-enrolled the vendor keys.** Your keys are still in
`/var/lib/sbctl`, so re-enrol and re-sign:

```bash
sudo sbctl enroll-keys -m
sudo loomctl sign-boot
```

**Keep a copy of `/var/lib/sbctl`.** It holds your platform key. Losing it means
clearing Secure Boot in the firmware and starting over, which is annoying rather
than fatal — but back it up somewhere that is not the encrypted disk it protects.

## TPM2 unlock

With Secure Boot enforcing signed kernel images, the TPM can hold the LUKS key
and release it only when the firmware is in the expected state. You get full-disk
encryption without typing a passphrase at every boot.

Loom does not enable this by default, and the reason matters.

```bash
# Enrol a recovery passphrase FIRST. Without it, a firmware update can lock
# you out of your own disk permanently.
sudo systemd-cryptenroll --recovery-key /dev/nvme0n1p2

# Then bind to the TPM.
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/nvme0n1p2
```

No change to the kernel command line is needed: `systemd-cryptsetup` finds the
TPM2 token in the LUKS2 header by itself. That is one of the things the
systemd-based initramfs buys.

**On the choice of PCRs.** PCR 7 records the Secure Boot policy. Binding to it
means the TPM releases the key only while Secure Boot is on with your keys
enrolled — which, combined with signed images, is a meaningful guarantee.

The stronger choice is PCR 11, which measures the kernel image itself. It is also
a recurring maintenance problem: every kernel upgrade changes the measurement, so
the enrolment must be recomputed with `systemd-measure` / `systemd-pcrlock` as
part of the upgrade, and any mismatch means falling back to the passphrase. If you
want that, read `man systemd-pcrlock` properly first. PCR 7 alone is the
pragmatic choice, and `--recovery-key` is the part nobody should skip.

**Understand the trade.** TPM2 unlock means the disk decrypts itself when the
machine powers on. A thief who takes the whole laptop gets a machine that boots
to your login prompt — so your user password is now the only thing protecting
your data at rest. That is a reasonable trade for a desktop and a questionable
one for something that travels. Decide deliberately, and read
[tty.md](tty.md#autologin) before you also turn on console autologin.
