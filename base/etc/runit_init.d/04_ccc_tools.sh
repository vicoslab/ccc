#!/bin/bash -e

USER_NAME=${USER_NAME:-user}
USER_HOME=${BASE%"/"}/$USER_NAME
USER_ID=`id -u $USER_NAME`

export HOME=$USER_HOME

CONDA_BIN=$USER_HOME/conda/bin/conda

CCC_TOOLS_ENABLE=${CCC_TOOLS_ENABLE:-1}

CCC_TOOLS_ENV=${CCC_TOOLS_ENV:-ccc-tools}
CCC_TOOLS_PYTHON_VER=${CCC_TOOLS_PYTHON_VER:-3.11}

CCC_TOOLS_GITHUB=${CCC_TOOLS_GITHUB:-"https://github.com/vicoslab/ccc-tools"}

if [ "$CCC_TOOLS_ENABLE" = 1 ]; then

    # wait until installation flag is finished if exists
    while [ -f "$USER_HOME/ccc-tools.installing" ]; do sleep 2; done	

    echo "Installing ccc-tools ..."
    if [ -z "$(${CONDA_BIN} env list | grep "^${CCC_TOOLS_ENV} */")" ]; then
        # mark instalation in progress to prevent concurrent installs from containers with shared HOME
        chpst -u $USER_NAME touch "$USER_HOME/ccc-tools.installing"

        { chpst -u $USER_NAME $CONDA_BIN create --name $CCC_TOOLS_ENV python=$CCC_TOOLS_PYTHON_VER -y &&
        chpst -u $USER_NAME $CONDA_BIN run -n $CCC_TOOLS_ENV pip install --no-input git+$CCC_TOOLS_GITHUB ; } && INSTALLED=1 || INSTALLED=0

        # clear "in instalation" flag
        chpst -u $USER_NAME rm "$USER_HOME/ccc-tools.installing"
    else
        INSTALLED=1
    fi

    if [ "$INSTALLED" = 1 ]; then
        # instally symlink to ccc binary in conda to system path
        CCC_BIN=$(chpst -u $USER_NAME $CONDA_BIN run -n $CCC_TOOLS_ENV which ccc)

        ln -sf $CCC_BIN /usr/bin/ccc

        echo "  (done)"	
    else
        echo "ERROR"
        echo "FAILED TO INSTALL ccc-tools, but continuing anyway (!!!)"
    fi
fi