#!/bin/sh
set -eu

truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        0|false|FALSE|no|NO|off|OFF) return 1 ;;
        *) return 1 ;;
    esac
}

if ! truthy "${CCC_FUSE_RELINK_HELPERS:-1}"; then
    exit 0
fi

client_bin_dir="${CCC_FUSE_CLIENT_BIN_DIR:-/opt/ccc-fuse-sidecar/bin}"
helper_dirs="${CCC_FUSE_HELPER_DIRS:-/usr/local/bin:/usr/bin:/bin}"
shim="${client_bin_dir}/fusermount3"

if [ ! -x "${shim}" ]; then
    echo "warning: CCC FUSE fusermount3 shim is missing or not executable: ${shim}" >&2
    exit 0
fi

old_ifs=${IFS}
IFS=:
for dir in ${helper_dirs}; do
    [ -n "${dir}" ] || continue
    mkdir -p "${dir}"
    ln -sfn "${shim}" "${dir}/fusermount3"
    ln -sfn "${shim}" "${dir}/fusermount"
    ln -sfn "${shim}" "${dir}/fusemount3"
    ln -sfn "${shim}" "${dir}/fusemount"
done
IFS=${old_ifs}

mkdir -p "${CCC_FUSE_SOCKET_DIR:-/run/ccc-fuse-sidecar}"
