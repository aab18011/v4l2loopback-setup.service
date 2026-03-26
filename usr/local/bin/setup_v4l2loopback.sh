#!/bin/bash
set -euo pipefail

REPO_DIR="/home/user/Documents/v4l2loopback"
USER_NAME="user"   # replace with your username

# Ensure dkms is available
if ! command -v dkms &>/dev/null; then
    echo "dkms not found, installing..."
    pacman -S --noconfirm dkms linux-headers
fi

# Clone repo if missing
if [ ! -d "$REPO_DIR" ]; then
    sudo -u "$USER_NAME" git clone https://github.com/aab18011/v4l2loopback.git "$REPO_DIR"
fi

cd "$REPO_DIR"

# Get current commit
CURRENT_COMMIT=$(sudo -u "$USER_NAME" git rev-parse HEAD 2>/dev/null || echo "none")

# Fetch latest
sudo -u "$USER_NAME" git fetch origin main

# Get remote commit
REMOTE_COMMIT=$(sudo -u "$USER_NAME" git rev-parse origin/main)

# Compute version
VERSION=$(sudo -u "$USER_NAME" git describe --always --dirty 2>/dev/null \
          || sudo -u "$USER_NAME" git describe --always 2>/dev/null \
          || echo snapshot)

# Get current kernel
CURRENT_KERNEL=$(uname -r)

# DKMS 3.x (Arch) uses "module/version, kernel, arch: status"
if dkms status | grep -qE "^v4l2loopback/$VERSION,\s*$CURRENT_KERNEL.*: installed$"; then
    INSTALLED=true
else
    INSTALLED=false
fi

if [ "$CURRENT_COMMIT" != "$REMOTE_COMMIT" ] || ! $INSTALLED; then
    sudo -u "$USER_NAME" git reset --hard origin/main

    # Recompute version after reset
    VERSION=$(sudo -u "$USER_NAME" git describe --always --dirty 2>/dev/null \
              || sudo -u "$USER_NAME" git describe --always 2>/dev/null \
              || echo snapshot)

    echo "Preparing to install v4l2loopback version: $VERSION"

    # --- PATCH FOR KERNEL 6.19+ API CHANGE ---
    # v4l2_fh_add/del gained a mandatory second 'filp' argument in 6.19.
    if grep -q 'v4l2_fh_add(&opener->fh);' v4l2loopback.c; then
        echo "Applying kernel 6.19+ v4l2_fh patch..."
        sed -i 's/v4l2_fh_add(&opener->fh);/v4l2_fh_add(\&opener->fh, filp);/g' v4l2loopback.c
        sed -i 's/v4l2_fh_del(&opener->fh);/v4l2_fh_del(\&opener->fh, filp);/g' v4l2loopback.c
    fi

    # --- CLEANUP BROKEN DKMS ENTRIES ---
    while IFS=',' read -r mod ver; do
        mod="${mod// /}"
        ver="${ver// /}"
        SRC_DIR="/var/lib/dkms/$mod/$ver/source"
        if [ ! -f "$SRC_DIR/dkms.conf" ]; then
            echo "Removing broken DKMS entry: $mod $ver"
            dkms remove -m "$mod" -v "$ver" --all || true
            rm -rf "/usr/src/$mod-$ver" "/var/lib/dkms/$mod/$ver"
        fi
    done < <(dkms status | awk -F'[/,]' '/^v4l2loopback\//{print $1","$2}' | tr -d ' ')

    # --- REMOVE OLD VERSIONS ---
    while IFS= read -r ver; do
        ver="${ver// /}"
        if [ -n "$ver" ] && [ "$ver" != "$VERSION" ]; then
            echo "Removing old DKMS version: $ver"
            dkms remove -m v4l2loopback -v "$ver" --all || true
            rm -rf "/usr/src/v4l2loopback-$ver" "/var/lib/dkms/v4l2loopback/$ver"
        fi
    done < <(dkms status | awk -F'[/,]' '/^v4l2loopback\//{print $2}' | tr -d ' ')

    # --- FORCE REMOVE CURRENT VERSION IF EXISTS ---
    dkms remove -m v4l2loopback -v "$VERSION" --all || true
    rm -rf "/var/lib/dkms/v4l2loopback/$VERSION"
    rm -rf "/usr/src/v4l2loopback-$VERSION"

    # --- COPY SOURCES ---
    cp -r . "/usr/src/v4l2loopback-$VERSION"

    # --- ADD / BUILD / INSTALL ---
    dkms add -m v4l2loopback -v "$VERSION"
    dkms build -m v4l2loopback -v "$VERSION"
    dkms install -m v4l2loopback -v "$VERSION" --force

else
    echo "No updates and already installed for current kernel, skipping install."
fi

# --- LOAD MODULE ---
modprobe -r v4l2loopback || true
modprobe v4l2loopback devices=16 exclusive_caps=1 \
    video_nr=$(seq -s, 0 15) \
    card_label=$(printf "'Cam%d'," {0..15} | sed 's/,$//')

echo "v4l2loopback $VERSION loaded."
