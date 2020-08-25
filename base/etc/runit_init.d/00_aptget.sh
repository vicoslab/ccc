#!/bin/bash -e


if [ ! -z "$INSTALL_PACKAGES" ]; then

# add custom repos 
if [ ! -z "$INSTALL_REPOSITORY_SOURCES" ]; then
  apt-get clean
  apt-get update --fix-missing || echo "Update did not finish successfully but continuing"
  apt-get install -y software-properties-common apt-transport-https
  
  IFS=',' read -ra KEY_ARRAY <<< "$INSTALL_REPOSITORY_KEYS"
  for key in "${KEY_ARRAY[@]}"; do
    wget -qO - "$key" | apt-key add -
  done
  
  IFS=',' read -ra REPO_ARRAY <<< "$INSTALL_REPOSITORY_SOURCES"
  for repo_src in "${REPO_ARRAY[@]}"; do
    add-apt-repository -y "$repo_src"
  done
  
fi

# install packages
apt-get clean
apt-get update --fix-missing || echo "Update did not finish successfully but continuing"
apt-get install -y $INSTALL_PACKAGES
apt-get clean
rm -rf /var/lib/apt/lists/*

fi
