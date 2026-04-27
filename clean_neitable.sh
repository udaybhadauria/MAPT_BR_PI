#!/usr/bin/env bash
set -euo pipefail

# Detect enx* interfaces
IFACE=$(ifconfig | awk -F: '/^(enx|eth1)/ {print $1; exit}')

if [ -z "$IFACE" ]; then
    echo "No enx* interface found"
    exit 0
fi

cleanup_neigh() {
    local DEV="$1"

    echo "🔍 Cleaning IPv6 neighbors on $DEV"

    ip -6 neigh show dev "$DEV" \
    | awk '$2=="FAILED" || $2=="INCOMPLETE" {print $1}' \
    | while read -r IP; do
        echo "  deleting $IP on $DEV"
        ip -6 neigh del "$IP" dev "$DEV" 2>/dev/null || true
    done
}

# Cleanup enx*/eth1 interface
cleanup_neigh "$IFACE"

# Cleanup eth0 as well
cleanup_neigh "eth0"

echo "IPv6 neighbor cleanup complete."
