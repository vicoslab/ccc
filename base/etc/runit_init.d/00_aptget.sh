#!/bin/bash -e

# create cache folder for apt to avoid crash issues during cleanup with missing files (should be tested)
mkdir -p /var/cache/apt/archives/partial

# make sure to install latest certificates in case root certificases have changed since docker was built
apt-get update || echo "Update did not finish successfully, but could be just updated GPG key so continuing"
apt-get install -y ca-certificates

if [ ! -z "$INSTALL_PACKAGES" ]; then

# add custom repos 
if [ ! -z "$INSTALL_REPOSITORY_SOURCES" ]; then
  apt-get clean
  apt-get update --fix-missing || echo "Update did not finish successfully, but could be just updated GPG key so continuing"
  apt-get install -y software-properties-common apt-transport-https
  
  IFS=',' read -ra KEY_ARRAY <<< "$INSTALL_REPOSITORY_KEYS"
  for key in "${KEY_ARRAY[@]}"; do
    wget -qO - "$key" | apt-key add -
  done
  
  IFS=',' read -ra REPO_ARRAY <<< "$INSTALL_REPOSITORY_SOURCES"
  for repo_src in "${REPO_ARRAY[@]}"; do
    add-apt-repository -y "$repo_src" || echo "add-apt-repository did not finish successfully, but could be just updated GPG key so continuing"
  done
  
fi

# install packages
apt-get clean
apt-get update --fix-missing || echo "Update did not finish successfully, but could be just updated GPG key so continuing"
apt-get install -y $INSTALL_PACKAGES
apt-get clean
rm -rf /var/lib/apt/lists/*

fi
