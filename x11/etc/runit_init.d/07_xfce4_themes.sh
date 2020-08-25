#!/bin/bash

USER_NAME=${USER_NAME:-user}
USER_HOME=${BASE%"/"}/$USER_NAME

export HOME=$USER_HOME
chpst -u $USER_NAME '/etc/setup_xfce4_themes.sh'
echo "XFCE4 themes setup complete."

