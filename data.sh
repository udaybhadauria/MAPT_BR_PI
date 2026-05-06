#!/bin/bash
# System / policy configuration for generate_config.sh

#################################
# PATHS
#################################

export KEA_DIR="/etc/kea"
export NETPLAN_FILE="/etc/netplan/01-network-manager-all.yaml"
export RADVD_FILE="/etc/radvd.conf"
export LOG_DIR="/var/log/kea"

#################################
# INTERFACES
#################################

# LAN: auto-detect enx* or eth1
export LAN_IF=$(ifconfig | awk -F: '/^(enx|eth1)/ {print $1; exit}')

# WAN: fixed
export WAN_IF="eth0"

#################################
# LAN ADDRESSES
#################################

export LAN_IPV4="192.168.7.1/24"
export LAN_IPV6="fd12:3456:789a::1/64"

#################################
# DHCPv4
#################################

export DHCP4_SUBNET="192.168.7.0/24"
export DHCP4_POOL_START="192.168.7.100"
export DHCP4_POOL_END="192.168.7.200"
export DHCP4_ROUTER="192.168.7.1"
export DHCP4_DNS="8.8.8.8,9.9.9.9"

export DHCP4_VALID=604800
export DHCP4_RENEW=300
export DHCP4_REBIND=600

#################################
# DHCPv6
#################################

export DHCP6_SUBNET="fd12:3456:789a::/60"
export DHCP6_POOL_START="fd12:3456:789a::150"
export DHCP6_POOL_END="fd12:3456:789a::200"
export DHCP6_DNS="2001:4860:4860::8888,2001:4860:4860::8844"

export DHCP6_VALID=604800
export DHCP6_PREF=604800
export DHCP6_RENEW=518400
export DHCP6_REBIND=604800

#################################
# MAP‑T (S46) – SYSTEM OWNED
#################################

# Shared IPv4 address (host form)
export V4_ADDR="192.168.12.100"
export V4_PLEN=24

# Derived IPv4 network
export V4_PREFIX="${V4_ADDR%.*}.0"

# EA bits
export EA_LEN=14

# MAP‑T IPv6 rule prefix
export V6_RULE_PREFIX="2600:8809:a504::/46"

# Default Mapping Rule (DMR)
export DMR="2600:8809:bfff:ffff::/64"



export WAN_DHCP4=true
export WAN_DHCP6=true
export WAN_RA=true

export RADVD_PREFIX="fd12:3456:789a::/64"
