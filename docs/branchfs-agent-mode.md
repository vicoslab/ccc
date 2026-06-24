# BranchFS design notes (agent containment)

This document records the BranchFS storage model and design rationale behind
CCC's **agent containment** feature. The feature itself is implemented in the
[`ccc-agent-containment`](https://github.com/vicoslab/ccc-agent-containment)
runtime and wired into image startup (opt-in via `CCC_AGENT_CONTAINMENT_ENABLE`);
see [`docs/agent-containment.md`](agent-containment.md) for the operational setup
(enable flag, env vars, image bake, updating). This file is the "why" — the
storage layout, the trust split, and the BranchFS properties the design relies
on — plus notes on the distributed-training use of the same mechanism.

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

## CCC storage model

BranchFS protects the writable CCC data under `/storage`. CCC exposes
`/home/$USER` from the same user storage area that is also available under
`/storage/user` (specifically `/storage/user/$CONTAINER_NAME`). These paths
share **one** BranchFS root — `/home/$USER` and `/storage/user/...` must not be
branched independently, or there would be two incoherent writable aliases for
the same backing files.

The implemented layout (generated at container startup by `ccc-agent-setup`):

```text
real underlay (read-through):   /storage                     (base)
node-local delta store:         /opt/branchfs_branches        (off /storage)
branch mounted back inside box: /storage
home is a subpath of the same branch:
  /home/$USER  ==  /storage/user/$CONTAINER_NAME
```

So the whole of `/storage` is branched once; the branch is mounted back at
`/storage` in the sandbox, and the branch's `user/$CONTAINER_NAME` subdir is
bind-mounted to `/home/$USER`. `/storage/datasets` and `/storage/group` are
read-through; writes to them are captured as branch deltas and flagged for
review rather than touching the real NFS. The delta store and the runtime's
`state_dir` live **off** `/storage` (node-local) so BranchFS never branches its
own state.

## Agent and trusted split (the security boundary)

The agent runs inside a **rootless bubblewrap** user+mount+pid namespace — no
container `CAP_SYS_ADMIN`, no privileged helper. Inside the sandbox the agent
sees only:

- the BranchFS branch (read-write) at `/storage` and `/home/$USER`;
- read-through datasets;
- **not** the real NFS underlay, the BranchFS store, or any commit-capable
  control socket / `.branchfs_ctl`.

The trusted supervisor runs **outside** the sandbox and owns commit authority:
real underlays, the BranchFS store, and the freeze/inspect/commit/abort API. The
agent can create branch deltas but cannot commit them to real storage itself.
(In the accepted threat model this is best-effort against accidental/naive
misbehavior, not a defense against an agent that actively spoofs its own
approval — see `ccc-agent-containment` docs.)

## Lazy branch behavior

BranchFS uses lazy inheritance, which is what makes branching all of `/storage`
viable:

- Creating a branch writes metadata and empty delta/tombstone directories only.
- Reading an inherited path resolves through the parent branch or base underlay.
- Writing a new file creates only that file in the branch delta.
- First modification of an inherited file copies only that file into the delta.
- Directory listings merge the requested base directory, delta directory, and
  tombstones without scanning unrelated parts of the tree.
- Status and diff walk branch deltas and tombstones, not the full underlay.

Branch creation must be O(1) with respect to the number of inherited files.

## Distributed training semantics

Relaxed multi-writer mode supports training jobs where multiple nodes or ranks
write disjoint files into the same branch. Suitable output layouts:

```text
/storage/user/experiments/<run-id>/
  manifest.json
  logs/<hostname>-rank-<rank>.log
  metrics/<hostname>-rank-<rank>.jsonl
  checkpoints/step-000100/rank-00000.pt
  checkpoints/step-000100/rank-00001.pt
```

Supported:

- Multiple nodes create and write distinct files in one branch.
- Concurrent `mkdir -p` of the same directory is tolerated.
- Branch deltas live in a shared store, so other nodes on the same branch can
  read files once they become visible through normal filesystem behavior.

Explicitly unsupported in relaxed mode:

- Concurrent writes to the same path.
- Delete-vs-write races on the same path.
- Overlapping renames.
- Treating files such as `latest.pt`, `shared.log`, or one shared metrics file
  as safe multi-writer targets unless the framework provides its own
  synchronization.

Jobs should write rank-local artifacts and use manifests or post-processing to
identify the chosen checkpoint. Large checkpoints should be written directly to
their final per-rank path, or to a temporary path followed by a coordinated
single-writer rename.

## Freeze, review, and commit flow

1. The trusted launcher (`ccc-agent-run` / the shim) creates a BranchFS branch.
2. The agent runs with only branch views mounted.
3. At each turn's Stop boundary (and at session end) the supervisor classifies
   the branch deltas against the path policy.
4. In-scope changes (under the home/workspace) are committed; out-of-scope ones
   are reported for review via `ccc-agentctl` (accept / reject / file- or
   line-level), and the branch is otherwise left for later inspection.

Commit is **selective** — only reviewed, in-scope deltas are applied to the
base; the runtime does not blindly `commit-branch` the whole branch. The
low-level BranchFS store interface (used by the supervisor, never the agent):

```bash
branchfs status      "$BRANCH_ID" --storage /opt/branchfs_branches/storage --json
branchfs commit-branch "$BRANCH_ID" --storage /opt/branchfs_branches/storage
branchfs abort-branch  "$BRANCH_ID" --storage /opt/branchfs_branches/storage
```

## Deployment

FUSE and the sandbox both run **unprivileged**: BranchFS mounts via the
[`ccc-fuse-sidecar`](https://github.com/vicoslab/ccc-fuse-sidecar) (see
[`docs/fuse-support.md`](fuse-support.md)) and the agent is confined with
rootless bwrap — no `--privileged`, no `CAP_SYS_ADMIN`. The container must allow
**unprivileged user namespaces** for bwrap. Real underlays, the BranchFS store,
and control APIs are hidden from the agent before it starts (the sandbox exposes
only the branch view). See `docs/agent-containment.md` for the concrete env vars
and `/proc` note.

## Remaining limitations and future work

- Shared NFS branch stores need robust metadata persistence and cross-node cache
  visibility semantics; the default store is node-local.
- Commit across multiple independent NFS exports cannot be globally atomic.
- Strong same-path concurrency would require per-path locking or a stricter
  coordination layer.
- Operational policy is still evolving for branch naming, retention, quotas,
  review approval, and cleanup.
- Agent-visible BranchFS mounts use `branchfs mount --agent` so commit-capable
  controls are not exposed in the mounted tree.
