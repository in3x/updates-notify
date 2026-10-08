# Automated Security Patching & Reboot Orchestration

Unintentional, cloud-independent micro-automation stack for system updates for both security and outstanding packages supporting Ubuntu (22.04+) and RHEL (9+).


## Pipeline Architecture & Decoupled Design

The system splits package management and reboot orchestration into two decoupled, independent pipelines to avoid mixing update notifications with reboot lifecycles:

For design notes on this topic and others and see: [Pipeline Architecture & Decoupled Design documentation](docs/design.md#pipeline-architecture--decoupled-design).


---

## Deployment

Follow these steps to deploy the pipeline across target Linux nodes.

### Prerequisites

> **Note:** The `deploy.sh` script automatically checks for required package dependencies during execution and halts if any are missing. 

If you need to pre-install dependencies manually before deploying:

* **RHEL 9+ Hosts:** Ensure both `dnf-utils` (for `needs-restarting`) and `dnf-automatic` are installed:
  ```bash
  sudo dnf install -y dnf-utils dnf-automatic
  ```
* **Ubuntu / Debian Hosts:** Ensure `unattended-upgrades` is installed:
  ```bash
  sudo apt-get install -y unattended-upgrades
  ```

---

### 1. Execute Deployment Script

Run `deploy.sh` as `root` to install scripts, systemd units, and package manager configuration drop-ins with strict permissions (`root:root`, `0755`/`0644`/`0600`):

```bash
sudo ./deploy.sh
```

*If `etckeeper` is installed, the script automatically stages `/etc` prior to deployment and commits all changes upon completion.*

---

### 2. Configure Local Overrides (`99-local.conf`)

#### Generate a Unique NTFY Topic Name
Use `generate-topic.sh` to generate a unique topic identifier consisting of a local usable name and a random 16-character alphanumeric suffix:

```bash
# Syntax: ./scripts/generate-topic.sh <local-usable-name> [suffix-length]

./scripts/generate-topic.sh pw-lake-updates
# Output: pw-lake-updates-8861344083d8c97d

# Or with custom suffix length:
./scripts/generate-topic.sh my-server-updates 16
# Output: my-server-updates-a4f91b80c3e7215d
```

#### Edit Configuration
Configure host-specific telemetry, NTFY authentication credentials, and reboot maintenance windows:

```bash
sudo nano /etc/conditional-reboot.conf.d/99-local.conf
```

Set your node parameters:

```bash
# Host identification & NTFY notification endpoints
NTFY_URL="[https://ntfy.sh](https://ntfy.sh)"
NTFY_TOPIC="your_private_topic"
NTFY_TOKEN="tk_xxxxxxxxxxxxxxxxx"
HC_PING_URL="[https://hc-ping.com/your-uuid-here](https://hc-ping.com/your-uuid-here)"

# Maintenance window constraints (24-hour format)
MAINTENANCE_WINDOW_START="03:00"
MAINTENANCE_WINDOW_END="05:00"

# Optional: Override process blocks (space-separated array)
BLOCKED_PROCESSES=("backup_job" "db_migration" "rsync" "tmux")
```

Ensure the configuration file retains restricted permissions:

```bash
sudo chmod 0600 /etc/conditional-reboot.conf.d/99-local.conf
```

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
/usr/local/bin/systemd-failure-notify.sh "test-service.service"

# 2. Verify telemetry dispatch in system logs
sudo journalctl -t conditional-reboot -n 20

# 3. Simulate an in-window execution check using libfaketime
sudo faketime '03:30:00' /usr/local/bin/conditional-reboot.sh
```

---

## Collision Prevention & Orchestration Safety

Design notes on guarantees that conditional reboots and package upgrades never collide, see: [Collision Prevention & Orchestration Safety](docs/design.md#collision-prevention--orchestration-safety).

---

## Notification Timing & NTFY Action Buttons

The pipeline supports remote action buttons via NTFY (e.g. `[🚀 Apply All Updates]`):
Design notes are found at: [Notification Timing & NTFY Action Buttons](docs/design.md#notification-timing-ntfy-action=buttons)
