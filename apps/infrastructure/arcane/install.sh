#!/bin/bash

# ==============================================================================
# ARCANE - MODERN DOCKER MANAGEMENT PLATFORM
# Web-based Docker management with real-time monitoring
# https://getarcane.app/
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/docker.sh"

APP_NAME="arcane"
CONTAINER_NAME="arcane"
DATA_DIR="/opt/automation/arcane"
NETWORK="vps_network"
ARCANE_VERSION="latest"

log_info "═══════════════════════════════════════════"
log_info "  Installing Arcane Docker Management"
log_info "═══════════════════════════════════════════"
echo ""

# Check dependencies
log_step "Step 1: Checking dependencies"
if ! check_docker; then
    log_error "Docker is not installed"
    log_info "Please install Docker first: Infrastructure > Docker Engine"
    exit 1
fi
log_success "✓ Docker is available"
echo ""

# Check for existing installation
if run_sudo docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log_success "✓ Arcane is already installed"
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

# Generate credentials
log_step "Step 2: Generating secure credentials"
if ! has_credentials "$APP_NAME"; then
    ADMIN_PASSWORD=$(generate_secure_password 24)
    API_TOKEN=$(generate_secure_password 32)
    
    save_secret "$APP_NAME" "ADMIN_PASSWORD" "$ADMIN_PASSWORD"
    save_secret "$APP_NAME" "API_TOKEN" "$API_TOKEN"
    
    log_success "Credentials generated securely"
else
    log_info "Using existing credentials"
    ADMIN_PASSWORD=$(get_secret "$APP_NAME" "ADMIN_PASSWORD")
    API_TOKEN=$(get_secret "$APP_NAME" "API_TOKEN")
fi
echo ""

# Setup directories
log_step "Step 3: Setting up directories"
create_app_directory "$DATA_DIR"
create_app_directory "$DATA_DIR/config"
log_success "Arcane directories created"
echo ""

# Create configuration
log_step "Step 4: Creating configuration"
cat > "$DATA_DIR/config/.env" << EOF
# Arcane Configuration
ARCANE_HOST=0.0.0.0
ARCANE_PORT=3000
ADMIN_PASSWORD=$ADMIN_PASSWORD
API_TOKEN=$API_TOKEN
DOCKER_HOST=/var/run/docker.sock
EOF

log_success "Configuration created"
echo ""

# Create Docker network
log_step "Step 5: Creating Docker network"
create_docker_network "$NETWORK"
echo ""

# Deploy container
log_step "Step 6: Deploying Arcane container"
log_info "Pulling Arcane Docker Management image..."

run_sudo docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --network "$NETWORK" \
    -p 3000:3000 \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -v "$DATA_DIR/config:/app/config" \
    -e ADMIN_PASSWORD="$ADMIN_PASSWORD" \
    -e API_TOKEN="$API_TOKEN" \
    ghcr.io/getarcaneapp/arcane:$ARCANE_VERSION

if [ $? -ne 0 ]; then
    log_error "Failed to deploy Arcane"
    exit 1
fi
log_success "Container deployed"
echo ""

# Wait for container
log_step "Step 7: Waiting for Arcane to be ready"
sleep 8
if curl -sf http://localhost:3000 > /dev/null 2>&1; then
    log_success "Arcane is ready!"
else
    log_warn "Arcane is starting up (this may take a moment)..."
    sleep 5
fi
echo ""

# Display connection info
log_success "═══════════════════════════════════════════"
log_success "  Arcane Docker Management Installed!"
log_success "═══════════════════════════════════════════"
echo ""

SERVER_IP=$(hostname -I | awk '{print $1}')
log_info "Access URLs:"
echo "  Local:    http://localhost:3000"
echo "  Network:  http://$SERVER_IP:3000"
echo ""

log_info "Login Credentials:"
echo "  Username: admin"
echo "  Password: $ADMIN_PASSWORD"
echo "  Stored in: ~/.vps-secrets/.env_$APP_NAME"
echo ""

log_info "Configuration:"
echo "  Config:   $DATA_DIR/config/.env"
echo "  Docker:   /var/run/docker.sock (read-only)"
echo ""

log_info "Features Available:"
echo "  • Container Management - Start, stop, restart containers"
echo "  • Image Management - Pull, inspect, remove images"
echo "  • Network Configuration - Create and manage networks"
echo "  • Volume Management - Manage persistent storage"
echo "  • Real-time Monitoring - CPU, memory, network usage"
echo "  • Log Viewer - View container logs in real-time"
echo ""

log_info "API Access:"
echo "  API Token: $API_TOKEN"
echo "  Base URL:  http://$SERVER_IP:3000/api"
echo "  Docs:      http://$SERVER_IP:3000/docs"
echo ""

log_warn "Important notes:"
echo "  • Arcane has read-only access to Docker socket"
echo "  • Change admin password after first login"
echo "  • Setup Nginx reverse proxy for HTTPS in production"
echo "  • Visit https://getarcane.app/docs for full documentation"
echo ""

log_info "Docker management:"
echo "  View logs:    docker logs $CONTAINER_NAME -f"
echo "  Restart:      docker restart $CONTAINER_NAME"
echo "  Stop:         docker stop $CONTAINER_NAME"
echo "  Start:        docker start $CONTAINER_NAME"
echo "  Remove:       docker rm -f $CONTAINER_NAME"
echo ""


