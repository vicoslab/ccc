#!/bin/bash

USER_NAME=${USER_NAME:-user}
USER_HOME=${BASE%"/"}/$USER_NAME
USER_ID=`id -u $USER_NAME`

export HOME=$USER_HOME

CONDA_BIN=$USER_HOME/conda/bin/conda
CONDA_PROJECTOR_ENV=jetbrains-projector

PROJECTOR_BIN="${CONDA_BIN} run -n ${CONDA_PROJECTOR_ENV} projector"

export PROJECTOR_IDE=${PROJECTOR_IDE:-"PyCharm Professional Edition 2021.1.3"}
export PROJECTOR_PORT=${PROJECTOR_PORT:-9999}
export PROJECTOR_CONFIG=${PROJECTOR_CONFIG:-default}
PROJECTOR_CONFIG_FILE=$USER_HOME/.projector/configs/$PROJECTOR_CONFIG/config.ini

ensure_secure_config() {

	DO_UPDATE=""
	
	AUTH_TOKEN=$(grep -o "^password = .*" $PROJECTOR_CONFIG_FILE | cut -f2- -d=)
	
	if [ -z "$AUTH_TOKEN" ]; then
		# auth token not configure: create new one
		AUTH_TOKEN=`date +%s | sha256sum | base64 | head -c 64`
		
		cat >> $PROJECTOR_CONFIG_FILE <<- EOF
		[PASSWORDS]
		password = $AUTH_TOKEN
		ro_password = $AUTH_TOKEN
		EOF
		
		DO_UPDATE=1
	fi
	
	SSL_TOKEN=$(grep -o "^token = .*" $PROJECTOR_CONFIG_FILE | cut -f2- -d=)
	
	if [ -z "$SSL_TOKEN" ]; then
		# SSL no configure: create new token
		SSL_TOKEN=`date +%s | sha256sum | base64 | head -c 20`
		
		cat >> $PROJECTOR_CONFIG_FILE <<- EOF
		[SSL]
		token = $SSL_TOKEN
		EOF
		
		DO_UPDATE=1
	fi
	
	if [ ! -z "$DO_UPDATE" ]; then
		chpst -u $USER_NAME $PROJECTOR_BIN config rebuild
	fi 
}

# install jetbrains-projector into conda enviroment
if [ -z "$(${CONDA_BIN} env list | grep "^${CONDA_PROJECTOR_ENV} */")" ]; then
	
	echo "Installing conda env $CONDA_PROJECTOR_ENV"
	chpst -u $USER_NAME $CONDA_BIN create --name $CONDA_PROJECTOR_ENV --file /etc/jetbrains-projector-requirements.txt -y
	chpst -u $USER_NAME $CONDA_BIN run -n $CONDA_PROJECTOR_ENV pip install projector-installer
	echo "  (done)"	
fi 

# put empty folder to prevent GPL question when running projector for the first time
chpst -u $USER_NAME mkdir -p $USER_HOME/.projector/apps
chpst -u $USER_NAME mkdir -p $USER_HOME/.projector/configs
chpst -u $USER_NAME mkdir -p $USER_HOME/.projector/cache

if [ -z "$($PROJECTOR_BIN config list | grep $PROJECTOR_CONFIG)" ]; then
	
	# install default app
	echo "Installing '$PROJECTOR_IDE' as JetBrains projector app under config name '$PROJECTOR_CONFIG' (port: $PROJECTOR_PORT)"
	chpst -u $USER_NAME $PROJECTOR_BIN autoinstall --config-name $PROJECTOR_CONFIG --ide-name "$PROJECTOR_IDE" --port $PROJECTOR_PORT --hostname 0.0.0.0
	chpst -u $USER_NAME $PROJECTOR_BIN config update $PROJECTOR_CONFIG
	echo "  (done)"
	
	# enable SSL and add tokens it not present
	ensure_secure_config

fi