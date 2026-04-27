#!/bin/bash
set -euo pipefail

LOG="/root/BR_PI/zboot_logs.log"
exec > >(tee -a "$LOG") 2>&1

echo "###############################################################"
echo "Running script: $0"
echo "Date: $(date)"

########################################
# Script to ensure eth0 has a connection via nmcli
########################################
# Interface to check
WANIFACE="eth0"

# Check if interface has an IPv4 or IPv6 address
IP_CHECK=$(ip addr show "$WANIFACE" | grep -E "inet |inet6 " | awk '{print $2}')

if [ -z "$IP_CHECK" ]; then
    echo "No IP found on $WANIFACE. Checking nmcli connection..."

    # Read existing connection name for this interface
    CON_NAME=$(nmcli -t -f NAME,DEVICE connection show --active | grep ":$WANIFACE" | cut -d: -f1)

    if [ -z "$CON_NAME" ]; then
        CON_NAME="netplan-eth0"
        echo "No active connection. Adding connection '$CON_NAME'..."
        nmcli connection add \
            type ethernet \
            ifname "$WANIFACE" \
            con-name "$CON_NAME" \
            ipv4.method auto \
            ipv6.method auto
    else
        echo "Connection '$CON_NAME' already exists."
    fi
else
    echo "$WANIFACE already has IP(s): $IP_CHECK"
fi

########################################

echo "======================================"
echo "$(date) 🚀 Boot service initialization started"
echo "======================================"

########################################
# Helper: restart + verify systemd unit
########################################
restart_and_check() {
  local svc="$1"

  echo "🔁 Restarting $svc"
  systemctl restart "$svc"

  echo "⏳ Waiting for $svc to become active"
  for i in {1..10}; do
    if systemctl is-active --quiet "$svc"; then
      echo "✅ $svc is active"
      return 0
    fi
    sleep 1
  done

  echo "❌ $svc failed to start"
  systemctl status "$svc" --no-pager
  exit 1
}

########################################
# Network first (very important order)
########################################
restart_and_check NetworkManager

echo "🌐 Applying netplan"
netplan generate
netplan apply

# Give kernel + NM time to settle routes & RAs
sleep 5

########################################
# DHCP servers
########################################
restart_and_check kea-dhcp4-server
restart_and_check kea-dhcp6-server

########################################
# Router advertisements
########################################
restart_and_check radvd

# --------------------------------------
echo "Checking service status..."
systemctl is-active --quiet kea-dhcp4-server && echo "✅ kea-dhcp4-server is RUNNING" || echo "❌ kea-dhcp4-server FAILED"
systemctl is-active --quiet kea-dhcp6-server && echo "✅ kea-dhcp6-server is RUNNING" || echo "❌ kea-dhcp6-server FAILED"
systemctl is-active --quiet radvd && echo "✅ radvd is RUNNING" || echo "❌ radvd FAILED"

sleep 2

########################################
# Validate IPv4 + IPv6 on interfaces
########################################
IFACE=$(ifconfig | awk -F: '/^(enx|eth1)/ {print $1; exit}')

check_interface_addrs() {
  local iface="$1"
  echo "🔍 Validating addresses on $iface"

  IPV4=$(ip -4 addr show dev "$iface" | awk '/inet / {print $2}')
  IPV6_LL=$(ip -6 addr show dev "$iface" scope link | awk '/inet6/ {print $2}')
  IPV6_G=$(ip -6 addr show dev "$iface" scope global | awk '/inet6/ {print $2}')

  if [[ -z "$IPV4" ]]; then
    echo "❌ $iface missing IPv4 address"
    return 1
  fi

  if [[ -z "$IPV6_LL" ]]; then
    echo "❌ $iface missing IPv6 link-local address"
    return 1
  fi

  if [[ -z "$IPV6_G" ]]; then
    echo "❌ $iface missing IPv6 global address"
    return 1
  fi

  echo "✅ $iface OK"
  echo "   IPv4 : $IPV4"
  echo "   IPv6 LL : $IPV6_LL"
  echo "   IPv6 G  : $IPV6_G"

  return 0
}

########################################
# Run validations
########################################
check_interface_addrs eth0 || exit 1
check_interface_addrs "$IFACE" || exit 1

echo "###############################################################"
