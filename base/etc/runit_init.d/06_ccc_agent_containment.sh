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

    # Rust toolchain (NOT present by default).  branchfs ships a v4 Cargo.lock,
    # which needs cargo >= 1.78 -- newer than apt's cargo on every current
    # Ubuntu (apt cargo is ~1.75 and fails with "lock file version 4 requires
    # -Znext-lockfile-bump").  So use an existing cargo ONLY if it is new
    # enough, otherwise install a current toolchain via rustup.
    cargo_bin=""
    existing="$(command -v cargo 2>/dev/null || true)"
    if [ -n "${existing}" ] && "${existing}" --version 2>/dev/null \
         | awk '{split($2,a,"."); exit !(a[1]>1 || (a[1]==1 && a[2]>=78))}'; then
        cargo_bin="${existing}"
    elif [ -n "${existing}" ]; then
        echo "ccc-agent-containment: cargo $(${existing} --version 2>/dev/null | awk '{print $2}') too old for branchfs (Cargo.lock v4 needs >= 1.78); using rustup"
    fi
    if [ -z "${cargo_bin}" ]; then
        echo "ccc-agent-containment: installing a current rust toolchain via rustup"
        export RUSTUP_HOME="${tmpdir}/rustup" CARGO_HOME="${tmpdir}/cargo"
        curl -fsSL https://sh.rustup.rs \
            | sh -s -- -y --no-modify-path --profile minimal >/dev/null 2>&1 || true
        [ -x "${CARGO_HOME}/bin/cargo" ] && cargo_bin="${CARGO_HOME}/bin/cargo"
    fi
    if [ -z "${cargo_bin}" ]; then
        echo "ccc-agent-containment: warning: no suitable rust toolchain; cannot build branchfs" >&2
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

# --- install the runtime via pip into the SYSTEM python ----------------------
# Use the system python EXPLICITLY (not `pip`/`python3` on PATH, which may be
# conda's when a user env is active).  This pins the console-script shebangs to
# /usr/bin/python3 and lands the package under /usr, so the entry points work
# even with conda active and inside the bwrap sandbox (which only exposes /usr).
syspy="${CCC_AGENT_CONTAINMENT_SYSTEM_PYTHON:-/usr/bin/python3}"
[ -x "${syspy}" ] || syspy="$(command -v python3 || true)"
[ -n "${syspy}" ] || { echo "ccc-agent-containment: ERROR: no system python3" >&2; exit 1; }

if ! "${syspy}" -m pip --version >/dev/null 2>&1; then
    if truthy "${install_deps}" && command -v apt-get >/dev/null 2>&1; then
        echo "ccc-agent-containment: installing python3-pip for ${syspy}"
        apt_get update -qq || true
        apt_get install -y --no-install-recommends python3-pip \
            || echo "ccc-agent-containment: warning: python3-pip install failed" >&2
    fi
fi

pip_spec="git+${repo}@${ref}"
echo "ccc-agent-containment: pip-installing ${pip_spec} into ${syspy}"
if ! "${syspy}" -m pip install --break-system-packages --upgrade "${pip_spec}" 2>/dev/null; then
    # older pip (no --break-system-packages) or non-PEP668 env
    "${syspy}" -m pip install --upgrade "${pip_spec}" \
        || { echo "ccc-agent-containment: ERROR: pip install of ${pip_spec} failed" >&2; exit 1; }
fi

# Resolve the installed binaries + the ccc-agent-setup entry point.
branchfs_resolved="${CCC_AGENT_CONTAINMENT_BRANCHFS_BIN:-$(command -v branchfs 2>/dev/null || echo "${branchfs_dest}")}"
bwrap_resolved="${CCC_AGENT_CONTAINMENT_BWRAP_BIN:-$(command -v bwrap 2>/dev/null || echo bwrap)}"
setup_bin="$(command -v ccc-agent-setup 2>/dev/null || true)"
if [ -z "${setup_bin}" ]; then
    for d in /usr/local/bin /usr/bin; do
        [ -x "${d}/ccc-agent-setup" ] && { setup_bin="${d}/ccc-agent-setup"; break; }
    done
fi
[ -n "${setup_bin}" ] || { echo "ccc-agent-containment: ERROR: ccc-agent-setup not found after pip install" >&2; exit 1; }

# Wire config + hooks via ccc-agent-setup (generates /etc/ccc-agent/config.json,
# the managed Claude settings, and the codex notify entry; hook paths point into
# the installed package under /usr, which the sandbox exposes).
register_hooks="${CCC_AGENT_CONTAINMENT_REGISTER_HOOKS:-${enable_shims}}"
set -- --system --config "${config_file}" --user-name "${USER_NAME:-user}" \
    --branchfs-bin "${branchfs_resolved}" --bwrap-bin "${bwrap_resolved}"
[ -n "${CCC_AGENT_STATE_DIR:-}" ] && set -- "$@" --state-dir "${CCC_AGENT_STATE_DIR}"
[ -n "${CCC_AGENT_STORAGE_USER_BASE:-}" ] && set -- "$@" --storage-base "${CCC_AGENT_STORAGE_USER_BASE}"
[ -n "${CCC_AGENT_STORAGE_USER_STORE:-}" ] && set -- "$@" --storage-store "${CCC_AGENT_STORAGE_USER_STORE}"
truthy "${register_hooks}" || set -- "$@" --no-hooks
truthy "${enable_shims}" && set -- "$@" --enable-shims --shim-agents "${shim_agents}" --link-dir "${link_dir}"
"${setup_bin}" "$@"

echo "ccc-agent-containment: installed; CCC_AGENT_CONFIG=${config_file}"
