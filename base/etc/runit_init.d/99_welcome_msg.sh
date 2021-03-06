#!/bin/bash

[ -r /etc/lsb-release ] && . /etc/lsb-release

if [ -z "$DISTRIB_DESCRIPTION" ] && [ -x /usr/bin/lsb_release ]; then
        # Fall back to using the very slow lsb_release utility
        DISTRIB_DESCRIPTION=$(lsb_release -s -d)
fi

cat > /etc/motd << EOF
Welcome to Conda Compute Container (https://github.com/vicoslab/ccc)

Running ${DISTRIB_DESCRIPTION} on node '${HOSTNAME}' with:

 * Docker image: ${CONTAINER_IMAGE}
 * Container name: ${CONTAINER_NAME}
  
 * APT-GET sources: '${INSTALL_REPOSITORY_SOURCES}'
 * APT-GET keys: '${INSTALL_REPOSITORY_KEYS}'
 * APT-GET packges: '${INSTALL_PACKAGES}'
 
 * Miniconda: /home/$USER_NAME/conda

${CONTAINER_WELCOME_MSG}
EOF

if [ ! -z $RUNIT_STATUS_FILE ] && [ $(cat $RUNIT_STATUS_FILE | grep -c 'failed boot') -ne 0 ]
then

	cat >> /etc/motd <<- EOF
	CONTAINER STATUS: FAILED BOOT

	#######################################################################
	WARNING:      BOOT FAILED WITH THE USER REQUESTED SETTING
                  REVERTED BACK TO THE LAST KNOWN GOOD CONFIGURATION

                  Please fix your configuration values.
	#######################################################################

	EOF
else
    echo "CONTAINER STATUS: OK" >> /etc/motd
fi

if [ ! -z $CUSTOM_MESSAGE ]
then
    echo "\n$CUSTOM_MESSAGE" >> /etc/motd
fi
