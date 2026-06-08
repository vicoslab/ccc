# AGENTS.md — CCC BranchFS Integration Docs

This checkout is being used to document a future CCC agent/training mode based on BranchFS.

## Objective

Add non-invasive documentation and examples for running CCC agent containers where writable user/group storage is exposed through BranchFS branch views, while real NFS underlays and commit authority remain hidden from untrusted agents.

## Requirements

- Prefer docs/examples under `docs/` or `scripts/`; avoid changing core deployment behavior unless necessary.
- Document that `/home/$USER` is a subpath of `/storage/user` in CCC and must share the same BranchFS root.
- Document the split between:
  - agent container: branch view only, no commit authority;
  - trusted review/commit container: real underlay RW + BranchFS store/control access.
- Document relaxed multi-writer training conventions: multiple nodes writing disjoint files in one branch, not the same file.
- Call out FUSE/Docker requirements (`/dev/fuse`, mount capability/privileged startup sidecar) as deployment considerations.
- Keep examples clearly marked as examples/prototypes if not wired into Ansible.

## Validation

If shell examples are added, run `bash -n` on them.
