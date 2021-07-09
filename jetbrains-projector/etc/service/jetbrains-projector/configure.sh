#!/bin/sh -e

#####################################################################################
# variable setup 

USER_NAME=${USER_NAME:-user}
USER_HOME=${BASE%"/"}/$USER_NAME

export HOME=$USER_HOME

CONDA_BIN=$USER_HOME/conda/bin/conda
CONDA_PROJECTOR_ENV=jetbrains-projector

PROJECTOR_BIN="${CONDA_BIN} run -n ${CONDA_PROJECTOR_ENV} projector"
PROJECTOR_CONFIG="${HOSTNAME}-${PROJECTOR_CONFIG:-default}"
PROJECTOR_CONFIG_FOLDER=$USER_HOME/.projector/configs/$PROJECTOR_CONFIG/
PROJECTOR_CONFIG_FILE=$PROJECTOR_CONFIG_FOLDER/config.ini

#####################################################################################
# function defines

ensure_secure_config() {

	DO_UPDATE=""
	
	# find authentication token (should be in section [PASSWORDS] and starts with 'password = ')
	AUTH_TOKEN=$(grep -o "^password = .*" $PROJECTOR_CONFIG_FILE | cut -f2- -d=)
	
	# get user requested token if specified
	USER_REQUESTED_TOKEN=$(cat $HOME/jetbrains-projector.token 2> /dev/null || echo "")
	
	# if auth token not configured then create new one
	if [ -z "$AUTH_TOKEN" ]; then
		# use user token if present
		if [ -z "$USER_REQUESTED_TOKEN" ] ; then
			AUTH_TOKEN=`date +%s | sha256sum | base64 | head -c 64`
		else
			AUTH_TOKEN=$USER_REQUESTED_TOKEN
		fi
		cat >> $PROJECTOR_CONFIG_FILE <<- EOF
		[PASSWORDS]
		password = $AUTH_TOKEN
		ro_password = $AUTH_TOKEN
		EOF
		
		DO_UPDATE=1
	elif [ "$USER_REQUESTED_TOKEN" != "$AUTH_TOKEN" ] ; then
		# password already present but user requested different one so change it
		sed -i "s/password = .*/password = ${USER_REQUESTED_TOKEN}/g" $PROJECTOR_CONFIG_FILE
		sed -i "s/ro_password = .*/ro_password = ${USER_REQUESTED_TOKEN}/g" $PROJECTOR_CONFIG_FILE
	fi
	
	# find SSL token (should be in section [SSL] and starts with 'token = ')
	SSL_TOKEN=$(grep -o "^token = .*" $PROJECTOR_CONFIG_FILE | cut -f2- -d=)
	
	# if SSL is not configured then create new token
	if [ -z "$SSL_TOKEN" ]; then
		SSL_TOKEN=`date +%s | sha256sum | base64 | head -c 20`
		
		cat >> $PROJECTOR_CONFIG_FILE <<- EOF
		[SSL]
		token = $SSL_TOKEN
		EOF
		
		DO_UPDATE=1
	fi
	
	# rebuild config file if changes were made
	if [ ! -z "$DO_UPDATE" ]; then
		chpst -u $USER_NAME $PROJECTOR_BIN config rebuild $PROJECTOR_CONFIG
	fi 
}

remove_auth_token_motd() {
	# remove existing token from MOTD 
	line=$(grep -n 'TOKEN (JetBrains Projector)' /etc/motd | cut -f1 -d:)
	if [ ! -z "$line" ]; then
		sed -i "$((line))d" /etc/motd
	fi 
}

add_auth_token_motd() {
	# first remove any existing tokens 
	remove_auth_token_motd

	# find actual token
	AUTH_TOKEN=$(grep -o "^password = .*" $PROJECTOR_CONFIG_FILE | cut -f2- -d=)
	
	# save value that will be appended to MOTD into temp file
	cat > /tmp/motd.jetbrains <<- EOF
	TOKEN (JetBrains Projector): ${AUTH_TOKEN}
	EOF
	
	# append right before CONTAINER STATUS
	line=$(grep -n "CONTAINER STATUS:" /etc/motd | cut -f1 -d:)
	sed -i "$((line-1))r/tmp/motd.jetbrains" /etc/motd
	
	# remove temp file
	rm /tmp/motd.jetbrains
}

clenup_previous_run() {

	# need to manually kill java app for projector 
	pkill -f ".*/.projector/apps/.*/java.*" 2> /dev/null || echo ""

	# also clear the lock flag
	rm "$PROJECTOR_CONFIG_FOLDER/run.lock" 2> /dev/null || echo ""
}

remove_warning_motd() {
	# if warning is in MOTD file them revert it back to original (/tmp/motd.back)
	if [ ! -z "$(grep 'JetBrains Projector IS NOT RUNNING' /etc/motd)" ]; then 
		cp /tmp/motd.back /etc/motd && rm /tmp/motd.back
	fi
}

insert_warning_motd() {
	# if any previous TOKENs were written in motd then remove them since they will not be valid any more
	remove_auth_token_motd

	# make a copy of motd to which we can restore when projector is properly configured and started
	cp /etc/motd /tmp/motd.back
	
	# create temp file with message
	cat > /tmp/motd.jetbrains <<- EOF
	
	################################################################################
	WARNING: JetBrains Projector IS NOT RUNNING on this node due to missing config
	
		Please run following to fully configure: 
			 > conda activate jetbrains-projector
			 > projector ide install --no-auto-run
			 > projector config add ${PROJECTOR_CONFIG}
		
		Use following settings:
			- host: 0.0.0.0
			- port: ${PROJECTOR_PORT:-9999}
			
	################################################################################
	EOF

	# insert message before "CONTAINER STATUS" line
	line=$(grep -n "CONTAINER STATUS:" /etc/motd | cut -f1 -d:)
	sed -i "${line}r/tmp/motd.jetbrains" /etc/motd
	
	# remove temp file
	rm /tmp/motd.jetbrains

}
#####################################################################################
# main checks and configuration

## clean-up any child processes that did not exit properly from previous run
# must be done before calling projector config list
clenup_previous_run

## check if valid configuration for projector exists
if [  -z "$($PROJECTOR_BIN config list | grep $PROJECTOR_CONFIG)" ]; then

	# insert warning into MOTD if not present yet
	if [ -z "$(grep 'JetBrains Projector IS NOT RUNNING' /etc/motd)" ]; then
		insert_warning_motd
	fi

	# return error since we cannot continue (this will throw exception in run)
	exit 1
fi

## remove missing config message from MOTD
remove_warning_motd

## ensure that config is secure (using secure websockets and token)
ensure_secure_config

## append authentication token to MOTD
add_auth_token_motd	
