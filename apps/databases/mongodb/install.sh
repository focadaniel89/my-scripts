#!/bin/bash

# ==============================================================================
# MONGODB DATABASE INSTALLATION
# Deploys MongoDB in Docker container with auto-generated credentials
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/docker.sh"

APP_NAME="mongodb"
CONTAINER_NAME="mongodb"
DATA_DIR="/opt/databases/mongodb"

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
log_info "  Installing MongoDB Database"
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
        log_warn "MongoDB is already running"
        if confirm_action "Reinstall? (This will stop the DB and remove container)"; then
            log_info "Stopping and removing existing container..."
            run_sudo docker stop "$CONTAINER_NAME" 2>/dev/null || true
            run_sudo docker rm "$CONTAINER_NAME" 2>/dev/null || true
        else
            log_info "Installation cancelled"
            exit 0
        fi
    else
        log_warn "MongoDB container exists but is STOPPED"
        if confirm_action "Start MongoDB instead of reinstalling?"; then
             log_info "Starting MongoDB..."
             run_sudo docker start "$CONTAINER_NAME"
             log_success "MongoDB started successfully"
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
    
    save_secret "$APP_NAME" "MONGO_INITDB_ROOT_USERNAME" "admin"
    save_secret "$APP_NAME" "MONGO_INITDB_ROOT_PASSWORD" "$ROOT_PASSWORD"
    save_secret "$APP_NAME" "MONGO_DB_NAME" "$DB_NAME"
    save_secret "$APP_NAME" "MONGO_USER" "$DB_USER"
    save_secret "$APP_NAME" "MONGO_PASSWORD" "$DB_PASSWORD"
    
    log_success "Credentials generated and saved"
else
    log_info "Loading existing credentials..."
fi

load_secrets "$APP_NAME"
log_success "Credentials loaded"

# Validate critical variables
if [ -z "$MONGO_INITDB_ROOT_USERNAME" ] || [ -z "$MONGO_INITDB_ROOT_PASSWORD" ]; then
    log_error "Critical MongoDB credentials are empty!"
    log_error "MONGO_INITDB_ROOT_USERNAME: ${MONGO_INITDB_ROOT_USERNAME:+SET} ${MONGO_INITDB_ROOT_USERNAME:-EMPTY}"
    log_error "MONGO_INITDB_ROOT_PASSWORD: ${MONGO_INITDB_ROOT_PASSWORD:+SET} ${MONGO_INITDB_ROOT_PASSWORD:-EMPTY}"
    exit 1
fi
log_info "✓ MongoDB credentials validated"
echo ""

# Setup directories
log_step "Step 3: Setting up directories"
create_app_directory "$DATA_DIR/data"
create_app_directory "$DATA_DIR/configdb"
log_success "Data directories created: $DATA_DIR"
echo ""

# Create Docker network (if not exists)
log_step "Step 4: Setting up Docker network"
create_docker_network "vps_network"
echo ""

# Deploy container
log_step "Step 5: Deploying MongoDB container"
log_info "Starting MongoDB 7..."

run_sudo docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --network vps_network \
    --cpus="2" \
    --memory="2g" \
    --memory-reservation="512m" \
    -e MONGO_INITDB_ROOT_USERNAME="$MONGO_INITDB_ROOT_USERNAME" \
    -e MONGO_INITDB_ROOT_PASSWORD="$MONGO_INITDB_ROOT_PASSWORD" \
    -v "${DATA_DIR}/data:/data/db" \
    -v "${DATA_DIR}/configdb:/data/configdb" \
    -p 27017:27017 \
    mongo:7.0.5

log_success "MongoDB container started"
echo ""

# Wait for MongoDB to be ready
log_step "Step 5: Waiting for MongoDB to be ready"
log_info "This may take 30-60 seconds..."

MAX_ATTEMPTS=60
ATTEMPT=0
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    if run_sudo docker exec "$CONTAINER_NAME" mongosh --eval "db.adminCommand('ping')" --quiet &>/dev/null; then
        log_success "MongoDB is ready!"
        break
    fi
    ATTEMPT=$((ATTEMPT + 1))
    sleep 2
    echo -n "."
done
echo ""

if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
    log_error "MongoDB did not become ready in time"
    log_info "Check logs: docker logs $CONTAINER_NAME"
    exit 1
fi
echo ""

# Create application user
log_step "Step 6: Creating application user"
run_sudo docker exec "$CONTAINER_NAME" mongosh admin \
    --username "$MONGO_INITDB_ROOT_USERNAME" \
    --password "$MONGO_INITDB_ROOT_PASSWORD" \
    --eval "
        db = db.getSiblingDB('$MONGO_DB_NAME');
        db.createUser({
            user: '$MONGO_USER',
            pwd: '$MONGO_PASSWORD',
            roles: [
                { role: 'readWrite', db: '$MONGO_DB_NAME' },
                { role: 'dbAdmin', db: '$MONGO_DB_NAME' }
            ]
        });
    " &>/dev/null

log_success "Application user created"
echo ""

# Verify container health
log_step "Step 7: Verifying installation"
log_info "Waiting for MongoDB to initialize (may take up to 90s for large volumes)..."
if check_container_health "$CONTAINER_NAME" 90; then
    log_success "MongoDB is running and healthy"
else
    log_warn "MongoDB health check inconclusive after 90s, checking container status..."
    if run_sudo docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_info "Container is running, MongoDB may need more time to fully initialize"
    else
        log_error "Container is not running!"
        show_container_logs "$CONTAINER_NAME" 30
        exit 1
    fi
fi
echo ""

# Display connection info
log_success "═══════════════════════════════════════════"
log_success "  MongoDB Installation Complete!"
log_success "═══════════════════════════════════════════"
echo ""

display_connection_info "$APP_NAME"

echo ""
log_info "Connection examples:"
echo "  # From host (admin):"
echo "  mongosh mongodb://admin:<password>@127.0.0.1:27017/admin"
echo ""
echo "  # From host (app user):"
echo "  mongosh mongodb://$MONGO_USER:<password>@127.0.0.1:27017/$MONGO_DB_NAME"
echo ""
echo "  # From another container:"
echo "  mongodb://$MONGO_USER:<password>@mongodb:27017/$MONGO_DB_NAME"
echo ""

log_info "Useful commands:"
echo "  docker logs mongodb          # View logs"
echo "  docker exec -it mongodb mongosh # Access MongoDB shell"
echo "  docker stop mongodb          # Stop container"
echo "  docker start mongodb         # Start container"
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
