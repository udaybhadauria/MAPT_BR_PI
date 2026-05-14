#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_SH="$SCRIPT_DIR/data.sh"
REBUILD_SH="$SCRIPT_DIR/rebuild_jool.sh"
REBUILD_LOCK="/tmp/jool_rebuild.lock"

[[ -f "$DATA_SH" ]] || { echo "❌ $DATA_SH not found"; exit 1; }
source "$DATA_SH"
[[ -f "$REBUILD_SH" ]] || { echo "❌ $REBUILD_SH not found"; exit 1; }

############################################
# EXPECTED CONFIG
############################################

INSTANCE="BR"

EXP_V6="${V6_RULE_PREFIX:-}"
EXP_V4="${V4_PREFIX:-}/${V4_PLEN:-}"
EXP_EA="${EA_LEN:-}"
EXP_A="4"
EXP_DMR="${DMR:-}"

[[ -n "$EXP_V6" && "$EXP_V6" != "null" ]] || { echo "❌ Invalid V6_RULE_PREFIX from data.sh: $EXP_V6"; exit 1; }
[[ -n "${V4_PREFIX:-}" && "${V4_PREFIX:-}" != "null" ]] || { echo "❌ Invalid V4_PREFIX from data.sh: ${V4_PREFIX:-}"; exit 1; }
[[ -n "${V4_PLEN:-}" && "${V4_PLEN:-}" != "null" ]] || { echo "❌ Invalid V4_PLEN from data.sh: ${V4_PLEN:-}"; exit 1; }
[[ -n "$EXP_EA" && "$EXP_EA" != "null" ]] || { echo "❌ Invalid EA_LEN from data.sh: $EXP_EA"; exit 1; }
[[ -n "$EXP_DMR" && "$EXP_DMR" != "null" ]] || { echo "❌ Invalid DMR from data.sh: $EXP_DMR"; exit 1; }

echo "🩺 Validating JOOL MAP-T configuration..."

############################################
# Helpers
############################################

module_loaded() {
  lsmod | awk '{print $1}' | grep -qx "$1"
}

module_matches_running_kernel() {
  local module="$1"
  local kver
  local vermagic

  kver="$(uname -r)"
  vermagic="$(modinfo -F vermagic "$module" 2>/dev/null | head -n1 || true)"

  [[ -n "$vermagic" ]] && [[ "$vermagic" == "$kver"* ]]
}

wait_for_rebuild_lock() {
  local waited=0
  local max_wait=600

  while [[ -d "$REBUILD_LOCK" ]] && [[ "$waited" -lt "$max_wait" ]]; do
    echo "⏳ Waiting for ongoing JOOL rebuild lock to clear... (${waited}s/${max_wait}s)"
    sleep 5
    waited=$((waited + 5))
  done

  if [[ -d "$REBUILD_LOCK" ]]; then
    echo "❌ Timed out waiting for JOOL rebuild lock: $REBUILD_LOCK"
    exit 1
  fi
}

ensure_kernel_compatible_modules() {
  local required_modules=(jool_common jool jool_mapt)
  local mismatch=0

  echo "🔎 Checking JOOL module/kernel compatibility..."
  for module in "${required_modules[@]}"; do
    if module_matches_running_kernel "$module"; then
      echo "✅ $module matches running kernel $(uname -r)"
    else
      echo "⚠️  Kernel mismatch or missing module metadata for: $module"
      mismatch=1
    fi
  done

  if [[ "$mismatch" -eq 0 ]]; then
    return 0
  fi

  if mkdir "$REBUILD_LOCK" 2>/dev/null; then
    trap 'rmdir "$REBUILD_LOCK" >/dev/null 2>&1 || true' EXIT
    echo "🛠 Kernel mismatch detected. Rebuilding JOOL modules..."
    bash "$REBUILD_SH"
    rmdir "$REBUILD_LOCK" >/dev/null 2>&1 || true
    trap - EXIT
  else
    wait_for_rebuild_lock
  fi

  for module in "${required_modules[@]}"; do
    if ! module_matches_running_kernel "$module"; then
      echo "❌ $module still mismatched after rebuild"
      exit 1
    fi
  done

  echo "✅ JOOL modules now match running kernel"
}

ensure_modules() {
  local required_modules=(jool jool_mapt jool_common)
  local need_load=0

  echo "🔎 Checking JOOL kernel modules..."
  lsmod | grep -E '^jool|^jool_mapt|^jool_common' || true

  for module in "${required_modules[@]}"; do
    if module_loaded "$module"; then
      echo "✅ Module loaded: $module"
    else
      echo "⚙️  Loading module: $module"
      modprobe "$module"
      need_load=1
    fi
  done

  for module in "${required_modules[@]}"; do
    if ! module_loaded "$module"; then
      echo "❌ Module failed to load: $module"
      exit 1
    fi
  done

  if [[ "$need_load" -eq 1 ]]; then
    echo "✅ JOOL modules loaded successfully"
  else
    echo "✅ All JOOL modules already loaded"
  fi
}

instance_is_healthy() {
  jool_mapt -i "$INSTANCE" fmrt display >/dev/null 2>&1 && \
  jool_mapt -i "$INSTANCE" stats display >/dev/null 2>&1
}

ensure_instance() {
  if jool_mapt -i "$INSTANCE" instance display >/dev/null 2>&1; then
    echo "✅ JOOL instance '$INSTANCE' exists"
  else
    echo "⚙️  Creating JOOL MAP-T instance '$INSTANCE'"
    jool_mapt instance add "$INSTANCE" --netfilter --dmr "$EXP_DMR"
  fi
}

rebuild_instance() {
  echo "⚠️  JOOL instance '$INSTANCE' is not healthy — rebuilding"
  jool_mapt instance remove "$INSTANCE" >/dev/null 2>&1 || true
  jool_mapt instance add "$INSTANCE" --netfilter --dmr "$EXP_DMR"
}

############################################
# 1️⃣ Kernel modules + instance health
############################################

ensure_kernel_compatible_modules
ensure_modules
ensure_instance

if instance_is_healthy; then
  echo "✅ JOOL instance '$INSTANCE' health check passed"
else
  rebuild_instance
fi

############################################
# 2️⃣ Show runtime status
############################################

echo "📊 Current FMRT table:"
jool_mapt -i "$INSTANCE" fmrt display || true

echo "📊 Current JOOL stats:"
jool_mapt -i "$INSTANCE" stats display || true

############################################
# 3️⃣ Parse CURRENT FMRT state
############################################

sleep 3

read CUR_V6 CUR_V4 CUR_EA CUR_A <<EOF
$(jool_mapt -i "$INSTANCE" fmrt display |
  awk -F'|' '
    /^\|/ {
      for(i=1;i<=NF;i++) gsub(/^ +| +$/, "", $i)
    }
    $2=="IPv6 Prefix" {next}
    $2!="" {print $2, $3, $4, $5; exit}
  '
)
EOF

############################################
# 4️⃣ Validate FMRT
############################################

if [[ -n "$CUR_V6" ]]; then
  echo "ℹ️  Current FMRT:"
  echo "   IPv6 Prefix: $CUR_V6"
  echo "   IPv4 Prefix: $CUR_V4"
  echo "   EA Bits:     $CUR_EA"
  echo "   Offset (A):  $CUR_A"
else
  echo "⚠️  No FMRT rule present"
fi

if [[ "$CUR_V6" == "$EXP_V6" ]] &&
   [[ "$CUR_V4" == "$EXP_V4" ]] &&
   [[ "$CUR_EA" == "$EXP_EA" ]] &&
   [[ "$CUR_A"  == "$EXP_A"  ]]; then

  echo "✅ FMRT rule matches expected configuration"
else
  echo "⚙️  FMRT mismatch detected — applying expected rule"
  if [[ -n "$CUR_V6" && -n "$CUR_V4" && -n "$CUR_EA" && -n "$CUR_A" ]]; then
    echo "🧹 Removing existing FMRT rule first"
    jool_mapt -i "$INSTANCE" fmrt remove \
      "$CUR_V6" \
      "$CUR_V4" \
      "$CUR_EA" \
      "$CUR_A" >/dev/null 2>&1 || true
  fi
  jool_mapt -i "$INSTANCE" fmrt add \
    "$EXP_V6" \
    "$EXP_V4" \
    "$EXP_EA" \
    "$EXP_A"
fi

############################################
# 5️⃣ Enforce MAP-T type
############################################

echo "🔧 Ensuring MAP-T type is BR"
jool_mapt -i "$INSTANCE" global update map-t-type BR

############################################
# DONE
############################################

echo "✅ JOOL MAP-T '$INSTANCE' validated and ready"
