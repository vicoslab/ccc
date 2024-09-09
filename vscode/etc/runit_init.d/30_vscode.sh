#!/bin/bash -e

USER_NAME=${USER_NAME:-user}
USER_HOME=${BASE%"/"}/$USER_NAME
USER_ID=`id -u $USER_NAME`

export HOME=$USER_HOME

# Define the version of VS Code CLI amd URL for install
VSCODE_CLI_VERSION=${VSCODE_CLI_VERSION:-"latest"}
VSCODE_CLI_URL=${VSCODE_CLI_URL:-"https://update.code.visualstudio.com/${VSCODE_CLI_VERSION}/cli-linux-x64/stable"}

if [ $VSCODE_USE_INSIDER ] ; then
    VSCODE_CLI_URL=${VSCODE_CLI_URL:-"https://update.code.visualstudio.com/${VSCODE_CLI_VERSION}/cli-linux-x64/insider"}
fi


# Define the installation directory
INSTALL_DIR="/usr/bin"

# Create the installation directory if it doesn't exist
mkdir -p "$INSTALL_DIR"

# Download and extract VS Code CLI
echo "Downloading VS Code CLI version: $VSCODE_CLI_VERSION"

INSTALLED=false
{ curl -L "$VSCODE_CLI_URL" | tar -xz -C "$INSTALL_DIR"; } && INSTALLED=true || INSTALLED=false

if [ "$INSTALLED" = true ]; then
    echo "VS Code CLI installed to $INSTALL_DIR"
else
    echo ""
    echo "ERROR (!!)"
    echo "FAILED TO INSTALL VS Code CLI but continuing anyway (!!!)"
    echo ""
    echo ""
fi
