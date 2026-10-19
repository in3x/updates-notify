#!/usr/bin/env bash
# ==============================================================================
# pending-updates-digest.sh
#
# PURPOSE:
#   Weekly audit check that notifies of all outstanding pending updates.
# ==============================================================================
set -euo pipefail

# 1. Early bootstrap trap
trap 'echo "Fatal: Early execution error on line $LINENO" >&2; exit 1' ERR

# 2. Source common telemetry library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common-telemetry.sh"
trap 'failure_handler ${LINENO}' ERR

# 3. Refresh package lists quietly (if supported)
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1 || true
elif command -v dnf >/dev/null 2>&1; then
    dnf check-update -q >/dev/null 2>&1 || true
fi

# 4. Check for pending updates
PENDING_UPDATES=$(get_pending_updates)

if [[ -z "${PENDING_UPDATES}" ]]; then
    logger -t pending-updates-digest "No pending package updates on ${HOSTNAME}."
    exit 0
fi

# 5. Dispatch weekly digest notification
logger -t pending-updates-digest "Pending package updates on ${HOSTNAME}: ${PENDING_UPDATES}"
ACTION_BTN=$(get_apply_updates_action)
send_ntfy "control" "📦 Weekly Updates Digest" "Pending package updates on ${HOSTNAME}: ${PENDING_UPDATES}." "default" "${ACTION_BTN}"

exit 0
