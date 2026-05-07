#!/bin/bash
set -Eeuo pipefail

# JOOL MAP-T installer
# Source: https://github.com/NICMx/Jool/tree/mapt
# All build operations are performed inside ~/Jool.

JOOL_SRC_DIR="${JOOL_SRC_DIR:-$HOME/Jool}"
JOOL_BRANCH="mapt"
FORCE_MODE=0
[[ "${1:-}" == "--force" ]] && FORCE_MODE=1

log()  { echo -e "\e[32m[INFO]\e[0m  $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m  $*"; }
die()  { echo -e "\e[31m[ERROR]\e[0m $*" >&2; exit 1; }

# -----------------------------------------------
# 1. OS check — require Ubuntu 22.04 or 24.04
# -----------------------------------------------
check_os() {
  source /etc/os-release 2>/dev/null || die "Cannot read /etc/os-release"
  log "Detected OS: ${PRETTY_NAME:-unknown}"
  [[ "${ID:-}" == "ubuntu" ]] || { warn "Non-Ubuntu OS. Proceeding anyway."; return; }
  case "${VERSION_ID:-}" in
    22.04|24.04) log "Ubuntu ${VERSION_ID} is supported for JOOL MAP-T." ;;
    *)
      echo -e "\e[31m[ERROR]\e[0m Ubuntu ${VERSION_ID:-unknown} is not supported." >&2
      echo "Use Ubuntu 22.04 (Jammy) or 24.04 (Noble). Run with --force to override." >&2
      [[ "$FORCE_MODE" -eq 1 ]] || exit 1
      warn "Continuing with --force on unsupported Ubuntu release."
      ;;
  esac
}

# -----------------------------------------------
# 2. Validate kernel headers match running kernel
# -----------------------------------------------
validate_kernel_headers() {
  local running_kernel kdir header_pkg header_ver header_release
  local found_kernel_pkg=0 kernel_pkg kernel_ver

  running_kernel="$(uname -r)"
  kdir="/lib/modules/${running_kernel}/build"
  header_pkg="linux-headers-${running_kernel}"

  log "Validating kernel headers for: ${running_kernel}"

  # Install header package if missing.
  if ! dpkg -s "$header_pkg" >/dev/null 2>&1; then
    warn "${header_pkg} not installed. Installing now."
    sudo apt-get install -y "$header_pkg" || true
  fi
  dpkg -s "$header_pkg" >/dev/null 2>&1 || die "Required header package missing: ${header_pkg}"

  header_ver="$(dpkg-query -W -f='${Version}' "$header_pkg" 2>/dev/null)"
  [[ -n "$header_ver" ]] || die "Cannot read version for ${header_pkg}"

  # Ensure at least one running-kernel package exists and versions match.
  for kernel_pkg in \
      "linux-image-${running_kernel}" \
      "linux-image-unsigned-${running_kernel}" \
      "linux-modules-${running_kernel}"; do
    if dpkg -s "$kernel_pkg" >/dev/null 2>&1; then
      found_kernel_pkg=1
      kernel_ver="$(dpkg-query -W -f='${Version}' "$kernel_pkg" 2>/dev/null)"
      if [[ "$kernel_ver" != "$header_ver" ]]; then
        die "Package version mismatch:\n  ${kernel_pkg}=${kernel_ver}\n  ${header_pkg}=${header_ver}\nReboot into the intended kernel and re-run."
      fi
    fi
  done
  [[ "$found_kernel_pkg" -eq 1 ]] || die "No Ubuntu kernel package found for ${running_kernel}"

  # Ensure build dir exists.
  [[ -d "$kdir" ]] || die "Kernel header build dir missing: ${kdir}"

  # Resolve actual header release from generated files (avoids make kernelrelease mismatch on RPi).
  header_release=""
  if [[ -f "$kdir/include/generated/utsrelease.h" ]]; then
    header_release="$(sed -n 's/^#define UTS_RELEASE "\(.*\)"/\1/p' "$kdir/include/generated/utsrelease.h" | head -n1)"
  fi
  if [[ -z "$header_release" && -f "$kdir/include/config/kernel.release" ]]; then
    header_release="$(head -n1 "$kdir/include/config/kernel.release" 2>/dev/null || true)"
  fi
  if [[ -z "$header_release" ]]; then
    header_release="$(make -s -C "$kdir" kernelrelease 2>/dev/null || true)"
  fi
  [[ -n "$header_release" ]] || die "Cannot resolve header release from ${kdir}"
  [[ "$header_release" == "$running_kernel" ]] ||
    die "Kernel/header release mismatch:\n  running : ${running_kernel}\n  headers : ${header_release}\nReboot into the intended kernel and re-run."

  log "Kernel headers validated: ${running_kernel}"
}

# -----------------------------------------------
# 3. Remove apt JOOL DKMS if present (avoids symbol conflicts with source build)
# -----------------------------------------------
purge_dkms_if_present() {
  local running_kernel="$(uname -r)"
  sudo modprobe -r jool_mapt 2>/dev/null || true
  sudo modprobe -r jool_siit 2>/dev/null || true
  sudo modprobe -r jool     2>/dev/null || true
  sudo modprobe -r jool_common 2>/dev/null || true

  if dpkg -s jool-dkms >/dev/null 2>&1; then
    warn "Purging jool-dkms to avoid kernel symbol conflicts with source-built MAP-T modules."
    sudo apt-get purge -y jool-dkms
  fi

  # Remove residual DKMS/extra ko files.
  sudo find "/lib/modules/${running_kernel}" -type f \
    \( -path "*/dkms/jool*.ko*" -o -path "*/updates/jool*.ko*" -o -path "*/extra/jool*.ko*" \) \
    -delete 2>/dev/null || true
  sudo depmod -a
}

# -----------------------------------------------
# 4. Clone or update ~/Jool from mapt branch
# -----------------------------------------------
setup_jool_source() {
  log "Setting up JOOL source tree at: ${JOOL_SRC_DIR}  (branch: ${JOOL_BRANCH})"

  if [[ ! -d "${JOOL_SRC_DIR}/.git" ]]; then
    log "Cloning https://github.com/NICMx/Jool.git"
    git clone https://github.com/NICMx/Jool.git "$JOOL_SRC_DIR"
  fi

  cd "$JOOL_SRC_DIR"
  git fetch origin "${JOOL_BRANCH}"
  git checkout "${JOOL_BRANCH}" || die "Branch '${JOOL_BRANCH}' not found. Check https://github.com/NICMx/Jool/tree/${JOOL_BRANCH}"
  git reset --hard "origin/${JOOL_BRANCH}"
  log "JOOL source is at branch '${JOOL_BRANCH}': $(git rev-parse --short HEAD)"
}

# -----------------------------------------------
# 5. Build kernel modules  (all from ~/Jool)
# -----------------------------------------------
build_modules() {
  local running_kernel kdir
  running_kernel="$(uname -r)"
  kdir="/lib/modules/${running_kernel}/build"

  cd "$JOOL_SRC_DIR"

  log "Cleaning previous build artifacts..."
  make distclean || true

  log "Running autogen + configure..."
  ./autogen.sh
  ./configure --with-linux="$kdir"

  log "Building kernel modules in ${JOOL_SRC_DIR}/src/mod"
  cd "${JOOL_SRC_DIR}/src/mod"
  for module in common siit nat64 mapt; do
    log "Building: ${module}"
    if ! make -C "$module" KERNEL_DIR="$kdir" -j"$(nproc)"; then
      warn "Retrying clean build for ${module}..."
      make -C "$module" clean KERNEL_DIR="$kdir"
      make -C "$module" KERNEL_DIR="$kdir" -j"$(nproc)" || die "Failed to build module: ${module}"
    fi
  done
}

# -----------------------------------------------
# 6. Build + install userland binaries  (from ~/Jool)
# -----------------------------------------------
build_userland() {
  cd "$JOOL_SRC_DIR"
  log "Building userland binaries..."
  make -j"$(nproc)"
  sudo make install
}

# -----------------------------------------------
# 7. Install .ko files into extra/jool-mapt and refresh depmod
# -----------------------------------------------
install_modules() {
  local running_kernel kdir update_dir
  running_kernel="$(uname -r)"
  kdir="/lib/modules/${running_kernel}/build"
  update_dir="/lib/modules/${running_kernel}/extra/jool-mapt"

  log "Installing kernel modules into ${update_dir}"
  sudo mkdir -p "$update_dir"

  for ko in \
      "${JOOL_SRC_DIR}/src/mod/common/jool_common.ko" \
      "${JOOL_SRC_DIR}/src/mod/siit/jool_siit.ko" \
      "${JOOL_SRC_DIR}/src/mod/nat64/jool.ko" \
      "${JOOL_SRC_DIR}/src/mod/mapt/jool_mapt.ko"; do
    if [[ -f "$ko" ]]; then
      sudo install -m 0644 "$ko" "$update_dir/"
      log "Installed: $(basename "$ko")"
    else
      die "Module not found after build: ${ko}"
    fi
  done

  sudo depmod -a
}

# -----------------------------------------------
# 8. Load modules and verify — all hard failures
# -----------------------------------------------
load_and_verify() {
  # Unload any stale JOOL modules first.
  sudo modprobe -r jool_mapt 2>/dev/null || true
  sudo modprobe -r jool_siit 2>/dev/null || true
  sudo modprobe -r jool     2>/dev/null || true
  sudo modprobe -r jool_common 2>/dev/null || true

  # Verify userspace binaries.
  command -v jool      >/dev/null 2>&1 || die "jool CLI binary not found in PATH"
  command -v jool_mapt >/dev/null 2>&1 || die "jool_mapt CLI binary not found in PATH"
  jool --version       >/dev/null 2>&1 || die "jool CLI present but not responding"
  jool_mapt --help     >/dev/null 2>&1 || die "jool_mapt CLI present but not responding"

  # Verify module metadata is registered.
  modinfo jool_common >/dev/null 2>&1 || die "Kernel module metadata missing: jool_common"
  modinfo jool        >/dev/null 2>&1 || die "Kernel module metadata missing: jool"
  modinfo jool_mapt   >/dev/null 2>&1 || die "Kernel module metadata missing: jool_mapt"

  # Load in dependency order.
  sudo modprobe jool_common || die "Failed to load: jool_common"
  sudo modprobe jool        || die "Failed to load: jool"
  sudo modprobe jool_mapt   || die "Failed to load: jool_mapt"

  # Confirm resident in kernel.
  lsmod | awk '{print $1}' | grep -qx 'jool_common' || die "jool_common not resident after modprobe"
  lsmod | awk '{print $1}' | grep -qx 'jool'        || die "jool not resident after modprobe"
  lsmod | awk '{print $1}' | grep -qx 'jool_mapt'   || die "jool_mapt not resident after modprobe"

  log "JOOL MAP-T verified: userspace tools and kernel modules are working."
}

# -----------------------------------------------
# main
# -----------------------------------------------
log "=== JOOL MAP-T installer started ==="

check_os

log "Updating package index..."
sudo apt-get update -y

log "Installing build dependencies..."
sudo apt-get install -y \
  git build-essential autoconf automake libtool pkg-config \
  libnl-3-dev libnl-genl-3-dev libxtables-dev bc kmod \
  linux-headers-"$(uname -r)"

validate_kernel_headers
purge_dkms_if_present
setup_jool_source
build_modules
build_userland
install_modules
load_and_verify

log "=== JOOL MAP-T installer complete ==="