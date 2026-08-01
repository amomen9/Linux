#!/bin/bash
# Install Google Chrome and Microsoft Edge on Debian/Ubuntu, plus the
# minimal X11 stack (xauth, xterm, Openbox) needed to display their
# windows back over an X11-forwarded SSH session.
set -euo pipefail

# --- Base packages -----------------------------------------------------
sudo apt update
sudo apt install -y xterm xauth xorg openbox x11-apps

# Make sure the current user's X authority file exists so xauth/SSH X11
# forwarding has something to write cookies into. Default permissions
# from touch (no world read/write) are sufficient; it must stay private.
touch ~/.Xauthority

# --- Microsoft Edge ------------------------------------------------------
if ! command -v microsoft-edge-stable >/dev/null 2>&1; then
    sudo sh -c '
        set -euo pipefail
        wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
          | gpg --dearmor > /usr/share/keyrings/microsoft-edge.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-edge.gpg] https://packages.microsoft.com/repos/edge stable main" \
          > /etc/apt/sources.list.d/microsoft-edge.list
        apt update
        apt install -y microsoft-edge-stable
    '
else
    echo "Microsoft Edge is already installed, skipping."
fi

# --- Google Chrome ---------------------------------------------------------
if ! command -v google-chrome-stable >/dev/null 2>&1; then
    tmp_deb="$(mktemp --suffix=.deb)"
    curl -fL -o "$tmp_deb" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    sudo apt install -y --fix-broken "$tmp_deb"
    rm -f "$tmp_deb"
else
    echo "Google Chrome is already installed, skipping."
fi

# --- Clean up ------------------------------------------------------------
sudo apt-get clean
