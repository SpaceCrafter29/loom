# Keys, and where everything lives

## Virtual terminals

| | |
|---|---|
| `Ctrl+Alt+F1` | the session — zellij, or tmux if you have switched |
| `Ctrl+Alt+F2` … `F6` | plain login shells. These always work |

## zellij

Loom keeps zellij's defaults and adds five bindings. The status bar shows the
current mode and its keys, which is why `simplified_ui` is on rather than off.

**Modes** — press the key, then act:

| | |
|---|---|
| `Ctrl+p` | pane mode: `n` new, `x` close, `d` split down, `r` split right, `f` fullscreen |
| `Ctrl+t` | tab mode: `n` new, `x` close, `r` rename, `1`–`9` go to tab |
| `Ctrl+n` | resize mode: `hjkl` to resize |
| `Ctrl+h` | move mode: move the focused pane |
| `Ctrl+s` | search and scroll: `/` search, `PgUp`/`PgDn`, `e` open the scrollback in `$EDITOR` |
| `Ctrl+o` | session mode: `d` detach, `w` session manager |
| `Ctrl+g` | lock mode — passes every key through to the application. Press again to unlock |
| `Esc` or `Enter` | back to normal mode |

**Loom's additions** — these open a new pane running the thing:

| | |
|---|---|
| `Alt+f` | `yazi`, the file manager |
| `Alt+g` | `lazygit` |
| `Alt+m` | `btop` |
| `Alt+w` | `loomctl web` — the browser, under its own compositor |
| `Alt+h` | `loomctl health` |

**Navigation without a mode:** `Alt+h/j/k/l` moves focus between panes,
`Alt+n` opens a new pane, `Alt+[`/`Alt+]` cycles layouts, `Alt+=`/`Alt+-`
resizes.

Detaching (`Ctrl+o d`) leaves the session running. Log back in on `tty1` and
`loom-session` reattaches you to it.

## tmux

The other multiplexer. `packages/session.txt` installs both and Loom configures
both; which one owns `tty1` is one line in `/etc/loom/loom.conf`:

```bash
sudoedit /etc/loom/loom.conf     # LOOM_MULTIPLEXER="tmux"
```

It takes effect at the next login on `tty1`. A session that is already running
is not migrated — log out, or `loom-session` by hand.

The prefix is `Ctrl+b`, tmux's own, left alone for the same reason Loom leaves
zellij's defaults alone: every tmux answer you will ever find assumes it.

| | |
|---|---|
| `Ctrl+b` then `c` / `,` / `&` | new window / rename / close |
| `Ctrl+b` then `\|` / `-` | split right / split down. `%` and `"` still work |
| `Ctrl+b` then `z` | zoom the pane, and again to unzoom |
| `Ctrl+b` then `[` | copy mode — `v` select, `y` copy, `q` out. `]` pastes |
| `Ctrl+b` then `d` | detach. Logging back in on `tty1` reattaches you |
| `Ctrl+b` then `r` | reload `~/.config/tmux/tmux.conf` |
| `Ctrl+b` then `H` `J` `K` `L` | resize, repeatable — hold the prefix once and keep tapping |

**Without the prefix:**

| | |
|---|---|
| `Alt+←` `↓` `↑` `→` | move focus between panes |
| `Alt+1` … `Alt+9` | go to that window |
| `Alt+f` `Alt+g` `Alt+m` `Alt+w` `Alt+h` | the same five as zellij: `yazi`, `lazygit`, `btop`, `loomctl web`, `loomctl health` |

Those five open a *window* rather than a pane, which is the one place the two
multiplexers deliberately differ: on an 80×25 console a half-height `btop` is
not worth looking at. `Ctrl+b` then `w` brings you back.

Mouse selection copies on release, as it does in zellij. The buffer is tmux's
own — there is no clipboard behind a VT — so paste with `Ctrl+b` `]` and list
what you have with `Ctrl+b` `b`.

`tools/check.sh` fails if the two configs disagree about those five keys, or if
the tmux config ever names a colour in hex instead of by palette index.

## The default layout

Both multiplexers open the same four, because four fit in a console status bar
without wrapping:

| tab | what is in it |
|---|---|
| `shell` | an empty shell. This is where you live |
| `files` | `yazi` |
| `git` | `lazygit`, suspended — press Enter to start it, since it needs a repo |
| `sys` | `btop` on the left, a shell on the right |

Edit `~/.config/zellij/layouts/loom.kdl`. To start from the shipped version
again, delete yours and copy `/usr/share/loom/zellij/layouts/loom.kdl` back.

tmux has no declarative layout — a layout there is a sequence of commands — so
its copy of those four windows is `/usr/share/loom/tmux/layout.sh`, which
`loom-session` runs once when it creates the session. It does nothing to a
session that already has its windows, so reattaching never duplicates them.

## loomctl

```
sudo loomctl update [--aur] [--dry-run]   upgrade: news, snapshot, pacman, re-sign
sudo loomctl prefetch                     download pending updates now
sudo loomctl news                         read the news gating an upgrade

     loomctl snapshots                    list snapshots of / and /home
sudo loomctl snapshot "before X"          take one now
sudo loomctl rollback [N]                 rebuild / from a snapshot, then reboot
sudo loomctl prune-broken                 delete roots left by past rollbacks

sudo loomctl rebuild-boot                 regenerate and re-sign every kernel image
sudo loomctl sign-boot                    re-sign the ESP only

     loomctl gui                          start the river session on this VT
     loomctl gui firefox                  one app under cage, nothing else
     loomctl web [url]                    the browser, same thing
     loomctl health                       check boot, rollback and system state
     loomctl version
     loomctl aur-install <pkg>...         build from the AUR with paru
```

## Shell

fish, with `starship`, `zoxide` and `eza`. Abbreviations expand as you type them,
so you can see what they became:

| | |
|---|---|
| `u` | `sudo loomctl update` |
| `h` | `loomctl health` |
| `snaps` | `loomctl snapshots` |
| `g` / `lg` | `git` / `lazygit` |
| `ls` `ll` `la` `lt` | `eza`, plain / long / all / tree |
| `cat` | `bat` |
| `z <dir>` | `zoxide`, jumps to a directory you have visited |

## neovim

No plugin manager: a system editor that cannot start because a lockfile is stale
is not an editor. Leader is `Space`.

| | |
|---|---|
| `<leader>w` / `<leader>q` | write / quit |
| `<leader>e` | file explorer (netrw) |
| `<leader>b` | switch buffer |
| `<leader>/` | `:grep`, wired to ripgrep |
| `<leader>lc` / `<leader>lz` / `<leader>lt` | edit `loom.conf` / zellij's config / tmux's |
| `Ctrl+h/j/k/l` | window movement without the `Ctrl+w` prefix |
| `Esc` | clear search highlight |

Put your own config in `~/.config/nvim/lua/local.lua`. It is loaded with `pcall`,
so a syntax error in it cannot stop neovim from starting.

## Where things live

| | |
|---|---|
| `/etc/loom/loom.conf` | every knob Loom itself reads |
| `/etc/kernel/cmdline` | the kernel command line, embedded into the images |
| `/usr/share/loom/console/palette` | the 16 colours the whole system uses |
| `/usr/share/loom/zellij/` | the shipped session config and layout |
| `/usr/share/loom/tmux/` | the same, for tmux: `tmux.conf` and `layout.sh` |
| `/usr/share/loom/boot/` | mkinitcpio presets and the cmdline example |
| `/usr/share/loom/rescue/rescue.sh` | the rescue shell, also embedded in the rescue image |
| `/usr/share/loom/optional/` | things you can opt into, like autologin |
| `/usr/share/loom-payload/` | the package lists and `bootstrap.sh`, on an installed system |
| `/usr/local/bin/loom*` | `loomctl`, `loom-session`, `loom-gui`, `loom-sign-boot`, `loom-build-rescue` |
| `/efi/EFI/Linux/` | the kernel images, including `loom-rescue.efi` |
| `/.snapshots/` | snapper's snapshots of `/`, on their own subvolume |
| `/var/log/loom-setup.log` | what `bootstrap.sh` did |
| `~/.local/state/loom/gui.log` | what the last `loomctl gui` printed |

## Hardware, without a GUI

| | |
|---|---|
| network | `nmtui`, or `nmcli device wifi connect <ssid> --ask` |
| audio | `pulsemixer` |
| bluetooth | `bluetoothctl` — `scan on`, `pair <mac>`, `connect <mac>`. Or `bluetuith` from the AUR |
| brightness | `brightnessctl set 50%` |
| printing | `lpstat -p`, `lpr file.pdf`. The CUPS web UI works in `w3m http://localhost:631` |
| firmware | `fwupdmgr refresh && fwupdmgr get-updates` |
| battery | `tlp-stat -b`, `powertop` |
| disks | `lsblk -f`, `smartctl -a /dev/nvme0`, `ncdu /` |
