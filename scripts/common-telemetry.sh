#!/usr/bin/env bash
# Common Telemetry & Notification Functions

NTFY_TOPIC=""
HC_PING_URL=""

if [[ -f /etc/conditional-reboot.conf.d/99-local.conf ]]; then
    source /etc/conditional-reboot.conf.d/99-local.conf
fi

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
    local title="${1:-System Alert}"
    local message="${2:-No message body provided.}"
    local priority="${3:-default}"
    local actions="${4:-}"

    local caller_file="${BASH_SOURCE[1]:-$0}"
    local caller_line="${BASH_LINENO[0]:-unknown}"
    local caller_name
    caller_name="$(basename "${caller_file}")"

    local first_lines
    first_lines=$(echo "${message}" | head -n 2 | tr '\n' ' ')

    logger -t "ntfy-dispatch" "[${caller_name}:${caller_line}] Priority='${priority}' Title='${title}' Body='${first_lines}'"

    if [[ -n "${NTFY_TOPIC:-}" ]]; then
        local -a headers=()
        [[ -n "${NTFY_TOKEN:-}" ]] && headers+=(-H "Authorization: Bearer ${NTFY_TOKEN}")
        headers+=(-H "Title: ${title}")
        headers+=(-H "Priority: ${priority}")
        [[ -n "${actions}" ]] && headers+=(-H "Actions: ${actions}")

        curl -s "${headers[@]}" \
             -d "${message}" \
             "${NTFY_URL:-https://ntfy.sh}/${NTFY_TOPIC}" >/dev/null 2>&1 || true
    fi
}

get_apply_updates_action() {
    local cmd_topic="${NTFY_CMD_TOPIC:-${NTFY_TOPIC:+${NTFY_TOPIC}-cmd}}"
    if [[ -z "${cmd_topic}" ]]; then
        echo ""
        return 0
    fi

    local action="http, 🚀 Apply All Updates, ${NTFY_URL:-https://ntfy.sh}/${cmd_topic}, body=apply_all_updates, clear=true"
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
    send_ntfy "🚨 Pipeline Failure: ${script_name}" "${script_name} crashed on ${HOSTNAME} at line ${line_no}." "urgent"
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
