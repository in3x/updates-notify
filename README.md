# Automated Security Patching & Reboot Orchestration

Fleet-wide automated security updates and conditional reboot orchestration pipeline.

## Repository Layout
- `scripts/conditional-reboot.sh`: Core logic for checking reboot flags, process locks, and dispatching notifications.
- `systemd/system/`: Timer and service definitions for orchestration.
- `apt/apt.conf.d/99unattended-upgrades-local`: Debian/Ubuntu package manager overrides.
- `dnf/99-dnf-automatic-local.conf`: RHEL/CentOS package manager overrides.
