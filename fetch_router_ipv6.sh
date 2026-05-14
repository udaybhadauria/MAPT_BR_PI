#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILE="$SCRIPT_DIR/mac_ipv6_mapping.txt"

# Get local interface (enx* or eth1 — first match)
IFACE=$(ifconfig | awk -F: '/^(enx|eth1)/ {print $1; exit}')

# Extract MAC (first field before |)
MAC=$(awk -F'|' 'NR==1 {print $1}' "$FILE")
[[ -n "${MAC:-}" ]] || { echo "ERROR: Router MAC missing in $FILE"; exit 1; }

# Find matching fe80 address in neighbor table
LL_ADDR=$(ip -6 neigh show dev "$IFACE" | \
          awk -v mac="$MAC" '
              tolower($0) ~ tolower(mac) && /^fe80::/ {print $1; exit}
          ')

# Output
if [[ -n "$LL_ADDR" ]]; then
    echo "${LL_ADDR}%${IFACE}"
else
    echo "No matching fe80 neighbor for MAC $MAC on $IFACE"
    exit 1
fi

ping6 -c 4 "${LL_ADDR}%${IFACE}"
if [ $? -ne 0 ]; then
    echo "❌ Neighbor ${LL_ADDR}%${IFACE} not reachable — aborting"
    exit 1
fi
echo "✅ Neighbor reachable, proceeding..."
