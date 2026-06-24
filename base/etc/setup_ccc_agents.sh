#!/bin/sh
# setup_ccc_agents.sh — install / update / wire the ccc-agent-containment runtime
# (bwrap + branchfs + the ccc-agent-containment pip package + hooks/config).
#
# Called from TWO places:
#   * the image build (base/Dockerfile, `--install-only`): bakes the heavy,
#     user-independent bits (bwrap, branchfs binary, pip package) into the image
#     so an enabled container starts instantly;
#   * container startup (runit 06_ccc_agent_containment.sh, default = both
#     phases): a FAST no-op when the baked-in versions already match, and only
#     rebuilds / re-pips when a newer ref is requested via env (see UPDATING).
#
# Phases:
#   install  heavy + user-independent: bwrap, branchfs (built from source),
#            ccc-agent-containment pip package, libfuse runtime.  Version-guarded
#            by per-component marker files under ${install_dir}.
#   wire     light + user-specific: `ccc-agent-setup` writes /etc/ccc-agent/
#            config.json, the managed Claude Stop hook, the codex notify hook,
#            and (optionally) the transparent PATH shims.  Needs USER_NAME, so it
#            runs at container startup, NOT at build.
#
# UPDATING (env-controlled, the whole point of keeping this callable at runtime):
#   * Request a different ref and it is rebuilt/re-installed:
#       CCC_AGENT_CONTAINMENT_REF=<branch|tag|sha>            (the pip package)
#       CCC_AGENT_CONTAINMENT_BRANCHFS_REF=<branch|tag|sha>   (branchfs)
#     A changed ref vs. what the image baked (recorded in the marker) triggers a
#     reinstall of just that component; an unchanged ref is skipped.
#   * Force a refresh even when the ref name is unchanged (e.g. new commits on
#     the same branch):
#       CCC_AGENT_CONTAINMENT_UPDATE=1            (force everything)
#       CCC_AGENT_CONTAINMENT_BRANCHFS_UPDATE=1   (force just branchfs)
#
# All installs are best-effort: a failure warns but does not abort container
# startup, and every step is idempotent.
set -eu

truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

# --- phase selection ---------------------------------------------------------
do_install=1
do_wire=1
for arg in "$@"; do
    case "${arg}" in
        --install-only|--install) do_wire=0 ;;
        --wire-only|--wire)       do_install=0 ;;
        --all)                    do_install=1; do_wire=1 ;;
        *) echo "setup_ccc_agents.sh: unknown argument '${arg}'" >&2; exit 2 ;;
    esac
done

# --- configuration (env-overridable) -----------------------------------------
repo="${CCC_AGENT_CONTAINMENT_REPO:-https://github.com/vicoslab/ccc-agent-containment.git}"
ref="${CCC_AGENT_CONTAINMENT_REF:-master}"
install_dir="${CCC_AGENT_CONTAINMENT_INSTALL_DIR:-/opt/ccc-agent}"
config_dir="${CCC_AGENT_CONTAINMENT_CONFIG_DIR:-/etc/ccc-agent}"
config_file="${CCC_AGENT_CONFIG:-${config_dir}/config.json}"
link_dir="${CCC_AGENT_CONTAINMENT_LINK_DIR:-/usr/local/bin}"
enable_shims="${CCC_AGENT_CONTAINMENT_ENABLE_SHIMS:-0}"
shim_agents="${CCC_AGENT_CONTAINMENT_SHIM_AGENTS:-codex claude hermes opencode}"

install_deps="${CCC_AGENT_CONTAINMENT_INSTALL_DEPS:-1}"
branchfs_bin="${CCC_AGENT_CONTAINMENT_BRANCHFS_BIN:-}"
branchfs_repo="${CCC_AGENT_CONTAINMENT_BRANCHFS_REPO:-https://github.com/vicoslab/branchfs.git}"
branchfs_ref="${CCC_AGENT_CONTAINMENT_BRANCHFS_REF:-master}"
branchfs_dest="${CCC_AGENT_CONTAINMENT_BRANCHFS_DEST:-/usr/local/bin/branchfs}"

# Force-update toggles (refresh even when the ref name is unchanged).
update_all="${CCC_AGENT_CONTAINMENT_UPDATE:-0}"
update_branchfs="${CCC_AGENT_CONTAINMENT_BRANCHFS_UPDATE:-${update_all}}"
update_pip="${CCC_AGENT_CONTAINMENT_PIP_UPDATE:-${update_all}}"

# Per-component "what is installed" markers (compared against requested refs).
branchfs_marker="${install_dir}/.branchfs-ref"
pip_marker="${install_dir}/.ccc-agent-ref"

apt_get() { DEBIAN_FRONTEND=noninteractive apt-get "$@"; }

umask 022
tmpdir="$(mktemp -d)"
cleanup() { rm -rf "${tmpdir}"; }
trap cleanup EXIT INT TERM
mkdir -p "${install_dir}"

# =============================================================================
# install phase — heavy, user-independent, version-guarded
# =============================================================================

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

branchfs_present() {
    { [ -n "${branchfs_bin}" ] && [ -x "${branchfs_bin}" ]; } \
        || [ -x "${branchfs_dest}" ] || command -v branchfs >/dev/null 2>&1
}

branchfs_up_to_date() {
    # A prebuilt binary supplied via env is authoritative — never rebuild.
    [ -n "${branchfs_bin}" ] && [ -x "${branchfs_bin}" ] && return 0
    truthy "${update_branchfs}" && return 1
    branchfs_present || return 1
    [ "$(cat "${branchfs_marker}" 2>/dev/null || true)" = "${branchfs_ref}" ]
}

ensure_branchfs() {
    if branchfs_up_to_date; then
        ensure_libfuse
        return 0
    fi
    truthy "${install_deps}" || { echo "ccc-agent-containment: branchfs missing/stale and INSTALL_DEPS=0" >&2; return 0; }
    command -v apt-get >/dev/null 2>&1 || { echo "ccc-agent-containment: no apt-get; cannot build branchfs" >&2; return 0; }

    echo "ccc-agent-containment: building branchfs from ${branchfs_repo}@${branchfs_ref}"
    apt_get update -qq || true
    apt_get install -y --no-install-recommends \
        libfuse3-dev pkg-config build-essential ca-certificates curl git \
        || { echo "ccc-agent-containment: warning: branchfs build deps failed" >&2; return 0; }

    # Rust toolchain (NOT present by default).  branchfs ships a v4 Cargo.lock,
    # which needs cargo >= 1.78 -- newer than apt's cargo on every current
    # Ubuntu (apt cargo is ~1.75 and fails with "lock file version 4 requires
    # -Znext-lockfile-bump").  Use an existing cargo ONLY if it is new enough,
    # otherwise install a current toolchain via rustup (discarded after build).
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
            printf '%s\n' "${branchfs_ref}" > "${branchfs_marker}"
            echo "ccc-agent-containment: installed branchfs -> ${branchfs_dest} (ref ${branchfs_ref})"
        else
            echo "ccc-agent-containment: warning: failed to install branchfs binary" >&2
        fi
    else
        echo "ccc-agent-containment: warning: branchfs build failed" >&2
    fi
}

# Resolve the SYSTEM python EXPLICITLY (not `pip`/`python3` on PATH, which may be
# conda's when a user env is active).  This pins console-script shebangs to
# /usr/bin/python3 and lands the package under /usr, so the entry points work
# even with conda active and inside the bwrap sandbox (which only exposes /usr).
syspy() {
    p="${CCC_AGENT_CONTAINMENT_SYSTEM_PYTHON:-/usr/bin/python3}"
    [ -x "${p}" ] || p="$(command -v python3 || true)"
    printf '%s' "${p}"
}

pip_up_to_date() {
    truthy "${update_pip}" && return 1
    command -v ccc-agent-setup >/dev/null 2>&1 || return 1
    [ "$(cat "${pip_marker}" 2>/dev/null || true)" = "${ref}" ]
}

ensure_pip_package() {
    if pip_up_to_date; then
        return 0
    fi
    sp="$(syspy)"
    [ -n "${sp}" ] || { echo "ccc-agent-containment: ERROR: no system python3" >&2; return 1; }

    if ! "${sp}" -m pip --version >/dev/null 2>&1; then
        if truthy "${install_deps}" && command -v apt-get >/dev/null 2>&1; then
            echo "ccc-agent-containment: installing python3-pip for ${sp}"
            apt_get update -qq || true
            apt_get install -y --no-install-recommends python3-pip \
                || echo "ccc-agent-containment: warning: python3-pip install failed" >&2
        fi
    fi

    pip_spec="git+${repo}@${ref}"
    echo "ccc-agent-containment: pip-installing ${pip_spec} into ${sp}"
    if ! "${sp}" -m pip install --break-system-packages --upgrade "${pip_spec}" 2>/dev/null; then
        # older pip (no --break-system-packages) or non-PEP668 env
        "${sp}" -m pip install --upgrade "${pip_spec}" \
            || { echo "ccc-agent-containment: ERROR: pip install of ${pip_spec} failed" >&2; return 1; }
    fi
    printf '%s\n' "${ref}" > "${pip_marker}"
}

run_install() {
    if ! command -v git >/dev/null 2>&1; then
        echo "ccc-agent-containment: git is required to install ${repo}" >&2
        return 1
    fi
    ensure_bwrap
    ensure_branchfs
    ensure_pip_package
}

# =============================================================================
# wire phase — light, user-specific (needs USER_NAME); container startup only
# =============================================================================

run_wire() {
    branchfs_resolved="${branchfs_bin:-$(command -v branchfs 2>/dev/null || echo "${branchfs_dest}")}"
    bwrap_resolved="${CCC_AGENT_CONTAINMENT_BWRAP_BIN:-$(command -v bwrap 2>/dev/null || echo bwrap)}"

    setup_bin="$(command -v ccc-agent-setup 2>/dev/null || true)"
    if [ -z "${setup_bin}" ]; then
        for d in /usr/local/bin /usr/bin; do
            [ -x "${d}/ccc-agent-setup" ] && { setup_bin="${d}/ccc-agent-setup"; break; }
        done
    fi
    [ -n "${setup_bin}" ] || { echo "ccc-agent-containment: ERROR: ccc-agent-setup not found (run the install phase first)" >&2; return 1; }

    # Version-skew guard: this image's wiring passes the /storage-layout flags
    # (--storage-root etc.), which an older installed ccc-agent-containment does
    # not understand.  Detect that instead of crashing with an argparse dump or,
    # worse, silently wiring the wrong (legacy) layout.
    if ! "${setup_bin}" --help 2>&1 | grep -q -- '--storage-root'; then
        echo "ccc-agent-containment: ERROR: installed ccc-agent-setup predates the /storage-layout flags (--storage-root); cannot wire the storage layout." >&2
        echo "ccc-agent-containment: update the runtime to a build that has them, e.g. set CCC_AGENT_CONTAINMENT_UPDATE=1 (optionally with CCC_AGENT_CONTAINMENT_REF / _REPO pointing at that build) and restart." >&2
        return 1
    fi

    # Path wiring (only known at runtime, never at build): CCC mounts the user's
    # storage at /storage and the home at /storage/user/<container>.  The agent
    # gets ONE BranchFS branch over all of /storage (read-through), with deltas
    # in a node-local store OUTSIDE /storage, mounted back at /storage in the
    # sandbox; $HOME maps to <storage>/user/<container> of that same branch.
    storage_root="${CCC_AGENT_STORAGE_ROOT:-/storage}"
    state_dir="${CCC_AGENT_STATE_DIR:-/storage/user/.ccc-agents}"
    branch_store="${CCC_AGENT_BRANCH_STORE:-/storage/user/.ccc-agents}"
    container_name="${CCC_AGENT_CONTAINER_NAME:-${CONTAINER_NAME:-}}"
    

    register_hooks="${CCC_AGENT_CONTAINMENT_REGISTER_HOOKS:-${enable_shims}}"
    set -- --system --config "${config_file}" --user-name "${USER_NAME:-user}" \
        --branchfs-bin "${branchfs_resolved}" --bwrap-bin "${bwrap_resolved}" \
        --storage-root "${storage_root}" --branch-store "${branch_store}"
    [ -n "${container_name}" ] && set -- "$@" --container-name "${container_name}"
    [ -n "${state_dir}" ] && set -- "$@" --state-dir "${state_dir}"
    truthy "${register_hooks}" || set -- "$@" --no-hooks
    truthy "${enable_shims}" && set -- "$@" --enable-shims --shim-agents "${shim_agents}" --link-dir "${link_dir}"
    "${setup_bin}" "$@"
    echo "ccc-agent-containment: wired; CCC_AGENT_CONFIG=${config_file}"
}

# =============================================================================

# Best-effort: a phase failure warns but never aborts container startup (see the
# contract in the header). At build time (--install-only via the Dockerfile) a
# real failure should still surface, so only soften at runtime (when wiring).
if [ "${do_wire}" = 1 ]; then
    [ "${do_install}" = 1 ] && { run_install || echo "ccc-agent-containment: install phase failed (best-effort; continuing)" >&2; }
    run_wire || echo "ccc-agent-containment: wire phase failed (best-effort; continuing)" >&2
else
    [ "${do_install}" = 1 ] && run_install
fi
exit 0
