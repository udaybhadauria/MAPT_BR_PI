#!/bin/bash

SERVICES=(
  kea-dhcp6-server
  kea-dhcp4-server
  radvd
)

echo "Restarting network services..."
echo "--------------------------------"

FAILED=0

sudo netplan apply

for svc in "${SERVICES[@]}"; do
  echo "Restarting $svc ..."
  systemctl restart "$svc"

  sleep 1  # small grace period

  if systemctl is-active --quiet "$svc"; then
    echo "[OK] $svc is running"
  else
    echo "[FAIL] $svc is NOT running"
    FAILED=1
  fi
done

echo "--------------------------------"

if [ "$FAILED" -eq 0 ]; then
  echo "✅ All services restarted and running successfully."
  #exit 0
else
  echo "❌ One or more services failed to start."
  #exit 1
fi

ensure_single_masquerade_rule() {
    local cmd="$1"   # iptables or ip6tables
    local iface="$2" # e.g. eth0

    # Count existing rules
    local count
    count=$($cmd -t nat -S POSTROUTING \
        | grep -c -- "-o $iface -j MASQUERADE")

    if [ "$count" -eq 0 ]; then
        echo "➕ Adding MASQUERADE rule ($cmd, $iface)"
        $cmd -t nat -A POSTROUTING -o "$iface" -j MASQUERADE

    elif [ "$count" -gt 1 ]; then
        echo "🧹 Removing duplicate MASQUERADE rules ($cmd, $iface)"
        # Remove ALL
        while $cmd -t nat -C POSTROUTING -o "$iface" -j MASQUERADE 2>/dev/null; do
            $cmd -t nat -D POSTROUTING -o "$iface" -j MASQUERADE
        done
        # Add back ONE
        $cmd -t nat -A POSTROUTING -o "$iface" -j MASQUERADE

    else
        echo "✅ Single MASQUERADE rule already present ($cmd, $iface)"
    fi
}

WAN_IFACE="eth0"

#ensure_single_masquerade_rule iptables $WAN_IFACE
ensure_single_masquerade_rule ip6tables $WAN_IFACE

netfilter-persistent save

sudo netplan apply
