#!/bin/bash

set -euo pipefail

KVER=$(uname -r)
JOOL_DIR="$HOME/Jool"

echo "=================================================="
echo " Rebuilding Jool for kernel: $KVER"
echo "=================================================="

echo
echo "[1/8] Installing dependencies..."
sudo apt update

sudo apt install -y \
    build-essential \
    autoconf \
    automake \
    libtool \
    pkg-config \
    flex \
    bison \
    git \
    libnl-3-dev \
    libnl-genl-3-dev \
    libxtables-dev \
    linux-headers-$KVER

echo
echo "[2/8] Checking Jool source..."

if [ ! -d "$JOOL_DIR" ]; then
    echo "ERROR: Jool source directory not found:"
    echo "$JOOL_DIR"
    exit 1
fi

cd "$JOOL_DIR"

echo
echo "[3/8] Cleaning previous builds..."

make distclean 2>/dev/null || true

autoreconf -fi

echo
echo "[4/8] Configuring build..."

./configure

echo
echo "[5/8] Building kernel modules..."

pushd src/mod >/dev/null

# Build order matters: siit/nat64/mapt consume common/Module.symvers.
make -C common
make -C siit
make -C nat64
make -C mapt

popd >/dev/null

echo
echo "[6/8] Installing modules..."

sudo mkdir -p /lib/modules/$KVER/extra

for ko in \
    src/mod/common/jool_common.ko \
    src/mod/siit/jool_siit.ko \
    src/mod/nat64/jool.ko \
    src/mod/mapt/jool_mapt.ko; do
    if [ ! -f "$ko" ]; then
        echo "ERROR: Expected module not found: $ko"
        exit 1
    fi
    sudo cp "$ko" /lib/modules/$KVER/extra/
done

echo
echo "[7/8] Running depmod..."

sudo depmod -a

echo
echo "[8/8] Loading modules..."

for mod in jool_common jool jool_siit jool_mapt; do
    if ! sudo modprobe "$mod"; then
        echo "WARN: Failed to load module: $mod"
    fi
done

echo
echo "=================================================="
echo " Installed modules:"
echo "=================================================="

find /lib/modules/$KVER -name "*jool*"

echo
echo "=================================================="
echo " Loaded modules:"
echo "=================================================="

lsmod | grep jool || true

echo
echo "=================================================="
echo " Done"
echo "=================================================="