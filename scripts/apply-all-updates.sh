#!/usr/bin/env bash
# ==============================================================================
# apply-all-updates.sh
#
# PURPOSE:
#   Performs a full, non-interactive package upgrade across all pending packages,
#   logs all updated packages to syslog and /var/log/package-upgrades.log,
#   and sends an immediate telemetry report with the list of upgraded packages.
# ==============================================================================
set -euo pipefail

# 1. Early bootstrap trap
trap 'echo "Fatal: Early execution error on line $LINENO" >&2; touch /run/package-update.failed; exit 1' ERR

# 2. Source common telemetry library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common-telemetry.sh"
trap 'touch /run/package-update.failed; failure_handler ${LINENO}' ERR

# 3. Snapshot list of pending packages before upgrading
PACKAGES_TO_UPGRADE=$(get_pending_updates)

logger -t apply-updates "Initiating full package upgrade on ${HOSTNAME}. Target packages: ${PACKAGES_TO_UPGRADE:-None detected}"
send_ntfy "control" "⏳ Updates In Progress" "Starting full package upgrade on ${HOSTNAME}...\n\nTarget packages: ${PACKAGES_TO_UPGRADE:-All available}" "default"

LOG_FILE="/var/log/package-upgrades.log"
mkdir -p "$(dirname "${LOG_FILE}")"

UPGRADE_TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
{
    echo ""
    echo "=============================================================================="
    echo "Remote package upgrade started at: ${UPGRADE_TIMESTAMP} on ${HOSTNAME}"
    echo "Packages identified for upgrade: ${PACKAGES_TO_UPGRADE:-None}"
    echo "------------------------------------------------------------------------------"
} >> "${LOG_FILE}"

# 4. Pre-upgrade etckeeper hook (if installed)
if command -v etckeeper >/dev/null 2>&1; then
    etckeeper pre-install || true
fi

UPGRADE_SUCCESS=false

# 5. Execute Package Manager Upgrade
if command -v apt-get >/dev/null 2>&1; then
    logger -t apply-updates "Running apt-get update & dist-upgrade on ${HOSTNAME}..."
    if apt-get update -qq >> "${LOG_FILE}" 2>&1 && \
       DEBIAN_FRONTEND=noninteractive apt-get -y \
       -o Dpkg::Options::="--force-confdef" \
       -o Dpkg::Options::="--force-confold" \
       dist-upgrade >> "${LOG_FILE}" 2>&1; then
        UPGRADE_SUCCESS=true
    fi
elif command -v dnf >/dev/null 2>&1; then
    logger -t apply-updates "Running dnf upgrade on ${HOSTNAME}..."
    if dnf upgrade -y >> "${LOG_FILE}" 2>&1; then
        UPGRADE_SUCCESS=true
    fi
else
    logger -t apply-updates "Error: No supported package manager found."
    exit 1
fi

# 6. Post-upgrade etckeeper hook (if installed)
if command -v etckeeper >/dev/null 2>&1; then
    etckeeper post-install || true
fi

# 7. Evaluate Completion & Dispatch Telemetry
if [[ "${UPGRADE_SUCCESS}" == "true" ]]; then
    rm -f /run/package-update.failed
    {
        echo "------------------------------------------------------------------------------"
        echo "Upgrade completed successfully at: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "=============================================================================="
    } >> "${LOG_FILE}"

    logger -t apply-updates "Package upgrade completed successfully on ${HOSTNAME}. Upgraded: ${PACKAGES_TO_UPGRADE:-Done}"

    # Check if a reboot is now required after applying updates
    REBOOT_STATUS="No reboot required."
    TRIGGER_PKGS=""
    if [[ -f /run/reboot-required || -f /var/run/reboot-required ]]; then
        if [[ -s /run/reboot-required.pkgs ]]; then
            TRIGGER_PKGS=$(paste -sd ', ' /run/reboot-required.pkgs 2>/dev/null || tr '\n' ' ' < /run/reboot-required.pkgs)
        elif [[ -s /var/run/reboot-required.pkgs ]]; then
            TRIGGER_PKGS=$(paste -sd ', ' /var/run/reboot-required.pkgs 2>/dev/null || tr '\n' ' ' < /var/run/reboot-required.pkgs)
        fi
        REBOOT_STATUS="🔄 Reboot is now required (packages: ${TRIGGER_PKGS:-system}). Will be handled in maintenance window."
    elif command -v needs-restarting >/dev/null 2>&1; then
        if ! needs-restarting -r >/dev/null 2>&1; then
            REBOOT_STATUS="🔄 Reboot is now required. Will be handled in maintenance window."
        fi
    fi

    PKG_DETAILS_MSG=""
    if [[ -n "${PACKAGES_TO_UPGRADE}" ]]; then
        PKG_DETAILS_MSG="📦 Upgraded packages: ${PACKAGES_TO_UPGRADE}"$'\n\n'
    fi

    send_ntfy "control" "✅ Updates Completed" "Full package upgrade on ${HOSTNAME} finished successfully.\n\n${PKG_DETAILS_MSG}${REBOOT_STATUS}" "default"
    ping_hc ""
    exit 0
else
    touch /run/package-update.failed
    LAST_LOGS=$(tail -n 15 "${LOG_FILE}" 2>/dev/null | tr '\n' ' ')
    logger -t apply-updates "Package upgrade failed on ${HOSTNAME}: ${LAST_LOGS}"
    send_ntfy "alerts" "❌ Updates Failed" "Package upgrade failed on ${HOSTNAME}!\n\nRecent error log: ${LAST_LOGS}\n\nFull log: ${LOG_FILE}" "urgent"
    ping_hc "fail"
    exit 1
fi
