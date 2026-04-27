#!/bin/bash
set -e

# Load system/policy configuration
source ./data.sh
CONFIG="config_ui.json"

#V4_Prefix=$(ip -4 addr show eth0 | awk '/inet / {print $2}' | cut -d/ -f1)
V4_Prefix=$(ip -4 addr show eth0 | awk '/inet / {print $2}' | cut -d/ -f1 | sed 's/\.[0-9]\+$/\.0/')

mkdir -p "$KEA_DIR" "$LOG_DIR"

# --- Sanity checks ---
command -v jq >/dev/null || {
  echo "❌ jq is required but not installed"
  exit 1
}

[[ -n "$LAN_IF" ]] || {
  echo "❌ LAN interface not detected"
  exit 1
}

#################################
# BUILD DHCPv6 RESERVATIONS
#################################

DEVICE_COUNT=$(jq '.devices | length' "$CONFIG")
RESERVATIONS=""

if [[ "$DEVICE_COUNT" -eq 0 ]]; then
  echo "⚠️ WARNING: No devices defined in config_ui.json"
fi

for ((i=0; i<DEVICE_COUNT; i++)); do
  MAC=$(jq -r ".devices[$i].mac" "$CONFIG")
  PSID=$(jq -r ".devices[$i].psid" "$CONFIG")
  PSID_LEN=$(jq -r ".devices[$i].psid_len" "$CONFIG")
  PREFIX6=$(jq -r ".devices[$i].v6_prefix" "$CONFIG")

  RESERVATIONS+=$(cat <<EOF
          {
            "hw-address": "$MAC",
            "prefixes": ["$PREFIX6"],
            "option-data": [
              { "name": "s46-cont-mapt" },
              {
                "space": "s46-cont-mapt-options",
                "name": "s46-rule",
                "data": "0, $EA_LEN, $V4_PLEN, $V4_Prefix, $V6_RULE_PREFIX"
              },
              {
                "space": "s46-cont-mapt-options",
                "name": "s46-dmr",
                "data": "$DMR"
              },
              {
                "space": "s46-rule-options",
                "name": "s46-portparams",
                "data": "4, $PSID/$PSID_LEN"
              }
            ]
          }$( [[ $i -lt $((DEVICE_COUNT-1)) ]] && echo "," )
EOF
)
done

#################################
# WRITE kea-dhcp4.conf
#################################

cat > "$KEA_DIR/kea-dhcp4.conf" <<EOF
{
  "Dhcp4": {
    "interfaces-config": {
      "interfaces": [
        "$LAN_IF"
      ]
    },
    "lease-database": {
      "type": "memfile",
      "persist": true,
      "name": "/var/lib/kea/dhcp4.leases"
    },
    "subnet4": [
      {
        "id": 1,
        "subnet": "$DHCP4_SUBNET",
        "interface": "$LAN_IF",
        "pools": [
          {
            "pool": "$DHCP4_POOL_START - $DHCP4_POOL_END"
          }
        ],
        "option-data": [
          {
            "name": "routers",
            "data": "$DHCP4_ROUTER"
          },
          {
            "name": "domain-name-servers",
            "data": "$DHCP4_DNS"
          }
        ]
      }
    ],
    "valid-lifetime": $DHCP4_VALID,
    "renew-timer": $DHCP4_RENEW,
    "rebind-timer": $DHCP4_REBIND,
    "loggers": [
      {
        "name": "kea-dhcp4",
        "output_options": [
          {
            "output": "$LOG_DIR/kea-dhcp4.log"
          }
        ],
        "severity": "INFO"
      }
    ]
  }
}
EOF

#################################
# WRITE kea-dhcp6.conf
#################################

cat > "$KEA_DIR/kea-dhcp6.conf" <<EOF
{
  "Dhcp6": {
    "interfaces-config": {
      "interfaces": [
        "$LAN_IF"
      ]
    },
    "lease-database": {
      "type": "memfile",
      "persist": true,
      "name": "/var/lib/kea/dhcp6.leases"
    },
    "subnet6": [
      {
        "id": 1,
        "subnet": "$DHCP6_SUBNET",
        "interface": "$LAN_IF",
        "pools": [
          {
            "pool": "$DHCP6_POOL_START - $DHCP6_POOL_END"
          }
        ],
        "option-data": [
          {
            "name": "dns-servers",
            "data": "$DHCP6_DNS"
          }
        ],
        "preferred-lifetime": $DHCP6_PREF,
        "valid-lifetime": $DHCP6_VALID,
        "renew-timer": $DHCP6_RENEW,
        "rebind-timer": $DHCP6_REBIND,
        "reservations": [
$RESERVATIONS
        ]
      }
    ],
    "loggers": [
      {
        "name": "kea-dhcp6",
        "output_options": [
          {
            "output": "$LOG_DIR/kea-dhcp6.log",
            "maxsize": 1048576,
            "maxver": 3
          }
        ],
        "severity": "DEBUG",
        "debuglevel": 99
      }
    ]
  }
}
EOF

#################################
# WRITE radvd.conf
#################################

cat > "$RADVD_FILE" <<EOF
interface $LAN_IF {
    AdvSendAdvert on;
    AdvManagedFlag on;         # Tell client to use DHCPv6
    AdvOtherConfigFlag on;
    AdvDefaultLifetime 1800;   # MUST be non-zero

    prefix $RADVD_PREFIX {
        AdvOnLink on;
        AdvAutonomous off;     # <-- DISABLE SLAAC

        AdvValidLifetime 604800;
        AdvPreferredLifetime 604800;
    };
};
EOF

#################################
# WRITE netplan
#################################

cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  renderer: NetworkManager

  ethernets:
    $WAN_IF:
      dhcp4: $WAN_DHCP4
      dhcp6: $WAN_DHCP6
      accept-ra: $WAN_RA

    $LAN_IF:
      dhcp4: false
      dhcp6: false
      addresses:
        - $LAN_IPV4
        - $LAN_IPV6
EOF

echo "✅ All BR_PI configs generated successfully"


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

#ensure_single_masquerade_rule iptables eth0

#BR needs only IPv6 NAT Rule
ensure_single_masquerade_rule ip6tables $WAN_IF

#Starting Service after config apply

sudo netplan apply
sudo systemctl restart kea-dhcp4-server
sudo systemctl restart kea-dhcp6-server
sudo systemctl restart radvd

#Validating if services are started

systemctl is-active --quiet kea-dhcp4-server && echo "✅ kea-dhcp4-server is RUNNING" || echo "❌ kea-dhcp4-server FAILED"
systemctl is-active --quiet kea-dhcp6-server && echo "✅ kea-dhcp6-server is RUNNING" || echo "❌ kea-dhcp6-server FAILED"
systemctl is-active --quiet radvd && echo "✅ radvd is RUNNING" || echo "❌ radvd FAILED"

