# Living on the console

Loom's session runs on a Linux virtual terminal, not in a graphical terminal
emulator. That has four real consequences. Pretending otherwise is how a
terminal-first system ends up looking broken, so here is each one and what Loom
does instead.

## 1. Sixteen colours. That is the whole palette.

The kernel console has a 16-entry colour table. Not 256, not 24-bit. Anything
emitting truecolour escape sequences gets them silently ignored or crudely
approximated, which is why most modern colourschemes look like mud on a TTY.

**What Loom does:** reprograms the 16 entries and then refers to them *by index*
everywhere.

`/usr/share/loom/console/palette` holds three lines — all the reds, all the
greens, all the blues — and `loom-console-palette.service` applies it with
`setvtrgb` at boot. The table and its hex values are documented in
`palette.md` next to it.

Every theme in the system points at those indices rather than at hex values:

- zellij's `loom` theme uses `fg 7`, `bg 0`, `red 1` …
- tmux's config names `colour0`–`colour15` and nothing else; `tools/check.sh`
  fails if a hex value ever appears in it
- neovim sets `termguicolors = false` when `$TERM` is `linux` and uses the
  16-colour `vim` scheme
- btop runs with `truecolor = False` and `force_tty = True`
- starship's config uses colour *names*, which resolve to the palette

So recolouring the entire system is editing one file and restarting one service:

```bash
sudoedit /usr/share/loom/console/palette
sudo systemctl restart loom-console-palette
```

Inside a graphical terminal the same configs switch to truecolour — neovim's
config branches on `$TERM`, and `/etc/profile.d/loom-env.sh` only exports
`COLORTERM=truecolor` when it is not on the console.

## 2. No nerd-font glyphs

The console loads a PSF bitmap font — Terminus, `ter-132b` by default — with a
few hundred glyphs. Powerline separators, nerd-font icons and most emoji are not
among them. They render as empty boxes.

**What Loom does:** every shipped config is ASCII or plain Unicode.
`simplified_ui true` in zellij's config switches its status bar to plain
characters, and tmux's status bar is built out of ASCII for the same reason;
starship's prompt is `>` rather than a chevron glyph; btop's `rounded_corners`
is off; neovim's `fillchars` and `listchars` branch on `$TERM`.

Font too large or too small for your panel:

```bash
setfont ter-116b          # try it now
sudoedit /etc/vconsole.conf   # FONT=ter-116b to keep it
```

`ter-132b` suits a HiDPI laptop panel. `ter-116b` or `ter-118b` suit 1080p.

## 3. No inline images, and no graphical clipboard

Sixel and kitty-graphics do not exist on a VT, and there is no X or Wayland
clipboard to share with.

What works instead:

| | |
|---|---|
| images | `chafa picture.png` — Unicode half-blocks, 16 colours. Rough, but it tells you which photo it is |
| images, properly | `fbv` from the AUR draws real pixels straight to the framebuffer |
| video | `mpv --vo=drm video.mkv` plays full screen on the bare console. No compositor needed |
| PDFs | `pdftotext doc.pdf -` for the text, `loomctl gui zathura doc.pdf` to actually look at it |
| copy/paste | the multiplexer's own copy mode, within the session. Selecting copies on release in both zellij and tmux |
| mouse | `gpm` is enabled, so selection and middle-click paste work at the console too |

Anything that genuinely needs pixels goes through `loomctl gui <app>`, which is
one keystroke away (`Alt+w` for the browser).

## 4. Truecolour, if you insist

`kmscon` is a DRM-based console replacement with TrueType fonts and 24-bit
colour. It is in `packages/aur.txt` and it does work.

It is also largely unmaintained, and it replaces the one component in this system
that never breaks. The trade is: nicer fonts and real colours, in exchange for
your console now depending on a userspace daemon. Loom's position is that this is
the wrong trade for the thing that has to work when everything else does not —
but the package is listed, and nothing stops you.

The middle path most people end up preferring: stay on the kernel console for
the session, and run `loomctl gui` into a `river` session with `foot` when you
want a modern terminal for an afternoon. Both configs are already installed.

## Autologin

Loom does **not** autologin by default. The template is there:

```bash
sudo install -Dm644 /usr/share/loom/optional/getty-autologin.conf \
     /etc/systemd/system/getty@tty1.service.d/autologin.conf
sudo sed -i "s/%LOOM_USER%/$USER/" \
     /etc/systemd/system/getty@tty1.service.d/autologin.conf
sudo systemctl daemon-reload
```

Think about it first. Full-disk encryption protects the machine when it is off.
Autologin means that once the disk is unlocked, anyone holding the laptop is you.
Combined with TPM2 unlock — see [secure-boot.md](secure-boot.md#tpm2-unlock) —
it means a stolen laptop boots straight into your session. On a desktop that is
fine. On something that travels, leave it off.

## The escape hatch

`tty2` through `tty6` are plain login shells. Always. They read no session
config, start no multiplexer, and cannot be affected by anything you break in
`~/.config`.

`Ctrl+Alt+F2` is the answer to "I broke my session".

And if the multiplexer itself fails to start twice in under five seconds,
`loom-session` writes `/run/loom/no-session`, which disables autostart until the
next reboot and prints the commands to diagnose it. You get a plain shell on
`tty1` with an explanation, rather than a login loop.
