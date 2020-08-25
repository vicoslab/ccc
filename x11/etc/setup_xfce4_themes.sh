#!/bin/bash -e

USER_NAME=${USER_NAME:-user}
USER_PUBKEY=${USER_PUBKEY}
USER_HOME=${BASE%"/"}/$USER_NAME

cd $USER_HOME

tar --skip-old-files -xf /etc/user_config.tar.gz

# setup defualt font rendering for X11 applications when not using XFCE4 sesseion i.e. for x2go/xpra terminal only
cat > $USER_HOME/.Xdefaults<<EOF
Xft.antialias: 0
Xfg.hinting: 1
Xft.hintstyle: hintfull
Xft.rgba: none
Xft.dpi: 96
EOF 

chown $USER_NAME:$USER_NAME $USER_HOME/.Xdefaults

# unpack custom theme even if not installing desktop in case we need to run any gtk application in X11 forwarding
cd /
chpst -u root tar xf /etc/gtk-theme.tar.gz

# set default gtk2 theme for when using x2go/xfce terminal only
chpst -u root cp -R /usr/share/themes/Ambiance-XFCE-LXDE-fixed/gtk-2.0/* /etc/gtk-2.0/.
