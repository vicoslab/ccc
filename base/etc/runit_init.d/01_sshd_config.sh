#!/bin/bash -e

sshd_config="${CCC_SSHD_CONFIG:-/etc/ssh/sshd_config}"
mkdir -p "$(dirname "$sshd_config")"

cat >"$sshd_config" << EOF
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

truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

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

    printf 'SetEnv %s=%s\n' "$key" "$val" >> "$sshd_config"
}

append_literal_setenv() {
    key="$1"
    val="$2"
    [ -n "$val" ] || return 0
    case "$val" in
        *[!A-Za-z0-9_./:-]*)
            echo "Skipping SSH SetEnv for $key: unsupported characters" >&2
            return 0
            ;;
    esac
    printf 'SetEnv %s=%s\n' "$key" "$val" >> "$sshd_config"
}

ccc_agent_shim_dir() {
    install_dir="${CCC_AGENT_INSTALL_DIR:-/opt/ccc-agent}"
    printf '%s\n' "${CCC_AGENT_LINK_DIR:-${install_dir}/shims}"
}

ccc_agent_ssh_path() {
    user_name="${USER_NAME:-user}"
    user_home="${BASE%/}/${user_name}"
    install_dir="${CCC_AGENT_INSTALL_DIR:-/opt/ccc-agent}"
    shim_dir="${CCC_AGENT_LINK_DIR:-${install_dir}/shims}"
    # Non-interactive SSH commands (ssh host codex --app) do not read .bashrc or
    # profile files. Give sshd sessions a complete useful PATH with the trusted
    # ccc-agent shim dir first, then the normal user-local/conda/system locations
    # the shim should expose as the underlying real-agent search path.
    printf '%s:%s/.local/bin:/usr/local/bin:%s/conda/bin:%s/conda/condabin:/usr/local/nvidia/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
        "$shim_dir" "$user_home" "$user_home" "$user_home"
}

cat >>"$sshd_config" << EOF

# Container runtime identity for SSH sessions. This covers non-interactive
# SSH commands such as running archivemount remotely without requiring shell
# profile startup or enabling the full PAM account/session stack.
EOF
for key in CONTAINER_NAME CONTAINER_NODE CCC_FUSE_SIDECAR_SOCKET CCC_FUSE_SOCKET_DIR; do
    append_setenv "$key"
done

if truthy "${CCC_AGENT_ENABLE_SHIMS:-0}"; then
    cat >>"$sshd_config" << EOF

# ccc-agent transparent shims for non-interactive SSH commands, e.g.
# `ssh host codex --app`. Interactive shells also source the generated shell
# hook from the user's rc/profile files.
EOF
    append_literal_setenv PATH "$(ccc_agent_ssh_path)"
    append_literal_setenv CCC_AGENT_SHIM_DIR "$(ccc_agent_shim_dir)"
    append_literal_setenv CCC_AGENT_ENABLE_SHIMS 1
    append_literal_setenv CCC_AGENT_REAL_SHELL "${CCC_AGENT_REAL_SHELL:-/bin/bash}"
fi
