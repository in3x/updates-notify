#!/usr/bin/env bash
set -euo pipefail

# 1. REGISTER BOOTSTRAP TRAP BEFORE ANY SOURCING OR PATH EXPANSION
trap 'echo "Fatal: Early execution error on line $LINENO before common library loaded" >&2; exit 1' ERR

# 2. Source Common Functions & Upgrade to Full Failure Handler
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common-telemetry.sh"
trap 'failure_handler ${LINENO}' ERR

# 3. Script Logic, Defaults & OS Family Detection
MAINTENANCE_WINDOW_START="${MAINTENANCE_WINDOW_START:-02:00}"
MAINTENANCE_WINDOW_END="${MAINTENANCE_WINDOW_END:-05:00}"
REBOOT_DELAY_MINUTES="${REBOOT_DELAY_MINUTES:-5}"

OS_FAMILY="unknown"
if [[ -f /etc/debian_version ]]; then
    OS_FAMILY="debian"
elif [[ -f /etc/redhat-release ]]; then
    OS_FAMILY="rhel"
fi

if [[ -z "${BLOCKED_PROCESSES+x}" ]]; then
    BLOCKED_PROCESSES=("backup_job" "db_migration" "rsync" "check-updates")
    case "${OS_FAMILY}" in
        debian)
            BLOCKED_PROCESSES+=("apt" "apt-get" "dpkg" "unattended-upgrade")
            ;;
        rhel)
            BLOCKED_PROCESSES+=("dnf" "yum" "rpm")
            ;;
        *)
            BLOCKED_PROCESSES+=("apt" "apt-get" "dpkg" "unattended-upgrade" "dnf" "yum" "rpm")
            ;;
    esac
fi

FAIL_FLAG_FILE="/run/package-update.failed"

# 4. Check If Reboot Is Required (Distro-Isolated Detection)
REBOOT_REQUIRED=false
TRIGGER_PKGS=""

case "${OS_FAMILY}" in
    debian)
        if [[ -f /run/reboot-required || -f /var/run/reboot-required ]]; then
            REBOOT_REQUIRED=true
            if [[ -s /run/reboot-required.pkgs ]]; then
                TRIGGER_PKGS=$(paste -sd ', ' /run/reboot-required.pkgs 2>/dev/null || tr '\n' ' ' < /run/reboot-required.pkgs)
            elif [[ -s /var/run/reboot-required.pkgs ]]; then
                TRIGGER_PKGS=$(paste -sd ', ' /var/run/reboot-required.pkgs 2>/dev/null || tr '\n' ' ' < /var/run/reboot-required.pkgs)
            fi
        fi
        ;;
    rhel)
        if command -v needs-restarting >/dev/null 2>&1; then
            if ! needs-restarting -r >/dev/null 2>&1; then
                REBOOT_REQUIRED=true
                TRIGGER_PKGS=$(needs-restarting -r 2>/dev/null | grep -E '^/' | paste -sd ', ' - || true)
            fi
        elif command -v dnf >/dev/null 2>&1 && dnf needs-restarting --help >/dev/null 2>&1; then
            if ! dnf needs-restarting -r >/dev/null 2>&1; then
                REBOOT_REQUIRED=true
                TRIGGER_PKGS=$(dnf needs-restarting -r 2>/dev/null | grep -E '^/' | paste -sd ', ' - || true)
            fi
        else
            logger -t conditional-reboot "Warning: RHEL host missing 'needs-restarting' utility."
        fi
        ;;
    *)
        if [[ -f /run/reboot-required || -f /var/run/reboot-required ]]; then
            REBOOT_REQUIRED=true
        elif command -v needs-restarting >/dev/null 2>&1 && ! needs-restarting -r >/dev/null 2>&1; then
            REBOOT_REQUIRED=true
        fi
        ;;
esac

if [[ "${REBOOT_REQUIRED}" == "false" ]]; then
    logger -t conditional-reboot "No reboot required."
    rm -f /run/updates-notify/reboot_deferred_reported /run/updates-notify/reboot_outside_window_reported 2>/dev/null || true
    ping_hc ""
    exit 0
fi

PKG_INFO=""
if [[ -n "${TRIGGER_PKGS}" ]]; then
    PKG_INFO=" (packages: ${TRIGGER_PKGS})"
    logger -t conditional-reboot "Reboot required by: ${TRIGGER_PKGS}"
fi

# 5. Multi-Condition Safety Audit (Hard vs. Soft Blockers)
# Collect all active conditions across the entire system without early exit
hard_blocks=()
soft_blocks=()
audit_log_entries=()

# Check A: Prior Package Installation Failure
if [[ -f "${FAIL_FLAG_FILE}" ]]; then
    hard_blocks+=("Prior package installation failure flag (${FAIL_FLAG_FILE}) detected")
    audit_log_entries+=("[Hard] package_failure: ${FAIL_FLAG_FILE}")
fi

# Check B: Package Manager Locks Held
PKG_LOCK_FILES=()
case "${OS_FAMILY}" in
    debian)
        PKG_LOCK_FILES=("/var/lib/dpkg/lock-frontend" "/var/lib/dpkg/lock" "/var/lib/apt/lists/lock")
        ;;
    rhel)
        # RHEL 10 (DNF 5) uses /run/lock/libdnf5; RHEL 8/9 uses granular DNF 4 locks
        PKG_LOCK_FILES=(
            "/run/lock/libdnf5"
            "/var/lib/dnf/rpmdb_lock.pid"
            "/var/cache/dnf/download_lock.pid"
            "/var/cache/dnf/metadata_lock.pid"
            "/var/lib/rpm/.rpm.lock"
            "/var/run/yum.pid"
        )
        ;;
    *)
        PKG_LOCK_FILES=("/var/lib/dpkg/lock-frontend" "/var/run/dnf.pid")
        ;;
esac

for lock_file in "${PKG_LOCK_FILES[@]}"; do
    if [[ -f "${lock_file}" ]] && command -v fuser >/dev/null 2>&1 && fuser "${lock_file}" >/dev/null 2>&1; then
        lock_pid=$(fuser "${lock_file}" 2>/dev/null | tr -d ' ' || echo "active")
        hard_blocks+=("Package manager lock held on '${lock_file}' (PID: ${lock_pid})")
        audit_log_entries+=("[Hard] pkg_lock: ${lock_file} (PID: ${lock_pid})")
    fi
done

# Check C: Blocked Background Processes
for proc in "${BLOCKED_PROCESSES[@]}"; do
    if pgrep -f "${proc}" >/dev/null 2>&1; then
        pids=$(pgrep -f "${proc}" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        hard_blocks+=("Blocked process '${proc}' is active (PIDs: ${pids})")
        audit_log_entries+=("[Hard] blocked_process: ${proc} (PIDs: ${pids})")
    fi
done

# Check D: Maintenance Window
CURRENT_TIME=$(date +%H:%M)
IN_WINDOW=true
if [[ "${CURRENT_TIME}" < "${MAINTENANCE_WINDOW_START}" || "${CURRENT_TIME}" > "${MAINTENANCE_WINDOW_END}" ]]; then
    IN_WINDOW=false
    soft_blocks+=("Outside maintenance window (current: ${CURRENT_TIME}, window: ${MAINTENANCE_WINDOW_START}-${MAINTENANCE_WINDOW_END})")
    audit_log_entries+=("[Soft] outside_window: ${CURRENT_TIME} (window: ${MAINTENANCE_WINDOW_START}-${MAINTENANCE_WINDOW_END})")
fi

# Check E: Active User Sessions with Detailed Accounting
active_sessions=()
while IFS= read -r who_line; do
    [[ -z "${who_line}" ]] && continue
    u_name=$(echo "${who_line}" | awk '{print $1}')
    [[ "${u_name}" == "root" ]] && continue
    u_tty=$(echo "${who_line}" | awk '{print $2}')
    u_from=$(echo "${who_line}" | awk '{print $5}' | tr -d '()')
    u_uid=$(id -u "${u_name}" 2>/dev/null || echo "unknown")
    active_sessions+=("${u_name} (UID:${u_uid}, TTY:${u_tty}${u_from:+, From:${u_from}})")
done < <(who 2>/dev/null || true)

if (( ${#active_sessions[@]} > 0 )); then
    formatted_users="$(IFS=, ; echo "${active_sessions[*]}")"
    formatted_users="${formatted_users//,/, }"
    soft_blocks+=("Active user sessions: ${formatted_users}")
    audit_log_entries+=("[Soft] user_sessions: ${formatted_users}")
fi

TOTAL_BLOCKS=$(( ${#hard_blocks[@]} + ${#soft_blocks[@]} ))

# 6. Evaluation & Action
if (( TOTAL_BLOCKS == 0 )); then
    # All safety checks passed! Clear state flags and trigger reboot
    rm -f /run/updates-notify/reboot_deferred_reported /run/updates-notify/reboot_outside_window_reported 2>/dev/null || true

    logger -t conditional-reboot "All safety checks passed. Triggering intentional system reboot.${PKG_INFO}"
    send_ntfy "reboot" "🔄 Reboot Scheduled" "Intentional maintenance reboot scheduled on ${HOSTNAME} by conditional-reboot utility. All safety checks passed.${PKG_INFO} System will reboot in ${REBOOT_DELAY_MINUTES} minutes." "high"
    send_ntfy "alerts" "🔄 Reboot Scheduled" "Intentional maintenance reboot scheduled on ${HOSTNAME} by conditional-reboot utility. All safety checks passed.${PKG_INFO} System will reboot in ${REBOOT_DELAY_MINUTES} minutes." "high"
    ping_hc ""
    shutdown -r "+${REBOOT_DELAY_MINUTES}" "Automated maintenance reboot scheduled in ${REBOOT_DELAY_MINUTES} minutes by conditional-reboot utility."
    exit 0
fi

# 7. Record Full Multi-Condition Audit Log (Persistent Historical Record)
BLOCKS_LOG="/var/log/reboot-blocks.log"
mkdir -p "$(dirname "${BLOCKS_LOG}")"
{
    echo "=============================================================================="
    echo "$(date '+%Y-%m-%d %H:%M:%S') [DEFERRED] Host: ${HOSTNAME} | Packages: ${TRIGGER_PKGS:-system}"
    for entry in "${audit_log_entries[@]}"; do
        echo "   ${entry}"
    done
} >> "${BLOCKS_LOG}"

logger -t conditional-reboot "Reboot deferred (${TOTAL_BLOCKS} active conditions): ${audit_log_entries[*]}"

# 8. Notification & Silent Retry Management
mkdir -p /run/updates-notify

BLOCKER_BODY="Reboot required on ${HOSTNAME}${PKG_INFO}.\n\nACTIVE BLOCKING REASONS:"
if (( ${#hard_blocks[@]} > 0 )); then
    BLOCKER_BODY="${BLOCKER_BODY}\nHard Blocks (Safety Critical):"
    for hb in "${hard_blocks[@]}"; do
        BLOCKER_BODY="${BLOCKER_BODY}\n  ⛔ ${hb}"
    done
fi
if (( ${#soft_blocks[@]} > 0 )); then
    BLOCKER_BODY="${BLOCKER_BODY}\nSoft Blocks (Operational / Convenience):"
    for sb in "${soft_blocks[@]}"; do
        BLOCKER_BODY="${BLOCKER_BODY}\n  ℹ️ ${sb}"
    done
fi

if [[ "${IN_WINDOW}" == "true" ]]; then
    # Inside window: Send ONE alert at start of blockage, then retry silently every 15m
    if [[ ! -f /run/updates-notify/reboot_deferred_reported ]]; then
        touch /run/updates-notify/reboot_deferred_reported
        BLOCKER_BODY="${BLOCKER_BODY}\n\nRetrying silently every 15 minutes until maintenance window closes at ${MAINTENANCE_WINDOW_END}."
        send_ntfy "reboot" "ℹ️ Reboot Deferred" "${BLOCKER_BODY}" "high"
        send_ntfy "alerts" "ℹ️ Reboot Deferred" "${BLOCKER_BODY}" "high"
    else
        logger -t conditional-reboot "Silent in-window retry: conditions still blocked. No duplicate alert dispatched."
    fi
else
    # Outside window: Send ONE pending notice per boot session
    if [[ ! -f /run/updates-notify/reboot_outside_window_reported ]]; then
        touch /run/updates-notify/reboot_outside_window_reported
        BLOCKER_BODY="${BLOCKER_BODY}\n\nExecution scheduled for maintenance window (${MAINTENANCE_WINDOW_START}-${MAINTENANCE_WINDOW_END})."
        send_ntfy "reboot" "ℹ️ Reboot Pending" "${BLOCKER_BODY}" "default"
    fi
fi

if [[ -f "${FAIL_FLAG_FILE}" ]]; then
    ping_hc "fail"
    exit 1
fi

ping_hc ""
exit 0
