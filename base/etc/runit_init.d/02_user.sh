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

# Create the container-local account without copying files into shared storage.
getent passwd "$USER_NAME" || adduser --uid="$USER_ID" --home="$USER_HOME" \
    --no-create-home --disabled-password --gecos "" "$USER_NAME"

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

# The lock lives inside the home. Create an empty directory if needed, but
# don't populate it until setup_shared_home runs under that lock.
mkdir -p -m 750 -- "$USER_HOME"
CURRENT_HOME_OWNER=$(stat -c '%U' -- "$USER_HOME")

if [ "$CURRENT_HOME_OWNER" != "$USER_NAME" ]; then
    chown "$USER_NAME:$USER_NAME" "$USER_HOME"
    chpst -u "$USER_NAME" chmod 750 "$USER_HOME"
fi

change_home_subfolder_into_local() {
    local src=$1 target=$2 suffix

    mkdir -p -- "$target"
    if [[ -d $src && ! -L $src ]]; then
        suffix=$(date +%s | sha256sum | base64 | head -c 4)
        mv -- "$src" "${src}_backup_${suffix}"
        echo "Renamed existing $src folder into ${src}_backup_${suffix}"
    fi
    if [[ ! -L $src || $(readlink -f -- "$src") != "$target" ]]; then
        ln -sfn -- "$target" "$src"
        echo "Created symlink $src -> $target"
    fi
}

setup_shared_home() {
    local user=$1 home=$2 pubkey=$3
    # Populate new and pre-existing shared homes under the same lock.
    cp -r -n /etc/skel/. "$home/."

    if [[ -n $pubkey ]]; then
        mkdir -p -- "$home/.ssh"
        if ! grep -Fxq -- "$pubkey" "$home/.ssh/authorized_keys"; then
            echo 'Adding SSH public key:'
            printf '%s\n' "$pubkey" | tee -a "$home/.ssh/authorized_keys"
        fi
        chown -R "$user:$user" "$home/.ssh"
        chmod 700 "$home/.ssh"
        chmod 600 "$home/.ssh/authorized_keys"
    fi

    if [[ -n $LOCAL_SSD_STORAGE ]]; then
        change_home_subfolder_into_local "$home/.cache" "$LOCAL_SSD_STORAGE/$CONTAINER_NAME/.cache"
        change_home_subfolder_into_local "$home/.services" "$LOCAL_SSD_STORAGE/$CONTAINER_NAME/.services"
    fi
}
export -f setup_shared_home change_home_subfolder_into_local

exec chpst -u "$USER_NAME" /bin/bash "$(dirname -- "$0")/../ccc-install-lock.sh" \
    "$USER_HOME/user.installing" /bin/bash -ec 'setup_shared_home "$@"' setup_shared_home \
    "$USER_NAME" "$USER_HOME" "$USER_PUBKEY"
