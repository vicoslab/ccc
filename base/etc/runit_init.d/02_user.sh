#!/bin/bash -e

USER_NAME=${USER_NAME:-user}

USER_ID=${USER_ID:-1000}

USER_PUBKEY=${USER_PUBKEY}

USER_HOME=${BASE%"/"}/$USER_NAME

set +e
getent passwd $USER_NAME > /dev/null
EXISTS=$?
set -e

if [ $EXISTS != 0 ]; then
    adduser --uid=$USER_ID --home=$USER_HOME --disabled-password --gecos "" $USER_NAME

    # copy default profile files if they do not exist yet
    # (cannot use -m from adduser since folder many already exist due to mounting)
    chpst -u $USER_NAME cp -r -n /etc/skel/. $USER_HOME/.
fi

CURRENT_HOME_OWNER=$(stat -c '%U' $USER_HOME)

if [ "$CURRENT_HOME_OWNER" != "$USER_NAME" ]; then
    chown $USER_NAME:$USER_NAME $USER_HOME
    chpst -u $USER_NAME chmod 750 $USER_HOME
fi

if [ ! -z "${USER_PUBKEY}" ]; then
    chpst -u $USER_NAME mkdir -p $USER_HOME/.ssh
    echo "${USER_PUBKEY}" | chpst -u $USER_NAME tee $USER_HOME/.ssh/authorized_keys
    chpst -u $USER_NAME chown -R $USER_NAME:$USER_NAME $USER_HOME/.ssh

    chpst -u $USER_NAME chmod 700 $USER_HOME/.ssh
    chpst -u $USER_NAME chmod 600 $USER_HOME/.ssh/authorized_keys
fi

