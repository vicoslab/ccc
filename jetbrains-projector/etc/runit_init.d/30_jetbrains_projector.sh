#!/bin/bash

USER_NAME=${USER_NAME:-user}
USER_HOME=${BASE%"/"}/$USER_NAME
USER_ID=`id -u $USER_NAME`

export HOME=$USER_HOME

CONDA_BIN=$USER_HOME/conda/bin/conda
CONDA_PROJECTOR_ENV=jetbrains-projector

PROJECTOR_BIN="${CONDA_BIN} run -n ${CONDA_PROJECTOR_ENV} projector"

if [ ! -z "$LOCAL_SSD_STORAGE" ]; then
	# create symlink to local storage 
	PROJECTOR_STORAGE=$LOCAL_SSD_STORAGE/$CONTAINER_NAME/.projector
	
	CREATE_PROJECTOR_STORAGE=1
else
	# use /home/<user>/.projector as default storage (as required by projector)
	PROJECTOR_STORAGE=$USER_HOME/.projector
fi


export PROJECTOR_IDE=${PROJECTOR_IDE:-"PyCharm Professional Edition 2021.1.3"}
export PROJECTOR_PORT=${PROJECTOR_PORT:-9999}
export PROJECTOR_CONFIG="${HOSTNAME}-${PROJECTOR_CONFIG:-default}"

PROJECTOR_CONFIG_FILE=$PROJECTOR_STORAGE/configs/$PROJECTOR_CONFIG/config.ini

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
		
		DO_UPDATE=1
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

mutex_instalation_lock() {
	# wait until installation flag is finished
	while [ -f "$USER_HOME/jetbrains-projector.installing" ]; do sleep 2; done	
	
	# mark in file that jetbrains-projector.installing is in installation check
	chpst -u $USER_NAME touch "$USER_HOME/jetbrains-projector.installing"
}

mutex_instalation_unlock() {
	# clear "in installation" flag
	chpst -u $USER_NAME rm "$USER_HOME/jetbrains-projector.installing" 2> /dev/null

}

echo "Waiting on mutex lock"
mutex_instalation_lock
echo " continuing ..." 

# install jetbrains-projector into conda enviroment
if [ -z "$(${CONDA_BIN} env list | grep "^${CONDA_PROJECTOR_ENV} */")" ]; then
	
	echo "Installing conda env $CONDA_PROJECTOR_ENV"
	chpst -u $USER_NAME $CONDA_BIN create --name $CONDA_PROJECTOR_ENV --file /etc/jetbrains-projector-requirements.txt -y
	chpst -u $USER_NAME $CONDA_BIN run -n $CONDA_PROJECTOR_ENV pip install projector-installer
	echo "  (done)"	
fi 

if [ ! -z "$CREATE_PROJECTOR_STORAGE" ]; then 
	chpst -u $USER_NAME mkdir -p $PROJECTOR_STORAGE
	
	if [ ! -f "$USER_HOME/.projector" ] || [ "$(readlink -f $USER_HOME/.projector)" != "$PROJECTOR_STORAGE" ]; then
		chpst -u $USER_NAME ln -sfn $PROJECTOR_STORAGE $USER_HOME/.projector
	fi
fi

# put empty folder to prevent GPL question when running projector for the first time
chpst -u $USER_NAME mkdir -p $PROJECTOR_STORAGE/apps
chpst -u $USER_NAME mkdir -p $PROJECTOR_STORAGE/configs
chpst -u $USER_NAME mkdir -p $PROJECTOR_STORAGE/cache


if [ -z "$($PROJECTOR_BIN config list | grep " ${PROJECTOR_CONFIG}$")" ]; then
	
	# install default app
	echo "Installing '$PROJECTOR_IDE' as JetBrains projector app under config name '$PROJECTOR_CONFIG' (port: $PROJECTOR_PORT)"
	chpst -u $USER_NAME $PROJECTOR_BIN autoinstall --config-name $PROJECTOR_CONFIG --ide-name "$PROJECTOR_IDE" --port $PROJECTOR_PORT --hostname 0.0.0.0
	chpst -u $USER_NAME $PROJECTOR_BIN config update $PROJECTOR_CONFIG
	echo "  (done)"
	
	# enable SSL and add tokens it not present
	ensure_secure_config
fi

mutex_instalation_unlock