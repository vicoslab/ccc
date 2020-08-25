#!/bin/bash

USER_NAME=${USER_NAME:-user}
USER_HOME=${BASE%"/"}/$USER_NAME

export HOME=$USER_HOME
chpst -u $USER_NAME '/etc/setup_jupyter.sh'
echo "Jupyter setup complete."

