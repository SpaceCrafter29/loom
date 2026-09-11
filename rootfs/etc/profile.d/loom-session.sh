# shellcheck shell=bash
# Start the Loom session on the session TTY. All the gating lives in
# loom-session itself so that bash and fish can share one implementation.
#
# Exit code 0 means the session ran and ended, and the login shell should go
# away with it. 64 means "not this login". 70 means it failed, and we stay in a
# plain shell on purpose.

case $- in
    *i*) ;;
    *) return ;;
esac

if [ -x /usr/local/bin/loom-session ]; then
    /usr/local/bin/loom-session autostart
    if [ $? -eq 0 ]; then
        exit 0
    fi
fi
