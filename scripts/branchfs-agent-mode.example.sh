#!/usr/bin/env bash
set -Eeuo pipefail

# Non-production BranchFS/CCC agent-mode mount sketch.
#
# Default behavior is dry-run. The commands are printed but not executed unless:
#
#   CCC_BRANCHFS_EXAMPLE_APPLY=1 scripts/branchfs-agent-mode.example.sh
#
# This example intentionally models only the untrusted agent container view.
# Commit, freeze, abort, and direct access to real underlays or BranchFS control
# APIs belong in a separate trusted review/commit container.

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*" >&2
}

is_relative_clean_path() {
  case "$1" in
    "" | /* | "." | ".." | */../* | ../* | */..)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

print_command() {
  local arg
  printf '+'
  for arg in "$@"; do
    printf ' %q' "$arg"
  done
  printf '\n'
}

run_or_print() {
  print_command "$@"
  if [[ "${CCC_BRANCHFS_EXAMPLE_APPLY:-0}" == "1" ]]; then
    "$@"
  fi
}

require_apply_guardrails() {
  if [[ "${CCC_BRANCHFS_EXAMPLE_APPLY:-0}" != "1" ]]; then
    info "dry-run mode: set CCC_BRANCHFS_EXAMPLE_APPLY=1 to execute this prototype"
    return
  fi

  [[ "${EUID}" -eq 0 ]] || die "mount operations require root in the mounting context"
  command -v mount >/dev/null 2>&1 || die "mount command not found"
  command -v "${BRANCHFS_BIN}" >/dev/null 2>&1 || die "BranchFS binary not found: ${BRANCHFS_BIN}"
  [[ -e /dev/fuse ]] || die "/dev/fuse is not available"
}

main() {
  : "${BRANCH_ID:?set BRANCH_ID to the BranchFS branch name for this agent run}"
  : "${CCC_USER_NAME:?set CCC_USER_NAME to the CCC user name}"
  : "${CCC_HOME_SUBDIR:?set CCC_HOME_SUBDIR to the relative home path inside /storage/user}"

  BRANCHFS_BIN="${BRANCHFS_BIN:-branchfs}"
  REAL_STORAGE_USER="${REAL_STORAGE_USER:-/__real/storage_user}"
  BRANCHFS_STORE_ROOT="${BRANCHFS_STORE_ROOT:-/__branchfs_store}"
  BRANCHFS_MOUNT_ROOT="${BRANCHFS_MOUNT_ROOT:-/__branchfs_mounts}"
  TARGET_STORAGE_USER="${TARGET_STORAGE_USER:-/storage/user}"
  TARGET_HOME="${TARGET_HOME:-/home/${CCC_USER_NAME}}"

  is_relative_clean_path "${CCC_HOME_SUBDIR}" ||
    die "CCC_HOME_SUBDIR must be a clean relative path inside /storage/user"

  [[ "${TARGET_HOME}" == "/home/${CCC_USER_NAME}" ]] ||
    die "TARGET_HOME must match /home/\$CCC_USER_NAME in this example"

  if [[ "${TARGET_STORAGE_USER}" == "${TARGET_HOME}" ]]; then
    die "TARGET_STORAGE_USER and TARGET_HOME must not be the same mountpoint"
  fi

  local storage_user_store="${BRANCHFS_STORE_ROOT}/storage_user"
  local storage_user_view="${BRANCHFS_MOUNT_ROOT}/storage_user"
  local home_view="${storage_user_view}/${CCC_HOME_SUBDIR}"

  require_apply_guardrails

  info "agent branch: ${BRANCH_ID}"
  info "home is bound from the same /storage/user BranchFS root: ${home_view}"

  run_or_print mkdir -p "${storage_user_store}" "${storage_user_view}" "${TARGET_STORAGE_USER}" "${TARGET_HOME}"

  run_or_print \
    "${BRANCHFS_BIN}" mount \
    --base "${REAL_STORAGE_USER}" \
    --storage "${storage_user_store}" \
    --branch "${BRANCH_ID}" \
    --agent \
    "${storage_user_view}"

  run_or_print mount --bind "${storage_user_view}" "${TARGET_STORAGE_USER}"
  run_or_print mount --bind "${home_view}" "${TARGET_HOME}"

  if [[ "${PROTECT_STORAGE_GROUP:-0}" == "1" ]]; then
    : "${REAL_STORAGE_GROUP:?set REAL_STORAGE_GROUP when PROTECT_STORAGE_GROUP=1}"
    local storage_group_store="${BRANCHFS_STORE_ROOT}/storage_group"
    local storage_group_view="${BRANCHFS_MOUNT_ROOT}/storage_group"
    local target_storage_group="${TARGET_STORAGE_GROUP:-/storage/group}"

    run_or_print mkdir -p "${storage_group_store}" "${storage_group_view}" "${target_storage_group}"
    run_or_print \
      "${BRANCHFS_BIN}" mount \
      --base "${REAL_STORAGE_GROUP}" \
      --storage "${storage_group_store}" \
      --branch "${BRANCH_ID}" \
      --agent \
      "${storage_group_view}"
    run_or_print mount --bind "${storage_group_view}" "${target_storage_group}"
  fi

  info "trusted freeze/review/commit must happen outside this agent container"
}

main "$@"
