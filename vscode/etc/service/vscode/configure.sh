#!/bin/sh -e

#####################################################################################
# variable setup 

USER_NAME=${USER_NAME:-user}
USER_HOME=${BASE%"/"}/$USER_NAME

export HOME=$USER_HOME

BIN_SUFFIX=""
if [ $VSCODE_USE_INSIDER ] ; then
    BIN_SUFFIX="-insiders"
fi

VSCODE_CLI_BIN="code$BIN_SUFFIX"
VSCODE_CLI_SERVE=$HOME/.vscode$BIN_SUFFIX/cli/serve-web/
VSCODE_PORT=${VSCODE_PORT:-9999}

#####################################################################################
# function defines

# Function to check if VSCODE_CLI_SERVE contains any subfolder without ".staging" suffix
check_vscode_cli_serve() {
    if [ -d "$VSCODE_CLI_SERVE" ]; then
        for subdir in "$VSCODE_CLI_SERVE"/*; do
            if [ -d "$subdir" ]; then
                case "$(basename "$subdir")" in
                    *.staging) ;;
                    *) return 0 ;;
                esac
            fi
        done
    fi
    return 1
}

download_vscode() {
    echo "Downloading VS Code serve-web binary"

    # randomly generate connection token only for download
    VSCODE_DL_TOKEN=`date +%s | sha256sum | base64 | head -c 64`

    # Run code serve-web directly in the background
    $VSCODE_CLI_BIN serve-web --connection-token=$VSCODE_DL_TOKEN &

    # Capture the PID of the serve-web process
    SERVE_WEB_PID=$!

    sleep 1

    echo "Activating connection ..."
    # Initiate connection to force it to download serve-web binary
    curl -s http://127.0.0.1:8000?tkn=$VSCODE_DL_TOKEN

    # Wait until VSCODE_CLI_SERVE actually exists and contains any subfolders
    echo Waiting for VS Code to be fully downloaded ...
    while ! check_vscode_cli_serve; do
        sleep 1
    done

    # Stop the serve-web process once the binary is downloaded
    echo "VS Code downloaded successfully. Stopping serve-web."
    kill -TERM $SERVE_WEB_PID
}

remove_auth_token_motd() {
	# remove existing token from MOTD 
	line=$(grep -n 'TOKEN (VSCode Web-Server)' /etc/motd | cut -f1 -d:)
	if [ ! -z "$line" ]; then
		sed -i "$((line))d" /etc/motd
	fi 
}

add_auth_token_motd() {
	# first remove any existing tokens 
	remove_auth_token_motd

	# find actual token
	VSCODE_TOKEN=$(cat $HOME/vscode.token 2> /dev/null || echo "")
	
	# save value that will be appended to MOTD into temp file
	cat > /tmp/motd.vscode <<- EOF
	TOKEN (VSCode Web-Server): ${VSCODE_TOKEN}
	EOF
	
	# append right before CONTAINER STATUS
	line=$(grep -n "CONTAINER STATUS:" /etc/motd | cut -f1 -d:)
	sed -i "$((line-1))r/tmp/motd.vscode" /etc/motd
	
	# remove temp file
	rm /tmp/motd.vscode
}

retrieve_or_generate_auth_token() {
    VSCODE_TOKEN=$(cat $HOME/vscode.token 2> /dev/null || echo "")

    if [ -z "$VSCODE_TOKEN" ] ; then
        VSCODE_TOKEN=`date +%s | sha256sum | base64 | head -c 32`
        echo $VSCODE_TOKEN | chpst -u $USER_NAME tee $HOME/vscode.token
    fi

    # to avoid issues from concurrent access just sleep for a few sec and re-read the token
    sleep 3

    VSCODE_TOKEN=$(cat $HOME/vscode.token 2> /dev/null || echo "")
}

#####################################################################################
# main checks and configuration

# check if VSCODE binary is valid otherwise disable the service
$VSCODE_CLI_BIN --version && VSCODE_VALID=1 || VSCODE_VALID=0

if [ $VSCODE_VALID ] ; then
    # VS CODE CLI not valid - disabling the service

    DIR="$(cd "$(dirname "$0")" && pwd)"
    DOWNFILE=$(realpath $DIR/down)

    touch $DOWNFILE

    echo ""
    echo "ERROR: Invalid VS Code CLI binary: $VSCODE_CLI_BIN"
    echo ""
    echo "DISABLING VSCODE WEB-SERVE SERVICE"
    echo "To re-enable the service provide valid VS Code CLI and remove $DOWNFILE file"

    exit 0
fi

# Check if VSCODE_CLI_SERVE exists and is not empty
if ! check_vscode_cli_serve; then
  
    download_vscode
fi

# generate or retieve auth token (CAN HAPPEN CONCURRENTLY ON ALL SERVERS!!)
retrieve_or_generate_auth_token

## append authentication token to MOTD
add_auth_token_motd	


# use the latest version of vscode serve-web
VSCODE_VERSION=$(find "$VSCODE_CLI_SERVE" -mindepth 1 -maxdepth 1 -type d -printf "%T@ %p\n" | sort -n | tail -1 | awk '{print $2}')

# variables for running
VSCODE_BIN=$VSCODE_VERSION/bin/code-server$BIN_SUFFIX
VSCODE_SERVER_DATA_DIR=$HOME/.vscode-server$BIN_SUFFIX