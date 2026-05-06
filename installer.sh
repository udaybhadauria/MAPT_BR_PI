#!/bin/bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0")"
BASE_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
VENV_DIR="$BASE_DIR/ui_venv"

PKGS=(
  curl tcpdump mosquitto mosquitto-clients jq yq iproute2 net-tools
  radvd kea-dhcp6-server kea-dhcp4-server apparmor-utils
  iptables-persistent dibbler-client openssh-server python3-venv
)

SERVICES=(
  kea-dhcp6-server kea-dhcp4-server radvd dibbler-client ssh mosquitto
)

log() {
  echo "[$(date +"%F %T")] $*"
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: Run as root (sudo ./installer.sh)"
    exit 1
  fi
}

ensure_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: Required command not found: $cmd"
    exit 1
  }
}

install_apt_packages() {
  export DEBIAN_FRONTEND=noninteractive
  log "Updating apt package index"
  apt-get update

  log "Installing required packages"
  apt-get install -y "${PKGS[@]}"

  log "Verifying package installation"
  local missing=0
  for p in "${PKGS[@]}"; do
    if ! dpkg -s "$p" >/dev/null 2>&1; then
      echo "ERROR: Package missing after install: $p"
      missing=1
    fi
  done

  if [[ "$missing" -ne 0 ]]; then
    exit 1
  fi
}

enable_and_start_services() {
  log "Reloading systemd"
  systemctl daemon-reload

  log "Enabling and starting required services"
  for s in "${SERVICES[@]}"; do
    systemctl enable "$s"
    systemctl start "$s"
  done

  log "Verifying service state"
  local failed=0
  for s in "${SERVICES[@]}"; do
    if ! systemctl is-active --quiet "$s"; then
      echo "ERROR: Service not running: $s"
      failed=1
    fi
  done

  if [[ "$failed" -ne 0 ]]; then
    exit 1
  fi
}

configure_mosquitto() {
  local mosq_conf="/etc/mosquitto/conf.d/listener.conf"

  log "Configuring Mosquitto listener"
  mkdir -p /etc/mosquitto/conf.d

  cat > "$mosq_conf" <<EOF
listener 1883 ::
allow_anonymous true
EOF

  systemctl restart mosquitto
  systemctl is-active --quiet mosquitto || { echo "ERROR: Mosquitto is not active"; exit 1; }
  ss -lntp | grep -q ":1883" || { echo "ERROR: Mosquitto is not listening on 1883"; exit 1; }
}

configure_forwarding() {
  log "Enabling runtime IPv4/IPv6 forwarding"
  echo 1 > /proc/sys/net/ipv4/ip_forward
  echo 1 > /proc/sys/net/ipv6/conf/all/forwarding

  log "Persisting forwarding in sysctl"
  if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  fi
  if ! grep -q "^net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf; then
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
  fi
  sysctl -p >/dev/null
}

create_or_update_venv() {
  if [[ ! -d "$VENV_DIR" ]]; then
    log "Creating virtual environment at $VENV_DIR"
    python3 -m venv "$VENV_DIR"
  else
    log "Using existing virtual environment at $VENV_DIR"
  fi

  log "Installing Python dependencies"
  "$VENV_DIR/bin/pip" install --upgrade pip
  "$VENV_DIR/bin/pip" install paho-mqtt flask
}

verify_python_deps() {
  log "Verifying Python dependencies"
  "$VENV_DIR/bin/python" - <<'EOF'
import sys
try:
    import flask
    import paho.mqtt.client
except Exception as exc:
    print("ERROR: Python dependency validation failed:", exc)
    sys.exit(1)
print("OK: Flask and paho-mqtt import succeeded")
EOF
}

configure_apparmor_and_kea() {
  log "Setting Kea AppArmor profiles to complain mode"
  aa-complain /usr/sbin/kea-dhcp6 || true
  aa-complain /usr/sbin/kea-dhcp4 || true

  log "Fixing Kea lease file permissions when present"
  shopt -s nullglob
  local lease_files=(/var/lib/kea/kea-leases*.csv)
  if (( ${#lease_files[@]} > 0 )); then
    chmod 640 "${lease_files[@]}"
    chown _kea:_kea "${lease_files[@]}"
  fi
  shopt -u nullglob

  log "Fixing Kea config file permissions"
  if [[ -f /etc/kea/kea-dhcp4.conf ]]; then
    chmod 644 /etc/kea/kea-dhcp4.conf
    chown root:root /etc/kea/kea-dhcp4.conf
  fi
  if [[ -f /etc/kea/kea-dhcp6.conf ]]; then
    chmod 644 /etc/kea/kea-dhcp6.conf
    chown root:root /etc/kea/kea-dhcp6.conf
  fi

  log "Validating Kea configurations"
  [[ -f /etc/kea/kea-dhcp4.conf ]] && kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
  [[ -f /etc/kea/kea-dhcp6.conf ]] && kea-dhcp6 -t /etc/kea/kea-dhcp6.conf
}

make_scripts_executable() {
  log "Ensuring shell scripts are executable"
  find "$BASE_DIR" -maxdepth 1 -type f -name "*.sh" -exec chmod +x {} \;
}

main() {
  require_root
  ensure_cmd python3
  ensure_cmd apt-get
  ensure_cmd dpkg
  ensure_cmd systemctl
  ensure_cmd crontab
  ensure_cmd ss
  ensure_cmd aa-complain

  log "Starting non-interactive installation from $BASE_DIR"

  install_apt_packages
  enable_and_start_services
  configure_mosquitto
  configure_forwarding

  make_scripts_executable
  create_or_update_venv
  verify_python_deps
  configure_apparmor_and_kea

  log "Configuring systemd services"
  bash "$BASE_DIR/managed_services.sh"

  log "Configuring cron schedule"
  bash "$BASE_DIR/scheduler_cron.sh"

  echo
  echo "======================================"
  echo " ALL PACKAGES INSTALLED"
  echo " ALL SERVICES RUNNING"
  echo " KEA CONFIGS VALID"
  echo " PERMISSIONS SET"
  echo "======================================"

  log "Installation completed successfully"
}

main "$@"
