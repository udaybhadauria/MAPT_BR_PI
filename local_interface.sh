#!/bin/bash

# ------------------- Detect interfaces -------------------
# Try ENX interfaces first
mapfile -t IFACE < <(ls /sys/class/net | grep '^enx' | sort)

# If no ENX found, fallback to eth interfaces
if [ ${#IFACE[@]} -eq 0 ]; then
    mapfile -t ETH_INTERFACES < <(ls /sys/class/net | grep '^eth' | sort)
    if [ ${#ETH_INTERFACES[@]} -ge 2 ]; then
        # pick eth1 as fallback
        IFACE=("${ETH_INTERFACES[1]}")
    elif [ ${#ETH_INTERFACES[@]} -eq 1 ]; then
        IFACE=("${ETH_INTERFACES[0]}")
    else
        echo "ERROR: No suitable network interface found"
        exit 1
    fi
fi

echo "${IFACE[*]}"
