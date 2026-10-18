#!/usr/bin/env bash
# ==============================================================================
# remote-update-listener.sh
#
# PURPOSE:
#   Hardened background listener daemon subscribing to an NTFY command topic.
#   Uses the structured JSON event stream (/json) to:
#     1. Filter keepalive and handshake events without log pollution.
#     2. Enforce publisher identity verification (NTFY_VALID_USER ACL).
#     3. Safely invoke apply-all-updates.sh upon verified triggers.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common-telemetry.sh"

MY_HOSTNAME="$(hostname -s 2>/dev/null || echo "${HOSTNAME}")"
CMD_TOPIC="${NTFY_CMD_TOPIC:-${NTFY_TOPIC:+${NTFY_TOPIC}-cmd}}"

if [[ -z "${CMD_TOPIC}" ]]; then
    logger -t remote-listener "NTFY command topic is not configured. Exiting."
    exit 0
fi

STREAM_URL="${NTFY_URL:-https://ntfy.sh}/${CMD_TOPIC}/json"
EXPECTED_USER="${NTFY_VALID_USER:-}"

logger -t remote-listener "Starting hardened NTFY remote command listener on topic '${CMD_TOPIC}'..."
if [[ -n "${EXPECTED_USER}" ]]; then
    logger -t remote-listener "Publisher ACL enabled. Enforcing sender username='${EXPECTED_USER}'."
fi

while true; do
    logger -t remote-listener "Connecting to NTFY event stream: ${STREAM_URL}"

    local_headers=()
    if [[ -n "${NTFY_TOKEN:-}" ]]; then
        local_headers=(-H "Authorization: Bearer ${NTFY_TOKEN}")
    fi

    # Subscribe to structured JSON event stream
    curl -s -N "${local_headers[@]}" "${STREAM_URL}" 2>/dev/null | while IFS= read -r json_line; do
        [[ -z "${json_line}" ]] && continue

        # Only process message events (cleanly ignore keepalive, open, etc.)
        [[ ! "${json_line}" =~ \"event\":\"message\" ]] && continue

        # Extract message content
        msg=""
        if [[ "${json_line}" =~ \"message\":\"([^\"]+)\" ]]; then
            msg="${BASH_REMATCH[1]}"
        fi

        # Extract publisher username if present in JSON payload
        sender_user=""
        if [[ "${json_line}" =~ \"username\":\"([^\"]+)\" ]]; then
            sender_user="${BASH_REMATCH[1]}"
        fi

        # Enforce publisher verification ACL if configured
        if [[ -n "${EXPECTED_USER}" && "${sender_user}" != "${EXPECTED_USER}" ]]; then
            logger -t remote-listener "WARNING: Blocked execution attempt from unauthorized publisher '${sender_user:-anonymous}'"
            continue
        fi

        logger -t remote-listener "Received verified payload: ${msg}"

        if [[ "${msg}" == "apply_all_updates" || "${msg}" == "apply_updates_${MY_HOSTNAME}" || "${msg}" == "apply_updates_${HOSTNAME}" ]]; then
            logger -t remote-listener "Valid update command received for ${MY_HOSTNAME}. Triggering upgrade runner..."

            if [[ -x "/usr/local/bin/apply-all-updates.sh" ]]; then
                /usr/local/bin/apply-all-updates.sh || logger -t remote-listener "ERROR: apply-all-updates.sh failed."
            elif [[ -f "${SCRIPT_DIR}/apply-all-updates.sh" && -x "${SCRIPT_DIR}/apply-all-updates.sh" ]]; then
                "${SCRIPT_DIR}/apply-all-updates.sh" || logger -t remote-listener "ERROR: apply-all-updates.sh failed."
            else
                logger -t remote-listener "ERROR: Execution target apply-all-updates.sh missing or non-executable."
            fi
        fi
    done || true

    logger -t remote-listener "Stream disconnected. Reconnecting in 10 seconds..."
    sleep 10
done
