# Automated Security Patching & Reboot Orchestration

Unintentional, cloud-independent micro-automation stack for system updates for both security and outstanding packages supporting Ubuntu (22.04+) and RHEL (9+).

## Features

- **Cross-Distribution Support**: Native support for Ubuntu/Debian (`apt`, `unattended-upgrades`) and RHEL/CentOS (`dnf`, `dnf-automatic`, `needs-restarting`).
- **Security and Outstanding Updates Monitoring**: Scans repositories daily for pending upgrades with detailed package counts and summaries.
- **Interactive NTFY Action Buttons**: Trigger remote, non-interactive package upgrades (`[🚀 Apply All Updates]`) directly from mobile or desktop notifications without opening SSH. Design notes are found at: [Notification Timing & NTFY Action Buttons](docs/design.md#notification-timing-ntfy-action=buttons)
- **3-Topic Notification Channels**: Routes messages to dedicated topics (`alerts`, `reboot`, and `control`) so critical alarms override Do-Not-Disturb while daily updates remain quiet. See design notes: [3-Topic Fleet Architecture & Watchdog Routing](docs/design.md#3-topic-fleet-architecture--watchdog-routing).
- **Post-Boot Confirmation Telemetry**: Startup service (`post-boot-notify.service`) dispatches an immediate confirmation to the reboot topic when a node returns online, reporting kernel version and uptime.
- **Safety-First Reboot Orchestration**: Enforces strict maintenance windows, verifies absence of active non-root SSH users, checks blocked background tasks, and verifies package manager locks before restarting. Design notes are found at: [Collision Prevention & Orchestration Safety](docs/design.md#collision-prevention--orchestration-safety).
- **5-Minute Pre-Reboot Grace Period**: Broadcasts high-priority alert notifications before reboot, giving operators time to cancel (`shutdown -c`) if needed.
- **Package-Level Audit Logging**: Identifies and logs the specific packages triggering the reboot need (from `/run/reboot-required.pkgs` or `needs-restarting`).
- **Failure Quarantine & Alerting**: Halts automated reboots if prior package installations failed, dispatching urgent alerts to NTFY and Healthchecks.io.
- **Decoupled Pipelines**: Separates pending update scanning from conditional reboot evaluation, preventing false alarms and execution collisions. Design notes are found at: [Pipeline Architecture & Decoupled Design documentation](docs/design.md#pipeline-architecture--decoupled-design).
- **Safe Configuration Deployment**: `deploy.sh` merges new template options into active configs without overwriting local customizations, creating timestamped backups (`.YYYYMMDD-HHMMSS.bak`, Configurable backup retention count.).
- **Cryptographic Remote Security**: HMAC-SHA256 signed action buttons, one-time anti-replay nonce tracking, 24-hour expiration TTL, and `clear=true` notification auto-dismissal allow safe execution over public notification channels. See the [Security Architecture & Hardening Guide](docs/security.md).
- **Dual-Key Secret Rotation**: Seamless zero-downtime routine rotation (`--rotate-secret`) and immediate-lockout emergency rotation (`--rotate-emergency`) built into `generate-topic.sh`.
- **Systemd Failure Monitoring**: Generic systemd failure notification unit (`failure-notification@.service`) that alerts on service crashes across your fleet.
- **Topic Generation Utility**: Built-in CLI tool (`generate-topic.sh`) to produce unique, high-entropy NTFY topic names and site configurations.

---

## Deployment Steps

The deployment process has been automated as far as one reasonably can. The deployment process breaks into 4 distinct areas:
- Prerequisite installation
- Site configuration
- Actual deployment
- Per-machine configuration 

### Prerequisites

> **Automatic Dependency Resolution:** The `deploy.sh` script automatically detects, provisions repositories (CRB / EPEL on RHEL), and installs all missing dependencies (`unattended-upgrades`, `dnf-utils`, `dnf-automatic`, `etckeeper`, `git`). It also verifies whether `etckeeper` is already initialized so existing `/etc` git history is strictly preserved. Design notes are found at: [Automated Dependency Provisioning & Safe etckeeper Detection](docs/design.md#automated-dependency-provisioning-safe-etckeeper-detection).

If you prefer to pre-install dependencies manually before deploying:

- **RHEL 9 / 10+ Hosts:**
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
- **Ubuntu / Debian Hosts:** Ensure `unattended-upgrades`, `etckeeper`, `openssl`, and `curl` are installed:
    ```bash
    sudo apt-get install -y unattended-upgrades etckeeper git openssl curl
    ```

---

### 1. Generate Site Configuration

Use `generate-topic.sh` to generate a site configuration populated with two distinct, independent items: a unique public NTFY topic name (for URLs) and a private 256-bit `FLEET_SECRET` (for HMAC signing, never shared or derived from the topic):

```bash
# Syntax: ./scripts/generate-topic.sh <system-group-name> [ntfy-valid-user] [output-file]

./scripts/generate-topic.sh homelab eric
# Output: Writes to site-conf/homelab/99-local.conf (chmod 0600)
```

Edit `site-conf/homelab/99-local.conf` to add your `NTFY_TOKEN` and `HC_PING_URL`:

```bash
nano site-conf/homelab/99-local.conf
```

_(Note: `site-conf/*` is excluded via `.gitignore` so your secrets and tokens are never checked into version control.)_


---

### 2. Execute Deployment Script

Run `deploy.sh` as `root` passing your system group name. The script installs scripts, systemd units, package manager drop-ins, and merges your site configuration into `/etc/conditional-reboot.conf.d/99-local.conf`:

```bash
# Syntax: sudo ./deploy.sh [system-group-name]

sudo ./deploy.sh homelab
```

_If `etckeeper` is installed, the script automatically stages `/etc` prior to deployment and commits all changes upon completion._

---

### 3. Configuring The notifications and watchdog timeout. .

This update notify package organizes sets of machines into groups. Each group shares 3 NTFY 
topics between all of the machines in the group. Each machine has its own health check timer. 
Each health check timer is integrated with email and ntfy clients. The ntfy client in health 
check is connected to the group's alerts topic.

Each connection to ntfy channels requires an access token. Each machine in the group gets its 
own access token and uses that token to speak to all 3 of the shared topics. The health checks 
in the ntfy integration use a single token for all of the checks in a given group. This 
works out to N+1 NTFY access tokens, and N health check timers.

When the watchdog timer fires, it will send an ntfy message through the common alerts 
channel for any machine.

#### Starting Health checks configuration

1. On setup of the health checks NTFY integration
  1. Create an ntfy access token named <group name> watchdog. 
  1. In healthchecks.io's ntfy integration settings
    1. Topic should be the name of the group's alerts topic.
    1. Set access token to the `<group name>` watchdog token value.

#### Starting NTFY configuration

1. Create an NTFY Reserved topics for each topic in site-conf/<group name>/99-local.conf with permissions:
  1. NTFY_ALERTS_TOPIC: I can publish and subscribe, everyone can subscribe
  1. NTFY_REBOOT_TOPIC: I can publish and subscribe, everyone can subscribe
  1. NTFY_CONTROL_TOPIC: Only I can publish and subscribe

#### NTFY and Health checks set up

1. For each machines in the system group,
  1. Create access token labled "<host> pw-dc-topics" 
  1. Edit /etc/conditional-reboot.conf.d/99-local.conf
  1. Define NTFY_TOKEN with the machine specific token

### 4. Verify Package Managers & Systemd Timers

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

### 5. Validate Telemetry & Reboot Logic

Verify notification dispatches and test conditional reboot evaluation under simulated conditions:

```bash
# 1. Test manual telemetry dispatch
sudo /usr/local/bin/systemd-failure-notify.sh "test-service.service"

# 2. Verify telemetry dispatch in system logs
sudo journalctl -t conditional-reboot -n 20

# 3. Simulate an in-window execution check using libfaketime
sudo faketime '03:30:00' /usr/local/bin/conditional-reboot.sh
```
## security methods
This section will enumerate what you need to do when different security events arise and how to remedy them. 

#### Rotating Secrets

Rotate keys periodically or in emergencies using `generate-topic.sh`:

```bash
# Routine zero-downtime rotation (24h grace window for pending buttons):
./scripts/generate-topic.sh --rotate-secret homelab

# Emergency rotation (immediate revocation and lockout):
./scripts/generate-topic.sh --rotate-emergency homelab
```
