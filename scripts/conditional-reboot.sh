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
REBOOT_DELAY_MINUTES="${REBOOT_DELAY_MINUTES:-5}"

if [[ -z "${BLOCKED_PROCESSES+x}" ]]; then
    BLOCKED_PROCESSES=("apt" "apt-get" "dpkg" "unattended-upgrade" "dnf" "yum" "rpm" "check-updates" "backup_job" "db_migration" "rsync")
fi

FAIL_FLAG_FILE="/run/package-update.failed"

# 4. Inspect Prior Pipeline Failures
if [[ -f "${FAIL_FLAG_FILE}" ]]; then
    logger -t conditional-reboot "Aborting: Prior package update failure flag (${FAIL_FLAG_FILE}) detected."
    send_ntfy "⚠️ Reboot Aborted" "Reboot skipped on ${HOSTNAME}: Package installation reported failures." "high"
    ping_hc "fail"
    exit 1
fi

# 5. Check If Reboot Is Required
REBOOT_REQUIRED=false
TRIGGER_PKGS=""

if [[ -f /run/reboot-required || -f /var/run/reboot-required ]]; then
    REBOOT_REQUIRED=true
    if [[ -s /run/reboot-required.pkgs ]]; then
        TRIGGER_PKGS=$(paste -sd ', ' /run/reboot-required.pkgs 2>/dev/null || tr '\n' ' ' < /run/reboot-required.pkgs)
    elif [[ -s /var/run/reboot-required.pkgs ]]; then
        TRIGGER_PKGS=$(paste -sd ', ' /var/run/reboot-required.pkgs 2>/dev/null || tr '\n' ' ' < /var/run/reboot-required.pkgs)
    fi
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

PKG_INFO=""
if [[ -n "${TRIGGER_PKGS}" ]]; then
    PKG_INFO=" (packages: ${TRIGGER_PKGS})"
    logger -t conditional-reboot "Reboot required by: ${TRIGGER_PKGS}"
fi

# 6. Maintenance Window Check
CURRENT_TIME=$(date +%H:%M)
if [[ "${CURRENT_TIME}" < "${MAINTENANCE_WINDOW_START}" || "${CURRENT_TIME}" > "${MAINTENANCE_WINDOW_END}" ]]; then
    logger -t conditional-reboot "Reboot required${PKG_INFO} but outside maintenance window (${CURRENT_TIME}). Deferring."
    send_ntfy "ℹ️ Reboot Deferred" "Reboot deferred on ${HOSTNAME}: Outside maintenance window (${CURRENT_TIME}).${PKG_INFO}" "high"
    ping_hc ""
    exit 0
fi

# 7. Active SSH User Check
if who | grep -q -v -w 'root'; then
    logger -t conditional-reboot "Active user sessions detected. Deferring reboot.${PKG_INFO}"
    send_ntfy "ℹ️ Reboot Deferred" "Reboot deferred on ${HOSTNAME}: Active logged-in user sessions.${PKG_INFO}" "high"
    ping_hc ""
    exit 0
fi

# 8. Package Manager Lock Check (Prevent Reboot During Active Upgrades)
PKG_LOCK_FILES=("/var/lib/dpkg/lock-frontend" "/var/lib/dpkg/lock" "/var/lib/apt/lists/lock" "/var/run/dnf.pid" "/var/run/yum.pid")
for lock_file in "${PKG_LOCK_FILES[@]}"; do
    if [[ -f "${lock_file}" ]] && command -v fuser >/dev/null 2>&1 && fuser "${lock_file}" >/dev/null 2>&1; then
        logger -t conditional-reboot "Package manager lock '${lock_file}' is held. Deferring reboot.${PKG_INFO}"
        send_ntfy "ℹ️ Reboot Deferred" "Reboot deferred on ${HOSTNAME}: Package manager is currently installing updates.${PKG_INFO}" "high"
        ping_hc ""
        exit 0
    fi
done

# 9. Blocked Process Check
for proc in "${BLOCKED_PROCESSES[@]}"; do
    if pgrep -f "${proc}" >/dev/null 2>&1; then
        logger -t conditional-reboot "Blocked process '${proc}' is active. Deferring reboot.${PKG_INFO}"
        send_ntfy "ℹ️ Reboot Deferred" "Reboot deferred on ${HOSTNAME}: Process '${proc}' is currently running.${PKG_INFO}" "high"
        ping_hc ""
        exit 0
    fi
done

# 10. Execute System Reboot
logger -t conditional-reboot "All safety checks passed. Triggering intentional system reboot.${PKG_INFO}"

send_ntfy "🔄 Reboot Scheduled" "Intentional maintenance reboot scheduled on ${HOSTNAME} by conditional-reboot utility. All safety checks passed.${PKG_INFO} System will reboot in ${REBOOT_DELAY_MINUTES} minutes." "high"
ping_hc ""
shutdown -r "+${REBOOT_DELAY_MINUTES}" "Automated maintenance reboot scheduled in ${REBOOT_DELAY_MINUTES} minutes by conditional-reboot utility."
