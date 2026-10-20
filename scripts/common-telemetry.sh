#!/usr/bin/env bash
# Common Telemetry & Notification Functions

NTFY_ALERTS_TOPIC=""
NTFY_REBOOT_TOPIC=""
NTFY_CONTROL_TOPIC=""
NTFY_TOPIC=""
HC_PING_URL=""

CONF_FILE="/etc/conditional-reboot.conf.d/99-local.conf"

if [[ -f "${CONF_FILE}" ]]; then
    source "${CONF_FILE}"
elif [[ $EUID -ne 0 ]]; then
    logger -t "telemetry" "Warning: Script executed as non-root (EUID=$EUID); unable to read ${CONF_FILE}."
    echo "Warning: Running as non-root. Cannot access ${CONF_FILE}; please run with 'sudo'." >&2
fi

# Ensure optional secret parameters have safe defaults for set -u
FLEET_SECRET="${FLEET_SECRET:-}"
FLEET_SECRET_PREVIOUS="${FLEET_SECRET_PREVIOUS:-}"
FLEET_SECRET_CREATED_DATE="${FLEET_SECRET_CREATED_DATE:-0}"
NTFY_ALERTS_TOPIC="${NTFY_ALERTS_TOPIC:-}"
NTFY_REBOOT_TOPIC="${NTFY_REBOOT_TOPIC:-}"
NTFY_CONTROL_TOPIC="${NTFY_CONTROL_TOPIC:-}"
NTFY_TOPIC="${NTFY_TOPIC:-}"

ping_hc() {
    local status="${1:-}"
    local caller_file="${BASH_SOURCE[1]:-$0}"
    local caller_line="${BASH_LINENO[0]:-unknown}"
    local caller_name
    caller_name="$(basename "${caller_file}")"

    logger -t "hc-dispatch" "[${caller_name}:${caller_line}] Status='${status:-success}' URL='${HC_PING_URL:-not_configured}'"

    if [[ -n "${HC_PING_URL:-}" ]]; then
        local url="${HC_PING_URL}"
        [[ -n "${status}" ]] && url="${url}/${status}"
        curl -fsS -m 10 "${url}" >/dev/null 2>&1 || true
    fi
}

send_ntfy() {
    local channel="alerts"
    local title=""
    local message=""
    local priority="default"
    local actions=""

    # Support 3-channel routing: send_ntfy <channel> <title> <message> [priority] [actions]
    # Fallback for legacy calls: send_ntfy <title> <message> [priority] [actions]
    case "${1:-}" in
        alerts|reboot|control)
            channel="$1"
            title="${2:-System Alert}"
            message="${3:-No message body provided.}"
            priority="${4:-default}"
            actions="${5:-}"
            ;;
        *)
            channel="alerts"
            title="${1:-System Alert}"
            message="${2:-No message body provided.}"
            priority="${3:-default}"
            actions="${4:-}"
            ;;
    esac

    # Resolve destination topic based on channel
    local target_topic=""
    case "${channel}" in
        alerts)
            target_topic="${NTFY_ALERTS_TOPIC:-${NTFY_TOPIC:-}}"
            ;;
        reboot)
            target_topic="${NTFY_REBOOT_TOPIC:-${NTFY_TOPIC:-}}"
            ;;
        control)
            target_topic="${NTFY_CONTROL_TOPIC:-${NTFY_TOPIC:-}}"
            ;;
    esac

    if [[ -z "${target_topic}" ]]; then
        return 0
    fi

    # Automatically prepend host tag for clear multi-machine visibility on shared topics
    local host_tag="[$(hostname -s 2>/dev/null || echo "${HOSTNAME}")]"
    if [[ "${title}" != *"${host_tag}"* && "${title}" != *"["*"${HOSTNAME}"*"]"* ]]; then
        title="${host_tag} ${title}"
    fi

    local caller_file="${BASH_SOURCE[1]:-$0}"
    local caller_line="${BASH_LINENO[0]:-unknown}"
    local caller_name
    caller_name="$(basename "${caller_file}")"

    local first_lines
    first_lines=$(echo "${message}" | head -n 2 | tr '\n' ' ')

    logger -t "ntfy-dispatch" "[${caller_name}:${caller_line}] [${channel}->${target_topic}] Priority='${priority}' Title='${title}' Body='${first_lines}'"

    local -a headers=()
    [[ -n "${NTFY_TOKEN:-}" ]] && headers+=(-H "Authorization: Bearer ${NTFY_TOKEN}")
    headers+=(-H "Title: ${title}")
    headers+=(-H "Priority: ${priority}")
    [[ -n "${actions}" ]] && headers+=(-H "Actions: ${actions}")

    curl -s "${headers[@]}" \
         -d "${message}" \
         "${NTFY_URL:-https://ntfy.sh}/${target_topic}" >/dev/null 2>&1 || true
}

compute_payload_hmac() {
    local secret="$1"
    local hostname="$2"
    local timestamp="$3"
    local seed="$4"
    local rounds="${5:-16}"

    local data="${hostname}:${timestamp}:${seed}"
    local digest
    digest="$(echo -n "${data}" | openssl dgst -sha256 -hmac "${secret}" 2>/dev/null | awk '{print $2}')"

    # Sequential round stretching (similar to key derivation rounds in ssh-keygen -a)
    local r
    for (( r=2; r<=rounds; r++ )); do
        digest="$(echo -n "${digest}:${seed}:${r}" | openssl dgst -sha256 -hmac "${secret}" 2>/dev/null | awk '{print $2}')"
    done

    echo "${digest}"
}

get_apply_updates_action() {
    local cmd_topic="${NTFY_CONTROL_TOPIC:-${NTFY_CMD_TOPIC:-${NTFY_TOPIC:+${NTFY_TOPIC}-cmd}}}"
    if [[ -z "${cmd_topic}" ]]; then
        echo ""
        return 0
    fi

    local host_tag="$(hostname -s 2>/dev/null || echo "${HOSTNAME}")"
    local body="apply_updates:${host_tag}"

    # Generate unpredictable, multi-round HMAC signature if FLEET_SECRET is configured
    if [[ -n "${FLEET_SECRET:-}" ]]; then
        local ts
        ts="$(date +%s)"
        local seed
        seed="$(openssl rand -hex 8 2>/dev/null || od -vN 8 -An -tx1 /dev/urandom | tr -d ' \n')"
        local sig
        sig="$(compute_payload_hmac "${FLEET_SECRET}" "${host_tag}" "${ts}" "${seed}" 16)"
        if [[ -n "${sig}" && -n "${seed}" ]]; then
            body="apply_updates:${host_tag}:${ts}:${seed}:${sig}"
        fi
    fi

    local action="http, 🚀 Apply Updates (${host_tag}), ${NTFY_URL:-https://ntfy.sh}/${cmd_topic}, body=${body}, clear=true, headers.Priority=1"
    if [[ -n "${NTFY_TOKEN:-}" ]]; then
        action="${action}, headers.Authorization=Bearer ${NTFY_TOKEN}"
    fi
    echo "${action}"
}

failure_handler() {
    local line_no="${1:-unknown}"
    local script_name
    script_name="$(basename "$0")"

    touch /run/package-update.failed 2>/dev/null || true
    logger -t "${script_name}" "Script error occurred on line ${line_no}."
    send_ntfy "alerts" "🚨 Pipeline Failure: ${script_name}" "${script_name} crashed on ${HOSTNAME} at line ${line_no}." "urgent"
    ping_hc "fail"
    exit 1
}

get_pending_updates() {
    local raw=""
    if [[ -f /etc/debian_version ]] && command -v apt-get >/dev/null 2>&1; then
        raw=$(apt-get -s -o Debug::NoLocking=true dist-upgrade 2>/dev/null | awk '/^Inst / {print $2}')
    elif [[ -f /etc/redhat-release ]] && command -v dnf >/dev/null 2>&1; then
        raw=$(dnf check-update -q 2>/dev/null | awk '/^[a-zA-Z0-9]/ {print $1}')
    elif command -v apt-get >/dev/null 2>&1; then
        raw=$(apt-get -s -o Debug::NoLocking=true dist-upgrade 2>/dev/null | awk '/^Inst / {print $2}')
    elif command -v dnf >/dev/null 2>&1; then
        raw=$(dnf check-update -q 2>/dev/null | awk '/^[a-zA-Z0-9]/ {print $1}')
    fi

    if [[ -z "${raw}" ]]; then
        logger -t telemetry "get_pending_updates: No pending packages found."
        return 0
    fi

    local -a pkgs=()
    while IFS= read -r pkg; do
        [[ -n "${pkg}" ]] && pkgs+=("${pkg}")
    done <<< "${raw}"

    local total="${#pkgs[@]}"
    if (( total == 0 )); then
        return 0
    fi

    local result=""
    if (( total > 15 )); then
        local first_slice=("${pkgs[@]:0:15}")
        local formatted
        formatted=$(IFS=, ; echo "${first_slice[*]}")
        formatted="${formatted//,/, }"
        result="${total} packages (${formatted}, +$(( total - 15 )) more)"
    else
        local formatted
        formatted=$(IFS=, ; echo "${pkgs[*]}")
        formatted="${formatted//,/, }"
        result="${total} package(s): ${formatted}"
    fi

    logger -t telemetry "get_pending_updates: Found ${result}"
    echo "${result}"
}
