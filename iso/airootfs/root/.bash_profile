# Runs when the live medium autologs in as root on tty1.

[[ -f ~/.bashrc ]] && . ~/.bashrc

# Only greet on the console, not on an ssh login or a second VT.
if [[ $(tty) == /dev/tty1 ]]; then
    setfont ter-118b 2>/dev/null
    [[ -r /usr/share/loom-payload/rootfs/usr/share/loom/console/palette ]] \
        && setvtrgb /usr/share/loom-payload/rootfs/usr/share/loom/console/palette 2>/dev/null

    printf '\n'
    printf '\033[36;1m   L O O M\033[0m  \033[2minstall medium\033[0m\n'
    printf '\033[2m   by SpaceCrafter29 -- github.com/SpaceCrafter29/loom\033[0m\n'
    printf '\033[2m   ----------------------------------------------------------------\033[0m\n'
    printf '\n'
    printf '   \033[1mloom-install\033[0m              partition, encrypt and install\n'
    printf '   \033[1mloom-install --dry-run\033[0m    ask the same questions, touch nothing\n'
    printf '\n'
    printf '   Before that, you need a network:\n'
    printf '     ethernet    should already be up -- check with \033[1mip a\033[0m\n'
    printf '     wifi        \033[1mnmtui\033[0m\n'
    printf '\n'
    printf '   Other things that are here:\n'
    printf '     \033[1mlsblk\033[0m   disks        \033[1mzellij\033[0m  a multiplexer, if you want panes\n'
    printf '     \033[1mnvim\033[0m    editor       \033[1mbtop\033[0m    what this machine is doing\n'
    printf '\n'
    printf '   \033[1;31mloom-install erases the disk you point it at.\033[0m It shows you the\n'
    printf '   complete plan and makes you type the disk path before it writes.\n'
    printf '\n'

    if [[ ! -d /sys/firmware/efi/efivars ]]; then
        printf '   \033[1;31mThis machine booted in legacy BIOS mode.\033[0m Loom is UEFI-only.\n'
        printf '   Turn off CSM / legacy boot in the firmware and boot this medium again.\n\n'
    fi
fi
