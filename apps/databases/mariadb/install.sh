#!/bin/bash

# ==============================================================================
# MARIADB DATABASE INSTALLATION
# Deploys MariaDB in Docker container with auto-generated credentials
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/docker.sh"

APP_NAME="mariadb"
CONTAINER_NAME="mariadb"
DATA_DIR="/opt/databases/mariadb"

# Cleanup on error
INSTALL_FAILED=false
cleanup_on_error() {
    if [ "$INSTALL_FAILED" = true ]; then
        log_error "Installation failed, cleaning up..."
        
        # Remove container if created
        if run_sudo docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$" 2>/dev/null; then
            log_info "Removing failed container: $CONTAINER_NAME"
            run_sudo docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
        fi
        
        audit_log "INSTALL_FAILED" "$APP_NAME" "Cleanup completed"
        log_error "Installation aborted. You can retry by running this script again."
    fi
}
trap 'INSTALL_FAILED=true; cleanup_on_error' ERR

log_info "═══════════════════════════════════════════"
log_info "  Installing MariaDB Database"
log_info "═══════════════════════════════════════════"
echo ""

# Check dependency
log_step "Step 1: Checking dependencies"
if ! check_docker; then
    log_error "Docker is not installed"
    log_info "Please install Docker first: Infrastructure > Docker Engine"
    exit 1
fi
log_success "✓ Docker is available"
echo ""

# Check if already installed
if run_sudo docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    if run_sudo docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_warn "MariaDB is already running"
        if confirm_action "Reinstall? (This will stop the DB and remove container)"; then
            log_info "Stopping and removing existing container..."
            run_sudo docker stop "$CONTAINER_NAME" 2>/dev/null || true
            run_sudo docker rm "$CONTAINER_NAME" 2>/dev/null || true
        else
            log_info "Installation cancelled"
            exit 0
        fi
    else
        log_warn "MariaDB container exists but is STOPPED"
        if confirm_action "Start MariaDB instead of reinstalling?"; then
             log_info "Starting MariaDB..."
             run_sudo docker start "$CONTAINER_NAME"
             log_success "MariaDB started successfully"
             exit 0
        else
            log_info "Removing old container to reinstall..."
            run_sudo docker rm "$CONTAINER_NAME" 2>/dev/null || true
        fi
    fi
fi

# Manage credentials
log_step "Step 2: Managing credentials"
if ! has_credentials "$APP_NAME"; then
    log_info "Generating secure credentials..."
    
    ROOT_PASSWORD=$(generate_secure_password)
    DB_NAME="db_$(generate_secure_password 12 'alphanumeric' | tr '[:upper:]' '[:lower:]')"
    DB_USER="user_$(generate_secure_password 12 'alphanumeric' | tr '[:upper:]' '[:lower:]')"
    DB_PASSWORD=$(generate_secure_password)
    
    save_secret "$APP_NAME" "MARIADB_ROOT_PASSWORD" "$ROOT_PASSWORD"
    save_secret "$APP_NAME" "MARIADB_DATABASE" "$DB_NAME"
    save_secret "$APP_NAME" "MARIADB_USER" "$DB_USER"
    save_secret "$APP_NAME" "MARIADB_PASSWORD" "$DB_PASSWORD"
    
    log_success "Credentials generated and saved"
else
    log_info "Loading existing credentials..."
fi

load_secrets "$APP_NAME"
log_success "Credentials loaded"

# Validate critical variables
if [ -z "$MARIADB_ROOT_PASSWORD" ] || [ -z "$MARIADB_DATABASE" ] || [ -z "$MARIADB_USER" ] || [ -z "$MARIADB_PASSWORD" ]; then
    log_error "Critical MariaDB credentials are empty!"
    log_error "MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD:+SET} ${MARIADB_ROOT_PASSWORD:-EMPTY}"
    log_error "MARIADB_DATABASE: ${MARIADB_DATABASE:+SET} ${MARIADB_DATABASE:-EMPTY}"
    log_error "MARIADB_USER: ${MARIADB_USER:+SET} ${MARIADB_USER:-EMPTY}"
    log_error "MARIADB_PASSWORD: ${MARIADB_PASSWORD:+SET} ${MARIADB_PASSWORD:-EMPTY}"
    exit 1
fi
log_info "✓ MariaDB credentials validated"
echo ""

# Setup directories
log_step "Step 3: Setting up directories"
create_app_directory "$DATA_DIR/data"
log_success "Data directory created: $DATA_DIR"
echo ""

# Deploy container
log_step "Step 4: Deploying MariaDB container"
log_info "Starting MariaDB 11.2..."

run_sudo docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --network vps_network \
    --cpus="2" \
    --memory="2g" \
    --memory-reservation="512m" \
    -e MARIADB_ROOT_PASSWORD="$MARIADB_ROOT_PASSWORD" \
    -e MARIADB_DATABASE="$MARIADB_DATABASE" \
    -e MARIADB_USER="$MARIADB_USER" \
    -e MARIADB_PASSWORD="$MARIADB_PASSWORD" \
    -v "${DATA_DIR}/data:/var/lib/mysql" \
    -p 3306:3306 \
    mariadb:11.2

log_success "MariaDB container started"
echo ""

# Wait for MariaDB to be ready
log_step "Step 5: Waiting for MariaDB to be ready"
log_info "This may take 30-60 seconds..."

MAX_ATTEMPTS=60
ATTEMPT=0
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    if run_sudo docker exec "$CONTAINER_NAME" mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "SELECT 1" &>/dev/null; then
        log_success "MariaDB is ready!"
        break
    fi
    ATTEMPT=$((ATTEMPT + 1))
    sleep 2
    echo -n "."
done
echo ""

if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
    log_error "MariaDB did not become ready in time"
    log_info "Check logs: docker logs $CONTAINER_NAME"
    exit 1
fi
echo ""

# Verify container health
log_step "Step 6: Verifying installation"
log_info "Waiting for MariaDB to initialize (may take up to 90s for large volumes)..."
if check_container_health "$CONTAINER_NAME" 90; then
    log_success "MariaDB is running and healthy"
else
    log_warn "MariaDB health check inconclusive after 90s, checking container status..."
    if run_sudo docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_info "Container is running, MariaDB may need more time to fully initialize"
    else
        log_error "Container is not running!"
        show_container_logs "$CONTAINER_NAME" 30
        exit 1
    fi
fi
echo ""

# Display connection info
log_success "═══════════════════════════════════════════"
log_success "  MariaDB Installation Complete!"
log_success "═══════════════════════════════════════════"
echo ""

display_connection_info "$APP_NAME"

echo ""
log_info "Connection examples:"
echo "  # From host:"
echo "  mysql -h 127.0.0.1 -P 3306 -u $MARIADB_USER -p"
echo ""
echo "  # From another container:"
echo "  mysql -h mariadb -u $MARIADB_USER -p"
echo ""
echo "  # Connection string:"
echo "  mysql://$MARIADB_USER:<password>@mariadb:3306/$MARIADB_DATABASE"
echo ""

log_info "Useful commands:"
echo "  docker logs mariadb          # View logs"
echo "  docker exec -it mariadb bash # Access container"
echo "  docker stop mariadb          # Stop container"
echo "  docker start mariadb         # Start container"
echo ""
cat <<'EXAMPLE'
Example Implementation:
-----------------------

# Check dependencies
require_dependency "infrastructure/docker-engine"

# Manage credentials
if ! has_credentials "$APP_NAME"; then
    PASSWORD=$(generate_secure_password)
    save_secret "$APP_NAME" "APP_PASSWORD" "$PASSWORD"
fi
load_secrets "$APP_NAME"

# Deploy
run_sudo docker run -d \
    --name $APP_NAME \
    --restart unless-stopped \
    --network vps_network \
    -e PASSWORD="$APP_PASSWORD" \
    -p 8080:8080 \
    your-image:latest

# Verify
check_container_health "$APP_NAME"
display_connection_info "$APP_NAME"

EXAMPLE

echo ""
