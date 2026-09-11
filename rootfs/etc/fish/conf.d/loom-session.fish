# See /etc/profile.d/loom-session.sh -- same contract, fish syntax.
if status is-interactive
    if test -x /usr/local/bin/loom-session
        /usr/local/bin/loom-session autostart
        if test $status -eq 0
            exit 0
        end
    end
end
