#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/docker.sh"

# ==============================================================================
# GRAFANA VISUALIZATION PLATFORM INSTALLATION
# Deploys Grafana for metrics visualization and monitoring dashboards
# ==============================================================================

APP_NAME="grafana"
CONTAINER_NAME="grafana"
DATA_DIR="/opt/monitoring/grafana"

log_info "═══════════════════════════════════════════"
log_info "  Installing Grafana Visualization"
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
    log_warn "Grafana container already exists"
    
    if has_credentials "$APP_NAME"; then
        log_info "Using existing installation"
        
        if confirm_action "Do you want to reinstall Grafana?"; then
            log_info "Stopping and removing existing container..."
            run_sudo docker stop "$CONTAINER_NAME" 2>/dev/null || true
            run_sudo docker rm "$CONTAINER_NAME" 2>/dev/null || true
        else
            log_info "Installation cancelled"
            exit 0
        fi
    fi
fi

# Manage credentials
log_step "Step 2: Managing credentials"
if ! has_credentials "$APP_NAME"; then
    log_info "Generating secure admin password..."
    
    ADMIN_PASSWORD=$(generate_secure_password)
    ADMIN_USER="user_$(generate_secure_password 8 'alphanumeric' | tr '[:upper:]' '[:lower:]')"
    
    save_secret "$APP_NAME" "GF_SECURITY_ADMIN_PASSWORD" "$ADMIN_PASSWORD"
    save_secret "$APP_NAME" "GF_SECURITY_ADMIN_USER" "$ADMIN_USER"
    
    log_success "Credentials generated and saved"
else
    log_info "Loading existing credentials..."
fi

load_secrets "$APP_NAME"
log_success "Credentials loaded"
echo ""

# Setup directories
log_step "Step 3: Setting up directories"
create_app_directory "$DATA_DIR/data"
create_app_directory "$DATA_DIR/provisioning/datasources"
create_app_directory "$DATA_DIR/provisioning/dashboards"
log_success "Data directories created: $DATA_DIR"
echo ""

# Create datasource configuration for Prometheus
cat > "$DATA_DIR/provisioning/datasources/prometheus.yml" <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
EOF

log_info "Prometheus datasource configuration created"
echo ""

# Create Docker network
log_step "Step 4: Setting up Docker network"
create_docker_network "vps_network"
echo ""

# Deploy container
log_step "Step 5: Deploying Grafana container"
log_info "Starting Grafana..."

run_sudo docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --network vps_network \
    -e GF_SECURITY_ADMIN_USER="$GF_SECURITY_ADMIN_USER" \
    -e GF_SECURITY_ADMIN_PASSWORD="$GF_SECURITY_ADMIN_PASSWORD" \
    -e GF_INSTALL_PLUGINS="grafana-clock-panel,grafana-simple-json-datasource" \
    -v "${DATA_DIR}/data:/var/lib/grafana" \
    -v "${DATA_DIR}/provisioning:/etc/grafana/provisioning" \
    -p 3000:3000 \
    --health-cmd="wget --no-verbose --tries=1 --spider http://localhost:3000/api/health || exit 1" \
    --health-interval=30s \
    --health-timeout=10s \
    --health-retries=3 \
    grafana/grafana:latest

log_success "Grafana container started"
echo ""

# Wait for Grafana to be ready
log_step "Step 6: Waiting for Grafana to be ready"
log_info "This may take 30-45 seconds..."

if check_container_health "$CONTAINER_NAME" 45; then
    log_success "Grafana is ready!"
else
    log_warn "Health check inconclusive, but container is running"
fi
echo ""

# Verify container health
log_step "Step 7: Verifying installation"
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log_success "Grafana is running and healthy"
else
    log_error "Grafana container is not running"
    exit 1
fi
echo ""

# Display connection info
log_success "═══════════════════════════════════════════"
log_success "  Grafana Installation Complete!"
log_success "═══════════════════════════════════════════"
echo ""

SERVER_IP=$(hostname -I | awk '{print $1}')

log_info "Access Information:"
echo "  URL:      http://${SERVER_IP}:3000"
echo "  Username: $GF_SECURITY_ADMIN_USER"
echo "  Password: (stored in secrets)"
echo ""

display_connection_info "$APP_NAME"

echo ""
log_info "Data Storage:"
echo "  Grafana Data:    $DATA_DIR/data"
echo "  Provisioning:    $DATA_DIR/provisioning"
echo "  Datasources:     $DATA_DIR/provisioning/datasources"
echo "  Dashboards:      $DATA_DIR/provisioning/dashboards"
echo ""

log_info "Useful commands:"
echo "  docker logs grafana          # View logs"
echo "  docker restart grafana       # Restart Grafana"
echo "  docker exec -it grafana sh   # Access container"
echo ""

log_info "Next Steps:"
echo "  1. Login to Grafana web interface"
echo "  2. Add data sources (Prometheus pre-configured if running)"
echo "  3. Import dashboards or create new ones"
echo "  4. Configure alerting"
echo ""

log_warn "Security Recommendations:"
echo "  • Change admin password immediately after first login"
echo "  • Enable HTTPS with reverse proxy (Nginx + Certbot)"
echo "  • Configure user authentication (LDAP, OAuth)"
echo "  • Set up alerting channels"
echo ""

log_info "Popular Dashboard IDs (import from grafana.com):"
echo "  • 1860 - Node Exporter Full"
echo "  • 179  - Docker Prometheus Monitoring"
echo "  • 11074 - Node Exporter for Prometheus"
echo ""

