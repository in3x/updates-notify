#!/usr/bin/env bash
set -euo pipefail

# 1. REGISTER BOOTSTRAP TRAP BEFORE ANY SOURCING OR PATH EXPANSION
trap 'echo "Fatal: Early execution error on line $LINENO before common library loaded" >&2; exit 1' ERR

# 2. Source Common Functions & Upgrade to Full Failure Handler
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common-telemetry.sh"
trap 'failure_handler ${LINENO}' ERR

# 3. Script Logic & Defaults
MAINTENANCE_WINDOW_START="${MAINTENANCE_WINDOW_START:-02:00}"
MAINTENANCE_WINDOW_END="${MAINTENANCE_WINDOW_END:-05:00}"
BLOCKED_PROCESSES=("${BLOCKED_PROCESSES[@]:-backup_job db_migration rsync}")
FAIL_FLAG_FILE="/var/run/apt-update.failed"

# 4. Inspect Prior Pipeline Failures
if [[ -f "${FAIL_FLAG_FILE}" ]]; then
    logger -t conditional-reboot "Aborting: Prior package update failure flag (${FAIL_FLAG_FILE}) detected."
    send_ntfy "⚠️ Reboot Aborted" "Reboot skipped on $(hostname): Package installation reported failures." "high"
    ping_hc "fail"
    exit 1
fi

# 5. Check If Reboot Is Required
REBOOT_REQUIRED=false
if [[ -f /var/run/reboot-required ]]; then
    REBOOT_REQUIRED=true
elif command -v needs-restarting >/dev/null 2>&1; then
    if ! needs-restarting -r >/dev/null 2>&1; then
        REBOOT_REQUIRED=true
    fi
fi

if [[ "${REBOOT_REQUIRED}" == "false" ]]; then
    logger -t conditional-reboot "No reboot required."
    ping_hc ""
    exit 0
fi

# 6. Maintenance Window Check (With High-Priority Deferred Alert)
CURRENT_TIME=$(date +%H:%M)
if [[ "${CURRENT_TIME}" < "${MAINTENANCE_WINDOW_START}" || "${CURRENT_TIME}" > "${MAINTENANCE_WINDOW_END}" ]]; then
    logger -t conditional-reboot "Reboot required but outside maintenance window (${CURRENT_TIME}). Deferring."
    send_ntfy "ℹ️ Reboot Deferred" "Reboot deferred on $(hostname): Outside maintenance window (${CURRENT_TIME})." "high"
    ping_hc ""
    exit 0
fi

# 7. Active SSH User Check (With High-Priority Deferred Alert)
if who | grep -q -v 'root'; then
    logger -t conditional-reboot "Active user sessions detected. Deferring reboot."
    send_ntfy "ℹ️ Reboot Deferred" "Reboot deferred on $(hostname): Active logged-in user sessions." "high"
    ping_hc ""
    exit 0
fi

# 8. Blocked Process Check (With High-Priority Deferred Alert)
for proc in "${BLOCKED_PROCESSES[@]}"; do
    if pgrep -f "${proc}" >/dev/null 2>&1; then
        logger -t conditional-reboot "Blocked process '${proc}' is active. Deferring reboot."
        send_ntfy "ℹ️ Reboot Deferred" "Reboot deferred on $(hostname): Process '${proc}' is currently running." "high"
        ping_hc ""
        exit 0
    fi
done

# 9. Execute System Reboot
logger -t conditional-reboot "All safety checks passed. Triggering system reboot."
send_ntfy "🔄 System Rebooting" "Automated maintenance checks passed on $(hostname). Initiating reboot in 1 minute."
ping_hc ""
/sbin/shutdown -r +1 "Automated maintenance reboot scheduled in 1 minute."
