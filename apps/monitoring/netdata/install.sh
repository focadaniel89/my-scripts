#!/bin/bash

# ==============================================================================
# NETDATA REAL-TIME MONITORING
# System performance and health monitoring with beautiful dashboards
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/docker.sh"

APP_NAME="netdata"
CONTAINER_NAME="netdata"
DATA_DIR="/opt/monitoring/netdata"
NETWORK="vps_network"

log_info "═══════════════════════════════════════════"
log_info "  Installing Netdata Real-Time Monitor"
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
    log_success "✓ Netdata is already installed"
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
create_app_directory "$DATA_DIR/config"
create_app_directory "$DATA_DIR/cache"
create_app_directory "$DATA_DIR/lib"
log_success "Netdata directories created"
echo ""

# Create Docker network
log_step "Step 3: Creating Docker network"
create_docker_network "$NETWORK"
echo ""

# Create custom configuration
log_step "Step 4: Creating custom configuration"
cat > "$DATA_DIR/config/netdata.conf" << 'EOF'
[global]
    hostname = auto
    update every = 1
    memory mode = dbengine
    page cache size = 64
    dbengine multihost disk space = 1024

[web]
    default port = 19999
    bind to = *
    
[plugins]
    proc = yes
    diskspace = yes
    cgroups = yes
    tc = no
    idlejitter = no
    enable running new plugins = yes
    check for new plugins every = 60

[health]
    enabled = yes
    default repeat warning = 2h
    default repeat critical = 1h
EOF

log_success "Configuration created"
echo ""

# Deploy container
log_step "Step 5: Deploying Netdata container"
log_info "This requires host system access for accurate monitoring..."

run_sudo docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --network "$NETWORK" \
    --hostname "$(hostname)" \
    -p 19999:19999 \
    --cap-add SYS_PTRACE \
    --cap-add SYS_ADMIN \
    --security-opt apparmor=unconfined \
    -v "$DATA_DIR/config:/etc/netdata" \
    -v "$DATA_DIR/cache:/var/cache/netdata" \
    -v "$DATA_DIR/lib:/var/lib/netdata" \
    -v /etc/passwd:/host/etc/passwd:ro \
    -v /etc/group:/host/etc/group:ro \
    -v /proc:/host/proc:ro \
    -v /sys:/host/sys:ro \
    -v /etc/os-release:/host/etc/os-release:ro \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -e DOCKER_HOST=/var/run/docker.sock \
    netdata/netdata:latest

if [ $? -ne 0 ]; then
    log_error "Failed to deploy Netdata"
    exit 1
fi
log_success "Container deployed"
echo ""

# Wait for Netdata to be ready
log_step "Step 6: Waiting for Netdata to be ready"
RETRIES=60
COUNT=0
while [ $COUNT -lt $RETRIES ]; do
    if curl -sf http://localhost:19999/api/v1/info > /dev/null 2>&1; then
        log_success "Netdata is ready!"
        break
    fi
    COUNT=$((COUNT + 1))
    if [ $COUNT -eq $RETRIES ]; then
        log_error "Netdata failed to become ready"
        run_sudo docker logs $CONTAINER_NAME --tail 50
        exit 1
    fi
    sleep 2
done
echo ""

# Display system info
log_success "═══════════════════════════════════════════"
log_success "  Netdata Installation Complete!"
log_success "═══════════════════════════════════════════"
echo ""

SERVER_IP=$(hostname -I | awk '{print $1}')
log_info "🌐 Access URLs:"
echo "  Local:    http://localhost:19999"
echo "  Network:  http://$SERVER_IP:19999"
echo ""

log_info "📊 Monitored metrics:"
echo "  • CPU usage (per core)"
echo "  • Memory & Swap"
echo "  • Disk I/O & space"
echo "  • Network traffic"
echo "  • System load"
echo "  • Running processes"
echo "  • Docker containers"
echo "  • System temperatures"
echo ""

log_info "⚙️ Configuration:"
echo "  Config:   $DATA_DIR/config/netdata.conf"
echo "  Cache:    $DATA_DIR/cache/"
echo "  Database: $DATA_DIR/lib/"
echo ""

log_info "📦 Docker management:"
echo "  View logs:    docker logs $CONTAINER_NAME -f"
echo "  Restart:      docker restart $CONTAINER_NAME"
echo "  Stop:         docker stop $CONTAINER_NAME"
echo "  Start:        docker start $CONTAINER_NAME"
echo "  Remove:       docker rm -f $CONTAINER_NAME"
echo ""

log_info "🔔 Health alerts:"
echo "  • CPU usage > 80%"
echo "  • Memory usage > 80%"
echo "  • Disk space < 10%"
echo "  • High system load"
echo "  • Container crashes"
echo "  Configure: $DATA_DIR/config/health.d/"
echo ""

log_info "🔌 Available plugins:"
echo "  • System monitoring (CPU, RAM, Disk)"
echo "  • Docker container metrics"
echo "  • Network monitoring"
echo "  • Application monitoring (apps.plugin)"
echo "  • Web server metrics (if available)"
echo "  • Database metrics (if configured)"
echo ""

log_warn "⚠️  Important notes:"
echo "  • Netdata runs with elevated privileges for accurate monitoring"
echo "  • Data retention: configured for 1GB disk space"
echo "  • Update interval: 1 second (real-time)"
echo "  • Health checks run every 10 seconds"
echo "  • Consider setting up Nginx reverse proxy for HTTPS"
echo ""

log_info "💡 Next steps:"
echo "  1. Access Netdata dashboard"
echo "  2. Explore real-time metrics"
echo "  3. Configure alert notifications (Slack, Email, etc.)"
echo "  4. Setup Nginx reverse proxy for secure access"
echo "  5. Integrate with Prometheus for long-term storage"
echo ""

log_info "📚 Documentation:"
echo "  • Official docs: https://learn.netdata.cloud"
echo "  • Configuration: https://learn.netdata.cloud/docs/configure/nodes"
echo "  • Health alerts: https://learn.netdata.cloud/docs/monitor/configure-alarms"
echo ""


