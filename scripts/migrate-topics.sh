#!/usr/bin/env bash
# ==============================================================================
# migrate-topics.sh
#
# PURPOSE:
#   Dedicated standalone utility to migrate site configurations from the
#   legacy flat NTFY topic format to the new hierarchical topic architecture:
#
#   Old Format:  pw-<group>-<subtopic>-<16_hex>
#   New Format:  <16_hex>-<group>-<subtopic>
#
#   Subtopics:   -alerts, -reboot, -control
#
# USAGE:
#   Interactive menu:  ./scripts/migrate-topics.sh
#   Direct execution:  ./scripts/migrate-topics.sh <system-group-name>
#
# NOTE:
#   This is a standalone migration tool. It can be safely archived or deleted
#   once your group configurations have been converted.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Helper: validate topic name against NTFY constraints (max 64 chars, legal chars)
validate_topic_name() {
    local topic="$1"
    local len="${#topic}"

    if (( len > 64 )); then
        echo "Error: Target topic name '${topic}' exceeds NTFY's 64-character limit (length: ${len})." >&2
        echo "       Please use a shorter system group name (39 characters or fewer)." >&2
        exit 1
    fi

    if [[ ! "${topic}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "Error: Target topic name '${topic}' contains invalid characters." >&2
        echo "       NTFY topics may only contain letters, numbers, underscores, and hyphens." >&2
        exit 1
    fi
}
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

SYSTEM_GROUP="${1:-}"

# 1. Interactive selection if no argument is passed
if [[ -z "${SYSTEM_GROUP}" ]]; then
    shopt -s nullglob
    available_groups=()
    if [[ -d "${REPO_DIR}/site-conf" ]]; then
        for dir in "${REPO_DIR}/site-conf"/*/; do
            dir_name="$(basename "${dir}")"
            conf_files=("${dir}"*.conf)
            if (( ${#conf_files[@]} > 0 )); then
                available_groups+=("${dir_name}")
            fi
        done
    fi
    shopt -u nullglob

    if (( ${#available_groups[@]} == 0 )); then
        echo "Error: No site configurations found in ${REPO_DIR}/site-conf/." >&2
        exit 1
    fi

    echo "Available configurations in site-conf/:"
    for i in "${!available_groups[@]}"; do
        echo "  $(( i + 1 ))) ${available_groups[i]}"
    done
    echo ""

    while true; do
        read -r -p "Select a configuration to migrate [1-${#available_groups[@]} or 'q' to quit]: " selection
        if [[ "${selection}" =~ ^[Qq]$ ]]; then
            echo "Migration cancelled by user." >&2
            exit 0
        fi
        if [[ "${selection}" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#available_groups[@]} )); then
            SYSTEM_GROUP="${available_groups[$(( selection - 1 ))]}"
            break
        else
            echo "Invalid selection. Please enter a number between 1 and ${#available_groups[@]}."
        fi
    done
fi

SITE_CONF_DIR="${REPO_DIR}/site-conf/${SYSTEM_GROUP}"
if [[ ! -d "${SITE_CONF_DIR}" ]]; then
    echo "Error: Site configuration directory not found: ${SITE_CONF_DIR}" >&2
    exit 1
fi

TARGET_CONF=""
if [[ -f "${SITE_CONF_DIR}/99-local.conf" ]]; then
    TARGET_CONF="${SITE_CONF_DIR}/99-local.conf"
else
    shopt -s nullglob
    conf_matches=("${SITE_CONF_DIR}"/*.conf)
    shopt -u nullglob
    if (( ${#conf_matches[@]} > 0 )); then
        TARGET_CONF="${conf_matches[0]}"
    else
        echo "Error: No .conf file found in ${SITE_CONF_DIR}." >&2
        exit 1
    fi
fi

echo "==> Inspecting configuration: ${TARGET_CONF}"

# 2. Extract current topics
OLD_ALERTS=""
OLD_REBOOT=""
OLD_CONTROL=""

[[ -f "${TARGET_CONF}" ]] && OLD_ALERTS="$(grep -E '^[[:space:]]*NTFY_ALERTS_TOPIC=' "${TARGET_CONF}" | head -n 1 | cut -d= -f2- | tr -d '"'\'' ' || true)"
[[ -f "${TARGET_CONF}" ]] && OLD_REBOOT="$(grep -E '^[[:space:]]*NTFY_REBOOT_TOPIC=' "${TARGET_CONF}" | head -n 1 | cut -d= -f2- | tr -d '"'\'' ' || true)"
[[ -f "${TARGET_CONF}" ]] && OLD_CONTROL="$(grep -E '^[[:space:]]*NTFY_CONTROL_TOPIC=' "${TARGET_CONF}" | head -n 1 | cut -d= -f2- | tr -d '"'\'' ' || true)"

# 3. Extract existing 16-hex salt from old topic names to preserve entropy
HEX_SALT=""
for old_topic in "${OLD_ALERTS}" "${OLD_REBOOT}" "${OLD_CONTROL}"; do
    if [[ "${old_topic}" =~ ([0-9a-fA-F]{16}) ]]; then
        HEX_SALT="${BASH_REMATCH[1]}"
        break
    fi
done

if [[ -n "${HEX_SALT}" ]]; then
    echo "   [SALT DETECTED] Preserving existing random 16-hex salt: ${HEX_SALT}"
else
    HEX_SALT="$(openssl rand -hex 8 2>/dev/null || od -vN 8 -An -tx1 /dev/urandom | tr -d ' \n')"
    echo "   [SALT GENERATED] Generated fresh random 16-hex salt: ${HEX_SALT}"
fi

# 4. Construct new prefix-based topics
NEW_ALERTS="${HEX_SALT}-${SYSTEM_GROUP}-alerts"
NEW_REBOOT="${HEX_SALT}-${SYSTEM_GROUP}-reboot"
NEW_CONTROL="${HEX_SALT}-${SYSTEM_GROUP}-control"

validate_topic_name "${NEW_ALERTS}"
validate_topic_name "${NEW_REBOOT}"
validate_topic_name "${NEW_CONTROL}"

# Check if already migrated
if [[ "${OLD_ALERTS}" == "${NEW_ALERTS}" && "${OLD_REBOOT}" == "${NEW_REBOOT}" && "${OLD_CONTROL}" == "${NEW_CONTROL}" ]]; then
    echo ""
    echo "   [ALREADY MIGRATED] Topics in ${TARGET_CONF} are already using the prefix format:"
    echo "     Alerts:  ${OLD_ALERTS}"
    echo "     Reboot:  ${OLD_REBOOT}"
    echo "     Control: ${OLD_CONTROL}"
    echo ""
    echo "No migration needed."
    exit 0
fi

echo ""
echo "=== Planned Topic Migration ==="
echo "  Group:    ${SYSTEM_GROUP}"
echo "  Alerts:   ${OLD_ALERTS:-<none>}  ==>  ${NEW_ALERTS}"
echo "  Reboot:   ${OLD_REBOOT:-<none>}  ==>  ${NEW_REBOOT}"
echo "  Control:  ${OLD_CONTROL:-<none>}  ==>  ${NEW_CONTROL}"
echo "==============================="
echo ""

read -r -p "Apply this migration to ${TARGET_CONF}? [Y/n]: " confirm
confirm="${confirm:-Y}"
if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
    echo "Migration aborted by user." >&2
    exit 0
fi

# 5. Create backup before modifying
BACKUP_FILE="${TARGET_CONF}.$(date +%Y%m%d-%H%M%S).bak"
cp -p "${TARGET_CONF}" "${BACKUP_FILE}"
echo "-> Saved backup: ${BACKUP_FILE}"

# 6. Apply migration in-place
set_conf_variable "${TARGET_CONF}" "NTFY_ALERTS_TOPIC" "${NEW_ALERTS}"
set_conf_variable "${TARGET_CONF}" "NTFY_REBOOT_TOPIC" "${NEW_REBOOT}"
set_conf_variable "${TARGET_CONF}" "NTFY_CONTROL_TOPIC" "${NEW_CONTROL}"

# If NTFY_CMD_TOPIC is present, update it to match the new control topic
if grep -qE "^[[:space:]]*#?[[:space:]]*NTFY_CMD_TOPIC=" "${TARGET_CONF}"; then
    if grep -qE "^[[:space:]]*NTFY_CMD_TOPIC=" "${TARGET_CONF}"; then
        set_conf_variable "${TARGET_CONF}" "NTFY_CMD_TOPIC" "${NEW_CONTROL}"
    fi
fi

chmod 0600 "${TARGET_CONF}"

echo ""
echo "==> Migration complete for group '${SYSTEM_GROUP}'!"
echo "    Updated config: ${TARGET_CONF}"
echo ""
echo "Next Steps:"
echo "  1. Update external subscriptions:"
echo "     - Subscribe your phone/desktop NTFY app to: ${NEW_ALERTS}, ${NEW_REBOOT}, ${NEW_CONTROL}"
echo "     - In Healthchecks.io dashboard, update NTFY integration topic to: ${NEW_ALERTS}"
echo ""
echo "  2. Deploy updated topics to managed hosts:"
echo "     sudo ./deploy.sh ${SYSTEM_GROUP}"
echo ""
echo "  3. Once all hosts and clients are updated, delete this migration tool:"
echo "     rm ./scripts/migrate-topics.sh"
