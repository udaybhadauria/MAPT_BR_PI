#!/bin/bash

set -e

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0")"
BASE_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
LOG="$BASE_DIR/zboot_logs.log"
mkdir -p "$(dirname "$LOG")"
touch "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "###############################################################"
echo "Running script: $0"
echo "Date: $(date)"

# --- Detect LAN interface (enx* or eth1) ---
LAN_IFACE=$(ip -o link show | awk -F': ' '$2 ~ /^(enx|eth1)/ {print $2; exit}')

if [[ -z "$LAN_IFACE" ]]; then
  echo "❌ ERROR: No LAN interface found (enx* or eth1)"
  exit 1
fi

echo "🔍 Detected LAN interface: $LAN_IFACE"

# Helper functions
check_ipv4() {
  local iface="$1"
  ip -4 addr show dev "$iface" 2>/dev/null | grep -q "inet " && return 0 || return 1
}

check_ipv6() {
  local iface="$1"
  ip -6 addr show dev "$iface" scope global 2>/dev/null | grep -q "inet6 " && return 0 || return 1
}

check_link_local() {
  local iface="$1"
  ip -6 addr show dev "$iface" scope link 2>/dev/null | grep -q "inet6 fe80" && return 0 || return 1
}

restart_services() {
  echo "⚠️  No valid IP configuration on $LAN_IFACE. Restarting services..."
  echo "[*] Applying netplan..."
  netplan apply || true

  sleep 2

  for svc in kea-dhcp4-server kea-dhcp6-server radvd; do
    echo "[*] Restarting $svc..."
    systemctl restart "$svc" || echo "❌ Failed to restart $svc"
  done

  sleep 3
}

echo "🔍 Checking IP configuration on $LAN_IFACE..."

# Check for IPv4
if check_ipv4 "$LAN_IFACE"; then
  IPV4=$(ip -4 addr show dev "$LAN_IFACE" | awk '/inet / {print $2}')
  echo "✅ IPv4 present: $IPV4"
else
  echo "❌ No IPv4 address on $LAN_IFACE"
fi

# Check for IPv6 global
if check_ipv6 "$LAN_IFACE"; then
  IPV6=$(ip -6 addr show dev "$LAN_IFACE" scope global | awk '/inet6/ {print $2; exit}')
  echo "✅ IPv6 global present: $IPV6"
else
  echo "❌ No IPv6 global address on $LAN_IFACE"
fi

# Check for link-local (required for IPv6)
if check_link_local "$LAN_IFACE"; then
  LINK_LOCAL=$(ip -6 addr show dev "$LAN_IFACE" scope link | awk '/inet6 fe80/ {print $2; exit}')
  echo "✅ IPv6 link-local present: $LINK_LOCAL"
else
  echo "⚠️  No IPv6 link-local address on $LAN_IFACE (may be autoconfigured)"
fi

# Recover if IPv4 OR IPv6 global is missing (not only when both are gone)
if ! check_ipv4 "$LAN_IFACE" || ! check_ipv6 "$LAN_IFACE"; then
  echo
  echo "⚠️  ALERT: Interface $LAN_IFACE is missing IPv4 and/or IPv6 — triggering recovery"
  restart_services
fi

# --- System interface (source of truth) ---
SYS_IFACE="$LAN_IFACE"

# --- Read interfaces from configs ---
KEA4_IFACE=$(jq -r '.Dhcp4."interfaces-config".interfaces[0]' /etc/kea/kea-dhcp4.conf)
KEA6_IFACE=$(jq -r '.Dhcp6."interfaces-config".interfaces[0]' /etc/kea/kea-dhcp6.conf)
RADVD_IFACE=$(awk '/^interface[[:space:]]+/ {print $2; exit}' /etc/radvd.conf)
#NETPLAN_IFACE=$(yq -r '.network.ethernets | to_entries[] | select(.value.addresses) | .key' /etc/netplan/01-network-manager-all.yaml)
NETPLAN_IFACE=$(nmcli -t -f DEVICE,STATE device | awk -F: '$2=="connected"{print $1}' | grep -v '^eth0$')

echo "UDAY: $NETPLAN_IFACE"

# --- Sanity check ---
for v in SYS_IFACE KEA4_IFACE KEA6_IFACE RADVD_IFACE NETPLAN_IFACE; do
  if [[ -z "${!v}" || "${!v}" == "null" ]]; then
    echo "❌ $v is empty – aborting"
    exit 1
  fi
done

# --- Compare ---
if [[ "$SYS_IFACE" == "$KEA4_IFACE" &&
      "$SYS_IFACE" == "$KEA6_IFACE" &&
      "$SYS_IFACE" == "$RADVD_IFACE" &&
      "$SYS_IFACE" == "$NETPLAN_IFACE" ]]; then
  echo "✅ Interfaces already in sync ($SYS_IFACE). Nothing to do."
  exit 0
fi

echo "⚠️ Interface mismatch detected"
echo "SYS     : $SYS_IFACE"
echo "KEA4    : $KEA4_IFACE"
echo "KEA6    : $KEA6_IFACE"
echo "RADVD   : $RADVD_IFACE"
echo "NETPLAN : $NETPLAN_IFACE"

echo "🔧 Regenerating configs..."

# --- Trigger generators ---
./generate_netplan.sh
./generate_radvd.sh
./generate_kea_dhcp6.sh
./generate_kea_dhcp4.sh

echo "✅ Regeneration triggered due to interface mismatch"

echo "###############################################################"
