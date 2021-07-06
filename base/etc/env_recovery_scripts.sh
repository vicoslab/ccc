#!/bin/sh -e

# Store all enviroment variables into /etc/envvars 
init_environment_vars() {
	
	echo "Saving environment variables to /etc/envvars"
	echo "" > /etc/envvars

	ignore_envs="HOME HOSTNAME TERM PWD USER USERNAME _"
	for K in $(env | sed -n 's#^\([A-Za-z][a-zA-Z0-9_]*\)=.*$#\1#p')
	do
		VALID=1
		for var in $(echo "$ignore_envs" | tr ' ' '\n') 
		do
			if [ "$K" = "$var" ] &&  [ $VALID -eq 1 ]; then
				VALID=0
			fi
		done
		if [ "$VALID" -eq 0 ]; then
			continue
		fi
		
		VAL=$(eval "printf \"\$${K}\"")
		num_lines=$(printf "$VAL" | grep -c .)
		
		if [ $num_lines -ge 2 ]
		then
			# retain multiline strings
			cat >> /etc/envvars <<- EOF
			read -r -d '' ${K} <<- EOM
			${VAL}
			EOM
			export ${K}
			EOF
		else
			echo "export ${K}=\"${VAL}\"" >> /etc/envvars
		fi
	done

	echo "Setting environment variables for default profile startup"
	echo ". /etc/envvars" > /etc/profile.d/00_container_envs.sh
	
}

# This function will check if booting has already been attempted several times and use recovery ENVs in that case
# Uses ENVs: 
#   $RUNIT_STATUS_FILE .. path to file with status of the runit (running, booting attempts, recovery)
#   $RUNIT_WORKING_ENV_FILE .. path to stored ENV files
init_recovery_mode() {
    
    if [ -z "$RUNIT_STATUS_FILE" ] || [ -z "$RUNIT_WORKING_ENV_FILE" ] 
    then
		echo "Disabling recovery mode since RUNIT_STATUS_FILE or RUNIT_WORKING_ENV_FILE env vars are not defined" 
        return 0
    fi

    # check how many times have we booted already without success
    if [ -f $RUNIT_STATUS_FILE ] 
    then
        init_retries=$( cat $RUNIT_STATUS_FILE | sed -n "s/^booting \([0-9].*\)/\1/p" )    
    fi

    # set init_retries to 0 if this is the first try
    if [ -z $init_retries ]
    then
        init_retries=0
    fi

    # if we booted more then 2 times then revert back to last known config if GOOD_ENV_FILE exists
    if [ $init_retries -gt 2 ] && [ -f $RUNIT_WORKING_ENV_FILE ]
    then
        echo ""
        echo "##################################################################################################################"
        echo "WARNING WARNING !"
        echo "WARNING WARNING !"
        echo ""
        echo "Several failed boot attempts!"
        echo "Reverting ENVs to the last known good values from $RUNIT_WORKING_ENV_FILE"
        echo ""
        echo "##################################################################################################################"
        echo ""
        # read last known good configuration from $RUNIT_WORKING_ENV_FILE
        . $RUNIT_WORKING_ENV_FILE

        echo "failed boot - running with last known working ENVs" > $RUNIT_STATUS_FILE
        return 1
    else
        echo "booting $((init_retries + 1))" > $RUNIT_STATUS_FILE
    fi
    return 0
}

# When boot has successfully finished this function will set finish/working flag 
# and store etc/envvars as working set of vars into $RUNIT_WORKING_ENV_FILE
finish_recovery_mode() {
    if [ -z "$RUNIT_STATUS_FILE" ] || [ -z "$RUNIT_WORKING_ENV_FILE" ] 
    then
        return 1
    fi
    
    echo "running" > $RUNIT_STATUS_FILE

    # save last-working-config (i.e. envs) by copying /etc/envvars
    cp /etc/envvars $RUNIT_WORKING_ENV_FILE
}
