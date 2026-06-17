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
  
  # `apt-key` was removed on Ubuntu 24.04 (noble); drop each custom repo key into
  # /etc/apt/trusted.gpg.d instead (apt reads ASCII-armored *.asc keys there). This works
  # on both 22.04 and 24.04.
  mkdir -p /etc/apt/trusted.gpg.d
  IFS=',' read -ra KEY_ARRAY <<< "$INSTALL_REPOSITORY_KEYS"
  key_idx=0
  for key in "${KEY_ARRAY[@]}"; do
    [ -z "$key" ] && continue
    tmp_key=$(mktemp)
    trap 'rm -f "$tmp_key"' EXIT
    if wget -qO "$tmp_key" "$key"; then
      dest="/etc/apt/trusted.gpg.d/ccc-custom-${key_idx}.asc"
      mv "$tmp_key" "$dest"
      chmod 644 "$dest"
      tmp_key=""
      key_idx=$((key_idx+1))
    else
      rm -f "$tmp_key"
      tmp_key=""
      echo "failed to fetch custom repository key: $key"
    fi
    trap - EXIT
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
