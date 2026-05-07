#!/bin/bash
set -Eeuo pipefail

# JOOL MAP-T installer with strict kernel/header validation.
# Behavior:
# - Prefer Ubuntu packages (jool-tools + jool-dkms) when available.
# - Fall back to source build from NICMx/Jool mapt branch.
# - Validate that running kernel matches installed headers.
# - Guide user to Ubuntu 22.04/24.04 when environment is not suitable.

FORCE_MODE=0
if [[ "${1:-}" == "--force" ]]; then
  FORCE_MODE=1
fi

log()   { echo "[INFO] $*"; }
warn()  { echo "[WARN] $*"; }
error() { echo "[ERROR] $*" >&2; }
die()   { error "$*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command '$1' is missing"
}

require_sudo() {
  if [[ $EUID -eq 0 ]]; then
    SUDO=""
  else
    require_cmd sudo
    SUDO="sudo"
  fi
}

load_os_info() {
  if [[ ! -f /etc/os-release ]]; then
    die "Cannot detect OS: /etc/os-release not found"
  fi
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VER="${VERSION_ID:-unknown}"
  OS_PRETTY="${PRETTY_NAME:-$OS_ID $OS_VER}"
}

check_supported_ubuntu() {
  load_os_info
  log "Detected OS: $OS_PRETTY"

  if [[ "$OS_ID" != "ubuntu" ]]; then
    warn "Non-Ubuntu system detected. Jool build may still work if toolchain and headers are valid."
    return
  fi

  case "$OS_VER" in
    22.04|24.04)
      log "Ubuntu $OS_VER is recommended for JOOL MAP-T."
      ;;
    *)
      cat >&2 <<'EOF'
[ERROR] Unsupported Ubuntu release for this installer policy.
Use Ubuntu 22.04 (Jammy) or 24.04 (Noble) for stable JOOL MAP-T builds.
Run again with --force only if you intentionally accept potential build failures.
EOF
      [[ $FORCE_MODE -eq 1 ]] || exit 1
      warn "Continuing because --force was provided."
      ;;
  esac
}

update_system() {
  log "Updating package index..."
  $SUDO apt-get update -y
}

install_base_dependencies() {
  log "Installing build dependencies..."
  $SUDO apt-get install -y \
    git build-essential autoconf automake libtool pkg-config \
    libnl-3-dev libnl-genl-3-dev libxtables-dev bc kmod \
    linux-headers-"$(uname -r)"
}

ensure_kernel_headers_valid() {
  local running_kernel
  local kdir
  local header_kernel

  running_kernel="$(uname -r)"
  kdir="/lib/modules/${running_kernel}/build"

  log "Validating kernel headers for running kernel: ${running_kernel}"

  if [[ ! -d "$kdir" ]]; then
    warn "Headers not found at $kdir. Installing linux-headers-${running_kernel}."
    $SUDO apt-get install -y "linux-headers-${running_kernel}" || true
  fi

  if [[ ! -d "$kdir" ]]; then
    die "Kernel headers are still missing for ${running_kernel}."
  fi

  if ! header_kernel="$(make -s -C "$kdir" kernelrelease 2>/dev/null)"; then
    die "Unable to read header kernelrelease from ${kdir}. Headers are invalid or incomplete."
  fi

  if [[ "$header_kernel" != "$running_kernel" ]]; then
    cat >&2 <<EOF
[ERROR] Kernel/header mismatch detected.
Running kernel : ${running_kernel}
Header release : ${header_kernel}

Recommended fix:
1) Use Ubuntu 22.04/24.04 with a supported kernel and matching headers.
2) Reboot into the installed kernel after apt upgrades.
3) Re-run this script.
EOF
    exit 1
  fi

  log "Kernel headers are valid and match running kernel."
}

apt_pkg_available() {
  local pkg="$1"
  apt-cache show "$pkg" >/dev/null 2>&1
}

install_from_packages_if_available() {
  if apt_pkg_available jool-tools && apt_pkg_available jool-dkms; then
    log "Installing JOOL from packages: jool-tools + jool-dkms"
    $SUDO apt-get install -y jool-tools jool-dkms
    return 0
  fi

  warn "JOOL packages (jool-tools/jool-dkms) not available in apt. Falling back to source build."
  return 1
}

build_from_source() {
  local running_kernel
  local kdir

  running_kernel="$(uname -r)"
  kdir="/lib/modules/${running_kernel}/build"

  cd "$HOME"
  if [[ ! -d "Jool/.git" ]]; then
    log "Cloning JOOL repository..."
    git clone https://github.com/NICMx/Jool.git
  fi

  cd "$HOME/Jool"
  git fetch --all --tags
  git checkout mapt || true

  log "Cleaning previous build artifacts..."
  make distclean || true

  log "Running autogen/configure..."
  ./autogen.sh
  ./configure --with-linux="$kdir"

  log "Building JOOL kernel modules..."
  cd "$HOME/Jool/src/mod"
  local module
  for module in common siit nat64 mapt; do
    log "Building module: ${module}"
    if ! make -C "$module" KERNEL_DIR="$kdir" -j"$(nproc)"; then
      warn "Retrying clean build for ${module}"
      make -C "$module" clean KERNEL_DIR="$kdir"
      make -C "$module" KERNEL_DIR="$kdir" -j"$(nproc)"
    fi
  done

  log "Building/installing userland binaries..."
  cd "$HOME/Jool"
  make -j"$(nproc)"
  $SUDO make install

  log "Installing kernel modules into updates dir..."
  local update_dir
  update_dir="/lib/modules/${running_kernel}/updates"
  $SUDO mkdir -p "$update_dir"

  local modules=(
    "$HOME/Jool/src/mod/common/jool_common.ko"
    "$HOME/Jool/src/mod/siit/jool_siit.ko"
    "$HOME/Jool/src/mod/nat64/jool.ko"
    "$HOME/Jool/src/mod/mapt/jool_mapt.ko"
  )

  local ko
  for ko in "${modules[@]}"; do
    if [[ -f "$ko" ]]; then
      $SUDO install -m 0644 "$ko" "$update_dir/"
    else
      warn "Module not found: $ko"
    fi
  done
}

load_and_verify() {
  log "Refreshing module dependencies..."
  $SUDO depmod -a

  # Verify userspace tools exist and respond.
  command -v jool >/dev/null 2>&1 || die "JOOL CLI binary not found in PATH"
  command -v jool_mapt >/dev/null 2>&1 || die "jool_mapt binary not found in PATH"
  jool --version >/dev/null 2>&1 || die "JOOL CLI is present but not working"
  jool_mapt --help >/dev/null 2>&1 || die "jool_mapt CLI is present but not working"

  # Verify kernel modules are installed in module tree.
  modinfo jool_common >/dev/null 2>&1 || die "Kernel module metadata missing: jool_common"
  modinfo jool >/dev/null 2>&1 || die "Kernel module metadata missing: jool"
  modinfo jool_mapt >/dev/null 2>&1 || die "Kernel module metadata missing: jool_mapt"

  # Load required modules and confirm they are resident.
  $SUDO modprobe jool_common || die "Failed to load module: jool_common"
  $SUDO modprobe jool || die "Failed to load module: jool"
  $SUDO modprobe jool_mapt || die "Failed to load module: jool_mapt"

  lsmod | awk '{print $1}' | grep -qx 'jool_common' || die "Module not loaded after modprobe: jool_common"
  lsmod | awk '{print $1}' | grep -qx 'jool' || die "Module not loaded after modprobe: jool"
  lsmod | awk '{print $1}' | grep -qx 'jool_mapt' || die "Module not loaded after modprobe: jool_mapt"

  log "JOOL userspace tools and kernel modules verified successfully."
}

main() {
  require_sudo
  require_cmd apt-get
  require_cmd make
  require_cmd git

  log "=== JOOL MAP-T installer started ==="
  check_supported_ubuntu
  update_system
  install_base_dependencies
  ensure_kernel_headers_valid

  if ! install_from_packages_if_available; then
    build_from_source
  fi

  load_and_verify
  log "=== JOOL MAP-T installer complete ==="
}

main "$@"
