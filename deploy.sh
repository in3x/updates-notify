#!/usr/bin/env bash
set -euo pipefail

# 1. REGISTER BOOTSTRAP TRAP BEFORE ANY SOURCING OR PATH EXPANSION
trap 'echo "Fatal: Deploy script failed on line $LINENO" >&2; exit 1' ERR

echo "==> Deploying updates-notify pipeline to system..."

SYSTEM_GROUP="${1:-}"
if [[ -n "${SYSTEM_GROUP}" ]]; then
    echo "    System Group: ${SYSTEM_GROUP}"
fi

# Ensure root privileges
if [[ $EUID -ne 0 ]]; then
   echo "Error: This deployment script must be run as root." >&2
   exit 1
fi

# 2. Check and Automatically Install Prerequisites (RHEL/Ubuntu)
echo "-> Checking and ensuring prerequisites are installed..."

if [[ -f /etc/redhat-release ]]; then
    rhel_ver=$(rpm -E %rhel 2>/dev/null)

    if [[ ! "${rhel_ver}" =~ ^[0-9]+$ ]]; then
        echo "Error: Unable to detect valid RHEL major version via 'rpm -E %rhel'." >&2
        echo "Cannot safely configure repositories and dependencies. Aborting deployment." >&2
        exit 1
    fi

    echo "   Detected RHEL major version: ${rhel_ver}"

    MISSING_RHEL_PKGS=()
    if ! command -v needs-restarting >/dev/null 2>&1 && ! (command -v dnf >/dev/null 2>&1 && dnf needs-restarting --help >/dev/null 2>&1); then
        if (( rhel_ver >= 10 )); then
            MISSING_RHEL_PKGS+=("dnf-plugins-core")
        else
            MISSING_RHEL_PKGS+=("dnf-utils")
        fi
    fi

    if (( rhel_ver < 10 )); then
        command -v dnf-automatic >/dev/null 2>&1 || MISSING_RHEL_PKGS+=("dnf-automatic")
    fi

    command -v etckeeper >/dev/null 2>&1 || MISSING_RHEL_PKGS+=("etckeeper")
    command -v git >/dev/null 2>&1 || MISSING_RHEL_PKGS+=("git")
    command -v openssl >/dev/null 2>&1 || MISSING_RHEL_PKGS+=("openssl")
    command -v curl >/dev/null 2>&1 || MISSING_RHEL_PKGS+=("curl")

    if [[ ${#MISSING_RHEL_PKGS[@]} -gt 0 ]]; then
        echo "   Missing package(s): ${MISSING_RHEL_PKGS[*]}"

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
    command -v openssl >/dev/null 2>&1 || MISSING_DEB_PKGS+=("openssl")
    command -v curl >/dev/null 2>&1 || MISSING_DEB_PKGS+=("curl")

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

# Merge New Configuration Keys & Reference Defaults into Working Config File
merge_config_settings() {
    local example="$1"
    local dest="$2"
    local max_backups="${3:-3}"

    if [[ ! -f "${example}" || ! -f "${dest}" ]]; then
        return 0
    fi

    local -a tmpl_vars=()
    local -A tmpl_assign=()
    local -A tmpl_optional=()
    local -A tmpl_comments=()

    local pending_comment=""
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ^[[:space:]]*#[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]]; then
            local vname="${BASH_REMATCH[1]}"
            local raw_assign
            raw_assign="$(echo "${line}" | sed -E 's/^[[:space:]]*#[[:space:]]*//')"
            tmpl_vars+=("${vname}")
            tmpl_assign["${vname}"]="${raw_assign}"
            tmpl_optional["${vname}"]=1
            tmpl_comments["${vname}"]="${pending_comment}"
            pending_comment=""
        elif [[ "${line}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]]; then
            local vname="${BASH_REMATCH[1]}"
            local raw_assign
            raw_assign="$(echo "${line}" | sed -E 's/^[[:space:]]*//')"
            tmpl_vars+=("${vname}")
            tmpl_assign["${vname}"]="${raw_assign}"
            tmpl_optional["${vname}"]=0
            tmpl_comments["${vname}"]="${pending_comment}"
            pending_comment=""
        elif [[ "${line}" =~ ^[[:space:]]*# ]]; then
            if [[ -z "${pending_comment}" ]]; then
                pending_comment="${line}"
            else
                pending_comment="${pending_comment}"$'\n'"${line}"
            fi
        elif [[ "${line}" =~ ^[[:space:]]*$ ]]; then
            pending_comment=""
        fi
    done < "${example}"

    local -a new_dest_lines=()
    local -A seen_in_dest=()
    local dest_modified=0
    local prev_was_default_for=""

    while IFS= read -r line || [[ -n "${line}" ]]; do
        # 1. Existing '# Default: VAR=...' line
        if [[ "${line}" =~ ^[[:space:]]*#[[:space:]]*Default:[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]]; then
            local vname="${BASH_REMATCH[1]}"
            if [[ -n "${tmpl_assign[${vname}]:-}" ]]; then
                local expected_default="# Default: ${tmpl_assign[${vname}]}"
                if [[ "${line}" != "${expected_default}" ]]; then
                    new_dest_lines+=("${expected_default}")
                    dest_modified=1
                    echo "   [UPDATE] Updated reference default for '${vname}'."
                else
                    new_dest_lines+=("${line}")
                fi
                prev_was_default_for="${vname}"
                continue
            fi
        fi

        # 2. Active assignment: VAR=...
        if [[ "${line}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]]; then
            local vname="${BASH_REMATCH[1]}"
            seen_in_dest["${vname}"]=1

            # If template defines this variable, ensure the default comment precedes it
            if [[ -n "${tmpl_assign[${vname}]:-}" ]]; then
                if [[ "${prev_was_default_for}" != "${vname}" ]]; then
                    new_dest_lines+=("# Default: ${tmpl_assign[${vname}]}")
                    dest_modified=1
                    echo "   [MERGE] Placed reference default above active '${vname}'."
                fi
            fi
            new_dest_lines+=("${line}")
            # Ensure blank line separation after the variable assignment
            new_dest_lines+=("")
            dest_modified=1
            prev_was_default_for=""
            continue
        fi

        # 3. Commented assignment: # VAR=...
        if [[ "${line}" =~ ^[[:space:]]*#[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]]; then
            local vname="${BASH_REMATCH[1]}"
            seen_in_dest["${vname}"]=1
        fi

        # Avoid consecutive redundant blank lines
        if [[ "${line}" =~ ^[[:space:]]*$ ]]; then
            if (( ${#new_dest_lines[@]} > 0 )) && [[ "${new_dest_lines[-1]}" == "" ]]; then
                continue
            fi
            new_dest_lines+=("")
            continue
        fi

        new_dest_lines+=("${line}")
        prev_was_default_for=""
    done < "${dest}"

    # 4. Check for any template variables missing from dest
    for vname in "${tmpl_vars[@]}"; do
        if [[ -z "${seen_in_dest[${vname}]:-}" ]]; then
            echo "   [MERGE] Adding new setting '${vname}' from template..."
            dest_modified=1
            if (( ${#new_dest_lines[@]} > 0 )) && [[ "${new_dest_lines[-1]}" != "" ]]; then
                new_dest_lines+=("")
            fi
            if [[ -n "${tmpl_comments[${vname}]:-}" ]]; then
                while IFS= read -r c_line; do
                    new_dest_lines+=("${c_line}")
                done <<< "${tmpl_comments[${vname}]}"
            fi
            if (( tmpl_optional[${vname}] == 1 )); then
                new_dest_lines+=("# ${tmpl_assign[${vname}]}")
            else
                new_dest_lines+=("# Default: ${tmpl_assign[${vname}]}")
                new_dest_lines+=("${tmpl_assign[${vname}]}")
            fi
            new_dest_lines+=("")
        fi
    done

    # 5. Save changes safely if modified
    local tmp_file
    tmp_file=$(mktemp)
    printf "%s\n" "${new_dest_lines[@]}" > "${tmp_file}"

    if ! cmp -s "${tmp_file}" "${dest}"; then
        backup_and_rotate_config "${dest}" "${max_backups}"
        install -m 0600 -o root -g root "${tmp_file}" "${dest}"
        echo "   [MERGED] Config updated with defaults and blank-line spacing while strictly preserving site values & comments."
    else
        echo "   [UNCHANGED] ${dest} contains all template settings and defaults."
    fi
    rm -f "${tmp_file}"
}

# 4. Install Executable Scripts
echo "-> Checking and installing scripts in /usr/local/bin/"
install_file_safely "${REPO_DIR}/scripts/common-telemetry.sh" "/usr/local/bin/common-telemetry.sh" 0755
install_file_safely "${REPO_DIR}/scripts/apt-post-install-telemetry.sh" "/usr/local/bin/apt-post-install-telemetry.sh" 0755
install_file_safely "${REPO_DIR}/scripts/conditional-reboot.sh" "/usr/local/bin/conditional-reboot.sh" 0755
install_file_safely "${REPO_DIR}/scripts/check-updates.sh" "/usr/local/bin/check-updates.sh" 0755
install_file_safely "${REPO_DIR}/scripts/post-boot-notify.sh" "/usr/local/bin/post-boot-notify.sh" 0755
install_file_safely "${REPO_DIR}/scripts/systemd-failure-notify.sh" "/usr/local/bin/systemd-failure-notify.sh" 0755
install_file_safely "${REPO_DIR}/scripts/pending-updates-digest.sh" "/usr/local/bin/pending-updates-digest.sh" 0755
install_file_safely "${REPO_DIR}/scripts/apply-all-updates.sh" "/usr/local/bin/apply-all-updates.sh" 0755
install_file_safely "${REPO_DIR}/scripts/remote-update-listener.sh" "/usr/local/bin/remote-update-listener.sh" 0755

# 5. Create Configuration Directory & Merge Configuration
echo "-> Checking configuration in /etc/conditional-reboot.conf.d/"
install -d -m 0700 -o root -g root /etc/conditional-reboot.conf.d

CONF_FILE="/etc/conditional-reboot.conf.d/99-local.conf"
EXAMPLE_FILE="${REPO_DIR}/conf/99-local.conf.example"

SOURCE_CONF=""
if [[ -n "${SYSTEM_GROUP}" ]]; then
    SITE_CONF_DIR="${REPO_DIR}/site-conf/${SYSTEM_GROUP}"
    if [[ ! -d "${SITE_CONF_DIR}" ]]; then
        echo "Error: Site configuration directory not found: ${SITE_CONF_DIR}" >&2
        echo "Generate it first using: ./scripts/generate-topic.sh ${SYSTEM_GROUP}" >&2
        exit 1
    fi

    if [[ -f "${SITE_CONF_DIR}/99-local.conf" ]]; then
        SOURCE_CONF="${SITE_CONF_DIR}/99-local.conf"
    else
        shopt -s nullglob
        conf_matches=("${SITE_CONF_DIR}"/*.conf)
        shopt -u nullglob
        if (( ${#conf_matches[@]} > 0 )); then
            SOURCE_CONF="${conf_matches[0]}"
        else
            echo "Error: No .conf file found in ${SITE_CONF_DIR}." >&2
            exit 1
        fi
    fi
    echo "-> Using site configuration for group '${SYSTEM_GROUP}': ${SOURCE_CONF}"
else
    echo "-> No system group specified. Using default template: ${EXAMPLE_FILE}"
    SOURCE_CONF="${EXAMPLE_FILE}"
fi

if [[ ! -f "${CONF_FILE}" ]]; then
    echo "   [NEW FILE] Installing ${SOURCE_CONF} as ${CONF_FILE}..."
    install -m 0600 -o root -g root "${SOURCE_CONF}" "${CONF_FILE}"
    if [[ "${SOURCE_CONF}" != "${EXAMPLE_FILE}" && -f "${EXAMPLE_FILE}" ]]; then
        merge_config_settings "${EXAMPLE_FILE}" "${CONF_FILE}"
    fi
else
    echo "   [EXISTS] Merging configuration into operational ${CONF_FILE}..."
    if [[ -f "${SOURCE_CONF}" ]]; then
        merge_config_settings "${SOURCE_CONF}" "${CONF_FILE}"
    fi
    if [[ "${SOURCE_CONF}" != "${EXAMPLE_FILE}" && -f "${EXAMPLE_FILE}" ]]; then
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
install_file_safely "${REPO_DIR}/units/post-boot-notify.service" "/etc/systemd/system/post-boot-notify.service" 0644
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
systemctl enable post-boot-notify.service

if command -v dnf-automatic >/dev/null 2>&1; then
    systemctl enable --now dnf-automatic.timer
fi

# 9. Post-Install etckeeper Commit Trigger
if command -v etckeeper >/dev/null 2>&1; then
    echo "-> Running etckeeper post-install commit..."
    etckeeper post-install || true
fi

echo "==> Deployment process complete!"
