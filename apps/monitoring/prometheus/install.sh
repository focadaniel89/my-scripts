#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/docker.sh"

# ==============================================================================
# PROMETHEUS METRICS MONITORING INSTALLATION
# Deploys Prometheus for metrics collection and monitoring
# ==============================================================================

APP_NAME="prometheus"
CONTAINER_NAME="prometheus"
DATA_DIR="/opt/monitoring/prometheus"

log_info "═══════════════════════════════════════════"
log_info "  Installing Prometheus Monitoring"
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
    log_warn "Prometheus container already exists"
    
    if confirm_action "Do you want to reinstall Prometheus?"; then
        log_info "Stopping and removing existing container..."
        run_sudo docker stop "$CONTAINER_NAME" 2>/dev/null || true
        run_sudo docker rm "$CONTAINER_NAME" 2>/dev/null || true
    else
        log_info "Installation cancelled"
        exit 0
    fi
fi

# Setup directories
log_step "Step 2: Setting up directories"
create_app_directory "$DATA_DIR/data"
create_app_directory "$DATA_DIR/config"
create_app_directory "$DATA_DIR/rules"
log_success "Data directories created: $DATA_DIR"
echo ""

# Create Prometheus configuration
log_step "Step 3: Creating Prometheus configuration"
cat > "$DATA_DIR/config/prometheus.yml" <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    monitor: 'vps-monitor'

alerting:
  alertmanagers:
    - static_configs:
        - targets: []

rule_files:
  - '/etc/prometheus/rules/*.yml'

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
        labels:
          instance: 'prometheus'

  - job_name: 'node-exporter'
    static_configs:
      - targets: []
        # Add node-exporter targets here

  - job_name: 'docker'
    static_configs:
      - targets: []
        # Add Docker metrics targets here

  - job_name: 'cadvisor'
    static_configs:
      - targets: []
        # Add cAdvisor targets for container metrics
EOF

# Create basic alerting rules
cat > "$DATA_DIR/rules/alerts.yml" <<'EOF'
groups:
  - name: basic_alerts
    interval: 30s
    rules:
      - alert: InstanceDown
        expr: up == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Instance {{ \$labels.instance }} down"
          description: "{{ \$labels.instance }} has been down for more than 5 minutes."

      - alert: HighCPUUsage
        expr: 100 - (avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "High CPU usage on {{ \$labels.instance }}"
          description: "CPU usage is above 80% for more than 10 minutes."

      - alert: HighMemoryUsage
        expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 90
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "High memory usage on {{ \$labels.instance }}"
          description: "Memory usage is above 90% for more than 10 minutes."

      - alert: DiskSpaceLow
        expr: (1 - (node_filesystem_avail_bytes / node_filesystem_size_bytes)) * 100 > 85
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Disk space low on {{ \$labels.instance }}"
          description: "Disk usage is above 85% on {{ \$labels.mountpoint }}."
EOF

log_success "Configuration files created"
echo ""

# Create Docker network
log_step "Step 4: Setting up Docker network"
create_docker_network "vps_network"
echo ""

# Deploy container
log_step "Step 5: Deploying Prometheus container"
log_info "Starting Prometheus..."

run_sudo docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --network vps_network \
    -v "${DATA_DIR}/config:/etc/prometheus" \
    -v "${DATA_DIR}/rules:/etc/prometheus/rules" \
    -v "${DATA_DIR}/data:/prometheus" \
    -p 9090:9090 \
    --health-cmd="wget --no-verbose --tries=1 --spider http://localhost:9090/-/healthy || exit 1" \
    --health-interval=30s \
    --health-timeout=10s \
    --health-retries=3 \
    prom/prometheus:latest \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.path=/prometheus \
    --web.console.libraries=/usr/share/prometheus/console_libraries \
    --web.console.templates=/usr/share/prometheus/consoles \
    --storage.tsdb.retention.time=15d

log_success "Prometheus container started"
echo ""

# Wait for Prometheus to be ready
log_step "Step 6: Waiting for Prometheus to be ready"
log_info "This may take 20-30 seconds..."

if check_container_health "$CONTAINER_NAME" 30; then
    log_success "Prometheus is ready!"
else
    log_warn "Health check inconclusive, but container is running"
fi
echo ""

# Verify container health
log_step "Step 7: Verifying installation"
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log_success "Prometheus is running and healthy"
else
    log_error "Prometheus container is not running"
    exit 1
fi
echo ""

# Save installation info
init_secrets_dir
save_secret "$APP_NAME" "PROMETHEUS_URL" "http://$(hostname -I | awk '{print $1}'):9090"

# Display connection info
log_success "═══════════════════════════════════════════"
log_success "  Prometheus Installation Complete!"
log_success "═══════════════════════════════════════════"
echo ""

SERVER_IP=$(hostname -I | awk '{print $1}')

log_info "Access Information:"
echo "  URL: http://${SERVER_IP}:9090"
echo ""

log_info "Configuration:"
echo "  Config File: $DATA_DIR/config/prometheus.yml"
echo "  Rules Dir:   $DATA_DIR/rules/"
echo "  Data Dir:    $DATA_DIR/data/"
echo "  Retention:   15 days"
echo ""

log_info "Useful commands:"
echo "  docker logs prometheus              # View logs"
echo "  docker restart prometheus           # Restart Prometheus"
echo "  docker exec prometheus promtool check config /etc/prometheus/prometheus.yml"
echo ""

log_info "Adding Targets:"
echo "  1. Edit: $DATA_DIR/config/prometheus.yml"
echo "  2. Add targets under appropriate scrape_configs"
echo "  3. Reload: curl -X POST http://localhost:9090/-/reload"
echo "     Or:     docker restart prometheus"
echo ""

log_info "Integration with Grafana:"
echo "  • Install Grafana if not already installed"
echo "  • Add Prometheus datasource: http://prometheus:9090"
echo "  • Import dashboards from grafana.com"
echo ""

log_warn "Next Steps:"
echo "  • Install Node Exporter for system metrics"
echo "  • Install cAdvisor for container metrics"
echo "  • Configure alerting (Alertmanager)"
echo "  • Set up Grafana dashboards"
echo ""

log_info "Query Examples:"
echo "  # CPU usage"
echo "  rate(node_cpu_seconds_total[5m])"
echo ""
echo "  # Memory usage"
echo "  node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100"
echo ""
echo "  # Disk usage"
echo "  node_filesystem_avail_bytes / node_filesystem_size_bytes * 100"
echo ""

