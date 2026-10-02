#!/usr/bin/env bash
set -euo pipefail

# 1. REGISTER BOOTSTRAP TRAP BEFORE ANY SOURCING OR PATH EXPANSION
trap 'echo "Fatal: Deploy script failed on line $LINENO" >&2; exit 1' ERR

echo "==> Deploying updates-notify pipeline to system..."

# Ensure root privileges
if [[ $EUID -ne 0 ]]; then
   echo "Error: This deployment script must be run as root." >&2
   exit 1
fi

# 2. Check Prerequisites for RHEL/Ubuntu (Hard Exit if Missing)
if [[ -f /etc/redhat-release ]]; then
    MISSING_RHEL_PKGS=()
    if ! command -v needs-restarting >/dev/null 2>&1; then
        MISSING_RHEL_PKGS+=("dnf-utils")
    fi
    if ! command -v dnf-automatic >/dev/null 2>&1; then
        MISSING_RHEL_PKGS+=("dnf-automatic")
    fi

    if [[ ${#MISSING_RHEL_PKGS[@]} -gt 0 ]]; then
        echo "Error: Missing required RHEL package(s): ${MISSING_RHEL_PKGS[*]}" >&2
        echo "Please install them before deploying: sudo dnf install -y ${MISSING_RHEL_PKGS[*]}" >&2
        exit 1
    fi
elif [[ -f /etc/debian_version ]]; then
    if ! command -v unattended-upgrade >/dev/null 2>&1; then
        echo "Error: 'unattended-upgrades' package is not installed." >&2
        echo "Please install it before deploying: sudo apt-get install -y unattended-upgrades" >&2
        exit 1
    fi
fi

# 3. Check for etckeeper
if ! command -v etckeeper >/dev/null 2>&1; then
    echo ""
    echo "⚠️  WARNING: 'etckeeper' is not installed on this system."
    echo "   Using etckeeper is recommended to track /etc changes in version control."
    read -r -p "   Proceed deployment without etckeeper? [y/N]: " etckeeper_choice
    if [[ ! "${etckeeper_choice}" =~ ^[Yy]$ ]]; then
        echo "   Deployment aborted by user. Install etckeeper and run deploy.sh again." >&2
        exit 1
    fi
else
    echo "-> etckeeper detected. Staging /etc state prior to installation..."
    etckeeper pre-install || true
fi

# Detect repository root directory
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Interactive File Installation Helper
install_file_safely() {
    local src="$1"
    local dest="$2"
    local mode="${3:-0644}"
    local owner="${4:-root}"
    local group="${5:-root}"

    mkdir -p "$(dirname "${dest}")"

    if [[ -f "${dest}" ]]; then
        if cmp -s "${src}" "${dest}"; then
            echo "   [UNCHANGED] ${dest}"
            chmod "${mode}" "${dest}"
            chown "${owner}:${group}" "${dest}"
            return 0
        fi

        echo "   [DIFF DETECTED] ${dest} exists and differs from source."

        while true; do
            local choice
            read -r -p "   Action for ${dest} [y=Overwrite / d=Show diff / n=Skip / c=Cancel]: " choice
            case "${choice}" in
                [Dd]*)
                    echo "   --- Diff (${dest} -> ${src}) ---"
                    diff -u "${dest}" "${src}" || true
                    echo "   ---------------------------------"
                    ;;
                [Yy]*)
                    echo "   Overwriting ${dest}..."
                    break
                    ;;
                [Nn]*)
                    echo "   Skipping ${dest} content update (enforcing permissions)..."
                    chmod "${mode}" "${dest}"
                    chown "${owner}:${group}" "${dest}"
                    return 0
                    ;;
                [Cc]*)
                    echo "   Deployment cancelled by user." >&2
                    exit 1
                    ;;
                *)
                    echo "   Invalid option. Select y, d, n, or c."
                    ;;
            esac
        done
    else
        echo "   [NEW FILE] Installing ${dest}"
    fi

    install -m "${mode}" -o "${owner}" -g "${group}" "${src}" "${dest}"
}

# Create Timestamped Backup and Rotate to Retain Max N Backups
backup_and_rotate_config() {
    local target_file="$1"
    local max_backups="${2:-3}"
    local timestamp
    timestamp="$(date +%Y%m%d-%H%M%S)"
    local backup_file="${target_file}.${timestamp}.bak"

    cp -p "${target_file}" "${backup_file}"
    chmod 0600 "${backup_file}"
    chown root:root "${backup_file}"
    echo "   [BACKUP] Saved backup copy: ${backup_file}"

    local target_dir
    target_dir="$(dirname "${target_file}")"
    local target_name
    target_name="$(basename "${target_file}")"

    local -a backups=()
    while IFS= read -r -d $'\0' file; do
        backups+=("${file}")
    done < <(find "${target_dir}" -maxdepth 1 -name "${target_name}.*.bak" -type f -print0 | sort -z)

    local total="${#backups[@]}"
    if (( total > max_backups )); then
        local num_to_remove=$(( total - max_backups ))
        for (( i=0; i<num_to_remove; i++ )); do
            echo "   [ROTATE] Removing old backup ($(( i + 1 ))/${num_to_remove}): ${backups[i]}"
            rm -f "${backups[i]}"
        done
    fi
}

# Merge New Configuration Keys from Example Template into Destination File
merge_config_settings() {
    local example="$1"
    local dest="$2"
    local max_backups="${3:-3}"

    if [[ ! -f "${example}" || ! -f "${dest}" ]]; then
        return 0
    fi

    local -a missing_blocks=()
    local pending_comment=""

    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ^[[:space:]]*# ]]; then
            if [[ -z "${pending_comment}" ]]; then
                pending_comment="${line}"
            else
                pending_comment="${pending_comment}"$'\n'"${line}"
            fi
            continue
        elif [[ "${line}" =~ ^[[:space:]]*$ ]]; then
            pending_comment=""
            continue
        fi

        if [[ "${line}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]]; then
            local var_name="${BASH_REMATCH[1]}"
            if ! grep -qE "^[[:space:]]*#?[[:space:]]*${var_name}=" "${dest}"; then
                local block=""
                if [[ -n "${pending_comment}" ]]; then
                    block="${pending_comment}"$'\n'
                fi
                block="${block}${line}"
                missing_blocks+=("${block}")
                echo "   [MERGE] Detected new setting '${var_name}' from template."
            fi
            pending_comment=""
        else
            pending_comment=""
        fi
    done < "${example}"

    if [[ ${#missing_blocks[@]} -gt 0 ]]; then
        backup_and_rotate_config "${dest}" "${max_backups}"

        for block in "${missing_blocks[@]}"; do
            {
                echo ""
                echo "${block}"
            } >> "${dest}"
        done
        echo "   [MERGED] ${#missing_blocks[@]} new setting(s) appended to ${dest} (preserving all existing values & comments)."
    else
        echo "   [UNCHANGED] ${dest} contains all template settings."
    fi
}

# 4. Install Executable Scripts
echo "-> Checking and installing scripts in /usr/local/bin/"
install_file_safely "${REPO_DIR}/scripts/common-telemetry.sh" "/usr/local/bin/common-telemetry.sh" 0755
install_file_safely "${REPO_DIR}/scripts/apt-post-install-telemetry.sh" "/usr/local/bin/apt-post-install-telemetry.sh" 0755
install_file_safely "${REPO_DIR}/scripts/conditional-reboot.sh" "/usr/local/bin/conditional-reboot.sh" 0755
install_file_safely "${REPO_DIR}/scripts/systemd-failure-notify.sh" "/usr/local/bin/systemd-failure-notify.sh" 0755

# 5. Create Configuration Directory & Template
echo "-> Checking configuration in /etc/conditional-reboot.conf.d/"
install -d -m 0700 -o root -g root /etc/conditional-reboot.conf.d

CONF_FILE="/etc/conditional-reboot.conf.d/99-local.conf"
EXAMPLE_FILE="${REPO_DIR}/conf/99-local.conf.example"

if [[ ! -f "${CONF_FILE}" ]]; then
    if [[ -f "${EXAMPLE_FILE}" ]]; then
        install_file_safely "${EXAMPLE_FILE}" "${CONF_FILE}" 0600 root root
    fi
else
    echo "   [EXISTS] Checking for new template settings in ${CONF_FILE}..."
    if [[ -f "${EXAMPLE_FILE}" ]]; then
        merge_config_settings "${EXAMPLE_FILE}" "${CONF_FILE}"
    fi
    chmod 0600 "${CONF_FILE}"
    chown root:root "${CONF_FILE}"
fi

# 6. Install Package Manager Drop-Ins (Distro Specific)
if [[ -d /etc/apt/apt.conf.d ]]; then
    echo "-> Checking APT post-install telemetry hook (Debian/Ubuntu)"
    if [[ -f "${REPO_DIR}/apt/apt.conf.d/99unattended-upgrades-local" ]]; then
        install_file_safely "${REPO_DIR}/apt/apt.conf.d/99unattended-upgrades-local" "/etc/apt/apt.conf.d/99unattended-upgrades-local" 0644
    fi
fi

if [[ -d /etc/dnf ]]; then
    echo "-> Checking DNF Automatic override (RHEL/CentOS)"
    if [[ -f "${REPO_DIR}/dnf/99-dnf-automatic-local.conf" ]]; then
        install_file_safely "${REPO_DIR}/dnf/99-dnf-automatic-local.conf" "/etc/dnf/automatic.conf.d/99-local.conf" 0644
    fi
fi

# 7. Install Systemd Units
echo "-> Checking systemd units in /etc/systemd/system/"
install_file_safely "${REPO_DIR}/units/conditional-reboot.service" "/etc/systemd/system/conditional-reboot.service" 0644
install_file_safely "${REPO_DIR}/units/conditional-reboot.timer" "/etc/systemd/system/conditional-reboot.timer" 0644
install_file_safely "${REPO_DIR}/units/failure-notification@.service" "/etc/systemd/system/failure-notification@.service" 0644

# 8. Reload Systemd & Enable Timers
echo "-> Reloading systemd daemon and enabling timers..."
systemctl daemon-reload
systemctl enable --now conditional-reboot.timer

if command -v dnf-automatic >/dev/null 2>&1; then
    systemctl enable --now dnf-automatic.timer
fi

# 9. Post-Install etckeeper Commit Trigger
if command -v etckeeper >/dev/null 2>&1; then
    echo "-> Running etckeeper post-install commit..."
    etckeeper post-install || true
fi

echo "==> Deployment process complete!"
