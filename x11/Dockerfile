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
# xpra-html5 v4.5.1 only speaks the legacy `bencode` packet encoding, which xpra 6.x
# servers (e.g. the 6.x packages on 26.04) no longer support, so the HTML5 browser
# client could not connect ("invalid packet encoding: 'bencode' decoder is not
# available"). v21 uses rencodeplus and connects to the xpra 5.x and 6.x servers used
# across 22.04/24.04/26.04. Note: the installer's first positional argument is the
# install ROOT (it appends /usr/share/xpra/www), so pass "/".
RUN git clone --depth 1 --branch v21 https://github.com/Xpra-org/xpra-html5 . && ./setup.py install / && \
    # Reverse-proxy fix: the connect page's server probe and its info-endpoint XHRs
    # (/Info, /Sessions, /Displays, /DesktopMenu, favicon.png?echo-headers) embed the xpra
    # username in the request URL ("https://user@host/..."). That userinfo overrides /
    # suppresses the browser's cached HTTP Basic Auth from a front proxy (e.g. FRP), so the
    # requests 401 and the client cannot detect the server or populate sessions. xpra's own
    # HTTP endpoints do not use HTTP Basic Auth (auth is in the xpra protocol), so drop the
    # userinfo via the existing get_host_address(true) and let the proxy credentials flow.
    sed -i 's/get_host_address() + uri/get_host_address(true) + uri/g; s/const url = get_host_address();/const url = get_host_address(true);/g' /usr/share/xpra/www/connect.html && \
    rm -rf /tmp/xpra-html5/*

ENV XPRA_PROXY_HTML5_PORT 8888

EXPOSE $XPRA_PROXY_HTML5_PORT

#### FINAL DOCKER based on user-supplied X11_SERVER Switch  ####    
FROM xfce4-${X11_SERVER}
LABEL maintainer "Domen Tabernik <domen.tabernik@fri.uni-lj.si>"
    
COPY etc /etc/

WORKDIR /
