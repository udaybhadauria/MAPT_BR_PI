#!/bin/bash
set -euo pipefail

MAP_FILE="mac_ipv6_mapping.txt"

# Detect LAN interface (enx* or eth1)
IFACE=$(ip -o link show | awk -F': ' '$2 ~ /^(enx|eth1)/ {print $2; exit}')
[[ -n "${IFACE:-}" ]] || { echo "ERROR: LAN interface not found (enx* or eth1)" >&2; exit 1; }

[[ -f "$MAP_FILE" ]] || { echo "ERROR: Mapping file not found: $MAP_FILE" >&2; exit 1; }

# Router MAC from mapping file (first field)
MAC=$(awk -F'|' 'NR==1 {print tolower($1)}' "$MAP_FILE")
[[ -n "${MAC:-}" ]] || { echo "ERROR: Router MAC missing in $MAP_FILE" >&2; exit 1; }

# Find first non-link-local IPv6 neighbor for this MAC.
ROUTER_V6=$(ip -6 neigh show dev "$IFACE" \
  | awk -v mac="$MAC" '
      tolower($0) ~ mac && $1 !~ /^fe80::/ {print $1; exit}
    ')

if [[ -n "${ROUTER_V6:-}" ]]; then
  echo "$ROUTER_V6"
else
  echo "ERROR: No non-link-local IPv6 neighbor found for MAC $MAC on $IFACE" >&2
  exit 1
fi
