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

append_setenv() {
    key="$1"
    val=$(eval "printf '%s' \"\${${key}:-}\"")
    if [ -z "$val" ]; then
        return 0
    fi

    # These runtime identity values are expected to be simple names/paths. Skip
    # unusual values instead of writing surprising sshd_config syntax.
    case "$val" in
        *[!A-Za-z0-9_./:-]*)
            echo "Skipping SSH SetEnv for $key: unsupported characters" >&2
            return 0
            ;;
    esac

    printf 'SetEnv %s=%s\n' "$key" "$val" >> /etc/ssh/sshd_config
}

cat >>/etc/ssh/sshd_config << EOF

# Container runtime identity for SSH sessions. This covers non-interactive
# SSH commands such as running archivemount remotely without requiring shell
# profile startup or enabling the full PAM account/session stack.
EOF
for key in CONTAINER_NAME CONTAINER_NODE CCC_FUSE_SIDECAR_SOCKET CCC_FUSE_SOCKET_DIR; do
    append_setenv "$key"
done

