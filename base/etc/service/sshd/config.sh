#!/usr/bin/env sh

KEYS=${BASE%"/"}/.sshd/keys

if [ ! -f "$KEYS/ssh_host_rsa_key" ]; then
    mkdir -p $KEYS
    chown root:root $KEYS
    chmod 700 $KEYS
    ssh-keygen -f   $KEYS/ssh_host_rsa_key     -N '' -t rsa
    ssh-keygen -f   $KEYS/ssh_host_ecdsa_key   -N '' -t ecdsa
    ssh-keygen -f   $KEYS/ssh_host_ed25519_key -N '' -t ed25519
fi

