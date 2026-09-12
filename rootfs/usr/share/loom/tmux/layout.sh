#!/usr/bin/env bash
# Loom, by SpaceCrafter29 -- https://github.com/SpaceCrafter29/loom
# Build Loom's default tmux layout.
#
#   layout.sh [session]     lay out SESSION, or "loom" if not given
#
# zellij reads layouts/loom.kdl and builds four tabs from it. tmux has no
# declarative layout -- a layout there is a sequence of commands -- so this is
# that file's counterpart, and tools/check.sh checks the two describe the same
# four windows.
#
# It is idempotent: a session that already has more than one window is left
# exactly as it is. That matters because loom-session runs this on every create
# and a reattach must never duplicate anybody's windows.

set -uo pipefail

SESSION="${1:-loom}"

note() { printf 'loom-layout: %s\n' "$*" >&2; }

command -v tmux >/dev/null 2>&1 || { note "tmux is not installed"; exit 1; }

# "=name" is an exact match. Without the =, tmux prefix-matches, and a session
# called "loomy" would answer for "loom".
tmux has-session -t "=$SESSION" 2>/dev/null || { note "no session '$SESSION'"; exit 1; }

if (( $(tmux list-windows -t "=$SESSION" 2>/dev/null | grep -c .) > 1 )); then
    exit 0
fi

# A window opened on a command that is not installed exits at once and takes
# the window with it, which would leave the layout with holes in it. Every
# command below is checked first, and a missing one leaves a plain shell under
# the right name rather than nothing at all.
window() {
    local name=$1 cmd=${2:-}
    if [[ -z $cmd ]]; then
        tmux new-window -t "=$SESSION" -n "$name"
        return 0
    fi
    if ! command -v "${cmd%% *}" >/dev/null 2>&1; then
        tmux new-window -t "=$SESSION" -n "$name"
        tmux send-keys -t "=$SESSION:$name" "# ${cmd%% *} is not installed"
        return 0
    fi
    tmux new-window -t "=$SESSION" -n "$name" "$cmd"
}

# The first window already exists -- new-session made it -- so it gets renamed
# rather than created. By id, because base-index may be 0 or 1.
first=$(tmux list-windows -t "=$SESSION" -F '#{window_id}' | head -n1)
tmux rename-window -t "$first" shell

window files "yazi"

# lazygit outside a repository is an error message and nothing else, which is
# why zellij's layout marks this tab start_suspended. The tmux equivalent is to
# type the command and not press enter: the window is ready, you decide when.
window git
tmux send-keys -t "=$SESSION:git" "lazygit"

# btop on the left, a shell on the right: split_direction="vertical" in the
# zellij layout, -h here, same two panes either way.
window sys "btop"
sys_left=$(tmux list-panes -t "=$SESSION:sys" -F '#{pane_id}' | head -n1)
tmux split-window -h -t "=$SESSION:sys"
tmux select-pane -t "$sys_left"

# Land in the shell. It is the one you live in.
tmux select-window -t "$first"
