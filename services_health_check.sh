#!/bin/bash
set -e

# Health check + self-heal for MAP-T BR services/network state.
# What this script does:
# 1) Verifies kea-dhcp4-server, kea-dhcp6-server, and radvd are active.
# 2) Restarts any failed service and validates it recovered.
# 3) Ensures IPv6 forwarding and interface RA/autoconf sysctls are set.
# 4) Validates MAP-T IPv6 route + neighbor entries (from mapping file).
# 5) Repairs broken MAP-T route/neighbor state via generate_routes.sh.
# 6) Validates IPv6 return table and repairs route/rule when missing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATE_ROUTES_SCRIPT="$SCRIPT_DIR/generate_routes.sh"
V6_RULE_PREFIX="2600:8809:a504::/46"
MAPPING_FILE="$SCRIPT_DIR/mac_ipv6_mapping.txt"

echo "🔍 Checking service status..."

restart_needed=0
IFACE=$(ifconfig | awk -F: '/^(enx|eth1)/ {print $1; exit}')

if [[ -z "$IFACE" ]]; then
  echo "❌ ERROR: No LAN interface found (expected enx* or eth1)"
  exit 1
fi

check_and_restart() {
    local svc="$1"

    if systemctl is-active --quiet "$svc"; then
        echo "✅ $svc is RUNNING"
    else
        echo "❌ $svc FAILED → restarting"
        sudo systemctl restart "$svc"
        sleep 2
        if systemctl is-active --quiet "$svc"; then
            echo "✅ $svc recovered successfully"
        else
            echo "❌ $svc still FAILED after restart"
            restart_needed=1
        fi
    fi
}

has_iface_ipv4() {
  local iface="$1"
  ip -4 addr show dev "$iface" 2>/dev/null | grep -q "inet "
}

has_iface_ipv6_global() {
  local iface="$1"
  ip -6 addr show dev "$iface" scope global 2>/dev/null | grep -q "inet6 "
}

report_iface_state() {
  local iface="$1"

  if has_iface_ipv4 "$iface"; then
    local ipv4
    ipv4=$(ip -4 addr show dev "$iface" | awk '/inet / {print $2; exit}')
    echo "✅ $iface IPv4 present: $ipv4"
  else
    echo "❌ $iface IPv4 missing"
  fi

  if has_iface_ipv6_global "$iface"; then
    local ipv6
    ipv6=$(ip -6 addr show dev "$iface" scope global | awk '/inet6/ {print $2; exit}')
    echo "✅ $iface IPv6 global present: $ipv6"
  else
    echo "❌ $iface IPv6 global missing"
  fi
}

recover_network_stack() {
  local reason="$1"
  echo "⚠️ $reason"

  # Enable RA acceptance on WAN interface so kernel can pick up upstream IPv6
  echo "🔧 Enabling accept_ra + autoconf on eth0"
  sudo sysctl -w net.ipv6.conf.eth0.accept_ra=2 >/dev/null || true
  sudo sysctl -w net.ipv6.conf.eth0.autoconf=1 >/dev/null || true

  echo "🔧 Running: netplan apply"
  sudo netplan apply || true

  sleep 3

  for svc in kea-dhcp4-server kea-dhcp6-server radvd; do
    echo "🔁 Restarting $svc"
    sudo systemctl restart "$svc" || true
  done

  sleep 5
}

iface_needs_recovery() {
  local iface="$1"
  # Recover if IPv4 OR IPv6 global is missing (not only when both are gone)
  ! has_iface_ipv4 "$iface" || ! has_iface_ipv6_global "$iface"
}

check_and_restart kea-dhcp4-server
check_and_restart kea-dhcp6-server
check_and_restart radvd

echo "---------------------------------------"
echo "🔁 Checking WAN/LAN IPv4/IPv6 state..."

echo "🔎 Pre-check eth0"
report_iface_state eth0

if [[ "$IFACE" != "eth0" ]]; then
  echo "🔎 Pre-check $IFACE"
  report_iface_state "$IFACE"
fi

NEEDS_RECOVERY=0
if iface_needs_recovery eth0; then
  NEEDS_RECOVERY=1
fi
if [[ "$IFACE" != "eth0" ]] && iface_needs_recovery "$IFACE"; then
  NEEDS_RECOVERY=1
fi

if [[ $NEEDS_RECOVERY -eq 1 ]]; then
  recover_network_stack "One or more interfaces missing IPv4 and/or IPv6 global"

  echo "🔎 Post-recovery eth0"
  report_iface_state eth0
  if iface_needs_recovery eth0; then
    restart_needed=1
  fi

  if [[ "$IFACE" != "eth0" ]]; then
    echo "🔎 Post-recovery $IFACE"
    report_iface_state "$IFACE"
    if iface_needs_recovery "$IFACE"; then
      restart_needed=1
    fi
  fi
fi

echo "---------------------------------------"
echo "🔁 Checking forwarding settings..."

# IPv6 forwarding
if [[ "$(sysctl -n net.ipv6.conf.all.forwarding)" != "1" ]]; then
    echo "⚠️ IPv6 forwarding disabled → enabling"
    echo 1 | sudo tee /proc/sys/net/ipv6/conf/all/forwarding >/dev/null
else
    echo "✅ IPv6 forwarding enabled"
fi

sudo sysctl -w net.ipv6.conf.${IFACE}.accept_ra=2
sudo sysctl -w net.ipv6.conf.${IFACE}.autoconf=1

echo "---------------------------------------"
echo "🔁 Checking MAP-T IPv6 route + neighbor table..."

mapt_route_is_valid() {
  ip -6 route show "$V6_RULE_PREFIX" dev "$IFACE" 2>/dev/null | grep -q "$V6_RULE_PREFIX"
}

mapt_neighbors_are_valid() {
  local MAC PSID V6_PREFIX MAPT_IPV6 line

  [[ -f "$MAPPING_FILE" ]] || return 1

  while IFS="|" read -r MAC PSID V6_PREFIX MAPT_IPV6; do
    [[ -z "$MAC" ]] && continue
    [[ -z "$MAPT_IPV6" ]] && continue

    line=$(ip -6 neigh show dev "$IFACE" to "$MAPT_IPV6" 2>/dev/null || true)
    [[ -n "$line" ]] || return 1

    if ! echo "$line" | tr '[:upper:]' '[:lower:]' | grep -q "lladdr $(echo "$MAC" | tr '[:upper:]' '[:lower:]')"; then
      return 1
    fi
  done < "$MAPPING_FILE"

  return 0
}

repair_mapt_state() {
  [[ -f "$GENERATE_ROUTES_SCRIPT" ]] || return 1
  echo "🔧 Running generate_routes.sh to repair MAP-T route + neighbors"
  bash "$GENERATE_ROUTES_SCRIPT"
}

if mapt_route_is_valid && mapt_neighbors_are_valid; then
  echo "✅ MAP-T route and neighbor table look valid"
else
  echo "❌ MAP-T route/neighbor validation failed — attempting repair"
  if repair_mapt_state && mapt_route_is_valid && mapt_neighbors_are_valid; then
    echo "✅ MAP-T route and neighbor table repaired successfully"
  else
    echo "❌ MAP-T route/neighbor repair FAILED"
    restart_needed=1
  fi
fi

echo "---------------------------------------"
echo "🔁 Checking IPv6 return routing table..."

return_table_is_valid() {
  local ROUTER_LL
  ROUTER_LL=$(get_router_ll_from_mapping)
  [[ -z "$ROUTER_LL" ]] && return 1
  ip -6 route show table return 2>/dev/null | grep -q "$ROUTER_LL"
}

get_router_ll_from_mapping() {
  local ROUTER_MAC
  ROUTER_MAC=$(awk -F'|' 'NR==1 {print tolower($1)}' "$MAPPING_FILE")
  [[ -z "$ROUTER_MAC" ]] && return 1

  ip -6 neigh show dev "$IFACE" \
    | awk -v mac="$ROUTER_MAC" 'tolower($0) ~ mac && /^fe80::/ {print $1; exit}'
}

repair_return_table() {
  local ROUTER_LL
  ROUTER_LL=$(get_router_ll_from_mapping)
  if [[ -z "$ROUTER_LL" ]]; then
    echo "❌ Cannot repair return table — no router link-local found from mapping on $IFACE"
    return 1
  fi
  echo "🔧 Adding default route via $ROUTER_LL dev $IFACE table return"
  sudo ip -6 route replace default via "$ROUTER_LL" dev "$IFACE" table return
  # Ensure policy rule exists
  if ! ip -6 rule show | grep -q "lookup return"; then
    echo "🔧 Adding IPv6 policy rule: iif eth0 → table return"
    sudo ip -6 rule add iif eth0 table return
  fi
}

if return_table_is_valid; then
  echo "✅ IPv6 return table has valid entry for router link-local"
else
  echo "❌ IPv6 return table missing router link-local entry — attempting repair"
  if repair_return_table && return_table_is_valid; then
    echo "✅ IPv6 return table repaired successfully"
  else
    echo "❌ IPv6 return table repair FAILED"
    restart_needed=1
  fi
fi

echo "---------------------------------------"

if [[ $restart_needed -eq 1 ]]; then
    echo "♻️ One or more services were restarted"
else
    echo "🎉 All services healthy"
fi
