#!/usr/bin/env bash
# ==============================================================================
# generate-topic.sh
#
# Generates and rotates site-specific configuration and cryptographic credentials.
#
# NOTE ON SECURITY SEPARATION:
#   This utility generates two completely separate, independent items:
#     1. NTFY_TOPIC:  Public delivery endpoint URL (16 random hex characters).
#     2. FLEET_SECRET: Private 256-bit HMAC key (never exposed in URLs or derived from topic).
#   The topic name and the secret are completely independent and not derived from one another.
#
# Usage:
#   1. Initial generation: creates site configuration with unique topic & separate secret
#   2. Routine rotation (--rotate-secret): rotates FLEET_SECRET with 24h grace window
#   3. Emergency rotation (--rotate-emergency): immediately revokes old secret
#
# Usage:
#   ./scripts/generate-topic.sh <system-group-name> [ntfy-valid-user] [output-file]
#   ./scripts/generate-topic.sh --rotate-secret <system-group-name> [config-file]
#   ./scripts/generate-topic.sh --rotate-emergency <system-group-name> [config-file]
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Helper: update or insert a key=value in a config file
set_conf_variable() {
    local file="$1"
    local var="$2"
    local val="$3"

    if grep -qE "^[[:space:]]*#?[[:space:]]*${var}=" "${file}"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${var}=.*|${var}=\"${val}\"|" "${file}"
    else
        echo "${var}=\"${val}\"" >> "${file}"
    fi
}

# Helper: prompt to restart service
prompt_service_restart() {
    local prompt_msg="$1"
    local default_choice="${2:-N}"

    local choice
    read -r -p "${prompt_msg} [${default_choice}]: " choice
    choice="${choice:-${default_choice}}"

    if [[ "${choice}" =~ ^[Yy]$ ]]; then
        echo "-> Restarting remote-update-listener.service..."
        if command -v systemctl >/dev/null 2>&1; then
            if [[ $EUID -eq 0 ]]; then
                systemctl restart remote-update-listener.service 2>/dev/null && echo "   [OK] Service restarted." || echo "   [INFO] Service not running or inactive."
            elif command -v sudo >/dev/null 2>&1; then
                sudo systemctl restart remote-update-listener.service 2>/dev/null && echo "   [OK] Service restarted." || echo "   [INFO] Service not running or inactive."
            else
                systemctl restart remote-update-listener.service 2>/dev/null || echo "   [INFO] Could not restart service (run with sudo)."
            fi
        fi
    fi
}

# ==============================================================================
# MODE: --rotate-secret / --rotate-emergency
# ==============================================================================
if [[ "${1:-}" == "--rotate-secret" || "${1:-}" == "--rotate-emergency" ]]; then
    ROTATION_MODE="$1"
    shift

    if [[ $# -lt 1 ]]; then
        echo "Error: Missing system group name." >&2
        echo "Usage: $0 ${ROTATION_MODE} <system-group-name> [config-file]" >&2
        exit 1
    fi

    SYSTEM_GROUP="$1"
    TARGET_CONF="${2:-${REPO_DIR}/site-conf/${SYSTEM_GROUP}/99-local.conf}"

    if [[ ! -f "${TARGET_CONF}" ]]; then
        # Check system directory fallback
        if [[ -f "/etc/conditional-reboot.conf.d/99-local.conf" ]]; then
            TARGET_CONF="/etc/conditional-reboot.conf.d/99-local.conf"
        else
            echo "Error: Configuration file not found: ${TARGET_CONF}" >&2
            exit 1
        fi
    fi

    NOW_TS="$(date +%s)"
    NEW_SECRET="$(openssl rand -hex 32 2>/dev/null || od -vN 32 -An -tx1 /dev/urandom | tr -d ' \n')"

    # Create timestamped backup of config file
    BACKUP_FILE="${TARGET_CONF}.$(date +%Y%m%d-%H%M%S).bak"
    cp -p "${TARGET_CONF}" "${BACKUP_FILE}"
    echo "-> Created backup: ${BACKUP_FILE}"

    # Extract current secret
    OLD_SECRET=""
    if grep -qE "^[[:space:]]*FLEET_SECRET=" "${TARGET_CONF}"; then
        OLD_SECRET="$(grep -E '^[[:space:]]*FLEET_SECRET=' "${TARGET_CONF}" | head -n 1 | cut -d= -f2- | tr -d '"'\'' ')"
    fi

    if [[ "${ROTATION_MODE}" == "--rotate-secret" ]]; then
        echo "==> Performing routine secret rotation for '${SYSTEM_GROUP}' (24h grace window)..."

        # Shift old secret to PREVIOUS
        if [[ -n "${OLD_SECRET}" ]]; then
            set_conf_variable "${TARGET_CONF}" "FLEET_SECRET_PREVIOUS" "${OLD_SECRET}"
        fi
        set_conf_variable "${TARGET_CONF}" "FLEET_SECRET" "${NEW_SECRET}"
        set_conf_variable "${TARGET_CONF}" "FLEET_SECRET_CREATED_DATE" "${NOW_TS}"

        echo "    Config file:         ${TARGET_CONF}"
        echo "    New Fleet Secret:    ${NEW_SECRET:0:16}... (256-bit)"
        echo "    Previous Secret:     ${OLD_SECRET:0:16}... (valid for next 24 hours)"
        echo "    Created Timestamp:   ${NOW_TS}"
        echo ""
        echo "Pending notifications signed with the previous secret remain valid until $(date -d "@$(( NOW_TS + 86400 ))" 2>/dev/null || date -r "$(( NOW_TS + 86400 ))" 2>/dev/null || echo "24 hours")."
        echo ""
        prompt_service_restart "Restart remote-update-listener service now? (y/N)" "N"

    elif [[ "${ROTATION_MODE}" == "--rotate-emergency" ]]; then
        echo "==> ⚠️  PERFORMING EMERGENCY SECRET ROTATION FOR '${SYSTEM_GROUP}'..."

        # 1. Purge both the compromised current secret and the previous secret
        echo "-> Purging compromised current and previous fleet secrets..."
        sed -i -E '/^[[:space:]]*#?[[:space:]]*FLEET_SECRET_PREVIOUS=/d' "${TARGET_CONF}"
        sed -i -E '/^[[:space:]]*#?[[:space:]]*FLEET_SECRET=/d' "${TARGET_CONF}"

        # 2. Generate a fresh replacement secret
        echo "-> Generating fresh replacement secret..."
        NEW_SECRET="$(openssl rand -hex 32 2>/dev/null || od -vN 32 -An -tx1 /dev/urandom | tr -d ' \n')"

        # 3. Write new secret and creation date into config
        set_conf_variable "${TARGET_CONF}" "FLEET_SECRET" "${NEW_SECRET}"
        set_conf_variable "${TARGET_CONF}" "FLEET_SECRET_CREATED_DATE" "${NOW_TS}"
        echo 'FLEET_SECRET_PREVIOUS=""' >> "${TARGET_CONF}"

        # 4. Wipe local replay nonces cache if present
        rm -rf /run/updates-notify/consumed_nonces 2>/dev/null || true

        echo "    Config file:         ${TARGET_CONF}"
        echo "    New Fleet Secret:    ${NEW_SECRET:0:16}... (256-bit)"
        echo "    Previous Secret:     PURGED & REVOKED (zero grace window)"
        echo ""
        prompt_service_restart "Restart remote-update-listener service immediately? (Y/n)" "Y"
    fi

    exit 0
fi

# ==============================================================================
# MODE: Initial Configuration Generation / Non-Destructive Update
# ==============================================================================
if [[ $# -lt 1 ]]; then
    echo "Error: Missing required system group name argument." >&2
    echo "Usage:" >&2
    echo "  Generate / Update:  $0 <system-group-name> [ntfy-valid-user] [output-file]" >&2
    echo "  Routine rotation:   $0 --rotate-secret <system-group-name> [config-file]" >&2
    echo "  Emergency rotation: $0 --rotate-emergency <system-group-name> [config-file]" >&2
    exit 1
fi

SYSTEM_GROUP="$1"
NTFY_USER="${2:-your-ntfy-username}"
OUTPUT_FILE="${3:-${REPO_DIR}/site-conf/${SYSTEM_GROUP}/99-local.conf}"

mkdir -p "$(dirname "${OUTPUT_FILE}")"

if [[ ! -f "${OUTPUT_FILE}" ]]; then
    # 1. Generate unique, high-entropy 16-hex suffix for NTFY topics
    HEX_SUFFIX="$(openssl rand -hex 8 2>/dev/null || od -vN 8 -An -tx1 /dev/urandom | tr -d ' \n')"
    ALERTS_TOPIC="${SYSTEM_GROUP}-alerts-${HEX_SUFFIX}"
    REBOOT_TOPIC="${SYSTEM_GROUP}-reboot-${HEX_SUFFIX}"
    CONTROL_TOPIC="${SYSTEM_GROUP}-control-${HEX_SUFFIX}"

    # 2. Generate 32-byte (256-bit) FLEET_SECRET and creation date
    FLEET_SECRET="$(openssl rand -hex 32 2>/dev/null || od -vN 32 -An -tx1 /dev/urandom | tr -d ' \n')"
    CREATED_TS="$(date +%s)"

    # 3. Write site configuration file matching 99-local.conf.example format
    cat <<EOF > "${OUTPUT_FILE}"
# Host Telemetry & Notification Overrides
# Deploy to /etc/conditional-reboot.conf.d/99-local.conf (chmod 600, root:root)

# NTFY Fleet Topics (3-Channel Architecture)
# NTFY_ALERTS_TOPIC:  Urgent failures (systemd crashes, update failures). ALSO target for Healthchecks.io watchdog!
# NTFY_REBOOT_TOPIC:  Reboot notifications (scheduled, deferred, and boot success confirmation)
# NTFY_CONTROL_TOPIC: Outstanding updates, remote action buttons, and command listener
NTFY_ALERTS_TOPIC="${ALERTS_TOPIC}"
NTFY_REBOOT_TOPIC="${REBOOT_TOPIC}"
NTFY_CONTROL_TOPIC="${CONTROL_TOPIC}"

# Legacy fallback (used only if 3-topic channels above are unset)
# NTFY_TOPIC="${CONTROL_TOPIC}"

NTFY_TOKEN="your-token-here"

# Healthchecks.io Ping URL (Note: In Healthchecks.io dashboard, configure NTFY integration pointing to NTFY_ALERTS_TOPIC)
HC_PING_URL="https://hc-ping.com/your-uuid-here"

# Optional: Dedicated NTFY command topic for remote action button triggers (defaults to NTFY_CONTROL_TOPIC)
# NTFY_CMD_TOPIC="${CONTROL_TOPIC}"

# Optional: Restrict remote action triggers to a verified publisher username (NTFY JSON stream ACL)
NTFY_VALID_USER="${NTFY_USER}"

# Optional: Shared cryptographic secret for HMAC-SHA256 signing of remote action buttons
FLEET_SECRET="${FLEET_SECRET}"
FLEET_SECRET_CREATED_DATE="${CREATED_TS}"
# FLEET_SECRET_PREVIOUS=""

# Maintenance Constraints & Safety Locks
MAINTENANCE_WINDOW_START="02:00"
MAINTENANCE_WINDOW_END="05:00"
REBOOT_DELAY_MINUTES="5"
BLOCKED_PROCESSES=("apt" "apt-get" "dpkg" "unattended-upgrade" "dnf" "yum" "rpm" "check-updates" "backup_job" "db_migration" "rsync")
EOF

    chmod 0600 "${OUTPUT_FILE}"

    echo "==> Site configuration generated successfully!"
    echo "    File:             ${OUTPUT_FILE}"
    echo "    System Group:     ${SYSTEM_GROUP}"
    echo "    Alerts Topic:     ${ALERTS_TOPIC} (urgent errors; target for Healthchecks watchdog)"
    echo "    Reboot Topic:     ${REBOOT_TOPIC} (scheduled reboots, deferrals, boot success)"
    echo "    Control Topic:    ${CONTROL_TOPIC} (updates, action buttons, command listener)"
    echo "    Fleet Secret:     ${FLEET_SECRET:0:16}... (private 256-bit key, completely independent from topics)"
    echo "    Created:          ${CREATED_TS}"
    echo "    NTFY User:        ${NTFY_USER}"
    echo ""
    echo "Note: The NTFY topics and Fleet Secret are separate, independent items."
    echo "      Topics appear in URLs; the secret remains strictly confidential on disk."
    echo "Next step: Open ${OUTPUT_FILE} and fill in your NTFY_TOKEN and HC_PING_URL."

else
    # Existing file: Strictly preserve any defined NTFY topics and existing FLEET_SECRET
    echo "-> Existing configuration found at: ${OUTPUT_FILE}"
    echo "   Checking for missing settings (strictly preserving all defined topics and secrets)..."

    BACKUP_FILE="${OUTPUT_FILE}.$(date +%Y%m%d-%H%M%S).bak"
    cp -p "${OUTPUT_FILE}" "${BACKUP_FILE}"

    file_modified=0
    HEX_SUFFIX=""

    get_hex_suffix() {
        if [[ -z "${HEX_SUFFIX}" ]]; then
            HEX_SUFFIX="$(openssl rand -hex 8 2>/dev/null || od -vN 8 -An -tx1 /dev/urandom | tr -d ' \n')"
        fi
        echo "${HEX_SUFFIX}"
    }

    # 1. NTFY Topics: Preserve if defined; only generate if completely missing
    if grep -qE "^[[:space:]]*NTFY_ALERTS_TOPIC=" "${OUTPUT_FILE}"; then
        echo "   [PRESERVED] NTFY_ALERTS_TOPIC is already defined."
    else
        suffix="$(get_hex_suffix)"
        new_topic="${SYSTEM_GROUP}-alerts-${suffix}"
        set_conf_variable "${OUTPUT_FILE}" "NTFY_ALERTS_TOPIC" "${new_topic}"
        echo "   [ADDED] Generated missing NTFY_ALERTS_TOPIC: ${new_topic}"
        file_modified=1
    fi

    if grep -qE "^[[:space:]]*NTFY_REBOOT_TOPIC=" "${OUTPUT_FILE}"; then
        echo "   [PRESERVED] NTFY_REBOOT_TOPIC is already defined."
    else
        suffix="$(get_hex_suffix)"
        new_topic="${SYSTEM_GROUP}-reboot-${suffix}"
        set_conf_variable "${OUTPUT_FILE}" "NTFY_REBOOT_TOPIC" "${new_topic}"
        echo "   [ADDED] Generated missing NTFY_REBOOT_TOPIC: ${new_topic}"
        file_modified=1
    fi

    if grep -qE "^[[:space:]]*NTFY_CONTROL_TOPIC=" "${OUTPUT_FILE}"; then
        echo "   [PRESERVED] NTFY_CONTROL_TOPIC is already defined."
    else
        suffix="$(get_hex_suffix)"
        new_topic="${SYSTEM_GROUP}-control-${suffix}"
        set_conf_variable "${OUTPUT_FILE}" "NTFY_CONTROL_TOPIC" "${new_topic}"
        echo "   [ADDED] Generated missing NTFY_CONTROL_TOPIC: ${new_topic}"
        file_modified=1
    fi

    # 2. FLEET_SECRET: Preserve existing secret; only generate if missing
    if grep -qE "^[[:space:]]*FLEET_SECRET=" "${OUTPUT_FILE}"; then
        echo "   [PRESERVED] FLEET_SECRET is already defined (use --rotate-secret or --rotate-emergency to rotate)."
    else
        new_secret="$(openssl rand -hex 32 2>/dev/null || od -vN 32 -An -tx1 /dev/urandom | tr -d ' \n')"
        now_ts="$(date +%s)"
        set_conf_variable "${OUTPUT_FILE}" "FLEET_SECRET" "${new_secret}"
        set_conf_variable "${OUTPUT_FILE}" "FLEET_SECRET_CREATED_DATE" "${now_ts}"
        echo "   [ADDED] Generated missing FLEET_SECRET: ${new_secret:0:16}... (256-bit)"
        file_modified=1
    fi

    # 3. NTFY_VALID_USER
    if grep -qE "^[[:space:]]*#?[[:space:]]*NTFY_VALID_USER=" "${OUTPUT_FILE}"; then
        echo "   [PRESERVED] NTFY_VALID_USER is already present."
    elif [[ "${NTFY_USER}" != "your-ntfy-username" ]]; then
        set_conf_variable "${OUTPUT_FILE}" "NTFY_VALID_USER" "${NTFY_USER}"
        echo "   [ADDED] Added NTFY_VALID_USER: ${NTFY_USER}"
        file_modified=1
    fi

    # 4. Sync missing general settings from template (e.g. REBOOT_DELAY_MINUTES, BLOCKED_PROCESSES)
    EXAMPLE_CONF="${REPO_DIR}/conf/99-local.conf.example"
    if [[ -f "${EXAMPLE_CONF}" ]]; then
        while IFS= read -r line || [[ -n "${line}" ]]; do
            if [[ "${line}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]]; then
                var_name="${BASH_REMATCH[1]}"
                case "${var_name}" in
                    NTFY_ALERTS_TOPIC|NTFY_REBOOT_TOPIC|NTFY_CONTROL_TOPIC|NTFY_TOPIC|FLEET_SECRET|FLEET_SECRET_CREATED_DATE|FLEET_SECRET_PREVIOUS|NTFY_VALID_USER)
                        continue
                        ;;
                esac
                if ! grep -qE "^[[:space:]]*#?[[:space:]]*${var_name}=" "${OUTPUT_FILE}"; then
                    echo "" >> "${OUTPUT_FILE}"
                    echo "${line}" >> "${OUTPUT_FILE}"
                    echo "   [ADDED] Merged template parameter '${var_name}' into site config."
                    file_modified=1
                fi
            fi
        done < "${EXAMPLE_CONF}"
    fi

    chmod 0600 "${OUTPUT_FILE}"

    if (( file_modified == 1 )); then
        echo "==> Configuration updated successfully while strictly preserving all existing topics and secrets!"
    else
        rm -f "${BACKUP_FILE}"
        echo "==> Configuration is already up to date. All defined topics and Fleet Secret were untouched."
    fi
fi
