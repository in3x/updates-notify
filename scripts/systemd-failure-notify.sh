#!/usr/bin/env bash
set -euo pipefail

# 1. REGISTER BOOTSTRAP TRAP BEFORE ANY SOURCING OR PATH EXPANSION
trap 'echo "Fatal: Systemd failure notifier error on line $LINENO" >&2; exit 1' ERR

# 2. Source Common Functions & Upgrade to Full Failure Handler
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common-telemetry.sh"
trap 'failure_handler ${LINENO}' ERR

# 3. Main Logic
FAILED_UNIT="${1:-unknown.service}"

logger -t systemd-notify "Systemd service ${FAILED_UNIT} failed on ${HOSTNAME}."
send_ntfy "🚨 Systemd Execution Failure" "Systemd unit '${FAILED_UNIT}' failed on ${HOSTNAME}." "high"
ping_hc "fail"

exit 0
