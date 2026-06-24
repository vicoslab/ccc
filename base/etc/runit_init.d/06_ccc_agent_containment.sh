#!/bin/sh
set -eu

truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

# Non-default by design: CCC images only ACTIVATE the ccc-agent-containment
# runtime when explicitly requested at container startup.
if ! truthy "${CCC_AGENT_CONTAINMENT_ENABLE:-0}"; then
    exit 0
fi

# All real work lives in the shared installer so the exact same code runs at
# image build time (base/Dockerfile, `--install-only`) and here at startup.
#
# If the image was built with CCC_AGENT_CONTAINMENT_PREINSTALL=1, the heavy bits
# (bwrap + branchfs + the pip package) are already baked in and the install
# phase is a fast no-op; it only rebuilds/re-pips when a NEWER ref is requested
# via env (CCC_AGENT_CONTAINMENT_REF / _BRANCHFS_REF, or *_UPDATE=1). The wire
# phase (config + hooks, which need USER_NAME) always runs here.
setup="/etc/setup_ccc_agents.sh"
if [ ! -f "${setup}" ]; then
    echo "ccc-agent-containment: ERROR: ${setup} missing from image" >&2
    exit 1
fi

exec sh "${setup}"
