#!/bin/bash

# ==============================================================================
# XYOPS INSTALLATION (DOCKER)
# Setup XyOps using official Docker image (ghcr.io/pixlcore/xyops)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"
source "${SCRIPT_DIR}/lib/docker.sh"
source "${SCRIPT_DIR}/lib/preflight.sh"

APP_NAME="xyops"
CONTAINER_NAME="xyops01"
DATA_DIR="/opt/automation/xyops"
NETWORK="vps_network"

log_info "═══════════════════════════════════════════"
log_info "  Installing XyOps (Docker)"
log_info "═══════════════════════════════════════════"
echo ""

audit_log "INSTALL_START" "$APP_NAME"

# Pre-flight checks
preflight_check "$APP_NAME" 20 2 "5522"

# Check dependencies
log_step "Step 1: Checking dependencies"

# Docker check
if ! check_docker; then
    log_error "Docker is not installed"
    log_info "Please install Docker first: Infrastructure > Docker Engine"
    exit 1
fi
log_success "✓ Docker is available"

# Nginx check (REQUIRED for SSL)
if ! command -v nginx &>/dev/null; then
    log_error "Nginx is not installed"
    log_info "Please run orchestrator or install Nginx first"
    exit 1
fi
ensure_service_running nginx "Nginx"
log_success "✓ Nginx is available"
echo ""

# Check for existing installation
if run_sudo docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log_success "✓ XyOps is already installed"
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

# Domain configuration
log_step "Step 2: Domain configuration"
echo ""
log_info "XyOps requires a domain name for the reverse proxy"
prompt_domain XYOPS_DOMAIN
save_secret "$APP_NAME" "DOMAIN" "$XYOPS_DOMAIN"
echo ""

# Setup directories
log_step "Step 3: Setting up directory"
create_app_directory "$DATA_DIR"
create_app_directory "$DATA_DIR/data"
create_app_directory "$DATA_DIR/conf"
log_success "Created directory: $DATA_DIR"
echo ""

# Configure secret key
log_step "Step 4: Configuring Secret Key"
SECRET_KEY=$(get_secret "$APP_NAME" "XYOPS_SECRET_KEY" 2>/dev/null || echo "")
if [ -z "$SECRET_KEY" ]; then
    SECRET_KEY=$(openssl rand -hex 32)
    save_secret "$APP_NAME" "XYOPS_SECRET_KEY" "$SECRET_KEY"
    log_success "Generated new secret key"
else
    log_info "Using existing secret key"
fi
echo ""

# Create configuration template
run_sudo tee "$DATA_DIR/conf/config.json" > /dev/null <<EOF
{
  "secret_key": "$SECRET_KEY",
  "log_dir": "/opt/xyops/data/logs",
  "debug_level": 5
}
EOF
run_sudo chown -R 1000:1000 "$DATA_DIR/conf" "$DATA_DIR/data"

# Create Docker Compose file
log_step "Step 5: Creating Docker Compose configuration"

run_sudo tee "$DATA_DIR/docker-compose.yml" > /dev/null << 'EOF'
services:
  xyops01:
    image: ghcr.io/pixlcore/xyops:latest
    container_name: xyops01
    hostname: xyops01
    init: true
    restart: unless-stopped
    environment:
      XYOPS_xysat_local: "true"
      TZ: Europe/Bucharest
    volumes:
      - /opt/automation/xyops/data:/opt/xyops/data
      - /opt/automation/xyops/conf:/opt/xyops/conf
      - /var/run/docker.sock:/var/run/docker.sock
    ports:
      - "127.0.0.1:5522:5522"
      - "127.0.0.1:5523:5523"
    networks:
      - vps_network

networks:
  vps_network:
    external: true
EOF

log_success "Docker Compose configuration created"
echo ""

# Deploy container
log_step "Step 6: Deploying XyOps container"
if ! deploy_with_compose "$DATA_DIR"; then
    log_error "Failed to deploy XyOps"
    exit 1
fi
echo ""

# Wait for container to be ready
log_step "Step 7: Waiting for XyOps to be ready"
RETRIES=30
COUNT=0
while [ $COUNT -lt $RETRIES ]; do
    if curl -s -f http://127.0.0.1:5522/api/health &>/dev/null || curl -s http://127.0.0.1:5522/ &>/dev/null; then
        log_success "XyOps is reachable!"
        break
    fi
    COUNT=$((COUNT + 1))
    if [ $COUNT -eq $RETRIES ]; then
        log_warn "XyOps took too long to become reachable on port 5522. Check logs."
    fi
    sleep 2
done
echo ""

# Configure Nginx reverse proxy
log_step "Step 8: Configuring Nginx reverse proxy"
write_nginx_proxy_config "$APP_NAME" "$XYOPS_DOMAIN" 5522

if run_sudo nginx -t; then
    run_sudo systemctl reload nginx
    log_success "Nginx config valid and reloaded"
else
    log_error "Nginx configuration test failed"
    exit 1
fi
echo ""

log_success "═══════════════════════════════════════════"
log_success "  XyOps Installation Complete!"
log_success "═══════════════════════════════════════════"
audit_log "INSTALL_COMPLETE" "$APP_NAME" "Domain: $XYOPS_DOMAIN"
echo ""

log_info "Access Information:"
echo "  Domain: $XYOPS_DOMAIN"
echo "  Web Interface: http://$XYOPS_DOMAIN (Configure SSL manually or via proxy tool)"
echo "  Local Access: http://localhost:5522"
echo ""

log_info "Storage Configuration:"
echo "  Data directory: $DATA_DIR/data"
echo "  Config directory: $DATA_DIR/conf"
echo ""

log_info "Docker Management:"
echo "  View logs:    docker logs $CONTAINER_NAME -f"
echo "  Restart:      docker restart $CONTAINER_NAME"
echo "  Stop/Start:   docker stop $CONTAINER_NAME / docker start $CONTAINER_NAME"
echo ""
exit 0
