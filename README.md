# VPS Orchestrator

> **Production-Ready VPS Management System**
>
> Automated deployment, security hardening, and management for self-hosted applications. Built with modular Bash scripts, Docker, and comprehensive audit logging.

## 🚀 Quick Start

```bash
# 1. Clone
git clone https://github.com/danielfoca89/my-scripts.git
cd my-scripts

# 2. Run
./orchestrator.sh
```

The **Orchestrator** is your main entry point. It handles:
*   **Dependency Resolution**: Auto-installs Docker, Nginx, or Databases if an app needs them.
*   **Security**: Generates random passwords, creates isolated users, and binds sensitive ports to localhost.
*   **State**: Stores all secrets in `~/.vps-secrets/`.

---

## 📂 Project Structure

Verified structure of the codebase:

```text
my-scripts/
├── orchestrator.sh              # Main interaction menu & dependency logic
├── apps/                        # Application installers (self-contained)
│   ├── automation/             # n8n
│   ├── databases/              # Postgres, Redis, Mongo, MariaDB
│   ├── infrastructure/         # Nginx, Docker, Portainer, Arcane, Certbot
│   ├── monitoring/             # Grafana, Prometheus, Netdata, Uptime Kuma
│   ├── system/                 # VPS Setup, Log Maintenance, Node.js
│   └── security/               # WireGuard, Fail2ban
├── config/                      # Global configurations (e.g., Docker daemon)
├── lib/                         # Shared libraries (networking, secrets, logging)
├── tools/                       # Operational scripts (backups, updates, health)
└── workflows/                   # Complex multi-step flows (e.g., initial VPS setup)
```

---

## 🛡️ Security Architecture

### 1. Network Isolation
*   **Public Access**: handled strictly by **Nginx** (ports 80/443).
*   **Internal Services**: Databases (Postgres, Mongo) and Admin UIs (Portainer, Arcane) are bound to `127.0.0.1` or internal Docker networks (`vps_network`).
    *   *Access reserved via SSH Tunnel only.*
*   **Docker Networks**:
    *   `vps_network`: Shared infrastructure.
    *   `n8n_network`: Isolated for automation workflows.

### 2. System Hardening
Managed by `apps/system/setup-vps`:
*   **SSH**: Root login disabled, custom port configured.
*   **Firewall**: UFW/Firewalld configured to deny incoming by default.
*   **Fail2Ban**: Active intrusion prevention.
*   **Updates**: Unattended security upgrades enabled.

### 3. Credential Management
*   **Storage**: `~/.vps-secrets/` (chmod 600).
*   **Generation**: Cryptographically strong random passwords (32+ chars).
*   **Isolation**: Separate `.env` files per service (e.g., `.env_postgres`, `.env_n8n`).

---

## 🛠️ Management Tools

Located in `tools/`:

| Script | Purpose |
| :--- | :--- |
| `health-check.sh` | **System Status**. Checks CPU/RAM, active containers, SSL expiry, and failed systemd units. |
| `backup-credentials.sh` | **Secrets Backup**. Encrypts/archives `~/.vps-secrets` (Cron: Daily). |
| `backup-databases.sh` | **Data Backup**. Dumps Postgres/Mongo/MariaDB to `/opt/backups` (Cron: Daily). |
| `update.sh` | **Updater**. Safely pulls new images and recreates containers (`./tools/update.sh update-all`). |

---

## 🧩 Applications Catalog

### Automation
*   **n8n**: Workflow automation.
    *   *Features*: PostgreSQL backend, Redis Queue (persistent), Auto-pruning (7 days), AI-ready.

### databases
*   **PostgreSQL**: with **pgvector** for AI embeddings.
*   **Redis**: Optimized for reliability (`noeviction` policy, 512MB limit).
*   **MongoDB**: Document store (pinned stable version).

### Infrastructure
*   **Nginx**: Reverse proxy with auto-generated dashboards.
*   **Portainer**: Docker UI (Localhost only).
*   **Arcane**: Docker management (Localhost only).

### System
*   **Log Maintenance**: Auto-rotates Docker/System logs to prevent disk exhaustion.

---

## 📝 Latest Changes (Feb 2026)

*   **Security Critical**: Locked down Admin UIs (Portainer/Arcane) to `127.0.0.1`.
*   **Stability**: Fixed Redis memory policy to prevent n8n job loss.
*   **Maintenance**: Enabled auto-pruning for n8n execution data.
*   **Logging**: Implemented global Docker log limits (100MB/container).

---

## 📜 License
MIT License.
