#!/bin/bash -e

USER_NAME=${USER_NAME:-user}

USER_ID=${USER_ID:-1000}

USER_PUBKEY=${USER_PUBKEY}

USER_HOME=${BASE%"/"}/$USER_NAME

# Ubuntu 24.04 base images ship a default 'ubuntu' user (and group) at UID/GID
# 1000. When the requested USER_ID/USER_NAME differs, that pre-existing entry
# squats on the UID and `adduser --uid` fails; under `set -e` that aborts the
# whole startup before the SSH key is installed, which breaks SSH logins (this
# is never hit on 22.04, whose base image has no user at UID 1000). Remove the
# conflicting default user/group first so we can claim the requested IDs.
EXISTING_USER=$(getent passwd "$USER_ID" | cut -d: -f1)
if [ -n "$EXISTING_USER" ] && [ "$EXISTING_USER" != "$USER_NAME" ]; then
    echo "Removing default user '$EXISTING_USER' occupying UID $USER_ID"
    deluser "$EXISTING_USER" > /dev/null 2>&1 || userdel "$EXISTING_USER" > /dev/null 2>&1 || true
fi
EXISTING_GROUP=$(getent group "$USER_ID" | cut -d: -f1)
if [ -n "$EXISTING_GROUP" ] && [ "$EXISTING_GROUP" != "$USER_NAME" ]; then
    echo "Removing default group '$EXISTING_GROUP' occupying GID $USER_ID"
    groupdel "$EXISTING_GROUP" > /dev/null 2>&1 || true
fi

getent passwd $USER_NAME || adduser --uid=$USER_ID --home=$USER_HOME --disabled-password --gecos "" $USER_NAME

# OpenSSH 9.x (Ubuntu 24.04) refuses *all* authentication -- including publickey
# -- for accounts whose password is "locked", i.e. a shadow field starting with
# '!' as left by `adduser --disabled-password` (sshd logs "account is locked").
# OpenSSH 8.x (22.04) only applied that to password auth, so key logins worked.
# Swap the locked '!' for '*': still no usable password (password auth stays
# disabled, and PasswordAuthentication is off anyway), but the account is no
# longer considered locked, so key-based logins work on 22.04 and 24.04 alike.
CURRENT_PW=$(getent shadow "$USER_NAME" | cut -d: -f2)
case "$CURRENT_PW" in
    '!'*) usermod -p '*' "$USER_NAME" ;;
esac

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
            # Honor the exact requested GID. We intentionally avoid `groupadd -f -g`
            # here: when the requested GID is already used by another group (e.g.
            # GID 998/999 are taken by the runit-log groups), `-f` silently turns
            # off `-g` and picks a different free GID, so the group ends up with
            # the wrong ID and the user loses access to the matching resource
            # (e.g. the host docker socket).
            if getent group "$GROUP_NAME" > /dev/null; then
                # group name already exists: force it to use the requested GID
                # (-o allows the GID to be shared with an existing group)
                groupmod -o -g "$GROUP_ID" "$GROUP_NAME"
            else
                # create the group with the exact GID; -o allows a non-unique GID
                # so a pre-existing group on the same GID does not block us
                groupadd -o -g "$GROUP_ID" "$GROUP_NAME"
            fi
        else
            groupadd -f "$GROUP_NAME"
        fi
        usermod -a -G "$GROUP_NAME" "$USER_NAME"
    done
fi

CURRENT_HOME_OWNER=$(stat -c '%U' $USER_HOME)

if [ "$CURRENT_HOME_OWNER" != "$USER_NAME" ]; then
    chown $USER_NAME:$USER_NAME $USER_HOME
    chpst -u $USER_NAME chmod 750 $USER_HOME
fi
# copy default profile files if they do not exist yet
# (cannot use -m from adduser since folder many already exist due to mounting)
chpst -u $USER_NAME cp -r -n /etc/skel/. $USER_HOME/.

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
    # add provided public key if not present yet
    if ! grep -Fxq "${USER_PUBKEY}" $USER_HOME/.ssh/authorized_keys ;  then
        echo "Adding SSH public key:"
        echo "${USER_PUBKEY}" | chpst -u $USER_NAME tee -a $USER_HOME/.ssh/authorized_keys
    fi
    chpst -u $USER_NAME chown -R $USER_NAME:$USER_NAME $USER_HOME/.ssh

    chpst -u $USER_NAME chmod 700 $USER_HOME/.ssh
    chpst -u $USER_NAME chmod 600 $USER_HOME/.ssh/authorized_keys
    
fi

change_home_subfolder_into_local() {
    SUBFOLDER_NAME=$1
    SRC_FOLDER=$USER_HOME/$SUBFOLDER_NAME
    TARGET_FOLDER=$LOCAL_SSD_STORAGE/$CONTAINER_NAME/$SUBFOLDER_NAME

    chpst -u $USER_NAME mkdir -p $TARGET_FOLDER
    
    # check if existing folder is not symlink but actual folder -- rename it in case user has something important there
    if [ -d "$SRC_FOLDER" ] && [ ! -h "$SRC_FOLDER" ] ; then
        RANDOM_SUFFIX=$(date +%s | sha256sum | base64 | head -c 4)
        chpst -u $USER_NAME mv "$SRC_FOLDER" "${SRC_FOLDER}_backup_${RANDOM_SUFFIX}"
        
        echo "Renamed existing $SRC_FOLDER folder  into ${SRC_FOLDER}_backup_${RANDOM_SUFFIX}"
    fi
    
    # check if storage already exist but avoid creating if already there
    if [ ! -f "$SRC_FOLDER" ] || [ "$(readlink -f $SRC_FOLDER)" != "$TARGET_FOLDER" ]; then
        chpst -u $USER_NAME ln -sfn $TARGET_FOLDER $SRC_FOLDER
        
        echo "Created symlink $SRC_FOLDER -> $TARGET_FOLDER"
    fi
}

# create symlink to local storage for .cache files
if [ ! -z "$LOCAL_SSD_STORAGE" ]; then    
    change_home_subfolder_into_local ".cache"
    change_home_subfolder_into_local ".services"
fi

mutex_user_unlock
