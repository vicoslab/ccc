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
# No "password" entry: the proxy runs with tcp-auth=none (see the xpra-proxy-html5 service),
# so the HTML5 client must NOT expect an authentication challenge. Setting a password here
# makes the client wait for a challenge the proxy never sends. Access control is handled by
# the front proxy (FRP) and the network.
ssl = true
EOF


# Land the bare URL on the connection form (connect.html) instead of index.html.
# index.html is the auto-connecting client: opened with no parameters it immediately
# starts an empty seamless session (blank screen). connect.html is the form that lets
# the user pick "Start Command" / "Start Desktop" / connect to an existing display, and
# it submits back to index.html with submit=true. So we redirect any parameter-less
# (submit!=true) load of index.html to the form, while real connections pass through.
XPRA_INDEX=/usr/share/xpra/www/index.html
if [ -f "$XPRA_INDEX" ] && ! grep -q "ccc-landing-redirect" "$XPRA_INDEX"; then
	sed -i '0,/<head>/s##<head>\n<script id="ccc-landing-redirect">if(new URLSearchParams(location.search).get("submit")!=="true"){location.replace("connect.html");}</script>#' "$XPRA_INDEX"
fi


echo "XPRA configuration completed."

