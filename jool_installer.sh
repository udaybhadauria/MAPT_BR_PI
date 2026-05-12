#!/bin/bash
set -euo pipefail
 
echo "=== JOOL MAP-T all-in-one installer + recovery script ==="
 
log()   { echo -e "\e[32m[INFO]\e[0m $*"; }
warn()  { echo -e "\e[33m[WARN]\e[0m $*"; }
error() { echo -e "\e[31m[ERROR]\e[0m $*"; }
 
command_exists() { command -v "$1" >/dev/null 2>&1; }
 
# -----------------------------
# 1. Update system
# -----------------------------
log "Updating system..."
sudo apt update -y && sudo apt upgrade -y
 
# -----------------------------
# 2. Install dependencies
# -----------------------------
log "Installing dependencies..."
sudo apt install -y git build-essential autoconf automake libtool pkg-config \
    libnl-3-dev libnl-genl-3-dev libxtables-dev bc linux-headers-$(uname -r)
 
# -----------------------------
# 3. Check kernel headers
# -----------------------------
KDIR="/lib/modules/$(uname -r)/build"
if [ ! -d "$KDIR" ]; then
    warn "Kernel headers missing. Attempting to install..."
    sudo apt install -y linux-headers-$(uname -r)
fi
 
# -----------------------------
# 4. Clone or update JOOL repo
# -----------------------------
cd ~
if [ ! -d "Jool" ]; then
    log "Cloning JOOL repository..."
    git clone https://github.com/NICMx/Jool.git
fi
cd Jool
git fetch --all
git checkout mapt || true
 
# -----------------------------
# 5. Clean previous builds
# -----------------------------
log "Cleaning previous builds..."
make distclean || true
 
# -----------------------------
# 6. Autogen + configure
# -----------------------------
log "Running autogen and configure..."
./autogen.sh || true
./configure --with-linux="$KDIR" || true
 
# -----------------------------
# 7. Build all modules
# -----------------------------
log "Building JOOL kernel modules..."
cd src/mod
for module in common siit nat64 mapt; do
    log "Building $module..."
    if ! make -C $module KERNEL_DIR="$KDIR" -j$(nproc); then
        warn "Retrying $module..."
        make -C $module clean KERNEL_DIR="$KDIR"
        make -C $module KERNEL_DIR="$KDIR" -j$(nproc) || { error "Failed to build $module"; exit 1; }
    fi
done
 
# -----------------------------
# 8. Install userland binaries
# -----------------------------
log "Installing userland binaries..."
cd ~/Jool
make -j$(nproc) || warn "Userland build failed"
sudo make install
sudo depmod -a
 
# -----------------------------
# 9. Copy modules to updates folder
# -----------------------------
log "Copying kernel modules to updates directory..."
UPDATE_DIR="/lib/modules/$(uname -r)/updates"
sudo mkdir -p "$UPDATE_DIR"
for ko in ~/Jool/src/mod/common/jool_common.ko \
          ~/Jool/src/mod/siit/jool_siit.ko \
          ~/Jool/src/mod/nat64/jool.ko \
          ~/Jool/src/mod/mapt/jool_mapt.ko; do
    if [ -f "$ko" ]; then
        sudo cp "$ko" "$UPDATE_DIR"
    else
        warn "Module $ko not found"
    fi
done
sudo depmod -a
 
# -----------------------------
# 10. Load JOOL modules
# -----------------------------
log "Loading JOOL kernel modules..."
for mod in jool_common jool jool_siit jool_mapt; do
    sudo modprobe "$mod" || warn "Failed to load $mod"
done
 
# -----------------------------
# 11. Verification
# -----------------------------
log "Verifying installation..."
if jool --version >/dev/null 2>&1; then
    log "JOOL binary exists"
else
    warn "jool binary not found"
fi
 
if lsmod | grep -q jool; then
    log "JOOL kernel module loaded successfully"
else
    warn "JOOL kernel module not loaded"
fi
 
log "=== Installation complete ==="