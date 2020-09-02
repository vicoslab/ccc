#!/bin/bash

USER_NAME=${USER_NAME:-user}
USER_HOME=${BASE%"/"}/$USER_NAME

export HOME=$USER_HOME

IFS=':' read -ra APPS_ARRAY <<< "$APPS"

# register shared apps to the system path
for app_path in "${APPS_ARRAY[@]}"; do
    # remove any trailing spaces
    app_path=`echo $app_path | xargs`

    # get provided filename if comma is found
    IFS=',' read -ra app_name <<< "$app_path"
    
    app_path=${app_name[0]}
    filename=${app_name[1]}
    
    # get filename from path if not provided directly
    if [ -z "$filename" ]; then
        filename=$(basename -- "$app_path") 
    
        # remove extension 
        filename="${filename%.*}"
    fi
    
    # register symlink to /usr/local/bin
    ln -s $app_path "/usr/local/bin/$filename"
    
    echo "Added '/usr/local/bin/$filename' link to '$app_path'"
done

echo "Done adding apps to /usr/local/bin completed."

