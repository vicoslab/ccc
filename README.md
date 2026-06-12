Conda Compute Containers
========================

Contains build files for containers that use Conda in users directory (mounted as a persistent volume) for further package installation. The image itself is not writeable by the user.
Images also contain basic labels that are used to configure FRP port proxying.

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
