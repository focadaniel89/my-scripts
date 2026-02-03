#!/bin/bash

# ==============================================================================
# PROMETHEUS INSTALLATION (NATIVE)
# Installs Prometheus monitoring system directly on host
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"

APP_NAME="prometheus-native"
SERVICE_NAME="prometheus"

log_info "═══════════════════════════════════════════"
log_info "  Installing Prometheus (Native)"
log_info "═══════════════════════════════════════════"
echo ""

# Detect OS
log_step "Step 1: Detecting operating system"
detect_os
log_success "OS detected: $OS_TYPE"
echo ""

# Install Prometheus
log_step "Step 2: Installing Prometheus"
# Most distros have a decent version of prometheus in standard repos
install_package prometheus

# Verify installation
if ! command -v prometheus &>/dev/null; then
    log_error "Prometheus installation failed"
    exit 1
fi
log_success "Prometheus installed: $(prometheus --version | head -n 1)"
echo ""

# Configure Prometheus
log_step "Step 3: Configuring Prometheus"

CONF_DIR="/etc/prometheus"
CONF_FILE="$CONF_DIR/prometheus.yml"
DATA_DIR="/var/lib/prometheus"

# Ensure directories exist and permissions are correct
run_sudo mkdir -p "$CONF_DIR" "$DATA_DIR"
run_sudo chown -R prometheus:prometheus "$CONF_DIR" "$DATA_DIR"

# Basic Configuration
if [ ! -f "$CONF_FILE" ]; then
    log_info "Creating default configuration..."
    run_sudo tee "$CONF_FILE" > /dev/null <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    scrape_interval: 5s
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node'
    scrape_interval: 5s
    static_configs:
      - targets: ['localhost:9100']
EOF
    log_success "Created prometheus.yml"
else
    log_info "Existing config found at $CONF_FILE"
fi

# Node Exporter (Optional but highly recommended)
if confirm_action "Install Node Exporter (System Metrics)?"; then
    install_package prometheus-node-exporter
    run_sudo systemctl enable prometheus-node-exporter
    run_sudo systemctl restart prometheus-node-exporter
    log_success "Node Exporter installed"
fi

# Start Service
log_step "Step 4: Starting Prometheus Service"
run_sudo systemctl enable "$SERVICE_NAME"
run_sudo systemctl restart "$SERVICE_NAME"

if systemctl is-active --quiet "$SERVICE_NAME"; then
    log_success "Service started: $SERVICE_NAME"
else
    log_error "Failed to start service"
    exit 1
fi
echo ""

log_success "═══════════════════════════════════════════"
log_success "  Prometheus Installation Complete!"
log_success "═══════════════════════════════════════════"
echo "  URL: http://localhost:9090"
echo "  Service: sudo systemctl status $SERVICE_NAME"
echo "  Config: $CONF_FILE"
echo ""
