ARG ROOT_IMAGE
ARG X11_SERVER="xpra"

#### BASE XFCE4 ####
FROM ${ROOT_IMAGE} as xfce4-base

ENV DEBIAN_FRONTEND noninteractive

RUN apt-get clean && \
    apt-get update --fix-missing && \
    apt-get install -y --no-install-recommends xfce4 mate-terminal krusader && \
    apt-get install -y --no-install-recommends xubuntu-artwork xubuntu-icon-theme  breeze-icon-theme && \
    apt-get install -y --no-install-recommends ristretto gvfs gvfs-backends thunar-archive-plugin kio-extras ktexteditor-katepart && \
    apt-get auto-remove -y && \
    rm -rf /var/lib/apt/lists/*

#### XFCE4 with X2GO ####
FROM xfce4-base as xfce4-x2go

ENV DEBIAN_FRONTEND noninteractive

RUN apt-get clean && \
    apt-get update --fix-missing && \
    apt-get install -y --no-install-recommends software-properties-common && \
    add-apt-repository -y ppa:x2go/stable && apt-get update && \
    apt-get install -y --no-install-recommends x2goserver x2goserver-xsession pwgen dbus-x11 xdg-utils libdbus-glib-1-2 libdbusmenu-glib4 libdbusmenu-gtk3-4 python3-xdg python3-pyinotify xserver-xorg-input-libinput && \
    apt-get auto-remove -y && \
    rm -rf /var/lib/apt/lists/*

# disable XPRA service since it is not installed
RUN mkdir -p /etc/service/xpra-proxy-html5 && touch /etc/service/xpra-proxy-html5/down

#### XFCE4 with Xpra ####
FROM xfce4-base as xfce4-xpra

RUN apt-get clean && \
    apt-get update --fix-missing && \
    apt-get install -y --no-install-recommends software-properties-common apt-transport-https && \
    wget -q https://xpra.org/gpg.asc -O- | apt-key add - && \
    add-apt-repository "deb https://xpra.org/lts `lsb_release -cs` main" && apt-get update && \
    apt-get install -y --no-install-recommends xpra=5.1.1-r0-1 dbus-x11 xdg-utils libdbus-glib-1-2 libdbusmenu-glib4 libdbusmenu-gtk3-4 python3-xdg python3-pyinotify xserver-xorg-input-libinput websockify uglifyjs && \
    apt-get auto-remove -y && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/xpra-html5
RUN git clone --branch v4.5.1 https://github.com/Xpra-org/xpra-html5 . && ./setup.py install /usr/share/xpra/www && rm -rf /tmp/xpra-html5/*

ENV XPRA_PROXY_HTML5_PORT 8888

EXPOSE $XPRA_PROXY_HTML5_PORT

#### FINAL DOCKER based on user-supplied X11_SERVER Switch  ####    
FROM xfce4-${X11_SERVER}
LABEL maintainer "Domen Tabernik <domen.tabernik@fri.uni-lj.si>"
    
COPY etc /etc/

WORKDIR /
