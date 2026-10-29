# Automated Security Patching & Reboot Orchestration

Unintentional, cloud-independent micro-automation stack for system updates for both security and outstanding packages, supporting Ubuntu (22.04+) and RHEL (9+).

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
## Why not Ansible? 

It's a matter of scale and complexity. Ansible has a scaling down problem and is relatively complex. The more I dug into it, the more I realized I would have to create many of the infrastructure scripts that I have here. 

Updates-notify solves the problem of:
- Automatic security updates.
- Optional installation non-security updates.
- Automatic rebooting.
- Notification of success or failure of various operations.
- Relatively low complexity of install and configuration.
- Handling a relatively small number of machines that do not have to be on the same network. 

If I had more than 15–20 machines to keep up to date, then I would look at Ansible, combined with some of the capabilities of updates-notify. 

## Why did I name it what I did? 

I'm blaming Gemini for this one. On the other hand, I think it knew that I am banned from naming children and animals in 38 states.

---
## Deployment Steps

The deployment process is as automated as one reasonably can. The deployment process breaks into 4 distinct areas:
- Prerequisite installation
- Site configuration
- Actual deployment
- Per-machine configuration 

### Prerequisites

> **Automatic Dependency Resolution:** The `deploy.sh` script automatically detects your distribution, provisions required repositories (CRB / EPEL on RHEL family), and installs all missing dependencies (`unattended-upgrades`, `dnf-utils` / `dnf-plugins-core`, `dnf-automatic` on RHEL 9, `etckeeper`, `git`, `openssl`, `curl`). It also checks whether `etckeeper` is already initialized so existing `/etc` version control history is strictly preserved. See design notes: [Automated Dependency Provisioning & Safe etckeeper Detection](docs/design.md#automated-dependency-provisioning-safe-etckeeper-detection).

If you prefer to pre-install dependencies manually before deploying:

- **RHEL 9 / 10+ & Clones (Rocky, Alma, CentOS Stream):**
    ```bash
    # 1. Resolve RHEL major version (9, 10, etc.) from /etc/os-release
    rhel_ver=$(. /etc/os-release && echo "${VERSION_ID%%.*}")

    # 2. Enable CodeReady Linux Builder (CRB)
    if command -v subscription-manager >/dev/null 2>&1; then
        sudo subscription-manager repos --enable "codeready-builder-for-rhel-${rhel_ver}-$(arch)-rpms"
    elif command -v crb >/dev/null 2>&1; then
        sudo FORCE_DNF=1 /usr/bin/crb enable
    else
        sudo dnf config-manager --set-enabled crb 2>/dev/null || sudo dnf config-manager --set-enabled powertools 2>/dev/null
    fi

    # 3. Enable EPEL (required for etckeeper)
    sudo dnf install -y epel-release 2>/dev/null || \
    sudo dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${rhel_ver}.noarch.rpm"

    # 4. Install package utilities, version control, and cryptographic tools
    if (( rhel_ver >= 10 )); then
        sudo dnf install -y dnf-plugins-core etckeeper git openssl curl
    else
        sudo dnf install -y dnf-utils dnf-automatic etckeeper git openssl curl
    fi

    # 5. Initialize etckeeper (only if /etc/.git does not already exist)
    if [[ ! -d /etc/.git && ! -d /etc/.hg && ! -d /etc/.bzr ]]; then
        sudo etckeeper init
        sudo etckeeper commit "Initial etckeeper commit prior to deployment"
    fi
    ```

- **Ubuntu / Debian Hosts:**
    ```bash
    # 1. Update package indexes
    sudo apt-get update -qq

    # 2. Install unattended upgrades, version control, and cryptographic tools
    sudo apt-get install -y unattended-upgrades etckeeper git openssl curl

    # 3. Initialize etckeeper (only if /etc/.git does not already exist)
    if [[ ! -d /etc/.git && ! -d /etc/.hg && ! -d /etc/.bzr ]]; then
        sudo etckeeper init
        sudo etckeeper commit "Initial etckeeper commit prior to deployment"
    fi
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
# Syntax: sudo ./deploy.sh <system-group-name>

sudo ./deploy.sh homelab
```

_If `etckeeper` is installed, the script automatically stages `/etc` prior to deployment and commits all changes upon completion._

---

### 3. Configuring The notifications and watchdog timeout. .

This updates-notify package organizes sets of machines into groups. Each group shares 3 NTFY 
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
  1. Create a ntfy access token named <group name> watchdog. 
  1. In healthchecks.io's NTFY integration settings
    1. The topic should be the name of the group's alerts topic.
    1. Set the access token to the `<group name>` watchdog token value.

#### Starting NTFY configuration

1. Create NTFY Reserved topics for each topic in site-conf/<group name>/99-local.conf with permissions:
  1. NTFY_ALERTS_TOPIC: I can publish and subscribe, everyone can subscribe
  1. NTFY_REBOOT_TOPIC: I can publish and subscribe, everyone can subscribe
  1. NTFY_CONTROL_TOPIC: Only I can publish and subscribe

#### NTFY and Health checks set up

1. Edit /etc/conditional-reboot.conf.d/99-local.conf
1. For each machine in the system group,
  1. ntfy setup
    1. Create a machine-specific access token labeled "<host> pw-dc-topics" (create access token)
    1. Copy the machine-specific token into NTFY_TOKEN
  1 health checks setup
    1. Create a new check (add check)
    1. Name check: pw-<host>-failsafe
    1. Copy the ping URL into HC_PING_URL
    
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

---

### 6. Validate Outstanding Updates & Remote Action Triggering

Test the optional/outstanding updates discovery pipeline, remote action buttons, and background listener:

```bash
# 1. Trigger the outstanding updates scan manually
# If upgradable packages exist, this dispatches a "📦 Updates Available" 
# notification to NTFY_CONTROL_TOPIC with the interactive [🚀 Apply Updates] button.
sudo /usr/local/bin/check-updates.sh

# 2. Verify scan results in system logs
sudo journalctl -t check-updates -n 20 --no-pager

# 3. Verify the remote command listener daemon is active and listening
sudo systemctl status remote-update-listener.service

# 4. Monitor live incoming command events on the listener
sudo journalctl -u remote-update-listener -f

# 5. Test the upgrade runner directly (applies packages and sends status telemetry)
sudo /usr/local/bin/apply-all-updates.sh

# 6. Inspect package upgrade log file
sudo tail -n 30 /var/log/package-upgrades.log

# 7. Test the weekly Friday updates digest
sudo /usr/local/bin/pending-updates-digest.sh
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

---

## When to Restart Systemd Services

The systemd units in `updates-notify` fall into two distinct categories: **oneshot services** (which spawn, execute, and exit) and **one persistent daemon** (`remote-update-listener.service`).

### 1. The Only Service Requiring Restarts: `remote-update-listener.service`

Because `remote-update-listener` runs continuously in the background holding a live connection to NTFY, it keeps its configuration in memory.

Restart it only when:
- **Credentials or topics change in `99-local.conf`**:
  - Rotated `FLEET_SECRET`
  - Changed `NTFY_CONTROL_TOPIC`, `NTFY_TOKEN`, or `NTFY_VALID_USER`
- **Listener code is updated on disk**:
  - Modified `/usr/local/bin/remote-update-listener.sh` or `/usr/local/bin/common-telemetry.sh`

```bash
sudo systemctl restart remote-update-listener.service
```

### 2. Services That Never Need Restarts (Oneshot Tasks)

* `conditional-reboot.service`
* `check-updates.service`
* `pending-updates-digest.service`
* `post-boot-notify.service`
* `failure-notification@.service`

These services do not run in the background. Systemd starts them fresh whenever their scheduled timer triggers, and they exit upon completion. Any changes to maintenance windows, blocked processes, or Healthchecks URLs in `99-local.conf` are automatically read from disk on the next scheduled run.

### 3. Reloading Timers (`*.timer`)

Timers only need to be reloaded if you modify their execution schedule inside the `/etc/systemd/system/*.timer` file itself (e.g. changing `OnCalendar=`):

```bash
sudo systemctl daemon-reload
sudo systemctl restart conditional-reboot.timer
```

### Quick Reference Checklist

| Action Taken | Restart Required? | Command |
| :--- | :--- | :--- |
| **Edited maintenance windows / blocked processes in `99-local.conf`** | ❌ **No** | Nothing (read fresh on next run). |
| **Rotated `FLEET_SECRET` or changed `NTFY_CONTROL_TOPIC`** | ✅ **Yes** | `sudo systemctl restart remote-update-listener.service` |
| **Edited scripts (`conditional-reboot.sh`, `check-updates.sh`)** | ❌ **No** | Nothing (read fresh on next run). |
| **Edited `remote-update-listener.sh`** | ✅ **Yes** | `sudo systemctl restart remote-update-listener.service` |
| **Ran `generate-topic.sh --rotate-secret`** | ✅ **Handled** | The script prompts and restarts it automatically. |
| **Ran `sudo ./deploy.sh <group>`** | ✅ **Handled** | `deploy.sh` automatically reloads daemon and restarts the listener. |
| **Changed timer schedule (`.timer`)** | ✅ **Yes** | `sudo systemctl daemon-reload && sudo systemctl restart <name>.timer` |
