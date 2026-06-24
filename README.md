Conda Compute Containers
========================

Contains build files for containers that use Conda in users directory (mounted as a persistent volume) for further package installation. The image itself is not writeable by the user.
Images also contain basic labels that are used to configure FRP port proxying.

BranchFS agent/training mode
----------------------------

Future BranchFS-backed agent and training container ideas are documented in
`docs/branchfs-agent-mode.md`. The notes and example wrapper are non-production
scaffolding only; they do not change Ansible deployment or image startup
behavior.

The proposed mode protects writable CCC data mounts by exposing BranchFS branch
views to agent/training containers while keeping the real NFS underlays and
commit-capable BranchFS controls in a trusted launcher/review sidecar. Important
constraints are:

 * `/home/$USER` must be exposed as a subpath of the same `/storage/user` branch,
   not as an independent branch root.
 * agent-visible BranchFS mounts should use `branchfs mount --agent` or
   `--no-control` so `.branchfs_ctl` and `@branch` are hidden.
 * multi-node training should write disjoint per-node/per-rank files; same-path
   write/delete/rename races are outside the relaxed-mode guarantee.

See `scripts/branchfs-agent-mode.example.sh` for a dry-run wrapper sketch. It
prints the BranchFS and bind-mount commands by default and only executes them
when explicitly run with `CCC_BRANCHFS_EXAMPLE_APPLY=1`.

Manual development image builds
-------------------------------

The repository contains a manual-only GitHub Actions workflow named `Docker Dev Image CI` for testing a single CCC image without publishing release/latest tags. Run it from the GitHub Actions UI and choose exactly one `image` to build. The default is `base`.

Example base image run:

 * `image`: `base`
 * `root_image`: `nvidia/cuda:13.0.2-devel-ubuntu22.04`
 * `tag`: `ubuntu22.04-cuda13.0.2`

The workflow pushes one development tag to Docker Hub using the configured `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` secrets:

 * `vicoslab/ccc:base-dev-<tag>`
 * `vicoslab/ccc:jupyter-dev-<tag>` for Ubuntu 22.04 tags, when `image` is `jupyter`
 * `vicoslab/ccc:x2go-dev-<tag>` when `image` is `x2go`
 * `vicoslab/ccc:xpra-dev-<tag>` for Ubuntu 22.04/24.04 tags, when `image` is `xpra`
 * `vicoslab/ccc:vscode-dev-<tag>` when `image` is `vscode`

For non-base images, `root_image` should be the parent CCC base image to extend, such as `vicoslab/ccc:base-dev-ubuntu22.04-cuda13.0.2`. The workflow is intentionally configured only with `workflow_dispatch`, so it does not run on pushes, pull requests, or tags.

Base image
----------

The image uses runit for bootstrap, it runs rsyslogd, crond and sshd. It also runs several startup scripts that:

 * configures user with ssh pubkey if not present, 
 * configures SSH access with pubkey only and creates host keys at `/home/.sshd/keys` if not present
 * installs miniconda to `~/conda`,
 * installs optional APT packages (and sources), 
 * optionally reverts ENVs to last working version if startup failed 3-times, and
 * provides wellcome message (MOTD) (info on installed packages, etc)
 
Required environmental variables:
 * USER_NAME: the name of the user that will use the container, defaults to user.
 * USER_ID: the UID of the user, defaults to 1000.
 * USER_PUBKEY: the public part of the key for SSH access.
 
Optional environmental variables:
 * INSTALL_PACKAGES: apt-get packages that will be installed at startup-time.
 * INSTALL_REPOSITORY_KEYS: comma separated list of URLs to GPG keys that will be installed at startup-time using `wget -qO - "<KEY>" | apt-key add -`.
 * INSTALL_REPOSITORY_SOURCES: comma separated list of sources that will be installed at startup-time using `add-apt-repository -y "<SOURCE>"`.
 * RUNIT_STATUS_FILE: path to file where container will report its boot status (e.g., running, booting [NUM], failed boot)
 * RUNIT_WORKING_ENV_FILE: path to file where last working ENVs are stored (for recovery if invalid ENV values supplied)

Optional environmental variables used to provide info at login
 * CONTAINER_NAME: name of the container
 * CONTAINER_NODE: host/node name where container is running
 * CONTAINER_IMAGE: docker image that is running
 * CONTAINER_WELCOME_MSG: custom login text at the end

FUSE support
---------------------------

All CCC images support FUSE through [`ccc-fuse-sidecar`](https://github.com/vicoslab/ccc-fuse-sidecar) so compute containers do not need
privileged access or `SYS_ADMIN`. The image includes a static `fusermount3` shim
under `/opt/ccc-fuse-sidecar/bin` and relinks `fusermount3`/`fusermount` helper
names during startup. Startup also places an `umount` wrapper in `/usr/local/bin`
so normal user shells can run `umount /path/to/fuse-mount`; the wrapper execs
`fusermount3 -u "$@"`, and the FUSE shim sends the request to the sidecar instead
of requiring app-side `SYS_ADMIN`. The real system `/bin/umount` is left in place
for root/system scripts that call it explicitly.
The shim reads `CONTAINER_NAME` from the container environment and forwards it to
the sidecar, allowing Docker-inspect path translation to identify the calling
compute container.

For this to work, the CCC deployment must provide the runtime pieces, not the
image itself:

```bash
--device /dev/fuse:/dev/fuse:rw
-v /run/ccc-fuse-sidecar/<container>:/run/ccc-fuse-sidecar:rw
--label ccc.fuse=enabled
-e CONTAINER_NAME=<container-name>
```

You do not need `--privileged` or app-side `--cap-add SYS_ADMIN`.

Agent containment runtime
-------------------------

CCC agent filesystem containment now lives in the separate
`ccc-agent-containment` repository. The CCC image does not include or enable it
by default. At runit startup, the base image only activates the external runtime
when explicitly requested:

```bash
-e CCC_AGENT_CONTAINMENT_ENABLE=1
```

The install/update logic is a single shared script, `/etc/setup_ccc_agents.sh`,
invoked from two places: the **image build** (to bake the runtime in, see
*Baking it into the image* below) and **runit startup**
(`etc/runit_init.d/06_ccc_agent_containment.sh`, behind the enable flag). The
startup call installs at first boot if nothing is baked in, and otherwise is a
fast no-op that only rebuilds/re-pips when a **newer ref** is requested via env
(see *Updating* below).

Useful optional variables:

```bash
CCC_AGENT_CONTAINMENT_REPO=https://github.com/vicoslab/ccc-agent-containment.git
CCC_AGENT_CONTAINMENT_REF=master
CCC_AGENT_CONTAINMENT_INSTALL_DIR=/opt/ccc-agent
CCC_AGENT_CONTAINMENT_ENABLE_SHIMS=0     # 1 = install codex/claude/... PATH shims
CCC_AGENT_CONTAINMENT_REGISTER_HOOKS=    # default = ENABLE_SHIMS; 1 to register hooks
# Dependency install (bwrap + branchfs) into system dirs:
CCC_AGENT_CONTAINMENT_INSTALL_DEPS=1     # 0 to skip apt/cargo installs
CCC_AGENT_CONTAINMENT_BRANCHFS_REPO=https://github.com/vicoslab/branchfs.git
CCC_AGENT_CONTAINMENT_BRANCHFS_REF=master
CCC_AGENT_CONTAINMENT_BRANCHFS_DEST=/usr/local/bin/branchfs
CCC_AGENT_CONTAINMENT_BRANCHFS_BIN=     # prebuilt branchfs; set to skip the build
CCC_AGENT_CONTAINMENT_BWRAP_BIN=        # prebuilt bwrap; set to skip apt install
CCC_AGENT_CONFIG=/etc/ccc-agent/config.json
# Storage/path wiring (resolved at startup; see "How the storage is wired"):
CCC_AGENT_STORAGE_ROOT=/storage          # real underlay, branched once
CCC_AGENT_BRANCH_STORE=/opt/branchfs_branches  # node-local deltas (must be OFF /storage)
CCC_AGENT_STATE_DIR=                      # default /opt/ccc-agent/state (node-local)
# CONTAINER_NAME (already set by CCC) maps $HOME to /storage/user/$CONTAINER_NAME.
# Updating a baked-in image at runtime (see "Updating"):
CCC_AGENT_CONTAINMENT_UPDATE=0           # 1 = force refresh pip pkg + branchfs
CCC_AGENT_CONTAINMENT_BRANCHFS_UPDATE=0  # 1 = force rebuild branchfs only
```

### How the storage is wired

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
`config.json` is generated at **container startup** by `ccc-agent-setup` (it
needs these runtime-only paths), never at image build.

### Baking it into the image (recommended)

Building rust + branchfs on first boot takes minutes. Build the **base** image
with the runtime baked in so an enabled container starts instantly (derived
images — VS Code, Jupyter, … — inherit it from the base):

```bash
docker build base/ \
  --build-arg CCC_AGENT_CONTAINMENT_PREINSTALL=1 \
  --build-arg CCC_AGENT_CONTAINMENT_REF=master \
  --build-arg CCC_AGENT_CONTAINMENT_BRANCHFS_REF=master
```

This runs `/etc/setup_ccc_agents.sh --install-only` at build time (bwrap +
branchfs binary + the pip package; user-specific config/hooks are still wired at
startup). It is **on by default** (`PREINSTALL=1`); build with
`--build-arg CCC_AGENT_CONTAINMENT_PREINSTALL=0` to skip it and keep the base
image lean (the runtime then installs on first boot instead). The build-arg ref
defaults match the runtime defaults, so a stock baked image is a no-op at boot.

### Updating

A baked-in image is pinned to the refs it was built with (recorded in markers
under `/opt/ccc-agent`). To pull a newer version at container start, request a
different ref — only the changed component is rebuilt/re-pipped:

```bash
-e CCC_AGENT_CONTAINMENT_REF=v1.2.0            # newer pip package
-e CCC_AGENT_CONTAINMENT_BRANCHFS_REF=v0.5.0   # newer branchfs
```

If the ref name is unchanged but the branch has advanced (new commits), force a
refresh with `-e CCC_AGENT_CONTAINMENT_UPDATE=1` (or
`CCC_AGENT_CONTAINMENT_BRANCHFS_UPDATE=1` for just branchfs).

When enabled, startup **installs the dependencies into system dirs** so they
are always on `PATH`: `bwrap` via `apt-get install bubblewrap` (→ `/usr/bin`),
and `branchfs` built from the vicoslab fork branch
(`vicoslab/branchfs@feat/ccc-agent-containment` by default) and installed to
`/usr/local/bin/branchfs` (also installs `libfuse3` so the binary runs without
`LD_LIBRARY_PATH`). Both installs are **idempotent** (skipped when already
present) and **best-effort** (a failure warns but never aborts startup); set a
`*_BIN` var to supply a prebuilt binary and skip building, or
`CCC_AGENT_CONTAINMENT_INSTALL_DEPS=0` to skip installs entirely.

It then clones the external runtime under `/opt/ccc-agent`, links
`ccc-agent-run`, `ccc-agent-launch`, and `ccc-agentctl` into `/usr/local/bin`,
and generates a root-owned default `/etc/ccc-agent/config.json` if missing. The
default config is **bwrap confinement** (rootless; needs unprivileged user
namespaces, no `CAP_SYS_ADMIN`) with the agent's `~/.codex`/`~/.claude` exposed
read-only for auth and the agents' config/cache dirs ignored. With shims/hooks
enabled it also registers the Claude Code Stop hook (managed settings) and the
codex `notify` hook so interactive agents commit per turn.

Requirements for bwrap confinement: the container must allow **unprivileged
user namespaces**. The build also needs network access (apt + the branchfs git
repo + the rust toolchain) on first start; thereafter the system binaries are
reused. For interactive agents running as the real (non-root) uid, fresh
`--proc` needs the container's masked `/proc` cleared
(`--security-opt systempaths=unconfined`); the default `bwrap_proc_mode: bind`
works without that. Commit/review policy lives entirely in the external runtime;
CCC image startup only performs opt-in installation/wiring. See the
`ccc-agent-containment` repo's `docs/agent-integration.md` for hook registration
and credential details.

VS Code
-------

Extends base image and installs a VS Code IDE. It starts `code serve-web` service on default port 9999 (or one specifided in VSCODE_PORT env var). The instance is protected using a token that is saved in file `~/vscode.token`.


Jupyter
-------

Extends base image, contains a Jupyter instance that is run at startup. The instance is protected using a token that is saved in file `~/jupyter.token`.



X11 support with XFCE4 and X2Go
-------------------------------

Extends base image with XFCE4 and X2Go server, which is run when client connects through the SSH. Image also installs `mate-terminal krusader ristretto gvfs gvfs-backends thunar-archive-plugin kio-extras ktexteditor-katepart` packages and default themes with `xubuntu-artwork xubuntu-icon-theme  breeze-icon-theme` packages. 

Additional Environmental variables:
 * APPS: installs symlinks to `/usr/local/bin` (paths separated by ':', each path can also provide symlink name seperated by comma, e.g.: `/opt/pycharm-pro/bin/pycharm:/opt/pycharm-free/bin/pycharm.sh,pycharm-free` will create `pycharm` and `pycharm-free` bins)
