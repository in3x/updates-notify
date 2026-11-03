#!/usr/bin/env bash
# ==============================================================================
# check-updates.sh
#
# PURPOSE:
#   Dedicated pipeline to check for outstanding/pending package updates
#   and dispatch notification telemetry (with optional NTFY action buttons).
#
# TIMING:
#   Scheduled via check-updates.timer (typically daily after repo index refresh).
# ==============================================================================
set -euo pipefail

# 1. Early bootstrap trap
trap 'echo "Fatal: Early execution error on line $LINENO before common library loaded" >&2; exit 1' ERR

# 2. Source Common Functions & Upgrade to Full Failure Handler
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common-telemetry.sh"
trap 'failure_handler ${LINENO}' ERR

# 3. Check for Pending Package Updates
PENDING_UPDATES=$(get_pending_updates)

if [[ -z "${PENDING_UPDATES}" ]]; then
    logger -t check-updates "No pending package updates on ${HOSTNAME}."
    ping_hc ""
    exit 0
fi

# 4. Format Telemetry & Dispatch to Dedicated Channels
ACTION_BTN=$(get_apply_updates_action)
ALERTS_MESSAGE="Available for upgrade on ${HOSTNAME}: ${PENDING_UPDATES}."
CONTROL_MESSAGE="${PENDING_UPDATES} ready to install.\n\nSee alerts topic for full package breakdown. Tap below to apply."

logger -t check-updates "Outstanding updates detected: ${PENDING_UPDATES}"

# Observer Stream (Alerts): Full detailed package list, NO action buttons
send_ntfy "alerts" "📦 Updates Available" "${ALERTS_MESSAGE}" "default"

# Control Stream (Admin): Concise summary pointing to alerts + signed action button
send_ntfy "control" "🚀 Ready to Upgrade" "${CONTROL_MESSAGE}" "default" "${ACTION_BTN}"

ping_hc ""

exit 0
