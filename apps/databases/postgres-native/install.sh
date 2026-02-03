#!/bin/bash

# ==============================================================================
# POSTGRESQL INSTALLATION (NATIVE)
# Installs PostgreSQL directly on host system
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"

APP_NAME="postgres-native"
SERVICE_NAME="postgresql"

log_info "═══════════════════════════════════════════"
log_info "  Installing PostgreSQL (Native)"
log_info "═══════════════════════════════════════════"
echo ""

# Detect OS
log_step "Step 1: Detecting operating system"
detect_os
log_success "OS detected: $OS_TYPE"
echo ""

# Install PostgreSQL
log_step "Step 2: Installing PostgreSQL"
update_pkg_cache
install_package postgresql
install_package postgresql-contrib

# Verify installation
if ! command -v psql &>/dev/null; then
    log_error "PostgreSQL installation failed"
    exit 1
fi
log_success "PostgreSQL installed"
echo ""

# Configure PostgreSQL
log_step "Step 3: Configuring PostgreSQL"

# Enable remote connections (bind to 0.0.0.0)
# Default is localhost only. For a VPS setup where other services (native or docker) need to connect, we often need 0.0.0.0
# However, for security, if everything is local, localhost is better.
# User requested "use full system power", implies services might be distributed or local.
# Let's configure for local access primarily but allow binding changes.

PG_CONF_DIR=$(run_sudo find /etc/postgresql -name "postgresql.conf" | head -n 1 | xargs dirname)
PG_VERSION=$(basename "$PG_CONF_DIR")
PG_CONF_FILE="$PG_CONF_DIR/postgresql.conf"
PG_HBA_FILE="$PG_CONF_DIR/pg_hba.conf"

log_info "PostgreSQL Version: $PG_VERSION"
log_info "Config Dir: $PG_CONF_DIR"

# Backup configs
backup_file "$PG_CONF_FILE"
backup_file "$PG_HBA_FILE"

# Set listen_addresses to '*' to allow connections from other containers/hosts if firewall permits
# But strictly control via pg_hba.conf and UFW
if grep -q "^#listen_addresses = 'localhost'" "$PG_CONF_FILE"; then
    run_sudo sed -i "s/^#listen_addresses = 'localhost'/listen_addresses = '*'/" "$PG_CONF_FILE"
elif grep -q "^listen_addresses = 'localhost'" "$PG_CONF_FILE"; then
    run_sudo sed -i "s/^listen_addresses = 'localhost'/listen_addresses = '*'/" "$PG_CONF_FILE"
fi

# Performance Tuning (Basic 2026 Standards for automation workloads)
# Set shared_buffers to approx 25% of RAM (detected dynamically)
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
SHARED_BUFFERS_MB=$((TOTAL_RAM_MB / 4))
# Cap at 4GB for auto-tuning safety
if [ "$SHARED_BUFFERS_MB" -gt 4096 ]; then SHARED_BUFFERS_MB=4096; fi

log_info "Tuning shared_buffers to ${SHARED_BUFFERS_MB}MB"
if grep -q "^shared_buffers" "$PG_CONF_FILE"; then
    run_sudo sed -i "s/^shared_buffers = .*/shared_buffers = ${SHARED_BUFFERS_MB}MB/" "$PG_CONF_FILE"
else
    echo "shared_buffers = ${SHARED_BUFFERS_MB}MB" | run_sudo tee -a "$PG_CONF_FILE"
fi

# Configure pg_hba.conf to allow password authentication
# Allow host connections with md5/scram-sha-256
echo "host    all             all             0.0.0.0/0               scram-sha-256" | run_sudo tee -a "$PG_HBA_FILE" > /dev/null

log_success "Configuration updated"
echo ""

# Start Service
log_step "Step 4: Starting PostgreSQL Service"
run_sudo systemctl enable "$SERVICE_NAME"
run_sudo systemctl restart "$SERVICE_NAME"

if systemctl is-active --quiet "$SERVICE_NAME"; then
    log_success "Service started: $SERVICE_NAME"
else
    log_error "Failed to start service"
    exit 1
fi
echo ""

# Setup Superuser
log_step "Step 5: Setting up credentials"

# Get or generate secrets
POSTGRES_USER=$(get_secret "postgres-native" "POSTGRES_USER")
if [ -z "$POSTGRES_USER" ]; then
    POSTGRES_USER="postgres" # Default superuser
    save_secret "postgres-native" "POSTGRES_USER" "$POSTGRES_USER"
fi

DB_PASSWORD=$(get_secret "postgres-native" "DB_PASSWORD")
if [ -z "$DB_PASSWORD" ]; then
    DB_PASSWORD=$(generate_secure_password)
    save_secret "postgres-native" "DB_PASSWORD" "$DB_PASSWORD"
fi

log_info "Setting password for user: $POSTGRES_USER"

# Set password using psql
run_sudo -u postgres psql -c "ALTER USER $POSTGRES_USER WITH PASSWORD '$DB_PASSWORD';" > /dev/null

if [ $? -eq 0 ]; then
    log_success "Password set successfully"
else
    log_error "Failed to set password"
    exit 1
fi
echo ""

log_success "═══════════════════════════════════════════"
log_success "  PostgreSQL Installation Complete!"
log_success "═══════════════════════════════════════════"
echo "  Port: 5432"
echo "  User: $POSTGRES_USER"
echo "  Service: sudo systemctl status $SERVICE_NAME"
echo "  Config: $PG_CONF_FILE"
echo ""
