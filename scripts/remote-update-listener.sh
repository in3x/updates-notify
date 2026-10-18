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

        logger -t remote-listener "Received event payload: ${msg}"

        target_matched=0
        max_ttl=86400  # 24-hour maximum validity window

        # High-entropy seeded multi-round format: apply_updates:<host>:<ts>:<seed>:<hmac>
        if [[ "${msg}" =~ ^apply_updates:([^:]+):([0-9]+):([a-fA-F0-9]+):([a-fA-F0-9]{64})$ ]]; then
            target_host="${BASH_REMATCH[1]}"
            cmd_ts="${BASH_REMATCH[2]}"
            cmd_seed="${BASH_REMATCH[3]}"
            cmd_sig="${BASH_REMATCH[4]}"

            # 1. Host Target Matching
            if [[ "${target_host}" != "${MY_HOSTNAME}" && "${target_host}" != "${HOSTNAME}" ]]; then
                # Command is destined for another machine on the shared topic; ignore cleanly
                continue
            fi

            # 2. Cryptographic Multi-Round HMAC Verification (ssh-keygen style round stretching)
            if [[ -n "${FLEET_SECRET:-}" ]]; then
                expected_sig="$(compute_payload_hmac "${FLEET_SECRET}" "${target_host}" "${cmd_ts}" "${cmd_seed}" 16)"
                if [[ "${cmd_sig}" != "${expected_sig}" ]]; then
                    logger -t remote-listener "SECURITY ALERT: Invalid HMAC signature on command payload for ${MY_HOSTNAME}. Dropped."
                    continue
                fi
            fi

            # 3. Expiration Check (Anti-Stale / Anti-Replay TTL)
            now="$(date +%s)"
            age=$(( now - cmd_ts ))
            if (( age > max_ttl || age < -300 )); then
                logger -t remote-listener "WARNING: Command payload expired (age: ${age}s, max TTL: ${max_ttl}s). Dropped."
                continue
            fi

            # 4. Anti-Replay: Check if random seed was already consumed
            nonce_dir="/run/updates-notify"
            mkdir -p "${nonce_dir}"
            nonce_file="${nonce_dir}/consumed_nonces"
            if [[ -f "${nonce_file}" ]] && grep -qFx "${cmd_seed}:${cmd_sig}" "${nonce_file}" 2>/dev/null; then
                logger -t remote-listener "WARNING: Blocked replayed update command (seed ${cmd_seed} already consumed)."
                continue
            fi

            # Record consumed seed
            echo "${cmd_seed}:${cmd_sig}" >> "${nonce_file}"
            # Cryptographic signature, TTL, and nonce verified; authorize execution
            target_matched=1

        # Fallback 3-part format (legacy single-pass): apply_updates:<host>:<ts>:<hmac>
        elif [[ "${msg}" =~ ^apply_updates:([^:]+):([0-9]+):([a-fA-F0-9]+)$ ]]; then
            target_host="${BASH_REMATCH[1]}"
            cmd_ts="${BASH_REMATCH[2]}"
            cmd_sig="${BASH_REMATCH[3]}"

            # 1. Host Target Matching (Fallback format)
            if [[ "${target_host}" != "${MY_HOSTNAME}" && "${target_host}" != "${HOSTNAME}" ]]; then
                # Command is destined for another machine on the shared topic; ignore cleanly
                continue
            fi

            if [[ -n "${FLEET_SECRET:-}" ]]; then
                expected_sig="$(echo -n "${target_host}:${cmd_ts}" | openssl dgst -sha256 -hmac "${FLEET_SECRET}" 2>/dev/null | awk '{print $2}')"
                if [[ "${cmd_sig}" != "${expected_sig}" ]]; then
                    logger -t remote-listener "SECURITY ALERT: Invalid HMAC signature on command payload for ${MY_HOSTNAME}. Dropped."
                    continue
                fi
            fi

            now="$(date +%s)"
            age=$(( now - cmd_ts ))
            if (( age > max_ttl || age < -300 )); then
                logger -t remote-listener "WARNING: Command payload expired (age: ${age}s, max TTL: ${max_ttl}s). Dropped."
                continue
            fi

            nonce_dir="/run/updates-notify"
            mkdir -p "${nonce_dir}"
            nonce_file="${nonce_dir}/consumed_nonces"
            if [[ -f "${nonce_file}" ]] && grep -qFx "${cmd_ts}:${cmd_sig}" "${nonce_file}" 2>/dev/null; then
                logger -t remote-listener "WARNING: Blocked replayed update command (nonce ${cmd_ts} already consumed)."
                continue
            fi

            echo "${cmd_ts}:${cmd_sig}" >> "${nonce_file}"
            # Cryptographic signature, TTL, and nonce verified; authorize execution
            target_matched=1

        elif [[ "${msg}" == "apply_updates:${MY_HOSTNAME}" || "${msg}" == "apply_updates:${HOSTNAME}" || "${msg}" == "apply_updates_${MY_HOSTNAME}" || "${msg}" == "apply_updates_${HOSTNAME}" || "${msg}" == "apply_all_updates" ]]; then
            # If FLEET_SECRET is enforced on this node, reject unauthenticated legacy payloads
            if [[ -n "${FLEET_SECRET:-}" ]]; then
                logger -t remote-listener "SECURITY WARNING: Dropped unsigned payload '${msg}' because FLEET_SECRET is required on this host."
                continue
            fi
            target_matched=1
        fi

        if (( target_matched == 1 )); then
            logger -t remote-listener "Verified update command accepted for ${MY_HOSTNAME}. Triggering upgrade runner..."

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
