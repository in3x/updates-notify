#!/usr/bin/env bash
set -euo pipefail

mkdir -p units scripts

# 1. Systemd Service Unit
cat <<'EOF' > units/conditional-reboot.service
[Unit]
Description=Conditional Reboot Orchestration Pipeline
OnFailure=failure-notification@%n.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/conditional-reboot.sh
EOF

# 2. Systemd Timer Unit
cat <<'EOF' > units/conditional-reboot.timer
[Unit]
Description=Trigger Conditional Reboot Pipeline Daily

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=900
Persistent=true

[Install]
WantedBy=timers.target
EOF

# 3. Generic Systemd Failure Notification Service Template
cat <<'EOF' > units/failure-notification@.service
[Unit]
Description=NTFY Alert Notification for Systemd Unit %i

[Service]
Type=oneshot
ExecStart=/usr/local/bin/systemd-failure-notify.sh "%i"
EOF

# 4. Systemd Failure Helper Script
cat <<'EOF' > scripts/systemd-failure-notify.sh
#!/usr/bin/env bash
set -euo pipefail

# 1. REGISTER BOOTSTRAP TRAP BEFORE ANY SOURCING OR PATH EXPANSION
trap 'echo "Fatal: Systemd failure notifier error on line $LINENO" >&2; exit 1' ERR

# 2. Source Common Functions & Upgrade to Full Failure Handler
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common-telemetry.sh"
trap 'failure_handler ${LINENO}' ERR

# 3. Main Logic
FAILED_UNIT="${1:-unknown.service}"

logger -t systemd-notify "Systemd service ${FAILED_UNIT} failed on $(hostname)."
send_ntfy "🚨 Systemd Execution Failure" "Systemd unit '${FAILED_UNIT}' failed on $(hostname)." "high"
ping_hc "fail"

exit 0
EOF

chmod +x scripts/systemd-failure-notify.sh

echo "Systemd unit files written to ./units/ and failure helper to ./scripts/"
