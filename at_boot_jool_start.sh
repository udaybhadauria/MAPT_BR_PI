#!/bin/bash
#set -euo pipefail

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0")"
BASE_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
LOG="$BASE_DIR/zboot_logs.log"
mkdir -p "$(dirname "$LOG")"
touch "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "###############################################################"
echo "Running script: $0"
echo "Date: $(date)"

SCRIPT_DIR=$(dirname "$(realpath "$0")")
CONFIG="$SCRIPT_DIR/config_ui.json"

INSTANCE="BR"

# -------------------------------
# PRE-CHECKS
# -------------------------------
command -v jq >/dev/null || { echo "❌ jq not installed"; exit 1; }
command -v jool_mapt >/dev/null || { echo "❌ jool_mapt not installed"; exit 1; }
[[ -f "$CONFIG" ]] || { echo "❌ $CONFIG not found"; exit 1; }

# -------------------------------
# READ CONFIG VALUES
# -------------------------------
V6_RULE_PREFIX=$(jq -r '.s46.v6_rule_prefix' "$CONFIG")
V4_PREFIX=$(ip -4 addr show eth0 | awk '/inet / {print $2}' | cut -d/ -f1 | xargs)
#V4_PREFIX=$(jq -r '.s46.v4_prefix' "$CONFIG")
V4_PLEN=$(jq -r '.s46.v4_plen' "$CONFIG")
EA_LEN=$(jq -r '.s46.ea_len' "$CONFIG")
DMR=$(jq -r '.s46.dmr' "$CONFIG")

# -------------------------------
# DELETE EXISTING INSTANCE
# -------------------------------

sudo modprobe jool_common
sudo modprobe jool
sudo modprobe jool_mapt
sleep 1

# -------------------------------
# Add instance
# -------------------------------
echo "🔹 Creating JOOL instance $INSTANCE..."
jool_mapt instance add "$INSTANCE" --netfilter --dmr "$DMR"

# -------------------------------
# Add FMR rule
# -------------------------------
echo "🔹 Adding FMR rule..."
jool_mapt -i "$INSTANCE" fmrt add "$V6_RULE_PREFIX" "$V4_PREFIX/$V4_PLEN" "$EA_LEN" 4

# -------------------------------
# Set MAP-T type
# -------------------------------
echo "🔹 Setting MAP-T type..."
jool_mapt -i "$INSTANCE" global update map-t-type BR

# -------------------------------
# VALIDATION
# -------------------------------
echo "======================================="
echo "🩺 Validating JOOL FMR configuration..."

sleep 3

# Parse fmrt display, ignore headers

read CUR_V6 CUR_V4 CUR_EA CUR_A < <(
  jool_mapt -i "BR" fmrt display |
  awk -F'|' '/^\|/ {for(i=1;i<=NF;i++) gsub(/^ +| +$/, "", $i)} $2=="IPv6 Prefix"{next} $2!=""{print $2, $3, $4, $5; exit}'
)

# Compare values
errors=0

[[ "$CUR_V6" == "$V6_RULE_PREFIX" ]] || { echo "❌ IPv6 Prefix mismatch: expected $V6_RULE_PREFIX, got $CUR_V6"; errors=$((errors+1)); }
[[ "$CUR_V4" == "$V4_PREFIX/$V4_PLEN" ]] || { echo "❌ IPv4 Prefix mismatch: expected $V4_PREFIX/$V4_PLEN, got $CUR_V4"; errors=$((errors+1)); }
[[ "$CUR_EA" == "$EA_LEN" ]] || { echo "❌ EA-bits mismatch: expected $EA_LEN, got $CUR_EA"; errors=$((errors+1)); }
[[ "$CUR_A" == "4" ]] || { echo "❌ 'a' value mismatch: expected 4, got $CUR_A"; errors=$((errors+1)); }

if [[ $errors -eq 0 ]]; then
    echo "✅ JOOL FMR values match config_ui.json"
else
    echo "❌ Validation failed, see above errors"
    exit 1
fi

# Optional: show stats
echo "MAP-T stats:"
jool_mapt -i "$INSTANCE" stats display
echo "🎉 JOOL MAP-T configuration applied and validated successfully"

echo "###############################################################"
