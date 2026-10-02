#!/usr/bin/env bash
# ==============================================================================
# remote-update-listener.sh
#
# PURPOSE:
#   Background listener daemon that subscribes to an NTFY command topic.
#   Listens for remote 'apply_all_updates' triggers (e.g. from NTFY action buttons)
#   and executes apply-all-updates.sh safely.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common-telemetry.sh"

CMD_TOPIC="${NTFY_CMD_TOPIC:-${NTFY_TOPIC:+${NTFY_TOPIC}-cmd}}"

if [[ -z "${CMD_TOPIC}" ]]; then
    logger -t remote-listener "NTFY command topic is not configured. Exiting."
    exit 0
fi

logger -t remote-listener "Starting NTFY remote command listener on topic '${CMD_TOPIC}'..."

STREAM_URL="${NTFY_URL:-https://ntfy.sh}/${CMD_TOPIC}/raw"

while true; do
    logger -t remote-listener "Connecting to NTFY event stream: ${STREAM_URL}"

    local_headers=()
    if [[ -n "${NTFY_TOKEN:-}" ]]; then
        local_headers=(-H "Authorization: Bearer ${NTFY_TOKEN}")
    fi

    # Subscribe to raw incoming stream line by line
    curl -s -N "${local_headers[@]}" "${STREAM_URL}" 2>/dev/null | while IFS= read -r msg; do
        # Ignore keepalive / empty lines
        [[ -z "${msg}" ]] && continue

        logger -t remote-listener "Received incoming message on ${CMD_TOPIC}: ${msg}"

        # Match trigger command
        case "${msg}" in
            "apply_all_updates"|"apply_updates_${HOSTNAME}")
                logger -t remote-listener "Valid update command received for ${HOSTNAME}. Triggering upgrade runner..."
                /usr/local/bin/apply-all-updates.sh || true
                ;;
            *)
                logger -t remote-listener "Ignored unrecognized command: ${msg}"
                ;;
        esac
    done || true

    logger -t remote-listener "Stream disconnected. Reconnecting in 10 seconds..."
    sleep 10
done
