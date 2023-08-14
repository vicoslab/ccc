#!/bin/bash -e

USER_NAME=${USER_NAME:-user}
USER_HOME=${BASE%"/"}/$USER_NAME

# wait until installation flag is finished if exists
while [ -f "$USER_HOME/miniconda.installing" ]; do sleep 2; done	

if [ ! -f "$USER_HOME/conda/bin/conda" ] && [ ! -f "$USER_HOME/conda/condabin/conda" ]; then
  # mark instalation in progress to prevent concurrent installs from containers with shared HOME
  chpst -u $USER_NAME touch "$USER_HOME/miniconda.installing"

  echo "Installing miniconda ..."
  export HOME=$USER_HOME
  chpst -u $USER_NAME '/etc/setup_miniconda.sh'
  echo "Conda setup complete."

  # clear "in instalation" flag
  chpst -u $USER_NAME rm "$USER_HOME/miniconda.installing"
fi

# add link to profile.d since HOME folder can be shared and installed from elsewhere but /etc is not 
ln -sf $USER_HOME/conda/etc/profile.d/conda.sh /etc/profile.d/conda.sh
