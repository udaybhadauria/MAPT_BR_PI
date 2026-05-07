#!/bin/bash
set -e

SCRIPT_DIR=$(dirname "$(realpath "$0")")

################################
# INPUTS
################################

LAN_IF=$(ip -o link show | awk -F': ' '/: (enx|eth1)/ {print $2; exit}')
V6_RULE_PREFIX="2600:8809:a504::/46"
MAPPING_FILE="$SCRIPT_DIR/mac_ipv6_mapping.txt"

METRIC=1024
PREF="medium"

################################
# V4/V6 rules
################################

sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
sysctl -w net.ipv6.conf.eth0.forwarding=1 >/dev/null
sysctl -w net.ipv6.conf.eth0.accept_ra=2 >/dev/null
sysctl -w net.ipv6.conf.eth0.autoconf=1 >/dev/null


################################
# VALIDATION
################################

if [[ ! -f "$MAPPING_FILE" ]]; then
  echo "❌ Mapping file not found: $MAPPING_FILE"
  exit 1
fi

if [[ -z "$LAN_IF" ]]; then
  echo "❌ LAN interface not found (expected enx* or eth1)"
  exit 1
fi

################################
# INSTALL MAP-T ROUTE
################################

echo "Installing MAP-T IPv6 route..."
ip -6 route replace "$V6_RULE_PREFIX" dev "$LAN_IF" metric "$METRIC" pref "$PREF"

################################
# INSTALL NEIGHBORS
################################

echo "Flushing old permanent IPv6 neighbors on $LAN_IF (safe scope)..."
ip -6 neigh show dev "$LAN_IF" nud permanent | awk '{print $1}' | while read -r addr; do
  [[ -n "$addr" ]] && ip -6 neigh del "$addr" dev "$LAN_IF" 2>/dev/null || true
done

echo "Installing MAP-T neighbor entries..."

PROCESSED=0
while IFS="|" read -r MAC PSID V6_PREFIX MAPT_IPV6; do
  [[ -z "$MAC" ]] && continue
  [[ -z "$MAPT_IPV6" ]] && continue

  echo "  → $MAPT_IPV6 → $MAC"
  ip -6 neigh replace "$MAPT_IPV6" dev "$LAN_IF" lladdr "$MAC" nud permanent
  PROCESSED=$((PROCESSED + 1))
done < "$MAPPING_FILE"

################################
# STATUS
################################

COUNT=$PROCESSED
echo "✅ MAP-T kernel state installed"
echo "✅ Devices processed: $COUNT"
