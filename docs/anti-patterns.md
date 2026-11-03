# Good Ideas That Really Aren't (Anti-Patterns & Architectural Decisions)

This document captures design discussions, architectural proposals, and seemingly good ideas that were evaluated, tested against real-world operations, and intentionally rejected.

Documenting rejected proposals prevents future developers, maintainers, and AI agents from re-litigating settled trade-offs or introducing well-intentioned changes that compromise simplicity, security, or reliability.

---

## 1. Configurable Per-Alert Topic Mappings

### The Proposal
Instead of hardcoding alerts into three fixed channels (`ALERTS`, `REBOOT`, `CONTROL`), allow administrators to configure per-event topic variables in `99-local.conf` (e.g., `TOPIC_SYSTEMD_FAILURE`, `TOPIC_BOOT_SUCCESS`, `TOPIC_REBOOT_DEFERRED`, `TOPIC_PENDING_UPDATES`).

### Why It Sounded Good
- **Maximum Granularity**: Operators could split individual events into separate NTFY topics (e.g. routing post-boot audit logs into a compliance channel).
- **Muting Unwanted Alerts**: Operators could silence noisy warnings (like `reboot deferred`) by leaving a specific event variable empty.
- **Custom Flexibility**: Allowed power users to define any routing topology they wanted without editing scripts.

### Why It's Actually a Bad Idea

1. **Breaks the "Observer vs. Admin" Security Boundary**:
   The 3-channel architecture enforces a strict security wall:
   - Observers on `...-alerts` see notifications but **never** see or receive action triggers.
   - Interactive root action buttons (`[🚀 Apply Updates]`) exist **exclusively** on `...-control`.
   If per-event routing were configurable, an administrator or automated script could inadvertently route pending update notifications to an observer channel. This would leak cryptographically signed root action triggers to unauthorized devices. Keeping routing hardcoded in the scripts guarantees that action buttons can *never* leak outside the Control topic.

2. **Configuration Bloat & Fragility**:
   Instead of configuring 3 topic URLs and a token, `99-local.conf` would balloon by 8–12 additional variables. Every added variable increases cognitive load, surface area for typos, and the likelihood of silently dropped alerts.

3. **Cognitive Debt for AI Agents & Human Operators**:
   When routing is fragmented across dozens of override variables, both human operators and LLM coding agents lose confidence in how an alert is routed. Troubleshooting requires tracing through multiple layers of fallback code to determine which variable took precedence.

4. **Listener-Publisher Topic Drift**:
   The background daemon (`remote-update-listener.service`) must listen on the exact same topic where action buttons are published. Allowing independent topic variables for the action button and the listener creates a coupling trap where a configuration typo completely breaks remote updates.

5. **Upgrades Become Unreliable**:
   `deploy.sh` maintains a safe configuration merge engine. Reconciling a matrix of 12+ per-event override variables between upstream templates and existing site configurations dramatically increases diff noise and merge conflicts.

### The Better Solution
**An Authoritative 3-Topic Contract:**
The codebase adheres strictly to an immutable 3-topic registry:
- **`NTFY_ALERTS_TOPIC`**: All failures, emergencies, crashes, and Healthchecks watchdog down events (Observer Stream).
- **`NTFY_REBOOT_TOPIC`**: All restart lifecycle events (scheduled reboots, deferrals, boot success confirmations).
- **`NTFY_CONTROL_TOPIC`**: All update notifications, digests, action buttons, and remote listener traffic.

If an operator wants fine-grained filtering (e.g., muting `reboot deferred` notices or highlighting only specific servers), they leverage **NTFY's native client-side filters** (filtering by priority, host tag `[hostname]`, or title regex) directly on their mobile device or desktop app. The server code remains simple, robust, and deterministic.

---

## 2. Dynamic Version Fallback Guessing on RHEL

### The Proposal
When determining the major release of an Enterprise Linux host (`rpm -E %rhel`), default to version `9` if macro evaluation returns empty or fails (e.g. `rhel_ver="${rhel_ver:-9}"`).

### Why It Sounded Good
- Avoided crashing the installer on minimal environments where RPM macro expansion might be absent.
- Provided a "graceful" best-effort installation.

### Why It's Actually a Bad Idea
- **Cross-Version Repository Pollution**: RHEL 10 and RHEL 9 have incompatible repository channels (CRB 10 vs 9, EPEL 10 vs 9). Guessing version `9` on a RHEL 10 node installs incorrect EPEL release RPMs, pointing the system to packages compiled against older glibc/kernel ABIs.
- **Package Manager Breakage**: RHEL 10 uses DNF 5 and removes `dnf-automatic` and `dnf-utils` entirely. If the installer assumes RHEL 9, it attempts to install obsolete packages, crashing the installation midway and leaving half-configured state.

### The Better Solution
**Fail Fast with Clear Diagnostics:**
Read the major version cleanly from `/etc/os-release` (`VERSION_ID`), validate that it is an unambiguous positive integer (`^[0-9]+$`), and halt immediately with an actionable error if the OS version cannot be verified. Never guess operating system releases.

---

## 3. Embedding Secrets in Public Topic Names

### The Proposal
Derive the public NTFY topic name directly from the local cryptographic secret (`FLEET_SECRET`) to ensure unique, unguessable URLs.

### Why It Sounded Good
- Reduced the number of generated secrets to a single value.
- Guaranteed that every topic name was cryptographically unique.

### Why It's Actually a Bad Idea
- **Public vs. Private Exposure**: Topic names are visible in plaintext URLs, HTTP reverse-proxy logs, browser histories, and push notification payloads.
- **Compromising the Signing Key**: If the topic name contains or is derived from `FLEET_SECRET`, anyone observing network traffic immediately gains the private key needed to forge HMAC-SHA256 update commands.

### The Better Solution
**Complete Cryptographic Separation:**
`generate-topic.sh` generates two independent, unrelated values:
- A high-entropy public topic namespace for message routing (`<16-hex>-<group>-<subtopic>`).
- An isolated 256-bit private key (`FLEET_SECRET`) locked down with `chmod 0600 root:root` that is never transmitted, exposed in URLs, or derived from topic strings.

---

## 4. Hierarchical Subtopics with Slashes in NTFY

### The Proposal
Use forward slashes in topic names to represent nested subtopics under a group namespace (e.g., `https://ntfy.sh/<hex>-<group>/alerts` or `/control`).

### Why It Sounded Good
- Followed intuitive directory/REST-style hierarchical naming.
- Visual clarity when organizing groups and subtopics.

### Why It's Actually a Bad Idea
- **NTFY API Routing Conflict**: NTFY treats the URL path following the topic name as HTTP API endpoints (such as `/json`, `/raw`, `/sse`, `/auth`). Topic names containing slashes disrupt endpoint parsing on NTFY servers.
- **Flat Namespace Constraint**: NTFY strictly requires topic names to be flat strings consisting solely of alphanumeric characters, hyphens (`-`), and underscores (`_`), with a maximum length of 64 characters.

### The Better Solution
**Prefix-Based Flat Topics (`<16_hex>-<group>-<subtopic>`):**
Use hyphens to separate the random hex prefix, system group name, and subtopic suffix (`-alerts`, `-reboot`, `-control`). Validate at generation and migration time that the total length never exceeds 64 characters (`validate_topic_name`).
