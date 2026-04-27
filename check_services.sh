#!/bin/bash

timestamp=$(date +%s)

cat <<EOF > services_status.json
{
  "timestamp": $timestamp,
  "services": {
    "dhcp4": "$(systemctl is-active kea-dhcp4-server)",
    "dhcp6": "$(systemctl is-active kea-dhcp6-server)",
    "radvd": "$(systemctl is-active radvd)",
    "jool": "$(jool_mapt instance display | grep -qw BR && echo "active" || echo "inactive")"
  }
}
EOF
