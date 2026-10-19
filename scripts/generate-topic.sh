#!/usr/bin/env bash
# ==============================================================================
# generate-topic.sh
#
# Generates a site-specific configuration file in the format of 99-local.conf.example:
#   1. Unique & secure NTFY topic name (<prefix>-<system-group>-updates-<16-hex>)
#   2. Cryptographic FLEET_SECRET (32-byte / 256-bit hex key)
#   3. NTFY valid user for ACL enforcement
#
# Usage:
#   ./scripts/generate-topic.sh <system-group-name> [ntfy-valid-user] [output-file]
#
# Example:
#   ./scripts/generate-topic.sh homelab eric
#   -> Writes to site-conf/homelab/99-local.conf (chmod 0600)
# ==============================================================================
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Error: Missing required system group name argument." >&2
    echo "Usage: $0 <system-group-name> [ntfy-valid-user] [output-file]" >&2
    echo "Example: $0 homelab eric" >&2
    echo "         $0 pond eric site-conf/pond/99-local.conf" >&2
    exit 1
fi

SYSTEM_GROUP="$1"
NTFY_USER="${2:-your-ntfy-username}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUTPUT_FILE="${3:-${REPO_DIR}/site-conf/${SYSTEM_GROUP}/99-local.conf}"

# 1. Generate unique, high-entropy 16-hex suffix for NTFY topic
HEX_SUFFIX="$(openssl rand -hex 8 2>/dev/null || od -vN 8 -An -tx1 /dev/urandom | tr -d ' \n')"
TOPIC="pw-${SYSTEM_GROUP}-updates-${HEX_SUFFIX}"

# 2. Generate 32-byte (256-bit) FLEET_SECRET for HMAC-SHA256 signature verification
FLEET_SECRET="$(openssl rand -hex 32 2>/dev/null || od -vN 32 -An -tx1 /dev/urandom | tr -d ' \n')"

# 3. Create destination directory
mkdir -p "$(dirname "${OUTPUT_FILE}")"

# 4. Write site configuration file matching 99-local.conf.example format
cat <<EOF > "${OUTPUT_FILE}"
# Host Telemetry & Notification Overrides
# Deploy to /etc/conditional-reboot.conf.d/99-local.conf (chmod 600, root:root)

NTFY_TOPIC="${TOPIC}"
NTFY_TOKEN="your-token-here"
HC_PING_URL="https://hc-ping.com/your-uuid-here"

# Optional: Dedicated NTFY command topic for remote action button triggers (defaults to <NTFY_TOPIC>-cmd)
# NTFY_CMD_TOPIC="${TOPIC}-cmd"

# Optional: Restrict remote action triggers to a verified publisher username (NTFY JSON stream ACL)
NTFY_VALID_USER="${NTFY_USER}"

# Optional: Shared cryptographic secret for HMAC-SHA256 signing of remote action buttons
FLEET_SECRET="${FLEET_SECRET}"

# Maintenance Constraints & Safety Locks
MAINTENANCE_WINDOW_START="02:00"
MAINTENANCE_WINDOW_END="05:00"
REBOOT_DELAY_MINUTES="5"
BLOCKED_PROCESSES=("apt" "apt-get" "dpkg" "unattended-upgrade" "dnf" "yum" "rpm" "check-updates" "backup_job" "db_migration" "rsync")
EOF

chmod 0600 "${OUTPUT_FILE}"

echo "==> Site configuration generated successfully!"
echo "    File:         ${OUTPUT_FILE}"
echo "    System Group: ${SYSTEM_GROUP}"
echo "    NTFY Topic:   ${TOPIC}"
echo "    Fleet Secret: ${FLEET_SECRET:0:16}... (256-bit)"
echo "    NTFY User:    ${NTFY_USER}"
echo ""
echo "Next step: Open ${OUTPUT_FILE} and fill in your NTFY_TOKEN and HC_PING_URL."
