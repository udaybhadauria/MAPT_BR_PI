#!/bin/bash

set -e

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
SCRIPT_DIR_ESCAPED="$(printf '%q' "$SCRIPT_DIR")"
CRON_TMP="/tmp/current_cron.$$"
touch "$CRON_TMP"

# Load existing crontab if it exists
crontab -l 2>/dev/null > "$CRON_TMP" || true

# Normalize old health-check schedules so only one canonical entry exists.
grep -v "services_health_check.sh" "$CRON_TMP" > "${CRON_TMP}.new" || true
mv "${CRON_TMP}.new" "$CRON_TMP"

# Normalize periodic reboot entries so only one canonical entry exists.
grep -v "BR_PI periodic reboot" "$CRON_TMP" > "${CRON_TMP}.new" || true
mv "${CRON_TMP}.new" "$CRON_TMP"

# Function to add cron line if missing
add_cron_job() {
    local job="$1"
    grep -Fxq "$job" "$CRON_TMP" || echo "$job" >> "$CRON_TMP"
}

# Required cron jobs
add_cron_job "@reboot (sleep 120; /bin/bash $SCRIPT_DIR_ESCAPED/apply_config.sh) >> $SCRIPT_DIR_ESCAPED/zboot_logs.log 2>&1"
add_cron_job "* * * * * /bin/bash $SCRIPT_DIR_ESCAPED/clean_neitable.sh"
add_cron_job "*/5 * * * * /bin/bash $SCRIPT_DIR_ESCAPED/check_services.sh"
add_cron_job "*/15 * * * * /bin/bash $SCRIPT_DIR_ESCAPED/services_health_check.sh"
add_cron_job "*/5 * * * * /bin/bash $SCRIPT_DIR_ESCAPED/at_boot_check_eth0.sh"
add_cron_job "*/5 * * * * /bin/bash $SCRIPT_DIR_ESCAPED/at_boot_check_lan_iface.sh"
add_cron_job "0 4 */2 * * (echo '[CRON] BR_PI periodic reboot for fresh network session'; /sbin/reboot) >> $SCRIPT_DIR_ESCAPED/zboot_logs.log 2>&1"

# Install updated crontab
crontab "$CRON_TMP"

# Cleanup
rm -f "$CRON_TMP"

echo "✅ Crontab verified and updated successfully."
