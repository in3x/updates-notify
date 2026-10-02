#!/usr/bin/env bash
# ==============================================================================
# apt-post-install-telemetry.sh
#
# PURPOSE:
#   Post-installation hook executed by unattended-upgrades on Debian/Ubuntu.
#
# HOW IT IS TRIGGERED:
#   Configured in /etc/apt/apt.conf.d/99unattended-upgrades-local via:
#     Unattended-Upgrade::PostInstallScript "/usr/local/bin/apt-post-install-telemetry.sh";
#
# LIFECYCLE & TIMING:
#   1. APT/unattended-upgrades only invokes this script AFTER all packages
#      have been successfully downloaded, unpacked, and installed.
#   2. If package installation fails mid-way, APT halts and this script NEVER runs.
#   3. Therefore, simply reaching the body of this script is proof that the latest
#      package update run completed successfully.
#   4. Removing /run/package-update.failed here clears any prior failure flag,
#      signaling to conditional-reboot.sh that it is once again safe to reboot.
# ==============================================================================
set -euo pipefail

FAIL_FLAG_FILE="/run/package-update.failed"

# 1. Early bootstrap trap (before sourcing common library)
trap 'echo "Fatal: Early execution error on line $LINENO before common library loaded" >&2; touch "${FAIL_FLAG_FILE}"; exit 1' ERR

# 2. Source common telemetry library and register full failure handler
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common-telemetry.sh"
trap 'touch "${FAIL_FLAG_FILE}"; failure_handler ${LINENO}' ERR

# 3. Clear any prior failure flag (unblocks conditional-reboot.sh)
rm -f "${FAIL_FLAG_FILE}"

# 4. Log successful completion to syslog/journald
logger -t apt-post-install "Unattended-upgrades completed successfully on ${HOSTNAME}."

exit 0
