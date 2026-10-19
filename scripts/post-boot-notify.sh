#!/usr/bin/env bash
# ==============================================================================
# post-boot-notify.sh
#
# PURPOSE:
#   Oneshot notification service executed on system startup.
#   Confirms system boot success, reports running kernel & uptime,
#   and dispatches a confirmation notice to NTFY_REBOOT_TOPIC.
# ==============================================================================
set -euo pipefail

# 1. Early bootstrap trap
trap 'echo "Fatal: Post-boot notification error on line $LINENO" >&2; exit 1' ERR

# 2. Source common telemetry functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common-telemetry.sh"
trap 'failure_handler ${LINENO}' ERR

MY_HOST="$(hostname -s 2>/dev/null || echo "${HOSTNAME}")"
KERNEL="$(uname -r)"
UPTIME="$(uptime -p 2>/dev/null || uptime | awk -F'( |,|:)+' '{print $6,"hours,", $7,"minutes"}')"

# 3. Check for lingering reboot flag
REBOOT_FLAG_NOTE=""
if [[ -f /run/reboot-required || -f /var/run/reboot-required ]]; then
    REBOOT_FLAG_NOTE=$'\n\n'"⚠️ Notice: /run/reboot-required is still present."
fi

BODY="Host ${MY_HOST} is online after system boot.\n\nKernel: ${KERNEL}\nUptime: ${UPTIME}${REBOOT_FLAG_NOTE}"

logger -t post-boot "System boot confirmation: Host ${MY_HOST} online. Kernel: ${KERNEL}."
send_ntfy "reboot" "✅ Boot Successful" "${BODY}" "default"
ping_hc ""

exit 0
