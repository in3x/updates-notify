#!/usr/bin/env bash
# Common Telemetry & Notification Functions

NTFY_TOPIC=""
HC_PING_URL=""

if [[ -f /etc/conditional-reboot.conf.d/99-local.conf ]]; then
    source /etc/conditional-reboot.conf.d/99-local.conf
fi

ping_hc() {
    local status="${1:-}"
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
    if [[ -n "${NTFY_TOPIC:-}" ]]; then
        curl -s \
             -H "Authorization: Bearer ${NTFY_TOKEN:-}" \
             -H "Title: ${title}" \
             -H "Priority: ${priority}" \
             -d "${message}" \
             "https://ntfy.sh/${NTFY_TOPIC}"  >/dev/null 2>&1 || true
    fi
}

failure_handler() {
    local line_no="${1:-unknown}"
    local script_name
    script_name="$(basename "$0")"

    logger -t "${script_name}" "Script error occurred on line ${line_no}."
    send_ntfy "🚨 Pipeline Failure: ${script_name}" "${script_name} crashed on $(hostname) at line ${line_no}." "urgent"
    ping_hc "fail"
    exit 1
}
