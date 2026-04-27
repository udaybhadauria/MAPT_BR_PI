#!/bin/bash

set -e

LOG="/root/BR_PI/zboot_logs.log"
exec > >(tee -a "$LOG") 2>&1

echo "###############################################################"
echo "Running script: $0"
echo "Date: $(date)"

# --- System interface (source of truth) ---
SYS_IFACE=$(ifconfig | awk -F: '/^(enx|eth1)/ {print $1; exit}')

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
