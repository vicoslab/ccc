#!/bin/bash -e

USER_NAME=${USER_NAME:-user}
USER_HOME=${BASE%"/"}/$USER_NAME
SCRIPT_DIR=$(dirname -- "$0")

setup_projector() {
    local home=$1 requirements=$2
    local conda="$home/conda/bin/conda" env=jetbrains-projector
    local storage="$home/.projector" suffix envs configs
    export HOME=$home
    export PROJECTOR_IDE=${PROJECTOR_IDE:-"PyCharm Professional Edition 2021.1.3"}
    export PROJECTOR_PORT=${PROJECTOR_PORT:-9999}
    export PROJECTOR_CONFIG="${HOSTNAME}-${PROJECTOR_CONFIG:-default}"
    local projector=("$conda" run -n "$env" projector)

    envs=$("$conda" env list)
    if ! grep -q "^${env} */" <<< "$envs"; then
        echo "Installing conda env $env"
        "$conda" create --name "$env" --file "$requirements" -y
        "$conda" run -n "$env" pip install projector-installer
        echo '  (done)'
    fi

    if [[ -n $LOCAL_SSD_STORAGE ]]; then
        storage="$LOCAL_SSD_STORAGE/$CONTAINER_NAME/.projector"
        mkdir -p -- "$storage"
        if [[ -d "$home/.projector" && ! -L "$home/.projector" ]]; then
            suffix=$(date +%s | sha256sum | base64 | head -c 4)
            mv -- "$home/.projector" "$home/.projector_backup_$suffix"
            echo "Renamed existing $home/.projector folder into $home/.projector_backup_$suffix"
        fi
        if [[ ! -L "$home/.projector" || $(readlink -f -- "$home/.projector") != "$storage" ]]; then
            ln -sfn -- "$storage" "$home/.projector"
            echo "Created symlink $home/.projector -> $storage"
        fi
    fi

    # Pre-create these directories to avoid the interactive GPL prompt.
    mkdir -p -- "$storage"/{apps,configs,cache}
    configs=$("${projector[@]}" config list)
    if ! grep -q " ${PROJECTOR_CONFIG}$" <<< "$configs"; then
        echo "Installing '$PROJECTOR_IDE' as JetBrains projector app under config name '$PROJECTOR_CONFIG' (port: $PROJECTOR_PORT)"
        "${projector[@]}" autoinstall --config-name "$PROJECTOR_CONFIG" --ide-name "$PROJECTOR_IDE" --port "$PROJECTOR_PORT" --hostname 0.0.0.0
        "${projector[@]}" config update "$PROJECTOR_CONFIG"
        echo '  (done)'
    fi
}
export -f setup_projector

exec chpst -u "$USER_NAME" /bin/bash "$SCRIPT_DIR/../ccc-install-lock.sh" \
    "$USER_HOME/jetbrains-projector.installing" /bin/bash -ec 'setup_projector "$@"' setup_projector \
    "$USER_HOME" "$SCRIPT_DIR/../jetbrains-projector-requirements.txt"
