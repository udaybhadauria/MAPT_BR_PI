#!/bin/bash
#set -e

echo "####################################"
echo "$(date)"
echo "####################################"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$BASE_DIR"

export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH

CONFIG_FILE="$1"

echo "Applying MAP-T configuration from $BASE_DIR"

bash "$BASE_DIR/generate_mac_ipv6.sh"

bash "$BASE_DIR/generate_config.sh"

bash "$BASE_DIR/generate_routes.sh"

bash "$BASE_DIR/jool_apply.sh"

#bash "$BASE_DIR/start_kea_services.sh"

bash "$BASE_DIR/return_policy.sh"

echo "✅ Apply completed"

echo "#########################################"
