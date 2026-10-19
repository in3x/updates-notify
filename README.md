# Automated Security Patching & Reboot Orchestration

Unintentional, cloud-independent micro-automation stack for system updates for both security and outstanding packages supporting Ubuntu (22.04+) and RHEL (9+).

## Features

- **Cross-Distribution Support**: Native support for Ubuntu/Debian (`apt`, `unattended-upgrades`) and RHEL/CentOS (`dnf`, `dnf-automatic`, `needs-restarting`).
- **Security and Outstanding Updates Monitoring**: Scans repositories daily for pending upgrades with detailed package counts and summaries.
- **Interactive NTFY Action Buttons**: Trigger remote, non-interactive package upgrades (`[🚀 Apply All Updates]`) directly from mobile or desktop notifications without opening SSH. Design notes are found at: [Notification Timing & NTFY Action Buttons](docs/design.md#notification-timing-ntfy-action=buttons)
- **Safety-First Reboot Orchestration**: Enforces strict maintenance windows, verifies absence of active non-root SSH users, checks blocked background tasks, and verifies package manager locks before restarting. Design notes are found at: [Collision Prevention & Orchestration Safety](docs/design.md#collision-prevention--orchestration-safety).
- **5-Minute Pre-Reboot Grace Period**: Broadcasts high-priority alert notifications before reboot, giving operators time to cancel (`shutdown -c`) if needed.
- **Package-Level Audit Logging**: Identifies and logs the specific packages triggering the reboot need (from `/run/reboot-required.pkgs` or `needs-restarting`).
- **Failure Quarantine & Alerting**: Halts automated reboots if prior package installations failed, dispatching urgent alerts to NTFY and Healthchecks.io.
- **Decoupled Pipelines**: Separates pending update scanning from conditional reboot evaluation, preventing false alarms and execution collisions. Design notes are found at: [Pipeline Architecture & Decoupled Design documentation](docs/design.md#pipeline-architecture--decoupled-design).
- **Safe Configuration Deployment**: `deploy.sh` merges new template options into active configs without overwriting local customizations, creating timestamped backups (`.YYYYMMDD-HHMMSS.bak`, Configurable backup retention count.).
- **Cryptographic Remote Security**: HMAC-SHA256 signed action buttons, one-time anti-replay nonce tracking, 24-hour expiration TTL, and `clear=true` notification auto-dismissal allow safe execution over public notification channels. See the [Security Architecture & Hardening Guide](docs/security.md).
- **Systemd Failure Monitoring**: Generic systemd failure notification unit (`failure-notification@.service`) that alerts on service crashes across your fleet.
- **Topic Generation Utility**: Built-in CLI tool (`generate-topic.sh`) to produce unique, high-entropy NTFY topic names.

---

## Deployment

Follow these steps to deploy the pipeline across target Linux nodes.

### Prerequisites

> **Automatic Dependency Resolution:** The `deploy.sh` script automatically detects, provisions repositories (CRB / EPEL on RHEL), and installs all missing dependencies (`unattended-upgrades`, `dnf-utils`, `dnf-automatic`, `etckeeper`, `git`). It also verifies whether `etckeeper` is already initialized so existing `/etc` git history is strictly preserved.  Design notes are found at: [Automated Dependency Provisioning & Safe etckeeper Detection](docs/design.md#automated-dependency-provisioning-safe-etckeeper-detection).

If you prefer to pre-install dependencies manually before deploying:

* **RHEL 9 / 10+ Hosts:**
  ```bash
  # Dynamically resolve RHEL major version (9, 10, etc.)
  rhel_ver=$(rpm -E %rhel)

  # Enable CodeReady Linux Builder (CRB)
  sudo subscription-manager repos --enable codeready-builder-for-rhel-${rhel_ver}-$(arch)-rpms

  # Install EPEL (for etckeeper)
  sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-${rhel_ver}.noarch.rpm

  # Install package manager utilities and cryptographic tools
  if (( rhel_ver >= 10 )); then
      sudo dnf install -y dnf-plugins-core etckeeper git openssl curl
  else
      sudo dnf install -y dnf-utils dnf-automatic etckeeper git openssl curl
  fi
  ```
* **Ubuntu / Debian Hosts:** Ensure `unattended-upgrades`, `etckeeper`, `openssl`, and `curl` are installed:
  ```bash
  sudo apt-get install -y unattended-upgrades etckeeper git openssl curl
  ```

---

### 1. Generate Site Configuration
Use `generate-topic.sh` to generate a site-specific configuration file with a unique topic, a 256-bit `FLEET_SECRET`, and your NTFY username:

```bash
# Syntax: ./scripts/generate-topic.sh <system-group-name> [ntfy-valid-user] [output-file]

./scripts/generate-topic.sh homelab eric
# Output: Writes to site-conf/homelab/99-local.conf (chmod 0600)
```

Edit `site-conf/homelab/99-local.conf` to add your `NTFY_TOKEN` and `HC_PING_URL`:

```bash
nano site-conf/homelab/99-local.conf
```

*(Note: `site-conf/*` is excluded via `.gitignore` so your secrets and tokens are never checked into version control.)*

---

### 2. Execute Deployment Script

Run `deploy.sh` as `root` passing your system group name. The script installs scripts, systemd units, package manager drop-ins, and merges your site configuration into `/etc/conditional-reboot.conf.d/99-local.conf`:

```bash
# Syntax: sudo ./deploy.sh [system-group-name]

sudo ./deploy.sh homelab
```

*If `etckeeper` is installed, the script automatically stages `/etc` prior to deployment and commits all changes upon completion.*

---

### 3. Verify Package Managers & Systemd Timers

Verify that systemd timers are active and package managers merge your local configuration overrides:

```bash
# Check systemd timer status
sudo systemctl status conditional-reboot.timer

# Ubuntu / Debian: Verify effective Unattended-Upgrade rules
apt-config dump | grep -i "Unattended-Upgrade::"

# RHEL: Verify dnf-automatic schedule and service
sudo systemctl status dnf-automatic.timer
```

---

### 4. Validate Telemetry & Reboot Logic

Verify notification dispatches and test conditional reboot evaluation under simulated conditions:

```bash
# 1. Test manual telemetry dispatch
sudo /usr/local/bin/systemd-failure-notify.sh "test-service.service"

# 2. Verify telemetry dispatch in system logs
sudo journalctl -t conditional-reboot -n 20

# 3. Simulate an in-window execution check using libfaketime
sudo faketime '03:30:00' /usr/local/bin/conditional-reboot.sh
```
