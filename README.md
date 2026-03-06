# VPS Orchestrator

> **Production-Ready VPS Management System — v2.0**
>
> Automated deployment, security hardening, and management for self-hosted applications.
> Built with modular Bash scripts, focused on **Debian/Ubuntu**.

---

## 🚀 Quick Start

```bash
# 1. Clone
git clone https://github.com/focadaniel89/my-scripts.git
cd my-scripts

# 2. First run — VPS hardening (on a fresh server, NOT over SSH)
sudo ./workflows/vps-initial-setup.sh

# 3. Install applications
./orchestrator.sh
```

**Requirements:** `Debian 11+` or `Ubuntu 22.04+` · `Bash 4+` · Root or sudo access

The **Orchestrator** is your main entry point. It:
- **Resolves dependencies** automatically (Docker, Nginx, DBs)
- **Detects installed apps** and shows their status in the menu
- **Loops back** to the menu after each action — no need to re-run
- **Runs a startup check** — warns if internet or resources are insufficient

---

## 📂 Project Structure

```text
my-scripts/
├── orchestrator.sh              # Main interactive menu (v2.0)
├── apps/                        # Application installers (self-contained)
│   ├── ai/                      # Ollama, Open WebUI, Llama.cpp
│   ├── automation/              # n8n, XyOps
│   ├── databases/               # Postgres, Redis, Mongo, MariaDB (Docker & Native)
│   ├── infrastructure/          # Nginx, Docker Engine, Portainer, Arcane, Certbot
│   ├── monitoring/              # Grafana, Prometheus, Netdata, Uptime Kuma
│   ├── security/                # WireGuard, Fail2Ban, Security Audit
│   └── system/                  # Node.js, Log Maintenance
├── config/                      # Global configs (Docker daemon, apps catalog)
│   ├── apps.conf                # App registry — names, deps, descriptions
│   └── docker-daemon.json       # Docker daemon defaults
├── lib/                         # Shared libraries — sourced by all scripts
│   ├── utils.sh                 # Logging, guards, sudo, service management
│   ├── os-detect.sh             # OS/distro detection (is_debian_based, etc.)
│   ├── preflight.sh             # System checks (disk, RAM, internet, ports)
│   ├── secrets.sh               # Credential generation & storage
│   └── docker.sh                # Docker helpers
├── tools/                       # Operational scripts (accessible from menu)
│   ├── health-check.sh          # System status — CPU, RAM, containers, SSL
│   ├── update.sh                # Pull new Docker images & recreate containers
│   ├── backup-databases.sh      # Dump Postgres/Mongo/MariaDB → /opt/backups
│   ├── backup-credentials.sh    # Encrypt & archive ~/.vps-secrets
│   ├── generate-self-signed-cert.sh
│   └── setup-dashboard.sh
└── workflows/                   # Complex multi-step flows
    └── vps-initial-setup.sh     # Full server hardening (13 steps)
```

---

## 🛡️ Security Architecture

### 1. VPS Hardening (`workflows/vps-initial-setup.sh`)

13-step hardening process:

| Step | What it does |
|:-----|:-------------|
| 1 | System update + upgrade |
| 2 | Install security tools (fail2ban, auditd, ufw, apparmor) |
| 3 | Create admin user + `systemctl --user` fix + `umask 027` |
| 4 | Kernel hardening — ASLR, sysctl params, IPv6 protection |
| 5 | SSH hardening — key-only auth, custom port, strict config |
| 6 | Firewall — UFW (Debian) or firewalld (RHEL) |
| 7 | Fail2Ban — SQLite persistent bans, 24h SSH ban, recidivists jail (7 days) |
| 8 | Audit logging — identity, SSH, sudo escalation, cron, kernel modules |
| 9 | Automatic security updates |
| 10 | Custom MOTD |
| 11 | Final verification (all services + AppArmor status) |
| 12 | Sudo hardening — 5-min timeout + full command log |
| 13 | AppArmor — installed, enabled, all profiles enforced |

### 2. Network Isolation

- **Public**: only through Nginx (ports 80/443)
- **Internal**: databases and admin UIs bound to `127.0.0.1` or Docker network `vps_network`
- **SSH**: key-only authentication, no root login, no password auth

### 3. Credential Management

- Storage: `~/.vps-secrets/` (mode `700`, files `600`)
- Cryptographically random passwords (32+ chars)
- Separate `.env` files per service (`.env_postgres`, `.env_n8n`, etc.)
- Audit log: `~/.vps-secrets/.audit.log`

---

## 🛠️ Management Tools

Available directly from the orchestrator menu (`[tools]` section):

| Script | Purpose |
|:-------|:--------|
| `health-check.sh` | CPU/RAM, active containers, SSL expiry — HTML and `--cli` output |
| `backup-credentials.sh` | Encrypts `~/.vps-secrets` (run via cron daily) |
| `backup-databases.sh` | Dumps Postgres/Mongo/MariaDB → `/opt/backups` |
| `update.sh` | Pulls new Docker images, recreates containers safely |
| `setup-dashboard.sh` | Terminal dashboard for quick status overview |

---

## 🧩 Applications Catalog

### 🤖 AI
- **Ollama** — Local LLM runner
- **Open WebUI** — Chat interface for Ollama
- **Llama.cpp** — Run LLMs with minimal overhead

### ⚡ Automation
- **n8n** — Workflow automation (PostgreSQL + Redis backed)
- **XyOps** — Lightweight orchestration tool (Node.js)

### 🗄️ Databases
- **PostgreSQL** — Docker or Native. Includes `pgvector` extension.
- **Redis** — Docker (`redis-docker`) or Native (`redis`). Memory policy tuned for reliability.
- **MongoDB** — Docker container
- **MariaDB** — Docker container

### 🏗️ Infrastructure
- **Docker Engine** — Base dependency for most apps
- **Nginx** — Reverse proxy with auto-generated site configs
- **Portainer** — Docker UI (localhost only, SSH tunnel)
- **Arcane** — Lightweight Docker manager (localhost only)
- **Certbot** — SSL/TLS certificate management (Let's Encrypt)

### 📊 Monitoring
- **Grafana** — Visualization platform (Docker or Native)
- **Prometheus** — Metrics collection (Docker or Native)
- **Netdata** — Real-time performance monitoring
- **Uptime Kuma** — Uptime monitoring & alerting

### 🔐 Security
- **WireGuard** — Modern VPN tunnel
- **Fail2Ban** — Intrusion prevention (also configured in VPS setup)
- **Security Audit** — Local vulnerability scanner

### ⚙️ System
- **Node.js** — Environment setup (NVM based)
- **Log Maintenance** — Auto-rotates logs to prevent disk exhaustion

---

## 📝 Changelog

See [CHANGELOG.md](CHANGELOG.md) for the full version history.

**Latest: v2.0.0 (March 2026)**
- Orchestrator: loop menu, --help, startup preflight checks, tools section
- Security: AppArmor, sudo hardening, ASLR, fail2ban SQLite persistence
- Library: `require_debian()`, `check_internet()`, `get_ssh_service_name()`, `preflight_startup()`
- Auditd: sudo/su escalation monitoring, cron, kernel module detection
- Focus: standardized on Debian/Ubuntu (with RHEL advisory warnings)

---

## 📌 Versioning

[Semantic Versioning](https://semver.org/spec/v2.0.0.html) · [Tags](https://github.com/focadaniel89/my-scripts/tags)

---

## 📜 License

MIT License — Copyright © 2026 Daniel Foca

## Author

**Daniel Foca** ([@focadaniel89](https://github.com/focadaniel89))
