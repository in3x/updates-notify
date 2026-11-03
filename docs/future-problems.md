# Problems for Future Me (Architectural Backlog & Design Challenges)

This document tracks complex operational challenges, edge cases, and design trade-offs that have been deliberately analyzed but deferred for future implementation. 

Rather than implementing premature abstractions or fragile heuristics today, this document captures the core problem, why naive solutions fail, the data-gathering strategy currently in place, and proposed future architectures.

---

## 1. User Session Disambiguation & Intelligent Whitelisting

### The Dilemma
When automated security updates require a reboot, the pipeline checks for active user sessions to avoid abruptly terminating interactive work. However, determining what constitutes a "real human sitting at an interactive prompt" versus a background service account is deceptively difficult.

### Why Naive Approaches Fail

1. **Parsing `/etc/passwd` and UID Ranges (`5000-6000`, `!fred`, `!123`)**:
   - **Cross-Distribution Fragmentation**: Ubuntu and Debian assign standard user UIDs starting at `1000`; older Enterprise Linux systems started at `500`; enterprise LDAP and Active Directory domains frequently map user IDs into large ranges (`1000000+`).
   - **Daemon Overlap**: Modern service daemons (e.g. CI/CD runners, container daemons, local test accounts) often receive standard UIDs $\ge 1000$ or are configured with interactive login shells (`/bin/bash`).
   - **Fragile Negative Logic**: Crafting miniature expression parsers in Bash to handle inclusions, exclusions, and ranges (`eric, !fred, 5000-6000`) introduces high cognitive debt, syntax ambiguity, and edge-case bugs.

2. **Parsing Raw `who` Output**:
   - `who` displays active utmp/wtmp records, but lacks insight into whether a session is actively typing, idle for 12 hours, or detached inside a background multiplexer (`tmux`/`screen`).

### The Better Architectural Path: Systemd `logind` Session Classes

Modern Linux systems with `systemd-logind` already solve session disambiguation through kernel-level cgroups:
```bash
loginctl list-sessions --no-legend
```
Output:
```text
SESSION  UID   USER    SEAT  TTY   CLASS
2        1000  eric    -     pts/0 user
c1       998   gitlab  -     -     background
```

`logind` categorizes sessions into distinct classes:
- **`class=user` with a PTY (`pts/*` or `tty*`)**: A real human session connected via SSH or local console.
- **`class=background` without a TTY**: Background processes, cron jobs, or service units (e.g., `gitlab-runner`, `systemd --user`).

### Current Empirical Data-Gathering Strategy
Before building complex session whitelists or UID parsers, the pipeline currently executes a **multi-condition audit** logged to `/var/log/reboot-blocks.log`:
- Captures active username, UID (`id -u <user>`), terminal device (`pts/*`), and remote origin IP address.
- Reviewing `/var/log/reboot-blocks.log` over several weeks reveals exactly which accounts actually block reboots across fleet nodes, allowing rule creation based on empirical data rather than guesswork.

---

## 2. Two-Tier Soft Block Bypassing & Phased Terminal Warning Broadcasts

### The Dilemma
When updates require a reboot during the maintenance window (e.g., 02:00–05:00), transient conditions (such as an idle SSH terminal left open overnight or a delayed backup job) can defer the restart. An administrator needs a way to distinguish:
1. **Hard Blocks**: Conditions that are safety-critical and must NEVER be bypassed (active package manager locks, database migrations, prior installation failure flags).
2. **Auto-Waived Soft Blocks**: Conditions that the automated nightly window is pre-approved to ignore (e.g., idle user sessions on non-critical workstations).
3. **Manual-Only Soft Blocks**: Conditions that the automated window will never bypass on its own, but an administrator is permitted to override explicitly via an action button on `NTFY_CONTROL_TOPIC`.

### Planned Two-Tier Architecture

| Category | Policy Variable in `99-local.conf` | Execution Model |
| :--- | :--- | :--- |
| **Hard Blocks** | `BLOCKED_PROCESSES=(...)` | Strictly non-overridable. Both automated and manual reboots are rejected immediately. |
| **Auto-Waived Soft Blocks** | `IGNORE_WINDOW_BLOCKS=("user_sessions")` | Automated script waives the condition inside the nightly window and initiates a 15-minute grace reboot. |
| **Manual-Only Soft Blocks** | `MANUAL_BYPASS_PERMITTED_BLOCKS=("outside_window" "user_sessions")` | Requires the administrator to tap `[⚠️ Bypass Soft Blocks & Reboot in 15m]` on the Control channel. |

### The 15-Minute Broadcast & Remote Cancellation Pattern
When a soft block is bypassed (either automatically or via explicit admin action):
1. **Phased Terminal Warnings**: A background broadcaster issues terminal `wall` messages to all logged-in users at **15m, 10m, 5m, 3m, and 1m**, giving active users ample time to save work.
2. **Remote Cancellation**: A signed `[🛑 Cancel Reboot]` action button is published to `NTFY_CONTROL_TOPIC`, allowing the administrator to abort the countdown remotely (`shutdown -c`) without needing an SSH session.
