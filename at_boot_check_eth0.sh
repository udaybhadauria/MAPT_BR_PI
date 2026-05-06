#!/bin/bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0")"
BASE_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
LOG="$BASE_DIR/zboot_logs.log"
mkdir -p "$(dirname "$LOG")"
touch "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "###############################################################"
echo "Running script: $0"
echo "Date: $(date)"

IFACE="eth0"
VENV_DIR="${HOME:-/root}/ui_venv"

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
    echo "⚠️  No valid IP configuration detected. Restarting DHCP services..."
    echo "[*] Applying netplan..."
    netplan apply || true

    sleep 2

    for svc in kea-dhcp4-server kea-dhcp6-server radvd; do
        echo "[*] Restarting $svc..."
        systemctl restart "$svc" || echo "❌ Failed to restart $svc"
    done

    sleep 3
}

# Check if interface exists
if ! ip link show "$IFACE" >/dev/null 2>&1; then
    echo "❌ ERROR: Interface $IFACE does not exist"
    exit 1
fi

echo "🔍 Checking IP configuration on $IFACE..."

# Check for IPv4
if check_ipv4 "$IFACE"; then
    IPV4=$(ip -4 addr show dev "$IFACE" | awk '/inet / {print $2}')
    echo "✅ IPv4 present: $IPV4"
else
    echo "❌ No IPv4 address on $IFACE"
fi

# Check for IPv6 global
if check_ipv6 "$IFACE"; then
    IPV6=$(ip -6 addr show dev "$IFACE" scope global | awk '/inet6/ {print $2; exit}')
    echo "✅ IPv6 global present: $IPV6"
else
    echo "❌ No IPv6 global address on $IFACE"
fi

# Check for link-local (required for IPv6)
if check_link_local "$IFACE"; then
    LINK_LOCAL=$(ip -6 addr show dev "$IFACE" scope link | awk '/inet6 fe80/ {print $2; exit}')
    echo "✅ IPv6 link-local present: $LINK_LOCAL"
else
    echo "⚠️  No IPv6 link-local address on $IFACE (may be autoconfigured)"
fi

# Recover if IPv4 OR IPv6 global is missing (not only when both are gone)
if ! check_ipv4 "$IFACE" || ! check_ipv6 "$IFACE"; then
    echo
    echo "⚠️  ALERT: Interface $IFACE is missing IPv4 and/or IPv6 — triggering recovery"
    restart_services
fi

echo "###############################################################"
