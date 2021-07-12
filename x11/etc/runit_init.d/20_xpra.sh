#!/bin/bash

USER_NAME=${USER_NAME:-user}
USER_HOME=${BASE%"/"}/$USER_NAME
USER_ID=`id -u $USER_NAME`

export HOME=$USER_HOME

mkdir -p "/run/user/${USER_ID}" 
mkdir -p "/run/xpra"

chown $USER_NAME:$USER_NAME "/run/user/${USER_ID}"
chown $USER_NAME:$USER_NAME "/run/xpra"
chown $USER_NAME:$USER_NAME "$HOME/.xpra"

cat >/usr/local/bin/krusader-x11 << EOF
#!/bin/bash 

KDE_SESSION_VERSION=5 KDE_FULL_SESSION=true XDG_CURRENT_DESKTOP=kde krusader
EOF

chmod +x /usr/local/bin/krusader-x11

echo "XPRA configuration completed."

