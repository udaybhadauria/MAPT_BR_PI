import argparse
import ipaddress
import logging

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(levelname)s: %(message)s')

def calculate_ipv6_pd_and_full_address(v4_prefix, psid_len, v6_prefix, v4_suffix, psid):
    # Parse prefixes
    v4_network = ipaddress.IPv4Network(v4_prefix, strict=False)
    v6_network = ipaddress.IPv6Network(v6_prefix, strict=False)

    v4_prefix_len = v4_network.prefixlen
    v6_prefix_len = v6_network.prefixlen

    # Calculate lengths
    v4_suffix_len = 32 - v4_prefix_len
    ea_bits_len = v4_suffix_len + psid_len
    v6_pd_len = v6_prefix_len + ea_bits_len

    logging.info(f"IPv4 suffix length: {v4_suffix_len}, EA bits length: {ea_bits_len}, v6_pd_len: {v6_pd_len}")

    # Validate ranges
    if not (0 <= v4_suffix < 2 ** v4_suffix_len):
        raise ValueError(f"IPv4 suffix must be between 0 and {2 ** v4_suffix_len - 1}")
    if not (0 <= psid < 2 ** psid_len):
        raise ValueError(f"PSID must be between 0 and {2 ** psid_len - 1}")

    # EA bits
    ea_bits_value = (v4_suffix << psid_len) | psid
    ea_bits_bin = format(ea_bits_value, f'0{ea_bits_len}b')
    logging.info(f"EA bits -> Hex: {hex(ea_bits_value)}, Binary: {ea_bits_bin}")

    # IPv6 PD
    v6_prefix_bin = format(int(v6_network.network_address), '0128b')[:v6_prefix_len]
    v6_pd_bin = (v6_prefix_bin + ea_bits_bin).ljust(128, '0')
    v6_pd_address = ipaddress.IPv6Address(int(v6_pd_bin, 2))
    logging.info(f"IPv6 PD: {v6_pd_address}/{v6_pd_len}")

    # Full IPv6 address
    full_ipv6_bin = v6_prefix_bin + ea_bits_bin

    # Padding
    padding_len = 128 - v6_pd_len - 32 - 16
    if padding_len < 0:
        raise ValueError("Invalid configuration: padding length negative")
    logging.info(f"Calculated padding length: {padding_len} bits")

    full_ipv6_bin += '0' * padding_len

    # IPv4 address
    ipv4_full_int = int(ipaddress.IPv4Address(v4_network.network_address)) + v4_suffix
    ipv4_full_address = ipaddress.IPv4Address(ipv4_full_int)
    ipv4_bin = format(ipv4_full_int, '032b')
    full_ipv6_bin += ipv4_bin

    # PSID
    psid_bin = format(psid, '016b')
    full_ipv6_bin += psid_bin

    # Ensure 128 bits
    full_ipv6_bin = full_ipv6_bin[:128]
    full_ipv6_address = ipaddress.IPv6Address(int(full_ipv6_bin, 2))

    logging.info(f"Full IPv6 address: {full_ipv6_address}")
    logging.info(f"Full IPv4 address: {ipv4_full_address}")

    return f"{v6_pd_address}/{v6_pd_len}", str(full_ipv6_address), str(ipv4_full_address)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Calculate IPv6 PD and Full IPv6 Address based on MAP-T logic")
    parser.add_argument("--v4_prefix", required=True, help="IPv4 prefix in CIDR format (e.g., 192.0.2.0/24)")
    parser.add_argument("--psid_len", type=int, required=True, help="Length of PSID in bits")
    parser.add_argument("--v6_prefix", required=True, help="IPv6 prefix in CIDR format (e.g., 2001:db8::/48)")
    parser.add_argument("--v4_suffix", type=int, required=True, help="IPv4 suffix value")
    parser.add_argument("--psid", type=int, required=True, help="PSID value")

    args = parser.parse_args()

    ipv6_pd, full_ipv6, full_ipv4 = calculate_ipv6_pd_and_full_address(
        args.v4_prefix, args.psid_len, args.v6_prefix, args.v4_suffix, args.psid
    )

    print("IPv6 PD:", ipv6_pd)
    print("Full IPv6 Address:", full_ipv6)
    print("Full IPv4 Address:", full_ipv4)
