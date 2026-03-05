# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] - 2026-03-05

### Changed

- **Scripts**: Refactored health check scripts by merging `check-all.sh` into `tools/health-check.sh` (added `--cli`/`--status` flag).
- **Scripts**: Removed redundant local-only installer wrappers for AI tools and `setup-vps` to simplify the project structure. Main scripts now gracefully handle both local and containerized environments.
- **Orchestrator**: Updated menu to use `display_name` from `apps.conf`, clearly distinguishing between Native and Docker installations.

## [1.0.0] - 2026-02-04

### Added

- **Core**: Initial release of VPS Orchestrator with modular Bash architecture.
- **AI Suite**: Support for local AI tools including Ollama, Open WebUI, and Llama.cpp.
- **Automation**: Integration for n8n (with PostgreSQL/Redis) and XyOps.
- **Databases**: Support for PostgreSQL (Docker/Native), Redis (Docker/Native), MongoDB, and MariaDB.
- **Infrastructure**: Nginx reverse proxy with auto-config, Portainer, Arcane, and Certbot.
- **Monitoring**: Grafana, Prometheus, Netdata, and Uptime Kuma.
- **Security**: WireGuard VPN, Fail2ban configuration, and Security Audit scripts.
- **System**: Scripts for VPS setup, log maintenance, and Node.js environment.
- **Tools**: CLI-based orchestrator menu, backup scripts for credentials and databases, and system health checks.
