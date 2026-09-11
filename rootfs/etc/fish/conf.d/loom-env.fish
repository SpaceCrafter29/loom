# Loom environment defaults for fish.
set -gx EDITOR nvim
set -gx VISUAL nvim
set -gx PAGER less
set -gx MANPAGER 'nvim +Man!'
set -gx LESS '-R -F -i -M -S -X -z-4'
set -gx SYSTEMD_PAGER ''

if test "$TERM" = linux
    set -gx LOOM_CONSOLE 1
    set -e COLORTERM
else
    set -gx COLORTERM truecolor
end

if status is-interactive
    # eza knows about colours; ls does not need to be reinvented beyond this.
    if command -q eza
        alias ls 'eza --group-directories-first'
        alias ll 'eza -l --git --group-directories-first'
        alias la 'eza -la --git --group-directories-first'
        alias lt 'eza --tree --level=2'
    end
    command -q bat; and alias cat bat
    command -q zoxide; and zoxide init fish | source
    command -q starship; and starship init fish | source

    abbr -a u 'sudo loomctl update'
    abbr -a h 'loomctl health'
    abbr -a snaps 'loomctl snapshots'
    abbr -a g git
    abbr -a lg lazygit
end
