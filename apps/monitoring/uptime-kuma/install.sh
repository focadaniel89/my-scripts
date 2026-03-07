#!/bin/bash

# ==============================================================================
# UPTIME KUMA STATUS MONITORING
# Self-hosted uptime monitoring and status page platform
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/docker.sh"

APP_NAME="uptime-kuma"
CONTAINER_NAME="uptime-kuma"
DATA_DIR="/opt/monitoring/uptime-kuma"
NETWORK="vps_network"

log_info "═══════════════════════════════════════════"
log_info "  Installing Uptime Kuma Monitor"
log_info "═══════════════════════════════════════════"
echo ""

# Check dependencies
log_step "Step 1: Checking dependencies"
if ! check_docker; then
    log_error "Docker is not installed"
    log_info "Please install Docker first: Infrastructure > Docker Engine"
    exit 1
fi
log_success "Docker is available"
echo ""

# Check for existing installation
if run_sudo docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log_success "✓ Uptime Kuma is already installed"
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

# Setup directories
log_step "Step 2: Setting up directories"
create_app_directory "$DATA_DIR"
create_app_directory "$DATA_DIR/data"
log_success "Uptime Kuma directories created"
echo ""

# Create Docker network
log_step "Step 3: Creating Docker network"
create_docker_network "$NETWORK"
echo ""

# Create Docker Compose file
log_step "Step 4: Creating Docker Compose configuration"
cat > "$DATA_DIR/docker-compose.yml" << EOF
version: '3.8'

services:
  uptime-kuma:
    image: louislam/uptime-kuma:latest
    container_name: $CONTAINER_NAME
    restart: unless-stopped
    
    ports:
      - "127.0.0.1:3001:3001"
    
    volumes:
      - $DATA_DIR/data:/app/data
      - /var/run/docker.sock:/var/run/docker.sock:ro
    
    networks:
      - $NETWORK
    
    environment:
      - TZ=\${TZ:-Europe/Bucharest}
      - UPTIME_KUMA_PORT=3001
    
    healthcheck:
      test: ["CMD-SHELL", "node extra/healthcheck.js"]
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 30s

networks:
  $NETWORK:
    external: true
EOF

log_success "Docker Compose configuration created"
echo ""

# Deploy container
log_step "Step 5: Deploying Uptime Kuma container"
if ! deploy_with_compose "$DATA_DIR"; then
    log_error "Failed to deploy Uptime Kuma"
    exit 1
fi
echo ""

# Wait for container to be ready
log_step "Step 6: Waiting for Uptime Kuma to be ready"
RETRIES=60
COUNT=0
while [ $COUNT -lt $RETRIES ]; do
    if curl -sf http://localhost:3001 > /dev/null 2>&1; then
        log_success "Uptime Kuma is ready!"
        break
    fi
    COUNT=$((COUNT + 1))
    if [ $COUNT -eq $RETRIES ]; then
        log_error "Uptime Kuma failed to become ready"
        run_sudo docker logs $CONTAINER_NAME --tail 50
        exit 1
    fi
    sleep 2
done
echo ""

# Display connection info
log_success "═══════════════════════════════════════════"
log_success "  Uptime Kuma Installation Complete!"
log_success "═══════════════════════════════════════════"
echo ""

SERVER_IP=$(hostname -I | awk '{print $1}')
log_info "🌐 Access URLs:"
echo "  Local:    http://127.0.0.1:3001"
echo "  Network:  No external access (Bind: 127.0.0.1) - Use Nginx Reverse Proxy"
echo ""

log_info "👤 First-time setup:"
echo "  On first access, you'll be prompted to:"
echo "  1. Create an administrator account"
echo "  2. Set username and password"
echo "  3. Start adding monitors"
echo ""

log_info "📊 Monitor types supported:"
echo "  • HTTP(s) - Website monitoring"
echo "  • TCP Port - Service availability"
echo "  • Ping - ICMP availability"
echo "  • DNS - Domain resolution"
echo "  • Docker Container - Container health"
echo "  • Push - Passive monitoring via HTTP push"
echo "  • Steam Game Server"
echo "  • Keyword - Website content monitoring"
echo ""

log_info "🔔 Notification channels:"
echo "  • Email (SMTP)"
echo "  • Discord"
echo "  • Slack"
echo "  • Telegram"
echo "  • Webhook"
echo "  • Pushover, Gotify, Apprise"
echo "  • And 90+ other services"
echo ""

log_info "📦 Docker management:"
echo "  View logs:    docker logs $CONTAINER_NAME -f"
echo "  Restart:      docker restart $CONTAINER_NAME"
echo "  Stop:         docker stop $CONTAINER_NAME"
echo "  Start:        docker start $CONTAINER_NAME"
echo "  Remove:       cd $DATA_DIR && docker-compose down"
echo ""

log_info "💾 Data location:"
echo "  Database:     $DATA_DIR/data/kuma.db"
echo "  Backups:      Create regular backups of data directory"
echo "  Restore:      Stop container, replace data, restart"
echo ""

log_info "🎨 Features:"
echo "  • Beautiful and responsive UI"
echo "  • Public status pages"
echo "  • Multi-language support"
echo "  • 2FA authentication"
echo "  • Certificate expiry monitoring"
echo "  • API for integration"
echo "  • Docker container monitoring"
echo ""

log_warn "⚠️  Important notes:"
echo "  • Create admin account on first access"
echo "  • Enable 2FA for security"
echo "  • Setup notifications for important services"
echo "  • Public status pages can be shared with customers"
echo "  • Regular backups recommended"
echo "  • Consider Nginx reverse proxy for HTTPS"
echo ""

log_info "💡 Usage examples:"
echo "  1. Monitor website: Add HTTP monitor with URL"
echo "  2. Monitor API: Use HTTP with custom headers/auth"
echo "  3. Monitor service: Add TCP port monitor"
echo "  4. Docker monitoring: Enable Docker socket access"
echo "  5. Create status page: Public > Add New Status Page"
echo ""

log_info "📚 Documentation:"
echo "  • GitHub: https://github.com/louislam/uptime-kuma"
echo "  • Wiki: https://github.com/louislam/uptime-kuma/wiki"
echo "  • API: https://github.com/louislam/uptime-kuma/wiki/API"
echo ""


