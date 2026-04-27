#!/bin/bash
set -Eeuo pipefail
#
# IPv6 Router Watchdog for MAP-T BR
# - Uses link-local (fe80::) router for reachability
# - Re-applies MAP-T kernel state ONLY when router recovers
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATE_ROUTES_SCRIPT="$SCRIPT_DIR/generate_routes.sh"
RETURN_POLICY_SCRIPT="$SCRIPT_DIR/return_policy.sh"

NORMAL_INTERVAL=30

############################################
# Detect LAN interface (enx* or eth1)
############################################

LAN_IF=$(ip -o link show | awk -F': ' '$2 ~ /^(enx|eth1)/ {print $2; exit}')

if [[ -z "$LAN_IF" ]]; then
  echo "❌ ERROR: No LAN interface found"
  exit 1
fi

echo "✅ Using LAN interface: $LAN_IF"

############################################
# Functions
############################################

apply_kernel_sysctls() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
}

apply_network_state() {
  [[ -f "$GENERATE_ROUTES_SCRIPT" ]] || { echo "❌ Missing script: $GENERATE_ROUTES_SCRIPT"; return 1; }
  [[ -f "$RETURN_POLICY_SCRIPT" ]] || { echo "❌ Missing script: $RETURN_POLICY_SCRIPT"; return 1; }

  echo "⚙️  Running generate_routes.sh"
  bash "$GENERATE_ROUTES_SCRIPT"

  echo "⚙️  Running return_policy.sh"
  bash "$RETURN_POLICY_SCRIPT"

  echo "✅ MAP-T routes/neighbors and IPv6 return policy applied"
}

get_router_lladdr() {
  ip -6 neigh show dev "$LAN_IF" \
    | awk '/^fe80::/ && /router/ {print $1; exit}'
}

router_is_reachable() {
  local LL
  LL=$(get_router_lladdr)
  [[ -z "$LL" ]] && return 1
  ping6 -c 2 -W 2 "${LL}%${LAN_IF}" >/dev/null 2>&1
}

return_table_is_valid() {
  ip -6 route show table return 2>/dev/null | grep -q .
}

############################################
# Initial setup
############################################

apply_kernel_sysctls
apply_network_state

STATE="UP"

############################################
# Watchdog loop (OLD / QUIET)
############################################

while true; do
  if router_is_reachable; then
    if [[ "$STATE" == "DOWN" ]]; then
      echo "✅ Router reachable again — restoring MAP-T state + return policy"
      apply_network_state
      if return_table_is_valid; then
        echo "✅ Validated: 'ip -6 route show table return' has entries"
        STATE="UP"
      else
        echo "⚠️  WARNING: return table still empty after apply — will retry next cycle"
        # Stay in DOWN so recovery is retried
      fi
    else
      echo "✅ Router reachable"
      if ! return_table_is_valid; then
        echo "⚠️  WARNING: return table is empty while router is UP — re-applying network state"
        apply_network_state
        if return_table_is_valid; then
          echo "✅ Validated: return table restored"
        else
          echo "❌ ERROR: return table still empty after re-apply"
        fi
      fi
    fi
  else
    if [[ "$STATE" == "UP" ]]; then
      echo "❌ Router unreachable — entering DOWN state"
      STATE="DOWN"
    fi
    # Silent while DOWN
  fi

  sleep "$NORMAL_INTERVAL"
done
