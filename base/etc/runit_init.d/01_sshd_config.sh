#!/bin/bash -e

cat >/etc/ssh/sshd_config << EOF
HostKey $BASE/.sshd/keys/ssh_host_rsa_key
HostKey $BASE/.sshd/keys/ssh_host_ecdsa_key
HostKey $BASE/.sshd/keys/ssh_host_ed25519_key

# Disable ipv6
AddressFamily inet

PermitRootLogin no
PubkeyAuthentication yes
HostbasedAuthentication no
IgnoreRhosts yes

# To disable tunneled clear text passwords, change to no here!
PasswordAuthentication no
PermitEmptyPasswords no

# Change to no to disable s/key passwords
ChallengeResponseAuthentication no

PermitTunnel yes
AllowAgentForwarding yes
X11Forwarding yes
X11UseLocalhost no
AllowTcpForwarding yes

# User internal sftp
Subsystem sftp internal-sftp

# Enable message-of-the-day on SSH logins
PrintMotd yes
EOF

