#!/bin/bash
set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0")"
BASE_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

############################################
# CONFIG
############################################
MAP_FILE="$BASE_DIR/mac_ipv6_mapping.txt"
WAN_IF="eth0"
TABLE_ID="252"
TABLE_NAME="return"
RT_TABLE_FILE="/etc/iproute2/rt_tables"

############################################
# Helpers
############################################
log() { echo "✅ $*"; }
err() { echo "❌ ERROR: $*" >&2; exit 1; }

############################################
# Detect LAN interface
############################################
LAN_IF=$(ip -o link show | awk -F': ' '/: (enx|eth1)/ {print $2; exit}')
[[ -n "$LAN_IF" ]] || err "LAN interface not found (enx* or eth1 expected)"
log "LAN interface: $LAN_IF"

############################################
# CLEANUP: remove route + rule
############################################

log "Removing IPv6 default route from table '$TABLE_NAME' (if any)"
ip -6 route del default table "$TABLE_NAME" 2>/dev/null || true

log "Removing IPv6 policy rule for table '$TABLE_NAME' (if any)"
while ip -6 rule del iif "$WAN_IF" lookup "$TABLE_NAME" 2>/dev/null; do :; done

############################################
# Confirm cleanup
############################################

if ip -6 route show table "$TABLE_NAME" | grep -q .; then
  err "IPv6 route still present in table $TABLE_NAME"
else
  log "IPv6 route table '$TABLE_NAME' is clean"
fi

if ip -6 rule show | grep -qE "iif $WAN_IF.*lookup ($TABLE_NAME|$TABLE_ID)"; then
  err "IPv6 policy rule still present"
else
  log "IPv6 policy rule successfully removed"
fi

############################################
# Validate mapping file
############################################
[[ -f "$MAP_FILE" ]] || err "Mapping file not found: $MAP_FILE"

MAC=$(awk -F'|' 'NR==1 {print tolower($1)}' "$MAP_FILE")
[[ -n "$MAC" ]] || err "MAC not found in mapping file"
log "Router MAC: $MAC"

############################################
# Discover router IPv6 link‑local
############################################
GW_LL=$(ip -6 neigh show dev "$LAN_IF" |
  awk -v mac="$MAC" 'tolower($0) ~ mac && /^fe80::/ {print $1; exit}'
)

[[ -n "$GW_LL" ]] || err "No link‑local IPv6 neighbor found for MAC $MAC"
log "Router IPv6 link‑local: $GW_LL"

############################################
# Ensure routing table registration
############################################
if ! grep -qE "^[[:space:]]*$TABLE_ID[[:space:]]+$TABLE_NAME$" "$RT_TABLE_FILE"; then
  log "Registering routing table $TABLE_ID ($TABLE_NAME)"
  echo "$TABLE_ID $TABLE_NAME" >> "$RT_TABLE_FILE"
else
  log "Routing table already registered"
fi

############################################
# Ensure neighbor reachability (CRITICAL)
############################################
if ! ip -6 neigh show dev "$LAN_IF" | grep -q "$GW_LL"; then
  log "Probing gateway neighbor (NDP)"
  ping6 -c 1 "$GW_LL%$LAN_IF" >/dev/null || err "Gateway $GW_LL unreachable on $LAN_IF"
fi

############################################
# Add IPv6 policy rule (single instance)
############################################
log "Adding IPv6 policy rule: iif $WAN_IF → table $TABLE_NAME"
ip -6 rule add iif "$WAN_IF" table "$TABLE_NAME"

############################################
# Add IPv6 default route
############################################
log "Adding IPv6 default route via $GW_LL (table $TABLE_NAME)"
ip -6 route replace default via "$GW_LL" dev "$LAN_IF" table "$TABLE_NAME"

############################################
# Final validation
############################################
echo
echo "===== IPv6 POLICY RULES ====="
ip -6 rule show

echo
echo "===== IPv6 ROUTES (table $TABLE_NAME) ====="
ip -6 route show table "$TABLE_NAME"

echo
log "IPv6 return‑path policy routing configured successfully"
