# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.1.0] — 2026-03-07

### Security & Hardening
- **Native Applications**: Enforced secure-by-default localhost/`127.0.0.1` binding and strict authentication (`scram-sha-256`) for native databases (PostgreSQL, Redis) to prevent unintended external exposure.
- **Docker Installations**: Confirmed isolation via custom `vps_network` and localized port binding.

### Modularity & Code Quality
- **Global Refactoring**: Extracted duplicated Nginx and SSL certificate setup logic from individual application scripts into centralized `lib/utils.sh` functions (`write_nginx_proxy_config`, `setup_ssl_certificate`, `prompt_domain`).
- **Standardized Execution**: Added extended signal traps (`ERR`, `INT`, `TERM`) for graceful error handling and cleanup across scripts (e.g. `health-check.sh`, `setup-dashboard.sh`).

### Automation
- **Unattended Installs**: Re-audited all prompts (e.g. Grafana domain selection, final SSH restart confirmation) to respect the `FORCE_YES=1` environment variable for completely automated, non-interactive deployments.

## [2.0.0] — 2026-03-06

### Added — Orchestrator
- Loop menu: returns to menu after each install/tool run (no re-run needed)
- `--help` / `-h` flag for quick usage display
- `[tools]` section in menu: health-check, update, backup, cert generation
- Version banner `v2.0.0`
- `preflight_startup()` at launch: checks bash version, OS, internet

### Added — lib/utils.sh (UTILITY GUARDS)
- `require_debian()` — warns if non-Debian/Ubuntu
- `check_min_bash_version()` — validates bash ≥ 4.0
- `check_internet()` — ping/curl with 3s timeout
- `get_ssh_service_name()` — returns `ssh` or `sshd` per distro
- `configure_sudo_security()` — 5-min sudo timeout + command logging
- `enable_apparmor()` — install, enable, enforce all profiles

### Added — lib/preflight.sh
- `preflight_startup()` — non-interactive startup check
- Export functions for inter-script use

### Added — VPS Hardening (Steps 12-13)
- Step 12: sudo hardening (`configure_sudo_security`)
- Step 13: AppArmor MAC (`enable_apparmor`)
- sysctl: ASLR, core dump disable, IPv6 redirect protection, DoS tuning
- SSH: `PrintLastLog no`
- Fail2Ban: SQLite persistent DB, 24h ban, recidivists jail (7 days)
- Auditd: sudo/su, cron, kernel module monitoring
- `create_admin_user`: `umask 027` in `.bashrc`
- `final_checks`: cross-distro SSH/firewall detection + AppArmor check

### Changed
- Orchestrator: unified log functions, simplified `is_app_installed()`, cleaner dep resolution
- README.md: full rewrite with Debian/Ubuntu focus, 13-step hardening table

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
