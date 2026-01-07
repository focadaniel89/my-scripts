#!/bin/bash

# ==============================================================================
# REDIS CACHE/DATABASE INSTALLATION (DOCKER)
# Containerized Redis for use across all VPS applications
# Runs in vps_network for global accessibility
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/docker.sh"
source "${SCRIPT_DIR}/lib/preflight.sh"

APP_NAME="redis"
CONTAINER_NAME="redis"
DATA_DIR="/opt/databases/redis"
NETWORK="vps_network"

# Cleanup on error
INSTALL_FAILED=false
COMPOSE_FILE_CREATED=false
cleanup_on_error() {
    if [ "$INSTALL_FAILED" = true ]; then
        log_error "Installation failed, cleaning up..."
        
        if run_sudo docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$" 2>/dev/null; then
            log_info "Removing failed container: $CONTAINER_NAME"
            run_sudo docker compose -f "${DATA_DIR}/docker-compose.yml" down 2>/dev/null || true
            run_sudo docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
        fi
        
        if [ "$COMPOSE_FILE_CREATED" = true ] && [ -f "${DATA_DIR}/docker-compose.yml" ]; then
            log_info "Removing incomplete docker-compose.yml"
            run_sudo rm -f "${DATA_DIR}/docker-compose.yml" 2>/dev/null || true
        fi
        
        audit_log "INSTALL_FAILED" "$APP_NAME" "Cleanup completed"
        log_error "Installation aborted. You can retry by running this script again."
    fi
}
trap 'INSTALL_FAILED=true; cleanup_on_error' ERR

log_info "═══════════════════════════════════════════"
log_info "  Installing Redis Cache/Database (Docker)"
log_info "═══════════════════════════════════════════"
echo ""

audit_log "INSTALL_START" "$APP_NAME"

# Pre-flight checks
preflight_check "$APP_NAME" 1 1 "6379"

# Check dependencies
log_step "Step 1: Checking dependencies"

if ! check_docker; then
    log_error "Docker is not installed"
    log_info "Please run orchestrator or install Docker first"
    exit 1
fi
log_success "✓ Docker is available"
echo ""

# Check for existing installation
if run_sudo docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log_success "✓ Redis is already installed"
    if confirm_action "Reinstall?"; then
        log_info "Removing existing installation..."
        run_sudo docker stop "$CONTAINER_NAME" 2>/dev/null || true
        run_sudo docker rm "$CONTAINER_NAME" 2>/dev/null || true
    else
        log_info "Installation cancelled"
        exit 0
    fi
fi
echo ""

# Generate/load Redis password
log_step "Step 2: Setting up Redis authentication"

if has_credentials "$APP_NAME"; then
    log_info "Using existing password from credentials store"
    REDIS_PASSWORD=$(get_secret "$APP_NAME" "REDIS_PASSWORD")
else
    log_info "Generating secure password..."
    REDIS_PASSWORD=$(generate_secure_password 32 "alphanumeric")
    save_secret "$APP_NAME" "REDIS_PASSWORD" "$REDIS_PASSWORD"
    log_success "Password saved to credentials store"
fi

if [ -z "$REDIS_PASSWORD" ]; then
    log_error "Failed to generate or retrieve Redis password!"
    exit 1
fi

log_success "Redis password configured"
audit_log "CREDENTIALS_SET" "$APP_NAME" "Password configured"
echo ""

# Setup directories
log_step "Step 3: Setting up directories"
create_app_directory "$DATA_DIR"
log_success "Redis data directory created"
echo ""

# Create Docker Compose file
log_step "Step 4: Creating Docker Compose configuration"
COMPOSE_FILE_CREATED=true

DOCKER_COMPOSE_CONTENT="version: '3.8'

services:
  redis:
    image: redis:7-alpine
    container_name: $CONTAINER_NAME
    restart: unless-stopped
    command: >
      redis-server
      --requirepass $REDIS_PASSWORD
      --appendonly yes
      --appendfsync everysec
      --maxmemory 256mb
      --maxmemory-policy allkeys-lru
    ports:
      - \"127.0.0.1:6379:6379\"
    volumes:
      - redis_data:/data
    healthcheck:
      test: [\"CMD\", \"redis-cli\", \"--raw\", \"incr\", \"ping\"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s

volumes:
  redis_data:
    driver: local"

echo "$DOCKER_COMPOSE_CONTENT" | run_sudo tee "$DATA_DIR/docker-compose.yml" > /dev/null
log_success "Docker Compose configuration created"
echo ""

# Deploy container
log_step "Step 5: Deploying Redis container"
if ! deploy_with_compose "$DATA_DIR"; then
    log_error "Failed to deploy Redis"
    exit 1
fi
echo ""

# Wait for container to be ready
log_step "Step 6: Waiting for Redis to be ready"
RETRIES=30
COUNT=0
while [ $COUNT -lt $RETRIES ]; do
    if run_sudo docker exec $CONTAINER_NAME redis-cli --raw incr ping &>/dev/null; then
        log_success "Redis is ready!"
        break
    fi
    COUNT=$((COUNT + 1))
    if [ $COUNT -eq $RETRIES ]; then
        log_error "Redis failed to become ready"
        run_sudo docker logs $CONTAINER_NAME --tail 50
        exit 1
    fi
    sleep 1
done
echo ""

# Test authentication
log_step "Step 7: Testing Redis authentication"
if run_sudo docker exec $CONTAINER_NAME redis-cli -a "$REDIS_PASSWORD" --no-auth-warning PING | grep -q "PONG"; then
    log_success "✓ Redis authentication working"
else
    log_error "Redis authentication test failed"
    exit 1
fi
echo ""

# Success
log_success "═══════════════════════════════════════════"
log_success "  Redis installation completed!"
log_success "═══════════════════════════════════════════"
echo ""

log_info "Redis Information:"
echo "  Container: $CONTAINER_NAME"
echo "  Mode: Standalone (applications connect to it via docker network connect)"
echo "  Data persistence: Enabled (AOF + RDB)"
echo "  Max memory: 256MB (LRU eviction)"
echo "  Host access: 127.0.0.1:6379 (localhost only)"
echo ""

log_info "Connection Details:"
echo "  From containers: Applications must connect Redis to their networks"
echo "  From localhost: redis://127.0.0.1:6379"
echo "  Password: Stored in ~/.vps-secrets/.env_redis"
echo ""

log_info "How Applications Connect:"
echo "  N8n example: docker network connect n8n_network redis"
echo "  Then n8n accesses: redis://redis:6379"
echo ""

log_info "Docker Management:"
echo "  View logs:    docker logs $CONTAINER_NAME -f"
echo "  Restart:      docker restart $CONTAINER_NAME"
echo "  Stop:         docker stop $CONTAINER_NAME"
echo "  Start:        docker start $CONTAINER_NAME"
echo "  CLI access:   docker exec -it $CONTAINER_NAME redis-cli -a \$REDIS_PASSWORD"
echo "  Remove:       cd $DATA_DIR && docker-compose down -v"
echo ""

log_info "Redis CLI Commands:"
echo "  PING          - Test connection"
echo "  INFO          - Server information"
echo "  DBSIZE        - Number of keys"
echo "  FLUSHALL      - Clear all databases (DANGER!)"
echo ""

audit_log "INSTALL_SUCCESS" "$APP_NAME" "Container: $CONTAINER_NAME, Network: vps_network"
log_success "Installation completed successfully!"
