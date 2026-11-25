#!/bin/bash -e

USER_NAME=${USER_NAME:-user}
USER_HOME=${BASE%"/"}/$USER_NAME
SCRIPT_DIR=$(dirname -- "$0")

install_miniconda() {
    export HOME=$1
    if [[ ! -f "$HOME/conda/bin/conda" && ! -f "$HOME/conda/condabin/conda" ]]; then
        echo 'Installing miniconda ...'
        "$2"
        echo 'Conda setup complete.'
    fi
}
export -f install_miniconda

chpst -u "$USER_NAME" /bin/bash "$SCRIPT_DIR/../ccc-install-lock.sh" \
    "$USER_HOME/miniconda.installing" /bin/bash -ec 'install_miniconda "$@"' install_miniconda \
    "$USER_HOME" "$SCRIPT_DIR/../setup_miniconda.sh"

# Add link to profile.d since HOME may be shared, but /etc is not.
ln -sf "$USER_HOME/conda/etc/profile.d/conda.sh" /etc/profile.d/conda.sh
