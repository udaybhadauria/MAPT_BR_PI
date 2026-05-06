#!/bin/bash

IFACE=$(ifconfig | awk -F: '/^(enx|eth1)/ {print $1; exit}')

# Check physical link first
if [ "$(cat /sys/class/net/$IFACE/carrier)" -eq 0 ]; then
    echo "No carrier on $IFACE — cable/device issue"
    exit 1
fi

IP_CHECK=$(ip -4 addr show "$IFACE" | grep inet)

if [ -z "$IP_CHECK" ]; then
    echo "No IP found on $IFACE"

    CON_NAME=$(nmcli -t -f NAME,DEVICE connection show | \
               grep ":$IFACE" | cut -d: -f1)

    if [ -z "$CON_NAME" ]; then
        CON_NAME="$IFACE-auto"
        echo "Creating connection $CON_NAME"

        nmcli connection add \
            type ethernet \
            ifname "$IFACE" \
            con-name "$CON_NAME" \
            ipv4.method auto \
            ipv6.method auto
    fi

    nmcli connection up "$CON_NAME"

else
    echo "$IFACE already has IP"
fi
