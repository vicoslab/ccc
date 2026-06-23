#!/bin/sh
set -eu

truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        0|false|FALSE|no|NO|off|OFF|"") return 1 ;;
        *) return 1 ;;
    esac
}

# Non-default by design: CCC images only install/activate the external
# ccc-agent-containment runtime when explicitly requested at container startup.
if ! truthy "${CCC_AGENT_CONTAINMENT_ENABLE:-0}"; then
    exit 0
fi

repo="${CCC_AGENT_CONTAINMENT_REPO:-https://github.com/vicoslab/ccc-agent-containment.git}"
ref="${CCC_AGENT_CONTAINMENT_REF:-master}"
install_dir="${CCC_AGENT_CONTAINMENT_INSTALL_DIR:-/opt/ccc-agent}"
config_dir="${CCC_AGENT_CONTAINMENT_CONFIG_DIR:-/etc/ccc-agent}"
config_file="${CCC_AGENT_CONFIG:-${config_dir}/config.json}"
link_dir="${CCC_AGENT_CONTAINMENT_LINK_DIR:-/usr/local/bin}"
enable_shims="${CCC_AGENT_CONTAINMENT_ENABLE_SHIMS:-0}"
shim_agents="${CCC_AGENT_CONTAINMENT_SHIM_AGENTS:-codex claude hermes opencode}"
branchfs_bin="${CCC_AGENT_CONTAINMENT_BRANCHFS_BIN:-}"

# Dependencies (bwrap + branchfs) are installed into system dirs so they are
# always on PATH. branchfs is built from the vicoslab fork branch by default.
install_deps="${CCC_AGENT_CONTAINMENT_INSTALL_DEPS:-1}"
branchfs_repo="${CCC_AGENT_CONTAINMENT_BRANCHFS_REPO:-https://github.com/vicoslab/branchfs.git}"
branchfs_ref="${CCC_AGENT_CONTAINMENT_BRANCHFS_REF:-feat/ccc-agent-containment}"
branchfs_dest="${CCC_AGENT_CONTAINMENT_BRANCHFS_DEST:-/usr/local/bin/branchfs}"

if ! command -v git >/dev/null 2>&1; then
    echo "ccc-agent-containment: git is required to install ${repo}" >&2
    exit 1
fi

umask 022
tmpdir="$(mktemp -d)"
cleanup() {
    rm -rf "${tmpdir}"
}
trap cleanup EXIT INT TERM

# --- system dependencies: bwrap + branchfs (installed into system dirs) -------
# All installs are best-effort: a failure warns but never aborts container
# startup, and everything is idempotent (skipped when already present).
apt_get() { DEBIAN_FRONTEND=noninteractive apt-get "$@"; }

ensure_libfuse() {
    # branchfs links libfuse3 at runtime; make the shared lib available so the
    # binary is callable without LD_LIBRARY_PATH. (Does NOT install fuse3 /
    # fusermount3 — that stays the CCC sidecar shim.)
    truthy "${install_deps}" || return 0
    command -v apt-get >/dev/null 2>&1 || return 0
    if ! ldconfig -p 2>/dev/null | grep -q 'libfuse3\.so'; then
        apt_get update -qq || true
        apt_get install -y --no-install-recommends libfuse3-3 \
            || echo "ccc-agent-containment: warning: failed to install libfuse3 runtime" >&2
    fi
}

ensure_bwrap() {
    command -v bwrap >/dev/null 2>&1 && return 0
    [ -n "${CCC_AGENT_CONTAINMENT_BWRAP_BIN:-}" ] && [ -x "${CCC_AGENT_CONTAINMENT_BWRAP_BIN}" ] && return 0
    truthy "${install_deps}" || return 0
    command -v apt-get >/dev/null 2>&1 || return 0
    echo "ccc-agent-containment: installing bubblewrap (bwrap)"
    apt_get update -qq || true
    apt_get install -y --no-install-recommends bubblewrap \
        || echo "ccc-agent-containment: warning: failed to install bubblewrap" >&2
}

ensure_branchfs() {
    # Usable binary already provided/installed? Just make sure libfuse is there.
    if { [ -n "${CCC_AGENT_CONTAINMENT_BRANCHFS_BIN:-}" ] && [ -x "${CCC_AGENT_CONTAINMENT_BRANCHFS_BIN}" ]; } \
       || [ -x "${branchfs_dest}" ] || command -v branchfs >/dev/null 2>&1; then
        ensure_libfuse
        return 0
    fi
    truthy "${install_deps}" || { echo "ccc-agent-containment: branchfs missing and INSTALL_DEPS=0" >&2; return 0; }
    command -v apt-get >/dev/null 2>&1 || { echo "ccc-agent-containment: no apt-get; cannot build branchfs" >&2; return 0; }

    echo "ccc-agent-containment: building branchfs from ${branchfs_repo}@${branchfs_ref}"
    apt_get update -qq || true
    apt_get install -y --no-install-recommends \
        libfuse3-dev pkg-config build-essential ca-certificates curl git \
        || { echo "ccc-agent-containment: warning: branchfs build deps failed" >&2; return 0; }

    # Rust toolchain (NOT present by default): prefer an existing cargo, then
    # apt's cargo/rustc (branchfs is edition 2021, no MSRV pin -> apt rust is
    # new enough), then a minimal rustup as a last resort.
    cargo_bin="$(command -v cargo 2>/dev/null || true)"
    if [ -z "${cargo_bin}" ]; then
        echo "ccc-agent-containment: installing rust toolchain (cargo/rustc) via apt"
        apt_get install -y --no-install-recommends cargo rustc || true
        cargo_bin="$(command -v cargo 2>/dev/null || true)"
    fi
    if [ -z "${cargo_bin}" ]; then
        echo "ccc-agent-containment: apt rust unavailable; installing via rustup"
        export RUSTUP_HOME="${tmpdir}/rustup" CARGO_HOME="${tmpdir}/cargo"
        curl -fsSL https://sh.rustup.rs \
            | sh -s -- -y --no-modify-path --profile minimal >/dev/null 2>&1 || true
        [ -x "${CARGO_HOME}/bin/cargo" ] && cargo_bin="${CARGO_HOME}/bin/cargo"
    fi
    if [ -z "${cargo_bin}" ]; then
        echo "ccc-agent-containment: warning: no rust toolchain; cannot build branchfs" >&2
        return 0
    fi

    bsrc="${tmpdir}/branchfs"
    if ! git clone --depth 1 --branch "${branchfs_ref}" "${branchfs_repo}" "${bsrc}" 2>/dev/null; then
        if ! { git clone "${branchfs_repo}" "${bsrc}" && git -C "${bsrc}" checkout "${branchfs_ref}"; }; then
            echo "ccc-agent-containment: warning: branchfs clone failed" >&2
            return 0
        fi
    fi
    if ( cd "${bsrc}" && "${cargo_bin}" build --release ); then
        if install -m 0755 "${bsrc}/target/release/branchfs" "${branchfs_dest}"; then
            echo "ccc-agent-containment: installed branchfs -> ${branchfs_dest}"
        else
            echo "ccc-agent-containment: warning: failed to install branchfs binary" >&2
        fi
    else
        echo "ccc-agent-containment: warning: branchfs build failed" >&2
    fi
}

ensure_bwrap
ensure_branchfs

src="${tmpdir}/src"
echo "ccc-agent-containment: installing ${repo}@${ref} into ${install_dir}"
if ! git clone --depth 1 --branch "${ref}" "${repo}" "${src}"; then
    echo "ccc-agent-containment: shallow clone failed; retrying full clone" >&2
    git clone "${repo}" "${src}"
    git -C "${src}" checkout "${ref}"
fi

rm -rf "${tmpdir}/runtime"
mkdir -p "${tmpdir}/runtime"
for path in bin ccc_agent config hooks scripts shims README.md docs; do
    if [ -e "${src}/${path}" ]; then
        cp -a "${src}/${path}" "${tmpdir}/runtime/${path}"
    fi
done

rm -rf "${install_dir}"
mkdir -p "$(dirname "${install_dir}")"
cp -a "${tmpdir}/runtime" "${install_dir}"

# If BranchFS is already installed in the image/container, make the default
# ccc-agent config path work without baking BranchFS into the CCC image.
if [ -n "${branchfs_bin}" ] && [ -x "${branchfs_bin}" ]; then
    ln -sfn "${branchfs_bin}" "${install_dir}/bin/branchfs"
elif command -v branchfs >/dev/null 2>&1; then
    ln -sfn "$(command -v branchfs)" "${install_dir}/bin/branchfs"
else
    echo "ccc-agent-containment: warning: branchfs binary not found; set CCC_AGENT_CONTAINMENT_BRANCHFS_BIN before using branchfs backend" >&2
fi

# bwrap is the default confinement boundary; resolve it like branchfs.
bwrap_bin="${CCC_AGENT_CONTAINMENT_BWRAP_BIN:-}"
if [ -n "${bwrap_bin}" ] && [ -x "${bwrap_bin}" ]; then
    ln -sfn "${bwrap_bin}" "${install_dir}/bin/bwrap"
elif command -v bwrap >/dev/null 2>&1; then
    bwrap_bin="$(command -v bwrap)"
    ln -sfn "${bwrap_bin}" "${install_dir}/bin/bwrap"
else
    echo "ccc-agent-containment: warning: bwrap not found; install bubblewrap or set CCC_AGENT_CONTAINMENT_BWRAP_BIN for the default bwrap confinement" >&2
    bwrap_bin="${install_dir}/bin/bwrap"
fi

mkdir -p "${link_dir}"
for bin in ccc-agent-run ccc-agent-launch ccc-agentctl; do
    if [ -x "${install_dir}/bin/${bin}" ]; then
        ln -sfn "${install_dir}/bin/${bin}" "${link_dir}/${bin}"
    fi
done

mkdir -p "${config_dir}"
if [ ! -f "${config_file}" ]; then
    user_name="${USER_NAME:-user}"
    home_subdir="${CCC_AGENT_HOME_SUBDIR:-}"
    state_dir="${CCC_AGENT_STATE_DIR:-/storage/user/.ccc-agent}"
    storage_user_base="${CCC_AGENT_STORAGE_USER_BASE:-/__real/storage_user}"
    storage_user_store="${CCC_AGENT_STORAGE_USER_STORE:-/__branchfs_store/storage_user}"
    home="/home/${user_name}"
    cat > "${config_file}" <<EOF
{
  "_comment": "Generated by CCC runit startup when CCC_AGENT_CONTAINMENT_ENABLE=1. Keep root-owned and not writable by agents. See ${install_dir}/config/config.example.json for all keys and ${install_dir}/docs/agent-integration.md for hook/credential setup.",
  "state_dir": "${state_dir}",
  "backend": "branchfs",
  "branchfs_bin": "${install_dir}/bin/branchfs",
  "user": "${user_name}",
  "home_subdir": "${home_subdir}",

  "confinement": "bwrap",
  "bwrap_bin": "${bwrap_bin}",
  "bwrap_proc_mode": "bind",
  "_runtime_comment": "Re-expose the agent binary/runtime read-only at a NON-view dest (top-level or real /opt). codex/claude installed under \$HOME or /storage need an entry like '/path/to/agent:/opt/agent'.",
  "bwrap_ro_binds": [],

  "_cred_comment": "Agents read auth from these dirs; they're re-exposed read-only. OAuth-subscription logins (the common case) authenticate from the token file, so it must stay readable (do NOT add it to cred_mask). Use cred_mask + cred_env only for API-key auth.",
  "cred_mounts": ["${home}/.codex", "${home}/.claude"],
  "cred_mask": [],
  "cred_env": {},

  "roots": [
    {
      "name": "storage_user",
      "base": "${storage_user_base}",
      "store": "${storage_user_store}",
      "visible": "/storage/user",
      "home_subdir": "${home_subdir}",
      "hide_paths": [".ssh", ".gnupg", ".netrc", ".aws", ".kube", ".docker/config.json", ".ccc-agent"]
    }
  ],
  "hide_patterns": [".env", ".env.*", "*.pem", "id_rsa*", "id_ed25519*", "credentials.json"],
  "policy": {
    "mode": "workspace-auto",
    "ignore_patterns": ["/storage/user/.codex*", "/storage/user/.claude*", "/storage/user/.config*", "/storage/user/.cache*"]
  }
}
EOF
    chmod 0644 "${config_file}"
fi

if truthy "${enable_shims}"; then
    for agent in ${shim_agents}; do
        ln -sfn "${install_dir}/shims/ccc-agent-shim.sh" "${link_dir}/${agent}"
    done
fi

# Register the per-turn Stop hooks so interactive agents signal end-of-turn.
# Defaults on with shims; gate independently with CCC_AGENT_CONTAINMENT_REGISTER_HOOKS.
register_hooks="${CCC_AGENT_CONTAINMENT_REGISTER_HOOKS:-${enable_shims}}"
if truthy "${register_hooks}"; then
    # Claude Code: managed settings (a path the agent cannot rewrite).
    claude_managed="${CLAUDE_MANAGED_SETTINGS:-/etc/claude-code/managed-settings.json}"
    mkdir -p "$(dirname "${claude_managed}")"
    if [ ! -f "${claude_managed}" ]; then
        cat > "${claude_managed}" <<EOF
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "${install_dir}/hooks/claude-stop-hook.sh" } ] } ] } }
EOF
        chmod 0644 "${claude_managed}"
    fi
    # Codex: notify program in the user's config.toml (append if not present).
    codex_home="${CODEX_HOME:-/home/${USER_NAME:-user}/.codex}"
    mkdir -p "${codex_home}"
    if ! grep -q '^notify' "${codex_home}/config.toml" 2>/dev/null; then
        printf '\nnotify = ["%s/hooks/codex-notify.sh"]\n' "${install_dir}" \
            >> "${codex_home}/config.toml"
    fi
fi

echo "ccc-agent-containment: installed runtime; set CCC_AGENT_CONFIG=${config_file} for explicit use"
