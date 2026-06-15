#!/bin/bash

USER_NAME=${USER_NAME:-user}
USER_HOME=${BASE%"/"}/$USER_NAME
USER_ID=$(id -u "$USER_NAME")

export HOME=$USER_HOME
export XDG_RUNTIME_DIR="/run/user/${USER_ID}"

# Xpra 5 is stricter about runtime/socket directory ownership and modes.
# Clean stale sockets from previous container runs before the proxy service starts.
rm -rf "${XDG_RUNTIME_DIR}/xpra"
rm -f /run/xpra/*
rm -f "$HOME/.xpra/${HOSTNAME}-"*
rm -f /tmp/.X11-unix/X[0-9]*

install -d -o "$USER_NAME" -g "$USER_NAME" -m 700 "$XDG_RUNTIME_DIR"
install -d -o "$USER_NAME" -g "$USER_NAME" -m 700 "${XDG_RUNTIME_DIR}/xpra"
install -d -o "$USER_NAME" -g "$USER_NAME" -m 700 "$HOME/.xpra"

if getent group xpra >/dev/null; then
    install -d -o "$USER_NAME" -g xpra -m 775 /run/xpra
else
    install -d -o "$USER_NAME" -g "$USER_NAME" -m 755 /run/xpra
fi

install -d -o root -g root -m 1777 /tmp/.X11-unix

cat >/usr/local/bin/krusader-x11 << EOF
#!/bin/bash 

KDE_SESSION_VERSION=5 KDE_FULL_SESSION=true XDG_CURRENT_DESKTOP=kde krusader
EOF

chmod +x /usr/local/bin/krusader-x11


cat > /usr/share/xpra/www/default-settings.txt << EOF
# Xpra HTML5 default settings
#
# ie:
# port = 10000
# keyboard_layout = gb
# encoding = auto
# bandwidth_limit = 10000000
# debug_keyboard = true
username = $USER_NAME
ssl = true
webtransport = false
exit_with_client = false
exit_with_children = false
EOF


echo "XPRA configuration completed."

