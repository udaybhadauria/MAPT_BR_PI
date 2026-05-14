#!/bin/bash
set -Eeuo pipefail
#
# IPv6 Router Watchdog for MAP-T BR
# - Uses link-local (fe80::) router for reachability
# - Re-applies MAP-T kernel state ONLY when router recovers
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATE_ROUTES_SCRIPT="$SCRIPT_DIR/generate_routes.sh"
FETCH_ROUTER_IPV6_SCRIPT="$SCRIPT_DIR/fetch_router_ipv6.sh"
RETURN_POLICY_SCRIPT="$SCRIPT_DIR/return_policy.sh"
START_KEA_SERVICES_SCRIPT="$SCRIPT_DIR/start_kea_services.sh"

NORMAL_INTERVAL="${NORMAL_INTERVAL:-60}"
HEARTBEAT_CYCLES="${HEARTBEAT_CYCLES:-1}"

if ! [[ "$NORMAL_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
  echo "⚠️ Invalid NORMAL_INTERVAL='$NORMAL_INTERVAL' — using default 60"
  NORMAL_INTERVAL=60
fi

if ! [[ "$HEARTBEAT_CYCLES" =~ ^[1-9][0-9]*$ ]]; then
  echo "⚠️ Invalid HEARTBEAT_CYCLES='$HEARTBEAT_CYCLES' — using default 1"
  HEARTBEAT_CYCLES=1
fi

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

restart_network_services() {
  [[ -f "$START_KEA_SERVICES_SCRIPT" ]] || {
    echo "❌ Missing script: $START_KEA_SERVICES_SCRIPT"
    return 1
  }

  echo "⚙️  Running start_kea_services.sh"
  bash "$START_KEA_SERVICES_SCRIPT" || {
    echo "❌ start_kea_services.sh failed"
    return 1
  }
}

apply_network_state() {
  [[ -f "$GENERATE_ROUTES_SCRIPT" ]] || { echo "❌ Missing script: $GENERATE_ROUTES_SCRIPT"; return 1; }
  [[ -f "$FETCH_ROUTER_IPV6_SCRIPT" ]] || { echo "❌ Missing script: $FETCH_ROUTER_IPV6_SCRIPT"; return 1; }
  [[ -f "$RETURN_POLICY_SCRIPT" ]] || { echo "❌ Missing script: $RETURN_POLICY_SCRIPT"; return 1; }

  restart_network_services || return 1

  echo "⚙️  Running generate_routes.sh"
  bash "$GENERATE_ROUTES_SCRIPT" || {
    echo "❌ generate_routes.sh failed"
    return 1
  }

  echo "⚙️  Running fetch_router_ipv6.sh"
  bash "$FETCH_ROUTER_IPV6_SCRIPT" || {
    echo "❌ fetch_router_ipv6.sh failed"
    return 1
  }

  echo "⚙️  Running return_policy.sh"
  bash "$RETURN_POLICY_SCRIPT" || {
    echo "❌ return_policy.sh failed"
    return 1
  }

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
STATE="DOWN"

if router_is_reachable; then
  echo "✅ Router reachable at startup — attempting initial apply"
  if apply_network_state && return_table_is_valid; then
    echo "✅ Initial MAP-T state is valid"
    STATE="UP"
  else
    echo "⚠️  Initial apply incomplete; watchdog will retry on next cycle"
  fi
else
  echo "⚠️  Router unreachable at startup; waiting for recovery"
fi

############################################
# Watchdog loop (OLD / QUIET)
############################################

CYCLE=0
while true; do
  CYCLE=$((CYCLE + 1))

  if router_is_reachable; then
    if [[ "$STATE" == "DOWN" ]]; then
      echo "✅ Router reachable again — restoring MAP-T state + return policy"
      if apply_network_state && return_table_is_valid; then
        echo "✅ Validated: 'ip -6 route show table return' has entries"
        STATE="UP"
      else
        echo "⚠️  WARNING: apply failed or return table empty — will retry next cycle"
        # Stay in DOWN so recovery is retried
      fi
    else
      if ! return_table_is_valid; then
        echo "⚠️  WARNING: return table is empty while router is UP — re-applying network state"
        if apply_network_state && return_table_is_valid; then
          echo "✅ Validated: return table restored"
        else
          echo "❌ ERROR: return table still empty after re-apply"
          STATE="DOWN"
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

  if [[ "$STATE" == "UP" ]] && (( CYCLE % HEARTBEAT_CYCLES == 0 )); then
    if return_table_is_valid; then
      echo "ℹ️ Watchdog heartbeat: router UP, return table OK"
    else
      echo "⚠️ Watchdog heartbeat: router UP, return table MISSING"
    fi
  fi

  sleep "$NORMAL_INTERVAL"
done
