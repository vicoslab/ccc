#!/bin/bash -e

USER_NAME=${USER_NAME:-user}
USER_HOME=${BASE%"/"}/$USER_NAME
SCRIPT_DIR=$(dirname -- "$0")
export HOME=$USER_HOME

CONDA_BIN=$USER_HOME/conda/bin/conda
CCC_TOOLS_ENABLE=${CCC_TOOLS_ENABLE:-1}
CCC_TOOLS_ENV=${CCC_TOOLS_ENV:-ccc-tools}
CCC_TOOLS_PYTHON_VER=${CCC_TOOLS_PYTHON_VER:-3.11}
CCC_TOOLS_GITHUB=${CCC_TOOLS_GITHUB:-https://github.com/vicoslab/ccc-tools}

install_ccc_tools() {
    local conda=$1 env=$2 python=$3 repo=$4 envs bin
    echo 'Installing ccc-tools ...' >&2
    # An unavailable env listing must not make this optional install fatal.
    if ! envs=$("$conda" env list) || ! grep -q "^${env} */" <<< "$envs"; then
        if ! { "$conda" create --name "$env" "python=$python" -y &&
               "$conda" run -n "$env" pip install --no-input "git+$repo"; } >&2; then
            return 20  # Optional install failure; startup can continue without the tool.
        fi
    fi
    bin=$("$conda" run -n "$env" which ccc)
    printf '%s\n' "$bin"
}
export -f install_ccc_tools

if [[ $CCC_TOOLS_ENABLE == 1 ]]; then
    if CCC_BIN=$(chpst -u "$USER_NAME" /bin/bash "$SCRIPT_DIR/../ccc-install-lock.sh" \
        "$USER_HOME/ccc-tools.installing" /bin/bash -ec 'install_ccc_tools "$@"' install_ccc_tools \
        "$CONDA_BIN" "$CCC_TOOLS_ENV" "$CCC_TOOLS_PYTHON_VER" "$CCC_TOOLS_GITHUB"); then
        ln -sf "$CCC_BIN" /usr/bin/ccc
        echo '  (done)'
    else
        status=$?
        if [[ $status != 20 ]]; then
            exit "$status"
        fi
        echo 'FAILED TO INSTALL ccc-tools, but continuing anyway (!!!)' >&2
    fi
fi
