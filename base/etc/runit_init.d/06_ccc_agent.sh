#!/bin/sh
set -eu

truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

as_agent() {
    if [ "$agent_is_root" = 1 ]; then
        chpst -u "$agent_user" "$@"
    else
        "$@"
    fi
}

ensure_runtime_dir() {
    dir="$1"
    if [ ! -d "$dir" ]; then
        if [ -e "$dir" ] || [ -L "$dir" ]; then
            echo "agent runtime: ERROR: expected directory: $dir" >&2
            return 1
        fi
        mkdir -p "$dir"
    fi
    chmod 700 "$dir"
    if [ "$agent_is_root" = 1 ]; then
        chown "$agent_uid:$agent_gid" "$dir"
    fi
}

ensure_home_dir() {
    dir="$1"
    if [ ! -d "$dir" ]; then
        if [ -e "$dir" ] || [ -L "$dir" ]; then
            echo "agent runtime: ERROR: expected directory: $dir" >&2
            return 1
        fi
        as_agent mkdir -p "$dir"
    fi
    as_agent chmod 700 "$dir"
}

link_local_runtime() {
    link="$1"
    target="$2"
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
        return 0
    fi

    new="${link}.ccc-runtime-new.$$"
    old="${link}.ccc-runtime-old.$$"
    # These two paths contain runtime-only sockets/locks/logs. Rename first so
    # replacement is recoverable if installing the symlink fails.
    as_agent rm -f -- "$new"
    as_agent ln -s "$target" "$new"
    moved=0
    if [ -e "$link" ] || [ -L "$link" ]; then
        if as_agent mv -T "$link" "$old" 2>/dev/null; then
            moved=1
        elif [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
            as_agent rm -f -- "$new"
            return 0
        fi
    fi
    if ! as_agent mv -Tf "$new" "$link"; then
        as_agent rm -f -- "$new"
        if [ "$moved" = 1 ] && [ ! -e "$link" ] && [ ! -L "$link" ]; then
            as_agent mv -T "$old" "$link"
        fi
        return 1
    fi
    [ "$moved" = 0 ] || as_agent rm -rf -- "$old"
}

setup_local_agent_runtime() {
    agent_user="${USER_NAME:-user}"
    agent_home="${BASE:-/home}"
    agent_home="${agent_home%/}/$agent_user"
    agent_uid=$(id -u "$agent_user")
    agent_gid=$(id -g "$agent_user")
    agent_is_root=0
    [ "$(id -u)" != 0 ] || agent_is_root=1
    user_runtime="${CCC_AGENT_USER_RUNTIME_DIR:-/run/user/$agent_uid}"
    runtime_root="${CCC_AGENT_RUNTIME_ROOT:-$user_runtime/ccc-agent-runtime}"

    ensure_runtime_dir "$user_runtime"
    ensure_runtime_dir "$runtime_root"
    ensure_runtime_dir "$runtime_root/claude"
    ensure_runtime_dir "$runtime_root/codex"
    ensure_home_dir "$agent_home/.claude"
    ensure_home_dir "$agent_home/.claude/remote"
    ensure_home_dir "$agent_home/.codex"
    link_local_runtime "$agent_home/.claude/remote/run" "$runtime_root/claude"
    link_local_runtime "$agent_home/.codex/app-server-control" "$runtime_root/codex"
}

# Claude and Codex keep sockets, locks and active-server metadata under $HOME.
# CCC homes may be shared, but /run is private to each container. Localize these
# ephemeral paths for every container, independently of ccc-agent enablement.
setup_local_agent_runtime

# Non-default by design: CCC images only ACTIVATE the ccc-agent
# runtime when explicitly requested at container startup.
if ! truthy "${CCC_AGENT_ENABLE:-0}"; then
    exit 0
fi

# All real work lives in the shared installer so the exact same code runs at
# image build time (base/Dockerfile, `--install-only`) and here at startup.
#
# If the image was built with CCC_AGENT_PREINSTALL=1, the user-independent bits
# (bwrap + libfuse + ccc-agent[branchfs]) are already baked in and the install
# phase is a fast no-op; it only re-pips when a NEWER ccc-agent ref is requested
# via env (CCC_AGENT_REF or *_UPDATE=1). The wire phase (config + hooks, which
# need USER_NAME) always runs here.
setup="/etc/setup_ccc_agent.sh"
if [ ! -f "${setup}" ]; then
    echo "ccc-agent: ERROR: ${setup} missing from image" >&2
    exit 1
fi

exec sh "${setup}"
