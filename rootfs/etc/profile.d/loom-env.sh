# Loom environment defaults for POSIX shells.
export EDITOR=nvim
export VISUAL=nvim
export PAGER=less
export MANPAGER='nvim +Man!'
export LESS='-R -F -i -M -S -X -z-4'
export SYSTEMD_PAGER=''

# Keep $HOME tidy.
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"

# The Linux console has 16 colours and no nerd-font glyphs. Anything that asks
# TERM what it can do will now get an honest answer.
if [ "$TERM" = "linux" ]; then
    export LOOM_CONSOLE=1
    export COLORTERM=
else
    export COLORTERM=truecolor
fi
