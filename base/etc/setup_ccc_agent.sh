#!/bin/sh
# setup_ccc_agent.sh — install / update / wire the ccc-agent runtime
# (bwrap + ccc-agent pip package + packaged BranchFS binary + hooks/config).
#
# Called from TWO places:
#   * the image build (base/Dockerfile, `--install-only`): bakes the
#     user-independent bits (bwrap, libfuse runtime, ccc-agent[branchfs] pip
#     package) into the image so an enabled container starts instantly;
#   * container startup (runit 06_ccc_agent.sh, default = both phases): a FAST
#     no-op when the baked-in ref already matches, and only re-pips when a newer
#     ref is requested via env (see UPDATING).
#
# Phases:
#   install  user-independent: bwrap, libfuse runtime, ccc-agent pip package.
#            By default the pip package is installed with the [branchfs] extra,
#            which downloads the vicoslab BranchFS GitHub-release wheel.  No
#            Rust/Cargo toolchain is required.
#   wire     light + user-specific: `ccc-agent setup` writes /etc/ccc-agent/
#            config.json, the managed Claude Stop hook, the codex notify hook,
#            and (optionally) the transparent PATH shims.  Needs USER_NAME, so it
#            runs at container startup, NOT at build.
#
# UPDATING (env-controlled, the whole point of keeping this callable at runtime):
#   * Request a different ccc-agent ref and it is re-installed:
#       CCC_AGENT_REF=<branch|tag|sha>
#     A changed ref vs. what the image baked (recorded in the marker) triggers a
#     reinstall; an unchanged ref is skipped.
#   * Force a refresh even when the ref name is unchanged (e.g. new commits on
#     the same branch):
#       CCC_AGENT_UPDATE=1            (force pip reinstall)
#       CCC_AGENT_PIP_UPDATE=1        (force just pip reinstall)
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
        *) echo "setup_ccc_agent.sh: unknown argument '${arg}'" >&2; exit 2 ;;
    esac
done

# --- configuration (env-overridable) -----------------------------------------
repo="${CCC_AGENT_REPO:-https://github.com/vicoslab/ccc-agent.git}"
ref="${CCC_AGENT_REF:-master}"
install_dir="${CCC_AGENT_INSTALL_DIR:-/opt/ccc-agent}"
config_dir="${CCC_AGENT_CONFIG_DIR:-/etc/ccc-agent}"
config_file="${CCC_AGENT_CONFIG:-${config_dir}/config.json}"
link_dir="${CCC_AGENT_LINK_DIR:-${install_dir}/shims}"
shim_path_hook="${CCC_AGENT_SHIM_PATH_HOOK:-${config_dir}/shim-path.sh}"
ssh_shell_router="${CCC_AGENT_SSH_SHELL_ROUTER:-${install_dir}/bin/ccc-agent-ssh-shell-router}"
real_shell="${CCC_AGENT_REAL_SHELL:-/bin/bash}"
shells_file="${CCC_AGENT_SHELLS_FILE:-/etc/shells}"
enable_shims="${CCC_AGENT_ENABLE_SHIMS:-0}"
shim_agents="${CCC_AGENT_SHIM_AGENTS:-codex claude hermes opencode}"
conda_activate_shims="${CCC_AGENT_CONDA_ACTIVATE_SHIMS:-${enable_shims}}"
conda_prefix="${CCC_AGENT_CONDA_PREFIX:-${CONDA_PREFIX:-}}"

install_deps="${CCC_AGENT_INSTALL_DEPS:-1}"
install_branchfs_extra="${CCC_AGENT_INSTALL_BRANCHFS_EXTRA:-1}"
branchfs_bin="${CCC_AGENT_BRANCHFS_BIN:-}"

# Force-update toggles (refresh even when the ref name is unchanged).
update_all="${CCC_AGENT_UPDATE:-0}"
update_pip="${CCC_AGENT_PIP_UPDATE:-${update_all}}"

# Per-component "what is installed" markers (compared against requested refs).
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
            || echo "ccc-agent: warning: failed to install libfuse3 runtime" >&2
    fi
}

ensure_bwrap() {
    command -v bwrap >/dev/null 2>&1 && return 0
    bwrap_override="${CCC_AGENT_BWRAP_BIN:-}"
    [ -n "${bwrap_override}" ] && [ -x "${bwrap_override}" ] && return 0
    truthy "${install_deps}" || return 0
    command -v apt-get >/dev/null 2>&1 || return 0
    echo "ccc-agent: installing bubblewrap (bwrap)"
    apt_get update -qq || true
    apt_get install -y --no-install-recommends bubblewrap \
        || echo "ccc-agent: warning: failed to install bubblewrap" >&2
}

branchfs_present() {
    { [ -n "${branchfs_bin}" ] && [ -x "${branchfs_bin}" ]; } \
        || command -v branchfs >/dev/null 2>&1
}

ensure_branchfs_runtime() {
    ensure_libfuse
    # The default CCC path installs BranchFS through ccc-agent[branchfs] in
    # ensure_pip_package.  Keep this only as a post-install best-effort check so
    # images no longer need Rust/Cargo or a BranchFS source build.
    if branchfs_present; then
        return 0
    fi
    if truthy "${install_branchfs_extra}"; then
        echo "ccc-agent: warning: BranchFS binary not found after pip install; check ccc-agent[branchfs] install output" >&2
    else
        echo "ccc-agent: warning: BranchFS binary not found; set CCC_AGENT_BRANCHFS_BIN or enable CCC_AGENT_INSTALL_BRANCHFS_EXTRA=1" >&2
    fi
}

# Resolve the SYSTEM python EXPLICITLY (not `pip`/`python3` on PATH, which may be
# conda's when a user env is active).  This pins console-script shebangs to
# /usr/bin/python3 and lands the package under /usr, so the entry points work
# even with conda active and inside the bwrap sandbox (which only exposes /usr).
syspy() {
    p="${CCC_AGENT_SYSTEM_PYTHON:-/usr/bin/python3}"
    [ -x "${p}" ] || p="$(command -v python3 || true)"
    printf '%s' "${p}"
}

preferred_ccc_agent() {
    # Prefer the system-installed console script over whatever a user or conda
    # environment put first on PATH.  Startup wiring uses this binary to install
    # shims/plugins, so resolving ~/.local/bin/ccc-agent here can keep linking
    # stale package assets even after a system update was requested.
    for candidate in \
        "${CCC_AGENT_SETUP_BIN:-}" \
        "${link_dir}/ccc-agent" \
        /usr/local/bin/ccc-agent \
        /usr/bin/ccc-agent
    do
        [ -n "${candidate}" ] || continue
        [ -x "${candidate}" ] || continue
        printf '%s' "${candidate}"
        return 0
    done
    return 1
}

pip_up_to_date() {
    truthy "${update_pip}" && return 1
    preferred_ccc_agent >/dev/null 2>&1 || return 1
    [ "$(cat "${pip_marker}" 2>/dev/null || true)" = "${ref}" ]
}

ensure_pip_package() {
    if pip_up_to_date; then
        return 0
    fi
    sp="$(syspy)"
    [ -n "${sp}" ] || { echo "ccc-agent: ERROR: no system python3" >&2; return 1; }

    if ! "${sp}" -m pip --version >/dev/null 2>&1; then
        if truthy "${install_deps}" && command -v apt-get >/dev/null 2>&1; then
            echo "ccc-agent: installing python3-pip for ${sp}"
            apt_get update -qq || true
            apt_get install -y --no-install-recommends python3-pip \
                || echo "ccc-agent: warning: python3-pip install failed" >&2
        fi
    fi

    if truthy "${install_deps}"; then
        if ! "${sp}" -m pip install --break-system-packages --upgrade pip setuptools wheel 2>/dev/null; then
            "${sp}" -m pip install --upgrade pip setuptools wheel \
                || echo "ccc-agent: warning: pip self-upgrade failed; continuing with existing pip" >&2
        fi
    fi

    pip_extras=""
    truthy "${install_branchfs_extra}" && pip_extras="[branchfs]"
    pip_spec="ccc-agent${pip_extras} @ git+${repo}@${ref}"
    echo "ccc-agent: pip-installing ${pip_spec} into ${sp}"
    force_args=""
    if truthy "${update_pip}"; then
        # ccc-agent's package version may intentionally stay stable while the
        # requested branch advances.  `pip install --upgrade git+...@master` is
        # not enough to guarantee same-version files/scripts are replaced, so a
        # forced runtime update must bypass the cache and reinstall the package.
        force_args="--force-reinstall --no-cache-dir"
    fi
    if ! "${sp}" -m pip install --break-system-packages --upgrade ${force_args} "${pip_spec}" 2>/dev/null; then
        # older pip (no --break-system-packages) or non-PEP668 env
        "${sp}" -m pip install --upgrade ${force_args} "${pip_spec}" \
            || { echo "ccc-agent: ERROR: pip install of ${pip_spec} failed" >&2; return 1; }
    fi
    printf '%s\n' "${ref}" > "${pip_marker}"
}

run_install() {
    if ! command -v git >/dev/null 2>&1; then
        echo "ccc-agent: git is required to install ${repo}" >&2
        return 1
    fi
    ensure_bwrap
    ensure_pip_package
    ensure_branchfs_runtime
}

# =============================================================================
# wire phase — light, user-specific (needs USER_NAME); container startup only
# =============================================================================

install_user_shell_shim_hook() {
    hook_path="$1"
    user_name="${USER_NAME:-user}"
    user_home="${BASE%/}/${user_name}"
    [ -d "${user_home}" ] || return 0

    for rc in .bashrc .profile; do
        path="${user_home}/${rc}"
        tmp="${path}.ccc-agent.$$"
        if [ -f "${path}" ]; then
            awk '
                /^# BEGIN ccc-agent shims$/ { skip=1; next }
                /^# END ccc-agent shims$/ { skip=0; next }
                !skip { print }
            ' "${path}" > "${tmp}"
        else
            : > "${tmp}"
        fi
        cat >> "${tmp}" << EOF
# BEGIN ccc-agent shims
# Generated by ccc-agent setup. Keep transparent agent shims first in PATH.
if [ -r "${hook_path}" ]; then
    . "${hook_path}"
fi
# END ccc-agent shims
EOF
        mv "${tmp}" "${path}"
        if id "${user_name}" >/dev/null 2>&1; then
            chown "${user_name}:${user_name}" "${path}" 2>/dev/null || true
        fi
    done
}

install_user_ssh_shell_router() {
    router_path="$1"
    real_shell_path="$2"
    user_name="${USER_NAME:-user}"
    [ -x "${router_path}" ] || {
        echo "ccc-agent: warning: SSH shell router ${router_path} is not executable; not changing ${user_name}'s shell" >&2
        return 0
    }

    mkdir -p "$(dirname "${shells_file}")" 2>/dev/null || true
    touch "${shells_file}" 2>/dev/null || true
    if [ -w "${shells_file}" ] && ! grep -qxF "${router_path}" "${shells_file}" 2>/dev/null; then
        printf '%s\n' "${router_path}" >> "${shells_file}" || true
    fi

    usermod -s "${router_path}" "${user_name}" \
        || echo "ccc-agent: warning: failed to set ${user_name}'s shell to ${router_path}" >&2
}

restore_user_ssh_shell_router() {
    router_path="$1"
    real_shell_path="$2"
    user_name="${USER_NAME:-user}"
    current_shell="$(getent passwd "${user_name}" 2>/dev/null | cut -d: -f7 || true)"
    [ "${current_shell}" = "${router_path}" ] || return 0
    [ -x "${real_shell_path}" ] || real_shell_path=/bin/bash
    usermod -s "${real_shell_path}" "${user_name}" \
        || echo "ccc-agent: warning: failed to restore ${user_name}'s shell to ${real_shell_path}" >&2
}

run_wire() {
    bwrap_resolved="${CCC_AGENT_BWRAP_BIN:-$(command -v bwrap 2>/dev/null || echo bwrap)}"

    setup_bin="$(preferred_ccc_agent 2>/dev/null || true)"
    if [ -z "${setup_bin}" ]; then
        setup_bin="$(command -v ccc-agent 2>/dev/null || true)"
    fi
    [ -n "${setup_bin}" ] || { echo "ccc-agent: ERROR: ccc-agent not found (run the install phase first)" >&2; return 1; }

    # Version-skew guard: this image's wiring passes the /storage-layout flags
    # (--storage-root etc.), which an older installed ccc-agent does
    # not understand.  Detect that instead of crashing with an argparse dump or,
    # worse, silently wiring the wrong (legacy) layout.
    if ! "${setup_bin}" setup --help 2>&1 | grep -q -- '--storage-root'; then
        echo "ccc-agent: ERROR: installed ccc-agent predates the /storage-layout flags (--storage-root); cannot wire the storage layout." >&2
        echo "ccc-agent: update the runtime to a build that has them, e.g. set CCC_AGENT_UPDATE=1 (optionally with CCC_AGENT_REF / CCC_AGENT_REPO pointing at that build) and restart." >&2
        return 1
    fi

    # Path wiring (only known at runtime, never at build): CCC mounts the user's
    # storage at /storage and the home at /storage/user/<container>.  The agent
    # gets ONE BranchFS branch over all of /storage (read-through), with deltas
    # in a node-local store OUTSIDE /storage, mounted back at /storage in the
    # sandbox; $HOME maps to <storage>/user/<container> of that same branch.
    storage_root="${CCC_AGENT_STORAGE_ROOT:-/storage}"
    state_dir="${CCC_AGENT_STATE_DIR:-/storage/user/.ccc-agent}"
    branch_store="${CCC_AGENT_BRANCH_STORE:-/storage/user/.ccc-agent}"
    container_name="${CCC_AGENT_CONTAINER_NAME:-${CONTAINER_NAME:-}}"

    # CCC's miniconda bootstrap installs the default env under /home/$USER/conda
    # and activates it from shell startup files.  The runit wiring environment is
    # not itself a user login shell, so CONDA_PREFIX is often unset here even
    # though later agent shells will activate that env.  Auto-discover that prefix
    # so the image can install conda activation hooks without requiring another
    # env knob.  If no conda env is present, skip hook installation rather than
    # creating a bogus prefix directory.
    conda_prefix_resolved="${conda_prefix}"
    if [ -z "${conda_prefix_resolved}" ]; then
        for d in "/home/${USER_NAME:-user}/conda" "/home/${USER_NAME:-user}/miniconda3" "/opt/conda"; do
            [ -d "${d}" ] && { conda_prefix_resolved="${d}"; break; }
        done
    fi

    # Register the native CCC agent plugins (codex/claude/hermes lifecycle
    # hooks). ccc-agent run injects the matching plugin read-only into the
    # sandbox per contained run -- the user's ~/.codex/~/.claude config is never
    # edited. CCC_AGENT_REGISTER_PLUGINS is the current knob; REGISTER_HOOKS
    # stays as a back-compat alias.
    register_plugins="${CCC_AGENT_REGISTER_PLUGINS:-${CCC_AGENT_REGISTER_HOOKS:-${enable_shims}}}"
    set -- --system --config "${config_file}" --user-name "${USER_NAME:-user}" \
        --bwrap-bin "${bwrap_resolved}" \
        --storage-root "${storage_root}" --branch-store "${branch_store}"
    [ -n "${branchfs_bin}" ] && set -- "$@" --branchfs-bin "${branchfs_bin}"
    [ -n "${container_name}" ] && set -- "$@" --container-name "${container_name}"
    [ -n "${state_dir}" ] && set -- "$@" --state-dir "${state_dir}"
    # --no-hooks is the deprecated alias understood by every ccc-agent setup
    # build; it now disables agent_plugins. Keep it for version-skew safety.
    truthy "${register_plugins}" || set -- "$@" --no-hooks
    ssh_router_for_user=""
    if truthy "${enable_shims}"; then
        set -- "$@" --enable-shims --shim-agents "${shim_agents}" --link-dir "${link_dir}"
        if "${setup_bin}" setup --help 2>&1 | grep -q -- '--shell-path-hook'; then
            set -- "$@" --shell-path-hook "${shim_path_hook}"
        else
            echo "ccc-agent: warning: installed ccc-agent lacks --shell-path-hook; interactive shells may not prefer shims over user-local agents. Set CCC_AGENT_UPDATE=1 and restart." >&2
        fi
        if "${setup_bin}" setup --help 2>&1 | grep -q -- '--ssh-shell-router'; then
            set -- "$@" --ssh-shell-router "${ssh_shell_router}"
            ssh_router_for_user="${ssh_shell_router}"
        else
            echo "ccc-agent: warning: installed ccc-agent lacks --ssh-shell-router; SSH absolute Claude/Codex commands may bypass ccc-agent. Set CCC_AGENT_UPDATE=1 and restart." >&2
        fi
        install_user_shell_shim_hook "${shim_path_hook}"
    else
        rm -f "${shim_path_hook}" 2>/dev/null || true
        restore_user_ssh_shell_router "${ssh_shell_router}" "${real_shell}"
    fi
    if truthy "${conda_activate_shims}"; then
        if [ -n "${conda_prefix_resolved}" ] && { [ -n "${conda_prefix}" ] || [ -d "${conda_prefix_resolved}" ]; }; then
            if "${setup_bin}" setup --help 2>&1 | grep -q -- '--conda-activate-shims'; then
                set -- "$@" --conda-activate-shims --conda-prefix "${conda_prefix_resolved}"
            else
                echo "ccc-agent: warning: installed ccc-agent lacks --conda-activate-shims; conda-installed agents may bypass PATH shims. Set CCC_AGENT_UPDATE=1 and restart." >&2
            fi
        else
            echo "ccc-agent: conda shim hooks requested but no conda prefix found; set CCC_AGENT_CONDA_PREFIX to enable them" >&2
        fi
    fi
    "${setup_bin}" setup "$@"
    if truthy "${enable_shims}" && [ -n "${ssh_router_for_user}" ]; then
        install_user_ssh_shell_router "${ssh_router_for_user}" "${real_shell}"
    fi
    echo "ccc-agent: wired; CCC_AGENT_CONFIG=${config_file}"
}

# =============================================================================

# Best-effort: a phase failure warns but never aborts container startup (see the
# contract in the header). At build time (--install-only via the Dockerfile) a
# real failure should still surface, so only soften at runtime (when wiring).
if [ "${do_wire}" = 1 ]; then
    [ "${do_install}" = 1 ] && { run_install || echo "ccc-agent: install phase failed (best-effort; continuing)" >&2; }
    run_wire || echo "ccc-agent: wire phase failed (best-effort; continuing)" >&2
else
    [ "${do_install}" = 1 ] && run_install
fi
exit 0
