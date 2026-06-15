#!/bin/sh -e

USER_NAME=${USER_NAME:-user}
USER_HOME=${BASE%"/"}/$USER_NAME
USER_ID=$(id -u "$USER_NAME")

# need to set HOME to user 
export HOME=$USER_HOME
export XDG_RUNTIME_DIR="/run/user/${USER_ID}"

# Xpra expects private per-user runtime/socket directories (0700).
umask 077

LOG_DIR=$USER_HOME/.xpra

# CCC's Xpra proxy convention is port 8888. Default rather than silently
# exiting so runit failures are easier to diagnose when the env is incomplete.
XPRA_PROXY_HTML5_PORT=${XPRA_PROXY_HTML5_PORT:-8888}
export XPRA_PROXY_HTML5_PORT

# CCC terminates HTTPS before the container, so Xpra sees browser traffic as
# plain WebSocket (ws). Xpra 5 uses a separate ProxyInstanceProcess for ws,
# which is fragile in containers because the live client socket is handed to a
# child process. Force threaded proxying like Xpra already does for wss/ssl.
export XPRA_PROXY_INSTANCE_THREADED=${XPRA_PROXY_INSTANCE_THREADED:-1}
export XPRA_PROXY_SOCKET_TIMEOUT=${XPRA_PROXY_SOCKET_TIMEOUT:-5}
export XPRA_PROXY_WS_TIMEOUT=${XPRA_PROXY_WS_TIMEOUT:-10}

mkdir -p $LOG_DIR
PROXY_LOG="$LOG_DIR/${HOSTNAME:-$(hostname)}-xpra-proxy.log"
export PROXY_LOG
touch "$PROXY_LOG"
chown "$USER_NAME:$USER_NAME" "$LOG_DIR" "$PROXY_LOG" 2>/dev/null || true
chmod 700 "$LOG_DIR" 2>/dev/null || true
chmod 600 "$PROXY_LOG" 2>/dev/null || true

# wait a few sec to ensure dbus is started
while [ -z "$(sv status dbus | grep pid)" ] ; do sleep 3; sv start dbus 2> /dev/null ; done
