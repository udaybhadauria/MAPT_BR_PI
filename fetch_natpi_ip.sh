#!/bin/bash
set -e

# Fetch the first global IPv6 address assigned to eth0
IP=$(ip -6 -o addr show dev eth0 scope global \
     | awk '/inet6/ {print $4}' \
     | cut -d/ -f1 \
     | head -n 1)

if [[ -z "$IP" ]]; then
  echo "❌ No IPv6 address found on eth0" >&2
  exit 1
fi

# Replace last hextet with 1
ROUTER_IP=$(echo "$IP" | sed 's/:[^:]*$/:1/')

echo "$ROUTER_IP"

