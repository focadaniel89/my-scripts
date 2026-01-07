# VPS Orchestrator

> Production-ready VPS management system with automatic dependency resolution, health monitoring, audit logging, and secure deployment of 22 applications including AI runtimes (Ollama, llama.cpp) with vector database support.

## Quick Start

```bash
# Clone repository
git clone https://github.com/danielfoca89/my-scripts.git
cd my-scripts

# Run orchestrator
./orchestrator.sh

# Select application number (e.g., 3 for n8n)
# Dependencies auto-install, credentials auto-generate
```

## Repository Structure

```
my-scripts/
├── orchestrator.sh              # Main orchestrator with dependency management
│
├── lib/                         # Core libraries (5 modules)
│   ├── utils.sh                # Logging, audit system, helpers (50 lines)
│   ├── secrets.sh              # Credential generation & management (409 lines)
│   ├── docker.sh               # Docker operations & health checks (186 lines)
│   ├── os-detect.sh            # OS detection & package management (278 lines)
│   └── preflight.sh            # Resource validation before install (140 lines)
│
├── apps/                        # Application installers (22 apps)
│   ├── infrastructure/         # 5 apps (Docker, Nginx, Portainer, Certbot, Arcane)
│   ├── databases/              # 4 apps (PostgreSQL, MariaDB, MongoDB, Redis)
│   ├── monitoring/             # 4 apps (Grafana, Prometheus, Netdata, Uptime Kuma)
│   ├── automation/             # 1 app (n8n)
│   ├── ai/                     # 2 apps (Ollama, llama.cpp)
│   ├── security/               # 3 apps (WireGuard, Fail2ban, Security Audit)
│   └── system/                 # 3 apps (VPS Setup, Node.js, Log Maintenance)
│
├── tools/                       # Management tools (5 scripts)
│   ├── health-check.sh         # System health monitoring (577 lines)
│   ├── setup-dashboard.sh      # Dashboard setup with Basic Auth (245 lines)
│   ├── backup-credentials.sh   # Credentials backup/restore (175 lines)
│   ├── backup-databases.sh     # Database backup/restore (295 lines)
│   └── update.sh               # Container update manager (250 lines)
│
├── workflows/                   # Multi-step workflows
├── config/                      # App metadata & categories
└── templates/                   # Docker Compose templates
```

**Statistics:**
- **9,000+ lines** of production bash code
- **22 installers** (5,500+ lines)
- **5 libraries** (1,063 lines)
- **5 tools** (1,542 lines)
- **1 orchestrator** (949 lines)

## Available Applications (22)

### Infrastructure (5)
- **Docker Engine** - Container runtime (auto-installed as dependency)
- **Nginx** - Reverse proxy with automatic dashboard setup
- **Portainer** - Docker management UI
- **Certbot** - SSL certificate automation (Let's Encrypt, optional for n8n)
- **Arcane** - Modern Docker management UI

### Databases (4)
- **PostgreSQL** - Relational DB with pgvector for AI embeddings (uuid-ossp, hstore, pg_trgm, btree_gin, btree_gist, vector)
- **MariaDB** - MySQL-compatible database
- **MongoDB** - NoSQL document database
- **Redis** - In-memory cache & data store (native installation)

### Monitoring (4)
- **Grafana** - Analytics & visualization dashboards
- **Prometheus** - Metrics collection & alerting
- **Netdata** - Real-time system monitoring
- **Uptime Kuma** - Uptime monitoring & status pages

### Automation (1)
- **n8n** - Workflow automation with SSL, PostgreSQL, Redis queue, and AI integration

### AI (2)
- **Ollama** - Self-hosted LLM runtime with on-demand loading (Llama, Mistral, Gemma, CodeLlama, etc.)
- **llama.cpp** - Flexible LLM runtime for any GGUF model from HuggingFace (OpenAI-compatible API)

### Security (3)
- **WireGuard** - VPN solution
- **Fail2ban** - Intrusion prevention system
- **Security Audit** - Vulnerability scanning

### System (3)
- **VPS Setup** - Complete server hardening
- **Node.js** - JavaScript runtime (via NVM)
- **Log Maintenance** - Log rotation & cleanup

## Production Features
### 🆕 Recent Improvements (January 2026)

**N8N Enhancements:**
- ✅ Automatic PostgreSQL database creation with isolated credentials
- ✅ Redis queue integration for production workloads
- ✅ Improved credential management (partial credential support)
- ✅ Enhanced nginx configuration with WebSocket support
- ✅ **Flexible SSL options**: Let's Encrypt (certbot) or self-signed certificates
- ✅ Automatic fallback to self-signed on certbot rate limits
- ✅ Self-signed certificates compatible with Cloudflare SSL mode "Full"
- ✅ Fixed Docker networking for Redis connectivity (172.17.0.1)
- ✅ File permissions fix for n8n data directory (UID 1000)

**PostgreSQL Improvements:**
- ✅ **pgvector extension** - AI embeddings and vector similarity search
- ✅ **Image**: pgvector/pgvector:pg16 (Debian-based)
- ✅ **Extensions auto-installed in template1**: uuid-ossp, hstore, pg_trgm, btree_gin, btree_gist, vector
- ✅ All new databases inherit extensions automatically
- ✅ Standardized to 'postgres' superuser (industry standard)
- ✅ Automated database/user creation for dependent apps
- ✅ Secure random password generation (32 chars)

**AI Runtime Integration:**
- ✅ **Ollama**: On-demand model loading (~50MB idle, ~4GB when active)
- ✅ **llama.cpp**: Manual loading for rare HuggingFace models (OpenAI-compatible)
- ✅ **Network**: Both on vps_network (internal access only)
- ✅ **n8n Integration**: Native Ollama node + OpenAI node for llama.cpp
- ✅ **Use case**: Local LLM inference without API costs, data stays on-premise
- ✅ CPU-optimized (no GPU required)
### �� Audit Logging
All critical operations tracked in `~/.vps-secrets/.audit.log`:
- Installation lifecycle (start/complete/failed)
- Database creation
- Credential backups
- Database backups
- Container updates
- VPS setup events

**View logs:**
```bash
cat ~/.vps-secrets/.audit.log
tail -f ~/.vps-secrets/.audit.log  # Live monitoring
```

### ⚡ Pre-flight Checks
Resource validation before installation:
- **Disk space** - Prevents "no space left" failures
- **RAM availability** - Ensures sufficient memory
- **Port conflicts** - Detects occupied ports
- **User confirmation** - Interactive prompts before proceeding

**Requirements:**
- n8n: 10GB disk, 2GB RAM, port 5678
- PostgreSQL: 15GB disk, 2GB RAM, port 5432
- Docker: 20GB disk, 4GB RAM

### 🛡️ Docker Resource Limits
Database containers protected from resource exhaustion:
- **PostgreSQL**: 2 CPU cores, 2GB RAM (512MB guaranteed)
- **MariaDB**: 2 CPU cores, 2GB RAM (512MB guaranteed)
- **MongoDB**: 2 CPU cores, 2GB RAM (512MB guaranteed)

### 📊 Web Dashboard
Auto-configured with Nginx installation:
- **URL**: `http://your-ip/status.html`
- **Auth**: Basic Auth (username/password)
- **Features**:
  - Real-time CPU, RAM, Disk with progress bars
  - Container status (running/stopped/healthy)
  - SSL certificate expiry monitoring
  - Backup status tracking
  - Auto-refresh (browser: 30s, server: 2 min)

**Credentials:** `~/.vps-secrets/.env_dashboard`

### 🔐 SSL Monitoring
Certificate expiry tracking with alerts:
- **OK**: >30 days remaining
- **WARNING**: <30 days (yellow)
- **CRITICAL**: <7 days (red)
- **Timer check**: Alerts if certbot.timer inactive

### 🚀 Smart Dependencies
- Automatic dependency resolution
- Recursive installation (Docker → PostgreSQL → n8n)
- Status tracking (`[✓ Installed]` indicators)
- Skip already-installed dependencies

## Universal OS Support

**Supported distributions:**
- Debian/Ubuntu (20.04+)
- AlmaLinux/Rocky Linux (8+)
- CentOS (8+)
- Fedora (36+)

**Auto-detects:**
- Package manager (apt/dnf/yum)
- Sudo groups (sudo/wheel)
- SSH service (ssh/sshd)
- Firewall (ufw/firewalld)
- Log paths (/var/log/auth.log or /var/log/secure)

## Security Features

✅ **Random credentials** - 32-64 character passwords  
✅ **Random DB names** - `db_a3k9m2x7p5q1` (unpredictable)  
✅ **Random usernames** - `user_x8n4k2m9p7q5`  
✅ **No defaults** - PostgreSQL, Grafana use random usernames  
✅ **Secure storage** - `~/.vps-secrets/` (600/700 permissions)  
✅ **Audit logging** - All operations tracked  
✅ **Resource limits** - Databases cannot exhaust system  
✅ **Pre-flight checks** - Validation before installation  
✅ **SSL certificates** - Let's Encrypt (auto-renewal) or self-signed (Cloudflare compatible)  
✅ **Dashboard auth** - Basic Auth protected  
✅ **Docker isolation** - Dedicated network (vps_network)  
✅ **Fail2ban** - Intrusion prevention  
✅ **Firewall** - Universal UFW/firewalld support

## Management Tools

### Health Check & Dashboard

**Terminal output:**
```bash
./tools/health-check.sh
```

**HTML dashboard:**
```bash
sudo ./tools/health-check.sh --html /var/www/html/status.html
```

**Monitors:**
- System resources (CPU/RAM/Disk with progress bars)
- Docker containers (status, health)
- Native services (nginx, redis, fail2ban)
- SSL certificates (expiry + certbot timer)
- Credentials count
- Backup status

### Container Updates

**Update single container:**
```bash
./tools/update.sh update <name>
# Examples:
./tools/update.sh update n8n
./tools/update.sh update postgres
```

**Update all containers:**
```bash
./tools/update.sh update-all
```

**List updatable containers:**
```bash
./tools/update.sh list
```

### Backup Credentials

**Create backup:**
```bash
./tools/backup-credentials.sh backup
```

**List backups:**
```bash
./tools/backup-credentials.sh list
```

**Restore backup:**
```bash
./tools/backup-credentials.sh restore <backup-file>
```

**Cleanup old backups (30+ days):**
```bash
./tools/backup-credentials.sh cleanup
```

**Location:** `~/.vps-secrets/.backup/`

### Backup Databases

**Backup all databases:**
```bash
./tools/backup-databases.sh
```

**Backup specific database:**
```bash
./tools/backup-databases.sh postgres
./tools/backup-databases.sh mariadb
./tools/backup-databases.sh mongodb
```

**List backups:**
```bash
./tools/backup-databases.sh list
```

**Cleanup old backups (7+ days):**
```bash
./tools/backup-databases.sh cleanup
```

**Locations:**
- PostgreSQL: `/opt/backups/postgres/`
- MariaDB: `/opt/backups/mariadb/`
- MongoDB: `/opt/backups/mongodb/`

## Example: n8n Installation Workflow

```bash
./orchestrator.sh
# Select: 12 (n8n)

# Orchestrator checks dependencies:
✓ docker-engine not installed → auto-installs
✓ postgres not installed → auto-installs
✓ nginx not installed → auto-installs + dashboard setup
✓ certbot not installed → auto-installs

# n8n installer:
? Enter domain: n8n.example.com
? Enter email: admin@example.com

# Auto-configuration:
✓ Pre-flight check (10GB disk, 2GB RAM, port 5678)
✓ Creates random PostgreSQL DB: n8n_a3k9m2x7
✓ Creates random user: user_x8n4k2m9
✓ Saves credentials: ~/.vps-secrets/.env_n8n
✓ Configures Nginx reverse proxy
✓ Requests SSL certificate
✓ Deploys n8n container
✓ Audit log: installation complete

# Result:
✓ Access: https://n8n.example.com
✓ Dashboard: http://ip/status.html (Basic Auth)
✓ Credentials: ~/.vps-secrets/.env_n8n
```

## Ollama + N8N AI Workflows

### Installation

```bash
# 1. Install n8n (auto-installs dependencies: Docker, PostgreSQL, Redis, Nginx)
./orchestrator.sh  # Select: n8n

# 2. Install Ollama on same network
./orchestrator.sh  # Select: Ollama

# 3. Download models
docker exec ollama ollama pull gemma3     # Pre-installed
docker exec ollama ollama pull mistral    # 7B model
docker exec ollama ollama pull llama3.2   # Fast 3B model

# 4. Verify on-demand loading
docker exec ollama ollama ps              # Shows loaded models
docker stats ollama --no-stream           # Check RAM usage
```

### N8N Integration - Method 1: Ollama Node (Recommended)

```
Workflow Example:
[Manual Trigger]
    ↓ prompt: "Explain Docker"
[Ollama Node]
    URL: http://ollama:11434
    Model: gemma3
    ↓
[Output] → LLM response
```

### N8N Integration - Method 2: llama.cpp with OpenAI Node

```bash
# 1. Install llama.cpp (optional, for HuggingFace models)
./orchestrator.sh  # Select: llama.cpp

# 2. Load model manually (no auto-loading, must run manually)
docker exec llama-cpp llama-server -hf TheBloke/Mistral-7B-GGUF:Q4_K_M

# 3. Use OpenAI node in n8n:
#    - Base URL: http://llama-cpp:8080/v1
#    - API Key: dummy (not validated)
#    - Model: model
```

### Architecture

```
┌─────────────────────────────────────────────┐
│ VPS (vps_network - 172.18.0.0/16)          │
│                                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐ │
│  │PostgreSQL│  │  Ollama  │  │llama.cpp │ │
│  │(pgvector)│  │ :11434   │  │  :8080   │ │
│  └─────┬────┘  └─────┬────┘  └─────┬────┘ │
│        │             │              │      │
│        └─────────────┴──────────────┘      │
│                      │                     │
│              ┌───────┴────────┐            │
│              │  n8n :5678     │            │
│              │ (n8n_network + │            │
│              │  vps_network)  │            │
│              └────────────────┘            │
│                      │                     │
│              ┌───────┴────────┐            │
│              │  Nginx :80/443 │            │
│              │  (native host) │            │
│              └────────────────┘            │
└─────────────────────────────────────────────┘
                      ↓
                  Internet
              https://n8n.domain.com
```

### Use Cases

**Text Generation:**
```json
// Ollama Node
{
  "model": "mistral",
  "prompt": "Summarize: {{ $json.article }}",
  "options": {
    "temperature": 0.7,
    "max_tokens": 500
  }
}
```

**Code Generation:**
```json
// Ollama Node
{
  "model": "codellama",
  "prompt": "Write Python function to {{ $json.task }}"
}
```

**AI Embeddings + Vector Search:**
```sql
-- PostgreSQL with pgvector
-- 1. Generate embeddings via n8n (Ollama)
-- 2. Store in PostgreSQL with vector column
-- 3. Similarity search

CREATE TABLE documents (
  id SERIAL PRIMARY KEY,
  content TEXT,
  embedding vector(384)  -- pgvector
);

-- Similarity search
SELECT content FROM documents
ORDER BY embedding <-> $1::vector
LIMIT 5;
```

### Benefits

✅ **No API costs** - No OpenAI/Anthropic charges  
✅ **Data privacy** - All processing on-premise  
✅ **Low latency** - Same network (~10-50ms)  
✅ **Offline capable** - No internet required  
✅ **Multiple models** - Switch models per workflow  
✅ **On-demand RAM** - Ollama loads/unloads automatically  
✅ **Vector search** - pgvector for RAG (Retrieval Augmented Generation)

## Credential Management

**All credentials auto-generated and stored:**

```bash
# View credentials
cat ~/.vps-secrets/.env_n8n
cat ~/.vps-secrets/.env_postgres
cat ~/.vps-secrets/.env_dashboard

# List all
ls -la ~/.vps-secrets/

# Example .env_n8n:
N8N_DOMAIN='n8n.example.com'
N8N_EMAIL='admin@example.com'
N8N_USER='admin@n8n.local'
N8N_PASSWORD='<64-chars-auto-generated>'
N8N_DB_NAME='n8n_a3k9m2x7'           # Random
N8N_DB_USER='user_x8n4k2m9'          # Random
N8N_DB_PASSWORD='<32-chars-auto-generated>'
```

## Quick Reference

### View Logs
```bash
# Audit log
tail -f ~/.vps-secrets/.audit.log

# Container logs
docker logs n8n -f
docker logs postgres -f

# Nginx logs
sudo tail -f /var/log/nginx/access.log
sudo tail -f /var/log/nginx/error.log
```

### Container Management
```bash
# List containers
docker ps -a

# Restart container
docker restart n8n

# Stop container
docker stop n8n

# Remove container (keeps data)
docker rm n8n
```

### System Status
```bash
# Health check
./tools/health-check.sh

# SSL certificates
certbot certificates

# Nginx status
sudo systemctl status nginx

# Docker status
sudo systemctl status docker
```

## Automated Tasks (Cron)

```bash
# Edit crontab
crontab -e

# Credentials backup (daily 2 AM)
0 2 * * * /path/to/my-scripts/tools/backup-credentials.sh backup

# Database backup (daily 3 AM)
0 3 * * * /path/to/my-scripts/tools/backup-databases.sh

# Dashboard update (every 2 minutes) - auto-configured by setup-dashboard.sh
*/2 * * * * /path/to/my-scripts/tools/health-check.sh --html /var/www/html/status.html
```

## Troubleshooting

### Permissions
```bash
chmod +x orchestrator.sh
chmod +x apps/**/*/install.sh
chmod +x tools/*.sh
```

### View Container Logs
```bash
docker logs <container> -f
docker logs <container> --tail 100
```

### Check Container Status
```bash
docker ps -a
docker inspect <container>
```

### Nginx Configuration Test
```bash
sudo nginx -t
sudo systemctl reload nginx
```

### View Audit Log
```bash
tail -100 ~/.vps-secrets/.audit.log
```

## Architecture

### Native vs Docker

**Native installations:**
- **Nginx** - Needs port 80/443 system access
- **Redis** - Better performance
- **Certbot** - Direct filesystem access for certs
- **WireGuard** - Requires kernel module

**Docker installations:**
- **Databases** - PostgreSQL, MariaDB, MongoDB (with resource limits)
- **Monitoring** - Grafana, Prometheus, Netdata
- **Automation** - n8n, Ollama
- **Infrastructure** - Portainer, Arcane

### Docker Networking

**Multi-network architecture for isolation and shared services:**

```
vps_network (172.18.0.0/16) - Shared database & AI services
├── PostgreSQL (postgres:5432)
├── Ollama (ollama:11434) - Internal only
├── llama.cpp (llama-cpp:8080) - Internal only
└── Other database containers

n8n_network (172.19.0.0/16) - n8n isolation
├── n8n container
└── Connects to BOTH networks:
    ├── n8n_network (own traffic)
    └── vps_network (database & AI access)

Redis (native on host)
├── Binds to: 127.0.0.1, docker0 gateway, vps_network gateway, n8n_network gateway
└── Accessible from: localhost + all Docker containers via their network gateway
```

**Connection examples:**
- n8n → PostgreSQL: `postgres:5432` (DNS on vps_network)
- n8n → Redis: `172.19.0.1:6379` (n8n_network gateway)
- n8n → Ollama: `http://ollama:11434` (DNS on vps_network)
- n8n → llama.cpp: `http://llama-cpp:8080/v1` (DNS on vps_network)

**Security benefits:**
- ✅ AI services (Ollama, llama.cpp) NOT exposed to internet or localhost
- ✅ Internal-only access via vps_network
- ✅ Container isolation from host
- ✅ Network-level access control
- ✅ Predictable DNS resolution
- ✅ Zero cross-network traffic (Redis accessed via own gateway)

## License

MIT License - Copyright (c) 2025 Daniel Foca

See [LICENCE](LICENCE) file for details.

## Author

**Daniel Foca** ([@danielfoca89](https://github.com/danielfoca89))
