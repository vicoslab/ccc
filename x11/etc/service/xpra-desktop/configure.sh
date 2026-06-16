#!/bin/sh -e

USER_NAME=${USER_NAME:-user}
USER_HOME=${BASE%"/"}/$USER_NAME
USER_ID=$(id -u $USER_NAME)

# need to set HOME and the runtime dir to the user's
export HOME=$USER_HOME
export XDG_RUNTIME_DIR=/run/user/$USER_ID

LOG_DIR=$USER_HOME/.xpra

mkdir -p $LOG_DIR

# wait a few sec to ensure dbus is started (the desktop session needs it)
while [ -z "$(sv status dbus | grep pid)" ] ; do sleep 3; sv start dbus 2> /dev/null ; done
