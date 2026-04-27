#!/bin/bash

# Interface
IFACE="enx00249b59bf67"

# Route and neighbor parameters
ROUTE="2600:8809:a504::/46"
NEIGH_IP="2600:8809:a505:91d0:0:c0a8:c64:1d"
NEIGH_MAC="1c:9e:cc:21:6d:f6"

echo "Checking rules... $(date)"

# --- CHECK + ADD ROUTE ---
if ip -6 route show | grep -q "$ROUTE"; then
    echo "Route already exists."
else
    echo "Adding route..."
    ip -6 route add $ROUTE dev $IFACE metric 1024 pref medium
fi

# --- CHECK + ADD NEIGHBOR ---
if ip -6 neigh show | grep -q "$NEIGH_IP"; then
    echo "Neighbor entry exists."
else
    echo "Adding neighbor entry..."
    ip -6 neigh add $NEIGH_IP dev $IFACE lladdr $NEIGH_MAC nud permanent
fi

echo "Done."
