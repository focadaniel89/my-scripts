# VPS Orchestrator

> **Production-Ready VPS Management System**
>
> Automated deployment, security hardening, and management for self-hosted applications. Built with modular Bash scripts, Docker, and comprehensive audit logging.

## 🚀 Quick Start

```bash
# 1. Clone
git clone https://github.com/focadaniel89/my-scripts.git
cd my-scripts

# 2. Run
./orchestrator.sh
```

The **Orchestrator** is your main entry point. It handles:

- **Dependency Resolution**: Auto-installs Docker, Nginx, or Databases if an app needs them.
- **Security**: Generates random passwords, creates isolated users, and binds sensitive ports to localhost.
- **State**: Stores all secrets in `~/.vps-secrets/`.

---

## 📂 Project Structure

Verified structure of the codebase:

```text
my-scripts/
├── orchestrator.sh              # Main interaction menu & dependency logic
├── apps/                        # Application installers (self-contained)
│   ├── automation/             # n8n, XyOps
│   ├── databases/              # Postgres, Redis, Mongo, MariaDB (Docker & Native options)
│   ├── infrastructure/         # Nginx, Docker, Portainer, Arcane, Certbot
│   ├── monitoring/             # Grafana, Prometheus, Netdata, Uptime Kuma
│   ├── system/                 # VPS Setup, Log Maintenance, Node.js
│   └── security/               # WireGuard, Fail2ban, Audit
├── config/                      # Global configurations (e.g., Docker daemon)
├── lib/                         # Shared libraries (networking, secrets, logging)
├── tools/                       # Operational scripts (backups, updates, health)
└── workflows/                   # Complex multi-step flows (e.g., initial VPS setup)
```

---

## 🛡️ Security Architecture

### 1. Network Isolation

- **Public Access**: handled strictly by **Nginx** (ports 80/443).
- **Internal Services**: Databases and Admin UIs are bound to `127.0.0.1` or internal Docker networks (`vps_network`).
  - _Access reserved via SSH Tunnel only._
- **Docker Networks**:
  - `vps_network`: Shared infrastructure.
  - `n8n_network`: Isolated for automation workflows.

### 2. System Hardening

Managed by `apps/system/setup-vps`:

- **SSH**: Root login disabled, custom port configured.
- **Firewall**: UFW/Firewalld configured to deny incoming by default.
- **Fail2Ban**: Active intrusion prevention.
- **Updates**: Unattended security upgrades enabled.

### 3. Credential Management

- **Storage**: `~/.vps-secrets/` (chmod 600).
- **Generation**: Cryptographically strong random passwords (32+ chars).
- **Isolation**: Separate `.env` files per service (e.g., `.env_postgres`, `.env_n8n`).

---

## 🛠️ Management Tools

Located in `tools/`:

| Script                  | Purpose                                                                                                          |
| :---------------------- | :--------------------------------------------------------------------------------------------------------------- |
| `health-check.sh`       | **System Status**. Checks CPU/RAM, active containers, SSL expiry, etc. Supports HTML and `--cli` tabular output. |
| `backup-credentials.sh` | **Secrets Backup**. Encrypts/archives `~/.vps-secrets` (Cron: Daily).                                            |
| `backup-databases.sh`   | **Data Backup**. Dumps Postgres/Mongo/MariaDB to `/opt/backups` (Cron: Daily).                                   |
| `update.sh`             | **Updater**. Safely pulls new images and recreates containers.                                                   |
| `setup-dashboard.sh`    | **Dashboard**. Configures a terminal-based dashboard for quick overview.                                         |

---

## 🧩 Applications Catalog

### 🤖 AI

- **Ollama**: Local LLM runner.
- **Open WebUI**: Chat interface for Ollama.
- **Llama.cpp**: Run LLMs with minimal overhead.

### ⚡ Automation

- **n8n**: Workflow automation (PostgreSQL + Redis supported).
- **XyOps**: Lightweight automation/orchestration tool (Node.js).

### 🗄️ Databases

- **PostgreSQL**: Available as **Docker** container or **Native** system service. Includes `pgvector`.
- **Redis**: Available as **Docker** container or **Native** system service. Optimized for reliability.
- **MongoDB**: Document store.
- **MariaDB**: SQL database.

### 🏗️ Infrastructure

- **Nginx**: Reverse proxy with auto-generated configurations.
- **Portainer**: Docker UI (Localhost only).
- **Arcane**: Docker management (Localhost only).
- **Certbot**: SSL certificate management.

### 📊 Monitoring

- **Grafana**: Visualization platform (Docker & Native options).
- **Prometheus**: Metrics collection (Docker & Native options).
- **Netdata**: Real-time performance monitoring.
- **Uptime Kuma**: Uptime monitoring tool.

### 🔐 Security

- **WireGuard**: Modern VPN tunnel.
- **Fail2ban**: Intrusion prevention.
- **Security Audit**: Scans system for vulnerabilities.

### ⚙️ System

- **VPS Setup**: Initial server provisioning.
- **Log Maintenance**: Auto-rotates logs to prevent disk exhaustion.
- **Node.js**: Environment setup.

---

## 📝 Latest Changes (March 2026)

- **Refactoring**: Deduplicated installation wrapper scripts (removed redundant local-only and setup-vps wrappers).
- **Health Checks**: Consolidated script logic into `tools/health-check.sh` featuring both HTML and CLI tabular outputs.
- **Orchestrator**: Enhanced main menu to clearly distinguish between Native and Docker application variants.
- **AI Suite**: Added support for local AI tools (Ollama).
- **Native vs Docker**: Added flexible installation options for Databases and Monitoring tools.
- **Security Critical**: Locked down Admin UIs to `127.0.0.1`.
- **Stability**: Fixed Redis memory policy to prevent n8n job loss.
- **Maintenance**: Enabled auto-pruning for n8n execution data.

---

## 📌 Versioning

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). For the versions available, see the [tags on this repository](https://github.com/focadaniel89/my-scripts/tags).

See [CHANGELOG.md](CHANGELOG.md) for details on changes.

---

## 📜 License

MIT License - Copyright (c) 2026 Daniel Foca

See [LICENSE](LICENSE) file for details.

## Author

**Daniel Foca** ([@focadaniel89](https://github.com/focadaniel89))
