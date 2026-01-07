#!/bin/bash

# ==============================================================================
# POSTGRESQL DATABASE INSTALLATION
# Deploys PostgreSQL in Docker container with auto-generated credentials
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/docker.sh"
source "${SCRIPT_DIR}/lib/preflight.sh"

APP_NAME="postgres"
CONTAINER_NAME="postgres"
DATA_DIR="/opt/databases/postgres"

# Cleanup on error
INSTALL_FAILED=false
cleanup_on_error() {
    if [ "$INSTALL_FAILED" = true ]; then
        log_error "Installation failed, cleaning up..."
        
        # Remove container if it was created during this installation
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
log_info "  Installing PostgreSQL Database"
log_info "═══════════════════════════════════════════"
echo ""

audit_log "INSTALL_START" "$APP_NAME"

# Pre-flight checks
preflight_check "$APP_NAME" 15 2 "5432"

# Check dependency
log_step "Step 1: Checking dependencies"
if ! check_docker; then
    log_error "Docker dependency check failed"
    exit 1
fi

# Generate or load credentials
log_step "Step 2: Managing credentials"
init_secrets_dir

if has_credentials "$APP_NAME"; then
    log_info "Loading existing credentials..."
    load_secrets "$APP_NAME"
else
    log_info "Generating new credentials..."
    
    # Use standard PostgreSQL defaults with secure password
    DB_PASSWORD=$(generate_secure_password 32 "alphanumeric")
    POSTGRES_USER="postgres"  # Standard PostgreSQL superuser
    POSTGRES_DB="postgres"     # Default database
    
    # Save credentials
    save_secret "$APP_NAME" "DB_PASSWORD" "$DB_PASSWORD"
    save_secret "$APP_NAME" "POSTGRES_USER" "$POSTGRES_USER"
    save_secret "$APP_NAME" "POSTGRES_DB" "$POSTGRES_DB"
    
    # Load for current session
    load_secrets "$APP_NAME"
fi

# Validate critical variables
if [ -z "$DB_PASSWORD" ] || [ -z "$POSTGRES_USER" ] || [ -z "$POSTGRES_DB" ]; then
    log_error "Critical environment variables are empty!"
    log_error "DB_PASSWORD: ${DB_PASSWORD:+SET} ${DB_PASSWORD:-EMPTY}"
    log_error "POSTGRES_USER: ${POSTGRES_USER:+SET} ${POSTGRES_USER:-EMPTY}"
    log_error "POSTGRES_DB: ${POSTGRES_DB:+SET} ${POSTGRES_DB:-EMPTY}"
    exit 1
fi
log_info "✓ All credentials validated"
echo ""

# Verify vps_network exists (created by docker-engine)
log_step "Step 3: Verifying vps_network"
if ! run_sudo docker network inspect vps_network &>/dev/null 2>&1; then
    log_error "vps_network does not exist!"
    log_error "Please install docker-engine first: ./apps/infrastructure/docker-engine/install.sh"
    exit 1
fi
log_success "vps_network found"
echo ""

# Create directories
log_step "Step 4: Creating data directories"
create_app_directory "$DATA_DIR/data" 755

# Check if already installed
if run_sudo docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    if run_sudo docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_warn "Postgres container is already running"
        if confirm_action "Reinstall? (This will stop the DB and remove container)"; then
            log_info "Stopping and removing existing container..."
            remove_container "$CONTAINER_NAME"
        else
            log_info "Installation cancelled"
            echo ""
            log_info "Connection String (from other containers on vps_network):"
            echo "  postgresql://${POSTGRES_USER}:[PASSWORD]@postgres:5432/${POSTGRES_DB}"
            exit 0
        fi
    else
        log_warn "Postgres container exists but is STOPPED"
        if confirm_action "Start Postgres instead of reinstalling?"; then
             log_info "Starting Postgres..."
             run_sudo docker start "$CONTAINER_NAME"
             log_success "Postgres started successfully"
             exit 0
        else
            log_info "Removing old container to reinstall..."
            remove_container "$CONTAINER_NAME"
        fi
    fi
fi

# Deploy container
log_step "Step 5: Deploying PostgreSQL container"
log_info "Using image: pgvector/pgvector:pg16 (includes pgvector extension)"

run_sudo docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --network vps_network \
    --cpus="2" \
    --memory="2g" \
    --memory-reservation="512m" \
    -e POSTGRES_PASSWORD="$DB_PASSWORD" \
    -e POSTGRES_USER="$POSTGRES_USER" \
    -e POSTGRES_DB="$POSTGRES_DB" \
    -e PGDATA=/var/lib/postgresql/data/pgdata \
    -v "${DATA_DIR}/data":/var/lib/postgresql/data \
    -p 127.0.0.1:5432:5432 \
    --health-cmd="pg_isready -U ${POSTGRES_USER}" \
    --health-interval=10s \
    --health-timeout=5s \
    --health-retries=5 \
    pgvector/pgvector:pg16

# Check health
log_step "Step 6: Verifying installation"
log_info "Waiting for PostgreSQL to initialize (may take up to 60s for large databases)..."
if check_container_health "$CONTAINER_NAME" 60; then
    log_success "PostgreSQL is running and healthy!"
else
    log_error "PostgreSQL health check failed after 60 seconds"
    show_container_logs "$CONTAINER_NAME" 20
    exit 1
fi

# Install PostgreSQL extensions
log_step "Step 7: Installing PostgreSQL extensions"
log_info "Installing extensions in template1 (all new databases will inherit them)..."

# Install extensions in template1 database
EXTENSIONS=(
    "uuid-ossp"      # UUID generation support
    "hstore"         # Key-value store
    "pg_trgm"        # Trigram matching for full-text search
    "btree_gin"      # GIN indexing for JSON and arrays
    "btree_gist"     # Advanced GiST indexing
    "vector"         # pgvector for AI embeddings and similarity search
)

for ext in "${EXTENSIONS[@]}"; do
    log_info "Installing extension: $ext"
    if run_sudo docker exec "$CONTAINER_NAME" psql -U "$POSTGRES_USER" -d template1 -c "CREATE EXTENSION IF NOT EXISTS \"$ext\"" &>/dev/null; then
        log_success "✓ $ext installed"
    else
        log_warn "⚠ Failed to install $ext (may not be available in this PostgreSQL version)"
    fi
done

log_success "PostgreSQL extensions installed in template1"
log_info "All future databases will automatically include these extensions"
echo ""

# Verify extensions
log_info "Verifying installed extensions:"
run_sudo docker exec "$CONTAINER_NAME" psql -U "$POSTGRES_USER" -d template1 -c "\\dx" 2>/dev/null || true
echo ""

# Configure firewall (optional, typically accessed via Docker network)
# open_port 5432 "PostgreSQL Database"

echo ""
log_success "═══════════════════════════════════════════"
log_success "  PostgreSQL installed successfully!"
log_success "═══════════════════════════════════════════"
echo ""

# Display connection information
log_info "Container Details:"
echo "  Name:       $CONTAINER_NAME"
echo "  Network:    vps_network"
echo "  Port:       5432"
echo "  Data Dir:   $DATA_DIR/data"
echo ""

log_info "Connection String (from Docker network):"
echo "  Host:     postgres"
echo "  Port:     5432"
echo "  User:     $POSTGRES_USER"
echo "  Database: $POSTGRES_DB"
echo ""

log_info "Connection String (external):"
log_warn "⚠️  PostgreSQL is bound to localhost only for security"
log_info "For external access, use SSH tunnel:"
echo "  ssh -L 5432:127.0.0.1:5432 dfoca89@your-server"
echo ""
log_info "Then connect locally to:"
echo "  postgresql://${POSTGRES_USER}:[PASSWORD]@localhost:5432/${POSTGRES_DB}"
echo ""

log_info "Installed Extensions:"
echo "  ✓ uuid-ossp    - UUID generation"
echo "  ✓ hstore       - Key-value store"
echo "  ✓ pg_trgm      - Full-text search (trigram)"
echo "  ✓ btree_gin    - GIN indexing for JSON/arrays"
echo "  ✓ btree_gist   - Advanced GiST indexing"
echo "  ✓ vector       - pgvector for AI embeddings (similarity search)"
echo ""
log_info "All new databases will automatically inherit these extensions from template1"
echo ""

log_warn "Security Note:"
echo "  • Credentials are stored in: ~/.vps-secrets/.env_${APP_NAME}"
echo "  • For external access, ensure firewall allows port 5432"
echo "  • Consider using SSL/TLS for production"
echo ""

log_info "Management Commands:"
echo "  View logs:    docker logs $CONTAINER_NAME"
echo "  Connect:      docker exec -it $CONTAINER_NAME psql -U $POSTGRES_USER"
echo "  Restart:      docker restart $CONTAINER_NAME"
echo "  Stop:         docker stop $CONTAINER_NAME"
echo "  Remove:       docker rm -f $CONTAINER_NAME"
echo ""
