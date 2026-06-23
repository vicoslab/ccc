# BranchFS Agent Mode for CCC

This document describes a future, non-production integration mode for running CCC
agent and training containers on BranchFS-backed views of writable storage.
It is a design note and operator guide, not a change to the current Ansible
deployment or image startup behavior.

## Goals

- Give untrusted agents a writable working view without giving them direct write
  access to the real NFS underlays.
- Keep branch creation cheap for large CCC user and group areas by relying on
  lazy BranchFS inheritance rather than recursively copying or scanning trees.
- Allow trusted review before any branch changes are committed back to real
  storage.
- Support distributed training jobs where multiple nodes write different output
  files into one shared branch.
- Keep CCC's existing image model intact: the image root remains non-writable by
  the normal user, and only mutable data mounts are protected.

## Intended CCC Storage Model

BranchFS should protect writable CCC data mounts, especially:

- `/storage/user`
- `/home/$USER`, as a subpath of `/storage/user`
- `/storage/group`, when the container has writable group storage
- optional private or local scratch mounts when their artifacts must be reviewed

`/storage/datasets` should normally remain read-only passthrough storage. Local
scratch such as `/storage/local/ssd` or `/storage/local/hdd` can remain
disposable unless a workflow needs its outputs reviewed and committed.

CCC exposes `/home/$USER` from the same user storage area that is also available
under `/storage/user`. These paths must share one BranchFS root. Do not branch
`/home/$USER` and `/storage/user` independently, because that would create two
incoherent writable aliases for the same backing files.

Conceptually:

```text
real underlay:
  /__real/storage_user
  /__real/storage_user/<home-subdir>

branch view:
  /__branchfs_mounts/storage_user

agent-visible paths:
  /storage/user -> /__branchfs_mounts/storage_user
  /home/$USER   -> /__branchfs_mounts/storage_user/<home-subdir>
```

The `<home-subdir>` value must be the relative path inside `/storage/user` that
backs `/home/$USER` for the current CCC deployment.

Prototype agent-side mount command:

```bash
branchfs mount \
  --base /__real/storage_user \
  --storage /__branchfs_store/storage_user \
  --branch "$BRANCH_ID" \
  --agent \
  /__branchfs_mounts/storage_user
```

Then bind `/__branchfs_mounts/storage_user` to `/storage/user`, and bind
`/__branchfs_mounts/storage_user/<home-subdir>` to `/home/$USER`.

## Agent and Trusted Container Split

The agent container must see only branch views:

- BranchFS-mounted writable views for protected storage.
- Read-only passthrough mounts for immutable datasets.
- No real NFS underlay paths such as `/__real/storage_user`.
- No BranchFS store paths or commit-capable control socket.
- No `.branchfs_ctl` or equivalent interface that can freeze, abort, or commit.

A separate trusted review/commit container or sidecar owns commit authority:

- Real NFS underlays mounted read/write.
- BranchFS store and control API access.
- Permission to freeze, inspect, diff, commit, or abort branches.

This split is the security boundary. Agent containers may create branch deltas,
but they must not be able to commit those deltas to real storage themselves.

## Lazy Branch Behavior

The intended BranchFS behavior for CCC is lazy inheritance:

- Creating a branch writes metadata and empty delta/tombstone directories only.
- Reading an inherited path resolves through the parent branch or base underlay.
- Writing a new file creates only that file in the branch delta.
- First modification of an inherited file copies only that file into the delta.
- Directory listings merge the requested base directory, delta directory, and
  tombstones without scanning unrelated parts of the tree.
- Status and diff walk branch deltas and tombstones, not the full underlay.

This matters because CCC user and group areas can contain very large trees.
Branch creation must be O(1) with respect to the number of inherited files.

## Distributed Training Semantics

Relaxed multi-writer mode is intended for training jobs where multiple nodes or
ranks write disjoint files into the same branch. Suitable output layouts include:

```text
/storage/user/experiments/<run-id>/
  manifest.json
  logs/<hostname>-rank-<rank>.log
  metrics/<hostname>-rank-<rank>.jsonl
  checkpoints/step-000100/rank-00000.pt
  checkpoints/step-000100/rank-00001.pt
```

Supported convention:

- Multiple nodes can create and write distinct files in one branch.
- Concurrent `mkdir -p` of the same directory should be tolerated.
- Branch deltas live in a shared store, so other nodes using the same branch can
  read files after they become visible through normal filesystem behavior.

Explicitly unsupported in relaxed mode:

- Concurrent writes to the same path.
- Delete-vs-write races on the same path.
- Overlapping renames.
- Treating files such as `latest.pt`, `shared.log`, or one shared metrics file
  as safe multi-writer targets unless the training framework provides its own
  synchronization.

Jobs should write rank-local artifacts and use manifests or post-processing to
identify the chosen checkpoint. Same-path multi-writer races are outside the
guarantees of this mode.

## Freeze, Review, and Commit Flow

The expected lifecycle is:

1. A trusted launcher creates or selects a BranchFS branch.
2. Agent and training containers run with only branch views mounted.
3. The trusted sidecar freezes the branch when the run is complete or ready for
   review.
4. Review tools inspect branch status, diffs, manifests, logs, and artifacts.
5. A trusted operator or policy commits approved changes, or aborts/discards the
   branch.

Prototype trusted-side commands:

```bash
branchfs freeze "$BRANCH_ID" --storage /__branchfs_store/storage_user
branchfs status "$BRANCH_ID" --storage /__branchfs_store/storage_user
branchfs commit-branch "$BRANCH_ID" --storage /__branchfs_store/storage_user
# or discard:
branchfs abort-branch "$BRANCH_ID" --storage /__branchfs_store/storage_user
```

These commands use the current BranchFS prototype CLI. The required property is
the boundary: freeze/review/commit operations run only from the trusted
environment, never from the agent container.

## Deployment Considerations

BranchFS uses FUSE, so a CCC deployment will need a privileged startup path or
sidecar that can perform mounts. Depending on Docker and host policy, this may
require:

- `/dev/fuse` passed into the mounting context.
- `CAP_SYS_ADMIN` or equivalent mount capability.
- A privileged sidecar or early container startup phase to mount BranchFS views.
- Bind mounts from BranchFS views onto the normal CCC paths.
- Careful hiding of real underlays, BranchFS stores, and control APIs before the
  untrusted agent process starts.

These are deployment concerns for future CCC integration. This repository change
does not wire BranchFS into Ansible, runit startup scripts, or production image
behavior.

## Performance Constraints

The integration is only viable if the implementation preserves these properties:

- Branch creation is O(1).
- New artifact writes do not scan the base tree.
- First copy-on-write of an inherited file copies only that file.
- Directory listing scans only the listed directory in the base/parent and delta.
- Status and diff operate from delta and tombstone metadata.
- Multi-node jobs avoid hot shared output files.

Large model checkpoints should be written directly to their final per-rank path
or to a temporary path followed by a coordinated single-writer rename.

## Limitations and Future Work

- This document describes a future mode and example scaffolding only.
- Agent-visible BranchFS mounts must use `branchfs mount --agent` or
  `--no-control` so commit-capable controls are not exposed in the mounted tree.
- Shared NFS branch stores need robust metadata persistence and cache visibility
  semantics across nodes.
- Commit across multiple independent NFS exports cannot be globally atomic.
- Strong same-path concurrency would require per-path locking or a stricter
  coordination layer.
- Operational policy is still needed for branch naming, retention, quotas,
  review approval, and cleanup.
