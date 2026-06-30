# Agent containment runtime

CCC agent filesystem containment lives in the separate
[`ccc-agent`](https://github.com/vicoslab/ccc-agent)
repository. It lets Codex / Claude Code / Hermes / OpenCode (and any command)
run against CCC storage **without direct write access to the real NFS data**:
the agent works in a node-local BranchFS branch view, and a trusted supervisor
commits to the real underlay only after a path policy passes (or parks the
changes for review).

The CCC image does not include or enable it by default. At runit startup the
base image only activates the external runtime when explicitly requested:

```bash
-e CCC_AGENT_ENABLE=1
```

The install/update logic is a single shared script, `/etc/setup_ccc_agent.sh`,
invoked from two places: the **image build** (to bake the runtime in — see
[Baking it into the image](#baking-it-into-the-image)) and **runit startup**
(`etc/runit_init.d/06_ccc_agent.sh`, behind the enable flag). The
startup call installs at first boot if nothing is baked in, and otherwise is a
fast no-op that only rebuilds/re-pips when a **newer ref** is requested via env
(see [Updating](#updating)).

## Optional variables

```bash
CCC_AGENT_REPO=https://github.com/vicoslab/ccc-agent.git
CCC_AGENT_REF=master
CCC_AGENT_INSTALL_DIR=/opt/ccc-agent
CCC_AGENT_ENABLE_SHIMS=0     # 1 = install codex/claude/... PATH shims
CCC_AGENT_LINK_DIR=/usr/local/bin  # trusted shim dir; prepended ahead of conda envs
CCC_AGENT_SHIM_AGENTS="codex claude hermes opencode"
CCC_AGENT_CONDA_ACTIVATE_SHIMS=    # default = ENABLE_SHIMS; installs conda activation hooks when a prefix exists
CCC_AGENT_CONDA_PREFIX=            # default: $CONDA_PREFIX, then /home/$USER/conda, /home/$USER/miniconda3, /opt/conda
CCC_AGENT_REGISTER_PLUGINS=  # default = ENABLE_SHIMS; 1 to register native plugins
CCC_AGENT_REGISTER_HOOKS=    # legacy alias for REGISTER_PLUGINS
# Dependency install (bwrap + branchfs) into system dirs:
CCC_AGENT_INSTALL_DEPS=1     # 0 to skip apt/cargo installs
CCC_AGENT_BRANCHFS_REPO=https://github.com/vicoslab/branchfs.git
CCC_AGENT_BRANCHFS_REF=master
CCC_AGENT_BRANCHFS_DEST=/usr/local/bin/branchfs
CCC_AGENT_BRANCHFS_BIN=     # prebuilt branchfs; set to skip the build
CCC_AGENT_BWRAP_BIN=        # prebuilt bwrap; set to skip apt install
CCC_AGENT_CONFIG=/etc/ccc-agent/config.json
# Storage/path wiring (resolved at startup; see "How the storage is wired"):
CCC_AGENT_STORAGE_ROOT=/storage          # real underlay, branched once
CCC_AGENT_BRANCH_STORE=/opt/branchfs_branches  # node-local deltas (must be OFF /storage)
CCC_AGENT_STATE_DIR=                      # default /opt/ccc-agent/state (node-local)
# CONTAINER_NAME (already set by CCC) maps $HOME to /storage/user/$CONTAINER_NAME.
# Updating a baked-in image at runtime (see "Updating"):
CCC_AGENT_UPDATE=0           # 1 = force refresh pip pkg + branchfs
CCC_AGENT_BRANCHFS_UPDATE=0  # 1 = force rebuild branchfs only
```

## How the storage is wired

CCC bind-mounts the user's storage at `/storage` and the user's home to the
**same bytes** as `/storage/user/$CONTAINER_NAME`. To avoid branching that data
twice, the runtime creates **one** BranchFS branch over all of `/storage`
(read-through), keeps the deltas in a node-local store **outside** `/storage`
(`/opt/branchfs_branches`), and inside the sandbox:

- mounts that single branch back at `/storage` (so the agent reads all of
  `/storage` but every write is captured as a branch delta, never the real NFS);
- bind-mounts the branch's `user/$CONTAINER_NAME` subdir to `/home/$USER`, so the
  home and `/storage/user/$CONTAINER_NAME` are the same branch — not two
  overlays of the same data.

Policy auto-commits changes under the home (the workspace) and flags writes
anywhere else under `/storage` (datasets, group, other users) for review. The
`config.json` is generated at **container startup** by `ccc-agent setup` (it
needs these runtime-only paths), never at image build. The branch store and
`state_dir` therefore live off `/storage` (node-local) so BranchFS never
branches its own state.

## Baking it into the image

Building rust + branchfs on first boot takes minutes. Build the **base** image
with the runtime baked in so an enabled container starts instantly (derived
images — VS Code, Jupyter, … — inherit it from the base):

```bash
docker build base/ \
  --build-arg CCC_AGENT_PREINSTALL=1 \
  --build-arg CCC_AGENT_REF=master \
  --build-arg CCC_AGENT_BRANCHFS_REF=master
```

This runs `/etc/setup_ccc_agent.sh --install-only` at build time (bwrap +
branchfs binary + the pip package; user-specific config/hooks are still wired at
startup). It is **on by default** (`PREINSTALL=1`); build with
`--build-arg CCC_AGENT_PREINSTALL=0` to skip it and keep the base
image lean (the runtime then installs on first boot instead). The build-arg ref
defaults match the runtime defaults, so a stock baked image is a no-op at boot.

## Updating

A baked-in image is pinned to the refs it was built with (recorded in markers
under `/opt/ccc-agent`). To pull a newer version at container start, request a
different ref — only the changed component is rebuilt/re-pipped:

```bash
-e CCC_AGENT_REF=v1.2.0            # newer pip package
-e CCC_AGENT_BRANCHFS_REF=v0.5.0   # newer branchfs
```

If the ref name is unchanged but the branch has advanced (new commits), force a
refresh with `-e CCC_AGENT_UPDATE=1` (or
`CCC_AGENT_BRANCHFS_UPDATE=1` for just branchfs).

## What startup installs and wires

When enabled, startup **installs the dependencies into system dirs** so they are
always on `PATH`: `bwrap` via `apt-get install bubblewrap` (→ `/usr/bin`), and
`branchfs` built from `vicoslab/branchfs@master` by default and installed to
`/usr/local/bin/branchfs` (also installs `libfuse3` so the binary runs without
`LD_LIBRARY_PATH`). Both installs are **idempotent** (skipped when already
present) and **best-effort** (a failure warns but never aborts startup); set a
`*_BIN` var to supply a prebuilt binary and skip building, or
`CCC_AGENT_INSTALL_DEPS=0` to skip installs entirely.

It then installs the runtime (pip package under `/usr`), links the unified
`ccc-agent` CLI into `/usr/local/bin`, and generates a
root-owned `/etc/ccc-agent/config.json`. The default config is **bwrap
confinement** (rootless; needs unprivileged user namespaces, no
`CAP_SYS_ADMIN`) with the agent's `~/.codex`/`~/.claude` state dirs writable in
the BranchFS view and ignored by policy. With shims/hooks enabled it also
registers the Claude Code Stop hook and the codex `notify` hook so interactive
agents commit per turn.

For transparent shims, conda needs one extra PATH step: activated conda envs put
`$CONDA_PREFIX/bin` before `/usr/local/bin`, so a `codex`/`claude` installed in
conda would otherwise bypass the system shim. Therefore, when
`CCC_AGENT_ENABLE_SHIMS=1`, startup also defaults
`CCC_AGENT_CONDA_ACTIVATE_SHIMS=1` and writes conda
`activate.d`/`deactivate.d` hooks when it can find a conda prefix (`$CONDA_PREFIX`,
`/home/$USER/conda`, `/home/$USER/miniconda3`, or `/opt/conda`). Those hooks
re-prepend the trusted shim dir ahead of `$CONDA_PREFIX/bin`, so shell lookup
hits the CCC shim first while the shim still resolves the real agent binary from
the active env. Set `CCC_AGENT_CONDA_PREFIX` for a non-standard env,
or `CCC_AGENT_CONDA_ACTIVATE_SHIMS=0` to disable this wiring.

## Requirements

The container must allow **unprivileged user namespaces** for bwrap confinement.
A non-baked first start also needs network access (apt + the branchfs git repo +
the rust toolchain); thereafter the system binaries are reused. For interactive
agents running as the real (non-root) uid, a fresh `--proc` needs the
container's masked `/proc` cleared (`--security-opt systempaths=unconfined`); the
default `bwrap_proc_mode: bind` works without that.

Commit/review policy lives entirely in the external runtime; CCC image startup
only performs opt-in installation/wiring. See the `ccc-agent` repo's
`docs/agent-integration.md` for hook registration and credential details.
