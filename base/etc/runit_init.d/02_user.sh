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

if [ ! -z "${USER_GROUPS}" ]; then
    # split groups into list using ',' as separator
    IFS=',' read -ra USER_GROUPS <<< "${USER_GROUPS}"
    for GRPUP_NAME_ID in "${USER_GROUPS[@]}"
    do
        # split with "=" to get name and id
        IFS='=' read -ra GRPUP_NAME_ID <<< "${GRPUP_NAME_ID}"
        GROUP_NAME=${GRPUP_NAME_ID[0]}
        GROUP_ID=${GRPUP_NAME_ID[1]}
        
        if [ ! -z "${GROUP_ID}" ]; then
            groupadd  -f -g $GROUP_ID $GROUP_NAME
        else
            groupadd  -f $GROUP_NAME
        fi
        usermod -a -G $GROUP_NAME $USER_NAME
    done
fi

CURRENT_HOME_OWNER=$(stat -c '%U' $USER_HOME)

if [ "$CURRENT_HOME_OWNER" != "$USER_NAME" ]; then
    chown $USER_NAME:$USER_NAME $USER_HOME
    chpst -u $USER_NAME chmod 750 $USER_HOME
fi

mutex_user_lock() {
    # wait until all other users finish
    while [ -f "$USER_HOME/user.installing" ]; do sleep 2; done	
    
    # mark in file that user.installing is in installation check
    chpst -u $USER_NAME touch "$USER_HOME/user.installing"
}

mutex_user_unlock() {
    # clear "in installation" flag
    chpst -u $USER_NAME rm "$USER_HOME/user.installing" 2> /dev/null
}

mutex_user_lock

# install SSH keys
if [ ! -z "${USER_PUBKEY}" ]; then
    
    chpst -u $USER_NAME mkdir -p $USER_HOME/.ssh
    echo "${USER_PUBKEY}" | chpst -u $USER_NAME tee $USER_HOME/.ssh/authorized_keys
    chpst -u $USER_NAME chown -R $USER_NAME:$USER_NAME $USER_HOME/.ssh

    chpst -u $USER_NAME chmod 700 $USER_HOME/.ssh
    chpst -u $USER_NAME chmod 600 $USER_HOME/.ssh/authorized_keys
    
fi

# create symlink to local storage for .cache files
if [ ! -z "$LOCAL_SSD_STORAGE" ]; then    
    USER_CACHE=$LOCAL_SSD_STORAGE/$CONTAINER_NAME/.cache
    
    chpst -u $USER_NAME mkdir -p $USER_CACHE
    
    # check if existing folder is not symlink but actual folder -- rename it in case user has something important there
    if [ -d "$USER_HOME/.cache" ] && [! -h "$USER_HOME/.cache" ] ; then
        chpst -u $USER_NAME mv "$USER_HOME/.cache" "$USER_HOME/.cache_backup"
    fi
    
    # check if storage already exist but avoid creating if already there
    if [ ! -f "$USER_HOME/.cache" ] || [ "$(readlink -f $USER_HOME/.cache)" != "$USER_CACHE" ]; then
        chpst -u $USER_NAME ln -sfn $USER_CACHE $USER_HOME/.cache
    fi
fi

mutex_user_unlock