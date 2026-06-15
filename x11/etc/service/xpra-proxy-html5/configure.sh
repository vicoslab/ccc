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

if [ -z "${XPRA_PROXY_HTML5_PORT}" ]; then
	exit 1
fi

mkdir -p $LOG_DIR

# wait a few sec to ensure dbus is started
while [ -z "$(sv status dbus | grep pid)" ] ; do sleep 3; sv start dbus 2> /dev/null ; done
