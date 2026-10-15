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

# 2. Check and Automatically Install Prerequisites (RHEL/Ubuntu)
echo "-> Checking and ensuring prerequisites are installed..."

if [[ -f /etc/redhat-release ]]; then
    MISSING_RHEL_PKGS=()
    command -v needs-restarting >/dev/null 2>&1 || MISSING_RHEL_PKGS+=("dnf-utils")
    command -v dnf-automatic >/dev/null 2>&1 || MISSING_RHEL_PKGS+=("dnf-automatic")
    command -v etckeeper >/dev/null 2>&1 || MISSING_RHEL_PKGS+=("etckeeper")
    command -v git >/dev/null 2>&1 || MISSING_RHEL_PKGS+=("git")

    if [[ ${#MISSING_RHEL_PKGS[@]} -gt 0 ]]; then
        echo "   Missing package(s): ${MISSING_RHEL_PKGS[*]}"
        rhel_ver=$(rpm -E %rhel 2>/dev/null || echo "9")
        echo "   Detected RHEL major version: ${rhel_ver}"

        # Enable CodeReady Linux Builder (CRB) repository
        if command -v subscription-manager >/dev/null 2>&1; then
            echo "   Enabling CodeReady Linux Builder (CRB) via subscription-manager..."
            subscription-manager repos --enable "codeready-builder-for-rhel-${rhel_ver}-$(arch)-rpms" 2>/dev/null || true
        fi

        if command -v crb >/dev/null 2>&1; then
            FORCE_DNF=1 /usr/bin/crb enable 2>/dev/null || true
        elif command -v dnf >/dev/null 2>&1; then
            dnf config-manager --set-enabled crb 2>/dev/null || dnf config-manager --set-enabled powertools 2>/dev/null || true
        fi

        # Provision EPEL if needed for etckeeper
        if ! rpm -q epel-release >/dev/null 2>&1; then
            echo "   Configuring EPEL repository..."
            dnf install -y epel-release 2>/dev/null || \
            dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${rhel_ver}.noarch.rpm" 2>/dev/null || true
        fi

        echo "   Installing required dependencies (${MISSING_RHEL_PKGS[*]})..."
        dnf install -y "${MISSING_RHEL_PKGS[@]}"
    else
        echo "   All required RHEL packages are already installed."
    fi

elif [[ -f /etc/debian_version ]]; then
    MISSING_DEB_PKGS=()
    command -v unattended-upgrade >/dev/null 2>&1 || MISSING_DEB_PKGS+=("unattended-upgrades")
    command -v etckeeper >/dev/null 2>&1 || MISSING_DEB_PKGS+=("etckeeper")
    command -v git >/dev/null 2>&1 || MISSING_DEB_PKGS+=("git")

    if [[ ${#MISSING_DEB_PKGS[@]} -gt 0 ]]; then
        echo "   Missing package(s): ${MISSING_DEB_PKGS[*]}"
        echo "   Installing required dependencies via apt-get..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y "${MISSING_DEB_PKGS[@]}"
    else
        echo "   All required Debian/Ubuntu packages are already installed."
    fi
fi

# 3. Safe etckeeper Inspection and Initialization
if command -v etckeeper >/dev/null 2>&1; then
    # Verify if etckeeper repository is already initialized (do not wipe existing git repo)
    if [[ -d /etc/.git || -d /etc/.hg || -d /etc/.bzr ]]; then
        echo "-> Existing etckeeper repository detected. Preserving git history and staging current /etc..."
        etckeeper pre-install || true
    else
        echo "-> etckeeper installed but uninitialized. Initializing new repository..."
        etckeeper init
        if git -C /etc rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            if ! git -C /etc config user.name >/dev/null 2>&1; then
                git -C /etc config user.name "root"
                git -C /etc config user.email "root@${HOSTNAME}"
            fi
        fi
        etckeeper commit "Initial etckeeper commit prior to updates-notify deployment" || true
    fi
else
    echo "⚠️  etckeeper is not available. Continuing deployment without /etc tracking..."
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
install_file_safely "${REPO_DIR}/scripts/check-updates.sh" "/usr/local/bin/check-updates.sh" 0755
install_file_safely "${REPO_DIR}/scripts/systemd-failure-notify.sh" "/usr/local/bin/systemd-failure-notify.sh" 0755
install_file_safely "${REPO_DIR}/scripts/pending-updates-digest.sh" "/usr/local/bin/pending-updates-digest.sh" 0755
install_file_safely "${REPO_DIR}/scripts/apply-all-updates.sh" "/usr/local/bin/apply-all-updates.sh" 0755
install_file_safely "${REPO_DIR}/scripts/remote-update-listener.sh" "/usr/local/bin/remote-update-listener.sh" 0755

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
install_file_safely "${REPO_DIR}/units/check-updates.service" "/etc/systemd/system/check-updates.service" 0644
install_file_safely "${REPO_DIR}/units/check-updates.timer" "/etc/systemd/system/check-updates.timer" 0644
install_file_safely "${REPO_DIR}/units/pending-updates-digest.service" "/etc/systemd/system/pending-updates-digest.service" 0644
install_file_safely "${REPO_DIR}/units/pending-updates-digest.timer" "/etc/systemd/system/pending-updates-digest.timer" 0644
install_file_safely "${REPO_DIR}/units/remote-update-listener.service" "/etc/systemd/system/remote-update-listener.service" 0644
install_file_safely "${REPO_DIR}/units/failure-notification@.service" "/etc/systemd/system/failure-notification@.service" 0644

# 8. Reload Systemd & Enable Timers and Services
echo "-> Reloading systemd daemon and enabling timers and services..."
systemctl daemon-reload
systemctl enable --now conditional-reboot.timer
systemctl enable --now check-updates.timer
systemctl enable --now pending-updates-digest.timer
systemctl enable --now remote-update-listener.service

if command -v dnf-automatic >/dev/null 2>&1; then
    systemctl enable --now dnf-automatic.timer
fi

# 9. Post-Install etckeeper Commit Trigger
if command -v etckeeper >/dev/null 2>&1; then
    echo "-> Running etckeeper post-install commit..."
    etckeeper post-install || true
fi

echo "==> Deployment process complete!"
