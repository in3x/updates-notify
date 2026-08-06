#!/usr/bin/env bash
set -euo pipefail

# 1. REGISTER BOOTSTRAP TRAP BEFORE ANY SOURCING OR PATH EXPANSION
trap 'echo "Fatal: Early execution error on line $LINENO before common library loaded" >&2; touch /var/run/apt-update.failed; exit 1' ERR

# 2. Source Common Functions & Upgrade to Full Failure Handler
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common-telemetry.sh"
trap 'failure_handler ${LINENO}' ERR

# 3. Main Logic
FAIL_FLAG_FILE="/var/run/apt-update.failed"

if [[ -f "${FAIL_FLAG_FILE}" ]]; then
    rm -f "${FAIL_FLAG_FILE}"
fi

logger -t apt-post-install "Unattended-upgrades completed successfully on $(hostname)."

exit 0
