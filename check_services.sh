#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

restart_if_down() {
  local svc="$1"
  if ! systemctl is-active --quiet "$svc"; then
    echo "[$(date)] ⚠️ $svc is DOWN — restarting"
    sudo systemctl restart "$svc" || true
    sleep 2
    if systemctl is-active --quiet "$svc"; then
      echo "[$(date)] ✅ $svc recovered"
    else
      echo "[$(date)] ❌ $svc still down after restart"
    fi
  fi
}

restart_if_down kea-dhcp4-server
restart_if_down kea-dhcp6-server
restart_if_down radvd

timestamp=$(date +%s)

cat <<EOF > "$SCRIPT_DIR/services_status.json"
{
  "timestamp": $timestamp,
  "services": {
    "dhcp4": "$(systemctl is-active kea-dhcp4-server)",
    "dhcp6": "$(systemctl is-active kea-dhcp6-server)",
    "radvd": "$(systemctl is-active radvd)",
    "jool": "$(jool_mapt instance display 2>/dev/null | grep -qw BR && echo "active" || echo "inactive")"
  }
}
EOF
