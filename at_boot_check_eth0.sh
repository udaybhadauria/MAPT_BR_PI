#!/bin/bash
# Script to ensure eth0 has a connection via nmcli

LOG="/root/BR_PI/zboot_logs.log"
exec > >(tee -a "$LOG") 2>&1

echo "###############################################################"
echo "Running script: $0"
echo "Date: $(date)"

# Interface to check
IFACE="eth0"

# Check if interface has an IPv4 or IPv6 address
IP_CHECK=$(ip addr show "$IFACE" | grep -E "inet |inet6 " | awk '{print $2}')

if [ -z "$IP_CHECK" ]; then
    echo "No IP found on $IFACE. Checking nmcli connection..."

    # Read existing connection name for this interface
    CON_NAME=$(nmcli -t -f NAME,DEVICE connection show --active | grep ":$IFACE" | cut -d: -f1)

    if [ -z "$CON_NAME" ]; then
        CON_NAME="netplan-eth0"
        echo "No active connection. Adding connection '$CON_NAME'..."
        nmcli connection add \
            type ethernet \
            ifname "$IFACE" \
            con-name "$CON_NAME" \
            ipv4.method auto \
            ipv6.method auto
    else
        echo "Connection '$CON_NAME' already exists."
    fi
else
    echo "$IFACE already has IP(s): $IP_CHECK"
fi

echo "###############################################################"
