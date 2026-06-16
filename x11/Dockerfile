ARG ROOT_IMAGE
ARG X11_SERVER="xpra"

#### BASE XFCE4 ####
FROM ${ROOT_IMAGE} as xfce4-base

ENV DEBIAN_FRONTEND noninteractive

RUN apt-get clean && \
    apt-get -o Acquire::Retries=3 update --fix-missing && \
    apt-get install -y --no-install-recommends xfce4 mate-terminal krusader && \
    apt-get install -y --no-install-recommends xubuntu-artwork xubuntu-icon-theme  breeze-icon-theme && \
    apt-get install -y --no-install-recommends ristretto gvfs gvfs-backends thunar-archive-plugin kio-extras ktexteditor-katepart && \
    apt-get auto-remove -y && \
    rm -rf /var/lib/apt/lists/*

#### XFCE4 with X2GO ####
FROM xfce4-base as xfce4-x2go

ENV DEBIAN_FRONTEND noninteractive

# The x2go/stable PPA does not publish packages for every Ubuntu release (e.g. it has
# no 26.04/resolute build). Use the PPA when it is available for this release, otherwise
# fall back to the x2goserver packages shipped in the Ubuntu archive (universe), which are
# present on 22.04, 24.04 and 26.04. This keeps the image building across all releases.
RUN apt-get clean && \
    apt-get -o Acquire::Retries=3 update --fix-missing && \
    apt-get install -y --no-install-recommends software-properties-common && \
    if add-apt-repository -y ppa:x2go/stable && apt-get -o Acquire::Retries=3 update; then \
        echo "x2go: using ppa:x2go/stable"; \
    else \
        echo "x2go: PPA not available for this release, falling back to Ubuntu archive"; \
        add-apt-repository -r -y ppa:x2go/stable || true; \
        rm -f /etc/apt/sources.list.d/*x2go* || true; \
        apt-get -o Acquire::Retries=3 update; \
    fi && \
    apt-get install -y --no-install-recommends x2goserver x2goserver-xsession pwgen dbus-x11 xdg-utils libdbus-glib-1-2 libdbusmenu-glib4 libdbusmenu-gtk3-4 python3-xdg python3-pyinotify xserver-xorg-input-libinput && \
    apt-get auto-remove -y && \
    rm -rf /var/lib/apt/lists/*

# disable XPRA service since it is not installed
RUN mkdir -p /etc/service/xpra-proxy-html5 && touch /etc/service/xpra-proxy-html5/down

#### XFCE4 with Xpra ####
FROM xfce4-base as xfce4-xpra

# Install the xpra.org repository key into a keyring file referenced via signed-by.
# `apt-key` is deprecated and has been removed entirely on newer releases (e.g. 26.04),
# so it can no longer be used. The xpra.org "lts" channel only ships some codenames
# (e.g. jammy, noble); for releases it does not cover (e.g. resolute/26.04) fall back to
# the regular xpra.org channel, which tracks all current Ubuntu codenames.
RUN apt-get clean && \
    apt-get -o Acquire::Retries=3 update --fix-missing && \
    apt-get install -y --no-install-recommends software-properties-common apt-transport-https ca-certificates curl wget && \
    install -d -m 0755 /usr/share/keyrings && \
    wget -q https://xpra.org/gpg.asc -O /usr/share/keyrings/xpra.asc && \
    XPRA_CODENAME="$(. /etc/os-release && echo $VERSION_CODENAME)" && \
    XPRA_REPO="https://xpra.org/lts" && \
    if ! curl -sfL -o /dev/null "$XPRA_REPO/dists/$XPRA_CODENAME/InRelease"; then XPRA_REPO="https://xpra.org"; fi && \
    echo "deb [signed-by=/usr/share/keyrings/xpra.asc] $XPRA_REPO $XPRA_CODENAME main" > /etc/apt/sources.list.d/xpra.list && \
    apt-get -o Acquire::Retries=3 update && \
    apt-get install -y --no-install-recommends xpra xpra-x11 dbus-x11 xdg-utils libdbus-glib-1-2 libdbusmenu-glib4 libdbusmenu-gtk3-4 python3-xdg python3-pyinotify xserver-xorg-input-libinput websockify uglifyjs && \
    apt-get auto-remove -y && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/xpra-html5
# Pick the bundled HTML5 client to match the installed xpra server:
#   * xpra 5.x (the LTS channel used on 22.04/24.04): use the well-tested v4.5.1 client.
#     It works through reverse proxies that enforce HTTP Basic Auth (e.g. FRP); the newer
#     v6+ client regressed that (it embeds the username in info-endpoint URLs which
#     suppresses the proxy's Basic Auth, gates the password behind an SSL *checkbox* it
#     cannot infer from a TLS-terminating proxy, and adds connect-page features that 401).
#   * xpra 6.x (the current channel on 26.04): v4.5.1 cannot connect (it only speaks the
#     legacy `bencode` packet encoding which 6.x dropped - "invalid packet encoding:
#     'bencode' decoder is not available"), so use v21 and patch its connect page to work
#     behind a TLS-terminating reverse proxy: treat an https-served page as a secure
#     connection (so the password is sent), and stop injecting the xpra username into the
#     info-endpoint/probe URLs (so the proxy's Basic Auth is not suppressed and they do not
#     401). Note: v21's installer takes the install ROOT as its first argument (it appends
#     /usr/share/xpra/www), whereas v4.5.1 takes the install dir directly.
RUN set -eux; \
    XPRA_MAJOR="$(xpra --version 2>/dev/null | grep -oE '[0-9]+' | head -1)"; \
    if [ "${XPRA_MAJOR:-5}" -ge 6 ]; then \
        git clone --depth 1 --branch v21 https://github.com/Xpra-org/xpra-html5 . ; \
        ./setup.py install / ; \
        sed -i 's/get_host_address() + uri/get_host_address(true) + uri/g; s/const url = get_host_address();/const url = get_host_address(true);/g; s/return webtransport_input.checked/return location.protocol==="https:" || webtransport_input.checked/' /usr/share/xpra/www/connect.html ; \
    else \
        git clone --depth 1 --branch v4.5.1 https://github.com/Xpra-org/xpra-html5 . ; \
        ./setup.py install /usr/share/xpra/www ; \
    fi; \
    rm -rf /tmp/xpra-html5/*

ENV XPRA_PROXY_HTML5_PORT 8888

EXPOSE $XPRA_PROXY_HTML5_PORT

#### FINAL DOCKER based on user-supplied X11_SERVER Switch  ####    
FROM xfce4-${X11_SERVER}
LABEL maintainer "Domen Tabernik <domen.tabernik@fri.uni-lj.si>"
    
COPY etc /etc/

WORKDIR /
