Conda Compute Containers
========================

Contains build files for containers that use Conda in users directory (mounted as a persistent volume) for further package installation. The image itself is not writeable by the user.
Images also contain basic labels that are used to configure FRP port proxying.

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

Jupyter
-------

Extends base image, contains a Jupyter instance that is run at startup. The instance is protected using a token that is saved in file `~/jupyter.token`.


X11 support with XFCE4 and X2Go
-------------------------------

Extends base image with XFCE4 and X2Go server, which is run when client connects through the SSH. Image also installs `mate-terminal krusader ristretto gvfs gvfs-backends thunar-archive-plugin kio-extras ktexteditor-katepart` packages and default themes with `xubuntu-artwork xubuntu-icon-theme  breeze-icon-theme` packages. 

Additional Environmental variables:
 * APPS: installs symlinks to `/usr/local/bin` (paths separated by ':', each path can also provide symlink name seperated by comma, e.g.: `/opt/pycharm-pro/bin/pycharm:/opt/pycharm-free/bin/pycharm.sh,pycharm-free` will create `pycharm` and `pycharm-free` bins)
