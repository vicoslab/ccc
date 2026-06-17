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

# Prefer the x2go/stable PPA, but fall back to the x2goserver packages in the Ubuntu archive
# (universe) when the PPA has no build for this release. The PPA does not publish for every
# Ubuntu release, so this keeps the x2go image building on both 22.04 and 24.04.
RUN apt-get clean && \
    apt-get -o Acquire::Retries=3 update --fix-missing && \
    apt-get install -y --no-install-recommends software-properties-common && \
    if add-apt-repository -y ppa:x2go/stable && apt-get -o Acquire::Retries=3 update; then \
        echo "x2go: using ppa:x2go/stable"; \
    else \
        echo "x2go: ppa:x2go/stable unavailable for this release, using the Ubuntu archive"; \
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

# Add the xpra.org repo via a signed-by keyring instead of `apt-key add` + `lsb_release`:
# `apt-key` was removed on Ubuntu 24.04 (noble) and `lsb_release` is not always installed,
# so the old approach breaks the 24.04 build. The keyring + /etc/os-release codename works on
# both 22.04 (jammy) and 24.04 (noble) - both of which the xpra.org "lts" channel ships
# (xpra 5.1.x), keeping the server version identical across the two releases.
RUN apt-get clean && \
    apt-get -o Acquire::Retries=3 update --fix-missing && \
    apt-get install -y --no-install-recommends software-properties-common apt-transport-https ca-certificates wget && \
    install -d -m 0755 /usr/share/keyrings && \
    wget -q https://xpra.org/gpg.asc -O /usr/share/keyrings/xpra.asc && \
    echo "deb [signed-by=/usr/share/keyrings/xpra.asc] https://xpra.org/lts $(. /etc/os-release && echo "$VERSION_CODENAME") main" > /etc/apt/sources.list.d/xpra.list && \
    apt-get -o Acquire::Retries=3 update && \
    apt-get install -y --no-install-recommends xpra xpra-x11 xpra-html5 dbus-x11 xdg-utils libdbus-glib-1-2 libdbusmenu-glib4 libdbusmenu-gtk3-4 python3-xdg python3-pyinotify xserver-xorg-input-libinput websockify uglifyjs && \
    apt-get auto-remove -y && \
    rm -rf /var/lib/apt/lists/*

ARG XPRA_HTML5_VER="v13"
RUN set -eux; \
    xpra_html_tmp="$(mktemp -d)"; \
    git clone --depth 1 --branch ${XPRA_HTML5_VER} https://github.com/Xpra-org/xpra-html5 "${xpra_html_tmp}"; \
    rm -rf /usr/share/xpra/www/*; \
    cd ${xpra_html_tmp} && python3 setup.py install /; \
    rm -rf "${xpra_html_tmp}"

ENV XPRA_PROXY_HTML5_PORT 8888

EXPOSE $XPRA_PROXY_HTML5_PORT

#### FINAL DOCKER based on user-supplied X11_SERVER Switch  ####    
FROM xfce4-${X11_SERVER}
LABEL maintainer "Domen Tabernik <domen.tabernik@fri.uni-lj.si>"
    
COPY etc /etc/

WORKDIR /
